# FC-16 Collection

FC-16 完整游戏合集，包含 33 款游戏。完整游戏的源码、资源、项目配置和回归测试只在此维护；主机仓库的 demo 仅维护联机、物理等 API 功能示例。

使用与当前 [FC-16 规范](../FC-16/spec/SPEC.md) 同步的主机和工具。每款游戏的 `fc16.project.json` 是元数据、代码、资源和发布路径的唯一来源；目录内的 `.fc16` 与 `.fc16.png` 都由它生成。点击 [卡带目录](index.html) 浏览，PNG 本身就是可运行卡带。

```bash
# 将 FC-16 与 FC-16-Collection 放在同一父目录；需要 Rust 与 Python 3。
python3 tools/build_all.py
python3 tools/verify_all.py
../FC-16/target/debug/fc16 celeste2/celeste2.fc16
```

`build_all.py` 可跟游戏名，只重建指定游戏；`--fc16-root` 或 `FC16_ROOT` 可指定主机源码目录，`--profile release` 使用发行构建。默认会先编译当前工具；已编译可用 `--skip-tools-build`。资源转换脚本用于重新制作素材，普通构建使用已提交的当前资源，不需要原版游戏、ROM 或第三方美术工具。

验证会重建临时副本并比较发布产物，随后运行全部游戏的标题、开始、方向、暂停和选项输入，以及 Celeste2、Balatro、Crimson Night、魔塔和存档回归。截图与音频预览为手动诊断，使用 `--preview-dir` 导出，不设与机器性能或音量有关的默认验收阈值。

游戏各自的玩法与素材来源见目录内 README；第三方游戏、美术、音乐遵循各自来源的许可，收录不改变其授权。
