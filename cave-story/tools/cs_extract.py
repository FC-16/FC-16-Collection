#!/usr/bin/env python3
"""从 freeware Doukutsu.exe 提取 vanilla stage 表。

移植自 doukutsu-rs src/data/vanilla.rs 的扫描逻辑：
在 .text 节中定位特征字节序列，取其后 u32 LE（gTMT 的虚地址），
换算为文件偏移后读取 95 × 0xC8 字节条目。

条目布局（stage.rs:392-414）：tileset[32] | map[32] | bg_type:u32LE |
back[32] | npc1[32] | npc2[32] | boss:u8 | name[32] | pad[3]，名称为 Shift-JIS。
"""

import json
import struct
import sys

STAGE_COUNT = 95
ENTRY_SIZE = 0xC8
PATTERN = bytes([
    0x83, 0xC4, 0x08,        # add esp, 8
    0x8B, 0x45, 0x08,        # mov eax, [ebp+arg_0]
    0x69, 0xC0, 0xC8, 0x00, 0x00, 0x00,  # imul eax, 0C8h
    0x05,                    # add eax, offset gTMT
])

def cstr(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("shift_jis", errors="replace")

def main() -> None:
    exe_path, out_path = sys.argv[1], sys.argv[2]
    buf = open(exe_path, "rb").read()

    # 最小 PE32 解析：DOS 头 → PE 头 → 可选头 → 节表
    e_lfanew = struct.unpack_from("<I", buf, 0x3C)[0]
    assert buf[e_lfanew:e_lfanew + 4] == b"PE\0\0", "PE 魔数不符"
    coff = e_lfanew + 4
    n_sections = struct.unpack_from("<H", buf, coff + 2)[0]
    opt_size = struct.unpack_from("<H", buf, coff + 16)[0]
    opt = coff + 20
    image_base = struct.unpack_from("<I", buf, opt + 28)[0]
    sec0 = opt + opt_size
    sections = []
    for i in range(n_sections):
        off = sec0 + 40 * i
        name = buf[off:off + 8].rstrip(b"\0").decode("ascii", errors="replace")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", buf, off + 8)
        sections.append((name, vaddr, vsize, rawptr, rawsize))

    text = next(s for s in sections if s[0] == ".text")
    pos = buf.find(PATTERN, text[3], text[3] + text[4])
    assert pos >= 0, "未找到 gTMT 引用特征"
    gmt_va = struct.unpack_from("<I", buf, pos + 13)[0]
    rva = gmt_va - image_base
    sec = next(s for s in sections if s[1] <= rva < s[1] + max(s[2], s[4]))
    data_start = sec[3] + (rva - sec[1])
    table = buf[data_start:data_start + STAGE_COUNT * ENTRY_SIZE]
    assert len(table) == STAGE_COUNT * ENTRY_SIZE, "stage 表读取不完整"

    entries = []
    for i in range(STAGE_COUNT):
        e = table[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE]
        entries.append({
            "index": i,
            "tileset": cstr(e[0x00:0x20]),
            "map": cstr(e[0x20:0x40]),
            "bg_type": struct.unpack_from("<I", e, 0x40)[0],
            "back": cstr(e[0x44:0x64]),
            "npc1": cstr(e[0x64:0x84]),
            "npc2": cstr(e[0x84:0xA4]),
            "boss": e[0xA4],
            "name": cstr(e[0xA5:0xC5]),
        })

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=1)
    for e in entries[:8]:
        print(e)

if __name__ == "__main__":
    main()
