# Scripts/GameScenes/GroundParallaxController.gd
extends Node2D
## 地面背景视差跟随控制器（3×3 复制平铺版）
##
## 摆放公式（对参考点是纯函数，不含任何历史状态）：
##   pattern_origin = reference * parallax_ratio + auto_scroll_phase + pattern_offset
##   grid_center    = pattern_origin 上离 reference 最近的格点（格距 = 单块背景尺寸）
##
## 为什么这样写：
##   1) 旧实现依赖“入口锚点 + 换格阈值 + 大幅跳变重锚”三套历史状态，任何一处状态切换
##      （相机与玩家参考切换、超距重锚、多格级联）都会把网格摆到“非格点”位置 →
##      表现为某一帧或几帧背景错位叠加（错误帧闪现）。纯函数摆放不存在这种跳变。
##   2) 同一房间无论从哪个门进入，背景相位只由相机所在世界坐标决定 → 多门进入背景一致。
##   3) 换格只在相机跨过半格时发生，且位移恒等于“整块尺寸”，视觉上完全无缝。
##
## parallax_ratio 语义：背景图案原点跟随参考点的比例。
##   0 = 背景固定在世界上（看起来随镜头一起流动，像“近景”）
##   1 = 背景完全跟随参考点（看起来几乎静止，像“远景”）
## auto_scroll_enabled 打开后图案原点随时间持续漂移，实现“玩家静止时云也在动”的动态背景。

## 目标房间 ID；为空时自动向上查找父级 Room 节点。
@export var target_room_id: String = ""

## 单张背景 Sprite2D 引用（九宫格以它为模板复制）。
@export var source_background: Sprite2D = null

## 视差系数（X 水平、Y 垂直）。
@export var parallax_ratio: Vector2 = Vector2(0.2, 0.05)

## 图案相位偏移（像素）：用于给不同房间/图层微调背景落点。
@export var pattern_offset: Vector2 = Vector2.ZERO

## 是否优先使用主相机中心作为跟随参考（关闭则用玩家坐标）。
@export var use_camera_center: bool = true

## ── 自动移动（动态背景云）──
@export_category("自动移动")
## 是否启用自动移动（玩家静止时背景也持续漂移）
@export var auto_scroll_enabled: bool = false
## 自动移动速度（像素/秒，方向即漂移方向）
@export var auto_scroll_speed: Vector2 = Vector2(6.0, 0.0)

## 自动移动累积相位（像素）
var _auto_scroll_phase: Vector2 = Vector2.ZERO
## 单块背景的世界尺寸
var _tile_size: Vector2 = Vector2(512.0, 288.0)
## 九宫格偏移坐标集合
var _tile_offsets: Array[Vector2i] = []
## 缓存的 9 张 Sprite2D（key = 偏移坐标）
var _tiles: Dictionary = {}
## 克隆体挂载的父节点
var _clone_parent: Node2D = null
## 解析后的目标房间 ID
var _resolved_room_id: String = ""
## 当前房间是否激活该控制器
var _is_active_room: bool = false
## 当前可见性状态（避免每帧重复写 visible）
var _visible_applied: bool = false


## 初始化：解析房间、构建九宫格，并立即按当前参考点摆放一次。
func _ready() -> void:
	_resolved_room_id = _resolve_target_room_id()
	if not is_instance_valid(source_background):
		push_error("GroundParallaxController: source_background 未绑定")
		return
	_clone_parent = source_background.get_parent() as Node2D
	if not is_instance_valid(_clone_parent):
		_clone_parent = self
	## 关闭背景 Sprite 的物理插值：本控制器在 _process 中已按“渲染时刻的相机位置”精确摆放，
	## 若再让引擎在物理帧之间插值这些 Sprite，就会出现背景与相机不同步的错位帧。
	source_background.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_tile_size = _resolve_tile_size()
	_build_tile_offsets()
	_build_nine_tiles()
	_connect_room_loaded_signal()
	_refresh_active_state()
	## 摆放是参考点的纯函数，不需要等待相机就位：构建完立刻对齐，
	## 避免“首帧露一次错位背景 / 背景暂时消失”的闪烁。
	_update_placement(0.0)
	_set_tiles_visible(_is_active_room)
	_visible_applied = _is_active_room


## 每帧：仅在本房间激活时按参考点摆放九宫格。
func _process(delta: float) -> void:
	_refresh_active_state()
	if not _is_active_room:
		if _visible_applied:
			_set_tiles_visible(false)
			_visible_applied = false
		return
	if not _visible_applied:
		_set_tiles_visible(true)
		_visible_applied = true
	_update_placement(delta)


## 按参考点摆放九宫格（纯函数：只依赖当前参考点与自动移动相位）
func _update_placement(delta: float) -> void:
	if auto_scroll_enabled:
		_auto_scroll_phase += auto_scroll_speed * delta
	var reference: Vector2 = _get_reference_position()
	var pattern_origin: Vector2 = reference * parallax_ratio + _auto_scroll_phase + pattern_offset
	var center: Vector2 = _nearest_lattice_point(reference, pattern_origin)
	_place_grid(center)


## 求 pattern_origin 格点阵上离 near_point 最近的那个格点（格距 = 单块尺寸）
func _nearest_lattice_point(near_point: Vector2, origin: Vector2) -> Vector2:
	var tx: float = maxf(_tile_size.x, 1.0)
	var ty: float = maxf(_tile_size.y, 1.0)
	return Vector2(
		origin.x + roundf((near_point.x - origin.x) / tx) * tx,
		origin.y + roundf((near_point.y - origin.y) / ty) * ty
	)


## 兼容入口：Door / RoomManager 切房前会调用。
## 纯函数摆放下不需要预对齐（背景相位只由相机世界坐标决定），保留空实现以免调用方报错。
func prepare_entry_anchor(_entry_world_pos: Vector2) -> void:
	pass


## 房间切换回调：切换激活状态并立即对齐一次。
func _on_room_loaded(new_room_id: String, _previous_room_id: String) -> void:
	_is_active_room = _resolved_room_id == "" or new_room_id == _resolved_room_id
	if _is_active_room:
		## 切房后立刻按当前参考点对齐，避免显示时还停留在旧相位
		_update_placement(0.0)
		_set_tiles_visible(true)
		_visible_applied = true
	else:
		_set_tiles_visible(false)
		_visible_applied = false


## 将 9 张背景按中心位置摆放成 3×3（中心始终落在图案格点上）
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


## 自动解析背景单块尺寸。
func _resolve_tile_size() -> Vector2:
	if not is_instance_valid(source_background):
		return Vector2(512.0, 288.0)
	var base_size: Vector2 = Vector2.ZERO
	if source_background.region_enabled and source_background.region_rect.size.x > 0.0 and source_background.region_rect.size.y > 0.0:
		base_size = source_background.region_rect.size
	elif source_background.texture:
		base_size = source_background.texture.get_size()
	if base_size.x <= 0.0 or base_size.y <= 0.0:
		base_size = Vector2(512.0, 288.0)
	return Vector2(base_size.x * absf(source_background.scale.x), base_size.y * absf(source_background.scale.y))


## 创建不携带控制脚本的 Sprite2D 克隆（复制源背景的所有表现属性）。
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
	## 与源背景一致：关闭物理插值，避免与相机不同步的错位帧
	clone.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	clone.global_position = source_background.global_position + Vector2(
		float(offset.x) * _tile_size.x,
		float(offset.y) * _tile_size.y
	)
	return clone


## 构建九宫格偏移坐标。
func _build_tile_offsets() -> void:
	_tile_offsets.clear()
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			_tile_offsets.append(Vector2i(ox, oy))


## 基于 source_background 复制并缓存 9 张背景。
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


## 获取跟随参考坐标。
## 默认用相机中心（物理上等价于“背景挂在世界坐标上以 ratio 跟随镜头”）。
## 注意 1：必须用“本帧渲染所用”的位置（物理插值开启时为插值后的变换），
##         否则背景会比画面上的相机/角色滞后最多一个物理步 → 表现为随机的错位帧。
## 注意 2：不再做“相机离玩家过远就改用玩家坐标”的回退 —— 那个回退会让参考点来回跳变，
##         也是 Y 轴跟随频繁出现错位帧的根源。仅在死亡演出（相机被刻意冻结）时改用玩家坐标。
func _get_reference_position() -> Vector2:
	if not RoomManager:
		return Vector2.ZERO
	var player := RoomManager.player_ref
	if not is_instance_valid(player):
		return Vector2.ZERO
	if player is Node2D:
		var player_node: Node2D = player as Node2D
		## 死亡演出期间（HP 归零→黑屏前）相机会被冻结以配合死亡流程，
		## 此窗口改以玩家位置跟随，让下坠/滑落动画期间背景也持续响应。
		if player.has_method("is_in_death_state") and player.is_in_death_state():
			return _render_position(player_node)
		if use_camera_center and player.get_viewport():
			var camera := player.get_viewport().get_camera_2d()
			if is_instance_valid(camera):
				return _render_position(camera)
		return _render_position(player_node)
	return Vector2.ZERO


## 取节点“本帧渲染所用”的位置。
## 开启物理插值时引擎用插值后的变换绘制，背景必须用同一个值才能与画面严格对齐。
func _render_position(node: Node2D) -> Vector2:
	if node.has_method("get_global_transform_interpolated"):
		return node.get_global_transform_interpolated().origin
	return node.global_position
