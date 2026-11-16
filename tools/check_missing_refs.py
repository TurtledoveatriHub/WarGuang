# -*- coding: utf-8 -*-
"""扫描所有 .tscn / .tres 中 ext_resource 引用的文件是否存在（只读，不修改任何文件）。"""
import re
import subprocess
from pathlib import Path

PROJECT = Path(r"D:\Tools\GameTools\GODOT\GodotGames\warma-shadow-test")
COMMIT = "2c1290e"


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(PROJECT), *args], capture_output=True).stdout.decode("utf-8", "replace")


def main() -> None:
    raw = git("ls-tree", "-r", "-z", "--name-only", COMMIT)
    tracked = [p for p in raw.split("\0") if p]
    tracked_set = set(tracked)

    missing = {}
    pat = re.compile(r'path="(res://[^"]+)"')
    files = [p for p in tracked if p.endswith((".tscn", ".tres"))]
    for rel in files:
        path = PROJECT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for ref in pat.findall(text):
            target = ref.replace("res://", "")
            if target in tracked_set:
                continue
            missing.setdefault(ref, []).append(rel)

    print(f"检查了 {len(files)} 个场景/资源文件；共发现 {len(missing)} 个在提交 {COMMIT} 中不存在的引用：")
    for ref in sorted(missing):
        users = sorted(set(missing[ref]))
        print(f"  {ref}")
        print(f"      <- {', '.join(users[:4])}{' ...' if len(users) > 4 else ''}")


if __name__ == "__main__":
    main()
