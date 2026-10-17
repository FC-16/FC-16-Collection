//! FC16-AC-163：Celeste2等时输入跳跃高度、碰撞与第二关房间通行。
use fc16_core::{
    cart::CartData, config, font::Font, input::InputState, machine::NoopHost, Machine, RunState,
    Tunables,
};
use std::{path::Path, sync::Arc};

fn machine() -> Machine {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("celeste2/celeste2.fc16");
    let cart = CartData::parse_file(&std::fs::read(path).unwrap(), "celeste2.fc16").unwrap();
    let m = Machine::new(
        cart,
        Tunables::default(),
        0,
        0,
        String::new(),
        Arc::new(Font::from_bytes(config::FONT).unwrap()),
        None,
    );
    // 测试在已加载卡带外修改全局状态，关闭 safeenv 的导入缓存后设置房间起点。
    m.lua.globals().set_safeenv(false);
    m
}

#[test]
fn glacial_caves_lower_ring_route_reaches_checkpoint() {
    let mut m = machine();
    m.lua
        .load(
            r#"
        goto_level(4)
        level_intro=0 infade=120
        camera_x=1024 camera_y=256 camera_target_x=1024 camera_target_y=256
        camera(camera_x,camera_y)
        for o in all(objects) do
            if o.base==player then
                o.x=1240 o.y=448 o.speed_x=0 o.speed_y=0 o.state=0 o.facing=-1
                o.remainder_x=0 o.remainder_y=0
            end
        end
    "#,
        )
        .exec()
        .unwrap();
    let output = std::env::var_os("FC16_CELESTE_REVIEW_DIR").map(std::path::PathBuf::from);
    if let Some(dir) = &output {
        std::fs::create_dir_all(dir).unwrap();
        m.lua
            .load(
                r#"
            local draw_game = _draw
            function _draw()
                draw_game()
                camera(0,0)
                rectfill(0,0,256,16,0)
                for i,key in ipairs({"left","right","a","b"}) do
                    print(btnicon(key),4+(i-1)*16,2,btn(key) and 7 or 4)
                end
                print("第二关：下方圆环路线",76,2,7)
                camera(camera_x,camera_y)
            end
        "#,
            )
            .exec()
            .unwrap();
    }
    let left = 1;
    let right = 2;
    let jump = 1 << 4;
    let grapple = 1 << 5;
    let route = [
        (0, 30),
        (left, 27),                  // 从右侧平台落到下方圆环的高度。
        (left | grapple, 16),        // 向左拉近，经过圆环时仍保留钩索跳窗口。
        (left | jump | grapple, 12), // 钩索跳穿过冰柱底部。
        (right, 8),                  // 释放跳跃，准备在窄缝左壁蹬墙。
        (right | jump, 12),
        (right, 3), // 到达窄缝右壁，再次释放跳跃。
        (left | jump, 20),
        (left, 20), // 落上左侧记录点平台。
        (right, 20),
        (0, 45),
    ];
    let mut frame = 0;
    for (buttons, count) in route {
        for _ in 0..count {
            m.frame(
                [
                    InputState::from_buttons(buttons),
                    fc16_core::input::InputState::ZERO,
                    fc16_core::input::InputState::ZERO,
                    fc16_core::input::InputState::ZERO,
                ],
                &mut NoopHost,
            );
            assert_eq!(m.state, RunState::Running);
            if let Some(dir) = &output {
                let file = std::fs::File::create(dir.join(format!("{frame:04}.png"))).unwrap();
                let mut png = png::Encoder::new(file, 256, 256);
                png.set_color(png::ColorType::Rgb);
                png.set_depth(png::BitDepth::Eight);
                png.write_header()
                    .unwrap()
                    .write_image_data(&m.screenshot_rgb())
                    .unwrap();
            }
            frame += 1;
        }
    }
    assert_eq!(
        m.lua.globals().get::<u32>("level_checkpoint").unwrap(),
        4 * 8192 + 66 + 25 * 128
    );
    assert_eq!(m.lua.globals().get::<u32>("death_count").unwrap(), 0);
    assert_eq!(m.lua.globals().get::<u32>("level_index").unwrap(), 4);
}

#[test]
fn jump_heights_and_impulses_match_equal_duration_reference_inputs() {
    let m = machine();
    m.lua
        .load(include_str!("fixtures/celeste2_jumps.lua"))
        .exec()
        .unwrap();
    let measure: mlua::Function = m.lua.globals().get("measure_jump").unwrap();
    // 原作 player.lua（SHA256 c653fbdd084b7dbb0d5f4264a568b758a6352d2259e242517c9febc06e9a9e73）
    // 实测1..7个30Hz更新的保持输入；高度换算至2倍坐标，测试无需原作运行时或文件。
    for (kind, heights, impulse) in [
        ("jump", [24, 32, 40, 48, 56, 56, 56], 0.2),
        ("wall_jump", [14, 20, 26, 32, 38, 38, 38], 3.0),
        ("grapple_jump", [14, 20, 26, 32, 38, 38, 38], 0.0),
        ("spring", [36, 46, 56, 66, 76, 86, 96], 0.0),
        ("bounce", [48, 48, 48, 48, 48, 48, 48], 0.5),
    ] {
        for (i, height) in heights.into_iter().enumerate() {
            let (actual, vx): (i32, f64) = measure.call((kind, (i + 1) * 2)).unwrap();
            assert_eq!(actual, height, "{kind} held for {} frames", (i + 1) * 2);
            assert!((vx - impulse).abs() < 1e-9, "{kind} initial impulse {vx}");
        }
    }
}

#[test]
fn ceiling_stops_jump_hold_without_tunneling() {
    let mut m = machine();
    m.lua
        .load(
            r#"
        goto_level(4) level_intro=0 infade=120 objects={}
        for x=28,36 do for y=18,26 do mset(x,y,0) end end
        for x=28,36 do mset(x,22,60) mset(x,25,60) end
        test_player=create(player,512,384)
    "#,
        )
        .exec()
        .unwrap();
    let p: mlua::Table = m.lua.globals().get("test_player").unwrap();
    let mut hit_ceiling = false;
    for frame in 0..60 {
        m.frame(
            [
                InputState::from_buttons(if frame < 35 { 1 << 4 } else { 0 }),
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
                fc16_core::input::InputState::ZERO,
            ],
            &mut NoopHost,
        );
        assert_eq!(m.state, RunState::Running);
        let y: f64 = p.get("y").unwrap();
        assert!(y >= 380.0, "穿过顶板：{y}");
        if y == 380.0 && p.get::<f64>("speed_y").unwrap() == 0.0 {
            assert_eq!(p.get::<u32>("t_var_jump").unwrap(), 0);
            hit_ceiling = true;
        }
    }
    assert!(hit_ceiling);
    assert_eq!(p.get::<f64>("y").unwrap(), 400.0);
}

#[test]
fn celeste2_release_matches_project_content() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("celeste2");
    let load =
        |name: &str| CartData::parse_file(&std::fs::read(root.join(name)).unwrap(), name).unwrap();
    assert_eq!(
        load("celeste2.fc16").to_fc16().unwrap(),
        load("celeste2.fc16.png").to_fc16().unwrap()
    );
}

#[test]
fn centered_bounce_and_anchor_crossing_preserve_boundary_direction() {
    let m = machine();
    m.lua
        .load(include_str!("fixtures/celeste2_jumps.lua"))
        .exec()
        .unwrap();
    let result: (f64, f64, f64, i32, i32) = m
        .lua
        .load(
            r#"
        measure_jump("jump",10)
        local p=objects[1]
        local impulses={}
        for _,offset in ipairs({-1,0,1}) do
            p.x=400+offset p.y=400 p.speed_x=0
            p:bounce(400,400)
            table.insert(impulses,p.speed_x)
        end
        local states={}
        input_x=0 input_jump=false input_jump_pressed=0 input_grapple=true
        for _,direction in ipairs({-1,1}) do
            p.x=400 p.y=400 p.state=11 p.speed_x=0 p.speed_y=0
            p.grapple_dir=direction p.grapple_x=400 p.grapple_y=394
            p.grapple_boost=true p.grapple_hit=nil
            p:update()
            table.insert(states,p.state)
        end
        return impulses[1],impulses[2],impulses[3],states[1],states[2]
    "#,
        )
        .eval()
        .unwrap();
    assert_eq!(result, (-0.5, 0.5, 0.5, 11, 0));
}

#[test]
fn snowball_stomp_throw_and_spawn_settle_after_one_bounce() {
    let m = machine();
    m.lua
        .load(include_str!("fixtures/celeste2_snowball.lua"))
        .exec()
        .unwrap();
    let measure: mlua::Function = m.lua.globals().get("measure_snowball").unwrap();
    for (kind, expected) in [("stomp", 0), ("thrown", 1), ("spawned", 1), ("dropped", 0)] {
        let (bounces, y, speed_x): (i32, i32, f64) = measure.call(kind).unwrap();
        assert_eq!(bounces, expected, "{kind}");
        assert_eq!(y, 399, "{kind} should settle on the floor");
        if kind == "dropped" {
            assert_eq!(speed_x, 0.0, "dropped snowball should stop");
        } else {
            assert!(speed_x > 0.0, "{kind} should keep rolling");
        }
    }
    let (first, second, y, speed_x): (i32, i32, i32, f64) = measure.call("rethrow").unwrap();
    assert_eq!((first, second, y), (1, 1, 399));
    assert!(speed_x > 0.0);
}
