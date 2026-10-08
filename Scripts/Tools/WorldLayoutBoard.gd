# Scripts/Tools/WorldLayoutBoard.gd
## 世界布局摆放面板（编辑器工具）
## 职责：把所有房间作为可拖动槽位摆放在同一个场景里，并把摆放结果记录为唯一权威布局数据
## （res://Assets/Configs/RoomLayoutData.tres），供 RoomManager 与地图系统共用。
##
## 使用流程：
##   ① 扫描房间边界  —— 读取每个房间场景内 room_bounds 的真实尺寸（房间场景本身不带位置）
##   ② 在视口中拖动各房间矩形，摆出相对位置（数据缺失/矩形重叠会高亮提示）
##   ③ 记录槽位位置到数据 —— 把槽位坐标写回 RoomLayoutData.tres
@tool
extends Node2D

## 槽位容器节点名
const ROOMS_ROOT_NAME := "Rooms"

## 打开场景时是否自动重算房间尺寸与地图画布
## （这两项都是派生数据，房间改过 room_bounds 尺寸后无需手工同步）
@export var auto_refresh_on_ready: bool = true

## 重算时是否连地图画布原点一起重算
## 若你手工微调过 RoomLayoutData.map_world_origin（让美术贴图对齐），把它关掉就不会被覆盖
## 注意：居中模式下（center_texture_on_world_origin = true）原点由纹理尺寸推导，通常无需手调。
@export var auto_refresh_map_origin: bool = true

## 布局数据资源（把 res://Assets/Configs/RoomLayoutData.tres 拖到这里）
## 不再硬编码路径：资源换了位置只要重新拖一下就行，保存也写回它自己的路径。
@export var layout_data: RoomLayoutData = null

## 是否允许在 2D 视口中直接拖动房间矩形
@export var enable_viewport_drag: bool = true

## 拖动时的吸附网格步长（像素，0 表示不吸附）
@export var drag_snap_step: int = 16

## 扫描房间边界并写入布局数据
@export_tool_button("① 扫描房间边界") var action_scan_rooms: Callable = scan_rooms
## 把布局数据中的位置套用到槽位（撤销未记录的拖动）
@export_tool_button("② 用数据重置槽位位置") var action_apply_data: Callable = apply_data_to_slots
## 把槽位当前位置写入布局数据并保存
@export_tool_button("③ 记录槽位位置到数据") var action_record_slots: Callable = record_slots_to_data
## 打印布局一致性校验报告
@export_tool_button("校验布局一致性") var action_validate: Callable = print_validation

## 布局数据资源引用
var _layout_data: RoomLayoutData = null

## 槽位容器
var _rooms_root: Node2D = null

## 当前被视为重叠的房间 ID 集合
var _overlapping_ids: Dictionary = {}

## 当前正在被拖动的槽位
var _dragging_slot: Node2D = null

## 拖动开始时鼠标相对槽位原点的偏移
var _drag_grab_offset: Vector2 = Vector2.ZERO

## 是否已排队一次槽位状态刷新（用于合并同一帧内的多次请求）
var _refresh_pending: bool = false

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_rooms_root = _ensure_rooms_root()
	_load_layout_data()
	if _layout_data == null:
		return
	if auto_refresh_on_ready:
		refresh_derived_data()
	_ensure_slots()
	apply_data_to_slots()
	refresh_slot_states()

## 重算派生数据：各房间真实尺寸 + 地图画布原点，并落盘
## 房间改了 room_bounds 尺寸、或新增/移动了房间，都只需重新打开本场景。
func refresh_derived_data() -> void:
	if _layout_data == null:
		return
	var report: Dictionary = RoomScanner.scan_all(_layout_data)
	# 贴图尺寸与画布原点都从「当前房间包围盒」推导（见 RoomLayoutData.sync_generated_canvas）
	if auto_refresh_map_origin:
		_layout_data.sync_generated_canvas()
	ResourceSaver.save(_layout_data)
	print(RoomScanner.format_report(report))
	print("地图纹理尺寸 = %s｜地图画布原点 = %s｜画布尺寸 = %s 像素（1 像素 = %d 世界像素）" % [
		str(_layout_data.map_texture_size),
		str(_layout_data.map_world_origin),
		str(_layout_data.get_map_canvas_size()),
		int(_layout_data.world_units_per_map_pixel),
	])
	if _layout_data.center_texture_on_world_origin:
		var required: Vector2i = _layout_data.get_required_texture_size_centered()
		print("居中模式：纹理中心 = 世界 (0,0)。至少要 %d × %d 像素才能盖住全部房间，当前 %d × %d → %s" % [
			required.x, required.y,
			_layout_data.map_texture_size.x, _layout_data.map_texture_size.y,
			"足够" if _layout_data.is_texture_size_sufficient() else "不足！超出部分的地图不会被显示"
		])
	else:
		print("（自动模式：如需与美术贴图对齐，可手改 RoomLayoutData.map_world_origin，并把本节点的 auto_refresh_map_origin 关掉）")
	queue_redraw()

## 取布局数据：直接用 Inspector 上拖进来的引用（不再硬编码路径）
func _load_layout_data() -> void:
	if layout_data == null:
		push_error("WorldLayoutBoard: 请把 Assets/Configs/RoomLayoutData.tres 拖到本节点的 layout_data 上")
		return
	_layout_data = layout_data

## 确保存在槽位容器
func _ensure_rooms_root() -> Node2D:
	var existing: Node = get_node_or_null(ROOMS_ROOT_NAME)
	if existing is Node2D:
		return existing
	var created := Node2D.new()
	created.name = ROOMS_ROOT_NAME
	add_child(created)
	_mark_owner(created)
	return created

## 为注册表中缺失的房间补建槽位
func _ensure_slots() -> void:
	var registry: Dictionary = RoomScanner.get_room_registry()
	var created_any: bool = false
	for room_id in registry.keys():
		if _find_slot(room_id) != null:
			continue
		_create_slot(room_id)
		created_any = true
	if created_any:
		mark_scene_unsaved()

## 新建一个房间槽位
func _create_slot(room_id: String) -> Node2D:
	var slot: Node2D = RoomLayoutSlot.new()
	slot.name = room_id
	slot.set("room_id", room_id)
	slot.position = _layout_data.get_room_offset(room_id) if _layout_data != null else Vector2.ZERO
	_rooms_root.add_child(slot)
	_mark_owner(slot)
	return slot

## 让新增节点随场景一起保存
func _mark_owner(node: Node) -> void:
	var edited_root: Node = get_tree().edited_scene_root if get_tree() != null else null
	node.owner = edited_root

## 按房间 ID 查找槽位（先按节点名，再按 room_id 导出值）
func _find_slot(room_id: String) -> Node2D:
	if _rooms_root == null:
		return null
	var by_name: Node = _rooms_root.get_node_or_null(room_id)
	if by_name is Node2D:
		return by_name
	for child in _rooms_root.get_children():
		if child is Node2D and str(child.get("room_id")) == room_id:
			return child
	return null

## 读取槽位代表的房间 ID（优先用导出值，回退到节点名）
func _slot_room_id(slot: Node2D) -> String:
	var exported: String = str(slot.get("room_id"))
	if exported != "":
		return exported
	return slot.name

## 扫描全部房间边界并写入布局数据
func scan_rooms() -> void:
	if _layout_data == null:
		push_error("WorldLayoutBoard: 布局数据未加载")
		return
	refresh_derived_data()
	_ensure_slots()
	refresh_slot_states()

## 把布局数据中的位置套用到槽位
func apply_data_to_slots() -> void:
	if _layout_data == null or _rooms_root == null:
		return
	for child in _rooms_root.get_children():
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		slot.position = _layout_data.get_room_offset(_slot_room_id(slot))
	refresh_slot_states()

## 记录槽位位置到数据并保存后，刷新显示
func record_slots_to_data() -> void:
	if _layout_data == null or _rooms_root == null:
		return
	for child in _rooms_root.get_children():
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		_layout_data.set_room_position(_slot_room_id(slot), slot.position)
	ResourceSaver.save(_layout_data)
	refresh_slot_states()
	queue_redraw()
	print("WorldLayoutBoard: 已记录 %d 个房间位置到 %s" % [_rooms_root.get_child_count(), str(_layout_data.resource_path)])

## 绘制地图画布范围（美术需要画的整图所对应的世界矩形）
func _draw() -> void:
	if _layout_data == null:
		return
	var canvas_size_px: Vector2 = _layout_data.get_map_canvas_size()
	if canvas_size_px.x <= 0.0 or canvas_size_px.y <= 0.0:
		return
	var ratio: float = maxf(_layout_data.world_units_per_map_pixel, 1.0)
	var canvas_rect := Rect2(_layout_data.map_world_origin, canvas_size_px * ratio)
	var sufficient: bool = _layout_data.is_texture_size_sufficient()
	# 纹理不足时用红色警示（超出纹理范围的房间在地图上会直接消失）
	var canvas_color := Color(1.0, 0.85, 0.3, 0.75) if sufficient else Color(1.0, 0.3, 0.3, 0.9)
	draw_rect(canvas_rect, canvas_color, false, 24.0)
	var font: Font = ThemeDB.fallback_font
	var label := "地图纹理：%d × %d 像素" % [int(canvas_size_px.x), int(canvas_size_px.y)]
	draw_string(font, canvas_rect.position + Vector2(24.0, -40.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 96, canvas_color)
	# 居中模式下额外画出「覆盖全部房间所需的最小纹理范围」，方便美术判断还要画多大
	if _layout_data.center_texture_on_world_origin:
		var required: Vector2i = _layout_data.get_required_texture_size_centered()
		var required_rect := Rect2(-Vector2(required) * 0.5 * ratio, Vector2(required) * ratio)
		draw_rect(required_rect, Color(0.4, 1.0, 0.6, 0.8), false, 12.0)
		draw_string(font, required_rect.position + Vector2(24.0, required_rect.size.y + 96.0),
			"至少需要：%d × %d 像素" % [required.x, required.y],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 72, Color(0.5, 1.0, 0.7, 0.95))

## 请求一次延迟的槽位状态刷新（同一帧内多次请求只会执行一次）
func request_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	_flush_refresh.call_deferred()

## 执行被合并的刷新请求
func _flush_refresh() -> void:
	_refresh_pending = false
	refresh_slot_states()

## 重新计算并同步所有槽位的显示状态（矩形、缺数据、重叠）
func refresh_slot_states() -> void:
	if _rooms_root == null or _layout_data == null:
		return
	_overlapping_ids = _compute_overlapping_ids()
	for child in _rooms_root.get_children():
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		var room_id: String = _slot_room_id(slot)
		slot.set("bounds_local", _layout_data.get_room_bounds_local(room_id))
		slot.set("is_data_missing", not (_layout_data.has_room(room_id) and _layout_data.has_room_bounds(room_id)))
		slot.set("is_overlapping", _overlapping_ids.has(room_id))
		slot.set("door_links", _collect_door_links(room_id))
		slot.call("refresh")


## 把一个房间的门整理成槽位绘图需要的形式：
## pos = 门在房间本地坐标系里的位置；target_pos = 目标房间槽位的位置（用于画对齐引线）
func _collect_door_links(room_id: String) -> Array:
	var links: Array = []
	if _layout_data == null:
		return links
	var doors_raw: Variant = _layout_data.room_doors.get(room_id, [])
	if not (doors_raw is Array):
		return links
	for door: Variant in doors_raw:
		var entry: Dictionary = door
		var target_room: String = str(entry.get("target", ""))
		var target_slot: Node2D = _find_slot(target_room)
		links.append({
			"pos": entry.get("position", Vector2.ZERO),
			"door_id": str(entry.get("door_id", "")),
			"target_room": target_room,
			"target_pos": target_slot.position if target_slot != null else Vector2.ZERO,
			"has_target": target_slot != null,
		})
	return links

## 找出世界矩形互相重叠的房间（尺寸为空的房间不参与判定）
func _compute_overlapping_ids() -> Dictionary:
	var result: Dictionary = {}
	if _rooms_root == null or _layout_data == null:
		return result
	var entries: Array = []
	for child in _rooms_root.get_children():
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		var room_id: String = _slot_room_id(slot)
		var rect: Rect2 = Rect2(slot.position + _layout_data.get_room_bounds_local(room_id).position,
			_layout_data.get_room_bounds_local(room_id).size)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		entries.append({"id": room_id, "rect": rect})
	for i in range(entries.size()):
		for j in range(i + 1, entries.size()):
			var a: Dictionary = entries[i]
			var b: Dictionary = entries[j]
			if (a["rect"] as Rect2).intersects(b["rect"] as Rect2, false):
				result[a["id"]] = true
				result[b["id"]] = true
	return result

## 打印布局一致性校验报告
func print_validation() -> void:
	if _layout_data == null:
		push_error("WorldLayoutBoard: 布局数据未加载")
		return
	var registry: Dictionary = RoomScanner.get_room_registry()
	var missing_position: Array = []
	var missing_bounds: Array = []
	var no_slot: Array = []
	for room_id in registry.keys():
		if not _layout_data.has_room(room_id):
			missing_position.append(room_id)
		if not _layout_data.has_room_bounds(room_id):
			missing_bounds.append(room_id)
		if _find_slot(room_id) == null:
			no_slot.append(room_id)
	var slot_only: Array = []
	if _rooms_root != null:
		for child in _rooms_root.get_children():
			if child is Node2D:
				var rid: String = _slot_room_id(child)
				if not registry.has(rid):
					slot_only.append(rid)
	_overlapping_ids = _compute_overlapping_ids()
	var lines: Array[String] = []
	lines.append("=== WorldLayout 布局校验 ===")
	lines.append("登记房间数：%d，槽位数：%d" % [registry.size(), _rooms_root.get_child_count() if _rooms_root != null else 0])
	lines.append("缺少位置偏移：%s" % ("无" if missing_position.is_empty() else ", ".join(missing_position)))
	lines.append("缺少房间尺寸：%s" % ("无" if missing_bounds.is_empty() else ", ".join(missing_bounds)))
	lines.append("缺少槽位：%s" % ("无" if no_slot.is_empty() else ", ".join(no_slot)))
	lines.append("槽位无对应房间登记：%s" % ("无" if slot_only.is_empty() else ", ".join(slot_only)))
	lines.append("世界矩形重叠：%s" % ("无" if _overlapping_ids.is_empty() else ", ".join(_overlapping_ids.keys())))
	print("\n".join(lines))

## 通知编辑器当前场景有未保存改动
func mark_scene_unsaved() -> void:
	if not Engine.is_editor_hint():
		return
	EditorInterface.mark_scene_as_unsaved()

## 视口内直接拖动房间矩形（仅编辑器；可用 enable_viewport_drag 关闭）
func _input(event: InputEvent) -> void:
	if not Engine.is_editor_hint() or not enable_viewport_drag or _rooms_root == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag_at_mouse()
		elif _dragging_slot != null:
			_end_drag()
	elif event is InputEventMouseMotion and _dragging_slot != null:
		_update_drag()

## 鼠标位置命中某个房间矩形时开始拖动
func _begin_drag_at_mouse() -> void:
	var mouse: Vector2 = get_global_mouse_position()
	var slot: Node2D = _find_slot_at(mouse)
	if slot == null:
		return
	_dragging_slot = slot
	_drag_grab_offset = slot.position - mouse
	slot.set("is_being_dragged", true)
	slot.call("refresh")
	get_viewport().set_input_as_handled()

## 拖动过程中更新槽位位置
func _update_drag() -> void:
	if _dragging_slot == null:
		return
	var target: Vector2 = get_global_mouse_position() + _drag_grab_offset
	if drag_snap_step > 0:
		var step: float = float(drag_snap_step)
		target = Vector2(roundf(target.x / step) * step, roundf(target.y / step) * step)
	_dragging_slot.position = target
	refresh_slot_states()
	get_viewport().set_input_as_handled()

## 结束拖动并标记场景为未保存
func _end_drag() -> void:
	if _dragging_slot != null:
		_dragging_slot.set("is_being_dragged", false)
		_dragging_slot.call("refresh")
		_dragging_slot = null
	mark_scene_unsaved()
	get_viewport().set_input_as_handled()

## 查找世界矩形包含指定世界坐标的槽位（后添加的槽位优先）
func _find_slot_at(world_pos: Vector2) -> Node2D:
	if _rooms_root == null or _layout_data == null:
		return null
	var children: Array = _rooms_root.get_children()
	for i in range(children.size() - 1, -1, -1):
		var child: Node = children[i]
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		var local_rect: Rect2 = _layout_data.get_room_bounds_local(_slot_room_id(slot))
		if local_rect.size.x <= 0.0 or local_rect.size.y <= 0.0:
			continue
		if Rect2(slot.position + local_rect.position, local_rect.size).has_point(world_pos):
			return slot
	return null
