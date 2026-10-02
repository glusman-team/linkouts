package version

import (
	"testing"
)

func TestParseSplitsKGFromVersion(t *testing.T) {
	cases := []struct {
		in, kg, version string
		parts           []int
	}{
		{"drug-approvals-kg-1.11.2", "drug-approvals-kg", "1.11.2", []int{1, 11, 2}},
		{"multiomics-kg-1.12.0", "multiomics-kg", "1.12.0", []int{1, 12, 0}},
		{"wellness_kg-2.0.1", "wellness_kg", "2.0.1", []int{2, 0, 1}},
		{"kg-1.16.0", "kg", "1.16.0", []int{1, 16, 0}},
	}
	for _, c := range cases {
		got, err := Parse(c.in)
		if err != nil {
			t.Fatalf("Parse(%q): %v", c.in, err)
		}
		if got.KG != c.kg {
			t.Errorf("Parse(%q).KG = %q, want %q", c.in, got.KG, c.kg)
		}
		if v := got.Version(); v != c.version {
			t.Errorf("Parse(%q).Version() = %q, want %q", c.in, v, c.version)
		}
		if len(got.Parts) != len(c.parts) {
			t.Errorf("Parse(%q) parts = %v, want %v", c.in, got.Parts, c.parts)
			continue
		}
		for i, p := range c.parts {
			if got.Parts[i] != p {
				t.Errorf("Parse(%q) part %d = %d, want %d", c.in, i, got.Parts[i], p)
			}
		}
	}
}

func TestParsePreReleaseAndOddKeys(t *testing.T) {
	k, err := Parse("kg-1.0.0-rc1")
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if k.KG != "kg" || k.Suffix != "-rc1" {
		t.Errorf("kg=%q suffix=%q, want kg and -rc1", k.KG, k.Suffix)
	}
	if v := k.Version(); v != "1.0.0-rc1" {
		t.Errorf("Version() = %q", v)
	}

	// No numeric segment at all: still parseable, still orderable, never a panic.
	odd, err := Parse("wellness_kg")
	if err != nil {
		t.Fatalf("Parse(wellness_kg): %v", err)
	}
	if odd.KG != "wellness_kg" {
		t.Errorf("KG = %q", odd.KG)
	}
	if _, err := Parse(""); err == nil {
		t.Error("an empty key was accepted")
	}
}

func TestCompareOrdersNumericallyNotLexically(t *testing.T) {
	// The whole point: lexicographic order says 1.9.0 > 1.16.0, which would make the CLI
	// diff a new release against the wrong base and the UI list versions backwards.
	if got := CompareKeys("kg-1.9.0", "kg-1.16.0"); got >= 0 {
		t.Errorf("Compare(kg-1.9.0, kg-1.16.0) = %d, want negative", got)
	}
	if got := CompareKeys("kg-1.11.2", "kg-1.16.0"); got >= 0 {
		t.Errorf("Compare(kg-1.11.2, kg-1.16.0) = %d, want negative", got)
	}
	if got := CompareKeys("kg-2.0.0", "kg-10.0.0"); got >= 0 {
		t.Errorf("Compare(kg-2.0.0, kg-10.0.0) = %d, want negative", got)
	}
	if got := CompareKeys("kg-1.0.0", "kg-1.0.0"); got != 0 {
		t.Errorf("Compare of equal keys = %d, want 0", got)
	}
	// Different KGs sort by name, so keys from two graphs never interleave.
	if got := CompareKeys("a-kg-9.9.9", "b-kg-0.0.1"); got >= 0 {
		t.Errorf("Compare across KGs = %d, want negative", got)
	}
	// A pre-release precedes its release.
	if got := CompareKeys("kg-1.0.0-rc1", "kg-1.0.0"); got >= 0 {
		t.Errorf("Compare(rc1, release) = %d, want negative", got)
	}
	// A missing trailing segment reads as zero, so 1.2 == 1.2.0.
	if got := CompareKeys("kg-1.2", "kg-1.2.0"); got != 0 {
		t.Errorf("Compare(kg-1.2, kg-1.2.0) = %d, want 0", got)
	}
}

func TestSortAndNewest(t *testing.T) {
	in := []string{"drug-approvals-kg-1.16.0", "drug-approvals-kg-1.9.0", "drug-approvals-kg-1.11.2"}
	got := SortKeys(in)
	want := []string{"drug-approvals-kg-1.9.0", "drug-approvals-kg-1.11.2", "drug-approvals-kg-1.16.0"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("SortKeys = %v, want %v", got, want)
		}
	}
	// The input must not be reordered in place: callers still hold it.
	if in[0] != "drug-approvals-kg-1.16.0" {
		t.Errorf("SortKeys mutated its input: %v", in)
	}
	if got := Newest(in); got != "drug-approvals-kg-1.16.0" {
		t.Errorf("Newest = %q", got)
	}
	if got := Newest(nil); got != "" {
		t.Errorf("Newest(nil) = %q", got)
	}
}

func TestSameKG(t *testing.T) {
	a, _ := Parse("drug-approvals-kg-1.11.2")
	b, _ := Parse("drug-approvals-kg-1.16.0")
	c, _ := Parse("wellness_kg-1.0.0")
	if !SameKG(a, b) {
		t.Error("two releases of one KG were not recognised as the same KG")
	}
	if SameKG(a, c) {
		t.Error("different KGs matched")
	}
}
