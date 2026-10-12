extends RefCounted
class_name PlayerAirMotionService

## 处理空中水平输入、惯性与无输入减速。
static func apply_air_horizontal_motion(player: Node, move_input: float) -> void:
	if player.is_gliding or player.is_jump2_boost_active:
		return

	## 空中目标速度上限：跑跳期间临时提高。只提高上限、不直接改速度，
	## 因此加速与“松开方向键的减速”和普通跳跃完全同一套规则。
	## 跑跳的临时上限 = jump_move_speed + run_jump_boost_speed（run_jump_boost_speed 就是“临时增加的上限部分”，不以 run_move_speed 为基准）。
	var air_cap: float = player.jump_move_speed
	if player.is_run_jumping:
		if player.run_jump_timer > 0.0:
			## 爬升：run_jump_boost_ramp_time 秒内线性升到满加成
			var elapsed: float = maxf(player.run_jump_boost_duration - player.run_jump_timer, 0.0)
			var rise_ratio: float = 1.0
			if player.run_jump_boost_ramp_time > 0.0:
				rise_ratio = clampf(elapsed / player.run_jump_boost_ramp_time, 0.0, 1.0)
			air_cap += player.run_jump_boost_speed * rise_ratio
		else:
			## 衰减：保持期结束后按 run_jump_decay_time 把加成降回 0
			var over_time: float = -player.run_jump_timer
			air_cap += player.run_jump_boost_speed * clampf(1.0 - over_time / maxf(player.run_jump_decay_time, 0.01), 0.0, 1.0)

	if move_input != 0:
		var target_speed = move_input * air_cap * player.effective_horizontal_multiplier
		## 空中加速：用独立参数 air_acceleration（px/s²，基准值），实际再乘环境横向倍率
		player.velocity.x = move_toward(player.velocity.x, target_speed, player.air_acceleration * player.effective_horizontal_multiplier * player.get_physics_process_delta_time())
		return

	# 空中无输入：超过空中基准速度（跑跳/冲刺带出的高速）时不再主动减速，
	# 只按 air_overspeed_decay 缓慢衰减超速部分 —— 蔚蓝式“带速滞空”惯性保留。
	var air_base_speed: float = player.jump_move_speed * player.effective_horizontal_multiplier
	if absf(player.velocity.x) > air_base_speed:
		var overspeed_decay: float = player.air_overspeed_decay * player.get_physics_process_delta_time()
		player.velocity.x = move_toward(player.velocity.x, signf(player.velocity.x) * air_base_speed, overspeed_decay)
		return

	# 空中无输入减速：独立 px/s² 参数，JUMP / DOWN 各一个，
	# 不再与 air_control、ground_deceleration、jump_move_speed 相互牵连（仅保留环境加速度倍率）。
	var no_input_decel: float = player.air_no_input_deceleration
	if player.current_state == player.PlayerState.DOWN:
		no_input_decel = player.air_no_input_deceleration_down
	player.velocity.x = move_toward(player.velocity.x, 0, no_input_decel * player.effective_acceleration_multiplier * player.get_physics_process_delta_time())


## 冲刺结束后的垂直阻尼（上/下冲刺 → 短暂滞空 / 保留俯冲动能）。
## 阻尼强度 = up_dash_deceleration / down_dash_deceleration × vertical_dash_speed，
## 只在 dash_vertical_decel_time 秒的窗口内生效（由 PlayerStateTransitionService 开启）。
static func apply_dash_vertical_damping(player: Node, fixed_delta: float) -> void:
	if player.dash_vertical_decel_timer <= 0.0:
		return
	player.dash_vertical_decel_timer = maxf(player.dash_vertical_decel_timer - fixed_delta, 0.0)
	## 冲刺中 / 贴地时不参与（阻尼只服务空中滞空手感）
	if player.current_state == player.PlayerState.DASH or player.is_on_floor():
		return
	if player.current_state == player.PlayerState.HURT or player.current_state == player.PlayerState.DIE:
		return
	var decel_rate: float = player.down_dash_deceleration if player.velocity.y > 0.0 else player.up_dash_deceleration
	var damping: float = decel_rate * player.vertical_dash_speed * fixed_delta
	if damping <= 0.0:
		return
	player.velocity.y = move_toward(player.velocity.y, 0.0, damping)
