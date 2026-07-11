package service

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestCreateTestConfigDoesNotMutateOutbounds(t *testing.T) {
	outbound := map[string]any{
		"tag":      "warp",
		"protocol": "wireguard",
		"settings": map[string]any{
			"noKernelTun": false,
		},
	}

	(&OutboundService{}).createTestConfig("warp", []any{outbound}, 19080)

	settings := outbound["settings"].(map[string]any)
	if settings["noKernelTun"] != false {
		t.Fatalf("createTestConfig mutated outbound settings: %+v", settings)
	}
}

func TestSelectOutboundTestClosureIgnoresUnrelatedInvalidVLESS(t *testing.T) {
	tested := map[string]any{
		"tag":      "vpngate",
		"protocol": "freedom",
		"settings": map[string]any{},
	}
	unrelated := map[string]any{
		"tag":      "1",
		"protocol": "vless",
		"settings": map[string]any{},
	}

	selected, err := selectOutboundTestClosure(tested, []any{tested, unrelated})
	if err != nil {
		t.Fatalf("select closure: %v", err)
	}
	if len(selected) != 1 || selected[0].(map[string]any)["tag"] != "vpngate" {
		t.Fatalf("unrelated outbound entered test closure: %+v", selected)
	}
}

func TestSelectOutboundTestClosureIncludesExplicitDependency(t *testing.T) {
	tested := map[string]any{
		"tag":      "edge",
		"protocol": "freedom",
		"streamSettings": map[string]any{
			"sockopt": map[string]any{"dialerProxy": "transport"},
		},
	}
	dependency := map[string]any{
		"tag":      "transport",
		"protocol": "freedom",
		"settings": map[string]any{},
	}
	before := cloneOutboundTestValue(t, []any{tested, dependency})

	selected, err := selectOutboundTestClosure(tested, []any{tested, dependency})
	if err != nil {
		t.Fatalf("select closure: %v", err)
	}
	if got := outboundTestTags(selected); !reflect.DeepEqual(got, []string{"edge", "transport"}) {
		t.Fatalf("selected tags = %v, want [edge transport]", got)
	}
	if after := []any{tested, dependency}; !reflect.DeepEqual(after, before) {
		t.Fatalf("dependency selection mutated input: before=%+v after=%+v", before, after)
	}
}

func TestSelectOutboundTestClosureIncludesRecursiveDependencies(t *testing.T) {
	tested := map[string]any{
		"tag":           "edge",
		"protocol":      "freedom",
		"proxySettings": map[string]any{"tag": "middle"},
	}
	middle := map[string]any{
		"tag":      "middle",
		"protocol": "freedom",
		"streamSettings": map[string]any{
			"sockopt": map[string]any{"dialerProxy": "transport"},
		},
	}
	transport := map[string]any{
		"tag":      "transport",
		"protocol": "freedom",
		"settings": map[string]any{},
	}

	selected, err := selectOutboundTestClosure(tested, []any{transport, middle, tested})
	if err != nil {
		t.Fatalf("select closure: %v", err)
	}
	if got := outboundTestTags(selected); !reflect.DeepEqual(got, []string{"edge", "middle", "transport"}) {
		t.Fatalf("selected tags = %v, want [edge middle transport]", got)
	}
}

func TestSelectOutboundTestClosureRejectsMissingAndCyclicDependencies(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		tested := map[string]any{
			"tag":           "edge",
			"protocol":      "freedom",
			"proxySettings": map[string]any{"tag": "missing"},
		}
		_, err := selectOutboundTestClosure(tested, []any{tested})
		if err == nil || !strings.Contains(err.Error(), `missing dependency "missing"`) {
			t.Fatalf("expected a clear missing dependency error, got %v", err)
		}
	})

	t.Run("cycle", func(t *testing.T) {
		tested := map[string]any{
			"tag":           "edge",
			"protocol":      "freedom",
			"proxySettings": map[string]any{"tag": "transport"},
		}
		dependency := map[string]any{
			"tag":           "transport",
			"protocol":      "freedom",
			"proxySettings": map[string]any{"tag": "edge"},
		}
		_, err := selectOutboundTestClosure(tested, []any{tested, dependency})
		if err == nil || !strings.Contains(err.Error(), "dependency cycle") {
			t.Fatalf("expected a clear dependency cycle error, got %v", err)
		}
	})
}

func TestTestOutboundRejectsInvalidSelectedVLESSBeforeProcessStart(t *testing.T) {
	tests := []struct {
		name         string
		outboundJSON string
		allJSON      string
		wantTag      string
	}{
		{
			name:         "tested outbound",
			outboundJSON: `{"tag":"broken-root","protocol":"vless","settings":{}}`,
			allJSON:      `[]`,
			wantTag:      "broken-root",
		},
		{
			name:         "selected dependency",
			outboundJSON: `{"tag":"edge","protocol":"freedom","proxySettings":{"tag":"broken-dependency"}}`,
			allJSON:      `[{"tag":"edge","protocol":"freedom"},{"tag":"broken-dependency","protocol":"vless","settings":{}}]`,
			wantTag:      "broken-dependency",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := (&OutboundService{}).TestOutbound(tt.outboundJSON, "", tt.allJSON)
			if err != nil {
				t.Fatalf("TestOutbound returned transport error: %v", err)
			}
			if result == nil || result.Success {
				t.Fatalf("invalid VLESS outbound was not rejected: %+v", result)
			}
			for _, want := range []string{`tag "` + tt.wantTag + `"`, "settings.address"} {
				if !strings.Contains(result.Error, want) {
					t.Fatalf("error %q does not contain %q", result.Error, want)
				}
			}
		})
	}
}

func outboundTestTags(outbounds []any) []string {
	tags := make([]string, 0, len(outbounds))
	for _, raw := range outbounds {
		outbound, _ := raw.(map[string]any)
		tag, _ := outbound["tag"].(string)
		tags = append(tags, tag)
	}
	return tags
}

func cloneOutboundTestValue(t *testing.T, value []any) []any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var clone []any
	if err := json.Unmarshal(raw, &clone); err != nil {
		t.Fatal(err)
	}
	return clone
}
