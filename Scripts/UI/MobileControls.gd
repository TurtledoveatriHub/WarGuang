# MobileControls.gd
extends CanvasLayer
class_name MobileControls

## 移动端虚拟按键控制器
## 自动检测移动端并显示虚拟按键，将触摸输入映射为 Input 动作
## 每个键是一个 Area2D（圆形碰撞），同时响应鼠标和触摸事件
## 使用方法：添加到 MainGameScene 作为子节点即可自动生效
##
## PC 测试：按 Ctrl+M 强制显示/隐藏虚拟按键
##
## ====== 未来 SettingsScene 集成接口 ======
## - get_layout_config() -> Dictionary 获取当前布局
## - apply_layout_config(config: Dictionary) 应用布局
## - layout_mode: int 切换布局模式（DPAD/JOYSTICK）
## - rebuild_buttons() 重建所有按钮

## ==================== 布局模式枚举 ====================

## 布局模式
enum LayoutMode {
	DPAD = 0,       ## 十字键布局（当前默认）
	JOYSTICK = 1,   ## 圆形虚拟摇杆布局
}

## ==================== 导出变量（可在 Inspector 中编辑） ====================

## 布局模式（0=十字键, 1=虚拟摇杆）
@export var layout_mode: LayoutMode = LayoutMode.DPAD:
	set(v):
		layout_mode = v
		if is_inside_tree():
			rebuild_buttons()

## 按钮全局透明度（0~1）
@export var button_alpha: float = 0.25:
	set(v):
		button_alpha = v
		if is_inside_tree():
			_refresh_visuals()
## 按钮按下时透明度
@export var button_pressed_alpha: float = 0.5
## 按钮背景色
@export var button_color: Color = Color(1, 1, 1):
	set(v):
		button_color = v
		if is_inside_tree():
			_refresh_visuals()
## 按钮文字颜色
@export var label_color: Color = Color(1, 1, 1, 0.75):
	set(v):
		label_color = v
		if is_inside_tree():
			_refresh_visuals()
## 按钮文字大小
@export var label_font_size: int = 16:
	set(v):
		label_font_size = v
		if is_inside_tree():
			_refresh_visuals()

## （可选）自定义按钮贴图
@export var custom_textures: Array[Texture2D] = []
## 按下态贴图（可选）
@export var custom_textures_pressed: Array[Texture2D] = []

## ==================== 内部变量 ====================

## 是否为移动端（自动检测）
var _is_mobile: bool:
	get:
		return DisplayServer.is_touchscreen_available()

## 是否强制显示虚拟按键（PC测试用）
## 参数名加 p_ 前缀避免与 CanvasLayer.visible 属性冲突
var force_show: bool = false

## 按钮节点映射
var _button_areas: Dictionary = {}   ## action_name -> Area2D
var _button_bgs: Dictionary = {}     ## action_name -> ColorRect/TextureRect
var _button_labels: Dictionary = {}  ## action_name -> Label

## 可见性控制
var _should_show: bool = false

## 鼠标跟踪（用于 PC 测试的滑动过渡）
var _mouse_pressed: bool = false
var _mouse_active_action: String = ""

## 触摸跟踪（用于移动端的滑动过渡）
var _active_touches: Dictionary = {}  ## touch_index(int) -> action_name(String)

## 按钮布局配置（基于 1280x720 视口）
## 这些值可在运行中修改，调用 rebuild_buttons() 生效
var dpad_center: Vector2 = Vector2(80.0, 560.0)
var dpad_spacing: float = 70.0
var dpad_btn_size: float = 55.0

var action_region_center: Vector2 = Vector2(1120.0, 570.0)
var jump_size: float = 90.0
var action_size: float = 60.0

## 按钮定义列表（可被 apply_layout_config 替换）
var _button_defs: Array[Dictionary] = []

## ==================== 公共接口（供 SettingsScene 调用） ====================

## 获取当前布局配置（供 SettingsScene 读取和修改）
func get_layout_config() -> Dictionary:
	return {
		"layout_mode": layout_mode,
		"dpad_center": dpad_center,
		"dpad_spacing": dpad_spacing,
		"dpad_btn_size": dpad_btn_size,
		"action_region_center": action_region_center,
		"jump_size": jump_size,
		"action_size": action_size,
		"button_alpha": button_alpha,
		"button_pressed_alpha": button_pressed_alpha,
		"button_color": button_color,
		"label_color": label_color,
		"label_font_size": label_font_size,
	}

## 应用布局配置（SettingsScene 调整后调用）
func apply_layout_config(config: Dictionary) -> void:
	if config.has("layout_mode"):
		layout_mode = config["layout_mode"] as LayoutMode
	if config.has("dpad_center"):
		dpad_center = config["dpad_center"] as Vector2
	if config.has("dpad_spacing"):
		dpad_spacing = config["dpad_spacing"] as float
	if config.has("dpad_btn_size"):
		dpad_btn_size = config["dpad_btn_size"] as float
	if config.has("action_region_center"):
		action_region_center = config["action_region_center"] as Vector2
	if config.has("jump_size"):
		jump_size = config["jump_size"] as float
	if config.has("action_size"):
		action_size = config["action_size"] as float
	if config.has("button_alpha"):
		button_alpha = config["button_alpha"] as float
	if config.has("button_pressed_alpha"):
		button_pressed_alpha = config["button_pressed_alpha"] as float
	if config.has("button_color"):
		button_color = config["button_color"] as Color
	if config.has("label_color"):
		label_color = config["label_color"] as Color
	if config.has("label_font_size"):
		label_font_size = config["label_font_size"] as int
	rebuild_buttons()

## 切换布局模式（0=十字键, 1=虚拟摇杆）
func set_layout_mode(mode: LayoutMode) -> void:
	layout_mode = mode
	rebuild_buttons()

## 强制显示/隐藏虚拟按键（PC测试用）
func set_visible_override(p_visible: bool) -> void:
	force_show = p_visible
	_update_visibility()

## 切换显示状态
func toggle_visibility() -> void:
	force_show = not force_show
	_update_visibility()

## 检查当前是否可见
func is_controls_visible() -> bool:
	return _should_show

## 重建所有按钮（布局/大小改变后调用）
func rebuild_buttons() -> void:
	_cleanup_all_buttons()
	_build_button_defs()
	_create_all_buttons()
	_update_visibility()

## ==================== 生命周期 ====================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 200

	_build_button_defs()
	_create_all_buttons()
	_update_visibility()
	get_viewport().size_changed.connect(_on_viewport_size_changed)

func _exit_tree() -> void:
	_cleanup_all_buttons()

func _input(event: InputEvent) -> void:
	## PC 调试快捷键：Ctrl+M
	if not _is_mobile:
		if event is InputEventKey and event.keycode == KEY_M and event.ctrl_pressed and event.is_pressed() and not event.is_echo():
			toggle_visibility()
			get_viewport().set_input_as_handled()
			return

	if not visible:
		return

	## ===== PC 鼠标处理 =====
	if not _is_mobile:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_mouse_pressed = true
				var hit_action: String = _hit_test_action(event.position)
				if hit_action != "":
					_mouse_active_action = hit_action
					_press_action(hit_action)
			else:
				_mouse_pressed = false
				if _mouse_active_action != "":
					_release_action(_mouse_active_action)
					_mouse_active_action = ""
			get_viewport().set_input_as_handled()
			return

		if event is InputEventMouseMotion and _mouse_pressed:
			var hit_action: String = _hit_test_action(event.position)
			if hit_action != "" and hit_action != _mouse_active_action:
				if _mouse_active_action != "":
					_release_action(_mouse_active_action)
				_mouse_active_action = hit_action
				_press_action(hit_action)
			elif hit_action == "" and _mouse_active_action != "":
				_release_action(_mouse_active_action)
				_mouse_active_action = ""
			get_viewport().set_input_as_handled()
			return

	## ===== 移动端触摸处理 =====
	if _is_mobile:
		if event is InputEventScreenTouch:
			var touch_idx: int = event.index
			if event.pressed:
				var hit_action: String = _hit_test_action(event.position)
				if hit_action != "":
					_active_touches[touch_idx] = hit_action
					_press_action(hit_action)
			else:
				if _active_touches.has(touch_idx):
					var action: String = _active_touches[touch_idx]
					_release_action(action)
					_active_touches.erase(touch_idx)

		if event is InputEventScreenDrag:
			var touch_idx: int = event.index
			if _active_touches.has(touch_idx):
				var current_action: String = _active_touches[touch_idx]
				var hit_action: String = _hit_test_action(event.position)
				if hit_action != "" and hit_action != current_action:
					_release_action(current_action)
					_active_touches[touch_idx] = hit_action
					_press_action(hit_action)

## ==================== 按钮定义构建 ====================

func _build_button_defs() -> void:
	match layout_mode:
		LayoutMode.DPAD:
			_build_dpad_defs()
		LayoutMode.JOYSTICK:
			_build_joystick_defs()

## 十字键布局定义
func _build_dpad_defs() -> void:
	_button_defs = [
		{"action": "left",          "label": "◀", "pos": Vector2(dpad_center.x - dpad_spacing, dpad_center.y),               "size": dpad_btn_size, "is_dpad": true},
		{"action": "right",         "label": "▶", "pos": Vector2(dpad_center.x + dpad_spacing, dpad_center.y),               "size": dpad_btn_size, "is_dpad": true},
		{"action": "up",            "label": "▲", "pos": Vector2(dpad_center.x, dpad_center.y - dpad_spacing),               "size": dpad_btn_size, "is_dpad": true},
		{"action": "down",          "label": "▼", "pos": Vector2(dpad_center.x, dpad_center.y + dpad_spacing),               "size": dpad_btn_size, "is_dpad": true},
		{"action": "jump",          "label": "跳",   "pos": Vector2(action_region_center.x + 80, action_region_center.y - 20), "size": jump_size,   "is_dpad": false},
		{"action": "dash",          "label": "冲",   "pos": Vector2(action_region_center.x - 60, action_region_center.y + 10), "size": action_size, "is_dpad": false},
		{"action": "super_dash",    "label": "超冲", "pos": Vector2(action_region_center.x + 80, action_region_center.y - 160),"size": action_size, "is_dpad": false},
		{"action": "interactive",   "label": "交互", "pos": Vector2(action_region_center.x - 60, action_region_center.y - 170),"size": action_size, "is_dpad": false},
		{"action": "map",           "label": "地图", "pos": Vector2(50, 40),                                                 "size": 45.0,         "is_dpad": false},
		{"action": "dialogue_next", "label": "对话", "pos": Vector2(1180, 40),                                               "size": 45.0,         "is_dpad": false},
	]

## 虚拟摇杆布局定义（预留，后续实现具体摇杆逻辑）
func _build_joystick_defs() -> void:
	## 摇杆模式下，方向键区域替换为一个虚拟摇杆区域
	_button_defs = [
		{"action": "joystick_area", "label": "摇杆", "pos": dpad_center, "size": dpad_btn_size * 2.5, "is_dpad": true, "is_joystick": true},
		{"action": "jump",          "label": "跳",   "pos": Vector2(action_region_center.x + 80, action_region_center.y - 20), "size": jump_size,   "is_dpad": false},
		{"action": "dash",          "label": "冲",   "pos": Vector2(action_region_center.x - 60, action_region_center.y + 10), "size": action_size, "is_dpad": false},
		{"action": "super_dash",    "label": "超冲", "pos": Vector2(action_region_center.x + 80, action_region_center.y - 160),"size": action_size, "is_dpad": false},
		{"action": "interactive",   "label": "交互", "pos": Vector2(action_region_center.x - 60, action_region_center.y - 170),"size": action_size, "is_dpad": false},
		{"action": "map",           "label": "地图", "pos": Vector2(50, 40),                                                 "size": 45.0,         "is_dpad": false},
		{"action": "dialogue_next", "label": "对话", "pos": Vector2(1180, 40),                                               "size": 45.0,         "is_dpad": false},
	]

## ==================== 按钮创建 ====================

func _create_all_buttons() -> void:
	for i in range(_button_defs.size()):
		var def: Dictionary = _button_defs[i]
		var action: String = def["action"]
		## 跳过摇杆区域占位（后续单独实现）
		if def.get("is_joystick", false):
			_create_joystick_area(def)
			continue
		var label: String = def["label"]
		var pos: Vector2 = def["pos"]
		var size: float = def["size"]
		_create_one_button(action, label, pos, size, i)

## 创建一个按钮（Area2D + 碰撞 + ColorRect 背景 + Label）
func _create_one_button(action: String, label_text: String, pos: Vector2, size: float, _index: int) -> void:
	## ---- 顶层：Area2D（接收鼠标和触摸事件） ----
	var area := Area2D.new()
	area.name = "Btn_" + action
	area.position = pos
	add_child(area)

	## ---- 碰撞形状 ----
	var collision := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = size * 0.5
	collision.shape = circle
	area.add_child(collision)

	## ---- 背景视觉 ----
	var bg := ColorRect.new()
	bg.name = "Bg_" + action
	bg.position = Vector2(-size * 0.5, -size * 0.5)
	bg.size = Vector2(size, size)
	bg.color = Color(button_color.r, button_color.g, button_color.b, button_alpha)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(bg)

	## 自定义贴图替换
	if _index < custom_textures.size() and custom_textures[_index] != null:
		_replace_bg_with_texture(area, bg, custom_textures[_index])

	## ---- 文字标签 ----
	var lbl := Label.new()
	lbl.name = "Label_" + action
	lbl.position = Vector2(-size * 0.5, -size * 0.5)
	lbl.size = Vector2(size, size)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", label_font_size)
	lbl.modulate = label_color
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(lbl)

	## ---- 存储引用 ----
	_button_areas[action] = area
	_button_bgs[action] = bg
	_button_labels[action] = lbl

## 用 TextureRect 替换 ColorRect 背景
func _replace_bg_with_texture(area: Area2D, old_bg: ColorRect, normal_tex: Texture2D) -> void:
	var tex_rect := TextureRect.new()
	tex_rect.name = "Tex_" + old_bg.name.trim_prefix("Bg_")
	tex_rect.position = old_bg.position
	tex_rect.size = old_bg.size
	tex_rect.texture = normal_tex
	tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	area.remove_child(old_bg)
	old_bg.queue_free()
	area.add_child(tex_rect)

	_button_bgs[area.name.trim_prefix("Btn_")] = tex_rect

## 创建虚拟摇杆区域（预留，后续实现具体摇杆行为）
func _create_joystick_area(def: Dictionary) -> void:
	var action: String = def["action"]
	var pos: Vector2 = def["pos"]
	var size: float = def["size"]

	var area := Area2D.new()
	area.name = "Btn_" + action
	area.position = pos
	add_child(area)

	var collision := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = size * 0.5
	collision.shape = circle
	area.add_child(collision)

	var bg := ColorRect.new()
	bg.name = "Bg_" + action
	bg.position = Vector2(-size * 0.5, -size * 0.5)
	bg.size = Vector2(size, size)
	bg.color = Color(button_color.r, button_color.g, button_color.b, button_alpha * 0.5)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(bg)

	var lbl := Label.new()
	lbl.name = "Label_" + action
	lbl.position = Vector2(-size * 0.5, -size * 0.5)
	lbl.size = Vector2(size, size)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.text = def["label"]
	lbl.add_theme_font_size_override("font_size", label_font_size)
	lbl.modulate = label_color
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(lbl)

	_button_areas[action] = area
	_button_bgs[action] = bg
	_button_labels[action] = lbl

## ==================== 清理 ====================

## 清除所有按钮节点
func _cleanup_all_buttons() -> void:
	## 先释放所有按住的按键
	for action in _button_areas.keys():
		Input.action_release(action)
	## 移除所有按钮 Area2D
	for action in _button_areas.keys():
		var area: Area2D = _button_areas[action]
		if is_instance_valid(area) and area.get_parent() == self:
			remove_child(area)
			area.queue_free()
	_button_areas.clear()
	_button_bgs.clear()
	_button_labels.clear()
	_active_touches.clear()
	_mouse_active_action = ""
	_mouse_pressed = false

## 刷新视觉效果（不重建按钮，只更新颜色/文字大小等）
func _refresh_visuals() -> void:
	for action in _button_areas.keys():
		if _button_bgs.has(action):
			var bg = _button_bgs[action]
			if bg is ColorRect:
				bg.color = Color(button_color.r, button_color.g, button_color.b, button_alpha)
		if _button_labels.has(action):
			var lbl: Label = _button_labels[action]
			lbl.add_theme_font_size_override("font_size", label_font_size)
			lbl.modulate = label_color

## ==================== 点击检测 ====================

func _hit_test_action(screen_pos: Vector2) -> String:
	for def in _button_defs:
		var action: String = def["action"]
		if not _button_areas.has(action):
			continue
		var area: Area2D = _button_areas[action]
		if not is_instance_valid(area):
			continue
		var circle_radius: float = def["size"] * 0.5
		var dist: float = area.position.distance_to(screen_pos)
		if dist <= circle_radius:
			return action
	return ""

## ==================== 输入事件处理 ====================

func _press_action(action: String) -> void:
	Input.action_press(action)
	_set_button_highlight(action, true)

func _release_action(action: String) -> void:
	Input.action_release(action)
	_set_button_highlight(action, false)

## ==================== 视觉反馈 ====================

func _set_button_highlight(action: String, highlighted: bool) -> void:
	if not _button_bgs.has(action):
		return
	var bg = _button_bgs[action]
	if highlighted:
		if bg is ColorRect:
			(bg as ColorRect).color = Color(button_color.r, button_color.g, button_color.b, button_pressed_alpha)
		elif bg is TextureRect:
			(bg as TextureRect).modulate = Color(1.5, 1.5, 1.5, 1.0)
	else:
		if bg is ColorRect:
			(bg as ColorRect).color = Color(button_color.r, button_color.g, button_color.b, button_alpha)
		elif bg is TextureRect:
			(bg as TextureRect).modulate = Color(1, 1, 1, 1)

## ==================== 可见性管理 ====================

func _update_visibility() -> void:
	_should_show = force_show or _is_mobile
	visible = _should_show

func _on_viewport_size_changed() -> void:
	pass

## ==================== 工具方法 ====================

## 获取当前活跃按钮数量（调试用）
func get_active_button_count() -> int:
	var count = 0
	for action in _button_areas.keys():
		if Input.is_action_pressed(action):
			count += 1
	return count
