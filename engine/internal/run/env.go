// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

package run

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/aosmcleod/runbranch/engine/internal/config"
	"github.com/aosmcleod/runbranch/engine/internal/pathx"
	"github.com/aosmcleod/runbranch/engine/internal/ui"
)

const isWindows = runtime.GOOS == "windows"

// HardenPath fixes PATH before anything is looked up on it.
//
// An app launched from the Dock inherits launchd's PATH — /usr/bin:/bin:
// /usr/sbin:/sbin — not the one your shell builds, and one launched from the
// Start menu can carry a PATH older than the last installer. Under either,
// docker, pnpm, gh and node (fnm's bin directory is minted per shell session)
// are all invisible, and the launcher would report them missing while they
// sit right there.
//
// The apps pass their best guess at the user's PATH; this is the second
// layer, for when the engine is invoked with a bare environment.
func HardenPath() {
	path := os.Getenv("PATH")
	for _, dir := range extraPathDirs() {
		if dir == "" || !pathx.IsDir(dir) {
			continue
		}
		path = appendPath(path, dir)
	}
	os.Setenv("PATH", path)
	if _, err := exec.LookPath("node"); err != nil {
		if _, err := exec.LookPath("fnm"); err == nil {
			for k, v := range fnmEnv("") {
				os.Setenv(k, v)
			}
		}
	}
}

func appendPath(path, dir string) string {
	for _, d := range filepath.SplitList(path) {
		if pathx.Equal(d, dir) {
			return path
		}
	}
	if path == "" {
		return dir
	}
	return path + string(os.PathListSeparator) + dir
}

// RequireCmd dies when a command is not on PATH, saying where it looked.
func RequireCmd(name, fix string) {
	if _, err := exec.LookPath(name); err == nil {
		return
	}
	ui.Die(fmt.Sprintf("`%s` is not on PATH.\n\n%s\nSo %s is either genuinely missing, or installed somewhere unusual.", name, ui.SearchedDirs(), name), fix)
}

// OnPath reports whether a command can be found.
func OnPath(name string) bool {
	if name == "" {
		return false
	}
	_, err := exec.LookPath(name)
	return err == nil
}

// A repo that pins its toolchain expects that pin to be honoured. The
// activation has to happen INSIDE the worktree, because that is where .nvmrc
// / .tool-versions / mise.toml live — activating in the launcher's own
// directory reads the wrong pin, or none.
//
// mise and fnm are asked for the environment they would set, as JSON, and it
// is applied to the child's environment directly. The bash engine evaluated
// a shell snippet instead, which only bash understands. asdf and nvm have
// nothing like it, so on macOS they keep their bash prelude, and on Windows —
// where neither has a per-directory equivalent — they are refused with a
// clear message before anything starts.

// RuntimeUnsupported says why this RUNTIME cannot work here, or "".
func RuntimeUnsupported(rt string) string {
	if isWindows && (rt == "asdf" || rt == "nvm") {
		return fmt.Sprintf("RUNTIME=%s is not available on Windows: %s has no per-directory Windows version. mise and fnm work on both.", rt, rt)
	}
	return ""
}

// runtimeEnv is what a command in dir needs added to its environment.
func runtimeEnv(rt, dir string) map[string]string {
	switch rt {
	case "mise":
		return miseEnv(dir)
	case "fnm":
		env := fnmEnv(dir)
		if len(env) > 0 {
			cmd := exec.Command("fnm", "use", "--install-if-missing")
			cmd.Dir = dir
			cmd.Env = Merge(os.Environ(), env)
			_ = cmd.Run()
		}
		return env
	}
	return nil
}

// Prelude is the bash snippet a runtime still needs on macOS, prepended to
// the command. Errors are swallowed, as they always were: a missing tool
// should surface as the command failing, with its own message.
func Prelude(rt string) string {
	if isWindows {
		return ""
	}
	switch rt {
	case "asdf":
		return `. "$(brew --prefix asdf 2>/dev/null)/libexec/asdf.sh" 2>/dev/null || true; `
	case "nvm":
		return `. "$HOME/.nvm/nvm.sh" 2>/dev/null && nvm use >/dev/null 2>&1 || true; `
	}
	return ""
}

func jsonEnv(dir, name string, args ...string) map[string]string {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return nil
	}
	raw := map[string]any{}
	if err := json.Unmarshal(out.Bytes(), &raw); err != nil {
		return nil
	}
	env := map[string]string{}
	for k, v := range raw {
		if s, ok := v.(string); ok {
			env[k] = s
		}
	}
	return env
}

func miseEnv(dir string) map[string]string { return jsonEnv(dir, "mise", "env", "--json") }

// fnmEnv is `fnm env`, plus the PATH entry it would have added: the JSON form
// names the multishell directory but leaves putting it on PATH to the shell.
func fnmEnv(dir string) map[string]string {
	env := jsonEnv(dir, "fnm", "env", "--json")
	if env == nil {
		return nil
	}
	if ms := env["FNM_MULTISHELL_PATH"]; ms != "" {
		bin := ms
		if !isWindows {
			bin = filepath.Join(ms, "bin")
		}
		env["PATH"] = bin + string(os.PathListSeparator) + os.Getenv("PATH")
	}
	return env
}

// Merge overlays add onto an environment. Windows names are
// case-insensitive, so Path and PATH are one variable there.
func Merge(base []string, add map[string]string) []string {
	norm := func(k string) string {
		if isWindows {
			return strings.ToUpper(k)
		}
		return k
	}
	pending := map[string]string{}
	names := map[string]string{}
	for k, v := range add {
		pending[norm(k)] = v
		names[norm(k)] = k
	}
	out := make([]string, 0, len(base)+len(add))
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if k == "" { // Windows' hidden =C:=C:\ entries
			out = append(out, kv)
			continue
		}
		if v, ok := pending[norm(k)]; ok {
			out = append(out, k+"="+v)
			delete(pending, norm(k))
			continue
		}
		out = append(out, kv)
	}
	for nk, v := range pending {
		out = append(out, names[nk]+"="+v)
	}
	return out
}

// commandEnv is the environment for a command a project runs in dir.
func commandEnv(p *config.Project, dir string, extra map[string]string) []string {
	env := Merge(os.Environ(), runtimeEnv(p.Get("RUNTIME"), dir))
	return Merge(env, extra)
}
