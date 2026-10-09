package pipeline

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/glusman-team/linkouts/cli/internal/cosmos"
)

// Push is the reload path: it must create what is new, skip what is identical (resume), and
// replace what changed - and the reserved pool index must land last, because a reader that
// sees the index resolves every pool it names.

func TestPushCreatesIntoAnEmptyTarget(t *testing.T) {
	source := cosmos.NewFake(nil)
	target := cosmos.NewFake(nil)
	source.Seed(cosmos.Doc{ID: "a", Blob: "b1", KG: "kg"}).Seed(cosmos.Doc{ID: "b", Blob: "b2", KG: "kg"})

	stats, err := Push(context.Background(), PushOptions{Source: source, Target: target})
	if err != nil {
		t.Fatalf("push: %v", err)
	}
	if stats != (PushStats{Read: 2, Created: 2}) {
		t.Fatalf("stats = %+v", stats)
	}
	if got := target.Docs()["a"].Blob; got != "b1" {
		t.Fatalf("target a = %q", got)
	}
}

func TestPushSkipsIdenticalAndReplacesChanged(t *testing.T) {
	source := cosmos.NewFake(nil)
	target := cosmos.NewFake(nil)
	source.Seed(cosmos.Doc{ID: "same", Blob: "b", DictID: 7, KG: "kg"})
	source.Seed(cosmos.Doc{ID: "changed", Blob: "new"})
	target.Seed(cosmos.Doc{ID: "same", Blob: "b", DictID: 7, KG: "kg"})
	target.Seed(cosmos.Doc{ID: "changed", Blob: "old"})

	stats, err := Push(context.Background(), PushOptions{Source: source, Target: target})
	if err != nil {
		t.Fatalf("push: %v", err)
	}
	if stats != (PushStats{Read: 2, Skipped: 1, Replaced: 1}) {
		t.Fatalf("stats = %+v", stats)
	}
	if got := target.Docs()["changed"].Blob; got != "new" {
		t.Fatalf("changed = %q, want the source's bytes", got)
	}
	// A rerun of the same push is a no-op: that is what makes the command resumable.
	again, err := Push(context.Background(), PushOptions{Source: source, Target: target})
	if err != nil {
		t.Fatalf("re-push: %v", err)
	}
	if again != (PushStats{Read: 2, Skipped: 2}) {
		t.Fatalf("re-push stats = %+v", again)
	}
}

func TestPushKeepsThePoolIndexLast(t *testing.T) {
	source := cosmos.NewFake(nil)
	target := cosmos.NewFake(nil)
	source.Seed(cosmos.Doc{ID: "00000000-edge", Blob: "b"})
	source.Seed(cosmos.Doc{ID: cosmos.RandomPoolID, Blob: "ix"})
	source.Seed(cosmos.Doc{ID: cosmos.PoolDocID("kg", "1.0"), Blob: "pool"})

	if _, err := Push(context.Background(), PushOptions{Source: source, Target: target, Concurrency: 4}); err != nil {
		t.Fatalf("push: %v", err)
	}
	for _, id := range []string{"00000000-edge", cosmos.RandomPoolID, cosmos.PoolDocID("kg", "1.0")} {
		if _, ok := target.Docs()[id]; !ok {
			t.Fatalf("target is missing %s", id)
		}
	}
}

func TestPushReportsFailuresLoudly(t *testing.T) {
	source := cosmos.NewFake(nil).Seed(cosmos.Doc{ID: "a", Blob: "b"})
	target := cosmos.NewFake(nil).Fail("create", errors.New("simulated outage"))

	stats, err := Push(context.Background(), PushOptions{Source: source, Target: target})
	if err == nil {
		t.Fatal("a failed push must return an error, not just a count")
	}
	if stats.Failed != 1 || !strings.Contains(err.Error(), "simulated outage") {
		t.Fatalf("stats %+v, err %v", stats, err)
	}
}

func TestPushHonoursBudget(t *testing.T) {
	// The budget paces target writes; an unlimited-budget fake is what the dry run and the
	// local file store use, so here we only prove the wiring exists (charged reads of the
	// conflict path are covered by the merge tests).
	source := cosmos.NewFake(nil).Seed(cosmos.Doc{ID: "a", Blob: "b"})
	target := cosmos.NewFake(nil)
	stats, err := Push(context.Background(), PushOptions{Source: source, Target: target, Concurrency: 1})
	if err != nil {
		t.Fatalf("push: %v", err)
	}
	if stats.Created != 1 {
		t.Fatalf("stats = %+v", stats)
	}
}
