#!/usr/bin/env python3
"""按事件分组解码 TSC：文本按 Shift-JIS 解码，命令高亮输出，帮助复原流程图。"""

import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from cs_survey import decrypt_tsc

def main():
    raw = decrypt_tsc(open(sys.argv[1], "rb").read())
    text = raw.decode("gbk", errors="replace")
    blocks = re.split(r"(?=#[0-9]{4})", text)
    only = sys.argv[2] if len(sys.argv) > 2 else None
    for b in blocks:
        b = b.strip()
        if not b.startswith("#"):
            continue
        ev = b[1:5]
        if only and ev != only:
            continue
        # 换行显示：命令以 < 开头，输出时按命令切行以便阅读
        body = b[5:].replace("\r", "")
        parts = re.split(r"(<[A-Z]{2,3}[0-9A-Za-z:+\-\.]*)", body)
        lines, cur = [], ""
        for p in parts:
            if p.startswith("<"):
                if cur:
                    lines.append(cur)
                cur = p
            else:
                cur += p
        if cur:
            lines.append(cur)
        print(f"── #{ev}")
        for ln in lines:
            print("   ", ln)

if __name__ == "__main__":
    main()
