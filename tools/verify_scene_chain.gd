extends SceneTree

func _initialize() -> void:
	var scenes = [
		"res://Scenes/GameScenes/MainGameScene.tscn",
		"res://Scenes/UI/Scenes/SettingsScene.tscn"
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
