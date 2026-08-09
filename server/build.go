// Command build is a shell-independent cross-compile builder for SafeServer (Go).
//
// It is the single source of truth for the release target matrix and is invoked
// by server/justfile, server/Makefile and CI so every environment (Windows dev
// box, Linux/macOS CI runner) behaves identically. It drives `go build` through
// os/exec with GOOS/GOARCH/CGO_ENABLED set per process, so it never touches the
// user's global `go env` (unlike `go env -w`).
//
// Usage (run from the server/ directory):
//
//	go run build.go                  # all default targets
//	go run build.go -targets host     # current GOOS/GOARCH only
//	go run build.go -o dist/go        # custom output dir (default dist/go)
//	go run build.go -targets windows/amd64,linux/arm64
//
// Default matrix (requested): linux/windows × amd64/arm64.
// The "host" pseudo-target builds for runtime.GOOS/runtime.GOARCH.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// defaultTargets is the release matrix. Add more GOOS/GOARCH pairs here (e.g.
// darwin/arm64) when CI needs them — every consumer picks it up automatically.
var defaultTargets = []string{
	"windows/amd64",
	"windows/arm64",
	"linux/amd64",
	"linux/arm64",
}

func main() {
	outDir := flag.String("o", "dist/go", "output directory (relative to repo root)")
	pkgDir := flag.String("pkg", "go", "Go module/package directory (relative to repo root)")
	targetsStr := flag.String("targets", "", "comma-separated GOOS/GOARCH list; \"host\" = current platform (default: all)")
	flag.Parse()

	targets := defaultTargets
	if *targetsStr != "" {
		if *targetsStr == "host" {
			targets = []string{runtime.GOOS + "/" + runtime.GOARCH}
		} else {
			targets = strings.Split(*targetsStr, ",")
		}
	}

	// Repo root = directory of this source file (server/).
	_, selfFile, _, ok := runtime.Caller(0)
	if !ok {
		fatal("cannot resolve build.go path")
	}
	root := filepath.Dir(selfFile)
	goDir := filepath.Join(root, *pkgDir)
	if fi, err := os.Stat(goDir); err != nil || !fi.IsDir() {
		fatal("Go package directory not found: %s", goDir)
	}

	outAbs := *outDir
	if !filepath.IsAbs(outAbs) {
		outAbs = filepath.Join(root, *outDir)
	}
	if err := os.MkdirAll(outAbs, 0o755); err != nil {
		fatal("create output dir: %v", err)
	}

	fmt.Printf("SafeServer build -> %s\n", outAbs)
	var failed []string
	for _, t := range targets {
		if err := buildOne(goDir, outAbs, t); err != nil {
			fmt.Fprintf(os.Stderr, "  FAIL %s: %v\n", t, err)
			failed = append(failed, t)
		}
	}

	if len(failed) > 0 {
		fatal("failed targets: %s", strings.Join(failed, ", "))
	}
	fmt.Printf("done: %d binary(es) in %s\n", len(targets), outAbs)
}

func buildOne(goDir, outDir, target string) error {
	parts := strings.SplitN(strings.TrimSpace(target), "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return fmt.Errorf("bad target %q (want GOOS/GOARCH)", target)
	}
	goos, goarch := parts[0], parts[1]

	ext := ""
	if goos == "windows" {
		ext = ".exe"
	}
	outPath := filepath.Join(outDir, fmt.Sprintf("safeserver-%s-%s%s", goos, goarch, ext))

	fmt.Printf("  -> %s/%s\n", goos, goarch)
	cmd := exec.Command("go", "build", "-trimpath", "-o", outPath, ".")
	cmd.Dir = goDir
	cmd.Env = append(os.Environ(),
		"GOOS="+goos,
		"GOARCH="+goarch,
		"CGO_ENABLED=0",
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "build: "+format+"\n", args...)
	os.Exit(1)
}
