import AppKit
import SwiftUI

/// 无边框面板要能接收键盘（在页面里输入基金代码、金额），所以让它能成为 key window
/// 面板不是前台窗口时，点一下也要直接响应（不用先点一次激活）
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 贴在桌面上的面板：在桌面图标之上、所有普通窗口之下，所有桌面空间都显示。
/// 平时锁定；菜单里点「编辑布局」后才能拖动和拖右下角调整大小，编辑时暂时浮到其他窗口上面。
/// 位置和大小用 autosave 记住。
@MainActor
final class PanelController {
    private var panel: KeyablePanel?
    private var overlay: EditOverlay?
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private static let autosaveName = "AssetPanePanelV4"
    private static let defaultSize = NSSize(width: 340, height: 540)
    private static let minSize = NSSize(width: 230, height: 300)

    /// 上次的位置和大小（AppKit 存的格式：x y 宽 高 屏幕x 屏幕y 屏幕宽 屏幕高）
    private static func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") else { return nil }
        let n = s.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 4, n[2] > 0, n[3] > 0 else { return nil }
        return NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// 面板当前位置（详情窗口贴着它摆）
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func setVisible(_ visible: Bool, model: AppModel, onEditDone: @escaping () -> Void) {
        if !visible { panel?.orderOut(nil); return }
        let p = panel ?? makePanel(model: model, onEditDone: onEditDone)
        panel = p
        p.orderFrontRegardless()
        keepOnScreen(p)
    }

    func setEditing(_ on: Bool) {
        guard let panel else { return }
        panel.level = on ? .floating : Self.desktopLevel
        overlay?.isHidden = !on
        panel.orderFrontRegardless()
    }

    /// 调试用：把面板（原生界面）画成 PNG 写到 path，不需要屏幕录制权限
    func snapshot(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    private func makePanel(model: AppModel, onEditDone: @escaping () -> Void) -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.level = Self.desktopLevel
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.minSize = Self.minSize

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        
        let host = FirstMouseHostingView(rootView: AssetPanelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        let overlay = EditOverlay(frame: container.bounds, done: onEditDone)
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        container.addSubview(overlay)
        self.overlay = overlay

        p.contentView = container
        if let saved = Self.savedFrame() {
            p.setFrame(saved, display: false)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrame(NSRect(x: v.minX + 24, y: v.maxY - Self.defaultSize.height - 24,
                              width: Self.defaultSize.width, height: Self.defaultSize.height), display: false)
        }
        p.setFrameAutosaveName(Self.autosaveName)
        return p
    }

    /// 换了更小的屏幕时，把面板挪回屏幕里
    private func keepOnScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = panel.frame
        f.size.width = min(f.width, v.width); f.size.height = min(f.height, v.height)
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.minY < v.minY { f.origin.y = v.minY }
        if f != panel.frame { panel.setFrame(f, display: true) }
    }
}

/// 编辑布局时盖在面板上：虚线边框、「完成」按钮、右下角缩放手柄，其余地方按住就能拖动整个面板
final class EditOverlay: NSView {
    private let done: () -> Void

    init(frame: NSRect, done: @escaping () -> Void) {
        self.done = done
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2

        let button = NSButton(title: "完成", target: self, action: #selector(finish))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: frame.width - 72, y: frame.height - 40, width: 60, height: 28)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(button)

        let hint = NSTextField(labelWithString: "按住拖动 · 拖右下角调整大小")
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 12, y: 10, width: 200, height: 16)
        hint.autoresizingMask = [.maxXMargin, .maxYMargin]
        addSubview(hint)

        let grip = Grip(frame: NSRect(x: frame.width - 28, y: 6, width: 22, height: 22))
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(grip)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func finish() { done() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// 右下角缩放手柄：拖动时左上角不动，大小不小于窗口的 minSize
final class Grip: NSView {
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        for i in 0..<3 {
            let d = CGFloat(i) * 5 + 5
            let p = NSBezierPath()
            p.move(to: NSPoint(x: bounds.maxX - d, y: bounds.minY + 2))
            p.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + d))
            p.lineWidth = 1.5
            p.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let m = NSEvent.mouseLocation
        let w = max(window.minSize.width, startFrame.width + (m.x - startMouse.x))
        let h = max(window.minSize.height, startFrame.height - (m.y - startMouse.y))
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - h, width: w, height: h), display: true)
    }
}
