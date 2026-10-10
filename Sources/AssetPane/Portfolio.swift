import Foundation

struct FundRow: Identifiable {
    let code: String, name: String
    let category: String
    let value: Double          // 当前市值
    let dayChange: Double      // 当日（或最近交易日）盈亏
    let dayPercent: Double?
    let profit: Double         // 持有收益 = 市值 - 成本
    let profitPercent: Double?
    let share: Double          // 持有份额
    let cost: Double           // 持仓成本价（每份）
    let price: Double          // 现价（估值或最新确认净值）
    let dcaPerDay: Double?     // 每个交易日的定投金额（没有定投为 nil）
    var id: String { code }
}

/// 同一指数类别的基金合并成一行（例如 13 只纳斯达克 100 → 一行）
struct CategoryRow: Identifiable {
    let name: String
    let count: Int
    let value: Double
    let weight: Double          // 占总资产的比例（0~1）
    let dayChange: Double
    let dayPercent: Double?
    let profit: Double
    let profitPercent: Double?
    var id: String { name }
}

/// 一个地区（美洲 / 欧洲 / 亚太 / 黄金）下的指数类别
struct RegionRow: Identifiable {
    let name: String
    let categories: [CategoryRow]
    let value: Double
    let weight: Double
    let dayChange: Double
    let dayPercent: Double?
    let profit: Double
    let profitPercent: Double?
    var id: String { name }
}

/// 定投概览：按地区、指数类别汇总每个交易日的定投金额（不写基金名）
struct DcaRegion: Identifiable {
    let name: String
    let total: Double
    let items: [(category: String, amount: Double)]
    var id: String { name }
}

struct Summary {
    var dca: [DcaRegion] = []
    var dcaPerDay = 0.0
    var dcaFundCount = 0
    var dcaOtherCount = 0       // 不是「每个交易日」的计划个数
    var totalValue = 0.0
    var dayChange = 0.0
    var dayPercent: Double? = nil
    var isLive = false          // 当日是估算值
    var profit = 0.0
    var profitPercent: Double? = nil
    var rows: [FundRow] = []
    var categories: [CategoryRow] = []
    var regions: [RegionRow] = []
    var updatedAt: Date? = nil
}

enum Portfolio {
    /// 按基金名称里的关键词归到指数类别（同一指数不同公司的基金归一类；先匹配的优先）
    /// 指数类别 → 地区（和行情窗一致：亚太 / 欧洲 / 美洲；黄金单独一张卡片）
    static func region(of category: String) -> String {
        switch category {
        case "纳斯达克100", "标普500": return "美洲"
        case "富时100", "德国 DAX", "法国 CAC40": return "欧洲"
        case "日经225", "中证A500", "红利", "亚太精选": return "亚太"
        case "黄金": return "黄金"
        default: return "其他"
        }
    }

    static func category(for name: String) -> String {
        let n = name.uppercased()
        let rules: [(String, [String])] = [
            ("纳斯达克100", ["纳斯达克", "纳指"]),
            ("标普500", ["标普"]),
            ("富时100", ["富时100"]),
            ("德国 DAX", ["DAX", "德国"]),
            ("法国 CAC40", ["CAC", "法国"]),
            ("日经225", ["日经"]),
            ("中证A500", ["A500"]),
            ("红利", ["红利"]),
            ("黄金", ["黄金"]),
            ("亚太精选", ["亚太"]),
        ]
        for (label, keys) in rules where keys.contains(where: { n.contains($0) }) { return label }
        return "其他"
    }

    static func summarize(raw: RawData, navs: [String: [NavService.Point]],
                          estimates: [String: NavService.Estimate] = [:], now: Date = Date()) -> Summary {
        var s = Summary()
        var costTotal = 0.0, prevTotal = 0.0
        for f in raw.funds {
            guard let h = raw.holdings[f.code], h.share > 0 else { continue }
            // 最新已确认净值和前一日净值：以自己拉的历史净值为准，没有才退回页面存的值
            let hist = navs[f.code] ?? []
            var nav = f.dwjz, navDate = f.jzrq, prev: Double? = nil
            if let last = hist.last {
                nav = last.value; navDate = last.date
                if hist.count >= 2 { prev = hist[hist.count - 2].value }
            } else if let n = f.dwjz, let z = f.zzl, z > -100 { prev = n / (1 + z / 100) }
            guard let confirmed = nav else { continue }
            var price = confirmed, base = prev ?? confirmed
            // 当日估值比最新确认净值更新时，用估值（QDII 等没有估值的基金继续用确认净值）
            if let e = estimates[f.code], String(e.gztime.prefix(10)) > navDate {
                price = e.gsz; base = confirmed; s.isLive = true
            }
            let value = h.share * price
            let cost = h.share * h.cost
            s.rows.append(FundRow(code: f.code, name: f.name, category: category(for: f.name), value: value, dayChange: h.share * (price - base),
                                  dayPercent: base > 0 ? (price / base - 1) * 100 : nil,
                                  profit: value - cost, profitPercent: cost > 0 ? (value / cost - 1) * 100 : nil,
                                  share: h.share, cost: h.cost, price: price,
                                  dcaPerDay: raw.plans[f.code].flatMap { $0.enabled && $0.cycle == "daily" ? $0.amount : nil }))
            s.totalValue += value; s.dayChange += h.share * (price - base); costTotal += cost; prevTotal += h.share * base
        }
        // 定投：只统计启用的、每个交易日的计划；其他周期只数个数
        var dca: [String: [String: Double]] = [:]      // 地区 → 类别 → 每天金额
        for f in raw.funds {
            guard let plan = raw.plans[f.code], plan.enabled else { continue }
            if plan.cycle != "daily" { s.dcaOtherCount += 1; continue }
            let cat = category(for: f.name)
            // 黄金没有统一的指数名，标明是哪家的（国泰黄金、工银黄金…）
            let label = cat == "黄金" ? String(f.name.prefix(2)) + "黄金" : cat
            dca[region(of: cat), default: [:]][label, default: 0] += plan.amount
            s.dcaPerDay += plan.amount; s.dcaFundCount += 1
        }
        let dcaOrder = ["亚太", "欧洲", "美洲", "黄金", "其他"]
        s.dca = dca.map { name, cats in
            DcaRegion(name: name, total: cats.values.reduce(0, +),
                      items: cats.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 })
        }.sorted { (dcaOrder.firstIndex(of: $0.name) ?? 99) < (dcaOrder.firstIndex(of: $1.name) ?? 99) }
        s.rows.sort { $0.value > $1.value }
        var groups: [String: [FundRow]] = [:]
        for r in s.rows { groups[r.category, default: []].append(r) }
        s.categories = groups.map { name, rs in
            let value = rs.reduce(0) { $0 + $1.value }
            let day = rs.reduce(0) { $0 + $1.dayChange }
            let profit = rs.reduce(0) { $0 + $1.profit }
            let cost = value - profit
            let prev = value - day
            return CategoryRow(name: name, count: rs.count, value: value,
                               weight: s.totalValue > 0 ? value / s.totalValue : 0,
                               dayChange: day, dayPercent: prev > 0 ? day / prev * 100 : nil,
                               profit: profit, profitPercent: cost > 0 ? profit / cost * 100 : nil)
        }.sorted { $0.value > $1.value }
        let order = ["亚太", "欧洲", "美洲", "黄金", "其他"]   // 和行情窗的地区顺序一致
        var byRegion: [String: [CategoryRow]] = [:]
        for c in s.categories { byRegion[region(of: c.name), default: []].append(c) }
        s.regions = byRegion.map { name, cs in
            let value = cs.reduce(0) { $0 + $1.value }
            let day = cs.reduce(0) { $0 + $1.dayChange }
            let profit = cs.reduce(0) { $0 + $1.profit }
            let cost = value - profit
            let prev = value - day
            return RegionRow(name: name, categories: cs, value: value,
                             weight: s.totalValue > 0 ? value / s.totalValue : 0,
                             dayChange: day, dayPercent: prev > 0 ? day / prev * 100 : nil,
                             profit: profit, profitPercent: cost > 0 ? profit / cost * 100 : nil)
        }.sorted { (order.firstIndex(of: $0.name) ?? 99) < (order.firstIndex(of: $1.name) ?? 99) }
        s.profit = s.totalValue - costTotal
        s.profitPercent = costTotal > 0 ? (s.totalValue / costTotal - 1) * 100 : nil
        s.dayPercent = prevTotal > 0 ? s.dayChange / prevTotal * 100 : nil
        s.updatedAt = now
        return s
    }
}
