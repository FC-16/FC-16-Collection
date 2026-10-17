#!/usr/bin/env python3
"""按每款游戏的 fc16.project.json 使用当前 FC-16 工具重建卡带。"""
import argparse
import os
import shutil
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('games', nargs='*')
    parser.add_argument('--fc16-root', type=Path, default=Path(os.environ.get('FC16_ROOT', ROOT.parent / 'FC-16')))
    parser.add_argument('--profile', choices=('debug', 'release'), default='debug')
    parser.add_argument('--skip-tools-build', action='store_true')
    args = parser.parse_args()
    root = args.fc16_root.resolve()
    if not args.skip_tools_build:
        cmd = ['cargo', 'build', '--locked', '-p', 'fc16-tools', '--bins', '-p', 'fc16-host']
        if args.profile == 'release':
            cmd.append('--release')
        subprocess.run(cmd, cwd=root, check=True)
    binary = root / 'target' / args.profile / ('fc16-tools.exe' if os.name == 'nt' else 'fc16-tools')
    projects = {p.parent.name: p for p in ROOT.glob('*/fc16.project.json')}
    unknown = set(args.games) - projects.keys()
    if unknown:
        parser.error('未知游戏：' + ', '.join(sorted(unknown)))
    failures = []
    for game in args.games or sorted(projects):
        if game in ("doudizhu", "holdem"):
            shutil.copyfile(ROOT / "tools/cards.bin", ROOT / game / "cards.bin")
        if game == 'cave-story':
            subprocess.run([sys.executable, str(ROOT / game / 'tools/cs_luabuild.py')], check=True)
        result = subprocess.run([str(binary), 'project', 'build', str(projects[game])], capture_output=True, text=True)
        print(('OK   ' if result.returncode == 0 else 'FAIL ') + game, flush=True)
        if result.returncode:
            failures.append(game)
            print(result.stdout + result.stderr)
    if not failures:
        subprocess.run([sys.executable, str(ROOT / 'tools/gen_gallery.py')], check=True)
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
