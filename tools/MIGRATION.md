# FC-16 v0.99 → v0.177 卡带迁移规则

目标规范：`/Users/lex/Codes/FC-16/spec/`（machine.md §4/§5、audio-engine.md、API_REFERENCE.md）。
本文只列**必需**的代码改写规则；游戏逻辑不动。

## 1. SFX 数据布局（运行时 poke 的游戏）

旧：`base = 0x060000 + id*112`；头 16B + 32 步 × 3B。
新：`base = 0x0C0000 + id*144`；头 16B + 32 步 × 4B（SPEC §5.2）。

| 旧偏移 | 旧含义 | 新偏移 | 新写法 |
|---|---|---|---|
| +0 | speed（每步帧数，0 按 1） | +0..1 | SPD u16 小端 = `speed*4`（240Hz tick）；不得为 0 |
| +1 | length（1–32） | +2 | LEN 原值 |
| +2 | loop_start | +3 | 原值 |
| +3 | loop_end（**排他** 1–32） | +4 | LOOP END = `旧值-1`（新为**包含**，须 < LEN） |
| +4 | bit0 LOOP | +5 | LOOP 0/1 原值 |
| +5..15 | 保留 0 | +6..15 | 保留 0 |
| +16+i*3 | 音高（0=休止；1–96=C0–B7） | +16+i*4 | PITCH = `旧-1`（0–95=C0–B7）；休止步写 0 |
| | 波形 `wave*16+vol` | +17+i*4 | INSTRUMENT = `WMAP[旧wave]`（见下） |
| | 效果 | +18+i*4 | VOLUME：休止步必须 0，其余原值 |
| | | +19+i*4 | EFFECT 0–7 原值 |

**休止**：旧音高 0 → 新 `PITCH=0, VOLUME=0`。非休止步 VOLUME 不变。

**音色映射 WMAP**（旧 16 音色 → 新来源 0–31；8–15=自定义波形 0–7）：

```
旧 0–4 → 0,1,2,3,4      （TRIANGLE/TILTED SAW/SAW/SQUARE/PULSE）
旧 5     → 14            （PULSE 12 → 自定义波形 6）
旧 6     → 5             （ORGAN）
旧 7     → 15            （REED → 自定义波形 7）
旧 8–13  → 8,9,10,11,12,13（ROUND/DOUBLE SAW/BELL/BASS/HOLLOW/BIT → 自定义波形 0–5）
旧 14,15 → 6             （NOISE LONG/SHORT → 系统噪声）
```

Lua 写法：`local WMAP = {[0]=0,1,2,3,4,14,5,15,8,9,10,11,12,13,6,6}`。

**自定义波形数据**（每个游戏 `_init` 里先写一次，`tools/gen_waveforms.py` 已生成模板）：
`0x0C4800 + id*80`，+0..15 头全 0，+16..79 为 64 个 i8（poke 时按 `x % 256` 打包）。
完整 Lua 模板见 `tools/waveforms_template.lua`。

## 2. PATTERN → MUSIC（运行时 poke 的游戏）

旧：`0x063800 + pat*16`，+0..7 通道引用（0=空，1–128=SFX 0–127），+8 流程位（bit0 BEGIN、bit1 END、bit2 STOP）。
新：MUSIC 区基址 `0x0C5380`：

- `+0`：全表 LEN = 使用的行数（0–64），**必须写**。
- 行 r 在 `0x0C5380 + 32 + r*32`：
  - `+0..7`：八个 SFX ID（0–127；**空轨写 0xFF**，0 是合法 SFX 号）。
  - `+8..15`：八个声像 -1/0/1（默认 0，可整段不清）。
  - `+16`：LOOP_START（旧 BEGIN）；`+17`：LOOP_BACK（旧 END，行尾回最近 LOOP_START）；`+18`：STOP（旧 STOP）。
- 旧引用值 v>0 → ID `v-1`；旧 0 → `0xFF`。

`music(row, fade, mask)`、`sfx(...)` 调用不变（mask/通道语义同旧）。

## 3. 其他地址迁移

| 旧 | 新 | 内容 |
|---|---|---|
| `0x040000` | `0x080000` | MAP 0（128KiB，格编码：低字节 tile 低 8 位；高字节 tile 位 8–10 占低 3 位，flags 5 位占高位） |
| — | `0x0A0000` | MAP 1（新增第二平面） |
| `0x060000` | `0x0C0000` | SFX |
| `0x063800` | `0x0C5380` | MUSIC（新格式） |
| `0x064000` | `0x0C5BA0` | 精灵标志（2048B） |
| `0x064400` | `0x0C63A0` | 自定义数据 |
| `0x0A0000` | `0x100000` | 工作内存 |
| `0x0B0000` | `0x110000` | 屏幕像素 |
| `0x0C0000` | `0x120000` | 绘制状态 |
| `0x0C1000` | `0x121000` | 只读机器状态（布局变了：budget_used/limit 已删除；音频窗在 +0x08） |

**旧地图格裸写**（如 showcase `0x040000 + (cy*256+cx)*2`）：tile≤255 且 flags=0 时低字节不变、高字节 0→0 无需换算；其余按 `高字节 = (tile>>8)&7 | (flags&31)<<3` 重算。

**budget_used/budget_limit 已从机器状态删除**（v0.114）：相关自适应代码改为常数 0 或删除；debug 显示可改用 `meminfo()`。

## 4. 物理 API（v0.114–v0.124 重构）

| 旧 | 新 |
|---|---|
| `body(x,y,w,h [,kind])` | `pbox(vector.create(x,y), vector.create(w,h) [,kind])`（x,y 仍为中心） |
| `cbody(x,y,r [,kind])` | `pcirc(vector.create(x,y), r [,kind])` |
| kind `"dyn"/"stat"/"sens"` | `"move"/"wall"/"scan"` |
| `phy_gravity(v(...))` | `pgrav(vector.create(gx,gy))` |
| `phy_del(b)` | `pdel(b)` |
| `raycast(o,d,dist)` | `pray(o,d,dist)`（返回 `id,point,normal,t`） |
| `b.pos` / `b.vel`（可写 vec2） | `pstate(b)` 读 → `position,velocity`；写 → `pmove(b,pos [,vel])` |
| `b.impulse(vec)` | `pimp(b, impulse_vector)` |
| `b.hit(cb)` | `phit(b, cb)`（cb 参数同为 `other_id, normal, depth`） |
| `b.mass/restitution/friction/gravity_scale/group/mask` | **已删除**；出厂手感固定（machine.toml），相关赋值删除 |
| `pnear` | 新增：`pnear(out, center, r)` 空间邻域查询 |

向量是**不可变** Luau 原生 vector：改分量要重建。

## 5. 向量 API（v0.124 删除自制 Vec2/v 接口）

| 旧 | 新 |
|---|---|
| `v(x,y)` | `vector.create(x,y)` |
| `a.x/.y` 读 | 同；**写**→重建新向量 |
| `a+b a-b -a a*n a/n` | 同 |
| `a*b`（**点积**） | `vector.dot(a,b)`（新 `a*b` 是逐分量乘！） |
| `v.len(a)` | `vector.magnitude(a)` |
| `v.norm(a)` | `vector.normalize(a)` |
| `v.rot(a,ang)` 圈制 | 手写：`local s=cos(ang) c=cos(ang)` → `vector.create(a.x*c-a.y*s, a.x*s+a.y*c)`（圈制全局 sin/cos） |
| `v.angle(a)` | `atan2(a.x, a.y)`（全局圈制 atan2，dx 在前） |
| `v.cross(a,b)` 2D z | `vector.cross(a,b).z` |

## 6. 联机 API（v0.118–v0.129 room_* 前缀）

`nearby_*`/`session_*` → `room_*`：`room_open{net="lan"|...}`（net 必填）、`room_scan(true,net)`、
`room_list()`（字段 `id,name,user,mode,players,max_players`）、`room_connect(id,cb)`、`room_close()`、
`room_state()`（`closed/connecting/waiting/connected/reconnecting`）、`room_player()`、`room_players()`、
`room_active(p)`、`room_members()`（`player,active,ready,manager,machine_id,user`）、
`room_ready(b)`、`room_set_config/get_config`、`room_start`、`room_send/recv`。
参照已迁移的官方示例：`/Users/lex/Codes/FC-16/demo/net_race/net_race.lua`。
`rec_*` 与 `_sync_init/sync_frame/sync_end/on_sync_end` 不变。

## 7. 构建与验证

- 构建（README 中各游戏命令）：`/Users/lex/Codes/FC-16/target/release/fc16mk ...`；
  旧 `--patterns` 参数已删除 → `--music`（2080B MUSIC 格式）、`--waveforms`（640B）、`--instruments`（2304B）、`--sflags`（2048B）、`--maps`（≤256KiB，MAP0+MAP1 顺序）。
- headless 验证：`/Users/lex/Codes/FC-16/target/release/fc16 --frames N --screenshot out.png [--wav out.wav] cart.fc16`；
  退出码 0、stderr 无 Lua 运行时错误为过。
- 音频有效：BGM 播放段导出 wav，非全零即音频数据被接受。

## 8. 结构化 API 兼容性（不用改）

`mget/mset/map/tline`（plane 缺省 0）、`sget/sset`、`fget/fset`、`dget/dset/fpeek/fpoke/fflush`、
`sin/cos/atan2`（圈制全局）、`rnd/srand`、`flr/mid/sgn`、`printw`、`fillp`、`btn/btnp/dir/dirp`、
`rumble`、`rec_*`、`_sync_*`、`on_sync_end` 签名均兼容旧代码。
