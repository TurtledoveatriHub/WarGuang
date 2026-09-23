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
## 移动方案切换（摇杆 ↔ 十字键）时的淡入淡出时长，单位：秒。
@export var move_mode_fade_duration: float = 0.25
## 调试用：在 PC 上也打开移动端 HUD 以验证布局和输入。
@export var force_mobile_test_mode: bool = false
## 虚拟按键布局保存路径。
@export var layout_file_path: String = "user://mobile_controls_layout.cfg"

## 勾选后：运行时忽略 user:// 保存的布局，始终使用**本场景（MainGameScene/MobileTouchHUD）
## 编辑器里摆放的节点位置**。透明度 / 大小 / 移动方案仍从配置文件读取。
## 用途：当你想“直接在编辑器里摆 HUD 位置”，不希望被设置页保存的布局覆盖时打开。
@export var use_scene_layout_only: bool = false
## 摇杆最大拖动半径（像素）。这是实际控制范围，决定摇杆响应跨度。
@export var joystick_radius: float = 72.0
## 摇杆死区：小于此值时不触发方向，避免轻微偏移导致方向抖动。
@export var joystick_deadzone: float = 0.14
## 轴优先分离比：当横向/纵向差异超过此值时，优先按 X 或 Y 轴响应，形成明确的上下左右分区。
@export var joystick_axis_split_ratio: float = 1.8

var _root: Control = null
var _button_map: Dictionary = {}
var _joystick_base: TextureButton = null
var _joystick_thumb: TextureButton = null
var _is_dragging_joystick: bool = false
var _layout_config: Dictionary = {}
var _button_alpha: float = 1.0
## 虚拟按键统一大小倍率（0.5~2.0，来自配置文件）。
var _button_scale: float = 1.0
## 移动方案：0=摇杆，1=十字键（来自配置文件）。
var _move_mode: int = 0
## 每个虚拟按键在编辑器中放置的原始 scale（应用大小倍率前）。
var _base_scales: Dictionary = {}
## 摇杆方案的节点组（底座+拖动球）。
var _joystick_group: Array = []
## 十字键方案的节点组（上下左右）。
var _dpad_group: Array = []
var _move_mode_tween: Tween = null
var _pressed_buttons: Dictionary = {}
var _move_state: Dictionary = {
	"left": false,
	"right": false,
	"up": false,
	"down": false,
}
## 正在拖动摇杆的那根触摸的 index（鼠标拖动时为 -1；-1 也用作“无触摸”哨兵）。
var _joystick_touch_index: int = -1
## 摇杆当前是否由鼠标拖动（桌面/调试用）。
var _joystick_by_mouse: bool = false
## 触摸 index → 正在按住的按钮节点（支持多点同时按不同按钮）。
var _button_touch_index: Dictionary = {}

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
	# 注意：这里也必须包含十字键四个节点，否则“以编辑器为准”时它们不会回到场景摆放位置。
	for key in ["MoveJoystick", "MoveJoystickThumb", "DpadUp", "DpadDown", "DpadLeft", "DpadRight", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]:
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
	if use_scene_layout_only:
		# 显式选择“以本场景编辑器摆放为准”，忽略设置页保存到 user:// 的布局。
		_layout_config = _collect_scene_positions()
	else:
		_layout_config = _coerce_layout_to_pixels(saved_layout)
	_button_alpha = clampf(float(config.get_value("mobile_controls", "button_alpha", 1.0)), 0.0, 1.0)
	_button_scale = clampf(float(config.get_value("mobile_controls", "button_scale", 1.0)), 0.5, 2.0)
	_move_mode = int(config.get_value("mobile_controls", "move_mode", 0))
	if _move_mode != 1:
		_move_mode = 0

func _signal_has_callable(signal_ref: Signal, target: Callable) -> bool:
	for connection in signal_ref.get_connections():
		if connection.callable == target:
			return true
	return false

func _connect_unique(signal_ref: Signal, target: Callable) -> void:
	if not _signal_has_callable(signal_ref, target):
		signal_ref.connect(target)

func _bind_virtual_buttons() -> void:
	# 绑定节点引用。所有按键/摇杆由本脚本在 _input 里按“触摸 index”分别跟踪处理，
	# 因此这里把所有控件设为 MOUSE_FILTER_IGNORE，避免引擎 GUI 的焦点/单指抢占，
	# 从而支持“摇杆/十字键 + 跳跃”等多点同时操作。
	_button_map.clear()
	_base_scales.clear()
	_joystick_group.clear()
	_dpad_group.clear()
	_joystick_base = get_node_or_null("Root/MoveJoystick") as TextureButton
	_joystick_thumb = get_node_or_null("Root/MoveJoystickThumb") as TextureButton
	var button_names = ["MoveJoystick", "MoveJoystickThumb", "DpadUp", "DpadDown", "DpadLeft", "DpadRight", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]
	for button_name in button_names:
		var button = get_node_or_null("Root/%s" % button_name)
		if button and button is TextureButton:
			_button_map[button_name] = button
			_base_scales[button_name] = button.scale
			button.focus_mode = Control.FOCUS_NONE
			button.mouse_filter = Control.MOUSE_FILTER_IGNORE
			# 像素美术：强制最近邻采样，避免缩放时像素块被插值糊掉。
			button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if _joystick_base:
		_joystick_group.append(_joystick_base)
	if _joystick_thumb:
		_joystick_group.append(_joystick_thumb)
	for key in ["DpadUp", "DpadDown", "DpadLeft", "DpadRight"]:
		if _button_map.has(key):
			_dpad_group.append(_button_map[key])

func _apply_layout_from_config(animate_mode: bool = false) -> void:
	# 根据配置设置按钮位置。
	for key in _layout_config.keys():
		var target = get_node_or_null("Root/%s" % key)
		if target is Control and _layout_config[key] is Vector2:
			target.position = _layout_config[key]
	if _joystick_thumb and _layout_config.has("MoveJoystickThumb"):
		_joystick_thumb.position = _layout_config["MoveJoystickThumb"]
	# 统一应用不透明度 + 大小，并按当前移动方案切换摇杆/十字键。
	_apply_move_mode(animate_mode)

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

func _input(event: InputEvent) -> void:
	if _root == null or not _root.visible:
		return
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			if _begin_pointer(t.index, _to_root_local(t.position), false):
				get_viewport().set_input_as_handled()
		else:
			_end_pointer(t.index, false)
		return
	if event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		if _is_dragging_joystick and not _joystick_by_mouse and d.index == _joystick_touch_index:
			_update_joystick_from_pointer(_to_root_local(d.position))
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _begin_pointer(-1, _to_root_local(mb.position), true):
					get_viewport().set_input_as_handled()
			else:
				_end_pointer(-1, true)
		return
	if event is InputEventMouseMotion and _is_dragging_joystick and _joystick_by_mouse:
		_update_joystick_from_pointer(_to_root_local((event as InputEventMouseMotion).position))


## 统一的“指针落下”分发：返回 true 表示本 HUD 已消费（摇杆或某按键）。
func _begin_pointer(touch_index: int, local: Vector2, is_mouse: bool) -> bool:
	if _move_mode == 0 and not _is_dragging_joystick and _point_in_joystick_grab(local):
		_is_dragging_joystick = true
		_joystick_by_mouse = is_mouse
		_joystick_touch_index = touch_index
		if _joystick_thumb:
			_joystick_thumb.modulate = Color(1, 1, 1, 1.0)
		_update_joystick_from_pointer(local)
		return true
	return _try_press_button_at(touch_index, local)


## 统一的“指针抬起”处理。
func _end_pointer(touch_index: int, is_mouse: bool) -> void:
	if _is_dragging_joystick:
		if (is_mouse and _joystick_by_mouse) or (not is_mouse and touch_index == _joystick_touch_index):
			_end_joystick_drag()
			_joystick_by_mouse = false
			_joystick_touch_index = -1
			return
	if _button_touch_index.has(touch_index):
		var button: TextureButton = _button_touch_index[touch_index]
		_button_touch_index.erase(touch_index)
		_release_button(button)


func _point_in_joystick_grab(local: Vector2) -> bool:
	if _joystick_base == null:
		return false
	var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
	var grab_r: float = maxf(joystick_radius, 18.0)
	var rect: Rect2 = _joystick_base.get_global_rect()
	grab_r = maxf(grab_r, maxf(rect.size.x, rect.size.y) * 0.5 + 24.0)
	return center.distance_to(local) <= grab_r


func _try_press_button_at(touch_index: int, local: Vector2) -> bool:
	if _button_touch_index.has(touch_index):
		return false
	var names: Array = ["JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]
	if _move_mode == 1:
		names = ["DpadUp", "DpadDown", "DpadLeft", "DpadRight"] + names
	for button_name in names:
		var button: TextureButton = _button_map.get(button_name, null) as TextureButton
		if button == null or not is_instance_valid(button) or not button.visible:
			continue
		if _control_rect_in_root(button).has_point(local):
			_button_touch_index[touch_index] = button
			_press_button(button)
			return true
	return false


func _press_button(button: TextureButton) -> void:
	var move_action: String = _move_action_for_button(button)
	if move_action != "":
		if _pressed_buttons.get(button.name, false):
			return
		_pressed_buttons[button.name] = true
		_set_move_action(move_action, true)
		button.modulate = Color(1, 1, 1, maxf(_button_alpha * 0.55, 0.15))
		return
	var action_name: String = _action_name_for_button(button)
	if action_name == "":
		return
	if _pressed_buttons.get(button.name, false):
		return
	_pressed_buttons[button.name] = true
	_emit_action_event(action_name, true)
	button.modulate = Color(1, 1, 1, maxf(_button_alpha * 0.55, 0.15))


func _release_button(button: TextureButton) -> void:
	var move_action: String = _move_action_for_button(button)
	if move_action != "":
		_pressed_buttons[button.name] = false
		_set_move_action(move_action, false)
		button.modulate = Color(1, 1, 1, _button_alpha)
		return
	var action_name: String = _action_name_for_button(button)
	if action_name == "":
		return
	_pressed_buttons[button.name] = false
	_emit_action_event(action_name, false)
	button.modulate = Color(1, 1, 1, _button_alpha)


## 十字键按钮 → 移动动作；非十字键返回空字符串。
func _move_action_for_button(button: TextureButton) -> String:
	match button.name:
		"DpadLeft":
			return "left"
		"DpadRight":
			return "right"
		"DpadUp":
			return "up"
		"DpadDown":
			return "down"
	return ""


## 统一应用所有虚拟按键的大小倍率与不透明度（含被禁用的那一组）。
func _apply_button_visuals() -> void:
	for key in _button_map.keys():
		var b: TextureButton = _button_map[key] as TextureButton
		if b == null or not is_instance_valid(b):
			continue
		var base: Vector2 = _base_scales.get(key, b.scale)
		# 以按键自身中心为缩放基准（而不是左上角）。
		b.pivot_offset = b.size * 0.5
		b.scale = base * _button_scale
		b.modulate = Color(1.0, 1.0, 1.0, _button_alpha)


func _set_group_visible(group: Array, visible_value: bool) -> void:
	for b in group:
		if is_instance_valid(b):
			b.visible = visible_value


func _set_group_alpha(group: Array, alpha_value: float) -> void:
	for b in group:
		if is_instance_valid(b):
			b.modulate.a = alpha_value


## 应用当前移动方案：animated=true 时旧组淡出禁用、新组在其位置淡入。
func _apply_move_mode(animated: bool = true) -> void:
	_apply_button_visuals()
	var show_dpad: bool = _move_mode == 1
	if not animated:
		_set_group_visible(_joystick_group, not show_dpad)
		_set_group_visible(_dpad_group, show_dpad)
		_set_group_alpha(_joystick_group, _button_alpha if not show_dpad else 0.0)
		_set_group_alpha(_dpad_group, _button_alpha if show_dpad else 0.0)
		return
	_animate_move_mode_switch(show_dpad)


func _animate_move_mode_switch(show_dpad: bool) -> void:
	_release_move_actions()
	if _move_mode_tween and _move_mode_tween.is_valid():
		_move_mode_tween.kill()
	var out_group: Array = _dpad_group if not show_dpad else _joystick_group
	var in_group: Array = _joystick_group if not show_dpad else _dpad_group
	var dur: float = maxf(move_mode_fade_duration, 0.01)
	# 新组先就位隐藏，避免与旧组同时出现。
	_set_group_visible(in_group, true)
	_set_group_alpha(in_group, 0.0)
	_move_mode_tween = create_tween()
	var first := true
	for b in out_group:
		if not is_instance_valid(b):
			continue
		if first:
			_move_mode_tween.tween_property(b, "modulate:a", 0.0, dur)
			first = false
		else:
			_move_mode_tween.parallel().tween_property(b, "modulate:a", 0.0, dur)
	_move_mode_tween.tween_callback(func():
		_set_group_visible(out_group, false)
	)
	first = true
	for b in in_group:
		if not is_instance_valid(b):
			continue
		if first:
			_move_mode_tween.tween_property(b, "modulate:a", _button_alpha, dur)
			first = false
		else:
			_move_mode_tween.parallel().tween_property(b, "modulate:a", _button_alpha, dur)


## 释放所有移动输入与拖动状态（切换方案/失去焦点时用）。
func _release_move_actions() -> void:
	_is_dragging_joystick = false
	_joystick_by_mouse = false
	_joystick_touch_index = -1
	_button_touch_index.clear()
	_set_move_action("left", false)
	_set_move_action("right", false)
	_set_move_action("up", false)
	_set_move_action("down", false)
	if _joystick_base and _joystick_thumb:
		var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
		_joystick_thumb.position = center - _joystick_thumb.size * 0.5


func _action_name_for_button(button: TextureButton) -> String:
	match button.name:
		"JumpButton":
			return "jump"
		"DashButton":
			return "dash"
		"InteractButton":
			return "interactive"
		"SuperDashButton":
			return "super_dash"
		"MapButton":
			return "map"
	return ""


func _to_root_local(point: Vector2) -> Vector2:
	if _root == null:
		return point
	return _root.get_global_transform_with_canvas().affine_inverse() * point


func _control_rect_in_root(control: Control) -> Rect2:
	var global_rect: Rect2 = control.get_global_rect()
	if _root == null:
		return global_rect
	var xform := _root.get_global_transform_with_canvas().affine_inverse()
	var top_left := xform * global_rect.position
	var bottom_right := xform * (global_rect.position + global_rect.size)
	return Rect2(top_left, bottom_right - top_left)


func _update_joystick_from_pointer(local: Vector2) -> void:
	if _joystick_base == null:
		return
	# 关键：以“实际渲染矩形（含 scale/父变换）”的中心为基准，坐标统一换算到 Root 局部。
	var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
	var vector_offset: Vector2 = local - center
	var max_radius: float = maxf(joystick_radius, 18.0)
	if vector_offset.length() > max_radius:
		vector_offset = vector_offset.normalized() * max_radius
	if _joystick_thumb:
		# 使用中心 pivot 缩放时，视觉中心 = position + size/2，所以用 size 计算居中。
		_joystick_thumb.position = center + vector_offset - _joystick_thumb.size * 0.5
	_apply_move_vector_from_joystick(vector_offset)


func _end_joystick_drag() -> void:
	_is_dragging_joystick = false
	if _joystick_base and _joystick_thumb:
		var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
		_joystick_thumb.position = center - _joystick_thumb.size * 0.5
		_joystick_thumb.modulate = Color(1, 1, 1, _button_alpha)
	_set_move_action("left", false)
	_set_move_action("right", false)
	_set_move_action("up", false)
	_set_move_action("down", false)

func apply_layout_config(config: Dictionary) -> void:
	# 外部调用入口：允许其他脚本重置布局。
	if config.has("layout"):
		_layout_config = config["layout"]
		_apply_layout_from_config()

func get_layout_config() -> Dictionary:
	# 外部读取入口：返回当前布局。
	return _layout_config

func reload_layout() -> void:
	# 外部调用入口：重新从磁盘读取布局/透明度/大小/移动方案并立即应用。
	# 供设置页的移动端布局编辑器在保存/重置后调用，使改动在游戏内即时生效，无需重进存档。
	_load_layout_from_disk()
	_apply_layout_from_config(true)
