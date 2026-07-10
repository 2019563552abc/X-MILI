package service

import "testing"

func TestDefaultValueMapUsesSafeNetworkDefaults(t *testing.T) {
	if got := defaultValueMap["webListen"]; got != "127.0.0.1" {
		t.Fatalf("webListen default = %q, want loopback", got)
	}
	if got := defaultValueMap["subListen"]; got != "127.0.0.1" {
		t.Fatalf("subListen default = %q, want loopback", got)
	}
	for _, key := range []string{"subEnable", "subJsonEnable", "subClashEnable"} {
		if got := defaultValueMap[key]; got != "false" {
			t.Fatalf("%s default = %q, want false", key, got)
		}
	}
}
