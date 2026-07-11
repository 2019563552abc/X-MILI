package service

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestUnwrapXrayTemplateConfig(t *testing.T) {
	real := `{"log":{},"inbounds":[],"outbounds":[],"routing":{}}`

	t.Run("passes through a clean config", func(t *testing.T) {
		if got := UnwrapXrayTemplateConfig(real); got != real {
			t.Fatalf("clean config was modified: %s", got)
		}
	})

	t.Run("passes through invalid JSON unchanged", func(t *testing.T) {
		in := "not json at all"
		if got := UnwrapXrayTemplateConfig(in); got != in {
			t.Fatalf("invalid input was modified: %s", got)
		}
	})

	t.Run("unwraps one layer of response-shaped wrapper", func(t *testing.T) {
		wrapper := `{"inboundTags":["tag"],"outboundTestUrl":"x","xraySetting":` + real + `}`
		got := UnwrapXrayTemplateConfig(wrapper)
		if !equalJSON(t, got, real) {
			t.Fatalf("want %s, got %s", real, got)
		}
	})

	t.Run("unwraps multiple stacked layers", func(t *testing.T) {
		lvl1 := `{"xraySetting":` + real + `}`
		lvl2 := `{"xraySetting":` + lvl1 + `}`
		lvl3 := `{"xraySetting":` + lvl2 + `}`
		got := UnwrapXrayTemplateConfig(lvl3)
		if !equalJSON(t, got, real) {
			t.Fatalf("want %s, got %s", real, got)
		}
	})

	t.Run("handles an xraySetting stored as a JSON-encoded string", func(t *testing.T) {
		encoded, _ := json.Marshal(real) // becomes a quoted string
		wrapper := `{"xraySetting":` + string(encoded) + `}`
		got := UnwrapXrayTemplateConfig(wrapper)
		if !equalJSON(t, got, real) {
			t.Fatalf("want %s, got %s", real, got)
		}
	})

	t.Run("does not unwrap when top level already has real xray keys", func(t *testing.T) {
		// Pathological but defensible: if a user's actual config somehow
		// has both the real keys and an unrelated `xraySetting` key, we
		// must not strip it.
		in := `{"inbounds":[],"xraySetting":{"some":"thing"}}`
		got := UnwrapXrayTemplateConfig(in)
		if got != in {
			t.Fatalf("should have left real config alone, got %s", got)
		}
	})

	t.Run("stops at a reasonable depth", func(t *testing.T) {
		// Build a deeper-than-maxDepth chain that ends at something
		// non-wrapped, and confirm we end up at some valid JSON (we
		// don't loop forever and we don't blow the stack).
		s := real
		for i := 0; i < 16; i++ {
			s = `{"xraySetting":` + s + `}`
		}
		got := UnwrapXrayTemplateConfig(s)
		if !strings.Contains(got, `"inbounds"`) && !strings.Contains(got, `"xraySetting"`) {
			t.Fatalf("unexpected tail: %s", got)
		}
	})
}

func TestSaveXraySettingRejectsEmptyFlatVLESSOutbound(t *testing.T) {
	config := `{"outbounds":[{"tag":"1","protocol":"vless","settings":{}}]}`

	err := (&XraySettingService{}).SaveXraySetting(config)
	if err == nil {
		t.Fatal("SaveXraySetting accepted an empty flat VLESS outbound")
	}
	if !strings.Contains(err.Error(), `tag "1"`) {
		t.Fatalf("error does not identify the invalid outbound tag: %v", err)
	}
}

func TestSaveXraySettingRejectsFlatVLESSWithoutPort(t *testing.T) {
	config := `{"outbounds":[{"tag":"edge","protocol":"vless","settings":{"address":"example.com","id":"test-id"}}]}`

	err := (&XraySettingService{}).SaveXraySetting(config)
	if err == nil {
		t.Fatal("SaveXraySetting accepted a flat VLESS outbound without a port")
	}
	for _, want := range []string{`tag "edge"`, "settings.port"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q does not contain %q", err, want)
		}
	}
}

func TestSaveXraySettingRejectsFlatVLESSWithoutID(t *testing.T) {
	config := `{"outbounds":[{"tag":"edge","protocol":"vless","settings":{"address":"example.com","port":443}}]}`

	err := (&XraySettingService{}).SaveXraySetting(config)
	if err == nil {
		t.Fatal("SaveXraySetting accepted a flat VLESS outbound without an id")
	}
	for _, want := range []string{`tag "edge"`, "settings.id"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q does not contain %q", err, want)
		}
	}
}

func TestSaveXraySettingRejectsInvalidLegacyVLESSShape(t *testing.T) {
	endpoint := `{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}`
	tests := []struct {
		name     string
		settings string
		want     string
	}{
		{name: "no endpoints", settings: `{"vnext":[]}`, want: "settings.vnext"},
		{name: "multiple endpoints", settings: `{"vnext":[` + endpoint + `,` + endpoint + `]}`, want: "settings.vnext"},
		{name: "no users", settings: `{"vnext":[{"address":"example.com","port":443,"users":[]}]}`, want: "users"},
		{name: "multiple users", settings: `{"vnext":[{"address":"example.com","port":443,"users":[{"id":"one"},{"id":"two"}]}]}`, want: "users"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := `{"outbounds":[{"tag":"legacy-edge","protocol":"vless","settings":` + tt.settings + `}]}`
			err := (&XraySettingService{}).SaveXraySetting(config)
			if err == nil {
				t.Fatal("SaveXraySetting accepted an invalid legacy VLESS outbound")
			}
			for _, want := range []string{`tag "legacy-edge"`, tt.want} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("error %q does not contain %q", err, want)
				}
			}
		})
	}
}

func TestCheckXrayConfigAcceptsValidVLESSShapes(t *testing.T) {
	tests := []struct {
		name     string
		settings string
	}{
		{
			name:     "flat",
			settings: `{"address":"example.com","port":443,"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}`,
		},
		{
			name:     "legacy single endpoint and user",
			settings: `{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := `{"outbounds":[{"tag":"valid","protocol":"vless","settings":` + tt.settings + `}]}`
			if err := (&XraySettingService{}).CheckXrayConfig(config); err != nil {
				t.Fatalf("valid VLESS config was rejected: %v", err)
			}
		})
	}
}

func TestSaveXraySettingRejectsVLESSWithoutEncryption(t *testing.T) {
	tests := []struct {
		name     string
		settings string
	}{
		{
			name:     "flat",
			settings: `{"address":"example.com","port":443,"id":"11111111-1111-1111-1111-111111111111"}`,
		},
		{
			name:     "legacy",
			settings: `{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111"}]}]}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := `{"outbounds":[{"tag":"encrypted-edge","protocol":"vless","settings":` + tt.settings + `}]}`
			err := (&XraySettingService{}).SaveXraySetting(config)
			if err == nil {
				t.Fatal("SaveXraySetting accepted VLESS without encryption")
			}
			for _, want := range []string{`tag "encrypted-edge"`, "encryption"} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("error %q does not contain %q", err, want)
				}
			}
		})
	}
}

func TestSaveXraySettingRejectsMixedVLESSShapes(t *testing.T) {
	config := `{"outbounds":[{"tag":"mixed","protocol":"vless","settings":{"vnext":[],"id":"11111111-1111-1111-1111-111111111111"}}]}`

	err := (&XraySettingService{}).SaveXraySetting(config)
	if err == nil {
		t.Fatal("SaveXraySetting accepted mixed flat and legacy VLESS settings")
	}
	for _, want := range []string{`tag "mixed"`, "not both"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q does not contain %q", err, want)
		}
	}
}

func TestCheckXrayConfigAcceptsVLESSPortBoundaries(t *testing.T) {
	for _, port := range []string{"1", "65535"} {
		t.Run(port, func(t *testing.T) {
			config := `{"outbounds":[{"tag":"boundary-port","protocol":"vless","settings":{"address":"example.com","port":` + port + `,"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}}]}`
			if err := (&XraySettingService{}).CheckXrayConfig(config); err != nil {
				t.Fatalf("valid boundary port %s was rejected: %v", port, err)
			}
		})
	}
}

func TestSaveXraySettingRejectsInvalidVLESSPortLiterals(t *testing.T) {
	for _, port := range []string{"0", "65536", "-1", `"443"`, "443.0", "443e0"} {
		t.Run(port, func(t *testing.T) {
			config := `{"outbounds":[{"tag":"numeric-port","protocol":"vless","settings":{"address":"example.com","port":` + port + `,"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}}]}`
			err := (&XraySettingService{}).SaveXraySetting(config)
			if err == nil {
				t.Fatalf("SaveXraySetting accepted invalid port literal %s", port)
			}
			for _, want := range []string{`tag "numeric-port"`, "settings.port"} {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("error %q does not contain %q", err, want)
				}
			}
		})
	}
}

func equalJSON(t *testing.T, a, b string) bool {
	t.Helper()
	var va, vb any
	if err := json.Unmarshal([]byte(a), &va); err != nil {
		return false
	}
	if err := json.Unmarshal([]byte(b), &vb); err != nil {
		return false
	}
	ja, _ := json.Marshal(va)
	jb, _ := json.Marshal(vb)
	return string(ja) == string(jb)
}

// firstRuleOutbound parses the (post-hoisted) config and returns
// routing.rules[0].outboundTag, or "" if anything is missing.
func firstRuleOutbound(t *testing.T, raw string) string {
	t.Helper()
	var cfg map[string]any
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatalf("unmarshal cfg: %v", err)
	}
	routing, _ := cfg["routing"].(map[string]any)
	rules, _ := routing["rules"].([]any)
	if len(rules) == 0 {
		return ""
	}
	first, _ := rules[0].(map[string]any)
	tag, _ := first["outboundTag"].(string)
	return tag
}

func TestEnsureStatsRouting_HoistsApiRuleFromMiddle(t *testing.T) {
	// #4113 repro shape: admin added a cascade outbound and put a
	// catch-all routing rule above the api rule. stats query path
	// gets starved by the catch-all unless we hoist the api rule.
	in := `{
		"routing": {
			"rules": [
				{"type":"field","inboundTag":["inbound-vless"],"outboundTag":"vless-cascade"},
				{"type":"field","inboundTag":["api"],"outboundTag":"api"},
				{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}
			]
		}
	}`
	out, err := EnsureStatsRouting(in)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got := firstRuleOutbound(t, out); got != "api" {
		t.Fatalf("api rule should be at index 0 after hoist, got first outboundTag = %q\nfull: %s", got, out)
	}
}

func TestEnsureStatsRouting_NoOpWhenAlreadyFirst(t *testing.T) {
	// Don't churn the JSON when nothing needs fixing — same string in,
	// same string out. Lets the diff in the panel UI stay quiet for
	// well-formed configs.
	in := `{"routing":{"rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}]}}`
	out, err := EnsureStatsRouting(in)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if out != in {
		t.Fatalf("expected unchanged input, got: %s", out)
	}
}

func TestEnsureStatsRouting_InsertsDefaultWhenMissing(t *testing.T) {
	// Some admins delete the api rule by accident. Re-add a default
	// at the front so stats keep working after the next save.
	in := `{"routing":{"rules":[{"type":"field","outboundTag":"vless-cascade","inboundTag":["inbound-vless"]}]}}`
	out, err := EnsureStatsRouting(in)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got := firstRuleOutbound(t, out); got != "api" {
		t.Fatalf("default api rule should be inserted at index 0, got %q\nfull: %s", got, out)
	}
	// The original rule should still be there, just shifted.
	var cfg map[string]any
	json.Unmarshal([]byte(out), &cfg)
	rules := cfg["routing"].(map[string]any)["rules"].([]any)
	if len(rules) != 2 {
		t.Fatalf("expected 2 rules after insert, got %d: %v", len(rules), rules)
	}
}

func TestEnsureStatsRouting_NoRoutingBlock(t *testing.T) {
	// Pathological but possible: empty config or one without a routing
	// section. Don't crash, and create the section with the api rule.
	in := `{"log":{}}`
	out, err := EnsureStatsRouting(in)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got := firstRuleOutbound(t, out); got != "api" {
		t.Fatalf("api rule should be created when routing was missing, got %q\nfull: %s", got, out)
	}
}

func TestEnsureStatsRouting_InvalidJsonReturnsAsIs(t *testing.T) {
	// SaveXraySetting calls CheckXrayConfig before this helper, so
	// invalid JSON shouldn't reach us in practice — but be defensive
	// about garbage in (return same garbage out plus an error) so the
	// caller can choose to skip the hoist instead of corrupting input.
	in := "definitely not json"
	out, err := EnsureStatsRouting(in)
	if err == nil {
		t.Fatalf("expected error for invalid json, got none")
	}
	if out != in {
		t.Fatalf("expected raw passthrough on error, got %q", out)
	}
}

func TestEnsureStatsRouting_AcceptsInboundTagAsString(t *testing.T) {
	// Some manually-edited configs use a single string instead of an
	// array for inboundTag. Make sure we still recognize the api rule.
	in := `{"routing":{"rules":[{"type":"field","inboundTag":["other"],"outboundTag":"vless-cascade"},{"type":"field","inboundTag":"api","outboundTag":"api"}]}}`
	out, err := EnsureStatsRouting(in)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if got := firstRuleOutbound(t, out); got != "api" {
		t.Fatalf("api rule with string-form inboundTag should hoist to front, got %q\nfull: %s", got, out)
	}
}
