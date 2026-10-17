#!/usr/bin/env python3
"""Cave Story → FC-16 资产转换器（截面：出生洞/初始洞窟/咪咪村/亚瑟之家）。

输入：原版免费版 data 目录 + assets/stage_table.json + assets/npc_rects.json
输出：build/{sprites,maps,sflags,sfx,waveforms,custom}.bin + build/csdata.lua

约定：
- CS 调色板中 RGB==(0,0,0) 的像素 → FC-16 色号 0（透明）；其余像素最近色匹配且不落到 0 号
- 瓦片集整块放在图集行边界上（16 列对齐），tile i 的图集瓦片号 = 基址 + i
- sflags 位定义：bit0 实心；bit1..3 斜坡码 1..8（0x50..0x57 / 0x70..0x77）；bit4 尖刺
- 地图平面布局：Start(0,0) 21×16；Cave(0,16) 60×45；Mimi(64,0) 60×60；Pole(24,0) 21×16
"""

import json
import struct
import argparse
import sys
from pathlib import Path

DATA = None
HERE = Path(__file__).resolve().parent.parent
ASSETS, BUILD = HERE / "assets", HERE / "build"

# SPEC §2.2 ENDESGA-64，FC-16 顺序（8×8 行优先）
FC_PALETTE = [
    0x131313, 0x1B1B1B, 0x272727, 0x3D3D3D, 0x5D5D5D, 0x858585, 0xB4B4B4, 0xFFFFFF,
    0xC7CFDD, 0x92A1B9, 0x657392, 0x424C6E, 0x2A2F4E, 0x1A1932, 0x0E071B, 0x1C121C,
    0x391F21, 0x5D2C28, 0x8A4836, 0xBF6F4A, 0xE69C69, 0xF6CA9F, 0xF9E6CF, 0xEDAB50,
    0xE07438, 0xC64524, 0x8E251D, 0xFF5000, 0xED7614, 0xFFA214, 0xFFC825, 0xFFEB57,
    0xD3FC7E, 0x99E65F, 0x5AC54F, 0x33984B, 0x1E6F50, 0x134C4C, 0x0C2E44, 0x00396D,
    0x0069AA, 0x0098DC, 0x00CDF9, 0x0CF1FF, 0x94FDFF, 0xFDD2ED, 0xF389F5, 0xDB3FFD,
    0x7A09FA, 0x3003D9, 0x0C0293, 0x03193F, 0x3B1443, 0x622461, 0x93388F, 0xCA52C9,
    0xC85086, 0xF68187, 0xF5555D, 0xEA323C, 0xC42430, 0x891E2B, 0x571C27, 0xFF0040,
]
FC_RGB = [((c >> 16) & 255, (c >> 8) & 255, c & 255) for c in FC_PALETTE]

STAGES = {  # 保留原版 stage 表编号
    13: dict(map="Start", ts="Cave", px=0, py=0, bg=0, name="出生洞窟"),
    12: dict(map="Cave", ts="Cave", px=0, py=16, bg=0, name="初始洞窟"),
    11: dict(map="Mimi", ts="Mimi", px=64, py=0, bg=1, name="咪咪村庄"),
    90: dict(map="Pole", ts="Cave", px=24, py=0, bg=0, name="亚瑟的之家"),
}
KEEP_TYPES = {0, 1, 15, 16, 17, 18, 21, 37, 39, 42, 60, 61, 64, 65, 74, 78, 79, 211}
# 截面剧情裁剪：删除依赖原版剧情旗标的重复变体实体（关卡号 → (tile x, tile y)）
DROP_SPAWNS = {(90, (10, 8)), (11, (14, 34)), (11, (12, 34)),
               (12, (51, 12)), (12, (53, 11)), (12, (54, 11))}  # 眼之门秘室的持枪前敌人
SOLID_ATTR = {0x05, 0x41, 0x43, 0x46}
SPIKE_ATTR = {0x42, 0x62}
SLOPE_ATTR = {0x50: 1, 0x51: 2, 0x52: 3, 0x53: 4, 0x54: 5, 0x55: 6, 0x56: 7, 0x57: 8,
              0x70: 1, 0x71: 2, 0x72: 3, 0x73: 4, 0x74: 5, 0x75: 6, 0x76: 7, 0x77: 8}

# 各精灵所属 CS 精灵表与要打包的帧清单（name, sheet, key）
SHEET_FILES = {
    "mychar": DATA / "MyChar.pbm",
    "cemet": DATA / "Npc/NpcCemet.pbm",
    "guest": DATA / "Npc/NpcGuest.pbm",
    "regu": DATA / "Npc/NpcRegu.pbm",
    "sym": DATA / "Npc/NpcSym.pbm",
    "bullet": DATA / "Bullet.pbm",
    "caret": DATA / "Caret.pbm",
}

def load_bmp(path: Path):
    d = path.read_bytes()
    assert d[:2] == b"BM", path
    off = struct.unpack_from("<I", d, 10)[0]
    w, h = struct.unpack_from("<ii", d, 18)
    bpp = struct.unpack_from("<H", d, 28)[0]
    assert bpp in (1, 2, 4, 8), f"{path}: {bpp}bpp 不支持"
    ncol = 1 << bpp
    pal = [(d[54 + i * 4 + 2], d[54 + i * 4 + 1], d[54 + i * 4]) for i in range(ncol)]
    w, h = abs(w), abs(h)
    stride = ((w * bpp + 31) // 32) * 4
    rows = []
    for ry in range(h):
        src = off + ry * stride
        row = bytearray(w)
        if bpp == 8:
            row = bytearray(d[src:src + w])
        else:
            for i in range(w):
                byte = d[src + (i * bpp) // 8]
                shift = 8 - bpp - ((i * bpp) % 8)
                row[i] = (byte >> shift) & ((1 << bpp) - 1)
        rows.append(row)
    rows.reverse()  # bottom-up → top-down
    return w, h, pal, rows

class Quantizer:
    def __init__(self):
        self.cache = {}

    def index(self, rgb):
        if rgb in self.cache:
            return self.cache[rgb]
        if rgb == (0, 0, 0):
            idx = 0
        else:
            best, bd = 1, 1 << 30
            for i, fc in enumerate(FC_RGB):
                if i == 0:
                    continue
                dr, dg, db = rgb[0] - fc[0], rgb[1] - fc[1], rgb[2] - fc[2]
                dist = dr * dr + dg * dg + db * db
                if dist < bd:
                    best, bd = i, dist
            idx = best
        self.cache[rgb] = idx
        return idx

Q = Quantizer()

class Atlas:
    def __init__(self):
        self.pix = bytearray(256 * 1024)  # 256×1024 8bpp
        self.first_free_row = 0           # 瓦片集从第 0 行开始占位
        self.cursor_col = 0
        self.slots = {}                   # key → (px, py)

    def blit(self, x, y, w, h, rows, pal, src_x, src_y):
        # FC-16 精灵段为瓦片优先布局（SPEC §4.1）：瓦片 t 连续占 t*256..t*256+255，
        # 瓦片内 16×16 行优先（j*16+i）。(x,y) 为 16 对齐的图集像素坐标。
        assert x % 16 == 0 and y % 16 == 0, "图集槽位须 16 对齐"
        for j in range(h):
            row = rows[src_y + j]
            tj, py = (y + j) // 16, (y + j) % 16
            for i in range(w):
                ti, px = (x + i) // 16, (x + i) % 16
                tile = tj * 16 + ti
                self.pix[tile * 256 + py * 16 + px] = Q.index(pal[row[src_x + i]])

    def alloc(self, key, w, h):
        if key in self.slots:
            return self.slots[key]
        tw, th = (w + 15) // 16, (h + 15) // 16
        if self.cursor_col + tw > 16:
            self.first_free_row += 1
            self.cursor_col = 0
        x, y = self.cursor_col * 16, self.first_free_row * 16
        self.cursor_col += tw
        self.slots[key] = (x, y)
        return x, y

ATLAS = Atlas()

def pack_tileset(name, ts_name):
    w, h, pal, rows = load_bmp(DATA / f"Stage/Prt{ts_name}.pbm")
    assert w == 256 and h % 16 == 0
    base_row = 0 if ts_name == "Cave" else (ATLAS.slots.get(("ts", "Cave")) or [0, 0])[0] // 256 + 80 // 16
    return w, h, pal, rows

def main():
    BUILD.mkdir(exist_ok=True)
    stage_table = {e["index"]: e for e in json.load(open(ASSETS / "stage_table.json"))}
    npc_rects = json.load(open(ASSETS / "npc_rects.json"))

    # ─── 1. 瓦片集：整块占用行边界 ───
    ts_base, ts_rows = {}, 0
    ts_pixels = {}
    for ts_name in ["Cave", "Mimi"]:
        w, h, pal, rows = load_bmp(DATA / f"Stage/Prt{ts_name}.pbm")
        assert ATLAS.first_free_row == ts_rows and ATLAS.cursor_col == 0
        ATLAS.blit(0, ts_rows * 16, w, h, rows, pal, 0, 0)
        ts_base[ts_name] = ts_rows * 16
        ts_pixels[ts_name] = (w, h, pal, rows)
        ts_rows += h // 16
        ATLAS.first_free_row = ts_rows
    print(f"瓦片集: Cave 基址 {ts_base['Cave']}（{80//16} 行）, Mimi 基址 {ts_base['Mimi']}（{160//16} 行），占用 {ts_rows} 行")

    # ─── 2. 精灵矩形打包 ───
    sheets = {}
    for k, p in SHEET_FILES.items():
        sheets[k] = load_bmp(p)

    manifest = {}

    def pack(key, sheet, rect):
        l, t, r, b = rect
        w, h = r - l, b - t
        x, y = ATLAS.alloc((sheet, rect), w, h)
        ATLAS.blit(x, y, w, h, sheets[sheet][3], sheets[sheet][2], l, t)
        manifest.setdefault(key, []).append((x, y, w, h))

    # MyChar 整表（含 4 行姿态 + 星星）
    mc = sheets["mychar"]
    ATLAS.alloc(("mychar", "block"), 208, 64)
    x0, y0 = ATLAS.slots[("mychar", "block")]
    ATLAS.blit(x0, y0, 200, 64, mc[3], mc[2], 0, 0)
    manifest["mychar"] = [(x0, y0, 200, 64)]

    # NPC 帧：type → (sheet, npcs.rs 键)
    NPC_PACK = [
        (1, "sym", "n001_experience"), (4, "sym", "n004_smoke"),
        (15, "sym", "n015_closed_chest"), (16, "sym", "n016_save_point"),
        (17, "sym", "n017_health_refill"), (18, "sym", "n018_door"),
        (37, "sym", "n037_sign"), (39, "sym", "n039_save_sign"),
        (42, "regu", "n042_sue"), (60, "regu", "n060_toroko"), (61, "regu", "n061_king"),
        (64, "cemet", "n064_first_cave_critter"), (65, "cemet", "n065_first_cave_bat"),
        (74, "guest", "n074_jack"), (78, "sym", "n078_pot"), (79, "guest", "n079_mahin"),
        (211, "sym", "n211_small_spikes"),
    ]
    for t, sheet, key in NPC_PACK:
        rects = npc_rects[key]
        for rect in rects:
            if rect[2] - rect[0] == 1:  # smoke 的 1px 占位帧跳过
                continue
            pack(f"npc{t}", sheet, tuple(rect))

    # 枪匠（Pole 用 Guest 表）
    for rect in npc_rects["n030_hermit_gunsmith"]:
        pack("npc30", "guest", tuple(rect))

    # 子弹（Polar Star L1/L2/L3，横/竖）
    for key, rect in [("b4h", (128, 32, 144, 48)), ("b4v", (144, 32, 160, 48)),
                      ("b5h", (160, 32, 176, 48)), ("b5v", (176, 32, 192, 48)),
                      ("b6h", (128, 48, 144, 64)), ("b6v", (144, 48, 160, 64))]:
        pack(key, "bullet", rect)

    # Caret：枪口焰 4 帧 / 弹丸消散 4 帧(8×8) / 升级 2 帧(56×16)
    for i, rect in enumerate([(0, 48, 16, 64), (16, 48, 32, 64), (32, 48, 48, 64), (48, 48, 64, 64)]):
        pack("caret_shoot", "caret", rect)
    for i, rect in enumerate([(0, 72, 8, 80), (8, 72, 16, 80), (16, 72, 24, 80), (24, 72, 32, 80)]):
        pack("caret_diss", "caret", rect)
    for i, rect in enumerate([(0, 0, 56, 16), (0, 16, 56, 32)]):
        pack("caret_level", "caret", rect)

    (BUILD / "sprites.bin").write_bytes(ATLAS.pix)
    print(f"图集: 约占用 {ATLAS.first_free_row + 1} 行（瓦片优先布局）")

    # ─── 3. 地图平面 ───
    map_bin = bytearray(128 * 1024)
    spawns_out = {}
    for sid, meta in STAGES.items():
        pxm = (DATA / f"Stage/{meta['map']}.pxm").read_bytes()
        w, h = struct.unpack_from("<HH", pxm, 4)
        base = ts_base[meta["ts"]]
        for j in range(h):
            for i in range(w):
                t = pxm[8 + j * w + i]
                cell = base + t
                off = ((meta["py"] + j) * 256 + meta["px"] + i) * 2
                map_bin[off] = cell & 0xFF
                map_bin[off + 1] = (cell >> 8) & 0x03
        print(f"stage {sid} {meta['map']}: {w}×{h} → 平面({meta['px']},{meta['py']})")
        if sid == 12:
            # 截面改图：凿开眼之门秘室左侧岩壁（col 47, rows 9-12），
            # 原版秘室仅能从咪咪村侧进入，这里让洞窟→村庄双向可通行
            for j in range(9, 13):
                off = (((meta["py"] + j) * 256) + meta["px"] + 47) * 2
                map_bin[off] = 0
                map_bin[off + 1] = 0

        # 实体布点（过滤 + flag 门控交给运行时）
        pxe = (DATA / f"Stage/{meta['map']}.pxe").read_bytes()
        ver = pxe[3]
        (count,) = struct.unpack_from("<I", pxe, 4)
        step = 13 if ver == 0x10 else 12
        lst = []
        for n in range(count):
            x, y, flag, ev, typ, fl = struct.unpack_from("<hhHHHH", pxe, 8 + n * step)
            if typ not in KEEP_TYPES:
                continue
            if ev == 0 and typ == 0:
                continue
            if (sid, (x, y)) in DROP_SPAWNS:
                continue
            lst.append(dict(x=x, y=y, t=typ, ev=ev, fl=flag, bf=fl))
        spawns_out[sid] = lst

    (BUILD / "maps.bin").write_bytes(map_bin)

    # ─── 4. sflags（实心 / 斜坡 / 尖刺）───
    sflags = bytearray(2048)   # SPEC §4.2：2048 精灵 × 8bit
    for ts_name in ["Cave", "Mimi"]:
        pxa = (DATA / f"Stage/{ts_name}.pxa").read_bytes()
        base = ts_base[ts_name]
        for t in range(256):
            a = 0 if t == 0 else (pxa[t] if t < len(pxa) else 0)  # PXM 0 号 = 空气
            f = 0
            if a in SOLID_ATTR:
                f |= 1
            if a in SLOPE_ATTR:
                f |= SLOPE_ATTR[a] << 1
            if a in SPIKE_ATTR:
                f |= 16
            sflags[base + t] = f
    (BUILD / "sflags.bin").write_bytes(sflags)

    # ─── 5. 背景：bkBlue 量化平铺 256×256 → 自由区；bk0 取主色 ───
    free = bytearray()
    bg_meta = {}
    w, h, pal, rows = load_bmp(DATA / "bkBlue.pbm")
    tile = bytearray(64 * 64)
    for j in range(64):
        row = rows[j]
        for i in range(64):
            tile[j * 64 + i] = Q.index(pal[row[i]])
    for ty in range(4):
        for tx in range(4):
            for j in range(64):
                free += tile[j * 64:(j + 1) * 64]
    bg_meta["bkblue"] = 0

    w, h, pal, rows = load_bmp(DATA / "bk0.pbm")
    from collections import Counter
    c = Counter()
    for j in range(0, h, 4):
        row = rows[j]
        for i in range(0, w, 4):
            c[Q.index(pal[row[i]])] += 1
    bg_meta["bk0_color"] = c.most_common(1)[0][0]
    print(f"bk0 主色: FC-{bg_meta['bk0_color']}")
    (BUILD / "custom.bin").write_bytes(free)
    print(f"自由区: {len(free)} B / 236640B")

    # ─── 6. SFX 合成（144B/条）───
    def sfx(speed, steps, loop=False):
        head = max(1, speed * 4).to_bytes(2, "little") + bytes([
            len(steps), 0, len(steps) - 1 if loop else 0, 1 if loop else 0]) + bytes(10)
        body = b""
        for pitch, wv, vol, eff in steps:
            source = {8: 9, 11: 8, 14: 6, 15: 6, 6: 5}.get(wv, wv)
            body += bytes([min(95, max(0, pitch - 1)), source, vol, eff])
        return head + body

    S = []
    S.append(sfx(1, [(88, 3, 5, 0)]))                                        # 0 文本滴声
    S.append(sfx(1, [(84, 3, 8, 0), (91, 3, 8, 0), (96, 3, 8, 0)]))          # 1 经验拾取
    S.append(sfx(1, [(72, 3, 9, 3), (60, 3, 9, 3), (48, 3, 7, 3)]))          # 2 射击 L1/L2
    S.append(sfx(1, [(79, 4, 11, 3), (67, 4, 11, 3), (55, 4, 9, 3)]))        # 3 射击 L3
    S.append(sfx(1, [(90, 15, 10, 0), (80, 15, 8, 0)]))                      # 4 命中
    S.append(sfx(1, [(72, 14, 12, 3), (60, 14, 11, 3), (48, 14, 9, 3), (36, 14, 8, 3)]))  # 5 敌人死亡
    S.append(sfx(1, [(55, 2, 12, 3), (43, 2, 11, 3), (31, 2, 10, 3)]))       # 6 玩家受伤
    S.append(sfx(1, [(60, 3, 7, 1), (72, 3, 7, 0)]))                         # 7 跳跃
    S.append(sfx(1, [(74, 3, 8, 2), (74, 3, 8, 0)]))                         # 8 跳跳虫叫
    S.append(sfx(1, [(33, 11, 10, 0)]))                                      # 9 落地闷响
    S.append(sfx(1, [(41, 3, 10, 1), (53, 3, 10, 0)]))                       # 10 开门
    S.append(sfx(2, [(72, 6, 9, 0), (76, 6, 9, 0), (79, 6, 9, 0), (84, 6, 9, 0)]))      # 11 获得道具
    S.append(sfx(1, [(84, 8, 6, 0)]))                                        # 12 水晶落地
    S.append(sfx(2, [(72, 6, 9, 0), (79, 6, 9, 0), (84, 6, 10, 0)]))         # 13 存档
    S.append(sfx(2, [(72, 3, 10, 0), (76, 3, 10, 0), (79, 3, 10, 0), (84, 3, 10, 0), (88, 3, 10, 0), (91, 3, 10, 0)]))  # 14 升级
    S.append(sfx(1, [(40, 15, 6, 0)]))                                       # 15 空枪咔哒
    sfx_bin = bytearray(128 * 144)
    for i, s in enumerate(S):
        assert len(s) <= 144, f"sfx{i} 超长"
        sfx_bin[i * 144:i * 144 + len(s)] = s
    (BUILD / "sfx.bin").write_bytes(sfx_bin)
    waveforms = bytearray(8 * 80)
    for i, levels in enumerate((
        [7,9,11,12,13,14,15,15,15,14,13,12,10,9,9,8,7,7,6,6,5,3,2,1,0,0,0,1,2,3,4,6],
        [8,9,10,12,13,14,14,15,15,15,14,14,13,12,10,9,8,6,5,3,2,1,1,0,0,0,1,1,2,3,5,6],
    )):
        waveforms[i * 80 + 16:i * 80 + 80] = bytes(
            (level * 17 - 128) & 0xFF for level in levels for _ in range(2))
    (BUILD / "waveforms.bin").write_bytes(waveforms)
    print(f"SFX: {len(S)} 条")

    # ─── 6.5 NPC 属性表（npc.tbl：24B 条目，列优先）───
    tbl = (DATA / "npc.tbl").read_bytes()
    n = len(tbl) // 0x18
    # 列优先（SoA）：flags(u16)×n | life(u16)×n | sheet(u8)×n | death(u8)×n | hurt(u8)×n
    #             | size(u8)×n | exp(u32)×n | dmg(u32)×n | hit(4B)×n | disp(4B)×n
    flags_c = [struct.unpack_from("<H", tbl, i * 2)[0] for i in range(n)]
    life_c = [struct.unpack_from("<H", tbl, n * 2 + i * 2)[0] for i in range(n)]
    exp_c = [struct.unpack_from("<I", tbl, n * 8 + i * 4)[0] for i in range(n)]
    dmg_c = [struct.unpack_from("<I", tbl, n * 12 + i * 4)[0] for i in range(n)]
    hb_c = [tuple(tbl[n*16+i*4:n*16+i*4+4]) for i in range(n)]
    dp_c = [tuple(tbl[n*20+i*4:n*20+i*4+4]) for i in range(n)]
    # 半像素 → 像素（碰撞/显示盒）；经验值上限 255
    stats = {0: dict(life=1, dmg=0, exp=0, invul=True, hb=[5, 8, 5, 8], dp=[8, 8, 8, 8])}
    for t in sorted(KEEP_TYPES):
        if t == 0:
            continue
        hb = [max(1, v // 2) for v in hb_c[t]]
        dp = [v // 2 for v in dp_c[t]]
        stats[t] = dict(life=life_c[t], dmg=dmg_c[t], exp=min(255, exp_c[t]),
                        invul=(flags_c[t] & 0x04) != 0, hb=hb, dp=dp)

    # ─── 7. 生成 csdata.lua ───
    def lua_tab(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return str(v)
        if isinstance(v, str):
            return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
        if isinstance(v, dict):
            items = []
            for k, val in v.items():
                if isinstance(k, str) and k.isidentifier():
                    items.append(f"{k}={lua_tab(val)}")
                else:
                    items.append(f"[{k}]={lua_tab(val)}")
            return "{" + ",".join(items) + "}"
        if isinstance(v, (list, tuple)):
            return "{" + ",".join(lua_tab(x) for x in v) + "}"
        raise TypeError(v)

    out = ["-- 由 tools/cs_build.py 生成，请勿手改", "return {"]
    out.append("atlas=" + lua_tab(manifest) + ",")
    out.append("bg=" + lua_tab(bg_meta) + ",")
    out.append("stages={" + ",".join(
        f"[{sid}]={lua_tab(dict(px=m['px'], py=m['py'], w=0, h=0, bg=m['bg'], name=m['name']))}"
        for sid, m in STAGES.items()) + "},")
    # 地图实际尺寸补进 stages
    dims = {}
    for sid, meta in STAGES.items():
        pxm = (DATA / f"Stage/{meta['map']}.pxm").read_bytes()
        w, h = struct.unpack_from("<HH", pxm, 4)
        dims[sid] = (w, h)
    out.append("dims={" + ",".join(f"[{sid}]={lua_tab(d)}" for sid, d in dims.items()) + "},")
    out.append("spawns={" + ",".join(f"[{sid}]={lua_tab(l)}" for sid, l in spawns_out.items()) + "},")
    out.append("stats=" + lua_tab(stats) + ",")
    out.append("}")
    (BUILD / "csdata.lua").write_text("\n".join(out), encoding="utf-8")
    print("csdata.lua 生成完毕")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True, help="原版 Doukutsu/data 目录")
    DATA = parser.parse_args().data
    main()
