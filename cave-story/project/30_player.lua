-- 30_player.lua —— 玩家（库特）：移动、跳跃、射击、受击、动画

plr = nil

function new_player(tx, ty, dir)
  return {
    x = (tx * 16 + 8) * SUB,
    y = (ty * 16 + 8) * SUB,
    vx = 0, vy = 0,
    dir = dir or 1,            -- -1 左 / 1 右
    up = false, down = false,
    on_ground = false,
    life = 3, max_life = 3,
    shock = 0,                 -- 受击无敌帧
    anim = 0,                  -- 行走动画计数
    xp_timer = 0,
    weapon = nil,              -- {id=2, level=1..3, exp=0}
  }
end

function give_weapon(id, level)
  if plr.weapon and plr.weapon.id == id then return end
  plr.weapon = { id = id, level = level or 1, exp = 0 }
  sfx(SFX.levelup)
  caret_spawn(plr.x, plr.y - 10 * SUB, "level", 0)
end

local function add_xp(n)
  local w = plr.weapon
  if not w then return end
  w.exp = w.exp + n
  local lt = WEAPON.level_table
  if w.level < 3 and w.exp >= lt[w.level] then
    w.level = w.level + 1
    w.exp = 0
    sfx(SFX.levelup)
    caret_spawn(plr.x, plr.y - 10 * SUB, "level", 0)
  elseif w.level >= 3 then
    w.exp = 0
  end
  plr.xp_timer = 30
end

function plr_damage(dmg)
  if plr.shock > 0 or plr.life <= 0 then return end
  sfx(SFX.hurt)
  plr.shock = 128
  plr.vy = -0x400
  plr.life = plr.life - dmg
  if plr.life <= 0 then
    plr.life = 0
    G.dead_t = 100
    sfx(SFX.die)
    for i = 1, 24 do
      npc_spawn_smoke(plr.x + math.floor(rnd(-10, 10)) * SUB, plr.y + math.floor(rnd(-10, 10)) * SUB)
    end
  end
end

-- ─── 地图碰撞 ───────────────────────────────────────────────

local function cell_solid(cx, cy)
  local t = mget(cx, cy)
  return fget(t, 0)
end

-- 移动后的探针检测：横向
local function collide_x(e, l, r, t, b)
  if e.vx > 0 then
    local cx = sar(e.x + r, 13)
    local rows = { sar(e.y - t + 256, 13), sar(e.y + b - 256, 13) }
    for i = 1, 2 do
      if cell_solid(cx, rows[i]) then
        e.x = lsl(cx, 13) - r
        e.vx = 0
        return
      end
    end
  elseif e.vx < 0 then
    local cx = sar(e.x - l, 13)
    local rows = { sar(e.y - t + 256, 13), sar(e.y + b - 256, 13) }
    for i = 1, 2 do
      if cell_solid(cx, rows[i]) then
        e.x = lsl(cx + 1, 13) + l
        e.vx = 0
        return
      end
    end
  end
end

local function collide_y(e, l, r, t, b)
  e.on_ground = false
  if e.vy > 0 then
    local cy = sar(e.y + b, 13)
    local cols = { sar(e.x - l + 256, 13), sar(e.x + r - 256, 13) }
    for i = 1, 2 do
      if cell_solid(cols[i], cy) then
        e.y = lsl(cy, 13) - b
        e.vy = 0
        e.on_ground = true
        return
      end
    end
  elseif e.vy < 0 then
    local cy = sar(e.y - t, 13)
    local cols = { sar(e.x - l + 256, 13), sar(e.x + r - 256, 13) }
    for i = 1, 2 do
      if cell_solid(cols[i], cy) then
        e.y = lsl(cy + 1, 13) + t
        e.vy = 0
        return
      end
    end
  end
end

-- 斜坡（sflags bit1..3 = 坡码 1..8；几何取自原版 test_hit_*_slope_*）
local function slope_at(e, l, r, t, b)
  local cx = sar(e.x, 13)
  local cy = sar(e.y + b, 13)
  local t0 = mget(cx, cy)
  local code = bit32.bor(fget(t0, 1) and 1 or 0, fget(t0, 2) and 2 or 0, fget(t0, 3) and 4 or 0)
  if code == 0 then return end
  local dx = e.x - lsl(cx, 13)
  local ty0 = lsl(cy, 13)
  local Q = 0x800
  local line
  if code == 5 then line = ty0 + dx // 2 - Q        -- 0x54 左升(整高)
  elseif code == 6 then line = ty0 + dx // 2 + Q    -- 0x55 左升(半高)
  elseif code == 7 then line = ty0 - dx // 2 + Q    -- 0x56 右升(半高)
  elseif code == 8 then line = ty0 - dx // 2 - Q    -- 0x57 右升(整高)
  end
  if line and e.y + b > line then
    e.y = line - b
    if e.vy > 0 then e.vy = 0 end
    e.on_ground = true
  end
end

-- 天花板斜坡（坡码 1..4）
local function ceil_slope(e, l, r, t, b)
  local cx = sar(e.x, 13)
  local cy = sar(e.y - t, 13)
  local t0 = mget(cx, cy)
  local code = bit32.bor(fget(t0, 1) and 1 or 0, fget(t0, 2) and 2 or 0, fget(t0, 3) and 4 or 0)
  if code == 0 or code > 4 then return end
  local dx = e.x - lsl(cx, 13)
  local ty0 = lsl(cy, 13)
  local Q = 0x800
  local line
  if code == 1 then line = ty0 - dx // 2 + Q
  elseif code == 2 then line = ty0 - dx // 2 - Q
  elseif code == 3 then line = ty0 + dx // 2 - Q
  elseif code == 4 then line = ty0 + dx // 2 + Q
  end
  if line and e.y - t < line then
    e.y = line + t
    if e.vy < 0 then e.vy = 0 end
  end
end

-- ─── 射击 ─────────────────────────────────────────────────

local function shoot()
  local w = plr.weapon
  if not w then return end
  if bullet_count_player() >= WEAPON.max_on_screen then return end
  local lvl = w.level
  local mx, my, dir
  if plr.up then
    mx = plr.dir * SUB
    my = -0x1000
    dir = "up"
  elseif plr.down and not plr.on_ground then
    mx = plr.dir * SUB
    my = 0x1000
    dir = "down"
  else
    mx = plr.dir * 0xc00
    my = 0x600
    dir = plr.dir < 0 and "left" or "right"
  end
  bullet_spawn(plr.x + mx, plr.y + my, dir, lvl)
  caret_spawn(plr.x + mx * 2, plr.y + my, "shoot", plr.dir)
  if lvl >= 3 then sfx(SFX.shoot3) else sfx(SFX.shoot) end
end

-- ─── 交互（↑ 键触发）───────────────────────────────────────

local function try_interact()
  local px0, py0 = plr.x - 28 * SUB, plr.y - 30 * SUB
  local px1, py1 = plr.x + 28 * SUB, plr.y + 30 * SUB
  local best, bd = nil, bit32.lshift(1, 30)
  local cand_n = 0
  for i = 1, #npcs do
    local n = npcs[i]
    if n.ev > 0 or n.t == 16 or n.t == 39 or n.t == 17 then
      cand_n = cand_n + 1
      local st = CS.stats[n.t]
      local dp = st and st.dp
      if dp then
        local x0, y0 = n.x - dp[1] * SUB, n.y - dp[2] * SUB
        local x1, y1 = n.x + dp[3] * SUB, n.y + dp[4] * SUB
        if x0 < px1 and x1 > px0 and y0 < py1 and y1 > py0 then
          local d = math.abs(n.x - plr.x) + math.abs(n.y - plr.y)
          if d < bd then best, bd = n, d end
        end
      end
    end
  end
  if best then
    G.interact_cd = 30
    G.interact_latch = true
    plr.dir = best.x >= plr.x and 1 or -1
    if best.t == 16 or best.t == 39 then
      G.prompt = "save"
      sfx(SFX.blip)
    elseif best.t == 17 then
      if plr.life < plr.max_life then
        plr.life = plr.max_life
        sfx(SFX.chest)
      end
    elseif best.ev > 0 then
      scr_run(best.ev)
    end
  end
end

-- ─── 主更新 ───────────────────────────────────────────────

function plr_update()
  if plr.life <= 0 then return end
  if plr.shock > 0 then plr.shock = plr.shock - 1 end
  if plr.xp_timer > 0 then plr.xp_timer = plr.xp_timer - 1 end

  local locked = scr_locks_player() or G.prompt or G.dead_t > 0
  local left, right, up, down = false, false, false, false
  local jump_p, shoot_p = false, false
  if not locked then
    left = dir("left")
    right = dir("right")
    up = dir("up")
    down = dir("down")
    jump_p = btnp("a") or btnp("x")
    shoot_p = btnp("b") or btnp("y")
  end
  plr.up = up
  plr.down = down

  if jump_p and plr.on_ground then
    plr.vy = -P.jump
    sfx(SFX.jump)
  end

  -- 水平加速 / 摩擦
  if left and not right then
    plr.dir = -1
    plr.vx = plr.vx - (plr.on_ground and P.dash_ground or P.dash_air)
    plr.vx = math.max(plr.vx, -P.max_move)
  elseif right and not left then
    plr.dir = 1
    plr.vx = plr.vx + (plr.on_ground and P.dash_ground or P.dash_air)
    plr.vx = math.min(plr.vx, P.max_move)
  elseif plr.on_ground then
    if plr.vx < 0 then
      plr.vx = math.min(plr.vx + P.resist, 0)
    else
      plr.vx = math.max(plr.vx - P.resist, 0)
    end
  end
  -- 地面走速上限 max_dash，空中保留惯性上限 max_move（原版 air_physics 语义）
  if plr.on_ground then
    plr.vx = mid(-P.max_dash, plr.vx, P.max_dash)
  else
    plr.vx = mid(-P.max_move, plr.vx, P.max_move)
  end

  -- 重力（上升按住跳 = 低重力）
  if plr.vy < 0 and (btn("a") or btn("x")) and not locked then
    plr.vy = plr.vy + P.gravity_air
  else
    plr.vy = plr.vy + P.gravity_ground
  end
  plr.vy = mid(-P.max_move, plr.vy, P.max_move)

  local l, t, r, b = PLR_HIT.l * SUB, PLR_HIT.t * SUB, PLR_HIT.r * SUB, PLR_HIT.b * SUB
  plr.x = plr.x + plr.vx
  collide_x(plr, l, r, t, b)
  plr.y = plr.y + plr.vy
  collide_y(plr, l, r, t, b)
  if plr.vy >= 0 then
    slope_at(plr, l, r, t, b)
  else
    ceil_slope(plr, l, r, t, b)
  end

  -- 行走动画
  if plr.on_ground and plr.vx ~= 0 then
    plr.anim = plr.anim + 1
  else
    plr.anim = 0
  end

  if shoot_p then shoot() end
  -- 交互：按住 ↑ 亦可触发；触发一次后需松开 ↑ 才重新武装（原版 interacted 标记语义）
  if G.interact_cd > 0 then
    G.interact_cd = G.interact_cd - 1
  elseif dir("up") and not locked then
    if not G.interact_latch then
      try_interact()
    end
  else
    G.interact_latch = false
  end
end

-- 绘制：MyChar 块内 16×16 帧，行 0=左 1=右
function plr_draw()
  if plr.life <= 0 then return end
  if plr.shock > 0 and sar(G.frame, 2) % 2 == 0 then return end -- 受击闪烁
  local row = plr.dir < 0 and 0 or 16
  local col
  if plr.on_ground and plr.vx == 0 then
    col = plr.up and 3 or 0
  elseif not plr.on_ground then
    col = plr.vy < 0 and 2 or 1
  else
    col = WALK_CYCLE[((plr.anim // 5) % 4) + 1]
    if plr.up then col = (col == 0) and 3 or col end
  end
  local a = CS.atlas.mychar[1]
  local sx = sar(plr.x, 9) - G.camx
  local sy = sar(plr.y, 9) - G.camy
  sspr(a[1] + col, a[2] + row, 16, 16, sx - 8, sy - 8)
end
