// Accounts.swift — 账户存储（机器绑定 AES-GCM 加密）+ 账户列表面板
// 支持双击复制用户名、三击复制密码

import AppKit
import CryptoKit
import Darwin

// MARK: - 账户模型与存储

struct Account: Codable {
    var username: String
    var secret: String   // base64(AES-GCM 组合格式)，非明文
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
    func add(username: String, password: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "用户名不能为空" }
        guard !name.contains(" ") else { return "用户名不能包含空格" }
        guard !exists(name) else { return "用户名已存在" }
        guard !password.isEmpty else { return "密码不能为空" }
        accounts.append(Account(username: name, secret: Self.seal(password)))
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

// MARK: - 支持多击事件的表格

final class AccountTableView: NSTableView {
    /// (行号, 点击次数)
    var onRowClick: ((Int, Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        super.mouseDown(with: event)
        if clickedRow >= 0 {
            onRowClick?(clickedRow, event.clickCount)
        }
    }
}

// MARK: - 账户面板

final class AccountPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let store = AccountStore.shared
    private var tableView: AccountTableView!
    private var userField: NSTextField!
    private var passField: NSSecureTextField!
    private var confirmField: NSSecureTextField!
    private var hintLabel: NSTextField!
    private var pendingCopy: DispatchWorkItem?
    private var hintResetWork: DispatchWorkItem?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 470))

        func label(_ rect: NSRect, _ text: String, size: CGFloat,
                   weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let tf = NSTextField(labelWithString: text)
            tf.frame = rect
            tf.font = NSFont.systemFont(ofSize: size, weight: weight)
            tf.textColor = color
            v.addSubview(tf)
            return tf
        }

        _ = label(NSRect(x: 24, y: 434, width: 220, height: 16), "账户列表", size: 12, weight: .semibold)

        // 列表
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 100, width: 220, height: 322))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let table = AccountTableView()
        table.headerView = nil
        table.rowHeight = 26
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.width = 196
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.onRowClick = { [weak self] row, clicks in
            self?.handleRowClick(row: row, clicks: clicks)
        }
        scroll.documentView = table
        v.addSubview(scroll)
        tableView = table

        let delBtn = NSButton(title: "删除所选", target: self, action: #selector(deleteSelected))
        delBtn.frame = NSRect(x: 24, y: 64, width: 96, height: 26)
        delBtn.bezelStyle = .rounded
        delBtn.controlSize = .small
        v.addSubview(delBtn)

        // 分隔线
        let sep = NSBox(frame: NSRect(x: 264, y: 64, width: 1, height: 386))
        sep.boxType = .separator
        v.addSubview(sep)

        // 表单
        _ = label(NSRect(x: 288, y: 404, width: 60, height: 16), "用户名", size: 12)
        userField = NSTextField(frame: NSRect(x: 352, y: 400, width: 224, height: 24))
        userField.placeholderString = "新用户名"
        v.addSubview(userField)

        _ = label(NSRect(x: 288, y: 368, width: 60, height: 16), "密　码", size: 12)
        passField = NSSecureTextField(frame: NSRect(x: 352, y: 364, width: 224, height: 24))
        passField.placeholderString = "密码（留空则不改）"
        v.addSubview(passField)

        _ = label(NSRect(x: 288, y: 332, width: 60, height: 16), "确认密码", size: 12)
        confirmField = NSSecureTextField(frame: NSRect(x: 352, y: 328, width: 224, height: 24))
        confirmField.placeholderString = "再次输入密码"
        v.addSubview(confirmField)

        let addBtn = NSButton(title: "新增账户", target: self, action: #selector(addAccount))
        addBtn.frame = NSRect(x: 288, y: 288, width: 104, height: 28)
        addBtn.bezelStyle = .rounded
        v.addSubview(addBtn)

        let saveBtn = NSButton(title: "保存修改（所选）", target: self, action: #selector(saveSelected))
        saveBtn.frame = NSRect(x: 400, y: 288, width: 176, height: 28)
        saveBtn.bezelStyle = .rounded
        v.addSubview(saveBtn)

        hintLabel = label(NSRect(x: 288, y: 200, width: 288, height: 72), "", size: 11, color: .secondaryLabelColor)
        hintLabel.maximumNumberOfLines = 4
        hintLabel.lineBreakMode = .byWordWrapping

        _ = label(NSRect(x: 24, y: 28, width: 552, height: 30),
                  "双击账户行＝复制用户名　·　三击账户行＝复制密码（90 秒后自动清空剪贴板）\n密码以机器绑定 AES-GCM 加密保存在 accounts.json，文件中不含明文",
                  size: 10, color: .tertiaryLabelColor)

        view = v
        tableView.reloadData()
        if !store.accounts.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if ProcessInfo.processInfo.environment["NM_TEST_COPY"] == "1" { runCopySelfTest() }
    }

    // MARK: 复制自检（仅 NM_TEST_COPY=1 时执行，用于验证双击/三击时序）
    private func runCopySelfTest() {
        guard !store.accounts.isEmpty else { print("SELFTEST: 无账户"); return }
        print("SELFTEST: 账户数 \(store.accounts.count)，首行 \(store.accounts[0].username)")

        // 双击 → 应复制用户名
        handleRowClick(row: 0, clicks: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let v1 = NSPasteboard.general.string(forType: .string) ?? "nil"
            print("SELFTEST 双击结果: [\(v1)]  期望用户名 → \(v1 == self.store.accounts[0].username ? "PASS" : "FAIL")")

            // 三击 → 应复制密码（并取消待执行的双击动作）
            self.handleRowClick(row: 0, clicks: 2)   // 先制造待执行双击
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.handleRowClick(row: 0, clicks: 3)
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

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { store.accounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < store.accounts.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.frame = NSRect(x: 8, y: 3, width: 190, height: 18)
            tf.font = NSFont.systemFont(ofSize: 13)
            cell.addSubview(tf)
            cell.textField = tf
        }
        cell.textField?.stringValue = store.accounts[row].username
        return cell
    }

    private var selectedUsername: String? {
        let row = tableView.selectedRow
        guard row >= 0, row < store.accounts.count else { return nil }
        return store.accounts[row].username
    }

    // MARK: 复制交互

    private func handleRowClick(row: Int, clicks: Int) {
        guard row < store.accounts.count else { return }
        if clicks >= 3 {
            pendingCopy?.cancel()
            pendingCopy = nil
            copyPassword(row: row)
            return
        }
        if clicks == 2 {
            // 延迟 0.3 秒等三击判定，避免双击与三击互相干扰
            let work = DispatchWorkItem { [weak self] in
                self?.copyUsername(row: row)
            }
            pendingCopy = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
        }
    }

    private func copyUsername(row: Int) {
        let name = store.accounts[row].username
        writePasteboard(name)
        showHint("已复制用户名：\(name)", ok: true)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func copyPassword(row: Int) {
        let name = store.accounts[row].username
        guard let pwd = store.password(for: name), !pwd.isEmpty else {
            showHint("「\(name)」的密码无法解密，请重新设置", ok: false)
            return
        }
        writePasteboard(pwd)
        showHint("已复制「\(name)」的密码", ok: true)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

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

    // MARK: 行为

    @objc private func addAccount() {
        guard passField.stringValue == confirmField.stringValue else {
            showHint("两次输入的密码不一致", ok: false); return
        }
        if let err = store.add(username: userField.stringValue, password: passField.stringValue) {
            showHint(err, ok: false); return
        }
        let name = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        userField.stringValue = ""; passField.stringValue = ""; confirmField.stringValue = ""
        tableView.reloadData()
        if let idx = store.usernames.firstIndex(of: name) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        showHint("已新增账户：\(name)", ok: true)
    }

    @objc private func saveSelected() {
        guard let name = selectedUsername else {
            showHint("请先在左侧选择一个账户", ok: false); return
        }
        guard passField.stringValue == confirmField.stringValue else {
            showHint("两次输入的密码不一致", ok: false); return
        }
        let newName = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty, newName != name {
            if let err = store.rename(name, to: newName) {
                showHint(err, ok: false); return
            }
        }
        let target = newName.isEmpty ? name : newName
        var changed = ["用户名"]
        if !passField.stringValue.isEmpty {
            if let err = store.setPassword(username: target, password: passField.stringValue) {
                showHint(err, ok: false); return
            }
            changed.append("密码")
        }
        passField.stringValue = ""; confirmField.stringValue = ""
        tableView.reloadData()
        if let idx = store.usernames.firstIndex(of: target) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        showHint("已保存「\(target)」的\(changed.joined(separator: "与"))", ok: true)
    }

    @objc private func deleteSelected() {
        guard let name = selectedUsername else {
            showHint("请先在左侧选择一个账户", ok: false); return
        }
        let alert = NSAlert()
        alert.messageText = "删除账户「\(name)」？"
        alert.informativeText = "删除后不可恢复。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            _ = store.remove(username: name)
            tableView.reloadData()
            showHint("已删除账户：\(name)", ok: true)
        }
    }
}
