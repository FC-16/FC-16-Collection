-- FC-16《2048》演示卡带
-- 经典 4×4 滑动合并：方向键整行整列滑动，相同数字合并翻倍，
-- 每张牌每次移动至多合并一次；每次有效移动后随机空格生成新牌（90% 为 2、10% 为 4）。
--
-- 演出：牌面缓动滑移（ease-out）、合并弹跳 + 闪光 + 飘字、新牌放大淡入、
--       大数字合并粒子与震屏、512/1024 里程碑横幅、2048 金色射线胜利庆祝；
--       合并音效音高随数值档位升高，轻量 BGM（A 小调四小节循环）用 View 开关。
-- 规则：无效移动不生成新牌（棋盘抖动 + 闷响）；得分 = 合并产生数值之和；
--       最高分经 dset + fflush 持久化；Ⓑ 撤销最近 3 步；Menu 重开；无路可走判负。
--
-- 确定性：随机数只用于新牌生成（rnd）；演出抖动取自幀计数（SPEC §7.2），
--         同 seed 同输入序列结果逐位一致。

-- ---------------------------------------------------------------- 布局常量

local CELL, GAP, BPAD = 44, 4, 6     -- 格宽 / 格距 / 棋盘内边距
local BX, BY = 28, 36                 -- 棋盘底板左上
local SLIDE_T = 8                     -- 滑动动画幀数
local SPAWN_T, POP_T = 12, 10         -- 生成淡入 / 合并弹跳幀数
local UNDO_MAX = 3                    -- 撤销栈深度

local DVEC = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}}  -- 各方向 {行,列} 单位向量

-- 数值 → 外观查表（SPEC §2.2 固定色号；明暗色全部显式给出，不做色号算术）
local TSPEC = {
  [0]    = {bg = 11, fg = 6,  hi = 10},   -- 仅标题 logo 的 0 牌使用
  [2]    = {bg = 22, fg = 17, hi = 21},   -- 浅色系：奶油 / 米黄
  [4]    = {bg = 23, fg = 17, hi = 30},
  [8]    = {bg = 20, fg = 16, hi = 22},   -- 暖色系：桃橙 → 深橙红
  [16]   = {bg = 24, fg = 22, hi = 29},
  [32]   = {bg = 27, fg = 22, hi = 29},
  [64]   = {bg = 25, fg = 22, hi = 24},
  [128]  = {bg = 58, fg = 22, hi = 57},   -- 红 / 粉高饱和
  [256]  = {bg = 59, fg = 22, hi = 57},
  [512]  = {bg = 55, fg = 22, hi = 45},
  [1024] = {bg = 47, fg = 51, hi = 46},   -- 紫
  [2048] = {bg = 30, fg = 26, hi = 31},   -- 金色闪耀
  [4096] = {bg = 42, fg = 38, hi = 43},   -- 超越 2048：青色
  [8192] = {bg = 43, fg = 38, hi = 44},
}

local function spec_of(v)
  return TSPEC[v] or {bg = 7, fg = 63, hi = 6}
end

-- 数值 → 合并音效档位（2 为 1 档，每翻倍一档）
local TIER = {}
do
  local v = 2
  for i = 1, 16 do TIER[v] = i v = v * 2 end
end

-- ---------------------------------------------------------------- 3×5 像素数字

local DIGITS = {
  "111101101101111", "010110010010111", "111001111100111",
  "111001111001111", "101101111001001", "111100111001111",
  "111100111101111", "111001010010010", "111101111101111",
  "111101111001111",
}

-- 以 (cx,cy) 为中心绘制数字串；s 为像素块边长，g 为字间隙
local function bignum(s, cx, cy, sz, g, c)
  local n = #s
  local w = n * 3 * sz + (n - 1) * g
  local x0 = cx - w / 2
  local y0 = cy - 2.5 * sz
  for k = 1, n do
    local pat = DIGITS[s:byte(k) - 47]
    for j = 0, 4 do
      for i = 0, 2 do
        if pat:byte(j * 3 + i + 1) == 49 then
          rectfill(x0 + (k - 1) * (3 * sz + g) + i * sz, y0 + j * sz, sz, sz, c)
        end
      end
    end
  end
end

-- 牌面数字：按位数查表取块号尺寸（4 位 39px 至多 44px 格宽），≥5 位退回固件 ASCII
local NUMS = {6, 5, 4, 3, 2}

local function draw_num(v, cx, cy, k)
  local s = string.format("%d", v)
  local n = #s
  if n >= 5 then
    print(s, cx - tw(s) / 2, cy - 8, spec_of(v).fg)
  else
    local sz = flr(NUMS[n] * k)
    if sz < 2 then sz = 2 end
    bignum(s, cx, cy, sz, sz >= 4 and 2 or 1, spec_of(v).fg)
  end
end

local function fmt(n) return string.format("%d", n) end

-- ---------------------------------------------------------------- 音频（SPEC §5.2 布局）

local function u8(a, v) poke(a, v % 256) end

-- notes 为逐步音高（0=休止）；o 可含 loop / effect
local function init_sfx(id, notes, wave, vol, speed, o)
  o = o or {}
  local base = 0x060000 + id * 112
  u8(base, speed)
  u8(base + 1, #notes)
  if o.loop then u8(base + 2, o.loop) u8(base + 3, #notes) u8(base + 4, 1) end
  for i = 0, 31 do
    local a = base + 16 + i * 3
    if i < #notes then
      u8(a, notes[i + 1])
      u8(a + 1, wave * 16 + vol)
      u8(a + 2, o.effect or 0)
    else
      u8(a, 0)
      u8(a + 1, 0)
    end
  end
end

-- 轻量 BGM：A 小调四小节循环（Am-F-C-G），旋律 / 琶音 / 贝斯三声部，
-- 每小节一条 32 步 SFX（八分音符 ×4 步，speed 7），Pattern 0 BEGIN / 3 END
local MELDY = {
  {58, 0, 61, 0, 64, 0, 61, 0},
  {58, 0, 61, 0, 65, 64, 61, 0},
  {55, 0, 61, 0, 64, 0, 67, 0},
  {62, 0, 59, 62, 55, 0, 50, 0},
}
local ARPEG = {
  {46, 49, 52, 46, 49, 52, 58, 52},
  {46, 49, 53, 46, 49, 53, 58, 53},
  {43, 49, 52, 43, 49, 52, 55, 52},
  {43, 47, 50, 43, 47, 50, 55, 50},
}
local BASSL = {
  {34, 0, 0, 0, 40, 0, 0, 0},
  {29, 0, 0, 0, 36, 0, 0, 0},
  {36, 0, 0, 0, 44, 0, 0, 0},
  {31, 0, 0, 0, 38, 0, 0, 0},
}

local function expand(notes, n)
  local out = {}
  for _, v in ipairs(notes) do
    for _ = 1, n do out[#out + 1] = v end
  end
  return out
end

local function init_audio()
  init_sfx(0, {44}, 14, 4, 2)                       -- 滑动轻嗖（长噪声）
  init_sfx(1, {30, 26}, 3, 9, 2)                    -- 无效移动闷响
  init_sfx(2, {57}, 0, 3, 2)                        -- 新牌轻点
  init_sfx(3, {40, 52}, 8, 7, 2, {effect = 1})      -- 撤销上滑
  init_sfx(4, {64, 69, 73, 76}, 10, 8, 2)           -- 里程碑铃音上行
  init_sfx(5, {52, 56, 59, 64, 0, 59, 64, 0, 69, 0, 0, 0}, 3, 10, 3) -- 胜利号角
  init_sfx(6, {40, 44, 47, 52, 0, 47, 52, 0, 56, 0, 0, 0}, 8, 8, 3) -- 胜利和声
  init_sfx(7, {35, 31, 28, 23}, 11, 9, 5)           -- 失败下行低音
  init_sfx(8, {69, 76}, 10, 7, 2)                   -- 新纪录
  init_sfx(9, {56}, 3, 6, 1)                        -- 界面确认
  -- 合并音效 id 16-28：档位越高音高越高，高档附加三度 / 五度 / 八度和音
  for tier = 1, 13 do
    local p = 40 + tier * 2
    local notes = {p, p + 4}
    if tier >= 5 then notes[#notes + 1] = p + 7 end
    if tier >= 9 then notes[#notes + 1] = p + 12 end
    init_sfx(15 + tier, notes, 3, tier >= 8 and 11 or 9, 1)
  end
  -- BGM 声部：旋律 32-35 / 琶音 40-43 / 贝斯 48-51，占通道 2/3/4
  for bar = 1, 4 do
    init_sfx(31 + bar, expand(MELDY[bar], 4), 8, 5, 7)
    init_sfx(39 + bar, expand(ARPEG[bar], 4), 0, 3, 7)
    init_sfx(47 + bar, expand(BASSL[bar], 4), 11, 6, 7)
    local pb = 0x063800 + (bar - 1) * 16
    u8(pb + 2, 33 + bar)
    u8(pb + 3, 41 + bar)
    u8(pb + 4, 49 + bar)
    u8(pb + 8, bar == 1 and 1 or (bar == 4 and 2 or 0))
  end
end

-- ---------------------------------------------------------------- 游戏状态

local state, grid, score, best, won, over, cele
local undo_stack, anim, queued_dir
local run_max, record_shown, banner, score_flash
local parts, popups
local shake2_t, invalid_t, invalid_dx, invalid_dy
local music_on

local function cell_xy(r, c)
  return BX + BPAD + (c - 1) * (CELL + GAP), BY + BPAD + (r - 1) * (CELL + GAP)
end

local function new_tile(r, c, v, quick)
  local x, y = cell_xy(r, c)
  grid[r][c] = {v = v, r = r, c = c, x = x, y = y,
                born = quick and 6 or SPAWN_T, pop = 0, sliding = false}
end

-- 新牌生成：随机空格 + 90% 为 2 / 10% 为 4（唯一的 rnd 消耗点）
local function spawn(quiet)
  local empties = {}
  for r = 1, 4 do
    for c = 1, 4 do
      if not grid[r][c] then empties[#empties + 1] = r * 8 + c end
    end
  end
  if #empties == 0 then return end
  local e = empties[flr(rnd(#empties)) + 1]
  new_tile(flr(e / 8), e % 8, rnd(1) < 0.9 and 2 or 4)
  if not quiet then sfx(2) end
end

local function snapshot()
  local cells = {}
  for r = 1, 4 do
    for c = 1, 4 do
      cells[(r - 1) * 4 + c] = grid[r][c] and grid[r][c].v or 0
    end
  end
  return {cells = cells, score = score}
end

local function grid_from(cells)
  grid = {}
  for r = 1, 4 do
    grid[r] = {}
    for c = 1, 4 do
      local v = cells[(r - 1) * 4 + c]
      if v > 0 then new_tile(r, c, v, true) end
    end
  end
end

local function new_game()
  grid = {}
  for r = 1, 4 do grid[r] = {} end
  score = 0
  won = false
  over = false
  cele = false
  run_max = 0
  record_shown = false
  undo_stack = {}
  anim = nil
  queued_dir = nil
  banner = nil
  parts = {}
  popups = {}
  spawn(true)
  spawn(true)
end

local function can_move()
  for r = 1, 4 do
    for c = 1, 4 do
      local tl = grid[r][c]
      if not tl then return true end
      if c < 4 then
        local o = grid[r][c + 1]
        if o and o.v == tl.v then return true end
      end
      if r < 4 then
        local o = grid[r + 1][c]
        if o and o.v == tl.v then return true end
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------- 移动与合并

-- 方向 d 的第 i 条线上，自移动墙侧数第 k 格的坐标
local function line_cell(d, i, k)
  if d == 0 then return i, k
  elseif d == 1 then return i, 5 - k
  elseif d == 2 then return k, i
  else return 5 - k, i end
end

-- 计算并启动一次移动；无任何牌位移或合并时返回 false（无效移动）
local function try_move(d)
  local moves, gained, any = {}, 0, false
  local snap = snapshot()
  for i = 1, 4 do
    local placed = {}
    for k = 1, 4 do
      local r, c = line_cell(d, i, k)
      local tl = grid[r][c]
      if tl then
        local p = placed[#placed]
        if p and p.v == tl.v and not p.merged then
          p.v = flr(tl.v * 2)      -- 每张牌每次移动至多并入一次
          p.merged = tl
          gained = gained + p.v
          any = true
        else
          placed[#placed + 1] = {v = tl.v, src = tl, merged = nil}
        end
      end
    end
    -- 摘下本线所有牌（源格清空，再统一写回目标格；并入者一并摘下）
    for k = 1, #placed do
      local p = placed[k]
      grid[p.src.r][p.src.c] = nil
      if p.merged then grid[p.merged.r][p.merged.c] = nil end
    end
    for k = 1, #placed do
      local r, c = line_cell(d, i, k)
      local p = placed[k]
      local tx, ty = cell_xy(r, c)
      -- 牌身滑动（被并入的目标牌也要先滑到位，再接收并入者）
      if p.src.x ~= tx or p.src.y ~= ty then
        p.src.sliding = true
        moves[#moves + 1] = {tl = p.src, fx = p.src.x, fy = p.src.y,
                             tx = tx, ty = ty, target = nil, newv = p.v}
        any = true
      end
      p.src.r, p.src.c = r, c
      grid[r][c] = p.src
      if p.merged then
        p.merged.sliding = true
        moves[#moves + 1] = {tl = p.merged, fx = p.merged.x, fy = p.merged.y,
                             tx = tx, ty = ty, target = p.src, newv = p.v}
        any = true
      end
    end
  end
  if not any then return false end
  undo_stack[#undo_stack + 1] = snap
  if #undo_stack > UNDO_MAX then table.remove(undo_stack, 1) end
  anim = {phase = "slide", t = 0, moves = moves, gained = gained}
  sfx(0)
  return true
end

-- 合并落地演出：飘字、粒子、震屏、里程碑与胜利判定
local function merge_fx(m)
  local cx, cy = m.tx + CELL / 2, m.ty + CELL / 2
  popups[#popups + 1] = {x = cx, y = m.ty - 6, txt = "+" .. fmt(m.newv),
                         t = 34, col = 31}
  if m.newv >= 128 then
    local sp = spec_of(m.newv)
    local cols = {sp.hi, 31, 30, 7}
    local tier = TIER[m.newv] or 13
    local n = min(26, 8 + tier * 2)
    for i = 1, n do                        -- 黄金角散布（确定性，不用 rnd）
      local a = i * 0.381966 + tier * 0.13
      local spd = 0.7 + (i % 3) * 0.45 + tier * 0.05
      parts[#parts + 1] = {
        x = cx, y = cy,
        vx = cos(a) * spd, vy = sin(a) * spd - 0.6,
        life = 16 + (i % 4) * 4, col = cols[i % 4 + 1], sz = 2,
      }
    end
  end
  if m.newv >= 512 then shake2_t = 10 end
  if m.newv > run_max then
    run_max = m.newv
    if m.newv == 512 or m.newv == 1024 then
      banner = {txt = fmt(m.newv) .. " 达成！", t = 96}
      sfx(4)
    end
  end
  if m.newv == 2048 and not won then
    won = true
    cele = true
    sfx(5)
    sfx(6)
    for i = 1, 40 do                       -- 胜利彩带（确定性散布）
      parts[#parts + 1] = {
        x = 16 + i * 5.6, y = -10 - (i % 7) * 8,
        vx = sin(i * 0.7) * 0.4, vy = 0.8 + (i % 5) * 0.3,
        life = 90 + (i % 6) * 10, col = (i % 2 == 0) and 31 or 30, sz = 3,
      }
    end
  end
end

local function finish_slide()
  local gained = anim.gained
  local top_tier = 0
  for _, m in ipairs(anim.moves) do
    m.tl.sliding = false
    m.tl.x, m.tl.y = m.tx, m.ty
    if m.target then
      m.target.v = m.newv
      m.target.pop = POP_T
      merge_fx(m)
      local t = TIER[m.newv] or 13
      if t > top_tier then top_tier = t end
    end
  end
  if top_tier > 0 then sfx(15 + min(top_tier, 13)) end
  if gained > 0 then
    score = score + gained
    score_flash = 14
    if score > best then
      best = score
      dset(0, best)
      fflush()
      if not record_shown then
        record_shown = true
        sfx(8)
        popups[#popups + 1] = {x = 146, y = 42, txt = "新纪录！", t = 50, col = 30}
      end
    end
  end
  anim = nil
  spawn()
  if not can_move() then
    over = true
    sfx(7)
  end
end

local function step_slide()
  anim.t = anim.t + 1
  local u = min(1, anim.t / SLIDE_T)
  local e = 1 - (1 - u) * (1 - u)          -- ease-out 二次
  for _, m in ipairs(anim.moves) do
    m.tl.x = m.fx + (m.tx - m.fx) * e
    m.tl.y = m.fy + (m.ty - m.fy) * e
  end
  if anim.t >= SLIDE_T then finish_slide() end
end

local function do_undo()
  if #undo_stack == 0 then
    popups[#popups + 1] = {x = 128, y = 122, txt = "没有可撤销的移动",
                           t = 44, col = 9}
    sfx(1)
    return
  end
  local s = table.remove(undo_stack)
  grid_from(s.cells)
  score = s.score
  over = false
  cele = false
  anim = nil
  queued_dir = nil
  run_max = 0
  for r = 1, 4 do
    for c = 1, 4 do
      if grid[r][c] and grid[r][c].v > run_max then run_max = grid[r][c].v end
    end
  end
  sfx(3)
end

local function toggle_music()
  music_on = not music_on
  dset(1, music_on and 0 or 1)
  fflush()
  if music_on then music(0, 300, 0x1C) else music(-1, 300) end
end

local function apply_dir(d)
  if anim then return end
  if try_move(d) then return end
  invalid_t = 7
  invalid_dx = DVEC[d + 1][2]   -- 列分量 → 屏幕水平
  invalid_dy = DVEC[d + 1][1]   -- 行分量 → 屏幕垂直
  sfx(1)
end

-- ---------------------------------------------------------------- 幀更新

function _update()
  if shake2_t > 0 then shake2_t = shake2_t - 1 end
  if invalid_t > 0 then invalid_t = invalid_t - 1 end
  if score_flash > 0 then score_flash = score_flash - 1 end

  for i = #parts, 1, -1 do
    local p = parts[i]
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    p.vy = p.vy + 0.14
    p.life = p.life - 1
    if p.life <= 0 then table.remove(parts, i) end
  end
  for i = #popups, 1, -1 do
    local p = popups[i]
    p.y = p.y - 0.45
    p.t = p.t - 1
    if p.t <= 0 then table.remove(popups, i) end
  end
  if banner then
    banner.t = banner.t - 1
    if banner.t <= 0 then banner = nil end
  end
  if grid then
    for r = 1, 4 do
      for c = 1, 4 do
        local tl = grid[r][c]
        if tl then
          if tl.born > 0 then tl.born = tl.born - 1 end
          if tl.pop > 0 then tl.pop = tl.pop - 1 end
        end
      end
    end
  end

  if state == "title" then
    if btnp(4) or btnp(11) then
      state = "play"
      new_game()
      sfx(9)
    elseif btnp(10) then
      toggle_music()
    end
    return
  end

  if btnp(10) then toggle_music() end

  if anim and anim.phase == "slide" then
    for d = 0, 3 do                        -- 动画中缓冲下一次方向
      if dirp(d) then queued_dir = d end
    end
    step_slide()
    return
  end

  if cele then
    if btnp(4) then cele = false
    elseif btnp(11) then new_game() sfx(9) end
    return
  end

  if over then
    if btnp(5) then do_undo()
    elseif btnp(4) or btnp(11) then new_game() sfx(9) end
    return
  end

  local d = queued_dir
  queued_dir = nil
  if d ~= nil then
    apply_dir(d)
  elseif dirp(0) then apply_dir(0)
  elseif dirp(1) then apply_dir(1)
  elseif dirp(2) then apply_dir(2)
  elseif dirp(3) then apply_dir(3)
  elseif btnp(5) then do_undo()
  elseif btnp(11) then new_game() sfx(9) end
end

-- ---------------------------------------------------------------- 绘制

local function draw_tile(tl, ox, oy)
  local k = 1
  if tl.born > 0 then                      -- 生成淡入放大
    local u = 1 - tl.born / SPAWN_T
    k = 0.5 + 0.5 * (1 - (1 - u) * (1 - u))
  elseif tl.pop > 0 then                   -- 合并弹跳
    local u = 1 - tl.pop / POP_T
    k = 1 + 0.32 * sin(u * 0.5) * (1 - u)
  end
  local x, y = tl.x + ox, tl.y + oy
  local sp = spec_of(tl.v)
  local w = CELL * k
  local rx = x + (CELL - w) / 2
  local ry = y + (CELL - w) / 2
  rrectfill(rx, ry, w, w, max(1, 5 * k), sp.bg)
  if w >= 12 then
    line(rx + 3, ry + 2, rx + w - 4, ry + 2, sp.hi)  -- 顶缘高光（查表色）
  end
  if k > 0.72 then
    draw_num(tl.v, x + CELL / 2, y + CELL / 2, k)
  end
  if tl.v >= 2048 and tl.born == 0 then    -- 金色闪耀十字星
    for i = 0, 2 do
      local a = frame() * 0.06 + i * 0.333
      local rr = 14 + 4 * sin(frame() * 0.04 + i)
      local sx = x + CELL / 2 + cos(a) * rr
      local sy = y + CELL / 2 + sin(a) * rr
      line(sx - 1, sy, sx + 1, sy, 31)
      line(sx, sy - 1, sx, sy + 1, 31)
    end
  end
end

local function draw_board(ox, oy)
  rrectfill(26 + ox, 34 + oy, 204, 204, 9, 11)     -- 外缘
  rrectfill(28 + ox, 36 + oy, 200, 200, 7, 13)     -- 底板
  fillp(0x0104)                                    -- 底板点纹
  rectfill(28 + ox, 36 + oy, 200, 200, 12 * 256 + 13)
  fillp()
  for r = 1, 4 do
    for c = 1, 4 do
      local tl = grid[r][c]
      if not tl or tl.sliding then                 -- 空格与被腾出的源格
        local x, y = cell_xy(r, c)
        rrectfill(x + ox, y + oy, CELL, CELL, 5, 14)
      end
    end
  end
end

local function draw_tiles(ox, oy)
  for r = 1, 4 do
    for c = 1, 4 do
      local tl = grid[r][c]
      if tl and not tl.sliding then draw_tile(tl, ox, oy) end
    end
  end
  if anim then                                     -- 滑动中的牌压在上层
    for _, m in ipairs(anim.moves) do draw_tile(m.tl, ox, oy) end
  end
end

local function panel(x, w, label, val, col, flash)
  rrectfill(x, 1, w, 32, 6, 13)
  rect(x, 1, w, 32, 12)
  print(label, x + (w - tw(label)) / 2, 1, 9)
  local s = fmt(val)
  local c = col
  if flash and frame() % 6 < 3 then c = 31 end
  print(s, x + (w - tw(s)) / 2, 16, c)
end

local function draw_hud()
  local mini = {{2, 12, 2}, {0, 28, 2}, {4, 12, 18}, {8, 28, 18}}
  for _, m in ipairs(mini) do
    local sp = spec_of(m[1])
    rrectfill(m[2], m[3], 15, 15, 3, sp.bg)
    bignum(fmt(m[1]), m[2] + 7.5, m[3] + 8, 2, 1, sp.fg)
  end
  panel(112, 68, "得分", score, 7, score_flash > 0)
  panel(184, 64, "最高", best, 30, false)
end

local function draw_parts()
  for _, p in ipairs(parts) do
    rectfill(p.x, p.y, p.life < 10 and 1 or p.sz, p.life < 10 and 1 or p.sz, p.col)
  end
end

local function draw_popups()
  for _, p in ipairs(popups) do
    if p.t > 10 or frame() % 4 < 2 then
      print(p.txt, p.x - tw(p.txt) / 2, p.y, p.col)
    end
  end
end

local function draw_banner()
  if not banner then return end
  if banner.t < 20 and frame() % 4 < 2 then return end
  local w = tw(banner.txt) + 24
  rrectfill((256 - w) / 2, 96, w, 26, 6, 13)
  rect((256 - w) / 2, 96, w, 26, 30)
  print(banner.txt, (256 - tw(banner.txt)) / 2, 101, 31)
end

local function big_text(s, x, y, c)
  print(s, x + 1, y + 1, 15)
  print(s, x - 1, y, 15)
  print(s, x + 1, y, 15)
  print(s, x, y - 1, 15)
  print(s, x, y + 1, 15)
  print(s, x, y, c)
end

-- 胜利 / 失败覆盖层直接压在可见棋盘上（保留终局局面），不整屏擦除
local function draw_rays(cx, cy)
  for i = 0, 15 do
    if i % 2 == 0 then
      local a = frame() * 0.003 + i * 0.0625
      local x1 = cx + cos(a - 0.012) * 150
      local y1 = cy + sin(a - 0.012) * 150
      local x2 = cx + cos(a + 0.012) * 150
      local y2 = cy + sin(a + 0.012) * 150
      trifill(cx, cy, x1, y1, x2, y2, i % 4 == 0 and 30 or 26)
    end
  end
end

local function draw_cele()
  draw_rays(128, 128)
  rrectfill(44, 92, 168, 84, 8, 13)
  rect(44, 92, 168, 84, 31)
  local s1 = "2048 达成！"
  big_text(s1, (256 - tw(s1)) / 2, 106, 31)
  local s2 = "Ⓐ 继续挑战　Menu 新一局"
  print(s2, (256 - tw(s2)) / 2, 140, 7)
end

local function draw_over()
  rrectfill(48, 88, 160, 88, 8, 13)
  rect(48, 88, 160, 88, 61)
  local s1 = "无路可走"
  big_text(s1, (256 - tw(s1)) / 2, 100, 58)
  local s2 = "得分 " .. fmt(score) .. "　最高 " .. fmt(best)
  print(s2, (256 - tw(s2)) / 2, 128, 7)
  if frame() % 30 < 20 then
    local s3 = "Ⓑ 悔棋一步　Menu / Ⓐ 重开"
    print(s3, (256 - tw(s3)) / 2, 150, 31)
  end
end

local function draw_hints()
  local s
  if flr(frame() / 240) % 2 == 0 then
    s = "←↑↓→ 移动　Ⓑ 撤销"
  else
    s = "Menu 重开　View 音乐"
  end
  print(s, (256 - tw(s)) / 2, 239, 9)
end

-- 标题背景漂浮色块
local FTILES = {
  {v = 4,  bx = 24,  off = 0,   sp = 0.011, amp = 10},
  {v = 8,  bx = 210, off = 90,  sp = 0.007, amp = 14},
  {v = 16, bx = 40,  off = 170, sp = 0.009, amp = 12},
  {v = 32, bx = 200, off = 40,  sp = 0.013, amp = 8},
  {v = 64, bx = 120, off = 130, sp = 0.005, amp = 16},
}

local function draw_title()
  local t = frame()
  for i, f in ipairs(FTILES) do
    local x = f.bx + sin(t * f.sp + i) * f.amp
    local y = (f.off + t * 0.35) % 280 - 20
    rrectfill(x, y, 18, 18, 4, spec_of(f.v).bg)
  end
  -- 大 logo：2×2 大牌逐张落下并轻微悬停
  local big = {{2, 0, 0}, {0, 1, 0}, {4, 0, 1}, {8, 1, 1}}
  for i, m in ipairs(big) do
    local age = t - (m[3] * 2 + m[2]) * 7
    local drop
    if age < 0 then
      drop = -110
    elseif age < 14 then
      local u = age / 14
      drop = -110 * (1 - u) * (1 - u) - 8 * sin(u * 0.5)
    else
      drop = sin(t * 0.02 + i * 0.2) * 2
    end
    local x = 69 + m[2] * 58
    local y = 40 + m[3] * 58 + drop
    local sp = spec_of(m[1])
    rrectfill(x, y, 56, 56, 8, sp.bg)
    line(x + 8, y + 4, x + 48, y + 4, sp.hi)
    bignum(fmt(m[1]), x + 28, y + 30, 8, 4, sp.fg)
  end
  local s = "经典数字合成"
  print(s, (256 - tw(s)) / 2, 172, 9)
  if t % 40 < 28 then
    s = "Ⓐ 开始游戏"
    print(s, (256 - tw(s)) / 2, 198, 31)
  end
  if best > 0 then
    s = "最高 " .. fmt(best)
    print(s, (256 - tw(s)) / 2, 222, 30)
  end
  s = "View 音乐开关"
  print(s, (256 - tw(s)) / 2, 239, 6)
end

function _draw()
  camera(0, 0)
  if shake2_t > 4 then                      -- 大合并震屏（幀计数抖动）
    camera((frame() * 13 % 5) - 2, (frame() * 7 % 5) - 2)
  end
  cls(14)
  fillp(0x0104)                             -- 页面底纹
  rectfill(0, 0, 256, 256, 13 * 256 + 14)
  fillp()
  if state == "title" then
    draw_title()
  else
    local ox, oy = 0, 0                     -- 无效移动：棋盘轻微抖动
    if invalid_t > 0 then
      local amp = 1 + flr(invalid_t / 3)
      ox = invalid_dx * amp
      oy = invalid_dy * amp
    end
    draw_hud()
    draw_board(ox, oy)
    draw_tiles(ox, oy)
    draw_parts()
    draw_popups()
    draw_banner()
    draw_hints()
    if cele then draw_cele() end
    if over then draw_over() end
  end
end

-- ---------------------------------------------------------------- 初始化

function _init()
  init_audio()
  best = dget(0)
  music_on = dget(1) == 0
  state = "title"
  score = 0
  parts = {}
  popups = {}
  undo_stack = {}
  grid = nil
  won = false
  over = false
  cele = false
  run_max = 0
  record_shown = false
  banner = nil
  score_flash = 0
  shake2_t = 0
  invalid_t = 0
  invalid_dx, invalid_dy = 0, 0
  anim = nil
  queued_dir = nil
  if music_on then music(0, 600, 0x1C) end
end
