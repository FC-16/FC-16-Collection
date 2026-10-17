-- ============================================================
-- 小丑牌 · FC-16（balatro-gba 移植版）
-- 以 GBALATRO/balatro-gba 为移植蓝本（研究学习用途）：52+1 小丑、13 牌型、
-- 8 ante、30 盲注、商店/结算/开局设置/选项，交互与演出按 GBA 版语义。
-- 精灵/背景由 gen_assets.py 从 gba/*.png 转换（64 色最近邻）。
-- ============================================================
-- ============================================================
-- 模块经构建期静态 require 组合（fc16.project.json → fc16-tools project build）；
-- 状态经全局表共享，模块值仅在此收集以声明依赖与组装顺序
local __modules = {
  require("const"),
  require("content"),
  require("input"),
  require("ui"),
  require("hand"),
  require("score"),
  require("run"),
  require("blindsel"),
  require("round"),
  require("shop"),
  require("menus"),
  require("save"),
}

-- ------------------------------------------------------------ 运行状态
st, tt = "splash", 0
G = nil            -- 对局变量
DH, DK, DS = {}, {}, {}   -- 手牌 / 牌库(栈) / 打出区
menu, OV = { i = 1 }, nil
SHOP = nil
FLT = {}           -- 浮动文字
SHK = 0            -- 震屏
OPT = { speed = 1 }
RUN = { seed = 0, used = false, reuse = false }

-- ============================================================ 主循环
function _init()
  save_init()
  OPT.speed = saved_speed()
  music(0, 400, 0xC7)
end

function _update()
  tt = tt + 1
  poll_input()
  if SHK > 0 then SHK = SHK - 1 end
  for i = #FLT, 1, -1 do
    local f = FLT[i]
    f.t = f.t + 1
    if f.t > 40 then deli(FLT, i) end
  end
  if st == "splash" then
    if tt > 45 then to_menu() end
  elseif st == "menu" then up_menu()
  elseif st == "setup" then up_setup()
  elseif st == "options" then up_options()
  elseif st == "blindsel" then up_blindsel()
  elseif st == "round" then
    if PS.ph == "deal" then
      tick_round()
      PS.t = PS.t + 1
      if PS.t >= sp(24) then PS.ph, PS.t = "input", 0 end
    elseif PS.ph == "input" then
      tick_round()
      up_round()
    elseif PS.ph == "tosort" then
      tick_round()
      PS.t = PS.t + 1
      if PS.t >= sp(16) then begin_score() end
    else
      up_round_score()
    end
  elseif st == "roundend" then up_roundend()
  elseif st == "shop" then up_shop()
  elseif st == "over" then up_over()
  end
end

function _draw()
  pal()
  cls(0)
  if st == "splash" then
    local t = MIN(tt, 45)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      print("BALATRO", 128 - tw2("BALATRO") / 2 + d[1], 116 + d[2], CL.red, 2)
    end
    print("BALATRO", 128 - tw2("BALATRO") / 2, 116, 7, 2)
  elseif st == "menu" then dn_menu()
  elseif st == "setup" then dn_setup()
  elseif st == "options" then dn_options()
  elseif st == "blindsel" then dn_blindsel()
  elseif st == "round" then
    dn_round()
    if PS.ph == "input" then
      hint({ { "pad", "移动" },
        { "a", PS.row == 0 and "换位" or (seln() > 0 and "已选" .. seln() or "选牌") },
        { "b", "取消" }, { "lt", "点数", G.sortm == 0 and CL.cur or CL.g1 },
        { "rt", "花色", G.sortm == 1 and CL.cur or CL.g1 } })
    elseif HELO then
      hint({ [1] = { nil, "计分中…" } })
    end
  elseif st == "roundend" then dn_roundend()
  elseif st == "shop" then
    dn_shop()
    local rows = { { "pad", "移动" } }
    if SHOP.row == 0 then
      rows[#rows + 1] = { "a", "购买" }
    elseif SHOP.row == 1 then
      rows[#rows + 1] = { "a", SHOP.cur == 1 and "重掷" or "离开" }
    else
      rows[#rows + 1] = { "lb", "出售" }
    end
    hint(rows)
  elseif st == "over" then dn_over()
  end
end
