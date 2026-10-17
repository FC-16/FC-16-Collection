#!/usr/bin/env python3
"""检查当前源码与发布产物一致，并执行全部游戏的实际玩法回归。"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fc16-root', type=Path, default=Path(os.environ.get('FC16_ROOT', ROOT.parent / 'FC-16')))
    parser.add_argument('--preview-dir', type=Path, help='手动导出截图和 WAV，不作为业务验收')
    args = parser.parse_args()
    fc16 = args.fc16_root.resolve()
    env = os.environ.copy()
    env['FC16_ROOT'] = str(fc16)
    subprocess.run(['cargo', 'test', '--locked', '--manifest-path', str(ROOT / 'Cargo.toml'), '--tests'], env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(ROOT / 'celeste2/tools'), '-p', 'test_cs2_audio_fixture.py'], check=True)
    if args.preview_dir:
        output = args.preview_dir.resolve()
        output.mkdir(parents=True, exist_ok=True)
        binary = fc16 / 'target/debug' / ('fc16.exe' if os.name == 'nt' else 'fc16')
        for manifest in sorted(ROOT.glob('*/fc16.project.json')):
            game = manifest.parent.name
            subprocess.run([str(binary), str(manifest.parent / f'{game}.fc16'), '--frames', '220', '--screenshot', str(output / f'{game}.png'), '--wav', str(output / f'{game}.wav')], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
