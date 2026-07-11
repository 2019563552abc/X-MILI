package service

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/util/json_util"
	"github.com/mhsanaei/3x-ui/v2/xray"

	"gorm.io/gorm"
)

// OutboundService provides business logic for managing Xray outbound configurations.
// It handles outbound traffic monitoring and statistics.
type OutboundService struct{}

// testSemaphore limits concurrent outbound tests to prevent resource exhaustion.
var testSemaphore sync.Mutex

func (s *OutboundService) AddTraffic(traffics []*xray.Traffic, clientTraffics []*xray.ClientTraffic) (error, bool) {
	var err error
	db := database.GetDB()
	tx := db.Begin()

	defer func() {
		if err != nil {
			tx.Rollback()
		} else {
			tx.Commit()
		}
	}()

	err = s.addOutboundTraffic(tx, traffics)
	if err != nil {
		return err, false
	}

	return nil, false
}

func (s *OutboundService) addOutboundTraffic(tx *gorm.DB, traffics []*xray.Traffic) error {
	if len(traffics) == 0 {
		return nil
	}

	var err error

	for _, traffic := range traffics {
		if traffic.IsOutbound {

			var outbound model.OutboundTraffics

			err = tx.Model(&model.OutboundTraffics{}).Where("tag = ?", traffic.Tag).
				FirstOrCreate(&outbound).Error
			if err != nil {
				return err
			}

			outbound.Tag = traffic.Tag
			outbound.Up = outbound.Up + traffic.Up
			outbound.Down = outbound.Down + traffic.Down
			outbound.Total = outbound.Up + outbound.Down

			err = tx.Save(&outbound).Error
			if err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *OutboundService) GetOutboundsTraffic() ([]*model.OutboundTraffics, error) {
	db := database.GetDB()
	var traffics []*model.OutboundTraffics

	err := db.Model(model.OutboundTraffics{}).Find(&traffics).Error
	if err != nil {
		logger.Warning("Error retrieving OutboundTraffics: ", err)
		return nil, err
	}

	return traffics, nil
}

func (s *OutboundService) ResetOutboundTraffic(tag string) error {
	db := database.GetDB()

	whereText := "tag "
	if tag == "-alltags-" {
		whereText += " <> ?"
	} else {
		whereText += " = ?"
	}

	result := db.Model(model.OutboundTraffics{}).
		Where(whereText, tag).
		Updates(map[string]any{"up": 0, "down": 0, "total": 0})

	err := result.Error
	if err != nil {
		return err
	}

	return nil
}

// TestOutboundResult represents the result of testing an outbound
type TestOutboundResult struct {
	Success    bool   `json:"success"`
	Delay      int64  `json:"delay"` // Delay in milliseconds
	Error      string `json:"error,omitempty"`
	StatusCode int    `json:"statusCode,omitempty"`
	Outbound   any    `json:"outbound,omitempty"`
}

// TestOutbound tests an outbound by creating a temporary xray instance and measuring response time.
// allOutboundsJSON is used to resolve explicit outbound dependencies. The temporary
// config includes only the tested outbound and its dependency closure.
func (s *OutboundService) TestOutbound(outboundJSON string, testURL string, allOutboundsJSON string) (*TestOutboundResult, error) {
	if testURL == "" {
		testURL = DefaultXrayOutboundTestURL
	}

	// Limit to one concurrent test at a time
	if !testSemaphore.TryLock() {
		return &TestOutboundResult{
			Success: false,
			Error:   "Another outbound test is already running, please wait",
		}, nil
	}
	defer testSemaphore.Unlock()

	// Parse the outbound being tested to get its tag
	var testOutbound map[string]any
	if err := decodeJSONUseNumber([]byte(outboundJSON), &testOutbound); err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Invalid outbound JSON: %v", err),
		}, nil
	}
	outboundTag, _ := testOutbound["tag"].(string)
	if outboundTag == "" {
		return &TestOutboundResult{
			Success: false,
			Error:   "Outbound has no tag",
		}, nil
	}
	if protocol, _ := testOutbound["protocol"].(string); protocol == "blackhole" || outboundTag == "blocked" {
		return &TestOutboundResult{
			Success: false,
			Error:   "Blocked/blackhole outbound cannot be tested",
		}, nil
	}

	// Use the posted list only as a dependency catalog. Unrelated outbounds must
	// not make an otherwise independent outbound test fail.
	var allOutbounds []any
	if allOutboundsJSON != "" {
		if err := decodeJSONUseNumber([]byte(allOutboundsJSON), &allOutbounds); err != nil {
			return &TestOutboundResult{
				Success: false,
				Error:   fmt.Sprintf("Invalid allOutbounds JSON: %v", err),
			}, nil
		}
	}
	selectedOutbounds, err := selectOutboundTestClosure(testOutbound, allOutbounds)
	if err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Invalid outbound dependency graph: %v", err),
		}, nil
	}
	if err := validateVLESSOutbounds(selectedOutbounds); err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Invalid outbound configuration: %v", err),
		}, nil
	}

	// Find an available port for test inbound
	testPort, err := findAvailablePort()
	if err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Failed to find available port: %v", err),
		}, nil
	}

	// Copy the selected dependency closure as-is, then add the test inbound and route rule.
	testConfig := s.createTestConfig(outboundTag, selectedOutbounds, testPort)

	// Use a temporary config file so the main config.json is never overwritten
	testConfigPath, err := createTestConfigPath()
	if err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Failed to create test config path: %v", err),
		}, nil
	}
	defer os.Remove(testConfigPath) // ensure temp file is removed even if process is not stopped

	// Create temporary xray process with its own config file
	testProcess := xray.NewTestProcess(testConfig, testConfigPath)
	defer func() {
		if testProcess.IsRunning() {
			testProcess.Stop()
		}
	}()

	// Start the test process
	if err := testProcess.Start(); err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Failed to start test xray instance: %v", err),
		}, nil
	}

	// Wait for xray to start listening on the test port
	if err := waitForPort(testPort, 3*time.Second); err != nil {
		if !testProcess.IsRunning() {
			result := testProcess.GetResult()
			return &TestOutboundResult{
				Success: false,
				Error:   fmt.Sprintf("Xray process exited: %s", result),
			}, nil
		}
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Xray failed to start listening: %v", err),
		}, nil
	}

	// Check if process is still running
	if !testProcess.IsRunning() {
		result := testProcess.GetResult()
		return &TestOutboundResult{
			Success: false,
			Error:   fmt.Sprintf("Xray process exited: %s", result),
		}, nil
	}

	// Test the connection through proxy
	delay, statusCode, err := s.testConnection(testPort, testURL)
	if err != nil {
		return &TestOutboundResult{
			Success: false,
			Error:   err.Error(),
		}, nil
	}

	return &TestOutboundResult{
		Success:    true,
		Delay:      delay,
		StatusCode: statusCode,
	}, nil
}

// selectOutboundTestClosure returns the tested outbound plus every outbound it
// explicitly depends on through sockopt.dialerProxy or proxySettings.tag.
// The tested object is authoritative even when allOutbounds contains an older
// object with the same tag.
func selectOutboundTestClosure(testOutbound map[string]any, allOutbounds []any) ([]any, error) {
	rootTag, _ := testOutbound["tag"].(string)
	if strings.TrimSpace(rootTag) == "" {
		return nil, fmt.Errorf("tested outbound has no tag")
	}

	catalog := make(map[string]map[string]any)
	duplicates := make(map[string]bool)
	for _, rawOutbound := range allOutbounds {
		outbound, ok := rawOutbound.(map[string]any)
		if !ok {
			continue
		}
		tag, _ := outbound["tag"].(string)
		if strings.TrimSpace(tag) == "" || tag == rootTag {
			continue
		}
		if _, exists := catalog[tag]; exists {
			duplicates[tag] = true
			continue
		}
		catalog[tag] = outbound
	}

	selected := make([]any, 0, len(catalog)+1)
	state := make(map[string]uint8)
	var visit func(string, map[string]any) error
	visit = func(tag string, outbound map[string]any) error {
		switch state[tag] {
		case 1:
			return fmt.Errorf("outbound dependency cycle detected at tag %q", tag)
		case 2:
			return nil
		}

		state[tag] = 1
		selected = append(selected, outbound)
		dependencies, err := outboundDependencyTags(tag, outbound)
		if err != nil {
			return err
		}
		for _, dependencyTag := range dependencies {
			if state[dependencyTag] == 1 {
				return fmt.Errorf("outbound dependency cycle detected from tag %q to tag %q", tag, dependencyTag)
			}
			if duplicates[dependencyTag] {
				return fmt.Errorf("outbound tag %q has duplicate dependency tag %q", tag, dependencyTag)
			}

			var dependency map[string]any
			if dependencyTag == rootTag {
				dependency = testOutbound
			} else {
				dependency = catalog[dependencyTag]
			}
			if dependency == nil {
				return fmt.Errorf("outbound tag %q has missing dependency %q", tag, dependencyTag)
			}
			if err := visit(dependencyTag, dependency); err != nil {
				return err
			}
		}
		state[tag] = 2
		return nil
	}

	if err := visit(rootTag, testOutbound); err != nil {
		return nil, err
	}
	return selected, nil
}

func outboundDependencyTags(outboundTag string, outbound map[string]any) ([]string, error) {
	dependencies := make([]string, 0, 2)
	if streamSettings, ok := outbound["streamSettings"].(map[string]any); ok {
		if sockopt, ok := streamSettings["sockopt"].(map[string]any); ok {
			if rawTag, exists := sockopt["dialerProxy"]; exists {
				tag, ok := rawTag.(string)
				if !ok {
					return nil, fmt.Errorf("outbound tag %q has non-string streamSettings.sockopt.dialerProxy", outboundTag)
				}
				if strings.TrimSpace(tag) != "" {
					dependencies = append(dependencies, tag)
				}
			}
		}
	}
	if proxySettings, ok := outbound["proxySettings"].(map[string]any); ok {
		if rawTag, exists := proxySettings["tag"]; exists {
			tag, ok := rawTag.(string)
			if !ok {
				return nil, fmt.Errorf("outbound tag %q has non-string proxySettings.tag", outboundTag)
			}
			if strings.TrimSpace(tag) != "" {
				dependencies = append(dependencies, tag)
			}
		}
	}
	return dependencies, nil
}

// createTestConfig creates a test config from the selected outbound dependency
// closure and adds only the test inbound and route rule.
func (s *OutboundService) createTestConfig(outboundTag string, selectedOutbounds []any, testPort int) *xray.Config {
	// Test inbound (SOCKS proxy) - only addition to inbounds
	testInbound := xray.InboundConfig{
		Tag:      "test-inbound",
		Listen:   json_util.RawMessage(`"127.0.0.1"`),
		Port:     testPort,
		Protocol: "socks",
		Settings: json_util.RawMessage(`{"auth":"noauth","udp":true}`),
	}

	// Outbounds: copy all, but set noKernelTun=true for WireGuard outbounds
	processedOutbounds := make([]any, len(selectedOutbounds))
	for i, ob := range selectedOutbounds {
		outbound, ok := ob.(map[string]any)
		if !ok {
			processedOutbounds[i] = ob
			continue
		}
		raw, _ := json.Marshal(outbound)
		var outboundCopy map[string]any
		_ = json.Unmarshal(raw, &outboundCopy)
		outbound = outboundCopy
		if protocol, ok := outbound["protocol"].(string); ok && protocol == "wireguard" {
			// Set noKernelTun to true for WireGuard outbounds
			if settings, ok := outbound["settings"].(map[string]any); ok {
				settings["noKernelTun"] = true
			} else {
				// Create settings if it doesn't exist
				outbound["settings"] = map[string]any{
					"noKernelTun": true,
				}
			}
		}
		processedOutbounds[i] = outbound
	}
	outboundsJSON, _ := json.Marshal(processedOutbounds)

	// Create routing rule to route all traffic through test outbound
	routingRules := []map[string]any{
		{
			"type":        "field",
			"outboundTag": outboundTag,
			"network":     "tcp,udp",
		},
	}

	routingJSON, _ := json.Marshal(map[string]any{
		"domainStrategy": "AsIs",
		"rules":          routingRules,
	})

	// Disable logging for test process to avoid creating orphaned log files
	logConfig := map[string]any{
		"loglevel": "warning",
		"access":   "none",
		"error":    "none",
		"dnsLog":   false,
	}
	logJSON, _ := json.Marshal(logConfig)

	// Create minimal config
	cfg := &xray.Config{
		LogConfig: json_util.RawMessage(logJSON),
		InboundConfigs: []xray.InboundConfig{
			testInbound,
		},
		OutboundConfigs: json_util.RawMessage(string(outboundsJSON)),
		RouterConfig:    json_util.RawMessage(string(routingJSON)),
		Policy:          json_util.RawMessage(`{}`),
		Stats:           json_util.RawMessage(`{}`),
	}

	return cfg
}

// testConnection tests the connection through the proxy and measures delay.
// It performs a warmup request first to establish the SOCKS connection and populate DNS caches,
// then measures the second request for a more accurate latency reading.
func (s *OutboundService) testConnection(proxyPort int, testURL string) (int64, int, error) {
	// Create SOCKS5 proxy URL
	proxyURL := fmt.Sprintf("socks5://127.0.0.1:%d", proxyPort)

	// Parse proxy URL
	proxyURLParsed, err := url.Parse(proxyURL)
	if err != nil {
		return 0, 0, common.NewErrorf("Invalid proxy URL: %v", err)
	}

	// Create HTTP client with proxy and keep-alive for connection reuse
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			Proxy: http.ProxyURL(proxyURLParsed),
			DialContext: (&net.Dialer{
				Timeout:   5 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
			MaxIdleConns:       1,
			IdleConnTimeout:    10 * time.Second,
			DisableCompression: true,
		},
	}

	// Warmup request: establishes SOCKS/TLS connection, DNS, and TCP to the target.
	// This mirrors real-world usage where connections are reused.
	warmupResp, err := client.Get(testURL)
	if err != nil {
		return 0, 0, common.NewErrorf("Request failed: %v", err)
	}
	io.Copy(io.Discard, warmupResp.Body)
	warmupResp.Body.Close()

	// Measure the actual request on the warm connection
	startTime := time.Now()
	resp, err := client.Get(testURL)
	delay := time.Since(startTime).Milliseconds()

	if err != nil {
		return 0, 0, common.NewErrorf("Request failed: %v", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	return delay, resp.StatusCode, nil
}

// waitForPort polls until the given TCP port is accepting connections or the timeout expires.
func waitForPort(port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("port %d not ready after %v", port, timeout)
}

// findAvailablePort finds an available port for testing
func findAvailablePort() (int, error) {
	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()

	addr := listener.Addr().(*net.TCPAddr)
	return addr.Port, nil
}

// createTestConfigPath returns a unique path for a temporary xray config file in the bin folder.
// The temp file is created and closed so the path is reserved; Start() will overwrite it.
func createTestConfigPath() (string, error) {
	tmpFile, err := os.CreateTemp(config.GetBinFolderPath(), "xray_test_*.json")
	if err != nil {
		return "", err
	}
	path := tmpFile.Name()
	if err := tmpFile.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}
