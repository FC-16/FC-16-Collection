-- FC-16 斗地主（demo/doudizhu）
-- 三人斗地主：你（南家）对阵东家、西家两台 AI。
-- 完整流程：标题 → 发牌动画 → 叫分（1/2/3/不叫，全不叫重发）→ 地主拿底牌（明示）
--   → 轮流出牌（跟同型更大或炸弹/王炸）→ 结算（底分×叫分×炸弹翻倍×春天）。
-- 牌型：单/对/三张/三带一/三带对/顺子(≥5)/连对(≥3)/飞机(≥2 组连三，可带同数单或对)
--       /四带二(两单或两对)/炸弹/王炸；2 与王不入顺。
-- 无精灵资产：牌面、牌背、界面全部程序化绘制（迷你 3×5 点数字形 + 5×5 花色字形）。
-- SFX 与背景音乐由 _init 按 SPEC §5.2 布局 poke 写入。
-- 操作：←→移动光标（按住重复）　↑/Ⓐ抬起或放回当前牌　↓放回当前牌　Ⓑ清空选择
--       Ⓧ出牌　Ⓨ不要　Ⓡ提示（复用 AI 跟牌逻辑）　Menu/Ⓐ 结算后再来一局。
-- 存档：dset 槽 0 = 累计积分，槽 1 = 局数。

-- ================================================================ 常量与配色

local CW, CH = 20, 28          -- 标准牌尺寸（手牌 / 侧家出牌）
local HY = 196                 -- 手牌顶 y（选中牌上移 8px）
local PLAY_CX = {128, 204, 52} -- 各家出牌区中心 x：1 南 2 东(右) 3 西(左)
local PLAY_Y = {108, 44, 44}   -- 各家出牌区 y
local PLAY_W = {216, 88, 88}   -- 各家出牌区可用宽度
local DEAL_TO = {{128, 202}, {204, 10}, {52, 10}} -- 发牌飞行目标

local SEAT_NAME = {"你", "东家", "西家"} -- 座位 1=南(玩家) 2=东(右上) 3=西(左上)；逆时针轮转

-- ENDESGA-64 的 FC-16 固定索引（SPEC §2.2）
local C_TABLE = 36   -- 桌面毛毡绿
local C_TABLE_HI = 35
local C_RIM = 37
local C_BG = 14      -- 手牌区深底
local C_STRIP = 13   -- 顶栏
local C_PANEL = 16   -- 玩家面板棕
local C_PANEL_BD = 18
local C_CREAM = 22   -- 面板文字
local C_GOLD = 30    -- 选中/地主金
local C_GOLD2 = 31
local C_RED = 59     -- 红花色
local C_BLACK = 1    -- 黑花色
local C_JOKER_S = 40 -- 小王蓝
local C_DIM = 10     -- 次要文字
local C_BACK = 60    -- 牌背红
local C_BACK_D = 61

local next_seat = function(s) return s % 3 + 1 end

-- ================================================================ 迷你字形

-- 3×5 点数字形（每行 3 位，高位在左）
local GLYPH = {
  ["1"] = {2, 6, 2, 2, 7},
  ["2"] = {7, 1, 7, 4, 7},
  ["3"] = {7, 1, 7, 1, 7},
  ["4"] = {5, 5, 7, 1, 1},
  ["5"] = {7, 4, 7, 1, 7},
  ["6"] = {7, 4, 7, 5, 7},
  ["7"] = {7, 1, 1, 1, 1},
  ["8"] = {7, 5, 7, 5, 7},
  ["9"] = {7, 5, 7, 1, 7},
  ["0"] = {7, 5, 5, 5, 7},
  ["J"] = {7, 2, 2, 2, 6},
  ["Q"] = {7, 5, 5, 7, 1},
  ["K"] = {5, 6, 4, 6, 5},
  ["A"] = {2, 5, 7, 5, 5},
}
-- 5×5 花色 / 王星字形
local SUIT_G = {
  {4, 14, 31, 31, 4},  -- ♠
  {10, 31, 31, 14, 4}, -- ♥
  {4, 14, 31, 14, 4},  -- ♦
  {14, 31, 31, 4, 4},  -- ♣
}
local JOKER_G = {4, 21, 31, 14, 4}
local SUIT_CH = {"♠", "♥", "♦", "♣"}
local RANK_STR = {"3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A", "2"}

local function glyph(pat, x, y, c, sc, w)
  sc = sc or 1
  for r = 1, 5 do
    local bits = pat[r]
    for i = 0, w - 1 do
      if (bits >> (w - 1 - i)) & 1 == 1 then
        rectfill(x + i * sc, y + (r - 1) * sc, sc, sc, c)
      end
    end
  end
end

-- ================================================================ 卡牌编码

-- 牌编码 c = 点数×4 + 花色；点数 3..15（3..2），16 小王，17 大王；小王=64 大王=68
-- 点数序：3<4<…<K<A<2<小王<大王，编码整数值与大小序一致
local function rank_of(c) return flr(c / 4) end

local function card_col(c)
  local r = rank_of(c)
  if r == 17 then return C_RED end
  if r == 16 then return C_JOKER_S end
  return (c % 4 == 1 or c % 4 == 2) and C_RED or C_BLACK
end

local function sort_hand(h)
  table.sort(h, function(a, b) return a > b end)
end

local function hand_cnt(cards)
  local cnt = {}
  for i = 1, #cards do
    local r = rank_of(cards[i])
    cnt[r] = (cnt[r] or 0) + 1
  end
  return cnt
end

local function by_rank(cards)
  local m = {}
  for i = 1, #cards do
    local r = rank_of(cards[i])
    local l = m[r]
    if not l then l = {} m[r] = l end
    l[#l + 1] = cards[i]
  end
  return m
end

local function copy_cards(cs)
  local out = {}
  for i = 1, #cs do out[i] = cs[i] end
  return out
end

-- ================================================================ 牌型识别与比较

local function is_run(ranks) -- 已升序
  for i = 2, #ranks do
    if ranks[i] ~= ranks[i - 1] + 1 then return false end
  end
  return true
end

-- 识别一手牌；返回 {kind, main, len?, cards} 或 nil（非法）
-- kind: single/pair/trio/trio1/trio2/straight/pairseq/plane/plane1/plane2/
--       four2/four2pair/bomb/rocket
local function analyze(cards)
  local n = #cards
  if n < 1 then return nil end
  local cnt = hand_cnt(cards)
  local ranks = {}
  for r in pairs(cnt) do ranks[#ranks + 1] = r end
  table.sort(ranks)
  local nr = #ranks

  if n == 2 and cnt[16] and cnt[17] then
    return {kind = "rocket", main = 17, cards = cards}
  end
  if nr == 1 then
    local r = ranks[1]
    if n == 1 then return {kind = "single", main = r, cards = cards} end
    if n == 2 then return {kind = "pair", main = r, cards = cards} end
    if n == 3 then return {kind = "trio", main = r, cards = cards} end
    if n == 4 then return {kind = "bomb", main = r, cards = cards} end
    return nil
  end
  if n == 4 and nr == 2 then
    for _, r in ipairs(ranks) do
      if cnt[r] == 3 then return {kind = "trio1", main = r, cards = cards} end
    end
    return nil
  end
  if n == 5 and nr == 2 then
    for _, r in ipairs(ranks) do
      if cnt[r] == 3 then return {kind = "trio2", main = r, cards = cards} end
    end
    return nil
  end
  -- 顺子（≥5 连单，2 与王不入顺）
  if n >= 5 and nr == n and ranks[nr] <= 14 and is_run(ranks) then
    return {kind = "straight", main = ranks[nr], len = n, cards = cards}
  end
  -- 连对（≥3 连对）；不满足对子计数时继续向后判定（可能是飞机翅膀）
  if n >= 6 and n % 2 == 0 and nr == n / 2 and ranks[nr] <= 14 and is_run(ranks) then
    local allpairs = true
    for _, r in ipairs(ranks) do
      if cnt[r] ~= 2 then allpairs = false break end
    end
    if allpairs then
      return {kind = "pairseq", main = ranks[nr], len = nr, cards = cards}
    end
  end
  -- 飞机族：点数 至多A 的全部三张必须构成连续段
  local t3 = {}
  for _, r in ipairs(ranks) do
    if cnt[r] == 3 and r <= 14 then t3[#t3 + 1] = r end
  end
  if #t3 >= 2 and is_run(t3) then
    local k = #t3
    if n == 3 * k then
      return {kind = "plane", main = t3[k], len = k, cards = cards}
    end
    if n == 4 * k then
      return {kind = "plane1", main = t3[k], len = k, cards = cards}
    end
    if n == 5 * k then
      local pairs = 0
      for _, r in ipairs(ranks) do
        if cnt[r] ~= 3 then
          if cnt[r] == 2 then pairs = pairs + 1 else pairs = -1 break end
        end
      end
      if pairs == k then return {kind = "plane2", main = t3[k], len = k, cards = cards} end
    end
  end
  -- 四带二（两单或两对）
  local four = nil
  for _, r in ipairs(ranks) do
    if cnt[r] == 4 then four = r end
  end
  if four then
    if n == 6 then return {kind = "four2", main = four, cards = cards} end
    if n == 8 then
      local pairs = 0
      for _, r in ipairs(ranks) do
        if cnt[r] == 2 then pairs = pairs + 1
        elseif cnt[r] ~= 4 then return nil end
      end
      if pairs == 2 then return {kind = "four2pair", main = four, cards = cards} end
      return nil
    end
  end
  return nil
end

-- a 是否压过 b（b 为上家牌型）
local function beats(a, b)
  if a == nil then return false end
  if a.kind == "rocket" then return true end
  if b.kind == "rocket" then return false end
  if a.kind == "bomb" then
    if b.kind ~= "bomb" then return true end
    return a.main > b.main
  end
  if b.kind == "bomb" then return false end
  return a.kind == b.kind and a.len == b.len and a.main > b.main
end

-- ================================================================ AI：拆牌与出牌

local hands               -- hands[1..3]：各家手牌（降序）
local landlord            -- 地主座位（1..3），0 未定
local last_play           -- {seat, combo} 或 nil（新一轮）
local played_cnt          -- 各家出牌次数（春天判定）

local function is_friend(a, b)
  return a ~= b and a ~= landlord and b ~= landlord
end

local function opp_cards(seat) -- 对手方最小剩余张数
  if seat == landlord then
    local m = 99
    for s = 1, 3 do
      if s ~= seat then m = min(m, #hands[s]) end
    end
    return m
  end
  return #hands[landlord]
end

local function mate_cards(seat) -- 农民队友剩余张数
  if seat == landlord then return 99 end
  for s = 1, 3 do
    if s ~= seat and s ~= landlord then return #hands[s] end
  end
  return 99
end

-- 手牌强度估值（叫分用）
local function hand_strength(cards)
  local cnt = hand_cnt(cards)
  local s = 0
  for r, c in pairs(cnt) do
    if r == 14 then s = s + c
    elseif r == 15 then s = s + c * 2
    elseif r == 16 then s = s + 3
    elseif r == 17 then s = s + 4 end
    if c == 4 then s = s + 3 end
  end
  if cnt[16] and cnt[17] then s = s + 3 end
  return s
end

-- 手牌拆解为组合（启发式：王炸/炸弹 → 最长顺子 → 连对 → 连三张飞机 → 三张 → 对 → 单）
local function decompose(cards)
  local cnt = hand_cnt(cards)
  local used = {}
  local groups = {}
  local function take(r, k)
    local out = {}
    for i = 1, #cards do
      if not used[i] and rank_of(cards[i]) == r then
        used[i] = true
        out[#out + 1] = cards[i]
        if #out == k then break end
      end
    end
    cnt[r] = (cnt[r] or 0) - k
    if cnt[r] <= 0 then cnt[r] = nil end
    return out
  end

  if cnt[16] and cnt[17] then
    groups[#groups + 1] = {kind = "rocket", main = 17,
      cards = {take(16, 1)[1], take(17, 1)[1]}}
  end
  for r = 3, 15 do
    if cnt[r] == 4 then
      groups[#groups + 1] = {kind = "bomb", main = r, cards = take(r, 4)}
    end
  end
  -- 最长顺子优先（从小端起）
  local found = true
  while found do
    found = false
    local r = 3
    while r <= 10 do
      if (cnt[r] or 0) > 0 then
        local e = r
        while e + 1 <= 14 and (cnt[e + 1] or 0) > 0 do e = e + 1 end
        if e - r + 1 >= 5 then
          local cs = {}
          for rr = r, e do cs[#cs + 1] = take(rr, 1)[1] end
          groups[#groups + 1] = {kind = "straight", main = e, len = e - r + 1, cards = cs}
          found = true
        end
      end
      r = r + 1
    end
  end
  -- 连对
  found = true
  while found do
    found = false
    local r = 3
    while r <= 12 do
      if (cnt[r] or 0) >= 2 then
        local e = r
        while e + 1 <= 14 and (cnt[e + 1] or 0) >= 2 do e = e + 1 end
        if e - r + 1 >= 3 then
          local cs = {}
          for rr = r, e do
            local t = take(rr, 2)
            cs[#cs + 1] = t[1] cs[#cs + 1] = t[2]
          end
          groups[#groups + 1] = {kind = "pairseq", main = e, len = e - r + 1, cards = cs}
          found = true
        end
      end
      r = r + 1
    end
  end
  -- 连续三张合并为飞机；单独三张保留
  local t3 = {}
  for r = 3, 14 do
    if cnt[r] == 3 then t3[#t3 + 1] = r end
  end
  local i = 1
  while i <= #t3 do
    local j = i
    while j + 1 <= #t3 and t3[j + 1] == t3[j] + 1 do j = j + 1 end
    if j > i then
      local cs = {}
      for x = i, j do
        local t = take(t3[x], 3)
        cs[#cs + 1] = t[1] cs[#cs + 1] = t[2] cs[#cs + 1] = t[3]
      end
      groups[#groups + 1] = {kind = "plane", main = t3[j], len = j - i + 1, cards = cs}
    else
      groups[#groups + 1] = {kind = "trio", main = t3[i], cards = take(t3[i], 3)}
    end
    i = j + 1
  end
  if cnt[15] == 3 then
    groups[#groups + 1] = {kind = "trio", main = 15, cards = take(15, 3)}
  end
  for r = 3, 17 do
    if cnt[r] == 2 then
      groups[#groups + 1] = {kind = "pair", main = r, cards = take(r, 2)}
    end
  end
  for r = 3, 17 do
    if cnt[r] == 1 then
      groups[#groups + 1] = {kind = "single", main = r, cards = take(r, 1)}
    end
  end
  return groups
end

-- 主动出牌：长小型优先、小牌优先；对手报单时少送单/对小牌
local function ai_lead(seat)
  local hand = hands[seat]
  local whole = analyze(hand)
  if whole then return copy_cards(hand) end -- 整手一手出完
  local groups = decompose(hand)
  local cands = {}
  for _, g in ipairs(groups) do
    if g.kind ~= "bomb" and g.kind ~= "rocket" then cands[#cands + 1] = g end
  end
  if #cands == 0 then
    -- 只剩炸弹：先出炸弹，王炸垫底
    local pick = nil
    for _, g in ipairs(groups) do
      if g.kind == "bomb" then pick = g break end
    end
    if not pick then pick = groups[1] end
    return copy_cards(pick.cards)
  end
  local opp_n = opp_cards(seat)
  local mate_n = mate_cards(seat)
  local best, best_s = nil, 1e9
  for _, g in ipairs(cands) do
    local base
    if g.kind == "straight" then base = 0
    elseif g.kind == "pairseq" then base = 1
    elseif g.kind == "plane" then base = 2
    elseif g.kind == "trio" then base = 3
    elseif g.kind == "pair" then base = 4
    else base = 5 end
    local s = base * 40 + g.main * 3 - (g.len or 1) * 2
    if opp_n <= 2 and (g.kind == "single" or g.kind == "pair") and g.main < 11 then
      s = s + 150
    end
    if mate_n == 1 and g.kind == "single" then s = s - 150 end
    if s < best_s then best_s = s best = g end
  end
  local g = best
  local cs = copy_cards(g.cards)
  -- 三张/飞机带小单翅（不拆大牌、不动王）
  if g.kind == "trio" or g.kind == "plane" then
    local need = g.len or 1
    local wings = {}
    for _, g2 in ipairs(groups) do
      if g2 ~= g and g2.kind == "single" and g2.main < g.main and g2.main < 11
        and #wings < need then
        wings[#wings + 1] = g2.cards[1]
      end
    end
    if #wings == need then
      for i = 1, #wings do cs[#cs + 1] = wings[i] end
    end
  end
  if analyze(cs) then return cs end
  return copy_cards(g.cards)
end

-- 找 need 张最小翅膀（wkind 1=单张 2=对子），避开 [lo,hi] 区间、炸弹与王
local function smallest_wings(cnt, m, lo, hi, need, wkind)
  local out = {}
  if wkind == 1 then
    for pass = 1, 2 do
      for r = 3, 15 do
        if r < lo or r > hi then
          local c = cnt[r] or 0
          if #out < need and ((pass == 1 and c == 1) or (pass == 2 and c == 2)) then
            out[#out + 1] = m[r][1]
          end
        end
      end
      if #out >= need then break end
    end
    if #out >= need then return out end
  else
    for r = 3, 15 do
      if (r < lo or r > hi) and (cnt[r] or 0) == 2 and #out < need * 2 then
        out[#out + 1] = m[r][1]
        out[#out + 1] = m[r][2]
      end
    end
    if #out >= need * 2 then return out end
  end
  return nil
end

-- 同型最小压牌（非炸）；返回 cards 或 nil
local function minimal_beat(hand, last)
  local cnt = hand_cnt(hand)
  local m = by_rank(hand)
  local k = last.kind

  if k == "single" then
    for pass = 1, 4 do
      for r = last.main + 1, 17 do
        local c = cnt[r] or 0
        local ok = (pass == 1 and c == 1 and r <= 15) or (pass == 2 and c == 2)
          or (pass == 3 and c == 1 and r >= 16) or (pass == 4 and c == 3)
        if ok then return {m[r][1]} end
      end
    end
    return nil
  end

  if k == "pair" then
    for pass = 1, 2 do
      for r = last.main + 1, 15 do
        local c = cnt[r] or 0
        if (pass == 1 and c == 2) or (pass == 2 and c == 3) then
          return {m[r][1], m[r][2]}
        end
      end
    end
    return nil
  end

  if k == "trio" or k == "trio1" or k == "trio2" then
    for r = last.main + 1, 15 do
      if (cnt[r] or 0) == 3 then
        local cs = {m[r][1], m[r][2], m[r][3]}
        if k == "trio1" then
          local w = smallest_wings(cnt, m, r, r, 1, 1)
          if not w then return nil end
          cs[4] = w[1]
        elseif k == "trio2" then
          local w = smallest_wings(cnt, m, r, r, 1, 2)
          if not w then return nil end
          cs[4] = w[1] cs[5] = w[2]
        end
        return cs
      end
    end
    return nil
  end

  if k == "straight" or k == "pairseq" or k == "plane"
    or k == "plane1" or k == "plane2" then
    local L, need
    if k == "straight" then need = 1
    elseif k == "pairseq" then need = 2
    else need = 3 end
    L = last.len
    for top = last.main + 1, 14 do
      local lo = top - L + 1
      if lo >= 3 then
        local ok = true
        for r = lo, top do
          if (cnt[r] or 0) < need then ok = false break end
        end
        if ok then
          local cs = {}
          for r = lo, top do
            for x = 1, need do cs[#cs + 1] = m[r][x] end
          end
          if k == "plane1" or k == "plane2" then
            local w = smallest_wings(cnt, m, lo, top, L, k == "plane1" and 1 or 2)
            if not w then ok = false end
            if ok then
              for i = 1, #w do cs[#cs + 1] = w[i] end
            end
          end
          if ok then return cs end
        end
      end
    end
    return nil
  end

  if k == "four2" or k == "four2pair" then
    for r = last.main + 1, 15 do
      if (cnt[r] or 0) == 4 then
        local w = smallest_wings(cnt, m, r, r, 2, k == "four2" and 1 or 2)
        if w then
          local cs = {m[r][1], m[r][2], m[r][3], m[r][4]}
          for i = 1, #w do cs[#cs + 1] = w[i] end
          return cs
        end
      end
    end
    return nil
  end

  return nil -- 炸弹/王炸交给炸弹路径
end

-- 是否值得动用炸弹
local function should_bomb(seat, last)
  if last.kind == "rocket" then return false end
  if last.kind == "bomb" then return true end
  if opp_cards(seat) <= 5 then return true end
  if #hands[seat] <= 7 then return true end
  if last.main >= 14 and (last.kind == "single" or last.kind == "pair"
    or last.kind == "trio") then return true end
  return false
end

-- AI 决策：返回要出的 cards 或 nil（过）
local function ai_decide(seat)
  local hand = hands[seat]
  if #hand == 0 then return nil end
  if last_play == nil then
    return ai_lead(seat)
  end
  local last = last_play.combo
  -- 整手能直接压过 → 一手出完
  local whole = analyze(hand)
  if whole and beats(whole, last) then return copy_cards(hand) end
  -- 队友领先：让牌（能整手出完的情形上面已处理）
  if is_friend(seat, last_play.seat) then return nil end
  local c = minimal_beat(hand, last)
  if c then return c end
  if should_bomb(seat, last) then
    local cnt = hand_cnt(hand)
    local m = by_rank(hand)
    local base = 2
    if last.kind == "bomb" then base = last.main end
    for r = base + 1, 15 do
      if cnt[r] == 4 then
        return {m[r][1], m[r][2], m[r][3], m[r][4]}
      end
    end
    if cnt[16] and cnt[17]
      and (last.kind == "bomb" or opp_cards(seat) <= 3 or #hand <= 6) then
      return {64, 68}
    end
  end
  return nil
end

-- ================================================================ 音频（SPEC §5.2）

local function u8(a, v) poke(a, v % 256) end

-- steps: {{音高, 波形, 音量, 效果?}, ...}；音高 0 = 休止
local function sfx_steps(id, speed, steps)
  local base = 0x060000 + id * 112
  u8(base, speed)
  u8(base + 1, #steps)
  for i = 0, 31 do
    local a = base + 16 + i * 3
    local st = steps[i + 1]
    if st then
      u8(a, st[1] or 0) -- 音高 0 = 休止
      u8(a + 1, (st[2] or 0) * 16 + (st[3] or 0))
      u8(a + 2, st[4] or 0)
    else
      u8(a, 0)
      u8(a + 1, 0)
    end
  end
end

local function init_audio()
  sfx_steps(0, 1, {{76, 15, 4}})                                       -- 发牌嗒
  sfx_steps(1, 1, {{68, 3, 5}})                                        -- 选牌
  sfx_steps(2, 1, {{0, 15, 8}, {40, 3, 9, 3}, {31, 3, 7}})             -- 出牌
  sfx_steps(3, 1, {{30, 11, 7}, {25, 11, 5}})                          -- 不要
  sfx_steps(4, 1, {{62, 15, 15}, {54, 14, 14}, {46, 14, 12},           -- 炸弹
    {38, 3, 11, 3}, {30, 3, 9, 3}, {22, 3, 7, 3}, {16, 3, 5, 3}})
  sfx_steps(5, 1, {{72, 15, 15}, {64, 14, 15}, {54, 14, 14},           -- 王炸
    {44, 14, 12}, {50, 3, 12}, {38, 3, 10, 3}, {26, 3, 8, 3}, {14, 3, 6, 3}})
  sfx_steps(6, 1, {{64, 3, 7}, {69, 3, 7}})                            -- 叫分
  sfx_steps(7, 2, {{64, 3, 8}, {69, 3, 8}, {76, 3, 9}})                -- 叫 3 分
  sfx_steps(8, 4, {{60, 3, 9}, {64, 3, 9}, {67, 3, 10},                -- 胜利
    {72, 3, 11}, {76, 3, 12}, {79, 3, 12}})
  sfx_steps(9, 5, {{67, 3, 8}, {62, 3, 8}, {58, 3, 7},                 -- 失败
    {52, 3, 6}, {45, 3, 5}})
  sfx_steps(10, 1, {{26, 3, 8}, {26, 3, 6}})                           -- 非法提示
  sfx_steps(11, 1, {{72, 3, 6}, {79, 3, 6}})                           -- 提示
  sfx_steps(12, 1, {{58, 3, 4}})                                       -- 光标
  sfx_steps(13, 2, {{79, 10, 8}, {84, 10, 8}, {88, 10, 9}})            -- 春天星音
  sfx_steps(14, 2, {{56, 3, 9}, {61, 3, 9}, {64, 3, 10}, {69, 3, 11}}) -- 地主揭晓
  -- BGM（Pattern 0 回环，ch6 贝斯 + ch7 旋律，进行 C-Am-F-G）
  sfx_steps(20, 5, {
    {37, 0, 6}, {0}, {44, 0, 5}, {0}, {37, 0, 6}, {0}, {44, 0, 5}, {0},
    {34, 0, 6}, {0}, {41, 0, 5}, {0}, {34, 0, 6}, {0}, {41, 0, 5}, {0},
    {30, 0, 6}, {0}, {37, 0, 5}, {0}, {30, 0, 6}, {0}, {37, 0, 5}, {0},
    {32, 0, 6}, {0}, {39, 0, 5}, {0}, {32, 0, 6}, {0}, {39, 0, 5}, {0},
  })
  sfx_steps(21, 5, {
    {0}, {0}, {61, 8, 4}, {0}, {0}, {0}, {63, 8, 4}, {0},
    {0}, {0}, {65, 8, 4}, {0}, {0}, {0}, {61, 8, 4}, {0},
    {0}, {0}, {63, 8, 4}, {0}, {0}, {0}, {65, 8, 4}, {0},
    {0}, {0}, {68, 8, 4}, {0}, {0}, {0}, {0}, {0},
  })
  local mb = 0x063800
  u8(mb + 6, 21) -- ch6 ← SFX 20
  u8(mb + 7, 22) -- ch7 ← SFX 21
  u8(mb + 8, 3)  -- BEGIN|END 回环
end

-- ================================================================ 游戏状态

local state          -- title / deal / bid / play / settle
local t              -- 全局幀计数（动画）
local deck           -- 洗好的 54 张
local bottom         -- 3 张底牌
local bottom_up      -- 底牌是否明示
local bid_cnt, high, high_seat
local bid_turn, bid_cursor, bid_phase, conclude_t
local OPTS = {0, 1, 2, 3}
local OPT_LABEL = {"不叫", "1分", "2分", "3分"}
local turn, think
local bomb_cnt, over_seat, end_t, final_bid
local sel, cur       -- 玩家选牌 / 光标
local msg, msg_c, msg_t
local bubble         -- AI 叫分气泡 {txt, t}
local plays_disp     -- 各家出牌展示 {cards,anim} / {pass=true}
local shake_t, flash_t
local settle         -- 结算信息
local score, games   -- 存档：累计积分 / 局数
local deal_i, deal_t
local rep_dir, rep_t -- 方向键重复

local function fmt(n) return string.format("%d", n) end

local function mult_now()
  local m = 1
  for i = 1, bomb_cnt do m = m * 2 end
  return m
end

local function say(s, c, dur)
  msg = s
  msg_c = c or 22
  msg_t = dur or 90
end

local function build_deck()
  deck = {}
  for r = 3, 15 do
    for s = 0, 3 do deck[#deck + 1] = r * 4 + s end
  end
  deck[#deck + 1] = 64
  deck[#deck + 1] = 68
  for i = #deck, 2, -1 do
    local j = flr(rnd(i)) + 1
    deck[i], deck[j] = deck[j], deck[i]
  end
end

local function remove_cards(seat, cs)
  local h = hands[seat]
  for _, c in ipairs(cs) do
    for i = 1, #h do
      if h[i] == c then table.remove(h, i) break end
    end
  end
end

-- 轮到玩家时的提示
local function on_player_turn()
  if last_play == nil then
    say("轮到你先出牌", 22)
    return
  end
  local can = minimal_beat(hands[1], last_play.combo) ~= nil
  if not can then
    local cnt = hand_cnt(hands[1])
    local bb = 2
    if last_play.combo.kind == "bomb" then bb = last_play.combo.main end
    for r = bb + 1, 15 do
      if cnt[r] == 4 then can = true break end
    end
    if cnt[16] and cnt[17] then can = true end
  end
  if can then
    say("轮到你出牌", 22)
  else
    say("要不起，Ⓨ不要", 10)
  end
end

local function do_pass(seat)
  plays_disp[seat] = {pass = true}
  if seat == 1 then
    say("你不要", 10, 55)
  else
    say(SEAT_NAME[seat] .. "：不要", 10, 55)
  end
  sfx(3)
  local leader = last_play.seat
  turn = next_seat(seat)
  if turn == leader then
    -- 连续两家不要：新一轮由最后出牌者任意出，只保留其上一手
    last_play = nil
    for s = 1, 3 do
      if s ~= leader then plays_disp[s] = nil end
    end
  end
  if turn ~= 1 then
    think[turn] = 26 + t % 5
  else
    on_player_turn()
  end
end

local function commit_play(seat, cs)
  if cs ~= nil and #cs > 0 then
    local combo = analyze(cs)
    local ok = combo ~= nil and (last_play == nil or beats(combo, last_play.combo))
    if ok then
      local fresh = (last_play == nil)
      remove_cards(seat, cs)
      played_cnt[seat] = played_cnt[seat] + 1
      last_play = {seat = seat, combo = combo}
      if fresh then
        for s = 1, 3 do
          if s ~= seat then plays_disp[s] = nil end
        end
      end
      plays_disp[seat] = {cards = cs, anim = 12}
      if combo.kind == "rocket" then
        bomb_cnt = bomb_cnt + 1
        shake_t = 18
        flash_t = 16
        sfx(5)
      elseif combo.kind == "bomb" then
        bomb_cnt = bomb_cnt + 1
        shake_t = 13
        sfx(4)
      else
        sfx(2)
      end
      if seat == 1 then
        sel = {}
        cur = mid(1, cur, max(1, #hands[1]))
      end
      if #hands[seat] == 0 then
        over_seat = seat
        end_t = 60
        say((seat == 1 and "你" or SEAT_NAME[seat]) .. "率先出完！", 30)
        return true
      end
      turn = next_seat(seat)
      if turn ~= 1 then
        think[turn] = 26 + t % 5
      else
        on_player_turn()
      end
      return true
    end
    if seat == 1 then return false end -- 玩家路径已预检
    cs = nil -- AI 兜底转为过（正常不会发生）
  end
  do_pass(seat)
  return false
end

-- ================================================================ 玩家输入（出牌阶段）

local function player_input()
  local n = #hands[1]
  -- 光标左右（自实现按住重复）
  if n > 0 then
    local dir = 0
    if dir(0) then dir = dir - 1 end
    if dir(1) then dir = dir + 1 end
    if dir ~= 0 then
      if dir ~= rep_dir then
        rep_dir = dir
        rep_t = 0
        cur = mid(1, cur + dir, n)
        sfx(12)
      else
        rep_t = rep_t + 1
        if rep_t > 10 and rep_t % 4 == 0 then
          cur = mid(1, cur + dir, n)
        end
      end
    else
      rep_dir = 0
    end
  end
  if dirp(2) or btnp(4) then -- ↑/Ⓐ 抬起或放回
    if n > 0 then
      sel[cur] = not sel[cur]
      sfx(1)
    end
  end
  if dirp(3) then -- ↓ 放回当前牌
    if sel[cur] then
      sel[cur] = false
      sfx(1)
    end
  end
  if btnp(5) then -- Ⓑ 清空选择
    local had = false
    for i = 1, n do
      if sel[i] then sel[i] = false had = true end
    end
    if had then sfx(1) end
  end
  if btnp(9) then -- Ⓡ 提示（复用 AI 逻辑）
    local cs = ai_decide(1)
    if cs and #cs > 0 then
      sel = {}
      for i = 1, n do
        for _, c in ipairs(cs) do
          if hands[1][i] == c then sel[i] = true end
        end
      end
      say("建议出牌", 22, 60)
      sfx(11)
    else
      say(last_play == nil and "先出任意合法牌型" or "建议不要", 10, 60)
      sfx(11)
    end
  end
  if btnp(6) then -- Ⓧ 出牌
    local cs = {}
    for i = 1, n do
      if sel[i] then cs[#cs + 1] = hands[1][i] end
    end
    if #cs == 0 then
      say("请先选牌", 10)
      sfx(10)
    else
      local combo = analyze(cs)
      if combo == nil then
        say("不是合法牌型", 10)
        sfx(10)
      elseif last_play and not beats(combo, last_play.combo) then
        say("压不过上家", 10)
        sfx(10)
      else
        commit_play(1, cs)
      end
    end
  end
  if btnp(7) then -- Ⓨ 不要
    if last_play == nil then
      say("轮到你先出，不能过", 10)
      sfx(10)
    else
      commit_play(1, nil)
    end
  end
end

-- ================================================================ 流程

local function finish_game()
  local winner = over_seat
  local m = mult_now()
  local spring = false
  if winner == landlord then
    -- 地主胜且两农民一张未出 → 春天
    local a, b = next_seat(landlord), next_seat(next_seat(landlord))
    if played_cnt[a] == 0 and played_cnt[b] == 0 then spring = true end
  else
    -- 农民胜且地主只出过首手 → 反春
    if played_cnt[landlord] <= 1 then spring = true end
  end
  if spring then m = m * 2 end
  local pts = final_bid * m
  local lw = (winner == landlord)
  local delta
  if landlord == 1 then
    delta = lw and 2 * pts or -2 * pts
  else
    delta = lw and -pts or pts
  end
  score = score + delta
  games = games + 1
  dset(0, score)
  dset(1, games)
  fflush()
  settle = {win = lw, player_win = (landlord == 1) == lw, delta = delta,
    base = final_bid, mult = m, bombs = bomb_cnt, spring = spring}
  state = "settle"
  music(-1, 200)
  sfx(((landlord == 1) == lw) and 8 or 9)
  if spring then sfx(13) end
end

local function start_new_game()
  build_deck()
  hands = {{}, {}, {}}
  bottom = {}
  bottom_up = false
  landlord = 0
  plays_disp = {}
  bubble = {}
  played_cnt = {0, 0, 0}
  bomb_cnt = 0
  last_play = nil
  over_seat = nil
  end_t = 0
  sel = {}
  cur = 1
  think = {0, 0, 0}
  state = "deal"
  deal_i = 0
  deal_t = 0
  msg_t = 0
  music(-1, 100)
  say("发牌中…", 10, 200)
end

local function update_play()
  if over_seat then
    end_t = end_t - 1
    if end_t <= 0 then finish_game() end
    return
  end
  if turn == 1 then
    player_input()
  else
    think[turn] = think[turn] - 1
    if think[turn] <= 0 then
      local cs = ai_decide(turn)
      commit_play(turn, cs)
    end
  end
end

local function opt_avail(i)
  return i == 1 or OPTS[i] > high
end

local function advance_bid()
  bid_cnt = bid_cnt + 1
  if high == 3 or bid_cnt >= 3 then
    bid_phase = "conclude"
    conclude_t = 55
  else
    bid_turn = next_seat(bid_turn)
    if bid_turn ~= 1 then
      think[bid_turn] = 30 + t % 5
    else
      bid_cursor = (high < 1) and 2 or 1
    end
  end
end

local function update_bid()
  if bid_phase == "conclude" then
    conclude_t = conclude_t - 1
    if conclude_t <= 0 then
      if high == 0 then
        say("无人叫地主，重新发牌", 10)
        bid_phase = "redeal"
        conclude_t = 80
      else
        landlord = high_seat
        final_bid = high
        for i = 1, 3 do
          hands[landlord][#hands[landlord] + 1] = bottom[i]
        end
        sort_hand(hands[landlord])
        if landlord == 1 then
          sel = {}
          cur = mid(1, cur, #hands[1])
        end
        bottom_up = true
        say(SEAT_NAME[landlord] .. "是地主！底分" .. final_bid, 30, 100)
        sfx(14)
        bid_phase = "reveal"
        conclude_t = 100
      end
    end
  elseif bid_phase == "reveal" then
    conclude_t = conclude_t - 1
    if conclude_t <= 0 then
      state = "play"
      turn = landlord
      music(0, 500, 0xC0)
      if turn ~= 1 then
        think[turn] = 26 + t % 5
      else
        on_player_turn()
      end
    end
  elseif bid_phase == "redeal" then
    conclude_t = conclude_t - 1
    if conclude_t <= 0 then start_new_game() end
  elseif bid_turn == 1 then
    -- 玩家叫分
    if dirp(0) or dirp(1) then
      local dir = dirp(0) and -1 or 1
      local i = bid_cursor
      repeat
        i = i + dir
        if i < 1 then i = 4 elseif i > 4 then i = 1 end
      until i == bid_cursor or opt_avail(i)
      if opt_avail(i) then
        bid_cursor = i
        sfx(12)
      end
    end
    if btnp(4) then
      local v = OPTS[bid_cursor]
      if v > high then
        high = v
        high_seat = 1
      end
      say(v == 0 and "你不叫" or ("你叫 " .. v .. " 分"), v > 0 and 22 or 10, 70)
      sfx(v == 3 and 7 or 6)
      advance_bid()
    end
  else
    -- AI 叫分
    think[bid_turn] = think[bid_turn] - 1
    if think[bid_turn] <= 0 then
      local s = bid_turn
      local str = hand_strength(hands[s])
      local v = 0
      if str >= 13 and high < 3 then v = 3
      elseif str >= 8 and high < 2 then v = 2
      elseif str >= 5 and high < 1 then v = 1 end
      if v > high then
        high = v
        high_seat = s
      end
      bubble[s] = {txt = v == 0 and "不叫" or (v .. " 分"), t = 90}
      sfx(v == 3 and 7 or 6)
      advance_bid()
    end
  end
end

local function update_deal()
  deal_t = deal_t + 1
  if deal_i < 51 and deal_t % 3 == 0 then
    deal_i = deal_i + 1
    local seat = (deal_i - 1) % 3 + 1
    hands[seat][#hands[seat] + 1] = deck[deal_i]
    if seat == 1 then sort_hand(hands[1]) end
    sfx(0)
  end
  if deal_i >= 51 and deal_t >= 51 * 3 + 30 then
    bottom = {deck[52], deck[53], deck[54]}
    for s = 1, 3 do sort_hand(hands[s]) end
    state = "bid"
    bid_cnt = 0
    high, high_seat = 0, 1
    bid_phase = "speak"
    bid_turn = (flr(rnd(3)) | 0) + 1
    bid_cursor = 2
    if bid_turn ~= 1 then
      think[bid_turn] = 30
    end
    say(SEAT_NAME[bid_turn] .. "先叫分", 22)
  end
end

-- ================================================================ 绘制：卡牌

local function draw_back(x, y, w, h)
  rectfill(x, y, w, h, 7)
  rectfill(x + 1, y + 1, w - 2, h - 2, C_BACK)
  if w >= 16 and h >= 20 then
    fillp(0x8142)
    rectfill(x + 3, y + 3, w - 6, h - 6, 63 * 256 + C_BACK)
    fillp()
  else
    rectfill(flr(x + w / 2) - 2, flr(y + h / 2) - 2, 4, 4, 63)
  end
end

-- 标准牌 20×28：左上角迷你点数 + 花色，右下角小花色
local function draw_card(x, y, c, on)
  rectfill(x, y, CW, CH, 7)
  if on then
    rect(x - 1, y - 1, CW + 2, CH + 2, C_GOLD2)
    rect(x, y, CW, CH, C_GOLD)
  else
    rect(x, y, CW, CH, 3)
  end
  local r = rank_of(c)
  local col = card_col(c)
  if r >= 16 then
    glyph(JOKER_G, x + 2, y + 3, col, 1, 5)
    glyph(JOKER_G, x + 12, y + 18, col, 1, 5)
  else
    local s = RANK_STR[r - 2]
    local gx = x + 2
    for i = 1, #s do
      glyph(GLYPH[s:sub(i, i)], gx, y + 3, col, 1, 3)
      gx = gx + 4
    end
    glyph(SUIT_G[c % 4 + 1], x + 2, y + 10, col, 1, 5)
    glyph(SUIT_G[c % 4 + 1], x + 12, y + 19, col, 1, 5)
  end
end

-- 放大牌（南家出牌 sc=2 / 标题 sc=3），迷你字形同倍放大
local function draw_card_big(x, y, c, sc)
  rectfill(x, y, 20 * sc, 28 * sc, 7)
  rect(x, y, 20 * sc, 28 * sc, 3)
  local r = rank_of(c)
  local col = card_col(c)
  if r >= 16 then
    glyph(JOKER_G, x + 3 * sc, y + 3 * sc, col, sc, 5)
    glyph(JOKER_G, x + 12 * sc, y + 18 * sc, col, sc, 5)
  else
    local s = RANK_STR[r - 2]
    local gx = x + 2 * sc
    for i = 1, #s do
      glyph(GLYPH[s:sub(i, i)], gx, y + 2 * sc, col, sc, 3)
      gx = gx + 4 * sc
    end
    glyph(SUIT_G[c % 4 + 1], x + 2 * sc, y + 9 * sc, col, sc, 5)
    glyph(SUIT_G[c % 4 + 1], x + 12 * sc, y + 19 * sc, col, sc, 5)
  end
end

-- 底牌迷你牌 12×17
local function draw_mini(x, y, c, up)
  if not up then
    draw_back(x, y, 12, 17)
    return
  end
  rectfill(x, y, 12, 17, 7)
  rect(x, y, 12, 17, 3)
  local r = rank_of(c)
  local col = card_col(c)
  if r >= 16 then
    glyph(JOKER_G, x + 3, y + 4, col, 1, 5)
  else
    local s = RANK_STR[r - 2]
    local gx = x + 1
    for i = 1, #s do
      glyph(GLYPH[s:sub(i, i)], gx, y + 2, col, 1, 3)
      gx = gx + 4
    end
    glyph(SUIT_G[c % 4 + 1], x + 3, y + 9, col, 1, 5)
  end
end

-- 地主皇冠
local function crown(x, y)
  trifill(x, y + 4, x + 2, y, x + 4, y + 4, C_GOLD2)
  trifill(x + 3, y + 4, x + 5, y, x + 7, y + 4, C_GOLD2)
  trifill(x + 6, y + 4, x + 8, y, x + 10, y + 4, C_GOLD2)
  rectfill(x, y + 4, 11, 2, C_GOLD)
end

-- ================================================================ 绘制：场景

local function draw_room()
  cls(C_RIM)
  rrectfill(6, 23, 244, 168, 10, C_TABLE)
  rrect(6, 23, 244, 168, 10, C_TABLE_HI)
  fillp(0x1084)
  rectfill(10, 27, 236, 160, C_TABLE_HI * 256 + C_TABLE)
  fillp()
  circ(128, 102, 32, C_TABLE_HI)
  rectfill(0, 190, 256, 66, C_BG)
  line(0, 190, 255, 190, C_STRIP)
end

local function draw_panel(x, seat)
  local is_l = (landlord == seat and landlord > 0 and state ~= "deal")
  rectfill(x, 2, 76, 17, C_PANEL)
  rect(x, 2, 76, 17, is_l and C_GOLD or C_PANEL_BD)
  draw_back(x + 3, 4, 8, 12)
  print(SEAT_NAME[seat], x + 14, 3, C_CREAM)
  print(fmt(#hands[seat]), x + 48, 3, 23)
  if is_l then crown(x + 64, 5) end
  -- 思考指示
  if state == "play" and turn == seat and not over_seat then
    local nd = flr(t / 10) % 3 + 1
    for i = 1, nd do
      circfill(x + 52 + i * 4, 18, 1, C_GOLD2)
    end
  end
end

local function draw_strip()
  rectfill(0, 0, 256, 21, C_STRIP)
  line(0, 21, 255, 21, C_BG)
  draw_panel(2, 3)   -- 西
  draw_panel(178, 2) -- 东
  if #bottom == 3 then
    print("底牌", 78, 3, C_DIM)
    for i = 1, 3 do
      draw_mini(110 + (i - 1) * 15, 2, bottom[i], bottom_up)
    end
  end
  -- 轮到东/西家的箭头指示
  if state == "play" and not over_seat then
    local pu = 3 + flr(sin(t / 12) * 2 + 2)
    if turn == 3 then
      trifill(88, 6, 88, 18, 79, 12, pu + 27)
    elseif turn == 2 then
      trifill(168, 6, 168, 18, 177, 12, pu + 24)
    end
  end
end

local function draw_play_row(seat)
  local d = plays_disp[seat]
  if d == nil then return end
  local cx, y = PLAY_CX[seat], PLAY_Y[seat]
  if d.pass then
    print("不要", cx - 16, y + (seat == 1 and 16 or 6), C_DIM)
    return
  end
  local n = #d.cards
  local big = (seat == 1)
  local cw2 = big and 40 or CW
  local sp = 0
  if n > 1 then
    sp = min(big and 18 or 10, flr((PLAY_W[seat] - cw2) / (n - 1)))
  end
  local total = (n - 1) * sp + cw2
  local x0 = flr(cx - total / 2)
  local dy = (d.anim or 0) > 0 and -flr((d.anim or 0) / 4) or 0
  for i = 1, n do
    local x = x0 + (i - 1) * sp
    if big then
      draw_card_big(x, y + dy, d.cards[i], 2)
    else
      draw_card(x, y + dy, d.cards[i], false)
    end
  end
end

local function draw_bubble(seat)
  local b = bubble[seat]
  if b == nil or b.t <= 0 then return end
  local w = tw(b.txt) + 8
  local x = (seat == 3) and 10 or (246 - w)
  rectfill(x, 24, w, 16, 7)
  print(b.txt, x + 4, 25, C_PANEL)
end

local function draw_hand()
  local h = hands[1]
  local n = #h
  if n == 0 then return end
  local sp = 12
  if n > 1 then sp = min(12, flr(236 / (n - 1))) end
  local total = (n - 1) * sp + CW
  local x0 = flr((256 - total) / 2)
  for i = 1, n do
    draw_card(x0 + (i - 1) * sp, HY - (sel[i] and 8 or 0), h[i], sel[i])
  end
  -- 光标三角（呼吸）
  local cx = x0 + (cur - 1) * sp + 7
  local cy = (sel[cur] and HY - 8 or HY) - 9 - flr(sin(t / 15) * 2 + 2)
  trifill(cx, cy, cx + 6, cy, cx + 3, cy + 6, C_GOLD2)
end

local function draw_msg()
  if state == "play" and not over_seat then
    print("你是" .. (landlord == 1 and "地主" or "农民"), 4, 168,
      landlord == 1 and C_GOLD or C_CREAM)
    local ms = "底分" .. final_bid .. " ×" .. mult_now()
    print(ms, 252 - tw(ms), 168, 23)
  end
  if msg_t > 0 then
    print(msg, (256 - tw(msg)) / 2, 168, msg_c)
  end
end

local function draw_bidbox()
  if bid_turn == 1 then
    local info
    if high > 0 then
      info = "当前 " .. SEAT_NAME[high_seat] .. " " .. high .. " 分"
    else
      info = "请你先叫分"
    end
    print(info, (256 - tw(info)) / 2, 52, C_CREAM)
    for i = 1, 4 do
      local bx = 18 + (i - 1) * 56
      local av = opt_avail(i)
      rectfill(bx, 74, 52, 20, av and C_PANEL or C_STRIP)
      rect(bx, 74, 52, 20, i == bid_cursor and C_GOLD2 or C_PANEL_BD)
      print(OPT_LABEL[i], bx + (52 - tw(OPT_LABEL[i])) / 2, 77, av and C_CREAM or C_DIM)
    end
    local hs = "←→选择 Ⓐ确认"
    print(hs, (256 - tw(hs)) / 2, 102, C_DIM)
  else
    local s = SEAT_NAME[bid_turn] .. "思考中" .. string.rep(".", flr(t / 15) % 4)
    print(s, (256 - tw(s)) / 2, 86, C_DIM)
  end
end

local function draw_deal_anim()
  -- 中央牌堆
  draw_back(122, 84, 16, 22)
  draw_back(120, 82, 16, 22)
  if deal_i >= 1 and deal_i <= 51 then
    local seat = (deal_i - 1) % 3 + 1
    local p = (deal_t - (deal_i - 1) * 3) / 3
    if p > 0 and p <= 1 then
      local tx, ty = DEAL_TO[seat][1], DEAL_TO[seat][2]
      local x = 122 + (tx - 122) * p
      local y = 92 + (ty - 92) * p
      draw_back(flr(x) - 6, flr(y) - 8, 12, 16)
    end
  end
end

local function draw_settle()
  fillp(0xa5a5)
  rectfill(0, 0, 256, 256, C_STRIP * 256 + C_BG)
  fillp()
  local x, y, w, h = 40, 40, 176, 170
  rectfill(x - 2, y - 2, w + 4, h + 4, 0)
  rectfill(x, y, w, h, 15)
  rect(x, y, w, h, C_GOLD)
  local s2 = settle.win and "地主胜利" or "农民胜利"
  print(s2, (256 - tw(s2)) / 2, y + 8, settle.win and C_GOLD or 23)
  local s1 = settle.player_win and "你赢了！" or "你输了"
  print(s1, (256 - tw(s1)) / 2, y + 28, settle.player_win and 29 or C_RED)
  local lines = {
    {"底分 " .. settle.base, C_CREAM},
    {"倍数 ×" .. settle.mult, C_CREAM},
  }
  if settle.bombs > 0 then
    lines[#lines + 1] = {"炸弹/王炸 " .. settle.bombs .. " 个", C_CREAM}
  end
  if settle.spring then
    lines[#lines + 1] = {"春天！×2", 29}
  end
  local ds = (settle.delta >= 0 and "+" or "") .. fmt(settle.delta)
  lines[#lines + 1] = {"本局 " .. ds, settle.delta >= 0 and C_GOLD or C_RED}
  lines[#lines + 1] = {"累计 " .. fmt(score) .. " 分 ・ " .. games .. " 局", C_DIM}
  local yy = y + 52
  for _, l in ipairs(lines) do
    print(l[1], (256 - tw(l[1])) / 2, yy, l[2])
    yy = yy + 15
  end
  if flr(t / 20) % 2 == 0 then
    local s = "Ⓐ 再来一局"
    print(s, (256 - tw(s)) / 2, y + h - 22, C_GOLD2)
  end
end

local function draw_title()
  cls(C_RIM)
  rrectfill(14, 8, 228, 240, 12, C_TABLE)
  rrect(14, 8, 228, 240, 12, C_TABLE_HI)
  fillp(0x1084)
  rectfill(18, 12, 220, 232, C_TABLE_HI * 256 + C_TABLE)
  fillp()
  draw_card_big(34, 34, 14 * 4, 3)     -- ♠A
  draw_card_big(98, 26, 13 * 4 + 1, 3) -- ♥K
  draw_card_big(162, 34, 68, 3)        -- 大王
  local s = "斗地主"
  local x = (256 - tw(s)) / 2
  print(s, x + 1, 142, 26)
  print(s, x - 1, 140, C_GOLD2)
  local s2 = "经典三人纸牌"
  print(s2, (256 - tw(s2)) / 2, 164, C_CREAM)
  local s3 = "积分 " .. fmt(score) .. " ・ " .. games .. " 局"
  print(s3, (256 - tw(s3)) / 2, 188, C_DIM)
  if flr(t / 20) % 2 == 0 then
    local s4 = "Ⓐ 开始游戏"
    print(s4, (256 - tw(s4)) / 2, 212, C_GOLD)
  end
end

-- ================================================================ 生命周期

function _init()
  init_audio()
  score = dget(0)
  games = dget(1)
  hands = {{}, {}, {}}
  bottom = {}
  plays_disp = {}
  bubble = {}
  think = {0, 0, 0}
  sel = {}
  cur = 1
  landlord = 0
  state = "title"
  t = 0
  msg_t = 0
  shake_t = 0
  flash_t = 0
end

function _update()
  t = t + 1
  if msg_t > 0 then msg_t = msg_t - 1 end
  if shake_t > 0 then shake_t = shake_t - 1 end
  if flash_t > 0 then flash_t = flash_t - 1 end
  for s = 1, 3 do
    local b = bubble[s]
    if b and b.t > 0 then b.t = b.t - 1 end
    local d = plays_disp[s]
    if d and d.anim and d.anim > 0 then d.anim = d.anim - 1 end
  end
  if state == "title" then
    if btnp(4) or btnp(11) then start_new_game() end
  elseif state == "deal" then
    update_deal()
  elseif state == "bid" then
    update_bid()
  elseif state == "play" then
    update_play()
  elseif state == "settle" then
    if btnp(4) or btnp(11) then start_new_game() end
  end
end

function _draw()
  if shake_t > 0 then
    camera(flr(rnd(5)) - 2, flr(rnd(5)) - 2)
  end
  if state == "title" then
    draw_title()
  else
    draw_room()
    draw_strip()
    draw_play_row(2)
    draw_play_row(3)
    draw_bubble(2)
    draw_bubble(3)
    draw_play_row(1)
    draw_msg()
    if state == "bid" and bid_phase == "speak" then draw_bidbox() end
    draw_hand()
    if state == "deal" then draw_deal_anim() end
    if state == "play" and turn == 1 and not over_seat then
      local s = "←→选Ⓐ抬Ⓑ清Ⓧ出Ⓨ过Ⓡ提示"
      print(s, (256 - tw(s)) / 2, 232, C_DIM)
    end
    if state == "settle" then draw_settle() end
  end
  if flash_t > 0 and flr(flash_t / 3) % 2 == 0 then
    rect(2, 2, 252, 252, C_RED)
    rect(4, 4, 248, 248, C_RED)
  end
  camera(0, 0)
end
