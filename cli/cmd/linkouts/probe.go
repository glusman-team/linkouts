package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/spf13/cobra"

	"github.com/glusman-team/edge-linkouts/cli/internal/codec"
	"github.com/glusman-team/edge-linkouts/cli/internal/cosmos"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

type probeFlags struct {
	count int
	dict  string
}

func newProbeCmd(g *globals) *cobra.Command {
	f := &probeFlags{}
	cmd := &cobra.Command{
		Use:   "probe",
		Short: "Measure the real cost of the web app's read path",
		Long: `probe point-reads N edge documents and reports what they actually cost.

The number that matters is RU per read, because the free tier is 1000 RU/s shared with the CLI
and the web app is budgeted at 450. probe turns that budget from a guess into a measurement:
it reports mean and worst-case charge, the decoded document sizes, and how many reads per
second the budget allows.

IDs come from the __random_pool__ document a load writes, so the sample spans the KG rather
than being whatever happens to be first in the file.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) (err error) {
			cfg, err := g.resolve()
			if err != nil {
				return err
			}
			dict, err := readDict(f.dict)
			if err != nil {
				return err
			}
			// A real budget, so the measured rate reflects pacing rather than raw latency.
			budget := ratelimit.New(cfg.RUps)
			store, err := g.openStore(cfg, budget)
			if err != nil {
				return err
			}
			defer deferClose(store.Close, &err)

			ids, err := probeIDs(cmd.Context(), store, dict, f.count)
			if err != nil {
				return err
			}
			if len(ids) == 0 {
				return fmt.Errorf("no ids to probe: run `linkouts load` first, which writes the %s document", cosmos.RandomPoolID)
			}
			printf("probing %d documents against %s\n", len(ids), store.Name())

			start := time.Now()
			var totalRU float64
			var worstRU float64
			var worstID string
			var totalStored, totalResolved int64
			var maxStored int64
			for _, id := range ids {
				before := budget.Consumed()
				doc, err := store.Read(cmd.Context(), id)
				if err != nil {
					return fmt.Errorf("read %s: %w", id, err)
				}
				charge := budget.Consumed() - before
				totalRU += charge
				if charge > worstRU {
					worstRU, worstID = charge, id
				}
				totalStored += int64(len(doc.Blob))
				if int64(len(doc.Blob)) > maxStored {
					maxStored = int64(len(doc.Blob))
				}
				// Decoding is part of the read path the web app pays for in CPU, so probe
				// measures it too: a blob that costs 1 RU but 200 ms to expand is still a problem.
				stored, err := dictionaryFor(doc.DictID, dict)
				if err != nil {
					return err
				}
				blob, err := codec.DecodeBlob(doc.Blob, stored)
				if err != nil {
					return fmt.Errorf("decode %s: %w", id, err)
				}
				for _, k := range blob.VersionKeys() {
					resolved, err := blob.Resolve(k)
					if err != nil {
						return fmt.Errorf("resolve %s version %s: %w", id, k, err)
					}
					raw, err := codec.Marshal(resolved)
					if err != nil {
						return err
					}
					totalResolved += int64(len(raw))
				}
			}
			elapsed := time.Since(start)
			n := float64(len(ids))
			mean := totalRU / n
			readsPerSecond := cfg.RUps
			if mean > 0 {
				readsPerSecond = cfg.RUps / mean
			}
			printf("  %.1f RU total in %s (%.0f reads/s achieved)\n", totalRU, elapsed.Round(time.Millisecond), n/elapsed.Seconds())
			printf("  mean %.2f RU/read · worst %.2f RU (%s)\n", mean, worstRU, worstID)
			printf("  budget %.0f RU/s allows ~%.0f reads/s\n", cfg.RUps, readsPerSecond)
			printf("  stored %s total, %s largest; %s decoded across all versions\n",
				humanBytes(totalStored), humanBytes(maxStored), humanBytes(totalResolved))
			if mean > 2 {
				println("  warning: above 2 RU/read the free tier will not carry much traffic; check indexing and document size")
			}
			return nil
		},
	}
	cmd.Flags().IntVarP(&f.count, "n", "n", 20, "documents to read")
	cmd.Flags().StringVar(&f.dict, "dict", "", "trained zstd dictionary the blobs were written with")
	return cmd
}

// probeIDs takes up to n ids from the random pool. A pool smaller than n is used as-is rather
// than padded with repeats, because re-reading one document would flatter any cache and
// understate the real cost.
func probeIDs(ctx context.Context, store cosmos.Store, dict []byte, count int) ([]string, error) {
	doc, err := store.Read(ctx, cosmos.RandomPoolID)
	if err != nil {
		if errors.Is(err, cosmos.ErrNotFound) {
			return nil, nil
		}
		return nil, fmt.Errorf("read %s: %w", cosmos.RandomPoolID, err)
	}
	stored, err := dictionaryFor(doc.DictID, dict)
	if err != nil {
		return nil, err
	}
	var pool codec.Pool
	if err := codec.DecodeJSON(doc.Blob, stored, &pool); err != nil {
		return nil, fmt.Errorf("decode %s: %w", cosmos.RandomPoolID, err)
	}
	ids := pool.IDs
	if len(ids) > count {
		rand.Shuffle(len(ids), func(i, j int) { ids[i], ids[j] = ids[j], ids[i] })
		ids = ids[:count]
	}
	return ids, nil
}
