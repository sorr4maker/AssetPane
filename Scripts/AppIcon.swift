// App 图标：青绿渐变底 + 白卡片，卡片里一条向上的资产曲线（下面有淡淡的填充）和一条虚线（净投入）。
// 用法：swift Scripts/AppIcon.swift <输出.png>；一般用 Scripts/make-icon.sh 一步生成 Resources/AppIcon.icns
import SwiftUI
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let teal = Color(red: 0.05, green: 0.60, blue: 0.62)

struct IconBody<Content: View>: View {
    let fill: AnyShapeStyle
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous).fill(fill)
            content()
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)], startPoint: .top, endPoint: .center), lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

struct CurveIcon: View {
    static let pts: [CGFloat] = [0.08, 0.14, 0.12, 0.30, 0.26, 0.46, 0.42, 0.62, 0.56, 0.80]
    var body: some View {
        IconBody(fill: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.10, green: 0.72, blue: 0.62), Color(red: 0.06, green: 0.36, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))) {
            ZStack {
                RoundedRectangle(cornerRadius: 70, style: .continuous).fill(.white.opacity(0.93)).frame(width: 600, height: 560)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                let w: CGFloat = 480, h: CGFloat = 380
                ZStack {
                    Path { p in
                        p.move(to: .init(x: 0, y: h))
                        for (i, v) in Self.pts.enumerated() { p.addLine(to: .init(x: w * CGFloat(i) / CGFloat(Self.pts.count - 1), y: h - h * v)) }
                        p.addLine(to: .init(x: w, y: h)); p.closeSubpath()
                    }.fill(LinearGradient(colors: [teal.opacity(0.30), teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: .init(x: 0, y: h - h * 0.10))
                        p.addLine(to: .init(x: w * 0.4, y: h - h * 0.10)); p.addLine(to: .init(x: w * 0.4, y: h - h * 0.30))
                        p.addLine(to: .init(x: w * 0.75, y: h - h * 0.30)); p.addLine(to: .init(x: w * 0.75, y: h - h * 0.45))
                        p.addLine(to: .init(x: w, y: h - h * 0.45))
                    }.stroke(Color(white: 0.55), style: StrokeStyle(lineWidth: 8, lineCap: .round, dash: [16, 14]))
                    Path { p in
                        for (i, v) in Self.pts.enumerated() {
                            let pt = CGPoint(x: w * CGFloat(i) / CGFloat(Self.pts.count - 1), y: h - h * v)
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                    }.stroke(teal, style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                }
                .frame(width: w, height: h)
            }
        }
    }
}

MainActor.assumeIsolated {
    let r = ImageRenderer(content: CurveIcon()); r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("画图失败"); exit(1) }
    try! png.write(to: out)
}
