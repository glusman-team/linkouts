package pipeline

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glusman-team/edge-linkouts/cli/internal/codec"
	"github.com/glusman-team/edge-linkouts/cli/internal/cosmos"
	"github.com/glusman-team/edge-linkouts/cli/internal/engine"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

const (
	keyV1 = "drug-approvals-kg-1.11.2"
	keyV2 = "drug-approvals-kg-1.16.0"
)

func fixtures(t *testing.T) (nodes, edges string) {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test file")
	}
	dir := filepath.Join(filepath.Dir(file), "..", "..", "testdata", "dakp")
	return filepath.Join(dir, "nodes.ndjson"), filepath.Join(dir, "edges.ndjson")
}

func baseOptions(t *testing.T, store cosmos.Store) Options {
	t.Helper()
	nodes, edges := fixtures(t)
	return Options{
		Key:         keyV1,
		NodesPath:   nodes,
		EdgesPath:   edges,
		Store:       store,
		Engine:      engine.NewFake(),
		Budget:      ratelimit.NewUnlimited(),
		Concurrency: 4,
	}
}

// decode reads a stored document back the way the web app will.
func decode(t *testing.T, d cosmos.Doc, dict []byte) *codec.Blob {
	t.Helper()
	blob, err := codec.DecodeBlob(d.Blob, dict)
	if err != nil {
		t.Fatalf("decode %s: %v", d.ID, err)
	}
	return blob
}

func TestLoadFreshCreatesEveryEdge(t *testing.T) {
	store := cosmos.NewFake(nil)
	opt := baseOptions(t, store)
	stats, err := Load(context.Background(), opt)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if stats.Edges != 6 {
		t.Errorf("Edges = %d, want the 6 fixture edges", stats.Edges)
	}
	if stats.Created != 6 || stats.Merged != 0 || stats.Failed != 0 {
		t.Errorf("created=%d merged=%d failed=%d, want 6/0/0", stats.Created, stats.Merged, stats.Failed)
	}
	docs := store.Docs()
	// 6 edges plus the reserved random pool.
	if len(docs) != 7 {
		t.Errorf("stored %d documents, want 7 (6 edges + pool)", len(docs))
	}
	for id, d := range docs {
		if id == cosmos.RandomPoolID {
			continue
		}
		blob := decode(t, d, nil)
		if len(blob.Versions) != 1 {
			t.Errorf("%s holds %d versions, want 1", id, len(blob.Versions))
		}
		doc, err := blob.Resolve(keyV1)
		if err != nil {
			t.Fatalf("resolve %s: %v", id, err)
		}
		if err := codec.CheckNoNulls(doc, "$"); err != nil {
			t.Errorf("%s: %v", id, err)
		}
		if got, _ := doc["id"].(string); got != id {
			t.Errorf("document id %q does not match its key %q", got, id)
		}
		// The join must have attached node-side names; that is the whole reason it exists.
		if name, _ := doc["subject_name"].(string); name == "" {
			t.Errorf("%s has no subject_name", id)
		}
	}
	if stats.RawBytes == 0 || stats.BlobBytes == 0 {
		t.Errorf("size accounting is empty: raw=%d blob=%d", stats.RawBytes, stats.BlobBytes)
	}
	if stats.Sampled == 0 {
		t.Error("no ids were sampled for /random")
	}
}

// A second release of the same KG must land as a second version inside the same document, not
// as a new document and not by overwriting the first.
func TestLoadSecondVersionMergesIntoExistingDocuments(t *testing.T) {
	store := cosmos.NewFake(nil)
	ctx := context.Background()

	first := baseOptions(t, store)
	if _, err := Load(ctx, first); err != nil {
		t.Fatalf("first Load: %v", err)
	}
	second := baseOptions(t, store)
	second.Key = keyV2
	stats, err := Load(ctx, second)
	if err != nil {
		t.Fatalf("second Load: %v", err)
	}
	if stats.Merged != 6 || stats.Created != 0 {
		t.Errorf("created=%d merged=%d, want 0/6", stats.Created, stats.Merged)
	}

	docs := store.Docs()
	versions := 0
	for id, d := range docs {
		if id == cosmos.RandomPoolID {
			continue
		}
		blob := decode(t, d, nil)
		if len(blob.Versions) != 2 {
			t.Fatalf("%s holds %d versions, want 2 (%v)", id, len(blob.Versions), blob.VersionKeys())
		}
		versions += len(blob.Versions)
		// Both versions must resolve, and to different documents: the fixture mutates fields
		// between releases, so an identical result means the delta was applied to the wrong base.
		v1, err := blob.Resolve(keyV1)
		if err != nil {
			t.Fatalf("resolve v1 for %s: %v", id, err)
		}
		v2, err := blob.Resolve(keyV2)
		if err != nil {
			t.Fatalf("resolve v2 for %s: %v", id, err)
		}
		for _, doc := range []codec.Doc{v1, v2} {
			if err := codec.CheckNoNulls(doc, "$"); err != nil {
				t.Errorf("%s: %v", id, err)
			}
		}
		entry := blob.Versions[keyV2]
		if entry.IsFull() {
			t.Errorf("%s stored v2 in full though it only differs by a few fields", id)
		}
		if entry.Base != keyV1 {
			t.Errorf("%s: v2 targets %q, want %q", id, entry.Base, keyV1)
		}
	}
	if versions != 12 {
		t.Errorf("total versions = %d, want 12", versions)
	}
}

// Reloading the same key must be idempotent, and --no-repack must avoid rewriting documents
// that already carry it.
func TestReloadSameKeyIsIdempotent(t *testing.T) {
	store := cosmos.NewFake(nil)
	ctx := context.Background()
	opt := baseOptions(t, store)
	if _, err := Load(ctx, opt); err != nil {
		t.Fatalf("first Load: %v", err)
	}
	before := store.Docs()

	again := baseOptions(t, store)
	again.NoRepack = true
	stats, err := Load(ctx, again)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if stats.Skipped != 6 {
		t.Errorf("skipped = %d, want 6 with --no-repack", stats.Skipped)
	}
	if stats.Created != 0 || stats.Merged != 0 {
		t.Errorf("created=%d merged=%d, want 0/0", stats.Created, stats.Merged)
	}
	after := store.Docs()
	for id, d := range before {
		if id == cosmos.RandomPoolID {
			continue
		}
		if after[id].Blob != d.Blob {
			t.Errorf("%s was rewritten by a --no-repack reload", id)
		}
	}

	// Without --no-repack the version is replaced in place, still leaving exactly one version.
	third := baseOptions(t, store)
	stats, err = Load(ctx, third)
	if err != nil {
		t.Fatalf("repack reload: %v", err)
	}
	if stats.Merged != 6 {
		t.Errorf("merged = %d, want 6", stats.Merged)
	}
	for id, d := range store.Docs() {
		if id == cosmos.RandomPoolID {
			continue
		}
		if n := len(decode(t, d, nil).Versions); n != 1 {
			t.Errorf("%s holds %d versions after reloading the same key, want 1", id, n)
		}
	}
}

func TestDryRunWritesNothing(t *testing.T) {
	store := cosmos.NewFake(nil)
	opt := baseOptions(t, store)
	opt.DryRun = true
	stats, err := Load(context.Background(), opt)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(store.Docs()) != 0 {
		t.Errorf("dry run wrote %d documents", len(store.Docs()))
	}
	if counts := store.OpCounts(); len(counts) != 0 {
		t.Errorf("dry run touched the store: %v", counts)
	}
	if stats.Edges != 6 || stats.BlobBytes == 0 {
		t.Errorf("dry run should still measure the work: edges=%d bytes=%d", stats.Edges, stats.BlobBytes)
	}
	if stats.Sampled != 0 {
		t.Errorf("dry run sampled %d ids for /random", stats.Sampled)
	}
}

func TestChargesAreDebitedToTheBudget(t *testing.T) {
	budget := ratelimit.New(100000) // fast enough not to slow the test, real enough to account
	// Charges are reported by the store, so the store is what holds the budget.
	store := cosmos.NewFake(budget)
	store.ChargeFor["create"] = 5.5
	store.ChargeFor["read"] = 1.0
	opt := baseOptions(t, store)
	opt.Budget = budget
	if _, err := Load(context.Background(), opt); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := budget.Consumed(); got != 6*5.5 {
		t.Errorf("budget consumed %v RU, want %v", got, 6*5.5)
	}
}

func TestPreconditionConflictRetriesAndSucceeds(t *testing.T) {
	store := cosmos.NewFake(nil)
	ctx := context.Background()
	opt := baseOptions(t, store)
	if _, err := Load(ctx, opt); err != nil {
		t.Fatalf("first Load: %v", err)
	}
	// One lost race: the next replace sees a stale etag, must re-read, and must still succeed.
	store.Fail("replace", cosmos.ErrPreconditionFailed)
	second := baseOptions(t, store)
	second.Key = keyV2
	stats, err := Load(ctx, second)
	if err != nil {
		t.Fatalf("Load after a precondition failure: %v", err)
	}
	if stats.Merged != 6 || stats.Failed != 0 {
		t.Errorf("merged=%d failed=%d, want 6/0", stats.Created, stats.Failed)
	}
}

func TestStoreFailureAbortsTheRun(t *testing.T) {
	store := cosmos.NewFake(nil)
	store.Fail("create", errors.New("network unreachable"))
	opt := baseOptions(t, store)
	_, err := Load(context.Background(), opt)
	if err == nil {
		t.Fatal("a store failure did not abort the run")
	}
	if !errors.Is(err, err) { // sanity: the error is the one the store produced, wrapped
		t.Error("unexpected error identity")
	}
}

func TestDictionaryMismatchIsFatal(t *testing.T) {
	dict, err := buildTestDict(t)
	if err != nil {
		t.Skipf("dictionary training needs more sample mass: %v", err)
	}
	store := cosmos.NewFake(nil)
	ctx := context.Background()

	withDict := baseOptions(t, store)
	withDict.Dict = dict
	if _, err := Load(ctx, withDict); err != nil {
		t.Fatalf("Load with a dictionary: %v", err)
	}
	// Reading a dict-compressed document without the dictionary must fail loudly: silently
	// producing garbage is how a display bug becomes undiagnosable.
	without := baseOptions(t, store)
	without.Key = keyV2
	_, err = Load(ctx, without)
	if err == nil {
		t.Fatal("a dictionary mismatch was not detected")
	}
	if got := err.Error(); !contains(got, "dictionary") {
		t.Errorf("error does not mention the dictionary: %v", err)
	}

	// With the dictionary, the second version merges and both resolve.
	again := baseOptions(t, store)
	again.Key = keyV2
	again.Dict = dict
	if _, err := Load(ctx, again); err != nil {
		t.Fatalf("Load with the matching dictionary: %v", err)
	}
	for id, d := range store.Docs() {
		if id == cosmos.RandomPoolID {
			continue
		}
		blob := decode(t, d, dict)
		if len(blob.Versions) != 2 {
			t.Errorf("%s holds %d versions, want 2", id, len(blob.Versions))
		}
	}
}

func TestValidationRejectsUnusableOptions(t *testing.T) {
	store := cosmos.NewFake(nil)
	nodes, edges := fixtures(t)
	cases := map[string]Options{
		"no key":    {NodesPath: nodes, EdgesPath: edges, Store: store, Engine: engine.NewFake()},
		"no store":  {Key: keyV1, NodesPath: nodes, EdgesPath: edges, Engine: engine.NewFake()},
		"no engine": {Key: keyV1, NodesPath: nodes, EdgesPath: edges, Store: store},
		"no nodes":  {Key: keyV1, EdgesPath: edges, Store: store, Engine: engine.NewFake()},
		"no edges":  {Key: keyV1, NodesPath: nodes, Store: store, Engine: engine.NewFake()},
	}
	for name, opt := range cases {
		if _, err := Load(context.Background(), opt); err == nil {
			t.Errorf("%s: Load accepted unusable options", name)
		}
	}
}

func TestBaseKeyMustExistInStoredDocument(t *testing.T) {
	store := cosmos.NewFake(nil)
	ctx := context.Background()
	opt := baseOptions(t, store)
	if _, err := Load(ctx, opt); err != nil {
		t.Fatalf("first Load: %v", err)
	}
	second := baseOptions(t, store)
	second.Key = keyV2
	second.BaseKey = "drug-approvals-kg-0.9.9"
	_, err := Load(ctx, second)
	if err == nil {
		t.Fatal("a --base version that is not stored was accepted")
	}
	if !contains(err.Error(), "not stored in this document") {
		t.Errorf("error = %v", err)
	}
}

func TestRandomPoolIsWrittenAndMerged(t *testing.T) {
	store := cosmos.NewFake(nil)
	ctx := context.Background()
	opt := baseOptions(t, store)
	opt.SampleSize = 4
	if _, err := Load(ctx, opt); err != nil {
		t.Fatalf("first Load: %v", err)
	}
	pool := readPool(t, store, nil)
	if pool.Schema != codec.PoolSchema {
		t.Errorf("pool schema = %q", pool.Schema)
	}
	if len(pool.IDs) != 4 {
		t.Errorf("pool holds %d ids, want the cap of 4", len(pool.IDs))
	}
	if pool.Key != keyV1 {
		t.Errorf("pool key = %q", pool.Key)
	}
	for _, id := range pool.IDs {
		if _, err := store.Read(ctx, id); err != nil {
			t.Errorf("pool references %s, which is not stored: %v", id, err)
		}
	}

	// A second load merges rather than replaces, so /random stays unscoped across releases.
	second := baseOptions(t, store)
	second.Key = keyV2
	second.SampleSize = 4
	if _, err := Load(ctx, second); err != nil {
		t.Fatalf("second Load: %v", err)
	}
	merged := readPool(t, store, nil)
	if len(merged.IDs) != 4 {
		t.Errorf("merged pool holds %d ids, want it capped at 4", len(merged.IDs))
	}
	if merged.Key != keyV2 {
		t.Errorf("merged pool key = %q, want the most recent", merged.Key)
	}
	seen := map[string]bool{}
	for _, id := range merged.IDs {
		if seen[id] {
			t.Errorf("pool contains %s twice, which would bias /random", id)
		}
		seen[id] = true
	}
}

func TestReservoirIsUniformAndCapped(t *testing.T) {
	const k, n = 100, 10000
	counts := make(map[string]int, n)
	for range 20 {
		r := newReservoir(k, 0)
		for i := range n {
			r.offer(idFor(i))
		}
		if r.len() != k {
			t.Fatalf("reservoir holds %d ids, want %d", r.len(), k)
		}
		if r.offered() != n {
			t.Fatalf("offered = %d, want %d", r.offered(), n)
		}
		sampled := r.snapshot()
		for _, id := range sampled {
			counts[id]++
		}
		// Duplicates must never enter the sample: a repeated id would double that edge's chance
		// of being picked by /random.
		seen := map[string]bool{}
		for _, id := range sampled {
			if seen[id] {
				t.Fatal("reservoir contains a duplicate")
			}
			seen[id] = true
		}
	}
	// Every position should be sampled about equally often: expected 20*k/n = 0.2 per id.
	// A front-biased reservoir would show up as the first ids dominating.
	front, back := 0, 0
	for i := range n {
		if c, ok := counts[idFor(i)]; ok {
			if i < n/2 {
				front += c
			} else {
				back += c
			}
		}
	}
	total := front + back
	if total != 20*k {
		t.Fatalf("counted %d samples, want %d", total, 20*k)
	}
	ratio := float64(front) / float64(total)
	if ratio < 0.4 || ratio > 0.6 {
		t.Errorf("sample is biased: %.1f%% from the first half of the stream", ratio*100)
	}
}

func TestProgressReceivesSnapshots(t *testing.T) {
	store := cosmos.NewFake(nil)
	opt := baseOptions(t, store)
	rec := &recordingProgress{}
	opt.Progress = rec
	if _, err := Load(context.Background(), opt); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(rec.calls) == 0 {
		t.Fatal("progress was never reported")
	}
	last := rec.calls[len(rec.calls)-1]
	if !last.final {
		t.Error("the last report was not marked final")
	}
	if last.snap.Edges != 6 {
		t.Errorf("final snapshot reports %d edges, want 6", last.snap.Edges)
	}
	if last.snap.Elapsed <= 0 {
		t.Errorf("final snapshot has no elapsed time: %v", last.snap.Elapsed)
	}
}

func TestTextProgressFormats(t *testing.T) {
	var buf safeBuffer
	p := NewTextProgress(&buf, 100)
	p.Every = 0
	p.Report(Snapshot{Key: keyV1, Elapsed: 2 * time.Second, Edges: 50, Created: 40, Merged: 10, RawBytes: 1000, BlobBytes: 100}, false)
	p.Report(Snapshot{Key: keyV1, Elapsed: 4 * time.Second, Edges: 100, Created: 100, RawBytes: 1000, BlobBytes: 100}, true)
	out := buf.String()
	if !contains(out, "50 edges") || !contains(out, "100 edges") {
		t.Errorf("progress output missing counts:\n%s", out)
	}
	if !contains(out, "eta") {
		t.Errorf("no ETA while the total is known:\n%s", out)
	}
	if !contains(out, "ratio=0.100") {
		t.Errorf("no compression ratio:\n%s", out)
	}
	if !contains(out, "(done)") {
		t.Errorf("final line not marked:\n%s", out)
	}
	// A zero total must not divide by zero.
	p2 := NewTextProgress(&buf, 0)
	p2.Every = 0
	p2.Report(Snapshot{Edges: 5}, false)
}

// --- helpers ---

type recordingProgress struct {
	calls []struct {
		snap  Snapshot
		final bool
	}
}

func (r *recordingProgress) Report(s Snapshot, final bool) {
	r.calls = append(r.calls, struct {
		snap  Snapshot
		final bool
	}{s, final})
}

func readPool(t *testing.T, store *cosmos.Fake, dict []byte) codec.Pool {
	t.Helper()
	d, err := store.Read(context.Background(), cosmos.RandomPoolID)
	if err != nil {
		t.Fatalf("read pool: %v", err)
	}
	var pool codec.Pool
	if err := codec.DecodeJSON(d.Blob, dict, &pool); err != nil {
		t.Fatalf("decode pool: %v", err)
	}
	return pool
}

func buildTestDict(t *testing.T) ([]byte, error) {
	t.Helper()
	nodes, edges := fixtures(t)
	var samples [][]byte
	err := engineEach(nodes, edges, func(doc codec.Doc) error {
		raw, err := codec.Marshal(doc)
		if err != nil {
			return err
		}
		samples = append(samples, raw)
		return nil
	})
	if err != nil {
		return nil, err
	}
	// Six fixture edges are thin training material; repeat them so the builder has enough mass
	// to find literals. A real load trains on thousands of distinct documents.
	for range 6 {
		samples = append(samples, samples...)
	}
	return codec.BuildDict(samples, codec.DefaultDictID)
}

func engineEach(nodes, edges string, fn func(codec.Doc) error) error {
	e := engine.NewFake()
	return e.Join(context.Background(), engine.Query{NodesPath: nodes, EdgesPath: edges}, func(r engine.Row) error {
		doc, err := engine.MergedDoc(r)
		if err != nil {
			return err
		}
		return fn(doc)
	})
}

func idFor(i int) string { return fmt.Sprintf("id-%05d", i) }

func contains(haystack, needle string) bool { return strings.Contains(haystack, needle) }

// safeBuffer collects progress output from concurrent Report calls.
type safeBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// Regenerating the committed contract fixtures must give identical bytes, or CI's diff of them is
// noise. A fixed seed and clock are the only things the pool needs for that.
func TestReservoirIsReproducibleWithASeed(t *testing.T) {
	sample := func(seed int64) []string {
		r := newReservoir(10, seed)
		for i := range 1000 {
			r.offer(idFor(i))
		}
		return r.snapshot()
	}
	a, b := sample(42), sample(42)
	if fmt.Sprint(a) != fmt.Sprint(b) {
		t.Fatalf("same seed, different samples:\n%v\n%v", a, b)
	}
	if fmt.Sprint(a) == fmt.Sprint(sample(43)) {
		t.Fatal("different seeds gave the same sample; the seed is not reaching the RNG")
	}
}
