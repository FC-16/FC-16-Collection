# 弹跳鸟 · FC-16

FC-16 幻想主机上的完整 Flappy Bird 演示卡带：拍翅穿管、渐进难度、昼夜天色与全套
程序化生成的美术与音乐（云朵与记分数字由 `_init` 逐字节烘焙，小鸟为运行时圆 +
三角组合绘制，SFX 与 BGM 全部程序化写入；卡带不携带二进制资产，颜色全部直取
SPEC §2.2 固定色表）。

## 玩法与规则

| 项目 | 规则 |
|---|---|
| 目标 | 操控小鸟穿过管道缺口，每通过一对 +1 分 |
| 操控 | Ⓐ / Ⓑ / 方向键拍翅：重置上升速度，重力恒定下拉 |
| 死亡 | 撞管道或落地即亡（圆形碰撞半径 6，略小于视觉，判定宽容）；顶出屏幕上缘只挡不死 |
| 难度 | 分数越高卷速越快（1.6 → 2.4 封顶）、缺口越窄（86 → 64 封底） |
| 天色 | 每局随机 白天 / 黄昏 / 夜晚 三种配色（视差云、城市剪影、灌丘同步换装，夜晚有星月、黄昏有条纹落日） |
| 奖牌 | 铜 ≥10・银 ≥20・金 ≥30・白金 ≥40，结算面板中带游走闪光 |
| 纪录 | 局中超越最高分即时弹出「新纪录」；最高分 `dset(0)` + `fflush` 持久化 |

- 状态机：标题（小鸟正弦浮动）→ 准备（按 Ⓐ 起飞）→ 游戏 → 坠落（撞击白闪 +
  羽毛四散 + 旋转俯冲 + 落地扬尘）→ 结算（面板滑入 + 分数滚动 + 奖牌号角）。
- 手感：重力 0.18 px/帧²、拍翅 -3.4 px/帧、最大下落 4.5 px/帧、管道间距 128px、
  小鸟固定于 x=72，世界向左卷动；相邻缺口中心限制 ±72px 跳变，杜绝不可达间距。
- 演出：得分白字上浮、过管音效音高随分数渐升（8 级）、地面投影随高度缩放、
  撞击震屏与显示期白闪（`pal(…, …, 1)`，帧缓冲不变）。

## 操作

| 键 | 功能 |
|---|---|
| Ⓐ / Ⓑ / ⬅⬆⬇➡ | 拍翅（标题 / 结算界面 Ⓐ 或 Ⓑ 为开始・再来一局） |
| Select | 音乐开关（任意界面，存档槽位 1 持久化） |
| Start | 结算界面回标题 |

## 音频

8 声部芯片配器：旋律 PULSE 25、琶音 TRIANGLE、贝斯 BASS、鼓组（长/短噪声），
PATTERN 0-7 以 BEGIN/END 回环，占 ch4-7；游戏音效走 ch0-2。BGM 为原创
C 大调 8 小节轻快循环。过管音高随分数渐升，撞击为方波 + 噪声脆响，
坠落为下坠滑音，奖牌 / 新纪录各有独立号角。

## 构建与运行

```bash
cargo run -p fc16-tools --bin fc16mk -- --name "弹跳鸟" --author "FrostMiKu" \
  --version 1 --code demo/flappy/flappy.lua --cover 120 \
  --out demo/flappy/flappy.fc16 --png demo/flappy/flappy.fc16.png
cargo run -p fc16-host -- demo/flappy/flappy.fc16
```

headless 验证（标题 300 帧 + 输入脚本开局打管道）：

```bash
cargo run -p fc16-host -- demo/flappy/flappy.fc16 --frames 300 --screenshot out.png
printf '100 key 4\n102 key -\n110 key 4\n112 key -\n' > script.txt
cargo run -p fc16-host -- demo/flappy/flappy.fc16 --frames 600 \
  --script script.txt --screenshot out.png
```
