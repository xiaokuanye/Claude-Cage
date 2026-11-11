package workbench

import (
	"bufio"
	"compress/flate"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const audioCaptureCommand = "exec /usr/bin/parec --server=unix:/run/cage-audio/native --record --raw --format=s16le --rate=48000 --channels=2 --device=cage_output.monitor --latency-msec=20"

var audioFormat = struct {
	Format     string `json:"format"`
	SampleRate int    `json:"sample_rate"`
	Channels   int    `json:"channels"`
}{"s16le", 48000, 2}

type bufferedAudio struct {
	io.Reader
	io.Closer
}

func readAudioReady(reader *bufio.Reader) error {
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return err
	}
	var ready struct {
		Ready      bool   `json:"ready"`
		Format     string `json:"format"`
		SampleRate int    `json:"sample_rate"`
		Channels   int    `json:"channels"`
	}
	if json.Unmarshal(line, &ready) != nil || !ready.Ready || ready.Format != "s16le" || ready.SampleRate != 48000 || ready.Channels != 2 {
		return errors.New("客机声音格式无效")
	}
	return nil
}

// Audio is a local output stream. It does not grant guest Internet access and
// cannot select a microphone, arbitrary guest command, or host audio source.
func (s *Server) audio(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	available := !s.closing && !s.guestUpdateRequired
	s.mu.Unlock()
	if !available || !s.vmRunning() {
		http.Error(w, "请先启动并更新 Cage 环境", http.StatusConflict)
		return
	}
	if !websocket.IsWebSocketUpgrade(r) {
		if s.macosGuest != nil {
			s.macOSAudioStatus(w, r)
			return
		}
		if s.windowsGuest != nil {
			s.windowsAudioStatus(w, r)
			return
		}
		jsonReply(w, audioFormat)
		return
	}
	s.mu.Lock()
	if s.audioClients >= 4 {
		s.mu.Unlock()
		http.Error(w, "声音连接过多，请关闭重复的工作台窗口", http.StatusConflict)
		return
	}
	s.audioClients++
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.audioClients--; s.mu.Unlock() }()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	if s.macosGuest != nil {
		s.macOSAudioCapture(w, r, ctx, cancel)
		return
	}
	if s.windowsGuest != nil {
		s.windowsAudioCapture(w, r, ctx, cancel)
		return
	}
	cmd := s.sshCommand(ctx, "-T", s.sshTarget(), "--", audioCaptureCommand)
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, "声音连接未能建立", http.StatusBadGateway)
		return
	}
	if err = cmd.Start(); err != nil {
		http.Error(w, "声音连接未能建立", http.StatusBadGateway)
		return
	}
	defer func() { cancel(); pipe.Close(); _ = cmd.Wait() }()
	s.streamAudio(w, r.WithContext(ctx), pipe)
}

func (s *Server) streamAudio(w http.ResponseWriter, r *http.Request, source io.ReadCloser) {
	defer source.Close()
	ws, err := s.upgradeWithCompression(w, r, true)
	if err != nil {
		return
	}
	defer ws.Close()
	ws.SetReadLimit(1024)
	if err := ws.SetCompressionLevel(flate.BestSpeed); err != nil {
		return
	}
	ws.EnableWriteCompression(false)
	_ = ws.SetWriteDeadline(time.Now().Add(2 * time.Second))
	if ws.WriteJSON(audioFormat) != nil {
		return
	}
	// Reading is necessary to observe the client disconnect. The client sends
	// no audio or commands; any data message closes this output-only stream.
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer ws.Close()
		_ = sendAudioPCM(ws, source)
	}()
	defer func() { _ = source.Close(); _ = ws.Close(); <-done }()
	// The stream is output-only. Do not read/decompress incoming data: a wire
	// read limit alone does not bound the expanded size of a compressed message.
	_, _, _ = ws.NextReader()
}

func sendAudioPCM(ws *websocket.Conn, source io.Reader) error {
	packet := make([]byte, 48000*2*2/50) // 20 ms, complete stereo frames.
	for {
		n, err := io.ReadFull(source, packet)
		n -= n % 4
		if n > 0 {
			// Preserve every 20 ms packet, including quiet gaps and very soft
			// sounds. Dropping silent packets changes the old player's timeline.
			// Only exact zeroes are compressed, avoiding codec cost for music or
			// noise; clients without the extension still receive identical PCM.
			ws.EnableWriteCompression(audioPCMSilent(packet[:n]))
			_ = ws.SetWriteDeadline(time.Now().Add(2 * time.Second))
			if writeErr := ws.WriteMessage(websocket.BinaryMessage, packet[:n]); writeErr != nil {
				return writeErr
			}
		}
		if err != nil {
			return err
		}
	}
}

func audioPCMSilent(packet []byte) bool {
	for _, b := range packet {
		if b != 0 {
			return false
		}
	}
	return true
}
