-- 黑白棋 ・ FC-16 演示卡带
-- 标准 8×8 黑白棋（Reversi/Othello）：玩家执黑先行，AI 执白，三档难度。
--   入门＝贪心翻最多（带本局种子的随机扰动）；进阶＝位置权重贪心（角最大 /
--       角旁负 / 边正，附送角惩罚与行动力压制）；困难＝α-β 剪枝 minimax
--       （深度 4，评估＝位置权重＋行动力＋潜在翻转前线子，终盘空格 至多9 改为
--       精确求解至终局），搜索按节点预算切片到多幀执行（coroutine 分幀），
--       排序与走子全确定性，扰动只走本局 srand 的 rnd。
-- 演出：落子弹跳缩放入场；翻转按距落子点距离错峰（横向椭圆压缩再展开模拟
--       翻面＋中途变色），翻转音效逐枚变调；AI 落子金环提示；非法落子红闪
--       抖动；无手可下自动跳过横幅；终局黑白对比条 + 胜负大字 + 各难度战绩。
-- 操作：←→↑↓ 移动光标（可按住连移，光标旁显示 C4 式坐标）　Ⓐ 落子　
--       Ⓧ 悔棋（成对撤回玩家+AI 两手，不限次）　Menu 暂停菜单
--       （继续/认输/重开/回标题）　View 音乐开关
-- 音频：落子/翻转/非法/跳过/终局 SFX + 原创安静棋类 BGM（D 小调 4 小节循环），
--       全部由 _init 程序化写入（SPEC §4.2/§5.2），棋盘与棋子亦程序化烘焙。
-- 存档：dset(0..8) 各难度 胜/负/和 战绩，dset(9) 音乐开关，fflush 落盘（§13）。

-- ---------------------------------------------------------------- 常量

local CELL = 24                     -- 格边长（像素）
local BX, BY = 8, 36                -- 棋盘 (0,0) 格左上角屏幕坐标
local TOP_H, BOT_Y = 28, 240        -- 顶栏高 / 底栏 y
local PANEL_X, PANEL_W = 206, 46    -- 右侧信息板
local FLIP_DUR = 8                  -- 单枚翻转动画幀数
local DROP_DUR = 14                 -- 落子入场动画幀数

-- 色号直取 SPEC §2.2（禁止色号算术推导明暗）
local C_BG, C_PANEL, C_EDGE = 13, 14, 11
local C_TXT, C_MID, C_DIM = 8, 10, 5
local C_GOLD, C_GOLD_L = 30, 31

local DNAME = {"入门", "进阶", "困难"}
local DCOL = {33, 29, 58}
local TDESC = {"贪心：翻最多", "权重：占要点", "深算：四层搜索"}

-- 位置权重表：角最大、角旁（X/C 位）为负、边正（进阶/困难共用）
local WT = {
  {120, -20, 20, 5, 5, 20, -20, 120},
  {-20, -40, -5, -5, -5, -5, -40, -20},
  {20, -5, 15, 3, 3, 15, -5, 20},
  {5, -5, 3, 3, 3, 3, -5, 5},
  {5, -5, 3, 3, 3, 3, -5, 5},
  {20, -5, 15, 3, 3, 15, -5, 20},
  {-20, -40, -5, -5, -5, -5, -40, -20},
  {120, -20, 20, 5, 5, 20, -20, 120},
}
local CORNER = {[1] = true, [8] = true, [57] = true, [64] = true}

local HINTS = {
  btnicon("a") .. " 落子　" .. btnicon("x") .. " 悔棋　" .. btnicon("menu") .. " 菜单",
  btnicon("view") .. " 音乐开关",
  "落子须至少夹翻一枚对方棋子",
  "占住四角！角落的棋子不会被翻转",
}

local function fmt(n) return string.format("%d", n) end

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

-- 写一条 SFX：steps[i] = {音高, 音色, 音量[, 效果]}，nil 步为休止
-- 音高为旧固件值（1-96 = C0-B7），写卡带前换算为新 0-95 并用音量 0 表休止
local function write_sfx(id, speed, steps, len)
  local base = 0x0C0000 + id * 144
  poke2(base, (speed == 0 and 1 or speed) * 4) -- 旧每步帧数(60Hz) → 新 SPD tick(240Hz)
  u8(base + 2, len or #steps)
  for i = 0, 31 do
    local a, s = base + 16 + i * 4, steps[i + 1]
    if s and (s[1] or 0) > 0 then
      u8(a, s[1] - 1) u8(a + 1, WMAP[s[2] or 0]) u8(a + 2, s[3] or 0) u8(a + 3, s[4] or 0)
    else u8(a, 0) u8(a + 1, 0) u8(a + 2, 0) u8(a + 3, 0) end
  end
end

-- 安静棋类 BGM：D 小调 4 小节循环，ch4 旋律（ROUND）/ ch5 贝斯（BASS），
-- speed 8，每小节 256 幀，全曲约 17 秒；MUSIC 行 0-3，mask 0x30
local MEL = {
  {51, 0, 54, 56, 58, 0, 56, 54},  -- D4 F4 G4 A4 G4 F4
  {56, 0, 58, 0, 61, 0, 58, 56},   -- G4 A4 C5 A4 G4
  {54, 0, 51, 0, 53, 54, 53, 51},  -- F4 D4 E4 F4 E4 D4
  {53, 0, 51, 0, 51, 0, 0, 0},     -- E4 D4（收束回环）
}
local BASS_ROOT = {27, 30, 25, 27} -- D2 F2 C2 D2

local MUSIC_BASE = 0x0C5380 -- MUSIC 区（SPEC §5.2）：+0 LEN，行 r 在 +32+r*32

local function init_audio()
  init_waveforms()
  write_sfx(0, 1, {{70, 3, 3}})                            -- 光标轻移
  write_sfx(1, 2, {{43, 8, 12}, {36, 8, 8}})               -- 落子（圆润低叩）
  write_sfx(2, 2, {{24, 14, 9}, {24, 14, 7}})              -- 非法：噪声 buzz
  write_sfx(3, 3, {{53, 8, 8}, {49, 8, 7}, {45, 8, 6}})    -- 跳过提示
  write_sfx(4, 1, {{64, 3, 5}})                            -- 菜单移动
  write_sfx(5, 2, {{60, 3, 8}, {67, 3, 9}})                -- 确认
  write_sfx(6, 2, {{52, 3, 8}, {47, 3, 7}})                -- 悔棋下行
  write_sfx(7, 2, {{58, 8, 10}, {62, 8, 10}, {65, 8, 10}, {70, 8, 11}, nil,
    {70, 8, 11}, {74, 8, 12}, {77, 8, 13}})                -- 胜利琶音
  write_sfx(8, 3, {{58, 8, 9}, {54, 8, 8}, {51, 8, 7}, {46, 8, 6}}) -- 失败下行
  write_sfx(9, 3, {{57, 8, 8}, {60, 8, 8}, {57, 8, 7}})    -- 和棋
  for k = 0, 11 do -- 翻转音效 12 档：逐枚轻微升调
    write_sfx(20 + k, 1, {{55 + k * 2, 3, 4}, {59 + k * 2, 3, 3}})
  end
  local function expand(notes, k, wave, vol) -- 0（休止）展开为 {0,0,0} 步
    local out = {}
    for _, v in ipairs(notes) do
      local st = (v == 0) and {0, 0, 0} or {v, wave, vol}
      for _ = 1, k do out[#out + 1] = st end
    end
    return out
  end
  u8(MUSIC_BASE, 4) -- 全表 LEN = 4 行
  for bar = 0, 3 do
    write_sfx(40 + bar, 8, expand(MEL[bar + 1], 4, 8, 7), 32)
    write_sfx(50 + bar, 8, expand({BASS_ROOT[bar + 1]}, 32, 11, 6), 32)
    local mb = MUSIC_BASE + 32 + bar * 32
    for c = 0, 7 do u8(mb + c, 0xFF) end -- 空轨写 0xFF（0 是合法 SFX 号）
    u8(mb + 4, 40 + bar)  -- ch4 旋律
    u8(mb + 5, 50 + bar)  -- ch5 贝斯
    if bar == 0 then u8(mb + 16, 1) end -- LOOP_START：循环起点
    if bar == 3 then u8(mb + 17, 1) end -- LOOP_BACK：回到 LOOP_START
  end
end

-- ---------------------------------------------------------------- 精灵烘焙

-- 精灵表像素写入：表坐标 (u,v) → 瓦片 (v/16)*16+u/16，瓦片内偏移 (u%16, v%16)
local function spset(u, v, c)
  poke((flr(v / 16) * 16 + flr(u / 16)) * 256 + (v % 16) * 16 + u % 16, c)
end

-- 16×16 圆片：径向明暗 + 左上高光（黑）/ 右下体面（白）+ 右下落影（画在毛毡上）
local function bake_disc(id, white)
  local u0, v0 = (id % 16) * 16, flr(id / 16) * 16
  for y = 0, 15 do
    for x = 0, 15 do
      local dx, dy = x + 0.5 - 8, y + 0.5 - 8
      local d = sqrt(dx * dx + dy * dy)
      local c = 0
      if d <= 6.6 then
        if white then
          if d > 5.6 then c = 5            -- 边缘灰圈
          elseif dx + dy > 5.2 then c = 6  -- 右下体面阴影
          else c = 7 end                   -- 亮面
        else
          if d > 5.4 then c = 3            -- 边缘受光圈
          else
            local hx, hy = x - 5.2, y - 5.0
            local h2 = hx * hx + hy * hy
            if h2 < 2.2 then c = 6         -- 高光核
            elseif h2 < 6 then c = 4       -- 高光晕
            else c = 1 end                 -- 石身
          end
        end
      elseif d <= 7.6 and dx + dy > 2 then
        c = 37                             -- 右下半圈落影
      end
      spset(u0 + x, v0 + y, c)
    end
  end
end

-- 198×198 棋盘烘焙到表区 (0,256)：3px 木框（受光/背光棱）+ 34/35 绿毛毡
-- 24px 相间格 + 稀疏噪点 + 四角星位标记
local function bake_board()
  local S = 198
  for y = 0, S - 1 do
    for x = 0, S - 1 do
      local c
      if x == 0 or y == 0 then c = 21
      elseif x == S - 1 or y == S - 1 then c = 17
      else c = 19 end
      spset(x, 256 + y, c)
    end
  end
  for gy = 0, 7 do
    for gx = 0, 7 do
      local base = ((gx + gy) % 2 == 0) and 34 or 35
      local noise = ((gx + gy) % 2 == 0) and 35 or 36
      for py = 0, 23 do
        for px = 0, 23 do
          local x, y = 3 + gx * 24 + px, 3 + gy * 24 + py
          spset(x, 256 + y, (x * 73 + y * 151) % 211 < 2 and noise or base)
        end
      end
    end
  end
  -- 四角星位（格 (2,2)/(2,6)/(6,2)/(6,6) 交界）
  for _, pt in ipairs({{51, 51}, {147, 51}, {51, 147}, {147, 147}}) do
    for dy = -1, 1 do
      for dx = -1, 1 do
        spset(pt[1] + dx, 256 + pt[2] + dy, 37)
      end
    end
  end
end

-- ---------------------------------------------------------------- 棋盘几何预计算

-- 格索引 i = y*8+x+1（1..64）；0 空 / 1 黑（玩家）/ 2 白（AI）
local W8 = {}   -- 位置权重（扁平）
local RX = {}   -- RX[i] = 8 条射线（格索引数组，自 i 向外）
local NB = {}   -- NB[i] = 相邻格
local DIR8 = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}
for y = 0, 7 do
  for x = 0, 7 do
    local i = y * 8 + x + 1
    W8[i] = WT[y + 1][x + 1]
    local rays, nb = {}, {}
    for d = 1, 8 do
      local r = {}
      local xx, yy = x + DIR8[d][1], y + DIR8[d][2]
      while xx >= 0 and xx < 8 and yy >= 0 and yy < 8 do
        r[#r + 1] = yy * 8 + xx + 1
        xx, yy = xx + DIR8[d][1], yy + DIR8[d][2]
      end
      rays[#rays + 1] = r
      if abs(xx - x) <= 1 and abs(yy - y) <= 1 then nb[#nb + 1] = yy * 8 + xx + 1 end
    end
    RX[i], NB[i] = rays, nb
  end
end

-- ---------------------------------------------------------------- 状态

local t = 0                  -- 全局幀计数
local gt = 0                 -- 对局计时幀（暂停/菜单不计时）
local state = "splash"       -- splash / title / play / over
local diff = 1               -- 难度 1 入门 / 2 进阶 / 3 困难
local phase = "input"        -- input | anim | think | pass（play 中）
local turn = 1               -- 当前方 1 黑 / 2 白
local B = {}                 -- 棋盘
local bc, wc = 2, 2          -- 黑白子数
local hist = {}              -- {bd=棋盘快照, turn=行棋方}（行棋前）
local cx, cy = 3, 2          -- 光标（格坐标，初始停在合法手 D3）
local rep = {0, 0, 0, 0}     -- 方向键按住计时
local pm, pm_set = {}, {}    -- 玩家合法手列表 / 集合
local fx = nil               -- 演出：{drop, flips, active}
local mark = nil             -- AI 落子金环 {i, t}
local shake, bad_t, bad_i = 0, 0, 0
local pass_side, pass_t = 0, 0
local menu_open, menu_i = false, 1
local over_t, result = 0, 0
local rec = {}               -- 战绩 rec[(diff-1)*3 + {1胜,2负,3和}]
local music_on = false

-- ---------------------------------------------------------------- 规则

local function tally()
  local b, w = 0, 0
  for i = 1, 64 do
    local v = B[i]
    if v == 1 then b = b + 1 elseif v == 2 then w = w + 1 end
  end
  bc, wc = b, w
end

-- 若 c 在空格 i 落子合法，返回被翻格列表；否则 nil
local function flips_for(i, c)
  local opp = 3 - c
  local out = {}
  local rays = RX[i]
  for d = 1, 8 do
    local r, got = rays[d], {}
    for k = 1, #r do
      local v = B[r[k]]
      if v == opp then
        got[#got + 1] = r[k]
      else
        if v == c and #got > 0 then
          for j = 1, #got do out[#out + 1] = got[j] end
        end
        break
      end
    end
  end
  if #out == 0 then return nil end
  return out
end

local function legal_list(c)
  local out = {}
  for i = 1, 64 do
    if B[i] == 0 and flips_for(i, c) then out[#out + 1] = i end
  end
  return out
end

local function coord(i)
  return string.char(65 + (i - 1) % 8) .. fmt(flr((i - 1) / 8) + 1)
end

-- 落子（已校验合法）：写快照入历史 → 改盘 → 演出与音效
local function apply_move(i, c, fl)
  local cp = {}
  for k = 1, 64 do cp[k] = B[k] end
  hist[#hist + 1] = {bd = cp, turn = c}
  B[i] = c
  for k = 1, #fl do B[fl[k]] = c end
  tally()
  fx = {drop = {i = i, c = c, t = 0}, flips = {}, active = {}}
  local px, py = (i - 1) % 8, flr((i - 1) / 8)
  for k = 1, #fl do
    local qx, qy = (fl[k] - 1) % 8, flr((fl[k] - 1) / 8)
    local dist = max(abs(qx - px), abs(qy - py))
    fx.flips[k] = {i = fl[k], delay = dist * 6, t = 0, ord = k}
    fx.active[fl[k]] = true
  end
  sfx(1, 0)
end

-- ---------------------------------------------------------------- AI（搜索板 + 分幀切片）

-- 搜索用独立棋盘（思考期间 _draw 仍读 B），并维护增量评估状态：
--   SW  位置权重带符号和（黑正）    SF1/SF2  双方前线子数（潜力翻转面）
--   SE  空格数                      SEC[i]   格 i 的空邻居数（前线判定）
local SB, SEC = {}, {}
local SW, SF1, SF2, SE = 0, 0, 0, 64
local MOV, MVS, MVC, ORD, FB = {}, {}, {}, {}, {}
for d = 0, 13 do
  MOV[d], MVS[d], MVC[d], ORD[d], FB[d] = {}, {}, {}, {}, {}
end
local ticks, TICK_BUDGET = 0, 200  -- 每幀搜索切片预算（节点/候选段数）

local function tick()
  ticks = ticks + 1
  if ticks >= TICK_BUDGET then
    ticks = 0
    coroutine.yield()
  end
end

local function s_load() -- 从对局棋盘载入并初始化增量状态
  SW, SF1, SF2, SE = 0, 0, 0, 64
  for i = 1, 64 do
    local v = B[i]
    SB[i] = v
    local nb, e = NB[i], 0
    for k = 1, #nb do
      if B[nb[k]] == 0 then e = e + 1 end
    end
    SEC[i] = e
    if v ~= 0 then
      SE = SE - 1
      SW = SW + (v == 1 and 1 or -1) * W8[i]
      if e > 0 then
        if v == 1 then SF1 = SF1 + 1 else SF2 = SF2 + 1 end
      end
    end
  end
end

-- 生成 c 方合法手到第 ply 层缓冲：MOV/MVS/MVC + 翻转格 FB（可中断续跑）
local function gen(d, c)
  local opp = 3 - c
  local mv, ms, mc, fb = MOV[d], MVS[d], MVC[d], FB[d]
  local n, ftop = 0, 0
  for i = 1, 64 do
    if SB[i] == 0 then
      local near = false
      local nb = NB[i]
      for k = 1, #nb do
        if SB[nb[k]] ~= 0 then near = true break end
      end
      if near then
        local fs, legal, rays = ftop, false, RX[i]
        for dd = 1, 8 do
          local r, got, rtop = rays[dd], 0, ftop
          for k = 1, #r do
            local v = SB[r[k]]
            if v == opp then
              got = got + 1
              ftop = ftop + 1
              fb[ftop] = r[k]
            else
              if v == c and got > 0 then legal = true else ftop = rtop end
              break
            end
          end
        end
        if legal then
          n = n + 1
          mv[n] = i
          ms[n] = fs + 1
          mc[n] = ftop - fs
        end
      end
    end
    if i % 8 == 0 then tick() end
  end
  return n
end

-- 落子/回退：O(手数+8)，同步维护 SW/SF1/SF2/SE/SEC（评估增量化）
local function s_apply(d, j, c)
  local i = MOV[d][j]
  SB[i] = c
  SE = SE - 1
  local sg = (c == 1) and 1 or -1
  SW = SW + sg * W8[i]
  local nb, e = NB[i], 0
  for k = 1, #nb do
    if SB[nb[k]] == 0 then e = e + 1 end
  end
  SEC[i] = e
  if e > 0 then
    if c == 1 then SF1 = SF1 + 1 else SF2 = SF2 + 1 end
  end
  for k = 1, #nb do
    local q = nb[k]
    if SEC[q] > 0 then
      SEC[q] = SEC[q] - 1
      if SEC[q] == 0 then
        local v = SB[q]
        if v == 1 then SF1 = SF1 - 1 elseif v == 2 then SF2 = SF2 - 1 end
      end
    end
  end
  local fb, s0, m = FB[d], MVS[d][j], MVC[d][j]
  for k = s0, s0 + m - 1 do
    local q = fb[k]
    local o = SB[q]
    SB[q] = c
    SW = SW + 2 * sg * W8[q]
    if SEC[q] > 0 then
      if o == 1 then SF1 = SF1 - 1 else SF2 = SF2 - 1 end
      if c == 1 then SF1 = SF1 + 1 else SF2 = SF2 + 1 end
    end
  end
end

local function s_unmake(d, j, c)
  local i = MOV[d][j]
  local sg = (c == 1) and 1 or -1
  local fb, s0, m = FB[d], MVS[d][j], MVC[d][j]
  for k = s0 + m - 1, s0, -1 do
    local q = fb[k]
    local o = 3 - c
    SW = SW - 2 * sg * W8[q]
    if SEC[q] > 0 then
      if c == 1 then SF1 = SF1 - 1 else SF2 = SF2 - 1 end
      if o == 1 then SF1 = SF1 + 1 else SF2 = SF2 + 1 end
    end
    SB[q] = o
  end
  SW = SW - sg * W8[i]
  SE = SE + 1
  if SEC[i] > 0 then
    if c == 1 then SF1 = SF1 - 1 else SF2 = SF2 - 1 end
  end
  SB[i] = 0
  local nb = NB[i]
  for k = 1, #nb do
    local q = nb[k]
    if SEC[q] == 0 then
      local v = SB[q]
      if v == 1 then SF1 = SF1 + 1 elseif v == 2 then SF2 = SF2 + 1 end
    end
    SEC[q] = SEC[q] + 1
  end
end

-- 手序固定：按位置权重降序、同权按格序升序（插入排序，总序所以完全确定）
local function sort_moves(d, n)
  local ord, mv = ORD[d], MOV[d]
  for j = 1, n do ord[j] = j end
  for j = 2, n do
    local v, kv = ord[j], W8[MOV[d][ord[j]]]
    local jj = j - 1
    while jj >= 1 do
      local u = ord[jj]
      local ku = W8[mv[u]]
      if ku < kv or (ku == kv and mv[u] > mv[v]) then
        ord[jj + 1] = u
        jj = jj - 1
      else
        break
      end
    end
    ord[jj + 1] = v
  end
end

-- α-β 负极大：评估＝位置权重＋行动力（己方实际手数，对方以前线子代理）
-- ＋潜在翻转（双方前线子差）；终局（双方无手/盘满）以精确子差计分
local function ab(d, depth, alpha, beta, c, passed)
  tick()
  local n = gen(d, c)
  if n == 0 then
    if passed or SE == 0 then
      local diff2 = 0
      for i = 1, 64 do
        local v = SB[i]
        if v == c then diff2 = diff2 + 1 elseif v ~= 0 then diff2 = diff2 - 1 end
      end
      return diff2 * 100
    end
    return -ab(d, depth, -beta, -alpha, 3 - c, true)
  end
  if depth <= 0 then
    local fm, fo
    if c == 1 then fm, fo = SF1, SF2 else fm, fo = SF2, SF1 end
    local w = (c == 1) and SW or -SW
    return w + 9 * n - 6 * fm + 6 * fo
  end
  sort_moves(d, n)
  local best = -1e18
  for j = 1, n do
    local jj = ORD[d][j]
    s_apply(d, jj, c)
    local v = -ab(d + 1, depth - 1, -beta, -alpha, 3 - c, false)
    s_unmake(d, jj, c)
    if v > best then
      best = v
      if best > alpha then alpha = best end
      if alpha >= beta then break end
    end
  end
  return best
end

-- 入门：贪心翻最多 + 本局种子扰动（rnd）
local function ai_easy(n)
  local best, bj = -1e9, 1
  for j = 1, n do
    local sc = MVC[0][j] + rnd(-1.5, 1.5)
    if sc > best then best, bj = sc, j end
  end
  return MOV[0][bj]
end

-- 进阶：位置权重贪心 + 翻转数 + 行动力压制，送角重罚
local function ai_medium(n)
  local best, bj = -1e9, 1
  for j = 1, n do
    local i = MOV[0][j]
    local sc = W8[i] + 2 * MVC[0][j]
    s_apply(0, j, 2)
    local m2 = gen(1, 1)
    for k = 1, m2 do
      if CORNER[MOV[1][k]] then sc = sc - 80 break end
    end
    sc = sc - m2
    s_unmake(0, j, 2)
    if sc > best then best, bj = sc, j end
  end
  return MOV[0][bj]
end

-- 困难：α-β 深度 4；终盘空格 至多9 改为精确求解至终局
local function think_root()
  s_load()
  local n = gen(0, 2)
  if n == 0 then return nil end
  if diff == 1 then return ai_easy(n) end
  if diff == 2 then return ai_medium(n) end
  sort_moves(0, n)
  local depth = (SE <= 9) and (SE + 4) or 4
  local alpha, best, bi = -1e18, -1e18, MOV[0][1]
  for j = 1, n do
    local jj = ORD[0][j]
    s_apply(0, jj, 2)
    local v = -ab(1, depth - 1, -1e18, -alpha, 1, false)
    s_unmake(0, jj, 2)
    if v > best then
      best, bi = v, MOV[0][jj]
    end
    if best > alpha then alpha = best end
    tick()
  end
  return bi
end

-- ---------------------------------------------------------------- 流程

local function begin_input()
  phase = "input"
  pm = legal_list(1)
  pm_set = {}
  for k = 1, #pm do pm_set[pm[k]] = true end
end

local function to_title()
  state, menu_open, fx, mark = "title", false, nil, nil
end

local function finish_game(resign)
  tally()
  local res = resign and 2 or (bc > wc and 1 or (bc < wc and 2 or 0))
  result, state, over_t = res, "over", 0
  menu_open = false
  local idx = (diff - 1) * 3 + (res == 1 and 1 or (res == 2 and 2 or 3))
  rec[idx] = rec[idx] + 1
  dset(idx - 1, rec[idx])
  fflush()
  sfx(res == 1 and 7 or (res == 2 and 8 or 9), 2)
end

local function new_game()
  srand(frame() + 7919) -- 本局种子：入门扰动走这里
  for i = 1, 64 do B[i] = 0 end
  B[28] = 2 B[37] = 2  -- d4/e5 白
  B[36] = 1 B[29] = 1  -- e4/d5 黑
  turn, hist, fx, mark = 1, {}, nil, nil
  bc, wc = 2, 2
  shake, bad_t, gt, over_t = 0, 0, 0, 0
  pass_side, pass_t = 0, 0
  cx, cy = 3, 2
  menu_open = false
  state = "play"
  begin_input()
end

local function toggle_music()
  music_on = not music_on
  dset(9, music_on and 0 or 1)
  fflush()
  if music_on then music(0, 400, 0x30) else music(-1, 400) end
end

-- 一手演出结束后的回合推进：无手自动跳过，双方无手/盘满即终局
local start_think -- 前置声明（end_move 的 AI 回合与跳过推进都会调用）
local function end_move()
  turn = 3 - turn
  if #legal_list(turn) > 0 then
    if turn == 1 then begin_input() else start_think() end
    return
  end
  local skipped = turn
  turn = 3 - turn
  if #legal_list(turn) > 0 then
    pass_side, pass_t, phase = skipped, 0, "pass"
    sfx(3, 2)
  else
    finish_game(false)
  end
end

local think = {co = nil, best = nil, fallback = nil, t = 0, min_t = 0}

function start_think()
  phase = "think"
  think.t = 0
  think.min_t = (diff == 3) and 24 or 36 -- 最短思考演出幀数
  think.best = nil
  think.fallback = nil
  for i = 1, 64 do
    if B[i] == 0 and flips_for(i, 2) then
      think.fallback = i
      break
    end
  end
  think.co = coroutine.create(think_root)
end

local function ai_apply(i)
  local fl = flips_for(i, 2)
  if not fl and think.fallback then
    i = think.fallback
    fl = flips_for(i, 2)
  end
  if fl then
    apply_move(i, 2, fl)
    mark = {i = i, t = 0}
    phase = "anim"
  else
    end_move() -- 理论不可达（思考前已确认白方有手）：保守推进
  end
end

local function update_think()
  think.t = think.t + 1
  if think.co then
    ticks = 0 -- 每幀一个切片：预算内跑，超预算 yield 到下一幀
    local ok, res = coroutine.resume(think.co)
    if not ok then
      printh("reversi: AI 错误 " .. tostring(res))
      think.co = nil
      think.best = think.fallback
    elseif coroutine.status(think.co) == "dead" then
      think.co = nil
      think.best = (type(res) == "number") and res or think.fallback
    end
  end
  if think.best and think.t >= think.min_t then
    ai_apply(think.best)
  end
end

-- 悔棋：弹历史直到撤回到玩家行棋前（即成对撤回玩家+AI 两手）
local function undo_try()
  if #hist == 0 then
    sfx(2, 1)
    return
  end
  while #hist > 0 do
    local h = table.remove(hist)
    for k = 1, 64 do B[k] = h.bd[k] end
    turn = h.turn
    if h.turn == 1 then break end
  end
  fx, mark, pass_t = nil, nil, 0
  tally()
  sfx(6, 1)
  begin_input()
end

local function update_anim()
  local busy = false
  if fx.drop then
    fx.drop.t = fx.drop.t + 1
    if fx.drop.t >= DROP_DUR then fx.drop = nil else busy = true end
  end
  for k = #fx.flips, 1, -1 do
    local f = fx.flips[k]
    f.t = f.t + 1
    if f.t == f.delay + 1 then sfx(20 + (f.ord - 1) % 12) end
    if f.t >= f.delay + FLIP_DUR then
      fx.active[f.i] = nil
      table.remove(fx.flips, k)
    else
      busy = true
    end
  end
  if not busy then end_move() end
end

-- ---------------------------------------------------------------- 输入与更新

local function cursor_input()
  for d = 0, 3 do
    if dir(d) then
      rep[d + 1] = rep[d + 1] + 1
      if rep[d + 1] == 1 or (rep[d + 1] > 14 and (rep[d + 1] - 15) % 4 == 0) then
        if d == 0 then cx = max(0, cx - 1)
        elseif d == 1 then cx = min(7, cx + 1)
        elseif d == 2 then cy = max(0, cy - 1)
        else cy = min(7, cy + 1) end
        sfx(0, 1)
      end
    else
      rep[d + 1] = 0
    end
  end
end

local function update_menu()
  if dirp(2) then
    menu_i = (menu_i + 2) % 4 + 1
    sfx(4, 1)
  elseif dirp(3) then
    menu_i = menu_i % 4 + 1
    sfx(4, 1)
  elseif btnp(11) or btnp(5) then
    menu_open = false
    sfx(4, 1)
  elseif btnp(4) then
    if menu_i == 1 then
      menu_open = false
      sfx(5, 1)
    elseif menu_i == 2 then
      finish_game(true) -- 认输
    elseif menu_i == 3 then
      sfx(5, 1)
      new_game()
    else
      sfx(5, 1)
      to_title()
    end
  end
end

local function update_play()
  if btnp(10) then toggle_music() end
  if menu_open then
    update_menu()
    return
  end
  if state == "over" then
    over_t = over_t + 1
    if mark then mark.t = mark.t + 1 end
    if over_t > 30 then
      if btnp(4) then
        sfx(5, 1)
        new_game()
      elseif btnp(11) then
        sfx(5, 1)
        to_title()
      end
    end
    return
  end
  if btnp(11) then
    menu_open, menu_i = true, 1
    sfx(4, 1)
    return
  end
  gt = gt + 1
  if mark then mark.t = mark.t + 1 end
  if shake > 0 then shake = shake - 1 end
  if bad_t > 0 then bad_t = bad_t - 1 end
  if phase == "input" then
    cursor_input()
    if btnp(4) then
      local i = cy * 8 + cx + 1
      if pm_set[i] then
        apply_move(i, 1, flips_for(i, 1))
        phase = "anim"
      else
        shake, bad_t, bad_i = 12, 12, i
        sfx(2, 1)
      end
    elseif btnp(6) then
      undo_try()
    end
  elseif phase == "anim" then
    update_anim()
  elseif phase == "think" then
    update_think()
  elseif phase == "pass" then
    pass_t = pass_t + 1
    if pass_t >= 80 then
      if turn == 1 then begin_input() else start_think() end
    end
  end
end

local function update_title()
  if dirp(0) then
    diff = (diff + 1) % 3 + 1
    sfx(4, 1)
  elseif dirp(1) then
    diff = diff % 3 + 1
    sfx(4, 1)
  end
  if btnp(10) then toggle_music() end
  if btnp(4) or btnp(11) then
    sfx(5, 1)
    new_game()
  end
end

function _update()
  t = t + 1
  if state == "splash" then
    -- 开机封面：90 帧后（或 Ⓐ / Menu）进交互菜单
    if t > 90 or btnp(4) or btnp(11) then state = "title" end
  elseif state == "title" then
    update_title()
  else
    update_play()
  end
end

-- ---------------------------------------------------------------- 绘制

local function cell_xy(i)
  return BX + (i - 1) % 8 * CELL, BY + flr((i - 1) / 8) * CELL
end

local function ctext(s, y, c)
  print(s, flr((256 - tw(s)) / 2), y, c)
end

local function disc_cols(c)
  if c == 1 then return 1, 3 end
  return 7, 5
end

local function draw_board()
  rectfill(8, 37, 198, 198, 15) -- 右下投影
  sspr(0, 256, 198, 198, 5, 33)
end

local function draw_dots()
  fillp(0xAAAA)
  for k = 1, #pm do
    local px, py = cell_xy(pm[k])
    circfill(px + 12, py + 12, 4.5, C_GOLD_L * 256 + 35)
  end
  fillp()
  for k = 1, #pm do
    local px, py = cell_xy(pm[k])
    circ(px + 12, py + 12, 5.5, 37)
  end
end

local function draw_discs()
  -- 静态子（跳过入场/翻转中的格子）
  for i = 1, 64 do
    local v = B[i]
    if v ~= 0 and not (fx and ((fx.drop and fx.drop.i == i) or fx.active[i])) then
      local px, py = cell_xy(i)
      sspr(v == 1 and 16 or 32, 0, 16, 16, px + 2, py + 2, 20, 20)
    end
  end
  if not fx then return end
  if fx.drop then -- 落子弹跳缩放入场
    local d = fx.drop
    local px, py = cell_xy(d.i)
    local u = d.t / DROP_DUR
    local k = u < 0.7 and (0.3 + 0.9 * (u / 0.7)) or (1.2 - 0.2 * ((u - 0.7) / 0.3))
    local w = flr(20 * k)
    sspr(d.c == 1 and 16 or 32, 0, 16, 16,
      px + 12 - flr(w / 2), py + 12 - flr(w / 2), w, w)
  end
  for k = 1, #fx.flips do -- 翻转：横向椭圆压缩再展开，中途变色
    local f = fx.flips[k]
    local px, py = cell_xy(f.i)
    if f.t <= f.delay then
      local oc = 3 - B[f.i]
      sspr(oc == 1 and 16 or 32, 0, 16, 16, px + 2, py + 2, 20, 20)
    else
      local cxp, cyp = px + 12, py + 12
      local p = (f.t - f.delay) / FLIP_DUR
      if p >= 1 then
        sspr(B[f.i] == 1 and 16 or 32, 0, 16, 16, px + 2, py + 2, 20, 20)
      else
        local face = (p < 0.5) and (3 - B[f.i]) or B[f.i]
        local main, rim = disc_cols(face)
        local kk = abs(1 - 2 * p)
        local rx = max(kk * 10, 0.9)
        ovalfill(cxp, cyp, rx, 10, main)
        oval(cxp, cyp, rx, 10, rim)
        if kk < 0.35 then rectfill(cxp - 1, cyp - 9, 2, 18, 15) end -- 侧面厚度
      end
    end
  end
end

local function draw_marks()
  if mark and mark.t < 60 then -- AI 落子金环
    local px, py = cell_xy(mark.i)
    circ(px + 12, py + 12, 12 + sin(mark.t * 0.25) * 1.5,
      flr(t / 5) % 2 == 0 and C_GOLD or 29)
  end
  if bad_t > 0 and bad_t % 4 < 2 then -- 非法格红闪
    local px, py = cell_xy(bad_i)
    rrect(px - 1, py - 1, CELL + 2, CELL + 2, 3, 59)
  end
end

local function draw_cursor()
  local px, py = BX + cx * CELL, BY + cy * CELL
  local ox = 0
  if shake > 0 then ox = flr(sin(shake * 1.1) * shake / 3) end
  local c = flr(t / 6) % 2 == 0 and C_GOLD or C_GOLD_L
  rrect(px - 3 + ox, py - 3, CELL + 6, CELL + 6, 5, 15)
  rrect(px - 2 + ox, py - 2, CELL + 4, CELL + 4, 4, c)
  local s = string.char(65 + cx) .. fmt(cy + 1)
  local lx, ly = px + 1, (cy == 0) and py + CELL + 2 or py - 18
  print(s, lx + 1, ly + 1, 15)
  print(s, lx, ly, C_GOLD_L)
end

local function draw_top()
  rectfill(0, 0, 256, TOP_H, C_BG)
  line(0, TOP_H, 255, TOP_H, C_EDGE)
  print("黑白棋 ・ " .. DNAME[diff], 6, 6, C_MID)
  local msg, mc
  if state == "over" then
    msg, mc = "对局终了", C_TXT
  elseif phase == "pass" then
    msg, mc = (pass_side == 1 and "黑" or "白") .. "无子可下", C_GOLD_L
  elseif phase == "think" then
    msg = "思考中" .. string.rep(".", 1 + flr(t / 14) % 3)
    mc = C_GOLD
  elseif phase == "input" then
    msg, mc = "你的回合", C_GOLD_L
  else
    msg, mc = "对局中", C_MID
  end
  ctext(msg, 6, mc)
  print("♪", 243, 6, music_on and C_GOLD or C_EDGE)
end

local function draw_panel()
  rrectfill(PANEL_X, 33, PANEL_W, 198, 3, C_PANEL)
  rrect(PANEL_X, 33, PANEL_W, 198, 3, C_EDGE)
  -- 黑白双方子数 + 行动指示灯 + 比例条
  circfill(216, 47, 5, 1)
  circ(216, 47, 5, 3)
  print(fmt(bc), 250 - #fmt(bc) * 8, 39, C_TXT)
  circfill(216, 87, 5, 7)
  circ(216, 87, 5, 5)
  print(fmt(wc), 250 - #fmt(wc) * 8, 79, C_TXT)
  local tot = bc + wc
  if tot > 0 then
    local bpart = flr(36 * bc / tot + 0.5)
    rectfill(210, 63, 36, 6, 2)
    if bpart > 0 then rectfill(210, 63, bpart, 6, 1) end
    if 36 - bpart > 0 then rectfill(210 + bpart, 63, 36 - bpart, 6, 7) end
    rect(210, 63, 36, 6, C_EDGE)
  end
  if state == "play" then
    local ly = (turn == 1) and 47 or 87
    circ(216, ly, 8 + sin(t * 0.15) * 1.2, C_GOLD)
  end
  line(210, 108, 248, 108, C_EDGE)
  print("难度", 212, 114, C_MID)
  print(DNAME[diff], 212, 132, DCOL[diff])
  print("用时", 212, 152, C_MID)
  local sec = flr(gt / 60)
  print(string.format("%d:%02d", flr(sec / 60), sec % 60), 212, 170, C_TXT)
  print("手数", 212, 192, C_MID)
  print(fmt(#hist), 212, 210, C_TXT)
end

local function draw_bottom()
  rectfill(0, BOT_Y, 256, 16, C_BG)
  line(0, BOT_Y, 255, BOT_Y, C_EDGE)
  local s = HINTS[flr(t / 180) % #HINTS + 1]
  ctext(s, BOT_Y, C_MID)
end

local function draw_pass()
  local a = min(1, pass_t / 10)
  local w = flr(150 * a)
  if w < 8 then return end
  local x0 = flr(128 - w / 2)
  rrectfill(x0, 100, w, 52, 6, C_PANEL)
  if a >= 1 then
    rrect(x0, 100, w, 52, 6, C_GOLD)
    local s = (pass_side == 1 and "黑" or "白") .. "无子可下"
    ctext(s, 112, C_TXT)
    ctext("自动跳过", 132, C_MID)
  end
end

local function draw_menu()
  fillp(0xa5a5)
  rectfill(0, 0, 256, 256, 15 * 256 + 0)
  fillp()
  rrectfill(86, 78, 84, 122, 6, C_PANEL)
  rrect(86, 78, 84, 122, 6, C_EDGE)
  ctext("暂停", 88, C_TXT)
  local items = {"继续", "认输", "重开", "回标题"}
  for i = 1, 4 do
    local y = 112 + (i - 1) * 22
    if menu_i == i then print("▶", 94, y, C_GOLD) end
    print(items[i], 116, y, menu_i == i and C_TXT or C_MID)
  end
end

local function draw_over()
  fillp(0x8421)
  rectfill(0, 0, 256, 256, 13 * 256 + 0)
  fillp()
  local u = min(1, over_t / 12)
  local by, bh = flr(128 - 76 * u), flr(152 * u)
  rrectfill(44, by, 168, bh, 6, C_PANEL)
  rrect(44, by, 168, bh, 6, C_EDGE)
  if u < 1 then return end
  local s = result == 1 and "你赢了！" or (result == 2 and "你输了" or "平局")
  local sc = result == 1 and C_GOLD_L or (result == 2 and C_TXT or 7)
  print(s, flr((256 - tw(s)) / 2) + 1, 64, 15)
  ctext(s, 62, sc)
  -- 黑白子数对比条
  circfill(66, 104, 6, 1)
  circ(66, 104, 6, 3)
  print(fmt(bc), 78, 96, C_TXT)
  circfill(190, 104, 6, 7)
  circ(190, 104, 6, 5)
  local ws = fmt(wc)
  print(ws, 180 - #ws * 8, 96, C_TXT)
  local tot = bc + wc
  if tot > 0 then
    local bp = flr(56 * bc / tot + 0.5)
    rectfill(100, 100, 56, 8, 2)
    if bp > 0 then rectfill(100, 100, bp, 8, 1) end
    if 56 - bp > 0 then rectfill(100 + bp, 100, 56 - bp, 8, 7) end
    rect(100, 100, 56, 8, C_EDGE)
  end
  -- 各难度战绩（本难度行高亮，获胜闪星）
  for d = 1, 3 do
    local y = 128 + (d - 1) * 20
    local base = (d - 1) * 3
    local star = "　"
    if d == diff and result == 1 and flr(t / 8) % 2 == 0 then star = "★" end
    print(star .. DNAME[d] .. " 胜" .. fmt(rec[base + 1])
      .. " 负" .. fmt(rec[base + 2]) .. " 和" .. fmt(rec[base + 3]),
      54, y, d == diff and C_GOLD or C_MID)
  end
  if flr(t / 16) % 2 == 0 then
    ctext(btnicon("a") .. " 再来一局　" .. btnicon("menu") .. " 回标题", 186, C_TXT)
  end
end

-- Splash：纯主视觉封面（0-90 帧）——黑白棋子 3×3 反转序列微距特写，零菜单零提示
local function draw_splash()
  cls(C_BG)
  fillp(0x0421)
  rectfill(0, 0, 256, 256, 12 * 256 + C_BG)
  fillp()
  -- 暗棋盘格暗示
  for i = 0, 11 do
    local p = 8 + i * 22
    line(p, 0, p, 256, C_PANEL)
    line(0, p, 256, p, C_PANEL)
  end
  -- 大 logo（scale 3，投影 + 逐字配色）
  local chars, cols = { "黑", "白", "棋" }, { 7, C_GOLD_L, C_GOLD }
  for i = 1, 3 do
    local x = 70 + (i - 1) * 44
    print(chars[i], x + 4, 30, 15, 3)
    print(chars[i], x, 26, cols[i], 3)
  end
  -- 英雄画面：3×3 巨子对峙（左列黑 / 右列白，中列 = 反转序列：黑→翻转中→白）
  local D, GP = 52, 10
  local x0, y0 = 40, 62
  for r = 0, 2 do
    for c = 0, 2 do
      local cx = x0 + c * (D + GP) + D / 2
      local cy = y0 + r * (D + GP) + D / 2 + sin(t * 0.03 + r * 1.3 + c * 0.7) * 2
      ovalfill(cx - D / 2, cy + D / 2 - 4, D, 8, 15)  -- 落影
      local black = c == 0 or (c == 1 and r == 0)
      local flip = c == 1 and r == 1
      if flip then
        -- 翻转中：左黑右白各半 + 金环 + 运动弧线
        circfill(cx, cy, D / 2 - 2, 7)
        clip(cx - D / 2 + 2, cy - D / 2 + 2, D / 2 - 2, D - 4)
        sspr(16, 0, 16, 16, cx - D / 2 + 2, cy - D / 2 + 2, D - 4, D - 4)
        clip()
        circ(cx, cy, D / 2 - 1, C_GOLD)
        local a0 = t * 0.05
        for k = 0, 9 do
          local a1 = a0 + k * 0.09
          local a2 = a1 + 0.055
          line(cx + cos(a1) * (D / 2 + 5), cy + sin(a1) * (D / 2 + 5),
            cx + cos(a2) * (D / 2 + 5), cy + sin(a2) * (D / 2 + 5), C_GOLD_L)
          local b1 = a1 + 3.1416
          line(cx + cos(b1) * (D / 2 + 5), cy + sin(b1) * (D / 2 + 5),
            cx + cos(b1 + 0.055) * (D / 2 + 5), cy + sin(b1 + 0.055) * (D / 2 + 5), C_GOLD_L)
        end
      else
        sspr(black and 16 or 32, 0, 16, 16, cx - D / 2 + 2, cy - D / 2 + 2, D - 4, D - 4)
      end
    end
  end
end

local function draw_title()
  cls(C_BG)
  fillp(0x0421)
  rectfill(0, 0, 256, 256, 12 * 256 + C_BG)
  fillp()
  -- 主视觉：压暗棋盘 + 黑白对峙局面（黑潮左 / 白阵右，波锋交错；frame 0 即完整）
  local bx, by, bs = 62, 70, 132
  pal(34, 36, 1)
  pal(35, 37, 1)
  pal(19, 18, 1)
  pal(21, 19, 1)
  pal(17, 16, 1)
  rectfill(bx + 3, by + 5, bs, bs, 15)
  sspr(0, 256, 198, 198, bx, by, bs, bs)
  local k = bs / 198
  for r = 0, 7 do
    local f = flr(3.5 + sin(r * 0.9 + 0.6) * 1.9 + 0.5) -- 波锋：黑方推进前沿
    for c = 0, 7 do
      if (r * 5 + c * 3 + 1) % 7 < 5 then  -- 稀疏镂空，避免死板满铺
        local dx = flr(bx + (15 + c * 24) * k) - 6
        local dy = flr(by + (15 + r * 24) * k) - 6
        sspr(c <= f and 16 or 32, 0, 16, 16, dx, dy, 13, 13)
      end
    end
  end
  pal()
  -- 标题（阴影字 + 浮动）
  local chars, cols = {"黑", "白", "棋"}, {7, C_GOLD_L, C_GOLD}
  for i = 1, 3 do
    local x, y = 104 + (i - 1) * 16, 8 + flr(sin(t * 0.05 + i * 0.4) * 2)
    print(chars[i], x + 2, y + 2, 15)
    print(chars[i], x, y, cols[i])
  end
  ctext("REVERSI ・ FC-16", 30, C_MID)
  -- 难度拨盘（◀ ▶ 即左右键）
  rrectfill(43, 44, 170, 24, 5, C_PANEL)
  rrect(43, 44, 170, 24, 5, C_EDGE)
  local ns = "◀ " .. DNAME[diff] .. " ▶"
  local x0 = flr((256 - tw(ns) - 8 - tw(TDESC[diff])) / 2)
  print(ns, x0, 50, C_GOLD_L)
  print(TDESC[diff], x0 + tw(ns) + 8, 50, C_MID)
  -- 开始提示（稳定不闪烁，压在棋盘下缘）
  rrectfill(66, 174, 124, 24, 5, 0)
  rrect(66, 174, 124, 24, 5, C_GOLD)
  local ps = "按 " .. btnicon("a") .. " 开始"
  print(ps, flr((256 - tw(ps)) / 2), 180, C_GOLD_L)
  -- 本难度战绩（一行小字）
  local base = (diff - 1) * 3
  local ss = DNAME[diff] .. "　胜" .. fmt(rec[base + 1])
    .. " 负" .. fmt(rec[base + 2]) .. " 和" .. fmt(rec[base + 3])
  ctext(ss, 210, C_MID)
  ctext(btnicon("left") .. btnicon("right") .. " 选难度", 226, C_DIM)
  ctext("FrostMiKu ・ FC-16", 242, C_EDGE)
  print("♪", 240, 4, music_on and C_GOLD or C_EDGE)
end

function _draw()
  pal()
  fillp()
  camera(0, 0)
  if state == "splash" then
    draw_splash()
    return
  end
  if state == "title" then
    draw_title()
    return
  end
  cls(C_BG)
  draw_top()
  draw_board()
  draw_marks()
  if state == "play" and phase == "input" then draw_dots() end
  draw_discs()
  if state == "play" and phase == "input" then draw_cursor() end
  draw_panel()
  draw_bottom()
  if state == "play" and phase == "pass" then draw_pass() end
  if menu_open then draw_menu() end
  if state == "over" then draw_over() end
end

-- ---------------------------------------------------------------- 生命周期

function _init()
  bake_board()
  bake_disc(1, false) -- 瓦片 1 黑子
  bake_disc(2, true)  -- 瓦片 2 白子
  init_audio()
  for i = 1, 9 do rec[i] = flr(dget(i - 1)) end
  music_on = dget(9) == 0 -- 槽位 9：0 = 开（默认）
  if music_on then music(0, 400, 0x30) end
  t, gt = 0, 0
  state, diff = "splash", 1
  phase, turn = "input", 1
  menu_open, menu_i = false, 1
  cx, cy = 3, 2
  hist, pm, pm_set = {}, {}, {}
  shake, bad_t, bad_i = 0, 0, 0
  pass_side, pass_t = 0, 0
  over_t, result = 0, 0
end
