extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	var base: TextureButton = hud.get_node("Root/MoveJoystick")
	var thumb: TextureButton = hud.get_node("Root/MoveJoystickThumb")
	print("size=", base.size, "scale=", base.scale, "pos=", base.position)
	print("thumb pos=", thumb.position, "size=", thumb.size)
	hud._apply_move_vector_from_joystick(Vector2(40.0, 0.0))
	print("after apply: ", hud._move_state)
	print("input right=", Input.is_action_pressed("right"))
	quit()
