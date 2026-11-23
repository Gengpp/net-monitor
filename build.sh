#!/bin/zsh
# NetMonitor 一键构建脚本
# 源码变化时：自动升级补丁版本号 → 自动 commit + push 到 GitHub → 编译打包 .app
set -e
cd "$(dirname "$0")"

# ---------- 自动版本升级 + 自动提交推送（仅当核心源码变化时） ----------
HASH_FILES=(main.swift Accounts.swift Info.plist build.sh package.sh export-core.sh)
SRC_HASH=$(cat "${HASH_FILES[@]}" 2>/dev/null | md5)
HASH_FILE=".last-source-hash"
LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

if [ "$SRC_HASH" != "$LAST_HASH" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0.0")
  MAJOR=${VERSION%%.*}
  REST=${VERSION#*.}
  MINOR=${REST%%.*}
  PATCH=${REST#*.}
  NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" Info.plist
  echo "$SRC_HASH" > "$HASH_FILE"

  if git rev-parse --git-dir >/dev/null 2>&1; then
    git add -A
    git commit -m "chore(release): v$NEW_VERSION（源码变更自动升级版本号）" >/dev/null 2>&1 || true
    if git push >/dev/null 2>&1; then
      echo "✅ v$NEW_VERSION 已自动提交并推送到 GitHub"
    else
      echo "⚠️ v$NEW_VERSION 已本地提交，推送失败（稍后可手动 git push）"
    fi
  fi
fi

# ---------- 编译 ----------
mkdir -p NetMonitor.app/Contents/MacOS
swiftc -O -swift-version 5 -framework AppKit \
  -o NetMonitor.app/Contents/MacOS/NetMonitor main.swift Accounts.swift
cp Info.plist NetMonitor.app/Contents/Info.plist
mkdir -p NetMonitor.app/Contents/Resources
if [ -f icon/AppIcon.icns ]; then
  cp icon/AppIcon.icns NetMonitor.app/Contents/Resources/AppIcon.icns
  /usr/bin/touch NetMonitor.app   # 让 Finder/Dock 刷新图标缓存
fi
codesign --force -s - NetMonitor.app

echo "构建完成: $(pwd)/NetMonitor.app"
