extends SceneTree

func _initialize() -> void:
	var settings_scene = load("res://Scenes/UI/Scenes/SettingsScene.tscn").instantiate()
	root.add_child(settings_scene)
	var page = settings_scene.get_node_or_null("SettingsRoot/PagesRoot/MobieControlsPage")
	assert(page != null, "MobieControlsPage missing")
	assert(page.has_method("_create_alpha_slider"), "alpha slider factory missing")
	var slider = page.get_node_or_null("VirtualButtonAlphaSlider")
	assert(slider != null, "VirtualButtonAlphaSlider missing")
	assert(slider is HSlider, "VirtualButtonAlphaSlider is not HSlider")
	assert(page.default_button_alpha == 1.0, "default alpha should start at 1.0")
	page.default_button_alpha = 0.5
	page._apply_button_alpha()
	var button = page.get_node_or_null("MoveJoystick")
	assert(button != null, "MoveJoystick missing")
	assert(abs(button.modulate.a - 0.5) < 0.001, "MoveJoystick alpha not applied")
	print("VERIFY_MOBILE_CONTROLS_ALPHA_OK")
	quit()
