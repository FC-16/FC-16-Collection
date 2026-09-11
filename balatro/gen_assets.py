#!/usr/bin/env python3
# 小丑牌（Balatro）FC-16 卡带资产生成器
# 产出：sprites.bin（256×1024 精灵表）、icon.bin（256B 8bpp 图标）、
#       sfx.bin（128×112B）、patterns.bin（64×16B）
#
# 精灵表像素布局（Lua 侧 sspr 使用同一坐标，改动需两处同步）：
#   行 0   16×16 UI 图标：0 空闲｜(16,0) 小盲｜(32,0) 大盲｜(48,0) Boss｜(64,0) 筹码｜
#          (80,0) 倍率｜(96,0) 金币｜(112,0) 牌组｜(128,0) 出牌｜(144,0) 弃牌｜(160,0) 排序｜
#          (176,0) 手型册｜(192,0) 指针｜(208,0) 空小丑槽｜(224,0) 骷髅｜(240,0) 星
#   (0,16)  16×16 Boss 图标 ×16（hook/wall/needle/water/club/spade/heart/diamond/
#           chain/psychic/eye/mouth/flint/arm/tooth/serpent）
#   (0,48)  16×16 塔罗图标 ×22（愚者…审判，按编号）
#   (0,96)  16×16 星球图标 ×12（水星…阋神星，按牌型顺序）
#   (24*(i%10), 144+24*(i//10))  24×24 小丑图标 ×52
#   (0,292) LOGO「BALATRO」112×20（FONT35 ×4 波浪基线）
#
# SFX 布局：0–31 游戏音效（5/6/8 为 16 步上行跑条，供 offset 步进调用），
#           64–68 低音 / 69–73 和弦 / 74–81 旋律 / 82 闭镲 / 83 军鼓（音乐用）
# Pattern 0–7 循环（0 BEGIN，7 BEGIN|END），通道 0 低音 1 和弦 2 旋律 6 镲 7 军鼓。

import math
import struct

W, H = 256, 1024
S = bytearray(W * H)
OUT = "demo/balatro"


def px(x, y, c):
    if 0 <= x < W and 0 <= y < H:
        S[y * W + x] = c


def fill(x, y, w, h, c):
    for j in range(h):
        for i in range(w):
            px(x + i, y + j, c)


def rect(x, y, w, h, c):
    for i in range(w):
        px(x + i, y, c)
        px(x + i, y + h - 1, c)
    for j in range(h):
        px(x, y + j, c)
        px(x + w - 1, y + j, c)


def line(x0, y0, x1, y1, c):
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx - dy
    while True:
        px(x0, y0, c)
        if x0 == x1 and y0 == y1:
            return
        e2 = err * 2
        if e2 > -dy:
            err -= dy
            x0 += sx
        if e2 < dx:
            err += dx
            y0 += sy


def circ(cx, cy, r, c):
    for j in range(-r, r + 1):
        for i in range(-r, r + 1):
            if i * i + j * j <= r * r:
                px(cx + i, cy + j, c)


# ---------------------------------------------------------------- 调色字符表
CM = {
    ".": None, "k": 1, "K": 2, "d": 3, "g": 5, "G": 6, "w": 7, "W": 8,
    "m": 9, "n": 10, "N": 11, "u": 12, "U": 13,
    "s": 21, "S": 20, "t": 23,
    "o": 29, "y": 30, "Y": 31, "O": 28, "z": 24,
    "e": 34, "E": 35, "v": 36, "V": 37, "L": 32, "q": 33,
    "c": 40, "b": 41, "B": 42, "l": 43, "p": 44, "P": 45, "i": 46,
    "r": 59, "R": 61, "x": 62, "X": 57, "F": 63, "f": 58, "T": 60,
    "M": 54, "h": 56, "D": 52, "a": 18, "A": 19,
}


def art(x, y, rows, cm=None, flip=False):
    cm = cm or CM
    w = max(len(r) for r in rows)
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            c = cm.get(ch)
            if c is not None:
                px(x + (w - 1 - i if flip else i), y + j, c)


# ---------------------------------------------------------------- 3×5 迷你字
# 每字符 5 行 × 3 位（bit2=左）。Lua 侧 RANKF 同源拷贝（仅 2..A）。
FONT35 = {
    "0": [7, 5, 5, 5, 7], "1": [2, 6, 2, 2, 7], "2": [7, 1, 7, 4, 7],
    "3": [7, 1, 3, 1, 7], "4": [5, 5, 7, 1, 1], "5": [7, 4, 7, 1, 7],
    "6": [7, 4, 7, 5, 7], "7": [7, 1, 1, 2, 2], "8": [7, 5, 7, 5, 7],
    "9": [7, 5, 7, 1, 7], "A": [2, 5, 7, 5, 5], "J": [3, 1, 1, 5, 2],
    "Q": [7, 5, 5, 7, 1], "K": [5, 5, 6, 5, 5], "$": [2, 7, 6, 7, 2],
    "B": [6, 5, 6, 5, 6], "L": [4, 4, 4, 4, 7], "T": [7, 2, 2, 2, 2],
    "R": [6, 5, 6, 6, 5], "O": [7, 5, 5, 5, 7],
    "?": [7, 1, 3, 0, 2], "!": [2, 2, 2, 0, 2], "x": [0, 5, 2, 5, 0],
    "+": [0, 2, 7, 2, 0], "-": [0, 0, 7, 0, 0], "3x": [7, 1, 3, 1, 7],
}


def glyph(ch, x, y, c, sc=1):
    g = FONT35[ch]
    for j in range(5):
        for i in range(3):
            if g[j] >> (2 - i) & 1:
                if sc == 1:
                    px(x + i, y + j, c)
                else:
                    fill(x + i * sc, y + j * sc, sc, sc, c)


def glyph10(x, y, c, sc=1):  # "10" 两字符 7px 宽
    glyph("1", x, y, c, sc)
    glyph("0", x + 4 * sc, y, c, sc)


# ---------------------------------------------------------------- 花色点阵 7×7
PIPS = {
    1: ["...#...", "..###..", ".#####.", "#######", ".#####.", "..###..", "...#..."],  # 黑桃
    2: ["...#...", "..###..", ".#####.", "#######", ".#####.", "..###..", "..###.."],  # 红心
    3: [".##.##.", "#######", "#######", ".#####.", "..###..", "..###..", "...#..."],  # 方片(横)
    4: ["..###..", ".#####.", "###.###", "#######", "###.###", ".#####.", "...#..."],  # 梅花
}
RED = {2: True, 3: True}  # 2=♥ 3=♦ 红；1=♠ 4=♣ 黑
SUIT_NAME = {1: "♠", 2: "♥", 3: "♦", 4: "♣"}


def pip(suit, x, y, sc=1, c=None):
    rows = PIPS[suit]
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch == "#":
                if sc == 1:
                    px(x + i, y + j, c)
                else:
                    fill(x + i * sc, y + j * sc, sc, sc, c)


# ---------------------------------------------------------------- 小丑画家工具
JC = {  # 小丑卡内常用色
    "skin": 21, "skin2": 20, "hat1": 59, "hat2": 34, "face": 7, "out": 1,
}


def j_circ(cx, cy, r, c):
    circ(cx, cy, r, c)


def j_hat(x, y, c1, c2):
    """三尖小丑帽（20 宽 8 高），(x,y) 为左上"""
    art(x, y, ["..a.........a........", "..aa.......aa........", ".abba.....abba.......",
               ".abbba...abbba....aa.", "..abbbbaabbbba...abba", "...aabbbbbbbbaaaabbba",
               "....abbbbbbbbbbbbbba.", ".....aaaaaaaaaaaaaa.."], {"a": c1, "b": c2})


def j_face(x, y, skin, smile=1, eyes=1):
    """圆脸 12×12，(x,y) 左上"""
    art(x, y, ["...ffffff....", "..ffffffffff.", ".ffffffffffff.", ".ffWffffffWff.",
               ".ffffffffffff.", ".ffffffffffff.", "..ffffffffff.",
               "..f.f....f.f..", "...f.f..f.f...", "....ffffff....",
               "....ffffffff..", ".............."],
        {"f": skin, "W": 7 if eyes else skin})
    if smile:
        line(x + 3, y + 7, x + 8, y + 7, 1)
        line(x + 2, y + 6, x + 3, y + 7, 1)
        line(x + 8, y + 7, x + 9, y + 6, 1)


def j_card(x, y, w=12, h=16, face=7, border=5):
    rect(x, y, w, h, border)
    fill(x + 1, y + 1, w - 2, h - 2, face)


def j_pip_at(suit, x, y, c, sc=1):
    pip(suit, x, y, sc, c)


def j_chipstack(x, y, n, c, c2):
    """n 层筹码（每层 3px 高 12 宽）"""
    for i in range(n):
        yy = y - i * 3
        fill(x, yy, 12, 3, c)
        fill(x + 2, yy + 1, 8, 1, c2)
        rect(x, yy, 12, 3, 1)


# ================================================================ 行 0 UI 图标
def icon_blind(x, y, n, base):
    """盲注令牌：底座圆盘 + n 枚金币"""
    fill(x + 1, y + 3, 14, 12, base)
    rect(x + 1, y + 3, 14, 12, 1)
    if n == 1:
        circ(x + 8, y + 9, 4, 30)
        circ(x + 8, y + 9, 2, 31)
        rect(x + 4, y + 5, 9, 1, 1)
    else:
        circ(x + 5, y + 7, 3, 30)
        circ(x + 5, y + 7, 1, 31)
        circ(x + 11, y + 10, 3, 29)
        circ(x + 11, y + 10, 1, 30)


icon_blind(16, 0, 1, 11)
icon_blind(32, 0, 2, 11)


def icon_boss(x, y):
    fill(x + 1, y + 1, 14, 14, 61)
    rect(x + 1, y + 1, 14, 14, 1)
    art(x + 2, y + 2, ["..wwwwww..", ".wwwwwwww.", "wwkwwwwkww", "wwkwwwwkww",
                       "wwwkkkkwww", "www.ww.www", "..w.ww.w..", "..w.ww.w.."],
        {"w": 8, "k": 1})


icon_boss(48, 0)


def icon_chip(x, y):
    """蓝色筹码"""
    circ(x + 8, y + 8, 7, 1)
    circ(x + 8, y + 8, 5, 41)
    for a in range(6):
        ang = a * math.pi / 3
        px(x + 8 + round(6 * math.cos(ang)), y + 8 + round(6 * math.sin(ang)), 42)
    circ(x + 8, y + 8, 2, 42)
    px(x + 7, y + 7, 44)


icon_chip(64, 0)


def icon_mult(x, y):
    circ(x + 8, y + 8, 7, 1)
    circ(x + 8, y + 8, 5, 59)
    line(x + 5, y + 5, x + 11, y + 11, 63)
    line(x + 11, y + 5, x + 5, y + 11, 63)
    line(x + 6, y + 5, x + 11, y + 10, 7)


icon_mult(80, 0)


def icon_coin(x, y):
    circ(x + 8, y + 8, 6, 29)
    circ(x + 8, y + 8, 4, 30)
    glyph("$", x + 7, y + 6, 31)


icon_coin(96, 0)


def icon_deck(x, y):
    """牌组：三张叠卡"""
    j_card(x + 1, y + 4, 10, 11, 11, 1)
    j_card(x + 4, y + 2, 10, 11, 12, 1)
    j_card(x + 3, y + 1, 10, 11, 41, 7)
    rect(x + 5, y + 3, 6, 7, 44)
    rect(x + 6, y + 4, 4, 5, 42)


icon_deck(112, 0)


def icon_play(x, y):
    circ(x + 8, y + 8, 7, 35)
    circ(x + 8, y + 8, 6, 34)
    for j in range(6):
        w = 6 - abs(j - 3) * 2
        fill(x + 6, y + 5 + j, w + 1, 1, 7)
    px(x + 12, y + 8, 7)


icon_play(128, 0)


def icon_discard(x, y):
    circ(x + 8, y + 8, 7, 26)
    circ(x + 8, y + 8, 6, 25)
    for a in range(12):
        ang = -a * math.pi / 6 + 0.5
        px(x + 8 + round(4 * math.cos(ang)), y + 8 + round(4 * math.sin(ang)), 7)
    line(x + 4, y + 4, x + 8, y + 8, 7)
    line(x + 9, y + 4, x + 8, y + 8, 7)
    line(x + 4, y + 9, x + 8, y + 8, 7)


icon_discard(144, 0)


def icon_sort(x, y):
    fill(x + 3, y + 2, 10, 12, 3)
    rect(x + 3, y + 2, 10, 12, 5)
    line(x + 6, y + 4, x + 6, y + 11, 44)
    line(x + 5, y + 5, x + 6, y + 4, 7)
    line(x + 7, y + 5, x + 6, y + 4, 7)
    line(x + 10, y + 11, x + 10, y + 4, 30)
    line(x + 9, y + 10, x + 10, y + 11, 7)
    line(x + 11, y + 10, x + 10, y + 11, 7)


icon_sort(160, 0)


def icon_book(x, y):
    fill(x + 2, y + 2, 12, 12, 11)
    rect(x + 2, y + 2, 12, 12, 1)
    fill(x + 3, y + 3, 10, 2, 42)
    fill(x + 3, y + 7, 10, 2, 59)
    fill(x + 3, y + 11, 10, 1, 30)


icon_book(176, 0)


def icon_cursor(x, y):
    art(x + 4, y + 1, ["w.......",
                       "ww......",
                       "www.....",
                       "wwww....",
                       "wwwww...",
                       "wwwwww..",
                       "wwwwwww.",
                       "wwwwwwww",
                       "www.www.",
                       "ww...ww.",
                       "w....ww.",
                       ".....w.."], {"w": 7})


icon_cursor(192, 0)


def icon_slot(x, y):
    """空小丑槽：暗色卡 + 帽子剪影"""
    fill(x + 1, y + 1, 14, 14, 2)
    rect(x + 1, y + 1, 14, 14, 3)
    art(x + 3, y + 4, ["..d.......d..", ".ddd.....ddd.", ".dddd...dddd.", "..ddddddddd..",
                       "..ddddddddd..", "...ddddddd...", "....ddddd....",
                       "...d.d.d.d..."], {"d": 3})


icon_slot(208, 0)


def icon_skull(x, y):
    art(x + 3, y + 2, ["..wwwwww..", ".wwwwwwww.", "wwwwwwwwww", "wwkwwwwkww",
                      "wwkwwwwkww", "wwwkkkkwww", "wwww.wwwww", ".ww.w.w.w.",
                      "..wwwwwww.", "...wwwww.."], {"w": 8, "k": 1})


icon_skull(224, 0)


def icon_star(x, y):
    circ(x + 8, y + 8, 7, 30)
    for a in range(5):
        ang = -math.pi / 2 + a * 2 * math.pi / 5
        ang2 = ang + math.pi / 5
        x1, y1 = x + 8 + round(7 * math.cos(ang)), y + 8 + round(7 * math.sin(ang))
        x2, y2 = x + 8 + round(3 * math.cos(ang2)), y + 8 + round(3 * math.sin(ang2))
        line(x + 8, y + 8, x1, y1, 31)
        line(x1, y1, x2, y2, 31)


icon_star(240, 0)

# ================================================================ Boss 图标 ×16
BOSS_ART = [
    # 0 钩子
    [".....ww......", "....w........", "....w........", "....w........",
     "....w..ww....", "....w.w..w...", "....w.w......", "....ww.w.....",
     ".....w.ww....", "......ww.....", ".............", "......g......",
     ".....ggg.....", "....ggggg....", "...ggggggg...", "............."],
    # 1 高墙
    ["tttttttttttttt.", "t..t.t..t.t..t.", "tttttttttttttt.", "t.t..t..t.t..t.",
     "tttttttttttttt.", "t..t.t..t.t..tt", "ttttttttttttt..", ".t.t..t..t..t..",
     "tttttttttttttt.", "t..t.t..t.t..t.", "tttttttttttttt.", "t.t..t..t.t..t.",
     "tttttttttttttt.", "t..t.t..t.t..t.", "tttttttttttttt.", "..............."],
    # 2 针筒
    ["..........ww..", ".........w..w.", "........w...w.", ".......w...w..",
     "......w...w...", ".....w...w....", "....w...w.....", "...w...w......",
     "..w...w.......", ".w...w........", "ww..w.........", ".www..........",
     "..w...........", ".w.w..........", "w...w.........", ".............."],
    # 3 水管
    ["..............", "....bbbbbb....", "...bBBBBBBb...", "...bBBBBBBb...",
     "...bBBBBBBb...", "...bBBBBBBb...", "...bBBBBBBb...", "...bBBBBBBb...",
     "...bBBBBBBb...", "...bBBBBBBb...", "....bbbbbb....", "......bb......",
     "......bb......", "..............", "..............", ".............."],
    # 4 梅花之头（ clubs boss）
    ["...kkkkkk.....", "..k####k......", ".k##k#k#k.....", "k#k#k#k#k.....",
     "kkkkkkkkk.....", ".kkkkkkk......", "..kkkkk.......", "...kkk........",
     "....k.........", "...kkk........", "..kkkkk.......", ".kkkkkkk......",
     "kkkkkkkkk.....", ".kkkkkkk......", "..kkkkk.......", ".............."],
    # 5 黑桃之头
    ["......k.......", ".....kkk......", "....kkkkk.....", "...kkkkkkk....",
     "..kkkkkkkkk...", ".kkkkkkkkkkk..", "kkkkkkkkkkkkk.", ".kkkkkkkkkkk..",
     "..kkkkkkkkk...", "...kkkkkkk....", "....kkkkk.....", "....kkkkk.....",
     ".....kkk......", "......k.......", "..............", ".............."],
    # 6 红心之头
    ["rrrr....rrrr.", "rrrrrrrrrrrr.", "rrrrrrrrrrrr.", "rrrrrrrrrrrr.",
     ".rrrrrrrrrrr.", "..rrrrrrrrr..", "...rrrrrrr...", "....rrrrr....",
     ".....rrr.....", "......r......", "..............", "..............",
     "..............", "..............", "..............", ".............."],
    # 7 方片之头
    ["......rr......", ".....rrrr.....", "....rrrrrr....", "...rrrrrrrr...",
     "..rrrrrrrrrr..", ".rrrrrrrrrrrr.", "rrrrrrrrrrrrrr", ".rrrrrrrrrrrr.",
     "..rrrrrrrrrr..", "...rrrrrrrr...", "....rrrrrr....", ".....rrrr.....",
     "......rr......", "..............", "..............", ".............."],
    # 8 镣铐
    ["..gg......gg..", ".g..g....g..g.", ".g..g.gg.g..g.", ".g..gg..gg..g.",
     "..gg.g..g.gg..", ".....gggg.....", "....gg..gg....", "....g....g....",
     "....g....g....", "....gg..gg....", ".....gggg.....", "......gg......",
     "......gg......", "..............", "..............", ".............."],
    # 9 心灵（必须5张）
    ["...pppppppp...", "..pppppppppp..", ".pppwwwwwwppp.", ".ppwwwwwwwwpp.",
     "ppwwppppppwwpp", "ppwppppppppwpp", "ppwppppppppwpp", "ppwwppppppwwpp",
     ".ppwwwwwwwwpp.", ".pppwwwwwwppp.", "..pppppppppp..", "...pppppppp...",
     "..............", "..............", "..............", ".............."],
    # 10 邪眼
    ["....wwwwww....", "..wwwwwwwwww..", ".wwkkwwwwkkww.", "wwwkkwwwwkkwww",
     "wwwkkkwwkkkwww", "wwwkkkwwkkkwww", "wwwkkwwwwkkwww", ".wwkkwwwwkkww.",
     "..wwwwwwwwww..", "....wwwwww....", "..............", "..............",
     "..............", "..............", "..............", ".............."],
    # 11 独口
    ["...rrrrrrrr...", "..rrrrrrrrrr..", ".rrrrrrrrrrrr.", "rrrrwwwwwwrrrr",
     "rrrwwwwwwwwrrr", "rrrwwwwwwwwrrr", "rrrwwwwwwwwrrr", "rrrrwwwwwwrrrr",
     ".rrrrrrrrrrrr.", "..rrrrrrrrrr..", "...rrrrrrrr...", "..............",
     "..............", "..............", "..............", ".............."],
    # 12 燧石
    ["..............", "......gg......", ".....gggg.....", "....gggggg....",
     "...gggGGggg...", "..gggGGggggg..", ".gggggggggggg.", ".gggggggggg...",
     "..ggggggggg...", "...ggggggg....", "....gggggg.o..", "......gg...oo.",
     "...........o..", "..............", "..............", ".............."],
    # 13 手臂
    ["......sss.....", ".....sssss....", "....sssssss...", "...sssssssss..",
     "...s.s.s.s.s..", "..sssssssss...", "..ssssssss....", "...ssssss.....",
     "....sssss.....", ".....sss......", "......ss......", "..............",
     "..............", "..............", "..............", ".............."],
    # 14 尖牙
    ["...wwwwwwww...", "..wwwwwwwwww..", ".wwwwwwwwwwww.", "wwwwwwwwwwwwww",
     "wwkwwwwwwwwkww", "wwwkkwwwwkkwww", "wwwwkkwwkkwwww", "wwwwwkkkkwwwww",
     "wwwwwwwwwwwwww", ".wwwwwwwwwwww.", "..wwwwwwwwww..", "...wwwwwwww...",
     "....w.ww.w....", "..............", "..............", ".............."],
    # 15 巨蛇
    ["..............", "...eee........", "..e...e.......", "..e...e.......",
     "...eee........", ".....e........", "....e.........", "...eeeeeee....",
     ".........e....", "........e.....", "...eeeeee.....", "..e.....e.....",
     "..eeeeeee.....", "......ee......", ".....e..e.....", ".............."],
]
BOSS_COL = [{"w": 7, "g": 6, "k": 1}, {"t": 23, "k": 1}, {"w": 8, "k": 1}, {"b": 41, "B": 44, "k": 1},
            {"k": 1, "#": 7}, {"k": 1}, {"r": 59, "k": 1}, {"r": 59, "k": 1},
            {"g": 6, "k": 1}, {"p": 45, "w": 7, "k": 1}, {"w": 8, "k": 1}, {"r": 59, "w": 7, "k": 1},
            {"g": 5, "G": 6, "o": 24, "k": 1}, {"s": 21, "k": 1}, {"w": 8, "k": 1}, {"e": 34, "k": 1}]
for bi, rows in enumerate(BOSS_ART):
    bx, by = (bi % 16) * 16, 16
    fill(bx, by, 16, 16, 0)
    art(bx, by, rows, BOSS_COL[bi])

# ================================================================ 塔罗图标 ×22
TAROT_ART = [
    ["...wwwwwwwwww..", "..w..........w.", ".w....rrrr....w", ".w...r....r...w",
     ".w..r......r..w", ".w..r..rr..r..w", ".w..r.rrrr.r..w", ".w..r..rr..r..w",
     ".w...r....r...w", ".w....rrrr....w", "..w..........w.", "...wwwwwwwwww.."],
    # 1 魔术师：四叶草幸运
    ["...wwwwwwwwww..", "..w..........w.", ".w.....ee.....w", ".w...eeeeee...w",
     ".w..eeeeeeee..w", ".w..eeeeeeee..w", ".w...eeeeee...w", ".w..e..ee..e..w",
     ".w.....ee.....w", ".w......e.....w", "..w..........w.", "...wwwwwwwwww.."],
    # 2 女祭司：双月
    ["...wwwwwwwwww..", "..w..........w.", ".w...b....b...w", ".w..bbb..bbb..w",
     ".w.bbbbbbbbbb.w", ".w..bbb..bbb..w", ".w...b....b...w", ".w............w",
     ".w....bbbb....w", ".w...bbbbbb...w", "..w..........w.", "...wwwwwwwwww.."],
    # 3 皇后：多重
    ["...wwwwwwwwww..", "..w..........w.", ".w..r.r..r.r..w", ".w.r.rr..rr.r.w",
     ".w..rrr..rrr..w", ".w...rr....rr.w", ".w............w", ".w....rrrr....w",
     ".w...rrrrrr...w", ".w....rrrr....w", "..w..........w.", "...wwwwwwwwww.."],
    # 4 皇帝：双塔罗
    ["...wwwwwwwwww..", "..w..........w.", ".w.rr....rr...w", ".wrrrr..rrrr..w",
     ".w.rr....rr...w", ".w............w", ".w.rr....rr...w", ".wrrrr..rrrr..w",
     ".w.rr....rr...w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 5 教皇：富余
    ["...wwwwwwwwww..", "..w..........w.", ".w....cccc....w", ".w..cccccccc..w",
     ".w.cccccccccc.w", ".w..cccccccc..w", ".w....cccc....w", ".w............w",
     ".w....cccc....w", ".w...cccccc...w", "..w..........w.", "...wwwwwwwwww.."],
    # 6 恋人：万能
    ["...wwwwwwwwww..", "..w..........w.", ".w..r....e....w", ".w.r.r..e.e...w",
     ".w.r.r.eee.e..w", ".w..r.eeeee...w", ".w...eeeee....w", ".w....eee.....w",
     ".w.....e......w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 7 战车：钢铁
    ["...wwwwwwwwww..", "..w..........w.", ".w..gggggggg..w", ".w.gggggggggg.w",
     ".w.gWggggggWg.w", ".w.gggggggggg.w", ".w.gggggggggg.w", ".w.gWggggggWg.w",
     ".w.gggggggggg.w", ".w..gggggggg..w", "..w..........w.", "...wwwwwwwwww.."],
    # 8 正义：玻璃
    ["...wwwwwwwwww..", "..w..........w.", ".w..plllllp...w", ".w.plllllllp..w",
     ".w.pllwwllllp.w", ".w.pllllllllp.w", ".w.plllllllp..w", ".w..plllllp...w",
     ".w....lll.....w", ".w.....l......w", "..w..........w.", "...wwwwwwwwww.."],
    # 9 隐士：金币翻倍
    ["...wwwwwwwwww..", "..w..........w.", ".w....yyyy....w", ".w...yyyyyy...w",
     ".w..yy.yy.yy..w", ".w..yyyyyyyy..w", ".w...yyyyyy...w", ".w....yyyy....w",
     ".w....y..y....w", ".w...y....y...w", "..w..........w.", "...wwwwwwwwww.."],
    # 10 命运之轮
    ["...wwwwwwwwww..", "..w..........w.", ".w....cccc....w", ".w..cc.cc.cc..w",
     ".w.c..cccc..c.w", ".w.cc.c..c.cc.w", ".w.c..cccc..c.w", ".w..cc.cc.cc..w",
     ".w....cccc....w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 11 力量：升阶
    ["...wwwwwwwwww..", "..w..........w.", ".w......w.....w", ".w.....ww.....w",
     ".w....wwww....w", ".w...wwwwww...w", ".w.....ww.....w", ".w.....ww.....w",
     ".w............w", ".w....7777....w", "..w..........w.", "...wwwwwwwwww.."],
    # 12 倒吊人：销毁
    ["...wwwwwwwwww..", "..w..........w.", ".w....rr......w", ".w...rrrr.....w",
     ".w..rrrrrr....w", ".w...rrrr.....w", ".w....rr......w", ".w.....x......w",
     ".w.....x......w", ".w....xxx.....w", "..w..........w.", "...wwwwwwwwww.."],
    # 13 死神：复制
    ["...wwwwwwwwww..", "..w..........w.", ".w..w....w....w", ".w.ww....ww...w",
     ".w..w....w....w", ".w..w....w....w", ".w............w", ".w...wwww.....w",
     ".w............w", ".w..w....w....w", "..w..........w.", "...wwwwwwwwww.."],
    # 14 节制：金钱
    ["...wwwwwwwwww..", "..w..........w.", ".w.....yy.....w", ".w....yyyy....w",
     ".w...yyyyyy...w", ".w...y.yy.y...w", ".w...yyyyyy...w", ".w....yyyy....w",
     ".w.....yy.....w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 15 恶魔：黄金
    ["...wwwwwwwwww..", "..w..........w.", ".w..rr....rr..w", ".w.rrrr..rrrr.w",
     ".w.rrrr..rrrr.w", ".w..rr....rr..w", ".w.....yy.....w", ".w....yyyy....w",
     ".w....y..y....w", ".w.....yy.....w", "..w..........w.", "...wwwwwwwwww.."],
    # 16 塔：石头
    ["...wwwwwwwwww..", "..w..........w.", ".w...gggggg...w", ".w..gggggggg..w",
     ".w..gggggggg..w", ".w..ggg..ggg..w", ".w..gggggggg..w", ".w..gggggggg..w",
     ".w..gggggggg..w", ".w..gggggggg..w", "..w..........w.", "...wwwwwwwwww.."],
    # 17 星：方片
    ["...wwwwwwwwww..", "..w..........w.", ".w.....rr.....w", ".w....rrrr....w",
     ".w...rrrrrr...w", ".w..rrrrrrrr..w", ".w...rrrrrr...w", ".w....rrrr....w",
     ".w.....rr.....w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 18 月：梅花
    ["...wwwwwwwwww..", "..w..........w.", ".w....ccc.....w", ".w...ccccc....w",
     ".w...ccccc....w", ".w..ccccccc...w", ".w...ccccc....w", ".w....ccc.....w",
     ".w.....c......w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 19 太阳：红心
    ["...wwwwwwwwww..", "..w..........w.", ".w..rr...rr...w", ".w.rrrr.rrrr..w",
     ".w.rrrrrrrrr..w", ".w..rrrrrrr...w", ".w...rrrrr....w", ".w....rrr.....w",
     ".w.....r......w", ".w............w", "..w..........w.", "...wwwwwwwwww.."],
    # 20 世界：黑桃
    ["...wwwwwwwwww..", "..w..........w.", ".w.....kk.....w", ".w....kkkk....w",
     ".w...kkkkkk...w", ".w..kkkkkkkk..w", ".w...kkkkkk...w", ".w....kkkk....w",
     ".w.....kk.....w", ".w....kkkk....w", "..w..........w.", "...wwwwwwwwww.."],
    # 21 审判：随机小丑
    ["...wwwwwwwwww..", "..w..........w.", ".w..rr...ee...w", ".w.rrrr.eeee..w",
     ".w.rrrr.eeee..w", ".w..rr...ee...w", ".w...wwwwww...w", ".w..wwwwwwww..w",
     ".w...wwwwww...w", ".w....wwww....w", "..w..........w.", "...wwwwwwwwww.."],
]
for ti, rows in enumerate(TAROT_ART):
    tx, ty = (ti % 16) * 16, 48 + (ti // 16) * 16
    fill(tx, ty, 16, 16, 0)
    art(tx, ty, rows, CM)

# ================================================================ 星球图标 ×12
PLANET_COL = [41, 59, 30, 24, 34, 42, 46, 12, 27, 63, 56, 48]  # 水星..阋神星
for pi in range(12):
    bx, by = (pi % 16) * 16, 96 + (pi // 16) * 16
    c1, c2 = PLANET_COL[pi], 7
    r = 5 + (pi % 2)
    circ(bx + 8, by + 8, r, 1)
    circ(bx + 8, by + 8, r - 1, c1)
    # 高光
    circ(bx + 8 - r // 2, by + 8 - r // 2, 1, c2)
    # 环
    if pi % 3 == 2:
        line(bx + 1, by + 10, bx + 15, by + 5, 23)
    # 条纹
    if pi % 3 == 1:
        fill(bx + 8 - r + 2, by + 7, 2 * r - 3, 1, 1)

# ================================================================ 小丑图标 ×52
# 24×24，(24*(i%10), 144+24*(i//10))
JO = 144


def jpos(i):
    return ((i % 10) * 24, JO + (i // 10) * 24)


def joker(i):
    fill(*jpos(i), 24, 24, 0)
    return jpos(i)


# 1 小丑（红绿帽小丑脸）
x, y = joker(0)
j_hat(x + 2, y + 1, 59, 34)
j_face(x + 6, y + 9, 21)
px(x + 12, y + 8, 1)

# 2-5 花色小丑：小妖 + 对应花色（四色花色：♠白 ♥红 ♦蓝 ♣绿）
SUITC = {1: 7, 2: 59, 3: 41, 4: 34}
for si, suit in enumerate([3, 2, 1, 4]):  # 贪婪♦ 色欲♥ 暴怒♠ 暴食♣
    x, y = joker(1 + si)
    j_face(x + 5, y + 2, 21, smile=1)
    art(x + 4, y + 2, ["..e.e..", ".eeeee.", ".e.e.e."], {"e": 36})  # 尖耳
    fill(x + 6, y + 14, 12, 8, 35)
    rect(x + 6, y + 14, 12, 8, 1)
    pip(suit, x + 8, y + 14, 1, SUITC[suit])

# 6 快活（对子 +8）
x, y = joker(5)
j_card(x + 3, y + 5, 10, 14, 7)
j_card(x + 10, y + 3, 10, 14, 7)
pip(2, x + 12, y + 5, 1, 59)
pip(2, x + 5, y + 7, 1, 59)
glyph("8", x + 16, y + 19, 30)

# 7 嬉闹（三条 +12）
x, y = joker(6)
for i in range(3):
    j_card(x + 3 + i * 6, y + 4 + (i % 2) * 3, 8, 13, 7)
    pip(3, x + 5 + i * 6, y + 7 + (i % 2) * 3, 1, 59)
glyph("1", x + 8, y + 19, 30)
glyph("2", x + 13, y + 19, 30)

# 8 疯狂（两对 +10）
x, y = joker(7)
for i in range(4):
    j_card(x + 2 + i * 5, y + 5 + (i % 2) * 4, 8, 12, 7)
    pip([2, 4, 2, 4][i], x + 4 + i * 5, y + 8 + (i % 2) * 4, 1, 59 if i % 2 else 7)
glyph("1", x + 7, y + 19, 30)
glyph("0", x + 12, y + 19, 30)

# 9 狂热（顺子 +12）
x, y = joker(8)
for i in range(4):
    j_card(x + 2 + i * 5, y + 3 + i * 2, 8, 11, 7)
    rect(x + 4 + i * 5, y + 6 + i * 2, 4, 2, [41, 34, 30, 59][i])
for i in range(3):
    line(x + 5 + i * 5, y + 8 + i * 2, x + 8 + i * 5, y + 9 + i * 2, 63)
glyph("1", x + 8, y + 20, 30)
glyph("2", x + 13, y + 20, 30)

# 10 悠然（同花 +10）
x, y = joker(9)
j_card(x + 5, y + 3, 14, 16, 7)
for i in range(3):
    pip(3, x + 7 + i * 3, y + 5 + i * 3, 1, 59)
glyph("1", x + 8, y + 20, 30)
glyph("0", x + 13, y + 20, 30)

# 11-15 筹码系（对子50/三条100/两对80/顺子100/同花80）
for idx, ji in enumerate([10, 11, 12, 13, 14]):
    ns = [2, 3, 4, 5, 6][idx]
    x, y = joker(ji)
    j_chipstack(x + 6, y + 15, 3, [41, 59, 30, 42, 34][idx], 44)
    # 顶部对应数量的花色点
    suitc = [2, 3, 2, 1, 3][idx]
    for i in range(ns):
        pip(suitc, x + 5 + i * 6, y + 2, 1, 7)
    # 数字标注
    num = ["50", "100", "80", "100", "80"][idx]
    if len(num) == 2:
        glyph(num[0], x + 6, y + 18, 30)
        glyph(num[1], x + 11, y + 18, 30)
    else:
        glyph(num[0], x + 4, y + 18, 30)
        glyph(num[1], x + 9, y + 18, 30)
        glyph(num[2], x + 14, y + 18, 30)

# 16 半张小丑
x, y = joker(15)
j_card(x + 4, y + 3, 12, 18, 7)
fill(x + 10, y + 3, 6, 18, 8)  # 右半阴影
rect(x + 4, y + 3, 12, 18, 5)
line(x + 10, y + 4, x + 10, y + 20, 5)
line(x + 6, y + 12, x + 9, y + 12, 1)
line(x + 6, y + 13, x + 9, y + 13, 1)
glyph("2", x + 6, y + 5, 59)
glyph("0", x + 14, y + 17, 5)

# 17 横幅小丑
x, y = joker(16)
line(x + 5, y + 2, x + 5, y + 21, 23)
art(x + 6, y + 3, ["rrrrrrrrrrrr.", "rrrrrrrrrrrrr", "rrwwwwwwwwrrr", "rrwwwwwwwwrrr",
                  "rrrrrrrrrrrrr", ".rrrrrrrrrrr.", "..rrrrrrrrr.."], {"r": 59, "w": 7})
glyph("+", x + 9, y + 5, 7)

# 18 神秘之巅
x, y = joker(17)
fill(x + 2, y + 14, 20, 8, 12)
art(x + 2, y + 6, ["....bb....", "...bbbb...", "..bbbbbb..", ".bbbbbbbb.", "bbbbbbbbbb"],
    {"b": 11})
circ(x + 18, y + 4, 2, 31)
fill(x + 2, y + 14, 20, 2, 42)
line(x + 4, y + 16, x + 9, y + 21, 8)
line(x + 12, y + 16, x + 17, y + 21, 8)

# 19 错印小丑
x, y = joker(18)
j_card(x + 4, y + 3, 15, 18, 7)
glyph("?", x + 7, y + 6, 1)
glyph("!", x + 12, y + 11, 59)
line(x + 7, y + 16, x + 14, y + 16, 5)

# 20 忠诚卡
x, y = joker(19)
j_card(x + 4, y + 3, 16, 18, 7)
rect(x + 6, y + 5, 12, 9, 44)
for i in range(6):
    px(x + 7 + (i % 3) * 4, y + 7 + (i // 3) * 4, 42 if i < 4 else 3)
glyph("x", x + 9, y + 16, 59)
glyph("4", x + 13, y + 16, 59)

# 21 绿小丑
x, y = joker(20)
j_hat(x + 2, y + 1, 34, 36)
j_face(x + 6, y + 9, 34)
line(x + 9, y + 16, x + 14, y + 16, 7)
px(x + 12, y + 8, 1)

# 22 冰淇淋
x, y = joker(21)
art(x + 7, y + 2, ["..wwww..", ".wwwwww.", ".wwwwww.", "..wwww..", "..wwww.."], {"w": 44})
fill(x + 7, y + 2, 8, 2, 7)
art(x + 6, y + 7, ["...tt....", "..tttt...", ".ttttt...", ".tttt....", "..tt.....",
                  "..t......", "..t......", ".t......."], {"t": 23})
px(x + 9, y + 3, 59)
px(x + 13, y + 4, 41)

# 23 偶数史蒂文
x, y = joker(22)
j_card(x + 5, y + 3, 14, 18, 7)
glyph("2", x + 10, y + 6, 41)
glyph("4", x + 8, y + 13, 41)
glyph("6", x + 12, y + 13, 41)

# 24 奇数托德
x, y = joker(23)
j_card(x + 5, y + 3, 14, 18, 7)
glyph("A", x + 10, y + 6, 29)
glyph("3", x + 8, y + 13, 29)
glyph("5", x + 12, y + 13, 29)

# 25 学者
x, y = joker(24)
j_face(x + 6, y + 10, 21)
art(x + 3, y + 4, ["..kkkkkkkkkk..", ".kkkkkkkkkkkk.", "..kk......kk.."], {"k": 12})
line(x + 9, y + 7, x + 9, y + 10, 12)
glyph("A", x + 14, y + 18, 30)

# 26 商业卡
x, y = joker(25)
j_card(x + 5, y + 3, 14, 18, 7)
glyph("$", x + 9, y + 5, 30)
rect(x + 7, y + 12, 10, 6, 8)
glyph("$", x + 10, y + 13, 30)

# 27 超新星
x, y = joker(26)
circ(x + 12, y + 12, 4, 30)
circ(x + 12, y + 12, 2, 31)
for a in range(8):
    ang = a * math.pi / 4
    line(x + 12 + round(5 * math.cos(ang)), y + 12 + round(5 * math.sin(ang)),
         x + 12 + round(10 * math.cos(ang)), y + 12 + round(10 * math.sin(ang)), 24 if a % 2 else 30)

# 28 搭公车
x, y = joker(27)
fill(x + 3, y + 6, 18, 10, 30)
rect(x + 3, y + 6, 18, 10, 1)
for i in range(3):
    rect(x + 5 + i * 5, y + 8, 3, 3, 44)
circ(x + 7, y + 17, 2, 1)
circ(x + 17, y + 17, 2, 1)
fill(x + 3, y + 4, 6, 2, 24)

# 29 太空小丑
x, y = joker(28)
art(x + 9, y + 2, ["...ww...", "..wwww..", "..wwww..", ".w.ww.w.", ".wwwwww.",
                  ".wwwwww.", "..wwww..", "..r..r..", ".r....r.", "..rrrr.."],
    {"w": 7, "r": 59})
circ(x + 5, y + 18, 3, 42)
circ(x + 18, y + 17, 2, 44)

# 30 方块小丑
x, y = joker(29)
for i in range(4):
    fill(x + 5 + (i % 2) * 8, y + 5 + (i // 2) * 8, 7, 7, [41, 42, 44, 40][i])
    rect(x + 5 + (i % 2) * 8, y + 5 + (i // 2) * 8, 7, 7, 1)

# 31 黑板小丑
x, y = joker(30)
fill(x + 3, y + 4, 18, 14, 23)
rect(x + 3, y + 4, 18, 14, 12)
line(x + 3, y + 4, x + 3, y + 4, 23)
rect(x + 5, y + 6, 14, 10, 12)
rect(x + 5, y + 6, 14, 10, 35)
glyph("x", x + 8, y + 9, 7)
glyph("3", x + 13, y + 9, 7)

# 32 公牛小丑
x, y = joker(31)
j_face(x + 6, y + 8, 21)
line(x + 3, y + 7, x + 6, y + 10, 8)
line(x + 20, y + 7, x + 17, y + 10, 8)
line(x + 3, y + 6, x + 5, y + 8, 8)
line(x + 20, y + 6, x + 18, y + 8, 8)
px(x + 9, y + 12, 1)
px(x + 14, y + 12, 1)

# 33 香蕉小丑
x, y = joker(32)
art(x + 4, y + 4, ["....yyyyyy....", "..yyyyyyyyyy..", ".yyyyyyyyyyy..", ".yyyyyyyyyy...",
                  ".yyyyyyyyy....", ".yyyyyyyy.....", "..yyyyyy......", "...yyyy.......",
                  "....yy........", ".....y........"], {"y": 30})
px(x + 6, y + 5, 29)
px(x + 8, y + 7, 29)

# 34 血石小丑
x, y = joker(33)
pip(2, x + 4, y + 2, 2, 59)
fill(x + 12, y + 8, 2, 8, 63)
px(x + 13, y + 17, 63)
rect(x + 9, y + 20, 9, 2, 61)

# 35 偶像小丑
x, y = joker(34)
fill(x + 8, y + 3, 8, 12, 23)
rect(x + 8, y + 3, 8, 12, 29)
px(x + 10, y + 6, 1)
px(x + 13, y + 6, 1)
line(x + 10, y + 10, x + 13, y + 10, 1)
fill(x + 5, y + 15, 14, 5, 12)
rect(x + 5, y + 15, 14, 5, 1)
glyph("x", x + 9, y + 16, 31)
glyph("2", x + 13, y + 16, 31)

# 36 斐波那契
x, y = joker(35)
for a in range(28):
    ang = a * 0.4
    r = 0.4 * a
    px(x + 12 + round(r * math.cos(ang)), y + 12 + round(r * math.sin(ang)), 34)
for a in range(20):
    ang = a * 0.4 + 2.5
    r = 0.35 * a
    px(x + 12 + round(r * math.cos(ang)), y + 12 + round(r * math.sin(ang)), 30)
glyph("8", x + 19, y + 17, 7)

# 37 恐怖脸
x, y = joker(36)
j_card(x + 4, y + 3, 16, 18, 7)
glyph("J", x + 7, y + 5, 1)
line(x + 7, y + 11, x + 9, y + 13, 1)
line(x + 9, y + 13, x + 11, y + 11, 1)
line(x + 11, y + 11, x + 13, y + 13, 1)
line(x + 13, y + 13, x + 15, y + 11, 1)
px(x + 8, y + 9, 1)
px(x + 14, y + 9, 1)

# 38 抽象小丑
x, y = joker(37)
rect(x + 4, y + 3, 16, 18, 5)
fill(x + 5, y + 4, 14, 16, 7)
circ(x + 9, y + 9, 2, 41)
fill(x + 13, y + 6, 4, 4, 59)
line(x + 6, y + 16, x + 17, y + 12, 34)
px(x + 8, y + 14, 30)
px(x + 15, y + 16, 46)

# 39 无面小丑
x, y = joker(38)
j_face(x + 6, y + 6, 8, smile=0, eyes=0)
rect(x + 6, y + 6, 13, 12, 5)
j_hat(x + 4, y + 1, 3, 2)
line(x + 9, y + 21, x + 16, y + 21, 3)

# 40 哑剧小丑
x, y = joker(39)
j_face(x + 6, y + 8, 8, smile=0)
fill(x + 5, y + 5, 13, 3, 59)
fill(x + 7, y + 3, 9, 2, 59)
for i in range(4):
    fill(x + 6 + i * 3, y + 20, 2, 3, 7 if i % 2 else 1)

# 41 四指小丑
x, y = joker(40)
fill(x + 7, y + 3, 10, 13, 21)
rect(x + 7, y + 3, 10, 13, 1)
for i in range(4):
    fill(x + 7 + i * 3, y, 2, 4, 21)
fill(x + 7, y + 16, 10, 6, 7)
rect(x + 7, y + 16, 10, 6, 1)
glyph("4", x + 10, y + 17, 1)

# 42 涂抹小丑
x, y = joker(41)
art(x + 3, y + 5, ["pppppp....", "ppppppp...", ".ppppppp..", "..pppppp.."],
    {"p": 56})
art(x + 9, y + 12, ["....eeeeee.", "...eeeeeee.", "..eeeeee...", ".eeeeee...."],
    {"e": 34})
pip(2, x + 4, y + 16, 1, 59)
pip(1, x + 15, y + 16, 1, 1)

# 43 卡文迪什
x, y = joker(42)
art(x + 3, y + 3, ["...yyyyyy.....", ".yyyyyyyyyy...", "yyyyyyyyyyy...", "yyyyyyyyyy....",
                  "yyyyyyyy......", ".yyyyyyy......", "..yyyyy.......", "...yyy........",
                  "....yy........", ".....y........"], {"y": 30})
art(x + 11, y + 12, ["..yyyyyyy...", "yyyyyyyyyy..", "yyyyyyyyy...", ".yyyyyy.....",
                     "..yyyy......", "...yy......."], {"y": 29})
px(x + 6, y + 6, 1)
px(x + 15, y + 14, 1)

# 44 袜子与戏剧
x, y = joker(43)
j_card(x + 2, y + 4, 9, 14, 7)
j_card(x + 13, y + 4, 9, 14, 7)
glyph("J", x + 4, y + 6, 1)
glyph("Q", x + 15, y + 6, 59)
pip(1, x + 5, y + 12, 1, 1)
pip(2, x + 16, y + 12, 1, 59)

# 45 特技演员
x, y = joker(44)
fill(x + 5, y + 3, 14, 12, 41)
rect(x + 5, y + 3, 14, 12, 1)
glyph("+", x + 10, y + 5, 7)
glyph("2", x + 7, y + 11, 7)
glyph("5", x + 11, y + 11, 7)
glyph("0", x + 15, y + 11, 7)
glyph("-", x + 8, y + 18, 59)
glyph("2", x + 12, y + 18, 59)

# 46 蓝图小丑
x, y = joker(45)
fill(x + 4, y + 3, 16, 18, 12)
rect(x + 4, y + 3, 16, 18, 42)
for i in range(1, 4):
    line(x + 5, y + 3 + i * 4, x + 19, y + 3 + i * 4, 40)
for i in range(1, 4):
    line(x + 4 + i * 4, y + 4, x + 4 + i * 4, y + 20, 40)
circ(x + 12, y + 12, 3, 44)

# 47 头脑风暴
x, y = joker(46)
circ(x + 11, y + 9, 7, 8)
circ(x + 7, y + 13, 4, 8)
circ(x + 16, y + 13, 4, 8)
line(x + 10, y + 6, x + 13, y + 9, 30)
line(x + 13, y + 9, x + 11, y + 9, 24)
line(x + 11, y + 9, x + 14, y + 12, 30)
fill(x + 8, y + 18, 8, 3, 12)

# 48 男爵
x, y = joker(47)
art(x + 4, y + 4, ["y..y..y..y..y", "yy.yy.yy.yy.y", "yyyyyyyyyyyyy", "yyyyyyyyyyyyy",
                  "y.y.y.y.y.y.y"], {"y": 30})
fill(x + 6, y + 9, 12, 3, 29)
j_face(x + 6, y + 12, 21, smile=1)
line(x + 9, y + 19, x + 14, y + 19, 1)

# 49 星座小丑
x, y = joker(48)
circ(x + 12, y + 12, 9, 12)
stars = [(6, 8), (11, 4), (17, 7), (19, 13), (14, 18), (8, 17)]
for i in range(len(stars) - 1):
    line(x + stars[i][0], y + stars[i][1], x + stars[i + 1][0], y + stars[i + 1][1], 10)
for sx, sy in stars:
    px(x + sx, y + sy, 31)
    px(x + sx - 1, y + sy, 8)
    px(x + sx + 1, y + sy, 8)
    px(x + sx, y + sy - 1, 8)
    px(x + sx, y + sy + 1, 8)

# 50 DNA小丑
x, y = joker(49)
for a in range(16):
    yy = y + 2 + a
    dx = round(6 * math.sin(a * 0.4))
    px(x + 12 + dx, yy, 41)
    px(x + 12 - dx, yy, 59)
    if a % 4 == 2:
        line(x + 12 - dx, yy, x + 12 + dx, yy, 8)

# 51 棒球卡
x, y = joker(50)
circ(x + 12, y + 11, 7, 7)
circ(x + 12, y + 11, 6, 8)
for a in [0, 1, 2]:
    px(x + 8 + a * 4, y + 5 + (a % 2), 59)
    px(x + 9 + a * 4, y + 17 - (a % 2), 59)
line(x + 9, y + 7, x + 15, y + 15, 5)

# 52 钢铁小丑
x, y = joker(51)
j_card(x + 5, y + 3, 14, 18, 6)
rect(x + 5, y + 3, 14, 18, 8)
for i in range(3):
    line(x + 6, y + 5 + i * 5, x + 17, y + 5 + i * 5, 5)
glyph("x", x + 8, y + 16, 42)
glyph("3", x + 13, y + 16, 42)

# ================================================================ LOGO（Fusion 固件字形 ×2）
# font.bin：F12\0 + u32 数量；变长条目保存步进、bbox 与逐行 1bpp 位图。
_fb = open("assets/font.bin", "rb").read()
assert _fb[:4] == b"F12\0"
_cnt = struct.unpack("<I", _fb[4:8])[0]
FG = {}
_off = 8
for _ in range(_cnt):
    cp = struct.unpack("<I", _fb[_off:_off + 4])[0]
    advance = _fb[_off + 4]
    bx, by = struct.unpack("<bb", _fb[_off + 5:_off + 7])
    wd, ht = _fb[_off + 7:_off + 9]
    stride = (wd + 7) // 8
    bitmap = _fb[_off + 9:_off + 9 + stride * ht]
    points = [(bx + x, by + y) for y in range(ht) for x in range(wd)
              if bitmap[y * stride + x // 8] >> (7 - x % 8) & 1]
    FG[cp] = (advance, points)
    _off += 9 + stride * ht
assert _off == len(_fb)

LOGO_Y = 296
word = "BALATRO"
offs = [-2, 1, -1, 2, 0, -2, 1]
ink_rows = set()
for ch in word:
    _, points = FG[ord(ch)]
    ink_rows.update(y for _, y in points)
y0 = min(ink_rows)
for li, ch in enumerate(word):
    _, points = FG[ord(ch)]
    lx = 2 + li * 18
    ly = LOGO_Y + 4 + offs[li] - y0
    for dx, dy in [(-2, 0), (2, 0), (0, -2), (0, 2), (-2, -2), (2, 2), (-2, 2), (2, -2)]:
        for x, y in points:
            fill(lx + x * 2 + dx, ly + y * 2 + dy, 2, 2, 1)
    for x, y in points:
        fill(lx + x * 2, ly + y * 2, 2, 2, 59)
for yy in range(LOGO_Y, LOGO_Y + 40):
    for xx in range(0, 130):
        if S[yy * W + xx] == 59 and yy > LOGO_Y + 18:
            S[yy * W + xx] = 61

# ================================================================ icon.bin
icon = bytearray(256)
for j in range(16):
    for i in range(16):
        icon[j * 16 + i] = 13
# 16×16 小丑脸
j_hat_i = ["..r.........r...", "..rr.......rr...", ".rerr.....rerr..", ".rrrr....rrrr...",
           "..rrrrrrrrrrr...", "...rrrrrrrrr....", "....rrrrrrr.....",
           "....ssssss......", "...ssssssss.....", "...sWssssWss....", "...ssssssss.....",
           "....ssssss......", "....s.ss.s......", ".....s..s......."]
for j, row in enumerate(j_hat_i):
    for i, ch in enumerate(row):
        icon[j * 16 + i] = {"r": 59, "e": 34, "s": 21, "W": 7, ".": 13}[ch]

# ================================================================ SFX
sfx = bytearray(128 * 112)


def N(midi):
    return midi - 11


def put_sfx(idx, speed, steps, loop_end=None):
    base = idx * 112
    ln = len(steps)
    sfx[base] = speed
    sfx[base + 1] = ln
    sfx[base + 2] = 0
    sfx[base + 3] = loop_end if loop_end else ln
    sfx[base + 4] = 0
    for i in range(32):
        a = base + 16 + i * 3
        if i < ln:
            p, w, v, fx = steps[i]
            sfx[a] = p & 0xFF
            sfx[a + 1] = ((w & 0xF) << 4) | (v & 0xF)
            sfx[a + 2] = fx & 0x7
        else:
            sfx[a] = 0
            sfx[a + 1] = 0
            sfx[a + 2] = 0


SQ, P25, P12, ORG, REED, BELL, BASS, BIT = 3, 4, 5, 6, 7, 10, 11, 13
NLD, NSH = 14, 15

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

pat = bytearray(64 * 16)
for i in range(8):
    base = i * 16
    bar = BPM_BARS[i]
    pat[base + 0] = bass_ids[bar] + 1
    pat[base + 1] = chord_ids[bar] + 1
    pat[base + 2] = mel_ids[i] + 1
    pat[base + 6] = 83    # SFX 82 → 引用 83
    pat[base + 7] = 84    # SFX 83 → 引用 84
    flags = 1 if i == 0 else 0
    if i == 7:
        flags = 1 | 2
    pat[base + 8] = flags

# ================================================================ 输出
# FC-16 精灵表按瓦片连续存储（SPEC §4.1）：瓦片 (tu,tv) 占 256B，
# 地址 = (tv*16+tu)*256 + 行*16 + 列。画布按行主序书写，导出时重排。
out = bytearray(W * H)
for y in range(H):
    tv, ty = divmod(y, 16)
    row = y * W
    for x in range(W):
        tu, tx = divmod(x, 16)
        out[(tv * 16 + tu) * 256 + ty * 16 + tx] = S[row + x]
with open(f"{OUT}/sprites.bin", "wb") as f:
    f.write(out)
with open(f"{OUT}/icon.bin", "wb") as f:
    f.write(icon)
with open(f"{OUT}/sfx.bin", "wb") as f:
    f.write(sfx)
with open(f"{OUT}/patterns.bin", "wb") as f:
    f.write(pat)
print(f"精灵表 {W}x{H}，SFX 128 条，Pattern 8 段 —— 写出至 {OUT}/")
