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

package disk

import (
	"io/fs"
	"path/filepath"

	"github.com/aosmcleod/runbranch/engine/internal/pathx"
)

// sizeKB is the sum of file sizes, each rounded up to a 4 KiB cluster, which
// is what NTFS allocates for all but the smallest files. Links are not
// followed. Hardlinks are not de-duplicated: finding a file's identity needs
// a handle per file, which on a node_modules tree costs more than the answer
// is worth, and the figure is a guide to what deleting would free.
func sizeKB(dir string) int64 {
	var bytes int64
	// Through \\?\ so a node_modules past MAX_PATH is counted, not skipped.
	_ = filepath.WalkDir(pathx.Extended(dir), func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		bytes += (fi.Size() + 4095) / 4096 * 4096
		return nil
	})
	return (bytes + 1023) / 1024
}
