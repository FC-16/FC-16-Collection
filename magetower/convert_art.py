# -*- coding: utf-8 -*-
"""魔塔图块转换脚本（demo/magetower/convert_art.py）

把 extract_art.py 从原版 SWF 解出的图块帧（_source/art24/、_source/art50/，
本地不入库）转换成 FC-16 精灵数据，并把生成的 Lua 数据块写回
两个卡带源 .lua 的标记区间：

  -- BEGIN GENERATED ART (from _source) / -- END GENERATED ART

流程：32px 原版位图 → 2×2 区域平均降采样到 16px → 逐像素映射到
SPEC §2.2 的 ENDESGA-64 64 色调色板（读 assets/palette.dat）→
每图块 ≤16 色 + RLE 游程编码 → Lua 表。
透明区（含半透明权重不足的边缘）映射为颜色 0；不透明近黑像素改映射到
色号 1（#1B1B1B），避免与"颜色 0 默认透明"的精灵语义冲突。

图块语义映射（TILE_SPECS）按两版 SWF 的 ExportAssets 导出名建立：
24 层版 mt_XX 与地图值 XX 同名同义；50 层版 IconN 与 DefObj_array 的
图标值 N 同名同义。个别无原版导出的值用最近语义替身，见各条注释。

用法：
  python convert_art.py            # 重建并写回两张卡带源的美术块
  python convert_art.py --sheet    # 额外输出 _source/_tile_sheet.png 核对图
"""
import json
import os
import sys

from PIL import Image, ImageDraw

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))  # 仓库根：assets/palette.dat
SRC = os.path.join(HERE, "_source")
# 拆分后的两个卡带源共用同一份生成美术块
LUA_TARGETS = [os.path.join(HERE, "..", "mota24", "mota24.lua"),
               os.path.join(HERE, "..", "mota50", "mota50.lua")]
BEGIN = "-- BEGIN GENERATED ART (from _source)"
END = "-- END GENERATED ART"

# 游程编码用 64 个可打印 ASCII 字符（Lua 源码内安全）
ALPHA = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


# ---------------------------------------------------------------- 图块布局
# (图块 id, 版本, 源导出名, 帧号, 模式)
# 模式：""=32px 直接降采样；"crop96"=96px 取中上 64px 再降采样（大怪物）；
#       "fit"=裁到不透明内容后撑满 32px（门/墙/栅栏等满格结构，源画布带边距）；
#       "frame32"=裁到内容后等比缩放居中（大画布上的不满格道具）；
#       "center32"=取源图居中 32×32 单元（96px 宽幅结构，如 50F 商店）；
#       "flat:RRGGBB"=纯色块（50F 地板灰）。
def tile_specs():
    s = []
    # ---- 24 层版地形与道具（值 → mt_XX 同名导出） ----
    m24 = {
        0: "mt_00",   # 石板地（可走地面）
        1: "mt_01",   # 边界砖墙
        2: "mt_20",   # 塔壁（星空填充墙）
        3: "mt_19",   # 血肉红墙（序章外围 / 地下圣域）
        4: "mt_15",   # 铁栅栏
        6: "mt_02",   # 黄门
        7: "mt_03",   # 蓝门
        8: "mt_04",   # 红门
        9: "mt_05",   # 魔王门（三灵杖）
        10: "mt_01",  # 暗门：原版与普通墙同图（撞开才显现）
        11: "mt_06",  # 黄钥匙
        12: "mt_07",  # 蓝钥匙
        13: "mt_08",  # 红钥匙
        14: "mt_10",  # 红宝石（攻击+3）
        15: "mt_09",  # 蓝宝石（防御+3）
        16: "mt_11",  # 小血瓶
        17: "mt_12",  # 大血瓶
        18: "mt_13",  # 上楼梯
        19: "mt_14",  # 下楼梯
        20: "mt_71",  # 铁剑（地图拾取件，侧栏同图）
        21: "mt_72",  # 银剑
        22: "mt_73",  # 骑士剑
        23: "mt_74",  # 圣光剑
        24: "mt_75",  # 金色圣光剑
        25: "mt_76",  # 铁盾
        26: "mt_77",  # 银盾
        27: "mt_78",  # 骑士盾
        28: "mt_79",  # 圣光盾
        29: "mt_80",  # 金色圣光盾
        30: "mt_39",  # 金币袋
        31: "mt_36",  # 钥匙盒
        32: "mt_30",  # 小飞羽
        33: "mt_31",  # 大飞羽
        34: "mt_33",  # 圣水
        35: "mt_201",  # 冰之灵杖
        36: "mt_202",  # 炎之灵杖
        37: "mt_203",  # 心之灵杖
        38: "mt_22",  # 商店
        39: "mt_24",  # 仙子
        40: "mt_25",  # 小偷
        41: "mt_26",  # 老者（26 号剧情人）
        42: "mt_27",  # 商人（27 号剧情人）
        43: "mt_28",  # 国王（28 号剧情人）
        44: "mt_34",  # 神秘宝物 34（原版图 34）
        45: "mt_35",  # 神秘宝物 35
        46: "mt_37",  # 神秘宝物 37
        47: "mt_38",  # 神秘宝物 38（小偷的工具）
    }
    for tid, name in m24.items():
        s.append((tid, "24", name, 1, ""))
    for i in range(31):  # 怪物 0..30 → mt_40..mt_70 → 图块 48..78
        s.append((48 + i, "24", "mt_%d" % (40 + i), 1, ""))
    s.append((241, "24", "mt_21", 1, ""))  # 栏杆变体（原值 21）
    s.append((242, "24", "mt_23", 1, ""))  # 门形栅栏（原值 23）
    # 24F 圣殿 3×3：181..189 → 133..141；开启后 191..199 → 142..150
    for i in range(9):
        s.append((133 + i, "24", "mt_%d" % (181 + i), 1, ""))
        s.append((142 + i, "24", "mt_%d" % (191 + i), 1, ""))
    s.append((122, "24", "mt_185", 1, ""))   # 通用演出块兜底（素色圣殿面）
    s.append((123, "24", "mt_99", 1, ""))    # 24F 主角（12 帧行走取首帧）
    s.append((124, "24", "mt_188", 1, ""))   # 血影
    # ---- 两版共用：50 层版来源 ----
    s.append((5, "50", "Icon100", 1, ""))    # 暗墙/50F 城墙（砖）
    s.append((125, "50", "Icon32", 1, "crop96"))   # 50F 魔龙 96px 取头部
    s.append((126, "50", "Icon15", 1, ""))   # 宝箱（50F 石像箱怪物格）
    s.append((127, "50", "Icon111", 1, ""))  # 熔岩
    s.append((128, "50", "Icon82", 1, ""))   # 怪物手册/卷轴
    s.append((129, "50", "Icon85", 1, ""))   # 圣光十字架
    s.append((130, "50", "Icon90", 1, ""))   # 镐
    s.append((131, "50", "Icon92", 1, ""))   # 炸弹
    s.append((132, "50", "Icon94", 1, ""))   # 传送之翼
    # ---- 50 层版专属 ----
    s.append((244, "50", "", 0, "flat:808080"))  # 244=50F 平灰地板（原版纯灰）
    s.append((223, "50", "Icon112", 1, ""))  # 圣殿星空墙
    s.append((224, "50", "Icon107", 1, ""))  # 结界门
    s.append((225, "50", "Icon110", 2, ""))  # 单向门（首帧为空，取帧 2）
    s.append((226, "50", "Icon101", 1, ""))  # 上楼梯（50F 款）
    s.append((227, "50", "Icon102", 1, ""))  # 下楼梯（50F 款）
    s.append((228, "50", "Icon103", 1, ""))  # 黄门（50F 款）
    s.append((229, "50", "Icon104", 1, ""))  # 蓝门
    s.append((230, "50", "Icon105", 1, ""))  # 红门
    s.append((231, "50", "Icon106", 1, ""))  # 蓝门（破损变体）
    for i in range(6):  # 121..126 装饰砖 → 232..237
        s.append((232 + i, "50", "Icon%d" % (121 + i), 1, ""))
    s.append((238, "24", "mt_99", 1, ""))    # 50F 主角（原版 Player 精灵带雷光
    #    特效层，本体与 24F 主角同一形象，故取 24F 干净帧）
    s.append((239, "50", "Icon87", 1, ""))   # 屠龙匕（栏标）
    s.append((240, "50", "Icon88", 1, ""))   # 圣水（50F 款，栏标）
    s.append((196, "50", "Icon51", 1, ""))   # 50F 商店
    for i in range(5):  # NPC 52..56 → 197..201
        s.append((197 + i, "50", "Icon%d" % (52 + i), 1, ""))
    s.append((202, "50", "Icon61", 1, ""))   # 黄钥匙（50F 款）
    s.append((203, "50", "Icon62", 1, ""))   # 蓝钥匙
    s.append((204, "50", "Icon63", 1, ""))   # 红钥匙
    s.append((205, "50", "Icon64", 1, ""))   # 小血瓶
    s.append((206, "50", "Icon65", 1, ""))   # 大血瓶
    s.append((207, "50", "Icon66", 1, ""))   # 红宝石
    s.append((208, "50", "Icon67", 1, ""))   # 蓝宝石
    for i in range(5):  # 剑 71..75 → 209..213
        s.append((209 + i, "50", "Icon%d" % (71 + i), 1, ""))
    for i in range(5):  # 盾 76..80 → 214..218
        s.append((214 + i, "50", "Icon%d" % (76 + i), 1, ""))
    s.append((219, "50", "Icon83", 1, ""))   # 冰魔法之杖（栏标）
    s.append((220, "50", "Icon84", 1, ""))   # 魔杖
    s.append((221, "50", "Icon89", 1, ""))   # 钥匙盒（50F 款）
    s.append((222, "50", "Icon86", 1, ""))   # 幸运金币
    for i in range(35):  # 50F 怪物 icon 1..35 → 161..195
        mode = "crop96" if (35 + i) in (17,) else ""  # 大乌贼 96px
        s.append((161 + i, "50", "Icon%d" % (1 + i), 1, mode))
    # 满格结构（栅栏/门/城墙/装饰砖）：源画布带边距，裁到内容后撑满 16×16，
    # 否则结构被压扁、两侧透明露出黑背景
    FIT = {4, 5, 6, 7, 8, 9, 224, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237}
    # 大画布上的不满格道具：取内容帧等比居中
    FRAME = {128, 129, 130, 131, 132, 239, 240}
    # 宽幅结构（96px 商店）：取居中单元
    CENTER = {196}
    return [(tid, tag, name, fr, "fit" if tid in FIT else
             "frame32" if tid in FRAME else
             "center32" if tid in CENTER else md)
            for tid, tag, name, fr, md in s]


# ---------------------------------------------------------------- 转换

def load_palette():
    pal = []
    with open(os.path.join(ROOT, "assets", "palette.dat"), "rb") as f:
        d = f.read()
    for i in range(64):
        pal.append((d[i * 3], d[i * 3 + 1], d[i * 3 + 2]))
    return pal


PAL = None


def nearest(r, g, b):
    """最近的调色板色号；不透明近黑映射到 1 号，避免与透明 0 号冲突。"""
    best, bi = 1 << 30, 0
    for i, (pr, pg, pb) in enumerate(PAL):
        dr, dg, db = r - pr, g - pg, b - pb
        d = dr * dr * 2 + dg * dg * 4 + db * db  # 视觉加权
        if d < best:
            best, bi = d, i
    return 1 if bi == 0 else bi


def down16(img):
    """区域平均降采样到 16×16（按 alpha 加权；源为 32/96 方块）。"""
    n = img.width // 16
    out = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    po, pi = out.load(), img.load()
    for y in range(16):
        for x in range(16):
            r = g = b = a = 0
            for dy in range(n):
                for dx in range(n):
                    pr, pg, pb, pa = pi[x * n + dx, y * n + dy]
                    r += pr * pa
                    g += pg * pa
                    b += pb * pa
                    a += pa
            if a < 255 * n * n // 2:
                po[x, y] = (0, 0, 0, 0)
            else:
                po[x, y] = (r // a, g // a, b // a, 255)
    return out


def crop96(img):
    """96px 大怪物：取中上部 64px（头与双翼）再降采样。"""
    return img.crop((16, 16, 80, 80)).resize((32, 32), Image.LANCZOS)


def encode_tile(idx16):
    """16×16 色号矩阵 → "调色板|游程串"（≤16 色 + 4bit 游程）。"""
    used = []
    for c in idx16:
        if c not in used:
            used.append(c)
    # 超过 16 色时合并出现最少的色号（实测原版图块极少触发）
    if len(used) > 16:
        cnt = [(idx16.count(c), c) for c in used]
        cnt.sort(reverse=True)
        keep = {c for _, c in cnt[:16]}
        drop = {c: None for _, c in cnt[16:]}
        remap = {}
        for c in list(used):
            if c in drop:
                near = min((k for k in keep), key=lambda k: abs(k - c))
                remap[c] = near
        idx16 = [remap.get(c, c) for c in idx16]
        used = [c for c in used if c not in drop]
    pal_s = ",".join(str(c) for c in used)
    pos = {c: i for i, c in enumerate(used)}
    runs = []
    i = 0
    while i < 256:
        c = idx16[i]
        n = 1
        while i + n < 256 and idx16[i + n] == c and n < 16:
            n += 1
        runs.append(ALPHA[pos[c]] + ALPHA[n - 1])
        i += n
    return "%s|%s" % (pal_s, "".join(runs))


def dense32(img):
    """FFDec 帧画布是全帧动画内容的并集：取不透明像素最密的 32×32 窗口。"""
    if img.width == 32 and img.height == 32:
        return img
    p = img.load()
    w, h = img.width, img.height
    cs = [[0] * (w + 1) for _ in range(h + 1)]  # 积分图：不透明像素计数
    for y in range(h):
        row = cs[y + 1]
        prev = cs[y]
        for x in range(w):
            row[x + 1] = row[x] + prev[x + 1] - prev[x] + \
                (1 if p[x, y][3] > 0 else 0)
    best, bx, by = -1, 0, 0
    for y in range(max(1, h - 31)):
        for x in range(max(1, w - 31)):
            cnt = cs[y + 32][x + 32] - cs[y][x + 32] - cs[y + 32][x] + cs[y][x]
            if cnt > best:
                best, bx, by = cnt, x, y
    return img.crop((bx, by, bx + 32, by + 32))


def convert(spec, out_sheet=None):
    tid, tag, name, frame, mode = spec
    if mode.startswith("flat:"):
        rgb = tuple(int(mode[5 + i * 2:7 + i * 2], 16) for i in range(3))
        img = Image.new("RGBA", (16, 16), rgb + (255,))
        return [nearest(*rgb)] * 256, img
    path = os.path.join(SRC, "art" + tag, "%s_f%d.png" % (name, frame))
    if not os.path.exists(path):
        # 34/35 号怪物图标无原版导出且地图数据从未使用：留空并告警
        print("[warn] 缺少源图 %s（图块 %d 留空）" % (path, tid))
        return [0] * 256, Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    img = Image.open(path).convert("RGBA")
    if mode in ("fit", "frame32", "center32"):
        if mode == "fit":
            bb = img.getchannel("A").getbbox()
            if bb:
                img = img.crop(bb)
            img = img.resize((32, 32), Image.LANCZOS)
        elif mode == "frame32":
            bb = img.getchannel("A").getbbox()
            if bb:
                img = img.crop(bb)
            if img.width > 32 or img.height > 32:
                sc = 32 / max(img.width, img.height)
                img = img.resize(
                    (max(1, round(img.width * sc)), max(1, round(img.height * sc))),
                    Image.LANCZOS)
            canvas = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
            canvas.paste(img, ((32 - img.width) // 2, (32 - img.height) // 2))
            img = canvas
        else:  # center32：宽幅结构取居中单元，不整块压扁
            if img.width > 32 or img.height > 32:
                bx, by = (img.width - 32) // 2, (img.height - 32) // 2
                img = img.crop((bx, by, bx + 32, by + 32))
            else:
                img = dense32(img)
    elif mode == "crop96":
        if img.width != 96:
            img = img.resize((96, 96), Image.LANCZOS)
        img = crop96(img)
    elif img.width != 32 or img.height != 32:
        if img.width % 16 == 0 and img.height % 16 == 0 and \
                max(img.width, img.height) > 64:
            img = img.resize((32, 32), Image.LANCZOS)  # 整块大图（96px+）缩小
        else:
            img = dense32(img)  # 双帧/并集画布（32×64 等）：取最密 32×32
    img16 = down16(img)
    p = img16.load()
    idx = []
    for y in range(16):
        for x in range(16):
            r, g, b, a = p[x, y]
            idx.append(0 if a == 0 else nearest(r, g, b))
    return idx, img16


def build_title_tiles():
    """原版标题干净帧 → 全屏瓦片 256..511（256×256 px，16×16 格）。

    从 FFDec 渲染的 1100 帧（标题，无帮助浮层）取边框整体，等比缩放居中；
    原版菜单三行（位图书法）擦除，由游戏用固件字重绘（24/50 层选择是
    本移植的合并功能）。背景不透明（近黑色 1），需要
    _source/title_render/1100.png（重建步骤见 README）。
    """
    path = os.path.join(SRC, "title_render", "1100.png")
    if not os.path.exists(path):
        print("[warn] 缺少 %s（标题图跳过，卡带用旧标题）" % path)
        return {}
    img = Image.open(path).convert("RGB")
    a = np.asarray(img, dtype=np.int16)
    # 擦除原版菜单三行（开始游戏 / 游戏说明 / 离开游戏），保留 Ver 字样
    for y0, y1 in ((214, 250), (270, 305), (322, 358)):
        a[y0:y1, 110:440] = 0
    im = Image.fromarray(a.astype(np.uint8))
    # 边框盒 (89, 22, 537, 384) 等比缩放 s=0.55 → 246×199，画布居中；
    # 亮度 <60 的帮助弹窗残影清除（魔塔/花体字主体 ≥70 不受影响）
    crop = im.crop((89, 22, 537, 384)).resize((246, 199), Image.LANCZOS)
    canvas = Image.new("RGB", (256, 256), (0, 0, 0))
    canvas.paste(crop, (5, 28))
    p = canvas.load()
    out = {}
    for ty in range(16):
        for tx in range(16):
            idx = []
            for y in range(16):
                for x in range(16):
                    pr, pg, pb = p[tx * 16 + x, ty * 16 + y]
                    v = pr + pg + pb
                    if v < 60 * 3:
                        idx.append(1)
                    else:
                        idx.append(nearest(pr, pg, pb))
            out[256 + ty * 16 + tx] = encode_tile(idx)
    return out


def main():
    global PAL
    sheet_only = "--sheet" in sys.argv
    PAL = load_palette()
    specs = tile_specs()
    tiles, thumbs = {}, {}
    for spec in specs:
        idx, img16 = convert(spec)
        tiles[spec[0]] = encode_tile(idx)
        thumbs[spec[0]] = img16
    tiles.update(build_title_tiles())
    print("生成图块 %d 张（含标题图 %d 张）"
          % (len(tiles), 16 * 16 if 256 in tiles else 0))

    lines = [
        BEGIN,
        "-- 由 convert_art.py 从原版 SWF 提取图块生成（_source/ 不入库），勿手改。",
        "-- 每图块 = \"色号表|游程串\"：色号表为逗号分隔的 SPEC §2.2 色号，",
        "-- 游程串每两字符为 (本图块色序号, 重复数-1)，字母表见 ART_ALPHA。",
        "function bake_generated_art()",
        "  local ART_ALPHA = \"%s\"" % ALPHA,
        "  local ART_TILES = {",
    ]
    for tid in sorted(tiles):
        lines.append("    [%d]=%s," % (tid, json.dumps(tiles[tid])))
    lines += [
        "  }",
        "  for id, s in pairs(ART_TILES) do",
        "    local pal_s, px = s:match(\"([^|]*)|(.*)\")",
        "    local pal, n = {}, 0",
        "    for v in pal_s:gmatch(\"%d+\") do",
        "      n = n + 1",
        "      pal[n] = tonumber(v)",
        "    end",
        "    local base, p = id * 256, 0",
        "    for i = 1, #px, 2 do",
        "      local c = pal[ART_ALPHA:find(px:sub(i, i), 1, true)]",
        "      for _ = 1, ART_ALPHA:find(px:sub(i + 1, i + 1), 1, true) do",
        "        poke(base + p, c)",
        "        p = p + 1",
        "      end",
        "    end",
        "  end",
        "end",
        END,
    ]
    block = "\n".join(lines) + "\n"

    for lua in LUA_TARGETS:
        src = open(lua, encoding="utf-8").read()
        b = src.find(BEGIN)
        e = src.find(END)
        if b >= 0 and e > b:
            src = src[:b] + block + src[e + len(END) + 1:]
        else:
            marker = "-- ================================================================ 配色"
            b = src.find(marker)
            if b < 0:
                raise SystemExit("%s 中找不到插入点" % lua)
            src = src[:b] + block + "\n" + src[b:]
        with open(lua, "w", encoding="utf-8") as f:
            f.write(src)
        print("已写回 %s（美术块 %d KB）" % (lua, len(block) // 1024))

    if sheet_only or True:  # 核对图始终输出到 _source（不入库）
        cols, cell = 16, 96
        ids = sorted(thumbs)
        rows = (len(ids) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell, rows * cell + 4), (70, 70, 84))
        d = ImageDraw.Draw(sheet)
        for i, tid in enumerate(ids):
            x, y = (i % cols) * cell, (i // cols) * cell + 4
            im = thumbs[tid].resize((64, 64), Image.NEAREST)
            sheet.paste(im, (x + 4, y + 24), im)
            d.text((x + 4, y + 6), str(tid), fill=(255, 220, 120))
        sheet.save(os.path.join(SRC, "_tile_sheet.png"))
        print("核对图 _source/_tile_sheet.png")


if __name__ == "__main__":
    main()
