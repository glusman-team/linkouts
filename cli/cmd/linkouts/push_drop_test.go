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
