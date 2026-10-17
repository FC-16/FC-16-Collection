-- 99_main.lua —— 入口与帧循环（§8：_update → _draw）

function new_game()
  flreset()
  G.stage = 13
  G.items = {}
  plr = new_player(9, 3, 1)
  npcs_spawn_for_stage()
  update_camera(true)
  G.fade_tgt = 0
  scr_run(1000)
end

function _init()
  -- 有存档则续玩；按住 B（射击键）启动则重开新游戏
  if has_save() and not btn("b") then
    load_save()
  else
    new_game()
  end
end

function _update()
  game_update()
end

function _draw()
  game_draw()
end
