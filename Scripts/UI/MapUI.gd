extends CanvasLayer

@onready var background: ColorRect = $Background
## 内容根：全屏 Control，pivot 设为画面中心 → 缩放从中心展开（而不是左上角）
@onready var content_root: Control = $ContentRoot
@onready var map_container: Node2D = $ContentRoot/MapContainer
@onready var map_texture: Sprite2D = $ContentRoot/MapContainer/MapTexture
@onready var player_icon: Sprite2D = $ContentRoot/MapContainer/PlayerIcon
@onready var close_btn: TextureButton = $ContentRoot/CloseBtn

@export_category("MapUI 开关动画")
## 暗化倍率：0.3 = 70% 暗
@export_range(0.0, 1.0, 0.01) var darken_multiplier: float = 0.3
## 开场景淡入与退场淡出过渡时长（秒）
@export var transition_duration: float = 0.1
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
## PlayerIcon 更新间隔（秒）
@export_range(0.05, 5.0, 0.05) var player_icon_update_interval: float = 0.2

var is_open: bool = false
var _original_modulate: Color
var _canvas_modulate: CanvasModulate
var _icon_timer: float = 0.0
var _base_visual_scales: Dictionary = {}
var _base_visual_positions: Dictionary = {}
var _base_visual_modulates: Dictionary = {}
## 当前进行中的开/关补间（避免旧补间残留导致状态被卡住）
var _open_tween: Tween = null
var _close_tween: Tween = null
## 开/关动画兜底计时器（即使补间异常不推进，也能按时完成状态切换）
var _open_fallback_timer: SceneTreeTimer = null
var _close_fallback_timer: SceneTreeTimer = null

func _ready() -> void:
	layer = 98
	visible = false
	# 关键修正：地图是在“未暂停”的游戏内打开的，因此必须用 PROCESS_MODE_ALWAYS。
	# 之前用 WHEN_PAUSED 会导致未暂停时本节点不处理，绑定在本节点的补间也从不推进，
	# 表现为“打开只有暗化、内容不显示、关闭不还原亮度”。
	process_mode = Node.PROCESS_MODE_ALWAYS
	background.color = Color(0, 0, 0, 0)
	content_root.visible = false
	close_btn.visible = true
	close_btn.modulate = Color(1, 1, 1, 1)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	close_btn.pressed.connect(_on_close_pressed)
	close_btn.gui_input.connect(_on_close_button_gui_input)
	_cache_visual_base_states()
	# 中心缩放：ContentRoot 为全屏 Control，把 pivot 设到自身中心。
	_update_content_pivot()
	if content_root:
		content_root.resized.connect(_update_content_pivot)

## 让内容围绕其中心缩放（Control.pivot_offset 默认在左上角，需改为尺寸一半）。
func _update_content_pivot() -> void:
	if content_root:
		content_root.pivot_offset = content_root.size * 0.5

func _cache_visual_base_states() -> void:
	_base_visual_scales.clear()
	_base_visual_positions.clear()
	_base_visual_modulates.clear()
	_base_visual_scales["Background"] = background.scale
	_base_visual_scales["ContentRoot"] = content_root.scale
	_base_visual_scales["CloseBtn"] = close_btn.scale
	_base_visual_positions["Background"] = background.position
	_base_visual_positions["ContentRoot"] = content_root.position
	_base_visual_positions["CloseBtn"] = close_btn.position
	_base_visual_modulates["Background"] = background.modulate
	_base_visual_modulates["ContentRoot"] = content_root.modulate
	_base_visual_modulates["CloseBtn"] = close_btn.modulate

## 参与开关动画的视觉节点键。
## 注意：Background(ColorRect 暗化层) 不参与动画——打开/关闭时它立即全量出现/消失，
## 只对内容（ContentRoot + CloseBtn）做缩放/淡入淡出。
const VISUAL_KEYS: Array[String] = ["ContentRoot", "CloseBtn"]

func _visual_node(visual_name: String) -> CanvasItem:
	match visual_name:
		"Background":
			return background
		"ContentRoot":
			return content_root
		"CloseBtn":
			return close_btn
	return null

func _for_each_visual_node(callback: Callable) -> void:
	# 显式引用节点：CloseBtn 位于 ContentRoot 内部，不能用同名子路径查找。
	for node_name: String in VISUAL_KEYS:
		var node := _visual_node(node_name)
		if node and is_instance_valid(node):
			callback.call(node_name, node)

## 终止进行中的开/关补间，避免新旧动画互相覆盖。
func _kill_open_close_tweens() -> void:
	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()
		_open_tween = null
	if _close_tween and _close_tween.is_valid():
		_close_tween.kill()
		_close_tween = null

## 设置节点透明度：ColorRect 必须改 color.a（modulate 混用会让背景层失效），其余 CanvasItem 改 modulate.a
func _set_node_alpha(node: CanvasItem, alpha: float) -> void:
	if node is ColorRect:
		node.color = Color(node.color.r, node.color.g, node.color.b, alpha)
	else:
		node.modulate = Color(node.modulate.r, node.modulate.g, node.modulate.b, alpha)

## 补间节点透明度，返回 PropertyTweener 供 tween.parallel() 链式调用
func _tween_node_alpha(tween: Tween, node: CanvasItem, alpha: float, duration: float) -> PropertyTweener:
	if node is ColorRect:
		return tween.tween_property(node, "color:a", alpha, duration)
	return tween.tween_property(node, "modulate:a", alpha, duration)

## 动画目标透明度：各内容节点恢复到其基准透明度（内容基准均为不透明）。
func _get_target_alpha(node_name: String) -> float:
	return _base_visual_modulates.get(node_name, Color(1, 1, 1, 1)).a

func _play_open_animation() -> void:
	# 与 GameSettingScene 相同的开启动画结构：初始帧直接设置 → 放大并淡入（并行）→
	# 峰值停顿 → 回落到基准（并行）。不 await，结束时与兜底计时器共同保证最终状态。
	_kill_open_close_tweens()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_OUT)
	# 初始帧：小尺寸 + 下方漂移 + 全透明
	for key: String in VISUAL_KEYS:
		var node := _visual_node(key)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(key, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(key, node.position)
		node.scale = base_scale * close_min_scale_multiplier
		node.position = Vector2(base_position.x, base_position.y + open_drift_distance)
		_set_node_alpha(node, 0.0)
	# 阶段一：放大到峰值并淡入
	for key: String in VISUAL_KEYS:
		var node := _visual_node(key)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(key, node.scale)
		tween.parallel().tween_property(node, "scale", base_scale * open_peak_scale_multiplier, open_peak_duration)
		_tween_node_alpha(tween.parallel(), node, _get_target_alpha(key), open_peak_duration)
	# 峰值停顿
	if open_peak_hold_duration > 0.0:
		tween.chain().tween_interval(open_peak_hold_duration)
	tween.chain()
	# 阶段二：回落到基准尺寸/位置/透明度
	for key: String in VISUAL_KEYS:
		var node := _visual_node(key)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(key, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(key, node.position)
		tween.parallel().tween_property(node, "scale", base_scale, open_settle_duration)
		tween.parallel().tween_property(node, "position:y", base_position.y, open_settle_duration)
		_tween_node_alpha(tween.parallel(), node, _get_target_alpha(key), open_settle_duration)
	tween.finished.connect(_ensure_open_final_state)
	_open_tween = tween
	# 兜底：即使补间异常不推进，总时长后仍把内容强制恢复为最终可见状态。
	_open_fallback_timer = get_tree().create_timer(_open_total_duration() + 0.1)
	_open_fallback_timer.timeout.connect(_ensure_open_final_state)

func _play_close_animation() -> void:
	# 与 GameSettingScene 相同的关闭动画结构：放大到峰值（并行）→ 峰值停顿 → 缩小消失并淡出（并行）。
	_kill_open_close_tweens()
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	# 阶段一：放大到峰值
	for key: String in VISUAL_KEYS:
		var node := _visual_node(key)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(key, node.scale)
		tween.parallel().tween_property(node, "scale", base_scale * close_peak_scale_multiplier, close_peak_duration)
	# 峰值停顿
	if close_peak_hold_duration > 0.0:
		tween.chain().tween_interval(close_peak_hold_duration)
	tween.chain()
	# 阶段二：缩小消失并淡出
	for key: String in VISUAL_KEYS:
		var node := _visual_node(key)
		if node == null:
			continue
		var base_scale: Vector2 = _base_visual_scales.get(key, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(key, node.position)
		tween.parallel().tween_property(node, "scale", base_scale * close_min_scale_multiplier, close_vanish_duration)
		tween.parallel().tween_property(node, "position:y", base_position.y + close_drift_distance, close_vanish_duration)
		_tween_node_alpha(tween.parallel(), node, 0.0, close_vanish_duration)
	tween.finished.connect(_apply_closed_state)
	_close_tween = tween
	# 兜底：即使补间异常不推进，也会在总时长后强制隐藏并完成关闭。
	_close_fallback_timer = get_tree().create_timer(_close_total_duration() + 0.1)
	_close_fallback_timer.timeout.connect(_apply_closed_state)

func _input(event: InputEvent) -> void:
	if not is_open or not visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if close_btn.get_global_rect().has_point(get_viewport().get_mouse_position()):
			_on_close_pressed()
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not is_open:
		return
	_icon_timer += delta
	if _icon_timer >= player_icon_update_interval:
		_icon_timer = 0.0
		_update_player_position()

func _get_overlay_alpha_for_darken() -> float:
	return clampf(0.2 + (1.0 - darken_multiplier) * 0.8, 0.0, 1.0)

func open() -> void:
	if is_open:
		return
	is_open = true
	# 关键修正：先在基准状态上恢复并缓存（绝不能在透明度归零后再缓存，
	# 否则所有按钮会以 alpha=0 为基准而永久不可见）。
	_restore_visual_base_states()
	_cache_visual_base_states()
	visible = true
	content_root.visible = true
	close_btn.visible = true
	# 立即就位到最终可见状态：即使补间异常，内容也一定完整显示。
	content_root.modulate = Color(1, 1, 1, 1)
	close_btn.modulate = Color(1, 1, 1, 1)
	background.color = Color(0, 0, 0, _get_overlay_alpha_for_darken())
	_adjust_lighting()
	_update_player_position()
	# 播放入场动画（含兜底）
	_play_open_animation()

## 将视觉节点恢复到 _ready 时缓存的基准状态，防止上一次关闭动画残留的透明/缩放被再次缓存。
func _restore_visual_base_states() -> void:
	_for_each_visual_node(func(node_name: String, node: CanvasItem):
		var base_scale: Vector2 = _base_visual_scales.get(node_name, node.scale)
		var base_position: Vector2 = _base_visual_positions.get(node_name, node.position)
		var base_modulate: Color = _base_visual_modulates.get(node_name, node.modulate)
		node.scale = base_scale
		node.position = base_position
		if node is ColorRect:
			node.color = Color(node.color.r, node.color.g, node.color.b, base_modulate.a)
		else:
			node.modulate = base_modulate
	)

func close() -> void:
	if not is_open:
		# 防御：若历史状态残留了可见地图，强制清理，
		# 避免“打开设置/其他界面时地图消失动画乱入”。
		if visible:
			_apply_closed_state()
		return
	is_open = false
	# 关键修正：立即恢复全局亮度，绝不依赖退场补间 —— 杜绝“关图后仍暗”残留。
	_restore_lighting()
	_play_close_animation()

## 入场兜底：确保打开后内容始终处于最终可见状态（补间异常时也能保证）。
func _ensure_open_final_state() -> void:
	if not is_open:
		return
	content_root.modulate = Color(1, 1, 1, 1)
	close_btn.modulate = Color(1, 1, 1, 1)
	background.color = Color(0, 0, 0, _get_overlay_alpha_for_darken())
	_for_each_visual_node(func(node_name: String, node: CanvasItem):
		node.scale = _base_visual_scales.get(node_name, node.scale)
		node.position = _base_visual_positions.get(node_name, node.position)
	)

## 退场兜底：确保地图最终被完全隐藏。
func _apply_closed_state() -> void:
	if is_open:
		return
	content_root.visible = false
	close_btn.visible = false
	background.color = Color(0, 0, 0, 0)
	visible = false

func _open_total_duration() -> float:
	return open_peak_duration + maxf(open_peak_hold_duration, 0.0) + open_settle_duration

func _close_total_duration() -> float:
	return close_peak_duration + maxf(close_peak_hold_duration, 0.0) + close_vanish_duration

func _exit_tree() -> void:
	# 兜底：任何异常路径下都要恢复全局亮度，避免暗化残留。
	_restore_lighting()

func _on_close_button_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if close_btn.get_global_rect().has_point(get_viewport().get_mouse_position()):
			_on_close_pressed()
			get_viewport().set_input_as_handled()

func _on_close_pressed() -> void:
	MapManager.close_map()

## 暗化场景（与 GameSettingScene 一致）
func _adjust_lighting() -> void:
	if RoomManager and RoomManager.global_canvas_modulate:
		_canvas_modulate = RoomManager.global_canvas_modulate
		_original_modulate = _canvas_modulate.color
		_canvas_modulate.color = Color(
			_original_modulate.r * darken_multiplier,
			_original_modulate.g * darken_multiplier,
			_original_modulate.b * darken_multiplier,
			1.0
		)

func _restore_lighting() -> void:
	if _canvas_modulate and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate

## PlayerIcon 定位（每隔 player_icon_update_interval 秒更新一次）
func _update_player_position() -> void:
	if not player_icon:
		return
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player_icon.position = _world_to_map_position(player.global_position)
		player_icon.visible = true
	else:
		player_icon.visible = false

func _world_to_map_position(world_pos: Vector2) -> Vector2:
	## 占位：后续替换为 MapData 的房间→地图坐标映射
	return world_pos * 0.05

func on_room_discovered(_room_id: String) -> void:
	pass
