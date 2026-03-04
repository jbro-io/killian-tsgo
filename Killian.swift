import Cocoa
import CoreGraphics

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
    private var runTimer: Timer?
    private var runFrame: Bool = false
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
        }

        log("Killian started — hunting rogue tsgo runners")
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

        // Start run animation during scan
        startRunAnimation()

        let processes = discoverProcesses()
        lastProcesses = processes

        let toKill = evaluateProcesses(processes)

        for proc in toKill {
            killProcess(proc, reason: "auto")
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

    private func evaluateProcesses(_ processes: [TsGoProcess]) -> [TsGoProcess] {
        var toKill: [TsGoProcess] = []

        // Always kill: orphaned, parent dead, memory hogs
        var survivors: [TsGoProcess] = []
        for proc in processes {
            if proc.ppid == 1 {
                log("Marking PID \(proc.pid) — orphaned (ppid=1)")
                toKill.append(proc)
            } else if kill(proc.ppid, 0) != 0 {
                log("Marking PID \(proc.pid) — parent dead (ppid=\(proc.ppid))")
                toKill.append(proc)
            } else if proc.rss > fourGB {
                log("Marking PID \(proc.pid) — memory hog (%.1f GB)", proc.memoryGB)
                toKill.append(proc)
            } else {
                survivors.append(proc)
            }
        }

        // Count IDE windows, kill excess tsgo processes (oldest first)
        let ideWindows = countIDEWindows()
        if survivors.count > ideWindows {
            let sorted = survivors.sorted { $0.pid < $1.pid }  // oldest (lowest PID) first
            let excess = survivors.count - max(ideWindows, 0)
            for proc in sorted.prefix(excess) {
                log("Marking PID \(proc.pid) — excess (%d tsgo vs %d IDE windows)", Int32(survivors.count), Int32(ideWindows))
                toKill.append(proc)
            }
        }

        return toKill
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
