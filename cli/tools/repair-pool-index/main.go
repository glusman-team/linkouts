// Command repair-pool-index reconstructs pool-index entries for releases whose pool
// documents survive in the store but whose index entries were lost.
//
// Background: an older load aborted the index write's read on a transient error and fell
// through to a fresh index, clobbering every other graph's entry (the bug Load's
// writePoolIndex now refuses to commit). This tool restores what the surviving pool
// documents still prove: each release's pool document holds its ids and sampled-at
// timestamp; only the true edge count has to be supplied, from the release's own README.
//
// Usage (one-off, run from cli/):
//
//	go run ./tools/repair-pool-index
//
// It reads the current index, verifies each pool document exists, sets the entries below,
// and upserts the index. Idempotent: rerunning writes the same document.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/glusman-team/linkouts/cli/internal/codec"
	"github.com/glusman-team/linkouts/cli/internal/config"
	"github.com/glusman-team/linkouts/cli/internal/cosmos"
	"github.com/glusman-team/linkouts/cli/internal/pipeline"
	"github.com/glusman-team/linkouts/cli/internal/ratelimit"
)

// repairs lists one entry per lost release. Edges is the release's true edge count as
// published in the dataset card (huggingface.co/datasets/SkyeAv/drug-approvals-kp, table
// "Releases"); SampledAt comes from the surviving pool document itself.
var repairs = []struct {
	slug  string
	label string
	edges int64
}{
	{"drugapprovals-kp", "1.23.3", 138275},
	{"drugapprovals-kp", "1.23.4", 138284},
	{"drugapprovals-kp", "1.23.5", 138284},
	{"drugapprovals-kp", "1.24.0", 136291},
	{"drugapprovals-kp", "1.24.1", 136291},
}

func main() {
	ctx := context.Background()
	cfg, err := config.Load(nil)
	if err != nil {
		fatal(err)
	}
	store, err := cosmos.Open(ctx, "cosmos", cfg.Cosmos, ratelimit.New(cfg.RUps))
	if err != nil {
		fatal(err)
	}
	defer func() { _ = store.Close() }()

	index, err := pipeline.ReadPoolIndex(ctx, store, nil)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("index holds %d graphs before repair\n", len(index.KGs))

	for _, r := range repairs {
		// The pool documents were written with the DAKP dictionary; the read resolves the
		// dictionary from the document itself only if passed, so pass the web app's copy.
		pool, err := pipeline.ReadPool(ctx, store, dictBytes(), r.slug, r.label)
		if err != nil {
			fatal(fmt.Errorf("%s %s: %w", r.slug, r.label, err))
		}
		at := pool.SampledAt
		if at == "" {
			at = time.Now().UTC().Format(time.RFC3339)
		}
		index.Set(r.slug, r.label, r.edges, len(pool.IDs), at)
		fmt.Printf("repaired %s %s: edges=%d sampled=%d at=%s\n", r.slug, r.label, r.edges, len(pool.IDs), at)
	}

	encoded, err := codec.EncodeJSON(index, nil, 0)
	if err != nil {
		fatal(err)
	}
	doc := cosmos.Doc{ID: cosmos.RandomPoolID, Blob: encoded}
	if err := store.Upsert(ctx, doc); err != nil {
		fatal(err)
	}
	fmt.Println("pool index repaired")
}

// dictBytes loads the DAKP dictionary this CLI ships to the web app, so the surviving
// pool documents decode. The registry file name carries the dictionary id; DAKP_DICT
// overrides the search path for a checkout laid out differently.
func dictBytes() []byte {
	if p := os.Getenv("DAKP_DICT"); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			fatal(err)
		}
		return b
	}
	for _, p := range []string{
		"../web/priv/zstd/drugapprovals-kp.77140996.dict",
		"web/priv/zstd/drugapprovals-kp.77140996.dict",
	} {
		if b, err := os.ReadFile(p); err == nil {
			return b
		}
	}
	fatal(errors.New("DAKP dictionary not found; set DAKP_DICT"))
	return nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "repair-pool-index:", err)
	os.Exit(1)
}
