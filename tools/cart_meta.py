#!/usr/bin/env python3
"""解析 .fc16 头部元数据（cart.rs 头部布局）并输出 JSON。"""
import sys, json, pathlib

def meta(path):
    raw = pathlib.Path(path).read_bytes()
    # 文本头："fc16\n" + 键值行，随后二进制。name/author/save_id 也在二进制头 6/38/70
    head = raw[:4096]
    d = {}
    if head.startswith(b'fc16\n'):
        for line in head[5:].split(b'\n'):
            if b': ' in line:
                k, v = line.split(b': ', 1)
                try: d[k.decode()] = v.decode()
                except UnicodeDecodeError: pass
            if line == b'': break
    # 二进制固定头：name@6 32B, author@38 32B, save_id@70 32B, version@102 u32, icon@106, flags@362 u16
    def s(off):
        b = raw[off:off+32]
        return b[:b.index(0)].decode('utf-8', 'replace') if 0 in b else b.decode('utf-8', 'replace')
    out = {'name': s(6), 'author': s(38), 'save_id': s(70),
           'version': int.from_bytes(raw[102:106], 'little'),
           'flags': int.from_bytes(raw[362:364], 'little')}
    out['text_header'] = d
    return out

if __name__ == '__main__':
    result = {}
    for p in sorted(pathlib.Path('.').glob('*/*.fc16')):
        result[p.parent.name] = meta(p)
    print(json.dumps(result, ensure_ascii=False, indent=1))
