package controller

import (
	"strings"
	"testing"
)

func TestFailedLoginLogMessageNeverContainsPasswordField(t *testing.T) {
	message := failedLoginLogMessage("admin\nnext-line", "192.0.2.1")
	if strings.Contains(strings.ToLower(message), "password") {
		t.Fatalf("failed-login message unexpectedly contains a password field: %q", message)
	}
	if !strings.Contains(message, `username="admin\nnext-line"`) {
		t.Fatalf("username is not safely quoted in %q", message)
	}
}
