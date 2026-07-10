package database

import (
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/util/crypto"
)

func TestHasLegacyDefaultCredentialRecognizesPlaintextAndBcryptValues(t *testing.T) {
	hash, err := crypto.HashPasswordAsBcrypt(legacyDefaultPassword)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}

	for _, user := range []model.User{
		{Username: defaultUsername, Password: legacyDefaultPassword},
		{Username: defaultUsername, Password: hash},
	} {
		if !hasLegacyDefaultCredential(user) {
			t.Fatalf("legacy credential was not recognized for %#v", user)
		}
	}

	for _, user := range []model.User{
		{Username: "operator", Password: hash},
		{Username: defaultUsername, Password: mustHashNonDefaultPassword(t)},
	} {
		if hasLegacyDefaultCredential(user) {
			t.Fatalf("non-default credential was incorrectly recognized for %#v", user)
		}
	}
}

func mustHashNonDefaultPassword(t *testing.T) string {
	t.Helper()
	hash, err := crypto.HashPasswordAsBcrypt("not-the-legacy-password")
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	return hash
}
