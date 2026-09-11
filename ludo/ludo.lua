-- FC-16 飞行棋（demo/ludo）
-- 经典中式四色飞行棋：52 格环形跑道（每色 13 格）＋各色 6 格终点跑道＋虚线飞行捷径
-- 简化与约定（详见 README.md）：
--   ・每次移动至多触发一次同色跳跃（+4）或捷径飞跃（+12），二者不连环
--   ・跳跃不得越过终点入口（+4 超出第 50 格则不跳）
--   ・飞跃途中只撞击落点的敌机
--   ・撞机者奖励再掷一次；掷 6 后可再掷；连掷三个 6 本回合作废（第三枚 6 不落子）
--   ・终点须恰好到达，多出的步数回退走完
--   ・首位 4 机全部到达者获胜，随后直接结算名次（其余按进度排名）
-- 确定性：AI 为纯状态启发式；骰子与装饰粒子用 rnd（PCG32），不读真实时钟
-- 操作：Ⓐ 掷骰／确认　⬅➡⬆⬇ 选机　Ⓑ 弃权　Select 音乐开关　Start 回标题

-- ================================================================ 几何

local CS, OX, OY = 15, 15, 16 -- 格边长／棋盘原点（顶部留 16px 状态栏，底部 15px 提示栏）
local GOAL = 57               -- 路径总长：51 环格（0-50）＋6 终点格（51-56）＋中心（57）
local FLY_SRC, FLY_DST = 28, 40 -- 己色飞行格相对位置 → 飞跃落点（+12）

local NAME = {"红", "黄", "蓝", "绿"}
local START0 = {0, 13, 26, 39} -- 各色起飞点在环上的 0 基索引（红起顺时针）
local PC = {                   -- 每色 {主色, 暗色, 深色, 亮色}（SPEC §2.2 固定色号，不做算术推导）
  {58, 60, 61, 57},            -- 红
  {30, 28, 25, 31},            -- 黄
  {41, 40, 39, 42},            -- 蓝
  {34, 35, 36, 33},            -- 绿
}
local LDIR = {0, 1, 2, 3} -- 各色起飞后初始朝向：红东／黄南／蓝西／绿北（顺时针）

-- 环形跑道 52 格（顺时针），自红方起飞点 (1,6) 起
local RING = {}
do
  local function rc(cx, cy) RING[#RING + 1] = {cx, cy} end
  for x = 1, 5 do rc(x, 6) end       -- 左臂上沿向东（红出发）
  for y = 5, 0, -1 do rc(6, y) end   -- 上臂左列向北
  rc(7, 0)                           -- 上臂尖端（黄终点入口）
  for y = 0, 5 do rc(8, y) end       -- 上臂右列向南
  for x = 9, 14 do rc(x, 6) end      -- 右臂上沿向东
  rc(14, 7)                          -- 右臂尖端（蓝终点入口）
  for x = 14, 9, -1 do rc(x, 8) end  -- 右臂下沿向西
  for y = 9, 14 do rc(8, y) end      -- 下臂右列向南
  rc(7, 14)                          -- 下臂尖端（绿终点入口）
  for y = 14, 9, -1 do rc(6, y) end  -- 下臂左列向北
  for x = 5, 0, -1 do rc(x, 8) end   -- 左臂下沿向西
  rc(0, 7)                           -- 左臂尖端（红终点入口）
  rc(0, 6)                           -- 环闭合格
end

-- 各色 6 格终点跑道（自入口向中心）
local HOME = {
  {{1, 7}, {2, 7}, {3, 7}, {4, 7}, {5, 7}, {6, 7}},     -- 红：自西向东
  {{7, 1}, {7, 2}, {7, 3}, {7, 4}, {7, 5}, {7, 6}},     -- 黄：自北向南
  {{13, 7}, {12, 7}, {11, 7}, {10, 7}, {9, 7}, {8, 7}}, -- 蓝：自东向西
  {{7, 13}, {7, 12}, {7, 11}, {7, 10}, {7, 9}, {7, 8}}, -- 绿：自南向北
}

-- 机场（左上／右上／右下／左下）与停机垫
local APRT = {{15, 16}, {150, 16}, {150, 151}, {15, 151}}
local function apc(p) return APRT[p][1] + 45, APRT[p][2] + 45 end
local PAD = {}
for p = 1, 4 do
  local cx, cy = apc(p)
  PAD[p] = {
    {cx - 20, cy - 20}, {cx + 20, cy - 20},
    {cx - 20, cy + 20}, {cx + 20, cy + 20},
  }
end

-- 中心终点区（3×3 格，四色三角各居一侧），完赛机收纳位
local GCX, GCY = 127.5, 128.5
local GOALB = {{113, 128.5}, {127.5, 114}, {142, 128.5}, {127.5, 143}}
local GSLOT = {{-5, -5}, {5, -5}, {-5, 5}, {5, 5}}

local function ccx(cx) return OX + cx * CS + CS / 2 end
local function ccy(cy) return OY + cy * CS + CS / 2 end

-- 位置 → 像素中心（pos：-1 机场／0-50 环／51-56 终点道／57 中心）
local function pos_xy(p, pos, k, slot)
  if pos < 0 then
    return PAD[p][k][1], PAD[p][k][2]
  elseif pos == GOAL then
    local b = GOALB[p]
    return b[1] + GSLOT[slot or 1][1], b[2] + GSLOT[slot or 1][2]
  elseif pos <= 50 then
    local c = RING[(START0[p] + pos) % 52 + 1]
    return ccx(c[1]), ccy(c[2])
  else
    local c = HOME[p][pos - 50]
    return ccx(c[1]), ccy(c[2])
  end
end

local function ring0_of(p, pos) return (START0[p] + pos) % 52 end
local function own_color(p, pos) return pos <= 50 and ring0_of(p, pos) % 4 == p - 1 end

-- ================================================================ 精灵（程序化 bake，SPEC §2.3）

-- 设计坐标：机头朝东的顶视小飞机（16×16）
local function tri_in(x, y, ax, ay, bx, by, cx, cy)
  local d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by)
  local d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy)
  local d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay)
  local neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
  local pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
  return not (neg and pos)
end

local function segd(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 0 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local qx, qy = ax + dx * t, ay + dy * t
  return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

local function plane_solid(x, y)
  if x >= 3.5 and x <= 12.6 and y >= 6.8 and y <= 9.2 then return true end      -- 机身
  if x >= 12.6 and x <= 15 and abs(y - 8) <= (15 - x) * 0.62 + 0.35 then return true end -- 机头
  if tri_in(x, y, 10.2, 7.2, 3.2, 2.5, 4.0, 7.5) then return true end          -- 上主翼
  if tri_in(x, y, 10.2, 8.8, 3.2, 13.5, 4.0, 8.5) then return true end         -- 下主翼
  if tri_in(x, y, 4.0, 7.4, 1.2, 4.6, 1.8, 7.7) then return true end           -- 上尾翼
  if tri_in(x, y, 4.0, 8.6, 1.2, 11.4, 1.8, 8.3) then return true end          -- 下尾翼
  return false
end

local function plane_shade(p, x, y)
  local cp = PC[p]
  local hx, hy = x - 11.3, y - 8
  if hx * hx + hy * hy < 1.35 then return 7 end                    -- 座舱白点
  if x > 13.1 then return cp[2] end                                -- 机头暗
  if segd(x, y, 3.2, 2.5, 4.0, 7.5) < 0.8 then return cp[2] end    -- 上翼后缘
  if segd(x, y, 3.2, 13.5, 4.0, 8.5) < 0.8 then return cp[2] end   -- 下翼后缘
  if x < 1.7 then return cp[2] end                                 -- 尾缘
  if x >= 4 and x <= 11 and y < 7.6 then return cp[4] end          -- 机身顶高光
  return cp[1]
end

-- 瓦片 1..16：色 p（1-4）× 朝向 d（0 东／1 南／2 西／3 北）
local function bake_planes()
  for p = 1, 4 do
    for d = 0, 3 do
      local id = 1 + (p - 1) * 4 + d
      local base = id * 256
      for y = 0, 15 do
        for x = 0, 15 do
          local dx, dy = x, y
          if d == 1 then dx, dy = y, 15 - x
          elseif d == 2 then dx, dy = 15 - x, 15 - y
          elseif d == 3 then dx, dy = 15 - y, x end
          local c = nil
          if plane_solid(dx, dy) then
            c = plane_shade(p, dx, dy)
          elseif plane_solid(dx + 1, dy) or plane_solid(dx - 1, dy)
            or plane_solid(dx, dy + 1) or plane_solid(dx, dy - 1) then
            c = 1 -- 深色描边（色 0 为精灵透明，用近黑 1）
          end
          poke(base + y * 16 + x, c or 0)
        end
      end
    end
  end
end

local function plane_tile(p, face) return 1 + (p - 1) * 4 + (face % 4) end

local function draw_plane(p, face, x, y, s)
  local id = plane_tile(p, face)
  sspr((id % 16) * 16, flr(id / 16) * 16, 16, 16,
       flr(x - s / 2), flr(y - s / 2), s, s)
end

-- ================================================================ 音频（SPEC §5.2 布局）

local function u8(a, v) poke(a, v % 256) end

local function init_sfx(id, notes, wave, vol, speed, eff)
  local base = 0x060000 + id * 112
  u8(base, speed or 2)
  u8(base + 1, #notes)
  for i = 0, 31 do
    local a = base + 16 + i * 3
    if i < #notes then
      u8(a, notes[i + 1])
      u8(a + 1, wave * 16 + vol)
      u8(a + 2, eff or 0)
    else
      u8(a, 0)
      u8(a + 1, 0)
    end
  end
end

local function init_all_sfx()
  init_sfx(0, {38, 0, 42, 0}, 15, 7, 1)                 -- 掷骰哗啦
  init_sfx(1, {44, 31, 25}, 11, 11, 2)                  -- 骰子定格
  init_sfx(2, {26, 38, 50, 62}, 5, 8, 2)                -- 起飞爬升
  init_sfx(3, {74}, 3, 5, 1)                            -- 逐格嘀嗒
  init_sfx(4, {52, 64, 70}, 6, 8, 1)                    -- 同色跳跃
  init_sfx(5, {22, 34, 46, 58, 70}, 9, 8, 2)            -- 捷径飞跃
  init_sfx(6, {52, 40, 28, 16}, 15, 12, 1)              -- 撞机
  init_sfx(7, {61, 65, 68, 73}, 4, 10, 2)               -- 到达终点
  init_sfx(8, {61, 0, 61, 0, 61, 0, 65, 0, 68, 0, 65, 0, 68, 0, 73, 73, 73, 0, 0}, 4, 11, 3) -- 胜利
  init_sfx(9, {72}, 3, 6, 1)                            -- 界面滴答
  init_sfx(10, {58, 53, 49, 44}, 0, 8, 3)               -- 被撞返航
  init_sfx(11, {76, 83}, 10, 8, 2)                      -- 奖励再掷
  init_sfx(12, {35, 0, 35, 0, 35, 35, 35, 35}, 13, 9, 2) -- 三连六警告

  -- BGM：C 大调轻快回旋（C・Am・F・G），八小节两段 Pattern 循环
  -- 旋律（ORGAN）／贝斯（BASS）／琶音垫（TRIANGLE）各 2 条 32 步 SFX，speed 4 同步
  local mel_a = {
    53, 0, 56, 58, 61, 0, 58, 56,  58, 0, 56, 53, 49, 0, 53, 56,
    54, 0, 58, 61, 65, 0, 63, 61,  56, 0, 60, 63, 60, 56, 54, 0,
  }
  local mel_b = {
    53, 0, 56, 58, 61, 0, 63, 65,  65, 63, 61, 58, 56, 0, 58, 60,
    61, 58, 54, 0, 54, 58, 61, 0,  63, 60, 56, 0, 56, 60, 63, 0,
  }
  local roots = {25, 22, 18, 20}
  local chords = {{49, 53, 56}, {45, 49, 53}, {42, 45, 49}, {44, 48, 51}}
  local bass_a, bass_b, arp_a, arp_b = {}, {}, {}, {}
  for half = 1, 2 do
    local tb = half == 1 and bass_a or bass_b
    local ta = half == 1 and arp_a or arp_b
    for b = 1, 4 do
      local r = roots[b]
      local bar = {r, 0, r, 0, r, 0, r + 7, 0}
      for i = 1, 8 do tb[#tb + 1] = bar[i] end
      local c = chords[b]
      local abar = {0, c[1], 0, c[2], 0, c[3], 0, c[2]}
      for i = 1, 8 do ta[#ta + 1] = abar[i] end
    end
  end
  init_sfx(20, mel_a, 6, 9, 4)
  init_sfx(21, mel_b, 6, 9, 4)
  init_sfx(22, bass_a, 11, 11, 4)
  init_sfx(23, bass_b, 11, 11, 4)
  init_sfx(24, arp_a, 0, 5, 4)
  init_sfx(25, arp_b, 0, 5, 4)
  -- Pattern 0（BEGIN）／1（END）循环；ch4-6 为音乐通道
  local p0, p1 = 0x063800, 0x063810
  u8(p0 + 4, 21) u8(p0 + 5, 23) u8(p0 + 6, 25) u8(p0 + 8, 1)
  u8(p1 + 4, 22) u8(p1 + 5, 24) u8(p1 + 6, 26) u8(p1 + 8, 2)
end

-- ================================================================ 全局状态

local G = {
  mode = "title", t = 0,
  humans = 1,
  stars = {},
  P = {},                 -- P[p] = {pos, face, slot, human}
  cur = 1, streak = 0, extra = false,
  phase = "roll", phase_t = 0,
  dice = 1, dface = 1,
  mov = {}, msel = 1, holdd = nil, holdt = 0,
  mv = nil,               -- 本步移动上下文
  banner = nil,           -- {txt, col, t}
  anims = {}, parts = {},
  shake = 0, fw_t = 0, end_t = 0,
  games = 0, wins = {0, 0, 0, 0}, music_on = true,
  ranking = {},
}

local ANIMS, PARTS = G.anims, G.parts
local OV = {} -- 动画视觉覆盖：["p:k"] = {x,y,f,s}

local function note(txt, col, dur) G.banner = {txt = txt, col = col or 7, t = dur or 70} end
local function ov_set(p, k, x, y, f, s) OV[p .. ":" .. k] = {x = x, y = y, f = f, s = s} end
local function ov_del(p, k) OV[p .. ":" .. k] = nil end

local function count_goal(p)
  local n = 0
  for k = 1, 4 do if G.P[p].pos[k] == GOAL then n = n + 1 end end
  return n
end

-- ================================================================ 规则核心

-- 落点结算（AI 评估与执行共用同一函数，保证永远一致）
-- 返回 {final, launched, fly, jump, caps, direct, from}
local function resolve_landing(p, k, d)
  local pos = G.P[p].pos[k]
  local launched = pos < 0
  local direct
  if launched then
    direct = 0
  else
    local t = pos + d
    direct = t > GOAL and 114 - t or t -- 超出中心则回退
  end
  local final, fly, jump = direct, false, false
  if not launched and final <= 50 then
    if final == FLY_SRC then
      final, fly = FLY_DST, true
    elseif own_color(p, final) and final + 4 <= 50 then
      final, jump = final + 4, true
    end
  end
  local caps = 0
  if final <= 50 then
    local r0 = ring0_of(p, final)
    for q = 1, 4 do
      if q ~= p then
        for k2 = 1, 4 do
          local p2 = G.P[q].pos[k2]
          if p2 >= 0 and p2 <= 50 and ring0_of(q, p2) == r0 then caps = caps + 1 end
        end
      end
    end
  end
  return {final = final, launched = launched, fly = fly, jump = jump,
          caps = caps, direct = direct, from = pos}
end

-- 落点危险度：敌方 1-6 步可追及的子数（含敌方起飞点压境）
local function threat(p, ring0)
  local cnt = 0
  for q = 1, 4 do
    if q ~= p then
      local near_launch = false
      for k = 1, 4 do
        local p2 = G.P[q].pos[k]
        if p2 >= 0 and p2 <= 50 then
          local dist = (ring0 - ring0_of(q, p2)) % 52
          if dist >= 1 and dist <= 6 and p2 + dist <= 50 then cnt = cnt + 1 end
        elseif p2 < 0 then
          near_launch = true
        end
      end
      if near_launch and ring0 == START0[q] then cnt = cnt + 1 end
    end
  end
  return cnt
end

-- AI 启发式评分：撞机 > 恰到终点 > 飞跃 > 起飞 > 跳跃 > 进度 > 危险规避
local function eval_move(p, k, d)
  local r = resolve_landing(p, k, d)
  local sc = r.final * 0.6
  if r.final == GOAL then sc = sc + 130 end
  sc = sc + r.caps * 80
  if r.launched then sc = sc + 36 end
  if r.fly then sc = sc + 48 end
  if r.jump then sc = sc + 16 end
  if not r.launched and r.final < r.from then sc = sc - 20 end -- 回退浪费
  if r.final <= 50 then
    sc = sc - threat(p, ring0_of(p, r.final)) * 13
    local own = 0
    for k2 = 1, 4 do
      local p2 = G.P[p].pos[k2]
      if k2 ~= k and p2 >= 0 and p2 <= 50
        and ring0_of(p, p2) == ring0_of(p, r.final) then
        own = own + 1
      end
    end
    sc = sc - own * 4 -- 轻微避免叠子
  end
  return sc
end

local function ai_pick()
  local best, bi = -1e9, 1
  for i, k in ipairs(G.mov) do
    local sc = eval_move(G.cur, k, G.dice)
    if sc > best then best, bi = sc, i end
  end
  return bi
end

local function movable(p, d)
  local out = {}
  for k = 1, 4 do
    local pos = G.P[p].pos[k]
    if pos == -1 then
      if d == 6 then out[#out + 1] = k end
    elseif pos < GOAL then
      out[#out + 1] = k
    end
  end
  return out
end

-- ================================================================ 粒子与演员

local function add_part(x, y, vx, vy, g, life, c)
  PARTS[#PARTS + 1] = {x = x, y = y, vx = vx, vy = vy, g = g, life = life, c = c}
end

local function burst(x, y, n, cols, sp)
  for _ = 1, n do
    local a = rnd(1)
    local v = rnd(0.3, 1) * (sp or 2)
    add_part(x, y, cos(a) * v, sin(a) * v, 0.06, 30 + flr(rnd(30)),
      cols[flr(rnd(#cols)) + 1])
  end
end

local function firework()
  burst(30 + rnd(196), 30 + rnd(120), 26, {7, 31, 30, 42, 57, 58, 41, 34}, 2.4)
end

local function add_actor(a) ANIMS[#ANIMS + 1] = a end

local function bez(ax, ay, bx, by, cx, cy, u)
  local w = 1 - u
  return w * w * ax + 2 * w * u * bx + u * u * cx,
         w * w * ay + 2 * w * u * by + u * u * cy
end

local function dir4(dx, dy)
  if abs(dx) > abs(dy) then return dx > 0 and 0 or 2 end
  return dy > 0 and 1 or 3
end

-- 逐格步行（含终点回退）：plan 为逐个途经的位置
local function actor_walk(p, k, from, plan, fin)
  local a = {i = 1, t = 0, stepf = 6}
  local x0, y0 = pos_xy(p, from, k)
  local x1, y1 = x0, y0
  a.up = function(self)
    self.t = self.t + 1
    if self.i > #plan then
      G.P[p].pos[k] = fin
      ov_del(p, k)
      return true
    end
    if self.t == 1 then
      local nx, ny = pos_xy(p, plan[self.i], k)
      G.P[p].face[k] = dir4(nx - x0, ny - y0)
      sfx(3)
      x1, y1 = nx, ny
    end
    local u = self.t / self.stepf
    ov_set(p, k, x0 + (x1 - x0) * u, y0 + (y1 - y0) * u, G.P[p].face[k], 13)
    if self.t >= self.stepf then
      self.t = 0
      self.i = self.i + 1
      x0, y0 = x1, y1
    end
    return false
  end
  add_actor(a)
end

-- 贝塞尔弧线飞行（起飞／飞跃共用）：途经中心方向并抬升，trail 画尾迹
local function actor_arc(p, k, ax, ay, bx, by, dur, snd, trail, fin, face_to)
  local a = {t = 0}
  local mx, my = (ax + bx) / 2, (ay + by) / 2
  local cx, cy = mx * 0.7 + GCX * 0.3, my * 0.7 + GCY * 0.3 - 22
  if snd then sfx(snd) end
  a.up = function(self)
    self.t = self.t + 1
    local u = self.t / dur
    local x, y = bez(ax, ay, cx, cy, bx, by, u)
    local x2, y2 = bez(ax, ay, cx, cy, bx, by, min(1, u + 0.04))
    ov_set(p, k, x, y, face_to or dir4(x2 - x, y2 - y), 13)
    if trail and self.t % 2 == 0 then
      add_part(x, y, 0, 0, 0, 12, PC[p][4])
    end
    if self.t >= dur then
      G.P[p].pos[k] = fin
      if face_to then G.P[p].face[k] = face_to end
      ov_del(p, k)
      return true
    end
    return false
  end
  add_actor(a)
end

-- 同色跳跃：短促滑移＋起伏
local function actor_jump(p, k, ax, ay, bx, by, fin)
  local a = {t = 0, dur = 14}
  sfx(4)
  a.up = function(self)
    self.t = self.t + 1
    local u = self.t / self.dur
    local hop = sin(u) * 6
    local x = ax + (bx - ax) * u
    local y = ay + (by - ay) * u - hop
    ov_set(p, k, x, y, dir4(bx - ax, by - ay), 13)
    if self.t % 2 == 0 then add_part(x, y + 4, 0, 0, 0, 10, PC[p][4]) end
    if self.t >= self.dur then
      G.P[p].pos[k] = fin
      ov_del(p, k)
      return true
    end
    return false
  end
  add_actor(a)
end

-- 被撞返航：旋转缩小的抛物线归巢
local function actor_return(p, k, ax, ay)
  local pad = PAD[p][k]
  local a = {t = 0, dur = 42}
  local mx, my = (ax + pad[1]) / 2, (ay + pad[2]) / 2 - 34
  sfx(10)
  a.up = function(self)
    self.t = self.t + 1
    local u = self.t / self.dur
    local x, y = bez(ax, ay, mx, my, pad[1], pad[2], u)
    local s = 13 - abs(sin(u)) * 6
    ov_set(p, k, x, y, flr(u * 8) % 4, s)
    if self.t % 3 == 0 then add_part(x, y, 0, 0.1, 0, 10, PC[p][2]) end
    if self.t >= self.dur then
      G.P[p].face[k] = LDIR[p]
      ov_del(p, k)
      return true
    end
    return false
  end
  add_actor(a)
end

local function actor_delay(dur)
  local a = {t = 0, dur = dur}
  a.up = function(self)
    self.t = self.t + 1
    return self.t >= self.dur
  end
  add_actor(a)
end

-- ================================================================ 回合状态机

local function next_active()
  for _ = 1, 4 do
    G.cur = G.cur % 4 + 1
    if count_goal(G.cur) < 4 then return end
  end
end

local function end_turn(extra)
  if extra then
    G.extra = true
    sfx(11)
  else
    G.extra = false
    G.streak = 0
    next_active()
  end
  G.phase = "roll"
  G.phase_t = 0
  G.mov = {}
end

local function begin_move(i)
  local p, k = G.cur, G.mov[i]
  local r = resolve_landing(p, k, G.dice)
  local m = {p = p, k = k, r = r, stage = "walk", capped = false}
  G.mv = m
  G.phase = "move"
  G.phase_t = 0
  if r.launched then
    m.stage = "launch"
    local ax, ay = PAD[p][k][1], PAD[p][k][2]
    local bx, by = pos_xy(p, 0, k)
    actor_arc(p, k, ax, ay, bx, by, 26, 2, true, 0, LDIR[p])
  else
    -- 逐步计划：走到直接落点（超出中心则先到中心再折返）
    local pos, d = r.from, G.dice
    local plan = {}
    local t = pos + d
    if t <= GOAL then
      for x = pos + 1, t do plan[#plan + 1] = x end
    else
      for x = pos + 1, GOAL do plan[#plan + 1] = x end
      for x = GOAL - 1, 114 - t, -1 do plan[#plan + 1] = x end
    end
    actor_walk(p, k, pos, plan, r.direct)
  end
end

local function settle_now(m)
  local p = m.p
  if m.r.final <= 50 then
    local r0 = ring0_of(p, m.r.final)
    local lx, ly = pos_xy(p, m.r.final, m.k)
    local hit = 0
    for q = 1, 4 do
      if q ~= p then
        for k2 = 1, 4 do
          local p2 = G.P[q].pos[k2]
          if p2 >= 0 and p2 <= 50 and ring0_of(q, p2) == r0 then
            hit = hit + 1
            local qx, qy = pos_xy(q, p2, k2)
            G.P[q].pos[k2] = -1
            actor_return(q, k2, qx, qy)
          end
        end
      end
    end
    if hit > 0 then
      m.capped = true
      sfx(6)
      G.shake = 10
      burst(lx, ly, 16, {7, PC[p][1], PC[p][2], 62}, 2.2)
      note(NAME[p] .. "方撞回 " .. hit .. " 架敌机！", 62, 70)
      m.stage = "capwait"
      return
    end
  end
  m.stage = "post"
end

local function post_move(m)
  local p = m.p
  if m.r.final == GOAL then
    local gx, gy = pos_xy(p, GOAL, m.k, G.P[p].slot[m.k])
    sfx(7)
    burst(gx, gy, 18, {7, 31, 30, PC[p][4]}, 1.8)
    note(NAME[p] .. "方飞机到达终点！", PC[p][1], 70)
    if count_goal(p) == 4 then
      -- 冠军诞生：写战绩、放烟花、进结算
      G.ranking[#G.ranking + 1] = p
      G.games = G.games + 1
      G.wins[p] = G.wins[p] + 1
      dset(0, G.games)
      dset(p, G.wins[p])
      fflush()
      music(-1, 300)
      sfx(8)
      G.phase = "celebrate"
      G.phase_t = 0
      G.fw_t = 0
      return
    end
    actor_delay(26)
  else
    actor_delay(12)
  end
  m.stage = "pause"
end

-- move 阶段推进：动画清空后逐步解析落点
local function advance_move()
  local m = G.mv
  if m.stage == "launch" or m.stage == "walk" then
    if not m.r.launched and m.r.direct <= 50 then
      if m.r.direct == FLY_SRC then
        m.stage = "fly"
        local p = m.p
        local ax, ay = pos_xy(p, FLY_SRC, m.k)
        local bx, by = pos_xy(p, FLY_DST, m.k)
        actor_arc(p, m.k, ax, ay, bx, by, 32, 5, true, FLY_DST)
        return
      elseif m.r.jump then
        m.stage = "jump"
        local p = m.p
        local ax, ay = pos_xy(p, m.r.direct, m.k)
        local bx, by = pos_xy(p, m.r.final, m.k)
        actor_jump(p, m.k, ax, ay, bx, by, m.r.final)
        return
      end
    end
    settle_now(m)
  elseif m.stage == "fly" or m.stage == "jump" then
    settle_now(m)
  elseif m.stage == "capwait" or m.stage == "post" then
    post_move(m)
  elseif m.stage == "pause" then
    end_turn(G.dice == 6 or m.capped)
  end
end

local function resolve_roll()
  if G.dice == 6 then
    G.streak = G.streak + 1
    if G.streak >= 3 then
      note("三连六！" .. NAME[G.cur] .. "方本回合作废", 62, 90)
      sfx(12)
      G.phase = "void"
      G.phase_t = 0
      return
    end
  else
    G.streak = 0
  end
  G.mov = movable(G.cur, G.dice)
  if #G.mov == 0 then
    note(NAME[G.cur] .. "方没有可动的飞机", 9, 60)
    G.phase = "nomove"
    G.phase_t = 0
  else
    G.phase = "select"
    G.phase_t = 0
    G.msel = 1
    G.holdd = nil
  end
end

local function do_roll()
  G.dice = flr(rnd(6)) + 1
  G.dface = flr(rnd(6)) + 1
  G.phase = "rollanim"
  G.phase_t = 0
  sfx(0)
end

local function start_game()
  G.mode = "play"
  G.P = {}
  for p = 1, 4 do
    G.P[p] = {
      pos = {-1, -1, -1, -1},
      face = {LDIR[p], LDIR[p], LDIR[p], LDIR[p]},
      slot = {1, 2, 3, 4},
      human = p <= G.humans,
    }
  end
  G.cur = 1
  G.streak = 0
  G.extra = false
  G.phase = "roll"
  G.phase_t = 0
  G.mov = {}
  G.mv = nil
  G.banner = nil
  G.ranking = {}
  for key in pairs(OV) do OV[key] = nil end
  for i = #ANIMS, 1, -1 do ANIMS[i] = nil end
  for i = #PARTS, 1, -1 do PARTS[i] = nil end
  G.shake = 0
  note(NAME[1] .. "方先行，掷 6 起飞", 7, 80)
end

local function to_title()
  G.mode = "title"
  G.t = 0
  if G.music_on then music(0, 334, 0x70) end
end

-- ================================================================ 更新

local AI_ROLL_T, AI_SEL_T = 16, 10
local DICEF = 34

local function update_play()
  local ph = G.P[G.cur]
  if btnp(11) then to_title() return end
  if btnp(10) then
    G.music_on = not G.music_on
    dset(5, G.music_on and 0 or 1)
    fflush()
    if G.music_on then music(0, 334, 0x70) else music(-1, 200) end
  end

  local st = G.phase
  if st == "roll" then
    if ph.human then
      if btnp(4) then do_roll() end
    else
      G.phase_t = G.phase_t + 1
      if G.phase_t >= AI_ROLL_T then do_roll() end
    end

  elseif st == "rollanim" then
    G.phase_t = G.phase_t + 1
    if G.phase_t % 6 == 0 then sfx(0) end
    if G.phase_t % 3 == 0 and G.phase_t < DICEF - 7 then G.dface = flr(rnd(6)) + 1 end
    if G.phase_t >= DICEF - 7 then G.dface = G.dice end
    if G.phase_t >= DICEF then
      sfx(1)
      G.phase = "postroll"
      G.phase_t = 0
      if G.dice == 6 then
        if G.streak == 1 then
          note("掷出 6！再掷 6 将作废", 62, 70)
        else
          note("掷出 6！", PC[G.cur][1], 55)
        end
      end
    end

  elseif st == "postroll" then
    G.phase_t = G.phase_t + 1
    if G.phase_t >= 12 then resolve_roll() end

  elseif st == "select" then
    if ph.human then
      local function shift(d)
        G.msel = ((G.msel - 1 + d) % #G.mov) + 1
        sfx(9)
      end
      if btnp(0) or btnp(2) then
        G.holdd = btnp(0) and 0 or 2
        G.holdt = 0
        shift(-1)
      elseif btnp(1) or btnp(3) then
        G.holdd = btnp(1) and 1 or 3
        G.holdt = 0
        shift(1)
      elseif G.holdd and btn(G.holdd) then
        G.holdt = G.holdt + 1
        if G.holdt > 12 and G.holdt % 5 == 0 then
          shift(G.holdd < 2 and -1 or 1)
        end
      else
        G.holdd = nil
      end
      if btnp(4) then
        begin_move(G.msel)
      elseif btnp(5) then
        note(NAME[G.cur] .. "方放弃移动", 9, 55)
        G.phase = "skipwait"
        G.phase_t = 0
      end
    else
      G.phase_t = G.phase_t + 1
      if G.phase_t >= AI_SEL_T then begin_move(ai_pick()) end
    end

  elseif st == "move" then
    if #ANIMS == 0 then advance_move() end

  elseif st == "void" then
    G.phase_t = G.phase_t + 1
    if G.phase_t >= 85 then end_turn(false) end

  elseif st == "nomove" or st == "skipwait" then
    G.phase_t = G.phase_t + 1
    if G.phase_t >= 55 then end_turn(st == "nomove" and G.dice == 6) end

  elseif st == "celebrate" then
    G.phase_t = G.phase_t + 1
    G.fw_t = G.fw_t - 1
    if G.fw_t <= 0 then
      firework()
      G.fw_t = 12
    end
    if G.phase_t >= 220 then
      G.mode = "end"
      G.end_t = 0
    end
  end
end

local function update_title()
  if btnp(0) or btnp(2) then
    G.humans = (G.humans - 2) % 4 + 1
    sfx(9)
  elseif btnp(1) or btnp(3) then
    G.humans = G.humans % 4 + 1
    sfx(9)
  end
  if btnp(4) or btnp(11) then
    sfx(7)
    start_game()
  end
  if btnp(10) then
    G.music_on = not G.music_on
    dset(5, G.music_on and 0 or 1)
    fflush()
    if G.music_on then music(0, 334, 0x70) else music(-1, 200) end
  end
end

function _update()
  G.t = G.t + 1
  if G.shake > 0 then G.shake = G.shake - 1 end
  if G.banner then
    G.banner.t = G.banner.t - 1
    if G.banner.t <= 0 then G.banner = nil end
  end
  -- 粒子
  for i = #PARTS, 1, -1 do
    local pa = PARTS[i]
    pa.x = pa.x + pa.vx
    pa.y = pa.y + pa.vy
    pa.vy = pa.vy + pa.g
    pa.life = pa.life - 1
    if pa.life <= 0 then table.remove(PARTS, i) end
  end
  -- 演员
  for i = #ANIMS, 1, -1 do
    if ANIMS[i]:up(ANIMS[i]) then table.remove(ANIMS, i) end
  end
  if G.mode == "title" then
    update_title()
  elseif G.mode == "play" then
    update_play()
  elseif G.mode == "end" then
    G.end_t = G.end_t + 1
    G.fw_t = G.fw_t - 1
    if G.fw_t <= 0 then
      firework()
      G.fw_t = 21
    end
    if btnp(4) or btnp(11) then
      sfx(9)
      to_title()
    end
  end
end

-- ================================================================ 绘制

-- 单格：底色＋暗描边＋上缘高光
local function draw_cell_base(cx, cy, cp)
  local x, y = OX + cx * CS, OY + cy * CS
  rectfill(x, y, CS, CS, cp[1])
  rect(x, y, CS, CS, cp[2])
  line(x + 1, y + 1, x + CS - 2, y + 1, cp[4])
end

local function chevron(x, y, d, c)
  if d == 0 then
    line(x - 3, y - 4, x + 2, y, c) line(x - 3, y + 4, x + 2, y, c)
  elseif d == 2 then
    line(x + 3, y - 4, x - 2, y, c) line(x + 3, y + 4, x - 2, y, c)
  elseif d == 1 then
    line(x - 4, y - 3, x, y + 2, c) line(x + 4, y - 3, x, y + 2, c)
  else
    line(x - 4, y + 3, x, y - 2, c) line(x + 4, y + 3, x, y - 2, c)
  end
end

local function draw_board()
  -- 底纹
  cls(51)
  fillp(0x1041)
  rectfill(0, 0, 256, 256, 52 * 256 + 51)
  fillp()

  -- 机场
  for p = 1, 4 do
    local ax, ay = APRT[p][1], APRT[p][2]
    local cp = PC[p]
    rrectfill(ax + 2, ay + 2, 86, 86, 10, cp[3])
    rrect(ax + 2, ay + 2, 86, 86, 10, cp[2])
    if G.cur == p and G.phase ~= "celebrate" then
      if flr(G.t / 4) % 2 == 0 then
        rrect(ax - 1, ay - 1, 92, 92, 12, cp[1])
      end
    end
    print(NAME[p], ax + 6, ay + 4, cp[4])
    for k = 1, 4 do
      local pd = PAD[p][k]
      circfill(pd[1], pd[2], 8, cp[3])
      circ(pd[1], pd[2], 8, cp[2])
      line(pd[1] - 4, pd[2], pd[1] + 4, pd[2], cp[2])
      line(pd[1], pd[2] - 4, pd[1], pd[2] + 4, cp[2])
    end
  end

  -- 环形跑道（含起飞格／终点入口／飞行格标记）
  for i = 1, 52 do
    local r0 = i - 1
    local c = RING[i]
    local cp = PC[(i - 1) % 4 + 1]
    local owner_start, owner_entry, owner_fly = nil, nil, nil
    for p = 1, 4 do
      if START0[p] == r0 then owner_start = p end
      if (START0[p] + 50) % 52 == r0 then owner_entry = p end
      if (START0[p] + FLY_SRC) % 52 == r0 then owner_fly = p end
    end
    if owner_start then
      -- 起飞格：亮底＋白箭头
      rectfill(OX + c[1] * CS, OY + c[2] * CS, CS, CS, cp[4])
      rect(OX + c[1] * CS, OY + c[2] * CS, CS, CS, cp[2])
      chevron(ccx(c[1]), ccy(c[2]), LDIR[owner_start], 7)
    else
      draw_cell_base(c[1], c[2], cp)
      if owner_entry then
        chevron(ccx(c[1]), ccy(c[2]), LDIR[owner_entry], 7)
      end
    end
    if owner_fly then
      -- 己色飞行格：白色虚线角框＋迷你飞机
      local x, y = OX + c[1] * CS, OY + c[2] * CS
      for t = 1, CS - 2, 2 do
        pset(x + t, y + 1, 7)
        pset(x + t, y + CS - 2, 7)
        pset(x + 1, y + t, 7)
        pset(x + CS - 2, y + t, 7)
      end
      draw_plane(owner_fly, LDIR[owner_fly], ccx(c[1]), ccy(c[2]), 9)
    end
  end

  -- 终点跑道
  for p = 1, 4 do
    local cp = PC[p]
    for j = 1, 6 do
      local c = HOME[p][j]
      draw_cell_base(c[1], c[2], cp)
      chevron(ccx(c[1]), ccy(c[2]), LDIR[p], cp[4])
    end
  end

  -- 中心终点：四色三角拼合的终点广场
  rectfill(105, 106, 45, 45, 14)
  rect(105, 106, 45, 45, 7)
  trifill(105, 106, 105, 151, GCX, GCY, PC[1][2])
  trifill(105, 106, 150, 106, GCX, GCY, PC[2][2])
  trifill(150, 106, 150, 151, GCX, GCY, PC[3][2])
  trifill(105, 151, 150, 151, GCX, GCY, PC[4][2])
  trifill(106, 107, 106, 150, GCX, GCY, PC[1][1])
  trifill(106, 107, 149, 107, GCX, GCY, PC[2][1])
  trifill(149, 107, 149, 150, GCX, GCY, PC[3][1])
  trifill(106, 150, 149, 150, GCX, GCY, PC[4][1])
  print("✽", 120, 121, 31)

  -- 飞行捷径虚线走廊
  for p = 1, 4 do
    local a = RING[(START0[p] + FLY_SRC) % 52 + 1]
    local b = RING[(START0[p] + FLY_DST) % 52 + 1]
    local ax, ay = ccx(a[1]), ccy(a[2])
    local bx, by = ccx(b[1]), ccy(b[2])
    local n = flr(sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) / 5)
    for i = 0, n do
      if i % 2 == 0 then
        local u = i / max(n, 1)
        pset(ax + (bx - ax) * u, ay + (by - ay) * u, PC[p][4])
      end
    end
  end
end

-- 棋子（含叠放偏移、动画覆盖、完赛收纳）
local function draw_planes()
  -- 选中高亮环与落点预览（画在棋子下层）
  if G.phase == "select" and G.P[G.cur].human then
    local k = G.mov[G.msel]
    if k then
      local p = G.cur
      local o = OV[p .. ":" .. k]
      local x, y
      if o then
        x, y = o.x, o.y
      else
        x, y = pos_xy(p, G.P[p].pos[k], k)
      end
      if flr(G.t / 3) % 2 == 0 then circ(x, y, 8, 7) end
      local r = resolve_landing(p, k, G.dice)
      local gx, gy = pos_xy(p, r.final, k)
      circ(gx, gy, 5 + flr(G.t / 8) % 2, 7)
      if r.fly then chevron(gx, gy - 8, 1, 31) end
    end
  end
  local cnt = {}
  for p = 1, 4 do
    local ph = G.P[p]
    if ph then
      for k = 1, 4 do
        local key = p .. ":" .. k
        local o = OV[key]
        if o then
          draw_plane(p, o.f, o.x, o.y, o.s)
        else
          local pos = ph.pos[k]
          local x, y
          local s = 13
          if pos == GOAL then
            x, y = pos_xy(p, GOAL, k, ph.slot[k])
            s = 9
          else
            x, y = pos_xy(p, pos, k)
            if pos >= 0 then
              local gk = p .. ":" .. pos
              cnt[gk] = (cnt[gk] or 0) + 1
              x = x + (cnt[gk] - 1) * 3
              y = y + (cnt[gk] - 1) * 3
            end
          end
          draw_plane(p, ph.face[k], x, y, s)
        end
      end
    end
  end
end

local function pip(x, y, c) circfill(x, y, 1, c) end

local function draw_dice_face(x, y, v, s, c)
  rrectfill(x - s / 2, y - s / 2, s, s, 3, 7)
  rrect(x - s / 2, y - s / 2, s, s, 3, 1)
  local h = s / 2 - 3
  if v == 1 then
    pip(x, y, c)
  elseif v == 2 then
    pip(x - h, y - h, c) pip(x + h, y + h, c)
  elseif v == 3 then
    pip(x, y, c) pip(x - h, y - h, c) pip(x + h, y + h, c)
  elseif v == 4 then
    pip(x - h, y - h, c) pip(x + h, y - h, c)
    pip(x - h, y + h, c) pip(x + h, y + h, c)
  elseif v == 5 then
    pip(x, y, c)
    pip(x - h, y - h, c) pip(x + h, y - h, c)
    pip(x - h, y + h, c) pip(x + h, y + h, c)
  else
    pip(x - h, y - h, c) pip(x - h, y, c) pip(x - h, y + h, c)
    pip(x + h, y - h, c) pip(x + h, y, c) pip(x + h, y + h, c)
  end
end

local function draw_dice()
  if G.phase == "celebrate" then return end
  local cx, cy = apc(G.cur)
  local v = G.dface
  local s = 17
  if G.phase == "rollanim" then
    s = 19 + flr(abs(sin(G.t * 0.2)) * 2)
    cx = cx + flr(rnd(3)) - 1
    cy = cy + flr(rnd(3)) - 1
  end
  local cp = PC[G.cur]
  rrectfill(cx - 13, cy - 13, 26, 26, 4, cp[3])
  rrect(cx - 13, cy - 13, 26, 26, 4, cp[2])
  draw_dice_face(cx, cy, v, s, 1)
end

local function draw_hud()
  rectfill(0, 0, 256, 16, 13)
  line(0, 15, 255, 15, 12)
  for p = 1, 4 do
    local x = 8 + (p - 1) * 60
    local cp = PC[p]
    rectfill(x, 4, 8, 8, cp[1])
    rect(x, 4, 8, 8, cp[2])
    local done = count_goal(p)
    local is_cur = G.cur == p
    local col = is_cur and 7 or 10
    if is_cur and flr(G.t / 4) % 2 == 0 then col = 31 end
    print(done .. "/4", x + 11, 0, col)
    local ph = G.P[p]
    if ph then
      if ph.human then print("人", x + 36, 0, 6) else print("机", x + 36, 0, 10) end
    end
  end
end

local function prompt_text()
  if G.banner then return nil end
  local p = G.P[G.cur]
  if not p then return nil end
  local nm = NAME[G.cur] .. "方"
  if not p.human then return nm .. "（电脑）行动中" end
  if G.phase == "roll" then
    if G.extra then return "奖励再掷！" .. nm .. " Ⓐ 掷骰" end
    return nm .. " Ⓐ 掷骰"
  elseif G.phase == "select" then
    return "⬅➡⬆⬇ 选机 Ⓐ 确认 Ⓑ 弃权"
  elseif G.phase == "rollanim" then
    return nm .. " 掷骰中"
  end
  return nil
end

local function draw_bottom()
  rectfill(0, 240, 256, 16, 13)
  line(0, 240, 255, 240, 12)
  if G.banner then
    local b = G.banner
    local bw = tw(b.txt) + 14
    rrectfill(128 - bw / 2, 118, bw, 20, 4, 14)
    rrect(128 - bw / 2, 118, bw, 20, 4, PC[G.cur][1])
    print(b.txt, 128 - tw(b.txt) / 2, 122, b.col)
  end
  local s = prompt_text()
  if s then print(s, (256 - tw(s)) / 2, 240, 7) end
end

local function draw_parts()
  for i = 1, #PARTS do
    local pa = PARTS[i]
    if pa.life > 6 or flr(pa.life / 2) % 2 == 0 then
      pset(pa.x, pa.y, pa.c)
    end
  end
end

local function big_text(s, x, y, c)
  print(s, x + 1, y + 1, 1)
  print(s, x - 1, y, 1)
  print(s, x + 1, y, 1)
  print(s, x, y - 1, 1)
  print(s, x, y + 1, 1)
  print(s, x, y, c)
end

-- ================================================================ 标题与结算

local function draw_title()
  cls(51)
  fillp(0x1041)
  rectfill(0, 0, 256, 256, 52 * 256 + 51)
  fillp()
  for i = 1, #G.stars do
    local st = G.stars[i]
    local twk = (flr(G.t / 20) + i) % 7 == 0
    pset(st[1], st[2], twk and 7 or st[3])
  end
  -- 环绕标题的四色机群（放大 26px）
  for p = 1, 4 do
    local a = G.t * 0.006 + (p - 1) * 0.25
    local x = 128 + cos(a) * 86
    local y = 88 + sin(a) * 44
    local x2 = 128 + cos(a + 0.04) * 86
    local y2 = 88 + sin(a + 0.04) * 44
    draw_plane(p, dir4(x2 - x, y2 - y), x, y, 26)
    if G.t % 4 == 0 then add_part(x, y, 0, 0, 0, 14, PC[p][4]) end
  end
  big_text("飞行棋", 128 - tw("飞行棋") / 2, 50, 31)
  print("FC-16 LUDO", 128 - tw("FC-16 LUDO") / 2, 70, 10)

  -- 玩家数选择
  local py = 118
  rrectfill(38, py, 180, 76, 6, 13)
  rrect(38, py, 180, 76, 6, 12)
  print("⬅➡ 玩家数", 128 - tw("⬅➡ 玩家数") / 2, py + 6, 7)
  big_text(tostring(G.humans), 76, py + 24, 31)
  print("人", 92, py + 28, 7)
  for p = 1, 4 do
    local x = 118 + (p - 1) * 24
    local cp = PC[p]
    rectfill(x - 9, py + 24, 18, 18, cp[3])
    rect(x - 9, py + 24, 18, 18, cp[2])
    draw_plane(p, LDIR[p], x, py + 33, 13)
    local lab = p <= G.humans and "人" or "机"
    print(lab, x - 4, py + 44, p <= G.humans and 7 or 10)
  end
  local gs = "战绩 " .. G.games .. " 局"
  print(gs, 128 - tw(gs) / 2, py + 60, 10)

  if flr(G.t / 20) % 2 == 0 then
    print("Ⓐ 开始游戏", 128 - tw("Ⓐ 开始游戏") / 2, 202, 31)
  end
  local ms = "Select 音乐：" .. (G.music_on and "开" or "关")
  print(ms, 128 - tw(ms) / 2, 220, 10)
  local rs = "掷6起飞・跳跃・飞跃・撞机"
  print(rs, 128 - tw(rs) / 2, 240, 10)
end

local function draw_end()
  fillp(0x5a5a)
  rectfill(0, 0, 256, 256, 14 * 256 + 51)
  fillp()
  local w = G.ranking[1]
  local ws = NAME[w] .. "方夺冠！"
  big_text(ws, 128 - tw(ws) / 2, 44, PC[w][4])

  -- 名次：冠军之后按完赛架数与总进度排
  local function prog(p)
    local s, g = 0, 0
    for k = 1, 4 do
      local pos = G.P[p].pos[k]
      if pos == GOAL then
        g = g + 1
        s = s + GOAL
      elseif pos > 0 then
        s = s + pos
      end
    end
    return g, s
  end
  local order = {}
  for p = 1, 4 do
    if p ~= w then order[#order + 1] = p end
  end
  table.sort(order, function(a, b)
    local ga, sa = prog(a)
    local gb, sb = prog(b)
    if ga ~= gb then return ga > gb end
    if sa ~= sb then return sa > sb end
    return a < b
  end)
  rrectfill(48, 78, 160, 88, 8, 13)
  rrect(48, 78, 160, 88, 8, 12)
  print("冠军", 66, 86, 31)
  print(NAME[w] .. "方 4/4", 104, 86, PC[w][4])
  for i, p in ipairs(order) do
    local g = prog(p)
    local y = 106 + (i - 1) * 18
    print("第" .. (i + 1), 60, y, 7)
    draw_plane(p, LDIR[p], 116, y + 8, 13)
    print(NAME[p] .. "方 " .. g .. "/4", 132, y, PC[p][4])
  end
  if flr(G.t / 20) % 2 == 0 then
    print("Ⓐ 回到标题", 128 - tw("Ⓐ 回到标题") / 2, 176, 31)
  end
  local gs = "累计 " .. G.games .. " 局"
  print(gs, 128 - tw(gs) / 2, 196, 10)
end

function _draw()
  if G.mode == "title" then
    draw_title()
    draw_parts()
    return
  end
  if G.shake > 0 then
    camera(flr(rnd(5)) - 2, flr(rnd(5)) - 2)
  else
    camera(0, 0)
  end
  draw_board()
  draw_planes()
  draw_dice()
  draw_hud()
  draw_bottom()
  draw_parts()
  if G.mode == "end" then
    camera(0, 0)
    draw_end()
  end
end

-- ================================================================ 初始化

function _init()
  bake_planes()
  init_all_sfx()
  local scols = {10, 11, 12, 48}
  for i = 1, 46 do
    G.stars[i] = {flr(rnd(4, 252)), flr(rnd(4, 250)), scols[i % 4 + 1]}
  end
  -- dget 恒为 Lua 浮点（Q16.16 解包），| 0 转回整数，拼接显示才不会变成 "0.0"
  G.games = flr(dget(0)) | 0
  for p = 1, 4 do G.wins[p] = flr(dget(p)) | 0 end
  G.music_on = dget(5) == 0
  if G.music_on then music(0, 500, 0x70) end
end
