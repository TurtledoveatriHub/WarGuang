extends SceneTree

func _initialize() -> void:
	var scene_resource = load("res://Scenes/UI/Scenes/SettingsScene.tscn")
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
