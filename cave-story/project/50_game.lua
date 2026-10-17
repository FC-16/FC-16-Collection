-- 50_game.lua —— 全局状态、关卡切换、相机、HUD、对话框、存档

G = {
  stage = 13,
  camx = 0, camy = 0,
  lookx = 0, looky = 0,
  fade = 0, fade_tgt = 0,
  frame = 0,
  dead_t = 0,
  prompt = nil,        -- "save"
  interact_cd = 0,
  interact_latch = false,
  items = {},
  title_t = 0,
}

function stage_switch(s, ev, tx, ty)
  G.stage = s
  npcs_spawn_for_stage()
  if tx then
    local mo = MAPD[s]
    plr.x = ((mo[1] + tx) * 16 + 8) * SUB
    plr.y = ((mo[2] + ty) * 16 + 8) * SUB
  end
  plr.vx, plr.vy = 0, 0
  update_camera(true)
  G.fade_tgt = 0
  if ev then
    scr_run(ev)
  end
end

function update_camera(snap)
  local d = MAPD[G.stage]
  local dims = CS.dims[G.stage]
  local wx, wy = d[1] * 16, d[2] * 16
  local ww, wh = dims[1] * 16, dims[2] * 16
  -- 视线前探
  local tx = 0
  if plr.vx > 0x100 then tx = 16 elseif plr.vx < -0x100 then tx = -16 end
  local ty = 0
  if plr.up then ty = -16 elseif plr.down and plr.on_ground then ty = 16 end
  if snap then G.lookx, G.looky = tx, ty
  else
    if G.lookx < tx then G.lookx = math.min(G.lookx + 1, tx) else G.lookx = math.max(G.lookx - 1, tx) end
    if G.looky < ty then G.looky = math.min(G.looky + 1, ty) else G.looky = math.max(G.looky - 1, ty) end
  end
  local cx = mid(wx, sar(plr.x, 9) - 128 + G.lookx, wx + ww - 256)
  local cy = mid(wy, sar(plr.y, 9) - 128 + G.looky, wy + wh - 256)
  if ww <= 256 then cx = wx + (ww - 256) // 2 end
  if wh <= 256 then cy = wy end
  G.camx, G.camy = cx, cy
end

-- ─── 存档 ─────────────────────────────────────────────────

-- 结构（SPEC §13）：{stage, x, y（像素）, max_life, life, weapon_level, weapon_exp, dir, flags}
function do_save()
  save({
    stage = G.stage,
    x = plr.x // 512,
    y = plr.y // 512,
    max_life = plr.max_life,
    life = plr.life,
    weapon_level = plr.weapon and plr.weapon.level or 0,
    weapon_exp = plr.weapon and plr.weapon.exp or 0,
    dir = plr.dir,
    flags = flsave(),
  })
end

-- 读出存档表；无存档或损坏返回 nil
local function save_data()
  local d = load()
  return type(d) == "table" and d or nil
end

-- 缺失或非数字字段按 0 处理
local function save_num(d, k)
  local v = d[k]
  return type(v) == "number" and v or 0
end

function has_save()
  local d = save_data()
  return d ~= nil and save_num(d, "stage") > 0
end

function load_save()
  local d = save_data() or {}
  if not plr then plr = new_player(0, 0, 1) end
  plr.max_life = save_num(d, "max_life")
  plr.life = save_num(d, "life")
  plr.dir = save_num(d, "dir") ~= 0 and save_num(d, "dir") or 1
  if save_num(d, "weapon_level") > 0 then
    plr.weapon = { id = 2, level = save_num(d, "weapon_level"), exp = save_num(d, "weapon_exp") }
  end
  flload(d.flags)
  G.items[2] = flget(322)
  G.stage = save_num(d, "stage")
  npcs_spawn_for_stage()
  plr.x = save_num(d, "x") * 512
  plr.y = save_num(d, "y") * 512
  plr.vx, plr.vy = 0, 0
  update_camera(true)
  G.fade_tgt = 0
end

-- ─── 每帧推进 ─────────────────────────────────────────────

function game_update()
  G.frame = G.frame + 1
  -- 淡出推进
  if G.fade < G.fade_tgt then
    G.fade = math.min(G.fade + 0.25, G.fade_tgt)
  elseif G.fade > G.fade_tgt then
    G.fade = math.max(G.fade - 0.25, G.fade_tgt)
  end

  scr_update()

  if G.dead_t > 0 then
    G.dead_t = G.dead_t - 1
    if G.dead_t == 40 then
      G.fade_tgt = 4
    elseif G.dead_t == 1 then
      if has_save() then
        load_save()
      else
        new_game()
      end
      G.fade_tgt = 0
    end
    carets_update()
    return
  end

  plr_update()
  npcs_update()
  bullets_update()
  carets_update()
  update_camera(false)

  -- 存档确认
  if G.prompt == "save" then
    if btnp("a") then
      do_save()
      sfx(SFX.save)
      G.prompt = nil
    elseif btnp("b") then
      G.prompt = nil
    end
  end
end

-- ─── 绘制 ─────────────────────────────────────────────────

local NPC_FRAME = {
  [16] = function(n) return (sar(G.frame, 3) % 8) + 1 end,
  [64] = function(n) return n.anim + (n.dir < 0 and 1 or 4) end,
  [65] = function(n) return n.anim + (n.dir > 0 and 5 or 1) end,
  [1] = function(n) return n.anim + 1 end,
  [4] = function(n) return (sar(n.a, 2) % 4) + 1 end,
  [211] = function(n) return (sar(n.x, 13) + sar(n.y, 13)) % 4 + 1 end,
}

local function draw_npcs()
  for i = 1, #npcs do
    local n = npcs[i]
    local rects = CS.atlas["npc" .. n.t]
    if rects then
      local idx = 1
      if NPC_FRAME[n.t] then
        idx = NPC_FRAME[n.t](n)
        idx = mid(1, idx, #rects)
      end
      local r = rects[idx]
      local sx = sar(n.x, 9) - G.camx - sar(r[3], 1)
      local sy = sar(n.y, 9) - G.camy - sar(r[4], 1)
      if n.t == 18 then sy = sy - 4 end
      sspr(r[1], r[2], r[3], r[4], sx, sy)
    end
  end
end

local function draw_bullets()
  for i = 1, #bullets do
    local b = bullets[i]
    local key = "b" .. (3 + b.lvl) .. ((b.vx ~= 0) and "h" or "v")
    local r = CS.atlas[key][1]
    sspr(r[1], r[2], r[3], r[4], sar(b.x, 9) - G.camx - 8, sar(b.y, 9) - G.camy - 8)
  end
end

local function draw_carets()
  for i = 1, #carets do
    local c = carets[i]
    if c.kind == "shoot" then
      local r = CS.atlas.caret_shoot[(sar(c.a, 2) % 4) + 1]
      local ox = c.dir < 0 and -12 or 4
      sspr(r[1], r[2], r[3], r[4], sar(c.x, 9) - G.camx - 8 + (c.vy ~= 0 and 0 or ox), sar(c.y, 9) - G.camy - 8)
    elseif c.kind == "diss" then
      local r = CS.atlas.caret_diss[(sar(c.a, 1) % 4) + 1]
      sspr(r[1], r[2], r[3], r[4], sar(c.x, 9) - G.camx - 4, sar(c.y, 9) - G.camy - 4)
    elseif c.kind == "level" and c.a < 80 then
      local r = CS.atlas.caret_level[(sar(c.a, 3) % 2) + 1]
      sspr(r[1], r[2], r[3], r[4], sar(c.x, 9) - G.camx - 28, sar(c.y, 9) - G.camy - 24)
    end
  end
end

local function draw_map_layer()
  if CS.bg.bkblue ~= nil and G.stage == 11 then
    -- 咪咪村：bkBlue 平铺背景（自由区 0 起，64KB=256×256 索引）
    memcpy(0x0B0000, 0x0C63A0, 65536)
  else
    cls(CS.bg.bk0_color or 0)
  end
  local tx, ty = sar(G.camx, 4), sar(G.camy, 4)
  map(tx, ty, -(G.camx % 16), -(G.camy % 16), 17, 17, 0)
end

local function draw_msg()
  local m = scr.msg
  if not m then return end
  rectfill(6, 192, 244, 58, 0)
  rect(6, 192, 244, 58, 7)
  local y = 200
  local shown = m.chars
  for i = 1, #m.lines do
    local ln = m.lines[i]
    local take = mid(0, shown, #ln)
    if take > 0 then
      printw(ln:sub(1, take), 16, y, 7, 224)
    end
    shown = shown - #ln
    y = y + 12
    if shown <= 0 then break end
  end
  -- 等键闪烁箭头
  if scr.wait_key and sar(G.frame, 4) % 2 == 0 then
    print("▼", 236, 234, 7)
  end
end

local function draw_hud()
  -- 生命
  rect(5, 5, 52, 9, 7)
  rectfill(6, 6, 50, 7, 0)
  rectfill(6, 6, 50 * plr.life // plr.max_life, 7, 58)
  -- 武器等级
  if plr.weapon then
    print("Lv." .. plr.weapon.level, 6, 16, 7)
    local wexp = plr.weapon.exp
    local cap = plr.weapon.level >= 3 and WEAPON.level_table[3] or WEAPON.level_table[plr.weapon.level]
    rectfill(6, 26, 20 * math.min(1, wexp / cap), 2, 10)
  end
end

function game_draw()
  draw_map_layer()
  draw_npcs()
  plr_draw()
  draw_bullets()
  draw_carets()
  draw_hud()
  draw_msg()
  if G.prompt == "save" then
    rectfill(48, 92, 160, 56, 0)
    rect(48, 92, 160, 56, 7)
    printw("要在此记录吗？", 64, 102, 7, 128)
    print(btnicon("a") .. " 记录", 64, 124, 6)
    print(btnicon("b") .. " 取消", 150, 124, 6)
  end
  -- 淡出覆盖
  if G.fade > 0 then
    apply_fade(G.fade)
  end
  if G.fade >= 4 then
    rectfill(0, 0, 256, 256, 0)
    apply_fade(0)
  end
end
