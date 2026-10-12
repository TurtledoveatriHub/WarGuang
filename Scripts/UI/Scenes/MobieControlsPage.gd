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
@export var fade_in_duration: float = 0.8
## 淡出时间，单位：秒。
@export var fade_out_duration: float = 0.5
## 可拖拽布局区域的最大范围，通常与分辨率一致。
@export var layout_bounds: Vector2 = Vector2(1280.0, 720.0)
## 虚拟按键统一透明度：0=完全透明, 1=完全不透明。
@export_range(0.0, 1.0, 0.01) var default_button_alpha: float = 1.0

## 布局编辑时，按下去拖拽虚拟按键是否要有悬停/按下贴图变化。
## 默认关闭：编辑时手指按住按钮只表示「拖动」，贴图变化会干扰观察按钮真实外观。
## 以后需要时把本开关勾上即可（贴图仍配在场景里，不用重新接）。
@export var show_button_texture_feedback: bool = false

## 内部变量
signal layout_saved_and_closed

var _layout_config_path: String = "user://mobile_controls_layout.cfg"
var _layout_editing: bool = false
## 初始化期间禁止写盘：_ready 里的程序性 slider.value 赋值会触发 value_changed，
## 若那时就保存，会把默认值写回配置，反而把磁盘上已保存的大小/透明度冲掉。
var _suppress_layout_write: bool = false
var _dragging_button: TextureButton = null
## 上一次拖拽时的**指针位置**（画布坐标）。位移一律用「本次指针位置 − 上次指针位置」求。
var _drag_last_pointer_pos: Vector2 = Vector2.ZERO
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
var _button_alpha_text_label: Label = null
var _alpha_display_control: CanvasItem = null
## 虚拟按键统一大小倍率（0.5~2.0）。
var _button_scale: float = 1.0
## 移动方案：0=摇杆，1=十字键。
var _move_mode: int = 0
var _button_scale_slider: HSlider = null
var _button_scale_label: CanvasItem = null
var _button_scale_text_label: Label = null
var _scale_display_control: CanvasItem = null
var _move_mode_option: OptionButton = null
## “移动操控选项”整组（Label + OptionButton）的显隐控制节点。
var _move_mode_label: CanvasItem = null
## 避免程序设置 OptionButton.selected 时又回写配置。
var _suppress_move_mode_callback: bool = false
## 记录 MobieBackground 原始不透明度，用于淡入淡出。
var _layout_overlay_alpha: float = 1.0
## 每个虚拟按键在编辑器中放置的原始 scale（应用大小倍率前）。
var _base_scales: Dictionary = {}
var _joystick_group: Array = []
var _dpad_group: Array = []
var _controls_root: Node2D = null
var _layout_overlay_sprite: Sprite2D = null

func _ready() -> void:
	# 初始化期间（建滑块 / 读配置 / 应用布局）一律不写盘，避免默认值覆盖已保存的设置。
	_suppress_layout_write = true
	# 初始化编辑页：先准备顶部编辑按钮，再绑定场景中已存在的虚拟按键，并保留编辑器中的原始位置。
	_controls_root = get_node_or_null("MobieControls") as Node2D
	if _controls_root == null:
		_controls_root = get_node_or_null("SettingsRoot/PagesRoot/MobieControlsPage/MobieControls") as Node2D
	_layout_overlay_sprite = get_node_or_null("MobieBackground") as Sprite2D
	if _layout_overlay_sprite != null:
		_layout_overlay_alpha = _layout_overlay_sprite.modulate.a
	_update_layout_bounds_from_viewport()
	_ensure_editor_buttons()
	_normalize_button_rects()
	_capture_base_scales()
	_create_alpha_slider()
	_create_scale_slider()
	_create_move_mode_option()
	_editor_default_positions = _collect_scene_button_positions()
	_default_button_positions = _editor_default_positions.duplicate()
	_load_layout_from_disk()
	_build_virtual_buttons()
	_apply_layout_to_buttons()
	_set_layout_editor_visible(false)
	# 初始化完成：之后的滑块/下拉改动才允许写盘 + 通知游戏内 HUD。
	_suppress_layout_write = false

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
	# 只绑定场景中已经存在的虚拟按键节点（含十字键）。
	var button_names: Array = ["MoveJoystick", "DpadUp", "DpadDown", "DpadLeft", "DpadRight", "JumpButton", "DashButton", "InteractButton", "SuperDashButton", "MapButton"]
	var controls_root := _controls_root if _controls_root != null else self
	# 注意：**不要**在这里重置 / 重采 _base_scales ——
	# 此时 _load_layout_from_disk() 已经按保存的倍率改过 scale，再采一次就会把
	# 「场景基准 × 倍率」当成新基准，倍率于是层层累积（150% 重进设置页变成 1.5×1.5，
	# 再设 100% 却显示 150%）。基准统一只在 _capture_base_scales() 里读一次。
	_joystick_group.clear()
	_dpad_group.clear()
	for button_name in button_names:
		var button: TextureButton = controls_root.get_node_or_null(button_name) as TextureButton
		if button == null:
			continue
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		if not show_button_texture_feedback:
			# 编辑布局时不希望按下/悬停改变贴图：清掉这两张，BaseButton 自动回退到
			# texture_normal，按住拖拽全程画面不变。
			button.texture_pressed = null
			button.texture_hover = null
		_connect_unique(button.pressed, _on_virtual_button_pressed.bind(button))
		_connect_unique(button.button_down, _on_virtual_button_drag_started.bind(button))
		_connect_unique(button.button_up, _on_virtual_button_drag_ended.bind(button))
		_connect_unique(button.gui_input, _on_virtual_button_gui_input.bind(button))
		if button_name == "MoveJoystick":
			_joystick_base = button
			_joystick_group.append(button)
		elif button_name.begins_with("Dpad"):
			_dpad_group.append(button)
		else:
			_action_buttons[button_name] = button
	# 摇杆拖动球单独处理
	var thumb: TextureButton = controls_root.get_node_or_null("MoveJoystickThumb") as TextureButton
	if thumb != null:
		thumb.focus_mode = Control.FOCUS_NONE
		# 摇杆是一个整体（按需求：只能整体拖动）。
		# 拖动球不接收指针：否则按住摇杆正中（球所在处）会落到球上，
		# 出现「按上下两端能拖、按中间反而拖不动」的怪象。按在摇杆任意位置都由基座接收。
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_joystick_thumb = thumb
		_joystick_group.append(thumb)
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
	_update_alpha_label()
	var saved_scale = config.get_value("mobile_controls", "button_scale", 1.0)
	_button_scale = clampf(float(saved_scale), 0.5, 2.0)
	_move_mode = int(config.get_value("mobile_controls", "move_mode", 0))
	if _move_mode != 1:
		_move_mode = 0
	if _button_scale_slider != null and is_instance_valid(_button_scale_slider):
		_button_scale_slider.value = _button_scale
	if _move_mode_option != null and is_instance_valid(_move_mode_option):
		_suppress_move_mode_callback = true
		_move_mode_option.selected = _move_mode
		_suppress_move_mode_callback = false
	_update_scale_label()

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
	config.set_value("mobile_controls", "button_scale", _button_scale)
	config.set_value("mobile_controls", "move_mode", _move_mode)
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
	_button_alpha_text_label = _button_alpha_label as Label
	if not _button_alpha_slider.value_changed.is_connected(_on_button_alpha_changed):
		_button_alpha_slider.value_changed.connect(_on_button_alpha_changed)
	_button_alpha_slider.value = default_button_alpha
	_update_alpha_label()
	if _alpha_display_control:
		_alpha_display_control.visible = false

func _on_button_alpha_changed(value: float) -> void:
	default_button_alpha = clampf(value, 0.0, 1.0)
	_update_alpha_label()
	_apply_button_alpha()
	# 立即落盘并通知游戏内 HUD：否则只有在编辑态里点「保存并关闭」才会保存，
	# 用 ESC / 退回主菜单离开设置页时改动会丢。
	if _suppress_layout_write:
		return
	_save_layout_to_disk()
	_notify_mobile_hud_reload()


## 在“按键不透明度” Label 上显示当前百分比。
func _update_alpha_label() -> void:
	if _button_alpha_text_label != null and is_instance_valid(_button_alpha_text_label):
		_button_alpha_text_label.text = tr("按键不透明度：%d%%") % int(round(default_button_alpha * 100.0))


## 把每个虚拟按键的「可点击矩形」对齐到它实际画出来的纹理大小。
## 起因：按钮用 stretch_mode = KEEP_CENTERED（按纹理原始尺寸居中绘制），
## 而节点矩形往往被 clamp 到纹理的最小尺寸/写成 32×32；两者不一致时，
## 手指按在看得见的纹理上却落在矩形之外 —— 表现就是「拖拽范围跟看到的按钮对不上」，
## 纹理最大的摇杆、十字键最明显。这里把矩形改成纹理尺寸，并保持**视觉中心不动**。
func _normalize_button_rects() -> void:
	var target_root := _controls_root if _controls_root != null else self
	for child in target_root.get_children():
		if child is TextureButton:
			_normalize_button_rect(child as TextureButton)


## 单个按钮：矩形 = 纹理尺寸，pivot = 中心，且移动后视觉中心不变。
func _normalize_button_rect(button: TextureButton) -> void:
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


## 记录所有虚拟按键在编辑器中的原始 scale（必须在应用倍率之前调用，保证幂等）。
## 只在这里读一次场景值：之后所有缩放都从这份基准推算 —— 一旦从「当前 scale」反推，
## 倍率就会层层累积（150% → 缩短 → 再回 150%，三次结果互不相同）。
func _capture_base_scales() -> void:
	_base_scales.clear()
	var target_root := _controls_root if _controls_root != null else self
	for child in target_root.get_children():
		if child is TextureButton:
			_base_scales[child.name] = child.scale
			# 像素美术：强制最近邻采样，避免缩放时像素块被插值糊掉。
			child.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _create_scale_slider() -> void:
	# 与不透明度滑块同构：VirtualButtonScaleLabel（含子滑块）。
	var slider_root := _controls_root if _controls_root != null else self
	_button_scale_label = slider_root.get_node_or_null("VirtualButtonScaleLabel") as CanvasItem
	_button_scale_slider = slider_root.get_node_or_null("VirtualButtonScaleSlider") as HSlider
	if _button_scale_slider == null and _button_scale_label:
		_button_scale_slider = _button_scale_label.get_node_or_null("VirtualButtonScaleSlider") as HSlider
	if _button_scale_slider == null:
		return
	_scale_display_control = _button_scale_label if (_button_scale_label and is_instance_valid(_button_scale_label)) else _button_scale_slider
	_button_scale_text_label = _button_scale_label as Label
	_connect_unique(_button_scale_slider.value_changed, _on_button_scale_changed)
	_button_scale_slider.min_value = 0.5
	_button_scale_slider.max_value = 2.0
	# 步长 0.25 → 只能取 50% / 75% / 100% / 125% ... / 200%
	_button_scale_slider.step = 0.25
	_button_scale_slider.value = _button_scale
	_update_scale_label()
	if _scale_display_control:
		_scale_display_control.visible = false


func _on_button_scale_changed(value: float) -> void:
	_button_scale = clampf(value, 0.5, 2.0)
	_update_scale_label()
	_apply_button_scale()
	# 同不透明度：立即落盘 + 通知游戏内 HUD 重载布局（无需重进存档即可看到效果）。
	if _suppress_layout_write:
		return
	_save_layout_to_disk()
	_notify_mobile_hud_reload()


## 在“按键大小” Label 上显示当前百分比数值。
func _update_scale_label() -> void:
	if _button_scale_text_label != null and is_instance_valid(_button_scale_text_label):
		_button_scale_text_label.text = tr("按键大小：%d%%") % int(round(_button_scale * 100.0))


## 统一应用大小倍率（含被禁用的那一组移动按键）。
## 只按「基准 × 倍率」写一次，绝不从当前 scale 反推。
func _apply_button_scale() -> void:
	var target_root := _controls_root if _controls_root != null else self
	for button_name in _base_scales.keys():
		var key: String = String(button_name)
		if key in ["EditLayoutButton", "SaveAndCloseButton", "ResetLayoutButton"]:
			continue
		var child: TextureButton = target_root.get_node_or_null(key) as TextureButton
		if child == null:
			continue
		# 以按键自身中心为缩放基准（而不是左上角）。
		child.pivot_offset = child.size * 0.5
		child.scale = _base_scales[button_name] * _button_scale
		child.modulate = Color(1.0, 1.0, 1.0, default_button_alpha)
	if _button_scale_slider != null and is_instance_valid(_button_scale_slider):
		_button_scale_slider.value = _button_scale


func _create_move_mode_option() -> void:
	var option_root := _controls_root if _controls_root != null else self
	# 支持 MoveModeLabel/MoveModeOption 嵌套结构，并兼容直接子节点结构。
	_move_mode_label = option_root.get_node_or_null("MoveModeLabel") as CanvasItem
	_move_mode_option = option_root.get_node_or_null("MoveModeLabel/MoveModeOption") as OptionButton
	if _move_mode_option == null:
		_move_mode_option = option_root.get_node_or_null("MoveModeOption") as OptionButton
	if _move_mode_option == null:
		return
	_move_mode_option.focus_mode = Control.FOCUS_NONE
	_move_mode_option.selected = _move_mode
	_connect_unique(_move_mode_option.item_selected, _on_move_mode_selected)
	_set_move_mode_ui_visible(false)


## 显示/隐藏整个“移动操控选项”控件（优先使用其父 Label）。
func _set_move_mode_ui_visible(visible_value: bool) -> void:
	if _move_mode_label != null and is_instance_valid(_move_mode_label):
		_move_mode_label.visible = visible_value
	elif _move_mode_option != null and is_instance_valid(_move_mode_option):
		_move_mode_option.visible = visible_value


func _on_move_mode_selected(index: int) -> void:
	# 下拉选择移动方案：0=摇杆，1=十字键。切换后立即应用并保存，并通知游戏内 HUD 重新加载。
	if _suppress_move_mode_callback:
		return
	_move_mode = 1 if index == 1 else 0
	_apply_move_mode_visibility()
	_save_layout_to_disk()
	_notify_mobile_hud_reload()


## 只显示当前选中的移动方案那一组（按需求：编辑态也不允许两组同时显示）。
## 想编辑另一组，请在编辑态里用「移动方式」下拉切过去，再拖那一组的按钮。
func _apply_move_mode_visibility() -> void:
	var show_dpad := _move_mode == 1
	for b in _joystick_group:
		if is_instance_valid(b):
			b.visible = not show_dpad
	for b in _dpad_group:
		if is_instance_valid(b):
			b.visible = show_dpad

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
	_apply_button_scale()
	# 摇杆球必须始终与基座同心：
	# 存档里可能残留旧版本写下的偏移位置，而需求是「摇杆只能整体移动」。
	if _joystick_base != null and _joystick_thumb != null:
		var base_center: Vector2 = _joystick_base.position + _joystick_base.size * 0.5
		_joystick_thumb.position = base_center - _joystick_thumb.size * 0.5

func _set_layout_editor_visible(show_state: bool) -> void:
	# 关键修正（按需求）：
	# 非编辑态（刚点开 ControlsButton 时）：隐藏 MobieBackground 与 MobieControls 及其全部子节点，
	# 只保留 EditLayoutButton 可见。
	# 编辑态（点击 EditLayoutButton 后）：显示 MobieBackground + MobieControls
	# （7 个虚拟按键、SaveAndCloseButton、ResetLayoutButton、VirtualButtonAlphaLabel 及其子滑块）。
	_layout_editing = show_state
	if _edit_layout_button:
		_edit_layout_button.visible = not show_state
	# MobieBackground 同样做淡入淡出（不再是硬切换）。
	_fade_layout_overlay(show_state)
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
	if _scale_display_control:
		_scale_display_control.visible = show_state
	_set_move_mode_ui_visible(show_state)
	if _save_close_button:
		_save_close_button.visible = show_state
	if _reset_layout_button:
		_reset_layout_button.visible = show_state
	if show_state:
		# 两组移动按键都受统一大小/透明度影响，但只显示当前选中的那一组。
		_apply_move_mode_visibility()
		_apply_button_scale()

## MobieBackground 淡入淡出（编辑态显示/隐藏）。
func _fade_layout_overlay(show_state: bool) -> void:
	if _layout_overlay_sprite == null or not is_instance_valid(_layout_overlay_sprite):
		return
	if show_state:
		_layout_overlay_sprite.visible = true
		_layout_overlay_sprite.modulate = Color(1, 1, 1, 0.0)
		var tw := create_tween()
		tw.tween_property(_layout_overlay_sprite, "modulate:a", _layout_overlay_alpha, fade_in_duration)
	else:
		var tw := create_tween()
		tw.tween_property(_layout_overlay_sprite, "modulate:a", 0.0, fade_out_duration)
		tw.tween_callback(func():
			_layout_overlay_sprite.visible = false
		)


func _request_scene_lock(locked: bool) -> void:
	var current: Node = self
	while current:
		if current.has_method("set_input_locked"):
			current.call("set_input_locked", locked)
			return
		current = current.get_parent()

## 编辑布局时，把「本页之外」的所有控件（返回按钮、三个分类按钮…）设为不接收指针。
## ── 实测证据（在运行中的游戏里注入真实鼠标事件）─────────────────────
##   * BackButton：offset(58,608) size(176,32) scale 2.5 → 可点击矩形是
##     P:(-74,584) S:(440,80)（左半截还在屏幕外），正好盖住整个左下角。
##   * Godot 的控件拾取按场景树顺序、**不看 z_index**（返回按钮在场景树里比页面更靠后），
##     所以它先拿到按下事件：按在左下角虚拟按键**正中心**都抓不到（实测 grabbed=false），
##     而把返回按钮设为 IGNORE 后同一次拖拽立即正常（grabbed=true, 位移 13.33）。
## 表象就是「左下角那几个固定小位置拖不动、可拖区域很小且位置偏离」。
var _suppressed_mouse_filters: Dictionary = {}

func _suppress_outside_input(suppress: bool) -> void:
	if suppress:
		_suppressed_mouse_filters.clear()
		var scene_root: Node = self
		# 一路走到本页所在场景的根（SettingsScene），只处理这一棵树。
		while scene_root.get_parent() != null and scene_root.get_parent() != get_tree().root:
			scene_root = scene_root.get_parent()
		_suppress_recursive(scene_root, self)
	else:
		for node in _suppressed_mouse_filters.keys():
			if is_instance_valid(node):
				(node as Control).mouse_filter = _suppressed_mouse_filters[node]
		_suppressed_mouse_filters.clear()

func _suppress_recursive(node: Node, keep_root: Node) -> void:
	for child in node.get_children():
		# keep_root 是「本页」：整棵子树都要保留（虚拟按键 + 大小/透明度滑块都要能操作），
		# 只屏蔽本页之外的控件。
		if child == keep_root:
			continue
		if child is Control:
			var control: Control = child as Control
			_suppressed_mouse_filters[control] = control.mouse_filter
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_suppress_recursive(child, keep_root)

func _on_edit_layout_pressed() -> void:
	# 进入拖拽编辑态：将所有虚拟按键设置为可拖拽、可查看、但不执行真实操作。
	_request_scene_lock(true)
	_suppress_outside_input(true)
	_set_layout_editor_visible(true)

func _on_save_and_close_pressed() -> void:
	# 保存当前布局并退出编辑态，并通知父设置页恢复正常交互和环境亮度。
	_save_layout_to_disk()
	_notify_mobile_hud_reload()
	_set_layout_editor_visible(false)
	_suppress_outside_input(false)
	_request_scene_lock(false)
	layout_saved_and_closed.emit()

func _on_reset_layout_pressed() -> void:
	# 仅重置布局到编辑器默认位置，不退出编辑态。
	# 关键：先删掉磁盘上的旧布局再重置 —— 历史保存的数据会一直覆盖编辑器里的位置，
	# 这就是「在编辑器里调好了位置、游戏里却还是老位置」的根源。
	_delete_saved_layout_file()
	_default_button_positions = _editor_default_positions.duplicate()
	_apply_layout_to_buttons()
	_save_layout_to_disk()
	_notify_mobile_hud_reload()


## 删除磁盘上保存的虚拟按键布局（等价于「清除已保存的布局」）。
func _delete_saved_layout_file() -> void:
	if not FileAccess.file_exists(_layout_config_path):
		return
	var err: int = DirAccess.remove_absolute(ProjectSettings.globalize_path(_layout_config_path))
	if err != OK:
		push_warning("MobieControlsPage: 删除布局文件失败（err=%d）" % err)

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
	# 记录**收到按下的那个**按钮即可：摇杆基座与拖动球是一对，
	# _drag_button_by_event() 无论从哪一个开始都会把两者一起移动。
	# （以前这里把基座硬改成「拖动球」：拖动事件来自基座、而 _dragging_button 是球，
	#   两者永远不相等 → 按住基座拖动毫无反应，只能精确按住中间那颗小球才拖得动。）
	if not _layout_editing:
		return
	_dragging_button = button
	_drag_last_pointer_pos = button.get_global_mouse_position()

func _on_virtual_button_drag_ended(_button: TextureButton) -> void:
	# 拖拽结束时写入布局配置，并更新到磁盘。
	_dragging_button = null
	_save_layout_to_disk()

## 夹住 position，只保证**按钮中心**留在屏幕内。
## 迭代记录：曾经改成「整个可见矩形必须在屏内」，结果放大 3 倍的按钮在屏幕边缘
## 会被 clamp 抢位置 —— 手指拖到角落时按钮不跟手（发粘），而且继续拖会“躲”开手指，
## 看起来就像「那一片区域的拖拽范围变小且位置偏离」。现在只夹中心，移动完全跟手。
func _clamp_button_position(button: TextureButton, next_position: Vector2) -> Vector2:
	var s: Vector2 = button.scale
	var pivot: Vector2 = button.pivot_offset
	# position → 可见矩形中心的固定偏移（由 pivot 与 scale 决定）
	var center_offset: Vector2 = pivot + (button.size * 0.5 - pivot) * s
	var center: Vector2 = next_position + center_offset
	center.x = clampf(center.x, 0.0, layout_bounds.x)
	center.y = clampf(center.y, 0.0, layout_bounds.y)
	return center - center_offset

func _drag_button_by_event(button: TextureButton, drag_delta: Vector2) -> void:
	_update_layout_bounds_from_viewport()
	# 注意：拖动过程中**不要**写盘。以前每一帧都 _save_layout_to_disk()，
	# 一次拖动就是几十次文件写入，表现为拖动发滞、不跟手。
	# 保存统一放在 _on_virtual_button_drag_ended() 里做。
	if button == _joystick_base and _joystick_thumb:
		var next_base: Vector2 = _clamp_button_position(button, button.position + drag_delta)
		var delta: Vector2 = next_base - button.position
		button.position = next_base
		_joystick_thumb.position = _clamp_button_position(_joystick_thumb, _joystick_thumb.position + delta)
		return
	if button == _joystick_thumb and _joystick_base:
		var next_thumb: Vector2 = _clamp_button_position(button, button.position + drag_delta)
		var delta: Vector2 = next_thumb - button.position
		button.position = next_thumb
		_joystick_base.position = _clamp_button_position(_joystick_base, _joystick_base.position + delta)
		return
	button.position = _clamp_button_position(button, button.position + drag_delta)


## 拖拽位移：**不要用 event.relative**。
## ── 实测证据（在运行中的游戏里注入 40px 位移的真实鼠标事件）───────────
##   * scale = 3 的按钮：event.relative 只有 13.33px（= 40 / 3，即真实位移的 1/scale）；
##     把同一个按钮 scale 改成 1 再拖同样 40px，正好走 40px ⇒ 事件已被处理成「控件局部坐标」。
##   * 触摸：位置只同步到「模拟鼠标」上（手机端悬停能正常触发就是证据），事件自身的 position 不可靠
##     （注入 ScreenDrag 实测位移为 0）。
## 所以统一用「指针位置求差」（get_global_mouse_position）：鼠标与触摸都跟随，
## 也天然免疫「一次手指移动同时产生 ScreenDrag + 模拟 MouseMotion」的重复叠加。
func _on_virtual_button_gui_input(event: InputEvent, button: TextureButton) -> void:
	if not _layout_editing:
		return
	if button != _dragging_button:
		return
	if not (event is InputEventMouseMotion or event is InputEventScreenDrag):
		return
	var pointer: Vector2 = button.get_global_mouse_position()
	var delta: Vector2 = pointer - _drag_last_pointer_pos
	_drag_last_pointer_pos = pointer
	# 指针位置是画布坐标，而 button.position 是父节点局部坐标：按父节点缩放换算。
	var parent: Node = button.get_parent()
	if parent is CanvasItem:
		var parent_scale: Vector2 = (parent as CanvasItem).get_global_transform_with_canvas().get_scale()
		if absf(parent_scale.x) > 0.0001 and absf(parent_scale.y) > 0.0001:
			delta = Vector2(delta.x / parent_scale.x, delta.y / parent_scale.y)
	_drag_button_by_event(button, delta)

func cancel_current_mapping() -> void:
	# 兼容设置页调用接口，与 PC 端控制页保持一致。
	pass

func get_layout_config() -> Dictionary:
	# 返回布局配置：供运行时 HUD 或其他模块读取。
	var layout := _default_button_positions.duplicate()
	return {
		"layout": layout,
		"layout_mode": _move_mode,
		"button_scale": _button_scale,
		"button_alpha": default_button_alpha,
	}

func apply_layout_config(config: Dictionary) -> void:
	# 更新当前布局：来自运行时 HUD 或其它模块，保持兼容接口。
	# 注意：旧版这里会拿配置里的 dpad_center 把摇杆基座/球强行摆到某个写死的坐标，
	# 那会覆盖编辑器里摆好的位置，已删除 —— 位置一律以 layout 里的值为准。
	if config.has("layout"):
		_default_button_positions = config["layout"]
		_apply_layout_to_buttons()
