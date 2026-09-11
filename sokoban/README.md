# 推箱子 · FC-16

经典仓库整理谜题 Sokoban 的 FC-16 演示卡带：把全部箱子推到目标点上即过关。
箱子只能推、不能拉；推墙或推另一只箱子无效；全部归位过关。收录 16 个
按难度排序的经典关卡，带悔棋、最佳推动存档、死锁提示与全套程序化音画。

## 关卡

| # | 来源 | 最少推动 |
|---|---|---|
| 1-15 | David W. Skinner《Microban》关卡集 #2 / #21 / #4 / #1 / #17 / #9 / #15 / #3 / #11 / #19 / #10 / #6 / #8 / #16 / #143 | 3 → 65 |
| 16 | Thinking Rabbit 原版关卡集 Level 1（1982，经 1988 年流传文本） | 97 |

两套关卡文本均为公开流传的事实数据（Microban 见 borgar.net 收录，
原版集见 sokoban-jd 流传的 Original collection）；逐关经离线 push-A*
求解器验证可解，表中"最少推动"即求解器算得的最优值（原版 #1 的 97
推动与公开记录一致）。关卡按最少推动数升序排列，构成难度曲线。

## 视口与画面

- 小关卡（≤14×12）居中以 16px 大格绘制；大关卡自动换 12px 小格，
  19×11 的原版 #1 也能整屏装下，无需滚动。
- 瓦片、工人、标题字位图全部由 `_init` 逐像素 `poke`/`sset` 程序化生成，
  卡带不携带二进制美术资产；工人有四向两帧行走动画。
- 推动有 5 帧滑动缓动；箱子归位白框闪光 + 上行三连音；目标菱形呼吸
  （绘制期 pal 重映射）；过关粒子庆祝与横幅；百叶窗转场；全通关终章。
- 标题"推箱子"三字先用固件字体画入屏幕、放大 3 倍转录进精灵表，
  再以 sspr 带投影绘制。

## 音频

SFX 与 BGM 均由 `_init` 程序化写入：脚步、推箱、归位、无效推、悔棋、
菜单、过关号角、终章号角、死锁警示共 11 条音效；BGM 为 A 小调八小节
平静循环（Am-F-C-G × 2，旋律 SQUARE / 贝斯 BASS / 和声 ORGAN 三声部，
8 个 Pattern 以 BEGIN/END 回环），Select 随时开关并存档。

## 操作

| 键 | 功能 |
|---|---|
| 方向 | 移动（新按立即走一步，按住每 8 帧一步） |
| Ⓑ | 悔棋（无限栈，上限 1024 步） |
| Ⓧ | 重开本关 |
| Start | 回选关菜单 |
| Select | 音乐开关 |

选关网格自由选关，★ 与数字标记已通关关卡的最佳推动数。箱子被推进
死角（对角/沿墙无目标）时底栏上方闪烁红色"卡住了 Ⓑ 悔棋"提示；
死格表由关卡装载时从目标反向"拉"BFS 预计算。

## 存档

`save-id: sokoban`；槽 1..16 为各关最佳推动数，槽 20 为音乐开关，
过关时 `dset` + `fflush` 落盘。

## 构建与运行

```bash
cargo run -p fc16-tools --bin fc16mk -- --name "推箱子" --author "FrostMiKu" \
  --version 1 --save-id sokoban --code demo/sokoban/sokoban.lua --cover 60 \
  --out demo/sokoban/sokoban.fc16 --png demo/sokoban/sokoban.fc16.png
cargo run -p fc16-host -- demo/sokoban/sokoban.fc16
```

开发期验证（headless + 输入脚本）：

```bash
cargo run -p fc16-host -- demo/sokoban/sokoban.fc16 --frames 400 \
  --screenshot out.png
```

每关可解性由仓库外求解器逐关验证（最优推动数即卡内"最少推"参考值）；
第 1 关与第 16 关另经 `--script` 完整通关回放复核（含无效推、悔棋、
重开、死锁提示、过关演出与终章）。
