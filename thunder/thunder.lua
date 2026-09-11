-- 雷霆战机（FC-16）
-- 纵版弹幕射击：WASD 移动 / J 射击 / Start 暂停
-- 纯 Lua 卡带（不依赖精灵与地图段）：程序化几何绘制 + 芯片音效（§5.2 poke 写入）
-- Neo 霓虹风格：紫黑夜空 + 合成波网格 + 霓虹太阳，实体全部高亮描边发光
-- 波次递增：grunt → weaver → tank，每 5 波 boss（环形弹幕 + 瞄准三连）
-- 敌人概率掉落「P」火力强化（1→5 级，5 级追加双斜弹）/「♥」回血（生命上限 3）
-- 最高分经 dset 存档

function u8(a, v) poke(a, v % 256) end

-- ---------------------------------------------------------------- 合成器

-- 写一条 SFX（SPEC §5.2 v0.31：每条 112B = 头 16B + 32 步 × 3B）
-- notes: 音高表（MIDI 号 1–96）；wave 0–13 固件音色 / 14–15 噪声
function init_sfx(id, notes, wave, vol)
  local base = 0x060000 + id * 112
  u8(base, 2)        -- 速度：每步 2 帧
  u8(base + 1, #notes) -- 有效步数
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

-- 芯片音乐：BASS 低音（小调下行走进）+ ROUND 空灵旋律
function init_music()
  init_sfx(4, {33, 33, 31, 31, 36, 36, 34, 34, 33, 33, 29, 29, 31, 31, 34, 32}, 11, 11)
  init_sfx(5, {81, 0, 79, 0, 76, 0, 79, 0, 84, 0, 81, 0, 79, 0, 74, 0}, 8, 7)
  local mb = 0x063800
  u8(mb + 4, 5) u8(mb + 5, 6)
  u8(mb + 8, 3)
end

-- ---------------------------------------------------------------- 状态

local state = "title" -- title | play | pause | over
local t = 0
local stars = {}
local pbul, ebul, foes, drops, parts
local player, score, best, lives, power
local wave, spawn_timer, to_spawn, wave_clear, boss
local banner_txt, banner_t, over_t
local invuln, shoot_cd, new_best

-- 霓虹配色（ENDESGA-64 的 FC-16 固定索引，SPEC §2.2）
local C = {
  ground = 52, -- 深夜紫地平线地面
  line = 53,   -- 暗紫网格
  horizon = 55,-- 霓虹紫地平线
  fan = 48,    -- 放射线
  sun = { 55, 43, 30 }, -- 霓虹太阳圈层：紫 / 青 / 黄
}

-- 敌人类型：1 grunt（红，瞄准弹）/ 2 weaver（绿，蛇形 + 扇形三连）/ 3 tank（紫，双发慢弹）
local F = {
  [1] = { hp = 2, r = 8, sp = 1.0, sc = 50,  fire = 62 },
  [2] = { hp = 4, r = 8, sp = 0.7, sc = 100, fire = 55 },
  [3] = { hp = 10, r = 11, sp = 0.45, sc = 200, fire = 75 },
}

-- ---------------------------------------------------------------- 实体

function reset_game()
  score, lives, power, wave = 0, 3, 1, 1
  pbul, ebul, foes, drops, parts = {}, {}, {}, {}, {}
  boss = nil
  player = { x = 128, y = 216 }
  to_spawn, over_t = wave_def(1).n, 0
  wave_clear = false -- Lua 中 0 为真值，必须用 false 才能拦住首帧误判「本波已清」
  spawn_timer, banner_t = 60, 90
  banner_txt = "第 1 波"
  invuln, shoot_cd, new_best = 0, 0, false
end

function _init()
  local sc = { 45, 63, 8, 8 }
  for i = 1, 40 do
    stars[i] = { x = flr(rnd(1, 255)), y = flr(rnd(1, 128)), sp = 0.3 + rnd(1, 3) / 2, c = sc[(i % 4) + 1] }
  end
  best = dget(0) or 0
  -- 游戏音效走脉冲通道 ch0-3（音乐占 ch4-5，mask 15 时 ch4-7 全保留给音乐）
  init_sfx(0, {72, 84}, 4, 8)    -- 射击（激光上扫）
  init_sfx(1, {30, 20, 12}, 3, 14) -- 爆炸（下坠滑音）
  init_sfx(2, {60, 52, 44, 36}, 4, 12) -- 受击 / boss 警报
  init_sfx(3, {45, 50, 55, 60, 65}, 5, 9) -- 强化拾取
  init_sfx(6, {67, 79, 86}, 5, 9) -- 回血（三音上行）
  init_music()
  reset_game()
  state = "title"
end
-- ---------------------------------------------------------------- 波次
-- 难度曲线：第 1 波 6 架 / 间隔 64 帧，前段平缓；出敌间隔 4 波起 48 帧、
-- 8 波起 32 帧、12 波起 16 帧封顶；火力提前量按 min(wave,10) 封顶，
-- 弹速 20 波后不再增长。

function wave_def(w)
  return {
    n = 4 + w * 2,                       -- 敌机数量
    kinds = w < 2 and { 1 } or (w < 4 and { 1, 2 } or { 1, 2, 3 }),
    gap = max(16, 64 - w * 4),           -- 出敌间隔
    sp_mul = 1 + w * 0.06,               -- 速度增幅
    boss = w % 5 == 0,
  }
end

function spawn_foe(d)
  local k = d.kinds[flr(rnd(#d.kinds)) + 1] -- rnd(n) ∈ [0,n)，+1 得 1..#kinds
  local spec = F[k]
  foes[#foes + 1] = {
    kind = k, x = rnd(20, 236), y = -16,
    hp = spec.hp, r = spec.r,
    vy = spec.sp * d.sp_mul,
    vx = (rnd(1, 100) < 50 and -1 or 1) * 0.4,
    phase = rnd(1, 64) / 64,            -- 蛇形相位
    cd = spec.fire - flr(rnd(1, 30)),
    spec = spec,
  }
end

function spawn_boss()
  boss = {
    x = 128, y = -32, hp = 40 + wave * 15, hp0 = 0,
    r = 26, cd = 90, atk = 0, entered = false, phase = 1,
  }
  boss.hp0 = boss.hp
  sfx(2, 3) -- 入场警报（脉冲通道）
end

-- ---------------------------------------------------------------- 更新

function update_stars()
  for i = 1, #stars do
    local s = stars[i]
    s.y = s.y + s.sp * (state == "play" and 2 or 1)
    if s.y > 128 then s.y = s.y - 129 s.x = flr(rnd(1, 255)) end
  end
end

function update_player()
  local sp = 2.4
  if btn(0) then player.x = player.x - sp end
  if btn(1) then player.x = player.x + sp end
  if btn(2) then player.y = player.y - sp end
  if btn(3) then player.y = player.y + sp end
  player.x = mid(player.x, 12, 244)
  player.y = mid(player.y, 60, 244)

  if btn(4) and shoot_cd <= 0 then
    shoot_cd = 6
    sfx(0, 0)
    -- 火力 1–5 级：直弹 1→5 发；5 级追加两发斜弹
    for i = 1, power do
      local off = (i - (power + 1) / 2) * 7
      pbul[#pbul + 1] = { x = player.x + off, y = player.y - 10 }
    end
    if power >= 5 then
      pbul[#pbul + 1] = { x = player.x - 10, y = player.y - 2, dx = -0.9 }
      pbul[#pbul + 1] = { x = player.x + 10, y = player.y - 2, dx = 0.9 }
    end
  end
  if shoot_cd > 0 then shoot_cd = shoot_cd - 1 end
  if invuln > 0 then invuln = invuln - 1 end

  -- 玩家子弹
  for i = #pbul, 1, -1 do
    local b = pbul[i]
    b.y = b.y - 7
    b.x = b.x + (b.dx or 0)
    if b.y < -8 then table.remove(pbul, i) end
  end

  if btnp(11) then
    state = "pause"
    music(-1)
  end
end

function fire_foe(f)
  local sp = 1.4 + min(wave, 20) * 0.05
  if f.kind == 1 then
    -- 瞄准弹：atan2(dx,dy) 圈制，a=0 指 +x 轴、0.25 指 +y 轴
    local a = atan2(player.x - f.x, player.y - f.y)
    ebul[#ebul + 1] = { x = f.x, y = f.y + 8, vx = cos(a) * sp, vy = sin(a) * sp, c = 58 }
  elseif f.kind == 2 then
    -- 扇形三连
    local base = 0.25 + (rnd(1, 100) - 50) / 200
    for k = -1, 1 do
      local a = base + k * 0.05
      ebul[#ebul + 1] = { x = f.x, y = f.y + 8, vx = cos(a) * sp, vy = sin(a) * sp, c = 34 }
    end
  else
    -- 重甲双发慢弹
    local sp2 = sp * 0.7
    ebul[#ebul + 1] = { x = f.x - 8, y = f.y + 10, vx = 0, vy = sp2, c = 41 }
    ebul[#ebul + 1] = { x = f.x + 8, y = f.y + 10, vx = 0, vy = sp2, c = 41 }
  end
end

function boss_attack(b)
  b.atk = b.atk + 1
  local sp = 1.2 + min(wave, 20) * 0.04
  if b.atk % 3 == 0 then
    -- 环形八向
    for k = 0, 7 do
      local a = k / 8 + b.atk / 96
      ebul[#ebul + 1] = { x = b.x, y = b.y + 14, vx = cos(a) * sp, vy = sin(a) * sp, c = 44 }
    end
  end
  if b.atk % 2 == 0 then
    -- 瞄准三连
    local a0 = atan2(player.x - b.x, player.y - b.y)
    for k = -1, 1 do
      ebul[#ebul + 1] = { x = b.x, y = b.y + 14, vx = cos(a) * (sp + 0.4), vy = sin(a) * (sp + 0.4), c = 23 }
    end
  end
end

function update_foes()
  for i = #foes, 1, -1 do
    local f = foes[i]
    f.y = f.y + f.vy
    f.x = f.x + f.vx
    f.phase = f.phase + 0.02
    if f.kind == 2 then f.x = f.x + sin(f.phase) * 1.4 end
    if f.x < 12 or f.x > 244 then
      f.x = mid(f.x, 12, 244)
      f.vx = -f.vx
    end

    f.cd = f.cd - 1
    if f.cd <= 0 and f.y > 16 and f.y < 200 then
      fire_foe(f)
      f.cd = f.spec.fire - min(wave, 10) * 3
    end
    if f.y > 270 then table.remove(foes, i) end
  end

  if boss then
    local b = boss
    if not b.entered then
      b.y = b.y + 0.6
      if b.y >= 40 then b.entered = true end
    else
      local sway = b.phase == 2 and 1.6 or 1
      b.x = 128 + sin(t / 75) * 60 * sway
      b.cd = b.cd - 1
      if b.cd <= 0 then
        boss_attack(b)
        b.cd = (52 - min(wave, 10)) / sway
      end
    end
    -- 血量过半：狂暴二阶段（一次性的，回血也不回退）
    if boss.phase == 1 and boss.hp <= boss.hp0 / 2 then
      boss.phase = 2
      boss.atk = 0
      boss.cd = 30
      banner_txt = "狂暴模式！"
      banner_t = 90
      sfx(2, 3)
      ebul = {} -- 清场给玩家喘息
    end
  end

  -- 敌方子弹
  for i = #ebul, 1, -1 do
    local b = ebul[i]
    b.x = b.x + b.vx
    b.y = b.y + b.vy
    if b.x < -8 or b.x > 264 or b.y < -8 or b.y > 264 then table.remove(ebul, i) end
  end

  -- 掉落物：kind 1 = 火力强化（至 5 级），kind 2 = 回血（生命上限 3）
  for i = #drops, 1, -1 do
    local d = drops[i]
    d.y = d.y + 1
    if d.y > 256 then
      table.remove(drops, i)
    elseif abs(d.x - player.x) < 10 and abs(d.y - player.y) < 10 then
      table.remove(drops, i)
      if d.kind == 1 then
        power = min(5, power + 1)
        sfx(3, 3)
      else
        lives = min(3, lives + 1)
        sfx(6, 6)
      end
    end
  end

  -- 粒子
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.life = p.life - 1
    if p.life <= 0 then table.remove(parts, i) end
  end
end

function boom(x, y, c, n)
  for i = 1, n do
    local a = i / n
    local sp = 0.8 + rnd(1, 4)
    parts[#parts + 1] = {
      x = x, y = y, vx = cos(a) * sp, vy = sin(a) * sp,
      life = 16 + flr(rnd(1, 12)), c = c,
    }
  end
end

function check_hits()
  if state ~= "play" then return end
  local consumed = false
  for i = #pbul, 1, -1 do
    local b = pbul[i]
    consumed = false
    for j = #foes, 1, -1 do
      local f = foes[j]
      if abs(b.x - f.x) < f.r + 2 and abs(b.y - f.y) < f.r + 2 then
        table.remove(pbul, i)
        f.hp = f.hp - 1
        if f.hp <= 0 then
          table.remove(foes, j)
          score = score + f.spec.sc
          boom(f.x, f.y, 44, 8)
          sfx(1, 5)
          -- 掉落：火力未满级掉「P」，生命未满掉「♥」，两者独立判定
          local roll = rnd(1, 100)
          if power < 5 and roll <= 10 then
            drops[#drops + 1] = { x = f.x, y = f.y, kind = 1 }
          end
          if lives < 3 and roll > 50 and roll <= 58 then
            drops[#drops + 1] = { x = f.x, y = f.y + 14, kind = 2 }
          end
        end
        consumed = true
        break
      end
    end
    if not consumed and boss and abs(b.x - boss.x) < boss.r + 2 and abs(b.y - boss.y) < boss.r + 2 then
      table.remove(pbul, i)
      boss.hp = boss.hp - 1
      if boss.hp <= 0 then
        score = score + 500
        boom(boss.x, boss.y, 15, 16)
        boom(boss.x, boss.y, 44, 12)
        boss = nil
        wave_clear = true
        banner_txt = "第 " .. wave .. " 波 完成"
        banner_t = 90
        sfx(1, 6)
      end
    end
  end

  -- 敌方子弹 / 敌机 vs 玩家
  if invuln <= 0 and state == "play" then
    for i = #ebul, 1, -1 do
      local b = ebul[i]
      if abs(b.x - player.x) < 6 and abs(b.y - player.y) < 6 then
        table.remove(ebul, i)
        hurt_player()
        break
      end
    end
  end
  if invuln <= 0 and state == "play" then
    for j = #foes, 1, -1 do
      local f = foes[j]
      if abs(f.x - player.x) < f.r + 5 and abs(f.y - player.y) < f.r + 5 then
        table.remove(foes, j)
        boom(f.x, f.y, 44, 10)
        hurt_player()
        break
      end
    end
  end
end

function hurt_player()
  lives = lives - 1
  power = flr(max(1, power - 1)) -- 受击降一级火力，保底 1 级（max 返回浮点，取整）
  invuln = 90
  boom(player.x, player.y, 44, 10)
  sfx(2, 2)
  if lives <= 0 then
    state = "over"
    over_t = 0
    music(-1)
    if score > best then
      best = score
      new_best = true
      dset(0, best)
      fflush()
    end
  end
end

function update_play()
  if banner_t > 0 then banner_t = banner_t - 1 end

  update_player()
  if state ~= "play" then return end -- 暂停了

  -- 出怪：本波配额未耗尽时按间隔释放
  if to_spawn > 0 and not boss then
    spawn_timer = spawn_timer - 1
    if spawn_timer <= 0 then
      spawn_foe(wave_def(wave))
      to_spawn = to_spawn - 1
      spawn_timer = wave_def(wave).gap
    end
  end
  -- boss 波：小怪清空后入场
  if wave_def(wave).boss and not boss and to_spawn == 0 and #foes == 0 and not wave_clear then
    spawn_boss()
  end
  -- 普通波清空（或 boss 被击破后）：结算 → 下一波
  if not wave_def(wave).boss and to_spawn == 0 and #foes == 0 and not wave_clear then
    wave_clear = true
    banner_txt = "第 " .. wave .. " 波 完成"
    banner_t = 90
    score = score + 100 * wave
  end
  if wave_clear and banner_t == 0 then
    wave_clear = false
    wave = wave + 1
    to_spawn = wave_def(wave).n
    spawn_timer = 60
    banner_txt = "第 " .. wave .. " 波"
    banner_t = 90
  end

  update_foes()
  check_hits()
end

-- ---------------------------------------------------------------- 绘制

function draw_stars()
  for i = 1, #stars do
    local s = stars[i]
    pset(s.x, s.y, s.c)
  end
end

-- 合成波网格：地平线下方向下滚动的透视横格线 + 放射纵线
function draw_grid()
  rectfill(0, 128, 256, 128, C.ground)
  local off = flr((t * 0.6) % 18)
  for i = 0, 11 do
    line(0, 131 + i * 18 + off, 255, 131 + i * 18 + off, C.line)
  end
  line(0, 128, 255, 128, C.horizon) -- 霓虹地平线
  for k = -5, 5 do
    line(128 + k * 22, 128, 128 + k * 48, 256, C.fan)
  end
end

-- 霓虹太阳：右上空三层同心圆（黄芯 / 青 / 紫）+ 自下而上渐密的合成波切缝
function draw_sun()
  circfill(196, 56, 30, 30)
  circfill(196, 56, 21, 41)
  circfill(196, 56, 12, 48)
  for i = 1, 6 do
    local y = 56 + i * 3 -- 自上而下渐密的切缝
    rectfill(166, y, 60, i + 1, 0)
  end
end

function draw_bg()
  cls(0)
  draw_stars()
  draw_grid()
  draw_sun()
end

function draw_player()
  if state ~= "play" and state ~= "pause" then return end
  if invuln > 0 and flr(invuln / 4) % 2 == 1 then return end
  local x, y = flr(player.x), flr(player.y)
  circfill(x, y + 4, 12, 37)                       -- 青色光晕
  trifill(x - 8, y + 8, x + 8, y + 8, x, y - 10, 42)  -- 机身（霓虹青）
  rectfill(x - 1, y - 8, 2, 14, 7)                     -- 白色脊线
  trifill(x - 8, y + 8, x - 12, y + 12, x - 4, y + 9, 55) -- 左翼（霓虹紫）
  trifill(x + 8, y + 8, x + 12, y + 12, x + 4, y + 9, 55) -- 右翼（霓虹紫）
  local fl = flr(sin(t / 6) * 2)
  circfill(x, y + 11, 2 + fl, fl == 2 and 7 or 23) -- 尾焰脉动
end

function draw_foes()
  for i = 1, #foes do
    local f = foes[i]
    local x, y = flr(f.x), flr(f.y)
    if f.kind == 1 then
      circfill(x, y, 12, 62)                           -- 暗红光晕
      trifill(x - 8, y - 6, x + 8, y - 6, x, y + 8, 60)  -- 霓虹红三角（朝下）
      circfill(x, y - 2, 2, 22)
    elseif f.kind == 2 then
      circfill(x, y, 12, 36)                          -- 暗绿光晕
      trifill(x - 8, y - 8, x + 8, y - 8, x, y + 8, 34)  -- 霓虹绿菱形
      trifill(x - 8, y + 8, x + 8, y + 8, x, y - 8, 36)
      circfill(x, y, 2, 22)
    else
      circfill(x, y, 15, 21)                          -- 暗紫光晕
      rectfill(x - 11, y - 8, 22, 16, 55)             -- 霓虹紫重甲
      rectfill(x - 14, y - 4, 4, 8, 8)
      rectfill(x + 10, y - 4, 4, 8, 8)
      circfill(x, y, 3, 23)
    end
  end
  if boss then
    local b = boss
    local x, y = flr(b.x), flr(b.y)
    -- 二阶段：机体换红 + 眼点闪烁
    circfill(x, y, 36, b.phase == 2 and 61 or 53)    -- 光晕
    rrectfill(x - 26, y - 14, 52, 28, 6, b.phase == 2 and 60 or 55)
    rectfill(x - 20, y - 8, 40, 4, b.phase == 2 and 22 or 8)
    circfill(x - 12, y + 6, 4, b.phase == 2 and (flr(t / 8) % 2 == 0 and 7 or 60) or 23)
    circfill(x + 12, y + 6, 4, b.phase == 2 and (flr(t / 8) % 2 == 0 and 7 or 60) or 23)
    ovalfill(x, y - 2, 8, 6, 23)
  end
end

function draw_bullets()
  for i = 1, #pbul do
    local b = pbul[i]
    rectfill(flr(b.x) - 1, flr(b.y) - 4, 2, 8, 42)
    rectfill(flr(b.x) - 1, flr(b.y) - 4, 2, 2, 7)
  end
  for i = 1, #ebul do
    local b = ebul[i]
    circfill(flr(b.x), flr(b.y), 3, b.c)
    pset(flr(b.x), flr(b.y), 7)
  end
end

function draw_drops()
  for i = 1, #drops do
    local d = drops[i]
    local x, y = flr(d.x), flr(d.y)
    local fl = flr(sin(t / 20 + i) * 2)
    if d.kind == 1 then
      -- P：火力强化（霓虹黄底）
      rrectfill(x - 6, y - 6 + fl, 12, 12, 4, 30)
      print("P", x - 4, y - 4 + fl, 7)
    else
      -- ♥：回血（红色）
      rrectfill(x - 6, y - 6 + fl, 12, 12, 4, 61)
      print("♥", x - 4, y - 4 + fl, 7)
    end
  end
end

function draw_parts()
  for i = 1, #parts do
    local p = parts[i]
    pset(flr(p.x), flr(p.y), p.c)
  end
end

-- 霓虹标题：亮色正文 + 偏移暗色描边，模拟辉光
function neon_text(s, x, y, c)
  print(s, x + 1, y + 1, 11)
  print(s, x, y, c)
end

function draw_hud()
  print("得分 " .. score, 4, 4, 7)
  print("波次 " .. wave, 4, 22, 41)
  for i = 1, 3 do
    print("♥", 248 - i * 12, 4, i <= lives and 60 or 2)
  end
  print("火力 " .. power, 4, 34, 30)
  if banner_t > 0 then
    neon_text(banner_txt, flr((256 - tw(banner_txt)) / 2), 100, 7)
  end
  if boss then
    local w = flr(180 * boss.hp / boss.hp0)
    rectfill(38, 250, 180, 4, 15)
    if w > 0 then rectfill(38, 250, w, 4, boss.phase == 2 and 60 or 30) end
  end
end

function draw_title()
  neon_text("雷霆战机", flr((256 - tw("雷霆战机")) / 2), 56, 44)
  neon_text("NEON JET", flr((256 - tw("NEON JET")) / 2), 84, 60)
  if flr(t / 30) % 2 == 0 then
    neon_text("按 Start 开始", flr((256 - tw("按 Start 开始")) / 2), 140, 7)
  end
  print("WASD 移动　J 射击", flr((256 - tw("WASD 移动　J 射击")) / 2), 168, 10)
  print("最高 " .. best, flr((256 - tw("最高 " .. best)) / 2), 184, 10)
  draw_jet_preview()
end

function draw_jet_preview()
  local x, y = 128, 220 + flr(sin(t / 40) * 4)
  circfill(x, y + 4, 12, 37)
  trifill(x - 8, y + 8, x + 8, y + 8, x, y - 10, 42)
  rectfill(x - 1, y - 8, 2, 14, 7)
  trifill(x - 8, y + 8, x - 12, y + 12, x - 4, y + 9, 55)
  trifill(x + 8, y + 8, x + 12, y + 12, x + 4, y + 9, 55)
  circfill(x, y + 10, 2, 23)
end

function draw_over()
  rectfill(32, 96, 192, 64, 15)
  rect(32, 96, 192, 64, 55)
  print("游戏结束", flr((256 - tw("游戏结束")) / 2), 104, 60)
  print("得分 " .. score, flr((256 - tw("得分 " .. score)) / 2), 124, 7)
  if new_best and flr(t / 20) % 2 == 0 then
    print("新纪录！", flr((256 - tw("新纪录！")) / 2), 142, 23)
  end
end

function _draw()
  if state == "title" then
    draw_bg()
    draw_title()
  else
    draw_bg()
    draw_bullets()
    draw_drops()
    draw_foes()
    draw_player()
    draw_parts()
    draw_hud()
    if state == "pause" then
      rectfill(0, 116, 256, 24, 15)
      rect(0, 116, 256, 24, 41)
      print("已暂停", flr((256 - tw("已暂停")) / 2), 118, 7)
      print("按 Start 继续", flr((256 - tw("按 Start 继续")) / 2), 134, 20)
    end
    if state == "over" then
      draw_over()
    end
  end
end

-- ---------------------------------------------------------------- 帧循环

function _update()
  t = t + 1
  update_stars()
  if state == "title" then
    if btnp(11) then
      reset_game()
      state = "play"
      wave = 1
      music(0, 500, 48) -- ch4-5 交给音乐
    end
  elseif state == "play" then
    update_play()
  elseif state == "pause" then
    if btnp(11) then
      state = "play"
      music(0, 0, 48)
    end
  elseif state == "over" then
    over_t = over_t + 1
    if over_t > 60 and btnp(11) then
      state = "title"
    end
  end
end
