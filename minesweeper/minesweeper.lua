-- =====================================================================
-- FC-16 扫雷演示卡带（demo/minesweeper）
--
-- 完整规则：三难度（初级 9×9/10、中级 16×16/40、高级 20×16/70 横向滚动）/
--   首击安全（首击及其 8 邻不放雷，雷在首击后布置，首击必定开出空区）/
--   洪泛展开（逐圈波纹动画）/ Ⓑ 插旗循环（旗→问号→无）/
--   Ⓧ 和弦（已开数字格周围旗数等于数字时齐开其余邻格，误旗则爆炸）/
--   计时（首击起，frame/60）/ 剩余雷数 / 笑脸状态（正常・惊恐 O・阵亡 X・胜利墨镜）
-- 胜利：未标雷格自动补旗 + 最佳时间存档（dset 槽 0-2；槽 3 音乐开关）；
--   失败：踩雷爆红、逐雷揭幕、错旗划叉、震屏；Ⓐ 重开同难度。
-- 演出：洪泛逐圈波纹、爆炸震屏、胜利彩带；数字 1-8 高对比固定查表色。
-- 资产全部程序化：14px 格子精灵 poke 烘焙；SFX / BGM 按 SPEC §5.2 位写入。
--
-- 操作：←→↑↓ 移动（按住重复）・Ⓐ 翻开・Ⓑ 插旗循环・Ⓧ 和弦・
--       View 音乐开关・Menu 对局中重开 / 终局回标题
-- =====================================================================

-- ---------------------------------------------------------------- 常量

-- 色号（SPEC §2.2 ENDESGA-64 固定顺序；逐处按视觉挑色，不做色号算术）
local C_BG      = 15  -- #1C121C 页面深底
local C_BAR     = 12  -- #2A2F4E 顶/底栏
local C_BARLINE = 14  -- #0E071B 栏缘线
local C_FRAME   = 11  -- #424C6E 棋盘外框
local C_CELL_M  = 10  -- #657392 未开格基色（钢）
local C_CELL_L  = 8   -- #C7CFDD 未开格左上受光
local C_CELL_L2 = 9   -- #92A1B9 未开格次受光
local C_CELL_D  = 12  -- #2A2F4E 未开格右下背光
local C_CELL_D2 = 14  -- #0E071B 未开格次背光
local C_OPEN    = 13  -- #1A1932 已开格基色
local C_OPEN_D  = 14  -- #0E071B 已开格左上阴影
local C_OPEN_L  = 11  -- #424C6E 已开格右下反光
local C_TEXT    = 8   -- #C7CFDD 次要文字
local C_GRAY    = 9   -- #92A1B9 灰文字
local C_GOLD    = 23  -- #EDAB50 金（光标/标题）
local C_GOLD_L  = 31  -- #FFEB57 亮金
local C_FLAG    = 59  -- #EA323C 旗面红
local C_EXPL    = 60  -- #C42430 爆炸格红底
local C_EXPL_D  = 62  -- #571C27 爆炸格暗边
local C_EXPL_L  = 58  -- #F5555D 爆炸格亮边
local C_LED     = 58  -- #F5555D LED 亮段
local C_LED_DIM = 61  -- #891E2B LED 熄段
local C_FACE    = 30  -- #FFC825 笑脸底
local C_FACE_ED = 28  -- #ED7614 笑脸描边
local C_INK     = 13  -- #1A1932 笑脸五官
local C_WHITE   = 7

-- 数字 1-8 固定查表色（亮色压暗底，SPEC §2.2 禁止色号算术推导）
local NUMC = { 42, 33, 58, 48, 28, 44, 7, 8 }

-- 3×5 数字点阵（瓦片烘焙用；'1' 为墨迹）
local DIGPAT = {
  { "010", "110", "010", "010", "111" }, -- 1
  { "111", "001", "111", "100", "111" }, -- 2
  { "111", "001", "111", "001", "111" }, -- 3
  { "101", "101", "111", "001", "001" }, -- 4
  { "111", "100", "111", "001", "111" }, -- 5
  { "100", "100", "111", "101", "111" }, -- 6
  { "111", "001", "001", "001", "001" }, -- 7
  { "111", "101", "111", "101", "111" }, -- 8
}

-- 5×7 问号点阵（2px 块 → 10×14）
local QPAT = { "01110", "10001", "00001", "00010", "00100",
               "00000", "00100" }

-- 难度（初级/中级为标准规格；高级 20 列需横向滚动）
local DIFF = {
  { name = "初级", w = 9,  h = 9,  m = 10 },
  { name = "中级", w = 16, h = 16, m = 40 },
  { name = "高级", w = 20, h = 16, m = 70 },
}

local CS = 14     -- 格子边长（16 行 × 14 = 224 恰合 16..239 棋盘区）
local BOARD_TOP = 16
local BOARD_H = 224

-- 音效编号
local S_OPEN, S_FLAG, S_UNFLAG, S_CHORD = 0, 1, 2, 3
local S_BOOM, S_WIN, S_LOSE, S_CUR, S_GO = 4, 5, 6, 7, 8

-- 震屏偏移表（确定性查表，幀龄每 2 幀换一格）
local SHK = { { -3, 2 }, { 3, -2 }, { -2, -3 }, { 2, 3 },
              { -3, -1 }, { 3, 1 }, { -1, 3 }, { 1, -2 } }

-- 底栏提示轮播
local HINTS = {
  btnicon("dpad") .. " 移动　" .. btnicon("a") .. " 翻开　" .. btnicon("b") .. " 插旗",
  btnicon("b") .. " 再按出问号　" .. btnicon("x") .. " 和弦齐开",
  "首击必定安全 放心开局",
}

-- 标题装饰格（字符对应状态）：旗・问号・钢雷・数字格拼出对局剪影
local TSTRIP = {
  "cc2f1cc1cc2ccfcc",
  "c1f2c1cc1cf2c1c1",
  "cc1c1ccm1c1cc1cq",
}

-- ---------------------------------------------------------------- 状态

local mode = "splash"    -- splash / title / play
local di = 1             -- 当前难度
local W, H, M            -- 当前期宽/高/雷数
local x0, y0             -- 棋盘世界原点（像素）
local mine, state, mark, adj, ot, mine_show
local placed, opened
local dead, won, boom, over_t, jingled
local start_f, final_sec, new_record
local cx, cy             -- 光标（列/行）
local camx
local chord_flash
local confetti = {}
local title_sel = 1
local music_on = true
local t = 0

local function cprint(s, y, c) print(s, flr((256 - tw(s)) / 2), y, c) end

local function idx(x, y) return y * W + x + 1 end
local function cur_i() return idx(cx, cy) end

-- 计时（秒）：首击起；终局定格（min 返回浮点子类型，外层 flr 还原整数显示）
local function elapsed_sec()
  if start_f == nil then return 0 end
  return flr(min(999, flr((t - start_f) / 60)))
end

local function shown_sec()
  if won or dead then return final_sec end
  return elapsed_sec()
end

-- 剩余雷数 = 总雷 - 旗数
local function mines_left()
  local f = 0
  for i = 1, W * H do
    if mark[i] == 1 then f = f + 1 end
  end
  return M - f
end

-- ---------------------------------------------------------------- 棋盘逻辑

-- 首击安全：safe 及其 8 邻为禁区，其余格做选择抽样布 M 雷（确定性）
local function place_mines(safe)
  local sx, sy = (safe - 1) % W, flr((safe - 1) / W)
  local function excl(x, y)
    return abs(x - sx) <= 1 and abs(y - sy) <= 1
  end
  local need = M
  local rem = 0
  for i = 1, W * H do
    mine[i] = false
    if not excl((i - 1) % W, flr((i - 1) / W)) then rem = rem + 1 end
  end
  for i = 1, W * H do
    if not excl((i - 1) % W, flr((i - 1) / W)) then
      if need > 0 and flr(rnd(rem)) < need then
        mine[i] = true
        need = need - 1
      end
      rem = rem - 1
    end
  end
  for i = 1, W * H do adj[i] = 0 end
  for i = 1, W * H do
    if mine[i] then
      local x, y = (i - 1) % W, flr((i - 1) / W)
      for dy = -1, 1 do
        for dx = -1, 1 do
          if not (dx == 0 and dy == 0) then
            local nx, ny = x + dx, y + dy
            if nx >= 0 and nx < W and ny >= 0 and ny < H then
              adj[idx(nx, ny)] = adj[idx(nx, ny)] + 1
            end
          end
        end
      end
    end
  end
  placed = true
end

local function win_game()
  won = true
  final_sec = elapsed_sec()
  over_t, jingled = 0, false
  -- 胜利补旗：所有未标雷格自动插旗
  for i = 1, W * H do
    if mine[i] then mark[i] = 1 end
  end
  -- 最佳时间存档（槽 0-2 按难度；0 = 暂无）
  local best = dget(di - 1)
  new_record = best == 0 or final_sec < best
  if new_record then dset(di - 1, final_sec) end
  dset(3, music_on and 0 or 1)
  fflush()
  sfx(S_WIN)
  music(-1, 400)
  for i = 1, 34 do
    local cols = { 23, 31, 42, 33, 58, 30, 44 }
    confetti[#confetti + 1] = {
      x = rnd(256), y = -rnd(220), vy = 0.7 + rnd(0.9),
      ph = rnd(1), c = cols[i % 7 + 1],
    }
  end
end

local function check_win()
  if opened == W * H - M then win_game() end
end

local function explode(i)
  dead = true
  over_t, jingled = 0, false
  final_sec = elapsed_sec()
  boom = { i = i, t0 = t }
  mark[i] = 0
  -- 逐雷揭幕次序：按与爆点的切比雪夫距离
  local bx, by = (i - 1) % W, flr((i - 1) / W)
  for j = 1, W * H do
    if mine[j] then
      local x, y = (j - 1) % W, flr((j - 1) / W)
      mine_show[j] = max(abs(x - bx), abs(y - by)) * 2
    end
  end
  sfx(S_BOOM)
  music(-1, 300)
end

-- 洪泛展开：逐圈记录出现时刻（波纹动画），旗格不被洪泛翻开
local function flood(i0)
  local ring = { i0 }
  local r = 0
  state[i0] = 1
  mark[i0] = 0
  opened = opened + 1
  ot[i0] = t
  while #ring > 0 do
    local nring = {}
    for k = 1, #ring do
      local i = ring[k]
      if adj[i] == 0 then
        local x, y = (i - 1) % W, flr((i - 1) / W)
        for dy = -1, 1 do
          for dx = -1, 1 do
            if not (dx == 0 and dy == 0) then
              local nx, ny = x + dx, y + dy
              if nx >= 0 and nx < W and ny >= 0 and ny < H then
                local n = idx(nx, ny)
                if state[n] == 0 and mark[n] ~= 1 then
                  state[n] = 1
                  mark[n] = 0
                  opened = opened + 1
                  ot[n] = t + (r + 1) * 2
                  nring[#nring + 1] = n
                end
              end
            end
          end
        end
      end
    end
    ring = nring
    r = r + 1
  end
end

-- Ⓐ 翻开
local function do_reveal()
  local i = cur_i()
  if state[i] == 1 or mark[i] == 1 then return end
  if not placed then
    place_mines(i)
    start_f = t
  end
  if mine[i] then explode(i) return end
  flood(i)
  sfx(S_OPEN)
  check_win()
end

-- Ⓑ 插旗循环：无 → 旗 → 问号 → 无
local function cycle_mark()
  local i = cur_i()
  if state[i] == 1 then return end
  if mark[i] == 0 then
    mark[i] = 1
    sfx(S_FLAG)
  else
    mark[i] = mark[i] == 1 and 2 or 0
    sfx(S_UNFLAG)
  end
end

-- Ⓧ 和弦：数字格周围旗数等于数字时，齐开其余邻格（误旗则爆炸）
local function do_chord()
  local i = cur_i()
  if state[i] ~= 1 or adj[i] == 0 then return end
  local x, y = (i - 1) % W, flr((i - 1) / W)
  local f = 0
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if nx >= 0 and nx < W and ny >= 0 and ny < H and mark[idx(nx, ny)] == 1 then
          f = f + 1
        end
      end
    end
  end
  if f ~= adj[i] then
    chord_flash = { i = i, t = t }
    return
  end
  local hit = false
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if nx >= 0 and nx < W and ny >= 0 and ny < H then
          local n = idx(nx, ny)
          if state[n] == 0 and mark[n] ~= 1 then
            if mine[n] then hit = true end
          end
        end
      end
    end
  end
  if hit then
    -- 有未旗之雷（存在误旗）：翻开即爆
    for dy = -1, 1 do
      for dx = -1, 1 do
        if not (dx == 0 and dy == 0) then
          local nx, ny = x + dx, y + dy
          if nx >= 0 and nx < W and ny >= 0 and ny < H then
            local n = idx(nx, ny)
            if state[n] == 0 and mark[n] ~= 1 and mine[n] then
              explode(n)
              return
            end
          end
        end
      end
    end
  end
  for dy = -1, 1 do
    for dx = -1, 1 do
      if not (dx == 0 and dy == 0) then
        local nx, ny = x + dx, y + dy
        if nx >= 0 and nx < W and ny >= 0 and ny < H then
          local n = idx(nx, ny)
          if state[n] == 0 and mark[n] ~= 1 then flood(n) end
        end
      end
    end
  end
  sfx(S_CHORD)
  check_win()
end

-- ---------------------------------------------------------------- 对局控制

local function start_game(d)
  di = d
  local dd = DIFF[d]
  W, H, M = dd.w, dd.h, dd.m
  x0 = flr((256 - W * CS) / 2)
  y0 = BOARD_TOP + flr((BOARD_H - H * CS) / 2)
  mine, state, mark, adj, ot, mine_show = {}, {}, {}, {}, {}, {}
  -- 显式清零：state/mark 依赖 == 0 判定（nil ~= 0 会让洪泛/和弦失效）
  for i = 1, W * H do
    mine[i] = false
    state[i] = 0
    mark[i] = 0
    adj[i] = 0
  end
  placed, opened = false, 0
  dead, won, boom = false, false, nil
  over_t, jingled = 0, false
  start_f, final_sec, new_record = nil, 0, false
  cx, cy = flr(W / 2), flr(H / 2)
  camx, chord_flash = 0, nil
  confetti = {}
  mode = "play"
  if music_on then music(0, 300, 0xE0) end
  sfx(S_GO)
end

local function goto_title()
  mode = "title"
  confetti = {}
  if music_on then music(0, 300, 0xE0) end
end

local function toggle_music()
  music_on = not music_on
  dset(3, music_on and 0 or 1)
  if music_on then music(0, 300, 0xE0) else music(-1, 200) end
end

-- ---------------------------------------------------------------- 音频

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

-- 按 SPEC §5.2 写一条 SFX（144B = 头 16B + 32 步 × 4B）；vol 可为单值或逐步表；fx 为逐步效果码
-- 音高为旧固件值（1-96 = C0-B7），写卡带前换算为新 0-95 并用音量 0 表休止
local function init_sfx(id, notes, wave, vol, speed, fx)
  local base = 0x0C0000 + id * 144
  local spd = speed or 1
  poke2(base, (spd == 0 and 1 or spd) * 4)  -- 旧每步帧数(60Hz) → 新 SPD tick(240Hz)
  u8(base + 2, #notes)
  for i = 0, 31 do
    local a = base + 16 + i * 4
    local n = notes[i + 1]
    if n and n > 0 then
      local v = type(vol) == "table" and vol[i + 1] or vol
      u8(a, n - 1)
      u8(a + 1, WMAP[wave])
      u8(a + 2, v)
      u8(a + 3, fx or 0)
    else
      u8(a, 0)
      u8(a + 1, 0)
      u8(a + 2, 0)
      u8(a + 3, 0)
    end
  end
end

local function init_audio()
  init_waveforms()
  init_sfx(S_OPEN, { 50, 55 }, 0, 6, 1)            -- 翻格：轻双跳
  init_sfx(S_FLAG, { 69, 76 }, 4, 9, 1)            -- 插旗：上扬
  init_sfx(S_UNFLAG, { 76, 69 }, 4, 7, 1)          -- 拔旗 / 问号
  init_sfx(S_CHORD, { 60, 64, 67 }, 3, 10, 1)      -- 和弦：三连
  init_sfx(S_BOOM, { 30, 26, 22, 18 }, 14, { 15, 11, 8, 5 }, 2, 3) -- 爆炸
  init_sfx(S_WIN, { 49, 53, 56, 61, 65, 68, 73 }, 3, 11, 2)        -- 胜利
  init_sfx(S_LOSE, { 56, 53, 49, 44, 41, 37 }, 2, 10, 3)           -- 失利
  init_sfx(S_CUR, { 76 }, 0, 3, 1)                 -- 光标
  init_sfx(S_GO, { 61, 68 }, 3, 9, 2)              -- 开局

  -- BGM：C 大调 I-vi-IV-V 四小节循环（旋律 / 琶音和声 / 贝斯 = ch5-7）
  -- 每小节 8 个八分音符 ×4 步、speed 5 → 160 幀/小节
  local melody = {
    { 53, 0, 56, 58, 61, 0, 58, 56 },  -- C
    { 58, 0, 61, 58, 56, 0, 53, 0 },   -- Am
    { 54, 0, 58, 61, 0, 58, 54, 0 },   -- F
    { 56, 0, 60, 63, 0, 60, 56, 0 },   -- G
  }
  local harmony = { { 44, 53 }, { 46, 53 }, { 42, 49 }, { 44, 51 } }
  local bass = { 37, 34, 30, 32 }
  local function expand(notes, k)
    local out = {}
    for _, v in ipairs(notes) do
      for _ = 1, k do out[#out + 1] = v end
    end
    return out
  end
  for r = 0, 3 do
    for c = 0, 7 do u8(MUSIC_BASE + 32 + r * 32 + c, 0xFF) end  -- 空轨写 0xFF（0 是合法 SFX 号）
  end
  for bar = 1, 4 do
    init_sfx(8 + bar, expand(melody[bar], 4), 8, 9, 5)   -- ROUND 旋律
    local h = {}
    for i = 1, 8 do h[i] = harmony[bar][i % 2 + 1] end
    init_sfx(12 + bar, expand(h, 4), 0, 5, 5)            -- TRIANGLE 和声
    init_sfx(16 + bar, expand({ bass[bar] }, 32), 11, 10, 5) -- BASS
    local mb = MUSIC_BASE + 32 + (bar - 1) * 32
    u8(mb + 5, 8 + bar)   -- ch5 旋律
    u8(mb + 6, 12 + bar)  -- ch6 和声
    u8(mb + 7, 16 + bar)  -- ch7 贝斯
    if bar == 1 then u8(mb + 16, 1) end    -- LOOP_START：循环起点
    if bar == 4 then u8(mb + 17, 1) end    -- LOOP_BACK：回到 LOOP_START
  end
  u8(MUSIC_BASE, 4)  -- 全表 LEN = 4 行
end

-- ---------------------------------------------------------------- 精灵烘焙

-- 逐像素写瓦片（SPEC §4.2：瓦片像素地址 = t*256 + y*16 + x）
local function bake(id, fn)
  local base = id * 256
  for y = 0, 15 do
    for x = 0, 15 do
      local c = fn(x + 0.5, y + 0.5)
      poke(base + y * 16 + x, c or 0)
    end
  end
end

-- 未开格：钢面双级斜面（左上受光 / 右下背光），设计区 14×14
local function closed_px(x, y)
  if x >= 14 or y >= 14 then return nil end
  if y == 13 or x == 13 then return C_CELL_D end
  if y == 0 or x == 0 then return C_CELL_L end
  if y == 1 or x == 1 then return C_CELL_L2 end
  if y == 12 or x == 12 then return C_CELL_D2 end
  return C_CELL_M
end

-- 已开格：凹陷（左上阴影 / 右下反光）
local function open_px(x, y)
  if x >= 14 or y >= 14 then return nil end
  if y == 0 or x == 0 then return C_OPEN_D end
  if y == 13 or x == 13 then return C_OPEN_L end
  return C_OPEN
end

-- 水雷几何：弹体 + 八向尖刺 + 左上高光（ball/spike/glint 为色号）
local function mine_px(x, y, ball, spike, glint)
  local dx, dy = x - 6.5, y - 6.5
  local d2 = dx * dx + dy * dy
  if d2 <= 16.5 then
    if glint and dx <= -0.5 and dy <= -0.5 and dx >= -3 and dy >= -3 then
      return glint
    end
    return ball
  end
  -- 轴向尖刺
  if (y == 6 or y == 7) and (x <= 1 or x >= 12) then return spike end
  if (x == 6 or x == 7) and (y <= 1 or y >= 12) then return spike end
  -- 对角尖刺
  local ax, ay = abs(dx), abs(dy)
  if ax <= 5 and ax >= 3.5 and ay <= 5 and ay >= 3.5 then return spike end
  return nil
end

local function bake_cells()
  bake(1, closed_px)                       -- 未开格
  bake(2, open_px)                         -- 已开格
  bake(3, function(x, y)                   -- 旗（透明底覆盖层）
    if x >= 6 and x <= 6 and y >= 2 and y <= 11 then return C_WHITE end
    if x >= 7 and y >= 2 and y <= 6 and x <= 6 + (7 - y) then return C_FLAG end
    if y >= 11 and y <= 12 and x >= 4 and x <= 8 then return C_CELL_L end
  end)
  bake(4, function(x, y)                   -- 问号（透明底覆盖层）
    local r = flr(y / 2)
    local c = flr((x - 2) / 2)
    if r < 7 and c >= 0 and c < 5 and x >= 2 and x < 12 then
      local row = QPAT[r + 1]
      if row:sub(c + 1, c + 1) == "1" then return C_GOLD end
    end
  end)
  bake(5, function(x, y)                   -- 已开格 + 钢雷（雷优先，open_px 全域非 nil）
    return mine_px(x, y, 6, 5, 7) or open_px(x, y)
  end)
  bake(6, function(x, y)                   -- 爆炸格：红底 + 黑雷
    if x >= 14 or y >= 14 then return nil end
    if y == 0 or x == 0 then return C_EXPL_D end
    if y == 13 or x == 13 then return C_EXPL_L end
    return mine_px(x, y, 14, 14, nil) or C_EXPL
  end)
  bake(7, function(x, y)                   -- 错旗：已开格 + 暗雷 + 红叉（雷优先）
    if abs(x - y) <= 1 or abs(x + y - 13) <= 1 then
      if x >= 2 and x <= 11 and y >= 2 and y <= 11 then return C_EXPL_L end
    end
    return mine_px(x, y, 4, 4, nil) or open_px(x, y)
  end)
  -- 数字 1-8：已开格 + 3×5 点阵 ×2 放大（居中 6×10）
  for d = 1, 8 do
    local pat = DIGPAT[d]
    local col = NUMC[d]
    bake(7 + d, function(x, y)
      local c = flr((x - 4) / 2)
      local r = flr((y - 2) / 2)
      if c >= 0 and c < 3 and r >= 0 and r < 5 and x >= 4 and x < 10 and y >= 2 and y < 12 then
        if pat[r + 1]:sub(c + 1, c + 1) == "1" then return col end
      end
      return open_px(x, y)
    end)
  end
  -- 标题大雷（16×16 全幅）
  bake(16, function(x, y)
    local dx, dy = x - 8, y - 8
    if dx * dx + dy * dy <= 34 then
      if dx <= -1 and dy <= -1 and dx >= -5 and dy >= -5 then return 7 end
      return 6
    end
    local ax, ay = abs(dx), abs(dy)
    if ax <= 7 and ay <= 0.5 or ay <= 7 and ax <= 0.5 then
      if ax + ay >= 6 then return 5 end
    end
    if ax <= 6.5 and ax >= 4.5 and ay <= 6.5 and ay >= 4.5 then return 5 end
  end)
end

-- 瓦片 → 精灵表源坐标
local function tile_src(id)
  return (id % 16) * 16, flr(id / 16) * 16
end

-- 画 14×14 格子瓦片
local function blit(id, x, y)
  local sx, sy = tile_src(id)
  sspr(sx, sy, 14, 14, x, y)
end

-- ---------------------------------------------------------------- LED 数码管

-- 七段码（段序 a 顶 b 右上 c 右下 d 底 e 左下 f 左上 g 中）与段矩形
local SEG = {
  [0] = { 1, 1, 1, 1, 1, 1, 0 }, [1] = { 0, 1, 1, 0, 0, 0, 0 },
  [2] = { 1, 1, 0, 1, 1, 0, 1 }, [3] = { 1, 1, 1, 1, 0, 0, 1 },
  [4] = { 0, 1, 1, 0, 0, 1, 1 }, [5] = { 1, 0, 1, 1, 0, 1, 1 },
  [6] = { 1, 0, 1, 1, 1, 1, 1 }, [7] = { 1, 1, 1, 0, 0, 0, 0 },
  [8] = { 1, 1, 1, 1, 1, 1, 1 }, [9] = { 1, 1, 1, 1, 0, 1, 1 },
  [10] = { 0, 0, 0, 0, 0, 0, 1 }, -- '-'
}
local SEGR = {
  { 1, 0, 3, 1 }, { 4, 1, 1, 3 }, { 4, 5, 1, 3 }, { 1, 8, 3, 1 },
  { 0, 5, 1, 3 }, { 0, 1, 1, 3 }, { 1, 4, 3, 1 },
}

local function led_digit(x, y, d)
  local seg = SEG[d]
  for s = 1, 7 do
    local r = SEGR[s]
    rectfill(x + r[1], y + r[2], r[3], r[4], seg[s] == 1 and C_LED or C_LED_DIM)
  end
end

-- 三位 LED 显示（负数 = '-' + 两位；正数带前导零）
local function led_show(x, v)
  rectfill(x, 2, 25, 12, 0)
  rect(x, 2, 25, 12, C_BARLINE)
  local av = min(abs(v), 999)
  if v < 0 then
    av = min(av, 99)
    led_digit(x + 3, 3, 10)
    led_digit(x + 10, 3, flr(av / 10))
    led_digit(x + 17, 3, av % 10)
  else
    led_digit(x + 3, 3, flr(av / 100) % 10)
    led_digit(x + 10, 3, flr(av / 10) % 10)
    led_digit(x + 17, 3, av % 10)
  end
end

-- ---------------------------------------------------------------- 笑脸按钮

local function draw_face()
  local fx, fy = 128, 8
  circfill(fx, fy, 6, C_FACE)
  circ(fx, fy, 6, C_FACE_ED)
  if dead then
    -- 阵亡：X 眼 + 撇嘴
    for _, ox in ipairs({ -3, 3 }) do
      line(fx + ox - 1, fy - 2, fx + ox + 1, fy, C_INK)
      line(fx + ox + 1, fy - 2, fx + ox - 1, fy, C_INK)
    end
    for dx = -2, 2 do pset(fx + dx, fy + 3 - flr((4 - dx * dx) / 2), C_INK) end
  elseif won then
    -- 胜利：墨镜 + 笑
    rectfill(fx - 5, fy - 2, 4, 2, C_INK)
    rectfill(fx + 1, fy - 2, 4, 2, C_INK)
    pset(fx, fy - 1, C_INK)
    if flr(t / 8) % 4 == 0 then pset(fx - 3, fy - 1, C_WHITE) end
    for dx = -2, 2 do pset(fx + dx, fy + 2 + flr((4 - dx * dx) / 2), C_INK) end
  elseif mode == "play" and btn(4) then
    -- 按下惊恐：圆睁眼 + O 形嘴
    circ(fx - 3, fy - 1, 1, C_INK)
    circ(fx + 3, fy - 1, 1, C_INK)
    circ(fx, fy + 3, 2, C_INK)
  else
    pset(fx - 3, fy - 1, C_INK)
    pset(fx + 3, fy - 1, C_INK)
    for dx = -2, 2 do pset(fx + dx, fy + 2 + flr((4 - dx * dx) / 2), C_INK) end
  end
end

-- ---------------------------------------------------------------- 绘制

local function draw_board()
  -- 棋盘外框
  rect(x0 - 2, y0 - 2, W * CS + 4, H * CS + 4, C_FRAME)
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local i = idx(x, y)
      local sx = x0 + x * CS
      local sy = y0 + y * CS
      local scr = sx - camx
      if scr > -CS and scr < 256 then
        if dead then
          if mine[i] then
            if mark[i] == 1 then
              blit(1, sx, sy)      -- 正确旗雷：保留旗
              blit(3, sx, sy)
            elseif t >= boom.t0 + mine_show[i] then
              if i == boom.i then
                blit(6, sx, sy)    -- 爆点：红底雷
              else
                blit(5, sx, sy)    -- 揭幕钢雷
              end
            else
              blit(1, sx, sy)
            end
          elseif mark[i] == 1 then
            blit(t >= boom.t0 + 14 and 7 or 1, sx, sy) -- 错旗划叉
          else
            blit(state[i] == 1 and (adj[i] > 0 and 7 + adj[i] or 2) or 1, sx, sy)
          end
        elseif won then
          if mine[i] then
            blit(1, sx, sy)
            blit(3, sx, sy)
          else
            blit(adj[i] > 0 and 7 + adj[i] or 2, sx, sy)
          end
        elseif state[i] == 1 then
          if t >= ot[i] then
            blit(adj[i] > 0 and 7 + adj[i] or 2, sx, sy)
            -- 波纹展开闪现：出现后 2 幀叠白色抖动
            if t - ot[i] < 2 then
              fillp(0x7777)
              rectfill(sx, sy, CS, CS, 8 * 256 + C_OPEN)
              fillp()
            end
          else
            blit(1, sx, sy)
          end
        else
          blit(1, sx, sy)
          if mark[i] == 1 then
            blit(3, sx, sy)
          elseif mark[i] == 2 then
            blit(4, sx, sy)
          end
        end
      end
    end
  end
  -- 和弦不匹配提示：白框闪
  if chord_flash and t - chord_flash.t < 12 then
    local i = chord_flash.i
    if flr((t - chord_flash.t) / 4) % 2 == 0 then
      local sx = x0 + ((i - 1) % W) * CS
      local sy = y0 + flr((i - 1) / W) * CS
      rect(sx, sy, CS, CS, C_WHITE)
    end
  end
  -- 光标：金色角括号（仅对局中）
  if not dead and not won then
    local sx = x0 + cx * CS
    local sy = y0 + cy * CS
    local c = flr(t / 6) % 2 == 0 and C_GOLD_L or C_GOLD
    line(sx, sy, sx + 4, sy, c)
    line(sx, sy, sx, sy + 4, c)
    line(sx + CS - 5, sy, sx + CS, sy, c)
    line(sx + CS, sy, sx + CS, sy + 4, c)
    line(sx, sy + CS - 5, sx, sy + CS, c)
    line(sx, sy + CS, sx + 4, sy + CS, c)
    line(sx + CS, sy + CS - 5, sx + CS, sy + CS, c)
    line(sx + CS - 5, sy + CS, sx + CS, sy + CS, c)
  end
end

local function draw_hud()
  rectfill(0, 0, 256, 16, C_BAR)
  line(0, 16, 255, 16, C_BARLINE)
  led_show(4, mines_left())
  led_show(227, shown_sec())
  draw_face()
end

local function draw_bottom()
  rectfill(0, 240, 256, 16, C_BAR)
  line(0, 240, 255, 240, C_BARLINE)
  cprint(HINTS[flr(t / 150) % 3 + 1], 240, C_GRAY)
end

local function draw_confetti()
  for i = 1, #confetti do
    local p = confetti[i]
    rectfill(p.x, p.y, 2, 2, p.c)
  end
end

local function draw_over_panel()
  if over_t <= 36 then return end
  -- dget 返回浮点数，显示前取整（秒数恒为整数，避免 "34.0"）
  local best = flr(dget(di - 1))
  if won then
    rrectfill(28, 80, 200, 84, 6, 36)
    rrect(28, 80, 200, 84, 6, 33)
    cprint("胜利！", 88, C_GOLD_L)
    cprint("用时 " .. final_sec .. " 秒", 110, C_TEXT)
    if new_record then
      if flr(t / 6) % 2 == 0 then cprint("新纪录！", 128, C_GOLD_L) end
    else
      cprint("最快 " .. best .. " 秒", 128, C_TEXT)
    end
  else
    rrectfill(28, 80, 200, 84, 6, 26)
    rrect(28, 80, 200, 84, 6, 58)
    cprint("踩雷了", 88, C_LED)
    cprint("用时 " .. final_sec .. " 秒", 110, C_TEXT)
    if best > 0 then
      cprint("最快 " .. best .. " 秒", 128, C_TEXT)
    else
      cprint("再接再厉", 128, C_TEXT)
    end
  end
  cprint(btnicon("a") .. " 再来一局　" .. btnicon("menu") .. " 回标题", 146, C_GRAY)
end

-- 标题装饰格条（用真实瓦片拼三排对局剪影：旗 / 问号 / 钢雷 / 数字）
local function draw_title_strip()
  local yy = 196
  for r = 1, 3 do
    local row = TSTRIP[r]
    for c = 0, #row - 1 do
      local ch = row:sub(c + 1, c + 1)
      local x = 16 + c * CS
      local y = yy + (r - 1) * CS
      if ch == "c" then
        blit(1, x, y)
      elseif ch == "f" then
        blit(1, x, y) blit(3, x, y)
      elseif ch == "q" then
        blit(1, x, y) blit(4, x, y)
      elseif ch == "m" then
        blit(5, x, y)
      elseif ch >= "1" and ch <= "8" then
        blit(7 + tonumber(ch), x, y)
      else
        blit(2, x, y)
      end
    end
  end
end

-- Splash：纯主视觉封面（0-90 帧）——大地雷特写 + 旗帜 + 掀开的数字格，
-- 零菜单零提示零统计（封面帧 --cover 30 落在本段）
local function draw_splash()
  cls(C_BG)
  -- 大 logo（scale 4：暗影 + 金/旗红）
  local cw = tw("扫") * 4
  local xs = { 128 - cw - 10, 128 + 10 }
  local chars, cols = { "扫", "雷" }, { C_GOLD_L, C_FLAG }
  for i = 1, 2 do
    print(chars[i], xs[i] + 4, 24, C_BARLINE, 4)
    print(chars[i], xs[i], 20, cols[i], 4)
  end
  cprint("MINESWEEPER ・ FC-16", 78, C_GRAY)
  -- 主视觉：大地雷（钢雷高光，scale 7）居中 + 金色角括号对焦
  sspr(0, 16, 16, 16, 72, 96, 112, 112)
  local function brackets(x, y, w, h)
    local c = flr(t / 6) % 2 == 0 and C_GOLD_L or C_GOLD
    line(x, y, x + 12, y, c) line(x, y, x, y + 12, c)
    line(x + w - 1, y, x + w - 13, y, c) line(x + w - 1, y, x + w - 1, y + 12, c)
    line(x, y + h - 1, x + 12, y + h - 1, c) line(x, y + h - 1, x, y + h - 13, c)
    line(x + w - 1, y + h - 1, x + w - 13, y + h - 1, c)
    line(x + w - 1, y + h - 1, x + w - 1, y + h - 13, c)
  end
  brackets(66, 90, 124, 124)
  -- 旗帜格（未开钢面 + 旗，scale 4）与掀开的数字 3 格（scale 4）
  local cx1, cy1 = tile_src(1)
  local fx, fy = tile_src(3)
  local nx, ny = tile_src(10)
  sspr(cx1, cy1, 14, 14, 194, 160, 56, 56)
  sspr(fx, fy, 14, 14, 194, 160, 56, 56)
  sspr(nx, ny, 14, 14, 8, 162, 56, 56)
  -- 底部雷区地表：两排未开格 + 零星旗/数字（纯装饰）
  for c = 0, 18 do
    blit(1, c * 14 + c % 2, 228)
    blit(1, c * 14 + (c + 1) % 2, 242)
  end
  blit(1, 40, 228) blit(3, 40, 228)   -- 旗
  blit(9, 112, 242)                    -- 数字 2
  blit(11, 190, 242)                   -- 数字 4
end

local function draw_title()
  -- 匾额
  rrectfill(44, 22, 168, 42, 6, 16)
  rrect(44, 22, 168, 42, 6, C_GOLD)
  cprint("扫雷", 28, C_GOLD_L)
  cprint("FC-16 MINESWEEPER", 47, C_GRAY)
  -- 两侧大雷 / 大旗（2× 最近邻放大）
  sspr(0, 16, 16, 16, 8, 26, 32, 32)
  sspr(16, 0, 14, 14, 214, 26, 28, 28)
  sspr(48, 0, 14, 14, 214, 26, 28, 28)
  -- 难度菜单
  for i = 1, 3 do
    local dd = DIFF[i]
    local y = 92 + (i - 1) * 26
    local sel = title_sel == i
    if sel then print("▶", 28, y, C_GOLD_L) end
    local nm = dd.name
    print(nm, 48, y, sel and C_GOLD_L or C_TEXT)
    local spec = dd.w .. "×" .. dd.h .. "・" .. dd.m .. "雷"
    print(spec, 94, y, sel and C_TEXT or C_GRAY)
    local best = flr(dget(i - 1))
    local bs = best > 0 and best .. "秒" or "无"
    print(bs, 232 - tw(bs), y, best > 0 and C_GOLD or C_GRAY)
  end
  -- 操作 / 开始提示（图标、稳定不闪烁；Ⓑ 插旗・Ⓧ 和弦在此写明）
  local h1 = btnicon("a") .. " 翻开　" .. btnicon("b") .. " 插旗　" .. btnicon("x") .. " 和弦"
  cprint(h1, 168, C_GRAY)
  local h2 = btnicon("up") .. btnicon("down") .. " 选难度　" .. btnicon("a") .. " 开始　"
    .. btnicon("view") .. " 音乐" .. (music_on and "开" or "关")
  cprint(h2, 184, C_GRAY)
  draw_title_strip()
end

function _draw()
  cls(C_BG)
  if mode == "splash" then
    draw_splash()
    return
  end
  if mode == "title" then
    draw_title()
    return
  end
  -- 震屏：爆炸后 22 幀查表抖动（叠加横向滚动）
  local shx, shy = 0, 0
  if dead and t - boom.t0 < 22 then
    local o = SHK[flr((t - boom.t0) / 2) % 8 + 1]
    shx, shy = o[1], o[2]
  end
  camera(camx + shx, shy)
  draw_board()
  camera(0, 0)
  draw_hud()
  draw_bottom()
  if won then draw_confetti() end
  if dead or won then draw_over_panel() end
end

-- ---------------------------------------------------------------- 输入

local hold_dx, hold_dy, rep_t = 0, 0, 0

local function nudge(dx, dy)
  cx = mid(0, cx + dx, W - 1)
  cy = mid(0, cy + dy, H - 1)
  sfx(S_CUR)
end

-- 方向键按住重复（btnp 无自动重复：首按 1 步，按住 14 幀后每 5 幀一步）
local function cursor_repeat()
  local dx = (dir(1) and 1 or 0) - (dir(0) and 1 or 0)
  local dy = (dir(3) and 1 or 0) - (dir(2) and 1 or 0)
  if dx == 0 and dy == 0 then
    hold_dx, hold_dy, rep_t = 0, 0, 0
    return
  end
  if dx ~= hold_dx or dy ~= hold_dy then
    hold_dx, hold_dy = dx, dy
    rep_t = 0
    nudge(dx, dy)
  else
    rep_t = rep_t + 1
    if rep_t >= 14 and rep_t % 5 == 0 then nudge(dx, dy) end
  end
end

-- 高级 20 列横向滚动：光标保持在屏内舒适带（缓动趋近）
local function update_scroll()
  local range = max(0, W * CS - 256)
  if range <= 0 then camx = 0 return end
  local px = x0 + cx * CS
  local target = mid(max(0, px + CS - 196), camx, min(range, px - 60))
  camx = camx + mid(-3, target - camx, 3)
end

local function update_title()
  if dirp(2) then
    title_sel = title_sel == 1 and 3 or title_sel - 1
    sfx(S_CUR)
  end
  if dirp(3) then
    title_sel = title_sel % 3 + 1
    sfx(S_CUR)
  end
  if btnp(10) then toggle_music() end
  if btnp(4) or btnp(11) then start_game(title_sel) end
end

function _update()
  t = t + 1
  if mode == "splash" then
    if t > 90 or btnp(4) or btnp(11) then mode = "title" end
    return
  end
  if mode == "title" then
    update_title()
    return
  end
  if btnp(10) then toggle_music() end
  if won or dead then
    over_t = over_t + 1
    if won then
      for i = 1, #confetti do
        local p = confetti[i]
        p.y = p.y + p.vy
        p.x = p.x + sin(p.ph) * 0.6
        p.ph = p.ph + 0.05
        if p.y > 256 then
          p.y = -10
          p.x = rnd(256)
        end
      end
    else
      -- 揭幕收束后补一段失利旋律
      if not jingled and t >= boom.t0 + 50 then
        jingled = true
        sfx(S_LOSE)
      end
    end
    if over_t > 36 then
      if btnp(4) then start_game(di) end
      if btnp(11) then goto_title() end
    end
    return
  end
  if btnp(11) then start_game(di) end
  cursor_repeat()
  update_scroll()
  if btnp(4) then do_reveal() end
  if btnp(5) then cycle_mark() end
  if btnp(6) then do_chord() end
end

-- ---------------------------------------------------------------- 初始化

function _init()
  bake_cells()
  init_audio()
  music_on = dget(3) == 0
  W, H, M = 9, 9, 10
  mine, state, mark, adj, ot, mine_show = {}, {}, {}, {}, {}, {}
  placed, opened = false, 0
  dead, won, boom = false, false, nil
  start_f, final_sec, new_record = nil, 0, false
  cx, cy = 4, 4
  camx, chord_flash = 0, nil
  x0, y0 = flr((256 - W * CS) / 2), BOARD_TOP + flr((BOARD_H - H * CS) / 2)
  title_sel = 1
  mode = "splash"
  t = 0
  if music_on then music(0, 500, 0xE0) end
end
