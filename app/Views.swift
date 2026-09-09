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

// The small views — the ones with no state of their own worth naming.

import SwiftUI
import AppKit

struct Badge: View {
    /// The default branch. A fixed hue rather than a semantic colour, for the
    /// reason the call site gives, and teal because every other badge colour
    /// here is taken.
    static let trunk = Color(red: 0.09, green: 0.58, blue: 0.64)

    let text: String
    var symbol: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// The run's status, as one glass bar.
///
/// An earlier version copied Stocks' stats grid literally — a column of
/// 9pt uppercase labels over values. At that size, in tertiary, the labels
/// were unreadable, and four of them turned a status line into a form. What
/// actually matters is one sentence (how it is, how long) and the things you
/// might click. So: no labels, and the clickable parts look clickable.
struct RunStrip: View {
    let state: RunState
    /// Observed, not just held. As a plain property this view never subscribed
    /// to the monitor's changes, so the indicator kept whatever it first drew:
    /// a run that had gone healthy still read "Starting" indefinitely.
    @ObservedObject var health: HealthMonitor
    let epoch: TimeInterval

    static func elapsed(since epoch: TimeInterval, now: Date) -> String {
        guard epoch > 0 else { return "—" }
        let s = max(0, Int(now.timeIntervalSince1970 - epoch))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private var worst: HealthMonitor.Health {
        let all = state.targets.compactMap { health.status[$0.name] }
        if all.contains(.failing) { return .failing }
        if all.contains(.starting) || all.isEmpty { return .starting }
        return all.allSatisfy { $0 == .healthy } ? .healthy : .starting
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(worst.color)
                .frame(width: 8, height: 8)
                .shadow(color: worst.color.opacity(0.7), radius: 3)

            Text(worst.label.capitalized)
                .font(.system(size: 13, weight: .medium))

            // Which kind of run this is, because the two behave differently in
            // the way that matters: a worktree run is a snapshot and will not
            // see your edits, an in-place run is your checkout and will.
            if state.adopted {
                Badge(text: "started elsewhere", symbol: "arrow.up.right.square",
                      color: .orange)
                    .help("Already running when Runbranch looked — not started by it")
            } else if state.inPlace {
                Badge(text: "in place", symbol: "pencil", color: .orange)
                    .help("Running your checkout — edits and uncommitted work are live")
            }

            // TimelineView keeps the tick inside this label. Driving it from
            // ContentView re-rendered the whole detail every second, which
            // rebuilt the toolbar menus and dismissed any open submenu.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.elapsed(since: epoch, now: ctx.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // A label, not a button: Open already opens it, and two ways to do
            // one thing is worse than one obvious way.
            ForEach(state.targets) { t in
                Text("localhost:\(String(t.port))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(t.name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct BranchRow: View {
    let branch: Branch
    let isLive: Bool
    /// Reserve the leading slot whenever ANY demo is up, so branch names stay
    /// on one vertical line instead of the live row shunting itself sideways.
    let showGutter: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showGutter {
                ZStack {
                    if isLive { ProgressView().controlSize(.small) }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if branch.isRemote {
                        Image(systemName: "cloud")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                        : AnyShapeStyle(.tertiary))
                            .help("Remote branch — selecting it builds a worktree at its tip")
                    }
                    Text(branch.display)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if branch.isDefault {
                        // Not .accentColor. A selected row is filled with the
                        // accent, so a badge tinted with it disappears — and
                        // that holds whatever the user has set the accent to.
                        Badge(text: "default", color: Badge.trunk)
                    } else if let l = branch.pr.label {
                        Badge(text: l, symbol: branch.pr.symbol, color: branch.pr.color)
                    }
                    Badge(text: branch.owner)
                    // What is actually being worked on. This is the branch your
                    // checkout is sitting on, so it is the one whose edits are
                    // live on disk — and the only one that can be run in place.
                    if branch.isCurrent {
                        Badge(text: "checked out", symbol: "pencil",
                              color: .orange)
                    } else if !branch.checkedOutAt.isEmpty {
                        Badge(text: "in another worktree", symbol: "arrow.triangle.branch",
                              color: .purple)
                    }
                    if !isLive && branch.ready {
                        Badge(text: "ready", symbol: "bolt.fill", color: .green)
                    }
                }

                // What the work actually is. A branch name is what someone
                // called it; this is what it does.
                if !branch.subject.isEmpty {
                    Text(branch.subject)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Text(branch.age)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
        .padding(.vertical, 3)
    }
}

/// A searchable grid of symbols, the way the SF Symbols picker works: icons
/// only, no names. A `Picker` listing names was unreadable — you scan icons by
/// shape, and the label just gets in the way.
///
/// The list is curated rather than exhaustive. There is no public API to
/// enumerate SF Symbols, and a few hundred relevant ones beat ten thousand
/// unsearchable ones.
struct SymbolPicker: View {
    @Binding var selection: String
    @State private var query = ""
    @State private var open = false

    private static let all: [String] = [
        // projects and things
        "shippingbox", "cube", "cube.transparent", "square.stack.3d.up", "square.stack",
        "folder", "folder.badge.gearshape", "tray.full", "archivebox", "briefcase",
        // web and network
        "globe", "globe.americas", "network", "antenna.radiowaves.left.and.right",
        "wifi", "link", "cloud", "icloud", "point.3.connected.trianglepath.dotted",
        // servers and data
        "server.rack", "externaldrive", "internaldrive", "cylinder.split.1x2",
        "chart.bar.doc.horizontal", "tablecells", "list.bullet.rectangle",
        // building and business
        "building.2", "building.columns", "storefront", "cart", "creditcard",
        "banknote", "chart.line.uptrend.xyaxis", "chart.pie", "percent",
        // design
        "paintpalette", "paintbrush", "swatchpalette", "eyedropper", "ruler",
        "square.on.circle", "circle.hexagongrid", "wand.and.stars", "sparkles",
        // code and tools
        "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right",
        "hammer", "wrench.and.screwdriver", "gearshape.2", "cpu", "memorychip",
        "ladybug", "testtube.2", "flask",
        // documents and writing
        "doc.text", "doc.richtext", "book", "books.vertical", "text.book.closed",
        "newspaper", "pencil.and.outline", "signature",
        // communication
        "envelope", "bubble.left.and.bubble.right", "megaphone", "bell",
        "phone", "video", "person.2", "person.3",
        // media
        "photo", "photo.stack", "film", "music.note", "waveform", "mic",
        "play.rectangle", "camera",
        // navigation and places
        "map", "location", "signpost.right", "airplane", "car", "tram",
        // nature and misc
        "leaf", "tree", "flame", "drop", "bolt", "sun.max", "moon.stars",
        "star", "heart", "flag", "tag", "bookmark", "pin", "key", "lock",
        "shield", "checkmark.seal", "target", "scope", "puzzlepiece",
        "gamecontroller", "dice", "crown", "gift", "cup.and.saucer", "fork.knife",
    ]

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.all }
        return Self.all.filter { $0.contains(q) }
    }

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.isEmpty ? "shippingbox" : selection)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .padding(10)

                Divider()

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4),
                                             count: 8), spacing: 4) {
                        ForEach(matches, id: \.self) { name in
                            Button {
                                selection = name
                                open = false
                                query = ""
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 15))
                                    .frame(width: 34, height: 30)
                                    .background(name == selection
                                                ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                                : AnyShapeStyle(.clear),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(name)      // the name is there if you want it
                        }
                    }
                    .padding(10)
                }
                .frame(height: 240)

                if matches.isEmpty {
                    Text("Nothing matches “\(query)”")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
            }
            .frame(width: 330)
        }
    }
}

/// Shown when no projects are declared. The alternative was an empty sidebar
/// beside an empty pane, which tells a first-time user nothing at all.
/// The bare glyph on transparency, not the app icon. Inside the app the
/// rounded tile is redundant — the window already is the app — and the tile's
/// light background sits badly on a dark splash.
enum Mark {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Mark", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

struct WelcomeView: View {
    let onScan: () -> Void
    let onAdd: () -> Void

    /// Both buttons get the same width so neither looks like the runt. Sizing
    /// to the longer label and letting the shorter one match is the usual fix.
    private let buttonWidth: CGFloat = 124

    var body: some View {
        VStack(spacing: 0) {
            if let mark = Mark.image {
                Image(nsImage: mark)
                    .resizable().frame(width: 84, height: 84)
                    .padding(.bottom, 16)
            }
            Text("Runbranch").font(.system(size: 24, weight: .semibold))
            Text("Run any branch of any project, on a real port.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("Isolated in a throwaway worktree, or in place in your checkout.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            HStack(spacing: 10) {
                Button(action: onScan) {
                    Text("Scan…").frame(width: buttonWidth)
                }
                .buttonStyle(.glassProminent)
                Button(action: onAdd) {
                    Text("Add a project…").frame(width: buttonWidth)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 24)

            Text("Projects are plain config files you can commit to the repository.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.top, 22)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Sets the window's content size when the app crosses between onboarding and
/// the browser. Onboarding needs a fraction of the room the branch list does,
/// and a splash floating in a half-empty 1000pt window reads as a bug.
///
/// Only acts on a transition, so a window the user has resized by hand is left
/// alone until the mode actually changes.
struct WindowSizer: NSViewRepresentable {
    let compact: Bool
    static let compactSize = NSSize(width: 520, height: 400)
    static let fullSize = NSSize(width: 1000, height: 720)

    final class Coordinator { var applied: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.applied != compact else { return }
        context.coordinator.applied = compact
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let size = compact ? Self.compactSize : Self.fullSize
            window.setContentSize(size)
            window.styleMask = compact
                ? window.styleMask.subtracting(.resizable)
                : window.styleMask.union(.resizable)
            window.center()
        }
    }
}

struct ProjectRow: View {
    let project: Project
    let isLive: Bool
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : (isLive ? .green : .secondary))
                .frame(width: 16)
            Text(project.name).font(.system(size: 13))
            Spacer(minLength: 0)
            if isLive {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            }
        }
    }
}
