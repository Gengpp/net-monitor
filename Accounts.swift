// Accounts.swift — 账户存储（机器绑定 AES-GCM 加密）+ 账户标签面板（流式 Tag 布局）
// 交互：单击标签＝载入内容到输入框（可选中复制）· 双击＝复制用户名 · 三击＝复制密码 · ✕＝删除

import AppKit
import CryptoKit
import Darwin

// MARK: - 账户模型与存储

struct Account: Codable {
    var username: String
    var secret: String   // base64(AES-GCM 组合格式)，非明文
    var nickname: String? // 显示用昵称，nil/空则回退显示用户名
}

/// 旧版（不可逆哈希）结构，仅用于识别并迁移
private struct LegacyAccount: Codable {
    var username: String
    var salt: String
    var hash: String
}

final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [Account] = []
    private let fileURL: URL
    private(set) var didMigrateLegacyStore = false

    /// - Parameter directory: 仅测试用，可指定自定义目录
    init(directory: URL? = nil) {
        let base: URL
        if let d = directory {
            base = d
        } else if let envDir = ProcessInfo.processInfo.environment["NM_STORE_DIR"], !envDir.isEmpty {
            base = URL(fileURLWithPath: envDir)   // 测试钩子：指定存储目录
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            base = appSupport.appendingPathComponent("NetMonitor", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("accounts.json")
        load()
    }

    // MARK: 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { seedDefault(); return }

        if let list = try? JSONDecoder().decode([Account].self, from: data), !list.isEmpty {
            accounts = list
            return
        }
        // 旧版哈希结构无法还原密码：重建为默认账户
        if (try? JSONDecoder().decode([LegacyAccount].self, from: data)) != nil {
            seedDefault()
        } else {
            seedDefault()
        }
    }

    private func seedDefault() {
        accounts = []
        _ = add(username: "gpp", password: "6866788")
        didMigrateLegacyStore = true
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(accounts) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    // MARK: 加密（机器绑定密钥，AES-GCM）

    private static let vaultKey: SymmetricKey = {
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        var ts = timespec(tv_sec: 1, tv_nsec: 0)
        let rc = uuidBytes.withUnsafeMutableBufferPointer { buf -> Int32 in
            gethostuuid(buf.baseAddress, &ts)
        }
        let idHex = rc == 0 ? uuidBytes.map { String(format: "%02x", $0) }.joined() : "no-host-id"
        let material = Data(("com.gengpp.netmonitor.vault.v1:" + idHex).utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }()

    private static func seal(_ plain: String) -> String {
        guard let box = try? AES.GCM.seal(Data(plain.utf8), using: vaultKey),
              let combined = box.combined else { return "" }
        return combined.base64EncodedString()
    }

    private static func open(_ secret: String) -> String? {
        guard let data = Data(base64Encoded: secret),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: vaultKey) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: 查询

    var usernames: [String] { accounts.map(\.username) }

    func exists(_ username: String) -> Bool {
        accounts.contains { $0.username == username }
    }

    func password(for username: String) -> String? {
        guard let acc = accounts.first(where: { $0.username == username }) else { return nil }
        return Self.open(acc.secret)
    }

    // MARK: 修改（返回错误提示，nil 表示成功）

    @discardableResult
    func add(username: String, password: String, nickname: String? = nil) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "用户名不能为空" }
        guard !name.contains(" ") else { return "用户名不能包含空格" }
        guard !exists(name) else { return "用户名已存在" }
        guard !password.isEmpty else { return "密码不能为空" }
        let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts.append(Account(username: name, secret: Self.seal(password),
                                nickname: (nick?.isEmpty == false) ? nick : nil))
        save()
        return nil
    }

    func remove(username: String) -> String? {
        accounts.removeAll { $0.username == username }
        save()
        return nil
    }

    func setPassword(username: String, password: String) -> String? {
        guard !password.isEmpty else { return "密码不能为空" }
        guard let idx = accounts.firstIndex(where: { $0.username == username }) else {
            return "账户不存在"
        }
        accounts[idx].secret = Self.seal(password)
        save()
        return nil
    }

    /// 昵传空串/nil 表示清除昵称（回退显示用户名）
    @discardableResult
    func setNickname(username: String, nickname: String?) -> String? {
        guard let idx = accounts.firstIndex(where: { $0.username == username }) else {
            return "账户不存在"
        }
        let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[idx].nickname = (nick?.isEmpty == false) ? nick : nil
        save()
        return nil
    }

    func rename(_ old: String, to new: String) -> String? {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "用户名不能为空" }
        guard !name.contains(" ") else { return "用户名不能包含空格" }
        guard name != old else { return nil }
        guard !exists(name) else { return "用户名已存在" }
        guard let idx = accounts.firstIndex(where: { $0.username == old }) else { return "账户不存在" }
        accounts[idx].username = name
        save()
        return nil
    }
}

// MARK: - el-tag 风格彩色标签

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// el-tag 样式：浅色底 + 同系边框 + 同系文字，圆角 4
final class TagChipView: NSView {
    var onClickCount: ((Int) -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClickCount?(event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    /// 阻止默认右键菜单
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    init(text: String, colors: (bg: NSColor, border: NSColor, text: NSColor),
         selected: Bool, textWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: textWidth + 18, height: 22))
        wantsLayer = true
        layer?.backgroundColor = colors.bg.cgColor
        layer?.borderColor = colors.border.cgColor
        layer?.borderWidth = selected ? 2 : 1
        layer?.cornerRadius = 4
        let lb = NSTextField(labelWithString: text)
        lb.font = NSFont.systemFont(ofSize: 11, weight: selected ? .medium : .regular)
        lb.textColor = colors.text
        lb.frame = NSRect(x: 9, y: 3, width: textWidth, height: 16)
        addSubview(lb)
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - 流式标签布局（宽度不足自动换行）

final class TagFlowView: NSView {
    override var isFlipped: Bool { true }   // 从上往下排列，阅读顺序与账户顺序一致

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maxW = bounds.width
        let gap: CGFloat = 6
        var x: CGFloat = gap
        var y: CGFloat = gap
        var rowH: CGFloat = 0
        for sub in subviews {
            let w = sub.frame.width, h = sub.frame.height
            if x + w > maxW - gap && x > gap {   // 放不下则换行
                x = gap
                y += rowH + gap
                rowH = 0
            }
            sub.frame.origin = NSPoint(x: x, y: y)
            x += w + gap
            rowH = max(rowH, h)
        }
        // 文档高度随内容/换行变化，供滚动
        let minH = enclosingScrollView?.contentSize.height ?? 0
        let contentH = (subviews.isEmpty ? 0 : y + rowH + gap) + gap
        let newH = max(contentH, minH)
        if abs(frame.height - newH) > 0.5 {
            frame.size.height = newH
        }
    }
}

// MARK: - 账户面板（标签 + 内容输入框）

final class AccountPanelController: NSViewController {

    private let store = AccountStore.shared
    private var flowView: TagFlowView!
    private var nickField: NSTextField!
    private var accField: NSTextField!
    private var passField: NSTextField!
    private var selectedLabel: NSTextField!
    private var hintLabel: NSTextField!
    private static let helpText = "单击标签＝载入内容（输入框文本可选中复制）· 双击＝复制用户名 · 三击＝复制密码 · 右键标签＝删除"
    private var pendingLoad: DispatchWorkItem?
    private var pendingCopy: DispatchWorkItem?
    private var hintResetWork: DispatchWorkItem?
    private var selectedUsername: String?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: 232))

        // 标签流式区（顶部）
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 128, width: 288, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let flow = TagFlowView(frame: NSRect(x: 0, y: 0, width: 286, height: 96))
        flow.autoresizingMask = [.width]
        scroll.documentView = flow
        v.addSubview(scroll)
        flowView = flow

        // 表单（设计稿样式：昵称 / 账户 / 密码 三行输入框）
        func formRow(_ text: String, _ y: CGFloat, _ placeholder: String) -> NSTextField {
            let lb = NSTextField(labelWithString: text)
            lb.frame = NSRect(x: 8, y: y + 3, width: 44, height: 16)
            lb.font = NSFont.systemFont(ofSize: 11)
            v.addSubview(lb)
            let f = NSTextField(frame: NSRect(x: 56, y: y, width: 240, height: 22))
            f.font = NSFont.systemFont(ofSize: 11)
            f.placeholderString = placeholder
            f.target = self
            f.action = #selector(inputCommitted)
            v.addSubview(f)
            return f
        }
        // 昵称框顶边 y=118，与标签区底边 y=128 正好间隔 10px
        nickField = formRow("昵称:", 96, "请输入昵称（可留空）")
        accField = formRow("账户:", 68, "请输入账户")
        passField = formRow("密码:", 40, "请输入密码")

        // 按钮行
        @discardableResult
        func smallButton(_ title: String, _ x: CGFloat, _ w: CGFloat, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: 16, width: w, height: 26)
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 11)
            v.addSubview(b)
            return b
        }
        smallButton("新增账户", 56, 92, #selector(addNewAccount))
        smallButton("保存修改", 152, 92, #selector(saveSelected))
        selectedLabel = NSTextField(labelWithString: "未选中")
        selectedLabel.frame = NSRect(x: 248, y: 23, width: 48, height: 14)
        selectedLabel.font = NSFont.systemFont(ofSize: 9)
        selectedLabel.textColor = .secondaryLabelColor
        selectedLabel.lineBreakMode = .byTruncatingTail
        v.addSubview(selectedLabel)

        // 提示/帮助（默认显示交互说明，有状态消息时临时替换）
        hintLabel = NSTextField(labelWithString: Self.helpText)
        hintLabel.frame = NSRect(x: 8, y: 0, width: 288, height: 14)
        hintLabel.font = NSFont.systemFont(ofSize: 9)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        v.addSubview(hintLabel)

        view = v
        rebuildTags()
        if ProcessInfo.processInfo.environment["NM_TEST_COPY"] == "1" { runCopySelfTest() }
    }

    // MARK: 标签构建

    private func displayName(_ acc: Account) -> String {
        if let n = acc.nickname, !n.isEmpty { return n }
        return acc.username
    }

    /// 单击标签：载入内容到三个输入框
    private func loadToInput(name: String) {
        guard let acc = store.accounts.first(where: { $0.username == name }) else { return }
        selectedUsername = name
        rebuildTags()
        nickField.stringValue = acc.nickname ?? ""
        accField.stringValue = acc.username
        passField.stringValue = store.password(for: acc.username) ?? ""
        showHint("已载入「\(displayName(acc))」，文本可选中复制；点「新增账户」则添加新账户", ok: true)
    }

    /// el-tag 同系配色（底色/边框/文字）
    private static let tagPalette: [(bg: NSColor, border: NSColor, text: NSColor)] = [
        (NSColor(hex: 0xECF5FF), NSColor(hex: 0xB3D8FF), NSColor(hex: 0x409EFF)),  // 蓝
        (NSColor(hex: 0xF0F9EB), NSColor(hex: 0xC2E7B0), NSColor(hex: 0x67C23A)),  // 绿
        (NSColor(hex: 0xFDF6EC), NSColor(hex: 0xF3D19E), NSColor(hex: 0xE6A23C)),  // 橙
        (NSColor(hex: 0xFEF0F0), NSColor(hex: 0xFBC4C4), NSColor(hex: 0xF56C6C)),  // 红
        (NSColor(hex: 0xF9F0FF), NSColor(hex: 0xDDBEF6), NSColor(hex: 0x9254DE)),  // 紫
        (NSColor(hex: 0xE8FFFB), NSColor(hex: 0xB5F1EC), NSColor(hex: 0x13C2C2)),  // 青
        (NSColor(hex: 0xFFF0F6), NSColor(hex: 0xFFD6E7), NSColor(hex: 0xEB2F96)),  // 品红
        (NSColor(hex: 0xF4F4F5), NSColor(hex: 0xDADDE2), NSColor(hex: 0x909399)),  // 灰
    ]

    /// 用户名稳定哈希 → 调色板起始下标
    private func stableIndex(_ s: String, modulus: Int) -> Int {
        var h = 0
        for ch in s.unicodeScalars { h = (h &* 31 &+ Int(ch.value)) & 0x7FFFFFFF }
        return h % modulus
    }

    /// 为每个账户分配互不相同的颜色下标（同账户集合同顺序时结果稳定）
    private func assignColorIndexes() -> [Int] {
        let m = Self.tagPalette.count
        var used = Set<Int>()
        var result: [Int] = []
        for acc in store.accounts {
            var idx = stableIndex(acc.username, modulus: m)
            while used.contains(idx) { idx = (idx + 1) % m }
            used.insert(idx)
            result.append(idx)
        }
        return result
    }

    private func rebuildTags() {
        flowView.subviews.forEach { $0.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: 11)
        let colorIdx = assignColorIndexes()
        let para: [NSAttributedString.Key: Any] = [.font: font]

        for (idx, acc) in store.accounts.enumerated() {
            let name = displayName(acc)
            let textW = ceil((name as NSString).size(withAttributes: para).width)
            let chip = TagChipView(
                text: name,
                colors: Self.tagPalette[colorIdx[idx]],
                selected: acc.username == selectedUsername,
                textWidth: textW)
            chip.onClickCount = { [weak self] clicks in
                self?.handleTagClick(index: idx, clicks: clicks)
            }
            chip.onRightClick = { [weak self] in
                self?.deleteTag(index: idx)
            }
            chip.frame = NSRect(x: 0, y: 0, width: textW + 18, height: 22)
            flowView.addSubview(chip)
        }
        flowView.needsLayout = true
        if let sel = selectedUsername, let acc = store.accounts.first(where: { $0.username == sel }) {
            selectedLabel.stringValue = "选中:\(displayName(acc))"
        } else {
            selectedLabel.stringValue = "未选中"
        }
    }

    // MARK: 标签交互（单击载入 / 双击用户名 / 三击密码）

    private func handleTagClick(index: Int, clicks: Int) {
        guard index < store.accounts.count else { return }
        let name = store.accounts[index].username

        if clicks >= 3 {
            pendingLoad?.cancel(); pendingCopy?.cancel()
            pendingLoad = nil; pendingCopy = nil
            copyPassword(name: name)
            return
        }
        if clicks == 2 {
            pendingLoad?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.copyUsername(name: name) }
            pendingCopy = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: w)
            return
        }
        // 单击：延迟 0.3 秒载入，双击/三击时取消，避免误载入
        let w = DispatchWorkItem { [weak self] in self?.loadToInput(name: name) }
        pendingLoad = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: w)
    }

    /// 右键标签：直接删除（已屏蔽默认右键菜单），并同步刷新标签与表单状态
    private func deleteTag(index: Int) {
        guard index < store.accounts.count else { return }
        let acc = store.accounts[index]
        let shown = displayName(acc)

        // 确认窗口
        let alert = NSAlert()
        alert.messageText = "删除账户「\(shown)」？"
        alert.informativeText = "用户名：\(acc.username)\n删除后不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            showHint("已取消删除", ok: true)
            return
        }

        _ = store.remove(username: acc.username)
        if selectedUsername == acc.username {
            selectedUsername = nil
            nickField.stringValue = ""; accField.stringValue = ""; passField.stringValue = ""
        }
        rebuildTags()
        showHint("已删除：\(shown)", ok: true)
    }

    // MARK: 表单按钮

    /// 按输入框内容新增账户（不受选中影响）
    @objc private func addNewAccount() {
        let (nickname, username, password, err) = parseInput()
        if let err = err { showHint(err, ok: false); return }
        if let err = store.add(username: username, password: password, nickname: nickname) {
            showHint(err, ok: false); return
        }
        selectedUsername = nil
        rebuildTags()
        nickField.stringValue = ""; accField.stringValue = ""; passField.stringValue = ""
        showHint("已新增：\(username)，输入框已清空", ok: true)
    }

    /// 保存修改到所选账户
    @objc private func saveSelected() {
        guard let sel = selectedUsername else {
            showHint("请先单击标签选中一个账户，再保存修改", ok: false); return
        }
        let (nickname, username, password, err) = parseInput()
        if let err = err { showHint(err, ok: false); return }
        var target = sel
        if username != sel {
            if let e = store.rename(sel, to: username) { showHint(e, ok: false); return }
            target = username
        }
        if let e = store.setNickname(username: target, nickname: nickname) {
            showHint(e, ok: false); return
        }
        if let e = store.setPassword(username: target, password: password) {
            showHint(e, ok: false); return
        }
        selectedUsername = target
        rebuildTags()
        showHint("已保存「\(target)」", ok: true)
    }

    /// 读取三个输入框（昵称可留空）
    private func parseInput() -> (nickname: String?, username: String, password: String, error: String?) {
        let nick = nickField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = accField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return (nil, "", "", "账户不能为空") }
        guard !password.isEmpty else { return (nil, "", "", "密码不能为空") }
        return (nick.isEmpty ? nil : nick, username, password, nil)
    }

    // MARK: 回车＝有选中则保存，无选中则新增

    private func copyUsername(name: String) {
        writePasteboard(name)
        showHint("已复制用户名：\(name)", ok: true)
    }

    private func copyPassword(name: String) {
        guard let pwd = store.password(for: name), !pwd.isEmpty else {
            showHint("「\(name)」的密码无法解密，请重新设置", ok: false)
            return
        }
        writePasteboard(pwd)
        showHint("已复制「\(name)」的密码", ok: true)
        // 90 秒后自动清空（若剪贴板仍是这段密码）
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if NSPasteboard.general.string(forType: .string) == pwd {
                NSPasteboard.general.clearContents()
            }
        }
    }

    private func writePasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: 输入框保存/新增

    @objc private func inputCommitted() {
        if selectedUsername != nil {
            saveSelected()
        } else {
            addNewAccount()
        }
    }

    // MARK: 复制自检（仅 NM_TEST_COPY=1，验证双击/三击时序）

    private func runCopySelfTest() {
        guard !store.accounts.isEmpty else { print("SELFTEST: 无账户"); return }
        print("SELFTEST: 账户数 \(store.accounts.count)，首个 \(store.accounts[0].username)")

        // 双击 → 应复制用户名
        handleTagClick(index: 0, clicks: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let v1 = NSPasteboard.general.string(forType: .string) ?? "nil"
            print("SELFTEST 双击结果: [\(v1)]  期望用户名 → \(v1 == self.store.accounts[0].username ? "PASS" : "FAIL")")

            // 三击 → 应复制密码（并取消待执行的双击动作）
            self.handleTagClick(index: 0, clicks: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.handleTagClick(index: 0, clicks: 3)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let v2 = NSPasteboard.general.string(forType: .string) ?? "nil"
                    let expect = self.store.password(for: self.store.accounts[0].username) ?? "nil"
                    print("SELFTEST 三击结果: [\(v2)]  期望密码 → \(v2 == expect ? "PASS" : "FAIL")")
                    print("SELFTEST 完成")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: 状态提示

    private func showHint(_ text: String, ok: Bool) {
        hintResetWork?.cancel()
        hintLabel.stringValue = text
        hintLabel.textColor = ok ? .systemGreen : .systemRed
        let work = DispatchWorkItem { [weak self] in
            self?.hintLabel.stringValue = Self.helpText
            self?.hintLabel.textColor = .tertiaryLabelColor
        }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
