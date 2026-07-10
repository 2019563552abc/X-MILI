package entity

import (
	"strings"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/web/network"
)

func securityTestSettings() *AllSetting {
	return &AllSetting{
		WebListen:    "0.0.0.0",
		WebPort:      2053,
		WebBasePath:  "/",
		SubListen:    "127.0.0.1",
		SubPort:      2096,
		SubPath:      "/sub/",
		SubJsonPath:  "/json/",
		SubClashPath: "/clash/",
		TimeLocation: "Local",
	}
}

func TestCheckValidRejectsPublicPanelHTTP(t *testing.T) {
	settings := securityTestSettings()
	err := settings.CheckValid()
	if err == nil || !strings.Contains(err.Error(), network.AllowInsecureHTTPEnv) {
		t.Fatalf("CheckValid() error = %v, want public HTTP rejection mentioning %s", err, network.AllowInsecureHTTPEnv)
	}

	t.Setenv(network.AllowInsecureHTTPEnv, "true")
	if err := settings.CheckValid(); err != nil {
		t.Fatalf("explicit insecure HTTP override rejected: %v", err)
	}
}

func TestCheckValidRejectsPublicSubscriptionHTTP(t *testing.T) {
	settings := securityTestSettings()
	settings.WebListen = "127.0.0.1"
	settings.SubEnable = true
	settings.SubListen = "0.0.0.0"

	err := settings.CheckValid()
	if err == nil || !strings.Contains(err.Error(), "subscription HTTP") {
		t.Fatalf("CheckValid() error = %v, want public subscription HTTP rejection", err)
	}
}
