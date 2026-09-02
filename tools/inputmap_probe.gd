extends SceneTree

func _initialize() -> void:
	print("HAS LEFT=", InputMap.has_action("left"))
	Input.action_press("left")
	print("LEFT PRESS=", Input.is_action_pressed("left"))
	Input.action_release("left")
	print("LEFT RELEASED=", Input.is_action_pressed("left"))
	quit()
