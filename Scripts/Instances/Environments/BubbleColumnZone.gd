# ★ 不加 @tool（理由见 EnvironmentZoneBase 顶部）：保证场景里的参数可自由修改
extends "res://Scripts/Instances/Environments/EnvironmentZoneBase.gd"
class_name BubbleColumnZone

## 水下的「上升气泡柱」（《我的世界》式）：玩家进到里面就可以回氧（气泡立刻回满）。
##
## ★ 复用环境区域基类，所以自动具备：区域范围（CollisionShape2D）、效果变化（时间循环 / 开关控制）、
##   可视化表现状态 —— 视觉直接复用 EnvironmentZoneVisual（条纹向上飘，把它当成"气泡"看即可）。
## ★ 与其它区域不同：气泡柱不改变玩家速度/重力，只影响「水下呼吸」。

@export_category("气泡柱")
## 气泡柱的视觉强度（像素/秒；越大条纹飘得越快）
@export var visual_speed: float = 120.0

## 子类实现：区域所属组 / 名称 / 表现强度与方向
func _get_zone_group() -> String:
	return "bubble_column_zone"

func _get_zone_label() -> String:
	return "BubbleColumnZone"

## 表现用：气泡柱永远有上升条纹
func _is_effect_enabled() -> bool:
	return true

## 基准强度（供可视化换算粒子数量比例）
func _get_base_strength() -> float:
	return visual_speed

## 表现方向恒为向上（效果变化为负时由基类翻转为向下）
func _get_visual_direction() -> Vector2:
	return Vector2.UP

## 某个世界坐标是否落在气泡柱内（供 PlayerBreathService 每帧查询）
func contains_position(world_position: Vector2) -> bool:
	var rect: Rect2 = get_zone_world_rect()
	return rect.has_area() and rect.has_point(world_position)
