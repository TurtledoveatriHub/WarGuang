# Scripts/Enemys/EnemyBase.gd
## 敌人基础脚本（挂载在敌人场景根节点的子节点上）
## 负责：血量管理、受伤/死亡/复活、接触玩家伤害
## 通过信号与 RegularEnemy（父节点）协作

extends Node2D
class_name EnemyBase

## ── 血量 ──
@export_category("血量")
@export var max_health: int = 5
var health: int = 5

## ── 受伤 ──
@export_category("受伤")
## 受伤后无敌时间（秒）
@export var invincible_time: float = 0.8
## 启用来自 HurtBox 的击退效果
@export var enable_hurtbox_knockback: bool = true

## ── 接触玩家伤害 ──
@export_category("接触玩家伤害")
## 启用接触伤害
@export var enable_contact_damage: bool = true
## 接触伤害值
@export var contact_damage: int = 1
## 接触伤害冷却（秒）
@export var contact_damage_cooldown: float = 0.2
## 击退力（对player，x=水平,y=垂直）
@export var knockback_force: Vector2 = Vector2(100, 200)

## ── 死亡 ──
@export_category("死亡")
## 复活模式
@export var respawn_mode: RespawnMode = RespawnMode.TIMED
## 固定时间复活等待时长（秒），仅 TIMED 模式生效
@export var respawn_delay: float = 6.0

## ── 信号 ──
signal damage_taken(damage: int, current_health: int)
signal enemy_died()
signal enemy_respawned()
## 完全刷新信号（由 force_refresh 触发，不走 Respawn 动画）
signal enemy_force_refreshed()

## 复活模式枚举
enum RespawnMode {
	PERMANENT = 0,      ## 永不复活（完全死亡，没有任何复活场景）
	TIMED = 1,           ## 冷却时间复活（_respawn_timer 归零后自动复活）
	ON_CHECKPOINT = 2,   ## 存档交互/角色死亡重生时复活
}

var _parent: CharacterBody2D = null
var _invincible_timer: float = 0.0
var _contact_cooldown: float = 0.0
var _spawn_position: Vector2 = Vector2.ZERO
var _is_dead: bool = false
var _respawn_timer: float = 0.0

func _ready() -> void:
	_parent = get_parent() as CharacterBody2D
	if _parent == null:
		set_process(false)
		return
	_spawn_position = _parent.global_position
	health = max_health
	## 注册到 enemy_base 组，供存档/切房间时遍历复活
	add_to_group("enemy_base")

func _process(delta: float) -> void:
	if _invincible_timer > 0.0:
		_invincible_timer -= delta
		if _parent:
			_parent.modulate.a = 0.5
	elif _parent and _parent.modulate.a != 1.0:
		_parent.modulate.a = 1.0
	if _contact_cooldown > 0.0:
		_contact_cooldown -= delta
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0 and respawn_mode == RespawnMode.TIMED:
			_revive()

## 受到伤害（由 HurtBox / HurtBoxMap 调用）
func take_damage(damage: int, kb_force: Vector2 = Vector2.ZERO) -> void:
	if _is_dead or _invincible_timer > 0.0:
		return
	health -= damage
	_invincible_timer = invincible_time
	_parent.modulate.a = 0.5
	# 受伤击退（替换当前速度，HURT 状态不再清零 velocity.x）
	if enable_hurtbox_knockback and kb_force != Vector2.ZERO:
		_parent.velocity = kb_force
	damage_taken.emit(damage, health)
	if health <= 0:
		_die()
	else:
		pass  # RegularEnemy 通过 damage_taken 信号处理 HURT 状态

## 接触玩家伤害（由 KillZone Area2D 的 body_entered 连接）
## 使用与 HurtBox 一致的击退方向计算：水平推离敌人，垂直固定向上
func _on_killzone_entered(body: Node) -> void:
	if not enable_contact_damage or _contact_cooldown > 0.0:
		return
	if body.is_in_group("player") and body.has_method("take_damage"):
		# 计算击退方向：水平朝远离敌人的方向，垂直向上
		var dir: Vector2 = (body.global_position - _parent.global_position).normalized()
		var knockback: Vector2 = Vector2(
			sign(dir.x) * knockback_force.x,
			-knockback_force.y
		)
		body.take_damage(_parent.global_position, contact_damage, 0, knockback)
		_contact_cooldown = contact_damage_cooldown

## 死亡
func _die() -> void:
	_is_dead = true
	enemy_died.emit()
	# 注意：碰撞体不在死亡时立即禁用，由 RegularEnemy 在 Die 动画完成后调用 disable_collision()
	# 以防止敌人立即坠落

## 外部：Die 动画完成后禁用碰撞体
func disable_collision() -> void:
	if _parent and _parent.has_node("CollisionShape2D"):
		_parent.get_node("CollisionShape2D").set_deferred("disabled", true)

## 复活
func _revive() -> void:
	_is_dead = false
	health = max_health
	_parent.global_position = _spawn_position
	_parent.velocity = Vector2.ZERO
	## 清除无敌闪烁，防止复活后仍半透明
	_invincible_timer = 0.0
	_parent.modulate.a = 1.0
	enemy_respawned.emit()
	if _parent.has_node("CollisionShape2D"):
		_parent.get_node("CollisionShape2D").set_deferred("disabled", false)

## 外部：复活（由 ChairSavePoint 交互时调用）
## ON_CHECKPOINT 和 TIMED 模式都生效
func revive_by_save() -> void:
	if respawn_mode == RespawnMode.PERMANENT:
		return
	if not _is_dead:
		return
	_respawn_timer = 0.0
	_revive()

## 强制完全刷新（由 角色死亡重生 时调用）
## ON_CHECKPOINT 和 TIMED 模式都生效
func force_refresh() -> void:
	if respawn_mode == RespawnMode.PERMANENT:
		return
	_is_dead = false
	health = max_health
	_parent.global_position = _spawn_position
	_parent.velocity = Vector2.ZERO
	_invincible_timer = invincible_time
	_respawn_timer = 0.0
	if _parent.has_node("CollisionShape2D"):
		_parent.get_node("CollisionShape2D").set_deferred("disabled", false)
	enemy_force_refreshed.emit()

## 复活（由 TIMED 冷却结束 / 房间切换时调用）
## 仅 TIMED 模式生效，播放正常 Respawn 动画
func start_respawn_timer() -> void:
	if respawn_mode == RespawnMode.TIMED:
		_respawn_timer = respawn_delay

## 房间切换复活（仅 TIMED 模式，播放正常动画）
func revive_by_room_switch() -> void:
	if respawn_mode == RespawnMode.TIMED and _is_dead:
		_respawn_timer = 0.0
		_revive()

func is_dead() -> bool:
	return _is_dead

func get_health_percent() -> float:
	return float(health) / float(max_health) if max_health > 0 else 0.0
