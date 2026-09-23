# Scripts/Entities/Enemys/RegularEnemy.gd
## 常规地面敌人 AI（样本）—— 参考 FlyingEnemy 的检测/仇恨/弹幕体系重构
## 行为：
##  1. 无目标时沿地面巡逻：左右行走，遇障碍/悬崖按策略处理（跳跃/停顿掉头）。
##  2. PlayerDetector 仅作为“首次发现玩家”的触发源；发现后进入 CHASE。
##  3. 脱离仇恨 = 玩家与自身直线距离超过 leash_range（不再依赖离开 PlayerDetector）。
##  4. CHASE 两种模式：
##       - 未开启弹幕：近身追击（接触伤害由 EnemyBase/KillZone 负责）。
##       - 开启弹幕(enable_bullet_attack)：不再贴身，把玩家控制在射程(shoot_range)附近，
##         保持距离站定进行弹幕攻击（扇形/连发，同 EnemyBase 独立弹幕 EnemyBullet）。
##  5. 死亡/复活：不复用 Respawn 动画，死亡淡出后隐藏停用，待存档点/角色重生复活直接 Idle。
## 状态机：PATROL(巡逻) → CHASE(追击或保持射程) → ATTACK(弹幕) → HURT → DIE → IDLE
## 复用 EnemyBase.gd：血量/无敌/受伤/死亡/复活/接触玩家伤害。
## 性能：仇恨/攻击决策集中在低频 tick（detect_interval）内，不每帧轮询。

extends CharacterBody2D
class_name RegularEnemy

## 事件：发现玩家并建立仇恨（用于音效/演出等订阅）
signal spotted()
## 事件：进入攻击预警/开始（用于音效/演出等订阅）
signal attack_started()

## ── 移动 ──
@export_category("移动")
## 巡逻移动速度（像素/秒）
@export var move_speed: float = 60.0
## 追击(近身模式)移动速度（像素/秒）
@export var chase_speed: float = 120.0
## 跳跃初速度（负值=向上，像素/秒）
@export var jump_velocity: float = -300.0
## 重力加速度（像素/秒²）
@export var gravity: float = 980.0
## 地面摩擦强度
@export var ground_drag: float = 220.0
## 受伤状态下的水平拖拽强度
@export var hurt_drag: float = 240.0

## ── 节点路径 ──
@export_category("节点路径")
## 前方障碍物检测射线
var obstacle_detector_path: NodePath = NodePath("ObstacleDetector")
## 悬崖检测射线
var cliff_detector_path: NodePath = NodePath("CliffDetector")
## 玩家检测区域（仅作为首次发现触发源）
var player_detector_path: NodePath = NodePath("PlayerDetector")
## 接触伤害区（由 EnemyBase 处理）
var killzone_path: NodePath = NodePath("KillZone")
## EnemyBase 子节点
var enemy_base_path: NodePath = NodePath("EnemyBase")

## ── 检测应对策略 ──
## IGNORE=忽略, FLIP=停住等待后掉头, JUMP=跳跃越过
enum Resp { IGNORE, FLIP, JUMP }
@export_category("巡逻检测应对策略")
## 巡逻-遇障碍物
@export var patrol_on_obstacle: Resp = Resp.FLIP
## 巡逻-遇悬崖
@export var patrol_on_cliff: Resp = Resp.FLIP
## 追击-遇障碍物
@export var chase_on_obstacle: Resp = Resp.JUMP
## 追击-遇悬崖
@export var chase_on_cliff: Resp = Resp.JUMP

## ── 发现与仇恨 ──
@export_category("发现与仇恨")
## 仇恨/攻击决策间隔（秒），越大越省性能；建议 0.2~0.3
@export var detect_interval: float = 0.25
## 脱战直线距离（像素）：玩家超过该距离即失去仇恨并返回
@export var leash_range: float = 420.0

## ── 弹幕模组（enable_bullet_attack=true 时生效）──
@export_category("弹幕参数")
## 弹幕场景（默认独立 EnemyBullet.tscn）
@export var bullet_scene: PackedScene
## 开启弹幕攻击：开启后不再贴身追击，改为保持射程站定射击
@export var enable_bullet_attack: bool = false
## 弹幕射程（像素，欧氏距离；玩家进入该距离内才会发动攻击）
@export var shoot_range: float = 200.0
## 攻击统一冷却（秒）
@export var attack_cooldown: float = 1.8
## 开火前预警时长（秒）
@export var windup_time: float = 0.3
## 每轮发射的子弹总数
@export var bullet_count: int = 1
## 发射方式：SPREAD=一次扇形齐射；SEQUENTIAL=逐发连发（每发重新瞄准玩家）
@export var fire_mode: FireMode = FireMode.SEQUENTIAL
## 扇形齐射总张角（度）
@export var spread_angle_total: float = 60.0
## 逐发连发间隔（秒）
@export var bullet_gap: float = 0.2
## 发射点相对自身的位置偏移（世界像素）
@export var muzzle_offset: Vector2 = Vector2(0, -18)
## 弹幕覆盖值（-1 / Vector2.ZERO = 使用弹幕场景默认）
## 弹幕速度覆盖（像素/秒）
@export var bullet_speed_override: float = -1.0
## 弹幕伤害覆盖
@export var bullet_damage_override: int = -1
## 弹幕击退覆盖
@export var bullet_knockback_override: Vector2 = Vector2.ZERO
## 弹幕存活时间覆盖（秒）
@export var bullet_life_override: float = -1.0
## 抛物线弹幕：开启后发射时把玩家位置传给弹幕自动解算弧线落向玩家（需弹幕 parabolic_mode=true）
@export var bullet_parabolic: bool = false

## ── 巡逻行为 ──
@export_category("巡逻行为")
## 触发FLIP/条件阻塞后的等待时长（秒）
@export var patrol_idle_on_block: float = 0.5
## 周期性停顿间隔（秒）
@export var patrol_idle_interval: float = 3.0
## 周期性停顿持续时长（秒）
@export var patrol_idle_duration: float = 1.0
## 周期性停顿触发概率（0~1）
@export var patrol_idle_chance: float = 0.25

## ── 受伤/死亡 ──
@export_category("受伤/死亡")
## 受伤硬直持续时间（秒）
@export var hurt_duration: float = 0.5
## 死亡淡出持续时间（秒）
@export var death_fade_duration: float = 2.0

## 发射方式
enum FireMode { SPREAD = 0, SEQUENTIAL = 1 }
## 状态
enum State { PATROL, CHASE, ATTACK, HURT, DIE, IDLE }

## 当前状态
var _state: int = State.PATROL
## 当前逻辑方向（1=右，-1=左）
var _dir: int = 1
## 出生点
var _spawn_pos: Vector2 = Vector2.ZERO

## 节点引用
var _sprite: AnimatedSprite2D = null
var _base: Node = null
var _player: Node = null
var _obs_ray: RayCast2D = null
var _cliff_ray: RayCast2D = null

## 巡逻计时
var _patrol_timer: float = 0.0
var _block_timer: float = 0.0
var _is_blocked: bool = false
## FLIP 防抖
var _flip_cooldown: float = 0.0
const FLIP_COOLDOWN_DURATION: float = 0.5
## 决策计时（仇恨/攻击条件）
var _tick_timer: float = 0.0
## 受伤计时
var _hurt_timer: float = 0.0
## 攻击冷却
var _attack_cd: float = 0.0

## 攻击执行
## 是否在攻击中（预警或发射）
var _attacking: bool = false
## 预警阶段是否结束进入发射
var _attack_firing: bool = false
## 攻击阶段计时
var _attack_timer: float = 0.0
## 连发剩余颗数
var _shots_left: int = 0
## 连发间隔计时
var _shoot_timer: float = 0.0

## 贴图基准 scale.x
var _base_scale_x: float = 1.0
## 死亡淡出 tween
var _death_tween: Tween = null


func _ready() -> void:
	_spawn_pos = global_position
	_sprite = $AnimatedSprite2D
	if _sprite:
		_base_scale_x = absf(_sprite.scale.x)
	
	if enemy_base_path:
		_base = get_node(enemy_base_path)
		if _base:
			if _base.has_signal("damage_taken"):
				_base.damage_taken.connect(_on_hurt)
			if _base.has_signal("enemy_died"):
				_base.enemy_died.connect(_on_die)
				_base.enemy_died.connect(_on_disable_killzone)
			if _base.has_signal("enemy_respawned"):
				_base.enemy_respawned.connect(_on_revive)
			if _base.has_signal("enemy_force_refreshed"):
				_base.enemy_force_refreshed.connect(_on_force_refresh)
	
	if obstacle_detector_path:
		_obs_ray = get_node(obstacle_detector_path) as RayCast2D
	if cliff_detector_path:
		_cliff_ray = get_node(cliff_detector_path) as RayCast2D
	if player_detector_path:
		var det := get_node(player_detector_path) as Area2D
		if det:
			# 只监听“玩家进入”作为首次发现，离开不脱战（改用 leash 直线距离）
			det.body_entered.connect(_on_player_detected)
	if killzone_path and _base and _base.has_method("_on_killzone_entered"):
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.body_entered.connect(_base._on_killzone_entered)
	
	if _sprite and _sprite.sprite_frames:
		_sprite.animation_finished.connect(_on_anim_end)
		_play_default_anim()


## 选择一个存在的动画作为初始帧（优先 Idle，其次 Move）
func _play_default_anim() -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	if _sprite.sprite_frames.has_animation("Idle"):
		_sprite.play("Idle")
	elif _sprite.sprite_frames.has_animation("Move"):
		_sprite.play("Move")


func _physics_process(d: float) -> void:
	# 死亡/受伤等终结态处理
	if _state == State.DIE:
		velocity.x = move_toward(velocity.x, 0.0, ground_drag * d)
		_apply_gravity(d)
		move_and_slide()
		return
	if _state == State.HURT:
		_apply_gravity(d)
		if is_on_floor():
			velocity.x = move_toward(velocity.x, 0.0, hurt_drag * d)
		move_and_slide()
		_hurt_timer -= d
		if _hurt_timer <= 0.0:
			_change(State.PATROL)
		return
	
	if _flip_cooldown > 0.0:
		_flip_cooldown -= d
	if _attack_cd > 0.0:
		_attack_cd -= d
	
	# ── 低频决策 tick（仇恨保持/脱离 + 攻击触发）──
	_tick_timer += d
	if _tick_timer >= detect_interval:
		_tick_timer = 0.0
		_on_tick()
	
	# 常规状态统一受重力（空中时才会加速），跳跃等会覆盖 y 速度
	_apply_gravity(d)
	
	match _state:
		State.PATROL:
			_patrol(d)
		State.CHASE:
			_chase(d)
		State.ATTACK:
			_attack(d)
		State.IDLE:
			velocity.x = move_toward(velocity.x, 0.0, ground_drag * d)
	
	_dir = 1 if _dir >= 0 else -1
	_sync_flip()
	move_and_slide()


## 低频决策：仇恨保持/脱离 + 是否发动弹幕攻击
func _on_tick() -> void:
	if _player and is_instance_valid(_player):
		if _player.has_method("is_in_death_state") and _player.is_in_death_state():
			_drop_target()
			return
		var dist: float = global_position.distance_to(_player.global_position)
		if dist > leash_range:
			_drop_target()
			return
		# 有仇恨：若在巡逻则切追击
		if _state == State.PATROL:
			_change(State.CHASE)
		# 弹幕模式：冷却结束 + 在射程内 → 站定攻击
		if enable_bullet_attack and _state == State.CHASE and not _attacking \
		and _attack_cd <= 0.0 and dist <= shoot_range:
			_begin_attack()
	elif _state in [State.CHASE, State.ATTACK]:
		_drop_target()


## 丢弃仇恨并回到巡逻
func _drop_target() -> void:
	_player = null
	_cancel_attack()
	_change(State.PATROL)


# ════════════════════════════════════════
# 巡逻
# ════════════════════════════════════════

func _patrol(d: float) -> void:
	if _is_blocked:
		_block_timer -= d
		velocity.x = 0
		_play("Idle")
		if _block_timer <= 0.0:
			_is_blocked = false
			if randf() < 0.5:
				_dir = -_dir
				_flip_cooldown = FLIP_COOLDOWN_DURATION
		return
	if _flip_cooldown <= 0.0:
		if _obs_ray and _obs_ray.is_colliding():
			match patrol_on_obstacle:
				Resp.FLIP: _block_on_condition(); return
				Resp.JUMP: _do_jump(move_speed)
				_: pass
		if _cliff_ray and not _cliff_ray.is_colliding():
			match patrol_on_cliff:
				Resp.FLIP: _block_on_condition(); return
				Resp.JUMP: _do_jump(move_speed)
				_: pass
	_patrol_timer += d
	if _patrol_timer >= patrol_idle_interval:
		_patrol_timer = 0.0
		if randf() < patrol_idle_chance:
			_is_blocked = true
			_block_timer = patrol_idle_duration
			return
	velocity.x = _dir * move_speed
	if is_on_floor():
		_play("Move")


# ════════════════════════════════════════
# 追击
# ════════════════════════════════════════

func _chase(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_change(State.PATROL)
		return
	_face_player()
	if enable_bullet_attack:
		_chase_ranged(d)
	else:
		_chase_melee(d)


## 近身追击模式（无弹幕）：贴脸追击，接触伤害由 EnemyBase 负责
func _chase_melee(_d: float) -> void:
	# 跳跃应对障碍/悬崖
	if _flip_cooldown <= 0.0:
		if _obs_ray and _obs_ray.is_colliding() and chase_on_obstacle == Resp.JUMP:
			_do_jump(chase_speed)
		if _cliff_ray and not _cliff_ray.is_colliding() and chase_on_cliff == Resp.JUMP:
			_do_jump(chase_speed)
	velocity.x = _dir * chase_speed
	if is_on_floor():
		_play("Run")


## 弹幕模式：把玩家控制在射程内（太远靠近、太近后退），开火由 tick 触发
func _chase_ranged(d: float) -> void:
	# 仍保留跳跃应对障碍/悬崖
	if _flip_cooldown <= 0.0:
		if _obs_ray and _obs_ray.is_colliding() and chase_on_obstacle == Resp.JUMP:
			_do_jump(move_speed)
		if _cliff_ray and not _cliff_ray.is_colliding() and chase_on_cliff == Resp.JUMP:
			_do_jump(move_speed)
	var dx: float = _player.global_position.x - global_position.x
	var adx: float = absf(dx)
	if adx > shoot_range + 40.0:
		# 太远：靠近
		velocity.x = move_toward(velocity.x, signf(dx) * chase_speed, chase_speed * 4.0 * d)
		if is_on_floor():
			_play("Run")
	elif adx < shoot_range - 70.0:
		# 太近：后退拉开距离（不贴身）
		velocity.x = move_toward(velocity.x, -signf(dx) * chase_speed * 0.6, chase_speed * 4.0 * d)
		if is_on_floor():
			_play("Run")
	else:
		# 处于射程：停住等待开火（开火在 tick 触发，这里停脚）
		velocity.x = move_toward(velocity.x, 0.0, chase_speed * 6.0 * d)
		if is_on_floor():
			_play("Idle")


# ════════════════════════════════════════
# 弹幕攻击
# ════════════════════════════════════════

## 开始一轮弹幕攻击（预警 → 发射）
func _begin_attack() -> void:
	attack_started.emit()
	_attacking = true
	_attack_firing = false
	_attack_timer = windup_time
	_shots_left = 0
	_shoot_timer = 0.0
	_change(State.ATTACK)


## 取消当前攻击
func _cancel_attack() -> void:
	_attacking = false
	_attack_firing = false


func _attack(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_drop_target()
		return
	_face_player()
	if not _attack_firing:
		# 预警：停脚、面向玩家
		velocity.x = move_toward(velocity.x, 0.0, chase_speed * 6.0 * d)
		_play("Attack")
		_attack_timer -= d
		if _attack_timer <= 0.0:
			_attack_firing = true
			_begin_execute()
		return
	if _shots_left > 0:
		_shoot_timer -= d
		if _shoot_timer <= 0.0:
			_fire_towards_player()
			_shots_left -= 1
			_shoot_timer = bullet_gap
	else:
		_end_attack()


## 发射开始初始化（连发计数或扇形齐射）
func _begin_execute() -> void:
	if fire_mode == FireMode.SPREAD:
		_fire_spread()
		_end_attack()
	else:
		_shots_left = bullet_count
		_shoot_timer = 0.0


## 结束一轮攻击：进入冷却并回追击
func _end_attack() -> void:
	_attacking = false
	_attack_cd = attack_cooldown
	if _state == State.ATTACK:
		_change(State.CHASE)


## 朝玩家当前位置发射一颗子弹（连发每发重新瞄准；以发射点=自身+muzzle_offset 为基准）
func _fire_towards_player() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var spawn_pos: Vector2 = global_position + muzzle_offset
	var dir: Vector2 = (_player.global_position - spawn_pos).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_spawn_bullet_at(spawn_pos, dir)


## 扇形齐射
func _fire_spread() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var spawn_pos: Vector2 = global_position + muzzle_offset
	var base_dir: Vector2 = (_player.global_position - spawn_pos).normalized()
	if base_dir == Vector2.ZERO:
		base_dir = Vector2.RIGHT
	var n: int = maxi(bullet_count, 1)
	var total_rad: float = deg_to_rad(spread_angle_total)
	if n == 1:
		_spawn_bullet_at(spawn_pos, base_dir)
		return
	var step: float = total_rad / float(n - 1)
	var start_off: float = -total_rad * 0.5
	for i in range(n):
		var ang: float = start_off + step * float(i)
		_spawn_bullet_at(spawn_pos, base_dir.rotated(ang))


## 实例化一颗独立弹幕并发射
func _spawn_bullet_at(pos: Vector2, dir: Vector2) -> void:
	if bullet_scene == null:
		return
	var bullet := bullet_scene.instantiate() as Area2D
	if bullet == null:
		return
	if bullet.has_method("setup"):
		bullet.setup(dir, bullet_speed_override, bullet_damage_override, bullet_knockback_override, bullet_life_override)
	bullet.global_position = pos
	# 抛物线弹幕：开启时强制弹幕进入抛物线模式，并传玩家位置做弧线自瞄
	if bullet_parabolic:
		var pm: Variant = bullet.get("parabolic_mode")
		if typeof(pm) == TYPE_BOOL:
			bullet.parabolic_mode = true
	if bullet_parabolic and bullet.has_method("set_parabolic_target") \
	and _player and is_instance_valid(_player):
		bullet.set_parabolic_target(_player.global_position)
	var parent := get_parent()
	if parent:
		parent.add_child(bullet)


# ════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════

## 朝向玩家（更新 _dir，用于贴图翻转）
func _face_player() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var dx: float = _player.global_position.x - global_position.x
	if dx != 0.0:
		_dir = 1 if dx > 0.0 else -1


## 同步朝向/射线方向
func _sync_flip() -> void:
	var target: int = _dir
	if _obs_ray:
		_obs_ray.target_position = Vector2(50 * target, 0)
	if _cliff_ray:
		_cliff_ray.target_position = Vector2(50 * target, 25)
	if _sprite and is_instance_valid(_sprite):
		var target_x: float = _base_scale_x if target > 0 else -_base_scale_x
		if not is_equal_approx(_sprite.scale.x, target_x):
			_sprite.scale.x = target_x


## 重力与下落动画
func _apply_gravity(d: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * d
		if velocity.y > 0.0 and _state in [State.PATROL, State.CHASE]:
			_play("Down")


## 跳跃：保持水平速度前进
func _do_jump(h_speed: float) -> void:
	if is_on_floor():
		velocity.y = jump_velocity
		var keep_x: float = maxf(absf(velocity.x), absf(h_speed))
		velocity.x = _dir * minf(keep_x, maxf(absf(h_speed), 20.0))
		_play("Jump")


## FLIP 阻塞
func _block_on_condition() -> void:
	_is_blocked = true
	_block_timer = patrol_idle_on_block
	velocity.x = 0
	_play("Idle")


## 安全播放动画
func _play(anim_name: String) -> void:
	if _sprite and _sprite.sprite_frames \
	and _sprite.sprite_frames.has_animation(anim_name) \
	and _sprite.animation != anim_name:
		_sprite.play(anim_name)


## 状态切换
func _change(new_state: int) -> void:
	if _state == new_state:
		return
	_state = new_state
	match new_state:
		State.PATROL:
			_patrol_timer = 0.0
			_is_blocked = false
		State.ATTACK:
			_play("Attack")
		State.HURT:
			_play("Hurt")
		State.DIE:
			_play("Die")


# ════════════════════════════════════════
# 信号
# ════════════════════════════════════════

## 玩家首次被 PlayerDetector 发现
func _on_player_detected(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if _player and is_instance_valid(_player):
		return
	_player = body
	spotted.emit()
	if _state == State.PATROL:
		_change(State.CHASE)

## 受伤（由 EnemyBase.damage_taken 触发）
func _on_hurt(_damage: int, current_health: int) -> void:
	if _state == State.DIE:
		return
	if current_health <= 0:
		_cancel_attack()
		_change(State.DIE)
		_play("Die")
		return
	_cancel_attack()
	_change(State.HURT)
	_hurt_timer = hurt_duration

## 死亡（EnemyBase.enemy_died）→ 关闭接触伤害区
func _on_disable_killzone() -> void:
	if killzone_path:
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", false)

func _on_die() -> void:
	_cancel_attack()
	_change(State.DIE)

## 复活（EnemyBase.enemy_respawned）：直接 Idle/PATROL，不走 Respawn 动画
func _on_revive() -> void:
	if not is_physics_processing():
		set_physics_process(true)
	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()
		_death_tween = null
	if killzone_path:
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", true)
	visible = true
	modulate = Color.WHITE
	_change(State.PATROL)
	_play_default_anim()

## 强制完全刷新
func _on_force_refresh() -> void:
	_on_revive()

## 动画结束回调
func _on_anim_end() -> void:
	if _sprite == null:
		return
	var anim_name: String = _sprite.animation
	if anim_name == "Die":
		_start_death_sequence()
	elif anim_name == "Hurt":
		if _state == State.HURT:
			_change(State.PATROL)

## 死亡淡出流程：淡出→隐藏→禁用碰撞→停用物理（等待存档点/角色重生复活）
func _start_death_sequence() -> void:
	if _state != State.DIE:
		return
	if death_fade_duration > 0.0:
		if _death_tween and _death_tween.is_valid():
			return
		_death_tween = create_tween()
		_death_tween.tween_property(self, "modulate", Color(1, 1, 1, 0), death_fade_duration)
		await _death_tween.finished
		_death_tween = null
	if _base and _base.has_method("is_dead") and not _base.is_dead():
		# 淡出期间已被复活
		return
	visible = false
	set_physics_process(false)
	if _base and _base.has_method("disable_collision"):
		_base.disable_collision()
