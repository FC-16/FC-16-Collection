-- 雷霆战机（FC-16）
-- 纵版弹幕射击：方向键 移动 / Ⓐ 射击 / Menu 暂停
-- 纯 Lua 卡带（不依赖精灵与地图段）：程序化几何绘制 + 芯片音效（§5.2 poke 写入）
-- Neo 霓虹风格：紫黑夜空 + 三层视差星空 + 合成波网格 + 霓虹太阳，实体全部高亮描边发光
-- 波次递增：grunt → weaver → tank，每 5 波 boss（环形弹幕 + 瞄准三连）
-- 敌人概率掉落「P」火力强化（1→5 级，5 级追加双斜弹）/「♥」回血（生命上限 3）
-- 最高分经 dset 存档

function u8(a, v) poke(a, v % 256) end

-- ---------------------------------------------------------------- 合成器

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

-- 写一条 SFX（SPEC §5.2：每条 144B = 头 16B + 32 步 × 4B）
-- notes: 音高表（旧固件 MIDI 号 1–96，0=休止）；wave 旧固件音色，经 WMAP 映射到新来源
function init_sfx(id, notes, wave, vol)
  local base = 0x0C0000 + id * 144
  poke2(base, 2 * 4)  -- 速度：旧每步 2 帧(60Hz) → 新 SPD 8 tick(240Hz)
  u8(base + 2, #notes) -- 有效步数
  for i = 0, 31 do
    local a = base + 16 + i * 4
    if i < #notes and notes[i + 1] > 0 then
      u8(a, notes[i + 1] - 1)
      u8(a + 1, WMAP[wave])
      u8(a + 2, vol)
      u8(a + 3, 0)
    else
      u8(a, 0) u8(a + 1, 0) u8(a + 2, 0) u8(a + 3, 0)
    end
  end
end

-- 芯片音乐：BASS 低音（小调下行走进）+ ROUND 空灵旋律
local MUSIC_BASE = 0x0C5380  -- MUSIC 区（SPEC §5.2）：+0 LEN，行 r 在 +32+r*32
function init_music()
  init_sfx(4, {33, 33, 31, 31, 36, 36, 34, 34, 33, 33, 29, 29, 31, 31, 34, 32}, 11, 11)
  init_sfx(5, {81, 0, 79, 0, 76, 0, 79, 0, 84, 0, 81, 0, 79, 0, 74, 0}, 8, 7)
  local mb = MUSIC_BASE + 32  -- 行 0
  for c = 0, 7 do u8(mb + c, 0xFF) end
  u8(mb + 4, 4) u8(mb + 5, 5)
  u8(mb + 16, 1) u8(mb + 17, 1)  -- LOOP_START / LOOP_BACK：单行自回环
  u8(MUSIC_BASE, 1)  -- 全表 LEN = 1 行
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
local hint_t -- 开局操作提示剩余帧数

-- 霓虹配色（ENDESGA-64 的 FC-16 固定索引，SPEC §2.2）
local C = {
  ground = 52, -- 深夜紫地平线地面
  line = 53,   -- 暗紫网格
  horizon = 55,-- 霓虹紫地平线
  fan = 48,    -- 放射线
  sun = { 55, 43, 30 }, -- 霓虹太阳圈层：紫 / 青 / 黄
}

-- 三层视差星空（纯装饰）：固定种子的局部 LCG 生成，_init 时一次成型，
-- 不动全局随机序列（敌机波次 / 掉落仍每局随机）；
-- 远层慢而暗、中层居中、近层快而亮大，竖向滚动下移模拟前进
local star_seed = 1
local function star_rnd()
  star_seed = (star_seed * 1103515245 + 12345) % 2147483648
  return star_seed / 2147483648
end
local STAR_LAYERS = {
  { n = 18, sp = 0.35, c = 8,  s = 1 }, -- 远层：暗弱小点
  { n = 12, sp = 0.85, c = 45, s = 1 }, -- 中层：中速中亮
  { n = 8,  sp = 1.7,  c = 7,  s = 2 }, -- 近层：快速亮大（2×2）
}

local function gen_stars()
  star_seed = 91
  stars = {}
  for _, L in ipairs(STAR_LAYERS) do
    for _ = 1, L.n do
      stars[#stars + 1] = {
        x = 1 + flr(star_rnd() * 254),
        y = 1 + flr(star_rnd() * 126),
        sp = L.sp, c = L.c, s = L.s,
      }
    end
  end
end

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
  hint_t = 200 -- 开局 3 秒余显示操作提示
end

function _init()
  gen_stars() -- 三层视差星空（固定种子，frame 0 即完整）
  best = dget(0) or 0
  -- 游戏音效走脉冲通道 ch0-3（音乐占 ch4-5，mask 15 时 ch4-7 全保留给音乐）
  init_waveforms()  -- 旧固件音色 → v0.177 自定义波形
  init_sfx(0, {72, 84}, 4, 8)    -- 射击（激光上扫）
  init_sfx(1, {30, 20, 12}, 3, 14) -- 爆炸（下坠滑音）
  init_sfx(2, {60, 52, 44, 36}, 4, 12) -- 受击 / boss 警报
  init_sfx(3, {45, 50, 55, 60, 65}, 5, 9) -- 强化拾取
  init_sfx(6, {67, 79, 86}, 5, 9) -- 回血（三音上行）
  init_music()
  reset_game()
  state = "splash" -- 开机封面，Ⓐ/Menu 或 90 帧后进 title
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
    if s.y > 128 then s.y = s.y - 128 end -- 出屏回顶循环平铺（x 保持，外观确定）
  end
end

function update_player()
  local sp = 2.4
  local dx = (dir(1) and 1 or 0) - (dir(0) and 1 or 0)
  local dy = (dir(3) and 1 or 0) - (dir(2) and 1 or 0)
  player.x = player.x + dx * sp
  player.y = player.y + dy * sp
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
    local a = atan2(player.x - b.x, player.y - b.y)
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
  if hint_t > 0 then hint_t = hint_t - 1 end

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
    if s.s > 1 then rectfill(s.x, s.y, 2, 2, s.c) else pset(s.x, s.y, s.c) end
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

-- 霓虹太阳：左下网格上三层同心圆（黄芯 / 青 / 紫）+ 自下而上渐密的合成波切缝
-- （沉在网格左下，避开中央大标题 / 左上 HUD / 顶部提示 / boss 血条，装饰 frame 0 即完整）
function draw_sun()
  circfill(32, 204, 30, 30)
  circfill(32, 204, 21, 41)
  circfill(32, 204, 12, 48)
  for i = 1, 6 do
    local y = 204 + i * 3 -- 自上而下渐密的切缝
    rectfill(2, y, 60, i + 1, 0)
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

-- 霓虹标题：亮色正文 + 偏移暗色描边，模拟辉光（scale 放大时描边加厚）
function neon_text(s, x, y, c, scale)
  local o = (scale or 1) > 1 and 2 or 1
  print(s, x + o, y + o, 11, scale)
  print(s, x, y, c, scale)
end

-- 居中横坐标（print scale 放大按倍数展宽）
local function cx(s, scale) return flr((256 - tw(s) * (scale or 1)) / 2) end

function draw_hud()
  print("得分 " .. score, 4, 4, 7)
  print("波次 " .. wave, 4, 22, 41)
  for i = 1, 3 do
    print("♥", 248 - i * 12, 4, i <= lives and 60 or 2)
  end
  print("火力 " .. power, 4, 34, 30)
  if hint_t > 0 and state == "play" then -- 开局头几秒的操作提示（btnicon）
    local h = btnicon("dpad") .. " 移动　" .. btnicon("a") .. " 射击　" .. btnicon("menu") .. " 暂停"
    print(h, cx(h), 4, 42)
  end
  if banner_t > 0 then
    neon_text(banner_txt, cx(banner_txt), 100, 7)
  end
  if boss then
    local w = flr(180 * boss.hp / boss.hp0)
    rectfill(38, 250, 180, 4, 15)
    if w > 0 then rectfill(38, 250, w, 4, boss.phase == 2 and 60 or 30) end
  end
end

-- 标题即封面：scale 3 大标题 + 霓虹太阳 / 星空装饰 + 一行稳定开始提示
function draw_title()
  neon_text("雷霆战机", cx("雷霆战机", 3), 68, 44, 3)
  neon_text("NEON JET", cx("NEON JET"), 124, 60)
  neon_text("按 " .. btnicon("a") .. " 开始", cx("按 " .. btnicon("a") .. " 开始"), 156, 7)
  print("最高 " .. best, cx("最高 " .. best), 178, 10)
  draw_jet_preview()
  print("FrostMiKu ・ FC-16", cx("FrostMiKu ・ FC-16"), 246, 22)
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

-- Splash：纯主视觉封面（0-90 帧）——战机大特写（4×）+ 双弹道，
-- 压三层星空合成波背景，零菜单零提示零战绩
function draw_splash()
  -- 双弹道：两道上行光束（青光白芯），压在机身与 logo 之后
  for i = -1, 1, 2 do
    local bx = 128 + i * 26
    rectfill(bx - 2, 0, 4, 116, 42)
    rectfill(bx - 1, 0, 2, 116, 7)
  end
  -- 战机大特写（draw_player 同款机体放大 4 倍）
  local x, y, s = 128, 152, 4
  circfill(x, y + 11 * s + flr(sin(t / 5) * 3), 2 * s + 3, 23) -- 尾焰脉动
  circfill(x, y + 4 * s, 12 * s, 37)                           -- 青色光晕
  trifill(x - 8 * s, y + 8 * s, x + 8 * s, y + 8 * s, x, y - 10 * s, 42)
  rectfill(x - s, y - 8 * s, 2 * s, 14 * s, 7)
  trifill(x - 8 * s, y + 8 * s, x - 12 * s, y + 12 * s, x - 4 * s, y + 9 * s, 55)
  trifill(x + 8 * s, y + 8 * s, x + 12 * s, y + 12 * s, x + 4 * s, y + 9 * s, 55)
  circfill(x, y + 11 * s, 2 * s + 1, 23)
  -- 大 logo（scale 4 + 霓虹描边）与一行英文副题
  neon_text("雷霆战机", cx("雷霆战机", 4), 22, 44, 4)
  neon_text("NEON JET", cx("NEON JET"), 84, 60)
end

function draw_over()
  rectfill(32, 96, 192, 64, 15)
  rect(32, 96, 192, 64, 55)
  print("游戏结束", flr((256 - tw("游戏结束")) / 2), 104, 60)
  print("得分 " .. score, flr((256 - tw("得分 " .. score)) / 2), 124, 7)
  if new_best and flr(t / 20) % 2 == 0 then
    print("新纪录！", flr((256 - tw("新纪录！")) / 2), 142, 23)
  end
  if over_t > 60 then -- 与可输入时机同步显示
    local h = btnicon("menu") .. " 回标题"
    neon_text(h, cx(h), 172, 41)
  end
end

function _draw()
  if state == "splash" then
    draw_bg()
    draw_splash()
    return
  end
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
      local h = "按 " .. btnicon("menu") .. " 继续"
      print(h, flr((256 - tw(h)) / 2), 134, 20)
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
  if state == "splash" then
    -- 开机封面：Ⓐ/Menu 跳过，90 帧后进 title
    if t > 90 or btnp(4) or btnp(11) then
      state = "title"
    end
  elseif state == "title" then
    if btnp(4) or btnp(11) then -- Ⓐ 或 Menu 开始
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
