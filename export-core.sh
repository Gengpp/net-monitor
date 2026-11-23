#!/bin/zsh
# NetMonitor 核心代码导出脚本
# 将核心源码/脚本/文档打包为 zip，输出到项目目录的上一层
# 用法：./export-core.sh
set -e
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "0.0.0")
OUT_NAME="net-monitor-core-v${VERSION}.zip"
OUT_PATH="$(dirname "$(pwd)")/$OUT_NAME"

# 核心代码清单（不含 .app / release / iconset 中间产物）
CORE_FILES=(main.swift Accounts.swift Info.plist build.sh package.sh export-core.sh \
            .gitignore .last-source-hash docs/README.md icon/AppIcon.icns)
for png in icon/*.png; do
  [ -f "$png" ] && CORE_FILES+=("$png")
done

# 仅打包实际存在的文件
EXISTING=()
for f in "${CORE_FILES[@]}"; do
  [ -f "$f" ] && EXISTING+=("$f")
done

rm -f "$OUT_PATH"
zip -q "$OUT_PATH" "${EXISTING[@]}"

echo "✅ 核心代码已打包：$OUT_PATH"
echo "   版本：v$VERSION"
ls -lh "$OUT_PATH" | awk '{print "   大小："$5}'
echo "   内容："
unzip -l "$OUT_PATH" | awk 'NR>3 && $4 != "" {print "     - "$4}' | head -20
