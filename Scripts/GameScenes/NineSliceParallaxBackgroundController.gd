extends Node2D

## 目标房间 ID；为空时自动向上查找父级 Room 节点。
@export var target_room_id: String = ""
## 基础背景（中心背景）节点，建议挂在房间内的独立控制器节点上时通过 Inspector 手动拖拽绑定。
@export var source_background: Sprite2D
## 背景单块尺寸覆盖值；留空时自动按背景显示尺寸推导（纹理/区域尺寸 * Sprite2D Scale）。
@export var tile_size_override: Vector2 = Vector2.ZERO
## 切换到相邻背景格时的缓冲值，默认按背景 Scale 自动放大，避免边界反复切换。
@export var switch_buffer: Vector2 = Vector2(50.0, 50.0)
## X/Y 视差系数（默认使用“当前参考点 - 入房基线参考点”的差值乘以该系数）。
## 值越小，背景越“远”、移动越慢；值越大，背景越“近”、移动越快。
## 推荐区间：0.00~0.30。超出该区间可能造成明显漂移或眩晕感。
@export var parallax_ratio: Vector2 = Vector2(0.2, 0.05)
## 是否优先使用主相机中心作为跟随参考。
@export var use_camera_center: bool = true

# 解析后的目标房间 ID。
var _resolved_room_id: String = ""
# 实际使用的基础背景节点。
var _source_background: Sprite2D = null
# 当前房间是否激活该控制器。
var _is_active_room: bool = false
# 跟随是否已初始化（防止 Door 流程中 room_loaded 早于玩家落位）。
var _follow_ready: bool = false
# 进入房间时的参考坐标基线。
var _base_reference: Vector2 = Vector2.ZERO
# 解析后的背景单块尺寸（用于 3x3 排布与切格）。
var _tile_size: Vector2 = Vector2.ZERO
# 解析后的切换缓冲值。
var _switch_buffer: Vector2 = Vector2.ZERO
# 入房时中心背景锚点（世界坐标）。
var _entry_anchor: Vector2 = Vector2.ZERO
# 当前离散中心格索引（相对入房锚点，单位为背景块）。
var _center_cell: Vector2i = Vector2i.ZERO
# 是否存在待应用的入房锚点。
var _has_pending_entry_anchor: bool = false
# Door 进入目标房间前预设的锚点位置。
var _pending_entry_anchor: Vector2 = Vector2.ZERO
# 9 宫格偏移缓存（固定 -1..1）。
var _tile_offsets: Array[Vector2i] = []
# 9 宫格背景实例缓存，key 为偏移坐标。
var _tiles: Dictionary = {}

## 初始化控制器：解析房间、构建 9 宫格、连接房间信号。
func _ready() -> void:
	_resolved_room_id = _resolve_target_room_id()
	_source_background = source_background
	if not is_instance_valid(_source_background):
		push_error("NineSliceParallaxBackgroundController 需要在 Inspector 里绑定 source_background")
		return
	_resolve_layout_metrics()
	_build_tile_offsets()
	_build_nine_tiles()
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
	if not _follow_ready:
		_try_initialize_follow()
		return
	var reference: Vector2 = _get_reference_position()
	var reference_delta: Vector2 = reference - _base_reference
	_update_center_cell(reference_delta)
	var center_base: Vector2 = _entry_anchor + Vector2(float(_center_cell.x) * _tile_size.x, float(_center_cell.y) * _tile_size.y)
	var parallax_offset := Vector2(reference_delta.x * parallax_ratio.x, reference_delta.y * parallax_ratio.y)
	var center_world := center_base + parallax_offset
	_place_grid(center_world)

## 预对齐接口：Door 在切房前调用，把目标房间背景锚点对齐到目标门附近。
func prepare_entry_anchor(entry_world_pos: Vector2) -> void:
	_has_pending_entry_anchor = true
	_pending_entry_anchor = entry_world_pos
	_follow_ready = false
	_center_cell = Vector2i.ZERO

## 房间切换回调：进入目标房间时启用并等待玩家落位后初始化，离开则停更。
func _on_room_loaded(new_room_id: String, _previous_room_id: String) -> void:
	var should_activate := _resolved_room_id == "" or new_room_id == _resolved_room_id
	_is_active_room = should_activate
	if _is_active_room:
		_center_cell = Vector2i.ZERO
		_apply_pending_entry_anchor_if_any(true)
		_set_tiles_visible(true)
	else:
		_follow_ready = false
		_set_tiles_visible(false)

## 构建 9 宫格偏移坐标。
func _build_tile_offsets() -> void:
	_tile_offsets.clear()
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			_tile_offsets.append(Vector2i(ox, oy))

## 基于一张 source_background 复制并缓存 9 宫格实例。
func _build_nine_tiles() -> void:
	_tiles.clear()
	if not is_instance_valid(_source_background):
		push_warning("NineSliceParallaxBackgroundController: source_background 未绑定")
		return
	for offset in _tile_offsets:
		if offset == Vector2i.ZERO:
			_tiles[offset] = _source_background
			continue
		var clone := _create_tile_clone(offset)
		clone.name = "%s_Clone_%d_%d" % [_source_background.name, offset.x, offset.y]
		add_child(clone)
		_tiles[offset] = clone

## 尝试完成跟随初始化：确保玩家已经真正进入目标房间。
func _try_initialize_follow() -> void:
	if not _is_active_room:
		return
	if not is_instance_valid(_source_background):
		return
	if not _is_reference_ready_for_room():
		return
	_base_reference = _get_reference_position()
	_center_cell = Vector2i.ZERO
	if _has_pending_entry_anchor:
		_entry_anchor = _pending_entry_anchor
		_has_pending_entry_anchor = false
	else:
		_entry_anchor = _source_background.global_position
	_place_grid(_entry_anchor)
	_follow_ready = true

## 将 9 张背景按中心位置实时摆放成 3x3。
func _place_grid(center_world_pos: Vector2) -> void:
	for offset in _tile_offsets:
		var tile: Sprite2D = _tiles.get(offset, null) as Sprite2D
		if not is_instance_valid(tile):
			continue
		tile.global_position = center_world_pos + Vector2(float(offset.x) * _tile_size.x, float(offset.y) * _tile_size.y)

## 切换 9 张背景可见性（离房时停止可见和跟随）。
func _set_tiles_visible(visible_value: bool) -> void:
	for offset in _tile_offsets:
		var tile: Sprite2D = _tiles.get(offset, null) as Sprite2D
		if is_instance_valid(tile):
			tile.visible = visible_value

## 根据参考点相对入房基线的位移，更新当前中心格。
## 规则：
## 1) 参考点从 A 进入 B 后，需继续向 B 内部移动至少 switch_buffer 才切到 B。
## 2) 反向返回时同理，形成迟滞，避免在两格交界处来回抖动。
func _update_center_cell(reference_delta: Vector2) -> void:
	if _tile_size.x <= 0.0 or _tile_size.y <= 0.0:
		return
	var threshold_x: float = _tile_size.x * 0.5 + _switch_buffer.x
	var threshold_y: float = _tile_size.y * 0.5 + _switch_buffer.y
	while reference_delta.x > (float(_center_cell.x) * _tile_size.x + threshold_x):
		_center_cell.x += 1
	while reference_delta.x < (float(_center_cell.x) * _tile_size.x - threshold_x):
		_center_cell.x -= 1
	while reference_delta.y > (float(_center_cell.y) * _tile_size.y + threshold_y):
		_center_cell.y += 1
	while reference_delta.y < (float(_center_cell.y) * _tile_size.y - threshold_y):
		_center_cell.y -= 1

## 解析背景显示尺寸与切换缓冲值。
func _resolve_layout_metrics() -> void:
	_tile_size = _resolve_tile_size()
	_switch_buffer = Vector2(absf(switch_buffer.x), absf(switch_buffer.y)) * _resolve_background_scale()

## 自动解析背景单块尺寸：优先覆盖值，其次按纹理/区域尺寸 * Sprite2D Scale。
func _resolve_tile_size() -> Vector2:
	if tile_size_override.x > 0.0 and tile_size_override.y > 0.0:
		return tile_size_override
	if not is_instance_valid(_source_background):
		return Vector2(512.0, 288.0)
	var base_size := Vector2.ZERO
	var background_node := _source_background
	if background_node.region_enabled and background_node.region_rect.size.x > 0.0 and background_node.region_rect.size.y > 0.0:
		base_size = background_node.region_rect.size
	elif background_node.texture:
		base_size = background_node.texture.get_size()
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		base_size = Vector2(512.0, 288.0)
	return Vector2(base_size.x * absf(background_node.scale.x), base_size.y * absf(background_node.scale.y))

## 取背景自身的缩放系数，用于把 50px 缓冲同步放大。
func _resolve_background_scale() -> Vector2:
	if not is_instance_valid(_source_background):
		return Vector2.ONE
	var background_node := _source_background
	return Vector2(maxf(absf(background_node.scale.x), 0.001), maxf(absf(background_node.scale.y), 0.001))

## 如果房间加载时已经收到了入场锚点，就立刻把 3x3 网格放到门附近，避免先沿用旧布局。
func _apply_pending_entry_anchor_if_any(force_finalize: bool = false) -> void:
	if not _has_pending_entry_anchor:
		return
	_entry_anchor = _pending_entry_anchor
	_center_cell = Vector2i.ZERO
	_place_grid(_entry_anchor)
	if force_finalize:
		_base_reference = _entry_anchor
		_follow_ready = true
	_has_pending_entry_anchor = false

## 创建不携带控制脚本的 Sprite2D 克隆，只复制视觉属性。
func _create_tile_clone(offset: Vector2i) -> Sprite2D:
	var clone := Sprite2D.new()
	var background_node := _source_background
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
	clone.global_position = background_node.global_position + Vector2(float(offset.x) * _tile_size.x, float(offset.y) * _tile_size.y)
	return clone

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
