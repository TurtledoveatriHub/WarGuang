extends SceneTree

## 临时校验脚本：验证房间扫描器与一致性校验器的实际输出（运行后可删除）

func _initialize() -> void:
	var scanner_script: GDScript = load("res://Scripts/Tools/RoomScanner.gd")
	var check_script: GDScript = load("res://Scripts/Tools/RoomConsistencyCheck.gd")
	var data: Resource = load("res://Assets/Configs/RoomLayoutData.tres")

	print("=========== 注册表 ===========")
	var registry: Dictionary = scanner_script.get_room_registry()
	print("房间数 = ", registry.size())
	var ids: Array = registry.keys()
	ids.sort()
	print(ids)

	print("=========== 扫描边界 ===========")
	var report: Dictionary = scanner_script.scan_all(data)
	print(scanner_script.format_report(report))
	var bounds: Dictionary = data.get("room_bounds_rects")
	print("已写入 room_bounds_rects 数量 = ", bounds.size())
	for room_id in ids:
		print("  ", room_id, " -> ", bounds.get(room_id, "<缺失>"))
	# 把扫描结果持久化，避免首次打开摆放场景时再扫一遍
	var save_error: int = ResourceSaver.save(data, "res://Assets/Configs/RoomLayoutData.tres")
	print("保存 RoomLayoutData.tres 结果 = ", save_error)

	print("=========== 一致性报告 ===========")
	print(check_script.build_report(data))

	print("=========== WorldLayout 场景校验 ===========")
	var packed: PackedScene = load("res://Scenes/Tools/WorldLayout.tscn")
	if packed == null:
		print("WorldLayout.tscn 加载失败")
	else:
		var instance: Node = packed.instantiate()
		var rooms_root: Node = instance.get_node_or_null("Rooms")
		print("WorldLayout 槽位数 = ", rooms_root.get_child_count() if rooms_root != null else -1)
		instance.free()

	quit()
