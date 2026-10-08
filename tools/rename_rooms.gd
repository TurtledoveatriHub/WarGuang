extends SceneTree

## 房间批量改名工具（无头运行）
##
## 一次改完改名需要同步的全部位置，避免手工漏改：
##   1. 房间场景内的 room_id 导出值、根节点名
##   2. 其它房间场景里对本房间的引用（Door.target_room_id / adjacent_rooms /
##      DynamicCheckpoint.belongs_to_room / GroundParallaxController.target_room_id）
##   3. ScenePaths.ROOM_PATHS 的键与路径
##   4. RoomLayoutData.tres 中的 room_positions / room_bounds_rects / map_region_rects 键
##   5. 房间场景文件本身改名
##
## 使用方法：
##   ① 在下面的 RENAME_MAP 里填「旧ID → 新ID」
##   ② APPLY_CHANGES 保持 false 先跑一次（dry-run），核对报告
##   ③ 确认无误后把 APPLY_CHANGES 改成 true 再跑一次
##
## 运行：
##   Godot --headless --path <项目根> --script res://tools/rename_rooms.gd

## 改名映射表：旧 ID → 新 ID
const RENAME_MAP := {
	# 示例：
	# "Room61": "GrassLand7",
}

## 是否真正写入（false = 只做 dry-run 检查并打印报告）
const APPLY_CHANGES := false

## 权威布局数据路径
const ROOM_LAYOUT_PATH := "res://Assets/Configs/RoomLayoutData.tres"
## 房间路径注册表脚本路径
const SCENE_PATHS_SCRIPT_PATH := "res://Scripts/Managers/ScenePaths.gd"
## 需要做文本替换的根目录
const TEXT_SCAN_DIRS: Array[String] = ["res://Scripts", "res://Scenes"]
## 参与文本替换的扩展名
const TEXT_EXTENSIONS: Array[String] = [".gd", ".tscn"]
## 文本替换时跳过的文件（由资源接口单独处理）
const TEXT_SKIP_FILES: Array[String] = [ROOM_LAYOUT_PATH]

func _initialize() -> void:
	print("========== 房间批量改名工具 ==========")
	print("模式：", "写入" if APPLY_CHANGES else "dry-run（只检查，不写入）")
	_run_self_test()

	if RENAME_MAP.is_empty():
		print("RENAME_MAP 为空，没有需要改名的房间。")
		print("请在脚本顶部的 RENAME_MAP 里填写「旧ID → 新ID」后重跑。")
		quit()
		return

	var registry: Dictionary = _load_registry()
	if registry.is_empty():
		print("无法读取 ", SCENE_PATHS_SCRIPT_PATH)
		quit()
		return

	var errors: Array[String] = _validate(RENAME_MAP, registry)
	if not errors.is_empty():
		print("【校验失败，未做任何修改】")
		for message in errors:
			print("  ✗ ", message)
		quit()
		return
	print("【校验通过】共 %d 个房间待改名" % RENAME_MAP.size())

	var text_files: Array[String] = _collect_text_files()

	# ---- 文本替换 ----
	var total_hits: int = 0
	var changed_files: Array[String] = []
	for path in text_files:
		var text: String = _read_text(path)
		if text == "":
			continue
		var hits: int = _count_hits(text, RENAME_MAP)
		if hits <= 0:
			continue
		total_hits += hits
		changed_files.append("%s（%d 处）" % [path, hits])
		if APPLY_CHANGES:
			_write_text(path, _apply_renames_to_text(text, RENAME_MAP))
	print("文本替换：%d 个文件、共 %d 处" % [changed_files.size(), total_hits])
	for entry in changed_files:
		print("    ", entry)

	# ---- 布局数据键改名 ----
	var layout_summary: Array[String] = _rename_layout_keys(RENAME_MAP, APPLY_CHANGES)
	print("布局数据键：")
	for entry in layout_summary:
		print("    ", entry)

	# ---- 场景文件改名 ----
	print("场景文件改名：")
	for old_id in RENAME_MAP.keys():
		var new_id: String = str(RENAME_MAP[old_id])
		var from_path: String = str(registry[old_id])
		var to_path: String = from_path.get_base_dir().path_join(new_id + ".tscn")
		print("    %s → %s" % [from_path, to_path])
		if APPLY_CHANGES:
			var rename_error: int = DirAccess.rename_absolute(from_path, to_path)
			print("        结果码 = ", rename_error)

	if not APPLY_CHANGES:
		print("【dry-run 结束，未做任何修改】确认无误后把 APPLY_CHANGES 改成 true 再跑一次。")
		quit()
		return

	# ---- 写入后复检残留 ----
	print("【已写入】复检残留引用：")
	var leftovers: int = 0
	for path in _collect_text_files():
		var text: String = _read_text(path)
		if text == "":
			continue
		var hits: int = _count_hits(text, RENAME_MAP)
		if hits > 0:
			leftovers += hits
			print("    ! 仍残留 %d 处：%s" % [hits, path])
	if leftovers == 0:
		print("    ✓ 未发现残留")
	else:
		print("    ！共 %d 处残留，请手工检查（可能是 RoomLayoutData 或其它非 .gd/.tscn 文件）" % leftovers)
	print("改名完成。建议随后打开 WorldLayout.tscn 补/删槽位，并跑一次一致性校验。")
	quit()

## 自检：确认替换逻辑正确
## 重点：A→B 且 B→C 时，文本里的 A 只能变成 B，不能被级联成 C
func _run_self_test() -> void:
	var sample := """[node name="Room61" type="Node2D"]
room_id = "Room61"
adjacent_rooms = Array[String](["Room62", "Room39"])
target_room_id = "Room61"
path = "res://Scenes/GameScenes/Rooms/Room61.tscn"
"""
	var map := {"Room61": "GrassLand7", "GrassLand7": "GrassLandX"}
	var result: String = _apply_renames_to_text(sample, map)
	var ok: bool = not result.contains("Room61") \
		and not result.contains("GrassLandX") \
		and result.contains("GrassLand7.tscn") \
		and result.count("GrassLand7") == 4
	print("自检（链式映射不级联）= ", "通过" if ok else "失败")
	if not ok:
		print(result)

## 读取房间注册表
func _load_registry() -> Dictionary:
	var paths_script: GDScript = load(SCENE_PATHS_SCRIPT_PATH)
	if paths_script == null:
		return {}
	return paths_script.get_script_constant_map().get("ROOM_PATHS", {})

## 校验映射表是否可安全执行
func _validate(rename_map: Dictionary, registry: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for old_id in rename_map.keys():
		var new_id: String = str(rename_map[old_id])
		if old_id == new_id:
			errors.append("%s：新旧 ID 相同" % old_id)
			continue
		if not registry.has(old_id):
			errors.append("%s：不在 ROOM_PATHS 中，找不到对应场景" % old_id)
			continue
		if registry.has(new_id):
			errors.append("%s → %s：新 ID 已被 ROOM_PATHS 占用" % [old_id, new_id])
			continue
		var from_path: String = str(registry[old_id])
		if not FileAccess.file_exists(from_path):
			errors.append("%s：场景文件不存在 %s" % [old_id, from_path])
			continue
		var to_path: String = from_path.get_base_dir().path_join(new_id + ".tscn")
		if FileAccess.file_exists(to_path):
			errors.append("%s → %s：目标文件已存在 %s" % [old_id, new_id, to_path])
	return errors

## 递归收集需要做文本替换的文件
func _collect_text_files() -> Array[String]:
	var result: Array[String] = []
	var pending: Array[String] = TEXT_SCAN_DIRS.duplicate()
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir: DirAccess = DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while entry != "":
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				if entry != "." and entry != "..":
					pending.append(full)
			else:
				var extension: String = full.get_extension()
				if ("." + extension) in TEXT_EXTENSIONS and not (full in TEXT_SKIP_FILES):
					result.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	result.sort()
	return result

## 统计一段文本中与映射表相关的出现次数
func _count_hits(text: String, rename_map: Dictionary) -> int:
	var hits: int = 0
	for old_id in rename_map.keys():
		hits += text.count("\"" + str(old_id) + "\"")
		hits += text.count(str(old_id) + ".tscn")
	return hits

## 对文本执行两阶段替换（避免 A→B、B→C 链式误替换）
func _apply_renames_to_text(text: String, rename_map: Dictionary) -> String:
	var old_ids: Array = rename_map.keys()
	# 第一阶段：旧 ID → 占位符
	for index in range(old_ids.size()):
		var old_id: String = str(old_ids[index])
		var placeholder: String = _placeholder(index)
		text = text.replace("\"" + old_id + "\"", "\"" + placeholder + "\"")
		text = text.replace(old_id + ".tscn", placeholder + ".tscn")
	# 第二阶段：占位符 → 新 ID
	for index in range(old_ids.size()):
		text = text.replace(_placeholder(index), str(rename_map[old_ids[index]]))
	return text

## 生成替换占位符
func _placeholder(index: int) -> String:
	return "__ROOM_RENAME_SLOT_%d__" % index

## 改名布局数据中的房间键
func _rename_layout_keys(rename_map: Dictionary, apply_changes: bool) -> Array[String]:
	var summary: Array[String] = []
	var data: RoomLayoutData = load(ROOM_LAYOUT_PATH)
	if data == null:
		summary.append("无法加载 " + ROOM_LAYOUT_PATH)
		return summary
	var renamed: int = 0
	for field in ["room_positions", "room_bounds_rects", "map_region_rects"]:
		var table: Dictionary = data.get(field)
		for old_id in rename_map.keys():
			if not table.has(old_id):
				continue
			table[str(rename_map[old_id])] = table[old_id]
			table.erase(old_id)
			renamed += 1
			summary.append("%s：%s → %s" % [field, old_id, rename_map[old_id]])
	if renamed == 0:
		summary.append("没有需要改的键")
	if apply_changes:
		var save_error: int = ResourceSaver.save(data, ROOM_LAYOUT_PATH)
		summary.append("保存结果码 = %d" % save_error)
	return summary

## 读取文本文件
func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text

## 写入文本文件
func _write_text(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入 " + path)
		return
	file.store_string(text)
	file.close()
