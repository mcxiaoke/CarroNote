#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 icon-round-simple-chip.svg 重新生成 dark 模式的 splash 源图。

flutter_native_splash 不会反向生成 splash_dark_500.png / splash_dark_12.png,
所以换图标(或清理草稿)后必须手动生成这两个源图, 再跑
`dart run flutter_native_splash:create` 烤进各平台。

设计: 源 SVG 使用 currentColor 的单色 chip (圆角方块 + 挖空的"纸"窗口 +
干净的萝卜叶子和萝卜描边). 本脚本把它渲染为白色 (放在 color_dark:#000000
的纯黑背景上 = 暗色 logo), 然后按与 scripts/gen_splash.py 一致的几何
居中到透明画布.

为什么用 resvg-py 而不是 cairosvg:
  cairosvg 2.9.0 对本 SVG 的 <mask> 挖空支持有缺陷, 会忽略 chipCut mask
  把整个圆角方块错误地填成实心. resvg (Rust) 能正确渲染 mask 挖空.

产物 (与 gen_splash.py 对称, 但目标文件名带 _dark):
  - assets/images/splash_dark_500.png : 1024x1024 透明画布
  - assets/images/splash_dark_12.png  : 576x576   透明画布, 主体直径≈334

用法:
  python scripts/gen_splash_dark.py
"""

import datetime
import io
import os
import sys

try:
    import resvg_py
except ImportError:
    sys.stderr.write("错误: 需要 resvg-py, 请先运行: pip install resvg-py\n")
    sys.exit(2)
try:
    from PIL import Image
except ImportError:
    sys.stderr.write("错误: 需要 Pillow 库, 请先运行: pip install Pillow\n")
    sys.exit(2)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG = os.path.join(ROOT, "assets", "images", "icon-round-simple-chip.svg")
OUT_500 = os.path.join(ROOT, "assets", "images", "splash_dark_500.png")
OUT_12 = os.path.join(ROOT, "assets", "images", "splash_dark_12.png")

S_500 = 1024        # splash_dark_500 画布边长 (与 flutter_native_splash 的 image_dark 输入源图一致)
S_12 = 576          # splash_dark_12  画布边长 (Android 12 dark splash 输入源图)
D12_BODY = 334      # splash_dark_12 中图标主体直径 (与 gen_splash.py D12_BODY 一致, 保证 dark/light 12 几何对称)
ALPHA_T = 10        # 视为"不透明"的 alpha 阈值
INK = "#FFFFFF"     # currentColor 着色: 白色, 与 #000 背景组合 = 暗色 logo


def render_svg_white(svg_path, size):
    """把 SVG 渲染成 RGBA 透明 PNG bytes, currentColor -> 白色.

    在根 <svg> 注入 style="color:#fff", 利用 CSS color 继承让
    currentColor 解析为白色. resvg 支持该机制.
    """
    src = open(svg_path, "r", encoding="utf-8").read()
    head = src.split(">", 1)[0]
    if "style=" in head:
        # 根 svg 已有 style 属性, 改为插入 <style> 兜底 (避免破坏既有 style)
        injected = src.replace(
            "<defs>", f'<style>svg{{color:{INK}}}</style>\n  <defs>', 1
        )
    else:
        injected = src.replace("<svg ", f'<svg style="color:{INK}" ', 1)
    if injected == src:
        sys.stderr.write(f"错误: 未能向 {svg_path} 注入 currentColor 着色 style\n")
        sys.exit(3)
    return resvg_py.svg_to_bytes(svg_string=injected, width=size, height=size)


def body_bbox(im):
    """基于 alpha 通道求图标主体包围盒 (与 gen_splash.py 一致)."""
    alpha = im.split()[-1].point(lambda a: 255 if a > ALPHA_T else 0)
    bb = alpha.getbbox()
    if bb is None:
        raise ValueError("渲染结果完全透明, 无法提取图标主体")
    return bb


def center_icon(src, canvas, target_body=None):
    """把图标主体放到透明画布中央. target_body 给定则先缩放到该主体直径."""
    bb = body_bbox(src)
    body = src.crop(bb)
    bw, bh = body.size
    if target_body:
        scale = target_body / max(bw, bh)
        body = body.resize(
            (max(1, round(bw * scale)), max(1, round(bh * scale))), Image.LANCZOS
        )
        bw, bh = body.size
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(body, ((canvas - bw) // 2, (canvas - bh) // 2), body)
    return out


def main():
    if not os.path.isfile(SVG):
        sys.stderr.write(f"找不到源 SVG: {SVG}\n")
        sys.exit(1)
    raw = render_svg_white(SVG, 1024)
    icon = Image.open(io.BytesIO(raw)).convert("RGBA")
    print(f"渲染源: {SVG} -> 1024x1024 (currentColor={INK})")

    s500 = center_icon(icon, S_500)
    s500.save(OUT_500, "PNG")
    print(f"已生成: {OUT_500} ({S_500}x{S_500})")

    s12 = center_icon(icon, S_12, D12_BODY)
    s12.save(OUT_12, "PNG")
    print(f"已生成: {OUT_12} ({S_12}x{S_12}, 主体直径≈{D12_BODY})")

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    print(f"完成时间戳: {stamp}")


if __name__ == "__main__":
    main()
