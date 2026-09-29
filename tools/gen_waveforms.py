#!/usr/bin/env python3
"""把 v0.99 固件 32×4bit 音色表移植为 v0.177 自定义波形（8×80B）。

旧表值 v∈[0,15] 的有符号电平是 v*2-15（旧引擎 event_level），满幅 15。
新自定义波形是 64×i8（-128..127）循环采样，满幅 127。
32→64 采样用循环线性插值，端点不重复计权。
"""
import sys

OLD = {
    # custom_id: (旧音色名, 32 项 4bit 表)
    0: ("ROUND",      [8,9,10,12,13,14,14,15,15,15,14,14,13,12,10,9,8,6,5,3,2,1,1,0,0,0,1,1,2,3,5,6]),
    1: ("DOUBLE SAW", [2,3,3,4,5,6,6,7,8,9,9,10,11,12,12,13,2,3,3,4,5,6,6,7,8,9,9,10,11,12,12,13]),
    2: ("BELL",       [8,12,13,13,13,15,15,12,10,12,15,15,13,13,13,12,8,3,2,2,2,0,0,3,5,3,0,0,2,2,2,3]),
    3: ("BASS",       [7,9,11,12,13,14,15,15,15,14,13,12,10,9,9,8,7,7,6,6,5,3,2,1,0,0,0,1,2,3,4,6]),
    4: ("HOLLOW",     [7,7,7,8,10,11,13,15,15,15,13,11,10,8,7,7,7,8,8,7,5,4,2,0,0,0,2,4,5,7,8,8]),
    5: ("BIT",        [10,10,10,14,14,14,14,14,14,14,14,14,14,14,10,10,10,5,5,1,1,1,1,1,1,1,1,1,1,1,5,5]),
    6: ("PULSE 12",   [15,15,15,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),
    7: ("REED",       [8,12,14,15,15,15,15,14,14,13,12,12,11,11,10,9,8,6,5,4,4,3,3,2,1,1,0,0,0,0,1,3]),
}

def to_i8(v):
    return round((v * 2 - 15) / 15 * 127)

def upsample(tab):
    s = [to_i8(v) for v in tab]
    out = []
    for j in range(64):
        t = j * 32 / 64          # 0..32（不含 32）
        i = int(t) % 32
        f = t - int(t)
        a, b = s[i], s[(i + 1) % 32]
        out.append(max(-128, min(127, round(a * (1 - f) + b * f))))
    return out

def emit_lua(path):
    lines = ["-- v0.99 固件音色 → v0.177 自定义波形（tools/gen_waveforms.py 生成）",
             "-- 索引 = 自定义波形 0-7；SFX step 的来源编号 = 8 + 索引",
             "local WAVEFORM_DATA = {"]
    for cid in range(8):
        name, tab = OLD[cid]
        samples = upsample(tab)
        lines.append(f"  -- {cid}: 旧 {name}")
        lines.append("  {" + ",".join(str(x) for x in samples) + "},")
    lines.append("}")
    lines.append("")
    lines.append("local WAVEFORM_BASE = 0x0C4800  -- WAVEFORMS：8×80B（SPEC §5.2）")
    lines.append("local function init_waveforms()")
    lines.append("  for id = 0, 7 do")
    lines.append("    local base = WAVEFORM_BASE + id * 80")
    lines.append("    local t = WAVEFORM_DATA[id + 1]")
    lines.append("    for i = 0, 63 do poke(base + 16 + i, t[i + 1]) end")
    lines.append("  end")
    lines.append("end")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {path}")

def emit_bin(path):
    blob = bytearray()
    for cid in range(8):
        blob += bytes(16)            # 头：BASS/NOIZ/... 全 0
        blob += bytes((x + 256) % 256 for x in upsample(OLD[cid][1]))
    assert len(blob) == 640
    with open(path, "wb") as f:
        f.write(blob)
    print(f"wrote {path}")

if __name__ == "__main__":
    emit_lua(sys.argv[1] if len(sys.argv) > 1 else "waveforms.lua")
    if len(sys.argv) > 2:
        emit_bin(sys.argv[2])
