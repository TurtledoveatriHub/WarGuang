extends SceneTree

func _initialize() -> void:
	var scene_resource = load("res://Scenes/GameScenes/MainGameScene.tscn")
	if scene_resource == null:
		push_error("MainGameScene scene resource failed to load.")
		quit(1)
		return
	var instance = scene_resource.instantiate()
	if instance == null:
		push_error("MainGameScene instance creation failed.")
		quit(1)
		return
	print("MainGameScene scene instantiated successfully.")
	instance.queue_free()
	quit(0)
