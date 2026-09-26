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

package gitx

// Cksum is the CRC that POSIX `cksum` prints, which is NOT the CRC-32 in
// hash/crc32: the same polynomial, 0x04C11DB7, but fed most significant bit
// first, from zero, with the input's length appended afterwards in as few
// bytes as it takes (least significant first), and complemented at the end.
//
// It matters because it names directories. A worktree whose slug collided was
// given a `-<cksum % 65536>` suffix by the bash engine, and a different digest
// here would orphan it.
func Cksum(data []byte) uint32 {
	var crc uint32
	for _, b := range data {
		crc = (crc << 8) ^ cksumTable[byte(crc>>24)^b]
	}
	for n := uint64(len(data)); n != 0; n >>= 8 {
		crc = (crc << 8) ^ cksumTable[byte(crc>>24)^byte(n)]
	}
	return ^crc
}

var cksumTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 24
		for j := 0; j < 8; j++ {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return
}()
