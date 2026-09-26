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

package ports

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// GetExtendedTcpTable is not in x/sys. iphlpapi.dll is loaded from the system
// directory only, never from wherever the engine happens to be run.
var procGetExtendedTcpTable = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")

const (
	tcpTableOwnerPIDListener = 3 // TCP_TABLE_OWNER_PID_LISTENER

	// Row sizes: MIB_TCPROW_OWNER_PID is six DWORDs; MIB_TCP6ROW_OWNER_PID is
	// two 16-byte addresses plus six DWORDs. Both tables start with a DWORD
	// count, and neither row needs more than 4-byte alignment, so rows begin
	// at offset 4.
	row4Size = 24
	row6Size = 56
)

func listeners() (Snapshot, error) {
	var snap Snapshot
	seen := make(map[Listener]bool)
	// IPv4 first: when a port is held on both families by different
	// processes (rare, but seen with WSL relays), Holder names the IPv4 one,
	// as lsof's order does on macOS.
	for _, fam := range []struct {
		af            uint32
		rowSize       int
		portAt, pidAt int
	}{
		{windows.AF_INET, row4Size, 8, 20},   // dwState, dwLocalAddr, dwLocalPort … dwOwningPid
		{windows.AF_INET6, row6Size, 20, 52}, // ucLocalAddr[16], dwLocalScopeId, dwLocalPort … dwOwningPid
	} {
		table, err := tcpTable(fam.af)
		if err != nil {
			return nil, err
		}
		if len(table) < 4 {
			continue
		}
		n := int(binary.LittleEndian.Uint32(table))
		for i := 0; i < n; i++ {
			row := table[4+i*fam.rowSize:]
			if len(row) < fam.rowSize {
				break
			}
			// The port is in network byte order in the low 16 bits of its
			// DWORD, so it reads big-endian from the first two bytes.
			l := Listener{
				Port: int(binary.BigEndian.Uint16(row[fam.portAt:])),
				PID:  int(binary.LittleEndian.Uint32(row[fam.pidAt:])),
			}
			// A server bound to both 0.0.0.0 and :: appears twice.
			if !seen[l] {
				seen[l] = true
				snap = append(snap, l)
			}
		}
	}
	return snap, nil
}

// tcpTable returns the raw listener table for one address family. It asks
// for the size first and retries, because sockets open between the calls.
func tcpTable(af uint32) ([]byte, error) {
	size := uint32(16 << 10)
	for attempt := 0; attempt < 8; attempt++ {
		buf := make([]uint32, size/4+1) // uint32 for the table's alignment
		want := size
		r, _, _ := procGetExtendedTcpTable.Call(
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(unsafe.Pointer(&want)),
			0, // unsorted; order is not relied on
			uintptr(af),
			tcpTableOwnerPIDListener,
			0,
		)
		switch syscall.Errno(r) {
		case 0:
			// The row count bounds the parse; on success the size is not
			// reliably rewritten, so hand back the whole buffer.
			return unsafe.Slice((*byte)(unsafe.Pointer(&buf[0])), size), nil
		case windows.ERROR_INSUFFICIENT_BUFFER:
			size = want + 4<<10
		default:
			return nil, fmt.Errorf("GetExtendedTcpTable: %w", syscall.Errno(r))
		}
	}
	return nil, fmt.Errorf("GetExtendedTcpTable: table kept growing")
}
