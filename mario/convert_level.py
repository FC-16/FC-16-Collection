#!/usr/bin/env python3
"""convert_level.py — 从 SuperMarioBros-C 反汇编（docs/smbdis.asm）解码关卡数据。

忠实实现 NES 版「区域对象 / 敌人对象」字节流的解析逻辑（对应反汇编中的
ProcessAreaData / DecodeAreaData / 各对象子例程与 ProcessEnemyData），
把 World 1-1 / 1-2 / 1-3 / 1-4 / 奖励房的布局与敌人布点转写为
demo/mario/mario.lua 的 LEVEL 表所需的描述性输出。

用法：
    python3 convert_level.py                 # 解码全部世界 1 关卡并打印
    python3 convert_level.py L_GroundArea7   # 只解码指定区域

数据来源（参考仓库，gitignore 于 G:/github/_ref/SuperMarioBros-C）：
    https://github.com/MitchellSternke/SuperMarioBros-C
"""

import re
import sys
from pathlib import Path

REF_ASM = Path(r"G:/github/_ref/SuperMarioBros-C/docs/smbdis.asm")

# ---------------------------------------------------------------- 数据提取

def load_labels():
    """解析 .db 数据段，返回 {标签: [bytes]}（按文件顺序拼接同名/无名连续段）。"""
    data = REF_ASM.read_text(encoding="utf-8", errors="replace")
    labels = {}
    order = []
    cur = None
    pending = None  # 位于注释行之后、无标签的连续段并入上一标签
    for line in data.splitlines():
        s = line.split(";", 1)[0].strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):$", s)
        if m:
            cur = m.group(1)
            if cur not in labels:
                labels[cur] = []
                order.append(cur)
            continue
        if not s:
            continue
        m = re.match(r"^\.db\s+(.*)$", s)
        if m and cur:
            for tok in m.group(1).split(","):
                tok = tok.strip()
                mm = re.match(r"^\$([0-9A-Fa-f]{1,2})$", tok)
                if mm:
                    labels[cur].append(int(mm.group(1), 16))
                elif tok.startswith("<") or tok.startswith(">"):
                    labels[cur].append(("ref", tok[1:]))
                else:
                    labels[cur].append(("sym", tok))
    return labels, order


# ---------------------------------------------------------------- 常量表

# MusicLengthLookupTbl 不在本文件使用；下面是关卡解码所需的反汇编常量表。
TERRAIN_BITS = [
    (0b00000000, 0b00000000), (0b00000000, 0b00011000), (0b00000001, 0b00011000),
    (0b00000111, 0b00011000), (0b00001111, 0b00011000), (0b11111111, 0b00011000),
    (0b00000001, 0b00011111), (0b00000111, 0b00011111), (0b00001111, 0b00011111),
    (0b10000001, 0b00011111), (0b00000001, 0b00000000), (0b10001111, 0b00011111),
    (0b11110001, 0b00011111), (0b11111001, 0b00011000), (0b11110001, 0b00011000),
    (0b11111111, 0b00011111),
]

# 敌人对象 ID → 名称（反汇编常量定义）
ENEMY_NAMES = {
    0x00: "greenKoopa", 0x01: "greenKoopa(shell)", 0x02: "buzzyBeetle",
    0x03: "redKoopa", 0x05: "hammerBro", 0x06: "goomba", 0x07: "bloober",
    0x08: "bulletBill", 0x0a: "greyCheep", 0x0b: "redCheep", 0x0c: "podoboo",
    0x0d: "piranhaPlant", 0x0e: "paraKoopa(jump)", 0x0f: "redParaKoopa",
    0x10: "paraKoopa(fly)", 0x11: "lakitu", 0x12: "spiny",
    0x14: "flyCheep", 0x15: "bowserFlame", 0x16: "fireworks",
    0x17: "bbillCheepFrenzy", 0x18: "stopFrenzy", 0x1b: "firebar-$1b",
    0x1c: "firebar-$1c", 0x1d: "firebar-$1d", 0x1e: "firebar-$1e",
    0x1f: "firebar-long", 0x2d: "bowser", 0x2e: "powerUp", 0x2f: "vine",
    0x30: "flagpoleFlag", 0x31: "starFlag", 0x32: "jumpspring",
    0x33: "bulletBillCannon", 0x35: "retainer(princess)",
}

LARGE_NAMES = {0: "pipe", 1: "areaStyle", 2: "rowBrick", 3: "rowSolid",
               4: "rowCoin", 5: "colBrick", 6: "colSolid", 7: "pipeDeco"}
ROW12_NAMES = {0: "hole", 1: "pulleyRope", 2: "bridgeHigh", 3: "bridgeMid",
               4: "bridgeLow", 5: "holeWater", 6: "qRowHigh", 7: "qRowLow"}
ROW15_NAMES = {0: "endlessRope", 1: "balanceRope", 2: "castle", 3: "staircase",
               4: "exitPipe", 5: "flagBalls"}
SMALL_NAMES = {0: "Q(power)", 1: "Q(coin)", 2: "Q(hidden coin)", 3: "hidden1UP",
               4: "brick(power)", 5: "brick(vine)", 6: "brick(star)",
               7: "brick(coins)", 8: "brick(1UP)", 9: "waterPipe",
               10: "emptyBlock", 11: "jumpspring"}
ROW13_NAMES = {0: "introPipe", 1: "flagpole", 2: "axe", 3: "chain", 4: "castleBridge",
               5: "scrollLockWarp", 6: "scrollLock", 7: "scrollLock",
               8: "frenzyFlyCheep", 9: "frenzyBBill", 10: "frenzyStop", 11: "loopCmd"}


# ---------------------------------------------------------------- 区域解码

def decode_area(bytes_):
    """按 DecodeAreaData 逐对象解码，返回对象字典列表（页内 X 与绝对 X）。"""
    objs = []
    page = 0
    page_sel = False
    y = 0
    n = len(bytes_)
    while y < n:
        b1 = bytes_[y]
        if b1 == 0xFD:
            break
        y += 1
        b2 = bytes_[y] if y < n else 0
        y += 1
        page_sel = False  # IncAreaObjOffset：每个对象处理后清零页选择
        x_in_page = b1 >> 4
        row = b1 & 0x0F
        page_flag = (b2 & 0x80) != 0
        if page_flag and not page_sel:
            page += 1
            page_sel = True
        o = {"page": page, "x_in_page": x_in_page, "x": page * 16 + x_in_page,
             "row": row, "b2": b2}
        if row == 0x0D:
            if b2 & 0x40:  # d6 置位 = 行 13 特殊对象
                oid = b2 & 0x3F
                if (b2 & 0x7F) == 0x4B:
                    o["obj"] = "loopCmd"
                else:
                    o["obj"] = ROW13_NAMES.get(oid, "row13-%02x" % oid)
            else:  # 页控制：byte2 低 5 位直接设定页号
                page = b2 & 0x1F
                page_sel = True
                o["obj"] = "pageCtrl"
                o["to_page"] = page
                o["x"] = page * 16
            objs.append(o)
            continue
        if row == 0x0E:
            o["obj"] = "alterAttrs"
            o["terrain"] = b2 & 0x0F
            o["bgScenery"] = (b2 >> 4) & 0x03
            o["fgScenery"] = b2 & 0x07 if (b2 & 0x40) else None
            o["bgColor"] = b2 & 0x07 if (b2 & 0x40) else None
            objs.append(o)
            continue
        if row >= 0x0C:  # 行 12 与 15 的特殊对象
            oid = (b2 & 0x70) >> 4
            o["len"] = b2 & 0x0F
            o["obj"] = (ROW12_NAMES if row == 0x0C else ROW15_NAMES).get(
                oid, "spec-%02x" % oid)
            if row == 0x0C and oid == 0 and (b2 & 0x08):
                pass  # 行 12 的 d3 用法位仅用于管状对象，此处无意义
        elif (b2 & 0x70) != 0:  # 普通行的大对象
            oid = (b2 & 0x70) >> 4
            o["len"] = b2 & 0x0F
            if oid in (0, 7):
                o["obj"] = "warpPipe" if (b2 & 0x08) else "pipe"
                o["pipe_id"] = oid
            else:
                o["obj"] = LARGE_NAMES.get(oid, "large-%02x" % oid)
        else:  # 小对象
            oid = b2 & 0x0F
            o["obj"] = SMALL_NAMES.get(oid, "small-%02x" % oid)
            o["len"] = 1
        objs.append(o)
    return objs


def decode_enemies(bytes_):
    """按 ProcessEnemyData 解码敌人布点。"""
    ents = []
    page = 0
    page_sel = False
    y = 0
    n = len(bytes_)
    while y < n:
        b1 = bytes_[y]
        if b1 == 0xFF:
            break
        y += 1
        b2 = bytes_[y] if y < n else 0
        y += 1
        page_sel = False  # 每个敌人对象处理后清零页选择
        row = b1 & 0x0F
        if row == 0x0E:  # 三字节「进入区域」命令
            b3 = bytes_[y] if y < n else 0
            y += 1
            ents.append({"obj": "enterArea", "x": page * 16 + (b1 >> 4),
                         "area": b2 & 0x1F, "world": b3 >> 5, "page": b3 & 0x1F})
            continue
        if row == 0x0F:  # 页控制
            if not page_sel:
                page = b2 & 0x3F
                page_sel = True
                ents.append({"obj": "pageCtrl", "to_page": page})
            continue
        if (b2 & 0x80) and not page_sel:
            page += 1
            page_sel = True
        x = page * 16 + (b1 >> 4)
        oid = b2 & 0x3F
        if 0x37 <= oid <= 0x3E:
            # HandleGroupEnemies：$37-$3a 栗子怪成组（d1=1 抬高一行、d0=1 三只），
            # $3b-$3e 绿龟成组；组内间距 24px
            base = oid - 0x37
            high = bool(base & 2)
            cnt = 3 if (base & 1) else 2
            kind = "koopaGroup" if base >= 4 else "goombaGroup"
            e = {"obj": f"{kind}x{cnt}{'@high' if high else ''}",
                 "id": oid, "x": x, "y": 112 if high else 176, "page": page,
                 "spacing": 24}
        else:
            e = {"obj": ENEMY_NAMES.get(oid, "enemy-%02x" % oid),
                 "id": oid, "x": x, "y": row * 16, "page": page}
        e["hard_only"] = bool(b2 & 0x40)
        ents.append(e)
    return ents


def terrain_rows(ctl):
    """地形模式位 → 行集合（行 0-12）。"""
    hi, lo = TERRAIN_BITS[ctl & 0x0F]
    bits = [(hi >> (7 - i)) & 1 for i in range(8)] + [(lo >> (7 - i)) & 1 for i in range(5)]
    return [i for i, b in enumerate(bits) if b]


# ---------------------------------------------------------------- 报告

def emit_area_header(lv, name, data):
    print(f"  头: {data[0]:02x} {data[1]:02x}  计时设置={data[0]>>6} "
          f"入场控制={(data[0]>>3)&7} 前景={data[0]&7} "
          f"地形={data[1]&0xf} 背景景致={(data[1]>>4)&3} 风格={data[1]>>6}")
    rows = terrain_rows(data[1] & 0x0F)
    print(f"  固有地形行: {rows}")


def expand(objs):
    """把行/列/坑展开成逐格清单，便于核对。"""
    grid = {}   # (x,row) -> label
    holes = []  # (x, width)
    items = []
    for o in objs:
        k = o["obj"]
        if k in ("rowBrick", "rowSolid", "rowCoin", "qRowHigh", "qRowLow"):
            tile = {"rowBrick": "B", "rowSolid": "S", "rowCoin": "o",
                    "qRowHigh": "Q", "qRowLow": "Q"}[k]
            r = {"qRowHigh": 3, "qRowLow": 7}.get(k, o["row"])
            for i in range(o["len"] + 1):
                grid[(o["x"] + i, r)] = tile
        elif k in ("colBrick", "colSolid"):
            tile = "B" if k == "colBrick" else "S"
            for i in range(o["len"] + 1):
                grid[(o["x"], o["row"] + i)] = tile
        elif k in ("hole", "holeWater"):
            holes.append((o["x"], o["len"] + 1, k))
        elif k == "pipe" or k == "warpPipe" or k == "pipeDeco":
            items.append((o["x"], o["row"], k, "h=%d" % (min(o["len"], 3) + 1)))
        elif k == "staircase":
            items.append((o["x"], o["row"], k, "len=%d" % o["len"]))
        else:
            items.append((o["x"], o["row"], k,
                          "len=%d" % o.get("len", 0) if "len" in o else ""))
    return grid, holes, items


def report(label, labels, only=None):
    if only and label not in only:
        return
    data = labels.get(label)
    if data is None or any(isinstance(b, tuple) for b in data):
        print(f"== {label}: 无纯字节数据 ==")
        return
    print(f"== {label} ({len(data)}B) ==")
    emit_area_header(label, data, data)
    objs = decode_area(data[2:])
    for o in objs:
        print("   ", o)
    grid, holes, items = expand(objs)
    if holes:
        print("  坑:", holes)
    if items:
        print("  其他对象:", items)
    # 敌人数据
    elabel = label.replace("L_", "E_", 1)
    edata = labels.get(elabel)
    if edata and not any(isinstance(b, tuple) for b in edata):
        print(f"  -- 敌人 {elabel} ({len(edata)}B) --")
        for e in decode_enemies(edata):
            print("   ", e)
    print()


# World 1 使用的数据区（反汇编注释与指针表核对）：
#   1-1 主区 L_GroundArea6 / 1-1 奖励房 L_UndergroundArea3（5 段共用）
#   1-2 主区 L_UndergroundArea1 / 1-2 奖励房 L_UndergroundArea2
#   1-3 主区 L_GroundArea7
#   1-4 主区 L_CastleArea1
def main():
    labels, _ = load_labels()
    only = set(sys.argv[1:]) or None
    for lb in ["L_GroundArea6", "L_UndergroundArea3", "L_UndergroundArea1",
               "L_UndergroundArea2", "L_GroundArea7", "L_CastleArea1"]:
        report(lb, labels, only)


if __name__ == "__main__":
    main()
