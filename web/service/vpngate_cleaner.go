package service

type VPNGateCleaner struct{}

func (VPNGateCleaner) Remove() error {
	// 1. Cancel/stop any running openvpn tasks
	vpnGateOpenVPN.Lock()
	vpnGateOpenVPN.stopLocked()
	vpnGateOpenVPN.status.Phase = "idle"
	vpnGateOpenVPN.status.Progress = 0
	vpnGateOpenVPN.status.Message = "未连接"
	vpnGateOpenVPN.status.Error = ""
	vpnGateOpenVPN.status.TunIP = ""
	vpnGateOpenVPN.status.TunDev = ""
	vpnGateOpenVPN.status.Outbound = nil
	vpnGateOpenVPN.Unlock()

	// 2. Clear node information (servers list cache)
	vpngateService := &VPNGateService{}
	vpngateService.ClearCache()

	// 3. Remove outbound tag "vpngate" from xray template
	_ = removeXrayVPNGateOutbound()

	return nil
}
