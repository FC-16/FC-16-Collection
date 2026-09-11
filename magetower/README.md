# 魔塔素材工作区（demo/magetower）

本目录是 **demo/mota24**（24 层魔塔）与 **demo/mota50**（50 层魔塔）两张
独立卡带的素材提取与生成工作区，本身不含卡带。原始 SWF、原曲音频等素材只留
在本地 `_source/`（已 gitignore，不入库）。

## 工具

| 文件 | 用途 |
|---|---|
| `extract_swf.py` | 原版 SWF → 楼层地图/怪物/文本数据（24F 纯 Python 自检；50F 需 FFDec） |
| `extract_art.py` | 原版 SWF → `_source/art24/`、`_source/art50/` 位图与 `_source/audio/` 原曲留档 |
| `convert_art.py` | 位图 → 16×16 图块 RLE（含标题帧烘焙），写回两张卡带源 |
| `midi_arrange.py` | 50F 原版 MIDI → 芯片谱面（声部分类 + 16 分网格量化，被转录入口调用） |
| `transcribe_music.py` | 转录入口：mota50 走 MIDI 精确转录；mota24 走 B 站音频转录（速度双估计 + 宿主渲染选优） |
| `verify_music.py` | 渲染验收环：每曲生成测试卡带 → 真实 fc16-host 渲染 → 与源音频色度相似度 |
| `compose_music.py` | 写谱库：SFX/Pattern 布局（SPEC §5.2，内容寻址去重），被上面三者调用 |

50F 音源为 Tower of the Sorcerer 1.2r1 自带 MIDI 与 tswKai 整合包
（[tswBGM](https://github.com/Z-H-Sun/tswBGM) 的 BGM.zip，MIT 授权；
MIDI 在 [TSW_all_in_one.zip](https://github.com/Z-H-Sun/tswKai/releases)
的 `TSW1.2r1/Midi/`）。楼层→曲目映射由 TSW.exe 反汇编 `soundcheck`
确认（0F/序章 Entry、1-10F B_067、11-20F B_058、21-30F B_110、
31-40F A_118、41-49F A_019、50F B_018、通关 B_014）。

## _source/ 布局

| 路径 | 内容 |
|---|---|
| `24层魔塔.swf` / `50层魔塔.swf` | 用户提供原版 Flash |
| `ffdec/` | FFDec CLI（渲染标题帧、反编译 50F） |
| `title_render/` | FFDec 逐帧渲染（标题干净帧 1100、序章/通关文转录用） |
| `art24/` / `art50/` | 逐图块位图（mt_XX / IconN） |
| `audio/` | SWF 内嵌原曲 MP3 留档 + 元数据（50F 仅音效，无 BGM） |
| `BGM/Midi/` | TSW 原版 MIDI（50F 音乐源，17 曲） |
| `BGM/BGM/` | tswBGM 320kbps MP3（同 MIDI 的 Timidity 渲染，验证参考） |
| `bili24/` | B 站《24层魔塔BGM FC音色重制版》六曲（24F 音乐来源，BV14h411F77W） |

## 重建流程

```bash
# 1) 提取数据（数据已入库生成，仅原始数据复现时需要）
python demo/magetower/extract_swf.py "24层魔塔.swf" "50层魔塔.swf" \
  --ffdec ffdec-cli.jar --out data.json --check

# 2) 提取美术与音频留档
python demo/magetower/extract_art.py "24层魔塔.swf" "50层魔塔.swf" --outdir _source
demo/magetower/_source/ffdec/ffdec-cli.exe -export frame \
  demo/magetower/_source/title_render "24层魔塔.swf" -select 900-1300

# 3) 生成美术块（写回 demo/mota24/mota24.lua 与 demo/mota50/mota50.lua）
python demo/magetower/convert_art.py

# 4) 转录音乐（分别写回两个卡带源）
python demo/magetower/transcribe_music.py mota24
python demo/magetower/transcribe_music.py mota50

# 5) 渲染验收（mota24 需先跑第 4 步；相似度均值参考 0.75 上下）
python demo/magetower/verify_music.py mota24
python demo/magetower/verify_music.py mota50

# 6) 打包（见 demo/mota24 / demo/mota50 各自 README）
```

B 站音频下载方式：playurl API（`fnval=16` 取 dash 音频流，需带 Referer）+
ffmpeg 转 WAV。MIDI/MP3 从 tswKai release 整合包或 tswBGM 仓库下载后
按上表目录放置。
