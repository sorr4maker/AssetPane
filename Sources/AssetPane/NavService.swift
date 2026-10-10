import Foundation

/// 历史净值：东方财富 pingzhongdata 里的 Data_netWorthTrend，按基金缓存到磁盘（6 小时内直接用缓存，抓不到就用旧缓存）
enum NavService {
    static let tz = TimeZone(identifier: "Asia/Shanghai")!
    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AssetPane/nav", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func dayString(_ d: Date) -> String { dayFormat.string(from: d) }
    static func day(_ s: String) -> Date { dayFormat.date(from: s) ?? Date(timeIntervalSince1970: 0) }

    struct Point: Codable { let date: String; let value: Double }
    private struct Cache: Codable { let fetchedAt: Date; let points: [Point] }

    static func history(code: String) async -> [Point] {
        let file = cacheDir.appendingPathComponent("\(code).json")
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        if let c = cached, Date().timeIntervalSince(c.fetchedAt) < 6 * 3600 { return c.points }
        if let fresh = await fetch(code: code), !fresh.isEmpty {
            if let data = try? JSONEncoder().encode(Cache(fetchedAt: Date(), points: fresh)) { try? data.write(to: file) }
            return fresh
        }
        return cached?.points ?? []
    }

    private static func fetch(code: String) async -> [Point]? {
        guard let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(code).js") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let js = String(data: data, encoding: .utf8) else { return nil }
        return parse(js)
    }

    /// 取出 `Data_netWorthTrend = [ ... ]` 这段 JSON 数组
    static func parse(_ js: String) -> [Point]? {
        guard let key = js.range(of: "Data_netWorthTrend = ") else { return nil }
        let rest = js[key.upperBound...]
        guard let start = rest.firstIndex(of: "[") else { return nil }
        var depth = 0, end: String.Index?
        var i = start
        while i < rest.endIndex {
            let ch = rest[i]
            if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1; if depth == 0 { end = i; break } }
            i = rest.index(after: i)
        }
        guard let end, let data = String(rest[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { d in
            guard let x = num(d["x"]), let y = num(d["y"]) else { return nil }
            return Point(date: dayFormat.string(from: Date(timeIntervalSince1970: x / 1000)), value: y)
        }.sorted { $0.date < $1.date }
    }

    /// 天天基金当日估值（fundgz）。QDII 等没有估值的基金会返回空，调用方当成「没有估值」
    struct Estimate { let gsz: Double; let gszzl: Double?; let gztime: String }

    static func estimate(code: String) async -> Estimate? {
        guard let url = URL(string: "https://fundgz.1234567.com.cn/js/\(code).js?rt=\(Int(Date().timeIntervalSince1970 * 1000))") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let js = String(data: data, encoding: .utf8),
              let a = js.firstIndex(of: "{"), let b = js.lastIndex(of: "}"), a < b,
              let obj = try? JSONSerialization.jsonObject(with: Data(js[a...b].utf8)) as? [String: Any],
              let gsz = num(obj["gsz"]), gsz > 0 else { return nil }
        return Estimate(gsz: gsz, gszzl: num(obj["gszzl"]), gztime: obj["gztime"] as? String ?? "")
    }
}
