# -*- coding: utf-8 -*-
"""(可选) 对比 2c1290e 快照与当前工作区，找出可能由 VS Code 本地历史恢复来的额外文件。

用途：reset 事故恢复后，确认没有把旧版本文件"混"回项目中。
只读：不修改、不删除任何文件。
"""
import hashlib
import subprocess
from pathlib import Path

PROJECT = Path(r"D:\Tools\GameTools\GODOT\GodotGames\warma-shadow-test")
SNAPSHOT = Path(r"D:\Tools\GameTools\GODOT\GodotGames\_warma_recover_2c1290e")
COMMIT = "2c1290e"


def git(*args: str) -> str:
    result = subprocess.run(["git", "-C", str(PROJECT), *args], capture_output=True)
    return result.stdout.decode("utf-8", "replace")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    tracked = [p for p in git("ls-tree", "-r", "-z", "--name-only", COMMIT).split("\0") if p]
    missing = [p for p in tracked if not (PROJECT / p).exists()]
    print(f"提交 {COMMIT} 跟踪文件: {len(tracked)}，本地缺失: {len(missing)}")
    for p in missing:
        print("  缺失:", p)

    # 顶层"多出来"的条目（快照里没有、当前却有）
    snap_top = {p.split("/")[0] for p in tracked}
    extra_top = []
    for child in sorted(PROJECT.iterdir()):
        name = child.name
        if name in {".git", ".godot"} or name in snap_top:
            continue
        extra_top.append(name)
    print("当前顶层多出的条目（需人工确认是否为 VS Code 历史恢复的旧文件）:")
    for name in extra_top:
        print("  ", name)

    # 关键目录计数
    counts = {
        "Scripts/*.gd": len(list((PROJECT / "Scripts").rglob("*.gd"))),
        "Scenes/*.tscn": len(list((PROJECT / "Scenes").rglob("*.tscn"))),
        "Assets/*.png": len(list((PROJECT / "Assets").rglob("*.png"))),
        "Assets/*.import": len(list((PROJECT / "Assets").rglob("*.import"))),
        "Scenes/GameScenes/Rooms/*.tscn": len(list((PROJECT / "Scenes/GameScenes/Rooms").rglob("*.tscn"))),
    }
    print("关键文件计数:")
    for k, v in counts.items():
        print(f"  {k}: {v}")

    if SNAPSHOT.exists():
        print(f"快照目录存在: {SNAPSHOT}（确认无误后可删除）")


if __name__ == "__main__":
    main()
