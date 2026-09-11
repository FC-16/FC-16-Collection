# 50 层魔塔 ・ FC-16

经典《50 层魔塔》（Tower of the Sorcerer 魔法の塔系）移植（教育用途演示卡带）：
地下密室 + 1—50 层，共 51 张 11×11 地图（图标层 + 事件层）。顶层贤者即为通关。

核心玩法与原版一致：怪物格必须战斗才可通过；三色钥匙开对应门；宝石/血瓶/剑盾
提升属性（随楼层十段缩放）；楼梯换层；手册/魔杖/十字架/圣水等特殊道具按原版
语义实现。面对怪物先弹出**战斗预览**，损失致死或攻击不破防时禁止战斗。

| 键 | 功能 |
|---|---|
| ⬅⬆⬇➡ | 移动（按住约 8 帧连续步进）；撞向怪物弹出战斗预览 |
| Ⓐ | 确认 / 对话翻页 / 确认战斗 |
| Ⓑ | 取消 / 关闭面板 |
| Start | 菜单：存档×3 / 读档×3 / 怪物手册 / 道具使用 / 音效开关 / 回标题 |
| Select | 背景音乐开关 |

## 音乐

原版 Flash 内没有 BGM（SWF 只嵌音效）；本卡带使用《Tower of the Sorcerer
1.2r1》自带的**原版 MIDI**（[tswBGM](https://github.com/Z-H-Sun/tswBGM)
整合包提取，MIT 授权）做**精确转录**——直接读取音符事件，不经过音频识别。
楼层→曲目映射由 TSW.exe 反汇编 `soundcheck` 函数确认，与原版一致：

| 楼层 | 曲目 | 原版文件 |
|---|---|---|
| 序章 / 标题 | Entry | A_027XGW |
| 1-10F | Skeleton A - Bloody Labyrinth | B_067XGW |
| 11-20F | Vampire | B_058XGW |
| 21-30F | The Sorcerer | B_110XGW |
| 31-40F | Golden Knight | A_118XGW |
| 41-49F | Zeno - Killer Trap | A_019XGW |
| 50F | Finale | B_018XGW |
| 通关 | Credits | B_014XGW |

同段内换层 BGM 连续播放（不重头起），段切换自动换曲——与 tswKai 的
BGM 改进行为一致。转录管线见 `../magetower/midi_arrange.py`（声部分类：
主音/副旋律/贝斯/鼓，每曲 6-8 小节循环，SFX/Pattern 内容寻址去重）。
如实申报：四芯片声道无法还原原曲全部声部，低声部以贝斯波近似。

## 美术与数据

- 怪物/道具/门/墙/地板/楼梯/主角：原版 SWF 位图提取（`IconN` 导出角色），
  32px → 16px 降采样 → SPEC §2.2 调色板量化。
- 标题画面：沿用系列书法"魔塔 / Magic Tower"标题帧整幅烘焙（瓦片 256–511）。
- 楼层地图（51 层）/怪物数值/道具数值/商店定价/事件：**SWF 原值**
  （FFDec 反编译解析，管线见 `../magetower/extract_swf.py`）。
- NPC 对白为 SWF 常量池原文（81 条 Msg + 15 条 NPC 交易）。

## 重建

```bash
python demo/magetower/convert_art.py             # 生成美术块写入两张卡带源
python demo/magetower/transcribe_music.py mota50 # MIDI 精确转录写入本卡带源
python demo/magetower/verify_music.py mota50     # 渲染验收（相似度应 ≥0.55）
cargo run -p fc16-tools --bin fc16mk -- --name "50层魔塔" --author "FrostMiKu" \
  --version 1 --save-id mota50 --code demo/mota50/mota50.lua \
  --out demo/mota50/mota50.fc16 --png demo/mota50/mota50.fc16.png --cover 120
cargo run -p fc16-host -- demo/mota50/mota50.fc16
```

音频源（MIDI/MP3 留档与 tswKai 整合包下载说明）见 `../magetower/README.md`；
源文件仅存本地 `_source/`（不入库）。
