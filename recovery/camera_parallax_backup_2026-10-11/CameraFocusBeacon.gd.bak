extends Area2D
class_name CameraFocusBeacon

## 相机焦点抢夺信标
## 语义（和你的理解一致）：
##   * **CollisionShape2D = 抢夺范围**：玩家进入这个范围，抢夺才会生效；
##   * **FocusTarget = 抢夺焦点**：相机被拉向这个点（没配/找不到时退化为自身位置）；
##   * steal_strength / falloff_power / max_focus_offset 决定「拉多用力」。
## 范围半径 = 形状半径 × 形状节点缩放（不再有 capture_radius 这种会和形状打架的参数）。
## ★ 没有 CollisionShape2D、没设 shape、或形状类型不支持时直接 push_error 报错 —— 不做任何兜底猜测。

@export_category("Focus Capture")
## 焦点目标节点路径；找不到时使用自身位置
@export var focus_target_path: NodePath = NodePath("FocusTarget")
## 抢夺强度，越大越容易压过普通跟随
@export var steal_strength: float = 0.65
## 距离衰减曲线指数，越高越偏向「靠近范围中心」才产生明显抢夺
@export var falloff_power: float = 1.5
## 单个抢夺区允许影响相机的最大偏移量
@export var max_focus_offset: float = 220.0

## 碰撞形状节点（= 抢夺范围）
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

## 初始化：连接玩家进出信号
func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)

## 解析抢夺焦点（找不到就用自身位置）
func _resolve_focus_target() -> Node2D:
	if focus_target_path != NodePath(""):
		var target: Node = get_node_or_null(focus_target_path)
		if target is Node2D:
			return target
	return self

## 抢夺范围半径（世界单位）= 形状半径 × 形状节点缩放。
## 形状缺失/类型不支持时 push_error 并返回 -1。
func get_capture_radius() -> float:
	if collision_shape == null:
		push_error("CameraFocusBeacon: 缺少 CollisionShape2D（抢夺范围），节点=" + str(get_path()))
		return -1.0
	var shape: Shape2D = collision_shape.shape
	if shape == null:
		push_error("CameraFocusBeacon: CollisionShape2D 没设 shape（抢夺范围），节点=" + str(get_path()))
		return -1.0
	var scale_factor: float = maxf(maxf(absf(collision_shape.global_scale.x), absf(collision_shape.global_scale.y)), 0.001)
	if shape is RectangleShape2D:
		return maxf((shape as RectangleShape2D).size.length() * 0.5 * scale_factor, 1.0)
	if shape is CircleShape2D:
		return maxf((shape as CircleShape2D).radius * scale_factor, 1.0)
	push_error("CameraFocusBeacon: 抢夺范围只支持 RectangleShape2D / CircleShape2D，当前=" + shape.get_class() + "，节点=" + str(get_path()))
	return -1.0

## 给 PlayerCameraController 采样：玩家在范围内返回 weight/offset，否则 valid=false
func get_focus_capture_sample_for_player(player: Node2D) -> Dictionary:
	var target: Node2D = _resolve_focus_target()
	if target == null or player == null:
		return {"valid": false}
	var radius: float = get_capture_radius()
	if radius <= 0.0:
		return {"valid": false}
	var distance: float = global_position.distance_to(player.global_position)
	if distance > radius:
		return {"valid": false}
	# 越靠近范围中心，抢夺越强；到边缘衰减为 0
	var normalized: float = clampf(distance / radius, 0.0, 1.0)
	var weight: float = maxf(steal_strength, 0.0) * pow(1.0 - normalized, maxf(falloff_power, 0.01))
	if weight <= 0.001:
		return {"valid": false}
	var offset: Vector2 = (target.global_position - player.global_position) * weight
	if max_focus_offset > 0.0 and offset.length() > max_focus_offset:
		offset = offset.normalized() * max_focus_offset
	return {
		"valid": true,
		"weight": weight,
		"offset": offset,
		"target": target.global_position
	}

## 玩家进入抢夺范围 → 注册到玩家相机控制器
func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.has_method("register_camera_focus_zone"):
		body.register_camera_focus_zone(self)

## 玩家离开抢夺范围 → 注销
func _on_body_exited(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	if body.has_method("unregister_camera_focus_zone"):
		body.unregister_camera_focus_zone(self)
