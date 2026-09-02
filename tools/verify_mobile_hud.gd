extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)

	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	assert(hud != null, "MobileTouchHUD not found")
	var jump_button: TextureButton = hud.get_node("Root/JumpButton")
	assert(jump_button != null, "JumpButton not found")

	hud._on_button_down(jump_button)
	assert(Input.is_action_pressed("jump"), "jump action was not pressed")
	hud._on_button_up(jump_button)
	assert(not Input.is_action_pressed("jump"), "jump action was not released")

	var joystick_base: TextureButton = hud.get_node("Root/MoveJoystick")
	var joystick_thumb: TextureButton = hud.get_node("Root/MoveJoystickThumb")
	assert(joystick_base != null and joystick_thumb != null, "joystick nodes missing")
	hud._on_move_joystick_pressed(joystick_base)
	hud._update_joystick_from_pointer(joystick_base.position + joystick_base.size * 0.5 + Vector2(40.0, 0.0))
	assert(Input.is_action_pressed("right") or Input.is_action_pressed("left") or Input.is_action_pressed("up") or Input.is_action_pressed("down"), "joystick did not set movement action")
	hud._end_joystick_drag()
	assert(not Input.is_action_pressed("left") and not Input.is_action_pressed("right") and not Input.is_action_pressed("up") and not Input.is_action_pressed("down"), "joystick did not reset movement action")

	print("VERIFY_MOBILE_HUD_OK")
	quit()
