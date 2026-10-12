extends RefCounted
class_name PlayerDoorTraversalService

## 自动走位到位容差（像素）：进入该范围即视为到达，不再强行把玩家拉到目标点
const AUTOWALK_ARRIVE_TOLERANCE: float = 6.0
## 只有偏差小于该值才做像素级对齐（避免“被拽一下”的僵硬感）
const AUTOWALK_SNAP_TOLERANCE: float = 2.0
# 初始化 Door 自动走位状态。
static func begin_autowalk(player: Node, room_id: String, door_position: Vector2, facing_right: bool, allow_jump: bool = true, timeout: float = 1.4) -> bool:
	if TimerControlManager and TimerControlManager.has_method("stop_slow_motion"):
		TimerControlManager.stop_slow_motion()
	if is_instance_valid(player) and player.has_method("disable_counter_slow_effects"):
		player.disable_counter_slow_effects()
	if not DynamicCheckpointManager:
		return false
	if not DynamicCheckpointManager.has_method("get_best_checkpoint_for_room"):
		return false
	var best_checkpoint: Dictionary = DynamicCheckpointManager.get_best_checkpoint_for_room(room_id, door_position, facing_right)
	if best_checkpoint.is_empty():
		return false
	var target_position: Vector2 = best_checkpoint.get("position", door_position)
	if absf(target_position.x - door_position.x) < 18.0:
		return false

	player.door_autowalk_active = true
	player.door_autowalk_target_position = target_position
	player.door_autowalk_timeout = maxf(timeout, 0.35)
	player.door_autowalk_jump_used = not allow_jump
	player.door_autowalk_jump_phase = 0
	player.door_autowalk_jump_velocity = Vector2.ZERO
	player.door_autowalk_jump_velocity_ready = false
	var target_delta_x: float = float(player.door_autowalk_target_position.x - door_position.x)
	var resolved_facing_right: bool = facing_right
	if absf(target_delta_x) > 0.5:
		resolved_facing_right = target_delta_x > 0.0
	player.door_autowalk_facing_right = resolved_facing_right
	player.velocity = Vector2.ZERO
	player.is_facing_right = resolved_facing_right
	player.animated_sprite.flip_h = not resolved_facing_right
	# ★ 进房间前在奔跑的话，自动走位也保持奔跑（速度 + RUN 动画），不要掉成走路/待机。
	#   奔跑跳跃（空中）进门的场景里，is_running 会被空中判定清掉，
	#   所以还要看「土狼时间前是否奔跑」与「奔跑离地保持」这两条链路的状态。
	player.door_autowalk_running = bool(player.is_running) \
		or player.current_state == player.PlayerState.RUN \
		or bool(player.was_running_before_coyote) \
		or (player.airborne_run_keep_active and player.airborne_run_keep_valid) \
		or player.is_run_jumping
	player.change_state(player.PlayerState.RUN if player.door_autowalk_running else player.PlayerState.IDLE)
	player.control_lock_timer = player.door_autowalk_timeout + 0.2
	player.is_control_locked = true
	player.set_process_input(false)
	return true

# 每帧更新 Door 自动走位，返回 true 表示已完成。
static func update_autowalk(player: Node, fixed_delta: float) -> bool:
	if not player.door_autowalk_active:
		return true

	player.door_autowalk_timeout -= fixed_delta
	if player.door_autowalk_timeout <= 0.0:
		finish_autowalk(player)
		return true

	var target: Vector2 = player.door_autowalk_target_position
	var delta: Vector2 = target - player.global_position
	var horizontal_distance: float = absf(delta.x)
	var vertical_distance: float = delta.y
	var horizontal_direction: float = 0.0
	if horizontal_distance > 3.0:
		horizontal_direction = 1.0 if delta.x > 0.0 else -1.0

	if player.is_on_floor() and horizontal_distance <= AUTOWALK_ARRIVE_TOLERANCE and absf(vertical_distance) <= 6.0:
		## 偏差很小时才做像素级对齐，其余情况直接“就近结束”，不再强行拽到目标点
		if horizontal_distance <= AUTOWALK_SNAP_TOLERANCE:
			player.global_position.x = target.x
		player.velocity = Vector2.ZERO
		finish_autowalk(player)
		return true

	var previous_position: Vector2 = player.global_position
	# ★ 自动走位速度直接跟着玩家自己的移动速度走（不再用 0.85 这种魔法系数）：
	#   普通走位 = base_move_speed，奔跑进门 = run_move_speed，和玩家手动移动完全一致，
	#   所以调 player 脚本里的这两个速度就能同时调自动走位。
	var auto_walk_base_speed: float = player.run_move_speed if player.door_autowalk_running else player.base_move_speed
	var target_speed: float = auto_walk_base_speed * player.effective_horizontal_multiplier
	## 加速度与手动移动同一套公式（同样是不带 delta 的每物理步增量；
	## 旧写法多乘了一次 fixed_delta，导致自动走位实际只用 1/60 的加速度，永远到不了奔跑速度）
	var acceleration: float = player.ground_acceleration * auto_walk_base_speed * player.effective_horizontal_multiplier
	if player.door_autowalk_jump_used:
		if player.door_autowalk_jump_phase == 1:
			if not player.door_autowalk_jump_velocity_ready:
				player.door_autowalk_jump_velocity = _compute_vertical_jump_velocity(player, target)
				player.velocity = player.door_autowalk_jump_velocity
				player.door_autowalk_jump_velocity_ready = true
			player.velocity.x = 0.0
			if not player.is_on_floor():
				player.apply_gravity(fixed_delta)
			player.move_and_slide()
			if player.global_position.y <= target.y + 4.0 or player.velocity.y >= 0.0:
				player.door_autowalk_jump_phase = 2
				player.door_autowalk_jump_velocity_ready = false
		elif player.door_autowalk_jump_phase == 2:
			if not player.door_autowalk_jump_velocity_ready:
				player.door_autowalk_jump_velocity = _compute_jump_velocity(player, target)
				player.velocity = player.door_autowalk_jump_velocity
				player.door_autowalk_jump_velocity_ready = true
			if not player.is_on_floor():
				player.apply_gravity(fixed_delta)
			player.move_and_slide()
		else:
			player.door_autowalk_jump_phase = 1
			player.door_autowalk_jump_velocity_ready = false
	else:
		player.velocity.x = move_toward(player.velocity.x, horizontal_direction * target_speed, acceleration * player.get_accel_step_scale())
		if not player.is_on_floor():
			player.apply_gravity(fixed_delta)
		player.move_and_slide()
		var horizontal_progress: float = absf(player.global_position.x - previous_position.x)
		var blocked_by_wall: bool = player.is_on_wall() and horizontal_distance > 20.0
		var target_is_higher: bool = vertical_distance < -14.0
		if blocked_by_wall and target_is_higher:
			player.door_autowalk_jump_used = true
			player.door_autowalk_jump_phase = 1
			player.door_autowalk_jump_velocity_ready = false
			player.velocity = Vector2.ZERO
			player.change_state(player.PlayerState.JUMP)
			return false
		elif horizontal_progress >= maxf(target_speed * fixed_delta * 0.25, 0.5):
			pass

	if player.is_on_floor():
		if absf(player.velocity.x) > 8.0:
			player.change_state(player.PlayerState.RUN if player.door_autowalk_running else player.PlayerState.MOVE)
		else:
			player.change_state(player.PlayerState.IDLE)
	else:
		if player.velocity.y < 0.0:
			player.change_state(player.PlayerState.JUMP)
		else:
			player.change_state(player.PlayerState.DOWN)

	var current_delta_x: float = target.x - player.global_position.x
	var horizontal_distance_after_move: float = absf(current_delta_x)
	var moving_away_from_target: bool = absf(player.velocity.x) > 8.0 and sign(player.velocity.x) != sign(current_delta_x)
	if player.is_on_floor():
		if horizontal_distance_after_move <= AUTOWALK_ARRIVE_TOLERANCE or (player.door_autowalk_jump_used and (horizontal_distance_after_move <= 10.0 or moving_away_from_target)):
			## 轻微偏差直接忽略（不再把 x/y 强行吸附到目标点，消除落点前的“生硬拽动”）
			if horizontal_distance_after_move <= AUTOWALK_SNAP_TOLERANCE:
				player.global_position.x = target.x
			player.velocity = Vector2.ZERO
			finish_autowalk(player)
			return true

	return false

static func _compute_vertical_jump_velocity(player: Node, target: Vector2) -> Vector2:
	var delta: Vector2 = target - player.global_position
	var gravity_strength: float = player.gravity * maxf(player.effective_gravity_multiplier, 0.1)
	var minimum_lift_height: float = maxf(absf(delta.y) + 24.0, 48.0)
	var launch_speed: float = maxf(absf(player.jump_velocity), sqrt(maxf(2.0 * gravity_strength * minimum_lift_height, 0.0)))
	return Vector2(0.0, -launch_speed)

static func _compute_jump_velocity(player: Node, target: Vector2) -> Vector2:
	var delta: Vector2 = target - player.global_position
	var gravity_strength: float = player.gravity * maxf(player.effective_gravity_multiplier, 0.1)
	var horizontal_time: float = absf(delta.x) / maxf(player.run_move_speed * 0.9, 1.0)
	var vertical_time: float = sqrt(maxf(absf(delta.y) * 2.0 / maxf(gravity_strength, 1.0), 0.0))
	var travel_time: float = clampf(maxf(horizontal_time, vertical_time * 1.05), 0.24, 0.95)
	var velocity_x: float = delta.x / travel_time
	var velocity_y: float = (delta.y - 0.5 * gravity_strength * travel_time * travel_time) / travel_time
	return Vector2(velocity_x, velocity_y)

# 结束 Door 自动走位并恢复输入。
static func finish_autowalk(player: Node) -> void:
	player.door_autowalk_active = false
	player.door_autowalk_timeout = 0.0
	player.door_autowalk_jump_used = false
	player.door_autowalk_jump_phase = 0
	player.door_autowalk_jump_velocity = Vector2.ZERO
	player.door_autowalk_jump_velocity_ready = false
	player.velocity = Vector2.ZERO
	player.control_lock_timer = 0.0
	player.is_control_locked = false
	player.set_process_input(true)
	# 奔跑进门的话，自动走位结束也停在 RUN 上，与随后的玩家输入无缝衔接。
	# 注意：还必须把“奔跑意图”写回 Player（is_running / is_run_ready / run_direction），
	# 否则下一帧 handle_run_state 会因为 is_running=false 立即掉回 MOVE。
	var was_running: bool = player.door_autowalk_running
	player.door_autowalk_running = false
	if was_running:
		var hold_dir: int = int(signf(Input.get_axis("left", "right")))
		if hold_dir != 0:
			player.is_run_ready = true
			player.run_direction = hold_dir
			player.is_running = true
			player.was_running_before_coyote = true
			## 起步过渡直接拉满，避免刚出自动走位又被 0.2s 过渡降速（保证“无缝”）
			player.run_speed_ramp_timer = maxf(player.run_speed_transition_time, 0.0)
	if player.is_on_floor():
		player.change_state(player.PlayerState.RUN if was_running else player.PlayerState.IDLE)
	else:
		player.change_state(player.PlayerState.DOWN)
