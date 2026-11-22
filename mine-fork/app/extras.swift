// ListenUp v1.1.2 — recursos nativos novos
//  • IA no próprio Mac (Apple Intelligence / FoundationModels)
//  • Voz: apertar para falar e "Ei, SpotLo" (Speech) + resposta falada
//  • Atalhos globais personalizáveis (Carbon)
//  • Widget flutuante na mesa
//  • Atualização automática pelo GitHub
//  • Atalhos do macOS (app Atalhos) para o Foco / bloquear distrações

import Cocoa
import WebKit
import Carbon
import Speech
import AVFoundation
#if HAS_FM
import FoundationModels
#endif

let updateRepo = "jholmine50-dotcom/spotlofi"

// MARK: - IA (Apple Intelligence, no próprio Mac)

enum LocalAI {
    /// "ok" | "noSDK" | "old" | descrição do motivo de não estar disponível
    static func status() -> String {
        #if HAS_FM
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "ok"
            case .unavailable(let reason): return "\(reason)"
            @unknown default: return "unknown"
            }
        }
        return "old"
        #else
        return "noSDK"
        #endif
    }

    static func ask(instructions: String, prompt: String, done: @escaping (String?, String?) -> Void) {
        #if HAS_FM
        if #available(macOS 26.0, *) {
            Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt)
                    let text = response.content
                    DispatchQueue.main.async { done(text, nil) }
                } catch {
                    DispatchQueue.main.async { done(nil, "\(error)") }
                }
            }
            return
        }
        #endif
        done(nil, "unavailable")
    }
}

// MARK: - Fala (resposta da IA)

final class Speaker: NSObject {
    static let shared = Speaker()
    let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        u.rate = 0.52
        synth.speak(u)
    }
}

// MARK: - Voz (reconhecimento)

final class VoiceListener: NSObject {
    enum Mode { case off, push, wake }

    var onEvent: (([String: Any]) -> Void)?
    private(set) var mode: Mode = .off
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var restartTimer: Timer?
    private var lastText = ""
    private var awake = false          // no modo "Ei SpotLo", depois de ouvir a palavra de ativação
    private var wakeOffset = ""        // texto antes do comando
    private var wantWake = false

    private let wakeRegex = try! NSRegularExpression(
        pattern: "(?:\\b(?:ei|hei|hey|oi|e aí|eai)\\b[\\s,]*)(?:spot\\s*-?\\s*lo\\w*|spotlo\\w*|spot\\s*low|spot\\s*l[oô]u?|spotify)",
        options: [.caseInsensitive])

    func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { done(false); return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async { done(ok) }
                }
            }
        }
    }

    /// Escuta um comando (botão ou atalho). Para sozinho depois de uma pausa.
    func startPush() {
        authorize { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.onEvent?(["voice": "denied"]); return }
            self.stopAll(silent: true)
            self.mode = .push
            self.begin()
            self.onEvent?(["voice": "listening"])
        }
    }

    /// Fica ouvindo "Ei SpotLo" o tempo todo.
    func setWake(_ on: Bool) {
        wantWake = on
        if on {
            authorize { [weak self] ok in
                guard let self = self else { return }
                guard ok else { self.wantWake = false; self.onEvent?(["voice": "denied"]); return }
                if self.mode == .off { self.mode = .wake; self.begin() }
                self.onEvent?(["voice": "wake-on"])
            }
        } else {
            if mode == .wake { stopAll(silent: true) }
            onEvent?(["voice": "wake-off"])
        }
    }

    func cancel() {
        stopAll(silent: false)
    }

    private func begin() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onEvent?(["voice": "unavailable"])
            mode = .off
            return
        }
        lastText = ""
        awake = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.taskHint = .dictation
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            onEvent?(["voice": "error", "error": "\(error)"])
            mode = .off
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let r = result {
                let text = r.bestTranscription.formattedString
                DispatchQueue.main.async { self.handle(text: text, isFinal: r.isFinal) }
            }
            if error != nil {
                DispatchQueue.main.async { self.recycle() }
            }
        }

        restartTimer?.invalidate()
        // o reconhecimento tem limite de tempo; recomeça em silêncio de tempos em tempos
        restartTimer = Timer.scheduledTimer(withTimeInterval: mode == .wake ? 50 : 15, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.mode == .push { self.finishPush() } else { self.recycle() }
        }
    }

    private func handle(text: String, isFinal: Bool) {
        guard text != lastText || isFinal else { return }
        lastText = text
        switch mode {
        case .push:
            onEvent?(["voice": "partial", "text": text])
            armSilence(1.6) { [weak self] in self?.finishPush() }
            if isFinal { finishPush() }
        case .wake:
            if !awake {
                let ns = text as NSString
                if let m = wakeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    awake = true
                    wakeOffset = ns.substring(to: m.range.location + m.range.length)
                    onEvent?(["voice": "wake"])
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
            }
            if awake {
                let cmd = String(text.dropFirst(min(wakeOffset.count, text.count)))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespaces))
                onEvent?(["voice": "partial", "text": cmd])
                armSilence(cmd.isEmpty ? 4 : 1.6) { [weak self] in
                    guard let self = self else { return }
                    let c = String(self.lastText.dropFirst(min(self.wakeOffset.count, self.lastText.count)))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?").union(.whitespaces))
                    if !c.isEmpty { self.onEvent?(["voice": "final", "text": c]) } else { self.onEvent?(["voice": "idle"]) }
                    self.recycle()
                }
            }
        case .off:
            break
        }
    }

    private func armSilence(_ secs: Double, _ fire: @escaping () -> Void) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in fire() }
    }

    private func finishPush() {
        guard mode == .push else { return }
        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        stopAll(silent: true)
        onEvent?(text.isEmpty ? ["voice": "idle"] : ["voice": "final", "text": text])
        if wantWake { mode = .wake; begin() }
    }

    /// Fecha a escuta atual e, se o "Ei SpotLo" estiver ligado, recomeça.
    private func recycle() {
        let again = wantWake
        stopAll(silent: true)
        if again {
            mode = .wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.mode == .wake, self.task == nil else { return }
                self.begin()
            }
        }
    }

    private func stopAll(silent: Bool) {
        silenceTimer?.invalidate(); silenceTimer = nil
        restartTimer?.invalidate(); restartTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        mode = .off
        awake = false
        if !silent { onEvent?(["voice": "idle"]) }
    }
}

// MARK: - Atalhos globais (funcionam com qualquer app na frente)

final class HotkeyManager {
    static let shared = HotkeyManager()
    var onFire: ((String) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var names: [UInt32: String] = [:]
    private var installed = false

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "space": 49, "return": 36, "enter": 36, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111
    ]

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotkeyManager.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        if let n = names[id] { DispatchQueue.main.async { self.onFire?(n) } }
    }

    /// map: ação → combinação, ex.: ["toggle": "cmd+opt+p"]
    /// Devolve as combinações que o macOS recusou (já usadas por outro app).
    @discardableResult
    func apply(_ map: [String: String]) -> [String] {
        installHandler()
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); names.removeAll()
        var failed: [String] = []
        var i: UInt32 = 1
        for (action, combo) in map.sorted(by: { $0.key < $1.key }) {
            guard let (code, mods) = parse(combo) else { continue }
            var ref: EventHotKeyRef?
            let hid = EventHotKeyID(signature: OSType(0x534C4F46), id: i)  // "SLOF"
            let st = RegisterEventHotKey(code, mods, hid, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref = ref { refs.append(ref); names[i] = action } else { failed.append(action) }
            i += 1
        }
        return failed
    }

    private func parse(_ combo: String) -> (UInt32, UInt32)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = HotkeyManager.keyCodes[key] else { return nil }
        var mods: UInt32 = 0
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "meta": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: break
            }
        }
        guard mods != 0 || key.hasPrefix("f") else { return nil }   // exige um modificador (exceto F1–F12)
        return (code, mods)
    }
}

// MARK: - App Atalhos do macOS (para ligar/desligar o Foco)

enum ShortcutsBridge {
    static func list(_ done: @escaping ([String]) -> Void) {
        run(["list"]) { out in
            done(out.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty })
        }
    }

    static func runShortcut(_ name: String) {
        guard !name.isEmpty else { return }
        run(["run", name]) { _ in }
    }

    private static func run(_ args: [String], done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { DispatchQueue.main.async { done("") }; return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let s = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { done(s) }
        }
    }
}

// MARK: - Atualização automática (GitHub)

final class Updater {
    static let shared = Updater()
    var onEvent: (([String: Any]) -> Void)?
    private(set) var latest: [String: Any]?

    private var manifestURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(updateRepo)/main/\(updateChannel)/latest.json?t=\(Int(Date().timeIntervalSince1970))")!
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Pede o latest.json pela API do GitHub (sem o atraso do cache de ~5 min do raw) e, se falhar, pelo raw.
    private func fetchManifest(_ done: @escaping ([String: Any]?) -> Void) {
        func get(_ url: URL, accept: String?, _ cb: @escaping ([String: Any]?) -> Void) {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let a = accept { req.setValue(a, forHTTPHeaderField: "Accept") }
            req.setValue("ListenUp", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      j["version"] is String else { cb(nil); return }
                cb(j)
            }.resume()
        }
        let api = URL(string: "https://api.github.com/repos/\(updateRepo)/contents/\(updateChannel)/latest.json?ref=main&t=\(Int(Date().timeIntervalSince1970))")!
        get(api, accept: "application/vnd.github.raw") { [weak self] j in
            if let j = j { done(j); return }
            guard let self = self else { done(nil); return }
            get(self.manifestURL, accept: nil, done)
        }
    }

    func check(manual: Bool) {
        fetchManifest { [weak self] j in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let j = j, let v = j["version"] as? String else {
                    if manual { self.onEvent?(["update": ["state": "error", "message": "Não consegui verificar agora."]]) }
                    return
                }
                self.latest = j
                if Updater.isNewer(v, than: appVersion) {
                    self.onEvent?(["update": ["state": "available", "version": v, "notes": j["notes"] ?? ""]])
                } else if manual {
                    self.onEvent?(["update": ["state": "current", "version": appVersion]])
                }
            }
        }
    }

    /// Espera o instalador terminar de montar a versão nova: ele avisa com o arquivo READY (aí o app fecha
    /// para ser trocado e reaberto) ou FAILED (aí mostra o erro e continua aberto).
    private func watchInstall(base: URL) {
        let ready = base.appendingPathComponent("READY"), failed = base.appendingPathComponent("FAILED")
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            let fm = FileManager.default
            if fm.fileExists(atPath: ready.path) {
                t.invalidate()
                NSApp.terminate(nil)
            } else if fm.fileExists(atPath: failed.path) {
                t.invalidate()
                let why = (try? String(contentsOf: failed, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
                self?.onEvent?(["update": ["state": "error", "message": "A atualização não terminou. " + why]])
            } else if Date().timeIntervalSince(started) > 600 {
                t.invalidate()
                self?.onEvent?(["update": ["state": "error", "message": "A atualização demorou demais. Tente de novo."]])
            }
        }
    }

    /// Troca o app atual pelo app pronto que veio no zip: um script espera o ListenUp fechar,
    /// substitui o .app (guardando o antigo até dar certo), tira a quarentena e abre de novo.
    private func installPrebuilt(newApp: String, base: URL) {
        onEvent?(["update": ["state": "installing"]])
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = base.appendingPathComponent("install-fork.sh")
        let body = """
        #!/bin/bash
        NEW="$1"; OLD="$2"; PID="$3"
        DEST="$(dirname "$OLD")/$(basename "$NEW")"
        for i in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
        rm -rf "$OLD.old"
        if mv "$OLD" "$OLD.old" && { [ "$DEST" = "$OLD" ] || rm -rf "$DEST"; } && ditto "$NEW" "$DEST"; then
          rm -rf "$OLD.old"
        else
          rm -rf "$DEST"; mv "$OLD.old" "$OLD"; DEST="$OLD"
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            p.arguments = ["-c", "nohup /bin/bash \(q(script.path)) \(q(newApp)) \(q(dest)) \(pid) > /tmp/listenup-minefork-update.log 2>&1 &"]
            try p.run()
        } catch {
            onEvent?(["update": ["state": "error", "message": "Não consegui iniciar a instalação."]]); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }

    func install() {
        guard let j = latest, let zip = j["zip"] as? String else { check(manual: true); return }
        let zipURL: URL? = zip.hasPrefix("http") ? URL(string: zip)
            : URL(string: "https://raw.githubusercontent.com/\(updateRepo)/main/\(zip)")
        guard let url = zipURL else { return }
        onEvent?(["update": ["state": "downloading"]])
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, _ in
            guard let self = self else { return }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async { self.onEvent?(["update": ["state": "error", "message": "Falha ao baixar a atualização."]]) }
                return
            }
            let fm = FileManager.default
            let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpotLo-fi/update")
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let zipPath = base.appendingPathComponent("update.zip")
            try? fm.moveItem(at: tmp, to: zipPath)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipPath.path, base.path]
            do { try unzip.run(); unzip.waitUntilExit() } catch {}
            // Mine fork: o zip já traz o app pronto (compilado no GitHub) — só troca o app e reabre
            if let items = try? fm.contentsOfDirectory(atPath: base.path),
               let appName = items.first(where: { $0.hasSuffix(".app") }) {
                let newApp = base.appendingPathComponent(appName).path
                DispatchQueue.main.async { self.installPrebuilt(newApp: newApp, base: base) }
                return
            }
            // acha o build-app.sh
            var script: String?
            if let en = fm.enumerator(atPath: base.path) {
                for case let p as String in en where p.hasSuffix("build-app.sh") { script = base.appendingPathComponent(p).path; break }
            }
            DispatchQueue.main.async {
                guard let s = script else {
                    self.onEvent?(["update": ["state": "error", "message": "Atualização incompleta."]]); return
                }
                self.onEvent?(["update": ["state": "installing"]])
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                let quoted = s.replacingOccurrences(of: "'", with: "'\\''")
                p.arguments = ["-c", "nohup /bin/bash '\(quoted)' > /tmp/spotlofi-update.log 2>&1 &"]
                do { try p.run() } catch {
                    self.onEvent?(["update": ["state": "error", "message": "Não consegui iniciar a instalação."]]); return
                }
                self.watchInstall(base: base)
            }
        }.resume()
    }
}

// MARK: - Widget flutuante

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// WKWebView que deixa arrastar a janela pelas áreas que a página marca como "barra"
/// (a página manda os retângulos; botões e campos dentro delas continuam clicáveis).
final class DragWebView: WKWebView {
    private var dragRects: [CGRect] = []
    private var noDragRects: [CGRect] = []

    private static func rects(_ any: Any?) -> [CGRect] {
        guard let arr = any as? [[Any]] else { return [] }
        return arr.compactMap { r in
            guard r.count == 4 else { return nil }
            let n = r.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
    }
    func setRegions(drag: Any?, noDrag: Any?) {
        dragRects = DragWebView.rects(drag)
        noDragRects = DragWebView.rects(noDrag)
    }
    private func isDragPoint(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let pt = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        return dragRects.contains { $0.contains(pt) } && !noDragRects.contains { $0.contains(pt) }
    }
    override func mouseDown(with event: NSEvent) {
        if let w = window, isDragPoint(event) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { w.performMiniaturize(nil) } else if action != "None" { w.performZoom(nil) }
            } else {
                w.performDrag(with: event)
            }
            return
        }
        super.mouseDown(with: event)
    }
}

final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class FloatingWidget: NSObject, NSWindowDelegate {
    var panel: KeyPanel?
    var web: WKWebView?
    var onAction: (([String: Any]) -> Void)?
    var lastState: [String: Any] = [:]
    var onTop = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(port: UInt16, handler: WKScriptMessageHandler, onTop: Bool) {
        self.onTop = onTop
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 176),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.delegate = self
            let cfg = WKWebViewConfiguration()
            let ucc = WKUserContentController()
            ucc.add(handler, name: "widget")
            cfg.userContentController = ucc
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 176), configuration: cfg)
            w.setValue(false, forKey: "drawsBackground")
            w.autoresizingMask = [.width, .height]
            let container = NSView(frame: w.frame)
            container.wantsLayer = true
            container.layer?.cornerRadius = 22
            container.layer?.masksToBounds = true
            container.addSubview(w)
            let strip = DragStrip(frame: NSRect(x: 0, y: 176 - 20, width: 300, height: 20))
            strip.autoresizingMask = [.width, .minYMargin]
            container.addSubview(strip)
            p.contentView = container
            if let u = URL(string: "http://127.0.0.1:\(port)/widget") { w.load(URLRequest(url: u)) }
            panel = p
            web = w
            if !p.setFrameUsingName("SpotLoFiWidget") {
                let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                p.setFrameOrigin(NSPoint(x: vf.maxX - 320, y: vf.maxY - 196))
            }
            p.setFrameAutosaveName("SpotLoFiWidget")
        }
        applyLevel()
        panel?.orderFrontRegardless()
        push(lastState)
    }

    func applyLevel() {
        guard let p = panel else { return }
        if onTop {
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            // fica "na mesa": abaixo das janelas, acima do papel de parede
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    func hide() { panel?.orderOut(nil) }

    func push(_ state: [String: Any]) {
        lastState = state
        guard let w = web, isVisible,
              let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        w.evaluateJavaScript("window.upd&&window.upd(\(json))", completionHandler: nil)
    }
}
