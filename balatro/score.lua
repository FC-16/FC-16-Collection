-- 计分：筹码/倍率/金钱原语与出牌计分主线
-- ------------------------------------------------------------ 计分原语
local TCh, TMu, TPop = 0, 0, nil   -- 本手筹码/倍率/当前演出
function achip(v, o) TCh = TCh + v jpop(o, "+" .. fmt(v), CL.sky) end
function amul(v, o) TMu = TMu + v jpop(o, "+" .. v, CL.red) sfx(6, CH_UI) end
function xm(v, o) TMu = TMu * v jpop(o, "×" .. v, CL.red) sfx(7, CH_UI) end
function give(v, o)
  G.money = G.money + v
  jpop(o, "$" .. v, CL.gold) sfx(9, CH_UI)
end
function jpop(o, s, c)
  local t = POPJ or o
  if t and t.px then toast(s, t.px + 16, t.py - 4, c) end
end
function coin() return ri(2) == 1 end
function kill(o, msg)     -- 小丑销毁（气泡水喝光）
  for i, q in ipairs(G.jk) do
    if q == o then deli(G.jk, i) toast(msg, o.px + 16, o.py, CL.g2) sfx(18, CH_UI) return end
  end
end
function retrig(msg)
  if HELO then HELO.ret = HELO.ret + 1 end
end


-- ============================================================ 对局：出牌与计分
function play_selected()
  DS = {}
  for i = #DH, 1, -1 do
    if DH[i].sel then
      local c = table.remove(DH, i)
      c.sel = nil
      DS[#DS + 1] = c
    end
  end
  -- 打出区从左到右排列
  table.sort(DS, function(a, b) return a.tx < b.tx end)
  local n = #DS
  for i, c in ipairs(DS) do
    c.px = 128 - 16 + (i - 1 - (n - 1) / 2) * 32
    c.py = 116
    c.sx, c.sy = c.x, c.y
    c.de = sp(4) * (i - 1)
  end
  G.hands = G.hands - 1
  sfx(4, CH_UI)
  PS.ph, PS.t, PS.step = "tosort", 0, 0
  PS.ah, PS.used = nil, nil   -- 离开出牌阶段：作废未完成的 A 点按，防止计分后误选牌
end
function do_discard()
  local n = 0
  for i = #DH, 1, -1 do
    if DH[i].sel then table.remove(DH, i) n = n + 1 end
  end
  G.discards = G.discards - 1
  sfx(31, CH_UI)
  PS.ah, PS.used = nil, nil   -- 同上：弃牌后不再延续按住 A 的点按语义
  draw_cards(n)
end

-- 计分主线（GBA PlayState 序列的紧凑版）
EVN, RETN, HELO = nil, 0, nil
function begin_score()
  local ev = eval_hand(DS)
  EVN = ev
  TCh, TMu = HANDS[ev.k][2], HANDS[ev.k][3]
  HELO = { ph = "pre", t = 0, i = 1, ret = 0 }
  PS.ph = "score"
end
function fire(o, ev, c, i)
  local target, td = o, JOKERS[o.id + 1]
  if o.id == 52 or o.id == 41 then
    -- 蓝图/头脑风暴：解析复制源，以复制体位置演出
    local src = copy_src(o)
    if not src then return end
    target, td = src, JOKERS[src.id + 1]
  end
  if td[ev] then
    POPJ = target ~= o and o or nil
    td[ev](target, c, i)
    POPJ = nil
  end
end
function fire_all(ev, c, i)
  for _, o in ipairs(G.jk) do fire(o, ev, c, i) end
end
function copy_src(o)
  local n = #G.jk
  for idx, q in ipairs(G.jk) do
    if q == o then
      if o.id == 41 then          -- 头脑风暴 → 最左侧非复制体
        for k = 1, n do
          if G.jk[k].id ~= 41 and G.jk[k].id ~= 52 then return G.jk[k] end
        end
      else                        -- 蓝图 → 右侧第一个非复制体
        for k = idx + 1, n do
          if G.jk[k].id ~= 41 and G.jk[k].id ~= 52 then return G.jk[k] end
        end
      end
    end
  end
  return nil
end
function step_score()
  local h = HELO
  h.t = h.t + 1
  if h.ph == "pre" then                 -- 出牌后小丑（hp）
    if h.t == 1 then fire_all("hp") end
    if h.t >= sp(12) then h.ph, h.t, h.i, h.ret, h.ce = "card", 0, 1, 0, nil end
  elseif h.ph == "card" then            -- 逐张：翻牌 + 筹码 + cs + 重触发
    local c = DS[h.i]
    if h.t == 1 then c.flip = 1 sfx(3, CH_UI) end
    if h.t == sp(8) then
      achip0(c)
      fire_all("cs", c, h.i)
    end
    if h.t >= sp(20) then
      if h.ret > 0 then                 -- 重触发演出（不重放翻牌/首次计分）
        h.ret = h.ret - 1
        toast("再来！", c.px + 8, c.py - 10, CL.cur)
        achip0(c)
        fire_all("cs", c, h.i)
        h.t = sp(20)
        return
      end
      if not h.ce then                  -- ce 事件每张卡只发一次，否则按点数重触发的
        h.ce = true                     -- 小丑（黑客等）会与重放互相派生，无限循环
        fire_all("ce", c, h.i)
        if h.ret > 0 then h.t = sp(20) return end
      end
      h.ce = nil
      h.i = h.i + 1
      h.t = 0
      if h.i > #DS then h.ph, h.t, h.hi = "held", 0, nil end
    end
  elseif h.ph == "held" then            -- 留牌
    local held = {}
    for _, c in ipairs(DH) do if not c.sel then held[#held + 1] = c end end
    h.hi = h.hi or 1
    if h.hi <= #held then
      if h.t == sp(8) then fire_all("ch", held[h.hi]) end
      if h.t >= sp(14) then h.hi = h.hi + 1 h.t = 0 end
    else
      h.ph, h.t, h.ji = "indep", 0, 1
    end
  elseif h.ph == "indep" then           -- 独立结算
    local j = h.ji or 1
    if j <= #G.jk then
      if h.t == 1 then fire(G.jk[j], "ind") end
      if h.t >= sp(16) then h.ji = j + 1 h.t = 0 end
    else
      h.ph, h.t = "hs", 0
    end
  elseif h.ph == "hs" then              -- 整手结算 + 乘算
    if h.t == 1 then fire_all("hs") end
    if h.t >= sp(10) then
      h.fin = TCh * TMu
      toast(fmt(TCh) .. " × " .. fmt(TMu), 128, 170, 7, true)
      SHK = sp(6)
      sfx(23, CH_UI)
      h.ph, h.t, h.li = "lerp", 0, 0
    end
  elseif h.ph == "lerp" then            -- 16 步滚动入总分
    if h.t % 2 == 0 then
      h.li = h.li + 1
      G.score = G.score + CEIL(h.fin / 16)
      sfx(8, CH_UI)
    end
    if h.li >= 16 and h.t >= sp(32) then
      G.score = G.score + h.fin - h.li * CEIL(h.fin / 16)   -- 冲抵跑条近似增量，总分落定精确值
      h.ph, h.t = "out", 0
    end
  end
end
function achip0(c)
  local v = c.r >= 9 and 10 or (c.r == 12 and 11 or c.r + 2)
  TCh = TCh + v
  toast("+" .. v, DS_px(c) , c.py - 12, CL.sky)
  sfx(5, CH_UI)
end
function DS_px(c)
  for i, q in ipairs(DS) do if q == c then return c.px end end
  return c.px
end

function round_over()
  local req = blind_req(G.blind >= 3 and 2 or (G.blind - 1))
  if G.score >= req then
    st, tt = "roundend", 0
    RE = { t = 0, items = {}, got = 0, cash = 0 }
    local reward = blind_reward(G.blind - 1)
    if G.deck == 3 then     -- 绿牌组：剩余出牌 ×$2 + 剩余弃牌 ×$1，无利息
      RE.cash = reward + G.hands * 2 + G.discards
      RE.items = {
        { blind_name(G.blind - 1), "$" .. reward },
        { "剩余手牌 " .. G.hands .. "×$2", "$" .. G.hands * 2 },
        { "剩余弃牌 " .. G.discards .. "×$1", "$" .. G.discards },
        { "利息（无）", "$0" },
      }
    else
      local interest = math.floor(MIN(math.floor(G.money / 5), 5))  -- min/max 恒返浮点子类型，拼接前归整
      RE.cash = reward + G.hands + interest
      RE.items = {
        { blind_name(G.blind - 1), "$" .. reward },
        { "剩余手牌 " .. G.hands, "$" .. G.hands },
        { "利息", "$" .. interest },
      }
    end
    RE.final = G.blind >= 3 and G.ante >= 8
    sfx(13, CH_UI)
  end
end
function game_over(win)
  st, tt = "over", 0
  OV = { win = win, sel = 1 }
  sfx(win and 22 or 21, CH_UI)
  music_stop(600)
end
