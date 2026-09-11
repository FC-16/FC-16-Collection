# -*- coding: utf-8 -*-
"""魔塔 SWF 美术/音频提取脚本（demo/magetower/extract_art.py）

从两份原版 Flash（24 层 / 50 层魔塔）中提取图像与声音 tag，产出：
  _source/art24/、_source/art50/   位图 PNG（img_<id>.png）、按导出名解出的
                                   图块帧 PNG（<name>_f<帧>.png）、结构索引
                                   structure.json、全量联络表 _sheet_*.png
  _source/audio/                   每个声音 tag 一个原始文件 + sounds.json

SWF 容器解析（CWS 解压、tag 遍历、DefineSprite 递归）复用 extract_swf.py 的
实现；两份 SWF 的保护壳（DoAction 诱饵跳转）只影响字节码，tag 流本身完好，
图像/声音 tag 可直接按规范解析。

两作图块的存储方式：导出的 MovieClip（ExportAssets 命名 mt_XX / IconN）内含
1-N 帧动画，每帧是若干 DefineShape 图层——位图平铺填充（形状=定位方块）或
纯矢量填色。本脚本优先用 FFDec（可选依赖，获取方式同 extract_swf.py）把每
个 sprite 按真实 Flash 语义渲染成逐帧 PNG；没有 FFDec 时退回纯 Python：
自实现的 DefineShape2/3 解析 + 偶奇扫描线栅格化（位图/矢量/描边简化渲染）。

支持的图像 tag（SWF 6 时代规格）：
  6  DefineBits        JPEG 数据（共享 8 号 JPEGTables 头）
  20 DefineBitsLossless   zlib：3=colormap(RGB) / 4=RGB555 / 5=RGB888
  21 DefineBitsJPEG2   完整 JPEG（兼容 Adobe 历史 bug：FFD9FFD8 开头剥掉）
  35 DefineBitsJPEG3   JPEG + zlib 压缩的 8bit alpha 平面
  36 DefineBitsLossless2  同 20，颜色带 alpha（3=RGBA colormap / 5=ARGB）
  注：本作两文件 DefineBitsLossless 格式 5 的像素按 ARGB 字节序存放
  （byte0 实测恒为 0xFF），按规范"保留字节"读会把红蓝互换，此处按实测处理。
声音 tag（14 DefineSound）按格式落盘：2=MP3 直接导出原始帧；
0=LE PCM 转 WAV；其余导出原始字节留档（元数据见 sounds.json）。

用法：
  python extract_art.py <24层魔塔.swf> <50层魔塔.swf> [--outdir _source]
                        [--ffdec ffdec-cli.jar]
  FFDec 查找顺序与 extract_swf.py 相同（--ffdec / FFDEC_JAR / ./ffdec/），
  额外尝试 <outdir>/ffdec/ffdec-cli.jar。不带参数时打印本说明。
"""
import json
import os
import struct
import sys
import wave
import zlib
import io
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_swf import load_body, find_ffdec  # noqa: E402  复用容器解析与 FFDec 查找


# ---------------------------------------------------------------- 位流工具

class BitReader:
    def __init__(self, data, pos):
        self.data, self.pos, self.bit = data, pos, 0

    def u(self, n):
        v = 0
        for _ in range(n):
            b = self.data[self.pos]
            v = (v << 1) | ((b >> (7 - self.bit)) & 1)
            self.bit += 1
            if self.bit == 8:
                self.bit = 0
                self.pos += 1
        return v

    def s(self, n):
        v = self.u(n)
        if n and (v >> (n - 1)):
            v -= 1 << n
        return v

    def align(self):
        if self.bit:
            self.bit = 0
            self.pos += 1


def swf_rect(data, p):
    nbits = data[p] >> 3
    return p + (5 + nbits * 4 + 7) // 8


def parse_matrix(br):
    """MATRIX → dict（twips 平移 + 缩放/旋转，仅用于语义与填充采样）"""
    m = {}
    if br.u(1):
        nb = br.u(5)
        m["sx"] = br.s(nb) / 65536.0
        m["sy"] = br.s(nb) / 65536.0
    if br.u(1):
        nb = br.u(5)
        m["rs"] = br.s(nb) / 65536.0
        m["re"] = br.s(nb) / 65536.0
    nb = br.u(5)
    m["tx"] = br.s(nb)
    m["ty"] = br.s(nb)
    br.align()
    return m


def parse_cxform(br, with_alpha):
    """CXform(WithAlpha)：逐通道 8.8 定点乘 + 加，运行时上色的关键。"""
    has_add = br.u(1)
    has_mult = br.u(1)
    nb = br.u(4)
    cx = {"mult": [1.0, 1.0, 1.0, 1.0], "add": [0.0, 0.0, 0.0, 0.0]}
    if has_mult:
        cx["mult"] = [br.s(nb) / 256.0 for _ in range(4 if with_alpha else 3)]
    if has_add:
        cx["add"] = [br.s(nb) for _ in range(4 if with_alpha else 3)]
    br.align()
    return cx


def compose_cx(outer, inner):
    """外层 CXform ∘ 内层 CXform（像素先经内层再经外层）。"""
    if not outer:
        return inner
    if not inner:
        return outer
    m = [outer["mult"][i] * inner["mult"][i] for i in range(4)]
    a = [outer["add"][i] + outer["mult"][i] * inner["add"][i] for i in range(4)]
    return {"mult": m, "add": a}


def apply_cx(img, cx):
    """把 CXform 应用到 RGBA 图像（Flash 运行时语义：c' = c×mult + add）。"""
    if not cx or img is None:
        return img
    mult, add = cx["mult"], cx["add"]
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            px[x, y] = (
                max(0, min(255, int(r * mult[0] + add[0]))),
                max(0, min(255, int(g * mult[1] + add[1]))),
                max(0, min(255, int(b * mult[2] + add[2]))),
                max(0, min(255, int(a * mult[3] + add[3]))))
    return out


# ---------------------------------------------------------------- 图像解码

def decode_lossless(data, has_alpha):
    cid = struct.unpack_from("<H", data, 0)[0]
    fmt = data[2]
    w, h = struct.unpack_from("<HH", data, 3)
    p = 7
    if fmt == 3:
        n = data[p] + 1
        p += 1
    z = zlib.decompress(data[p:])
    img = Image.new("RGBA", (w, h))
    pix = img.load()
    if fmt == 3:  # colormap
        bpp = 4 if has_alpha else 3
        table = []
        for i in range(n):
            e = z[i * bpp:(i + 1) * bpp]
            table.append(tuple(e) if has_alpha else (e[0], e[1], e[2], 255))
        stride = (w + 3) & ~3
        for y in range(h):
            row = z[n * bpp + y * stride: n * bpp + y * stride + w]
            for x in range(w):
                pix[x, y] = table[row[x]]
    elif fmt == 4:  # RGB555（2B/px，行按 32bit 对齐）
        stride = (w * 2 + 3) & ~3
        for y in range(h):
            base = y * stride
            for x in range(w):
                v = struct.unpack_from("<H", z, base + x * 2)[0]
                pix[x, y] = ((v >> 10 & 31) * 255 // 31,
                             (v >> 5 & 31) * 255 // 31,
                             (v & 31) * 255 // 31, 255)
    elif fmt == 5:  # 32bit/px：本作两文件按 ARGB 存（byte0 实测 0xFF=不透明）
        for i, (a, r, g, b) in enumerate(
                struct.iter_unpack("<BBBB", z[:w * h * 4])):
            pix[i % w, i // w] = (r, g, b, a if has_alpha else 255)
    else:
        raise ValueError("未知 lossless 格式 %d" % fmt)
    return cid, img


def decode_jpeg(raw):
    """PIL 解 JPEG；兼容 Adobe 以 FFD9FFD8 开头的历史 bug。"""
    if raw[:4] == b"\xff\xd9\xff\xd8":
        raw = raw[4:]
    img = Image.open(io.BytesIO(raw))
    return img.convert("RGB")


def decode_image(code, data, jpeg_tables):
    """返回 (cid, RGBA PIL Image)。"""
    cid = struct.unpack_from("<H", data, 0)[0]
    if code == 6:  # DefineBits：表头在共享 JPEGTables
        return cid, decode_jpeg((jpeg_tables or b"") + data[2:]).convert("RGBA")
    if code == 21:  # DefineBitsJPEG2
        return cid, decode_jpeg(data[2:]).convert("RGBA")
    if code == 35:  # DefineBitsJPEG3：JPEG + zlib alpha
        (off,) = struct.unpack_from("<I", data, 2)
        img = decode_jpeg(data[6:6 + off]).convert("RGB")
        alpha = zlib.decompress(data[6 + off:])
        w, h = img.size
        stride = (w + 3) & ~3
        img = img.convert("RGBA")
        pix = img.load()
        for y in range(h):
            base = y * stride
            for x in range(w):
                r, g, b, _ = pix[x, y]
                pix[x, y] = (r, g, b, alpha[base + x])
        return cid, img
    if code in (20, 36):
        return decode_lossless(data, has_alpha=(code == 36))
    return cid, None


# ---------------------------------------------------------------- 结构遍历

class Catalog:
    """一次遍历收集全部角色定义与引用关系。"""

    def __init__(self):
        self.images = {}        # cid -> (tagcode, bytes)
        self.jpeg_tables = b""
        self.exports = {}       # name -> cid
        self.sounds = {}        # cid -> bytes
        self.sprites = {}       # sprite cid -> [placement dict]（遍历序，参考用）
        self.sprite_ranges = {}  # sprite cid -> (tag 起始, tag 结束)
        self.sprite_frames = {}  # sprite cid -> [每帧显示列表]
        self.shape_fills = {}   # shape cid -> [(位图 id, 填充矩阵)]
        self.shape_defs = {}    # shape cid -> (tagcode, s, e)
        self.timeline = []      # 根时间线摆放（语义参考）

    def place(self, code, data, s, ctx):
        try:
            rec = place_record(code, data, s)
        except Exception:
            return
        if rec is None:
            return
        if ctx is None:
            self.timeline.append(rec)
        else:
            self.sprites.setdefault(ctx, []).append(rec)

    def build_sprite_frames(self, data):
        """按 DefineSprite 内部时间线重建每帧的显示列表。

        sprite_frames[sid] = [ {depth: {char, cx, m}}, ... ]；
        ShowFrame 切帧，RemoveObject/RemoveObject2 移除深度。
        """
        for sid, rng in self.sprite_ranges.items():
            p, end = rng
            disp = {}
            frames = [{}]
            while p + 2 <= end:
                (cl,) = struct.unpack_from("<H", data, p)
                code = cl >> 6
                ln = cl & 0x3F
                p += 2
                if ln == 0x3F:
                    (ln,) = struct.unpack_from("<I", data, p)
                    p += 4
                s = p
                p += ln
                if code == 1:
                    frames.append(dict(disp))
                elif code in (5, 28):  # RemoveObject / RemoveObject2
                    disp.pop(struct.unpack_from("<H", data, s + 2)[0], None)
                elif code in (4, 26, 70):
                    try:
                        rec = place_record(code, data, s)
                    except Exception:
                        continue
                    if rec is None:
                        continue
                    if rec["char"] is not None:
                        disp[rec["depth"]] = {"char": rec["char"],
                                              "cx": rec["cxform"],
                                              "m": rec["matrix"]}
                    elif rec.get("move") and rec["depth"] in disp:
                        if rec["cxform"]:
                            disp[rec["depth"]]["cx"] = rec["cxform"]
                    else:
                        disp.pop(rec["depth"], None)
            out = [frames[0]]
            for f in frames[1:]:
                if f != out[-1]:
                    out.append(f)
            self.sprite_frames[sid] = out

    def resolve_frames(self, cid, cx=None, depth=0):
        """角色 → [(PIL RGBA 帧, 源标签)]；sprite 按时间线逐帧合成图层。"""
        if depth > 6:
            return []
        if cid in self.images:
            return [("img", cid, cx, None)]
        if cid in self.shape_defs:
            if cid in self.shape_fills:
                return [("fill", b, cx, m) for b, m in self.shape_fills[cid]]
            return [("vec", cid, cx, None)]
        if cid in self.sprite_ranges:
            out = []
            for fi, disp in enumerate(self.sprite_frames.get(cid, [])):
                if not disp:
                    continue
                layers = [disp[d] for d in sorted(disp)]
                out.append(("comp", (fi, layers), cx, None))
            return out
        return []

    def build_frame(self, data, item, imgs, size_px=32, depth=0):
        """把 resolve_frames 的一项渲染成 RGBA 图像（合成递归）。"""
        kind = item[0]
        cx = item[2]
        if kind == "img":
            base = imgs.get(item[1])
            return apply_cx(base, cx) if base is not None else None
        if kind == "fill":
            base = imgs.get(item[1])
            if base is None:
                return None
            return apply_cx(bitmap_fill_frame(base, item[3], size_px), cx)
        if kind == "vec":
            try:
                scode, ss, se = self.shape_defs[item[1]]
                sp = ShapeParser(scode, data, ss, se).parse()
                return apply_cx(shape_to_image(sp, size_px), cx)
            except Exception:
                return None
        if kind == "comp":
            layers = item[1][1]
            # 画布取各图层首帧的最大尺寸（96×96 大图块不裁剪）
            subs = []
            w = h = size_px
            for lay in layers:
                fr = self.resolve_frames(lay["char"],
                                         compose_cx(cx, lay["cx"]), depth + 1)
                if fr:
                    img = self.build_frame(data, fr[0], imgs, size_px,
                                           depth + 1)
                    if img is not None:
                        subs.append(img)
                        w, h = max(w, img.width), max(h, img.height)
            canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            for img in subs:
                canvas.alpha_composite(img)
            return canvas
        return None


def place_record(code, data, s):
    """PlaceObject 1/2/3 → {char, depth, name, matrix, cxform}。

    字段顺序按 SWF 规范：Depth, [CharacterId], [Matrix], [ColorTransform],
    [Ratio], [Name], [ClipDepth]。
    """
    if code == 4:  # PlaceObject：cid+depth+matrix
        cid = struct.unpack_from("<H", data, s)[0]
        depth = struct.unpack_from("<H", data, s + 2)[0]
        m = parse_matrix(BitReader(data, s + 4))
        return {"char": cid, "depth": depth, "name": None, "matrix": m,
                "cxform": None}
    if code == 26:  # PlaceObject2
        flags = data[s]
        depth = struct.unpack_from("<H", data, s + 1)[0]
        q = s + 3
        cid = None
        if flags & 0x02:
            cid = struct.unpack_from("<H", data, q)[0]
            q += 2
        m = cx = None
        if flags & 0x04:
            br = BitReader(data, q)
            m = parse_matrix(br)
            q = br.pos
        if flags & 0x08:
            br = BitReader(data, q)
            cx = parse_cxform(br, True)
            q = br.pos
        if flags & 0x10:  # HasRatio
            q += 2
        name = None
        if flags & 0x20:  # HasName
            z = data.index(b"\x00", q)
            name = data[q:z].decode("utf-8", "replace")
        return {"char": cid, "depth": depth, "name": name, "matrix": m,
                "cxform": cx, "move": not (flags & 0x02)}
    # PlaceObject3：两组 flags 字节（2003 年代文件极少用，尽力而为）
    f1 = data[s]
    depth = struct.unpack_from("<H", data, s + 2)[0]
    q = s + 4
    cid = None
    if f1 & 0x02:
        cid = struct.unpack_from("<H", data, q)[0]
        q += 2
    m = cx = None
    if f1 & 0x04:
        br = BitReader(data, q)
        m = parse_matrix(br)
        q = br.pos
    if f1 & 0x08:
        br = BitReader(data, q)
        cx = parse_cxform(br, True)
        q = br.pos
    if f1 & 0x10:
        q += 2
    name = None
    if f1 & 0x20:
        z = data.index(b"\x00", q)
        name = data[q:z].decode("utf-8", "replace")
    return {"char": cid, "depth": depth, "name": name, "matrix": m,
            "cxform": cx, "move": not (f1 & 0x02)}


def shape_fill_bitmaps(cat, data, s, e, code):
    """解析形状的填充样式，返回位图填充 (bid, matrix) 列表。"""
    try:
        sp = ShapeParser(code, data, s, e).parse()
    except Exception:
        return []
    out = []
    for t, payload in sp["fills"]:
        if t == "bitmap":
            out.append(payload)
    return out


def traverse(cat, data, off, end, ctx):
    p = off
    while p + 2 <= end:
        (cl,) = struct.unpack_from("<H", data, p)
        code = cl >> 6
        ln = cl & 0x3F
        p += 2
        if ln == 0x3F:
            (ln,) = struct.unpack_from("<I", data, p)
            p += 4
        s = p
        p += ln
        if code == 8:  # JPEGTables
            cat.jpeg_tables = data[s:s + ln]
        elif code in (6, 20, 21, 35, 36):
            cid = struct.unpack_from("<H", data, s)[0]
            cat.images[cid] = (code, data[s:s + ln])
        elif code == 14:  # DefineSound
            cat.sounds[struct.unpack_from("<H", data, s)[0]] = data[s:s + ln]
        elif code == 56:  # ExportAssets
            q = s
            try:
                (n,) = struct.unpack_from("<H", data, q)
                q += 2
                for _ in range(n):
                    cid = struct.unpack_from("<H", data, q)[0]
                    q += 2
                    z = data.index(b"\x00", q)
                    cat.exports[data[q:z].decode("utf-8", "replace")] = cid
                    q = z + 1
            except (struct.error, ValueError):
                pass  # 尾部残缺记录不阻塞其余导出
        elif code in (4, 26, 70):
            cat.place(code, data, s, ctx)
        elif code == 39:  # DefineSprite：id(2B)+帧数(2B)+子 tag 流
            sid = struct.unpack_from("<H", data, s)[0]
            cat.sprite_ranges[sid] = (s + 4, s + ln)
            traverse(cat, data, s + 4, s + ln, sid)
        elif code in (2, 22, 32):  # DefineShape：记录定义与位图填充
            cid = struct.unpack_from("<H", data, s)[0]
            cat.shape_defs[cid] = (code, s, s + ln)
            fills = shape_fill_bitmaps(cat, data, s, s + ln, code)
            if fills:
                cat.shape_fills[cid] = fills


# ---------------------------------------------------------------- 形状解析与栅格化
#
# 两作的图块层级是：导出 MovieClip → DefineShape（方块定位 + 位图平铺填充/
# 纯矢量填色）。位图填充直接引用位图 id；纯矢量形状（灵杖、圣殿块等）需要
# 栅格化才能得到像素。这里实现完整的 DefineShape2/3 记录解析 + 简易扫描线
# 渲染（偶奇填充 + 折线描边）；有 FFDec 时优先使用 FFDec 渲染结果。

class ShapeParser:
    """解析单个 DefineShape2/3：填充样式、线样式与全部路径。"""

    def __init__(self, code, data, s, e):
        self.ver = 3 if code == 32 else 2
        self.data = data
        self.s, self.e = s, e

    # ---- 字节级样式数组 ----
    def read_styles(self, p, with_alpha):
        """返回 (fills, lines, p)；fills=[(type, 载荷)]，lines=[(宽, 色)]。"""
        data = self.data
        n = data[p]
        p += 1
        if n == 0xFF:
            n = struct.unpack_from("<H", data, p)[0]
            p += 2
        fills = []
        for _ in range(n):
            t = data[p]
            p += 1
            if t == 0x00:  # solid
                if with_alpha:
                    col = (data[p], data[p + 1], data[p + 2], data[p + 3])
                    p += 4
                else:
                    col = (data[p], data[p + 1], data[p + 2], 255)
                    p += 3
                fills.append(("solid", col))
            elif 0x10 <= t <= 0x13:  # 渐变
                br = BitReader(data, p)
                parse_matrix(br)
                p = br.pos
                ng = data[p]
                p += 1
                records = []
                step = 5 if with_alpha else 4
                for _ in range(ng):
                    records.append((data[p], tuple(data[p + 1:p + 1 + step])))
                    p += 1 + step
                p += 2  # EndRecode
                fills.append(("gradient%d" % (t & 3), records))
            elif 0x40 <= t <= 0x43:  # 位图平铺/裁剪
                bid = struct.unpack_from("<H", data, p)[0]
                br = BitReader(data, p + 2)
                m = parse_matrix(br)
                p = br.pos
                fills.append(("bitmap", (bid, m)))
            else:
                raise ValueError("未知填充类型 0x%02x" % t)
        n = data[p]
        p += 1
        if n == 0xFF:
            n = struct.unpack_from("<H", data, p)[0]
            p += 2
        lines = []
        for _ in range(n):
            w = struct.unpack_from("<H", data, p)[0]
            p += 2
            if with_alpha:
                lines.append((w, (data[p], data[p + 1], data[p + 2], data[p + 3])))
                p += 4
            else:
                lines.append((w, (data[p], data[p + 1], data[p + 2], 255)))
                p += 3
        return fills, lines, p

    # ---- 路径记录 ----
    def parse(self):
        data = self.data
        p = self.s + 2  # ShapeId
        nb = data[p] >> 3
        p += (5 + nb * 4 + 7) // 8  # ShapeBounds
        fills, lines, p = self.read_styles(p, self.ver == 3)
        br = BitReader(data, p)
        nfill = br.u(4)
        nline = br.u(4)
        paths = []      # {f0, f1, ln, subs: [[(x,y)...]]}
        cur = None      # 当前 path
        sub = None      # 当前子路径
        x = y = 0
        while True:
            if br.u(1) == 0:
                break
            if br.u(1) == 1:  # StyleChange
                if br.u(1):  # StateNewStyles
                    br.align()
                    fills, lines, p2 = self.read_styles(br.pos, self.ver == 3)
                    br = BitReader(data, p2)
                    nfill = br.u(5)
                    nline = br.u(5)
                if br.u(1):  # StateLineStyle
                    ln_i = br.u(nline)
                    self._close(cur, sub, paths)
                    cur, sub = {"f0": 0, "f1": 0, "ln": ln_i, "subs": []}, None
                if br.u(1):  # StateFillStyle1
                    f1 = br.u(nfill)
                    if cur is None or (cur["f1"] != f1 and cur["subs"]):
                        self._close(cur, sub, paths)
                        cur, sub = {"f0": 0, "f1": f1, "ln": 0, "subs": []}, None
                    else:
                        cur["f1"] = f1
                if br.u(1):  # StateFillStyle0
                    f0 = br.u(nfill)
                    if cur is None or (cur["f0"] != f0 and cur["subs"]):
                        self._close(cur, sub, paths)
                        cur, sub = {"f0": f0, "f1": 0, "ln": 0, "subs": []}, None
                    else:
                        cur["f0"] = f0
                if br.u(1):  # StateMoveTo
                    mb = br.u(5)
                    x = br.s(mb)
                    y = br.s(mb)
                    if cur is not None:
                        if sub and len(sub) > 1:
                            cur["subs"].append(sub)
                        sub = None
                    sub = [(x, y)]
            else:  # 边
                if cur is None:
                    cur, sub = {"f0": 0, "f1": 0, "ln": 0, "subs": []}, [(x, y)]
                if sub is None:
                    sub = [(x, y)]
                if br.u(1):  # 直线边
                    nb2 = br.u(4) + 2
                    if br.u(1):  # general
                        x += br.s(nb2)
                        y += br.s(nb2)
                    elif br.u(1):  # vertical
                        y += br.s(nb2)
                    else:
                        x += br.s(nb2)
                else:  # 二次曲线：8 段折线近似
                    nb2 = br.u(4) + 2
                    cx, cy = x + br.s(nb2), y + br.s(nb2)
                    ex, ey = cx + br.s(nb2), cy + br.s(nb2)
                    for i in range(1, 9):
                        t = i / 8.0
                        px = (1 - t) ** 2 * x + 2 * (1 - t) * t * cx + t * t * ex
                        py = (1 - t) ** 2 * y + 2 * (1 - t) * t * cy + t * t * ey
                        sub.append((px, py))
                    x, y = ex, ey
        self._close(cur, sub, paths)
        return {"fills": fills, "lines": lines, "paths": paths,
                "bounds": self._bounds(paths)}

    @staticmethod
    def _close(cur, sub, paths):
        if cur is None:
            return
        if sub and len(sub) > 1:
            cur["subs"].append(sub)
        if cur["subs"]:
            paths.append(cur)

    @staticmethod
    def _bounds(paths):
        xs = [pt[0] for p in paths for sub in p["subs"] for pt in sub]
        ys = [pt[1] for p in paths for sub in p["subs"] for pt in sub]
        if not xs:
            return (0, 0, 0, 0)
        return (min(xs), min(ys), max(xs), max(ys))


def rasterize_shape(shape, size, scale_to=None):
    """把解析出的形状渲染成 size*S 超采样 RGBA（调用方负责缩小）。

    scale_to = (x0, y0, x1, y1)：形状 twips 坐标 → 画布映射（缺省取路径范围）。
    本函数只处理 solid/gradient 填充与描边；位图填充的形状在 resolve 阶段
    直接落到引用的位图，不经过这里。
    """
    S = 4  # 4× 超采样
    W = size * S
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    x0, y0, x1, y1 = scale_to if scale_to else shape["bounds"]
    if x1 <= x0 or y1 <= y0:
        return canvas

    def tx(pt):
        return ((pt[0] - x0) * W / (x1 - x0), (pt[1] - y0) * W / (y1 - y0))

    def evenodd_polys(subs, color):
        if not color[3]:
            return
        edges = []
        for sub in subs:
            pts = [tx(p) for p in sub]
            for i in range(len(pts)):
                a, b = pts[i], pts[(i + 1) % len(pts)]
                if a[1] != b[1]:
                    edges.append((a, b))
        ys = [pt[1] for sub in subs for pt in map(tx, sub)]
        yy = int(min(ys))
        ye = int(max(ys)) + 1
        rowpix = {}
        for ry in range(max(0, yy), min(W, ye)):
            yc = ry + 0.5
            xs = []
            for (a, b) in edges:
                if (a[1] <= yc < b[1]) or (b[1] <= yc < a[1]):
                    xs.append(a[0] + (yc - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                xa, xb = int(xs[i]), int(xs[i + 1]) + 1
                if xb > xa:
                    rowpix.setdefault(ry, []).append((max(0, xa), min(W, xb)))
        px = canvas.load()
        for ry, runs in rowpix.items():
            for xa, xb in runs:
                for rx in range(xa, xb):
                    px[rx, ry] = color

    def stroke(subs, width_twips, color):
        if not color[3] or not width_twips:
            return
        wpx = width_twips * W / (x1 - x0)
        for sub in subs:
            pts = [tx(p) for p in sub]
            draw.line(pts, fill=color, width=max(1, int(wpx)), joint="curve")

    fills = shape["fills"]
    lines = shape["lines"]
    for p in shape["paths"]:
        if p["ln"]:
            c = lines[p["ln"] - 1] if p["ln"] <= len(lines) else None
            if c:
                stroke(p["subs"], c[0], c[1])
        for key in ("f1", "f0"):
            fi = p[key]
            if fi:
                fs = fills[fi - 1] if fi <= len(fills) else None
                if fs and fs[0] == "solid":
                    evenodd_polys(p["subs"], fs[1])
                elif fs and fs[0].startswith("gradient"):
                    recs = fs[1]
                    # 简化：用记录中间色作整体填充
                    mid = recs[len(recs) // 2][1]
                    if len(mid) == 3:
                        mid = mid + (255,)
                    evenodd_polys(p["subs"], mid)
    return canvas


def shape_to_image(shape, size=32):
    """渲染形状（映射整个 32px=640twips 单元，越界部分并入范围）并缩放。"""
    bx0, by0, bx1, by1 = shape["bounds"]
    scale_to = (min(0, bx0), min(0, by0), max(640, bx1), max(640, by1))
    img = rasterize_shape(shape, size, scale_to)
    return img.resize((size, size), Image.LANCZOS)


def bitmap_fill_frame(img, m, cell=32):
    """按填充矩阵把位图（平铺/缩放）采样到 cell×cell 的 32px 单元。

    SWF 位图填充矩阵把位图像素空间映射到形状 twips 空间：
    X_twips = bx·sx + tx；此处反向采样，平铺按位图尺寸取模。
    """
    sx = m.get("sx", 1.0) if m else 1.0
    sy = m.get("sy", 1.0) if m else 1.0
    tx = m.get("tx", 0) if m else 0
    ty = m.get("ty", 0) if m else 0
    if abs(sx - 1.0) < 1e-9 and abs(sy - 1.0) < 1e-9 and tx == 0 and ty == 0 \
            and img.width == cell and img.height == cell:
        return img  # 恒等：直接使用
    out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
    px, po = img.load(), out.load()
    for y in range(cell):
        Y = y * 20
        by = (Y - ty) / sy
        by = by % img.height if img.height else 0
        iy = int(by) % img.height
        for x in range(cell):
            X = x * 20
            bx = (X - tx) / sx
            bx = bx % img.width if img.width else 0
            po[x, y] = px[int(bx) % img.width, iy]
    return out


# ---------------------------------------------------------------- 声音导出

SOUND_RATES = {0: 5512, 1: 11025, 2: 22050, 3: 44100}
SOUND_FMTS = {0: "pcm", 1: "adpcm", 2: "mp3", 3: "pcmbe", 6: "nelly"}


def export_sound(cid, data, outdir, prefix):
    flags = data[2]
    fmt = flags >> 4
    rate = SOUND_RATES[(flags >> 2) & 3]
    bits16 = (flags >> 1) & 1
    stereo = flags & 1
    (samples,) = struct.unpack_from("<I", data, 3)
    body = data[7:]
    meta = {"fmt": SOUND_FMTS.get(fmt, str(fmt)), "rate": rate,
            "bits": 16 if bits16 else 8, "channels": stereo + 1,
            "samples": samples, "sec": round(samples / rate, 2)}
    if fmt == 2 and len(body) > 4:  # MP3：跳过 SeekSamples+RecordCount
        out, fext = body[4:], ".mp3"
        meta["seek"], meta["framesamples"] = struct.unpack_from("<hH", body, 0)
    elif fmt == 0:  # 无压缩 LE PCM → WAV
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wv:
            wv.setnchannels(stereo + 1)
            wv.setsampwidth(2 if bits16 else 1)
            wv.setframerate(rate)
            wv.writeframes(body)
        out, fext = buf.getvalue(), ".wav"
    else:
        out, fext = body, ".%s.bin" % meta["fmt"]
    name = "%s_c%03d%s" % (prefix, cid, fext)
    with open(os.path.join(outdir, name), "wb") as f:
        f.write(out)
    meta["file"] = name
    return meta


# ---------------------------------------------------------------- 联络表

def contact_sheet(images, out, labels, per_row=8, cell=132):
    if not images:
        return
    ids = sorted(images)
    rows = (len(ids) + per_row - 1) // per_row
    sheet = Image.new("RGB", (per_row * cell, rows * cell), (40, 40, 48))
    d = ImageDraw.Draw(sheet)
    for i, key in enumerate(ids):
        img = images[key]
        x0, y0 = (i % per_row) * cell, (i // per_row) * cell
        thumb = img.convert("RGBA")
        thumb.thumbnail((cell - 8, cell - 26))
        bg = Image.new("RGB", (cell - 8, cell - 26), (90, 90, 110))
        bg.paste(thumb, ((cell - 8 - thumb.width) // 2,
                         (cell - 26 - thumb.height) // 2), thumb)
        sheet.paste(bg, (x0 + 4, y0 + 22))
        d.text((x0 + 4, y0 + 4), "%s %s" % (labels[key], img.size),
               fill=(255, 220, 120))
    sheet.save(out)


# ---------------------------------------------------------------- FFDec 协同

def ffdec_sprites(ffdec_jar, swf_path, outdir):
    """FFDec 渲染全部 DefineSprite 为逐帧 PNG（真实 Flash 合成语义）。"""
    import shutil
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp(prefix="mtart_")
    safe = os.path.join(tmp, "m.swf")
    with open(swf_path, "rb") as f, open(safe, "wb") as g:
        g.write(f.read())
    cmd = ["java", "-jar", ffdec_jar, "-format", "sprite:png",
           "-export", "sprite", outdir, safe]
    subprocess.run(cmd, check=True, capture_output=True, timeout=900)
    shutil.rmtree(tmp, ignore_errors=True)


def load_ffdec_frames(spr_dir, cid, name, max_frames=4):
    """读取 FFDec 导出的 DefineSprite_<cid>_<name>/ 逐帧 PNG。"""
    d = os.path.join(spr_dir, "DefineSprite_%d_%s" % (cid, name))
    if not os.path.isdir(d):
        return []
    out = []
    for fn in os.listdir(d):
        stem, ext = os.path.splitext(fn)
        if ext == ".png" and stem.isdigit():
            out.append((int(stem), os.path.join(d, fn)))
    out.sort()
    return [p for _, p in out[:max_frames]]


# ---------------------------------------------------------------- 主流程

def extract(swf_path, outdir, tag, ffdec_arg=None):
    art_dir = os.path.join(outdir, "art" + tag)
    aud_dir = os.path.join(outdir, "audio")
    os.makedirs(art_dir, exist_ok=True)
    os.makedirs(aud_dir, exist_ok=True)

    body = load_body(swf_path)
    cat = Catalog()
    traverse(cat, body, swf_rect(body, 0) + 4, len(body), None)
    cat.build_sprite_frames(body)

    # --- 位图 → PNG（原始 dump） ---
    imgs = {}
    manifest = {}
    for cid, (code, blob) in sorted(cat.images.items()):
        try:
            _, img = decode_image(code, blob, cat.jpeg_tables)
        except Exception as ex:
            print("  [warn] 图像 c%d (tag %d) 解码失败: %s" % (cid, code, ex))
            continue
        imgs[cid] = img
        name = "img_%03d.png" % cid
        img.save(os.path.join(art_dir, name))
        manifest[str(cid)] = {"tag": code, "w": img.width, "h": img.height,
                              "file": name}
    print("  位图 %d 张" % len(imgs))

    # --- FFDec 精灵渲染（真实 Flash 合成，含矢量/渐变/描边/逐层混合） ---
    spr_dir = os.path.join(art_dir, "ffdec_sprites")
    jar = find_ffdec(ffdec_arg or os.path.join(outdir, "ffdec", "ffdec-cli.jar"))
    if jar:
        try:
            os.makedirs(spr_dir, exist_ok=True)
            ffdec_sprites(jar, swf_path, spr_dir)
            print("  FFDec 精灵渲染完成（%s）" % os.path.basename(jar))
        except Exception as ex:
            print("  [warn] FFDec 渲染失败，退回纯 Python 合成: %s" % ex)
            jar = None
    else:
        print("  未找到 FFDec，精灵帧退回纯 Python 合成（矢量形状将缺失）")

    # --- 导出名 → 逐帧图（优先 FFDec 渲染，纯 Python 兜底） ---
    resolved = {}
    frames_out = {}
    for name, cid in sorted(cat.exports.items()):
        files = []
        via = None
        if jar and cid in cat.sprite_ranges:
            files = load_ffdec_frames(spr_dir, cid, name)
            via = "ffdec"
        if not files:
            files = []
            for item in cat.resolve_frames(cid)[:4]:
                img = cat.build_frame(body, item, imgs, 32)
                if img is not None and img.getbbox() is not None:
                    fn = os.path.join(art_dir,
                                      "_py_%s_%d.png" % (name, len(files) + 1))
                    img.save(fn)
                    files.append(fn)
            via = "python"
        if not files:
            continue
        entry = {"char": cid, "via": via, "frames": []}
        for i, fp in enumerate(files):
            img = Image.open(fp).convert("RGBA")
            fn = "%s_f%d.png" % (name, i + 1)
            img.save(os.path.join(art_dir, fn))
            frames_out[fn] = img
            entry["frames"].append({"file": fn})
        resolved[name] = entry
    print("  导出角色 %d 个（解出 %d 条）" % (len(cat.exports), len(resolved)))

    structure = {
        "images": manifest,
        "exports": cat.exports,
        "resolved": resolved,
        "sprites": {str(k): v for k, v in sorted(cat.sprites.items())},
        "timeline": [{"char": r["char"], "name": r["name"], "depth": r["depth"],
                      "cxform": r["cxform"]} for r in cat.timeline],
    }
    with open(os.path.join(art_dir, "structure.json"), "w", encoding="utf-8") as f:
        json.dump(structure, f, ensure_ascii=False, indent=1)

    # --- 联络表：全部位图 / 解析后的图块帧 ---
    contact_sheet(imgs, os.path.join(art_dir, "_sheet_all.png"),
                  {k: "c%s" % k for k in imgs})
    contact_sheet(frames_out, os.path.join(art_dir, "_sheet_frames.png"),
                  {k: k[:-4] for k in frames_out}, per_row=8, cell=116)

    # --- 声音留档 ---
    sounds = {}
    for cid, blob in sorted(cat.sounds.items()):
        try:
            sounds[str(cid)] = export_sound(cid, blob, aud_dir, "t" + tag)
        except Exception as ex:
            print("  [warn] 声音 c%d 导出失败: %s" % (cid, ex))
    with open(os.path.join(aud_dir, "t%s_sounds.json" % tag), "w",
              encoding="utf-8") as f:
        json.dump(sounds, f, ensure_ascii=False, indent=1)
    if sounds:
        print("  声音 %d 条（%s）" % (len(sounds), aud_dir))
    return imgs


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    outdir = "_source"
    ffdec = None
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--outdir":
            outdir = args[i + 1]
            i += 2
            continue
        if args[i] == "--ffdec":
            ffdec = args[i + 1]
            i += 2
            continue
        rest.append(args[i])
        i += 1
    for swf in rest:
        tag = "50" if "50" in os.path.basename(swf) else "24"
        print("提取 %s → art%s" % (os.path.basename(swf), tag))
        extract(swf, outdir, tag, ffdec)


if __name__ == "__main__":
    main()
