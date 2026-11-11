package workbench

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

const audioTestPacketBytes = 48000 * 2 * 2 / 50

// Count reads at the TCP connection, below the WebSocket decoder. Counting
// decoded ReadMessage payloads would conceal the bandwidth regression entirely.
type audioCountingConn struct {
	net.Conn
	readBytes *atomic.Int64
}

func (c *audioCountingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.readBytes.Add(int64(n))
	return n, err
}

type audioClosingReader struct {
	*io.PipeReader
	once   sync.Once
	closed chan struct{}
}

func (r *audioClosingReader) Close() error {
	err := r.PipeReader.Close()
	r.once.Do(func() { close(r.closed) })
	return err
}

type audioCompressionStream struct {
	ws        *websocket.Conn
	writer    *io.PipeWriter
	readBytes atomic.Int64
	baseline  int64
	finished  chan struct{}
	closed    chan struct{}
	cancel    context.CancelFunc
}

func newAudioCompressionStream(t *testing.T, compression bool) *audioCompressionStream {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	reader, writer := io.Pipe()
	source := &audioClosingReader{PipeReader: reader, closed: make(chan struct{})}
	stream := &audioCompressionStream{
		writer: writer, finished: make(chan struct{}), closed: source.closed, cancel: cancel,
	}
	s := &Server{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(stream.finished)
		s.streamAudio(w, r.WithContext(ctx), source)
	}))
	s.origin = server.URL
	t.Cleanup(func() {
		cancel()
		_ = writer.Close()
		_ = source.Close()
		if stream.ws != nil {
			_ = stream.ws.Close()
		}
		server.Close()
		select {
		case <-stream.finished:
		case <-time.After(3 * time.Second):
			t.Error("audio compression handler did not exit during cleanup")
		}
	})
	dialer := websocket.Dialer{
		EnableCompression: compression,
		HandshakeTimeout:  3 * time.Second,
		NetDialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return &audioCountingConn{Conn: conn, readBytes: &stream.readBytes}, nil
		},
	}
	ws, response, err := dialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/api/audio", http.Header{"Origin": {server.URL}})
	if err != nil {
		t.Fatal("dial audio stream:", err)
	}
	stream.ws = ws
	extensions := response.Header.Get("Sec-WebSocket-Extensions")
	if negotiated := strings.Contains(extensions, "permessage-deflate"); negotiated != compression {
		t.Fatalf("compression negotiated=%v, requested=%v, extensions=%q", negotiated, compression, extensions)
	}
	if !compression && extensions != "" {
		t.Fatalf("legacy client received unsolicited extension %q", extensions)
	}
	_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	kind, format, err := ws.ReadMessage()
	wantFormat := []byte("{\"format\":\"s16le\",\"sample_rate\":48000,\"channels\":2}\n")
	if err != nil || kind != websocket.TextMessage || !bytes.Equal(format, wantFormat) {
		t.Fatalf("audio format changed: kind=%d data=%q err=%v", kind, format, err)
	}
	// The pipe has supplied no PCM yet. ReadMessage fully consumes the JSON
	// message, so neither handshake nor metadata can leak into subsequent byte
	// counts, even when the dialer's buffered reader prefetched that message.
	stream.baseline = stream.readBytes.Load()
	return stream
}

func (s *audioCompressionStream) writePCM(t *testing.T, data []byte) {
	t.Helper()
	result := make(chan error, 1)
	go func() {
		_, err := s.writer.Write(data)
		result <- err
	}()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal("supply PCM:", err)
		}
	case <-time.After(3 * time.Second):
		_ = s.writer.Close()
		t.Fatal("audio stream stopped consuming PCM")
	}
}

func (s *audioCompressionStream) readPCM(t *testing.T, want []byte) {
	t.Helper()
	_ = s.ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	kind, got, err := s.ws.ReadMessage()
	if err != nil {
		t.Fatal("read PCM:", err)
	}
	if kind != websocket.BinaryMessage || !bytes.Equal(got, want) {
		t.Fatalf("PCM changed: kind=%d received=%d bytes expected=%d bytes equal=%v", kind, len(got), len(want), bytes.Equal(got, want))
	}
}

func (s *audioCompressionStream) expectClosed(t *testing.T) {
	t.Helper()
	_ = s.ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	if kind, data, err := s.ws.ReadMessage(); err == nil {
		t.Fatalf("unexpected extra message: kind=%d bytes=%d", kind, len(data))
	} else if networkError, ok := err.(net.Error); ok && networkError.Timeout() {
		t.Fatal("audio stream did not close before the read deadline")
	}
	select {
	case <-s.finished:
	case <-time.After(3 * time.Second):
		t.Fatal("audio handler leaked")
	}
	select {
	case <-s.closed:
	default:
		t.Fatal("audio handler did not close its source")
	}
}

func TestAudioCompressionRoundTripAndPacketOrder(t *testing.T) {
	quiet := bytes.Repeat([]byte{1, 0, 255, 255}, audioTestPacketBytes/4) // +1/-1 s16le.
	impulse := make([]byte, audioTestPacketBytes)
	copy(impulse[1536:], []byte{0x40, 0x1f, 0xc0, 0xe0}) // One stereo frame, +8000/-8000.
	noise := make([]byte, audioTestPacketBytes)
	_, _ = rand.New(rand.NewSource(20261111)).Read(noise)
	zero := make([]byte, audioTestPacketBytes)
	packets := []struct {
		name   string
		data   []byte
		silent bool
	}{
		{"initial silence", zero, true},
		{"very soft sound", quiet, false},
		{"short quiet gap", zero, true},
		{"one-frame sound", impulse, false},
		{"second quiet gap", zero, true},
		{"deterministic noise", noise, false},
		{"third quiet gap", zero, true},
		{"very soft sound after silence", quiet, false},
		{"final full silent packet", zero, true},
	}
	for _, compression := range []bool{false, true} {
		t.Run(fmt.Sprintf("compression=%v", compression), func(t *testing.T) {
			stream := newAudioCompressionStream(t, compression)
			for index, packet := range packets {
				before := stream.readBytes.Load()
				// Complete this read before supplying the next packet, so TCP
				// read-ahead cannot attribute a later packet to this one.
				stream.writePCM(t, packet.data)
				stream.readPCM(t, packet.data)
				wireBytes := stream.readBytes.Load() - before
				if !compression || !packet.silent {
					if want := int64(len(packet.data) + 4); wireBytes != want {
						t.Fatalf("packet %d (%s): uncompressed wire bytes=%d, want=%d", index, packet.name, wireBytes, want)
					}
				} else if wireBytes*20 > int64(len(packet.data)) {
					t.Fatalf("packet %d (%s): compressed silence uses %d wire bytes", index, packet.name, wireBytes)
				}
			}
			// EOF preserves the last three complete stereo frames and discards
			// only the incomplete fourth frame, exactly as the old PCM path did.
			tail := noise[:15]
			stream.writePCM(t, tail)
			_ = stream.writer.Close()
			stream.readPCM(t, tail[:12])
			stream.expectClosed(t)
		})
	}
}

func TestAudioCompressionPartialSilentFrames(t *testing.T) {
	for _, compression := range []bool{false, true} {
		for _, bytesAtEOF := range []int{0, 1, 3, 4, 15, audioTestPacketBytes - 1} {
			t.Run(fmt.Sprintf("compression=%v/bytes=%d", compression, bytesAtEOF), func(t *testing.T) {
				stream := newAudioCompressionStream(t, compression)
				if bytesAtEOF != 0 {
					stream.writePCM(t, make([]byte, bytesAtEOF))
				}
				_ = stream.writer.Close()
				if completeBytes := bytesAtEOF - bytesAtEOF%4; completeBytes > 0 {
					stream.readPCM(t, make([]byte, completeBytes))
				}
				stream.expectClosed(t)
			})
		}
	}
}

func TestAudioCompressionSilenceWireBudget(t *testing.T) {
	// These are 1 s and 10 s of 48 kHz stereo PCM, not wall-clock load tests.
	// Capture supplies the pacing in production; here each 20 ms packet must
	// still arrive separately, including every zero packet.
	for _, seconds := range []int{1, 10} {
		t.Run(fmt.Sprintf("%ds", seconds), func(t *testing.T) {
			packetCount := seconds * 50
			zero := make([]byte, audioTestPacketBytes)
			var wireBytes [2]int64
			for index, compression := range []bool{false, true} {
				stream := newAudioCompressionStream(t, compression)
				for packet := 0; packet < packetCount; packet++ {
					stream.writePCM(t, zero)
					stream.readPCM(t, zero)
				}
				wireBytes[index] = stream.readBytes.Load() - stream.baseline
				_ = stream.writer.Close()
				stream.expectClosed(t)
			}
			rawBytes := int64(packetCount * audioTestPacketBytes)
			if want := int64(packetCount * (audioTestPacketBytes + 4)); wireBytes[0] != want {
				t.Fatalf("legacy PCM framing changed: wire=%d expected=%d", wireBytes[0], want)
			}
			if wireBytes[1] <= 0 || wireBytes[1]*20 > rawBytes || wireBytes[1]*20 > wireBytes[0] {
				t.Fatalf("silence exceeds 5%% wire budget: raw_pcm=%d legacy_wire=%d compressed_wire=%d", rawBytes, wireBytes[0], wireBytes[1])
			}
			t.Logf("packets=%d raw_pcm_bytes=%d legacy_ws_bytes=%d compressed_ws_bytes=%d ratio=%.4f%% (HTTP handshake and JSON metadata excluded; WebSocket headers included)", packetCount, rawBytes, wireBytes[0], wireBytes[1], 100*float64(wireBytes[1])/float64(wireBytes[0]))
		})
	}
}

func TestAudioCompressionClosesOnCancellationAndSourceEOF(t *testing.T) {
	for _, action := range []string{"cancel", "source EOF", "client disconnect"} {
		t.Run(action, func(t *testing.T) {
			stream := newAudioCompressionStream(t, true)
			switch action {
			case "cancel":
				stream.cancel()
			case "source EOF":
				_ = stream.writer.Close()
			case "client disconnect":
				_ = stream.ws.Close()
			}
			stream.expectClosed(t)
		})
	}
}

func TestAudioCompressionRejectsInboundDataWithoutReadingPayload(t *testing.T) {
	for _, opcode := range []byte{websocket.TextMessage, websocket.BinaryMessage} {
		t.Run(fmt.Sprintf("opcode=%d", opcode), func(t *testing.T) {
			stream := newAudioCompressionStream(t, true)
			// Valid negotiated compressed data-frame header, masked as required
			// for a client, advertising 256 bytes (below the 1024-byte read limit).
			// Deliberately withhold the body: the output-only endpoint must close
			// on the header, without waiting for or expanding compressed data.
			header := []byte{0xc0 | opcode, 0xfe, 0x01, 0x00, 0x12, 0x34, 0x56, 0x78}
			_ = stream.ws.UnderlyingConn().SetWriteDeadline(time.Now().Add(3 * time.Second))
			if _, err := stream.ws.UnderlyingConn().Write(header); err != nil {
				t.Fatal("write compressed data header:", err)
			}
			stream.expectClosed(t)
		})
	}
}

func TestWebSocketUpgradeDoesNotNegotiateAudioCompression(t *testing.T) {
	s := &Server{}
	payload := bytes.Repeat([]byte{0}, audioTestPacketBytes)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := s.upgrade(w, r)
		if err != nil {
			return
		}
		defer ws.Close()
		_ = ws.WriteMessage(websocket.BinaryMessage, payload)
	}))
	defer server.Close()
	s.origin = server.URL
	dialer := websocket.Dialer{EnableCompression: true, HandshakeTimeout: 3 * time.Second}
	ws, response, err := dialer.Dial("ws"+strings.TrimPrefix(server.URL, "http")+"/ordinary-websocket", http.Header{"Origin": {server.URL}})
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	if extensions := response.Header.Get("Sec-WebSocket-Extensions"); extensions != "" {
		t.Fatalf("non-audio upgrade unexpectedly enabled compression: %q", extensions)
	}
	_ = ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	if kind, data, err := ws.ReadMessage(); err != nil || kind != websocket.BinaryMessage || !bytes.Equal(data, payload) {
		t.Fatalf("non-audio payload changed: kind=%d bytes=%d err=%v", kind, len(data), err)
	}
}
