extends Node2D

## 目标房间 ID；为空时自动向上查找父级 Room 节点。
@export var target_room_id: String = ""

## 单张背景 Sprite2D 引用，支持 Inspector 拖拽绑定。
@export var source_background: Sprite2D = null

## 视差系数（X 水平、Y 垂直），数值越小背景移动越慢。
@export var parallax_ratio: Vector2 = Vector2(0.2, 0.05)

## 换格缓冲值（像素），防止在格子边界反复切换。
var switch_buffer: Vector2 = Vector2(50.0, 30.0)

## 是否优先使用主相机中心作为跟随参考。
var use_camera_center: bool = true

# ——— 运行时状态 ———

## ## 源背景的父节点，克隆体挂载于此。
var _clone_parent: Node2D = null

## ## 入口锚点：首次跟随时锁定为参考位置（相机/玩家位置），所有背景共用同一锚点。
## ## 核心原则：entry_anchor = 参考位置(相机/玩家)，不是 source_background 的编辑器位置。
var _entry_anchor: Vector2 = Vector2.ZERO

## ## 基准参考位：等于 _entry_anchor。ref_delta = 相机 - 入口锚点，
## ## 即相机相对参考位的绝对位移，保证所有背景网格中心对齐到相机。
var _base_reference: Vector2 = Vector2.ZERO

## ## 当前中心格索引。
var _center_cell: Vector2i = Vector2i.ZERO

## ## 单块背景的世界坐标尺寸。
var _tile_size: Vector2 = Vector2.ZERO

## ## 是否已完成首次跟随初始化。
var _follow_ready: bool = false

## ## _entry_anchor 是否已锁定。
var _entry_anchor_locked: bool = false

## ## 是否待处理 Door 传入的入场锚点。
var _has_pending_entry_anchor: bool = false
var _pending_entry_anchor: Vector2 = Vector2.ZERO

## ## 9 宫格偏移坐标集合。
var _tile_offsets: Array[Vector2i] = []

## ## 缓存的 9 张 Sprite2D，key 为偏移坐标。
var _tiles: Dictionary = {}

## ## 解析后的目标房间 ID。
var _resolved_room_id: String = ""

## ## 当前房间是否激活该控制器。
var _is_active_room: bool = false


## 初始化控制器：解析房间、构建 9 宫格、连接房间信号。
func _ready() -> void:
	_resolved_room_id = _resolve_target_room_id()
	if not is_instance_valid(source_background):
		push_error("GroundParallaxController: source_background 未绑定")
		return
	_clone_parent = source_background.get_parent() as Node2D
	if not is_instance_valid(_clone_parent):
		_clone_parent = self
	_build_tile_offsets()
	_tile_size = _resolve_tile_size()
	_build_nine_tiles()
	_connect_room_loaded_signal()
	_refresh_active_state()
	## 隐藏九宫格直到初始化完成，避免黑屏外暴露编辑器位置
	_set_tiles_visible(false)
	## 直接尝试初始化（此时可能 RoomManager 未就绪，失败则由 _process 重试）
	_try_initialize_follow()


## 每帧：仅在玩家处于本房间时按相机/玩家坐标做视差跟随。
func _process(_delta: float) -> void:
	_refresh_active_state()
	if not _is_active_room:
		_follow_ready = false
		_set_tiles_visible(false)
		return
	if not _follow_ready:
		_try_initialize_follow()
		if _follow_ready:
			## 初始化成功后立即显示（此时网格已对齐到参考位）
			_set_tiles_visible(true)
		return
	var reference: Vector2 = _get_reference_position()
	var reference_delta: Vector2 = reference - _base_reference
	## 大幅跳变（复活/切房传送等）时直接以新参考为中心重锚，避免逐格追赶造成长时间“不响应”。
	var snap_span: float = maxf(_tile_size.x, _tile_size.y) * 3.0
	if snap_span <= 0.0:
		snap_span = 768.0
	if reference_delta.length_squared() > snap_span * snap_span:
		_entry_anchor = reference
		_base_reference = reference
		_center_cell = Vector2i.ZERO
		reference_delta = Vector2.ZERO
	var parallax_offset: Vector2 = reference_delta * parallax_ratio
	## 换格：while前向（安全，cell增加后条件自动放松），if后向（防级联）
	_update_center_cell(reference_delta)
	var center_world: Vector2 = _entry_anchor + Vector2(
		float(_center_cell.x) * _tile_size.x,
		float(_center_cell.y) * _tile_size.y
	) + parallax_offset
	_place_grid(center_world)


## 预对齐接口：Door 在切房前调用。
func prepare_entry_anchor(entry_world_pos: Vector2) -> void:
	_has_pending_entry_anchor = true
	_pending_entry_anchor = entry_world_pos
	_follow_ready = false
	_center_cell = Vector2i.ZERO
	_set_tiles_visible(false)


## 房间切换回调。
## 注意：不重置 _center_cell（由 _update_center_cell 根据当前 ref_delta 自动纠正）。
func _on_room_loaded(new_room_id: String, _previous_room_id: String) -> void:
	var should_activate := _resolved_room_id == "" or new_room_id == _resolved_room_id
	_is_active_room = should_activate
	if _is_active_room:
		_apply_pending_entry_anchor_if_any(true)
		_try_initialize_follow()
		if _follow_ready:
			_set_tiles_visible(true)
	else:
		_set_tiles_visible(false)


## 初始化入口锚点 & 基准位。
## 
## 核心逻辑：
##   1. _entry_anchor = 玩家位置（所有实例获得同一值）
##      理由：玩家始终在正确位置（从保存数据/场景放置还原），相机可能因 lerp 延迟而不在。
##   2. _base_reference = _entry_anchor
##      使 ref_delta = 相机 - 玩家位置（非「相机 - 初始化时相机位置」），
##      避免相机未就位时锁了 (0,0) 导致 ref_delta 巨跳。
##   3. 相机-玩家距离保护：>100px 时不初始化（确保 ref_delta 不大幅跳变）。
## 
## 多背景一致性：所有 GroundParallaxController 实例在 `_is_reference_ready_for_room()`
## 通过后的同一个 _process 帧中先后调用此函数。它们看到的玩家位置相同，
## 因此 _entry_anchor 相同，所有背景网格初始中心一致。
func _try_initialize_follow() -> void:
	if not _is_active_room:
		return
	if not _is_reference_ready_for_room():
		return
	var player := RoomManager.player_ref
	if not is_instance_valid(player) or not (player is Node2D):
		return
	var player_pos: Vector2 = (player as Node2D).global_position
	## 相机-玩家距离保护：相机超过 1.5 个 tile_size 远时暂缓初始化
	## （确保相机基本就位，避免 (0,0) 处锁位导致 ref_delta 巨跳）
	var reference := _get_reference_position()
	var max_dist_sq: float = maxf(_tile_size.x, _tile_size.y) * 1.5
	max_dist_sq *= max_dist_sq
	if reference.distance_squared_to(player_pos) > max_dist_sq:
		return
	if not _entry_anchor_locked:
		if _has_pending_entry_anchor:
			_entry_anchor = _pending_entry_anchor
		else:
			_entry_anchor = player_pos
		_entry_anchor_locked = true
	_base_reference = _entry_anchor
	_center_cell = Vector2i.ZERO
	_place_grid(_entry_anchor)
	_follow_ready = true


## 将 9 张背景按中心位置实时摆放成 3×3。
func _place_grid(center_world_pos: Vector2) -> void:
	for offset in _tile_offsets:
		var tile: Sprite2D = _tiles.get(offset, null) as Sprite2D
		if not is_instance_valid(tile):
			continue
		tile.global_position = center_world_pos + Vector2(
			float(offset.x) * _tile_size.x,
			float(offset.y) * _tile_size.y
		)


## 切换 9 张背景可见性。
func _set_tiles_visible(visible_value: bool) -> void:
	for offset in _tile_offsets:
		var tile: Sprite2D = _tiles.get(offset, null) as Sprite2D
		if is_instance_valid(tile):
			tile.visible = visible_value


## 换格逻辑：基于调整后的 ref_delta（乘以 (1-parallax_ratio)）。
## 
## 核心问题：直接用 ref_delta 判断换格会产生累积误差。
## 
## 原因：center_world = entry + cell×tile + ref×ratio
##       camera       = entry + ref
##       gap = center - camera = cell×tile - ref×(1-ratio)
## 
## 若 cell 基于 raw ref 计算（ref > cell×tile + tile/2×...），
## 当 cell 增大时 gap 随 cell×tile×ratio 线性增长，最终网格脱离相机。
## 且比率越大脱离越快（解释了高 parallax 背景提前换格更严重）。
## 
## 修复：用 adjusted_ref = ref×(1-ratio) 判断换格：
##       gap = cell×tile - adjusted_ref
##       cell 基于 adjusted_ref 计算 → gap 不随 cell 增长 →不累积。
## 
## 阈值含义：角色在相邻格内移动半格 + switch_buffer 后才换格。
## 注意：阈值中不再包含 tile×ratio（已在 adjusted_ref 中处理）。
func _update_center_cell(reference_delta: Vector2) -> void:
	if _tile_size.x <= 0.0 or _tile_size.y <= 0.0:
		return
	## 修复核心：调整 ref_delta 排除视差偏移影响
	var adjusted_x: float = reference_delta.x * (1.0 - parallax_ratio.x)
	var adjusted_y: float = reference_delta.y * (1.0 - parallax_ratio.y)
	## 阈值 = 半格 + switch_buffer（不再包含 tile×ratio）
	var threshold_x: float = _tile_size.x * 0.5 + switch_buffer.x
	var threshold_y: float = _tile_size.y * 0.5 + switch_buffer.y
	while adjusted_x > (float(_center_cell.x) * _tile_size.x + threshold_x):
		_center_cell.x += 1
	if adjusted_x < (float(_center_cell.x) * _tile_size.x - threshold_x):
		_center_cell.x -= 1
	while adjusted_y > (float(_center_cell.y) * _tile_size.y + threshold_y):
		_center_cell.y += 1
	if adjusted_y < (float(_center_cell.y) * _tile_size.y - threshold_y):
		_center_cell.y -= 1


## 自动解析背景单块尺寸。
func _resolve_tile_size() -> Vector2:
	if not is_instance_valid(source_background):
		return Vector2(512.0, 288.0)
	var base_size := Vector2.ZERO
	if source_background.region_enabled and source_background.region_rect.size.x > 0.0 and source_background.region_rect.size.y > 0.0:
		base_size = source_background.region_rect.size
	elif source_background.texture:
		base_size = source_background.texture.get_size()
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		base_size = Vector2(512.0, 288.0)
	return Vector2(base_size.x * absf(source_background.scale.x), base_size.y * absf(source_background.scale.y))


## 如果房间加载时已收到入场锚点，立刻把 3×3 网格放到门附近。
func _apply_pending_entry_anchor_if_any(force_finalize: bool = false) -> void:
	if not _has_pending_entry_anchor:
		return
	_entry_anchor = _pending_entry_anchor
	_entry_anchor_locked = true
	_center_cell = Vector2i.ZERO
	_place_grid(_entry_anchor)
	if force_finalize:
		_base_reference = _entry_anchor
		_follow_ready = true
	_has_pending_entry_anchor = false


## 创建不携带控制脚本的 Sprite2D 克隆。
func _create_tile_clone(offset: Vector2i) -> Sprite2D:
	var clone := Sprite2D.new()
	clone.texture = source_background.texture
	clone.centered = source_background.centered
	clone.offset = source_background.offset
	clone.flip_h = source_background.flip_h
	clone.flip_v = source_background.flip_v
	clone.region_enabled = source_background.region_enabled
	clone.region_rect = source_background.region_rect
	clone.texture_filter = source_background.texture_filter
	clone.texture_repeat = source_background.texture_repeat
	clone.modulate = source_background.modulate
	clone.scale = source_background.scale
	clone.rotation = source_background.rotation
	clone.z_index = source_background.z_index
	clone.z_as_relative = source_background.z_as_relative
	clone.self_modulate = source_background.self_modulate
	clone.visible = source_background.visible
	clone.global_position = source_background.global_position + Vector2(
		float(offset.x) * _tile_size.x,
		float(offset.y) * _tile_size.y
	)
	return clone


## 构建 9 宫格偏移坐标。
func _build_tile_offsets() -> void:
	_tile_offsets.clear()
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			_tile_offsets.append(Vector2i(ox, oy))


## 基于 source_background 复制并缓存 9 宫格实例。
func _build_nine_tiles() -> void:
	_tiles.clear()
	if not is_instance_valid(source_background):
		push_error("GroundParallaxController: source_background 未绑定")
		return
	for offset in _tile_offsets:
		if offset == Vector2i.ZERO:
			_tiles[offset] = source_background
			continue
		var clone := _create_tile_clone(offset)
		clone.name = "%s_Clone_%d_%d" % [source_background.name, offset.x, offset.y]
		_clone_parent.add_child(clone)
		_tiles[offset] = clone
	_place_grid(source_background.global_position)


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


## 解析目标房间。
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


## 判断参考对象是否已落入目标房间。
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


## 获取跟随参考坐标。
## 死亡/复活等控制锁期间相机可能不跟随玩家（相机离玩家过远），此时回退用玩家坐标，
## 保证背景始终随玩家响应；相机追近后自动恢复用相机中心做平滑视差。
func _get_reference_position() -> Vector2:
	if not RoomManager:
		return Vector2.ZERO
	var player := RoomManager.player_ref
	if not is_instance_valid(player):
		return Vector2.ZERO
	if player is Node2D:
		var player_pos: Vector2 = (player as Node2D).global_position
		# 死亡演出期间（HP 归零→黑屏前）相机会被“冻结”在固定位置以配合死亡流程，
		# 若仍以相机中心为参考背景就会静止。此窗口改以玩家位置跟随，
		# 让死亡动画（下坠/滑落等）期间背景也持续响应；不触碰相机-重生同步链路。
		if player.has_method("is_in_death_state") and player.is_in_death_state():
			return player_pos
		if use_camera_center and player.get_viewport():
			var camera := player.get_viewport().get_camera_2d()
			if is_instance_valid(camera):
				var tile_max: float = maxf(_tile_size.x, _tile_size.y)
				if tile_max <= 0.0:
					tile_max = 256.0
				if camera.global_position.distance_squared_to(player_pos) <= (tile_max * 2.0) * (tile_max * 2.0):
					return camera.global_position
		return player_pos
	return Vector2.ZERO
