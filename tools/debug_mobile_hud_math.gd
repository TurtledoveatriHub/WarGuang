extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://Scenes/GameScenes/MainGameScene.tscn").instantiate()
	root.add_child(scene)
	var hud: CanvasLayer = scene.get_node("MobileTouchHUD")
	var base: TextureButton = hud.get_node("Root/MoveJoystick")
	var thumb: TextureButton = hud.get_node("Root/MoveJoystickThumb")
	print("base pos=", base.position, "size=", base.size, "scale=", base.scale)
	var center: Vector2 = base.position + base.size * 0.5
	var pointer: Vector2 = center + Vector2(40.0, 0.0)
	var vector_offset: Vector2 = pointer - center
	var max_radius: float = maxf(base.size.x * 0.45, 18.0)
	print("center=", center, "pointer=", pointer, "vector_offset=", vector_offset, "max_radius=", max_radius)
	print("normalized=", vector_offset / max_radius)
	hud._joystick_base = base
	hud._joystick_thumb = thumb
	hud._update_joystick_from_pointer(pointer)
	print("after _update_joystick_from_pointer => ", hud._move_state, Input.is_action_pressed("right"), Input.is_action_pressed("left"))
	quit()
