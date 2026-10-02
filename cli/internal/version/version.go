// Package version parses and orders the "<kg>-<version>" keys that identify one release of
// one knowledge graph. Both the CLI (which version a delta is based on) and the web app
// (which display config to use, which order to list versions in) need the same answers, so
// the rules live in one place and the Elixir side mirrors them under a contract test.
package version

import (
	"fmt"
	"strconv"
	"strings"
)

// Key is a parsed "<kg>-<version>" identifier, e.g. drug-approvals-kg-1.11.2.
type Key struct {
	Raw string
	KG  string
	// Parts is the dotted version split into integers where possible. "1.11.2" becomes
	// [1 11 2]; a non-numeric part is kept as 0 with Suffix holding the text.
	Parts []int
	// Suffix carries any non-numeric trailing text ("1.0.0-rc1" -> "-rc1").
	Suffix string
}

// Parse splits a key at the last hyphen that begins a numeric segment. KG names contain
// hyphens ("drug-approvals-kg"), versions start with a digit, so that boundary is
// unambiguous — and splitting on the last hyphen alone would break on "1.0.0-rc1".
func Parse(key string) (Key, error) {
	if key == "" {
		return Key{}, fmt.Errorf("empty version key")
	}
	k := Key{Raw: key}
	cut := -1
	for i := len(key) - 1; i > 0; i-- {
		if key[i-1] == '-' && i < len(key) && key[i] >= '0' && key[i] <= '9' {
			cut = i
			break
		}
	}
	if cut < 0 {
		// No numeric segment: treat the whole thing as a KG name with an unparseable version.
		// Callers that need ordering still get a deterministic answer (compare as text).
		k.KG = key
		k.Suffix = key
		return k, nil
	}
	k.KG = key[:cut-1]
	ver := key[cut:]
	k.Parts, k.Suffix = parseVersion(ver)
	return k, nil
}

// parseVersion splits "1.11.2-rc1" into [1 11 2] and "-rc1".
func parseVersion(v string) ([]int, string) {
	var parts []int
	suffix := ""
	dotted := v
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		dotted, suffix = v[:i], v[i:]
	}
	for _, seg := range strings.Split(dotted, ".") {
		n, err := strconv.Atoi(seg)
		if err != nil {
			// A non-numeric segment ends numeric comparison; keep the text so ordering is
			// still total and deterministic.
			if suffix == "" {
				suffix = seg
			}
			parts = append(parts, 0)
			continue
		}
		parts = append(parts, n)
	}
	return parts, suffix
}

// String returns the original key.
func (k Key) String() string { return k.Raw }

// Version renders the version part alone ("1.11.2"), which is what the UI shows.
func (k Key) Version() string {
	if len(k.Parts) == 0 {
		return strings.TrimPrefix(k.Raw, k.KG)
	}
	nums := make([]string, len(k.Parts))
	for i, p := range k.Parts {
		nums[i] = strconv.Itoa(p)
	}
	return strings.Join(nums, ".") + k.Suffix
}

// Compare orders two keys: by KG name first, then by numeric version parts, then by suffix
// text. It is a total order, so sorting a key list is deterministic — which matters because
// the CLI writes deltas against "the newest other version" and the UI lists versions in this
// order.
func Compare(a, b Key) int {
	if c := strings.Compare(a.KG, b.KG); c != 0 {
		return c
	}
	for i := range max(len(a.Parts), len(b.Parts)) {
		var av, bv int
		if i < len(a.Parts) {
			av = a.Parts[i]
		}
		if i < len(b.Parts) {
			bv = b.Parts[i]
		}
		if av != bv {
			if av < bv {
				return -1
			}
			return 1
		}
	}
	return compareSuffix(a.Suffix, b.Suffix)
}

// compareSuffix orders the text after the numeric parts. An absent suffix means a final
// release, which sorts AFTER any pre-release: 1.0.0-rc1 < 1.0.0. A plain string comparison
// gets this backwards, because "" sorts before "-rc1".
func compareSuffix(a, b string) int {
	switch {
	case a == b:
		return 0
	case a == "":
		return 1 // a is the release, b is a pre-release
	case b == "":
		return -1
	default:
		return strings.Compare(a, b)
	}
}

// CompareKeys parses and compares two raw keys. Unparseable keys fall back to text order, so
// a malformed key can never make a sort panic or loop.
func CompareKeys(a, b string) int {
	pa, erra := Parse(a)
	pb, errb := Parse(b)
	if erra != nil || errb != nil {
		return strings.Compare(a, b)
	}
	return Compare(pa, pb)
}

// SortKeys orders keys oldest first.
func SortKeys(keys []string) []string {
	out := append([]string(nil), keys...)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && CompareKeys(out[j-1], out[j]) > 0; j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out
}

// Newest returns the highest-ordering key, or "" when there are none.
func Newest(keys []string) string {
	best := ""
	for _, k := range keys {
		if best == "" || CompareKeys(k, best) > 0 {
			best = k
		}
	}
	return best
}

// SameKG reports whether two keys belong to the same knowledge graph, which is what decides
// whether a delta between them is even meaningful.
func SameKG(a, b Key) bool { return a.KG == b.KG }
