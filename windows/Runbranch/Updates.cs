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

// Noticing a new release and installing it (spec F10) — Updates.swift, with
// the disk image and bash swap replaced by a zip and `runbranch.exe
// install-update`. The shape is the Mac's: GitHub's latest release, the asset
// picked by name, the SHA-256 GitHub publishes checked before anything is
// touched, then a helper that waits for this process to exit and swaps the
// folder. The helper is the engine rather than a PowerShell script because
// script policy is often locked down on work machines (spec F17).
//
// Free of WinUI, like Model.cs, so Runbranch.Tests compiles it on its own.
// Changed is raised on whatever thread made the change; the Update dialog
// moves it to the UI thread.

using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;

namespace Runbranch;

/// <summary>
/// A dotted version, compared by number rather than by string.
///
/// String comparison gets "1.10.0" &lt; "1.9.0" wrong, which is exactly the
/// comparison this app will start making around its tenth minor release.
/// Named AppVersion rather than the Mac's Version so it cannot be mistaken
/// for System.Version, which every file here also sees.
/// </summary>
public sealed class AppVersion : IComparable<AppVersion>, IEquatable<AppVersion>
{
    public IReadOnlyList<int> Parts { get; }
    /// <summary>The text parsed, without a leading v: what the UI shows.</summary>
    public string Description { get; }

    AppVersion(IReadOnlyList<int> parts, string description)
    {
        Parts = parts;
        Description = description;
    }

    /// <summary>
    /// Accepts a tag or an assembly version: a leading `v` is dropped, and a
    /// non-numeric suffix ends the parse rather than failing it, so a
    /// `1.3.0-beta2` tag reads as 1.3.0 instead of as nothing at all, and a
    /// `1.5.1+abc123` informational version as 1.5.1.
    /// </summary>
    public static AppVersion? Parse(string? raw)
    {
        if (raw is null) return null;
        var text = raw.StartsWith('v') ? raw[1..] : raw;
        var parts = new List<int>();
        foreach (var piece in text.Split('.', StringSplitOptions.RemoveEmptyEntries))
        {
            var digits = new string(piece.TakeWhile(char.IsAsciiDigit).ToArray());
            if (digits.Length == 0 || !int.TryParse(digits, out var n)) break;
            parts.Add(n);
        }
        return parts.Count == 0 ? null : new AppVersion(parts, text);
    }

    /// <summary>The version this build is. "0" when it cannot say, as on the Mac.</summary>
    public static AppVersion Installed => Parse(Build.Version) ?? Parse("0")!;

    /// <summary>
    /// Missing components read as zero, so 1.3 and 1.3.0 are the same version
    /// rather than the shorter one being smaller.
    /// </summary>
    public int CompareTo(AppVersion? other)
    {
        if (other is null) return 1;
        for (var i = 0; i < Math.Max(Parts.Count, other.Parts.Count); i++)
        {
            var x = i < Parts.Count ? Parts[i] : 0;
            var y = i < other.Parts.Count ? other.Parts[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        return 0;
    }

    public bool Equals(AppVersion? other) => other is not null && CompareTo(other) == 0;
    public override bool Equals(object? obj) => obj is AppVersion v && Equals(v);
    public override int GetHashCode() => string.Join('.', Parts.Reverse().SkipWhile(p => p == 0).Reverse()).GetHashCode(StringComparison.Ordinal);
    public override string ToString() => Description;

    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(AppVersion a, AppVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(AppVersion a, AppVersion b) => a.CompareTo(b) >= 0;
    public static bool operator ==(AppVersion? a, AppVersion? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(AppVersion? a, AppVersion? b) => !(a == b);
}

/// <summary>One release, reduced to the parts an update needs.</summary>
/// <param name="Zip">The Windows download; null when the release has none.</param>
public sealed record Release(AppVersion Version, string Notes, Uri? Zip, long Bytes, string? Sha256)
{
    /// <summary>
    /// For an install asked of a release with nothing to install. The Update
    /// sheet never gets that far — a newer release with no Windows download
    /// is UpdatePhase.NotForWindows, not a failure — so this is the backstop.
    /// </summary>
    public string MissingDownload => $"Release {Version.Description} has no Windows download attached.";

    /// <summary>
    /// The asset make-app.ps1 -Release produces. By name, not by position:
    /// releases carry the Mac's disk image and other assets too, and picking
    /// assets[0] would eventually download the wrong one.
    /// </summary>
    public static string AssetName(AppVersion v) => $"Runbranch-{v.Description}-windows-x64.zip";

    /// <summary>Stand-in content for the dialog harness; a version that will not exist for a while.</summary>
    public static Release Sample(string notes) =>
        new(AppVersion.Parse("9.0.0")!, notes, new Uri("https://example.invalid/Runbranch-9.0.0-windows-x64.zip"), 2_400_000, null);
}

/// <summary>What went wrong, in words fit for the Update dialog.</summary>
public sealed class UpdateFailure(string message) : Exception(message);

/// <summary>GitHub's `releases/latest`, read.</summary>
public static class ReleaseFeed
{
    public static readonly Uri Latest = new("https://api.github.com/repos/aosmcleod/runbranch/releases/latest");
    public static readonly Uri ReleasesPage = new("https://github.com/aosmcleod/runbranch/releases/latest");

    /// <summary>
    /// The release in a `releases/latest` body, or an UpdateFailure saying why
    /// not. A release with no Windows zip still parses, with Zip null, so the
    /// version can be compared before its absence matters.
    /// </summary>
    public static Release Parse(string json)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(json).RootElement; }
        catch (JsonException) { throw new UpdateFailure("GitHub's answer could not be read."); }
        if (root.ValueKind != JsonValueKind.Object) throw new UpdateFailure("GitHub's answer could not be read.");

        if (Bool(root, "draft") || Bool(root, "prerelease")) throw new UpdateFailure("The latest release is not public.");
        var tag = Str(root, "tag_name") ?? "";
        var version = AppVersion.Parse(tag) ?? throw new UpdateFailure($"Could not read a version from the tag {tag}.");

        var wanted = Release.AssetName(version);
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var a in assets.EnumerateArray())
            {
                if (a.ValueKind != JsonValueKind.Object || Str(a, "name") != wanted) continue;
                if (!Uri.TryCreate(Str(a, "browser_download_url"), UriKind.Absolute, out var url))
                    throw new UpdateFailure($"Release {version} lists {wanted} with no address to download it from.");
                var size = a.TryGetProperty("size", out var s) && s.TryGetInt64(out var n) ? n : 0;
                return new Release(version, Str(root, "body") ?? "", url, size, Digest(Str(a, "digest")));
            }
        }
        return new Release(version, Str(root, "body") ?? "", null, 0, null);
    }

    /// <summary>
    /// Lowercase hex from the `digest` GitHub publishes alongside an asset,
    /// "sha256:&lt;hex&gt;". null when there is none — older releases predate
    /// the field — or it is some other algorithm.
    /// </summary>
    public static string? Digest(string? raw) =>
        raw is not null && raw.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) && raw.Length > 7
            ? raw[7..].ToLowerInvariant()
            : null;

    static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static bool Bool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
}

public enum UpdatePhase
{
    Idle,
    Checking,
    /// <summary>Progress is 0...1, or null while the server has not said how big the file is.</summary>
    Downloading,
    Verifying,
    Installing,
    UpToDate,
    /// <summary>
    /// A newer release exists, but with nothing for Windows: it shipped for
    /// the Mac alone (spec F18). Not a failure, and not "up to date" either,
    /// because someone who has seen the release page knows better. The
    /// version is Updater.Newer. The Mac's notForMac, the other way round.
    /// </summary>
    NotForWindows,
    /// <summary>Asked on a build that must not update itself.</summary>
    Development,
    Failed,
}

public sealed class Updater
{
    // The app's own instance, first touched by the launch check, which is when
    // the last update's leftovers are swept: in the background, since nothing
    // waits on it. Here rather than in the constructor so tests never sweep
    // the real %TEMP%.
    static readonly Lazy<Updater> shared = new(() =>
    {
        _ = Task.Run(() => SweepLeftovers());
        return new Updater(AppVersion.Installed, Build.IsDevelopment, Settings.Shared, AppContext.BaseDirectory);
    });

    public static Updater Shared => shared.Value;

    readonly AppVersion installed;
    readonly bool development;
    readonly Settings settings;
    readonly string installDir;
    readonly Func<Task<string>>? feed;
    bool checkedOnce;

    /// <summary>
    /// Any version, channel, settings and folder, for tests. The app uses
    /// Shared. `feed` stands in for GitHub: the body of `releases/latest`.
    /// </summary>
    public Updater(AppVersion installed, bool development, Settings settings, string installDir, Func<Task<string>>? feed = null)
    {
        this.feed = feed;
        this.installed = installed;
        this.development = development;
        this.settings = settings;
        this.installDir = Path.TrimEndingDirectorySeparator(Path.GetFullPath(installDir));
    }

    public AppVersion Installed => installed;
    public Release? Available { get; private set; }
    /// <summary>While NotForWindows: the release that is newer but has no Windows download.</summary>
    public AppVersion? Newer { get; private set; }
    public UpdatePhase Phase { get; private set; }
    /// <summary>While Downloading: 0...1, or null when the size is not known.</summary>
    public double? Progress { get; private set; }
    /// <summary>While Failed: why, in words.</summary>
    public string Reason { get; private set; } = "";
    /// <summary>
    /// Set when the user asked, so "you are up to date" is reported rather
    /// than passed over in silence the way the launch check does.
    /// </summary>
    public bool Manual { get; private set; }

    /// <summary>Raised after any change, on the thread that made it.</summary>
    public event Action? Changed;

    // Unauthenticated is 60 requests an hour per address. One per launch is
    // nothing, but the header is what GitHub asks for and it makes the
    // traffic identifiable if it ever does need explaining.
    static HttpClient Client(TimeSpan timeout, AppVersion v)
    {
        var c = new HttpClient { Timeout = timeout };
        c.DefaultRequestHeaders.UserAgent.ParseAdd($"Runbranch/{v.Description}");
        return c;
    }

    // --- checking ----------------------------------------------------------

    /// <summary>
    /// The launch check, once per process. Silent about everything: no
    /// network, a rate limit, a release with no Windows download — none of
    /// that is the user's problem, and none of it should raise a dialog in
    /// front of an app they just opened. Returns whether there is an update
    /// to offer.
    /// </summary>
    public async Task<bool> CheckOnLaunchAsync()
    {
        // A development build must never offer to replace itself with a
        // release: the whole point of the one in the dev folder is that it is
        // the build you are working on, and an update would silently throw it
        // away for whatever was last tagged.
        if (development || checkedOnce || !settings.UpdatesCheck) return false;
        checkedOnce = true;
        try
        {
            var release = await FetchAsync().ConfigureAwait(false);
            if (release.Version <= installed || release.Zip is null) return false;
            Available = release;
            Changed?.Invoke();
            return true;
        }
        catch (Exception e) when (IsExpected(e))
        {
            return false;
        }
    }

    /// <summary>The ••• menu's check, which reports either way.</summary>
    public async Task CheckNowAsync()
    {
        checkedOnce = true;
        Manual = true;
        // Said rather than silently skipped. Picking the menu item and having
        // nothing happen at all reads as a broken menu item.
        if (development)
        {
            Available = null;
            Set(UpdatePhase.Development);
            return;
        }
        Set(UpdatePhase.Checking);
        try
        {
            var release = await FetchAsync().ConfigureAwait(false);
            Newer = null;
            if (release.Version > installed && release.Zip is null)
            {
                Available = null;
                Newer = release.Version;
                Set(UpdatePhase.NotForWindows);
                return;
            }
            Available = release.Version > installed ? release : null;
            Set(Available is null ? UpdatePhase.UpToDate : UpdatePhase.Idle);
        }
        catch (Exception e) when (IsExpected(e))
        {
            Available = null;
            Fail(Readable(e));
        }
    }

    async Task<Release> FetchAsync()
    {
        if (feed is not null) return ReleaseFeed.Parse(await feed().ConfigureAwait(false));
        using var http = Client(TimeSpan.FromSeconds(15), installed);
        using var request = new HttpRequestMessage(HttpMethod.Get, ReleaseFeed.Latest);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        // The API caches aggressively at the edge; a stale hit would report an
        // old version as the newest one for as long as it lived.
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        using var response = await http.SendAsync(request).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK) throw new UpdateFailure($"GitHub answered {(int)response.StatusCode}.");
        return ReleaseFeed.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
    }

    // --- can we even install? ---------------------------------------------

    /// <summary>
    /// Why an in-place update is impossible here, or null when it is fine.
    ///
    /// Both cases fail in a way that looks like a bug in the updater rather
    /// than a fact about where the app is, so they are worth naming before
    /// the download rather than after it.
    /// </summary>
    public static string? Blocker(string installDir)
    {
        var dir = Path.TrimEndingDirectorySeparator(Path.GetFullPath(installDir));
        // Opening the exe from inside a zip in File Explorer runs a copy it
        // extracted to %TEMP% — the Windows version of the Mac's translocated
        // read-only copy. Updating that copy would update nothing anyone keeps.
        var temp = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath()));
        if (dir.StartsWith(temp + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            return "Runbranch is running from a temporary copy, which is what File Explorer makes when "
                 + "you open it from inside the zip. Extract the zip to a folder and open it from there.";
        // The swap renames this folder aside and moves the new one in beside
        // it, so it is the parent that has to be writable, not only the folder.
        var parent = Path.GetDirectoryName(dir);
        if (parent is null || !Writable(parent)) return $"Runbranch is in {parent ?? dir}, which this account cannot write to.";
        if (!Writable(dir)) return $"Runbranch is in {dir}, which this account cannot write to.";
        return null;
    }

    static bool Writable(string dir)
    {
        var probe = Path.Combine(dir, $".runbranch-write-test-{Guid.NewGuid():N}");
        try
        {
            File.WriteAllBytes(probe, []);
            File.Delete(probe);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    // --- installing --------------------------------------------------------

    /// <summary>The engine, where make-app.ps1 puts it in an install folder. It does the swap.</summary>
    public static readonly string EnginePath = Path.Combine("bin", "runbranch.exe");

    /// <summary>What each attempt's download folder in %TEMP% is called, followed by a GUID.</summary>
    public const string WorkPrefix = "runbranch-update-";

    /// <summary>Where the swap writes what it did (the engine's update.DefaultLog).</summary>
    public static string UpdateLog =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Runbranch", "update.log");

    /// <summary>
    /// Downloads, verifies, unpacks and hands off, then calls `quit`. Leaves
    /// the phase Failed, with nothing changed on disk, if any step before the
    /// hand-off goes wrong.
    /// </summary>
    public async Task InstallAsync(Release release, Action quit)
    {
        if (Blocker(installDir) is { } why)
        {
            Fail(why);
            return;
        }

        var work = Path.Combine(Path.GetTempPath(), $"{WorkPrefix}{Guid.NewGuid():N}");
        var staging = Path.Combine(Path.GetDirectoryName(installDir)!,
            $".{Path.GetFileName(installDir)}-update-{Guid.NewGuid().ToString("N")[..8]}");
        try
        {
            Directory.CreateDirectory(work);
            Progress = null;
            Set(UpdatePhase.Downloading);
            var zip = await DownloadAsync(release, Path.Combine(work, Release.AssetName(release.Version))).ConfigureAwait(false);

            Set(UpdatePhase.Verifying);
            await Task.Run(() => Verify(zip, release.Sha256)).ConfigureAwait(false);
            var app = await Task.Run(() => Unpack(zip, staging, release.Version)).ConfigureAwait(false);

            Set(UpdatePhase.Installing);
            await HandOffAsync(app, staging, work).ConfigureAwait(false);
        }
        catch (Exception e) when (IsExpected(e))
        {
            TryDelete(staging);
            TryDelete(work);
            Fail(Readable(e));
            return;
        }

        // A hidden copy of the engine is now waiting for this process to go
        // away before it swaps the folder. Anything that keeps us alive keeps the
        // old version installed, so the caller quits outright.
        quit();
    }

    async Task<string> DownloadAsync(Release release, string dest)
    {
        // A download made here carries no Mark of the Web — that is attached
        // by browsers, and HttpClient does not — so SmartScreen has nothing to
        // say about the new exe, which is why the updater needs no signing.
        using var http = Client(TimeSpan.FromMinutes(10), installed);
        var zip = release.Zip ?? throw new UpdateFailure(release.MissingDownload);
        using var response = await http.GetAsync(zip, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK) throw new UpdateFailure($"The download failed with {(int)response.StatusCode}.");

        // No length is a real case and must show as an indeterminate bar
        // rather than as a bar stuck at zero.
        long? total = response.Content.Headers.ContentLength is > 0 and var length ? length : null;
        await using var source = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
        await using var file = File.Create(dest);
        var buffer = new byte[81920];
        long done = 0;
        var shown = -1;
        int n;
        while ((n = await source.ReadAsync(buffer).ConfigureAwait(false)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, n)).ConfigureAwait(false);
            done += n;
            if (total is not { } t) continue;
            // Per percent, not per read: a Changed per 80 KB is thousands of
            // dispatcher hops for a bar nobody can see move that finely.
            var percent = (int)(done * 100 / t);
            if (percent == shown) continue;
            shown = percent;
            Progress = Math.Min(1.0, (double)done / t);
            Changed?.Invoke();
        }
        return dest;
    }

    /// <summary>
    /// Checks the bytes against the hash GitHub publishes.
    ///
    /// Not a signature: it proves the file is the one the release page lists,
    /// not that the release page is honest. What it does catch is a truncated
    /// or corrupted download, which is the failure that actually happens, and
    /// it catches it before anything is replaced.
    /// </summary>
    public static void Verify(string file, string? expected)
    {
        if (expected is null) return;
        using var stream = File.OpenRead(file);
        var actual = Convert.ToHexStringLower(SHA256.HashData(stream));
        if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
            throw new UpdateFailure("The download does not match the checksum GitHub published for it.");
    }

    /// <summary>
    /// Extracts beside the installed folder, so the swap is a rename on one
    /// volume rather than a copy, and checks what came out. Everything here
    /// happens while the installed copy is untouched: once the helper starts
    /// there is no cheap way back, so this is the last chance to find out the
    /// download is not what it said. Returns the new app's folder.
    /// </summary>
    public static string Unpack(string zip, string staging, AppVersion expected)
    {
        // ExtractToDirectory refuses entries that would land outside it.
        try { ZipFile.ExtractToDirectory(zip, staging); }
        catch (InvalidDataException) { throw new UpdateFailure("The download is not a zip file that can be opened."); }

        // The zip holds a Runbranch\ folder (make-app.ps1). A zip of the bare
        // contents is accepted too, since that is an easy one to make by hand.
        var app = new[] { Path.Combine(staging, "Runbranch"), staging }
            .FirstOrDefault(d => File.Exists(Path.Combine(d, "Runbranch.exe")))
            ?? throw new UpdateFailure("The download does not contain Runbranch.exe.");

        var info = FileVersionInfo.GetVersionInfo(Path.Combine(app, "Runbranch.exe"));
        if (info.ProductName != "Runbranch") throw new UpdateFailure("The app in the download is not Runbranch.");
        var found = AppVersion.Parse(info.ProductVersion);
        if (found != expected)
            throw new UpdateFailure($"The download holds {found?.Description ?? "an unknown version"}, not {expected.Description}.");
        // An app with nothing to run is not an update, whatever its version says.
        if (!File.Exists(Path.Combine(app, "bin", "runbranch.exe")))
            throw new UpdateFailure("The download has no engine in it.");
        return app;
    }

    /// <summary>
    /// Which engine does the swap: the installed one, falling back to the
    /// new one. The installed one first because it is the same build as this
    /// code, so the arguments below are the ones it understands; a future
    /// engine is free to change them. Null when there is neither.
    /// </summary>
    public static string? HelperEngine(string installDir, string app) =>
        new[] { Path.Combine(installDir, EnginePath), Path.Combine(app, EnginePath) }.FirstOrDefault(File.Exists);

    /// <summary>
    /// Starts the helper and waits until it says it is running.
    ///
    /// A copy in the download folder, never bin\runbranch.exe where it is:
    /// that file is inside the folder the helper is about to move, and
    /// Windows will not rename a folder with a running program in it. And the
    /// wait matters: if the helper cannot start at all, or refuses the new
    /// folder, quitting anyway would leave nothing running and nothing
    /// installed. It checks the new folder before it says it started, so a
    /// refusal arrives here as an early exit, while there is still an app to
    /// say so.
    /// </summary>
    async Task HandOffAsync(string app, string staging, string work)
    {
        var engine = HelperEngine(installDir, app)
            ?? throw new UpdateFailure("This build has no engine to install with; download the update instead.");
        var helperExe = Path.Combine(work, "runbranch.exe");
        File.Copy(engine, helperExe, overwrite: true);
        var started = Path.Combine(work, "started");

        var pid = Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        using var helper = StartHelper(helperExe, HelperArgs(pid, app, installDir, staging, work));
        for (var waited = 0; waited < 100; waited++)
        {
            if (File.Exists(started)) return;
            if (helper.HasExited)
                throw new UpdateFailure($"The installer stopped before it began (exit code {helper.ExitCode}). Its log is {UpdateLog}.");
            await Task.Delay(100).ConfigureAwait(false);
        }
        try { helper.Kill(); } catch (InvalidOperationException) { }
        throw new UpdateFailure("The installer did not start in time.");
    }

    /// <summary>
    /// `install-update`'s arguments (docs/specs/windows-port-engine-contract.md).
    /// Public so the tests can run the real engine with exactly these.
    /// </summary>
    public static string[] HelperArgs(string pid, string app, string installDir, string staging, string work) =>
        ["install-update", pid, app, installDir, "--staging", staging, "--work", work];

    /// <summary>
    /// The engine with no window of any kind: CreateNoWindow gives the
    /// console program a console nobody sees, so there is nothing to flash on
    /// screen. Public for the hand-off's own tests.
    /// </summary>
    public static Process StartHelper(string exe, IEnumerable<string> args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return Process.Start(psi) ?? throw new UpdateFailure("The installer could not be started.");
    }

    /// <summary>
    /// Removes what earlier updates left in %TEMP%. The helper empties its
    /// download folder but cannot delete itself from it while it runs, so a
    /// copy of the engine stays behind after every update; this is where it
    /// goes. Only folders older than `age` (ten minutes), so an attempt in
    /// progress is never swept from under itself, and anything still in use
    /// is simply left for next time.
    /// </summary>
    public static void SweepLeftovers(string? temp = null, TimeSpan? age = null)
    {
        var root = temp ?? Path.GetTempPath();
        var cutoff = DateTime.UtcNow - (age ?? TimeSpan.FromMinutes(10));
        string[] dirs;
        try { dirs = Directory.GetDirectories(root, WorkPrefix + "*"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        foreach (var dir in dirs)
        {
            try { if (Directory.GetCreationTimeUtc(dir) > cutoff) continue; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            TryDelete(dir);
        }
    }

    // --- preferences and state ---------------------------------------------

    /// <summary>Puts a release up without a check having found one: the dialog harness.</summary>
    public void Offer(Release release)
    {
        Available = release;
        Changed?.Invoke();
    }

    /// <summary>Puts the dialog in a phase without doing the work: the dialog harness.</summary>
    public void Preview(UpdatePhase phase, double? progress = null, string reason = "")
    {
        Progress = progress;
        Reason = reason;
        Set(phase);
    }

    public void TurnOffChecks()
    {
        settings.UpdatesCheck = false;
        Dismiss();
    }

    public void Dismiss()
    {
        Available = null;
        Newer = null;
        Manual = false;
        Set(UpdatePhase.Idle);
    }

    void Set(UpdatePhase phase)
    {
        Phase = phase;
        Changed?.Invoke();
    }

    void Fail(string reason)
    {
        Reason = reason;
        Set(UpdatePhase.Failed);
    }

    static bool IsExpected(Exception e) =>
        e is UpdateFailure or HttpRequestException or TaskCanceledException or OperationCanceledException
            or IOException or UnauthorizedAccessException or InvalidDataException or JsonException
            or System.ComponentModel.Win32Exception;

    /// <summary>Errors mapped to readable text: no network, timed out, the HTTP code.</summary>
    public static string Readable(Exception e) => e switch
    {
        UpdateFailure f => f.Message,
        TaskCanceledException or OperationCanceledException => "GitHub did not answer in time.",
        HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError } =>
            "No network connection.",
        HttpRequestException { InnerException: SocketException } => "No network connection.",
        _ => e.Message,
    };

    static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
