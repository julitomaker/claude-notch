// Claude Notch — Claude Code activity around the MacBook notch, with a tamagotchi.
//
// Claude Code hooks (hooks/notch-hook.sh) drop small per-event files into
// ~/.claude/notch/sessions. This app watches that folder, works out the state of
// every session (working / needs you / done-unseen / resting), keeps the pet's
// stats, and drives the view in notch.html.

import Cocoa
import WebKit

let home = FileManager.default.homeDirectoryForCurrentUser
let notchDir = home.appendingPathComponent(".claude/notch")
let sessionsDir = notchDir.appendingPathComponent("sessions")
let petURL = notchDir.appendingPathComponent("pet.json")
let configURL = notchDir.appendingPathComponent("config.json")
let settingsURL = home.appendingPathComponent(".claude/settings.json")

/// Room on each side of the notch (inline toast + hover list). The panel is transparent and click-through.
let sideRoom: CGFloat = 150
/// Extra height below the notch for the hover list.
let cardRoom: CGFloat = 170
/// A finished-but-unseen session turns into "resting" after this long anyway.
let unseenExpiry: TimeInterval = 45 * 60
/// A "working" session with no hook/transcript activity for this long is considered stuck.
let staleAfter: TimeInterval = 10 * 60
/// Session files untouched for this long are deleted.
let pruneAfter: TimeInterval = 24 * 60 * 60

// MARK: - Small helpers

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func touch(_ url: URL) {
    try? Data().write(to: url, options: .atomic)
}

extension String {
    func truncated(_ max: Int) -> String {
        guard count > max else { return self }
        let cut = String(prefix(max))
        let trimmed = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        return trimmed.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

// MARK: - Config

struct Config {
    var petName = "Clawdito"
    var autoExpand = true

    static func load() -> Config {
        var c = Config()
        if let j = readJSON(configURL) {
            if let n = j["petName"] as? String, !n.isEmpty { c.petName = String(n.prefix(20)) }
            if let a = j["autoExpand"] as? Bool { c.autoExpand = a }
        } else {
            let text = "{\n  \"petName\": \"Clawdito\",\n  \"autoExpand\": true\n}\n"
            try? text.write(to: configURL, atomically: true, encoding: .utf8)
        }
        return c
    }
}

// MARK: - Screen geometry

struct Geometry: Equatable {
    var frame: NSRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
}

func targetScreen() -> NSScreen? {
    NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
}

func notchGeometry(for screen: NSScreen) -> Geometry {
    let f = screen.frame
    var notchWidth: CGFloat = 0
    var midX = f.midX
    var height: CGFloat
    if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
        notchWidth = f.width - l.width - r.width
        midX = f.minX + l.width + notchWidth / 2
        height = screen.safeAreaInsets.top
    } else {
        let menuBar = f.maxY - screen.visibleFrame.maxY
        height = menuBar > 0 ? menuBar : 24
    }
    let width = max(notchWidth + sideRoom * 2, 360).rounded(.up)
    let total = height + cardRoom
    let frame = NSRect(x: (midX - width / 2).rounded(), y: f.maxY - total, width: width, height: total)
    return Geometry(frame: frame, notchWidth: notchWidth, notchHeight: height)
}

// MARK: - Describing what Claude is doing

func projectName(cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "Claude" }
    // Prefer the git repo's name over a subfolder's.
    var dir = URL(fileURLWithPath: cwd)
    var root = dir
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { root = dir; break }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    let name = root.lastPathComponent
    if name.hasPrefix("scratch-") { return "scratch" }
    return name == "/" || name.isEmpty ? "Claude" : name
}

func describeTool(_ j: [String: Any]?) -> String? {
    guard let j, let tool = j["tool_name"] as? String else { return nil }
    let input = j["tool_input"] as? [String: Any] ?? [:]
    func file(_ k: String = "file_path") -> String? {
        (input[k] as? String).map { ($0 as NSString).lastPathComponent }
    }
    let text: String
    switch tool {
    case "Edit", "MultiEdit": text = "Editando " + (file() ?? "archivos")
    case "Write": text = "Escribiendo " + (file() ?? "un archivo")
    case "NotebookEdit": text = "Editando " + (file("notebook_path") ?? "notebook")
    case "Read": text = "Leyendo " + (file() ?? "archivos")
    case "Bash":
        if let d = input["description"] as? String, !d.isEmpty { text = d }
        else {
            let cmd = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            text = cmd.isEmpty ? "Corriendo un comando" : "$ " + cmd
        }
    case "Grep": text = (input["pattern"] as? String).map { "Buscando “\($0)”" } ?? "Buscando"
    case "Glob": text = "Buscando archivos"
    case "WebFetch", "WebSearch": text = "Investigando en la web"
    case "Task", "Agent": text = (input["description"] as? String).map { "Delegando: \($0)" } ?? "Delegando a un agente"
    case "TodoWrite": text = "Organizando tareas"
    default:
        if tool.hasPrefix("mcp__") { text = "Usando " + (tool.components(separatedBy: "__").last ?? tool) }
        else { text = tool }
    }
    return text.truncated(70)
}

/// Strips markdown and returns the first sentence — Claude's final messages
/// nearly always lead with the outcome ("Quedó instalado y andando.").
func headline(_ markdown: String, max: Int) -> String {
    var s = markdown
    s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "[*_`]{1,3}", with: "", options: .regularExpression)
    let lines = s.components(separatedBy: .newlines)
        .map { $0.replacingOccurrences(of: "^\\s*(#+|>|[-*•]|\\d+\\.)\\s+", with: "", options: .regularExpression)
                  .trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("|") }
    guard var line = lines.first else { return "" }
    if let r = line.range(of: "(?<=[.!?])\\s", options: .regularExpression), line.distance(from: line.startIndex, to: r.lowerBound) >= 12 {
        line = String(line[..<r.lowerBound])
    }
    return line.truncated(max)
}

/// Esc in Claude Code doesn't fire Stop, but appends "[Request interrupted by user…]".
func transcriptEndsInInterrupt(_ path: String) -> Bool {
    guard let h = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? h.close() }
    guard let size = try? h.seekToEnd(), size > 0 else { return false }
    try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
    return text.split(separator: "\n").last?.contains("Request interrupted by user") ?? false
}

/// The last assistant text of the transcript (the turn's final message).
func finalAssistantText(_ path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let chunk: UInt64 = 2 << 20
    try? h.seek(toOffset: size > chunk ? size - chunk : 0)
    guard let data = try? h.readToEnd() else { return nil }
    for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
              let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        for block in content.reversed() where block["type"] as? String == "text" {
            if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        }
    }
    return nil
}

// MARK: - Sessions

enum SState: String { case working, waiting, done, resting }

struct Session {
    var id: String
    var state: SState
    var project: String
    var detail: String
    var lastEvent: Date
    var pid: pid_t?
    var doneAt: Date?
}

/// Reads the per-event files and works out every session's state.
final class SessionStore {
    private var summaries: [String: (Date, String)] = [:]   // id → (done mtime, headline)
    private var jsonCache: [String: (Date, [String: Any])] = [:]

    private func json(_ path: String, _ m: Date) -> [String: Any]? {
        if let c = jsonCache[path], c.0 == m { return c.1 }
        guard let j = readJSON(URL(fileURLWithPath: path)) else { return nil }
        jsonCache[path] = (m, j)
        return j
    }

    func summary(id: String, doneAt: Date, transcript: String?) -> String {
        if let s = summaries[id], s.0 == doneAt { return s.1 }
        let text = transcript.flatMap(finalAssistantText).map { headline($0, max: 90) } ?? ""
        let value = text.isEmpty ? "Tarea terminada" : text
        summaries[id] = (doneAt, value)
        return value
    }

    func load(now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }

        var events: [String: [String: Date]] = [:]
        var pids: [String: pid_t] = [:]
        for name in names where !name.hasPrefix(".") {
            let path = sessionsDir.appendingPathComponent(name).path
            guard let dot = name.firstIndex(of: ".") else {
                try? fm.removeItem(atPath: path)          // pre-1.1 format
                continue
            }
            let id = String(name[..<dot]), kind = String(name[name.index(after: dot)...])
            guard let m = mtime(path) else { continue }
            if kind == "pid" {
                if let s = try? String(contentsOfFile: path, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { pids[id] = p }
            } else {
                events[id, default: [:]][kind.replacingOccurrences(of: ".json", with: "")] = m
            }
        }

        var out: [Session] = []
        for (id, ev) in events {
            let path = { (kind: String) in sessionsDir.appendingPathComponent("\(id).\(kind)").path }
            let pid = pids[id]
            guard let (latestKind, latest) = ev.max(by: { $0.value < $1.value }) else { continue }

            // Owner process gone, or nothing for a day → forget the session.
            if let pid, pid > 1, kill(pid, 0) != 0, errno == ESRCH { remove(id); continue }
            if now.timeIntervalSince(latest) > pruneAfter { remove(id); continue }

            let prompt = ev["prompt"].flatMap { json(path("prompt.json"), $0) }
            let tool = ev["tool"].flatMap { json(path("tool.json"), $0) }
            let cwd = (prompt?["cwd"] ?? tool?["cwd"]) as? String
            let transcript = (prompt?["transcript_path"] ?? tool?["transcript_path"]) as? String
            let project = projectName(cwd: cwd)

            var state: SState
            switch latestKind {
            case "prompt", "tool", "posttool": state = .working
            case "waiting": state = .waiting
            case "done": state = now.timeIntervalSince(latest) < unseenExpiry ? .done : .resting
            default: state = .resting                   // seen / interrupted markers
            }

            if state == .working || state == .waiting, let t = transcript, let tm = mtime(t) {
                if tm > latest, transcriptEndsInInterrupt(t) {
                    touch(URL(fileURLWithPath: path("interrupted")))
                    state = .resting
                } else if state == .working, now.timeIntervalSince(max(tm, latest)) > staleAfter {
                    state = .resting
                }
            }

            var detail = ""
            let doneAt = ev["done"]
            switch state {
            case .working:
                detail = latestKind == "prompt" ? "Pensando…" : (describeTool(tool) ?? "Trabajando")
            case .waiting:
                detail = "Permiso: " + (describeTool(tool) ?? "una acción")
            case .done, .resting:
                if let d = doneAt { detail = summary(id: id, doneAt: d, transcript: transcript) }
            }
            out.append(Session(id: id, state: state, project: project, detail: detail, lastEvent: latest, pid: pid, doneAt: doneAt))
        }
        return out.sorted { $0.lastEvent > $1.lastEvent }
    }

    func markSeen(_ id: String) {
        touch(sessionsDir.appendingPathComponent("\(id).seen"))
    }

    private func remove(_ id: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: sessionsDir.path)) ?? [] where name.hasPrefix(id + ".") {
            try? fm.removeItem(at: sessionsDir.appendingPathComponent(name))
        }
        summaries[id] = nil
    }
}

// MARK: - Pet

struct TaskRecord: Codable { var project: String; var summary: String; var at: Double }

struct Pet: Codable {
    var xp = 0
    var food = 70.0          // "panza": filled by finished tasks, empties over time
    var joy = 70.0           // "ánimo": tasks and pets
    var updated = Date().timeIntervalSince1970
    var day = ""
    var today = 0
    var streak = 0
    var total = 0
    var lastPet = 0.0
    var last: TaskRecord?

    var level: Int { Int((Double(xp) / 30).squareRoot()) + 1 }
    var levelProgress: Double {
        let lo = 30 * (level - 1) * (level - 1), hi = 30 * level * level
        return Double(xp - lo) / Double(hi - lo)
    }

    static func load() -> Pet {
        guard let d = try? Data(contentsOf: petURL), let p = try? JSONDecoder().decode(Pet.self, from: d) else { return Pet() }
        return p
    }
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: petURL, options: .atomic)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    mutating func decay(now: Date = Date()) {
        let hours = max(0, now.timeIntervalSince1970 - updated) / 3600
        food = max(0, food - 5 * hours)
        joy = max(0, joy - 3 * hours)
        updated = now.timeIntervalSince1970
        if day != Pet.dayString(now) { today = 0 }
    }

    /// Returns true on level up.
    mutating func finished(project: String, summary: String, duration: TimeInterval, now: Date = Date()) -> Bool {
        decay(now: now)
        let before = level
        xp += 10 + min(30, Int(duration / 30))
        food = min(100, food + 22)
        joy = min(100, joy + 8)
        let todayStr = Pet.dayString(now)
        if day != todayStr {
            let yesterday = Pet.dayString(now.addingTimeInterval(-86400))
            streak = day == yesterday ? streak + 1 : 1
            day = todayStr
            today = 0
        }
        today += 1
        total += 1
        last = TaskRecord(project: project, summary: summary, at: now.timeIntervalSince1970)
        return level > before
    }

    mutating func petted(now: Date = Date()) {
        guard now.timeIntervalSince1970 - lastPet > 0.8 else { return }
        lastPet = now.timeIntervalSince1970
        joy = min(100, joy + 4)
    }

    func mood(active: Bool, lastActivity: Date?, now: Date = Date()) -> String {
        if !active {
            let hour = Calendar.current.component(.hour, from: now)
            let idleFor = lastActivity.map { now.timeIntervalSince($0) } ?? .infinity
            if hour < 7 || idleFor > 30 * 60 { return "sleep" }
        }
        if food < 25 { return "hungry" }
        if joy < 25 { return "sad" }
        if food > 50 && joy > 65 { return "happy" }
        return "ok"
    }
}

// MARK: - Window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Bridge: NSObject, WKScriptMessageHandler {
    var onMessage: ([String: Any]) -> Void = { _ in }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let body = m.body as? [String: Any] { onMessage(body) }
    }
}

final class NotchController: NSObject, WKNavigationDelegate {
    private let panel: NotchPanel
    private let web: NotchWebView
    private let bridge = Bridge()
    private let demo: Bool
    private let store = SessionStore()
    private var config = Config.load()
    private var configMTime = mtime(configURL.path)
    private var pet = Pet.load()

    private var loaded = false
    private var geometry: Geometry?
    private var shapeRect = NSRect.zero            // in panel coordinates, top-left origin
    private var sessions: [Session] = []
    private var lastModelJSON = ""
    private var knownStates: [String: SState] = [:]
    private var processedDone: [String: Date] = [:]
    private var firstScan = true

    private var hovering = false
    private var insideSince: Date?
    private var outsideSince: Date?

    private var dirSource: DispatchSourceFileSystemObject?
    private var timers: [Timer] = []

    init(demo: Bool) {
        self.demo = demo
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "native")
        web = NotchWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true            // click-through except while the pointer is on the shape
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = web
        super.init()

        bridge.onMessage = { [weak self] in self?.handle($0) }
        web.navigationDelegate = self
        if let html = Bundle.main.url(forResource: "notch", withExtension: "html") {
            let url = demo ? URL(string: html.absoluteString + "?demo")! : html
            web.loadFileURL(url, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            NSLog("ClaudeNotch: notch.html missing from bundle")
        }

        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        startTimers()
        if !demo { startWatching() }
    }

    // MARK: Layout

    @objc private func screensChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.layout()
            self?.panel.orderFrontRegardless()
        }
    }

    private func layout() {
        guard let screen = targetScreen() else { return }
        let g = notchGeometry(for: screen)
        guard g != geometry else { return }
        geometry = g
        panel.setFrame(g.frame, display: true)
        pushGeometry()
    }

    private func pushGeometry() {
        guard loaded, let g = geometry else { return }
        js("configure({width:\(g.frame.width),height:\(g.frame.height),notchWidth:\(g.notchWidth),notchHeight:\(g.notchHeight)})")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pushGeometry()
        lastModelJSON = ""
        if !demo { refresh() }
        if args.contains("--demo-hover") { hovering = true; js("setHover(true)") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload()
    }

    // MARK: Watching

    private func startWatching() {
        let fd = open(sessionsDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
            src.setEventHandler { [weak self] in self?.refresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }
        refresh()
    }

    private func startTimers() {
        // State upkeep: Esc interrupts, stuck sessions, unseen expiry, pet decay, config edits.
        let slow = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        slow.tolerance = 0.5
        // Pointer tracking: hover + click-through. NSEvent.mouseLocation needs no permissions.
        let fast = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.trackMouse() }
        fast.tolerance = 0.02
        for t in [slow, fast] { RunLoop.main.add(t, forMode: .common) }
        timers = [slow, fast]
    }

    private func tick() {
        if !demo { refresh() }
        if let m = mtime(configURL.path), m != configMTime {
            configMTime = m
            config = Config.load()
            lastModelJSON = ""
            refresh()
        }
    }

    // MARK: State

    private func refresh() {
        guard !demo else { return }
        let now = Date()
        sessions = store.load(now: now)

        // Finished turns → pet rewards + a one-line toast. Needs-you → toast.
        for s in sessions {
            let previous = knownStates[s.id]
            if let d = s.doneAt, d > (processedDone[s.id] ?? .distantPast) {
                processedDone[s.id] = d
                if !firstScan && s.state == .done {
                    let started = mtime(sessionsDir.appendingPathComponent("\(s.id).prompt.json").path) ?? d
                    _ = pet.finished(project: s.project, summary: s.detail, duration: d.timeIntervalSince(started))
                    pet.save()
                    notify(s)
                }
            }
            if !firstScan && s.state == .waiting && previous != .waiting { notify(s) }
            knownStates[s.id] = s.state
        }
        firstScan = false

        pet.decay(now: now)
        pushModel()
    }

    private func pushModel() {
        let active = sessions.contains { $0.state == .working || $0.state == .waiting }
        let lastActivity = sessions.map(\.lastEvent).max()
        let model: [String: Any] = [
            "sessions": sessions.map { ["id": $0.id, "project": $0.project, "state": $0.state.rawValue, "detail": $0.detail] },
            "pet": [
                "name": config.petName,
                "level": pet.level,
                "progress": pet.levelProgress,
                "mood": pet.mood(active: active, lastActivity: lastActivity),
                "food": Int(pet.food.rounded()),
                "joy": Int(pet.joy.rounded()),
                "streak": pet.streak,
                "today": pet.day == Pet.dayString(Date()) ? pet.today : 0,
            ],
            "last": pet.last.map { ["project": $0.project, "summary": $0.summary, "at": $0.at] } ?? NSNull(),
            "autoExpand": config.autoExpand,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: model), let json = String(data: data, encoding: .utf8) else { return }
        guard json != lastModelJSON else { return }
        lastModelJSON = json
        if loaded { js("update(\(json))") }
    }

    private func notify(_ s: Session) {
        let n: [String: Any] = ["id": s.id, "project": s.project, "state": s.state.rawValue, "detail": s.detail]
        guard loaded, let data = try? JSONSerialization.data(withJSONObject: n), let json = String(data: data, encoding: .utf8) else { return }
        pushModel()
        js("notify(\(json))")
    }

    // MARK: Pointer

    private func trackMouse() {
        guard let g = geometry, !args.contains("--demo-hover") else { return }
        let p = NSEvent.mouseLocation
        let f = panel.frame
        var r = shapeRect
        if r.width < 1 {
            // Hidden: the notch itself is the hot zone (or a small zone on notch-less screens).
            let w = max(g.notchWidth, 120)
            r = NSRect(x: (f.width - w) / 2, y: 0, width: w, height: g.notchHeight)
        }
        let screenRect = NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height).insetBy(dx: -2, dy: -2)
        let inside = screenRect.contains(p)

        // Only swallow clicks while the pointer is actually over the shape.
        let shouldIgnore = !(inside && hovering)
        if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }

        let now = Date()
        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if !hovering, now.timeIntervalSince(insideSince!) > 0.18 { setHover(true) }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if hovering, now.timeIntervalSince(outsideSince!) > 0.35 { setHover(false) }
        }
    }

    private func setHover(_ on: Bool) {
        hovering = on
        js("setHover(\(on))")
        if !on {
            // Looking at the list counts as having seen what finished.
            var changed = false
            for s in sessions where s.state == .done { store.markSeen(s.id); changed = true }
            if changed { refresh() }
        }
    }

    // MARK: Messages from the page

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "rect":
            if let x = msg["x"] as? Double, let y = msg["y"] as? Double, let w = msg["w"] as? Double, let h = msg["h"] as? Double {
                shapeRect = NSRect(x: x, y: y, width: w, height: h)
            }
        case "pet":
            pet.petted()
            pet.save()
            pushModel()
        case "focus":
            guard let id = msg["id"] as? String else { return }
            if let s = sessions.first(where: { $0.id == id }) {
                if s.state == .done { store.markSeen(id) }
                if let pid = s.pid { focusApp(owning: pid) }
            }
            refresh()
        default:
            break
        }
    }

    private func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }
}

// MARK: - Focusing the app that runs a session

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let pp = info.kp_eproc.e_ppid
    return pp > 1 ? pp : nil
}

/// Walks up from the claude process to the GUI app hosting it (Terminal, iTerm, VS Code, Claude…).
func focusApp(owning pid: pid_t) {
    var current: pid_t? = pid
    for _ in 0..<12 {
        guard let p = current else { return }
        if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular, let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return
        }
        current = parentPid(p)
    }
}

// MARK: - Hook installer (merges into ~/.claude/settings.json)

let hookMarker = "notch-hook.sh"

let ourHooks: [(event: String, matcher: String?, arg: String)] = [
    ("UserPromptSubmit", nil, "prompt"),
    ("PreToolUse", "*", "tool"),
    ("PostToolUse", "*", "posttool"),
    ("Notification", "permission_prompt|elicitation_dialog", "waiting"),
    ("Stop", nil, "done"),
    ("SessionEnd", nil, "end"),
]

func updateSettings(install: Bool) throws {
    let fm = FileManager.default
    var root: [String: Any] = [:]
    if fm.fileExists(atPath: settingsURL.path) {
        let data = try Data(contentsOf: settingsURL)
        if !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ClaudeNotch", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object"])
            }
            root = obj
        }
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.claude-notch.bak")
        try? fm.removeItem(at: backup)
        try fm.copyItem(at: settingsURL, to: backup)
    }

    var hooks = root["hooks"] as? [String: Any] ?? [:]

    // Strip previous Claude Notch entries, leaving everything else untouched.
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { continue }
        var kept: [[String: Any]] = []
        for var group in groups {
            let entries = group["hooks"] as? [[String: Any]] ?? []
            let others = entries.filter { !(($0["command"] as? String)?.contains(hookMarker) ?? false) }
            if others.count == entries.count { kept.append(group); continue }
            if others.isEmpty { continue }
            group["hooks"] = others
            kept.append(group)
        }
        hooks[event] = kept.isEmpty ? nil : kept
    }

    if install {
        for h in ourHooks {
            let cmd: [String: Any] = ["type": "command", "command": "\"$HOME/.claude/notch/notch-hook.sh\" \(h.arg)", "timeout": 5]
            var group: [String: Any] = ["hooks": [cmd]]
            if let m = h.matcher { group["matcher"] = m }
            hooks[h.event] = (hooks[h.event] as? [[String: Any]] ?? []) + [group]
        }
    }

    root["hooks"] = hooks.isEmpty ? nil : hooks
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: settingsURL, options: .atomic)
}

// MARK: - Main

let args = CommandLine.arguments

if args.contains("--install-hooks") || args.contains("--uninstall-hooks") {
    let install = args.contains("--install-hooks")
    do {
        try updateSettings(install: install)
        print(install ? "Hooks installed in \(settingsURL.path)" : "Hooks removed from \(settingsURL.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("ClaudeNotch: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Single instance.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0)
}

try? FileManager.default.createDirectory(at: notchDir, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
let controller = NotchController(demo: args.contains("--demo"))
app.run()
