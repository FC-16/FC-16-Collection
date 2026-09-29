-- 弹跳鸟 ・ FC-16 演示卡带
-- 玩法：Ⓐ/Ⓑ/方向键拍翅上飞，穿过管道缺口 +1 分；撞管 / 落地即亡，顶边只挡不死
-- 难度：分数越高卷速越快、缺口越窄（均有上限）；每局随机 白天 / 黄昏 / 夜晚 三种天色
-- 演出：视差云层 / 城市剪影 / 灌木丘陵 / 滚动地面；小鸟三态扇翅并随垂直速度倾角、
--       得分跳字、过管音高渐升、撞击白闪 + 羽毛四散、坠落扬尘、地面投影、
--       结算面板滑入 + 奖牌（铜 10 / 银 20 / 金 30 / 白金 40）游走闪光与分数滚动
-- 音频：拍翅 / 得分 / 撞击 / 坠落 / 落地 / 面板 / 奖牌 / 新纪录 SFX + 原创 8 小节
--       循环 BGM（View 开关，占 ch4-7）；最高分 dset(0)、音乐开关 dset(1) 持久化
-- 云朵、大号记分数字由 _init 程序化烘焙，小鸟为运行时三角 + 圆组合绘制
-- （SPEC §4.2/§5.2），颜色全部直取 §2.2 固定色表
-- 操作：Ⓐ/Ⓑ/方向键 拍翅 View 音乐开关 Ⓐ 开始・再来一局 Menu 回标题

-- ---------------------------------------------------------------- 常量

local GROUND_Y = 232          -- 地面顶边（世界不动，小鸟固定 x，场景左卷）
local BIRD_X = 72             -- 小鸟固定屏幕横坐标
local BIRD_R = 6              -- 碰撞半径（视觉半径 6.8，判定略宽容）
local GRAV = 0.18             -- 重力（像素/幀^2）
local FLAP_V = -3.4           -- 拍翅速度（像素/幀）
local MAX_FALL = 4.5          -- 最大下落速度
local PIPE_W = 32             -- 管道宽度
local PIPE_DIST = 128         -- 管道水平间距
local GAP0, GAP_MIN = 86, 64  -- 缺口初始 / 收缩下限（像素）
local SPD0, SPD_MAX = 1.6, 2.4 -- 卷速初始 / 上限（像素/幀）
-- 奖牌门槛：铜 10・银 20・金 30・白金 40
local MEDALS = {
  {19, 18, "铜牌"}, {8, 5, "银牌"}, {31, 28, "金牌"}, {7, 43, "白金牌"},
}
-- 天色主题：天空渐带（上→下）、云、城市剪影 / 窗灯、灌木、草地与土层
local THEMES = {
  { -- 白天
    name = "白天", sky = {40, 41, 42, 44},
    cloud = 7, cloudsh = 8, city = 9, win = false,
    hillb = 34, hillf = 33,
    grass = 33, grassst = 34, edge = 32, dirt = 23, dirtst = 22, dirtbot = 18,
  },
  { -- 黄昏
    name = "黄昏", sky = {13, 12, 11, 23},
    cloud = 57, cloudsh = 56, city = 13, win = 30,
    hillb = 36, hillf = 35,
    grass = 35, grassst = 36, edge = 34, dirt = 18, dirtst = 17, dirtbot = 16,
  },
  { -- 夜晚
    name = "夜晚", sky = {51, 39, 40, 41},
    cloud = 11, cloudsh = 12, city = 13, win = 31,
    hillb = 37, hillf = 36,
    grass = 36, grassst = 37, edge = 35, dirt = 16, dirtst = 17, dirtbot = 16,
  },
}

-- ---------------------------------------------------------------- 音频（SPEC §5.2）

local function u8(a, v) poke(a, v % 256) end
-- v0.99 固件音色 → v0.177 自定义波形（tools/gen_waveforms.py 生成）
-- 索引 = 自定义波形 0-7；SFX step 的来源编号 = 8 + 索引
local WAVEFORM_DATA = {
  -- 0: 旧 ROUND
  {8,16,25,34,42,59,76,84,93,102,110,110,110,118,127,127,127,127,127,118,110,110,110,102,93,84,76,59,42,34,25,16,8,-8,-25,-34,-42,-59,-76,-84,-93,-102,-110,-110,-110,-118,-127,-127,-127,-127,-127,-118,-110,-110,-110,-102,-93,-84,-76,-59,-42,-34,-25,-8},
  -- 1: 旧 DOUBLE SAW
  {-93,-84,-76,-76,-76,-68,-59,-50,-42,-34,-25,-25,-25,-16,-8,0,8,16,25,25,25,34,42,50,59,68,76,76,76,84,93,0,-93,-84,-76,-76,-76,-68,-59,-50,-42,-34,-25,-25,-25,-16,-8,0,8,16,25,25,25,34,42,50,59,68,76,76,76,84,93,0},
  -- 2: 旧 BELL
  {8,42,76,84,93,93,93,93,93,110,127,127,127,102,76,59,42,59,76,102,127,127,127,110,93,93,93,93,93,84,76,42,8,-34,-76,-84,-93,-93,-93,-93,-93,-110,-127,-127,-127,-102,-76,-59,-42,-59,-76,-102,-127,-127,-127,-110,-93,-93,-93,-93,-93,-84,-76,-34},
  -- 3: 旧 BASS
  {-8,8,25,42,59,68,76,84,93,102,110,118,127,127,127,127,127,118,110,102,93,84,76,59,42,34,25,25,25,16,8,0,-8,-8,-8,-16,-25,-25,-25,-34,-42,-59,-76,-84,-93,-102,-110,-118,-127,-127,-127,-127,-127,-118,-110,-102,-93,-84,-76,-68,-59,-42,-25,-16},
  -- 4: 旧 HOLLOW
  {-8,-8,-8,-8,-8,0,8,25,42,50,59,76,93,110,127,127,127,127,127,110,93,76,59,50,42,25,8,0,-8,-8,-8,-8,-8,0,8,8,8,0,-8,-25,-42,-50,-59,-76,-93,-110,-127,-127,-127,-127,-127,-110,-93,-76,-59,-50,-42,-25,-8,0,8,8,8,0},
  -- 5: 旧 BIT
  {42,42,42,42,42,76,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,76,42,42,42,42,42,0,-42,-42,-42,-76,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-110,-76,-42,-42,-42,0},
  -- 6: 旧 PULSE 12
  {127,127,127,127,127,127,127,0,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,-127,0},
  -- 7: 旧 REED
  {8,42,76,93,110,118,127,127,127,127,127,127,127,118,110,110,110,102,93,84,76,76,76,68,59,59,59,50,42,34,25,16,8,-8,-25,-34,-42,-50,-59,-59,-59,-68,-76,-76,-76,-84,-93,-102,-110,-110,-110,-118,-127,-127,-127,-127,-127,-127,-127,-118,-110,-93,-76,-34},
}

local WAVEFORM_BASE = 0x0C4800  -- WAVEFORMS：8×80B（SPEC §5.2）

local function init_waveforms()
  for id = 0, 7 do
    local base = WAVEFORM_BASE + id * 80
    local t = WAVEFORM_DATA[id + 1]
    for i = 0, 63 do u8(base + 16 + i, t[i + 1]) end
  end
end

-- 旧固件 16 音色 → 新来源编号：0-7 系统波形、8-15 自定义波形、14=PULSE 12、15=REED
local WMAP = { [0] = 0, 1, 2, 3, 4, 14, 5, 15, 8, 9, 10, 11, 12, 13, 6, 6 }

-- 写一条 SFX（SPEC §5.2：144B = 头 16B + 32 步 × 4B）
-- steps[i] = {音高, 音色, 音量[, 效果]}，nil 步与音高 0 均为休止（len 显式给全步数）
-- 音高为旧固件值（1-96 = C0-B7），写卡带前换算为新 0-95 并用音量 0 表休止
local function write_sfx(id, speed, steps, len)
  local base = 0x0C0000 + id * 144
  poke2(base, (speed == 0 and 1 or speed) * 4)  -- 旧每步帧数(60Hz) → 新 SPD tick(240Hz)
  u8(base + 2, len or #steps)
  for i = 0, 31 do
    local a, s = base + 16 + i * 4, steps[i + 1]
    if s and (s[1] or 0) > 0 then
      u8(a, s[1] - 1) u8(a + 1, WMAP[s[2] or 0]) u8(a + 2, s[3] or 0) u8(a + 3, s[4] or 0)
    else u8(a, 0) u8(a + 1, 0) u8(a + 2, 0) u8(a + 3, 0) end
  end
end
-- 原创循环 BGM（C 大调，8 小节，轻快雀跃）：每小节 = 一条 32 步 SFX（speed 4，
-- 八分音符展开 4 步）；四声部旋律 20-27 / 琶音 32-39 / 贝斯 44-51 / 鼓 56-63，
-- MUSIC 0-7 行顺序相连并 LOOP_START/LOOP_BACK 回环，占 ch4-7（music mask 0xF0）
local MUSIC_BASE = 0x0C5380  -- MUSIC 区（SPEC §5.2）：+0 LEN，行 r 在 +32+r*32
local MEL = {
  {61, 0, 65, 68, 70, 0, 68, 65}, -- C C E G A・G E
  {70, 0, 68, 65, 63, 0, 61, 0},  -- Am A G E D・C
  {61, 0, 65, 66, 68, 0, 66, 65}, -- F C E F G・F E
  {63, 0, 56, 58, 60, 0, 63, 0},  -- G D G A B・D
  {61, 0, 65, 68, 70, 0, 73, 0},  -- C C E G A・C6
  {72, 0, 70, 68, 70, 0, 0, 0},   -- Am B A G A
  {61, 66, 68, 0, 66, 68, 70, 0}, -- F C F G・F G A
  {68, 65, 63, 0, 61, 0, 0, 0},   -- G G E D・C
}
local ARP = {
  {49, 52, 56}, {46, 49, 53}, {42, 46, 49}, {44, 48, 51},
  {49, 52, 56}, {46, 49, 53}, {42, 46, 49}, {44, 48, 51},
}
local BASS_ROOT = {25, 34, 30, 32, 25, 34, 30, 32}
local function init_audio()
  init_waveforms()
  -- 游戏音效（显式走 ch0-2，ch4-7 留给音乐）
  write_sfx(0, 1, {{44, 2, 5}, {54, 2, 7}})          -- 拍翅
  write_sfx(1, 1, {{40, 3, 13}, {33, 3, 12}, {26, 14, 11}}) -- 撞击
  write_sfx(2, 3, {{62, 0, 10, 3}, {57, 0, 9, 3}, {50, 0, 8, 3}, {43, 0, 8, 3}}, 4) -- 坠落
  write_sfx(3, 1, {{31, 11, 11}, {24, 11, 8}})       -- 落地闷响
  write_sfx(4, 2, {{33, 15, 6, 4}, {45, 15, 9, 5}})  -- 开局 / 面板滑入
  write_sfx(5, 2, {{61, 8, 10}, {65, 8, 10}, {68, 8, 11}, {73, 8, 12}}) -- 奖牌号角
  write_sfx(6, 2, {{61, 8, 10}, {65, 8, 11}, {68, 8, 11}, {73, 8, 12}, nil,
    {73, 8, 10}, {77, 8, 13}}, 7)                    -- 新纪录
  write_sfx(7, 1, {{72, 10, 5}})                     -- 分数滚动滴答
  for lvl = 0, 7 do -- 过管：音高随分数渐升
    local p = 65 + lvl * 2
    write_sfx(8 + lvl, 1, {{p, 10, 10}, {p + 5, 10, 11}})
  end
  for bar = 0, 7 do
    local mel, arp, bass = {}, {}, {}
    local tri = ARP[bar + 1]
    local patt = {tri[1], tri[2], tri[3], tri[2], tri[1], tri[2], tri[3], tri[2]}
    for i = 1, 8 do
      for _ = 1, 4 do
        mel[#mel + 1] = {MEL[bar + 1][i], 4, 11}
        arp[#arp + 1] = {patt[i], 0, 5}
      end
    end
    local r = BASS_ROOT[bar + 1]
    for _, q in ipairs({r, r + 12, r, r + 12}) do
      for _ = 1, 8 do bass[#bass + 1] = {q, 11, 10} end
    end
    local dr = {} -- 鼓：底鼓 1/3 拍、军鼓 2/4 拍、踩镲反拍
    dr[1], dr[17] = {28, 11, 12, 3}, {28, 11, 12, 3}
    dr[9], dr[25] = {56, 14, 9, 3}, {56, 14, 9, 3}
    for _, hs in ipairs({5, 13, 21, 29}) do dr[hs] = {90, 15, 4} end
    write_sfx(20 + bar, 4, mel, 32)
    write_sfx(32 + bar, 4, arp, 32)
    write_sfx(44 + bar, 4, bass, 32)
    write_sfx(56 + bar, 4, dr, 32)
    -- MUSIC 行（SPEC §5.2：八个 SFX ID，0xFF 为空；LOOP_START/LOOP_BACK 控制回环）
    local mb = MUSIC_BASE + 32 + bar * 32
    for c = 0, 7 do u8(mb + c, 0xFF) end
    u8(mb + 4, 20 + bar) u8(mb + 5, 32 + bar)
    u8(mb + 6, 44 + bar) u8(mb + 7, 56 + bar)
    if bar == 0 then u8(mb + 16, 1) end  -- LOOP_START：循环起点
    if bar == 7 then u8(mb + 17, 1) end  -- LOOP_BACK：回到 LOOP_START
  end
  u8(MUSIC_BASE, 8)  -- 全表 LEN = 8 行
end

-- ---------------------------------------------------------------- 精灵烘焙

-- 逐像素写 16×16 瓦片：fn(x, y) 返回色号或 nil（0＝透明）
local function bake(id, fn)
  local base = id * 256
  for y = 0, 15 do
    for x = 0, 15 do
      poke(base + y * 16 + x, fn(x + 0.5, y + 0.5) or 0)
    end
  end
end
-- 云朵（tile 1）：三团圆隆起，底部压平，下缘淡青阴影
local function bake_sprites()
  bake(1, function(x, y)
    if y < 2.6 or y > 12.4 then return nil end
    local bumps = {{4.6, 10.2, 3.4}, {8.6, 7.6, 4.2}, {12.4, 10.6, 3.1}}
    for _, b in ipairs(bumps) do
      local dx, dy = x - b[1], y - b[2]
      if dx * dx + dy * dy <= b[3] * b[3] then return y >= 10.2 and 8 or 7 end
    end
    return nil
  end)
  -- 大号记分数字（tile 16+d）：5×7 点阵 2 倍放大，白字深色描边
  local DIG = {
    {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},
    {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F},
    {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},
    {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},
    {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E},
    {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},
    {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
  }
  local function dpx(d, gx, gy)
    return bit32.band(DIG[d + 1][gy + 1], bit32.lshift(1, 4 - gx)) ~= 0
  end
  for d = 0, 9 do
    bake(16 + d, function(x, y)
      local function hit(px, py)
        local gx, gy = flr((px - 3) / 2), flr((py - 1) / 2)
        return gx >= 0 and gx <= 4 and gy >= 0 and gy <= 6 and dpx(d, gx, gy)
      end
      if hit(x, y) then return 7 end
      if hit(x - 1, y) or hit(x + 1, y) or hit(x, y - 1) or hit(x, y + 1) then return 1 end
      return nil
    end)
  end
end

-- ---------------------------------------------------------------- 状态

local state, t = "splash", 0 -- splash | title | ready | play | dying | over
local dist = 0              -- 世界卷动距离（像素）
local theme = 1             -- 1 白天 / 2 黄昏 / 3 夜晚
local bird = {y = 150, vy = 0, rot = 0, wph = 0, flap_t = 0}
local pipes                 -- {{x=世界x, gc=缺口中心y, g=缺口高, scored=bool}, ...}
local next_x, last_gc       -- 下一根管道世界 x / 上一个缺口中心（限制跳变）
local score, best, new_best = 0, 0, false
local die_t, land_t, landed = 0, 0, false
local over_t, shown, medal = 0, 0, 0
local shake = 0
local parts, pops = {}, {}
local music_on, bgm_on = true, false
local CITY, CITY_W = {}, 0  -- 城市剪影楼群（固定种子生成，外观稳定）
local BUSH, BUSH_W = {}, 0  -- 灌木丘陵
local CLOUDS = {}           -- 视差云
local STARS = {}            -- 夜晚星点

local function toggle_music()
  music_on = not music_on
  dset(1, music_on and 0 or 1)
  fflush()
  if music_on then music(0, 400, 0xF0) bgm_on = true
  else music(-1, 400) bgm_on = false end
end

-- ---------------------------------------------------------------- 粒子・跳字

local function burst(px, py, cols, n)
  for _ = 1, n do
    parts[#parts + 1] = {
      x = px + rnd(-4, 4), y = py + rnd(-3, 3),
      vx = rnd(-1.6, 1.6), vy = rnd(-2.8, -0.4),
      c = cols[flr(rnd(#cols)) + 1], life = 14 + flr(rnd(14)),
    }
  end
  while #parts > 200 do table.remove(parts, 1) end
end
local function add_pop(txt, x, y, gold)
  pops[#pops + 1] = {txt = txt, x = flr(x - tw(txt) / 2), y = flr(y), t = 0, gold = gold}
end
local function update_parts()
  for i = #parts, 1, -1 do
    local q = parts[i]
    q.x, q.y = q.x + q.vx, q.y + q.vy
    q.vy = q.vy + 0.14
    q.life = q.life - 1
    if q.life <= 0 or q.y > 260 then table.remove(parts, i) end
  end
end
local function update_pops()
  for i = #pops, 1, -1 do
    pops[i].t = pops[i].t + 1
    if pops[i].t > 40 then table.remove(pops, i) end
  end
end

-- ---------------------------------------------------------------- 文本帮手

local function sp(s, x, y, c, sh) -- 带影打印
  print(s, x + 1, y + 1, sh or 1)
  print(s, x, y, c)
end
local function cp(s, y, c, sh) -- 居中带影
  sp(s, flr((256 - tw(s)) / 2), y, c, sh)
end

-- ---------------------------------------------------------------- 场景生成

local function gen_scenery()
  srand(7) -- 固定种子：城市 / 灌木 / 云 / 星外观每次启动一致
  CITY, CITY_W = {}, 0
  for i = 1, 14 do
    local w = 14 + flr(rnd(14))
    CITY[i] = {w = w, h = 18 + flr(rnd(40)), ant = i % 3 == 1}
    CITY_W = CITY_W + w
  end
  BUSH, BUSH_W = {}, 0
  for i = 1, 12 do
    BUSH[i] = {r = 11 + flr(rnd(9))}
    BUSH_W = BUSH_W + 26
  end
  CLOUDS = {}
  for i = 1, 6 do
    CLOUDS[i] = {x = rnd(480), y = 22 + flr(rnd(92)), s = 1 + flr(rnd(3)) * 0.5}
  end
  STARS = {}
  for i = 1, 44 do
    STARS[i] = {x = flr(rnd(256)), y = flr(rnd(150)), ph = flr(rnd(9))}
  end
end

-- ---------------------------------------------------------------- 流程

local function current_gap() return max(GAP_MIN, GAP0 - score * 0.75) end
local function current_speed() return min(SPD_MAX, SPD0 + score * 0.018) end

local function do_flap()
  bird.vy = FLAP_V
  bird.flap_t = 12
  bird.wph = -0.25 -- 扇翅从上向下扫
  sfx(0, 0)
end

local function spawn_pipes()
  while next_x < dist + 300 do
    local g = current_gap()
    local lo, hi = g / 2 + 22, GROUND_Y - g / 2 - 24
    local gc = mid(lo, last_gc + rnd(-72, 72), hi)
    pipes[#pipes + 1] = {x = next_x, gc = gc, g = g, scored = false}
    last_gc = gc
    next_x = next_x + PIPE_DIST
  end
end

local function start_game()
  srand(t * 31 + 7) -- 每局确定性随机：天色与缺口序列跟随输入历史
  theme = flr(rnd(3)) + 1
  score, new_best, medal, shown = 0, false, 0, 0
  bird = {y = 112, vy = 0, rot = 0, wph = 0, flap_t = 0}
  pipes, next_x, last_gc = {}, dist + 240, 116
  die_t, land_t, landed, over_t, shake = 0, 0, false, 0, 0
  parts, pops = {}, {}
  state = "ready"
  sfx(4, 0)
  if music_on and not bgm_on then music(0, 500, 0xF0) bgm_on = true end
end

local function to_title()
  state = "title"
  theme = 1
  bird = {y = 128, vy = 0, rot = 0, wph = 0, flap_t = 0}
  pipes, parts, pops = {}, {}, {}
  if music_on and not bgm_on then music(0, 500, 0xF0) bgm_on = true end
end

local function die(on_ground)
  state, die_t, land_t = "dying", 0, 0
  shake = on_ground and 5 or 9
  if bgm_on then music(-1, 250) bgm_on = false end
  sfx(1, 0)
  if on_ground then
    bird.y, bird.vy, bird.rot, landed = GROUND_Y - 5, 0, 0.26, true
    burst(BIRD_X, GROUND_Y - 3, {23, 22, 18}, 12)
  else
    landed = false
    bird.vy = -2.4
    burst(BIRD_X, bird.y, {29, 30, 7, 31}, 10) -- 羽毛四散
  end
  if score > best then
    best, new_best = score, true
    dset(0, best)
    fflush()
  end
end

local function enter_over()
  state, over_t, shown = "over", 0, 0
  medal = score >= 40 and 4 or score >= 30 and 3 or score >= 20 and 2 or score >= 10 and 1 or 0
end

-- ---------------------------------------------------------------- 更新

local function update_title()
  dist = dist + 0.6
  bird.y = 128 + sin(t * 0.05) * 5
  bird.rot = sin(t * 0.05 + 0.3) * 0.04
  bird.wph = bird.wph + 0.12
  if btnp(4) or btnp(5) or dirp(0) or dirp(1) or dirp(2) or dirp(3) then start_game() return end
end

local function update_ready()
  dist = dist + 1.2
  bird.y = 112 + sin(t * 0.09) * 5
  bird.rot = sin(t * 0.09 + 0.25) * 0.03
  bird.wph = bird.wph + 0.14
  if btnp(4) or btnp(5) or dirp(0) or dirp(1) or dirp(2) or dirp(3) then state = "play" do_flap() return end
end

-- 小鸟圆 vs 轴对齐矩形
local function hit_rect(rx, ry, rw, rh)
  local nx, ny = mid(rx, BIRD_X, rx + rw), mid(ry, bird.y, ry + rh)
  local dx, dy = BIRD_X - nx, bird.y - ny
  return dx * dx + dy * dy < BIRD_R * BIRD_R
end

local function update_play()
  if btnp(4) or btnp(5) or dirp(0) or dirp(1) or dirp(2) or dirp(3) then do_flap() end
  -- 物理：重力、限速、上缘只挡不死
  bird.vy = min(bird.vy + GRAV, MAX_FALL)
  bird.y = bird.y + bird.vy
  if bird.y < 9 then bird.y = 9 bird.vy = max(bird.vy, 0) end
  -- 倾角：上冲微仰，下坠渐俯（平滑趋近）
  local target = bird.vy < 0 and -0.07 or min(0.26, bird.vy * 0.055)
  bird.rot = bird.rot + (target - bird.rot) * 0.15
  -- 扇翅相位：拍翅后快扇，平时慢扇
  bird.flap_t = max(0, bird.flap_t - 1)
  bird.wph = bird.wph + (bird.flap_t > 0 and 0.38 or 0.13)
  -- 卷动与管道
  dist = dist + current_speed()
  spawn_pipes()
  for i = #pipes, 1, -1 do
    local p = pipes[i]
    local sx = p.x - dist
    if sx < -48 then
      table.remove(pipes, i)
    elseif not p.scored and sx + PIPE_W < BIRD_X then
      p.scored = true
      score = score + 1
      sfx(8 + min(score - 1, 7), 1)
      add_pop("+1", BIRD_X, bird.y - 18, false)
      if best > 0 and score > best and not new_best then
        new_best = true
        add_pop("新纪录", 128, 44, true)
      end
    end
  end
  -- 碰撞：地面 / 管道（碰撞矩形各内缩 1px）
  if bird.y + BIRD_R >= GROUND_Y then return die(true) end
  for i = 1, #pipes do
    local p = pipes[i]
    local sx = p.x - dist
    if sx < BIRD_X + BIRD_R and sx + PIPE_W > BIRD_X - BIRD_R then
      local topH = p.gc - p.g / 2
      local botY = p.gc + p.g / 2
      if hit_rect(sx + 1, -512, PIPE_W - 2, topH + 512)
        or hit_rect(sx + 1, botY, PIPE_W - 2, GROUND_Y - botY) then
        return die(false)
      end
    end
  end
end

-- 坠落演出：旋转俯冲 → 落地扬尘 → 短暂停留进结算
local function update_dying()
  die_t = die_t + 1
  if not landed then
    bird.vy = min(bird.vy + GRAV * 1.4, 6.5)
    bird.y = bird.y + bird.vy
    bird.rot = min(bird.rot + 0.018, 0.26)
    if bird.y >= GROUND_Y - 5 then
      bird.y, bird.vy, landed, land_t = GROUND_Y - 5, 0, true, die_t
      shake = max(shake, 4)
      sfx(3, 0)
      burst(BIRD_X, GROUND_Y - 3, {23, 22, 18}, 14)
    end
  end
  if landed and die_t - land_t > 26 then enter_over() end
end

local function update_over()
  over_t = over_t + 1
  if over_t == 22 then sfx(4, 1) end                  -- 面板滑入到底
  if over_t == 30 and medal > 0 then sfx(5, 1) end    -- 奖牌号角
  if over_t == 46 and new_best then sfx(6, 1) end     -- 新纪录旋律
  if over_t > 26 and shown < score then               -- 分数滚动
    shown = min(score, shown + max(1, flr(score / 32)))
    if over_t % 2 == 0 then sfx(7, 2) end
  end
  if over_t > 48 then
    if btnp(4) or btnp(5) then start_game()
    elseif btnp(11) then to_title() end
  end
end

-- ---------------------------------------------------------------- 绘制・世界

local function skyc(y) -- 天空渐带取色（黄昏落日条纹用）
  local g = THEMES[theme]
  if y < 64 then return g.sky[1] elseif y < 128 then return g.sky[2]
  elseif y < 186 then return g.sky[3] else return g.sky[4] end
end

local function draw_sky()
  local g = THEMES[theme]
  rectfill(0, 0, 256, 64, g.sky[1])
  rectfill(0, 64, 256, 64, g.sky[2])
  rectfill(0, 128, 256, 58, g.sky[3])
  rectfill(0, 186, 256, GROUND_Y - 186, g.sky[4])
end

local function draw_celestial()
  if theme == 1 then -- 白天：高悬暖阳
    circfill(208, 42, 16, 30)
    circfill(208, 42, 11, 31)
  elseif theme == 2 then -- 黄昏：下沉条纹落日
    circfill(56, 176, 24, 30)
    circfill(56, 176, 19, 31)
    rectfill(30, 170, 52, 3, skyc(171))
    rectfill(30, 178, 52, 4, skyc(180))
    rectfill(30, 187, 52, 6, skyc(190))
  else -- 夜晚：满月 + 闪烁星
    circfill(198, 46, 14, 7)
    circfill(193, 41, 3, 8)
    circfill(202, 51, 2, 8)
    circfill(203, 40, 1.5, 8)
    for i = 1, #STARS do
      local st = STARS[i]
      if (flr(t / 5) + st.ph) % 9 ~= 0 then
        pset(st.x, st.y, (st.ph + flr(t / 40)) % 5 == 0 and 44 or 7)
      end
    end
  end
end

local function draw_clouds()
  local g = THEMES[theme]
  pal(7, g.cloud)    -- 云朵精灵按天色着色（显示期不动幀缓冲）
  pal(8, g.cloudsh)
  for i = 1, #CLOUDS do
    local c = CLOUDS[i]
    local sx = (c.x - flr(dist * 0.2)) % 480 - 48 -- 远层云：0.2 系数最慢
    sspr(16, 0, 16, 16, sx, c.y, 16 * c.s, 16 * c.s)
  end
  pal()
end

local function draw_city()
  local g = THEMES[theme]
  local off = flr(dist * 0.35) % CITY_W -- 中景城市：0.35 系数，慢于灌木快于云
  local x, i = -off, 1
  while x < 256 do
    local b = CITY[(i - 1) % #CITY + 1]
    rectfill(x, GROUND_Y - b.h, b.w, b.h, g.city)
    if b.ant then -- 楼顶天线
      local ax = x + flr(b.w / 2)
      line(ax, GROUND_Y - b.h - 8, ax, GROUND_Y - b.h, g.city)
      pset(ax, GROUND_Y - b.h - 9, g.city)
    end
    if g.win then -- 黄昏 / 夜晚点灯（位置散列决定，不耗随机序列）
      for wy = GROUND_Y - b.h + 5, GROUND_Y - 8, 8 do
        for wx = x + 3, x + b.w - 4, 6 do
          if (wx * 7 + wy * 13) % 5 < 2 then pset(wx, wy, g.win) end
        end
      end
    end
    x, i = x + b.w, i + 1
  end
end

local function draw_bushes()
  local g = THEMES[theme]
  local off = flr(dist * 0.55) % BUSH_W -- 近层丘陵：0.55 系数，视差最快的一层
  local x, i = -off, 1
  while x < 286 do -- 后排高丘
    local b = BUSH[(i - 1) % #BUSH + 1]
    circfill(x, GROUND_Y + 8, b.r + 5, g.hillb)
    x, i = x + 26, i + 1
  end
  x, i = -off - 13, 1
  while x < 286 do -- 前排矮丘
    local b = BUSH[(i - 1) % #BUSH + 1]
    circfill(x, GROUND_Y + 10, b.r, g.hillf)
    x, i = x + 26, i + 1
  end
end

local function draw_pipe_pair(sx, p)
  local topH = flr(p.gc - p.g / 2)
  local botY = flr(p.gc + p.g / 2)
  -- 上管：管身 + 左亮右暗 + 管口
  rectfill(sx, 0, PIPE_W, topH, 35)
  rectfill(sx + 3, 0, 5, topH, 33)
  rectfill(sx + PIPE_W - 7, 0, 4, topH, 36)
  rect(sx, 0, PIPE_W, topH, 13)
  rectfill(sx - 3, topH - 11, PIPE_W + 6, 11, 34)
  rectfill(sx - 3, topH - 11, PIPE_W + 6, 2, 32)
  rectfill(sx + 2, topH - 8, 4, 6, 33)
  rectfill(sx + PIPE_W - 7, topH - 8, 4, 6, 36)
  rect(sx - 3, topH - 11, PIPE_W + 6, 11, 13)
  -- 下管：镜像
  rectfill(sx, botY, PIPE_W, GROUND_Y - botY, 35)
  rectfill(sx + 3, botY, 5, GROUND_Y - botY, 33)
  rectfill(sx + PIPE_W - 7, botY, 4, GROUND_Y - botY, 36)
  rect(sx, botY, PIPE_W, GROUND_Y - botY, 13)
  rectfill(sx - 3, botY, PIPE_W + 6, 11, 34)
  rectfill(sx - 3, botY, PIPE_W + 6, 2, 32)
  rectfill(sx + 2, botY + 2, 4, 6, 33)
  rectfill(sx + PIPE_W - 7, botY + 2, 4, 6, 36)
  rect(sx - 3, botY, PIPE_W + 6, 11, 13)
end

local function draw_pipes()
  for i = 1, #pipes do
    local sx = flr(pipes[i].x - dist)
    if sx < 260 and sx + PIPE_W > -4 then draw_pipe_pair(sx, pipes[i]) end
  end
end

local function draw_ground()
  local g = THEMES[theme]
  rectfill(0, GROUND_Y, 256, 256 - GROUND_Y, g.dirt)
  rectfill(0, GROUND_Y, 256, 6, g.grass)
  local off = flr(dist) % 12
  for x = -12 - off, 256, 12 do -- 草沿斜纹（随世界全速滚动）
    trifill(x, GROUND_Y, x + 6, GROUND_Y, x - 3, GROUND_Y + 6, g.grassst)
  end
  line(0, GROUND_Y, 255, GROUND_Y, g.edge)
  local off2 = flr(dist) % 16
  for x = -16 - off2, 256, 16 do -- 土层斜纹
    trifill(x, 240, x + 9, 240, x - 3, 250, g.dirtst)
  end
  rectfill(0, 250, 256, 6, g.dirtbot)
end

local function draw_world()
  draw_sky()
  draw_celestial()
  draw_clouds()
  draw_city()
  draw_bushes()
  draw_pipes()
  draw_ground()
end

-- ---------------------------------------------------------------- 绘制・小鸟

-- 小鸟 = 圆身 + 三角翅 / 嘴组合，整体随倾角旋转（圈制，确定性）
local function draw_bird(bx, by, rot, wph, dead)
  local c, s = cos(rot), sin(rot)
  local function R(lx, ly) return bx + lx * c - ly * s, by + lx * s + ly * c end
  local lift = dead and -2.5 or sin(wph) * 4.2 -- 死亡翅膀下垂
  circfill(bx, by, 6.8, 25) -- 描边
  circfill(bx, by, 6, 29)   -- 身体
  local ax, ay = R(-1.2, 2.6)
  ovalfill(ax, ay, 3.6, 2.4, 31) -- 腹部
  ax, ay = R(0.8, -3.4)
  ovalfill(ax, ay, 3, 1.4, 30)   -- 顶部高光
  local x1, y1 = R(-1, -0.5)
  local x2, y2 = R(-7, 1)
  local x3, y3 = R(-3.6, -0.5 - lift)
  trifill(x1, y1, x2, y2, x3, y3, 28) -- 翅膀
  ax, ay = R(2.8, -2.6)
  circfill(ax, ay, 2.3, 7) -- 眼白
  ax, ay = R(3.7, -2.7)
  circfill(ax, ay, 1.1, 1) -- 瞳孔
  local b1x, b1y = R(3.6, -1.4)
  local b2x, b2y = R(9.6, -0.6)
  local b3x, b3y = R(3.8, 2.8)
  trifill(b1x, b1y, b2x, b2y, b3x, b3y, 26) -- 嘴描边
  b1x, b1y = R(4, -0.8) b2x, b2y = R(9, -0.6) b3x, b3y = R(4.2, 0.8)
  trifill(b1x, b1y, b2x, b2y, b3x, b3y, 27) -- 上喙
  b1x, b1y = R(4, 0.4) b2x, b2y = R(8.4, 0.9) b3x, b3y = R(4.2, 2)
  trifill(b1x, b1y, b2x, b2y, b3x, b3y, 24) -- 下喙
end

local function draw_shadow() -- 地面投影：越近地面越大越实
  if state == "title" then return end
  local g = THEMES[theme]
  local k = mid(0, (bird.y - 120) / 110, 1)
  ovalfill(BIRD_X, GROUND_Y + 4, 3 + 4 * k, 1 + 1.5 * k, g.dirtbot)
end

-- ---------------------------------------------------------------- 绘制・UI

local function digits_w(n) return #tostring(n) * 13 - 3 end
local function draw_digits(n, x, y)
  local s = tostring(n)
  for i = 1, #s do
    sspr((s:byte(i) - 48) * 16, 16, 16, 16, x + (i - 1) * 13, y)
  end
end

local function draw_parts()
  for i = 1, #parts do
    rectfill(flr(parts[i].x), flr(parts[i].y), 2, 2, parts[i].c)
  end
end
local function draw_pops()
  for i = 1, #pops do
    local p = pops[i]
    local y = flr(p.y - p.t * 0.7)
    print(p.txt, p.x + 1, y + 1, 1)
    print(p.txt, p.x, y, p.gold and (p.t < 16 and 31 or 30) or (p.t < 24 and 7 or 6))
  end
end

local function draw_music_mark()
  if music_on then
    print("♪", 243, 4, 1)
    print("♪", 242, 3, 30)
  end
end

local function draw_title()
  draw_bird(128, bird.y, bird.rot, bird.wph, false)
  rrectfill(58, 26, 140, 64, 6, 8) -- 匾额
  rectfill(64, 29, 128, 2, 7)
  rectfill(64, 85, 128, 2, 10)
  rrect(58, 26, 140, 64, 6, 12)
  local chars, cols = {"弹", "跳", "鸟"}, {31, 30, 29}
  for i = 1, 3 do
    local x, y = 92 + (i - 1) * 30, 36 + flr(sin(t * 0.05 + i * 0.16) * 3)
    print(chars[i], x + 2, y + 2, 12)
    print(chars[i], x, y, cols[i])
  end
  cp("FLAPPY BIRD", 66, 12)
  cp("最高纪录 " .. best, 150, 31)
  -- 开始提示稳定不闪烁（封面取第 30 帧），操作说明不上标题
  cp("按 " .. btnicon("a") .. " 开始", 200, 7)
  cp("FrostMiKu ・ FC-16", 239, 7, 17)
end

-- 大号小鸟（draw_bird 的 0 旋角放大版，s 为倍率，扇翅随 wph 摆动）
local function big_bird(bx, by, s, wph)
  local lift = sin(wph) * 4.2 * s / 6
  circfill(bx, by, 6.8 * s, 25) -- 描边
  circfill(bx, by, 6 * s, 29)   -- 身体
  ovalfill(bx - 1.2 * s, by + 2.6 * s, 3.6 * s, 2.4 * s, 31) -- 腹部
  ovalfill(bx + 0.8 * s, by - 3.4 * s, 3 * s, 1.4 * s, 30)   -- 顶部高光
  trifill(bx - 1 * s, by - 0.5 * s, bx - 7 * s, by + 1 * s,
    bx - 3.6 * s, by - 0.5 * s - lift, 28)                   -- 翅膀
  circfill(bx + 2.8 * s, by - 2.6 * s, 2.3 * s, 7)           -- 眼白
  circfill(bx + 3.7 * s, by - 2.7 * s, 1.1 * s, 1)           -- 瞳孔
  trifill(bx + 3.6 * s, by - 1.4 * s, bx + 9.6 * s, by - 0.6 * s,
    bx + 3.8 * s, by + 2.8 * s, 26)                          -- 嘴描边
  trifill(bx + 4 * s, by - 0.8 * s, bx + 9 * s, by - 0.6 * s,
    bx + 4.2 * s, by + 0.8 * s, 27)                          -- 上喙
  trifill(bx + 4 * s, by + 0.4 * s, bx + 8.4 * s, by + 0.9 * s,
    bx + 4.2 * s, by + 2 * s, 24)                            -- 下喙
end

-- 放大管道对（k 为倍率：管身 / 亮暗棱 / 管口同比例缩放）
local function draw_pipe_big(sx, topH, botY, k)
  local w, rh = flr(PIPE_W * k), flr(11 * k)
  rectfill(sx, -4, w, topH + 4, 35)
  rectfill(sx + flr(3 * k), -4, flr(5 * k), topH + 4, 33)
  rectfill(sx + w - flr(7 * k), -4, flr(4 * k), topH + 4, 36)
  rect(sx, -4, w, topH + 4, 13)
  rectfill(sx - flr(3 * k), topH - rh, w + flr(6 * k), rh, 34)
  rectfill(sx - flr(3 * k), topH - rh, w + flr(6 * k), 2, 32)
  rect(sx - flr(3 * k), topH - rh, w + flr(6 * k), rh, 13)
  rectfill(sx, botY, w, GROUND_Y - botY + 4, 35)
  rectfill(sx + flr(3 * k), botY, flr(5 * k), GROUND_Y - botY + 4, 33)
  rectfill(sx + w - flr(7 * k), botY, flr(4 * k), GROUND_Y - botY + 4, 36)
  rect(sx, botY, w, GROUND_Y - botY + 4, 13)
  rectfill(sx - flr(3 * k), botY, w + flr(6 * k), rh, 34)
  rectfill(sx - flr(3 * k), botY, w + flr(6 * k), 2, 32)
  rect(sx - flr(3 * k), botY, w + flr(6 * k), rh, 13)
end

-- Splash：纯主视觉封面（0-90 帧）——大鸟穿过两根管道间隙的特写构图，
-- 大 logo 挂匾放下方；零菜单零提示零纪录（Ⓐ/Menu 可跳过，90 帧后进交互菜单）
local function draw_splash()
  draw_world()
  -- 放大管道对：缺口居中偏上，大鸟正穿行其间
  draw_pipe_big(88, 88, 152, 2.5)
  -- 掠过的风线（装饰可动）
  for i = 0, 2 do
    local ly = 112 + i * 14
    line(34 + (i % 2) * 8, ly, 62 + (i % 2) * 10, ly, 7)
  end
  big_bird(122, 120, 3.2, t * 0.15)
  -- 大 logo 匾额（沿用标题匾样式）
  rrectfill(44, 172, 168, 60, 8, 8)
  rectfill(50, 175, 156, 2, 7)
  rectfill(50, 227, 156, 2, 10)
  rrect(44, 172, 168, 60, 8, 12)
  local chars, cols = { "弹", "跳", "鸟" }, { 31, 30, 29 }
  for i = 1, 3 do
    local x = 66 + (i - 1) * 44
    print(chars[i], x + 3, 181, 12, 4)
    print(chars[i], x, 178, cols[i], 4)
  end
  cp("FLAPPY BIRD", 236, 7)
end

local function draw_ready_ui()
  local g = THEMES[theme]
  sp(g.name, 4, 3, 7)
  draw_music_mark()
  if flr(t / 18) % 2 == 0 then cp("按 " .. btnicon("a") .. " 起飞", 161, 7) end
  cp(btnicon("a") .. btnicon("b") .. " " .. btnicon("dpad") .. " 拍翅", 188, 7)
  cp("最高 " .. best, 213, 31)
end

local function draw_over_ui()
  local k = min(1, over_t / 22)
  k = 1 - (1 - k) * (1 - k)                       -- easeOut 二次
  local py = flr(64 + (256 - 64) * (1 - k))       -- 自底部滑入至 64
  local rec = new_best and flr(t / 8) % 2 == 0
  cp(rec and "★ 新纪录 ★" or "游戏结束", 32, rec and 31 or 7)
  rrectfill(48, py, 160, 132, 8, 22)              -- 面板
  rectfill(52, py + 2, 152, 2, 21)
  rectfill(52, py + 128, 152, 2, 20)
  rrect(48, py, 160, 132, 8, 17)
  print("奖牌", 72, py + 12, 17)
  local mx, my = 88, py + 66
  if medal > 0 then
    local m = MEDALS[medal]
    circfill(mx, my, 17, m[2])
    circfill(mx, my, 13, m[1])
    print("★", mx - 8, my - 8, m[2])
    for s2 = 0, 1 do -- 游走闪光
      local a = (t * 0.02 + s2 * 0.5) % 1
      local sx2, sy2 = mx + cos(a) * 15, my + sin(a) * 12
      line(sx2 - 2, sy2, sx2 + 2, sy2, 7)
      line(sx2, sy2 - 2, sx2, sy2 + 2, 7)
    end
    print(m[3], flr(mx - tw(m[3]) / 2), py + 90, m[2])
  else
    circfill(mx, my, 17, 21)
    circfill(mx, my, 13, 22)
    print("无", mx - 8, my - 8, 18)
  end
  print("分数", 144, py + 12, 17)
  draw_digits(shown, flr(160 - digits_w(shown) / 2), py + 30)
  print("最高", 144, py + 62, 17)
  draw_digits(best, flr(160 - digits_w(best) / 2), py + 80)
  if over_t > 48 then
    if flr(t / 16) % 2 == 0 then cp(btnicon("a") .. " 再来一局", 208, 7) end
    cp(btnicon("menu") .. " 回标题", 225, 6)
  end
end

-- ---------------------------------------------------------------- 生命周期

function _init()
  bake_sprites()
  init_audio()
  gen_scenery()
  music_on = dget(1) == 0 -- 槽位 1：0 = 开（默认）
  best = flr(dget(0)) -- dget 为 32 位定点，取整保证显示与数字精灵索引正确
  to_title()
  state = "splash" -- 开机封面段：90 帧后回落交互菜单
end

function _update()
  t = t + 1
  update_parts()
  update_pops()
  if shake > 0 then shake = shake - 1 end
  if btnp(10) then toggle_music() end
  if state == "splash" then
    if t > 90 or btnp(4) or btnp(5) or btnp(11) then state = "title" end
  elseif state == "title" then update_title()
  elseif state == "ready" then update_ready()
  elseif state == "play" then update_play()
  elseif state == "dying" then update_dying()
  elseif state == "over" then update_over() end
end

function _draw()
  pal()
  cls(0)
  if shake > 0 then -- 撞击震屏（与幀号绑定，确定性）
    camera(flr(sin(t * 0.9) * min(3, shake * 0.5)), flr(cos(t * 1.3) * min(2, shake * 0.4)))
  end
  if state == "splash" then
    draw_splash()
    camera(0, 0)
    return
  end
  draw_world()
  if state == "title" then
    draw_title()
    camera(0, 0)
    return
  end
  draw_shadow()
  draw_bird(BIRD_X, bird.y, bird.rot, bird.wph, state ~= "play" and state ~= "ready")
  draw_parts()
  draw_pops()
  if state ~= "over" or over_t < 22 then -- 结算面板滑入后隐藏顶部大分数
    draw_digits(score, flr((256 - digits_w(score)) / 2), 10)
  end
  if state == "play" or state == "dying" then draw_music_mark() end
  camera(0, 0)
  if state == "ready" then draw_ready_ui() end
  if state == "over" then draw_over_ui() end
  if state == "dying" and die_t < 5 then -- 撞击白闪：显示期整体映射（幀缓冲不变）
    for i = 0, 63 do pal(i, 7, 1) end
  end
end
