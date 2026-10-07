package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/glusman-team/linkouts/cli/internal/codec"
	"github.com/glusman-team/linkouts/cli/internal/engine"
)

type trainDictFlags struct {
	nodes   string
	edges   string
	out     string
	samples int
	threads int
}

func newTrainDictCmd(g *globals) *cobra.Command {
	f := &trainDictFlags{}
	cmd := &cobra.Command{
		Use:   "train-dict",
		Short: "Train a zstd dictionary from a KG's own documents",
		Long: `train-dict runs the join over a sample of the input and builds the compression
dictionary that load and the web app both use.

Small JSON documents compress badly alone: most of an edge is key names that repeat on every
other edge. A dictionary trained on this KG's own shape is what takes a ~250-byte document to
~25 bytes, which is the difference between a point read costing 1 RU and costing 1 RU plus a
download the free tier has to serve thousands of times a day.

The dictionary is written to --out and committed to web/priv/zstd/ so the reader and the writer
always agree. Retraining changes the dictionary id, and a blob written with one dictionary
cannot be decoded with another, so retrain deliberately and repack afterwards.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) (err error) {
			cfg, err := g.resolve()
			if err != nil {
				return err
			}
			eng, err := g.openEngine(cfg)
			if err != nil {
				return err
			}
			defer deferClose(eng.Close, &err)

			samples := make([][]byte, 0, f.samples)
			err = eng.Join(cmd.Context(), engine.Query{
				NodesPath: f.nodes,
				EdgesPath: f.edges,
				Threads:   f.threads,
			}, func(r engine.Row) error {
				if len(samples) >= f.samples {
					return engine.ErrStop
				}
				doc, err := engine.MergedDoc(r)
				if err != nil {
					return err
				}
				blob, err := codec.NewBlob("sample", doc)
				if err != nil {
					return err
				}
				// Train on the encoded blob, not on the bare document: that is the byte stream
				// the dictionary will actually be used against.
				raw, err := codec.Marshal(blob)
				if err != nil {
					return err
				}
				samples = append(samples, raw)
				return nil
			})
			if err != nil && err != engine.ErrStop {
				return err
			}
			if len(samples) == 0 {
				return fmt.Errorf("no documents were sampled from %s", f.edges)
			}
			dict, err := codec.BuildDict(samples, codec.DefaultDictID)
			if err != nil {
				return err
			}
			if dir := filepath.Dir(f.out); dir != "" && dir != "." {
				if err := os.MkdirAll(dir, 0o755); err != nil {
					return err
				}
			}
			if err := os.WriteFile(f.out, dict, 0o644); err != nil {
				return fmt.Errorf("write %s: %w", f.out, err)
			}
			printf("trained a %s dictionary (id %#x) from %d documents → %s\n",
				humanBytes(int64(len(dict))), codec.DictID(dict), len(samples), f.out)
			return nil
		},
	}
	cmd.Flags().StringVar(&f.nodes, "nodes", "", "path to KGX nodes.ndjson (required)")
	cmd.Flags().StringVar(&f.edges, "edges", "", "path to KGX edges.ndjson (required)")
	cmd.Flags().StringVar(&f.out, "out", "", "dictionary output path (required)")
	cmd.Flags().IntVar(&f.samples, "samples", 4096, "documents to train from")
	cmd.Flags().IntVar(&f.threads, "threads", 0, "ClickHouse max_threads (default: NumCPU)")
	_ = cmd.MarkFlagRequired("nodes")
	_ = cmd.MarkFlagRequired("edges")
	_ = cmd.MarkFlagRequired("out")
	return cmd
}
