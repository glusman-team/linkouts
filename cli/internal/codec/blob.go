package codec

import (
	"encoding/base64"
	"fmt"
	"sort"

	"github.com/klauspost/compress/zstd"
)

// SchemaVersion is stamped into every blob so a reader can refuse a format it does not
// implement instead of mis-decoding one.
const SchemaVersion = "edgelinkouts.blob/1"

// DefaultZstdLevel is zstd's level 3: near-LZ4 speed with a ratio that matters at this
// document size. Override with --zstd-level.
const DefaultZstdLevel = 3

// Blob is one Cosmos document: every version of one edge, keyed by KGX release.
// Cosmos indexes only `id`, so the whole document is read in one point read and every
// version toggle in the UI is free after that.
type Blob struct {
	Schema   string           `json:"schema"`
	Versions map[string]Entry `json:"versions"`
}

// MarshalJSON implements json.Marshaler so Entry's wire form ("$t"/"$set"/... or a full
// document) is what lands in the blob rather than Go field names.
func (e Entry) MarshalJSON() ([]byte, error) { return canon.Marshal(e.Wire()) }

// UnmarshalJSON implements json.Unmarshaler.
func (e *Entry) UnmarshalJSON(b []byte) error {
	v, err := ParseAny(b)
	if err != nil {
		return err
	}
	parsed, err := EntryFromWire(v)
	if err != nil {
		return err
	}
	*e = parsed
	return nil
}

// NewBlob builds a blob whose first version is stored in full.
func NewBlob(version string, doc Doc) (*Blob, error) {
	if err := CheckNoNulls(doc, "$"); err != nil {
		return nil, err
	}
	return &Blob{Schema: SchemaVersion, Versions: map[string]Entry{version: {Full: Clone(doc).(Doc)}}}, nil
}

// AddVersion stores doc under version, diffing against baseVersion/baseDoc (usually the
// previously stored version of this edge) and keeping whichever of full-or-delta is
// smaller. baseDoc may be nil, which stores this version in full.
func (b *Blob) AddVersion(version, baseVersion string, doc, baseDoc Doc) error {
	if version == "" {
		return fmt.Errorf("empty version key")
	}
	if _, dup := b.Versions[version]; dup {
		return fmt.Errorf("version %q already present", version)
	}
	if err := CheckNoNulls(doc, "$"); err != nil {
		return fmt.Errorf("version %s: %w", version, err)
	}
	entry, err := Diff(baseVersion, baseDoc, doc)
	if err != nil {
		return fmt.Errorf("version %s: %w", version, err)
	}
	// A delta whose base is not in this blob can never be resolved, so refuse it at write
	// time instead of at read time in production.
	if !entry.IsFull() {
		if _, ok := b.Versions[entry.Base]; !ok {
			return fmt.Errorf("version %s: delta targets %q, which is not stored in this blob", version, entry.Base)
		}
	}
	b.Versions[version] = entry
	return nil
}

// VersionKeys returns the stored versions in insertion-stable sorted order. Sorted, not
// semver-sorted: KGX versions are opaque strings here, and the UI orders them itself.
func (b *Blob) VersionKeys() []string {
	out := make([]string, 0, len(b.Versions))
	for k := range b.Versions {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Resolve expands version into a full document, walking the delta chain. It refuses cycles
// and unknown targets rather than looping forever on a corrupt blob.
func (b *Blob) Resolve(version string) (Doc, error) {
	return b.resolve(version, map[string]bool{})
}

// resolve carries the visited set through the recursion. A per-call set would let a cycle
// recurse until the goroutine stack dies, which is exactly what a corrupt blob from the
// network should not be able to do.
func (b *Blob) resolve(version string, seen map[string]bool) (Doc, error) {
	if seen[version] {
		return nil, fmt.Errorf("delta cycle at version %q", version)
	}
	// Mark for the duration of this path only: a blob where two versions share one base
	// is a diamond, not a cycle, and un-marking on the way out keeps those resolvable.
	seen[version] = true
	defer delete(seen, version)
	entry, ok := b.Versions[version]
	if !ok {
		return nil, fmt.Errorf("version %q not in blob (have %v)", version, b.VersionKeys())
	}
	if entry.IsFull() {
		out, ok := Clone(entry.Full).(Doc)
		if !ok {
			return nil, fmt.Errorf("version %q: full payload did not clone to an object", version)
		}
		return out, nil
	}
	base, err := b.resolve(entry.Base, seen)
	if err != nil {
		return nil, err
	}
	out, err := Apply(base, entry)
	if err != nil {
		return nil, fmt.Errorf("version %q: %w", version, err)
	}
	return out, nil
}

// Encode serializes the blob to the stored form: base64(zstd(canonical JSON)). The dict may
// be nil, in which case plain zstd is used; the reader must use the same choice, which is
// why the document row carries dict_id alongside the blob.
func (b *Blob) Encode(dict []byte, level int) (string, error) {
	if b.Schema == "" {
		b.Schema = SchemaVersion
	}
	return EncodeJSON(b, dict, level)
}

// DecodeBlob is the inverse of Encode.
func DecodeBlob(encoded string, dict []byte) (*Blob, error) {
	comp, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("blob is not valid base64: %w", err)
	}
	raw, err := Decompress(comp, dict)
	if err != nil {
		return nil, err
	}
	var b Blob
	if err := canon.Unmarshal(raw, &b); err != nil {
		return nil, fmt.Errorf("unmarshal blob: %w", err)
	}
	if b.Schema != SchemaVersion {
		return nil, fmt.Errorf("unsupported blob schema %q, want %q", b.Schema, SchemaVersion)
	}
	if len(b.Versions) == 0 {
		return nil, fmt.Errorf("blob carries no versions")
	}
	for _, v := range b.VersionKeys() {
		if _, err := b.Resolve(v); err != nil {
			return nil, err
		}
	}
	return &b, nil
}

// Compress zstd-compresses raw, optionally against a trained dictionary.
func Compress(raw, dict []byte, level int) ([]byte, error) {
	if level == 0 {
		level = DefaultZstdLevel
	}
	opts := []zstd.EOption{zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(level))}
	if len(dict) > 0 {
		opts = append(opts, zstd.WithEncoderDict(dict))
	}
	enc, err := zstd.NewWriter(nil, opts...)
	if err != nil {
		return nil, fmt.Errorf("zstd encoder: %w", err)
	}
	// EncodeAll buffers, so Close only has to release the encoder; it is still checked,
	// because a Close failure here would mean the frame was never finished.
	compressed := enc.EncodeAll(raw, nil)
	if err := enc.Close(); err != nil {
		return nil, fmt.Errorf("zstd encoder close: %w", err)
	}
	return compressed, nil
}

// Decompress is the inverse of Compress. dict must match what was used to compress; a
// dict-compressed frame decoded without it fails loudly rather than producing garbage.
func Decompress(comp, dict []byte) ([]byte, error) {
	var opts []zstd.DOption
	if len(dict) > 0 {
		opts = append(opts, zstd.WithDecoderDicts(dict))
	}
	dec, err := zstd.NewReader(nil, opts...)
	if err != nil {
		return nil, fmt.Errorf("zstd decoder: %w", err)
	}
	defer dec.Close()
	out, err := dec.DecodeAll(comp, nil)
	if err != nil {
		return nil, fmt.Errorf("zstd decode: %w", err)
	}
	return out, nil
}

// PoolSchema identifies the reserved __random_pool__ document, which holds reservoir-sampled
// edge ids rather than a version map. Indexing is off on this container, so a random pick
// would otherwise be a cross-partition scan.
const PoolSchema = "edgelinkouts.pool/1"

// EncodeJSON is the generic form of Blob.Encode: base64(zstd(canonical JSON of v)). The pool
// document and any future reserved documents use it so every stored frame is built the same
// way and reads back with the same dictionary rules.
func EncodeJSON(v any, dict []byte, level int) (string, error) {
	raw, err := Marshal(v)
	if err != nil {
		return "", err
	}
	comp, err := Compress(raw, dict, level)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(comp), nil
}

// DecodeJSON is the inverse of EncodeJSON.
func DecodeJSON(encoded string, dict []byte, v any) error {
	comp, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return fmt.Errorf("payload is not valid base64: %w", err)
	}
	raw, err := Decompress(comp, dict)
	if err != nil {
		return err
	}
	if err := canon.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("unmarshal payload: %w", err)
	}
	return nil
}

// Pool is the reserved document that backs /random.
type Pool struct {
	Schema    string   `json:"schema"`
	Key       string   `json:"key"`
	SampledAt string   `json:"sampled_at"`
	IDs       []string `json:"ids"`
}
