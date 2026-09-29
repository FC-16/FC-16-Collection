# 24 层魔塔 ・ FC-16

经典《24 层魔塔》移植（教育用途演示卡带）：序章 + 1—22 层 + 魔塔圣殿 + 地下圣域，
共 27 张 11×11 地图。开局为**原版序章故事**（上滚文字，可 Ⓐ 跳过），通关播放
**原版通关文**。

核心玩法与原版一致：怪物格必须战斗才可通过；三色钥匙开对应门；宝石/血瓶/剑盾
提升属性；楼梯换层。面对怪物先弹出**战斗预览**，损失致死或攻击不破防时禁止战斗
——数值算不过就绕路，这是魔塔的灵魂。

| 键 | 功能 |
|---|---|
| ⬅⬆⬇➡ | 移动（按住约 8 帧连续步进）；撞向怪物弹出战斗预览 |
| Ⓐ | 确认 / 对话翻页 / 确认战斗 |
| Ⓑ | 取消 / 关闭面板 |
| Start | 菜单：存档×3 / 读档×3 / 怪物手册 / 音效开关 / 回标题 |
| Select | 背景音乐开关 |

## 音乐

按原版结构**分楼层段换曲**（标题 / 1-7F / 8-14F / 15-18F / 19-24F / 通关），
同段内换层 BGM 连续播放。音源为 B 站《24层魔塔BGM，FC音色重制版》
（[BV14h411F77W](https://www.bilibili.com/video/BV14h411F77W/)，UP：
Player_C，FL Studio FC 音色重制）六曲，音频仅存本地
`../magetower/_source/bili24/`（不入库）。

由 `../magetower/transcribe_music.py mota24` 自动转录为芯片谱面：CQT 谐波
激活 → 速度网格（通量梳状评分 + librosa beat_track 双估计、宿主渲染选优）
→ 循环中位数折叠 → 主音/副声部/贝斯分区提取 → 打击鼓组。如实申报：芯片
音色与重制版音源不同，副声部与和弦垫为推断近似。

## 美术与数据

- 怪物/道具/门/墙/地板/楼梯/主角：原版 SWF 位图提取（`mt_XX` 导出角色），
  32px → 16px 降采样 → SPEC §2.2 调色板量化。
- 标题画面：原版书法"魔塔 / Magic Tower"标题帧整幅烘焙（瓦片 256–511）。
- 楼层地图/怪物数值/道具数值/商店定价：**SWF 原值**（提取管线见
  `../magetower/extract_swf.py`，24 层版纯 Python 提取、自带全量自检）。
- 序章故事页/通关文：FFDec 渲染帧逐行转录（原版为位图文字），文字近似。

## 重建

```bash
python magetower/convert_art.py             # 生成美术块写入两张卡带源
python magetower/transcribe_music.py mota24 # 音频转录写入本卡带源
python magetower/verify_music.py mota24     # 渲染验收（相似度应 ≥0.55）
cargo run -p fc16-tools --bin fc16mk -- --name "24层魔塔" --author "FrostMiKu" \
  --version 1 --save-id mota24 --code mota24/mota24.lua \
  --out mota24/mota24.fc16 --png carts/mota24.fc16.png --cover 30
cargo run -p fc16-host -- mota24/mota24.fc16
```

B 站音频下载方式见 `../magetower/README.md`。
