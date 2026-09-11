-- 愤怒的小鸟（FC-16 demo 卡带）
-- 弹弓物理破坏：拉弓发射小鸟，用撞击冲量拆毁木/石/冰结构，消灭所有猪即可过关。
-- 美术与音乐均为原创致敬风格；物理使用 SPEC §10 内置确定性 2D 物理（AABB+圆）。
--
-- 操作：
--   Ⓐ 按住拉弓，方向键调角度与力度，松开 Ⓐ 发射；Ⓑ 取消拉弓
--   Menu 菜单（继续/重开/选关）　View 音乐开关
--   结算画面：Ⓐ 下一关（失败时重试），Menu 返回选关
--
-- 伤害模型：撞击冲量 = 接近速度 × 有效质量（动碰静取自身质量，动碰动取约化质量）；
-- 超过材料耐久即破坏。速度快照在物理步进前采集（回调读到的是求解后速度）。

-- ================================================================ 常量

local GROUND_Y = 224           -- 地表顶部 y
local FORK_X, FORK_Y = 44, 170 -- 弹弓皮兜静止点
local BIRD_R = 6               -- 小鸟碰撞半径
local PIG_R = 5                -- 小猪碰撞半径
local V_MIN, V_MAX = 140, 430  -- 发射速度区间（px/s）；默认力度恰打在场中结构上
local DEF_ANG, DEF_POW = 45, 0.3
local IMPACT_MIN = 60          -- 低于该接近速度不产生伤害（px/s）
local PIG_SCORE = 5000
local BIRD_BONUS = 10000       -- 过关时每只剩余鸟的奖励分
local TNT_R = 54               -- 炸药桶爆炸半径

-- 材料：1 木 2 石 3 冰（mf 为质量因子，作用于默认面积质量）
local MAT = {
  { name = "木", hp = 100, mf = 1.0, fric = 6, rest = 0.08, score = 500,
    deb = { 19, 18, 17 }, hit_sfx = 2, brk_sfx = 5 },
  { name = "石", hp = 260, mf = 2.2, fric = 6, rest = 0.04, score = 800,
    deb = { 5, 4, 3 }, hit_sfx = 3, brk_sfx = 6 },
  { name = "冰", hp = 45, mf = 0.5, fric = 1, rest = 0.02, score = 300,
    deb = { 43, 44, 42 }, hit_sfx = 4, brk_sfx = 7 },
}

-- ================================================================ 关卡（表驱动）
-- bl 方块 {x, y, w, h, 材质}（x,y 为中心，支撑面 224）
-- pg 小猪 {x, y}　tn 炸药桶 {x, y}
-- th 三星分数阈值

local LV = {
  { name = "简单小屋", birds = 3, th = { 5000, 13000, 19000 },
    bl = {
      { 116, 208, 8, 32, 1 }, { 140, 208, 8, 32, 1 }, { 128, 188, 32, 8, 1 },
    },
    pg = { { 128, 219 } }, tn = {} },
  { name = "冰雪别墅", birds = 3, th = { 10000, 16000, 23000 },
    bl = {
      { 146, 208, 8, 32, 3 }, { 174, 208, 8, 32, 3 }, { 160, 188, 40, 8, 3 },
      { 204, 216, 16, 16, 1 },
    },
    pg = { { 160, 219 }, { 204, 203 } }, tn = {} },
  { name = "双层木塔", birds = 3, th = { 15000, 22000, 30000 },
    bl = {
      { 136, 208, 8, 32, 1 }, { 168, 208, 8, 32, 1 }, { 152, 188, 48, 8, 1 },
      { 136, 168, 8, 32, 1 }, { 168, 168, 8, 32, 1 }, { 152, 148, 48, 8, 1 },
    },
    pg = { { 152, 219 }, { 152, 179 }, { 152, 139 } }, tn = {} },
  { name = "石木碉堡", birds = 4, th = { 15000, 25000, 36000 },
    bl = {
      { 104, 216, 16, 16, 3 }, { 104, 200, 16, 16, 3 },
      { 136, 208, 8, 32, 2 }, { 164, 208, 8, 32, 2 }, { 150, 188, 44, 8, 2 },
      { 136, 168, 8, 32, 1 }, { 164, 168, 8, 32, 1 }, { 150, 148, 44, 8, 1 },
    },
    pg = { { 150, 219 }, { 150, 179 }, { 214, 219 } }, tn = { { 192, 216 } } },
  { name = "双塔一桥", birds = 4, th = { 15000, 25000, 36000 },
    bl = {
      { 112, 208, 8, 32, 1 }, { 128, 208, 8, 32, 1 }, { 120, 188, 24, 8, 1 },
      { 176, 208, 8, 32, 1 }, { 192, 208, 8, 32, 1 }, { 184, 188, 24, 8, 1 },
      { 152, 180, 48, 8, 1 },
    },
    pg = { { 152, 219 }, { 152, 171 }, { 224, 219 } }, tn = { { 210, 216 } } },
  { name = "冰雪要塞", birds = 4, th = { 20000, 30000, 41000 },
    bl = {
      { 146, 208, 8, 32, 3 }, { 182, 208, 8, 32, 3 }, { 164, 188, 48, 8, 3 },
      { 156, 172, 16, 16, 2 }, { 172, 172, 16, 16, 2 },
    },
    pg = { { 156, 219 }, { 164, 159 }, { 216, 219 } }, tn = { { 170, 216 } } },
  { name = "三层高塔", birds = 4, th = { 20000, 31000, 42000 },
    bl = {
      { 118, 216, 16, 16, 3 }, { 118, 200, 16, 16, 3 },
      { 154, 208, 8, 32, 1 }, { 186, 208, 8, 32, 1 }, { 170, 188, 48, 8, 1 },
      { 154, 168, 8, 32, 1 }, { 186, 168, 8, 32, 1 }, { 170, 148, 48, 8, 1 },
      { 154, 128, 8, 32, 3 }, { 186, 128, 8, 32, 3 }, { 170, 108, 48, 8, 1 },
    },
    pg = { { 170, 219 }, { 170, 179 }, { 170, 139 }, { 170, 99 } }, tn = {} },
  { name = "石头地堡", birds = 5, th = { 15000, 28000, 40000 },
    bl = {
      { 158, 208, 8, 32, 2 }, { 194, 208, 8, 32, 2 }, { 176, 188, 48, 8, 2 },
      { 160, 172, 16, 16, 2 }, { 192, 172, 16, 16, 2 }, { 176, 160, 48, 8, 2 },
    },
    pg = { { 167, 219 }, { 176, 151 }, { 234, 219 } },
    tn = { { 181, 216 }, { 138, 216 }, { 214, 216 } } },
  { name = "左右开弓", birds = 4, th = { 20000, 30000, 42000 },
    bl = {
      { 108, 208, 8, 32, 3 }, { 132, 208, 8, 32, 3 }, { 120, 188, 32, 8, 3 },
      { 192, 208, 8, 32, 2 }, { 216, 208, 8, 32, 2 }, { 204, 188, 32, 8, 2 },
    },
    pg = { { 120, 219 }, { 120, 179 }, { 204, 219 }, { 246, 219 } },
    tn = { { 232, 216 } } },
  { name = "猪猪城堡", birds = 5, th = { 25000, 40000, 55000 },
    bl = {
      { 140, 216, 16, 16, 2 }, { 140, 200, 16, 16, 2 }, { 140, 184, 16, 16, 2 },
      { 212, 216, 16, 16, 2 }, { 212, 200, 16, 16, 2 }, { 212, 184, 16, 16, 2 },
      { 160, 208, 8, 32, 1 }, { 192, 208, 8, 32, 1 }, { 176, 188, 48, 8, 1 },
      { 160, 168, 8, 32, 1 }, { 192, 168, 8, 32, 1 }, { 176, 148, 48, 8, 1 },
      { 160, 128, 8, 32, 3 }, { 192, 128, 8, 32, 3 }, { 176, 108, 48, 8, 1 },
    },
    pg = { { 176, 219 }, { 176, 179 }, { 176, 139 }, { 176, 99 }, { 140, 171 } },
    tn = { { 118, 216 }, { 242, 216 } } },
}

local NLEVEL = #LV

local HINTS = {
  "Ⓐ 按住拉弓　方向键调角度与力度",
  "松开 Ⓐ 发射　Ⓑ 取消",
  "Menu 菜单　View 音乐开关",
}

-- ================================================================ 音频（SPEC §5.2）

local function u8(a, val) poke(a, val % 256) end

local function init_sfx(id, notes, wave, vol, spd, lps)
  local base = 0x060000 + id * 112
  u8(base, spd or 2)
  u8(base + 1, #notes)
  if lps then u8(base + 2, lps) u8(base + 3, #notes) u8(base + 4, 1) end
  for i = 0, 31 do
    local a = base + 16 + i * 3
    if i < #notes then
      u8(a, notes[i + 1])
      u8(a + 1, wave * 16 + vol)
      u8(a + 2, 0)
    else
      u8(a, 0) u8(a + 1, 0)
    end
  end
end

-- 一条旋律按小节序列拆成多条 SFX（每条 32 步）
local function expand(notes, n)
  local out = {}
  for _, val in ipairs(notes) do
    for _ = 1, n do out[#out + 1] = val end
  end
  return out
end

local function init_audio()
  -- 0 拉弓吱呀 1 发射嗖 2/3/4 木石冰撞击 5/6/7 木石冰破碎
  -- 8 猪 popped 9 爆炸 10 过关 11 失败 12 界面 13 星星 14 小鸟就位
  init_sfx(0, { 49, 52 }, 3, 6, 1)
  init_sfx(1, { 80, 74, 68, 62 }, 14, 12, 1)
  init_sfx(2, { 33, 30 }, 3, 10, 1)
  init_sfx(3, { 26, 23 }, 2, 11, 1)
  init_sfx(4, { 76, 73 }, 10, 8, 1)
  init_sfx(5, { 45, 40, 35 }, 15, 12, 1)
  init_sfx(6, { 28, 24, 20 }, 14, 13, 1)
  init_sfx(7, { 82, 79, 76, 72 }, 15, 10, 1)
  init_sfx(8, { 65, 60, 54, 49 }, 4, 12, 1)
  init_sfx(9, { 22, 18, 14 }, 14, 15, 2)
  init_sfx(10, { 60, 64, 67, 72, 76, 79 }, 6, 12, 3)
  init_sfx(11, { 50, 46, 42, 37 }, 11, 11, 4)
  init_sfx(12, { 70, 77 }, 5, 8, 1)
  init_sfx(13, { 84, 89 }, 10, 9, 1)
  init_sfx(14, { 88, 83 }, 4, 7, 1)

  -- BGM：C 大调轻快小曲（旋律/琶音/贝斯三条声部，ch4-6）
  local mel = {
    { 65, 68, 70, 68, 65, 61, 63, 65 },
    { 63, 66, 68, 66, 63, 59, 61, 63 },
    { 65, 68, 70, 68, 65, 61, 63, 65 },
    { 68, 66, 65, 63, 61, 61, 61, 61 },
  }
  local bass = { { 37, 44 }, { 42, 49 }, { 37, 44 }, { 32, 39 } }
  local arp = {
    { 52, 56, 61, 56 }, { 54, 58, 63, 58 },
    { 52, 56, 61, 56 }, { 50, 54, 59, 54 },
  }
  for bar = 1, 4 do
    init_sfx(19 + bar, expand(mel[bar], 4), 8, 10, 4)
    init_sfx(29 + bar, expand(arp[bar], 8), 0, 5, 4)
    init_sfx(39 + bar, expand(bass[bar], 16), 11, 10, 4)
  end
  for bar = 1, 4 do
    local mb = 0x063800 + (bar - 1) * 16
    u8(mb + 4, 20 + bar)
    u8(mb + 5, 30 + bar)
    u8(mb + 6, 40 + bar)
    u8(mb + 8, bar == 1 and 1 or (bar == 4 and 2 or 0))
  end
end

-- ================================================================ 精灵烘焙

-- 逐像素写 16×16 瓦片：fn(x, y) 返回色号或 nil（透明）
local function bake(id, fn)
  local base = id * 256
  for y = 0, 15 do
    for x = 0, 15 do
      local c = fn(x + 0.5, y + 0.5)
      poke(base + y * 16 + x, c or 0)
    end
  end
end

local function seg_d(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local tt = 0
  if l2 > 0 then
    tt = ((px - ax) * dx + (py - ay) * dy) / l2
    if tt < 0 then tt = 0 elseif tt > 1 then tt = 1 end
  end
  local qx, qy = ax + dx * tt, ay + dy * tt
  local ex, ey = px - qx, py - qy
  return sqrt(ex * ex + ey * ey)
end

local function bake_sprites()
  -- 小鸟（红，怒眉，白肚，橙喙）
  bake(1, function(x, y)
    -- 尾羽
    if x <= 4 and (y >= 6.4 and y <= 7.8 or y >= 9.6 and y <= 11) then
      if x <= 1.2 then return 62 end
      return 60
    end
    -- 头顶双羽
    local f1 = sqrt((x - 6.2) * (x - 6.2) + (y - 2.2) * (y - 2.2))
    local f2 = sqrt((x - 8.4) * (x - 8.4) + (y - 1.4) * (y - 1.4))
    if f1 < 1.1 or f2 < 1.1 then return 58 end
    if f1 < 1.7 or f2 < 1.7 then return 62 end
    -- 喙
    if x >= 12 and abs(y - 8.9) < (x - 10.8) * 0.75 then
      if abs(y - 8.9) < 0.5 then return 25 end
      return 29
    end
    -- 身体
    local dx, dy = x - 7.4, y - 8.6
    local d = sqrt(dx * dx + dy * dy)
    if d > 6.3 then return nil end
    if d > 5.3 then return 62 end
    -- 白肚
    local bx, by = (x - 8.4) / 3.1, (y - 10.6) / 2.3
    if bx * bx + by * by <= 1 then return 21 end
    -- 眼睛
    local e1 = sqrt((x - 9.5) * (x - 9.5) + (y - 6.3) * (y - 6.3))
    local e2 = sqrt((x - 11.8) * (x - 11.8) + (y - 6.5) * (y - 6.5))
    if e1 < 1.5 or e2 < 1.3 then
      local p1 = sqrt((x - 10.2) * (x - 10.2) + (y - 6.5) * (y - 6.5))
      local p2 = sqrt((x - 12.4) * (x - 12.4) + (y - 6.7) * (y - 6.7))
      if p1 < 0.7 or p2 < 0.6 then return 0 end
      return 7
    end
    -- 怒眉
    if seg_d(x, y, 7.4, 4.4, 12.6, 6.1) < 0.9 then return 62 end
    if dy > 2.2 then return 60 end
    return 58
  end)
  -- 小猪（绿，大鼻，竖耳）
  bake(2, function(x, y)
    -- 耳朵
    local a1 = sqrt((x - 4.7) * (x - 4.7) + (y - 3.5) * (y - 3.5))
    local a2 = sqrt((x - 11.3) * (x - 11.3) + (y - 3.5) * (y - 3.5))
    if a1 < 1.2 or a2 < 1.2 then return 34 end
    if a1 < 1.8 or a2 < 1.8 then return 36 end
    local dx, dy = x - 8, y - 8.6
    local d = sqrt(dx * dx + dy * dy)
    if d > 6.4 then return nil end
    if d > 5.5 then return 36 end
    -- 鼻子
    local sx, sy = (x - 8) / 2.7, (y - 9.8) / 2.1
    local sd = sx * sx + sy * sy
    if sd <= 1 then
      local n1 = sqrt((x - 6.9) * (x - 6.9) + (y - 9.8) * (y - 9.8))
      local n2 = sqrt((x - 9.1) * (x - 9.1) + (y - 9.8) * (y - 9.8))
      if n1 < 0.55 or n2 < 0.55 then return 35 end
      return 33
    end
    if sd <= 1.5 then return 35 end
    -- 眼睛
    local e1 = sqrt((x - 5.4) * (x - 5.4) + (y - 6.6) * (y - 6.6))
    local e2 = sqrt((x - 10.6) * (x - 10.6) + (y - 6.6) * (y - 6.6))
    if e1 < 1.3 or e2 < 1.3 then
      local p1 = sqrt((x - 5.8) * (x - 5.8) + (y - 6.8) * (y - 6.8))
      local p2 = sqrt((x - 10.2) * (x - 10.2) + (y - 6.8) * (y - 6.8))
      if p1 < 0.55 or p2 < 0.55 then return 0 end
      return 7
    end
    if dy > 2.4 then return 35 end
    return 34
  end)
end

-- ================================================================ 全局状态

local state = "title" -- title | select | play | pause | settle
local t = 0           -- 全局幀
local gt = 0          -- 本关幀
local cur_lv = 1      -- 当前关卡
local score = 0
local stars, best = {}, {}
local music_on = true

-- 对局状态
local phase = "ready" -- ready | aim | fly | load | drain
local aim_ang, aim_pow = DEF_ANG, DEF_POW
local birds_left = 0
local pigs_left = 0
local win_t, load_t, drain_t = 0, 0, 0
local slow_t, flash_t, shake_t = 0, 0, 0
local settle_t, won, new_best, shown_stars = 0, false, false, 0
local sel = 1         -- 选关光标
local pause_sel = 1

-- 物理实体
local ground_b
local blocks, pigs, tnts = {}, {}, {}
local bird            -- 飞行中的小鸟 { b, trail, fly_t, still }
local by_id = {}      -- body id → 实体表
local prevel = {}     -- body id → {vx, vy}（步进前快照）

-- 演出
local parts = {}      -- 粒子池
local floats = {}     -- 飘分文本
local snd_cd = {}     -- 音效限频
local clouds = {
  { x = 30, y = 38, s = 1.0 }, { x = 118, y = 22, s = 0.8 },
  { x = 196, y = 50, s = 1.2 }, { x = 74, y = 76, s = 0.7 },
  { x = 160, y = 92, s = 0.9 },
}

-- ================================================================ 小工具

local function shadow_print(s, x, y, c)
  print(s, x + 1, y + 1, 0)
  print(s, x, y, c)
end

-- 五角星（中心扇形三角带）
local function draw_star(x, y, r, c, rt)
  rt = rt or r * 0.45
  local px, py = {}, {}
  for i = 0, 9 do
    local a = -0.25 + i * 0.1
    local rr = (i % 2 == 0) and r or rt
    px[i + 1] = x + cos(a) * rr
    py[i + 1] = y + sin(a) * rr
  end
  for i = 1, 10 do
    local j = i % 10 + 1
    trifill(x, y, px[i], py[i], px[j], py[j], c)
  end
end

-- 粒子（简单表池，容量上限）
local function puff(x, y, n, c, spd, life, grav)
  for _ = 1, n do
    if #parts >= 220 then return end
    local a = rnd(1)
    local s = rnd(spd * 0.3, spd)
    parts[#parts + 1] = {
      x = x, y = y,
      vx = cos(a) * s, vy = sin(a) * s - spd * 0.25,
      life = flr(rnd(life * 0.6, life)),
      c = c, g = grav, sz = flr(rnd(1, 2.7)),
    }
  end
end

local function update_parts()
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.vy = p.vy + p.g
    p.life = p.life - 1
    if p.y > GROUND_Y - 1 and p.vy > 0 then
      p.y = GROUND_Y - 1
      p.vy = -p.vy * 0.4
      p.vx = p.vx * 0.7
    end
    if p.life <= 0 then deli(parts, i) end
  end
end

local function draw_parts()
  for i = 1, #parts do
    local p = parts[i]
    rectfill(p.x, p.y, p.sz, p.sz, p.c)
  end
end

-- 飘分文本
local function add_float(x, y, txt, c)
  floats[#floats + 1] = { x = x, y = y, txt = txt, c = c, t = 46 }
end

local function update_floats()
  for i = #floats, 1, -1 do
    local f = floats[i]
    f.y = f.y - 0.45
    f.t = f.t - 1
    if f.t <= 0 then deli(floats, i) end
  end
end

local function draw_floats()
  for i = 1, #floats do
    local f = floats[i]
    local s = f.txt
    print(s, f.x - tw(s) / 2 + 1, f.y + 1, 0)
    print(s, f.x - tw(s) / 2, f.y, f.c)
  end
end

local function add_score(n, x, y, c)
  score = score + n
  add_float(x, y, "+" .. n, c)
end

-- 限频音效
local function play_sfx(id)
  if gt < (snd_cd[id] or -99) then return end
  snd_cd[id] = gt + 5
  sfx(id)
end

local function total_stars()
  local n = 0
  for i = 1, NLEVEL do n = n + (stars[i] or 0) end
  return n
end

local function unlocked(i)
  return i == 1 or (stars[i - 1] or 0) > 0
end

-- ================================================================ 伤害与破坏

local take_damage -- 前向声明

-- 从实体表中移除并删除物理体
local function detach(e)
  local bid = e.b.id
  phy_del(e.b)
  by_id[bid] = nil
  if e.kind == "pig" then del(pigs, e)
  elseif e.kind == "tnt" then del(tnts, e)
  else del(blocks, e) end
end

-- 炸药桶爆炸：径向冲量 + 范围伤害 + 演出
local function explode_tnt(e)
  local p = e.b.pos
  local cx, cy = p.x, p.y
  detach(e)
  sfx(9)
  shake_t = 14
  flash_t = 2
  puff(cx, cy, 12, 30, 3.2, 26, 0.06)
  puff(cx, cy, 10, 59, 2.6, 30, 0.05)
  puff(cx, cy, 12, 6, 1.8, 40, 0.015)
  -- 收集受影响者（避免遍历中修改列表）
  local victims = {}
  for _, list in ipairs({ blocks, pigs, tnts }) do
    for i = 1, #list do victims[#victims + 1] = list[i] end
  end
  if bird then victims[#victims + 1] = bird end
  for i = 1, #victims do
    local ent = victims[i] -- 勿名 v：会遮蔽全局 vec2 构造器 v()
    if not ent.dead then
      local vp = ent.b.pos
      local dx, dy = vp.x - cx, vp.y - cy - 4
      local d = sqrt(dx * dx + dy * dy)
      if d < TNT_R then
        local dd = max(d, 6)
        local nx, ny = dx / dd, dy / dd
        if d < 1 then nx, ny = 0, -1 end
        local k = 1 - dd / TNT_R
        ent.b.vel = ent.b.vel + v(nx * 430 * k, ny * 430 * k - 60 * k)
        if ent.kind ~= "bird" then
          ent.cd = 0
          take_damage(ent, 320 * k)
        end
      end
    end
  end
end

-- 标记破坏：碰撞回调可能成对触发，若一方回调立即 phy_del 自己，
-- 另一方的回调再读 other.id 就会踩到已删除的 body。
-- 因此回调内只做标记与演出，物理体统一延迟到下一幀 update 删除。
local function mark_destroy(e)
  if e.dead then return end
  e.dead = true
  local p = e.b.pos
  if e.kind == "pig" then
    pigs_left = pigs_left - 1
    add_score(PIG_SCORE, p.x, p.y - 8, 30)
    sfx(8)
    puff(p.x, p.y, 14, 34, 2.2, 32, 0.1)
    puff(p.x, p.y, 6, 33, 1.6, 28, 0.1)
    for i = 1, 5 do
      add_float(p.x + rnd(-8, 8), p.y - 6 - rnd(10), "★", 31)
    end
    if pigs_left <= 0 then
      win_t = 55
      slow_t = 26
      flash_t = 3
    end
  elseif e.kind == "tnt" then
    add_score(1000, p.x, p.y - 10, 31)
    e.fuse = 3 -- 延时引爆（防递归），爆炸时再删除本体
  else
    local md = MAT[e.mat]
    add_score(md.score, p.x, p.y - 6, 22)
    play_sfx(md.brk_sfx)
    local n = mid(4, flr(e.w * e.h / 22), 14)
    for i = 1, n do
      puff(p.x + rnd(-e.w / 2, e.w / 2), p.y + rnd(-e.h / 2, e.h / 2),
        1, md.deb[i % 3 + 1], 2.4, 34, 0.14)
    end
    puff(p.x, p.y, 5, 6, 1.2, 22, 0.02)
  end
end

-- 统一清理已标记破坏的实体（TNT 由爆炸路径自行删除）
local function sweep_dead()
  for _, list in ipairs({ blocks, pigs, tnts }) do
    for i = #list, 1, -1 do
      local e = list[i]
      if e.dead and e.kind ~= "tnt" then
        detach(e)
      end
    end
  end
end

-- 冲量伤害入口（j 为冲量数值）
take_damage = function(e, j)
  if e.dead or state ~= "play" then return end
  if gt < (e.cd or 0) then return end
  e.cd = gt + 5
  e.hp = e.hp - j
  local p = e.b.pos
  if j > 25 then
    puff(p.x, p.y, 3, 6, 1.0, 16, 0.02)
  end
  if e.kind == "block" then
    local md = MAT[e.mat]
    if j > 40 then play_sfx(md.hit_sfx) end
  end
  if j > 180 then shake_t = max(shake_t, 6) end
  if e.hp <= 0 then mark_destroy(e) end
end

-- 碰撞回调工厂：按步进前速度快照计算撞击冲量
local function make_hit_cb(e)
  return function(other, n)
    if state ~= "play" or e.dead then return end
    local sv = prevel[e.b.id]
    if not sv then return end
    local ovx, ovy = 0, 0
    local oent = by_id[other.id]
    if oent then
      local ov = prevel[other.id]
      if ov then ovx, ovy = ov[1], ov[2] end
    end
    -- 接近速度：对方沿 n（指向自己）逼近自己的分量；n 为作用在自己上的推开方向
    local closing = (ovx - sv[1]) * n.x + (ovy - sv[2]) * n.y
    if closing < IMPACT_MIN then return end
    local m = e.b.mass
    if oent then
      local mo = other.mass
      m = m * mo / (m + mo)
    end
    take_damage(e, closing * m)
  end
end

-- ================================================================ 关卡装配

local function snap_list(list)
  for i = 1, #list do
    local e = list[i]
    if not e.dead then
      local vel = e.b.vel
      prevel[e.b.id] = { vel.x, vel.y }
    end
  end
end

local function snap_vels()
  prevel = {}
  snap_list(blocks)
  snap_list(pigs)
  snap_list(tnts)
  if bird then
    local vel = bird.b.vel
    prevel[bird.b.id] = { vel.x, vel.y }
  end
end

local function teardown()
  for _, list in ipairs({ blocks, pigs, tnts }) do
    for i = #list, 1, -1 do phy_del(list[i].b) end
  end
  if bird then phy_del(bird.b) bird = nil end
  if ground_b then phy_del(ground_b) ground_b = nil end
  blocks, pigs, tnts, by_id, prevel = {}, {}, {}, {}, {}
  parts, floats = {}, {}
end

local function start_level(n)
  teardown()
  cur_lv = n
  local lv = LV[n]
  -- 地面（宽出屏，防侧漏）
  ground_b = body(140, GROUND_Y + 12, 440, 24, "stat")
  ground_b.friction = 6
  -- 方块
  for i = 1, #lv.bl do
    local d = lv.bl[i]
    local md = MAT[d[5]]
    local b = body(d[1], d[2], d[3], d[4], "dyn")
    b.mass = d[3] * d[4] / 256 * md.mf
    b.friction = md.fric
    b.restitution = md.rest
    local e = { b = b, kind = "block", mat = d[5], w = d[3], h = d[4],
                hp = md.hp, hp0 = md.hp, dead = false }
    e.b:hit(make_hit_cb(e))
    blocks[#blocks + 1] = e
    by_id[b.id] = e
  end
  -- 猪
  for i = 1, #lv.pg do
    local d = lv.pg[i]
    local b = cbody(d[1], d[2], PIG_R, "dyn")
    b.restitution = 0.15
    b.friction = 4
    local e = { b = b, kind = "pig", hp = 30, hp0 = 30, dead = false }
    e.b:hit(make_hit_cb(e))
    pigs[#pigs + 1] = e
    by_id[b.id] = e
  end
  -- 炸药桶
  for i = 1, #lv.tn do
    local d = lv.tn[i]
    local b = body(d[1], d[2], 16, 16, "dyn")
    b.mass = 0.8
    b.friction = 5
    b.restitution = 0.05
    local e = { b = b, kind = "tnt", hp = 22, hp0 = 22, dead = false, fuse = 0 }
    e.b:hit(make_hit_cb(e))
    tnts[#tnts + 1] = e
    by_id[b.id] = e
  end
  birds_left = lv.birds
  pigs_left = #lv.pg
  score = 0
  gt = 0
  phase = "ready"
  aim_ang, aim_pow = DEF_ANG, DEF_POW
  win_t, load_t, drain_t, slow_t = 0, 0, 0, 0
  state = "play"
end

-- ================================================================ 弹弓与发射

local function aim_dir()
  return v(cos(aim_ang / 360), -sin(aim_ang / 360))
end

local function pouch_pos()
  local d = aim_dir()
  local stretch = 6 + 16 * aim_pow
  return FORK_X - d.x * stretch, FORK_Y - d.y * stretch
end

local function launch_speed()
  return V_MIN + (V_MAX - V_MIN) * aim_pow
end

local function fire()
  local px, py = pouch_pos()
  local d = aim_dir()
  local b = cbody(px, py, BIRD_R, "dyn")
  b.mass = 0.45
  b.restitution = 0.15 -- 低弹性：撞击后更倾向砸穿而非弹开
  b.friction = 3
  b.vel = d * launch_speed()
  bird = { b = b, kind = "bird", trail = {}, fly_t = 0, still = 0, dead = false }
  by_id[b.id] = bird
  birds_left = birds_left - 1
  phase = "fly"
  sfx(1)
  puff(px, py, 6, 6, 1.5, 24, 0.02)
end

local function after_bird()
  bird = nil
  if pigs_left > 0 then
    if birds_left > 0 then
      phase = "load"
      load_t = 22
    else
      phase = "drain"
      drain_t = 0
    end
  else
    -- 猪已清零：胜利倒计时接管，本相位静置等待
    phase = "drain"
    drain_t = 0
  end
end

local function update_bird()
  local bd = bird.b
  local p = bd.pos
  bird.fly_t = bird.fly_t + 1
  if bird.fly_t % 3 == 0 then
    bird.trail[#bird.trail + 1] = { x = p.x, y = p.y }
    if #bird.trail > 42 then deli(bird.trail, 1) end
  end
  local sp = v.len(bd.vel)
  if sp < 14 then bird.still = bird.still + 1 else bird.still = 0 end
  if bird.fly_t > 330 or bird.still > 42
    or p.x > 340 or p.x < -60 or p.y > 300 then
    if p.y <= 300 and p.x >= -60 and p.x <= 340 then
      puff(p.x, p.y, 8, 6, 1.2, 22, 0.02)
    end
    local bid = bd.id -- 先取 id：phy_del 后再访问字段会报“已删除”
    phy_del(bd)
    by_id[bid] = nil
    after_bird()
  end
end

-- 场景是否安定（用于失败判定前等待）
local function scene_calm()
  for _, list in ipairs({ blocks, pigs, tnts }) do
    for i = 1, #list do
      local e = list[i]
      if not e.dead and v.len(e.b.vel) > 18 then return false end
    end
  end
  return true
end

-- ================================================================ 结算

local function settle_win()
  score = score + birds_left * BIRD_BONUS
  local th = LV[cur_lv].th
  local n = 1
  if score >= th[2] then n = 2 end
  if score >= th[3] then n = 3 end
  won = true
  shown_stars = n
  new_best = score > (best[cur_lv] or 0)
  if n > (stars[cur_lv] or 0) then stars[cur_lv] = n end
  if new_best then best[cur_lv] = score end
  dset(cur_lv, stars[cur_lv] or 0)
  dset(NLEVEL + cur_lv, best[cur_lv] or 0)
  fflush()
  state = "settle"
  settle_t = 0
  sfx(10)
end

local function settle_lose()
  won = false
  state = "settle"
  settle_t = 0
  sfx(11)
end

-- 暂停冻结（物理每幀自动步进，靠零重力+零速度冻结世界）
local frozen
local function freeze_list(list)
  for i = 1, #list do
    local e = list[i]
    if not e.dead then
      frozen[#frozen + 1] = { e.b, e.b.vel.x, e.b.vel.y }
      e.b.vel = v(0, 0)
    end
  end
end

local function pause_freeze()
  frozen = {}
  freeze_list(blocks)
  freeze_list(pigs)
  freeze_list(tnts)
  if bird then
    frozen[#frozen + 1] = { bird.b, bird.b.vel.x, bird.b.vel.y }
    bird.b.vel = v(0, 0)
  end
  phy_gravity(v(0, 0))
end

local function pause_unfreeze()
  for i = 1, #frozen do
    local f = frozen[i]
    f[1].vel = v(f[2], f[3])
  end
  frozen = nil
  phy_gravity(v(0, 900))
end

-- ================================================================ 更新

local function update_select()
  if dirp(0) then sel = (sel - 2) % NLEVEL + 1 sfx(12) end
  if dirp(1) then sel = sel % NLEVEL + 1 sfx(12) end
  if dirp(2) then sel = (sel - 6) % NLEVEL + 1 sfx(12) end
  if dirp(3) then sel = (sel + 4) % NLEVEL + 1 sfx(12) end
  if btnp(4) then
    if unlocked(sel) then
      start_level(sel)
      sfx(12)
    else
      sfx(11)
    end
  end
  if btnp(5) or btnp(11) then state = "title" sfx(12) end
end

local function update_pause()
  if dirp(3) then pause_sel = pause_sel % 3 + 1 sfx(12) end
  if dirp(2) then pause_sel = (pause_sel + 1) % 3 + 1 sfx(12) end
  -- 上 = (n+1)%3+1，下 = n%3+1，循环三选一
  if btnp(11) or btnp(5) then
    pause_unfreeze()
    state = "play"
  elseif btnp(4) then
    pause_unfreeze()
    if pause_sel == 1 then
      state = "play"
    elseif pause_sel == 2 then
      start_level(cur_lv)
    else
      state = "select"
      sel = cur_lv
    end
    sfx(12)
  end
end

local function update_settle()
  settle_t = settle_t + 1
  -- 星星逐个亮起配音
  if won then
    if settle_t == 30 and shown_stars >= 1 then sfx(13) end
    if settle_t == 55 and shown_stars >= 2 then sfx(13) end
    if settle_t == 80 and shown_stars >= 3 then sfx(13) end
  end
  if settle_t > 45 and btnp(4) then
    if won then
      if cur_lv < NLEVEL then
        start_level(cur_lv + 1)
      else
        start_level(cur_lv)
      end
    else
      start_level(cur_lv)
    end
  elseif settle_t > 45 and btnp(11) then
    state = "select"
    sel = cur_lv
  end
end

local function update_play()
  gt = gt + 1
  snap_vels()

  -- 最后一击慢动作（速度衰减 + 低重力，结束后恢复）
  if slow_t > 0 then
    slow_t = slow_t - 1
    local function slow_list(list)
      for i = 1, #list do
        local e = list[i]
        if not e.dead then
          e.b.vel = e.b.vel * 0.55
          e.b.gravity_scale = 0.35
        end
      end
    end
    slow_list(blocks)
    slow_list(pigs)
    slow_list(tnts)
    if bird then bird.b.vel = bird.b.vel * 0.55 bird.b.gravity_scale = 0.35 end
    if slow_t == 0 then
      local function wake(list)
        for i = 1, #list do
          local e = list[i]
          if not e.dead then e.b.gravity_scale = 1 end
        end
      end
      wake(blocks) wake(pigs) wake(tnts)
      if bird then bird.b.gravity_scale = 1 end
    end
  end

  -- 阶段机
  if phase == "ready" then
    if btn(4) then phase = "aim" end
  elseif phase == "aim" then
    local changed = false
    if dir(0) then aim_ang = max(10, aim_ang - 0.55) changed = true end
    if dir(1) then aim_ang = min(80, aim_ang + 0.55) changed = true end
    if dir(3) then aim_pow = max(0, aim_pow - 0.007) changed = true end
    if dir(2) then aim_pow = min(1, aim_pow + 0.007) changed = true end
    if changed and gt % 4 == 0 then play_sfx(0) end
    if btnp(5) then
      phase = "ready"
      aim_ang, aim_pow = DEF_ANG, DEF_POW
    elseif not btn(4) then
      fire()
    end
  elseif phase == "fly" then
    update_bird()
  elseif phase == "load" then
    load_t = load_t - 1
    if load_t <= 0 then
      phase = "ready"
      aim_ang, aim_pow = DEF_ANG, DEF_POW
      sfx(14)
    end
  elseif phase == "drain" then
    drain_t = drain_t + 1
    if drain_t > 210 or scene_calm() then settle_lose() end
  end

  -- TNT 引信
  for i = #tnts, 1, -1 do
    local e = tnts[i]
    if e.dead then
      e.fuse = e.fuse - 1
      if e.fuse <= 0 then explode_tnt(e) end
    end
  end

  -- 清理上一幀标记破坏的实体
  sweep_dead()

  -- 出界清理（猪出界视为消灭）
  for _, list in ipairs({ blocks, pigs, tnts }) do
    for i = #list, 1, -1 do
      local e = list[i]
      if not e.dead then
        local p = e.b.pos
        if p.y > 300 or p.x < -60 or p.x > 360 then
          if e.kind == "pig" then
            e.dead = true
            pigs_left = pigs_left - 1
            if pigs_left <= 0 then
              win_t = 55
              slow_t = 26
            end
          end
          local bid = e.b.id
          phy_del(e.b)
          by_id[bid] = nil
          deli(list, i)
        end
      end
    end
  end

  update_parts()
  update_floats()
  if shake_t > 0 then shake_t = shake_t - 1 end

  if win_t > 0 then
    win_t = win_t - 1
    if win_t <= 0 then settle_win() end
  end
end

function _update()
  t = t + 1
  if btnp(10) then
    music_on = not music_on
    dset(40, music_on and 0 or 1)
    if music_on then music(0, 500, 0x70) else music(-1, 200) end
  end
  if state == "title" then
    if btnp(4) or btnp(11) then state = "select" sfx(12) end
  elseif state == "select" then
    update_select()
  elseif state == "play" then
    if btnp(11) then
      state = "pause"
      pause_sel = 1
      pause_freeze()
    else
      update_play()
    end
  elseif state == "pause" then
    update_pause()
  elseif state == "settle" then
    update_settle()
  end
  if flash_t > 0 then flash_t = flash_t - 1 end
end

-- ================================================================ 绘制：背景

local function draw_bg()
  -- 天空三段
  rectfill(0, 0, 256, 100, 40)
  rectfill(0, 100, 256, 70, 41)
  rectfill(0, 170, 256, GROUND_Y - 170, 42)
  -- 太阳
  circfill(224, 34, 11, 30)
  circfill(224, 34, 8, 31)
  -- 云（缓慢漂移，位置确定性）
  for i = 1, #clouds do
    local c = clouds[i]
    local cx = (c.x + t * 0.06 * c.s) % 300 - 22
    circfill(cx, c.y, 6 * c.s, 8)
    circfill(cx + 7 * c.s, c.y + 2, 5 * c.s, 8)
    circfill(cx - 7 * c.s, c.y + 2, 4 * c.s, 8)
    circfill(cx + 2, c.y - 3 * c.s, 4 * c.s, 8)
  end
  -- 远山（深色剪影）
  circfill(48, GROUND_Y + 44, 92, 12)
  circfill(208, GROUND_Y + 58, 110, 12)
  circfill(128, GROUND_Y + 66, 120, 11)
  -- 地面
  rectfill(0, GROUND_Y, 256, 32, 17)
  rectfill(0, GROUND_Y, 256, 3, 34)
  rectfill(0, GROUND_Y + 3, 256, 2, 33)
  for x = 0, 255 do
    if (x * 7 + 13) % 97 < 4 then
      pset(x, GROUND_Y + 9 + (x * 31) % 18, 18)
    end
  end
end

-- ================================================================ 绘制：弹弓

local function draw_sling_arm(x0, y0, x1, y1, c)
  line(x0, y0, x1, y1, c)
  line(x0 + 1, y0, x1 + 1, y1, c)
  line(x0, y0 + 1, x1, y1 + 1, 16)
end

local function draw_sling_back()
  -- 支柱与前叉臂（后臂）
  rectfill(40, 192, 6, 32, 18)
  rectfill(40, 192, 2, 32, 16)
  draw_sling_arm(46, 194, 52, 170, 17)
end

local function draw_sling_front()
  draw_sling_arm(41, 194, 36, 172, 19)
end

local function band_to(px, py, ax, ay)
  line(ax, ay, px, py, 62)
  line(ax, ay + 1, px, py + 1, 62)
end

-- ================================================================ 绘制：实体

local function draw_block(e)
  local p = e.b.pos
  local x0 = p.x - e.w / 2
  local y0 = p.y - e.h / 2
  local ratio = e.hp / e.hp0
  if e.mat == 1 then -- 木
    rectfill(x0, y0, e.w, e.h, 19)
    rect(x0, y0, e.w, e.h, 17)
    if e.w >= e.h then
      local yy = y0 + 2
      while yy < y0 + e.h - 1 do
        line(x0 + 1, yy, x0 + e.w - 2, yy, 18)
        yy = yy + 3
      end
      line(x0 + 1, y0 + 1, x0 + 1, y0 + e.h - 2, 20)
    else
      local xx = x0 + 2
      while xx < x0 + e.w - 1 do
        line(xx, y0 + 1, xx, y0 + e.h - 2, 18)
        xx = xx + 3
      end
      line(x0 + 1, y0 + 1, x0 + e.w - 2, y0 + 1, 20)
    end
  elseif e.mat == 2 then -- 石
    rectfill(x0, y0, e.w, e.h, 5)
    rect(x0, y0, e.w, e.h, 3)
    pset(x0 + 2, y0 + 2, 6)
    pset(x0 + e.w - 3, y0 + 3, 6)
    pset(x0 + 3, y0 + e.h - 3, 4)
  else -- 冰（抖色半透明感）
    rectfill(x0, y0, e.w, e.h, 42)
    fillp(0x5a5a)
    rectfill(x0, y0, e.w, e.h / 2 + 1, 44 * 256 + 42)
    fillp()
    rect(x0, y0, e.w, e.h, 40)
    pset(x0 + 2, y0 + 2, 44)
    pset(x0 + e.w - 3, y0 + 2, 43)
  end
  -- 裂纹（受损表现）
  if ratio < 0.99 then
    local seed = e.b.id * 37
    local n = ratio < 0.34 and 3 or (ratio < 0.67 and 2 or 1)
    for i = 1, n do
      local cx = x0 + ((seed + i * 53) % max(e.w - 4, 1)) + 2
      local cy = y0 + ((seed + i * 29) % max(e.h - 4, 1)) + 2
      line(cx, cy, cx + 2, cy + 2, e.mat == 3 and 7 or 2)
      line(cx + 2, cy + 2, cx + 4, cy, e.mat == 3 and 7 or 2)
    end
  end
end

local function draw_tnt(e)
  local p = e.b.pos
  local x0, y0 = p.x - 8, p.y - 8
  rectfill(x0, y0, 16, 16, 59)
  rect(x0, y0, 16, 16, 61)
  rectfill(x0 + 1, y0 + 5, 14, 5, 61)
  rectfill(x0 + 3, y0 + 6, 2, 3, 22)
  rectfill(x0 + 7, y0 + 6, 2, 3, 22)
  rectfill(x0 + 11, y0 + 6, 2, 3, 22)
  line(x0 + 8, y0, x0 + 8, y0 - 3, 18)
  if e.dead and flr(t / 3) % 2 == 0 then
    circfill(x0 + 8, y0 - 4, 2, 31)
    pset(x0 + 6, y0 - 5, 30)
    pset(x0 + 10, y0 - 4, 30)
  end
end

local function draw_pig(e)
  local p = e.b.pos
  spr(2, p.x - 8, p.y - 8)
  -- 受伤表情：血量过半画裂纹状皱眉
  if e.hp < e.hp0 * 0.5 then
    line(p.x - 4, p.y - 4, p.x - 1, p.y - 3, 36)
    line(p.x + 4, p.y - 4, p.x + 1, p.y - 3, 36)
  end
end

local function draw_bird_at(x, y)
  spr(1, x - 8, y - 8)
end

-- 弹道预测点（拉弓时）
local function draw_trajectory()
  local px, py = pouch_pos()
  local d = aim_dir()
  local vx, vy = d.x * launch_speed(), d.y * launch_speed()
  local n = 0
  for i = 1, 90 do
    vy = vy + 900 / 60
    px = px + vx / 60
    py = py + vy / 60
    if py > GROUND_Y or px > 256 then break end
    if i % 7 == 3 then
      n = n + 1
      if n > 9 then break end
      local c = (n % 2 == 0) and 7 or 8
      if aim_pow > 0.97 then c = 31 end
      circfill(px, py, max(2.2 - n * 0.15, 1), c)
    end
  end
end

-- 力度表（弹弓左侧竖条）
local function draw_power_bar()
  local bx, by, bh = 12, 138, 62
  rect(bx - 1, by - 1, 8, bh + 2, 0)
  rectfill(bx, by, 6, bh, 15)
  local fh = flr(bh * aim_pow)
  local c = 41
  if aim_pow > 0.66 then c = 59 elseif aim_pow > 0.33 then c = 29 else c = 34 end
  rectfill(bx, by + bh - fh, 6, fh, c)
  -- 角度刻度点
  for i = 0, 7 do
    pset(bx + 7, by + 4 + i * 8, (i / 7 < (80 - aim_ang) / 70) and 5 or 6)
  end
end

-- ================================================================ 绘制：HUD 与界面

local function draw_hud()
  camera(0, 0)
  -- 分数（左上）
  shadow_print("分数 " .. score, 4, 3, 7)
  -- 星级进度（小星）
  local th = LV[cur_lv].th
  for i = 1, 3 do
    draw_star(10 + (i - 1) * 15, 31, 5, score >= th[i] and 30 or 2)
  end
  -- 关卡（顶中）
  local cs = "第" .. cur_lv .. "关"
  shadow_print(cs, 128 - tw(cs) / 2, 3, 22)
  -- 剩余猪（右上）
  sspr(32, 0, 16, 16, 238, 2, 12, 12)
  shadow_print("×" .. pigs_left, 222, 3, 7)
  -- 底部提示
  local hs
  if phase == "aim" then
    hs = "角度 " .. flr(aim_ang) .. "　力度 " .. flr(aim_pow * 100)
  else
    hs = HINTS[flr(t / 150) % #HINTS + 1]
  end
  fillp(0xa5a5)
  rectfill(0, 240, 256, 16, 0 * 256 + 15)
  fillp()
  shadow_print(hs, 128 - tw(hs) / 2, 241, 6)
end

local function draw_pause()
  fillp(0x5a5a)
  rectfill(0, 0, 256, 256, 1 * 256 + 15)
  fillp()
  local px, py, pw, ph = 68, 84, 120, 92
  rectfill(px, py, pw, ph, 15)
  rect(px, py, pw, ph, 30)
  shadow_print("菜单", 128 - tw("菜单") / 2, py + 8, 22)
  local opts = { "继续", "重开本关", "选关界面" }
  for i = 1, 3 do
    local c = i == pause_sel and 30 or 6
    if i == pause_sel then
      print("→", px + 14, py + 32 + (i - 1) * 17, 30)
    end
    print(opts[i], px + 36, py + 32 + (i - 1) * 17, c)
  end
end

local function draw_settle()
  fillp(0x5a5a)
  rectfill(0, 0, 256, 256, 1 * 256 + 15)
  fillp()
  local px, py, pw, ph = 36, 58, 184, 130
  rectfill(px, py, pw, ph, 15)
  rect(px, py, pw, ph, 30)
  if won then
    shadow_print("过关！", 128 - tw("过关！") / 2, py + 10, 30)
    -- 星星逐个亮起
    for i = 1, 3 do
      local lit = settle_t > 20 + i * 25 and i <= shown_stars
      draw_star(88 + (i - 1) * 40, py + 48, 14, lit and 30 or 3)
    end
    -- 分数滚动
    local shown = flr(score * min(1, settle_t / 50))
    local ss2 = "分数 " .. shown
    shadow_print(ss2, 128 - tw(ss2) / 2, py + 74, 7)
    if settle_t > 55 then
      if new_best and flr(t / 8) % 2 == 0 then
        local nb = "新纪录！"
        shadow_print(nb, 128 - tw(nb) / 2, py + 94, 59)
      else
        local bs = "最佳 " .. (best[cur_lv] or 0)
        shadow_print(bs, 128 - tw(bs) / 2, py + 94, 22)
      end
    end
    local nxt = cur_lv < NLEVEL and "Ⓐ 下一关" or "Ⓐ 再玩一次"
    shadow_print(nxt, 128 - tw(nxt) / 2, py + 112, 6)
  else
    shadow_print("失败…", 128 - tw("失败…") / 2, py + 10, 59)
    local ps = "剩余小猪 " .. pigs_left .. " 只"
    shadow_print(ps, 128 - tw(ps) / 2, py + 48, 7)
    local ss3 = "分数 " .. score
    shadow_print(ss3, 128 - tw(ss3) / 2, py + 70, 7)
    local rs = "Ⓐ 重试"
    shadow_print(rs, 128 - tw(rs) / 2, py + 112, 6)
  end
  local ss = "Menu 选关"
  shadow_print(ss, 128 - tw(ss) / 2, py + 112 + 16 - 2, 9)
end

local function draw_title()
  draw_bg()
  draw_sling_back()
  draw_sling_front()
  -- 大小鸟蹲在弹弓上（瓦片 1 源坐标 (16,0)）
  sspr(16, 0, 16, 16, 28, 118, 48, 48)
  -- 地面上的猪（瓦片 2 源坐标 (32,0)）
  sspr(32, 0, 16, 16, 170, 196, 28, 28)
  sspr(32, 0, 16, 16, 202, 200, 20, 20)
  -- 标题
  local s = "愤怒的小鸟"
  print(s, 89, 43, 1)
  print(s, 88, 42, 63)
  local s2 = "FC-16・弹弓物理破坏"
  shadow_print(s2, 128 - tw(s2) / 2, 66, 7)
  local s3 = "拉弓发射　拆塔砸猪"
  shadow_print(s3, 128 - tw(s3) / 2, 86, 22)
  if flr(t / 20) % 2 == 0 then
    local s4 = "按 Ⓐ 开始"
    shadow_print(s4, 128 - tw(s4) / 2, 158, 30)
  end
  local s5 = "共获 ★ " .. total_stars()
  shadow_print(s5, 128 - tw(s5) / 2, 236, 6)
  draw_parts()
end

local function draw_select()
  draw_bg()
  local s = "选择关卡"
  shadow_print(s, 128 - tw(s) / 2, 8, 7)
  local ts = "共获 ★ " .. total_stars()
  shadow_print(ts, 128 - tw(ts) / 2, 28, 6)
  for i = 1, NLEVEL do
    local gx = 22 + ((i - 1) % 5) * 46
    local gy = 60 + flr((i - 1) / 5) * 66
    local ok = unlocked(i)
    rectfill(gx, gy, 42, 46, ok and 15 or 12)
    rect(gx, gy, 42, 46, i == sel and 30 or (ok and 11 or 13))
    if i == sel then
      rect(gx - 2, gy - 2, 46, 50, 30)
    end
    local c = ok and (i == sel and 30 or 7) or 5
    local ns = string.format("%02d", i)
    print(ns, gx + 21 - tw(ns) / 2, gy + 4, c)
    if ok then
      for st = 1, 3 do
        draw_star(gx + 11 + (st - 1) * 10, gy + 30, 4,
          st <= (stars[i] or 0) and 30 or 3)
      end
    else
      shadow_print("锁", gx + 21 - 8, gy + 24, 5)
    end
  end
  local info = unlocked(sel)
    and ("第" .. sel .. "关・" .. LV[sel].name .. "　鸟 ×" .. LV[sel].birds)
    or "先通过前一关解锁"
  shadow_print(info, 128 - tw(info) / 2, 202, 22)
  local h = "Ⓐ 选择　Menu 返回"
  shadow_print(h, 128 - tw(h) / 2, 224, 6)
end

-- ================================================================ 主绘制

local function draw_play()
  draw_bg()
  draw_sling_back()
  -- 拉弓后臂皮筋
  if phase == "aim" then
    local px, py = pouch_pos()
    band_to(px, py, 52, 171)
  end
  -- 等待的鸟队列（弹弓左侧排队；瓦片 1 源坐标 (16,0)）
  local on_sling = (phase == "ready" or phase == "aim") and 1 or 0
  for i = 1, birds_left - on_sling do
    sspr(16, 0, 16, 16, 2 + (i - 1) * 13, 210, 11, 11)
  end
  -- 结构（本幀刚标记破坏的实体不再绘制，由下一幀 sweep 删除）
  for i = 1, #blocks do
    if not blocks[i].dead then draw_block(blocks[i]) end
  end
  for i = 1, #tnts do draw_tnt(tnts[i]) end
  for i = 1, #pigs do
    if not pigs[i].dead then draw_pig(pigs[i]) end
  end
  -- 飞行中的鸟与轨迹
  if bird then
    for i = 1, #bird.trail do
      local tr = bird.trail[i]
      circfill(tr.x, tr.y, i > 30 and 1 or 2, 7)
    end
    local p = bird.b.pos
    draw_bird_at(p.x, p.y)
  end
  -- 待发射的鸟
  if on_sling == 1 then
    local px, py = FORK_X, FORK_Y
    if phase == "aim" then
      px, py = pouch_pos()
    else
      py = py + sin(t * 0.08) * 1 -- 待命呼吸
    end
    draw_bird_at(px, py)
    -- 前臂皮筋与皮兜
    if phase == "aim" then
      band_to(px, py, 36, 173)
      rectfill(px - 3, py - 3, 6, 6, 62)
    end
  end
  draw_sling_front()
  if phase == "aim" then
    draw_trajectory()
    draw_power_bar()
  end
  draw_parts()
  draw_floats()
  -- 最后一击横幅
  if win_t > 0 and flr(t / 4) % 2 == 0 then
    local s = "全部消灭！"
    print(s, 128 - tw(s) / 2 + 1, 91, 0)
    print(s, 128 - tw(s) / 2, 90, 31)
  end
  draw_hud()
  if state == "pause" then draw_pause() end
  if state == "settle" then draw_settle() end
end

function _draw()
  pal()
  if flash_t > 0 then
    for i = 0, 63 do pal(i, 7, 1) end
  end
  if shake_t > 0 then
    camera(flr(rnd(5)) - 2, flr(rnd(5)) - 2)
  else
    camera(0, 0)
  end
  if state == "title" then
    draw_title()
  elseif state == "select" then
    draw_select()
  else
    draw_play()
  end
end

-- ================================================================ 初始化

function _init()
  srand(20260910)
  bake_sprites()
  init_audio()
  music_on = flr(dget(40)) == 0
  for i = 1, NLEVEL do
    stars[i] = flr(dget(i)) -- dget 返回定点数，转整数避免拼接出 ".0"
    best[i] = flr(dget(NLEVEL + i))
  end
  if music_on then music(0, 500, 0x70) end -- ch4-6 交给音乐
  state = "title"
  t = 0
end
