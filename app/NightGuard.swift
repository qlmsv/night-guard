// Night Guard — menu bar app. A thin UI over the `nightguard` CLI (~/.night-guard/nightguard).
import SwiftUI
import AppKit
import ServiceManagement

struct NGStatus: Decodable, Equatable {
    var version = "", start = "23:00", end = "07:00", now = "--:--"
    var enabled = true, in_window = false, blocking = false
    var pause_left = 0, pause_max = 30, blocks_today = 0
    var claude_present = false, claude_installed = false
    var codex_present = false, codex_installed = false
}

@MainActor
final class Model: ObservableObject {
    @Published var s = NGStatus()
    @Published var cliMissing = false
    @Published var message: String?
    @Published var isError = false
    @Published var start = Date()
    @Published var end = Date()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timer: Timer?
    private var editedSchedule = false

    nonisolated static let cli = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".night-guard/nightguard").path
    static let phrase = "я осознанно работаю ночью"

    init() {
        // Defer the first refresh: never touch @Published state while SwiftUI is building the scene.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Runs the CLI on a background thread. Waiting on the main thread would spin the run loop
    /// in the middle of a SwiftUI update and crash (AttributeGraph precondition failure).
    func run(_ args: [String], env: [String: String] = [:]) async -> (Int32, String) {
        await Task.detached { Model.exec(args, env: env) }.value
    }

    nonisolated static func exec(_ args: [String], env: [String: String]) -> (Int32, String) {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return (127, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cli] + args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        e.merge(env) { $1 }
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, out)
    }

    func refresh() {
        Task {
            let (code, out) = await run(["status", "--json"])
            if code == 127 { cliMissing = true; return }
            guard code == 0, let st = try? JSONDecoder().decode(NGStatus.self, from: Data(out.utf8)) else { return }
            cliMissing = false
            if st != s { s = st }
            if !editedSchedule { start = Self.date(st.start); end = Self.date(st.end) }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func act(_ args: [String], env: [String: String] = [:]) {
        Task {
            let (code, out) = await run(args, env: env)
            isError = code != 0
            message = out.split(separator: "\n").first.map {
                String($0).replacingOccurrences(of: "✓ ", with: "").replacingOccurrences(of: "✗ ", with: "")
            }
            if code == 0 { editedSchedule = false }
            refresh()
        }
    }

    func scheduleEdited() { editedSchedule = true }
    var scheduleDirty: Bool { Self.hm(start) != s.start || Self.hm(end) != s.end }
    func saveSchedule() { editedSchedule = false; act(["schedule", Self.hm(start), Self.hm(end)]) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch { isError = true; message = "Автозапуск: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func date(_ hm: String) -> Date {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var pausing = false
    @State private var phrase = ""
    @State private var pauseMinutes = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if m.cliMissing { missingCLI } else {
                Divider()
                schedule
                Divider()
                agents
                if m.s.blocking { Divider(); pause }
                if let msg = m.message {
                    Text(msg).font(.caption).foregroundStyle(m.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { m.refresh() }
    }

    var state: (icon: String, title: String, color: Color) {
        if !m.s.enabled { return ("moon.circle", "Выключен", .secondary) }
        if m.s.blocking { return ("moon.zzz.fill", "Ночь — агенты спят", .indigo) }
        if m.s.pause_left > 0 { return ("pause.circle.fill", "Пауза · ещё \(m.s.pause_left / 60 + 1) мин", .orange) }
        return ("sun.max.fill", "День — можно работать", .orange)
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: state.icon).font(.system(size: 30)).foregroundStyle(state.color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.headline)
                Text("Сейчас \(m.s.now) · блокировок сегодня: \(m.s.blocks_today)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var schedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Расписание").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { m.s.enabled }, set: { m.act([$0 ? "on" : "off"]) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(m.s.blocking && m.s.enabled)
                    .help(m.s.blocking ? "Ночью выключить нельзя" : "Включить или выключить Night Guard")
            }
            HStack {
                DatePicker("С", selection: Binding(get: { m.start }, set: { m.start = $0; m.scheduleEdited() }),
                           displayedComponents: .hourAndMinute)
                DatePicker("до", selection: Binding(get: { m.end }, set: { m.end = $0; m.scheduleEdited() }),
                           displayedComponents: .hourAndMinute)
                Spacer()
                if m.scheduleDirty {
                    Button("Сохранить") { m.saveSchedule() }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .disabled(m.s.blocking)
            if m.s.blocking {
                Label("Ночью расписание менять нельзя", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Агенты").font(.subheadline.weight(.semibold))
            agentRow("Claude Code", present: m.s.claude_present, installed: m.s.claude_installed, key: "claude")
            agentRow("Codex", present: m.s.codex_present, installed: m.s.codex_installed, key: "codex")
            if m.s.codex_installed {
                Text("В Codex один раз выполни /hooks и доверь хукам Night Guard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func agentRow(_ name: String, present: Bool, installed: Bool, key: String) -> some View {
        HStack {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
            Text(name)
            Spacer()
            if !present {
                Text("не найден").font(.caption).foregroundStyle(.secondary)
            } else if installed {
                Button("Отключить") { m.act(["uninstall", key]) }.controlSize(.small)
                    .disabled(m.s.blocking).help(m.s.blocking ? "Ночью отключать нельзя" : "")
            } else {
                Button("Подключить") { m.act(["install", key]) }.controlSize(.small)
            }
        }
    }

    var pause: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pausing {
                Button { pausing = true } label: { Label("Экстренная пауза…", systemImage: "pause.circle") }
                    .controlSize(.small)
                Text("Один раз за ночь, до \(m.s.pause_max) мин.").font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("На \(pauseMinutes) мин", value: $pauseMinutes, in: 1...max(1, m.s.pause_max), step: 5)
                Text("Напиши: «\(Model.phrase)»").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $phrase).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Отмена") { pausing = false; phrase = "" }
                    Spacer()
                    Button("Поставить паузу") {
                        m.act(["pause", String(pauseMinutes)], env: ["NG_PHRASE": phrase])
                        pausing = false; phrase = ""
                    }
                    .disabled(phrase.trimmingCharacters(in: .whitespaces) != Model.phrase)
                }.controlSize(.small)
            }
        }
    }

    var missingCLI: some View {
        Text("Не найден ~/.night-guard/nightguard. Установи Night Guard: ./install.sh в папке репозитория.")
            .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    var footer: some View {
        HStack {
            Toggle("Автозапуск", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).controlSize(.small)
            Spacer()
            Button("Журнал") {
                let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".night-guard/blocked.log")
                if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
                else { m.isError = false; m.message = "Журнал пока пуст — ни одной блокировки." }
            }.controlSize(.small)
            Button("Выход") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}

@main
struct NightGuardApp: App {
    @StateObject private var model = Model()

    init() {
        // `--preview`: show the panel in a regular window (handy for screenshots and debugging).
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.async {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "Night Guard"
                w.contentView = NSHostingView(rootView: ContentView().environmentObject(PreviewHolder.model))
                w.setContentSize(w.contentView!.fittingSize); w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                PreviewHolder.window = w
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: model.s.blocking ? "moon.zzz.fill" : (model.s.enabled ? "moon" : "moon.circle"))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor enum PreviewHolder {
    static let model = Model()
    static var window: NSWindow?
}
