extends SceneTree

func _initialize() -> void:
	var hud = load("res://Scripts/GameScenes/MobileTouchHUD.gd").new()
	root.add_child(hud)
	var hud_root := Control.new()
	hud_root.name = "Root"
	hud_root.size = Vector2(1280.0, 720.0)
	hud.add_child(hud_root)

	var base := TextureButton.new()
	base.name = "MoveJoystick"
	base.position = Vector2(60.0, 500.0)
	base.size = Vector2(64.0, 64.0)
	hud_root.add_child(base)

	var thumb := TextureButton.new()
	thumb.name = "MoveJoystickThumb"
	thumb.position = Vector2(89.0, 533.0)
	thumb.size = Vector2(32.0, 32.0)
	hud_root.add_child(thumb)

	hud._root = hud_root
	hud._joystick_base = base
	hud._joystick_thumb = thumb
	hud._bind_virtual_buttons()
	hud._update_joystick_from_pointer(Vector2(160.0, 520.0))
	print("MOVE_STATE=", hud._move_state)
	print("RIGHT=", Input.is_action_pressed("right"))
	print("LEFT=", Input.is_action_pressed("left"))
	print("UP=", Input.is_action_pressed("up"))
	print("DOWN=", Input.is_action_pressed("down"))
	quit()
