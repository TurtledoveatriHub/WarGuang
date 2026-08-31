extends RefCounted
class_name PlayerAnimationService

# 统一玩家动画更新入口。
static func update_animation(player: Node) -> void:
	if player.is_in_death_process:
		if player.current_animation != "DIE":
			player.current_animation = "DIE"
			player.animated_sprite.play("DIE")
		return

	if player.current_animation != "JUMP2" and player.is_jumpbox_triggered:
		player.clear_jumpbox_effect()

	var target_animation_val: String = ""
	match player.current_state:
		player.PlayerState.IDLE:
			target_animation_val = "IDLE"
		player.PlayerState.MOVE:
			target_animation_val = "MOVE"
		player.PlayerState.RUN:
			target_animation_val = "RUN"
		player.PlayerState.JUMP:
			if player.has_double_jumped:
				if player.is_jumpbox_triggered or player.is_double_jump_holding:
					target_animation_val = "JUMP2"
				else:
					target_animation_val = "JUMP1LOOP"
			elif player.should_jump1start:
				target_animation_val = "JUMP1START"
				player.should_jump1start = false
			elif player.jump1start_played:
				target_animation_val = "JUMP1LOOP"
				player.jump1start_played = false
			elif player.current_animation == "JUMP1LOOP":
				target_animation_val = "JUMP1LOOP"
			elif player.current_animation == "JUMP1START":
				target_animation_val = "JUMP1START"
			else:
				target_animation_val = "JUMP1LOOP"
		player.PlayerState.DOWN:
			if player.has_double_jumped:
				if player.is_jumpbox_triggered or player.is_double_jump_holding:
					target_animation_val = "JUMP2"
				else:
					target_animation_val = "DOWNLOOP"
			elif player._landing_downend_active:
				# 着陆后先播放一遍 DOWNEND
				target_animation_val = "DOWNEND"
			elif player.current_animation == "DOWNEND":
				# DOWNEND 播放中/已播完最后一帧，保持不动
				target_animation_val = "DOWNEND"
			else:
				# 正常下落循环
				target_animation_val = "DOWNLOOP"
		player.PlayerState.DASH:
			if player.black_dash_unlocked:
				target_animation_val = "BLACKDASH"
			else:
				target_animation_val = "DASH"
		player.PlayerState.GLIDE:
			target_animation_val = "GLIDE"
		player.PlayerState.HURT:
			if player.warp_flight_active:
				target_animation_val = "JUMP2"
			else:
				target_animation_val = "HURT"
		player.PlayerState.DIE:
			target_animation_val = "DIE"
		player.PlayerState.SLEEP:
			target_animation_val = "SLEEP"
		player.PlayerState.LOOKUP:
			target_animation_val = "LOOKUP"
		player.PlayerState.LOOKDOWN:
			target_animation_val = "LOOKDOWN"
		player.PlayerState.INTERACTIVE:
			target_animation_val = "INTERACTIVE"
		player.PlayerState.WALLGRIP:
			target_animation_val = "WALLGRIP"
		player.PlayerState.WALLJUMP:
			target_animation_val = "WALLJUMP"
		player.PlayerState.SUPERDASHSTART:
			target_animation_val = "SUPERDASHSTART"
		player.PlayerState.SUPERDASH:
			if player.super_dash_deceleration_timer > 0.0:
				target_animation_val = "SUPERDASHEND"
			else:
				target_animation_val = "SUPERDASH"
		player.PlayerState.BACKSTEP:
			target_animation_val = "BACKSTEP"

	if target_animation_val != player.current_animation and target_animation_val != "":
		if player.current_animation == "JUMP2" and player.is_jumpbox_triggered:
			player.clear_jumpbox_effect()
		player.current_animation = target_animation_val
		player.animated_sprite.play(target_animation_val)

	if player.is_invincible and player.current_state != player.PlayerState.HURT and player.current_state != player.PlayerState.DIE and not player.is_respawn_invincible:
		player.animated_sprite.modulate.a = 0.5
	elif player.current_state != player.PlayerState.HURT and player.current_state != player.PlayerState.DIE:
		player.animated_sprite.modulate.a = 1.0
