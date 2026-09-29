-- FC-16 推箱子（Sokoban）演示卡带
-- 经典仓库整理谜题：把全部箱子推到目标点上。只能推、不能拉；
-- 箱子推墙或推箱无效；全部归位过关。
--
-- 关卡：Thinking Rabbit 原版关卡集（1988 流传文本）与 David W. Skinner
-- Microban 关卡集中的公开经典关卡，按难度排序；全部经离线求解器验证
-- 可解，最少推动参考值亦由求解器计算（见 README）。
--
-- 操作：方向移动（按住连续）；B 悔棋（无限栈）；X 重开本关；
--       Menu 选关；View 音乐开关；标题画面 A 开始（按键提示均为 btnicon 图标）。
-- 演出：推动滑动缓动、归位闪光与音效、过关庆祝、全通关终章、百叶窗转场。
-- 死锁提示：箱子被推进死角时提示"卡住了 B 悔棋"。
-- 存档：最佳推动数与通关标记（dset + fflush，save-id：sokoban）。

-- ================================================================ 常量

local HUD_H = 16        -- 顶栏高
local FOOT_Y = 238      -- 底栏顶
local CS_BIG = 16       -- 小关卡格子像素
local CS_SML = 12       -- 大关卡格子像素
local ANIM_N = 5        -- 一步滑动幀数
local REPEAT = 8        -- 按住连续移动节拍（幀）
local UNDO_CAP = 1024   -- 悔棋栈上限

-- 方向：1 上 2 下 3 左 4 右；DIR_IN[d] 为对应输入键 id（0← 1→ 2↑ 3↓）
local DX = {0, 0, -1, 1}
local DY = {-1, 1, 0, 0}
local DIR_IN = {2, 3, 0, 1}

-- 调色板色号（SPEC §2.2 ENDESGA-64 顺序，不做色号算术）
local C_BG = 13      -- 场外深靛 #1A1932
local C_FLOOR = 11   -- 地板 #424C6E
local C_FLOOR_D = 12 -- 地板暗纹 #2A2F4E
local C_WALL = 17    -- 砖墙主体 #5D2C28
local C_WALL_D = 16  -- 砖缝 #391F21
local C_WALL_H = 18  -- 砖亮沿 #8A4836
local C_GOAL = 30    -- 目标金 #FFC825
local C_GOAL_D = 23  -- 目标暗金 #EDAB50
local C_BOX = 19     -- 箱体 #BF6F4A
local C_BOX_D = 17   -- 箱暗边 #5D2C28
local C_BOX_H = 20   -- 箱亮沿 #E69C69
local C_BOX_G = 23   -- 归位箱体 #EDAB50
local C_BOX_G_D = 25 -- 归位箱暗边 #C64524
local C_HAT = 42     -- 工人安全帽青 #00CDF9
local C_SKIN = 22    -- 工人肤色 #F9E6CF
local C_CLOTH = 40   -- 工作服蓝 #0069AA
local C_INK = 16     -- 深色线条 #391F21
local C_TXT = 7      -- 白字 #FFFFFF
local C_TXT_D = 10   -- 暗字 #657392
local C_RED = 59     -- 警示红 #EA323C

-- 精灵瓦片号：0..10 为 16px 组，16..26 为 12px 组
-- 组内：+0 地板 +1 墙 +2 目标 +3 箱 +4 归位箱 +5..6 下行两幀
--       +7..8 上行两幀 +9..10 左行两幀（右行 = 左行水平翻转）
local T16 = 0
local T12 = 16
local LOGO_T = 32 -- 标题字位图（3 瓦特 48×16，sspr 放大）

-- 音效编号
local S_STEP, S_PUSH, S_GOAL, S_BUMP = 0, 1, 2, 3
local S_UNDO, S_MENU, S_OK, S_CLEAR = 4, 5, 6, 7
local S_FINALE, S_DEAD, S_START = 8, 9, 10
-- BGM 声部 SFX：旋律 20..27、贝斯 30..37、和声 40..47（各 8 小节）

-- ================================================================ 关卡数据
-- 每关：par = 求解器验证的最少推动数；src = 来源；rows 为 XSB 文本
-- （# 墙 $ 箱 * 箱在目标上 . 目标 @ 工人 + 工人在目标上）

local LEVELS = {
  {
    par = 3, src = "Microban #2",
    rows = {
      "######",
      "#    #",
      "# #@ #",
      "# $* #",
      "# .* #",
      "#    #",
      "######",
    },
  },
  {
    par = 5, src = "Microban #21",
    rows = {
      "####",
      "#  ####",
      "# . . #",
      "# $$#@#",
      "##    #",
      " ######",
    },
  },
  {
    par = 7, src = "Microban #4",
    rows = {
      "########",
      "#      #",
      "# .**$@#",
      "#      #",
      "#####  #",
      "    ####",
    },
  },
  {
    par = 8, src = "Microban #1",
    rows = {
      "####",
      "# .#",
      "#  ###",
      "#*@  #",
      "#  $ #",
      "#  ###",
      "####",
    },
  },
  {
    par = 9, src = "Microban #17",
    rows = {
      "#####",
      "# @ #",
      "#...#",
      "#$$$##",
      "#    #",
      "#    #",
      "######",
    },
  },
  {
    par = 10, src = "Microban #9",
    rows = {
      "#####",
      "#.  ##",
      "#@$$ #",
      "##   #",
      " ##  #",
      "  ##.#",
      "   ###",
    },
  },
  {
    par = 12, src = "Microban #15",
    rows = {
      "     ###",
      "######@##",
      "#    .* #",
      "#   #   #",
      "#####$# #",
      "    #   #",
      "    #####",
    },
  },
  {
    par = 13, src = "Microban #3",
    rows = {
      "  ####",
      "###  ####",
      "#     $ #",
      "# #  #$ #",
      "# . .#@ #",
      "#########",
    },
  },
  {
    par = 16, src = "Microban #11",
    rows = {
      "  ######",
      "  #    #",
      "  # ##@##",
      "### # $ #",
      "# ..# $ #",
      "#       #",
      "#  ######",
      "####",
    },
  },
  {
    par = 20, src = "Microban #19",
    rows = {
      "########",
      "#   .. #",
      "#  @$$ #",
      "##### ##",
      "   #  #",
      "   #  #",
      "   #  #",
      "   ####",
    },
  },
  {
    par = 21, src = "Microban #10",
    rows = {
      "      #####",
      "      #.  #",
      "      #.# #",
      "#######.# #",
      "# @ $ $ $ #",
      "# # # # ###",
      "#       #",
      "#########",
    },
  },
  {
    par = 29, src = "Microban #6",
    rows = {
      "###### #####",
      "#    ###   #",
      "# $$     #@#",
      "# $ #...   #",
      "#   ########",
      "#####",
    },
  },
  {
    par = 32, src = "Microban #8",
    rows = {
      "  ######",
      "  # ..@#",
      "  # $$ #",
      "  ## ###",
      "   # #",
      "   # #",
      "#### #",
      "#    ##",
      "# #   #",
      "#   # #",
      "###   #",
      "  #####",
    },
  },
  {
    par = 39, src = "Microban #16",
    rows = {
      " ####",
      " #  ####",
      " #     ##",
      "## ##   #",
      "#. .# @$##",
      "#   # $$ #",
      "#  .#    #",
      "##########",
    },
  },
  {
    par = 65, src = "Microban #143",
    rows = {
      "####",
      "#  ####",
      "# $   #",
      "# .#  #",
      "# $# ##",
      "# .  #",
      "#### #",
      "   # #",
      " ### ###",
      " #  $  #",
      "## #$# ##",
      "# $ @ $ #",
      "# ..#.. #",
      "###   ###",
      "  #####",
    },
  },
  {
    par = 97, src = "原版 #1",
    rows = {
      "    #####",
      "    #   #",
      "    #$  #",
      "  ###  $##",
      "  #  $ $ #",
      "### # ## #   ######",
      "#   # ## #####  ..#",
      "# $  $          ..#",
      "##### ### #@##  ..#",
      "    #     #########",
      "    #######",
    },
  },
}

-- ================================================================ 精灵生成

-- 逐像素写瓦片：把 16×16 主坐标的画法 fn(x, y) 采样到 s×s 尺寸，
-- 写入瓦片 id 的左上角（不足 16 的部分保持透明 0）
local function bake(id, s, fn)
  local base = id * 256
  for y = 0, s - 1 do
    for x = 0, s - 1 do
      local mx, my = x * 16 / s + 0.5, y * 16 / s + 0.5 -- 主坐标像素中心
      poke(base + y * 16 + x, fn(mx, my) or 0)
    end
  end
end

-- 工人画法：dir 1 下 / 2 上 / 3 左；幀 f 0/1（腿脚交替、身体起伏）
local function worker_art(dir, f)
  local bob = (f == 1) and 1 or 0
  return function(x, y)
    y = y - bob
    -- 安全帽
    local hx, hy = x - 8, y - 4.5
    if hx * hx / 20 + hy * hy / 7 <= 1 then
      if hy < -1.2 then return C_HAT end
      return C_CLOTH
    end
    -- 脸
    hx, hy = x - 8, y - 4
    if hx * hx + hy * hy / 1.6 <= 10 then
      if dir == 2 then return C_CLOTH end -- 背面无脸
      local ex = (dir == 3) and -2 or (dir == 4) and 2 or 0
      if abs(x - (8 + ex * 0.6)) < 1.1 and abs(y - 4.4) < 1.4 then
        return C_INK
      end
      return C_SKIN
    end
    -- 身体工装
    if x >= 4.6 and x <= 11.4 and y >= 8 and y <= 12.4 then
      if x <= 5.4 or x >= 10.8 then return C_INK end
      if x > 6.5 and x < 9.5 and y < 9.6 then return C_SKIN end
      return C_CLOTH
    end
    -- 腿脚（幀交替：行走两幀迈不同侧的腿）
    if y > 12.4 and y <= 15 then
      if dir == 3 then
        if (f == 0 and x > 8.6 and x < 11.4) or (f == 1 and x > 4.6 and x < 7.4) then
          return C_INK
        end
      elseif dir == 4 then
        if (f == 0 and x > 4.6 and x < 7.4) or (f == 1 and x > 8.6 and x < 11.4) then
          return C_INK
        end
      else
        if (f == 0 and ((x > 5 and x < 7) or (x > 9.6 and x < 11.4)))
          or (f == 1 and ((x > 6.4 and x < 8) or (x > 8.2 and x < 9.8))) then
          return C_INK
        end
      end
    end
    return nil
  end
end

-- 一次烘焙一组尺寸的全部瓦片
local function bake_all(base, s)
  -- 地板：柔和格纹，边缘收暗
  bake(base + 0, s, function(x, y)
    if x < 1 or y < 1 or x > 15 or y > 15 then return C_FLOOR_D end
    if (x < 2.5 and y < 2.5) or (x > 13.5 and y > 13.5) then return C_FLOOR_D end
    return C_FLOOR
  end)
  -- 墙：砖块三排错缝 + 顶部受光沿
  bake(base + 1, s, function(x, y)
    if y < 1.5 then return C_WALL_H end
    if y > 14.5 then return C_WALL_D end
    local row = flr((y - 1.5) / 4.5)
    local off = (row % 2 == 0) and 0 or 4
    local bx = (x + off) % 8
    local ry = (y - 1.5) % 4.5
    if bx < 0.8 or ry < 0.7 then return C_WALL_D end
    if ry < 1.4 and bx > 5 then return C_WALL_H end
    return C_WALL
  end)
  -- 目标：地板 + 中心菱形金环
  bake(base + 2, s, function(x, y)
    local d = abs(x - 8) + abs(y - 8)
    if d > 3.4 and d < 5 then return C_GOAL_D end
    if d >= 2 and d <= 3.4 then return C_GOAL end
    if d < 1.2 then return C_GOAL_D end
    if x < 1 or y < 1 or x > 15 or y > 15 then return C_FLOOR_D end
    return C_FLOOR
  end)
  -- 箱子：木箱 + 斜撑交叉 + 顶沿高光
  bake(base + 3, s, function(x, y)
    if x < 1 or y < 1 or x > 15 or y > 15 then return nil end
    if x < 2 or y < 2 or x > 14 or y > 14 then return C_BOX_D end
    if y < 3 then return C_BOX_H end
    if y > 13.5 then return C_BOX_D end
    local diag = abs((x - 8) - (y - 8))
    local diag2 = abs((x - 8) + (y - 8))
    if diag < 1.1 or diag2 < 1.1 then return C_BOX_D end
    if x > 12.5 then return C_BOX_H end
    return C_BOX
  end)
  -- 归位箱：金色箱体 + 星形铆钉
  bake(base + 4, s, function(x, y)
    if x < 1 or y < 1 or x > 15 or y > 15 then return nil end
    if x < 2 or y < 2 or x > 14 or y > 14 then return C_BOX_G_D end
    if y < 3 then return C_GOAL end
    if y > 13.5 then return C_BOX_G_D end
    local diag = abs((x - 8) - (y - 8))
    local diag2 = abs((x - 8) + (y - 8))
    if diag < 1.1 or diag2 < 1.1 then return C_BOX_G_D end
    if (x == 4 or x == 12) and (y == 5 or y == 11) then return C_TXT end
    return C_BOX_G
  end)
  bake(base + 5, s, worker_art(1, 0))
  bake(base + 6, s, worker_art(1, 1))
  bake(base + 7, s, worker_art(2, 0))
  bake(base + 8, s, worker_art(2, 1))
  bake(base + 9, s, worker_art(3, 0))
  bake(base + 10, s, worker_art(3, 1))
end

-- ================================================================ 音频

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

-- init_sfx(id, notes, wave, vol, speed)：notes 为音高表（0 休止，至多32 步）
-- 音高为旧固件值（1-96 = C0-B7），写卡带前换算为新 0-95 并用音量 0 表休止
local function init_sfx(id, notes, wave, vol, speed)
  local sp = speed or 2
  local base = 0x0C0000 + id * 144
  poke2(base, (sp == 0 and 1 or sp) * 4)  -- 旧每步帧数(60Hz) → 新 SPD tick(240Hz)
  u8(base + 2, #notes)
  for i = 0, 31 do
    local a = base + 16 + i * 4
    local p = notes[i + 1]
    if p and p > 0 then
      u8(a, p - 1)
      u8(a + 1, WMAP[wave])
      u8(a + 2, vol)
      u8(a + 3, 0)
    else
      u8(a, 0)
      u8(a + 1, 0)
      u8(a + 2, 0)
      u8(a + 3, 0)
    end
  end
end

-- 音高：1-96 = C0-B7（MIDI 12-107），下表用 MIDI 折算
local function n(m) return m - 11 end

-- 八小节平静谜题循环（A 小调，Am-F-C-G × 2）；每小节 8 个八分音符
local MEL = {
  {n(69), 0, n(72), 0, n(76), 0, n(72), 0},
  {n(69), n(72), n(74), n(72), n(69), 0, n(64), 0},
  {n(67), 0, n(72), 0, n(76), 0, n(79), 0},
  {n(76), n(74), n(72), n(74), n(71), 0, n(67), 0},
  {n(69), 0, n(72), 0, n(76), 0, n(81), 0},
  {n(79), n(76), n(74), n(76), n(72), 0, n(69), 0},
  {n(67), 0, n(71), 0, n(74), 0, n(79), 0},
  {n(76), 0, n(74), 0, n(72), 0, 0, 0},
}
local BASS_ROOT = {45, 41, 48, 43, 45, 41, 48, 43} -- A2 F2 C3 G2
local ARP = { -- 和声双音（低/高），八分交替
  {n(57), n(60)}, -- Am：A3 C4
  {n(53), n(57)}, -- F：F3 A3
  {n(55), n(60)}, -- C：G3 C4
  {n(55), n(59)}, -- G：G3 B3
}

local function expand(notes, k)
  local out = {}
  for _, v in ipairs(notes) do
    for _ = 1, k do out[#out + 1] = v end
  end
  return out
end

local MUSIC_BASE = 0x0C5380  -- MUSIC 区（SPEC §5.2）：+0 LEN，行 r 在 +32+r*32

local function init_audio()
  init_waveforms()
  init_sfx(S_STEP, {n(57)}, 13, 4, 1) -- 脚步：短促软点
  init_sfx(S_PUSH, {n(45), n(43)}, 11, 9, 2) -- 推箱：低频搓动
  init_sfx(S_GOAL, {n(72), n(76), n(79)}, 6, 8, 2) -- 归位：上行三连
  init_sfx(S_BUMP, {n(38), n(36)}, 11, 10, 1) -- 无效推：钝响
  init_sfx(S_UNDO, {n(64), n(59)}, 3, 7, 2) -- 悔棋：下行双音
  init_sfx(S_MENU, {n(69)}, 3, 6, 1) -- 菜单移动
  init_sfx(S_OK, {n(69), n(76)}, 3, 8, 2) -- 菜单确认
  init_sfx(S_CLEAR, -- 过关旋律：明亮号角
    {n(69), 0, n(69), 0, n(69), 0, n(72), 0,
     n(74), 0, n(74), 0, n(74), 0, n(77), 0,
     n(76), 0, n(74), 0, n(72), 0, n(69), 0,
     n(72), n(72), n(72), n(72), n(72), 0, 0, 0}, 3, 12, 3)
  init_sfx(S_FINALE, -- 全通关终章：号角 + 上行音阶
    {n(65), 0, n(69), 0, n(72), 0, n(77), 0,
     n(76), 0, n(72), 0, n(69), 0, n(76), 0,
     n(72), n(74), n(76), n(77), n(79), n(81), n(84), 0,
     n(84), 0, n(81), 0, n(77), 0, n(84), 0}, 3, 12, 4)
  init_sfx(S_DEAD, {n(56), n(55)}, 2, 8, 3) -- 死锁警示：不协和半音
  init_sfx(S_START, {n(60), n(67)}, 6, 8, 2) -- 开局定音

  -- BGM：每小节一条 32 步 SFX × 三声部；8 个 MUSIC 行顺序回环
  for bar = 1, 8 do
    init_sfx(19 + bar, expand(MEL[bar], 4), 3, 7, 4) -- 旋律 SQUARE
    init_sfx(29 + bar, expand({n(BASS_ROOT[bar])}, 32), 11, 10, 4) -- 贝斯
    local pair = ARP[(bar - 1) % 4 + 1]
    local lo, hi = pair[1], pair[2]
    init_sfx(39 + bar,
      expand({lo, hi, lo, hi, lo, hi, lo, hi}, 4), 6, 4, 4) -- 和声 ORGAN
    -- MUSIC 行（SPEC §5.2：八个 SFX ID，0xFF 为空；LOOP_START/LOOP_BACK 控制回环）
    local mb = MUSIC_BASE + 32 + (bar - 1) * 32
    for c = 0, 7 do u8(mb + c, 0xFF) end
    u8(mb + 5, 19 + bar)
    u8(mb + 6, 29 + bar)
    u8(mb + 7, 39 + bar)
    if bar == 1 then u8(mb + 16, 1) end  -- LOOP_START：循环起点
    if bar == 8 then u8(mb + 17, 1) end  -- LOOP_BACK：回到 LOOP_START
  end
  u8(MUSIC_BASE, 8)  -- 全表 LEN = 8 行
end

-- ================================================================ 关卡装载

-- 解析一关：墙/目标/箱子/工人 + 从工人可达的内部地板格 + 死格表
-- 死格 = 箱子一旦进入就永远无法推到任何目标的格（角落 / 沿墙无目标）
local function parse_level(rows)
  local w, h = 0, #rows
  for _, r in ipairs(rows) do w = max(w, #r) end
  local wall, goal, box = {}, {}, {}
  local px, py
  for y = 1, h do
    local r = rows[y]
    for x = 1, w do
      local c = string.sub(r, x, x)
      local i = (y - 1) * w + x
      if c == "#" then
        wall[i] = true
      elseif c ~= " " and c ~= "" then
        if c == "$" then box[i] = true
        elseif c == "*" then box[i] = true goal[i] = true
        elseif c == "." then goal[i] = true
        elseif c == "@" then px, py = x, y
        elseif c == "+" then px, py = x, y goal[i] = true end
      end
    end
  end
  local P = {w = w, h = h, wall = wall, goal = goal, box = box,
             px = px, py = py}
  -- 可达地板（忽略箱子）：决定绘制范围（挡住关卡外的装饰性空格）
  local reach = {}
  local q = {{px, py}}
  reach[(py - 1) * w + px] = true
  while #q > 0 do
    local e = table.remove(q)
    for d = 1, 4 do
      local nx, ny = e[1] + DX[d], e[2] + DY[d]
      if nx >= 1 and nx <= w and ny >= 1 and ny <= h then
        local i = (ny - 1) * w + nx
        if not wall[i] and not reach[i] then
          reach[i] = true
          q[#q + 1] = {nx, ny}
        end
      end
    end
  end
  P.reach = reach
  -- 死格表：从目标反向"拉"BFS——箱子能从 s 拉到 (x,y) 需要
  -- s、玩家站位 pp 都是可达地板；全部目标自身即活格种子
  local alive = {}
  local q2 = {}
  for i in pairs(goal) do
    alive[i] = true
    q2[#q2 + 1] = i
  end
  while #q2 > 0 do
    local i = table.remove(q2)
    local x, y = (i - 1) % w + 1, flr((i - 1) / w) + 1
    for d = 1, 4 do
      local sx, sy = x + DX[d], y + DY[d]
      local tx, ty = x + 2 * DX[d], y + 2 * DY[d]
      if sx >= 1 and sx <= w and sy >= 1 and sy <= h
        and tx >= 1 and tx <= w and ty >= 1 and ty <= h then
        local s = (sy - 1) * w + sx
        local pp = (ty - 1) * w + tx
        if not wall[s] and not wall[pp] and not alive[s]
          and reach[s] and reach[pp] then
          alive[s] = true
          q2[#q2 + 1] = s
        end
      end
    end
  end
  P.alive = alive
  P.goals_n = 0
  for _ in pairs(goal) do P.goals_n = P.goals_n + 1 end
  return P
end

-- ================================================================ 游戏状态

-- state：title / play / clear / finale（全局，便于端到端观测）
-- cur_level / steps / pushes 为全局观测变量
local t = 0               -- 全局幀
local st = {}             -- 当前关卡运行状态
local sel = 1             -- 选关光标
local best = {}           -- 各关最佳推动（1 起）
local music_on = true
local trans = nil         -- {t, T, mid} 转场
local sparks = {}         -- 粒子
local total_pushes = 0    -- 本次会话累计推动（按过关净计数）
local stuck_t = 0         -- 死锁提示剩余幀

local function start_transition(mid)
  trans = {t = 0, T = 9, mid = mid}
end

local function fmt(n) return string.format("%d", n) end

local function enter_level(idx)
  cur_level = idx
  local P = parse_level(LEVELS[idx].rows)
  st = {
    P = P,
    box = {},
    undo = {},
    steps = 0, pushes = 0,
    anim = nil,   -- {d, fx, fy, tx, ty, p, box={fx,fy,tx,ty,i}}
    flash = nil,  -- {i, t} 归位闪光格
    cd = 0,       -- 连续移动冷却
    dir = 1,
    frame = 0,    -- 行走幀（奇偶交替迈腿）
    ct = 0,       -- 过关演出计时
  }
  for i in pairs(P.box) do st.box[i] = true end
  steps, pushes = 0, 0
  stuck_t = 0
  sparks = {}
  state = "play"
  sfx(S_START, 1)
end

local function try_move(d, fresh)
  local P = st.P
  local nx, ny = P.px + DX[d], P.py + DY[d]
  local ni = (ny - 1) * P.w + nx
  st.dir = d
  if P.wall[ni] then
    if fresh then sfx(S_BUMP, 0) end
    return
  end
  if st.box[ni] then
    local tx, ty = nx + DX[d], ny + DY[d]
    local ti = (ty - 1) * P.w + tx
    if P.wall[ti] or st.box[ti] then
      if fresh then sfx(S_BUMP, 0) end
      return
    end
    -- 有效推箱
    st.box[ni] = nil
    st.box[ti] = true
    st.undo[#st.undo + 1] = {px = P.px, py = P.py, bf = ni, bt = ti}
    st.anim = {d = d, fx = P.px, fy = P.py, tx = nx, ty = ny, p = 0,
               box = {fx = nx, fy = ny, tx = tx, ty = ty, i = ti}}
    P.px, P.py = nx, ny
    st.steps = st.steps + 1
    st.pushes = st.pushes + 1
    st.frame = st.frame + 1
    sfx(S_PUSH, 0)
    if P.goal[ti] then
      st.flash = {i = ti, t = 18}
      sfx(S_GOAL, 1)
    elseif not P.alive[ti] then
      stuck_t = 200
      sfx(S_DEAD, 3)
    end
  else
    -- 纯移动
    st.undo[#st.undo + 1] = {px = P.px, py = P.py}
    st.anim = {d = d, fx = P.px, fy = P.py, tx = nx, ty = ny, p = 0}
    P.px, P.py = nx, ny
    st.steps = st.steps + 1
    st.frame = st.frame + 1
    sfx(S_STEP, 0)
  end
  if #st.undo > UNDO_CAP then table.remove(st.undo, 1) end
  st.cd = REPEAT
end

local function do_undo()
  local e = table.remove(st.undo)
  if not e then
    sfx(S_BUMP, 1)
    return
  end
  local P = st.P
  if e.bf then
    st.box[e.bt] = nil
    st.box[e.bf] = true
    st.pushes = st.pushes - 1
  end
  P.px, P.py = e.px, e.py
  st.steps = st.steps - 1
  st.anim = nil
  st.flash = nil
  stuck_t = 0
  sfx(S_UNDO, 1)
end

local function check_win()
  local P = st.P
  local n = 0
  for i in pairs(st.box) do
    if P.goal[i] then n = n + 1 end
  end
  return n >= P.goals_n
end

local function on_clear()
  state = "clear"
  stuck_t = 0
  st.ct = 0
  -- 存档：最佳推动数（槽 1..N；槽 0 预留进度；槽 20 音乐开关）
  if best[cur_level] == 0 or st.pushes < best[cur_level] then
    best[cur_level] = st.pushes
    dset(cur_level, st.pushes)
  end
  total_pushes = total_pushes + st.pushes
  fflush()
  sfx(S_CLEAR, 2)
  -- 庆祝粒子：从每个归位箱喷发
  sparks = {}
  local P = st.P
  for i in pairs(st.box) do
    local x = (i - 1) % P.w + 1
    local y = flr((i - 1) / P.w) + 1
    for k = 1, 6 do
      sparks[#sparks + 1] = {
        x = x, y = y,
        vx = rnd(-0.9, 0.9), vy = rnd(-2.2, -0.6),
        life = 30 + flr(rnd(24)),
        c = (k % 2 == 0) and C_GOAL or C_TXT,
      }
    end
  end
end

-- ================================================================ 更新

local function update_play()
  if stuck_t > 0 then stuck_t = stuck_t - 1 end
  if st.flash then
    st.flash.t = st.flash.t - 1
    if st.flash.t <= 0 then st.flash = nil end
  end

  -- 滑动缓动推进；结束瞬间判定胜负
  if st.anim then
    st.anim.p = st.anim.p + 1
    if st.anim.p >= ANIM_N then
      st.anim = nil
      if check_win() then on_clear() end
    end
  end

  -- 悔棋 / 重开 / 菜单
  if btnp(5) then do_undo() return end
  if btnp(6) then
    sfx(S_MENU, 1)
    start_transition(function() enter_level(cur_level) end)
    return
  end
  if btnp(11) then
    sfx(S_MENU, 1)
    start_transition(function() state = "title" end)
    return
  end

  -- 方向输入（新按立即走一步；按住时每 REPEAT 幀一步）
  if st.cd > 0 then st.cd = st.cd - 1 end
  local d = 0
  if dir(2) then d = 1 elseif dir(3) then d = 2
  elseif dir(0) then d = 3 elseif dir(1) then d = 4 end
  if d > 0 and not st.anim then
    if btnp(DIR_IN[d]) then
      try_move(d, true)
    elseif st.cd == 0 then
      try_move(d, false)
    end
  end
end

local function update_clear()
  st.ct = st.ct + 1
  for i = #sparks, 1, -1 do
    local s = sparks[i]
    s.x = s.x + s.vx
    s.y = s.y + s.vy
    s.vy = s.vy + 0.14
    s.life = s.life - 1
    if s.life <= 0 then table.remove(sparks, i) end
  end
  local last = cur_level == #LEVELS
  if btnp(4) or st.ct > 170 then
    if last then
      state = "finale"
      st.ft = 0
      sparks = {}
      sfx(S_FINALE, 2)
    else
      local nx = cur_level + 1
      if nx > sel then sel = nx end
      start_transition(function() enter_level(nx) end)
    end
  end
end

local function update_finale()
  st.ft = st.ft + 1
  -- 礼花：顶部撒落彩点
  if t % 3 == 0 then
    sparks[#sparks + 1] = {
      x = rnd(8, 248), y = 30,
      vx = rnd(-0.8, 0.8), vy = rnd(0.4, 1.6),
      life = 60 + flr(rnd(40)),
      c = flr(rnd(4)) == 0 and C_GOAL or (flr(rnd(2)) == 0 and C_HAT or C_TXT),
    }
  end
  for i = #sparks, 1, -1 do
    local s = sparks[i]
    s.x = s.x + s.vx
    s.y = s.y + s.vy
    s.vy = s.vy + 0.02
    s.life = s.life - 1
    if s.life <= 0 then table.remove(sparks, i) end
  end
  if btnp(4) or btnp(11) then
    sfx(S_OK, 1)
    start_transition(function()
      state = "title"
      sparks = {}
    end)
  end
end

local function update_title()
  if dirp(2) and sel > 4 then sel = sel - 4 sfx(S_MENU, 1) end
  if dirp(3) and sel + 4 <= #LEVELS then sel = sel + 4 sfx(S_MENU, 1) end
  if dirp(0) and sel % 4 ~= 1 then sel = sel - 1 sfx(S_MENU, 1) end
  if dirp(1) and sel % 4 ~= 0 then sel = sel + 1 sfx(S_MENU, 1) end
  if btnp(4) or btnp(11) then
    sfx(S_OK, 1)
    start_transition(function() enter_level(sel) end)
  end
end

function _update()
  t = t + 1
  -- 音乐开关（任意状态；槽 20：0 开 1 关）
  if btnp(10) then
    music_on = not music_on
    dset(20, music_on and 0 or 1)
    fflush()
    if music_on then music(0, 334, 0xE0) else music(-1, 167) end
  end
  -- 转场推进（中点执行切换，期间锁输入）
  if trans then
    trans.t = trans.t + 1
    if trans.t == trans.T then
      trans.mid()
    elseif trans.t >= trans.T * 2 then
      trans = nil
    end
    return
  end
  if state == "splash" then
    if t > 90 or btnp(4) or btnp(11) then state = "title" end
  elseif state == "title" then
    update_title()
  elseif state == "play" then
    update_play()
  elseif state == "clear" then
    update_clear()
  elseif state == "finale" then
    update_finale()
  end
end

-- ================================================================ 绘制

-- 画一瓦片：base 为该尺寸组基号，s 为格子像素，(x,y) 为 1 起格坐标
local function tile(base, s, i, ox, oy, x, y)
  local sx = (base + i) % 16 * 16
  local sy = flr((base + i) / 16) * 16
  sspr(sx, sy, s, s, ox + (x - 1) * s, oy + (y - 1) * s)
end

-- 工人朝向 -> 瓦片号与是否水平翻转
local function worker_tile(base, d, f)
  local k = f % 2
  if d == 2 then return base + 5 + k, false end -- 下
  if d == 1 then return base + 7 + k, false end -- 上
  return base + 9 + k, d == 4                   -- 左 / 右（翻转）
end

-- 当前棋盘原点与格距
local function board_origin()
  local P = st.P
  local cs = (P.w <= 14 and P.h <= 12) and CS_BIG or CS_SML
  local ox = flr((256 - P.w * cs) / 2)
  local oy = flr(HUD_H + 2 + (FOOT_Y - HUD_H - 6 - P.h * cs) / 2)
  return ox, oy, cs
end

local function draw_board()
  local P = st.P
  local ox, oy, cs = board_origin()
  local base = (cs == CS_BIG) and T16 or T12
  -- 目标呼吸（暗金 <-> 金）：作用在含 C_GOAL_D 的地形与归位箱上
  if flr(t / 20) % 2 == 0 then
    pal(C_GOAL_D, C_GOAL, 0)
  end
  -- 地形
  for y = 1, P.h do
    for x = 1, P.w do
      local i = (y - 1) * P.w + x
      if P.wall[i] then
        tile(base, cs, 1, ox, oy, x, y)
      elseif P.reach[i] then
        tile(base, cs, P.goal[i] and 2 or 0, ox, oy, x, y)
      end
    end
  end
  -- 箱子（正在滑动的箱子跳过，稍后按插值画）
  for i in pairs(st.box) do
    if not (st.anim and st.anim.box and st.anim.box.i == i) then
      local x = (i - 1) % P.w + 1
      local y = flr((i - 1) / P.w) + 1
      tile(base, cs, P.goal[i] and 4 or 3, ox, oy, x, y)
    end
  end
  -- 工人与被推箱子（起点到终点线性插值）
  local wx, wy = P.px, P.py
  if st.anim then
    local a = st.anim
    local u = a.p / ANIM_N
    wx = a.fx + (a.tx - a.fx) * u
    wy = a.fy + (a.ty - a.fy) * u
    if a.box then
      local bx = a.box.fx + (a.box.tx - a.box.fx) * u
      local by = a.box.fy + (a.box.ty - a.box.fy) * u
      tile(base, cs, P.goal[a.box.i] and 4 or 3, ox, oy, bx, by)
    end
  end
  local wt, flip = worker_tile(base, st.dir, st.frame)
  local sx = wt % 16 * 16
  local sy = flr(wt / 16) * 16
  sspr(sx, sy, cs, cs, ox + (wx - 1) * cs, oy + (wy - 1) * cs, cs, cs, flip)
  pal()
  -- 归位闪光：落点目标格短促白框闪烁
  if st.flash and flr(st.flash.t / 3) % 2 == 0 then
    local x = (st.flash.i - 1) % P.w + 1
    local y = flr((st.flash.i - 1) / P.w) + 1
    rect(ox + (x - 1) * cs, oy + (y - 1) * cs, cs, cs, C_TXT)
  end
end

local function draw_hud()
  rectfill(0, 0, 256, HUD_H, C_BG)
  line(0, HUD_H, 255, HUD_H, C_WALL_D)
  print("关 " .. fmt(cur_level) .. "/" .. fmt(#LEVELS), 4, 0, C_TXT)
  local mid = "步 " .. fmt(st.steps) .. " 推 " .. fmt(st.pushes)
  print(mid, (256 - tw(mid)) / 2, 0, C_TXT)
  local bp = best[cur_level]
  local bs = "最佳 " .. (bp > 0 and fmt(bp) or "-")
  print(bs, 252 - tw(bs), 0, C_GOAL)
  -- 底栏
  rectfill(0, FOOT_Y, 256, 256 - FOOT_Y, C_BG)
  line(0, FOOT_Y, 255, FOOT_Y, C_WALL_D)
  print("最少推 " .. fmt(LEVELS[cur_level].par), 4, FOOT_Y + 2, C_TXT_D)
  local hint = btnicon("b") .. "悔棋 " .. btnicon("x") .. "重开 " .. btnicon("menu") .. "选关"
  print(hint, 252 - tw(hint), FOOT_Y + 2, C_TXT_D)
  -- 死锁提示（棋盘下方闪烁）
  if stuck_t > 0 and flr(t / 8) % 2 == 0 then
    local s = "卡住了 " .. btnicon("b") .. " 悔棋"
    print(s, (256 - tw(s)) / 2, FOOT_Y - 18, C_RED)
  end
end

local function draw_sparks()
  if #sparks == 0 then return end
  local ox, oy, cs = board_origin()
  for i = 1, #sparks do
    local s = sparks[i]
    pset(ox + (s.x - 0.5) * cs, oy + (s.y - 0.5) * cs, s.c)
    pset(ox + (s.x - 0.5) * cs + 1, oy + (s.y - 0.5) * cs, s.c)
  end
end

local function draw_play()
  draw_board()
  draw_hud()
end

local function draw_clear()
  draw_play()
  draw_sparks()
  -- 居中横幅
  local bw, bh = 176, 66
  local bx, by = (256 - bw) / 2, 92
  rectfill(bx - 2, by - 2, bw + 4, bh + 4, C_INK)
  rectfill(bx, by, bw, bh, C_BG)
  rect(bx, by, bw, bh, C_GOAL)
  local s1 = "过关！"
  print(s1, (256 - tw(s1)) / 2, by + 8, C_GOAL)
  local s2 = "推动 " .. fmt(st.pushes) .. " 次"
  print(s2, (256 - tw(s2)) / 2, by + 28, C_TXT)
  local bp = best[cur_level]
  local s3 = (bp >= st.pushes) and "新纪录！" or "最佳 " .. fmt(bp)
  print(s3, (256 - tw(s3)) / 2, by + 46,
        (bp >= st.pushes) and C_GOAL or C_TXT_D)
end

-- 标题字放大位图（_init 里转录进精灵表）：带投影
local function draw_logo(x, y)
  local sx = LOGO_T % 16 * 16
  local sy = flr(LOGO_T / 16) * 16
  pal(C_TXT, C_INK, 0)
  sspr(sx, sy, 48, 16, x + 3, y + 3, 144, 48)
  pal()
  sspr(sx, sy, 48, 16, x, y, 144, 48)
end

local function draw_finale()
  rectfill(0, 0, 256, 256, C_BG)
  draw_logo(56, 30)
  local s1 = "全部通关！"
  print(s1, (256 - tw(s1)) / 2, 98, C_GOAL)
  local s2 = "感谢游玩"
  print(s2, (256 - tw(s2)) / 2, 122, C_TXT)
  local s3 = "本次累计推动 " .. fmt(total_pushes) .. " 次"
  print(s3, (256 - tw(s3)) / 2, 146, C_TXT_D)
  for i = 1, #sparks do
    pset(sparks[i].x, sparks[i].y, sparks[i].c)
  end
  if flr(t / 20) % 2 == 0 then
    local s4 = btnicon("a") .. " 返回选关"
    print(s4, (256 - tw(s4)) / 2, 196, C_HAT)
  end
end

-- 标题主题构图：工人推箱奔向目标点（箱子 + 目标点，frame 0 即完整）
local function draw_vignette()
  local function tspr(id, x, y, flip)
    sspr(id % 16 * 16, flr(id / 16) * 16, 16, 16, x, y, 16, 16, flip)
  end
  tspr(T16 + 0, 76, 78)              -- 地板
  tspr(T16 + 9, 76, 78, true)        -- 工人（朝右推）
  tspr(T16 + 0, 92, 78)              -- 地板
  tspr(T16 + 3, 92, 78)              -- 待推木箱
  for i = 0, 1 do                    -- 推进方向箭头
    local ax = 108 + i * 8
    line(ax, 82, ax + 4, 85, C_GOAL)
    line(ax, 88, ax + 4, 85, C_GOAL)
  end
  tspr(T16 + 2, 128, 78)             -- 目标点（自带地板）
  tspr(T16 + 0, 160, 78)             -- 地板
  tspr(T16 + 4, 160, 78)             -- 已归位的箱子
  line(178, 72, 182, 72, C_GOAL)     -- 归位闪光
  line(180, 70, 180, 74, C_GOAL)
end

local function draw_title()
  rectfill(0, 0, 256, 256, C_BG)
  -- 顶部仓库地面横带
  rectfill(0, 0, 256, 20, C_FLOOR)
  line(0, 20, 255, 20, C_WALL_D)
  draw_logo(56, 26)
  draw_vignette()
  -- 选关网格 4×4（菜单项即开始入口）
  local gw, gh = 52, 28
  local gx0, gy0 = (256 - 4 * gw - 3 * 4) / 2, 100
  for i = 1, #LEVELS do
    local cx = gx0 + ((i - 1) % 4) * (gw + 4)
    local cy = gy0 + flr((i - 1) / 4) * (gh + 4)
    local done = best[i] > 0
    local hot = i == sel
    rectfill(cx, cy, gw, gh, hot and C_FLOOR or C_FLOOR_D)
    if hot then
      rect(cx, cy, gw, gh, C_GOAL)
    end
    local col = done and C_GOAL or (hot and C_TXT or C_TXT_D)
    print(fmt(i), cx + 5, cy + 6, col)
    if done then
      local bs = "★" .. fmt(best[i])
      print(bs, cx + gw - 5 - tw(bs), cy + 6, C_GOAL)
    end
  end
  local s = "按 " .. btnicon("a") .. " 开始" -- 稳定提示，不闪烁
  print(s, (256 - tw(s)) / 2 + 1, 231, C_INK)
  print(s, (256 - tw(s)) / 2, 230, C_TXT)
  local h2 = btnicon("dpad") .. " 选关　" .. btnicon("view") .. " 音乐"
  print(h2, (256 - tw(h2)) / 2, 246, C_TXT_D)
end

-- Splash：纯主视觉封面（0-90 帧）——工人推巨箱奔向发光目标点的侧写特写，
-- 大 logo 放下方；零菜单零提示（Ⓐ/Menu 可跳过，90 帧后进选关菜单）
local function draw_splash()
  -- 浮尘微光（确定性散布，frame 0 即完整）
  for i = 1, 14 do
    pset((i * 53) % 256, 28 + (i * 37) % 66, (i % 3 == 0) and C_GOAL_D or C_FLOOR_D)
  end
  -- 仓库地面（地板 2× 横带，右端是发光目标点）
  for i = 0, 6 do
    sspr(T16 % 16 * 16, 0, 16, 16, i * 32, 136, 32, 32)
  end
  sspr((T16 + 2) % 16 * 16, 0, 16, 16, 224, 136, 32, 32)
  rectfill(0, 168, 256, 12, C_FLOOR_D)  -- 地面暗缘
  -- 目标点辉光（从钻石向外的扩散光环，叠在地面上）
  for i = 2, 0, -1 do
    circ(240, 152, 10 + i * 7 + sin(t * 0.06 + i * 2.1) * 2,
      (i == 0) and C_GOAL or C_GOAL_D)
  end
  -- 目标点上方星光（装饰可动）
  if flr(t / 16) % 2 == 0 then
    line(234, 112, 246, 112, 7)
    line(240, 106, 240, 118, 7)
  end
  -- 巨箱（3× 放大）与工人（2× 放大，行走两幀动画，朝右推进）
  sspr((T16 + 3) % 16 * 16, 0, 16, 16, 136, 88, 48, 48)
  local f = flr(t / 8) % 2
  sspr((T16 + 9 + f) % 16 * 16, 0, 16, 16, 96, 104, 32, 32, true)
  -- 推进动势线
  line(76, 112, 90, 112, C_TXT_D)
  line(70, 122, 86, 122, C_TXT_D)
  line(78, 132, 92, 132, C_TXT_D)
  -- 大 logo
  draw_logo(56, 186)
end

-- 百叶窗转场（确定性：仅依赖 trans.t；条间交错收放）
local function draw_trans()
  if not trans then return end
  local p
  if trans.t <= trans.T then
    p = trans.t / trans.T
  else
    p = max(0, 2 - trans.t / trans.T)
  end
  local bh = 32
  for i = 0, 7 do
    local h = flr(p * bh + 0.5)
    if h > 0 then
      if i % 2 == 0 then
        rectfill(0, i * bh, 256, h, C_INK)
      else
        rectfill(0, (i + 1) * bh - h, 256, h, C_INK)
      end
    end
  end
end

function _draw()
  cls(C_BG)
  if state == "splash" then
    draw_splash()
  elseif state == "title" then
    draw_title()
  elseif state == "play" then
    draw_play()
  elseif state == "clear" then
    draw_clear()
  elseif state == "finale" then
    draw_finale()
  end
  draw_trans()
end

-- ================================================================ 初始化

function _init()
  bake_all(T16, CS_BIG)
  bake_all(T12, CS_SML)
  init_audio()
  -- 标题字位图：先把文字画到屏幕，转录进精灵表再擦掉（一次性）
  print("推箱子", 8, 8, C_TXT)
  local sx, sy = LOGO_T % 16 * 16, flr(LOGO_T / 16) * 16
  for y = 0, 15 do
    for x = 0, 47 do
      sset(sx + x, sy + y, pget(8 + x, 8 + y))
    end
  end
  rectfill(0, 0, 72, 28, 0)

  -- 存档装载：槽 0 预留、1..N 各关最佳推动、20 音乐开关
  best = {}
  for i = 1, #LEVELS do best[i] = dget(i) end
  music_on = dget(20) == 0
  sel = 1
  state = "splash" -- 开机封面段：90 帧后回落选关菜单
  cur_level = 1
  steps, pushes = 0, 0
  st = {}
  if music_on then music(0, 500, 0xE0) end
  start_transition(function() end) -- 开场展开
end
