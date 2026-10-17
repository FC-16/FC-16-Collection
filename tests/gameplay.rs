//! 游戏行为回归：存档、物理生命周期与方向输入。
use fc16_core::{cart::CartData, config, font::Font, Machine, RunState, Tunables};
use std::{fs, path::Path, sync::Arc};

fn game(name: &str, hooks: &str, saved: Option<&[u8]>) -> Machine {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join(name);
    let mut cart = CartData::parse_file(
        &fs::read(root.join(format!("{name}.fc16"))).unwrap(),
        "cart.fc16",
    )
    .unwrap();
    cart.code = fs::read_to_string(root.join(format!("{name}.lua"))).unwrap() + hooks;
    let m = Machine::new(
        cart,
        Tunables::default(),
        0,
        0,
        String::new(),
        Arc::new(Font::from_bytes(config::FONT).unwrap()),
        saved,
    );
    assert_eq!(m.state, RunState::Running, "{name}");
    m
}

#[test]
fn snake_saves_each_mode_record_and_music_setting() {
    let hooks = r#"
function record_test()
  for n=1,3 do mode=n start_game() score=100+n die() end
  toggle_music()
  local data=load()
  assert(data.best_scores[1]==101 and data.best_scores[2]==102 and data.best_scores[3]==103)
  assert(data.music_on==false)
end
function restore_test()
  assert(progress.music_on==false)
  for n=1,3 do mode=n start_game() assert(best==100+n) end
end
"#;
    let m = game("snake", hooks, None);
    m.lua.load("record_test()").exec().unwrap();
    let bytes = m.core.borrow().save.bytes().unwrap().to_vec();
    let restored = game("snake", hooks, Some(&bytes));
    restored.lua.load("restore_test()").exec().unwrap();
}

#[test]
fn tower_slots_round_trip_full_changes_flags_and_equipment() {
    let hooks = r#"
function record_test()
  for slot=0,2 do
    new_game()
    G.hp=1234+slot G.atk=80+slot G.floor=slot+1 G.x=2 G.y=3
    G.fl.prologue=true G.fl.ice=true
    for i=0,699 do G.ch[i]=i%7 end
    G.weapon=3 G.shield=4 G.shops[12]=17
    save_game(slot)
  end
end
function restore_test(is50)
  for slot=0,2 do
    assert(slot_used(slot) and load_game(slot))
    assert(G.hp==1234+slot and G.atk==80+slot and G.floor==slot+1)
    assert(G.x==2 and G.y==3 and G.fl.prologue and G.fl.ice)
    local count=0
    for i=0,699 do assert(G.ch[i]==i%7) count+=1 end
    assert(count==700)
    if is50 then assert(G.weapon==3 and G.shield==4 and G.shops[12]==17) end
  end
end
"#;
    for name in ["mota24", "mota50"] {
        let m = game(name, hooks, None);
        m.lua.load("record_test()").exec().unwrap();
        let bytes = m.core.borrow().save.bytes().unwrap().to_vec();
        let restored = game(name, hooks, Some(&bytes));
        restored
            .lua
            .load(format!("restore_test({})", name == "mota50"))
            .exec()
            .unwrap();
    }
}

#[test]
fn angrybirds_uses_current_objects_and_freezes_without_losing_velocity() {
    let hooks = r#"
function physics_test()
  start_level(1)
  assert(ground_b.kind=='solid' and blocks[1].b.kind=='solid' and pigs[1].b.kind=='actor')
  fire()
  assert(bird.b.kind=='actor' and bird.b.vx>0 and bird.b.vx<8 and bird.b.vy<0)
  local vx,vy=bird.b.vx,bird.b.vy
  pause_freeze() assert(ppause())
  pause_unfreeze() assert(not ppause() and bird.b.vx==vx and bird.b.vy==vy)
  teardown()
end
"#;
    let m = game("angrybirds", hooks, None);
    m.lua.load("physics_test()").exec().unwrap();
    assert!(m.core.borrow().phys.is_empty());
}

#[test]
fn named_directions_move_board_cursors_and_repeat_in_the_same_direction() {
    use fc16_core::{input::InputState, machine::NoopHost};
    for name in ["gomoku", "tictactoe"] {
        for buttons in [1, 2, 4, 8] {
            let hooks = if name == "gomoku" {
                "function prepare() cx=7 cy=7 rep={0,0,0,0} _update=cursor_input _draw=function()end end function position()return cx,cy end"
            } else {
                "function prepare() gx=1 gy=1 gmode=1 rep={0,0,0,0} _update=cursor_input _draw=function()end end function position()return gx,gy end"
            };
            let mut m = game(name, hooks, None);
            m.lua.load("prepare()").exec().unwrap();
            let start: (i32, i32) = m.lua.load("return position()").eval().unwrap();
            for _ in 0..20 {
                m.frame(
                    [
                        InputState::from_buttons(buttons),
                        InputState::ZERO,
                        InputState::ZERO,
                        InputState::ZERO,
                    ],
                    &mut NoopHost,
                );
                assert_eq!(m.state, RunState::Running);
            }
            let end: (i32, i32) = m.lua.load("return position()").eval().unwrap();
            match buttons {
                1 => assert!(end.0 < start.0 && end.1 == start.1),
                2 => assert!(end.0 > start.0 && end.1 == start.1),
                4 => assert!(end.1 < start.1 && end.0 == start.0),
                _ => assert!(end.1 > start.1 && end.0 == start.0),
            }
        }
    }
    for buttons in [1, 2, 4, 8] {
        let hooks = "function prepare(n) start_game() G.phase='select' G.mov={1,2,3,4} G.msel=n _update=update_play _draw=function()end end function position()return G.msel end";
        let mut m = game("ludo", hooks, None);
        let negative = buttons == 1 || buttons == 4;
        m.lua
            .load(if negative { "prepare(4)" } else { "prepare(1)" })
            .exec()
            .unwrap();
        for _ in 0..20 {
            m.frame(
                [
                    InputState::from_buttons(buttons),
                    InputState::ZERO,
                    InputState::ZERO,
                    InputState::ZERO,
                ],
                &mut NoopHost,
            );
            assert_eq!(m.state, RunState::Running);
        }
        let position: i32 = m.lua.load("return position()").eval().unwrap();
        assert_eq!(
            position,
            if negative { 2 } else { 3 },
            "方向按住重复须保持方向"
        );
    }
}
