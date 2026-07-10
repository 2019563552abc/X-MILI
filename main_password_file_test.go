package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestReadPasswordFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "password")
	if err := os.WriteFile(path, []byte("correct-horse-battery-staple\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	password, err := readPasswordFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if password != "correct-horse-battery-staple" {
		t.Fatalf("password = %q", password)
	}
}

func TestReadPasswordFileRejectsInsecureMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows does not expose Unix file modes")
	}

	path := filepath.Join(t.TempDir(), "password")
	if err := os.WriteFile(path, []byte("correct-horse-battery-staple"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := readPasswordFile(path); err == nil {
		t.Fatal("expected insecure password file to be rejected")
	}
}
