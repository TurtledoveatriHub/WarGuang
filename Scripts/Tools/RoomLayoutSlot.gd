# Scripts/Tools/RoomLayoutSlot.gd
## 房间布局槽位（编辑器工具）
## 只在 Scenes/Tools/WorldLayout.tscn 中作为房间的可拖动代表使用，不参与游戏运行时。
## 槽位自身的 position 就是该房间根节点在世界空间中的原点。
@tool
extends Node2D

## 该槽位代表的房间 ID（需与房间场景的 room_id 一致）
@export var room_id: String = ""

## 房间边界的本地矩形（由 WorldLayoutBoard 从 RoomLayoutData 同步）
var bounds_local: Rect2 = Rect2()

## 是否缺少布局数据（无位置偏移或未扫描到边界）
var is_data_missing: bool = true

## 是否与其它房间的世界矩形重叠
var is_overlapping: bool = false

## 是否正在被拖动
var is_being_dragged: bool = false

## 拖动中的状态颜色
const COLOR_DRAGGING := Color(0.45, 1.0, 0.55)
## 数据缺失的状态颜色
const COLOR_MISSING := Color(1.0, 0.78, 0.25)
## 矩形重叠的状态颜色
const COLOR_OVERLAP := Color(1.0, 0.35, 0.35)
## 正常状态颜色
const COLOR_NORMAL := Color(0.42, 0.72, 1.0)
## 原点十字的半径
const ORIGIN_CROSS_RADIUS := 40.0

func _ready() -> void:
	# 编辑器拖动槽位时实时刷新重叠状态
	set_notify_transform(true)

func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSFORM_CHANGED:
		return
	if not Engine.is_editor_hint():
		return
	# 向上查找摆放面板（本节点挂在 Rooms 容器下，父节点不是面板）
	var node: Node = get_parent()
	while node != null:
		if node.has_method("request_refresh"):
			node.call("request_refresh")
			return
		node = node.get_parent()

## 同步布局数据后刷新绘制
func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	var state_color: Color = COLOR_NORMAL
	if is_being_dragged:
		state_color = COLOR_DRAGGING
	elif is_data_missing:
		state_color = COLOR_MISSING
	elif is_overlapping:
		state_color = COLOR_OVERLAP
	if bounds_local.size.x <= 0.0 or bounds_local.size.y <= 0.0:
		_draw_origin_marker(state_color)
		return
	# 房间矩形填充与描边
	draw_rect(bounds_local, Color(state_color.r, state_color.g, state_color.b, 0.14), true)
	draw_rect(bounds_local, Color(state_color.r, state_color.g, state_color.b, 0.85), false, 6.0)
	_draw_origin_marker(state_color)
	_draw_labels(state_color)

## 绘制房间根节点原点十字（槽位 position 即房间根原点）
func _draw_origin_marker(state_color: Color) -> void:
	var cross_color := Color(1.0, 1.0, 1.0, 0.9)
	draw_line(Vector2(-ORIGIN_CROSS_RADIUS, 0.0), Vector2(ORIGIN_CROSS_RADIUS, 0.0), cross_color, 4.0)
	draw_line(Vector2(0.0, -ORIGIN_CROSS_RADIUS), Vector2(0.0, ORIGIN_CROSS_RADIUS), cross_color, 4.0)
	draw_circle(Vector2.ZERO, 10.0, state_color)

## 绘制房间名称、尺寸与原点坐标标注
func _draw_labels(state_color: Color) -> void:
	var font: Font = ThemeDB.fallback_font
	var title_size: int = int(clampf(bounds_local.size.y * 0.035, 28.0, 96.0))
	var info_size: int = int(clampf(bounds_local.size.y * 0.026, 22.0, 72.0))
	var text_left: float = bounds_local.position.x + title_size
	var text_top: float = bounds_local.position.y + title_size * 2.0
	var title: String = room_id
	if is_data_missing:
		title += "   [缺少布局数据]"
	elif is_overlapping:
		title += "   [与其它房间重叠]"
	draw_string(font, Vector2(text_left, text_top), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, title_size, Color(1.0, 1.0, 1.0, 0.95))
	var info := "size=%d×%d   origin=(%d, %d)" % [
		int(bounds_local.size.x), int(bounds_local.size.y), int(position.x), int(position.y)
	]
	draw_string(font, Vector2(text_left, text_top + info_size * 1.6), info, HORIZONTAL_ALIGNMENT_LEFT, -1.0, info_size, Color(1.0, 1.0, 1.0, 0.7))
