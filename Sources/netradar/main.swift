import AppKit
import Foundation

// MARK: - Value snapshot (Sendable, handed to the main thread)

struct Device {
    let ip: String
    let mac: String
    let vendor: String
    let host: String
}

struct Conn {
    let proc: String
    let remote: String   // ip:port
    let rdns: String
    let dir: String      // "IN" or "out"
}

struct Snapshot {
    let devices: [Device]
    let conns: [Conn]
    let newCount: Int
    let inbound: Int
}

// MARK: - Regex helper (NSRegularExpression, works on macOS 12+)

func captures(_ pattern: String, _ text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    var rows: [[String]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range) else { continue }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: s) { groups.append(String(s[r])) }
            else { groups.append("") }
        }
        rows.append(groups)
    }
    return rows
}

// MARK: - Scan engine (all state confined to scanQueue)

final class ScanEngine {
    private let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NetRadar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private lazy var baselineURL = support.appendingPathComponent("baseline.json")
    private lazy var ouiURL = support.appendingPathComponent("oui.txt")

    private var baseline: Set<String>? = nil
    private var rdnsCache: [String: String] = [:]
    private var oui: [String: String]? = nil
    private let maxLookupsPerCycle = 12

    // Run a command, capture stdout.
    private func run(_ cmd: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func normMac(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }
    private func isNonUnicast(_ mac: String) -> Bool {
        mac.hasPrefix("01:00:5e") || mac.hasPrefix("33:33") || mac.hasPrefix("ff:ff:ff") || mac == "00:00:00:00:00:00"
    }

    private func loadOUI() {
        if oui != nil { return }
        var map: [String: String] = [:]
        if let text = try? String(contentsOf: ouiURL, encoding: .utf8) {
            for row in captures("^([0-9A-Fa-f]{6})\\s+(.+)$", text) {
                map[row[1].uppercased()] = row[2].trimmingCharacters(in: .whitespaces)
            }
        }
        oui = map
    }
    private func vendor(_ mac: String) -> String {
        loadOUI()
        let key = mac.replacingOccurrences(of: ":", with: "").prefix(6).uppercased()
        return oui?[String(key)] ?? ""
    }

    private func rdns(_ ip: String, budget: inout Int) -> String {
        if let c = rdnsCache[ip] { return c }
        if budget <= 0 { return "" }
        budget -= 1
        let out = run("/usr/bin/host", ["-W", "1", ip])
        var name = ""
        if let row = captures("pointer\\s+(.+?)\\.?\\s*$", out).first { name = row[1] }
        rdnsCache[ip] = name
        return name
    }

    private func loadBaseline() -> Set<String> {
        if let b = baseline { return b }
        if let data = try? Data(contentsOf: baselineURL),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            baseline = Set(arr); return baseline!
        }
        return []
    }
    private func saveBaseline(_ macs: Set<String>) {
        baseline = macs
        if let data = try? JSONEncoder().encode(Array(macs)) { try? data.write(to: baselineURL) }
    }

    // Full scan -> immutable snapshot.
    func scan() -> Snapshot {
        var budget = maxLookupsPerCycle

        // LAN devices
        var devices: [Device] = []
        var macs = Set<String>()
        for row in captures("\\(([0-9.]+)\\)\\s+at\\s+([0-9a-f:]+)", run("/usr/sbin/arp", ["-an"])) {
            let ip = row[1]
            let mac = normMac(row[2])
            if ip.hasPrefix("224.") || ip.hasPrefix("239.") || ip.hasPrefix("255.") || ip.hasSuffix(".255") { continue }
            if isNonUnicast(mac) { continue }
            macs.insert(mac)
            devices.append(Device(ip: ip, mac: mac, vendor: vendor(mac), host: rdns(ip, budget: &budget)))
        }

        // NEW devices vs baseline (first run seeds baseline)
        var base = loadBaseline()
        if base.isEmpty { base = macs; saveBaseline(macs) }
        let newCount = macs.subtracting(base).count

        // Externally-reachable listening ports
        var listen = Set<String>()
        for row in captures("TCP\\s+(\\S+):([0-9]+)\\s+\\(LISTEN\\)", run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])) {
            let hostpart = row[1]
            if hostpart == "127.0.0.1" || hostpart == "[::1]" || hostpart == "localhost" { continue }
            listen.insert(row[2])
        }

        // Established connections
        var conns: [Conn] = []
        var inbound = 0
        for row in captures("^(\\S+)\\s+[0-9]+\\s.*\\bTCP\\s+(\\S+):([0-9]+)->(\\S+):([0-9]+)\\s+\\(ESTABLISHED\\)",
                            run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED"])) {
            let proc = row[1], lport = row[3], rip = row[4], rport = row[5]
            if rip == "127.0.0.1" || rip == "[::1]" || rip == "localhost" { continue }
            let dir = listen.contains(lport) ? "IN" : "out"
            if dir == "IN" { inbound += 1 }
            conns.append(Conn(proc: proc, remote: "\(rip):\(rport)", rdns: rdns(rip, budget: &budget), dir: dir))
        }
        conns.sort { ($0.dir == "IN" ? 0 : 1) < ($1.dir == "IN" ? 0 : 1) }

        return Snapshot(devices: devices, conns: conns, newCount: newCount, inbound: inbound)
    }

    func resetBaseline() { try? FileManager.default.removeItem(at: baselineURL); baseline = nil }
    var ouiPath: String { ouiURL.path }
    var supportPath: String { support.path }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine = ScanEngine()
    private let scanQueue = DispatchQueue(label: "com.netradar.scan")
    private var timer: Timer?
    private var last = Snapshot(devices: [], conns: [], newCount: 0, inbound: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "NetRadar")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.title = " …"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let snap = self.engine.scan()
            DispatchQueue.main.async { self.apply(snap) }
        }
    }

    private func apply(_ snap: Snapshot) {
        last = snap
        guard let button = statusItem.button else { return }
        button.title = " \(snap.devices.count)" + (snap.newCount > 0 ? "!" : "")
        button.contentTintColor = snap.newCount > 0 ? .systemRed : nil
    }

    // Rebuild the dropdown each time it opens, from the latest snapshot.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = "LAN \(last.devices.count)"
            + (last.newCount > 0 ? " · NEW \(last.newCount)" : "")
            + (last.inbound > 0 ? " · IN \(last.inbound)" : "")
        menu.addItem(sectionTitle(header))

        menu.addItem(sectionTitle("Devices"))
        if last.devices.isEmpty { menu.addItem(disabled("  (none)")) }
        for d in last.devices {
            let name = d.host.isEmpty ? (d.vendor.isEmpty ? d.ip : d.vendor) : d.host
            let sub = [d.vendor, d.mac].filter { !$0.isEmpty }.joined(separator: " · ")
            menu.addItem(disabled("  \(d.ip)   \(name)\(sub.isEmpty ? "" : "   — \(sub)")"))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(sectionTitle("Connections"))
        if last.conns.isEmpty { menu.addItem(disabled("  (none)")) }
        for c in last.conns.prefix(30) {
            let where_ = c.rdns.isEmpty ? c.remote : c.rdns
            menu.addItem(disabled("  [\(c.dir)] \(c.proc)   \(where_)"))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(action("Refresh now", #selector(doRefresh)))
        menu.addItem(action("Reset new-device baseline", #selector(doReset)))
        menu.addItem(action("Reveal data folder", #selector(doReveal)))
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit NetRadar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func sectionTitle(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        item.isEnabled = false
        return item
    }
    private func disabled(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        ])
        item.isEnabled = false
        return item
    }
    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func doRefresh() { refresh() }
    @objc private func doReset() { scanQueue.async { self.engine.resetBaseline(); let s = self.engine.scan(); DispatchQueue.main.async { self.apply(s) } } }
    @objc private func doReveal() { NSWorkspace.shared.selectFile(engine.ouiPath, inFileViewerRootedAtPath: engine.supportPath) }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
