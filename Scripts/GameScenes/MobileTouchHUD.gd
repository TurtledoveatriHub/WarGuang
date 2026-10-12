extends CanvasLayer

## 真实的移动端 HUD 控制层
## 作用：
## 1) 仅在游戏中显示虚拟按键；
## 2) 读取 user://mobile_controls_layout.cfg；
## 3) 让虚拟按键真正驱动 InputMap 中的动作；
## 4) 负责淡入淡出和移动端/PC 端分支。

@export_category("移动端真实 HUD")
## 淡入时间，单位：秒。
@export var fade_in_duration: float = 0.4
## 淡出时间，单位：秒。
@export var fade_out_duration: float = 0.4
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
@export var joystick_radius: float = 96.0
## 摇杆死区：小于此值时不触发方向，避免轻微偏移导致方向抖动。
@export var joystick_deadzone: float = 0.14
## 轴优先分离比：当横向/纵向差异超过此值时，优先按 X 或 Y 轴响应，形成明确的上下左右分区。
## 轴向判定系数：|y| ≥ |x| × ratio 才算“上下”优先，|x| ≥ |y| × ratio 才算“左右”优先
@export var joystick_axis_split_ratio: float = 1.6

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
	# 传送面板 / 游戏内设置面板会把 get_tree().paused 设为 true；HUD 必须继续处理输入，
	# 否则暂停期间触摸事件收不到：交互键的「按下/抬起」丢失 → 面板无法用交互键关闭，
	# 同时 _pressed_buttons 会残留为 true，使该按键（及其它按键）看起来永久失效。
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("mobile_touch_hud")
	_root = get_node_or_null("Root")
	if _root != null:
		# 全屏容器必须 IGNORE：它只是摆放虚拟按键的坐标系。
		# 否则它会吃掉屏幕上的所有点击/触摸，对话框（继续/选项）就点不动了。
		# 真正的按键在 _bind_virtual_buttons() 里也是 IGNORE，由本脚本自己按触摸 index 分发。
		_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
			# 可点击/可抓取矩形必须等于实际画出的纹理大小，否则手指按在纹理上却落在矩形外。
			_normalize_button_rect(button)
	if _joystick_base:
		_joystick_group.append(_joystick_base)
	if _joystick_thumb:
		_joystick_group.append(_joystick_thumb)
	for key in ["DpadUp", "DpadDown", "DpadLeft", "DpadRight"]:
		if _button_map.has(key):
			_dpad_group.append(_button_map[key])

func _normalize_button_rect(button: TextureButton) -> void:
	# 矩形 = 纹理尺寸，pivot = 中心，且移动后视觉中心不变。
	if button == null or button.texture_normal == null:
		return
	var tex_size: Vector2 = button.texture_normal.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	if button.size.is_equal_approx(tex_size):
		return
	var old_center: Vector2 = button.position + button.size * 0.5
	button.custom_minimum_size = tex_size
	button.size = tex_size
	button.position = old_center - tex_size * 0.5
	button.pivot_offset = tex_size * 0.5


func _apply_layout_from_config(animate_mode: bool = false) -> void:
	# 根据配置设置按钮位置。
	for key in _layout_config.keys():
		var target = get_node_or_null("Root/%s" % key)
		if target is Control and _layout_config[key] is Vector2:
			target.position = _layout_config[key]
	if _joystick_thumb and _layout_config.has("MoveJoystickThumb"):
		_joystick_thumb.position = _layout_config["MoveJoystickThumb"]
	# 摇杆球必须与基座同心（摇杆只能整体移动；存档里可能残留旧偏移值）。
	if _joystick_base != null and _joystick_thumb != null:
		var base_center: Vector2 = _joystick_base.position + _joystick_base.size * 0.5
		_joystick_thumb.position = base_center - _joystick_thumb.size * 0.5
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

## 摇杆抓取半径倍率：抓取圈 = joystick_radius × 本值（以摇杆中心为圆心）。
## 按下圈内任意位置会立刻把拖动球吸到按下点并可继续拖拽；1.0 = 与摇杆半径完全一致。
@export var joystick_grab_radius_multiplier: float = 1.5

## 真机输入诊断日志（默认关闭，关闭时不产生任何 IO / 打印）。
## 用途：只在真机触摸设备上出现、桌面注入事件无法复现的问题（例如「先按交互，再按跳跃+移动，
## 跳跃变短按且后续按键失灵」）。打开后每个触摸/拖拽事件与 HUD 的处置结果会写入
## user://hud_input_log.txt（同时打印到控制台）。复现一次后把该文件给我即可定位。
@export var log_input_diagnostics: bool = false

var _diag_file: FileAccess = null

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
	# 斜向区（既不是横向优先也不是纵向优先）：记录本帧状态，供冲刺方向判定优先取左右。
	# PC 键盘不会走到这里，所以不影响键盘上「上+左」同时按住的上下冲刺。
	if Global != null:
		Global.joystick_diagonal_horizontal_bias = (
			not horizontal_priority and not vertical_priority
			and normalized.length() > joystick_deadzone
		)
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
	# 树被暂停 = 有全屏面板（游戏内设置 / 传送面板等）正在接管交互。
	# 本 HUD 此时仍要继续处理（PROCESS_MODE_ALWAYS，供面板期间按交互键），
	# 但**绝不能吞事件**：吞掉鼠标「按下」会让面板按钮点一次只显示悬停、要按两次，
	# 也让设置页里的虚拟按键完全拖不动（鼠标移动不会被吞，所以只表现为悬停）。
	var paused: bool = get_tree() != null and get_tree().paused
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		var local: Vector2 = _to_root_local(t.position)
		if t.pressed:
			var consumed: bool = _begin_pointer(t.index, local, false)
			_diag("touch_down idx=%d pos=%s local=%s consumed=%s joy=%s/%d buttons=%s" % [
				t.index, str(t.position), str(local), str(consumed),
				str(_is_dragging_joystick), _joystick_touch_index, str(_button_touch_index.keys())])
			if consumed and not paused:
				get_viewport().set_input_as_handled()
		else:
			_diag("touch_up   idx=%d before=%s" % [t.index, str(_button_touch_index.keys())])
			_end_pointer(t.index, false)
			_diag("touch_up   idx=%d after=%s joy=%s/%d" % [
				t.index, str(_button_touch_index.keys()),
				str(_is_dragging_joystick), _joystick_touch_index])
		return
	if event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		if _is_dragging_joystick and not _joystick_by_mouse and d.index == _joystick_touch_index:
			_update_joystick_from_pointer(_to_root_local(d.position))
			if not paused:
				get_viewport().set_input_as_handled()
		else:
			_diag("drag_skip  idx=%d joy=%s/%d by_mouse=%s" % [
				d.index, str(_is_dragging_joystick), _joystick_touch_index, str(_joystick_by_mouse)])
		return
	# 触摸平台上忽略「由触摸合成出来的鼠标事件」：
	# emulate_mouse_from_touch 会让每次触摸额外产生一个 index = -1 的鼠标事件，
	# 同一根手指因此被记成两份（实测 _button_touch_index 里 -1 与触摸 index 绑在同一按键上，
	# 摇杆也会被这一路抢走拖动权）。手机端只认真实触摸事件。
	if _is_touch_platform():
		if event is InputEventMouseButton:
			_diag("mouse_skip idx=-1 pos=%s pressed=%s (触摸平台忽略合成鼠标)" % [
				str((event as InputEventMouseButton).position), str((event as InputEventMouseButton).pressed)])
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _begin_pointer(-1, _to_root_local(mb.position), true) and not paused:
					get_viewport().set_input_as_handled()
			else:
				_end_pointer(-1, true)
		return
	if event is InputEventMouseMotion and _is_dragging_joystick and _joystick_by_mouse:
		_update_joystick_from_pointer(_to_root_local((event as InputEventMouseMotion).position))


## 是否是触摸平台（手机 / 平板）。PC 上仅在 force_mobile_test_mode 时启用 HUD，
## 那种调试场景仍需要鼠标事件，所以这里按平台判断而不是按「HUD 是否可见」判断。
func _is_touch_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")


## 写一行输入诊断日志（仅在 log_input_diagnostics 打开时生效）。
func _diag(line: String) -> void:
	if not log_input_diagnostics:
		return
	if _diag_file == null:
		_diag_file = FileAccess.open("user://hud_input_log.txt", FileAccess.WRITE)
		if _diag_file == null:
			return
		_diag_file.store_line("=== MobileTouchHUD input diagnostics ===")
	if _diag_file != null:
		_diag_file.store_line("%d %s" % [Time.get_ticks_msec(), line])
		_diag_file.flush()
	print("[HUDIO] ", line)


## 统一的“指针落下”分发：返回 true 表示本 HUD 已消费（摇杆或某按键）。
func _begin_pointer(touch_index: int, local: Vector2, is_mouse: bool) -> bool:
	if _move_mode == 0 and not _is_dragging_joystick and _point_in_joystick_grab(local):
		_is_dragging_joystick = true
		_joystick_by_mouse = is_mouse
		_joystick_touch_index = touch_index
		_set_joystick_pressed_visual(true)
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
	var grab_r: float = maxf(joystick_radius, 18.0) * maxf(joystick_grab_radius_multiplier, 1.0)
	var rect: Rect2 = _joystick_base.get_global_rect()
	grab_r = maxf(grab_r, maxf(rect.size.x, rect.size.y) * 0.5)
	return center.distance_to(local) <= grab_r


func _try_press_button_at(touch_index: int, local: Vector2) -> bool:
	# 原逻辑：同一指位已经有绑定就直接放弃（不做多点重绑定）。
	if _button_touch_index.has(touch_index):
		return false
	for key in _button_map.keys():
		var button: TextureButton = _button_map[key] as TextureButton
		if button == null or not is_instance_valid(button) or not button.visible:
			continue
		# 摇杆本体/拖动球由 _begin_pointer 里的摇杆分支处理，不能当普通按键。
		if _joystick_group.has(button):
			continue
		if _control_rect_in_root(button).has_point(local):
			_button_touch_index[touch_index] = button
			_press_button(button)
			return true
	return false


func _press_button(button: TextureButton) -> void:
	# TextureButton 只有在「toggle_mode + button_pressed」时才会画 texture_pressed；
	# 本 HUD 的按键是 MOUSE_FILTER_IGNORE，引擎永远不会给它们置按下态，
	# 所以必须在这里自己置位，否则按下去只看到 modulate 明暗变化、没有按下贴图。
	button.toggle_mode = true
	button.button_pressed = true
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
	button.button_pressed = false
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
## 只按「基准 × 倍率」写一次，绝不从当前 scale 反推（否则倍率会层层累积）。
func _apply_button_visuals() -> void:
	for key in _base_scales.keys():
		var b: TextureButton = _button_map.get(key, null) as TextureButton
		if b == null or not is_instance_valid(b):
			continue
		# 以按键自身中心为缩放基准（而不是左上角）。
		b.pivot_offset = b.size * 0.5
		b.scale = _base_scales[key] * _button_scale
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
	_set_joystick_pressed_visual(false)
	_button_touch_index.clear()
	_set_move_action("left", false)
	_set_move_action("right", false)
	_set_move_action("up", false)
	_set_move_action("down", false)
	if _joystick_base and _joystick_thumb:
		var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
		_joystick_thumb.position = center - _joystick_thumb.size * 0.5


## 摇杆整体的「按下态」贴图：底座与拖动球都是 TextureButton，
## 只有 toggle_mode + button_pressed 才会画 texture_pressed（本 HUD 的按键全是
## MOUSE_FILTER_IGNORE，引擎永远不会给它们置位，必须自己置）。
func _set_joystick_pressed_visual(pressed: bool) -> void:
	for entry in _joystick_group:
		var button: TextureButton = entry as TextureButton
		if button == null or not is_instance_valid(button):
			continue
		button.toggle_mode = true
		button.button_pressed = pressed


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
	_set_joystick_pressed_visual(false)
	if _joystick_base and _joystick_thumb:
		var center: Vector2 = _to_root_local(_joystick_base.get_global_rect().get_center())
		_joystick_thumb.position = center - _joystick_thumb.size * 0.5
		_joystick_thumb.modulate = Color(1, 1, 1, _button_alpha)
	_set_move_action("left", false)
	_set_move_action("right", false)
	_set_move_action("up", false)
	_set_move_action("down", false)

func reload_layout() -> void:
	# 外部调用入口：重新从磁盘读取布局/透明度/大小/移动方案并立即应用。
	# 供设置页的移动端布局编辑器在保存/重置后调用，使改动在游戏内即时生效，无需重进存档。
	# 注意：游戏内设置面板打开时树是暂停的（本节点不是 PROCESS_MODE_ALWAYS），
	# 带动画的切换会卡在暂停里 —— 这种情况改用直接应用，保证回到面板背景时已经是新布局。
	_load_layout_from_disk()
	_apply_layout_from_config(get_tree() != null and not get_tree().paused)
