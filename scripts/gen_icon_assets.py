#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从母版图标一键生成全套 App 图标 / splash 源图，并自动取色生成配置。

解决的问题：
  1. adaptive_icon_background 不再写死 —— 从母版自动采样背景色
  2. flutter_native_splash 的 color / color_dark / icon_background_color 全部自动取色
  3. light 模式背景色 = 主色自动变浅（同色系）；dark 模式背景色 = 主色原色

产物（写入 assets/images/ 与项目根目录）：
  - icon.png                      直角不透明 1024（iOS/Windows/Web/Android legacy）
  - icon-android_foreground.png   色键去背景的透明主体，缩放到安全区 66%（Android adaptive foreground）
  - icon_round.png                圆角 icon（保留背景色，供别处使用）
  - splash_500.png / splash_12.png（圆角 icon 缩放，整图居中）
  - flutter_launcher_icons.yaml   自动填 adaptive_icon_background
  - flutter_native_splash.yaml    自动填 color / color_dark / icon_background_color

用法：
  python scripts/gen_icon_assets.py <母版图标路径.png>

母版要求：1024x1024 直角不透明（无圆角、无透明），例如 v2/carrot-sage-green.png
"""

import colorsys
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageMath
except ImportError:
    sys.stderr.write("错误: 需要 Pillow，请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_DIR = os.path.join(ROOT, "assets", "images")

SIZE = 1024            # icon 画布
FG_RATIO = 2 / 3.0     # Android foreground 主体占画布比例（66% 安全区）
S_500 = 1024           # splash_500 画布
S_12 = 576             # splash_12 画布
ROUND_R = 0.22         # 圆角 icon 圆角半径占边长比例（近似 iOS 图标观感）
SPLASH_ICON_RATIO = 0.5  # splash 中圆角 icon 占画布比例
COLOR_KEY_TOL = 60       # 色键去背景阈值：与背景色距离≤此值的像素变透明
ALPHA_T = 10


# ---------- 颜色工具 ----------

def rgb_to_hex(rgb):
    return "#%02X%02X%02X" % tuple(int(round(c)) for c in rgb)


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lighten(hex_color, l_factor=1.35, l_max=0.92):
    """在 HSL 空间提升亮度，得到同色系浅色（不超过 l_max，避免发白）。"""
    r, g, b = [c / 255.0 for c in hex_to_rgb(hex_color)]
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    l2 = min(l * l_factor, l_max)
    r2, g2, b2 = colorsys.hls_to_rgb(h, l2, s)
    return rgb_to_hex((r2 * 255, g2 * 255, b2 * 255))


def sample_bg(img):
    """四角采样平均，得到背景主色。"""
    W, H = img.size
    vals = []
    for cx, cy in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)]:
        x0, y0 = max(0, cx - 12), max(0, cy - 12)
        x1, y1 = min(W, cx + 12), min(H, cy + 12)
        vals.append(img.crop((x0, y0, x1, y1)).resize((1, 1)).getpixel((0, 0)))
    return tuple(sum(v[i] for v in vals) // 4 for i in range(3))


# ---------- 源图生成 ----------

def color_key_alpha(src, bg, tol=COLOR_KEY_TOL):
    """色键去背景：与背景色足够接近的像素变透明，主体保留。
    用 ImageMath 在 C 层逐像素计算距离，比 flood-fill 更稳：
    不依赖连通性、不会误伤主体内部，仅按阈值硬切主体边缘。
    """
    img = src.convert("RGBA")
    r, g, b = img.split()[:3]
    mask = ImageMath.unsafe_eval(
        "convert((abs(R - {0}) + abs(G - {1}) + abs(B - {2}) > {3}) * 255, 'L')".format(
            bg[0], bg[1], bg[2], tol
        ),
        R=r, G=g, B=b,
    )
    img.putalpha(mask)
    return img


def make_android_foreground(src, out, color_key=True, tol=COLOR_KEY_TOL):
    """Android 自适应前景图（规范做法：前景只含主体、外圈透明）。
    color_key=True（默认）：用色键把母版背景变透明得到透明主体，
        再裁到主体包围盒、缩放到安全区(66%)、透明补边到 1024。
    color_key=False：退化为圆角 icon（保留背景色，等同 splash 算法）。
    背景色统一由 adaptive_icon_background 那一层负责。
    """
    if color_key:
        bg = sample_bg(src.convert("RGB"))
        img = color_key_alpha(src, bg, tol)
        bbox = img.getbbox()
        subj = img.crop(bbox) if bbox else img
        target = round(SIZE * FG_RATIO)
        sw, sh = subj.size
        scale = target / max(sw, sh)
        subj = subj.resize((max(1, round(sw * scale)), max(1, round(sh * scale))), Image.LANCZOS)
        canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        canvas.paste(subj, ((SIZE - subj.width) // 2, (SIZE - subj.height) // 2), subj)
        canvas.save(out, "PNG")
        return out
    # 退化：圆角 icon（保留背景色）
    make_rounded_icon(src, FG_RATIO).save(out, "PNG")
    return out


def make_rounded_icon(src, safe_ratio=FG_RATIO, canvas=SIZE):
    """圆角 icon 最简算法（按比例，源图多大都行，无多余步骤）：
    1. 原图加圆角（圆角比例 ROUND_R 固定）
    2. 缩放到安全区（canvas * safe_ratio，safe_ratio 固定）
    3. 四周补透明像素到 canvas（默认 1024）
    """
    # 1. 原图加圆角
    base = src.convert("RGBA").resize((canvas, canvas), Image.LANCZOS)
    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, canvas - 1, canvas - 1], radius=int(canvas * ROUND_R), fill=255
    )
    rounded = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    rounded.paste(base, (0, 0), mask)

    # 2. 缩放到安全区
    sz = round(canvas * safe_ratio)

    rounded = rounded.resize((sz, sz), Image.LANCZOS)
    # 3. 四周补透明像素到 canvas
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(rounded, ((canvas - sz) // 2, (canvas - sz) // 2), rounded)
    return out

def make_rounded_icon_simple(src, safe_ratio=FG_RATIO, canvas=SIZE):
    """圆角 icon 最简算法（按比例，源图多大都行，无多余步骤）：
    1. 原图加圆角（圆角比例 ROUND_R 固定）
    2. 缩放到安全区（canvas * safe_ratio，safe_ratio 固定）
    3. 四周补透明像素到 canvas（默认 1024）
    """
    # 1. 原图加圆角
    base = src.convert("RGBA").resize((canvas, canvas), Image.LANCZOS)
    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, canvas - 1, canvas - 1], radius=int(canvas * ROUND_R), fill=255
    )
    rounded = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    rounded.paste(base, (0, 0), mask)
    return rounded

def make_splash(src, out_500, out_12, safe_ratio=SPLASH_ICON_RATIO):
    """圆角 icon：整图加圆角 → 缩放到安全区 → 透明补边（splash_500 / splash_12）。"""
    make_rounded_icon(src, safe_ratio, S_500).save(out_500, "PNG")
    make_rounded_icon(src, safe_ratio, S_12).save(out_12, "PNG")


# ---------- 配置生成 ----------

def write_launcher_yaml(bg):
    content = f"""flutter_launcher_icons:
  android: true
  #ios: true

  # iOS / Windows / Web / Android legacy 共用直角母版
  image_path: "assets/images/icon.png"
  #image_path_ios: "assets/images/icon.png"

  # iOS 去掉 alpha（App Store 拒收透明）
  #remove_alpha_ios: true

  # Android adaptive icon：背景取主色，前景透明主体居中 66%
  adaptive_icon_background: "{bg}"
  adaptive_icon_foreground: "assets/images/icon-android-foreground.png"
  adaptive_icon_foreground_inset: 16

  min_sdk_android: 25

  web:
    generate: false
    image_path: "assets/images/icon-round.png"
  windows:
    generate: true
    icon_size: 256
    image_path: "assets/images/icon-round.png"
"""
    with open(os.path.join(ROOT, "flutter_launcher_icons.yaml"), "w", encoding="utf-8") as f:
        f.write(content)


def write_splash_yaml(bg_light, bg_raw):
    content = f"""flutter_native_splash:
  color: "{bg_light}"
  image: assets/images/splash_500.png
  color_dark: "{bg_raw}"
  image_dark: assets/images/splash_500.png

  android_12:
    color: "{bg_light}"
    icon_background_color: "{bg_light}"
    image: assets/images/splash_12.png
    color_dark: "{bg_raw}"
    icon_background_color_dark: "{bg_raw}"
    image_dark: assets/images/splash_12.png

  web: false

  fullscreen: true
"""
    with open(os.path.join(ROOT, "flutter_native_splash.yaml"), "w", encoding="utf-8") as f:
        f.write(content)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法: python scripts/gen_icon_assets.py <母版图标路径.png>\n")
        sys.exit(1)
    master = os.path.abspath(sys.argv[1])
    if not os.path.isfile(master):
        sys.stderr.write(f"母版不存在: {master}\n")
        sys.exit(1)

    with Image.open(master) as im:
        master_img = im.convert("RGBA")

    # 1. 采样主色
    bg = sample_bg(master_img.convert("RGB"))
    bg_hex = rgb_to_hex(bg)
    bg_light = lighten(bg_hex)

    print(f"母版     : {master}")
    print(f"主色     : {bg_hex}")
    print(f"浅色(light): {bg_light}")
    print("-" * 50)

    # 2. 生成源图
    icon_out = os.path.join(IMG_DIR, "icon.png")
    # icon.png = 直角不透明（去掉 alpha）
    master_img.convert("RGB").save(icon_out, "PNG")
    print(f"已生成: {icon_out}")

    fg_file_path = os.path.join(IMG_DIR, "icon-android-foreground.png")
    if os.path.exists(fg_file_path):
        print(f"已存在，跳过: {fg_file_path}")
    else:
        #fg_file_path = make_android_foreground(master_img.convert("RGBA"), fg_file_path)
        print(f"已生成: {fg_file_path}")

    # 圆角 icon（保留背景色，供别处使用）
    round_out = os.path.join(IMG_DIR, "icon-round.png")
    make_rounded_icon_simple(master_img.convert("RGBA"), FG_RATIO).save(round_out, "PNG")
    print(f"已生成: {round_out}")

    make_splash(master_img.convert("RGBA"),
                os.path.join(IMG_DIR, "splash_500.png"),
                os.path.join(IMG_DIR, "splash_12.png"))
    print(f"已生成: {os.path.join(IMG_DIR, 'splash_500.png')}")
    print(f"已生成: {os.path.join(IMG_DIR, 'splash_12.png')}")

    # 3. 生成配置
    write_launcher_yaml(bg_hex)
    # write_splash_yaml(bg_light, bg_hex)
    # using black for dark mode splash bg
    write_splash_yaml(bg_light, "#000000")
    print(f"已生成: {os.path.join(ROOT, 'flutter_launcher_icons.yaml')}")
    print(f"已生成: {os.path.join(ROOT, 'flutter_native_splash.yaml')}")
    print("-" * 50)
    print("下一步:")
    print("  1. 从 pubspec.yaml 删除 flutter_launcher_icons / flutter_native_splash 两段")
    print("  2. dart run flutter_launcher_icons")
    print("  3. dart run flutter_native_splash:create")


if __name__ == "__main__":
    main()
