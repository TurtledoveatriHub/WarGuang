# Scripts/Enemys/RegularEnemy.gd
## 常规敌人 AI —— 雪人专用
## 状态机：PATROL(巡逻) → CHASE(追击) → HURT(受伤) → DIE(死亡) → RESPAWN(复活)
## 核心原则：纹理方向(scale.x)与移动方向(sign(velocity.x))永远一致
extends CharacterBody2D
class_name RegularEnemy

## ── 移动 ──
@export_category("移动")
## 巡逻移动速度（像素/秒）
@export var move_speed: float = 60.0
## 追击移动速度（像素/秒）
@export var chase_speed: float = 120.0
## 跳跃初速度（负值=向上，像素/秒）
@export var jump_velocity: float = -480.0
## 重力加速度（像素/秒²）
@export var gravity: float = 900.0
## 地面摩擦强度，用于受伤和落地状态的速度衰减
@export var ground_drag: float = 220.0
## 受伤状态下的水平拖拽强度，避免瞬时被抛飞感过强
@export var hurt_drag: float = 190.0

## ── 节点路径 ──
@export_category("节点路径")
@export_node_path var obstacle_detector_path: NodePath
@export_node_path var cliff_detector_path: NodePath
@export_node_path var player_detector_path: NodePath
@export_node_path var killzone_path: NodePath
@export_node_path var hurtbox_detector_path: NodePath
@export_node_path var enemy_base_path: NodePath = NodePath("EnemyBase")

## ── 检测应对策略 ──
## IGNORE=忽略, FLIP=停住等待后掉头, JUMP=跳跃越过（跳跃时保持移动方向速度）
enum Resp { IGNORE, FLIP, JUMP }
@export_category("巡逻检测应对策略")
## 巡逻-遇障碍物
@export var patrol_on_obstacle: Resp = Resp.JUMP
## 巡逻-遇悬崖
@export var patrol_on_cliff: Resp = Resp.FLIP
## 巡逻-遇伤害区域
@export var patrol_on_hurtbox: Resp = Resp.FLIP

@export_category("追击检测应对策略")
## 追击-遇障碍物
@export var chase_on_obstacle: Resp = Resp.JUMP
## 追击-遇悬崖
@export var chase_on_cliff: Resp = Resp.JUMP
## 追击-遇伤害区域
@export var chase_on_hurtbox: Resp = Resp.FLIP

## ── 玩家检测 ──
@export_category("玩家检测")
## 玩家检测间隔（秒）
@export var player_detect_interval: float = 0.3
## 玩家进入 PlayerDetector 范围追击，离开范围恢复巡逻

## ── 巡逻行为 ──
@export_category("巡逻行为")
## 触发FLIP/条件阻塞后的等待时长（秒）
@export var patrol_idle_on_block: float = 1.0
## 周期性停顿间隔（秒）
@export var patrol_idle_interval: float = 3.0
## 周期性停顿持续时长（秒）
@export var patrol_idle_duration: float = 2.0
## 周期性停顿触发概率（0~1）
@export var patrol_idle_chance: float = 0.5

## ── 受伤/死亡 ──
@export_category("受伤/死亡")
## 受伤硬直持续时间（秒）
@export var hurt_duration: float = 0.4
## 死亡淡出持续时间（秒）
@export var death_fade_duration: float = 2.0

enum State { PATROL, CHASE, HURT, DIE, RESPAWN, IDLE }

## 当前状态
var _state: int = State.PATROL
## 当前逻辑方向（1=右，-1=左），不再直接用作每帧 sprite 强制翻转的唯一来源。
var _dir: int = 1
## 当前渲染朝向，独立管理 sprite flip，避免速度与折算方向互相覆盖。
var _facing_dir: int = 1
var _sprite: AnimatedSprite2D = null
var _base: Node = null
var _player: Node = null
var _spawn_pos: Vector2 = Vector2.ZERO

var _patrol_timer: float = 0.0
var _block_timer: float = 0.0
var _is_blocked: bool = false
var _hurt_timer: float = 0.0
var _detect_timer: float = 0.0
## 当前是否处于跳跃空中（落地前为true），用于防止空中触发地面条件检测
var _in_air_jumped: bool = false
## 动画锁：true时防止 Move/Run/Down 覆盖当前动画（如Jump）
var _anim_lock_jump: bool = false

## FLIP 防抖
var _flip_cooldown: float = 0.0
const FLIP_COOLDOWN_DURATION: float = 0.5
## 死亡淡出 tween
var _death_tween: Tween = null

var _obs_ray: RayCast2D = null
var _cliff_ray: RayCast2D = null
var _in_hurt: bool = false


func _ready():
	_spawn_pos = global_position
	_sprite = $AnimatedSprite2D
	_facing_dir = _dir
	
	if enemy_base_path: _base = get_node(enemy_base_path)
	if _base:
		if _base.has_signal("damage_taken"):
			_base.damage_taken.connect(_on_hurt)
		if _base.has_signal("enemy_died"):
			_base.enemy_died.connect(_on_die)
		if _base.has_signal("enemy_respawned"):
			_base.enemy_respawned.connect(_on_revive)
		if _base.has_signal("enemy_force_refreshed"):
			_base.enemy_force_refreshed.connect(_on_force_refresh)
		## 死亡时禁用KillZone
		if _base.has_signal("enemy_died"):
			_base.enemy_died.connect(_on_disable_killzone)
	
	if obstacle_detector_path: _obs_ray = get_node(obstacle_detector_path)
	if cliff_detector_path: _cliff_ray = get_node(cliff_detector_path)
	
	if player_detector_path:
		var a = get_node(player_detector_path) as Area2D
		if a:
			a.body_entered.connect(_on_player_enter)
			a.body_exited.connect(_on_player_leave)
	
	if killzone_path and _base and _base.has_method("_on_killzone_entered"):
		var k = get_node(killzone_path) as Area2D
		if k: k.body_entered.connect(_base._on_killzone_entered)
	
	if hurtbox_detector_path:
		var h = get_node(hurtbox_detector_path) as Area2D
		if h:
			h.area_entered.connect(_on_hurtbox_area_entered)
			h.area_exited.connect(_on_hurtbox_area_exited)
	
	if _sprite and _sprite.sprite_frames:
		_sprite.animation_finished.connect(_on_anim_end)


func _physics_process(d):
	# ── 地面检测（落地后重置跳跃状态和锁） ──
	if is_on_floor():
		_in_air_jumped = false
		_anim_lock_jump = false
	
	if _flip_cooldown > 0:
		_flip_cooldown -= d
	
	# 方向安全钳位（防止 _dir 意外为 0 或其它非法值）
	_dir = 1 if _dir >= 0 else -1
	_sync_flip()
	
	match _state:
		State.IDLE, State.RESPAWN:
			velocity.x = move_toward(velocity.x, 0.0, ground_drag * d)
			_apply_gravity(d)
			_apply_vel_flip()
			move_and_slide()
			return
		State.HURT:
			# HURT 状态：保留击退冲量，但做有限缓减，避免瞬间被抛飞。
			_apply_gravity(d)
			if is_on_floor():
				velocity.x = move_toward(velocity.x, 0.0, hurt_drag * d)
			_apply_vel_flip()
			move_and_slide()
			_hurt_timer -= d
			if _hurt_timer <= 0: _change(State.PATROL)
			return
		State.DIE:
			velocity.x = move_toward(velocity.x, 0.0, ground_drag * d)
			_apply_gravity(d)
			_apply_vel_flip()
			move_and_slide()
			return
	
	_apply_gravity(d)
	
	# ── 玩家检测（PlayerDetector 区域决定追击/巡逻） ──
	_detect_timer += d
	if _detect_timer >= player_detect_interval:
		_detect_timer = 0
		if _player and is_instance_valid(_player):
			var dx = _player.global_position.x - global_position.x
			var new_dir: int = 1 if dx >= 0 else -1
			## ★ 根因修复：方向变化过快导致鬼畜翻转 — 用 flip_cooldown 限制最小翻转间隔
			if new_dir != _dir and _flip_cooldown <= 0.0:
				_dir = new_dir
				_flip_cooldown = FLIP_COOLDOWN_DURATION
			_change(State.CHASE)
		elif _state == State.CHASE:
			_change(State.PATROL)
	
	# ── 状态处理 ──
	if _state == State.CHASE: _chase(d)
	elif _state == State.PATROL: _patrol(d)
	
	# ★ 纹理方向无条件跟随 velocity.x
	_apply_vel_flip()
	
	move_and_slide()


# ════════════════════════════════════════
# 巡逻
# ════════════════════════════════════════

func _patrol(d):
	# 阻塞中：等待计时，不执行任何检测
	if _is_blocked:
		_block_timer -= d
		velocity.x = 0
		_play("Idle")
		if _block_timer <= 0:
			_is_blocked = false
			## 周期性停顿结束后的二次50%判断：继续原方向 或 翻转方向
			if randf() < 0.5:
				_dir = -_dir
				_flip_cooldown = FLIP_COOLDOWN_DURATION
		return
	
	# ★ 防抖 / 空中跳跃时跳过地面条件检测
	if _flip_cooldown > 0 or _in_air_jumped:
		pass  # 跳过条件检测
	else:
		# ── 条件检测（按优先级） ──
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
		if _in_hurt:
			match patrol_on_hurtbox:
				Resp.FLIP: _block_on_condition(); return
				Resp.JUMP: _do_jump(move_speed)
				_: pass
	
	# ── 周期性停顿 ──
	_patrol_timer += d
	if _patrol_timer >= patrol_idle_interval:
		_patrol_timer = 0
		if randf() < patrol_idle_chance:
			_is_blocked = true
			_block_timer = patrol_idle_duration
			return
	
	# ── 正常行走 ──
	if not _anim_lock_jump:
		velocity.x = _dir * move_speed
		# ★ 仅在地面时播放 Move 动画（空中让 Down 优先）
		if is_on_floor():
			_play("Move")


# ════════════════════════════════════════
# 追击
# ════════════════════════════════════════

func _chase(_d):
	# 跳跃应对（保持 chase_speed 水平速度）
	if _obs_ray and _obs_ray.is_colliding() and chase_on_obstacle == Resp.JUMP:
		_do_jump(chase_speed)
	if _cliff_ray and not _cliff_ray.is_colliding() and chase_on_cliff == Resp.JUMP:
		_do_jump(chase_speed)
	if _in_hurt and chase_on_hurtbox == Resp.JUMP:
		_do_jump(chase_speed)
	
	# 正常追击
	if not _anim_lock_jump:
		velocity.x = _dir * chase_speed
		# ★ 仅在地面时播放 Run 动画
		if is_on_floor():
			_play("Run")


# ════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════

## 纹理方向统一跟随逻辑朝向，不再被 velocity.x 的瞬时波动打断。
## 这样可以避免每帧都左右翻转鬼畜，保证 Sprite 与 AI 朝向始终一致。
func _apply_vel_flip() -> void:
	if _state in [State.DIE, State.RESPAWN]:
		return
	_facing_dir = _dir
	if _sprite and is_instance_valid(_sprite):
		_sprite.scale.x = 2.0 if _facing_dir > 0 else -2.0
	# 根节点 scale 不能在这里改，否则会把 RayCast 与 CollisionShape 也一起翻转，导致逻辑错乱。

## 同步射线方向：只让 RayCast 的目标方向随 _dir 变化，不碰根节点 scale。
func _sync_flip() -> void:
	var target: int = _dir
	if _obs_ray:
		_obs_ray.target_position = Vector2(50 * target, 0)
	if _cliff_ray:
		_cliff_ray.target_position = Vector2(50 * target, 25)
	if _sprite and is_instance_valid(_sprite):
		_sprite.scale.x = 2.0 if target > 0 else -2.0

## 重力与下落动画
func _apply_gravity(d):
	if not is_on_floor():
		velocity.y += gravity * d
		# ★ 空中下落时播 Down（在空中时 Move/Run 不会覆盖，见 _patrol/_chase）
		if velocity.y > 0 and _state in [State.PATROL, State.CHASE]:
			_play("Down")

## 跳跃：同时设置水平和垂直速度，保持移动方向
func _do_jump(h_speed: float):
	if is_on_floor() and not _in_air_jumped:
		## 跳跃时保留当前前进方向，但不再直接把速度硬覆盖为极值，避免原地跳问题。
		velocity.y = jump_velocity
		var horizontal_base: float = max(abs(velocity.x), abs(_dir * h_speed))
		velocity.x = _dir * min(horizontal_base, max(abs(_dir * h_speed), 10.0)) * 0.85
		_in_air_jumped = true
		_anim_lock_jump = true       ## 锁定动画防止被 Move/Run/Down 覆盖
		_play("Jump")

## FLIP 阻塞
func _block_on_condition():
	_is_blocked = true
	_block_timer = patrol_idle_on_block
	velocity.x = 0
	_play("Idle")

## 安全播放动画（仅当目标动画与当前不同时才切换，防止每帧打断）
func _play(n):
	if _sprite and _sprite.sprite_frames and _sprite.sprite_frames.has_animation(n) and _sprite.animation != n:
		_sprite.play(n)

## 状态切换
func _change(s):
	if _state == s: return
	_state = s
	match s:
		State.PATROL:
			_patrol_timer = 0
			_is_blocked = false
		State.CHASE:
			_play("Run")
		State.HURT:
			_play("Hurt")
		State.DIE:
			_play("Die")
		State.RESPAWN:
			_play("Respawn")


# ════════════════════════════════════════
# 信号
# ════════════════════════════════════════

func _on_player_enter(b):
	## 玩家进入检测区域 — 切换追击，但不立即更新方向（等 _detect_timer 每 0.9s 处理）
	if b.is_in_group("player"):
		_player = b
		_change(State.CHASE)
func _on_player_leave(b):
	## 玩家离开检测区域 — ★ 立即恢复巡逻
	if b.is_in_group("player"):
		_player = null
		if _state == State.CHASE:
			_change(State.PATROL)

func _on_hurtbox_area_entered(area: Area2D) -> void:
	if area == null:
		_in_hurt = true
		return
	_in_hurt = true
	var enemy_base = get_node_or_null("EnemyBase")
	if enemy_base == null or not enemy_base.has_method("take_damage"):
		return
	var damage_value: int = 1
	if area.has_method("get"):
		var area_damage: Variant = area.get("enemy_damage")
		if typeof(area_damage) == TYPE_INT:
			damage_value = int(area_damage)
	var direction: Vector2 = (global_position - area.global_position).normalized()
	if direction == Vector2.ZERO:
		direction = Vector2.UP
	var knockback: Vector2 = Vector2(
		(direction.x * 100.0),
		(direction.y * 100.0)
	)
	if area.has_method("get"):
		var area_knockback: Variant = area.get("enemy_knockback")
		if typeof(area_knockback) == TYPE_VECTOR2:
			knockback = Vector2(
				direction.x * abs(Vector2(area_knockback).x),
				direction.y * abs(Vector2(area_knockback).y)
			)
	enemy_base.take_damage(damage_value, knockback)

func _on_hurtbox_area_exited(_area: Area2D) -> void:
	_in_hurt = false

## 受伤（由 EnemyBase.damage_taken 信号触发）
func _on_hurt(_d, current_health):
	if _state in [State.DIE, State.RESPAWN]:
		return
	if current_health <= 0:
		_change(State.DIE)
		_play("Die")
		return
	_change(State.HURT)
	_hurt_timer = hurt_duration
	# ★ 击退保留：velocity 已由 EnemyBase.take_damage 设置，HURT 状态只做拖拽衰减，不再让 sprite 反复 flip

## 死亡（由 EnemyBase.enemy_died 信号触发）
## 死亡时禁用KillZone（避免死亡动画期间仍有伤害判定）
func _on_disable_killzone():
	if killzone_path:
		var kz = get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", false)

func _on_die():
	_change(State.DIE)

## 复活（由 EnemyBase.enemy_respawned 信号触发）
func _on_revive():
	# 确保 process 已启用
	if not is_processing(): set_process(true)
	if not is_physics_processing(): set_physics_process(true)
	# 杀死残留的死亡淡出tween
	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()
		_death_tween = null
	# 恢复KillZone
	if killzone_path:
		var kz = get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", true)
	visible = true
	modulate = Color.WHITE
	## 恢复 Respawn 动画，结束后 _on_anim_end 自动切 PATROL
	_change(State.RESPAWN)
	_play("Respawn")

## 完全刷新（无动画，直接 PATROL）
func _on_force_refresh():
	# 确保 process 已启用
	if not is_processing(): set_process(true)
	if not is_physics_processing(): set_physics_process(true)
	# 杀死残留 tween
	if _death_tween and _death_tween.is_valid():
		_death_tween.kill()
		_death_tween = null
	# 恢复KillZone
	if killzone_path:
		var kz = get_node(killzone_path) as Area2D
		if kz:
			kz.set_deferred("monitoring", true)
	visible = true
	modulate = Color.WHITE
	# 直接切 PATROL，不播放任何动画
	_change(State.PATROL)

## 动画结束回调
func _on_anim_end():
	if _sprite == null: return
	var a = _sprite.animation
	if a == "Die":
		if death_fade_duration > 0:
			## ★ 死亡倒计时锁：防止动画循环导致 _on_anim_end 重入
			if _death_tween and _death_tween.is_valid():
				return
			_death_tween = create_tween()
			_death_tween.tween_property(self, "modulate", Color(1,1,1,0), death_fade_duration)
			await _death_tween.finished
			_death_tween = null
		## ★ 如果 tween 执行期间已被复活（如存档交互），跳过死亡处理
		if _base and _base.has_method("is_dead") and not _base.is_dead():
			return
		visible = false
		if _base and _base.has_method("disable_collision"): _base.disable_collision()
		if _base and _base.has_method("start_respawn_timer"): _base.start_respawn_timer()
		if _base and _base.has_method("is_dead") and _base.is_dead():
			match _base.respawn_mode:
				## ★ 修复：PERMANENT 改为隐藏+禁用（不 queue_free），以便 revive_by_save 能复活
				EnemyBase.RespawnMode.PERMANENT:
					visible = false; set_process(false); set_physics_process(false)
				EnemyBase.RespawnMode.TIMED: _state = State.RESPAWN
				EnemyBase.RespawnMode.ON_CHECKPOINT:
					visible = false; set_process(false); set_physics_process(false)
	if a == "Respawn": _change(State.PATROL)
	if a == "Hurt": _change(State.PATROL)
