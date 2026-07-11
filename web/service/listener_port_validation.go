package service

import (
	"encoding/json"
	"net"
	"strings"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/web/entity"
	"github.com/mhsanaei/3x-ui/v2/xray"
)

type serviceListener struct {
	name   string
	listen string
	port   int
	enable bool
}

// validateListenerPortConflicts prevents the panel or subscription HTTP
// server from reserving the same TCP socket as an enabled Xray inbound.
// It is deliberately validation-only: existing inbounds and settings are
// never rewritten or disabled automatically.
func validateListenerPortConflicts(settings *entity.AllSetting, inbounds []*model.Inbound) error {
	if settings == nil {
		return common.NewError("settings are required for listener port validation")
	}

	listeners := []serviceListener{
		{name: "panel", listen: settings.WebListen, port: settings.WebPort, enable: true},
		{name: "subscription", listen: settings.SubListen, port: settings.SubPort, enable: settings.SubEnable},
	}
	if listeners[1].enable &&
		listeners[0].port == listeners[1].port &&
		listenerAddressesOverlap(listeners[0].listen, listeners[1].listen) {
		return common.NewErrorf(
			"the panel listener (%s:%d) conflicts with the subscription listener (%s:%d); change one port or listener address",
			displayListenerAddress(listeners[0].listen),
			listeners[0].port,
			displayListenerAddress(listeners[1].listen),
			listeners[1].port,
		)
	}

	for _, inbound := range inbounds {
		if inbound == nil || !inbound.Enable {
			continue
		}
		for _, listener := range listeners {
			if !listener.enable || inbound.Port != listener.port || !listenerAddressesOverlap(inbound.Listen, listener.listen) {
				continue
			}

			tag := strings.TrimSpace(inbound.Tag)
			if tag == "" {
				tag = "<untagged>"
			}
			return common.NewErrorf(
				"enabled Xray inbound %q (%s:%d) conflicts with the %s listener (%s:%d); change one port or listener address",
				tag,
				displayListenerAddress(inbound.Listen),
				inbound.Port,
				listener.name,
				displayListenerAddress(listener.listen),
				listener.port,
			)
		}
	}
	return nil
}

func validateSettingsAgainstCurrentInbounds(settings *entity.AllSetting) error {
	var inbounds []*model.Inbound
	err := database.GetDB().
		Model(model.Inbound{}).
		Select("id", "tag", "listen", "port", "enable").
		Where("enable = ?", true).
		Find(&inbounds).Error
	if err != nil {
		return err
	}
	templateConfig, err := (&SettingService{}).GetXrayConfigTemplate()
	if err != nil {
		return err
	}
	return validateSettingsAgainstXrayListeners(settings, templateConfig, inbounds)
}

func validateSettingsAgainstXrayListeners(settings *entity.AllSetting, templateConfig string, inbounds []*model.Inbound) error {
	if err := validateListenerPortConflicts(settings, inbounds); err != nil {
		return err
	}

	config := &xray.Config{}
	if err := json.Unmarshal([]byte(UnwrapXrayTemplateConfig(templateConfig)), config); err != nil {
		return common.NewErrorf("invalid Xray template while checking listener ports: %v", err)
	}
	return validateXrayConfigListenerPortConflicts(settings, config)
}

func validateInboundAgainstServiceListeners(inbound *model.Inbound) error {
	if inbound == nil || !inbound.Enable {
		return nil
	}
	settings, err := (&SettingService{}).GetAllSetting()
	if err != nil {
		return err
	}
	return validateListenerPortConflicts(settings, []*model.Inbound{inbound})
}

// validateXrayConfigListenerPortConflicts is the final preflight used by
// GetXrayConfig. Besides database-backed inbounds, it also covers inbounds
// embedded in the Xray template and catches historical conflicts before the
// currently running Xray process is stopped.
func validateXrayConfigListenerPortConflicts(settings *entity.AllSetting, config *xray.Config) error {
	if config == nil {
		return common.NewError("Xray config is required for listener port validation")
	}

	inbounds := make([]*model.Inbound, 0, len(config.InboundConfigs))
	for _, inbound := range config.InboundConfigs {
		listen := ""
		rawListen := strings.TrimSpace(string(inbound.Listen))
		if rawListen != "" && rawListen != "null" {
			if err := json.Unmarshal(inbound.Listen, &listen); err != nil {
				return common.NewErrorf("Xray inbound %q has an invalid listen address: %v", inbound.Tag, err)
			}
		}
		inbounds = append(inbounds, &model.Inbound{
			Enable: true,
			Listen: listen,
			Port:   inbound.Port,
			Tag:    inbound.Tag,
		})
	}
	return validateListenerPortConflicts(settings, inbounds)
}

func listenerAddressesOverlap(left, right string) bool {
	left = canonicalListenerAddress(left)
	right = canonicalListenerAddress(right)
	return left == "*" || right == "*" || left == right
}

func canonicalListenerAddress(address string) string {
	address = strings.TrimSpace(address)
	if len(address) >= 2 && address[0] == '[' && address[len(address)-1] == ']' {
		address = address[1 : len(address)-1]
	}

	switch strings.ToLower(address) {
	case "", "*", "0.0.0.0", "::", "::0":
		return "*"
	}

	ip := net.ParseIP(address)
	if ip == nil {
		return strings.ToLower(address)
	}
	if ip.IsUnspecified() {
		return "*"
	}
	if ip4 := ip.To4(); ip4 != nil {
		return ip4.String()
	}
	return ip.String()
}

func displayListenerAddress(address string) string {
	if canonicalListenerAddress(address) == "*" {
		return "all interfaces"
	}
	return strings.TrimSpace(address)
}
