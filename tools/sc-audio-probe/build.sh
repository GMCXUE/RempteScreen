#!/usr/bin/env bash
# 构建采集能力探针，产出 .app 包。
# 打成 .app 是为了让系统的「屏幕录制」权限记在探针自己名下，
# 而不是记到终端或调用方身上 —— 正式版采集 App 也是这个形态。
# 仅需 Command Line Tools，不需要完整 Xcode。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="RemoteScreen 采集探针"
APP="$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/sc-audio-probe" main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>sc-audio-probe</string>
    <key>CFBundleIdentifier</key><string>com.remotescreen.scprobe</string>
    <key>CFBundleName</key><string>RemoteScreen 采集探针</string>
    <key>CFBundleDisplayName</key><string>RemoteScreen 采集探针</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 临时签名。稳定的签名标识能让系统记住授权，避免每次运行都要重新授权。
codesign --force --sign - --identifier com.remotescreen.scprobe "$APP" 2>/dev/null \
    || echo "提示：临时签名失败，不影响功能，但可能每次都需要重新授权。"

echo "构建完成：$(pwd)/$APP"
echo "运行：open \"$APP_NAME.app\""
