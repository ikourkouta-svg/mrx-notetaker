// Live copilot for macOS: transcribes the call as it happens and advises what to say next.
//
// Arms only for Teams, Zoom and Webex desktop apps. Browser calls are deliberately excluded: telling
// a meeting tab from WhatsApp Web needs window titles, which needs the Screen Recording permission
// that this app is built to avoid.
//
// Transcription runs locally with the bundled whisper.cpp (Metal), and ONLY when advice is asked
// for: the last few minutes of the call are held in memory and transcribed on the press, so the
// machine is idle the rest of the time. Transcribing continuously made Costas's MacBook hot and
// left it grinding through a backlog for minutes after the call (1 Oct 2026).
// Advice goes to the MRX endpoint, which holds the Gemini key, so no key is ever on the laptop.
// Enabled only when copilot.json exists.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

let copilotConfig = support.appendingPathComponent("copilot.json")
let adviceWindowSeconds = 120.0   // how much of the call the advice is based on
let copilotApps = ["com.microsoft.teams", "us.zoom", "com.cisco.webex"]

struct CopilotSettings {
    let endpoint: String, token: String, model: String

    static func load() -> CopilotSettings? {
        guard let data = try? Data(contentsOf: copilotConfig),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = j["endpoint"] as? String, let token = j["token"] as? String else { return nil }
        let model = (j["model"] as? String) ?? support.appendingPathComponent("whisper-model.bin").path
        // The brief (our prices and rules) lives on the server, never on a laptop.
        return CopilotSettings(endpoint: endpoint, token: token, model: model)
    }
}

/// Keeps the last `adviceWindowSeconds` of one side of the call in memory as 16 kHz mono samples,
/// and writes them to a WAV only when advice is asked for. Nothing is transcribed until then.
final class RollingAudio {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var limit: Int { Int(16000 * adviceWindowSeconds) }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var pending: AVAudioPCMBuffer? = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            status.pointee = pending == nil ? .noDataNow : .haveData
            defer { pending = nil }
            return pending
        }
        guard error == nil, out.frameLength > 0, let data = out.int16ChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }

    /// Writes what is held to `url`. Returns the seconds written, 0 when there is nothing.
    func snapshot(to url: URL) -> Double {
        lock.lock()
        let held = samples
        lock.unlock()
        guard !held.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(held.count)),
              let out = buffer.int16ChannelData else { return 0 }
        held.withUnsafeBufferPointer { out[0].update(from: $0.baseAddress!, count: held.count) }
        buffer.frameLength = AVAudioFrameCount(held.count)
        guard let file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: true), (try? file.write(from: buffer)) != nil else { return 0 }
        return Double(held.count) / 16000
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

final class Copilot: NSObject {
    private let settings: CopilotSettings
    private let whisper: URL
    private let queue = DispatchQueue(label: "mrx.copilot.transcribe")
    private var busy = false, sentToday = 0, day = ""
    private let panel: NSPanel
    private let body: NSTextField
    private let status: NSTextField
    let micAudio = RollingAudio(), systemAudio = RollingAudio()
    private let workDir: URL

    init?(chunkDir: URL) {
        guard let settings = CopilotSettings.load(),
              let whisper = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
              FileManager.default.fileExists(atPath: settings.model) else { return nil }
        self.settings = settings
        self.whisper = whisper
        workDir = chunkDir
        try? FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

        panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 460, height: 230),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "MRX Copilot"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1)
        body = NSTextField(wrappingLabelWithString: "listening...")
        body.font = .systemFont(ofSize: 14)
        body.textColor = .white
        body.backgroundColor = .clear
        body.isBezeled = false
        status = NSTextField(labelWithString: "fn+F9 advice   fn+F10 hide")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.backgroundColor = .clear
        status.isBezeled = false
        super.init()

        // Buttons as well as hotkeys: on a MacBook the top row is media keys, so F9 alone does
        // nothing and the keys are easy to miss. A nonactivating panel takes the click without
        // stealing focus from Teams.
        let advice = NSButton(title: "Advice", target: self, action: #selector(adviceClicked))
        let hide = NSButton(title: "Hide", target: self, action: #selector(hideClicked))
        for b in [advice, hide] { b.bezelStyle = .rounded }
        let row = NSStackView(views: [advice, hide])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [body, status, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.contentView = stack

        registerHotKeys()
    }

    // MARK: transcription

    /// Transcribes one side and returns its lines as (second in the clip, text). Timestamps are
    /// kept so both sides can be merged back into the order they were actually said.
    private func transcribe(_ url: URL, speaker: String) -> [(Double, String)] {
        let p = Process()
        p.executableURL = whisper
        p.arguments = ["-m", settings.model, "-f", url.path, "-l", "auto", "-np", "-t", "4"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("whisper failed: \(error)"); return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: url)
        var lines: [(Double, String)] = []
        // whisper.cpp prints "[00:00:04.000 --> 00:00:07.000]   text"
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+):(\d+)\.\d+ --> [^\]]+\]\s*(.+)"#)
        for line in out.split(separator: "\n") {
            let text = String(line)
            guard let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func part(_ i: Int) -> String { String(text[Range(m.range(at: i), in: text)!]) }
            let said = part(4).trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { continue }
            lines.append(((Double(part(1)) ?? 0) * 3600 + (Double(part(2)) ?? 0) * 60 + (Double(part(3)) ?? 0),
                          "\(speaker): \(said)"))
        }
        return lines
    }

    /// The last minutes of the call, both sides, transcribed now. Runs off the main thread.
    private func transcript() -> String {
        let mic = workDir.appendingPathComponent("me.wav"), system = workDir.appendingPathComponent("them.wav")
        try? FileManager.default.removeItem(at: mic)
        try? FileManager.default.removeItem(at: system)
        var lines: [(Double, String)] = []
        if micAudio.snapshot(to: mic) > 1 { lines += transcribe(mic, speaker: "Me") }
        if systemAudio.snapshot(to: system) > 1 { lines += transcribe(system, speaker: "Them") }
        return lines.sorted { $0.0 < $1.0 }.map { $0.1 }.joined(separator: "\n")
    }

    // MARK: advice

    func advise(reason: String = "") {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        if today != day { day = today; sentToday = 0 }
        guard !busy, sentToday < 200 else { return }
        busy = true
        sentToday += 1
        show("listening back...", reason)
        // Transcribing happens here, on the press, not throughout the call.
        queue.async { [self] in
            let text = transcript()
            guard !text.isEmpty else {
                busy = false
                return show("(nothing heard yet)", "")
            }
            ask(text, reason: reason)
        }
    }

    private func ask(_ text: String, reason: String) {
        show("thinking...", reason)
        var request = URLRequest(url: URL(string: settings.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": settings.token, "transcript": text])
        let started = Date()
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            busy = false
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answer = j["text"] as? String {
                show(answer, String(format: "%.0fs %@", Date().timeIntervalSince(started), reason))
            } else {
                show("advice unavailable (\(error?.localizedDescription ?? "no answer"))", "")
            }
        }.resume()
    }

    private func show(_ text: String, _ note: String) {
        DispatchQueue.main.async { [self] in
            body.stringValue = text
            status.stringValue = "fn+F9 advice   fn+F10 hide    \(note)"
        }
    }

    @objc private func adviceClicked() { advise(reason: "button") }

    @objc private func hideClicked() { panel.orderOut(nil) }

    // MARK: window and keys

    func callStarted() {
        DispatchQueue.main.async { [self] in
            show("listening...", "call started")
            panel.orderFrontRegardless()
        }
    }

    func callEnded() {
        micAudio.clear()
        systemAudio.clear()
        DispatchQueue.main.async { [self] in panel.orderOut(nil) }
    }

    private func registerHotKeys() {
        var handler: EventHandlerRef?
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            NotificationCenter.default.post(name: .copilotHotKey, object: nil, userInfo: ["id": hotKeyID.id])
            return noErr
        }, 1, &spec, nil, &handler)
        for (id, code) in [(1, kVK_F9), (2, kVK_F10)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x4D525831), id: UInt32(id)),
                                GetApplicationEventTarget(), 0, &ref)
        }
        NotificationCenter.default.addObserver(forName: .copilotHotKey, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? UInt32 else { return }
            if id == 1 { advise(reason: "F9") } else { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }
        }
    }
}

extension Notification.Name {
    static let copilotHotKey = Notification.Name("mrx.copilot.hotkey")
}
