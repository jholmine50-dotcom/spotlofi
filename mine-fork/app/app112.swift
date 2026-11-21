// ListenUp v1.1.2 — ligações entre os recursos novos e o app

import Cocoa
import WebKit

extension AppDelegate {

    func setupV112() {
        voice.onEvent = { [weak self] ev in self?.sendToPage(ev) }
        HotkeyManager.shared.onFire = { [weak self] action in self?.hotkeyFired(action) }
        Updater.shared.onEvent = { [weak self] ev in self?.sendToPage(ev) }
        // verifica atualização 10 s depois de abrir e depois a cada 6 horas
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.check(manual: false) }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Updater.shared.check(manual: false) }
    }

    // MARK: links spotlofi:// (app Atalhos, compartilhar playlist)
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme?.lowercased() == "spotlofi" {
            if pageReady { sendToPage(["url": u.absoluteString]) } else { pendingURLs.append(u.absoluteString) }
        }
    }

    // MARK: permissões de microfone para a chamada do "Estudar junto"
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler((origin.host == "127.0.0.1" || origin.host == "localhost") ? .grant : .deny)
    }

    // MARK: página → app (comandos novos). Devolve true quando tratou o comando.
    func handleV112(_ cmd: String, _ body: [String: Any]) -> Bool {
        switch cmd {
        case "ready":
            pageReady = true
            sendToPage(["aiStatus": LocalAI.status(), "version": appVersion])
            for u in pendingURLs { sendToPage(["url": u]) }
            pendingURLs.removeAll()
            return true

        case "state":
            for (k, v) in body where k != "cmd" && k != "scenes" { widgetState[k] = v }
            widget.push(widgetState)
            return false   // o tratamento antigo (barra de menus, "tocando agora") continua

        case "ai":
            let instructions = (body["instructions"] as? String) ?? ""
            let prompt = (body["prompt"] as? String) ?? ""
            let id = (body["id"] as? String) ?? ""
            LocalAI.ask(instructions: instructions, prompt: prompt) { [weak self] text, err in
                var r: [String: Any] = ["aiReply": ["id": id]]
                var inner: [String: Any] = ["id": id]
                if let t = text { inner["text"] = t }
                if let e = err { inner["error"] = e }
                r["aiReply"] = inner
                self?.sendToPage(r)
            }
            return true

        case "aiStatus":
            sendToPage(["aiStatus": LocalAI.status()])
            return true

        case "speak":
            if let t = body["text"] as? String { Speaker.shared.say(t) }
            return true

        case "voice":
            switch (body["mode"] as? String) ?? "" {
            case "push": voice.startPush()
            case "wakeOn": voice.setWake(true)
            case "wakeOff": voice.setWake(false)
            default: voice.cancel()
            }
            return true

        case "hotkeys":
            let map = (body["map"] as? [String: String]) ?? [:]
            let failed = HotkeyManager.shared.apply(map)
            sendToPage(["hotkeysFailed": failed])
            return true

        case "widget":
            if let on = body["on"] as? Bool {
                if on { widget.show(port: port, handler: self, onTop: (body["onTop"] as? Bool) ?? false) } else { widget.hide() }
            } else if let top = body["onTop"] as? Bool {
                widget.onTop = top
                widget.applyLevel()
            }
            return true

        case "shortcutsList":
            ShortcutsBridge.list { [weak self] names in self?.sendToPage(["shortcuts": names]) }
            return true

        case "runShortcut":
            if let n = body["name"] as? String { ShortcutsBridge.runShortcut(n) }
            return true

        case "hideOthers":
            NSApp.hideOtherApplications(nil)
            return true

        case "unhideOthers":
            NSApp.unhideAllApplications(nil)
            return true

        case "updateCheck":
            Updater.shared.check(manual: true)
            return true

        case "updateInstall":
            Updater.shared.install()
            return true

        case "copy":
            if let t = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
            return true

        default:
            return false
        }
    }

    // MARK: atalhos globais
    func hotkeyFired(_ action: String) {
        switch action {
        case "show": showMain()
        case "mini": toggleMini()
        case "voice": talkToAI()
        case "widget": toggleWidgetMenu()
        default: sendToPage(["action": action])
        }
    }

    // MARK: widget
    func widgetAction(_ a: String) {
        switch a {
        case "ready": widget.push(widgetState)
        case "show": showMain()
        default: sendToPage(["action": a])
        }
    }

    @objc func toggleWidgetMenu() {
        sendToPage(["action": "widgetToggle"])
    }

    @objc func talkToAI() {
        sendToPage(["action": "aiOpen"])
        voice.startPush()
    }

    @objc func checkUpdatesMenu() {
        showMain()
        sendToPage(["action": "updatePanel"])
        Updater.shared.check(manual: true)
    }
}

// Seletor de arquivos para <input type="file"> (importar músicas do Mac)
extension AppDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Escolha músicas ou vídeos do seu Mac"
        panel.prompt = "Importar"
        if let w = webView.window {
            panel.beginSheetModal(for: w) { r in completionHandler(r == .OK ? panel.urls : nil) }
        } else {
            panel.begin { r in completionHandler(r == .OK ? panel.urls : nil) }
        }
    }
}
