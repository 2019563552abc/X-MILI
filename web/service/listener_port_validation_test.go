package service

import (
	"strings"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/util/json_util"
	"github.com/mhsanaei/3x-ui/v2/web/entity"
	"github.com/mhsanaei/3x-ui/v2/xray"
)

func TestValidateListenerPortConflictsRejectsSubscriptionInboundCollision(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   2053,
		SubEnable: true,
		SubListen: "::",
		SubPort:   2096,
	}
	inbounds := []*model.Inbound{{
		Enable: true,
		Listen: "0.0.0.0",
		Port:   2096,
		Tag:    "subscription-collision",
	}}

	err := validateListenerPortConflicts(settings, inbounds)
	if err == nil {
		t.Fatal("accepted an enabled Xray inbound on the subscription listener port")
	}
	for _, want := range []string{"subscription", "subscription-collision", "2096"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error = %q, want it to contain %q", err, want)
		}
	}
}

func TestValidateListenerPortConflictsRejectsPanelInboundCollision(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   2053,
		SubEnable: false,
		SubListen: "127.0.0.1",
		SubPort:   2096,
	}
	inbounds := []*model.Inbound{{
		Enable: true,
		Listen: "127.0.0.1",
		Port:   2053,
		Tag:    "panel-collision",
	}}

	err := validateListenerPortConflicts(settings, inbounds)
	if err == nil || !strings.Contains(err.Error(), "panel") {
		t.Fatalf("error = %v, want panel listener conflict", err)
	}
}

func TestValidateListenerPortConflictsRejectsOverlappingPanelAndSubscription(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "::",
		WebPort:   2096,
		SubEnable: true,
		SubListen: "0.0.0.0",
		SubPort:   2096,
	}

	err := validateListenerPortConflicts(settings, nil)
	if err == nil {
		t.Fatal("accepted overlapping wildcard panel and subscription listeners")
	}
	for _, want := range []string{"panel", "subscription", "2096"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error = %q, want it to contain %q", err, want)
		}
	}
}

func TestListenerAddressesOverlapTreatsExpandedIPv6UnspecifiedAsWildcard(t *testing.T) {
	for _, address := range []string{
		"0:0:0:0:0:0:0:0",
		"::ffff:0.0.0.0",
	} {
		if !listenerAddressesOverlap(address, "192.0.2.10") {
			t.Fatalf("%q was not treated as a wildcard listener", address)
		}
	}
}

func TestValidateListenerPortConflictsAllowsInactiveOrDisjointSubscription(t *testing.T) {
	tests := []struct {
		name     string
		settings *entity.AllSetting
	}{
		{
			name: "disabled subscription",
			settings: &entity.AllSetting{
				WebListen: "0.0.0.0",
				WebPort:   2096,
				SubEnable: false,
				SubListen: "::",
				SubPort:   2096,
			},
		},
		{
			name: "distinct specific addresses",
			settings: &entity.AllSetting{
				WebListen: "127.0.0.1",
				WebPort:   2096,
				SubEnable: true,
				SubListen: "192.0.2.10",
				SubPort:   2096,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateListenerPortConflicts(tt.settings, nil); err != nil {
				t.Fatalf("unexpected listener conflict: %v", err)
			}
		})
	}
}

func TestValidateListenerPortConflictsIgnoresInactiveListeners(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   2053,
		SubEnable: false,
		SubListen: "0.0.0.0",
		SubPort:   2096,
	}

	tests := []struct {
		name     string
		inbounds []*model.Inbound
	}{
		{
			name: "disabled subscription",
			inbounds: []*model.Inbound{{
				Enable: true,
				Listen: "0.0.0.0",
				Port:   2096,
				Tag:    "allowed-while-subscription-disabled",
			}},
		},
		{
			name: "disabled inbound",
			inbounds: []*model.Inbound{{
				Enable: false,
				Listen: "0.0.0.0",
				Port:   2053,
				Tag:    "disabled-panel-collision",
			}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateListenerPortConflicts(settings, tt.inbounds); err != nil {
				t.Fatalf("unexpected conflict: %v", err)
			}
		})
	}
}

func TestValidateListenerPortConflictsAllowsDistinctSpecificAddresses(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   2053,
		SubEnable: true,
		SubListen: "127.0.0.1",
		SubPort:   2096,
	}
	inbounds := []*model.Inbound{
		{
			Enable: true,
			Listen: "192.0.2.10",
			Port:   2053,
			Tag:    "public-panel-port",
		},
		{
			Enable: true,
			Listen: "192.0.2.10",
			Port:   2096,
			Tag:    "public-subscription-port",
		},
	}

	if err := validateListenerPortConflicts(settings, inbounds); err != nil {
		t.Fatalf("distinct specific addresses should be allowed: %v", err)
	}
}

func TestValidateXrayConfigListenerPortConflictsRejectsHistoricalCollision(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   2053,
		SubEnable: true,
		SubListen: "::",
		SubPort:   2096,
	}
	config := &xray.Config{
		InboundConfigs: []xray.InboundConfig{{
			Listen: json_util.RawMessage(`"0.0.0.0"`),
			Port:   2096,
			Tag:    "historical-collision",
		}},
	}

	err := validateXrayConfigListenerPortConflicts(settings, config)
	if err == nil {
		t.Fatal("accepted a generated Xray config that collides with the subscription listener")
	}
	for _, want := range []string{"historical-collision", "subscription", "2096"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error = %q, want it to contain %q", err, want)
		}
	}
}

func TestValidateXrayConfigListenerPortConflictsRejectsTemplateInboundCollision(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   62789,
		SubEnable: false,
	}
	config := &xray.Config{
		InboundConfigs: []xray.InboundConfig{{
			Listen: json_util.RawMessage(`"127.0.0.1"`),
			Port:   62789,
			Tag:    "api",
		}},
	}

	err := validateXrayConfigListenerPortConflicts(settings, config)
	if err == nil || !strings.Contains(err.Error(), "api") {
		t.Fatalf("error = %v, want template inbound conflict", err)
	}
}

func TestValidateSettingsAgainstXrayListenersRejectsTemplateInboundCollision(t *testing.T) {
	settings := &entity.AllSetting{
		WebListen: "127.0.0.1",
		WebPort:   62789,
		SubEnable: false,
	}
	template := `{
		"inbounds": [{
			"listen": "127.0.0.1",
			"port": 62789,
			"tag": "api"
		}]
	}`

	err := validateSettingsAgainstXrayListeners(settings, template, nil)
	if err == nil || !strings.Contains(err.Error(), "api") {
		t.Fatalf("error = %v, want template API inbound conflict", err)
	}
}
