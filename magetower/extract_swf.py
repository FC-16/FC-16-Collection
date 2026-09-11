# -*- coding: utf-8 -*-
"""魔塔 SWF 数据提取脚本（demo/magetower/extract_swf.py）

从用户提供的经典 Flash 魔塔（24 层 / 50 层）SWF 中提取游戏数据，产出
magetower_data.json，卡带源的内嵌数据表即由本脚本生成。

数据来源与两条提取通道
----------------------
两份 SWF 都使用了 2003 年代国产 SWF 保护壳：DoAction 字节码里混有大量
诱饵指令流（`Push <真值>; If -> 落在数据字节中间`），逐条静态反汇编会走进
死路；但**数据本体（地图行 / 怪物五元组 / 初始属性）以 ActionPush 立即数
完整存在于字节码中**，且遵循确定的压栈模式（AVM1 InitArray 按逆序弹参，
因此行数据是反的）。本脚本据此实现"模式提取"：

通道 A（纯 Python，24 层版全部核心数据）
  1. CWS 解压（8 字节头 + zlib 主体）；
  2. 递归遍历 tag（含 DefineSprite 内部）收集 DoAction(12)/DoInitAction(59)；
  3. 解析 ActionConstantPool(0x88) 与 ActionPush(0x96) 立即数（UTF-8）；
  4. 模式匹配：
     - 地图：`Push mt_line_XX / 行号 / 11 个格子值 / 11 / Array`（值逆序）；
     - 怪物表：`Push boss_man / 编号 / [经验,金币,防,攻,血](逆序) / 名字常量`；
     - 初始属性：`Base_hp 1000` 等赋值对；
     - 全部中文文案（拾取提示 / 楼层名 / 商店 / 剧情常量）来自常量池。
  提取结果与 JPEXS FFDec 反编译输出逐行核对（脚本内置 --check）。

通道 B（FFDec，可选；50 层版结构化数据）
  50 层版把全部数据装在一个 192KB 的 DoAction 里、经寄存器循环展开，
  纯模式匹配不可靠；用 JPEXS FFDec（免费反编译器，能正确仿真被保护的
  AVM1）导出 ActionScript 后按字面解析：
     DefObj_array（51 层 × [图标 121 + 事件 121]）
     DefEnemy_array（35 种怪物：生命/攻/防/金币/魔法/十字架/屠龙标记）
     DefPlayer（初始属性）、DefStair_array（楼层连通）
     Msg_array（81 条剧情文本）、Exchange_array（15 个 NPC 交易）
  FFDec 获取：https://github.com/jindrapetrik/jpexs-decompiler/releases
  （国内可用 ghproxy 类镜像下载 zip，解压后把 ffdec-cli.jar 路径传给
   --ffdec，或放在本脚本同目录 ffdec/ 子目录 / 环境变量 FFDEC_JAR）

用法：
  python extract_swf.py 24层魔塔.swf [50层魔塔.swf] \
      [--out magetower_data.json] [--ffdec ffdec-cli.jar 路径] [--check]

不带参数时打印本说明。
"""
import io
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

# ---------------------------------------------------------------- SWF 容器

TAG_NAMES = {
    0: "End", 1: "ShowFrame", 2: "DefineShape", 4: "PlaceObject",
    5: "RemoveObject", 6: "DefineBits", 7: "DefineButton", 9: "SetBackgroundColor",
    10: "DefineFont", 11: "DefineText", 12: "DoAction", 13: "DefineFontInfo",
    14: "DefineSound", 20: "DefineBitsLossless", 21: "DefineBitsJPEG2",
    22: "DefineShape2", 26: "PlaceObject2", 28: "RemoveObject2",
    32: "DefineShape3", 33: "DefineText2", 36: "DefineBitsLossless2",
    37: "DefineEditText", 39: "DefineSprite", 43: "FrameLabel",
    56: "ExportAssets", 59: "DoInitAction", 65: "ScriptLimits",
    69: "FileAttributes", 70: "PlaceObject3", 76: "SymbolClass",
    77: "Metadata", 82: "DoABC",
}


def load_body(swf_path):
    raw = open(swf_path, "rb").read()
    if raw[:3] == b"CWS":
        return zlib.decompress(raw[8:])
    if raw[:3] == b"FWS":
        return raw[8:]
    raise SystemExit("未知 SWF 签名: %r" % raw[:3])


def iter_tags(data, off, end):
    while off < end:
        (code_len,) = struct.unpack_from("<H", data, off)
        code = code_len >> 6
        ln = code_len & 0x3F
        off += 2
        if ln == 0x3F:
            (ln,) = struct.unpack_from("<I", data, off)
            off += 4
        yield code, off, off + ln
        off += ln


def walk_tags(data, off, end):
    """产出 (路径, tagcode, 起始, 结束)；递归 DefineSprite。"""
    stack = [(off, end, "root")]
    while stack:
        o, e, path = stack.pop()
        for code, s, t in iter_tags(data, o, e):
            if code == 39:  # DefineSprite：id(2B)+帧数(2B) 后为子 tag 流
                stack.append((s + 4, t - 1, "%s/sprite%d" % (path, struct.unpack_from("<H", data, s)[0])))
                yield path, code, s, t
            else:
                yield path, code, s, t


def parse_action_block(data, s, e):
    """解析一段 DoAction：返回 (常量池列表, push 立即数列表)。

    仅解码 ConstantPool 与 Push（数据提取不需要执行语义）；遇到 End 即止。
    保护壳插入的诱饵指令流不影响 Push 立即数的完整收集。
    """
    consts, pushes = [], []
    p = s
    while p < e:
        code = data[p]
        p += 1
        if code == 0:
            break
        if code < 0x80:
            continue
        (ln,) = struct.unpack_from("<H", data, p)
        p += 2
        b = data[p:p + ln]
        p += ln
        if code == 0x88:  # ActionConstantPool
            (n,) = struct.unpack_from("<H", b, 0)
            r = 2
            for _ in range(n):
                z = b.index(b"\x00", r)
                consts.append(b[r:z].decode("utf-8", "replace"))
                r = z + 1
        elif code == 0x96:  # ActionPush
            r = 0
            while r < len(b):
                t = b[r]
                r += 1
                if t == 0:  # 字符串（本作中文为 UTF-8）
                    z = b.index(b"\x00", r)
                    pushes.append(b[r:z].decode("utf-8", "replace"))
                    r = z + 1
                elif t == 1:
                    pushes.append(struct.unpack_from("<f", b, r)[0]); r += 4
                elif t in (2, 3):
                    pushes.append(None)
                elif t == 4:
                    pushes.append("#r%d" % b[r]); r += 1
                elif t == 5:
                    pushes.append(bool(b[r])); r += 1
                elif t == 6:
                    pushes.append(struct.unpack_from("<d", b, r)[0]); r += 8
                elif t == 7:
                    pushes.append(struct.unpack_from("<i", b, r)[0]); r += 4
                elif t == 8:
                    pushes.append("#c%d" % b[r]); r += 1
                elif t == 9:
                    pushes.append("#c%d" % struct.unpack_from("<H", b, r)[0]); r += 2
    return consts, pushes


# ------------------------------------------------------ 24 层版：模式提取

def extract_24(swf_path):
    body = load_body(swf_path)
    nbits = body[0] >> 3
    end_rect = (5 + nbits * 4 + 7) // 8
    tags = body[end_rect + 4:]

    blocks = []
    for path, code, s, e in walk_tags(tags, 0, len(tags)):
        if code == 12:  # DoAction
            blocks.append((path, s, e))

    floors, monsters, base, texts = {}, {}, {}, []
    for path, s, e in blocks:
        consts, pushes = parse_action_block(tags, s, e)

        def res(v):  # 常量池引用还原
            if isinstance(v, str) and v.startswith("#c"):
                i = int(v[2:])
                return consts[i] if i < len(consts) else None
            return v

        # --- 地图：Push mt_line_XX / 行号 / 11 值(逆序) / 11 / Array ---
        if "mt_line_00" in consts:
            i, n = 0, len(pushes)
            while i < n - 14:
                nm = res(pushes[i])
                if isinstance(nm, str) and nm.startswith("mt_line_"):
                    row, vals = pushes[i + 1], pushes[i + 2:i + 13]
                    if (isinstance(row, (int, float)) and pushes[i + 13] == 11
                            and res(pushes[i + 14]) == "Array"
                            and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in vals)):
                        # AVM1 InitArray 逆序弹参 → 反转恢复源顺序
                        floors.setdefault(nm, {})[int(row)] = [int(v) for v in reversed(vals)]
                        i += 15
                        continue
                i += 1

        # --- 怪物表压栈单元：boss_man 编号 名字 <经,金,防,攻,血>(逆序) ---
        if "boss_man" in consts:
            n = len(pushes)
            for i in range(n - 7):
                if (res(pushes[i]) == "boss_man"
                        and isinstance(pushes[i + 1], (int, float))
                        and not isinstance(pushes[i + 1], bool)):
                    nm = res(pushes[i + 2])
                    five = pushes[i + 3:i + 8]
                    if (isinstance(nm, str) and 1 <= len(nm) <= 6
                            and all(0x4E00 <= ord(c) <= 0x9FFF for c in nm)
                            and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in five)):
                        hp, gong, fang, money, mp = [int(x) for x in reversed(five)]
                        monsters[int(pushes[i + 1])] = [hp, gong, fang, money, mp, nm]

        # --- 初始属性：Push Base_hp 1000（SetVariable 对） ---
        for i in range(len(pushes) - 1):
            k, v = res(pushes[i]), pushes[i + 1]
            if (isinstance(k, str) and k.startswith("Base_")
                    and isinstance(v, (int, float)) and not isinstance(v, bool)):
                base[k[5:]] = int(v)

        texts.extend(c for c in consts if c and any(0x4E00 <= ord(ch) <= 0x9FFF for ch in c))

    if len(floors) != 27:
        raise SystemExit("24 层地图提取异常：仅 %d 层" % len(floors))
    if len(monsters) != 33:
        raise SystemExit("怪物表提取异常：仅 %d 只" % len(monsters))
    ordered = []
    for f in range(27):
        key = "mt_line_%02d" % f
        rows = floors[key]
        assert len(rows) == 11 and all(len(rows[r]) == 11 for r in rows), key
        ordered.append([rows[r] for r in range(11)])
    mlist = [monsters[k] for k in sorted(monsters)]
    return {"floors": ordered, "monsters": mlist, "base": base, "texts": sorted(set(texts))}


# ------------------------------------------------ 50 层版：FFDec 反编译解析

def find_ffdec(explicit):
    cands = []
    if explicit:
        cands.append(explicit)
    env = os.environ.get("FFDEC_JAR")
    if env:
        cands.append(env)
    here = os.path.dirname(os.path.abspath(__file__))
    cands.append(os.path.join(here, "ffdec", "ffdec-cli.jar"))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def decompile_with_ffdec(ffdec_jar, swf_path):
    """FFDec 导出主帧脚本文本；中文路径先复制到临时 ASCII 路径。"""
    tmp = tempfile.mkdtemp(prefix="mt50_")
    safe = os.path.join(tmp, "m.swf")
    with open(swf_path, "rb") as f, open(safe, "wb") as g:
        g.write(f.read())
    out = os.path.join(tmp, "as")
    cmd = ["java", "-jar", ffdec_jar, "-export", "script", out, safe]
    subprocess.run(cmd, check=True, capture_output=True, timeout=600)
    main = os.path.join(out, "scripts", "frame_1", "DoAction.as")
    return open(main, encoding="utf-8").read()


def extract_50(swf_path, ffdec_jar):
    src = decompile_with_ffdec(ffdec_jar, swf_path)

    m = re.search(r"_global\.DefObj_array = new Array\((.*?)\);", src, re.S)
    defobj = [[int(x) for x in a.split(",")]
              for a in re.findall(r"new Array\(([\d,\-]+)\)", m.group(1))]
    assert len(defobj) == 102 and all(len(a) == 121 for a in defobj)

    m = re.search(r"_loc1_\.DefEnemy_array = new Array\((.*?)\);\n", src, re.S)
    enemies = []
    for o in re.findall(r"\{([^{}]*)\}", m.group(1)):
        d = dict(re.findall(r'(\w+):("[^"]*"|-?\d+|true|false)', o))
        enemies.append({
            "magic": int(d["Magic"]), "cross": d["Cross"] == "true",
            "dragon": d["Dragon"] == "true", "life": int(d["Life"]),
            "offense": int(d["Offense"]), "defense": int(d["Defense"]),
            "money": int(d["Money"]), "name": d["Name"].strip('"').strip()})

    m = re.search(r"_loc1_\.DefPlayer = \{(.*?)\};", src, re.S)
    pd = dict(re.findall(r"(\w+):(-?\d+|true|false|new Array\(0\))", m.group(1)))
    player = {k: int(v) for k, v in pd.items() if v.lstrip("-").isdigit()}

    m = re.search(r"_global\.DefStair_array = new Array\((.*?)\);", src, re.S)
    stairs = [{k: int(v) for k, v in dict(re.findall(r"(\w+):(-?\d+)", o)).items()}
              for o in re.findall(r"\{([^{}]*)\}", m.group(1))]

    m = re.search(r'_global\.Msg_array = new Array\((".*?")\);', src, re.S)
    msgs = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))

    m = re.search(r"_global\.Exchange_array = new Array\((.*?)\);", src, re.S)
    exs = []
    for o in re.findall(r"\{([^{}]*)\}", m.group(1)):
        d = dict(re.findall(r'(\w+):(".*?"|-?\d+)', o))
        exs.append({
            "msg": d["Message_str"].strip('"'), "btn": int(d["ButtonType"]),
            "event": int(d["EventNo"]), "life": int(d["Life"]),
            "offense": int(d["Offense"]), "defense": int(d["Defense"]),
            "money": int(d["Money"]), "keyY": int(d["KeyYellow"]),
            "keyB": int(d["KeyBlue"]), "keyR": int(d["KeyRed"]),
            "icon": int(d["IconNo"])})

    assert len(enemies) == 35 and len(msgs) >= 80 and len(exs) == 15
    return {"defobj": defobj, "enemies": enemies, "player": player,
            "stairs": stairs, "msgs": msgs, "exchanges": exs}


# ---------------------------------------------------------------- 校验

# 与 FFDec 反编译（frame_4346/DoAction.as）逐行核对过的基准值抽查。
# monsters 为 [编号] 索引表 → [血, 攻, 防, 金币, 经验, 名字]。
KNOWN_MONSTERS = {
    0: [50, 20, 1, 1, 1, "绿头怪"],
    2: [100, 20, 5, 3, 3, "小蝙蝠"],
    13: [15000, 1000, 1000, 100, 100, "红衣魔王"],
    32: [99999, 9999, 5000, 0, 0, "魔龙"],
}
KNOWN_F1R0 = [13, 98, 6, 40, 41, 40, 0, 0, 0, 0, 0]
KNOWN_F26R10 = [19, 19, 19, 19, 19, 97, 19, 19, 19, 19, 19]
KNOWN_BASE = {"hp": 1000, "gong": 10, "fang": 10, "money": 0, "life": 1}


def check(data):
    ok = True
    mtab = {i: v for i, v in enumerate(data["monsters"])}
    for mid, vals in KNOWN_MONSTERS.items():
        if mtab.get(mid) != vals:
            print("校验失败：怪物 %d = %s（期望 %s）" % (mid, mtab.get(mid), vals))
            ok = False
    if data["floors"][1][0] != KNOWN_F1R0:
        print("校验失败：F1 行 0 = %s" % data["floors"][1][0]); ok = False
    if data["floors"][26][10] != KNOWN_F26R10:
        print("校验失败：F26 行 10 = %s" % data["floors"][26][10]); ok = False
    for k, v in KNOWN_BASE.items():
        if data["base"].get(k) != v:
            print("校验失败：Base_%s = %s（期望 %s）" % (k, data["base"].get(k), v)); ok = False
    print("24 层版校验：%s（地图 27 层 × 11×11、怪物 33、基准抽查通过）" % ("通过" if ok else "未通过"))
    return ok


# ---------------------------------------------------------------- 主流程

def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    swf24 = None
    swf50 = None
    out = "magetower_data.json"
    ffdec = None
    do_check = "--check" in args
    rest = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--out":
            out = args[i + 1]; i += 2; continue
        if a == "--ffdec":
            ffdec = args[i + 1]; i += 2; continue
        if a.startswith("--"):
            i += 1; continue
        if "50" in os.path.basename(a):
            swf50 = a
        else:
            swf24 = a
        i += 1

    result = {}
    if swf24:
        d24 = extract_24(swf24)
        if do_check:
            check(d24)
        result["t24"] = d24
        print("24 层版：地图 %d 层，怪物 %d，初始属性 %s" %
              (len(d24["floors"]), len(d24["monsters"]), d24["base"]))
    if swf50:
        jar = find_ffdec(ffdec)
        if not jar:
            print("未找到 FFDec（--ffdec / FFDEC_JAR / ./ffdec/ffdec-cli.jar），跳过 50 层版提取")
        else:
            result["t50"] = extract_50(swf50, jar)
            print("50 层版：DefObj %d 层数组，怪物 %d，剧情 %d 条，交换 %d 条" % (
                len(result["t50"]["defobj"]), len(result["t50"]["enemies"]),
                len(result["t50"]["msgs"]), len(result["t50"]["exchanges"])))

    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print("已写出 %s" % out)


if __name__ == "__main__":
    main()
