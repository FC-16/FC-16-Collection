-- 数独 ・ FC-16 演示卡带
-- 经典 9×9 数独：三档难度（入门 40 提示数 / 进阶 32 / 困难 26），全部由卡带内
-- 回溯算法现场生成。出题流水线切片到多幀执行（协程 + 每幀预算），绝不单幀算完：
--   1) 随机候选顺序回溯生成完整终盘；
--   2) 中心对称挖洞，每移除一格（对）都用「解数计数器（数到 2 即止）」验证唯一解，
--      不唯一立即回填；MRV（候选最少格优先）保证验证高效。
-- 操作：光标移动 → Ⓐ 呼出数字条 → 选数确认；Ⓑ 擦除；LB 铅笔候选（3×3 小字，
--       填数自动清理同行/列/宫同数候选）；RB 提示揭示答案（每局 3 次）；
--       Ⓧ 冲突检查开关（标红行/列/宫内重复）；Menu 暂停菜单；View 音乐开关。
--       （提示文案一律 btnicon 图标：Ⓐ=btnicon("a")、LB=btnicon("lb")、RB=btnicon("rb")）
-- 辅助：光标行列宫淡染、同数高亮、给定双描白字 / 玩家青蓝 / 提示绿 / 冲突红、
--       数字条余量计数；胜利斜向金波扫场 + 结算（用时/提示/填错/新纪录）。
-- 音频：移动/填数（按数字五声音阶变调）/擦除/填错/提示/胜利 SFX + 原创
--       4 小节 C 五声舒缓 BGM 循环（View 开关）。
-- 存档：各难度最佳用时 dset(0..2)、最少提示 dset(3..5)、音乐开关 dset(6)，整数
--       秒存储，fflush 持久化（SPEC §13）。

-- ---------------------------------------------------------------- 常量

local CELL = 18                      -- 格边长（9×18 = 162）
local BX, BY = 47, 24                -- 棋盘左上像素（x 47..209，y 24..186）
local BAR_Y, KEY_W, KEY_H = 190, 24, 26 -- 底部数字条：y 190..216
local STAT_Y, TIP_Y = 220, 240       -- 铅笔/检查指示行 ・ 底部提示栏

-- 色号（SPEC §2.2 色表直取；禁止色号算术推导明暗）
local C_PAGE   = 14  -- 页面底 #0E071B
local C_HUD    = 13  -- 顶/底栏・面板 #1A1932
local C_CELL_D = 12  -- 棋盘深格 #2A2F4E
local C_CELL_L = 11  -- 棋盘浅格 #424C6E
local C_GRID   = 10  -- 细网格线 #657392
local C_THICK  = 8   -- 3×3 粗线/外框 #C7CFDD
local C_GIVEN  = 7   -- 给定数字 白
local C_PLAYER = 42  -- 玩家数字 亮青蓝 #00CDF9
local C_HINTC  = 33  -- 提示揭示数字 绿 #99E65F
local C_PENCIL = 9   -- 铅笔候选 #92A1B9
local C_CONFL  = 63  -- 冲突红 #FF0040
local C_CURSOR = 30  -- 光标格填充 #FFA214
local C_INK    = 16  -- 选中底上的墨色数字 #391F21
local C_GOLD   = 31  -- 亮金 #FFEB57
local C_AMBER  = 24  -- 深金（光标描边偶幀）#E07438
local C_TXT    = 8   -- 正文亮字 #C7CFDD
local C_DIM    = 10  -- 暗字 #657392

local DIFF = {
  { name = "入门", col = 33, clues = 40 },
  { name = "进阶", col = 29, clues = 32 },
  { name = "困难", col = 58, clues = 26 },
}
local HINTS_MAX = 3

-- 填数音效：数字 1-9 映射 G 大调五声音阶（任意填入都悦耳）
local PENT = { 55, 57, 59, 62, 64, 67, 69, 71, 74 }

local function idx(r, c) return r * 9 + c + 1 end
local function box_of(r, c) return flr(r / 3) * 3 + flr(c / 3) end
local function mmss(s) return string.format("%02d:%02d", flr(s / 60), s % 60) end
local function ctext(s, y, c) print(s, flr((256 - tw(s)) / 2), y, c) end

-- ---------------------------------------------------------------- 状态

local state = "splash" -- splash / title / gen / play / pause / win
local t = 0            -- 全局幀计数
local diff = 1         -- 当前难度 1..3
local title_sel = 1
local pause_sel = 1
local focus = 0        -- 0 棋盘光标 / 1 数字条
local bar_sel = 5      -- 数字条选中数字 1..9
local cx, cy = 4, 4    -- 光标（列/行，0 起）
local pencil = false   -- 铅笔候选模式
local check = false    -- Ⓧ 冲突检查显示
local hints_left = HINTS_MAX
local play_frames = 0  -- 计时幀（暂停不累计）
local mistakes = 0     -- 填错次数（与答案不符的填入）
local sol, giv, puz, own, penc -- 答案 / 题面 / 盘面 / 来源(1玩家 2提示) / 候选表
local conf = {}        -- 冲突格标记（检查模式下逐幀重算）
local rep = { 0, 0, 0, 0 }   -- 方向键按住计时（自动重复）
local rep_bar = 0            -- 数字条左右按住计时
local gen                    -- 出题协程
local gen_phase, gen_prog = 0, 0
local win_t, win_new_best, win_best_hints = 0, false, false
local music_on, bgm_on = true, false

local TIPS = {
  btnicon("a") .. " 选数　" .. btnicon("b") .. " 擦除　" .. btnicon("lb") .. " 铅笔",
  btnicon("rb") .. " 提示　" .. btnicon("x") .. " 检查　" .. btnicon("menu") .. " 菜单",
  btnicon("view") .. " 音乐开关",
}

local function set_bgm(on)
  if on then music(0, 400, 0x30) bgm_on = true
  else music(-1, 400) bgm_on = false end
end
local function toggle_music()
  music_on = not music_on
  dset(6, music_on and 0 or 1)
  fflush()
  set_bgm(music_on)
end

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

local MUSIC_BASE = 0x0C5380  -- MUSIC 区（SPEC §5.2）：+0 LEN，行 r 在 +32+r*32

-- 写一条 SFX（SPEC §5.2：144B = 头 16B + 32 步 × 4B）：steps[i] = {音高, 音色, 音量[, 效果]}，nil 步与音高 0 均为休止
-- 音高为旧固件值（1-96 = C0-B7），写卡带前换算为新 0-95 并用音量 0 表休止
local function write_sfx(id, speed, steps, len)
  local base = 0x0C0000 + id * 144
  poke2(base, (speed == 0 and 1 or speed) * 4)  -- 旧每步帧数(60Hz) → 新 SPD tick(240Hz)
  u8(base + 2, len or #steps)
  for i = 0, 31 do
    local a, s = base + 16 + i * 4, steps[i + 1]
    if s and (s[1] or 0) > 0 then u8(a, s[1] - 1) u8(a + 1, WMAP[s[2] or 0]) u8(a + 2, s[3] or 0) u8(a + 3, s[4] or 0)
    else u8(a, 0) u8(a + 1, 0) u8(a + 2, 0) u8(a + 3, 0) end
  end
end
local function expand(notes, k, wave, vol) -- 音符序列按 k 步展开（0 = 休止）
  local out, m = {}, 0
  for _, n in ipairs(notes) do
    for _ = 1, k do
      m = m + 1
      if n ~= 0 then out[m] = { n, wave, vol } end
    end
  end
  return out
end
-- BGM：C 大调五声舒缓小品，4 小节回环；旋律 ch4（ROUND）/ 贝斯 ch5（BASS），
-- speed 8：每小节 256 幀，全曲约 17 秒；MUSIC 0-3 行首 LOOP_START 末 LOOP_BACK，占 ch4-5
local BGM_MEL = {
  { 72, 0, 76, 0, 79, 0, 76, 0 }, -- C5 ・ E5 ・ G5 ・ E5
  { 69, 0, 72, 0, 74, 0, 0, 0 },  -- A4 ・ C5 ・ D5
  { 67, 0, 72, 0, 76, 0, 74, 0 }, -- G4 ・ C5 ・ E5 ・ D5
  { 72, 0, 0, 0, 67, 0, 0, 0 },   -- C5 ・ ・ ・ G4（收束回环）
}
local BGM_BASS = { 48, 45, 43, 48 } -- C3 A2 G2 C3 整小节长音

local function init_audio()
  init_waveforms()
  write_sfx(0, 1, { { 68, 3, 5 } })                          -- 菜单/光标轻响
  write_sfx(1, 1, { { 60, 3, 8 }, { 67, 3, 10 } })           -- 开始/确认
  write_sfx(2, 1, { { 56, 3, 3 } })                          -- 光标滑步（更轻）
  write_sfx(3, 1, { { 30, 15, 6 }, { 24, 15, 5 } })          -- 拒绝 buzz（噪声）
  write_sfx(5, 2, { { 52, 3, 9 }, { 45, 3, 8 } })            -- 填错下行
  write_sfx(6, 2, { { 74, 10, 9 }, { 78, 10, 9 }, { 81, 10, 10 }, { 86, 10, 11 } }) -- 提示星光
  write_sfx(7, 1, { { 72, 3, 7 }, { 76, 3, 7 } })            -- 检查开
  write_sfx(8, 1, { { 76, 3, 6 }, { 72, 3, 6 } })            -- 检查关
  write_sfx(9, 2, { { 67, 2, 10 }, { 72, 2, 10 }, { 76, 2, 11 }, { 79, 2, 11 }, nil,
    { 84, 2, 12 } }, 6)                                      -- 胜利号角（含休止，显式长度）
  write_sfx(10, 2, { { 79, 2, 11 }, { 84, 2, 11 }, { 88, 2, 12 }, nil, { 91, 2, 13 } }, 5) -- 新纪录
  write_sfx(11, 1, { { 62, 3, 7 }, { 55, 3, 6 } })           -- 暂停开合
  write_sfx(12, 1, { { 64, 3, 6 }, { 69, 3, 6 } })           -- 铅笔开关
  write_sfx(13, 2, { { 43, 11, 8 }, { 38, 11, 6 } })         -- 擦除低响
  for d = 1, 9 do -- 填数：五声音阶变调
    local p = PENT[d]
    write_sfx(19 + d, 1, { { p, 8, 11 }, { p + 12, 8, 6 } })
  end
  for r = 0, 3 do
    for c = 0, 7 do u8(MUSIC_BASE + 32 + r * 32 + c, 0xFF) end  -- 空轨写 0xFF（0 是合法 SFX 号）
  end
  for b = 1, 4 do
    write_sfx(29 + b, 8, expand(BGM_MEL[b], 4, 8, 7), 32)        -- 旋律 ROUND
    write_sfx(33 + b, 8, expand({ BGM_BASS[b] }, 32, 11, 6), 32) -- 贝斯 BASS
    local mb = MUSIC_BASE + 32 + (b - 1) * 32
    u8(mb + 4, 29 + b) u8(mb + 5, 33 + b)  -- 引用指向本行写入的旋律/贝斯 SFX
    -- （旧代码引用 29+b/33+b 按旧语义指向 SFX 28+b/32+b，ch4 首小节落在
    --   未写入的 SFX 29 上；新固件对 SPD=0 的非法头会终止 Music，故按
    --   作曲意图直接引用本段写入的 SFX ID）
    if b == 1 then u8(mb + 16, 1) end      -- LOOP_START：循环起点
    if b == 4 then u8(mb + 17, 1) end      -- LOOP_BACK：回到 LOOP_START
  end
  u8(MUSIC_BASE, 4)  -- 全表 LEN = 4 行
end

-- ---------------------------------------------------------------- 小字烘焙

-- 精灵表像素写入：表坐标 (u,v) → 瓦片 (v/16)*16+u/16，瓦片内偏移 (u%16, v%16)
local function spset(u, v, c)
  poke((flr(v / 16) * 16 + flr(u / 16)) * 256 + (v % 16) * 16 + u % 16, c)
end
-- 3×5 微型数字（铅笔候选/数字条余量）：白色烘入表区 y=16 行，画时 pal 重映射
local TINY = {
  [0] = { 7, 5, 5, 5, 7 },                                   -- 0
  { 2, 6, 2, 2, 7 }, { 7, 1, 7, 4, 7 }, { 7, 1, 7, 1, 7 },   -- 1 2 3
  { 5, 5, 7, 1, 1 }, { 7, 4, 7, 1, 7 }, { 7, 4, 7, 5, 7 },   -- 4 5 6
  { 7, 1, 2, 2, 2 }, { 7, 5, 7, 5, 7 }, { 7, 5, 7, 1, 7 },   -- 7 8 9
}
local function bake_tiny()
  for d = 0, 9 do
    local rows = TINY[d]
    for ry = 0, 4 do
      local bits = rows[ry + 1]
      for rx = 0, 2 do
        if flr(bits / (2 ^ (2 - rx))) % 2 == 1 then
          spset(d * 4 + rx, 16 + ry, 7)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- 出题引擎（协程分幀）

-- 预计算格位元信息：RC[i] = {r, c, b}；行/列/宫的格索引清单
local RC, ROWS, COLS, BOXS = {}, {}, {}, {}
local function build_maps()
  for r = 0, 8 do
    ROWS[r], COLS[r], BOXS[r] = {}, {}, {}
  end
  for r = 0, 8 do
    for c = 0, 8 do
      local i, b = idx(r, c), box_of(r, c)
      RC[i] = { r = r, c = c, b = b }
      ROWS[r][#ROWS[r] + 1] = i
      COLS[c][#COLS[c] + 1] = i
      BOXS[b][#BOXS[b] + 1] = i
    end
  end
end

local NG = { bd = {}, rows = {}, cols = {}, boxs = {} } -- 出题工作区
local ng_nodes = 0   -- 验证节点计数（分幀切片用）

local function ng_set(i, d, on) -- 在 NG 盘面放置/撤除一个数字
  local rc = RC[i]
  NG.rows[rc.r][d] = on and true or nil
  NG.cols[rc.c][d] = on and true or nil
  NG.boxs[rc.b][d] = on and true or nil
  NG.bd[i] = on and d or 0
end

-- 解数计数：MRV（候选最少空格优先）回溯，数满 limit 即早退。
-- 在出题协程内调用：每 12 个验证节点 yield 一次，由幀驱动器限流。
local function ng_count(limit)
  local rows, cols, boxs = {}, {}, {}
  for i = 0, 8 do rows[i], cols[i], boxs[i] = {}, {}, {} end
  local empties = {}
  for i = 1, 81 do
    local d, rc = NG.bd[i], RC[i]
    if d ~= 0 then
      rows[rc.r][d], cols[rc.c][d], boxs[rc.b][d] = true, true, true
    else
      empties[#empties + 1] = i
    end
  end
  local count = 0
  ng_nodes = 0
  local function solve()
    local bi, bc, bn = nil, nil, 10
    for k = 1, #empties do
      local i = empties[k]
      if NG.bd[i] == 0 then
        local rc = RC[i]
        local cands, n = {}, 0
        for d = 1, 9 do
          if not rows[rc.r][d] and not cols[rc.c][d] and not boxs[rc.b][d] then
            n = n + 1
            cands[n] = d
          end
        end
        if n == 0 then return false end          -- 死局剪枝：该空格无数可填
        if n < bn then
          bi, bc, bn = i, cands, n
          if n == 1 then break end               -- 已是下界，提前收手
        end
      end
    end
    if not bi then                               -- 无空格：找到一个完整解
      count = count + 1
      return count >= limit
    end
    local rc = RC[bi]
    for k = 1, bn do
      local d = bc[k]
      rows[rc.r][d], cols[rc.c][d], boxs[rc.b][d] = true, true, true
      NG.bd[bi] = d
      ng_nodes = ng_nodes + 1
      if ng_nodes % 12 == 0 then coroutine.yield() end
      local stop = solve()
      NG.bd[bi] = 0
      rows[rc.r][d], cols[rc.c][d], boxs[rc.b][d] = nil, nil, nil
      if stop then return true end
    end
    return false
  end
  solve()
  return count
end

-- 出题流水线（在协程内执行）：阶段 0 构建终盘 → 阶段 1 对称挖洞 + 唯一解验证
local function gen_worker()
  NG.bd = {}
  for i = 0, 8 do
    NG.rows[i] = {}
    NG.cols[i] = {}
    NG.boxs[i] = {}
  end
  for i = 1, 81 do NG.bd[i] = 0 end
  gen_phase, gen_prog = 0, 0
  -- 阶段 0：随机候选顺序回溯填满整盘
  local nodes = 0
  local function fill(i)
    if i > 81 then return true end
    local rc = RC[i]
    local cands = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
    for n = 9, 2, -1 do                          -- Fisher-Yates 洗牌
      local j = flr(rnd(n)) + 1
      cands[n], cands[j] = cands[j], cands[n]
    end
    for k = 1, 9 do
      local d = cands[k]
      if not NG.rows[rc.r][d] and not NG.cols[rc.c][d] and not NG.boxs[rc.b][d] then
        ng_set(i, d, true)
        nodes = nodes + 1
        if nodes % 24 == 0 then coroutine.yield() end
        if fill(i + 1) then return true end
        ng_set(i, d, false)
      end
    end
    return false
  end
  fill(1)
  NG.sol = {}                                    -- 另存完整终盘（挖洞只改 bd）
  for i = 1, 81 do NG.sol[i] = NG.bd[i] end
  -- 阶段 1：中心对称挖洞。先成对移除 (i, 82-i)，不唯一即回填；凑近目标后
  -- 单格补挖。每次移除都经解数计数器（最多数到 2）验证唯一解。
  gen_phase = 1
  local target = DIFF[diff].clues
  local filled = 81
  local order = {}
  for k = 0, 40 do order[k + 1] = k end
  for n = 41, 2, -1 do
    local j = flr(rnd(n)) + 1
    order[n], order[j] = order[j], order[n]
  end
  for k = 1, 41 do
    if filled <= target then break end
    local i1 = order[k] + 1                      -- 1..41
    local i2 = 82 - i1                           -- 81..41（i1=41 时重合为中心格）
    if NG.bd[i1] ~= 0 then
      local v1, v2 = NG.bd[i1], NG.bd[i2]
      NG.bd[i1], NG.bd[i2] = 0, 0
      if ng_count(2) == 1 then
        filled = filled - (i1 == i2 and 1 or 2)
      else
        NG.bd[i1], NG.bd[i2] = v1, v2
      end
      gen_prog = (81 - filled) / (81 - target)
      coroutine.yield()
    end
  end
  for k = 1, 41 do                               -- 单格补挖到目标提示数
    if filled <= target then break end
    local i1 = order[k] + 1
    if NG.bd[i1] ~= 0 then
      local v1 = NG.bd[i1]
      NG.bd[i1] = 0
      if ng_count(2) == 1 then filled = filled - 1 else NG.bd[i1] = v1 end
      gen_prog = (81 - filled) / (81 - target)
      coroutine.yield()
    end
  end
  gen_prog = 1
end

-- ---------------------------------------------------------------- 对局流程

local board_full           -- 前置声明
local recompute_conflicts  -- 前置声明（定义见「冲突标记」节）

local function clear_pencil_units(i, d) -- 填入 d 后清理同行/列/宫的 d 候选
  local rc = RC[i]
  for _, j in ipairs(ROWS[rc.r]) do penc[j][d] = nil end
  for _, j in ipairs(COLS[rc.c]) do penc[j][d] = nil end
  for _, j in ipairs(BOXS[rc.b]) do penc[j][d] = nil end
  penc[i] = {}
end

function board_full()
  for i = 1, 81 do
    if puz[i] ~= sol[i] then return false end
  end
  return true
end

local function on_win()
  state = "win"
  win_t = 0
  local secs = flr(play_frames / 60)
  local slot = diff - 1
  local best = flr(dget(slot))
  win_new_best = best == 0 or secs < best
  if win_new_best then dset(slot, secs) end
  local used = HINTS_MAX - hints_left
  local hb = flr(dget(3 + slot))
  win_best_hints = hb == 0 or used + 1 < hb     -- 槽位存用量+1，0 = 未记录
  if win_best_hints then dset(3 + slot, used + 1) end
  if win_new_best or win_best_hints then fflush() end
  sfx(9, 2)
end

local function apply_digit(d)
  local i = idx(cy, cx)
  if giv[i] ~= 0 then sfx(3, 1) return end     -- 给定格不可改
  if pencil then                               -- 铅笔候选：切换小字
    if puz[i] ~= 0 then sfx(3, 1) return end
    if penc[i][d] then penc[i][d] = nil else penc[i][d] = true end
    sfx(12, 1)
    return
  end
  if puz[i] == d then sfx(0, 0) return end     -- 重复填同数：轻响带过
  puz[i] = d
  own[i] = 1
  if d == sol[i] then
    sfx(19 + d, 0)
  else
    mistakes = mistakes + 1
    sfx(5, 1)
  end
  clear_pencil_units(i, d)
  if board_full() then on_win() end
end

local function erase_cell()
  local i = idx(cy, cx)
  if giv[i] ~= 0 then sfx(3, 1) return end
  local had_digit = puz[i] ~= 0
  local had_penc = next(penc[i]) ~= nil
  if pencil then                               -- 铅笔模式：只清候选
    penc[i] = {}
    sfx(had_penc and 13 or 2, 0)
  else
    puz[i] = 0
    own[i] = 0
    penc[i] = {}
    sfx((had_digit or had_penc) and 13 or 2, 0)
  end
end

local function use_hint()
  local i = idx(cy, cx)
  if hints_left <= 0 or giv[i] ~= 0 or puz[i] == sol[i] then
    sfx(3, 1)
    return
  end
  puz[i] = sol[i]
  own[i] = 2
  hints_left = hints_left - 1
  clear_pencil_units(i, sol[i])
  sfx(6, 1)
  if board_full() then on_win() end
end

local function start_gen()
  srand(frame())                               -- 以开局幀号为种子（确定性随机）
  gen_phase, gen_prog = 0, 0
  gen = coroutine.create(gen_worker)
  state = "gen"
end

local function finish_gen()                    -- 装填棋局，进入对局
  sol, giv, puz, own, penc = {}, {}, {}, {}, {}
  for i = 1, 81 do
    sol[i] = NG.sol[i]
    giv[i] = NG.bd[i]
    puz[i] = NG.bd[i]
    own[i] = 0
    penc[i] = {}
    conf[i] = false
  end
  hints_left, mistakes, play_frames = HINTS_MAX, 0, 0
  cx, cy, focus, bar_sel = 4, 4, 0, 5
  pencil, check = false, false
  rep, rep_bar = { 0, 0, 0, 0 }, 0
  gen = nil
  state = "play"
  sfx(1, 0)
end

local function restart_puzzle()                -- 重开本题：恢复题面
  for i = 1, 81 do
    puz[i] = giv[i]
    own[i] = 0
    penc[i] = {}
    conf[i] = false
  end
  hints_left, mistakes, play_frames = HINTS_MAX, 0, 0
  cx, cy, focus = 4, 4, 0
  pencil, check = false, false
  rep, rep_bar = { 0, 0, 0, 0 }, 0
  state = "play"
  sfx(1, 0)
end

local function to_title()
  state = "title"
  title_sel = diff
end

-- ---------------------------------------------------------------- 更新

local function update_title()
  if dirp(2) or dirp(3) or dirp(0) or dirp(1) then
    title_sel = title_sel % 3 + 1              -- 任意方向键循环切换难度
    sfx(0, 0)
  end
  if btnp(10) then toggle_music() end
  if btnp(4) or btnp(11) then
    diff = title_sel
    sfx(1, 0)
    start_gen()
  end
end

local function update_gen()
  if btnp(10) then toggle_music() end
  if btnp(11) then                             -- Menu 取消出题回标题
    state = "title"
    gen = nil
    sfx(11, 0)
    return
  end
  for _ = 1, 4 do                              -- 每幀最多 4 段切片（预算内）
    if gen == nil or coroutine.status(gen) == "dead" then break end
    local ok, err = coroutine.resume(gen)
    if not ok then error(err) end
  end
  if gen ~= nil and coroutine.status(gen) == "dead" then finish_gen() end
end

local function update_play()
  if btnp(10) then toggle_music() end
  if btnp(11) then
    state = "pause"
    pause_sel = 1
    sfx(11, 0)
    return
  end
  play_frames = play_frames + 1                -- 计时仅对局中推进
  if focus == 0 then
    for d = 0, 3 do                            -- 光标移动：首按即动 + 自动重复
      if dir(d) then
        rep[d + 1] = rep[d + 1] + 1
        if rep[d + 1] == 1 or (rep[d + 1] > 14 and rep[d + 1] % 3 == 0) then
          if d == 0 and cx > 0 then cx = cx - 1 sfx(2, 0)
          elseif d == 1 and cx < 8 then cx = cx + 1 sfx(2, 0)
          elseif d == 2 and cy > 0 then cy = cy - 1 sfx(2, 0)
          elseif d == 3 then
            if cy < 8 then cy = cy + 1 sfx(2, 0)
            else focus = 1 sfx(0, 0) end       -- 底行再按下 → 跳到数字条
          end
        end
      else
        rep[d + 1] = 0
      end
    end
    if btnp(4) then
      if giv[idx(cy, cx)] ~= 0 then sfx(3, 1)
      else focus = 1 sfx(0, 0) end
    elseif btnp(5) then erase_cell()
    elseif btnp(8) then pencil = not pencil sfx(12, 0)
    elseif btnp(9) then use_hint()
    elseif btnp(6) then check = not check sfx(check and 7 or 8, 0)
    end
  else
    local bdir = 0                             -- 数字条：左右选数（自动重复）
    if dir(0) then bdir = -1 elseif dir(1) then bdir = 1 end
    if bdir ~= 0 then
      rep_bar = rep_bar + 1
      if rep_bar == 1 or (rep_bar > 12 and rep_bar % 2 == 0) then
        bar_sel = (bar_sel + bdir + 8) % 9 + 1
        sfx(0, 0)
      end
    else
      rep_bar = 0
    end
    if dirp(2) then                            -- ↑ 回棋盘
      focus = 0
      rep = { 0, 0, 0, 0 }
      sfx(0, 0)
    elseif btnp(4) then                        -- 确认填入
      local was_given = giv[idx(cy, cx)] ~= 0
      apply_digit(bar_sel)
      if not pencil or was_given then focus = 0 end -- 铅笔连填留在数字条
    elseif btnp(5) then
      focus = 0
      sfx(0, 0)
    elseif btnp(8) then                        -- 数字条上也可切换铅笔/检查、用提示
      pencil = not pencil
      sfx(12, 0)
    elseif btnp(6) then
      check = not check
      sfx(check and 7 or 8, 0)
    elseif btnp(9) then
      use_hint()
    end
  end
  recompute_conflicts()
end

local function update_pause()
  if btnp(11) or btnp(5) then
    state = "play"
    sfx(11, 0)
  elseif dirp(2) or dirp(0) then
    pause_sel = (pause_sel + 2) % 4 + 1
    sfx(0, 0)
  elseif dirp(3) or dirp(1) then
    pause_sel = pause_sel % 4 + 1
    sfx(0, 0)
  elseif btnp(4) then
    if pause_sel == 1 then
      state = "play"
      sfx(11, 0)
    elseif pause_sel == 2 then
      restart_puzzle()
    elseif pause_sel == 3 then
      sfx(1, 0)
      start_gen()
    else
      to_title()
      sfx(0, 0)
    end
  end
end

local function update_win()
  win_t = win_t + 1
  if win_t == 46 and win_new_best then sfx(10, 2) end
  if btnp(10) then toggle_music() end
  if win_t > 50 then
    if btnp(4) then
      sfx(1, 0)
      start_gen()                              -- 再来一局：同难度换新题
    elseif btnp(11) then
      to_title()
    end
  end
end

function _update()
  t = t + 1
  if state == "splash" then
    if t > 90 or btnp(4) or btnp(11) then state = "title" end
  elseif state == "title" then update_title()
  elseif state == "gen" then update_gen()
  elseif state == "play" then update_play()
  elseif state == "pause" then update_pause()
  elseif state == "win" then update_win() end
end

-- ---------------------------------------------------------------- 冲突标记

function recompute_conflicts()                 -- 检查模式：行/列/宫内重复标红
  for i = 1, 81 do conf[i] = false end
  if not check then return end
  local cnt = {}
  for u = 0, 8 do                              -- 行
    for d = 1, 9 do cnt[d] = 0 end
    for c = 0, 8 do local v = puz[idx(u, c)] if v > 0 then cnt[v] = cnt[v] + 1 end end
    for c = 0, 8 do local v = puz[idx(u, c)] if v > 0 and cnt[v] > 1 then conf[idx(u, c)] = true end end
  end
  for u = 0, 8 do                              -- 列
    for d = 1, 9 do cnt[d] = 0 end
    for r = 0, 8 do local v = puz[idx(r, u)] if v > 0 then cnt[v] = cnt[v] + 1 end end
    for r = 0, 8 do local v = puz[idx(r, u)] if v > 0 and cnt[v] > 1 then conf[idx(r, u)] = true end end
  end
  for u = 0, 8 do                              -- 宫
    for d = 1, 9 do cnt[d] = 0 end
    local r0, c0 = flr(u / 3) * 3, (u % 3) * 3
    for r = r0, r0 + 2 do
      for c = c0, c0 + 2 do
        local v = puz[idx(r, c)]
        if v > 0 then cnt[v] = cnt[v] + 1 end
      end
    end
    for r = r0, r0 + 2 do
      for c = c0, c0 + 2 do
        local v = puz[idx(r, c)]
        if v > 0 and cnt[v] > 1 then conf[idx(r, c)] = true end
      end
    end
  end
end

-- ---------------------------------------------------------------- 绘制

local function draw_dots_bg()                  -- 深底 + 稀疏点纹
  cls(C_PAGE)
  fillp(0x0842)
  rectfill(0, 0, 256, 256, C_HUD * 256 + C_PAGE)
  fillp()
end

local function draw_hud()
  rectfill(0, 0, 256, 20, C_HUD)
  line(0, 20, 255, 20, C_CELL_L)
  print(DIFF[diff].name, 4, 2, DIFF[diff].col)
  ctext(mmss(flr(play_frames / 60)), 2, 7)
  local hs = btnicon("rb") .. "×" .. hints_left
  print(hs, 252 - tw(hs), 2, hints_left > 0 and C_GOLD or C_DIM)
  if music_on then print("♪", 252 - tw(hs) - 24, 2, 30) end
end

local function draw_status()
  local s = pencil and "铅笔 开" or "铅笔 关"
  print(s, 4, STAT_Y, pencil and C_GOLD or C_DIM)
  s = check and "检查 开" or "检查 关"
  print(s, 252 - tw(s), STAT_Y, check and C_CONFL or C_DIM)
end

local function draw_tips()
  rectfill(0, TIP_Y, 256, 16, C_HUD)
  line(0, TIP_Y, 255, TIP_Y, C_CELL_L)
  ctext(TIPS[flr(t / 240) % #TIPS + 1], TIP_Y, C_DIM)
end

local function draw_board()
  local cursor_on = focus == 0 and state ~= "win"
  local cv = puz[idx(cy, cx)]
  -- 格底 + 三层高亮（光标行列宫淡染 → 同数高亮 → 冲突红染）
  for r = 0, 8 do
    for c = 0, 8 do
      local i = idx(r, c)
      local px, py = BX + c * CELL, BY + r * CELL
      local is_cur = cursor_on and r == cy and c == cx
      local base = (r + c) % 2 == 0 and C_CELL_L or C_CELL_D
      if is_cur then
        rectfill(px, py, CELL, CELL, C_CURSOR)
      else
        rectfill(px, py, CELL, CELL, base)
        if cursor_on and (r == cy or c == cx or box_of(r, c) == box_of(cy, cx)) then
          fillp(0x2222)
          rectfill(px, py, CELL, CELL, C_CURSOR * 256 + base)
          fillp()
        end
        if cursor_on and cv ~= 0 and puz[i] == cv then
          fillp(0x8888)
          rectfill(px, py, CELL, CELL, C_GOLD * 256 + base)
          fillp()
        end
        if conf[i] then
          fillp(0x2222)
          rectfill(px, py, CELL, CELL, C_CONFL * 256 + base)
          fillp()
        end
      end
    end
  end
  -- 网格线：细线 1px ・ 3×3 粗线 2px
  for k = 1, 8 do
    local p = k * CELL
    if k % 3 ~= 0 then
      line(BX + p, BY, BX + p, BY + 162, C_GRID)
      line(BX, BY + p, BX + 162, BY + p, C_GRID)
    else
      rectfill(BX + p - 1, BY, 2, 162, C_THICK)
      rectfill(BX, BY + p - 1, 162, 2, C_THICK)
    end
  end
  -- 外框 2px
  rectfill(BX - 2, BY - 2, 166, 2, C_THICK)
  rectfill(BX - 2, BY + 162, 166, 2, C_THICK)
  rectfill(BX - 2, BY, 2, 162, C_THICK)
  rectfill(BX + 162, BY, 2, 162, C_THICK)
  -- 数字与铅笔候选
  pal(7, C_PENCIL)                             -- 小字白色统一映射为铅笔灰
  for r = 0, 8 do
    for c = 0, 8 do
      local i = idx(r, c)
      local v = puz[i]
      local px, py = BX + c * CELL, BY + r * CELL
      if v > 0 then
        local is_cur = cursor_on and r == cy and c == cx
        local col
        if is_cur then col = C_INK
        elseif conf[i] then col = C_CONFL
        elseif giv[i] ~= 0 then col = C_GIVEN
        elseif own[i] == 2 then col = C_HINTC
        else col = C_PLAYER end
        if giv[i] ~= 0 then                    -- 给定：双描白字（粗体感）
          print(v, px + 5, py + 1, col)
          print(v, px + 6, py + 1, col)
        else
          print(v, px + 5, py + 1, col)
        end
      elseif next(penc[i]) then
        for d = 1, 9 do
          if penc[i][d] then
            local sr, sc = flr((d - 1) / 3), (d - 1) % 3
            sspr(d * 4, 16, 3, 5, px + sc * 6 + 2, py + sr * 6)
          end
        end
      end
    end
  end
  pal()
  -- 光标描边（数字条聚焦时转暗，表示棋盘暂不可编辑）
  if state ~= "win" then
    local px, py = BX + cx * CELL, BY + cy * CELL
    local oc
    if focus == 1 then oc = C_GRID
    elseif flr(t / 8) % 2 == 0 then oc = C_GOLD
    else oc = C_AMBER end
    rect(px - 2, py - 2, 22, 22, oc)
    rect(px - 1, py - 1, 20, 20, oc)
  end
end

local function draw_bar()
  local cnts = {}
  for i = 1, 81 do
    local v = puz[i]
    if v > 0 then cnts[v] = (cnts[v] or 0) + 1 end
  end
  for d = 1, 9 do
    local kx = 4 + (d - 1) * (KEY_W + 4)
    local sel = focus == 1 and bar_sel == d
    local full = (cnts[d] or 0) >= 9
    rrectfill(kx, BAR_Y, KEY_W, KEY_H, 3, sel and C_CURSOR or C_CELL_D)
    rrect(kx, BAR_Y, KEY_W, KEY_H, 3,
      sel and (flr(t / 8) % 2 == 0 and C_GOLD or C_AMBER) or C_GRID)
    print(d, kx + 8, BAR_Y + 2, sel and C_INK or (full and C_DIM or C_TXT))
    pal(7, sel and C_INK or (full and C_DIM or C_TXT))
    sspr((9 - (cnts[d] or 0)) * 4, 16, 3, 5, kx + 11, BAR_Y + 20)
    pal()
  end
end

local function draw_gen()
  draw_dots_bg()
  rrectfill(64, 92, 128, 76, 6, C_HUD)
  rrect(64, 92, 128, 76, 6, C_GRID)
  rectfill(66, 94, 124, 1, 30)
  ctext("出题中" .. string.rep(".", flr(t / 20) % 4), 104, C_GOLD)
  ctext(gen_phase == 0 and "构建终盘" or "挖洞 ・ 唯一解验证", 126, C_TXT)
  rrectfill(76, 148, 104, 12, 3, C_CELL_D)     -- 进度条
  rrect(76, 148, 104, 12, 3, C_GRID)
  rectfill(78, 150, flr(100 * gen_prog), 8, 30)
  if flr(t / 20) % 2 == 0 then ctext(btnicon("menu") .. " 返回", 180, C_DIM) end
end

-- Splash：纯主视觉封面（0-90 幀）——单个 3×3 宫大特写 + 手写感大数字 + 光标格，
-- 零菜单零提示零统计（封面帧 --cover 30 落在本段）
local function draw_splash()
  draw_dots_bg()
  -- 背景极暗漂浮数字（纯装饰，定位固定）
  local deco = { { "5", 16, 96 }, { "2", 232, 100 }, { "7", 22, 212 },
    { "6", 230, 214 }, { "9", 64, 240 }, { "3", 192, 242 }, { "8", 126, 86 } }
  for i = 1, #deco do
    local d = deco[i]
    print(d[1], d[2], d[3] + flr(sin(t * 0.01 + i) * 4), 12)
  end
  -- 大 logo：数独（scale 4，暗影 + 逐字金/青）
  local chars, cols = { "数", "独" }, { C_GOLD, C_PLAYER }
  local cw = tw("数") * 4
  local xs = { 128 - cw - 10, 128 + 10 }
  for i = 1, 2 do
    print(chars[i], xs[i] + 4, 26, 1, 4)
    print(chars[i], xs[i], 22, cols[i], 4)
  end
  ctext("SUDOKU ・ FC-16", 80, C_DIM)
  -- 主视觉：单个 3×3 宫大特写（格 40px，中置）
  local cs, bx, by = 40, 68, 106
  for r = 0, 2 do
    for c = 0, 2 do
      rectfill(bx + c * cs, by + r * cs, cs, cs,
        (r + c) % 2 == 0 and C_CELL_L or C_CELL_D)
    end
  end
  rectfill(bx + cs, by + cs, cs, cs, C_CURSOR)   -- 中央光标格
  -- 大数字（scale 3，双描手写感 + 逐格微倾；{列,行,数字,色,倾x,倾y}）
  local cells = {
    { 0, 0, 5, C_GIVEN, 0, 0 }, { 2, 0, 3, C_PLAYER, 1, 0 },
    { 0, 1, 7, C_GIVEN, 1, 1 }, { 2, 1, 4, C_HINTC, 0, 1 },
    { 0, 2, 1, C_PLAYER, 0, 0 }, { 2, 2, 9, C_GIVEN, 1, 1 },
  }
  for _, e in ipairs(cells) do
    local x, y = bx + e[1] * cs + 11 + e[5], by + e[2] * cs + 7 + e[6]
    print(e[3], x + 1, y + 1, C_PAGE, 3)
    print(e[3], x, y, e[4], 3)
  end
  local x, y = bx + cs + 11, by + cs + 7         -- 光标格墨色大数字
  print(8, x + 1, y + 1, C_PAGE, 3)
  print(8, x, y, C_INK, 3)
  -- 网格线：内部细线、外框粗线
  for k = 1, 2 do
    local p = k * cs
    line(bx + p, by, bx + p, by + 3 * cs, C_GRID)
    line(bx, by + p, bx + 3 * cs, by + p, C_GRID)
  end
  rectfill(bx - 2, by - 2, 3 * cs + 4, 2, C_THICK)
  rectfill(bx - 2, by + 3 * cs, 3 * cs + 4, 2, C_THICK)
  rectfill(bx - 2, by, 2, 3 * cs, C_THICK)
  rectfill(bx + 3 * cs, by, 2, 3 * cs, C_THICK)
  -- 光标双描边（金/琥珀交替，封面帧稳定）
  local oc = flr(t / 8) % 2 == 0 and C_GOLD or C_AMBER
  rect(bx + cs - 3, by + cs - 3, cs + 6, cs + 6, oc)
  rect(bx + cs - 2, by + cs - 2, cs + 4, cs + 4, oc)
end

local function draw_title()
  draw_dots_bg()
  -- 背景漂浮数字（极暗装饰）
  local deco = { { "7", 10, 66 }, { "3", 240, 66 }, { "5", 6, 150 }, { "9", 246, 150 },
    { "1", 56, 226 }, { "4", 204, 226 }, { "8", 132, 228 } }
  for i = 1, #deco do
    local d = deco[i]
    print(d[1], d[2], d[3] + flr(sin(t * 0.008 + i * 0.9) * 5), 12)
  end
  -- 主视觉：3×3 宫格 + 填入数字（经典基底解采样，天然合法；frame 0 即完整）
  local gx0, gy0, cs = 156, 92, 10
  for r = 0, 8 do
    for c = 0, 8 do
      rectfill(gx0 + c * cs, gy0 + r * cs, cs, cs,
        (r + c) % 2 == 0 and C_CELL_L or C_CELL_D)
    end
  end
  for k = 1, 8 do
    local p = k * cs
    if k % 3 ~= 0 then
      line(gx0 + p, gy0, gx0 + p, gy0 + 9 * cs, C_GRID)
      line(gx0, gy0 + p, gx0 + 9 * cs, gy0 + p, C_GRID)
    else
      rectfill(gx0 + p - 1, gy0, 2, 9 * cs, C_THICK)
      rectfill(gx0, gy0 + p - 1, 9 * cs, 2, C_THICK)
    end
  end
  rectfill(gx0 - 2, gy0 - 2, 9 * cs + 4, 2, C_THICK)
  rectfill(gx0 - 2, gy0 + 9 * cs, 9 * cs + 4, 2, C_THICK)
  rectfill(gx0 - 2, gy0, 2, 9 * cs, C_THICK)
  rectfill(gx0 + 9 * cs, gy0, 2, 9 * cs, C_THICK)
  for r = 0, 8 do
    for c = 0, 8 do
      local px, py = gx0 + c * cs, gy0 + r * cs
      local cur = r == 4 and c == 4
      if cur then rectfill(px, py, cs, cs, C_CURSOR) end -- 光标格示意
      if cur or (r * 7 + c * 5 + 3) % 5 < 2 then
        local d = (r * 3 + flr(r / 3) + c) % 9 + 1
        local col = cur and C_INK
          or ((r * 11 + c * 7) % 13 == 0 and C_PLAYER or C_GIVEN)
        print(d, px + 3, py + 2, col)
      end
    end
  end
  -- 标题：双字格片 + 阴影错位 + 浮动
  local chars, cols = { "数", "独" }, { C_GOLD, C_PLAYER }
  for i = 1, 2 do
    local x = 84 + (i - 1) * 52
    local y = 16 + flr(sin(t * 0.04 + i * 0.5) * 2)
    rrectfill(x, y, 36, 36, 6, C_CELL_D)
    rrect(x, y, 36, 36, 6, C_GRID)
    print(chars[i], x + 11, y + 12, C_PAGE)
    print(chars[i], x + 10, y + 10, cols[i])
  end
  ctext("SUDOKU ・ FC-16", 60, C_DIM)
  -- 难度菜单（左列，含最佳用时）
  rrectfill(16, 76, 128, 112, 6, C_HUD)
  rrect(16, 76, 128, 112, 6, C_GRID)
  rectfill(18, 78, 124, 1, 30)
  ctext("选择难度", 84, C_TXT)
  for i = 1, 3 do
    local y = 108 + (i - 1) * 28
    local sel = title_sel == i
    if sel then
      rrect(22, y - 5, 116, 26, 4, flr(t / 8) % 2 == 0 and C_GOLD or C_AMBER)
      print("▶", 26, y, C_GOLD)
    end
    print(DIFF[i].name, 44, y, DIFF[i].col)
    local bt = flr(dget(i - 1))
    local bs = bt == 0 and "--:--" or mmss(bt)
    print(bs, 134 - tw(bs), y, sel and 7 or C_DIM)
  end
  -- 提示（稳定不闪烁）
  local hint = btnicon("dpad") .. " 选难度　" .. btnicon("a") .. " 出题开局　"
    .. btnicon("view") .. " 音乐"
  ctext(hint, 210, 7)
  print("♪", 240, 4, music_on and 30 or 10)
  ctext("FrostMiKu ・ FC-16", 236, 10)
end

local function draw_pause()
  fillp(0x5a5a)                                -- 暗色抖动纱罩
  rectfill(0, 0, 256, 256, C_PAGE * 256 + 0)
  fillp()
  rrectfill(64, 66, 128, 124, 6, C_HUD)
  rrect(64, 66, 128, 124, 6, C_GRID)
  rectfill(66, 68, 124, 1, 30)
  print("暂停", (256 - tw("暂停")) / 2 + 1, 79, C_PAGE)
  ctext("暂停", 78, C_GOLD)
  local items = { "继续", "重开本题", "换一题", "返回难度选择" }
  for i = 1, 4 do
    local y = 104 + (i - 1) * 22
    local sel = pause_sel == i
    if sel and flr(t / 10) % 2 == 0 then print("▶", 78, y, C_GOLD) end
    print(items[i], 94, y, sel and 7 or C_DIM)
  end
end

local function draw_win()
  -- 胜利金波：按 (行+列) 对角时序扫过全盘
  if win_t < 130 then
    fillp(0x8888)
    for r = 0, 8 do
      for c = 0, 8 do
        local d0 = (r + c) * 2
        if win_t > d0 and win_t < d0 + 26 then
          rectfill(BX + c * CELL, BY + r * CELL, CELL, CELL, C_GOLD * 256 + C_CELL_D)
        end
      end
    end
    fillp()
  end
  if win_t <= 60 then return end
  fillp(0x5a5a)
  rectfill(0, 0, 256, 256, C_PAGE * 256 + 0)
  fillp()
  rrectfill(44, 56, 168, 152, 8, C_HUD)
  rrect(44, 56, 168, 152, 8, C_GRID)
  rectfill(46, 58, 164, 1, 30)
  print("完成！", (256 - tw("完成！")) / 2 + 1, 71, C_PAGE)
  ctext("完成！", 70, C_GOLD)
  local s = "难度 " .. DIFF[diff].name
  local x0 = (256 - tw(s)) / 2
  print(s, x0, 96, C_TXT)
  print(DIFF[diff].name, x0 + tw("难度 "), 96, DIFF[diff].col)
  ctext("用时 " .. mmss(flr(play_frames / 60)), 116, 7)
  ctext("提示 " .. (HINTS_MAX - hints_left) .. " ・ 填错 " .. mistakes, 136, C_TXT)
  if win_new_best then
    if flr(t / 6) % 2 == 0 then ctext("★ 新纪录 ★", 156, C_GOLD) end
  elseif win_best_hints then
    if flr(t / 6) % 2 == 0 then ctext("☆ 提示新纪录 ☆", 156, C_HINTC) end
  end
  if flr(t / 16) % 2 == 0 then ctext(btnicon("a") .. " 再来一局", 174, 7) end
  ctext(btnicon("menu") .. " 回标题", 190, C_DIM)
end

function _draw()
  pal()
  camera(0, 0)
  if state == "splash" then
    draw_splash()
    return
  end
  if state == "title" then
    draw_title()
  elseif state == "gen" then
    draw_gen()
  else
    cls(C_PAGE)
    draw_hud()
    draw_board()
    draw_bar()
    draw_status()
    draw_tips()
    if state == "pause" then draw_pause() end
    if state == "win" then draw_win() end
  end
end

-- ---------------------------------------------------------------- 生命周期

function _init()
  build_maps()
  bake_tiny()
  init_audio()
  music_on = dget(6) == 0                      -- 槽位 6：0 = 开（默认）
  if music_on then set_bgm(true) end
  state, diff, title_sel = "splash", 1, 1
end
