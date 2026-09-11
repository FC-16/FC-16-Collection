-- 贪吃蛇 ・ FC-16 演示卡带
-- 模式：经典（撞墙/撞己皆亡）/ 穿墙（四边环绕）/ 障碍（固定障碍阵 + 致命边界）
-- 网格逻辑 + 渲染插值：蛇身按步进间进度平滑滑动，体节桥接补缝，穿墙两侧补画；
-- 明暗相间花纹；吃食头部放大；星果光环 + 倒计时闪烁 + 扩散环庆祝；
-- 死亡闪红（绘制期 + 显示期映射）+ 撞击回弹 + 自尾向头逐节碎裂
-- 音频：转向轻响 / 吃食音高随连吃上升 8 级 / 星果琶音 / 死亡下坠 / 新纪录旋律 /
--       原创 8 小节循环 BGM（Select 开关）；分模式最高分 dset + fflush 持久化
-- 精灵与全部 SFX/PATTERN 由 _init 程序化写入（SPEC §4.2/§5.2），颜色直取 §2.2 色表
-- 操作：⬅⬆⬇➡ 转向（入队即刻预转向 + 轻响）　Ⓑ/Start 暂停　Ⓐ 确认・重来　Select 音乐开关

-- ---------------------------------------------------------------- 常量

local COLS, ROWS, CELL = 16, 14, 16 -- 场地格子数 × 格边长（像素）
local FX, FY = 0, 16                -- 场地像素原点（顶栏 16px 之下）
local FW, FH = COLS * CELL, ROWS * CELL
local MODES = {"经典", "穿墙", "障碍"}
local WRAP = {false, true, false}   -- 模式 2 穿墙
local SPD_NAME, SPD_INT, SPD_COL = {"慢", "中", "快"}, {12, 10, 8}, {33, 30, 59}
local BEST_SLOT = {0, 1, 2}         -- 分模式最高分 dset 槽位
-- 方向：1 右 2 上 3 左 4 下（同轴奇偶相同 → 禁止 180° 回头）
local DX, DY = {1, 0, -1, 0}, {0, -1, 0, 1}
local KEY2DIR = {[0] = 3, [1] = 1, [2] = 2, [3] = 4}
-- 障碍阵：四条横栏 + 中央 2×2 方墩（出生行 2 保持畅通）
local OBS = {
  {2, 4}, {3, 4}, {4, 4}, {5, 4}, {10, 4}, {11, 4}, {12, 4}, {13, 4},
  {2, 9}, {3, 9}, {4, 9}, {5, 9}, {10, 9}, {11, 9}, {12, 9}, {13, 9},
  {7, 6}, {8, 6}, {7, 7}, {8, 7},
}
local function fmt(n) return string.format("%d", n) end

-- ---------------------------------------------------------------- 音频（SPEC §5.2）

local function u8(a, v) poke(a, v % 256) end
-- 写一条 SFX：steps[i] = {音高, 波形, 音量[, 效果]}，nil 步为休止
local function write_sfx(id, speed, steps, len)
  local base = 0x060000 + id * 112
  u8(base, speed)
  u8(base + 1, len or #steps)
  for i = 0, 31 do
    local a, s = base + 16 + i * 3, steps[i + 1]
    if s then u8(a, s[1] or 0) u8(a + 1, (s[2] or 0) * 16 + (s[3] or 0)) u8(a + 2, s[4] or 0)
    else u8(a, 0) u8(a + 1, 0) u8(a + 2, 0) end
  end
end
-- 原创循环 BGM（A 小调五声，8 小节）：每小节 = 一条 32 步 SFX（speed 4，八分音符
-- 展开 4 步）；四声部旋律 20-27 / 琶音 32-39 / 贝斯 44-51 / 鼓 56-63，
-- PATTERN 0-7 顺序相连并 BEGIN/END 回环，占 ch4-7（music mask 0xF0）
local MEL = {
  {58, 61, 63, 65, 63, 61, 58, 0}, {56, 58, 61, 58, 56, 53, 0, 0},
  {58, 61, 63, 65, 68, 65, 63, 61}, {63, 0, 61, 58, 58, 0, 0, 0},
  {65, 0, 68, 0, 70, 0, 68, 65}, {63, 65, 63, 61, 58, 61, 63, 0},
  {58, 0, 61, 63, 65, 63, 61, 58}, {56, 58, 58, 0, 0, 0, 0, 0},
}
local ARP = {
  {46, 49, 53}, {41, 44, 48}, {46, 49, 53}, {46, 49, 53},
  {42, 46, 49}, {39, 42, 46}, {46, 49, 53}, {41, 44, 48},
}
local BASS_ROOT = {34, 29, 34, 34, 30, 27, 34, 29}
local function init_audio()
  -- 游戏音效（显式走 ch0-2，ch4-7 留给音乐）
  write_sfx(0, 1, {{60, 3, 5}, {67, 3, 6}})               -- 菜单微调
  write_sfx(1, 1, {{58, 3, 9}, {62, 3, 10}, {65, 3, 11}}) -- 开始
  write_sfx(2, 1, {{72, 3, 3}})                           -- 转向轻响
  for lvl = 0, 7 do -- 吃食：连吃音高上升
    local p = 58 + lvl * 2
    write_sfx(3 + lvl, 1, {{p, 3, 10}, {p + 4, 3, 11}, {p + 7, 3, 9}})
  end
  write_sfx(11, 2, {{67, 10, 9}, {72, 10, 10}, {76, 10, 11}, {79, 10, 12}}) -- 星果琶音
  write_sfx(12, 3, {{54, 8, 6}, {49, 8, 5}, {44, 8, 4}})  -- 星果消散
  write_sfx(13, 2, {{45, 2, 12, 3}, {37, 2, 11, 3}, {29, 2, 10, 3}, {21, 2, 9, 3}}) -- 死亡下坠
  write_sfx(14, 2, {{60, 3, 10}, {64, 3, 10}, {67, 3, 11}, {72, 3, 12}, nil,
    {72, 3, 10}, {76, 3, 13}}) -- 新纪录
  write_sfx(15, 1, {{56, 3, 7}, {63, 3, 7}}) -- 暂停/继续
  for bar = 0, 7 do
    local mel, arp, bass = {}, {}, {}
    local tri = ARP[bar + 1]
    local patt = {tri[1], tri[2], tri[3], tri[2], tri[1], tri[2], tri[3], tri[2]}
    for i = 1, 8 do
      for _ = 1, 4 do
        mel[#mel + 1] = {MEL[bar + 1][i], 8, 12}
        arp[#arp + 1] = {patt[i], 0, 5}
      end
    end
    local r = BASS_ROOT[bar + 1]
    for _, q in ipairs({r, r + 12, r, r + 12}) do
      for _ = 1, 8 do bass[#bass + 1] = {q, 11, 10} end
    end
    local dr = {} -- 鼓：底鼓 1/3 拍、军鼓 2/4 拍、踩镲后半拍
    dr[1], dr[9] = {28, 11, 12, 3}, {56, 14, 9, 3}
    dr[17], dr[18] = {28, 11, 12, 3}, {22, 11, 9, 3}
    dr[25], dr[26] = {56, 14, 9, 3}, {50, 14, 6}
    for _, hs in ipairs({5, 13, 21, 29}) do dr[hs] = {90, 15, 4} end
    write_sfx(20 + bar, 4, mel, 32)
    write_sfx(32 + bar, 4, arp, 32)
    write_sfx(44 + bar, 4, bass, 32)
    write_sfx(56 + bar, 4, dr, 32)
    local pb = 0x063800 + bar * 16
    u8(pb + 4, 21 + bar) u8(pb + 5, 33 + bar)
    u8(pb + 6, 45 + bar) u8(pb + 7, 57 + bar)
    local fl = 0
    if bar == 0 then fl = 1 end       -- BEGIN：循环起点
    if bar == 7 then fl = fl + 2 end  -- END：回到 BEGIN
    u8(pb + 8, fl)
  end
end

-- ---------------------------------------------------------------- 精灵烘焙

-- 逐像素写 16×16 瓦片：fn(x, y) 返回色号或 nil（0＝透明）
local function bake(id, fn)
  local base = id * 256
  for y = 0, 15 do
    for x = 0, 15 do
      poke(base + y * 16 + x, fn(x + 0.5, y + 0.5) or 0)
    end
  end
end
local function in_rr(x, y, x0, y0, x1, y1, r) -- 圆角矩形内判定
  local cx, cy = mid(x0 + r, x, x1 - r), mid(y0 + r, y, y1 - r)
  local dx, dy = x - cx, y - cy
  return dx * dx + dy * dy <= r * r
end
local function in_poly(px, py, pts) -- 射线法点在多边形内
  local inside, j = false, #pts
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
local function seg_d(px, py, ax, ay, bx, by) -- 点到线段距离
  local dx, dy = bx - ax, by - ay
  local l2, tt = dx * dx + dy * dy, 0
  if l2 > 0 then
    tt = mid(0, ((px - ax) * dx + (py - ay) * dy) / l2, 1)
  end
  local qx, qy = ax + dx * tt, ay + dy * tt
  return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end
local function edge_d(px, py, pts) -- 多边形最小边距
  local best = 1e9
  for i = 1, #pts do
    local a, b = pts[i], pts[i % #pts + 1]
    best = min(best, seg_d(px, py, a[1], a[2], b[1], b[2]))
  end
  return best
end
-- 蛇头（朝右，tile 1）：圆角头颅 + 双眼（瞳孔朝行进方向）+ 鼻孔 + 分叉吐舌
local function head_r_fn(x, y)
  if x > 12.4 then -- 舌头伸向右缘
    local ty = abs(y - 8)
    if (x <= 14 and ty <= 0.8) or (x > 14 and ty >= 0.3 and ty <= 1.7) then return 59 end
  end
  if not in_rr(x, y, 1.2, 2.4, 13.4, 13.6, 5) then
    return in_rr(x, y, 0.4, 1.6, 14.2, 14.4, 5.7) and 37 or nil
  end
  for _, ey in ipairs({4.9, 11.1}) do -- 双眼：暗瞳孔 + 白眼球
    local px, py = x - 10.5, y - ey
    if px * px + py * py <= 1.2 then return 1 end
    local wx, wy = x - 9.7, y - ey
    if wx * wx + wy * wy <= 4.8 then return 7 end
  end
  local n1 = (x - 13) * (x - 13)
  if n1 + (y - 6.6) * (y - 6.6) <= 0.3 then return 37 end -- 鼻孔
  if n1 + (y - 9.4) * (y - 9.4) <= 0.3 then return 37 end
  if (x - 4.5) * (x - 4.5) + (y - 5) * (y - 5) <= 1.4 then return 32 end -- 高光斑
  if y <= 5.2 and x <= 11 then return 33 end -- 顶部受光面
  if y >= 11.6 then return 35 end            -- 下巴暗面
  return 34
end
local function bake_sprites()
  bake(1, head_r_fn)
  bake(2, function(x, y) return head_r_fn(15 - y, x) end) -- 朝上 = 旋转 90°
  -- 体节 A（亮）主 33・外圈 36・菱形纹 32・右下暗 35；体节 B（深）主 34・外圈 37・纹 36・顶反光 33
  local function body_tile(main, rim, dot, sheen, shthr)
    bake(main == 33 and 3 or 4, function(x, y)
      if not in_rr(x, y, 1.8, 1.8, 14.2, 14.2, 4) then
        return in_rr(x, y, 1, 1, 15, 15, 4.7) and rim or nil
      end
      local dx, dy = x - 8, y - 8
      if abs(dx) + abs(dy) <= 2.7 then return dot end
      if dy < -4.6 and abs(dx) < 5.5 then return sheen end
      if dx + dy > shthr then return 35 end
      return main
    end)
  end
  body_tile(33, 36, 32, 32, 5.4)
  body_tile(34, 37, 36, 33, 5.8)
  -- 苹果：果体 58・底暗 59・描边 61・奶油高光 22・果梗 17・绿叶 33/34
  bake(5, function(x, y)
    if abs(x - 7.8) <= 0.8 and y >= 2.2 and y <= 4.6 then return 17 end
    local lx, ly = (x - 11) / 2.1, (y - 3.4) / 1.25
    if lx * lx + ly * ly <= 1 then return (x + y < 13) and 33 or 34 end
    local dx, dy = x - 8, y - 9.8
    local d2 = dx * dx + dy * dy
    if d2 > 31.4 then return d2 <= 40 and 61 or nil end
    if (x - 6.1) * (x - 6.1) + (y - 8.1) * (y - 8.1) <= 1.5 then return 22 end
    if dy > 2.6 then return 59 end
    return 58
  end)
  -- 星果（特殊果实）：五角星 30/31・描边 28・闪光点 7
  local star, big = {}, {}
  for i = 0, 9 do
    local a = -0.25 + i * 0.1
    local rr = (i % 2 == 0) and 7.4 or 3.1
    local rb = (i % 2 == 0) and 8.3 or 4.0
    star[i + 1] = {8 + cos(a) * rr, 8.6 + sin(a) * rr}
    big[i + 1] = {8 + cos(a) * rb, 8.6 + sin(a) * rb}
  end
  bake(6, function(x, y)
    if in_poly(x, y, star) then
      if edge_d(x, y, star) < 0.8 then return 28 end
      if (x - 6) * (x - 6) + (y - 6.5) * (y - 6.5) <= 1.3 then return 7 end
      return (x < 8.5) and 31 or 30
    end
    return in_poly(x, y, big) and 28 or nil
  end)
  -- 障碍砖块：金属面 3・上左亮棱 5・下右暗棱 1・外圈 2・错缝砖纹 + 铆钉
  bake(7, function(x, y)
    if x < 1 or y < 1 or x > 14 or y > 14 then return 2 end
    for _, c in ipairs({{3, 3}, {12, 3}, {3, 12}, {12, 12}}) do
      if (x - c[1]) * (x - c[1]) + (y - c[2]) * (y - c[2]) <= 1.2 then return 5 end
    end
    if x == 1 or y == 1 then return 5 end
    if x == 14 or y == 14 then return 1 end
    if y == 8 then return 2 end
    if (y < 8 and x == 8) or (y > 8 and (x == 4 or x == 12)) then return 2 end
    if x + y == 14 and x >= 9 and x <= 11 then return 4 end -- 划痕
    return 3
  end)
end

-- ---------------------------------------------------------------- 状态

local state, t = "title", 0 -- title | play | pause | dying | over
local mode, spd, sel_row = 1, 2, 1
local body      -- {{x, y, mx, my}, ...} 头在前；mx/my = 最近一步位移方向
local dir, pend -- 当前方向 / 转向缓冲（≤2）
local step_t, step_int, eat_pulse
local food, sfruit
local score, best, eaten, final_len
local combo, combo_t
local new_best, win
local parts, pops, rings
local die_t, death_dir, death_u, over_t, shake
local walls
local music_on, bgm_on
local trail     -- 标题装饰蛇轨迹
local function toggle_music()
  music_on = not music_on
  dset(3, music_on and 0 or 1)
  fflush()
  if music_on then music(0, 400, 0xF0) bgm_on = true
  else music(-1, 400) bgm_on = false end
end

-- ---------------------------------------------------------------- 粒子・飘字・光环

local function burst(px, py, cols, n)
  for _ = 1, n do
    parts[#parts + 1] = {
      x = px + rnd(-4, 4), y = py + rnd(-3, 3),
      vx = rnd(-1.6, 1.6), vy = rnd(-2.8, -0.4),
      c = cols[flr(rnd(#cols)) + 1], life = 14 + flr(rnd(14)),
    }
  end
  while #parts > 200 do table.remove(parts, 1) end
end
local function add_pop(txt, x, y, gold)
  pops[#pops + 1] = {txt = txt, x = flr(x - tw(txt) / 2), y = flr(y - 10), t = 0, gold = gold}
end
local function update_parts()
  for i = #parts, 1, -1 do
    local q = parts[i]
    q.x, q.y = q.x + q.vx, q.y + q.vy
    q.vy = q.vy + 0.18
    q.life = q.life - 1
    if q.life <= 0 or q.y > 262 then table.remove(parts, i) end
  end
end
local function update_pops()
  for i = #pops, 1, -1 do
    pops[i].t = pops[i].t + 1
    if pops[i].t > 42 then table.remove(pops, i) end
  end
end
local function update_rings()
  for i = #rings, 1, -1 do
    rings[i].t = rings[i].t + 1
    if rings[i].t > 16 then table.remove(rings, i) end
  end
end

-- ---------------------------------------------------------------- 食物生成

local function free_cell() -- 随机取一个空闲格（避开蛇身/食物/障碍）
  local occ = {}
  for i = 1, #body do occ[body[i].y * COLS + body[i].x] = true end
  if food then occ[food.y * COLS + food.x] = true end
  if sfruit then occ[sfruit.y * COLS + sfruit.x] = true end
  local free = {}
  for cy = 0, ROWS - 1 do
    for cx = 0, COLS - 1 do
      if not walls[cy][cx] and not occ[cy * COLS + cx] then free[#free + 1] = {cx, cy} end
    end
  end
  if #free == 0 then return nil end
  return free[flr(rnd(#free)) + 1]
end

local function spawn_food()
  local c = free_cell()
  food = c and {x = c[1], y = c[2]} or nil
end
local function spawn_special()
  local c = free_cell()
  sfruit = c and {x = c[1], y = c[2], life = 360} or nil
end

-- ---------------------------------------------------------------- 流程

local function empty_walls()
  local w = {}
  for y = 0, ROWS - 1 do
    w[y] = {}
    for x = 0, COLS - 1 do w[y][x] = false end
  end
  return w
end

local function die()
  state, die_t, death_dir, death_u = "dying", 0, dir, 1
  final_len, shake = #body, 12
  if score > best then
    best, new_best = score, true
    dset(BEST_SLOT[mode], best)
    fflush()
  end
  if bgm_on then music(-1, 300) bgm_on = false end
  sfx(13, 2)
end
local function start_game()
  sfx(1, 0)
  state, score, eaten = "play", 0, 0
  combo, combo_t, new_best, win = 0, 0, false, false
  best = dget(BEST_SLOT[mode])
  body = {}
  for i = 0, 2 do body[i + 1] = {x = 6 - i, y = 2, mx = 0, my = 0} end
  dir, pend = 1, {}
  step_t, step_int, eat_pulse = 0, SPD_INT[spd], 0
  death_u, die_t, over_t, shake, final_len = 1, 0, 0, 0, 3
  parts, pops, rings = {}, {}, {}
  walls = empty_walls()
  if mode == 3 then
    for _, o in ipairs(OBS) do walls[o[2]][o[1]] = true end
  end
  food, sfruit = nil, nil
  spawn_food()
  if music_on and not bgm_on then music(0, 500, 0xF0) bgm_on = true end
end
local function to_title()
  state, trail = "title", {}
  if music_on and not bgm_on then music(0, 500, 0xF0) bgm_on = true end
end
local function adjust(d) -- ←→ 调整当前行（模式或速度，循环切换）
  if sel_row == 1 then
    mode = (mode + d + 2) % 3 + 1
    best = dget(BEST_SLOT[mode])
  else
    spd = (spd + d + 2) % 3 + 1
  end
  sfx(0, 0)
end
local function udir(o, n, sz) -- 单位位移：o→n 相邻格（含环绕）
  local d = n - o
  if d == 1 or d == -(sz - 1) then return 1 end
  if d == -1 or d == sz - 1 then return -1 end
  return 0
end
local function step_snake()
  if #pend > 0 then dir = table.remove(pend, 1) end -- 应用队首转向（入队时已校验轴向）
  local h = body[1]
  local nx, ny = h.x + DX[dir], h.y + DY[dir]
  if mode == 2 then
    nx, ny = (nx + COLS) % COLS, (ny + ROWS) % ROWS
  elseif nx < 0 or nx >= COLS or ny < 0 or ny >= ROWS then
    return die()
  end
  if walls[ny][nx] then return die() end
  local eating = food ~= nil and food.x == nx and food.y == ny
  local star = sfruit ~= nil and sfruit.x == nx and sfruit.y == ny
  local lim = eating and #body or #body - 1 -- 不进食时尾节将让位，可除外
  for i = 1, lim do
    if body[i].x == nx and body[i].y == ny then return die() end
  end
  if eating then -- 先复制尾节再整体前移 = 本步不缩尾（长 1 节）
    local tl = body[#body]
    table.insert(body, {x = tl.x, y = tl.y, mx = 0, my = 0})
  end
  local px, py = h.x, h.y
  for i = 1, #body do -- 各节滑入前一节旧位置，记录位移方向供插值
    local s = body[i]
    local ox, oy = s.x, s.y
    if i == 1 then s.x, s.y = nx, ny else s.x, s.y = px, py end
    s.mx, s.my = udir(ox, s.x, COLS), udir(oy, s.y, ROWS)
    px, py = ox, oy
  end
  local hx, hy = FX + nx * CELL + 8, FY + ny * CELL + 8
  if eating then
    eaten, score = eaten + 1, score + 10
    combo, combo_t, eat_pulse = combo + 1, 0, 8
    sfx(3 + min(combo - 1, 7), 0)
    burst(hx, hy, {58, 59, 34, 33}, 5)
    add_pop("+10", hx, hy, false)
    food = nil
    spawn_food()
    if not food then -- 填满全场：完美通关
      state, over_t, win, final_len = "over", 40, true, #body
      if bgm_on then music(-1, 300) bgm_on = false end
      return
    end
    if eaten % 5 == 0 and not sfruit then spawn_special() end
    step_int = max(SPD_INT[spd] - 4, SPD_INT[spd] - eaten * 0.25) -- 加速曲线
  end
  if star then -- 星果：+50 分 + 金色爆发 + 扩散环
    score = score + 50
    sfx(11, 1)
    burst(hx, hy, {31, 30, 29, 7}, 16)
    add_pop("+50", hx, hy, true)
    rings[#rings + 1] = {x = hx, y = hy, t = 0}
    sfruit = nil
  end
end
local function update_play()
  for k = 0, 3 do -- 转向输入：两级缓冲，先按先转；入队即按生效方向校验轴向
    if btnp(k) and #pend < 2 then -- 同轴（含 180° 回头）当场拒收，不占缓冲位
      local d = KEY2DIR[k]
      local eff = pend[#pend] or dir
      if d % 2 ~= eff % 2 then
        pend[#pend + 1] = d
        sfx(2, 0) -- 轻响与头部预转向（draw_snake）随按键即刻反馈
      end
    end
  end
  combo_t = combo_t + 1
  if combo_t > 360 then combo = 0 end -- 连吃窗口 6 秒
  if sfruit then
    sfruit.life = sfruit.life - 1
    if sfruit.life <= 0 then sfruit = nil sfx(12, 1) end
  end
  step_t = step_t + 1
  if step_t >= step_int then step_t = 0 step_snake() end
end
-- 死亡演出：闪红 + 头部撞击回弹后，身体自尾向头逐节碎裂
local function update_dying()
  die_t = die_t + 1
  if die_t > 16 then
    local iv = #body > 40 and 1 or 2 -- 长蛇加速碎裂
    if die_t % iv == 0 and #body > 1 then
      local s = table.remove(body)
      burst(FX + (s.x - s.mx * (1 - death_u)) * CELL + 8,
        FY + (s.y - s.my * (1 - death_u)) * CELL + 8, {33, 34, 35, 32}, 4)
    end
  end
  if #body <= 1 and die_t > 24 then -- 头部最后爆裂
    local hx, hy = FX + body[1].x * CELL + 8, FY + body[1].y * CELL + 8
    burst(hx, hy, {59, 58, 57, 7}, 14)
    rings[#rings + 1] = {x = hx, y = hy, t = 0}
    body, state, over_t = {}, "over", 0
  end
end
local function update_over()
  over_t = over_t + 1
  if over_t == 36 and new_best then sfx(14, 2) end
  if over_t > 40 then
    if btnp(4) then start_game()
    elseif btnp(11) then to_title() end
  end
end
local function update_title()
  -- 装饰蛇沿利萨茹轨迹巡游（节距 ≈ 10px 保证体节相连）
  trail[#trail + 1] = {128 + cos(t * 0.006) * 84, 130 + sin(t * 0.012) * 54}
  if #trail > 90 then table.remove(trail, 1) end
  if btnp(2) or btnp(3) then sel_row = 3 - sel_row sfx(0, 0)
  elseif btnp(0) then adjust(-1)
  elseif btnp(1) then adjust(1) end
  if btnp(10) then toggle_music() end
  if btnp(4) then start_game() end
end

-- ---------------------------------------------------------------- 绘制

local function blit(id, x, y, w, h, fh, fv)
  -- 画一段 16×16 精灵；穿墙模式下越界一侧补画一份，保持视觉连续
  local sx, sy = (id % 16) * 16, flr(id / 16) * 16
  sspr(sx, sy, 16, 16, x, y, w, h, fh, fv)
  if state ~= "title" and mode == 2 then
    if x < FX then sspr(sx, sy, 16, 16, x + FW, y, w, h, fh, fv)
    elseif x > FX + FW - w then sspr(sx, sy, 16, 16, x - FW, y, w, h, fh, fv) end
    if y < FY then sspr(sx, sy, 16, 16, x, y + FH, w, h, fh, fv)
    elseif y > FY + FH - h then sspr(sx, sy, 16, 16, x, y - FH, w, h, fh, fv) end
  end
end
local function draw_field()
  rectfill(FX, FY, FW, FH, 15)
  for cy = 0, ROWS - 1 do
    for cx = 0, COLS - 1 do
      if (cx + cy) % 2 == 1 then
        rectfill(FX + cx * CELL, FY + cy * CELL, CELL, CELL, 14)
      end
    end
  end
  if mode == 2 then -- 穿墙：四边流动虚线提示环绕
    local off = flr(t / 2) % 8
    for xx = FX - off, FX + FW, 8 do
      rectfill(xx, FY, 5, 2, 43) rectfill(xx, FY + FH - 2, 5, 2, 43)
    end
    for yy = FY - off, FY + FH, 8 do
      rectfill(FX, yy, 2, 5, 43) rectfill(FX + FW - 2, yy, 2, 5, 43)
    end
  else -- 经典/障碍：致命砖墙边框 + 铆钉
    rectfill(FX, FY, FW, 2, 61) rectfill(FX, FY + FH - 2, FW, 2, 61)
    rectfill(FX, FY, 2, FH, 61) rectfill(FX + FW - 2, FY, 2, FH, 61)
    for xx = FX + 8, FX + FW - 8, 24 do
      pset(xx, FY + 1, 59) pset(xx, FY + FH - 2, 59)
    end
    for yy = FY + 8, FY + FH - 8, 24 do
      pset(FX + 1, yy, 59) pset(FX + FW - 2, yy, 59)
    end
  end
  if mode == 3 then
    for cy = 0, ROWS - 1 do
      for cx = 0, COLS - 1 do
        if walls[cy][cx] then blit(7, FX + cx * CELL, FY + cy * CELL, 16, 16) end
      end
    end
  end
end
local function draw_food()
  if not food then return end
  blit(5, FX + food.x * CELL, FY + food.y * CELL + flr(sin(t * 0.09) * 1.5), 16, 16)
end
local function draw_special()
  if sfruit and (sfruit.life >= 120 or flr(t / 4) % 2 == 1) then
    local x, y = FX + sfruit.x * CELL + 8, FY + sfruit.y * CELL + 8
    circ(x, y, 11 + sin(t * 0.07) * 1.6, 28) -- 光环
    circ(x, y, 8.6 + sin(t * 0.07) * 1.2, 29)
    local w = flr(16 * (1 + 0.1 * sin(t * 0.09))) -- 呼吸缩放
    blit(6, x - w / 2, y - w / 2, w, w)
  end
  for i = 1, #rings do
    local r = rings[i]
    circ(r.x, r.y, 3 + r.t * 1.5, r.t < 8 and 31 or 30)
  end
end
local function draw_snake()
  if #body == 0 then return end
  local u = (state == "play") and step_t / step_int or death_u
  local fdir = dir -- 头部朝向：已缓冲的下一步转向即刻预转向，消除等待手感
  if (state == "play" or state == "pause") and pend[1] then fdir = pend[1] end
  local cs = {} -- 各节插值中心；先桥接后贴图，使蛇身连续（含拐角）
  for i = 1, #body do
    local s = body[i]
    cs[i] = {FX + (s.x - s.mx * (1 - u)) * CELL + 8, FY + (s.y - s.my * (1 - u)) * CELL + 8}
  end
  for i = 2, #body do
    local a, b = cs[i], cs[i - 1]
    if abs(b[1] - a[1]) <= CELL and abs(b[2] - a[2]) <= CELL then -- 穿墙断口跳过
      rectfill(min(a[1], b[1]) - 6, min(a[2], b[2]) - 6,
        abs(b[1] - a[1]) + 12, abs(b[2] - a[2]) + 12, i % 2 == 0 and 33 or 34)
    end
  end
  for i = #body, 1, -1 do
    local x, y = cs[i][1] - 8, cs[i][2] - 8
    if i == 1 then
      local k = 1
      if eat_pulse > 0 then k = 1 + 0.22 * eat_pulse / 8 end -- 吃食头部放大
      if state == "dying" and die_t < 12 then -- 撞击回弹
        local b = sin(die_t / 12 * 0.5) * 3
        x, y = x + DX[death_dir] * b, y + DY[death_dir] * b
      end
      local w = flr(16 * k)
      x, y = x - (w - 16) / 2, y - (w - 16) / 2
      if fdir == 1 then blit(1, x, y, w, w)          -- 四向：右/左 = 右翻转
      elseif fdir == 3 then blit(1, x, y, w, w, true)
      elseif fdir == 2 then blit(2, x, y, w, w)      -- 上/下 = 上翻转
      else blit(2, x, y, w, w, false, true) end
    else
      blit(i % 2 == 0 and 3 or 4, x, y, 16, 16) -- 明暗相间花纹
    end
  end
end
local function draw_parts()
  for i = 1, #parts do
    rectfill(flr(parts[i].x), flr(parts[i].y), 2, 2, parts[i].c)
  end
end
local function draw_pops()
  for i = 1, #pops do
    local p = pops[i]
    local y = flr(p.y - p.t * 0.5)
    print(p.txt, p.x + 1, y + 1, 1)
    print(p.txt, p.x, y, p.gold and (p.t < 16 and 31 or 30) or (p.t < 14 and 33 or 34))
  end
end

local function draw_hud()
  rectfill(0, 0, 256, 16, 2)
  line(0, 15, 255, 15, 4)
  print("分", 2, 0, 6)
  local s = fmt(score)
  print(s, 66 - #s * 8, 0, 7)
  print("高", 70, 0, 6)
  s = fmt(best)
  print(s, 134 - #s * 8, 0, 30)
  print("长", 138, 0, 6)
  s = fmt(#body)
  print(s, 190 - #s * 8, 0, 33)
  print("速", 194, 0, 6)
  print(SPD_NAME[spd], 210, 0, SPD_COL[spd])
  if music_on then print("♪", 244, 0, 30) end
end

local function draw_bottom()
  rectfill(0, 240, 256, 16, 2)
  local hints = {"⬅⬆⬇➡ 转向　Ⓑ 暂停", "Select 音乐开关", "★ 特殊果实 +50", "速度随长度提升"}
  local s = hints[flr(t / 150) % #hints + 1]
  print(s, (256 - tw(s)) / 2, 240, 6)
end
local function draw_pause()
  fillp(0xa5a5)
  rectfill(0, 0, 256, 256, 15 * 256 + 0)
  fillp()
  rectfill(56, 92, 144, 76, 15)
  rect(56, 92, 144, 76, 37)
  local s = "暂停"
  print(s, (256 - tw(s)) / 2 + 1, 103, 1)
  print(s, (256 - tw(s)) / 2, 102, 7)
  local hints = {"Ⓑ 或 Start 继续", "Select 音乐开关"}
  for i = 1, 2 do print(hints[i], (256 - tw(hints[i])) / 2, 128 + (i - 1) * 18, 6) end
end
local function draw_over()
  fillp(0x8421)
  rectfill(0, 0, 256, 256, 15 * 256 + 0)
  fillp()
  local bx, by, bw, bh = 40, 54, 176, 150
  rectfill(bx, by, bw, bh, 15)
  rect(bx, by, bw, bh, 37)
  rectfill(bx + 2, by + 2, bw - 4, 1, 33)
  rectfill(bx + 2, by + bh - 3, bw - 4, 1, 36)
  local function row(txt, y, c)
    print(txt, (256 - tw(txt)) / 2, y, c)
  end
  local s = win and "完美通关！" or "游戏结束"
  print(s, (256 - tw(s)) / 2 + 1, 65, 1)
  row(s, 64, 63)
  row("模式 " .. MODES[mode] .. "　速度 " .. SPD_NAME[spd], 88, 6)
  row("分数 " .. fmt(score), 108, 7)
  row("长度 " .. fmt(final_len), 126, 33)
  row("最高 " .. fmt(best), 144, 30)
  if new_best and flr(t / 6) % 2 == 0 then row("★ 新纪录 ★", 164, 31) end
  if flr(t / 16) % 2 == 0 then row("Ⓐ 再来一局", 184, 7) end
  row("Start 回标题", 204, 6)
end
local function draw_title_snake()
  local n = #trail
  if n < 70 then return end
  for i = 16, 1, -1 do
    local idx = n - (i - 1) * 3
    local p = trail[idx]
    local x, y = flr(p[1]) - 8, flr(p[2]) - 8
    if i == 1 then -- 头按最近位移取向
      local q = trail[max(1, idx - 3)]
      local dx, dy = p[1] - q[1], p[2] - q[2]
      if abs(dx) >= abs(dy) then blit(1, x, y, 16, 16, dx < 0)
      else blit(2, x, y, 16, 16, false, dy > 0) end
    else
      blit(i % 2 == 0 and 3 or 4, x, y, 16, 16)
    end
  end
end
local function draw_title()
  cls(15)
  fillp(0x0842)
  rectfill(0, 0, 256, 256, 13 * 256 + 15)
  fillp()
  draw_title_snake()
  rectfill(52, 28, 152, 48, 51) -- 标题板（斜面匾）
  rectfill(52, 28, 152, 2, 53) rectfill(52, 28, 2, 48, 53)
  rectfill(52, 74, 152, 2, 50) rectfill(202, 28, 2, 48, 50)
  local chars, cols = {"贪", "吃", "蛇"}, {33, 30, 55}
  for i = 1, 3 do
    local x, y = 94 + (i - 1) * 26, 38 + flr(sin(t * 0.05 + i * 0.14) * 3)
    print(chars[i], x + 2, y + 2, 1)
    print(chars[i], x, y, cols[i])
  end
  local s = "SNAKE ・ FC-16"
  print(s, (256 - tw(s)) / 2, 84, 5)
  for r = 1, 2 do -- 设置行：模式 / 速度（↑↓ 选行，←→ 调整）
    local y, act = 104 + (r - 1) * 28, sel_row == r
    if act then
      rectfill(60, y - 4, 136, 24, 13) rect(60, y - 4, 136, 24, 42)
    end
    print(r == 1 and "模式" or "速度", 68, y, act and 7 or 6)
    local val = r == 1 and MODES[mode] or SPD_NAME[spd]
    print("◀", 138, y, act and 43 or 10)
    print(val, 158, y, act and 31 or 6)
    print("▶", 182, y, act and 43 or 10)
  end
  s = "纪录 经 " .. fmt(dget(0)) .. "　穿 " .. fmt(dget(1)) .. "　障 " .. fmt(dget(2))
  print(s, (256 - tw(s)) / 2, 166, 30)
  if flr(t / 20) % 2 == 0 then
    s = "按 Ⓐ 开始游戏"
    print(s, (256 - tw(s)) / 2 + 1, 191, 1)
    print(s, (256 - tw(s)) / 2, 190, 7)
  end
  local hints = {"⬅⬆⬇➡ 选择　Ⓐ 开始", "Select 音乐开关"}
  for i = 1, 2 do print(hints[i], (256 - tw(hints[i])) / 2, 214 + (i - 1) * 18, 6) end
  print("♪", 242, 2, music_on and 30 or 10)
  print("FrostMiKu ・ FC-16", (256 - tw("FrostMiKu ・ FC-16")) / 2, 240, 10)
end

-- ---------------------------------------------------------------- 生命周期

function _init()
  bake_sprites()
  init_audio()
  music_on = dget(3) == 0 -- 槽位 3：0 = 开（默认）
  bgm_on, best = false, dget(0)
  trail, parts, pops, rings = {}, {}, {}, {}
  shake, eat_pulse, death_u, die_t, over_t = 0, 0, 1, 0, 0
  if music_on then music(0, 500, 0xF0) bgm_on = true end
end
function _update()
  t = t + 1
  update_parts()
  update_pops()
  update_rings()
  if eat_pulse > 0 then eat_pulse = eat_pulse - 1 end
  if shake > 0 then shake = shake - 1 end
  if state == "title" then
    update_title()
  elseif state == "play" then
    if btnp(10) then toggle_music() end
    if btnp(5) or btnp(11) then state = "pause" sfx(15, 0)
    else update_play() end
  elseif state == "pause" then
    if btnp(5) or btnp(11) or btnp(4) then state = "play" sfx(15, 0)
    elseif btnp(10) then toggle_music() end
  elseif state == "dying" then
    update_dying()
  elseif state == "over" then
    update_over()
  end
end
function _draw()
  pal()
  camera(0, 0)
  if state == "title" then
    draw_title()
    return
  end
  if shake > 0 then -- 死亡震屏（与帧号绑定，保持确定性）
    local a = min(5, shake * 0.6)
    camera(flr(sin(t * 0.11) * a), flr(cos(t * 0.17) * a * 0.6))
  end
  -- 死亡红闪之一：显示期映射把棋盘底色整体染红（帧缓冲不变）
  local flash = state == "dying" and die_t < 24 and flr(die_t / 4) % 2 == 0
  if flash then
    pal(15, 61, 1)
    pal(14, 60, 1)
  end
  draw_field()
  draw_food()
  draw_special()
  if flash then -- 死亡红闪之二：绘制期映射把蛇身绿系映为红系
    pal(32, 57) pal(33, 58) pal(34, 59)
    pal(35, 60) pal(36, 61) pal(37, 62)
  end
  draw_snake()
  pal()
  draw_parts()
  draw_pops()
  draw_hud()
  draw_bottom()
  camera(0, 0)
  if state == "pause" then draw_pause() end
  if state == "over" and over_t > 30 then draw_over() end
end