#!/bin/zsh
# NetMonitor 一键构建脚本
set -e
cd "$(dirname "$0")"

mkdir -p NetMonitor.app/Contents/MacOS
swiftc -O -swift-version 5 -framework AppKit \
  -o NetMonitor.app/Contents/MacOS/NetMonitor main.swift Accounts.swift
cp Info.plist NetMonitor.app/Contents/Info.plist
codesign --force -s - NetMonitor.app

echo "构建完成: $(pwd)/NetMonitor.app"
