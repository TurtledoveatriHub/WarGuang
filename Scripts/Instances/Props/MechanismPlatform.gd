# Scripts/Instances/Props/MechanismPlatform.gd
## 机关平台 —— 继承 MechanismObject（机关物体）：由开关驱动位移，同时具备“移动平台”性质。
##  - 与 Platform.gd 同构的关键点：暴露 get_platform_velocity()，
##    Player._apply_platform_follow() 会读取 StaticBody2D 父节点的该方法使角色跟随平台移动。
##  - 加减速（acceleration_time / deceleration_time）由基类作用，本类不再重复实现。
##  - 动画表现：移动时 ON、静止时 OFF（不看开关是否激活）。
extends "res://Scripts/Instances/Props/MechanismObject.gd"
class_name MechanismPlatform

## ── 平台设置 ──
@export_category("平台设置")
## 是否把平台速度传递给站在上面的角色（关闭则角色不跟随平台）
@export var carry_rider: bool = true


## 供 Player._apply_platform_follow() 读取（关闭 carry_rider 时返回零）
func get_platform_velocity() -> Vector2:
	if not carry_rider:
		return Vector2.ZERO
	return _motion_velocity


## 移动状态变化：平台按“是否在移动”切 ON/OFF，而不是按激活态
func _on_motion_updated(is_moving: bool) -> void:
	_play_anim(ANIM_NAMES[Anim.ON] if is_moving else ANIM_NAMES[Anim.OFF])


## 基类 _recompute() 会按激活态切动画，这里立即按“是否移动”纠正回来
func _recompute() -> void:
	super._recompute()
	_on_motion_updated(_motion_velocity != Vector2.ZERO)
