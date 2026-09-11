# -*- coding: utf-8 -*-
"""魔塔 BGM/SFX 写谱器（demo/magetower/compose_music.py）

FC-16 是 8 通道芯片合成器（SPEC §5，无采样回放），原版 SWF 里的流媒体
MP3 无法直接播放——卡带音乐由 transcribe_music.py 从原曲音频自动转录，
本文件只负责把"曲目 → SFX/Pattern"按 SPEC §5.2 布局写回目标卡带
.lua 的标记区间（默认 demo/mota24/mota24.lua，可由调用方传入路径）：

  -- BEGIN GENERATED MUSIC (compose_music.py) / -- END GENERATED MUSIC

声道编排（music mask 0x3F，ch6-7 留给即时音效）：
  ch0 主音（控制声部）  ch1 和弦垫  ch2 贝斯  ch4 打击乐（噪声鼓）

用法：python transcribe_music.py mota24|mota50  # 转录 + 写回（本文件为库）
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LUA = os.path.join(HERE, "magetower.lua")
BEGIN = "-- BEGIN GENERATED MUSIC (compose_music.py)"
END = "-- END GENERATED MUSIC"

# ---- 基础 ----
# 波形：0三角 1斜锯 2锯齿 3方波 4脉冲25 5脉冲12 6管风琴 7簧片 8圆润
#       9双锯 10铃 11贝斯 12空洞 13数字 14长噪声 15短噪声
W = {"tri": 0, "saw": 2, "sq": 3, "pulse": 4, "pulse12": 5, "organ": 6,
     "reed": 7, "round": 8, "bell": 10, "bass": 11, "hollow": 12, "bit": 13,
     "nlong": 14, "nshort": 15}
# 效果：0 无 1 滑音 2 颤音 3 降音 4 淡入 5 淡出 6 快琶音 7 慢琶音
FX_VIB, FX_SLIDE, FX_FALL = 2, 1, 3

NOTE_BASE = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4,
             "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9,
             "A#": 10, "Bb": 10, "B": 11}

# 声部通道（mask 0x3F：ch0-5 交给音乐，ch6-7 留给即时音效）
MELO_CH, HARM_CH, BASS_CH, DRUM_CH = 0, 1, 2, 4


def pitch(name):
    """"E5" → SPEC 音高（MIDI-11）；"-" = 休止。"""
    if name in ("-", "", None):
        return 0
    octv = int(name[-1])
    key = name[:-1]
    midi = 12 + (octv + 1) * 12 + NOTE_BASE[key]
    return midi - 11


def steps32(events):
    """[(步, 音名, 长, 波形, 音量, 效果?)] → 32 步数组（后写覆盖先写）。"""
    out = [None] * 32
    for st, name, dur, wav, vol, *fx in events:
        for i in range(dur):
            if 0 <= st + i < 32:
                out[st + i] = (pitch(name), W[wav], vol, fx[0] if fx and i == 0 else 0)
    return out


class Song:
    """一首曲子：按 (pattern, 通道) 组织的音序事件，自动分配 SFX id。"""

    def __init__(self, speed):
        self.speed = speed
        self.tracks = {}  # (pattern_idx, ch) -> [ (步,音名,长,波形,音量,效果) ]

    def put(self, pat, ch, events):
        self.tracks.setdefault((pat, ch), []).extend(events)


def assemble(song, alloc, pool):
    """Song → (SFX 定义列表, pattern 表)。

    alloc() 产生下一个 SFX id；pool 为跨曲共享的
    {(speed, steps 元组) → id} 去重池：鼓组/贝斯等逐 Pattern 重复的
    内容只占一条 SFX 预算。同一声部（pattern 内同一通道）的
    一个 32 步数组 = 一条 SFX。
    """
    by_key = {}
    for (pat, ch), ev in song.tracks.items():
        by_key[(pat, ch)] = steps32(ev)
    pats = max(k[0] for k in by_key) + 1
    defs, table = [], [[0] * 8 for _ in range(pats)]
    for pat in range(pats):
        for ch in range(5):
            st = by_key.get((pat, ch))
            if not st or all(s is None for s in st):
                continue
            rows = []
            for s in st:
                if s is None:
                    rows.append((0, 0, 0, 0))
                else:
                    rows.append(s)
            key = (song.speed, tuple(rows))
            if key in pool:
                table[pat][ch] = pool[key]
                continue
            sid = alloc()
            defs.append({"id": sid, "speed": song.speed, "steps": rows})
            pool[key] = sid
            table[pat][ch] = sid
    return defs, table


def lua_rows(rows):
    out = []
    for row in rows:
        p, w, v = row[0], row[1], row[2]
        f = row[3] if len(row) > 3 else 0
        if p == 0 and v == 0:
            out.append("{0}")
        else:
            out.append("{%d, %d, %d, %d}" % (p, w, v, f))
    return "{" + ", ".join(out) + "}"


# ---------------------------------------------------------------- 写回 Lua

def write_all(parts, lua_path=None):
    """parts = [(Pattern 全局名, Song, pattern 数)] → 写回目标 .lua。"""
    lua_path = lua_path or LUA
    pool, tables = {}, []
    counter = [14]                      # 0-13 为游戏即时音效

    def alloc():
        sid = counter[0]
        counter[0] += 1
        return sid

    for _gname, song, _npats in parts:
        defs, table = assemble(song, alloc, pool)
        tables.append((defs, table))
    # 各曲 Pattern 起始号（顺序累计）
    bases, pat_base = {}, 0
    for (gname, _, _npats), (_defs, table) in zip(parts, tables):
        bases[gname] = pat_base
        pat_base += len(table)
    all_sfx = [(d["id"], d["speed"], d["steps"])
               for defs, _ in tables for d in defs]
    print("SFX 总数 %d / 128，Pattern 总数 %d / 64" % (counter[0], pat_base))
    assert counter[0] <= 128, "SFX 超预算"
    assert pat_base <= 64, "Pattern 超预算"

    game_sfx = [
        # (id, speed, [(音高, 波形, 音量, 效果?)])
        (0, 1, [(pitch("C3"), W["nlong"], 4), (pitch("G2"), W["nlong"], 3)]),  # 脚步
        (1, 1, [(pitch("E4"), W["sq"], 8), (pitch("A4"), W["sq"], 7, FX_SLIDE),
                (pitch("C5"), W["sq"], 5, FX_FALL)]),                          # 开门
        (2, 1, [(pitch("C6"), W["bell"], 8), (pitch("G6"), W["bell"], 8)]),    # 拾取
        (3, 1, [(pitch("E6"), W["bell"], 7), (pitch("B6"), W["bell"], 8),
                (pitch("E7"), W["bell"], 7)]),                                 # 宝石
        (4, 1, [(pitch("E2"), W["nlong"], 11), (pitch("C2"), W["nlong"], 9, FX_FALL)]),  # 战斗
        (5, 2, [(pitch("G5"), W["sq"], 9), (pitch("E5"), W["sq"], 7),
                (pitch("C5"), W["sq"], 6)]),                                   # 战胜
        (6, 1, [(pitch("E3"), W["sq"], 7), (pitch("C3"), W["sq"], 6)]),        # 拒绝
        (7, 3, [(pitch("E3"), W["nlong"], 12), (pitch("E3"), W["nlong"], 12),
                (pitch("D3"), W["nlong"], 12, FX_FALL),
                (pitch("C3"), W["bass"], 11, FX_FALL)]),                       # Boss 警报
        (8, 4, [(pitch("C5"), W["sq"], 9), (pitch("E5"), W["sq"], 9),
                (pitch("G5"), W["sq"], 10), (pitch("C6"), W["sq"], 11),
                (pitch("G5"), W["sq"], 10), (pitch("C6"), W["sq"], 12)]),      # 胜利
        (9, 6, [(pitch("A4"), W["sq"], 8), (pitch("F4"), W["sq"], 7),
                (pitch("D4"), W["sq"], 6), (pitch("B3"), W["sq"], 5),
                (pitch("G3"), W["sq"], 4), (pitch("E3"), W["sq"], 4)]),        # 败北
        (10, 2, [(pitch("G5"), W["bell"], 8), (pitch("C6"), W["bell"], 9)]),   # 存档
        (11, 1, [(pitch("E5"), W["sq"], 5)]),                                  # 菜单
        (12, 1, [(pitch("B5"), W["bell"], 9), (pitch("E6"), W["bell"], 9)]),   # 购买
        (13, 2, [(pitch("A4"), W["sq"], 7), (pitch("C5"), W["sq"], 8),
                 (pitch("E5"), W["sq"], 9)]),                                  # 上下楼
    ]
    all_music = [(i, sp, st) for i, sp, st in all_sfx]
    everything = [(i, sp, st) for (i, sp, st) in game_sfx] + all_music

    def flags(pats):
        return ["3" if i == len(pats) - 1 else ("1" if i == 0 else "0")
                for i in range(len(pats))]

    lines = [
        BEGIN,
        "-- 由 transcribe_music.py 从原曲音频转录生成（_source/audio/ 留档），勿手改。",
        "-- 声部布局：ch0 主音 ch1 和弦垫 ch2 贝斯 ch4 鼓；mask 0x3F。",
        "-- 各曲速度/小节数见 transcribe_music.py 的 TRACKS 与运行输出。",
        "local function u8(a, v) poke(a, v % 256) end",
        "",
        "-- steps: {{音高, 波形, 音量, 效果?}, ...}；音高 0 = 休止；1-96 = C0-B7",
        "local function sfx_steps(id, speed, steps)",
        "  local base = 0x060000 + id * 112",
        "  u8(base, speed)",
        "  u8(base + 1, #steps)",
        "  for i = 0, 31 do",
        "    local a = base + 16 + i * 3",
        "    local st = steps[i + 1]",
        "    if st then",
        "      u8(a, st[1] or 0)",
        "      u8(a + 1, (st[2] or 0) * 16 + (st[3] or 0))",
        "      u8(a + 2, st[4] or 0)",
        "    else",
        "      u8(a, 0)",
        "      u8(a + 1, 0)",
        "    end",
        "  end",
        "end",
        "",
        "local S_STEP, S_DOOR, S_PICK, S_GEM, S_FIGHT, S_KILL, S_DENY = 0, 1, 2, 3, 4, 5, 6",
        "local S_BOSS, S_WIN, S_LOSE, S_SAVE, S_MENU, S_BUY, S_STAIR = 7, 8, 9, 10, 11, 12, 13",
        "",
        "-- BGM 曲目表（Pattern 起始号，全局）",
        "%s = %s" % (", ".join(g for g, _, _ in parts),
                     ", ".join(str(bases[g]) for g, _, _ in parts)),
        "-- 机器可读曲目表（verify_music.py 用）：名=起始:段数:speed",
        "-- TRACKS: " + ", ".join(
            "%s=%d:%d:%d" % (g, bases[g], len(table), song.speed)
            for (g, song, _n), (_d, table) in zip(parts, tables)),
        "",
        "local function init_audio()",
    ]
    for i, sp, st in everything:
        lines.append("  sfx_steps(%d, %d, %s)" % (i, sp, lua_rows(st)))
    pat_lines = ["  local mb = 0x063800\n"]

    def emit(table, base_pat):
        fl = flags(table)
        for i, row in enumerate(table):
            for ch in range(8):
                if row[ch]:
                    pat_lines.append("  u8(mb + %d * 16 + %d, %d)  -- ch%d ← SFX %d"
                                     % (base_pat + i, ch, row[ch] + 1, ch, row[ch]))
            pat_lines.append("  u8(mb + %d * 16 + 8, %s)  -- %s"
                             % (base_pat + i, fl[i],
                                "BEGIN|END 回环" if fl[i] == "3" else
                                ("BEGIN" if fl[i] == "1" else
                                 "END" if fl[i] == "2" else "")))

    for (gname, _, _npats), (_defs, table) in zip(parts, tables):
        emit(table, bases[gname])
    lines += pat_lines
    lines += [
        "end",
        END,
    ]
    block = "\n".join(lines) + "\n"

    src = open(lua_path, encoding="utf-8").read()
    b = src.find(BEGIN)
    if b >= 0:
        e = src.find(END, b)
        src = src[:b] + block + src[e + len(END) + 1:]
    else:
        marker = "-- ================================================================ 音频（SPEC §5.2）"
        b = src.find(marker)
        assert b >= 0
        src = src[:b] + block + src[b + len(marker) + 1:]
    open(lua_path, "w", encoding="utf-8").write(src)
    print("音乐块 %d KB 已写回 %s" % (len(block) // 1024, lua_path))


if __name__ == "__main__":
    print("本文件是写谱库；入口是 transcribe_music.py")
