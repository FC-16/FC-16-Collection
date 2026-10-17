#!/usr/bin/env python3
"""Celeste Classic 2（PICO-8）→ FC-16 资产转换器。

输入：../../Celeste2 下的 .p8 文本卡带
  celeste2.p8  —— 权威美术（__gfx__ 前 64 行 = 精灵 0–127）、精灵标志、SFX、乐谱
  1.p8 … 8.p8 —— 各关原始地图（__map__ 为 128 宽行；高度 > 32 的关卡下半段在
                 __gfx__ 的 0x1000 共享区，见 README「关卡数据」）

输出（build/）：
  sprites.bin   256×2048 精灵表，瓦片 0–127 = PICO 8×8 最近邻 2× 放大
  sflags.bin    2048 字节精灵标志
  sfx.bin       128 × 144B
  waveforms.bin 8 × 80B（原曲没有自定义波形，保持全零）
  instruments.bin 16 × 144B（原 SFX 0–7 的独立副本）
  music.bin     32B 表头 + 64 × 32B
  custom.bin    关卡地图格（每格 2B 小端，瓦片号 0–2047）

用法：python3 tools/cs2_convert.py [--preview]
"""

from __future__ import annotations

import argparse
import re
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent   # celeste2
REPO = HERE.parents[1] / "FC-16"                          # FC-16 仓库根
SRC = HERE.parents[1] / "Celeste2"              # 并存的原作仓库 ../Celeste2
BUILD = HERE / "build"

# ---------------------------------------------------------------- 调色板

# PICO-8 标准 16 色
PICO_RGB = [
    (0, 0, 0), (29, 43, 83), (126, 37, 83), (0, 135, 81),
    (171, 82, 54), (95, 87, 79), (194, 195, 199), (255, 241, 232),
    (255, 0, 77), (255, 163, 0), (255, 236, 39), (0, 228, 54),
    (41, 173, 255), (131, 118, 156), (255, 119, 168), (255, 204, 170),
]

# PICO-8 色号 → FC-16 固定 64 色号。
# 由 assets/palette.dat 的 CIEDE2000 最近色计算得出；白（7）与棕（4）按色族人工
# 定标（白必须仍是白；棕保持棕色相而非偏红的 #c64524），见 README「调色板定标」。
COL = [0, 12, 53, 35, 18, 4, 6, 7, 63, 29, 31, 34, 41, 10, 57, 21]
COL_NAME = ["black", "dark-blue", "dark-purple", "dark-green", "brown", "dark-grey",
            "light-grey", "white", "red", "orange", "yellow", "green", "blue",
            "lavender", "pink", "peach"]

def load_sections(path: Path) -> dict[str, str]:
    out: dict[str, list[str]] = {}
    cur = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^__(\w+)__\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
        elif cur is not None:
            out[cur].append(line)
    return {k: "\n".join(v).strip("\n") for k, v in out.items()}


def rows(sec: str) -> list[bytes]:
    return [bytes.fromhex(l.strip()) for l in sec.split("\n") if l.strip()]


# ---------------------------------------------------------------- 精灵表

def build_sprites(cart: dict[str, str]) -> bytes:
    """PICO 128×128 4bpp 精灵表 → FC 256×2048 8bpp 瓦片表。

    PICO 精灵 n 的像素原点 (n%16*8, n/16*8)；放大 2× 后写入瓦片 n 的 16×16 块。
    """
    gfx = rows(cart["gfx"])           # 每行 64 字节 = 128 像素（4bpp）
    sheet = bytearray(2048 * 256)
    for n in range(128):
        sx = (n % 16) * 8
        sy = (n // 16) * 8
        base = n * 256
        for py in range(8):
            row = gfx[sy + py]
            for px in range(8):
                byte = row[(sx + px) // 2]
                c = (byte >> 4) if (sx + px) % 2 == 0 else (byte & 0x0F)
                fc = COL[c]
                for dy in range(2):
                    off = base + (py * 2 + dy) * 16 + px * 2
                    sheet[off] = fc
                    sheet[off + 1] = fc
    return bytes(sheet)


def build_sflags(cart: dict[str, str]) -> bytes:
    flags = rows(cart["gff"])
    blob = b"".join(flags)
    assert len(blob) == 256, len(blob)
    return blob + bytes(2048 - 256)


# ---------------------------------------------------------------- 音频

def parse_sfx(cart: dict[str, str]) -> list[dict]:
    """解析 .p8 __sfx__：每行 168 字符 = 头 8 + 32 音符 × 5。

    头 4B：编辑模式与Filters / speed / 循环起点 / 循环终点（独占边界）。
    音符 5 字符：音高 2 位十六进制（0–63）、波形 1、音量 1、效果 1。
    """
    out = []
    for line in cart["sfx"].split("\n"):
        line = line.strip()
        if not line:
            continue
        assert len(line) == 168, len(line)
        mode_filters = int(line[0:2], 16)
        loop_start_byte = int(line[4:6], 16)
        # PICO byte 66 bit7 表示 64×i8 Waveform 模式；此原作 0–7 全是 SFX Instrument。
        assert not (loop_start_byte & 0x80), "原卡带启用了 Waveform 模式，需单独解析原始64字节"
        noiz = (mode_filters >> 1) & 1
        buzz = (mode_filters >> 2) & 1
        value = mode_filters >> 3
        detune = value % 3
        reverb = (value // 3) % 3
        dampen = value // 9
        assert dampen <= 2
        assert mode_filters == (mode_filters & 1) + 2 * noiz + 4 * buzz + 8 * detune + 24 * reverb + 72 * dampen
        notes = []
        for k in range(32):
            g = line[8 + k * 5:8 + k * 5 + 5]
            p, w, v, fx = int(g[:2], 16), int(g[2], 16), int(g[3], 16), int(g[4], 16)
            assert p <= 63 and w <= 15 and v <= 7 and fx <= 7
            notes.append((p, w, v, fx))
        out.append({
            "speed": int(line[2:4], 16),
            "loop_start": loop_start_byte,
            "loop_end": int(line[6:8], 16),
            "filters": (noiz, buzz, detune, reverb, dampen),
            "notes": notes,
        })
    assert len(out) == 64, len(out)
    return out


def sfx_length(s: dict) -> int:
    # PICO 的 LEN 特例仅由「START>0, END=0」编码；尾部静音仍计入正常32步时长。
    if s["loop_start"] > 0 and s["loop_end"] == 0:
        return s["loop_start"]
    return 32


def fc_speed(pico_speed: int) -> int:
    # 两个音频时钟分别为 120/240Hz，整数倍换算不经过浮点舍入。
    return 2 * max(1, pico_speed)


def encode_sfx(s: dict, instrument: bool = False) -> bytes:
    """PICO SFX / SFX Instrument → 两个独立 FC 144B 资源（SPEC §5.2）。"""
    length = sfx_length(s)
    spd = fc_speed(s["speed"])
    loop = s["loop_end"] > s["loop_start"]
    assert 1 <= spd <= 65535 and 1 <= length <= 32
    assert s["loop_start"] < 32 and s["loop_end"] <= 32
    head = bytearray(16)
    head[0:2] = spd.to_bytes(2, "little")
    head[2] = length
    head[3] = s["loop_start"] if loop else 0
    head[4] = s["loop_end"] - 1 if loop else 0
    head[5] = 1 if loop else 0
    head[6:11] = bytes(s["filters"])
    body = bytearray()
    for p, w, v, fx in s["notes"]:
        if instrument:
            assert w < 8, "原作的内层 Instrument 不允许再次引用 Instrument"
        source = w if w < 8 else 16 + (w - 8)
        volume = (15 * v + 3) // 7
        body += bytes([p if instrument else p + 24, source, volume, fx])
    assert len(body) == 128
    return bytes(head) + bytes(body)


def parse_music(cart: dict[str, str]) -> list[dict]:
    out = []
    for line in cart["music"].split("\n"):
        line = line.strip()
        if not line:
            continue
        flags = int(line[0:2], 16)
        assert flags < 8
        hexs = line[3:]
        assert len(hexs) == 8
        chans = []
        for j in range(4):
            b = int(hexs[j * 2:j * 2 + 2], 16)
            chans.append(None if b & 0x40 else b & 0x3F)
        out.append({"flags": flags, "chans": chans})
    return out


def music_duration(sfx: list[dict], refs: list[int | None]) -> tuple[int | None, int | None]:
    """PICO 左首 nonloop 与 FC 最长 nonloop 的行时长，单位均为 FC audio tick。"""
    durations = [
        fc_speed(sfx[id]["speed"]) * sfx_length(sfx[id])
        for id in refs if id is not None and sfx[id]["loop_end"] <= sfx[id]["loop_start"]
    ]
    return (durations[0], max(durations)) if durations else (None, None)


def build_audio(cart: dict[str, str]) -> tuple[bytes, bytes, bytes, bytes, list[str]]:
    sfx = parse_sfx(cart)
    music_rows = parse_music(cart)
    blob = bytearray(128 * 144)
    for i, entry in enumerate(sfx):
        blob[i * 144:(i + 1) * 144] = encode_sfx(entry)
    instruments = bytearray(16 * 144)
    for i in range(8):
        instruments[i * 144:(i + 1) * 144] = encode_sfx(sfx[i], instrument=True)
    waves = bytes(8 * 80)  # 原作前八条均非 Waveform 模式，绝不从 SFX volume 伪造波形。

    # Row38 只有 channel2 的循环 SFX53；全循环 FC Row 不自然结束。
    # 按原曲 SFX53 的整段32步×130 PICO ticks×2，用空闲的原四轨 channel0 作静音节拍锚点。
    timer = 64 * 144
    blob[timer:timer + 2] = fc_speed(sfx[53]["speed"]).to_bytes(2, "little")
    blob[timer + 2] = 32
    assert fc_speed(sfx[53]["speed"]) * 32 == 8320

    music_blob = bytearray(32 + 64 * 32)
    music_blob[0] = max((
        i + 1 for i, row in enumerate(music_rows)
        if row["flags"] or any(ch is not None for ch in row["chans"])
    ), default=0)
    assert len(music_rows) == 42 and music_blob[0] == 42
    for i in range(64):
        base = 32 + i * 32
        music_blob[base:base + 8] = b"\xff" * 8
        if i >= len(music_rows):
            continue
        row = music_rows[i]
        pico_duration, fc_duration = music_duration(sfx, row["chans"])
        if i == 38:
            assert pico_duration is None and fc_duration is None
            fc_duration = 8320
        else:
            assert pico_duration == fc_duration, f"Music Row {i}: PICO {pico_duration} != FC {fc_duration}"
            assert fc_duration == ([704] * 36 + [8320, 8320, 8320, 704, 896, 1024])[i]
        for channel, source in enumerate(row["chans"]):
            if source is not None:
                music_blob[base + channel] = source
        music_blob[base + 16] = int(bool(row["flags"] & 1))
        music_blob[base + 17] = int(bool(row["flags"] & 2))
        music_blob[base + 18] = int(bool(row["flags"] & 4))
    music_blob[32 + 38 * 32] = 64
    summary = [
        f"{i}:{fc_speed(s['speed'])}/{sfx_length(s)}"
        for i, s in enumerate(sfx) if s["speed"] >= 130
    ]
    return bytes(blob), waves, bytes(instruments), bytes(music_blob), ["Long SFX: " + ", ".join(summary)]


# ---------------------------------------------------------------- 关卡

# (关卡号, 宽, 高)；与 gamestate.lua 的 levels 表一致
LEVELS = [(1, 96, 16), (2, 32, 32), (3, 128, 22), (4, 128, 32),
          (5, 128, 16), (6, 128, 16), (7, 128, 16), (8, 16, 62)]


def level_grid(idx: int, w: int, h: int) -> list[list[int]]:
    """关卡瓦片网格。

    __map__ 为地图行 0..N-1（128 格/行）；高度 > 32 时，后 32 行位于卡带 ROM
    0x1000 的共享区（.p8 文本里是 __gfx__ 的第 64 行起，每地图行 128 字节）。
    """
    sec = load_sections(SRC / f"{idx}.p8")
    mrows = rows(sec["map"])
    gfxdata = b"".join(rows(sec["gfx"]))
    grid = []
    for y in range(h):
        if y < len(mrows) and y < 32:
            row = mrows[y]
        else:
            off = 0x1000 + 128 * (y - 32)
            row = gfxdata[off:off + 128]
        grid.append(list(row[:w]) + [0] * max(0, w - len(row)))
    return grid


def build_levels() -> tuple[bytes, list[int]]:
    blob = bytearray()
    offsets = []
    for idx, w, h in LEVELS:
        grid = level_grid(idx, w, h)
        offsets.append(len(blob))
        for row in grid:
            for t in row:
                blob += struct.pack("<H", t & 0x0FFF)
    return bytes(blob), offsets


# ---------------------------------------------------------------- PNG 预览

def write_png(path: Path, width: int, height: int, rgb: bytes) -> None:
    raw = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def build_preview(cart: dict[str, str], sprites: bytes) -> None:
    pal = REPO / "assets" / "palette.dat"
    fc = [tuple(pal.read_bytes()[i * 3:i * 3 + 3]) for i in range(64)]
    # 只导出瓦片 0–127（16 列 × 8 行），每瓦片 1:1
    tex = bytearray(256 * 128 * 3)
    for n in range(128):
        tx = (n % 16) * 16
        ty = (n // 16) * 16
        for py in range(16):
            for px in range(16):
                c = fc[sprites[n * 256 + py * 16 + px]]
                off = ((ty + py) * 256 + tx + px) * 3
                tex[off:off + 3] = bytes(c)
    out = HERE / "assets" / "sheet.png"
    out.parent.mkdir(exist_ok=True)
    write_png(out, 256, 128, bytes(tex))
    print(f"预览：{out}")


# ---------------------------------------------------------------- 主流程

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true")
    args = ap.parse_args()

    cart = load_sections(SRC / "celeste2.p8")
    BUILD.mkdir(exist_ok=True)

    sprites = build_sprites(cart)
    sflags = build_sflags(cart)
    sfxb, waves, instruments, music_data, log = build_audio(cart)
    custom, offsets = build_levels()

    (BUILD / "sprites.bin").write_bytes(sprites)
    (BUILD / "sflags.bin").write_bytes(sflags)
    (BUILD / "sfx.bin").write_bytes(sfxb)
    (BUILD / "waveforms.bin").write_bytes(waves)
    (BUILD / "instruments.bin").write_bytes(instruments)
    (BUILD / "music.bin").write_bytes(music_data)
    (BUILD / "custom.bin").write_bytes(custom)
    # 卡带图标 = 玩家待机精灵（瓦片 2），16×16 8bpp
    (BUILD / "icon.bin").write_bytes(sprites[2 * 256:3 * 256])

    print("调色板定标：")
    for i in range(16):
        r, g, b = PICO_RGB[i]
        print(f"  PICO {i:2d} {COL_NAME[i]:<11} #{r:02x}{g:02x}{b:02x} → FC {COL[i]:2d}")
    print("关卡偏移（自定义数据段，字节）：")
    for (idx, w, h), off in zip(LEVELS, offsets):
        print(f"  level {idx}: {w}×{h} @ {off} (+{w*h*2})")
    for line in log:
        print("  " + line)
    print(f"sprites {len(sprites)}B, sflags {len(sflags)}B, sfx {len(sfxb)}B, "
          f"waveforms {len(waves)}B, instruments {len(instruments)}B, "
          f"music {len(music_data)}B, custom {len(custom)}B")
    if args.preview:
        build_preview(cart, sprites)
    return 0


if __name__ == "__main__":
    sys.exit(main())
