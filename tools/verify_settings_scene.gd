extends SceneTree
## 冒烟测试：设置场景能否加载并实例化。
## 用法：godot --headless --path . --script tools/verify_settings_scene.gd

const ScenePathsScript := preload("res://Scripts/Managers/ScenePaths.gd")

func _initialize() -> void:
	var scene_resource = load(ScenePathsScript.UI_SETTINGS)
	if scene_resource == null:
		push_error("SettingsScene resource failed to load.")
		quit(1)
		return
	var instance = scene_resource.instantiate()
	if instance == null:
		push_error("SettingsScene instance creation failed.")
		quit(1)
		return
	print("SettingsScene instantiated successfully.")
	instance.queue_free()
	quit(0)
