package sub

import (
	"testing"

	"github.com/mhsanaei/3x-ui/v2/web/network"
)

func TestSafeSubscriptionURIRejectsHTTPWithoutExplicitOverride(t *testing.T) {
	for _, uri := range []string{"http://legacy.example/sub/", " HTTP://legacy.example/sub/"} {
		if got := safeSubscriptionURI(uri); got != "" {
			t.Fatalf("safeSubscriptionURI(%q) = %q, want empty", uri, got)
		}
	}
	if got := safeSubscriptionURI("https://secure.example/sub/"); got == "" {
		t.Fatal("HTTPS subscription URI was unexpectedly rejected")
	}
	if got := safeSubscriptionURI("/sub/"); got != "/sub/" {
		t.Fatalf("relative subscription URI = %q, want preserved value", got)
	}
}

func TestSafeSubscriptionURIAllowsExplicitLegacyOverride(t *testing.T) {
	t.Setenv(network.AllowInsecureHTTPEnv, "true")
	uri := "http://legacy.example/sub/"
	if got := safeSubscriptionURI(uri); got != uri {
		t.Fatalf("safeSubscriptionURI() = %q, want %q with explicit override", got, uri)
	}
}
