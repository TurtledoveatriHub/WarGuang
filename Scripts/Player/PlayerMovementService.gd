extends RefCounted
class_name PlayerMovementService

# 复用空气能力服务，避免移动状态和跳跃状态各自写一套切换逻辑。
const PlayerAirAbilityServiceScript = preload("res://Scripts/Player/PlayerAirAbilityService.gd")
## 台阶修正入口（跑出边缘撞到矮障碍时把它抬上去，而不是走撞墙僵直）
const PlayerEdgeCorrectionServiceScript = preload("res://Scripts/Player/PlayerEdgeCorrectionService.gd")

# 处理地面快速双击奔跑检测。
static func detect_run_input(player: Node, move_input: float) -> void:
	if move_input != 0 and (player.is_on_floor() or player.coyote_time_active):
		var current_time: float = Time.get_unix_time_from_system()
		var move_direction: int = 1 if move_input > 0 else -1

		if Input.is_action_just_pressed("right") or Input.is_action_just_pressed("left"):
			if move_direction == player.last_move_direction:
				var time_since_last_input: float = current_time - player.last_move_input_time
				if time_since_last_input < player.quick_tap_time_window:
					player.is_run_ready = true
					player.run_direction = move_direction
			else:
				player.is_run_ready = false

			player.last_move_input_time = current_time
			player.last_move_direction = move_direction

		if player.is_run_ready and player.run_direction == move_direction:
			player.is_running = true
			if player.is_on_floor():
				player.was_running_before_coyote = true
		else:
			player.is_running = false
	else:
		player.is_running = false
		player.is_run_ready = false

	if player.is_on_floor():
		player.was_running_before_coyote = player.is_running

# 处理奔跑跳速度窗口。
static func handle_run_jump(player: Node, fixed_delta: float) -> void:
	if player.current_state == player.PlayerState.DASH or player.current_state == player.PlayerState.SUPERDASH or player.current_state == player.PlayerState.SUPERDASHSTART:
		return
	if not player.is_run_jumping:
		return

	player.run_jump_timer -= fixed_delta
	var move_input: float = player.get_resolved_horizontal_input() if player.has_method("get_resolved_horizontal_input") else Input.get_axis("left", "right")
	if move_input == 0:
		player.is_run_jumping = false
		return
	if sign(move_input) != player.run_jump_original_direction:
		player.is_run_jumping = false
		return

	if player.run_jump_timer > 0:
		player.velocity.x = player.run_jump_original_direction * (player.base_move_speed + player.run_jump_boost_speed) * player.effective_horizontal_multiplier
		return

	var target_speed: float = player.run_jump_original_direction * player.base_move_speed
	player.velocity.x = move_toward(player.velocity.x, target_speed, player.run_jump_boost_speed * fixed_delta / player.run_jump_decay_time)
	if abs(player.velocity.x) <= player.base_move_speed:
		player.is_run_jumping = false

# 进入超级冲刺状态。
static func start_super_dash(player: Node) -> void:
	player.is_super_dash_charging = false
	player.super_dash_charge_timer = 0.0
	player.super_dash_accel_timer = 0.0
	player.super_dash_deceleration_timer = 0.0
	player.super_dash_input_lock_timer = player.super_dash_input_lock_time
	player.super_dash_afterimage_timer = 0.0
	player.super_dash_duration_timer = 0.0
	player.is_jumping = true
	player.jump_count = 1
	player.has_double_jumped = false
	player.can_double_jump = true
	player.can_glide = false
	player.is_double_jump_holding = false
	player.coyote_time_active = false
	player.can_compensation_jump = false
	player.is_in_special_state = true
	player.change_state(player.PlayerState.SUPERDASH)

# 处理冲刺计时结束后的状态回退。
static func handle_dash_timers(player: Node, fixed_delta: float) -> void:
	if player.current_state == player.PlayerState.DASH:
		player.dash_duration_timer += fixed_delta
		var current_dash_duration = player.black_dash_duration if player.black_dash_unlocked else player.dash_duration
		var total_dash_duration = current_dash_duration + maxf(player.dash_steer_duration, 0.0)
		if player.dash_duration_timer >= total_dash_duration:
			player.dash_duration_timer = 0
			if player.was_gliding_before_dash:
				player.was_gliding_before_dash = false
				player.change_state(player.PlayerState.DOWN)
			elif player.is_on_floor() or player.coyote_time_active:
				var move_input = player.get_resolved_horizontal_input() if player.has_method("get_resolved_horizontal_input") else Input.get_axis("left", "right")
				if move_input == 0:
					player.change_state(player.PlayerState.IDLE)
				elif player.is_running:
					# 地面冲刺结束：仍在奔跑就回 RUN —— 冲刺不应该打断奔跑状态
					player.change_state(player.PlayerState.RUN)
				else:
					player.change_state(player.PlayerState.MOVE)
			else:
				if player.jump_buffer_timer and player.jump_buffer_timer.is_stopped() == false:
					player.jump_buffer_timer.stop()
				if player.velocity.y < 0:
					player.change_state(player.PlayerState.JUMP)
				else:
					player.change_state(player.PlayerState.DOWN)

static func _check_game_pause_state(player: Node) -> bool:
	if player.is_in_dialogue:
		return true
	var game_setting_nodes = player.get_tree().get_nodes_in_group("game_setting_scene")
	if game_setting_nodes.size() > 0:
		for node in game_setting_nodes:
			if node.visible:
				return true
	if player.get_tree().paused:
		return true
	return false

static func update_timer_with_pause(_player: Node, timer_ref: float, fixed_delta: float, is_paused: bool = false) -> float:
	if is_paused:
		return timer_ref
	return timer_ref + fixed_delta

static func apply_gravity(player: Node, fixed_delta: float) -> void:
	if player.current_state == player.PlayerState.WALLGRIP:
		return
	if player.current_state == player.PlayerState.GLIDE and player.glide_timer <= player.glide_hover_time:
		player.velocity.y = min(player.velocity.y, 0.0)
		return
	if player.is_jump_interrupt_decaying:
		return
	player.velocity.y += player.gravity * player.effective_gravity_multiplier * fixed_delta
	player.velocity.y = min(player.velocity.y, player.effective_max_fall_speed)

static func update_coyote_time(player: Node) -> void:
	if player.was_on_floor and not player.is_on_floor() and player.velocity.y >= 0 and not player.is_jumping:
		player.coyote_time_active = true
		player.coyote_timer.start(player.coyote_time)
		if not player.is_jumping:
			player.can_compensation_jump = true
			player.compensation_jump_used = false
	if player.is_on_floor():
		if player.current_state == player.PlayerState.SUPERDASH:
			player.was_on_floor = player.is_on_floor()
			return
		player.coyote_time_active = false
		player.has_double_jumped = false
		player.can_double_jump = false
		player.can_compensation_jump = false
		player.compensation_jump_used = false
		player.is_jumping = false
		player.is_run_jumping = false
		player.has_dashed_in_air = false
		player.can_glide = false
		player.is_double_jump_holding = false
		player.was_gliding_before_dash = false
		player.jump_buffer_after_dash = false
		player.jump_buffer_type = 0
	player.was_on_floor = player.is_on_floor()

# 处理冲刺输入和冲刺进入条件。
static func try_dash(player: Node, dash_just_pressed: bool) -> bool:
	if dash_just_pressed and player.can_dash and player.dash_unlocked:
		# 已在空中冲刺过则立即拒绝，不执行任何副作用（避免破坏滑翔状态）。
		if not player.is_on_floor() and not player.coyote_time_active and player.has_dashed_in_air:
			return false

		player.was_gliding_before_dash = (player.current_state == player.PlayerState.GLIDE)

		if player.was_gliding_before_dash:
			player.is_gliding = false
			player.glide_timer = 0.0
			player.is_double_jump_holding = false

		# 在地面时不会消耗空中冲刺计数；在空中时标记已使用空中冲刺。
		if not player.is_on_floor() and not player.coyote_time_active:
			player.has_dashed_in_air = true

		# 检测冲刺方向：垂直输入优先于水平（同时按住时优先垂直），地面禁止下冲刺。
		var v_input := Input.get_axis("up", "down")
		var h_input := Input.get_axis("left", "right")
		if player.vertical_dash_unlocked and v_input != 0 and not (player.is_on_floor() and v_input > 0):
			player.dash_locked_vector = Vector2(0, -1 if v_input < 0 else 1)
		else:
			var h_dir: int = 1 if player.is_facing_right else -1
			if h_input != 0:
				h_dir = 1 if h_input > 0 else -1
			player.dash_locked_vector = Vector2(h_dir, 0)

		player.change_state(player.PlayerState.DASH)
		player.can_dash = false
		player.dash_duration_timer = 0
		## ★ 清除来自 BACKSTEP 等状态的残留跳跃缓冲，防止上冲刺结束后自动跳跃
		player.jump_buffer_after_dash = false
		var current_dash_duration = player.black_dash_duration if player.black_dash_unlocked else player.dash_duration
		var total_dash_duration = current_dash_duration + maxf(player.dash_steer_duration, 0.0)
		player.dash_duration_timer_node.start(total_dash_duration)
		player.dash_cooldown_timer_node.start(player.dash_cooldown)
		return true
	elif dash_just_pressed and not player.dash_unlocked:
		print("冲刺能力尚未解锁！")
	return false

# 处理地面后撤步触发：按住下方向并按下冲刺键，方向固定为当前朝向反方向。
static func try_backstep(player: Node, dash_just_pressed: bool) -> bool:
	if not dash_just_pressed:
		return false
	if not player.backstep_unlocked:
		return false
	if player.counter_slow_compensation_active:
		return false
	if not player.can_dash:
		return false
	if not player.is_on_floor():
		return false
	if not Input.is_action_pressed("down"):
		return false

	var facing_dir: int = 1 if player.is_facing_right else -1
	start_backstep(player, facing_dir)
	player.can_dash = false
	player.dash_cooldown_timer_node.start(player.dash_cooldown)
	return true

# 处理站立状态的派生状态切换。
static func handle_idle_state(player: Node, _delta: float, move_input: float, jump_just_pressed: bool, dash_just_pressed: bool) -> void:
	if player.sleep_timer >= player.idle_to_sleep_time:
		player.change_state(player.PlayerState.SLEEP)
		return

	if player.is_pressing_up and not player.is_pressing_down and player.look_timer >= player.idle_to_look_time:
		player.change_state(player.PlayerState.LOOKUP)
		return

	if player.is_pressing_down and not player.is_pressing_up and player.look_timer >= player.idle_to_look_time:
		player.change_state(player.PlayerState.LOOKDOWN)
		return

	if player.super_dash_unlocked and Input.is_action_pressed("super_dash") and player.current_state != player.PlayerState.DASH:
		player.is_super_dash_charging = true
		player.change_state(player.PlayerState.SUPERDASHSTART)
		return

	if not player.is_on_floor() and not player.coyote_time_active:
		if player.velocity.y < 0:
			player.change_state(player.PlayerState.JUMP)
		else:
			player.change_state(player.PlayerState.DOWN)
		return

	if try_backstep(player, dash_just_pressed):
		return

	if try_dash(player, dash_just_pressed):
		return

	if PlayerAirAbilityServiceScript.try_jump(player, jump_just_pressed):
		return

	if move_input != 0:
		if player.is_running:
			player.change_state(player.PlayerState.RUN)
		else:
			player.change_state(player.PlayerState.MOVE)
	else:
		var target_speed = move_input * player.base_move_speed * player.effective_horizontal_multiplier
		player.velocity.x = move_toward(player.velocity.x, target_speed, player.ground_acceleration * player.base_move_speed * player.effective_horizontal_multiplier)

# 处理普通移动状态的地面逻辑。
static func handle_move_state(player: Node, delta: float, move_input: float, jump_just_pressed: bool, dash_just_pressed: bool) -> void:
	if not player.is_on_floor() and not player.coyote_time_active:
		if player.velocity.y < 0:
			player.change_state(player.PlayerState.JUMP)
		else:
			player.change_state(player.PlayerState.DOWN)
		return

	if try_backstep(player, dash_just_pressed):
		return

	if try_dash(player, dash_just_pressed):
		return

	if PlayerAirAbilityServiceScript.try_jump(player, jump_just_pressed):
		return

	if player.super_dash_unlocked and Input.is_action_pressed("super_dash") and player.current_state != player.PlayerState.DASH:
		player.is_super_dash_charging = true
		player.change_state(player.PlayerState.SUPERDASHSTART)
		return

	if player.current_state == player.PlayerState.RUN and player.is_on_wall():
		var wall_normal = player.get_wall_normal()
		if wall_normal.dot(Vector2(move_input, 0)) < 0:
			# ★ 先试「跑出边缘台阶修正」：断口对面那块同高度地形的侧面会被当成墙，
			#   修正成功就把玩家抬到它顶面继续跑，而不是吃撞墙僵直 + 反弹。
			if not PlayerEdgeCorrectionServiceScript.try_run_off_ledge_step_up(player, delta):
				handle_wall_bump(player)
				return

	if move_input == 0:
		player.change_state(player.PlayerState.IDLE)
	else:
		if player.is_running:
			player.change_state(player.PlayerState.RUN)

		var target_speed = move_input * player.base_move_speed * player.effective_horizontal_multiplier
		player.velocity.x = move_toward(player.velocity.x, target_speed, player.ground_acceleration * player.base_move_speed * player.effective_horizontal_multiplier)

# 处理跑步状态的地面逻辑。
static func handle_run_state(player: Node, delta: float, move_input: float, jump_just_pressed: bool, dash_just_pressed: bool) -> void:
	if not player.is_on_floor() and not player.coyote_time_active:
		if player.velocity.y < 0:
			player.change_state(player.PlayerState.JUMP)
		else:
			player.change_state(player.PlayerState.DOWN)
		return

	if try_backstep(player, dash_just_pressed):
		return

	if try_dash(player, dash_just_pressed):
		return

	if PlayerAirAbilityServiceScript.try_jump(player, jump_just_pressed):
		return

	if player.super_dash_unlocked and Input.is_action_pressed("super_dash") and player.current_state != player.PlayerState.DASH:
		player.is_super_dash_charging = true
		player.change_state(player.PlayerState.SUPERDASHSTART)
		return

	if player.current_state == player.PlayerState.RUN and player.is_on_wall():
		var wall_normal = player.get_wall_normal()
		if wall_normal.dot(Vector2(move_input, 0)) < 0:
			# ★ 同上：撞墙前先给「跑出边缘台阶修正」一次机会（这就是跨越一格断口的关键）
			if not PlayerEdgeCorrectionServiceScript.try_run_off_ledge_step_up(player, delta):
				handle_wall_bump(player)
				return

	if move_input == 0:
		player.change_state(player.PlayerState.IDLE)
	else:
		if not player.is_running:
			player.change_state(player.PlayerState.MOVE)
		else:
			var target_speed = move_input * player.run_move_speed * player.effective_horizontal_multiplier
			player.velocity.x = move_toward(player.velocity.x, target_speed, player.ground_acceleration * player.run_move_speed * player.effective_horizontal_multiplier)

static func start_backstep(player: Node, facing_dir: int) -> void:
	player.backstep_direction = -facing_dir
	player.backstep_timer = 0.0
	player.backstep_counter_consumed = false
	player.change_state(player.PlayerState.BACKSTEP)

static func handle_backstep_state(player: Node, fixed_delta: float, move_input: float) -> void:
	if not player.is_on_floor() and not player.coyote_time_active:
		player.change_state(player.PlayerState.DOWN)
		return
	player.backstep_timer += fixed_delta
	player.velocity.x = player.backstep_direction * player.backstep_move_speed
	player.velocity.y = 0

	if Input.is_action_pressed("jump"):
		if player.can_double_jump and not player.has_double_jumped:
			player.jump_buffer_after_dash = true
			player.jump_buffer_type = 2
		else:
			player.jump_buffer_after_dash = true
			player.jump_buffer_type = 1

	if player.backstep_timer >= player.backstep_duration:
		if player.jump_buffer_after_dash:
			player.jump_buffer_after_dash = false
			if player.jump_buffer_type == 1:
				PlayerAirAbilityServiceScript.try_jump(player, true)
			elif player.jump_buffer_type == 2:
				PlayerAirAbilityServiceScript.try_double_jump(player, true)
			return
		if player.is_on_floor() or player.coyote_time_active:
			if move_input == 0:
				player.change_state(player.PlayerState.IDLE)
			else:
				player.change_state(player.PlayerState.MOVE)
		else:
			if player.velocity.y < 0:
				player.change_state(player.PlayerState.JUMP)
			else:
				player.change_state(player.PlayerState.DOWN)

# 处理基础冲刺状态的速度锁定。
static func handle_dash_state(player: Node) -> void:
	# 冲刺期间按下跳跃不立即打断冲刺，改为缓冲到冲刺结束后执行（由 _on_dash_duration_timeout 处理）。
	if Input.is_action_just_pressed("jump"):
		if player.can_double_jump and not player.has_double_jumped:
			player.jump_buffer_after_dash = true
			player.jump_buffer_type = 2
		else:
			player.jump_buffer_after_dash = true
			player.jump_buffer_type = 1

	if player.dash_locked_vector == Vector2.ZERO:
		player.dash_locked_vector = Vector2.RIGHT if player.is_facing_right else Vector2.LEFT

	# 转向阶段：超过基础冲刺时长后，允许玩家在同一轴向上调整方向。
	var current_dash_duration = player.black_dash_duration if player.black_dash_unlocked else player.dash_duration
	if player.dash_steer_duration > 0.0 and player.dash_duration_timer >= current_dash_duration:
		if player.dash_locked_vector.y == 0:
			# 水平冲刺：转向阶段只允许左右调整
			var move_input = player.get_resolved_horizontal_input() if player.has_method("get_resolved_horizontal_input") else Input.get_axis("left", "right")
			if move_input != 0:
				player.dash_locked_vector = Vector2(1 if move_input > 0 else -1, 0)
				player.is_facing_right = move_input > 0
				player.animated_sprite.flip_h = not player.is_facing_right
		else:
			# 垂直冲刺：转向阶段按反方向键直接打断冲刺。
			var v_input := Input.get_axis("up", "down")
			if v_input != 0:
				if sign(v_input) == -player.dash_locked_vector.y:
					# 按住反方向 → 直接退出冲刺状态
					player.dash_duration_timer = 0
					player.dash_duration_timer_node.stop()
					player.change_state(player.PlayerState.DOWN)
					return
				# 同方向调整
				player.dash_locked_vector = Vector2(0, -1 if v_input < 0 else 1)

	var current_dash_speed: float = player.vertical_dash_speed if player.dash_locked_vector.y != 0 else player.dash_speed
	player.velocity = player.dash_locked_vector * current_dash_speed
	if player.dash_locked_vector.y == 0:
		player.velocity.y = 0
	else:
		player.velocity.x = 0

	# 处理攀墙状态的受力、减速和跳跃入口。
static func handle_wallgrip_state(player: Node, fixed_delta: float, move_input: float, jump_just_pressed: bool, _jump_pressed: bool, _jump_just_released: bool, dash_just_pressed: bool) -> void:
	if try_dash(player, dash_just_pressed):
		return

	if jump_just_pressed:
		player.start_wall_jump()
		return

	var locked_wall_direction: int = player.wall_grip_direction if player.wall_grip_direction != 0 else player.wall_direction

	if not player.is_touching_wall:
		player.exit_wallgrip()
		return

	if locked_wall_direction == 0:
		locked_wall_direction = player.wall_direction

	# 攀墙朝向锁定：面朝所贴的墙（右墙朝右、左墙朝左）。
	# 否则会沿用进入攀墙前的旧朝向，出现“右墙却朝左”的错误表现。
	if locked_wall_direction != 0:
		var face_right: bool = locked_wall_direction > 0
		if player.is_facing_right != face_right:
			player.is_facing_right = face_right
			player.animated_sprite.flip_h = not face_right

	var toward_wall = (move_input > 0 and locked_wall_direction == 1) or (move_input < 0 and locked_wall_direction == -1)
	var away_from_wall = (move_input < 0 and locked_wall_direction == 1) or (move_input > 0 and locked_wall_direction == -1)

	if player.is_invincible and player.current_state == player.PlayerState.HURT:
		player.exit_wallgrip()
		return

	if toward_wall:
		player.no_input_timer = 0.0
		player.hold_toward_wall_timer += fixed_delta

		if player.hold_toward_wall_timer < player.hold_toward_wall_time:
			player.velocity.y = 0
			player.current_wall_slide_speed = 0
		else:
			player.velocity.y = player.wall_slide_slow_speed * player.effective_gravity_multiplier
			player.current_wall_slide_speed = player.wall_slide_slow_speed * player.effective_gravity_multiplier
		player.velocity.x = 0
	elif away_from_wall:
		# 按离墙方向键：立即脱离攀墙（不再使用延迟）
		player.wall_jump_escape_buffer_timer = player.wall_jump_escape_buffer_time
		player.exit_wallgrip()
		return
	else:
		player.no_input_timer += fixed_delta
		var progress = min(player.no_input_timer / player.no_input_time, 1.0)
		player.current_wall_slide_speed = lerp(player.wall_slide_slow_speed, player.wall_slide_speed, progress) * player.effective_gravity_multiplier
		player.velocity.y = player.current_wall_slide_speed
		player.velocity.x = 0

	if PlayerAirAbilityServiceScript.try_double_jump(player, jump_just_pressed):
		return

# 处理墙跳后的过渡加速和重新附着判定。
static func handle_walljump_state(player: Node, fixed_delta: float, move_input: float, jump_just_pressed: bool, jump_pressed: bool, _jump_just_released: bool, dash_just_pressed: bool) -> void:
	if try_dash(player, dash_just_pressed):
		return

	if PlayerAirAbilityServiceScript.try_double_jump(player, jump_just_pressed):
		return

	player.wall_jump_timer += fixed_delta

	if player.wall_jump_timer < 0.1:
		var wall_jump_direction: int = -player.wall_grip_direction if player.wall_grip_direction != 0 else -player.wall_direction
		player.velocity.x = player.wall_jump_h_speed * wall_jump_direction * player.effective_horizontal_multiplier
		player.velocity.y = player.wall_jump_v_speed * player.effective_vertical_multiplier
	else:
		if move_input != 0:
			var target_speed = move_input * player.base_move_speed
			player.velocity.x = move_toward(player.velocity.x, target_speed, player.air_control * player.ground_acceleration * player.base_move_speed * player.effective_acceleration_multiplier)

	if jump_pressed and player.wall_jump_hold_timer < player.wall_jump_max_hold_time:
		player.velocity.y += player.wall_jump_hold_boost
		player.wall_jump_hold_timer += fixed_delta

	player.apply_gravity(fixed_delta)

	if player.wall_jump_timer >= player.wall_jump_reattach_delay:
		player.can_reattach_to_wall = true
		if try_start_wallgrip_from_air(player, move_input):
			return
		elif player.velocity.y >= 0:
			player.change_state(player.PlayerState.DOWN)

	# 处理撞墙后的反弹和相机反馈。
static func handle_wall_bump(player: Node) -> void:
	CameraShakeManager.shake("x_strong", player.phantom_camera)
	player.trigger_feedback_event(&"wall_bump", {})
	player.velocity.x = player.wall_bump_rebound_x * (-1 if player.is_facing_right else 1)
	player.velocity.y = player.wall_bump_rebound_y
	player.hurt_timer = maxf(player.run_wall_bump_control_lock_time, 0.0)
	player.lock_control(maxf(player.run_wall_bump_control_lock_time, 0.0), "run_wall_bump")
	player.is_wall_bump_stun = true

# 处理撞墙僵直期间的重力与恢复。
static func handle_wall_bump_stun(player: Node, fixed_delta: float) -> void:
	player.apply_gravity(fixed_delta)
	var bump_decel: float = player.ground_deceleration if player.is_on_floor() else player.air_deceleration
	player.velocity.x = move_toward(player.velocity.x, 0, bump_decel * player.base_move_speed * fixed_delta)
	player.hurt_timer -= fixed_delta

	if player.hurt_timer <= 0:
		player.is_wall_bump_stun = false
		if player.is_control_locked:
			player.unlock_control()
		# 撞墙僵直结束后重置二段跳状态，允许空中跳跃
		player.has_double_jumped = false
		player.can_double_jump = true
		if player.is_on_floor():
			player.change_state(player.PlayerState.IDLE)
		else:
			player.change_state(player.PlayerState.DOWN)

# 尝试从空中直接进入攀墙状态。
static func try_enter_wallgrip_from_air(player: Node, move_input: float, jump_just_pressed: bool = false) -> bool:
	return try_start_wallgrip_from_air(player, move_input, jump_just_pressed)

# 统一空中挂墙判定：缓冲期内只允许回到原墙，避免双墙互抢。
static func try_start_wallgrip_from_air(player: Node, move_input: float, jump_just_pressed: bool = false) -> bool:
	if not player.wall_grip_unlocked or not player.is_touching_wall or player.is_on_floor():
		return false
	if jump_just_pressed:
		return false
	var detected_wall_direction: int = player.wall_direction
	if detected_wall_direction == 0:
		return false
	if move_input == 0 or sign(move_input) != detected_wall_direction:
		return false
	if player.wall_jump_escape_buffer_timer > 0.0 and player.wall_grip_direction != 0 and detected_wall_direction == player.wall_grip_direction:
		return false
	player.start_wallgrip()
	return player.current_state == player.PlayerState.WALLGRIP
