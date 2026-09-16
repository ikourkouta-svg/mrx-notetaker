// MRX Notetaker for macOS 14.2+: records calls automatically, no bot joins the meeting.
//
// When a meeting app (Teams, Zoom, a browser) starts using the microphone, records two tracks:
//   mic.m4a     the microphone (you)
//   system.m4a  everything the Mac plays (everyone else), via a Core Audio process tap
// and 45 s after the app releases the microphone writes session.json LAST and moves the folder
// into the OneDrive folder "MRX-Notetaker", where the transcription server picks it up.
//
// Usage: MRXNotetaker --user costas@mrexporttoafrica.com [--selftest]

import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let version = 1
let folderName = "MRX-Notetaker"
let poll: TimeInterval = 3
let grace: TimeInterval = 45
// Prefix match, so helper processes (com.microsoft.teams2.helper, com.google.Chrome.helper) count too.
// WhatsApp, FaceTime and Viber are deliberately absent: personal calls are never recorded.
let meetingApps = ["com.microsoft.teams", "us.zoom", "com.google.Chrome", "com.microsoft.edgemac",
                   "com.apple.Safari", "org.mozilla.firefox", "com.cisco.webex", "com.brave.Browser"]

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MRXNotetaker")
let recordingDir = support.appendingPathComponent("recording")
let outboxDir = support.appendingPathComponent("outbox")

struct NTError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ s: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(s)")
}

// MARK: Core Audio helpers

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func readUInt32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

/// Bundle id of a meeting app currently using the microphone, or nil.
func meetingAppOnMic() -> String? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids where readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1 {
        if let bundle = readString(id, kAudioProcessPropertyBundleID), meetingApps.contains(where: { bundle.hasPrefix($0) }) {
            return bundle
        }
    }
    return nil
}

func aacSettings(_ format: AVAudioFormat) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
     AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 32000 * Int(format.channelCount)]
}

// MARK: Recorders

/// Everything the Mac plays: a global process tap wrapped in a private aggregate device.
final class SystemRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "mrx.systemtap")

    func start(_ url: URL) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        var status = AudioHardwareCreateProcessTap(tap, &tapID)
        guard status == noErr else { throw NTError("process tap failed (\(status))") }

        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { throw NTError("tap format failed (\(status))") }

        guard let outputID = readUInt32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice),
              let outputUID = readString(outputID, kAudioDevicePropertyDeviceUID) else { throw NTError("no output device") }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MRXNotetakerTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { throw NTError("aggregate device failed (\(status))") }

        let file = try AVAudioFile(forWriting: url, settings: aacSettings(format), commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.file = file
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) {
                try? file.write(from: buffer)
            }
        }
        guard status == noErr else { throw NTError("io proc failed (\(status))") }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw NTError("device start failed (\(status))") }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        queue.sync { file = nil }  // releasing AVAudioFile finalises the m4a
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}

final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()

    func start(_ url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NTError("no microphone") }
        let file = try AVAudioFile(forWriting: url, settings: aacSettings(format), commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.lock.lock()
            try? self?.file?.write(from: buffer)
            self?.lock.unlock()
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        lock.unlock()
    }
}

// MARK: Sessions

func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

final class Session {
    let user: String, selftest: Bool, started = Date()
    let dir: URL
    let mic = MicRecorder(), system = SystemRecorder()

    init(user: String, selftest: Bool) throws {
        self.user = user
        self.selftest = selftest
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.timeZone = TimeZone(identifier: "UTC")
        let name = "\(user.split(separator: "@")[0])_\(selftest ? "selftest_" : "")\(stamp.string(from: started))"
        dir = recordingDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Each track is independent: a missing permission on one must not lose the other.
        do { try mic.start(dir.appendingPathComponent("mic.m4a")) } catch { log("mic: \(error)") }
        do { try system.start(dir.appendingPathComponent("system.m4a")) } catch { log("system audio: \(error)") }
        log("recording \(name)")
    }

    /// The user chose "Stop and delete this recording": nothing is kept or uploaded.
    func discard() {
        mic.stop()
        system.stop()
        try? FileManager.default.removeItem(at: dir)
        log("recording deleted by the user")
    }

    func finish() {
        mic.stop()
        system.stop()
        let fm = FileManager.default
        var files: [String: Int] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            files[f] = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(f).path)[.size] as? Int) ?? 0
        }
        // "files" lets the server wait until OneDrive has uploaded every track, not just session.json.
        let meta: [String: Any] = ["user": user, "host": Host.current().localizedName ?? "mac", "source": "mac",
                                   "version": version, "selftest": selftest, "started": iso(started), "ended": iso(Date()), "files": files]
        do {
            try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("session.json"))
            try fm.createDirectory(at: outboxDir, withIntermediateDirectories: true)
            try fm.moveItem(at: dir, to: outboxDir.appendingPathComponent(dir.lastPathComponent))
            log("saved \(dir.lastPathComponent) \(files)")
        } catch { log("save failed: \(error)") }
    }
}

func oneDriveFolder() -> URL? {
    let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    for entry in (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? [] where entry.hasPrefix("OneDrive") {
        let candidate = cloud.appendingPathComponent(entry).appendingPathComponent(folderName)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// Moves finished sessions into OneDrive; anything that fails stays in the outbox for the next try.
func flushOutbox() {
    let fm = FileManager.default
    guard let pending = try? fm.contentsOfDirectory(atPath: outboxDir.path), !pending.isEmpty else { return }
    guard let target = oneDriveFolder() else {
        log("OneDrive folder \(folderName) not found; \(pending.count) session(s) waiting")
        return
    }
    for name in pending where !name.hasPrefix(".") {
        let src = outboxDir.appendingPathComponent(name), dest = target.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            // Audio first, session.json last, so the server never sees a manifest before its tracks.
            let tracks = try fm.contentsOfDirectory(atPath: src.path).filter { $0 != "session.json" }
            for f in tracks + ["session.json"] {
                let to = dest.appendingPathComponent(f)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: src.appendingPathComponent(f), to: to)
            }
            try fm.removeItem(at: src)
            log("uploaded \(name)")
        } catch { log("upload \(name) failed: \(error)") }
    }
}

// MARK: Main

let args = CommandLine.arguments
guard let userIndex = args.firstIndex(of: "--user"), userIndex + 1 < args.count else {
    print("usage: MRXNotetaker --user EMAIL [--selftest]")
    exit(2)
}
let user = args[userIndex + 1]
let permission = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .audio) { granted in
    log("microphone permission: \(granted ? "granted" : "DENIED")")
    permission.signal()
}
permission.wait()

if args.contains("--selftest") {
    log("self-test: recording 10 seconds, speak and play any video with sound now")
    do {
        let session = try Session(user: user, selftest: true)
        Thread.sleep(forTimeInterval: 10)
        session.finish()
    } catch { log("self-test failed: \(error)") }
    flushOutbox()
    log(oneDriveFolder() == nil ? "SELF-TEST NOT UPLOADED: OneDrive folder \(folderName) is missing" : "self-test done")
    exit(0)
}

log("MRX Notetaker v\(version) watching for calls as \(user)")
var current: Session?
var skipThisCall = false  // set when the user deletes a recording; cleared when that call ends
var lastSeen = Date.distantPast

// Menu bar indicator, so it is always visible whether a call is being recorded.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
final class MenuActions: NSObject {
    @MainActor @objc func discard() {
        current?.discard()
        current = nil
        skipThisCall = true
        refreshStatus()
    }
}
let actions = MenuActions()
let discardItem = NSMenuItem(title: "Stop and delete this recording", action: #selector(MenuActions.discard), keyEquivalent: "")
discardItem.target = actions
let menu = NSMenu()
menu.autoenablesItems = false
stateLine.isEnabled = false
menu.addItem(stateLine)
menu.addItem(discardItem)
statusItem.menu = menu

@MainActor func refreshStatus() {
    if let session = current {
        let time = DateFormatter.localizedString(from: session.started, dateStyle: .none, timeStyle: .short)
        statusItem.button?.attributedTitle = NSAttributedString(string: "\u{25CF} REC", attributes: [.foregroundColor: NSColor.systemRed])
        stateLine.title = "Recording this call since \(time)"
        discardItem.isHidden = false
    } else {
        statusItem.button?.attributedTitle = NSAttributedString(string: "MRX", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        stateLine.title = skipThisCall ? "Not recording this call (you deleted it)" : "Not recording. Waiting for a Teams or Zoom call"
        discardItem.isHidden = true
    }
}

// Timers are scheduled on the main run loop, so their closures run on the main thread.
Timer.scheduledTimer(withTimeInterval: poll, repeats: true) { _ in MainActor.assumeIsolated {
    if let app = meetingAppOnMic() {
        lastSeen = Date()
        if current == nil && !skipThisCall {
            log("call detected (\(app))")
            current = try? Session(user: user, selftest: false)
        }
    } else if Date().timeIntervalSince(lastSeen) > grace {
        current?.finish()
        current = nil
        skipThisCall = false
    }
    refreshStatus()
} }
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    if current == nil { flushOutbox() }
}
flushOutbox()
refreshStatus()
app.run()
