-- 对局屏：输入、左栏与主区绘制、结算面板
-- ============================================================ 对局：输入
function seln()
  local n = 0
  for _, c in ipairs(DH) do if c.sel then n = n + 1 end end
  return n
end
function deselect_all()
  for _, c in ipairs(DH) do c.sel = nil end
  sfx(2, CH_UI)
end
function swap_hand(a, b)
  if a >= 1 and a <= #DH and b >= 1 and b <= #DH then
    DH[a], DH[b] = DH[b], DH[a]
    layout_hand()
    sfx(3, CH_UI)
  end
end
function swap_joker(a, b)
  if a >= 1 and a <= #G.jk and b >= 1 and b <= #G.jk then
    G.jk[a], G.jk[b] = G.jk[b], G.jk[a]
    sfx(3, CH_UI)
  end
end
function sell_joker(i)
  local o = G.jk[i]
  if not o then return end
  local v = math.floor(MAX(1, JOKERS[o.id + 1].v / 2))
  G.money = G.money + v
  deli(G.jk, i)
  -- 浮字跟随该小丑的实际屏幕位置（对局行在 y≈6、商店行在 y=140）
  if o.px then toast("$" .. v, o.px + 16, o.py + 34, CL.gold) end
  sfx(24, CH_UI)
  if PS.row == 0 and PS.cur > #G.jk then
    PS.cur = MAX(1, #G.jk)
    if #G.jk == 0 then PS.row, PS.cur = 1, MIN(PS.cur, #DH) end   -- 小丑卖光回手牌行
  end
end
function joker_x(i, n, cx, aw)   -- 小丑行第 i / n 张的左边缘：以 cx 为中线，步进≤34 并按可用宽度 aw 收敛
  local g = n > 1 and MIN(34, math.floor(((aw or 176) - 32) / (n - 1))) or 0
  return cx - 16 + math.floor((i - (n + 1) / 2) * g)
end

function up_round()
  if PS.ph ~= "input" then return end
  -- 每帧每方向只解析一次（dpr 在同帧内不重复派发）
  local dl, dr = dpr("left"), dpr("right")
  local du, dd = dpr("up"), dpr("down")
  local held = btn("a")
  if btnp("a") then PS.ah, PS.used = 0, nil end   -- 阶段内新按下：这次点按从头计
  if held and PS.ah then
    PS.ah = PS.ah + 1
    -- 按住 A：方向参与即交换（重复节奏由 dpr 控制），此时方向不再移动光标
    if dl ~= dr then
      local t = PS.cur + (dl and -1 or 1)
      local n = PS.row == 1 and #DH or #G.jk
      if t >= 1 and t <= n then
        if PS.row == 1 then swap_hand(PS.cur, t) else swap_joker(PS.cur, t) end
        PS.cur = t
      end
      PS.used = true
    end
  elseif not held then
    if PS.ah and not PS.used then   -- 纯点按 A：松开时判定选牌，按住时长不限
      if PS.row == 1 then
        local c = DH[PS.cur]
        if c then
          if c.sel then c.sel = nil sfx(2, CH_UI)
          elseif seln() < 5 then c.sel = true sfx(1, CH_UI) else buzz() end
        end
      end
    end
    PS.ah, PS.used = nil, nil
  end
  -- 行切换：手牌 ↔ 小丑（无小丑时不进小丑行）
  if du and PS.row == 1 and #G.jk > 0 then
    PS.row, PS.cur = 0, 1
    sfx(0, CH_UI)
  end
  if dd and PS.row == 0 then
    PS.row, PS.cur = 1, MIN(PS.cur, #DH)
    sfx(0, CH_UI)
  end
  -- 行内移动（按住 A 时方向专用于交换）
  if not held then
    if PS.row == 1 then
      if dl then PS.cur = (PS.cur - 2) % #DH + 1 sfx(0, CH_UI) end
      if dr then PS.cur = PS.cur % #DH + 1 sfx(0, CH_UI) end
    elseif PS.row == 0 then
      if dl then PS.cur = (PS.cur - 2) % #G.jk + 1 sfx(0, CH_UI) end
      if dr then PS.cur = PS.cur % #G.jk + 1 sfx(0, CH_UI) end
    end
  end
  -- 肩键 / 扳机（GBA：L=出牌 或 卖小丑，R=弃牌；排序移到扳机）
  if kL() then
    if PS.row == 0 then sell_joker(PS.cur)
    elseif G.hands > 0 and seln() > 0 then play_selected()
    else buzz() end
    return
  end
  if kR() then
    if G.discards > 0 and seln() > 0 then do_discard() else buzz() end
    return
  end
  if kLTp() then set_sort(0) end
  if kRTp() then set_sort(1) end
  if kB() then
    if seln() > 0 then deselect_all() elseif PS.row ~= 1 then PS.row, PS.cur = 1, MIN(PS.cur, #DH) end
  end
end

function tick_round()
  for _, c in ipairs(DH) do
    c.ap = MAX(0, (c.ap or 0) - 1)
    c.x = c.x + (c.tx - c.x) * 0.35
    c.y = c.y + (c.ty - c.y) * 0.35
    if c.flip and c.flip > 0 then c.flip = c.flip - 1 end
    if ABS(c.tx - c.x) < 0.5 then c.x = c.tx end
  end
  for _, c in ipairs(DS) do
    if c.de > 0 then c.de = c.de - 1
    else
      c.x = c.x + (c.px - c.x) * 0.3
      c.y = c.y + (c.py - c.y) * 0.3
    end
  end
end

function up_round_score()
  tick_round()
  local h = HELO
  if not h then return end
  step_score()
  if h.ph == "out" then
    h.t = h.t + 1
    for _, c in ipairs(DS) do c.x = c.x + 6 end
    if h.t >= sp(24) then
      DS = {}
      G.hplay[EVN.k] = G.hplay[EVN.k] + 1
      if h.fin > G.best then G.best, G.bestkind = h.fin, EVN.k end
      local req = blind_req(G.blind - 1)
      if G.score >= req then
        round_over()
      elseif G.hands == 0 then
        game_over(false)
      else
        draw_cards(dmod().hsize - #DH)
        PS.ph, PS.t = "input", 0
      end
      HELO = nil
    end
  end
end


-- ============================================================ 对局：绘制
function dn_panel()
  rectfill(0, 0, 80, 240, CL.panel)
  line(80, 0, 80, 240, CL.dusk)
  local b = G.blind
  -- 盲注：图标在左、名称在右
  draw_blind(b >= 3 and G.boss or (b - 1), 4, 4)
  ptext(blind_name(b - 1), 14, 7, 40, 76)
  print("目标 " .. fmt(blind_req(b - 1)), 6, 44, CL.red)
  print("奖金 $" .. blind_reward(b - 1), 6, 58, CL.gold)
  -- 分数：标签在框外，框内数值独占整宽，内边距四周均等
  print("分数", 6, 74, CL.g1)
  fr(4, 88, 72, 22, CL.steel)
  ptext(fmt(G.score), 93, 7, 4, 76)
  -- 本手预览：筹码 / 倍率，描边随语义配色（蓝筹码、红倍率）
  ptext("筹码", 114, CL.g1, 4, 36) ptext("倍率", 114, CL.g1, 44, 76)
  fr(4, 128, 32, 22, CL.sky) fr(44, 128, 32, 22, CL.red)
  local pv = preview()
  ptext(pv and fmt(pv.c) or "-", 133, CL.sky, 4, 36)
  ptext(pv and fmt(pv.m) or "-", 133, CL.red, 44, 76)
  print("×", 37, 133, CL.red)
  local ok = PS.ph == "input"
  local canplay = ok and G.hands > 0 and seln() > 0
  local candisc = ok and G.discards > 0 and seln() > 0
  -- 小丑行聚焦时 LB 是出售，按钮文案随焦点切换（售价见小丑提示面板）
  local sell = PS.row == 0 and ok
  button(4, 158, 72, 16, btnicon("lb") .. (sell and " 出售" or " 出牌 " .. G.hands),
    sell and CL.gold or CL.fd, false, sell or canplay)
  button(4, 178, 72, 16, btnicon("rb") .. " 弃牌 " .. G.discards, CL.dred, false, candisc)
  print("$" .. fmt(G.money), 4, 200, CL.gold)
  print("底注 " .. G.ante .. "/8", 4, 213, CL.g2)
  print("轮次 " .. G.round, 4, 226, CL.g2)
end

function preview()
  if seln() == 0 or PS.ph ~= "input" then return nil end
  local sel = {}
  for _, c in ipairs(DH) do if c.sel then sel[#sel + 1] = c end end
  local ev = eval_hand(sel)
  return { k = ev.k, c = HANDS[ev.k][2], m = HANDS[ev.k][3] }
end

function dn_round()
  cls(37)
  map(0, 0, 0, 0, 16, 16, 1)
  if SHK > 0 then
    camera(math.floor(sin(tt * 1.7) * SHK), math.floor(cos(tt * 2.1) * SHK))
  end
  dn_panel()
  -- 打出区
  for i, c in ipairs(DS) do
    local fl = c.flip and c.flip > 0
    draw_card(c, math.floor(c.x), math.floor(c.y) - (fl and 6 or 0))
  end
  -- 小丑行
  for i, o in ipairs(G.jk) do
    local x, y = joker_x(i, #G.jk, 168), 6
    local foc = PS.row == 0 and PS.cur == i and PS.ph == "input"
    if foc then y = y - 4 end
    o.px, o.py = x, y
    draw_joker(o, x, y)
    if foc then rect(x - 1, y - 1, 34, 34, CL.cur) end
  end
  -- 手牌：选中牌上浮表达；黄框是唯一选择器，只指示光标位置
  local hov = PS.row == 1 and DH[PS.cur] or nil
  for i, c in ipairs(DH) do
    local sel = c.sel
    local yy = c.y - (sel and 10 or 0) - ((sel or c == hov) and math.floor(ABS(sin((tt + i * 9) * 0.05)) * 2) or 0)
    draw_card(c, math.floor(c.x), math.floor(yy))
    if c == hov and PS.ph == "input" then
      -- 卡面墨迹 x 4..27（宽 24）：框贴卡面而不是整格
      rect(math.floor(c.x) + 4, math.floor(yy), 24, 32, CL.cur)
    end
  end
  -- 牌堆剩余数（立在牌堆左侧，不压牌堆图）；手牌恒为满额，无需计数
  if #DK > 0 then spr(band_tile(T_BACK, G.deck), 220, 158, 2, 2) end
  print("牌库 " .. #DK .. "/52", 156, 160, CL.g2)
  -- 小丑聚焦提示
  if PS.row == 0 and #G.jk > 0 and PS.ph == "input" then
    local o = G.jk[PS.cur]
    local d = JOKERS[o.id + 1]
    tip_panel(d.n .. "(" .. RAR_N[d.r + 1] .. ")", RAR_C[d.r + 1], d.d)
    print("出售 $" .. math.floor(MAX(1, d.v / 2)), 196, 176, CL.gold)
  end
  camera(0, 0)
  floats()
end

-- ============================================================ 结算
function up_roundend()
  RE.t = RE.t + 1
  if RE.t > sp(40) and kA() then
    G.money = G.money + RE.cash
    sfx(23, CH_UI)
    if RE.final then
      game_over(true)
      return
    end
    -- 底注推进在商店"离开"时统一结算（此处只计轮次）
    G.round = G.round + 1
    st, tt = "shop", 0
    enter_shop()
  end
end
function dn_roundend()
  dn_round()
  rectfill(56, 40, 144, 130, CL.bg)
  rect(56, 40, 144, 130, CL.gold)
  ptext("盲注击败", 46, 7)
  local reveal = math.floor(RE.t / sp(20))
  local y = 64
  for i, it in ipairs(RE.items) do
    if reveal >= i then
      print(it[1], 66, y, CL.frost)
      print(it[2], 158, y, CL.gold)
      y = y + 16
    end
  end
  if reveal >= 4 then
    button(88, 140, 80, 20, "领取 $" .. RE.cash, CL.gold, true, true)
  end
  hint({ { "a", "领取" } })
end
