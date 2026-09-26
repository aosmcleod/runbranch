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

using System.IO.Compression;
using System.Security.Cryptography;
using Xunit;

namespace Runbranch.Tests;

public sealed class VersionTests
{
    static AppVersion V(string s) => AppVersion.Parse(s)!;

    [Fact]
    public void ComparesByNumberNotByString() => Assert.True(V("1.10.0") > V("1.9.0"));

    [Fact]
    public void MissingComponentsAreZero()
    {
        Assert.True(V("1.3") == V("1.3.0"));
        Assert.False(V("1.3") < V("1.3.0"));
        Assert.Equal(V("1.3").GetHashCode(), V("1.3.0").GetHashCode());
    }

    [Fact]
    public void ALeadingVIsDropped()
    {
        Assert.Equal("1.5.1", V("v1.5.1").Description);
        Assert.True(V("v1.5.1") == V("1.5.1"));
    }

    [Theory]
    [InlineData("1.3.0-beta2", "1.3.0")]
    [InlineData("1.5.1+abc123", "1.5.1")]
    [InlineData("2.x.1", "2")]
    public void ASuffixEndsTheParseRatherThanFailingIt(string raw, string same) => Assert.True(V(raw) == V(same));

    [Theory]
    [InlineData("")]
    [InlineData("v")]
    [InlineData("beta")]
    [InlineData(null)]
    public void NothingNumericIsNoVersion(string? raw) => Assert.Null(AppVersion.Parse(raw));
}

public sealed class ReleaseFeedTests
{
    static string Json(string tag, string assets, bool draft = false, bool prerelease = false) =>
        $$"""{"tag_name":"{{tag}}","body":"notes","draft":{{(draft ? "true" : "false")}},"prerelease":{{(prerelease ? "true" : "false")}},"assets":[{{assets}}]}""";

    static string Asset(string name, string? digest = null) =>
        $$"""{"name":"{{name}}","size":1234,"browser_download_url":"https://example.invalid/{{name}}"{{(digest is null ? "" : $",\"digest\":\"{digest}\"")}}}""";

    [Fact]
    public void PicksTheWindowsZipByNameNotPosition()
    {
        var r = ReleaseFeed.Parse(Json("v1.6.0",
            Asset("Runbranch-1.6.0.dmg") + "," + Asset("Runbranch-1.6.0-windows-x64.zip", "sha256:ABCDEF")));
        Assert.Equal("1.6.0", r.Version.Description);
        Assert.Equal("https://example.invalid/Runbranch-1.6.0-windows-x64.zip", r.Zip!.AbsoluteUri);
        Assert.Equal(1234, r.Bytes);
        Assert.Equal("abcdef", r.Sha256);
        Assert.Equal("notes", r.Notes);
    }

    [Fact]
    public void AReleaseWithOnlyTheMacImageParsesWithNoDownload()
    {
        // So its version can still be compared: someone on it is up to date.
        var r = ReleaseFeed.Parse(Json("v1.6.0", Asset("Runbranch-1.6.0.dmg")));
        Assert.Equal("1.6.0", r.Version.Description);
        Assert.Null(r.Zip);
        Assert.Equal("Release 1.6.0 has no Windows download attached.", r.MissingDownload);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void DraftsAndPrereleasesAreRefused(bool draft, bool pre)
    {
        var e = Assert.Throws<UpdateFailure>(() =>
            ReleaseFeed.Parse(Json("v1.6.0", Asset("Runbranch-1.6.0-windows-x64.zip"), draft, pre)));
        Assert.Equal("The latest release is not public.", e.Message);
    }

    [Fact]
    public void ATagWithNoVersionSaysSo() =>
        Assert.Equal("Could not read a version from the tag nightly.",
            Assert.Throws<UpdateFailure>(() => ReleaseFeed.Parse(Json("nightly", ""))).Message);

    [Fact]
    public void NotJsonIsAFailureNotACrash() =>
        Assert.Throws<UpdateFailure>(() => ReleaseFeed.Parse("<html>rate limited</html>"));

    [Theory]
    [InlineData("sha256:0A1B", "0a1b")]
    [InlineData("SHA256:ff", "ff")]
    [InlineData("sha512:ff", null)]
    [InlineData("sha256:", null)]
    [InlineData(null, null)]
    public void DigestIsTheSha256HexOnly(string? raw, string? hex) => Assert.Equal(hex, ReleaseFeed.Digest(raw));
}

public sealed class InstallStepTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "rb-update-" + Guid.NewGuid().ToString("N"));

    public InstallStepTests() => Directory.CreateDirectory(dir);

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public void VerifyAcceptsTheRightHashAndNoHash()
    {
        var file = Path.Combine(dir, "a.zip");
        File.WriteAllText(file, "payload");
        var hex = Convert.ToHexStringLower(SHA256.HashData("payload"u8));
        Updater.Verify(file, hex);
        Updater.Verify(file, hex.ToUpperInvariant());
        Updater.Verify(file, null);
    }

    [Fact]
    public void VerifyRefusesAMismatch()
    {
        var file = Path.Combine(dir, "a.zip");
        File.WriteAllText(file, "truncated");
        var e = Assert.Throws<UpdateFailure>(() => Updater.Verify(file, new string('0', 64)));
        Assert.Contains("checksum", e.Message);
    }

    [Fact]
    public void UnpackRefusesAZipWithNoApp()
    {
        var zip = Path.Combine(dir, "u.zip");
        using (var a = ZipFile.Open(zip, ZipArchiveMode.Create))
            a.CreateEntry("Runbranch/readme.txt");
        var e = Assert.Throws<UpdateFailure>(() => Updater.Unpack(zip, Path.Combine(dir, "stage"), AppVersion.Parse("1.6.0")!));
        Assert.Equal("The download does not contain Runbranch.exe.", e.Message);
    }

    [Fact]
    public void UnpackRefusesAnExeThatIsNotRunbranch()
    {
        // Any real exe that is not this app: the test host is one.
        var zip = Path.Combine(dir, "u.zip");
        using (var a = ZipFile.Open(zip, ZipArchiveMode.Create))
            a.CreateEntryFromFile(Environment.ProcessPath!, "Runbranch/Runbranch.exe");
        var e = Assert.Throws<UpdateFailure>(() => Updater.Unpack(zip, Path.Combine(dir, "stage"), AppVersion.Parse("1.6.0")!));
        Assert.Equal("The app in the download is not Runbranch.", e.Message);
    }

    [Fact]
    public void UnpackRefusesSomethingThatIsNotAZip()
    {
        var zip = Path.Combine(dir, "u.zip");
        File.WriteAllText(zip, "not a zip");
        Assert.Throws<UpdateFailure>(() => Updater.Unpack(zip, Path.Combine(dir, "stage"), AppVersion.Parse("1.6.0")!));
    }

    [Fact]
    public void ACopyUnderTempIsBlocked()
    {
        // What File Explorer runs when you open the exe from inside the zip.
        var app = Path.Combine(dir, "Temp1_Runbranch-1.6.0-windows-x64.zip", "Runbranch");
        Directory.CreateDirectory(app);
        Assert.Contains("temporary copy", Updater.Blocker(app));
    }

    [Fact]
    public void TheHelperIsTheInstalledEngineThenTheNewOne()
    {
        var installed = Path.Combine(dir, "Runbranch");
        var app = Path.Combine(dir, ".Runbranch-update-x", "Runbranch");
        Assert.Null(Updater.HelperEngine(installed, app));
        Directory.CreateDirectory(Path.Combine(app, "bin"));
        File.WriteAllText(Path.Combine(app, Updater.EnginePath), "new");
        Assert.Equal(Path.Combine(app, Updater.EnginePath), Updater.HelperEngine(installed, app));
        Directory.CreateDirectory(Path.Combine(installed, "bin"));
        File.WriteAllText(Path.Combine(installed, Updater.EnginePath), "old");
        Assert.Equal(Path.Combine(installed, Updater.EnginePath), Updater.HelperEngine(installed, app));
    }

    [Fact]
    public void TheHelperArgumentsAreTheContracts()
    {
        Assert.Equal(["install-update", "42", @"C:\s\Runbranch", @"C:\Runbranch", "--staging", @"C:\s", "--work", @"C:\w"],
            Updater.HelperArgs("42", @"C:\s\Runbranch", @"C:\Runbranch", @"C:\s", @"C:\w"));
    }

    [Fact]
    public void SweepingRemovesOnlyOldUpdateFolders()
    {
        var old = Path.Combine(dir, Updater.WorkPrefix + "old");
        var fresh = Path.Combine(dir, Updater.WorkPrefix + "fresh");
        var other = Path.Combine(dir, "something-else");
        foreach (var d in new[] { old, fresh, other })
        {
            Directory.CreateDirectory(d);
            File.WriteAllText(Path.Combine(d, "runbranch.exe"), "x");
        }
        Directory.SetCreationTimeUtc(old, DateTime.UtcNow.AddHours(-1));
        Updater.SweepLeftovers(dir);
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(fresh));
        Assert.True(Directory.Exists(other));
    }

    [Fact]
    public void TheInstalledFolderOutsideTempIsFine()
    {
        var app = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "rb-blocker-" + Guid.NewGuid().ToString("N"), "Runbranch");
        Directory.CreateDirectory(app);
        try { Assert.Null(Updater.Blocker(app)); }
        finally { Directory.Delete(Path.GetDirectoryName(app)!, recursive: true); }
    }
}

public sealed class UpdaterStateTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "rb-updater-" + Guid.NewGuid().ToString("N"));
    Settings NewSettings() => new(Path.Combine(dir, "settings.json"));

    public void Dispose()
    {
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public async Task ADevelopmentBuildNeverChecksOnLaunchAndSaysSoWhenAsked()
    {
        var u = new Updater(AppVersion.Parse("1.5.1")!, development: true, NewSettings(), dir);
        Assert.False(await u.CheckOnLaunchAsync());
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.Development, u.Phase);
        Assert.True(u.Manual);
        Assert.Null(u.Available);
    }

    [Fact]
    public async Task LaunchChecksAreOffWhenTurnedOff()
    {
        var s = NewSettings();
        s.UpdatesCheck = false;
        var u = new Updater(AppVersion.Parse("1.5.1")!, development: false, s, dir);
        Assert.False(await u.CheckOnLaunchAsync());
    }

    [Fact]
    public void TurnOffChecksWritesTheMacKeyAndDismisses()
    {
        var s = NewSettings();
        var u = new Updater(AppVersion.Parse("1.5.1")!, development: false, s, dir);
        u.Offer(Release.Sample(""));
        u.TurnOffChecks();
        Assert.False(new Settings(Path.Combine(dir, "settings.json")).UpdatesCheck);
        Assert.Null(u.Available);
        Assert.Equal(UpdatePhase.Idle, u.Phase);
    }

    static string Latest(string tag, bool windows) =>
        $$"""{"tag_name":"{{tag}}","body":"notes","draft":false,"prerelease":false,"assets":[{"name":"Runbranch-{{tag.TrimStart('v')}}.dmg","size":1,"browser_download_url":"https://example.invalid/a.dmg"}{{(windows ? $",{{\"name\":\"Runbranch-{tag.TrimStart('v')}-windows-x64.zip\",\"size\":1,\"browser_download_url\":\"https://example.invalid/w.zip\"}}" : "")}}]}""";

    Updater With(string json) =>
        new(AppVersion.Parse("1.5.1")!, development: false, NewSettings(), dir, () => Task.FromResult(json));

    [Fact]
    public async Task TheSameVersionWithOnlyAMacBuildIsUpToDate()
    {
        // Today's real latest release: v1.5.1 with a .dmg and nothing else.
        var u = With(Latest("v1.5.1", windows: false));
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.UpToDate, u.Phase);
        Assert.Null(u.Available);
        Assert.False(await With(Latest("v1.5.1", windows: false)).CheckOnLaunchAsync());
    }

    [Fact]
    public async Task ANewerMacOnlyReleaseIsSilentOnLaunchAndSaysSoWhenAsked()
    {
        var launch = With(Latest("v1.6.0", windows: false));
        Assert.False(await launch.CheckOnLaunchAsync());
        Assert.Null(launch.Available);
        Assert.Equal(UpdatePhase.Idle, launch.Phase);

        // Not a failure: the Mac's notForMac, the other way round.
        var u = With(Latest("v1.6.0", windows: false));
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.NotForWindows, u.Phase);
        Assert.Equal("1.6.0", u.Newer!.Description);
        Assert.Null(u.Available);
        Assert.Equal("", u.Reason);

        u.Dismiss();
        Assert.Null(u.Newer);
    }

    [Fact]
    public async Task ACheckAfterNotForWindowsForgetsTheVersion()
    {
        var calls = 0;
        var u = new Updater(AppVersion.Parse("1.5.1")!, development: false, NewSettings(), dir,
            () => Task.FromResult(++calls == 1 ? Latest("v1.6.0", windows: false) : Latest("v1.6.0", windows: true)));
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.NotForWindows, u.Phase);
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.Idle, u.Phase);
        Assert.Null(u.Newer);
        Assert.NotNull(u.Available);
    }

    [Fact]
    public async Task ANewerWindowsReleaseIsOfferedOnceOnLaunch()
    {
        var u = With(Latest("v1.6.0", windows: true));
        Assert.True(await u.CheckOnLaunchAsync());
        Assert.Equal("https://example.invalid/w.zip", u.Available!.Zip!.AbsoluteUri);
        // Once per process.
        Assert.False(await u.CheckOnLaunchAsync());
    }

    [Fact]
    public async Task AnOlderLatestIsNotAnUpdate()
    {
        var u = With(Latest("v1.4.0", windows: true));
        await u.CheckNowAsync();
        Assert.Equal(UpdatePhase.UpToDate, u.Phase);
    }

    [Fact]
    public void ReadableErrors()
    {
        Assert.Equal("GitHub did not answer in time.", Updater.Readable(new TaskCanceledException()));
        Assert.Equal("No network connection.",
            Updater.Readable(new HttpRequestException(HttpRequestError.NameResolutionError, "no such host")));
        Assert.Equal("GitHub answered 403.", Updater.Readable(new UpdateFailure("GitHub answered 403.")));
    }
}
