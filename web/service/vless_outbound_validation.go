package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

func decodeJSONUseNumber(raw []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(destination); err != nil {
		return err
	}

	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values are not allowed")
		}
		return err
	}
	return nil
}

func validateVLESSOutbounds(outbounds []any) error {
	for index, rawOutbound := range outbounds {
		outbound, ok := rawOutbound.(map[string]any)
		if !ok || outbound["protocol"] != "vless" {
			continue
		}

		tag, _ := outbound["tag"].(string)
		label := fmt.Sprintf("outbounds[%d] VLESS outbound tag %q", index, tag)
		settings, ok := outbound["settings"].(map[string]any)
		if !ok {
			return fmt.Errorf("%s is invalid: settings must be an object", label)
		}

		_, hasVnext := settings["vnext"]
		hasFlatField := false
		for _, field := range []string{"address", "port", "id", "flow", "encryption"} {
			if _, exists := settings[field]; exists {
				hasFlatField = true
				break
			}
		}
		if hasFlatField && hasVnext {
			return fmt.Errorf("%s is invalid: settings must use either flat address/port/id or legacy vnext, not both", label)
		}
		if hasVnext {
			if err := validateLegacyVLESSSettings(label, settings["vnext"]); err != nil {
				return err
			}
			continue
		}

		if address, _ := settings["address"].(string); strings.TrimSpace(address) == "" {
			return fmt.Errorf("%s is invalid: settings.address is required", label)
		}
		if !validVLESSPort(settings["port"]) {
			return fmt.Errorf("%s is invalid: settings.port must be an integer from 1 to 65535", label)
		}
		if id, _ := settings["id"].(string); strings.TrimSpace(id) == "" {
			return fmt.Errorf("%s is invalid: settings.id is required", label)
		}
		if encryption, _ := settings["encryption"].(string); strings.TrimSpace(encryption) == "" {
			return fmt.Errorf("%s is invalid: settings.encryption is required (usually %q)", label, "none")
		}
	}
	return nil
}

func validateLegacyVLESSSettings(label string, rawVnext any) error {
	vnext, ok := rawVnext.([]any)
	if !ok {
		return fmt.Errorf("%s is invalid: settings.vnext must be an array with exactly one endpoint", label)
	}
	if len(vnext) != 1 {
		return fmt.Errorf("%s is invalid: settings.vnext must contain exactly one endpoint (got %d)", label, len(vnext))
	}

	endpoint, ok := vnext[0].(map[string]any)
	if !ok {
		return fmt.Errorf("%s is invalid: settings.vnext[0] must be an object", label)
	}
	if address, _ := endpoint["address"].(string); strings.TrimSpace(address) == "" {
		return fmt.Errorf("%s is invalid: settings.vnext[0].address is required", label)
	}
	if !validVLESSPort(endpoint["port"]) {
		return fmt.Errorf("%s is invalid: settings.vnext[0].port must be an integer from 1 to 65535", label)
	}

	users, ok := endpoint["users"].([]any)
	if !ok {
		return fmt.Errorf("%s is invalid: settings.vnext[0].users must be an array with exactly one user", label)
	}
	if len(users) != 1 {
		return fmt.Errorf("%s is invalid: settings.vnext[0].users must contain exactly one user (got %d)", label, len(users))
	}
	user, ok := users[0].(map[string]any)
	if !ok {
		return fmt.Errorf("%s is invalid: settings.vnext[0].users[0] must be an object", label)
	}
	if id, _ := user["id"].(string); strings.TrimSpace(id) == "" {
		return fmt.Errorf("%s is invalid: settings.vnext[0].users[0].id is required", label)
	}
	if encryption, _ := user["encryption"].(string); strings.TrimSpace(encryption) == "" {
		return fmt.Errorf("%s is invalid: settings.vnext[0].users[0].encryption is required (usually %q)", label, "none")
	}
	return nil
}

func validVLESSPort(raw any) bool {
	switch port := raw.(type) {
	case json.Number:
		value, err := strconv.ParseUint(port.String(), 10, 16)
		return err == nil && value >= 1
	case int:
		return port >= 1 && port <= 65535
	case int64:
		return port >= 1 && port <= 65535
	case uint:
		return port >= 1 && port <= 65535
	case uint64:
		return port >= 1 && port <= 65535
	default:
		return false
	}
}
