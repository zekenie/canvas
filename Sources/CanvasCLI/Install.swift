import CanvasRPC
import Darwin
import Foundation

/// `canvas install`: puts what an agent needs to use `canvas` where it looks, from the folder the app
/// carries for agents (`Contents/Resources/agents`): the skills, copied into the folder agents that
/// read Agent Skills share (`~/.agents/skills`); the same folder as a Claude Code plugin, when
/// `claude` is there to install it; and `canvas` itself, linked into a folder on the PATH. It never
/// asks the app, so it works before the app has ever run, and it does only what it can undo by running
/// again: it replaces a copy of a skill it made (the folder has `Install.markerName` in it) and a link
/// to the `canvas` of an app of this one's identifier, and says, and leaves alone, anything else in the way.
struct Install {
    /// In every folder `canvas install` copies a skill to, saying which build the copy is from. A folder
    /// without it isn't one `canvas install` made.
    static let markerName = ".canvas-install"
    /// The plugin marketplace the agents folder is, and its plugin: `claude plugin install canvas@infinite-canvas`.
    static let marketplace = "infinite-canvas"
    static let plugin = "canvas"
    /// Where the skills go (relative to the home folder) when `--to` doesn't say: the folder agents that
    /// follow the Agent Skills standard (agentskills.io) share by convention.
    static let skillsFolder = ".agents/skills"
    /// Where `canvas` is linked (relative to the home folder, else absolute), in the order tried, when
    /// `--bin` doesn't say: the first that is a folder, on the PATH and writable.
    static let binFolders = [".local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    /// The identifier of the app (build.sh's `APP_BASE_ID`), and of a worktree's copy of it (that, `.worktree.` and the worktree's name).
    static let appIdentifier = "com.example.InfiniteCanvas"
    /// How long a `claude` command may take, in seconds, unless `CANVAS_INSTALL_CLAUDE_TIMEOUT` says (a test's).
    static let claudeTimeout = 60.0
    /// Where mounted volumes (disk images among them) are, unless `CANVAS_INSTALL_VOLUMES` says (a test's).
    static let volumesFolder = "/Volumes"

    struct Options: Equatable {
        var to: String?
        var bin: String?
        var from: String?
        var claude = true

        /// The arguments after `install`.
        init(_ words: [String]) throws(ArgumentError) {
            var index = 0
            func value(of option: String, inline: String?) throws(ArgumentError) -> String {
                let text: String
                if let inline {
                    text = inline
                } else {
                    guard index < words.count else { throw ArgumentError("--\(option) needs a folder") }
                    text = words[index]
                    index += 1
                }
                guard !text.isEmpty, !text.hasPrefix("-") else {
                    throw ArgumentError("--\(option) needs a folder, not \(text.isEmpty ? "an empty value" : text)",
                                        hint: text.isEmpty ? nil : "A folder whose name starts with - is given as ./\(text).")
                }
                return text
            }
            while index < words.count {
                let word = words[index]
                index += 1
                let equals = word.hasPrefix("--") ? word.firstIndex(of: "=") : nil
                let name = equals.map { String(word[..<$0]) } ?? word
                let inline = equals.map { String(word[word.index(after: $0)...]) }
                switch name {
                case "--to": to = try value(of: "to", inline: inline)
                case "--bin": bin = try value(of: "bin", inline: inline)
                case "--from": from = try value(of: "from", inline: inline)
                case "--no-claude": claude = false
                default:
                    throw ArgumentError("install has no \(word.hasPrefix("-") ? "option" : "argument") \(word)",
                                        hint: "`\(RPC.commandName) help install` says what it takes.")
                }
            }
        }
    }

    enum Did: String {
        /// `warning`: it didn't work, and what matters didn't depend on it: not a failure.
        case done, unchanged, skipped, warning, refused, failed
    }

    /// One thing it did, or didn't: what a line of its output says.
    struct Step: Equatable {
        let name: String
        let did: Did
        let message: String

        var isFailure: Bool { did == .failed || did == .refused }
    }

    struct Report {
        /// The build the skills it installed are from, as the folder says.
        let build: String?
        let steps: [Step]

        var succeeded: Bool { !steps.contains(where: \.isFailure) }
    }

    let options: Options
    let environment: [String: String]
    /// This `canvas`, with its links resolved: what `canvas` is linked to, and where the app's folder of
    /// skills is when `--from` doesn't say.
    let executable: URL
    private let fileManager = FileManager.default

    init(options: Options, environment: [String: String], executable: URL) {
        self.options = options
        self.environment = environment
        self.executable = executable.resolvingSymlinksInPath()
    }

    /// The folder of the volume `url` is on, when that is one of the mounted volumes (`/Volumes/<name>`), its links resolved (the volume
    /// the system is on is a link to `/`).
    private func volume(of url: URL) -> String? {
        let volumes = URL(fileURLWithPath: environment["CANVAS_INSTALL_VOLUMES"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.volumesFolder, isDirectory: true).resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(volumes + "/") else { return nil }
        let name = path.dropFirst(volumes.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return volumes + "/" + name
    }

    private var timeout: TimeInterval {
        environment["CANVAS_INSTALL_CLAUDE_TIMEOUT"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? Self.claudeTimeout
    }

    private var home: String { environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() }

    func run() -> Report {
        guard let source = agentsFolder() else {
            let hint = options.from == nil ? " (a \(RPC.commandName) outside the app has none: --from DIR takes them from a folder laid out like the app's Contents/Resources/agents)" : ""
            let place = options.from.map { Invocation.absolute($0) } ?? executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/agents").path
            return Report(build: nil, steps: [Step(name: "skills", did: .failed, message: "no skills at \(place)\(hint)")])
        }
        let build = (try? String(contentsOf: source.appendingPathComponent("build-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        var steps: [Step] = []
        if let volume = volume(of: source) {
            steps.append(Step(name: "disk image", did: .warning,
                              message: "warning: the app is on a mounted volume (\(volume)), probably a disk image: the link and the Claude Code plugin point into it and break when it is ejected. Move the app to Applications, and run \(RPC.commandName) \(RPC.installCommand) from there"))
        }
        steps += copySkills(from: source, build: build ?? "unknown")
        if options.claude {
            steps += claude(marketplace: source)
        } else {
            steps.append(Step(name: "claude", did: .skipped, message: "--no-claude: the plugin isn't installed for Claude Code"))
        }
        steps.append(linkCanvas())
        return Report(build: build, steps: steps)
    }

    // MARK: Where the skills are

    /// The folder to take the skills from: `--from`, else the app's that this `canvas` is in. Nil if it isn't one.
    private func agentsFolder() -> URL? {
        let folder: URL
        if let from = options.from {
            folder = URL(fileURLWithPath: Invocation.absolute(from), isDirectory: true)
        } else {
            let helpers = executable.deletingLastPathComponent()
            guard helpers.lastPathComponent == "Helpers", helpers.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
            folder = helpers.deletingLastPathComponent().appendingPathComponent("Resources/agents", isDirectory: true)
        }
        return isDirectory(folder.appendingPathComponent("\(Self.plugin)/skills")) ? folder : nil
    }

    private func skills(in agents: URL) -> [String] {
        let folder = agents.appendingPathComponent("\(Self.plugin)/skills")
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && fileManager.fileExists(atPath: folder.appendingPathComponent("\($0)/SKILL.md").path) }.sorted()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What is at `url`, as `lstat` sees it (a link is a link, even a broken one).
    private func kind(of url: URL) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    // MARK: Copying the skills

    private func copySkills(from agents: URL, build: String) -> [Step] {
        let names = skills(in: agents)
        let destination = URL(fileURLWithPath: options.to.map { Invocation.absolute($0) } ?? (home as NSString).appendingPathComponent(Self.skillsFolder), isDirectory: true)
        guard !names.isEmpty else {
            return [Step(name: "skills", did: .failed, message: "\(agents.appendingPathComponent("\(Self.plugin)/skills").path) has no skill in it")]
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return [Step(name: "skills", did: .failed, message: "can't make \(destination.path): \(error.localizedDescription)")]
        }
        clearStaging(in: destination)
        return names.map { name in
            let step = "skill \(name)"
            let source = agents.appendingPathComponent("\(Self.plugin)/skills/\(name)")
            // The marker is written into the copy, and a copy of a link is a link: it would be written into what the link points to.
            guard kind(of: source) != .typeSymbolicLink else {
                return Step(name: step, did: .refused, message: "\(source.path) is a symbolic link, and canvas install copies folders, not what a link points to: it is not installed; make it a folder")
            }
            let target = destination.appendingPathComponent(name, isDirectory: true)
            let old = kind(of: target)
            var replacing = false
            if let old {
                let ours = old == .typeDirectory && fileManager.fileExists(atPath: target.appendingPathComponent(Self.markerName).path)
                guard ours else {
                    return Step(name: step, did: .refused, message: "\(target.path) is there and canvas install didn't make it, so it's left as it is: move it away, or --to DIR puts the skills somewhere else")
                }
                replacing = true
            }
            let staging = destination.appendingPathComponent(".\(name)\(Self.stagingSuffix)", isDirectory: true)
            do {
                forceRemove(staging)
                try fileManager.copyItem(at: source, to: staging)
                // The copy has the source's modes, and a source in a read-only place has none to write with.
                try makeWritable(staging)
                let marker = "build: \(build)\nfrom: \(agents.path)\nmade by `\(RPC.commandName) \(RPC.installCommand)`; a folder without this file is not touched by it\n"
                try marker.write(to: staging.appendingPathComponent(Self.markerName), atomically: true, encoding: .utf8)
                if replacing {
                    // One swap: the skill is the old copy or the new, never none.
                    _ = try fileManager.replaceItemAt(target, withItemAt: staging, options: .usingNewMetadataOnly)
                } else {
                    try fileManager.moveItem(at: staging, to: target)
                }
            } catch {
                forceRemove(staging)
                return Step(name: step, did: .failed, message: "can't copy \(name) to \(target.path): \(error.localizedDescription)")
            }
            return Step(name: step, did: .done, message: "\(replacing ? "replaced" : "installed") \(name) in \(target.path) (build \(build))")
        }
    }

    /// What a folder being made is called while it is, and an old one while it is swapped out.
    private static let stagingSuffix = ".canvas-install-new"

    /// Removes the staging folders an earlier run left (it was stopped, or couldn't clean up).
    private func clearStaging(in folder: URL) {
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(Self.stagingSuffix) {
            forceRemove(folder.appendingPathComponent(name))
        }
    }

    /// Gives its owner the right to write to everything under `url` (links aren't followed).
    private func makeWritable(_ url: URL) throws {
        guard let type = kind(of: url), type == .typeDirectory || type == .typeRegular else { return }
        let modes = (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        try fileManager.setAttributes([.posixPermissions: modes | (type == .typeDirectory ? 0o700 : 0o600)], ofItemAtPath: url.path)
        if type == .typeDirectory {
            for child in try fileManager.contentsOfDirectory(atPath: url.path) { try makeWritable(url.appendingPathComponent(child)) }
        }
    }

    /// Removes what is at `url`, whatever its modes.
    private func forceRemove(_ url: URL) {
        guard kind(of: url) != nil else { return }
        try? makeWritable(url)
        try? fileManager.removeItem(at: url)
    }

    // MARK: Claude Code

    /// Claude Code is pointed at this app's folder as the marketplace, and the plugin is installed and brought up to date. Claude Code
    /// may keep a copy of a plugin in a cache of its own named by the plugin's version (build.sh writes the build id as the version,
    /// so each build is another version), and installing what is installed already is a success that changes nothing: so after the
    /// add, the marketplace is refreshed from its folder and the plugin updated, every time.
    private func claude(marketplace agents: URL) -> [Step] {
        let id = "\(Self.plugin)@\(Self.marketplace)"
        let add = ["plugin", "marketplace", "add", agents.path]
        let remove = ["plugin", "marketplace", "remove", Self.marketplace]
        let install = ["plugin", "install", id]
        guard isRegularFile(agents.appendingPathComponent(".claude-plugin/marketplace.json")) else {
            return [Step(name: "claude", did: .skipped, message: "\(agents.path) is no plugin marketplace (no .claude-plugin/marketplace.json), so nothing is installed for Claude Code")]
        }
        guard let claude = which("claude") else {
            return [Step(name: "claude", did: .skipped,
                         message: "claude isn't on your PATH. For Claude Code, run: claude \(add.map(shellQuoted).joined(separator: " ")) && claude \(install.joined(separator: " "))")]
        }
        // The marketplace's name is taken by whatever was added under it last: another app's folder (a worktree's build, or the main
        // one) is a different set of skills. canvas install means this app's, so that registration goes, and this folder takes the name.
        let listed = launch(claude, ["plugin", "marketplace", "list", "--json"])
        let here = listed.output.contains(agents.path) || listed.output.contains(agents.path.replacingOccurrences(of: "/", with: "\\/"))
        var repointed = listed.status == 0 && listed.output.contains(Self.marketplace) && !here
        if repointed { _ = launch(claude, remove) }
        var added = launch(claude, add)
        if added.status != 0 && !repointed {
            // The list may not have shown a registration that is in the way; clearing it is the same.
            if launch(claude, remove).status == 0 {
                added = launch(claude, add)
                repointed = added.status == 0
            }
        }
        let refreshed = launch(claude, ["plugin", "marketplace", "update", Self.marketplace])
        let installed = launch(claude, install + ["-y"])
        let updated = installed.status == 0 ? launch(claude, ["plugin", "update", id, "-y"]) : nil

        var steps: [Step] = []
        if added.status == 0 {
            steps.append(Step(name: "claude marketplace", did: .done,
                              message: repointed ? "the \(Self.marketplace) marketplace of Claude Code was another place's: removed it, and added this app's skills (\(agents.path))"
                                                 : "added the \(Self.marketplace) marketplace to Claude Code (\(agents.path))"))
        } else if installed.status == 0 {
            steps.append(Step(name: "claude marketplace", did: .warning,
                              message: "warning: claude plugin marketplace add failed: \(added.summary). Claude Code may read the \(Self.marketplace) marketplace from another place than \(agents.path), so its skills may not be this app's"))
        } else {
            steps.append(Step(name: "claude marketplace", did: .failed, message: "claude plugin marketplace add failed: \(added.summary)"))
        }
        if installed.status == 0 {
            steps.append(Step(name: "claude plugin", did: .done, message: "installed the \(Self.plugin) plugin for Claude Code (its skills are named \(Self.plugin):<skill>)"))
        } else {
            steps.append(Step(name: "claude plugin", did: .failed, message: "claude \(install.joined(separator: " ")) failed: \(installed.summary)"))
        }
        var problems: [String] = []
        if refreshed.status != 0 { problems.append("claude plugin marketplace update \(Self.marketplace) failed: \(refreshed.summary)") }
        if let updated, updated.status != 0 { problems.append("claude plugin update \(id) failed: \(updated.summary)") }
        if !problems.isEmpty {
            steps.append(Step(name: "claude update", did: .warning,
                              message: "warning: \(problems.joined(separator: "; ")). Claude Code may still hold an older build of the plugin"))
        } else if updated != nil {
            steps.append(Step(name: "claude update", did: .done, message: "refreshed the \(Self.marketplace) marketplace and the \(Self.plugin) plugin from it: restart Claude Code to load it"))
        }
        return steps
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "/._-@:".contains($0) } ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Outcome {
        let status: Int32
        let output: String

        /// The last line it said, or its status.
        var summary: String {
            let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.last ?? "exit status \(status)"
        }
    }

    /// What a process wrote, as it writes it, for another thread to read.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Runs `executable` to its end, or for `timeout` seconds, with nothing on its standard input, and returns what it said. A command
    /// that is still running then is stopped and its status is 124.
    private func launch(_ executable: URL, _ arguments: [String]) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = Collected()
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { handle in
            let more = handle.availableData
            if more.isEmpty { handle.readabilityHandler = nil } else { collected.append(more) }
        }
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            reading.readabilityHandler = nil
            return Outcome(status: 127, output: error.localizedDescription)
        }
        var timedOut = false
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if ended.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 2)
            }
        }
        // What is in the pipe now, without waiting for an end of it: a process it started may hold it open.
        reading.readabilityHandler = nil
        let descriptor = reading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(Data(buffer.prefix(count)))
        }
        if timedOut {
            let seconds = timeout == timeout.rounded() ? String(Int(timeout)) : String(timeout)
            return Outcome(status: 124, output: collected.text + "\ntimed out after \(seconds) s")
        }
        return Outcome(status: process.terminationStatus, output: collected.text)
    }

    // MARK: The link

    /// The folders the PATH names, links resolved.
    private var pathFolders: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
    }

    private func which(_ name: String) -> URL? {
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(folder), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path), !isDirectory(candidate) { return candidate }
        }
        return nil
    }

    private func linkCanvas() -> Step {
        let name = RPC.commandName
        let folder: URL
        if let bin = options.bin {
            folder = URL(fileURLWithPath: Invocation.absolute(bin), isDirectory: true)
            guard isDirectory(folder) else {
                return Step(name: "link", did: .failed, message: "\(folder.path) is not a folder, so \(name) is not linked there")
            }
        } else {
            let onPath = Set(pathFolders)
            let candidates = Self.binFolders.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent($0, isDirectory: true) }
            guard let found = candidates.first(where: { isDirectory($0) && fileManager.isWritableFile(atPath: $0.path) && onPath.contains($0.resolvingSymlinksInPath().path) }) else {
                return Step(name: "link", did: .skipped,
                            message: "no folder of those on your PATH is writable (\(candidates.map(\.path).joined(separator: ", "))): --bin DIR links \(name) into one, or run: ln -s \(shellQuoted(executable.path)) DIR/\(name)")
            }
            folder = found
        }
        let link = folder.appendingPathComponent(name)
        let note = options.bin != nil && !pathFolders.contains(folder.resolvingSymlinksInPath().path) ? " (that folder is not on your PATH: add it to be able to run \(name))" : ""
        var replacing = false
        if let existing = kind(of: link) {
            guard existing == .typeSymbolicLink, let written = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
                return Step(name: "link", did: .refused, message: "\(link.path) is there and canvas install didn't make it, so it's left as it is")
            }
            let points = URL(fileURLWithPath: written, relativeTo: folder).standardized
            if link.resolvingSymlinksInPath().path == executable.path {
                return Step(name: "link", did: .unchanged, message: "\(link.path) links to this \(name) already\(note)")
            }
            guard isAppsCanvas(points) else {
                return Step(name: "link", did: .refused, message: "\(link.path) is a link to \(points.path), which isn't the \(name) of an Infinite Canvas app, so it's left as it is")
            }
            replacing = true
        }
        // The new link is made beside the old and renamed over it: there is always a link.
        let fresh = folder.appendingPathComponent(".\(name)\(Self.stagingSuffix)")
        do {
            try? fileManager.removeItem(at: fresh)
            try fileManager.createSymbolicLink(at: fresh, withDestinationURL: executable)
            guard rename(fresh.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fileManager.removeItem(at: fresh)
            return Step(name: "link", did: .failed, message: "can't link \(link.path): \(error.localizedDescription)")
        }
        return Step(name: "link", did: .done, message: "\(replacing ? "replaced the link" : "linked") \(link.path) to \(executable.path)\(note)")
    }

    /// Whether `target` is the `canvas` of an Infinite Canvas app: in a bundle whose identifier is the app's (or a worktree copy's), or,
    /// where the app is gone, in one called what the app's bundles are called. Another app's helper of the same name is not.
    private func isAppsCanvas(_ target: URL) -> Bool {
        let helpers = target.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard target.lastPathComponent == RPC.commandName, helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents" else { return false }
        guard fileManager.fileExists(atPath: bundle.path) else {
            let name = bundle.lastPathComponent
            return name.hasSuffix(".app") && (name.hasPrefix("Infinite Canvas") || name.hasPrefix("InfiniteCanvas"))
        }
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String else { return false }
        return identifier == Self.appIdentifier || identifier.hasPrefix(Self.appIdentifier + ".worktree.")
    }
}

extension Invocation {
    /// `canvas install`, which asks no app.
    func runInstall(_ words: [String], format: OutputFormat) -> ExitStatus {
        let options: Install.Options
        do {
            options = try Install.Options(words)
        } catch {
            return fail(.usage, reason: "usage", error.message, hint: error.hint, format: format)
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let result = Install(options: options, environment: environment, executable: executable).run()
        switch format {
        case .text:
            write(result.steps.map(\.message).joined(separator: "\n"), false)
        case .json:
            var object: [String: JSON] = ["steps": .array(result.steps.map {
                .object(["step": .string($0.name), "did": .string($0.did.rawValue), "message": .string($0.message)])
            })]
            if let build = result.build { object["build"] = .string(build) }
            write(JSON.object(object).prettyText, false)
        }
        return result.succeeded ? .done : .failed
    }

    func installHelp() -> String {
        let name = RPC.commandName
        return [
            "Usage: \(name) install [--to <folder>] [--bin <folder>] [--from <folder>] [--no-claude]",
            Help.wrap("Puts what an agent needs to use \(name): the skills that came with the app, a copy of each in ~/.agents/skills (the folder agents that "
                + "read Agent Skills share), the same skills as a plugin of Claude Code, and \(name) itself, linked into a folder on your PATH. "
                + "It doesn't need the app to be running. Run it again after the app is updated: it replaces what it made, and only that.", width: Help.width),
            "Options:\n" + Help.table([
                ("--to <folder>", "Copy the skills into this folder instead of ~/.agents/skills. A folder there that \(name) install didn't make is left alone, and said."),
                ("--bin <folder>", "Link \(name) into this folder. Default: the first of ~/.local/bin, /opt/homebrew/bin and /usr/local/bin that is on your PATH and writable."),
                ("--from <folder>", "Take the skills from this folder, laid out like the app's Contents/Resources/agents. Default: the app this \(name) came with."),
                ("--no-claude", "Don't install the plugin for Claude Code. Without this, \(name) runs `claude plugin marketplace add` and `claude plugin install \(Install.plugin)@\(Install.marketplace)`, "
                    + "if `claude` is on your PATH, then refreshes the marketplace and updates the plugin, and says what to run if it isn't. "
                    + "A marketplace of that name added from another folder (another build of the app) is removed and added again from this app's."),
            ]),
            Help.wrap("It says what it did, a line for each step. Exit status 0: done; 1: a step couldn't be done (the line says which); 2: the command line is wrong.", width: Help.width),
        ].joined(separator: "\n\n")
    }
}
