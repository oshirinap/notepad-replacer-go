// main.go - notepad-replacer native shim (fixed CreationFlags, single-file rejoin)
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const dummyMarker = "-3qlsvw92"

type Config struct {
	Exe  string   `json:"exe"`
	Args []string `json:"args"`
}

func userConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".notepad-replacer", "config.json"), nil
}

func readConfig() (*Config, error) {
	p, err := userConfigPath()
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, fmt.Errorf("open config: %w", err)
	}
	defer f.Close()
	var cfg Config
	dec := json.NewDecoder(f)
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.Exe == "" {
		return nil, fmt.Errorf("config.exe missing")
	}
	return &cfg, nil
}

func looksLikeExe(s string) bool {
	ls := strings.ToLower(s)
	return strings.HasSuffix(ls, ".exe")
}

// collectOriginalArgs figures out which trailing raw args (after stripping
// our marker and the re-injected original notepad.exe path) came from
// Windows forwarding the original invocation.
//
// notepad.exe only ever opens a single file at a time. If the file
// association that ultimately triggered this ("open with" command, etc.)
// didn't quote its %1 placeholder, a filename containing spaces arrives
// here already split into multiple separate tokens -- IFEO's Debugger
// mechanism just prepends our shim in front of the original command line
// verbatim, it doesn't fix quoting. There is no way to tell after the fact
// which split is "real" multiple files vs. one filename that lost its
// quotes, so we always rejoin every trailing token into a single argument.
// This matches notepad.exe's own single-file behavior and fixes the
// unquoted-association case for free.
func collectOriginalArgs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	var markerIndex = -1
	for i, v := range raw {
		if v == dummyMarker {
			markerIndex = i
			break
		}
	}

	copySkipExe := func(slice []string) []string {
		if len(slice) == 0 {
			return nil
		}
		if looksLikeExe(slice[0]) && len(slice) > 1 {
			return slice[1:]
		}
		return slice
	}

	var tokens []string

	if markerIndex >= 0 {
		if markerIndex+1 < len(raw) {
			after := copySkipExe(raw[markerIndex+1:])
			if len(after) > 0 {
				tokens = after
			}
		}
		if tokens == nil && markerIndex-1 > 0 {
			before := copySkipExe(raw[:markerIndex-1])
			if len(before) > 0 {
				tokens = before
			}
		}
		if tokens == nil {
			temp := []string{}
			for _, s := range raw {
				if s == dummyMarker {
					continue
				}
				if strings.HasSuffix(strings.ToLower(s), ".cmd") || strings.HasSuffix(strings.ToLower(s), ".vbs") {
					continue
				}
				temp = append(temp, s)
			}
			tokens = copySkipExe(temp)
		}
	} else if looksLikeExe(raw[0]) || strings.HasSuffix(strings.ToLower(raw[0]), ".cmd") || strings.HasSuffix(strings.ToLower(raw[0]), ".vbs") {
		if len(raw) > 1 {
			tokens = raw[1:]
		}
	} else {
		tokens = raw
	}

	if len(tokens) == 0 {
		return nil
	}

	return []string{strings.Join(tokens, " ")}
}

func main() {
	cfg, err := readConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "notepad-replacer shim: config error:", err)
		os.Exit(1)
	}

	rawArgs := os.Args[1:]
	orig := collectOriginalArgs(rawArgs)

	finalArgs := []string{}
	if len(cfg.Args) > 0 {
		finalArgs = append(finalArgs, cfg.Args...)
	}
	if len(orig) > 0 {
		finalArgs = append(finalArgs, orig...)
	}

	cmd := exec.Command(cfg.Exe, finalArgs...)
	// CREATE_NEW_PROCESS_GROUP (0x00000200) insulates the child from our
	// console signals. CREATE_NO_WINDOW (0x08000000) hides any console
	// window without the stronger DETACHED_PROCESS semantics -- some
	// editors' single-instance/"reuse window" IPC handshake on startup
	// doesn't like being fully detached from a console subsystem, and
	// would intermittently fail to connect to an existing instance
	// (launching directly always worked because this didn't apply).
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: 0x00000200 | 0x08000000,
	}
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Stdin = nil

	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "notepad-replacer shim: failed to start editor:", err)
		os.Exit(1)
	}
	// Don't call cmd.Process.Release() here -- on Windows that can race
	// the tail end of CreateProcess bookkeeping if we os.Exit()
	// immediately after, which matched the intermittent "sometimes
	// nothing happens" symptom. Just let main() return normally; the Go
	// runtime exits cleanly and the already-started child process is
	// unaffected either way.
}
