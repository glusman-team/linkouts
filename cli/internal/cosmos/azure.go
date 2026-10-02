package cosmos

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"

	"github.com/glusman-team/edge-linkouts/cli/internal/config"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

// maxSDKRetries is raised above the SDK default of 3 because a bulk load is exactly the
// workload that hits 429s, and the SDK's backoff already honours x-ms-retry-after-ms
// (ADR 0002). Retrying here too would double the wait and hide throttling from the budget.
const maxSDKRetries = 5

// AzureStore is the Cosmos DB backend. Writes use the read-write key; the web app never
// touches this type and uses the read-only key over REST instead.
type AzureStore struct {
	cfg       config.Cosmos
	client    *azcosmos.Client
	container *azcosmos.ContainerClient
	budget    ratelimit.Budget
}

var _ Store = (*AzureStore)(nil)

// AzureConfig is the subset of config.Cosmos this package needs, kept as an alias so the
// constructor signature stays short.
type AzureConfig = config.Cosmos

// NewAzure builds a client. It performs no I/O: the first request is Provision or a read.
func NewAzure(cfg AzureConfig, budget ratelimit.Budget) (*AzureStore, error) {
	if !cfg.Ready() {
		return nil, errors.New("cosmos store needs an endpoint and a key: set COSMOS_PRIMARY_CONNECTION_STRING_RW (see .envrc.example)")
	}
	if budget == nil {
		budget = ratelimit.NewUnlimited()
	}
	cred, err := azcosmos.NewKeyCredential(cfg.Key)
	if err != nil {
		return nil, fmt.Errorf("cosmos key: %w", err)
	}
	client, err := azcosmos.NewClientWithKey(cfg.Endpoint, cred, &azcosmos.ClientOptions{
		ClientOptions: azcore.ClientOptions{
			// Retry is a value, not a pointer, in this azcore version.
			Retry: policy.RetryOptions{MaxRetries: maxSDKRetries},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("cosmos client for %s: %w", cfg.Endpoint, err)
	}
	db, err := client.NewDatabase(cfg.Database)
	if err != nil {
		return nil, fmt.Errorf("database handle %s: %w", cfg.Database, err)
	}
	container, err := db.NewContainer(cfg.Container)
	if err != nil {
		return nil, fmt.Errorf("container handle %s/%s: %w", cfg.Database, cfg.Container, err)
	}
	return &AzureStore{cfg: cfg, client: client, container: container, budget: budget}, nil
}

// Provision creates the database and container if they are missing. Both calls treat 409 as
// success, so `linkouts init` is safe to re-run — and safe to run against an account that
// already has the container from a previous project.
//
// Throughput is manual at cfg.Throughput on the container. On the free tier the first
// 1000 RU/s is free, so 1000 here costs nothing and leaves the account's whole allowance
// to this container (ADR 0002).
func (s *AzureStore) Provision(ctx context.Context) error {
	throughput := azcosmos.NewManualThroughputProperties(s.cfg.Throughput)
	// v1.5.0 has no *IfNotExists variants; 409 is the "already exists" answer, and both
	// creates are therefore idempotent by construction. CreateDatabase is a method on the
	// client, CreateContainer on the database handle.
	_, err := s.client.CreateDatabase(ctx, azcosmos.DatabaseProperties{ID: s.cfg.Database},
		&azcosmos.CreateDatabaseOptions{ThroughputProperties: &throughput})
	if err != nil && !errors.Is(mapError(err), ErrConflict) {
		return fmt.Errorf("create database %s: %w", s.cfg.Database, mapError(err))
	}
	db, err := s.client.NewDatabase(s.cfg.Database)
	if err != nil {
		return fmt.Errorf("database handle %s: %w", s.cfg.Database, err)
	}
	// Indexing is off for everything but id: this workload is point reads only, and every
	// indexed path is RU charged on every write.
	indexing := &azcosmos.IndexingPolicy{
		Automatic:     false,
		IndexingMode:  azcosmos.IndexingModeNone,
		ExcludedPaths: []azcosmos.ExcludedPath{{Path: "/*"}},
	}
	_, err = db.CreateContainer(ctx, azcosmos.ContainerProperties{
		ID:                     s.cfg.Container,
		PartitionKeyDefinition: azcosmos.PartitionKeyDefinition{Paths: []string{config.PartitionKeyPath}},
		IndexingPolicy:         indexing,
	}, &azcosmos.CreateContainerOptions{ThroughputProperties: &throughput})
	if err != nil && !errors.Is(mapError(err), ErrConflict) {
		return fmt.Errorf("create container %s: %w", s.cfg.Container, mapError(err))
	}
	return nil
}

// Read is a single point read: one partition key, one id, ~1 RU for a small document.
func (s *AzureStore) Read(ctx context.Context, id string) (Doc, error) {
	resp, err := s.container.ReadItem(ctx, azcosmos.NewPartitionKeyString(id), id, nil)
	s.charge(ctx, resp.RequestCharge)
	if err != nil {
		return Doc{}, mapError(err)
	}
	doc, err := decodeDoc(resp.Value)
	if err != nil {
		return Doc{}, fmt.Errorf("%s: %w", id, err)
	}
	doc.ETag = string(resp.ETag)
	return doc, nil
}

// Create writes a new document. ErrConflict means the id already exists, which the pipeline
// treats as "merge into the existing blob", not as failure.
func (s *AzureStore) Create(ctx context.Context, d Doc) error {
	payload, err := encodeDoc(d)
	if err != nil {
		return err
	}
	resp, err := s.container.CreateItem(ctx, azcosmos.NewPartitionKeyString(d.ID), payload, nil)
	s.charge(ctx, resp.RequestCharge)
	if err != nil {
		return mapError(err)
	}
	return nil
}

// Upsert writes whether or not the document exists. It costs more than Create on a miss and
// cannot detect a lost race, so the pipeline prefers Create-then-merge.
func (s *AzureStore) Upsert(ctx context.Context, d Doc) error {
	payload, err := encodeDoc(d)
	if err != nil {
		return err
	}
	resp, err := s.container.UpsertItem(ctx, azcosmos.NewPartitionKeyString(d.ID), payload, nil)
	s.charge(ctx, resp.RequestCharge)
	if err != nil {
		return mapError(err)
	}
	return nil
}

// Replace overwrites under an If-Match precondition. ErrPreconditionFailed means another
// writer moved the document; the caller must re-read, re-merge, and retry.
func (s *AzureStore) Replace(ctx context.Context, d Doc, etag string) error {
	payload, err := encodeDoc(d)
	if err != nil {
		return err
	}
	var opts *azcosmos.ItemOptions
	if etag != "" {
		match := azcore.ETag(etag)
		opts = &azcosmos.ItemOptions{IfMatchEtag: &match}
	}
	resp, err := s.container.ReplaceItem(ctx, azcosmos.NewPartitionKeyString(d.ID), d.ID, payload, opts)
	s.charge(ctx, resp.RequestCharge)
	if err != nil {
		return mapError(err)
	}
	return nil
}

// Name identifies the account and container in logs.
func (s *AzureStore) Name() string {
	return fmt.Sprintf("cosmos://%s/%s/%s", s.cfg.Endpoint, s.cfg.Database, s.cfg.Container)
}

// Close is a no-op: the SDK client holds no OS resources beyond the HTTP transport.
func (s *AzureStore) Close() error { return nil }

// charge debits the actual RU the service reported. Charges are debited even when the call
// failed, because Cosmos bills 409s and 412s too — ignoring them would let a run overshoot
// its budget during a merge storm.
func (s *AzureStore) charge(ctx context.Context, ru float32) {
	if ru <= 0 {
		return
	}
	// Errors here are only ever "context cancelled", and a cancelled context is already
	// failing the caller's loop, so the charge is recorded best-effort.
	_ = s.budget.Take(ctx, float64(ru))
}

// encodeDoc renders the stored shape exactly as ADR 0001 specifies: id, b, and d only when
// a dictionary was used.
func encodeDoc(d Doc) ([]byte, error) {
	if d.ID == "" {
		return nil, errors.New("document has no id")
	}
	if d.Blob == "" {
		return nil, fmt.Errorf("%s: empty blob", d.ID)
	}
	payload := struct {
		ID     string `json:"id"`
		Blob   string `json:"b"`
		DictID uint32 `json:"d,omitempty"`
	}{d.ID, d.Blob, d.DictID}
	b, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", d.ID, err)
	}
	return b, nil
}

func decodeDoc(raw []byte) (Doc, error) {
	var payload struct {
		ID     string `json:"id"`
		Blob   string `json:"b"`
		DictID uint32 `json:"d"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return Doc{}, fmt.Errorf("decode stored document: %w", err)
	}
	if payload.ID == "" || payload.Blob == "" {
		return Doc{}, fmt.Errorf("stored document is missing id or b")
	}
	return Doc{ID: payload.ID, Blob: payload.Blob, DictID: payload.DictID}, nil
}

// mapError translates an azcore.ResponseError into this package's sentinels so callers
// never import azcore and never match on status codes by hand.
func mapError(err error) error {
	if err == nil {
		return nil
	}
	var rerr *azcore.ResponseError
	if errors.As(err, &rerr) {
		switch rerr.StatusCode {
		case http.StatusNotFound:
			return fmt.Errorf("%w (%d)", ErrNotFound, rerr.StatusCode)
		case http.StatusConflict:
			return fmt.Errorf("%w (%d)", ErrConflict, rerr.StatusCode)
		case http.StatusPreconditionFailed:
			return fmt.Errorf("%w (%d)", ErrPreconditionFailed, rerr.StatusCode)
		case http.StatusTooManyRequests:
			return fmt.Errorf("%w after %d retries (retry-after %dms)", ErrThrottled, maxSDKRetries, retryAfterMs(rerr))
		}
	}
	return err
}

// retryAfterMs reads the throttle hint the service sent. It is reported in the error so a
// throttled run says how long to wait instead of just failing.
func retryAfterMs(rerr *azcore.ResponseError) int {
	if rerr.RawResponse == nil {
		return 0
	}
	for _, h := range []string{"x-ms-retry-after-ms", "retry-after-ms"} {
		if v := rerr.RawResponse.Header.Get(h); v != "" {
			if ms, err := strconv.Atoi(v); err == nil {
				return ms
			}
		}
	}
	return 0
}

// IsThrottled reports whether err is a 429 that outlasted the SDK's retries.
func IsThrottled(err error) bool { return errors.Is(err, ErrThrottled) }
