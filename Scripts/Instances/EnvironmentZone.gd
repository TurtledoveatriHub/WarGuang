# ★ 不加 @tool（理由见 EnvironmentZoneBase 顶部）：保证场景里的参数可自由修改
extends "res://Scripts/Instances/EnvironmentZoneBase.gd"
class_name EnvironmentZone

## 环境效果区（在房间里任意摆放、可自定义范围大小）
##
## 玩家进入本区域矩形时受到「环境速度乘数 / 重力乘数 / 最大下落速度乘数 / 风场」影响。
##
## ★ 生效方式（与 CameraLimitZone 同风格）：
##   本脚本**完全不碰**玩家的任何字段，也**不依赖物理进出信号**；
##   它在 _ready 里加入组 "environment_zone"，由 PlayerEnvironmentZoneService 每帧按
##   「玩家是否在矩形内」自行判定（传送 / 读档后位置已经变了也能立刻判定，不会漏一帧）。
##
## ★ 两类参数：
##   1) 环境速度乘数：
##      - 左右方向乘数作用于玩家**自己驱动出来**的水平速度（走路 / 跑 / 滑翔 / 冲刺的目标速度）；
##      - 上 / 下方向乘数作用于垂直方向的**实际位移速度**（只补「乘数带来的额外位移」，
##        不修改 velocity 本身，所以不会污染弹跳 / 击退等其它垂直速度来源）；
##      - 重力乘数 / 最大下落速度乘数直接作用于重力与下落速度上限。
##   2) 风场：给玩家叠加一个**独立的风速度**（有自己的加速度与速度上限，离开后按衰减加速度归零）。
##      玩家完全不操作（idle）时也会被吹动；风不参与玩家 velocity，
##      因此不会污染自身移动速度、弹跳速度、击退速度，也不会把 IDLE 状态改成 MOVE。
##
## 区域范围 = 自己的 CollisionShape2D（× 形状节点缩放），每次判定都按当前变换重算。
## ★ 形状缺失 / 类型不支持时直接 push_error 报错 —— 不做兜底尺寸猜测。

@export_category("环境速度乘数（上下左右）")
## 玩家「向右移动」时的速度乘数（1.0 = 不变，1.5 = 1.5 倍，0.5 = 减半）
@export var speed_mul_right: float = 1.0
## 玩家「向左移动」时的速度乘数
@export var speed_mul_left: float = 1.0
## 玩家「向上运动」（上升中）时的垂直位移速度乘数
@export var speed_mul_up: float = 1.0
## 玩家「向下运动」（下落中）时的垂直位移速度乘数
@export var speed_mul_down: float = 1.0
## 重力乘数（1.5 = 重力变大 1.5 倍，掉得更快）
@export var gravity_mul: float = 1.0
## 最大下落速度乘数（1.5 = 允许掉得更快）
@export var max_fall_mul: float = 1.0

@export_category("风场（无操作也会被吹动）")
## 是否启用风场
@export var wind_enabled: bool = true
## 风的最大速度（像素/秒）：方向与大小都由它决定，例如 (60, 0) = 向右吹、上限 60px/s
@export var wind_max_velocity: Vector2 = Vector2(60.0, 0.0)
## 风的加速度（像素/秒÷秒）：从 0 加速到最大风速所需时间 = 最大风速 / 加速度
@export var wind_acceleration: float = 120.0
## 离开风场（或风场关闭）后风速的衰减加速度（像素/秒÷秒）
@export var wind_deceleration: float = 240.0
## 地面上的风强度（0 = 地面不受风，1 = 与空中相同；想模拟地面摩擦更稳可以调小）
@export var wind_ground_scale: float = 0.7

## 子类实现：区域所属组 / 名称 / 表现强度与方向 ─────────────────
func _get_zone_group() -> String:
	return "environment_zone"

func _get_zone_label() -> String:
	return "EnvironmentZone"

## 表现用：只要启用了风场就有可视化
func _is_effect_enabled() -> bool:
	return wind_enabled and wind_max_velocity.length() > 0.0

## 基准强度（= 100% 时的风速），供可视化换算粒子数量比例
func _get_base_strength() -> float:
	return wind_max_velocity.length()

## 表现方向（效果变化为负时由基类自动翻转）
func _get_visual_direction() -> Vector2:
	if wind_max_velocity.length() <= 0.0:
		return Vector2.RIGHT
	return wind_max_velocity.normalized()

## 提供本区域对玩家的完整配置（供 PlayerEnvironmentZoneService 每帧读取）
func get_environment_config(player: Node) -> Dictionary:
	var influence: float = compute_influence(player)
	## 地面上的风可以单独缩放（默认与空中相同）
	var wind_scale: float = 1.0
	if player != null and player.is_on_floor():
		wind_scale = clampf(wind_ground_scale, 0.0, 1.0)
	return {
		"influence": influence,
		"speed_mul_right": speed_mul_right,
		"speed_mul_left": speed_mul_left,
		"speed_mul_up": speed_mul_up,
		"speed_mul_down": speed_mul_down,
		"gravity_mul": gravity_mul,
		"max_fall_mul": max_fall_mul,
		"wind_enabled": wind_enabled and wind_scale > 0.0,
		"wind_velocity": wind_max_velocity * wind_scale,
		"wind_acceleration": wind_acceleration * wind_scale,
		"wind_deceleration": wind_deceleration,
	}
