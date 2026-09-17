# Scripts/Instances/Platforms/Platform.gd
## 平台系统（纯位置跟随模式——蔚蓝风格）
## 继承 Node2D，通过移动 StaticBody2D 子节点实现碰撞跟随。
## Player 通过读取 get_platform_velocity() 手动叠加速度，而非依赖物理自动携带。
## 修复：Player 在平台上受伤时不会与平台物理冲突导致"消失"。
##
## 动画状态机：
##   ON（静止）←→ ONMOVE（移动）
##   ON →（player 站上且 brittle）→ CLOSE（非循环，播完→OFF）
##   OFF →（recover_time 后）→ OPEN（非循环，播完→ON）
##
## 碰撞体规则：ON / ONMOVE / CLOSE →启用，OFF / OPEN →禁用
## 移动规则：OFF / CLOSE / OPEN →不移动
extends Node2D
class_name Platform

enum MovementMode { STATIC, LINEAR, CIRCULAR }
enum PlatformAnim { ON, ONMOVE, OFF, CLOSE, OPEN }
enum SpriteEffect { NONE, FLIP }

## ── 移动设置（严格匹配 HurtBox）──
@export_category("移动设置")
## 移动模式：0=静止，1=直线往返，2=圆周往返
@export var movement_mode: MovementMode = MovementMode.STATIC

## 移动通用参数（HurtBox 同款）
@export_category("移动通用参数")
## 移动速度（像素/秒）
@export var move_speed: float = 100.0
## 终点偏移（相对初始位置）
@export var end_offset: Vector2 = Vector2(200, 0)
## 端点停留时间（秒）
@export var wait_time: float = 1.0
## 加速时间（秒）
@export var acceleration_time: float = 0.5
## 减速时间（秒）
@export var deceleration_time: float = 1.0
## 精灵视觉效果
@export var sprite_effect: SpriteEffect = SpriteEffect.FLIP


## 圆周专用参数
@export_category("圆周专用参数")
## 圆周运动方向
@export var circular_clockwise: bool = true

## ── 玩家交互 ──
@export_category("玩家交互")
## player 站在平台上后停止移动
@export var stop_when_player_stands: bool = false
## 玩家在平台上的水平速度乘数
@export var horizontal_speed_multiplier: float = 1.0

## ── 破碎 ──
@export_category("破碎设置")
## 是否可破碎
@export var brittle: bool = false
## 破碎倒计时（秒），player站上后等待此时间再播 CLOSE 动画
@export var break_countdown: float = 0.1
## 破碎后恢复等待时间（秒）
@export var recover_time: float = 2.5

# ── 移动状态（HurtBox 同款）──
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
var _prev_position: Vector2  # 用于圆周差值移动和速度计算
var _prev_progress: float = -1.0  # 移动冻结诊断
var _stuck_frames: int = 0
var _anim_state: PlatformAnim = PlatformAnim.ON
var _player_on: bool = false
#var _last_position: Vector2
var _platform_velocity: Vector2 = Vector2.ZERO

# ── 破碎状态 ──
var _brittle_active: bool = false
var _break_countdown_timer: float = 0.0
var _recover_timer: float = 0.0

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var _collision_body: StaticBody2D = $Body
@onready var collision_shape: CollisionShape2D = $Body/CollisionShape2D
@onready var _detect_area: Area2D = $Body/Area2D

# 保存在 Inspector 中设置的 collision_layer（含 Wall 等自定义层），不被 _set_collision_deferred 覆盖
var _base_collision_layer: int = 2


func _ready():
	_base_collision_layer = _collision_body.collision_layer
	_start_pos = global_position
	_end_pos = _start_pos + end_offset
	_path_length = end_offset.length()
	_wait_timer = wait_time
	_prev_position = global_position
	
	if movement_mode == MovementMode.CIRCULAR and _path_length > 0.0:
		_circle_center = _start_pos + end_offset * 0.5
		_circle_radius = _path_length * 0.5
	
	_set_collision_deferred(true)
	_play_anim(PlatformAnim.ON)
	
	if _detect_area:
		_detect_area.body_entered.connect(_on_player_entered)
		_detect_area.body_exited.connect(_on_player_exited)
	
	if animated_sprite:
		animated_sprite.animation_finished.connect(_on_anim_finished)


func _physics_process(delta: float) -> void:
	var fd := minf(delta, 1.0 / 30.0)
	
	_platform_velocity = (global_position - _prev_position) / maxf(fd, 0.001)
	_prev_position = global_position
	
	# ── 移动冻结诊断（设备用，不修改逻辑）──
	if movement_mode != MovementMode.STATIC and not _is_waiting and not _brittle_active:
		if _prev_progress == _progress:
			_stuck_frames += 1
			if _stuck_frames == 120:
				var room_node: Node = null
				if get_parent() and get_parent().get_parent():
					room_node = get_parent().get_parent()
				var room_name: String = str(room_node.name) if room_node else "?"
				print("[Platform] 疑似冻结: node=", name, " room=", room_name,
					" mode=", movement_mode, " progress=", _progress, " speed=", _current_speed,
					" waiting=", _is_waiting, " is_finite=", is_finite(_progress))
		else:
			_stuck_frames = 0
		_prev_progress = _progress
	
	# NaN 保护
	if not is_finite(_progress): _progress = 0.0
	if not is_finite(_current_speed): _current_speed = 0.0
	if not is_finite(_wait_timer): _wait_timer = 0.0
	
	# 破碎流程（含倒计时）
	if _brittle_active:
		if _break_countdown_timer > 0.0:
			_break_countdown_timer -= fd
			if _break_countdown_timer <= 0.0:
				_set_collision_deferred(true)
				_play_anim(PlatformAnim.CLOSE)
		else:
			match _anim_state:
				PlatformAnim.OFF:
					_recover_timer -= fd
					if _recover_timer <= 0.0:
						_play_anim(PlatformAnim.OPEN)
		return
	
	# 破碎持续检测——player 从侧面进入或平台移动后 player 到达顶部时才触发破碎
	if brittle and not _brittle_active and _player_on and _anim_state != PlatformAnim.OFF:
		var body := get_tree().get_first_node_in_group("player")
		if body and body.global_position.y < global_position.y - 4.0:
			_on_player_stood()
	
	if stop_when_player_stands and _player_on and movement_mode != MovementMode.STATIC:
		_play_anim(PlatformAnim.ON)
		return
	
	if _anim_state != PlatformAnim.ON and _anim_state != PlatformAnim.ONMOVE:
		return
	
	if movement_mode == MovementMode.STATIC:
		_play_anim(PlatformAnim.ON)
		return
	
	handle_movement(fd)
	_update_sprite_effect()


## ── 移动逻辑（严格匹配 HurtBox handle_movement）──
func handle_movement(delta: float) -> void:
	if _path_length <= 0.0 or move_speed <= 0.0:
		_play_anim(PlatformAnim.ON)
		return
	
	# 端点等待
	if _is_waiting:
		_wait_timer -= delta
		if _wait_timer <= 0.0:
			_is_waiting = false
			_moving_to_end = not _moving_to_end
			_current_speed = 0.0
		return
	
	# 加减速判定（HurtBox 距离判定法）
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
	
	# ★ 根因修复：减速到 0 且接近终点时强制到达，避免 epsilon 精度差导致永久冻结
	if _current_speed <= 0.0 and dist_left < half_decel * 0.5:
		if _moving_to_end:
			_progress = 1.0
			global_position = _end_pos
		else:
			_progress = 0.0
			global_position = _start_pos
		_is_waiting = true
		_wait_timer = wait_time
		_play_anim(PlatformAnim.ON)
		return
	
	# 推进进度
	var step: float = (_current_speed * delta) / _path_length
	_progress += step if _moving_to_end else -step
	if not is_finite(_progress):
		_progress = 0.0
	
	# 到达检测
	var eps: float = 0.001
	if _moving_to_end:
		if _progress >= 1.0 - eps:
			_progress = 1.0
			global_position = _end_pos
			_is_waiting = true
			_wait_timer = wait_time
			_play_anim(PlatformAnim.ON)
			return
	else:
		if _progress <= eps:
			_progress = 0.0
			global_position = _start_pos
			_is_waiting = true
			_wait_timer = wait_time
			_play_anim(PlatformAnim.ON)
			return
	
	_progress = clampf(_progress, 0.0, 1.0)
	_update_position()
	_play_anim(PlatformAnim.ONMOVE)


## 位置插值（HurtBox 同款：_update_position）
func _update_position() -> void:
	match movement_mode:
		MovementMode.LINEAR:
			global_position = _start_pos.lerp(_end_pos, _progress)
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
			global_position = _circle_center + _circle_radius * (end_dir * cos(angle) + perp * sin(angle))


## ── 精灵翻转（HurtBox 同款 FLIP 逻辑）──
func _update_sprite_effect() -> void:
	if sprite_effect != SpriteEffect.FLIP or animated_sprite == null:
		return
	if movement_mode != MovementMode.STATIC and end_offset.x != 0.0:
		var moving_right: bool = (end_offset.x > 0) == _moving_to_end
		animated_sprite.scale.x = 1.0 if moving_right else -1.0
	elif animated_sprite.scale.x != 1.0:
		animated_sprite.scale.x = 1.0


## ── 破碎 ──
func _on_player_stood() -> void:
	if not brittle or _brittle_active or _anim_state == PlatformAnim.OFF:
		return
	_brittle_active = true
	_break_countdown_timer = break_countdown

## 倒计时结束后启动 CLOSE（由 _physics_process 调用）
func _on_player_stood_impl() -> void:
	if _anim_state != PlatformAnim.ON and _anim_state != PlatformAnim.ONMOVE:
		return
	_set_collision_deferred(true)
	_play_anim(PlatformAnim.CLOSE)
	# CLOSE 播完后自动切 OFF（监听 animation_finished）


func _on_anim_finished() -> void:
	if animated_sprite == null:
		return
	var current := animated_sprite.animation
	if current == "CLOSE":
		_anim_state = PlatformAnim.OFF
		_set_collision_deferred(false)
		_recover_timer = recover_time
		_play_anim(PlatformAnim.OFF)  # 播完 CLOSE 立即切 OFF 动画，不卡最后一帧
	elif current == "OPEN":
		_brittle_active = false
		_anim_state = PlatformAnim.ON
		_set_collision_deferred(true)
		_play_anim(PlatformAnim.ON)


## ── 碰撞体控制（在子 StaticBody2D 上操作）──
func _set_collision_deferred(enabled: bool) -> void:
	if collision_shape:
		collision_shape.set_deferred("disabled", not enabled)
	_collision_body.set_deferred("collision_layer", _base_collision_layer if enabled else 0)


## ── 动画播放 ──
func _play_anim(anim: PlatformAnim) -> void:
	_anim_state = anim
	var anim_name := ""
	match anim:
		PlatformAnim.ON: anim_name = "ON"
		PlatformAnim.ONMOVE: anim_name = "ONMOVE"
		PlatformAnim.OFF: anim_name = "OFF"
		PlatformAnim.CLOSE: anim_name = "CLOSE"
		PlatformAnim.OPEN: anim_name = "OPEN"
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation(anim_name):
		animated_sprite.play(anim_name)


## ── 对外接口 ──
func get_platform_velocity() -> Vector2:
	return _platform_velocity


## ── Player 检测 ──
func _on_player_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	_player_on = true
	
	# 破碎判定：只允许 player 在平台上方时触发
	if brittle and not _brittle_active and _anim_state != PlatformAnim.OFF:
		var on_top: bool = body.global_position.y < global_position.y - 4.0
		if on_top:
			_on_player_stood()
	
	# 速度乘数延迟一帧，避免 player 尚未就绪
	if horizontal_speed_multiplier != 1.0 and EnvironmentManager:
		call_deferred("_apply_speed_multiplier")


func _apply_speed_multiplier() -> void:
	if EnvironmentManager:
		EnvironmentManager.set_environment_multipliers(horizontal_speed_multiplier, 1.0, 1.0, 1.0, 1.0)


func _on_player_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	_player_on = false
	if horizontal_speed_multiplier != 1.0 and EnvironmentManager:
		EnvironmentManager.clear_environment()
