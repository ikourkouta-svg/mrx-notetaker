// Live copilot for macOS: transcribes the call as it happens and advises what to say next.
//
// Arms only for Teams, Zoom and Webex desktop apps. Browser calls are deliberately excluded: telling
// a meeting tab from WhatsApp Web needs window titles, which needs the Screen Recording permission
// that this app is built to avoid.
//
// Transcription runs locally with the bundled whisper.cpp (Metal). Advice goes to the MRX endpoint,
// which holds the Gemini key, so no key is ever on the laptop. Enabled only when copilot.json exists.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation

let copilotConfig = support.appendingPathComponent("copilot.json")
let chunkSeconds = 10.0
let adviceWindowMinutes = 4.0
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

/// Writes the call to 10 second 16 kHz mono WAV files, which is what whisper.cpp expects.
final class ChunkWriter {
    private let dir: URL, prefix: String
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var started = Date.distantPast
    private var index = 0
    private let lock = NSLock()
    var onChunk: ((URL) -> Void)?

    init(dir: URL, prefix: String) {
        self.dir = dir
        self.prefix = prefix
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

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
        if error != nil || out.frameLength == 0 { return }
        if Date().timeIntervalSince(started) > chunkSeconds { rotate() }
        try? file?.write(from: out)
    }

    private func rotate() {
        if let done = file?.url {
            file = nil
            onChunk?(done)
        }
        index += 1
        started = Date()
        let url = dir.appendingPathComponent("\(prefix)_\(String(format: "%05d", index)).wav")
        file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if let done = file?.url {
            file = nil
            onChunk?(done)
        }
    }
}

final class Copilot {
    private let settings: CopilotSettings
    private let whisper: URL
    private let queue = DispatchQueue(label: "mrx.copilot.transcribe")
    private var lines: [(Date, String, String)] = []
    private let lock = NSLock()
    private var busy = false, lastAuto = Date.distantPast, sentToday = 0, day = ""
    private let panel: NSPanel
    private let body: NSTextField
    private let status: NSTextField
    let micChunks: ChunkWriter, systemChunks: ChunkWriter

    // Objection phrases: the same list the Linux copilot uses, spaces intact.
    static let triggers = ["budget", "too expensive", "expensive", "discount", "cheaper", "price", "cost",
                           "competitor", "another agency", "we already work", "proof", "case stud", "reference",
                           "guarantee", "board", "procurement", "contract", "think about it", "get back to you",
                           "not sure", "risk", "ακριβ", "προϋπολογισμ", "έκπτωση", "κόστος", "τιμή", "εγγύηση",
                           "συμβόλαιο", "ρίσκο", "θα το σκεφτ", "θα σας πω", "δεν είμαι σίγουρ"]

    init?(chunkDir: URL) {
        guard let settings = CopilotSettings.load(),
              let whisper = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
              FileManager.default.fileExists(atPath: settings.model) else { return nil }
        self.settings = settings
        self.whisper = whisper
        micChunks = ChunkWriter(dir: chunkDir, prefix: "me")
        systemChunks = ChunkWriter(dir: chunkDir, prefix: "them")

        panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 460, height: 190),
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
        status = NSTextField(labelWithString: "F9 advice   F10 hide")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.backgroundColor = .clear
        status.isBezeled = false
        let stack = NSStackView(views: [body, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        panel.contentView = stack

        micChunks.onChunk = { [weak self] url in self?.transcribe(url, speaker: "Me") }
        systemChunks.onChunk = { [weak self] url in self?.transcribe(url, speaker: "Them") }
        registerHotKeys()
    }

    // MARK: transcription

    private func transcribe(_ url: URL, speaker: String) {
        queue.async { [self] in
            let p = Process()
            p.executableURL = whisper
            p.arguments = ["-m", settings.model, "-f", url.path, "-l", "auto", "-nt", "-np", "-t", "4"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return log("whisper failed: \(error)") }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            try? FileManager.default.removeItem(at: url)
            let text = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[") }.joined(separator: " ")
            guard !text.isEmpty else { return }
            lock.lock()
            lines.append((Date(), speaker, text))
            lock.unlock()
            log("\(speaker): \(text)")
            if speaker == "Them" { autoAdvise(text) }
        }
    }

    private func transcript() -> String {
        let cutoff = Date().addingTimeInterval(-adviceWindowMinutes * 60)
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { $0.0 >= cutoff }.map { "\($0.1): \($0.2)" }.joined(separator: "\n")
    }

    // MARK: advice

    private func autoAdvise(_ text: String) {
        let lower = text.lowercased()
        guard Copilot.triggers.contains(where: { lower.contains($0) }),
              Date().timeIntervalSince(lastAuto) > 45 else { return }
        lastAuto = Date()
        advise(reason: "objection heard")
    }

    func advise(reason: String = "") {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        if today != day { day = today; sentToday = 0 }
        guard !busy, sentToday < 200 else { return }
        let text = transcript()
        guard !text.isEmpty else { return show("(nothing heard yet)", "") }
        busy = true
        sentToday += 1
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
            status.stringValue = "F9 advice   F10 hide    \(note)"
        }
    }

    // MARK: window and keys

    func callStarted() {
        DispatchQueue.main.async { [self] in
            show("listening...", "call started")
            panel.orderFrontRegardless()
        }
    }

    func callEnded() {
        micChunks.finish()
        systemChunks.finish()
        lock.lock()
        lines.removeAll()
        lock.unlock()
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
