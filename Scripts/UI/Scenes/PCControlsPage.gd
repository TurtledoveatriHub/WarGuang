extends Node2D
class_name PCControlsPage

## PC 端按键设置页
@onready var action_list = $ActionList
@onready var controls_hint = $ControlsHint
@onready var reset_button = $ResetButton
@onready var reset_hint_label = $ResetHintLabel

var action_buttons = {}

var reset_state: int = 0
var reset_timer: float = 0.0
@export var reset_hint_show_time: float = 1.5
@export var reset_hint_fade_time: float = 0.5
@export var reset_timeout: float = 2.0

@export var hint_wait_time: float = 0.5
@export var hint_fade_time: float = 0.5
var current_hint_type: String = ""
var hint_timer: Timer = null
var hint_tween: Tween = null

func _ready():
	controls_hint.visible = false
	reset_hint_label.visible = false

	hint_timer = Timer.new()
	hint_timer.name = "HintTimer"
	hint_timer.one_shot = true
	hint_timer.timeout.connect(_on_hint_timer_timeout)
	add_child(hint_timer)

	_setup_action_buttons()
	reset_button.pressed.connect(_on_reset_button_pressed)
	_update_all_action_displays()

func _setup_action_buttons():
	for child in action_list.get_children():
		if child is HBoxContainer:
			var remap_button = _find_remap_button(child)
			if remap_button:
				var action_name = _get_action_from_hbox(child.name)
				if action_name != "":
					action_buttons[action_name] = remap_button
					remap_button.pressed.connect(_on_action_remap_button_pressed.bind(action_name))

func _find_remap_button(hbox: HBoxContainer) -> TextureButton:
	for child in hbox.get_children():
		if child is TextureButton and child.name.contains("Remap"):
			return child
	return null

func _get_action_from_hbox(hbox_name: String) -> String:
	var action_map = {
		"JumpAction": "jump",
		"DashAction": "dash",
		"LeftAction": "left",
		"RightAction": "right",
		"UpAction": "up",
		"DownAction": "down",
		"SuperDashAction": "super_dash",
		"InteractiveAction": "interactive",
		"DialogueNextAction": "dialogue_next",
		"MapAction": "map"
	}
	return action_map.get(hbox_name, "")

func _on_action_remap_button_pressed(action: String):
	AudioManager.play_button_click_sfx()
	if InputMapManager.is_remapping():
		InputMapManager.switch_remap_action(action)
		show_waiting_hint()
		return
	if current_hint_type in ["success", "cancel"]:
		cancel_hint_effects()
	InputMapManager.start_remap_action(action)
	show_waiting_hint()

func _update_all_action_displays():
	for action in action_buttons.keys():
		_update_action_display(action)

func _update_action_display(action: String):
	var hbox_name = _get_hbox_name_from_action(action)
	if hbox_name == "":
		return
	var hbox = action_list.get_node_or_null(hbox_name)
	if not hbox:
		return
	if hbox.get_child_count() >= 2:
		var key_label = hbox.get_child(1)
		if key_label is Label:
			key_label.text = InputMapManager.get_action_key_display(action)

func _get_hbox_name_from_action(action: String) -> String:
	var action_map = {
		"jump": "JumpAction",
		"dash": "DashAction",
		"left": "LeftAction",
		"right": "RightAction",
		"up": "UpAction",
		"down": "DownAction",
		"super_dash": "SuperDashAction",
		"interactive": "InteractiveAction",
		"dialogue_next": "DialogueNextAction",
		"map": "MapAction"
	}
	return action_map.get(action, "")

func show_waiting_hint(text: String = "请按下新的按键... (ESC取消)"):
	cancel_hint_effects()
	controls_hint.text = text
	controls_hint.modulate.a = 1.0
	controls_hint.modulate = Color.WHITE
	controls_hint.visible = true
	current_hint_type = "waiting"

func show_result_hint(text: String, is_success: bool = true):
	cancel_hint_effects()
	controls_hint.text = text
	controls_hint.modulate.a = 1.0
	controls_hint.visible = true
	controls_hint.modulate = Color.GREEN if is_success else Color.YELLOW
	current_hint_type = "success" if is_success else "cancel"
	hint_timer.start(hint_wait_time)

func cancel_hint_effects():
	if hint_timer and hint_timer.time_left > 0:
		hint_timer.stop()
	if hint_tween and hint_tween.is_valid():
		hint_tween.kill()
		hint_tween = null
	controls_hint.modulate = Color.WHITE

func _on_hint_timer_timeout():
	if current_hint_type != "waiting":
		start_hint_fade_out()

func start_hint_fade_out():
	hint_tween = create_tween()
	hint_tween.tween_property(controls_hint, "modulate:a", 0.0, hint_fade_time)
	hint_tween.tween_callback(func():
		if current_hint_type != "waiting":
			controls_hint.visible = false
			controls_hint.modulate.a = 1.0
			current_hint_type = ""
	)

func _input(event):
	if InputMapManager.is_remapping():
		var handled = InputMapManager.handle_remap_input(event)
		if handled:
			get_viewport().set_input_as_handled()
			cancel_hint_effects()
			if event is InputEventKey and event.keycode == KEY_ESCAPE:
				show_result_hint("已取消重新映射", false)
			else:
				_update_all_action_displays()
				show_result_hint("映射成功！", true)

func _process(delta):
	if reset_state == 1:
		reset_timer += delta
		if reset_timer >= reset_hint_show_time:
			var tween = create_tween()
			tween.tween_property(reset_hint_label, "modulate:a", 0.0, reset_hint_fade_time)
			tween.tween_callback(func():
				if reset_state == 1:
					reset_state = 0
					reset_timer = 0.0
					reset_hint_label.visible = false
			)
		if reset_timer >= reset_timeout:
			reset_state = 0
			reset_timer = 0.0
			reset_hint_label.visible = false

func _on_reset_button_pressed():
	AudioManager.play_button_click_sfx()
	if InputMapManager.is_remapping():
		InputMapManager.cancel_remap()
		return
	match reset_state:
		0:
			reset_state = 1
			reset_timer = 0.0
			reset_hint_label.text = "再按一次确认重置"
			reset_hint_label.modulate.a = 1.0
			reset_hint_label.visible = true
		1:
			reset_state = 0
			reset_timer = 0.0
			if InputMapManager.reset_to_default():
				_update_all_action_displays()
				reset_hint_label.text = "已重置为默认设置"
				reset_hint_label.modulate.a = 1.0
				reset_hint_label.visible = true
				var tween = create_tween()
				tween.tween_property(reset_hint_label, "modulate:a", 0.0, 1.0)
				tween.tween_callback(func():
					reset_hint_label.visible = false
				)

func cancel_current_mapping():
	if InputMapManager.is_remapping():
		InputMapManager.cancel_remap()
		show_result_hint("已取消重新映射", false)
	elif current_hint_type in ["success", "cancel"]:
		cancel_hint_effects()
		controls_hint.visible = false
		current_hint_type = ""
