#!/usr/bin/env bash
# 构建 Android 调试版 APK。
#
# 需要 JDK 17 与 Android SDK。如果本机没有，脚本会提示缺什么。
# 产物：app/build/outputs/apk/debug/app-debug.apk

set -euo pipefail

cd "$(dirname "$0")"

# ---- 工具链定位 ----------------------------------------------------------

# JDK：优先用环境变量，其次找常见的安装位置
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME}/bin/java" ]; then
  for candidate in \
    "$HOME/android-build"/jdk-17*/Contents/Home \
    "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home" \
    "$(command -v /usr/libexec/java_home >/dev/null 2>&1 && /usr/libexec/java_home -v 17 2>/dev/null || true)"
  do
    if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi

if [ -z "${JAVA_HOME:-}" ]; then
  echo "找不到 JDK 17。安装方式：brew install --cask temurin@17" >&2
  exit 1
fi

JAVA_VERSION="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')"
if [ "${JAVA_VERSION:-0}" -lt 17 ]; then
  echo "需要 JDK 17 及以上，当前是 $JAVA_VERSION。Android Gradle 插件 8.x 不支持更低的版本。" >&2
  exit 1
fi

# Android SDK
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ ! -d "$ANDROID_HOME/platforms" ]; then
  echo "找不到 Android SDK（$ANDROID_HOME）。" >&2
  echo "安装：自 https://developer.android.com/studio#command-tools 下载命令行工具，然后用 sdkmanager 装 platforms;android-34 与 build-tools;34.0.0" >&2
  exit 1
fi

# Gradle：优先用系统安装的，其次用本地解压的
if command -v gradle >/dev/null 2>&1; then
  GRADLE="gradle"
elif [ -x "$HOME/android-build/gradle-8.7/bin/gradle" ]; then
  GRADLE="$HOME/android-build/gradle-8.7/bin/gradle"
else
  echo "找不到 Gradle。可以从 https://services.gradle.org/distributions/ 下载，或 brew install gradle" >&2
  exit 1
fi

# 告诉 Gradle SDK 在哪
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > local.properties

echo "JDK      $JAVA_HOME"
echo "SDK      $ANDROID_HOME"
echo "Gradle   $GRADLE"
echo ""

"$GRADLE" assembleDebug --no-daemon --console=plain

APK="app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "构建完成：$(pwd)/$APK"
echo "体积：$(du -h "$APK" | cut -f1)"
