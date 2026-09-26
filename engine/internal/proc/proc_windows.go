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

package proc

// Windows processes, and what was found out about them on a Windows 11 x64
// machine before this was written. The findings decide the design, so they
// are recorded here rather than left to be rediscovered:
//
//  1. DETACHED_PROCESS is wrong for a server. cmd.exe then has no console, so
//     every console program it starts (node, python) is given a brand-new
//     console. Its output goes there instead of the inherited log, and Windows
//     11 hosts each new console in a visible Windows Terminal window
//     (WindowsTerminal.exe -Embedding). CREATE_NO_WINDOW is also ignored when
//     combined with DETACHED_PROCESS (documented, and observed). What works is
//     CREATE_NO_WINDOW alone: cmd.exe gets a hidden console of its own, every
//     descendant inherits it, and the log receives everything.
//
//  2. A named Job Object cannot be reopened by a later engine process. The
//     name lives only as long as a handle does. Once the engine that created
//     the job exits, OpenJobObjectW fails with "file not found" even though the
//     server is still inside the job. The engine is short-lived by design (one
//     process per command), so a job would only help the invocation that
//     started the server. Stopping instead walks the process tree from the
//     recorded root, guarded by creation time, and that works from any process.
//
//  3. GenerateConsoleCtrlEvent only reaches processes on the caller's own
//     console. Called from the engine it returns success and does nothing. A
//     helper that frees its console, attaches to the server's hidden console
//     and then sends CTRL_BREAK does work: node and python treat it like
//     SIGTERM and exit cleanly, and cmd.exe exits with them. That is the
//     graceful step. The helper is this same binary re-executed (see init).
//
//  4. CTRL_BREAK sent to a pid that does not lead a process group is not
//     ignored. It is broadcast to every process on that console (observed: it
//     reached the parent too). So a stranger (Terminate) only gets CTRL_BREAK
//     when its PEB says it leads its own group. Otherwise a broadcast could
//     reach the user's shell.
//
//  5. The engine may itself be inside a job (this one was, with no
//     BREAKAWAY_OK). A job with KILL_ON_JOB_CLOSE, such as an editor's or an
//     app's, would take every server down with it. So servers are started
//     with CREATE_BREAKAWAY_FROM_JOB, and started without it when the job
//     refuses (ERROR_ACCESS_DENIED).

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32                  = windows.NewLazySystemDLL("kernel32.dll")
	procAttachConsole         = kernel32.NewProc("AttachConsole")
	procFreeConsole           = kernel32.NewProc("FreeConsole")
	procSetConsoleCtrlHandler = kernel32.NewProc("SetConsoleCtrlHandler")
	procGetConsoleProcessList = kernel32.NewProc("GetConsoleProcessList")

	user32                       = windows.NewLazySystemDLL("user32.dll")
	procEnumWindows              = user32.NewProc("EnumWindows")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	procIsWindowVisible          = user32.NewProc("IsWindowVisible")
)

const (
	serverFlags = windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_NO_WINDOW

	stillActive = 259 // STILL_ACTIVE, GetExitCodeProcess's "has not exited"

	// FILETIME counts 100ns ticks since 1601; unix seconds start in 1970.
	ticksPerSecond    = 10_000_000
	epochDeltaSeconds = 11_644_473_600

	pollEvery = 200 * time.Millisecond

	// helperEnv makes this binary act as the console helper instead of
	// itself. It has to be a separate process: AttachConsole needs a caller
	// with no console, and the engine keeps its own console for its output.
	helperEnv = "RUNBRANCH_PROC_CONSOLE_HELPER"
)

// init turns a re-executed engine into the console helper before main (or a
// test binary's TestMain) sees anything. Every binary that imports proc
// therefore carries its own helper, and there is no second executable to
// ship or find.
func init() {
	if v := os.Getenv(helperEnv); v != "" {
		os.Exit(consoleHelper(v))
	}
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

func comspec() string {
	// The system directory, not a PATH lookup: a cmd.exe sitting in a
	// project's directory must never be the one that runs its servers.
	dir, err := windows.GetSystemDirectory()
	if err != nil {
		dir = `C:\Windows\System32`
	}
	return filepath.Join(dir, "cmd.exe")
}

// cmdLine is the command line cmd.exe receives. It goes through
// SysProcAttr.CmdLine because Go's usual argv escaping (backslash-quote) is
// the C runtime's convention, not cmd's: `echo "a&b" && x` would arrive with
// its quotes escaped and cmd would split on the &. With /s, cmd strips exactly
// the outer pair of quotes and runs what is between them as typed.
func cmdLine(command string) string {
	return `cmd.exe /d /s /c "` + command + `"`
}

func shell(command string) (string, []string) {
	// The arguments as cmd.exe sees them. A caller that hands these to
	// exec.Command gets Go's escaping; start and run build the line with
	// cmdLine instead.
	return comspec(), []string{"/d", "/s", "/c", command}
}

func start(spec Spec) (Handle, error) {
	log, err := os.OpenFile(spec.LogPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return Handle{}, err
	}
	defer log.Close() // the child has its own inherited copy
	null, err := os.Open(os.DevNull)
	if err != nil {
		return Handle{}, err
	}
	defer null.Close()

	launch := func(flags uint32) (*exec.Cmd, error) {
		c := exec.Command(comspec())
		c.SysProcAttr = &syscall.SysProcAttr{CmdLine: cmdLine(spec.Command), CreationFlags: flags}
		c.Dir, c.Env = spec.Dir, spec.Env
		// Go passes only these three handles to the child (it uses an explicit
		// handle list), so a server never holds the app's pipe to the engine
		// open. The app reads the engine's output until EOF; a leaked handle
		// would hang it for as long as the server ran.
		c.Stdin, c.Stdout, c.Stderr = null, log, log
		return c, c.Start()
	}
	c, err := launch(serverFlags | windows.CREATE_BREAKAWAY_FROM_JOB)
	if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		// The job the engine runs in does not allow breakaway. The server
		// then lives as long as that job's owner lets it, which is the best
		// available.
		c, err = launch(serverFlags)
	}
	if err != nil {
		return Handle{}, err
	}
	h := Handle{PID: c.Process.Pid}
	// Read while os.Process still holds its handle, so the process object
	// exists even if the server has already exited.
	if t, err := startTime(h.PID); err == nil {
		h.Started = t
	}
	// No Wait: the server must outlive the engine. Windows has no zombies, so
	// releasing the handle costs nothing.
	c.Process.Release()
	return h, nil
}

func run(command, dir string, env []string, out io.Writer) error {
	c := exec.Command(comspec())
	c.SysProcAttr = &syscall.SysProcAttr{CmdLine: cmdLine(command)}
	if !hasConsole() {
		// Without a console to inherit, npm and friends would each get a
		// new, visible one (see finding 1). With one, share it, so that
		// Ctrl+C in the user's terminal reaches the install as it would
		// under bash.
		c.SysProcAttr.CreationFlags = windows.CREATE_NO_WINDOW
	}
	c.Dir, c.Env = dir, env
	c.Stdout, c.Stderr = out, out // stdin stays nil, which is NUL: never prompt
	return c.Run()
}

func hasConsole() bool {
	var pid uint32
	n, _, _ := procGetConsoleProcessList.Call(uintptr(unsafe.Pointer(&pid)), 1)
	return n != 0
}

// ---------------------------------------------------------------------------
// Liveness and identity
// ---------------------------------------------------------------------------

func fileTimeToUnix(ticks int64) int64 { return ticks/ticksPerSecond - epochDeltaSeconds }
func unixToFileTime(sec int64) int64   { return (sec + epochDeltaSeconds) * ticksPerSecond }

// sameSecond compares creation times recorded at second granularity, with the
// ±1s tolerance that rounding on either side needs.
func sameSecond(a, b int64) bool { d := a - b; return d >= -1 && d <= 1 }

// open returns a handle, or (0, true) when the process exists but will not
// be opened (ACCESS_DENIED: an elevated or protected process), or (0, false)
// when there is no such process.
func open(pid int, access uint32) (windows.Handle, bool) {
	if pid <= 0 {
		return 0, false
	}
	h, err := windows.OpenProcess(access, false, uint32(pid))
	if err != nil {
		return 0, errors.Is(err, windows.ERROR_ACCESS_DENIED)
	}
	return h, true
}

func running(h windows.Handle) bool {
	var code uint32
	return windows.GetExitCodeProcess(h, &code) == nil && code == stillActive
}

func creationTicks(h windows.Handle) (int64, error) {
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(h, &created, &exited, &kernel, &user); err != nil {
		return 0, err
	}
	return int64(created.HighDateTime)<<32 | int64(created.LowDateTime), nil
}

func alive(h Handle) bool {
	ph, exists := open(h.PID, windows.PROCESS_QUERY_LIMITED_INFORMATION)
	if ph == 0 {
		return exists
	}
	defer windows.CloseHandle(ph)
	if !running(ph) {
		return false
	}
	if h.Started != 0 {
		t, err := creationTicks(ph)
		if err == nil && !sameSecond(fileTimeToUnix(t), h.Started) {
			return false // the pid now belongs to someone else
		}
	}
	return true
}

func exists(pid int) bool {
	ph, exists := open(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION)
	if ph == 0 {
		return exists
	}
	defer windows.CloseHandle(ph)
	// A process object outlives the process while anyone holds a handle to
	// it, so an open that succeeds is not proof on its own.
	return running(ph)
}

func startTime(pid int) (int64, error) {
	ph, _ := open(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION)
	if ph == 0 {
		return 0, fmt.Errorf("pid %d: cannot open process", pid)
	}
	defer windows.CloseHandle(ph)
	t, err := creationTicks(ph)
	if err != nil {
		return 0, err
	}
	return fileTimeToUnix(t), nil
}

// ---------------------------------------------------------------------------
// The process tree
// ---------------------------------------------------------------------------

type pentry struct {
	pid, ppid int
	created   int64 // FILETIME ticks
	name      string
}

// processes is every process on the machine with its parent and creation
// time, from one NtQuerySystemInformation call. It is the same walk
// Toolhelp32 offers, but it carries creation times, so the guard below needs
// no OpenProcess per candidate and is not defeated by processes we may not
// open.
func processes() (map[int]pentry, error) {
	size := uint32(1 << 20)
	for attempt := 0; attempt < 8; attempt++ {
		buf := make([]uint64, size/8) // uint64 for the alignment the struct needs
		var ret uint32
		err := windows.NtQuerySystemInformation(windows.SystemProcessInformation, unsafe.Pointer(&buf[0]), size, &ret)
		if errors.Is(err, windows.STATUS_INFO_LENGTH_MISMATCH) {
			size = ret + 256<<10 // processes appear between the two calls
			continue
		}
		if err != nil {
			return nil, err
		}
		out := make(map[int]pentry, 512)
		base := unsafe.Pointer(&buf[0])
		for off := uintptr(0); ; {
			p := (*windows.SYSTEM_PROCESS_INFORMATION)(unsafe.Add(base, off))
			out[int(p.UniqueProcessID)] = pentry{
				pid:     int(p.UniqueProcessID),
				ppid:    int(p.InheritedFromUniqueProcessID),
				created: p.CreateTime,
				name:    p.ImageName.String(),
			}
			if p.NextEntryOffset == 0 {
				break
			}
			off += uintptr(p.NextEntryOffset)
		}
		return out, nil
	}
	return nil, errors.New("process list kept growing")
}

// ident is one process, pinned by its creation time so a reused pid is not
// taken for it.
type ident struct {
	pid     int
	created int64 // FILETIME ticks
}

// descendants returns every live process that descends from one of roots,
// and each root that is itself still alive, parents before children.
//
// Windows never reparents: a child keeps its dead parent's pid as its parent
// id, and that pid can be reused. The walk would then adopt an unrelated
// process's children. Two checks prevent it:
//   - a child is older than its parent's recorded creation time → it belongs
//     to an earlier holder of that pid;
//   - the pid is live now under a different creation time, and the child is
//     younger than that newcomer → it belongs to the newcomer.
//
// A child that predates the newcomer was started by the process we know, and
// stays ours.
func descendants(roots []ident, snap map[int]pentry) []ident {
	children := make(map[int][]pentry)
	for _, p := range snap {
		if p.pid != p.ppid {
			children[p.ppid] = append(children[p.ppid], p)
		}
	}
	self := os.Getpid()
	seen := make(map[ident]bool)
	var out []ident
	queue := append([]ident(nil), roots...)
	for _, r := range roots {
		if cur, ok := snap[r.pid]; ok && cur.created == r.created && !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	for len(queue) > 0 {
		n := queue[0]
		queue = queue[1:]
		cur, reused := snap[n.pid]
		reused = reused && cur.created != n.created
		for _, c := range children[n.pid] {
			if c.pid == self || c.created < n.created {
				continue
			}
			if reused && c.created >= cur.created {
				continue
			}
			id := ident{c.pid, c.created}
			if !seen[id] {
				seen[id] = true
				out = append(out, id)
				queue = append(queue, id)
			}
		}
	}
	return out
}

// rootOf pins a handle to an ident. With a recorded start time the anchor is
// that second. With none it is the live process, or, when the pid is gone,
// zero (any orphan of that pid). That weaker case exists only for state
// written before start times were recorded.
func rootOf(h Handle, snap map[int]pentry) ident {
	cur, ok := snap[h.PID]
	switch {
	case h.Started == 0 && ok:
		return ident{h.PID, cur.created}
	case h.Started == 0:
		return ident{h.PID, 0}
	case ok && sameSecond(fileTimeToUnix(cur.created), h.Started):
		return ident{h.PID, cur.created}
	default:
		// Dead, or reused. Its children, if any survive, are still ours.
		// Started is truncated, so the true creation time is no earlier than
		// this and the child-is-older check stays sound.
		return ident{h.PID, unixToFileTime(h.Started)}
	}
}

// tree follows a server's processes across the rounds of a stop. Every
// process ever seen stays an anchor, because a watcher killed before its
// freshly respawned child would otherwise take the only link to that child
// with it.
type tree struct {
	anchors map[ident]bool
}

func (t *tree) add(ids ...ident) {
	for _, id := range ids {
		t.anchors[id] = true
	}
}

func (t *tree) live() ([]ident, error) {
	snap, err := processes()
	if err != nil {
		return nil, err
	}
	roots := make([]ident, 0, len(t.anchors))
	for id := range t.anchors {
		roots = append(roots, id)
	}
	found := descendants(roots, snap)
	t.add(found...)
	return found, nil
}

func newTree(h Handle) (*tree, error) {
	snap, err := processes()
	if err != nil {
		return nil, err
	}
	t := &tree{anchors: map[ident]bool{}}
	t.add(rootOf(h, snap))
	return t, nil
}

// ---------------------------------------------------------------------------
// Stopping
// ---------------------------------------------------------------------------

func stopTree(h Handle, grace time.Duration) error {
	if h.PID <= 0 {
		return nil
	}
	t, err := newTree(h)
	if err != nil {
		return err
	}
	live, err := t.live()
	if err != nil {
		return err
	}
	if len(live) == 0 {
		return nil
	}

	// Graceful: CTRL_BREAK to everything on the server's console. Attach
	// through the root when it is alive, otherwise through any survivor;
	// they share the console. The group is the root's pid; if the root has
	// gone that group has no leader and the break is broadcast to the whole
	// console (finding 4), which here holds only this server's processes.
	// The helper also lists what is attached to that console, which catches
	// processes whose parent died before this walk could link them.
	delivered := false
	for _, id := range live {
		pids, err := consoleCtrl(id.pid, h.PID, true)
		if err != nil {
			continue
		}
		delivered = true
		if snap, err := processes(); err == nil {
			for _, pid := range pids {
				if p, ok := snap[pid]; ok && pid != os.Getpid() {
					t.add(ident{pid, p.created})
				}
			}
		}
		break
	}
	// Waiting only makes sense when something was asked to stop.
	if delivered {
		for deadline := time.Now().Add(grace); time.Now().Before(deadline); {
			time.Sleep(pollEvery)
			if live, err = t.live(); err == nil && len(live) == 0 {
				return nil
			}
		}
	}

	// Forced: terminate everything, parents first so a watcher is gone
	// before it can respawn, and walk again until nothing is left. A child a
	// watcher managed to respawn in between is caught on the next round.
	for round := 0; round < 25; round++ {
		if live, err = t.live(); err != nil {
			return err
		}
		if len(live) == 0 {
			return nil
		}
		var waits []windows.Handle
		for _, id := range live {
			if ph := terminateIdent(id); ph != 0 {
				waits = append(waits, ph)
			}
		}
		for _, ph := range waits {
			windows.WaitForSingleObject(ph, 500)
			windows.CloseHandle(ph)
		}
	}
	if live, err = t.live(); err == nil && len(live) == 0 {
		return nil
	}
	pids := make([]string, len(live))
	for i, id := range live {
		pids[i] = strconv.Itoa(id.pid)
	}
	return fmt.Errorf("still running after stop: pid %s", strings.Join(pids, ", "))
}

// terminateIdent force-kills one process, having checked that the pid still
// names the same process the walk found. It returns the handle to wait on.
func terminateIdent(id ident) windows.Handle {
	ph, _ := open(id.pid, windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE)
	if ph == 0 {
		return 0
	}
	if t, err := creationTicks(ph); err != nil || t != id.created {
		windows.CloseHandle(ph)
		return 0
	}
	windows.TerminateProcess(ph, 1)
	return ph
}

func terminate(pid int, grace time.Duration) error {
	if !exists(pid) {
		return nil
	}
	created, _ := startTime(pid)
	// A stranger gets CTRL_BREAK only when it leads its own group, so the
	// break reaches it and its children and nobody else (finding 4). Anything
	// else gets taskkill without /F: WM_CLOSE to its windows, which is a real
	// request to a GUI program.
	//
	// To a console program with no window — which is what a dev server
	// started in a terminal is — WM_CLOSE is a no-op, and Windows has no other
	// way to ask a process that shares its console with others. Breaking that
	// console would reach the terminal and everything else in it. So such a
	// process is ended on its own, that pid and no other: the nearest thing
	// to SIGTERM, whose default for node and python is to exit at once. It
	// used to be left running, and kill-port then reported a failure for a
	// port the user had just been told it would free.
	//
	// A program with a window is never forced. It may be asking to save.
	if gid, err := groupID(pid); err == nil && gid == pid {
		consoleCtrl(pid, pid, true)
	} else {
		c := exec.Command("taskkill", "/PID", strconv.Itoa(pid))
		c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
		c.Run()
		if !waitGone(pid, created, min(grace, 2*time.Second)) && !hasVisibleWindow(pid) {
			endOne(pid, created)
		}
	}
	for deadline := time.Now().Add(grace); ; {
		if !alive(Handle{PID: pid, Started: created}) {
			return nil
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("pid %d did not stop within %s", pid, grace)
		}
		time.Sleep(pollEvery)
	}
}

// waitGone polls until pid has exited or wait has passed, and says which.
func waitGone(pid int, created int64, wait time.Duration) bool {
	for deadline := time.Now().Add(wait); ; {
		if !alive(Handle{PID: pid, Started: created}) {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(pollEvery)
	}
}

// endOne terminates exactly pid, provided it is still the process that was
// looked at: a pid reused in the meantime belongs to somebody else.
func endOne(pid int, created int64) {
	ph, err := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(ph)
	if now, err := startTime(pid); err != nil || (created != 0 && now != created) {
		return
	}
	windows.TerminateProcess(ph, 1)
}

// hasVisibleWindow reports whether pid owns a visible top-level window.
func hasVisibleWindow(pid int) bool {
	found := false
	cb := windows.NewCallback(func(hwnd uintptr, _ uintptr) uintptr {
		var owner uint32
		procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&owner)))
		if int(owner) == pid {
			if vis, _, _ := procIsWindowVisible.Call(hwnd); vis != 0 {
				found = true
				return 0
			}
		}
		return 1
	})
	procEnumWindows.Call(cb, 0)
	return found
}

// consoleCtrl runs the helper against the console that pid is attached to.
// It returns the pids attached to that console, the helper excluded, and
// sends CTRL_BREAK to group when asked.
func consoleCtrl(pid, group int, sendBreak bool) ([]int, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	b := 0
	if sendBreak {
		b = 1
	}
	c := exec.Command(exe)
	c.Env = append(os.Environ(), fmt.Sprintf("%s=%d %d %d", helperEnv, pid, group, b))
	// A hidden console of its own, freed at once. With no console at all,
	// the helper would be fine, but anything it started would not be.
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	var out strings.Builder
	c.Stdout = &out
	if err := c.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err = <-done:
	case <-time.After(10 * time.Second):
		c.Process.Kill()
		<-done
		return nil, errors.New("console helper hung")
	}
	if err != nil {
		return nil, fmt.Errorf("console helper: %v: %s", err, strings.TrimSpace(out.String()))
	}
	var pids []int
	for _, f := range strings.Fields(out.String()) {
		if n, err := strconv.Atoi(f); err == nil && n != c.Process.Pid {
			pids = append(pids, n)
		}
	}
	return pids, nil
}

// consoleHelper is the helper process's whole life: "<pid> <group> <break>".
func consoleHelper(arg string) int {
	var pid, group, brk int
	if n, _ := fmt.Sscanf(arg, "%d %d %d", &pid, &group, &brk); n != 3 || pid <= 0 {
		fmt.Println("bad helper argument")
		return 2
	}
	procFreeConsole.Call()
	if r, _, err := procAttachConsole.Call(uintptr(pid)); r == 0 {
		fmt.Println("attach:", err)
		return 1
	}
	// Survive the break we are about to send: a leaderless group broadcasts
	// to the whole console, this helper included. A NULL handler would
	// ignore only CTRL_C, so install one that swallows everything.
	procSetConsoleCtrlHandler.Call(windows.NewCallback(func(uint32) uintptr { return 1 }), 1)
	list := make([]uint32, 1024)
	n, _, _ := procGetConsoleProcessList.Call(uintptr(unsafe.Pointer(&list[0])), uintptr(len(list)))
	if int(n) > len(list) {
		n = uintptr(len(list))
	}
	for _, p := range list[:n] {
		fmt.Println(p)
	}
	if brk == 1 {
		if err := windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(group)); err != nil {
			fmt.Println("break:", err)
			return 1
		}
		// Delivery is asynchronous (conhost injects a thread into each
		// target). Leaving the console at once has not lost an event in
		// testing, but a short pause costs nothing.
		time.Sleep(100 * time.Millisecond)
	}
	return 0
}

// ---------------------------------------------------------------------------
// What a process is
// ---------------------------------------------------------------------------

func cmdline(pid int) (string, error) {
	ph, _ := open(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION)
	if ph == 0 {
		return "", fmt.Errorf("pid %d: cannot open process", pid)
	}
	defer windows.CloseHandle(ph)
	size := uint32(4096)
	for attempt := 0; attempt < 4; attempt++ {
		buf := make([]uint64, (size+7)/8)
		var ret uint32
		err := windows.NtQueryInformationProcess(ph, windows.ProcessCommandLineInformation, unsafe.Pointer(&buf[0]), size, &ret)
		if errors.Is(err, windows.STATUS_INFO_LENGTH_MISMATCH) || errors.Is(err, windows.STATUS_BUFFER_TOO_SMALL) || errors.Is(err, windows.STATUS_BUFFER_OVERFLOW) {
			size = ret + 64
			continue
		}
		if err != nil {
			return "", err
		}
		// A UNICODE_STRING header whose buffer points just past itself.
		return (*windows.NTUnicodeString)(unsafe.Pointer(&buf[0])).String(), nil
	}
	return "", fmt.Errorf("pid %d: command line kept growing", pid)
}

// withParams opens pid for reading and finds its RTL_USER_PROCESS_PARAMETERS
// in its own address space. x/sys's structs carry native 64-bit offsets, so
// this reads only 64-bit processes from a 64-bit engine. A 32-bit (WOW64)
// target keeps a second, 32-bit PEB; it is refused rather than guessed at.
func withParams(pid int, fn func(ph windows.Handle, params uintptr) error) error {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		return errors.New("reading another process needs a 64-bit engine")
	}
	ph, _ := open(pid, windows.PROCESS_QUERY_INFORMATION|windows.PROCESS_VM_READ)
	if ph == 0 {
		ph, _ = open(pid, windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_VM_READ)
	}
	if ph == 0 {
		return fmt.Errorf("pid %d: cannot open process for reading", pid)
	}
	defer windows.CloseHandle(ph)
	var wow bool
	if err := windows.IsWow64Process(ph, &wow); err != nil {
		return err
	}
	if wow {
		return fmt.Errorf("pid %d is a 32-bit process", pid)
	}
	var pbi windows.PROCESS_BASIC_INFORMATION
	if err := windows.NtQueryInformationProcess(ph, windows.ProcessBasicInformation, unsafe.Pointer(&pbi), uint32(unsafe.Sizeof(pbi)), nil); err != nil {
		return err
	}
	// PebBaseAddress is an address in the other process, never dereferenced
	// here: every read goes through ReadProcessMemory.
	peb := uintptr(unsafe.Pointer(pbi.PebBaseAddress))
	params, err := readPointer(ph, peb+unsafe.Offsetof(windows.PEB{}.ProcessParameters))
	if err != nil {
		return err
	}
	if params == 0 {
		return fmt.Errorf("pid %d has no process parameters yet", pid)
	}
	return fn(ph, params)
}

func readMemory(ph windows.Handle, addr uintptr, buf []byte) error {
	var n uintptr
	if err := windows.ReadProcessMemory(ph, addr, &buf[0], uintptr(len(buf)), &n); err != nil {
		return err
	}
	if n != uintptr(len(buf)) {
		return errors.New("short read")
	}
	return nil
}

func readPointer(ph windows.Handle, addr uintptr) (uintptr, error) {
	var b [8]byte
	if err := readMemory(ph, addr, b[:]); err != nil {
		return 0, err
	}
	return uintptr(*(*uint64)(unsafe.Pointer(&b[0]))), nil
}

func cwd(pid int) (string, error) {
	var dir string
	err := withParams(pid, func(ph windows.Handle, params uintptr) error {
		at := params + unsafe.Offsetof(windows.RTL_USER_PROCESS_PARAMETERS{}.CurrentDirectory) +
			unsafe.Offsetof(windows.CURDIR{}.DosPath)
		var us [16]byte // UNICODE_STRING: Length, MaximumLength, pad, Buffer
		if err := readMemory(ph, at, us[:]); err != nil {
			return err
		}
		length := int(*(*uint16)(unsafe.Pointer(&us[0])))
		text := uintptr(*(*uint64)(unsafe.Pointer(&us[8])))
		if length == 0 || text == 0 || length%2 != 0 || length > 0x10000 {
			return fmt.Errorf("pid %d: no working directory recorded", pid)
		}
		chars := make([]uint16, length/2)
		raw := unsafe.Slice((*byte)(unsafe.Pointer(&chars[0])), length)
		if err := readMemory(ph, text, raw); err != nil {
			return err
		}
		dir = windows.UTF16ToString(chars)
		return nil
	})
	if err != nil {
		return "", err
	}
	// Windows keeps a trailing separator on the working directory; C:\ keeps
	// it, because C: alone means "the current directory on C".
	if len(dir) > 3 {
		dir = strings.TrimRight(dir, `\`)
	}
	return dir, nil
}

// groupID reads the process group a process was placed in, from its PEB.
func groupID(pid int) (int, error) {
	var gid uint32
	err := withParams(pid, func(ph windows.Handle, params uintptr) error {
		var b [4]byte
		if err := readMemory(ph, params+unsafe.Offsetof(windows.RTL_USER_PROCESS_PARAMETERS{}.ProcessGroupId), b[:]); err != nil {
			return err
		}
		gid = *(*uint32)(unsafe.Pointer(&b[0]))
		return nil
	})
	return int(gid), err
}

// ---------------------------------------------------------------------------
// Browser
// ---------------------------------------------------------------------------

func openURL(url string) error {
	// ShellExecute hands the URL to the registered handler as one string.
	// `cmd /c start` would parse it first and cut it at the first &.
	verb, err := windows.UTF16PtrFromString("open")
	if err != nil {
		return err
	}
	target, err := windows.UTF16PtrFromString(url)
	if err != nil {
		return err
	}
	return windows.ShellExecute(0, verb, target, nil, nil, windows.SW_SHOWNORMAL)
}
