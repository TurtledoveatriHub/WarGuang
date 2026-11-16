# ★ 不加 @tool（理由见 EnvironmentZoneBase 顶部）：保证场景里的参数可自由修改
extends "res://Scripts/Instances/EnvironmentZoneBase.gd"
class_name UpdraftZone

## 上升气流区（滑翔上升气流，参考空洞骑士丝之歌里大黄蜂的滑翔手感）
##
## 玩家在区域矩形内、且处于滑翔状态时被**持续向上推**：
## 上升速度有自己的加速度与上限，离开区域 / 退出滑翔后按衰减加速度归零。
## 上升速度作为独立速度参与位移（不修改 player.velocity），所以不会污染其它垂直速度来源。
##
## ★ 生效方式与 EnvironmentZone 完全一致：
##   _ready 加入组 "updraft_zone"，由 PlayerEnvironmentZoneService 每帧判定，不依赖进出信号。
## 区域范围 = 自己的 CollisionShape2D（× 形状节点缩放），每次判定都按当前变换重算。

@export_category("上升气流")
## 是否只在滑翔状态生效（关闭 = 任何空中状态都会被往上推）
@export var glide_only: bool = true
## 上升加速度（像素/秒÷秒）
@export var updraft_acceleration: float = 600.0
## 上升速度上限（像素/秒）
@export var updraft_max_speed: float = 360.0
## 离开气流 / 退出滑翔后上升速度的衰减加速度（像素/秒÷秒）
@export var updraft_deceleration: float = 240.0

## 子类实现：区域所属组 / 名称 / 表现强度与方向 ─────────────────
func _get_zone_group() -> String:
	return "updraft_zone"

func _get_zone_label() -> String:
	return "UpdraftZone"

## 上升气流只要求处于滑翔状态（glide_only 关闭时任何空中状态都生效）
func _is_player_eligible(player: Node) -> bool:
	if not glide_only:
		return true
	return player.current_state == player.PlayerState.GLIDE

## 表现用：设定了上升速度上限就有可视化
func _is_effect_enabled() -> bool:
	return updraft_max_speed > 0.0

## 基准强度（= 100% 时的上升速度上限），供可视化换算粒子数量比例
func _get_base_strength() -> float:
	return updraft_max_speed

## 表现方向恒为向上（效果变化为负时由基类翻转为向下）
func _get_visual_direction() -> Vector2:
	return Vector2.UP

## 提供本区域对玩家的完整配置（供 PlayerEnvironmentZoneService 每帧读取）
## influence 可为负（效果变化反向）→ 上升会变成向下推
func get_updraft_config(player: Node) -> Dictionary:
	var influence: float = compute_influence(player)
	return {
		"active": not is_zero_approx(influence),
		"influence": influence,
		"acceleration": updraft_acceleration,
		"max_speed": updraft_max_speed,
		"deceleration": updraft_deceleration,
	}

## ★ 表现状态**不在这里覆写**：基类 get_visual_state() 会把「效果变化」系数乘进强度、
##   并在系数为负时把方向翻成向下。之前这里返回的是常量（方向恒向上、强度恒等于上限），
##   结果不管怎么改效果参数，粒子都不跟着变（用户实测“上升气流粒子不受效果参数影响”）。
