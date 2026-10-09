# 应用图标生成器

图标是**代码画的**（Swift + CoreGraphics），不依赖设计稿也不依赖第三方库，
改一行参数就能重新生成全套尺寸，两端保持一致。

## 设计

蓝色渐变圆角底 + 白色屏幕轮廓 + 左下角投屏信号（实心点 + 两道弧），
与客户端主题色 `#3B82F6 → #1D63D2` 一致。

## 用法

```bash
swiftc -O make-icon.swift -o make-icon
./make-icon 1024 /tmp/icon.png      # 生成指定尺寸的 PNG
```

## 需要更新的位置

| 位置 | 文件 |
| --- | --- |
| macOS 桌面端 | `apps/desktop-rs/app/src-tauri/icons/`（icon.icns / icon.png / 32x32.png / 128x128.png / 128x128@2x.png / icon.ico） |
| Android 移动端 | `apps/flutter_client/android/app/src/main/res/mipmap-*/ic_launcher.png`（48 / 72 / 96 / 144 / 192） |

macOS 的 `.icns` 用 `iconutil -c icns <name>.iconset -o icon.icns` 打包；
Windows 的 `.ico` 直接内嵌 PNG 即可（无需第三方库）。
