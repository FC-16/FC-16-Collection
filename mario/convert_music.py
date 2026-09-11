#!/usr/bin/env python3
"""convert_music.py — 把 SuperMarioBros-C 反汇编（docs/smbdis.asm）中的原曲音符表
转写为 FC-16 tracker 数据（SFX 32 步×3B + Pattern 64×16B），并以
「BEGIN GENERATED MUSIC / END」标记区间写回 demo/mario/mario.lua。

数据来源与格式（对应反汇编中的音乐引擎）：
  - MusicHeaderData：每首歌头 = [长度表偏移, 数据地址(lo,hi), 三角偏移, 方波1偏移, (噪声偏移)]
  - 音符流：方波2/三角 d7=1 长度字节(d2-d0 索引长度表)否则音符(d6-d0 频率表字节偏移)；
    方波1/噪声 d0,d7,d6 三位长度，方波1 d5-d1 音符，噪声 d5-d4 节拍型
  - FreqRegLookupTbl：12bit NES 周期表，f = 1789773/(16×(P+1))（三角波低一个八度）
  - MusicLengthLookupTbl：时值表（帧）；$f0 头字节给出各行基址
  - 地上曲按原版段落表拼接成 Pattern 链（BEGIN/END 循环），重复段落引用同一组 SFX

用法：
    python3 convert_music.py            # 重建生成段并写回 mario.lua
    python3 convert_music.py --check    # 只比对 mario.lua 中生成段是否最新
    python3 convert_music.py --report   # 打印曲目/Pattern/SFX 预算报告，不写文件

曲式简化（README「实现说明」同步）：原版「时间告急」后主曲会整体提速演奏，此处
改为播放原版时间告急警号后恢复原速主曲；无敌星曲在星星结束后切回关卡主曲。
"""

import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REF_ASM = Path(r"G:\github\_ref\SuperMarioBros-C\docs\smbdis.asm")
LUA = HERE / "mario.lua"
BEGIN_MARK = "-- BEGIN GENERATED MUSIC (from smbdis via convert_music.py)"
END_MARK = "-- END GENERATED MUSIC"

CPU = 1789773.0

# ---------------------------------------------------------------- asm 解析

def load_asm():
    """解析 .db 数据段 → (labels, order)；无名连续行并入上一标签。"""
    text = REF_ASM.read_text(encoding="utf-8", errors="replace")
    labels, order, cur = {}, [], None
    for line in text.splitlines():
        s = line.split(";", 1)[0].strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):$", s)
        if m:
            cur = m.group(1)
            if cur not in labels:
                labels[cur] = bytearray()
                order.append(cur)
            continue
        if not s:
            continue
        m = re.match(r"^\.db\s+(.*)$", s)
        if m and cur:
            for tok in m.group(1).split(","):
                mm = re.match(r"^\$([0-9A-Fa-f]{1,2})$", tok.strip())
                if mm:
                    labels[cur].append(int(mm.group(1), 16))
    return labels, order


def region(labels, order, first, last):
    """拼接 [first, last) 标签区间为连续字节流（与 ROM 内布局一致）。"""
    out, on = bytearray(), False
    for lb in order:
        if lb == first:
            on = True
        if lb == last:
            break
        if on:
            out += labels[lb]
    return bytes(out)


def parse_headers():
    """头标签行 → {头名: (len_ofs, tri_ofs, sq1_ofs, noise_ofs|None)}。"""
    hdrs = {}
    for line in REF_ASM.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.split(";", 1)[0].strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*Hdr):\s*\.db\s+(.*)$", s)
        if m:
            toks = [t.strip() for t in m.group(2).split(",")]
            vals = []
            for t in toks:
                if t[0] in "<>":
                    vals.append(None)  # 地址引用，偏移另行计算
                else:
                    vals.append(int(t.lstrip("$"), 16))
            if len(vals) < 5:
                continue  # SilenceHdr 等残缺头不参与解码
            hdrs[m.group(1)] = (vals[0], vals[3], vals[4],
                                vals[5] if len(vals) > 5 else None)
    return hdrs


# ---------------------------------------------------------------- 常量表

# FreqRegLookupTbl（16bit 周期，按字节偏移取用）
FREQ_TBL = [
    0x088, 0x02F, 0x000, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A,
    0x1DF, 0x1C4, 0x1AB, 0x193, 0x17C, 0x167, 0x153, 0x140,
    0x12E, 0x11D, 0x10D, 0x0FE, 0x0EF, 0x0E2, 0x0D5, 0x0C9,
    0x0BE, 0x0B3, 0x0A9, 0x0A0, 0x097, 0x08E, 0x086, 0x077,
    0x07E, 0x071, 0x054, 0x064, 0x05F, 0x059, 0x050, 0x047,
    0x043, 0x03B, 0x035, 0x02A, 0x023, 0x475, 0x357, 0x2F9,
    0x2CF, 0x1FC, 0x06A,
]
# MusicLengthLookupTbl（行基址 = 头字节 $f0）
LEN_TBL = [
    0x05, 0x0A, 0x14, 0x28, 0x50, 0x1E, 0x3C, 0x02,
    0x04, 0x08, 0x10, 0x20, 0x40, 0x18, 0x30, 0x0C,
    0x03, 0x06, 0x0C, 0x18, 0x30, 0x12, 0x24, 0x08,
    0x36, 0x03, 0x09, 0x06, 0x12, 0x1B, 0x24, 0x0C,
    0x24, 0x02, 0x06, 0x04, 0x0C, 0x12, 0x18, 0x08,
    0x12, 0x01, 0x03, 0x02, 0x06, 0x09, 0x0C, 0x04,
]
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def period_to_midi(period, tri=False):
    """NES 周期 → MIDI 号（方波 f=CPU/(16×(P+1))，三角波低一个八度）。"""
    if period == 0:
        return 0
    f = CPU / (16.0 * (period + 1))
    if tri:
        f /= 2.0
    return int(round(69 + 12 * math.log2(f / 440.0)))


def note_name(midi):
    return NAMES[midi % 12] + str(midi // 12 - 1)


def freq_midi(idx, tri):
    p = FREQ_TBL[idx // 2] if idx // 2 < len(FREQ_TBL) else 0
    return period_to_midi(p, tri)


# ---------------------------------------------------------------- 音符流解码

def walk_sq2(data, ofs, len_ofs, end_t, tri=False):
    """方波2/三角流 → [(起始帧, 时值, midi)]；$00 终止。"""
    out, t, ln = [], 0, LEN_TBL[len_ofs]
    n = len(data)
    while ofs < n:
        b = data[ofs]
        ofs += 1
        if b == 0:
            break
        if b & 0x80:
            ln = LEN_TBL[len_ofs + (b & 7)]
            continue
        out.append((t, ln, freq_midi(b & 0x7F, tri)))
        t += ln
        if t >= end_t:
            break
    return out


def walk_sq1(data, ofs, len_ofs, end_t):
    """方波1流 → [(起始帧, 时值, midi)]；$00 为备用寄存器标记，跳过。"""
    out, t = [], 0
    n = len(data)
    while ofs < n and t < end_t:
        b = data[ofs]
        ofs += 1
        if b == 0:
            continue
        ln3 = ((b & 1) << 2) | ((b >> 6) & 3)
        out.append((t, LEN_TBL[len_ofs + ln3], freq_midi(b & 0x3E, False)))
        t += LEN_TBL[len_ofs + ln3]
    return out


def walk_noise(data, ofs, len_ofs, loop_ofs, end_t):
    """噪声流 → [(起始帧, 时值, 节拍型 0-3)]；$00 跳回循环点。"""
    out, t, n = [], 0, len(data)
    start = ofs
    while t < end_t and ofs < n:
        b = data[ofs]
        ofs += 1
        if b == 0:
            ofs = loop_ofs if loop_ofs is not None else start
            continue
        ln3 = ((b & 1) << 2) | ((b >> 6) & 3)
        dur = LEN_TBL[len_ofs + ln3]
        out.append((t, dur, (b >> 4) & 3))
        t += dur
    return out


def total_time(events):
    return sum(ln for (_, ln, _) in events)


# ---------------------------------------------------------------- 量化到步进

def quant(events, step, steps, offset):
    """事件流量化到网格：steps 个步，每步取当时发声的音（0=休止）。"""
    grid = []
    for s in range(steps):
        t0 = offset + s * step
        cur = 0
        for (t, ln, m) in events:
            if t <= t0 < t + ln:
                cur = m
                break
        grid.append(cur)
    return grid


def quant_beats(ev, step, steps, offset):
    grid = []
    for s in range(steps):
        t0 = offset + s * step
        cur = 0
        for (t, ln, bt) in ev:
            if t <= t0 < t + ln:
                cur = bt
                break
        grid.append(cur)
    return grid


# ---------------------------------------------------------------- 歌曲

GROUND_LAYOUT = [
    # 原版段落表（MusicHeaderData「ground level music layout」）前两轮 + 第四段一组；
    # 完整 33 段超出 64 Pattern 预算，取舍见 README 实现说明
    "LeadIn", "P1", "P1", "P2A", "P2B", "P2A", "P2C",
    "P2A", "P2B", "P2A", "P2C", "P3A", "P3B", "P3A", "LeadIn",
    "P4A", "P4B", "P4A", "P4C", "LeadIn",
]
SEC_DATA = {
    "LeadIn": "GroundMLdInData", "P1": "GroundM_P1Data", "P2A": "GroundM_P2AData",
    "P2B": "GroundM_P2BData", "P2C": "GroundM_P2CData", "P3A": "GroundM_P3AData",
    "P3B": "GroundM_P3BData", "P4A": "GroundM_P4AData", "P4B": "GroundM_P4BData",
    "P4C": "GroundM_P4CData",
}
SEC_HDR = {
    "LeadIn": "GroundLevelLeadInHdr", "P1": "GroundLevelPart1Hdr",
    "P2A": "GroundLevelPart2AHdr", "P2B": "GroundLevelPart2BHdr",
    "P2C": "GroundLevelPart2CHdr", "P3A": "GroundLevelPart3AHdr",
    "P3B": "GroundLevelPart3BHdr", "P4A": "GroundLevelPart4AHdr",
    "P4B": "GroundLevelPart4BHdr", "P4C": "GroundLevelPart4CHdr",
}
# 其他曲目：名 → (数据区间, 头, 块时长, 循环?)
SIMPLE = [
    ("under", ("UndergroundMusData", "WaterMusData"), "UndergroundMusHdr", 96, True),
    ("castle", ("CastleMusData", "GameOverMusData"), "CastleMusHdr", 160, True),
    ("star", ("Star_CloudMData", "GroundM_P1Data"), "Star_CloudHdr", 64, True),
    ("warn", ("TimeRunOutMusData", "WinLevelMusData"), "TimeRunningOutHdr", 128, False),
    ("die", ("DeathMusData", "CastleMusData"), "DeathMusHdr", 96, False),
    ("win", ("WinLevelMusData", "UndergroundMusData"), "EndOfLevelMusHdr", 96, False),
    ("rescue", ("EndOfCastleMusData", "VictoryMusData"), "WinCastleMusHdr", 128, False),
    ("over", ("GameOverMusData", "TimeRunOutMusData"), "GameOverMusHdr", 96, False),
]
# SFX 槽位：游戏即时音效 0-14（死亡/告警/过关号角改由音乐 Pattern 播放），
# 音乐 15-127：主旋律 15-44 / 和声 45-85 / 贝斯 86-120 / 鼓 121-127
MELO_BASE, HARM_BASE, BASS_BASE, DRUM_BASE = 15, 45, 83, 114
CAPS = {"mel": (MELO_BASE, 30), "harm": (HARM_BASE, 38),
        "bass": (BASS_BASE, 31), "drum": (DRUM_BASE, 11)}

# 地上各段切块方案：(块时长, 步长)。LeadIn 用 3 帧精确步长；P1 单块 32 步×9 帧
# （段内时值恰为 9 的倍数）；其余 144 帧段单块 24 步×6 帧
GROUND_CHUNKS = {"LeadIn": [(96, 3), (48, 3)], "P1": [(288, 9)]}
GROUND_DEFAULT = [(144, 6)]
# 预算取舍（README 实现说明同步）：时间告急省三角贝斯、死亡省方波1持续音、
# 过关号角省三角贝斯；地下曲方波1与方波2为同度齐奏，只保留方波2一条
SIMPLE_DROP = {"warn": "bass", "die": "mel", "win": "bass"}
UNDER_MEL_FROM_HARM = True


def decode_section(data, base, hdr4, t_end):
    len_ofs, tri_ofs, sq1_ofs, noise_ofs = hdr4
    o = base
    return {
        "mel": walk_sq1(data, o + sq1_ofs, len_ofs, t_end),
        "harm": walk_sq2(data, o, len_ofs, t_end),
        "bass": walk_sq2(data, o + tri_ofs, len_ofs, t_end, tri=True),
        "drum": (walk_noise(data, o + noise_ofs, len_ofs, o + noise_ofs, t_end)
                 if noise_ofs is not None else []),
    }


def build():
    labels, order = load_asm()
    hdrs = parse_headers()

    # 地上各段：字节流连续，段内偏移为绝对偏移
    ground = region(labels, order, "GroundM_P1Data", "CastleMusData")
    pos, base_of, start = 0, {}, None
    for lb in order:
        if lb == "GroundM_P1Data":
            start = pos
        if lb == "CastleMusData":
            break
        if start is not None:
            base_of[lb] = pos - start
        pos += len(labels[lb])
    secs = {}
    for key, lb in SEC_DATA.items():
        h = hdrs[SEC_HDR[key]]
        t_end = total_time(walk_sq2(ground, base_of[lb], h[0], 1 << 30))
        secs[key] = decode_section(ground, base_of[lb], h, t_end)

    songs = {}
    for name, (a, b), hl, cl, loop in SIMPLE:
        d = region(labels, order, a, b)
        h = hdrs[hl]
        t_end = total_time(walk_sq2(d, 0, h[0], 1 << 30))
        songs[name] = (cl, loop, decode_section(d, 0, h, t_end))

    # ---- 组装 SFX / Pattern ----
    emit = []          # (sid, content, kind, speed)
    sfx_idx = {"mel": {}, "harm": {}, "bass": {}, "drum": {}}

    def sfx_id(kind, content, speed):
        key = (tuple(content), speed)
        idx = sfx_idx[kind]
        if key in idx:
            return idx[key]
        b0, cap = CAPS[kind]
        used = sum(1 for (s, c, k, sp) in emit if k == kind)
        assert used < cap, "SFX 槽位超预算：%s" % kind
        sid = b0 + used
        emit.append((sid, list(content), kind, speed))
        idx[key] = sid
        return sid

    pats = []

    def emit_chunk(voices, chunks_plan, drop=(), base_off=0):
        """按切块方案铺一个声部组；返回最后一个块的 [mel,harm,bass,drum] id。"""
        ids = [0, 0, 0, 0]
        off = base_off
        for (clen, step) in chunks_plan:
            n = min(32, math.ceil(clen / step))
            kinds = (("mel", quant), ("harm", quant), ("bass", quant),
                     ("drum", quant_beats))
            for ki, (kind, fn) in enumerate(kinds):
                if kind in drop or not voices[kind]:
                    continue
                data = fn(voices[kind], step, n, off)
                if not any(data):
                    continue
                ids[ki] = sfx_id(kind, data, step)
            off += clen
        return ids

    # 地上：段落链（BEGIN/END 循环）
    n_ground = len(GROUND_LAYOUT)
    for i, key in enumerate(GROUND_LAYOUT):
        sec = secs[key]
        plan = GROUND_CHUNKS.get(key, GROUND_DEFAULT)
        ids = emit_chunk(sec, plan)
        flags = (1 if i == 0 else 0) | (2 if i == n_ground - 1 else 0)
        pats.append((key, ids, flags))
    # 其余曲目：Pattern 基址按地上段之后顺序分配（多块曲目占连续编号）
    pbase = len(GROUND_LAYOUT)  # 地上 0-19，其余曲目紧随其后顺序分配
    bases = {}
    for name, _, _, _, _ in SIMPLE:
        cl, loop, voices = songs[name]
        step = cl // 32
        nchunks = max(1, math.ceil(sec_t(voices) / cl))
        bases[name] = (pbase, nchunks)
        pbase += nchunks
    for name, (_, _, _, _, _) in zip([s0[0] for s0 in SIMPLE], SIMPLE):
        cl, loop, voices = songs[name]
        pbase0, nchunks = bases[name]
        drop = (SIMPLE_DROP.get(name),)
        if name == "under" and UNDER_MEL_FROM_HARM:
            voices = dict(voices, mel=[])  # 方波1与方波2同度齐奏，只留方波2
        step = cl // 32
        for ci in range(nchunks):
            ids = emit_chunk(voices, [(cl, step)], drop, base_off=ci * cl)
            flags = (1 if ci == 0 else 0) | ((2 if loop else 4) if ci == nchunks - 1 else 0)
            pats.append((name + ("" if nchunks == 1 else "#%d" % ci), ids, flags))
    return secs, songs, emit, pats, bases


def sec_t(voices):
    """曲段实际时长 = 各声部最后一个事件结束点的最大值（去掉曲尾静音）。"""
    def last_end(ev):
        return ev[-1][0] + ev[-1][1] if ev else 0
    return max(last_end(voices[k]) for k in ("mel", "harm", "bass", "drum"))


WAVE = {"mel": 3, "harm": 4, "bass": 0}
VOL = {"mel": 11, "harm": 7, "bass": 14}


def emit_lua(emit, pats, bases):
    layout = ", ".join("%s=%d" % (k, v[0]) for k, v in
                       sorted(bases.items(), key=lambda kv: kv[1][0]))
    L = [
        BEGIN_MARK,
        "-- 原曲音符表转写（SuperMarioBros-C 反汇编 docs/smbdis.asm；由 convert_music.py 生成）",
        "-- 通道：ch4 主旋律 SQUARE / ch5 和声 PULSE25 / ch6 贝斯 TRIANGLE / ch7 鼓 NOISE",
        "-- Pattern：0-19 地上(BEGIN/END 循环)；其余曲目（循环曲 BEGIN+END，一次性曲 STOP）：",
        "--          " + layout,
        "local function drum_sfx(id, steps, speed)",
        "  local base = 0x060000 + id * 112",
        "  u8(base, speed) u8(base + 1, #steps)",
        "  for s = 0, 31 do",
        "    local a = base + 16 + s * 3",
        "    local st = steps[s + 1]",
        "    if st then u8(a, st[1]) u8(a + 1, st[2] * 16 + st[3]) u8(a + 2, 0) else u8(a, 0) u8(a + 1, 0) end",
        "  end",
        "end",
        "local function music_gen()",
    ]
    for (sid, content, kind, speed) in sorted(emit):
        sp = max(1, int(round(speed)))
        if kind == "drum":
            parts = []
            for m in content:
                if m == 1:
                    parts.append("{36,13,3}")     # 短军鼓
                elif m == 2:
                    parts.append("{24,15,12}")    # 强拍=底鼓
                elif m == 3:
                    parts.append("{48,12,2}")     # 长镲
                else:
                    parts.append("nil")
            L.append("  drum_sfx(%d, {%s}, %d)" % (sid, ", ".join(parts), sp))
        else:
            L.append("  init_sfx(%d, {%s}, %d, %d, %d)"
                     % (sid, ",".join(str(m) for m in content), WAVE[kind], VOL[kind], sp))
    L.append("  -- Pattern 表（0x063800 起，每段 16B；ch4-7 = 音乐通道）")
    L.append("  local function pat(n, m, h, b, d, f)")
    L.append("    local a = 0x063800 + n * 16")
    L.append("    u8(a + 4, m) u8(a + 5, h) u8(a + 6, b) u8(a + 7, d) u8(a + 8, f)")
    L.append("  end")
    for pi, (name, ids, flags) in enumerate(pats):
        L.append("  pat(%d, %d, %d, %d, %d, %d) -- %s"
                 % (pi, ids[0], ids[1], ids[2], ids[3], flags, name))
    L.append("end")
    return "\n".join(L) + "\n"


def main():
    report_only = "--report" in sys.argv
    check_only = "--check" in sys.argv
    secs, songs, emit, pats, bases = build()

    print("== 音乐预算 ==")
    for key, sec in secs.items():
        print("  地上段 %-6s %5d 帧 (%4.1fs)" % (key, sec_t(sec), sec_t(sec) / 60))
    for name in ("under", "castle", "star", "warn", "die", "win", "rescue", "over"):
        cl, loop, voices = songs[name]
        print("  %-7s %5d 帧 (%4.1fs)  块长 %d" % (name, sec_t(voices), sec_t(voices) / 60, cl))
    n_mel = sum(1 for e in emit if e[2] == "mel")
    n_harm = sum(1 for e in emit if e[2] == "harm")
    n_bass = sum(1 for e in emit if e[2] == "bass")
    n_drum = sum(1 for e in emit if e[2] == "drum")
    total_sfx = len(emit)
    print("  Pattern %d/64；音乐 SFX %d/110（旋律 %d 和声 %d 贝斯 %d 鼓 %d）"
          % (len(pats), total_sfx, n_mel, n_harm, n_bass, n_drum))
    print("  Pattern 基址：", {k: v[0] for k, v in sorted(bases.items(), key=lambda kv: kv[1][0])})
    if len(pats) > 64 or total_sfx > 110:
        print("!! 超出预算", file=sys.stderr)
        sys.exit(1)
    if report_only:
        return

    gen = emit_lua(emit, pats, bases) + END_MARK + "\n"
    src = LUA.read_text(encoding="utf-8")
    b = src.find(BEGIN_MARK)
    e = src.find(END_MARK)
    if b >= 0 and e >= 0:
        if check_only:
            same = src[b:e + len(END_MARK)] == gen[:-len("\n")] or \
                src[b:e + len(END_MARK)] == gen.rstrip("\n")
            print("生成段一致" if same else "生成段过期（请运行 convert_music.py）")
            sys.exit(0 if same else 1)
        new = src[:b] + gen + src[e + len(END_MARK):]
        LUA.write_text(new, encoding="utf-8")
    else:
        anchor = "local function init_all_audio()"
        i = src.index(anchor)
        LUA.write_text(src[:i] + gen + "\n" + src[i:], encoding="utf-8")
        if check_only:
            print("缺少生成段标记")
            sys.exit(1)
    print("已写回 %s（%d 个 Pattern，%d 条音乐 SFX）" % (LUA, len(pats), len(emit)))


if __name__ == "__main__":
    main()
