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

// The only place that talks to the engine — runbranch.exe, the Go engine the
// Mac app shares. Every subcommand the app uses is a function here, and
// nothing else shells out. A port of app/Engine.swift.
//
// Everything on Engine blocks until the engine exits. Call it off the UI
// thread (Task.Run), as the Mac calls it off the main actor; Runner and
// HealthMonitor are the two things here that are made for the UI thread.

using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Runbranch;

/// <summary>
/// Runs the engine.
///
/// The Mac has to rebuild the login shell's environment, because an app
/// launched from the Dock inherits launchd's, which has none of the user's
/// PATH. A Windows app launched from Explorer inherits the user's real
/// environment, so there is nothing to resolve here: the engine runs with
/// this process's own variables, RB_* overrides included.
/// </summary>
public static class Engine
{
    /// <summary>
    /// The engine, which ships in bin\ beside Runbranch.exe.
    ///
    /// RB_ENGINE first, for pointing a built app at a working copy without
    /// rebuilding, as on the Mac; then bin\runbranch.exe, where make-app.ps1
    /// puts it. Resolved relative to the exe, never the working directory: a
    /// copy launched from anywhere else must still find its own.
    ///
    /// Not in the same folder as the app, which is what the spec first said:
    /// Windows file names are case-insensitive, so runbranch.exe and
    /// Runbranch.exe are one file. The first build found "the engine" there
    /// and it was this app — every engine call launched another Runbranch,
    /// which single-instance redirection quietly folded back into this one.
    /// bin\ keeps the engine's own name, so that folder can go on PATH and
    /// `runbranch doctor` works in a terminal, as the docs say.
    /// </summary>
    public static string EnginePath
    {
        get
        {
            var over = Environment.GetEnvironmentVariable("RB_ENGINE");
            if (!string.IsNullOrEmpty(over) && File.Exists(over) && !IsThisApp(over)) return over;
            // Nothing to run is reported by the first call that tries, naming
            // this path, rather than failing later with something confusing.
            return Path.Combine(AppContext.BaseDirectory, "bin", "runbranch.exe");
        }
    }

    static bool IsThisApp(string path) =>
        Environment.ProcessPath is { } self &&
        string.Equals(Path.GetFullPath(path), Path.GetFullPath(self), StringComparison.OrdinalIgnoreCase);

    public readonly record struct Result(string Out, string Err, int Code)
    {
        public bool Started => Code != -1;
    }

    /// <summary>
    /// Runs a subcommand to completion. Code is -1 when the engine could not
    /// be started at all.
    ///
    /// stderr is always drained, even by callers that ignore it. The Mac
    /// handed it a pipe nobody read, which holds until the engine writes more
    /// than a pipe buffer to stderr and then blocks it forever.
    /// </summary>
    public static Result Execute(IReadOnlyList<string> args)
    {
        ChildProcess child;
        try { child = ChildProcess.Start(EnginePath, args, mergeStderr: false); }
        catch (Exception e) when (e is Win32Exception or IOException) { return new Result("", "", -1); }
        using (child)
        {
            var outTask = Task.Run(() => ReadAll(child.Output));
            var errTask = Task.Run(() => ReadAll(child.Error!));
            child.WaitForExit();
            child.DrainOrAbandon(outTask, errTask);
            return new Result(Decode(outTask), Decode(errTask), child.ExitCode);
        }
    }

    static byte[] ReadAll(Stream s)
    {
        using var ms = new MemoryStream();
        try { s.CopyTo(ms); } catch (Exception e) when (e is IOException or ObjectDisposedException) { }
        return ms.ToArray();
    }

    static string Decode(Task<byte[]> t) =>
        t.IsCompletedSuccessfully ? new UTF8Encoding(false, false).GetString(t.Result) : "";

    /// <summary>Blocking. Used for the short reads (branch list, state).</summary>
    public static (string Out, int Code) Capture(params string[] args)
    {
        var r = Execute(args);
        return (r.Out, r.Code);
    }

    /// <summary>
    /// Runs a subcommand and returns what it complained about, or null if it
    /// worked.
    ///
    /// The engine names the command that fixes every failure it reports, which
    /// is worth nothing if the caller throws it away. Anything that is not a
    /// streamed run goes through here.
    /// </summary>
    public static string? Failure(params string[] args)
    {
        var r = Execute(args);
        if (!r.Started) return $"Could not run {EnginePath}.";
        if (r.Code == 0) return null;
        return Wire.TidyFailure(r.Err, args.FirstOrDefault());
    }

    public static List<Project> Projects() => Project.ParseAll(Capture("projects").Out);

    public static List<Branch> Branches(string project) => Branch.ParseAll(Capture("branches", project).Out);

    public static List<string> Presets(string project) => Wire.ParseLines(Capture("presets", project).Out);

    /// <summary>
    /// Where the engine keeps things for a project: worktrees, logs, config,
    /// repo, GitHub slug, and optionally one branch's worktree.
    /// </summary>
    public static ProjectPaths Paths(string project, string? @ref = null) =>
        ProjectPaths.Parse((@ref is null ? Capture("paths", project) : Capture("paths", project, @ref)).Out);

    static readonly Lazy<string> projectsDir = new(() =>
    {
        var output = Capture("projects-dir").Out.Trim();
        return output.Length > 0
            ? output
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".runbranch", "projects");
    });

    /// <summary>
    /// Where `.conf` files live, according to the engine.
    ///
    /// On the Mac this was once `dirname(scriptPath) + "/projects"`, which
    /// inside the app is a directory INSIDE the bundle — and an update replaces
    /// the bundle, so every project added through the app was destroyed by the
    /// next one. The same holds for a folder an update swaps out here. The
    /// engine owns the layout; asking it is the only way this cannot drift.
    ///
    /// Resolved once, on first use. Read it off the UI thread the first time.
    /// </summary>
    public static string ProjectsDir => projectsDir.Value;

    public static RunState State(string project) => RunState.Parse(Capture("state", project).Out);

    /// <summary>Reclaims ports and clears state a crash left. Once at launch, before anything else.</summary>
    public static string Reclaim() => Capture("reclaim").Out;

    /// <summary>Every worktree on disk across every project, and what it costs. Slow: seconds.</summary>
    public static List<DiskRow> Disk() => DiskRow.Parse(Capture("disk").Out);

    /// <summary>Every declared port, and what is on it.</summary>
    public static List<PortRow> Ports() => PortRow.Parse(Capture("ports").Out);

    /// <summary>
    /// Ports more than one project declares. `doctor` says the same thing in
    /// prose, which the app cannot act on.
    /// </summary>
    public static List<PortOverlap> Overlaps() => PortOverlap.Parse(Capture("overlaps").Out);

    /// <summary>
    /// The smallest `PORT_OFFSET` that puts all of a project's ports somewhere
    /// free. null when the engine could not find one, rather than 0 — which
    /// means "nothing needs moving" and is a different answer.
    /// </summary>
    public static int? SuggestedOffset(string project)
    {
        var (output, code) = Capture("suggest-offset", project);
        return Wire.ParseOffset(output, code);
    }

    /// <summary>
    /// What holds the ports a preset needs, asked BEFORE starting so the user
    /// gets a choice rather than a failure. null means go straight to `run`:
    /// that covers no conflict and also an engine that died without printing
    /// clashes, which `run` will then report properly.
    /// </summary>
    public static PortConflict? CheckPorts(string project, string preset)
    {
        var (output, code) = Capture("check-ports", project, preset);
        return code != 0 ? PortConflict.Parse(output) : null;
    }

    /// <summary>Ends a port holder, if it belongs to a project. What went wrong, or null.</summary>
    public static string? KillPort(int pid) => Failure("kill-port", pid.ToString(System.Globalization.CultureInfo.InvariantCulture));

    /// <summary>Stops a run without streaming it (resolving a port conflict). What went wrong, or null.</summary>
    public static string? Stop(string project) => Failure("stop", project);

    /// <summary>Removes worktrees whose ref no longer exists. What went wrong, or null.</summary>
    public static string? PruneGone(string project) => Failure("prune-gone", project);

    /// <summary>Re-reads pull request state from GitHub. Output ignored; it exits 0 either way.</summary>
    public static void Refresh(string project) => Capture("refresh", project);

    /// <summary>Git repos under a directory that are not already declared.</summary>
    public static List<ScanResult> Scan(string directory) => ScanResult.Parse(Capture("scan", directory).Out);

    public static string? Favourite(string project, bool on) => Failure("favourite", project, on ? "on" : "off");

    /// <summary>Reads a repo, writes a proposed config, returns (name, file). null if it would not.</summary>
    public static AddedProject? Add(string repoPath)
    {
        var (output, code) = Capture("add", repoPath);
        return code == 0 ? AddedProject.Parse(output) : null;
    }

    /// <summary>
    /// Every editable field of a project. TARGETS arrives with U+0001
    /// separating its lines, since it is the one multi-line value.
    /// </summary>
    public static Dictionary<string, string> Get(string project) => Wire.ParseGet(Capture("get", project).Out);

    /// <summary>
    /// Writes one key. Returns null on success, or what went wrong — stderr as
    /// the engine wrote it. The editor shows its first line, which the
    /// contract keeps for the message.
    /// </summary>
    public static string? Set(string project, string key, string value)
    {
        var r = Execute(["set", project, key, Wire.EncodeValue(value)]);
        if (!r.Started) return "could not run the engine";
        if (r.Code == 0) return null;
        return r.Err.Length == 0 ? $"writing {key} failed" : r.Err;
    }

    // --- streamed commands -------------------------------------------------
    // The argument lists for Runner, so the positional rules live here with
    // everything else that knows the engine's command line.

    public static string[] RunArgs(string project, string @ref, string preset, int? offset = null, bool inPlace = false)
    {
        var args = new List<string> { "run", project, @ref, preset };
        if (offset is { } o) args.Add(o.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (inPlace) args.Add("--in-place");
        return [.. args];
    }

    public static string[] StopArgs(string project) => ["stop", project];
    public static string[] UpdateArgs(string project) => ["update", project];
    public static string[] RemoveWorktreeArgs(string project, string @ref) => ["remove-worktree", project, @ref];
    public static string[] RemoveArgs(string project) => ["remove", project];

    static readonly ConcurrentDictionary<string, bool> commandCache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Whether a command resolves on PATH, the way cmd.exe would find it:
    /// each PATH directory, each PATHEXT extension. A direct lookup, since
    /// spawning `where` to answer it would cost more than every other check
    /// put together. Cached for the life of the process.
    /// </summary>
    public static bool HasCommand(string name) => commandCache.GetOrAdd(name, n => Which(n) is not null);

    /// <summary>The full path a command resolves to, or null.</summary>
    public static string? Which(string name)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        var exts = (Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD")
            .Split(';', StringSplitOptions.RemoveEmptyEntries);
        var hasExt = Path.HasExtension(name);
        foreach (var raw in path.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var dir = raw.Trim().Trim('"');
            if (dir.Length == 0) continue;
            try
            {
                if (hasExt && File.Exists(Path.Combine(dir, name))) return Path.Combine(dir, name);
                foreach (var ext in exts)
                {
                    var candidate = Path.Combine(dir, name + ext);
                    if (File.Exists(candidate)) return candidate;
                }
            }
            catch (ArgumentException) { /* a PATH entry with characters no path can hold */ }
        }
        return null;
    }
}

/// <summary>
/// A child process with its standard handles on pipes, started with no
/// window of any kind.
///
/// Not System.Diagnostics.Process, for two reasons. It cannot put stdout and
/// stderr on ONE pipe, which is what a streamed run needs to keep the
/// engine's lines and its FAILED block in the order they were written. And it
/// lets every inheritable handle in this process leak into the child, so a
/// capture started while a run is streaming could hold the run's pipe open
/// after the run exits. CreateProcess with an explicit handle list gives the
/// child its three handles and nothing else.
///
/// CREATE_NO_WINDOW on every start: the engine is a console program, and
/// without it each call would flash a console window — including the ones
/// the 30 s refresh makes, forever.
/// </summary>
sealed class ChildProcess : IDisposable
{
    readonly SafeProcessHandle process;
    readonly AnonymousPipeServerStream stdout;
    readonly AnonymousPipeServerStream? stderr;

    public int Pid { get; }
    public Stream Output => stdout;
    public Stream? Error => stderr;

    ChildProcess(SafeProcessHandle process, int pid, AnonymousPipeServerStream stdout, AnonymousPipeServerStream? stderr)
    {
        this.process = process;
        Pid = pid;
        this.stdout = stdout;
        this.stderr = stderr;
    }

    public static ChildProcess Start(string exe, IReadOnlyList<string> args, bool mergeStderr, string? workingDirectory = null)
    {
        var outPipe = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        var errPipe = mergeStderr ? null : new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
        // stdin is a pipe whose write end is closed straight after the start,
        // so the child reads end-of-file. Nothing here ever wants input, and
        // an inherited stdin is how a child ends up waiting on a terminal that
        // is not there.
        var inPipe = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        try
        {
            var hIn = inPipe.ClientSafePipeHandle.DangerousGetHandle();
            var hOut = outPipe.ClientSafePipeHandle.DangerousGetHandle();
            var hErr = errPipe?.ClientSafePipeHandle.DangerousGetHandle() ?? hOut;

            var handles = hErr == hOut ? new[] { hIn, hOut } : new[] { hIn, hOut, hErr };
            var (process, pid) = Native.Create(exe, CommandLine(exe, args), workingDirectory, hIn, hOut, hErr, handles);

            inPipe.DisposeLocalCopyOfClientHandle();
            outPipe.DisposeLocalCopyOfClientHandle();
            errPipe?.DisposeLocalCopyOfClientHandle();
            inPipe.Dispose();
            return new ChildProcess(process, pid, outPipe, errPipe);
        }
        catch
        {
            inPipe.Dispose();
            outPipe.Dispose();
            errPipe?.Dispose();
            throw;
        }
    }

    public void WaitForExit() => Native.WaitForSingleObject(process, Native.Infinite);

    public bool WaitForExit(TimeSpan timeout) =>
        Native.WaitForSingleObject(process, (uint)Math.Clamp(timeout.TotalMilliseconds, 0, uint.MaxValue - 1)) == 0;

    public int ExitCode => Native.GetExitCodeProcess(process, out var code) ? unchecked((int)code) : -1;

    /// <summary>
    /// Ends the engine, and only the engine — the Mac's terminate() is a
    /// SIGTERM to its pid alone. Servers a run already started are detached
    /// and survive; the state file is written only once they have all started,
    /// so a cancel mid-start can leave one with no state, which `reclaim` at
    /// the next launch catches.
    /// </summary>
    public void Kill() => Native.TerminateProcess(process, 1);

    /// <summary>
    /// After exit, give the readers a moment to reach end-of-file, then stop
    /// waiting. A grandchild that kept the pipe (an install step's daemon,
    /// say) would otherwise hold the call open for as long as it lives, when
    /// the engine is long gone. Done means the engine exited, not that every
    /// process it touched let go of its output.
    /// </summary>
    public void DrainOrAbandon(params Task[] readers)
    {
        if (Task.WaitAll(readers, TimeSpan.FromSeconds(2))) return;
        // A blocked synchronous read holds a reference on its handle, so
        // disposing alone would wait for the very read it is meant to end.
        // Cancel it first.
        Native.CancelIoEx(stdout.SafePipeHandle, IntPtr.Zero);
        if (stderr is not null) Native.CancelIoEx(stderr.SafePipeHandle, IntPtr.Zero);
        stdout.Dispose();
        stderr?.Dispose();
        try { Task.WaitAll(readers, TimeSpan.FromSeconds(1)); } catch (AggregateException) { }
    }

    public void Dispose()
    {
        stdout.Dispose();
        stderr?.Dispose();
        process.Dispose();
    }

    /// <summary>
    /// The quoting CommandLineToArgvW and Go's os.Args both undo: an argument
    /// with spaces, tabs or quotes is wrapped in quotes, backslashes are
    /// doubled only where they precede a quote, and an empty argument is "".
    /// </summary>
    public static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0) return arg;
        var sb = new StringBuilder("\"");
        for (var i = 0; i < arg.Length; i++)
        {
            var slashes = 0;
            while (i < arg.Length && arg[i] == '\\') { slashes++; i++; }
            if (i == arg.Length) { sb.Append('\\', slashes * 2); break; }
            if (arg[i] == '"') sb.Append('\\', slashes * 2 + 1).Append('"');
            else sb.Append('\\', slashes).Append(arg[i]);
        }
        return sb.Append('"').ToString();
    }

    public static string CommandLine(string exe, IEnumerable<string> args) =>
        string.Join(' ', new[] { Quote(exe) }.Concat(args.Select(Quote)));

    static class Native
    {
        public const uint Infinite = 0xFFFFFFFF;
        const uint CreateNoWindow = 0x08000000;
        const uint ExtendedStartupInfoPresent = 0x00080000;
        const uint CreateUnicodeEnvironment = 0x00000400;
        const int StartfUseStdHandles = 0x00000100;
        static readonly IntPtr ProcThreadAttributeHandleList = 0x00020002;

        [StructLayout(LayoutKind.Sequential)]
        struct StartupInfo
        {
            public int cb;
            public IntPtr lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInformation
        {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
        static extern bool CreateProcess(string? lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
            string? lpCurrentDirectory, ref StartupInfoEx lpStartupInfo, out ProcessInformation lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue,
            IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll")]
        static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(SafeProcessHandle handle, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CancelIoEx(SafePipeHandle handle, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(SafeProcessHandle handle, uint exitCode);

        public static (SafeProcessHandle, int) Create(string exe, string commandLine, string? cwd,
            IntPtr stdin, IntPtr stdout, IntPtr stderr, IntPtr[] inherit)
        {
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            var list = Marshal.AllocHGlobal(size);
            var handles = Marshal.AllocHGlobal(IntPtr.Size * inherit.Length);
            var initialised = false;
            try
            {
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Win32Exception();
                initialised = true;
                Marshal.Copy(inherit, 0, handles, inherit.Length);
                if (!UpdateProcThreadAttribute(list, 0, ProcThreadAttributeHandleList, handles,
                        IntPtr.Size * inherit.Length, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception();

                var si = new StartupInfoEx
                {
                    StartupInfo = new StartupInfo
                    {
                        cb = Marshal.SizeOf<StartupInfoEx>(),
                        dwFlags = StartfUseStdHandles,
                        hStdInput = stdin,
                        hStdOutput = stdout,
                        hStdError = stderr,
                    },
                    lpAttributeList = list,
                };
                var cmd = new StringBuilder(commandLine);
                if (!CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, true,
                        CreateNoWindow | ExtendedStartupInfoPresent | CreateUnicodeEnvironment,
                        IntPtr.Zero, cwd, ref si, out var pi))
                    throw new Win32Exception();
                CloseHandle(pi.hThread);
                return (new SafeProcessHandle(pi.hProcess, ownsHandle: true), pi.dwProcessId);
            }
            finally
            {
                if (initialised) DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(handles);
                Marshal.FreeHGlobal(list);
            }
        }
    }
}

/// <summary>
/// Streams a run into the Run dialog, one line at a time.
///
/// Create it on the UI thread: lines, Finished and Failed are only ever
/// changed there, so an ItemsRepeater or ListView can bind Lines directly.
/// stdout and stderr share one pipe, so the engine's FAILED block lands after
/// the lines that led up to it, as it does in a terminal.
/// </summary>
public sealed class Runner : INotifyPropertyChanged
{
    readonly DispatcherQueue queue;
    ChildProcess? child;
    int generation;
    bool finished;
    bool failed;

    public Runner()
    {
        queue = DispatcherQueue.GetForCurrentThread()
                ?? throw new InvalidOperationException("Runner must be created on the UI thread.");
    }

    public ObservableCollection<string> Lines { get; } = [];

    public bool Finished
    {
        get => finished;
        private set => SetField(ref finished, value);
    }

    /// <summary>The engine exited non-zero. Success or failure comes only from the exit status.</summary>
    public bool Failed
    {
        get => failed;
        private set => SetField(ref failed, value);
    }

    public bool IsRunning => child is not null && !finished;

    /// <summary>Raised on the UI thread once Finished and Failed are final.</summary>
    public event EventHandler? Completed;

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Start(IReadOnlyList<string> args)
    {
        var mine = ++generation;
        Lines.Clear();
        Finished = false;
        Failed = false;

        ChildProcess started;
        try
        {
            started = ChildProcess.Start(Engine.EnginePath, args, mergeStderr: true);
        }
        catch (Exception e) when (e is Win32Exception or IOException)
        {
            child = null;
            Lines.Add($"Could not start {Engine.EnginePath}");
            Failed = true;
            Finished = true;
            OnPropertyChanged(nameof(IsRunning));
            Completed?.Invoke(this, EventArgs.Empty);
            return;
        }
        child = started;
        OnPropertyChanged(nameof(IsRunning));

        var reader = Task.Run(() =>
        {
            var assembler = new LineAssembler();
            var buffer = new byte[8192];
            try
            {
                int n;
                while ((n = started.Output.Read(buffer, 0, buffer.Length)) > 0)
                    Post(mine, assembler.Feed(buffer.AsSpan(0, n)));
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException) { }
            Post(mine, assembler.Finish());
        });

        Task.Run(() =>
        {
            started.WaitForExit();
            started.DrainOrAbandon(reader);
            var code = started.ExitCode;
            started.Dispose();
            queue.TryEnqueue(() =>
            {
                if (mine != generation) return;
                Failed = code != 0;
                Finished = true;
                OnPropertyChanged(nameof(IsRunning));
                Completed?.Invoke(this, EventArgs.Empty);
            });
        });
    }

    void Post(int mine, List<string> lines)
    {
        if (lines.Count == 0) return;
        queue.TryEnqueue(() =>
        {
            if (mine != generation) return;
            foreach (var l in lines) Lines.Add(l);
        });
    }

    /// <summary>Ends the engine. See ChildProcess.Kill for what that leaves running.</summary>
    public void Cancel()
    {
        try { child?.Kill(); } catch (ObjectDisposedException) { }
    }

    void SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(name);
    }

    void OnPropertyChanged(string? name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>
/// Polls each target's health URL. Health is a fact to be checked, not
/// something to assume because a process is still alive — a server can be up
/// and answering 500s.
///
/// Every 5 s, 3 s per request (ui-map §4.5). Create it on the UI thread;
/// Status only changes there.
/// </summary>
public sealed class HealthMonitor : INotifyPropertyChanged
{
    static readonly HttpClient http = new(new SocketsHttpHandler
    {
        // The targets are on localhost. A system proxy has no business seeing
        // them, and one that does not bypass loopback would report every
        // server as down.
        UseProxy = false,
        AllowAutoRedirect = false,
        PooledConnectionLifetime = TimeSpan.FromMinutes(1),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    readonly DispatcherQueue queue;
    readonly DispatcherQueueTimer timer;
    readonly Dictionary<string, Health> status = new(StringComparer.Ordinal);
    IReadOnlyList<RunTarget> targets = [];
    int generation;

    public HealthMonitor()
    {
        queue = DispatcherQueue.GetForCurrentThread()
                ?? throw new InvalidOperationException("HealthMonitor must be created on the UI thread.");
        timer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.IsRepeating = true;
        timer.Tick += (_, _) => Poll();
    }

    public IReadOnlyDictionary<string, Health> Status => status;

    /// <summary>The strip's colour: the worst of the run's targets, over those polled so far.</summary>
    public Health Worst(RunState state) =>
        HealthRules.Worst(state.Targets.Where(t => status.ContainsKey(t.Name)).Select(t => status[t.Name]));

    public event PropertyChangedEventHandler? PropertyChanged;

    public void Watch(IReadOnlyList<RunTarget> watched)
    {
        timer.Stop();
        generation++;
        targets = watched;
        if (watched.Count == 0)
        {
            Clear();
            return;
        }
        foreach (var t in watched) status.TryAdd(t.Name, Health.Unknown);
        Changed();
        Poll();
        timer.Start();
    }

    public void Stop()
    {
        timer.Stop();
        generation++;
        targets = [];
        Clear();
    }

    void Clear()
    {
        if (status.Count == 0) return;
        status.Clear();
        Changed();
    }

    void Poll()
    {
        var mine = generation;
        foreach (var t in targets)
        {
            if (!t.Alive || t.HealthUrlOrNull is not { } url)
            {
                Apply(mine, t.Name, _ => Health.Failing);
                continue;
            }
            _ = Check(mine, t.Name, url);
        }
    }

    async Task Check(int mine, string name, Uri url)
    {
        int? code = null;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cts.Token)
                .ConfigureAwait(false);
            code = (int)response.StatusCode;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException) { }
        queue.TryEnqueue(() => Apply(mine, name, previous =>
            code is { } c ? HealthRules.OnResponse(c) : HealthRules.OnNoResponse(previous)));
    }

    /// <summary>
    /// A late answer for a run that is no longer watched is dropped, so the
    /// strip of the run you switched to cannot pick up the last one's status.
    /// </summary>
    void Apply(int mine, string name, Func<Health, Health> next)
    {
        if (mine != generation) return;
        var previous = status.TryGetValue(name, out var p) ? p : Health.Unknown;
        var value = next(previous);
        if (status.TryGetValue(name, out var existing) && existing == value) return;
        status[name] = value;
        Changed();
    }

    void Changed() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
}

public enum EditorKind
{
    VSCode,
    Cursor,
    Zed,
    Terminal,
    ClaudeCode,
    Explorer,
}

/// <summary>
/// An editor we can offer for "Open worktree in" (spec F9). Only the ones
/// actually installed are shown — a menu full of things you do not have is
/// worse than a short menu.
/// </summary>
public sealed record Editor(EditorKind Kind, string Title, string Launcher)
{
    /// <summary>
    /// Every editor found on this machine, in the order most people would want
    /// them. Looked up once: the menu is built often and the answer only
    /// changes when something is installed, which a restart picks up.
    /// </summary>
    public static IReadOnlyList<Editor> Installed => installed.Value;

    static readonly Lazy<IReadOnlyList<Editor>> installed = new(Detect);

    static IReadOnlyList<Editor> Detect()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var found = new List<Editor>();

        void Offer(EditorKind kind, string title, string? launcher)
        {
            if (launcher is not null) found.Add(new Editor(kind, title, launcher));
        }

        Offer(EditorKind.VSCode, "Visual Studio Code", Find("Code.exe",
            [Path.Combine(local, "Programs", "Microsoft VS Code", "Code.exe"), Path.Combine(programs, "Microsoft VS Code", "Code.exe")],
            "code", up: 2));
        Offer(EditorKind.Cursor, "Cursor", Find("Cursor.exe",
            [Path.Combine(local, "Programs", "cursor", "Cursor.exe"), Path.Combine(programs, "Cursor", "Cursor.exe")],
            "cursor", up: 4));
        Offer(EditorKind.Zed, "Zed", Find("Zed.exe",
            [Path.Combine(local, "Programs", "Zed", "Zed.exe"), Path.Combine(programs, "Zed", "Zed.exe")],
            "zed", up: 0));

        var wt = WindowsTerminal(local);
        Offer(EditorKind.Terminal, "Windows Terminal", wt);
        // Claude Code is a CLI, so it opens a terminal sitting in the worktree,
        // as on the Mac. Only offered where there is a terminal to open it in
        // and a `claude` to run.
        if (wt is not null && Engine.HasCommand("claude")) Offer(EditorKind.ClaudeCode, "Claude Code", wt);
        // Always there.
        Offer(EditorKind.Explorer, "File Explorer", "explorer.exe");
        return found;
    }

    /// <summary>
    /// App Paths first (what an installer registers so Win+R can find it),
    /// then the usual install folders, then PATH. A PATH hit is usually a
    /// .cmd shim in a bin folder under the install; `up` climbs from the shim
    /// to where the real exe lives, so launching it needs no console. When
    /// the exe is not there, the shim is used as it is.
    /// </summary>
    static string? Find(string exe, string[] known, string command, int up)
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\App Paths\{exe}");
                if (key?.GetValue(null) is string p && File.Exists(p.Trim('"'))) return p.Trim('"');
            }
            catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException) { }
        }
        foreach (var k in known)
            if (File.Exists(k)) return k;
        if (Engine.Which(command) is not { } shim) return null;
        if (shim.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return shim;
        var dir = Path.GetDirectoryName(shim);
        for (var i = 0; i < up && dir is not null; i++) dir = Path.GetDirectoryName(dir);
        return dir is not null && File.Exists(Path.Combine(dir, exe)) ? Path.Combine(dir, exe) : shim;
    }

    /// <summary>
    /// wt.exe is an app execution alias in WindowsApps. It is on PATH for most
    /// people, and in its folder either way.
    /// </summary>
    static string? WindowsTerminal(string local)
    {
        if (Engine.Which("wt.exe") is { } onPath) return onPath;
        var alias = Path.Combine(local, "Microsoft", "WindowsApps", "wt.exe");
        return File.Exists(alias) ? alias : null;
    }

    public void Open(string path)
    {
        switch (Kind)
        {
            case EditorKind.Explorer:
                Shell.OpenFolder(path);
                break;
            case EditorKind.Terminal:
                Shell.Launch(Launcher, ["-d", WtEscape(path)]);
                break;
            case EditorKind.ClaudeCode:
                // `cmd /k` so a claude.cmd shim runs as well as a claude.exe,
                // and so the tab stays at a prompt in the worktree when claude
                // exits — the Mac's `cd <path> && claude` in Terminal does the same.
                Shell.Launch(Launcher, ["-d", WtEscape(path), "cmd", "/k", "claude"]);
                break;
            default:
                Shell.Launch(Launcher, [path]);
                break;
        }
    }

    /// <summary>
    /// Windows Terminal reads `;` on its command line as "new tab". A worktree
    /// path with one in it would open two tabs, one of them nonsense.
    /// </summary>
    static string WtEscape(string path) => path.Replace(";", "\\;");
}

/// <summary>
/// File Explorer, the browser, the text editor: what the Mac does with
/// NSWorkspace. Wording in the UI follows Windows (spec D14): "Show in File
/// Explorer", "Open folder".
/// </summary>
public static class Shell
{
    /// <summary>
    /// Starts a program the way double-clicking it would. A .cmd or .bat shim
    /// goes through a hidden cmd.exe, because ShellExecute would give it a
    /// console window of its own for the moment it takes to hand off.
    /// </summary>
    public static bool Launch(string program, IReadOnlyList<string> args, string? workingDirectory = null)
    {
        try
        {
            ProcessStartInfo psi;
            if (program.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || program.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
            {
                psi = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true };
                psi.ArgumentList.Add("/d");
                psi.ArgumentList.Add("/c");
                psi.ArgumentList.Add(program);
                foreach (var a in args) psi.ArgumentList.Add(a);
            }
            else
            {
                psi = new ProcessStartInfo(program)
                {
                    UseShellExecute = true,
                    Arguments = string.Join(' ', args.Select(ChildProcess.Quote)),
                };
            }
            if (workingDirectory is not null) psi.WorkingDirectory = workingDirectory;
            using var _ = Process.Start(psi);
            return true;
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    public static bool OpenUrl(Uri url) => Open(url.AbsoluteUri);

    /// <summary>A folder in File Explorer, opened on itself.</summary>
    public static bool OpenFolder(string path) => Open(path);

    /// <summary>
    /// A file selected in its folder in File Explorer ("Show in File
    /// Explorer"). A folder is opened on itself instead, which is what the
    /// Mac's reveal does for one.
    /// </summary>
    public static bool ShowInExplorer(string path)
    {
        if (Directory.Exists(path)) return OpenFolder(path);
        return Launch("explorer.exe", [$"/select,{path}"]);
    }

    /// <summary>
    /// A file in the user's text editor. A .conf has no file association, so
    /// opening it by its type would ask which app to use every time; this uses
    /// whatever opens .txt instead, and Notepad when even that is not set.
    /// </summary>
    public static bool OpenInTextEditor(string file)
    {
        var editor = TextEditor() ?? "notepad.exe";
        return Launch(editor, [file]);
    }

    static string? TextEditor()
    {
        uint size = 1024;
        var sb = new StringBuilder((int)size);
        // ASSOCSTR_EXECUTABLE = 2
        return AssocQueryString(0, 2, ".txt", "open", sb, ref size) == 0 && File.Exists(sb.ToString()) ? sb.ToString() : null;
    }

    static bool Open(string target)
    {
        try
        {
            using var _ = Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern uint AssocQueryString(uint flags, uint str, string pszAssoc, string? pszExtra, StringBuilder pszOut, ref uint pcchOut);
}
