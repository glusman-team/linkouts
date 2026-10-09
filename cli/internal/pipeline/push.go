package pipeline

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/glusman-team/linkouts/cli/internal/cosmos"
	"github.com/glusman-team/linkouts/cli/internal/ratelimit"
)

// PushOptions configures Push: the source store to read, the target to write, the RU
// budget that paces target writes, and how many documents fly concurrently.
type PushOptions struct {
	Source      cosmos.Store
	Target      cosmos.Store
	Budget      ratelimit.Budget
	Concurrency int
}

// PushStats reports what a push did.
type PushStats struct {
	Read     int
	Created  int
	Skipped  int // conflict with identical bytes: a resumed run, not work
	Replaced int // conflict with different bytes: source is newer
	Failed   int
}

// Push mirrors one store into another, edge documents first and the reserved pool documents
// last, so a reader that observes the pool index can resolve every pool it names.
//
// The happy path is one Create per document, which is the whole point: `load` merging into
// a live container pays a read + conditional replace per edge it merges (about 12 RU per
// document on the measured corpus), while staging the merge into a file store and pushing
// the result pays one create (about 5 RU). A 409 means the target already has the id: the
// stored document is read, an identical one is skipped (push is resumable), a different one
// is replaced under its etag (push is also the promotion path for a restaged store).
func Push(ctx context.Context, o PushOptions) (PushStats, error) {
	if o.Concurrency <= 0 {
		o.Concurrency = 8
	}
	if o.Budget == nil {
		o.Budget = ratelimit.NewUnlimited()
	}

	var stats PushStats
	var mu sync.Mutex
	var reserved []cosmos.Doc
	var firstErrs []error

	// Work queue: edges stream through workers; reserved documents are collected and pushed
	// after the stream ends, which keeps the pool index last (a reader that sees the index
	// can then resolve every pool it names).
	jobs := make(chan cosmos.Doc)
	var wg sync.WaitGroup
	for range o.Concurrency {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for doc := range jobs {
				res, err := pushOne(ctx, o, doc)
				mu.Lock()
				stats.Created += res.Created
				stats.Skipped += res.Skipped
				stats.Replaced += res.Replaced
				stats.Failed += res.Failed
				if err != nil {
					firstErrs = append(firstErrs, err)
				}
				mu.Unlock()
			}
		}()
	}

	err := o.Source.All(ctx, func(d cosmos.Doc) error {
		mu.Lock()
		stats.Read++
		mu.Unlock()
		if cosmos.IsReservedID(d.ID) {
			reserved = append(reserved, d)
			return nil
		}
		select {
		case jobs <- d:
		case <-ctx.Done():
			return ctx.Err()
		}
		return nil
	})
	close(jobs)
	wg.Wait()
	if err != nil {
		return stats, fmt.Errorf("read source %s: %w", o.Source.Name(), err)
	}

	// Reserved documents last, in the order the source stores them (pool docs before the
	// index document, because a staged file appends pools as each load finishes and the
	// index rewrite is the final write).
	for _, d := range reserved {
		res, perr := pushOne(ctx, o, d)
		stats.Created += res.Created
		stats.Skipped += res.Skipped
		stats.Replaced += res.Replaced
		stats.Failed += res.Failed
		if perr != nil {
			return stats, fmt.Errorf("push reserved document %s: %w", d.ID, perr)
		}
	}

	// A run that lost documents is not a success: the counts say what survived, and the
	// caller gets the first failures to investigate. Pushing again resumes (identical
	// documents are skipped), so the fix is always "solve the error, rerun".
	if stats.Failed > 0 {
		sample := errors.Join(firstErrs[:min(3, len(firstErrs))]...)
		return stats, fmt.Errorf("%d of %d documents failed to push: %w",
			stats.Failed, stats.Read, sample)
	}

	return stats, nil
}

func pushOne(ctx context.Context, o PushOptions, d cosmos.Doc) (PushStats, error) {
	if err := o.Target.Create(ctx, d); err == nil {
		return PushStats{Created: 1}, nil
	} else if !errors.Is(err, cosmos.ErrConflict) {
		return PushStats{Failed: 1}, fmt.Errorf("create %s: %w", d.ID, err)
	}

	existing, err := o.Target.Read(ctx, d.ID)
	if err != nil {
		return PushStats{Failed: 1}, fmt.Errorf("read existing %s: %w", d.ID, err)
	}
	if existing.Blob == d.Blob && existing.DictID == d.DictID && existing.KG == d.KG {
		return PushStats{Skipped: 1}, nil
	}
	if err := o.Target.Replace(ctx, d, existing.ETag); err != nil {
		return PushStats{Failed: 1}, fmt.Errorf("replace %s: %w", d.ID, err)
	}
	return PushStats{Replaced: 1}, nil
}
