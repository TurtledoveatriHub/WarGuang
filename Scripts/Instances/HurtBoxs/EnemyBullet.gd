# Scripts/Instances/HurtBoxs/EnemyBullet.gd
## 独立敌方弹幕（通用组件）—— 可单独拖入场景使用，也可由敌怪实例化并调用 setup() 发射。
## 分工建议：
##   - 本弹幕负责“自身”：默认速度/寿命/伤害/击退（Inspector 外部变量）、生命周期与命中逻辑。
##   - 敌怪负责“火力几何”（多少颗、扇形/连发、张角、发射点），并在实例化后用 setup() 按需覆盖上面的默认值。
## 场景要求：根节点 Area2D + CollisionShape2D + AnimatedSprite2D。
## AnimatedSprite2D 需提供 3 个动画：Spawn(生成,播一次) / Fly(持续,loop) / Die(销毁,播一次)；
## 缺动画时不报错（没有 Spawn 直接飞，没有 Die 直接释放），美术就绪后把帧填进 SpriteFrames 即可。
## 生命周期：Spawn → 移动(Fly) → 命中玩家/撞地形(层2/3/6)/寿命耗尽 → Die → 自动释放。
## 命中走 body_entered 信号，不做每帧轮询（适合移动端）。
extends Area2D
class_name EnemyBullet

## 地形层掩码：层2(bit1=2)、层3(bit2=4)、层6(bit5=32)（与项目 2D 物理层约定一致）
const TERRAIN_MASK: int = 2 | 4 | 32

## ── 飞行 ──
@export_category("飞行")
## 直线飞行速度（像素/秒）
@export var speed: float = 240.0
## 存活时间（秒），耗尽后自动进入销毁
@export var life_time: float = 3.0
## 是否受重力影响（false=纯直线弹道）
@export var affected_by_gravity: bool = false
## 重力加速度（像素/秒²），仅 affected_by_gravity / parabolic_mode 时生效（注意不可与 Area2D 原生 gravity 重名）
@export var bullet_gravity: float = 600.0
## 抛物线攻击模式：true 且敌怪传入瞄准点时，自动解算带重力的弧线初速落向目标；否则为普通直线/重力弹
@export var parabolic_mode: bool = false
## 出膛加速时间（秒）：0=立刻达到飞行速度；>0 表示从 0 线性加速到 speed 所需时长
@export var accel_time: float = 0.4

## ── 瞄准与朝向 ──
@export_category("瞄准与朝向")
## 出膛随机散射角（度，0=精确锁定；>0 则每发在 ±scatter_deg 内随机偏转）
@export var scatter_deg: float = 10.0
## 是否让弹幕整体（贴图+碰撞体）实时旋转，使朝向速度方向（默认贴图朝右）
@export var rotate_to_velocity: bool = true
## 朝向刷新间隔（秒）：每隔该时长才重新采样速度方向并旋转一次（省计算）
@export var facing_update_interval: float = 0.2

## ── 伤害 ──
@export_category("伤害")
## 对玩家造成的伤害值
@export var damage: int = 1
## 命中玩家的击退力（方向=自身飞行方向）
@export var knockback: Vector2 = Vector2(100, 100)
## 玩家处于无敌/冲刺时本弹是否穿透（true=不销毁、继续飞行）
@export var pierce_invincible: bool = true

## ── 碰撞/消失 ──
@export_category("碰撞与消失")
## 是否被地形(层2/3/6)阻挡并消失（false=穿墙）
@export var block_by_terrain: bool = true
## 销毁动画最长等待（秒），超时强制释放，防止动画缺失导致永久残留
@export var die_max_wait: float = 1.2
## 碰到地形时是否反弹（需 block_by_terrain=true 才会有地形碰撞）
@export var bounce_on_terrain: bool = false
## 反弹次数上限（达到后销毁；0=一碰即销毁）
@export var bounce_max: int = 2

## ── 音效（可留空）──
@export_category("音效")
## 生成音效
@export var spawn_sfx: AudioStream
## 销毁音效
@export var destroy_sfx: AudioStream

## ── 内部状态 ──
## 生命阶段
enum Stage { SPAWN, FLY, DIE }
## 当前阶段
var _stage: int = Stage.FLY
## 当前飞行方向（单位向量，由 setup() 指定；不做外部变量）
var _dir: Vector2 = Vector2.RIGHT
## 剩余寿命（秒）
var _life: float = 3.0
## 销毁等待计时（秒）
var _die_wait: float = 0.0
## 是否已命中（防止重复伤害）
var _hit: bool = false
## 内部速度（实际运动速度；抛物线模式下为解算出的初速）
var _vel: Vector2 = Vector2.ZERO
## 是否启用重力累积
var _gravity: bool = false
## 是否有抛物线瞄准点
var _has_aim: bool = false
## 抛物线瞄准点（世界坐标，由敌怪 set_parabolic_target 传入）
var _aim_target: Vector2 = Vector2.ZERO
## 出膛加速已用时间（秒）
var _accel_t: float = 0.0
## 已反弹次数
var _bounces: int = 0
## 朝向刷新倒计时（秒）
var _facing_cd: float = 0.0
## 上一帧位移向量（用于反弹法线探测与朝向）
var _last_move: Vector2 = Vector2.ZERO
## 动画节点引用
var _anim: AnimatedSprite2D = null


func _ready() -> void:
	_life = life_time
	_vel = _dir * speed
	_accel_t = 0.0
	_bounces = 0
	_facing_cd = 0.0
	if parabolic_mode and _has_aim and bullet_gravity > 0.0:
		_solve_parabolic()
	else:
		_gravity = affected_by_gravity
	# 出膛散射：在 ±scatter_deg 内随机偏转实际飞行方向
	if scatter_deg > 0.0:
		var off_rad: float = deg_to_rad(randf_range(-scatter_deg, scatter_deg))
		_dir = _dir.rotated(off_rad)
		if _gravity:
			_vel = _vel.rotated(off_rad)
		else:
			_vel = _dir * speed
	body_entered.connect(_on_body_entered)
	# 依据是否挡地形设置碰撞掩码：需命中玩家(层1)，可选被地形(层2/3/6)阻挡
	var target_mask: int = 1
	if block_by_terrain:
		target_mask |= TERRAIN_MASK
	collision_mask = target_mask
	# 生成音效（对象池复用时也会在每次取出时播放）
	_play_sfx(spawn_sfx)
	_anim = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if _anim:
		if not _anim.animation_finished.is_connected(_on_anim_finished):
			_anim.animation_finished.connect(_on_anim_finished)
		if _anim_usable("Spawn"):
			# 有生成动画帧：先播 Spawn，期间不判定伤害
			_anim.play("Spawn")
			_stage = Stage.SPAWN
			monitoring = false
		else:
			# 无生成动画/空帧：直接进入持续飞行
			_stage = Stage.FLY
			monitoring = true
			if _anim_usable("Fly"):
				_anim.play("Fly")
	else:
		_stage = Stage.FLY
		monitoring = true


func _physics_process(delta: float) -> void:
	match _stage:
		Stage.SPAWN:
			return
		Stage.FLY:
			# 出膛加速：随时间从 0 线性 ramp 到 1
			var ramp: float = 1.0
			if accel_time > 0.0 and _accel_t < accel_time:
				_accel_t += delta
				ramp = clampf(_accel_t / maxf(accel_time, 0.001), 0.0, 1.0)
			var mv: Vector2
			if _gravity:
				_vel += Vector2(0.0, bullet_gravity * delta)
				mv = _vel * ramp
			else:
				mv = _dir * speed * ramp
			_last_move = mv * delta
			global_position += mv * delta
			_update_facing(delta)
			_life -= delta
			if _life <= 0.0 and not _hit:
				_enter_die()
		Stage.DIE:
			_die_wait -= delta
			if _die_wait <= 0.0:
				queue_free()


## 由外部(敌怪/场景)在 add_child 之前调用以指定方向并覆盖参数。
## 传 -1/负值 表示沿用本弹幕场景里的默认值。
func setup(dir: Vector2, p_speed: float = -1.0, p_damage: int = -1, p_knockback: Vector2 = Vector2.ZERO, p_life: float = -1.0) -> void:
	_dir = dir.normalized()
	if p_speed > 0.0: speed = p_speed
	if p_damage >= 0: damage = p_damage
	if p_knockback != Vector2.ZERO: knockback = p_knockback
	if p_life > 0.0: life_time = p_life
	_life = life_time
	_vel = _dir * speed
	_accel_t = 0.0


## 抛物线瞄准点：敌怪在 add_child 之前调用（传玩家位置），需 parabolic_mode=true 才生效。
func set_parabolic_target(p: Vector2) -> void:
	_has_aim = true
	_aim_target = p


## 解算抛物线初速：水平初速 = 完整 speed（不再折半），用该飞行时间反解垂直初速，弧线必然落向瞄准点。
## 注意：重力越强/速度越低，弧线越高或射程越短；需要平缓远射请调大 speed 或调小 bullet_gravity。
func _solve_parabolic() -> void:
	_gravity = true
	var d: Vector2 = _aim_target - global_position
	var R: float = absf(d.x)
	var sx: float = 1.0
	if not is_zero_approx(d.x):
		sx = signf(d.x)
	var S: float = maxf(speed, 1.0)
	var g: float = maxf(bullet_gravity, 0.001)
	var t: float = R / S
	if t <= 0.001:
		t = 0.001
	# 屏幕坐标 y 向下为正：先解“向上为正”的垂直初速，再换算回屏幕坐标
	var y_up: float = -d.y
	var vy_up: float = (y_up + 0.5 * g * t * t) / t
	_vel = Vector2(sx * S, -vy_up)


## 让根节点按速度方向旋转（贴图+碰撞体一起转向），按 facing_update_interval 节流更新。
func _update_facing(delta: float) -> void:
	if not rotate_to_velocity or _last_move.length_squared() < 1.0:
		return
	_facing_cd -= delta
	if _facing_cd > 0.0:
		return
	_facing_cd = facing_update_interval
	var ang: float = _last_move.angle()
	if not is_equal_approx(rotation, ang):
		rotation = ang


## 地形反弹：沿上一帧位移向当前方向打一条射线取得碰撞法线，反射速度并略微推出墙面。
func _try_bounce() -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var from: Vector2 = global_position - _last_move
	var to: Vector2 = global_position
	var q := PhysicsRayQueryParameters2D.create(from, to, TERRAIN_MASK)
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return false
	var n: Vector2 = hit["normal"]
	var v: Vector2 = _vel if _gravity else _dir * speed
	var bounced: Vector2 = v.bounce(n)
	if bounced.length_squared() < 1.0:
		return false
	if _gravity:
		_vel = bounced
	else:
		_dir = bounced.normalized()
	global_position = (hit["position"] as Vector2) + n * 3.0
	return true


## 播放一段音效（走 AudioManager 的 SFX 池；用节点路径查找，避免强依赖 autoload 编译名）
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_stream_sfx"):
		am.play_stream_sfx(stream)


## 动画是否可用：存在该动画且有实际帧（空帧动画不会触发 finished，会卡住）
func _anim_usable(anim_name: String) -> bool:
	if _anim == null or _anim.sprite_frames == null:
		return false
	if not _anim.sprite_frames.has_animation(anim_name):
		return false
	return _anim.sprite_frames.get_frame_count(anim_name) > 0


## 命中处理（由 body_entered 信号触发）。
func _on_body_entered(body: Node) -> void:
	if _stage == Stage.DIE or _hit:
		return
	if body.is_in_group("player") and body.has_method("take_damage"):
		# 无敌/冲刺穿透
		if pierce_invincible and body.has_method("is_invincible") and body.is_invincible:
			return
		if pierce_invincible and body.has_method("get_player_state") \
		and body.get_player_state() == body.PlayerState.DASH:
			return
		_hit = true
		## 命中玩家：伤害 + 按飞行方向击退
		body.take_damage(global_position, damage, 0, _dir * knockback)
		_enter_die()
	elif block_by_terrain and body is CharacterBody2D and (body.collision_layer & TERRAIN_MASK) != 0:
		# 撞到地形(层2/3/6)：可反弹（次数上限）或直接消失
		if bounce_on_terrain and _bounces < bounce_max and _try_bounce():
			_bounces += 1
			return
		_hit = true
		_enter_die()


## 进入销毁阶段：停止命中、播放 Die 动画。
## 可能在 body_entered 信号回调内被调用，必须用 set_deferred 关闭监控
func _enter_die() -> void:
	if _stage == Stage.DIE:
		return
	_stage = Stage.DIE
	_hit = true
	_play_sfx(destroy_sfx)
	set_deferred("monitoring", false)
	_die_wait = die_max_wait
	if _anim_usable("Die"):
		_anim.play("Die")
	else:
		queue_free()


## 动画结束回调：Spawn 结束进入 FLY；Die 结束释放。
func _on_anim_finished() -> void:
	if _anim == null:
		return
	var anim_name: String = _anim.animation
	if anim_name == "Spawn" and _stage == Stage.SPAWN:
		_stage = Stage.FLY
		monitoring = true
		if _anim_usable("Fly"):
			_anim.play("Fly")
	elif anim_name == "Die":
		queue_free()
