#!/usr/bin/env python3
"""生成应用图标。

环境里没有 Pillow 之类的图像库，所以直接按 PNG 规范写字节。
用 4 倍超采样再降采样来得到平滑边缘 —— 否则圆角会全是锯齿。

用法：python3 scripts/make-icons.py
产出：src/renderer/icons/*.png
"""

import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "src" / "renderer" / "icons"

# 配色与界面保持一致
BACKGROUND = (76, 141, 255)   # --accent
FOREGROUND = (255, 255, 255)

SUPERSAMPLE = 4

# 图标形状，用 0~1 的相对坐标描述，便于任意尺寸复用
SHAPES = [
    # 圆角底板
    ("rounded", 0.00, 0.00, 1.00, 1.00, 0.22, BACKGROUND),
    # 屏幕
    ("rounded", 0.21, 0.25, 0.58, 0.36, 0.055, FOREGROUND),
    # 支架
    ("rounded", 0.44, 0.63, 0.12, 0.09, 0.01, FOREGROUND),
    # 底座
    ("rounded", 0.33, 0.74, 0.34, 0.07, 0.035, FOREGROUND),
]


def inside_rounded(x, y, left, top, width, height, radius):
    """判断点是否落在圆角矩形内。"""
    right = left + width
    bottom = top + height
    if x < left or x >= right or y < top or y >= bottom:
        return False

    r = min(radius, width / 2, height / 2)
    if r <= 0:
        return True

    # 只有落在四个角的方形区域内才需要做圆角判断
    cx = left + r if x < left + r else (right - r if x > right - r else x)
    cy = top + r if y < top + r else (bottom - r if y > bottom - r else y)
    if cx == x and cy == y:
        return True
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def render(size):
    """渲染一张 size×size 的 RGBA 图。"""
    big = size * SUPERSAMPLE
    # 先在超采样分辨率上逐点判断覆盖，再按块平均得到最终颜色
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            acc_r = acc_g = acc_b = acc_a = 0
            for sy in range(SUPERSAMPLE):
                ny = (py * SUPERSAMPLE + sy + 0.5) / big
                for sx in range(SUPERSAMPLE):
                    nx = (px * SUPERSAMPLE + sx + 0.5) / big
                    # 从后往前画，让上层形状覆盖下层
                    color = None
                    for kind, left, top, width, height, radius, rgb in SHAPES:
                        if inside_rounded(nx, ny, left, top, width, height, radius):
                            color = rgb
                    if color is None:
                        acc_a += 0
                    else:
                        acc_r += color[0]
                        acc_g += color[1]
                        acc_b += color[2]
                        acc_a += 255
            samples = SUPERSAMPLE * SUPERSAMPLE
            alpha = acc_a // samples
            if alpha == 0:
                row.append((0, 0, 0, 0))
            else:
                covered = acc_a / 255
                row.append((
                    round(acc_r / covered),
                    round(acc_g / covered),
                    round(acc_b / covered),
                    alpha,
                ))
        rows.append(row)
    return rows


def write_png(path, rows):
    width = len(rows[0])
    height = len(rows)
    raw = b"".join(
        b"\x00" + bytes(channel for pixel in row for channel in pixel)
        for row in rows
    )

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


TARGETS = {
    "icon-192.png": 192,
    "icon-512.png": 512,
    "apple-touch-icon.png": 180,
    "favicon.png": 64,
}

# Android 启动图标按密度分目录存放
ANDROID_TARGETS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

ANDROID_RES = ROOT.parent / "android" / "app" / "src" / "main" / "res"


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("网页 / PWA 图标：")
    for name, size in TARGETS.items():
        write_png(OUT_DIR / name, render(size))
        print(f"  {name}  {size}×{size}")

    # Android 工程存在时才生成，避免在没装 SDK 的机器上报错
    if ANDROID_RES.is_dir():
        print("\nAndroid 启动图标：")
        for folder, size in ANDROID_TARGETS.items():
            target_dir = ANDROID_RES / folder
            target_dir.mkdir(parents=True, exist_ok=True)
            write_png(target_dir / "ic_launcher.png", render(size))
            print(f"  {folder}/ic_launcher.png  {size}×{size}")
    else:
        print(f"\n跳过 Android 图标（未找到 {ANDROID_RES}）")

    print(f"\n网页图标位置：{OUT_DIR}")


if __name__ == "__main__":
    main()
