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

// The app itself: scenes, the menu bar, and where a launch begins.

// RunBranch — the front end. All the work happens in runbranch.sh;
// this is a window over it. Projects are declared in projects/*.conf and the
// app knows nothing about any of them beyond what the engine reports.
//
// Why a compiled app rather than osascript dialogs: NSAlert cannot be made to
// look like anything but NSAlert. It picks up desktop translucency, it shows
// the interpreter's icon rather than ours, and it stacks buttons vertically
// past two. It also cannot show progress, which meant handing off to
// Terminal.app over Apple Events — a permission the bundle does not have, so a
// launch could fail silently. Running the script as a subprocess and streaming
// it into this window removes that whole class of failure.

import SwiftUI
import AppKit

/// Where the app appears: Dock, menu bar, or both.
///
/// Menu-bar-only means switching NSApplication's activation policy to
/// .accessory, which removes the Dock icon and the app's own menu bar. That is
/// reversible at runtime, but it also means the window can only be summoned
/// from the status item, so the status menu always offers a way back.
enum Presentation: String, CaseIterable, Identifiable {
    case dock, both, menuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dock:    return "Dock Only"
        case .both:    return "Dock and Menu Bar"
        case .menuBar: return "Menu Bar Only"
        }
    }

    var showsStatusItem: Bool { self != .dock }
    var policy: NSApplication.ActivationPolicy { self == .menuBar ? .accessory : .regular }

    static let key = "presentation"

    static var current: Presentation {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(Presentation.init) ?? .dock
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Owns the status item. One instance, created at launch.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    static let shared = MenuBarController()

    @Published private(set) var mode: Presentation = .dock
    private var item: NSStatusItem?

    /// What the menu shows. Set by the window as its state changes, since the
    /// status item lives outside any view.
    var project: String?
    var branch: String?
    var running = false
    var healthLabel: String?
    var onOpenWindow: (() -> Void)?
    var onStop: (() -> Void)?

    /// `initial` is the application of the saved setting at launch, which must
    /// not summon a window: SwiftUI has already made one, and asking for
    /// another opens a duplicate.
    // Menu-bar-only still shows its window at launch, because the scene opens
    // one and closing it here does not work: tearing down ContentView takes
    // with it the openWindow environment action that `onOpenWindow` captured,
    // so the status menu could no longer bring a window back at all. Suppressing
    // the launch window needs the scene to not open one in the first place —
    // `.defaultLaunchBehavior(.suppressed)` — which is a per-scene decision and
    // cannot be made conditional on a runtime setting.
    private var closeObserver: NSObjectProtocol?

    func apply(_ next: Presentation, initial: Bool = false) {
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in MenuBarController.shared.windowClosed() }
            }
        }

        mode = next
        Presentation.current = next
        NSApp.setActivationPolicy(next.policy)

        if next.showsStatusItem {
            if item == nil { install() }
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }

        // Leaving .accessory does not bring the window back on its own, and
        // entering it hides one that was open. Either way the user asked for a
        // change of where the app lives, not for their window to vanish.
        if next != .menuBar && !initial {
            NSApp.activate(ignoringOtherApps: true)
            onOpenWindow?()
        }
    }

    private func install() {
        let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = new.button {
            // A template image is tinted by the system for light and dark menu
            // bars and inverted while the menu is open. Anything else looks
            // wrong in at least one of those states.
            // NSImage(named:) resolves MenuBarIcon@2x.png alongside the 1x file
            // and builds one image with both, so the item is sharp on Retina.
            // Loading the 1x by URL got that representation only.
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                // Never scale the axes independently. The default for a button
                // is proportional, but saying so costs nothing and this glyph
                // is not square, which is exactly when the difference shows.
                button.imageScaling = .scaleProportionallyDown
                // Its own size, deliberately. The mark is wider than it is
                // tall and a status item is variable-width; forcing a square
                // was what made the glyph small.
                button.image = image
            } else {
                button.title = "RB"
            }
            button.toolTip = "Runbranch"
        }
        new.menu = buildMenu()
        item = new
    }

    /// Rebuilt on each open, so it reflects the current run rather than
    /// whatever was true when the item was installed.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func refresh() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()

        let heading: String
        if let project {
            heading = running
                ? "\(project) — \(branch ?? "?")"
                : "\(project) — not running"
        } else {
            heading = "No project selected"
        }
        let title = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if running, let healthLabel {
            let status = NSMenuItem(title: healthLabel, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        if running {
            menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "Open Runbranch", action: #selector(openWindow),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Runbranch", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func stop() { onStop?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openWindow() {
        // An .accessory app cannot raise a window, so become .regular first —
        // and then STAY there while the window is up.
        //
        // Reverting on a timer instead does not work: the policy change lands
        // while the window is still being created and takes it with it, so
        // Open silently produced nothing. The Dock icon is tied to whether a
        // window is open, which is also the behaviour people expect from a
        // menu bar app that can show one.
        if mode == .menuBar { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        onOpenWindow?()
    }

    /// Back to accessory once the last window goes away, so the Dock icon does
    /// not linger against the setting.
    func windowClosed() {
        guard mode == .menuBar else { return }
        // The closing window is still in the list at notification time.
        let remaining = NSApp.windows.filter {
            $0.isVisible && $0.parent == nil && !($0 is NSPanel)
        }
        guard remaining.count <= 1 else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

/// Lets the main menu drive the window's actions.
///
/// Menu commands are built at the App level, where none of ContentView's state
/// is reachable. Rather than duplicate the work behind each command, the view
/// registers what it can do and the menu items call through.
@MainActor
final class MenuBridge: ObservableObject {
    static let shared = MenuBridge()
    var addProject: (() -> Void)?
    var scanForProjects: (() -> Void)?
    var editProject: (() -> Void)?
    var refresh: (() -> Void)?
    var checkForUpdates: (() -> Void)?
    /// Nil when nothing is selected, so the menu can disable what needs one.
    var hasSelection: () -> Bool = { false }
}

/// Owns the About panel. One instance, built on first use.
@MainActor
final class AboutPanel {
    static let shared = AboutPanel()
    private var panel: NSPanel?
    /// So a capture can target this window rather than guessing at it by size.
    /// Guessing picked an invisible 500x500 window AppKit keeps around and
    /// cropped the main window instead.
    nonisolated(unsafe) static var windowNumber: Int?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            // Not a utility panel: it should not float over everything, and it
            // should go away when the app is not in front.
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AboutView())
            p.contentView = host
            p.setContentSize(host.fittingSize)
            p.center()
            panel = p
            AboutPanel.windowNumber = p.windowNumber
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The About window.
///
/// Not `orderFrontStandardAboutPanel`, which was the first attempt: it renders
/// the icon at a fixed, small size and takes no instruction about it, and it
/// has nowhere to put a link. The layout below follows the same shape as the
/// system panel — icon, name, one line of what it is, version, then the small
/// print — because that shape is what people recognise.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // The app icon rather than the bare mark: the tile is what the
            // system panels show, and it is what the app looks like in the Dock.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 26)

            Text("Runbranch")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 14)

            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            // Only on a development build, and only then. A release should say
            // nothing about a distinction its user has no reason to know about.
            if Build.isDevelopment {
                Badge(text: "development build", symbol: "hammer.fill", color: .orange)
                    .padding(.top, 7)
            }

            Spacer(minLength: 14)

            VStack(spacing: 3) {
                Text("Created by Alec McLeod")
                Text("GPL-3.0 — free to use, change and share alike")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Link("Runbranch on GitHub", destination: repoURL)
                .font(.system(size: 11))
                .padding(.top, 10)
                .padding(.bottom, 24)
        }
        .multilineTextAlignment(.center)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var repoURL: URL {
        URL(string: "https://github.com/aosmcleod/runbranch")!
    }
}

/// Keeps the app alive with no window open.
///
/// A SwiftUI app terminates when its last window closes, which makes menu-bar
/// only mode impossible: switching to .accessory takes the window away and the
/// app exits with it. In Dock-only mode the old behaviour is right — closing
/// the window of a single-window utility should quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        Presentation.current == .dock
    }
}

@main
struct RunBranchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // No window tabbing. It fills View and Window with items — Show Tab
        // Bar, Merge All Windows, Move Tab to New Window — that do nothing
        // useful for a single-window utility whose whole state is one project.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Runbranch", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        .commands {
            // Toggle Sidebar, which View otherwise lacks entirely.
            SidebarCommands()
            CommandGroup(replacing: .help) {
                Button("Runbranch on GitHub") {
                    if let url = URL(string: "https://github.com/aosmcleod/runbranch") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Runbranch") { AboutPanel.shared.show() }
                Button("Check for Updates…") { MenuBridge.shared.checkForUpdates?() }
            }
            // Replacing .newItem drops "New Window" with it, which is the
            // right call: a second window on the same projects would show the
            // same state twice and offer no way to tell them apart.
            CommandGroup(replacing: .newItem) {
                Button("Add a Project…") { MenuBridge.shared.addProject?() }
                    .keyboardShortcut("n")
                Button("Scan for Projects…") { MenuBridge.shared.scanForProjects?() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Project Settings…") { MenuBridge.shared.editProject?() }
                    .keyboardShortcut(",")
                    .disabled(!MenuBridge.shared.hasSelection())
                Button("Reveal Projects Folder in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: Engine.projectsDir)
                }
                Divider()
                Button("Refresh") { MenuBridge.shared.refresh?() }
                    .keyboardShortcut("r")
            }
        }
    }

}
