# Door.gd
extends Area2D

## 门设置
@export_category("门设置")
## 门的唯一 ID，相同 ID 的两个门互相传送
@export var door_id: String = ""
## 目标房间 ID（传送前自动加载此房间，不填则尝试加载当前房间的相邻房间）
@export var target_room_id: String = ""

## 交互模式：启用后玩家触碰门不立即传送，需按下交互键才传送
@export var use_interaction_mode: bool = false

## 传送效果设置
@export_category("传送效果设置")
## 渐入时间（秒）
@export var fade_in_duration: float = 0.4
## 黑屏时间（秒）
@export var black_screen_duration: float = 0.4
## 淡出时间（秒）
@export var fade_out_duration: float = 0.4
## Door 非瞬移追镜时长（秒）
@export var door_camera_catchup_duration: float = 0.20
## Door 传送后临时放开相机限制时长（秒）
@export var door_camera_limit_unlock_duration: float = 0.32

## 房间入场事件配置
@export_category("房间入场事件")
## 设置此字段后，目标房间为该 ID 时延迟淡入并 hold_black，用于入场动画
@export var cinematic_room_id: String = ""
## 入场动画的 cinematic flag 名称（用于 Global.has_cinematic_flag 检查首次进入）
@export var cinematic_hold_tag: String = ""

# 内部变量
var can_teleport: bool = true
var is_player_inside: bool = false
var is_enabled: bool = true

@onready var interaction_prompt = $InteractionPrompt

func _ready():
	if door_id == "":
		print("错误：门节点没有设置 door_id，路径：", get_path())
		is_enabled = false
		return
	
	# 向 DoorManager 注册
	DoorManager.register_door(self)
	
	# 连接信号
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	if interaction_prompt:
		interaction_prompt.visible = false
	
	# 延迟检测已在区域内的 player
	call_deferred("_check_overlapping_player")


func _check_overlapping_player() -> void:
	if not is_enabled or not is_instance_valid(self):
		return
	# 延迟足够时间等当前淡入完成
	await get_tree().create_timer(1.0).timeout
	if not is_instance_valid(self) or not is_enabled:
		return
	for b in get_overlapping_bodies():
		if b.is_in_group("player") and can_teleport:
			print("[Door] 已在区域内(延迟1s后检测): id=", door_id)
			_on_body_entered(b)
			break


## 门被销毁时从 DoorManager 注销
func _exit_tree():
	if door_id != "" and DoorManager:
		DoorManager.unregister_door(self)

func _on_body_entered(body):
	if body.is_in_group("player") and is_enabled:
		if body.has_method("is_in_death_state") and body.is_in_death_state():
			return
		is_player_inside = true
		print("[Door] body_entered: id=", door_id, " target=", target_room_id, " can_tp=", can_teleport)
		if use_interaction_mode:
			_show_interaction_prompt()
		elif can_teleport:
			can_teleport = false
			if body.has_method("lock_control"):
				body.lock_control(999.0, "door_transfer")
			body.velocity = Vector2.ZERO
			if body.has_method("interrupt_hurt_visual_only"):
				body.interrupt_hurt_visual_only()
			elif body.has_method("interrupt_hurt_visual_effect"):
				body.interrupt_hurt_visual_effect()
			call_deferred("_deferred_start_teleport", body)

func _on_body_exited(body):
	if body.is_in_group("player"):
		is_player_inside = false
		can_teleport = true
		_hide_interaction_prompt()

func _input(event):
	if use_interaction_mode and event.is_action_pressed("interactive") and is_player_inside:
		var player = get_tree().get_first_node_in_group("player")
		if player and player.has_method("get_player_state") and player.get_player_state() == player.PlayerState.DASH:
			return
		_hide_interaction_prompt()
		# 交互模式同样走标准的黑屏→传送流程
		if player.has_method("lock_control"):
			player.lock_control(999.0, "door_transfer")
		player.velocity = Vector2.ZERO
		if player.has_method("interrupt_hurt_visual_only"):
			player.interrupt_hurt_visual_only()
		elif player.has_method("interrupt_hurt_visual_effect"):
			player.interrupt_hurt_visual_effect()
		# 和 body_entered 一样：先黑屏再传送
		await FadeManager.fade_out(fade_in_duration)
		await _teleport_player(player)

func _show_interaction_prompt() -> void:
	if interaction_prompt:
		interaction_prompt.visible = true

func _hide_interaction_prompt() -> void:
	if interaction_prompt:
		interaction_prompt.visible = false

## 延迟启动传送（idle 阶段执行，此时不在 physics callback 中）
func _deferred_start_teleport(body: Node) -> void:
	if not is_instance_valid(body) or not is_instance_valid(self):
		return
	# 先黑屏，再加载房间（避免闪现目标房间一帧）
	await FadeManager.fade_out(fade_in_duration)
	await _teleport_player(body)

## 黑屏阶段执行传送（此时屏幕已全黑，操作场景树安全）
func _teleport_player(player: Node) -> void:
	# 锁控与中断受伤视觉（_on_body_entered 中已做，此处为 _input 路径做保护）
	if player.has_method("lock_control"):
		player.lock_control(999.0, "door_transfer")
	player.velocity = Vector2.ZERO
	if player.has_method("interrupt_hurt_visual_only"):
		player.interrupt_hurt_visual_only()
	elif player.has_method("interrupt_hurt_visual_effect"):
		player.interrupt_hurt_visual_effect()
	
	# 传送前确保目标房间已加载（按需加载模式必需）
	var loaded_room: bool = false
	if target_room_id != "" and RoomManager and RoomManager.has_method("ensure_room_loaded"):
		loaded_room = RoomManager.ensure_room_loaded(target_room_id)
	elif RoomManager and RoomManager.rooms.has(RoomManager.current_room):
		for adj in RoomManager.rooms[RoomManager.current_room].adjacent:
			if RoomManager.has_method("ensure_room_loaded"):
				RoomManager.ensure_room_loaded(adj)
				RoomManager.load_room(adj)
	
	if not loaded_room and target_room_id != "":
		push_error("Door: 目标房间加载失败 room_id=", target_room_id)
	
	var other_door = DoorManager.find_other_door(self)
	
	if not other_door:
		push_error("严重错误：找不到相同 ID 的另一个门，ID='" + door_id + "'，路径：" + str(get_path()))
		# 恢复 can_teleport 让玩家可以再次尝试
		can_teleport = true
		if player.has_method("lock_control"):
			player.lock_control(0.0, "door_transfer_fail")
		return
	
	can_teleport = false
	other_door.can_teleport = false
	print("[Door] 找到配对门: id=", door_id, " 目标房间=", other_door.get_room_id())
	
	# 黑屏期间切换房间和传送玩家
	var door_target_room = other_door.get_room_id()
	var target_position = other_door.global_position
	var defer_autowalk_for_room_cinematic: bool = false
	if cinematic_room_id != "" and cinematic_hold_tag != "" and door_target_room == cinematic_room_id:
		if Global and Global.has_method("has_cinematic_flag"):
			defer_autowalk_for_room_cinematic = not Global.has_cinematic_flag(cinematic_hold_tag)
	if defer_autowalk_for_room_cinematic and FadeManager and FadeManager.has_method("hold_black"):
		FadeManager.hold_black(cinematic_hold_tag)

	# 传送窗口内临时抑制 RoomTrigger 切房回调，防止角点门附近二次切房竞态
	if RoomManager and RoomManager.has_method("suppress_player_room_enter"):
		RoomManager.suppress_player_room_enter(0.45)
	# 切房前先向目标房间广播入场锚点，用于背景预对齐。
	if RoomManager and RoomManager.has_method("prepare_room_background_for_entry"):
		RoomManager.prepare_room_background_for_entry(door_target_room, target_position)
	
	RoomManager.load_room(door_target_room, true)
	print("[Door] room_loaded: ", door_target_room, " t=", Time.get_ticks_msec())
	
	player.global_position = target_position
	player.velocity = Vector2.ZERO
	RoomManager.update_camera_limits()
	await get_tree().process_frame
	await get_tree().physics_frame
	RoomManager.update_camera_limits()
	if defer_autowalk_for_room_cinematic:
		if player.has_method("sync_camera_to_player_center"):
			player.sync_camera_to_player_center(true)
	elif player.has_method("sync_camera_after_room_teleport"):
		player.sync_camera_after_room_teleport()
		if player.has_method("start_door_camera_catchup_after_teleport"):
			player.start_door_camera_catchup_after_teleport(
				door_camera_catchup_duration,
				door_camera_limit_unlock_duration
			)
	await get_tree().create_timer(0.1).timeout
	if not defer_autowalk_for_room_cinematic and player.has_method("start_door_autowalk_to_dynamic_checkpoint"):
		var autowalk_started: bool = player.start_door_autowalk_to_dynamic_checkpoint(door_target_room, target_position, player.is_facing_right)
		if not autowalk_started and player.has_method("lock_control"):
			# 目标房间可能暂无动态检查点，避免无限锁输入。
			player.lock_control(0.18, "door_transfer_fallback")
	
	await get_tree().physics_frame
	await get_tree().create_timer(black_screen_duration).timeout
	
	# 4. 淡出（恢复）
	if defer_autowalk_for_room_cinematic:
		if FadeManager and FadeManager.has_method("force_black"):
			FadeManager.force_black()
	else:
		await FadeManager.fade_in(fade_out_duration)
	
	other_door.is_player_inside = true

## 获取门所在房间的 ID
func get_room_id() -> String:
	# 向上查找房间节点
	var parent = get_parent()
	while parent and not parent.has_method("get_room_data"):
		parent = parent.get_parent()
	
	if parent and parent.has_method("get_room_data"):
		var room_data = parent.get_room_data()
		if room_data and room_data.has("id"):
			return room_data.id
	
	# 备用方案：从场景树路径推断房间
	var scene_path = get_path()
	if "Room1" in scene_path:
		return "Room1"
	elif "Room2" in scene_path:
		return "Room2"
	elif "Room3" in scene_path:
		return "Room3"
	
	push_warning("Door.get_room_id(): 无法确定房间 ID，路径=", scene_path)
	return ""

## 禁用传送功能
func disable_teleport():
	is_enabled = false
	print("门 ID='", door_id, "'的传送功能已禁用")
