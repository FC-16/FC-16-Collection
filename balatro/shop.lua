-- 商店屏：货位、按钮、持有小丑三行光标
-- ============================================================ 商店
function roll_joker()
  local owned = {}
  for _, o in ipairs(G.jk) do owned[o.id] = true end
  local roll = ri(100)
  local want = roll <= 70 and 0 or (roll <= 95 and 1 or 2)
  local pool = {}
  for i, d in ipairs(JOKERS) do
    if not owned[d.id] and d.r == want then pool[#pool + 1] = d.id end
  end
  if #pool == 0 then
    for i, d in ipairs(JOKERS) do
      if not owned[d.id] then pool[#pool + 1] = d.id end
    end
  end
  if #pool == 0 then return nil end
  return pool[ri(#pool)]
end
function enter_shop()
  SHOP = { items = { roll_joker(), roll_joker() }, reroll = 5, row = 0, cur = 1 }
  music(0, 400, 0xC7)
end

-- 商店布局：货位两格、按钮两枚、持有小丑一行，三者各自以屏幕中线对称展开；
-- 货位格按稀有度描边，购买后留下空位（不重排，避免棋盘跳动）。
-- 纵向节奏：标题 8 / 信息 40 / 货位 60 / 按钮 128 / 小丑行 152 / 面板 192，段间距统一 8px。
local SP_GW, SP_GH, SP_GY, SP_GG = 60, 60, 60, 16      -- 货位格：宽/高/顶边/格间隙
local SP_BW, SP_BH, SP_BY = 70, 16, 128                -- 按钮：宽/高/顶边
local SP_BG = 12                                       -- 按钮间隙
local SP_JY, SP_JB, SP_PT = 152, 238, 192              -- 小丑行顶边 / 面板底边 / 面板顶边
local SP_GX = 128 - SP_GW - math.floor(SP_GG / 2)      -- 货位左格 x（右格 +SP_GW+SP_GG）
local SP_BX = 128 - SP_BW - math.floor(SP_BG / 2)      -- 按钮左钮 x（右钮 +SP_BW+SP_BG）

-- 光标 (row, cur)：row 0 货位（列即左右格）、row 1 按钮（1 重掷 / 2 离开）、
-- row 2 持有小丑（列即小丑序号）。方向键按屏幕方位移动：横向行内环绕，
-- 纵向跨行并尽量保持列；已售出的货位横向跳过、纵向不进入。
function shop_good(i)
  local id = SHOP.items[i]
  return id and JOKERS[id + 1] or nil
end
function shop_focus()
  if SHOP.row == 0 then
    local d = shop_good(SHOP.cur)
    if not d then return nil end
    return { nm = d.n .. "(" .. RAR_N[d.r + 1] .. ")", rc = RAR_C[d.r + 1], d = d.d }
  elseif SHOP.row == 1 then
    if SHOP.cur == 1 then
      return { nm = "重 掷", rc = CL.dred, d = "花费 $" .. SHOP.reroll .. " 刷新两个货位" }
    end
    return { nm = "离 开", rc = CL.fd, d = "保存进度，前往下一个盲注" }
  end
  local o = G.jk[SHOP.cur]
  if not o then return nil end
  local d = JOKERS[o.id + 1]
  return { nm = d.n .. "(" .. RAR_N[d.r + 1] .. ")", rc = RAR_C[d.r + 1], d = d.d,
    sell = math.floor(MAX(1, d.v / 2)) }
end
function shop_side(d)
  local n = SHOP.row == 2 and #G.jk or 2
  if n < 2 then return false end
  local c = SHOP.cur
  for _ = 1, n do
    c = d > 0 and c % n + 1 or (c - 2) % n + 1
    if c ~= SHOP.cur and (SHOP.row ~= 0 or SHOP.items[c]) then
      SHOP.cur = c
      return true
    end
  end
  return false
end
function shop_up()
  if SHOP.row == 2 then
    SHOP.row, SHOP.cur = 1, math.floor(MIN(SHOP.cur, 2))
  elseif SHOP.row == 1 then
    local c = math.floor(MIN(SHOP.cur, 2))
    if not SHOP.items[c] then c = 3 - c end
    if not SHOP.items[c] then return false end
    SHOP.row, SHOP.cur = 0, c
  else
    return false
  end
  return true
end
function shop_down()
  if SHOP.row == 0 then
    SHOP.row = 1
  elseif SHOP.row == 1 and #G.jk > 0 then
    SHOP.row, SHOP.cur = 2, math.floor(MIN(SHOP.cur, #G.jk))
  else
    return false
  end
  return true
end
function shop_buy(i)
  local d = shop_good(i)
  if not d or G.money < d.v or #G.jk >= G.slots then buzz() return end
  G.money = G.money - d.v
  local o = { id = d.id }
  if d.by then d.by(o) end
  G.jk[#G.jk + 1] = o
  SHOP.items[i] = nil
  sfx(10, CH_UI)
  if SHOP.cur == i and SHOP.items[3 - i] then SHOP.cur = 3 - i end   -- 移到仍有货的一格
end
function shop_reroll()
  if G.money < SHOP.reroll then buzz() return end
  G.money = G.money - SHOP.reroll
  SHOP.reroll = SHOP.reroll + 1
  SHOP.items = { roll_joker(), roll_joker() }
  sfx(11, CH_UI)
end
function shop_sell()
  local n = #G.jk
  sell_joker(SHOP.cur)
  if #G.jk == n then return end
  if #G.jk == 0 then SHOP.row, SHOP.cur = 1, math.floor(MIN(SHOP.cur, 2))
  else SHOP.cur = math.floor(MIN(SHOP.cur, #G.jk)) end
end
function up_shop()
  local moved = false
  if dpr("left") then moved = shop_side(-1) end
  if dpr("right") then moved = shop_side(1) or moved end
  if dpr("up") then moved = shop_up() or moved end
  if dpr("down") then moved = shop_down() or moved end
  if moved then sfx(0, CH_UI) end
  if SHOP.row == 2 then
    if kL() then shop_sell() end
  elseif kA() then
    if SHOP.row == 0 then shop_buy(SHOP.cur)
    elseif SHOP.cur == 1 then shop_reroll()
    else
      save_run()
      sfx(30, CH_UI)
      G.bstat[G.blind] = true        -- 本盲注已击败
      G.blind = G.blind + 1
      if G.blind > 3 then            -- Boss 亦战毕：进入下一个底注，重抽 Boss
        G.ante = G.ante + 1
        G.blind = 1
        G.boss = -1
        G.bstat = {}
      end
      to_blindsel()
    end
  end
end
function dn_shop()
  cls(37)
  print("商 店", 8, 8, 7, 2)
  local ms = "$" .. fmt(G.money)
  print(ms, 248 - textw(ms), 14, CL.gold)
  print("底注 " .. G.ante .. "/8  轮次 " .. G.round, 8, 40, CL.g2)
  local js = "小丑 " .. #G.jk .. "/" .. G.slots
  print(js, 248 - textw(js), 40, CL.g2)
  -- 货位：价格买不起时变暗，空货位留框显示"已售出"
  for i = 1, 2 do
    local x = SP_GX + (i - 1) * (SP_GW + SP_GG)
    local d = shop_good(i)
    rectfill(x, SP_GY, SP_GW, SP_GH, CL.hole)
    rect(x, SP_GY, SP_GW, SP_GH, d and RAR_C[d.r + 1] or CL.d3)
    if SHOP.row == 0 and SHOP.cur == i then rect(x - 1, SP_GY - 1, SP_GW + 2, SP_GH + 2, 7) end
    if d then
      spr(band_tile(T_JOKER, d.id), x + 14, SP_GY + 4, 2, 2)
      local ps = "$" .. d.v
      print(ps, x + math.floor((SP_GW - textw(ps)) / 2), SP_GY + 42, G.money >= d.v and CL.gold or CL.d3)
    else
      ptext("已售出", SP_GY + 24, CL.d3, x, x + SP_GW)
    end
  end
  -- 重掷 / 离开：与货位同列对齐
  button(SP_BX, SP_BY, SP_BW, SP_BH, "重掷 $" .. SHOP.reroll, CL.dred,
    SHOP.row == 1 and SHOP.cur == 1, G.money >= SHOP.reroll)
  button(SP_BX + SP_BW + SP_BG, SP_BY, SP_BW, SP_BH, "离开", CL.fd,
    SHOP.row == 1 and SHOP.cur == 2, true)
  -- 持有小丑：整行居中，空槽显示容量
  for i = 1, G.slots do
    local x = joker_x(i, G.slots, 128, 240)
    local o = G.jk[i]
    if o then
      o.px, o.py = x, SP_JY
      draw_joker(o, x, SP_JY)
      if SHOP.row == 2 and SHOP.cur == i then rect(x - 1, SP_JY - 1, 34, 34, 7) end
    else
      rect(x, SP_JY, 32, 32, CL.dusk)
    end
  end
  -- 说明面板：顶边固定（段间距与其余各行一致），不随描述长度上下浮动
  local f = shop_focus()
  if f then
    tip_panel(f.nm, f.rc, f.d, SP_PT, SP_JB - SP_PT)
    if f.sell then
      local s = "出售 $" .. f.sell
      print(s, 228 - textw(s), SP_PT + 4, CL.gold)
    end
  end
  floats()
end
