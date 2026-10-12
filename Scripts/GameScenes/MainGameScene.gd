# MainGameScene.gd
extends Node2D

signal boot_visual_ready

# 启动阶段是否已经准备好让场景切换流程继续。
var _boot_visual_ready: bool = false

@onready var room_container = $RoomContainer
@onready var player = $Player
# 新存档开场与后续事件演出的独立导演节点。
@onready var boot_cinematic_director = $BootCinematicDirector
@onready var new_save_opening_event_director = $EventDirectors/NewSaveOpeningEventDirector

func _ready():
	if not is_inside_tree() or get_tree() == null:
		return
	_cleanup_runtime_camera_viewfinder_overlays()
	if RoomManager and RoomManager.has_method("reset_runtime_state"):
		RoomManager.reset_runtime_state()
	if RoomManager and RoomManager.has_signal("room_loaded") and not RoomManager.room_loaded.is_connected(_on_room_loaded):
		RoomManager.room_loaded.connect(_on_room_loaded)
	# 当前启动是否携带一次性的新存档开场请求。
	var boot_cinematic_request: Dictionary = {}
	if Global and Global.has_method("peek_boot_cinematic_request"):
		boot_cinematic_request = Global.peek_boot_cinematic_request()
	# 是否需要走开场导演流程，而不是常规存档睡眠同步。
	var should_play_opening: bool = boot_cinematic_request.get("id", "") == "new_save_opening"

	# 初始化房间系统
	initialize_room_system()
	
	# 设置玩家引用
	RoomManager.set_player(player)
	if Global.current_save_slot >= 0 and not should_play_opening:
		_preposition_player_and_camera_for_save()
	
	# 确保 CanvasModulate 节点正确引用
	var global_canvas = $GlobalCanvasModulate
	if global_canvas:
		# 直接设置 RoomManager 的全局 CanvasModulate 引用
		RoomManager.global_canvas_modulate = global_canvas
		# 初始化颜色为当前房间的颜色（如果已经加载了房间）
		var current_room_data = RoomManager.get_current_room_data()
		if current_room_data:
			global_canvas.color = current_room_data.get("color", Color.WHITE)
	else:
		print("MainGameScene: 错误：未找到 GlobalCanvasModulate")
	
	var tree := get_tree()
	if tree == null:
		return
	# 立即加载房间（不等待渲染帧，借助 FadeManager.force_black 保持黑屏）
	RoomManager.auto_calculate_room_connections()
	
	# 如果是从存档加载，设置玩家位置和状态
	if Global.current_save_slot >= 0:
		if should_play_opening:
			await _play_new_game_opening_sequence()
		else:
			await _load_from_save()
	else:
		if get_tree() == null:
			return
		RoomManager.load_room("GrassLand1")
	
	# 连接玩家死亡信号
	if not is_inside_tree() or get_tree() == null:
		return
	var player_ui = get_tree().get_first_node_in_group("player_ui")
	if player_ui:
		player_ui.player_died.connect(_on_player_died)

	# 等待一帧渲染 + 一帧物理让 PhantomCamera 内部跟随逻辑稳定
	await get_tree().process_frame
	await get_tree().physics_frame
	# 在淡入前最后一次对齐相机到玩家位置，防止 PhantomCamera 跟随偏移
	if is_instance_valid(player) and player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	# ★ _boot_visual_ready 必须等「相机也对齐完」才置位。
	#   切场方 SceneManager 是在 wait_until_boot_visual_ready() 返回后立刻开始淡入的；
	#   若提前置位（原来就在本段开头），就会出现「淡入已经开始、相机却还没对齐」的一两帧错误画面
	#   —— 这正是「正常进入存档开头有短暂错误」的来源。
	_boot_visual_ready = true
	boot_visual_ready.emit()

## 新存档开场流程：黑幕下拉起房间并交给开场导演播放。
func _play_new_game_opening_sequence() -> void:
	if FadeManager and FadeManager.has_method("force_black"):
		FadeManager.force_black()
	else:
		await FadeManager.fade_out(0.0)
	if RoomManager:
		RoomManager.load_room("GrassLand1")
	await get_tree().process_frame
	if FadeManager and FadeManager.has_method("force_black"):
		FadeManager.force_black()
	var boot_cinematic_request: Dictionary = {}
	if Global and Global.has_method("consume_boot_cinematic_request"):
		boot_cinematic_request = Global.consume_boot_cinematic_request()
	if new_save_opening_event_director and new_save_opening_event_director.has_method("play_opening"):
		await new_save_opening_event_director.play_opening(boot_cinematic_request)
	elif boot_cinematic_director and boot_cinematic_director.has_method("play_intro_sequence"):
		await boot_cinematic_director.play_intro_sequence(boot_cinematic_request)

func _exit_tree() -> void:
	_cleanup_runtime_camera_viewfinder_overlays()
	if Engine.has_singleton("PhantomCameraManager"):
		var manager = Engine.get_singleton("PhantomCameraManager")
		if manager and manager.has_method("scene_changed"):
			manager.scene_changed()

func _on_room_loaded(_room_id: String, _previous_room: String) -> void:
	if not is_instance_valid(room_container):
		return
	if not RoomManager:
		return
	var current_room_data: Dictionary = RoomManager.get_current_room_data()
	if current_room_data.is_empty():
		return
	var global_canvas: CanvasModulate = $GlobalCanvasModulate
	if global_canvas:
		global_canvas.color = current_room_data.get("color", Color.WHITE)

func _cleanup_runtime_camera_viewfinder_overlays() -> void:
	var root := get_tree().root
	if root == null:
		return
	for child in root.get_children():
		if child is CanvasLayer:
			for grand in child.get_children():
				if grand is Control and grand.name == "ViewfinderPanel":
					child.queue_free()
					break

func wait_until_boot_visual_ready() -> void:
	if _boot_visual_ready:
		return
	await boot_visual_ready

func initialize_room_system():
	# 按需加载模式：RoomContainer 启动时为空
	# 首次房间加载由 _load_from_save 或玩家进入触发
	# RoomManager._instantiate_room() 会在需要时加载房间
	pass

## 从存档加载
func _load_from_save():
	# 设置玩家位置
	var the_player = get_tree().get_first_node_in_group("player")
	if the_player:
		# 复用死亡重生同款：先切到存档房间再做黑屏居中，避免边界回拉暴露。
		await get_tree().process_frame
		var target_room_id := Global.last_save_room
		if target_room_id == "":
			target_room_id = "GrassLand1"
		if the_player.has_method("sync_room_and_camera_for_respawn"):
			await the_player.sync_room_and_camera_for_respawn(target_room_id, true)
			await get_tree().process_frame
			if the_player.has_method("sync_camera_to_player_center"):
				the_player.sync_camera_to_player_center(true)
		else:
			if RoomManager and RoomManager.has_method("prepare_room_background_for_entry"):
				RoomManager.prepare_room_background_for_entry(target_room_id, the_player.global_position)
			RoomManager.load_room(target_room_id)
			RoomManager.update_camera_limits()
			_snap_camera_to_player_immediately(the_player)
		await get_tree().physics_frame
		
		# 使用传送伤害的禁用时间，也是存档进入游戏开始时的禁用时间
		the_player.lock_control(the_player.warp_control_lock_time, "warp_damage")
		
		# 设置玩家为睡眠状态
		the_player.enter_sleep_state()
	# 设置玩家UI状态
	var player_ui = get_tree().get_first_node_in_group("player_ui")
	if player_ui:
		player_ui.set_max_health(Global.player_max_health)
		player_ui.set_health(Global.player_current_health)

func _snap_camera_to_player_immediately(the_player: Node) -> void:
	if the_player == null:
		return
	var player_pos: Vector2 = the_player.global_position
	var follow_offset := Vector2.ZERO
	var phantom_camera = the_player.get_node_or_null("PhantomCamera2D")
	if phantom_camera and phantom_camera.has_method("get_follow_offset"):
		follow_offset = phantom_camera.get_follow_offset()
	var target_camera_pos: Vector2 = player_pos + follow_offset
	target_camera_pos = _clamp_camera_target_by_limits(target_camera_pos, phantom_camera)
	var main_camera = get_node_or_null("Camera2D")
	if main_camera:
		main_camera.global_position = target_camera_pos
		if main_camera.has_method("reset_smoothing"):
			main_camera.reset_smoothing()
		if main_camera.has_method("reset_physics_interpolation"):
			main_camera.reset_physics_interpolation()
	if phantom_camera:
		phantom_camera.global_position = target_camera_pos
		if phantom_camera.has_method("teleport_position"):
			phantom_camera.teleport_position()

func _clamp_camera_target_by_limits(target_pos: Vector2, phantom_camera: Node) -> Vector2:
	if phantom_camera == null:
		return target_pos
	var clamped_pos = target_pos
	if phantom_camera.has_method("get"):
		var limit_left = int(phantom_camera.get("limit_left"))
		var limit_top = int(phantom_camera.get("limit_top"))
		var limit_right = int(phantom_camera.get("limit_right"))
		var limit_bottom = int(phantom_camera.get("limit_bottom"))
		clamped_pos.x = clampf(clamped_pos.x, float(limit_left), float(limit_right))
		clamped_pos.y = clampf(clamped_pos.y, float(limit_top), float(limit_bottom))
	return clamped_pos

func _preposition_player_and_camera_for_save() -> void:
	if player == null:
		return
	player.global_position = Global.get_save_point_position()
	# 房间加载与相机同步交给 _load_from_save，保持单路径，避免双重同步竞争。

func _on_player_died():
	# 关键修复：死亡时清除动态检查点记录
	if DynamicCheckpointManager.has_method("clear_all_checkpoints_on_death"):
		DynamicCheckpointManager.clear_all_checkpoints_on_death()
