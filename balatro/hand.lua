-- 牌型判定：评估选中牌的牌型与计分牌
-- ------------------------------------------------------------ 牌型判定
local function has(id)
  for _, o in ipairs(G.jk) do if o.id == id then return true end end
  return false
end
function is_face(c)
  return c.r >= 9 or has(46)   -- J/Q/K；似人小丑全场人面
end
function straight_len() return has(50) and 4 or 5 end
local CONTAINED = {}
function contained(k) return CONTAINED[k] == true end

-- 评估选中的牌：返回 kind（HANDS 下标）与计分牌集合
function eval_hand(cards)
  local n = #cards
  local cnt, suitc = {}, {}
  local best = { k = HK_HI, cards = { cards[1] } }
  for i, c in ipairs(cards) do
    cnt[c.r] = (cnt[c.r] or 0) + 1
    suitc[c.s] = (suitc[c.s] or 0) + 1
    if c.r > (best.cards[1] or { r = -1 }).r then best.cards[1] = c end
  end
  local function take_rank(r, into)
    for _, c in ipairs(cards) do if c.r == r then into[#into + 1] = c end end
  end
  local function take_suit(s, into)
    for _, c in ipairs(cards) do if c.s == s then into[#into + 1] = c end end
  end
  -- 同花（四指时 4 张）
  local fs, fn = nil, 0
  for s = 0, 3 do if (suitc[s] or 0) > fn then fs, fn = s, suitc[s] end end
  local flush_cards = {}
  if fn >= straight_len() then take_suit(fs, flush_cards) end
  -- 顺子（A 可低位；捷径隔 1）：在去重点数上找最长游程
  local rs = {}
  for r = 0, 12 do if cnt[r] then rs[#rs + 1] = r end end
  local function find_run()
    local gap, bl = has(48) and 2 or 1, straight_len()
    local best_run = {}
    for a = 1, #rs do
      local run, last = { rs[a] }, rs[a]
      for b = a + 1, #rs do
        if rs[b] - last <= gap and rs[b] - last >= 1 then
          run[#run + 1] = rs[b] last = rs[b]
        else break end
      end
      if #run >= bl and #run > #best_run then best_run = run end
    end
    -- A 低位：A-2-3-4(5)
    local low = {}
    for r = 0, bl - 2 do if cnt[r] then low[#low + 1] = r end end
    if cnt[12] and #low == bl - 1 then
      low[#low + 1] = 12
      if #low > #best_run then best_run = low end
    end
    return best_run
  end
  local run = find_run()
  local straight_cards = {}
  if #run >= straight_len() then
    for _, r in ipairs(run) do take_rank(r, straight_cards) end
  end
  -- 同花顺 / 皇家
  local sf_cards = {}
  if #flush_cards >= straight_len() and #run >= straight_len() then
    local set = {}
    for _, c in ipairs(flush_cards) do set[c] = true end
    for _, c in ipairs(straight_cards) do if set[c] then sf_cards[#sf_cards + 1] = c end end
    if #sf_cards >= straight_len() then
      local royal = true
      for _, r in ipairs({ 12, 11, 10, 9 }) do
        local ok = false
        for _, c in ipairs(sf_cards) do if c.r == r and c.s == fs then ok = true end end
        royal = royal and ok
      end
      best = { k = royal and HK_RF or HK_SF, cards = sf_cards }
    end
  end
  -- 多条系
  local function kind_cards(need)
    local out = {}
    for r = 12, 0, -1 do
      if (cnt[r] or 0) >= need then
        take_rank(r, out)
        if #out >= need then return out, r end
        out = {}
      end
    end
    return nil
  end
  local four = kind_cards(4)
  local three = kind_cards(3)
  local pair = kind_cards(2)
  local fh_cards, p2 = nil, nil
  if three and pair then
    if pair[1].r ~= three[1].r then
      fh_cards = {}
      for _, c in ipairs(three) do fh_cards[#fh_cards + 1] = c end
      for _, c in ipairs(pair) do if c.r ~= three[1].r then fh_cards[#fh_cards + 1] = c end end
      p2 = true
    end
  end
  -- 两对
  local twp, ranks2 = {}, {}
  for r = 12, 0, -1 do if (cnt[r] or 0) >= 2 then ranks2[#ranks2 + 1] = r end end
  if #ranks2 >= 2 then
    take_rank(ranks2[1], twp) take_rank(ranks2[2], twp)
  end
  local five = kind_cards(5)
  if five then best = { k = HK_5K, cards = five } end
  if five and flush_cards[1] then
    local allf = true
    for _, c in ipairs(five) do if c.s ~= fs then allf = false end end
    if allf then best = { k = HK_F5, cards = five } end
  end
  if fh_cards and flush_cards[1] then
    local allf = true
    for _, c in ipairs(fh_cards) do if c.s ~= fs then allf = false end end
    if allf then best = { k = HK_FHH, cards = fh_cards } end
  end
  if four and best.k < HK_4K then best = { k = HK_4K, cards = four } end
  if fh_cards and best.k < HK_FH then best = { k = HK_FH, cards = fh_cards } end
  if flush_cards[1] and best.k < HK_FL then best = { k = HK_FL, cards = flush_cards } end
  if straight_cards[1] and best.k < HK_ST then best = { k = HK_ST, cards = straight_cards } end
  if three and best.k < HK_3K then best = { k = HK_3K, cards = three } end
  if #twp >= 4 and best.k < HK_2P then best = { k = HK_2P, cards = twp } end
  if pair and best.k < HK_PAIR then best = { k = HK_PAIR, cards = pair } end
  -- contained 牌型集合（含所有子牌型）
  for i = 1, #HANDS do CONTAINED[i] = nil end
  local mark = function(k) CONTAINED[k] = true end
  if five then mark(HK_5K) mark(HK_4K) mark(HK_3K) mark(HK_PAIR) end
  if four then mark(HK_4K) mark(HK_3K) mark(HK_PAIR) end
  if three then mark(HK_3K) mark(HK_PAIR) end
  if #twp >= 4 then mark(HK_2P) mark(HK_PAIR) end
  if pair then mark(HK_PAIR) end
  if straight_cards[1] then mark(HK_ST) end
  if flush_cards[1] then mark(HK_FL) end
  if #sf_cards >= straight_len() then mark(HK_SF) mark(HK_ST) mark(HK_FL) end
  if best.k == HK_RF then mark(HK_RF) end
  -- GBA 语义：分数牌不包含在牌型内的高牌不计分
  return best
end

function min_rank_held()
  local b = nil
  for _, c in ipairs(DH) do
    if not c.sel and (b == nil or c.r < b.r) then b = c end
  end
  return b
end
