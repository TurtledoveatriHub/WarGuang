# Scripts/Entities/Enemys/EnemyBase.gd
## 敌人基础脚本（挂载在敌人场景根节点的子节点上）
## 负责：血量管理、受伤/死亡/复活、接触玩家伤害
## 通过信号与 RegularEnemy / FlyingEnemy（父节点）协作
## 复活策略（仅两种）：
##   PERMANENT   —— 永久死亡：死亡后隐藏，不再复活
##   ON_CHECKPOINT —— 角色与存档点交互（含角色死亡重生自动回档点）时复活
## 不再有“固定时间自动复活”，复活直接由父 AI 播 Idle 恢复，不走 Respawn 动画。

extends Node2D
class_name EnemyBase

## ── 血量 ──
@export_category("血量")
## 最大血量
@export var max_health: int = 5
var health: int = 5

## ── 受伤 ──
@export_category("受伤")
## 受伤后无敌时间（秒）
@export var invincible_time: float = 0.8
## 启用来自 HurtBox 的击退效果
@export var enable_hurtbox_knockback: bool = true
## 受伤击退缩放系数（0~1，越小越轻柔，更接近 Hollow Knight 的短冲量手感）
@export var hurt_knockback_scale: float = 0.5
## 受伤时允许的最大水平速度
@export var max_hurt_velocity_x: float = 160.0
## 受伤时允许的最大垂直速度
@export var max_hurt_velocity_y: float = 240.0

## ── 接触玩家伤害 ──
@export_category("接触玩家伤害")
## 启用接触伤害
@export var enable_contact_damage: bool = true
## 接触伤害值
@export var contact_damage: int = 1
## 接触伤害冷却（秒）
@export var contact_damage_cooldown: float = 0.2
## 击退力（对player，x=水平,y=垂直）
@export var knockback_force: Vector2 = Vector2(100, 50)

## ── 死亡/复活 ──
@export_category("死亡与复活")
## 复活模式
@export var respawn_mode: RespawnMode = RespawnMode.ON_CHECKPOINT

## ── 信号 ──
signal damage_taken(damage: int, current_health: int)
signal enemy_died()
signal enemy_respawned()
## 完全刷新信号（由 force_refresh 触发，不走 Respawn 动画）
signal enemy_force_refreshed()

## 复活模式枚举
enum RespawnMode {
	PERMANENT = 0,      ## 永久死亡（永不复活）
	ON_CHECKPOINT = 1,  ## 角色与存档点交互 / 角色死亡重生时复活
}

var _parent: CharacterBody2D = null
var _invincible_timer: float = 0.0
var _contact_cooldown: float = 0.0
var _spawn_position: Vector2 = Vector2.ZERO
var _is_dead: bool = false

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

## 受到伤害（由 HurtBox / HurtBoxMap 调用）
func take_damage(damage: int, kb_force: Vector2 = Vector2.ZERO) -> void:
	if _is_dead or _invincible_timer > 0.0:
		return
	health -= damage
	_invincible_timer = invincible_time
	_parent.modulate.a = 0.5
	## 受伤击退：改为“冲量叠加 + 限幅”，避免直接覆盖速度导致被打飞感过强。
	if enable_hurtbox_knockback and kb_force != Vector2.ZERO:
		var impulse: Vector2 = kb_force * hurt_knockback_scale
		var clamped_impulse: Vector2 = Vector2(
			clamp(impulse.x, -max_hurt_velocity_x, max_hurt_velocity_x),
			clamp(impulse.y, -max_hurt_velocity_y, max_hurt_velocity_y)
		)
		_parent.velocity += clamped_impulse
	damage_taken.emit(damage, health)
	if health <= 0:
		_die()

## 接触玩家伤害（由 KillZone Area2D 的 body_entered 连接）
## 使用与 HurtBox 一致的击退方向计算：水平推离敌人，垂直固定向上
func _on_killzone_entered(body: Node) -> void:
	if not enable_contact_damage or _contact_cooldown > 0.0:
		return
	if body.is_in_group("player") and body.has_method("take_damage"):
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
	# 碰撞体不在死亡时立即禁用，由父 AI 在 Die 动画完成后调用 disable_collision()

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

## 外部：复活（由 ChairSavePoint 交互时调用；角色死亡重生也会经由该路径复活敌人）
## 仅 ON_CHECKPOINT 模式生效
func revive_by_save() -> void:
	if respawn_mode == RespawnMode.PERMANENT:
		return
	if not _is_dead:
		return
	_revive()

## 强制完全刷新（由 角色死亡重生 时调用，重置到出生点）
## 仅 ON_CHECKPOINT 模式生效
func force_refresh() -> void:
	if respawn_mode == RespawnMode.PERMANENT:
		return
	_is_dead = false
	health = max_health
	_parent.global_position = _spawn_position
	_parent.velocity = Vector2.ZERO
	_invincible_timer = invincible_time
	if _parent.has_node("CollisionShape2D"):
		_parent.get_node("CollisionShape2D").set_deferred("disabled", false)
	enemy_force_refreshed.emit()

func is_dead() -> bool:
	return _is_dead

func get_health_percent() -> float:
	return float(health) / float(max_health) if max_health > 0 else 0.0
