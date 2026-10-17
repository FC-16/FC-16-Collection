-- 存档：save/load 结构化持久化与读档重建（SPEC §13）
-- 结构：{speed=游戏速度, run=对局快照（无进行中对局时缺省）}
-- ============================================================ 存档
-- 当前存档的内存副本：开机读取一次，之后每次写入同步更新
SAVED = {}
function save_init()
  local d = load()
  SAVED = type(d) == "table" and d or {}
end
local function save_commit() save(SAVED) end
-- 缺失或非数字字段按 0 处理；载入值一律归整
local function sint(v) return type(v) == "number" and FLR(v) or 0 end
function has_run() return type(SAVED.run) == "table" end
function saved_speed()
  local s = sint(SAVED.speed)
  return s == 0 and 1 or s
end
function save_speed()
  SAVED.speed = OPT.speed
  save_commit()
end

function save_run()
  local bdef = {}
  for i = 0, BOSS_POOL_N - 1 do
    if G.bdef[i] then bdef[#bdef + 1] = i end
  end
  local jokers = {}
  for i = 1, #G.jk do
    local o = G.jk[i]
    jokers[i] = { id = o.id, st = o.st }
  end
  local hplay = {}
  for i = 1, 13 do hplay[i] = G.hplay[i] end
  -- 当前底注内盲注状态：0 未至 / 1 已击败 / 2 已跳过
  local bstat = {}
  for i = 1, 3 do
    bstat[i] = G.bstat[i] == true and 1 or (G.bstat[i] == "skip" and 2 or 0)
  end
  SAVED.speed = OPT.speed
  SAVED.run = {
    ante = G.ante, round = G.round, money = G.money,
    hands = G.hands, discards = G.discards, sortm = G.sortm,
    blind = G.blind, boss = G.boss, deck = G.deck,
    bdef = bdef, seed = RUN.seed, jokers = jokers,
    best = G.best, bestkind = G.bestkind, hplay = hplay, bstat = bstat,
  }
  save_commit()
end
function load_run()
  local r = SAVED.run
  if type(r) ~= "table" then return false end
  OPT.speed = saved_speed()
  G = {
    ante = sint(r.ante), round = sint(r.round), money = sint(r.money),
    hands = sint(r.hands), discards = sint(r.discards), score = 0, sortm = sint(r.sortm),
    blind = sint(r.blind), boss = sint(r.boss), deck = sint(r.deck),
    jk = {}, bdef = {}, hplay = {}, best = 0, bestkind = 1,
  }
  G.slots = dmod().slots   -- 小丑槽由牌组派生（黑 +1 / 彩 -1），不入存档
  for i = 0, BOSS_POOL_N - 1 do G.bdef[i] = false end
  if type(r.bdef) == "table" then
    for _, i in ipairs(r.bdef) do
      i = sint(i)
      if i >= 0 and i < BOSS_POOL_N then G.bdef[i] = true end
    end
  end
  RUN.seed = sint(r.seed)
  if type(r.jokers) == "table" then
    for _, j in ipairs(r.jokers) do
      local id = type(j) == "table" and sint(j.id) or -1
      if id >= 0 then
        local o = { id = id }
        local per = sint(j.st)
        if per > 0 then o.st = per end
        G.jk[#G.jk + 1] = o
      end
    end
  end
  G.best = sint(r.best)
  G.bestkind = sint(r.bestkind)
  local hplay = type(r.hplay) == "table" and r.hplay or {}
  for i = 1, 13 do G.hplay[i] = sint(hplay[i]) end
  G.bstat = {}
  local bstat = type(r.bstat) == "table" and r.bstat or {}
  for i = 1, 3 do
    local v = sint(bstat[i])
    G.bstat[i] = v == 1 and true or (v == 2 and "skip" or nil)
  end
  SRAND_U32(RUN.seed + G.ante * 7919 + G.round)
  build_deck()
  to_blindsel()
  return true
end
