#!/usr/bin/env python3
"""全量 headless 验收：每个卡带跑 400 帧，检查退出码、Lua 错误、截图、音频 RMS。

有输入脚本的游戏（标题静音/需按键）用对应脚本。结果汇总输出。
"""
import math
import pathlib
import struct
import subprocess
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
FC = pathlib.Path('/Users/lex/Codes/FC-16/target/release/fc16')
TMP = pathlib.Path('/tmp/fc16_verify')
TMP.mkdir(exist_ok=True)

FRAMES = 400
# 需要按键才进入对局/开声的游戏：<帧> key <组合>（4=A，11=Menu）
SCRIPTS = {
    # Splash 占 0-90 帧：进入游戏的按键统一安排在 140 帧之后
    'pacman':      '140 key 4\n170 key -\n',
    'thunder':     '140 key 11\n170 key -\n',
    'riichi':      '170 key 4\n210 key -\n',
    'doudizhu':    '170 key 4\n210 key -\n370 key 4\n410 key -\n',
    'holdem':      '170 key 4\n210 key -\n',
    'xiangqi':     '170 key 4\n210 key -\n',
    'battlecity':  '140 key 4\n170 key -\n',
    'survivors':   '140 key 4\n170 key -\n',
    'klotski':     '140 key 4\n170 key -\n350 key 4\n380 key -\n',
}
SILENT_OK = {'tunnel'}  # 本身无声 / 联机大厅无声


def rms_stats(path):
    w = wave.open(str(path))
    n = w.getnframes()
    if n == 0:
        return 0, 0, 0
    s = struct.unpack(f'<{n*2}h', w.readframes(n))
    ch = 11025
    rms = [math.sqrt(sum(x * x for x in s[i:i + ch]) / ch)
           for i in range(0, len(s) - ch, ch)]
    return (round(max(rms)), sum(1 for r in rms if r > 100), len(rms))


def main():
    fails = []
    for cart in sorted(ROOT.glob('*/*.fc16')):
        game = cart.parent.name
        shot = TMP / f'{game}.png'
        wav = TMP / f'{game}.wav'
        err = TMP / f'{game}.err'
        cmd = [str(FC), '--frames', str(FRAMES), '--screenshot', str(shot), '--wav', str(wav)]
        if game in SCRIPTS:
            sc = TMP / f'{game}.txt'
            sc.write_text(SCRIPTS[game])
            cmd += ['--script', str(sc)]
        cmd.append(str(cart))
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        combined = r.stdout + r.stderr
        lua_err = '运行时错误' in combined or 'syntax error' in combined
        peak, on, total = rms_stats(wav) if wav.exists() else (0, 0, 0)
        audio_ok = (peak > 100) if game not in SILENT_OK else True
        ok = r.returncode == 0 and not lua_err and shot.exists() and audio_ok
        status = 'OK  ' if ok else 'FAIL'
        print(f'{status} {game:14s} exit={r.returncode} luaerr={lua_err} '
              f'audio_rms={peak} segments={on}/{total}')
        if not ok:
            fails.append(game)
            (err).write_text(combined)
    print()
    print('FAILED:', fails if fails else 'none')
    return 1 if fails else 0


if __name__ == '__main__':
    raise SystemExit(main())
