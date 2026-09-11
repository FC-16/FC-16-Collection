# 赤色之夜（Crimson Night）

本卡带直接由 `third_party/crimson_night/code.lua` 逐函数迁移为 Lua 5.4 + FC-16
原生 API；没有 PICO-8 兼容层或源码转换器。原作的教程、移动、自动瞄准、左轮六发
弹仓与换弹、冲刺、敌人、经验宝石、升级三选一、受伤无敌闪烁和死亡后 Start 重启
均保留。受击闪红（`pal` 白→红整帧重映射）、敌人死亡溅血（20 粒血珠 + 地面
28 点血渍渐隐）、伤害数字与相机震动均已逐帧对照原版复刻。

精灵由原始 8×8 图像按瓦片最近邻放大为 16×16，并按 FC-16 的逐瓦片布局写入；地图
按 `map.png` 的 128×32 灰度瓦片号还原到 FC-16 地图区（PICO-8 的 map 行 32..63
与精灵表下半共享 RAM，属精灵数据而非作者地图，不迁移；原作地图本就只有 34 格
涂鸦）。解码器已改用 PICO-8 标准调色板（此前误用非标准色表导致整张精灵表色相
漂移），精灵与代码层颜色一致。

## 本地化与手感

- 升级三选一的技能/增益名、教程、死亡结算全部中文（字集均在固件字集内）；文本
  居中一律用 `tw()` 计宽（中文全宽 16px / ASCII 8px，`#str` 是字节数不可用）。
- 影子：PICO-8 `ovalfill(x0,y0,x1,y1)` 包围盒签名换算为 FC-16 中心 + 双半轴
  （玩家 / 敌人 / 炸药 / 经验宝石四处），玩家脚下椭圆阴影按原作恢复。
- 左轮弹仓：黑盘、弹巢旋转与中心图标统一以盘心 `(112,112)` 为圆心，弹壳按正
  六边形顶点绕盘心旋转，精灵绘制原点对齐素材图案中心（图案在 16×16 格内偏
  6.5/6.5 与 6.5/8.5，居中按视觉中心而非格子中心）。
- 受伤反馈：触碰掉血时 `rumble(160,90,12)`，死亡 `rumble(255,180,40)`
  （SPEC §12.5；无手柄或禁用时宿主静默忽略）。

## 颜色

代码层的色彩常量一律经 `COL` 表取值（文件头部）：PICO-8 色号 0–15 → FC-16
64 色号，由 `convert_assets.py` 按 `assets/palette.dat` 最近色生成（与精灵像素
转换同源，转换器运行时打印该表）。PICO 白色（7）映射到 FC 7 白，
因此 `pal(7,8)` 类重映射在移植里写作 `pal(COL[7], COL[8])`。PICO-8 的三角、倾斜锯齿、锯齿、方波、脉冲、Organ、噪声、Phaser 分别使用 FC-16 的 TRIANGLE、TILTED SAW、SAW、SQUARE、PULSE 25、ORGAN、NOISE SHORT、ROUND；自定义乐器降级为 ROUND。转换器不再写入 FC-16 的卡带保留波表区。

## 音频

PICO-8 音频时钟实测 120Hz（每 tick = 1/120s = 0.5 个 FC-16 帧），转换以此为准：

- **SFX**：68B 记录逐音符解码后写入 112B（16B 头 + 32×3B）。速度 = PICO speed/2 帧；
  PICO tracker 的 C0=65.4Hz 对应 FC 科学音高 C2，故整体上移 24 半音
  （`note = pitch + 25`，0 保留为休止）；
  音量 ×2；PICO 的逐音效果直接映射到 FC 的 Effect 码。SFX 127
  为全休止占位，见下。
- **音乐**：PICO 的 64 行乐谱逐行重建为 64 个 FC Pattern；每段在通道 0/3/5/7
  直接引用对应 SFX，各声部保留自身速度；最左非循环声部控制 Pattern 时长。通道 OFF 引用全休止的 SFX 127。
  原 loop-start 5 / loop-end 16 映射为 Pattern 5 的 BEGIN 与 Pattern 16 的 END。
- **通道路由**：`music(0, 0, 169)`——通道 0/3/5/7 交给音乐，1/2/4/6 留给音效。
  若不传 mask，music 默认占用全部 8 通道；显式通道音效仍可抢占音乐声部。枪声 1 / 拾取 2 / 升级 4，
  其余自动路由。

## 帧率

原作使用 PICO-8 默认 30Hz `_update()` / `_draw()`，移植版已原生迁移到 FC-16 60Hz：运动与物理
使用半帧时间步，计时器以 0.5 推进，随机概率与缓动使用 60Hz 等效公式，按秒动画保持原值；原作
`_draw()` 内的粒子、拾取与受击状态也按同一时间步推进。不使用隔帧更新或复用帧缓冲。

## 构建

```bash
python3 third_party/crimson_night/decode_p8png.py \
  third_party/crimson_night-5.p8.png third_party/crimson_night
python3 third_party/skills/pico8-to-fc16/convert_assets.py \
  third_party/crimson_night demo/crimson_night
cargo run -p fc16-tools --bin fc16mk -- \
  --name "赤色之夜" --author "Fictionity" --version 1 \
  --code demo/crimson_night/crimson_night.lua \
  --sprites demo/crimson_night/sprites.bin --map demo/crimson_night/map.bin \
  --sfx demo/crimson_night/sfx_fc16.bin --patterns demo/crimson_night/patterns_fc16.bin \
  --sflags demo/crimson_night/sflags.bin \
  --out demo/crimson_night/crimson_night.fc16 \
  --png demo/crimson_night/crimson_night.fc16.png
```

## 验证

```bash
cargo run -p fc16-host -- demo/crimson_night/crimson_night.fc16 --frames 4900 \
  --wav /tmp/cn.wav          # 82s：0–26s 前奏、其后循环段；低音 RMS 周期 40 帧
cargo run -p fc16-host -- demo/crimson_night/crimson_night.fc16 --seed 1 \
  --frames 700 --script <(printf '10 key 11\n20 key -\n130 key 11\n140 key -\n') \
  --screenshot /tmp/cn.png   # 站桩挨打：帧 376/496/616 受击（闪红 + 无敌闪烁 + rumble）
```

已核对：开场教程两屏、游戏进行（地面/敌人/血渍/子弹/左轮/经验条/影子）、升级
三选一（卡片框、选中投影、红底选择框、中文名称居中）、死亡结算（红色“游戏结束”、
红色“开始键”）；音频 WAV 分析确认 10 帧/音节拍、前奏→循环链、枪声瞬态与开火帧
一致。编辑器 MAP 视图只见作者 34 格涂鸦（行 17..22），无伪影。
