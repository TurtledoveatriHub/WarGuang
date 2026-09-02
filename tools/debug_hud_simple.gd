extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	print("before action press right=", Input.is_action_pressed("right"))
	Input.action_press("right")
	print("after action_press right=", Input.is_action_pressed("right"))
	Input.action_release("right")
	print("after action_release right=", Input.is_action_pressed("right"))
	var v: Vector2 = Vector2(40.0, 0.0)
	hud._apply_move_vector_from_joystick(v)
	print("after vector right=", Input.is_action_pressed("right"), "move_state=", hud._move_state)
	quit()
