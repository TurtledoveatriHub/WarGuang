extends Node

signal room_loaded(room_id: String, previous_room: String)

const CAMERA_LIMIT_DISABLED: int = 10000000
const _ScenePathsScript = preload("res://Scripts/Managers/ScenePaths.gd")
const _RoomLayoutDataPath = preload("res://Assets/Configs/RoomLayoutData.tres")

# 在变量声明部分添加
var global_canvas_modulate: CanvasModulate = null

## 房间数据
var rooms: Dictionary = {}
var current_room: String = ""
var player_ref: Node = null
var suppress_player_enter_until_msec: int = 0

## 按需加载相关
var _room_container: Node = null      # MainGameScene 下的 RoomContainer 节点
var _room_node_cache: Dictionary = {} # room_id → Node（从场景树移除但保留引用）
var _room_packed_cache: Dictionary = {} # room_id → PackedScene（缓存场景文件）

## 颜色状态管理
var room_original_colors: Dictionary = {}  # 房间ID -> 原始颜色（检查器中设置的颜色）
var is_low_health_active: bool = false     # 低血量效果是否激活
var low_health_color: Color = Color.WHITE  # 低血量效果颜色（由Player设置）
var room_camera_trace_last_ms: int = -1000000

func reset_runtime_state() -> void:
	rooms.clear()
	current_room = ""
	player_ref = null
	global_canvas_modulate = null
	suppress_player_enter_until_msec = 0
	room_original_colors.clear()
	is_low_health_active = false
	low_health_color = Color.WHITE
	_room_container = null
	_room_node_cache.clear()
	_room_packed_cache.clear()

## 注册房间
func register_room(room_id: String, room_node: Node, room_data: Dictionary):
	# 确保从房间节点获取正确的颜色
	var room_color = Color.WHITE
	if room_node.has_method("get_room_color"):
		room_color = room_node.get_room_color()
	elif room_node.has_property("room_color"):
		room_color = room_node.room_color

	# 优先使用显式 bounds；若缺失则退化为相机限制矩形，保证按坐标解析房间可用。
	var room_bounds: Rect2 = room_data.get("bounds", Rect2())
	if not room_bounds.has_area() and room_node.has_method("get_camera_limits"):
		room_bounds = room_node.get_camera_limits()
	if not room_bounds.has_area() and room_data.has("bounds_position") and room_data.has("bounds_size"):
		var bounds_position: Vector2 = room_data.get("bounds_position", Vector2.ZERO)
		var bounds_size: Vector2 = room_data.get("bounds_size", Vector2.ZERO)
		if bounds_size.x > 0.0 and bounds_size.y > 0.0:
			room_bounds = Rect2(bounds_position - bounds_size * 0.5, bounds_size)
	
	rooms[room_id] = {
		"node": room_node,
		"bounds": room_bounds,
		"bgm_stream": room_data.get("bgm_stream", null),
		"adjacent": room_data.get("adjacent", []),
		"color": room_color
	}

# RoomManager.gd - 修改 set_global_canvas_modulate 函数
func set_global_canvas_modulate(canvas: CanvasModulate):
	global_canvas_modulate = canvas

func load_room(room_id: String, skip_unload: bool = false):
	if not rooms.has(room_id):
		if not _instantiate_room(room_id):
			push_error("房间不存在且加载失败：" + room_id)
			return
	
	var previous_room: String = current_room
	_debug_room_camera_trace("load_room_begin", {"target_room": room_id, "from_room": current_room})
	
	notify_dynamic_checkpoint_manager_room_change(room_id)
	notify_vignette_effect_room_change()
	if not skip_unload:
		unload_distant_rooms(room_id)
	
	# 确保目标房间在场景树中并激活
	_ensure_room_in_tree(room_id)
	if rooms.has(room_id) and rooms[room_id].has("node"):
		rooms[room_id].node.set_room_active(true)
	for adj in rooms[room_id].adjacent:
		if rooms.has(adj):
			_ensure_room_in_tree(adj)
			rooms[adj].node.set_room_active(true)
	
	cleanup_destroyed_walls()
	
	current_room = room_id
	
	# 登记为“已走过、待绘制”：地图上暂时不显示，需与静态检查点交互后才正式绘制
	if MapManager and MapManager.has_method("mark_room_pending"):
		MapManager.mark_room_pending(room_id)
	
	if global_canvas_modulate:
		var room_data = rooms[room_id]
		var target_color = room_data.get("color", Color.WHITE)
		global_canvas_modulate.color = target_color
	else:
		print("RoomManager: 错误：未找到全局 CanvasModulate")
	
	switch_room_bgm(room_id)
	update_camera_limits()
	room_loaded.emit(room_id, previous_room)
	_debug_room_camera_trace("load_room_end", {"current_room": current_room})

func ensure_room_loaded(room_id: String) -> bool:
	## 确保房间已在场景树中（仅实例化+注册，不激活房间）
	## load_room 需要调用方单独执行
	if room_id == "":
		return false
	if not rooms.has(room_id):
		if not _instantiate_room(room_id):
			return false
	if rooms.has(room_id):
		_ensure_room_in_tree(room_id)
		return true
	return false

## 在切房前向目标房间广播入场锚点，用于背景预对齐。
func prepare_room_background_for_entry(room_id: String, entry_world_pos: Vector2) -> void:
	if room_id == "" or not rooms.has(room_id):
		return
	var room_node: Node = rooms[room_id].get("node", null)
	if not is_instance_valid(room_node):
		return
	_notify_room_entry_anchor(room_node, entry_world_pos)

## 递归通知房间节点树中实现了 prepare_entry_anchor 的控制器。
func _notify_room_entry_anchor(node: Node, entry_world_pos: Vector2) -> void:
	if node.has_method("prepare_entry_anchor"):
		node.prepare_entry_anchor(entry_world_pos)
	for child in node.get_children():
		_notify_room_entry_anchor(child, entry_world_pos)

## 清理被摧毁的石墙（切换房间时调用）
func cleanup_destroyed_walls():
	# 获取当前场景中所有 DestructibleWall 节点
	var walls = get_tree().get_nodes_in_group("destructible_wall")
	for wall in walls:
		if wall.has_method("cleanup_destroyed_walls"):
			wall.cleanup_destroyed_walls()

## 通知 VignetteEffect 房间切换
func notify_vignette_effect_room_change():
	var vignette_nodes = get_tree().get_nodes_in_group("vignette_effect")
	for vignette in vignette_nodes:
		if vignette.has_method("on_room_changed"):
			vignette.on_room_changed()

## 通知DynamicCheckpointManager房间切换
func notify_dynamic_checkpoint_manager_room_change(new_room_id: String):
	if DynamicCheckpointManager.has_method("on_room_changed"):
		DynamicCheckpointManager.on_room_changed(new_room_id)

## 玩家进入房间
func player_entered_room(room_id: String):
	if Time.get_ticks_msec() < suppress_player_enter_until_msec:
		_debug_room_camera_trace("player_entered_room_suppressed", {"room_id": room_id})
		return
	if room_id == current_room:
		_debug_room_camera_trace("player_entered_room_same", {"room_id": room_id})
		return
	_debug_room_camera_trace("player_entered_room_switch", {"room_id": room_id})
	load_room(room_id)
	if player_ref and player_ref.has_method("sync_camera_to_player_center"):
		player_ref.sync_camera_to_player_center(true)
		_debug_room_camera_trace("player_entered_room_sync_center", {"room_id": room_id})


func suppress_player_room_enter(seconds: float = 0.35):
	var duration_msec := int(maxf(seconds, 0.0) * 1000.0)
	suppress_player_enter_until_msec = Time.get_ticks_msec() + duration_msec

## 卸载远处（非相邻）房间
func unload_distant_rooms(current_room_id: String):
	if not rooms.has(current_room_id):
		return
	
	var current_room_data = rooms[current_room_id]
	var rooms_to_keep = [current_room_id] + current_room_data.adjacent
	
	for room_id in rooms:
		if room_id in rooms_to_keep:
			rooms[room_id].node.set_room_active(true)
		else:
			_unload_room(room_id)


## 动态实例化房间（从磁盘加载 .tscn）
func _instantiate_room(room_id: String) -> bool:
	var scene_path: String = _ScenePathsScript.get_room_path(room_id)
	if scene_path.is_empty():
		return false
	if not _room_packed_cache.has(room_id):
		if not ResourceLoader.exists(scene_path):
			push_error("房间场景文件不存在: ", scene_path)
			return false
		_room_packed_cache[room_id] = load(scene_path)
	if _room_container == null:
		_room_container = get_node_or_null("/root/MainGameScene/RoomContainer")
		# 备用路径：通过组或场景查找
		if _room_container == null:
			var main = get_tree().current_scene
			if main:
				_room_container = main.get_node_or_null("RoomContainer")
		if _room_container == null:
			push_error("找不到 RoomContainer 节点，请确保 MainGameScene 中有 RoomContainer 子节点")
			return false
	var room_node = _room_packed_cache[room_id].instantiate()
	room_node.name = room_id
	room_node.position = _RoomLayoutDataPath.get_room_offset(room_id)
	_room_node_cache[room_id] = room_node
	_room_container.add_child(room_node)
	
	# 注册房间数据（立即完成，房间已在场景树中）
	if room_node.has_method("get_room_data"):
		var room_data = room_node.get_room_data()
		register_room(room_data.id, room_node, room_data)
		return true
	push_error("房间场景没有 get_room_data 方法: ", room_id)
	return false


## 确保房间在场景树中（如果已被卸载则重新加载）
func _ensure_room_in_tree(room_id: String) -> void:
	if not rooms.has(room_id):
		_instantiate_room(room_id)


## 卸载单个房间（彻底释放，参考空洞骑士做法）
func _unload_room(room_id: String) -> void:
	if not rooms.has(room_id):
		return
	var node = rooms[room_id].node
	if is_instance_valid(node):
		node.queue_free()
	rooms.erase(room_id)
	_room_node_cache.erase(room_id)
	_room_packed_cache.erase(room_id)

## 新增：添加相邻房间（双向）
func add_adjacent_room(room_a: String, room_b: String):
	if not rooms.has(room_a) or not rooms.has(room_b):
		return
	
	var room_data_a = rooms[room_a]
	var room_data_b = rooms[room_b]
	
	if not room_b in room_data_a.adjacent:
		room_data_a.adjacent.append(room_b)
	
	if not room_a in room_data_b.adjacent:
		room_data_b.adjacent.append(room_a)

## 新增：自动计算所有房间的相邻关系
func auto_calculate_room_connections():
	var door_pairs = DoorManager.get_all_paired_doors()
	
	if door_pairs.is_empty():
		print("警告：没有找到任何配对的门")
		return
	
	for pair in door_pairs:
		var door_a = pair.door_a
		var door_b = pair.door_b

		var room_a_id = door_a.get_room_id()
		var room_b_id = door_b.get_room_id()
		
		if room_a_id == "" or room_b_id == "":
			push_warning("  ⚠ 跳过：有一个门的房间 ID 为空")
			continue
		
		if room_a_id == room_b_id:
			push_warning("  ⚠ 警告：两个门在同一个房间 ", room_a_id)
			continue
		
		add_adjacent_room(room_a_id, room_b_id)

## 获取当前房间CanvasModulate
func get_current_canvas_modulate() -> CanvasModulate:
	if current_room != "" and rooms.has(current_room):
		var room_node = rooms[current_room].node
		if room_node.has_method("get_canvas_modulate"):
			return room_node.get_canvas_modulate()
	return null

## 切换房间 BGM（优先使用流式接口，支持同BGM跳过）
func switch_room_bgm(room_id: String):
	if not rooms.has(room_id):
		return
	
	var room_data = rooms[room_id]
	var bgm_stream: AudioStream = room_data.get("bgm_stream", null)
	
	if bgm_stream:
		if not AudioManager.is_playing_event_bgm():
			AudioManager.play_bgm_stream(bgm_stream)
		else:
			print("事件 BGM 播放中，不切换")
		return
	
	print("RoomManager: 房间 ", room_id, " 未配置 bgm_stream，请在 Inspector 中拖拽 BGM 文件")

## 更新相机限制框
func update_camera_limits():
	if not rooms.has(current_room) or not player_ref:
		return
	
	var room_data = rooms[current_room]
	var camera_limits = room_data.node.get_camera_limits()
	
	var player_camera = player_ref.get_node_or_null("PhantomCamera2D")
	var main_camera: Camera2D = null
	if player_ref.get_viewport():
		main_camera = player_ref.get_viewport().get_camera_2d()
	if player_camera:
		if camera_limits.has_area():
			# 只更新限制边界，不修改相机位置
			player_camera.limit_left = camera_limits.position.x
			player_camera.limit_top = camera_limits.position.y
			player_camera.limit_right = camera_limits.end.x
			player_camera.limit_bottom = camera_limits.end.y
			if main_camera:
				main_camera.limit_enabled = true
				main_camera.limit_left = int(camera_limits.position.x)
				main_camera.limit_top = int(camera_limits.position.y)
				main_camera.limit_right = int(camera_limits.end.x)
				main_camera.limit_bottom = int(camera_limits.end.y)
			_debug_room_camera_trace("update_camera_limits_area", {
				"room": current_room,
				"left": int(camera_limits.position.x),
				"top": int(camera_limits.position.y),
				"right": int(camera_limits.end.x),
				"bottom": int(camera_limits.end.y)
			})
		else:
			# 重置为默认的极大限制范围（相当于禁用限制）
			player_camera.limit_left = -CAMERA_LIMIT_DISABLED
			player_camera.limit_top = -CAMERA_LIMIT_DISABLED
			player_camera.limit_right = CAMERA_LIMIT_DISABLED
			player_camera.limit_bottom = CAMERA_LIMIT_DISABLED
			if main_camera:
				main_camera.limit_enabled = false
				main_camera.limit_left = -CAMERA_LIMIT_DISABLED
				main_camera.limit_top = -CAMERA_LIMIT_DISABLED
				main_camera.limit_right = CAMERA_LIMIT_DISABLED
				main_camera.limit_bottom = CAMERA_LIMIT_DISABLED
			_debug_room_camera_trace("update_camera_limits_disabled", {"room": current_room})

func _is_camera_debug_enabled() -> bool:
	if player_ref == null:
		return false
	return bool(player_ref.get("camera_damage_debug"))

func _debug_room_camera_trace(tag: String, payload: Dictionary = {}) -> void:
	if not _is_camera_debug_enabled():
		return
	var now_ms := Time.get_ticks_msec()
	if tag == "update_camera_limits_area" or tag == "update_camera_limits_disabled":
		if now_ms - room_camera_trace_last_ms < 120:
			return
	room_camera_trace_last_ms = now_ms
	var pcam := player_ref.get_node_or_null("PhantomCamera2D") if player_ref else null
	var cam := player_ref.get_viewport().get_camera_2d() if player_ref and player_ref.get_viewport() else null
	print("[RoomCameraTrace] ", tag,
		" room=", current_room,
		" player=", player_ref.global_position if player_ref else Vector2.ZERO,
		" pcam=", pcam.global_position if pcam else Vector2.ZERO,
		" cam=", cam.global_position if cam else Vector2.ZERO,
		" payload=", payload)

## 设置玩家引用
func set_player(player: Node):
	player_ref = player

## 获取当前房间数据
func get_current_room_data():
	return rooms.get(current_room, null)

## 根据世界坐标解析所属房间；未命中边界时回退最近房间中心。
func get_room_id_by_position(world_pos: Vector2) -> String:
	if rooms.is_empty():
		return current_room
	
	for room_id in rooms.keys():
		var room_data: Dictionary = rooms[room_id]
		var bounds: Rect2 = room_data.get("bounds", Rect2())
		if bounds.has_area() and bounds.has_point(world_pos):
			return room_id
	
	var nearest_room_id := current_room
	var nearest_distance := INF
	for room_id in rooms.keys():
		var room_data: Dictionary = rooms[room_id]
		var bounds: Rect2 = room_data.get("bounds", Rect2())
		if not bounds.has_area():
			continue
		var center: Vector2 = bounds.get_center()
		var dist_sq: float = center.distance_squared_to(world_pos)
		if dist_sq < nearest_distance:
			nearest_distance = dist_sq
			nearest_room_id = room_id
	
	return nearest_room_id
