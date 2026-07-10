package service

import (
	"fmt"
	"os"
	"syscall"
	"time"

	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/logger"
)

// PanelService provides business logic for panel management operations.
// It handles panel restart, updates, and system-level panel controls.
type PanelService struct{}

// PanelUpdateInfo contains the current and latest available panel versions.
type PanelUpdateInfo struct {
	CurrentVersion  string `json:"currentVersion"`
	LatestVersion   string `json:"latestVersion"`
	UpdateAvailable bool   `json:"updateAvailable"`
}

func (s *PanelService) RestartPanel(delay time.Duration) error {
	p, err := os.FindProcess(syscall.Getpid())
	if err != nil {
		return err
	}
	go func() {
		time.Sleep(delay)
		err := p.Signal(syscall.SIGHUP)
		if err != nil {
			logger.Error("failed to send SIGHUP signal:", err)
		}
	}()
	return nil
}

// GetUpdateInfo returns local version info. Upstream update checks are disabled for this fork.
func (s *PanelService) GetUpdateInfo() (*PanelUpdateInfo, error) {
	current := config.GetVersion()
	return &PanelUpdateInfo{
		CurrentVersion:  current,
		LatestVersion:   current,
		UpdateAvailable: false,
	}, nil
}

// StartUpdate is disabled because this fork should not pull upstream release scripts.
func (s *PanelService) StartUpdate() error {
	return fmt.Errorf("panel web update is disabled for this fork")
}
