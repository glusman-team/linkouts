package pipeline

import (
	"math/rand"
	"sync"
)

// reservoir is a thread-safe Algorithm R sample with deduplication.
//
// It exists because indexing is off on this container: picking a random edge with a query
// would be a full cross-partition scan, so the CLI samples ids while it streams (free, it is
// already touching every document) and the app point-reads the result. Uniformity matters —
// /random is how a reviewer stumbles onto an edge they were not looking for, and a sample
// biased toward the front of the file would only ever show one predicate.
type reservoir struct {
	k int

	mu   sync.Mutex
	ids  []string
	seen map[string]struct{}
	n    int64
	rng  *rand.Rand
}

func newReservoir(k int) *reservoir {
	if k < 1 {
		k = 1
	}
	return &reservoir{
		k:    k,
		ids:  make([]string, 0, k),
		seen: make(map[string]struct{}, k),
		rng:  rand.New(rand.NewSource(rand.Int63())),
	}
}

// offer adds id to the sample. Every distinct id has an equal chance of being held at the end,
// regardless of how many were offered.
func (r *reservoir) offer(id string) {
	if id == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.seen[id]; dup {
		return
	}
	if len(r.ids) < r.k {
		r.ids = append(r.ids, id)
		r.seen[id] = struct{}{}
		r.n++
		return
	}
	// Replace a random slot with probability k/n, which is what makes the sample uniform
	// over a stream of unknown length.
	r.n++
	j := r.rng.Int63n(r.n)
	if j < int64(r.k) {
		delete(r.seen, r.ids[j])
		r.ids[j] = id
		r.seen[id] = struct{}{}
	}
}

// snapshot returns a copy of the sample in arbitrary order.
func (r *reservoir) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.ids))
	copy(out, r.ids)
	return out
}

func (r *reservoir) len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.ids)
}

// offered is how many distinct ids were seen, for the summary line: a 4096-id pool drawn from
// 130k edges should say so.
func (r *reservoir) offered() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.n
}
