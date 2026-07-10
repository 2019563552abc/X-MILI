//go:build cgo

package controller

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/locale"

	"github.com/gin-gonic/gin"
	"github.com/op/go-logging"
)

func TestFailedLoginDoesNotLogPassword(t *testing.T) {
	gin.SetMode(gin.TestMode)
	dbPath := filepath.Join(t.TempDir(), "x-ui.db")
	logDir := t.TempDir()
	t.Setenv("XUI_LOG_FOLDER", logDir)

	if err := database.InitDB(dbPath); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.CloseDB() })
	logger.InitLogger(logging.DEBUG)
	t.Cleanup(logger.CloseLogger)

	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("I18n", func(_ locale.I18nType, _ string, _ ...string) string { return "test" })
		c.Next()
	})
	router.POST("/login", (&IndexController{}).login)

	secret := "password-marker-must-never-be-logged"
	form := url.Values{"username": {"admin"}, "password": {secret}}
	request := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("login response status = %d, want %d", response.Code, http.StatusOK)
	}

	logger.CloseLogger()
	contents, err := os.ReadFile(filepath.Join(logDir, "3xui.log"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(contents), secret) {
		t.Fatalf("failed-login log contains password marker: %s", contents)
	}
	if !strings.Contains(string(contents), "failed login for username") {
		t.Fatalf("failed-login audit record missing: %s", contents)
	}
}
