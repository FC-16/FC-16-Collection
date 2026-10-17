#!/usr/bin/env python3
"""合并 project/*.lua 为单一卡带源码 build/cart.lua（CS 数据内联）。"""

from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ORDER = ["10_data", "12_const", "14_util", "20_tsc", "30_player", "40_npc",
         "50_game", "60_scripts", "99_main"]

def main():
    csdata = (HERE / "build" / "csdata.lua").read_text(encoding="utf-8")
    assert "\nreturn {" in csdata or csdata.lstrip().startswith("return {")
    head = "-- ⚠️ 由 tools/cs_luabuild.py 生成，勿手改\n" + \
        csdata.replace("return {", "CS = {", 1) + "\n\n"
    parts = [head]
    for name in ORDER:
        parts.append(f"-- ════════ {name}.lua ════════\n")
        parts.append((HERE / "project" / f"{name}.lua").read_text(encoding="utf-8"))
        parts.append("\n")
    out = "".join(parts).rstrip() + chr(10)
    (HERE / "build" / "cart.lua").write_text(out, encoding="utf-8")
    print(f"cart.lua: {len(out)} 字节, {out.count(chr(10))} 行")

if __name__ == "__main__":
    main()
