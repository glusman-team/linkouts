// Package cosmos is the storage boundary. Everything above it talks to a Store; only the
// azure implementation knows about Cosmos DB, so the whole pipeline is testable offline and
// the web app can read the same documents from a file backend during development.
package cosmos

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

// Sentinel errors. Callers compare with errors.Is, never by string.
var (
	// ErrNotFound is a 404: no document with that id.
	ErrNotFound = errors.New("document not found")
	// ErrConflict is a 409: a create hit an existing id. The pipeline merges instead of
	// failing, because a create-first write against an id another KG version already owns
	// is the normal case, not an error.
	ErrConflict = errors.New("document already exists")
	// ErrPreconditionFailed is a 412: an If-Match etag no longer matches, i.e. someone else
	// wrote the document since it was read.
	ErrPreconditionFailed = errors.New("etag precondition failed")
	// ErrThrottled is a 429 that survived the SDK's own retries.
	ErrThrottled = errors.New("request throttled")
)

// Doc is one Cosmos document: an edge UUID and every version of that edge, compressed into
// one base64 zstd frame. See docs/adr/0001-wire-format.md.
type Doc struct {
	ID     string `json:"id"`
	Blob   string `json:"b"`
	DictID uint32 `json:"d,omitempty"`
	// ETag is service state, never part of the stored JSON.
	ETag string `json:"-"`
}

// RandomPoolID is the reserved document id holding the reservoir-sampled UUIDs that back
// /random. Indexing is off on this container, so a random query would be a full scan; the
// CLI samples once per load and the app point-reads the result.
const RandomPoolID = "__random_pool__"

// Store is the read/write surface the pipeline and the web app share.
type Store interface {
	// Read fetches one document by id, returning ErrNotFound when absent.
	Read(ctx context.Context, id string) (Doc, error)
	// Create writes a new document and returns ErrConflict if the id exists.
	Create(ctx context.Context, d Doc) error
	// Upsert writes the document whether or not it exists.
	Upsert(ctx context.Context, d Doc) error
	// Replace overwrites only when etag still matches; ErrPreconditionFailed otherwise.
	// An empty etag means "no precondition".
	Replace(ctx context.Context, d Doc, etag string) error
	// Provision creates the database and container if they are missing. It is idempotent.
	Provision(ctx context.Context) error
	// Name identifies the backend in logs and in --store output.
	Name() string
	// Close releases resources.
	Close() error
}

// Open builds a Store from a --store spec:
//
//	cosmos                       the configured Cosmos account (requires env, see internal/config)
//	file:/path/to/docs.ndjson    append-only NDJSON, no network, used by tests and local dev
//	mem://                       in-process, for tests that need to inject failures
//
// budget may be nil, which means unlimited.
func Open(ctx context.Context, spec string, cfg AzureConfig, budget ratelimit.Budget) (Store, error) {
	if budget == nil {
		budget = ratelimit.NewUnlimited()
	}
	switch {
	case spec == "" || spec == "cosmos":
		return NewAzure(cfg, budget)
	case strings.HasPrefix(spec, "file:"):
		return OpenFile(strings.TrimPrefix(spec, "file:"), budget)
	case spec == "mem://" || spec == "mem":
		return NewFake(budget), nil
	default:
		return nil, fmt.Errorf("unknown --store spec %q (want cosmos, file:<path>, or mem://)", spec)
	}
}
