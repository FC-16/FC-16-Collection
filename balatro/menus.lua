-- 结束、选项、主菜单与开局设置屏
-- ============================================================ 结束
B36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
function seed_str(s)
  if s == 0 then return "0" end
  local out = ""
  while s > 0 do
    out = B36:sub(s % 36 + 1, s % 36 + 1) .. out
    s = math.floor(s / 36)
  end
  return out
end
function up_over()
  if tt < sp(30) then return end
  OV.sel = OV.sel or 1
  if dpr("left") then OV.sel = (OV.sel - 2) % 2 + 1 sfx(0, CH_UI) end
  if dpr("right") then OV.sel = OV.sel % 2 + 1 sfx(0, CH_UI) end
  if kA() then
    RUN.reuse = OV.win
    if OV.sel == 1 then
      st, tt = "setup", 0
      SU = { row = 1, deck = RUN.deck or 0, seed = OV.win and seed_str(RUN.seed) or "" }
          music_stop(300)
    else
      to_menu()
    end
  end
end
function dn_over()
  cls(37)
  ptext(OV.win and "胜  利" or "失  败", 40, OV.win and CL.sky or CL.red, 0, 256, 2)
  local kindn = HANDS[G.bestkind] and HANDS[G.bestkind][1] or "无"
  print("最佳单次得分  " .. fmt(G.best), 64, 90, CL.frost)
  print("最常打出牌型  " .. kindn, 64, 106, CL.frost)
  print("本局种子      " .. seed_str(RUN.seed), 64, 122, CL.frost)
  button(64, 150, 56, 18, "再来一局", CL.fd, OV.sel == 1, true)
  button(136, 150, 56, 18, "主菜单", CL.hole, OV.sel == 2, true)
  hint({ { "a", "确认" } })
end

-- ============================================================ 选项
function up_options()
  if dpr("up") then OP.sel = (OP.sel - 2) % 2 + 1 sfx(0, CH_UI) end
  if dpr("down") then OP.sel = OP.sel % 2 + 1 sfx(0, CH_UI) end
  if OP.sel == 1 then
    if dpr("left") then OPT.speed = (OPT.speed - 2) % 4 + 1 sfx(0, CH_UI) end
    if dpr("right") then OPT.speed = OPT.speed % 4 + 1 sfx(0, CH_UI) end
  end
  if kA() then
    if OP.sel == 2 then
      save_speed()
      sfx(1, CH_UI)
      to_menu()
    end
  end
  if kB() then to_menu() end
end
function dn_options()
  cls(37)
  ptext("选  项", 36, 7, 0, 256, 2)
  local rows = { "游戏速度", "返回" }
  for i, s in ipairs(rows) do
    local y = 100 + i * 28
    if OP.sel == i then ptext("▶ " .. s, y, 7, 48, 208) else ptext(s, y, CL.g2, 48, 208) end
  end
  print("< " .. OPT.speed .. " >", 160, 128, 7)
  print(OPT.speed == 1 and "原速" or (OPT.speed == 2 and "稍快" or (OPT.speed == 3 and "快速" or "极速")), 160, 142, CL.g2)
  hint({ { "pad", "选择" }, { "a", "保存" }, { "b", "取消" } })
end

-- ============================================================ 主菜单 / 开局设置
function to_menu()
  st, tt = "menu", 0
  menu = { i = 1 }
end
function up_menu()
  local items = has_run() and 3 or 2
  if dpr("down") then menu.i = menu.i % items + 1 sfx(0, CH_UI) end
  if dpr("up") then menu.i = (menu.i - 2) % items + 1 sfx(0, CH_UI) end
  if kA() then
    local has_save = has_run()
    if menu.i == 1 then
      st, tt = "setup", 0
      SU = { row = 1, deck = RUN.deck or 0, seed = "" }
          sfx(1, CH_UI)
    elseif menu.i == 2 and has_save then
      if load_run() then sfx(1, CH_UI) else buzz() end
    else
      st, tt = "options", 0
      OP = { sel = 1 }
          sfx(1, CH_UI)
    end
  end
end
function dn_menu()
  cls(37)
  local title = "BALATRO"
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    print(title, 128 - tw2(title) / 2 + d[1], 36 + d[2], CL.red, 2)
  end
  print(title, 128 - tw2(title) / 2, 36, 7, 2)
  ptext("小丑牌", 66, CL.gold)
  local has_save = has_run()
  local items = has_save and { "新的对局", "继续挑战", "选项" } or { "新的对局", "选项" }
  for i, s in ipairs(items) do
    local y = 96 + i * 22
    if menu.i == i then
      button(96, y - 3, 64, 18, s, CL.dred, true, true)
    else
      ptext(s, y, CL.g2, 96, 160)
    end
  end
end
function tw2(s) return textw(s) * 2 end

SU = nil
-- 种子键盘：0..35 为字符（每行 10 个，第 4 行仅 0..5 列），36 随机、37 退格；
-- 导航按可见格子的行列移动，绝不落到画不出来的格子上
local function kb_cell(k)
  if k >= 36 then return 4, (k == 36 and 0 or 3) end
  return math.floor(k / 10), k % 10
end
local function kb_goto(r, c)
  if r == 4 then SU.k = c >= 3 and 37 or 36
  else SU.k = r * 10 + MIN(c, r == 3 and 5 or 9) end
end
-- dir 0 左 / 1 右 / 2 上 / 3 下；顶行向上返回 nil 表示退出键盘，false 表示原地不动
local function kb_move(dir)
  local r, c = kb_cell(SU.k)
  if dir == 0 or dir == 1 then
    if r == 4 then SU.k = SU.k == 36 and 37 or 36
    else kb_goto(r, (c + (dir == 0 and -1 or 1)) % (r == 3 and 6 or 10)) end
    return true
  elseif dir == 2 then
    if r == 0 then return nil end
    kb_goto(r - 1, c)
    return true
  elseif r < 4 then
    kb_goto(r + 1, c)
    return true
  end
  return false
end
function up_setup()
  if SU.k then                          -- 键盘编辑：A 键入，B/顶行向上完成并回种子行
    local function step(dir)
      local moved = kb_move(dir)
      if moved == nil then
        SU.k = nil                      -- 顶行向上：完成编辑
        sfx(2, CH_UI)
      elseif moved then
        sfx(0, CH_UI)
      end
    end
    if dpr("left") then step(0) end
    if dpr("right") then step(1) end
    if dpr("up") then step(2) end
    if dpr("down") then step(3) end
    if kA() then
      if SU.k == 36 then
        SU.seed = seed_str(math.floor(rnd(2176782336))):sub(1, 6)
      elseif SU.k == 37 then
        SU.seed = SU.seed:sub(1, #SU.seed - 1)
      elseif #SU.seed < 6 then
        SU.seed = SU.seed .. B36:sub(SU.k + 1, SU.k + 1)
      end
      sfx(0, CH_UI)
    end
    if kB() then SU.k = nil sfx(2, CH_UI) end
    return
  end
  -- 表单三行：1 牌组 / 2 种子 / 3 开始，上下循环换行
  if dpr("up") then SU.row = (SU.row + 1) % 3 + 1 sfx(0, CH_UI) end
  if dpr("down") then SU.row = SU.row % 3 + 1 sfx(0, CH_UI) end
  if SU.row == 1 then
    if dpr("left") then SU.deck = (SU.deck + 5) % 6 sfx(0, CH_UI) end
    if dpr("right") then SU.deck = (SU.deck + 1) % 6 sfx(0, CH_UI) end
  end
  if kA() then
    if SU.row == 1 then                 -- 确认 = 换下一副牌组
      SU.deck = (SU.deck + 1) % 6
      sfx(0, CH_UI)
    elseif SU.row == 2 then             -- 打开种子键盘
      SU.k = 0
      sfx(1, CH_UI)
    else
      local seed = 0
      for i = 1, #SU.seed do
        local ch = SU.seed:sub(i, i)
        local p = B36:find(ch, 1, true)
        if p then seed = seed * 36 + p - 1 end
      end
      if seed == 0 then seed = math.floor(rnd(4294967295)) + 1 end
      RUN.deck = SU.deck
      new_run(seed)
    end
  end
  if kB() then to_menu() end
end
function dn_setup()
  cls(37)
  -- 主菜单已分流"新的对局/继续挑战"；本屏为三行表单：牌组 / 种子 / 开始
  local editing = SU.k ~= nil
  -- 行 1 牌组：左牌背，右名称与分页；说明独占整行
  spr(band_tile(T_BACK, SU.deck), 48, 12, 2, 2)
  rect(47, 11, 34, 34, SU.row == 1 and 7 or CL.d3)
  ptext(DECKS[SU.deck + 1], 16, SU.row == 1 and 7 or CL.g1, 100, 240)
  ptext("◀ " .. (SU.deck + 1) .. "/6 ▶", 32, SU.row == 1 and 7 or CL.g2, 100, 240)
  printw(DECK_D[SU.deck + 1], 48, 56, CL.g2, 192)
  -- 行 2 种子：编辑中或聚焦时描白框
  rect(44, 88, 172, 20, (SU.row == 2 or editing) and 7 or CL.d3)
  print("种子(可选): " .. (SU.seed == "" and "随机" or SU.seed), 52, 92,
    SU.row == 2 and 7 or CL.cur)
  -- 键盘常驻（种子输入的可视化入口）；光标仅编辑时显示
  do
    local k = SU.k
    for r = 0, 3 do
      for c = 0, 9 do
        local idx = r * 10 + c
        if idx <= 35 then
          local x, y = 48 + c * 17, 120 + r * 16
          local ch = B36:sub(idx + 1, idx + 1)
          if k == idx then rectfill(x - 2, y - 2, 14, 14, 7) print(ch, x + 1, y, 0) else print(ch, x + 1, y, CL.g2) end
        end
      end
    end
    local lx, ly = 48, 120 + 4 * 16
    if k == 36 then rectfill(lx - 2, ly - 2, 40, 14, 7) print("随机", lx + 2, ly, 0) else print("随机", lx + 2, ly, CL.g2) end
    if k == 37 then rectfill(lx + 56 - 2, ly - 2, 40, 14, 7) print("退格", lx + 58, ly, 0) else print("退格", lx + 58, ly, CL.g2) end
  end
  -- 行 3 开始
  button(96, 208, 64, 18, "开始", CL.fd, SU.row == 3 and not editing, true)
  hint(editing
    and { { "pad", "移动" }, { "a", "键入" }, { "b", "完成" } }
    or { { "pad", "移动" },
      { "a", SU.row == 2 and "编辑" or (SU.row == 3 and "开始" or "换牌组") },
      { "b", "返回" } })
end
