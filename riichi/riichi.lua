-- FC-16 日本麻将（demo/riichi/riichi.lua）
-- 立直麻将（日本麻将）东风战：4 人制，25000 点起点，136 张（含红五万/筒/条各一）。
-- 完整流程：标题 → 掷骰定起家 → 配牌 → 摸切循环 → 鸣牌（吃/碰/大明杠）→
--   暗杠/加杠 → 立直（1000 点棒、自动摸切）→ 宝牌/里宝/杠宝 → 荒牌流局（听牌宣告）→
--   和了（荣和/自摸）→ 连庄/终局顺位结算。
-- 和牌判定：4 面子 1 雀头 + 七对子 + 国士无双；无役不能和。
-- 结构分层：牌表示 / 和牌判定与向听 → 役种与计分 → 进程状态机（协程）→ AI →
--   精灵烘焙 → UI / 动画 → 输入 → 音频 → 自测 → 生命周期。
-- SFX/BGM 按 SPEC §5.2 布局程序化写入；麻将牌 16×16 精灵逐像素烘焙。
-- 操作：⬅➡选牌（按住重复）Ⓐ打出　Ⓨ立直宣言　Ⓧ杠菜单　Ⓑ取消/过
--       鸣牌菜单 ⬅➡选择 Ⓐ确认 Ⓑ过；和牌提示 Ⓐ和 Ⓑ过；Start 暂停；Select BGM。
-- 存档：dset 槽 0=局数 1=和了数 2=立直数 3=最佳点数（1P 视角）。
-- 自测：自由区首字节 peek(0x064400)==42 时进入核心逻辑自测模式。

-- ================================================================ 常量与配色

local C_BG = 14       -- 深底
local C_RIM = 17      -- 桌沿木
local C_RIM2 = 19
local C_FELT = 37     -- 桌布墨绿
local C_FELT2 = 36
local C_TILE = 22     -- 牌面米白
local C_TILE_SH = 21  -- 牌影
local C_INK = 11      -- 墨蓝
local C_RED = 59      -- 红
local C_RED_D = 60
local C_GREEN = 35    -- 绿
local C_BLUE = 40     -- 蓝
local C_BACK = 60     -- 牌背深红
local C_BACK2 = 61
local C_GOLD = 30
local C_PANEL = 12
local C_PBD = 11
local C_TEXT = 8
local C_DIM = 10
local C_WHITE = 7

local TILE_W, TILE_H = 16, 16
local HAND_Y = 228    -- 手牌顶 y
local INFO_Y = 210    -- 底部信息条 y

-- 视角相关布局（rel: 0=下 1=右 2=上 3=左）
-- {x, y, cols, pitch_x, pitch_y, rows, max_h}
local RIVER_LY = {
  [0] = { 86, 168, 6, 13, 13, 3, 40 },
  [1] = { 160, 88, 3, 13, 12, 5, 60 },
  [2] = { 86, 32, 6, 13, 13, 3, 46 },
  [3] = { 56, 88, 3, 13, 12, 5, 60 },
}
local MELD_LY = {     -- 侧面鸣牌区 {x, y, 每行格数}
  [0] = {176, 152, 2},
  [1] = {172, 150, 2},
  [2] = {174, 32, 2},
  [3] = {2, 150, 2},
}
local WIND_CH = {"东", "南", "西", "北"}
local DRAGON_CH = {"白", "发", "中"}  -- kinds 31/32/33
local NUM_CH = {"一", "二", "三", "四", "五", "六", "七", "八", "九"}

-- ================================================================ 牌工具

-- kind 0..8=一万..九万 9..17=一筒..九筒 18..26=一条..九条
-- 27..30=东南西北 31白 32发 33中；code=kind*4+copy(0..3)
-- 红五：kind 4/13/22 且 copy==0
local function kind_of(code) return code >> 2 end
local RED_KIND = { [4] = true, [13] = true, [22] = true }
local function is_red(code) return (code & 3) == 0 and RED_KIND[code >> 2] or false end
local function kind_suit(k) return k < 27 and flr(k / 9) or 3 end
local function kind_num(k) return k % 9 + 1 end   -- 1..9
local function is_yao(k) return k >= 27 or k % 9 == 0 or k % 9 == 8 end
local function is_honor(k) return k >= 27 end
local function is_simp(k) return k < 27 and k % 9 >= 1 and k % 9 <= 7 end

local function dora_next(k)  -- 宝牌指示牌对应宝牌
  if k < 27 then
    return flr(k / 9) * 9 + (k + 1) % 9
  end
  if k == 30 then return 31 end
  if k == 33 then return 27 end
  return k + 1
end

local KIND_NAME = {}
do
  for s = 0, 2 do
    local suf = ({"万", "筒", "条"})[s + 1]
    for n = 0, 8 do KIND_NAME[s * 9 + n] = NUM_CH[n + 1] .. suf end
  end
  KIND_NAME[27], KIND_NAME[28] = "东", "南"
  KIND_NAME[29], KIND_NAME[30] = "西", "北"
  KIND_NAME[31], KIND_NAME[32], KIND_NAME[33] = "白", "发", "中"
end

local function code_name(code)
  local k = kind_of(code)
  if is_red(code) then return "红" .. KIND_NAME[k] end
  return KIND_NAME[k]
end

local function sort_hand(h)
  table.sort(h, function(a, b)
    local ka, kb = kind_of(a), kind_of(b)
    if ka ~= kb then return ka < kb end
    return is_red(a) and not is_red(b)
  end)
end

local function hand_to_cnt(h)
  local c = {}
  for i = 0, 33 do c[i] = 0 end
  for i = 1, #h do c[kind_of(h[i])] = c[kind_of(h[i])] + 1 end
  return c
end

local function cnt_copy(c)
  local o = {}
  for i = 0, 33 do o[i] = c[i] end
  return o
end

-- ================================================================ 和牌判定

-- 标准形：面子 + 雀头（bool）
local function win_std(cnt, n_called)
  local need = 4 - n_called
  for p = 0, 33 do
    if cnt[p] >= 2 then
      cnt[p] = cnt[p] - 2
      local ok = false
      local function rec(k)
        while k <= 33 and cnt[k] == 0 do k = k + 1 end
        if k > 33 then ok = true return end
        if cnt[k] >= 3 then
          cnt[k] = cnt[k] - 3
          rec(k)
          cnt[k] = cnt[k] + 3
          if ok then return end
        end
        if k < 27 and k % 9 <= 6 and cnt[k + 1] > 0 and cnt[k + 2] > 0 then
          cnt[k] = cnt[k] - 1 cnt[k + 1] = cnt[k + 1] - 1 cnt[k + 2] = cnt[k + 2] - 1
          rec(k)
          cnt[k] = cnt[k] + 1 cnt[k + 1] = cnt[k + 1] + 1 cnt[k + 2] = cnt[k + 2] + 1
          if ok then return end
        end
      end
      rec(0)
      cnt[p] = cnt[p] + 2
      if ok then return true end
    end
  end
  return false
end

-- 枚举全部分解（仅门清 14 张时调用）：{{sets={{t="tri"/"seq",k=..},..}, pair=k},..}
local function decompose_all(cnt)
  local res = {}
  for p = 0, 33 do
    if cnt[p] >= 2 then
      cnt[p] = cnt[p] - 2
      local sets = {}
      local function rec(k)
        while k <= 33 and cnt[k] == 0 do k = k + 1 end
        if k > 33 then
          local cp = {}
          for i = 1, #sets do cp[i] = sets[i] end
          res[#res + 1] = { sets = cp, pair = p }
          return
        end
        if cnt[k] >= 3 then
          cnt[k] = cnt[k] - 3
          sets[#sets + 1] = { t = "tri", k = k }
          rec(k)
          sets[#sets] = nil
          cnt[k] = cnt[k] + 3
        end
        if k < 27 and k % 9 <= 6 and cnt[k + 1] > 0 and cnt[k + 2] > 0 then
          cnt[k] = cnt[k] - 1 cnt[k + 1] = cnt[k + 1] - 1 cnt[k + 2] = cnt[k + 2] - 1
          sets[#sets + 1] = { t = "seq", k = k }
          rec(k)
          sets[#sets] = nil
          cnt[k] = cnt[k] + 1 cnt[k + 1] = cnt[k + 1] + 1 cnt[k + 2] = cnt[k + 2] + 1
        end
      end
      rec(0)
      cnt[p] = cnt[p] + 2
    end
  end
  return res
end

local function chiitoi_ok(cnt)
  local pairs = 0
  for i = 0, 33 do
    if cnt[i] == 1 or cnt[i] == 3 or cnt[i] == 4 then return false end
    if cnt[i] == 2 then pairs = pairs + 1 end
  end
  return pairs == 7
end

local YAO13 = { 0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33 }
local function kokushi_ok(cnt)
  local kinds, pair = 0, 0
  for i = 0, 33 do
    if cnt[i] > 0 and not (i == 0 or i == 8 or i == 9 or i == 17 or i == 18 or i == 26 or i >= 27) then
      return false
    end
  end
  for _, i in ipairs(YAO13) do
    if cnt[i] >= 1 then kinds = kinds + 1 end
    if cnt[i] >= 2 then pair = 1 end
  end
  return kinds == 13 and pair == 1
end

-- 14 张门清（含自摸/荣和牌）能否和（含七对/国士）
local function hand_wins(cnt, n_called)
  if n_called == 0 then
    if kokushi_ok(cnt) then return true end
    if chiitoi_ok(cnt) then return true end
  end
  return win_std(cnt, n_called)
end

-- ================================================================ 向听数

-- 常规向听（含鸣牌）；cnt 为 13/10/7/4/1 张的计数
local function shanten_regular(cnt, n_called)
  local blocks_max = 4 - n_called
  local best = 8
  local total = 0
  for i = 0, 33 do total = total + cnt[i] end
  local sets, partials, pair = 0, 0, 0
  local function rec(k, rem)
    local cur = 8 - 2 * (n_called + sets) - partials - pair
    if cur - ceil(rem * 2 / 3) >= best then return end
    while k <= 33 and cnt[k] == 0 do k = k + 1 end
    if k > 33 then
      local s = 8 - 2 * (n_called + sets) - partials - pair
      if s < best then best = s end
      return
    end
    local c = cnt[k]
    if c >= 3 and sets < blocks_max then
      cnt[k] = c - 3
      sets = sets + 1
      rec(k, rem - 3)
      sets = sets - 1
      cnt[k] = c
    end
    if k < 27 and k % 9 <= 6 and cnt[k + 1] > 0 and cnt[k + 2] > 0 and sets < blocks_max then
      cnt[k] = cnt[k] - 1 cnt[k + 1] = cnt[k + 1] - 1 cnt[k + 2] = cnt[k + 2] - 1
      sets = sets + 1
      rec(k, rem - 3)
      sets = sets - 1
      cnt[k] = cnt[k] + 1 cnt[k + 1] = cnt[k + 1] + 1 cnt[k + 2] = cnt[k + 2] + 1
    end
    if c >= 2 and pair == 0 and sets + partials <= blocks_max then
      cnt[k] = c - 2
      pair = 1
      rec(k, rem - 2)
      pair = 0
      cnt[k] = c
    end
    if c >= 2 and sets + partials < blocks_max then
      cnt[k] = c - 2
      partials = partials + 1
      rec(k, rem - 2)
      partials = partials - 1
      cnt[k] = c
    end
    if k < 27 and k % 9 <= 7 and cnt[k + 1] > 0 and sets + partials < blocks_max then
      cnt[k] = cnt[k] - 1 cnt[k + 1] = cnt[k + 1] - 1
      partials = partials + 1
      rec(k, rem - 2)
      partials = partials - 1
      cnt[k] = cnt[k] + 1 cnt[k + 1] = cnt[k + 1] + 1
    end
    if k < 27 and k % 9 <= 6 and cnt[k + 2] > 0 and sets + partials < blocks_max then
      cnt[k] = cnt[k] - 1 cnt[k + 2] = cnt[k + 2] - 1
      partials = partials + 1
      rec(k, rem - 2)
      partials = partials - 1
      cnt[k] = cnt[k] + 1 cnt[k + 2] = cnt[k + 2] + 1
    end
    rec(k + 1, rem)
  end
  rec(0, total)
  return best
end

local function shanten_chiitoi(cnt)
  local pairs, kinds = 0, 0
  for i = 0, 33 do
    if cnt[i] > 0 then
      kinds = kinds + 1
      if cnt[i] >= 2 then pairs = pairs + 1 end
    end
  end
  return 6 - pairs + max(0, 7 - kinds)
end

local function shanten_kokushi(cnt)
  local kinds, pair = 0, 0
  for _, i in ipairs(YAO13) do
    if cnt[i] >= 1 then kinds = kinds + 1 end
    if cnt[i] >= 2 then pair = 1 end
  end
  local extra = 0
  for i = 0, 33 do
    if cnt[i] > 0 and not (i == 0 or i == 8 or i == 9 or i == 17 or i == 18 or i == 26 or i >= 27) then
      extra = extra + cnt[i]
    end
  end
  return 13 - kinds - pair + extra
end

local function shanten_hand(cnt, n_called)
  local s = shanten_regular(cnt, n_called)
  if n_called == 0 then
    local c = shanten_chiitoi(cnt)
    if c < s then s = c end
    local k = shanten_kokushi(cnt)
    if k < s then s = k end
  end
  return s
end

-- 13 张的待牌种类列表（n_called==0 时含七对/国士）
local function waits_of(cnt13, n_called)
  local cand = {}
  for i = 0, 33 do cand[i] = false end
  for i = 0, 33 do
    if cnt13[i] > 0 then
      if i >= 27 then
        cand[i] = true
      else
        for d = -2, 2 do
          local j = i + d
          if j >= 0 and j < 27 and flr(j / 9) == flr(i / 9) then cand[j] = true end
        end
      end
    end
  end
  local out = {}
  for k = 0, 33 do
    if cand[k] then
      cnt13[k] = cnt13[k] + 1
      if hand_wins(cnt13, n_called) then out[#out + 1] = k end
      cnt13[k] = cnt13[k] - 1
    end
  end
  return out
end

local function is_tenpai(cnt13, n_called)
  return shanten_hand(cnt13, n_called) <= 0
end

-- ================================================================ 点数工具

local function c100(x) return ceil(x / 100) * 100 end
local function c10(x) return ceil(x / 10) * 10 end

-- 基本点（限额阶梯）
local function basic_pts(fu, han)
  if han >= 13 then return 8000 * flr(han / 13) end
  if han >= 11 then return 6000 end
  if han >= 8 then return 4000 end
  if han >= 6 then return 3000 end
  if han >= 5 then return 2000 end
  local b = fu * 4
  for _ = 1, han do b = b * 2 end
  if b > 1920 then return 2000 end  -- 切上满贯：1920 恰好仍按符算（7700）
  return b
end

-- ================================================================ 役种与计分

-- G 在此部分之后定义；score 依赖 G 的场况（风、宝牌等）。
-- 集合标记：t = "tri" 刻子 | "seq" 顺子 | "kan" 杠；conc = 是否暗刻（荣和牌补刻算明刻）

-- 计算一组面子集合 + 雀头的役（不含宝牌/立直系/自摸系，这些在 score_hand 汇总）
-- sets: 全部面子（含鸣牌）；pairk: 雀头 kind；menzen: 门清；red: 食い下がり
local function eval_yaku_sets(sets, pairk, menzen, red)
  local yaku = {}   -- {{名, 翻}}
  local function add(name, han) yaku[#yaku + 1] = { name, han } end
  local red_off = red and 1 or 0   -- 食い下がり减 1 翻

  local n_tri, n_seq, n_kan = 0, 0, 0
  local tri_k, seq_k = {}, {}
  local all_yao, no_honor, all_green, all_honor, one_suit = true, true, true, true, true
  local suit_seen = -1
  local ankou = 0
  for i = 1, #sets do
    local s = sets[i]
    local k = s.k
    if s.t == "seq" then
      n_seq = n_seq + 1
      seq_k[n_seq] = k
      if k % 9 ~= 0 and k % 9 ~= 6 then all_yao = false end
      all_honor = false
    else
      tri_k[#tri_k + 1] = k
      if s.t == "kan" then n_kan = n_kan + 1 else n_tri = n_tri + 1 end
      if s.conc then ankou = ankou + 1 end
      if not is_yao(k) then all_yao = false end
      if k < 27 then all_honor = false else no_honor = false end
    end
    if k < 27 then
      if suit_seen < 0 then suit_seen = flr(k / 9)
      elseif suit_seen ~= flr(k / 9) then one_suit = false end
    end
    -- 绿一色检查（面子级别）
    for d = 0, s.t == "seq" and 2 or 0 do
      local kk = k + d
      if not (kk == 19 or kk == 20 or kk == 21 or kk == 23 or kk == 25 or kk == 32) then
        all_green = false
      end
    end
  end
  local pk = pairk
  if not is_yao(pk) then all_yao = false end
  if pk < 27 then
    all_honor = false
    if suit_seen >= 0 and suit_seen ~= flr(pk / 9) then one_suit = false end
    if suit_seen < 0 then suit_seen = flr(pk / 9) end
  else
    no_honor = false
  end
  if not (pk == 19 or pk == 20 or pk == 21 or pk == 23 or pk == 25 or pk == 32) then
    all_green = false
  end

  -- 对对和 / 三暗刻 / 混老头 / 三色同刻
  if ankou >= 3 then add("三暗刻", 2) end
  if n_seq == 0 then
    add("对对和", 2)
    if all_yao then add("混老头", 2) end
    -- 三色同刻
    local bynum = {}
    for i = 1, #tri_k do
      local k = tri_k[i]
      bynum[k % 9] = (bynum[k % 9] or 0) + 1
    end
    for n, c in pairs(bynum) do
      if c >= 3 then
        local suits = {}
        for i = 1, #tri_k do
          if tri_k[i] % 9 == n then suits[flr(tri_k[i] / 9)] = true end
        end
        if suits[0] and suits[1] and suits[2] then add("三色同刻", 2) break end
      end
    end
  end

  -- 顺子系役
  if n_seq > 0 then
    -- 一杯口 / 二杯口（门清限定）
    if menzen then
      local cnt = {}
      for i = 1, n_seq do cnt[seq_k[i]] = (cnt[seq_k[i]] or 0) + 1 end
      local ip, rp = 0, 0
      for _, c in pairs(cnt) do
        if c >= 2 then ip = 1 end
        if c >= 4 then rp = 1 end
        if c >= 2 then rp = rp + 1 end
      end
      if rp >= 2 then add("二杯口", 3) elseif ip >= 1 then add("一杯口", 1) end
    end
    -- 三色同顺
    local m = {}
    for i = 1, n_seq do m[seq_k[i]] = true end
    for k = 0, 6 do
      if m[k] and m[k + 9] and m[k + 18] then add("三色同顺", 2 - red_off) break end
    end
    -- 一气通贯
    for s = 0, 2 do
      if m[s * 9] and m[s * 9 + 3] and m[s * 9 + 6] then add("一气通贯", 2 - red_off) break end
    end
    -- 混全带幺九 / 纯全带幺九
    if all_yao then
      if no_honor then add("纯全带幺九", 3 - red_off)
      else add("混全带幺九", 2 - red_off) end
    end
  end

  -- 断幺九
  if not all_yao then
    local simp = true
    for i = 1, #sets do
      local s = sets[i]
      if is_yao(s.k) then simp = false break end
      if s.t == "seq" and (is_yao(s.k) or is_yao(s.k + 2)) then simp = false break end
    end
    if simp and not is_yao(pk) then add("断幺九", 1) end
  end

  -- 混一色 / 清一色
  if one_suit then
    if no_honor then add("清一色", 6 - red_off)
    else add("混一色", 3 - red_off) end
  end

  return { yaku = yaku, ankou = ankou, n_kan = n_kan, all_honor = all_honor,
    no_honor = no_honor, all_yao = all_yao, all_green = all_green, n_seq = n_seq,
    tri_k = tri_k, n_tri_all = #tri_k }
end

-- 役满检查（返回役满名列表）
local function eval_yakuman(sets, pairk, menzen, info)
  local out = {}
  local function add(nm) out[#out + 1] = nm end
  if info.kokushi then add("国士无双") end
  if info.chiitoi then return out end
  -- 四暗刻：4 暗刻 + 雀头
  if info.ankou == 4 then add("四暗刻") end
  -- 大三元
  local dg = 0
  for i = 1, #info.tri_k do
    if info.tri_k[i] >= 31 then dg = dg + 1 end
  end
  if dg == 3 then add("大三元") end
  -- 字一色
  if info.all_honor then add("字一色") end
  -- 绿一色
  if info.all_green then add("绿一色") end
  -- 清老头
  if info.all_yao and info.no_honor and info.n_seq == 0 then add("清老头") end
  -- 九莲宝灯（门清清一色）
  if menzen and info.chuuren then add("九莲宝灯") end
  -- 四杠子
  if info.n_kan == 4 then add("四杠子") end
  return out
end

-- 符计算：sets 含暗/明标记；wk = 和牌张 kind；wtype = 待牌型
-- wtype: "ryanmen"/"shanpon"/"kanchan"/"penchan"/"tanki"
local function calc_fu(sets, pairk, wtype, menzen, tsumo, seat_wind, round_wind, is_chiitoi)
  if is_chiitoi then return 25 end
  local fu = 20
  -- 雀头符
  if pairk >= 31 then fu = fu + 2
  elseif pairk >= 27 then
    local sw, rw = false, false
    if pairk == 27 + seat_wind then sw = true end
    if pairk == 27 + round_wind then rw = true end
    if sw and rw then fu = fu + 4
    elseif sw or rw then fu = fu + 2 end
  end
  -- 面子符
  for i = 1, #sets do
    local s = sets[i]
    if s.t ~= "seq" then
      local yao = is_yao(s.k)
      if s.t == "kan" then
        fu = fu + (s.conc and (yao and 32 or 16) or (yao and 64 or 32))
      else
        fu = fu + (s.conc and (yao and 4 or 2) or (yao and 8 or 4))
      end
    end
  end
  -- 和牌形式符
  if tsumo then
    fu = fu + 2
  elseif menzen then
    fu = fu + 10
  end
  -- 待牌符（平和在调用方处理为 20 符）
  if wtype == "kanchan" or wtype == "penchan" or wtype == "tanki" then
    fu = fu + 2
  end
  return fu
end

-- ================================================================ 和了整体评分

-- melds: {type="chi"/"pon"/"mkan"/"ankan"/"kakan", k=kind, src=code, others={codes}, from=seat}
-- hand: 门清牌 code 数组（13 张，不含和牌张）；wcode: 和牌张
-- SC 场况表：{seat_wind, round_wind, riichi, daburu, ippatsu, tsumo(自摸),
--   rinshan(岭上), haitei(海底自摸), houtei(河底荣和), first(天和/地和),
--   dora={指示牌kind列表}, ura={里宝kind列表}, 用 SC.ura_on 表示里宝开放}
-- 返回 {yaku={{名,翻}..}, han, fu, yakuman, basic, wtype} 或 nil（无役不能和）
local function score_hand(hand, melds, wcode, mode, SC)
  local wk = kind_of(wcode)
  local cnt0 = hand_to_cnt(hand)
  local cnt = cnt_copy(cnt0)
  cnt[wk] = cnt[wk] + 1
  local msets = {}
  local menzen = true
  for i = 1, #melds do
    local m = melds[i]
    local s
    if m.type == "chi" then
      s = { t = "seq", k = m.k, conc = false }
      menzen = false
    elseif m.type == "pon" then
      s = { t = "tri", k = m.k, conc = false }
      menzen = false
    elseif m.type == "ankan" then
      s = { t = "kan", k = m.k, conc = true }
    else
      s = { t = "kan", k = m.k, conc = false }
      menzen = false
    end
    msets[#msets + 1] = s
  end
  local n_called = #melds
  local tsumo = (mode == "tsumo")

  -- 候选形：国士 / 七对 / 各分解
  local cands = {}
  if n_called == 0 then
    if kokushi_ok(cnt) then cands[#cands + 1] = { kokushi = true } end
    if chiitoi_ok(cnt) then cands[#cands + 1] = { chiitoi = true } end
  end
  local decomps = decompose_all(cnt)
  for i = 1, #decomps do cands[#cands + 1] = { decomp = decomps[i] } end

  local best = nil
  for ci = 1, #cands do
    local cand = cands[ci]
    local sets, pairk
    if cand.kokushi then
      sets, pairk = {}, -1
    elseif cand.chiitoi then
      sets, pairk = {}, -1
    else
      sets = {}
      for i = 1, #msets do sets[i] = msets[i] end
      local d = cand.decomp
      for i = 1, #d.sets do sets[#sets + 1] = { t = d.sets[i].t, k = d.sets[i].k, conc = true } end
      pairk = d.pair
      -- 荣和补刻的刻子算明刻（符与三暗刻）
      if mode == "ron" then
        for i = #msets + 1, #sets do
          if sets[i].t == "tri" and sets[i].k == wk and cnt0[wk] == 2 then
            sets[i].conc = false
          end
        end
      end
    end

    local entry = { names = {}, han = 0, yakuman = 0, fu = 25 }
    local function add_yaku(nm, hn)
      entry.names[#entry.names + 1] = { nm, hn }
      entry.han = entry.han + hn
    end

    if cand.kokushi then
      entry.yakuman = 1
      entry.names[#entry.names + 1] = { "国士无双", "役满" }
      entry.han = 13
      entry.fu = 25
      entry.basic = 8000
      entry.wtype = "kokushi"
    elseif cand.chiitoi then
      add_yaku("七对子", 2)
      -- 七对子的断幺/染手
      local simp, suit_only, suit = true, true, -1
      for i = 0, 33 do
        if cnt[i] == 2 then
          if is_yao(i) then simp = false end
          if i >= 27 then
            suit_only = false
          else
            local s = flr(i / 9)
            if suit == -1 then
              suit = s
            elseif suit ~= s and suit ~= -2 then
              suit = -2
            end
          end
        end
      end
      if simp then add_yaku("断幺九", 1) end
      if suit >= 0 then
        if suit_only then add_yaku("清一色", 6) else add_yaku("混一色", 3) end
      end
      local info = { chiitoi = true }
      local yk = eval_yakuman(sets, pairk, menzen, info)
      for i = 1, #yk do
        entry.yakuman = entry.yakuman + 1
        entry.names[#entry.names + 1] = { yk[i], "役满" }
        entry.han = entry.han + 13
      end
      entry.fu = 25
      entry.basic = basic_pts(25, entry.han)
    else
      -- 待牌型判定
      local wtype = nil
      if pairk == wk and cnt0[wk] == 1 then
        wtype = "tanki"
      else
        for i = 1, #sets do
          local s = sets[i]
          if s.t == "seq" and wk >= s.k and wk <= s.k + 2 then
            local pos = wk - s.k
            if pos == 1 then wtype = "kanchan"
            elseif pos == 0 then wtype = (wk % 9 == 0) and "penchan" or "ryanmen"
            else wtype = (wk % 9 == 8) and "penchan" or "ryanmen" end
            break
          elseif s.t == "tri" and s.k == wk and cnt0[wk] == 2 then
            wtype = "shanpon"
            break
          end
        end
      end
      if not wtype then wtype = "ryanmen" end
      entry.wtype = wtype
      -- 平和判定（先于一般符计算）
      local is_pinfu = menzen and #sets == 4 and wtype == "ryanmen"
      local pair_yakuhai = false
      if pairk >= 31 then pair_yakuhai = true
      elseif pairk >= 27 then
        if pairk == 27 + SC.round_wind or pairk == 27 + SC.seat_wind then pair_yakuhai = true end
      end
      if pair_yakuhai then is_pinfu = false end
      for i = 1, #sets do
        if sets[i].t ~= "seq" then is_pinfu = false end
      end

      local info = eval_yaku_sets(sets, pairk, menzen, not menzen)
      -- 役牌
      local dg_tri = 0
      for i = 1, #info.tri_k do
        local k = info.tri_k[i]
        if k >= 31 then
          add_yaku("役牌 " .. DRAGON_CH[k - 30], 1)
          dg_tri = dg_tri + 1
        else
          if k == 27 + SC.round_wind then add_yaku("场风" .. WIND_CH[SC.round_wind + 1], 1) end
          if k == 27 + SC.seat_wind then add_yaku("自风" .. WIND_CH[SC.seat_wind + 1], 1) end
        end
      end
      if dg_tri == 2 and pairk >= 31 then add_yaku("小三元", 2) end
      for i = 1, #info.yaku do add_yaku(info.yaku[i][1], info.yaku[i][2]) end
      if is_pinfu then add_yaku("平和", 1) end

      -- 役满
      info.chuuren = false
      if menzen and #melds == 0 then
        local s, ok = -1, true
        local low = { 3, 1, 1, 1, 1, 1, 1, 1, 3 }
        for su = 0, 2 do
          local has, good = false, true
          local tot = 0
          for j = 0, 8 do
            local c = cnt[su * 9 + j]
            if c > 0 then has = true end
            if c < low[j + 1] or c > low[j + 1] + 1 then good = false end
            tot = tot + c
          end
          if has then
            if not good or tot ~= 14 or s >= 0 then ok = false end
            s = su
          end
        end
        info.chuuren = ok and s >= 0
      end
      local yk = eval_yakuman(sets, pairk, menzen, info)
      if #yk > 0 then
        entry.yakuman = #yk
        entry.han = 0
        entry.names = {}
        for i = 1, #yk do
          entry.names[#entry.names + 1] = { yk[i], "役满" }
          entry.han = entry.han + 13
        end
        entry.fu = 25
        entry.basic = 8000 * #yk
      else
        if is_pinfu then
          entry.fu = 20
        else
          local fu = calc_fu(sets, pairk, wtype, menzen, tsumo,
            SC.seat_wind, SC.round_wind, false)
          entry.fu = c10(fu)
          if entry.fu < 30 then entry.fu = 30 end
        end
        if entry.han > 0 then
          entry.basic = basic_pts(entry.fu, entry.han)
        end
      end
    end

    -- 通用附加役：立直系 / 自摸 / 岭上 / 海底河底（无役时立直等仍可成立）
    if entry.yakuman == 0 then
      if SC.riichi then add_yaku("立直", 1) end
      if SC.daburu then add_yaku("两立直", 1) end
      if SC.ippatsu then add_yaku("一发", 1) end
      if tsumo and menzen then add_yaku("门前清自摸和", 1) end
      if SC.rinshan then add_yaku("岭上开花", 1) end
      if SC.haitei then add_yaku("海底捞月", 1) end
      if SC.houtei then add_yaku("河底捞鱼", 1) end
      if SC.tenhou or SC.chiihou then
        entry.yakuman = 1
        entry.han = 13
        entry.names[#entry.names + 1] = { SC.tenhou and "天和" or "地和", "役满" }
        entry.basic = 8000
      elseif entry.han > 0 then
        -- 宝牌（役满不计宝牌）
        local d_ct, r_ct, u_ct = 0, 0, 0
        local dmap, umap = {}, {}
        for i = 1, #SC.dora do dmap[SC.dora[i]] = true end
        if SC.riichi then
          for i = 1, #SC.ura do umap[SC.ura[i]] = true end
        end
        local all_codes = {}
        for i = 1, #hand do all_codes[#all_codes + 1] = hand[i] end
        all_codes[#all_codes + 1] = wcode
        for i = 1, #melds do
          all_codes[#all_codes + 1] = melds[i].src
          for j = 1, #melds[i].others do all_codes[#all_codes + 1] = melds[i].others[j] end
        end
        for i = 1, #all_codes do
          local code = all_codes[i]
          if dmap[kind_of(code)] then d_ct = d_ct + 1 end
          if is_red(code) then r_ct = r_ct + 1 end
          if umap[kind_of(code)] then u_ct = u_ct + 1 end
        end
        if d_ct > 0 then entry.names[#entry.names + 1] = { "宝牌 " .. d_ct, d_ct } entry.han = entry.han + d_ct end
        if r_ct > 0 then entry.names[#entry.names + 1] = { "红宝牌 " .. r_ct, r_ct } entry.han = entry.han + r_ct end
        if u_ct > 0 then entry.names[#entry.names + 1] = { "里宝牌 " .. u_ct, u_ct } entry.han = entry.han + u_ct end
        entry.basic = basic_pts(entry.fu, entry.han)
      end
    end

    if entry.han > 0 then
      if best == nil or entry.basic > best.basic then best = entry end
    end
  end
  if best == nil then return nil end
  best.is_pinfu = (best.fu == 20)
  return best
end

-- ================================================================ 音频（SPEC §5.2）

local function u8(a, v) poke(a, v % 256) end

local function sfx_steps(id, speed, steps)
  local base = 0x060000 + id * 112
  u8(base, speed)
  u8(base + 1, #steps)
  for i = 0, 31 do
    local a = base + 16 + i * 3
    local st = steps[i + 1]
    if st then
      u8(a, st[1] or 0)
      u8(a + 1, (st[2] or 0) * 16 + (st[3] or 0))
      u8(a + 2, st[4] or 0)
    else
      u8(a, 0) u8(a + 1, 0)
    end
  end
end

local BGM_ON = true
local function init_audio()
  sfx_steps(0, 1, { { 62, 15, 4 } })                                     -- 摸牌
  sfx_steps(1, 1, { { 40, 3, 8}, {34, 3, 6} })                           -- 切牌
  sfx_steps(2, 1, { { 45, 3, 9 }, { 38, 3, 8 }, { 30, 15, 6 } })         -- 吃/碰
  sfx_steps(3, 2, { { 48, 3, 10 }, { 33, 3, 9 }, { 22, 15, 10 } })       -- 杠
  sfx_steps(4, 3, { { 0, 15, 6 }, { 72, 3, 6 }, { 76, 3, 6 }, { 79, 3, 8 } }) -- 立直
  sfx_steps(5, 4, { { 67, 3, 9 }, { 71, 3, 9 }, { 74, 3, 10 }, { 79, 3, 12 } }) -- 荣和
  sfx_steps(6, 4, { { 62, 3, 9 }, { 67, 3, 9 }, { 71, 3, 10 }, { 74, 3, 11 }, { 79, 3, 13 } }) -- 自摸
  sfx_steps(7, 5, { { 57, 3, 8 }, { 52, 3, 7 }, { 45, 3, 6 } })          -- 流局
  sfx_steps(8, 1, { { 70, 3, 5 } })                                      -- 光标
  sfx_steps(9, 1, { { 64, 3, 6 }, { 71, 3, 6 } })                        -- 确认
  sfx_steps(10, 1, { { 26, 3, 8 }, { 26, 3, 6 } })                       -- 非法
  sfx_steps(11, 2, { { 30, 15, 6 }, { 42, 15, 5 }, { 35, 15, 7 } })      -- 掷骰
  sfx_steps(12, 1, { { 55, 15, 3 } })                                    -- 配牌
  sfx_steps(13, 1, { { 84, 10, 5 }, { 79, 10, 5 } })                     -- 点数结算
  sfx_steps(14, 2, { { 50, 3, 7 }, { 45, 3, 6 }, { 40, 3, 5 } })         -- 暂停
  -- BGM：低音 + 琶音（Pattern 0 循环）
  sfx_steps(20, 6, {
    { 33, 11, 5 }, { 0 }, { 40, 11, 4 }, { 0 }, { 45, 11, 4 }, { 0 },
    { 38, 11, 5 }, { 0 }, { 45, 11, 4 }, { 0 }, { 40, 11, 4 }, { 0 },
    { 31, 11, 5 }, { 0 }, { 38, 11, 4 }, { 0 }, { 43, 11, 4 }, { 0 },
    { 33, 11, 5 }, { 0 }, { 40, 11, 4 }, { 0 }, { 45, 11, 4 }, { 0 },
  })
  sfx_steps(21, 6, {
    { 0 }, { 74, 10, 3 }, { 0 }, { 76, 10, 3 }, { 0 }, { 0 },
    { 0 }, { 74, 10, 3 }, { 0 }, { 71, 10, 3 }, { 0 }, { 0 },
    { 0 }, { 69, 10, 3 }, { 0 }, { 71, 10, 3 }, { 0 }, { 0 },
    { 0 }, { 69, 10, 3 }, { 0 }, { 67, 10, 3 }, { 0 }, { 0 },
  })
  local mb = 0x063800
  u8(mb + 6, 21)
  u8(mb + 7, 22)
  u8(mb + 8, 3)
end

local function set_bgm(on)
  if on then music(0, 400, 0xC0) else music(-1, 200) end
end

-- ================================================================ 游戏状态

local G = {}
local T = 0              -- 全局帧
local PROMPT = nil       -- 当前输入请求
local PROMPT_RESULT = nil
local CO = nil           -- 主协程
local TEST_MODE = false

local function wait(n) coroutine.yield(n) end

local function ask(ptype, opts, seat, reveal)
  PROMPT = { type = ptype, opts = opts, sel = 1, seat = seat, reveal = reveal, t = 0 }
  PROMPT_RESULT = nil
  coroutine.yield("input")
  local r = PROMPT_RESULT
  PROMPT = nil
  return r
end

local function banner(text, col, dur)
  G.banner = { text = text, col = col or C_GOLD, t = dur or 55 }
end

local function log_msg(text, col)
  G.log[#G.log + 1] = { text, col or C_TEXT }
  if #G.log > 3 then table.remove(G.log, 1) end
end

local function pname(seat) return "P" .. (seat + 1) end

local function new_game(humans, level)
  G = {
    players = {},
    humans = humans,     -- 人类座位列表
    level = level,       -- 1 简单 2 普通 3 困难
    dealer = 0, dealer0 = 0,
    hand_no = 1, honba = 0, sticks = 0,
    wall = {}, live_ptr = 53, rin_ptr = 123,
    dora = {}, ura = {},
    turn = 0, kans = 0, calls = 0,
    first_round = true, last_go = false,
    ippatsu = { [0] = false, false, false, false },
    drawn = nil, drawn_seat = -1,
    last_discard = nil, last_tile = false,
    banner = nil, log = {},
    viewer = humans[1] or 0,
    privacy = #humans > 1,
    panel = nil, deltas = nil,
    over = false,
    stats = { riichi = 0, wins = 0, best = 0 },
  }
  for s = 0, 3 do
    G.players[s] = {
      seat = s, hand = {}, melds = {}, river = {},
      score = 25000, riichi = false, daburu = false,
      discards = 0, furiten_kinds = {}, furiten_perm = false,
      is_ai = false, riichi_turn = -1,
    }
  end
  for s = 0, 3 do
    local is_h = false
    for _, h in ipairs(humans) do if h == s then is_h = true end end
    G.players[s].is_ai = not is_h
  end
  G.fast = #humans == 0
end

local function seat_wind_of(seat) return (seat - G.dealer + 4) % 4 end

local function wall_left() return 123 - G.live_ptr end

local function build_wall()
  local w = {}
  for k = 0, 33 do
    for c = 0, 3 do w[#w + 1] = k * 4 + c end
  end
  for i = #w, 2, -1 do
    local j = flr(rnd(i)) + 1
    w[i], w[j] = w[j], w[i]
  end
  G.wall = w
  G.live_ptr = 53
  G.rin_ptr = 123
end

local function flip_dora()
  local i = #G.dora + 1
  if i <= 5 then
    G.dora[i] = kind_of(G.wall[138 - 2 * i])
    G.ura[i] = kind_of(G.wall[137 - 2 * i])
  end
end

local function draw_live()
  local c = G.wall[G.live_ptr]
  G.live_ptr = G.live_ptr + 1
  if G.live_ptr > 122 then G.last_tile = true end
  return c
end

local function draw_rinshan()
  local c = G.wall[G.rin_ptr]
  G.rin_ptr = G.rin_ptr + 1
  return c
end

local function remove_code(hand, code)
  for i = 1, #hand do
    if hand[i] == code then table.remove(hand, i) return true end
  end
  return false
end

-- 从手牌取 kind 的 n 张（红宝后取）；返回 code 列表（不足返回 nil）
local function take_kind(hand, k, n, keep_red)
  local got = {}
  -- 先取非红
  for pass = 1, 2 do
    for i = 1, #hand do
      if #got >= n then break end
      local c = hand[i]
      if kind_of(c) == k then
        local red = is_red(c)
        if (pass == 1) == (not red) then got[#got + 1] = c end
      end
    end
  end
  if #got < n then return nil end
  for i = 1, #got do remove_code(hand, got[i]) end
  return got
end

local function find_kind(hand, k)
  for i = 1, #hand do
    if kind_of(hand[i]) == k then return hand[i] end
  end
  return nil
end

local function add_to_hand(P, code)
  P.hand[#P.hand + 1] = code
  sort_hand(P.hand)
end

-- ================================================================ 和牌检查（场况包装）

local function build_SC(seat, mode)
  local P = G.players[seat]
  local dora_k, ura_k = {}, {}
  for i = 1, #G.dora do dora_k[i] = dora_next(G.dora[i]) end
  if P.riichi then
    for i = 1, #G.ura do ura_k[i] = dora_next(G.ura[i]) end
  end
  return {
    seat_wind = seat_wind_of(seat),
    round_wind = 0,
    riichi = P.riichi,
    daburu = P.daburu,
    ippatsu = P.riichi and G.ippatsu[seat] or false,
    tsumo = mode == "tsumo",
    rinshan = mode == "tsumo" and G.rinshan_win or false,
    haitei = mode == "tsumo" and G.haitei_flag or false,
    houtei = mode == "ron" and G.haitei_flag or false,
    tenhou = G.first_round and seat == G.dealer and G.calls == 0,
    chiihou = G.first_round and seat ~= G.dealer and G.calls == 0,
    dora = dora_k,
    ura = ura_k,
  }
end

-- 评分（无役返回 nil）
local function eval_win(seat, wcode, mode)
  local P = G.players[seat]
  local h = {}
  for i = 1, #P.hand do h[i] = P.hand[i] end
  local sc = score_hand(h, P.melds, wcode, mode, build_SC(seat, mode))
  return sc
end

-- 能否荣和
local function can_ron(seat, code)
  local P = G.players[seat]
  local k = kind_of(code)
  for i = 1, #P.river do
    if kind_of(P.river[i].code) == k then return false end
  end
  if P.furiten_kinds[k] then return false end
  local h = {}
  for i = 1, #P.hand do h[i] = P.hand[i] end
  local cnt = hand_to_cnt(h)
  cnt[k] = cnt[k] + 1
  if not hand_wins(cnt, #P.melds) then return false end
  return eval_win(seat, code, "ron") ~= nil
end

-- ================================================================ 对局流程（协程）

local ai_act, ai_call_choice  -- 前向声明（AI 部分实现）

local function focus(seat)
  if #G.humans > 1 and G.viewer ~= seat then
    ask("pass", nil, seat, false)
    G.viewer = seat
  end
end

-- 自摸判定：可和返回 result，否则 nil
local function tsumo_check(seat, tile)
  local P = G.players[seat]
  local cnt = hand_to_cnt(P.hand)
  cnt[kind_of(tile)] = cnt[kind_of(tile)] + 1
  if not hand_wins(cnt, #P.melds) then return nil end
  local sc = eval_win(seat, tile, "tsumo")
  if sc == nil then return nil end
  local go = true
  if not P.is_ai and not P.riichi then
    focus(seat)
    go = ask("tsumo", nil, seat, true)
  end
  if not go then
    P.furiten_kinds = {}  -- 摸牌见逃重置（规则上自摸见逃只留立直相关，此处简化）
    return nil
  end
  return { type = "tsumo", seat = seat, code = tile, sc = sc }
end

local function do_discard(seat, code, riichi_decl)
  local P = G.players[seat]
  local from_drawn = (G.drawn == code and G.drawn_seat == seat)
  if from_drawn then
    G.drawn = nil
  else
    remove_code(P.hand, code)
    if G.drawn ~= nil and G.drawn_seat == seat then
      -- 打手牌则摸牌入手
      add_to_hand(P, G.drawn)  -- add_to_hand 定义见下（排序插入）
      G.drawn = nil
    end
  end
  sort_hand(P.hand)
  local was_first = (P.discards == 0 and G.calls == 0)
  P.river[#P.river + 1] = {
    code = code, kind = kind_of(code),
    riichi = riichi_decl, tsumo = from_drawn, taken = nil,
  }
  G.last_discard = { seat = seat, code = code, t = 0 }
  G.discard_seq[#G.discard_seq + 1] = { seat = seat, kind = kind_of(code) }
  if riichi_decl then
    P.riichi = true
    P.daburu = was_first
    P.score = P.score - 1000
    G.sticks = G.sticks + 1
    G.ippatsu[seat] = true
    G.riichi_count = G.riichi_count + 1
    P.riichi_seq = #G.discard_seq
    if seat == 0 and not P.is_ai then G.stats.riichi = G.stats.riichi + 1 end
    banner("立直！", C_GOLD)
    log_msg(pname(seat) .. " 立直", C_GOLD)
    sfx(4)
    wait(24)
  else
    sfx(1)
    log_msg(pname(seat) .. " 切 " .. code_name(code))
    wait(6)
  end
  P.discards = P.discards + 1
  G.first_round = false
end

local function apply_kan(seat, mtype, k, src_code, from)
  local P = G.players[seat]
  if mtype == "ankan" then
    local codes = take_kind(P.hand, k, 4, true)
    P.melds[#P.melds + 1] = {
      type = "ankan", k = k, src = codes[1],
      others = { codes[2], codes[3], codes[4] }, from = seat,
    }
  elseif mtype == "kakan" then
    local code = take_kind(P.hand, k, 1, true)
    for i = 1, #P.melds do
      local m = P.melds[i]
      if m.type == "pon" and m.k == k then
        m.type = "kakan"
        m.others[#m.others + 1] = code[1]
      end
    end
  else -- mkan 大明杠
    local codes = take_kind(P.hand, k, 3, true)
    P.melds[#P.melds + 1] = {
      type = "mkan", k = k, src = src_code, others = codes, from = from,
    }
    for i = 1, #G.players[from].river do
      local r = G.players[from].river[i]
      if r.code == src_code then r.taken = seat end
    end
  end
  G.kans = G.kans + 1
  G.calls = G.calls + 1
  for i = 0, 3 do G.ippatsu[i] = false end
  if #G.dora < 5 then flip_dora() end
  banner(pname(seat) .. " 杠", C_TEXT)
  log_msg(pname(seat) .. " 杠 " .. KIND_NAME[k], C_TEXT)
  sfx(3)
  wait(16)
end

local function apply_pon_chi(seat, mtype, k, base, src_code, others, from)
  local P = G.players[seat]
  for i = 1, #others do remove_code(P.hand, others[i]) end
  P.melds[#P.melds + 1] = {
    type = mtype, k = base, src = src_code, others = others, from = from,
  }
  for i = 1, #G.players[from].river do
    local r = G.players[from].river[i]
    if r.code == src_code then r.taken = seat end
  end
  G.calls = G.calls + 1
  for i = 0, 3 do G.ippatsu[i] = false end
  banner(pname(seat) .. (mtype == "pon" and " 碰" or " 吃"), C_TEXT)
  log_msg(pname(seat) .. (mtype == "pon" and " 碰 " or " 吃 ") .. KIND_NAME[k], C_TEXT)
  sfx(2)
  wait(16)
end

-- 人类打牌提示：预计算立直可行/杠选项
local function human_discard_prompt(seat)
  local P = G.players[seat]
  local has_drawn = G.drawn ~= nil and G.drawn_seat == seat
  local cnt = hand_to_cnt(P.hand)
  if has_drawn then cnt[kind_of(G.drawn)] = cnt[kind_of(G.drawn)] + 1 end
  local n_melds = #P.melds
  local ok_kind = {}
  local any = false
  for k = 0, 33 do
    if cnt[k] > 0 then
      local c2 = cnt_copy(cnt)
      c2[k] = c2[k] - 1
      ok_kind[k] = is_tenpai(c2, n_melds)
      if ok_kind[k] then any = true end
    end
  end
  local ri_ok = {}
  for i = 1, #P.hand do ri_ok[i] = ok_kind[kind_of(P.hand[i])] end
  if has_drawn then ri_ok[#P.hand + 1] = ok_kind[kind_of(G.drawn)] end
  local riichi_any = #P.melds == 0 and not P.riichi and P.score >= 1000 and any
  -- 杠选项
  local kans = {}
  local cnt_h = hand_to_cnt(P.hand)
  for k = 0, 33 do
    if cnt_h[k] == 4 then
      kans[#kans + 1] = { ktype = "ankan", k = k, label = "暗杠 " .. KIND_NAME[k] }
    end
  end
  for i = 1, #P.melds do
    local m = P.melds[i]
    if m.type == "pon" and cnt_h[m.k] >= 1 then
      kans[#kans + 1] = { ktype = "kakan", k = m.k, label = "加杠 " .. KIND_NAME[m.k] }
    end
  end
  PROMPT = {
    type = "discard", seat = seat, reveal = true,
    cursor = #P.hand + (has_drawn and 1 or 0),
    ri = false, ri_ok = ri_ok, riichi_any = riichi_any,
    kans = kans, kmenu = nil, t = 0,
  }
  PROMPT_RESULT = nil
  coroutine.yield("input")
  local r = PROMPT_RESULT
  PROMPT = nil
  PROMPT_RESULT = nil
  return r
end

-- 单个玩家回合：摸牌(可无)→自摸判定→杠循环→打牌；和牌返回 result
local function player_turn(seat, drawn, rinshan)
  local P = G.players[seat]
  G.drawn = drawn
  G.drawn_seat = seat
  G.rinshan_win = rinshan
  if drawn then
    sfx(0)
    wait(4)
    local res = tsumo_check(seat, drawn)
    if res then return res end
    G.ippatsu[seat] = false
    P.furiten_kinds = {}
  end
  while true do
    local act
    if P.is_ai or P.riichi then
      wait(G.fast and 2 or 8 + T % 6)
      if P.riichi then
        act = { type = "discard", code = G.drawn or P.hand[#P.hand] }
      else
        act = ai_act(seat)
      end
    else
      focus(seat)
      act = human_discard_prompt(seat)
    end
    if act.type == "ankan" or act.type == "kakan" then
      apply_kan(seat, act.type, act.k, nil, seat)
      local tile = draw_rinshan()
      G.drawn = tile
      G.rinshan_win = true
      sfx(0)
      wait(4)
      local res = tsumo_check(seat, tile)
      if res then return res end
      G.ippatsu[seat] = false
      -- 杠后继续打牌循环（岭上牌在手，立直中只允许维持听牌的杠）
    else
      do_discard(seat, act.code, act.type == "riichi")
      return nil
    end
  end
end

-- 供的吃变体：返回 {base, a, b}（a/b 为手牌 kind）或 nil
local function chi_variants(hand, k)
  local cnt = hand_to_cnt(hand)
  local out = {}
  local defs = { { k - 2, k - 1 }, { k - 1, k + 1 }, { k + 1, k + 2 } }
  for i = 1, 3 do
    local a, b = defs[i][1], defs[i][2]
    local ok = true
    local suits = flr(k / 9)
    for _, x in ipairs({ a, b }) do
      if x < 0 or x > 26 or flr(x / 9) ~= suits or (cnt[x] or 0) < 1 then ok = false end
    end
    if ok then out[#out + 1] = { a = a, b = b } end
  end
  return out
end

-- 打牌后的鸣牌窗口：返回和牌 result 或 {seat=鸣家, type=...} 或 nil
local function resolve_calls(discarder, code)
  -- 荣和（座次顺，多人可和）
  local winners = {}
  for i = 1, 3 do
    local s = (discarder + i) % 4
    local P = G.players[s]
    if can_ron(s, code) then
      local take = true
      if not P.is_ai and not P.riichi then
        focus(s)
        take = ask("ron", nil, s, true)
      end
      if take then
        winners[#winners + 1] = s
      else
        P.furiten_kinds[kind_of(code)] = true
        if P.riichi then P.furiten_perm = true end
      end
    end
  end
  if #winners > 0 then
    return { win = true, winners = winners, payer = discarder, code = code }
  end
  -- 碰 / 大明杠（座次顺）
  for i = 1, 3 do
    local s = (discarder + i) % 4
    local P = G.players[s]
    if not P.riichi then
      local cnt = hand_to_cnt(P.hand)
      local k = kind_of(code)
      local can_pon = (cnt[k] or 0) >= 2
      local can_mkan = (cnt[k] or 0) >= 3
      if can_pon or can_mkan then
        local choice = nil
        if P.is_ai then
          choice = ai_call_choice(s, k, code, discarder, can_pon, can_mkan, false)
        else
          local opts = {}
          if can_mkan then opts[#opts + 1] = { type = "mkan", label = "杠" } end
          if can_pon then opts[#opts + 1] = { type = "pon", label = "碰" } end
          opts[#opts + 1] = { type = "pass", label = "过" }
          focus(s)
          local pick = ask("call", opts, s, true)
          if pick then choice = pick end
        end
        if choice and choice.type == "mkan" then
          apply_kan(s, "mkan", k, code, discarder)
          return { seat = s, type = "mkan" }
        elseif choice and choice.type == "pon" then
          local others = take_kind(P.hand, k, 2, true)
          apply_pon_chi(s, "pon", k, k, code, others, discarder)
          return { seat = s, type = "pon" }
        end
      end
    end
  end
  -- 吃（仅下家）
  local s = (discarder + 1) % 4
  local P = G.players[s]
  if not P.riichi then
    local k = kind_of(code)
    if k < 27 then
      local vars = chi_variants(P.hand, k)
      if #vars > 0 then
        local choice = nil
        if P.is_ai then
          choice = ai_call_choice(s, k, code, discarder, false, false, vars)
        else
          local opts = {}
          for i = 1, #vars do
            opts[#opts + 1] = { type = "chi", a = vars[i].a, b = vars[i].b,
              label = "吃 " .. KIND_NAME[vars[i].a] .. KIND_NAME[vars[i].b] }
          end
          opts[#opts + 1] = { type = "pass", label = "过" }
          focus(s)
          local pick = ask("call", opts, s, true)
          if pick then choice = pick end
        end
        if choice and choice.type == "chi" then
          local a = take_kind(P.hand, choice.a, 1, true)
          local b = take_kind(P.hand, choice.b, 1, true)
          local base = min(min(choice.a, choice.b), k)
          apply_pon_chi(s, "chi", k, base, code, { a[1], b[1] }, discarder)
          return { seat = s, type = "chi" }
        end
      end
    end
  end
  return nil
end

-- 荒牌流局
local function hand_ryuukyoku()
  local tenpai = {}
  local n = 0
  for s = 0, 3 do
    local P = G.players[s]
    local t = P.riichi
    if not t then
      local cnt = hand_to_cnt(P.hand)
      t = is_tenpai(cnt, #P.melds)
    end
    tenpai[s] = t
    if t then n = n + 1 end
  end
  return { type = "ryuukyoku", tenpai = tenpai, n_tenpai = n }
end

-- 一局主循环
local function play_hand()
  G.skip_draw = false
  G.rinshan_due = false
  while true do
    local seat = G.turn
    local drawn, rin = nil, false
    if G.skip_draw then
      G.skip_draw = false
      G.haitei_flag = false
    elseif G.rinshan_due then
      G.rinshan_due = false
      drawn = draw_rinshan()
      rin = true
      G.haitei_flag = false
    else
      if wall_left() <= 0 then return hand_ryuukyoku() end
      drawn = draw_live()
      G.haitei_flag = wall_left() <= 0
    end
    local res = player_turn(seat, drawn, rin)
    if res then return res end
    -- 四家立直流局
    if G.riichi_count >= 4 then
      return { type = "abort", tenpai = { [0] = true, true, true, true }, n_tenpai = 4 }
    end
    local cres = resolve_calls(seat, G.last_discard.code)
    if cres then
      if cres.win then
        return { type = "ron", winners = cres.winners, payer = cres.payer, code = cres.code }
      end
      G.turn = cres.seat
      if cres.type == "mkan" then
        G.rinshan_due = true
      else
        G.skip_draw = true
      end
    else
      G.turn = (seat + 1) % 4
    end
  end
end

-- ================================================================ 开局与结算

-- 支付表：返回 { {from, to, amount} ... }
local function calc_pay(winner, basic, mode, payer_seat)
  local out = {}
  local hb = G.honba
  local w_dealer = winner == G.dealer
  if mode == "tsumo" then
    for s = 0, 3 do
      if s ~= winner then
        local amt
        if w_dealer then
          amt = c100(basic * 2)
        elseif s == G.dealer then
          amt = c100(basic * 2)
        else
          amt = c100(basic)
        end
        amt = amt + 100 * hb
        out[#out + 1] = { from = s, to = winner, amount = amt }
      end
    end
  else
    local amt = (w_dealer and c100(basic * 6) or c100(basic * 4)) + 300 * hb
    out[#out + 1] = { from = payer_seat, to = winner, amount = amt }
  end
  return out
end

local function settle_hand(res)
  G.deltas = { [0] = 0, 0, 0, 0 }
  G.delta_pop = nil
  local mode = res.type
  if mode == "tsumo" or mode == "ron" then
    local wins = mode == "tsumo" and { res.seat } or res.winners
    local panel = { type = "win", mode = mode, payer = res.payer, entries = {} }
    for wi = 1, #wins do
      local s = wins[wi]
      local P = G.players[s]
      local sc
      if mode == "tsumo" then
        sc = res.seat == s and res.sc or eval_win(s, res.code, "tsumo")
      else
        sc = eval_win(s, res.code, "ron")
      end
      local pays = calc_pay(s, sc.basic, mode, res.payer)
      local total = 0
      for i = 1, #pays do
        local p = pays[i]
        G.players[p.from].score = G.players[p.from].score - p.amount
        G.players[s].score = G.players[s].score + p.amount
        G.deltas[p.from] = G.deltas[p.from] - p.amount
        total = total + p.amount
      end
      G.deltas[s] = G.deltas[s] + total
      if wi == 1 and G.sticks > 0 then
        G.players[s].score = G.players[s].score + 1000 * G.sticks
        G.deltas[s] = G.deltas[s] + 1000 * G.sticks
        total = total + 1000 * G.sticks
        G.sticks = 0
      end
      if s == 0 and not P.is_ai then
        G.stats.wins = G.stats.wins + 1
        if total > G.stats.best then G.stats.best = total end
      end
      local hcopy = {}
      for i = 1, #P.hand do hcopy[i] = P.hand[i] end
      hcopy[#hcopy + 1] = res.code
      sort_hand(hcopy)
      panel.entries[#panel.entries + 1] = {
        seat = s, hand = hcopy, melds = P.melds, sc = sc,
        total = total, is_dealer = s == G.dealer,
      }
    end
    G.panel = panel
    sfx(mode == "tsumo" and 6 or 5)
    G.reveal_all = true
    if G.fast then wait(160) else ask("settle") end
    G.reveal_all = false
  else
    -- 流局
    local panel = { type = "ryuukyoku", tenpai = res.tenpai, hands = {} }
    if res.type == "ryuukyoku" then
      local n = res.n_tenpai
      if n >= 1 and n <= 3 then
        for s = 0, 3 do
          if res.tenpai[s] then
            local gain = (n == 1 and 3000) or (n == 2 and 1500) or 1000
            G.players[s].score = G.players[s].score + gain
            G.deltas[s] = G.deltas[s] + gain
          else
            local loss = (n == 1 and 1000) or (n == 2 and 1500) or 3000
            G.players[s].score = G.players[s].score - loss
            G.deltas[s] = G.deltas[s] - loss
          end
        end
      end
    end
    for s = 0, 3 do
      local hcopy = {}
      for i = 1, #G.players[s].hand do hcopy[i] = G.players[s].hand[i] end
      sort_hand(hcopy)
      panel.hands[s] = { hand = hcopy, melds = G.players[s].melds }
    end
    G.panel = panel
    sfx(7)
    G.reveal_all = true
    if G.fast then wait(160) else ask("settle") end
    G.reveal_all = false
  end
  G.delta_pop = {}
  for s = 0, 3 do
    if G.deltas[s] ~= 0 then G.delta_pop[s] = { amt = G.deltas[s], t = 240 } end
  end
end

local function advance_hand(res)
  for s = 0, 3 do
    if G.players[s].score < 0 then
      G.over = "bust"
      return
    end
  end
  local keep = false
  if res.type == "tsumo" and res.seat == G.dealer then keep = true end
  if res.type == "ron" then
    for _, s in ipairs(res.winners) do
      if s == G.dealer then keep = true end
    end
  end
  if (res.type == "ryuukyoku" or res.type == "abort")
    and res.tenpai and res.tenpai[G.dealer] then
    keep = true
  end
  if keep then
    G.honba = G.honba + 1
  else
    G.dealer = (G.dealer + 1) % 4
    G.hand_no = G.hand_no + 1
    G.honba = 0
  end
  if G.hand_no > 4 then G.over = "end" end
end

local function start_hand()
  for s = 0, 3 do
    local P = G.players[s]
    P.hand = {} P.melds = {} P.river = {}
    P.riichi = false P.daburu = false P.discards = 0
    P.furiten_kinds = {} P.furiten_perm = false
    P.riichi_turn = -1
  end
  G.kans = 0 G.calls = 0
  G.first_round = true G.last_tile = false G.haitei_flag = false
  G.ippatsu = { [0] = false, false, false, false }
  G.drawn = nil G.drawn_seat = -1 G.last_discard = nil
  G.riichi_count = 0
  G.panel = nil G.deltas = nil G.delta_pop = nil
  G.banner = nil G.log = {}
  G.discard_seq = {}
  G.dora = {} G.ura = {}
  G.turn = G.dealer
  build_wall()
  flip_dora()
  -- 掷骰演出
  local d1, d2 = 1 + flr(rnd(6)), 1 + flr(rnd(6))
  G.dice = { d1, d2, t = 36 }
  local hb_txt = G.honba > 0 and ("・" .. NUM_CH[G.honba] .. "本场") or ""
  banner("东" .. NUM_CH[G.hand_no] .. "局" .. hb_txt
    .. (G.hand_no == 1 and G.honba == 0 and ("・起家 " .. pname(G.dealer0)) or ""),
    C_GOLD, 66)
  sfx(11)
  wait(30)
  -- 配牌
  local idx = 1
  for i = 1, 13 do
    for j = 0, 3 do
      local s = (G.dealer + j) % 4
      G.players[s].hand[#G.players[s].hand + 1] = G.wall[idx]
      idx = idx + 1
    end
    sfx(12)
    wait(2)
  end
  for s = 0, 3 do sort_hand(G.players[s].hand) end
  G.deal_done = true
  wait(14)
end

-- 终局排名：分数降序，同分按起家顺位
local function ranking()
  local r = { 0, 1, 2, 3 }
  local function order_key(s) return (s - G.dealer0 + 4) % 4 end
  table.sort(r, function(a, b)
    local sa, sb = G.players[a].score, G.players[b].score
    if sa ~= sb then return sa > sb end
    return order_key(a) < order_key(b)
  end)
  return r
end

local SAVE = { games = 0, wins = 0, riichi = 0, best = 0 }

local function load_save()
  SAVE.games = dget(0)
  SAVE.wins = dget(1)
  SAVE.riichi = dget(2)
  SAVE.best = dget(3)
end

local function save_stats()
  SAVE.games = SAVE.games + 1
  SAVE.wins = SAVE.wins + G.stats.wins
  SAVE.riichi = SAVE.riichi + G.stats.riichi
  if G.stats.best > SAVE.best then SAVE.best = G.stats.best end
  dset(0, SAVE.games)
  dset(1, SAVE.wins)
  dset(2, SAVE.riichi)
  dset(3, SAVE.best)
  fflush()
end

local function game_flow()
  local d1, d2 = 1 + flr(rnd(6)), 1 + flr(rnd(6))
  G.dealer0 = (d1 + d2) % 4
  G.dealer = G.dealer0
  G.hand_no = 1
  G.honba = 0
  G.sticks = 0
  G.over = false
  while true do
    start_hand()
    local res = play_hand()
    settle_hand(res)
    advance_hand(res)
    if G.over then break end
  end
  G.results = { rank = ranking() }
  if G.fast then
    wait(140)
  else
    ask("results")
  end
  save_stats()
  G.results = nil
end

-- ================================================================ AI（三档，确定性）

-- 全局打牌序列（安全牌判定用）；do_discard 追加
-- （G.discard_seq 在 start_hand 初始化）

local function shanten14(cnt, n_melds)
  local best = 99
  for k = 0, 33 do
    if cnt[k] > 0 then
      cnt[k] = cnt[k] - 1
      local s = shanten_hand(cnt, n_melds)
      cnt[k] = cnt[k] + 1
      if s < best then best = s end
    end
  end
  return best
end

-- 可见牌计数（ rivers + melds + 自己手牌/摸牌 + 宝牌指示牌 ）
local function visible_counts(seat)
  local v = {}
  for i = 0, 33 do v[i] = 0 end
  for s = 0, 3 do
    local P = G.players[s]
    for i = 1, #P.river do v[P.river[i].kind] = v[P.river[i].kind] + 1 end
    for i = 1, #P.melds do
      local m = P.melds[i]
      v[m.k] = v[m.k] + (#m.others + 1)
    end
  end
  local P = G.players[seat]
  for i = 1, #P.hand do v[kind_of(P.hand[i])] = v[kind_of(P.hand[i])] + 1 end
  if G.drawn and G.drawn_seat == seat then v[kind_of(G.drawn)] = v[kind_of(G.drawn)] + 1 end
  for i = 1, #G.dora do v[G.dora[i]] = v[G.dora[i]] + 1 end
  return v
end

local function is_dora_kind(k)
  for i = 1, #G.dora do
    if dora_next(G.dora[i]) == k then return true end
  end
  return RED_KIND[k] ~= nil
end

-- 实际弃牌 code：同 kind 优先打非红
local function pick_code(seat, k)
  local P = G.players[seat]
  for i = 1, #P.hand do
    local c = P.hand[i]
    if kind_of(c) == k and not is_red(c) then return c end
  end
  if G.drawn and G.drawn_seat == seat and kind_of(G.drawn) == k and not is_red(G.drawn) then
    return G.drawn
  end
  for i = 1, #P.hand do
    if kind_of(P.hand[i]) == k then return P.hand[i] end
  end
  if G.drawn and G.drawn_seat == seat and kind_of(G.drawn) == k then return G.drawn end
  return P.hand[1]
end

-- 某立直家眼中的安全牌集合
local function safe_kinds_vs(opp)
  local set = {}
  local R = G.players[opp]
  for i = 1, #R.river do set[R.river[i].kind] = true end
  local idx = R.riichi_seq or 0
  for i = idx, #G.discard_seq do set[G.discard_seq[i].kind] = true end
  return set
end

local function opp_riichi_list(seat)
  local out = {}
  for s = 0, 3 do
    if s ~= seat and G.players[s].riichi then out[#out + 1] = s end
  end
  return out
end

local function danger_of(k, opps, vcnt)
  local total = 0
  for oi = 1, #opps do
    local safe = safe_kinds_vs(opps[oi])
    if safe[k] then
      total = total + 0
    elseif k >= 27 then
      total = total + (4 - (vcnt[k] or 0) <= 0 and 0 or 3)
    else
      local n = k % 9
      -- 筋：±3 有其河牌较安全
      local suji = false
      if n >= 3 then
        local j = k - 3
        for _, s in ipairs(opps) do
          for i = 1, #G.players[s].river do
            if G.players[s].river[i].kind == j then suji = true end
          end
        end
      end
      if not suji and n <= 5 then
        local j = k + 3
        if j < 27 and flr(j / 9) == flr(k / 9) then
          for _, s in ipairs(opps) do
            for i = 1, #G.players[s].river do
              if G.players[s].river[i].kind == j then suji = true end
            end
          end
        end
      end
      total = total + (suji and 1 or 3)
      if n >= 2 and n <= 6 then total = total + 1 end
    end
  end
  return total
end

-- 构造弃牌候选并评分；返回按优劣排序的 {{k, sh, uke, score}, ...}
local function ai_candidates(seat)
  local P = G.players[seat]
  local cnt = hand_to_cnt(P.hand)
  if G.drawn and G.drawn_seat == seat then cnt[kind_of(G.drawn)] = cnt[kind_of(G.drawn)] + 1 end
  local n_melds = #P.melds
  local vcnt = visible_counts(seat)
  local lv = G.level

  -- 第一轮：向听
  local cands = {}
  for k = 0, 33 do
    if cnt[k] > 0 then
      local c2 = cnt_copy(cnt)
      c2[k] = c2[k] - 1
      cands[#cands + 1] = { k = k, sh = shanten_hand(c2, n_melds), uke = 0, score = 0 }
    end
  end
  table.sort(cands, function(a, b)
    if a.sh ~= b.sh then return a.sh < b.sh end
    return a.k < b.k
  end)
  local best_sh = cands[1].sh
  -- 第二轮：进张面（仅最优向听候选，最多 6 个）
  local n_top = 0
  for i = 1, #cands do
    if cands[i].sh == best_sh and n_top < 6 then
      local k = cands[i].k
      local c2 = cnt_copy(cnt)
      c2[k] = c2[k] - 1
      local ws = waits_of(c2, n_melds)
      local uke = 0
      for w = 1, #ws do
        local r = 4 - (vcnt[ws[w]] or 0)
        if r > 0 then uke = uke + r end
      end
      cands[i].uke = uke
      n_top = n_top + 1
    end
  end
  -- 评分
  local opps = (lv >= 3) and opp_riichi_list(seat) or {}
  local defend = #opps > 0 and best_sh >= 1
  for i = 1, #cands do
    local c = cands[i]
    c.score = c.sh * 100 - c.uke * 2
    if lv >= 2 then
      -- 宝牌系尽量保留；孤张字牌先切
      if is_dora_kind(c.k) and cnt[c.k] <= 2 then c.score = c.score + 25 end
      if c.k >= 27 and cnt[c.k] == 1 then
        local yak = c.k >= 31 or c.k == 27 + seat_wind_of(seat) or c.k == 27
        if not yak then c.score = c.score - 18 end
      end
      if is_yao(c.k) and c.k < 27 and cnt[c.k] == 1 then
        local adj = false
        for d = -2, 2 do
          local j = c.k + d
          if d ~= 0 and j >= 0 and j < 27 and flr(j / 9) == flr(c.k / 9) and cnt[j] > 0 then adj = true end
        end
        if not adj then c.score = c.score - 8 end
      end
    end
    if defend then
      c.score = c.score + danger_of(c.k, opps, vcnt) * 30
    end
  end
  table.sort(cands, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    if a.sh ~= b.sh then return a.sh < b.sh end
    return a.k < b.k
  end)
  return cands
end

-- 立直决策
local function ai_riichi_ok(seat, ten_cands)
  local lv = G.level
  if lv == 1 then return false end
  local P = G.players[seat]
  if P.riichi or #P.melds > 0 or P.score < 1000 then return false end
  if lv == 2 then return true end
  -- 困难：好型听牌才立直；终局追分放宽
  local best_uke = 0
  for i = 1, #ten_cands do
    if ten_cands[i].uke > best_uke then best_uke = ten_cands[i].uke end
  end
  if best_uke >= 8 then return true end
  if best_uke >= 4 then
    -- 领先保守、落后激进
    local my = P.score
    local below = 0
    for s = 0, 3 do
      if s ~= seat and G.players[s].score < my then below = below + 1 end
    end
    if G.hand_no >= 4 or below <= 1 then return true end
    return false
  end
  -- 终局必须进攻
  if G.hand_no >= 4 then
    local lead = true
    for s = 0, 3 do
      if s ~= seat and G.players[s].score > P.score + 6000 then lead = false end
    end
    if not lead then return true end
  end
  return false
end

local function ai_kan_decision(seat)
  if G.level == 1 then return nil end
  local P = G.players[seat]
  if P.riichi then return nil end
  local cnt_h = hand_to_cnt(P.hand)
  local n_melds = #P.melds
  local cnt14 = cnt_copy(cnt_h)
  if G.drawn and G.drawn_seat == seat then cnt14[kind_of(G.drawn)] = cnt14[kind_of(G.drawn)] + 1 end
  local sh_cur = shanten14(cnt14, n_melds)
  for k = 0, 33 do
    if cnt_h[k] == 4 then
      local c2 = cnt_copy(cnt_h)
      c2[k] = 0
      if shanten_regular(c2, n_melds + 1) <= sh_cur then
        return { type = "ankan", k = k }
      end
    end
  end
  for i = 1, #P.melds do
    local m = P.melds[i]
    if m.type == "pon" and cnt_h[m.k] >= 1 then
      local c2 = cnt_copy(cnt_h)
      c2[m.k] = c2[m.k] - 1
      if shanten_regular(c2, n_melds) <= sh_cur then
        return { type = "kakan", k = m.k }
      end
    end
  end
  return nil
end

ai_act = function(seat)
  local P = G.players[seat]
  if P.riichi then
    local code = G.drawn or P.hand[#P.hand]
    return { type = "discard", code = code }
  end
  local kan = ai_kan_decision(seat)
  if kan then return kan end
  local cands = ai_candidates(seat)
  -- 立直
  if #P.melds == 0 and P.score >= 1000 and cands[1].sh == 0 then
    local ten = {}
    for i = 1, #cands do
      if cands[i].sh == 0 then ten[#ten + 1] = cands[i] end
    end
    if ai_riichi_ok(seat, ten) then
      -- 选进张最宽的听牌切法
      local best = ten[1]
      for i = 2, #ten do
        if ten[i].uke > best.uke then best = ten[i] end
      end
      return { type = "riichi", code = pick_code(seat, best.k) }
    end
  end
  local c = cands[1]
  return { type = "discard", code = pick_code(seat, c.k) }
end

-- 鸣牌判定
local function call_yaku_ok(seat, k, c2)
  if k >= 31 then return true end
  if k >= 27 and (k == 27 + seat_wind_of(seat) or k == 27) then return true end
  for kk = 31, 33 do
    if (c2[kk] or 0) >= 2 then return true end
  end
  local sw = 27 + seat_wind_of(seat)
  if (c2[sw] or 0) >= 2 then return true end
  -- 断幺路径
  if is_simp(k) then
    local ok = true
    for i = 0, 33 do
      if (c2[i] or 0) > 0 and not is_simp(i) then ok = false break end
    end
    if ok then return true end
  end
  -- 对对和路径
  local tris = 0
  for i = 0, 33 do
    if (c2[i] or 0) >= 3 then tris = tris + 1 end
  end
  return tris >= 2
end

ai_call_choice = function(seat, k, code, from, can_pon, can_mkan, chi_vars)
  if G.level == 1 then return nil end
  local P = G.players[seat]
  local cnt = hand_to_cnt(P.hand)
  local n_melds = #P.melds
  local sh_cur = shanten_hand(cnt, n_melds)
  local lv = G.level
  -- 大明杠
  if can_mkan then
    local c2 = cnt_copy(cnt)
    c2[k] = c2[k] - 3
    local sh_new = shanten_regular(c2, n_melds + 1)
    if call_yaku_ok(seat, k, c2) and sh_new < sh_cur then
      return { type = "mkan" }
    end
  end
  -- 碰
  if can_pon then
    local c2 = cnt_copy(cnt)
    c2[k] = c2[k] - 2
    local sh_new = shanten_regular(c2, n_melds + 1)
    local ok = call_yaku_ok(seat, k, c2)
    if lv == 2 then
      if ok and sh_new < sh_cur then return { type = "pon" } end
    else
      -- 困难：役牌/断幺快攻或接近听牌才碰
      local speed = sh_new <= 1
      if ok and sh_new < sh_cur and (speed or k >= 27) then return { type = "pon" } end
    end
  end
  -- 吃
  if chi_vars and #chi_vars > 0 then
    local best = nil
    for i = 1, #chi_vars do
      local a, b = chi_vars[i].a, chi_vars[i].b
      local c2 = cnt_copy(cnt)
      c2[a] = c2[a] - 1
      c2[b] = c2[b] - 1
      local sh_new = shanten_regular(c2, n_melds + 1)
      if sh_new < sh_cur then
        local ok = call_yaku_ok(seat, k, c2)
        if ok then
          local good = (lv == 2) or sh_new <= 1
          if good then
            if best == nil or sh_new < best.sh then
              best = { type = "chi", a = a, b = b, sh = sh_new }
            end
          end
        end
      end
    end
    return best
  end
  return nil
end

-- ================================================================ 精灵烘焙

-- 瓦片：0..33 = 34 种牌；34..36 = 红五万/筒/条；37 = 牌背
local SPR = {}
do
  for k = 0, 33 do SPR[k] = k end
  SPR.red_man, SPR.red_pin, SPR.red_sou = 34, 35, 36
  SPR.back = 37
end
local RED_SPR_KIND = { [4] = 34, [13] = 35, [22] = 36 }
local function tile_sprite(code)
  local k = kind_of(code)
  if is_red(code) then return RED_SPR_KIND[k] end
  return k
end

local function spr_origin(t) return (t % 16) * 16, flr(t / 16) * 16 end

local function sp(t, x, y, c)  -- 写瓦片像素
  local sx, sy = spr_origin(t)
  sset(sx + x, sy + y, c)
end

-- 牌体：米白面 + 顶部高光 + 底右影
local function bake_body(t)
  for y = 0, 15 do
    for x = 0, 15 do
      sp(t, x, y, C_TILE)
    end
  end
  for i = 0, 14 do
    sp(t, i, 0, 7)
    sp(t, 0, i, 7)
  end
  for i = 1, 15 do
    sp(t, i, 15, C_TILE_SH)
    sp(t, 15, i, C_TILE_SH)
  end
end

-- print→pget 采样：把固件字符 NN 缩放盖进瓦片
local function stamp_char(t, ch, col, dx, dy, w, h)
  -- 区域覆盖采样：目标像素覆盖的源像素块内任一墨迹即着色（保细笔画）
  cls(0)
  print(ch, 0, 0, col)
  local sx, sy = spr_origin(t)
  for y = 0, h - 1 do
    local y0 = flr(y * 16 / h)
    local y1 = min(15, flr(ceil((y + 1) * 16 / h)) - 1)
    for x = 0, w - 1 do
      local x0 = flr(x * 16 / w)
      local x1 = min(15, flr(ceil((x + 1) * 16 / w)) - 1)
      local ink = false
      for py = y0, y1 do
        for px = x0, x1 do
          if pget(px, py) == col then ink = true break end
        end
        if ink then break end
      end
      if ink then sset(sx + dx + x, sy + dy + y, col) end
    end
  end
end

-- 小"万"印记（6×6，位串）
local SEAL_WAN = { "111111", "000000", "001100", "001100", "101100", "011110" }
local function draw_seal(t, dx, dy, col)
  for r = 1, 6 do
    local row = SEAL_WAN[r]
    for c = 1, 6 do
      if row:sub(c, c) == "1" then sp(t, dx + c - 1, dy + r - 1, col) end
    end
  end
end

-- 圆（筒）
local function bake_circle(t, cx, cy, r, ring, fillc, dotc)
  for y = -r - 1, r + 1 do
    for x = -r - 1, r + 1 do
      local d = sqrt(x * x + y * y)
      local px, py = cx + x, cy + y
      if px >= 0 and px <= 15 and py >= 0 and py <= 15 then
        if d <= r - 1.1 then
          sp(t, px, py, fillc)
        elseif d <= r + 0.45 then
          sp(t, px, py, ring)
        end
      end
    end
  end
  if dotc then
    sp(t, cx, cy, dotc)
  end
end

-- 条棍
local function bake_stick(t, x, y, h, main, is_red)
  local hi = 7
  local lo = is_red and 61 or 36
  for i = 0, h - 1 do
    sp(t, x, y + i, main)
    sp(t, x + 1, y + i, main)
    sp(t, x, y + i, hi)
    sp(t, x + 2, y + i, lo)
  end
end

local function bake_tiles()
  -- 万：数字（固件字模采样）+ 红色万印
  for n = 0, 8 do
    local t = n
    bake_body(t)
    stamp_char(t, NUM_CH[n + 1], C_INK, 2, 2, 11, 11)
    -- 印记底衬 + 印
    for y = 9, 15 do
      for x = 9, 15 do sp(t, x, y, C_TILE) end
    end
    draw_seal(t, 10, 10, C_RED)
    -- 红五万
    if n == 4 then
      bake_body(SPR.red_man)
      stamp_char(SPR.red_man, "五", C_RED, 2, 2, 11, 11)
      for y = 9, 15 do
        for x = 9, 15 do sp(SPR.red_man, x, y, C_TILE) end
      end
      draw_seal(SPR.red_man, 10, 10, C_INK)
    end
  end
  -- 筒
  local pin_layouts = {
    { { 8, 8, 6, C_BLUE, C_TILE, C_RED } },                          -- 1
    { { 8, 4, 3, C_BLUE, C_TILE, 7 }, { 8, 12, 3, C_GREEN, C_TILE, 7 } }, -- 2
    { { 5, 4, 2, C_BLUE, C_TILE, 7 }, { 8, 8, 2, C_GREEN, C_TILE, 7 }, { 11, 12, 2, C_RED, C_TILE, 7 } }, -- 3
    { { 4, 4, 2, C_BLUE, C_TILE, 7 }, { 11, 4, 2, C_GREEN, C_TILE, 7 },
      { 4, 11, 2, C_GREEN, C_TILE, 7 }, { 11, 11, 2, C_BLUE, C_TILE, 7 } }, -- 4
    { { 4, 4, 2, C_BLUE, C_TILE, 7 }, { 11, 4, 2, C_BLUE, C_TILE, 7 },
      { 4, 11, 2, C_BLUE, C_TILE, 7 }, { 11, 11, 2, C_BLUE, C_TILE, 7 },
      { 8, 8, 2, C_GREEN, C_TILE, 7 } },                             -- 5
    { { 5, 3, 1, C_BLUE, C_TILE, 7 }, { 10, 3, 1, C_BLUE, C_TILE, 7 },
      { 5, 8, 1, C_BLUE, C_TILE, 7 }, { 10, 8, 1, C_BLUE, C_TILE, 7 },
      { 5, 13, 1, C_BLUE, C_TILE, 7 }, { 10, 13, 1, C_BLUE, C_TILE, 7 } }, -- 6（2×3 小圈）
    { { 4, 4, 1, C_GREEN, C_TILE, 7 }, { 8, 4, 1, C_GREEN, C_TILE, 7 }, { 12, 4, 1, C_GREEN, C_TILE, 7 },
      { 2, 11, 1, C_BLUE, C_TILE, 7 }, { 6, 11, 1, C_BLUE, C_TILE, 7 },
      { 10, 11, 1, C_BLUE, C_TILE, 7 }, { 14, 11, 1, C_BLUE, C_TILE, 7 } }, -- 7（3 上 4 下错位）
    { { 2, 4, 1, C_BLUE, C_TILE, 7 }, { 6, 4, 1, C_BLUE, C_TILE, 7 }, { 10, 4, 1, C_BLUE, C_TILE, 7 }, { 14, 4, 1, C_BLUE, C_TILE, 7 },
      { 2, 11, 1, C_GREEN, C_TILE, 7 }, { 6, 11, 1, C_GREEN, C_TILE, 7 }, { 10, 11, 1, C_GREEN, C_TILE, 7 }, { 14, 11, 1, C_GREEN, C_TILE, 7 } }, -- 8
    { { 3, 3, 1, C_BLUE, C_TILE, 7 }, { 7, 3, 1, C_BLUE, C_TILE, 7 }, { 11, 3, 1, C_BLUE, C_TILE, 7 },
      { 3, 8, 1, C_GREEN, C_TILE, 7 }, { 7, 8, 1, C_GREEN, C_TILE, 7 }, { 11, 8, 1, C_GREEN, C_TILE, 7 },
      { 3, 13, 1, C_RED, C_TILE, 7 }, { 7, 13, 1, C_RED, C_TILE, 7 }, { 11, 13, 1, C_RED, C_TILE, 7 } }, -- 9
  }
  for n = 0, 8 do
    local t = 9 + n
    bake_body(t)
    for _, c in ipairs(pin_layouts[n + 1]) do
      bake_circle(t, c[1], c[2], c[3], c[4], c[5], c[6])
    end
  end
  -- 红五筒：中心大红点
  bake_body(SPR.red_pin)
  for _, c in ipairs(pin_layouts[5]) do
    local ring, dot = c[4], c[6]
    if c[2] == 8 and c[1] == 8 then ring, dot = C_RED, C_RED end
    bake_circle(SPR.red_pin, c[1], c[2], c[3], ring, c[5], dot)
  end
  -- 条
  local function bake_sou(t, n, red_center)
    bake_body(t)
    if n == 1 then
      -- 一条：单根饰棍（红顶）
      bake_stick(t, 6, 2, 12, C_GREEN, false)
      for y = 2, 4 do
        for x = 5, 9 do sp(t, x, y, C_RED) end
      end
    elseif n == 2 then
      bake_stick(t, 4, 2, 12, C_GREEN, false)
      bake_stick(t, 10, 2, 12, C_GREEN, false)
    elseif n == 3 then
      bake_stick(t, 3, 2, 8, C_GREEN, false)
      bake_stick(t, 7, 5, 8, C_GREEN, false)
      bake_stick(t, 11, 8, 8, C_GREEN, false)
    elseif n == 4 then
      bake_stick(t, 3, 2, 6, C_GREEN, false)
      bake_stick(t, 10, 2, 6, C_GREEN, false)
      bake_stick(t, 3, 9, 6, C_GREEN, false)
      bake_stick(t, 10, 9, 6, C_GREEN, false)
    elseif n == 5 then
      bake_stick(t, 3, 2, 6, C_GREEN, false)
      bake_stick(t, 10, 2, 6, C_GREEN, false)
      bake_stick(t, 3, 9, 6, C_GREEN, false)
      bake_stick(t, 10, 9, 6, C_GREEN, false)
      bake_stick(t, 6, 6, 6, C_RED, true)
    elseif n == 6 then
      -- 6 条：2 行 × 3 根长棍（与 7 条 3+4、8 条 2×4、9 条 3×3 区分）
      for i = 0, 2 do
        bake_stick(t, 2 + i * 5, 2, 5, C_GREEN, false)
        bake_stick(t, 2 + i * 5, 9, 5, C_GREEN, false)
      end
    elseif n == 7 then
      for i = 0, 2 do
        bake_stick(t, 3 + i * 4, 2, 3, C_GREEN, false)
      end
      for i = 0, 3 do
        bake_stick(t, 1 + i * 4, 9, 3, C_GREEN, false)
      end
    elseif n == 8 then
      for i = 0, 3 do
        bake_stick(t, 1 + i * 4, 2, 5, C_GREEN, false)
        bake_stick(t, 1 + i * 4, 9, 5, C_GREEN, false)
      end
    else
      for r = 0, 2 do
        for c = 0, 2 do
          local red = red_center and r == 1 and c == 1
          bake_stick(t, 3 + c * 4, 2 + r * 4, 3, red and C_RED or C_GREEN, red)
        end
      end
    end
  end
  for n = 1, 9 do
    bake_sou(18 + n - 1, n, false)
  end
  bake_sou(SPR.red_sou, 5, true)
  -- 字牌
  local honor_ch = { "东", "南", "西", "北", "白", "发", "中" }
  local honor_col = { C_INK, C_INK, C_INK, C_INK, C_INK, C_GREEN, C_RED }
  for i = 1, 7 do
    local t = 26 + i
    bake_body(t)
    stamp_char(t, honor_ch[i], honor_col[i], 1, 1, 14, 14)
  end
  -- 牌背
  local t = SPR.back
  for y = 0, 15 do
    for x = 0, 15 do sp(t, x, y, C_BACK) end
  end
  for i = 0, 15 do
    sp(t, i, 0, C_BACK2) sp(t, i, 15, C_BACK2)
    sp(t, 0, i, C_BACK2) sp(t, 15, i, C_BACK2)
  end
  -- 中央菱形纹
  for y = -3, 3 do
    for x = -3, 3 do
      if abs(x) + abs(y) <= 3 then
        sp(t, 8 + x, 8 + y, (abs(x) + abs(y)) % 2 == 0 and C_GOLD or C_BACK2)
      end
    end
  end
end

-- ================================================================ 渲染

local SEAT_COL = { 30, 41, 34, 59 }  -- P1..P4 主色

local function rel_of(seat) return (seat - G.viewer + 4) % 4 end
local function seat_of_rel(rel) return (G.viewer + rel) % 4 end

local function draw_tile(x, y, code)
  spr(tile_sprite(code), x, y)
end

local function draw_back_tile(x, y)
  spr(SPR.back, x, y)
end

-- 迷你牌背（程序化）
local function draw_back_small(x, y, w, h)
  rectfill(x, y, w, h, C_BACK)
  rect(x, y, w, h, C_BACK2)
  if w >= 8 and h >= 10 then
    rectfill(x + 2, y + 2, w - 4, h - 4, C_BACK2)
    rectfill(x + flr(w / 2) - 1, y + flr(h / 2) - 1, 2, 2, C_GOLD)
  end
end

-- 立直棒图标
local function draw_stick_icon(x, y)
  rectfill(x, y, 3, 10, 7)
  rectfill(x, y + 2, 3, 2, C_RED)
  rectfill(x, y + 6, 3, 2, C_RED)
  rect(x, y, 3, 10, 3)
end

local function draw_room()
  cls(C_BG)
  rectfill(0, 0, 256, 14, C_RIM)
  line(0, 14, 255, 14, C_RIM2)
  rectfill(2, 16, 252, 206, C_FELT)
  fillp(0x1084)
  rectfill(2, 16, 252, 206, C_FELT2 * 256 + C_FELT)
  fillp()
  rect(2, 16, 252, 206, C_RIM)
  rectfill(0, 208, 256, 48, C_RIM)
  line(0, 208, 255, 208, C_RIM2)
end

local function draw_topbar()
  local s = "东" .. NUM_CH[G.hand_no] .. "局"
  print(s, 2, 0, C_GOLD)
  local x = 2 + tw(s)
  if G.honba > 0 then
    local h = NUM_CH[G.honba] .. "本场"
    print(h, x, 0, C_TEXT)
    x = x + tw(h)
  end
  local w = "余" .. wall_left()
  print(w, 118, 0, C_WHITE)
  if G.sticks > 0 then
    draw_stick_icon(158, 2)
    print("×" .. G.sticks, 163, 0, C_WHITE)
  end
  print("宝", 186, 0, C_GOLD)
  for i = 1, #G.dora do
    local code = G.dora[i] * 4 + 1
    draw_tile(200 + (i - 1) * 12, 0, code)
  end
  if G.riichi_count >= 4 then
    print("四家立直", 186, 0, C_RED)
  end
end

-- 牌河
local function draw_river(rel, P)
  local L = RIVER_LY[rel]
  local x0, y0, cols, pitch_x, pitch_y0, rows0, max_h = L[1], L[2], L[3], L[4], L[5], L[6], L[7]
  local n = #P.river
  local rows_need = ceil(n / cols)
  local pitch_y = pitch_y0
  if rows_need > rows0 then
    pitch_y = max(8, flr((max_h - 16) / (rows_need - 1)))
  end
  for i = 1, n do
    local e = P.river[i]
    local r = flr((i - 1) / cols)
    local c = (i - 1) % cols
    local x = x0 + c * pitch_x
    local y = y0 + r * pitch_y
    if e.taken then
      rectfill(x, y, 16, 16, 10)
      rect(x, y, 16, 16, C_FELT2)
      trifill(x + 1, y + 8, x + 5, y + 2, x + 5, y + 14, 3)
    else
      draw_tile(x, y, e.code)
      if e.riichi then
        rectfill(x, y, 2, 16, C_GOLD)
        rectfill(x, y, 2, 2, 7)
      end
      if G.last_discard and G.last_discard.t < 18
        and G.last_discard.seat == P.seat and i == n and not e.taken then
        rect(x - 1, y - 1, 18, 18, (flr(T / 3) % 2 == 0) and 7 or 30)
      end
    end
  end
end

-- 一组鸣牌（含横置标记）
local function draw_meld(x, y, m)
  local tiles = {}
  for i = 1, #m.others do tiles[#tiles + 1] = m.others[i] end
  if m.type ~= "ankan" then tiles[#tiles + 1] = m.src end
  if m.type == "ankan" then tiles[#tiles + 1] = m.src end
  for i = 1, #tiles do
    local tx = x + (i - 1) * 9
    if m.type == "ankan" and i == 3 then
      draw_back_tile(tx, y)
    else
      draw_tile(tx, y, tiles[i])
      if tiles[i] == m.src and m.type ~= "ankan" then
        rectfill(tx, y, 1, 16, C_GOLD)
      end
    end
  end
  if m.type == "kakan" or m.type == "mkan" or m.type == "ankan" then
    rectfill(x + #tiles * 9 - 1, y + 14, 3, 2, C_GOLD)
  end
  return #tiles * 9 + 3
end

local function draw_meld_zone(rel, P)
  if rel == 0 then return end
  local L = MELD_LY[rel]
  local x, y = L[1], L[2]
  for i = 1, #P.melds do
    local w = draw_meld(x, y, P.melds[i])
    x = x + w + 2
    if x > L[1] + 78 then
      x = L[1]
      y = y + 18
      if y > L[2] + 36 then return end
    end
  end
end

-- 侧面角落信息盒
local function draw_corner(rel, P)
  local x = rel == 3 and 0 or 202
  rectfill(x, 88, 54, 62, C_PANEL)
  rect(x, 88, 54, 62, C_PBD)
  local col = SEAT_COL[P.seat + 1]
  print(pname(P.seat), x + 4, 90, col)
  print(WIND_CH[seat_wind_of(P.seat) + 1], x + 4 + 18, 90, C_WHITE)
  if G.dealer == P.seat then
    trifill(x + 44, 92, x + 50, 92, x + 47, 97, C_GOLD)
  end
  print(P.score, x + 6, 106, C_WHITE)
  -- 手牌数背牌
  local n = #P.hand + (G.drawn_seat == P.seat and G.drawn and 1 or 0)
  for i = 1, min(n, 9) do
    draw_back_small(x + 4 + (i - 1) * 5, 124, 4, 12)
  end
  print("×" .. n, x + 50 - 14, 124, C_TEXT)
  if P.riichi then
    draw_stick_icon(x + 8, 140)
    print("立直", x + 14, 140, C_GOLD)
  end
  local d = G.delta_pop and G.delta_pop[P.seat]
  if d then
    local s = (d.amt > 0 and "+" or "") .. d.amt
    print(s, x + 4, 140 - 16 - (d.amt > 0 and flr(d.t / 6) or 0), d.amt > 0 and C_GOLD or C_RED)
  end
end

-- 上家（对面）信息行
local function draw_top_seat(P)
  local col = SEAT_COL[P.seat + 1]
  print(pname(P.seat), 4, 16, col)
  print(WIND_CH[seat_wind_of(P.seat) + 1], 20, 16, C_WHITE)
  if G.dealer == P.seat then
    trifill(40, 18, 46, 18, 43, 23, C_GOLD)
  end
  print(P.score, 48, 16, C_WHITE)
  if P.riichi then
    draw_stick_icon(88, 17)
  end
  local d = G.delta_pop and G.delta_pop[P.seat]
  if d then
    local s = (d.amt > 0 and "+" or "") .. d.amt
    print(s, 96, 16, d.amt > 0 and C_GOLD or C_RED)
  end
  -- 手牌背
  local n = #P.hand + (G.drawn_seat == P.seat and G.drawn and 1 or 0)
  local bx = 256 - 4 - n * 6
  for i = 1, n do
    draw_back_small(bx + (i - 1) * 6, 16, 5, 13)
  end
end

-- 中央信息
local function draw_center()
  local cx = 126
  -- 当前行动家指示
  local P = G.players[G.turn]
  local col = SEAT_COL[G.turn + 1]
  circfill(cx - 4, 96, 7, C_PANEL)
  circ(cx - 4, 96, 7, col)
  print(WIND_CH[seat_wind_of(G.turn) + 1], cx - 12, 88, C_WHITE)
  local bob = flr(sin(T / 14) * 2)
  trifill(cx + 6, 90 + bob, cx + 6, 100 + bob, cx + 13, 95 + bob, col)
  -- 消息
  local y = 110
  for i = #G.log, max(1, #G.log - 1), -1 do
    if G.log[i] then
      print(G.log[i][1], 104, y, G.log[i][2])
      y = y + 15
    end
  end
  -- 剩余巡目标记
  if wall_left() <= 12 then
    print("终局", 112, 140, C_RED)
  end
end

-- 底部信息条 + 手牌
local can_riichi_now  -- 输入部分实现
local function draw_bottom_seat(P)
  local col = SEAT_COL[P.seat + 1]
  rectfill(0, 210, 256, 17, C_PANEL)
  line(0, 210, 255, 210, C_PBD)
  print(pname(P.seat), 4, 212, col)
  print(WIND_CH[seat_wind_of(P.seat) + 1], 22, 212, C_WHITE)
  if G.dealer == P.seat then
    trifill(42, 214, 48, 214, 45, 219, C_GOLD)
    print("亲", 52, 212, C_GOLD)
  end
  print(P.score .. "点", 70, 212, C_WHITE)
  if P.riichi then
    draw_stick_icon(120, 214)
  end
  local d = G.delta_pop and G.delta_pop[P.seat]
  if d then
    local s = (d.amt > 0 and "+" or "") .. d.amt
    print(s, 132, 212, d.amt > 0 and C_GOLD or C_RED)
  end
  local hint = "Ⓐ打 Ⓧ杠"
  if can_riichi_now and can_riichi_now(P.seat) then hint = hint .. " Ⓨ立直" end
  print(hint, 256 - tw(hint) - 4, 212, C_DIM)
  -- 手牌
  local show = (not G.privacy) or (PROMPT and PROMPT.seat == P.seat and PROMPT.reveal)
  local n = #P.hand
  local has_drawn = G.drawn ~= nil and G.drawn_seat == P.seat
  local total = n * 16 + (has_drawn and 22 or 0)
  local x0 = flr((256 - total) / 2)
  local cur = PROMPT and PROMPT.type == "discard" and PROMPT.seat == P.seat and PROMPT.cursor or -1
  for i = 1, n do
    local x = x0 + (i - 1) * 16
    local sel = (i == cur)
    if sel then
      rectfill(x - 1, 227, 18, 18, C_GOLD)
    end
    if show then
      draw_tile(x, 228 - (sel and 2 or 0), P.hand[i])
    else
      draw_back_tile(x, 228)
    end
  end
  if has_drawn then
    local x = x0 + n * 16 + 6
    local sel = (cur == n + 1)
    if sel then
      rectfill(x - 1, 227, 18, 18, C_GOLD)
    end
    if show then
      draw_tile(x, 228 - (sel and 2 or 0), G.drawn)
      -- 摸牌高亮角
      rectfill(x + 12, 226, 4, 2, 30)
    else
      draw_back_tile(x, 228)
    end
  end
  -- 鸣牌接在手牌右侧
  if show or true then
    local mx = x0 + total + 8
    for i = 1, #P.melds do
      local w = draw_meld(mx, 228, P.melds[i])
      mx = mx + w + 3
      if mx > 244 then break end
    end
  end
end

local function draw_banner()
  local b = G.banner
  if b == nil or b.t <= 0 then return end
  local w = tw(b.text) + 12
  local x = (256 - w) / 2
  rectfill(x, 96, w, 20, 0)
  rectfill(x + 1, 97, w - 2, 18, C_PANEL)
  rect(x + 1, 97, w - 2, 18, b.col)
  print(b.text, x + 6, 99, b.col)
end

local function draw_pass_overlay()
  cls(0)
  local s = "请交给 " .. pname(PROMPT.seat) .. " 操作"
  rectfill(28, 104, 200, 46, C_PANEL)
  rect(28, 104, 200, 46, C_GOLD)
  print(s, (256 - tw(s)) / 2, 112, C_WHITE)
  local s2 = "轮到 " .. pname(PROMPT.seat)
  print(s2, (256 - tw(s2)) / 2, 130, SEAT_COL[PROMPT.seat + 1])
  if flr(T / 20) % 2 == 0 then
    local h = "Ⓐ 继续"
    print(h, (256 - tw(h)) / 2, 148, C_GOLD)
  end
end

-- ================================================================ 面板：和牌 / 流局 / 终局

local function limit_label(basic, yakuman)
  if yakuman and yakuman > 1 then return "役满" .. NUM_CH[min(yakuman, 9)] end
  if basic >= 8000 then return "役满" end
  if basic >= 6000 then return "三倍满" end
  if basic >= 4000 then return "倍满" end
  if basic >= 3000 then return "跳满" end
  if basic >= 2000 then return "满贯" end
  return nil
end

local function draw_panel_win()
  local p = G.panel
  rectfill(0, 0, 256, 256, 0)
  rectfill(14, 20, 228, 216, C_PANEL)
  rect(14, 20, 228, 216, C_GOLD)
  local e = p.entries[1]
  local title = pname(e.seat) .. (p.mode == "tsumo" and " 自摸" or " 荣和")
  print(title, 22, 24, C_GOLD)
  print((e.is_dealer and "亲家" or "子家"), 22 + tw(title) + 6, 24, C_TEXT)
  local y = 42
  for wi = 1, #p.entries do
    local en = p.entries[wi]
    if #p.entries > 1 then
      print(pname(en.seat), 22, y - 12, SEAT_COL[en.seat + 1])
    end
    -- 和牌手牌
    local hx = 22
    for i = 1, #en.hand do
      draw_tile(hx + (i - 1) * 14, y, en.hand[i])
    end
    local mx = hx + #en.hand * 14 + 4
    for i = 1, #en.melds do
      local w = draw_meld(mx, y, en.melds[i])
      mx = mx + w + 2
    end
    y = y + 20
    -- 役种
    local names = {}
    for i = 1, #en.sc.names do
      local nm = en.sc.names[i]
      local hs = nm[2] == "役满" and "役满" or (nm[2] .. "翻")
      names[#names + 1] = nm[1] .. " " .. hs
    end
    local ys = table.concat(names, "・")
    printw(ys, 22, y, C_WHITE, 212)
    y = y + 30 + (#names > 4 and 14 or 0)
    -- 符翻与点数
    local fu_str
    if en.sc.yakuman > 0 then
      fu_str = "役满"
    else
      fu_str = en.sc.fu .. "符 " .. en.sc.han .. "翻"
    end
    local lb = limit_label(en.sc.basic, en.sc.yakuman)
    if lb then fu_str = fu_str .. "・" .. lb end
    print(fu_str, 22, y, C_TEXT)
    local pts = en.total .. "点"
    print(pts, 242 - tw(pts), y, C_GOLD)
    y = y + 20
  end
  -- 点数变动
  for s = 0, 3 do
    local dd = G.deltas and G.deltas[s] or 0
    local str = pname(s) .. " " .. G.players[s].score .. (dd ~= 0 and ((dd > 0 and " +" or " ") .. dd) or "")
    print(str, 22 + (s % 2) * 108, y + flr(s / 2) * 14,
      dd > 0 and C_GOLD or (dd < 0 and C_RED or C_DIM))
  end
  if p.mode == "ron" then
    print("放铳 " .. pname(p.payer), 138, 24, C_RED)
  end
  if flr(T / 20) % 2 == 0 then
    local h = "Ⓐ 继续"
    print(h, (256 - tw(h)) / 2, 218, C_GOLD)
  end
end

local function draw_panel_ryuukyoku()
  local p = G.panel
  rectfill(0, 0, 256, 256, 0)
  rectfill(14, 20, 228, 216, C_PANEL)
  rect(14, 20, 228, 216, C_TEXT)
  print("荒牌流局", (256 - 64) / 2, 24, C_WHITE)
  local y = 44
  for s = 0, 3 do
    local P = G.players[s]
    local t = p.tenpai[s]
    print(pname(s), 20, y, SEAT_COL[s + 1])
    print(t and "听牌" or "未听", 44, y, t and C_GOLD or C_DIM)
    local h = p.hands[s].hand
    local x = 78
    if t then
      for i = 1, #h do
        draw_tile(x + (i - 1) * 10, y - 1, h[i])
      end
      x = x + #h * 10
    else
      for i = 1, #h do
        draw_back_small(x + (i - 1) * 6, y + 1, 5, 13)
      end
      x = x + #h * 6
    end
    for i = 1, #P.melds do
      local w = draw_meld(x + 2, y - 1, P.melds[i])
      x = x + w + 2
    end
    local dd = G.deltas and G.deltas[s] or 0
    if dd ~= 0 then
      print((dd > 0 and "+" or "") .. dd, 236, y, dd > 0 and C_GOLD or C_RED)
    end
    y = y + 20
  end
  if flr(T / 20) % 2 == 0 then
    local h = "Ⓐ 继续"
    print(h, (256 - tw(h)) / 2, 218, C_GOLD)
  end
end

local function draw_results()
  rectfill(0, 0, 256, 256, 0)
  rectfill(20, 16, 216, 224, C_PANEL)
  rect(20, 16, 216, 224, C_GOLD)
  print("终局结算", (256 - 64) / 2, 22, C_GOLD)
  local rk = G.results.rank
  local y = 48
  local POS = { "一位", "二位", "三位", "四位" }
  for i = 1, 4 do
    local s = rk[i]
    local P = G.players[s]
    print(POS[i], 30, y, i == 1 and C_GOLD or C_TEXT)
    print(pname(s), 70, y, SEAT_COL[s + 1])
    if not P.is_ai then print("玩家", 96, y, C_WHITE) end
    print(P.score, 150, y, C_WHITE)
    local dd = P.score - 25000
    print((dd > 0 and "+" or "") .. dd, 196, y, dd > 0 and C_GOLD or C_RED)
    y = y + 18
  end
  local st = "本局战绩 和了" .. G.stats.wins .. " 立直" .. G.stats.riichi
    .. " 最佳" .. G.stats.best
  print(st, (256 - tw(st)) / 2, y + 6, C_TEXT)
  local st2 = "累计 局数" .. SAVE.games .. " 和了" .. SAVE.wins
    .. " 立直" .. SAVE.riichi .. " 最佳" .. SAVE.best
  print(st2, (256 - tw(st2)) / 2, y + 22, C_DIM)
  if flr(T / 20) % 2 == 0 then
    local h = "Ⓐ 返回标题"
    print(h, (256 - tw(h)) / 2, 214, C_GOLD)
  end
end

-- ================================================================ 提示 UI

local function draw_prompt_ui()
  if PROMPT == nil then return end
  local p = PROMPT
  if p.type == "call" then
    local opts = p.opts
    local wsum = 0
    for i = 1, #opts do wsum = wsum + tw(opts[i].label) + 12 end
    local x = flr((256 - wsum - (#opts - 1) * 2) / 2)
    local y = 186
    for i = 1, #opts do
      local w = tw(opts[i].label) + 12
      local sel = (i == p.sel)
      rectfill(x, y, w, 20, sel and 15 or C_PANEL)
      rect(x, y, w, 20, sel and C_GOLD or C_PBD)
      print(opts[i].label, x + 6, y + 2, sel and 30 or C_TEXT)
      x = x + w + 2
    end
    local h = "⬅➡选择 Ⓐ确认 Ⓑ过"
    print(h, (256 - tw(h)) / 2, 208 - 16, C_DIM)
  elseif p.type == "ron" then
    local s = pname(p.seat) .. " 可以荣和！"
    rectfill(28, 186, tw(s) + 130, 20, 0)
    rect(30, 187, tw(s) + 126, 18, C_RED)
    print(s, 34, 189, C_WHITE)
    print("Ⓐ 和", 34 + tw(s) + 10, 189, C_GOLD)
    print("Ⓑ 过", 34 + tw(s) + 60, 189, C_TEXT)
  elseif p.type == "tsumo" then
    local s = pname(p.seat) .. " 自摸和牌！"
    rectfill(28, 186, tw(s) + 130, 20, 0)
    rect(30, 187, tw(s) + 126, 18, C_GOLD)
    print(s, 34, 189, C_WHITE)
    print("Ⓐ 和", 34 + tw(s) + 10, 189, C_GOLD)
    print("Ⓑ 过", 34 + tw(s) + 60, 189, C_TEXT)
  elseif p.type == "discard" then
    if p.ri then
      local s = "立直宣言：选择打出的牌（Ⓑ取消）"
      print(s, (256 - tw(s)) / 2, 208, C_GOLD)
    end
    if p.kmenu then
      local opts = p.kmenu
      local w = 108
      local h = #opts * 16 + 10
      local x, y = 132, 190 - h
      rectfill(x, y, w, h, 0)
      rectfill(x + 1, y + 1, w - 2, h - 2, C_PANEL)
      rect(x + 1, y + 1, w - 2, h - 2, C_GOLD)
      for i = 1, #opts do
        if i == p.ksel then
          rectfill(x + 3, y + 3 + (i - 1) * 16, w - 6, 14, 15)
        end
        print(opts[i].label, x + 8, y + 4 + (i - 1) * 16, C_WHITE)
      end
    end
  end
end

-- ================================================================ 标题 / 暂停

local TITLE = { row = 1, hidx = 1, level = 2, bgm = true }
local HUMAN_LABEL = { "1人", "2人", "3人", "4人", "观战" }
local HUMAN_CNT = { 1, 2, 3, 4, 0 }
local LEVEL_LABEL = { "简单", "普通", "困难" }

local function draw_title()
  cls(C_BG)
  rectfill(0, 0, 256, 256, C_PANEL)
  fillp(0x8142)
  rectfill(0, 0, 256, 256, 13 * 256 + 12)
  fillp()
  rectfill(12, 8, 232, 240, C_FELT)
  fillp(0x1084)
  rectfill(14, 10, 228, 236, C_FELT2 * 256 + C_FELT)
  fillp()
  rect(12, 8, 232, 240, C_RIM)
  -- 装饰牌（2 倍放大）
  local deco = { 33 * 4 + 1, 34, 26 * 4 + 1, 32 * 4 + 1, 31 * 4 + 1 }
  local dx = 128 - 5 * 17
  for i = 1, 5 do
    local t = tile_sprite(deco[i])
    local sx, sy = spr_origin(t)
    sspr(sx, sy, 16, 16, dx + (i - 1) * 34, 22 + (i == 3 and -8 or 0), 32, 32)
  end
  local s = "日本麻将"
  local x = (256 - tw(s)) / 2
  print(s, x + 1, 73, 0)
  print(s, x - 1, 71, C_GOLD)
  line(64, 92, 192, 92, C_GOLD)
  local s2 = "立直麻将・东风战"
  print(s2, (256 - tw(s2)) / 2, 98, C_TEXT)
  -- 选项
  local rows = {
    { "玩家", HUMAN_LABEL[TITLE.hidx] },
    { "难度", LEVEL_LABEL[TITLE.level] },
    { "音乐", TITLE.bgm and "开" or "关" },
  }
  local y = 126
  for i = 1, 3 do
    local sel = (TITLE.row == i)
    if sel then
      rectfill(56, y - 2, 144, 20, 15)
      rect(56, y - 2, 144, 20, C_GOLD)
    end
    print(rows[i][1], 66, y, sel and 30 or C_TEXT)
    local v = "〈" .. rows[i][2] .. "〉"
    print(v, 186 - tw(v) + 8, y, sel and C_WHITE or C_TEXT)
    y = y + 23
  end
  local st = "战绩 局数" .. SAVE.games .. "・和了" .. SAVE.wins
    .. "・立直" .. SAVE.riichi .. "・最佳" .. SAVE.best
  print(st, (256 - tw(st)) / 2, 198, C_DIM)
  if flr(T / 20) % 2 == 0 then
    local h = "⬅➡调整 Ⓐ 开始对局"
    print(h, (256 - tw(h)) / 2, 222, C_GOLD)
  end
end

local PAUSE = nil
local YAKU_PAGES = {
  { "一翻", "立直・一发・两立直・门前清自摸和", "平和・断幺九・一杯口・岭上开花",
    "海底捞月・河底捞鱼・役牌(风/三元)" },
  { "二翻", "两立直外:三暗刻・三色同刻・混老头", "对对和・七对子(25符)・混全带幺九",
    "三色同顺・一气通贯(门前)・小三元" },
  { "三翻以上", "二杯口3・纯全带幺九3(门前)", "混一色3(鸣2)・清一色6(鸣5)",
    "满贯8000・跳满12000・倍满16000" },
  { "役满 32000", "国士无双・四暗刻・大三元・字一色", "绿一色・清老头・九莲宝灯・四杠子",
    "天和・地和(结算画面详细列出)" },
}

local function draw_pause()
  if PAUSE.table_page then
    rectfill(0, 0, 256, 256, 0)
    local pg = YAKU_PAGES[PAUSE.table_page]
    rectfill(16, 20, 224, 216, C_PANEL)
    rect(16, 20, 224, 216, C_TEXT)
    print("役种表 " .. PAUSE.table_page .. "/" .. #YAKU_PAGES, 24, 26, C_GOLD)
    local y = 48
    print(pg[1], 24, y, C_WHITE)
    y = y + 22
    for i = 2, #pg do
      print(pg[i], 24, y, C_TEXT)
      y = y + 20
    end
    local h = "⬅➡翻页 Ⓑ 返回"
    print(h, (256 - tw(h)) / 2, 214, C_GOLD)
    return
  end
  rectfill(64, 92, 128, 76, 0)
  rectfill(66, 94, 124, 72, C_PANEL)
  rect(66, 94, 124, 72, C_GOLD)
  print("暂停", (256 - 32) / 2, 100, C_WHITE)
  local items = { "继续对局", "役种表", "退出对局" }
  for i = 1, 3 do
    if i == PAUSE.sel then
      rectfill(76, 118 + (i - 1) * 15, 104, 13, 15)
    end
    print(items[i], 82, 119 + (i - 1) * 15, i == PAUSE.sel and 30 or C_TEXT)
  end
end

-- ================================================================ 输入

local rep_d, rep_t = 0, 0
local MODE = "title"

local function cursor_move(p, n)
  local dir = 0
  if btn(0) then dir = -1 elseif btn(1) then dir = 1 end
  if dir ~= 0 then
    if dir ~= rep_d then
      rep_d = dir rep_t = 0
      p.cursor = mid(1, p.cursor + dir, n)
      sfx(8)
    else
      rep_t = rep_t + 1
      if rep_t > 12 and rep_t % 4 == 0 then
        p.cursor = mid(1, p.cursor + dir, n)
        sfx(8)
      end
    end
  else
    rep_d = 0
  end
end

local function discard_input()
  local p = PROMPT
  local seat = p.seat
  local P = G.players[seat]
  local has_drawn = G.drawn ~= nil and G.drawn_seat == seat
  local n = #P.hand + (has_drawn and 1 or 0)
  if p.kmenu then
    if btnp(0) or btnp(3) then p.ksel = mid(1, p.ksel - 1, #p.kmenu) sfx(8) end
    if btnp(1) or btnp(2) then p.ksel = mid(1, p.ksel + 1, #p.kmenu) sfx(8) end
    if btnp(5) then p.kmenu = nil sfx(8) return end
    if btnp(4) then
      local o = p.kmenu[p.ksel]
      PROMPT_RESULT = { type = o.ktype, k = o.k }
      sfx(9)
    end
    return
  end
  cursor_move(p, n)
  if btnp(6) then  -- Ⓧ 杠菜单
    if p.kans and #p.kans > 0 then
      p.kmenu = p.kans
      p.ksel = 1
      sfx(8)
    else
      sfx(10)
    end
  end
  if btnp(7) then  -- Ⓨ 立直
    if p.ri then
      p.ri = false
      sfx(8)
    elseif p.riichi_any then
      p.ri = true
      sfx(9)
    else
      sfx(10)
      banner("现在不能立直", C_RED, 40)
    end
  end
  if btnp(5) then  -- Ⓑ 取消
    if p.ri then p.ri = false sfx(8) end
  end
  if btnp(4) then  -- Ⓐ 打出
    local idx = p.cursor
    if p.ri and not p.ri_ok[idx] then
      sfx(10)
      banner("此牌打出后未听牌", C_RED, 40)
      return
    end
    local code = idx <= #P.hand and P.hand[idx] or G.drawn
    PROMPT_RESULT = { type = p.ri and "riichi" or "discard", code = code }
    sfx(9)
  end
end

local function call_input()
  local p = PROMPT
  local n = #p.opts
  if btnp(0) then p.sel = (p.sel - 2 + n) % n + 1 sfx(8) end
  if btnp(1) then p.sel = p.sel % n + 1 sfx(8) end
  if btnp(5) then PROMPT_RESULT = nil sfx(8) return end
  if btnp(4) then
    local o = p.opts[p.sel]
    if o.type == "pass" then
      PROMPT_RESULT = nil
    else
      PROMPT_RESULT = o
    end
    sfx(9)
  end
end

local function title_input()
  if btnp(3) then TITLE.row = TITLE.row % 3 + 1 sfx(8) end
  if btnp(2) then TITLE.row = (TITLE.row - 2) % 3 + 1 sfx(8) end
  local dir = 0
  if btnp(0) then dir = -1 elseif btnp(1) then dir = 1 end
  if dir ~= 0 then
    if TITLE.row == 1 then
      if dir < 0 then
        TITLE.hidx = (TITLE.hidx + 3) % 5 + 1
      else
        TITLE.hidx = TITLE.hidx % 5 + 1
      end
    elseif TITLE.row == 2 then
      TITLE.level = mid(1, TITLE.level + dir, 3)
    else
      TITLE.bgm = not TITLE.bgm
    end
    sfx(8)
  end
  if btnp(4) or btnp(11) then
    PROMPT_RESULT = true
    sfx(9)
  end
end

local function handle_prompt_input()
  local p = PROMPT
  if p.type == "title" then
    title_input()
  elseif p.type == "discard" then
    discard_input()
  elseif p.type == "call" then
    call_input()
  elseif p.type == "ron" or p.type == "tsumo" then
    if btnp(4) then PROMPT_RESULT = true sfx(9)
    elseif btnp(5) then PROMPT_RESULT = false sfx(8) end
  elseif p.type == "settle" or p.type == "results" or p.type == "pass" then
    if btnp(4) or btnp(11) then PROMPT_RESULT = true sfx(9) end
  end
end

local main_co  -- 前向声明

local function pause_input()
  if PAUSE.table_page then
    if btnp(0) then PAUSE.table_page = mid(1, PAUSE.table_page - 1, #YAKU_PAGES) sfx(8) end
    if btnp(1) then PAUSE.table_page = PAUSE.table_page % #YAKU_PAGES + 1 sfx(8) end
    if btnp(5) or btnp(4) then PAUSE = { sel = 2 } sfx(8) end
    return
  end
  if btnp(2) or btnp(3) then PAUSE.sel = PAUSE.sel % 3 + 1 sfx(8) end
  if btnp(11) or btnp(5) then PAUSE = nil sfx(8) return end
  if btnp(4) then
    if PAUSE.sel == 1 then
      PAUSE = nil
      sfx(9)
    elseif PAUSE.sel == 2 then
      PAUSE = { table_page = 1 }
      sfx(9)
    else
      PAUSE = nil
      CO = nil
      PROMPT = nil
      PROMPT_RESULT = nil
      MODE = "title"
      music(-1, 300)
      sfx(9)
    end
  end
end

-- ================================================================ 主协程与生命周期

local draw_selftest  -- 自测部分实现
local WAIT_N = 0

local function drive()
  if WAIT_N > 0 then
    WAIT_N = WAIT_N - 1
    return
  end
  if CO == nil then
    if MODE == "title" then
      CO = coroutine.create(main_co)
    else
      return
    end
  end
  local ok, req = coroutine.resume(CO)
  if not ok then
    CO = nil
    error(req, 0)
  end
  if coroutine.status(CO) == "dead" then
    CO = nil
    return
  end
  if type(req) == "number" then WAIT_N = req end
end

main_co = function()
  while true do
    ask("title")
    local hs = {}
    local cnt = HUMAN_CNT[TITLE.hidx]
    for i = 0, cnt - 1 do hs[#hs + 1] = i end
    new_game(hs, TITLE.level)
    MODE = "game"
    if TITLE.bgm then set_bgm(true) end
    game_flow()
    MODE = "title"
    music(-1, 300)
    wait(20)
  end
end

can_riichi_now = function(seat)
  if PROMPT == nil or PROMPT.type ~= "discard" or PROMPT.seat ~= seat then
    return false
  end
  return PROMPT.riichi_any and true or false
end

function _update()
  T = T + 1
  if G and G.banner then
    G.banner.t = G.banner.t - 1
    if G.banner.t <= 0 then G.banner = nil end
  end
  if G and G.last_discard then G.last_discard.t = G.last_discard.t + 1 end
  if G and G.delta_pop then
    for s = 0, 3 do
      local d = G.delta_pop[s]
      if d then
        d.t = d.t - 1
        if d.t <= 0 then G.delta_pop[s] = nil end
      end
    end
  end
  if MODE == "test" then
    if btnp(4) then MODE = "title" sfx(9) end
    return
  end
  if PAUSE then
    pause_input()
    return
  end
  if MODE == "game" and btnp(10) then
    BGM_ON = not BGM_ON
    set_bgm(BGM_ON)
    sfx(8)
  end
  if PROMPT and PROMPT_RESULT == nil then
    handle_prompt_input()
    if PROMPT_RESULT == nil then return end
  end
  if MODE == "game" and PROMPT == nil and btnp(11) then
    PAUSE = { sel = 1 }
    sfx(14)
    return
  end
  drive()
end

function _draw()
  if MODE == "test" then
    draw_selftest()
    return
  end
  if MODE == "title" then
    draw_title()
    return
  end
  if PROMPT and PROMPT.type == "pass" then
    draw_pass_overlay()
    return
  end
  draw_room()
  draw_topbar()
  for rel = 0, 3 do
    local P = G.players[seat_of_rel(rel)]
    if rel == 2 then draw_top_seat(P) end
    if rel == 1 or rel == 3 then draw_corner(rel, P) end
    if rel == 0 then draw_bottom_seat(P) end
    draw_river(rel, P)
    draw_meld_zone(rel, P)
  end
  draw_center()
  draw_banner()
  draw_prompt_ui()
  if G.results then
    draw_results()
  elseif G.panel then
    if G.panel.type == "win" then draw_panel_win()
    elseif G.panel.type == "ryuukyoku" then draw_panel_ryuukyoku() end
  end
  if PAUSE then draw_pause() end
end

-- ================================================================ 自测（自由区首字节 42 触发）

local TESTS = nil

local function mk(str)
  -- 记法：123m 456p 789s（后缀花色）；z1..z7 = 东南西北白发中（前缀）；0=红5
  local out = {}
  local buf = {}
  local cur = 0
  local function flush(suit)
    for i = 1, #buf do
      local d = buf[i]
      if suit == 3 then
        out[#out + 1] = (26 + d) * 4 + 1
      elseif d == 0 then
        out[#out + 1] = (suit * 9 + 4) * 4  -- 红 5
      else
        out[#out + 1] = (suit * 9 + d - 1) * 4 + 1
      end
    end
    buf = {}
  end
  for i = 1, #str do
    local ch = str:sub(i, i)
    local d = tonumber(ch)
    if d then
      buf[#buf + 1] = d
    elseif ch == "m" then flush(0) cur = 0
    elseif ch == "p" then flush(1) cur = 1
    elseif ch == "s" then flush(2) cur = 2
    elseif ch == "z" then flush(3) cur = 3 end
  end
  flush(cur)
  return out
end

local function meld_pon(str)
  local t = mk(str)
  return { type = "pon", k = kind_of(t[1]), src = t[1], others = { t[2], t[3] }, from = 0 }
end

local function meld_chi(str)
  local t = mk(str)
  return { type = "chi", k = min(t[1], t[2], t[3]) >> 2, src = t[1],
    others = { t[2], t[3] }, from = 0 }
end

local function meld_ankan(str)
  local t = mk(str)
  return { type = "ankan", k = kind_of(t[1]), src = t[1],
    others = { t[2], t[3], t[4] }, from = 1 }
end

local function has_yaku(sc, name)
  for i = 1, #sc.names do
    if string.find(sc.names[i][1], name, 1, true) then return true end
  end
  return false
end

local function base_SC()
  return {
    seat_wind = 1, round_wind = 0,
    riichi = false, daburu = false, ippatsu = false,
    tsumo = false, rinshan = false, haitei = false, houtei = false,
    tenhou = false, chiihou = false,
    dora = {}, ura = {},
  }
end

local function run_self_tests()
  local pass, fail = 0, 0
  local fails = {}
  local function check(name, got, exp)
    local ok = got == exp
    if ok then
      pass = pass + 1
    else
      fail = fail + 1
      fails[#fails + 1] = name .. " got=" .. tostring(got) .. " exp=" .. tostring(exp)
    end
    printh((ok and "[PASS] " or "[FAIL] ") .. name
      .. " got=" .. tostring(got) .. " exp=" .. tostring(exp))
  end
  -- T1 平和+立直（20符）
  do
    local SC = base_SC()
    SC.riichi = true
    local sc = score_hand(mk("234m345m678m34p99p"), {}, mk("5p")[1], "ron", SC)
    check("T1平和成立", sc ~= nil and has_yaku(sc, "平和"), true)
    check("T1立直成立", sc ~= nil and has_yaku(sc, "立直"), true)
    check("T1翻数", sc and sc.han, 2)
    check("T1符", sc and sc.fu, 20)
    check("T1子家荣和点数", sc and c100(sc.basic * 4), 1300)
  end
  -- T2 断幺九（鸣牌、30符）
  do
    local sc = score_hand(mk("234m567m678s5s"), { meld_chi("456p") }, mk("5s")[1], "ron", base_SC())
    check("T2断幺九成立", sc ~= nil and has_yaku(sc, "断幺九"), true)
    check("T2翻数", sc and sc.han, 1)
    check("T2符", sc and sc.fu, 30)
  end
  -- T3 役牌白（40符）
  do
    local SC = base_SC()
    SC.dora = { 7 }
    local sc = score_hand(mk("234m345m678m55p55z"), {}, mk("5z")[1], "ron", SC)
    check("T3役牌白", sc ~= nil and has_yaku(sc, "役牌 白"), true)
    check("T3宝牌1", sc ~= nil and has_yaku(sc, "宝牌"), true)
    check("T3符", sc and sc.fu, 40)
    check("T3翻数", sc and sc.han, 2)
  end
  -- T4 七对子（25符2翻=1600）
  do
    local sc = score_hand(mk("1199m1122p3355s7s"), {}, mk("7s")[1], "ron", base_SC())
    check("T4七对子", sc ~= nil and has_yaku(sc, "七对子"), true)
    check("T4符", sc and sc.fu, 25)
    check("T4点数", sc and c100(sc.basic * 4), 1600)
  end
  -- T5 混一色+场风东
  do
    local SC = base_SC()
    SC.round_wind = 0
    SC.seat_wind = 2
    local sc = score_hand(mk("123m234m567m5m"), { meld_pon("111z") }, mk("5m")[1], "ron", SC)
    check("T5混一色", sc ~= nil and has_yaku(sc, "混一色"), true)
    check("T5场风东", sc ~= nil and has_yaku(sc, "场风东"), true)
    check("T5混一色翻数(鸣)", sc and sc.han, 3)
  end
  -- T6 对对和+三暗刻（满贯）
  do
    local sc = score_hand(mk("111m333m555m9m"), { meld_pon("222p") }, mk("9m")[1], "ron", base_SC())
    check("T6对对和", sc ~= nil and has_yaku(sc, "对对和"), true)
    check("T6三暗刻", sc ~= nil and has_yaku(sc, "三暗刻"), true)
    check("T6翻数", sc and sc.han, 4)
    check("T6符(单骑+2)", sc and sc.fu, 40)
    check("T6满贯点数", sc and sc.basic, 2000)
  end
  -- T7 国士无双
  do
    local sc = score_hand(mk("19m19p19s1234567z"), {}, mk("1m")[1], "ron", base_SC())
    check("T7国士无双役满", sc and sc.yakuman, 1)
    check("T7基本点", sc and sc.basic, 8000)
    check("T7荣和点数", sc and c100(sc.basic * 4), 32000)
  end
  -- T8 四暗刻（自摸）
  do
    local SC = base_SC()
    SC.riichi = true
    local sc = score_hand(mk("111m333m555m777m9p"), {}, mk("9p")[1], "tsumo", SC)
    check("T8四暗刻役满", sc and sc.yakuman, 1)
    check("T8立直并入役满不计", sc ~= nil and not has_yaku(sc, "立直"), true)
  end
  -- T9 门前荣和 40 符 vs 自摸 30 符
  do
    local SCr = base_SC()
    SCr.riichi = true
    local sc = score_hand(mk("234m456m789m111m5p"), {}, mk("5p")[1], "ron", SCr)
    check("T9荣和40符", sc and sc.fu, 40)
    local SCt = base_SC()
    SCt.riichi = true
    local sc2 = score_hand(mk("234m456m789m111m5p"), {}, mk("5p")[1], "tsumo", SCt)
    check("T9自摸30符", sc2 and sc2.fu, 30)
    check("T9自摸门前自摸和", sc2 ~= nil and has_yaku(sc2, "门前清自摸和"), true)
  end
  -- T10 点数表抽查
  do
    check("T10子3翻30符荣和", c100(basic_pts(30, 3) * 4), 3900)
    check("T10子4翻30符荣和", c100(basic_pts(30, 4) * 4), 7700)
    check("T10亲2翻40符荣和", c100(basic_pts(40, 2) * 6), 3900)
    check("T10子3翻30符自摸亲支付", c100(basic_pts(30, 3) * 2), 2000)
    check("T10子3翻30符自摸子支付", c100(basic_pts(30, 3)), 1000)
    check("T10满贯子荣和", c100(basic_pts(30, 5) * 4), 8000)
    check("T10满贯亲自摸", c100(basic_pts(30, 5) * 2), 4000)
    check("T10役满亲荣和", c100(basic_pts(25, 13) * 6), 48000)
    check("T10跳满子荣和", c100(basic_pts(30, 7) * 4), 12000)
    check("T10倍满子荣和", c100(basic_pts(30, 9) * 4), 16000)
  end
  -- T11 三色同顺
  do
    local sc = score_hand(mk("123m123p123s678m5s"), {}, mk("5s")[1], "ron", base_SC())
    check("T11三色同顺", sc ~= nil and has_yaku(sc, "三色同顺"), true)
    check("T11翻数", sc and sc.han, 2)
  end
  -- T12 一气通贯（边张）
  do
    local sc = score_hand(mk("123m456m789m123p5p"), {}, mk("5p")[1], "ron", base_SC())
    check("T12一气通贯", sc ~= nil and has_yaku(sc, "一气通贯"), true)
    check("T12边张40符", sc and sc.fu, 40)
  end
  -- T13 三暗刻+自摸
  do
    local sc = score_hand(mk("111p222p333p45p11m"), {}, mk("6p")[1], "tsumo", base_SC())
    check("T13三暗刻", sc ~= nil and has_yaku(sc, "三暗刻"), true)
    check("T13自摸翻数", sc and sc.han, 3)
    check("T13符", sc and sc.fu, 30)
  end
  -- T14 混全带幺九
  do
    local sc = score_hand(mk("123m789m999s5577z"), {}, mk("5z")[1], "tsumo", base_SC())
    check("T14混全带幺九", sc ~= nil and has_yaku(sc, "混全带幺九"), true)
  end
  -- T15 大三元
  do
    local sc = score_hand(mk("555666777z123m5p"), {}, mk("5p")[1], "tsumo", base_SC())
    check("T15大三元役满", sc and sc.yakuman, 1)
  end
  -- T16 绿一色
  do
    local sc = score_hand(mk("234s234s66s88s666z"), {}, mk("8s")[1], "tsumo", base_SC())
    check("T16绿一色役满", sc and sc.yakuman, 1)
  end
  -- T17 字一色（兼四暗刻双役满）
  do
    local sc = score_hand(mk("1112223334455z"), {}, mk("4z")[1], "tsumo", base_SC())
    check("T17字一色+四暗刻双役满", sc and sc.yakuman, 2)
  end
  -- T18 九莲宝灯
  do
    local sc = score_hand(mk("1112345678999m"), {}, mk("5m")[1], "tsumo", base_SC())
    check("T18九莲宝灯役满", sc and sc.yakuman, 1)
  end
  -- T19 四杠子+四暗刻（双役满）
  do
    local melds = { meld_ankan("1111m"), meld_ankan("2222m"), meld_ankan("3333m"), meld_ankan("4444m") }
    local sc = score_hand(mk("1p"), melds, mk("1p")[1], "tsumo", base_SC())
    check("T19四杠子+四暗刻双役满", sc and sc.yakuman, 2)
    check("T19双役满基本点", sc and sc.basic, 16000)
  end
  -- T20 混老头 50 符
  do
    local sc = score_hand(mk("111m999m1199p"), { meld_pon("777z") }, mk("1p")[1], "ron", base_SC())
    check("T20混老头", sc ~= nil and has_yaku(sc, "混老头"), true)
    check("T20对对和并存", sc ~= nil and has_yaku(sc, "对对和"), true)
    check("T20符", sc and sc.fu, 50)
  end
  -- T21 无役不能和
  do
    local sc = score_hand(mk("123m789m123p4p"), { meld_chi("789s") }, mk("5p")[1], "ron", base_SC())
    check("T21无役拒和", sc, nil)
  end
  -- T22 两立直+一发+里宝
  do
    local SC = base_SC()
    SC.riichi = true
    SC.daburu = true
    SC.ippatsu = true
    SC.dora = { 1 }
    SC.ura = { 1 }
    local sc = score_hand(mk("123m456m789m567m5p"), {}, mk("5p")[1], "tsumo", SC)
    check("T22两立直", sc ~= nil and has_yaku(sc, "两立直"), true)
    check("T22一发", sc ~= nil and has_yaku(sc, "一发"), true)
    check("T22里宝牌", sc ~= nil and has_yaku(sc, "里宝牌"), true)
  end
  -- T23 红宝牌
  do
    local SC = base_SC()
    SC.dora = {}
    local sc = score_hand(mk("406m234p678p234s5s"), {}, mk("5s")[1], "tsumo", SC)
    check("T23红宝牌", sc ~= nil and has_yaku(sc, "红宝牌"), true)
    check("T23断幺九", sc ~= nil and has_yaku(sc, "断幺九"), true)
  end
  -- T24 向听与听牌
  do
    local cnt = hand_to_cnt(mk("123m456m789m34p56p"))
    check("T24听牌向听数", shanten_hand(cnt, 0), 0)
    local ws = waits_of(cnt, 0)
    local has6p, has3p = false, false
    for _, k in ipairs(ws) do
      if k == 14 then has6p = true end
      if k == 11 then has3p = true end
    end
    check("T24待牌含六筒", has6p, true)
    check("T24待牌含三筒", has3p, true)
    local cnt2 = hand_to_cnt(mk("123m456m789m15p24s"))
    check("T24一向听", shanten_hand(cnt2, 0), 1)
    local cnt3 = hand_to_cnt(mk("19m19p19s1234567z"))
    check("T24国士听牌", shanten_hand(cnt3, 0), 0)
  end
  -- T25 小三元
  do
    local sc = score_hand(mk("555666z123m456p7z"), {}, mk("7z")[1], "ron", base_SC())
    check("T25小三元", sc ~= nil and has_yaku(sc, "小三元"), true)
    check("T25翻数(小三元+双役牌=4)", sc and sc.han, 4)
  end
  TESTS = { pass = pass, fail = fail, fails = fails }
  printh("SELFTEST pass=" .. pass .. " fail=" .. fail)
end

draw_selftest = function()
  cls(0)
  local t = "核心逻辑自测"
  print(t, (256 - tw(t)) / 2, 8, C_GOLD)
  local s = "通过 " .. TESTS.pass .. " / 失败 " .. TESTS.fail
  print(s, (256 - tw(s)) / 2, 32, TESTS.fail == 0 and C_GREEN or C_RED)
  local y = 56
  for i = 1, min(#TESTS.fails, 11) do
    print(TESTS.fails[i], 8, y, C_RED)
    y = y + 17
  end
  if #TESTS.fails > 11 then
    print("…共 " .. #TESTS.fails .. " 项失败（详见终端）", 8, y, C_DIM)
  end
  if flr(T / 20) % 2 == 0 then
    local h = "Ⓐ 继续"
    print(h, (256 - tw(h)) / 2, 236, C_GOLD)
  end
end

-- ================================================================ 生命周期

function _init()
  TEST_MODE = (peek(0x064400) == 42)
  bake_tiles()
  init_audio()
  load_save()
  if TEST_MODE then
    run_self_tests()
    MODE = "test"
  else
    MODE = "title"
  end
end


