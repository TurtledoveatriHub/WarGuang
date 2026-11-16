extends Area2D
class_name CameraLimitZone

## 临时相机范围限制区
## 玩家在区域内：相机限制框收敛到**本区域矩形**（所以玩家在区域内时，镜头不会露出区域外的画面）。
## 玩家离开：限制框直接收敛回房间限制 —— 过渡是否平滑由下面的加速度与速度上限控制，
## 不靠“锁住/保持限制”来回避问题。
##
## ★ 生效方式：
##   本脚本**完全不碰** Camera2D / PhantomCamera 的 limit_*，也**不依赖物理进出信号**；
##   它在 _ready 里加入组 "camera_limit_zone"，由 PlayerCameraController 每帧按「玩家是否在矩形内」
##   自行判定（传送 / 读档后位置已经变了也能立刻判定，不会漏一帧），
##   相机限制框的写入与收敛也由控制器单一负责。
##
## 区域范围 = 自己的 CollisionShape2D（× 形状节点缩放），在 _ready 时缓存一次。
## ★ 形状缺失 / 类型不支持时直接 push_error 报错 —— 不做兜底尺寸猜测。

@export_category("限制区")
## 进/出区死区（像素）：玩家要闯进区域边缘这么多才算「进入」；
## 离开时也要走出边缘这么多才算「离开」。边缘上反复蹭不会让相机抽搯。
@export var dead_zone: float = 48.0
## 限制框收敛的最大速度（像素/秒）；0 = 不设上限（完全由加速度决定快慢）
@export var limit_slide_speed: float = 480.0
## 限制框的加速度（像素/秒÷秒）：加速与减速都由它控制。
## 越大收敛越快（越“硬”），越小越缓。限制框目标反复切换时，速度也是按这个加速度连续变化的。
@export var limit_slide_accel: float = 240.0
## 隐藏房间模式：本区域是房间里“挖掉”的一块。
## 玩家在区域**外面**时：相机只能待在玩家所在的那一侧（不会拍到区域内部）；
## 玩家进入区域后：解除限制（可以正常看到区域内部）。
@export var hidden_room_mode: bool = false

## 碰撞形状节点（= 区域范围）
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

## 本区域的局部矩形（相对自身；_ready 时算一次并校验形状）
var _rect_local: Rect2 = Rect2()

## 初始化：登记到限制区组，并校验形状 + 缓存局部矩形
func _ready() -> void:
	add_to_group("camera_limit_zone")
	_rect_local = _compute_zone_local_rect()

## 区域的世界矩形（每帧按当前全局变换换算，父节点移动也不会失效）
func get_zone_world_rect() -> Rect2:
	if not _rect_local.has_area():
		return Rect2()
	var p1: Vector2 = to_global(_rect_local.position)
	var p2: Vector2 = to_global(_rect_local.end)
	return Rect2(
		Vector2(minf(p1.x, p2.x), minf(p1.y, p2.y)),
		Vector2(absf(p2.x - p1.x), absf(p2.y - p1.y))
	)

## 计算区域的局部矩形；形状缺失 / 类型不支持时 push_error 并返回空矩形
func _compute_zone_local_rect() -> Rect2:
	if collision_shape == null:
		push_error("CameraLimitZone: 缺少 CollisionShape2D（区域范围），节点=" + str(get_path()))
		return Rect2()
	var shape: Shape2D = collision_shape.shape
	if shape == null:
		push_error("CameraLimitZone: CollisionShape2D 没设 shape（区域范围），节点=" + str(get_path()))
		return Rect2()
	var scale_factor: Vector2 = Vector2(maxf(absf(collision_shape.scale.x), 0.001), maxf(absf(collision_shape.scale.y), 0.001))
	var size: Vector2 = Vector2.ZERO
	if shape is RectangleShape2D:
		size = (shape as RectangleShape2D).size * scale_factor
	elif shape is CircleShape2D:
		var radius: float = (shape as CircleShape2D).radius * maxf(scale_factor.x, scale_factor.y)
		size = Vector2(radius * 2.0, radius * 2.0)
	else:
		push_error("CameraLimitZone: 区域范围只支持 RectangleShape2D / CircleShape2D，当前=" + shape.get_class() + "，节点=" + str(get_path()))
		return Rect2()
	var center: Vector2 = collision_shape.position
	return Rect2(center - size * 0.5, size)

## 提供本区域的完整参数给相机控制器（区域矩形 + 进出死区 + 收敛参数 + 模式）
func get_limit_zone_config() -> Dictionary:
	return {
		"rect": get_zone_world_rect(),
		"dead_zone": dead_zone,
		"limit_slide_speed": limit_slide_speed,
		"limit_slide_accel": limit_slide_accel,
		"hidden_room_mode": hidden_room_mode,
	}
