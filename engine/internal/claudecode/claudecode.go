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

// Package claudecode installs Runbranch's Claude Code plugin, the status band
// above the prompt (claude-code/ in this repository).
//
// It writes the two keys Claude Code's own `/plugin marketplace add` and
// `/plugin install` write, in the user's settings.json, and nothing else:
// Claude Code fetches the plugin from GitHub on its next start. That works
// whether or not the `claude` command is on PATH, which on Windows, where the
// desktop app carries its own copy, it usually is not.
//
// The file is the user's. Every other key, and the order they are in, is
// kept; a copy is left beside it before the first change.
package claudecode

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	Marketplace = "runbranch"
	Plugin      = "runbranch@runbranch"
	Repo        = "aosmcleod/runbranch"
)

// SettingsFile is Claude Code's user settings: CLAUDE_CONFIG_DIR when set, as
// Claude Code itself reads it, else ~/.claude.
func SettingsFile() string {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, "settings.json")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "settings.json")
}

// Status is one word for the apps to build a menu item from:
//
//	installed  the plugin is enabled and its marketplace declared
//	disabled   declared, but switched off in Claude Code
//	absent     not there at all
//
// A marketplace pointed at a local directory (a checkout being developed)
// counts as declared.
func Status() (string, error) {
	doc, err := load(SettingsFile())
	if err != nil {
		return "", err
	}
	enabled, _ := doc.object("enabledPlugins")
	markets, _ := doc.object("extraKnownMarketplaces")
	raw, listed := enabled.get(Plugin)
	switch {
	case !listed || !markets.has(Marketplace):
		return "absent", nil
	case string(raw) == "true":
		return "installed", nil
	default:
		return "disabled", nil
	}
}

// Install declares the marketplace and enables the plugin. A marketplace the
// user already pointed somewhere else of their own (a local directory) is
// left alone. Returns whether the file changed.
func Install() (bool, error) {
	file := SettingsFile()
	doc, err := load(file)
	if err != nil {
		return false, err
	}
	markets, _ := doc.object("extraKnownMarketplaces")
	if raw, ok := markets.get(Marketplace); !ok || !isDirectorySource(raw) {
		markets.set(Marketplace, json.RawMessage(`{"source":{"source":"github","repo":"`+Repo+`"}}`))
	}
	enabled, _ := doc.object("enabledPlugins")
	enabled.set(Plugin, json.RawMessage(`true`))
	doc.setObject("extraKnownMarketplaces", markets)
	doc.setObject("enabledPlugins", enabled)
	return save(file, doc)
}

// Remove takes back what Install wrote: the plugin's entry, and the
// marketplace when it is the GitHub one. A local directory marketplace is the
// user's and stays.
func Remove() (bool, error) {
	file := SettingsFile()
	doc, err := load(file)
	if err != nil {
		return false, err
	}
	enabled, _ := doc.object("enabledPlugins")
	enabled.del(Plugin)
	markets, _ := doc.object("extraKnownMarketplaces")
	if raw, ok := markets.get(Marketplace); ok && !isDirectorySource(raw) {
		markets.del(Marketplace)
	}
	doc.setObject("enabledPlugins", enabled)
	doc.setObject("extraKnownMarketplaces", markets)
	return save(file, doc)
}

func isDirectorySource(raw json.RawMessage) bool {
	var m struct {
		Source struct {
			Source string `json:"source"`
		} `json:"source"`
	}
	return json.Unmarshal(raw, &m) == nil && m.Source.Source == "directory"
}

// object is a JSON object that remembers its key order, which a Go map does
// not: rewriting someone's settings in alphabetical order is a diff they did
// not ask for.
type object struct {
	keys []string
	vals map[string]json.RawMessage
}

func newObject() *object { return &object{vals: map[string]json.RawMessage{}} }

func parseObject(b []byte) (*object, error) {
	o := newObject()
	dec := json.NewDecoder(bytes.NewReader(b))
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil, errors.New("not a JSON object")
	}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, _ := tok.(string)
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, err
		}
		o.set(key, raw)
	}
	return o, nil
}

func (o *object) get(k string) (json.RawMessage, bool) {
	v, ok := o.vals[k]
	return v, ok
}

func (o *object) has(k string) bool { _, ok := o.vals[k]; return ok }

func (o *object) set(k string, v json.RawMessage) {
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
}

func (o *object) del(k string) {
	if _, ok := o.vals[k]; !ok {
		return
	}
	delete(o.vals, k)
	for i, key := range o.keys {
		if key == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

// object returns the nested object at k, or an empty one when it is absent.
func (o *object) object(k string) (*object, error) {
	raw, ok := o.vals[k]
	if !ok {
		return newObject(), nil
	}
	return parseObject(raw)
}

// setObject stores a nested object, or drops the key when it is empty, so a
// remove leaves no `"enabledPlugins": {}` behind.
func (o *object) setObject(k string, v *object) {
	if len(v.keys) == 0 {
		o.del(k)
		return
	}
	o.set(k, v.encode())
}

func (o *object) encode() json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		name, _ := json.Marshal(k)
		b.Write(name)
		b.WriteByte(':')
		b.Write(o.vals[k])
	}
	b.WriteByte('}')
	return b.Bytes()
}

func load(file string) (*object, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return newObject(), nil
	}
	if err != nil {
		return nil, err
	}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf"))
	if len(bytes.TrimSpace(b)) == 0 {
		return newObject(), nil
	}
	o, err := parseObject(b)
	if err != nil {
		return nil, fmt.Errorf("%s is not valid JSON: %w", file, err)
	}
	return o, nil
}

// save writes the document back, two-space indented as Claude Code writes it,
// through a temporary and a rename. Unchanged content is not rewritten.
func save(file string, doc *object) (bool, error) {
	var out bytes.Buffer
	if err := json.Indent(&out, doc.encode(), "", "  "); err != nil {
		return false, err
	}
	out.WriteByte('\n')
	old, err := os.ReadFile(file)
	if err == nil && bytes.Equal(bytes.TrimPrefix(old, []byte("\xef\xbb\xbf")), out.Bytes()) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return false, err
	}
	if err == nil {
		backup := file + ".runbranch-backup"
		if _, statErr := os.Stat(backup); errors.Is(statErr, os.ErrNotExist) {
			if err := os.WriteFile(backup, old, 0o600); err != nil {
				return false, err
			}
		}
	}
	tmp := file + ".runbranch-tmp"
	if err := os.WriteFile(tmp, out.Bytes(), 0o600); err != nil {
		return false, err
	}
	if err := os.Rename(tmp, file); err != nil {
		os.Remove(tmp)
		return false, err
	}
	return true, nil
}
