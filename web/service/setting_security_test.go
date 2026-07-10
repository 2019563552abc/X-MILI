//go:build cgo

package service

import (
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
)

func setupSecuritySettingsDB(t *testing.T) {
	t.Helper()
	if err := database.InitDB(filepath.Join(t.TempDir(), "x-ui.db")); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })
}

func TestFreshSettingsUseSafePanelAndSubscriptionDefaults(t *testing.T) {
	setupSecuritySettingsDB(t)
	settings := &SettingService{}

	listen, err := settings.GetListen()
	if err != nil {
		t.Fatal(err)
	}
	if listen != "127.0.0.1" {
		t.Fatalf("web listen = %q, want loopback", listen)
	}

	for name, get := range map[string]func() (bool, error){
		"subEnable":      settings.GetSubEnable,
		"subJsonEnable":  settings.GetSubJsonEnable,
		"subClashEnable": settings.GetSubClashEnable,
	} {
		value, err := get()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if value {
			t.Fatalf("%s = true, want false by default", name)
		}
	}

	subListen, err := settings.GetSubListen()
	if err != nil {
		t.Fatal(err)
	}
	if subListen != "127.0.0.1" {
		t.Fatalf("subscription listen = %q, want loopback", subListen)
	}
}

func TestUpdateFirstUserCompletesBootstrap(t *testing.T) {
	setupSecuritySettingsDB(t)
	users := &UserService{}
	if err := users.UpdateFirstUser("operator", "correct horse battery staple"); err != nil {
		t.Fatal(err)
	}

	pending, err := (&SettingService{}).GetBootstrapPending()
	if err != nil {
		t.Fatal(err)
	}
	if pending {
		t.Fatal("bootstrap marker remains set after credentials were updated")
	}
	if user, err := users.CheckUser("operator", "correct horse battery staple", ""); err != nil || user == nil {
		t.Fatalf("configured user cannot authenticate: user=%v err=%v", user, err)
	}
}
