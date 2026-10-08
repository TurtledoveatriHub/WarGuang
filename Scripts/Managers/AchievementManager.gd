extends Node
## 成就系统（全局 autoload）——**解锁记录与存档完全解耦**。
##
## 关键设计：解锁记录写在 `user://achievements.cfg`，**不在存档文件里**。
## 所以删掉某个存档、甚至三个存档全删，已经解锁的成就依然在。
##
## 业务代码只需要两个调用：
##     AchievementManager.unlock(&"first_step")        # 触发解锁（幂等，重复调用无害）
##     AchievementManager.is_unlocked(&"first_step")   # 查询
## 成就界面（AchievementScene）通过 get_achievements() 读取全部定义。

## 某个成就刚刚被解锁（同一次游戏里只会发一次）。
signal achievement_unlocked(id: StringName)

const SAVE_PATH: String = "user://achievements.cfg"
const SAVE_SECTION: String = "unlocked"

## 成就总目录。autoload 是纯脚本节点（没有 Inspector），所以直接在这里指定；
## 要换一份目录就改这一行路径。
@export var catalog: AchievementCatalog = preload("res://Assets/Configs/AchievementCatalog.tres")

## id(String) -> 解锁时间戳（Unix 秒）。不在表里 = 未解锁。
var _unlocked: Dictionary = {}


func _ready() -> void:
	load_data()
	_connect_ability_signals()


# ════════════════════════════════════════════════════════════
# 本项目的成就触发点
# ════════════════════════════════════════════════════════════
# 能力类成就直接挂 EventBus 的能力解锁信号：不用关心「谁解锁、从哪条路径解锁」
# （NPC 对话、道具、调试命令都会走到同一个信号上）。
# 注：Global._notify_ability_unlocks() 会在读档时补发这些信号 —— 那正是我们要的：
#     存档里已有的能力，对应成就应该补上；unlock() 幂等，不会重复弹提示。
const ABILITY_ACHIEVEMENTS: Dictionary = {
	"dash_unlocked": &"ACH2",
	"double_jump_unlocked": &"ACH1",
	"wall_grip_unlocked": &"ACH3",
	"glide_unlocked": &"ACH4",
	"vertical_dash_unlocked": &"ACH5",
	"black_dash_unlocked": &"ACH6",
	"super_dash_unlocked": &"ACH7",
}


func _connect_ability_signals() -> void:
	var bus: Node = get_node_or_null("/root/EventBus")
	if bus == null:
		return
	for signal_name in ABILITY_ACHIEVEMENTS.keys():
		if bus.has_signal(signal_name):
			bus.connect(signal_name, _on_ability_unlocked.bind(ABILITY_ACHIEVEMENTS[signal_name]))


func _on_ability_unlocked(achievement_id: StringName) -> void:
	unlock(achievement_id)


# ════════════════════════════════════════════════════════════
# 业务接口
# ════════════════════════════════════════════════════════════

## 解锁一个成就。已解锁 / id 为空时返回 false。
## **幂等**：放在每帧都会跑的地方也不会重复写盘、不会重复发信号。
func unlock(id: StringName) -> bool:
	if id == &"" or is_unlocked(id):
		return false
	_unlocked[String(id)] = int(Time.get_unix_time_from_system())
	save_data()
	achievement_unlocked.emit(id)
	return true


func is_unlocked(id: StringName) -> bool:
	return _unlocked.has(String(id))


## 解锁时刻（Unix 秒）。未解锁返回 0。
func get_unlocked_time(id: StringName) -> int:
	return int(_unlocked.get(String(id), 0))


## 全部成就定义，**按界面展示顺序**返回：
##   已解锁的排在前面（按解锁时间从早到晚），未解锁的排后面（按目录里的顺序）。
## 所以刚解锁的成就一定会出现在第一页，不会埋在后面几页里找不到。
func get_achievements() -> Array[AchievementData]:
	var unlocked_list: Array[AchievementData] = []
	var locked_list: Array[AchievementData] = []
	if catalog != null:
		for entry in catalog.achievements:
			if not entry is AchievementData:
				continue
			var data: AchievementData = entry as AchievementData
			if is_unlocked(data.id):
				unlocked_list.append(data)
			else:
				locked_list.append(data)
	unlocked_list.sort_custom(_is_earlier_unlock)
	var result: Array[AchievementData] = []
	result.append_array(unlocked_list)
	result.append_array(locked_list)
	return result


func _is_earlier_unlock(a: AchievementData, b: AchievementData) -> bool:
	return get_unlocked_time(a.id) < get_unlocked_time(b.id)


func get_total_count() -> int:
	return get_achievements().size()


func get_unlocked_count() -> int:
	var count: int = 0
	for data in get_achievements():
		if is_unlocked(data.id):
			count += 1
	return count


# ════════════════════════════════════════════════════════════
# 持久化（独立文件，与存档无关）
# ════════════════════════════════════════════════════════════

func load_data() -> void:
	_unlocked.clear()
	var config: ConfigFile = ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	# 文件存在但还没有 unlocked 段（首次运行 / 旧版本文件）时直接返回，
	# 否则 get_section_keys() 会报 "Cannot get keys from nonexistent section"。
	if not config.has_section(SAVE_SECTION):
		return
	for key in config.get_section_keys(SAVE_SECTION):
		_unlocked[key] = int(config.get_value(SAVE_SECTION, key, 0))


func save_data() -> void:
	var config: ConfigFile = ConfigFile.new()
	for key in _unlocked.keys():
		config.set_value(SAVE_SECTION, String(key), _unlocked[key])
	config.save(SAVE_PATH)


## 清空全部成就记录（仅供调试；正式流程里不要调用）。
func reset_all() -> void:
	_unlocked.clear()
	save_data()
