//go:build cgo

package database

import (
	"path/filepath"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/util/crypto"
)

func TestInitDBCreatesBootstrapAccountWithoutKnownDefaultPassword(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "x-ui.db")
	if err := InitDB(dbPath); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = CloseDB() })

	var user model.User
	if err := GetDB().First(&user).Error; err != nil {
		t.Fatal(err)
	}
	if user.Username != defaultUsername {
		t.Fatalf("bootstrap username = %q, want %q", user.Username, defaultUsername)
	}
	if crypto.CheckPasswordHash(user.Password, legacyDefaultPassword) {
		t.Fatal("fresh database accepts the legacy admin/admin credential")
	}

	var setting model.Setting
	if err := GetDB().Where("key = ?", BootstrapPendingSettingKey).First(&setting).Error; err != nil {
		t.Fatal(err)
	}
	if setting.Value != "true" {
		t.Fatalf("bootstrap marker = %q, want true", setting.Value)
	}
}

func TestInitDBRotatesLegacyDefaultCredentials(t *testing.T) {
	for _, tc := range []struct {
		name      string
		plaintext bool
	}{
		{name: "bcrypt legacy credential"},
		{name: "plaintext legacy credential", plaintext: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dbPath := filepath.Join(t.TempDir(), "x-ui.db")
			if err := InitDB(dbPath); err != nil {
				t.Fatal(err)
			}

			password := legacyDefaultPassword
			if !tc.plaintext {
				var err error
				password, err = crypto.HashPasswordAsBcrypt(legacyDefaultPassword)
				if err != nil {
					t.Fatal(err)
				}
			}
			if err := GetDB().Model(&model.User{}).
				Where("username = ?", defaultUsername).
				Update("password", password).
				Error; err != nil {
				t.Fatal(err)
			}
			if err := SetBootstrapPending(false); err != nil {
				t.Fatal(err)
			}
			if err := CloseDB(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = CloseDB() })

			if err := InitDB(dbPath); err != nil {
				t.Fatal(err)
			}
			var user model.User
			if err := GetDB().Where("username = ?", defaultUsername).First(&user).Error; err != nil {
				t.Fatal(err)
			}
			if crypto.CheckPasswordHash(user.Password, legacyDefaultPassword) {
				t.Fatal("legacy admin/admin credential was not rotated")
			}
			var setting model.Setting
			if err := GetDB().Where("key = ?", BootstrapPendingSettingKey).First(&setting).Error; err != nil {
				t.Fatal(err)
			}
			if setting.Value != "true" {
				t.Fatalf("bootstrap marker = %q, want true", setting.Value)
			}
		})
	}
}
