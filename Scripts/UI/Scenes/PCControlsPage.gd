extends Node2D
class_name PCControlsPage

## PC 端按键设置页
var action_list: VBoxContainer = null
var controls_hint: Label = null
var reset_button: TextureButton = null
var reset_hint_label: Label = null

var action_buttons = {}

var reset_state: int = 0
var reset_timer: float = 0.0
## 重置提示显示持续时间，单位：秒。
@export var reset_hint_show_time: float = 1.5
## 重置提示淡出时间，单位：秒。
@export var reset_hint_fade_time: float = 0.5
## 重置操作超时时间，单位：秒。
@export var reset_timeout: float = 2.0

## 等待按键提示显示时间，单位：秒。
@export var hint_wait_time: float = 0.5
## 提示淡出时间，单位：秒。
@export var hint_fade_time: float = 0.5
var current_hint_type: String = ""
var hint_timer: Timer = null
var hint_tween: Tween = null

func _ready():
	action_list = get_node_or_null("ActionList")
	if action_list == null:
		action_list = _find_node_by_suffix(self, "ActionList") as VBoxContainer

	var controls_hint_node = _find_node_by_suffix(self, "ControlsHint")
	var reset_hint_node = _find_node_by_suffix(self, "ResetHintLabel")
	var reset_button_node = _find_node_by_suffix(self, "ResetButton")
	if controls_hint_node is Label:
		controls_hint = controls_hint_node
	if reset_hint_node is Label:
		reset_hint_label = reset_hint_node
	if reset_button_node is TextureButton:
		reset_button = reset_button_node

	if controls_hint:
		controls_hint.visible = false
	if reset_hint_label:
		reset_hint_label.visible = false

	if action_list == null:
		push_warning("PCControlsPage: ActionList not found, controls page cannot initialize.")
		return

	hint_timer = Timer.new()
	hint_timer.name = "HintTimer"
	hint_timer.one_shot = true
	hint_timer.timeout.connect(_on_hint_timer_timeout)
	add_child(hint_timer)

	_setup_action_buttons()
	if reset_button:
		reset_button.pressed.connect(_on_reset_button_pressed)
	_update_all_action_displays()

func _setup_action_buttons():
	for child in action_list.get_children():
		if child is HBoxContainer:
			var remap_button = _find_remap_button(child)
			if remap_button:
				var action_name: String = _get_action_from_hbox(child.name)
				if action_name != "":
					action_buttons[action_name] = remap_button
					remap_button.pressed.connect(_on_action_remap_button_pressed.bind(action_name))

func _find_remap_button(hbox: HBoxContainer) -> TextureButton:
	for child in hbox.get_children():
		if child is TextureButton and child.name.contains("Remap"):
			return child
	return null

func _find_node_by_suffix(node: Node, suffix: String) -> Node:
	if node == null:
		return null
	if node.name.contains(suffix):
		return node
	for child in node.get_children():
		var found = _find_node_by_suffix(child, suffix)
		if found != null:
			return found
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
	for action_suffix in action_map.keys():
		if hbox_name.ends_with(action_suffix):
			return action_map[action_suffix]
	return ""

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
	var hbox_suffix: String = _get_hbox_name_from_action(action)
	if hbox_suffix == "":
		return
	var hbox: Node = _find_node_by_suffix(action_list, hbox_suffix)
	if hbox == null:
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
