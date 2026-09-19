// 发条屋 - DeepSeek Harness 原生独立窗口
// 用系统 WebKit 渲染，不依赖任何浏览器；服务未就绪时自动重连
import Cocoa
import CryptoKit
import WebKit

// 内置浏览器「用默认浏览器打开」按钮（带回调的轻量子类）
final class BrowserOpenButton: NSButton {
    var onOpen: (() -> Void)?
    override func performClick(_ sender: Any?) {
        onOpen?()
        super.performClick(sender)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 15        // 最多重试 15 次
    private let retryInterval = 4.0    // 每 4 秒一次，总共约 60 秒
    private var launchBalance: Double? // 启动时的余额基线（推算本次消费）
    private var balanceTimer: Timer?
    private let url = URL(string: "http://127.0.0.1:3080")!
    private var skins: [String] = []   // 三套皮肤 CSS（0=暗金, 1=翡翠晨光, 2=猩红熔岩）
    private var themeIndex = 0
    private let skinNames = ["暗金·深夜", "翡翠·晨光", "猩红·熔岩"]
    private var skinMenuItems: [NSMenuItem] = []
    private var shortcutMonitor: Any? // ⌥⌘1/2/3 快捷键监听（绕过 WKWebView 抢键）
    private var browserWindows: [NSWindow] = [] // 内置浏览器窗口（保持引用防释放）
    private var repaintWorkItem: DispatchWorkItem? // 强制重绘防抖

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 加载两套皮肤并读取上次选择
        skins = [
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-emerald-light", ofType: "css") ?? "", encoding: .utf8)) ?? "",
            (try? String(contentsOfFile: Bundle.main.path(forResource: "skin-scarlet", ofType: "css") ?? "", encoding: .utf8)) ?? "",
        ]
        themeIndex = UserDefaults.standard.integer(forKey: "ftThemeIndex")
        if themeIndex >= skins.count { themeIndex = 0 }
        buildMenu()
        installShortcuts()

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "发条屋"
        window.center()
        window.setFrameAutosaveName("发条屋窗口") // 记住窗口大小和位置
        // 顶部标题栏：透明 + 外观跟随皮肤（暗金=深，翡翠晨光=深绿玻璃渐变）
        window.titlebarAppearsTransparent = true
        let isDarkLaunch = themeIndex != 1
        window.appearance = NSAppearance(named: isDarkLaunch ? .darkAqua : .aqua)
        switch themeIndex {
        case 1:
            window.backgroundColor = AppDelegate.titlebarGlassGradient()
        case 2:
            window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.03, blue: 0.03, alpha: 1) // 猩红熔岩深红黑
        default:
            window.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.114, alpha: 1)
        }

        let config = WKWebViewConfiguration()
        // 生灵层要用 Web Audio 程序化合成机械音效：放开自动播放限制（否则 AudioContext 永远 suspended）
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "fatiaowuSetSkin")
        if let skin = AppDelegate.skinUserScript(css: skins[themeIndex], initialDark: themeIndex == 0) {
            config.userContentController.addUserScript(skin)
        }
        // 生灵层：发条机芯 + 小鲸鱼桌宠（独立脚本，见 resources/alive.js）
        if let alive = AppDelegate.aliveUserScript() {
            config.userContentController.addUserScript(alive)
        }
        webView = WKWebView(frame: rect, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = webView

        // “正在连接服务”提示
        statusLabel = NSTextField(labelWithString: "正在连接发条屋服务…")
        statusLabel.font = .systemFont(ofSize: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(statusLabel)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 先自签 dsh web 鉴权 cookie（secret 持久化在 credentials 里，跨服务重启有效），
        // 写入 WKWebView 后再加载页面，避免服务重启后撞上「authentication required」门页
        seedAuthThenLoad()

        // WKWebView 全屏切换/窗口尺寸变化后偶发陈旧渲染：强制重绘
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(forceRepaint(_:)), name: NSWindow.didResizeNotification, object: window)


    }

    // ---------- dsh web 鉴权自签 ----------

    // base64url（无填充），与 dsh 服务端 encodeBase64Url 一致
    private static func b64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    // 从 ~/.dsh/.credentials.yaml 读取 client-connection/browser-session 的持久化 secret
    private static func browserAuthSecret() -> Data? {
        guard let content = try? String(contentsOfFile: "/Users/yangliu/.dsh/.credentials.yaml", encoding: .utf8) else {
            return nil
        }
        var secretB64: String?
        var inBlock = false
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("client-connection/browser-session:") { inBlock = true; continue }
            if inBlock {
                if t.hasPrefix("secret:") {
                    secretB64 = t.dropFirst("secret:".count).trimmingCharacters(in: .whitespaces)
                    break
                }
                // 进入下一个顶层记录则中止
                if !t.hasPrefix("#"), !t.isEmpty, t.contains(":"), !t.hasPrefix("kind:"), !t.hasPrefix("payload:"), !t.hasPrefix("version:") {
                    break
                }
            }
        }
        guard var b64 = secretB64 else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let secret = Data(base64Encoded: b64), secret.count == 32 else { return nil }
        return secret
    }

    // 复刻 dsh-client-connection 的 cookie 算法：
    // name = "dsh-auth-" + b64url(sha256(authority))
    // value = "v1." + b64url(JSON) + "." + b64url(hmac-sha256(secret, body))
    private static func browserAuthCookie() -> HTTPCookie? {
        guard let secret = browserAuthSecret() else { return nil }
        let authority = "127.0.0.1:3080"
        let name = "dsh-auth-" + b64url(Data(SHA256.hash(data: Data(authority.utf8))))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let expires = now + 30 * 24 * 3600 * 1000 // 30 天，与服务端 maxAgeDays 一致
        let payload = "{\"version\":1,\"authority\":\"\(authority)\",\"issuedAt\":\(now),\"expiresAt\":\(expires)}"
        let body = b64url(Data(payload.utf8))
        let sig = b64url(Data(HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))))
        let value = "v1.\(body).\(sig)"
        return HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "127.0.0.1",
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600),
        ])
    }

    private func seedAuthThenLoad() {
        if let cookie = AppDelegate.browserAuthCookie() {
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
                guard let self = self else { return }
                AppDelegate.log("自签鉴权 cookie 已写入，加载页面")
                self.loadURL()
                self.startBalanceMonitor()
            }
        } else {
            AppDelegate.log("警告：自签鉴权 cookie 失败（secret 缺失或格式不符），直接加载页面")
            loadURL()
            startBalanceMonitor()
        }
    }

    // ---------- 余额/消费监控 ----------

    private func startBalanceMonitor() {
        fetchBalance()
        balanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchBalance() }
        }
    }

    private func fetchBalance() {
        guard let key = AppDelegate.deepseekApiKey() else {
            setStatus("余额不可用")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            // 后台线程只做解析
            var total: Double?
            var symbol = "¥"
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let infos = json["balance_infos"] as? [[String: Any]],
               let info = infos.first(where: { ($0["currency"] as? String) == "CNY" }) ?? infos.first,
               let totalStr = info["total_balance"] as? String,
               let parsed = Double(totalStr) {
                total = parsed
                symbol = (info["currency"] as? String) == "CNY" ? "¥" : "$"
            }
            // 跳回主线程更新 UI
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let t = total else {
                    self.setStatus("余额获取失败")
                    return
                }
                if self.launchBalance == nil { self.launchBalance = t }
                let consumed = max(0, (self.launchBalance ?? t) - t)
                let text = String(format: "余额 %@%.2f · 本次已消费 %@%.2f", symbol, t, symbol, consumed)
                self.setStatus(text)
                AppDelegate.log("余额: \(text)")
            }
        }.resume()
    }

    private func setStatus(_ text: String) {
        webView?.evaluateJavaScript("window.__fatiaowuSetStatus && window.__fatiaowuSetStatus(\(AppDelegate.jsStringLiteral(text)))") { _, _ in }
    }

    // 应用指定皮肤（菜单选择），记忆选择
    private func applySkin(_ index: Int) {
        guard index >= 0 && index < skins.count, !skins[index].isEmpty else { return }
        themeIndex = index
        UserDefaults.standard.set(themeIndex, forKey: "ftThemeIndex")
        let isDark = themeIndex != 1
        // 窗口外观跟随皮肤
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        switch themeIndex {
        case 1:
            window?.backgroundColor = AppDelegate.titlebarGlassGradient()
        case 2:
            window?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.03, blue: 0.03, alpha: 1)
        default:
            window?.backgroundColor = NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.114, alpha: 1)
        }
        // 菜单勾选状态
        for (i, item) in skinMenuItems.enumerated() {
            item.state = (i == themeIndex) ? .on : .off
        }
        let css = skins[themeIndex]
        webView?.evaluateJavaScript("window.__ftSetSkin && window.__ftSetSkin(\(AppDelegate.jsStringLiteral(css)), \(isDark ? "true" : "false"))") { _, _ in }
        webView?.evaluateJavaScript("window.__ftMarkSkin && window.__ftMarkSkin(\(themeIndex))") { _, _ in }
        AppDelegate.log("已切换皮肤: \(skinNames[themeIndex])")
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        applySkin(sender.tag)
    }

    // 设置面板「皮肤」选项 → 通知 Swift 换肤（与快捷键同一套 applySkin）
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "fatiaowuSetSkin" else { return }
        if let index = message.body as? Int, index >= 0, index < skins.count {
            applySkin(index)
        } else if let n = message.body as? NSNumber {
            applySkin(n.intValue)
        }
    }

    // ⌥⌘1/2/3 快捷键：直接监听按键事件（按物理键位识别，不受输入法/键盘布局影响，
    // 也不怕 WKWebView 抢先吃掉按键）。不用 ⌘⇧1/2/3，因为 ⌘⇧3 是系统截图键。
    private func installShortcuts() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard mods == [.command, .option] else { return event }
            // 物理键位：1=18, 2=19, 3=20（ANSI 键位，任何布局都一致）
            switch event.keyCode {
            case 18: self.applySkin(0); AppDelegate.log("快捷键 ⌥⌘1 → 暗金·深夜")
            case 19: self.applySkin(1); AppDelegate.log("快捷键 ⌥⌘2 → 翡翠·晨光")
            case 20: self.applySkin(2); AppDelegate.log("快捷键 ⌥⌘3 → 猩红·熔岩")
            default: return event
            }
            return nil // 已处理，不再传给菜单/网页
        }
    }

    // 生成标题栏「深绿玻璃」渐变（浅色皮肤用）
    private static func titlebarGlassGradient() -> NSColor {
        let image = NSImage(size: NSSize(width: 2, height: 64))
        image.lockFocus()
        let grad = NSGradient(
            starting: NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.62, alpha: 1),
            ending: NSColor(calibratedRed: 0.63, green: 0.79, blue: 0.69, alpha: 1)
        )!
        grad.draw(in: NSRect(x: 0, y: 0, width: 2, height: 64), angle: -90)
        image.unlockFocus()
        return NSColor(patternImage: image)
    }

    // 从 ~/.dsh/.credentials.yaml 读取 DeepSeek API 密钥
    private static func deepseekApiKey() -> String? {
        guard let content = try? String(contentsOfFile: "/Users/yangliu/.dsh/.credentials.yaml", encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "DEEPSEEK_API_KEY" {
                return parts[1]
            }
        }
        return nil
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 发条屋",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let skinItem = NSMenuItem(title: "切换皮肤", action: nil, keyEquivalent: "")
        let skinSubmenu = NSMenu()
        for (i, name) in skinNames.enumerated() {
            let mi = NSMenuItem(title: name,
                                action: #selector(selectSkin(_:)),
                                keyEquivalent: "\(i + 1)")
            mi.keyEquivalentModifierMask = [.command, .option]
            mi.tag = i
            mi.target = self
            mi.state = (i == themeIndex) ? .on : .off
            skinMenuItems.append(mi)
            skinSubmenu.addItem(mi)
        }
        skinItem.submenu = skinSubmenu
        appMenu.addItem(skinItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 发条屋",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单：没有它，⌘C/⌘V/⌘X/⌘A 不会进响应链，WKWebView 收不到 copy:/paste:，
        // 整个界面（选中文字、输入框粘贴）都会失效。
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
        let menus = mainMenu.items.compactMap { $0.submenu?.title }.joined(separator: "/")
        let editItems = (editItem.submenu?.items ?? [])
            .filter { !$0.isSeparatorItem }
            .map { "\($0.title)⌘\($0.keyEquivalent)" }
            .joined(separator: " ")
        AppDelegate.log("菜单自检: [\(menus)] 编辑菜单项: \(editItems)")
    }

    // 读取内置皮肤 CSS，生成注入脚本（在页面最早期注入，避免闪烁）
    // 生灵层脚本：从 bundle 读 resources/alive.js 直接注入（atDocumentEnd，此时 DOM 已就绪）
    private static func aliveUserScript() -> WKUserScript? {
        guard let path = Bundle.main.path(forResource: "alive", ofType: "js"),
              let js = try? String(contentsOfFile: path, encoding: .utf8),
              !js.isEmpty else {
            log("生灵层加载失败：alive.js 未找到或为空")
            return nil
        }
        log("生灵层加载成功：\(js.count) 字符")
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    private static func skinUserScript(css: String, initialDark: Bool) -> WKUserScript? {
        guard !css.isEmpty else {
            log("皮肤加载失败：CSS 为空")
            return nil
        }
        log("皮肤加载成功：\(css.count) 字符")
        let cssLiteral = jsStringLiteral(css)
        // 加载用户头像蒙版 PNG（FTW logo，形状在 alpha 通道）→ data URI，渲染时用 --ft-accent 着色
        var userAvatarURI = ""
        if let pngPath = Bundle.main.path(forResource: "user-avatar", ofType: "png"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: pngPath)) {
            userAvatarURI = "data:image/png;base64," + data.base64EncodedString()
        }
        let userAvLiteral = jsStringLiteral(userAvatarURI)
        let js = """
        (function () {
          var cssText = \(cssLiteral);
          var USER_AV = \(userAvLiteral);

          // 按顶层大括号拆分 CSS 规则
          function splitCss(css) {
            var rules = [], depth = 0, start = 0, inComment = false, inString = null;
            for (var i = 0; i < css.length; i++) {
              var c = css.charAt(i), n = css.charAt(i + 1);
              if (inComment) {
                if (c === '*' && n === '/') { inComment = false; i++; }
                continue;
              }
              if (inString) {
                if (c === '\\\\') { i++; }
                else if (c === inString) { inString = null; }
                continue;
              }
              if (c === '/' && n === '*') { inComment = true; i++; continue; }
              if (c === '"' || c === "'") { inString = c; continue; }
              if (c === '{') { depth++; }
              else if (c === '}') {
                depth--;
                if (depth === 0) { rules.push(css.slice(start, i + 1)); start = i + 1; }
              }
            }
            return rules;
          }

          // 注入样式表
          var s = document.createElement('style');
          s.id = 'fatiaowu-skin';
          s.type = 'text/css';
          (document.documentElement || document.head || document.body).appendChild(s);
          var inserted = 0;
          try {
            var sheet = s.sheet;
            if (sheet && sheet.insertRule) {
              var rules = splitCss(cssText);
              for (var i = 0; i < rules.length; i++) {
                try { sheet.insertRule(rules[i], sheet.cssRules.length); inserted++; } catch (e) {}
              }
            }
          } catch (e) {}
          // 兜底：如果 CSSOM 方式失败，直接写 textContent
          if (inserted === 0) {
            try { s.textContent = cssText; } catch (e) {}
          }

          // 主题深浅：跟随皮肤（暗金=深，翡翠晨光=浅）
          var __ftDark = \(initialDark ? "true" : "false");
          function forceTheme() {
            if (document.documentElement) { document.documentElement.style.colorScheme = __ftDark ? 'dark' : 'light'; }
            if (!document.body) return;
            if (__ftDark) {
              if (!document.body.hasAttribute('data-ds-dark-theme')) { document.body.setAttribute('data-ds-dark-theme', ''); }
            } else {
              if (document.body.hasAttribute('data-ds-dark-theme')) { document.body.removeAttribute('data-ds-dark-theme'); }
            }
          }
          forceTheme();
          if (window.MutationObserver) {
            var obs = new MutationObserver(function () { forceTheme(); });
            if (document.body) {
              obs.observe(document.body, { attributes: true, attributeFilter: ['data-ds-dark-theme'] });
            }
            document.addEventListener('DOMContentLoaded', function () {
              if (document.body) {
                obs.observe(document.body, { attributes: true, attributeFilter: ['data-ds-dark-theme'] });
              }
              forceTheme();
            });
          }

          // 余额/消费状态信息条（会话框上方，细小不抢眼）
          var __fatiaowuPending = null;
          function ensureStatusBar() {
            if (document.getElementById('fatiaowu-status')) return;
            var el = document.createElement('div');
            el.id = 'fatiaowu-status';
            el.style.cssText = 'position:fixed;top:50px;right:28px;z-index:999;font-size:11px;line-height:16px;color:var(--ft-status);letter-spacing:.3px;font-weight:400;pointer-events:none;text-shadow:0 1px 3px var(--ft-status-shadow);white-space:nowrap;';
            el.textContent = __fatiaowuPending !== null ? __fatiaowuPending : '余额加载中…';
            document.body.appendChild(el);
          }
          window.__fatiaowuSetStatus = function (t) {
            __fatiaowuPending = t;
            ensureStatusBar();
            var el = document.getElementById('fatiaowu-status');
            if (el) el.textContent = t;
          };
          if (document.body) { ensureStatusBar(); }
          else { document.addEventListener('DOMContentLoaded', ensureStatusBar); }

          // 对话区空白的装饰「灯环」（藏在内容后面，填补空洞不抢眼）
          function ensureCenterMark() {
            if (document.getElementById('fatiaowu-mark')) return;
            var m = document.createElement('div');
            m.id = 'fatiaowu-mark';
            m.style.cssText = 'position:fixed;top:62%;left:calc(50% + 134px);transform:translate(-50%,-50%);width:380px;height:380px;z-index:-1;pointer-events:none;opacity:.6;';
            m.innerHTML = '<svg width="380" height="380" viewBox="0 0 380 380" fill="none" xmlns="http://www.w3.org/2000/svg"><defs><radialGradient id="fg" cx="50%" cy="50%" r="50%"><stop offset="0" style="stop-color:var(--ft-accent-bg)"/><stop offset="1" stop-color="rgba(217,164,65,0)"/></radialGradient></defs><circle cx="190" cy="190" r="160" fill="url(#fg)"/><circle cx="190" cy="190" r="102" style="stroke:var(--ft-accent-soft)" stroke-width="1"/><circle cx="190" cy="190" r="160" style="stroke:var(--ft-accent-softer)" stroke-width="1" stroke-dasharray="2 7"/></svg>';
            document.body.appendChild(m);
          }
          if (document.body) { ensureCenterMark(); }
          else { document.addEventListener('DOMContentLoaded', ensureCenterMark); }

          // ===== 双方头像：我=皮肤色 FTW 立方体（蒙版着色，换肤自动变色），你=小鲸鱼 =====
          var WHALE_PATH = "M22.9168 1.43018C22.6713 1.31018 22.5658 1.53918 22.4223 1.65519C22.3733 1.69269 22.3318 1.74169 22.2903 1.78669C21.9317 2.1697 21.5127 2.42121 20.9657 2.39121C20.1657 2.34621 19.4827 2.59771 18.8787 3.20973C18.7502 2.45521 18.3236 2.0047 17.6746 1.71569C17.3351 1.56568 16.9916 1.41518 16.7536 1.08867C16.5876 0.856163 16.5421 0.597155 16.4591 0.341647C16.4061 0.187643 16.3536 0.0301382 16.1761 0.00363739C15.9836 -0.0263635 15.9081 0.135141 15.8326 0.270145C15.5306 0.822162 15.4136 1.43018 15.4251 2.0462C15.4516 3.43174 16.0366 4.53527 17.1991 5.3203C17.3311 5.4103 17.3651 5.5003 17.3236 5.63181C17.2441 5.90231 17.1501 6.16482 17.0671 6.43533C17.0141 6.60784 16.9351 6.64584 16.7501 6.57033C16.1121 6.30383 15.5611 5.90931 15.074 5.4328C14.2475 4.63328 13.5 3.75075 12.568 3.05973C12.349 2.89822 12.13 2.74822 11.9034 2.60522C10.9524 1.68169 12.028 0.923165 12.277 0.833162C12.5375 0.739159 12.3675 0.41615 11.5259 0.42015C10.6844 0.42365 9.91439 0.705658 8.93286 1.08117C8.78935 1.13767 8.63835 1.17867 8.48384 1.21267C7.59332 1.04367 6.66829 1.00617 5.70226 1.11517C3.88321 1.31768 2.43016 2.1777 1.36213 3.64575C0.0790928 5.4103 -0.222916 7.41536 0.146595 9.50642C0.535106 11.7105 1.66014 13.535 3.38869 14.9616C5.18125 16.4406 7.24581 17.1657 9.60138 17.0266C11.0319 16.9441 12.6245 16.7526 14.421 15.2321C14.874 15.4576 15.3496 15.5476 16.1381 15.6151C16.7456 15.6716 17.3306 15.5851 17.7836 15.4911C18.4931 15.3411 18.4441 14.6841 18.1876 14.5636C16.1081 13.595 16.5646 13.9891 16.1496 13.67C17.2061 12.42 18.8202 10.1979 19.3182 7.17235C19.3672 6.83834 19.4297 6.36783 19.4222 6.09732C19.4182 5.93231 19.4562 5.86831 19.6447 5.84931C20.1657 5.78931 20.6712 5.64681 21.1357 5.3913C22.4833 4.65528 23.0268 3.44624 23.1548 1.9972C23.1738 1.77569 23.1508 1.54668 22.9168 1.43018ZM11.1749 14.4736C9.15936 12.889 8.18184 12.3675 7.77832 12.39C7.40081 12.4125 7.46881 12.8445 7.55182 13.126C7.63882 13.404 7.75182 13.5955 7.91033 13.8396C8.01983 14.0011 8.09533 14.2411 7.80083 14.4216C7.15181 14.8231 6.02327 14.2866 5.97027 14.2601C4.65673 13.4865 3.5587 12.4655 2.78467 11.069C2.03715 9.72493 1.60314 8.28289 1.53164 6.74384C1.51264 6.37233 1.62214 6.24082 1.99215 6.17332C2.47916 6.08332 2.98118 6.06432 3.46769 6.13582C5.52476 6.43633 7.27581 7.35586 8.74385 8.8129C9.58188 9.64243 10.2159 10.634 10.8689 11.6025C11.5634 12.631 12.3105 13.611 13.262 14.4146C13.598 14.6961 13.866 14.9101 14.1225 15.0681C13.349 15.1546 12.058 15.1731 11.1749 14.4746ZM12.141 8.25988C12.141 8.09488 12.273 7.96338 12.439 7.96338C12.4765 7.96338 12.5105 7.97088 12.541 7.98188C12.5825 7.99688 12.6205 8.01938 12.6505 8.05338C12.7035 8.10588 12.7335 8.18088 12.7335 8.25988C12.7335 8.42489 12.6015 8.55639 12.4355 8.55639C12.2695 8.55639 12.141 8.42489 12.141 8.25988ZM15.1415 9.79893C14.949 9.87793 14.7565 9.94544 14.5715 9.95294C14.2845 9.96794 13.9715 9.85143 13.8015 9.70893C13.5375 9.48742 13.3485 9.36342 13.2695 8.97691C13.2355 8.8119 13.2545 8.55639 13.2845 8.40989C13.3525 8.09438 13.277 7.89187 13.0545 7.70787C12.8735 7.55786 12.643 7.51636 12.39 7.51636C12.2955 7.51636 12.209 7.47486 12.1445 7.44136C12.039 7.38886 11.9519 7.25735 12.035 7.09585C12.0615 7.04335 12.19 6.91584 12.22 6.89334C12.5635 6.69784 12.9595 6.76184 13.326 6.90834C13.6655 7.04735 13.9225 7.30236 14.292 7.66287C14.6695 8.09838 14.7375 8.21838 14.9525 8.54539C15.1225 8.8009 15.277 9.06341 15.3831 9.36392C15.4471 9.55142 15.3641 9.70493 15.1415 9.79893Z";
          function addAvatars() {
            var urows = document.querySelectorAll('.Sixlwa_userRow:not([data-ftav])');
            for (var i = 0; i < urows.length; i++) {
              var row = urows[i];
              row.setAttribute('data-ftav', '1');
              if (!USER_AV) continue;
              row.style.position = 'relative';
              var av = document.createElement('div');
              av.className = 'ft-av-user';
              av.style.cssText = 'position:absolute;right:-60px;top:4px;width:32px;height:32px;border-radius:8px;border:1px solid var(--ft-accent-soft);background:var(--ft-accent-bg);box-shadow:0 0 6px var(--ft-accent-bg);';
              // 蒙版铺满整格（mask-size:100%），留白由蒙版本体控制（见 scripts/make-avatar-mask.py）：
              // 旧版 `center/76%` 把「外圈描边+间隙」一起缩进来，32px 下只有 0.6px，糊成一团。
              av.innerHTML = '<div style="width:100%;height:100%;border-radius:inherit;background:var(--ft-accent);-webkit-mask:url(' + USER_AV + ') center/100% 100% no-repeat;mask:url(' + USER_AV + ') center/100% 100% no-repeat;"></div>';
              row.appendChild(av);
            }
            var arows = document.querySelectorAll('.hWmORq_root:not([data-ftav])');
            for (var j = 0; j < arows.length; j++) {
              var arow = arows[j];
              arow.setAttribute('data-ftav', '1');
              arow.style.position = 'relative';
              var av2 = document.createElement('div');
              av2.className = 'ft-av-asst';
              av2.style.cssText = 'position:absolute;left:-48px;top:4px;width:32px;height:32px;border-radius:8px;background:var(--ft-accent-bg);border:1px solid var(--ft-accent-softer);display:flex;align-items:center;justify-content:center;';
              av2.innerHTML = '<svg width="24" height="18" viewBox="0 0 23.16 17.04" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="' + WHALE_PATH + '" style="fill:var(--ft-accent)"/></svg>';
              arow.insertBefore(av2, arow.firstChild);
            }
          }
          function watchAvatars() {
            addAvatars();
            var root = document.querySelector('.EvIC1a_scroll') || document.body;
            if (window.MutationObserver) {
              new MutationObserver(function () { addAvatars(); }).observe(root, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchAvatars(); }
          else { document.addEventListener('DOMContentLoaded', watchAvatars); }

          // ===== 表情包：金色表情按钮 + 面板 =====
          var EMOJIS = ['😀','😁','😂','🤣','😊','😍','🥰','😘','😜','🤔','😎','🥳','😢','😭','😤','🤯','😴','🤗','🤝','👍','👎','👏','🙏','💪','🔥','✨','⭐','🌟','💖','💛','💚','💙','🫶','🎉','🎂','🍰','☕','🍜','🍺','🐳','🖼️','🕰️','🌙','⚡','💡','✅','❌','⚠️'];
          function ensureEmojiButton() {
            if (document.getElementById('ft-emoji-btn')) return;
            var addBtn = document.querySelector('.uV2eYG_add');
            if (!addBtn || !addBtn.parentElement) return;
            var btn = document.createElement('button');
            btn.id = 'ft-emoji-btn';
            btn.type = 'button';
            btn.style.cssText = 'box-sizing:border-box;flex:none;width:28px;height:28px;border-radius:8px;border:1px solid var(--ft-accent-soft);background:var(--ft-accent-bg);cursor:pointer;font-size:15px;line-height:1;display:inline-flex;align-items:center;justify-content:center;';
            btn.textContent = '😊';
            btn.title = '表情';
            btn.addEventListener('click', function (e) { e.stopPropagation(); toggleEmojiPanel(btn); });
            addBtn.parentElement.insertBefore(btn, addBtn.nextElementSibling);
          }
          function toggleEmojiPanel(btn) {
            var old = document.getElementById('ft-emoji-panel');
            if (old) { old.remove(); return; }
            var panel = document.createElement('div');
            panel.id = 'ft-emoji-panel';
            panel.style.cssText = 'position:fixed;z-index:1200;padding:10px;border-radius:12px;border:1px solid var(--ft-accent-softer);background:rgba(23,29,45,.97);box-shadow:0 8px 28px rgba(0,0,0,.5);display:grid;grid-template-columns:repeat(8,30px);gap:2px;';
            for (var i = 0; i < EMOJIS.length; i++) {
              var b = document.createElement('button');
              b.type = 'button';
              b.style.cssText = 'width:30px;height:30px;border:none;background:transparent;border-radius:6px;cursor:pointer;font-size:17px;line-height:1;';
              b.textContent = EMOJIS[i];
              b.addEventListener('click', function (ev) {
                ev.stopPropagation();
                insertEmoji(this.textContent);
                panel.remove();
              });
              panel.appendChild(b);
            }
            var r = btn.getBoundingClientRect();
            panel.style.left = Math.max(8, r.left) + 'px';
            panel.style.bottom = (window.innerHeight - r.top + 10) + 'px';
            document.body.appendChild(panel);
            setTimeout(function () {
              document.addEventListener('click', function h(e) {
                if (!panel.contains(e.target) && e.target.id !== 'ft-emoji-btn') { panel.remove(); document.removeEventListener('click', h); }
              });
            }, 0);
          }
          function insertEmoji(emo) {
            var ta = document.querySelector('.uV2eYG_input');
            if (!ta) return;
            var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
            var start = ta.selectionStart != null ? ta.selectionStart : ta.value.length;
            var end = ta.selectionEnd != null ? ta.selectionEnd : start;
            var val = ta.value.slice(0, start) + emo + ta.value.slice(end);
            setter.call(ta, val);
            ta.dispatchEvent(new Event('input', { bubbles: true }));
            ta.focus();
            ta.setSelectionRange(start + emo.length, start + emo.length);
          }
          function watchEmojiButton() {
            ensureEmojiButton();
            var root = document.querySelector('.wSkVaW_composerStack') || document.querySelector('.uV2eYG_root') || document.body;
            if (window.MutationObserver) {
              new MutationObserver(function () { ensureEmojiButton(); }).observe(root, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchEmojiButton(); }
          else { document.addEventListener('DOMContentLoaded', watchEmojiButton); }

          // ===== 设置面板：皮肤栏目（插入通用设置区块内，Agent 预设之后，不置底） =====
          window.__ftMarkSkin = function (idx) {
            var cards = document.querySelectorAll('#ft-skin-section [data-ftskin]');
            for (var i = 0; i < cards.length; i++) {
              var on = parseInt(cards[i].getAttribute('data-ftskin'), 10) === idx;
              cards[i].style.borderColor = on ? 'var(--ft-accent)' : 'var(--ft-accent-softer)';
              cards[i].style.background = on ? 'var(--ft-accent-bg)' : 'transparent';
              cards[i].style.boxShadow = on ? '0 0 0 1px var(--ft-accent), 0 4px 14px rgba(0,0,0,.35)' : 'none';
            }
          };
          function ensureSkinSelector() {
            var content = document.querySelector('.VOzbGW_content');
            if (!content) return;
            if (document.getElementById('ft-skin-section')) return;
            var sec = document.createElement('div');
            sec.id = 'ft-skin-section';
            sec.style.cssText = 'flex-direction:column;gap:12px;padding:18px 14px;display:flex;border-bottom:1px solid var(--dsw-alias-border-l2);';
            var head = document.createElement('div');
            head.style.cssText = 'display:flex;align-items:center;gap:8px;color:var(--dsw-alias-label-primary);font-size:15px;font-weight:500;line-height:22px;';
            var dot = document.createElement('span');
            dot.style.cssText = 'width:6px;height:6px;border-radius:50%;background:var(--ft-accent);flex:none;';
            head.appendChild(dot);
            head.appendChild(document.createTextNode('皮肤'));
            sec.appendChild(head);
            var hint = document.createElement('div');
            hint.style.cssText = 'color:var(--dsw-alias-label-tertiary);font-size:12px;line-height:18px;';
            hint.textContent = '选择你喜欢的皮肤；也可用快捷键 ⌥⌘1 / ⌥⌘2 / ⌥⌘3 快速切换';
            sec.appendChild(hint);
            var row = document.createElement('div');
            row.style.cssText = 'display:flex;gap:10px;';
            var skins = [
              { name: '暗金·深夜', bg: 'linear-gradient(160deg,#161c2e 0%,#101726 55%,#0a0e17 100%)', accent: 'rgba(217,164,65,0.85)', dark: true },
              { name: '翡翠·晨光', bg: 'linear-gradient(160deg,#f0f5ea 0%,#e0e9de 55%,#d2e2d5 100%)', accent: 'rgba(15,157,110,0.9)', dark: false },
              { name: '猩红·熔岩', bg: 'linear-gradient(160deg,#2b0e0e 0%,#180808 55%,#0b0404 100%)', accent: 'rgba(255,71,87,0.9)', dark: true }
            ];
            for (var k = 0; k < skins.length; k++) {
              (function (idx) {
                var s = skins[idx];
                var card = document.createElement('button');
                card.type = 'button';
                card.setAttribute('data-ftskin', idx);
                card.style.cssText = 'flex:1;min-width:0;padding:0;border-radius:14px;border:1px solid var(--ft-accent-softer);background:transparent;cursor:pointer;overflow:hidden;display:flex;flex-direction:column;transition:border-color .15s,box-shadow .15s;';
                var prev = document.createElement('div');
                prev.style.cssText = 'height:72px;background:' + s.bg + ';position:relative;flex:none;';
                var side = document.createElement('div');
                side.style.cssText = 'position:absolute;left:0;top:0;bottom:0;width:15px;background:' + s.accent + ';opacity:.55;';
                var bubble = document.createElement('div');
                bubble.style.cssText = 'position:absolute;left:24px;bottom:12px;width:54%;height:14px;border-radius:7px;background:' + (s.dark ? 'rgba(255,255,255,.14)' : 'rgba(255,255,255,.65)') + ';border:1px solid ' + s.accent + ';';
                var bubble2 = document.createElement('div');
                bubble2.style.cssText = 'position:absolute;left:24px;top:12px;width:38%;height:9px;border-radius:5px;background:' + (s.dark ? 'rgba(255,255,255,.07)' : 'rgba(255,255,255,.5)') + ';';
                prev.appendChild(side);
                prev.appendChild(bubble2);
                prev.appendChild(bubble);
                var name = document.createElement('div');
                name.style.cssText = 'padding:8px 6px;font-size:13px;line-height:20px;text-align:center;color:var(--dsw-alias-label-primary);';
                name.textContent = s.name;
                card.appendChild(prev);
                card.appendChild(name);
                card.addEventListener('click', function () {
                  try { window.webkit.messageHandlers.fatiaowuSetSkin.postMessage(idx); } catch (e) {}
                });
                row.appendChild(card);
              })(k);
            }
            sec.appendChild(row);
            // 插入到通用设置第一个栏目（Agent 预设）之后，不置底
            var sections = content.querySelectorAll('._WvWnq_section, [class*="_section"]');
            var anchor = sections.length > 0 ? sections[0] : null;
            if (anchor && anchor.parentNode) {
              if (anchor.nextSibling) { anchor.parentNode.insertBefore(sec, anchor.nextSibling); }
              else { anchor.parentNode.appendChild(sec); }
            } else if (content.firstChild) {
              content.insertBefore(sec, content.firstChild);
            } else {
              content.appendChild(sec);
            }
            window.__ftMarkSkin(0);
          }
          function watchSkinSelector() {
            ensureSkinSelector();
            if (window.MutationObserver) {
              new MutationObserver(function () { ensureSkinSelector(); }).observe(document.body, { childList: true, subtree: true });
            }
          }
          if (document.body) { watchSkinSelector(); }
          else { document.addEventListener('DOMContentLoaded', watchSkinSelector); }

          // 皮肤切换：替换 #fatiaowu-skin 样式内容（配色与背景整体换肤）
          window.__ftSetSkin = function (css, dark) {
            if (typeof dark === 'boolean') { __ftDark = dark; }
            var s = document.getElementById('fatiaowu-skin');
            if (!s) {
              s = document.createElement('style');
              s.id = 'fatiaowu-skin';
              (document.head || document.documentElement).appendChild(s);
            }
            s.textContent = css;
            forceTheme();
          };
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // 把字符串安全地转成 JS 字符串字面量
    private static func jsStringLiteral(_ s: String) -> String {
        var out = "'"
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u{%04X}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "'"
    }

    private func loadURL() {
        webView.load(URLRequest(url: url))
    }

    // 首次加载失败：启动自动重连
    private func handleLoadFailure() {
        if retryTimer == nil && retryCount == 0 {
            statusLabel.stringValue = "正在连接发条屋服务…"
            statusLabel.isHidden = false
            scheduleNextRetry()
        }
        // 重试期间再次失败就忽略，由定时器驱动下一次尝试
    }

    private func scheduleNextRetry() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryOnce()
            }
        }
    }

    private func retryOnce() {
        guard retryCount < maxRetries else {
            showServerDownAlert()
            return
        }
        retryCount += 1
        statusLabel.stringValue = "正在连接发条屋服务…（第 \(retryCount) 次尝试）"
        loadURL()
        scheduleNextRetry()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryTimer?.invalidate()
        retryTimer = nil
        statusLabel.isHidden = true
        webView.evaluateJavaScript("window.__ftMarkSkin && window.__ftMarkSkin(\(themeIndex))") { _, _ in }
        // TEMP 设置导航结构探针
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.webView?.evaluateJavaScript("""
            (function(){
              var panel = document.querySelector('.VOzbGW_panel');
              if (!panel) return 'no-panel';
              var out = [];
              // 找面板里所有直接可见的文本项（导航/内容），带 class
              function walk(el, depth) {
                if (depth > 4) return;
                for (var i = 0; i < el.children.length; i++) {
                  var c = el.children[i];
                  var t = (c.textContent || '').trim();
                  if (c.children.length === 0 && t.length < 30 && t.length > 0) {
                    out.push('LEAF ' + t + ' | ' + c.tagName + '.' + String(c.className||'').substring(0,45));
                  }
                  walk(c, depth + 1);
                }
              }
              walk(panel, 0);
              return out.slice(0, 40).join('\n');
            })()
            """) { result, _ in
                if let s = result as? String { AppDelegate.log("导航探针: \n\(s)") }
            }
        }
        diagnoseSkin()
    }

    // 页面加载后自动检查皮肤是否生效，写入日志
    private func diagnoseSkin() {
        // 生灵层自检：/tmp/ft-alive.flag 内容为 idle|busy，强制到该状态后全窗截图 + 机芯特写
        if FileManager.default.fileExists(atPath: "/tmp/ft-alive.flag") {
            let raw = (try? String(contentsOfFile: "/tmp/ft-alive.flag", encoding: .utf8)) ?? ""
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.probeAlive(force: mode.isEmpty ? "idle" : mode)
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/ft-snapshot.flag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.captureSnapshot()
            }
        }
        webView.evaluateJavaScript("""
        JSON.stringify({
          style: !!document.getElementById('fatiaowu-skin'),
          dark: document.body.hasAttribute('data-ds-dark-theme'),
          bg: getComputedStyle(document.body).getPropertyValue('--dsw-alias-bg-base'),
          brand: getComputedStyle(document.body).getPropertyValue('--dsw-alias-brand-primary'),
          bubble: getComputedStyle(document.body).getPropertyValue('--dsw-specific-bubble'),
          side: getComputedStyle(document.body).getPropertyValue('--dsw-specific-sidebar-fill'),
          art: getComputedStyle(document.body).backgroundImage !== 'none',
          title: document.title,
          bodyEls: document.body ? document.body.getElementsByTagName('*').length : -1
        })
        """) { result, _ in
            if let r = result as? String {
                AppDelegate.log("页面诊断: \(r)")
            }
        }
        // 3 秒后再复查一次，观察主题属性是否被插件来回切换
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("JSON.stringify({dark: document.body.hasAttribute('data-ds-dark-theme'), bar: !!document.getElementById('fatiaowu-status')})") { result, _ in
                if let r = result as? String {
                    AppDelegate.log("状态条: \(r)")
                }
            }
        }
        // 2.5 秒后检查左上角品牌区（无框方案：border 应为 0px、字标应为强调色、牌内字母应为墨色），换 dsh 版本后靠它快速回归
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("""
            (function () {
              function box(sel) {
                var el = document.querySelector(sel);
                if (!el) return sel + '=缺失';
                var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
                return sel + '=' + Math.round(r.width) + 'x' + Math.round(r.height) + '@' + Math.round(r.left) + ',' + Math.round(r.top)
                  + ' ' + cs.display
                  + ' border:' + cs.borderTopWidth + '/' + cs.borderTopStyle
                  + ' bg:' + cs.backgroundImage.slice(0, 12)
                  + ' color:' + cs.color;
              }
              var bn = document.querySelector('[class*="brandName"]');
              return JSON.stringify({
                collapsed: !!document.querySelector('[data-sidebar-collapsed]'),
                wordmark: document.querySelectorAll('svg[viewBox^="26 0 156"]').length,
                name: box('[class*="brandName"]'),
                mark: box('[class*="brandMark"]'),
                badgeInk: bn ? getComputedStyle(bn).getPropertyValue('--dsw-alias-label-primary-inverted').trim() : ''
              });
            })()
            """) { result, _ in
                if let r = result as? String { AppDelegate.log("品牌探针: \(r)") }
            }
        }

        // 10 秒后检查头像挂载数量（需要会话里有消息才会出现行元素）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.evaluateJavaScript("""
            JSON.stringify({
              userRows: document.querySelectorAll('.Sixlwa_userRow').length,
              userAv: document.querySelectorAll('.ft-av-user').length,
              asstAv: document.querySelectorAll('.ft-av-asst').length,
              maskPainted: (function(){ var el = document.querySelector('.ft-av-user div'); return el ? getComputedStyle(el).backgroundColor : 'n/a'; })()
            })
            """) { result, _ in
                if let r = result as? String {
                    AppDelegate.log("头像探针: \(r)")
                }
            }
        }
    }

    // 生灵层自检：强制运转状态 → 采两次状态（间隔 1s，比较齿轮角度证明真的在转）→ 全窗图 + 机芯特写
    private func probeAlive(force: String) {
        guard let wv = webView else { return }

        // settings 模式：先点开设置面板，验证「生灵」栏目是否插进去了
        if force == "settings" {
            wv.evaluateJavaScript("""
            (function(){
              var area = document.querySelector('[class$="_settingsArea"]');
              if (!area) return 'no-settingsArea';
              var b = area.querySelector('button,[role="button"]');
              if (!b) return 'no-button';
              b.click();
              return 'clicked';
            })()
            """) { r, _ in
                AppDelegate.log("生灵探针[settings]: 打开设置 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){
                  var s = document.getElementById('ft-alive-section');
                  var secs = document.querySelectorAll('[class$="_content"] [class*="_section"]');
                  return JSON.stringify({ alive: !!s, sections: secs.length,
                    skin: !!document.getElementById('ft-skin-section'),
                    toggles: s ? s.querySelectorAll('button').length : 0,
                    label: s ? s.textContent.replace(/\\s+/g,' ').slice(0,80) : null });
                })()
                """) { r, _ in
                    AppDelegate.log("生灵探针[settings] 栏目: \(r as? String ?? "nil")")
                }
                let c = WKSnapshotConfiguration()
                c.snapshotWidth = 1180
                self.writeSnapshot(wv, c, to: "/tmp/ft-alive-settings.png", label: "设置面板")
            }
            return
        }

        // tok 模式：核对真实 token 遥测（dsh 统计胶囊 aria-label + 传输层账本）
        if force == "tok" {
            let dump = "window.__ftAliveDebug ? JSON.stringify({pill: window.__ftAliveDebug.pill(), tele: window.__ftAliveDebug.state().tele, text: window.__ftAliveDebug.state().text, title: window.__ftAliveDebug.state().title}) : 'no-alive'"
            wv.evaluateJavaScript(dump) { r, _ in
                AppDelegate.log("用量探针: \(r as? String ?? "nil")")
            }
            // 真实会话可能还没有统计胶囊（新会话 steps=0 时不渲染）——注入同结构的假胶囊验证解析链路
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){
                  var real = document.querySelector('[data-composer-stats]');
                  if (real) return 'real-pill-present';
                  var d = document.createElement('div');
                  d.setAttribute('data-composer-stats', '1');
                  d.style.cssText = 'position:fixed;left:-9999px;top:0;';
                  var a = document.createElement('button');
                  a.setAttribute('aria-label', '24.6k tok · 缓存命中 92%');
                  var b = document.createElement('button');
                  b.setAttribute('aria-label', '3 轮 12 步 · 38 tok/s');
                  d.appendChild(a); d.appendChild(b);
                  document.body.appendChild(d);
                  return 'fake-pill-injected';
                })()
                """) { r, _ in
                    AppDelegate.log("用量探针: \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(dump) { r, _ in
                    AppDelegate.log("用量探针[注入后]: \(r as? String ?? "nil")")
                }
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 8), y: max(0, y - 8), width: w + 16, height: h + 16)
                    c.snapshotWidth = NSNumber(value: Int((w + 16) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-tok.png", label: "机芯读数")
                }
                wv.evaluateJavaScript("(function(){var d=document.querySelector('[data-composer-stats][style]');if(d)d.remove();return 'cleaned';})()") { _, _ in }
            }
            return
        }

        // liveflow 模式：走真实判据（注入假「停止生成」按钮）→ 灌合成用量 → 撤按钮触发完成，
        // 端到端验证「实时速率 → 转速 → 本轮增量 → 上弦音」这条链路（不触碰真实会话）
        if force == "liveflow" {
            let dump = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
            func readState(_ tag: String) {
                wv.evaluateJavaScript(dump) { r, _ in
                    AppDelegate.log("实时用量链路[\(tag)]: \(r as? String ?? "nil")")
                }
            }
            wv.evaluateJavaScript("""
            (function(){
              var b = document.createElement('button');
              b.id = 'ft-fake-stop';
              b.setAttribute('aria-label', '停止生成');
              b.style.cssText = 'position:fixed;left:-9999px;top:0;';
              document.body.appendChild(b);
              return 'injected';
            })()
            """) { r, _ in
                AppDelegate.log("实时用量链路: 注入假停止按钮 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.feed(5, 420)") { r, _ in
                    AppDelegate.log("实时用量链路: 灌合成用量 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { readState("t1 运转中") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { readState("t2 运转中") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-fake-stop');if(e)e.remove();return 'removed';})()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                readState("完成后(期望 done + 本轮增量)")
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 8), y: max(0, y - 8), width: w + 16, height: h + 16)
                    c.snapshotWidth = NSNumber(value: Int((w + 16) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-liveflow.png", label: "机芯读数[完成后]")
                }
            }
            return
        }

        // setopen 模式：查清设置面板的真实打开方式，以及「生灵」栏目到底被插到了哪儿
        if force == "setopen" {
            let js = """
            (function(){
              function cn(el){var c=el.className;if(c&&typeof c.baseVal==='string')c=c.baseVal;return (c||'').toString();}
              function desc(el){
                if(!el) return 'null';
                var r=el.getBoundingClientRect();
                return el.tagName.toLowerCase()+'['+cn(el).slice(0,50)+'] '+(r.width>0?'可见 ':'隐藏 ')+Math.round(r.width)+'x'+Math.round(r.height);
              }
              var sec=document.getElementById('ft-alive-section');
              function chain(el){
                var out=[], n=el, d=0;
                while(n && n!==document.body && d<8){
                  var r=n.getBoundingClientRect();
                  out.push(n.tagName.toLowerCase()+'['+cn(n).slice(0,44)+'] '+Math.round(r.width)+'x'+Math.round(r.height)+' pos:'+getComputedStyle(n).position);
                  n=n.parentNode; d++;
                }
                return out;
              }
              var pan=document.querySelector('[class$="_panel"]');
              var ovl=document.querySelector('[class$="_overlay"]');
              var area=document.querySelector('[class$="_settingsArea"]');
              var contacts=[];
              var trs=document.querySelectorAll('[class$="_triggerRow"]');
              for(var j=0;j<trs.length;j++){
                contacts.push({chain: chain(trs[j]), hasPanel: !!trs[j].querySelector('[class$="_panel"]'), hasOverlay: !!trs[j].querySelector('[class$="_overlay"]')});
              }
              var contents=[];
              var cs=document.querySelectorAll('[class$="_content"]');
              for(var i=0;i<cs.length;i++){
                var p=cs[i].parentNode;
                contents.push({cls:cn(cs[i]).slice(0,60), w:Math.round(cs[i].getBoundingClientRect().width),
                  h:Math.round(cs[i].getBoundingClientRect().height), parent:desc(p),
                  hasAlive: !!cs[i].querySelector('#ft-alive-section'), hasSkin: !!cs[i].querySelector('#ft-skin-section')});
              }
              return JSON.stringify({
                panelChain: pan ? chain(pan) : null,
                overlayChain: ovl ? chain(ovl) : null,
                areaChain: area ? chain(area) : null,
                triggerRows: contacts,
                overlayInArea: !!(area && ovl && area.contains(ovl)),
                overlayInTriggerRow: !!(trs.length && ovl && trs[0].contains(ovl)),
                aliveExists: !!sec,
                aliveParent: sec? desc(sec.parentNode) : null,
                aliveVisible: sec? (sec.offsetParent !== null) : null,
                aliveRect: sec? (function(){var r=sec.getBoundingClientRect();return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)];})() : null,
                // 「生灵」栏目里到底渲染了几行开关（文字直接读出来，不靠看图猜）
                aliveRows: sec? (function(){
                  var rs=sec.querySelectorAll('[class*="switchRow"],[class*="toggleRow"],[class*="row"]');
                  var out=[];
                  for(var i=0;i<rs.length;i++){
                    var t=(rs[i].textContent||'').replace(/\\s+/g,' ').trim();
                    if(t) out.push(t.slice(0,36));
                  }
                  return out;
                })() : null,
                aliveSwitches: sec? sec.querySelectorAll('[role="switch"],input[type="checkbox"],button[class*="switch"]').length : null,
                contentCount: cs.length,
                contents: contents.slice(0,6),
                sectionsTotal: document.querySelectorAll('[id$="-section"]').length,
                sectionIds: (function(){var a=[];var n=document.querySelectorAll('[id$="-section"]');for(var i=0;i<n.length;i++)a.push(n[i].id);return a;})()
              });
            })()
            """
            wv.evaluateJavaScript(js) { r, _ in
                AppDelegate.log("设置面板探针[关闭态]: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                // 点原生触发器（不是我的转发按钮）→ 看面板怎么出现
                wv.evaluateJavaScript("(function(){var a=document.querySelector('[class$=\"_settingsArea\"]');if(!a)return 'no-area';var b=a.querySelector('button');if(!b)return 'no-btn';b.click();return 'clicked-real';})()") { r, _ in
                    AppDelegate.log("设置面板探针: 点原生触发器 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(js) { r, _ in
                    AppDelegate.log("设置面板探针[打开后]: \(r as? String ?? "nil")")
                }
                // 面板内容可滚动：找到真正的滚动容器并滚到底，把「生灵」三条都露出来
                wv.evaluateJavaScript("""
                (function(){
                  var p=document.querySelector('[class$="_panel"]');
                  if(!p) return 'no-panel';
                  var best=null, bh=0;
                  var ns=p.querySelectorAll('*');
                  for(var i=0;i<ns.length;i++){
                    var el=ns[i];
                    if(el.scrollHeight - el.clientHeight > 30 && el.clientHeight > 180 && el.scrollHeight > bh){
                      best=el; bh=el.scrollHeight;
                    }
                  }
                  if(!best) return 'no-scroller';
                  best.scrollTop = best.scrollHeight;
                  return 'scrolled ' + Math.round(best.scrollTop) + '/' + Math.round(best.scrollHeight) + ' cls=' + String(best.className).slice(0,40);
                })()
                """) { r, _ in
                    AppDelegate.log("设置面板探针: 滚动 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("""
                (function(){var p=document.querySelector('[class$="_panel"]');if(!p)return null;var r=p.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
                """) { res, _ in
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - 4), y: max(0, y - 4), width: w + 8, height: h + 8)
                    c.snapshotWidth = NSNumber(value: Int(w + 8))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-set-alive.png", label: "设置面板[整块]")
                }
            }
            return
        }

        // setloc 模式：核对「设置」入口已搬到主区标题栏，并验证点击转发真的能打开面板
        if force == "setloc" {
            let st1 = "window.__ftAliveDebug ? JSON.stringify({moved: window.__ftAliveDebug.state().settingsMoved, hidden: window.__ftAliveDebug.state().settingsHidden, btn: (function(){var b=document.getElementById('ft-settings-btn');if(!b)return null;var r=b.getBoundingClientRect();return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)];})(), icon: (function(){var b=document.getElementById('ft-settings-btn');return b?b.children.length:-1;})()}) : 'no-alive'"
            wv.evaluateJavaScript(st1) { r, _ in
                AppDelegate.log("设置入口探针: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: 1180, y: 0, width: 260, height: 84)
                c.snapshotWidth = 1040
                self.writeSnapshot(wv, c, to: "/tmp/ft-set-header.png", label: "标题栏右上")
                wv.evaluateJavaScript("(function(){var b=document.getElementById('ft-settings-btn');if(b)b.click();return 'clicked';})()") { r, _ in
                    AppDelegate.log("设置入口探针: 点击转发 -> \(r as? String ?? "nil")")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                // 判据必须用「浮层是否真的有尺寸」——不能用 #ft-alive-section 是否存在
                // （那个节点常驻，面板关着也在，上一轮就是被它骗过一次）
                wv.evaluateJavaScript("""
                (function(){
                  function vis(el){ if(!el) return null; var r=el.getBoundingClientRect();
                    return Math.round(r.width)+'x'+Math.round(r.height)+' disp:'+getComputedStyle(el).display; }
                  var s  = document.getElementById('ft-alive-section');
                  var ov = document.querySelector('[class$="_overlay"]');
                  var pn = document.querySelector('[class$="_panel"]');
                  var t  = document.querySelector('[class$="_settingsArea"] button');
                  var b  = document.getElementById('ft-settings-btn');
                  return JSON.stringify({
                    overlay: vis(ov), panel: vis(pn),
                    aliveInPanel: !!(pn && pn.querySelector('#ft-alive-section')),
                    aliveVisible: s ? (s.offsetParent !== null) : null,
                    triggerExpanded: t ? t.getAttribute('aria-expanded') : null,
                    btnDataOn: b ? b.getAttribute('data-on') : null,
                    sections: document.querySelectorAll('[class$="_content"] [id$="-section"]').length
                  });
                })()
                """) { r, _ in
                    AppDelegate.log("设置入口探针 打开后: \(r as? String ?? "nil")")
                }
                let c = WKSnapshotConfiguration()
                c.snapshotWidth = 1180
                self.writeSnapshot(wv, c, to: "/tmp/ft-set-panel.png", label: "设置面板")
            }
            return
        }

        // pet 模式：桌宠特写（真实截图，放大后目检造型与摆动）
        if force == "pet" {
            let petRectJS = """
            (function(){
              var p = document.getElementById('ft-pet');
              if (!p) return null;
              var r = p.getBoundingClientRect();
              return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,
                mode:(window.__ftAliveDebug?window.__ftAliveDebug.state().petMode:''),
                eye:(window.__ftAliveDebug?window.__ftAliveDebug.state().petEye:'')});
            })()
            """
            wv.evaluateJavaScript(petRectJS) { r, _ in
                AppDelegate.log("桌宠探针: \(r as? String ?? "nil")")
            }
            wv.evaluateJavaScript("window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'") { r, _ in
                AppDelegate.log("生灵探针[pet] state: \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript(petRectJS) { res, _ in
                    let full = WKSnapshotConfiguration()
                    full.snapshotWidth = 1180
                    self.writeSnapshot(wv, full, to: "/tmp/ft-pet-full.png", label: "全窗[pet]")
                    guard let s = res as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double, w > 4 else {
                        AppDelegate.log("桌宠探针: 拿不到几何")
                        return
                    }
                    AppDelegate.log("桌宠探针 几何: \(Int(w))x\(Int(h))@\(Int(x)),\(Int(y)) mode=\(o["mode"] ?? "") eye=\(o["eye"] ?? "")")
                    let pad = 18.0
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - pad), y: max(0, y - pad), width: w + pad * 2, height: h + pad * 2)
                    c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 8))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-pet-zoom.png", label: "桌宠特写")
                }
            }
            return
        }

        // petact 模式：把每个新行为依次拉一遍并逐个截图（只验「特效落点/活动范围」，
        // 手感与好不好看交给用户实测）。截图区固定为「侧栏 + 正文左缘 360px」。
        if force == "petact" {
            let acts: [(String, Double)] = [("stretch", 0.5), ("spout", 0.35), ("chase", 1.2),
                                            ("peek", 2.7), ("spin", 0.3), ("visitClock", 3.6)]
            var delay = 0.4
            for (m, shot) in acts {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, let wv = self.webView else { return }
                    wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.play('\(m)')") { _, _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + shot) { [weak self] in
                    guard let self = self, let wv = self.webView else { return }
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: 0, y: 60, width: 360, height: 880)
                    c.snapshotWidth = 1080
                    self.writeSnapshot(wv, c, to: "/tmp/ft-act-\(m).png", label: "行为[\(m)]")
                    wv.evaluateJavaScript("""
                    (function(){var d=window.__ftAliveDebug;if(!d)return null;var s=d.state();
                    return JSON.stringify({mode:s.petMode,play:s.petPlay,pos:s.petPos,jelly:s.petJelly,
                    bubs:s.petBubs,scale:s.petScale,home:s.petHome});})()
                    """) { r, _ in
                        AppDelegate.log("行为探针[\(m)]: \(r as? String ?? "nil")")
                    }
                }
                delay += shot + 0.6
            }
            // 最后来一次「完成庆祝」（三连跳 + 星光 + 泡泡 + 和弦）
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.cheer()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: 0, y: 60, width: 360, height: 880)
                c.snapshotWidth = 1080
                self.writeSnapshot(wv, c, to: "/tmp/ft-act-cheer.png", label: "行为[cheer]")
            }
            return
        }

        // dom 模式：把侧栏底部/品牌区/主区头部的真实结构 dump 出来（决定「设置」往哪挪）
        if force == "dom" {
            wv.evaluateJavaScript("""
            (function(){
              function cn(el){
                var c = el.className;
                if (c && typeof c.baseVal === 'string') c = c.baseVal;
                return (c || '').toString();
              }
              function d(el){
                var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
                return {
                  t: el.tagName.toLowerCase(),
                  c: cn(el).split(/\\s+/).filter(function(x){return x.indexOf('_')>-1;}).join(' ').slice(0,60),
                  a: (el.getAttribute('aria-label') || el.getAttribute('title') || '').slice(0,24),
                  x: (el.textContent||'').replace(/\\s+/g,' ').trim().slice(0,24),
                  r: [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]
                };
              }
              function walk(el, depth, budget){
                if (!el || depth < 0 || budget.n <= 0) return null;
                budget.n--;
                var o = d(el);
                if (depth > 0) {
                  var kids = [];
                  for (var i = 0; i < el.children.length && i < 14; i++) {
                    var k = walk(el.children[i], depth-1, budget);
                    if (k) kids.push(k);
                  }
                  if (kids.length) o.k = kids;
                }
                return o;
              }
              var roots = {
                sideRoot: '[class$="_root"][class*="_hHd"]',
                logoRow: '[class$="_logoRow"]',
                footArea: '[class$="_footArea"]',
                settingsArea: '[class$="_settingsArea"]',
                footerActions: '[class$="_footerActions"]',
                regionArea: '[class$="_regionArea"]',
                mainHeader: '[class$="_header"]'
              };
              var out = {};
              for (var key in roots) {
                var el = document.querySelector(roots[key]);
                out[key] = el ? walk(el, 3, {n: 40}) : '缺失';
              }
              // 侧栏底部 260px 内出现的所有可点元素
              var bottom = [];
              var sb = document.querySelector('[class$="_root"][class*="_hHd"]');
              if (sb) {
                var br = sb.getBoundingClientRect();
                var all = sb.querySelectorAll('button,[role="button"],a');
                for (var i = 0; i < all.length; i++) {
                  var r = all[i].getBoundingClientRect();
                  if (r.top > br.bottom - 280 && r.width > 0) {
                    bottom.push({a: (all[i].getAttribute('aria-label')||all[i].getAttribute('title')||'').slice(0,20),
                                 x: (all[i].textContent||'').replace(/\\s+/g,' ').trim().slice(0,20),
                                 r: [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)]});
                  }
                }
              }
              out.sidebarBottomButtons = bottom;
              return JSON.stringify(out);
            })()
            """) { r, _ in
                if let s = r as? String {
                    AppDelegate.log("DOM探针:\n\(s)")
                } else {
                    AppDelegate.log("DOM探针: 无结果 \(String(describing: r))")
                }
            }
            return
        }

        // stopbtn 模式：注入一个假的「停止生成」按钮来验证主判定路径（不打扰真实会话）
        if force == "stopbtn" {
            let stateJS = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
            func readState(_ tag: String) {
                wv.evaluateJavaScript(stateJS) { r, _ in
                    AppDelegate.log("停止按钮路径 \(tag): \(r as? String ?? "nil")")
                }
            }
            wv.evaluateJavaScript("""
            (function(){
              var b = document.createElement('button');
              b.id = 'ft-fake-stop';
              b.setAttribute('aria-label', '停止生成');
              b.style.cssText = 'position:fixed;left:-9999px;top:0;';
              document.body.appendChild(b);
              return 'injected';
            })()
            """) { r, _ in
                AppDelegate.log("停止按钮路径: 注入假按钮 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { readState("注入后(期望 busy)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-fake-stop');if(e)e.remove();return 'removed';})()") { _, _ in }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { readState("移除后 0.9s(期望 done)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { readState("移除后 2.2s(期望 idle)") }
            return
        }

        // collapse 模式：折叠侧栏，验证机芯退化成「只剩齿轮」
        if force == "collapse" {
            wv.evaluateJavaScript("""
            (function(){var t=document.querySelector('[class$="_toggle"]');if(!t)return 'no-toggle';t.click();return 'clicked';})()
            """) { r, _ in
                AppDelegate.log("生灵探针[collapse]: 折叠 -> \(r as? String ?? "nil")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self = self, let wv = self.webView else { return }
                let full = WKSnapshotConfiguration()
                full.snapshotWidth = 1180
                self.writeSnapshot(wv, full, to: "/tmp/ft-alive-collapse.png", label: "全窗[折叠]")
                wv.evaluateJavaScript("""
                (function(){var e=document.getElementById('ft-clock');if(!e)return null;var r=e.getBoundingClientRect();
                return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height,sw:e.querySelector('svg').getBoundingClientRect().width});})()
                """) { r, _ in
                    AppDelegate.log("生灵探针[collapse] 机芯几何: \(r as? String ?? "nil")")
                    guard let s = r as? String,
                          let d = s.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let x = o["x"] as? Double, let y = o["y"] as? Double,
                          let w = o["w"] as? Double, let h = o["h"] as? Double else { return }
                    let pad = 10.0
                    let c = WKSnapshotConfiguration()
                    c.rect = CGRect(x: max(0, x - pad), y: max(0, y - pad), width: w + pad * 2, height: h + pad * 2)
                    c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 6))
                    self.writeSnapshot(wv, c, to: "/tmp/ft-clock-collapse.png", label: "机芯[折叠]")
                }
            }
            return
        }

        wv.evaluateJavaScript("window.__ftAliveDebug && window.__ftAliveDebug.force(\(AppDelegate.jsStringLiteral(force)))") { _, _ in }

        let stateJS = "window.__ftAliveDebug ? JSON.stringify(window.__ftAliveDebug.state()) : 'no-alive'"
        for (delay, tag) in [(1.2, "t0"), (2.2, "t1")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView?.evaluateJavaScript(stateJS) { r, _ in
                    AppDelegate.log("生灵探针[\(force)] \(tag): \(r as? String ?? "nil")")
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            let full = WKSnapshotConfiguration()
            full.snapshotWidth = 1180
            self.writeSnapshot(wv, full, to: "/tmp/ft-alive-\(force).png", label: "全窗[\(force)]")

            wv.evaluateJavaScript("""
            (function(){var e=document.getElementById('ft-clock');if(!e)return null;
            var r=e.getBoundingClientRect();
            return JSON.stringify({x:r.left,y:r.top,w:r.width,h:r.height});})()
            """) { res, _ in
                guard let s = res as? String,
                      let d = s.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let x = o["x"] as? Double, let y = o["y"] as? Double,
                      let w = o["w"] as? Double, let h = o["h"] as? Double else {
                    AppDelegate.log("机芯特写[\(force)]: 取不到 #ft-clock")
                    return
                }
                let pad = 12.0
                let c = WKSnapshotConfiguration()
                c.rect = CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: h + pad * 2)
                c.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 6))
                self.writeSnapshot(wv, c, to: "/tmp/ft-clock-\(force).png", label: "机芯特写[\(force)]")
            }
        }
    }

    // 截图自检：存在 /tmp/ft-snapshot.flag 时，把左上角品牌区截成 PNG（不需要录屏权限）
    // 同时若会话里有用户头像，再截一张头像特写（32px 的元素放大 8 倍看细节）
    private func captureSnapshot() {
        guard let wv = webView else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: 460, height: 150)
        cfg.snapshotWidth = 920
        writeSnapshot(wv, cfg, to: "/tmp/ft-snapshot.png", label: "品牌区")

        // 头像特写：把最后一个 .ft-av-user 克隆一份钉在视口角落（原地那份可能滚出可视区），
        // 截完再删掉。这样不需要滚动、不需要录屏权限，也能拿到 8 倍放大的真实渲染。
        wv.evaluateJavaScript("""
        (function () {
          var old = document.getElementById('ft-av-stage');
          if (old) old.remove();
          var es = document.querySelectorAll('.ft-av-user');
          if (!es.length) return null;
          var src = es[es.length - 1];
          var stage = src.cloneNode(true);
          stage.id = 'ft-av-stage';
          stage.style.cssText += ';position:fixed !important;left:auto !important;top:auto !important;right:20px;bottom:20px;z-index:2147483000;';
          document.body.appendChild(stage);
          var r = stage.getBoundingClientRect();
          var inner = stage.firstElementChild;
          var cs = inner ? getComputedStyle(inner) : null;
          return JSON.stringify({
            count: es.length, x: r.left, y: r.top, w: r.width, h: r.height,
            maskSize: cs ? (cs.webkitMaskSize || cs.maskSize) : '',
            maskImage: cs ? (cs.webkitMaskImage || cs.maskImage || '').slice(0, 24) : '',
            bg: cs ? cs.backgroundColor : ''
          });
        })()
        """) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let x = obj["x"] as? Double, let y = obj["y"] as? Double,
                  let w = obj["w"] as? Double, let h = obj["h"] as? Double else {
                AppDelegate.log("头像截图: 页面里没有用户头像元素")
                return
            }
            AppDelegate.log("头像截图: \(obj["count"] ?? 0) 个 · 几何 \(Int(w))x\(Int(h))@\(Int(x)),\(Int(y)) · maskSize=\(obj["maskSize"] ?? "") · mask=\(obj["maskImage"] ?? "") · bg=\(obj["bg"] ?? "")")
            let pad = 14.0
            let c2 = WKSnapshotConfiguration()
            c2.rect = CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: h + pad * 2)
            c2.snapshotWidth = NSNumber(value: Int((w + pad * 2) * 8))
            self.writeSnapshot(wv, c2, to: "/tmp/ft-avatar.png", label: "头像特写") {
                wv.evaluateJavaScript("(function(){var e=document.getElementById('ft-av-stage');if(e)e.remove();})()") { _, _ in }
            }
        }
    }

    private func writeSnapshot(_ wv: WKWebView, _ cfg: WKSnapshotConfiguration, to path: String,
                              label: String, done: (() -> Void)? = nil) {
        wv.takeSnapshot(with: cfg) { image, error in
            defer { done?() }
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                AppDelegate.log("截图自检[\(label)]: 失败 \(error?.localizedDescription ?? "无图")")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                AppDelegate.log("截图自检[\(label)]: 已写 \(path) (\(png.count) 字节)")
            } catch {
                AppDelegate.log("截图自检[\(label)]: 写盘失败 \(error.localizedDescription)")
            }
        }
    }

    // 简单日志，写到 ~/.dsh/logs/fatiaowu-app.log 方便排查
    static func log(_ message: String) {
        let path = "/Users/yangliu/.dsh/logs/fatiaowu-app.log"
        let line = "[\(Date())] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        handleLoadFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        handleLoadFailure()
    }

    private func showServerDownAlert() {
        retryTimer?.invalidate()
        retryTimer = nil
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "发条屋服务未启动"
        alert.informativeText = "等了很久还是没有连上 DeepSeek Harness 服务。请确认后台服务已开启（登录系统后它会自动运行），然后重新打开「发条屋」。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true // 关掉窗口即退出
    }

    // 全屏/窗口尺寸变化后，WKWebView 偶发渲染陈旧（DOM 正确但画面是旧的），强制重绘
    @objc private func forceRepaint(_ note: Notification) {
        repaintWorkItem?.cancel()
        let delay: Double = (note.name == NSWindow.didResizeNotification) ? 0.4 : 1.0
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            wv.setNeedsDisplay(wv.bounds)
            wv.evaluateJavaScript("""
            (function(){
              try {
                window.dispatchEvent(new Event('resize'));
                var b = document.body;
                if (b) {
                  b.style.display = 'none';
                  requestAnimationFrame(function(){ b.style.display = ''; });
                }
              } catch (e) {}
            })()
            """) { _, _ in }
        }
        repaintWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // ================= 内置浏览器 =================
    // 会话里点外部链接时，在本 App 内开一个浏览器窗口，而不是干等着不动。

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // 只拦截主会话窗口的链接点击；内置浏览器窗口内自由导航
        if webView !== self.webView {
            decisionHandler(.allow)
            return
        }
        let isLinkClick = navigationAction.navigationType == .linkActivated
        let isNewWindow = navigationAction.targetFrame == nil
        if isLinkClick || isNewWindow {
            let isDSH = (url.host == "127.0.0.1" || url.host == "localhost") && (url.port == 3080 || url.port == nil)
            if !isDSH {
                if url.scheme == "http" || url.scheme == "https" {
                    openInBuiltInBrowser(url)
                } else {
                    NSWorkspace.shared.open(url) // mailto: 等交给系统
                }
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // JS 打开的链接（window.open / target=_blank）：交给内置浏览器
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            openInBuiltInBrowser(url)
        }
        return nil // 不创建新 webview，直接打开内置浏览器
    }

    private func openInBuiltInBrowser(_ url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let rect = NSRect(x: 0, y: 0, width: 1080, height: 720)
            let win = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = url.host ?? "浏览"
            win.center()

            // 顶部小工具条：后退 / 前进 / 刷新 / 用默认浏览器打开
            let back = NSButton(title: "←", target: nil, action: nil)
            let forward = NSButton(title: "→", target: nil, action: nil)
            let reload = NSButton(title: "⟳", target: nil, action: nil)
            let external = BrowserOpenButton(title: "用默认浏览器打开", target: nil, action: nil)
            for b in [back, forward, reload, external] { b.bezelStyle = .rounded }

            let browser = WKWebView(frame: rect)
            browser.allowsBackForwardNavigationGestures = true

            back.target = browser
            back.action = #selector(WKWebView.goBack(_:))
            forward.target = browser
            forward.action = #selector(WKWebView.goForward(_:))
            reload.target = browser
            reload.action = #selector(WKWebView.reload(_:))
            external.onOpen = { [weak browser] in
                guard let browser, let url = browser.url else { return }
                NSWorkspace.shared.open(url)
            }

            let toolRow = NSStackView(views: [back, forward, reload, external])
            toolRow.orientation = .horizontal
            toolRow.spacing = 6
            toolRow.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

            let stack = NSStackView(views: [toolRow, browser])
            stack.orientation = .vertical
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            win.contentView = stack
            NSLayoutConstraint.activate([
                toolRow.heightAnchor.constraint(equalToConstant: 36),
            ])

            self.browserWindows.append(win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            browser.load(URLRequest(url: url))
        }
    }

}

// 入口：main.swift 顶层代码运行在主线程，这里明确切到主 actor
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
