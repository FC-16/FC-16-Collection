#!/usr/bin/env python3
"""extract_chr.py — 从 iNES 格式 ROM 提取 CHR 图形并映射到 FC-16 调色板
（ENDESGA-64，SPEC §2.2），生成可直接粘进 demo/mario/mario.lua 的
「BEGIN/END GENERATED CHR」标记段。

使用步骤：
  1. 把自备的日版/美版《超级马里奥兄弟》ROM 放到 demo/mario/_source/smb.nes
     （_source/ 已 gitignore，ROM 不入库）；
  2. python3 extract_chr.py            # 生成标记段写入 mario.lua（精灵表 512-1023 号瓦片）
     python3 extract_chr.py --selftest # 用合成 CHR 数据自测解析/解码/映射正确性
  3. 在 mario.lua 的 _init 中按需调用 chr_gen()（生成段内含说明）；不调用则不影响现有致敬美术。

说明：
  - iNES（NES 1.0）：16B 头 + [512B trainer] + PRG×16KB + CHR×8KB；CHR 为 2bpp
    平面像素（每 8×8 瓦片 8B 低位面 + 8B 高位面），像素值 0-3。
  - NES 调色板不存储在 ROM 中（由程序写入 PPU），此处内置《超级马里奥兄弟》
    1-1 的 4 组背景 + 4 组精灵调色板（公认值），并提供 NES 主调色板 →
    ENDESGA-64 的最近色映射（RGB 欧氏距离，合成色只在生成时计算一次）。
  - 像素值 0 = 透明（写 FC-16 色号 0）；CHR bank0 = 精灵、bank1 = 背景。
"""

import math
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROM = HERE / "_source" / "smb.nes"
LUA = HERE / "mario.lua"
BEGIN_MARK = "-- BEGIN GENERATED CHR (from _source/smb.nes via extract_chr.py)"
END_MARK = "-- END GENERATED CHR"
CHR_TILE_BASE = 0        # SMB 两个 CHR bank = 1024 瓦片，恰好覆盖整张 FC-16 精灵表
TARGET_SLOTS = 1024      # 调用 chr_gen() 即整体替换烘焙美术（不调用则不受影响）

# ENDESGA-64（SPEC §2.2 出厂基线，assets/palette.dat）
ENDESGA = [
    0x131313, 0x1B1B1B, 0x272727, 0x3D3D3D, 0x5D5D5D, 0x858585, 0xB4B4B4, 0xFFFFFF,
    0xC7CFDD, 0x92A1B9, 0x657392, 0x424C6E, 0x2A2F4E, 0x1A1932, 0x0E071B, 0x1C121C,
    0x391F21, 0x5D2C28, 0x8A4836, 0xBF6F4A, 0xE69C69, 0xF6CA9F, 0xF9E6CF, 0xEDAB50,
    0xE07438, 0xC64524, 0x8E251D, 0xFF5000, 0xED7614, 0xFFA214, 0xFFC825, 0xFFEB57,
    0xD3FC7E, 0x99E65F, 0x5AC54F, 0x33984B, 0x1E6F50, 0x134C4C, 0x0C2E44, 0x00396D,
    0x0069AA, 0x0098DC, 0x00CDF9, 0x0CF1FF, 0x94FDFF, 0xFDD2ED, 0xF389F5, 0xDB3FFD,
    0x7A09FA, 0x3003D9, 0x0C0293, 0x03193F, 0x3B1443, 0x622461, 0x93388F, 0xCA52C9,
    0xC85086, 0xF68187, 0xF5555D, 0xEA323C, 0xC42430, 0x891E2B, 0x571C27, 0xFF0040,
]

# NES 主调色板（SMB 实际用到的色号，标准 NTSC 参考值）
NES_RGB = {
    0x0F: 0x000000, 0x00: 0x7C7C7C, 0x16: 0xC84C0C, 0x27: 0xFCFCFC,
    0x18: 0xD8B050, 0x1A: 0x6888FC, 0x22: 0x3CBCFC, 0x29: 0x58D854,
    0x21: 0x88F4FC, 0x2C: 0xF8D878, 0x13: 0xEC2CB0, 0x28: 0xF878F8,
    0x2A: 0xF8B8F8, 0x12: 0x0058F8, 0x30: 0xFCFCFC, 0x17: 0xE45C10,
    0x15: 0xAC7C00, 0x36: 0xFCFCFC,
}


def nes_to_endesa(nes_idx):
    """NES 色号 → ENDESGA-64 最近色（RGB 欧氏距离）。0x0F（黑）固定 1 号近黑。"""
    if nes_idx == 0x0F:
        return 1
    rgb = NES_RGB.get(nes_idx)
    if rgb is None:
        raise ValueError("NES 色号 0x%02X 不在映射表内" % nes_idx)
    r, g, b = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
    best, bi = None, 0
    for i, rgb in enumerate(ENDESGA):
        er, eg, eb = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
        d = (r - er) ** 2 + (g - eg) ** 2 + (b - eb) ** 2
        if best is None or d < best:
            best, bi = d, i
    return bi


# 《超级马里奥兄弟》1-1 的 PPU 调色板（公认值；像素值 0 恒为透底）
SMB_BG_PALETTES = [
    (0x22, 0x29, 0x1A, 0x0F),   # 天空 / 树绿 / 砖褐 / 黑（地面、砖、管道）
    (0x22, 0x27, 0x16, 0x0F),   # 问号块与金币
    (0x22, 0x16, 0x27, 0x18),   # 白色系（云、城堡顶）
    (0x22, 0x21, 0x2C, 0x0F),   # 水蓝系
]
SMB_SPRITE_PALETTES = [
    (0x22, 0x16, 0x27, 0x18),   # 马里奥红 / 肤色 / 棕
    (0x22, 0x13, 0x36, 0x0F),   # 库巴系
    (0x22, 0x12, 0x28, 0x0F),   # 蓝龟壳系
    (0x22, 0x16, 0x30, 0x0F),   # 白红系
]


def parse_ines(data):
    """解析 iNES 头，返回 CHR 数据起点与页数。"""
    if data[:4] != b"NES\x1a":
        raise ValueError("不是 iNES ROM（缺少 NES\\x1a 头）")
    prg, chr_pages = data[4], data[5]
    flags6 = data[6]
    off = 16 + (512 if flags6 & 0x04 else 0) + prg * 16384
    if chr_pages == 0:
        raise ValueError("ROM 无 CHR bank（仅 COOLGIRL 等特殊卡带格式）")
    return off, chr_pages


def decode_chr_bank(bank):
    """8KB CHR bank → 512 个 8×8 瓦片，每瓦片 64 个像素值（0-3）。"""
    tiles = []
    for t in range(len(bank) // 16):
        tile = []
        for y in range(8):
            lo, hi = bank[t * 16 + y], bank[t * 16 + 8 + y]
            for x in range(8):
                bit = 7 - x
                tile.append(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1))
        tiles.append(tile)
    return tiles


def tile_to_fc16(tile, palette):
    """瓦片像素值 → FC-16 全局色号（0 = 透明）。palette = 4 个 NES 色号。"""
    map4 = [0] + [nes_to_endesa(c) for c in palette[1:]]
    return [map4[p] for p in tile]


def synthetic_rom():
    """合成 2-page CHR 测试 ROM：瓦片 t 的全部像素 = t % 4，便于断言。"""
    chr_data = bytearray(2 * 8192)
    for t in range(1024):
        v = t % 4
        lo = 0xFF if (v & 1) else 0x00
        hi = 0xFF if (v & 2) else 0x00
        for y in range(8):
            chr_data[t * 16 + y] = lo
            chr_data[t * 16 + 8 + y] = hi
    header = b"NES\x1a" + bytes([2, 2, 0x00, 0, 0, 0, 0, 0]) + bytes(4)
    return header + bytes(2 * 16384) + bytes(chr_data)


def selftest():
    """合成 CHR 自测：头解析、2bpp 解码、调色板映射逐一断言。"""
    rom = synthetic_rom()
    off, pages = parse_ines(rom)
    assert off == 16 + 32768, "CHR 偏移计算错误"
    assert pages == 2
    # 反例：坏头
    try:
        parse_ines(b"XXXX" + rom[4:])
        raise AssertionError("坏头未被拒绝")
    except ValueError:
        pass
    tiles = decode_chr_bank(rom[off:off + 8192])
    assert len(tiles) == 512
    for t in (0, 1, 2, 3, 100, 511):
        assert all(p == t % 4 for p in tiles[t]), "瓦片 %d 解码错误" % t
    # 调色板映射：0x0F → 1（近黑），天空蓝 0x22 → 42（ENDESGA 0x00CDF9）
    assert nes_to_endesa(0x0F) == 1
    assert nes_to_endesa(0x22) == 42
    assert 0 <= nes_to_endesa(0x27) < 64
    # 瓦片转 FC-16：像素 0 → 透明 0，像素 1 → 调色板第 1 色（树绿 0x29）
    tile_all1 = [1] * 64
    fc = tile_to_fc16(tile_all1, SMB_BG_PALETTES[0])
    assert fc[0] == nes_to_endesa(0x29) and len(fc) == 64
    assert tile_to_fc16([0] * 64, SMB_BG_PALETTES[0]) == [0] * 64
    print("extract_chr 自测通过：iNES 解析 / 2bpp 解码 / ENDESGA-64 映射")
    for name, idx in (("天空 0x22", 0x22), ("白 0x27", 0x27), ("马里奥红 0x16", 0x16),
                      ("土黄 0x18", 0x18), ("树绿 0x29", 0x29), ("黑 0x0F", 0x0F)):
        print("  %s → ENDESGA %d" % (name, nes_to_endesa(idx)))


def gen_block(chr_bytes):
    off, pages = parse_ines(chr_bytes)
    if pages < 2:
        raise ValueError("SMB 为 2 个 CHR bank，ROM 只有 %d" % pages)
    lua = [
        BEGIN_MARK,
        "-- 原版图形提取（_source/smb.nes CHR bank0 精灵 / bank1 背景 → ENDESGA-64）",
        "-- 由 extract_chr.py 生成；像素值 0 = 透明。瓦片写入精灵表 %d-%d 号（整表替换），"
        "-- 瓦片内调色板槽按 16x16 属性块近似选取，接入后可按画面微调。"
        "-- 需要在 _init 调用 chr_gen() 并替换 draw_* 中的瓦片引用后才会生效。"
        % (CHR_TILE_BASE, CHR_TILE_BASE + TARGET_SLOTS - 1),
        "local function chr_gen()",
    ]
    n = 0
    for b in range(2):
        bank = chr_bytes[off + b * 8192: off + (b + 1) * 8192]
        palette_set = SMB_SPRITE_PALETTES if b == 0 else SMB_BG_PALETTES
        tiles = decode_chr_bank(bank)
        for t, tile in enumerate(tiles):
            # 空瓦片（全 0）跳过
            if not any(tile):
                continue
            pal = palette_set[(t >> 2) & 3]  # 属性区按 16x16 块选调色板的近似
            colors = tile_to_fc16(tile, pal)
            rows = ["%d,%d," % (colors[y * 8 + x], colors[y * 8 + x + 1])
                    for y in range(8) for x in (0, 2, 4, 6)]
            slot = CHR_TILE_BASE + b * 256 + t
            lua.append("  local d%d = {%s}" % (t, "".join(rows)[:-1]))
            lua.append("  for i = 0, 63 do poke(%d * 256 + i, d%d[i + 1]) end" % (slot, t))
            n += 1
    lua.append("  -- 共写入 %d 个非空瓦片" % n)
    lua.append("end")
    lua.append(END_MARK)
    return "\n".join(lua) + "\n"


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    if not ROM.exists():
        print("未找到 %s：使用现有致敬美术，管线不生效。" % ROM)
        print("把自备 ROM 放到该路径后重新运行本脚本即可生成 CHR 生成段。")
        return
    data = ROM.read_bytes()
    gen = gen_block(data) + END_MARK + "\n"
    src = LUA.read_text(encoding="utf-8")
    b = src.find(BEGIN_MARK)
    e = src.find(END_MARK)
    if b >= 0 and e >= 0:
        src = src[:b] + gen + src[e + len(END_MARK):]
    else:
        anchor = "local function init_all_audio()"
        i = src.index(anchor)
        src = src[:i] + gen + "\n" + src[i:]
    LUA.write_text(src, encoding="utf-8")
    print("已把 CHR 生成段写入 %s（记得在 _init 调用 chr_gen() 并替换瓦片引用）" % LUA)


if __name__ == "__main__":
    main()
