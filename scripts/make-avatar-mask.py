#!/usr/bin/env python3
"""发条屋用户头像：把品牌 logo PNG 转成「去外环 + 放大 + 微加粗」的 alpha 蒙版。

用法:
    python3 scripts/make-avatar-mask.py [源图.png] [输出.png] [--fill 0.84] [--bold 0.5]

为什么不是简单缩放（上一版就是这么做，效果很糊）——源图 1079px 实测结构：
    外圈描边 28px  ▏间隙 33px  ▏主体字形 709x801  ▏顶部小菱形 216x111
头像实际显示只有 32px（内层蒙版 ≈ 27px），缩放系数 ≈ 0.025：
    外圈描边 → 0.6px  ｜  间隙 → 0.7px  ｜  小菱形 → 4x2px
亚像素的描边和间隙只会糊成一片灰，是「看不清、不高级」的根因。所以本脚本：

  1. 取最大墨块 = 主体字形，丢掉外圈描边（以及它带来的间隙与小菱形）
     → 显示尺寸可以立刻放大 1.8 倍，笔画从 2px 提到 3.5~6px
  2. 按 32px 显示尺度轻微膨胀（默认 0.5px）→ 抵消缩小时的抗锯齿吃掉的笔画宽度
  3. 输出 256px 蒙版，字形占画布 fill（默认 84%），四周留白由蒙版本体提供
     （CSS 用 mask-size:100% 铺满元素，留白即来自这里）

输出 PNG 为「白底 + alpha 蒙版」，配合 CSS `-webkit-mask` 着色成皮肤强调色，换肤自动跟随。
"""
import argparse
import os
import sys
from collections import deque

import numpy as np
from PIL import Image

SRC_W = 1079.0          # 源图工作尺度（仅用于把「显示 px」换算成源图像素）


def label(mask):
    """四邻连通分量标记。返回 (labels, 按面积降序的分量编号, 面积表)。"""
    H, W = mask.shape
    lab = np.zeros((H, W), np.int32)
    sizes = [0]
    ys, xs = np.where(mask)
    cur = 0
    for sy, sx in zip(ys, xs):
        if lab[sy, sx]:
            continue
        cur += 1
        n = 0
        q = deque([(sy, sx)])
        lab[sy, sx] = cur
        while q:
            y, x = q.popleft()
            n += 1
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] and not lab[ny, nx]:
                    lab[ny, nx] = cur
                    q.append((ny, nx))
        sizes.append(n)
    return lab, sorted(range(1, len(sizes)), key=lambda i: -sizes[i]), sizes


def dilate(mask, k):
    """二值膨胀 k 次（4 邻）。k≈19 时 1079² 上约 0.05s，比 PIL MaxFilter(39) 快且不炸内存。"""
    m = mask.astype(bool).copy()
    for _ in range(int(k)):
        n = m.copy()
        n[1:, :] |= m[:-1, :]
        n[:-1, :] |= m[1:, :]
        n[:, 1:] |= m[:, :-1]
        n[:, :-1] |= m[:, 1:]
        m = n
    return m


def build(src, fill=0.84, bold=0.5, size=256):
    a = np.array(Image.open(src).convert("L"))
    ink = a < 128
    lab, order, sizes = label(ink)
    if len(order) < 1:
        raise SystemExit("源图里找不到墨块，检查输入")
    glyph = lab == order[0]                       # 主体字形（丢掉外圈描边等其余分量）
    dropped = [sizes[i] for i in order[1:]]
    if bold > 0:
        glyph = dilate(glyph, round(bold * SRC_W / 32.0))
    print(f"  主体字形 {sizes[order[0]]}px，丢弃分量 {dropped}（外圈描边/间隙/小菱形）")

    ys, xs = np.where(glyph)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    sub = glyph[y0:y1 + 1, x0:x1 + 1]
    h, w = sub.shape
    sc = size * fill / max(h, w)
    im = Image.fromarray((sub * 255).astype(np.uint8)).resize(
        (max(1, round(w * sc)), max(1, round(h * sc))), Image.LANCZOS)
    canvas = Image.new("L", (size, size), 0)
    canvas.paste(im, ((size - im.width) // 2, (size - im.height) // 2))
    white = Image.new("L", (size, size), 255)
    return Image.merge("RGBA", (white, white, white, canvas)), (x1 - x0 + 1, y1 - y0 + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?", default=os.path.expanduser("~/Downloads/发条屋.png"))
    ap.add_argument("out", nargs="?", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "resources", "user-avatar.png"))
    ap.add_argument("--fill", type=float, default=0.84, help="字形占画布比例（默认 0.84）")
    ap.add_argument("--bold", type=float, default=0.5, help="按 32px 显示尺度加粗 px（默认 0.5）")
    ap.add_argument("--size", type=int, default=256)
    args = ap.parse_args()
    if not os.path.exists(args.src):
        raise SystemExit(f"源图不存在: {args.src}")
    print(f"源图 {args.src}")
    img, bbox = build(args.src, args.fill, args.bold, args.size)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    img.save(args.out)
    print(f"  bbox {bbox[0]}x{bbox[1]} → fill={args.fill} bold={args.bold}px")
    print(f"写出 {args.out}")


if __name__ == "__main__":
    sys.exit(main())
