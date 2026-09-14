import AppKit
import WebKit
import Darwin

let kPort = 30141
let kServerURL = URL(string: "http://127.0.0.1:\(kPort)/")!
let kPiWebPath = "/opt/homebrew/bin/pi-web"
let kChildPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

let kSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("PiWebWrapper", isDirectory: true)
let kPidFile = kSupportDir.appendingPathComponent("pi-web.pid")
let kLogFile = kSupportDir.appendingPathComponent("pi-web.log")

func onMain(_ block: @escaping () -> Void) {
    DispatchQueue.main.async(execute: DispatchWorkItem(block: block))
}

func runBackground(_ block: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem(block: block))
}

func processPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

func serverIsUp(timeout: TimeInterval = 1.0) -> Bool {
    var req = URLRequest(url: kServerURL)
    req.timeoutInterval = timeout
    var up = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, response, _ in
        if let http = response as? HTTPURLResponse { up = http.statusCode > 0 }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return up
}

// 新版 macOS 窗口内容默认延伸到标题栏下方；这个容器把 WebView 固定在
// contentLayoutRect（标题栏以下的区域），否则网页顶部被标题栏盖住、标题栏也拖不动
final class ContentLayoutView: NSView {
    weak var content: NSView?
    override func layout() {
        super.layout()
        guard let content else { return }
        let rect = window?.contentLayoutRect ?? bounds
        content.frame = rect.isEmpty ? bounds : rect
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var ownsServer = false
    var serverPID: pid_t?

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        ensureServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopServerIfOwned()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: window

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullScreen],
            backing: .buffered, defer: false)
        window.title = "Pi Web"
        window.minSize = NSSize(width: 640, height: 400)
        let container = ContentLayoutView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        wv.navigationDelegate = self
        container.content = wv
        container.addSubview(wv)
        window.contentView = container
        webView = wv
        window.delegate = self
        window.setFrameAutosaveName("PiWebMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInfoPage(title: "正在启动 Pi 服务…", detail: "首次启动需要几秒钟。")
    }

    // MARK: server management

    func ensureServer() {
        runBackground { [weak self] in
            guard let self else { return }
            if serverIsUp() {
                // 服务已在跑：如果是我们之前拉起的（崩溃残留），接管；否则视为外部启动，不动它
                self.ownsServer = self.adoptExistingServer()
                onMain { self.webView.load(kServerURL) }
                return
            }
            try? FileManager.default.removeItem(at: kPidFile)
            if let err = self.startServer() {
                onMain { self.showInfoPage(title: "Pi 服务启动失败", detail: err) }
                return
            }
            self.waitForServerAndLoad(since: Date())
        }
    }

    func readPidFile() -> pid_t? {
        guard let s = try? String(contentsOf: kPidFile, encoding: .utf8),
              let pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid_t(pid)
    }

    func adoptExistingServer() -> Bool {
        guard let pid = readPidFile(), kill(pid, 0) == 0,
              let path = processPath(pid), path.contains("pi-web") else { return false }
        serverPID = pid
        return true
    }

    func startServer() -> String? {
        do {
            guard FileManager.default.fileExists(atPath: kPiWebPath) else {
                return "找不到 \(kPiWebPath)，请先安装：npm install -g @agegr/pi-web"
            }
            try FileManager.default.createDirectory(at: kSupportDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: kLogFile.path) {
                FileManager.default.createFile(atPath: kLogFile.path, contents: nil)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: kPiWebPath)
            p.arguments = ["--no-open"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = kChildPATH
            p.environment = env
            let log = FileHandle(forWritingAtPath: kLogFile.path)
            log?.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
            try p.run()
            serverPID = p.processIdentifier
            ownsServer = true
            try? String(p.processIdentifier).write(to: kPidFile, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "\(error)"
        }
    }

    func waitForServerAndLoad(since date: Date) {
        runBackground { [weak self] in
            usleep(300_000)
            guard let self else { return }
            if serverIsUp() {
                onMain { self.webView.load(kServerURL) }
            } else if Date().timeIntervalSince(date) > 20 {
                onMain {
                    self.showInfoPage(title: "Pi 服务未能启动",
                                      detail: "20 秒内端口 \(kPort) 没有就绪。日志：\(kLogFile.path)")
                }
            } else {
                self.waitForServerAndLoad(since: date)
            }
        }
    }

    func stopServerIfOwned() {
        guard ownsServer, let pid = serverPID else { return }
        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            var waited = 0.0
            while kill(pid, 0) == 0 && waited < 3.0 {
                usleep(100_000)
                waited += 0.1
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: kPidFile)
    }

    // MARK: UI helpers

    func showInfoPage(title: String, detail: String) {
        let showSpinner = title.contains("正在启动")
        let html = """
        <html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system,'PingFang SC',sans-serif;background:#1a1a1a;color:#eee;
             display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        .box{text-align:center;max-width:600px;padding:0 24px}
        h1{font-size:17px;font-weight:600;margin-bottom:10px}
        p{font-size:13px;color:#aaa;line-height:1.6;word-break:break-all}
        .spin{width:28px;height:28px;border:3px solid #444;border-top-color:#4da3ff;
              border-radius:50%;margin:0 auto 18px;animation:s .9s linear infinite}
        @keyframes s{to{transform:rotate(360deg)}}
        </style></head><body><div class="box">
        \(showSpinner ? "<div class=\"spin\"></div>" : "")
        <h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func buildMenu() {
        let main = NSMenu()

        let appRoot = NSMenuItem()
        main.addItem(appRoot)
        let appMenu = NSMenu(title: "Pi Web")
        appMenu.addItem(NSMenuItem(title: "关于 Pi Web",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 Pi Web",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appRoot.submenu = appMenu

        let editRoot = NSMenuItem()
        main.addItem(editRoot)
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editRoot.submenu = editMenu

        let viewRoot = NSMenuItem()
        main.addItem(viewRoot)
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(NSMenuItem(title: "重新加载页面",
                                    action: #selector(WKWebView.reload(_:)),
                                    keyEquivalent: "r"))
        viewRoot.submenu = viewMenu

        let winRoot = NSMenuItem()
        main.addItem(winRoot)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(NSMenuItem(title: "最小化",
                                   action: #selector(NSWindow.performMiniaturize(_:)),
                                   keyEquivalent: "m"))
        winMenu.addItem(NSMenuItem(title: "关闭窗口",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w"))
        winRoot.submenu = winMenu

        NSApp.mainMenu = main
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 站内链接照常加载；指向外部的链接交给默认浏览器打开
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let host = url.host,
           host != "127.0.0.1" && host != "localhost",
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
