#!/usr/bin/env python3
"""把 v0.99 旧格式二进制资产转换为 v0.177 新格式。

- sfx: 128×112B（头 16B + 32 步 × 3B）→ 128×144B（头 16B + 32 步 × 4B）
- patterns: 64×16B（引用 1-128、流程位）→ MUSIC 2080B（LEN + 64 行 × 32B）
- map: 10 位 tile + 6 位 flags → 11 位 tile + 5 位 flags（前景位删除，输出前统计）
- waveforms: 由 tools/gen_waveforms.py 的移植表生成 8×80B
"""
import struct
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# 旧固件 16 音色 → 新来源 0-31（8-15 = 自定义波形 0-7）
WMAP = [0, 1, 2, 3, 4, 14, 5, 15, 8, 9, 10, 11, 12, 13, 6, 6]

# v0.99 固件 32×4bit 音色表（tools/gen_waveforms.py 同源）
OLD_WAVES = {
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
        t = j * 32 / 64
        i = int(t) % 32
        f = t - int(t)
        a, b = s[i], s[(i + 1) % 32]
        out.append(max(-128, min(127, round(a * (1 - f) + b * f))))
    return out


def waveforms_bin():
    blob = bytearray()
    for cid in range(8):
        blob += bytes(16)  # 头：BASS/FILTERS 全 0
        blob += bytes((x + 256) % 256 for x in upsample(OLD_WAVES[cid][1]))
    assert len(blob) == 640
    return bytes(blob)


def convert_sfx(old):
    assert len(old) == 128 * 112
    out = bytearray()
    for i in range(128):
        e = old[i * 112:(i + 1) * 112]
        speed = e[0] or 1
        length = e[1] or 32
        ne = bytearray(144)
        ne[0:2] = (speed * 4).to_bytes(2, 'little')  # 60Hz 帧数 → 240Hz tick
        ne[2] = length
        if e[4] & 1:  # LOOP
            ls, le = min(e[2], 31), max(min(e[3] - 1, length - 1), 0)
            if ls <= le:  # 非法循环降级为不循环
                ne[3], ne[4], ne[5] = ls, le, 1
        for st in range(32):
            p = e[16 + st * 3]
            wb = e[16 + st * 3 + 1]
            fx = e[16 + st * 3 + 2] & 7
            wave, vol = wb >> 4, wb & 15
            o = 16 + st * 4
            if p > 0:  # 休止步保持全 0（音量 0）
                ne[o], ne[o + 1], ne[o + 2], ne[o + 3] = p - 1, WMAP[wave], vol, fx
        out += ne
    return bytes(out)


def convert_patterns(old):
    out = bytearray(2080)
    out[0] = 64  # 全表 LEN = 64，流程由 BEGIN/END/STOP 位决定
    for r in range(64):
        e = old[r * 16:(r + 1) * 16]
        row = 32 + r * 32
        for c in range(8):
            ref = e[c]
            out[row + c] = 0xFF if ref == 0 else ref - 1
        fl = e[8]
        if fl & 1: out[row + 16] = 1  # BEGIN → LOOP_START
        if fl & 2: out[row + 17] = 1  # END → LOOP_BACK
        if fl & 4: out[row + 18] = 1  # STOP
    return bytes(out)


def convert_map(old):
    n = len(old) // 2
    vals = struct.unpack(f'<{n}H', old)
    out = bytearray()
    fg = 0
    for v in vals:
        tile = v & 0x3FF
        fl = v >> 10
        if fl & 4: fg += 1  # 旧前景优先位：新格式无此位
        nv = tile | ((fl & 1) << 11) | (((fl >> 1) & 1) << 12) | (((fl >> 3) & 7) << 13)
        out += nv.to_bytes(2, 'little')
    return bytes(out), fg


def main():
    wb = waveforms_bin()
    jobs = {
        'balatro': [('sfx.bin', convert_sfx, 'sfx_new.bin'),
                    ('patterns.bin', convert_patterns, 'music_new.bin')],
        'crimson_night': [('sfx_fc16.bin', convert_sfx, 'sfx_new.bin'),
                          ('patterns_fc16.bin', convert_patterns, 'music_new.bin')],
    }
    for game, pairs in jobs.items():
        d = ROOT / game
        (d / 'waveforms_new.bin').write_bytes(wb)
        for src, fn, dst in pairs:
            data = fn((d / src).read_bytes())
            (d / dst).write_bytes(data)
            print(f'{game}/{dst}: {len(data)}B')

    # crimson_night 地图与精灵标志
    d = ROOT / 'crimson_night'
    mp, fg = convert_map((d / 'map.bin').read_bytes())
    (d / 'maps_new.bin').write_bytes(mp)
    print(f'crimson_night/maps_new.bin: {len(mp)}B（旧前景位命中 {fg} 格）')
    (d / 'sflags_new.bin').write_bytes((d / 'sflags.bin').read_bytes())
    print('crimson_night/sflags_new.bin: 复制（1024B ≤ 2048B 上限）')


if __name__ == '__main__':
    main()
