# Scripts/Entities/Enemys/FlyingEnemy.gd
## 飞行敌人 AI（样本）—— 参考空洞骑士「原始阿斯匹德(Aspid)」的可扩展版
## 行为：
##   1. 无目标时在出生点附近空中悬停漂移（不落地、不受重力）。
##   2. PlayerDetector 仅作为“首次发现玩家”的触发源；发现后进入警戒（CHASE）。
##   3. 脱离仇恨条件 = 玩家与自身的直线距离超过 leash_range（或用直线距离脱战），
##      不再依赖“离开 PlayerDetector”（范围小、容易造成打几轮就停手的问题）。
##   4. 每次攻击冷却结束后，从已开启能力中执行：
##        - 弹幕：扇形同时发射(spread) 或 逐发连发(sequential，每发重新瞄准玩家)
##        - 肉身突进：朝玩家冲刺一段距离（可被地形阻挡，或无视地形穿越）
##        - 两者都开启时：每次随机选择一种
##   5. 弹幕使用独立场景 EnemyBullet（res://Scenes/Instances/HurtBoxs/EnemyBullet.tscn），
##      其速度/伤害/寿命等由弹幕自身外部变量控制，敌怪只负责发射几何。
## 状态机：PATROL(悬停) → CHASE(跟随/警戒) → ATTACK(执行能力) → HURT → DIE → RESPAWN
## 复用 EnemyBase.gd：血量/无敌/受伤/死亡/复活/接触玩家伤害。
## 性能：仇恨、攻击条件等“决策”集中在低频 tick（detect_interval）里做，
##       不在每帧扫描/轮询；伤害全走信号，不做每帧 Area 检测。

extends CharacterBody2D
class_name FlyingEnemy

## 事件：发现玩家并建立仇恨（用于音效/演出等订阅）
signal spotted()
## 事件：进入一轮能力攻击的预警/开始（用于音效/演出等订阅）
signal attack_started()

## 地形层掩码：层2(bit1=2)、层3(bit2=4)、层6(bit5=32)；幽灵模式只排除这些层
const TERRAIN_MASK: int = 2 | 4 | 32

## ── 悬停(巡逻) ──
@export_category("悬停巡逻")
## 无目标时水平漂移速度（像素/秒）
@export var hover_speed: float = 60.0
## 悬停允许离开出生点的最大水平半径（像素），超出自动掉头
@export var roam_radius: float = 160.0
## 垂直上下漂浮幅度（像素）
@export var bob_amplitude: float = 24.0
## 垂直漂浮速度（角速度，弧度/秒）
@export var bob_speed: float = 1.2
## 脱离仇恨后返回出生点的移动速度（像素/秒）
@export var return_speed: float = 90.0

## ── 发现与仇恨 ──
@export_category("发现与仇恨")
## 仇恨决策/攻击决策的间隔（秒）。越大越省性能；建议 0.2~0.35
@export var detect_interval: float = 0.3
## 脱战直线距离（像素）：玩家超过该距离即失去仇恨并返回出生点
@export var leash_range: float = 420.0
## 玩家进入该距离内才发动攻击（像素，欧氏距离）
@export var attack_range: float = 240.0

## ── 跟随/保持距离 ──
@export_category("跟随与保持距离")
## 水平距离小于该值会后退（避免贴脸），大于该值会靠近
@export var ideal_horizontal_distance: float = 160.0
## 跟随玩家的水平移动速度（像素/秒）
@export var track_speed: float = 240.0
## 保持相对玩家上方的高度偏移（像素，负值=高于玩家头部）
@export var hover_height_offset: float = -30.0
## 垂直跟随速度（像素/秒）
@export var vertical_follow_speed: float = 180.0
## 撞墙时贴墙滑行的攀爬/下降速度（像素/秒；仅非幽灵模式生效）
@export var wall_climb_speed: float = 240.0
## 撞墙绕障方向切换间隔（秒）：沿一个方向滑行该时长仍未绕过则反向尝试
@export var obstacle_flip_time: float = 0.55

## ── 能力开关 ──
@export_category("能力开关")
## 开启弹幕攻击
@export var enable_bullet_attack: bool = true
## 开启肉身突进
@export var enable_ram_attack: bool = false
## 攻击统一冷却（秒），冷却结束后才发动下一次能力
@export var attack_cooldown: float = 2.4
## 执行能力前的预警时长（秒，播放对应攻击动画、短暂悬停）
@export var windup_time: float = 0.35
## 弹幕攻击动画名（SpriteFrames 中不存在时回退到 "Attack"）
@export var anim_attack_bullet: String = "AttackBullet"
## 肉身突进攻击动画名（SpriteFrames 中不存在时回退到 "Attack"）
@export var anim_attack_ram: String = "AttackRam"

## ── 弹幕参数（enable_bullet_attack 时生效）──
@export_category("弹幕参数")
## 弹幕场景（默认使用独立 EnemyBullet.tscn）
@export var bullet_scene: PackedScene
## 每轮发射的子弹总数
@export var bullet_count: int = 3
## 发射方式：SPREAD=一次扇形齐射；SEQUENTIAL=逐发连发（每发重新瞄准玩家）
@export var fire_mode: FireMode = FireMode.SEQUENTIAL
## 扇形齐射的总张角（度，0=全部朝同一点）
@export var spread_angle_total: float = 60.0
## 逐发连发的间隔（秒）
@export var bullet_gap: float = 0.2
## 发射点相对自身的位置偏移（世界像素）
@export var muzzle_offset: Vector2 = Vector2(0, -12)
## 以下覆盖值：-1 / Vector2.ZERO = 使用弹幕场景自身的默认值
## 弹幕速度覆盖（像素/秒，-1=用弹幕默认）
@export var bullet_speed_override: float = -1.0
## 弹幕伤害覆盖（-1=用弹幕默认）
@export var bullet_damage_override: int = -1
## 弹幕击退覆盖（Vector2.ZERO=用弹幕默认）
@export var bullet_knockback_override: Vector2 = Vector2.ZERO
## 弹幕存活时间覆盖（秒，-1=用弹幕默认）
@export var bullet_life_override: float = -1.0
## 抛物线弹幕：开启后发射时把玩家位置传给弹幕自动解算弧线落向玩家（需弹幕自身 parabolic_mode=true）
@export var bullet_parabolic: bool = false

## ── 突进参数（enable_ram_attack 时生效）──
@export_category("肉身突进参数")
## 突进速度（像素/秒）
@export var ram_speed: float = 420.0
## 突进最大行进距离（像素），达到即停
@export var ram_range: float = 300.0
## 突进最长持续时间（秒，兜底防止卡墙/鬼畜）
@export var max_ram_time: float = 1.2

## ── 地形 ──
@export_category("地形")
## 是否无视地形碰撞体（穿过墙壁/地面；伤害地形仍会命中受伤）
@export var ignore_terrain_collision: bool = false

## ── 受伤/死亡 ──
@export_category("受伤/死亡")
## 受伤硬直持续时间（秒）
@export var hurt_duration: float = 0.35
## 受伤状态下的速度衰减强度（像素/秒²），飞行怪无重力，靠它缓缓停住
@export var hurt_drag: float = 300.0
## 死亡淡出持续时间（秒）
@export var death_fade_duration: float = 2.0

## ── 节点路径 ──
@export_category("节点路径")
## 玩家检测区域（仅作为首次发现玩家的触发源）
var player_detector_path: NodePath = NodePath("PlayerDetector")
## 接触伤害区（Area2D，由 EnemyBase 处理，突进撞击用）
var killzone_path: NodePath = NodePath("KillZone")
## EnemyBase 子节点
var enemy_base_path: NodePath = NodePath("EnemyBase")

## 发射方式
enum FireMode { SPREAD = 0, SEQUENTIAL = 1 }
## 能力类型
enum Ability { NONE = 0, BULLET = 1, RAM = 2 }
## 状态
enum State { PATROL, CHASE, ATTACK, HURT, DIE, IDLE }

## 当前状态
var _state: int = State.PATROL
## 当前水平朝向（1=右，-1=左）
var _dir: int = 1
## 出生点（悬停/返回参考）
var _spawn_pos: Vector2 = Vector2.ZERO

## 内部节点引用
var _sprite: AnimatedSprite2D = null
var _base: Node = null
var _player: Node = null
var _detector: Area2D = null

## 悬停相位
var _hover_phase: float = 0.0
## 当前漂移方向
var _roam_dir: int = 1
## 决策计时（仇恨/攻击条件）
var _tick_timer: float = 0.0
## 受伤计时
var _hurt_timer: float = 0.0
## 攻击冷却计时
var _attack_cd: float = 0.0

## 攻击执行相关
## 当前能力
var _ability: int = Ability.NONE
## 攻击是否进行中（预警或执行）
var _attacking: bool = false
## 攻击阶段计时（预警/执行共用）
var _attack_timer: float = 0.0
## 预警阶段是否结束、进入执行
var _attack_firing: bool = false
## 连发剩余颗数
var _shots_left: int = 0
## 连发间隔计时
var _shoot_timer: float = 0.0
## 突进方向（单位向量）
var _ram_dir: Vector2 = Vector2.ZERO
## 突进已行进距离（像素）
var _ram_travelled: float = 0.0

## 原始 collision_mask（编辑器设定，幽灵开关时用于恢复）
var _default_mask: int = 6
## 当前是否已应用“排除地形层”
var _ghost_applied: bool = false
## 贴图基准 scale.x
var _base_scale_x: float = 1.0
## 死亡淡出 tween
var _death_tween: Tween = null
## 撞墙绕障计时
var _obstacle_timer: float = 0.0
## 撞墙绕障当前方向（-1=向上滑，1=向下滑）
var _obstacle_dir: int = -1


func _ready() -> void:
	_spawn_pos = global_position
	_hover_phase = randf() * TAU
	_sprite = $AnimatedSprite2D
	if _sprite:
		_base_scale_x = absf(_sprite.scale.x)
	_default_mask = collision_mask
	_ghost_applied = ignore_terrain_collision
	if _ghost_applied:
		collision_mask = _default_mask & ~TERRAIN_MASK
	
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
	
	if player_detector_path:
		_detector = get_node(player_detector_path) as Area2D
		if _detector:
			# 只监听“玩家进入”作为首次发现，离开不脱战（改用 leash 直线距离）
			_detector.body_entered.connect(_on_player_detected)
	
	if killzone_path and _base and _base.has_method("_on_killzone_entered"):
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.body_entered.connect(_base._on_killzone_entered)
	
	if _sprite and _sprite.sprite_frames:
		_sprite.animation_finished.connect(_on_anim_end)


func _physics_process(d: float) -> void:
	# 幽灵模式切换（仅在开关状态变化时更新一次掩码，避免每帧赋值）
	if ignore_terrain_collision != _ghost_applied:
		_ghost_applied = ignore_terrain_collision
		collision_mask = (_default_mask & ~TERRAIN_MASK) if _ghost_applied else _default_mask
	
	if _state == State.DIE:
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		return
	if _state == State.IDLE:
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		return
	if _state == State.HURT:
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		_hurt_timer -= d
		if _hurt_timer <= 0.0:
			_change(State.PATROL)
		return
	
	# 冷却递减
	if _attack_cd > 0.0:
		_attack_cd -= d
	
	# ── 低频决策 tick：仇恨保持/脱离 + 攻击条件（性能友好）──
	_tick_timer += d
	if _tick_timer >= detect_interval:
		_tick_timer = 0.0
		_on_tick()
	
	match _state:
		State.PATROL:
			_patrol(d)
		State.CHASE:
			_chase(d)
		State.ATTACK:
			_attack(d)
	
	_apply_flip()
	move_and_slide()


## 低频决策（detect_interval 一次）：仇恨保持 + 是否发动能力
func _on_tick() -> void:
	if not _player or not is_instance_valid(_player):
		# 无有效仇恨：回到悬停
		if _state in [State.CHASE, State.ATTACK]:
			_cancel_attack()
			_change(State.PATROL)
		return
	# 玩家死亡则丢弃仇恨
	if _player.has_method("is_in_death_state") and _player.is_in_death_state():
		_player = null
		_cancel_attack()
		_change(State.PATROL)
		return
	# 直线距离超过 leash 则脱战
	var dist: float = global_position.distance_to(_player.global_position)
	if dist > leash_range:
		_player = null
		_cancel_attack()
		_change(State.PATROL)
		return
	# 有仇恨且在范围内 → 保持警戒
	if _state == State.PATROL:
		_change(State.CHASE)
	# 攻击条件：警戒中、冷却结束、距离够近、有可执行能力
	if _state == State.CHASE and not _attacking and _attack_cd <= 0.0 \
	and dist <= attack_range and _has_ability():
		_begin_attack()


## 是否还有可执行的能力
func _has_ability() -> bool:
	return enable_bullet_attack or enable_ram_attack


## 随机挑选本轮能力（都开启时随机；只开一个则用那个）
func _pick_ability() -> int:
	if enable_bullet_attack and enable_ram_attack:
		return Ability.BULLET if randf() < 0.5 else Ability.RAM
	if enable_bullet_attack:
		return Ability.BULLET
	if enable_ram_attack:
		return Ability.RAM
	return Ability.NONE


## 开始一轮能力攻击（预警 → 执行）
func _begin_attack() -> void:
	_ability = _pick_ability()
	if _ability == Ability.NONE:
		return
	attack_started.emit()
	_attacking = true
	_attack_firing = false
	_attack_timer = windup_time
	_shots_left = 0
	_shoot_timer = 0.0
	_ram_travelled = 0.0
	_change(State.ATTACK)


## 取消当前攻击（用于脱战/死亡）
func _cancel_attack() -> void:
	if not _attacking:
		return
	_attacking = false
	_ability = Ability.NONE


## 攻击执行
func _attack(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_cancel_attack()
		_change(State.PATROL)
		return
	# 预警阶段：面向玩家、短暂悬停
	if not _attack_firing:
		_face_player()
		velocity.x = move_toward(velocity.x, 0.0, track_speed * 4.0 * d)
		velocity.y = move_toward(velocity.y, 0.0, vertical_follow_speed * 2.0 * d)
		_attack_timer -= d
		if _attack_timer <= 0.0:
			_attack_firing = true
			_begin_execute()
		return
	# 执行阶段按能力推进
	match _ability:
		Ability.BULLET:
			_execute_bullet(d)
		Ability.RAM:
			_execute_ram(d)
		_:
			_end_attack()


## 进入能力执行瞬间的初始化
func _begin_execute() -> void:
	match _ability:
		Ability.BULLET:
			if fire_mode == FireMode.SPREAD:
				# 扇形齐射：一次发射 bullet_count 颗，立即结束
				_fire_spread()
				_end_attack()
			else:
				# 逐发连发：初始化待发数量（首发立即）
				_shots_left = bullet_count
				_shoot_timer = 0.0
		Ability.RAM:
			# 突进：锁定朝玩家的方向
			_ram_dir = (_player.global_position - global_position).normalized()
			if _ram_dir == Vector2.ZERO:
				_ram_dir = Vector2.RIGHT
			_ram_travelled = 0.0
			velocity = _ram_dir * ram_speed
			_play_attack_anim()
		_:
			_end_attack()


## 逐发连发执行（SEQUENTIAL）
func _execute_bullet(d: float) -> void:
	# 执行期间轻微缓停
	velocity.x = move_toward(velocity.x, 0.0, track_speed * 4.0 * d)
	velocity.y = move_toward(velocity.y, 0.0, vertical_follow_speed * 2.0 * d)
	if _shots_left > 0:
		_shoot_timer -= d
		if _shoot_timer <= 0.0:
			_face_player()
			_fire_towards_player()
			_shots_left -= 1
			_shoot_timer = bullet_gap
	else:
		_end_attack()


## 肉身突进执行（RAM）
func _execute_ram(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_cancel_attack()
		_change(State.PATROL)
		return
	# 维持锁定方向冲刺
	velocity = _ram_dir * ram_speed
	_ram_travelled += ram_speed * d
	_attack_timer += d
	# 结束条件：达到距离 / 撞到地形(非幽灵) / 超时兜底
	var hit_wall: bool = (not ignore_terrain_collision) and (is_on_wall() or is_on_floor())
	if _ram_travelled >= ram_range or hit_wall or _attack_timer >= max_ram_time:
		_end_attack()


## 结束一轮攻击：进入冷却并回到警戒
func _end_attack() -> void:
	_attacking = false
	_ability = Ability.NONE
	_attack_cd = attack_cooldown
	if _state == State.ATTACK:
		_change(State.CHASE)


## 朝玩家当前位置发射一颗子弹（连发用，每发重新瞄准；以发射点=自身+muzzle_offset 为基准）
func _fire_towards_player() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var spawn_pos: Vector2 = global_position + muzzle_offset
	var dir: Vector2 = (_player.global_position - spawn_pos).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_spawn_bullet_at(spawn_pos, dir)


## 扇形齐射：围绕朝向玩家方向均布 bullet_count 颗
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
	# 以朝向玩家方向为中心均布张角
	var step: float = total_rad / float(n - 1)
	var start_off: float = -total_rad * 0.5
	for i in range(n):
		var ang: float = start_off + step * float(i)
		var d: Vector2 = base_dir.rotated(ang)
		_spawn_bullet_at(spawn_pos, d)


## 实例化一颗弹幕（独立 EnemyBullet 场景），参数由其自身外部变量控制
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


## 朝向玩家（更新 _dir，用于贴图翻转）
func _face_player() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var dx: float = _player.global_position.x - global_position.x
	if dx != 0.0:
		_dir = 1 if dx > 0.0 else -1


## 更新贴图朝向（只翻转 AnimatedSprite2D，不翻转根节点）
func _apply_flip() -> void:
	if _sprite and is_instance_valid(_sprite):
		var target_x: float = _base_scale_x if _dir > 0 else -_base_scale_x
		if not is_equal_approx(_sprite.scale.x, target_x):
			_sprite.scale.x = target_x


## 悬停巡逻：若远离出生点先返回；靠近后左右漂移 + 正弦浮动
func _patrol(d: float) -> void:
	var away: Vector2 = _spawn_pos - global_position
	var away_len: float = away.length()
	if away_len > roam_radius * 1.5:
		# 回家
		var home_dir: Vector2 = away.normalized()
		velocity = velocity.move_toward(home_dir * return_speed, return_speed * 6.0 * d)
		return
	_hover_phase += bob_speed * d
	velocity.x = move_toward(velocity.x, _roam_dir * hover_speed, hover_speed * 4.0 * d)
	if global_position.x > _spawn_pos.x + roam_radius:
		_roam_dir = -1
	elif global_position.x < _spawn_pos.x - roam_radius:
		_roam_dir = 1
	var target_y: float = _spawn_pos.y + sin(_hover_phase) * bob_amplitude
	var diff_y: float = target_y - global_position.y
	velocity.y = clampf(diff_y * 4.0, -vertical_follow_speed, vertical_follow_speed)
	_play("Hover")


## 警戒跟随：调整到玩家上方理想高度，水平保持距离
func _chase(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_change(State.PATROL)
		return
	_face_player()
	var dx: float = _player.global_position.x - global_position.x
	var dist: float = absf(dx)
	if dist > ideal_horizontal_distance + 14.0:
		var toward: float = track_speed if dist < attack_range * 2.0 else hover_speed * 1.5
		velocity.x = move_toward(velocity.x, signf(dx) * toward, track_speed * 4.0 * d)
	elif dist < ideal_horizontal_distance - 20.0:
		velocity.x = move_toward(velocity.x, -signf(dx) * track_speed * 0.6, track_speed * 4.0 * d)
	else:
		velocity.x = move_toward(velocity.x, 0.0, track_speed * 4.0 * d)
	var target_y: float = _player.global_position.y + hover_height_offset
	var dy: float = target_y - global_position.y
	if is_on_wall() and not ignore_terrain_collision:
		# 被地形阻挡：保留水平顶墙压力使 move_and_slide 沿墙滑动，同时按目标高度方向攀爬/下潜尝试绕过
		if _obstacle_timer <= 0.0:
			# 玩家明显在下方则先向下找路，否则默认向上爬越墙顶
			_obstacle_dir = 1 if dy > 30.0 else -1
			_obstacle_timer = obstacle_flip_time
		else:
			_obstacle_timer -= d
			if _obstacle_timer <= 0.0:
				_obstacle_dir = -_obstacle_dir
				_obstacle_timer = obstacle_flip_time
		velocity.y = _obstacle_dir * wall_climb_speed
	else:
		_obstacle_timer = 0.0
		velocity.y = clampf(dy * 3.0, -vertical_follow_speed, vertical_follow_speed)
	_play("Hover")


## 安全播放动画
func _play(anim_name: String) -> void:
	if _sprite and _sprite.sprite_frames \
	and _sprite.sprite_frames.has_animation(anim_name) \
	and _sprite.animation != anim_name:
		_sprite.play(anim_name)


## 是否存在可用动画（有帧才算）
func _has_anim(anim_name: String) -> bool:
	if _sprite == null or _sprite.sprite_frames == null:
		return false
	if not _sprite.sprite_frames.has_animation(anim_name):
		return false
	return _sprite.sprite_frames.get_frame_count(anim_name) > 0


## 根据当前能力播放对应攻击动画（弹幕/肉身分开；缺帧时回退到 Attack）
func _play_attack_anim() -> void:
	var want: String = anim_attack_bullet if _ability == Ability.BULLET else anim_attack_ram
	if not _has_anim(want):
		want = "Attack"
	_play(want)


## 状态切换
func _change(new_state: int) -> void:
	if _state == new_state:
		return
	_state = new_state
	match new_state:
		State.PATROL:
			_play("Hover")
		State.CHASE:
			_play("Hover")
		State.ATTACK:
			_play_attack_anim()
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
		return  # 已有仇恨目标，忽略
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

## 复活（EnemyBase.enemy_respawned）
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
	_play("Hover")

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

## 死亡淡出流程
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
	# 死亡结束：隐藏并停用物理，等待存档点/角色重生触发 EnemyBase 复活
	visible = false
	set_physics_process(false)
	if _base and _base.has_method("disable_collision"):
		_base.disable_collision()
