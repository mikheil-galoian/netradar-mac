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
        let hasNew = snap.newCount > 0
        let title = " \(snap.devices.count)" + (hasNew ? "!" : "")
        // status color: GREEN = every device is known (ours), RED = a new/unknown device joined.
        // non-template palette symbol — the menu bar honors this color (it ignores tint on template icons).
        let tint: NSColor = hasNew ? .systemRed : .systemGreen
        let base = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "NetRadar")
        let img = base?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        img?.isTemplate = false
        button.image = img
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: tint])
    }

    // Read a color value from ~/.claude/statusbar/radar-theme.json (same file as the statusline)
    private func themeSpec(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/statusbar/radar-theme.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func color(_ spec: String?) -> NSColor? {
        guard let spec = spec, !spec.isEmpty else { return nil }
        if let n = Int(spec) { return Self.xterm256(n) }
        switch spec {
        case "red", "bred": return .systemRed
        case "green", "bgreen": return .systemGreen
        case "yellow", "byellow": return .systemYellow
        case "blue", "bblue": return .systemBlue
        case "magenta", "bmagenta": return .systemPurple
        case "cyan", "bcyan": return .systemTeal
        case "white", "bwhite": return .white
        case "gray", "grey": return .systemGray
        case "black": return .black
        default: return nil
        }
    }

    // xterm 256-color palette -> NSColor
    private static func xterm256(_ raw: Int) -> NSColor {
        let i = max(0, min(255, raw))
        func c(_ v: Int) -> CGFloat { CGFloat(v) / 255.0 }
        if i < 16 {
            let base = [(0,0,0),(205,0,0),(0,205,0),(205,205,0),(0,0,238),(205,0,205),(0,205,205),(229,229,229),
                        (127,127,127),(255,0,0),(0,255,0),(255,255,0),(92,92,255),(255,0,255),(0,255,255),(255,255,255)]
            let (r,g,b) = base[i]; return NSColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: 1)
        }
        if i >= 232 { let v = 8 + (i - 232) * 10; return NSColor(srgbRed: c(v), green: c(v), blue: c(v), alpha: 1) }
        let j = i - 16, steps = [0,95,135,175,215,255]
        return NSColor(srgbRed: c(steps[(j / 36) % 6]), green: c(steps[(j / 6) % 6]), blue: c(steps[j % 6]), alpha: 1)
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
        menu.addItem(themeSubmenu())
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

    // MARK: - In-menu color / theme picker (writes ~/.claude/statusbar/radar-theme.json)

    private let iconColors: [(String, String)] = [
        ("Зелёный", "46"), ("Аква", "51"), ("Розовый", "201"), ("Оранжевый", "214"),
        ("Жёлтый", "226"), ("Красный", "196"), ("Синий", "39"), ("Фиолетовый", "129"), ("Монохром", "")
    ]

    private func colorSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Цвет значка", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cur = currentSpec("menubar")
        for (name, spec) in iconColors {
            let mi = NSMenuItem(title: name, action: #selector(pickIconColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = spec
            if cur == spec { mi.state = .on }
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func themeSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Тема радара", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in ["Неон", "Классика", "Монохром"] {
            let mi = NSMenuItem(title: name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = name
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func pickIconColor(_ sender: NSMenuItem) {
        writeThemeKey("menubar", (sender.representedObject as? String) ?? "")
        refresh()
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        let name = (sender.representedObject as? String) ?? ""
        let presets: [String: [String: String]] = [
            "Неон": ["radar_label": "51", "sweep": "201", "lan": "46", "new": "196", "inbound": "214",
                     "context_low": "46", "context_mid": "220", "context_high": "196", "menubar": "46"],
            "Классика": ["radar_label": "cyan", "sweep": "cyan", "lan": "green", "new": "red", "inbound": "yellow",
                         "context_low": "green", "context_mid": "yellow", "context_high": "red", "menubar": "green"],
            "Монохром": ["radar_label": "white", "sweep": "gray", "lan": "white", "new": "white", "inbound": "gray",
                         "context_low": "white", "context_mid": "gray", "context_high": "white"]
        ]
        if let p = presets[name] { saveTheme(p as [String: Any]); refresh() }
    }

    private func themeURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/statusbar/radar-theme.json")
    }
    private func currentSpec(_ key: String) -> String {
        guard let data = try? Data(contentsOf: themeURL()),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let s = o[key] as? String { return s }
        if let n = o[key] as? NSNumber { return n.stringValue }
        return ""
    }
    private func writeThemeKey(_ key: String, _ value: String) {
        var o: [String: Any] = [:]
        if let data = try? Data(contentsOf: themeURL()),
           let cur = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { o = cur }
        if value.isEmpty { o.removeValue(forKey: key) } else { o[key] = value }
        saveTheme(o)
    }
    private func saveTheme(_ o: [String: Any]) {
        let dir = themeURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: themeURL())
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
