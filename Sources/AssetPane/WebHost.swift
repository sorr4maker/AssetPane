import AppKit
import WebKit

/// 从 App 包里的 web 目录提供静态页面（assetpane://app/…），不开本地端口。
/// 页面里的数据（持仓、交易、定投计划）存在这个来源的 localStorage 里，来源固定所以重启后还在。
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "assetpane"
    static let home = URL(string: "assetpane://app/")!
    private let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = resolve(url.path) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        do {
            let data = try Data(contentsOf: file)
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": Self.mime(file.pathExtension),
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-cache",
            ])!
            task.didReceive(resp); task.didReceive(data); task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// /、/foo、/foo/ 依次试 foo、foo.html、foo/index.html（Next 静态导出的目录风格）
    private func resolve(_ path: String) -> URL? {
        var rel = path.removingPercentEncoding ?? path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.split(separator: "/").contains("..") { return nil }
        let candidates = rel.isEmpty ? ["index.html"] : [rel, rel + ".html", rel + "/index.html"]
        for c in candidates {
            let u = root.appendingPathComponent(c)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
        }
        return nil
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        default: return "application/octet-stream"
        }
    }
}

/// 外链（带 target=_blank 或离开本页的链接）交给默认浏览器
final class WebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = action.request.url, url.scheme == "http" || url.scheme == "https", action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url); return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

@MainActor
func makeWebView(delegate: WebDelegate) -> WKWebView? {
    guard let web = Bundle.main.resourceURL?.appendingPathComponent("web"),
          FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path) else { return nil }
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(BundleSchemeHandler(root: web), forURLScheme: BundleSchemeHandler.scheme)
    config.websiteDataStore = .default()
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = delegate
    view.uiDelegate = delegate
    view.setValue(false, forKey: "drawsBackground")
    view.load(URLRequest(url: BundleSchemeHandler.home))
    return view
}
