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

// Noticing a new release, installing it, and saying what changed.

import SwiftUI
import AppKit
import CryptoKit

// MARK: - Versions

/// A dotted version, compared by number rather than by string.
///
/// String comparison gets "1.10.0" < "1.9.0" wrong, which is exactly the
/// comparison this app will start making around its tenth minor release.
struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]
    let description: String

    /// Accepts a tag or a bundle version: a leading `v` is dropped, and a
    /// non-numeric suffix ends the parse rather than failing it, so a
    /// `1.3.0-beta2` tag reads as 1.3.0 instead of as nothing at all.
    init?(_ raw: String) {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        var out: [Int] = []
        for piece in text.split(separator: ".") {
            let digits = piece.prefix { $0.isNumber }
            guard let n = Int(digits) else { break }
            out.append(n)
        }
        guard !out.isEmpty else { return nil }
        parts = out
        description = text
    }

    /// Missing components read as zero, so 1.3 and 1.3.0 are the same version
    /// rather than the shorter one being smaller.
    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    static var installed: Version {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return Version(s ?? "0") ?? Version("0")!
    }
}

/// Which build this is.
///
/// `make-app.sh` writes RBBuildChannel only for a development build, so the
/// absence of the key is a release. Read rather than compiled in, because the
/// same sources produce both and a #if would need two build configurations to
/// tell them apart.
enum Build {
    static var isDevelopment: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RBBuildChannel") as? String == "development"
    }
}

// MARK: - What GitHub says

/// One release, reduced to the parts an update needs.
struct Release {
    let version: Version
    let notes: String
    let dmg: URL
    let bytes: Int
    /// Lowercase hex, from the `digest` GitHub publishes alongside the asset.
    /// Nil when the API does not carry one — older releases predate the field.
    let sha256: String?
}

private struct APIRelease: Decodable {
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [APIAsset]
}

private struct APIAsset: Decodable {
    let name: String
    let size: Int
    let digest: String?
    let browser_download_url: URL
}

// MARK: - The updater

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Whether to look on launch. On by default — an update nobody hears about
    /// is not an update — and turned off from the sheet or the ••• menu.
    static let checkKey = "updates.check"
    /// The version whose changelog has been shown. Empty on a fresh install,
    /// which is the case that must NOT produce a "what's new" sheet.
    static let seenKey = "updates.lastSeenVersion"

    enum Phase: Equatable {
        case idle
        case checking
        /// 0...1, or nil while the server has not said how big the file is.
        case downloading(Double?)
        case verifying
        case installing
        case upToDate
        /// Asked on a build that must not update itself.
        case development
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    /// Set when the user asked, so "you are up to date" is reported rather
    /// than passed over in silence the way the launch check does.
    @Published private(set) var manual = false

    private var checked = false

    private static let latest = URL(
        string: "https://api.github.com/repos/aosmcleod/runbranch/releases/latest")!
    static let releasesPage = URL(
        string: "https://github.com/aosmcleod/runbranch/releases/latest")!

    private init() {}

    // MARK: Checking

    /// The launch check. Silent about everything: no network, a rate limit, a
    /// release with no disk image — none of that is the user's problem, and
    /// none of it should raise a sheet in front of an app they just opened.
    func checkOnLaunch() async {
        // A development build must never offer to replace itself with a
        // release: the whole point of the one in the dev folder is that it is
        // the build you are working on, and an update would silently throw it
        // away for whatever was last tagged.
        guard !Build.isDevelopment else { return }
        guard !checked else { return }
        guard UserDefaults.standard.object(forKey: Self.checkKey) as? Bool ?? true else { return }
        checked = true
        guard let release = try? await fetch() else { return }
        guard release.version > Version.installed else { return }
        available = release
    }

    /// The menu check, which reports either way.
    func checkNow() async {
        checked = true
        manual = true
        // Said rather than silently skipped. Picking the menu item and having
        // nothing happen at all reads as a broken menu item.
        guard !Build.isDevelopment else {
            available = nil
            phase = .development
            return
        }
        phase = .checking
        do {
            let release = try await fetch()
            if release.version > Version.installed {
                available = release
                phase = .idle
            } else {
                available = nil
                phase = .upToDate
            }
        } catch {
            available = nil
            phase = .failed(readable(error))
        }
    }

    private func fetch() async throws -> Release {
        var request = URLRequest(url: Self.latest)
        // Unauthenticated is 60 requests an hour per address. One per launch is
        // nothing, but the header is what GitHub asks for and it makes the
        // traffic identifiable if it ever does need explaining.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Runbranch/\(Version.installed)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // The API caches aggressively at the edge; a stale hit would report an
        // old version as the newest one for as long as it lived.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure("GitHub answered \(code).")
        }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        guard !api.draft, !api.prerelease else { throw Failure("The latest release is not public.") }
        guard let version = Version(api.tag_name) else {
            throw Failure("Could not read a version from the tag \(api.tag_name).")
        }
        // By name, not by position: releases carry other assets over time, and
        // picking assets[0] would eventually download the wrong one.
        guard let asset = api.assets.first(where: {
            $0.name == "Runbranch-\(version).dmg"
        }) else {
            throw Failure("Release \(version) has no disk image attached.")
        }
        return Release(
            version: version,
            notes: api.body ?? "",
            dmg: asset.browser_download_url,
            bytes: asset.size,
            sha256: asset.digest.flatMap { d in
                d.hasPrefix("sha256:") ? String(d.dropFirst(7)).lowercased() : nil
            })
    }

    // MARK: Can we even install?

    /// Why an in-place update is impossible here, or nil when it is fine.
    ///
    /// Both cases below fail in a way that looks like a bug in the updater
    /// rather than a fact about where the app is, so they are worth naming
    /// before the download rather than after it.
    static var blocker: String? {
        let path = Bundle.main.bundlePath
        // Gatekeeper runs a quarantined app from a randomised read-only image
        // rather than from where it appears to be. Nothing can write there,
        // including the app itself.
        if path.contains("/AppTranslocation/") {
            return "Runbranch is running from a temporary read-only copy. "
                 + "Move it to your Applications folder and open it from there."
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "Runbranch is in \(parent), which this account cannot write to."
        }
        return nil
    }

    // MARK: Installing

    func install(_ release: Release) async {
        if let why = Self.blocker { phase = .failed(why); return }

        let temp: URL
        do {
            phase = .downloading(nil)
            temp = try await download(release)
        } catch {
            phase = .failed(readable(error)); return
        }

        do {
            phase = .verifying
            try verify(temp, against: release)
            phase = .installing
            try handOff(temp, release)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            phase = .failed(readable(error))
            return
        }

        // handOff succeeded, so a detached script is now waiting for this
        // process to go away before it swaps the bundle. Anything that keeps
        // us alive keeps the old version installed.
        //
        // terminate() is a request, not an exit, and with the update sheet up
        // AppKit did not act on it at all: the script sat out its full ten
        // second patience and then had to kill the process, so every update
        // took ten seconds of the app being gone from the screen for no
        // reason. Ask nicely, then leave.
        UserDefaults.standard.synchronize()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    private func download(_ release: Release) async throws -> URL {
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.phase { self.phase = .downloading(fraction) }
            }
        }
        let session = URLSession(configuration: .default, delegate: progress, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // A URLSession download is not quarantined — that flag is attached by
        // whatever does the downloading, and browsers opt in where we do not.
        // It is the reason an update installed this way opens without the
        // right-click that a hand-downloaded image still needs.
        //
        // The completion-handler form rather than the async one: with a
        // completion handler URLSession does not call the delegate's
        // didFinishDownloadingTo, so there is no argument about which of the
        // two takes delivery of the file, and didWriteData still arrives.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: release.dmg) { file, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(throwing: Failure("The download failed with \(code)."))
                    return
                }
                guard let file else {
                    continuation.resume(throwing: Failure("The download produced no file."))
                    return
                }
                // URLSession deletes its temporary file as soon as this closure
                // returns, so it has to be moved now rather than later.
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Runbranch-\(release.version).dmg")
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: file, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    /// Checks the bytes against the hash GitHub publishes.
    ///
    /// Not a signature: it proves the file is the one the release page lists,
    /// not that the release page is honest. That second guarantee needs a
    /// Developer ID, which this build does not have. What it does catch is a
    /// truncated or corrupted download, which is the failure that actually
    /// happens, and it catches it before anything is replaced.
    private func verify(_ file: URL, against release: Release) throws {
        guard let expected = release.sha256 else { return }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw Failure("The download does not match the checksum GitHub published for it.")
        }
    }

    /// Mounts, checks what is on the image, and starts the swap script.
    private func handOff(_ dmg: URL, _ release: Release) throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("runbranch-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-mountpoint", mount.path,
                          "-nobrowse", "-readonly", "-quiet"])
        guard attach == 0 else { throw Failure("The disk image would not mount.") }

        do {
            let new = mount.appendingPathComponent("Runbranch.app")
            // Everything below happens while the installed copy is still
            // untouched. Once the script starts there is no cheap way back, so
            // this is the last chance to find out the image is not what it said.
            guard let bundle = Bundle(url: new) else {
                throw Failure("The disk image does not contain Runbranch.app.")
            }
            guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw Failure("The app on the disk image is not Runbranch.")
            }
            let onImage = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard let onImage, Version(onImage) == release.version else {
                throw Failure("The disk image holds \(onImage ?? "an unknown version"), "
                            + "not \(release.version).")
            }

            // Out of the bundle before running it: the script's own copy is
            // inside the app that is about to be deleted, and a running script
            // whose file is pulled out from under it is not something to rely on.
            guard let source = Bundle.main.url(forResource: "install-update",
                                               withExtension: "sh") else {
                throw Failure("This build has no installer script; download the update instead.")
            }
            let script = FileManager.default.temporaryDirectory
                .appendingPathComponent("runbranch-install-\(UUID().uuidString).sh")
            try FileManager.default.copyItem(at: source, to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [script.path,
                              String(ProcessInfo.processInfo.processIdentifier),
                              new.path,
                              Bundle.main.bundlePath,
                              mount.path,
                              dmg.path]
            try task.run()
            // Deliberately not waited on, and deliberately still mounted: the
            // script owns the image from here, and detaching it now would pull
            // the new app out from under the copy it is about to make.
        } catch {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw error
        }
    }

    // MARK: Preferences

    /// Puts a release on the sheet without a check having found one.
    ///
    /// For the screenshot pipeline, which has to photograph the update sheet
    /// on a machine where the installed version IS the latest release. Nothing
    /// on the normal path calls it.
    func offer(_ release: Release) { available = release }

    func turnOffChecks() {
        UserDefaults.standard.set(false, forKey: Self.checkKey)
        dismiss()
    }

    func dismiss() {
        available = nil
        phase = .idle
        manual = false
    }

    // MARK: Odds and ends

    private struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    private func readable(_ error: Error) -> String {
        if let f = error as? Failure { return f.text }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No network connection."
            case .timedOut:
                return "GitHub did not answer in time."
            default:
                return url.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Progress for a download, which URLSession only reports through a delegate.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: (Double?) -> Void
    init(_ report: @escaping (Double?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        // -1 when the server sends no length, which is a real case and must
        // show as an indeterminate bar rather than as a bar stuck at zero.
        guard expected > 0 else { report(nil); return }
        report(Double(totalBytesWritten) / Double(expected))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The async download(from:) call takes delivery; nothing to do here,
        // but URLSession requires the method to exist.
    }
}

extension Release {
    /// Stand-in content for the screenshot pipeline. Deliberately a version
    /// that will not exist for a while, so a real release cannot make the
    /// picture stale.
    static var sample: Release {
        Release(
            version: Version("9.0.0")!,
            notes: ReleaseNotes.all.first?.notes ?? "",
            dmg: URL(string: "https://example.invalid/Runbranch-9.0.0.dmg")!,
            bytes: 2_400_000,
            sha256: nil)
    }
}

// MARK: - What changed

/// The changelog, as shipped inside the bundle.
///
/// Bundled rather than fetched: it has to work on a laptop with no network,
/// and it has to work for someone who built the app from source and has no
/// release to read notes off. `make-app.sh` writes it out of CHANGELOG.md, so
/// there is still only one copy to keep current.
enum ReleaseNotes {
    struct Entry: Decodable, Identifiable {
        let version: String
        let notes: String
        var id: String { version }
        var parsed: Version? { Version(version) }
    }

    static let all: [Entry] = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }()

    /// Everything released after `seen`, newest first. Not just the newest
    /// entry: someone who skips two releases should see both, or the sheet
    /// quietly hides half of what changed under them.
    static func since(_ seen: Version) -> [Entry] {
        all.filter { entry in
            guard let v = entry.parsed else { return false }
            return v > seen && v <= Version.installed
        }
    }
}

// MARK: - Rendering the notes

/// Changelog prose, drawn rather than dumped.
///
/// A `Text` holding the raw markdown shows the asterisks and runs the bullets
/// together, and a full markdown renderer is a dependency for four constructs.
/// This handles the four the changelog actually uses — a bold lead line, a
/// bullet, a paragraph, a GitHub alert block — and passes inline `**bold**`
/// and backticks to AttributedString, which does understand those.
struct NotesText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .gap:
                    Color.clear.frame(height: 8)
                case .heading(let s):
                    Text(Self.inline(s))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 4).padding(.bottom, 3)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Text(Self.inline(s))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 3)
                case .body(let s):
                    Text(Self.inline(s))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Line {
        case gap
        case heading(String)
        case bullet(String)
        case body(String)
    }

    /// Paragraphs are rewrapped rather than kept as written: the changelog is
    /// hard-wrapped at 78 columns for reading in a terminal, and honouring
    /// those breaks in a 480pt sheet puts them in the wrong places entirely.
    private var lines: [Line] {
        var out: [Line] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            out.append(.body(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // GitHub alert syntax. The marker is chrome; the prose inside it
            // is the point, and the release bodies use it for the Gatekeeper
            // note that every reader of this sheet has already dealt with.
            if line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[!") { continue }
            }
            if line.isEmpty {
                flush()
                if case .gap = out.last { } else if !out.isEmpty { out.append(.gap) }
                continue
            }
            // A version heading inside a section body, which happens in a
            // release note pasted from the changelog.
            if line.hasPrefix("#") {
                flush()
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            // A lead line like **Two projects that want the same port** — bold
            // for its whole length and nothing else on the line.
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4,
               !line.dropFirst(2).dropLast(2).contains("**") {
                flush()
                out.append(.heading(String(line.dropFirst(2).dropLast(2))))
                continue
            }
            // A bullet's continuation line, indented in the source. It has
            // already been trimmed, so append it to the bullet rather than
            // starting a paragraph that will render at the wrong indent.
            if raw.hasPrefix("  "), case .bullet(let prev)? = out.last, paragraph.isEmpty {
                out[out.count - 1] = .bullet(prev + " " + line)
                continue
            }
            paragraph.append(line)
        }
        flush()
        if case .gap = out.last { out.removeLast() }
        return out
    }

    /// `**bold**` and `` `code` `` only. Block syntax has already been taken
    /// off by the time anything gets here.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - The sheets

/// Offered when there is a newer release, and the place the whole install
/// happens: progress, failure and the way out all stay on this one sheet.
struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    let onClose: () -> Void

    private var release: Release? { updater.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: release == nil ? 260 : 440)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let mark = Mark.image {
                Image(nsImage: mark).resizable().frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var title: String {
        if let release { return "Runbranch \(release.version) is available" }
        if case .failed = updater.phase { return "Could not check for updates" }
        if case .development = updater.phase { return "This is a development build" }
        return "Runbranch is up to date"
    }

    private var subtitle: String {
        if release != nil { return "You have \(Version.installed)" }
        if case .failed(let why) = updater.phase { return why }
        if case .development = updater.phase {
            return "Built from source as \(Version.installed)"
        }
        return "Version \(Version.installed), the latest release"
    }

    @ViewBuilder
    private var content: some View {
        if let release {
            ScrollView {
                NotesText(text: release.notes)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(statusLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusSymbol: String {
        if case .failed = updater.phase { return "wifi.exclamationmark" }
        if case .development = updater.phase { return "hammer" }
        return "checkmark.circle"
    }

    private var statusLine: String {
        if case .failed = updater.phase {
            return "Releases are listed on GitHub if you would rather look yourself."
        }
        if case .development = updater.phase {
            return "It does not update itself, because an update would replace "
                 + "the build you are working on with whatever was last released."
        }
        return "Nothing to install."
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .downloading(let fraction):
                progress(fraction, "Downloading \(release.map { "\($0.version)" } ?? "")…")
            case .verifying:
                progress(nil, "Checking the download…")
            case .installing:
                progress(nil, "Installing. Runbranch will restart on its own.")
            case .failed(let why):
                Text(why)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open Releases") { NSWorkspace.shared.open(Updater.releasesPage) }
                    .controlSize(.large)
                Button("Close", action: onClose)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            default:
                if release != nil {
                    // Plain and on the left, because it is the one action here
                    // nobody is looking for and it should not compete with the
                    // two that they are.
                    Button("Turn Off Update Checks") { updater.turnOffChecks() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let release {
                    Button("Later", action: onClose).controlSize(.large)
                    Button("Update") { Task { await updater.install(release) } }
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onClose)
                        .buttonStyle(.glassProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder
    private func progress(_ fraction: Double?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fraction {
                ProgressView(value: fraction).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown once, on the first launch after the version changes.
struct WhatsNewSheet: View {
    let entries: [ReleaseNotes.Entry]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let mark = Mark.image {
                    Image(nsImage: mark).resizable().frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in Runbranch \(Version.installed.description)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        // The version only earns a line of its own when there
                        // is more than one, which is the skipped-a-release case.
                        if entries.count > 1 {
                            Text(entry.version)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, entry.id == entries.first?.id ? 0 : 14)
                                .padding(.bottom, 4)
                        }
                        NotesText(text: entry.notes)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }

            Divider()

            HStack {
                Link("Full changelog", destination: Updater.releasesPage)
                    .font(.system(size: 11))
                Spacer()
                Button("Continue", action: onClose)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 520, height: 440)
    }

    private var subtitle: String {
        entries.count > 1 ? "\(entries.count) releases since you last opened it"
                          : "Updated from within Runbranch"
    }
}
