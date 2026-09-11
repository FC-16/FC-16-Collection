-- 螺旋矩形隧道（PICO-8 网络流传 tweetcart 的 FC-16 移植版，v0.6 原生 fillp）
--
-- 原作（PICO-8）：
--   c={0,1,2,8,14,15,7}
--   fillp(0xa5a5)
--   function _draw()
--     for w=3,68,.1 do
--       a=4/w+t()/4 k=145/w
--       x=64+cos(a)*k y=64+sin(a)*k
--       i=35/w+2+t()*3
--       rect(x-w,y-w,x+w,y+w,f(i)*16+f(i+.5))
--     end
--   end
--   function f(i) return c[flr(1.5+abs(6-i%12))] end
--
-- 移植要点（对照 SPEC）：
--   · 屏幕 128×128 → 256×256（§2.1）：几何整体 ×2（中心 64→128，w 3..68 → 6..136，
--     k=145/w → 290/w，i=35/w → 70/w，角度项 4/w → 8/w）
--   · 三角函数圈制（§7.2 v0.6）：与原作同单位，角度表达式逐字不变
--   · t() → time()（§7.2：time() = frame()/60）
--   · 16 色 → ENDESGA-64 固定调色板（§2.2）：黑 0、深蓝 12、紫 53、红 63、
--     粉 57、浅肤 21、白 7（对应原作 黑→蓝→紫→红→粉→白 的隧道配色）
--   · fillp 双色（§2.3 v0.6）：原生抖动；双色编码由 ×16 改为 ×256（本机 64 色）。
--     0xa5a5 在 §2.3 位格（bit15=左上、行优先）下恰为 (r+c) 偶数取 c₁ 的棋盘格，
--     与软件逐像素版 ((x+y)%2==0 → c₁) 逐位等效
--
-- 画面四角半径 > 最大环到达半径（290/w + w 最大 138 < 181 半对角线），
-- 与原作一样留暗角，形成圆形隧道构图，无需 cls。

local c = {0, 12, 53, 63, 57, 21, 7}

function f(i)
  return c[flr(1.5 + abs(6 - i % 12))]
end

function _draw()
  fillp(0xa5a5)
  local tm = time()
  for w = 6, 136, 0.3 do
    local a = 8 / w + tm / 4 -- 圈制：与原作同式
    local k = 290 / w
    local x = 128 + cos(a) * k
    local y = 128 + sin(a) * k
    local i = 70 / w + 2 + tm * 3 -- 原作 35/w ×2（缩放保持，无额外散布项）
    -- 原作两点式 rect((x-w),(y-w),(x+w),(y+w)) 为闭区间，边长 2w+1 像素
    rect(flr(x - w), flr(y - w), flr(2 * w + 1), flr(2 * w + 1), f(i) * 256 + f(i + 0.5))
  end
end
