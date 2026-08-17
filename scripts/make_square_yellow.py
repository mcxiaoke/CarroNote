#!/usr/bin/env python3
"""
把一张「圆角色块图标 + 白底」的图片，做成纯色填充的正方形图标。

做法：
1. 用连通域 flood-fill 从图像四边出发，找出与边缘连通的「页面白底」；
2. 把这些白底（四周白边 + 圆角外的白）替换成图标原本的背景色；
3. 输出为正方形（取原图较长边为边长），背景色填充，插画内容原样保留。
   插画内部自身的白色（如便签）不与边缘连通，不会被误填。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


def detect_yellow(arr: np.ndarray, white_thresh: int = 244) -> tuple[int, int, int]:
    """估算图标背景主色：取非白像素中出现最多的颜色。"""
    non_white = arr[~((arr[:, :, 0] >= white_thresh) &
                      (arr[:, :, 1] >= white_thresh) &
                      (arr[:, :, 2] >= white_thresh))]
    if non_white.size == 0:
        return (252, 221, 131)  # 兜底
    # 量化为 4 步长后取众数，避免抗锯齿噪声干扰
    q = (non_white // 4) * 4
    uniq, counts = np.unique(q.reshape(-1, 3), axis=0, return_counts=True)
    color = uniq[counts.argmax()]
    return tuple(int(c) for c in color)


def make_square_yellow(input_path: Path, output_path: Path, white_thresh: int = 244) -> tuple[int, int, int]:
    img = Image.open(input_path).convert("RGB")
    W, H = img.size
    arr = np.array(img)

    # 1. 白底判定 + 连通域（只保留与边缘连通的页面白底）
    whiteish = (arr[:, :, 0] >= white_thresh) & (arr[:, :, 1] >= white_thresh) & (arr[:, :, 2] >= white_thresh)
    labeled, n = ndimage.label(whiteish)

    labels_on_border = set()
    labels_on_border.update(np.unique(labeled[0, :]))
    labels_on_border.update(np.unique(labeled[-1, :]))
    labels_on_border.update(np.unique(labeled[:, 0]))
    labels_on_border.update(np.unique(labeled[:, -1]))
    labels_on_border.discard(0)

    page_mask = np.isin(labeled, list(labels_on_border)) & (labeled > 0)

    # 2. 将白底 mask 轻微膨胀，消除圆角边缘的抗锯齿浅色轮廓
    page_mask = ndimage.binary_dilation(page_mask, iterations=2)

    # 3. 背景色
    yellow = detect_yellow(arr, white_thresh)
    S = max(W, H)

    # 4. 拼合：内容保留，页面白底透明，再贴到实色正方形画布上
    content_alpha = (~page_mask).astype(np.uint8) * 255
    rgba = np.dstack([arr, content_alpha])
    src = Image.fromarray(rgba, "RGBA")

    canvas = Image.new("RGB", (S, S), yellow)
    off_x = (S - W) // 2
    off_y = (S - H) // 2
    canvas.paste(src, (off_x, off_y), src)

    canvas.save(output_path, "PNG")
    return S, yellow, int(page_mask.sum())


def main() -> int:
    parser = argparse.ArgumentParser(description="把圆角色块图标做成纯色正方形图标。")
    parser.add_argument("input", type=Path, help="输入图片路径")
    parser.add_argument("-o", "--output", type=Path, default=None, help="输出路径（默认在输入同目录加 _square 后缀）")
    parser.add_argument("--white-thresh", type=int, default=244, help="白底判定阈值（三通道均 >= 此值视为白）")
    args = parser.parse_args()

    if not args.input.exists():
        print(f"错误：输入文件不存在：{args.input}", file=sys.stderr)
        return 1

    out_path = args.output or args.input.with_name(args.input.stem + "_square.png")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        S, yellow, page_px = make_square_yellow(args.input, out_path, args.white_thresh)
    except Exception as exc:  # noqa: BLE001
        print(f"处理失败：{exc}", file=sys.stderr)
        return 1

    print(f"已保存：{out_path} ({S}x{S})")
    print(f"背景色：{yellow}  被填充的白底像素数：{page_px}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
