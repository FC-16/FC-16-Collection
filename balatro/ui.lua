-- 绘制工具与通用控件：文本、凹槽盒、按键提示、按钮、浮字、卡牌精灵
-- ------------------------------------------------------------ 绘制工具
function fmt(n)
  local s = tostring(math.floor(n))
  local out = s:sub(1, #s % 3 == 0 and 3 or #s % 3)
  for i = #s % 3 == 0 and 4 or #s % 3 + 1, #s, 3 do
    out = out .. "," .. s:sub(i, i + 2)
  end
  return out
end
function ptext(s, y, c, x0, x1, sc)
  x0, x1 = x0 or 0, x1 or 256
  sc = sc or 1
  print(s, math.floor((x0 + x1) / 2 - textw(s) * sc / 2), y, c, sc)
end
function fr(x, y, w, h, c)    -- 凹槽信息盒：暗底 + 语义描边色
  rectfill(x, y, w, h, CL.hole)
  rect(x, y, w, h, c or CL.d3)
end
function hint(rows)   -- rows: { 按钮图标名或 nil, 文本, 颜色（默认灰） }
  rectfill(0, 240, 256, 16, 0)
  local x = 4
  for _, r in ipairs(rows) do
    if r[2] and r[2] ~= "" then
      local s = (r[1] and (btnicon(r[1]) .. " ") or "") .. r[2]
      print(s, x, 242, r[3] or CL.g1)
      x = x + textw(s) + 5
    end
  end
end
function toast(s, x, y, c, big)
  FLT[#FLT + 1] = { s = s, x = x, y = y, c = c, t = 0, big = big }
end

-- ------------------------------------------------------------ 卡与小丑绘制
SUITS = { { "♦", 14 }, { "♣", 8 }, { "♥", 32 }, { "♠", 43 } }
function card_tile(c) return band_tile(0, c.s * 13 + c.r) end
function draw_card(c, x, y, o)
  if o and o.back then
    spr(band_tile(T_BACK, G and G.deck or 0), x, y, 2, 2)
  else
    spr(card_tile(c), x, y, 2, 2)
  end
end
function draw_joker(o, x, y, big)
  spr(band_tile(T_JOKER, o.id), x, y, 2, 2)
end
function draw_blind(b, x, y)
  spr(band_tile(T_BLIND, b), x, y, 2, 2)
end
function tip_h(d) return 34 + CEIL(textw(d) / 196) * 12 end
function tip_panel(nm, rc, d, ty, fh)   -- 名称 / 边框色 / 描述 / 顶边（缺省 182）/ 固定高（缺省按描述行数）
  ty = ty or 182
  local h = fh or tip_h(d)
  rectfill(20, ty, 216, h, CL.bg)
  rect(20, ty, 216, h, rc)
  print(nm, 28, ty + 4, 7)
  printw(d, 28, ty + 18, CL.frost, 200)
end


function button(x, y, w, h, s, c, sel, on)
  rectfill(x, y, w, h, on and c or CL.hole)
  rect(x, y, w, h, sel and 7 or (on and c or CL.d3))
  if sel then rect(x - 1, y - 1, w + 2, h + 2, 7) end
  -- 12px 字格墨迹为 11 行且偏下 1px：按 (h-13)/2 定位才能在按钮内垂直居中
  ptext(s, y + math.floor((h - 13) / 2), on and 7 or CL.g1, x, x + w)
end

function floats()
  for i = #FLT, 1, -1 do
    local f = FLT[i]
    local yy = f.y - f.t * 0.5
    if f.big then
      print(f.s, f.x - textw(f.s) / 2 + 1, math.floor(yy) + 1, 0)
      print(f.s, f.x - textw(f.s) / 2, math.floor(yy), f.c)
    else
      print(f.s, f.x - textw(f.s) / 2, math.floor(yy), f.c)
    end
  end
end
