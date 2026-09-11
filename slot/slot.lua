-- FC-16 老虎机演示卡带（v4：修复于 v0.7 实现）
-- 特性覆盖：poke 逐像素生成精灵表 / sspr 圆柱压缩滚筒（v0.7 修正表坐标语义）/
--           clip 裁剪滚动窗 / fillp 抖动遮罩与纹理 / pal 显示期调色映射（头奖全屏金闪，
--           SPEC §2.3 v0.7）/ mid 三值取中 / SFX 与背景音乐 / dset 存档 /
--           中文文本（固件字集内字符）
--
-- 操作（键盘映射到 A/B 键）：J 拉杆，旋转中每按一次 J 停下一只滚轮（逐轮快停），
--                 W/S 调注，K 满注，L 赔率表，Enter 存档，Tab 音乐开关，破产按 K 领币
-- 街机式 attract mode：闲置 5 秒自动演示
--
-- 上瘾设计：旋转棘轮声、前两轮同号的 near-miss 悬念（第三轮拖长＋滴答声）、
--           分档中奖音效、头奖双通道号角＋震屏＋射线＋金币落入出币口、计币音阶递升
--
-- 拟物：滚筒曲率（离中线越远符号越扁）、玻璃斜向反光、出币口接住金币、
--       机框四角螺丝、右侧实体键（按下下陷）、边框暗角

-- ---------------------------------------------------------------- 常量

local REEL_X = {28, 96, 164} -- 滚轮列左缘（宽 64）
local WIN_Y, WIN_H = 56, 78  -- 滚轮窗
local PAY_Y = 95             -- 中线（派彩线）中心
local PITCH = 26             -- 符号纵向间距
local STOP_T = {100, 160, 220} -- 各轮基础停止时刻（不快停时转足三秒半）
local BETS = {1, 2, 3, 5, 10, 20, 50, 99} -- 调注梯度

-- 符号（瓦片号）：1 七 2 铃 3 钻 4 星 5 葡 6 樱
local NAME = {"7", "铃", "钻", "星", "葡", "樱"}
local PAY3 = {[1] = 100, [2] = 15, [3] = 10, [4] = 6, [5] = 4, [6] = 5}

-- 三条滚轮带（各 8 格：单 7、单铃、单钻、单葡、双星、双樱）
local strip = {
  {1, 2, 6, 3, 4, 6, 5, 4},
  {3, 1, 4, 6, 2, 4, 6, 5},
  {4, 6, 5, 1, 6, 3, 2, 4},
}

-- 音效通道分配：BGM 独占 ch4（旋律）/ch5（琶音）/ch6（贝斯），
-- 游戏音效只用其余通道；ch0 与计币、ch7 与 UI 分别在不同状态复用（互不重叠）
local CH_RATCHET, CH_THUNK, CH_TENSE, CH_JINGLE = 0, 1, 2, 3
local CH_BLIP, CH_UI, CH_HARM = 0, 7, 7

-- ---------------------------------------------------------------- 精灵生成

-- 逐像素写 16×16 瓦片：fn(x, y) 返回色号或 nil（0＝透明）
local function bake(id, fn)
  local base = id * 256
  for y = 0, 15 do
    for x = 0, 15 do
      local c = fn(x + 0.5, y + 0.5) -- 像素中心
      poke(base + y * 16 + x, c or 0)
    end
  end
end

-- 射线法点在多边形内（pts 为 {{x,y}...}）
local function in_poly(px, py, pts)
  local inside = false
  local j = #pts
  for i = 1, #pts do
    local xi, yi = pts[i][1], pts[i][2]
    local xj, yj = pts[j][1], pts[j][2]
    if (yi > py) ~= (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- 点到线段距离
local function seg_d(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local tt = 0
  if l2 > 0 then
    tt = ((px - ax) * dx + (py - ay) * dy) / l2
    if tt < 0 then tt = 0 elseif tt > 1 then tt = 1 end
  end
  local qx, qy = ax + dx * tt, ay + dy * tt
  return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

-- 多边形最小边距
local function edge_d(px, py, pts)
  local best = 1e9
  for i = 1, #pts do
    local a, b = pts[i], pts[i % #pts + 1]
    local d = seg_d(px, py, a[1], a[2], b[1], b[2])
    if d < best then best = d end
  end
  return best
end

local function bake_symbols()
  -- 1 幸运 7：顶杠＋斜笔，带暗红轮廓（body 按 g 外扩判定轮廓带）
  bake(1, function(x, y)
    local function body(g)
      if y >= 2 - g and y <= 6 + g and x >= 2 - g and x <= 13 + g then return true end
      local d = x + y - 18.5
      return y >= 5 - g and y <= 15 + g and x <= 13 + g and abs(d) <= 2.4 + g
    end
    if not body(0) then
      if body(1) then return 62 end
      return nil
    end
    if y <= 6 then -- 顶杠
      if y <= 3 then return 58 end
      if y >= 6 then return 61 end
      return 60
    end
    local d = x + y - 18.5
    if d > 1.1 then return 58 end  -- 右缘高光
    if d < -1.5 then return 61 end -- 左下暗边
    return 60
  end)

  -- 2 金铃：穹顶＋口沿＋铃锤＋顶钮
  bake(2, function(x, y)
    local dx, dy = x - 8, y - 1.6
    if dx * dx + dy * dy <= 1.8 then return 23 end -- 顶钮
    dx, dy = x - 8, y - 15
    local rr = sqrt(dx * dx + dy * dy)
    if y <= 11 and rr <= 8 then
      if rr > 6.8 then return 1 end
      if x + y < 13 then return 23 end
      return 30
    end
    if y >= 11 and y <= 13 and x >= 2 and x <= 14 then
      if y <= 11 then return 23 end
      return 1
    end
    dx, dy = x - 8, y - 14.8
    if y >= 13 and dx * dx + dy * dy <= 2.2 then return 18 end
  end)

  -- 3 钻石：冠部梯形＋亭部三角，明暗分面＋白色闪光点
  local gem = {{3, 3}, {12, 3}, {14, 6}, {8, 14}, {2, 6}}
  bake(3, function(x, y)
    if not in_poly(x, y, gem) then return end
    local s1 = (x - 5.5) * (x - 5.5) + (y - 5.5) * (y - 5.5)
    local s2 = (x - 10.5) * (x - 10.5) + (y - 8.5) * (y - 8.5)
    if s1 < 1.2 or s2 < 1.2 then return 7 end
    if edge_d(x, y, gem) < 0.75 then return 39 end
    if y <= 6 then return (x < 8) and 43 or 41 end
    return (x < 8) and 42 or 40
  end)  -- 4 金星：五角星（圈制三角函数取顶点）
  local star = {}
  for i = 0, 9 do
    local a = -0.25 + i * 0.1
    local r = (i % 2 == 0) and 7.6 or 3.2
    star[i + 1] = {8 + cos(a) * r, 8.4 + sin(a) * r}
  end
  bake(4, function(x, y)
    if not in_poly(x, y, star) then return end
    if edge_d(x, y, star) < 0.7 then return 17 end
    return (x < 8.5) and 23 or 30
  end)

  -- 5 葡萄：九粒果穗＋果梗＋叶
  local berries = {
    {8, 3.6}, {5.6, 6.6}, {10.4, 6.6}, {4.2, 9.6}, {8, 9.6},
    {11.8, 9.6}, {6, 12.6}, {10, 12.6}, {8, 15},
  }
  bake(5, function(x, y)
    for _, c in ipairs(berries) do
      local dx, dy = x - c[1], y - c[2]
      local d = sqrt(dx * dx + dy * dy)
      if d <= 2.05 then
        if d > 1.45 then return 53 end
        if dx + dy < -1.2 then return 55 end
        return 48
      end
    end
    if seg_d(x, y, 8, 3, 9.5, 0.5) < 0.6 then return 6 end
    local lx, ly = x - 10.6, y - 2.2
    if lx * lx / 4.4 + ly * ly / 1.2 <= 1 then
      return (x < 10.6) and 34 or 36
    end
  end)

  -- 6 樱桃：双果＋果梗汇聚＋叶
  local chs = {{4.8, 10.8}, {10.8, 11.6}}
  bake(6, function(x, y)
    for _, c in ipairs(chs) do
      local dx, dy = x - c[1], y - c[2]
      local d = sqrt(dx * dx + dy * dy)
      if d <= 3.4 then
        if d > 2.6 then return 62 end
        local hx, hy = x - (c[1] - 1.2), y - (c[2] - 1.2)
        if hx * hx + hy * hy < 0.5 then return 22 end
        if dx + dy < -1.8 then return 57 end
        return 60
      end
    end
    local lx, ly = x - 9.6, y - 2.6
    if lx * lx / 5.8 + ly * ly / 1.4 <= 1 then
      return (x < 9.6) and 34 or 36
    end
    local d1 = seg_d(x, y, 11, 2, 4.8, 10.8)
    local d2 = seg_d(x, y, 11, 2, 10.8, 11.6)
    if min(d1, d2) < 0.65 then return (x > 8) and 35 or 36 end
  end)
end

-- ---------------------------------------------------------------- 音频（SPEC §5.2 布局）

local function u8(a, val) poke(a, val % 256) end

-- init_sfx(id, notes, wave, vol, speed, o)：o 可含 loop 与逐步 effect。
local function init_sfx(id, notes, wave, vol, speed, o)
  o = o or {}
  local base = 0x060000 + id * 112
  u8(base, speed or 2)
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

local function init_all_sfx()
  init_sfx(0, {33, 28}, 3, 12, 1) -- 拉杆：低音双响
  init_sfx(1, {81}, 3, 6, 1)      -- 棘轮滴答（Lua 每 3 帧重触发）
  init_sfx(2, {30, 26, 28}, 3, 11, 1) -- 停轮：钝响＋余震
  init_sfx(3, {61, 65, 68, 73}, 3, 11, 2)                       -- 小奖：明亮琶音
  init_sfx(4, {61, 65, 68, 73, 77, 80, 85}, 3, 12, 2)           -- 中奖：上行音阶
  init_sfx(5, {49, 0, 49, 49, 0, 53, 56, 0, 56, 56, 0, 61, 61, 0, 0},
    3, 13, 3)                                                   -- 头奖旋律（军号节奏）
  init_sfx(6, {37, 0, 37, 37, 0, 41, 44, 0, 44, 44, 0, 49, 49, 0, 0},
    2, 9, 3)                                                    -- 头奖和声
  -- 计币音阶（四级递升）＋逐步快琶音 Effect 6。
  init_sfx(7, {73}, 3, 7, 1, {effect = 6})
  init_sfx(8, {76}, 3, 7, 1, {effect = 6})
  init_sfx(9, {80}, 3, 7, 1, {effect = 6})
  init_sfx(10, {83}, 3, 7, 1, {effect = 6})
  init_sfx(11, {56}, 3, 5, 1)     -- 调注／满注
  init_sfx(12, {61, 68}, 3, 9, 2) -- 存档／领币
  init_sfx(13, {73}, 3, 8, 1) -- 悬念滴答 A（Lua 驱动）
  init_sfx(14, {76}, 3, 8, 1) -- 悬念滴答 B

  -- BGM：《天空之城》主题曲（君をのせて）八音盒编配，Am 调 72BPM，6 小节循环
  -- 旋律骨架：6 7 1・7 1 3｜7―― 3 3｜6'― 5' 3｜5'― 1' 7｜6― 6 7（回环）
  -- 和声：Am｜Em｜F｜G｜Am｜E7（E7 拉回 Am 完成循环）
  -- 结构：每小节 160 帧＝一条 32 步 SFX（speed 5，每个八分音符展开 4 步）。
  local melody_bars = {
    {46, 48, 49, 0, 0, 48, 49, 53}, -- 6 7 1・ 7 1 3
    {48, 0, 0, 0, 0, 53, 53, 0},    -- 7――― 3 3
    {58, 0, 0, 0, 0, 56, 53, 0},    -- 6'― 5' 3
    {56, 0, 0, 0, 0, 61, 48, 0},    -- 5'― 1' 7
    {46, 0, 0, 0, 0, 46, 48, 0},    -- 6― 6 7（回环起）
    {0, 0, 0, 0, 0, 0, 0, 0},       -- 琶音独奏小节（和声垫撑满）
  }
  local chords = {
    {34, 37, 41, 46, 49}, -- Am：A3 C4 E4 A4 C5
    {29, 32, 36, 41, 44}, -- Em
    {30, 34, 37, 42, 46}, -- F
    {32, 36, 39, 44, 48}, -- G
    {34, 37, 41, 46, 49}, -- Am
    {29, 33, 36, 39, 41}, -- E7
  }
  local bass_roots = {22, 17, 18, 20, 22, 17}
  -- 展开为逐小节 SFX：旋律 20-25（正弦主音）、琶音垫 30-35（25% 脉冲）、
  -- 贝斯 40-45（软锯齿长音）。speed 5（每步 5 帧）：一个八分音符＝5 步＝25 帧，
  -- 一小节 8 个八分音符＝32 步＝160 帧；init_sfx 按连续步写音符，先 ×4 展开
  local function expand(notes, n)
    local out = {}
    for _, v in ipairs(notes) do
      for _ = 1, n do out[#out + 1] = v end
    end
    return out
  end
  for bar = 1, 6 do
    init_sfx(19 + bar, expand(melody_bars[bar], 4), 8, 15, 5) -- ROUND
    local c = chords[bar]
    local arp = {c[1], c[2], c[3], c[4], c[5], c[4], c[3], c[2]}
    init_sfx(29 + bar, expand(arp, 4), 0, 6, 5) -- TRIANGLE
    init_sfx(39 + bar, expand({bass_roots[bar]}, 32), 11, 11, 5) -- BASS
  end
end

-- 背景音乐（SPEC §5.2）：ROUND 主音、TRIANGLE 和声垫；
-- 六段 MUSIC 顺序播放并以 BEGIN/END 回环；三轨固定 ch4/ch5/ch6。
local function init_music()
  for bar = 1, 6 do
    local mb = 0x063800 + (bar - 1) * 16
    u8(mb + 4, 20 + bar)
    u8(mb + 5, 30 + bar)
    u8(mb + 6, 40 + bar)
    u8(mb + 8, bar == 1 and 1 or (bar == 6 and 2 or 0))
  end
end

-- ---------------------------------------------------------------- 状态

-- state／credits／bet／show_pay 为全局（端到端测试观测用），其余为文件局部
local t, auto
local reels, spin_t, lever_t
local msg, msg_kind, pay_left, pay_total, pay_t, pay_hold, win_mult
local win_cols, blip_i, music_stopped
local attract_t, saved_flash, shake_t, cred_flash
local tease_snd, teased
local coins, best, music_on

local function say(s, kind)
  msg = s
  msg_kind = kind
end

local function fmt(n) return string.format("%d", n) end

local function lever_y()
  if lever_t <= 0 then return 64 end
  local u = min(lever_t, 14) / 14
  return 64 + 54 * sin(u * 0.5) -- 圈制：0.5 圈＝半程正弦
end

-- 落点：最小整数 target > pos+gap 且 target≡want (mod 8)。
-- gap：自然停轮 3（留足滑行），逐轮快停 1.6（几乎立即刹车）。
-- 停轮三段式：匀速滑行接近（coast）→ 短距三次缓动刹车（ease）→ 回弹（bounce），
-- 全程只用乘法（确定性：不经过平台 libm）
local function landing(pos, want, gap)
  local n = flr(pos + gap) + 1
  return n + (want - n) % 8
end

-- near-miss 悬念判定：前两轮已停且同符号、第三轮还在走
local function tease_active()
  return reels[1].phase == "done" and reels[2].phase == "done"
    and reels[3].phase ~= "done" and reels[3].phase ~= "bounce"
    and strip[1][reels[1].want + 1] == strip[2][reels[2].want + 1]
end

local function pull_lever()
  if credits <= 0 then
    say("破产了！按 K 领 20 币", "warn")
    return
  end
  if bet > credits then bet = max(1, flr(credits)) end
  credits = credits - bet
  state = "spinning"
  spin_t = 0
  lever_t = 1
  teased = false
  tease_snd = false
  for i = 1, 3 do
    reels[i].phase = "spin"
    reels[i].vel = 0.12
    reels[i].dy = 0
    reels[i].want = flr(rnd(8))
    reels[i].stop_at = STOP_T[i]
  end
  -- 出货即定的 near-miss 悬念：前两轮同号则拖长第三轮（高符号拖更久）
  local s1 = strip[1][reels[1].want + 1]
  if s1 == strip[2][reels[2].want + 1] then
    teased = true
    reels[3].stop_at = STOP_T[3] + (s1 <= 3 and 70 or 35)
  end
  sfx(0, CH_RATCHET)
end

local function spawn_coins(n)
  for _ = 1, n do
    table.insert(coins, {
      x = 60 + rnd(136), y = PAY_Y,
      vx = rnd(-1.7, 1.7), vy = rnd(-3.6, -1.5),
      ph = rnd(1), life = 50 + flr(rnd(40)), bounce = 0,
    })
  end
end

-- 结算：派彩判定与中奖演出调度
local function evaluate()
  local syms = {}
  for i = 1, 3 do syms[i] = strip[i][reels[i].want + 1] end
  local cnt = {}
  for i = 1, 3 do cnt[syms[i]] = (cnt[syms[i]] or 0) + 1 end

  local mult, line1, win_sym = 0, nil, nil
  if cnt[syms[1]] == 3 then
    mult = PAY3[syms[1]]
    line1 = "三连 " .. NAME[syms[1]] .. "　×" .. fmt(mult)
    win_sym = syms[1]
  else
    local c6 = cnt[6] or 0
    if c6 == 2 then
      mult, line1, win_sym = 2, "双樱 ×2", 6
    elseif c6 == 1 then
      mult, line1, win_sym = 1, "单樱　回本", 6
    else
      for s, c in pairs(cnt) do
        if c == 2 then
          mult, line1, win_sym = 1, "一对 " .. NAME[s] .. "　返注", s
        end
      end
    end
  end

  win_cols = {}
  for i = 1, 3 do win_cols[i] = mult > 0 and syms[i] == win_sym end

  local win = bet * mult
  if win > 0 then
    state = "payout"
    pay_total, pay_left, pay_t, pay_hold = win, win, 0, 70
    win_mult = mult
    blip_i = 0
    say(line1, mult >= 100 and "jackpot" or "win")
    if mult >= 100 then
      music(-1, 334) -- 让位给号角
      music_stopped = true
      shake_t = 30
      sfx(5, CH_JINGLE)
      sfx(6, CH_HARM)
      spawn_coins(40)
    elseif mult >= 5 then
      shake_t = 10
      sfx(4, CH_JINGLE)
      spawn_coins(min(10 + mult, 26))
    else
      sfx(3, CH_JINGLE)
      spawn_coins(6)
    end
  else
    state = "idle"
    attract_t = 0
    if credits <= 0 then
      say("破产了！按 K 领 20 币", "warn")
    else
      say("祝好运！", nil)
    end
  end
end

local function update_reel(i)
  local r = reels[i]
  if r.phase == "spin" then
    r.vel = min(0.45, r.vel + 0.028)
    r.pos = r.pos + r.vel
    if spin_t >= r.stop_at then
      r.phase = "coast"
      r.target = landing(r.pos, r.want, 3)
    end
  elseif r.phase == "coast" then
    r.pos = r.pos + r.vel
    if r.target - r.pos <= 2.0 then
      r.phase = "ease"
      r.dist = r.target - r.pos
      r.ease_t = 0
      r.ease_n = max(11, flr(r.dist / 0.35))
    end
  elseif r.phase == "ease" then
    r.ease_t = r.ease_t + 1
    local u = min(1, r.ease_t / r.ease_n)
    local w = 1 - u
    r.pos = r.target - r.dist * w * w * w
    if u >= 1 then
      r.pos = r.target
      r.phase = "bounce"
      r.bt = 0
      sfx(2, CH_THUNK) -- 停轮重击
    end
  elseif r.phase == "bounce" then
    r.bt = r.bt + 1
    local u = r.bt / 9
    r.dy = 4 * sin(u * 0.5) * (1 - u) -- 落定回弹（像素）
    if r.bt >= 9 then
      r.phase = "done"
      r.dy = 0
    end
  end
end

-- ---------------------------------------------------------------- 初始化

function _init()
  bake_symbols()
  init_all_sfx()
  init_music()

  credits = dget(0)
  if credits <= 0 then credits = 20 end
  best = dget(1)
  music_on = dget(2) == 0 -- 槽位 2：0＝开（默认）
  if music_on then music(0, 500, 0x70) end -- ch4-6 交给音乐
  bet = 1
  t = 0
  state = "idle"
  auto = false
  lever_t = 0
  attract_t = 0
  show_pay = false
  saved_flash = 0
  shake_t = 0
  cred_flash = 0
  music_stopped = false
  win_cols = {}
  win_mult = 0
  coins = {}
  reels = {}
  for i = 1, 3 do
    reels[i] = {pos = flr(rnd(8)), phase = "done", vel = 0, dy = 0, want = 0,
                target = 0, stop_at = STOP_T[i]}
  end
  say("祝好运！", nil)
end

-- ---------------------------------------------------------------- 帧循环

function _update()
  t = t + 1
  if saved_flash > 0 then saved_flash = saved_flash - 1 end
  if shake_t > 0 then shake_t = shake_t - 1 end
  if cred_flash > 0 then cred_flash = cred_flash - 1 end

  -- 金币粒子：落入出币口，弹两下后滞留
  for i = #coins, 1, -1 do
    local c = coins[i]
    c.x = c.x + c.vx
    c.y = c.y + c.vy
    c.vy = c.vy + 0.25
    c.ph = c.ph + 0.13
    c.life = c.life - 1
    if c.y > 224 and c.vy > 0 then
      c.y = 224
      if c.bounce < 2 and abs(c.vy) > 1.2 then
        c.vy = -c.vy * 0.45
        c.vx = c.vx * 0.7
        c.bounce = c.bounce + 1
      else
        c.vy = 0
        c.vx = 0
        c.life = max(c.life, 50) -- 在出币口里躺一会儿
      end
    end
    if c.life <= 0 or c.y > 258 then table.remove(coins, i) end
  end

  if show_pay then
    if btnp(9) or btnp(4) or btnp(5) then show_pay = false end
    return
  end

  if state == "idle" then
    if dirp(2) then -- ↑：调注梯度上一档
      for _, b in ipairs(BETS) do
        if b > bet then bet = b break end
      end
      sfx(11, CH_UI)
    end
    if dirp(3) then -- ↓
      for i = #BETS, 1, -1 do
        if BETS[i] < bet then bet = BETS[i] break end
      end
      sfx(11, CH_UI)
    end
    if btnp(5) then -- X：满注／破产领币
      if credits <= 0 then
        credits = 20
        sfx(12, CH_UI)
        say("赠送 20 币，接着玩！", "win")
      else
        bet = mid(1, flr(credits), 99)
        sfx(11, CH_UI)
      end
    end
    if btnp(9) then show_pay = true end
    if btnp(10) then -- Tab：音乐开关
      music_on = not music_on
      dset(2, music_on and 0 or 1)
      if music_on then music(0, 334, 0x70) else music(-1, 167) end
    end
    if btnp(11) then
      dset(0, credits)
      dset(1, best)
      fflush()
      saved_flash = 40
      sfx(12, CH_UI)
    end
    if btnp(4) then
      auto = false
      attract_t = 0
      pull_lever()
    else
      attract_t = attract_t + 1
      if attract_t > 300 then
        auto = true
        if credits <= 0 then credits = 20 end
        pull_lever()
      end
    end

  elseif state == "spinning" then
    spin_t = spin_t + 1
    if lever_t > 0 then
      lever_t = lever_t + 1
      if lever_t > 14 then lever_t = 0 end
    end
    if btnp(4) then
      -- 逐轮快停：每按一次 Z 停下一只仍在全速旋转的滚轮
      for i = 1, 3 do
        local r = reels[i]
        if r.phase == "spin" then
          r.phase = "coast"
          r.target = landing(r.pos, r.want, 1.6)
          break
        end
      end
    end

    local ta = tease_active()
    if ta then
      tease_snd = true
    else
      tease_snd = false
    end
    -- 悬念滴答（包络每 SFX 一次，颗粒音由 Lua 每隔 10 帧交替重触发）
    if tease_snd and t % 10 == 0 then
      sfx(13 + flr(t / 10) % 2, CH_TENSE)
    end
    -- 棘轮滴答（每 3 帧一次，随轮速）
    if t % 3 == 0 then
      sfx(1, CH_RATCHET)
    end

    local all_done = true
    for i = 1, 3 do
      update_reel(i)
      if reels[i].phase ~= "done" then all_done = false end
    end
    if all_done then evaluate() end

  elseif state == "payout" then
    if pay_left > 0 then
      pay_t = pay_t + 1
      if pay_t >= 2 then
        pay_t = 0
        local chunk = max(1, flr(pay_total / 25))
        chunk = min(chunk, pay_left)
        credits = credits + chunk
        pay_left = pay_left - chunk
        cred_flash = 8
        sfx(7 + blip_i % 4, CH_BLIP) -- 计币音阶递升
        blip_i = blip_i + 1
        if win_mult >= 100 then spawn_coins(2) end -- 头奖持续撒币
      end
    else
      pay_hold = pay_hold - 1
      if pay_hold <= 0 then
        state = "idle"
        attract_t = 0
        if pay_total > best then
          best = pay_total
          dset(1, best)
          fflush()
        end
        if music_stopped then
          music_stopped = false
          if music_on then music(0, 500, 0x70) end
        end
        say("祝好运！", nil)
      end
    end
  end
end

-- ---------------------------------------------------------------- 绘制

-- 大字：暗红描边＋投影
local function big_text(s, x, y, c)
  print(s, x + 1, y + 1, 15)
  print(s, x - 1, y, 15)
  print(s, x + 1, y, 15)
  print(s, x, y - 1, 15)
  print(s, x, y + 1, 15)
  print(s, x, y, c)
end

-- 灯泡：光晕＋亮芯
local function bulb(x, y, on, strobe)
  if on then
    circfill(x, y, 3, 18)
    circfill(x, y, 1, strobe and 22 or 22)
  else
    circfill(x, y, 2, 17)
  end
end

-- 中奖射线（头奖）
local function draw_rays(cx, cy, col)
  for i = 0, 9 do
    if i % 2 == 0 then
      local a = t * 0.004 + i * 0.1
      local x1 = cx + cos(a - 0.02) * 40
      local y1 = cy + sin(a - 0.02) * 40
      local x2 = cx + cos(a + 0.02) * 40
      local y2 = cy + sin(a + 0.02) * 40
      trifill(cx, cy, x1, y1, x2, y2, col)
    end
  end
end

-- 实体圆键（拟物）：按下时下陷
local function dome_key(x, y, r, c_main, c_hi, label, pressed)
  circfill(x, y + 2, r, 15) -- 井影
  local dy = pressed and 1 or 0
  local rr = r - (pressed and 1 or 0)
  circfill(x, y + dy, rr, c_main)
  circfill(x - r / 3, y - r / 3 + dy, 2, c_hi)
  print(label, x - 3, y - 6 + dy, 22)
end

-- 机框螺丝（拟物）
local function screw(x, y)
  circfill(x, y, 2, 9)
  circ(x, y, 2, 10)
  line(x - 1, y - 1, x + 1, y + 1, 11)
end

local function draw_cabinet()
  -- 顶部招牌（深红＋金框＋角饰＋背光）
  rectfill(16, 2, 224, 28, 15)
  rect(16, 2, 224, 28, 17)
  fillp(0x4444)
  rectfill(54, 5, 148, 22, 61 * 256 + 15) -- 标题背光板
  fillp()
  local s = "幸运老虎机"
  print(s, 89, 9, 62)
  print(s, 88, 8, 23)
  spr(1, 62, 8)
  spr(1, 178, 8)
  circfill(24, 8, 2, 30); circfill(231, 8, 2, 30)
  circfill(24, 23, 2, 30); circfill(231, 23, 2, 30)

  -- HUD 面板（币／注）
  rectfill(24, 33, 208, 15, 15)
  rect(24, 33, 208, 15, 17)
  circ(34, 40, 6, 17)
  circfill(34, 40, 6, 30)
  circfill(32, 38, 2, 21)
  local cc = 22
  if cred_flash > 0 and flr(t / 2) % 2 == 0 then cc = 60 end
  print("币 " .. fmt(credits), 46, 34, cc)
  local bs = "注 " .. fmt(bet)
  print(bs, 206 - tw(bs), 34, 22)
  circfill(216, 40, 5, 8)
  circ(216, 40, 5, 10)
  pset(212, 38, 10); pset(220, 38, 10)
  pset(212, 42, 10); pset(220, 42, 10)

  -- 机框（多层金色浮雕：亮上暗下）
  rectfill(24, 52, 208, 88, 17)
  rectfill(24, 52, 208, 2, 22)
  rectfill(24, 138, 208, 2, 1)
  rectfill(24, 54, 2, 84, 22)
  rectfill(230, 54, 2, 84, 1)
  rectfill(28, 56, 200, 80, 1) -- 内槽（列缝隙可见）
  for i = 1, 3 do
    rectfill(REEL_X[i], WIN_Y, 64, WIN_H, 22)
  end

  -- 拉杆（右侧）
  local ly = lever_y()
  rectfill(234, 54, 8, 14, 11)
  rect(234, 54, 8, 14, 10)
  line(238, 60, 238, ly, 10)
  line(240, 60, 240, ly, 9)
  circ(239, ly, 6, 62)
  circfill(239, ly, 6, 60)
  circfill(237, ly - 2, 2, 57)

  -- 中线标（两侧箭头）
  local mc = 30
  if state == "payout" and pay_hold > 10 then
    mc = (flr(t / 3) % 2 == 0) and 11 or 28
  elseif state == "spinning" then
    mc = (flr(t / 5) % 2 == 0) and 27 or 25
  elseif tease_active() then
    mc = (flr(t / 3) % 2 == 0) and 11 or 27
  end
  trifill(13, 88, 13, 102, 22, 95, mc)
  trifill(243, 88, 243, 102, 234, 95, mc)

  -- 跑马灯（机框上下沿）：常态追逐，悬念加速，中奖全闪
  local winning = state == "payout" and win_mult >= 2
  for i = 0, 12 do
    local x = 32 + i * 16
    local on
    if winning then
      on = flr(t / 3) % 2 == 0
    elseif tease_active() then
      on = (i + flr(t / 2)) % 2 == 0
    else
      on = (i + flr(t / 6)) % 3 == 0
    end
    bulb(x, 52, on, winning)
    bulb(x, 140, on, winning)
  end

  -- 机框四角螺丝
  screw(26, 54); screw(230, 54); screw(26, 138); screw(230, 138)

  -- 出币口（拟物：金币落入并滞留）
  rectfill(44, 214, 168, 22, 17)
  rectfill(48, 217, 160, 16, 15)
  rectfill(52, 221, 152, 9, 11)
  line(52, 230, 204, 230, 1)

  -- 实体键（右侧）：J 启动／K 满注
  dome_key(240, 158, 9, 11, 13, "J", btn(4))
  dome_key(240, 184, 7, 27, 29, "K", btn(5))
end

-- 瓦片号 → 精灵表源坐标（256 宽，每行 16 张）
local function tile_src(id)
  return (id % 16) * 16, flr(id / 16) * 16
end

local function draw_reels()
  for i = 1, 3 do
    local r = reels[i]
    local x = REEL_X[i]
    clip(x, WIN_Y, 64, WIN_H)
    local base = flr(r.pos)
    -- 行底色带（随轮滚动，交替奶白）
    for k = -2, 2 do
      local idx = base + k
      local y = PAY_Y - 8 + (r.pos - idx) * PITCH + r.dy
      rectfill(x + 1, y - 5, 62, 26, idx % 2 == 0 and 22 or 22)
    end
    -- 派彩线浅金衬带
    rectfill(x + 1, 89, 62, 13, 21)
    -- 符号（拟物滚筒曲率：离中线越远越扁，sspr 纵向压缩）
    for k = -2, 2 do
      local idx = base + k
      local y = PAY_Y - 8 + (r.pos - idx) * PITCH + r.dy
      local by = 0
      if state == "payout" and win_cols[i] and k == 0 then
        by = -abs(sin(t * 0.09)) * 3 -- 中奖符号跳动
      end
      local yc = y + by + 8 - PAY_Y -- 符号中心离中线距离（像素）
      local h = 16 - mid(0, flr(abs(yc) / 6.5), 4)
      local sx, sy = tile_src(strip[i][(idx % 8) + 1])
      sspr(sx, sy, 16, 16, x + 24, y + by + (16 - h) / 2, 16, h)
    end
    -- 高速旋转拖影线
    if r.vel > 0.2 and (r.phase == "spin" or r.phase == "coast") then
      for j = 0, 3 do
        local yy = 58 + ((flr(r.pos * PITCH) + j * 20) % 74)
        line(x + 4, yy, x + 60, yy, 18)
      end
    end
    clip()
    -- 玻璃左右渐隐
    fillp(0x1111)
    rectfill(x, WIN_Y, 4, WIN_H, 2 * 256 + 22)
    rectfill(x + 60, WIN_Y, 4, WIN_H, 2 * 256 + 22)
    fillp()
  end
  -- 玻璃上下渐隐
  fillp(0xa5a5)
  rectfill(28, WIN_Y, 200, 5, 2 * 256 + 8)
  rectfill(28, WIN_Y + WIN_H - 5, 200, 5, 2 * 256 + 8)
  fillp()
  -- 玻璃斜向反光（拟物：整块面板玻璃的两道高光）
  for yy = 0, WIN_H - 1 do
    local x0 = flr(34 + yy * 1.25)
    for j = 0, 4 do
      local xx = x0 + j
      if xx >= 28 and xx <= 227 and (xx + yy * 2) % 3 == 0 then
        pset(xx, WIN_Y + yy, 22)
      end
    end
    local x1 = flr(150 + yy * 1.25)
    for j = 0, 2 do
      local xx = x1 + j
      if xx >= 28 and xx <= 227 and (xx + yy * 2) % 3 == 0 then
        pset(xx, WIN_Y + yy, 22)
      end
    end
  end
  -- 悬念：第三轮窗口边框闪烁
  if tease_active() and flr(t / 3) % 2 == 0 then
    rect(REEL_X[3] - 1, WIN_Y - 1, 66, WIN_H + 2, 60)
  end
  -- 中奖列闪框
  if state == "payout" and pay_hold > 8 and flr(t / 3) % 2 == 0 then
    for i = 1, 3 do
      if win_cols[i] then
        rect(REEL_X[i] + 21, 84, 22, 22, win_mult >= 100 and 60 or 30)
      end
    end
  end
end

local function draw_message()
  if state == "payout" then
    local flash = (flr(t / 4) % 2 == 0)
    if win_mult >= 100 then
      draw_rays(128, 178, 26)
      big_text("头奖！！", (256 - tw("头奖！！")) / 2, 146, flash and 11 or 28)
      big_text(msg, (256 - tw(msg)) / 2, 168, 30)
    elseif win_mult >= 5 then
      big_text(msg, (256 - tw(msg)) / 2, 152, flash and 27 or 30)
    else
      big_text(msg, (256 - tw(msg)) / 2, 152, 27)
    end
    local got = pay_total - pay_left
    if got > 0 then
      local s2 = "赢 " .. fmt(got) .. " 币"
      big_text(s2, (256 - tw(s2)) / 2, 192, 7)
    end
  else
    print(msg, (256 - tw(msg)) / 2, 156,
          msg_kind == "warn" and 58 or (msg_kind == "win" and 30 or 9))
  end
  if saved_flash > 0 and flr(saved_flash / 8) % 2 == 0 then
    local s = "已存档！" -- 盖在出币口上（拟物：铭牌）
    print(s, (256 - tw(s)) / 2, 216, 30)
  end
end

local function draw_coins()
  for i = 1, #coins do
    local c = coins[i]
    local r = 1.6 + abs(sin(c.ph)) * 1.8 -- 旋转观感
    circfill(c.x, c.y, r, 30)
    circfill(c.x - r * 0.3, c.y - r * 0.3, r * 0.35, 21)
  end
end

local function draw_bottom()
  rectfill(0, 238, 256, 18, 0)
  line(0, 238, 255, 238, 17)
  local s
  if state == "idle" and attract_t > 200 then
    if flr(t / 16) % 2 == 0 then s = "自动演示中" end
  else
    local hints = {
      "J 拉杆　W/S 调注　K 满注",
      "L 赔率表　Enter 存档",
      "旋转中 J 逐轮快停",
    }
    s = hints[flr(t / 120) % 3 + 1]
  end
  if s then print(s, (256 - tw(s)) / 2, 240, 9) end
end

local function draw_paytable()
  fillp(0xa5a5) -- 棋盘抖动压暗底图
  rectfill(0, 0, 256, 256, 2 * 256 + 0)
  fillp()

  local px, py, pw, ph = 40, 24, 176, 208
  rectfill(px - 3, py - 3, pw + 6, ph + 6, 17)
  rectfill(px, py, pw, ph, 15)
  rect(px, py, pw, ph, 30)
  local s = "赔率表"
  print(s, (256 - tw(s)) / 2, 32, 23)

  for i = 1, 6 do
    local y = 50 + (i - 1) * 18
    spr(i, px + 14, y - 2)
    local nm = NAME[i] .. " 三连"
    print(nm, px + 38, y, 7)
    local m = "×" .. fmt(PAY3[i])
    print(m, px + pw - 16 - tw(m), y, 30)
  end
  local notes = {
    {"双樱 ×2　单樱 ×1", 7},
    {"其他一对：返注", 7},
    {"历史最佳赢：" .. fmt(best) .. " 币", 30},
    {"Tab 音乐　J 关闭", 53},
  }
  for i = 1, 4 do
    local ns = notes[i][1]
    print(ns, (256 - tw(ns)) / 2, 158 + (i - 1) * 16, notes[i][2])
  end
end

function _draw()
  -- 头奖震屏（camera 是轴 aligned 平移，全画面整体抖动）
  if shake_t > 0 then
    camera(flr(rnd(5)) - 2, flr(rnd(5)) - 2)
  else
    camera(0, 0)
  end
  -- v0.7 显示期调色映射：头奖期间丝绒底色整屏脉动为金色（帧缓冲不变）
  pal()
  if state == "payout" and win_mult >= 100 and flr(t / 4) % 2 == 0 then
    pal(62, 30, 1)
    pal(61, 22, 1)
  end
  cls(62)
  -- 丝绒质感底纹（稀疏点阵抖动）＋左右暗角（拟物机身收边）
  fillp(0x1084)
  rectfill(0, 0, 256, 256, 61 * 256 + 62)
  fillp()
  fillp(0xa5a5)
  rectfill(0, 0, 8, 256, 15 * 256 + 62)
  rectfill(248, 0, 8, 256, 15 * 256 + 62)
  fillp()

  draw_cabinet()
  draw_reels()
  draw_message()
  draw_coins()
  draw_bottom()

  -- 头奖：屏幕边框频闪
  if state == "payout" and win_mult >= 100 then
    rect(1, 1, 254, 254, flr(t / 3) % 2 == 0 and 60 or 30)
  end
  if show_pay then draw_paytable() end
end
