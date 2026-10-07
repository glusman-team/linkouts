package main

import (
	"fmt"
	"sort"

	"github.com/spf13/cobra"

	"github.com/glusman-team/linkouts/cli/internal/codec"
	"github.com/glusman-team/linkouts/cli/internal/pipeline"
	"github.com/glusman-team/linkouts/cli/internal/ratelimit"
	"github.com/glusman-team/linkouts/cli/internal/version"
)

type getFlags struct {
	versionKey string
	list       bool
	raw        bool
	dict       string
}

func newGetCmd(g *globals) *cobra.Command {
	f := &getFlags{}
	cmd := &cobra.Command{
		Use:   "get <edge-uuid>",
		Short: "Read one edge document and print a stored version",
		Long: `get point-reads one edge and expands the requested version.

This is the read path the web app uses, from the CLI: one point read, one zstd decode, then a
delta chain walk. Without --version the newest stored version is printed. --list shows every
version the document holds and how each is stored (full or delta, and against what).`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) (err error) {
			cfg, err := g.resolve()
			if err != nil {
				return err
			}
			dict, err := readDict(f.dict)
			if err != nil {
				return err
			}
			store, err := g.openStore(cfg, ratelimit.NewUnlimited())
			if err != nil {
				return err
			}
			defer deferClose(store.Close, &err)

			doc, err := store.Read(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			g.logf("%s: %s stored, dictionary %#x", args[0], humanBytes(int64(len(doc.Blob))), doc.DictID)
			stored, err := pipeline.DictionaryFor(doc.DictID, dict)
			if err != nil {
				return err
			}
			blob, err := codec.DecodeBlob(doc.Blob, stored)
			if err != nil {
				return err
			}
			if f.list {
				return listVersions(blob)
			}
			key := f.versionKey
			if key == "" {
				key = version.Newest(blob.VersionKeys())
			}
			resolved, err := blob.Resolve(key)
			if err != nil {
				return err
			}
			if f.raw {
				println(doc.Blob)
				return nil
			}
			pretty, err := codec.Marshal(resolved)
			if err != nil {
				return err
			}
			printf("%s\n", pretty)
			return nil
		},
	}
	cmd.Flags().StringVar(&f.versionKey, "version", "", "version key to resolve (default: newest)")
	cmd.Flags().BoolVar(&f.list, "list", false, "list stored versions instead of resolving one")
	cmd.Flags().BoolVar(&f.raw, "raw", false, "print the stored base64 frame")
	cmd.Flags().StringVar(&f.dict, "dict", "", "trained zstd dictionary the blob was written with")
	return cmd
}

func listVersions(blob *codec.Blob) error {
	keys := blob.VersionKeys()
	// Newest first: that is the order a reviewer wants, and the same order the UI lists.
	sort.Slice(keys, func(i, j int) bool { return version.CompareKeys(keys[i], keys[j]) > 0 })
	for _, k := range keys {
		entry := blob.Versions[k]
		kind := "full"
		if !entry.IsFull() {
			kind = fmt.Sprintf("delta ← %s", entry.Base)
		}
		doc, err := blob.Resolve(k)
		if err != nil {
			return err
		}
		raw, err := codec.Marshal(doc)
		if err != nil {
			return err
		}
		printf("%-32s %-28s %d fields, %s resolved\n", k, kind, len(doc), humanBytes(int64(len(raw))))
	}
	return nil
}
