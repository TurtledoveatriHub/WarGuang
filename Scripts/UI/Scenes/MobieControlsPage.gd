extends Node2D
class_name MobieControlsPage

## 移动端控制布局编辑页
## 设计目标：
## 1) 仅用于编辑虚拟按键布局，不负责实际游戏输入；
## 2) 允许拖拽虚拟按键并保存到配置文件；
## 3) 允许在编辑器中直接放置初始位置，运行时再覆盖；
## 4) 允许绑定真实纹理，并且在菜单/游戏场景中的显示时机分离。

## 外部变量
@export_category("移动端控制布局编辑")
## 淡入时间，单位：秒。
@export var fade_in_duration: float = 0.5
## 淡出时间，单位：秒。
@export var fade_out_duration: float = 0.5
## 可拖拽布局区域的最大范围，通常与分辨率一致。
@export var layout_bounds: Vector2 = Vector2(1280.0, 720.0)
## 虚拟按键统一透明度：0=完全透明, 1=完全不透明。
@export_range(0.0, 1.0, 0.01) var default_button_alpha: float = 1.0

## 内部变量
signal layout_saved_and_closed

var _layout_config_path: String = "user://mobile_controls_layout.cfg"
var _layout_editing: bool = false
var _dragging_button: TextureButton = null
var _joystick_base: TextureButton = null
var _joystick_thumb: TextureButton = null
var _action_buttons: Dictionary = {}
var _default_button_positions: Dictionary = {}
var _editor_default_positions: Dictionary = {}
var _edit_layout_button: TextureButton = null
var _save_close_button: TextureButton = null
var _reset_layout_button: TextureButton = null
var _button_alpha_slider: HSlider = null
## 编辑态时实际控制显隐的节点：滑块被包在 VirtualButtonAlphaLabel 内时为该 Label，否则为滑块自身
var _button_alpha_label: CanvasItem = null
var _alpha_display_control: CanvasItem = null
var _controls_root: Node2D = null
var _layout_overlay_sprite: Sprite2D = null

func _ready() -> void:
	# 初始化编辑页：先准备顶部编辑按钮，再绑定场景中已存在的虚拟按键，并保留编辑器中的原始位置。
	_controls_root = get_node_or_null("MobieControls") as Node2D
	if _controls_root == null:
		_controls_root = get_node_or_null("SettingsRoot/PagesRoot/MobieControlsPage/MobieControls") as Node2D
	_layout_overlay_sprite = get_node_or_null("MobieBackground") as Sprite2D
	_update_layout_bounds_from_viewport()
	_ensure_editor_buttons()
	_create_alpha_slider()
	_editor_default_positions = _collect_scene_button_positions()
	_default_button_positions = _editor_default_positions.duplicate()
	_load_layout_from_disk()
	_build_virtual_buttons()
	_apply_layout_to_buttons()
	_set_layout_editor_visible(false)

func _update_layout_bounds_from_viewport() -> void:
	# 使用当前视口尺寸作为布局边界，保证不同分辨率下仍然能把按钮限制在屏幕内。
	var viewport_size := get_viewport_rect().size
	if viewport_size.x > 0.0 and viewport_size.y > 0.0:
		layout_bounds = viewport_size
	if layout_bounds.x <= 0.0:
		layout_bounds.x = 1280.0
	if layout_bounds.y <= 0.0:
		layout_bounds.y = 720.0

func _ensure_editor_buttons() -> void:
	# 仅绑定场景中已经放置好的按钮；兼容现在的结构：
	# EditLayoutButton 在 MobieControlsPage 根节点，SaveAndCloseButton / ResetLayoutButton 在 MobieControls 容器中。
	_edit_layout_button = get_node_or_null("EditLayoutButton") as TextureButton
	if _edit_layout_button == null and _controls_root != null:
		_edit_layout_button = _controls_root.get_node_or_null("EditLayoutButton") as TextureButton

	_save_close_button = get_node_or_null("MobieControls/SaveAndCloseButton") as TextureButton
	if _save_close_button == null:
		_save_close_button = get_node_or_null("SaveAndCloseButton") as TextureButton
	if _save_close_button == null and _controls_root != null:
		_save_close_button = _controls_root.get_node_or_null("SaveAndCloseButton") as TextureButton

	_reset_layout_button = get_node_or_null("MobieControls/ResetLayoutButton") as TextureButton
	if _reset_layout_button == null:
		_reset_layout_button = get_node_or_null("ResetLayoutButton") as TextureButton
	if _reset_layout_button == null and _controls_root != null:
		_reset_layout_button = _controls_root.get_node_or_null("ResetLayoutButton") as TextureButton

	if _edit_layout_button == null or _save_close_button == null or _reset_layout_button == null:
		push_error("MobieControlsPage: 编辑器中缺少 EditLayoutButton / SaveAndCloseButton / ResetLayoutButton 节点，请在 SettingsScene.tscn 中添加。")
		return

	for button in [_edit_layout_button, _save_close_button, _reset_layout_button]:
		if button == null:
			continue
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_STOP

	if not _edit_layout_button.pressed.is_connected(_on_edit_layout_pressed):
		_edit_layout_button.pressed.connect(_on_edit_layout_pressed)
	if not _save_close_button.pressed.is_connected(_on_save_and_close_pressed):
		_save_close_button.pressed.connect(_on_save_and_close_pressed)
	if not _reset_layout_button.pressed.is_connected(_on_reset_layout_pressed):
		_reset_layout_button.pressed.connect(_on_reset_layout_pressed)
	_save_close_button.visible = false
	_reset_layout_button.visible = false

func _collect_scene_button_positions() -> Dictionary:
	var positions: Dictionary = {}
	var source_root := _controls_root if _controls_root != null else self
	for child in source_root.get_children():
		if child is TextureButton and child.name not in ["EditLayoutButton", "SaveAndCloseButton", "ResetLayoutButton"]:
			positions[child.name] = child.position
		if child.name == "MoveJoystickThumb" and child is TextureButton:
			positions["MoveJoystickThumb"] = child.position
	return positions

func _signal_has_callable(signal_ref: Signal, target: Callable) -> bool:
	for connection in signal_ref.get_connections():
		if connection.callable == target:
			return true
	return false

func _connect_unique(signal_ref: Signal, target: Callable) -> void:
	if not _signal_has_callable(signal_ref, target):
		signal_ref.connect(target)

func _build_virtual_buttons() -> void:
	# 只绑定场景中已经存在的虚拟按键节点；需要从新的 MobieControls 容器节点读取，
	# 不能再按直接子节点去找，否则编辑器中放置的布局会被忽略。
	var button_names: Array = ["MoveJoystick", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]
	var controls_root := _controls_root if _controls_root != null else self
	for button_name in button_names:
		var button: TextureButton = controls_root.get_node_or_null(button_name) as TextureButton
		if button == null:
			push_error("MobieControlsPage: 缺少虚拟按键节点 '%s'，请在编辑器中添加并拖放对应位置。" % button_name)
			continue
		button.modulate = Color(1.0, 1.0, 1.0, default_button_alpha)
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		_connect_unique(button.pressed, _on_virtual_button_pressed.bind(button))
		_connect_unique(button.button_down, _on_virtual_button_drag_started.bind(button))
		_connect_unique(button.button_up, _on_virtual_button_drag_ended.bind(button))
		_connect_unique(button.gui_input, _on_virtual_button_gui_input.bind(button))
		if button_name == "MoveJoystick":
			_joystick_base = button
			var thumb: TextureButton = controls_root.get_node_or_null("MoveJoystickThumb") as TextureButton
			if thumb == null:
				push_error("MobieControlsPage: 缺少摇杆拖动球 'MoveJoystickThumb'，请在场景中添加它。")
				continue
			thumb.modulate = Color(1.0, 1.0, 1.0, 0.9)
			thumb.focus_mode = Control.FOCUS_NONE
			thumb.mouse_filter = Control.MOUSE_FILTER_STOP
			_connect_unique(thumb.gui_input, _on_virtual_button_gui_input.bind(thumb))
			_connect_unique(thumb.button_down, _on_virtual_button_drag_started.bind(thumb))
			_connect_unique(thumb.button_up, _on_virtual_button_drag_ended.bind(thumb))
			_joystick_thumb = thumb
		else:
			_action_buttons[button_name] = button

	if _joystick_base == null:
		_joystick_base = controls_root.get_node_or_null("MoveJoystick") as TextureButton
	if _joystick_thumb == null:
		_joystick_thumb = controls_root.get_node_or_null("MoveJoystickThumb") as TextureButton

func _load_layout_from_disk() -> void:
	# 读取持久化布局配置；如果没有配置，则直接使用编辑器中拖拽放置的节点位置，不覆盖场景原始布局。
	_editor_default_positions = _collect_scene_button_positions()
	_default_button_positions = _editor_default_positions.duplicate()
	var config := ConfigFile.new()
	var err := config.load(_layout_config_path)
	if err != OK:
		return
	var layout = config.get_value("mobile_controls", "layout", {})
	if not layout.is_empty():
		_default_button_positions = _coerce_layout_to_pixels(layout)
	var saved_alpha = config.get_value("mobile_controls", "button_alpha", default_button_alpha)
	default_button_alpha = clampf(float(saved_alpha), 0.0, 1.0)
	if _button_alpha_slider != null and is_instance_valid(_button_alpha_slider):
		_button_alpha_slider.value = default_button_alpha

func _normalize_position_to_percent(control_position: Vector2) -> Vector2:
	# 把像素位置转换成相对百分比，避免固定分辨率绑定。
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return control_position
	return Vector2(control_position.x / viewport_size.x, control_position.y / viewport_size.y)

func _denormalize_position_from_percent(normalized_position: Vector2) -> Vector2:
	# 把百分比位置恢复为当前分辨率的像素值。
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return normalized_position
	return Vector2(normalized_position.x * viewport_size.x, normalized_position.y * viewport_size.y)

func _coerce_layout_to_pixels(layout: Dictionary) -> Dictionary:
	# 兼容旧的像素布局和新的百分比布局，统一转换为当前分辨率像素坐标。
	var result: Dictionary = {}
	for key in layout.keys():
		var value = layout[key]
		if value is Vector2:
			if value.x <= 1.0 and value.y <= 1.0:
				result[key] = _denormalize_position_from_percent(value)
			else:
				result[key] = value
		else:
			result[key] = value
	return result

func _save_layout_to_disk() -> void:
	# 将按钮当前位置和统一透明度写入配置文件，供运行时 HUD 读取；编辑器默认位置保留为重置基线，不被拖拽中的当前结果覆盖。
	var config := ConfigFile.new()
	var layout_positions: Dictionary = _collect_scene_button_positions()
	for key in layout_positions.keys():
		layout_positions[key] = _normalize_position_to_percent(layout_positions[key])
	config.set_value("mobile_controls", "layout", layout_positions)
	config.set_value("mobile_controls", "button_alpha", default_button_alpha)
	config.save(_layout_config_path)
	_default_button_positions = _editor_default_positions.duplicate()

func _apply_button_alpha() -> void:
	# 关键修正：实际控制的节点在 MobieControls 容器内，
	# 不能只遍历 Page 自身的直接子节点，否则设置页中看到的按钮不会跟随 alpha 滑块变化。
	var target_root := _controls_root if _controls_root != null else self
	for child in target_root.get_children():
		if child is TextureButton and child.name not in ["EditLayoutButton", "SaveAndCloseButton", "ResetLayoutButton"]:
			child.modulate = Color(1.0, 1.0, 1.0, default_button_alpha)
	if _joystick_thumb:
		_joystick_thumb.modulate = Color(1.0, 1.0, 1.0, default_button_alpha)
	if _joystick_base:
		_joystick_base.modulate = Color(1.0, 1.0, 1.0, default_button_alpha)
	if _button_alpha_slider != null and is_instance_valid(_button_alpha_slider):
		_button_alpha_slider.value = default_button_alpha

func _create_alpha_slider() -> void:
	# 严格遵守要求：不要在脚本中创建新节点。
	# 兼容两种结构：
	#  A) VirtualButtonAlphaSlider 直接位于 MobieControls 下；
	#  B) 滑块被包在 VirtualButtonAlphaLabel 父节点内（编辑态显示的是该 Label 整体）。
	var slider_root := _controls_root if _controls_root != null else self
	_button_alpha_label = slider_root.get_node_or_null("VirtualButtonAlphaLabel") as CanvasItem
	_button_alpha_slider = slider_root.get_node_or_null("VirtualButtonAlphaSlider") as HSlider
	if _button_alpha_slider == null and _button_alpha_label:
		_button_alpha_slider = _button_alpha_label.get_node_or_null("VirtualButtonAlphaSlider") as HSlider
	if _button_alpha_slider == null:
		_button_alpha_slider = get_node_or_null("VirtualButtonAlphaSlider") as HSlider
	if _button_alpha_slider == null or not is_instance_valid(_button_alpha_slider):
		_button_alpha_slider = null
		_button_alpha_label = null
		_alpha_display_control = null
		return
	# 有 VirtualButtonAlphaLabel 时控制它整体显隐；没有则退化为直接控制滑块。
	_alpha_display_control = _button_alpha_label if (_button_alpha_label and is_instance_valid(_button_alpha_label)) else _button_alpha_slider
	if not _button_alpha_slider.value_changed.is_connected(_on_button_alpha_changed):
		_button_alpha_slider.value_changed.connect(_on_button_alpha_changed)
	_button_alpha_slider.value = default_button_alpha
	if _alpha_display_control:
		_alpha_display_control.visible = false

func _on_button_alpha_changed(value: float) -> void:
	default_button_alpha = clampf(value, 0.0, 1.0)
	_apply_button_alpha()

func _apply_layout_to_buttons() -> void:
	# 把保存的配置同步到所有虚拟按键节点的位置；一旦节点在编辑器中被手动摆放，就保留其显式位置，
	# 不再根据摇杆球自动重算基础底座位置，以避免覆盖编辑器中的原始布局。
	var controls_root := _controls_root if _controls_root != null else self
	for child in controls_root.get_children():
		if child is TextureButton:
			var saved = _default_button_positions.get(child.name, child.position)
			if saved is Vector2:
				child.position = saved
		if child.name == "MoveJoystickThumb" and _joystick_thumb:
			var saved_thumb = _default_button_positions.get("MoveJoystickThumb", _joystick_thumb.position)
			if saved_thumb is Vector2:
				_joystick_thumb.position = saved_thumb
		if child.name == "MoveJoystick" and _joystick_base:
			var saved_base = _default_button_positions.get("MoveJoystick", _joystick_base.position)
			if saved_base is Vector2:
				_joystick_base.position = saved_base
	_apply_button_alpha()

func _set_layout_editor_visible(show_state: bool) -> void:
	# 关键修正（按需求）：
	# 非编辑态（刚点开 ControlsButton 时）：隐藏 MobieBackground 与 MobieControls 及其全部子节点，
	# 只保留 EditLayoutButton 可见。
	# 编辑态（点击 EditLayoutButton 后）：显示 MobieBackground + MobieControls
	# （7 个虚拟按键、SaveAndCloseButton、ResetLayoutButton、VirtualButtonAlphaLabel 及其子滑块）。
	_layout_editing = show_state
	if _edit_layout_button:
		_edit_layout_button.visible = not show_state
	if _layout_overlay_sprite:
		_layout_overlay_sprite.visible = show_state
	if _controls_root:
		# MobieControls 整体显隐控制真实虚拟按键与编辑控件；
		# EditLayoutButton 位于页面根节点，不在此容器内，因此不受影响。
		_controls_root.visible = show_state
		for child in _controls_root.get_children():
			if child is TextureButton:
				child.visible = show_state
		if _joystick_thumb:
			_joystick_thumb.visible = show_state
	# 关键修正：编辑态显示的透明度控件是 VirtualButtonAlphaLabel（含子滑块）整体；
	# 有该 Label 节点时控制 Label，否则退化为控制滑块自身。
	if _alpha_display_control:
		_alpha_display_control.visible = show_state
	if _save_close_button:
		_save_close_button.visible = show_state
	if _reset_layout_button:
		_reset_layout_button.visible = show_state

func _request_scene_lock(locked: bool) -> void:
	var current: Node = self
	while current:
		if current.has_method("_set_scene_input_locked"):
			current._set_scene_input_locked(locked)
			return
		current = current.get_parent()

func _on_edit_layout_pressed() -> void:
	# 进入拖拽编辑态：将所有虚拟按键设置为可拖拽、可查看、但不执行真实操作。
	_request_scene_lock(true)
	_set_layout_editor_visible(true)

func _on_save_and_close_pressed() -> void:
	# 保存当前布局并退出编辑态，并通知父设置页恢复正常交互和环境亮度。
	_save_layout_to_disk()
	_notify_mobile_hud_reload()
	_set_layout_editor_visible(false)
	_request_scene_lock(false)
	layout_saved_and_closed.emit()

func _on_reset_layout_pressed() -> void:
	# 仅重置布局到编辑器默认位置，不退出编辑态。
	_default_button_positions = _editor_default_positions.duplicate()
	_apply_layout_to_buttons()
	_save_layout_to_disk()
	_notify_mobile_hud_reload()

func _notify_mobile_hud_reload() -> void:
	# 让游戏场景中存活的移动端 HUD 立即重新读取磁盘配置并应用，
	# 使“在设置页调整按键/透明度”的改动无需重进存档即可在游戏中生效。
	for hud in get_tree().get_nodes_in_group("mobile_touch_hud"):
		if hud.has_method("reload_layout"):
			hud.reload_layout()

func _on_virtual_button_pressed(_button: TextureButton) -> void:
	# pressed 信号在鼠标释放时才触发，此时拖拽已经结束。
	# 不能在这里设置 _dragging_button，否则松开鼠标后仅悬停就会拖动按钮。
	pass

func _on_virtual_button_drag_started(button: TextureButton) -> void:
	# 开始拖动时记录当前正在拖拽的按钮；摇杆基座按住时必须视作拖动摇杆球。
	if not _layout_editing:
		return
	if button == _joystick_base:
		_dragging_button = _joystick_thumb
		return
	_dragging_button = button

func _on_virtual_button_drag_ended(_button: TextureButton) -> void:
	# 拖拽结束时写入布局配置，并更新到磁盘。
	_dragging_button = null
	_save_layout_to_disk()

func _clamp_button_position(button: TextureButton, next_position: Vector2) -> Vector2:
	var max_x: float = maxf(layout_bounds.x - button.size.x, 0.0)
	var max_y: float = maxf(layout_bounds.y - button.size.y, 0.0)
	return Vector2(clampf(next_position.x, 0.0, max_x), clampf(next_position.y, 0.0, max_y))

func _drag_button_by_event(button: TextureButton, drag_delta: Vector2) -> void:
	_update_layout_bounds_from_viewport()
	if button == _joystick_base and _joystick_thumb:
		var next_base: Vector2 = _clamp_button_position(button, button.position + drag_delta)
		var delta: Vector2 = next_base - button.position
		button.position = next_base
		_joystick_thumb.position = _clamp_button_position(_joystick_thumb, _joystick_thumb.position + delta)
		_save_layout_to_disk()
		return
	if button == _joystick_thumb and _joystick_base:
		var next_thumb: Vector2 = _clamp_button_position(button, button.position + drag_delta)
		var delta: Vector2 = next_thumb - button.position
		button.position = next_thumb
		_joystick_base.position = _clamp_button_position(_joystick_base, _joystick_base.position + delta)
		_save_layout_to_disk()
		return
	var next_button_position: Vector2 = _clamp_button_position(button, button.position + drag_delta)
	button.position = next_button_position
	_save_layout_to_disk()

func _on_virtual_button_gui_input(event: InputEvent, button: TextureButton) -> void:
	# 编辑态时，摇杆基座和摇杆球必须一起拖动，不允许单独分离，且不强制把 thumb 归正到中心。
	if not _layout_editing:
		return
	var target_button: TextureButton = button
	if button == _joystick_base:
		target_button = _joystick_base
	if _dragging_button != target_button:
		return
	if event is InputEventMouseMotion:
		_drag_button_by_event(target_button, event.relative)
		return
	if event is InputEventScreenDrag:
		_drag_button_by_event(target_button, event.relative)

func _get_default_layout() -> Dictionary:
	# 默认移动端布局：目标是编辑器中拖拽的初始位置，脚本不直接硬编码最终使用位置。
	return {
		"MoveJoystick": {"position": Vector2(120.0, 540.0), "size": 96.0},
		"JumpButton": {"position": Vector2(1110.0, 500.0), "size": 72.0},
		"DashButton": {"position": Vector2(1180.0, 590.0), "size": 72.0},
		"InteractButton": {"position": Vector2(1035.0, 585.0), "size": 72.0},
		"SuperDashButton": {"position": Vector2(960.0, 610.0), "size": 72.0},
		"MapButton": {"position": Vector2(1160.0, 420.0), "size": 56.0},
	}

func _get_default_layout_positions() -> Dictionary:
	# 将默认布局转成位置字典，供保存/重置逻辑调用。
	var positions: Dictionary = {}
	var layout := _get_default_layout()
	for key in layout.keys():
		positions[key] = layout[key]["position"]
	positions["MoveJoystickThumb"] = layout["MoveJoystick"]["position"] + Vector2(18.0, 18.0)
	return positions

func cancel_current_mapping() -> void:
	# 兼容设置页调用接口，与 PC 端控制页保持一致。
	pass

func get_layout_config() -> Dictionary:
	# 返回布局配置：供运行时 HUD 或其他模块读取。
	var layout := _default_button_positions.duplicate()
	if layout.is_empty():
		layout = _get_default_layout_positions()
	return {
		"layout": layout,
		"layout_mode": 0,
		"dpad_center": Vector2(120.0, 540.0),
	}

func apply_layout_config(config: Dictionary) -> void:
	# 更新当前布局：来自运行时 HUD 或其它模块，保持兼容接口。
	if config.has("layout"):
		_default_button_positions = config["layout"]
		_apply_layout_to_buttons()
	if config.has("dpad_center"):
		if _joystick_base:
			_joystick_base.position = config["dpad_center"] - _joystick_base.size * 0.5
		if _joystick_thumb:
			_joystick_thumb.position = config["dpad_center"] - _joystick_thumb.size * 0.5
