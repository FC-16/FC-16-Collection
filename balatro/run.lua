-- 对局流程：牌库构建、开局、盲注选取与结算判定
-- ============================================================ 对局构造
function sp(x) return MAX(1, CEIL(x / OPT.speed)) end   -- 游戏速度缩放帧数

function build_deck()
  DK = {}
  for s = 0, 3 do
    for r = 0, 12 do DK[#DK + 1] = { s = s, r = r } end
  end
  for i = #DK, 2, -1 do
    local j = ri(i)
    DK[i], DK[j] = DK[j], DK[i]
  end
end
function draw_cards(n)
  for _ = 1, n do
    if #DK > 0 then
      local c = table.remove(DK)
      c.tx, c.ty = 0, 0 c.x, c.y = 250, 130 c.ap = sp(10) c.flip = 0
      DH[#DH + 1] = c
      sfx(3, CH_UI)
    end
  end
  sort_hand()   -- 补牌后按当前排序模式整理手牌
end
function layout_hand()
  local n = #DH
  local gap = n > 1 and MIN(24, math.floor((168 - 32) / (n - 1))) or 0
  local x0 = 166 - math.floor(((n - 1) * gap + 32) / 2)
  for i, c in ipairs(DH) do
    c.tx = x0 + (i - 1) * gap
    c.ty = 202
  end
end
function sort_hand()
  if G.sortm == 0 then   -- 点数
    table.sort(DH, function(a, b)
      if a.r ~= b.r then return a.r > b.r end
      return a.s > b.s
    end)
  else                   -- 花色
    table.sort(DH, function(a, b)
      if a.s ~= b.s then return a.s > b.s end
      return a.r > b.r
    end)
  end
  layout_hand()
end
-- 排序切换：LT = 点数，RT = 花色；随时重新整理当前手牌
function set_sort(m)
  G.sortm = m
  sort_hand()
  sfx(0, CH_UI)
end

function new_run(seed)
  RUN.seed = seed % 4294967296
  SRAND_U32(RUN.seed)
  G = {
    ante = 1, round = 0, score = 0,
    jk = {}, deck = RUN.deck, sortm = 0, blind = 1,
    boss = -1, bdef = {},        -- 已击败 Boss 池（当前循环）
    bstat = {},                  -- 当前底注内小/大/Boss 的已击败/已跳过状态
    hplay = {}, best = 0, bestkind = 1,
  }
  G.hands, G.discards = dmod().hands, dmod().disc
  G.money, G.slots = dmod().money, dmod().slots
  for i = 1, 13 do G.hplay[i] = 0 end
  for i = 0, BOSS_POOL_N - 1 do G.bdef[i] = false end
  build_deck()
  save_run()
  to_blindsel()
end
function blind_req(b)
  local base = ANTE_LUT[MIN(G.ante, 8)]
  local mul = b == BL_SMALL and 1 or (b == BL_BIG and 1.5 or 2)
  return math.floor(base * mul)
end
function blind_reward(b)
  if b == BL_SMALL then return 3 end
  if b == BL_BIG then return 4 end
  return b >= BL_SD0 and 8 or 5
end
function blind_name(b)
  if b == BL_SMALL then return "小盲注" end
  if b == BL_BIG then return "大盲注" end
  if b >= BL_SD0 then return SHOWDOWNS[b - BL_SD0 + 1] end
  return BOSSES[b - BL_BOSS0 + 1]
end
function pick_boss()
  local showdown = G.ante % 8 == 0
  local pool = {}
  for i = 0, (showdown and SHOWDOWN_N or BOSS_POOL_N) - 1 do
    if not G.bdef[i] then pool[#pool + 1] = i end
  end
  if #pool == 0 then    -- 池已抽完，重置
    for i = 0, (showdown and SHOWDOWN_N or BOSS_POOL_N) - 1 do G.bdef[i] = false end
    for i = 0, (showdown and SHOWDOWN_N or BOSS_POOL_N) - 1 do pool[#pool + 1] = i end
  end
  local k = pool[ri(#pool)]
  G.bdef[k] = true
  G.boss = showdown and BL_SD0 + k or BL_BOSS0 + k
end

function to_blindsel()
  st, tt = "blindsel", 0
  BS = { bi = 1, row = 0, anim = sp(12) }
  if G.boss < 0 then pick_boss() end
  music(0, 400, 0xC7)
end


-- ============================================================ 对局：开局
function start_round()
  G.hands, G.discards, G.score = dmod().hands, dmod().disc, 0
  DH, DS = {}, {}
  build_deck()
  PS = { ph = "deal", t = 0, row = 1, cur = 1 }
  draw_cards(dmod().hsize)
end
