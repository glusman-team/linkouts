package main

import (
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"
)

func newDocsCmd() *cobra.Command {
	var outDir string
	cmd := &cobra.Command{
		Use:   "docs",
		Short: "Write the CLI reference as Markdown",
		Long: `docs generates one Markdown page per command into --out, from the same flag
definitions the binary uses.

The generated tree is published to GitHub Pages beside the ExDoc output, so the CLI reference
cannot drift from the code: regenerating it is part of the docs build, and CI fails if the
committed copy is stale.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := os.MkdirAll(outDir, 0o755); err != nil {
				return err
			}
			root := newRootCmd()
			// A stable source link keeps the generated pages diffable across checkouts.
			root.DisableAutoGenTag = true
			if err := doc.GenMarkdownTree(root, outDir); err != nil {
				return err
			}
			entries, err := filepath.Glob(filepath.Join(outDir, "*.md"))
			if err != nil {
				return err
			}
			printf("wrote %d pages to %s\n", len(entries), outDir)
			return nil
		},
	}
	cmd.Flags().StringVar(&outDir, "out", "docs/cli", "output directory")
	return cmd
}
