extends SceneTree
## 冒烟测试：确认「主场景 + 设置场景」都能加载并实例化。
## 用法：godot --headless --path . --script tools/verify_scene_chain.gd
## 路径统一取自 ScenePaths（本脚本在 --script 模式下没有 Autoload，所以只能 preload 并读常量）。

const ScenePathsScript := preload("res://Scripts/Managers/ScenePaths.gd")

func _initialize() -> void:
	var scenes: Array[String] = [
		ScenePathsScript.GAME_MAIN,
		ScenePathsScript.UI_SETTINGS,
	]
	for scene_path in scenes:
		var resource = load(scene_path)
		if resource == null:
			push_error("Failed to load: %s" % scene_path)
			quit(1)
			return
		var instance = resource.instantiate()
		if instance == null:
			push_error("Failed to instantiate: %s" % scene_path)
			quit(1)
			return
		print("OK: %s" % scene_path)
		instance.queue_free()
	quit(0)
