import SwiftUI

private let up = Color(red: 0.93, green: 0.27, blue: 0.27)     // 红涨
private let down = Color(red: 0.16, green: 0.70, blue: 0.40)    // 绿跌
private func trendColor(_ v: Double) -> Color { v > 0 ? up : (v < 0 ? down : .secondary) }
private func money(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2)).grouping(.automatic)) }
private func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + money(v) }
private func pct(_ v: Double?) -> String { v.map { ($0 > 0 ? "+" : "") + String(format: "%.2f%%", $0) } ?? "—" }
private func yuan(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

/// 内容在当前缩放下的高度（用来推算该缩放多少才刚好放得下）
private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 面板宽度为这个值时字号取设计值；面板变大变小，字号和间距按比例变（不是把画面拉伸，所以文字始终清晰）
private let designWidth: CGFloat = 330

struct AssetPanelView: View {
    @ObservedObject var model: AppModel
    @State private var heightAtUnitScale: CGFloat = 540   // 缩放比例为 1 时内容的高度

    var body: some View {
        GeometryReader { geo in
            let k = min(max(min(geo.size.width / designWidth, geo.size.height / max(heightAtUnitScale, 1)), 0.55), 2.4)
            PanelContent(model: model, summary: model.summary, k: k)
                .frame(width: geo.size.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                .onPreferenceChange(HeightKey.self) { h in
                    // 内容高度和缩放比例成正比，除回去得到「比例为 1 时」的高度
                    let unit = h / k
                    if abs(unit - heightAtUnitScale) > 0.5 { heightAtUnitScale = unit }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .contextMenu {
            Button(model.editingLayout ? "完成调整" : "调整大小和位置") { model.editingLayout.toggle() }
            Button("管理持仓与定投…") { model.openManager() }
            Button("立即刷新") { model.refresh() }
        }
    }
}

/// 鼠标移上去时亮起一个圆角小框，提示这一行可以点开（和行情窗一样）
private struct HoverRow<Content: View>: View {
    let k: CGFloat
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = ProcessInfo.processInfo.environment["ASSETPANE_DEBUG_HOVER"] != nil   // 调试：所有行都显示悬停样子

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 6 * k, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.30 : 0), lineWidth: 0.8))
                    .padding(.horizontal, -5 * k).padding(.vertical, -1.5 * k)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            .help("点击查看详细持仓")
    }
}

private struct PanelContent: View {
    @ObservedObject var model: AppModel
    let summary: Summary
    let k: CGFloat
    @State private var masked = false

    private func f(_ size: CGFloat) -> Font { .system(size: size * k) }
    private func f(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size * k, weight: weight) }

    // 列宽：名称自适应，其余固定，保证每行对齐
    private var wDay: CGFloat { 44 * k }
    private var wValue: CGFloat { 52 * k }
    private var wProfit: CGFloat { 47 * k }
    private var wPct: CGFloat { 42 * k }

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 7 * k) {
            header(s)
            if s.rows.isEmpty { emptyState } else {
                columnTitles
                ForEach(s.regions) { r in regionCard(r) }
                if !s.dca.isEmpty { dcaCard(s) }
            }
            footer(s)
        }
        .padding(14 * k)
    }

    private func header(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 2 * k) {
            HStack(spacing: 5 * k) {
                Text("总资产").font(f(10)).foregroundStyle(.secondary)
                Button { masked.toggle() } label: { Image(systemName: masked ? "eye.slash" : "eye").font(f(9)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.mini) }
            }
            Text(masked ? "••••••" : "¥" + money(s.totalValue))
                .font(.system(size: 24 * k, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack(spacing: 14 * k) {
                stat(s.isLive ? "今日（估）" : "最近交易日", masked ? "••••" : signed(s.dayChange), pct(s.dayPercent), trendColor(s.dayChange))
                stat("持有收益", masked ? "••••" : signed(s.profit), pct(s.profitPercent), trendColor(s.profit))
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ percent: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(f(9)).foregroundStyle(.secondary)
            HStack(spacing: 4 * k) {
                Text(value).font(f(11, .medium)).monospacedDigit()
                Text(percent).font(f(9)).monospacedDigit()
            }.foregroundStyle(color)
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("今日").frame(width: wDay, alignment: .trailing)
            Text("市值").frame(width: wValue, alignment: .trailing)
            Text("持有收益").frame(width: wProfit + wPct, alignment: .trailing)
        }
        .font(f(8)).foregroundStyle(.tertiary)
        .padding(.horizontal, 10 * k)
    }

    private func line(_ name: String, count: Int = 0, day: Double?, dayChange: Double, value: Double,
                      profit: Double, profitPercent: Double?, bold: Bool = false, onTap: @escaping () -> Void) -> some View {
        HoverRow(k: k, onTap: onTap) {
        HStack(spacing: 0) {
            HStack(spacing: 4 * k) {
                Text(name).font(f(bold ? 11 : 10, bold ? .semibold : .regular)).lineLimit(1)
                if count > 1 { Text("\(count)只").font(f(8)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 4 * k)
            Text(pct(day)).foregroundStyle(trendColor(dayChange)).frame(width: wDay, alignment: .trailing)
            Text(masked ? "••••" : money(value)).frame(width: wValue, alignment: .trailing)
            Text(masked ? "••" : signed(profit)).foregroundStyle(trendColor(profit)).frame(width: wProfit, alignment: .trailing)
            Text(pct(profitPercent)).foregroundStyle(trendColor(profit)).frame(width: wPct, alignment: .trailing)
        }
        .font(f(bold ? 9.5 : 9)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// 地区卡片（亚太 / 欧洲 / 美洲，黄金单独一张）：头部是该地区合计，下面每行一个指数
    private func regionCard(_ r: RegionRow) -> some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            HStack(spacing: 4 * k) {
                if r.name == "黄金" { Circle().fill(Color(red: 0.85, green: 0.65, blue: 0.13)).frame(width: 6 * k, height: 6 * k) }
                line(r.name, day: r.dayPercent, dayChange: r.dayChange, value: r.value,
                     profit: r.profit, profitPercent: r.profitPercent, bold: true,
                     onTap: { model.showDetail(.region(r.name)) })
            }
            // 黄金这张卡片本身就只有一个指数，不再重复一行
            ForEach(r.name == "黄金" ? [] : r.categories) { c in
                line(c.name, count: c.count, day: c.dayPercent, dayChange: c.dayChange, value: c.value,
                     profit: c.profit, profitPercent: c.profitPercent,
                     onTap: { model.showDetail(.category(c.name)) })
                    .padding(.leading, 6 * k)
            }
        }
        .padding(.horizontal, 10 * k).padding(.vertical, 7 * k)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11 * k, style: .continuous))
    }

    /// 定投概览：每个交易日按地区 / 指数汇总的金额，不写基金名
    private func dcaCard(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 3 * k) {
            HStack {
                Text("定投").font(f(11, .semibold))
                Text("每个交易日 \(masked ? "••" : yuan(s.dcaPerDay)) 元 · \(s.dcaFundCount) 只")
                    .font(f(9)).foregroundStyle(.secondary)
            }
            ForEach(s.dca) { r in
                HStack(alignment: .firstTextBaseline, spacing: 6 * k) {
                    Text(r.name).font(f(10)).frame(width: 30 * k, alignment: .leading)
                    // 地区下只有一个同名指数（黄金）时不重复写名字
                    let detail = (r.items.count == 1 && r.items[0].category == r.name) ? "" :
                        r.items.map { "\($0.category) \(masked ? "••" : yuan($0.amount))" }.joined(separator: " · ")
                    Text(detail).font(f(9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4 * k)
                    Text(masked ? "••" : yuan(r.total)).font(f(10)).monospacedDigit()
                }
            }
            if s.dcaOtherCount > 0 {
                Text("另有 \(s.dcaOtherCount) 个非每日计划").font(f(8)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10 * k).padding(.vertical, 7 * k)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11 * k, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8 * k) {
            Image(systemName: "tray").font(f(22)).foregroundStyle(.secondary)
            Text("还没有持仓").font(f(11, .medium))
            Text("点下面的按钮添加基金、持仓和定投计划，\n之后这里会自动显示资产变化。")
                .font(f(9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("管理持仓与定投") { model.openManager() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 200 * k)
    }

    private func footer(_ s: Summary) -> some View {
        // 调整大小模式下底部左边是提示、右下角是缩放手柄，底栏让出来，免得叠在一起
        HStack(spacing: 8 * k) {
            if model.editingLayout { Spacer() } else {
                Text(s.updatedAt.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未更新")
                    .font(f(8)).foregroundStyle(.tertiary)
                Spacer()
                Button { model.editingLayout.toggle() } label: {
                    Label("调整大小", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain).font(f(8)).foregroundStyle(.secondary)
                Button("管理持仓与定投") { model.openManager() }.buttonStyle(.plain)
                    .font(f(8)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 12 * k)
    }
}
