extends RefCounted
class_name PlayerStateTransitionService

# 处理状态退出时的副作用。
static func apply_exit_state(player: Node, from_state: int) -> void:
	match from_state:
		player.PlayerState.DASH:
			if player.dash_locked_vector.y == 0:
				# 水平冲刺退出：应用水平惯性
				player.velocity.x = player.dash_inertia_speed * player.effective_horizontal_multiplier * sign(player.dash_locked_vector.x)
			else:
				# 垂直冲刺退出：终止跳跃按住时间加成（切换状态后不应继续生效）。
				player.jump_hold_timer = player.max_jump_hold_time
				# 地面垂直冲刺退出时启用空中能力（二段跳、滑翔等）。
				if not player.has_dashed_in_air:
					player.is_jumping = true
					player.jump_count = 1
					player.has_double_jumped = false
					player.can_double_jump = true
					player.can_glide = false
					player.is_double_jump_holding = false
			player.dash_locked_vector = player.dash_locked_vector.normalized()
			player.can_reattach_to_wall = true

		player.PlayerState.JUMP:
			if player.is_jump_interrupt_decaying:
				player.is_jump_interrupt_decaying = false
				player.jump_interrupt_decay_timer = 0.0

		player.PlayerState.WALLGRIP:
			player.hold_toward_wall_timer = 0.0
			player.no_input_timer = 0.0
			player.current_wall_slide_speed = 0.0

		player.PlayerState.WALLJUMP:
			player.can_reattach_to_wall = true

		player.PlayerState.DOWN:
			player._landing_downend_active = false

		player.PlayerState.LOOKUP, player.PlayerState.LOOKDOWN:
			player.reset_camera_position()

		player.PlayerState.SLEEP:
			player.sleep_timer = 0.0

		player.PlayerState.BACKSTEP:
			player.backstep_timer = 0.0

# 处理状态进入时的副作用。
static func apply_enter_state(player: Node, to_state: int, from_state: int) -> void:
	match to_state:
		player.PlayerState.DOWN:
			player.down_state_entry_time = 0.0

		player.PlayerState.SLEEP:
			player.sleep_timer = 0.0

		player.PlayerState.DIE:
			# 若之前进入过传送伤害追镜，死亡时强制恢复到正常跟随与 dead zone。
			if player.camera_controller \
				and player.camera_controller.has_method("has_pending_warp_camera_hold") \
				and player.camera_controller.has_pending_warp_camera_hold() \
				and player.camera_controller.has_method("notify_warp_player_teleported"):
				player.camera_controller.notify_warp_player_teleported()
			if player.camera_controller and player.camera_controller.has_method("begin_death_camera_freeze"):
				player.camera_controller.begin_death_camera_freeze()
			player.die_timer = player.die_animation_time
			player.is_invincible = true
			player.animated_sprite.rotation_degrees = 0
			player.jump2_rotation = 0
			player.animated_sprite.modulate.a = 0.5

		player.PlayerState.HURT:
			player.is_invincible = true
			player.invincible_timer = player.hurt_invincible_time
			player.animated_sprite.rotation_degrees = 0
			player.jump2_rotation = 0
			player.animated_sprite.modulate.a = 0.5

		player.PlayerState.DASH:
			if player.dash_locked_vector == Vector2.ZERO:
				player.dash_locked_vector = Vector2.RIGHT if player.is_facing_right else Vector2.LEFT
			if from_state == int(player.PlayerState.WALLJUMP):
				player.can_reattach_to_wall = false

		player.PlayerState.WALLGRIP:
			player.hold_toward_wall_timer = 0.0
			player.no_input_timer = 0.0
			player.current_wall_slide_speed = 0.0
			player.has_double_jumped = false
			player.can_double_jump = true
			player.has_dashed_in_air = false
			player.current_animation = "WALLGRIP"
			player.animated_sprite.play("WALLGRIP")

		player.PlayerState.BACKSTEP:
			player.backstep_timer = 0.0
			player.backstep_afterimage_timer = 0.0
			player.backstep_counter_consumed = false
			if player.backstep_direction == 0:
				player.backstep_direction = -1 if player.is_facing_right else 1

static func change_state(player: Node, new_state: int) -> void:
	if player.current_state == new_state:
		return
	apply_exit_state(player, int(player.current_state))
	if new_state == player.PlayerState.DIE:
		player.is_in_death_process = true
	var previous_state = player.current_state
	apply_enter_state(player, int(new_state), int(player.current_state))
	player.current_state = new_state
	player.trigger_feedback_event(&"state_changed", {
		"from": previous_state,
		"to": new_state
	})
