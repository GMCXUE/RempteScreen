#!/bin/bash
# 给 RemoteScreen.app 注入麦克风用途声明（无此声明 macOS 会静默拒绝麦克风，
# 而系统音频采集的数据泵依赖麦克风设备 —— 没有它音频帧发不出去）。
# 用法: patch-macos-plist.sh /path/to/RemoteScreen.app
APP="$1"
/usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string "RemoteScreen 投送屏幕时需要采集系统音频，此授权仅用于音频传输，不会使用麦克风收音。"' "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription "RemoteScreen 投送屏幕时需要采集系统音频，此授权仅用于音频传输，不会使用麦克风收音。"' "$APP/Contents/Info.plist"
echo "Info.plist 已注入麦克风声明"
