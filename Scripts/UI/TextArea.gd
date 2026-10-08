# Scripts/UI/TextArea.gd
## 房间边界标记
##
## 真实用途（不能删）：
##   * `get_actual_size()` / `get_global_rect()` 被 `Scripts/GameScenes/Room.gd` 使用，
##     用于设置 RoomTrigger 的碰撞尺寸与相机限制（房间的"大小"就是由它定义的）。
##   * `RoomScanner` 依赖 `get_actual_size()` 扫描每个房间的真实尺寸。
##   * `WorldLayoutBoard` 依赖 `room_bounds_rects` 绘制摆放外框。
##
## 可视化部分（DebugCollisionShape / DebugPolygon）只在编辑器里创建，运行时完全不创建。
## ★ 注意：编辑器里看到的框其实是两层叠在一起 ——
##   * DebugCollisionShape（CollisionShape2D）：**编辑器自己会画碰撞体轮廓**，颜色不受 debug_color 控制，
##     所以 debug_color 透明度调成 0 时你仍然能看到一个框；
##   * DebugPolygon（Polygon2D）：半透明填充，颜色完全由 debug_color 控制。
@tool
extends Node2D
class_name TextArea

## 区域基础大小（可在编辑器直接拖动调整）
## 注意：最终大小 = size * scale
@export var size: Vector2 = Vector2(320, 320) : set = set_size

## 编辑器中的参考填充色（改这个会立即刷新）
@export var debug_color: Color = Color(0.0, 0.824, 0.588, 0.235) : set = set_debug_color

## 运行时是否显示该标记（默认 false，仅编辑器可见）
@export var show_in_game: bool = false

## 编辑器可视化节点（运行时保持为 null）
var collision_shape: CollisionShape2D
var polygon: Polygon2D

func _ready():
	if Engine.is_editor_hint():
		_refresh_visualization()
	else:
		# 运行时不需要任何可视化节点，只保留几何查询能力
		set_visible(show_in_game)

## size 变更时只更新已有可视化节点的几何，不重建节点（避免拖动数值时闪动）
func set_size(new_size: Vector2):
	size = new_size
	_refresh_visualization()

## debug_color 变更时立即刷新填充色
func set_debug_color(new_color: Color):
	debug_color = new_color
	if is_instance_valid(polygon):
		polygon.color = new_color

## 确保编辑器可视化节点存在，并与当前 size / debug_color 同步
func _refresh_visualization() -> void:
	if not Engine.is_editor_hint():
		return
	if is_instance_valid(polygon):
		_apply_size_to_visualization()
		polygon.color = debug_color
		return
	# 矩形框（编辑器可视化，不参与任何运行时逻辑）
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = size
	collision_shape = CollisionShape2D.new()
	collision_shape.name = "DebugCollisionShape"
	collision_shape.shape = rect_shape
	add_child(collision_shape)
	# 半透明填充
	polygon = Polygon2D.new()
	polygon.name = "DebugPolygon"
	polygon.color = debug_color
	add_child(polygon)
	_apply_size_to_visualization()

## 把当前 size 应用到已有可视化节点
func _apply_size_to_visualization() -> void:
	if is_instance_valid(collision_shape) and collision_shape.shape is RectangleShape2D:
		(collision_shape.shape as RectangleShape2D).size = size
	if is_instance_valid(polygon):
		polygon.polygon = _build_rect_points()

## 以节点自身为中心的矩形四个角点
func _build_rect_points() -> PackedVector2Array:
	var half := size * 0.5
	return PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])

## 获取实际大小（考虑 scale）
func get_actual_size() -> Vector2:
	return size * scale

## 获取实际区域（全局坐标；节点自身位置就是矩形中心）
func get_global_rect() -> Rect2:
	var actual_size: Vector2 = get_actual_size()
	return Rect2(global_position - actual_size * 0.5, actual_size)
