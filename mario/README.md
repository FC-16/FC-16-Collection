# 超级马里奥 · FC-16

FC-16 幻想主机上的横版平台跳跃致敬卡带。**World 1-1～1-4 全流程可玩：关卡布局与
敌人布点按参考反汇编逐对象转写；音乐由参考反汇编的音符表转写为 FC-16 tracker；
像素美术为原创自绘（可用自备 ROM 经提取管线替换，见下文）。**

物理常量逐项换算自开源参考实现
[MitchellSternke/SuperMarioBros-C](https://github.com/MitchellSternke/SuperMarioBros-C)
（原版亚像素表，1 亚像素 = 1/256 px，60fps）。参考仓库克隆在仓库外
`G:\github\_ref\SuperMarioBros-C`（已在 .gitignore），其 `docs/smbdis.asm`
是关卡 / 敌人 / 音乐数据的权威来源。

## 复刻范围

### World 1-1（一比一）

- 地面段与断口、全部砖 / ? 块（含隐藏 1UP 块）、四根管道（第二根可进入地下
  奖励房，出口管道回归主关卡末段）、坑、结尾楼梯与旗杆、城堡
- 敌人：16 只栗子怪 + 1 只乌龟（按 E_GroundArea6 布点，含高砖上的栗子怪与
  成对出现的组合）
- 问号块弹金币 / 蘑菇 / 火之花 / 无敌星 / 1UP；多金币砖

### World 1-2（结构复刻）

- 地下关（蓝砖配色）、天花板结构、断地与砖阵、升降平台段（原版电梯简化）、
  出口管道；通关后进入 1-3

### World 1-3（一比一转写，数据来源 L_/E_GroundArea7）

- 树梢关：入口城堡、无底深渊上的树台跳跃（x15 起取消地面）、金币列、
  蘑菇块、三只红龟 / 两只红跳跃龟、垂直升降台与三座横移台
- 结尾大阶梯（x138-143）与旗杆、城堡；结尾区顶部一行天花板（原版 terrain=2）

### World 1-4（一比一转写，数据来源 L_/E_CastleArea1）

- 城堡：分段地形（天花板深度 / 地面高度切换，与原版 terrain 控制一致）、
  全程岩浆铺底、隐形金币砖（原版 Q hidden coin / emptyBlock，共 17 块）
- 8 根火棒（$1b 快速 / $1d 慢速，转速与方向按原版 FirebarSpin 数据）、
  龙火（$15）、桥下火柱（$0c）、横移台（$28）
- 库巴 Boss 战：桥面追击、喷火、踩头反弹（侧碰受伤）、火球 5 发击破
- 斧头断桥：触碰后桥面从斧头侧逐格塌落、库巴坠入岩浆（+5000）
- 自动行走 → 公主 →「谢谢你马里奥！旅程结束了」→ 通关烟花；结局房间
  滚动锁（scrollLock @x149）

### 机制

- 三态马里奥：小 / 大（碎砖）/ 火力（Ⓑ 发射火球，屏上最多 2 发）
- 踩敌 / 踢龟壳连击计分、龟壳撞敌、受伤变小、无敌星（切换原版星星曲）
- 旗杆按抓高计分 → 滑杆 → 走进城堡 → 结算；时间告急警号（原曲）
- HUD：分数 / 金币（×100 加命）/ 世界 / 时间（400 起倒计，剩 100 警告）
- 死亡重生与续关、GAME OVER、通关庆祝；最高分与最远关卡存档

### 音乐（原曲音符表转写）

三首主曲 + 全部 jingle 由 `convert_music.py` 从参考反汇编的音符数据表
（`MusicHeaderData` / `FreqRegLookupTbl` / `MusicLengthLookupTbl`，NES 12bit
周期表换算 MIDI）自动转写为 FC-16 tracker：SFX 110 条（15-127）+ MUSIC 50 行
（0-19 地上曲按原版段落表 LOOP_START/LOOP_BACK 循环；地下 20、城堡 29、无敌星 33、
时间告急 36、死亡 38、过关号角 40、救出公主 44、游戏结束 47）。
通道分配：ch4 主旋律（SQUARE）/ ch5 和声（PULSE25）/ ch6 贝斯（TRIANGLE，
低八度）/ ch7 鼓（NOISE）；ch0-3 留给即时音效。生成段在 mario.lua 的
`BEGIN/END GENERATED MUSIC` 标记之间，一键重建：

```bash
python mario/convert_music.py          # 重建并写回 mario.lua
python mario/convert_music.py --check  # 校验生成段是否最新
python mario/convert_music.py --report # 曲目 / MUSIC 行 / SFX 预算报告
```

实现说明（规范未尽决定）：① 原版「时间告急」后主曲整体提速演奏，本作改为
播放原版警号后恢复原速；② 地上曲完整段落表为 33 段，超出 MUSIC 64 行容量，
取前两轮 + 第四段一组共 20 段；③ 时间告急省三角贝斯、死亡省方波1持续音、
过关号角省三角贝斯（SFX 110/110 槽位取舍）；④ 地下曲方波1与方波2为同度
齐奏，只保留方波2。

### 图形提取管线（建好待用，当前不替换美术）

`extract_chr.py` 读取 iNES 格式 ROM（放到 `mario/_source/smb.nes`，
`_source/` 已 gitignore、ROM 不入库），定位 CHR bank（bank0 精灵 / bank1 背景），
按《超级马里奥兄弟》PPU 调色板 → ENDESGA-64 最近色映射解码 2bpp 瓦片，
生成 `BEGIN/END GENERATED CHR` 标记段（写入精灵表整表替换）。ROM 不存在时
管线不生效、卡带使用现有致敬美术。管线含合成 CHR 自测：

```bash
python mario/extract_chr.py --selftest  # iNES 解析 / 2bpp 解码 / 映射断言
python mario/extract_chr.py             # ROM 存在时生成标记段写入 mario.lua
```

接入步骤：生成后确认 _init 调用 `chr_gen()`（生成段内有注释提示），再按画面
把 draw_* 的瓦片引用指向对应 CHR 瓦片；瓦片内调色板槽按 16×16 属性块近似
选取，接入后可按画面微调。

### 关卡数据转写

`convert_level.py` 实现 NES 区域对象 / 敌人对象字节流的解码器
（ProcessAreaData / DecodeAreaData / HandleGroupEnemies 的忠实移植），
可打印 World 1 各关卡的布局、坑、管道、敌人与布点，用于核对 mario.lua
中的 LEVEL 表：

```bash
python mario/convert_level.py                  # 全部世界 1 关卡
python mario/convert_level.py L_CastleArea1    # 指定区域
```

### 无头验证

`verify.py` 生成直达各关卡的测试变体卡带（正式 mario.fc16 不受影响），
逐段截图到 `shots/`：标题、1-1 开局、奖励房、1-2 旗杆与通关衔接、1-3 全程
（开局 / 树台 / 升降台 / 大阶梯 / 旗杆）、1-4（走廊 / 火棒 / 金币区 / 库巴 /
断桥 / 救出公主 / 通关）。

## 物理换算表（换算自参考实现）

| 参考常量 | 原值 | 换算（px/帧 或 px/帧^2） |
|---|---|---|
| MAX_WALK_SPEED | 0x18/16 | 1.5 最大步行 |
| MAX_RUN_SPEED | 0x28/16 | 2.5 最大跑动 |
| WALK_ACCEL | 0x98/256 | 0.40625 步行加速 / 低速松键减速 |
| RUN_ACCEL | 0xe4/256 | 0.109375 按住 Ⓑ 同向加速 |
| RELEASE_DECEL（高速） | 0xd0/256 | 0.1875 高速松键减速 / 空中快档加速 |
| SKID_DECEL | 2×上述两档 | 0.8125 / 0.375 反向打滑 |
| JUMP_V0 | 五档 | -4.125（慢速起跳，离散积分 ≥4 格 +2px 余量）/ -5（快速起跳） |
| RISE_GRAVITY | $20 $20 $1e $28 $28 | 0.125 / 0.125 / 0.1171875 / 0.15625 / 0.15625 |
| FALL_GRAVITY | $70 $70 $60 $90 $90 | 0.4375 / 0.4375 / 0.375 / 0.5625 / 0.5625 |
| MAX_FALL | 4 + frac<0x80 | ≈4.5 |
| ENEMY_WALK | 0x08/16 | 0.5 |
| SHELL_SPEED | 0x30/16 | 3.0 |
| FIREBALL | 0x40/16 | 4.0（重力 0.3125，落地反弹 -3） |
| STOMP_BOUNCE | $fc | -4（按住 Ⓐ 上升期轻重力） |
| TIME_TICK | — | 每 24 帧减 1 |

## 操作

| 键 | 功能 |
|---|---|
| ⬅ ➡ | 移动 |
| Ⓑ | 按住跑动；火力态发射火球 |
| Ⓐ | 跳（按住跳更高；速度越快跳得越高） |
| ⬇ | 蹲 / 进入管道 |
| Start | 暂停 |
| Select | 音乐开关 |

## 构建与运行

```bash
cargo run -p fc16-tools --bin fc16mk -- --name "超级马里奥" --author "FrostMiKu" \
  --version 1 --save-id mario --code mario/mario.lua --cover 30 \
  --out mario/mario.fc16 --png carts/mario.fc16.png
cargo run -p fc16-host -- mario/mario.fc16
```

`--cover 30` 取标题画面第 90 帧作卡带封面。卡带体积约 133KB（1MiB 预算内：
代码 384KiB、数据 640KiB）。

重建步骤（改动音符表 / 关卡数据来源后）：

```bash
python mario/convert_music.py   # 音乐生成段（可选 --check 校验）
python mario/convert_level.py   # 关卡布局核对（人工转写参考，不直接写回）
python mario/verify.py          # 无头验证 + 截图（在仓库根目录运行）
```
