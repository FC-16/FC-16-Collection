# -*- coding: utf-8 -*-
"""MIDI → FC-16 芯片编曲（demo/magetower/midi_arrange.py）

50 层魔塔的 BGM 有原版 MIDI 源文件（Tower of the Sorcerer 1.2r1 自带
`_source/BGM/Midi/*.MID`，floor→曲目映射由 TSW.exe 反汇编确认），直接读出
音符做**精确转录**，不走音频识别：

  解析（fmt 0/1、running status、note-on/off 就地配对，多 tempo 取首值）
  → 声部分类（主音 = 覆盖率高且音区最高的单音声部；贝斯 = 音区最低；
     副旋律 = 音区次高且与主音错开；ch9 = 鼓）
  → 16 分网格量化（ppq=480，1 step = 120 tick）
  → 四芯片声道：ch0 主音 ch1 副旋律/和弦垫 ch2 贝斯 ch4 鼓
  → compose_music.Song（内容寻址去重由写谱器完成）

被 transcribe_music.py 调用；无独立入口。
"""
import struct

import compose_music as cm

NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
STEP_TICKS = 120          # ppq 480 的 16 分音符
BAR_TICKS = 1920          # 4/4 一小节
MIDI_LO, MIDI_HI = 13, 106   # SPEC §5.2 音高 1-96（存 MIDI 12-107，留 1 位余量）
PERC_PATCHES = {115, 116, 117, 118, 119}   # 木鱼/太鼓/定音鼓线条/合成鼓/反镲


def note_name(midi):
    return "%s%d" % (NAMES[midi % 12], midi // 12 - 1)


# ---------------------------------------------------------------- SMF 解析

def _vlq(data, pos):
    v = 0
    for _ in range(4):
        b = data[pos]
        pos += 1
        v = (v << 7) | (b & 0x7F)
        if not b & 0x80:
            break
    return v, pos


def parse_midi(path):
    """→ {ppq, bpm, chans:{ch:{patch, notes:[(tick,dur,midi,vel)]}}, drums, end}。"""
    data = open(path, "rb").read()
    if data[:4] != b"MThd":
        raise ValueError("非 MIDI 文件：%s" % path)
    _fmt, _ntrk, ppq = struct.unpack(">HHH", data[8:14])
    pos, tempo, end = 14, None, 0
    chans = {}                      # ch -> {"patch":p, "on":{(key):tick}, "notes":[]}
    drums = []                      # [(tick, midi)]
    while pos < len(data) and data[pos:pos + 4] == b"MTrk":
        ln = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        trk = data[pos + 8:pos + 8 + ln]
        pos += 8 + ln
        tp, tick, run = 0, 0, None
        while tp < len(trk):
            d, tp = _vlq(trk, tp)
            tick += d
            if trk[tp] < 0x80:
                st = run
            else:
                st = trk[tp]
                tp += 1
                if st < 0xF0:
                    run = st
            if st is None:
                continue
            if st == 0xFF:
                mt = trk[tp]
                tp += 1
                mln, tp = _vlq(trk, tp)
                meta = trk[tp:tp + mln]
                tp += mln
                if mt == 0x51 and tempo is None:
                    tempo = int.from_bytes(meta, "big")
                elif mt == 0x2F and tick > end:
                    end = tick
            elif st in (0xF0, 0xF7):
                sln, tp = _vlq(trk, tp)
                tp += sln
            else:
                hi, ch = st & 0xF0, st & 0xF
                n = 1 if hi in (0xC0, 0xD0) else 2
                args = trk[tp:tp + n]
                tp += n
                if ch == 9:
                    if hi == 0x90 and args[1] > 0:
                        drums.append((tick, args[0]))
                    continue
                c = chans.setdefault(ch, {"patch": 0, "on": {}, "notes": []})
                key = args[0]
                if hi == 0x90 and args[1] > 0:
                    c["on"].setdefault(key, []).append((tick, args[1]))
                elif hi in (0x80, 0x90):        # note-off / vel 0
                    q = c["on"].get(key)
                    if q:
                        t0, vel = q.pop(0)
                        c["notes"].append((t0, tick - t0, key, vel))
                elif hi == 0xC0:
                    c["patch"] = args[0]
    out = {}
    for ch, c in chans.items():
        if c["notes"]:
            c["notes"].sort()
            out[ch] = {"patch": c["patch"], "notes": c["notes"]}
    return {"ppq": ppq, "tempo": tempo or 500000, "chans": out,
            "drums": sorted(drums), "end": end}


# ---------------------------------------------------------------- 声部分类

def _coverage(notes, span_ticks):
    """有音符的小节占比（按窗口长度）。"""
    bars = max(1, round(span_ticks / BAR_TICKS))
    hit = {t // BAR_TICKS for t, _d, _m, _v in notes}
    return min(1.0, len(hit) / bars)


def _line_sig(notes):
    """量化后的 (步 → 音高) 概略签名，用于识别 echo 双层同谱通道。"""
    sig = {}
    for t, _d, m, _v in notes:
        sig.setdefault(int(round(t / STEP_TICKS)), set()).add(m)
    return sig


def _dedup_echo(win_chans):
    """丢弃与其他通道 ≥85% 同谱（允许 ±8 步延迟）的 echo 重复层。

    同谱的普通音色与打击音色（p115-119）并存时保留普通音色——
    贝斯/旋律常被太鼓等打击层同谱加倍（如 B_058 的 ch1/ch2）。
    """
    sigs = {ch: {s: next(iter(ms)) for s, ms in _line_sig(c["notes"]).items()}
            for ch, c in win_chans.items()}
    drop = set()
    for a in sigs:
        if a in drop:
            continue
        for b in sigs:
            if a == b or b in drop:
                continue
            best = 0
            for shift in range(-8, 9):
                common = sum(1 for s, p in sigs[a].items()
                             if sigs[b].get(s + shift) == p)
                best = max(best, common)
            if best < 0.85 * min(len(sigs[a]), len(sigs[b])) or \
                    not (sigs[a] and sigs[b]):
                continue
            pa, pb = win_chans[a]["patch"], win_chans[b]["patch"]
            if pa in PERC_PATCHES and pb not in PERC_PATCHES:
                drop.add(a)
            else:
                drop.add(b)            # 默认保留 a，丢 b
    return {ch: c for ch, c in win_chans.items() if ch not in drop}


def classify(song, chans=None, span=None):
    """在给定声部集合（默认全曲）里选 (主音, 副旋律, 贝斯) 通道。

    打分基于实际参与编曲的窗口内容：
    音区 × 覆盖 × 单音性 × 音符密度。
    """
    cand = []
    for ch, c in (chans if chans is not None else song["chans"]).items():
        notes = c["notes"]
        if len(notes) < 2:
            continue
        sp = span or (notes[-1][0] + 1)
        bars = max(1, sp / BAR_TICKS)
        mean = sum(m for _t, _d, m, _v in notes) / len(notes)
        npb = len(notes) / bars
        cand.append({
            "ch": ch, "n": len(notes), "mean": mean, "npb": npb,
            "cov": _coverage(notes, sp),
            "perc": c["patch"] in PERC_PATCHES,
        })
    if not cand:
        return None, None, None
    for x in cand:
        x["m_score"] = x["mean"] * (0.4 + x["cov"]) \
            * min(1.6, 0.6 + x["npb"] / 6)
    # 主音：打击音色（tom/taiko 等）不进候选
    mel_cand = [x for x in cand if not x["perc"]] or cand
    mel_cand.sort(key=lambda x: -x["m_score"])
    mel = mel_cand[0]
    # 贝斯：平均音高最低且低于主音 4 个半音；近音高时取更活跃的声部
    bass = None
    by_mean = sorted(cand, key=lambda x: x["mean"])
    for x in by_mean:
        if x["ch"] != mel["ch"] and x["mean"] < mel["mean"] - 4:
            bass = x
            break
    if bass is not None:
        for x in by_mean:
            if x["ch"] in (mel["ch"], bass["ch"]) or \
                    not (bass["mean"] <= x["mean"] <= bass["mean"] + 8):
                continue
            if x["npb"] >= 3 * max(0.2, bass["npb"]):
                bass = x
                break
    # 副旋律：非主非贝中音区最高、足够活跃者
    counter = None
    for x in sorted(cand, key=lambda x: -x["mean"]):
        if x["ch"] in (mel["ch"], bass and bass["ch"]):
            continue
        if x["n"] >= 8 and x["npb"] >= 1.2:
            counter = x
            break
    return mel["ch"], (counter and counter["ch"]), (bass and bass["ch"])


# ---------------------------------------------------------------- 量化和写谱

def _quantize(notes, top=True):
    """[(tick,dur,midi,vel)] → [(step,len,midi,vel)]；同刻多音保最高/最低，
    同刻同音（echo 分层）只留一条。"""
    active = {}
    for t, d, m, v in notes:
        s = int(round(t / STEP_TICKS))
        ln = max(1, int(round(d / STEP_TICKS)))
        active.setdefault(s, set()).add((m, ln, v))
    grid = {}
    for s, lst in active.items():
        uniq = {}
        for m, ln, v in lst:
            if m not in uniq or ln > uniq[m][0]:
                uniq[m] = (ln, v)
        pairs = sorted(uniq.items(), key=lambda x: -x[0])
        m, (ln, v) = pairs[0] if top else pairs[-1]
        grid[s] = (ln, m, v)
    return sorted((s, ln, m, v) for s, (ln, m, v) in grid.items())


def _put_line(song, ch, qnotes, wave, vol, oct_shift=0):
    """量化音符流 → Song 声部；跨 pattern 自动接续。"""
    for st, ln, m, v in qnotes:
        m = m + oct_shift
        m = max(MIDI_LO, min(MIDI_HI, m))
        vol_q = max(1, min(15, round(v / 127 * vol)))
        st, ln = int(st) % 4096, min(int(ln), 32)
        while ln > 0 and st < 4096:
            pat, pos = st // 32, st % 32
            seg = min(ln, 32 - pos)
            song.put(pat, ch, [(pos, note_name(m), seg, wave, vol_q)])
            st += seg
            ln -= seg


def _put_drums(song, hits, bars):
    """打击 → ch4：最低音簇 kick、最高音簇 snare，按 16 分格折叠。"""
    if not hits:
        return
    pit = sorted({m for _t, m in hits})
    kick_p = pit[: max(1, len(pit) // 3)]
    snare_p = pit[-max(1, len(pit) // 3):] if len(pit) >= 2 else []
    for t, m in hits:
        st = int(round(t / STEP_TICKS))
        if st >= bars * 16:
            continue
        if m in kick_p:
            song.put(st // 32, cm.DRUM_CH, [(st % 32, "C2", 1, "nlong", 10)])
        elif m in snare_p:
            song.put(st // 32, cm.DRUM_CH, [(st % 32, "D3", 1, "nshort", 7)])


def _chords_from_line(mel, bars):
    """独奏曲（如 A_085 音乐盒）没有伴奏声部：从旋律线推每 2 小节三和弦。"""
    out = []
    for pair in range(0, bars, 2):
        pcs = {}
        for st, _ln, m, _v in mel:
            if pair * 32 <= st < (pair + 2) * 32:
                pcs[m % 12] = pcs.get(m % 12, 0) + 1
        best, score = None, -1e9
        for root in range(12):
            for iv in ((0, 4, 7), (0, 3, 7)):
                s = sum(pcs.get((root + i) % 12, 0) for i in iv) \
                    - 0.6 * sum(v for k, v in pcs.items()
                                if k not in {(root + i) % 12 for i in iv})
                if s > score:
                    best, score = (root, iv), s
        root, iv = best
        triad = [48 + (root + i) % 12 for i in iv]
        out.append((pair, triad))
    return out


def arrange(path, bars=4, bar_offset=1, lead_wave="pulse", mel_ch=None):
    """一首 MIDI → (Song, 描述)。bars 为编码小节数（4/4）。

    mel_ch 可显式指定主音通道（声部分类的手动覆盖）。
    """
    song = parse_midi(path)
    bpm = 60_000_000 / song["tempo"]
    t0 = bar_offset * BAR_TICKS
    t1 = min(song["end"], (bar_offset + bars) * BAR_TICKS)

    def window(ch):
        return [(t - t0, d, m, v) for t, d, m, v in song["chans"][ch]["notes"]
                if t0 <= t < t1]

    win_chans = {}
    for ch, c in song["chans"].items():
        w = [(t, d, m, v) for t, d, m, v in c["notes"] if t0 <= t < t1]
        if w:
            win_chans[ch] = {"patch": c["patch"], "notes": w}
    win_chans = _dedup_echo(win_chans)
    auto_mel, cnt_ch, bass_ch = classify(song, win_chans, (t1 - t0))
    if mel_ch is None:
        mel_ch = auto_mel
    elif mel_ch != auto_mel and cnt_ch == mel_ch:
        cnt_ch = auto_mel            # 覆盖后避免主副同通道
    if mel_ch is None:
        raise ValueError("找不到旋律声部：%s" % path)

    speed = max(1, min(15, round(900 / bpm)))
    out = cm.Song(speed)
    mel = _quantize(window(mel_ch), top=True)
    _put_line(out, cm.MELO_CH, mel, lead_wave, 11)
    if cnt_ch is not None:
        cnt = _quantize(window(cnt_ch), top=False)
        _put_line(out, cm.HARM_CH, cnt, "organ", 6)
    if bass_ch is not None:
        bass = _quantize(window(bass_ch), top=False)
        _put_line(out, cm.BASS_CH, bass, "bass", 9)
    _put_drums(out, [(t - t0, m) for t, m in song["drums"] if t0 <= t < t1],
               bars)
    if cnt_ch is None and bass_ch is None:
        # 独奏曲：旋律线和声垫 + 低八度贝斯（每 2 小节根音持续）
        for pair, triad in _chords_from_line(mel, bars):
            span = min(64, bars * 32 - pair * 32)
            for i in range(0, span, 2):
                nm = note_name(triad[(i // 2) % 3])
                out.put(pair // 2, cm.HARM_CH,
                        [((pair * 32 + i) % 32, nm, 1, "organ", 4)])
            root = note_name(triad[0] - 24)
            out.put(pair // 2, cm.BASS_CH,
                    [((pair * 32) % 32, root, 32, "bass", 7)])
    desc = "%.0f BPM %dbar@%d speed %d 主音ch%d:%d音 副ch%s 贝斯ch%s" % (
        bpm, bars, bar_offset, speed, mel_ch, len(mel),
        cnt_ch if cnt_ch is not None else "-",
        bass_ch if bass_ch is not None else "-")
    return out, desc
