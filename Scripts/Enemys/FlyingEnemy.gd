# Scripts/Enemys/FlyingEnemy.gd
## 飞行敌人样本 AI —— 参考空洞骑士「原始阿斯匹德(Aspid)」
## 行为：
##   1. 无目标时在出生点附近空中悬停漂移（不落地、不受重力）。
##   2. 玩家进入 PlayerDetector 后转为警戒：保持在一个理想距离，水平跟随玩家，
##      并把自身高度调整到玩家上方 hover_height_offset 处。
##   3. 距离合适且攻击冷却结束 → 短暂预警(Attack 动画) → 朝玩家当前位置连发弹幕(默认3连发)。
##   4. 玩家离开检测范围后恢复悬停巡逻。
## 状态机：PATROL(悬停) → CHASE(跟随保持距离) → ATTACK(连发弹幕) → HURT(受伤) → DIE(死亡) → RESPAWN(复活)
## 复用 EnemyBase.gd 负责：血量 / 无敌 / 受伤 / 死亡 / 复活 / 接触玩家伤害。
## 复用 RegularEnemy.gd 的方向约定：逻辑朝向 _dir 决定，仅翻转 AnimatedSprite2D（不翻转根节点）。
extends CharacterBody2D
class_name FlyingEnemy

## ── 悬停(巡逻) ──
@export_category("悬停巡逻")
## 无目标时水平漂移速度（像素/秒）
@export var hover_speed: float = 60.0
## 悬停允许离开出生点的最大水平半径（像素），超出自动掉头
@export var roam_radius: float = 120.0
## 垂直上下漂浮幅度（像素）
@export var bob_amplitude: float = 24.0
## 垂直漂浮速度（角速度，弧度/秒）
@export var bob_speed: float = 1.2

## ── 跟随/保持距离 ──
@export_category("跟随与射击距离")
## 开始警戒并靠近玩家的水平距离（像素）
@export var engage_distance: float = 320.0
## 水平距离小于该值会后退（避免贴脸），大于该值会靠近
@export var ideal_horizontal_distance: float = 160.0
## 跟随玩家的水平移动速度（像素/秒）
@export var track_speed: float = 120.0
## 保持相对玩家上方的高度偏移（像素，负值=高于玩家头部）
@export var hover_height_offset: float = -30.0
## 垂直跟随速度（像素/秒）
@export var vertical_follow_speed: float = 60.0

## ── 攻击/弹幕 ──
@export_category("弹幕攻击")
## 进入此水平距离内才发动攻击（像素）
@export var attack_range: float = 220.0
## 两轮弹幕之间的冷却时间（秒）
@export var shot_interval: float = 2.4
## 每轮连发子弹数量
@export var burst_count: int = 3
## 连发间隔（秒）
@export var burst_gap: float = 0.18
## 开火前预警动画时长（秒，播放 Attack 动画）
@export var windup_time: float = 0.4
## 子弹速度（像素/秒）
@export var bullet_speed: float = 220.0
## 子弹对玩家的伤害值
@export var bullet_damage: int = 1
## 子弹命中玩家的击退力（Vector2，方向=子弹飞行方向）
@export var bullet_knockback: Vector2 = Vector2(140, 120)
## 子弹存活时间（秒），超时自动消失
@export var bullet_life: float = 3.0
## 子弹碰撞半径（像素）
@export var bullet_radius: float = 6.0

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
## 玩家检测区域（Area2D，默认半径160）
@export_node_path var player_detector_path: NodePath = NodePath("PlayerDetector")
## 接触伤害区（Area2D，由 EnemyBase 处理）
@export_node_path var killzone_path: NodePath = NodePath("KillZone")
## EnemyBase 子节点
@export_node_path var enemy_base_path: NodePath = NodePath("EnemyBase")
## 伤害区域感知（保留以便扩展，飞行怪当前不依赖它做巡逻决策）
@export_node_path var hurtbox_detector_path: NodePath = NodePath("HurtBoxDetector")

enum State { PATROL, CHASE, ATTACK, HURT, DIE, RESPAWN, IDLE }

## 当前状态
var _state: int = State.PATROL
## 当前水平朝向（1=右，-1=左），决定贴图翻转
var _dir: int = 1
## 出生点（用于悬停范围限制）
var _spawn_pos: Vector2 = Vector2.ZERO

## 内部节点引用
var _sprite: AnimatedSprite2D = null
var _base: Node = null
var _player: Node = null
var _detector: Area2D = null

## 悬停相位（正弦 bob 用）
var _hover_phase: float = 0.0
## 当前漂移方向
var _roam_dir: int = 1
## 检测间隔计时
var _detect_timer: float = 0.0
## 受伤计时
var _hurt_timer: float = 0.0
## 攻击冷却计时（>=0 时正在冷却）
var _shot_cd: float = 0.0
## 当前轮次攻击流程计时（预警或连发）
var _attack_timer: float = 0.0
## 已发射的子弹数量（当前轮）
var _burst_fired: int = 0
## 是否处于预警/连发中
var _attacking: bool = false

## 死亡淡出 tween
var _death_tween: Tween = null
## 贴图基准 scale.x（用于翻转；SnowBird 默认 1，Snowman 这类可能为 2）
var _base_scale_x: float = 1.0

## 子弹用共享圆点贴图（懒生成一次）
static var _bullet_texture: Texture2D = null


func _ready() -> void:
	_spawn_pos = global_position
	_hover_phase = randf() * TAU
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
	
	if player_detector_path:
		_detector = get_node(player_detector_path) as Area2D
		if _detector:
			_detector.body_entered.connect(_on_player_enter)
			_detector.body_exited.connect(_on_player_leave)
	
	if killzone_path and _base and _base.has_method("_on_killzone_entered"):
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.body_entered.connect(_base._on_killzone_entered)
	
	if _sprite and _sprite.sprite_frames:
		_sprite.animation_finished.connect(_on_anim_end)


func _physics_process(d: float) -> void:
	if _state == State.DIE:
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		return
	if _state == State.RESPAWN or _state == State.IDLE:
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		return
	if _state == State.HURT:
		# 受伤：保留击退冲量但做衰减，结束后回到悬停
		velocity = velocity.move_toward(Vector2.ZERO, hurt_drag * d)
		move_and_slide()
		_hurt_timer -= d
		if _hurt_timer <= 0.0:
			_change(State.PATROL)
		return
	
	# 冷却递减
	if _shot_cd > 0.0:
		_shot_cd -= d
	
	# 朝向更新：有目标时持续面向玩家
	if _player and is_instance_valid(_player):
		var dx_to_player: float = _player.global_position.x - global_position.x
		if dx_to_player != 0.0:
			_dir = 1 if dx_to_player > 0.0 else -1
		# 检测间隔切换追击/巡逻
		_detect_timer += d
		if _detect_timer >= 0.2:
			_detect_timer = 0.0
			if _state != State.ATTACK:
				_change(State.CHASE)
	elif _state == State.CHASE or _state == State.ATTACK:
		_change(State.PATROL)
	
	match _state:
		State.PATROL:
			_patrol(d)
		State.CHASE:
			_chase(d)
		State.ATTACK:
			_attack(d)
	
	_apply_flip()
	move_and_slide()


## 更新贴图朝向（只翻转 AnimatedSprite2D，不翻转根节点）
func _apply_flip() -> void:
	if _sprite and is_instance_valid(_sprite):
		_sprite.scale.x = _base_scale_x if _dir > 0 else -_base_scale_x


## 悬停巡逻：左右漂移 + 正弦上下浮动，限制在出生点 roam_radius 内
func _patrol(d: float) -> void:
	_hover_phase += bob_speed * d
	# 水平漂移并处理边界掉头
	var target_vx: float = _roam_dir * hover_speed
	velocity.x = move_toward(velocity.x, target_vx, hover_speed * 4.0 * d)
	if global_position.x > _spawn_pos.x + roam_radius:
		_roam_dir = -1
	elif global_position.x < _spawn_pos.x - roam_radius:
		_roam_dir = 1
	# 垂直：围绕出生点高度的正弦 bob
	var target_y: float = _spawn_pos.y + sin(_hover_phase) * bob_amplitude
	var diff_y: float = target_y - global_position.y
	velocity.y = clampf(diff_y * 4.0, -vertical_follow_speed, vertical_follow_speed)
	_play("Hover")


## 警戒跟随：调整到玩家上方的理想高度，水平保持 ideal_horizontal_distance
func _chase(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_change(State.PATROL)
		return
	# 水平距离控制：太远靠近、太近后退、合适则缓停
	var dx: float = _player.global_position.x - global_position.x
	var dist: float = absf(dx)
	if dist > ideal_horizontal_distance + 12.0:
		var toward: float = hover_speed if dist > engage_distance else track_speed
		velocity.x = move_toward(velocity.x, signf(dx) * toward, track_speed * 4.0 * d)
	elif dist < ideal_horizontal_distance - 20.0:
		# 太近：背离玩家后退，避免贴脸
		velocity.x = move_toward(velocity.x, -signf(dx) * track_speed * 0.6, track_speed * 4.0 * d)
	else:
		velocity.x = move_toward(velocity.x, 0.0, track_speed * 4.0 * d)
	# 垂直：趋向“玩家上方 hover_height_offset”
	var target_y: float = _player.global_position.y + hover_height_offset
	var dy: float = target_y - global_position.y
	velocity.y = clampf(dy * 3.0, -vertical_follow_speed, vertical_follow_speed)
	# 移动中播悬停动画
	_play("Hover")
	# 距离合适且冷却结束 → 开始攻击
	if dist <= attack_range and _shot_cd <= 0.0 and not _attacking:
		_begin_attack()


## 开始一轮攻击：先预警(windup)，随后连发子弹
func _begin_attack() -> void:
	_attacking = true
	_attack_timer = windup_time
	_burst_fired = 0
	_change(State.ATTACK)


func _attack(d: float) -> void:
	if not _player or not is_instance_valid(_player):
		_attacking = false
		_change(State.PATROL)
		return
	_play("Attack")
	_attack_timer -= d
	if _attack_timer > 0.0:
		# 预警期间几乎悬停（轻微缓停）
		velocity.x = move_toward(velocity.x, 0.0, track_speed * 4.0 * d)
		velocity.y = move_toward(velocity.y, 0.0, vertical_follow_speed * 2.0 * d)
		return
	# 连发阶段：按 burst_gap 间隔发射
	if _burst_fired < burst_count:
		_fire_one()
		_burst_fired += 1
		_attack_timer = burst_gap
		return
	# 本轮结束：设置冷却，回到警戒
	_attacking = false
	_shot_cd = shot_interval
	_change(State.CHASE)


## 朝玩家当前位置发射一颗子弹
func _fire_one() -> void:
	if not _player or not is_instance_valid(_player):
		return
	var dir_to_player: Vector2 = (_player.global_position - global_position).normalized()
	_spawn_bullet(dir_to_player)


## 生成一颗子弹（挂在当前节点的兄弟位置，避免受敌人自身变换影响）
## 子弹朝 dir 直线飞行：命中玩家造成伤害；撞到地形(层2)或超时自动消失。
func _spawn_bullet(dir: Vector2) -> void:
	var bullet := EnemyBulletArea.new()
	bullet.collision_layer = 32     # 层6(2^5)，避免被玩家攻击/HurtBox误伤
	bullet.collision_mask = 3       # 检测层1 Player + 层2 地形
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = bullet_radius
	shape.shape = circle
	bullet.add_child(shape)
	
	var sprite := Sprite2D.new()
	sprite.texture = _get_bullet_texture()
	sprite.scale = Vector2.ONE * (bullet_radius * 2.0 / 32.0)
	bullet.add_child(sprite)
	
	bullet.global_position = global_position
	bullet.velocity_dir = dir.normalized()
	bullet.speed = bullet_speed
	bullet.damage = bullet_damage
	bullet.knockback = bullet_knockback
	bullet.life = bullet_life
	
	var parent := get_parent()
	if parent:
		parent.add_child(bullet)


## 惰性生成子弹圆点贴图（32x32，白点，可通过 modulate 上色）
static func _get_bullet_texture() -> Texture2D:
	if _bullet_texture:
		return _bullet_texture
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var center := Vector2(15.5, 15.5)
	var max_d := 15.5
	for y in range(32):
		for x in range(32):
			var dist: float = Vector2(x, y).distance_to(center)
			var a: float = clampf(1.0 - dist / max_d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_bullet_texture = ImageTexture.create_from_image(img)
	return _bullet_texture


## 子弹内部类：Area2D 直线飞行
class EnemyBulletArea extends Area2D:
	## 飞行方向（单位向量）
	var velocity_dir: Vector2 = Vector2.RIGHT
	## 飞行速度（像素/秒）
	var speed: float = 220.0
	## 伤害值
	var damage: int = 1
	## 命中玩家的击退力
	var knockback: Vector2 = Vector2(140, 120)
	## 剩余寿命（秒）
	var life: float = 3.0
	## 是否已命中（防止重复伤害）
	var _hit: bool = false

	func _ready() -> void:
		body_entered.connect(_on_body_entered)

	func _physics_process(d: float) -> void:
		global_position += velocity_dir * speed * d
		life -= d
		if life <= 0.0 and not _hit:
			queue_free()

	func _on_body_entered(body: Node) -> void:
		if _hit:
			return
		if body.is_in_group("player") and body.has_method("take_damage"):
			_hit = true
			## 命中玩家：伤害 + 按子弹飞行方向击退
			body.take_damage(global_position, damage, 0, velocity_dir * knockback)
			queue_free()
		elif body is CharacterBody2D and (body.collision_layer & 2) != 0:
			# 撞到地形(层2)消失
			_hit = true
			queue_free()


## 安全播放动画（仅当存在该动画且不同时才切换）
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
			_play("Hover")
		State.CHASE:
			_play("Hover")
		State.ATTACK:
			_play("Attack")
		State.HURT:
			_play("Hurt")
		State.DIE:
			_play("Die")


# ════════════════════════════════════════
# 信号
# ════════════════════════════════════════

func _on_player_enter(body: Node) -> void:
	if body.is_in_group("player"):
		_player = body

func _on_player_leave(body: Node) -> void:
	if body.is_in_group("player"):
		_player = null
		if _state == State.CHASE or _state == State.ATTACK:
			_change(State.PATROL)

## 受伤（由 EnemyBase.damage_taken 触发）
func _on_hurt(_damage: int, current_health: int) -> void:
	if _state in [State.DIE, State.RESPAWN]:
		return
	if current_health <= 0:
		_change(State.DIE)
		_play("Die")
		return
	_change(State.HURT)
	_hurt_timer = hurt_duration

## 死亡（EnemyBase.enemy_died）→ 关闭接触伤害区
func _on_disable_killzone() -> void:
	if killzone_path:
		var kz := get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", false)

func _on_die() -> void:
	_attacking = false
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

## 强制完全刷新（角色死亡重生 / 切房间调用）
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

## 死亡淡出流程（与 RegularEnemy 一致：淡出→隐藏→禁用碰撞→等待 EnemyBase 复活）
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
	if _base and _base.has_method("disable_collision"):
		_base.disable_collision()
	if _base and _base.has_method("start_respawn_timer"):
		_base.start_respawn_timer()
	if _base and _base.has_method("is_dead") and _base.is_dead():
		match int(_base.respawn_mode):
			EnemyBase.RespawnMode.PERMANENT:
				visible = false
				set_physics_process(false)
			EnemyBase.RespawnMode.TIMED:
				_state = State.RESPAWN
			EnemyBase.RespawnMode.ON_CHECKPOINT:
				visible = false
				set_physics_process(false)
