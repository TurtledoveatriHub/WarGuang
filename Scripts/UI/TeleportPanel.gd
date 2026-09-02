extends CanvasLayer

## 传送面板（参考 MapUI 模式，Esc 关闭，互斥打开）
## 层级：99（MapUI=98 之上，GameSetting=100 之下）

signal menu_closed

var source_teleport_id: String = ""

## ── 黑屏效果参数 ──
@export_category("黑屏效果")
## 淡出时长（秒，画面渐黑）
@export var fade_out_duration: float = 0.4
## 黑屏保持时长（秒，全黑期间执行传送逻辑）
@export var black_hold_duration: float = 0.6
## 淡入时长（秒，渐亮恢复画面）
@export var fade_in_duration: float = 0.4

@onready var background: ColorRect = $Background
@onready var panel_root: Node2D = $PanelRoot
@onready var close_btn: TextureButton = $PanelRoot/CloseBtn

@onready var teleport_buttons: Array[TextureButton] = [
	$PanelRoot/Btn1,
	$PanelRoot/Btn3,
	$PanelRoot/Btn4,
]

var _original_modulate: Color
var _canvas_modulate: CanvasModulate
var _owns_pause: bool = false

## 参与开关动画的视觉节点键。注意：Background(ColorRect 暗化层) 不参与动画——
## 打开/关闭时它立即全量出现/消失；只对内容整体 PanelRoot（含面板图、CloseBtn、传送按钮）做缩放/淡入淡出。
const VISUAL_KEYS: Array[String] = ["PanelRoot"]

@export_category("TeleportPanel 开关动画")
## 入场峰值缩放倍率
@export var open_peak_scale_multiplier: float = 1.2
## 入场放大阶段时长（秒）
@export var open_peak_duration: float = 0.2
## 入场峰值停顿时长（秒）
@export var open_peak_hold_duration: float = 0.15
## 入场回落阶段时长（秒）
@export var open_settle_duration: float = 0.18
## 关闭峰值缩放倍率
@export var close_peak_scale_multiplier: float = 1.2
## 关闭放大阶段时长（秒）
@export var close_peak_duration: float = 0.14
## 关闭峰值停顿时长（秒）
@export var close_peak_hold_duration: float = 0.1
## 关闭消失阶段时长（秒）
@export var close_vanish_duration: float = 0.22
## 关闭最小缩放倍率
@export var close_min_scale_multiplier: float = 0.02
## 入场位移距离（像素）
@export var open_drift_distance: float = 16.0
## 退场位移距离（像素）
@export var close_drift_distance: float = 16.0

var _base_visual_scales: Dictionary = {}
var _base_visual_positions: Dictionary = {}
var _base_visual_modulates: Dictionary = {}
var _open_tween: Tween = null
var _close_tween: Tween = null
var _close_fallback_timer: SceneTreeTimer = null
var _closing_started: bool = false
var _closing_finished: bool = false
var _teleport_started: bool = false
## 记录按钮原始 normal 纹理（悬停/按下反馈会临时替换 texture_normal，需据此还原）
var _btn_original_normal: Dictionary = {}


func _ready() -> void:
	layer = 99
	# TeleportPanel 打开时会把游戏置为暂停（见下方 get_tree().paused = true），
	# 因此用 WHEN_PAUSED 是正确的：暂停期间本节点仍会处理，自身补间也能推进。
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	visible = true
	panel_root.visible = true
	background.color = Color(0, 0, 0, 0.85)
	
	close_btn.pressed.connect(_close_panel)
	_btn_original_normal[close_btn.get_instance_id()] = close_btn.texture_normal
	for btn in teleport_buttons:
		_btn_original_normal[btn.get_instance_id()] = btn.texture_normal
	_adjust_lighting()
	_update_buttons()
	_set_game_setting_btn_visible(false)
	
	get_tree().paused = true
	_owns_pause = true
	
	# 开关动画：先在最终可见状态上缓存基准，再播放入场动画（初始帧→放大→停顿→回落）
	_cache_visual_base_states()
	_play_open_animation()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close_panel()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("map"):
		get_viewport().set_input_as_handled()
		return
	# 兜底命中：按钮是 Node2D(PanelRoot) 的子级 Control，某些情况下鼠标路由不可靠。
	# 在 _input 阶段手动命中（_input 先于 GUI 处理，set_input_as_handled 可避免与 pressed 重复触发）。
	_handle_pointer_release(event)

## 鼠标左键 / 触摸释放时，若命中 CloseBtn 或某个可用传送按钮则触发对应逻辑。
func _handle_pointer_release(event: InputEvent) -> void:
	var is_release := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		is_release = not event.pressed
	elif event is InputEventScreenTouch:
		is_release = not event.pressed
	if not is_release:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	if close_btn.get_global_rect().has_point(mouse_pos):
		_close_panel()
		get_viewport().set_input_as_handled()
		return
	for btn in teleport_buttons:
		if btn.visible and not btn.disabled and btn.get_global_rect().has_point(mouse_pos):
			var tid: String = String(btn.get("target_teleport_id"))
			if tid != "":
				_start_teleport(tid)
				get_viewport().set_input_as_handled()
			return


func _set_game_setting_btn_visible(state: bool) -> void:
	var ui = get_tree().get_first_node_in_group("player_ui")
	if ui and "game_setting_button" in ui:
		## 按钮已被 PlayerUI 移动到独立 CanvasLayer，不能通过 get_node 查找
		ui.game_setting_button.visible = state


## 每帧根据指针位置手动驱动按钮的悬停/按下纹理反馈。
## 原因：这些按钮位于 Node2D(PanelRoot) 之下，本项目的 GUI 鼠标路由在其上不可靠
## （点击已由 _handle_pointer_release 兜底），悬停/按下状态也需要手动模拟。
func _process(_delta: float) -> void:
	_update_button_pointer_visuals()

func _update_button_pointer_visuals() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var pointer_down: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	_set_button_pointer_state(close_btn, close_btn.get_global_rect().has_point(mouse_pos), pointer_down)
	for btn in teleport_buttons:
		_set_button_pointer_state(
			btn,
			btn.visible and not btn.disabled and btn.get_global_rect().has_point(mouse_pos),
			pointer_down
		)

## 依据悬停/按下状态临时切换 texture_normal，使 hover/pressed 纹理生效；
## 无悬停时恢复原始 normal 纹理。
func _set_button_pointer_state(btn: TextureButton, hovered: bool, pointer_down: bool) -> void:
	if btn == null:
		return
	var original: Texture2D = _btn_original_normal.get(btn.get_instance_id())
	if original == null:
		return
	var target: Texture2D = original
	if hovered and pointer_down and btn.texture_pressed:
		target = btn.texture_pressed
	elif hovered and btn.texture_hover:
		target = btn.texture_hover
	if btn.texture_normal != target:
		btn.texture_normal = target


## ── 更新按钮状态 ──
func _update_buttons() -> void:
	var activated: Array = TeleportManager.activated
	var available_count: int = 0
	for tid in activated:
		if tid != source_teleport_id:
			available_count += 1
	
	if available_count > teleport_buttons.size():
		push_warning("TeleportPanel: 激活传送阵(%d) > 按钮(%d)" % [available_count, teleport_buttons.size()])
	
	for btn in teleport_buttons:
		var tid: String = ""
		if "target_teleport_id" in btn:
			tid = btn.target_teleport_id
		
		if tid == "" or tid not in activated:
			btn.visible = false
			continue
		
		btn.visible = true
		if tid == source_teleport_id:
			btn.disabled = true
			btn.modulate = Color(0.5, 0.5, 0.5, 1)
		else:
			btn.disabled = false
			btn.modulate = Color(1, 1, 1, 1)
			btn.pressed.connect(_on_teleport_button_pressed.bind(tid), CONNECT_ONE_SHOT)


## ── 传送（参考 Door 的传送效果，但不自动走位）──
func _on_teleport_button_pressed(target_id: String) -> void:
	_start_teleport(target_id)

func _start_teleport(target_id: String) -> void:
	# 防重入：指针兜底与 GUI pressed 都可能触发，只允许执行一次。
	if _teleport_started:
		return
	_teleport_started = true
	## 注意：打开 TeleportPanel 时 get_tree().paused = true
	## FadeManager 设置了 PROCESS_MODE_ALWAYS，其 tween 在暂停态下仍可推进
	
	## 步骤1：淡出 → 黑屏
	await FadeManager.fade_out(fade_out_duration)
	
	## 步骤2：黑屏中关闭面板 + 执行传送（不暴露在黑屏外）
	_restore_lighting()
	get_tree().paused = false
	_owns_pause = false
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	visible = false
	
	## 步骤3：黑屏期间传送（参考 Door 的流程：黑屏持续期间操作场景树安全）
	var data: Dictionary = TeleportManager.get_data(target_id)
	var player := get_tree().get_first_node_in_group("player")
	if data.is_empty() or not player:
		await FadeManager.fade_in(fade_in_duration)
		queue_free()
		return
	
	if player.has_method("lock_control"):
		player.lock_control(999.0, "teleport")
	player.velocity = Vector2.ZERO
	
	var target_room: String = data.get("room_id", "")
	
	if RoomManager and RoomManager.has_method("suppress_player_room_enter"):
		RoomManager.suppress_player_room_enter(0.45)
	
	var tp_pos_raw = data.get("position", Vector2.ZERO)
	var tp_pos: Vector2 = Vector2.ZERO
	if typeof(tp_pos_raw) == TYPE_VECTOR2:
		tp_pos = tp_pos_raw
	elif typeof(tp_pos_raw) == TYPE_ARRAY and tp_pos_raw.size() == 2:
		tp_pos = Vector2(tp_pos_raw[0], tp_pos_raw[1])
	
	if RoomManager and RoomManager.has_method("prepare_room_background_for_entry"):
		RoomManager.prepare_room_background_for_entry(target_room, tp_pos)
	
	RoomManager.load_room(target_room)
	player.global_position = tp_pos
	player.velocity = Vector2.ZERO
	RoomManager.update_camera_limits()
	
	await get_tree().physics_frame
	RoomManager.update_camera_limits()
	
	if player.has_method("sync_camera_after_room_teleport"):
		player.sync_camera_after_room_teleport()
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	
	if player.has_method("lock_control"):
		player.lock_control(0.0, "teleport_end")
	
	## 步骤4：黑屏保持
	if black_hold_duration > 0.0:
		await get_tree().create_timer(black_hold_duration).timeout
	
	## 步骤5：淡入
	await FadeManager.fade_in(fade_in_duration)
	queue_free()


func _close_panel() -> void:
	# 播放退场动画；动画结束（或兜底计时器）后由 _finish_close_panel 统一收尾。
	if _closing_started:
		return
	_closing_started = true
	_play_close_animation()

func _finish_close_panel() -> void:
	if _closing_finished:
		return
	_closing_finished = true
	_restore_lighting()
	get_tree().paused = false
	_owns_pause = false
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	queue_free()

func _visual_node(visual_name: String) -> CanvasItem:
	match visual_name:
		"Background":
			return background
		"PanelRoot":
			return panel_root
	return null

func _for_each_visual_node(callback: Callable) -> void:
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node and is_instance_valid(node):
			callback.call(node_name, node)

func _cache_visual_base_states() -> void:
	# 记录每个视觉节点的基准位姿/透明度，动画以它们为最终落点。
	_base_visual_scales.clear()
	_base_visual_positions.clear()
	_base_visual_modulates.clear()
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		_base_visual_scales[node_name] = node.scale
		_base_visual_positions[node_name] = node.position
		_base_visual_modulates[node_name] = node.modulate

func _set_node_alpha(node: CanvasItem, alpha: float) -> void:
	# ColorRect 改 color.a，其余 CanvasItem 改 modulate.a。
	if node is ColorRect:
		node.color = Color(node.color.r, node.color.g, node.color.b, alpha)
	else:
		node.modulate = Color(node.modulate.r, node.modulate.g, node.modulate.b, alpha)

func _tween_node_alpha(tween: Tween, node: CanvasItem, alpha: float, duration: float) -> PropertyTweener:
	if node is ColorRect:
		return tween.tween_property(node, "color:a", alpha, duration)
	return tween.tween_property(node, "modulate:a", alpha, duration)

## 动画目标透明度：PanelRoot 回到其基准透明度（不透明）。
func _get_target_alpha(visual_name: String) -> float:
	return _base_visual_modulates.get(visual_name, Color(1, 1, 1, 1)).a

func _kill_open_close_tweens() -> void:
	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()
		_open_tween = null
	if _close_tween and _close_tween.is_valid():
		_close_tween.kill()
		_close_tween = null

func _open_total_duration() -> float:
	return open_peak_duration + maxf(open_peak_hold_duration, 0.0) + open_settle_duration

func _close_total_duration() -> float:
	return close_peak_duration + maxf(close_peak_hold_duration, 0.0) + close_vanish_duration

## 入场动画：小尺寸+下方漂移+透明 → 放大到峰值并淡入 → 停顿 → 回落到基准（与 GameSettingScene/MapUI 一致）
func _play_open_animation() -> void:
	_kill_open_close_tweens()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	# 初始帧
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(node_name, node.position)
		node.scale = base_scale * close_min_scale_multiplier
		node.position = Vector2(base_position.x, base_position.y + open_drift_distance)
		_set_node_alpha(node, 0.0)
	# 阶段一：放大到峰值并淡入
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		tween.parallel().tween_property(node, "scale", base_scale * open_peak_scale_multiplier, open_peak_duration)
		_tween_node_alpha(tween.parallel(), node, _get_target_alpha(node_name), open_peak_duration)
	# 峰值停顿
	if open_peak_hold_duration > 0.0:
		tween.chain().tween_interval(open_peak_hold_duration)
	tween.chain()
	# 阶段二：回落到基准
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(node_name, node.position)
		tween.parallel().tween_property(node, "scale", base_scale, open_settle_duration)
		tween.parallel().tween_property(node, "position:y", base_position.y, open_settle_duration)
		_tween_node_alpha(tween.parallel(), node, _get_target_alpha(node_name), open_settle_duration)
	_open_tween = tween

## 退场动画：放大到峰值 → 停顿 → 缩小消失并淡出（结束时/兜底后收尾）
func _play_close_animation() -> void:
	_kill_open_close_tweens()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	# 阶段一：放大到峰值
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		tween.parallel().tween_property(node, "scale", base_scale * close_peak_scale_multiplier, close_peak_duration)
	# 峰值停顿
	if close_peak_hold_duration > 0.0:
		tween.chain().tween_interval(close_peak_hold_duration)
	tween.chain()
	# 阶段二：缩小消失并淡出
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(node_name, node.position)
		tween.parallel().tween_property(node, "scale", base_scale * close_min_scale_multiplier, close_vanish_duration)
		tween.parallel().tween_property(node, "position:y", base_position.y + close_drift_distance, close_vanish_duration)
		_tween_node_alpha(tween.parallel(), node, 0.0, close_vanish_duration)
	tween.finished.connect(_finish_close_panel)
	_close_tween = tween
	# 兜底：即使补间异常不推进，总时长后也强制完成关闭。
	_close_fallback_timer = get_tree().create_timer(_close_total_duration() + 0.1)
	_close_fallback_timer.timeout.connect(_finish_close_panel)

func _exit_tree() -> void:
	# 兜底：任何异常路径下都恢复亮度；若仍持有暂停也一并恢复，避免残留暂停/暗化。
	_restore_lighting()
	if _owns_pause and get_tree() and get_tree().paused:
		get_tree().paused = false
		_owns_pause = false


func _adjust_lighting() -> void:
	if RoomManager and RoomManager.global_canvas_modulate:
		_canvas_modulate = RoomManager.global_canvas_modulate
		_original_modulate = _canvas_modulate.color
		_canvas_modulate.color = Color(
			_original_modulate.r * 0.3,
			_original_modulate.g * 0.3,
			_original_modulate.b * 0.3,
			1.0
		)


func _restore_lighting() -> void:
	if _canvas_modulate and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate
