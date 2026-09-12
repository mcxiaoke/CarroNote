#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从母版图标一键生成全套 App 图标 / splash 源图，并自动取色生成配置。

解决的问题：
  1. adaptive_icon_background 不再写死 —— 从母版自动采样背景色
  2. flutter_native_splash 的 color / color_dark / icon_background_color 全部自动取色
  3. light 模式背景色 = 主色自动变浅（同色系）；dark 模式背景色 = 主色原色
  4. 支持 --output / -o 指定输出目录，直接输出为 Flutter 标准项目结构（assets/images/ 与根目录 yaml）
  5. 智能平台策略：
     - 若指定 output 目录为测试/导出目录（非已有 Flutter 工程），默认输出全平台配置（all），方便复制与测试；
     - 若目标为真实 Flutter 项目，则根据工程中存在的平台目录（android/ios/web/windows/macos/linux）精准启用，
       缺失的平台转为注释模板，避免后续执行 dart run flutter_launcher_icons / flutter_native_splash:create 报错。

产物（写入 assets/images/ 与项目根目录）：
  - icon.png                      直角 1024（iOS/Windows/Web/Android legacy）
  - icon-android-foreground.png   Android 自适应图标前景图（缩放到 66% 安全区，四周透明补边）
  - icon-round.png                圆角 icon（保留背景色，供 Windows/Web 等使用）
  - splash_500.png / splash_12.png（圆角 icon 缩放，整图居中）
  - flutter_launcher_icons.yaml   按平台策略生成配置
  - flutter_native_splash.yaml    自动填色并按平台策略适配 web 参数

用法：
  # 输出到当前项目默认目录 (自动检测当前项目包含的平台)
  python scripts/gen_icon_assets.py <母版图标路径.png>

  # 输出到测试/导出目录 (自动启用全平台配置，方便直接拷贝或测试)
  python scripts/gen_icon_assets.py <母版图标路径.png> -o <输出目录>

  # 手动指定需要启用的平台
  python scripts/gen_icon_assets.py <母版图标路径.png> -o <输出目录> -p android,ios,windows

  # 强制开启全部平台
  python scripts/gen_icon_assets.py <母版图标路径.png> -o <输出目录> -p all

母版要求：建议 1024x1024 正方形图片（支持直角图片或带透明通道的主题图标）
"""

import argparse
import colorsys
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.stderr.write("错误: 需要 Pillow，请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

DEFAULT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SIZE = 1024            # icon 画布
FG_RATIO = 2 / 3.0     # Android foreground 主体占画布比例（66% 安全区）
S_500 = 1024           # splash_500 画布
S_12 = 576             # splash_12 画布
ROUND_R = 0.22         # 圆角 icon 圆角半径占边长比例（近似 iOS 图标观感）
SPLASH_ICON_RATIO = 0.5  # splash 中圆角 icon 占画布比例

SUPPORTED_PLATFORMS = ["android", "ios", "web", "windows", "macos", "linux"]


# ---------- 图像与几何工具 ----------

def make_square(img):
    """若源图不是正方形，居中裁剪为 1:1 正方形，避免拉伸畸变。"""
    w, h = img.size
    if w == h:
        return img
    side = min(w, h)
    left = (w - side) // 2
    top = (h - side) // 2
    return img.crop((left, top, left + side, top + side))


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
    if l < 0.05:  # 极暗或纯黑，返回浅灰色
        return "#F5F5F5"
    if l > 0.90:  # 接近纯白，保持纯白
        return "#FFFFFF"
    l2 = min(l * l_factor, l_max)
    r2, g2, b2 = colorsys.hls_to_rgb(h, l2, s)
    return rgb_to_hex((r2 * 255, g2 * 255, b2 * 255))


def sample_bg(img):
    """四角采样平均，得到背景主色。"""
    im_rgba = img.convert("RGBA")
    W, H = im_rgba.size
    vals = []
    has_alpha = False
    for cx, cy in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)]:
        x0, y0 = max(0, cx - 12), max(0, cy - 12)
        x1, y1 = min(W, cx + 12), min(H, cy + 12)
        pix = im_rgba.crop((x0, y0, x1, y1)).resize((1, 1)).getpixel((0, 0))
        if pix[3] < 128:
            has_alpha = True
        vals.append(pix[:3])
    if has_alpha:
        # 四角透明，说明母版本身是透明底主体，背景默认给纯白
        return (255, 255, 255)
    return tuple(sum(v[i] for v in vals) // 4 for i in range(3))


# ---------- 源图生成 ----------

def make_android_foreground(src, out, safe_ratio=FG_RATIO, canvas=SIZE):
    """Android 自适应前景图（不进行色键抠图，确保画质无损）：
    1. 若母版本身自带透明背景（Alpha）：裁切到内容包围盒，等比缩放到 66% 安全区居中。
    2. 若母版为直角不透明图：加圆角(ROUND_R)后缩放到 66% 安全区居中。
    """
    img = src.convert("RGBA")
    alpha_extrema = img.getchannel("A").getextrema()  # (min_alpha, max_alpha)
    if alpha_extrema[0] < 250:
        # 母版已有透明底，直接取内容包围盒缩放到安全区
        bbox = img.getbbox()
        subj = img.crop(bbox) if bbox else img
        target = round(canvas * safe_ratio)
        sw, sh = subj.size
        scale = target / max(sw, sh)
        new_w, new_h = max(1, round(sw * scale)), max(1, round(sh * scale))
        subj = subj.resize((new_w, new_h), Image.LANCZOS)
        out_img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        out_img.paste(subj, ((canvas - new_w) // 2, (canvas - new_h) // 2), subj)
        out_img.save(out, "PNG")
        return out

    # 不透明母版：整图加圆角后缩放到安全区居中
    make_rounded_icon(img, safe_ratio, canvas).save(out, "PNG")
    return out


def make_rounded_icon(src, safe_ratio=FG_RATIO, canvas=SIZE):
    """圆角 icon 最简算法：
    1. 原图加圆角（圆角比例 ROUND_R）
    2. 缩放到安全区（canvas * safe_ratio）
    3. 四周补透明像素到 canvas
    """
    base = src.convert("RGBA").resize((canvas, canvas), Image.LANCZOS)
    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, canvas - 1, canvas - 1], radius=int(canvas * ROUND_R), fill=255
    )
    rounded = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    rounded.paste(base, (0, 0), mask)

    # 缩放到安全区
    sz = round(canvas * safe_ratio)
    rounded = rounded.resize((sz, sz), Image.LANCZOS)

    # 四周补透明像素
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(rounded, ((canvas - sz) // 2, (canvas - sz) // 2), rounded)
    return out


def make_rounded_icon_simple(src, canvas=SIZE):
    """原图加圆角（无缩放和补边，铺满画布）"""
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


# ---------- 平台解析与配置生成 ----------

def is_flutter_project(path):
    """判断目录是否是一个现有的 Flutter 项目根目录。"""
    if not path or not os.path.isdir(path):
        return False
    if os.path.isfile(os.path.join(path, "pubspec.yaml")):
        return True
    if os.path.isdir(os.path.join(path, "lib")):
        for p in SUPPORTED_PLATFORMS:
            if os.path.isdir(os.path.join(path, p)):
                return True
    return False


def resolve_platforms(args_platforms, out_root, is_custom_output):
    """解析需要启用的平台集合。
    1. 若手动指定 -p/--platforms，以手动指定为最高优先级。
    2. 若用户指定了 -o/--output 且目标不是 Flutter 工程（空目录、新目录、纯测试/导出目录），
       说明用户想输出 icon 测试，默认生成全平台配置 (all)。
    3. 若目标是真实 Flutter 工程（无论是 -o 指向的还是默认当前项目），
       自动检测工程中实际存在的平台目录，未存在的平台生成为注释模板，防止运行报错。
    """
    if args_platforms:
        arg_val = args_platforms.strip().lower()
        if arg_val == "all":
            return set(SUPPORTED_PLATFORMS), "手动指定: 全部平台 (all)"
        chosen = {p.strip().lower() for p in arg_val.split(",") if p.strip()}
        valid = chosen & set(SUPPORTED_PLATFORMS)
        if not valid:
            sys.stderr.write(f"警告: 指定平台均无效 ({args_platforms})，回退到全部平台\n")
            return set(SUPPORTED_PLATFORMS), "回退: 全部平台 (all)"
        return valid, f"手动指定: {', '.join(sorted(valid))}"

    # 用户指定了 -o 且目标目录不是已有的 Flutter 工程 -> 输出全平台配置
    if is_custom_output and not is_flutter_project(out_root):
        return set(SUPPORTED_PLATFORMS), "测试/导出目录 (非 Flutter 工程): 默认启用全平台配置 (all)"

    # 目标为 Flutter 工程（-o 命中的工程或默认当前项目）
    target_project = out_root if is_flutter_project(out_root) else DEFAULT_ROOT
    detected = {p for p in SUPPORTED_PLATFORMS if os.path.isdir(os.path.join(target_project, p))}
    if detected:
        return detected, f"已检测到 Flutter 工程平台: {', '.join(sorted(detected))} (未存在平台已设为注释)"

    # 兜底：全平台
    return set(SUPPORTED_PLATFORMS), "默认: 全部平台 (all)"


def write_launcher_yaml(out_root, bg, platforms):
    lines = [
        "flutter_launcher_icons:",
        f"  android: {'true' if 'android' in platforms else 'false'}",
    ]

    # iOS
    if "ios" in platforms:
        lines.extend([
            "  ios: true",
            '  image_path_ios: "assets/images/icon.png"',
            "  remove_alpha_ios: true",
        ])
    else:
        lines.extend([
            "  #ios: true",
            '  #image_path_ios: "assets/images/icon.png"',
            "  #remove_alpha_ios: true",
        ])

    lines.extend([
        "",
        "  # iOS / Windows / Web / Android legacy 共用直角母版",
        '  image_path: "assets/images/icon.png"',
        "",
        "  # Android adaptive icon：背景取主色，前景主体已预留 66% 安全区，inset 设为 0",
        f'  adaptive_icon_background: "{bg}"',
        '  adaptive_icon_foreground: "assets/images/icon-android-foreground.png"',
        "  adaptive_icon_foreground_inset: 0",
        "",
        "  min_sdk_android: 25",
        "",
    ])

    # Web
    if "web" in platforms:
        lines.extend([
            "  web:",
            "    generate: true",
            '    image_path: "assets/images/icon-round.png"',
        ])
    else:
        lines.extend([
            "  #web:",
            "  #  generate: true",
            '  #  image_path: "assets/images/icon-round.png"',
        ])

    # Windows
    if "windows" in platforms:
        lines.extend([
            "  windows:",
            "    generate: true",
            "    icon_size: 256",
            '    image_path: "assets/images/icon-round.png"',
        ])
    else:
        lines.extend([
            "  #windows:",
            "  #  generate: true",
            "  #  icon_size: 256",
            '  #  image_path: "assets/images/icon-round.png"',
        ])

    # macOS
    if "macos" in platforms:
        lines.extend([
            "  macos:",
            "    generate: true",
            '    image_path: "assets/images/icon-round.png"',
        ])
    else:
        lines.extend([
            "  #macos:",
            "  #  generate: true",
            '  #  image_path: "assets/images/icon-round.png"',
        ])

    # Linux
    if "linux" in platforms:
        lines.extend([
            "  linux:",
            "    generate: true",
            '    image_path: "assets/images/icon-round.png"',
        ])
    else:
        lines.extend([
            "  #linux:",
            "  #  generate: true",
            '  #  image_path: "assets/images/icon-round.png"',
        ])

    content = "\n".join(lines) + "\n"
    path = os.path.join(out_root, "flutter_launcher_icons.yaml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def write_splash_yaml(out_root, bg_light, bg_raw, platforms):
    web_flag = "true" if "web" in platforms else "false"
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

  # 若项目缺少 web 目录，设为 true 会导致 flutter_native_splash 报错
  web: {web_flag}

  fullscreen: true
"""
    path = os.path.join(out_root, "flutter_native_splash.yaml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def parse_args():
    parser = argparse.ArgumentParser(
        description="从母版图标一键生成全套 App 图标 / splash 源图，并自动根据项目平台生成配置。",
    )
    parser.add_argument(
        "master",
        help="母版图标路径 (建议 1024x1024 PNG)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="输出根目录 (默认: 当前项目根目录)。"
        "按 Flutter 标准目录结构输出 assets/images/ 及 yaml 配置文件，方便复制到任意项目",
    )
    parser.add_argument(
        "-p",
        "--platforms",
        default=None,
        help="指定启用的平台 (逗号分隔，如 android,ios,windows,web，或 all)。"
        "独立输出目录默认全平台启用 (all)；若输出至 Flutter 工程则自动按实际平台目录过滤",
    )
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="强制覆盖已有文件 (包括 icon-android-foreground.png)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    master = os.path.abspath(args.master)
    if not os.path.isfile(master):
        sys.stderr.write(f"错误: 母版文件不存在: {master}\n")
        sys.exit(1)

    is_custom_output = bool(args.output)
    out_root = os.path.abspath(args.output) if args.output else DEFAULT_ROOT
    img_dir = os.path.join(out_root, "assets", "images")
    os.makedirs(img_dir, exist_ok=True)

    # 解析启用的平台
    platforms, plat_desc = resolve_platforms(args.platforms, out_root, is_custom_output)

    try:
        with Image.open(master) as im:
            raw_img = im.convert("RGBA")
    except Exception as e:
        sys.stderr.write(f"错误: 无法打开母版图标: {e}\n")
        sys.exit(1)

    # 居中裁剪为正方形，并缩放到标准 1024 尺寸
    sq_img = make_square(raw_img)
    if sq_img.size != (SIZE, SIZE):
        master_img = sq_img.resize((SIZE, SIZE), Image.LANCZOS)
    else:
        master_img = sq_img

    # 1. 采样主色
    bg = sample_bg(master_img)
    bg_hex = rgb_to_hex(bg)
    bg_light = lighten(bg_hex)

    print(f"母版     : {master}")
    print(f"输出目录 : {out_root}")
    print(f"平台策略 : {plat_desc}")
    print(f"主色     : {bg_hex}")
    print(f"浅色(light): {bg_light}")
    print("-" * 50)

    # 2. 生成源图
    # icon.png (直角图)
    icon_out = os.path.join(img_dir, "icon.png")
    # 若母版无透明通道，转为 RGB 保存；若有透明通道则保持 RGBA
    alpha_min = master_img.getchannel("A").getextrema()[0]
    if alpha_min >= 250:
        master_img.convert("RGB").save(icon_out, "PNG")
    else:
        master_img.save(icon_out, "PNG")
    print(f"已生成: {icon_out}")

    # Android 自适应图标前景
    fg_file_path = os.path.join(img_dir, "icon-android-foreground.png")
    if os.path.exists(fg_file_path) and not args.force:
        print(f"已存在，跳过: {fg_file_path} (可使用 -f/--force 覆盖)")
    else:
        make_android_foreground(master_img, fg_file_path)
        print(f"已生成: {fg_file_path}")

    # 圆角 icon（供 Windows / Web / 桌面端等使用）
    round_out = os.path.join(img_dir, "icon-round.png")
    make_rounded_icon_simple(master_img).save(round_out, "PNG")
    print(f"已生成: {round_out}")

    # Splash 启动图 (500 与 12)
    splash_500_out = os.path.join(img_dir, "splash_500.png")
    splash_12_out = os.path.join(img_dir, "splash_12.png")
    make_splash(
        master_img,
        splash_500_out,
        splash_12_out,
    )
    print(f"已生成: {splash_500_out}")
    print(f"已生成: {splash_12_out}")

    # 3. 生成配置
    launcher_yaml = write_launcher_yaml(out_root, bg_hex, platforms)
    splash_yaml = write_splash_yaml(out_root, bg_light, "#000000", platforms)
    print(f"已生成: {launcher_yaml}")
    print(f"已生成: {splash_yaml}")
    print("-" * 50)
    print("生成完成！目录结构:")
    print(f"  {out_root}")
    print(f"  ├── assets/")
    print(f"  │   └── images/")
    print(f"  │       ├── icon.png")
    print(f"  │       ├── icon-android-foreground.png")
    print(f"  │       ├── icon-round.png")
    print(f"  │       ├── splash_500.png")
    print(f"  │       └── splash_12.png")
    print(f"  ├── flutter_launcher_icons.yaml")
    print(f"  └── flutter_native_splash.yaml")
    print("-" * 50)
    print("提示:")
    print(f"  已启用平台: {', '.join(sorted(platforms))}")
    print("  如需自定义平台，可直接编辑 flutter_launcher_icons.yaml 解除/添加注释，")
    print("  或使用 -p/--platforms 参数重新生成 (例如: -p android,ios,windows,web 或 -p all)")
    print("-" * 50)
    print("使用方式:")
    print("  1. 将 assets/ 目录和两个 yaml 文件直接复制到目标 Flutter 项目根目录")
    print("  2. 在目标项目运行:")
    print("     dart run flutter_launcher_icons")
    print("     dart run flutter_native_splash:create")


if __name__ == "__main__":
    main()
