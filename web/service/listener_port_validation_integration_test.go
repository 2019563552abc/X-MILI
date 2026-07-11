//go:build cgo

package service

import (
	"strings"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
)

func TestAddInboundRejectsServicePortConflictBeforeInsert(t *testing.T) {
	setupSecuritySettingsDB(t)
	inbound := &model.Inbound{
		Enable:   true,
		Listen:   "0.0.0.0",
		Port:     2053,
		Protocol: model.VLESS,
		Settings: `{"clients":[]}`,
		Tag:      "panel-collision",
	}

	_, _, err := (&InboundService{}).AddInbound(inbound)
	if err == nil || !strings.Contains(err.Error(), "panel") {
		t.Fatalf("AddInbound() error = %v, want panel listener conflict", err)
	}

	var count int64
	if err := database.GetDB().Model(&model.Inbound{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("inbound row count = %d, want 0 after rejected insert", count)
	}
}

func TestSetInboundEnableRejectsSubscriptionPortConflictBeforeUpdate(t *testing.T) {
	setupSecuritySettingsDB(t)
	settings := &SettingService{}
	if err := settings.setBool("subEnable", true); err != nil {
		t.Fatal(err)
	}

	inbound := &model.Inbound{
		Enable:   false,
		Listen:   "0.0.0.0",
		Port:     2096,
		Protocol: model.VLESS,
		Settings: `{"clients":[]}`,
		Tag:      "subscription-collision",
	}
	if err := database.GetDB().Create(inbound).Error; err != nil {
		t.Fatal(err)
	}

	_, err := (&InboundService{}).SetInboundEnable(inbound.Id, true)
	if err == nil || !strings.Contains(err.Error(), "subscription") {
		t.Fatalf("SetInboundEnable() error = %v, want subscription listener conflict", err)
	}

	var persisted model.Inbound
	if err := database.GetDB().First(&persisted, inbound.Id).Error; err != nil {
		t.Fatal(err)
	}
	if persisted.Enable {
		t.Fatal("rejected inbound was enabled in the database")
	}
}

func TestUpdateAllSettingRejectsSubscriptionPortConflictBeforeSave(t *testing.T) {
	setupSecuritySettingsDB(t)
	inbound := &model.Inbound{
		Enable:   true,
		Listen:   "0.0.0.0",
		Port:     2096,
		Protocol: model.VLESS,
		Settings: `{"clients":[]}`,
		Tag:      "subscription-collision",
	}
	if err := database.GetDB().Create(inbound).Error; err != nil {
		t.Fatal(err)
	}

	settingsService := &SettingService{}
	settings, err := settingsService.GetAllSetting()
	if err != nil {
		t.Fatal(err)
	}
	settings.SubEnable = true

	err = settingsService.UpdateAllSetting(settings)
	if err == nil || !strings.Contains(err.Error(), "subscription") {
		t.Fatalf("UpdateAllSetting() error = %v, want subscription listener conflict", err)
	}

	subEnabled, err := settingsService.GetSubEnable()
	if err != nil {
		t.Fatal(err)
	}
	if subEnabled {
		t.Fatal("rejected subscription setting was persisted")
	}
}

func TestSetPortRejectsInboundConflictBeforeSave(t *testing.T) {
	setupSecuritySettingsDB(t)
	inbound := &model.Inbound{
		Enable:   true,
		Listen:   "0.0.0.0",
		Port:     8443,
		Protocol: model.VLESS,
		Settings: `{"clients":[]}`,
		Tag:      "cli-panel-collision",
	}
	if err := database.GetDB().Create(inbound).Error; err != nil {
		t.Fatal(err)
	}

	settings := &SettingService{}
	err := settings.SetPort(8443)
	if err == nil || !strings.Contains(err.Error(), "panel") {
		t.Fatalf("SetPort() error = %v, want panel listener conflict", err)
	}

	port, err := settings.GetPort()
	if err != nil {
		t.Fatal(err)
	}
	if port != 2053 {
		t.Fatalf("web port = %d, want original 2053 after rejected CLI update", port)
	}
}

func TestSaveXraySettingRejectsServicePortConflictBeforeSave(t *testing.T) {
	setupSecuritySettingsDB(t)
	settings := &SettingService{}
	original, err := settings.GetXrayConfigTemplate()
	if err != nil {
		t.Fatal(err)
	}

	template := `{
		"inbounds":[{"listen":"127.0.0.1","port":2053,"tag":"template-panel-collision"}],
		"outbounds":[]
	}`
	err = (&XraySettingService{}).SaveXraySetting(template)
	if err == nil || !strings.Contains(err.Error(), "panel") {
		t.Fatalf("SaveXraySetting() error = %v, want panel listener conflict", err)
	}

	persisted, err := settings.GetXrayConfigTemplate()
	if err != nil {
		t.Fatal(err)
	}
	if persisted != original {
		t.Fatal("rejected Xray template replaced the stored template")
	}
}
