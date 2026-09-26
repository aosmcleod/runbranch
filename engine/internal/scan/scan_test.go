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

package scan

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProjectName(t *testing.T) {
	for in, want := range map[string]string{
		"/x/My App":    "my-app",
		"/x/runbranch": "runbranch",
		"/x/a.b_c-d":   "a.b_c-d",
		"/x/Café":      "caf--", // byte by byte, as sed did
	} {
		if got := ProjectName(in); got != want {
			t.Errorf("ProjectName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPortGuesses(t *testing.T) {
	for in, want := range map[string]string{
		"vite --port 5174":         "5174",
		"next dev --port=4000":     "4000",
		"rails s -p 3001":          "3001",
		"-p 8080 serve":            "8080",
		"astro dev --host":         "",
		"node server.js -p1":       "",
		"x --port 1 --port 7000 y": "7000",
	} {
		if got := PortFromCommand(in); got != want {
			t.Errorf("PortFromCommand(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{
		"next dev": "3000", "vite": "5173", "astro dev": "4321", "storybook dev": "6006",
		"python manage.py runserver": "8000", "node x.js": "",
	} {
		if got := PortFromFramework(in); got != want {
			t.Errorf("PortFromFramework(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCmdHead(t *testing.T) {
	for in, want := range map[string]string{
		"PORT=1 NODE_ENV=dev node x.js": "node",
		"  pnpm run dev":                "pnpm",
		"A=1":                           "",
	} {
		if got := CmdHead(in); got != want {
			t.Errorf("CmdHead(%q) = %q, want %q", in, got, want)
		}
	}
}

// Only the services: block. A naive grep also matched volumes:, where
// postgres-data sits at the same indent and is not a service.
func TestComposeServices(t *testing.T) {
	f := filepath.Join(t.TempDir(), "docker-compose.yml")
	os.WriteFile(f, []byte("services:\n  postgres:\n    image: x\n  web:\n    image: y\n  redis:\n    image: z\nvolumes:\n  postgres-data:\n"), 0o644)
	if got := composeServices(f); got != "postgres redis" {
		t.Errorf("got %q", got)
	}
}
