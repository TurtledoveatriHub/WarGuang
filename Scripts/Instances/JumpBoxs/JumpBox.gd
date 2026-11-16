# Scripts/Instances/JumpBoxs/JumpBox.gd

## 通过 @export 开关控制移动/生命周期/挑战功能
extends Area2D
class_name JumpBox

## 移动模式
enum MovementMode { STATIC, LINEAR, CIRCULAR, WAVE }

## 动画状态
enum AnimState { NONE, START, YES, YN_TRANSITION, NO, NY_TRANSITION, END }

## 触发效果类型
enum TriggerEffectType {
	BOUNCE_BOOST,  ## 弹跳加强
	SPEED_BOOST,   ## 水平移速加强
	HEAL,          ## 生命恢复
}

## ── 触发判定 ──
@export_category("触发判定")
## 完美触发判定窗口（秒）
@export var perfect_trigger_window: float = 0.12

## ── 通用反馈 ──
@export_category("通用反馈")
## 是否启用触发白闪（打击感）
@export var trigger_white_flash_enabled: bool = true
## 白闪持续时间（秒）
@export var trigger_white_flash_duration: float = 0.1
## 普通触发音效（可选）
@export var normal_trigger_sfx: AudioStream
## 完美触发音效（可选）
@export var perfect_trigger_sfx: AudioStream

## ── 弹跳设置 ──
@export_category("弹跳设置")
## 触发的弹跳效果类型
@export var trigger_effect_type: TriggerEffectType = TriggerEffectType.BOUNCE_BOOST
## 垂直弹跳力（像素/秒）
@export var vertical_force: float = 420.0

## ── 移动设置 ──
@export_category("移动设置")
## 0=静止，1=直线往返，2=圆周往返，3=波浪垂直振荡
@export var movement_mode: MovementMode = MovementMode.STATIC

@export_category("移动通用参数")
## 移动速度（像素/秒）
@export var move_speed: float = 120.0
## 终点偏移（相对初始位置）
@export var end_offset: Vector2 = Vector2(256, 0)
## 端点停留时间（秒）
@export var wait_time: float = 0.5
## 加速时间（秒）
@export var acceleration_time: float = 0.5
## 减速时间（秒）
@export var deceleration_time: float = 0.5

@export_category("圆周专用参数")
## 圆周运动方向：true=顺时针，false=逆时针
@export var circular_clockwise: bool = true

## ── 波浪专用参数（严格对标 HurtBox） ──
@export_category("波浪专用参数")
## 振幅（像素），偏离直线的最大垂直距离
@export var wave_amplitude: float = 256.0
## 周期，每次往返中正弦波完成几个完整振荡
@export var wave_period: float = 1.0
## 波浪初始方向：true=先向上，false=先向下
@export var wave_start_up: bool = true
## 往返时波浪方向相反（折返时正弦相位翻转）
@export var wave_reverse_on_return: bool = false

## ── 挑战系统 ──
@export_category("挑战系统")
## 此 JumpBox 是否属于某个挑战（ChallengeController 通过此字段查找激活）
@export var is_challenge_jumpbox: bool = false

## ── 重生 ──
@export_category("重生")
## 触发后重新启用等待时间（秒）
@export var respawn_time: float = 3.0

## ── 生命周期 ──
@export_category("生命周期")
## 启用后触发→END→销毁，不再重生
@export var enable_lifecycle: bool = false
## YES 状态超时后自动销毁（秒，<=0 不自动销毁）
@export var auto_destroy_time: float = 0.0

@export_category("BOUNCE_BOOST（弹跳加强）")
## BOUNCE_BOOST 普通触发时的 vertical_force 倍率
@export var normal_force_multiplier: float = 1.2
## BOUNCE_BOOST 完美触发时的 vertical_force 倍率
@export var perfect_force_multiplier: float = 1.8

## ── SPEED_BOOST（水平速度加强）参数 ──
@export_category("SPEED_BOOST（水平速度加强）")
## 普通触发时水平加速倍率
@export var normal_horizontal_boost: float = 1.25
## 完美触发时水平加速倍率
@export var perfect_horizontal_boost: float = 1.75
## 普通触发时 boost_duration 倍率
@export var normal_boost_duration: float = 1.25
## 完美触发时 boost_duration 倍率
@export var perfect_boost_duration: float = 2.0

## ── HEAL（生命恢复）参数 ──
@export_category("HEAL（生命恢复）")
## 普通触发回复生命数
@export var heal_normal_amount: int = 1
## 完美触发回复生命数
@export var heal_perfect_amount: int = 2

## 触发时发出（player = 触发者，trigger_grade = "perfect" / "normal"）
signal bounce_triggered(player, trigger_grade)

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var is_active: bool = true
var is_destroying: bool = false
var is_transitioning: bool = false
var current_anim_state: AnimState = AnimState.NONE

var overlapping_players: Dictionary = {}
var pending_perfect_until_ms: Dictionary = {}
var _trigger_flash_default_modulate: Color = Color.WHITE
var _trigger_sfx_player: AudioStreamPlayer2D = null

# ── 移动（全部用相对父节点的局部坐标：父节点若会移动（例：巡游中的 NPC），
#     路径不会被拖着偏移，复位也能回到编辑器里摆的位置）──
var _start_pos: Vector2
var _end_pos: Vector2
var _path_length: float = 0.0
var _progress: float = 0.0
var _moving_to_end: bool = true
var _is_waiting: bool = true
var _wait_timer: float = 0.0
var _current_speed: float = 0.0
var _circle_center: Vector2
var _circle_radius: float = 0.0

# ════════════════════════════════════════
# _ready
# ════════════════════════════════════════

func _ready():
	_start_pos = position
	_end_pos = _start_pos + end_offset
	_path_length = end_offset.length()
	_wait_timer = wait_time
	_is_waiting = false  # 初始不等待，立即开始移动（避免等待结束时的方向翻转与 _progress=0 冲突导致卡死）
	
	if movement_mode == MovementMode.CIRCULAR and _path_length > 0.0:
		_circle_center = _start_pos + end_offset * 0.5
		_circle_radius = _path_length * 0.5
	
	_setup_trigger_detection()
	
	if is_challenge_jumpbox:
		# 挑战 JumpBox：不自启动，等待 ChallengeController 激活
		set_inactive()
		if animated_sprite:
			animated_sprite.visible = false
		return
	# 普通 JumpBox：自动播放 START 动画
	if enable_lifecycle:
		call_deferred("_start_lifecycle")
	else:
		call_deferred("play_start_animation")

func _process(_delta):
	_process_trigger_detection()

func _physics_process(delta: float) -> void:
	if movement_mode == MovementMode.STATIC or not is_active or is_transitioning or is_destroying:
		return
	if current_anim_state != AnimState.YES:
		return
	_handle_movement(delta)

# ════════════════════════════════════════
# 触发检测
# ════════════════════════════════════════

func _setup_trigger_detection() -> void:
	if body_entered.is_connected(_on_body_entered_base) == false:
		body_entered.connect(_on_body_entered_base)
	if body_exited.is_connected(_on_body_exited_base) == false:
		body_exited.connect(_on_body_exited_base)
	_setup_trigger_sfx_player()
	_prepare_trigger_flash_defaults()

func _process_trigger_detection() -> void:
	_check_overlapping_players_for_trigger()

func _on_body_entered_base(body) -> void:
	if body and body.is_in_group("player"):
		overlapping_players[body.get_instance_id()] = body
	if _can_trigger_for_player(body):
		trigger_bounce(body)

func _on_body_exited_base(body) -> void:
	if not body:
		return
	overlapping_players.erase(body.get_instance_id())
	pending_perfect_until_ms.erase(body.get_instance_id())

func _check_overlapping_players_for_trigger() -> void:
	if not _is_trigger_active():
		return
	for player in overlapping_players.values():
		if not is_instance_valid(player):
			continue
		if _can_trigger_for_player(player):
			trigger_bounce(player)
			return

func _can_trigger_for_player(body) -> bool:
	if not body:
		return false
	if not body.is_in_group("player"):
		return false
	if not _is_trigger_active() or not _is_visual_yes_state():
		return false
	if body.current_state == body.PlayerState.DASH:
		return false
	if not body.has_double_jumped:
		return false
	if not _is_player_jumpbox_eligible(body):
		return false
	if body.has_method("can_accept_jumpbox_bounce") and not body.can_accept_jumpbox_bounce():
		return false
	return true

func _is_player_jumpbox_eligible(body) -> bool:
	if body.current_animation == "JUMP2":
		return true
	if body.has_method("is_recent_double_jump_start"):
		return body.is_recent_double_jump_start(perfect_trigger_window)
	return false

func _determine_trigger_grade(player) -> String:
	if player.has_method("is_recent_double_jump_start") and player.is_recent_double_jump_start(perfect_trigger_window):
		return "perfect"
	var player_id = player.get_instance_id()
	var now_ms = Time.get_ticks_msec()
	if pending_perfect_until_ms.has(player_id) and now_ms <= int(pending_perfect_until_ms[player_id]):
		return "perfect"
	return "normal"

func _mark_perfect_candidates_on_yes_activation() -> void:
	var now_ms = Time.get_ticks_msec()
	var expiry_ms = now_ms + int(perfect_trigger_window * 1000.0)
	for player in overlapping_players.values():
		if not is_instance_valid(player):
			continue
		if not player.is_in_group("player"):
			continue
		if not player.has_double_jumped:
			continue
		if player.current_animation != "JUMP2":
			continue
		pending_perfect_until_ms[player.get_instance_id()] = expiry_ms

# ════════════════════════════════════════
# 触发弹跳
# ════════════════════════════════════════

func trigger_bounce(player):
	if not _can_trigger_for_player(player):
		return
	
	var trigger_grade := _determine_trigger_grade(player)
	bounce_triggered.emit(player, trigger_grade)
	
	_apply_trigger_effect(player, trigger_grade)
	_apply_common_feedback(player, trigger_grade)
	pending_perfect_until_ms.erase(player.get_instance_id())
	_consume_after_trigger(player, trigger_grade)

func _apply_trigger_effect(player, trigger_grade: String) -> void:
	var force_mult: float = perfect_force_multiplier if trigger_grade == "perfect" else normal_force_multiplier
	match trigger_effect_type:
		TriggerEffectType.BOUNCE_BOOST:
			var overrides := {"max_vertical_force_multiplier": force_mult}
			if player.has_method("start_jumpbox_bounce"):
				player.start_jumpbox_bounce(vertical_force * force_mult, trigger_grade, overrides)
		TriggerEffectType.SPEED_BOOST:
			var hbm: float = perfect_horizontal_boost if trigger_grade == "perfect" else normal_horizontal_boost
			var bdm: float = perfect_boost_duration if trigger_grade == "perfect" else normal_boost_duration
			var overrides := {
				"max_vertical_force_multiplier": 1.0,
				"horizontal_boost_multiplier": hbm,
				"boost_duration_multiplier": bdm
			}
			if player.has_method("start_jumpbox_bounce"):
				player.start_jumpbox_bounce(vertical_force, trigger_grade, overrides)
		TriggerEffectType.HEAL:
			var overrides := {"max_vertical_force_multiplier": 1.0}
			if player.has_method("start_jumpbox_bounce"):
				player.start_jumpbox_bounce(vertical_force, trigger_grade, overrides)
			var heal_amount: int = heal_perfect_amount if trigger_grade == "perfect" else heal_normal_amount
			# 参考 HealthUpgradeItem 的加血方式
			var pu = player.player_ui
			if pu and pu.has_method("get_health") and pu.has_method("set_health"):
				var cur: int = pu.get_health()
				var max_hp: int = pu.max_health if "max_health" in pu else 5
				var new_hp: int = mini(cur + heal_amount, max_hp)
				pu.set_health(new_hp)
			# 治愈后清除低血量视觉效果（参考静态检查点交互）
			if player.has_method("_clear_low_health_effect"):
				player._clear_low_health_effect()
	if player.has_method("start_jumpbox_hit_stop"):
		player.start_jumpbox_hit_stop(trigger_grade)
	get_tree().create_timer(0.06).timeout.connect(func():
		CameraShakeManager.shake("y_weak", player.phantom_camera)
	)

func _apply_common_feedback(_player, trigger_grade: String) -> void:
	_play_trigger_sfx(trigger_grade)
	_play_trigger_flash()

func _play_trigger_sfx(trigger_grade: String) -> void:
	if _trigger_sfx_player == null:
		return
	var stream: AudioStream = perfect_trigger_sfx if trigger_grade == "perfect" else normal_trigger_sfx
	if stream == null:
		return
	_trigger_sfx_player.stream = stream
	_trigger_sfx_player.play()

func _play_trigger_flash() -> void:
	if not trigger_white_flash_enabled:
		return
	if animated_sprite == null:
		return
	animated_sprite.modulate = Color(2.0, 2.0, 2.0, 1.0)
	var timer := get_tree().create_timer(trigger_white_flash_duration)
	timer.timeout.connect(func():
		if is_instance_valid(animated_sprite):
			animated_sprite.modulate = _trigger_flash_default_modulate
	)

func _prepare_trigger_flash_defaults() -> void:
	if animated_sprite != null:
		_trigger_flash_default_modulate = animated_sprite.modulate

func _setup_trigger_sfx_player() -> void:
	if is_instance_valid(_trigger_sfx_player):
		return
	_trigger_sfx_player = get_node_or_null("TriggerSFX") as AudioStreamPlayer2D
	if _trigger_sfx_player == null:
		_trigger_sfx_player = AudioStreamPlayer2D.new()
		_trigger_sfx_player.name = "TriggerSFX"
		add_child(_trigger_sfx_player)

# ════════════════════════════════════════
# 触发后处理
# ════════════════════════════════════════

func _consume_after_trigger(_player, _trigger_grade: String) -> void:
	if enable_lifecycle:
		if is_destroying:
			return
		set_inactive()
		_play_end_and_destroy()
		return
	is_transitioning = true
	set_inactive()
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("YN_TRANSITION"):
		current_anim_state = AnimState.YN_TRANSITION
		animated_sprite.play("YN_TRANSITION")
		await animated_sprite.animation_finished
	_play_loop_if_exists("NO")
	current_anim_state = AnimState.NO
	if respawn_time > 0.0:
		await get_tree().create_timer(respawn_time).timeout
	if is_destroying:
		return
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("NY_TRANSITION"):
		current_anim_state = AnimState.NY_TRANSITION
		animated_sprite.play("NY_TRANSITION")
		await animated_sprite.animation_finished
	set_active()
	_play_loop_if_exists("YES")
	current_anim_state = AnimState.YES
	_mark_perfect_candidates_on_yes_activation()
	is_transitioning = false

# ════════════════════════════════════════
# 动画流程
# ════════════════════════════════════════

func play_start_animation():
	if is_destroying:
		is_destroying = false
	# 每次开始都从编辑器初始位置重新起步：
	# 否则挑战失败重开时，会从上一次失败那一刻停在的位置继续移动
	reset_movement_state()
	is_transitioning = true
	set_inactive()
	if animated_sprite:
		animated_sprite.visible = true
	current_anim_state = AnimState.START
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("START"):
		animated_sprite.play("START")
		await animated_sprite.animation_finished
	_play_loop_if_exists("YES")
	current_anim_state = AnimState.YES
	set_active()
	_mark_perfect_candidates_on_yes_activation()
	is_transitioning = false

func play_end_animation():
	if not animated_sprite or not animated_sprite.sprite_frames:
		return
	current_anim_state = AnimState.END
	if animated_sprite.sprite_frames.has_animation("END"):
		animated_sprite.play("END")
		await animated_sprite.animation_finished

## 挑战开赛前预处理：回到初始位置并隐藏
## （在屏幕变黑之前调用，避免淡入瞬间闪出上一次结束时的位置）
func prepare_for_challenge() -> void:
	is_destroying = false
	is_transitioning = false
	reset_movement_state()
	set_inactive()
	current_anim_state = AnimState.NONE
	if animated_sprite:
		animated_sprite.visible = false

## 把移动状态复位到编辑器初始位置（挑战重新开始时用，避免从上次失败位置继续运动）
func reset_movement_state() -> void:
	position = _start_pos
	_progress = 0.0
	_moving_to_end = true
	_is_waiting = false
	_wait_timer = 0.0
	_current_speed = 0.0

## 由 ChallengeController 调用：播放 END 动画后禁用+隐藏
func play_end_and_hide() -> void:
	if is_destroying:
		return
	is_destroying = true
	is_transitioning = false
	set_inactive()
	await play_end_animation()
	if animated_sprite:
		animated_sprite.visible = false

func _play_end_and_destroy() -> void:
	if is_destroying:
		return
	is_destroying = true
	is_transitioning = false
	set_inactive()
	await play_end_animation()
	queue_free()

# ════════════════════════════════════════
# 生命周期
# ════════════════════════════════════════

func _start_lifecycle() -> void:
	if is_destroying:
		return
	set_inactive()
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("START"):
		animated_sprite.play("START")
		await animated_sprite.animation_finished
	if is_destroying:
		return
	set_active()
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("YES"):
		animated_sprite.play("YES")
		animated_sprite.sprite_frames.set_animation_loop("YES", true)
	_mark_perfect_candidates_on_yes_activation()
	if auto_destroy_time > 0.0:
		await get_tree().create_timer(auto_destroy_time).timeout
		if not is_destroying and is_active:
			_play_end_and_destroy()

# ════════════════════════════════════════
# 移动逻辑（严格匹配 Platform/HurtBox）
# ════════════════════════════════════════

func _handle_movement(delta: float) -> void:
	if _path_length <= 0.0 or move_speed <= 0.0:
		return
	if _is_waiting:
		_wait_timer -= delta
		if _wait_timer <= 0.0:
			_is_waiting = false
			_moving_to_end = not _moving_to_end
			_current_speed = 0.0
		return
	
	# LINEAR / CIRCULAR / WAVE 统一使用距离加减速逻辑（HurtBox/Platform 同款）
	# CIRCULAR 不再有独立加减速路径，与 LINEAR 共享同一套到达检测
	var dist_done: float = _progress * _path_length if _moving_to_end else (1.0 - _progress) * _path_length
	var dist_left: float = (1.0 - _progress) * _path_length if _moving_to_end else _progress * _path_length
	var half_accel: float = acceleration_time * move_speed / 2.0
	var half_decel: float = deceleration_time * move_speed / 2.0
	var accel: float = move_speed / acceleration_time if acceleration_time > 0.0 else move_speed
	var decel: float = move_speed / deceleration_time if deceleration_time > 0.0 else move_speed
	if dist_done < half_accel:
		_current_speed = minf(_current_speed + accel * delta, move_speed)
	elif dist_left < half_decel:
		_current_speed = maxf(_current_speed - decel * delta, 0.0)
	else:
		_current_speed = move_speed
	if _current_speed <= 0.0 and dist_left < half_decel * 0.5:
		if _moving_to_end:
			_progress = 1.0; position = _end_pos
		else:
			_progress = 0.0; position = _start_pos
		_is_waiting = true; _wait_timer = wait_time
		return
	var step: float = (_current_speed * delta) / _path_length
	_progress += step if _moving_to_end else -step
	if not is_finite(_progress): _progress = 0.0
	var eps: float = 0.001
	if _moving_to_end:
		if _progress >= 1.0 - eps:
			_progress = 1.0; position = _end_pos
			_is_waiting = true; _wait_timer = wait_time; return
	else:
		if _progress <= eps:
			_progress = 0.0; position = _start_pos
			_is_waiting = true; _wait_timer = wait_time; return
	_progress = clampf(_progress, 0.0, 1.0)
	# CIRCULAR 模式在折返点位置可能有累积误差，修正到精确端点
	if movement_mode == MovementMode.CIRCULAR:
		if _progress >= 1.0 - eps:
			_progress = 1.0
			position = _end_pos
		elif _progress <= eps:
			_progress = 0.0
			position = _start_pos
		else:
			_update_position()
	else:
		_update_position()

func _update_position() -> void:
	match movement_mode:
		MovementMode.LINEAR:
			position = _start_pos.lerp(_end_pos, _progress)
		MovementMode.CIRCULAR:
			# ★ 修复：使用 end_offset 方向向量计算圆弧，支持任意方向 end_offset
			var end_dir: Vector2 = end_offset.normalized()
			var perp: Vector2 = Vector2(-end_dir.y, end_dir.x)
			var dir_sign: float = 1.0 if circular_clockwise else -1.0
			var angle: float
			if _moving_to_end:
				angle = dir_sign * PI * (1.0 - _progress)
			else:
				angle = -dir_sign * PI * (1.0 - _progress)
			position = _circle_center + _circle_radius * (end_dir * cos(angle) + perp * sin(angle))
		MovementMode.WAVE:
			# 沿 start→end 直线前进 + 垂直方向正弦波偏移（严格对标 HurtBox）
			var linear_pos: Vector2 = _start_pos.lerp(_end_pos, _progress)
			var t: float = _progress if _moving_to_end else (1.0 - _progress)
			var phase: float = 0.0 if wave_start_up else PI
			var sign_mult: float = 1.0
			if wave_reverse_on_return and not _moving_to_end:
				sign_mult = -1.0
			var osc: float = sin(t * TAU * wave_period + phase) * sign_mult
			# 垂直于 end_offset 的方向
			var perp: Vector2 = Vector2(-end_offset.y, end_offset.x).normalized()
			if perp == Vector2.ZERO:
				perp = Vector2.UP
			position = linear_pos + perp * wave_amplitude * osc

# ════════════════════════════════════════
# 状态控制
# ════════════════════════════════════════

func _is_trigger_active() -> bool:
	if not is_active or is_transitioning or is_destroying:
		return false
	if enable_lifecycle:
		return is_active and not is_destroying
	return current_anim_state == AnimState.YES

func _is_visual_yes_state() -> bool:
	return animated_sprite != null and animated_sprite.animation == "YES"

func set_active() -> void:
	is_active = true
	if collision_shape:
		collision_shape.set_deferred("disabled", false)

func set_inactive() -> void:
	is_active = false
	if collision_shape:
		collision_shape.set_deferred("disabled", true)

func _play_loop_if_exists(anim_name: String) -> void:
	if not animated_sprite or not animated_sprite.sprite_frames:
		return
	if animated_sprite.sprite_frames.has_animation(anim_name):
		animated_sprite.play(anim_name)
		animated_sprite.sprite_frames.set_animation_loop(anim_name, true)
