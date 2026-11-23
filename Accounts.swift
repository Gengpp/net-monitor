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

// MARK: - 支持多击事件的标签按钮

final class TagButton: NSButton {
    /// (点击次数)
    var onCountedClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onCountedClick?(event.clickCount)
    }
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
    private var inputField: NSTextField!
    private var selectedLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var pendingLoad: DispatchWorkItem?
    private var pendingCopy: DispatchWorkItem?
    private var hintResetWork: DispatchWorkItem?
    private var selectedUsername: String?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 304, height: 232))

        // 标签流式区（顶部）
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 126, width: 288, height: 98))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let flow = TagFlowView(frame: NSRect(x: 0, y: 0, width: 286, height: 96))
        flow.autoresizingMask = [.width]
        scroll.documentView = flow
        v.addSubview(scroll)
        flowView = flow

        // 内容输入框（标签下方，可选中复制）
        inputField = NSTextField(frame: NSRect(x: 8, y: 98, width: 288, height: 22))
        inputField.placeholderString = "昵称:用户名:密码 或 用户名:密码"
        inputField.font = NSFont.systemFont(ofSize: 11)
        inputField.target = self
        inputField.action = #selector(inputCommitted)
        v.addSubview(inputField)

        // 操作按钮行：复制 / 新增 / 保存修改
        func smallButton(_ title: String, _ x: CGFloat, _ w: CGFloat, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: 72, width: w, height: 22)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            v.addSubview(b)
            return b
        }
        smallButton("复制", 8, 56, #selector(copyInput))
        smallButton("新增", 68, 56, #selector(addNewAccount))
        smallButton("保存修改", 128, 80, #selector(saveSelected))
        selectedLabel = NSTextField(labelWithString: "")
        selectedLabel.frame = NSRect(x: 212, y: 76, width: 84, height: 14)
        selectedLabel.font = NSFont.systemFont(ofSize: 10)
        selectedLabel.textColor = .secondaryLabelColor
        selectedLabel.lineBreakMode = .byTruncatingTail
        v.addSubview(selectedLabel)

        // 状态提示
        hintLabel = NSTextField(labelWithString: "")
        hintLabel.frame = NSRect(x: 8, y: 54, width: 288, height: 16)
        hintLabel.font = NSFont.systemFont(ofSize: 10)
        v.addSubview(hintLabel)

        // 交互说明
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let footer = NSTextField(wrappingLabelWithString:
            "单击标签＝载入内容 · 双击＝复制用户名 · 三击＝复制密码（90 秒后清剪贴板）\n复制＝复制输入框全部内容 · 新增＝按输入框内容新增账户\n保存修改＝更新所选标签 · 标签 ✕＝删除 · v\(ver)")
        footer.frame = NSRect(x: 8, y: 4, width: 288, height: 46)
        footer.font = NSFont.systemFont(ofSize: 9)
        footer.textColor = .tertiaryLabelColor
        v.addSubview(footer)

        view = v
        rebuildTags()
        if ProcessInfo.processInfo.environment["NM_TEST_COPY"] == "1" { runCopySelfTest() }
    }

    // MARK: 标签构建

    private func displayName(_ acc: Account) -> String {
        if let n = acc.nickname, !n.isEmpty { return n }
        return acc.username
    }

    /// 输入框展示的账户内容
    private func contentText(_ acc: Account) -> String {
        let pwd = store.password(for: acc.username) ?? ""
        if let n = acc.nickname, !n.isEmpty {
            return "\(n):\(acc.username):\(pwd)"
        }
        return "\(acc.username):\(pwd)"
    }

    private func rebuildTags() {
        flowView.subviews.forEach { $0.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: 11)

        for (idx, acc) in store.accounts.enumerated() {
            let name = displayName(acc)
            let container = NSView()

            let btn = TagButton(title: name, target: self, action: #selector(tagMainClicked(_:)))
            btn.font = font
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.lineBreakMode = .byTruncatingTail
            if acc.username == selectedUsername {
                btn.attributedTitle = NSAttributedString(
                    string: name,
                    attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                 .foregroundColor: NSColor.controlAccentColor])
            }
            btn.onCountedClick = { [weak self] clicks in
                self?.handleTagClick(index: idx, clicks: clicks)
            }
            let nameW = max(ceil(btn.intrinsicContentSize.width) + 4, 40)
            btn.frame = NSRect(x: 0, y: 0, width: nameW, height: 20)
            container.addSubview(btn)

            let del = NSButton(title: "✕", target: self, action: #selector(tagDeleteClicked(_:)))
            del.isBordered = false
            del.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            del.controlSize = .small
            del.frame = NSRect(x: nameW, y: 3, width: 14, height: 14)
            container.addSubview(del)

            container.frame = NSRect(x: 0, y: 0, width: nameW + 14, height: 20)
            flowView.addSubview(container)
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

    @objc private func tagMainClicked(_ sender: NSButton) {
        // 点击逻辑统一走 onCountedClick（带 clickCount）
    }

    @objc private func tagDeleteClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < store.accounts.count else { return }
        let name = store.accounts[idx].username
        let alert = NSAlert()
        alert.messageText = "删除账户「\(displayName(store.accounts[idx]))」？"
        alert.informativeText = "用户名：\(name)\n删除后不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            _ = store.remove(username: name)
            if selectedUsername == name {
                selectedUsername = nil
                inputField.stringValue = ""
            }
            rebuildTags()
            showHint("已删除：\(name)", ok: true)
        }
    }

    private func loadToInput(name: String) {
        guard let acc = store.accounts.first(where: { $0.username == name }) else { return }
        selectedUsername = name
        rebuildTags()
        inputField.stringValue = contentText(acc)
        selectedLabel.stringValue = "选中:\(displayName(acc))"
        showHint("已载入「\(displayName(acc))」，可选中复制或改后保存；点「新增」则添加新账户", ok: true)
    }

    // MARK: 输入框按钮

    /// 复制输入框全部内容
    @objc private func copyInput() {
        let text = inputField.stringValue
        guard !text.isEmpty else { showHint("输入框为空，无可复制内容", ok: false); return }
        writePasteboard(text)
        showHint("已复制输入框内容", ok: true)
    }

    /// 按输入框内容新增账户（不受选中影响）
    @objc private func addNewAccount() {
        let (nickname, username, password, err) = parseInput()
        if let err = err { showHint(err, ok: false); return }
        if let err = store.add(username: username, password: password, nickname: nickname) {
            showHint(err, ok: false); return
        }
        selectedUsername = username
        rebuildTags()
        showHint("已新增：\(username)", ok: true)
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

    /// 解析输入框：昵称:用户名:密码 或 用户名:密码
    private func parseInput() -> (nickname: String?, username: String, password: String, error: String?) {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "", "", "输入为空") }
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 2:
            return (nil, parts[0], parts[1], nil)
        case 3:
            let nick = parts[0].isEmpty ? nil : parts[0]
            return (nick, parts[1], parts[2], nil)
        default:
            return (nil, "", "", "格式：昵称:用户名:密码 或 用户名:密码")
        }
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
            self?.hintLabel.stringValue = ""
        }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
