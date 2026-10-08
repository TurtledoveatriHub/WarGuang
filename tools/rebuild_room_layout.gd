extends SceneTree

## 房间布局数据恢复脚本（无头运行）
## 用途：当 Assets/Configs/RoomLayoutData.tres 被误删/清空时，从 Scenes/Tools/WorldLayout.tscn
## 的槽位摆放与各房间场景的 room_bounds 重新生成完整数据。
##
## 运行方式：
##   Godot --headless --path <项目根> --script res://tools/rebuild_room_layout.gd

## 布局数据资源路径
const LAYOUT_DATA_PATH := "res://Assets/Configs/RoomLayoutData.tres"
## 摆放场景路径
const WORLD_LAYOUT_SCENE := "res://Scenes/Tools/WorldLayout.tscn"
## 槽位容器节点名
const ROOMS_ROOT_NAME := "Rooms"

func _initialize() -> void:
	var scanner_script: GDScript = load("res://Scripts/Tools/RoomScanner.gd")
	var data: RoomLayoutData = load(LAYOUT_DATA_PATH)
	if data == null:
		print("恢复失败：无法加载 ", LAYOUT_DATA_PATH)
		quit()
		return

	# 第一步：重新扫描全部房间边界
	var report: Dictionary = scanner_script.scan_all(data)
	print(scanner_script.format_report(report))

	# 第二步：从摆放场景读取每个房间的位置
	var packed: PackedScene = load(WORLD_LAYOUT_SCENE)
	if packed == null:
		print("恢复失败：无法加载 ", WORLD_LAYOUT_SCENE)
		quit()
		return
	var layout_root: Node = packed.instantiate()
	var rooms_root: Node = layout_root.get_node_or_null(ROOMS_ROOT_NAME)
	if rooms_root == null:
		print("恢复失败：摆放场景中找不到节点 ", ROOMS_ROOT_NAME)
		layout_root.free()
		quit()
		return
	var restored: Array[String] = []
	for child in rooms_root.get_children():
		if not (child is Node2D):
			continue
		var slot: Node2D = child
		var room_id: String = str(slot.get("room_id"))
		if room_id == "":
			room_id = slot.name
		data.set_room_position(room_id, slot.position)
		restored.append(room_id)
	layout_root.free()
	restored.sort()

	# 第三步：重算地图画布原点（美术作画基准）
	data.refresh_map_world_origin()

	var save_error: int = ResourceSaver.save(data, LAYOUT_DATA_PATH)
	print("已恢复房间位置 %d 个：" % restored.size())
	print(restored)
	print("room_positions 条目数 = ", (data.get("room_positions") as Dictionary).size())
	print("room_bounds_rects 条目数 = ", (data.get("room_bounds_rects") as Dictionary).size())
	print("地图画布原点 = ", data.map_world_origin)
	print("地图画布尺寸（贴图像素）= ", data.get_map_canvas_size())
	print("世界包围盒 = ", data.get_world_bounds())
	print("保存结果 = ", save_error)
	quit()
