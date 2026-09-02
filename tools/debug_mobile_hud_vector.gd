extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	print("before direct = ", hud._move_state, Input.is_action_pressed("right"))
	hud._apply_move_vector_from_joystick(Vector2(1.0, 0.0))
	print("after vector = ", hud._move_state, Input.is_action_pressed("right"), Input.is_action_pressed("left"))
	quit()
