extends Node

## 地图系统管理器（Autoload）
##
## 职责：
##   - 管理地图打开/关闭状态与 MapUI 场景生命周期
##   - 维护「已探索遮罩」（战争迷雾数据）：玩家走到哪，遮罩上就揭开哪一片
##   - 提供地图整图贴图与权威房间布局数据的统一读取入口
##
## 地图渲染方式（参考《泰拉瑞亚》/《空洞骑士》）：
##   美术画一张覆盖整个世界的整图；运行时按「已探索遮罩」把未去过的地方遮掉，
##   所以玩家只能看到自己走过的那一片，而不是一进房间就看到完整房间。

## 地图开关状态变化
signal map_visibility_changed(is_visible: bool)

## 交互键的 InputMap 动作名（打开地图时要屏蔽它，避免误触发 NPC / 存档点 / 传送点）
const INTERACT_ACTION := "interactive"

## 任务标记发生变化（增 / 删 / 清空）—— MapUI 监听它重建标记层
signal markers_changed()

## 地图是否处于打开状态
var is_map_open: bool = false

## 当前激活的任务标记：id → { "world_pos": Vector2, "icon": Texture2D }
## 不存入存档：读档后应由任务系统按任务状态重新 add_marker。
var _markers: Dictionary = {}

## 打开地图时被暂时拿掉的交互键事件（关闭时原样装回）
var _blocked_interact_events: Array[InputEvent] = []

## 打开地图时的血量快照（之后掉血 = 受伤 → 自动关地图）
var _health_when_opened: int = -1

## 已到达过的房间列表（供后续做「房间名 / 粗略房间色块」层使用）
var visited_rooms: Array = []

## MapUI 实例引用（常驻场景树，关闭时仅隐藏）
var _map_ui_instance: Node = null

## 权威布局数据资源引用
var _layout_data: RoomLayoutData = null

## 已探索遮罩图像（白 = 已探索）
var _reveal_image: Image = null

## 已探索遮罩纹理
var _reveal_texture: ImageTexture = null

## 已按「整房间」方式点亮过的房间 ID（避免重复填色）
var _painted_room_ids: Dictionary = {}

## 是否有尚未上传到纹理的填色改动（用于把多次填色合并成一次纹理上传）
var _reveal_pending_upload: bool = false

## 是否已经至少执行过一次揭示
var _has_revealed: bool = false

## 上一次执行揭示时玩家所在的世界坐标
var _last_reveal_world: Vector2 = Vector2.ZERO

# ════════════════════════════════════════════
# 代码生成地图纹理
# ════════════════════════════════════════════

## 算作「实体地面」的 TileMapLayer 名字前缀。
##   * HiddenTile：未激活时它在游戏里看起来就是地面，地图上也当成地面；
##     一旦被玩家触发激活（脚本会把整层 visible=false），地图上就不再算地面。
##   * BlockTile：和 GroundTile 一样是实体地形，同样要画。
const GROUND_LAYER_PREFIXES: Array[String] = ["Ground", "Block", "Hidden"]

## 房间内门节点所在的父节点名（门用来画相邻房间之间的连线）
const DOOR_CONTAINER_NAME := "Doors"

## 代码生成的地图整图（未探索处全透明）
var _gen_image: Image = null

## 生成贴图的纹理
var _gen_texture: ImageTexture = null

## 生成贴图使用的坐标系签名（比例 / 原点 / 画布尺寸），变了就整张重画
var _gen_signature: String = ""

## 已经画进生成贴图的房间 ID
var _gen_rooms: Dictionary = {}

## 每个已登记房间的实体地面横条：room_id → Array[Rect2]（世界坐标）
var _room_ground_runs: Dictionary = {}

## 每个已登记房间的门：room_id → Array[{ "world_pos": Vector2, "target": String }]
var _room_doors: Dictionary = {}

## 每个已登记房间的特殊标志：room_id → Array[{ "world_pos": Vector2, "size": Vector2i, "color": Color }]
var _room_landmarks: Dictionary = {}

## 玩家真实走过的门：key = room>target@x,y（由 Door.gd 调用 mark_door_used 写入）
var _used_doors: Dictionary = {}
## 已揭开过走廊的门对（避免每次开图重复描一遍）
var _revealed_corridor_keys: Dictionary = {}

## 是否按「整房间」点亮遮罩。
## true = ROOM 模式（一进房间就整块点亮）；false = RADIUS 模式（渐进揭露，默认）。
## 由 MapUI 在 _ready / 开图时下发（_push_reveal_config）。
var room_level_reveal: bool = false


## 取得代码生成的地图整图；没有布局数据时返回 null
func get_generated_map_texture() -> Texture2D:
	if not _prepare_generated_map():
		return null
	return _gen_texture


## 把玩家「当前所在房间」登记进地图（只有房间节点已经在场景树里时才能扫到地面格子）。
## 房间几何是不会变的，所以每个房间只扫一次，重复调用直接跳过。
func bake_current_room(room_id: String) -> void:
	if room_id == "" or _room_ground_runs.has(room_id):
		return
	if RoomManager == null:
		return
	var entry: Variant = RoomManager.rooms.get(room_id)
	if typeof(entry) != TYPE_DICTIONARY:
		return
	var room_node: Node = (entry as Dictionary).get("node")
	if room_node == null or not is_instance_valid(room_node):
		return
	var layout: RoomLayoutData = get_layout_data()
	if layout == null or not _prepare_generated_map():
		return
	_room_ground_runs[room_id] = _collect_ground_runs(room_node, layout, room_id)
	_room_doors[room_id] = _collect_doors(room_node, layout, room_id)
	_room_landmarks[room_id] = _collect_landmarks(room_node, layout, room_id)
	_gen_rooms[room_id] = true
	_redraw_generated_map()


## 重扫「当前还在场景树里、且已经登记过」的房间。
## 用途：捕捉运行时变化（玩家触发隐藏层使其消失）—— 之后地图上不再把它当地面。
## 没有任何变化就不重画（避免每次开图都上传整张贴图）。
func refresh_loaded_rooms() -> void:
	if RoomManager == null:
		return
	var layout: RoomLayoutData = get_layout_data()
	if layout == null:
		return
	var changed: bool = false
	for room_id: Variant in _room_ground_runs.keys():
		var id: String = str(room_id)
		var entry: Variant = RoomManager.rooms.get(id)
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var node: Node = (entry as Dictionary).get("node")
		if node == null or not is_instance_valid(node):
			continue
		var runs: Array = _collect_ground_runs(node, layout, id)
		if runs != _room_ground_runs[id]:
			_room_ground_runs[id] = runs
			changed = true
	if changed:
		_redraw_generated_map()


## 把「已到达过但还没画进地图」的房间补登记：
##   * 房间已经在场景树里 → 直接扫它的地面层
##   * 房间已不在场景树里（读档恢复的已探索房间就是这种）→ 从场景文件实例化一份读一遍，读完立即销毁
## 实例化不会进入场景树，所以房间脚本的 _ready 不会执行。
func bake_pending_visited_rooms() -> void:
	for room_id: Variant in visited_rooms:
		var id: String = str(room_id)
		if _room_ground_runs.has(id):
			continue
		bake_current_room(id)
		bake_room_from_scene(id)


## 从场景文件登记房间（房间当前不在场景树里时使用）
func bake_room_from_scene(room_id: String) -> void:
	if room_id == "" or _room_ground_runs.has(room_id):
		return
	var layout: RoomLayoutData = get_layout_data()
	if layout == null or not _prepare_generated_map():
		return
	var path: String = ""
	if ScenePaths != null and ScenePaths.ROOM_PATHS.has(room_id):
		path = str(ScenePaths.ROOM_PATHS[room_id])
	if path == "" or not ResourceLoader.exists(path):
		return
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var room_node: Node = packed.instantiate()
	if room_node == null:
		return
	_room_ground_runs[room_id] = _collect_ground_runs(room_node, layout, room_id)
	_room_doors[room_id] = _collect_doors(room_node, layout, room_id)
	_room_landmarks[room_id] = _collect_landmarks(room_node, layout, room_id)
	_gen_rooms[room_id] = true
	room_node.free()
	_redraw_generated_map()


## 确保生成贴图存在且坐标系与当前布局一致；坐标系变了就重画整张
func _prepare_generated_map() -> bool:
	var layout: RoomLayoutData = get_layout_data()
	if layout == null:
		return false
	# 原点 / 比例 / 画布尺寸三者必须自洽，否则整张图会错位
	layout.sync_generated_canvas()
	var signature: String = "%s|%s|%s" % [
		str(layout.world_units_per_map_pixel),
		str(layout.map_world_origin),
		str(layout.map_texture_size),
	]
	if _gen_image != null and signature == _gen_signature:
		return true
	_gen_signature = signature
	_gen_image = Image.create(layout.map_texture_size.x, layout.map_texture_size.y, false, Image.FORMAT_RGBA8)
	_gen_image.fill(Color(0, 0, 0, 0))
	_gen_texture = ImageTexture.create_from_image(_gen_image)
	# 坐标系变了：按缓存的房间数据整张重画（比例改动是低频操作，重画完全可以接受）
	_redraw_generated_map()
	return true


## 按「房间底色块 → 实体地面 → 门连线」的顺序重画整张地图
## 顺序不能变：地面必须压在底色块上面，连线又必须压在最上层。
func _redraw_generated_map() -> void:
	if _gen_image == null:
		return
	var layout: RoomLayoutData = get_layout_data()
	if layout == null:
		return
	_gen_image.fill(Color(0, 0, 0, 0))
	for room_id: Variant in _gen_rooms.keys():
		_draw_room_base(layout, str(room_id))
	for room_id: Variant in _gen_rooms.keys():
		var ground_color: Color = layout.get_ground_color(str(room_id))
		var runs: Array = _room_ground_runs.get(str(room_id), [])
		for run: Variant in runs:
			_fill_world_rect(layout, run, ground_color)
	# 特殊标志（存档点 / 传送阵 / 商店……）压在实体地面之上、门连线之下。
	# ★ 每个标志画的是它自己 CollisionShape2D 的**世界矩形**（不是固定尺寸的点阵）；
	#   没有 CollisionShape2D 的子节点（例如纯美术的 Sprite2D）直接不画。
	for room_id: Variant in _gen_rooms.keys():
		for landmark: Variant in _room_landmarks.get(str(room_id), []):
			var entry: Dictionary = landmark
			_fill_world_rect(
				layout,
				entry.get("world_rect", Rect2()),
				entry.get("color", Color.WHITE)
			)
	_draw_used_door_connectors(layout)
	_gen_texture.update(_gen_image)


## 画一个房间的底色块（规整矩形，不做任何边缘处理）。
## ★ 2026-09-27：之前的「毛边啃食」（_ragged_rect_edges）效果不佳，已按要求整体移除。
##   房间在地图上的形状就是它的 room_bounds 矩形。
func _draw_room_base(layout: RoomLayoutData, room_id: String) -> void:
	var world_rect: Rect2 = layout.get_room_world_rect(room_id)
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var ratio: float = maxf(layout.world_units_per_map_pixel, 1.0)
	var pos: Vector2 = (world_rect.position - layout.map_world_origin) / ratio
	var min_px := Vector2i(int(floorf(pos.x)), int(floorf(pos.y)))
	var size_px := Vector2i(
		maxi(int(ceilf(pos.x + world_rect.size.x / ratio)) - min_px.x, 1),
		maxi(int(ceilf(pos.y + world_rect.size.y / ratio)) - min_px.y, 1)
	)
	_safe_fill(Rect2i(min_px, size_px), layout.get_terrain_color(room_id))


## ★ 用 floor/ceil 取「覆盖范围」而不是四舍五入：
##   1 格地形在 1:20 下只有 0.8 像素，四舍五入会让 1 像素宽的墙落到错误的像素上，
##   房间边缘就会出现漏出来的浅色底块（GrassLand4 那种现象）。
##   向外取整保证必然覆盖（最多多盖 1 像素，视觉上不可见）。
func _fill_world_rect(layout: RoomLayoutData, world_rect: Rect2, color: Color) -> void:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var ratio: float = maxf(layout.world_units_per_map_pixel, 1.0)
	var pos: Vector2 = (world_rect.position - layout.map_world_origin) / ratio
	var size: Vector2 = world_rect.size / ratio
	var min_px := Vector2i(int(floorf(pos.x)), int(floorf(pos.y)))
	var max_px := Vector2i(int(ceilf(pos.x + size.x)), int(ceilf(pos.y + size.y)))
	var pixel_size := Vector2i(maxi(max_px.x - min_px.x, 1), maxi(max_px.y - min_px.y, 1))
	_safe_fill(Rect2i(min_px, pixel_size), color)


## 只填画布内的部分（fill_rect 不接受越界矩形，必须自己裁）
func _safe_fill(rect: Rect2i, color: Color) -> void:
	_safe_fill_on(_gen_image, rect, color)


## 在指定 Image 上只填画布内的部分（遮罩 / 生成贴图共用）
func _safe_fill_on(image: Image, rect: Rect2i, color: Color) -> void:
	if image == null:
		return
	var clipped: Rect2i = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	image.fill_rect(clipped, color)


## 扫描房间里的特殊标志容器（ChairSavePoints / TeleportPoints / Shops……），
## 返回 [{ "world_rect": Rect2, "color": Color }]。
func _collect_landmarks(room_node: Node, layout: RoomLayoutData, room_id: String) -> Array:
	var landmarks: Array = []
	_collect_landmarks_recursive(room_node, layout, room_id, layout.get_room_offset(room_id), landmarks)
	return landmarks


## 递归查找标志容器：命中配色表的容器节点，给它下面每个「有 CollisionShape2D」的
## Node2D 子节点记一条「按碰撞体大小得到的矩形」记录。
## ★ 没有碰撞形状的子节点（GrassLandShop 这类纯美术 Sprite2D）直接跳过 —— 不画。
func _collect_landmarks_recursive(node: Node, layout: RoomLayoutData, room_id: String, fallback_base: Vector2, out: Array) -> void:
	for child: Node in node.get_children():
		if child is Node2D and layout.has_landmark_color(child.name):
			var color: Color = layout.get_landmark_color(child.name)
			var container_base: Vector2 = _node_world_pos(child as Node2D, fallback_base)
			for sub: Node in child.get_children():
				if not (sub is Node2D):
					continue
				var world_rect: Rect2 = _landmark_world_rect(sub as Node2D, container_base)
				if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
					continue
				out.append({"world_rect": world_rect, "color": color})
			continue
		_collect_landmarks_recursive(child, layout, room_id, fallback_base, out)


## 标志实例在地图上的世界矩形：直接读它的 CollisionShape2D。
## 拿不到碰撞形状（没有子节点 / shape 为空）时返回空矩形，调用方据此跳过不画。
## 计算方式：形状自身范围 × 形状节点缩放，再加上「形状节点相对标志节点的偏移」，
## 最后按标志节点自己的旋转 / 缩放换算到世界；房间里的标志都是轴对齐摆放，够用。
func _landmark_world_rect(node: Node2D, base_pos: Vector2) -> Rect2:
	var shape_node: CollisionShape2D = _find_collision_shape(node)
	if shape_node == null or shape_node.shape == null:
		return Rect2()
	var shape_rect: Rect2 = shape_node.shape.get_rect()
	var size_local: Vector2 = shape_rect.size * shape_node.scale
	if size_local.x <= 0.0 or size_local.y <= 0.0:
		return Rect2()
	var center_local: Vector2 = shape_node.position + shape_rect.get_center() * shape_node.scale
	var node_pos: Vector2 = _node_world_pos(node, base_pos)
	var world_size := Vector2(absf(size_local.x * node.scale.x), absf(size_local.y * node.scale.y))
	var world_center: Vector2 = node_pos + center_local.rotated(node.rotation) * node.scale
	return Rect2(world_center - world_size * 0.5, world_size)


## 在标志实例里找可用的碰撞形状（先看直接子节点，再往非美术子节点里递归一层层找）
func _find_collision_shape(node: Node) -> CollisionShape2D:
	for child: Node in node.get_children():
		if child is CollisionShape2D:
			var shape_node: CollisionShape2D = child
			if shape_node.shape != null:
				return shape_node
	for child: Node in node.get_children():
		# Sprite2D / AnimatedSprite2D 只是美术，不用往下找
		if child is Sprite2D or child is AnimatedSprite2D:
			continue
		if child is Node:
			var nested: CollisionShape2D = _find_collision_shape(child)
			if nested != null:
				return nested
	return null


## 取节点的世界坐标（不入场景树时按 fallback_base + 本地坐标推算）
func _node_world_pos(node: Node2D, fallback_base: Vector2) -> Vector2:
	if node.is_inside_tree():
		return node.global_position
	return fallback_base + node.position


## 扫描房间里的实体地面层，把格子按「同一行相邻格子」合并成横条，返回世界坐标矩形列表
## 合并是为了把绘制次数从「上万个格子」降到「几百个横条」。
func _collect_ground_runs(room_node: Node, layout: RoomLayoutData, room_id: String) -> Array:
	var runs: Array = []
	var layers_root: Node = room_node.get_node_or_null("TileMapLayers")
	if layers_root == null:
		push_warning("MapManager: 房间 %s 没有 TileMapLayers 节点，地图上不会有地形" % room_id)
		return runs
	var fallback_base: Vector2 = layout.get_room_offset(room_id)
	for child: Node in layers_root.get_children():
		if not (child is TileMapLayer):
			continue
		if not _is_ground_layer(child.name):
			continue
		var layer: TileMapLayer = child
		if layer.tile_set == null:
			continue
		# 已激活的隐藏层不再算地面：
		#   * 在场景树里：HiddenRegionFade 触发后会把整层 visible 置 false（淡出中 a→0）
		#   * 不在场景树里（从场景文件补登记）：_ready 不会执行，要自己查存档记录
		if not layer.visible or layer.modulate.a <= 0.01:
			continue
		if _is_layer_activated_in_save(layer, room_id):
			continue
		var tile_size: Vector2 = Vector2(layer.tile_set.tile_size)
		if tile_size.x <= 0.0 or tile_size.y <= 0.0:
			continue
		var cells: Array[Vector2i] = layer.get_used_cells()
		if cells.is_empty():
			continue
		# 按行分桶：y → 该行的所有 x
		var rows: Dictionary = {}
		for cell: Vector2i in cells:
			var row: Array = rows.get(cell.y, [])
			row.append(cell.x)
			rows[cell.y] = row
		for row_y: Variant in rows.keys():
			var xs: Array = rows[row_y]
			xs.sort()
			var run_start: int = int(xs[0])
			var run_length: int = 1
			for i: int in range(1, xs.size()):
				var x: int = int(xs[i])
				if x == int(xs[i - 1]) + 1:
					run_length += 1
					continue
				runs.append(_make_run_rect(layer, fallback_base, run_start, int(row_y), run_length, tile_size))
				run_start = x
				run_length = 1
			runs.append(_make_run_rect(layer, fallback_base, run_start, int(row_y), run_length, tile_size))
	# room_bounds 之外的地形不画（房间外沿的补墙 / 装饰地形都不属于这张地图）
	# 但房间边缘的精度不重要：按房间 ID 取一个固定的 0~map_edge_tolerance_px 向外放宽，
	# 免得 room_bounds 正好切在墙中间时边缘出现整齐的缺口。
	var bounds_rect: Rect2 = layout.get_room_world_rect(room_id)
	var tolerance_px: int = _room_edge_tolerance_px(layout, room_id)
	if tolerance_px > 0:
		bounds_rect = bounds_rect.grow(float(tolerance_px) * layout.world_units_per_map_pixel)
	if bounds_rect.size.x > 0.0 and bounds_rect.size.y > 0.0:
		var clipped_runs: Array = []
		for run: Variant in runs:
			var clipped: Rect2 = (run as Rect2).intersection(bounds_rect)
			if clipped.size.x > 0.0 and clipped.size.y > 0.0:
				clipped_runs.append(clipped)
		runs = clipped_runs
	return runs


## 每个房间边缘向外放宽多少像素（0~map_edge_tolerance_px）。
## 用房间 ID 的哈希定死，保证同一个房间每次重画结果一致（不会闪烁）。
func _room_edge_tolerance_px(layout: RoomLayoutData, room_id: String) -> int:
	var max_tolerance: int = maxi(layout.map_edge_tolerance_px, 0)
	if max_tolerance <= 0:
		return 0
	return abs(hash(room_id)) % (max_tolerance + 1)


## 该层是否在存档里已被记录为「永久激活消失」（从场景文件补登记时用；
## 在场景树里的层会被 HiddenRegionFade 直接置 visible=false，不需要这条）
func _is_layer_activated_in_save(layer: TileMapLayer, room_id: String) -> bool:
	if Global == null or not Global.has_method("is_hidden_room_activated"):
		return false
	var save_id: String = str(layer.get("save_id"))
	if save_id.strip_edges() == "":
		# 与 HiddenRegionFade._compute_save_id() 保持完全一致
		save_id = room_id + "::" + str(layer.name)
	return bool(Global.call("is_hidden_room_activated", save_id))


## 把「同一行的连续格子」拼成一个世界坐标矩形
func _make_run_rect(layer: TileMapLayer, fallback_base: Vector2, start_x: int, cell_y: int, count: int, tile_size: Vector2) -> Rect2:
	# map_to_local 给的是格子中心，减去半个格子才是左上角
	var local_top_left: Vector2 = layer.map_to_local(Vector2i(start_x, cell_y)) - tile_size * 0.5
	var world_top_left: Vector2 = layer.to_global(local_top_left) if layer.is_inside_tree() else fallback_base + layer.position + local_top_left
	var layer_scale: Vector2 = layer.global_scale if layer.is_inside_tree() else layer.scale
	return Rect2(world_top_left, Vector2(tile_size.x * float(count), tile_size.y) * layer_scale)


## 节点名是否属于「实体地面」层
func _is_ground_layer(node_name: String) -> bool:
	for prefix: String in GROUND_LAYER_PREFIXES:
		if node_name.begins_with(prefix):
			return true
	return false


## 扫描房间里的门，记录它们的目标房间与世界坐标（用来画相邻房间之间的连线）
func _collect_doors(room_node: Node, layout: RoomLayoutData, room_id: String) -> Array:
	var doors: Array = []
	var container: Node = room_node.get_node_or_null(DOOR_CONTAINER_NAME)
	if container == null:
		return doors
	var fallback_base: Vector2 = layout.get_room_offset(room_id)
	for child: Node in container.get_children():
		if not (child is Node2D):
			continue
		var door_node: Node2D = child
		var target_raw: Variant = door_node.get("target_room_id")
		if target_raw == null:
			continue
		var target: String = str(target_raw)
		if target == "" or target == room_id:
			continue
		var world_pos: Vector2 = door_node.global_position if door_node.is_inside_tree() else fallback_base + container.position + door_node.position
		doors.append({"world_pos": world_pos, "target": target})
	return doors


## 画「玩家真实走过」的门连线。
## ★ 唯一条件就是这对门被走过（`mark_door_used` 记录过）—— 其它条件（房间是否已探索、
##   门是否在 room_bounds 内、迷雾是否揭开）全部多余：记录里已经带了两个端点坐标，
##   而且画在贴图里的东西本来就受迷雾遮罩管，没探索到的位置根本看不见。
## 两端会**延伸到各自房间的 room_bounds 边缘**（贴着框、不留缝），宽度 1 像素。
## 两个房间类型不同（地形底色不同）时，中线对半分色，各用自己房间的颜色。
func _draw_used_door_connectors(layout: RoomLayoutData) -> void:
	for key: Variant in _used_doors.keys():
		var record: Variant = _used_doors[key]
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = record
		var from_room: String = str(entry.get("from_room", ""))
		var to_room: String = str(entry.get("to_room", ""))
		if from_room == "" or to_room == "":
			continue
		var from_pos: Vector2 = _to_vector2(entry.get("from_pos", null))
		var to_pos: Vector2 = _to_vector2(entry.get("to_pos", null))
		if from_pos == to_pos:
			continue
		var start_pos: Vector2 = _extend_to_room_bounds(layout.get_room_world_rect(from_room), from_pos)
		var end_pos: Vector2 = _extend_to_room_bounds(layout.get_room_world_rect(to_room), to_pos)
		_draw_connector_line(layout, start_pos, end_pos, layout.get_terrain_color(from_room), layout.get_terrain_color(to_room))


## 兼容存档往返：Vector2 与 [x, y] 两种形式都能还原成 Vector2
func _to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and (value as Array).size() >= 2:
		var arr: Array = value
		return Vector2(float(arr[0]), float(arr[1]))
	return Vector2.ZERO


## 求「房间框上离这扇门最近的一点」：直接把门坐标夹进矩形范围。
## O(1)、不管门在多远都保证连线端正好落在框上 —— 比逐单位步进快得多，
## 也避免了「朝另一扇门方向推」在门位于房间同侧时算错方向、永远碰不到框的坑。
func _extend_to_room_bounds(rect: Rect2, from_pos: Vector2) -> Vector2:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return from_pos
	if rect.has_point(from_pos):
		return from_pos
	return Vector2(
		clampf(from_pos.x, rect.position.x, rect.end.x),
		clampf(from_pos.y, rect.position.y, rect.end.y)
	)


## 门使用记录的键：房间 + 目标房间 + 门的位置（量化到 1 世界像素，避开浮点误差）
func _door_use_key(room_id: String, target_room_id: String, world_pos: Vector2) -> String:
	return "%s>%s@%d,%d" % [room_id, target_room_id, int(roundf(world_pos.x)), int(roundf(world_pos.y))]


## 登记「玩家从这对门走过去了」（由 Door.gd 在传送成功时调用）。
## 两端坐标一起存：画线不依赖房间是否已画进贴图，也可以直接写进存档。
func mark_door_used(room_id: String, target_room_id: String, from_world_pos: Vector2, to_world_pos: Vector2) -> void:
	if room_id == "" or target_room_id == "":
		return
	var key: String = _door_use_key(room_id, target_room_id, from_world_pos)
	if _used_doors.has(key):
		return
	# 位置存成 [x, y] 数组：存档走 JSON 时 Vector2 会丢类型
	_used_doors[key] = {
		"from_room": room_id,
		"to_room": target_room_id,
		"from_pos": [from_world_pos.x, from_world_pos.y],
		"to_pos": [to_world_pos.x, to_world_pos.y],
	}
	# 记录变了就重画一次，否则连线要等到下次开图 / 进房才出现
	_redraw_generated_map()


## 取得「已走过门对」记录（写存档用；只读，不要直接改）
func get_used_doors() -> Dictionary:
	return _used_doors


## 画门连线；两个房间底色不同时在中点对半分色
func _draw_connector_line(layout: RoomLayoutData, from_world: Vector2, to_world: Vector2, from_color: Color, to_color: Color) -> void:
	if from_color.is_equal_approx(to_color):
		_draw_world_line(layout, from_world, to_world, from_color)
		return
	var mid: Vector2 = (from_world + to_world) * 0.5
	_draw_world_line(layout, from_world, mid, from_color)
	_draw_world_line(layout, mid, to_world, to_color)


## 在贴图上画一段世界坐标直线（逐像素推进，宽度 = map_connector_width_px）
func _draw_world_line(layout: RoomLayoutData, from_world: Vector2, to_world: Vector2, color: Color) -> void:
	_paint_world_line_on(_gen_image, layout, from_world, to_world, color, maxi(layout.map_connector_width_px, 1))


## 在任意 Image 上画一段世界坐标直线（生成贴图与已探索遮罩共用）
func _paint_world_line_on(image: Image, layout: RoomLayoutData, from_world: Vector2, to_world: Vector2, color: Color, width: int) -> void:
	if image == null:
		return
	var ratio: float = maxf(layout.world_units_per_map_pixel, 1.0)
	var from_px: Vector2 = (from_world - layout.map_world_origin) / ratio
	var to_px: Vector2 = (to_world - layout.map_world_origin) / ratio
	var delta: Vector2 = to_px - from_px
	var length: float = delta.length()
	if length < 1.0:
		return
	var line_width: int = maxi(width, 1)
	var steps: int = int(ceilf(length))
	for i: int in range(steps + 1):
		var point: Vector2 = from_px + delta * (float(i) / float(steps))
		_safe_fill_on(image, Rect2i(Vector2i(int(roundf(point.x)), int(roundf(point.y))), Vector2i(line_width, line_width)), color)

func _ready() -> void:
	## 先把权威布局数据读进来：地图生成依赖它，
	## 早于第一个房间加载就绪才能保证「进第一个房间时就能画进地图」。
	get_layout_data()
	## 预加载 MapUI 场景，并常驻场景树（关闭时仅隐藏），
	## 这样地图的战争迷雾揭示逻辑在游戏进行中也能持续工作。
	var map_ui_scene: PackedScene = preload("res://Scenes/UI/MapUI.tscn")
	_map_ui_instance = map_ui_scene.instantiate()
	## 关键：地图在游戏进行中打开，必须用 ALWAYS，否则暂停/未暂停时补间都可能不推进。
	_map_ui_instance.process_mode = Node.PROCESS_MODE_ALWAYS
	## Autoload 初始化阶段父节点正在装配子节点，直接 add_child 会被拒绝，必须延迟。
	get_tree().root.add_child.call_deferred(_map_ui_instance)

## 切换地图开/关
func toggle_map() -> void:
	if is_map_open:
		close_map()
	else:
		open_map()

## 打开地图
## 注意：**不锁玩家操作**（玩家仍然可以跑跳），只屏蔽交互键 U，
## 避免看地图时误触发 NPC / 存档点 / 传送点。
func open_map() -> void:
	if is_map_open or _map_ui_instance == null:
		return
	# 开图前把「已到达过但还没画进地图」的房间补上（早于布局数据就绪时进入的房间会被落到这里）
	bake_pending_visited_rooms()
	# 重扫仍在场景树里的房间：捕捉隐藏层被激活之类的运行时变化（没变化就不重画）
	refresh_loaded_rooms()
	is_map_open = true
	# 关图期间累积的遮罩改动在这里一次性上传（见 reveal_for_player）
	flush_reveal_texture()
	_health_when_opened = _read_player_health()
	_watch_player_health()
	_block_interact_action()
	if _map_ui_instance.has_method("open"):
		_map_ui_instance.open()
	map_visibility_changed.emit(true)

## 关闭地图
func close_map() -> void:
	if not is_map_open:
		return
	is_map_open = false
	_restore_interact_action()
	if _map_ui_instance != null and _map_ui_instance.has_method("close"):
		_map_ui_instance.close()
	map_visibility_changed.emit(false)


## 屏蔽交互键：暂存并清空 InputMap 里 interactive 的按键事件。
## 为什么不能用「在自己 _input 里 set_input_as_handled」：
## 很多交互物（NPC / 告示牌 / 矿车等）是在 _process 里轮询
## `Input.is_action_just_pressed("interactive")` 的，set_input_as_handled 拦不住它们；
## 直接摘掉按键事件才对所有消费者生效。
func _block_interact_action() -> void:
	_restore_interact_action()
	if not InputMap.has_action(INTERACT_ACTION):
		return
	for event: InputEvent in InputMap.action_get_events(INTERACT_ACTION):
		_blocked_interact_events.append(event)
	InputMap.action_erase_events(INTERACT_ACTION)


## 把交互键原样装回
func _restore_interact_action() -> void:
	if _blocked_interact_events.is_empty():
		return
	if InputMap.has_action(INTERACT_ACTION):
		InputMap.action_erase_events(INTERACT_ACTION)
		for event: InputEvent in _blocked_interact_events:
			InputMap.action_add_event(INTERACT_ACTION, event)
	_blocked_interact_events.clear()


# ════════════════════════════════════════════════════════════
# 任务标记（动态层）
# ════════════════════════════════════════════════════════════

## 新增 / 更新一个任务标记。world_pos 是世界坐标（不是地图像素）。
## 同一个 id 重复调用会直接覆盖（方便任务进度更新时挪位置）。
func add_marker(id: StringName, world_pos: Vector2, icon: Texture2D) -> void:
	if id == StringName(""):
		return
	_markers[id] = {"world_pos": world_pos, "icon": icon}
	markers_changed.emit()


## 移除一个任务标记
func remove_marker(id: StringName) -> void:
	if not _markers.has(id):
		return
	_markers.erase(id)
	markers_changed.emit()


## 清空全部任务标记（例如换章节 / 重开）
func clear_markers() -> void:
	if _markers.is_empty():
		return
	_markers.clear()
	markers_changed.emit()


## 取得全部任务标记（只读用途，不要直接改）
func get_markers() -> Dictionary:
	return _markers


## 取得 PlayerUI（血量信号的宿主）
func _get_player_ui() -> Node:
	if get_tree() == null:
		return null
	return get_tree().get_first_node_in_group("player_ui")


## 读当前血量；读不到返回 -1
func _read_player_health() -> int:
	var ui: Node = _get_player_ui()
	if ui != null and ui.has_method("get_health"):
		return int(ui.call("get_health"))
	if Global != null:
		return int(Global.player_current_health)
	return -1


## 监听玩家血量变化（只在打开地图时挂上，回调自己会判断 is_map_open）
func _watch_player_health() -> void:
	var ui: Node = _get_player_ui()
	if ui == null or not ui.has_signal("health_changed"):
		return
	var callback := Callable(self, "_on_player_health_changed")
	if not ui.is_connected("health_changed", callback):
		ui.connect("health_changed", callback)


## 玩家掉血 → 自动关掉地图（对标空洞骑士：地图不挡伤害）
func _on_player_health_changed(new_health: int) -> void:
	if not is_map_open:
		return
	# 只有「比打开地图时更低」才算受伤；回血 / 存档回满 / 读档都不算
	if _health_when_opened < 0 or new_health >= _health_when_opened:
		return
	close_map()

## 登记玩家到达过的房间
func mark_room_visited(room_id: String) -> void:
	if room_id == "":
		return
	# 切房后允许立刻揭示一次
	reset_reveal_throttle()
	# 代码生成地图：把刚进入的房间画进地图贴图（每个房间只扫一次，代价很小）
	bake_current_room(room_id)
	if visited_rooms.has(room_id):
		return
	visited_rooms.append(room_id)
	# 房间级揭示（仅 ROOM 模式）：一进房间就把它整块点亮（空洞骑士式）。
	# RADIUS 模式（默认）下**不能**这么做 —— 否则一进房间就会看到完整房间，
	# 那个模式的揭露完全由 MapUI 每帧按玩家半径推进。
	if room_level_reveal:
		reveal_room(room_id)
		flush_reveal()

## 房间是否已到达过
func is_room_visited(room_id: String) -> bool:
	return visited_rooms.has(room_id)

## 获取全部到达过的房间
func get_visited_rooms() -> Array:
	return visited_rooms

## 获取权威房间布局数据
func get_layout_data() -> RoomLayoutData:
	if _layout_data == null and ResourceLoader.exists(LAYOUT_DATA_PATH):
		var loaded: Resource = load(LAYOUT_DATA_PATH)
		if loaded is RoomLayoutData:
			_layout_data = loaded
	return _layout_data

## 权威布局数据资源路径
const LAYOUT_DATA_PATH := "res://Assets/Configs/RoomLayoutData.tres"

## 获取地图整图贴图（唯一来源：代码生成整图）
## 手绘整图已彻底废弃，这里不再有任何美术贴图回退。
func get_map_texture() -> Texture2D:
	return get_generated_map_texture()

## 确保已探索遮罩尺寸指定尺寸（尺寸变化时重建并清空）
func ensure_reveal_mask(size: Vector2i) -> void:
	var safe_size := Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	if _reveal_image != null and _reveal_image.get_size() == safe_size:
		return
	# 尺寸变了（美术换了更大的纹理）：保留旧内容的重叠部分，避免玩家探索进度被白白清空。
	var old_image: Image = _reveal_image
	_reveal_image = Image.create(safe_size.x, safe_size.y, false, Image.FORMAT_RGBA8)
	_reveal_image.fill(Color(0, 0, 0, 1))
	if old_image != null:
		var copy_size := Vector2i(mini(old_image.get_width(), safe_size.x), mini(old_image.get_height(), safe_size.y))
		if copy_size.x > 0 and copy_size.y > 0:
			_reveal_image.blit_rect(old_image, Rect2i(Vector2i.ZERO, copy_size), Vector2i.ZERO)
	_reveal_texture = ImageTexture.create_from_image(_reveal_image)
	_has_revealed = false
	_painted_room_ids.clear()
	_reveal_pending_upload = false

## 揭开「已走过门对」的连线走廊（含房间之间那条缝）。
## ★ 这是门连线在游戏里能被看见的前提：连线本身画在贴图里，
##   但迷雾只揭开玩家所在房间的 bounds，房间之间那一段永远是黑的 → 看起来就像连线消失了。
## 每条记录只会真正描一次（_revealed_corridor_keys 去重），开销可以忽略。
func _reveal_used_door_corridors(layout: RoomLayoutData) -> void:
	if _reveal_image == null:
		return
	var width: int = maxi(layout.map_connector_width_px, 1)
	var painted: bool = false
	for key: Variant in _used_doors.keys():
		var record: Variant = _used_doors[key]
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = record
		var from_room: String = str(entry.get("from_room", ""))
		var to_room: String = str(entry.get("to_room", ""))
		if from_room == "" or to_room == "":
			continue
		var line_key: String = "%s>%s" % [from_room, to_room]
		if _revealed_corridor_keys.has(line_key):
			continue
		var from_pos: Vector2 = _to_vector2(entry.get("from_pos", null))
		var to_pos: Vector2 = _to_vector2(entry.get("to_pos", null))
		if from_pos == to_pos:
			continue
		var start_pos: Vector2 = _extend_to_room_bounds(layout.get_room_world_rect(from_room), from_pos)
		var end_pos: Vector2 = _extend_to_room_bounds(layout.get_room_world_rect(to_room), to_pos)
		# 比连线本身再宽 2 像素：保证连线两端的像素一定落在揭开范围内
		_paint_world_line_on(_reveal_image, layout, start_pos, end_pos, Color(1, 1, 1, 1), width + 2)
		_revealed_corridor_keys[line_key] = true
		painted = true
	if painted:
		_reveal_pending_upload = true


## 房间级揭示：把该房间在地图上的矩形整块点亮（空洞骑士式，边界就是房间边界，天然锐利）
## 只填像素，不上传纹理；连续揭示多个房间后调 flush_reveal() 统一上传。
func reveal_room(room_id: String) -> void:
	if _reveal_image == null or room_id == "":
		return
	if _painted_room_ids.has(room_id):
		return
	_painted_room_ids[room_id] = true
	var layout: RoomLayoutData = get_layout_data()
	if layout == null:
		return
	# 顺带补揭「已走过门对」的连线走廊（含房间之间的缝隙）
	_reveal_used_door_corridors(layout)
	var rect: Rect2 = layout.get_room_map_rect(room_id)
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return
	var image_rect := Rect2i(Vector2i.ZERO, _reveal_image.get_size())
	var target := Rect2i(
		Vector2i(int(floorf(rect.position.x)), int(floorf(rect.position.y))),
		Vector2i(int(ceilf(rect.size.x)), int(ceilf(rect.size.y)))
	).intersection(image_rect)
	if target.size.x <= 0 or target.size.y <= 0:
		return
	_reveal_image.fill_rect(target, Color(1, 1, 1, 1))
	_reveal_pending_upload = true

## 把所有「已到达过的房间」整块点亮（仅 ROOM 模式；打开地图时调用，幂等）
## RADIUS 模式什么都不做 —— 遮罩进度完全由玩家的行走轨迹累积。
func reveal_visited_rooms() -> void:
	if not room_level_reveal:
		return
	for room_id in visited_rooms:
		reveal_room(str(room_id))
	flush_reveal()

## 把挂起的填色改动一次性上传到纹理（没有改动就直接返回，不做无谓的整图上传）
func flush_reveal() -> void:
	if not _reveal_pending_upload:
		return
	if _reveal_image == null:
		return
	if _reveal_texture == null:
		_reveal_texture = ImageTexture.create_from_image(_reveal_image)
	else:
		_reveal_texture.update(_reveal_image)
	_reveal_pending_upload = false


## 把「关图期间累积、还没上传」的遮罩改动刷进纹理（开图时调一次）
func flush_reveal_texture() -> void:
	flush_reveal()

## 获取已探索遮罩纹理（未初始化时为 null）
func get_reveal_texture() -> ImageTexture:
	return _reveal_texture

## 按移动步长节流地揭示玩家周围区域（由 MapUI 每帧驱动）
## allowed_world_rect：只允许揭示的世界矩形（传入「玩家当前所在房间」的范围）——
## 未进入过的房间即便玩家靠近也不会被揭开迷雾。
func reveal_for_player(world_pos: Vector2, allowed_world_rect: Rect2) -> void:
	if _reveal_image == null:
		return
	if allowed_world_rect.size.x <= 0.0 or allowed_world_rect.size.y <= 0.0:
		return
	if _has_revealed and world_pos.distance_to(_last_reveal_world) < reveal_step_world:
		return
	var layout: RoomLayoutData = get_layout_data()
	if layout == null:
		return
	_has_revealed = true
	_last_reveal_world = world_pos
	# ★ 已走过门对的连线走廊（含房间之间那段缝）也要揭开：
	#   迷雾原本只揭当前房间的 bounds，缝隙永远是黑的 → 门连线看起来像消失了。
	_reveal_used_door_corridors(layout)
	var ratio: float = maxf(layout.world_units_per_map_pixel, 1.0)
	var radius_px: float = reveal_radius_world / ratio
	var center_px: Vector2 = layout.world_to_map(world_pos)
	var allowed_px := Rect2(layout.world_to_map(allowed_world_rect.position), allowed_world_rect.size / ratio)
	_paint_reveal_disc(center_px, radius_px, allowed_px)
	# 关图期间遮罩纹理根本没人看：只写 Image，开图时统一刷一次，
	# 省掉「每次揭露都上传一遍整张 4MB 贴图」这笔最大的常驻开销。
	if is_map_open:
		_reveal_texture.update(_reveal_image)
	else:
		_reveal_pending_upload = true

## 清空揭示节流状态（切房时调用，保证进入新房间后立刻揭示一次）
func reset_reveal_throttle() -> void:
	_has_revealed = false

## 玩家周围揭示半径（世界像素），由 MapUI 在 _ready 时下发
var reveal_radius_world: float = 1000.0

## 玩家移动多少世界像素后重新揭示一次，由 MapUI 在 _ready 时下发
var reveal_step_world: float = 40.0

## 在遮罩上画一个圆形揭示区域；超出 allowed_rect 的部分不画（限制在本房间内）
## 实现上逐行求圆的 x 区间、一次 fill_rect 填一整行 ——
## 比逐像素 set_pixel 快约 50 倍（半径 36 时：约 72 次调用 取代 约 4000 次）。
func _paint_reveal_disc(center: Vector2, radius: float, allowed_rect: Rect2) -> void:
	var width: int = _reveal_image.get_width()
	var height: int = _reveal_image.get_height()
	var min_x: int = maxi(int(floorf(maxf(center.x - radius, allowed_rect.position.x))), 0)
	var max_x: int = mini(int(ceilf(minf(center.x + radius, allowed_rect.end.x))), width - 1)
	var min_y: int = maxi(int(floorf(maxf(center.y - radius, allowed_rect.position.y))), 0)
	var max_y: int = mini(int(ceilf(minf(center.y + radius, allowed_rect.end.y))), height - 1)
	if max_x < min_x or max_y < min_y:
		return
	var radius_squared: float = radius * radius
	var white := Color(1, 1, 1, 1)
	for y in range(min_y, max_y + 1):
		# 像素 x 的中心是 x + 0.5，所以区间要按中心算
		var dy: float = float(y) + 0.5 - center.y
		var half_span_squared: float = radius_squared - dy * dy
		if half_span_squared <= 0.0:
			continue
		var half_span: float = sqrt(half_span_squared)
		var row_min: int = maxi(int(ceilf(center.x - half_span - 0.5)), min_x)
		var row_max: int = mini(int(floorf(center.x + half_span - 0.5)), max_x)
		if row_max < row_min:
			continue
		_reveal_image.fill_rect(Rect2i(row_min, y, row_max - row_min + 1, 1), white)

## 清空已探索遮罩（新游戏时调用）
func clear_reveal_mask() -> void:
	if _reveal_image == null:
		return
	_reveal_image.fill(Color(0, 0, 0, 1))
	_reveal_texture.update(_reveal_image)
	_has_revealed = false
	_painted_room_ids.clear()
	_revealed_corridor_keys.clear()
	_reveal_pending_upload = false

## 导出已探索遮罩为 Base64 PNG，用于写入存档
func get_reveal_mask_base64() -> String:
	if _reveal_image == null:
		return ""
	return Marshalls.raw_to_base64(_reveal_image.save_png_to_buffer())

## 从存档恢复已探索遮罩
func load_reveal_mask_base64(encoded: String) -> void:
	# 无论是否恢复成功，都清空「已画房间」记录：
	# 打开地图时会按 visited_rooms 重新描一遍，保证遮罩与已到达房间列表永远一致。
	_painted_room_ids.clear()
	_reveal_pending_upload = false
	if encoded == "":
		return
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw(encoded)) != OK:
		push_warning("MapManager: 已探索遮罩数据损坏，已忽略")
		return
	_reveal_image = image
	_reveal_texture = ImageTexture.create_from_image(_reveal_image)
	_has_revealed = false

## 从存档恢复地图状态
func load_save_data(data: Dictionary) -> void:
	visited_rooms = _to_string_array(data.get("visited_rooms", []))
	load_reveal_mask_base64(str(data.get("map_reveal_mask", "")))
	# 恢复「已走过门对」：不恢复的话重开游戏后地图上的门连线会全部消失
	var doors_raw: Variant = data.get("used_map_doors", {})
	_used_doors = doors_raw if doors_raw is Dictionary else {}
	_redraw_generated_map()

## 重置地图状态（新游戏时调用）
func reset_state() -> void:
	visited_rooms.clear()
	_used_doors.clear()
	close_map()
	# close_map 在「本来就没开着」时会提前返回，所以这里再兜底把交互键装回去
	_restore_interact_action()
	clear_markers()
	clear_reveal_mask()

## 把存档中的通用数组安全转换为字符串数组
func _to_string_array(source: Variant) -> Array:
	var result: Array = []
	if source is Array:
		for item in source:
			result.append(str(item))
	return result
