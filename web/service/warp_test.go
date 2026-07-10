package service

import (
	"encoding/base64"
	"testing"
)

func TestBuildWarpOutbound(t *testing.T) {
	warpData := map[string]string{"private_key": "private"}
	clientID := base64.StdEncoding.EncodeToString([]byte{1, 2, 3})
	warpConfig := map[string]any{
		"config": map[string]any{
			"client_id": clientID,
			"interface": map[string]any{
				"addresses": map[string]any{
					"v4": "172.16.0.2",
					"v6": "2606:4700:110:abcd::2",
				},
			},
			"peers": []any{map[string]any{
				"public_key": "public",
				"endpoint": map[string]any{
					"host": "engage.cloudflareclient.com:2408",
				},
			}},
		},
	}

	outbound, err := buildWarpOutbound(warpData, warpConfig)
	if err != nil {
		t.Fatal(err)
	}
	if outbound["tag"] != "warp" || outbound["protocol"] != "wireguard" {
		t.Fatalf("unexpected outbound: %#v", outbound)
	}
	settings := outbound["settings"].(map[string]any)
	if settings["secretKey"] != "private" || settings["domainStrategy"] != "ForceIP" {
		t.Fatalf("unexpected settings: %#v", settings)
	}
	reserved := settings["reserved"].([]int)
	if len(reserved) != 3 || reserved[0] != 1 || reserved[2] != 3 {
		t.Fatalf("unexpected reserved: %#v", reserved)
	}
}
