# NetMonitor — 轻量级 macOS 菜单栏网速监控

原生 Swift + AppKit，零第三方依赖，可执行文件约 114 KB。

## 功能

| 功能 | 说明 |
|------|------|
| 菜单栏实时速率 | 项显示 `↓下行 ↑上行`，等宽数字体防抖动 |
| 主窗口（点击菜单栏直接打开） | **账户本**（默认页）与**流量监控**两个页签，再点一次菜单栏收起 |
| 账户本 | 配置 N 个账户（新增 / 改名 / 改密 / 删除）；**双击行复制用户名，三击行复制密码**；复制密码 90 秒后自动清空剪贴板 |
| 流量监控页 | 大号实时速率（蓝=下载/绿=上传）、120 秒滚动图表、自启动累计流量、活动接口数 |
| 默认账户 | 首次运行自动内置 `gpp / 6866788` |
| 安全存储 | 账户存于 `~/Library/Application Support/NetMonitor/accounts.json`，密码为**机器绑定 AES-GCM 加密**（取本机 host UUID 派生密钥），文件不含明文，权限 600；⚠️ 账户文件拷到其他电脑无法解密 |
| 显示模式 | 菜单栏文字模式（默认）或 SF Symbol 图标模式，选择持久化到 UserDefaults |

## 技术要点

- **采集**：`getifaddrs` 读取网卡字节计数，每 1 秒取差值计算速率。**macOS 上统计数据只挂在 `AF_LINK` 条目**（`AF_INET`/`AF_INET6` 条目的 `ifa_data` 为 NULL），必须按 AF_LINK 过滤并按接口名去重；排除 `lo0`/`awdl`/`llw`/`bridge`/`ap` 虚拟接口避免重复计数；计数器回绕按 0 处理。VPN（utun）流量会被计入。
- **图表**：纯 `NSBezierPath` 手绘半透明面积图 + 描边，右侧对齐向左滚动，上下行共用动态量程（下限 10 KB/s）。
- **常驻**：`LSUIElement=true` 不占 Dock，`NSApplication.accessory` 激活策略；NSPopover transient 行为，点外部自动收起。
- **已知修复**：NSPopover 的 contentViewController 懒加载导致首次 tick 时子视图为 nil 崩溃（SIGILL），已在 `update()` 里先触发 `_ = view` 强制加载。

## 构建与运行

```bash
./build.sh                      # 编译 + 打包 .app + ad-hoc 签名
open NetMonitor.app             # 启动（菜单栏出现 ↓0B ↑0B）
```

## 发布打包

```bash
./package.sh                    # 构建 + 生成 release/（zip + DMG + SHA256SUMS.txt）
./package.sh install            # 构建 + 一键安装到 /Applications
./package.sh clean              # 清理发布物与构建产物
```

- `NetMonitor-<版本>.zip`：解压即用的 .app
- `NetMonitor-<版本>.dmg`：拖拽安装镜像（内含 Applications 软链）
- 版本号取自 `Info.plist` 的 `CFBundleShortVersionString`
- 分发给他人：ad-hoc 签名，对方首次打开需右键 → 打开绕过 Gatekeeper

## 验收记录（2026-11-16）

| 项 | 结果 |
|----|------|
| 编译 | ✅ swiftc 6.1.2（CLT），二进制 114 KB |
| 启动 | ✅ `open` 托管运行，进程稳定 |
| 菜单栏显示 | ✅ 截图实测显示 `↓0 B ↑0 B`（空闲态） |
| 主面板弹窗 | ⏳ 自动化点击需辅助功能权限未验证，请手动点击菜单栏项确认 |

### 2026-11-17 修复：实时速率恒为 0 B

- **根因**：首版只统计 `AF_INET`/`AF_INET6` 条目，但 macOS 的 `if_data` 字节计数只挂在 `AF_LINK` 条目上，前者 `ifa_data` 全为 NULL → 永远采到 0。
- **修复**：改为按 `AF_LINK` 过滤 + 接口名去重取数。
- **实测**：下载 40 MB 期间菜单栏显示 `↓7.8 MB ↑85.9 KB`，结束后回落 `↓5.0 KB ↑2.0 KB`，实时监控正常。

### 2026-11-17 新增：登录窗口 + N 个可配置账户

- **架构**：新增 `Accounts.swift`（AccountStore + LoginWindowController + AccountManagerWindowController），build.sh 同时编译两个源文件。
- **存储逻辑测试**（隔离目录 CLI 测试全部通过）：默认账户验证 ✅、错误密码拒绝 ✅、新增/重名/空名拦截 ✅、改密后旧密码失效 ✅、删除后至少保留 1 个 ✅、JSON 中无明文密码 ✅。
- **UI 截图验证**：登录窗口与账户管理窗口布局正常（标题/输入框/按钮/提示齐全，无重叠错位）。
- **调试钩子**：环境变量 `NM_SHOW_LOGIN=1` 启动即弹登录窗；`NM_SHOW_ACCOUNTS=1` 直接打开账户管理（跳过登录），便于自动化截图验证。
- **交互门禁**：菜单栏速率常显；点开主面板、账户管理需登录；面板底部「锁定」或右键「锁定」可重新锁定；右键「登录…」可直接唤起登录窗。

### 2026-11-17 改版：去掉登录窗口，改为「账户本」直开

- **需求**：不要登录窗口，点菜单栏直接进用户管理；双击行复制用户名、三击行复制密码。
- **架构调整**：删除 LoginWindowController 与登录门禁；主窗口改为单窗口 + 顶部分段控件（账户本 / 流量监控），点菜单栏默认打开账户本页。
- **存储变更**：可复制密码 ⇒ 存储必须可逆，由「加盐哈希」改为「机器绑定 AES-GCM 加密」（密钥由 gethostuuid 的本机 ID 派生）；检测到旧版哈希结构时自动迁移并重建 `gpp/6866788`。
- **复制时序**：三击会先触发一次 clickCount=2 事件，用 0.3 秒延迟 + DispatchWorkItem 取消机制区分双击与三击。
- **验证**：
  - 存储层（隔离 CLI 测试）：加密还原 ✅（含中文密码）、重启解密 ✅、改密/重命名/删除 ✅、JSON 无明文 ✅、旧版迁移 ✅
  - 复制自检（`NM_TEST_COPY=1`）：双击复制用户名 PASS、三击复制密码 PASS
  - UI 截图（按窗口 ID 截取，穿透遮挡）：账户本页、流量监控页布局均正常
- **调试钩子**：`NM_SHOW_WINDOW=1` 启动即开窗口（`NM_TAB=monitor` 切流量页）、`NM_TEST_COPY=1` 运行复制自检。
