# Scripts/Tools/RoomLayoutViewer.gd
## 房间布局参考工具（只读版）
## 功能：显示所有房间的色块 + 尺寸标注，仅供视觉参考，不可编辑。
@tool
extends Node2D

const ROOMS_DIR := "res://Scenes/GameScenes/Rooms/"
const LAYOUT_DATA_PATH := "res://Assets/Configs/RoomLayoutData.tres"

const ROOM_COLORS := {
	"Room1": Color(0.4, 0.7, 1.0, 0.3),
	"Room2": Color(0.4, 1.0, 0.6, 0.3),
	"Room3": Color(1.0, 0.6, 0.4, 0.3),
	"Room4": Color(1.0, 0.9, 0.3, 0.3),
	"RoomDream10": Color(0.8, 0.4, 1.0, 0.3),
	"Room39": Color(0.6, 0.8, 1.0, 0.3),
	"Room61": Color(0.7, 0.7, 0.7, 0.3),
	"Room62": Color(0.4, 0.8, 0.8, 0.3),
	"Room63": Color(0.9, 0.5, 0.5, 0.3),
	"Room64": Color(0.5, 0.9, 0.5, 0.3),
	"Room65": Color(0.9, 0.7, 0.3, 0.3),
	"Room66": Color(0.6, 0.5, 0.9, 0.3),
	"Room67": Color(0.8, 0.6, 0.8, 0.3),
	"Room68": Color(0.3, 0.8, 0.7, 0.3),
	"Room69": Color(0.7, 0.3, 0.5, 0.3),
	"SnowMountain1": Color(0.5, 0.8, 0.9, 0.3),
	"SnowMountain2": Color(0.5, 0.9, 0.8, 0.3),
	"SnowMountain3": Color(0.5, 0.7, 1.0, 0.3),
	"SnowMountain4": Color(0.6, 0.9, 0.7, 0.3),
	"SnowMountain5": Color(0.5, 0.7, 1.0, 0.3),
	"SnowMountain6": Color(0.6, 0.9, 0.7, 0.3),
}

var _data: RoomLayoutData = null
var _room_sizes: Dictionary = {}
var _room_ids: Array[String] = []


func _ready():
	if not Engine.is_editor_hint():
		return
	_load_data()
	_scan_rooms()
	if _room_ids.is_empty():
		_show_error("未找到任何房间文件")
		return
	_render()


func _load_data() -> void:
	if ResourceLoader.exists(LAYOUT_DATA_PATH):
		var loaded = load(LAYOUT_DATA_PATH)
		if loaded is RoomLayoutData:
			_data = loaded
			return
	_data = RoomLayoutData.new()


func _scan_rooms() -> void:
	_room_ids.clear()
	_room_sizes.clear()
	_scan_dir(ROOMS_DIR)

func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			_scan_dir(full)
		elif entry.ends_with(".tscn"):
			var rid := entry.trim_suffix(".tscn")
			if not _room_ids.has(rid):
				_read_room(rid, full)
		entry = dir.get_next()
	dir.list_dir_end()

func _read_room(rid: String, scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		return
	var scene := load(scene_path) as PackedScene
	if scene == null:
		return
	var inst := scene.instantiate()
	if inst == null:
		return
	_room_ids.append(rid)
	var sz: Vector2 = _get_size(inst)
	if sz == Vector2.ZERO:
		sz = Vector2(3680, 2080)
	_room_sizes[rid] = sz
	inst.queue_free()

func _get_size(node: Node) -> Vector2:
	for c in node.get_children():
		if c is Node2D and c.has_method("get_actual_size"):
			var s: Vector2 = c.get_actual_size()
			if s.length_squared() > 0.0:
				return s
	for n in ["RoomBounds1", "RoomBounds", "room_bounds"]:
		var b := node.get_node_or_null(n)
		if b and b.has_method("get_actual_size"):
			var s: Vector2 = b.get_actual_size()
			if s.length_squared() > 0.0:
				return s
	return Vector2.ZERO

func _color_of(rid: String) -> Color:
	if ROOM_COLORS.has(rid):
		return ROOM_COLORS[rid]
	var h: float = hash(rid) % 360 / 360.0
	return Color.from_hsv(h, 0.5, 0.8, 0.3)


func _render() -> void:
	var wb: Rect2
	var first := true
	for rid in _room_ids:
		var offset: Vector2 = _data.get_room_offset(rid)
		var size: Vector2 = _room_sizes.get(rid, Vector2(3680, 2080)) as Vector2
		var b: Rect2 = Rect2(offset - size * 0.5, size)
		if first:
			wb = b
			first = false
		else:
			wb = wb.merge(b)
	if first:
		return
	wb = wb.grow(200)
	position = -wb.position
	_draw_grid(wb)
	for rid in _room_ids:
		var offset: Vector2 = _data.get_room_offset(rid)
		var size: Vector2 = _room_sizes.get(rid, Vector2(3680, 2080)) as Vector2
		var bounds: Rect2 = Rect2(offset - size * 0.5, size)
		_draw_room(rid, bounds)
	_draw_legend()

func _draw_grid(wb: Rect2) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.15, 1.0)
	bg.size = wb.size
	bg.position = wb.position
	add_child(bg)
	var gc := Color(0.3, 0.3, 0.3, 0.15)
	var st: float = 1000.0
	var sx: float = floor(wb.position.x / st) * st
	var sy: float = floor(wb.position.y / st) * st
	for x in range(sx, wb.end.x + st, st):
		var l := ColorRect.new()
		l.color = gc; l.size = Vector2(1, wb.size.y)
		l.position = Vector2(x, wb.position.y)
		add_child(l)
	for y in range(sy, wb.end.y + st, st):
		var l := ColorRect.new()
		l.color = gc; l.size = Vector2(wb.size.x, 1)
		l.position = Vector2(wb.position.x, y)
		add_child(l)

func _draw_room(rid: String, b: Rect2) -> void:
	var c := _color_of(rid)
	var r := ColorRect.new()
	r.color = c; r.size = b.size; r.position = b.position
	add_child(r)
	var border := ColorRect.new()
	border.color = Color(c.r, c.g, c.b, 0.8)
	border.size = b.size; border.position = b.position
	add_child(border)
	var lbl := Label.new()
	lbl.text = rid
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size = b.size; lbl.position = b.position
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	lbl.add_theme_font_size_override("font_size", 16)
	add_child(lbl)
	# 标注中心坐标
	var center := b.get_center()
	var clbl := Label.new()
	clbl.text = "(%d,%d)" % [center.x, center.y]
	clbl.position = center - Vector2(30, 8)
	clbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	clbl.add_theme_font_size_override("font_size", 10)
	add_child(clbl)

func _draw_legend() -> void:
	var ly := 20.0
	var lx := 20.0
	var t := Label.new()
	t.text = "房间布局参考（只读）"
	t.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	t.add_theme_font_size_override("font_size", 18)
	t.position = Vector2(lx, ly)
	add_child(t)
	ly += 30
	for rid in _room_ids:
		var c: Color = _color_of(rid)
		var sw: ColorRect = ColorRect.new()
		sw.color = c; sw.size = Vector2(16, 16)
		sw.position = Vector2(lx, ly)
		add_child(sw)
		var off: Vector2 = _data.get_room_offset(rid)
		var sz: Vector2 = _room_sizes.get(rid, Vector2(3680, 2080)) as Vector2
		var lbl := Label.new()
		lbl.text = "%s  offset=(%d,%d)  size=(%d,%d)" % [rid, off.x, off.y, sz.x, sz.y]
		lbl.position = Vector2(lx + 20, ly)
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
		lbl.add_theme_font_size_override("font_size", 12)
		add_child(lbl)
		ly += 22

func _show_error(msg: String) -> void:
	var lbl := Label.new()
	lbl.text = "⚠ " + msg
	lbl.add_theme_color_override("font_color", Color(1, 0.6, 0.2, 1))
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.position = Vector2(40, 40)
	add_child(lbl)
