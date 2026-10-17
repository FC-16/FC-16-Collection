-- 40_npc.lua —— 实体管理：布点生成、地图碰撞、AI、掉落与拾取

npcs = {}
bullets = {}
carets = {}

local SHOOTABLE = { [64] = true, [65] = true, [78] = true }

function npc_spawn_smoke(x, y)
  npcs[#npcs + 1] = {
    t = 4, x = x, y = y, vx = 0, vy = 0, ev = 0, fl = 0,
    anim = math.floor(rnd(4)) // 1, life = 1, dmg = 0, shock = 0, a = 0, on_ground = false,
  }
end

function npc_spawn_crystal(x, y, exp)
  local vx = math.floor(rnd(-0x200, 0x200)) // 1
  local vy = -math.floor(rnd(0, 0x400)) // 1
  npcs[#npcs + 1] = {
    t = 1, x = x, y = y, vx = vx, vy = vy, ev = 0, fl = 0,
    exp = exp, anim = math.floor(rnd(4)) // 1, life = 1, dmg = 0, shock = 0,
    a = 0, bounces = 0, on_ground = false, dir = 1,
  }
end

local function spawn_from_data()
  npcs = {}
  local list = CS.spawns[G.stage] or {}
  for i = 1, #list do
    local d = list[i]
    local ok = true
    if d.t == 15 then ok = not flget(d.fl)          -- 关闭的宝箱：开启后消失
    elseif d.t == 21 then ok = flget(d.fl)          -- 开启的宝箱：开启后出现
    end
    if ok then
      local st = CS.stats[d.t]
      local mo = MAPD[G.stage]
      npcs[#npcs + 1] = {
        t = d.t, ev = d.ev, fl = d.fl, bf = d.bf,
        x = ((mo[1] + d.x) * 16 + 8) * SUB, y = ((mo[2] + d.y) * 16 + 8) * SUB,
        vx = 0, vy = 0, dir = bit32.band(d.bf, 0x1000) ~= 0 and 1 or -1,
        life = st and st.life or 1, dmg = st and st.dmg or 0,
        invul = st and st.invul or false,
        shock = 0, anim = 0, a = 0, b = 0, on_ground = false,
      }
    end
  end
end

function npc_change_event(ev, typ)
  for i = 1, #npcs do
    if npcs[i].ev == ev then
      local st = CS.stats[typ]
      npcs[i].t = typ
      npcs[i].life = st and st.life or 1
      npcs[i].dmg = st and st.dmg or 0
      npcs[i].invul = st and st.invul or false
    end
  end
end

function npc_delete_event(ev)
  for i = #npcs, 1, -1 do
    if npcs[i].ev == ev then
      deli(npcs, i)
    end
  end
end

-- ─── 地图碰撞（与玩家同一套语义）─────────────────────────

local function cell_solid(cx, cy)
  local t = mget(cx, cy)
  return fget(t, 0)
end

local function npc_bounds(n)
  local st = CS.stats[n.t]
  local hb = st and st.hb or { 4, 4, 4, 4 }
  return hb[1] * SUB, hb[2] * SUB, hb[3] * SUB, hb[4] * SUB
end

local function collide_x(n, l, r, t, b)
  if n.vx > 0 then
    local cx = sar(n.x + r, 13)
    if cell_solid(cx, sar(n.y - t + 256, 13)) or cell_solid(cx, sar(n.y + b - 256, 13)) then
      n.x = lsl(cx, 13) - r
      n.vx = 0
      n.wall = 1
    end
  elseif n.vx < 0 then
    local cx = sar(n.x - l, 13)
    if cell_solid(cx, sar(n.y - t + 256, 13)) or cell_solid(cx, sar(n.y + b - 256, 13)) then
      n.x = lsl(cx + 1, 13) + l
      n.vx = 0
      n.wall = -1
    end
  end
end

local function collide_y(n, l, r, t, b)
  n.on_ground = false
  if n.vy > 0 then
    local cy = sar(n.y + b, 13)
    if cell_solid(sar(n.x - l + 256, 13), cy) or cell_solid(sar(n.x + r - 256, 13), cy) then
      n.y = lsl(cy, 13) - b
      n.vy = 0
      n.on_ground = true
    end
  elseif n.vy < 0 then
    local cy = sar(n.y - t, 13)
    if cell_solid(sar(n.x - l + 256, 13), cy) or cell_solid(sar(n.x + r - 256, 13), cy) then
      n.y = lsl(cy + 1, 13) + t
      n.vy = 0
    end
  end
end

-- ─── 掉落 / 死亡 ──────────────────────────────────────────

local function npc_die(n)
  local st = CS.stats[n.t]
  sfx(SFX.die)
  for i = 1, 3 do
    npc_spawn_smoke(n.x + math.floor(rnd(-6, 6)) * SUB, n.y + math.floor(rnd(-4, 4)) * SUB)
  end
  if st and st.exp > 0 then
    npc_spawn_crystal(n.x, n.y, st.exp)
  end
end

local function bullet_hits_npc(b)
  local br = 2 * SUB -- 子弹近似半径
  for i = 1, #npcs do
    local n = npcs[i]
    if SHOOTABLE[n.t] and not n.invul and n.shock <= 0 then
      local l, t, r, bo = npc_bounds(n)
      if math.abs(b.x - n.x) < br + l + r and math.abs(b.y - n.y) < br + t + bo then
        n.life = n.life - b.dmg
        n.shock = 30
        sfx(SFX.hit)
        caret_spawn(b.x, b.y, "diss", 0)
        if n.life <= 0 then
          npc_die(n)
          if n.t == 78 and n.ev > 0 then
            scr_run(n.ev)
          end
          deli(npcs, i)
        end
        return true
      end
    end
  end
  return false
end

-- ─── 各类型 AI ───────────────────────────────────────────

local function ai_critter(n)
  local dx = plr.x - n.x
  local dy = plr.y - n.y
  if n.a == 1 then
    if n.b < 8 then n.b = n.b + 1 end
    n.anim = 0
    if n.b >= 8 and math.abs(dx) < 0xe000 and math.abs(dy) < 0xa000 then
      n.anim = 1
    end
    if n.b >= 8 and math.abs(dx) < 0x8000 and dy > -0xa000 and dy < 0x6000 then
      n.a = 2
      n.b = 0
      n.anim = 0
    end
  elseif n.a == 2 then
    n.b = n.b + 1
    if n.b > 8 then
      n.a = 3
      n.anim = 2
      n.dir = dx < 0 and -1 or 1
      n.vx = n.dir * 0x100
      n.vy = -0x5ff
      sfx(SFX.critter)
    end
  elseif n.a == 3 then
    if n.on_ground and n.vy == 0 then
      n.vx = 0
      n.anim = 0
      n.b = 0
      n.a = 1
      sfx(SFX.thud)
    end
  end
  n.vy = math.min(n.vy + 0x40, 0x5ff)
  local l, t, r, bo = npc_bounds(n)
  n.x = n.x + n.vx
  collide_x(n, l, r, t, bo)
  n.y = n.y + n.vy
  collide_y(n, l, r, t, bo)
  if n.on_ground and n.vy >= 0 then
    slope_at_npc(n, l, r, t, bo)
  end
end

local function ai_bat(n)
  if n.a <= 1 then
    if n.a == 0 then
      n.a = 1
      n.b = math.floor(rnd(50)) // 1
    end
    n.b = n.b + 1
    if n.b >= 50 then
      n.a = 2
      n.b = 0
      n.vy = 0x300
    end
  elseif n.a == 2 then
    local dx = plr.x - n.x
    n.dir = dx < 0 and -1 or 1
    n.vx = n.dir * 0x100
    local dyt = plr.y - 0x1800 - n.y
    n.vy = n.vy + mid(-0x10, dyt // 16, 0x10)
    n.vy = mid(-0x300, n.vy, 0x300)
  end
  local l, t, r, bo = npc_bounds(n)
  n.x = n.x + n.vx
  collide_x(n, l, r, t, bo)
  n.y = n.y + n.vy
  collide_y(n, l, r, t, bo)
  n.anim = (n.anim + 1) % 3
end

local function ai_crystal(n)
  if n.a == 0 then
    n.a = 1
    n.anim = math.floor(rnd(4)) // 1
  end
  n.vy = math.min(n.vy + 0x2a, 0x5ff)
  local l, t, r, bo = 2 * SUB, 2 * SUB, 2 * SUB, 2 * SUB
  n.x = n.x + n.vx
  if n.vx < 0 and cell_solid(sar(n.x - l, 13), sar(n.y, 13)) then
    n.x = (sar(n.x - l, 13) + 1) * TILE + l
    n.vx = -n.vx
  elseif n.vx > 0 and cell_solid(sar(n.x + r, 13), sar(n.y, 13)) then
    n.x = sar(n.x + r, 13) * TILE - r
    n.vx = -n.vx
  end
  n.y = n.y + n.vy
  if n.vy > 0 and cell_solid(sar(n.x, 13), sar(n.y + bo, 13)) then
    n.y = sar(n.y + bo, 13) * TILE - bo
    sfx(SFX.bounce)
    n.vy = -0x280
    n.vx = n.vx * 2 // 3
    n.bounces = n.bounces + 1
  elseif n.vy < 0 and cell_solid(sar(n.x, 13), sar(n.y - t, 13)) then
    n.y = (sar(n.y - t, 13) + 1) * TILE + t
    n.vy = 0
  end
  if n.bounces > 2 then
    n.vy = n.vy - 0x100
  end
  n.anim = (n.anim + (n.dir > 0 and 1 or -1)) % 6
  -- 拾取
  if math.abs(plr.x - n.x) < 0xa00 + 4 * SUB and math.abs(plr.y - n.y) < 0xa00 + 6 * SUB then
    if plr.weapon then
      add_xp_pub(n.exp)
    end
    sfx(SFX.xp)
    deli(npcs, table_find_npc(n))
  end
end

local function ai_smoke(n)
  n.a = n.a + 1
  if n.a > 24 then
    del(npcs, n)
  end
end

local STATIC_TYPES = {
  [0] = true, [15] = true, [16] = true, [17] = true, [18] = true, [21] = true,
  [37] = true, [39] = true, [211] = true,
}
local VILLAGER = { [30] = true, [42] = true, [60] = true, [61] = true, [74] = true, [79] = true }

function npcs_update()
  for i = #npcs, 1, -1 do
    local n = npcs[i]
    if n.shock > 0 then n.shock = n.shock - 1 end
    if n.t == 64 then
      ai_critter(n)
    elseif n.t == 65 then
      ai_bat(n)
    elseif n.t == 1 then
      ai_crystal(n)
    elseif n.t == 4 then
      ai_smoke(n)
    end
    -- 接触伤害
    if n.dmg > 0 and plr.life > 0 and plr.shock <= 0 and G.dead_t <= 0 then
      local pl, pt, pr, pb = PLR_HIT.l * SUB, PLR_HIT.t * SUB, PLR_HIT.r * SUB, PLR_HIT.b * SUB
      local l, t, r, bo = npc_bounds(n)
      if math.abs(n.x - plr.x) < l + r and math.abs(n.y - plr.y) < t + pb then
        plr_damage(n.dmg)
      end
    end
  end
end

-- ─── 子弹 ────────────────────────────────────────────────

function bullet_spawn(x, y, dir, lvl)
  local spec = WEAPON.bullets[lvl]
  local b = {
    x = x, y = y, lvl = lvl, dmg = spec.dmg, life_t = spec.life_t,
    vx = 0, vy = 0,
  }
  if dir == "left" then b.vx = -WEAPON.speed
  elseif dir == "right" then b.vx = WEAPON.speed
  elseif dir == "up" then b.vy = -WEAPON.speed
  else b.vy = WEAPON.speed
  end
  bullets[#bullets + 1] = b
end

function bullet_count_player()
  return #bullets
end

function bullets_update()
  for i = #bullets, 1, -1 do
    local b = bullets[i]
    b.x = b.x + b.vx
    b.y = b.y + b.vy
    b.life_t = b.life_t - 1
    local dead = b.life_t <= 0
    if not dead then
      local cx, cy = sar(b.x, 13), sar(b.y, 13)
      if fget(mget(cx, cy), 0) then
        dead = true
        caret_spawn(b.x, b.y, "diss", 0)
      end
    end
    if not dead and bullet_hits_npc(b) then
      dead = true
    end
    if dead then
      deli(bullets, i)
    end
  end
end

function bullet_hits_npc_pub(b)
  return bullet_hits_npc(b)
end

-- ─── 特效 ────────────────────────────────────────────────

function caret_spawn(x, y, kind, dir)
  carets[#carets + 1] = { x = x, y = y, kind = kind, dir = dir, a = 0 }
end

function carets_update()
  for i = #carets, 1, -1 do
    local c = carets[i]
    c.a = c.a + 1
    local max = c.kind == "shoot" and 12 or (c.kind == "diss" and 8 or 80)
    if c.kind == "level" and c.a < 20 then
      c.y = c.y - SUB
    end
    if c.a > max then
      deli(carets, i)
    end
  end
end

-- 公共入口（player 层用）
function add_xp_pub(n)
  local w = plr.weapon
  if not w then return end
  w.exp = w.exp + n
  local lt = WEAPON.level_table
  if w.level < 3 and w.exp >= lt[w.level] then
    w.level = w.level + 1
    w.exp = 0
    sfx(SFX.levelup)
    caret_spawn(plr.x, plr.y - 10 * SUB, "level", 0)
  elseif w.level >= 3 and w.exp >= lt[3] then
    w.exp = lt[3]
  end
  plr.xp_timer = 30
end

function table_find_npc(n)
  for i = 1, #npcs do
    if npcs[i] == n then return i end
  end
  return #npcs
end

-- 斜坡（NPC 版：仅地板坡）
function slope_at_npc(n, l, r, t, b)
  local cx = sar(n.x, 13)
  local cy = sar(n.y + b, 13)
  local t0 = mget(cx, cy)
  local code = bit32.bor(fget(t0, 1) and 1 or 0, fget(t0, 2) and 2 or 0, fget(t0, 3) and 4 or 0)
  if code < 5 then return end
  local dx = n.x - lsl(cx, 13)
  local ty0 = lsl(cy, 13)
  local Q = 0x800
  local line
  if code == 5 then line = ty0 + dx // 2 - Q
  elseif code == 6 then line = ty0 + dx // 2 + Q
  elseif code == 7 then line = ty0 - dx // 2 + Q
  elseif code == 8 then line = ty0 - dx // 2 - Q
  end
  if line and n.y + b > line then
    n.y = line - b
    if n.vy > 0 then n.vy = 0 end
    n.on_ground = true
  end
end

function npcs_spawn_for_stage()
  spawn_from_data()
  bullets = {}
  carets = {}
end
