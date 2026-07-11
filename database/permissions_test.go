package database

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestPrepareDatabaseStorageHardensExistingFiles(t *testing.T) {
	requireUnixPermissionChecks(t)

	dataDir := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(dataDir, 0o755); err != nil {
		t.Fatal(err)
	}
	dbPath := filepath.Join(dataDir, "x-ui.db")
	for _, suffix := range sqliteFileSuffixes {
		if err := os.WriteFile(dbPath+suffix, []byte("preserve me"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dbPath+suffix, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := prepareDatabaseStorage(dbPath); err != nil {
		t.Fatal(err)
	}

	assertPermissions(t, dataDir, privateDirectoryMode)
	for _, suffix := range sqliteFileSuffixes {
		filePath := dbPath + suffix
		assertPermissions(t, filePath, privateDatabaseMode)
		contents, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if string(contents) != "preserve me" {
			t.Fatalf("%s was modified while permissions were hardened", filePath)
		}
	}
}

func TestPrepareDatabaseStorageCreatesPrivateDirectoryAndFile(t *testing.T) {
	requireUnixPermissionChecks(t)

	dbPath := filepath.Join(t.TempDir(), "new", "x-ui.db")
	if err := prepareDatabaseStorage(dbPath); err != nil {
		t.Fatal(err)
	}

	assertPermissions(t, filepath.Dir(dbPath), privateDirectoryMode)
	assertPermissions(t, dbPath, privateDatabaseMode)
}

func TestPrepareDatabaseStorageRejectsSymlinkDatabase(t *testing.T) {
	requireUnixPermissionChecks(t)

	dataDir := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(dataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(t.TempDir(), "target.db")
	if err := os.WriteFile(target, []byte("do not follow"), 0o600); err != nil {
		t.Fatal(err)
	}
	dbPath := filepath.Join(dataDir, "x-ui.db")
	if err := os.Symlink(target, dbPath); err != nil {
		t.Fatal(err)
	}

	if err := prepareDatabaseStorage(dbPath); err == nil {
		t.Fatal("expected a symlink database path to be rejected")
	}
	contents, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "do not follow" {
		t.Fatal("symlink target was modified")
	}
}

func TestPrepareDatabaseStorageRejectsFilesystemRoot(t *testing.T) {
	root := filepath.VolumeName(t.TempDir()) + string(os.PathSeparator)
	if err := prepareDatabaseStorage(filepath.Join(root, "x-mili-permission-test.db")); err == nil {
		t.Fatal("expected a filesystem-root database directory to be rejected")
	}
}

func requireUnixPermissionChecks(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Windows does not expose Unix permission bits")
	}
}

func assertPermissions(t *testing.T, filePath string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(filePath)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("permissions for %s = %04o, want %04o", filePath, got, want)
	}
}
