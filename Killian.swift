import Cocoa

struct TsGoProcess {
    let pid: pid_t
    let ppid: pid_t
    let cpu: Double
    let rss: UInt64  // in KB
    let elapsed: String
    let command: String

    var memoryMB: UInt64 { rss / 1024 }
    var memoryGB: Double { Double(rss) / 1024.0 / 1024.0 }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var scanTimer: Timer?
    private var animationTimer: Timer?
    private var lastProcesses: [TsGoProcess] = []
    private var recentKills: [(date: Date, pid: pid_t, reason: String)] = []
    private var totalKills: Int = 0
    private var totalScans: Int = 0
    private let logPath = NSHomeDirectory() + "/Library/Logs/Killian.log"
    private let fourGB: UInt64 = 4 * 1024 * 1024  // 4GB in KB

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = statusBarImage("figure.run")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            log("Button setup: target=\(String(describing: button.target)), action=\(String(describing: button.action))")
        } else {
            log("ERROR: statusItem.button is nil!")
        }

        log("Killian started — hunting rogue tsgo runners")
        scanAndKill()

        // Verify button still has target/action after scanAndKill
        if let button = statusItem.button {
            log("Post-scan button check: target=\(String(describing: button.target)), action=\(String(describing: button.action))")
        }

        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.scanAndKill()
        }
    }

    // MARK: - Click Handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        log("handleClick fired!")
        guard let event = NSApp.currentEvent else {
            log("handleClick: NSApp.currentEvent is nil")
            return
        }
        log("handleClick: event type = \(event.type.rawValue)")

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        log("showMenu called")
        let menu = NSMenu()

        // Current runners
        let processes = discoverProcesses()
        if processes.isEmpty {
            let item = NSMenuItem(title: "No tsgo runners detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Active Runners (\(processes.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for proc in processes {
                let title = String(format: "  PID %d — %.1f GB, CPU %.0f%%, up %@", proc.pid, proc.memoryGB, proc.cpu, proc.elapsed)
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Recent kills
        let recent = recentKills.suffix(5)
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent Kills", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for kill in recent.reversed() {
                let title = "  PID \(kill.pid) @ \(formatter.string(from: kill.date)) — \(kill.reason)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Actions
        menu.addItem(NSMenuItem(title: "Scan Now", action: #selector(scanNow), keyEquivalent: "s"))
        if !processes.isEmpty {
            menu.addItem(NSMenuItem(title: "Kill All Runners", action: #selector(killAllRunners), keyEquivalent: "k"))
        }

        menu.addItem(NSMenuItem.separator())

        // Stats
        let stats = NSMenuItem(title: "Scans: \(totalScans) | Kills: \(totalKills)", action: nil, keyEquivalent: "")
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

    @objc private func killAllRunners() {
        let processes = discoverProcesses()
        for proc in processes {
            killProcess(proc, reason: "manual kill-all")
        }
        if !processes.isEmpty {
            showKillAnimation()
        }
    }

    // MARK: - Process Discovery

    private func discoverProcesses() -> [TsGoProcess] {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,ppid,pcpu,rss,etime,command"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            log("Failed to run ps: \(error)")
            return []
        }

        // Read BEFORE waitUntilExit to avoid pipe deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var processes: [TsGoProcess] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {  // skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("/tsgo") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  let cpu = Double(parts[2]),
                  let rss = UInt64(parts[3]) else { continue }

            let elapsed = String(parts[4])
            let command = String(parts[5])

            processes.append(TsGoProcess(
                pid: pid, ppid: ppid, cpu: cpu, rss: rss,
                elapsed: elapsed, command: command
            ))
        }

        return processes
    }

    // MARK: - Scan & Kill

    private func scanAndKill() {
        totalScans += 1
        let processes = discoverProcesses()
        lastProcesses = processes

        var killed = false

        for proc in processes {
            if let reason = shouldKill(proc, allProcesses: processes) {
                killProcess(proc, reason: reason)
                killed = true
            }
        }

        if killed {
            showKillAnimation()
        } else {
            updateIcon(processes: processes)
        }
    }

    private func shouldKill(_ proc: TsGoProcess, allProcesses: [TsGoProcess]) -> String? {
        // 1. Orphaned — adopted by launchd
        if proc.ppid == 1 {
            return "orphaned (ppid=1)"
        }

        // 2. Parent dead or not a VS Code / node / pnpm process
        if kill(proc.ppid, 0) != 0 {
            return "parent dead (ppid=\(proc.ppid))"
        } else {
            let parentCmd = getProcessCommand(proc.ppid)
            if let cmd = parentCmd {
                let lower = cmd.lowercased()
                let isLegitParent = lower.contains("code") || lower.contains("node") ||
                                    lower.contains("pnpm") || lower.contains("electron") ||
                                    lower.contains("cursor")
                if !isLegitParent {
                    return "parent not VS Code/node (\(cmd))"
                }
            }
        }

        // 3. Memory hog — over 4GB
        if proc.rss > fourGB {
            return String(format: "memory hog (%.1f GB)", proc.memoryGB)
        }

        // 4. Excess instances — more than 1 per parent
        let siblings = allProcesses.filter { $0.ppid == proc.ppid }
        if siblings.count > 1 {
            // Keep the newest (highest PID), kill older duplicates
            let maxPid = siblings.map(\.pid).max() ?? proc.pid
            if proc.pid != maxPid {
                return "excess instance (sibling PID \(maxPid) is newer)"
            }
        }

        return nil
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

    // MARK: - Kill

    private func killProcess(_ proc: TsGoProcess, reason: String) {
        log("Killing PID \(proc.pid) — \(reason) (%.1f GB, CPU %.0f%%)", proc.memoryGB, proc.cpu)

        // SIGTERM first
        kill(proc.pid, SIGTERM)

        // Check after 2 seconds, SIGKILL if still alive
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if kill(proc.pid, 0) == 0 {
                self?.log("PID \(proc.pid) still alive after SIGTERM, sending SIGKILL")
                kill(proc.pid, SIGKILL)
            }
        }

        totalKills += 1
        recentKills.append((date: Date(), pid: proc.pid, reason: reason))
        // Keep only last 20 kills
        if recentKills.count > 20 {
            recentKills.removeFirst(recentKills.count - 20)
        }
    }

    // MARK: - Icon Updates

    private func updateIcon(processes: [TsGoProcess]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            if processes.isEmpty {
                button.image = self.statusBarImage("figure.run")
            } else {
                button.image = self.statusBarImage("figure.run.circle")
            }
        }
    }

    private func showKillAnimation() {
        animationTimer?.invalidate()

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }

            // Phase 1: figure.fall for 1.5s
            button.image = self.statusBarImage("figure.fall")

            self.animationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self = self, let button = self.statusItem.button else { return }

                // Phase 2: checkmark for 1s
                button.image = self.statusBarImage("checkmark.circle")

                self.animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    // Phase 3: back to normal
                    let current = self?.discoverProcesses() ?? []
                    self?.lastProcesses = current
                    self?.updateIcon(processes: current)
                }
            }
        }
    }

    private func statusBarImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration.preferringMonochrome()
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Killian")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
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
