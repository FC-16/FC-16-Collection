#!/usr/bin/env python3
"""生成 FC-16 结构化存档（SPEC §13 规范 JSON），用于 headless 测试注入（--save 只读）。

字段与 50_game.lua 的 do_save 一致：
stage, x/y（像素）, max_life, life, weapon_level, weapon_exp, dir,
flags = 56 个 32 位标志位字（数组第 i+1 项对应字 i）
"""

import json
import sys

def save(stage, tx, ty, life=3, wlevel=0, wexp=0, flags=()):
    mo = {13: (0, 0), 12: (0, 16), 11: (64, 0), 90: (24, 0)}[stage]
    words = [0] * 56
    for n in flags:
        words[n >> 5] |= 1 << (n & 31)
    data = {
        "stage": stage,
        "x": (mo[0] + tx) * 16 + 8,
        "y": (mo[1] + ty) * 16 + 8,
        "max_life": 3,
        "life": life,
        "weapon_level": wlevel,
        "weapon_exp": wexp,
        "dir": 1,
        "flags": words,
    }
    # 与 save() 产生的规范 JSON 一致：键按字节序升序、无多余空白
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

if __name__ == "__main__":
    stage, tx, ty = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    out = sys.argv[4]
    wlevel = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    flags = [int(x) for x in sys.argv[6].split(",")] if len(sys.argv) > 6 else []
    open(out, "wb").write(save(stage, tx, ty, wlevel=wlevel, flags=flags))
    print(f"{out}: stage={stage} tile=({tx},{ty}) weapon={wlevel}")
