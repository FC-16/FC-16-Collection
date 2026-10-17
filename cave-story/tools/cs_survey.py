#!/usr/bin/env python3
"""Cave Story 原版数据普查工具。

- TSC 解密：key = 加密文件 len/2 处字节，其余字节逐个 -key（doukutsu-rs encryption.rs）
- PXM：'PXM' + 0x10 + w:u16LE + h:u16LE + w*h 字节 tile 索引
- PXE：'PXE' + ver + count:u32LE + 12B/条 (x,y,flag,event,type,flags) + v0x10 每条附 1B layer
"""

import struct
import sys

def decrypt_tsc(buf: bytes) -> bytes:
    if not buf:
        return buf
    key = buf[len(buf) // 2] or 0x07
    out = bytearray(len(buf))
    for i, b in enumerate(buf):
        out[i] = b if i == len(buf) // 2 else (b - key) & 0xFF
    return bytes(out)

def read_pxm(path):
    d = open(path, "rb").read()
    assert d[:3] == b"PXM", path
    w, h = struct.unpack_from("<HH", d, 4)
    return w, h, d[8:8 + w * h]

def read_pxe(path):
    d = open(path, "rb").read()
    assert d[:3] == b"PXE", path
    ver = d[3]
    (count,) = struct.unpack_from("<I", d, 4)
    npcs, off = [], 8
    step = 13 if ver == 0x10 else 12
    for _ in range(count):
        x, y, flag, event, typ, fl = struct.unpack_from("<hhHHHH", d, off)
        npcs.append((x, y, flag, event, typ, fl))
        off += step
    return npcs

def main():
    cmd = sys.argv[1]
    if cmd == "tsc":
        out = decrypt_tsc(open(sys.argv[2], "rb").read())
        sys.stdout.buffer.write(out)
    elif cmd == "pxm":
        w, h, tiles = read_pxm(sys.argv[2])
        used = sorted(set(tiles))
        print(f"{w}x{h} tiles={w*h} 用到的瓦片号: {used}")
    elif cmd == "pxe":
        npcs = read_pxe(sys.argv[2])
        print(f"实体数: {len(npcs)}")
        for x, y, flag, event, typ, fl in npcs:
            print(f"  tile({x:4},{y:4}) type={typ:4} event={event:4} flag={flag} birthflags=0x{fl:04X}")

if __name__ == "__main__":
    main()
