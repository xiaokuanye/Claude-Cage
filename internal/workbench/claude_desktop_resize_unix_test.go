//go:build !windows

package workbench

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDesktopResizeScriptAppliesTheViewersDensity(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if runtime.GOOS != "linux" || err != nil {
		t.Skip("the script identifies its settings manager through /proc")
	}
	// go test already executes its test binary from this filesystem. Both
	// TMPDIR and /dev/shm can be mounted noexec independently of the Go build directory.
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(filepath.Dir(executable), "cage-resize-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	desktop, phone, bin := filepath.Join(root, "desktop"), filepath.Join(root, "phone"), filepath.Join(root, "bin")
	for _, directory := range []string{desktop, phone, bin} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, content string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	read := func(path string) string {
		data, _ := os.ReadFile(path)
		return string(data)
	}
	t.Setenv("CAGE_RESIZE_FIXTURE", root)
	write(filepath.Join(bin, "xrandr"), "#!/bin/sh\necho \"$*\" >> \"$CAGE_RESIZE_FIXTURE/modes\"\n", 0o700)
	// The script signals a process named xsettingsd.
	write(filepath.Join(bin, "xsettingsd"), "#!/bin/sh\ntrap 'cp \"$CAGE_RESIZE_FIXTURE/desktop/xsettings.conf\" \"$CAGE_RESIZE_FIXTURE/published\"; echo reload >> \"$CAGE_RESIZE_FIXTURE/reloads\"' HUP\nwhile :; do sleep 1 & wait $!; done\n", 0o700)
	dump := filepath.Join(bin, "dump_xsettings")
	publish := "#!/bin/sh\ncat \"$CAGE_RESIZE_FIXTURE/published\"\n"
	write(dump, publish, 0o700)
	executeResize := func(scale string) ([]byte, error) {
		t.Helper()
		script := strings.NewReplacer("/run/cage-desktop", desktop, "/run/cage-phone-desktop", phone, "/usr/bin/dump_xsettings", dump).Replace(desktopResizeScript(1000, 800, scale))
		cmd := exec.Command(bash, "--noprofile", "--norc", "-c", script)
		cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
		return cmd.CombinedOutput()
	}
	resize := func(scale string) string {
		t.Helper()
		output, err := executeResize(scale)
		if err != nil {
			t.Fatalf("resize %q: %v\n%s", scale, err, output)
		}
		return string(output)
	}
	reloads := func(want int) {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for strings.Count(read(filepath.Join(root, "reloads")), "reload") < want && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		// A reload that should not happen would arrive within this pause.
		time.Sleep(150 * time.Millisecond)
		if got := strings.Count(read(filepath.Join(root, "reloads")), "reload"); got != want {
			t.Fatalf("settings reloads: %d, want %d", got, want)
		}
	}

	// A fixed-density session keeps its density and reports none.
	if output := resize("1.25"); output != "" || read(filepath.Join(desktop, "desktop-size")) != "1000 800 \n" || read(filepath.Join(desktop, "xsettings.conf")) != "" {
		t.Fatalf("fixed density changed: %q", output)
	}
	if !strings.Contains(read(filepath.Join(root, "modes")), "--output VNC-0 --mode cage-1000x800") {
		t.Fatal("size not applied")
	}

	manager := exec.Command(filepath.Join(bin, "xsettingsd"))
	if err := manager.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = manager.Process.Kill(); _, _ = manager.Process.Wait() })
	for attempt := 0; read("/proc/"+strconv.Itoa(manager.Process.Pid)+"/comm") != "xsettingsd\n"; attempt++ {
		if attempt == 100 {
			t.Skip("the stand-in manager is not visible under its name")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The trap is installed shortly after the shell reports its name.
	time.Sleep(200 * time.Millisecond)
	write(filepath.Join(desktop, "xsettings.pid"), strconv.Itoa(manager.Process.Pid)+"\n", 0o600)
	write(filepath.Join(desktop, "base-display-scale"), "2\n", 0o600)
	write(filepath.Join(desktop, "display-scale"), "2\n", 0o600)

	if output := resize("1.25"); output != "scale 1.25\n" {
		t.Fatalf("applied density not reported: %q", output)
	}
	if conf := read(filepath.Join(desktop, "xsettings.conf")); !strings.HasPrefix(conf, "Xft/DPI 122880\n") || !strings.Contains(conf, "Gdk/UnscaledDPI 122880\n") {
		t.Fatalf("settings: %q", conf)
	}
	if read(filepath.Join(desktop, "display-scale")) != "1.25\n" || read(filepath.Join(desktop, "desktop-size")) != "1000 800 1.25\n" {
		t.Fatal("density not recorded")
	}
	reloads(1)
	// An unchanged density leaves the application alone.
	resize("1.25")
	reloads(1)

	// A viewer that names no density gets the configured one back.
	if output := resize(""); output != "" || !strings.HasPrefix(read(filepath.Join(desktop, "xsettings.conf")), "Xft/DPI 196608\n") {
		t.Fatalf("configured density not restored: %q", output)
	}
	reloads(2)

	// While a phone holds the display the request is kept for its release.
	write(filepath.Join(phone, "layout.json"), "{}", 0o600)
	// The deferred path must not wait for or attempt computer DPI publication.
	write(dump, "#!/bin/sh\necho probe >> \"$CAGE_RESIZE_FIXTURE/deferred-probes\"\nexit 1\n", 0o700)
	modes := read(filepath.Join(root, "modes"))
	if output := resize("1"); output != "scale 1\n" || read(filepath.Join(desktop, "desktop-size")) != "1000 800 1\n" {
		t.Fatalf("deferred request: %q", output)
	}
	if read(filepath.Join(desktop, "display-scale")) != "2\n" || read(filepath.Join(root, "modes")) != modes {
		t.Fatal("a held display was changed")
	}
	if read(filepath.Join(root, "deferred-probes")) != "" {
		t.Fatal("a held display was probed instead of deferring the request")
	}
	reloads(2)
	if err := os.Remove(filepath.Join(phone, "layout.json")); err != nil {
		t.Fatal(err)
	}

	// Wrong or blocked publication never acknowledges a DPI merely written to disk.
	for _, tc := range []struct{ probe, restore string }{
		{"#!/bin/sh\nprintf 'Xft/DPI 196608\\nGdk/WindowScalingFactor 1\\nGdk/UnscaledDPI 196608\\n'\n", "2"},
		{"#!/bin/sh\nsleep 10\n", ""},
	} {
		write(dump, tc.probe, 0o700)
		beforeModes := read(filepath.Join(root, "modes"))
		start := time.Now()
		output, err := executeResize("1.5")
		if err == nil || strings.Contains(string(output), "scale 1.5") || !strings.Contains(string(output), "Desktop display settings unavailable") {
			t.Fatalf("unpublished DPI was acknowledged: %v %q", err, output)
		}
		if time.Since(start) > 4*time.Second {
			t.Fatal("publication polling exceeded its bounded timeout")
		}
		if read(filepath.Join(desktop, "display-scale")) != "2\n" || read(filepath.Join(root, "modes")) != beforeModes {
			t.Fatal("failed publication changed the applied density record or framebuffer")
		}
		if !strings.HasPrefix(read(filepath.Join(desktop, "xsettings.conf")), "Xft/DPI 147456\n") {
			t.Fatal("failed request did not leave the pending configuration needed by the recovery fixture")
		}
		// Returning to the last applied scale, explicitly or by default, must
		// overwrite the failed request's configuration and signal its manager.
		write(dump, publish, 0o700)
		want := ""
		if tc.restore != "" {
			want = "scale " + tc.restore + "\n"
		}
		if output := resize(tc.restore); output != want || read(filepath.Join(desktop, "display-scale")) != "2\n" ||
			!strings.HasPrefix(read(filepath.Join(root, "published")), "Xft/DPI 196608\n") ||
			!strings.HasPrefix(read(filepath.Join(desktop, "xsettings.conf")), "Xft/DPI 196608\n") {
			t.Fatalf("last applied density was not restored after publication failure: %q", output)
		}
	}
	// A configured 1.5x session, like 2x, remains the fallback for older viewers.
	write(dump, publish, 0o700)
	write(filepath.Join(desktop, "base-display-scale"), "1.5\n", 0o600)
	if output := resize(""); output != "" || read(filepath.Join(desktop, "display-scale")) != "1.5\n" ||
		!strings.HasPrefix(read(filepath.Join(root, "published")), "Xft/DPI 147456\n") {
		t.Fatalf("configured 1.5x density not restored: %q", output)
	}
}
