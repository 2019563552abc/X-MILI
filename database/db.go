// Package database provides database initialization, migration, and management utilities
// for the 3x-ui panel using GORM with SQLite.
package database

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"

	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/util/crypto"
	"github.com/mhsanaei/3x-ui/v2/util/random"
	"github.com/mhsanaei/3x-ui/v2/xray"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

var db *gorm.DB

const (
	defaultUsername                   = "admin"
	legacyDefaultPassword             = "admin"
	privateDirectoryMode  os.FileMode = 0o700
	privateDatabaseMode   os.FileMode = 0o600

	// BootstrapPendingSettingKey marks an installation whose initial panel
	// credentials still need to be configured by the installer or CLI.
	BootstrapPendingSettingKey = "bootstrapPending"
)

var sqliteFileSuffixes = [...]string{"", "-journal", "-wal", "-shm"}

func initModels() error {
	models := []any{
		&model.User{},
		&model.Inbound{},
		&model.OutboundTraffics{},
		&model.Setting{},
		&model.InboundClientIps{},
		&xray.ClientTraffic{},
		&model.HistoryOfSeeders{},
		&model.CustomGeoResource{},
	}
	for _, model := range models {
		if err := db.AutoMigrate(model); err != nil {
			log.Printf("Error auto migrating model: %v", err)
			return err
		}
	}
	return nil
}

// initUser creates a bootstrap-only admin user if the users table is empty.
// Its password is random and intentionally never printed or logged. The
// installer uses BootstrapPendingSettingKey to replace it with operator-chosen
// credentials before exposing the panel.
func initUser() error {
	empty, err := isTableEmpty("users")
	if err != nil {
		log.Printf("Error checking if users table is empty: %v", err)
		return err
	}
	if empty {
		hashedPassword, err := crypto.HashPasswordAsBcrypt(random.Seq(32))

		if err != nil {
			log.Printf("Error hashing bootstrap password: %v", err)
			return err
		}

		user := &model.User{
			Username: defaultUsername,
			Password: hashedPassword,
		}
		return db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Create(user).Error; err != nil {
				return err
			}
			return setBootstrapPending(tx, true)
		})
	}
	return nil
}

func setBootstrapPending(tx *gorm.DB, pending bool) error {
	setting := &model.Setting{}
	err := tx.Where("key = ?", BootstrapPendingSettingKey).First(setting).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return tx.Create(&model.Setting{
			Key:   BootstrapPendingSettingKey,
			Value: strconv.FormatBool(pending),
		}).Error
	}
	if err != nil {
		return err
	}
	return tx.Model(setting).Update("value", strconv.FormatBool(pending)).Error
}

// SetBootstrapPending updates the initial-credential setup marker outside an
// existing transaction.
func SetBootstrapPending(pending bool) error {
	return setBootstrapPending(db, pending)
}

// SetBootstrapPendingTx updates the initial-credential setup marker in the
// caller's transaction so credential changes and marker changes are atomic.
func SetBootstrapPendingTx(tx *gorm.DB, pending bool) error {
	return setBootstrapPending(tx, pending)
}

func hasLegacyDefaultCredential(user model.User) bool {
	return user.Username == defaultUsername &&
		(user.Password == legacyDefaultPassword || crypto.CheckPasswordHash(user.Password, legacyDefaultPassword))
}

// rotateLegacyDefaultCredentials replaces the previously shipped admin/admin
// credentials with random bootstrap passwords. It runs after the bcrypt seeder
// so both old plaintext and bcrypt-backed defaults are recognized.
func rotateLegacyDefaultCredentials() error {
	return db.Transaction(func(tx *gorm.DB) error {
		var users []model.User
		if err := tx.Find(&users).Error; err != nil {
			return err
		}

		rotated := false
		for _, user := range users {
			if !hasLegacyDefaultCredential(user) {
				continue
			}

			hashedPassword, err := crypto.HashPasswordAsBcrypt(random.Seq(32))
			if err != nil {
				return err
			}
			if err := tx.Model(&model.User{}).
				Where("id = ?", user.Id).
				Update("password", hashedPassword).
				Error; err != nil {
				return err
			}
			rotated = true
		}

		if rotated {
			return setBootstrapPending(tx, true)
		}
		return nil
	})
}

// runSeeders migrates user passwords to bcrypt and records seeder execution to prevent re-running.
func runSeeders(isUsersEmpty bool) error {
	empty, err := isTableEmpty("history_of_seeders")
	if err != nil {
		log.Printf("Error checking if users table is empty: %v", err)
		return err
	}

	if empty && isUsersEmpty {
		hashSeeder := &model.HistoryOfSeeders{
			SeederName: "UserPasswordHash",
		}
		return db.Create(hashSeeder).Error
	} else {
		var seedersHistory []string
		db.Model(&model.HistoryOfSeeders{}).Pluck("seeder_name", &seedersHistory)

		if !slices.Contains(seedersHistory, "UserPasswordHash") && !isUsersEmpty {
			var users []model.User
			db.Find(&users)

			for _, user := range users {
				hashedPassword, err := crypto.HashPasswordAsBcrypt(user.Password)
				if err != nil {
					log.Printf("Error hashing password for user '%s': %v", user.Username, err)
					return err
				}
				db.Model(&user).Update("password", hashedPassword)
			}

			hashSeeder := &model.HistoryOfSeeders{
				SeederName: "UserPasswordHash",
			}
			return db.Create(hashSeeder).Error
		}
	}

	return nil
}

// isTableEmpty returns true if the named table contains zero rows.
func isTableEmpty(tableName string) (bool, error) {
	var count int64
	err := db.Table(tableName).Count(&count).Error
	return count == 0, err
}

// prepareDatabaseStorage creates and hardens the database directory and file
// before SQLite opens them. Pre-creating the database with mode 0600 avoids a
// window where a permissive process umask could expose a newly-created file.
// Existing installations are preserved; only their permission bits are
// tightened.
func prepareDatabaseStorage(dbPath string) error {
	if dbPath == "" {
		return errors.New("database path is empty")
	}

	dir := filepath.Dir(dbPath)
	cleanDir := filepath.Clean(dir)
	volumeRoot := filepath.VolumeName(cleanDir) + string(os.PathSeparator)
	if cleanDir == volumeRoot {
		return fmt.Errorf("database directory must not be a filesystem root: %s", dir)
	}
	switch filepath.ToSlash(cleanDir) {
	case "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/usr/local", "/var", "/var/lib", "/var/log":
		return fmt.Errorf("database directory must be a dedicated subdirectory: %s", dir)
	}
	if err := os.MkdirAll(dir, privateDirectoryMode); err != nil {
		return fmt.Errorf("create database directory: %w", err)
	}
	dirInfo, err := os.Lstat(dir)
	if err != nil {
		return fmt.Errorf("inspect database directory: %w", err)
	}
	if dirInfo.Mode()&os.ModeSymlink != 0 || !dirInfo.IsDir() {
		return fmt.Errorf("database directory must be a regular directory: %s", dir)
	}
	// A relative database filename uses the caller's working directory. Do not
	// change that directory's permissions; the database file is still private.
	if cleanDir != "." {
		if err := os.Chmod(dir, privateDirectoryMode); err != nil {
			return fmt.Errorf("secure database directory: %w", err)
		}
	}

	if fileInfo, statErr := os.Lstat(dbPath); statErr == nil {
		if fileInfo.Mode()&os.ModeSymlink != 0 || !fileInfo.Mode().IsRegular() {
			return fmt.Errorf("database path must be a regular file: %s", dbPath)
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return fmt.Errorf("inspect database file: %w", statErr)
	}

	file, err := os.OpenFile(dbPath, os.O_CREATE|os.O_RDWR, privateDatabaseMode)
	if err != nil {
		return fmt.Errorf("open database file: %w", err)
	}
	if err := file.Chmod(privateDatabaseMode); err != nil {
		_ = file.Close()
		return fmt.Errorf("secure database file: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close database file: %w", err)
	}

	return hardenDatabaseFiles(dbPath)
}

// hardenDatabaseFiles also covers SQLite's persistent journal and WAL sidecar
// files when they already exist. Systemd and Docker set umask 0077 so sidecars
// created later inherit private permissions as well.
func hardenDatabaseFiles(dbPath string) error {
	for _, suffix := range sqliteFileSuffixes {
		filePath := dbPath + suffix
		fileInfo, err := os.Lstat(filePath)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return fmt.Errorf("inspect database file %q: %w", filePath, err)
		}
		if fileInfo.Mode()&os.ModeSymlink != 0 || !fileInfo.Mode().IsRegular() {
			return fmt.Errorf("database file must be regular: %s", filePath)
		}
		if err := os.Chmod(filePath, privateDatabaseMode); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return fmt.Errorf("secure database file %q: %w", filePath, err)
		}
	}
	return nil
}

// InitDB sets up the database connection, migrates models, and runs seeders.
func InitDB(dbPath string) (retErr error) {
	if err := prepareDatabaseStorage(dbPath); err != nil {
		return err
	}

	var gormLogger logger.Interface

	if config.IsDebug() {
		gormLogger = logger.Default
	} else {
		gormLogger = logger.Discard
	}

	c := &gorm.Config{
		Logger: gormLogger,
	}
	var err error
	db, err = gorm.Open(sqlite.Open(dbPath), c)
	if err != nil {
		return err
	}
	// Migrations can create SQLite sidecar files. Tighten them on every return,
	// including initialization failures, without hiding the original error.
	defer func() {
		retErr = errors.Join(retErr, hardenDatabaseFiles(dbPath))
	}()

	if err := initModels(); err != nil {
		return err
	}

	isUsersEmpty, err := isTableEmpty("users")
	if err != nil {
		return err
	}

	if err := initUser(); err != nil {
		return err
	}
	if err := runSeeders(isUsersEmpty); err != nil {
		return err
	}
	if err := rotateLegacyDefaultCredentials(); err != nil {
		return err
	}
	return nil
}

// CloseDB closes the database connection if it exists.
func CloseDB() error {
	if db != nil {
		sqlDB, err := db.DB()
		if err != nil {
			return err
		}
		return sqlDB.Close()
	}
	return nil
}

// GetDB returns the global GORM database instance.
func GetDB() *gorm.DB {
	return db
}

func IsNotFound(err error) bool {
	return errors.Is(err, gorm.ErrRecordNotFound)
}

// IsSQLiteDB checks if the given file is a valid SQLite database by reading its signature.
func IsSQLiteDB(file io.ReaderAt) (bool, error) {
	signature := []byte("SQLite format 3\x00")
	buf := make([]byte, len(signature))
	_, err := file.ReadAt(buf, 0)
	if err != nil {
		return false, err
	}
	return bytes.Equal(buf, signature), nil
}

// Checkpoint performs a WAL checkpoint on the SQLite database to ensure data consistency.
func Checkpoint() error {
	// Update WAL
	err := db.Exec("PRAGMA wal_checkpoint;").Error
	if err != nil {
		return err
	}
	return nil
}

// ValidateSQLiteDB opens the provided sqlite DB path with a throw-away connection
// and runs a PRAGMA integrity_check to ensure the file is structurally sound.
// It does not mutate global state or run migrations.
func ValidateSQLiteDB(dbPath string) error {
	if _, err := os.Stat(dbPath); err != nil { // file must exist
		return err
	}
	gdb, err := gorm.Open(sqlite.Open(dbPath), &gorm.Config{Logger: logger.Discard})
	if err != nil {
		return err
	}
	sqlDB, err := gdb.DB()
	if err != nil {
		return err
	}
	defer sqlDB.Close()
	var res string
	if err := gdb.Raw("PRAGMA integrity_check;").Scan(&res).Error; err != nil {
		return err
	}
	if res != "ok" {
		return errors.New("sqlite integrity check failed: " + res)
	}
	return nil
}
