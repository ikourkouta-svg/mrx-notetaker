// Graph uploader: the way out when the OneDrive sync folder is not on this Mac.
//
// Costas' MacBook sat on 12 finished recordings for two weeks (16 Sep to 2 Oct 2026) because
// OneDrive never materialised the shared folder locally, and flushOutbox() had no other route.
// This file adds that route: a one-time device-code sign-in by the user, then every session is
// PUT straight into the same shared OneDrive folder over HTTPS. The sync folder stays the fast
// path; this runs only when the folder is missing.

import Foundation

let graphClientID = "0e26074c-2b3f-4061-8d83-67f00a5e8e0a"
let graphScope = "offline_access https://graph.microsoft.com/Files.ReadWrite.All"
let graphAuthority = "https://login.microsoftonline.com/organizations/oauth2/v2.0"
let graphRoot = "https://graph.microsoft.com/v1.0"
let graphStore = support.appendingPathComponent("graph.json")
let graphQueue = DispatchQueue(label: "com.mrx.notetaker.graph")
let chunkSize = 8 * 1024 * 1024          // 8 MiB, a multiple of 320 KiB as Graph requires
let simpleLimit = 4 * 1024 * 1024        // above this Graph wants an upload session
var graphBusy = false                    // one upload at a time, checked on the main thread
var graphAccess: (token: String, until: Date)?

// MARK: small HTTP and JSON helpers

/// Blocking request. Every caller already runs on graphQueue, never on the main thread.
func httpSync(_ request: URLRequest) -> (status: Int, body: Data)? {
    var out: (Int, Data)?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse { out = (http.statusCode, data ?? Data()) }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 600)
    return out
}

func jsonBody(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func formEncoded(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let parts: [String] = fields.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }
    return parts.joined(separator: "&").data(using: .utf8) ?? Data()
}

func postForm(_ path: String, _ fields: [String: String]) -> (status: Int, json: [String: Any]) {
    var request = URLRequest(url: URL(string: "\(graphAuthority)/\(path)")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncoded(fields)
    guard let result = httpSync(request) else { return (0, [:]) }
    return (result.status, jsonBody(result.body))
}

func graphSettings() -> [String: Any] {
    guard let data = try? Data(contentsOf: graphStore) else { return [:] }
    return jsonBody(data)
}

func saveGraphSettings(_ settings: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return }
    try? data.write(to: graphStore)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: graphStore.path)
}

// MARK: sign-in

/// Device-code sign-in. Prints the code and blocks until the user finishes or the code expires.
func graphLogin() -> Bool {
    let start = postForm("devicecode", ["client_id": graphClientID, "scope": graphScope])
    guard let code = start.json["device_code"] as? String,
          let shown = start.json["user_code"] as? String else {
        log("sign-in could not start: \(start.status) \(start.json)")
        return false
    }
    let interval = (start.json["interval"] as? Int) ?? 5
    print("")
    print("Open https://login.microsoft.com/device and enter the code: \(shown)")
    print("Sign in as the user this Mac records for, then come back here. Waiting...")
    let deadline = Date().addingTimeInterval(TimeInterval((start.json["expires_in"] as? Int) ?? 900))
    while Date() < deadline {
        Thread.sleep(forTimeInterval: TimeInterval(interval))
        let poll = postForm("token", ["client_id": graphClientID,
                                      "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                      "device_code": code])
        if let refresh = poll.json["refresh_token"] as? String {
            var settings = graphSettings()
            settings["refresh_token"] = refresh
            saveGraphSettings(settings)
            print("Signed in. Recordings will upload on their own from now on.")
            return true
        }
        let error = (poll.json["error"] as? String) ?? ""
        if error != "authorization_pending" && error != "slow_down" {
            log("sign-in failed: \(error) \(poll.json["error_description"] as? String ?? "")")
            return false
        }
    }
    log("sign-in timed out")
    return false
}

func graphAccessToken() -> String? {
    if let cached = graphAccess, cached.until > Date().addingTimeInterval(120) { return cached.token }
    guard let refresh = graphSettings()["refresh_token"] as? String else { return nil }
    let result = postForm("token", ["client_id": graphClientID, "grant_type": "refresh_token",
                                   "refresh_token": refresh, "scope": graphScope])
    guard let token = result.json["access_token"] as? String else {
        log("token refresh failed: \(result.status) \(result.json["error"] as? String ?? "")")
        return nil
    }
    if let rotated = result.json["refresh_token"] as? String {
        var settings = graphSettings()
        settings["refresh_token"] = rotated
        saveGraphSettings(settings)
    }
    let seconds = TimeInterval((result.json["expires_in"] as? Int) ?? 3600)
    graphAccess = (token, Date().addingTimeInterval(seconds))
    return token
}

// MARK: the target folder

/// (driveId, itemId) of the shared MRX-Notetaker folder, cached after the first lookup.
func graphFolder(_ token: String) -> (drive: String, item: String)? {
    let settings = graphSettings()
    if let drive = settings["drive_id"] as? String, let item = settings["item_id"] as? String {
        return (drive, item)
    }
    // Two places to look: the plain "shared with me" list, and the root of the user's own drive,
    // because a folder the user has added to My files appears there as a remoteItem instead.
    for path in ["/me/drive/sharedWithMe", "/me/drive/root/children"] {
        var request = URLRequest(url: URL(string: graphRoot + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = httpSync(request), result.status == 200 else {
            log("\(path) failed")
            continue
        }
        let items = (jsonBody(result.body)["value"] as? [[String: Any]]) ?? []
        for entry in items where (entry["name"] as? String) == folderName {
            guard let remote = entry["remoteItem"] as? [String: Any],
                  let item = remote["id"] as? String,
                  let parent = remote["parentReference"] as? [String: Any],
                  let drive = parent["driveId"] as? String else { continue }
            var settings = graphSettings()
            settings["drive_id"] = drive
            settings["item_id"] = item
            saveGraphSettings(settings)
            log("target folder found through \(path)")
            return (drive, item)
        }
    }
    log("\(folderName) is not shared with this account")
    return nil
}

// MARK: upload

func graphUpload(token: String, drive: String, item: String, session: String, file: URL) -> Bool {
    let name = file.lastPathComponent
    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let size: Int = (attributes?[.size] as? Int) ?? 0
    let base = "\(graphRoot)/drives/\(drive)/items/\(item):/\(session)/\(name):"
    if size <= simpleLimit {
        guard let data = try? Data(contentsOf: file) else { return false }
        var request = URLRequest(url: URL(string: "\(base)/content")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let result = httpSync(request), result.status / 100 == 2 else { return false }
        return true
    }
    var open = URLRequest(url: URL(string: "\(base)/createUploadSession")!)
    open.httpMethod = "POST"
    open.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    open.setValue("application/json", forHTTPHeaderField: "Content-Type")
    open.httpBody = try? JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "replace"]])
    guard let started = httpSync(open), started.status / 100 == 2,
          let uploadURL = jsonBody(started.body)["uploadUrl"] as? String,
          let handle = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? handle.close() }
    var offset = 0
    while offset < size {
        let length = min(chunkSize, size - offset)
        guard let chunk = try? handle.read(upToCount: length), !chunk.isEmpty else { return false }
        var put = URLRequest(url: URL(string: uploadURL)!)
        put.httpMethod = "PUT"
        put.setValue("bytes \(offset)-\(offset + chunk.count - 1)/\(size)", forHTTPHeaderField: "Content-Range")
        put.httpBody = chunk
        guard let result = httpSync(put), result.status / 100 == 2 else {
            log("chunk at \(offset) of \(name) failed")
            return false
        }
        offset += chunk.count
    }
    return true
}

/// Uploads everything in the outbox over HTTPS. Audio first, session.json last, exactly like the
/// sync-folder path, so the server never reads a manifest before its tracks have arrived.
func graphFlush() {
    let fm = FileManager.default
    guard let pending = try? fm.contentsOfDirectory(atPath: outboxDir.path) else { return }
    let sessions = pending.filter { !$0.hasPrefix(".") }
    guard !sessions.isEmpty else { return }
    guard let token = graphAccessToken() else {
        log("\(sessions.count) session(s) waiting and this Mac is not signed in; run MRXNotetaker --login")
        return
    }
    guard let target = graphFolder(token) else { return }
    for name in sessions {
        let src = outboxDir.appendingPathComponent(name)
        guard let contents = try? fm.contentsOfDirectory(atPath: src.path) else { continue }
        let tracks = contents.filter { $0 != "session.json" && !$0.hasPrefix(".") }
        var ok = true
        for file in tracks + ["session.json"] where ok {
            ok = graphUpload(token: token, drive: target.drive, item: target.item,
                             session: name, file: src.appendingPathComponent(file))
        }
        if ok {
            try? fm.removeItem(at: src)
            log("uploaded \(name) over https")
        } else {
            log("https upload of \(name) failed; it stays in the outbox")
            return
        }
    }
}
