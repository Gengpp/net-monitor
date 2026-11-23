#!/bin/zsh
# NetMonitor 一键构建脚本
set -e
cd "$(dirname "$0")"

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
