// NetMonitor — 轻量级 macOS 菜单栏网速监控 + 账户本
// 纯 AppKit，零第三方依赖；通过 getifaddrs 采集网卡字节计数差值计算实时速率

import AppKit
import Darwin

// MARK: - 格式化工具

func formatSpeed(_ bps: Double, compact: Bool = false) -> String {
    let kb = bps / 1024
    if kb < 1 { return String(format: "%.0f B/s", bps) }
    let mb = kb / 1024
    if mb < 1 { return kb >= 100 ? String(format: "%.0f KB/s", kb) : String(format: "%.1f KB/s", kb) }
    let gb = mb / 1024
    if gb < 1 { return mb >= 100 ? String(format: "%.0f MB/s", mb) : String(format: "%.1f MB/s", mb) }
    return String(format: "%.2f GB/s", gb)
}

func formatBytes(_ b: UInt64) -> String {
    var v = Double(b)
    let units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.2f %@", v, units[i])
}

// MARK: - 网络速率采集

struct NetSample {
    var down: Double  // B/s
    var up: Double    // B/s
}

final class NetMonitor {
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastTime: Double = 0
    private(set) var totalIn: UInt64 = 0    // 自启动累计收包
    private(set) var totalOut: UInt64 = 0   // 自启动累计发包
    private(set) var interfaceCount = 0

    private func currentBytes() -> (inB: UInt64, outB: UInt64, count: Int) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0, 0) }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        var seen = Set<String>()
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            // 关键：macOS 的字节计数只挂在 AF_LINK 条目上，
            // AF_INET / AF_INET6 条目的 ifa_data 为 NULL，必须按 AF_LINK 取。
            if let d = ifa.ifa_data, let addr = ifa.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                // 排除回环 / AirDrop 辅助 / 桥接 / 热点等，避免重复计数
                let skip = name == "lo0" || name.hasPrefix("awdl")
                    || name.hasPrefix("llw") || name.hasPrefix("bridge") || name.hasPrefix("ap")
                if !skip && seen.insert(name).inserted {
                    let nd = d.assumingMemoryBound(to: if_data.self)
                    inB &+= UInt64(nd.pointee.ifi_ibytes)
                    outB &+= UInt64(nd.pointee.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }
        return (inB, outB, seen.count)
    }

    func poll() -> NetSample? {
        let (inB, outB, count) = currentBytes()
        interfaceCount = count
        let now = Date().timeIntervalSinceReferenceDate
        defer { lastIn = inB; lastOut = outB; lastTime = now }
        guard lastTime > 0 else { return nil }
        let dt = now - lastTime
        guard dt > 0.2 else { return nil }
        let din = inB >= lastIn ? inB - lastIn : 0    // 计数器回绕时按 0 处理
        let dout = outB >= lastOut ? outB - lastOut : 0
        totalIn &+= din
        totalOut &+= dout
        return NetSample(down: Double(din) / dt, up: Double(dout) / dt)
    }
}

// MARK: - 滚动图表视图

final class ChartView: NSView {
    private var down: [Double] = []
    private var up: [Double] = []
    private let capacity = 120  // 120 秒窗口

    func addSample(_ s: NetSample) {
        down.append(s.down)
        up.append(s.up)
        if down.count > capacity {
            down.removeFirst(down.count - capacity)
            up.removeFirst(up.count - capacity)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 背景
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        // 横向网格线
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        for f in [0.25, 0.5, 0.75] {
            NSBezierPath(rect: NSRect(x: 6, y: bounds.height * CGFloat(f), width: bounds.width - 12, height: 0.5)).fill()
        }

        let maxV = max(down.max() ?? 0, up.max() ?? 0, 10 * 1024)
        drawSeries(up, color: .systemGreen, maxValue: maxV)
        drawSeries(down, color: .systemBlue, maxValue: maxV)
    }

    private func drawSeries(_ samples: [Double], color: NSColor, maxValue: Double) {
        guard samples.count >= 2, bounds.width > 0 else { return }
        let w = bounds.width
        let h = bounds.height - 2
        let stepX = w / CGFloat(capacity - 1)
        let startIdx = capacity - samples.count  // 右侧对齐，向左滚动

        func point(_ i: Int, _ v: Double) -> NSPoint {
            NSPoint(x: CGFloat(startIdx + i) * stepX, y: CGFloat(v / maxValue) * h + 1)
        }

        // 半透明填充
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: CGFloat(startIdx) * stepX, y: 1))
        for (i, v) in samples.enumerated() { fill.line(to: point(i, v)) }
        fill.line(to: NSPoint(x: w, y: 1))
        fill.close()
        color.withAlphaComponent(0.22).setFill()
        fill.fill()

        // 描边
        let stroke = NSBezierPath()
        stroke.move(to: point(0, samples[0]))
        for (i, v) in samples.enumerated() where i > 0 { stroke.line(to: point(i, v)) }
        color.setStroke()
        stroke.lineWidth = 1.5
        stroke.lineJoinStyle = .round
        stroke.stroke()
    }
}

// MARK: - 流量面板

final class MonitorPanelController: NSViewController {
    let monitor: NetMonitor
    private var chartView: ChartView!
    private var downField: NSTextField!
    private var upField: NSTextField!
    private var totalField: NSTextField!
    private var metaField: NSTextField!

    init(monitor: NetMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: 232))

        func label(_ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
            let tf = NSTextField(labelWithString: "")
            tf.frame = rect
            tf.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            tf.textColor = color
            v.addSubview(tf)
            return tf
        }

        downField = label(NSRect(x: 8, y: 190, width: 140, height: 32), size: 17, weight: .semibold)
        upField = label(NSRect(x: 156, y: 190, width: 140, height: 32), size: 17, weight: .semibold)

        chartView = ChartView(frame: NSRect(x: 8, y: 62, width: 288, height: 122))
        chartView.autoresizingMask = [.width]
        v.addSubview(chartView)

        metaField = label(NSRect(x: 8, y: 46, width: 288, height: 12), size: 9, color: .secondaryLabelColor)
        totalField = label(NSRect(x: 8, y: 30, width: 288, height: 12), size: 9, color: .secondaryLabelColor)

        let hint = label(NSRect(x: 8, y: 10, width: 288, height: 12), size: 9, color: .tertiaryLabelColor)
        hint.stringValue = "菜单栏常显速率 · 右键菜单可切换图标模式或复制当前速率"

        view = v
    }

    func update(_ s: NetSample) {
        assert(Thread.isMainThread)
        _ = view  // 触发懒加载
        chartView.addSample(s)

        func speed(_ arrow: String, _ color: NSColor, _ value: String) -> NSAttributedString {
            let a = NSMutableAttributedString(
                string: "\(arrow) ",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: color,
                ])
            a.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]))
            return a
        }

        downField.attributedStringValue = speed("↓", .systemBlue, formatSpeed(s.down))
        upField.attributedStringValue = speed("↑", .systemGreen, formatSpeed(s.up))

        metaField.attributedStringValue = {
            let a = NSMutableAttributedString(
                string: "● 下载  ",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemBlue])
            a.append(NSAttributedString(
                string: "● 上传  ",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemGreen]))
            a.append(NSAttributedString(
                string: "· \(monitor.interfaceCount) 个接口 · 近 120 秒",
                attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]))
            return a
        }()

        totalField.stringValue = "自启动累计：↓ \(formatBytes(monitor.totalIn))  ↑ \(formatBytes(monitor.totalOut))"
    }
}

// MARK: - 主窗口（账户本 + 流量监控，紧凑尺寸 + 可置顶）

final class MainWindowController: NSWindowController {
    private(set) var segmented: NSSegmentedControl!
    private(set) var pinButton: NSButton!
    private(set) var accountPanel: AccountPanelController!
    private(set) var monitorPanel: MonitorPanelController!

    /// 置顶状态（持久化）
    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: "nm.pinned") }
        set {
            UserDefaults.standard.set(newValue, forKey: "nm.pinned")
            applyPin()
        }
    }

    convenience init(monitor: NetMonitor) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "NetMonitor"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)

        accountPanel = AccountPanelController()
        monitorPanel = MonitorPanelController(monitor: monitor)
        buildUI()
        applyPin()
    }

    private func buildUI() {
        guard let content = window?.contentView, let win = window else { return }

        let seg = NSSegmentedControl(labels: ["账户本", "流量监控"], trackingMode: .selectOne, target: self,
                                     action: #selector(segmentChanged))
        seg.frame = NSRect(x: 10, y: 246, width: 150, height: 24)
        seg.font = NSFont.systemFont(ofSize: 11)
        seg.selectedSegment = 0
        content.addSubview(seg)
        segmented = seg

        // 置顶按钮：标题栏右上角的小图标（pin / pin.fill）
        let pin = NSButton(title: "置顶", target: self, action: #selector(pinTapped))
        pin.frame = NSRect(x: 0, y: 2, width: 30, height: 22)
        pin.bezelStyle = .regularSquare
        pin.isBordered = false
        pin.imagePosition = .imageOnly
        pin.controlSize = .small
        pin.contentTintColor = .secondaryLabelColor
        pin.toolTip = "置顶窗口"
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = pin
        accessory.layoutAttribute = .right
        win.addTitlebarAccessoryViewController(accessory)
        pinButton = pin

        for panel in [accountPanel.view, monitorPanel.view] {
            panel.frame = NSRect(x: 8, y: 8, width: 304, height: 232)
            panel.autoresizingMask = [.width]
            content.addSubview(panel)
        }
        monitorPanel.view.isHidden = true
    }

    private func applyPin() {
        guard let win = window else { return }
        if pinned {
            win.level = .floating                       // 完全置顶
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // 跨空间跟随
        } else {
            win.level = .normal
            win.collectionBehavior = []
        }
        // 图标随状态切换：钉住=pin.fill（主题色），未钉=pin（灰色）
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                   accessibilityDescription: pinned ? "取消置顶" : "置顶窗口")
        pinButton?.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func pinTapped() {
        pinned.toggle()
    }

    @objc private func segmentChanged() {
        let showMonitor = segmented.selectedSegment == 1
        monitorPanel.view.isHidden = !showMonitor
        accountPanel.view.isHidden = showMonitor
    }

    /// 0 = 账户本，1 = 流量监控
    func select(tab: Int) {
        segmented.selectedSegment = tab < 0 || tab > 1 ? 0 : tab
        segmentChanged()
    }

    func updateMonitor(_ s: NetSample) {
        _ = monitorPanel.view  // 触发懒加载，避免隐藏时首帧为空
        monitorPanel.update(s)
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = NetMonitor()
    var statusItem: NSStatusItem!
    var mainWindow: MainWindowController!
    var timer: Timer?
    private var lastSample: NetSample?

    enum DisplayMode: String { case text, icon }
    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "nm.displayMode") ?? "") ?? .text }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nm.displayMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            btn.toolTip = "NetMonitor — 点击打开账户本 / 右键菜单"
            btn.action = #selector(statusClicked)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyDisplayMode()

        mainWindow = MainWindowController(monitor: monitor)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()

        // 调试钩子：NM_SHOW_WINDOW=1 启动即打开窗口；NM_TAB=monitor 切到流量页
        let env = ProcessInfo.processInfo.environment
        if env["NM_SHOW_WINDOW"] == "1" {
            openWindow(tab: env["NM_TAB"] == "monitor" ? 1 : 0)
        }
    }

    func tick() {
        guard let s = monitor.poll() else { return }
        lastSample = s
        mainWindow.updateMonitor(s)
        if displayMode == .text, let btn = statusItem.button {
            // 菜单栏紧凑显示：去掉 "/s" 省宽度
            btn.title = "↓\(shortSpeed(s.down)) ↑\(shortSpeed(s.up))"
        }
    }

    private func shortSpeed(_ bps: Double) -> String {
        let s = formatSpeed(bps)
        return s.hasSuffix("/s") ? String(s.dropLast(2)) : s
    }

    // MARK: 菜单栏显示

    func applyDisplayMode() {
        guard let btn = statusItem.button else { return }
        if displayMode == .icon {
            btn.title = ""
            btn.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "网络流量")
        } else {
            btn.image = nil
            btn.title = lastSample.map { "↓\(shortSpeed($0.down)) ↑\(shortSpeed($0.up))" } ?? "…"
        }
    }

    @objc func toggleDisplayMode() {
        displayMode = displayMode == .text ? .icon : .text
        applyDisplayMode()
    }

    @objc func copyCurrentSpeed() {
        guard let s = lastSample else { return }
        let text = "↓ \(formatSpeed(s.down))  ↑ \(formatSpeed(s.up))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: 窗口

    func openWindow(tab: Int = 0) {
        mainWindow.select(tab: tab)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.showWindow(nil)
        mainWindow.window?.makeKeyAndOrderFront(nil)
    }

    @objc func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
            return
        }
        if let win = mainWindow.window, win.isVisible {
            win.orderOut(nil)
        } else {
            openWindow(tab: 0)   // 直接进入账户本
        }
    }

    @objc private func showAccountTab() { openWindow(tab: 0) }
    @objc private func showMonitorTab() { openWindow(tab: 1) }
    @objc private func togglePin() { mainWindow.pinned.toggle() }

    private func showMenu() {
        let menu = NSMenu()

        let accounts = NSMenuItem(title: "账户本", action: #selector(showAccountTab), keyEquivalent: "")
        accounts.target = self
        menu.addItem(accounts)

        let monitorItem = NSMenuItem(title: "流量监控", action: #selector(showMonitorTab), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)

        let pinItem = NSMenuItem(title: mainWindow.pinned ? "取消置顶" : "置顶窗口",
                                 action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)
        menu.addItem(.separator())

        let mode = NSMenuItem(
            title: displayMode == .text ? "菜单栏显示：切换为图标" : "菜单栏显示：切换为文字",
            action: #selector(toggleDisplayMode), keyEquivalent: "")
        mode.target = self
        menu.addItem(mode)

        let copy = NSMenuItem(title: "复制当前速率", action: #selector(copyCurrentSpeed), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 NetMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
