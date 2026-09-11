# -*- coding: utf-8 -*-
"""转录质量验证（demo/magetower/verify_music.py）

对每条曲目生成一张"只播这首歌"的测试卡带，用真实 fc16-host 渲染 WAV，
再与源音频（mota50 = tswBGM MP3 对应小节窗；mota24 = B 站 WAV）做
色度相似度对比。这是转录管线的客观验收环：

  python verify_music.py mota50        # 全部曲目打分
  python verify_music.py mota24
  python verify_music.py mota50 3      # 只测第 3 首（0 起）

判读：≥0.70 接近原曲；0.55-0.70 结构对但声部/八度有偏；<0.55 需要调参
（速度候选、bar_offset、声部覆盖或音区）。
依赖：librosa、numpy；需要 target_rel2 下已构建的 fc16mk / fc16-host。
"""
import os
import re
import subprocess
import sys
import tempfile
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import transcribe_music as tm

HOST = os.path.join(ROOT, "target_rel2", "release", "fc16.exe")
MK = os.path.join(ROOT, "target_rel2", "release", "fc16mk.exe")
BEGIN = tm.cm.BEGIN
END = tm.cm.END


def read_block(lua_path):
    src = open(lua_path, encoding="utf-8").read()
    b = src.find(BEGIN)
    e = src.find(END, b)
    assert b >= 0 and e > b
    return src[b:e + len(END)]


def track_table(block):
    """解析 '-- TRACKS: 名=起始:段数:speed, ...'。"""
    m = re.search(r"-- TRACKS: (.+)", block)
    assert m, "生成块缺少 TRACKS 表"
    out = {}
    for item in m.group(1).split(","):
        name, rest = item.strip().split("=")
        base, npats, speed = (int(x) for x in rest.split(":"))
        out[name] = (base, npats, speed)
    return out


def render_track(block, base, npats, speed):
    """测试卡带 → fc16mk → host 渲染两遍循环 → 11025Hz mono。"""
    import librosa
    frames = int(npats * 32 * speed * 2) + 120
    with tempfile.TemporaryDirectory() as td:
        lua = os.path.join(td, "t.lua")
        cart = os.path.join(td, "t.fc16")
        wav = os.path.join(td, "t.wav")
        open(lua, "w", encoding="utf-8").write(
            "%s\n\nfunction _init()\n  init_audio()\n"
            "  music(%d, 0, 0x3F)\nend\nfunction _update() end\n"
            "function _draw() end\n"
            % (block, base))
        subprocess.run([MK, "--name", "verify", "--author", "verify",
                        "--version", "1", "--code", lua, "--out", cart],
                       check=True, capture_output=True)
        subprocess.run([HOST, cart, "--frames", str(frames), "--wav", wav],
                       check=True, capture_output=True)
        w = wave.open(wav)
        try:
            assert w.getsampwidth() == 2
            y = np.frombuffer(w.readframes(w.getnframes()),
                              dtype=np.int16).astype(np.float32) / 32768
            if w.getnchannels() == 2:
                y = y.reshape(-1, 2).mean(axis=1)
        finally:
            w.close()
    return librosa.resample(y, orig_sr=44100, target_sr=11025)


def chroma(y, sr=11025):
    import librosa
    c = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=512)
    return c / (np.linalg.norm(c, axis=0, keepdims=True) + 1e-9)


def similarity(a, b):
    """互相关对齐（±1s）后逐帧余弦均值。"""
    ea, eb = a.mean(axis=0), b.mean(axis=0)
    cc = np.correlate(ea - ea.mean(), eb - eb.mean(), mode="full")
    lag = int(np.argmax(cc)) - (len(eb) - 1)
    lag = int(np.clip(lag, -22, 22))
    if lag >= 0:
        a2, b2 = a[:, lag:], b[:, :a.shape[1] - lag]
    else:
        b2, a2 = b[:, -lag:], a[:, :b.shape[1] + lag]
    n = min(a2.shape[1], b2.shape[1])
    return float((a2[:, :n] * b2[:, :n]).sum(axis=0).mean()), lag


def ref_segment(kind, src, kw):
    """参考音频段：MIDI 路径取 MP3 对应小节窗；音频路径取整曲。"""
    import librosa
    if kind == "midi":
        import midi_arrange
        song = midi_arrange.parse_midi(os.path.join(
            HERE, "_source", "BGM", "Midi", "%s.MID" % src))
        bpm = 60_000_000 / song["tempo"]
        bar = 4 * 60.0 / bpm
        t0 = kw.get("bar_offset", 1) * bar
        dur = kw["bars"] * bar
        y, _ = librosa.load(os.path.join(HERE, "_source", "BGM", "BGM",
                                         "%s.mp3" % src), sr=11025,
                            mono=True, offset=t0, duration=dur)
        return y
    y, _ = librosa.load(os.path.join(HERE, src), sr=11025, mono=True)
    return y


def score_song(gname, song, npats, ref_path):
    """单首 Song → 测试卡带渲染 → 与源音频等长开窗相似度（选速用）。

    参考取源音频开头、与渲染两遍循环同时长的窗口：候选速度若错一档
    （×2/÷2），渲染覆盖的音乐内容就与窗口错位，相似度受罚。
    """
    import compose_music as cm
    import tempfile
    td = tempfile.mkdtemp()
    lua = os.path.join(td, "t.lua")
    open(lua, "w", encoding="utf-8").write(cm.BEGIN + "\n" + cm.END + "\n")
    cm.write_all([(gname, song, npats)], lua)
    block = read_block(lua)
    base, np2, speed = track_table(block)[gname]
    y = render_track(block, base, np2, speed)
    import librosa
    ref_full, _ = librosa.load(ref_path, sr=11025, mono=True)
    win = int(len(y) / 11025 * 11025)      # 与渲染等时长
    ref = ref_full[:win]
    sim, _lag = similarity(chroma(y), chroma(ref))
    return sim


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else ""
    if target not in tm.TARGETS:
        raise SystemExit("用法：python verify_music.py mota24|mota50 [序号]")
    only = int(sys.argv[2]) if len(sys.argv) > 2 else None
    cfg = tm.TARGETS[target]
    block = read_block(cfg["lua"])
    info = track_table(block)
    print("%s 转录相似度（vs 源音频）：" % target)
    total, cnt = 0.0, 0
    for i, (gname, label, src, kw) in enumerate(cfg["tracks"]):
        if only is not None and i != only:
            continue
        base, npats, speed = info[gname]
        y = render_track(block, base, npats, speed)
        if cfg["kind"] == "audio":
            import librosa
            full, _ = librosa.load(os.path.join(HERE, src), sr=11025,
                                   mono=True)
            ref = full[:len(y)]             # 与渲染等时长的源片段
        else:
            ref = ref_segment(cfg["kind"], src, kw)
        sim, lag = similarity(chroma(y), chroma(ref))
        total, cnt = total + sim, cnt + 1
        print("  [%d %-9s %-14s] %.3f (lag %+d)" % (i, gname, label, sim, lag))
    if cnt > 1:
        print("  均值 %.3f" % (total / cnt))


if __name__ == "__main__":
    main()
