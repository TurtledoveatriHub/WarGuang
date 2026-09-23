extends CanvasLayer

## 地图界面
##
## 渲染方式：
##   美术提供「两张覆盖整个世界的整图贴图」——详情版（能看清房间内部结构）与
##   概览版（只保留房间块轮廓）。每个已绘制房间从整图中裁出自己那块矩形显示，
##   因此未绘制房间及其联通通道天然不可见。
##   两张整图与房间布局数据共用同一套世界坐标 / 缩放，所以地图与实机布局永远对齐。
##
## 视野：
##   打开时自动适配全部已绘制房间；滚轮缩放、方向键平移。

@onready var background: ColorRect = $Background
## 内容根：全屏 Control，pivot 设为画面中心 → 缩放从中心展开（而不是左上角）
@onready var content_root: Control = $ContentRoot
@onready var map_container: Node2D = $ContentRoot/MapContainer
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

@export_category("地图视野")
## 自动适配时四周留白的比例（0.9 = 四周各留 5%）
@export_range(0.1, 1.0, 0.01) var fit_padding: float = 0.85
## 高于该缩放值时使用详情版贴图，否则使用概览版贴图
@export var detail_texture_zoom_threshold: float = 0.35
## 最小缩放 = 自动适配缩放 × 该倍率
@export_range(0.05, 1.0, 0.01) var min_zoom_ratio: float = 0.4
## 最大缩放倍率
@export_range(1.0, 20.0, 0.5) var max_zoom_ratio: float = 6.0
## 每格滚轮的缩放倍率
@export_range(1.01, 2.0, 0.01) var zoom_step: float = 1.15
## 方向键平移速度（屏幕像素 / 秒）
@export var pan_speed: float = 600.0
## 未提供美术贴图时，房间占位块的基准透明度
@export_range(0.1, 1.0, 0.05) var placeholder_alpha: float = 0.85

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

## 房间块容器（运行时创建，无需在场景中手工维护）
var _rooms_layer: Node2D = null
## room_id → 房间块节点（Sprite2D 或占位块）
var _room_sprites: Dictionary = {}
## room_id → 占位房间名标签
var _room_labels: Dictionary = {}
## 1×1 白色占位贴图（美术贴图缺失时充当纯色块）
var _placeholder_texture: Texture2D = null
## 世界像素 → 地图像素 的缩放（来自 RoomLayoutData.map_texture_scale）
var _map_scale: float = 0.1
## 当前视野缩放
var _view_zoom: float = 1.0
## 当前视野平移（屏幕像素）
var _view_offset: Vector2 = Vector2.ZERO
## 自动适配得到的缩放值（作为缩放上下限与 LOD 的参考基准）
var _fit_zoom: float = 1.0
## 最小允许缩放
var _min_zoom: float = 0.1
## 最大允许缩放
var _max_zoom: float = 4.0

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
	_ensure_rooms_layer()
	_cache_visual_base_states()
	# 中心缩放：ContentRoot 为全屏 Control，把 pivot 设到自身中心。
	_update_content_pivot()
	if content_root:
		content_root.resized.connect(_update_content_pivot)

## 让内容围绕其中心缩放（Control.pivot_offset 默认在左上角，需改为尺寸一半）。
func _update_content_pivot() -> void:
	if content_root:
		content_root.pivot_offset = content_root.size * 0.5

## 创建房间块容器（只创建一次）
func _ensure_rooms_layer() -> void:
	if _rooms_layer != null and is_instance_valid(_rooms_layer):
		return
	_rooms_layer = Node2D.new()
	_rooms_layer.name = "RoomsLayer"
	map_container.add_child(_rooms_layer)

## 获取 1×1 白色占位贴图
func _get_placeholder_texture() -> Texture2D:
	if _placeholder_texture == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		_placeholder_texture = ImageTexture.create_from_image(image)
	return _placeholder_texture

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

## 滚轮缩放与方向键平移
func _unhandled_input(event: InputEvent) -> void:
	if not is_open or not visible:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(zoom_step, content_root.get_local_mouse_position())
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(1.0 / zoom_step, content_root.get_local_mouse_position())
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not is_open:
		return
	_update_pan(delta)
	_icon_timer += delta
	if _icon_timer >= player_icon_update_interval:
		_icon_timer = 0.0
		_update_player_position()

## 方向键平移视野（不使用 WASD，避免与仍可操控的玩家移动冲突）
func _update_pan(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if direction == Vector2.ZERO:
		return
	_view_offset += direction.normalized() * pan_speed * delta
	_sync_view()

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
	_rebuild_rooms()
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

## 地图房间绘制状态变化时的回调（由 MapManager 调用）
func on_map_rooms_changed(_newly_painted: Array) -> void:
	if not is_open:
		return
	_rebuild_rooms()

## 重建地图上的房间块（只重建已绘制房间，未绘制房间及其通道天然不可见）
func _rebuild_rooms() -> void:
	_clear_room_nodes()
	_ensure_rooms_layer()
	var layout: RoomLayoutData = MapManager.get_layout_data() if MapManager else null
	if layout == null:
		_sync_view()
		return
	_map_scale = layout.map_texture_scale
	var detail_texture: Texture2D = MapManager.get_detail_texture()
	var block_texture: Texture2D = MapManager.get_block_texture()
	for room_id in MapManager.get_painted_rooms():
		_create_room_block(str(room_id), layout, detail_texture, block_texture)
	_compute_fit_view()
	_apply_lod()
	_sync_view()

## 清空所有房间块与标签
func _clear_room_nodes() -> void:
	for room_id in _room_sprites.keys():
		var sprite: Node = _room_sprites[room_id]
		if is_instance_valid(sprite):
			sprite.queue_free()
	for room_id in _room_labels.keys():
		var label: Node = _room_labels[room_id]
		if is_instance_valid(label):
			label.queue_free()
	_room_sprites.clear()
	_room_labels.clear()

## 创建一个房间在地图上的显示块
func _create_room_block(room_id: String, layout: RoomLayoutData, detail_texture: Texture2D, block_texture: Texture2D) -> void:
	var world_rect: Rect2 = layout.get_room_map_region_world(room_id)
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		push_warning("MapUI: 房间 %s 缺少布局数据，无法在地图上显示" % room_id)
		return
	# 世界矩形 → 地图像素矩形（取整避免采样越界）
	var map_position := Vector2(roundf(world_rect.position.x * _map_scale), roundf(world_rect.position.y * _map_scale))
	var map_size := Vector2(maxf(roundf(world_rect.size.x * _map_scale), 1.0), maxf(roundf(world_rect.size.y * _map_scale), 1.0))
	var region := Rect2(map_position, map_size)
	var sprite := Sprite2D.new()
	sprite.name = room_id
	sprite.centered = false
	sprite.position = map_position
	var detail_atlas: Texture2D = _make_atlas(detail_texture, region)
	var block_atlas: Texture2D = _make_atlas(block_texture, region)
	if detail_atlas == null and block_atlas == null:
		# 美术贴图尚未就位：用纯色块占位，并标注房间名，保证逻辑可先行验证
		sprite.texture = _get_placeholder_texture()
		sprite.modulate = _placeholder_color(room_id)
		sprite.scale = map_size
		_create_room_label(room_id, map_position, map_size)
	else:
		sprite.set_meta("detail_texture", detail_atlas)
		sprite.set_meta("block_texture", block_atlas)
		sprite.texture = detail_atlas if detail_atlas != null else block_atlas
	_rooms_layer.add_child(sprite)
	_room_sprites[room_id] = sprite

## 从整图贴图上裁出指定区域；贴图缺失时返回 null
func _make_atlas(source: Texture2D, region: Rect2) -> Texture2D:
	if source == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = source
	atlas.region = region
	atlas.filter_clip = true
	return atlas

## 为占位房间创建名称标签
func _create_room_label(room_id: String, map_position: Vector2, map_size: Vector2) -> void:
	var label := Label.new()
	label.name = room_id + "_Label"
	label.text = room_id
	label.position = map_position
	label.size = map_size
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color(0, 0, 0, 0.85))
	_rooms_layer.add_child(label)
	_room_labels[room_id] = label

## 由房间 ID 派生占位色
func _placeholder_color(room_id: String) -> Color:
	var hue: float = float(hash(room_id) % 360) / 360.0
	var color := Color.from_hsv(hue, 0.45, 0.95, placeholder_alpha)
	return color

## 按当前缩放选择详情版 / 概览版贴图
func _apply_lod() -> void:
	var use_detail: bool = _view_zoom >= detail_texture_zoom_threshold
	for room_id in _room_sprites.keys():
		var sprite: Sprite2D = _room_sprites[room_id]
		if not is_instance_valid(sprite) or not sprite.has_meta("detail_texture"):
			continue
		var detail_texture: Variant = sprite.get_meta("detail_texture")
		var block_texture: Variant = sprite.get_meta("block_texture")
		var chosen: Texture2D = null
		if use_detail and detail_texture is Texture2D:
			chosen = detail_texture
		elif block_texture is Texture2D:
			chosen = block_texture
		elif detail_texture is Texture2D:
			chosen = detail_texture
		if chosen != null:
			sprite.texture = chosen

## 把视野缩放/平移应用到容器
func _sync_view() -> void:
	if map_container == null:
		return
	map_container.scale = Vector2(_view_zoom, _view_zoom)
	map_container.position = _view_offset

## 计算自动适配视野（全部已绘制房间的包围盒居中铺满）
func _compute_fit_view() -> void:
	var layout: RoomLayoutData = MapManager.get_layout_data() if MapManager else null
	if layout == null:
		_view_zoom = 1.0
		_view_offset = Vector2.ZERO
		_fit_zoom = 1.0
		return
	var room_union := Rect2()
	var has_any: bool = false
	for room_id in MapManager.get_painted_rooms():
		var world_rect: Rect2 = layout.get_room_map_region_world(str(room_id))
		if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
			continue
		var map_rect := Rect2(world_rect.position * _map_scale, world_rect.size * _map_scale)
		room_union = map_rect if not has_any else room_union.merge(map_rect)
		has_any = true
	if not has_any:
		_view_zoom = 1.0
		_view_offset = Vector2.ZERO
		_fit_zoom = 1.0
		return
	var view_size: Vector2 = content_root.size
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		view_size = get_viewport().get_visible_rect().size
	_fit_zoom = minf(view_size.x / maxf(room_union.size.x, 1.0), view_size.y / maxf(room_union.size.y, 1.0)) * fit_padding
	_view_zoom = _fit_zoom
	_view_offset = view_size * 0.5 - room_union.get_center() * _fit_zoom
	_min_zoom = _fit_zoom * min_zoom_ratio
	_max_zoom = maxf(_fit_zoom, detail_texture_zoom_threshold) * max_zoom_ratio

## 以屏幕上某点为锚点缩放视野
func _apply_zoom(factor: float, anchor_screen: Vector2) -> void:
	var previous_zoom: float = _view_zoom
	var target_zoom: float = clampf(_view_zoom * factor, _min_zoom, _max_zoom)
	if is_equal_approx(target_zoom, previous_zoom):
		return
	# 保持锚点在容器本地空间中的位置不变
	_view_offset = anchor_screen - (anchor_screen - _view_offset) * (target_zoom / previous_zoom)
	_view_zoom = target_zoom
	_apply_lod()
	_sync_view()

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

## 世界坐标 → 地图容器本地坐标（与房间块共用同一套换算，保证同源）
func _world_to_map_position(world_pos: Vector2) -> Vector2:
	return world_pos * _map_scale
