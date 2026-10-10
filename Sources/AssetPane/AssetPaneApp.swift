import SwiftUI
import WebKit
import ServiceManagement

@main
struct AssetPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("资产窗", systemImage: "chart.pie") {
            Toggle("显示桌面面板", isOn: $model.showPanel)
            Toggle("编辑布局（拖动、调整大小）", isOn: $model.editingLayout)
            Button("管理持仓与定投…") { model.openManager() }
            Button("导入持仓文件…") { model.importHoldings() }
            Button(model.isRefreshing ? "刷新中…" : "立即刷新") { model.refresh() }.disabled(model.isRefreshing)
            Divider()
            Toggle("开机自动启动", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            Divider()
            Text(model.summary.updatedAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未更新")
            Button("退出资产窗") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppModel()
    private let panel = PanelController()
    private let webDelegate = WebDelegate()
    private var web: WKWebView?
    private var manager: NSWindow?
    private var detail: NSWindow?
    private var timer: Timer?
    private static let showKey = "showPanel"

    @Published var showPanel: Bool = UserDefaults.standard.object(forKey: AppModel.showKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showPanel, forKey: Self.showKey)
            if !showPanel { editingLayout = false }
            applyVisibility()
        }
    }
    @Published var editingLayout = false { didSet { panel.setEditing(editingLayout) } }
    /// 正在拖动缩放手柄：界面用冻结的排版整体缩放（省算力），松手后再按新大小重排
    @Published var liveResizing = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var summary = Summary()
    @Published private(set) var isRefreshing = false

    /// 基估宝页面一直在后台载入：它负责刷新估值、按定投计划生成交易；这里只读它存的数据
    func start() {
        web = makeWebView(delegate: webDelegate)
        applyVisibility()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.web?.reloadFromOrigin(); try? await Task.sleep(nanoseconds: 8_000_000_000); self?.refresh() }
        }
        // 页面刚载入要几秒才把估值写进 localStorage
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.refresh() }
        let env = ProcessInfo.processInfo.environment
        if env["ASSETPANE_DEBUG_SEED"] != nil || env["ASSETPANE_DEBUG_CLEAR"] != nil { debugStorage(seed: env["ASSETPANE_DEBUG_SEED"] != nil) }
        if env["ASSETPANE_DEBUG_IMPORT"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.importHoldings() } }
        if env["ASSETPANE_DEBUG_EDIT"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.editingLayout = true } }   // 调试：进入「调整大小」模式
        if let name = env["ASSETPANE_DEBUG_DETAIL"] {   // 调试：自动打开某个指数（或地区，名字以「地区:」开头）的详情窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.showDetail(name.hasPrefix("地区:") ? .region(String(name.dropFirst(3))) : .category(name))
            }
        }
        if let dir = env["ASSETPANE_DEBUG_DIR"] { debugDump(to: dir) }
    }

    // MARK: 导入持仓

    static let importFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AssetPane/import.json")

    /// 读取 import.json：[{"code","name","share","cost"}]（份额和成本价，优先），或 [{"code","name","amount","profit","date"(可选)}]（按金额反推）
    /// 「按金额」换算成份额和成本价（份额 = 金额 ÷ 当日净值，成本 = (金额 − 收益) ÷ 份额），合并写进基估宝的持仓（同代码覆盖），
    /// 写之前把原来的 funds/holdings 备份到 import-backup-时间.json，然后重载页面。
    func importHoldings() {
        guard let web else { return }
        Task {
            func alert(_ text: String) {
                if ProcessInfo.processInfo.environment["ASSETPANE_DEBUG_IMPORT"] != nil { NSLog("导入结果：\(text)"); return }   // 调试时不弹窗
                let a = NSAlert(); a.messageText = "导入持仓"; a.informativeText = text; NSApp.activate(ignoringOtherApps: true); a.runModal()
            }
            // 文件可以是持仓数组，也可以是 {"holdings": […], "plans": […]}（plans 是定投计划）
            guard let data = try? Data(contentsOf: Self.importFile),
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                alert("没有找到可用的导入文件：\n\(Self.importFile.path)"); return
            }
            let arr = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["holdings"] as? [[String: Any]]) ?? []
            let plans = ((root as? [String: Any])?["plans"] as? [[String: Any]]) ?? []
            // "funds": [{"code","name"}] 只往列表里添加基金（还没有持仓、只准备定投的）
            let newFunds = ((root as? [String: Any])?["funds"] as? [[String: Any]]) ?? []
            guard !arr.isEmpty || !plans.isEmpty || !newFunds.isEmpty else { alert("导入文件里没有持仓也没有定投计划：\n\(Self.importFile.path)"); return }
            var items: [[String: Any]] = []
            var problems: [String] = []
            for it in arr {
                guard let code = it["code"] as? String else { problems.append("缺少代码：\(it)"); continue }
                let name = it["name"] as? String ?? code
                // 直接给了份额和成本价的（截图里有）就原样使用，不用净值反推
                if let share = num(it["share"]), let cost = num(it["cost"]), share > 0, cost > 0 {
                    items.append(["code": code, "name": name, "share": share, "cost": cost]); continue
                }
                guard let amount = num(it["amount"]) else { problems.append("\(code) \(name)：缺少金额或份额/成本"); continue }
                let hist = await NavService.history(code: code)
                let day = it["date"] as? String
                guard let nav = (day.flatMap { d in hist.last { $0.date <= d } } ?? hist.last)?.value, nav > 0 else {
                    problems.append("\(code) \(name)：取不到净值"); continue
                }
                let profit = num(it["profit"]) ?? 0
                let share = (amount / nav * 100).rounded() / 100
                guard share > 0 else { problems.append("\(code) \(name)：金额为 0"); continue }
                let cost = ((amount - profit) / share * 10000).rounded() / 10000
                items.append(["code": code, "name": name, "share": share, "cost": cost])
            }
            // 定投计划：{"code","amount","cycle":"daily|weekly|biweekly|monthly","firstDate":"YYYY-MM-DD","weeklyDay":1-5(每周/每两周),"monthlyDay":1-28(每月)}
            var planItems: [[String: Any]] = []
            for p in plans {
                // {"code": "…", "remove": true} 删除这只基金的定投计划
                if (p["remove"] as? Bool) == true, let code = p["code"] as? String { planItems.append(["code": code, "remove": true]); continue }
                guard let code = p["code"] as? String, let amount = num(p["amount"]), amount > 0,
                      let cycle = p["cycle"] as? String, ["daily", "weekly", "biweekly", "monthly"].contains(cycle),
                      let first = p["firstDate"] as? String else { problems.append("定投计划不完整：\(p)"); continue }
                var plan: [String: Any] = ["code": code, "amount": amount, "cycle": cycle, "firstDate": first]
                if let w = num(p["weeklyDay"]) { plan["weeklyDay"] = w }
                if let m = num(p["monthlyDay"]) { plan["monthlyDay"] = m }
                planItems.append(plan)
            }
            let fundItems: [[String: Any]] = newFunds.compactMap { f in
                guard let code = f["code"] as? String else { return nil }
                return ["code": code, "name": f["name"] as? String ?? code]
            }
            guard problems.isEmpty, !(items.isEmpty && planItems.isEmpty && fundItems.isEmpty),
                  let json = try? JSONSerialization.data(withJSONObject: items), let jsonText = String(data: json, encoding: .utf8),
                  let pjson = try? JSONSerialization.data(withJSONObject: planItems), let planText = String(data: pjson, encoding: .utf8),
                  let fjson = try? JSONSerialization.data(withJSONObject: fundItems), let fundText = String(data: fjson, encoding: .utf8) else {
                alert("没有写入任何数据，请先处理这些问题：\n" + problems.joined(separator: "\n")); return
            }
            let js = """
            (function(){
              const items = \(jsonText);
              const planItems = \(planText);
              const newFunds = \(fundText);
              const old = {funds: localStorage.getItem('funds'), holdings: localStorage.getItem('holdings'), dcaPlans: localStorage.getItem('dcaPlans')};
              const funds = JSON.parse(old.funds || '[]'), holdings = JSON.parse(old.holdings || '{}');
              for (const nf of newFunds) {
                if (!funds.find(f => f.code === nf.code)) funds.push({code: nf.code, name: nf.name, addedAt: Date.now()});
              }
              for (const it of items) {
                if (!funds.find(f => f.code === it.code)) funds.push({code: it.code, name: it.name, addedAt: Date.now()});
                holdings[it.code] = Object.assign({}, holdings[it.code] || {}, {share: it.share, cost: it.cost});
              }
              localStorage.setItem('funds', JSON.stringify(funds));
              localStorage.setItem('holdings', JSON.stringify(holdings));
              if (planItems.length) {
                let plans = JSON.parse(old.dcaPlans || 'null') || {};
                if (!plans.__global__) plans = {__global__: plans};   // 旧版是「代码 → 计划」的扁平对象
                for (const p of planItems) {
                  if (p.remove) { delete plans.__global__[p.code]; continue; }
                  if (!funds.find(f => f.code === p.code)) throw new Error('定投计划的基金不在列表里：' + p.code);
                  plans.__global__[p.code] = Object.assign({feeRate: 0, enabled: true}, plans.__global__[p.code] || {}, p);
                  delete plans.__global__[p.code].code;
                }
                localStorage.setItem('dcaPlans', JSON.stringify(plans));
              }
              return JSON.stringify(old);
            })()
            """
            let backup: String? = await withCheckedContinuation { cont in
                web.evaluateJavaScript(js) { r, _ in cont.resume(returning: r as? String) }
            }
            guard let backup else { alert("写入失败，页面没有响应。"); return }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let backupURL = Self.importFile.deletingLastPathComponent().appendingPathComponent("import-backup-\(stamp).json")
            try? backup.write(to: backupURL, atomically: true, encoding: .utf8)
            web.reloadFromOrigin()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            refresh()
            alert("已导入 \(items.count) 只基金持仓、新增 \(fundItems.count) 只基金、处理 \(planItems.count) 个定投计划。\n原来的数据备份在：\n\(backupURL.path)")
        }
    }

    /// 调试用：ASSETPANE_DEBUG_SEED=1 往页面的 localStorage 写入两只测试基金；ASSETPANE_DEBUG_CLEAR=1 把它们清掉
    private func debugStorage(seed: Bool) {
        let setJS = """
        const mk=(d,sh,amt,dca)=>({id:'t'+d+sh,type:'buy',amount:amt,share:sh,price:amt/sh,date:d,isAfter3pm:false,isDca:dca,timestamp:Date.parse(d)});
        localStorage.setItem('funds',JSON.stringify([{code:'270042',name:'广发纳斯达克100ETF联接A',addedAt:Date.parse('2026-06-01')},{code:'110020',name:'易方达沪深300ETF联接A',addedAt:Date.parse('2026-06-01')}]));
        localStorage.setItem('holdings',JSON.stringify({'270042':{share:300,cost:5.2},'110020':{share:200,cost:1.9}}));
        localStorage.setItem('transactions',JSON.stringify({'270042':[mk('2026-07-01',100,520,true),mk('2026-08-03',100,520,true),mk('2026-09-01',100,520,true)],'110020':[mk('2026-07-15',200,380,false)]}));
        """
        let clearJS = "['funds','holdings','transactions','groups','favorites','pendingTrades','dcaPlans','fundDailyEarnings'].forEach(k=>localStorage.removeItem(k))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.web?.evaluateJavaScript(seed ? setJS : clearJS)
        }
    }

    func refresh() {
        guard !isRefreshing, let web else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            guard let raw = await Bridge.read(from: web) else { return }
            let held = raw.funds.filter { (raw.holdings[$0.code]?.share ?? 0) > 0 || !(raw.trades[$0.code] ?? []).isEmpty }
            var navs: [String: [NavService.Point]] = [:]
            var estimates: [String: NavService.Estimate] = [:]
            await withTaskGroup(of: (String, [NavService.Point], NavService.Estimate?).self) { group in
                for f in held { group.addTask { (f.code, await NavService.history(code: f.code), await NavService.estimate(code: f.code)) } }
                for await (code, pts, est) in group { navs[code] = pts; estimates[code] = est }
            }
            summary = Portfolio.summarize(raw: raw, navs: navs, estimates: estimates)
        }
    }

    /// 打开基估宝页面（添加基金、填持仓、建定投计划），关掉窗口后自动刷新面板
    func openManager() {
        guard let web else { return }
        if manager == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "资产窗 · 管理持仓与定投"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = web
            w.center()
            manager = w
        }
        NSApp.activate(ignoringOtherApps: true)
        manager?.makeKeyAndOrderFront(nil)
    }

    /// 点面板里的某个指数 / 地区，弹出这个指数下每只基金的详细持仓（贴在面板旁边）
    func showDetail(_ key: DetailKey) {
        let host = NSHostingView(rootView: DetailView(model: self, key: key))
        let count = summary.rows.filter { key.contains($0) }.count
        let maxH = max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        let size = NSSize(width: 560, height: min(maxH, CGFloat(150 + 42 * count + 30)))
        if detail == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            detail = w
        }
        guard let w = detail else { return }
        w.title = "详细持仓 · \(key.name)"
        w.contentView = host
        w.setContentSize(size)
        // 放在面板右边；右边放不下就放左边
        if let pf = panel.frame {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            var x = pf.maxX + 12
            if x + size.width > screen.maxX { x = max(screen.minX, pf.minX - size.width - 12) }
            let y = min(max(screen.minY, pf.maxY - size.height), screen.maxY - size.height)
            w.setFrameOrigin(NSPoint(x: x, y: y))
        } else { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    private func applyVisibility() {
        panel.setVisible(showPanel, model: self) { [weak self] in self?.editingLayout = false }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { NSLog("开机自启设置失败：\(error.localizedDescription)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 调试用：设置 ASSETPANE_DEBUG_DIR 后，15 秒时把面板画成 snapshot.png，并把读到的摘要写进 summary.txt
    private func debugDump(to dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            panel.snapshot(to: dir + "/snapshot.png")
            if let v = detail?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: dir + "/detail.png")) }
            }
            let s = summary
            if let keys = ProcessInfo.processInfo.environment["ASSETPANE_DEBUG_KEYS"] {   // 例如 "dcaPlans,holdings"：把这些 localStorage 键的值写进 keys.txt
                let js = "JSON.stringify(Object.fromEntries('\(keys)'.split(',').map(k => [k, localStorage.getItem(k)])))"
                web?.evaluateJavaScript(js) { r, _ in try? ((r as? String) ?? "").write(toFile: dir + "/keys.txt", atomically: true, encoding: .utf8) }
            }
            let text = "总资产 \(s.totalValue)\n日 \(s.dayChange) live=\(s.isLive)\n持有收益 \(s.profit)\n行数 \(s.rows.count)\n" + s.regions.map { r in "\(r.name)｜市值 \(Int(r.value))｜占比 \(Int(r.weight * 100))%｜" + r.categories.map { "\($0.name)\($0.count)只" }.joined(separator: "、") }.joined(separator: "\n") + "\n定投 每个交易日 \(s.dcaPerDay) 元 \(s.dcaFundCount) 只｜" + s.dca.map { "\($0.name) \($0.total)" }.joined(separator: "，")
            try? text.write(toFile: dir + "/summary.txt", atomically: true, encoding: .utf8)
        }
    }
}

/// 面板被隐藏、菜单栏图标又找不到时的保险：在「应用程序」里再打开一次，面板就重新显示。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showPanel = true }
        return true
    }
}
