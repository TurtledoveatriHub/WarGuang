extends Node2D

class BackgroundLayerState:
	var source_background: Sprite2D = null
	var clone_parent: Node2D = null
	var parallax_ratio: Vector2 = Vector2(0.2, 0.05)
	var tile_size_override: Vector2 = Vector2.ZERO
	var switch_buffer: Vector2 = Vector2(50.0, 50.0)
	var tile_size: Vector2 = Vector2.ZERO
	var resolved_switch_buffer: Vector2 = Vector2.ZERO
	var follow_ready: bool = false
	var base_reference: Vector2 = Vector2.ZERO
	var entry_anchor: Vector2 = Vector2.ZERO
	var center_cell: Vector2i = Vector2i.ZERO
	var has_pending_entry_anchor: bool = false
	var pending_entry_anchor: Vector2 = Vector2.ZERO
	var tile_offsets: Array[Vector2i] = []
	var tiles: Dictionary = {}

## 目标房间 ID；为空时自动向上查找父级 Room 节点。
@export var target_room_id: String = ""

## 基础背景（中心背景）节点，建议挂在房间内的独立控制器节点上时通过 Inspector 手动拖拽绑定。
var source_background: Sprite2D
## X/Y 视差系数（默认使用“当前参考点 - 入房基线参考点”的差值乘以该系数）。
## 值越小，背景越“远”、移动越慢；值越大，背景越“近”、移动越快。
var parallax_ratio: Vector2 = Vector2(0.2, 0.05)
## 背景单块尺寸覆盖值；留空时自动按背景显示尺寸推导（纹理/区域尺寸 * Sprite2D Scale）。
var tile_size_override: Vector2 = Vector2.ZERO
## 切换到相邻背景格时的缓冲值，默认按背景 Scale 自动放大，避免边界反复切换。
var switch_buffer: Vector2 = Vector2(30.0, 20.0)

## 多层背景节点路径列表；启用后会优先使用这里的多张背景，每层互不影响。
@export var source_background_paths: Array[String] = []
## 多层背景的视差系数列表，按顺序与 source_background_paths 对应。
@export var layer_parallax_ratios: Array[Vector2] = []
## 多层背景的单块尺寸覆盖值列表，按顺序对应 source_background_paths 中的每一层。
## 留空时自动使用全局 tile_size_override。
@export var layer_tile_size_overrides: Array[Vector2] = []
## 多层背景的切换缓冲值列表，按顺序对应 source_background_paths 中的每一层。
## 留空时自动使用全局 switch_buffer。
@export var layer_switch_buffers: Array[Vector2] = []

## 是否优先使用主相机中心作为跟随参考。
var use_camera_center: bool = true

# 解析后的目标房间 ID。
var _resolved_room_id: String = ""
# 解析后的多层背景状态。
var _layers: Array[BackgroundLayerState] = []
# 当前房间是否激活该控制器。
var _is_active_room: bool = false

## 初始化控制器：解析房间、构建 9 宫格、连接房间信号。
func _ready() -> void:
	_resolved_room_id = _resolve_target_room_id()
	_build_layers()
	if _layers.is_empty():
		push_error("NineSliceParallaxBackgroundController 需要绑定至少一张背景")
		return
	_connect_room_loaded_signal()
	_refresh_active_state()
	if _is_active_room:
		_try_initialize_follow()
	else:
		_set_tiles_visible(false)

## 每帧更新：仅在玩家处于本房间时按相机中心做视差跟随。
func _process(_delta: float) -> void:
	if not _is_active_room:
		return
	if not _are_layers_ready():
		_try_initialize_follow()
		return
	var reference: Vector2 = _get_reference_position()
	for layer in _layers:
		if not layer.follow_ready:
			continue
		var reference_delta: Vector2 = reference - layer.base_reference
		_update_center_cell(layer, reference_delta)
		var center_base: Vector2 = layer.entry_anchor + Vector2(float(layer.center_cell.x) * layer.tile_size.x, float(layer.center_cell.y) * layer.tile_size.y)
		var parallax_offset := Vector2(reference_delta.x * layer.parallax_ratio.x, reference_delta.y * layer.parallax_ratio.y)
		var center_world := center_base + parallax_offset
		_place_grid(layer, center_world)

## 预对齐接口：Door 在切房前调用，把目标房间背景锚点对齐到目标门附近。
func prepare_entry_anchor(entry_world_pos: Vector2) -> void:
	for layer in _layers:
		layer.has_pending_entry_anchor = true
		layer.pending_entry_anchor = entry_world_pos
		layer.follow_ready = false
		layer.center_cell = Vector2i.ZERO

## 房间切换回调：进入目标房间时启用并等待玩家落位后初始化，离开则停更。
func _on_room_loaded(new_room_id: String, _previous_room_id: String) -> void:
	var should_activate := _resolved_room_id == "" or new_room_id == _resolved_room_id
	_is_active_room = should_activate
	if _is_active_room:
		for layer in _layers:
			layer.center_cell = Vector2i.ZERO
			_apply_pending_entry_anchor_if_any(layer, true)
		_set_tiles_visible(true)
	else:
		_set_tiles_visible(false)

## 构建多层背景状态。
func _build_layers() -> void:
	_layers.clear()
	var sources: Array[Sprite2D] = _resolve_layer_sources()
	if sources.is_empty():
		return
	for index in range(sources.size()):
		var source := sources[index]
		if not is_instance_valid(source):
			continue
		var layer := BackgroundLayerState.new()
		layer.source_background = source
		layer.clone_parent = source.get_parent() as Node2D
		if not is_instance_valid(layer.clone_parent):
			layer.clone_parent = self
		layer.parallax_ratio = _resolve_layer_parallax_ratio(index)
		layer.tile_size_override = _resolve_layer_tile_size_override(index)
		layer.switch_buffer = _resolve_layer_switch_buffer(index)
		_build_tile_offsets(layer)
		_resolve_layout_metrics(layer)
		_build_nine_tiles(layer)
		_layers.append(layer)

## 尝试完成跟随初始化：确保玩家已经真正进入目标房间。
func _try_initialize_follow() -> void:
	if not _is_active_room:
		return
	if not _is_reference_ready_for_room():
		return
	var reference := _get_reference_position()
	for layer in _layers:
		if not is_instance_valid(layer.source_background):
			continue
		layer.base_reference = reference
		layer.center_cell = Vector2i.ZERO
		if layer.has_pending_entry_anchor:
			layer.entry_anchor = layer.pending_entry_anchor
			layer.has_pending_entry_anchor = false
		else:
			layer.entry_anchor = layer.source_background.global_position
		_place_grid(layer, layer.entry_anchor)
		layer.follow_ready = true

## 将 9 张背景按中心位置实时摆放成 3x3。
func _place_grid(layer: BackgroundLayerState, center_world_pos: Vector2) -> void:
	for offset in layer.tile_offsets:
		var tile: Sprite2D = layer.tiles.get(offset, null) as Sprite2D
		if not is_instance_valid(tile):
			continue
		tile.global_position = center_world_pos + Vector2(float(offset.x) * layer.tile_size.x, float(offset.y) * layer.tile_size.y)

## 切换 9 张背景可见性（离房时停止可见和跟随）。
func _set_tiles_visible(visible_value: bool) -> void:
	for layer in _layers:
		for offset in layer.tile_offsets:
			var tile: Sprite2D = layer.tiles.get(offset, null) as Sprite2D
			if is_instance_valid(tile):
				tile.visible = visible_value

## 根据参考点相对入房基线的位移，更新当前中心格。
## 规则：
## 1) 参考点从 A 进入 B 后，需继续向 B 内部移动至少 switch_buffer 才切到 B。
## 2) 反向返回时同理，形成迟滞，避免在两格交界处来回抖动。
func _update_center_cell(layer: BackgroundLayerState, reference_delta: Vector2) -> void:
	if layer.tile_size.x <= 0.0 or layer.tile_size.y <= 0.0:
		return
	var threshold_x: float = layer.tile_size.x * 0.5 + layer.resolved_switch_buffer.x
	var threshold_y: float = layer.tile_size.y * 0.5 + layer.resolved_switch_buffer.y
	while reference_delta.x > (float(layer.center_cell.x) * layer.tile_size.x + threshold_x):
		layer.center_cell.x += 1
	while reference_delta.x < (float(layer.center_cell.x) * layer.tile_size.x - threshold_x):
		layer.center_cell.x -= 1
	while reference_delta.y > (float(layer.center_cell.y) * layer.tile_size.y + threshold_y):
		layer.center_cell.y += 1
	while reference_delta.y < (float(layer.center_cell.y) * layer.tile_size.y - threshold_y):
		layer.center_cell.y -= 1

## 解析背景显示尺寸与切换缓冲值。
func _resolve_layout_metrics(layer: BackgroundLayerState) -> void:
	layer.tile_size = _resolve_tile_size(layer)
	layer.resolved_switch_buffer = Vector2(absf(layer.switch_buffer.x), absf(layer.switch_buffer.y)) * _resolve_background_scale(layer)

## 自动解析背景单块尺寸：优先覆盖值，其次按纹理/区域尺寸 * Sprite2D Scale。
func _resolve_tile_size(layer: BackgroundLayerState) -> Vector2:
	if layer.tile_size_override.x > 0.0 and layer.tile_size_override.y > 0.0:
		return layer.tile_size_override
	if not is_instance_valid(layer.source_background):
		return Vector2(512.0, 288.0)
	var base_size := Vector2.ZERO
	var background_node := layer.source_background
	if background_node.region_enabled and background_node.region_rect.size.x > 0.0 and background_node.region_rect.size.y > 0.0:
		base_size = background_node.region_rect.size
	elif background_node.texture:
		base_size = background_node.texture.get_size()
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		base_size = Vector2(512.0, 288.0)
	return Vector2(base_size.x * absf(background_node.scale.x), base_size.y * absf(background_node.scale.y))

## 取背景自身的缩放系数，用于把 50px 缓冲同步放大。
func _resolve_background_scale(layer: BackgroundLayerState) -> Vector2:
	if not is_instance_valid(layer.source_background):
		return Vector2.ONE
	var background_node := layer.source_background
	return Vector2(maxf(absf(background_node.scale.x), 0.001), maxf(absf(background_node.scale.y), 0.001))

## 如果房间加载时已经收到了入场锚点，就立刻把 3x3 网格放到门附近，避免先沿用旧布局。
func _apply_pending_entry_anchor_if_any(layer: BackgroundLayerState, force_finalize: bool = false) -> void:
	if not layer.has_pending_entry_anchor:
		return
	layer.entry_anchor = layer.pending_entry_anchor
	layer.center_cell = Vector2i.ZERO
	_place_grid(layer, layer.entry_anchor)
	if force_finalize:
		layer.base_reference = layer.entry_anchor
		layer.follow_ready = true
	layer.has_pending_entry_anchor = false

## 创建不携带控制脚本的 Sprite2D 克隆，只复制视觉属性。
func _create_tile_clone(layer: BackgroundLayerState, offset: Vector2i) -> Sprite2D:
	var clone := Sprite2D.new()
	var background_node := layer.source_background
	clone.texture = background_node.texture
	clone.centered = background_node.centered
	clone.offset = background_node.offset
	clone.flip_h = background_node.flip_h
	clone.flip_v = background_node.flip_v
	clone.region_enabled = background_node.region_enabled
	clone.region_rect = background_node.region_rect
	clone.texture_filter = background_node.texture_filter
	clone.texture_repeat = background_node.texture_repeat
	clone.modulate = background_node.modulate
	clone.scale = background_node.scale
	clone.rotation = background_node.rotation
	clone.z_index = background_node.z_index
	clone.z_as_relative = background_node.z_as_relative
	clone.self_modulate = background_node.self_modulate
	clone.visible = background_node.visible
	clone.global_position = background_node.global_position + Vector2(float(offset.x) * layer.tile_size.x, float(offset.y) * layer.tile_size.y)
	return clone

## 构建 9 宫格偏移坐标。
func _build_tile_offsets(layer: BackgroundLayerState) -> void:
	layer.tile_offsets.clear()
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			layer.tile_offsets.append(Vector2i(ox, oy))

## 基于某层的 source_background 复制并缓存 9 宫格实例。
func _build_nine_tiles(layer: BackgroundLayerState) -> void:
	layer.tiles.clear()
	if not is_instance_valid(layer.source_background):
		push_warning("NineSliceParallaxBackgroundController: 某层 source_background 未绑定")
		return
	for offset in layer.tile_offsets:
		if offset == Vector2i.ZERO:
			layer.tiles[offset] = layer.source_background
			continue
		var clone := _create_tile_clone(layer, offset)
		clone.name = "%s_Clone_%d_%d" % [layer.source_background.name, offset.x, offset.y]
		layer.clone_parent.add_child(clone)
		layer.tiles[offset] = clone

## 解析多层背景源列表。
func _resolve_layer_sources() -> Array[Sprite2D]:
	var sources: Array[Sprite2D] = []
	if not source_background_paths.is_empty():
		for background_path in source_background_paths:
			if background_path == "":
				continue
			var node := get_node_or_null(NodePath(background_path))
			if node is Sprite2D:
				sources.append(node)
			else:
				push_warning("NineSliceParallaxBackgroundController: 无法解析背景节点路径 %s" % background_path)
	elif is_instance_valid(source_background):
		sources.append(source_background)
	return sources

## 解析某层的视差系数。
func _resolve_layer_parallax_ratio(index: int) -> Vector2:
	if not layer_parallax_ratios.is_empty():
		if index < layer_parallax_ratios.size():
			return layer_parallax_ratios[index]
		return layer_parallax_ratios[layer_parallax_ratios.size() - 1]
	return parallax_ratio

## 解析某层的单块尺寸覆盖值。
func _resolve_layer_tile_size_override(index: int) -> Vector2:
	if layer_tile_size_overrides.is_empty():
		return tile_size_override
	if index < layer_tile_size_overrides.size():
		return layer_tile_size_overrides[index]
	return layer_tile_size_overrides[layer_tile_size_overrides.size() - 1]

## 解析某层的切换缓冲值。
func _resolve_layer_switch_buffer(index: int) -> Vector2:
	if layer_switch_buffers.is_empty():
		return switch_buffer
	if index < layer_switch_buffers.size():
		return layer_switch_buffers[index]
	return layer_switch_buffers[layer_switch_buffers.size() - 1]

## 判断所有层是否已完成跟随初始化。
func _are_layers_ready() -> bool:
	if _layers.is_empty():
		return false
	for layer in _layers:
		if not layer.follow_ready:
			return false
	return true

## 连接 RoomManager.room_loaded 信号。
func _connect_room_loaded_signal() -> void:
	if not RoomManager:
		return
	if not RoomManager.has_signal("room_loaded"):
		return
	if not RoomManager.room_loaded.is_connected(_on_room_loaded):
		RoomManager.room_loaded.connect(_on_room_loaded)

## 刷新当前激活状态。
func _refresh_active_state() -> void:
	if not RoomManager:
		_is_active_room = _resolved_room_id == ""
		return
	_is_active_room = _resolved_room_id == "" or RoomManager.current_room == _resolved_room_id

## 解析目标房间：优先导出值，空值则向上查找 Room 节点。
func _resolve_target_room_id() -> String:
	if target_room_id != "":
		return target_room_id
	var current: Node = self
	while current:
		if current.has_method("get_room_data"):
			var room_data: Dictionary = current.get_room_data()
			if room_data.has("id"):
				return str(room_data.id)
		current = current.get_parent()
	return ""

## 判断参考对象是否已落入目标房间，避免 Door 切房中间帧误初始化。
func _is_reference_ready_for_room() -> bool:
	if _resolved_room_id == "":
		return true
	if not RoomManager:
		return true
	if not RoomManager.has_method("get_room_id_by_position"):
		return true
	var player := RoomManager.player_ref
	if not is_instance_valid(player):
		return false
	if not (player is Node2D):
		return false
	var room_id := RoomManager.get_room_id_by_position((player as Node2D).global_position)
	return room_id == _resolved_room_id

## 获取跟随参考坐标：默认主相机中心，回退到玩家坐标。
func _get_reference_position() -> Vector2:
	if not RoomManager:
		return Vector2.ZERO
	var player := RoomManager.player_ref
	if not is_instance_valid(player):
		return Vector2.ZERO
	if use_camera_center and player.get_viewport():
		var camera := player.get_viewport().get_camera_2d()
		if is_instance_valid(camera):
			return camera.global_position
	if player is Node2D:
		return (player as Node2D).global_position
	return Vector2.ZERO
