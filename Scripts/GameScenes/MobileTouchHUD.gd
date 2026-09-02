extends CanvasLayer

## 真实的移动端 HUD 控制层
## 作用：
## 1) 仅在游戏中显示虚拟按键；
## 2) 读取 user://mobile_controls_layout.cfg；
## 3) 让虚拟按键真正驱动 InputMap 中的动作；
## 4) 负责淡入淡出和移动端/PC 端分支。

@export_category("移动端真实 HUD")
## 淡入时间，单位：秒。
@export var fade_in_duration: float = 0.5
## 淡出时间，单位：秒。
@export var fade_out_duration: float = 0.5
## 调试用：在 PC 上也打开移动端 HUD 以验证布局和输入。
@export var force_mobile_test_mode: bool = true
## 虚拟按键布局保存路径。
@export var layout_file_path: String = "user://mobile_controls_layout.cfg"
## 摇杆最大拖动半径（像素）。这是实际控制范围，决定摇杆响应跨度。
@export var joystick_radius: float = 96.0
## 摇杆死区：小于此值时不触发方向，避免轻微偏移导致方向抖动。
@export var joystick_deadzone: float = 0.14
## 轴优先分离比：当横向/纵向差异超过此值时，优先按 X 或 Y 轴响应，形成明确的上下左右分区。
@export var joystick_axis_split_ratio: float = 1.35

var _root: Control = null
var _button_map: Dictionary = {}
var _joystick_base: TextureButton = null
var _joystick_thumb: TextureButton = null
var _is_dragging_joystick: bool = false
var _layout_config: Dictionary = {}
var _button_alpha: float = 1.0
var _pressed_buttons: Dictionary = {}
var _move_state: Dictionary = {
	"left": false,
	"right": false,
	"up": false,
	"down": false,
}

func _ready() -> void:
	# 初始化真实 HUD：读取配置、绑定节点、注册输入逻辑。
	add_to_group("mobile_touch_hud")
	_root = get_node_or_null("Root")
	_load_layout_from_disk()
	_bind_virtual_buttons()
	_apply_layout_from_config()
	_set_visible_state(true)
	_set_hud_active_for_mobile_only()

func set_hud_visible(show_state: bool) -> void:
	_set_visible_state(show_state)

func _set_hud_active_for_mobile_only() -> void:
	# 调试期允许 PC 端也启用移动端 HUD，以直接验证布局和输入逻辑。
	visible = force_mobile_test_mode or OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")
	if _root:
		_root.visible = visible

func _get_viewport_size() -> Vector2:
	# CanvasLayer 不直接提供 get_viewport_rect()，因此需要从 Viewport 取可见区域。
	var viewport = get_viewport()
	if viewport == null:
		return Vector2(1280.0, 720.0)
	return viewport.get_visible_rect().size

func _coerce_layout_to_pixels(layout: Dictionary) -> Dictionary:
	# 兼容旧版像素布局和新版百分比布局，统一转换到当前分辨率。
	var viewport_size := _get_viewport_size()
	var result: Dictionary = {}
	for key in layout.keys():
		var value = layout[key]
		if value is Vector2:
			if value.x <= 1.0 and value.y <= 1.0:
				result[key] = Vector2(value.x * viewport_size.x, value.y * viewport_size.y)
			else:
				result[key] = value
		else:
			result[key] = value
	return result

func _collect_scene_positions() -> Dictionary:
	var result: Dictionary = {}
	for key in ["MoveJoystick", "MoveJoystickThumb", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]:
		var target = get_node_or_null("Root/%s" % key)
		if target is Control:
			result[key] = target.position
	return result

func _load_layout_from_disk() -> void:
	# 从配置文件读取最终布局；若没有配置，则保留场景中已放置的节点位置，不覆盖编辑器拖拽结果。
	var config := ConfigFile.new()
	var err := config.load(layout_file_path)
	if err != OK:
		_layout_config = _collect_scene_positions()
		return
	var saved_layout = config.get_value("mobile_controls", "layout", _collect_scene_positions())
	_layout_config = _coerce_layout_to_pixels(saved_layout)
	_button_alpha = clampf(float(config.get_value("mobile_controls", "button_alpha", 1.0)), 0.0, 1.0)

func _signal_has_callable(signal_ref: Signal, target: Callable) -> bool:
	for connection in signal_ref.get_connections():
		if connection.callable == target:
			return true
	return false

func _connect_unique(signal_ref: Signal, target: Callable) -> void:
	if not _signal_has_callable(signal_ref, target):
		signal_ref.connect(target)

func _bind_virtual_buttons() -> void:
	# 绑定当前场景中的真实按键节点；摇杆缩略球也必须接收拖拽输入。
	_button_map.clear()
	_joystick_base = get_node_or_null("Root/MoveJoystick") as TextureButton
	_joystick_thumb = get_node_or_null("Root/MoveJoystickThumb") as TextureButton
	var button_names = ["MoveJoystick", "MoveJoystickThumb", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]
	for button_name in button_names:
		var button = get_node_or_null("Root/%s" % button_name)
		if button and button is TextureButton:
			_button_map[button_name] = button
			button.focus_mode = Control.FOCUS_NONE
			button.mouse_filter = Control.MOUSE_FILTER_STOP
			_connect_unique(button.button_down, _on_button_down.bind(button))
			_connect_unique(button.button_up, _on_button_up.bind(button))
		if button_name == "MoveJoystick" and _joystick_base:
			_connect_unique(_joystick_base.pressed, _on_move_joystick_pressed.bind(_joystick_base))
			_connect_unique(_joystick_base.gui_input, _on_move_joystick_input.bind(_joystick_base))
		if button_name == "MoveJoystickThumb" and _joystick_thumb:
			_connect_unique(_joystick_thumb.gui_input, _on_move_joystick_input.bind(_joystick_thumb))

func _apply_layout_from_config() -> void:
	# 根据配置设置按钮位置。
	for key in _layout_config.keys():
		var target = get_node_or_null("Root/%s" % key)
		if target is Control and _layout_config[key] is Vector2:
			target.position = _layout_config[key]
	if _joystick_thumb and _layout_config.has("MoveJoystickThumb"):
		_joystick_thumb.position = _layout_config["MoveJoystickThumb"]
	for key in ["MoveJoystick", "MoveJoystickThumb", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]:
		var target = get_node_or_null("Root/%s" % key)
		if target is TextureButton:
			target.modulate = Color(1.0, 1.0, 1.0, _button_alpha)

func _default_layout() -> Dictionary:
	# 默认布局来源，和设置页保持一致，并根据当前视口比例进行比例缩放。
	var viewport_size := _get_viewport_size()
	var scale_x := 1.0
	var scale_y := 1.0
	if viewport_size.x > 0.0:
		scale_x = viewport_size.x / 1280.0
	if viewport_size.y > 0.0:
		scale_y = viewport_size.y / 720.0
	return {
		"MoveJoystick": Vector2(120.0 * scale_x, 540.0 * scale_y),
		"MoveJoystickThumb": Vector2(138.0 * scale_x, 558.0 * scale_y),
		"JumpButton": Vector2(1110.0 * scale_x, 500.0 * scale_y),
		"DashButton": Vector2(1180.0 * scale_x, 590.0 * scale_y),
		"InteractButton": Vector2(1035.0 * scale_x, 585.0 * scale_y),
		"SuperDashButton": Vector2(960.0 * scale_x, 610.0 * scale_y),
		"MapButton": Vector2(1160.0 * scale_x, 420.0 * scale_y),
	}

func _set_visible_state(show_state: bool) -> void:
	# 设置 HUD 可见性，并执行淡入淡出。
	if not _root:
		return
	if show_state:
		_root.modulate = Color(1, 1, 1, 0.0)
		_root.visible = true
		var tween = create_tween()
		tween.tween_property(_root, "modulate:a", 1.0, fade_in_duration)
	else:
		var tween = create_tween()
		tween.tween_property(_root, "modulate:a", 0.0, fade_out_duration)
		tween.tween_callback(func():
			_root.visible = false
		)
		_root.visible = false

func _emit_action_event(action_name: String, pressed: bool) -> void:
	# 生成真实的 InputEventAction，让所有使用 event.is_action_pressed() 的逻辑都能收到和键盘/手柄一致的事件。
	var event := InputEventAction.new()
	event.action = action_name
	event.pressed = pressed
	event.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(event)
	if pressed:
		Input.action_press(action_name)
	else:
		Input.action_release(action_name)

func _set_move_action(action_name: String, should_press: bool) -> void:
	# 统一管理方向键按下/抬起状态，并同步派发 InputEventAction，保证 _input(event) 监听也能响应。
	if should_press and not _move_state[action_name]:
		_emit_action_event(action_name, true)
		_move_state[action_name] = true
	elif not should_press and _move_state[action_name]:
		_emit_action_event(action_name, false)
		_move_state[action_name] = false

func _apply_move_vector_from_joystick(vector_offset: Vector2) -> void:
	# 摇杆采用 X 型分区：如果横向明显大于纵向，则只响应左右；反之按上下处理。
	var max_radius: float = maxf(joystick_radius, 18.0)
	var normalized: Vector2 = Vector2.ZERO
	if vector_offset.length() > 0.0001:
		normalized = vector_offset / max_radius
	var abs_x: float = absf(normalized.x)
	var abs_y: float = absf(normalized.y)
	var horizontal_axis: float = 0.0
	var vertical_axis: float = 0.0
	var horizontal_priority: bool = abs_x >= abs_y * joystick_axis_split_ratio
	var vertical_priority: bool = abs_y >= abs_x * joystick_axis_split_ratio
	if abs_x > joystick_deadzone and horizontal_priority:
		horizontal_axis = signf(normalized.x)
	if abs_y > joystick_deadzone and vertical_priority:
		vertical_axis = signf(normalized.y)
	if not horizontal_priority and not vertical_priority:
		if abs_x > joystick_deadzone:
			horizontal_axis = signf(normalized.x)
		if abs_y > joystick_deadzone:
			vertical_axis = signf(normalized.y)
	_set_move_action("left", horizontal_axis < 0.0)
	_set_move_action("right", horizontal_axis > 0.0)
	_set_move_action("up", vertical_axis < 0.0)
	_set_move_action("down", vertical_axis > 0.0)

func _on_button_pressed(button: TextureButton) -> void:
	# 真实按键按下时，更新对应 InputMap 动作状态，并发送真实事件，确保所有 _input(event.is_action_pressed(...)) 都触发。
	var action_name: String = ""
	match button.name:
		"JumpButton":
			action_name = "jump"
		"DashButton":
			action_name = "dash"
		"InteractButton":
			action_name = "interactive"
		"SuperDashButton":
			action_name = "super_dash"
		"MapButton":
			action_name = "map"
		_:
			return
	if _pressed_buttons.get(button.name, false):
		return
	_pressed_buttons[button.name] = true
	_emit_action_event(action_name, true)

func _on_button_down(button: TextureButton) -> void:
	# 只处理按键按下逻辑，不处理布局拖拽。
	_on_button_pressed(button)

func _on_button_up(button: TextureButton) -> void:
	# 按键抬起时释放对应动作，并重置一次性状态。
	var action_name: String = ""
	match button.name:
		"JumpButton":
			action_name = "jump"
		"DashButton":
			action_name = "dash"
		"InteractButton":
			action_name = "interactive"
		"SuperDashButton":
			action_name = "super_dash"
		"MapButton":
			action_name = "map"
		_:
			return
	_pressed_buttons[button.name] = false
	_emit_action_event(action_name, false)

func _on_button_gui_input(event: InputEvent, button: TextureButton) -> void:
	# 真实 HUD 中，按钮本身不参与布局拖拽；同时兼容鼠标桌面端和触屏端。
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_button_down(button)
			else:
				_on_button_up(button)
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_button_down(button)
		else:
			_on_button_up(button)

func _on_move_joystick_pressed(_button: TextureButton) -> void:
	# 处理摇杆按下：开始记录拖拽起点。
	# 不要在这里调用 grab_focus()，因为 TextureButton 默认 focus_mode 通常为 NONE，
	# 这样会触发 "This control can't grab focus" 的脚本警告。
	_is_dragging_joystick = true
	if _joystick_thumb:
		_joystick_thumb.modulate = Color(1, 1, 1, 1.0)

func _update_joystick_from_pointer(pointer_position: Vector2) -> void:
	if _joystick_base == null:
		return
	var center: Vector2 = _joystick_base.position + _joystick_base.size * 0.5
	var vector_offset: Vector2 = pointer_position - center
	var max_radius: float = maxf(joystick_radius, 18.0)
	if vector_offset.length() > max_radius:
		vector_offset = vector_offset.normalized() * max_radius
	if _joystick_thumb:
		_joystick_thumb.position = center + vector_offset - _joystick_thumb.size * 0.5
	_apply_move_vector_from_joystick(vector_offset)

func _end_joystick_drag() -> void:
	_is_dragging_joystick = false
	if _joystick_thumb:
		_joystick_thumb.position = _joystick_base.position + (_joystick_base.size * 0.5 - _joystick_thumb.size * 0.5)
	_set_move_action("left", false)
	_set_move_action("right", false)
	_set_move_action("up", false)
	_set_move_action("down", false)

func _on_move_joystick_input(event: InputEvent, _button: TextureButton) -> void:
	# 处理摇杆拖动，映射到 left/right/up/down 动作。兼容鼠标拖拽和屏幕拖拽。
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_is_dragging_joystick = true
			else:
				_end_joystick_drag()
		return
	if not _is_dragging_joystick:
		return
	if event is InputEventMouseMotion:
		_update_joystick_from_pointer(_root.get_local_mouse_position())
		return
	if event is InputEventScreenDrag:
		_update_joystick_from_pointer(event.position)
		return
	if event is InputEventScreenTouch and not event.pressed:
		_end_joystick_drag()

func apply_layout_config(config: Dictionary) -> void:
	# 外部调用入口：允许其他脚本重置布局。
	if config.has("layout"):
		_layout_config = config["layout"]
		_apply_layout_from_config()

func get_layout_config() -> Dictionary:
	# 外部读取入口：返回当前布局。
	return _layout_config

func reload_layout() -> void:
	# 外部调用入口：重新从磁盘读取布局/透明度并立即应用。
	# 供设置页的移动端布局编辑器在保存/重置后调用，使改动在游戏内即时生效，无需重进存档。
	_load_layout_from_disk()
	_apply_layout_from_config()
