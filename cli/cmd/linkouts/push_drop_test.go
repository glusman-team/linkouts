package main

import (
	"context"
	"strings"
	"testing"

	"github.com/glusman-team/linkouts/cli/internal/cosmos"
)

// drop-container is the cutover cleanup; against anything but Cosmos it must refuse rather
// than silently doing nothing, because a file store has no container to drop.
func TestDropContainerRefusesNonCosmosStores(t *testing.T) {
	err := dropContainer(context.Background(), cosmos.NewFake(nil), true)
	if err == nil || !strings.Contains(err.Error(), "only works against Cosmos") {
		t.Fatalf("got %v", err)
	}
}

// The confirmation gate: a non-terminal stdin without --yes must never write.
func TestPushRefusesPipedStdinWithoutYes(t *testing.T) {
	ok, err := confirmPrompt("push?", false)
	if err == nil {
		t.Fatalf("expected a refusal, got ok=%v", ok)
	}
}

// --dry-run promises "delete nothing". Paired with --drop-container it must refuse up front,
// before resolving config or opening a store, rather than dropping the container.
//
// The store spec is an in-memory fake and every Cosmos variable is blanked: a test of a
// destructive command must be structurally unable to reach a real account even if the
// guard under test regresses (the first draft of this test, run from a shell with direnv
// credentials loaded and the guard still missing, did exactly that).
func TestPurgeRefusesDryRunWithDropContainer(t *testing.T) {
	for _, k := range []string{
		"COSMOS_PRIMARY_CONNECTION_STRING_RW", "COSMOS_PRIMARY_CONNECTION_STRING_R",
		"COSMOS_ENDPOINT", "COSMOS_KEY", "COSMOS_READ_ONLY_KEY", "COSMOS_CONTAINER", "LINKOUTS_STORE",
	} {
		t.Setenv(k, "")
	}
	g := &globals{storeSpec: "mem://"}
	err := runPurge(context.Background(), g, &purgeFlags{dropContainer: true, dryRun: true, yes: true})
	if err == nil || !strings.Contains(err.Error(), "--dry-run cannot be combined with --drop-container") {
		t.Fatalf("got %v", err)
	}
}
