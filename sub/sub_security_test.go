//go:build cgo

package sub

import (
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
)

func TestStartDoesNotListenWhenSubscriptionsAreDisabled(t *testing.T) {
	if err := database.InitDB(filepath.Join(t.TempDir(), "x-ui.db")); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })

	server := NewServer()
	t.Cleanup(func() { _ = server.Stop() })
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	if server.listener != nil {
		t.Fatalf("subscription listener = %v, want nil while subscriptions are disabled", server.listener.Addr())
	}
}
