package network

import (
	"crypto/tls"
	"net"
	"testing"
)

func TestRestrictInsecureListen(t *testing.T) {
	tests := []struct {
		name       string
		listen     string
		tlsEnabled bool
		override   string
		wantListen string
		wantLocked bool
	}{
		{name: "wildcard HTTP is restricted", listen: "", wantListen: LoopbackListenAddress, wantLocked: true},
		{name: "public IPv4 HTTP is restricted", listen: "0.0.0.0", wantListen: LoopbackListenAddress, wantLocked: true},
		{name: "public IPv6 HTTP is restricted", listen: "::", wantListen: LoopbackListenAddress, wantLocked: true},
		{name: "loopback IPv4 HTTP is allowed", listen: "127.0.0.1", wantListen: "127.0.0.1"},
		{name: "loopback IPv6 HTTP is allowed", listen: "::1", wantListen: "::1"},
		{name: "TLS public listener is allowed", listen: "0.0.0.0", tlsEnabled: true, wantListen: "0.0.0.0"},
		{name: "explicit legacy override is allowed", listen: "0.0.0.0", override: "true", wantListen: "0.0.0.0"},
		{name: "non-true override is denied", listen: "0.0.0.0", override: "yes", wantListen: LoopbackListenAddress, wantLocked: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(AllowInsecureHTTPEnv, tt.override)
			gotListen, gotLocked := RestrictInsecureListen(tt.listen, tt.tlsEnabled)
			if gotListen != tt.wantListen || gotLocked != tt.wantLocked {
				t.Fatalf("RestrictInsecureListen(%q, %v) = (%q, %v), want (%q, %v)", tt.listen, tt.tlsEnabled, gotListen, gotLocked, tt.wantListen, tt.wantLocked)
			}
		})
	}
}

func TestIsLoopbackListen(t *testing.T) {
	for _, listen := range []string{"127.0.0.1", "::1", "[::1]", "localhost"} {
		if !IsLoopbackListen(listen) {
			t.Errorf("%q should be loopback", listen)
		}
	}
	for _, listen := range []string{"", "0.0.0.0", "::", "192.0.2.1"} {
		if IsLoopbackListen(listen) {
			t.Errorf("%q should not be loopback", listen)
		}
	}
}

func TestNewRestrictedListenerBindsPlaintextPublicRequestsToLoopback(t *testing.T) {
	listener, restricted, err := NewRestrictedListener("0.0.0.0", 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	if !restricted {
		t.Fatal("public plaintext listener was not restricted")
	}
	tcpAddr, ok := listener.Addr().(*net.TCPAddr)
	if !ok || !tcpAddr.IP.IsLoopback() {
		t.Fatalf("listener address = %v, want loopback TCP address", listener.Addr())
	}
}

func TestNewRestrictedListenerKeepsTLSListenerAddress(t *testing.T) {
	listener, restricted, err := NewRestrictedListener("127.0.0.1", 0, &tls.Config{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	if restricted {
		t.Fatal("TLS listener should not be restricted")
	}
	if tcpAddr, ok := listener.Addr().(*net.TCPAddr); !ok || !tcpAddr.IP.IsLoopback() {
		t.Fatalf("TLS listener address = %v, want configured loopback TCP address", listener.Addr())
	}
}

func TestInvalidTLSConfigFallsBackToLoopbackOnly(t *testing.T) {
	tlsConfig, err := LoadTLSConfig("missing-cert.pem", "missing-key.pem")
	if err == nil || tlsConfig != nil {
		t.Fatalf("LoadTLSConfig() = (%v, %v), want nil config and an error", tlsConfig, err)
	}

	listener, restricted, err := NewRestrictedListener("0.0.0.0", 0, tlsConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if !restricted {
		t.Fatal("invalid TLS configuration permitted a public HTTP listener")
	}
	if tcpAddr, ok := listener.Addr().(*net.TCPAddr); !ok || !tcpAddr.IP.IsLoopback() {
		t.Fatalf("listener address = %v, want loopback after invalid TLS", listener.Addr())
	}
}
