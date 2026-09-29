#!/usr/bin/env python3
"""重建全部 FC-16 卡带（v0.177 格式）。

用法：python3 tools/build_all.py [游戏名 ...]   # 缺省全部
数据：tools/carts_meta.json（卡带名/作者/save_id/版本，取自原 .fc16 头）。
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FC16MK = pathlib.Path('/Users/lex/Codes/FC-16/target/release/fc16mk')

# 封面帧号：来自各 README 的 --cover 参数；缺失的取标题画面稳定帧
COVER = {}  # 标题画面即封面：全部取第 30 帧

# 二进制资产段（crimson_night 由 tools/convert_assets.py 预先转换；holdem/doudizhu 用 tools/cards.bin）
ASSETS = {
    'doudizhu': ['--sprites', 'tools/cards.bin'],
    'holdem': ['--sprites', 'tools/cards.bin'],
    'crimson_night': ['--sprites', 'crimson_night/sprites.bin',
                      '--maps', 'crimson_night/maps_new.bin',
                      '--sfx', 'crimson_night/sfx_new.bin',
                      '--music', 'crimson_night/music_new.bin',
                      '--sflags', 'crimson_night/sflags_new.bin'],
}


def build(game):
    meta = META[game]
    out = ROOT / game / f'{game}.fc16'
    png = ROOT / 'carts' / f'{game}.fc16.png'  # 发布封面统一输出到 carts/
    cmd = [str(FC16MK),
           '--name', meta['name'], '--author', meta['author'],
           '--version', meta['version'], '--flags', meta['flags'],
           '--code', str(ROOT / game / f'{game}.lua'),
           '--cover', str(COVER.get(game, 30)),
           '--out', str(out), '--png', str(png)]
    if meta['save_id']:
        cmd[cmd.index('--version'):cmd.index('--version')] = ['--save-id', meta['save_id']]
    for a in ASSETS.get(game, []):
        cmd.append(str(ROOT / a) if not a.startswith('--') else a)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return False, r.stdout + r.stderr
    return True, (r.stdout + r.stderr).strip()


if __name__ == '__main__':
    META = json.loads((ROOT / 'tools' / 'carts_meta.json').read_text())
    games = sys.argv[1:] or sorted(META)
    fail = 0
    for g in games:
        ok, msg = build(g)
        print(('OK  ' if ok else 'FAIL') + f' {g}: {msg.splitlines()[-1] if msg else ""}')
        fail += not ok
    sys.exit(1 if fail else 0)
