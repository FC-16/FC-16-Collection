-- 内容表：牌型、盲注、牌组与 53 张小丑
-- ------------------------------------------------------------ 内容表
-- 13 牌型（GBA HAND_BASE_VALUES，无星球升级）：名 / 基础筹码 / 基础倍率
HANDS = {
  { "高牌", 5, 1 }, { "对子", 10, 2 }, { "两对", 20, 2 }, { "三条", 30, 3 },
  { "顺子", 30, 4 }, { "同花", 35, 4 }, { "葫芦", 40, 4 }, { "四条", 60, 7 },
  { "同花顺", 100, 8 }, { "皇家同花顺", 100, 8 }, { "五条", 120, 12 },
  { "同花葫芦", 140, 14 }, { "同花五条", 160, 16 },
}
HK_HI, HK_PAIR, HK_2P, HK_3K, HK_ST, HK_FL, HK_FH, HK_4K = 1, 2, 3, 4, 5, 6, 7, 8
HK_SF, HK_RF, HK_5K, HK_FHH, HK_F5 = 9, 10, 11, 12, 13

-- 盲注（SMALL/BIG + 23 Boss + 5 Showdown；GBA 版 Boss 效果未实现，目标一律 ×2）
BOSSES = {
  "钩子", "金牛", "房屋", "高墙", "车轮", "手臂", "梅花", "鱼", "灵眼", "魔眼",
  "水门", "窗", "手铐", "邪眼", "独口", "植物", "巨蛇", "石柱", "针筒", "头颅",
  "尖牙", "燧石", "记号",
}
SHOWDOWNS = { "橡子", "落叶", "巨瓶", "红心", "铃钟" }
-- GBA blind.c 的 ANTE_LUT：下标即 ante（1..8），其首项 100 为越界回退值，不使用
ANTE_LUT = { 300, 800, 2000, 5000, 11000, 20000, 35000, 50000 }
BOSS_POOL_N, SHOWDOWN_N = 23, 5
BL_SMALL, BL_BIG, BL_BOSS0 = 0, 1, 2
BL_SD0 = BL_BOSS0 + BOSS_POOL_N

DECKS = { "红牌组", "蓝牌组", "黄牌组", "绿牌组", "黑牌组", "彩牌组" }
DECK_D = {
  "每轮 +1 次弃牌", "每轮 +1 次出牌", "开局额外 $10",
  "结算：剩余出牌 ×$2、剩余弃牌 ×$1，无利息",
  "小丑槽 +1，每轮 -1 次出牌", "手牌上限 +2，小丑槽 -1",
}
-- 牌组效果参数（GBA 选牌描述的语义；GBA 版仅显示未接线，本移植按描述实现）：
-- hands/disc 每轮出牌与弃牌次数、slots 小丑槽、hsize 手牌上限、money 开局金钱
DECK_M = {
  { hands = 4, disc = 5, slots = 5, hsize = 8, money = 4 },   -- 红
  { hands = 5, disc = 4, slots = 5, hsize = 8, money = 4 },   -- 蓝
  { hands = 4, disc = 4, slots = 5, hsize = 8, money = 14 },  -- 黄
  { hands = 4, disc = 4, slots = 5, hsize = 8, money = 4 },   -- 绿
  { hands = 3, disc = 4, slots = 6, hsize = 8, money = 4 },   -- 黑
  { hands = 4, disc = 4, slots = 4, hsize = 10, money = 4 },  -- 彩
}
function dmod() return DECK_M[G.deck + 1] end

-- ------------------------------------------------------------ 53 张小丑
-- r 稀有度 0/1/2；v 成本$；钩子 hp 出牌后｜cs 单卡计分｜ce 单卡结算(重触发)｜
-- ch 留牌计分｜ind 独立结算｜hs 整手结算；per 持久字段名
JOKERS = {
  { n = "小丑", r = 0, v = 2, d = "打出牌型 +4 倍率",
    ind = function(o) amul(4, o) end },
  { n = "抽象小丑", r = 0, v = 4, d = "每持有 1 张小丑 +3 倍率",
    ind = function(o) amul(3 * #G.jk, o) end },
  { n = "半张小丑", r = 0, v = 5, d = "打出不高于 3 张时 +20 倍率",
    ind = function(o) if #DS <= 3 then amul(20, o) end end },
  { n = "错印小丑", r = 0, v = 4, d = "+0 至 23 倍率",
    ind = function(o) amul(ri(24) - 1, o) end },
  { n = "惊恐脸", r = 0, v = 4, d = "打出的人面牌每张 +30 筹码",
    cs = function(o, c) if is_face(c) then achip(30, o) end end },
  { n = "袜与靴", r = 1, v = 6, d = "人面牌重触发 1 次",
    ce = function(o, c, i) if is_face(c) then retrig(i, "再来！") end end },
  { n = "杂技演员", r = 1, v = 6, d = "仅剩最后 1 次出牌时 ×3 倍率",
    ind = function(o) if G.hands == 0 then xm(3, o) end end },
  { n = "斐波那契", r = 1, v = 8, d = "打出的 A/2/3/5/8 每张 +8 倍率",
    cs = function(o, c) local r = c.r + 2
      if r == 14 or r == 2 or r == 3 or r == 5 or r == 8 then amul(8, o) end end },
  { n = "学者", r = 0, v = 4, d = "打出的 A 每张 +20 筹码 +4 倍率",
    cs = function(o, c) if c.r == 12 then achip(20, o) amul(4, o) end end },
  { n = "巧手小丑", r = 0, v = 4, d = "牌型含同花 +80 筹码",
    ind = function(o) if contained(HK_FL) then achip(80, o) end end },
  { n = "狡狯小丑", r = 0, v = 4, d = "牌型含同花 +10 倍率",
    ind = function(o) if contained(HK_FL) then amul(10, o) end end },
  { n = "举拳小丑", r = 0, v = 5, d = "手中点数最低的牌 +2×点数 倍率",
    hp = function(o) o.hf = min_rank_held() end,
    ch = function(o, c) if o.hf and c == o.hf then amul(2 * (c.r + 2), o) end end },
  { n = "预留车位", r = 0, v = 6, d = "手中每张人面牌 1/2 概率 +$1",
    ch = function(o, c) if is_face(c) and coin() then give(1, o) end end },
  { n = "商业卡", r = 0, v = 4, d = "打出的人面牌 1/2 概率 +$2",
    cs = function(o, c) if is_face(c) and coin() then give(2, o) end end },
  { n = "吊人小丑", r = 0, v = 4, d = "首张计分牌重触发 2 次",
    hp = function(o) o.hc = 2 end,
    ce = function(o, c, i) if i == 1 and o.hc > 0 then o.hc = o.hc - 1 retrig(i, "再来！") end end },
  { n = "镂空小丑", r = 1, v = 8, d = "×(1+空小丑槽位) 倍率",
    ind = function(o) xm(1 + (G.slots - #G.jk), o) end },
  { n = "横幅小丑", r = 0, v = 5, d = "每剩余 1 次弃牌 +30 筹码",
    ind = function(o) achip(30 * G.discards, o) end },
  { n = "射月小丑", r = 0, v = 5, d = "手中每张 Q +13 倍率",
    ch = function(o, c) if c.r == 10 then amul(13, o) end end },
  { n = "贪婪小丑", r = 0, v = 5, d = "打出的 ♦ 每张 +3 倍率",
    cs = function(o, c) if c.s == 0 then amul(3, o) end end },
  { n = "色欲小丑", r = 0, v = 5, d = "打出的 ♥ 每张 +3 倍率",
    cs = function(o, c) if c.s == 2 then amul(3, o) end end },
  { n = "暴怒小丑", r = 0, v = 5, d = "打出的 ♠ 每张 +3 倍率",
    cs = function(o, c) if c.s == 3 then amul(3, o) end end },
  { n = "暴食小丑", r = 0, v = 5, d = "打出的 ♣ 每张 +3 倍率",
    cs = function(o, c) if c.s == 1 then amul(3, o) end end },
  { n = "疯狂小丑", r = 0, v = 4, d = "牌型含顺子 +12 倍率",
    ind = function(o) if contained(HK_ST) then amul(12, o) end end },
  { n = "癫狂小丑", r = 0, v = 4, d = "牌型含两对 +10 倍率",
    ind = function(o) if contained(HK_2P) then amul(10, o) end end },
  { n = "聪慧小丑", r = 0, v = 4, d = "牌型含两对 +80 筹码",
    ind = function(o) if contained(HK_2P) then achip(80, o) end end },
  { n = "狡诈小丑", r = 0, v = 4, d = "牌型含顺子 +100 筹码",
    ind = function(o) if contained(HK_ST) then achip(100, o) end end },
  { n = "偶数史蒂文", r = 0, v = 4, d = "打出的偶数牌 每张 +4 倍率",
    cs = function(o, c) local r = c.r + 2
      if r <= 10 and r % 2 == 0 then amul(4, o) end end },
  { n = "黑板小丑", r = 1, v = 6, d = "手中全部为 ♠/♣ 时 ×3 倍率",
    ind = function(o)
      for _, c in ipairs(DH) do if c.s == 0 or c.s == 2 then return end end
      xm(3, o)
    end },
  { n = "神秘巅峰", r = 0, v = 5, d = "弃牌用完时 +15 倍率",
    ind = function(o) if G.discards == 0 then amul(15, o) end end },
  { n = "对讲机", r = 0, v = 4, d = "打出的 10 或 4 每张 +10 筹码 +4 倍率",
    cs = function(o, c) local r = c.r + 2
      if r == 10 or r == 4 then achip(10, o) amul(4, o) end end },
  { n = "滑稽小丑", r = 0, v = 4, d = "牌型含三条 +12 倍率",
    ind = function(o) if contained(HK_3K) then amul(12, o) end end },
  { n = "狡猾小丑", r = 0, v = 4, d = "牌型含三条 +100 筹码",
    ind = function(o) if contained(HK_3K) then achip(100, o) end end },
  { n = "灵巧小丑", r = 0, v = 3, d = "牌型含对子 +50 筹码",
    ind = function(o) if contained(HK_PAIR) then achip(50, o) end end },
  { n = "快活小丑", r = 0, v = 3, d = "牌型含对子 +8 倍率",
    ind = function(o) if contained(HK_PAIR) then amul(8, o) end end },
  { n = "蓝小丑", r = 0, v = 5, d = "每剩余 1 张牌库 +2 筹码",
    ind = function(o) achip(2 * #DK, o) end },
  { n = "奇数托德", r = 0, v = 4, d = "打出的奇数牌 每张 +31 筹码",
    cs = function(o, c) local r = c.r + 2
      if r == 14 or r % 2 == 1 then achip(31, o) end end },
  { n = "二重奏", r = 2, v = 8, d = "牌型含对子 ×2 倍率",
    ind = function(o) if contained(HK_PAIR) then xm(2, o) end end },
  { n = "三重奏", r = 2, v = 8, d = "牌型含三条 ×3 倍率",
    ind = function(o) if contained(HK_3K) then xm(3, o) end end },
  { n = "四重奏", r = 2, v = 8, d = "牌型含顺子 ×3 倍率",
    ind = function(o) if contained(HK_ST) then xm(3, o) end end },
  { n = "部落", r = 2, v = 8, d = "牌型含同花 ×2 倍率",
    ind = function(o) if contained(HK_FL) then xm(2, o) end end },
  { n = "家族", r = 2, v = 8, d = "牌型含四条 ×4 倍率",
    ind = function(o) if contained(HK_4K) then xm(4, o) end end },
  { n = "头脑风暴", r = 2, v = 10, d = "复制最左侧小丑的能力" },
  { n = "笑脸小丑", r = 0, v = 4, d = "打出的人面牌 每张 +5 倍率",
    cs = function(o, c) if is_face(c) then amul(5, o) end end },
  { n = "公牛小丑", r = 1, v = 6, d = "每 $1 +2 筹码",
    ind = function(o) if G.money > 0 then achip(2 * G.money, o) end end },
  { n = "照片小丑", r = 0, v = 5, d = "首张打出的人面牌 ×2 倍率",
    hp = function(o) o.pg = 0 end,
    cs = function(o, c) if o.pg == 0 and is_face(c) then o.pg = -1 xm(2, o) end end },
  { n = "黑客小丑", r = 1, v = 6, d = "打出的 2/3/4/5 每张重触发 1 次",
    ce = function(o, c, i) local r = c.r + 2
      if r >= 2 and r <= 5 then retrig(i, "再来！") end end },
  { n = "似人小丑", r = 1, v = 5, d = "所有牌都视为人面牌" },
  { n = "系绳小丑", r = 1, v = 7, d = "每 $5 +2 倍率",
    ind = function(o) if G.money > 0 then amul(math.floor(G.money / 5) * 2, o) end end },
  { n = "捷径小丑", r = 1, v = 7, d = "顺子允许隔 1 点数" },
  { n = "暮光小丑", r = 1, v = 5, d = "最后一手出牌时 打出牌全部重触发",
    ce = function(o, c, i) if G.hands == 0 then retrig(i, "再来！") end end },
  { n = "四指小丑", r = 1, v = 7, d = "顺子与同花只需 4 张" },
  { n = "气泡水", r = 1, v = 6, d = "重触发所有牌，剩 10 次",
    by = function(o) o.st = 10 end,
    ce = function(o, c, i) if o.st > 0 then retrig(i) end end,
    hs = function(o) if o.st > 0 then o.st = o.st - 1
      if o.st == 0 then kill(o, "喝光！") end end end },
  { n = "蓝图", r = 2, v = 10, d = "复制右侧小丑的能力" },
}
for i = 1, #JOKERS do JOKERS[i].id = i - 1 end

RAR_N, RAR_C = { "普通", "罕见", "稀有" }, { CL.sky, CL.green, CL.red }
