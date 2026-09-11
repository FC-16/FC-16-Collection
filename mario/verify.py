#!/usr/bin/env python3
"""verify.py — demo/mario 卡带的无头验证驱动（开发用，不属于卡带本体）。

为多段验证（标题 / 1-1 开局 / 奖励房 / 1-2 通关 / 1-3 全程 / 1-4 与 Boss、
断桥、结局）生成「测试变体」卡带：把 mario.lua 复制一份并在 _init 尾部注入
直达各关卡的启动代码（仓库正式产物 mario.fc16 不受影响），用 fc16-host
无头模式逐段截图到 demo/mario/shots/。

用法：在仓库根目录执行  python demo/mario/verify.py
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEMO = ROOT / "demo" / "mario"
TMP = ROOT / "target" / "mario_verify"
SHOTS = DEMO / "shots"

# (名称, 注入 _init 的代码, 帧数, 输入脚本行, 说明)
CASES = [
    ("01_title", "", 150, None, "标题画面"),
    ("02_world11_start", "", 620, "150 key 4\n160 key -\n170 key 1\n", "1-1 开局（按 A 开始并向右走）"),
    ("03_bonus",
     'start_game() game.lvi = 1 load_level(LEVEL_BONUS, true, 40, -24) game.state = "play" play_music()',
     320, None, "1-1 地下奖励房"),
    ("04_world12_flag",
     'start_game() game.lvi = 2 load_level(LEVEL_12, true, 133*16, 80) game.state = "play" play_music()',
     460, "60 key 1\n", "1-2 旗杆"),
    ("05_world12_to_13",
     'start_game() game.lvi = 2 load_level(LEVEL_12, true, 133*16, 80) game.state = "play" play_music()',
     900, "60 key 1\n", "1-2 通关后进入 1-3"),
    ("06_world13_start",
     'start_game() game.lvi = 3 begin_play()', 260, "150 key 1\n", "1-3 开局"),
    ("07_world13_trees",
     'start_game() game.lvi = 3 begin_play() game.mario.x = 42*16 game.mario.y = 24 game.cam = 42*16-108',
     300, None, "1-3 中段树台"),
    ("08_world13_lift",
     'start_game() game.lvi = 3 begin_play() game.mario.x = 55*16 game.mario.y = 80 game.cam = 55*16-108',
     300, None, "1-3 升降平台"),
    ("09_world13_end",
     'start_game() game.lvi = 3 begin_play() game.mario.x = 142*16 game.mario.y = 40 game.cam = 142*16-108',
     300, None, "1-3 结尾大阶梯"),
    ("10_world13_flag",
     'start_game() game.lvi = 3 begin_play() game.mario.x = 145*16 game.mario.y = 100 game.cam = 145*16-108',
     480, "60 key 1\n", "1-3 旗杆与城堡"),
    ("11_world14_start",
     'start_game() game.lvi = 4 begin_play()', 280, "150 key 1\n", "1-4 开局走廊"),
    ("12_world14_firebar",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 42*16 game.mario.y = 96 game.cam = 42*16-108',
     300, None, "1-4 火棒走廊"),
    ("13_world14_coins",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 104*16 game.mario.y = 128 game.cam = 104*16-108',
     340, None, "1-4 隐形金币区与龙火"),
    ("14_world14_bowser",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 131*16 game.mario.y = 100 game.cam = 131*16-108',
     420, None, "1-4 桥与库巴"),
    ("15_world14_axe",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 139*16+8 game.mario.y = 100 game.cam = 139*16-108',
     260, "50 key 1\n", "1-4 斧头断桥"),
    ("16_world14_rescue",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 139*16+8 game.mario.y = 100 game.cam = 139*16-108',
     700, "50 key 1\n", "救出公主"),
    ("17_world14_clear",
     'start_game() game.lvi = 4 begin_play() game.mario.x = 139*16+8 game.mario.y = 100 game.cam = 139*16-108',
     1260, "50 key 1\n", "通关庆祝"),
]

INJECT_ANCHOR = '  if game.music_on then music(0, 500, 240) end\nend'


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, shell=False)
    out = (r.stdout + r.stderr).strip()
    if r.returncode != 0 or "错误" in out or "error" in out.lower():
        print("FAIL:", " ".join(str(c) for c in cmd))
        print(out)
        return False
    return True


def main():
    TMP.mkdir(parents=True, exist_ok=True)
    SHOTS.mkdir(parents=True, exist_ok=True)
    src = (DEMO / "mario.lua").read_text(encoding="utf-8")
    assert INJECT_ANCHOR in src, "未找到 _init 注入锚点"
    failures = []
    for name, inject, frames, script, desc in CASES:
        variant = src.replace(INJECT_ANCHOR,
                              '  if game.music_on then music(0, 500, 240) end'
                              + "\n  -- verify.py 注入\n  " + inject + "\nend")
        vlua = TMP / (name + ".lua")
        vlua.write_text(variant, encoding="utf-8")
        vcart = TMP / (name + ".fc16")
        if not run(["target/debug/fc16mk.exe", "--name", "验证", "--author", "t",
                    "--version", "1", "--save-id", "mario_verify",
                    "--code", str(vlua.relative_to(ROOT)), "--out", str(vcart.relative_to(ROOT))]):
            failures.append(name)
            continue
        cmd = ["target/debug/fc16.exe", str(vcart.relative_to(ROOT)),
               "--frames", str(frames),
               "--screenshot", str((SHOTS / (name + ".png")).relative_to(ROOT))]
        if script:
            sp = TMP / (name + ".txt")
            sp.write_text(script, encoding="utf-8")
            cmd += ["--script", str(sp.relative_to(ROOT))]
        ok = run(cmd)
        print(("OK  " if ok else "FAIL ") + name + "  " + desc)
        if not ok:
            failures.append(name)
    print()
    if failures:
        print("失败用例：", ", ".join(failures))
        sys.exit(1)
    print("全部通过；截图见 demo/mario/shots/")


if __name__ == "__main__":
    main()
