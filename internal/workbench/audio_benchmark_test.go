package workbench

import (
	"compress/flate"
	"io"
	"testing"
)

// Microbenchmark of the zero scan plus the same reset/flush algorithm used by
// per-message deflate, not an end-to-end CPU/latency or network benchmark.
func BenchmarkAudioSilentPacketEncoding(b *testing.B) {
	packet := make([]byte, 3840)
	writer, err := flate.NewWriter(io.Discard, flate.BestSpeed)
	if err != nil {
		b.Fatal(err)
	}
	defer writer.Close()
	b.SetBytes(int64(len(packet)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if !audioPCMSilent(packet) {
			b.Fatal("silence misclassified")
		}
		writer.Reset(io.Discard)
		if _, err := writer.Write(packet); err != nil {
			b.Fatal(err)
		}
		if err := writer.Flush(); err != nil {
			b.Fatal(err)
		}
	}
}
