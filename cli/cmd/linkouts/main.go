// Command linkouts ingests Biolink KGX dumps into Cosmos DB and serves them to the web app.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	// A load can run for minutes against a 134 MB dump; Ctrl-C must cancel the context so the
	// engine and the store are released instead of leaving a half-written document behind.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := newRootCmd().ExecuteContext(ctx); err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			fmt.Fprintln(os.Stderr, "interrupted")
			os.Exit(130)
		}
		fmt.Fprintf(os.Stderr, "linkouts: %v\n", err)
		os.Exit(1)
	}
}
