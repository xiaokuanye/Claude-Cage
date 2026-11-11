package remotehost

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/sylvinus/agent-vm/internal/host"
)

// This exercises the real fixture SSH tunnel and Session.Transport through a
// standard reverse proxy. The backend models audio's wire behavior without
// importing workbench; it is not a production capture or WebView playback test.
func TestAudioCompressionThroughSSHReverseProxy(t *testing.T) {
	for _, compression := range []bool{false, true} {
		name := "plain-client"
		if compression {
			name = "compression-client"
		}
		t.Run(name, func(t *testing.T) {
			const packetBytes = 48000 * 2 * 2 / 50
			quiet := make([]byte, packetBytes)
			soft := make([]byte, packetBytes)
			// Keep a one-unit sample in each channel, at opposite packet edges.
			binary.LittleEndian.PutUint16(soft[:2], 1)
			binary.LittleEndian.PutUint16(soft[len(soft)-2:], 0xffff)
			stereo := make([]byte, packetBytes)
			for i := 0; i < len(stereo); i += 4 {
				binary.LittleEndian.PutUint16(stereo[i:i+2], uint16(i*13))
				binary.LittleEndian.PutUint16(stereo[i+2:i+4], uint16(65535-i*7))
			}
			packets := [][]byte{quiet, quiet, soft, quiet, stereo, quiet, soft, quiet}
			format := struct {
				Format     string `json:"format"`
				SampleRate int    `json:"sample_rate"`
				Channels   int    `json:"channels"`
			}{"s16le", 48000, 2}
			streamEnded := make(chan struct{})
			f := newFixture(t, fixtureHandler(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/audio" {
					http.NotFound(w, r)
					return
				}
				defer close(streamEnded)
				fixtureWebSocket := websocket.Upgrader{
					EnableCompression: true,
					CheckOrigin: func(r *http.Request) bool {
						return r.Header.Get("Origin") == "http://"+r.Host
					},
				}
				ws, err := fixtureWebSocket.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer ws.Close()
				ws.SetReadLimit(1024)
				if err := ws.SetCompressionLevel(flate.BestSpeed); err != nil {
					t.Errorf("set fixture compression: %v", err)
					return
				}
				ws.EnableWriteCompression(false)
				_ = ws.SetWriteDeadline(time.Now().Add(3 * time.Second))
				if err := ws.WriteJSON(format); err != nil {
					return
				}
				for _, packet := range packets {
					// Only exact-zero PCM uses compression, matching audio.go.
					ws.EnableWriteCompression(bytes.Equal(packet, quiet))
					_ = ws.SetWriteDeadline(time.Now().Add(3 * time.Second))
					if err := ws.WriteMessage(websocket.BinaryMessage, packet); err != nil {
						return
					}
				}
				// Remain connected after the last packet: only session shutdown or
				// client input/disconnect should end this output-only fixture.
				_, _, _ = ws.NextReader()
			})))
			// newFixture creates a temporary key with POSIX mode 0600. Windows
			// also needs the production private-file ACL before authentication.
			if err := host.ProtectFile(f.profile.Auth.IdentityFile); err != nil {
				t.Fatalf("protect temporary SSH fixture key: %v", err)
			}
			if err := host.CheckPrivateFile(f.profile.Auth.IdentityFile); err != nil {
				t.Fatalf("temporary SSH fixture key is not private: %v", err)
			}
			s := connectFixture(t, f)
			forwardsBefore := f.forwardCount.Load()
			target, err := url.Parse(s.Origin)
			if err != nil {
				t.Fatal(err)
			}
			proxy := httputil.NewSingleHostReverseProxy(target)
			proxy.Transport = s.Transport
			proxy.FlushInterval = -1
			gateway := httptest.NewServer(proxy)
			defer gateway.Close()
			dialer := websocket.Dialer{EnableCompression: compression, HandshakeTimeout: 3 * time.Second}
			ws, response, err := dialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http")+"/api/audio", http.Header{
				"Origin":        {gateway.URL},
				"Cookie":        {"local=local-secret"},
				"Authorization": {"Bearer local-secret"},
			})
			if err != nil {
				t.Fatal(err)
			}
			defer ws.Close()
			extensions := response.Header.Get("Sec-WebSocket-Extensions")
			if compression {
				if !strings.Contains(extensions, "permessage-deflate") || !strings.Contains(extensions, "server_no_context_takeover") || !strings.Contains(extensions, "client_no_context_takeover") {
					t.Fatalf("compression negotiation lost through SSH/proxy: %q", extensions)
				}
			} else if extensions != "" {
				t.Fatalf("plain client unexpectedly negotiated extensions: %q", extensions)
			}
			_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
			kind, header, err := ws.ReadMessage()
			var receivedFormat struct {
				Format     string `json:"format"`
				SampleRate int    `json:"sample_rate"`
				Channels   int    `json:"channels"`
			}
			if err != nil || kind != websocket.TextMessage || json.Unmarshal(header, &receivedFormat) != nil || receivedFormat != format {
				t.Fatalf("audio header changed: kind=%d header=%q err=%v", kind, header, err)
			}
			for i, want := range packets {
				_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
				kind, got, err := ws.ReadMessage()
				if err != nil || kind != websocket.BinaryMessage || !bytes.Equal(got, want) {
					t.Fatalf("PCM packet %d changed: kind=%d bytes=%d want=%d err=%v", i, kind, len(got), len(want), err)
				}
			}
			if f.forwardCount.Load() <= forwardsBefore {
				t.Fatal("audio did not open an SSH direct-tcpip channel")
			}
			select {
			case <-streamEnded:
				t.Fatal("fixture closed before session shutdown")
			default:
			}
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
			if kind, extra, err := ws.ReadMessage(); err == nil {
				t.Fatalf("extra message after %d PCM packets: kind=%d bytes=%d", len(packets), kind, len(extra))
			} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatalf("WebSocket remained open after session shutdown: %v", err)
			}
			select {
			case <-streamEnded:
			case <-time.After(3 * time.Second):
				t.Fatal("audio fixture leaked after session shutdown")
			}
		})
	}
}
