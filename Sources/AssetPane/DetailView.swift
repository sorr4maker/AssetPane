import SwiftUI

private let up = Color(red: 0.93, green: 0.27, blue: 0.27)     // 红涨
private let down = Color(red: 0.16, green: 0.70, blue: 0.40)    // 绿跌
private func trendColor(_ v: Double) -> Color { v > 0 ? up : (v < 0 ? down : .secondary) }
private func money(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2)).grouping(.automatic)) }
private func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + money(v) }
private func pct(_ v: Double?) -> String { v.map { ($0 > 0 ? "+" : "") + String(format: "%.2f%%", $0) } ?? "—" }
private func yuan(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

/// 点开的是一个指数类别（如纳斯达克100），还是一个地区（如美洲）
enum DetailKey: Hashable {
    case category(String), region(String)

    var name: String { switch self { case .category(let n), .region(let n): return n } }

    func contains(_ row: FundRow) -> Bool {
        switch self {
        case .category(let n): return row.category == n
        case .region(let n): return Portfolio.region(of: row.category) == n
        }
    }
}

/// 详细持仓：列出这个指数 / 地区里的每一只基金（随面板刷新实时更新）
struct DetailView: View {
    @ObservedObject var model: AppModel
    let key: DetailKey

    private var rows: [FundRow] { model.summary.rows.filter { key.contains($0) } }

    var body: some View {
        let rows = self.rows
        let value = rows.reduce(0) { $0 + $1.value }
        let day = rows.reduce(0) { $0 + $1.dayChange }
        let profit = rows.reduce(0) { $0 + $1.profit }
        let cost = value - profit
        let dca = rows.reduce(0) { $0 + ($1.dcaPerDay ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            // 合计
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(key.name) · \(rows.count) 只").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("¥" + money(value)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text(signed(day)); Text(pct(value - day > 0 ? day / (value - day) * 100 : nil))
                    }.font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(trendColor(day))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("持有收益").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text(signed(profit)); Text(pct(cost > 0 ? profit / cost * 100 : nil))
                    }.font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(trendColor(profit))
                }
                if dca > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("定投").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("每个交易日 \(yuan(dca)) 元").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                }
            }
            Divider()
            // 列标题
            HStack(spacing: 0) {
                Text("基金")
                Spacer()
                Text("今日").frame(width: 64, alignment: .trailing)
                Text("市值").frame(width: 84, alignment: .trailing)
                Text("持有收益").frame(width: 130, alignment: .trailing)
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(r.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(pct(r.dayPercent)).foregroundStyle(trendColor(r.dayChange)).frame(width: 64, alignment: .trailing)
                                Text(money(r.value)).frame(width: 84, alignment: .trailing)
                                HStack(spacing: 5) { Text(signed(r.profit)); Text(pct(r.profitPercent)) }
                                    .foregroundStyle(trendColor(r.profit)).frame(width: 130, alignment: .trailing)
                            }
                            .font(.system(size: 12)).monospacedDigit()
                            Text(([r.code,
                                   "份额 \(String(format: "%.2f", r.share))",
                                   "成本 \(String(format: "%.4f", r.cost))",
                                   "现价 \(String(format: "%.4f", r.price))"]
                                  + (r.dcaPerDay.map { ["定投 \(yuan($0))/天"] } ?? [])).joined(separator: "  ·  "))
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
