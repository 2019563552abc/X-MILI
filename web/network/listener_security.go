package network

import (
	"crypto/tls"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
)

const (
	// AllowInsecureHTTPEnv is an explicit, temporary escape hatch for legacy
	// deployments that intentionally expose the panel or subscriptions over HTTP.
	// Public HTTP is otherwise restricted to loopback to prevent credential and
	// subscription-token disclosure.
	AllowInsecureHTTPEnv = "XUI_ALLOW_INSECURE_HTTP"

	// LoopbackListenAddress is the fail-closed listener used when a public HTTP
	// listener has not been explicitly allowed or protected by TLS.
	LoopbackListenAddress = "127.0.0.1"
)

// InsecureHTTPAllowed reports whether an operator has explicitly opted into
// public HTTP for a legacy deployment.
func InsecureHTTPAllowed() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv(AllowInsecureHTTPEnv)), "true")
}

// IsLoopbackListen reports whether listen is a loopback address. An empty
// address is a wildcard listener and is intentionally not treated as local.
func IsLoopbackListen(listen string) bool {
	listen = strings.TrimSpace(strings.Trim(listen, "[]"))
	if strings.EqualFold(listen, "localhost") {
		return true
	}
	addr, err := netip.ParseAddr(listen)
	return err == nil && addr.IsLoopback()
}

// RestrictInsecureListen returns the safe listener and whether the requested
// listener was restricted. TLS-protected listeners and explicit operator
// overrides keep their configured address; plaintext public listeners fail
// closed to loopback.
func RestrictInsecureListen(listen string, tlsEnabled bool) (string, bool) {
	if tlsEnabled || InsecureHTTPAllowed() || IsLoopbackListen(listen) {
		return listen, false
	}
	return LoopbackListenAddress, true
}

// LoadTLSConfig returns a strict TLS server configuration when both certificate
// files load successfully. An absent pair intentionally means plaintext; a
// partial or invalid pair returns an error so callers can fail closed to a
// loopback-only plaintext listener instead of exposing a public HTTP fallback.
func LoadTLSConfig(certFile, keyFile string) (*tls.Config, error) {
	if certFile == "" && keyFile == "" {
		return nil, nil
	}

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, err
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}}, nil
}

// NewRestrictedListener creates a TCP listener only after the TLS decision has
// been made. Public plaintext listeners are rebound to loopback unless the
// operator explicitly set XUI_ALLOW_INSECURE_HTTP=true. A non-nil TLS config is
// wrapped directly, so plaintext requests are rejected rather than redirected
// after their credentials or subscription token have already been transmitted.
func NewRestrictedListener(listen string, port int, tlsConfig *tls.Config) (net.Listener, bool, error) {
	safeListen, restricted := RestrictInsecureListen(listen, tlsConfig != nil)
	listener, err := net.Listen("tcp", net.JoinHostPort(safeListen, strconv.Itoa(port)))
	if err != nil {
		return nil, restricted, err
	}
	if tlsConfig != nil {
		listener = tls.NewListener(listener, tlsConfig)
	}
	return listener, restricted, nil
}
