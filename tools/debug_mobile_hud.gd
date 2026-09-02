extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	print("HAS_ACTION_RIGHT=", InputMap.has_action("right"))
	print("RIGHT_EVENTS=", InputMap.action_get_events("right").size())
	var base: TextureButton = hud.get_node("Root/MoveJoystick")
	var thumb: TextureButton = hud.get_node("Root/MoveJoystickThumb")
	print("BEFORE=dragging=", hud._is_dragging_joystick, "right=", Input.is_action_pressed("right"), "left=", Input.is_action_pressed("left"))
	hud._on_move_joystick_pressed(base)
	print("AFTER_PRESSED=dragging=", hud._is_dragging_joystick, "right=", Input.is_action_pressed("right"), "left=", Input.is_action_pressed("left"))
	hud._update_joystick_from_pointer(base.position + base.size * 0.5 + Vector2(40.0, 0.0))
	print("AFTER_UPDATE=move_state=", hud._move_state)
	print("AFTER_UPDATE_PRESS=right=", Input.is_action_pressed("right"), "left=", Input.is_action_pressed("left"), "up=", Input.is_action_pressed("up"), "down=", Input.is_action_pressed("down"))
	quit()
