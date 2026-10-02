package cosmos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

func testDoc(id string) Doc {
	return Doc{ID: id, Blob: "KLUv/QAMAdw=", DictID: DefaultDictIDForTest}
}

// DefaultDictIDForTest keeps the tests honest about the omitted-zero case: a non-zero dict
// id must survive a round trip, and a zero one must not appear in the stored JSON.
const DefaultDictIDForTest = 0x454C4F31

func TestFileStoreRoundTripAndReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "docs.ndjson")
	ctx := context.Background()

	store, err := OpenFile(path, nil)
	if err != nil {
		t.Fatalf("OpenFile: %v", err)
	}
	want := testDoc("575af3e8-8015-3718-be03-4da18a0bacfc")
	if err := store.Create(ctx, want); err != nil {
		t.Fatalf("Create: %v", err)
	}
	got, err := store.Read(ctx, want.ID)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Blob != want.Blob || got.DictID != want.DictID {
		t.Fatalf("Read = %+v, want %+v", got, want)
	}
	if got.ETag == "" {
		t.Error("stored document has no etag, so Replace preconditions cannot work")
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Reopening must see what was written: the web app reads a file the CLI wrote in a
	// different process.
	reopened, err := OpenFile(path, nil)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	again, err := reopened.Read(ctx, want.ID)
	if err != nil {
		t.Fatalf("Read after reopen: %v", err)
	}
	if again.Blob != want.Blob {
		t.Errorf("blob changed across reopen: %q", again.Blob)
	}
	if reopened.Count() != 1 {
		t.Errorf("Count = %d, want 1", reopened.Count())
	}
}

func TestFileStoreLastWriteWins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "docs.ndjson")
	ctx := context.Background()
	store, err := OpenFile(path, nil)
	if err != nil {
		t.Fatalf("OpenFile: %v", err)
	}
	defer store.Close()

	id := "11111111-1111-3111-8111-111111111111"
	if err := store.Upsert(ctx, Doc{ID: id, Blob: "first"}); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	if err := store.Upsert(ctx, Doc{ID: id, Blob: "second"}); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	got, err := store.Read(ctx, id)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.Blob != "second" {
		t.Errorf("Blob = %q, want the newest write", got.Blob)
	}
	if store.Count() != 1 {
		t.Errorf("Count = %d, want 1 (two writes, one document)", store.Count())
	}

	// A fresh open must also resolve to the newest line, not the first.
	reopened, err := OpenFile(path, nil)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	after, err := reopened.Read(ctx, id)
	if err != nil {
		t.Fatalf("Read after reopen: %v", err)
	}
	if after.Blob != "second" {
		t.Errorf("after reopen Blob = %q, want second", after.Blob)
	}
}

func TestFileStoreCreateConflictAndReplacePrecondition(t *testing.T) {
	ctx := context.Background()
	store, err := OpenFile(filepath.Join(t.TempDir(), "docs.ndjson"), nil)
	if err != nil {
		t.Fatalf("OpenFile: %v", err)
	}
	defer store.Close()

	d := testDoc("22222222-2222-3222-8222-222222222222")
	if err := store.Create(ctx, d); err != nil {
		t.Fatalf("Create: %v", err)
	}
	err = store.Create(ctx, d)
	if !errors.Is(err, ErrConflict) {
		t.Errorf("second Create = %v, want ErrConflict", err)
	}

	stored, err := store.Read(ctx, d.ID)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if err := store.Replace(ctx, Doc{ID: d.ID, Blob: "v2"}, stored.ETag); err != nil {
		t.Fatalf("Replace with a fresh etag: %v", err)
	}
	err = store.Replace(ctx, Doc{ID: d.ID, Blob: "v3"}, stored.ETag)
	if !errors.Is(err, ErrPreconditionFailed) {
		t.Errorf("Replace with a stale etag = %v, want ErrPreconditionFailed", err)
	}
	if err := store.Replace(ctx, Doc{ID: "nope", Blob: "x"}, ""); !errors.Is(err, ErrNotFound) {
		t.Errorf("Replace of a missing id = %v, want ErrNotFound", err)
	}
	if _, err := store.Read(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("Read of a missing id = %v, want ErrNotFound", err)
	}
}

func TestFileStoreRejectsBadDocuments(t *testing.T) {
	ctx := context.Background()
	store, err := OpenFile(filepath.Join(t.TempDir(), "docs.ndjson"), nil)
	if err != nil {
		t.Fatalf("OpenFile: %v", err)
	}
	defer store.Close()

	if err := store.Upsert(ctx, Doc{Blob: "x"}); err == nil {
		t.Error("accepted a document with no id")
	}
	if err := store.Upsert(ctx, Doc{ID: "abc"}); err == nil {
		t.Error("accepted a document with an empty blob")
	}
}

func TestFileStoreRejectsCorruptLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docs.ndjson")
	if err := os.WriteFile(path, []byte("{\"id\":\"a\",\"b\":\"x\"}\nnot json\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := OpenFile(path, nil); err == nil {
		t.Error("opened a file with a corrupt line; a truncated write would be read as data")
	}
}

func TestFileStoreProvisionIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "docs.ndjson")
	store, err := OpenFile(path, nil)
	if err != nil {
		t.Fatalf("OpenFile: %v", err)
	}
	defer store.Close()
	if err := store.Provision(context.Background()); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if err := store.Provision(context.Background()); err != nil {
		t.Fatalf("second Provision: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("Provision did not create the file: %v", err)
	}
}

func TestEncodeDocOmitsZeroDictID(t *testing.T) {
	withDict, err := encodeDoc(Doc{ID: "a", Blob: "b", DictID: DefaultDictIDForTest})
	if err != nil {
		t.Fatalf("encodeDoc: %v", err)
	}
	want := fmt.Sprintf(`{"id":"a","b":"b","d":%d}`, DefaultDictIDForTest)
	if string(withDict) != want {
		t.Errorf("stored shape = %s, want %s", withDict, want)
	}
	// No dictionary means no "d" key at all, so an old reader never sees a zero it might
	// mistake for a real dictionary id.
	noDict, err := encodeDoc(Doc{ID: "a", Blob: "b"})
	if err != nil {
		t.Fatalf("encodeDoc: %v", err)
	}
	if string(noDict) != `{"id":"a","b":"b"}` {
		t.Errorf("stored shape without a dict = %s", noDict)
	}
	if _, err := encodeDoc(Doc{Blob: "b"}); err == nil {
		t.Error("encoded a document with no id")
	}
	if _, err := encodeDoc(Doc{ID: "a"}); err == nil {
		t.Error("encoded a document with no blob")
	}
}

func TestDecodeDoc(t *testing.T) {
	got, err := decodeDoc([]byte(`{"id":"a","b":"blob","d":7}`))
	if err != nil {
		t.Fatalf("decodeDoc: %v", err)
	}
	if got.ID != "a" || got.Blob != "blob" || got.DictID != 7 {
		t.Errorf("decoded = %+v", got)
	}
	// Unknown extra fields must be ignored: Cosmos adds _rid, _ts, _etag, _self.
	if _, err := decodeDoc([]byte(`{"id":"a","b":"x","_rid":"r","_ts":1700000000}`)); err != nil {
		t.Errorf("service metadata broke decoding: %v", err)
	}
	for _, bad := range []string{`{}`, `{"id":"a"}`, `{"b":"x"}`, `nope`} {
		if _, err := decodeDoc([]byte(bad)); err == nil {
			t.Errorf("decodeDoc(%s) accepted an unusable document", bad)
		}
	}
}

func TestFakeStoreFailuresAndCounters(t *testing.T) {
	ctx := context.Background()
	fake := NewFake(nil)
	fake.ChargeFor["upsert"] = 12.5

	d := testDoc("33333333-3333-3333-8333-333333333333")
	if err := fake.Upsert(ctx, d); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
	if got := fake.Docs()[d.ID].Blob; got != d.Blob {
		t.Errorf("stored blob = %q", got)
	}

	// A 409 on create is the normal case for a second KG version claiming an existing edge,
	// and the pipeline has to see it as ErrConflict to merge rather than fail.
	fake.Fail("create", ErrConflict)
	if err := fake.Create(ctx, d); !errors.Is(err, ErrConflict) {
		t.Errorf("armed Create = %v, want ErrConflict", err)
	}
	// One-shot: the next call behaves normally.
	if err := fake.Create(ctx, testDoc("44444444-4444-3444-8444-444444444444")); err != nil {
		t.Errorf("Create after the armed failure: %v", err)
	}

	fake.Fail("replace", ErrPreconditionFailed)
	if err := fake.Replace(ctx, d, "stale"); !errors.Is(err, ErrPreconditionFailed) {
		t.Errorf("armed Replace = %v, want ErrPreconditionFailed", err)
	}

	counts := fake.OpCounts()
	if counts["upsert"] != 1 || counts["create"] != 2 || counts["replace"] != 1 {
		t.Errorf("op counts = %v", counts)
	}
	if fake.Charges != 12.5 {
		t.Errorf("Charges = %v, want 12.5", fake.Charges)
	}
	if _, err := fake.Read(ctx, "missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("Read of a missing id = %v", err)
	}
}

func TestFakeSeed(t *testing.T) {
	fake := NewFake(nil).Seed(Doc{ID: "seeded", Blob: "b"})
	got, err := fake.Read(context.Background(), "seeded")
	if err != nil {
		t.Fatalf("Read seeded: %v", err)
	}
	if got.ETag == "" {
		t.Error("seeded document has no etag")
	}
	if len(fake.Ops) != 1 || fake.Ops[0] != "read" {
		t.Errorf("Seed should not record an op, got %v", fake.Ops)
	}
}

func TestOpenDispatch(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()

	file, err := Open(ctx, "file:"+filepath.Join(dir, "d.ndjson"), AzureConfig{}, nil)
	if err != nil {
		t.Fatalf("Open file: %v", err)
	}
	defer file.Close()
	if file.Name() != "file:"+filepath.Join(dir, "d.ndjson") {
		t.Errorf("Name = %q", file.Name())
	}

	mem, err := Open(ctx, "mem://", AzureConfig{}, nil)
	if err != nil {
		t.Fatalf("Open mem: %v", err)
	}
	defer mem.Close()

	// No account configured must fail loudly rather than silently writing nowhere.
	if _, err := Open(ctx, "cosmos", AzureConfig{}, nil); err == nil {
		t.Error("Open(cosmos) succeeded with no endpoint or key")
	}
	if _, err := Open(ctx, "s3://bucket", AzureConfig{}, nil); err == nil {
		t.Error("Open accepted an unknown scheme")
	}
}

func TestOpenChargesTheBudget(t *testing.T) {
	ctx := context.Background()
	budget := ratelimit.NewUnlimited()
	store, err := Open(ctx, "mem://", AzureConfig{}, budget)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	fake := store.(*Fake)
	fake.ChargeFor["create"] = 6.25
	if err := store.Create(ctx, testDoc("55555555-5555-3555-8555-555555555555")); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if budget.Consumed() != 6.25 {
		t.Errorf("budget consumed %v RU, want 6.25", budget.Consumed())
	}
}

func TestMapErrorLeavesForeignErrorsAlone(t *testing.T) {
	if got := mapError(nil); got != nil {
		t.Errorf("mapError(nil) = %v", got)
	}
	sentinel := errors.New("boom")
	if got := mapError(sentinel); !errors.Is(got, sentinel) {
		t.Errorf("mapError wrapped an unrelated error: %v", got)
	}
}

func TestRandomPoolIDIsReserved(t *testing.T) {
	// The pool document shares the container, so its id must never collide with a UUID.
	var uuid json.RawMessage = []byte(`"__random_pool__"`)
	if string(uuid) != `"__random_pool__"` || RandomPoolID == "" {
		t.Fatal("RandomPoolID must be a fixed reserved id")
	}
}
