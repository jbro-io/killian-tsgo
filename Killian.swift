import Cocoa
import CoreGraphics

enum ProcessKind: String {
    case tsgo = "tsgo"
    case nextServer = "next-server"
}

struct TsGoProcess {
    let pid: pid_t
    let ppid: pid_t
    let cpu: Double
    let rss: UInt64  // in KB
    let elapsed: String
    let elapsedSeconds: Int
    let tty: String
    let startTime: String
    let command: String
    let kind: ProcessKind

    var memoryMB: UInt64 { rss / 1024 }
    var memoryGB: Double { Double(rss) / 1024.0 / 1024.0 }
}

struct ProcessInfo {
    let pid: pid_t
    let ppid: pid_t
    let tty: String
    let startTime: String
    let command: String
}

struct ProcessSnapshot {
    let tracked: [TsGoProcess]
    let byPid: [pid_t: ProcessInfo]
}

struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startTime: String
}

struct CandidateState {
    let process: TsGoProcess
    let reason: String
    let consecutiveScans: Int
}

struct KillCandidate {
    let process: TsGoProcess
    let reason: String
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var scanTimer: Timer?
    private var animationTimer: Timer?
    private var runTimer: Timer?
    private var runFrame: Bool = false
    private var lastProcesses: [TsGoProcess] = []
    private var lastSnapshot: ProcessSnapshot?
    private var recentKills: [(date: Date, pid: pid_t, reason: String)] = []
    private var suspectStates: [ProcessIdentity: CandidateState] = [:]
    private var totalKills: Int = 0
    private var totalScans: Int = 0
    private let logPath = NSHomeDirectory() + "/Library/Logs/Killian.log"
    private let staleTsgoGracePeriod: Int = 180
    private let staleNextServerGracePeriod: Int = 180
    private let staleTsgoIdleCPUThreshold: Double = 5.0
    private let staleNextServerIdleCPUThreshold: Double = 3.0
    private let requiredStaleScans: Int = 3
    private let confirmedStaleMemoryBudgetKB: UInt64 = 6 * 1024 * 1024

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = statusBarImage("figure.run")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        log("Killian started — hunting lingering tsgo language servers and orphaned next-server processes")
        scanAndKill()

        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.scanAndKill()
        }
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // Current runners
        let snapshot = discoverSnapshot()
        let processes = snapshot.tracked
        lastProcesses = processes
        lastSnapshot = snapshot
        if processes.isEmpty {
            let item = NSMenuItem(title: "No rogue processes detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Active Runners (\(processes.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for proc in processes {
                let label = processLabel(proc)
                let title = String(format: "  PID %d [%@] — %.1f GB, CPU %.0f%%, up %@", proc.pid, label, proc.memoryGB, proc.cpu, proc.elapsed)
                let item = NSMenuItem(title: title, action: #selector(killRunner(_:)), keyEquivalent: "")
                item.tag = Int(proc.pid)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Recent kills submenu
        if !recentKills.isEmpty {
            let killsMenu = NSMenu()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for kill in recentKills.suffix(10).reversed() {
                let title = "PID \(kill.pid) @ \(formatter.string(from: kill.date)) — \(kill.reason)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                killsMenu.addItem(item)
            }
            let killsItem = NSMenuItem(title: "Recent Kills (\(recentKills.count))", action: nil, keyEquivalent: "")
            killsItem.submenu = killsMenu
            menu.addItem(killsItem)
        }

        // Actions
        menu.addItem(NSMenuItem(title: "Scan Now", action: #selector(scanNow), keyEquivalent: "s"))
        if !processes.isEmpty {
            menu.addItem(NSMenuItem(title: "Kill All Runners", action: #selector(killAllRunners), keyEquivalent: "k"))
        }

        menu.addItem(NSMenuItem.separator())

        // Simulate submenu
        let simMenu = NSMenu()
        simMenu.addItem(NSMenuItem(title: "Scan (5s)", action: #selector(simulateScan), keyEquivalent: ""))
        simMenu.addItem(NSMenuItem(title: "Kill Sequence", action: #selector(simulateKill), keyEquivalent: ""))
        simMenu.addItem(NSMenuItem(title: "Fall", action: #selector(simulateFall), keyEquivalent: ""))
        simMenu.addItem(NSMenuItem(title: "Headshot", action: #selector(simulateHeadshot), keyEquivalent: ""))
        let simItem = NSMenuItem(title: "Simulate", action: nil, keyEquivalent: "")
        simItem.submenu = simMenu
        menu.addItem(simItem)

        menu.addItem(NSMenuItem.separator())

        // Stats
        let ideCount = countIDEWindows()
        let stats = NSMenuItem(title: "IDE windows: \(ideCount) | Scans: \(totalScans) | Kills: \(totalKills)", action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func scanNow() {
        scanAndKill()
    }

    @objc private func simulateScan() {
        startRunAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.stopRunAnimation()
            self?.statusItem.button?.image = self?.statusBarImage("figure.run")
        }
    }

    @objc private func simulateKill() {
        showKillAnimation()
    }

    @objc private func simulateFall() {
        statusItem.button?.image = statusBarImage("figure.fall")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.statusItem.button?.image = self?.statusBarImage("figure.run")
        }
    }

    @objc private func simulateHeadshot() {
        statusItem.button?.image = skullImage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.statusItem.button?.image = self?.statusBarImage("figure.run")
        }
    }

    @objc private func killRunner(_ sender: NSMenuItem) {
        let pid = pid_t(sender.tag)
        if let proc = lastProcesses.first(where: { $0.pid == pid }) {
            killProcess(proc, reason: "manual kill")
        } else {
            // Process not in cache, kill by pid directly
            log("Manual kill PID \(pid)")
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            totalKills += 1
            recentKills.append((date: Date(), pid: pid, reason: "manual kill"))
        }
        showKillAnimation()
    }

    @objc private func killAllRunners() {
        let snapshot = discoverSnapshot()
        let processes = snapshot.tracked
        lastProcesses = processes
        lastSnapshot = snapshot
        for proc in processes {
            killProcess(proc, reason: "manual kill-all")
        }
        if !processes.isEmpty {
            showKillAnimation()
        }
    }

    // MARK: - Process Discovery

    private func discoverSnapshot() -> ProcessSnapshot {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,tty=,lstart=,command="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            log("Failed to run ps: \(error)")
            return ProcessSnapshot(tracked: [], byPid: [:])
        }

        // Read BEFORE waitUntilExit to avoid pipe deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else {
            return ProcessSnapshot(tracked: [], byPid: [:])
        }

        var processes: [TsGoProcess] = []
        var byPid: [pid_t: ProcessInfo] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 12,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  let cpu = Double(parts[2]),
                  let rss = UInt64(parts[3]),
                  let elapsedSeconds = parseElapsedSeconds(String(parts[4])) else { continue }

            let elapsed = String(parts[4])
            let tty = String(parts[5])
            let startTime = parts[6...10].joined(separator: " ")
            let command = parts[11...].joined(separator: " ")

            byPid[pid] = ProcessInfo(
                pid: pid,
                ppid: ppid,
                tty: tty,
                startTime: startTime,
                command: command
            )

            let kind: ProcessKind
            if command.contains("/tsgo") {
                kind = .tsgo
            } else if command.contains("next-server") {
                kind = .nextServer
            } else {
                continue
            }

            processes.append(TsGoProcess(
                pid: pid, ppid: ppid, cpu: cpu, rss: rss,
                elapsed: elapsed, elapsedSeconds: elapsedSeconds,
                tty: tty, startTime: startTime, command: command, kind: kind
            ))
        }

        return ProcessSnapshot(tracked: processes, byPid: byPid)
    }

    private func parseElapsedSeconds(_ elapsed: String) -> Int? {
        let daySplit = elapsed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

        let dayCount: Int
        let timePart: Substring

        if daySplit.count == 2 {
            guard let parsedDays = Int(daySplit[0]) else { return nil }
            dayCount = parsedDays
            timePart = daySplit[1]
        } else {
            dayCount = 0
            timePart = Substring(elapsed)
        }

        let timeComponents = timePart.split(separator: ":")
        guard timeComponents.count == 2 || timeComponents.count == 3 else { return nil }

        let hours: Int
        let minutesIndex: Int
        if timeComponents.count == 3 {
            guard let parsedHours = Int(timeComponents[0]) else { return nil }
            hours = parsedHours
            minutesIndex = 1
        } else {
            hours = 0
            minutesIndex = 0
        }

        guard let minutes = Int(timeComponents[minutesIndex]),
              let seconds = Int(timeComponents[minutesIndex + 1]) else { return nil }

        return (((dayCount * 24) + hours) * 60 + minutes) * 60 + seconds
    }

    // MARK: - Scan & Kill

    private func scanAndKill() {
        totalScans += 1

        // Start run animation during scan
        startRunAnimation()

        let snapshot = discoverSnapshot()
        let processes = snapshot.tracked
        lastProcesses = processes
        lastSnapshot = snapshot

        let toKill = evaluateProcesses(in: snapshot)

        for candidate in toKill {
            killProcess(candidate.process, reason: candidate.reason)
        }

        if !toKill.isEmpty {
            showKillAnimation()
        } else {
            // Let the run animation play out briefly, then settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.stopRunAnimation()
                self?.statusItem.button?.image = self?.statusBarImage("figure.run")
            }
        }
    }

    private func evaluateProcesses(in snapshot: ProcessSnapshot) -> [KillCandidate] {
        var updatedStates: [ProcessIdentity: CandidateState] = [:]
        var confirmed: [CandidateState] = []

        for proc in snapshot.tracked {
            guard let reason = staleReason(for: proc, in: snapshot) else { continue }

            let identity = ProcessIdentity(pid: proc.pid, startTime: proc.startTime)
            let scans = (suspectStates[identity]?.consecutiveScans ?? 0) + 1
            let state = CandidateState(process: proc, reason: reason, consecutiveScans: scans)
            updatedStates[identity] = state

            if scans >= requiredStaleScans {
                confirmed.append(state)
            } else {
                log(
                    "Tracking suspect PID \(proc.pid) [%@] — %@ (%d/%d scans, %.1f GB, CPU %.0f%%)",
                    processLabel(proc, snapshot: snapshot),
                    reason,
                    scans,
                    requiredStaleScans,
                    proc.memoryGB,
                    proc.cpu
                )
            }
        }

        suspectStates = updatedStates
        return selectConfirmedKillCandidates(from: confirmed)
    }

    private func selectConfirmedKillCandidates(from confirmed: [CandidateState]) -> [KillCandidate] {
        guard !confirmed.isEmpty else { return [] }

        let totalConfirmedRSS = confirmed.reduce(0) { $0 + $1.process.rss }
        let sorted = confirmed.sorted {
            if $0.process.rss == $1.process.rss {
                return $0.consecutiveScans > $1.consecutiveScans
            }
            return $0.process.rss > $1.process.rss
        }

        if totalConfirmedRSS > confirmedStaleMemoryBudgetKB {
            log(
                "Confirmed stale memory budget exceeded: %.1f GB across %d processes",
                Double(totalConfirmedRSS) / 1024.0 / 1024.0,
                confirmed.count
            )

            var selected: [KillCandidate] = []
            var remainingRSS = totalConfirmedRSS
            for state in sorted {
                selected.append(KillCandidate(process: state.process, reason: state.reason))
                remainingRSS -= state.process.rss
                if remainingRSS <= confirmedStaleMemoryBudgetKB {
                    break
                }
            }
            return selected
        }

        if let first = sorted.first {
            return [KillCandidate(process: first.process, reason: first.reason)]
        }

        return []
    }

    private func processLabel(_ proc: TsGoProcess, snapshot: ProcessSnapshot? = nil) -> String {
        switch proc.kind {
        case .tsgo:
            return isLanguageServer(proc, snapshot: snapshot) ? "tsgo LSP" : "tsgo CLI"
        case .nextServer:
            return "next-server"
        }
    }

    private func isLanguageServer(_ proc: TsGoProcess, snapshot: ProcessSnapshot? = nil) -> Bool {
        if proc.command.contains("--stdio") { return true }
        if let snapshot = snapshot ?? lastSnapshot {
            return hasIDEAncestor(proc.ppid, in: snapshot)
        }
        return false
    }

    private func staleReason(for proc: TsGoProcess, in snapshot: ProcessSnapshot) -> String? {
        switch proc.kind {
        case .tsgo:
            return staleTsgoReason(proc, in: snapshot)
        case .nextServer:
            return staleNextServerReason(proc, in: snapshot)
        }
    }

    private func countIDEWindows() -> Int {
        let ideNames = ["Electron", "Code", "Cursor", "Visual Studio Code"]
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        var count = 0
        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            if ideNames.contains(where: { ownerName.contains($0) }) {
                count += 1
            }
        }
        return count
    }

    private func staleTsgoReason(_ proc: TsGoProcess, in snapshot: ProcessSnapshot) -> String? {
        if proc.command.contains("--stdio") {
            guard proc.elapsedSeconds >= staleTsgoGracePeriod else { return nil }
            guard proc.cpu < staleTsgoIdleCPUThreshold else { return nil }
            guard !hasIDEAncestor(proc.ppid, in: snapshot) else { return nil }

            if proc.ppid == 1 {
                return "orphaned language server adopted by launchd"
            }

            if !isProcessAlive(proc.ppid, in: snapshot) {
                return "orphaned language server whose parent exited"
            }

            return nil
        }

        guard isBuildWatchTsgo(proc) else { return nil }
        guard isInnermostTrackedTsgoProcess(proc, in: snapshot) else { return nil }
        guard proc.elapsedSeconds >= staleTsgoGracePeriod else { return nil }

        return orphanedTsgoChainReason(for: proc, in: snapshot)
    }

    private func staleNextServerReason(_ proc: TsGoProcess, in snapshot: ProcessSnapshot) -> String? {
        guard proc.elapsedSeconds >= staleNextServerGracePeriod else { return nil }
        guard proc.cpu < staleNextServerIdleCPUThreshold else { return nil }
        guard proc.tty == "??" || proc.tty == "?" else { return nil }

        if proc.ppid == 1 {
            return "orphaned next-server adopted by launchd"
        }

        if !isProcessAlive(proc.ppid, in: snapshot) {
            return "orphaned next-server whose parent exited"
        }

        return nil
    }

    private func hasIDEAncestor(_ pid: pid_t, in snapshot: ProcessSnapshot) -> Bool {
        var current = pid
        for _ in 0..<12 {
            guard current > 1 else { return false }
            guard let info = snapshot.byPid[current] else { return false }
            if isIDEProcessCommand(info.command) {
                return true
            }
            guard info.ppid != current else { return false }
            current = info.ppid
        }
        return false
    }

    private func isBuildWatchTsgo(_ proc: TsGoProcess) -> Bool {
        proc.command.contains("--build") && proc.command.contains("--watch")
    }

    private func isInnermostTrackedTsgoProcess(_ proc: TsGoProcess, in snapshot: ProcessSnapshot) -> Bool {
        !snapshot.tracked.contains { candidate in
            candidate.kind == .tsgo && candidate.ppid == proc.pid
        }
    }

    private func orphanedTsgoChainReason(for proc: TsGoProcess, in snapshot: ProcessSnapshot) -> String? {
        var currentPid = proc.pid

        for _ in 0..<12 {
            guard let info = snapshot.byPid[currentPid] else { return nil }

            if info.ppid == 1 {
                return "orphaned tsgo build watcher adopted by launchd"
            }

            guard info.ppid != currentPid else { return nil }
            guard let parentInfo = snapshot.byPid[info.ppid] else {
                return "orphaned tsgo build watcher whose parent exited"
            }

            if isIDEProcessCommand(parentInfo.command) {
                return nil
            }

            guard parentInfo.command.contains("tsgo") else { return nil }
            currentPid = parentInfo.pid
        }

        return nil
    }

    private func isIDEProcessCommand(_ command: String) -> Bool {
        let idePatterns = ["Electron", "Code Helper", "Cursor", "Visual Studio Code"]
        return idePatterns.contains(where: { command.contains($0) })
    }

    private func isProcessAlive(_ pid: pid_t, in snapshot: ProcessSnapshot) -> Bool {
        guard pid > 1 else { return false }
        return snapshot.byPid[pid] != nil
    }

    private func getProcessPpid(_ pid: pid_t) -> pid_t? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "ppid="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return pid_t(str)
    }

    private func getProcessCommand(_ pid: pid_t) -> String? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func getProcessStartTime(_ pid: pid_t) -> String? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "lstart="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Kill

    private func killProcess(_ proc: TsGoProcess, reason: String) {
        let label = processLabel(proc)
        log("Killing PID \(proc.pid) [%@] — \(reason) (%.1f GB, CPU %.0f%%)", label, proc.memoryGB, proc.cpu)

        // For next-server, also kill the parent process tree (next dev, pnpm dev, etc.)
        var pidsToKill: [pid_t] = [proc.pid]
        if proc.kind == .nextServer {
            var parentPid = proc.ppid
            while parentPid > 1 {
                appendUniquePid(parentPid, to: &pidsToKill)
                if let grandparent = getProcessPpid(parentPid), grandparent > 1 {
                    // Check if grandparent is part of the next/pnpm chain
                    if let cmd = getProcessCommand(grandparent), cmd.contains("next") || cmd.contains("pnpm") {
                        appendUniquePid(grandparent, to: &pidsToKill)
                        parentPid = grandparent
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
            if pidsToKill.count > 1 {
                log("Killing next-server process tree: %@", pidsToKill.map { String($0) }.joined(separator: ", "))
            }
        } else if proc.kind == .tsgo && isBuildWatchTsgo(proc) {
            var parentPid = proc.ppid
            while parentPid > 1 {
                guard let parentCommand = getProcessCommand(parentPid), parentCommand.contains("tsgo") else {
                    break
                }

                appendUniquePid(parentPid, to: &pidsToKill)

                guard let grandparent = getProcessPpid(parentPid), grandparent > 1, grandparent != parentPid else {
                    break
                }
                parentPid = grandparent
            }

            if pidsToKill.count > 1 {
                log("Killing tsgo process tree: %@", pidsToKill.map { String($0) }.joined(separator: ", "))
            }
        }

        var expectedStartTimes: [pid_t: String] = [:]
        if let snapshot = lastSnapshot {
            for pid in pidsToKill {
                if let startTime = snapshot.byPid[pid]?.startTime {
                    expectedStartTimes[pid] = startTime
                }
            }
        }
        expectedStartTimes[proc.pid] = proc.startTime

        // SIGTERM first
        for pid in pidsToKill {
            kill(pid, SIGTERM)
        }

        // Check after 2 seconds, SIGKILL if still alive
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            for pid in pidsToKill {
                if kill(pid, 0) == 0 {
                    guard let expectedStartTime = expectedStartTimes[pid],
                          let currentStartTime = self?.getProcessStartTime(pid),
                          currentStartTime == expectedStartTime else {
                        self?.log("Skipping SIGKILL for PID \(pid) because process identity changed")
                        continue
                    }
                    self?.log("PID \(pid) still alive after SIGTERM, sending SIGKILL")
                    kill(pid, SIGKILL)
                }
            }
        }

        totalKills += 1
        recentKills.append((date: Date(), pid: proc.pid, reason: "[\(label)] \(reason)"))
        // Keep only last 20 kills
        if recentKills.count > 20 {
            recentKills.removeFirst(recentKills.count - 20)
        }
    }

    private func appendUniquePid(_ pid: pid_t, to pids: inout [pid_t]) {
        if !pids.contains(pid) {
            pids.append(pid)
        }
    }

    // MARK: - Icon Updates

    private func startRunAnimation() {
        guard runTimer == nil else { return }
        runFrame = false
        statusItem.button?.image = statusBarImage("figure.run")
        runTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.runFrame.toggle()
            button.image = self.statusBarImage(self.runFrame ? "figure.walk" : "figure.run")
        }
    }

    private func stopRunAnimation() {
        runTimer?.invalidate()
        runTimer = nil
    }

    private func showKillAnimation() {
        stopRunAnimation()
        animationTimer?.invalidate()

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }

            // Phase 1: scope (headshot) for 0.6s
            button.image = self.statusBarImage("scope")

            self.animationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                guard let self = self, let button = self.statusItem.button else { return }

                // Phase 2: figure.fall for 1s
                button.image = self.statusBarImage("figure.fall")

                self.animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    guard let self = self, let button = self.statusItem.button else { return }

                    // Phase 3: skull and crossbones for 1.5s
                    button.image = self.skullImage()

                    self.animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                        self?.statusItem.button?.image = self?.statusBarImage("figure.run")
                    }
                }
            }
        }
    }

    // MARK: - Image Helpers

    private func statusBarImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration.preferringMonochrome()
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Killian")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        return img
    }

    private func skullImage() -> NSImage {
        let size = NSSize(width: 28, height: 28)
        let img = NSImage(size: size, flipped: false) { rect in
            let str = "\u{2620}" as NSString  // ☠ skull and crossbones
            let font = NSFont.systemFont(ofSize: 26, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let strSize = str.size(withAttributes: attrs)
            let x = (rect.width - strSize.width) / 2
            let y = (rect.height - strSize.height) / 2
            str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Logging

    private func log(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        NSLog("[Killian] %@", message)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
