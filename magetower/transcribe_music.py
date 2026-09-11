# -*- coding: utf-8 -*-
"""魔塔 BGM 转录（demo/magetower/transcribe_music.py）

按目标卡带把原曲转录为 FC-16 芯片谱面并写回对应 .lua 的标记区间。

  mota50 ← 原版 MIDI **精确转录**（midi_arrange.py）。音源为 Tower of the
            Sorcerer 1.2r1 自带 MIDI（_source/BGM/Midi/），楼层→曲目映射由
            TSW.exe 反汇编 soundcheck 函数确认：序章 Entry / 1-10F
            B_067 / 11-20F B_058 / 21-30F B_110 / 31-40F A_118 / 41-49F
            A_019 / 50F Finale B_018 / 通关 Credits B_014。
  mota24 ← B 站《24层魔塔BGM，FC音色重制版》（BV14h411F77W）六曲音频转录
            （_source/bili24/）：opening / 1-7F / 8-14F / 15-18F / 19-24F /
            ending。管线：CQT 谐波激活 → 速度网格（通量梳状评分 + 整数 BPM
            对齐）→ 循环中位数折叠 → 主音/副声部/贝斯分区提取 → 打击鼓组。

用法：python transcribe_music.py mota24 | mota50 | mota50-info
依赖：librosa、numpy（mota24 路径）
"""
import os
import sys
import warnings

import numpy as np

warnings.filterwarnings("ignore")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compose_music as cm
import midi_arrange

# ---------------------------------------------------------------- 曲目配置
# (Pattern 全局名, 标签, 参数)；bars = 编码小节数（1 Pattern = 2 小节）
TARGETS = {
    "mota50": {
        "lua": os.path.join(HERE, "..", "mota50", "mota50.lua"),
        "kind": "midi",
        "tracks": [
            ("P_TITLE", "序章/标题 Entry", "A_027XGW", dict(bars=8)),
            ("P_F1_10", "1-10F 血之迷宫", "B_067XGW", dict(bars=8)),
            ("P_F11_20", "11-20F 吸血鬼", "B_058XGW",
             dict(bars=6, bar_offset=11)),      # 主音 bar11 才进
            ("P_F21_30", "21-30F 魔导师", "B_110XGW", dict(bars=8)),
            ("P_F31_40", "31-40F 黄金骑士", "A_118XGW",
             dict(bars=8, bar_offset=5)),       # 内容 bar5 起
            ("P_F41_49", "41-49F 泽诺陷阱", "A_019XGW", dict(bars=8)),
            ("P_F50", "50F 决战 Finale", "B_018XGW", dict(bars=8)),
            ("P_END50", "通关 Credits", "B_014XGW", dict(bars=8)),
        ],
    },
    "mota24": {
        "lua": os.path.join(HERE, "..", "mota24", "mota24.lua"),
        "kind": "audio",
        "tracks": [
            ("P_TITLE", "标题", "_source/bili24/opening.wav", dict(bars=4)),
            ("P_F1_7", "1-7F", "_source/bili24/f1_7.wav", dict(bars=8)),
            ("P_F8_14", "8-14F", "_source/bili24/f8_14.wav", dict(bars=4)),
            ("P_F15_18", "15-18F", "_source/bili24/f15_18.wav", dict(bars=4)),
            ("P_F19_24", "19-24F", "_source/bili24/f19_24.wav", dict(bars=8)),
            ("P_ENDING", "通关", "_source/bili24/ending.wav", dict(bars=4)),
        ],
    },
}


# ================================================================ 音频路径（mota24）

NAMES = midi_arrange.NAMES
BPO = 36                 # CQT 每八度 bin 数
FMIN = 55.0              # A1
N_OCT = 5                # A1..A6
N_BINS = BPO * N_OCT
MIDI_LO, MIDI_HI = 33, 96
SR = 11025
HOP = 128
FPS = SR / float(HOP)


def midi_name(m):
    return "%s%d" % (NAMES[int(m) % 12], int(m) // 12 - 1)


def load(path):
    import librosa
    return librosa.load(path, sr=SR, mono=True)


def salience(y, sr):
    """CQT → 逐音高激活 A(p,t)（基音 + 谐波加权和）。"""
    import librosa
    C = np.abs(librosa.cqt(y=y, sr=sr, fmin=FMIN, n_bins=N_BINS,
                           bins_per_octave=BPO, hop_length=HOP))
    P = MIDI_HI - MIDI_LO + 1
    A = np.zeros((P, C.shape[1]))
    for j, p in enumerate(range(MIDI_LO, MIDI_HI + 1)):
        bp = BPO * np.log2(440.0 * 2.0 ** ((p - 69) / 12.0) / FMIN)
        acc = np.zeros(C.shape[1])
        for h, w in ((1, 1.0), (2, 0.45), (3, 0.25), (4, 0.12)):
            pos = bp + BPO * np.log2(h)
            if pos < N_BINS - 2:
                acc += C[int(round(pos))] * w
        A[j] = acc
    return A


def flux(A):
    return np.maximum(np.diff(A.sum(axis=0), prepend=0), 0)


def find_grid(A, dur):
    """速度 + 相位：通量自相关粗估 → 候选 BPM 集合（整数/倍半频）→
    16 分网格梳状评分选优。返回 (bpm, phase, loop_bars)。"""
    f = flux(A)
    fn = f / (np.linalg.norm(f) + 1e-9)
    ac = np.correlate(fn, fn, mode="full")[len(fn) - 1:]
    lo_i, hi_i = int(60 / 240 * FPS), int(60 / 55 * FPS)
    beat0 = (lo_i + int(np.argmax(ac[lo_i:hi_i]))) / FPS   # 粗拍长
    bpm0 = 60.0 / beat0
    cands = {bpm0}
    for mult in (0.5, 2.0, 1.5, 2 / 3.0):
        v = bpm0 * mult
        for r in (round(v), round(v * 10) / 10):
            if 55 <= r <= 240:
                cands.add(r)
    # 循环周期（自相似）定 loop_bars
    loop_s = _loop_period(A)

    best = (None, None)
    for bpm in sorted(cands):
        sc = _comb_score(f, bpm, dur)
        if best[0] is None or sc > best[0]:
            best = (sc, bpm)
    bpm = best[1]
    step = 60.0 / bpm / 4
    ph = np.arange(16) * step / 16
    idx = np.minimum((ph[None, :] + np.arange(0, dur, step)[:, None])
                     * FPS, len(f) - 1).astype(int)
    best_ph = ph[int(np.argmax(f[idx].mean(axis=0)))]
    return bpm, best_ph, _bars_for(loop_s, bpm)


def _loop_period(A):
    """自相似最强周期（秒）。"""
    An = A / (np.linalg.norm(A, axis=0, keepdims=True) + 1e-9)
    q = max(1, int(round(FPS / 8)))
    B = An[:, ::q].T
    sps = FPS / q
    n = B.shape[0]
    sims = []
    for lag in range(int(1.0 * sps), min(int(40 * sps), n // 2)):
        s = float((B[:n - lag] * B[lag:]).sum(1).mean())
        sims.append((s, lag / sps))
    sims.sort(reverse=True)
    return sims[0][1] if sims else 8.0


def _bars_for(loop_s, bpm):
    cands_bars = []
    for bars in (2, 4, 8, 3, 6, 12, 16, 1):
        beat = loop_s / (bars * 4)
        if 0.28 <= beat <= 0.95:
            cands_bars.append((abs(np.log2(beat / (60.0 / bpm))), bars))
    bars = min(cands_bars)[1] if cands_bars else 4
    return int(np.clip(bars, 1, 16))


def _comb_score(f, bpm, dur):
    """16 分网格梳状评分（相位 16 档取最优均值）。"""
    step = 60.0 / bpm / 4
    ph = np.arange(16) * step / 16
    idx = np.minimum((ph[None, :] + np.arange(0, dur, step)[:, None])
                     * FPS, len(f) - 1).astype(int)
    return float(f[idx].mean())


def fold(A, bpm, phase, loop_bars, dur, how=np.median):
    """激活按循环折叠 → GA[步][pitch]（中位数抗装饰音）。"""
    step = 60.0 / bpm / 4
    L = loop_bars * 16
    total = int((dur - phase) / step)
    reps = max(1, total // L)
    frames = []
    for r in range(reps):
        t0 = phase + r * L * step
        for s in range(L):
            f0 = int(round((t0 + s * step) * FPS))
            f1 = max(f0 + 1, int(round((t0 + (s + 1) * step) * FPS)))
            if f0 >= A.shape[1]:
                frames.append(np.zeros(A.shape[0]))
            else:
                frames.append(A[:, f0:min(f1, A.shape[1])].mean(axis=1))
    M = np.array(frames).reshape(reps, L, A.shape[0])
    return np.nan_to_num(how(M, axis=0))


def extract_line(GA, lo, hi, gate_frac=0.30, second=False):
    """折叠网格 → [(步, 长, midi, 强度)]；second=True 时返回次强声部。"""
    sl = GA[:, lo - MIDI_LO:hi - MIDI_LO + 1].T
    med = np.median(sl, axis=1, keepdims=True)
    S = np.maximum(sl - med * 0.55, 0)
    L = S.shape[1]
    idx = np.argmax(S, axis=0)
    if second:
        # 屏蔽已选峰（±2 半音 + 全行），取次峰
        S2 = S.copy()
        S2[idx, np.arange(L)] = 0
        for d in (-2, -1, 1, 2):
            j = idx + d
            ok = (j >= 0) & (j < S2.shape[0])
            S2[j[ok], np.arange(L)[ok]] *= 0.2
        idx2 = np.argmax(S2, axis=0)
        peak = S2[idx2, np.arange(L)]
        base = S[idx, np.arange(L)]
        use = peak > 0.35 * np.maximum(base, 1e-9)
        idx = np.where(use, idx2, -1)
        if use.sum() < 0.30 * L:
            return []
        S = S2
        idx = np.where(idx >= 0, idx, -1)
    # 3 步众数平滑
    sm = idx.copy()
    for s in range(1, L - 1):
        a, b, c = idx[s - 1], idx[s], idx[s + 1]
        if b < 0:
            sm[s] = a if a == c and a >= 0 else -1
        else:
            sm[s] = b if (a == b or c == b) else (a if a == c and a >= 0 else b)
    floor = float(np.percentile(S.max(axis=0), 55)) * gate_frac
    out, s = [], 0
    while s < L:
        p = sm[s]
        e = s
        while e + 1 < L and sm[e + 1] == p:
            e += 1
        if p >= 0:
            strength = float(np.median(S[p, s:e + 1]))
            if strength >= floor:
                out.append((s, e - s + 1, p + lo, strength))
        s = e + 1
    merged = []
    for n in out:
        if merged and n[2] == merged[-1][2] and \
                n[0] <= merged[-1][0] + merged[-1][1] + 1:
            m0 = merged[-1]
            merged[-1] = (m0[0], n[0] + n[1] - m0[0], n[2], max(m0[3], n[3]))
        else:
            merged.append(n)
    return merged


def drum_loop(y, sr, bpm, phase, loop_bars, bars):
    """打击 onset → [(步, kind)]，循环折叠后保留稳定位。"""
    import librosa
    y_p = librosa.effects.percussive(y=y)
    env = librosa.onset.onset_strength(y=y_p, sr=sr, hop_length=512)
    peaks = librosa.util.peak_pick(
        env, pre_max=3, post_max=3, pre_avg=6, post_avg=6, delta=0.6, wait=5)
    stft = np.abs(librosa.stft(y_p, hop_length=512))
    freqs = librosa.fft_frequencies(sr=sr)
    low = (freqs >= 40) & (freqs <= 180)
    mid = (freqs >= 1000) & (freqs <= 4000)
    L = loop_bars * 16
    hits = {}
    step = 60.0 / bpm / 4
    for pk in peaks:
        t = pk * 512 / sr
        st = int(round((t - phase) / step))
        if not (0 <= st < bars * 16):
            continue
        lo = stft[low, max(0, pk - 2):pk + 3].max()
        md = stft[mid, max(0, pk - 2):pk + 3].max()
        hits.setdefault(st % L, []).append("kick" if lo > md else "snare")
    out = []
    for st, kinds in sorted(hits.items()):
        if len(kinds) >= 2:
            out.append((st, "kick" if kinds.count("kick") >= len(kinds) / 2
                        else "snare"))
    return out


def chords_from_fold(GA, bpm, bars):
    """折叠激活逐 2 小节聚类三和弦 → [(pattern, [midi×3])]。"""
    out = []
    for pair in range(0, bars, 2):
        seg = GA[pair * 32:(pair + 2) * 32]
        if not len(seg):
            out.append((pair // 2, [48, 52, 55]))
            continue
        agg = seg.max(axis=0)
        pcs = {}
        for j, p in enumerate(range(MIDI_LO, MIDI_HI + 1)):
            pcs[p % 12] = pcs.get(p % 12, 0.0) + agg[j]
        best, score = (0, (0, 4, 7)), -1e9
        for root in range(12):
            for iv in ((0, 4, 7), (0, 3, 7)):
                s = sum(pcs.get((root + i) % 12, 0) for i in iv) \
                    - 0.5 * sum(v for k, v in pcs.items()
                                if k not in {(root + i) % 12 for i in iv})
                if s > score:
                    best, score = (root, iv), s
        root, iv = best
        out.append((pair // 2, [48 + (root + i) % 12 for i in iv]))
    return out


def _build_song(A, y, sr, bpm, dur, bars):
    """按给定速度网格折叠并提取全部声部 → Song。"""
    step = 60.0 / bpm / 4
    f = flux(A)
    ph = np.arange(16) * step / 16
    idx = np.minimum((ph[None, :] + np.arange(0, dur, step)[:, None])
                     * FPS, len(f) - 1).astype(int)
    phase = ph[int(np.argmax(f[idx].mean(axis=0)))]
    loop_bars = _bars_for(_loop_period(A), bpm)
    use_bars = min(bars, loop_bars if loop_bars >= 2 else bars)
    GA = fold(A, bpm, phase, use_bars, dur)
    lead = extract_line(GA, 58, 88)
    second = extract_line(GA, 48, 78, second=True)
    bass = extract_line(GA, 33, 55, gate_frac=0.25)
    speed = max(2, min(15, round(900 / bpm)))
    song = cm.Song(speed)

    def put(notes, ch, wave, vol):
        for st, ln, m, _s in notes:
            st %= 4096
            m = max(13, min(106, int(m)))
            while ln > 0 and st < 4096:
                pat, pos = st // 32, st % 32
                seg = min(ln, 32 - pos)
                song.put(pat, ch, [(pos, midi_name(m), seg, wave, vol)])
                st += seg
                ln -= seg

    put(lead, cm.MELO_CH, "pulse", 10)
    put(second or [], cm.HARM_CH, "organ", 6)
    put(bass, cm.BASS_CH, "bass", 9)
    if not second:
        for pat, triad in chords_from_fold(GA, bpm, use_bars):
            seq = [triad[0], triad[1], triad[2], triad[1]]
            song.put(pat, cm.HARM_CH,
                     [((b % 32), midi_name(seq[b % 4] + 12), 1, "organ", 4)
                      for b in range(32)])
    for st, kind in drum_loop(y, sr, bpm, phase, use_bars, use_bars):
        pat, pos = st // 32, st % 32
        if kind == "kick":
            song.put(pat, cm.DRUM_CH, [(pos, "C2", 1, "nlong", 10)])
        else:
            song.put(pat, cm.DRUM_CH, [(pos, "D3", 1, "nshort", 7)])
    desc = "%.0f BPM %d 小节 speed %d：主音 %d 副声部 %d 贝斯 %d" % (
        bpm, use_bars, speed, len(lead), len(second), len(bass))
    return song, desc


def audio_track(path, bars):
    """一个音频文件 → (Song, 描述)。

    梳状评分对速度八度（×2/÷2）与附点（×3/2）不敏感，FC-16 又只有
    整数 speed——因此综合梳状评分与 librosa beat_track 两个独立估计
    生成候选速度集合，用真实宿主渲染与源音频的色度相似度选优
    （verify_music.score_song）。
    """
    import librosa
    y, sr = load(path)
    dur = len(y) / sr
    A = salience(y, sr)
    bpm, _ph, _lb = find_grid(A, dur)
    bt = float(np.atleast_1d(librosa.beat.beat_track(y=y, sr=sr)[0])[0])
    pool = {round(bpm * 10) / 10, round(bt * 10) / 10}
    for base in (bpm, bt):
        for mult in (0.5, 2.0):
            v = round(base * mult * 10) / 10
            if 55 <= v <= 240:
                pool.add(v)
    cands = []
    for b in sorted(pool):
        if any(abs(b / c[0] - 1) < 0.05 for c in cands):
            continue
        song, desc = _build_song(A, y, sr, b, dur, bars)
        cands.append((b, song, desc))
    if len(cands) == 1:
        return cands[0][1], cands[0][2]
    import verify_music as vm
    gname = "_pick"
    scored = []
    for b, song, desc in cands:
        npats = max(k[0] for k in song.tracks) + 1
        s = vm.score_song(gname, song, npats, path)
        scored.append((s, song, desc))
        print("      候选 %.1f BPM → %.3f" % (b, s))
    scored.sort(key=lambda x: -x[0])
    return scored[0][1], scored[0][2]


# ================================================================ 入口

def write_target(name):
    cfg = TARGETS[name]
    parts = []
    for gname, label, src, kw in cfg["tracks"]:
        if cfg["kind"] == "midi":
            song, desc = midi_arrange.arrange(
                os.path.join(HERE, "_source", "BGM", "Midi",
                             "%s.MID" % src), **kw)
        else:
            song, desc = audio_track(os.path.join(HERE, src), kw["bars"])
        npats = max(k[0] for k in song.tracks) + 1
        print("  [%s %s] %s = %d 段" % (gname, label, desc, npats))
        parts.append((gname, song, npats))
    cm.write_all(parts, cfg["lua"])


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else ""
    if target == "mota50-info":
        # 只打印声部分类，供调参
        for _g, _l, src, kw in TARGETS["mota50"]["tracks"]:
            song = midi_arrange.parse_midi(os.path.join(
                HERE, "_source", "BGM", "Midi", "%s.MID" % src))
            print(src, "bars=%.1f" % (song["end"] / 1920))
        return
    if target not in TARGETS:
        raise SystemExit("用法：python transcribe_music.py %s"
                         % "|".join(sorted(TARGETS)))
    print("转录目标 %s →" % target, TARGETS[target]["lua"])
    write_target(target)


if __name__ == "__main__":
    main()
