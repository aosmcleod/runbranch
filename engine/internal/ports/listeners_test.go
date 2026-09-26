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

//go:build windows || darwin

package ports

import (
	"net"
	"os"
	"testing"
)

// The snapshot sees this process's own sockets, on both families, with the
// right pid and the port the right way round (Windows keeps it in network
// byte order), and a closed port drops out.
func TestListenersSeesOwnSockets(t *testing.T) {
	l4, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p4 := l4.Addr().(*net.TCPAddr).Port
	var p6 int
	if l6, err := net.Listen("tcp6", "[::1]:0"); err == nil {
		defer l6.Close()
		p6 = l6.Addr().(*net.TCPAddr).Port
	} else {
		t.Logf("no IPv6 loopback here: %v", err)
	}

	snap, err := Listeners()
	if err != nil {
		t.Fatal(err)
	}
	if got := snap.Holder(p4); got != os.Getpid() {
		t.Errorf("IPv4 port %d: holder %d, want %d", p4, got, os.Getpid())
	}
	if p6 != 0 {
		if got := snap.Holder(p6); got != os.Getpid() {
			t.Errorf("IPv6 port %d: holder %d, want %d", p6, got, os.Getpid())
		}
	}
	seen := map[Listener]int{}
	for _, l := range snap {
		seen[l]++
		if seen[l] > 1 {
			t.Errorf("duplicate listener %+v", l)
		}
	}

	l4.Close()
	snap, err = Listeners()
	if err != nil {
		t.Fatal(err)
	}
	if got := snap.Holder(p4); got != 0 {
		t.Errorf("closed port %d still held by %d", p4, got)
	}
}
