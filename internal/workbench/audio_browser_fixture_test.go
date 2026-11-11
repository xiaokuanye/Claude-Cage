package workbench

import (
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Explicitly opt-in: only a temporary loopback server and synthetic PCM. This
// fixture never starts a guest, reads a profile, captures audio or plays sound.
func TestAudioBrowserFixture(t *testing.T) {
	if os.Getenv("CAGE_AUDIO_BROWSER_FIXTURE") != "1" {
		t.Skip("opt-in isolated native WebView2 fixture")
	}
	s := testServer(t)
	queue, err := os.ReadFile(filepath.Join("..", "..", "ui", "src", "audio-worklet.js"))
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/queue.js", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/javascript")
		_, _ = w.Write(queue)
	})
	mux.HandleFunc("/audio", func(w http.ResponseWriter, r *http.Request) {
		reader, writer := io.Pipe()
		defer reader.Close()
		defer writer.Close()
		go func() {
			defer writer.Close()
			for i := 0; i < 80; i++ {
				packet := make([]byte, 3840)
				// Silence, a short click, very quiet sound, and full-range stereo.
				var left, right int16
				switch {
				case i == 15 || i == 23:
					left, right = 900, -900
				case i == 40:
					left, right = 1, -1
				case i >= 50 && i < 65:
					left, right = -32768, 32767
				}
				for at := 0; at < len(packet); at += 4 {
					binary.LittleEndian.PutUint16(packet[at:], uint16(left))
					binary.LittleEndian.PutUint16(packet[at+2:], uint16(right))
				}
				if _, err := writer.Write(packet); err != nil {
					return
				}
				time.Sleep(20 * time.Millisecond)
			}
		}()
		s.streamAudio(w, r, reader)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, audioBrowserFixtureHTML)
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	s.origin = server.URL
	fmt.Printf("AUDIO_FIXTURE_URL=%s/\n", server.URL)
	// Bounded even if the external runner fails. The caller may stop just this
	// test process after collecting its result; no production PID is involved.
	time.Sleep(90 * time.Second)
}

const audioBrowserFixtureHTML = `<!doctype html><meta charset="utf-8"><title>audio-fixture</title>
<script type="module">
import { PCMQueue } from '/queue.js';
const errors = [], queues = [44100, 48000].map(rate => ({rate, actual:new PCMQueue(), expected:new PCMQueue()}));
let packets = 0, header = false;
const ws = new WebSocket(location.origin.replace('http:', 'ws:') + '/audio');
ws.binaryType = 'arraybuffer';
const fail = message => errors.push(message);
const timer = setTimeout(() => { fail('timeout'); ws.close(); finish(); }, 15000);
let done = false;
function finish() {
  if (done) return; done = true; clearTimeout(timer);
  if (!header) fail('missing format');
  if (packets !== 80) fail('packet count ' + packets);
  if (!ws.extensions.includes('permessage-deflate')) fail('native browser did not negotiate compression');
  window.audioFixtureResult = {passed:errors.length === 0, packets, formatVerified:header,
    extensions:ws.extensions, oldPCMQueueRates:[44100,48000], errors,
    scope:'native WebSocket decoding and unchanged PCMQueue, no physical audio output'};
  document.title = 'audio-fixture-done';
}
ws.onmessage = ({data}) => {
  try {
    if (typeof data === 'string') {
      const f = JSON.parse(data);
      header = f.format === 's16le' && f.sample_rate === 48000 && f.channels === 2;
      if (!header) fail('format mismatch');
      return;
    }
    const index = packets++, expected = new ArrayBuffer(3840), view = new DataView(expected);
    let left=0,right=0;
    if (index === 15 || index === 23) { left=900; right=-900; }
    if (index === 40) { left=1; right=-1; }
    if (index >= 50 && index < 65) { left=-32768; right=32767; }
    for (let at=0; at<3840; at+=4) { view.setInt16(at,left,true); view.setInt16(at+2,right,true); }
    const a = new Uint8Array(data), b = new Uint8Array(expected);
    if (a.length !== b.length || !a.every((v,i)=>v===b[i])) fail('PCM mismatch '+index);
    for (const q of queues) {
      q.actual.push(data); q.expected.push(expected);
      const al=new Float32Array(q.rate/50),ar=new Float32Array(q.rate/50);
      const el=new Float32Array(q.rate/50),er=new Float32Array(q.rate/50);
      q.actual.render(al,ar,q.rate); q.expected.render(el,er,q.rate);
      if (!al.every((v,i)=>v===el[i]) || !ar.every((v,i)=>v===er[i])) fail('old queue mismatch '+index+' '+q.rate);
    }
  } catch(e) { fail(String(e)); }
};
ws.onerror = () => { fail('WebSocket error'); };
ws.onclose = finish;
</script>`
