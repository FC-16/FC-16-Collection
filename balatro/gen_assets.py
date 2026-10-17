#!/usr/bin/env python3
# ============================================================ FC-16 小丑牌（balatro-gba 移植版）资产管线
#
# 输入：balatro/gba/*.png —— balatro-gba（GBA 同人 demake）美术素材，
#       仅作研究学习用途的本地转换，不随项目对外发布。
# 输出：sprites.bin / maps.bin / icon.bin / sfx.bin / waveforms.bin / music.bin
#
# sprites.bin：512KiB（256×2048，2048 张 16×16、8bpp，SPEC §4.1）。32×32 图按瓦片带
#   放置，段内基址见下方「精灵段」小节（T_CARD/T_BACK/T_JOKER/T_BLIND/AFFINE0）。
# maps.bin：256KiB。plane0 未使用（全 0），plane1 静态烘焙对局桌面仿射纹理（去重瓦片池）。
# icon.bin：16×16 8bpp 小丑脸。
# sfx.bin / music.bin：本 demo 原生重制的芯片音序。

import struct
from pathlib import Path
from PIL import Image

OUT = Path(__file__).resolve().parent
GBA = f"{OUT}/gba"

# ---------------------------------------------------------------- FC-16 调色板（SPEC §2.2，ENDESGA-64 循环左移一位）
# SPEC §2.2 表格顺序（行×8+列）即 FC-16 色号；0 号近黑为透明色
FC16 = [
    "#131313", "#1B1B1B", "#272727", "#3D3D3D", "#5D5D5D", "#858585", "#B4B4B4", "#FFFFFF",
    "#C7CFDD", "#92A1B9", "#657392", "#424C6E", "#2A2F4E", "#1A1932", "#0E071B", "#1C121C",
    "#391F21", "#5D2C28", "#8A4836", "#BF6F4A", "#E69C69", "#F6CA9F", "#F9E6CF", "#EDAB50",
    "#E07438", "#C64524", "#8E251D", "#FF5000", "#ED7614", "#FFA214", "#FFC825", "#FFEB57",
    "#D3FC7E", "#99E65F", "#5AC54F", "#33984B", "#1E6F50", "#134C4C", "#0C2E44", "#00396D",
    "#0069AA", "#0098DC", "#00CDF9", "#0CF1FF", "#94FDFF", "#FDD2ED", "#F389F5", "#DB3FFD",
    "#7A09FA", "#3003D9", "#0C0293", "#03193F", "#3B1443", "#622461", "#93388F", "#CA52C9",
    "#C85086", "#F68187", "#F5555D", "#EA323C", "#C42430", "#891E2B", "#571C27", "#FF0040",
]
PALETTE = [tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for h in FC16]

_cache = {}


def nearest(rgb):
    """最近邻映射到 FC-16 64 色（加权距离抑制纯亮度误配）。"""
    if rgb in _cache:
        return _cache[rgb]
    r, g, b = rgb[:3]
    best, bi = 1 << 30, 0
    for i, (pr, pg, pb) in enumerate(PALETTE):
        d = 2 * (r - pr) ** 2 + 4 * (g - pg) ** 2 + 3 * (b - pb) ** 2
        if d < best:
            best, bi = d, i
    if bi == 0:
        bi = 1  # 不透明近黑 → #1B1B1B（色 0 是透明色，留给 alpha 镂空）
    _cache[rgb] = bi
    return bi


# ---------------------------------------------------------------- 瓦片银行
SPR = bytearray(512 * 1024)          # 精灵表 256×2048，瓦片主序


def put_tile_at(t, pix):
    """把 pix(tx,ty) 写入指定瓦片号 t 的 16×16 像素。"""
    base = t * 256
    for ty in range(16):
        row = base + ty * 16
        for tx in range(16):
            SPR[row + tx] = pix(tx, ty)


# ---------------------------------------------------------------- 精灵段（32×32 按 2 行瓦片带放置）
# FC-16 spr(t,w,h) 以 16 瓦片/行组合：32×32 占 t、t+1、t+16、t+17。
# 带式布局：每带 2 行瓦片（32 格）放 8 张 32×32，带内第 k 张的左上瓦片号 = 带基址 + k*2。
# 各组基址（均为带基址，与 balatro.lua 的同名常量一致）：
#   牌面  idx = s*13 + r        → T_CARD  = 0   （7 带，0..223）
#   牌背  idx = 背序            → T_BACK  = 224 （1 带，224..255）
#   小丑  idx = id              → T_JOKER = 256（7 带，256..479）
#   盲注  idx = 盲注序          → T_BLIND = 480（4 带，480..607）
#   桌面纹理单瓦片                AFFINE0 = 608
T_CARD, T_BACK, T_JOKER, T_BLIND = 0, 224, 256, 480
AFFINE0 = 608      # 桌面纹理单瓦片基址，位于盲注之后的整带起点的连续瓦片池
BLANK_TILE = 2047  # 空瓦片（全 0 = 透明），用于纹理透明格
BAND_SPRITES = 8
BAND_TILES = 32
band_cursor = {"band": 0, "slot": 0}


def place_sprite32(im):
    """32×32 图 → 2 行带式瓦片，返回左上瓦片号。"""
    return _place32(im, im)


def place_sprite32_centered(im):
    """32×32 图 → 墨迹重定中心 → 2 行带式瓦片，返回左上瓦片号。
    GBA 图集里 token 墨迹不必占满格子（按格原样切割会画歪），
    入库前把非透明墨迹平移到 32×32 正中，绘制端按整格对齐即得居中。"""
    px = im.load()
    box = None
    for y in range(32):
        for x in range(32):
            p = px[x, y]
            if len(p) == 4 and p[3] >= 128:
                box = ((x, y, x, y) if box is None else
                       (min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)))
    canvas = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    if box:
        w, h = box[2] - box[0] + 1, box[3] - box[1] + 1
        canvas.paste(im.crop((box[0], box[1], box[2] + 1, box[3] + 1)),
                     ((32 - w) // 2, (32 - h) // 2))
    return _place32(canvas, im)


def _place32(draw_im, meta_im):
    if band_cursor["slot"] >= BAND_SPRITES:
        band_cursor["band"] += 1
        band_cursor["slot"] = 0
    t = band_cursor["band"] * BAND_TILES + band_cursor["slot"] * 2
    band_cursor["slot"] += 1
    quads = [(0, 0, t), (16, 0, t + 1), (0, 16, t + 16), (16, 16, t + 17)]
    for ox, oy, tt in quads:
        def pix(x, y, _ox=ox, _oy=oy):
            p = draw_im.getpixel((_ox + x, _oy + y))
            if len(p) == 4 and p[3] < 128:
                return 0
            return nearest(p)
        put_tile_at(tt, pix)
    return t


def convert(path):
    return Image.open(path).convert("RGBA")


deck = convert(f"{GBA}/deck_gfx.png")
for s2 in range(4):
    for r in range(13):
        place_sprite32(deck.crop((r * 32, s2 * 32, r * 32 + 32, s2 * 32 + 32)))
assert band_cursor == {"band": 6, "slot": 4}, band_cursor


def pad_band(base):
    """对齐到下一个带边界（带内剩余槽位弃用），并核对组基址落在整带上。"""
    if band_cursor["slot"] > 0:
        band_cursor["band"] += 1
        band_cursor["slot"] = 0
    assert band_cursor["band"] * BAND_TILES == base, (band_cursor, base)

pad_band(T_BACK)                         # 牌背 → 带 7
backs = convert(f"{GBA}/decks_face_down_gfx.png")
for i in range(6):
    place_sprite32(backs.crop((i * 32, 0, i * 32 + 32, 32)))
assert band_cursor == {"band": 7, "slot": 6}, band_cursor

pad_band(T_JOKER)                        # 小丑 → 带 8
for i in range(18):
    j = convert(f"{GBA}/joker_gfx{i}.png")
    for k in range(j.size[0] // 32):
        place_sprite32(j.crop((k * 32, 0, k * 32 + 32, 32)))
assert band_cursor == {"band": 14, "slot": 5}, band_cursor  # 53 张 → 6 带 + 5 张

pad_band(T_BLIND)                        # 盲注 → 带 15
for i in range(18):
    b = convert(f"{GBA}/blind_gfx{i}.png")
    for k in range(b.size[0] // 32):
        place_sprite32_centered(b.crop((k * 32, 0, k * 32 + 32, 32)))
assert band_cursor == {"band": 18, "slot": 6}, band_cursor  # 30 张 → 3 带 + 6 张
pad_band(AFFINE0)                        # 桌面纹理池 → 带 19

# plane1：对局桌面仿射纹理（静态烘焙进 maps.bin，透明格填 BLANK_TILE）
affine = Image.open(f"{GBA}/affine_background_gfx.png").convert("RGBA")
plane1_cells = [BLANK_TILE] * 65536
# 源图为 5 档低饱和青绿，最近邻会误配蓝灰 #657392；按亮度强制走绿色阶
FELT = {
    (92, 149, 125): 34,  # #5AC54F
    (86, 139, 118): 35,  # #33984B
    (77, 125, 109): 36,  # #1E6F50
    (68, 114, 100): 36,
    (61, 107, 92): 37,   # #134C4C
}
_raster = [[1] * 256 for _ in range(256)]
for _y in range(256):
    for _x in range(256):
        _p = affine.getpixel((_x, _y))
        if _p[3] >= 128:
            _raster[_y][_x] = FELT.get(_p[:3], nearest(_p))
_seen = {}
for _ty in range(16):
    for _tx in range(16):
        key = tuple(tuple(_raster[_ty * 16 + yy][_tx * 16 + xx] for xx in range(16))
                    for yy in range(16))
        t = _seen.get(key)
        if t is None:
            t = AFFINE0 + len(_seen)

            def _f(tx, ty, ox=_tx * 16, oy=_ty * 16):
                return _raster[oy + ty][ox + tx]
            put_tile_at(t, _f)
            _seen[key] = t
        plane1_cells[_ty * 16 + _tx] = t

print(f"瓦片消耗：卡 {T_CARD} 背 {T_BACK} 小丑 {T_JOKER} 盲注 {T_BLIND}，"
      f"桌面纹理 {AFFINE0}..{AFFINE0 + len(_seen) - 1}，共 {AFFINE0 + len(_seen)} 张 / 2048")

# ---------------------------------------------------------------- maps.bin（plane0 未使用，plane1 桌面纹理）
maps = bytearray(0x40000)
for i, v in enumerate(plane1_cells):
    struct.pack_into("<H", maps, 0x20000 + i * 2, v)

# ---------------------------------------------------------------- icon.bin（16×16 8bpp 小丑脸）
icon = bytearray(256)
ipx = {
    "r": 30, "e": 34, "s": 21, "W": 7, ".": 13,
}
j_hat_i = [
    "......WW......",
    ".....WWWW.....",
    "....WWWWWW....",
    "..s..WWWW..s..",
    ".sss.WWWW.sss.",
    "..ssssssssss..",
    "...ssssssss...",
]
for j, row in enumerate(j_hat_i):
    for i, ch in enumerate(row):
        if ch != ".":
            icon[j * 16 + i] = ipx[ch]
icon[9 * 16 + 5] = ipx["W"]  # 脸

# ================================================================ SFX（原生重制芯片音序）
sfx = bytearray(128 * 144)
waveforms = bytearray(8 * 80)

# 保留本卡带原音色的波形轮廓；32 个阶梯采样各展开为两项 i8。
custom_waves = [
    [15, 15, 15, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],  # Pulse 12.5%
    [8, 12, 14, 15, 15, 15, 15, 14, 14, 13, 12, 12, 11, 11, 10, 9,
     8, 6, 5, 4, 4, 3, 3, 2, 1, 1, 0, 0, 0, 0, 1, 3],  # Reed
    [8, 12, 13, 13, 13, 15, 15, 12, 10, 12, 15, 15, 13, 13, 13, 12,
     8, 3, 2, 2, 2, 0, 0, 3, 5, 3, 0, 0, 2, 2, 2, 3],  # Bell
    [7, 9, 11, 12, 13, 14, 15, 15, 15, 14, 13, 12, 10, 9, 9, 8,
     7, 7, 6, 6, 5, 3, 2, 1, 0, 0, 0, 1, 2, 3, 4, 6],  # Bass
    [10, 10, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 10, 10,
     10, 5, 5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 5, 5],  # Bit
]
for wid, levels in enumerate(custom_waves):
    waveforms[wid * 80 + 16:wid * 80 + 80] = bytes(
        (level * 17 - 128) & 0xFF for level in levels for _ in range(2))


def N(midi):
    return max(0, min(95, midi - 12))


def put_sfx(idx, speed, steps, loop_end=None):
    base = idx * 144
    ln = len(steps)
    sfx[base:base + 2] = (speed * 4).to_bytes(2, "little")
    sfx[base + 2] = ln
    sfx[base + 3] = 0
    sfx[base + 4] = loop_end - 1 if loop_end else 0
    sfx[base + 5] = 0
    for i in range(32):
        a = base + 16 + i * 4
        if i < ln:
            p, w, v, fx = steps[i]
            sfx[a] = p & 0xFF
            sfx[a + 1] = w
            sfx[a + 2] = v
            sfx[a + 3] = fx
        else:
            sfx[a] = 0
            sfx[a + 1] = 0
            sfx[a + 2] = 0
            sfx[a + 3] = 0


SQ, P25, P12, ORG, REED, BELL, BASS, BIT = 3, 4, 8, 5, 9, 10, 11, 12
NLD, NSH = 6, 6

put_sfx(0, 1, [(N(81), SQ, 6, 0)])                       # 光标
put_sfx(1, 1, [(N(72), SQ, 8, 0), (N(79), SQ, 8, 0)])    # 选中
put_sfx(2, 1, [(N(79), SQ, 7, 0), (N(72), SQ, 7, 0)])    # 取消
put_sfx(3, 2, [(0, NSH, 9, 0), (0, NLD, 6, 0)])          # 发牌/翻牌
put_sfx(4, 3, [(0, NLD, 9, 0), (N(80), 2, 10, 3), (N(74), 2, 8, 3)])  # 出牌呼啸
put_sfx(5, 1, [(N(48 + 2 * i), BASS, 12, 0) for i in range(16)])       # 筹码跑条
put_sfx(6, 1, [(N(55 + 2 * i), REED, 11, 0) for i in range(16)])       # 倍率跑条
put_sfx(7, 2, [(N(79), BELL, 14, 0), (N(83), BELL, 11, 0)])            # 乘算
put_sfx(8, 1, [(N(60 + i), SQ, 8, 0) for i in range(16)])              # 结算跑条
put_sfx(9, 2, [(N(83), P25, 10, 0), (N(88), P25, 10, 0)])              # 金钱
put_sfx(10, 2, [(N(88), P25, 9, 0), (N(79), P25, 9, 0), (N(72), ORG, 11, 0)])  # 购买
put_sfx(11, 2, [(0, NLD, 8 if i % 2 else 5, 0) for i in range(8)])     # 重掷
put_sfx(12, 3, [(N(52), SQ, 10, 0), (N(52), SQ, 9, 0), (N(56), SQ, 11, 0)])    # 盲注 sting
put_sfx(13, 3, [(N(69), P25, 10, 0), (N(72), P25, 10, 0), (N(76), P25, 10, 0), (N(81), P25, 11, 0)])  # 过关
put_sfx(14, 4, [(N(67), 2, 10, 0), (N(63), 2, 10, 0), (N(58), 2, 10, 0)])      # 失败
put_sfx(15, 2, [(N(72), BELL, 10, 0), (N(76), BELL, 10, 0), (N(79), BELL, 10, 0), (N(84), BELL, 11, 0)])  # 星球
put_sfx(16, 3, [(N(69), ORG, 10, 2), (N(69), ORG, 10, 2), (N(72), ORG, 10, 2)])  # 塔罗
put_sfx(17, 2, [(N(76), SQ, 10, 2)])                      # 小丑触发
put_sfx(18, 2, [(0, NSH, 11, 0), (0, NLD, 8, 0)])         # 销毁
put_sfx(19, 3, [(N(40), BASS, 10, 0), (N(36), BASS, 9, 0)])  # 失效
put_sfx(20, 3, [(N(37), SQ, 10, 0), (N(37), SQ, 9, 0)])   # 错误
put_sfx(21, 4, [(N(64), 2, 10, 0), (N(60), 2, 10, 0), (N(57), 2, 10, 0), (N(52), 2, 11, 0)])  # game over
put_sfx(22, 3, [(N(64), P25, 10, 0), (N(69), P25, 10, 0), (N(73), P25, 10, 0),
                (N(76), P25, 10, 0), (N(81), P25, 12, 0)])   # 通关
put_sfx(23, 2, [(N(79), P25, 10, 0), (N(84), P25, 10, 0), (N(88), P25, 11, 0), (N(91), P25, 11, 0)])  # 大钱
put_sfx(24, 2, [(N(88), P25, 9, 0), (N(79), P25, 8, 0), (N(72), SQ, 8, 0)])   # 出售
put_sfx(25, 2, [(N(64), BELL, 10, 0), (N(71), BELL, 9, 0)])   # 钢铁
put_sfx(26, 2, [(N(81), P25, 8, 0), (N(86), P25, 8, 0)])      # 利息
put_sfx(27, 4, [(N(72), 2, 9, 3)])                            # 跳过
put_sfx(28, 2, [(N(79), BELL, 10, 0), (N(84), BELL, 10, 0)])  # 标签
put_sfx(29, 2, [(N(72), BELL, 10, 0), (N(76), BELL, 10, 0), (N(81), BELL, 10, 0), (N(88), BELL, 12, 0)])  # 升级
put_sfx(30, 1, [(N(72), SQ, 7, 0), (N(65), SQ, 7, 0)])        # 返回
put_sfx(31, 3, [(0, NLD, 8, 0), (0, NLD, 6, 0), (0, NLD, 7, 0)])  # 洗牌

# ---------------------------------------------------------------- 音乐
BPM_BARS = ["Am", "F", "C", "G", "Am", "F", "C", "E"]
BASS_ROOT = {"Am": 45, "F": 41, "C": 48, "G": 43, "E": 40}
CHORD_TONES = {"Am": [57, 60, 64], "F": [53, 57, 60], "C": [55, 60, 64],
               "G": [55, 59, 62], "E": [52, 56, 59]}
BASS_OCT = [0, 0, 7, 0, 12, 0, 7, 0]  # 步进相对根音
MEL = [
    [(0, 76), (2, 72), (4, 74), (6, 76)],
    [(0, 72), (3, 69), (6, 67)],
    [(0, 76), (2, 79), (4, 76), (6, 74)],
    [(0, 74), (3, 71), (6, 67)],
    [(0, 69), (2, 72), (4, 76), (6, 74)],
    [(0, 72), (2, 69), (4, 65), (6, 67)],
    [(0, 76), (4, 79), (6, 81)],
    [(0, 76), (3, 74), (6, 71)],
]
bass_ids, chord_ids, mel_ids = {}, {}, {}
for bi, bar in enumerate(BPM_BARS):
    if bar not in bass_ids:
        idx = 64 + len(bass_ids)
        bass_ids[bar] = idx
        put_sfx(idx, 6, [(N(BASS_ROOT[bar] + BASS_OCT[s]), BASS, 13, 0) for s in range(8)])
    if bar not in chord_ids:
        idx = 69 + len(chord_ids)
        chord_ids[bar] = idx
        st = []
        for s in range(8):
            st.append((N(CHORD_TONES[bar][s // 3 if s < 6 else 2]), ORG, 7 if s in (0, 3, 6) else 0, 0))
        put_sfx(idx, 6, st)
    idx = 74 + bi
    mel_ids[bi] = idx
    st = [(0, 0, 0, 0) for _ in range(8)]
    for s, m in MEL[bi]:
        st[s] = (N(m), P25, 9, 0)
    put_sfx(idx, 6, st)
put_sfx(82, 6, [((0, NLD, 5, 0) if s % 2 else (0, 0, 0, 0)) for s in range(8)])
put_sfx(83, 6, [((0, NSH, 10, 0) if s == 4 else ((0, NSH, 4, 0) if s == 7 else (0, 0, 0, 0))) for s in range(8)])

music = bytearray(32 + 64 * 32)
music[0] = 8
for row in range(64):
    music[32 + row * 32:40 + row * 32] = b"\xff" * 8
for i in range(8):
    base = 32 + i * 32
    bar = BPM_BARS[i]
    music[base + 0] = bass_ids[bar]
    music[base + 1] = chord_ids[bar]
    music[base + 2] = mel_ids[i]
    music[base + 6] = 82
    music[base + 7] = 83
    music[base + 8] = music[base + 9] = 255  # -1 声像
    music[base + 14] = music[base + 15] = 1
    if i == 0:
        music[base + 16] = 1
    if i == 7:
        music[base + 17] = 1

# ================================================================ 输出
with open(f"{OUT}/sprites.bin", "wb") as f:
    f.write(SPR)
with open(f"{OUT}/maps.bin", "wb") as f:
    f.write(maps)
with open(f"{OUT}/icon.bin", "wb") as f:
    f.write(icon)
with open(f"{OUT}/sfx.bin", "wb") as f:
    f.write(sfx)
with open(f"{OUT}/waveforms.bin", "wb") as f:
    f.write(waveforms)
with open(f"{OUT}/music.bin", "wb") as f:
    f.write(music)

print(f"maps {len(maps)}B（plane0 空 + plane1 桌面），sprites {len(SPR)}B")
