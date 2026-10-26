// Command repair-pool-index reconstructs pool-index entries for releases whose pool
// documents survive in the store but whose index entries were lost.
//
// Background: an older load treated "cannot decode the shared index" (wrong dictionary,
// failed read) as "nothing to preserve" and wrote a fresh index, clobbering every other
// graph's entry — twice. Load's writePoolIndex now fails loudly instead, and reserved
// documents are written dictionary-free. This tool restores what the surviving pool
// documents still prove: each release's pool document holds its ids and sampled-at
// timestamp; only the true edge count has to be supplied, from the release's own dataset
// card. Pool documents written before the dict-free switch decode with the dictionary
// stamped on the document itself.
//
// Usage (one-off, run from cli/):
//
//	go run ./tools/repair-pool-index
//
// It reads the current index, verifies each pool document exists, sets the entries below,
// and upserts the index (dictionary-free). Idempotent: rerunning writes the same document.
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
	"github.com/glusman-team/linkouts/cli/internal/ratelimit"
)

// repairs lists one entry per lost release. Edges is the release's true edge count as
// published in its dataset card (drug-approvals-kp and multiomics-kp on huggingface.co/
// SkyeAv, table "Releases"); SampledAt comes from the surviving pool document itself.
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
	{"drugapprovals-kp", "1.25.1", 136317},
	{"multiomics-kp", "3.1.3", 18206965},
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

	index, err := readIndex(ctx, store)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("index holds %d graphs before repair\n", len(index.KGs))

	for _, r := range repairs {
		pool, err := readPool(ctx, store, r.slug, r.label)
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

// readIndex reads the shared index document, resolving the dictionary from the stamp on
// the document itself (see readPool). A missing index means a fresh repair.
func readIndex(ctx context.Context, store cosmos.Store) (codec.PoolIndex, error) {
	var index codec.PoolIndex
	doc, err := store.Read(ctx, cosmos.RandomPoolID)
	if errors.Is(err, cosmos.ErrNotFound) {
		return codec.PoolIndex{Schema: codec.PoolIndexSchema, KGs: map[string]codec.KGPool{}}, nil
	}
	if err != nil {
		return index, err
	}
	dict := []byte(nil)
	if doc.DictID != 0 {
		if doc.DictID != codec.DictID(dictBytes()) {
			return index, fmt.Errorf("index written with dictionary %#x, have %#x", doc.DictID, codec.DictID(dictBytes()))
		}
		dict = dictBytes()
	}
	if err := codec.DecodeJSON(doc.Blob, dict, &index); err != nil {
		return index, err
	}
	if index.KGs == nil {
		index.KGs = map[string]codec.KGPool{}
	}
	return index, nil
}

// readPool reads one release's pool document, resolving the dictionary from the stamp on
// the document itself: the DAKP pools written before the dict-free switch carry
// 0x77140996, everything newer carries none.
func readPool(ctx context.Context, store cosmos.Store, slug, label string) (codec.Pool, error) {
	var pool codec.Pool
	doc, err := store.Read(ctx, cosmos.PoolDocID(slug, label))
	if err != nil {
		return pool, err
	}
	dict := []byte(nil)
	if doc.DictID != 0 {
		if doc.DictID != codec.DictID(dictBytes()) {
			return pool, fmt.Errorf("pool written with dictionary %#x, have %#x", doc.DictID, codec.DictID(dictBytes()))
		}
		dict = dictBytes()
	}
	if err := codec.DecodeJSON(doc.Blob, dict, &pool); err != nil {
		return pool, err
	}
	if pool.Schema != codec.PoolSchema {
		return pool, fmt.Errorf("schema %q, want %q", pool.Schema, codec.PoolSchema)
	}
	return pool, nil
}

// dictBytes loads the DAKP dictionary this repo ships to the web app. The registry file
// name carries the dictionary id; DAKP_DICT overrides the search path.
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
