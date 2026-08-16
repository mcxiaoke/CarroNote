#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 assets/images/icon.png 重新生成 splash 源图。

重要: flutter_native_splash 只把 splash_500.png / splash_12.png 当作*输入源图*读取，
工具本身不会反向生成这两个文件。因此换图标后，必须先重跑本脚本生成新源图，
再执行 `dart run flutter_native_splash:create` 把它们烤进各平台 splash 资源。

产物:
  - assets/images/splash_500.png : 1024x1024 透明画布，图标主体居中 (= splash logo)
  - assets/images/splash_12.png  : 576x576   透明画布，图标主体缩小居中 (Android 12 安全区)

用法:
  python scripts/gen_splash.py
"""

import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("错误: 需要 Pillow 库，请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "assets", "images", "icon.png")
OUT_500 = os.path.join(ROOT, "assets", "images", "splash_500.png")
OUT_12 = os.path.join(ROOT, "assets", "images", "splash_12.png")

S_500 = 1024        # splash_500 画布边长
S_12 = 576          # splash_12 画布边长
D12_BODY = 334      # splash_12 中图标主体直径(与历史 splash_12 几何一致: bbox 121..455)
ALPHA_T = 10        # 视为"不透明"的 alpha 阈值


def body_bbox(im):
    """基于 alpha 通道(而非 RGB)求图标主体包围盒。

    注意: 本图标透明角常为 RGBA=(255,255,255,0)，若用 Image.getbbox()
    (按"全通道为零"判定) 会把白色透明角当成有内容，导致包围盒变成整张画布。
    """
    alpha = im.split()[-1].point(lambda a: 255 if a > ALPHA_T else 0)
    bb = alpha.getbbox()
    if bb is None:
        raise ValueError("icon.png 完全透明，无法提取图标主体")
    return bb


def center_icon(src, canvas, target_body=None):
    """把图标主体放到透明画布中央。target_body 给定则先缩放到该主体直径。"""
    bb = body_bbox(src)
    body = src.crop(bb)
    bw, bh = body.size
    if target_body:
        scale = target_body / max(bw, bh)
        body = body.resize(
            (max(1, round(bw * scale)), max(1, round(bh * scale))), Image.LANCZOS
        )
        bw, bh = body.size
    canvas_img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    offset = ((canvas - bw) // 2, (canvas - bh) // 2)
    canvas_img.paste(body, offset, body)
    return canvas_img


def main():
    if not os.path.isfile(ICON):
        sys.stderr.write(f"找不到源图: {ICON}\n")
        sys.exit(1)
    with Image.open(ICON) as im:
        icon = im.convert("RGBA")

    s500 = center_icon(icon, S_500)
    s500.save(OUT_500, "PNG")
    print(f"已生成: {OUT_500} ({S_500}x{S_500})")

    s12 = center_icon(icon, S_12, D12_BODY)
    s12.save(OUT_12, "PNG")
    print(f"已生成: {OUT_12} ({S_12}x{S_12}, 图标主体直径≈{D12_BODY})")


if __name__ == "__main__":
    main()
