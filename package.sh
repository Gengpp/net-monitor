#!/bin/zsh
# ============================================================
# NetMonitor 打包脚本
#
# 用法:
#   ./package.sh             构建 + 生成发布包（zip + DMG）到 release/
#   ./package.sh install     构建 + 安装到 /Applications
#   ./package.sh clean       清理 release/ 与构建产物
#
# 发布物:
#   release/NetMonitor-<版本>.zip    解压即用的 .app
#   release/NetMonitor-<版本>.dmg    拖拽安装镜像（含 Applications 链接）
#   release/SHA256SUMS.txt           校验和
# ============================================================
set -e
cd "$(dirname "$0")"

APP="NetMonitor.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
OUT="release"
STAGING="$OUT/dmg-staging"

# ---------- 子命令 ----------

if [[ "$1" == "clean" ]]; then
    rm -rf "$OUT" "$APP"
    echo "已清理 release/ 与 $APP"
    exit 0
fi

# ---------- 构建 ----------

echo "==> 构建 NetMonitor v$VERSION ..."
./build.sh

# ---------- 安装模式 ----------

if [[ "$1" == "install" ]]; then
    echo "==> 安装到 /Applications ..."
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "✅ 已安装：/Applications/$APP（可在 启动台/聚焦搜索 中打开）"
    exit 0
fi

# ---------- 打发布包 ----------

echo "==> 打包发布物 ..."
rm -rf "$OUT" "$STAGING"
mkdir -p "$OUT" "$STAGING"

# 1) zip：解压即用
ditto -c -k --keepParent "$APP" "$OUT/NetMonitor-$VERSION.zip"

# 2) DMG：拖拽安装镜像（app + Applications 软链）
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "NetMonitor $VERSION" \
    -srcfolder "$STAGING" -format UDZO -ov -quiet \
    "$OUT/NetMonitor-$VERSION.dmg"
rm -rf "$STAGING"

# 3) 校验和
( cd "$OUT" && shasum -a 256 "NetMonitor-$VERSION.zip" "NetMonitor-$VERSION.dmg" > SHA256SUMS.txt )

echo ""
echo "✅ 打包完成 v$VERSION："
for f in "$OUT"/*; do
    printf "   %-28s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1 | tr -d ' ')"
done
echo ""
echo "提示："
echo "  · 本机自用：双击 DMG 拖入 Applications，或 ./package.sh install"
echo "  · 分发给他人：由于是 ad-hoc 签名，对方首次打开需右键 → 打开（绕过 Gatekeeper）"
