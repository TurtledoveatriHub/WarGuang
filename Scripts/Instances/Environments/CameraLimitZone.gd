extends Area2D
class_name CameraLimitZone

## 临时相机范围限制区
## 玩家进入：把相机限制在**本区域矩形**内；玩家离开：解除限制。
##
## ★ 实现方式（和上一版的区别，也是修掉「拉进去又被拉回 / 垂直抽搐」的关键）：
##   不改写 Camera2D / PhantomCamera 的 limit_*（房间限制、门传送的临时解限也在写同一批属性，
##   多方互相覆盖就必然抖动），而是把玩家的**跟随锚点**夹进区域矩形。
##   相机中心就是跟随锚点，所以夹住锚点 = 相机被限制在区域内；
##   而且锚点每帧重算，天然平滑、不会和别的系统抢，也自动包含「相机不超出区域」的语义。
##
## 区域范围 = 自己的 CollisionShape2D（× 形状节点缩放）。
## ★ 形状缺失 / 类型不支持时直接 push_error 报错 —— 不做兜底尺寸猜测。

## 碰撞形状节点（= 区域范围）
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

## 当前登记的玩家
var _player: Node = null
## 形状是否可用（不可用时报错并且完全不生效）
var _shape_valid: bool = true

## 初始化：连接玩家进出信号并预校验形状
func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)
	_shape_valid = get_zone_world_rect() != Rect2()

## 区域的世界矩形；形状缺失 / 类型不支持时 push_error 并返回空矩形
func get_zone_world_rect() -> Rect2:
	if collision_shape == null:
		push_error("CameraLimitZone: 缺少 CollisionShape2D（区域范围），节点=" + str(get_path()))
		return Rect2()
	var shape: Shape2D = collision_shape.shape
	if shape == null:
		push_error("CameraLimitZone: CollisionShape2D 没设 shape（区域范围），节点=" + str(get_path()))
		return Rect2()
	var scale_factor: Vector2 = Vector2(maxf(absf(collision_shape.global_scale.x), 0.001), maxf(absf(collision_shape.global_scale.y), 0.001))
	var size: Vector2 = Vector2.ZERO
	if shape is RectangleShape2D:
		size = (shape as RectangleShape2D).size * scale_factor
	elif shape is CircleShape2D:
		var radius: float = (shape as CircleShape2D).radius * maxf(scale_factor.x, scale_factor.y)
		size = Vector2(radius * 2.0, radius * 2.0)
	else:
		push_error("CameraLimitZone: 区域范围只支持 RectangleShape2D / CircleShape2D，当前=" + shape.get_class() + "，节点=" + str(get_path()))
		return Rect2()
	var center: Vector2 = collision_shape.global_position
	return Rect2(center - size * 0.5, size)

## 玩家进入 → 到（玩家的）相机控制器登记本区域
func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player") or not _shape_valid:
		return
	_player = body
	if body.has_method("register_camera_limit_zone"):
		body.register_camera_limit_zone(self)

## 玩家离开 → 注销
func _on_body_exited(body: Node) -> void:
	if body != _player:
		return
	if body.has_method("unregister_camera_limit_zone"):
		body.unregister_camera_limit_zone(self)
	_player = null
