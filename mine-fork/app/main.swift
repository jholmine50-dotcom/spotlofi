// ListenUp para Mac
// Janela nativa que roda o ListenUp (index.html) e já vem com:
//  • servidor local (o YouTube toca sem o erro 153)
//  • monitor de áudio do Mac: avisa a página quando outro app/aba começa ou para de tocar
//  • modo mini flutuante (o "PiP" do app), sempre por cima, em todas as mesas
//
// Compile com:  bash build-app.sh

import Cocoa
import WebKit
import CoreAudio
import Network
import Darwin
import MediaPlayer
import ServiceManagement
import UniformTypeIdentifiers

let appVersion = "1.3.8"

// MARK: - Monitor de áudio (macOS 14.2+)

func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

@available(macOS 14.2, *)
func audioProcessObjects() -> [AudioObjectID] {
    var addr = audioAddress(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

@available(macOS 14.2, *)
func audioIsRunningOutput(_ id: AudioObjectID) -> Bool {
    var addr = audioAddress(kAudioProcessPropertyIsRunningOutput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
}

@available(macOS 14.2, *)
func audioPid(_ id: AudioObjectID) -> pid_t? {
    var addr = audioAddress(kAudioProcessPropertyPID)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

@available(macOS 14.2, *)
func audioBundle(_ id: AudioObjectID) -> String {
    var addr = audioAddress(kAudioProcessPropertyBundleID)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr, let str = value else { return "" }
    return str.takeRetainedValue() as String
}

/// O macOS sabe qual app é "responsável" por cada processo auxiliar
/// (ex.: o processo de áudio do WebKit deste app, ou os helpers do Chrome).
typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let responsibleFn: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

func responsiblePid(_ pid: pid_t) -> pid_t {
    if let fn = responsibleFn {
        let r = fn(pid)
        if r > 0 { return r }
    }
    return pid
}

func processPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

func appName(_ pid: pid_t) -> String {
    let path = processPath(pid)
    if path.isEmpty { return "pid \(pid)" }
    if let r = path.range(of: ".app/") {
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }
    return (path as NSString).lastPathComponent
}

let myPid = getpid()

func duckStateJSON() -> Data {
    var obj: [String: Any] = ["ok": false, "reason": "os", "v": 1, "playing": []]
    if #available(macOS 14.2, *) {
        var seen = Set<String>()
        var playing: [[String: Any]] = []
        for id in audioProcessObjects() {
            guard audioIsRunningOutput(id), let pid = audioPid(id) else { continue }
            let owner = responsiblePid(pid)
            // ignora o próprio app (inclusive o processo de áudio do WebKit dele)
            if pid == myPid || owner == myPid { continue }
            let name = appName(owner)
            // o som do próprio app sai por um processo auxiliar do WebKit; quando o macOS não diz
            // de qual app ele é (dono = ele mesmo), é o nosso — o Safari, por exemplo, aparece como "Safari"
            let path = processPath(pid)
            let isWebKitHelper = path.contains("WebKit") || name.lowercased().contains("webkit") || audioBundle(id).hasPrefix("com.apple.WebKit")
            if isWebKitHelper && (owner == pid || responsibleFn == nil || name.lowercased().contains("webkit")) { continue }
            if name == "ListenUp" || name == "SpotLo-fi" || audioBundle(id) == "com.spotlofi.app" { continue }
            if seen.insert(name).inserted {
                playing.append(["pid": Int(owner), "bundle": audioBundle(id), "app": name])
            }
        }
        obj = ["ok": true, "v": 1, "playing": playing]
    }
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false}".utf8)
}

// MARK: - Busca e importação (feitas pelo app, sem chave para o YouTube)

let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false}".utf8)
}

func httpGet(_ url: URL, headers: [String: String] = [:], done: @escaping (Data?) -> Void) {
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
    req.setValue("pt-BR,pt;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { done(nil); return }
        done(data)
    }.resume()
}

/// Acha um objeto JSON que começa logo depois de `marker` dentro de um HTML.
func extractJSON(_ html: String, markers: [String]) -> Any? {
    for marker in markers {
        guard let r = html.range(of: marker),
              let u8 = r.upperBound.samePosition(in: html.utf8) else { continue }
        let bytes = Array(html.utf8)
        var i = html.utf8.distance(from: html.utf8.startIndex, to: u8)
        while i < bytes.count && bytes[i] != UInt8(ascii: "{") { i += 1 }
        let start = i
        var depth = 0, inStr = false, esc = false
        while i < bytes.count {
            let c = bytes[i]
            if inStr {
                if esc { esc = false } else if c == UInt8(ascii: "\\") { esc = true } else if c == UInt8(ascii: "\"") { inStr = false }
            } else if c == UInt8(ascii: "\"") { inStr = true }
            else if c == UInt8(ascii: "{") { depth += 1 }
            else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    return try? JSONSerialization.jsonObject(with: Data(bytes[start...i]))
                }
            }
            i += 1
        }
    }
    return nil
}

func walkJSON(_ v: Any, _ visit: ([String: Any]) -> Void) {
    if let d = v as? [String: Any] {
        visit(d)
        for (_, x) in d { walkJSON(x, visit) }
    } else if let a = v as? [Any] {
        for x in a { walkJSON(x, visit) }
    }
}

func dig(_ v: Any?, _ path: [String]) -> Any? {
    var cur = v
    for k in path { cur = (cur as? [String: Any])?[k] }
    return cur
}

func ytText(_ v: Any?) -> String {
    guard let d = v as? [String: Any] else { return (v as? String) ?? "" }
    if let s = d["simpleText"] as? String { return s }
    if let s = d["content"] as? String { return s }
    if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
    return ""
}

func firstString(in v: Any, where test: (String, String) -> Bool) -> String? {
    var found: String?
    walkJSON(v) { d in
        if found != nil { return }
        for (k, x) in d { if let s = x as? String, test(k, s) { found = s; return } }
    }
    return found
}

func youtubeSearch(_ q: String, kind: String = "", done: @escaping (Data) -> Void) {
    var c = URLComponents(string: "https://www.youtube.com/results")!
    c.queryItems = [URLQueryItem(name: "search_query", value: q), URLQueryItem(name: "hl", value: "pt-BR"), URLQueryItem(name: "gl", value: "BR")]
    if kind == "channel" { c.queryItems?.append(URLQueryItem(name: "sp", value: "EgIQAg==")) }
    if kind == "playlist" { c.queryItems?.append(URLQueryItem(name: "sp", value: "EgIQAw==")) }
    httpGet(c.url!, headers: ["Cookie": "CONSENT=YES+1; SOCS=CAI"]) { data in
        guard let data = data, let html = String(data: data, encoding: .utf8),
              let root = extractJSON(html, markers: ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "]) else {
            done(jsonData(["ok": false, "error": "Não consegui buscar no YouTube agora."])); return
        }
        let primary = dig(root, ["contents", "twoColumnSearchResultsRenderer", "primaryContents"]) ?? root
        var seen = Set<String>()
        var items: [[String: Any]] = []
        walkJSON(primary) { d in
            if items.count >= 30 { return }
            if let ch = d["channelRenderer"] as? [String: Any], let id = ch["channelId"] as? String, !seen.contains(id) {
                seen.insert(id)
                var th = firstString(in: ch["thumbnail"] ?? ch) { k, _ in k == "url" } ?? ""
                if th.hasPrefix("//") { th = "https:" + th }
                let meta = [ytText(ch["videoCountText"]), ytText(ch["subscriberCountText"])].filter { !$0.isEmpty && !$0.hasPrefix("@") }.joined(separator: " · ")
                items.append(["type": "channel", "id": id, "title": ytText(ch["title"]), "author": "", "meta": meta, "thumb": th])
            }
            if let v = d["videoRenderer"] as? [String: Any], let id = v["videoId"] as? String, !seen.contains(id) {
                seen.insert(id)
                items.append(["type": "video", "id": id, "title": ytText(v["title"]), "author": ytText(v["ownerText"]),
                              "meta": ytText(v["lengthText"]), "thumb": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"])
            }
            if let p = d["playlistRenderer"] as? [String: Any], let id = p["playlistId"] as? String, !seen.contains(id) {
                seen.insert(id)
                let thumb = firstString(in: p["thumbnails"] ?? p) { k, s in k == "url" && s.contains("ytimg") } ?? ""
                let count = (p["videoCount"] as? String).map { "\($0) vídeos" } ?? ""
                items.append(["type": "playlist", "id": id, "title": ytText(p["title"]),
                              "author": ytText(p["shortBylineText"] ?? p["longBylineText"]), "meta": count, "thumb": thumb])
            }
            if let l = d["lockupViewModel"] as? [String: Any], let id = l["contentId"] as? String,
               let type = l["contentType"] as? String, type.contains("PLAYLIST"), !seen.contains(id) {
                seen.insert(id)
                let title = ytText(dig(l, ["metadata", "lockupMetadataViewModel", "title"]))
                let thumb = firstString(in: l["contentImage"] ?? l) { k, s in k == "url" && s.contains("ytimg") } ?? ""
                let author = firstString(in: dig(l, ["metadata", "lockupMetadataViewModel", "metadata"]) ?? [String: Any]()) { k, _ in k == "content" } ?? ""
                items.append(["type": "playlist", "id": id, "title": title, "author": author, "meta": "Playlist", "thumb": thumb])
            }
        }
        done(jsonData(["ok": true, "items": items]))
    }
}

/// Lê as faixas de uma playlist/álbum do Spotify pela página pública do player (sem chave).
func spotifyEmbedTracks(kind: String, id: String, done: @escaping (Data) -> Void) {
    guard let url = URL(string: "https://open.spotify.com/embed/\(kind)/\(id)") else { done(jsonData(["ok": false])); return }
    httpGet(url) { data in
        guard let data = data, let html = String(data: data, encoding: .utf8),
              let r = html.range(of: "id=\"__NEXT_DATA__\""),
              let gt = html.range(of: ">", range: r.upperBound..<html.endIndex),
              let end = html.range(of: "</script>", range: gt.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[gt.upperBound..<end.lowerBound].utf8)) else {
            done(jsonData(["ok": false, "error": "Não consegui ler essa playlist do Spotify."])); return
        }
        var name = ""
        var cover = ""
        var tracks: [[String: Any]] = []
        var single: [String: Any]? = nil
        walkJSON(root) { d in
            if single == nil, let u = d["uri"] as? String, u.hasPrefix("spotify:track:"), let tt = (d["title"] as? String) ?? (d["name"] as? String) {
                var st = (d["subtitle"] as? String) ?? ""
                if st.isEmpty, let arr = d["artists"] as? [[String: Any]] { st = arr.compactMap { $0["name"] as? String }.joined(separator: ", ") }
                single = ["uri": u, "title": tt, "artist": st, "dur": (d["duration"] as? NSNumber)?.doubleValue ?? 0]
            }
            guard tracks.isEmpty, let list = d["trackList"] as? [[String: Any]], !list.isEmpty else { return }
            name = (d["name"] as? String) ?? (d["title"] as? String) ?? ""
            if let ca = d["coverArt"] as? [String: Any], let src = ca["sources"] as? [[String: Any]], let u = src.first?["url"] as? String { cover = u }
            for t in list {
                guard let uri = t["uri"] as? String else { continue }
                let dur = (t["duration"] as? NSNumber)?.doubleValue ?? 0
                tracks.append(["uri": uri, "title": (t["title"] as? String) ?? "", "artist": (t["subtitle"] as? String) ?? "", "dur": dur])
            }
        }
        if tracks.isEmpty, kind == "track", let one = single { tracks = [one]; name = (one["title"] as? String) ?? "" }
        done(jsonData(["ok": !tracks.isEmpty, "name": name, "cover": cover, "tracks": tracks]))
    }
}

var spotifyToken: (token: String, until: Date, key: String)?

func spotifySearch(_ q: String, clientId: String, secret: String, done: @escaping (Data) -> Void) {
    let key = clientId + ":" + secret
    func search(_ token: String) {
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "type", value: "track,playlist,album"),
                        URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "market", value: "BR")]
        httpGet(c.url!, headers: ["Authorization": "Bearer \(token)"]) { data in
            guard let data = data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                done(jsonData(["ok": false, "error": "O Spotify recusou a busca. Confira o Client ID e o Secret."])); return
            }
            func img(_ v: Any?) -> String { ((v as? [[String: Any]])?.first?["url"] as? String) ?? "" }
            var items: [[String: Any]] = []
            for t in (dig(root, ["tracks", "items"]) as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                let artists = (t["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
                let ms = (t["duration_ms"] as? Int) ?? 0
                items.append(["type": "track", "id": t["id"] ?? "", "title": t["name"] ?? "", "author": artists,
                              "meta": String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60), "thumb": img(dig(t, ["album", "images"]))])
            }
            for p in (dig(root, ["playlists", "items"]) as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                let total = (dig(p, ["tracks", "total"]) as? Int).map { "\($0) músicas" } ?? "Playlist"
                items.append(["type": "playlist", "id": p["id"] ?? "", "title": p["name"] ?? "",
                              "author": (dig(p, ["owner", "display_name"]) as? String) ?? "", "meta": total, "thumb": img(p["images"])])
            }
            for a in (dig(root, ["albums", "items"]) as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                let artists = (a["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
                items.append(["type": "album", "id": a["id"] ?? "", "title": a["name"] ?? "", "author": artists,
                              "meta": "Álbum", "thumb": img(a["images"])])
            }
            done(jsonData(["ok": true, "items": items]))
        }
    }
    if let t = spotifyToken, t.key == key, t.until > Date() { search(t.token); return }
    var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    req.httpMethod = "POST"
    req.setValue("Basic " + Data(key.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data("grant_type=client_credentials".utf8)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = j["access_token"] as? String else {
            done(jsonData(["ok": false, "error": "Client ID ou Secret do Spotify inválidos."])); return
        }
        let secs = (j["expires_in"] as? Double) ?? 3000
        spotifyToken = (token, Date().addingTimeInterval(secs - 60), key)
        search(token)
    }.resume()
}

func oembedProxy(_ target: String, done: @escaping (Data) -> Void) {
    let isSp = target.contains("spotify.com")
    var c = URLComponents(string: isSp ? "https://open.spotify.com/oembed" : "https://www.youtube.com/oembed")!
    c.queryItems = [URLQueryItem(name: "url", value: target)] + (isSp ? [] : [URLQueryItem(name: "format", value: "json")])
    httpGet(c.url!) { data in done(data ?? jsonData(["error": true])) }
}

enum MigStore {
    static var parts: [Int: String] = [:]
    static let lock = NSLock()
}

// MARK: - Tocando agora para programas de fora (ex.: mod ListenUp Show do Minecraft)
// GET http://localhost:17846/__api/nowplaying -> {"ok":true,"title":..,"artist":..,"playing":..,"position":..,"duration":..,"age":..}
let npLock = NSLock()
var npShared: [String: Any] = [:]
var npSharedAt = Date.distantPast
func nowPlayingJSON() -> Data {
    npLock.lock(); var o = npShared; let at = npSharedAt; npLock.unlock()
    o["ok"] = !o.isEmpty
    o["app"] = "ListenUp"
    o["age"] = Date().timeIntervalSince(at)   // segundos desde a última atualização
    return (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{\"ok\":false}".utf8)
}

func handleAPI(_ path: String, done: @escaping (Data) -> Void) {
    let comps = URLComponents(string: "http://x" + path)
    var q: [String: String] = [:]
    for it in comps?.queryItems ?? [] { q[it.name] = it.value ?? "" }
    switch comps?.path ?? "" {
    case "/__api/nowplaying": done(nowPlayingJSON())
    case "/__api/ytsearch": youtubeSearch(q["q"] ?? "", kind: q["kind"] ?? "", done: done)
    case "/__api/ytraw":
        let p = q["p"] ?? ""
        guard p.hasPrefix("/"), let url = URL(string: "https://www.youtube.com" + p) else { done(jsonData(["ok": false])); return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("pt-BR,pt;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("CONSENT=YES+1; SOCS=CAI", forHTTPHeaderField: "Cookie")
        if let b = q["b"], !b.isEmpty {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(b.utf8)
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let body = String(data: data, encoding: .utf8) else { done(jsonData(["ok": false])); return }
            done(jsonData(["ok": true, "body": body]))
        }.resume()
    case "/__api/mig":
        // 1.3.8: copia a biblioteca do endereço antigo (127.0.0.1) para o novo (localhost), em pedaços.
        let op = q["op"] ?? "", i = Int(q["i"] ?? "") ?? -1
        MigStore.lock.lock()
        var res: [String: Any] = ["ok": false]
        if op == "put", i >= 0 { MigStore.parts[i] = q["d"] ?? ""; res = ["ok": true] }
        else if op == "get", i >= 0, let d = MigStore.parts[i] { res = ["ok": true, "d": d] }
        else if op == "clear" { MigStore.parts.removeAll(); res = ["ok": true] }
        MigStore.lock.unlock()
        done(jsonData(res))
    case "/__api/spembed": spotifyEmbedTracks(kind: q["kind"] ?? "playlist", id: q["id"] ?? "", done: done)
    case "/__api/spsearch": spotifySearch(q["q"] ?? "", clientId: q["cid"] ?? "", secret: q["cs"] ?? "", done: done)
    case "/__api/oembed": oembedProxy(q["url"] ?? "", done: done)
    case "/__api/spcode":
        spCodeLock.lock(); let v = spCodeQuery; spCodeQuery = ""; spCodeLock.unlock()
        done(jsonData(["q": v]))
    default: done(jsonData(["ok": false, "error": "rota desconhecida"]))
    }
}

// Volta do login do Spotify (http://127.0.0.1:17846/callback?code=…&state=…)
var spCodeQuery = ""
let spCodeLock = NSLock()
let spCallbackHTML = Data(#"""
<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>ListenUp</title></head><body style='margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,system-ui,Segoe UI,Roboto,sans-serif;background:#15121d;color:#f5f5f7;text-align:center'><div style='padding:24px'><h2 id='t' style='margin:0 0 8px'>Spotify conectado!</h2><p style='opacity:.7;margin:0 0 18px'>Pode fechar esta aba e voltar para o ListenUp.</p><a id='b' href='#' style='display:inline-block;padding:12px 24px;border-radius:999px;background:#1ed760;color:#000;font-weight:700;text-decoration:none'>Voltar para o ListenUp</a></div><script>var q=location.search.slice(1),u='spotlofi://spauth?'+q;if(/(^|&)error=/.test(q)){document.getElementById('t').textContent='Login cancelado';}document.getElementById('b').href=u;setTimeout(function(){location.href=u},600);</script></body></html>
"""#.utf8)

// MARK: - Servidor local (só 127.0.0.1)

final class LocalServer {
    let html: Data
    var files: [String: (Data, String)] = [:]
    var listener: NWListener?

    init(html: Data) { self.html = html }

    func start(preferred: UInt16, ready: @escaping (UInt16) -> Void) {
        attempt(preferred, ready: ready, allowFallback: true)
    }

    private func attempt(_ port: UInt16, ready: @escaping (UInt16) -> Void, allowFallback: Bool) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        guard let l = try? NWListener(using: params, on: nwPort) else {
            if allowFallback { attempt(0, ready: ready, allowFallback: false) }
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let p = l.port?.rawValue ?? port
                DispatchQueue.main.async { ready(p) }
            case .failed:
                l.cancel()
                if allowFallback { self?.attempt(0, ready: ready, allowFallback: false) }
            default:
                break
            }
        }
        l.start(queue: .global(qos: .userInitiated))
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            if path.hasPrefix("/__api/") {
                handleAPI(path) { data in LocalServer.send(conn, status: "200 OK", type: "application/json", body: data) }
                return
            }
            var status = "200 OK"
            var type = "text/html; charset=utf-8"
            var body = Data()
            let bare = String(path.split(separator: "?").first ?? "")
            if path == "/" || path.hasPrefix("/?") || path.hasPrefix("/index.html") {
                body = self.html
            } else if bare == "/callback" {
                if let qi = path.firstIndex(of: "?") {
                    spCodeLock.lock(); spCodeQuery = String(path[path.index(after: qi)...]); spCodeLock.unlock()
                }
                body = spCallbackHTML
            } else if let f = self.files[bare] {
                body = f.0
                type = f.1
            } else if path.hasPrefix("/__duck/state") {
                type = "application/json"
                body = duckStateJSON()
            } else if path.hasPrefix("/favicon") {
                status = "204 No Content"
            } else {
                status = "404 Not Found"
                type = "text/plain"
                body = Data("404".utf8)
            }
            LocalServer.send(conn, status: status, type: type, body: body)
        }
    }

    static func send(_ conn: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKScriptMessageHandler, NSMenuDelegate {
    // barra de menus + "tocando agora" do macOS
    var statusItem: NSStatusItem?
    var npTitle = "", npArtist = "", npThumb = ""
    var npPlaying = false
    var npDuration = 0.0, npPosition = 0.0
    var npArtwork: MPMediaItemArtwork?
    var sceneNames: [String] = []
    // v1.1.2
    var port: UInt16 = 0
    var pageReady = false
    var pendingURLs: [String] = []
    let voice = VoiceListener()
    let widget = FloatingWidget()
    var widgetState: [String: Any] = [:]
    var window: NSWindow!
    var web: WKWebView!
    var server: LocalServer?
    var popups: [NSWindow] = []
    var isMini = false
    var savedFrame = NSRect.zero
    var miniItem: NSMenuItem?
    var miniKind = "yt"          // "yt" (vídeo 16:9) ou "sp" (player compacto do Spotify)
    let normalMinSize = NSSize(width: 720, height: 520)
    let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let autosaveName = "SpotLoFiMain"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setupStatusItem()
        setupRemoteCommands()

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let html = try? Data(contentsOf: url) else {
            let alert = NSAlert()
            alert.messageText = "Não encontrei o index.html dentro do app."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = true }
        config.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: "window.__SPOTLOFI_APP__={version:'\(appVersion)',os:'mac'};",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "spotlofi")
        config.userContentController = ucc

        web = DragWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { web.isInspectable = true }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "ListenUp"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
        window.contentMinSize = normalMinSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.center()
        window.setFrameAutosaveName(autosaveName)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let srv = LocalServer(html: html)
        if let wu = Bundle.main.url(forResource: "widget", withExtension: "html"), let wd = try? Data(contentsOf: wu) {
            srv.files["/widget"] = (wd, "text/html; charset=utf-8")
        }
        server = srv
        srv.start(preferred: 17846) { [weak self] port in
            guard let self = self, let u = URL(string: "http://localhost:\(port)/") else { return }
            self.port = port
            self.web.load(URLRequest(url: u))
        }
        setupV112()
    }

    // Fechar a janela só esconde (a música continua). Clique no ícone do Dock para voltar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            // fechar a janela principal encerra o ListenUp inteiro (nada fica rodando escondido)
            if isMini { toggleMini() }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w !== window else { return }
        popups.removeAll { $0 === w }
        web.evaluateJavaScript("window.spotlofiNative&&window.spotlofiNative({spotifyLogin:true})", completionHandler: nil)
    }

    // No modo mini, o "zoom" (duplo clique na barra) não deve virar tela grande
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { !isMini }

    // Depois de redimensionar, garante que a página recalcule o tamanho do player
    func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        nudgeLayout()
    }

    func nudgeLayout() {
        web.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: página → app
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "widget" {
            if let body = message.body as? [String: Any], let a = body["action"] as? String { widgetAction(a) }
            return
        }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        if handleV112(cmd, body) { return }
        switch cmd {
        case "dragRegions":
            (web as? DragWebView)?.setRegions(drag: body["drag"], noDrag: body["nodrag"])
        case "mini": toggleMini()
        case "miniKind":
            let kind = (body["kind"] as? String) == "sp" ? "sp" : "yt"
            if kind != miniKind {
                miniKind = kind
                if isMini { applyMiniLayout(entering: false) }
            }
        case "state":
            if let s = body["title"] as? String { npTitle = s }
            if let s = body["artist"] as? String { npArtist = s }
            if let b = body["playing"] as? Bool { npPlaying = b }
            if let d = body["duration"] as? Double { npDuration = d }
            if let p = body["position"] as? Double { npPosition = p }
            if let names = body["scenes"] as? [String] { sceneNames = names }
            if let t = body["thumb"] as? String, t != npThumb { npThumb = t; loadArtwork(t) }
            updateNowPlaying()
            npLock.lock()
            npShared = ["title": npTitle, "artist": npArtist, "playing": npPlaying,
                        "position": npPosition, "duration": npDuration, "thumb": npThumb]
            npSharedAt = Date()
            npLock.unlock()
        case "saveFile":
            saveFile(name: (body["name"] as? String) ?? "ListenUp-backup.json", content: (body["content"] as? String) ?? "")
        case "openFile": openFile()
        case "loginItem":
            if let on = body["on"] as? Bool { setLoginItem(on) } else { sendToPage(["loginItem": loginItemEnabled()]) }
        case "fullscreen": window.toggleFullScreen(nil)
        case "spotifyLogin": openSpotifyLogin()
        case "open":
            if let s = body["url"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    // MARK: janelas pop-up (login do Spotify etc.)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let host = url?.host ?? ""
        let blank = url == nil || url!.absoluteString.isEmpty || url!.absoluteString == "about:blank"
        let loginHosts = ["accounts.spotify.com", "accounts.google.com", "appleid.apple.com", "facebook.com", "challenge.spotify.com"]
        if blank || loginHosts.contains(where: { host.hasSuffix($0) }) {
            return makePopup(configuration: configuration, title: "ListenUp")
        }
        if let u = url { NSWorkspace.shared.open(u) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = webView.window, w !== window { w.close() }
    }

    func makePopup(configuration: WKWebViewConfiguration, title: String) -> WKWebView {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        let v = WKWebView(frame: .zero, configuration: configuration)
        v.uiDelegate = self
        w.contentView = v
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return v
    }

    @objc func openSpotifyLogin() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = makePopup(configuration: cfg, title: "Entrar no Spotify — feche esta janela quando terminar")
        if let u = URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F") {
            v.load(URLRequest(url: u))
        }
    }

    // MARK: modo mini
    @objc func toggleMini() {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.toggleMini() }
            return
        }
        showMain()
        isMini.toggle()
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        // avisa a página antes de mexer na janela, para o layout já estar no modo certo
        web.evaluateJavaScript("window.spotlofiNative&&window.spotlofiNative({mini:\(isMini)})", completionHandler: nil)
        if isMini {
            savedFrame = window.frame
            window.setFrameAutosaveName("")
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            buttons.forEach { window.standardWindowButton($0)?.isHidden = true }
            applyMiniLayout(entering: true)
        } else {
            window.level = .normal
            window.collectionBehavior = []
            window.contentResizeIncrements = NSSize(width: 1, height: 1)   // tira a trava de proporção
            window.contentMaxSize = unlimited
            window.contentMinSize = normalMinSize
            buttons.forEach { window.standardWindowButton($0)?.isHidden = false }
            window.setFrame(savedFrame, display: true, animate: true)
            window.setFrameAutosaveName(autosaveName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.nudgeLayout() }
        }
        miniItem?.state = isMini ? .on : .off
    }

    /// Ajusta limites e proporção da janela mini para o tipo de player:
    /// vídeo do YouTube = 16:9 travado (redimensiona proporcional, sem cortar);
    /// Spotify = altura entre o player compacto (152) e o normal (352).
    func applyMiniLayout(entering: Bool) {
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let current = window.frame
        var size: NSSize
        if miniKind == "sp" {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.contentMinSize = NSSize(width: 300, height: 152)
            window.contentMaxSize = NSSize(width: 900, height: 352)
            size = entering ? NSSize(width: 420, height: 152)
                            : NSSize(width: max(300, min(current.width, 900)), height: 152)
        } else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.contentMinSize = NSSize(width: 288, height: 162)
            window.contentMaxSize = NSSize(width: 1600, height: 900)
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            let w = entering ? 480 : max(320, min(current.width, 1600))
            size = NSSize(width: w, height: (w * 9 / 16).rounded())
        }
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var origin: NSPoint
        if entering {
            origin = NSPoint(x: vf.maxX - frameSize.width - 20, y: vf.minY + 20)
        } else {
            // mantém o canto inferior direito no lugar
            origin = NSPoint(x: current.maxX - frameSize.width, y: current.minY)
        }
        origin.x = min(max(origin.x, vf.minX), vf.maxX - frameSize.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - frameSize.height)
        window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.nudgeLayout() }
    }

    // MARK: app → página
    func sendToPage(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.spotlofiNative&&window.spotlofiNative(\(json))", completionHandler: nil)
    }

    // MARK: ícone na barra de menus
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = Bundle.main.image(forResource: "StatusIcon") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true   // silhueta: fica branca ou preta conforme a barra de menus
            item.button?.image = img
        } else {
            item.button?.title = "♪"
        }
        item.button?.toolTip = "ListenUp"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        let head = NSMenuItem(title: npTitle.isEmpty ? "Nada tocando" : npTitle, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if !npArtist.isEmpty {
            let a = NSMenuItem(title: npArtist, action: nil, keyEquivalent: "")
            a.isEnabled = false
            menu.addItem(a)
        }
        menu.addItem(.separator())
        let actions: [(String, String)] = [(npPlaying ? "Pausar" : "Tocar", "toggle"), ("Próxima", "next"), ("Anterior", "prev")]
        for (title, action) in actions {
            let it = NSMenuItem(title: title, action: #selector(statusAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = action
            menu.addItem(it)
        }
        if !sceneNames.isEmpty {
            menu.addItem(.separator())
            let scenes = NSMenuItem(title: "Cenas", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Cenas")
            for (i, name) in sceneNames.enumerated() {
                let it = NSMenuItem(title: name, action: #selector(sceneAction(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                sub.addItem(it)
            }
            scenes.submenu = sub
            menu.addItem(scenes)
        }
        menu.addItem(.separator())
        let mini = NSMenuItem(title: isMini ? "Sair do modo mini" : "Modo mini", action: #selector(toggleMini), keyEquivalent: "")
        mini.target = self
        menu.addItem(mini)
        let show = NSMenuItem(title: "Mostrar ListenUp", action: #selector(showMain), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair do ListenUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    @objc func statusAction(_ sender: NSMenuItem) {
        if let a = sender.representedObject as? String { sendToPage(["action": a]) }
    }

    @objc func sceneAction(_ sender: NSMenuItem) {
        sendToPage(["action": "scene", "index": sender.tag])
    }

    // MARK: teclas de mídia, AirPods e "tocando agora"
    func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        let map: [(MPRemoteCommand, String)] = [
            (c.playCommand, "play"), (c.pauseCommand, "pause"), (c.togglePlayPauseCommand, "toggle"),
            (c.nextTrackCommand, "next"), (c.previousTrackCommand, "prev")
        ]
        for (cmd, action) in map {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.sendToPage(["action": action]) }
                return .success
            }
        }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                let t = e.positionTime
                DispatchQueue.main.async { self?.sendToPage(["action": "seek", "time": t]) }
            }
            return .success
        }
    }

    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle.isEmpty ? "ListenUp" : npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPNowPlayingInfoPropertyPlaybackRate: npPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: npPosition
        ]
        if npDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = npDuration }
        if let art = npArtwork { info[MPMediaItemPropertyArtwork] = art }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = npPlaying ? .playing : .paused
        statusItem?.button?.toolTip = npTitle.isEmpty ? "ListenUp" : "\(npTitle) — ListenUp"
    }

    func loadArtwork(_ urlString: String) {
        npArtwork = nil
        guard let url = URL(string: urlString) else { return }
        httpGet(url) { [weak self] data in
            guard let data = data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.npThumb == urlString else { return }
                self.npArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.updateNowPlaying()
            }
        }
    }

    // MARK: backup (exportar / importar)
    func saveFile(name: String, content: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                self?.sendToPage(["toast": "Backup salvo ✓"])
            } catch {
                self?.sendToPage(["toast": "Não consegui salvar o backup."])
            }
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                self?.sendToPage(["importData": s])
            } else {
                self?.sendToPage(["toast": "Não consegui ler esse arquivo."])
            }
        }
    }

    // MARK: abrir junto com o Mac
    func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            sendToPage(["toast": on ? "O macOS não deixou ativar. Veja em Ajustes do Sistema → Geral → Itens de Início." : "Não consegui desativar."])
        }
        sendToPage(["loginItem": loginItemEnabled()])
    }

    @objc func showMain() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reloadPage() { web.reload() }

    // MARK: menus
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "ListenUp")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Sobre o ListenUp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let sp = appMenu.addItem(withTitle: "Entrar no Spotify…", action: #selector(openSpotifyLogin), keyEquivalent: "")
        sp.target = self
        appMenu.addItem(.separator())
        let upd = appMenu.addItem(withTitle: "Verificar atualizações…", action: #selector(checkUpdatesMenu), keyEquivalent: "")
        upd.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar ListenUp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Ocultar outros", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Sair do ListenUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Editar")
        editItem.submenu = edit
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "Visualizar")
        viewItem.submenu = view
        let mini = view.addItem(withTitle: "Modo mini (flutuante)", action: #selector(toggleMini), keyEquivalent: "m")
        mini.keyEquivalentModifierMask = [.command, .shift]
        mini.target = self
        miniItem = mini
        let ai = view.addItem(withTitle: "Falar com a IA", action: #selector(talkToAI), keyEquivalent: " ")
        ai.keyEquivalentModifierMask = [.command, .shift]
        ai.target = self
        let wd = view.addItem(withTitle: "Mostrar/ocultar widget", action: #selector(toggleWidgetMenu), keyEquivalent: "w")
        wd.keyEquivalentModifierMask = [.command, .shift]
        wd.target = self
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Tela cheia", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        let reload = view.addItem(withTitle: "Recarregar", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Janela")
        winItem.submenu = win
        win.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let show = win.addItem(withTitle: "Mostrar ListenUp", action: #selector(showMain), keyEquivalent: "1")
        show.target = self
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
