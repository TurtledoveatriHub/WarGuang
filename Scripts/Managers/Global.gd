extends Node

const SAVE_VERSION: int = 1

## 无尽模式积分榜只记录历史前三
const ENDLESS_RECORD_LIMIT: int = 3

## 信号定义
signal player_health_changed(new_health)
signal player_max_health_changed(new_max_health)
signal coins_changed(new_amount)
signal coins_changing(old_amount, new_amount, duration)  # 钱币变化动画信号
## 开关存档状态变化（存档加载后通知场景内已有开关刷新）
signal switch_states_changed()

## 玩家数据
var player_max_health: int = 3
var player_current_health: int = 3
var player_coins: int = 100  # 玩家钱币数量

## 能力解锁状态
var unlocked_abilities: Dictionary = {
	"dash": false,
	"double_jump": false, 
	"glide": false,
	"black_dash": false,
	"wall_grip": false,
	"super_dash": false,
	"backstep": false,
	"vertical_dash": false,
	"map": false
}

# 击败的Boss记录
var defeated_bosses: Array = []

# 已收集的道具记录
var collected_items: Array = []

# 可破坏石墙摧毁记录（当前存档）- 从存档数据中读取/保存
var destructible_walls_destroyed: Array = []

# 已被永久触发的“隐藏房间/隐藏背景”记录（元素为 region_id，形如 room_id::层名 或自定义 save_id）
# 仅 permanent_hide=true 的 HiddenRegionFade 在完成淡出后登记，随存档读写。
var hidden_rooms_activated: Array = []

# 机关开关持久化状态（switch_id -> bool），随存档读写
var switch_states: Dictionary = {}

## 疯子挑战状态记录

# 第一阶段挑战状态记录
var maniac_challenge_completed: bool = false
var maniac_last_challenge_failed: bool = false

# 第二阶段挑战状态记录
var maniac_stage2_challenge_completed: bool = false
var maniac_stage2_last_challenge_failed: bool = false

# 第三阶段挑战状态记录
var maniac_stage3_challenge_completed: bool = false
var maniac_stage3_last_challenge_failed: bool = false

# 第四阶段挑战状态记录
var maniac_stage4_challenge_completed: bool = false
var maniac_stage4_last_challenge_failed: bool = false

# 第五阶段挑战状态记录
var maniac_stage5_challenge_completed: bool = false
var maniac_stage5_last_challenge_failed: bool = false

# 第六阶段挑战状态记录
var maniac_stage6_challenge_completed: bool = false
var maniac_stage6_last_challenge_failed: bool = false

# 第七阶段（无尽模式）挑战状态记录（无尽模式不会通关，只记录上次是否失败）
var maniac_stage7_last_challenge_failed: bool = false

# 竞速挑战最佳时间：key = 阶段序号字符串（"1"~"5"），value = 秒数 float
var race_best_times: Dictionary = {}

# 竞速最佳成绩的达成日期：key = 阶段序号字符串，value = "年.月.日" 文本
var race_best_time_dates: Dictionary = {}

# 竞速已通关记录：key = 阶段序号字符串，value = true（与「最佳时间」分开存，避免只有刷新纪录才算通关）
var race_stage_cleared: Dictionary = {}

# 无尽模式积分榜：历史前三，元素为 {"score": int, "date": String}，按积分从高到低
var endless_score_records: Array = []

# 存档点数据
var save_point_position: Vector2 = Vector2.ZERO  # 静态存档点位置
var last_save_point: Dictionary = {"position": Vector2(0, 0), "scene_path": "", "save_point_id": ""}
var last_checkpoint_position: Vector2 = Vector2.ZERO  # 最新触碰的检查点位置（动态或静态）
var last_checkpoint_type: String = "static"  # "dynamic" 或 "static"

func _ready():
	add_to_group("global")
	save_point_position = get_save_point_position()
	last_checkpoint_position = get_save_point_position()
	last_checkpoint_type = "static"
	_apply_saved_display_fit()
	_apply_saved_effect_level()
	_apply_saved_locale()
	if get_tree() != null:
		get_tree().node_added.connect(_on_tree_node_added)

# ======================= 画面适配（多分辨率） =======================
## 画面填充方式。
## 背景：工程里是 stretch/mode="viewport" + scale_mode="integer"（像素完美）。
## 但手机分辨率（如 2400x1080）不是 1280x720 的整数倍时，整数倍会被向下取整成 1，
## 于是 720p 视口 1:1 贴在屏幕正中 —— 这就是“手机上画面只占一小块”的原因。
## 所以手机端应切到“等比放大适配”。
enum DisplayFit {
	DEFAULT,       ## 工程默认：viewport + integer + keep（像素完美，非整数倍分辨率会有黑边）
	SCALE_TO_FIT,  ## 等比放大适配：viewport + fractional + keep（保持比例铺满，推荐手机）
	STRETCH_FILL,  ## 完全拉伸填满：viewport + fractional + ignore（无黑边，但比例不同会变形）
}

const DISPLAY_FIT_CONFIG_PATH: String = "user://display_settings.cfg"

## 当前生效的画面填充方式（启动时从 user://display_settings.cfg 读取）。
var display_fit_mode: int = DisplayFit.DEFAULT

## 应用画面填充方式。save_to_disk = true 时写入 user:// 配置，下次启动自动生效。
func apply_display_fit(mode: int, save_to_disk: bool = true) -> void:
	display_fit_mode = clampi(mode, DisplayFit.DEFAULT, DisplayFit.STRETCH_FILL)
	var root_window: Window = get_tree().root if get_tree() != null else null
	if root_window != null:
		# 三种模式都用 viewport 拉伸：本项目是像素风 2D，必须由引擎统一缩放根视口。
		root_window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		match display_fit_mode:
			DisplayFit.DEFAULT:
				root_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
				root_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER
			DisplayFit.SCALE_TO_FIT:
				root_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
				root_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
			DisplayFit.STRETCH_FILL:
				root_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
				root_window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	if save_to_disk:
		_save_display_fit_setting()

## 启动时读取并应用上次保存的画面填充方式。
func _apply_saved_display_fit() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(DISPLAY_FIT_CONFIG_PATH) == OK:
		display_fit_mode = int(config.get_value("display", "fit_mode", DisplayFit.DEFAULT))
	apply_display_fit(display_fit_mode, false)

func _save_display_fit_setting() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.load(DISPLAY_FIT_CONFIG_PATH)  # 先读再写：同文件还存着特效等级，直接 save 会把那段冲掉
	config.set_value("display", "fit_mode", display_fit_mode)
	config.save(DISPLAY_FIT_CONFIG_PATH)


# ======================= 特效等级 =======================
## 特效等级：影响粒子数量、2D 点光呼吸与帧率上限。
## 具体的分级含义见 EFFECT_PARTICLE_RATIO 与 apply_effect_level() 内的注释。
enum EffectLevel {
	LOW,     ## 低：粒子 35%、不开 2D 点光呼吸、帧率上限 60（手机上降发热）、水面关焦散/泡沫/波光
	MEDIUM,  ## 中：与旧版本表现一致（粒子 100%、点光呼吸开、帧率不额外封顶）、水面开基础焦散
	HIGH,    ## 高：粒子 150%（UI 场景粒子、雪地下雪等），水面焦散/泡沫/波光全开
	ULTRA,   ## 超高：粒子 200%，水面涟漪槽位与焦散拉满（仅建议高配设备）
}

## 各等级对应的粒子数量倍率。
const EFFECT_PARTICLE_RATIO: Dictionary = {
	EffectLevel.LOW: 0.35,
	EffectLevel.MEDIUM: 1.0,
	EffectLevel.HIGH: 1.5,
	EffectLevel.ULTRA: 2.0,
}

## 特效等级变化时发出，供各系统订阅（例：LightingManager 决定是否开点光呼吸）。
signal effect_level_changed(level: int)

## 当前特效等级（启动时从 user://display_settings.cfg 读取）。
var effect_level: int = EffectLevel.MEDIUM

## 应用特效等级。save_to_disk = true 时写入 user:// 配置，下次启动自动生效。
func apply_effect_level(level: int, save_to_disk: bool = true) -> void:
	effect_level = clampi(level, EffectLevel.LOW, EffectLevel.ULTRA)
	# 低特效档在手机上封 60 帧，减少发热与随之而来的热节流掉帧；中/高不额外封顶（跟随 vsync）。
	Engine.max_fps = 60 if effect_level == EffectLevel.LOW else 0
	_apply_particle_ratio_to_tree()
	effect_level_changed.emit(effect_level)
	if save_to_disk:
		_save_effect_level_setting()

## 启动时读取并应用上次保存的特效等级。
func _apply_saved_effect_level() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(DISPLAY_FIT_CONFIG_PATH) == OK:
		effect_level = int(config.get_value("effects", "level", EffectLevel.MEDIUM))
	apply_effect_level(effect_level, false)

func _save_effect_level_setting() -> void:
	var config: ConfigFile = ConfigFile.new()
	config.load(DISPLAY_FIT_CONFIG_PATH)
	config.set_value("effects", "level", effect_level)
	config.save(DISPLAY_FIT_CONFIG_PATH)

## 新节点进树时按当前等级套用：房间/UI 都是之后才加载的，必须动态覆盖。
func _on_tree_node_added(node: Node) -> void:
	if node is GPUParticles2D or node is CPUParticles2D:
		_apply_single_particle(node)

## 把粒子数量按当前等级套用到整棵树（UI 场景与房间的粒子都在 /root 下）。
func _apply_particle_ratio_to_tree() -> void:
	if get_tree() == null:
		return
	_apply_particle_ratio(get_tree().root)

func _apply_particle_ratio(node: Node) -> void:
	if node is GPUParticles2D or node is CPUParticles2D:
		_apply_single_particle(node)
	for child in node.get_children():
		_apply_particle_ratio(child)

## 单个粒子节点：首次套用时把原始 amount 记进 meta，之后只做倍率换算，反复切等级也不会累乘。
func _apply_single_particle(node: Node) -> void:
	var base_amount: int = int(node.get_meta("fx_base_amount", node.get("amount")))
	node.set_meta("fx_base_amount", base_amount)
	var ratio: float = float(EFFECT_PARTICLE_RATIO.get(effect_level, 1.0))
	node.set("amount", maxi(1, int(round(float(base_amount) * ratio))))


# ======================= 语言 =======================
## 支持的语言（与 Assets/Configs/Translations/ui_text.csv 的列对应）。
const SUPPORTED_LOCALES: PackedStringArray = ["zh_CN", "en", "ja"]

## 当前语言，启动时从 user://display_settings.cfg 读取。
var locale_code: String = "zh_CN"

## 虚拟摇杆“斜向”标志：由 MobileTouchHUD 每帧写入。
## 为 true 时（摇杆处于斜向区、既非横向优先也非纵向优先），冲刺判定优先取左右方向。
var joystick_diagonal_horizontal_bias: bool = false

## 切换语言并持久化。
## 文本替换完全由 Godot 内置自动翻译完成：ui_text.csv 里 key = 中文原文，
## 配合 project.godot 的 internationalization/rendering/root_node_auto_translate，
## 切换后所有 Control 的 text 会自动换成对应语言（数字等无译文的内容保持原样）。
func apply_locale(code: String, save_to_disk: bool = true) -> void:
	if not SUPPORTED_LOCALES.has(code):
		return
	locale_code = code
	TranslationServer.set_locale(code)
	if save_to_disk:
		var config: ConfigFile = ConfigFile.new()
		config.load(DISPLAY_FIT_CONFIG_PATH)  # 先读再写，保留同文件里的其它段
		config.set_value("locale", "code", locale_code)
		config.save(DISPLAY_FIT_CONFIG_PATH)

func _apply_saved_locale() -> void:
	var config: ConfigFile = ConfigFile.new()
	if config.load(DISPLAY_FIT_CONFIG_PATH) == OK:
		locale_code = str(config.get_value("locale", "code", locale_code))
	apply_locale(locale_code, false)

# 当前存档槽
var current_save_slot: int = -1

# 启动阶段待执行的过场序列标识。
var pending_boot_cinematic_id: StringName = &""

# 启动阶段过场携带的上下文参数。
var pending_boot_cinematic_payload: Dictionary = {}

# 一次性演出触发标记（写入存档）。
var played_cinematic_flags: Dictionary = {}

# 游戏时长（秒），只统计实际游玩时间
var total_play_time_seconds: int = 0
var _play_time_session_start_ms: int = -1

var last_save_room: String = "GrassLand1"  # 最后存档的房间

# 初始化新游戏（创建新存档时调用）
func initialize_new_game():
	print("Global: 初始化新游戏")
	# 重置所有存档相关数据
	player_max_health = 3
	player_current_health = 3
	player_coins = 0
	last_save_room = "GrassLand1"
	total_play_time_seconds = 0
	_play_time_session_start_ms = -1
	played_cinematic_flags = {}
	unlocked_abilities = {
		"dash": false,
		"double_jump": false,
		"glide": false,
		"black_dash": false,
		"wall_grip": false,
		"super_dash": false,
		"backstep": false,
		"vertical_dash": false,
		"map": false
	}
	defeated_bosses = []
	collected_items = []
	destructible_walls_destroyed = []  
	
	maniac_challenge_completed = false
	maniac_last_challenge_failed = false
	maniac_stage2_challenge_completed = false
	maniac_stage2_last_challenge_failed = false
	maniac_stage3_challenge_completed = false
	maniac_stage3_last_challenge_failed = false
	maniac_stage4_challenge_completed = false
	maniac_stage4_last_challenge_failed = false
	maniac_stage5_challenge_completed = false
	maniac_stage5_last_challenge_failed = false
	maniac_stage6_challenge_completed = false
	maniac_stage6_last_challenge_failed = false
	maniac_stage7_last_challenge_failed = false
	
	# 清空竞速最佳时间（每个存档独立）
	race_best_times = {}
	race_best_time_dates = {}
	race_stage_cleared = {}
	# 清空无尽模式积分榜（每个存档独立）
	endless_score_records = []
	
	last_save_point = {"position": Vector2(0, 0), "scene_path": "", "save_point_id": ""}
	save_point_position = Vector2.ZERO
	last_checkpoint_position = Vector2.ZERO
	last_checkpoint_type = "static"
	hidden_rooms_activated = []
	
	# 清空地图探索状态（已绘制 / 待绘制房间）
	if MapManager and MapManager.has_method("reset_state"):
		MapManager.reset_state()
	
	# 清空传送阵激活记录。
	# ★ TeleportManager 是 autoload，activated 会跨「回标题 → 开新存档」保留下来；
	#   不在这里重置的话，上一个存档激活过的传送阵会直接带进新存档（面板按钮直接亮着）。
	#   清空 _teleports 注册表也是安全的：每个房间的 TeleportPoint 会在自己的 _ready 里重新注册。
	if TeleportManager and TeleportManager.has_method("reset"):
		TeleportManager.reset()
	
	var task_manager = get_node_or_null("/root/TaskManager")
	if task_manager:
		task_manager.npc_interactions.clear()
		task_manager.tasks_completed.clear()
		task_manager.special_dialogues_shown.clear()

func request_boot_cinematic(sequence_id: StringName, payload: Dictionary = {}) -> void:
	pending_boot_cinematic_id = sequence_id
	pending_boot_cinematic_payload = payload.duplicate(true)

func peek_boot_cinematic_request() -> Dictionary:
	if pending_boot_cinematic_id == &"":
		return {}
	return {
		"id": pending_boot_cinematic_id,
		"payload": pending_boot_cinematic_payload.duplicate(true)
	}

func consume_boot_cinematic_request() -> Dictionary:
	if pending_boot_cinematic_id == &"":
		return {}
	var request := {
		"id": pending_boot_cinematic_id,
		"payload": pending_boot_cinematic_payload.duplicate(true)
	}
	pending_boot_cinematic_id = &""
	pending_boot_cinematic_payload = {}
	return request

func clear_boot_cinematic_request() -> void:
	pending_boot_cinematic_id = &""
	pending_boot_cinematic_payload = {}

## 记录一个开关的持久状态（供 Switch 调用）
func set_switch_state(id: String, value: bool) -> void:
	if id == "":
		return
	switch_states[id] = value


## 是否存在该开关的存档状态
func has_switch_state(id: String) -> bool:
	return switch_states.has(id)


## 读取开关存档状态（不存在返回 false）
func get_switch_state(id: String) -> bool:
	return bool(switch_states.get(id, false))


# 保存游戏数据
func get_save_data() -> Dictionary:
	var position_data = {}
	if last_save_point.has("position") and typeof(last_save_point["position"]) == TYPE_VECTOR2:
		position_data = {"x": last_save_point["position"].x, "y": last_save_point["position"].y}
	else:
		position_data = last_save_point.get("position", {"x": 0, "y": 0})
	
	# 获取 TaskManager 数据
	var task_manager = get_node("/root/TaskManager")
	
	# 修复：添加挑战状态记录
	return {
		"save_version": SAVE_VERSION,
		"player_max_health": player_max_health,
		"player_current_health": player_max_health,
		"player_coins": player_coins,
		"last_save_room": last_save_room,
		"unlocked_abilities": unlocked_abilities.duplicate(true),
		"defeated_bosses": defeated_bosses.duplicate(),
		"collected_items": collected_items.duplicate(),
		"last_save_point": {
			"position": position_data,
			"scene_path": last_save_point["scene_path"],
			"save_point_id": last_save_point["save_point_id"]
		},
		# 确保包含 NPC 对话数据
		"npc_interactions": task_manager.npc_interactions.duplicate(true) if task_manager else {},
		"tasks_completed": task_manager.tasks_completed.duplicate(true) if task_manager else {},
		"special_dialogues_shown": task_manager.special_dialogues_shown.duplicate(true) if task_manager else {},
		
		# 修复：添加疯子挑战状态
		"maniac_challenge_completed": maniac_challenge_completed,
		"maniac_last_challenge_failed": maniac_last_challenge_failed,
		"maniac_stage2_challenge_completed": maniac_stage2_challenge_completed,
		"maniac_stage2_last_challenge_failed": maniac_stage2_last_challenge_failed,
		"maniac_stage3_challenge_completed": maniac_stage3_challenge_completed,
		"maniac_stage3_last_challenge_failed": maniac_stage3_last_challenge_failed,
		"maniac_stage4_challenge_completed": maniac_stage4_challenge_completed,
		"maniac_stage4_last_challenge_failed": maniac_stage4_last_challenge_failed,
		"maniac_stage5_challenge_completed": maniac_stage5_challenge_completed,
		"maniac_stage5_last_challenge_failed": maniac_stage5_last_challenge_failed,
		"maniac_stage6_challenge_completed": maniac_stage6_challenge_completed,
		"maniac_stage6_last_challenge_failed": maniac_stage6_last_challenge_failed,
		"maniac_stage7_last_challenge_failed": maniac_stage7_last_challenge_failed,
		
		"race_best_times": race_best_times.duplicate(true),
		"race_best_time_dates": race_best_time_dates.duplicate(true),
		"race_stage_cleared": race_stage_cleared.duplicate(true),
		"endless_score_records": endless_score_records.duplicate(true),
		
		"destructible_walls_destroyed": destructible_walls_destroyed.duplicate(true),
		"hidden_rooms_activated": hidden_rooms_activated.duplicate(),
		"switch_states": switch_states.duplicate(true),
		"visited_rooms": MapManager.visited_rooms.duplicate() if MapManager else [],
		"used_map_doors": MapManager.get_used_doors() if MapManager and MapManager.has_method("get_used_doors") else {},
		"map_reveal_mask": MapManager.get_reveal_mask_base64() if MapManager and MapManager.has_method("get_reveal_mask_base64") else "",
		# ★ 已烘焙的房间地图数据（地面横条/门/标志）。存下来后读档开图不再需要实例化房间场景，
		#   直接解决「探索越多、第一次开图越卡」的问题。
		"map_baked": MapManager.get_baked_state() if MapManager and MapManager.has_method("get_baked_state") else {},
		"activated_teleports": TeleportManager.activated.duplicate() if TeleportManager else [],
		"tp_coords": TeleportManager.get_save_coords() if TeleportManager and TeleportManager.has_method("get_save_coords") else {},
		"played_cinematic_flags": played_cinematic_flags.duplicate(true),
		"play_time_seconds": get_total_play_time_seconds(),
		"timestamp": Time.get_datetime_string_from_system()
	}

# 加载游戏数据
func load_save_data(data: Dictionary):
	print("Global: 开始加载存档数据")

	# 关键：先重置关键落地字段，避免“缺字段时继承旧运行态”
	last_save_room = "GrassLand1"
	last_save_point = {"position": Vector2(0, 0), "scene_path": "", "save_point_id": ""}
	
	if data.has("player_max_health"):
		player_max_health = data["player_max_health"]
		player_max_health_changed.emit(player_max_health)
	
	# 总是设置为满血状态
	player_current_health = player_max_health
	player_health_changed.emit(player_current_health)
	
	if data.has("player_coins"):
		player_coins = data["player_coins"]
		coins_changed.emit(player_coins)
	
	if data.has("unlocked_abilities"):
		unlocked_abilities = data["unlocked_abilities"]
		if not unlocked_abilities.has("backstep"):
			unlocked_abilities["backstep"] = false
		_notify_ability_unlocks()
	
	if data.has("defeated_bosses"):
		defeated_bosses = data["defeated_bosses"]
	
	if data.has("collected_items"):
		collected_items = data["collected_items"]
	
	if data.has("last_save_point"):
		var save_point_data = data["last_save_point"]
		if save_point_data.has("position") and typeof(save_point_data["position"]) == TYPE_DICTIONARY:
			var pos_data = save_point_data["position"]
			last_save_point["position"] = Vector2(pos_data["x"], pos_data["y"])
		else:
			last_save_point["position"] = save_point_data.get("position", Vector2(0, 0))
		
		last_save_point["scene_path"] = save_point_data.get("scene_path", ScenePaths.GAME_MAIN)
		last_save_point["save_point_id"] = save_point_data.get("save_point_id", "start_point")

	# 关键：确保房间落点来自该存档槽本身
	if data.has("last_save_room"):
		last_save_room = data["last_save_room"]

	last_checkpoint_position = get_save_point_position()
	last_checkpoint_type = "static"
	save_point_position = get_save_point_position()

	if data.has("play_time_seconds"):
		total_play_time_seconds = int(data["play_time_seconds"])
	else:
		total_play_time_seconds = 0
	_play_time_session_start_ms = -1
	
	# 加载NPC对话数据
	var task_manager = get_node("/root/TaskManager")
	if task_manager:
		if data.has("npc_interactions"):
			task_manager.npc_interactions = data["npc_interactions"]
		
		if data.has("tasks_completed"):
			task_manager.tasks_completed = data["tasks_completed"]
		
		if data.has("special_dialogues_shown"):
			task_manager.special_dialogues_shown = data["special_dialogues_shown"]
	
	# 修复：加载疯子挑战状态
	if data.has("maniac_challenge_completed"):
		maniac_challenge_completed = data["maniac_challenge_completed"]
	
	if data.has("maniac_last_challenge_failed"):
		maniac_last_challenge_failed = data["maniac_last_challenge_failed"]
	
	if data.has("maniac_stage2_challenge_completed"):
		maniac_stage2_challenge_completed = data["maniac_stage2_challenge_completed"]
	
	if data.has("maniac_stage2_last_challenge_failed"):
		maniac_stage2_last_challenge_failed = data["maniac_stage2_last_challenge_failed"]

	if data.has("maniac_stage3_challenge_completed"):
		maniac_stage3_challenge_completed = data["maniac_stage3_challenge_completed"]

	if data.has("maniac_stage3_last_challenge_failed"):
		maniac_stage3_last_challenge_failed = data["maniac_stage3_last_challenge_failed"]

	if data.has("maniac_stage4_challenge_completed"):
		maniac_stage4_challenge_completed = data["maniac_stage4_challenge_completed"]

	if data.has("maniac_stage4_last_challenge_failed"):
		maniac_stage4_last_challenge_failed = data["maniac_stage4_last_challenge_failed"]
	
	if data.has("maniac_stage5_challenge_completed"):
		maniac_stage5_challenge_completed = data["maniac_stage5_challenge_completed"]
	
	if data.has("maniac_stage5_last_challenge_failed"):
		maniac_stage5_last_challenge_failed = data["maniac_stage5_last_challenge_failed"]

	if data.has("maniac_stage6_challenge_completed"):
		maniac_stage6_challenge_completed = data["maniac_stage6_challenge_completed"]

	if data.has("maniac_stage6_last_challenge_failed"):
		maniac_stage6_last_challenge_failed = data["maniac_stage6_last_challenge_failed"]

	if data.has("maniac_stage7_last_challenge_failed"):
		maniac_stage7_last_challenge_failed = data["maniac_stage7_last_challenge_failed"]
	
	# 竞速挑战最佳时间（key = 阶段序号字符串，value = 秒数）
	if data.has("race_best_times") and typeof(data["race_best_times"]) == TYPE_DICTIONARY:
		race_best_times = data["race_best_times"].duplicate(true)
	else:
		race_best_times = {}

	# 竞速最佳成绩的达成日期（key = 阶段序号字符串，value = 年.月.日）
	if data.has("race_best_time_dates") and typeof(data["race_best_time_dates"]) == TYPE_DICTIONARY:
		race_best_time_dates = data["race_best_time_dates"].duplicate(true)
	else:
		race_best_time_dates = {}

	# 竞速已通关记录
	if data.has("race_stage_cleared") and typeof(data["race_stage_cleared"]) == TYPE_DICTIONARY:
		race_stage_cleared = data["race_stage_cleared"].duplicate(true)
	else:
		race_stage_cleared = {}

	# 无尽模式积分榜
	if data.has("endless_score_records") and typeof(data["endless_score_records"]) == TYPE_ARRAY:
		endless_score_records = data["endless_score_records"].duplicate(true)
	else:
		endless_score_records = []
	
	# 加载可破坏石墙摧毁记录（每个存档独立）
	if data.has("destructible_walls_destroyed"):
		destructible_walls_destroyed = data["destructible_walls_destroyed"].duplicate()  # 使用 .duplicate() 防止引用污染
	else:
		destructible_walls_destroyed = []  # 新存档或无数据时重置为空数组

	if data.has("played_cinematic_flags") and typeof(data["played_cinematic_flags"]) == TYPE_DICTIONARY:
		played_cinematic_flags = data["played_cinematic_flags"].duplicate(true)
	else:
		played_cinematic_flags = {}
	
	## 地图探索 & 传送阵激活 持久化（通过 has_method 安全调用，防止脚本时序问题）
	if MapManager and MapManager.has_method("load_save_data"):
		MapManager.load_save_data(data)
	if TeleportManager and TeleportManager.has_method("load_save_data"):
		TeleportManager.load_save_data(data)
	# 隐藏房间（永久淡出）已激活记录
	if data.has("hidden_rooms_activated") and typeof(data["hidden_rooms_activated"]) == TYPE_ARRAY:
		hidden_rooms_activated = data["hidden_rooms_activated"].duplicate()
	else:
		hidden_rooms_activated = []

	# 机关开关持久化状态（switch_id -> bool）
	if data.has("switch_states") and typeof(data["switch_states"]) == TYPE_DICTIONARY:
		switch_states = data["switch_states"].duplicate(true)
	else:
		switch_states = {}
	# 通知场景内已存在的开关立即刷新状态
	switch_states_changed.emit()



## 登记一个隐藏区域已被永久触发（permanent_hide=true 淡出完成时调用）。
func mark_hidden_room_activated(region_id: String) -> void:
	if region_id == "":
		return
	if region_id in hidden_rooms_activated:
		return
	hidden_rooms_activated.append(region_id)


## 查询某隐藏区域是否已在存档中永久触发。
func is_hidden_room_activated(region_id: String) -> bool:
	return region_id in hidden_rooms_activated

func has_cinematic_flag(flag_id: String) -> bool:
	if flag_id.strip_edges() == "":
		return false
	return bool(played_cinematic_flags.get(flag_id, false))

func set_cinematic_flag(flag_id: String, enabled: bool = true) -> void:
	var normalized_id: String = flag_id.strip_edges()
	if normalized_id == "":
		return
	played_cinematic_flags[normalized_id] = enabled

# 通知能力解锁
func _notify_ability_unlocks():
	if EventBus and EventBus.instance:
		if unlocked_abilities.get("dash", false):
			EventBus.instance.emit_signal("dash_unlocked")
		if unlocked_abilities.get("double_jump", false):
			EventBus.instance.emit_signal("double_jump_unlocked")
		if unlocked_abilities.get("glide", false):
			EventBus.instance.emit_signal("glide_unlocked")
		if unlocked_abilities.get("black_dash", false):
			EventBus.instance.emit_signal("black_dash_unlocked")
		if unlocked_abilities.get("super_dash", false):
			EventBus.instance.emit_signal("super_dash_unlocked")
		if unlocked_abilities.get("wall_grip", false):
			EventBus.instance.emit_signal("wall_grip_unlocked")
		if unlocked_abilities.get("backstep", false):
			EventBus.instance.emit_signal("backstep_unlocked")
		if unlocked_abilities.get("vertical_dash", false):
			EventBus.instance.emit_signal("vertical_dash_unlocked")
		if unlocked_abilities.get("map", false):
			EventBus.instance.emit_signal("map_unlocked")

# 解锁能力
func unlock_ability(ability_name: String):
	if unlocked_abilities.has(ability_name) and !unlocked_abilities[ability_name]:
		unlocked_abilities[ability_name] = true
		# 通知EventBus
		_notify_ability_unlocks()
		if current_save_slot >= 0:
			SaveManager.save_game(current_save_slot, get_save_data())

# 击败Boss
func defeat_boss(boss_name: String):
	if not boss_name in defeated_bosses:
		defeated_bosses.append(boss_name)
		if current_save_slot >= 0:
			SaveManager.save_game(current_save_slot, get_save_data())

# 增加硬币
func add_coins(amount: int):
	player_coins += amount
	# 发射钱币变化信号
	coins_changed.emit(player_coins)
	if current_save_slot >= 0:
		# 钱币变动频繁：交给 SaveManager 合并窗口延迟写档（当帧同步写盘会造成拾取卡顿）
		SaveManager.request_auto_save(false)

## 花费钱币（带动画效果）- 关键修复：只发射 coins_changing 信号
func spend_coins(amount: int) -> bool:
	if player_coins >= amount:
		var old_coins = player_coins
		player_coins -= amount  # 立即减少实际钱币数量
		
		# 只发射动画信号，不发射 coins_changed 信号
		# PlayerUI 会在动画完成后自己更新显示
		coins_changing.emit(old_coins, player_coins, 0.1)
		if current_save_slot >= 0:
			# 钱币变动频繁：交给 SaveManager 合并窗口延迟写档
			SaveManager.request_auto_save(false)
		return true
	else:
		return false

## 获取当前钱币数（新增）
func get_coins() -> int:
	return player_coins

## 竞速最佳时间的显示文本（告示牌对话 / NPC 对话插值用）：没有记录返回「--:--」
func get_race_best_time_text(stage_number: int) -> String:
	var key: String = str(stage_number)
	if not race_best_times.has(key):
		return "--:--"
	var best_time: float = float(race_best_times[key])
	if best_time < 0.0:
		return "--:--"
	return "%.2f 秒" % best_time

## 竞速最佳成绩的达成日期（没有记录返回「--.--.--」）
func get_race_best_time_date_text(stage_number: int) -> String:
	var key: String = str(stage_number)
	if not race_best_time_dates.has(key):
		return "--.--.--"
	return str(race_best_time_dates[key])

## 是否已有某阶段的竞速记录（对话条件用）
func has_race_best_time(stage_number: int) -> bool:
	return race_best_times.has(str(stage_number))

## 写入竞速最佳成绩（同时记录达成日期）；返回是否刷新了记录
func record_race_best_time(stage_number: int, total_time: float) -> bool:
	var key: String = str(stage_number)
	if race_best_times.has(key):
		var old_time: float = float(race_best_times[key])
		if old_time >= 0.0 and total_time >= old_time:
			return false
	race_best_times[key] = total_time
	race_best_time_dates[key] = _today_text()
	return true

## 某阶段是否已经通关过（和「最佳时间」分开存：只要成功过一次就算通关，不再依赖是否刷新纪录）
func has_race_clear(stage_number: int) -> bool:
	return bool(race_stage_cleared.get(str(stage_number), false))

## 记录某阶段已通关（不重复写档；与最佳成绩一起由调用方存档）
func mark_race_stage_cleared(stage_number: int) -> void:
	race_stage_cleared[str(stage_number)] = true

## 告示牌记录行的统一排版：标题：成绩  达成时间：日期
func _format_record_line(title: String, score_text: String, date_text: String) -> String:
	return "%s：%s  达成时间：%s" % [title, score_text, date_text]

## 告示牌用：五个阶段的最佳时间 + 达成日期合成**一段文本**
## ★ 开头带一个换行：对话里写成「竞速记录：{{...}}」时，记录会从下一行开始。
func get_race_board_text() -> String:
	var lines: PackedStringArray = PackedStringArray()
	for stage_number: int in range(1, 6):
		lines.append(_format_record_line(
			"第 %d 段" % stage_number,
			get_race_best_time_text(stage_number),
			get_race_best_time_date_text(stage_number)
		))
	return "\n" + "\n".join(lines)

## 提交一局无尽模式积分（只保留历史前三）；同分不去重，按提交顺序保留
func submit_endless_score(score: int) -> void:
	endless_score_records.append({"score": score, "date": _today_text()})
	endless_score_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("score", 0)) > int(b.get("score", 0))
	)
	if endless_score_records.size() > ENDLESS_RECORD_LIMIT:
		endless_score_records.resize(ENDLESS_RECORD_LIMIT)
	if current_save_slot >= 0:
		SaveManager.save_game(current_save_slot, get_save_data())

## 无尽积分榜第 rank 名（从 1 开始）的积分文本（带单位）：没有记录返回「--」
func get_endless_score_text(rank: int) -> String:
	if rank < 1 or rank > endless_score_records.size():
		return "--"
	return str(int(endless_score_records[rank - 1].get("score", 0))) + " 分"

## 无尽积分榜第 rank 名（从 1 开始）的达成日期：没有记录返回「--.--.--」
func get_endless_score_date_text(rank: int) -> String:
	if rank < 1 or rank > endless_score_records.size():
		return "--.--.--"
	return str(endless_score_records[rank - 1].get("date", "--.--.--"))

## 无尽积分榜告示牌文本（历史前三名 + 达成日期，与竞速榜同一套排版）
## ★ 开头带一个换行：对话里写成「无尽积分记录：{{...}}」时，记录会从下一行开始。
func get_endless_board_text() -> String:
	var lines: PackedStringArray = PackedStringArray()
	for rank: int in range(1, ENDLESS_RECORD_LIMIT + 1):
		lines.append(_format_record_line(
			"第 %d 名" % rank,
			get_endless_score_text(rank),
			get_endless_score_date_text(rank)
		))
	return "\n" + "\n".join(lines)

## 今天的日期文本（年.月.日）
func _today_text() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d.%02d.%02d" % [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0))]

# 记录已收集的道具
func mark_item_collected(item_id: String):
	if not item_id in collected_items:
		collected_items.append(item_id)
		if current_save_slot >= 0:
			SaveManager.save_game(current_save_slot, get_save_data())

# 检查道具是否已收集
func is_item_collected(item_id: String) -> bool:
	return item_id in collected_items

## 设置静态存档点（玩家主动存档）
func set_save_point(position: Vector2, save_point_id: String = "default_chair", scene_path: String = ScenePaths.GAME_MAIN):
	save_point_position = position
	last_save_point["position"] = position
	last_save_point["scene_path"] = scene_path
	last_save_point["save_point_id"] = save_point_id
	last_checkpoint_position = position
	last_checkpoint_type = "static"
	
	# 恢复生命值
	player_current_health = player_max_health
	player_health_changed.emit(player_current_health)

## 设置最新动态检查点（仅运行态，不入档）
func set_dynamic_checkpoint(position: Vector2) -> void:
	last_checkpoint_position = position
	last_checkpoint_type = "dynamic"

## 获取最新触碰的检查点位置（动态优先于静态的“最近一次”语义）
func get_last_checkpoint_position() -> Vector2:
	return last_checkpoint_position

## 清除动态检查点记录，回退到静态存档点
func clear_dynamic_checkpoints() -> void:
	last_checkpoint_position = get_save_point_position()
	last_checkpoint_type = "static"

# 获取最近存档点位置
func get_save_point_position() -> Vector2:
	var position = last_save_point.get("position", Vector2(0, 0))
	if typeof(position) == TYPE_VECTOR2:
		return position
	elif typeof(position) == TYPE_DICTIONARY:
		return Vector2(position.get("x", 0), position.get("y", 0))
	else:
		print("警告：存档位置数据损坏，使用默认位置")
		return Vector2(0, 0)

func start_play_time_session() -> void:
	if _play_time_session_start_ms >= 0:
		return
	_play_time_session_start_ms = Time.get_ticks_msec()

func pause_play_time_session() -> void:
	if _play_time_session_start_ms < 0:
		return
	var elapsed_ms: int = Time.get_ticks_msec() - _play_time_session_start_ms
	total_play_time_seconds += int(elapsed_ms / 1000.0)
	_play_time_session_start_ms = -1

func resume_play_time_session() -> void:
	start_play_time_session()

func stop_play_time_session() -> void:
	pause_play_time_session()

func get_total_play_time_seconds() -> int:
	if _play_time_session_start_ms < 0:
		return total_play_time_seconds
	var elapsed_ms: int = Time.get_ticks_msec() - _play_time_session_start_ms
	return total_play_time_seconds + int(elapsed_ms / 1000.0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_persist_play_time_before_quit()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# Android 返回手势 / 返回键：不再直接退出游戏，转成 ui_cancel（等同 Esc），
		# 由当前 UI 页面自己决定怎么处理（关面板 / 关地图 / 返回上级）。
		# 必须同时保证工程设置 application/config/quit_on_go_back = false
		#（工程设置 → 应用 → 配置 → 返回时退出），否则引擎会在发出这个通知之前
		# 就直接退出应用 —— 而且该设置是**导出时烘焙**的，改完必须重新导出 APK 才生效。
		var back_event: InputEventAction = InputEventAction.new()
		back_event.action = &"ui_cancel"
		back_event.pressed = true
		Input.parse_input_event(back_event)

func _exit_tree() -> void:
	_persist_play_time_before_quit()

func _persist_play_time_before_quit() -> void:
	if current_save_slot < 0:
		return
	stop_play_time_session()
	if SaveManager:
		SaveManager.save_game(current_save_slot, get_save_data())
