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

// App preferences: what the Mac keeps in UserDefaults and @AppStorage, as one
// JSON file at %LOCALAPPDATA%\Runbranch\settings.json.
//
// An unpackaged app has no ApplicationData.LocalSettings, and the registry is
// a worse place for something a person might want to read or delete. The keys
// are the Mac's own, so the two stay easy to compare.
//
// Preferences are a convenience, never a reason not to start: a missing file,
// an unreadable one, or one with the wrong type under a key all read as the
// defaults. Keys this version does not know are kept on write, so an older
// build does not erase what a newer one saved.

using System.Text.Json;
using System.Text.Json.Nodes;

namespace Runbranch;

/// <summary>
/// Where the app lives (spec F5): the taskbar, the notification area, or both.
///
/// The Mac's Dock / Dock and Menu Bar / Menu Bar Only. The stored values are
/// Windows-only — this file is not shared with a Mac — so they say what they
/// mean here.
/// </summary>
public enum Presentation
{
    Taskbar,
    Both,
    Tray,
}

public static class Presentations
{
    public static readonly Presentation[] All = [Presentation.Taskbar, Presentation.Both, Presentation.Tray];

    /// <summary>Sentence case, as Windows menus are.</summary>
    public static string Label(this Presentation p) => p switch
    {
        Presentation.Both => "Taskbar and notification area",
        Presentation.Tray => "Notification area only",
        _ => "Taskbar only",
    };

    public static bool ShowsTrayIcon(this Presentation p) => p != Presentation.Taskbar;

    /// <summary>
    /// Closing the window in a tray mode hides it, because the notification
    /// area is how it comes back. In taskbar-only mode closing the window of a
    /// single-window utility quits it, as it does on the Mac.
    /// </summary>
    public static bool ClosingHides(this Presentation p) => p != Presentation.Taskbar;

    public static string Raw(this Presentation p) => p switch
    {
        Presentation.Both => "both",
        Presentation.Tray => "tray",
        _ => "taskbar",
    };

    public static Presentation Parse(string? raw) => raw switch
    {
        "both" => Presentation.Both,
        "tray" => Presentation.Tray,
        _ => Presentation.Taskbar,
    };
}

/// <summary>
/// Light or dark. The Mac has no setting — a Mac app follows the system and
/// that is that — but Windows apps offer one (Settings, Terminal, Explorer's
/// own), and one that ignored the system theme would be the odd one out.
/// </summary>
public enum Appearance
{
    System,
    Light,
    Dark,
}

public static class Appearances
{
    public static readonly Appearance[] All = [Appearance.System, Appearance.Light, Appearance.Dark];

    public static string Label(this Appearance a) => a switch
    {
        Appearance.Light => "Light",
        Appearance.Dark => "Dark",
        _ => "Use system setting",
    };

    public static string Raw(this Appearance a) => a switch
    {
        Appearance.Light => "light",
        Appearance.Dark => "dark",
        _ => "system",
    };

    public static Appearance Parse(string? raw) => raw switch
    {
        "light" => Appearance.Light,
        "dark" => Appearance.Dark,
        _ => Appearance.System,
    };
}

public sealed class Settings
{
    // Windows-only, so named here rather than borrowed from the Mac.
    public const string AppearanceKey = "appearance";

    // The Mac's keys, verbatim.
    public const string PresentationKey = "presentation";
    public const string UpdatesCheckKey = "updates.check";
    public const string LastSeenVersionKey = "updates.lastSeenVersion";
    public const string SidebarRunningKey = "sidebar.running.expanded";
    public const string SidebarFavouritesKey = "sidebar.favourites.expanded";
    public const string SidebarProjectsKey = "sidebar.projects.expanded";

    static readonly Lazy<Settings> shared = new(() => new Settings(DefaultPath));

    /// <summary>The app's one instance, at the default path.</summary>
    public static Settings Shared => shared.Value;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Runbranch", "settings.json");

    readonly object gate = new();
    readonly string path;
    JsonObject values;

    /// <summary>Any path, for tests. The app uses Shared.</summary>
    public Settings(string path)
    {
        this.path = path;
        values = Load(path);
    }

    public string FilePath => path;

    /// <summary>Raised on the thread that made the change, after it is written.</summary>
    public event Action<string>? Changed;

    public Presentation Presentation
    {
        get => Presentations.Parse(GetString(PresentationKey));
        set => Set(PresentationKey, value.Raw());
    }

    /// <summary>Light, dark, or whatever Windows is set to (the default).</summary>
    public Appearance Appearance
    {
        get => Appearances.Parse(GetString(AppearanceKey));
        set => Set(AppearanceKey, value.Raw());
    }

    /// <summary>Check for a new release on launch. Default on, as on the Mac.</summary>
    public bool UpdatesCheck
    {
        get => GetBool(UpdatesCheckKey, true);
        set => Set(UpdatesCheckKey, value);
    }

    /// <summary>
    /// The version "What's new" last showed. Empty on a fresh install, which
    /// records the installed version and shows nothing.
    /// </summary>
    public string LastSeenVersion
    {
        get => GetString(LastSeenVersionKey) ?? "";
        set => Set(LastSeenVersionKey, value);
    }

    public bool SidebarRunningExpanded
    {
        get => GetBool(SidebarRunningKey, true);
        set => Set(SidebarRunningKey, value);
    }

    public bool SidebarFavouritesExpanded
    {
        get => GetBool(SidebarFavouritesKey, true);
        set => Set(SidebarFavouritesKey, value);
    }

    public bool SidebarProjectsExpanded
    {
        get => GetBool(SidebarProjectsKey, true);
        set => Set(SidebarProjectsKey, value);
    }

    public string? GetString(string key)
    {
        lock (gate)
            return values[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    }

    public bool GetBool(string key, bool fallback)
    {
        lock (gate)
            return values[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    }

    public void Set(string key, string value) => Write(key, JsonValue.Create(value));

    public void Set(string key, bool value) => Write(key, JsonValue.Create(value));

    void Write(string key, JsonNode node)
    {
        lock (gate)
        {
            values[key] = node;
            Save();
        }
        Changed?.Invoke(key);
    }

    static JsonObject Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return [];
            return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            // A corrupt file is set aside rather than overwritten, so whatever
            // was in it can still be looked at.
            TryQuarantine(path);
            return [];
        }
    }

    static void TryQuarantine(string path)
    {
        try { File.Move(path, path + ".corrupt", overwrite: true); } catch { /* read-only or gone: defaults either way */ }
    }

    static readonly JsonSerializerOptions pretty = new() { WriteIndented = true };

    /// <summary>
    /// Written whole to a temp file and moved over the old one, so a crash
    /// mid-write leaves the previous settings rather than half of the new.
    /// Failing to save is not worth an error: the setting holds for this run.
    /// </summary>
    void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, values.ToJsonString(pretty));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
