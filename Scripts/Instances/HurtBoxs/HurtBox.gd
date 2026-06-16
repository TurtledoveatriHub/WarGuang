extends Area2D

const MAX_FRAME_TIME: float = 1.0 / 30.0

## 移动模式枚举：0=静止，1=直线，2=波浪，3=圆周
enum MovementMode { STATIC = 0, LINEAR = 1, WAVE = 2, CIRCULAR = 3 }
## 伤害类型枚举（可扩展）
enum DamageType { NORMAL = 0, SHADOW = 1 }
## 动画相位状态
enum AnimPhase { ON, CLOSING, OFF, OPENING }
## Sprite效果（与移动方向无关，仅视觉）
enum SpriteEffect { NONE, ROTATE, FLIP }

## 伤害设置
@export_category("伤害设置")
## 伤害类型（普通扣1血，阴影扣2血）
@export var damage_type: DamageType = DamageType.NORMAL
## 是否为传送伤害（独立于普通/阴影，会触发传送受击流程）
@export var is_warp_damage: bool = false
## 水平击退力
@export var horizontal_knockback_force: float = 300.0
## 垂直击退力
@export var vertical_knockback_force: float = 400.0
## 伤害冷却时间（秒）
@export var damage_cooldown_time: float = 0.1
## 持续伤害间隔（秒，0=每次冷却后立即触发）
@export var continuous_damage_interval: float = 0.5

## 旋转设置
@export_category("旋转设置")
## 精灵视觉效果：NONE=无, ROTATE=旋转, FLIP=往返水平翻转（碰撞体不翻）
@export var sprite_effect: SpriteEffect = SpriteEffect.NONE
## 旋转速度（度/秒），仅 ROTATE 模式有效
@export var rotation_speed: float = 90.0
## 旋转方向：true=顺时针，false=逆时针
@export var clockwise: bool = true
## 是否同时旋转碰撞体（可独立启用）
@export var rotate_collision: bool = false

## 伤害周期设置
@export_category("伤害周期设置")
## 是否周期性开关伤害检测（false=永久ON检测）
@export var enable_periodic_damage: bool = false
## 开启持续时间（秒），结束后播放 CLOSE 切为 OFF
@export var active_time: float = 3.0
## 关闭持续时间（秒），结束后播放 OPEN 切为 ON
@export var inactive_time: float = 2.0

## 移动模式
@export_category("移动模式")
## 0=静止，1=直线往返，2=波浪往返，3=圆周往返
@export var movement_mode: MovementMode = MovementMode.STATIC

## 移动通用参数（所有移动模式共用同一组）
@export_category("移动通用参数")
## 移动速度（像素/秒）
@export var move_speed: float = 240.0
## 终点偏移（相对编辑器放置位置）
@export var end_offset: Vector2 = Vector2(720, 0)
## 端点停留时间（秒）
@export var wait_time: float = 0.5
## 加速时间（秒）
@export var acceleration_time: float = 0.5
## 减速时间（秒）
@export var deceleration_time: float = 1.0

## 波浪专用参数
@export_category("波浪专用参数")
## 振幅（像素），偏离直线的最大垂直距离
@export var wave_amplitude: float = 360.0
## 周期，每次往返中正弦波完成几个完整振荡
@export var wave_period: float = 2.0
## 波浪初始方向：true=先向上，false=先向下
@export var wave_start_up: bool = true
## 往返时波浪方向相反（折返时正弦相位翻转）
@export var wave_reverse_on_return: bool = false

## 圆周专用参数
@export_category("圆周专用参数")
## 圆周运动方向（仅在 CIRCULAR 模式有效）
@export var circular_clockwise: bool = true

## 高级检测设置
@export_category("高级检测设置")
## 启用预测性碰撞检测（高速物体建议开启）
@export var enable_predictive_detection: bool = true
## 预测帧数，检测未来几帧的位置
@export var prediction_frames: int = 2
## 精确碰撞检测（使用 shape.collide()）
@export var enable_precise_collision: bool = true
## 调试输出
@export var enable_debug: bool = false

# 节点引用
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
## 所有 CollisionShape2D 子节点（拖拽引用或自动查找，支持任意数量）
@export var collision_shapes: Array[CollisionShape2D] = []

# 路径计算常量（_ready 中初始化）
## 起点位置（编辑器放置位置）
var start_pos: Vector2
## 终点位置（起点 + end_offset）
var end_pos: Vector2
## 起点到终点的距离
var path_length: float
## 垂直于路径方向的单位向量
var perp_dir: Vector2

# 圆形轨迹常量
## 圆心 = (start + end) / 2
var circle_center: Vector2
## 半径 = 直径 / 2
var circle_radius: float

# 循环计数器（用于调试往返停止问题）
var _round_trip_count: int = 0

# 进度驱动变量
var _progress: float = 0.0
var _moving_to_end: bool = true

# 移动物理变量
var current_speed: float = 0.0
var is_waiting: bool = false
var wait_timer: float = 0.0

# 动画周期变量
## 当前动画相位
var _anim_phase: AnimPhase = AnimPhase.ON
## 开启/关闭计时器，ON 时累加至 active_time，OFF 时累加至 inactive_time
var _phase_timer: float = 0.0
## 是否允许伤害检测（ON=true，其余 false）
var _damage_allowed: bool = true

# 伤害变量
var bodies_in_area: Array = []
var damage_timers: Dictionary = {}
var damage_cooldown: Dictionary = {}
var debug_timer: float = 0.0

func _ready():
	# 路径常量（统一使用 move_speed / end_offset / wait_time / acceleration/deceleration_time）
	start_pos = global_position
	end_pos = start_pos + end_offset
	path_length = end_offset.length()
	if path_length > 0:
		perp_dir = Vector2(-end_offset.normalized().y, end_offset.normalized().x)
	else:
		perp_dir = Vector2.UP
	
	# 圆形常量
	circle_center = start_pos + end_offset * 0.5
	circle_radius = path_length * 0.5
	
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	
	# 自动查找所有 CollisionShape2D 子节点（拖拽缺失时的兜底）
	if collision_shapes.is_empty():
		for child in get_children():
			if child is CollisionShape2D:
				collision_shapes.append(child)
	
	# 设置物理层：自身在 HurtBox 层(5)，仅监听 Player 层(1)
	# 避免和地面/墙壁等 StaticBody 产生物理推挤
	collision_layer = 16  # 2^4 = 层5 HurtBox
	collision_mask = 1    # 2^0 = 层1 Player
	
	# 初始动画
	animated_sprite.play("ON")
	
	if enable_debug:
		print("HurtBox: 初始化 mode=", movement_mode, " 周期=", enable_periodic_damage)


func _process(delta):
	var scaled_delta: float = delta * Engine.time_scale
	var fixed_delta: float = min(delta, MAX_FRAME_TIME)
	
	# 旋转 / 翻转（枚举互斥，同一时间只有一个生效）
	var rot_amount: float = rotation_speed * (1.0 if clockwise else -1.0) * scaled_delta
	match sprite_effect:
		SpriteEffect.ROTATE:
			animated_sprite.rotation_degrees += rot_amount
			if rotate_collision:
				_for_each_shape(func(s): s.rotation_degrees += rot_amount)
			if animated_sprite.scale.x != 1.0:
				animated_sprite.scale.x = 1.0
		SpriteEffect.FLIP:
			if movement_mode != MovementMode.STATIC and end_offset.x != 0.0:
				var moving_right: bool = (end_offset.x > 0) == _moving_to_end
				animated_sprite.scale.x = 1.0 if moving_right else -1.0
			elif animated_sprite.scale.x != 1.0:
				animated_sprite.scale.x = 1.0
		SpriteEffect.NONE:
			if animated_sprite.scale.x != 1.0:
				animated_sprite.scale.x = 1.0
			if rotate_collision:
				_for_each_shape(func(s): s.rotation_degrees += rot_amount)
	
	# 动画周期
	update_anim_cycle(delta)
	
	# 移动
	if movement_mode != MovementMode.STATIC:
		handle_movement(fixed_delta)
	
	# 伤害检测（仅在 _damage_allowed 时执行）
	if _damage_allowed:
		handle_damage(delta, scaled_delta)
	
	if enable_debug:
		debug_timer += delta
		if debug_timer >= 1.0:
			debug_timer = 0.0
			print("HurtBox: 玩家=", bodies_in_area.size(), " 相位=", _anim_phase, " 伤害=", _damage_allowed, " 进度=", _progress, " 翻转=", animated_sprite.scale.x)

# ── 信号回调 ──────────────────────────────────────

func _on_body_entered(body):
	if body.is_in_group("player"):
		if not body in bodies_in_area:
			bodies_in_area.append(body)
			if enable_debug:
				print("HurtBox: 玩家进入")
			if _damage_allowed and continuous_damage_interval <= 0:
				if not damage_cooldown.has(body) or damage_cooldown[body] <= 0:
					apply_damage(body)
					damage_cooldown[body] = damage_cooldown_time
			elif _damage_allowed:
				if not damage_timers.has(body):
					damage_timers[body] = continuous_damage_interval

func _on_body_exited(body):
	if body in bodies_in_area:
		bodies_in_area.erase(body)
		if enable_debug:
			print("HurtBox: 玩家离开")
	if damage_timers.has(body):
		damage_timers.erase(body)
	if damage_cooldown.has(body):
		damage_cooldown.erase(body)

# ── 移动逻辑 ──────────────────────────────────────

func handle_movement(delta: float) -> void:
	if path_length <= 0.0 or move_speed <= 0.0:
		return
	
	# 端点等待
	if is_waiting:
		wait_timer -= delta
		if wait_timer <= 0:
			is_waiting = false
			_moving_to_end = not _moving_to_end
			# 折返后计为完成一次往返
			if _moving_to_end:
				_round_trip_count += 1
				if enable_debug:
					print("HurtBox: 完成第 ", _round_trip_count, " 次往返")
			current_speed = 0.0
		return
	
	# 加减速判定（区分方向）
	var dist_done: float
	var dist_left: float
	if _moving_to_end:
		dist_done = _progress * path_length
		dist_left = (1.0 - _progress) * path_length
	else:
		dist_done = (1.0 - _progress) * path_length
		dist_left = _progress * path_length
	
	var half_accel: float = acceleration_time * move_speed / 2.0
	var half_decel: float = deceleration_time * move_speed / 2.0
	var accel: float = move_speed / acceleration_time if acceleration_time > 0 else move_speed
	var decel: float = move_speed / deceleration_time if deceleration_time > 0 else move_speed
	
	if dist_done < half_accel:
		current_speed = min(current_speed + accel * delta, move_speed)
	elif dist_left < half_decel:
		current_speed = max(current_speed - decel * delta, 0.0)
	else:
		current_speed = move_speed
	
	# 推进进度
	var step: float = (current_speed * delta) / path_length
	if not is_finite(step):
		step = 0.0
	_progress += step if _moving_to_end else -step
	if not is_finite(_progress):
		_progress = 0.0
	
	# 到达检测（分方向）— 加 epsilon 容差防止浮点精度问题
	var arrival_eps: float = 0.001
	if _moving_to_end:
		if _progress >= 1.0 - arrival_eps:
			_progress = 1.0
			global_position = end_pos
			is_waiting = true
			wait_timer = wait_time
			return
	else:
		if _progress <= arrival_eps:
			_progress = 0.0
			global_position = start_pos
			is_waiting = true
			wait_timer = wait_time
			return
	
	_progress = clampf(_progress, 0.0, 1.0)
	_update_position()


func _update_position() -> void:
	match movement_mode:
		MovementMode.LINEAR:
			global_position = start_pos.lerp(end_pos, _progress)
		MovementMode.WAVE:
			var linear_pos: Vector2 = start_pos.lerp(end_pos, _progress)
			var t: float = _progress if _moving_to_end else (1.0 - _progress)
			var phase: float = 0.0 if wave_start_up else PI
			var sign_mult: float = 1.0
			if wave_reverse_on_return and not _moving_to_end:
				sign_mult = -1.0
			var osc: float = sin(t * TAU * wave_period + phase) * sign_mult
			global_position = linear_pos + perp_dir * wave_amplitude * osc
		MovementMode.CIRCULAR:
			var dir_sign: float = 1.0 if circular_clockwise else -1.0
			if _moving_to_end:
				global_position = circle_center + Vector2(circle_radius * cos(dir_sign * PI * (1.0 - _progress)), circle_radius * sin(dir_sign * PI * (1.0 - _progress)))
			else:
				global_position = circle_center + Vector2(circle_radius * cos(-dir_sign * PI * (1.0 - _progress)), circle_radius * sin(-dir_sign * PI * (1.0 - _progress)))

# ── 伤害处理 ──────────────────────────────────────

func handle_damage(delta: float, scaled_delta: float) -> void:
	for i in range(bodies_in_area.size() - 1, -1, -1):
		var body = bodies_in_area[i]
		if not is_instance_valid(body):
			bodies_in_area.remove_at(i)
			if damage_timers.has(body):
				damage_timers.erase(body)
			if damage_cooldown.has(body):
				damage_cooldown.erase(body)
			continue
		if body.is_in_group("player"):
			if not damage_timers.has(body):
				damage_timers[body] = 0.0
			damage_timers[body] += delta
			if damage_timers[body] >= continuous_damage_interval:
				damage_timers[body] = 0.0
				if not damage_cooldown.has(body) or damage_cooldown[body] <= 0:
					apply_damage(body)
					damage_cooldown[body] = 0.1
	for body in damage_cooldown.keys():
		if is_instance_valid(body):
			damage_cooldown[body] -= scaled_delta
			if damage_cooldown[body] <= 0:
				damage_cooldown.erase(body)

# ── 应用伤害（向量化击退） ─────────────────────────

func apply_damage(body) -> bool:
	if body.has_method("is_invincible") and body.is_invincible:
		return false
	if body.has_method("get_player_state") \
	and body.get_player_state() == body.PlayerState.DASH \
	and body.has_method("is_black_dash_unlocked") \
	and body.is_black_dash_unlocked():
		return false
	var direction: Vector2 = (body.global_position - global_position).normalized()
	var angle: float = abs(atan2(direction.y, direction.x) - PI / 2.0)
	var total_force: float = sqrt(
		horizontal_knockback_force * horizontal_knockback_force \
		+ vertical_knockback_force * vertical_knockback_force
	)
	var y_ratio: float = cos(angle)
	var x_ratio: float = sin(angle)
	var knockback_force: Vector2 = Vector2(
		-sign(direction.x) * abs(total_force * x_ratio),
		-abs(total_force * y_ratio)
	)
	if body.has_method("take_damage"):
		if not damage_cooldown.has(body) or damage_cooldown[body] <= 0:
			## 伤害量：NORMAL=1，SHADOW=2
			var final_damage: int = 2 if damage_type == DamageType.SHADOW else 1
			## 类型位：damage_type 自身 + is_warp_damage 左移1位
			var final_type: int = int(damage_type) + (2 if is_warp_damage else 0)
			body.take_damage(global_position, final_damage, final_type, knockback_force)
			damage_cooldown[body] = 0.3
			if enable_debug:
				print("HurtBox: 伤害=", final_damage, " 类型=", final_type, " 击退=", knockback_force)
			return true
	return false

func clear_all_bodies() -> void:
	bodies_in_area.clear()
	damage_timers.clear()
	damage_cooldown.clear()

## 对每个 CollisionShape2D 执行操作（多碰撞体统一控制）
func _for_each_shape(action: Callable) -> void:
	for s in collision_shapes:
		if is_instance_valid(s):
			action.call(s)

# ── 动画周期 ──────────────────────────────────────

func update_anim_cycle(delta: float) -> void:
	if not is_instance_valid(animated_sprite):
		return
	
	if not enable_periodic_damage:
		_damage_allowed = true
		if animated_sprite.animation != "ON":
			animated_sprite.play("ON")
		return
	
	match _anim_phase:
		AnimPhase.ON:
			_damage_allowed = true
			animated_sprite.play("ON")
			_phase_timer += delta
			if _phase_timer >= active_time:
				_anim_phase = AnimPhase.CLOSING
				_phase_timer = 0.0
				animated_sprite.play("CLOSE")
				_damage_allowed = false
		AnimPhase.CLOSING:
			_damage_allowed = false
			if not animated_sprite.is_playing():
				_anim_phase = AnimPhase.OFF
				animated_sprite.play("OFF")
		AnimPhase.OFF:
			_damage_allowed = false
			animated_sprite.play("OFF")
			_phase_timer += delta
			if _phase_timer >= inactive_time:
				_anim_phase = AnimPhase.OPENING
				_phase_timer = 0.0
				animated_sprite.play("OPEN")
		AnimPhase.OPENING:
			_damage_allowed = false
			if not animated_sprite.is_playing():
				_anim_phase = AnimPhase.ON
				animated_sprite.play("ON")
				_damage_allowed = true
