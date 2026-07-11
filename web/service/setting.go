package service

import (
	"crypto/tls"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/util/random"
	"github.com/mhsanaei/3x-ui/v2/util/reflect_util"
	"github.com/mhsanaei/3x-ui/v2/web/entity"
	"github.com/mhsanaei/3x-ui/v2/xray"
	"gorm.io/gorm"
)

//go:embed config.json
var xrayTemplateConfig string

const DefaultXrayOutboundTestURL = "https://cp.cloudflare.com/generate_204"

var defaultValueMap = map[string]string{
	"xrayTemplateConfig":                xrayTemplateConfig,
	"webListen":                         "127.0.0.1",
	"webDomain":                         "",
	"webPort":                           "2053",
	"webCertFile":                       "",
	"webKeyFile":                        "",
	"secret":                            random.Seq(32),
	"webBasePath":                       "/",
	"sessionMaxAge":                     "360",
	"pageSize":                          "25",
	"expireDiff":                        "0",
	"trafficDiff":                       "0",
	"securityAlertsEnable":              "false",
	"remarkModel":                       "-ieo",
	"timeLocation":                      "Local",
	"twoFactorEnable":                   "false",
	"twoFactorToken":                    "",
	database.BootstrapPendingSettingKey: "false",
	"subEnable":                         "false",
	"subJsonEnable":                     "false",
	"subTitle":                          "",
	"subSupportUrl":                     "",
	"subProfileUrl":                     "",
	"subAnnounce":                       "",
	"subEnableRouting":                  "true",
	"subRoutingRules":                   "",
	"subListen":                         "127.0.0.1",
	"subPort":                           "2096",
	"subPath":                           "/sub/",
	"subDomain":                         "",
	"subCertFile":                       "",
	"subKeyFile":                        "",
	"subUpdates":                        "12",
	"subEncrypt":                        "true",
	"subShowInfo":                       "true",
	"subURI":                            "",
	"subJsonPath":                       "/json/",
	"subJsonURI":                        "",
	"subClashEnable":                    "false",
	"subClashPath":                      "/clash/",
	"subClashURI":                       "",
	"subJsonFragment":                   "",
	"subJsonNoises":                     "",
	"subJsonMux":                        "",
	"subJsonRules":                      "",
	"datepicker":                        "gregorian",
	"externalTrafficInformEnable":       "false",
	"externalTrafficInformURI":          "",
	"restartXrayOnClientDisable":        "true",
	"xrayOutboundTestUrl":               DefaultXrayOutboundTestURL,
	"warp":                              "",
	"vpngateRefreshInterval":            "120",
	"vpngateFavorites":                  "[]",
	"vpngateRuleMode":                   "default",
	"vpngateSelectedCountries":          "[]",
	"vpngateFallbackEnable":             "true",
}

// SettingService provides business logic for application settings management.
// It handles configuration storage, retrieval, and validation for all system settings.
type SettingService struct{}

func (s *SettingService) GetDefaultJSONConfig() (any, error) {
	var jsonData any
	err := json.Unmarshal([]byte(xrayTemplateConfig), &jsonData)
	if err != nil {
		return nil, err
	}
	return jsonData, nil
}

func (s *SettingService) GetAllSetting() (*entity.AllSetting, error) {
	db := database.GetDB()
	settings := make([]*model.Setting, 0)
	err := db.Model(model.Setting{}).Not("key = ?", "xrayTemplateConfig").Find(&settings).Error
	if err != nil {
		return nil, err
	}
	allSetting := &entity.AllSetting{}
	t := reflect.TypeFor[entity.AllSetting]()
	v := reflect.ValueOf(allSetting).Elem()
	fields := reflect_util.GetFields(t)

	setSetting := func(key, value string) (err error) {
		defer func() {
			panicErr := recover()
			if panicErr != nil {
				err = errors.New(fmt.Sprint(panicErr))
			}
		}()

		var found bool
		var field reflect.StructField
		for _, f := range fields {
			if f.Tag.Get("json") == key {
				field = f
				found = true
				break
			}
		}

		if !found {
			// Some settings are automatically generated, no need to return to the front end to modify the user
			return nil
		}

		fieldV := v.FieldByName(field.Name)
		switch t := fieldV.Interface().(type) {
		case int:
			n, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return err
			}
			fieldV.SetInt(n)
		case string:
			fieldV.SetString(value)
		case bool:
			fieldV.SetBool(value == "true")
		default:
			return common.NewErrorf("unknown field %v type %v", key, t)
		}
		return
	}

	keyMap := map[string]bool{}
	for _, setting := range settings {
		err := setSetting(setting.Key, setting.Value)
		if err != nil {
			return nil, err
		}
		keyMap[setting.Key] = true
	}

	for key, value := range defaultValueMap {
		if keyMap[key] {
			continue
		}
		err := setSetting(key, value)
		if err != nil {
			return nil, err
		}
	}

	return allSetting, nil
}

func (s *SettingService) ResetSettings() error {
	db := database.GetDB()
	// The bootstrap marker is security state, not a user-configurable panel
	// setting. Keeping it prevents a settings reset from making an
	// installation with randomized bootstrap credentials look initialized.
	err := db.Where("key <> ?", database.BootstrapPendingSettingKey).Delete(model.Setting{}).Error
	if err != nil {
		return err
	}
	return db.Model(model.User{}).
		Where("1 = 1").Error
}

func (s *SettingService) getSettingWithDB(db *gorm.DB, key string) (*model.Setting, error) {
	setting := &model.Setting{}
	err := db.Model(model.Setting{}).Where("key = ?", key).First(setting).Error
	if err != nil {
		return nil, err
	}
	return setting, nil
}

func (s *SettingService) getSetting(key string) (*model.Setting, error) {
	return s.getSettingWithDB(database.GetDB(), key)
}

func (s *SettingService) saveSettingWithDB(db *gorm.DB, key string, value string) error {
	setting, err := s.getSettingWithDB(db, key)
	if database.IsNotFound(err) {
		return db.Create(&model.Setting{
			Key:   key,
			Value: value,
		}).Error
	} else if err != nil {
		return err
	}
	setting.Key = key
	setting.Value = value
	return db.Save(setting).Error
}

func (s *SettingService) saveSetting(key string, value string) error {
	return s.saveSettingWithDB(database.GetDB(), key, value)
}

func (s *SettingService) getString(key string) (string, error) {
	setting, err := s.getSetting(key)
	if database.IsNotFound(err) {
		value, ok := defaultValueMap[key]
		if !ok {
			return "", common.NewErrorf("key <%v> not in defaultValueMap", key)
		}
		return value, nil
	} else if err != nil {
		return "", err
	}
	return setting.Value, nil
}

func (s *SettingService) setString(key string, value string) error {
	return s.saveSetting(key, value)
}

func (s *SettingService) getBool(key string) (bool, error) {
	str, err := s.getString(key)
	if err != nil {
		return false, err
	}
	return strconv.ParseBool(str)
}

func (s *SettingService) setBool(key string, value bool) error {
	return s.setString(key, strconv.FormatBool(value))
}

func (s *SettingService) getInt(key string) (int, error) {
	str, err := s.getString(key)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(str)
}

func (s *SettingService) setInt(key string, value int) error {
	return s.setString(key, strconv.Itoa(value))
}

func (s *SettingService) GetXrayConfigTemplate() (string, error) {
	return s.getString("xrayTemplateConfig")
}

func (s *SettingService) GetXrayOutboundTestUrl() (string, error) {
	return s.getString("xrayOutboundTestUrl")
}

func (s *SettingService) SetXrayOutboundTestUrl(url string) error {
	return s.setString("xrayOutboundTestUrl", url)
}

func (s *SettingService) GetSecurityAlertsEnable() (bool, error) {
	return s.getBool("securityAlertsEnable")
}

// GetBootstrapPending reports whether installation-created credentials still
// need to be replaced through the installer or CLI.
func (s *SettingService) GetBootstrapPending() (bool, error) {
	return s.getBool(database.BootstrapPendingSettingKey)
}

func (s *SettingService) SetBootstrapPending(value bool) error {
	return s.setBool(database.BootstrapPendingSettingKey, value)
}

func (s *SettingService) GetWarp() (string, error) {
	return s.getString("warp")
}

func (s *SettingService) SetWarp(data string) error {
	return s.setString("warp", data)
}

func (s *SettingService) GetVPNGateRefreshInterval() (int, error) {
	return s.getInt("vpngateRefreshInterval")
}

func (s *SettingService) SetVPNGateRefreshInterval(value int) error {
	return s.setInt("vpngateRefreshInterval", value)
}

func (s *SettingService) GetVPNGateFavorites() (string, error) {
	return s.getString("vpngateFavorites")
}

func (s *SettingService) SetVPNGateFavorites(value string) error {
	return s.setString("vpngateFavorites", value)
}

func (s *SettingService) GetVPNGateRuleMode() (string, error) {
	return s.getString("vpngateRuleMode")
}

func (s *SettingService) SetVPNGateRuleMode(value string) error {
	return s.setString("vpngateRuleMode", value)
}

func (s *SettingService) GetVPNGateSelectedCountries() (string, error) {
	return s.getString("vpngateSelectedCountries")
}

func (s *SettingService) SetVPNGateSelectedCountries(value string) error {
	return s.setString("vpngateSelectedCountries", value)
}

func (s *SettingService) GetVPNGateFallbackEnable() (bool, error) {
	return s.getBool("vpngateFallbackEnable")
}

func (s *SettingService) SetVPNGateFallbackEnable(value bool) error {
	return s.setBool("vpngateFallbackEnable", value)
}

func (s *SettingService) GetListen() (string, error) {
	return s.getString("webListen")
}

func (s *SettingService) SetListen(ip string) error {
	return s.setString("webListen", ip)
}

func (s *SettingService) GetWebDomain() (string, error) {
	return s.getString("webDomain")
}

func (s *SettingService) GetTwoFactorEnable() (bool, error) {
	return s.getBool("twoFactorEnable")
}

func (s *SettingService) SetTwoFactorEnable(value bool) error {
	return s.setBool("twoFactorEnable", value)
}

func (s *SettingService) GetTwoFactorToken() (string, error) {
	return s.getString("twoFactorToken")
}

func (s *SettingService) SetTwoFactorToken(value string) error {
	return s.setString("twoFactorToken", value)
}

func (s *SettingService) GetPort() (int, error) {
	return s.getInt("webPort")
}

func (s *SettingService) SetPort(port int) error {
	return s.setInt("webPort", port)
}

func (s *SettingService) SetCertFile(webCertFile string) error {
	return s.setString("webCertFile", webCertFile)
}

func (s *SettingService) GetCertFile() (string, error) {
	return s.getString("webCertFile")
}

func (s *SettingService) SetKeyFile(webKeyFile string) error {
	return s.setString("webKeyFile", webKeyFile)
}

// SetCertificateFiles updates panel and subscription certificate paths in one
// transaction so command-line certificate changes cannot leave a partial pair.
func (s *SettingService) SetCertificateFiles(certFile, keyFile string) error {
	values := []struct {
		key   string
		value string
	}{
		{key: "webCertFile", value: certFile},
		{key: "webKeyFile", value: keyFile},
		{key: "subCertFile", value: certFile},
		{key: "subKeyFile", value: keyFile},
	}

	return database.GetDB().Transaction(func(tx *gorm.DB) error {
		for _, item := range values {
			if err := s.saveSettingWithDB(tx, item.key, item.value); err != nil {
				return fmt.Errorf("set %s: %w", item.key, err)
			}
		}
		return nil
	})
}

func (s *SettingService) GetKeyFile() (string, error) {
	return s.getString("webKeyFile")
}

func (s *SettingService) GetExpireDiff() (int, error) {
	return s.getInt("expireDiff")
}

func (s *SettingService) GetTrafficDiff() (int, error) {
	return s.getInt("trafficDiff")
}

func (s *SettingService) GetSessionMaxAge() (int, error) {
	return s.getInt("sessionMaxAge")
}

func (s *SettingService) GetRemarkModel() (string, error) {
	return s.getString("remarkModel")
}

func (s *SettingService) GetSecret() ([]byte, error) {
	secret, err := s.getString("secret")
	if secret == defaultValueMap["secret"] {
		err := s.saveSetting("secret", secret)
		if err != nil {
			logger.Warning("save secret failed:", err)
		}
	}
	return []byte(secret), err
}

func (s *SettingService) SetBasePath(basePath string) error {
	if !strings.HasPrefix(basePath, "/") {
		basePath = "/" + basePath
	}
	if !strings.HasSuffix(basePath, "/") {
		basePath += "/"
	}
	return s.setString("webBasePath", basePath)
}

func (s *SettingService) GetBasePath() (string, error) {
	basePath, err := s.getString("webBasePath")
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(basePath, "/") {
		basePath = "/" + basePath
	}
	if !strings.HasSuffix(basePath, "/") {
		basePath += "/"
	}
	return basePath, nil
}

func (s *SettingService) GetTimeLocation() (*time.Location, error) {
	l, err := s.getString("timeLocation")
	if err != nil {
		return nil, err
	}
	location, err := time.LoadLocation(l)
	if err != nil {
		defaultLocation := defaultValueMap["timeLocation"]
		logger.Errorf("location <%v> not exist, using default location: %v", l, defaultLocation)
		location, err = time.LoadLocation(defaultLocation)
		if err != nil {
			logger.Errorf("failed to load default location, using UTC: %v", err)
			return time.UTC, nil
		}
		return location, nil
	}
	return location, nil
}

func (s *SettingService) GetSubEnable() (bool, error) {
	return s.getBool("subEnable")
}

func (s *SettingService) GetSubJsonEnable() (bool, error) {
	return s.getBool("subJsonEnable")
}

func (s *SettingService) GetSubTitle() (string, error) {
	return s.getString("subTitle")
}

func (s *SettingService) GetSubSupportUrl() (string, error) {
	return s.getString("subSupportUrl")
}

func (s *SettingService) GetSubProfileUrl() (string, error) {
	return s.getString("subProfileUrl")
}

func (s *SettingService) GetSubAnnounce() (string, error) {
	return s.getString("subAnnounce")
}

func (s *SettingService) GetSubEnableRouting() (bool, error) {
	return s.getBool("subEnableRouting")
}

func (s *SettingService) GetSubRoutingRules() (string, error) {
	return s.getString("subRoutingRules")
}

func (s *SettingService) GetSubListen() (string, error) {
	return s.getString("subListen")
}

func (s *SettingService) GetSubPort() (int, error) {
	return s.getInt("subPort")
}

func (s *SettingService) GetSubPath() (string, error) {
	return s.getString("subPath")
}

func (s *SettingService) GetSubJsonPath() (string, error) {
	return s.getString("subJsonPath")
}

func (s *SettingService) GetSubDomain() (string, error) {
	return s.getString("subDomain")
}

func (s *SettingService) SetSubCertFile(subCertFile string) error {
	return s.setString("subCertFile", subCertFile)
}

func (s *SettingService) GetSubCertFile() (string, error) {
	return s.getString("subCertFile")
}

func (s *SettingService) SetSubKeyFile(subKeyFile string) error {
	return s.setString("subKeyFile", subKeyFile)
}

func (s *SettingService) GetSubKeyFile() (string, error) {
	return s.getString("subKeyFile")
}

func (s *SettingService) GetSubUpdates() (string, error) {
	return s.getString("subUpdates")
}

func (s *SettingService) GetSubEncrypt() (bool, error) {
	return s.getBool("subEncrypt")
}

func (s *SettingService) GetSubShowInfo() (bool, error) {
	return s.getBool("subShowInfo")
}

func (s *SettingService) GetPageSize() (int, error) {
	return s.getInt("pageSize")
}

func (s *SettingService) GetSubURI() (string, error) {
	return s.getString("subURI")
}

func (s *SettingService) GetSubJsonURI() (string, error) {
	return s.getString("subJsonURI")
}

func (s *SettingService) GetSubClashEnable() (bool, error) {
	return s.getBool("subClashEnable")
}

func (s *SettingService) GetSubClashPath() (string, error) {
	return s.getString("subClashPath")
}

func (s *SettingService) GetSubClashURI() (string, error) {
	return s.getString("subClashURI")
}

func (s *SettingService) GetSubJsonFragment() (string, error) {
	return s.getString("subJsonFragment")
}

func (s *SettingService) GetSubJsonNoises() (string, error) {
	return s.getString("subJsonNoises")
}

func (s *SettingService) GetSubJsonMux() (string, error) {
	return s.getString("subJsonMux")
}

func (s *SettingService) GetSubJsonRules() (string, error) {
	return s.getString("subJsonRules")
}

func (s *SettingService) GetDatepicker() (string, error) {
	return s.getString("datepicker")
}

func (s *SettingService) GetExternalTrafficInformEnable() (bool, error) {
	return s.getBool("externalTrafficInformEnable")
}

func (s *SettingService) SetExternalTrafficInformEnable(value bool) error {
	return s.setBool("externalTrafficInformEnable", value)
}

func (s *SettingService) GetExternalTrafficInformURI() (string, error) {
	return s.getString("externalTrafficInformURI")
}

func (s *SettingService) SetExternalTrafficInformURI(InformURI string) error {
	return s.setString("externalTrafficInformURI", InformURI)
}

func (s *SettingService) GetRestartXrayOnClientDisable() (bool, error) {
	return s.getBool("restartXrayOnClientDisable")
}

func (s *SettingService) SetRestartXrayOnClientDisable(value bool) error {
	return s.setBool("restartXrayOnClientDisable", value)
}

func (s *SettingService) GetIpLimitEnable() (bool, error) {
	accessLogPath, err := xray.GetAccessLogPath()
	if err != nil {
		return false, err
	}
	return (accessLogPath != "none" && accessLogPath != ""), nil
}

func (s *SettingService) UpdateAllSetting(allSetting *entity.AllSetting) error {
	if err := allSetting.CheckValid(); err != nil {
		return err
	}

	v := reflect.ValueOf(allSetting).Elem()
	t := reflect.TypeFor[entity.AllSetting]()
	fields := reflect_util.GetFields(t)
	errs := make([]error, 0)
	for _, field := range fields {
		key := field.Tag.Get("json")
		fieldV := v.FieldByName(field.Name)
		value := fmt.Sprint(fieldV.Interface())
		err := s.saveSetting(key, value)
		if err != nil {
			errs = append(errs, err)
		}
	}
	return common.Combine(errs...)
}

func (s *SettingService) GetDefaultXrayConfig() (any, error) {
	var jsonData any
	err := json.Unmarshal([]byte(xrayTemplateConfig), &jsonData)
	if err != nil {
		return nil, err
	}
	return jsonData, nil
}

func extractHostname(host string) string {
	h, _, err := net.SplitHostPort(host)
	// Err is not nil means host does not contain port
	if err != nil {
		h = host
	}

	ip := net.ParseIP(h)
	// If it's not an IP, return as is
	if ip == nil {
		return h
	}

	// If it's an IPv4, return as is
	if ip.To4() != nil {
		return h
	}

	// IPv6 needs bracketing
	return "[" + h + "]"
}

func (s *SettingService) GetDefaultSettings(host string) (any, error) {
	type settingFunc func() (any, error)
	settings := map[string]settingFunc{
		"expireDiff":     func() (any, error) { return s.GetExpireDiff() },
		"trafficDiff":    func() (any, error) { return s.GetTrafficDiff() },
		"pageSize":       func() (any, error) { return s.GetPageSize() },
		"defaultCert":    func() (any, error) { return s.GetCertFile() },
		"defaultKey":     func() (any, error) { return s.GetKeyFile() },
		"subEnable":      func() (any, error) { return s.GetSubEnable() },
		"subJsonEnable":  func() (any, error) { return s.GetSubJsonEnable() },
		"subClashEnable": func() (any, error) { return s.GetSubClashEnable() },
		"subTitle":       func() (any, error) { return s.GetSubTitle() },
		"subURI":         func() (any, error) { return s.GetSubURI() },
		"subJsonURI":     func() (any, error) { return s.GetSubJsonURI() },
		"subClashURI":    func() (any, error) { return s.GetSubClashURI() },
		"remarkModel":    func() (any, error) { return s.GetRemarkModel() },
		"datepicker":     func() (any, error) { return s.GetDatepicker() },
		"ipLimitEnable":  func() (any, error) { return s.GetIpLimitEnable() },
		"securityAlertsEnable": func() (any, error) {
			return s.GetSecurityAlertsEnable()
		},
	}

	result := make(map[string]any)

	for key, fn := range settings {
		value, err := fn()
		if err != nil {
			return "", err
		}
		result[key] = value
	}

	subEnable := result["subEnable"].(bool)
	subJsonEnable := false
	if v, ok := result["subJsonEnable"]; ok {
		if b, ok2 := v.(bool); ok2 {
			subJsonEnable = b
		}
	}
	subClashEnable := false
	if v, ok := result["subClashEnable"]; ok {
		if b, ok2 := v.(bool); ok2 {
			subClashEnable = b
		}
	}
	if subEnable && (result["subURI"].(string) == "" || (subJsonEnable && result["subJsonURI"].(string) == "") || (subClashEnable && result["subClashURI"].(string) == "")) {
		subURI := ""
		subTitle, _ := s.GetSubTitle()
		subPort, _ := s.GetSubPort()
		subPath, _ := s.GetSubPath()
		subJsonPath, _ := s.GetSubJsonPath()
		subClashPath, _ := s.GetSubClashPath()
		subDomain, _ := s.GetSubDomain()
		subKeyFile, _ := s.GetSubKeyFile()
		subCertFile, _ := s.GetSubCertFile()
		subTLS := false
		if subKeyFile != "" && subCertFile != "" {
			_, err := tls.LoadX509KeyPair(subCertFile, subKeyFile)
			subTLS = err == nil
		}
		// Base64 encoding does not protect subscription credentials. Do not
		// manufacture an HTTP URL when this server has no valid TLS pair.
		if !subTLS {
			return result, nil
		}
		if subDomain == "" {
			subDomain = extractHostname(host)
		}
		subURI = "https://"
		if subPort == 443 {
			subURI += subDomain
		} else {
			subURI += fmt.Sprintf("%s:%d", subDomain, subPort)
		}
		if subEnable && result["subURI"].(string) == "" {
			result["subURI"] = subURI + subPath
		}
		if result["subTitle"].(string) == "" {
			result["subTitle"] = subTitle
		}
		if subJsonEnable && result["subJsonURI"].(string) == "" {
			result["subJsonURI"] = subURI + subJsonPath
		}
		if subClashEnable && result["subClashURI"].(string) == "" {
			result["subClashURI"] = subURI + subClashPath
		}
	}

	return result, nil
}
