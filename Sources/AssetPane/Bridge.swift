import Foundation
import WebKit

/// 基估宝页面存在 localStorage 里的数据（只读）
struct FundInfo {
    let code: String
    let name: String
    let dwjz: Double?     // 最新已确认净值
    let jzrq: String      // 净值日期
    let zzl: Double?      // 最新确认日涨跌幅（%）
    let gsz: Double?      // 估算净值
    let gszzl: Double?    // 估算涨跌幅（%）
    let gztime: String    // 估值时间 "YYYY-MM-DD HH:mm"
    let addedAt: Double?
}
struct Holding { let share: Double; let cost: Double; let firstPurchaseDate: String? }
struct Trade { let type: String; let amount: Double; let share: Double; let date: String; let isAfter3pm: Bool; let timestamp: Double }

struct PlanInfo { let amount: Double; let cycle: String; let enabled: Bool }

struct RawData {
    var plans: [String: PlanInfo] = [:]
    var funds: [FundInfo] = []
    var holdings: [String: Holding] = [:]
    var trades: [String: [Trade]] = [:]
}

func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

enum Bridge {
    private static let js = """
    JSON.stringify({
      funds: JSON.parse(localStorage.getItem('funds') || '[]'),
      holdings: JSON.parse(localStorage.getItem('holdings') || '{}'),
      transactions: JSON.parse(localStorage.getItem('transactions') || '{}'),
      dcaPlans: JSON.parse(localStorage.getItem('dcaPlans') || '{}')
    })
    """

    @MainActor
    static func read(from web: WKWebView) async -> RawData? {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(js) { result, _ in
                guard let s = result as? String, let data = s.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: parse(root))
            }
        }
    }

    static func parse(_ root: [String: Any]) -> RawData {
        var out = RawData()
        for f in (root["funds"] as? [[String: Any]]) ?? [] {
            guard let code = f["code"] as? String else { continue }
            out.funds.append(FundInfo(code: code, name: f["name"] as? String ?? code, dwjz: num(f["dwjz"]),
                                      jzrq: f["jzrq"] as? String ?? "", zzl: num(f["zzl"]), gsz: num(f["gsz"]),
                                      gszzl: num(f["gszzl"]), gztime: f["gztime"] as? String ?? "", addedAt: num(f["addedAt"])))
        }
        for (code, h) in (root["holdings"] as? [String: [String: Any]]) ?? [:] {
            out.holdings[code] = Holding(share: num(h["share"]) ?? 0, cost: num(h["cost"]) ?? 0,
                                         firstPurchaseDate: h["firstPurchaseDate"] as? String)
        }
        // 定投计划：{"__global__": {代码: 计划}}（旧版是扁平的 代码 → 计划）
        let planRoot = root["dcaPlans"] as? [String: Any] ?? [:]
        let planBucket = (planRoot["__global__"] as? [String: [String: Any]]) ?? (planRoot as? [String: [String: Any]]) ?? [:]
        for (code, p) in planBucket {
            guard let amount = num(p["amount"]), amount > 0 else { continue }
            out.plans[code] = PlanInfo(amount: amount, cycle: p["cycle"] as? String ?? "daily", enabled: (p["enabled"] as? Bool) ?? true)
        }
        for (code, list) in (root["transactions"] as? [String: [[String: Any]]]) ?? [:] {
            out.trades[code] = list.compactMap { t in
                // 只算全局账本里真正成交的：分组子账本（有 groupId）和仅历史记录的不算
                if t["groupId"] != nil || (t["isHistoryOnly"] as? Bool) == true { return nil }
                guard let date = t["date"] as? String else { return nil }
                return Trade(type: t["type"] as? String ?? "buy", amount: num(t["amount"]) ?? 0, share: num(t["share"]) ?? 0,
                             date: String(date.prefix(10)), isAfter3pm: (t["isAfter3pm"] as? Bool) ?? false,
                             timestamp: num(t["timestamp"]) ?? 0)
            }
        }
        return out
    }
}
