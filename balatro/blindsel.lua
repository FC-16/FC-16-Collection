-- 盲注选择屏
-- ============================================================ 盲注选择
function up_blindsel()
  if BS.anim > 0 then BS.anim = BS.anim - 1 return end
  if dpr("left") then BS.bi, BS.row = (BS.bi - 2) % 3 + 1, 0 sfx(0, CH_UI) end
  if dpr("right") then BS.bi, BS.row = BS.bi % 3 + 1, 0 sfx(0, CH_UI) end
  if dpr("up") then BS.bi, BS.row = 1, 0 sfx(0, CH_UI) end
  if dpr("down") then BS.row = 1 sfx(0, CH_UI) end
  if kA() then
    if BS.row == 1 then          -- 跳过（仅小/大盲注，无奖励，GBA 语义）
      if G.blind < 3 then
        G.bstat[G.blind] = "skip"
        sfx(27, CH_UI)
        G.blind = G.blind + 1
        to_blindsel()
      else
        buzz()
      end
    elseif BS.bi == G.blind then -- 顺序作战：只能迎战当前盲注
      sfx(12, CH_UI)
      st, tt = "round", 0
      start_round()
    else
      buzz()
    end
  end
end
function dn_blindsel()
  cls(37)
  ptext("选择你的盲注", 16, 7, 0, 256, 2)
  ptext("底注 " .. G.ante .. "/8    轮次 " .. G.round .. "    $" .. fmt(G.money), 44, CL.g2, 0, 256)
  for i = 1, 3 do
    local t = i - 1
    local bossid = G.ante % 8 == 0 and BL_SD0 + (G.boss - BL_SD0) or G.boss
    local art = t == 0 and 0 or (t == 1 and 1 or bossid)
    local x = 36 + (i - 1) * 76
    local sel = BS.bi == i and BS.row == 0
    local y = sel and 72 or 80
    if sel then
      rect(x - 3, y - 3, 38, 38, 7)
      rect(x - 4, y - 4, 40, 40, CL.cur)
    end
    draw_blind(art, x, y)
    ptext(blind_name(t), y + 36, sel and 7 or CL.g2, x, x + 32)
    print(fmt(blind_req(t)), x + 2, y + 52, CL.red)
    print("$" .. blind_reward(t), x + 2, y + 66, CL.gold)
    local st = "fut"
    if G.blind == i then st = "cur"
    elseif G.bstat[i] == true then st = "win"
    elseif G.bstat[i] then st = "skip" end
    if st == "cur" then ptext("▶迎战", y + 80, CL.cur, x, x + 32)
    elseif st == "win" then ptext("已击败", y + 80, CL.frost, x, x + 32)
    elseif st == "skip" then ptext("已跳过", y + 80, CL.g1, x, x + 32)
    else ptext("未解锁", y + 80, CL.d3, x, x + 32) end
  end
  -- 跳过行（常显；仅小/大盲注可跳）
  local skipok = G.blind < 3
  rectfill(48, 190, 160, 22, BS.row == 1 and CL.dred or CL.hole)
  rect(48, 190, 160, 22, BS.row == 1 and 7 or CL.d3)
  ptext(skipok and "跳过此盲注（无奖励）" or "Boss 不可跳过", 196,
    BS.row == 1 and 7 or CL.g1)
  hint({ { "pad", "选择" }, { "a", BS.row == 1 and "跳过" or (BS.bi == G.blind and "迎战" or "查看") },
    { "down", "跳过" } })
end
