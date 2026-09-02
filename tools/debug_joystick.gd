extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	var joystick_base: TextureButton = hud.get_node("Root/MoveJoystick")
	var joystick_thumb: TextureButton = hud.get_node("Root/MoveJoystickThumb")
	print("base_pos=", joystick_base.position, "thumb_pos=", joystick_thumb.position)
	hud._on_move_joystick_pressed(joystick_base)
	hud._update_joystick_from_pointer(joystick_base.position + joystick_base.size * 0.5 + Vector2(40.0, 0.0))
	print("left=", Input.is_action_pressed("left"), "right=", Input.is_action_pressed("right"), "up=", Input.is_action_pressed("up"), "down=", Input.is_action_pressed("down"))
	print("right_events=", InputMap.action_get_events("right"))
	quit()
