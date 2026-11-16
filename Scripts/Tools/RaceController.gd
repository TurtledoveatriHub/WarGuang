extends Node
class_name RaceController

## 跑圈竞速挑战控制器（计时制，无 AI 对手）
## 规则：玩家按顺序通过本阶段圈道上所有检查点 → 再过起点线算 1 圈；
##       在限时内跑完配置圈数 = 成功；超时 / 离开赛道 = 失败。
## 每圈过起点线时所有检查点复位（纹理/着色恢复未激活），下一圈重新按顺序激活。
## 结束后：停留 result_hold_time → 黑屏传回「初始位置」（**黑屏里就弹出结果对话**）→ 渐亮。
## 全程锁着操控，只有结果对话结束（RaceStarter 负责）才交还。
##       → 自动触发 RaceStarter 的结果对话（成功 / 失败分支）。
## 每个阶段的赛道是独立节点组，未开始/结束时整组隐藏。
## 黑屏传送流程与 JumpBox 挑战（ChallengeController）保持一致。

## 玩家 HUD 淡入淡出助手：复用 ChallengeUIController 的 fade_out/fade_in_player_ui
const PlayerUIFadeScript = preload("res://Scripts/UI/ChallengeUIController.gd")

## ── 阶段配置 ──
## 各阶段竞速配置（Inspector 按顺序拖入；索引 0 = 第一阶段）
@export var stage_configs: Array[RaceStageConfig] = []

@export_category("回程")
## 初始位置（Marker2D）：挑战结束后黑屏把玩家送回这里，并在黑屏中立即弹出结果对话
@export_node_path var initial_position_path: NodePath = NodePath()

@export_category("黑屏传送")
## 渐黑时长（秒）
@export var race_fade_out: float = 0.4
## 全黑保持时长（秒，期间完成传送）
@export var race_black_hold: float = 0.4
## 渐亮时长（秒，结束后正式开始计时）
@export var race_fade_in: float = 0.4
## 宽限期（秒）：开始后的这段时间不计时也不判负（传送落地的缓冲）
@export var race_grace_period: float = 0.5

@export_category("倒计时")
## 开始前倒计时秒数（从该数字倒数到 1，然后显示 GO！）
@export var countdown_from: int = 3
## 倒计时每步时长（秒）
@export var countdown_step: float = 0.8

@export_category("结果展示")
## 结果面板停留时长（秒），之后开始回程
@export var result_hold_time: float = 2.0

@export_category("音效")
## 挑战开始时播放
@export var start_sfx: AudioStream
## 每通过一个检查点时播放
@export var checkpoint_sfx: AudioStream
## 每跑完一圈（过起点线）时播放；**最后一圈不播**（那一下已经有成功音效）
@export var lap_sfx: AudioStream
## 倒计时每跳一个数字时播放（留空则不播）
@export var countdown_sfx: AudioStream
## 挑战成功时播放
@export var success_sfx: AudioStream
## 挑战失败时播放
@export var fail_sfx: AudioStream

@export_category("UI")
## 竞速 HUD 场景（RaceHUD.tscn）
@export var race_ui_scene: PackedScene
## UI 淡入淡出时长（秒）
@export var ui_fade_duration: float = 1.0

## 竞速状态机
enum State { INACTIVE, RUNNING, SUCCESS, FAILED }

## 挑战开始（玩家已就位、计时已启动）时发出
signal race_started()
## 挑战成功时发出，参数为总用时（秒）
signal race_completed(total_time: float)
## 挑战失败时发出
signal race_failed()

## 触发本控制器的 RaceStarter（由 NPC 启动挑战时写入，用于结束后自动对话）
var starter_npc: Node = null
## 当前状态
var current_state: State = State.INACTIVE
## 倒计时是否还在进行（进行中不算计时、不判负）
var _countdown_active: bool = false
## 本控制器当前是否持有「禁用操控」的锁
var _lock_owned: bool = false
## 是否正在等结果对话结束（只有这一次对话结束才交还操控）
var _awaiting_result_dialogue: bool = false
## 当前生效的阶段配置
var active_config: RaceStageConfig = null
## 当前阶段序号（从 1 开始，同时作为最佳时间存档 key）
var active_stage_number: int = 0
## 本阶段圈道节点（RaceStartLine + RaceCheckpoint，按 index 升序）
var checkpoints: Array[Node] = []
## 已完成圈数
var completed_laps: int = 0
## 已用时间（秒）
var elapsed_time: float = 0.0
## 下一个应当通过的检查点 index（大于最大 index 时表示「该过起点线了」）
var next_expected_index: int = 1
## 宽限期剩余时间（秒）
var _grace_timer: float = 0.0
## 竞速区域的世界矩形
var _race_bounds: Rect2 = Rect2()
## 玩家引用缓存
var _player_ref: Node = null
## 竞速 HUD 实例
var _ui: RaceHUD = null
## 玩家 HUD 淡入淡出助手
var _player_ui_fade = null
## 结果是否已经处理过（防止成功/失败回调重复触发）
var _result_handled: bool = false
## 本次挑战开始前，本阶段是否已经通关过
var _result_cleared_before: bool = false
## 本次是否为该阶段首次通关
var _result_first_clear: bool = false
## 本次是否刷新了该阶段的最佳成绩
var _result_record_broken: bool = false

## 初始化：建立玩家 HUD 助手，并把所有阶段赛道隐藏起来
func _ready() -> void:
	_player_ui_fade = PlayerUIFadeScript.new()
	_player_ui_fade.setup(self, race_ui_scene, ui_fade_duration)
	_hide_all_stages()

## 逐帧计时与失败判定
func _process(delta: float) -> void:
	if current_state != State.RUNNING or active_config == null or _countdown_active:
		return
	if _grace_timer > 0.0:
		_grace_timer -= delta
		return
	elapsed_time += delta
	if active_config.target_time > 0.0 and elapsed_time >= active_config.target_time:
		_fail_race("超时")
		return
	if active_config.require_in_bounds:
		var player: Node = _get_player()
		if player != null and _race_bounds != Rect2() and not _race_bounds.has_point(player.global_position):
			_fail_race("离开赛道")
			return
	if _ui != null:
		_ui.update_timer(elapsed_time, active_config.target_time - elapsed_time)

## 启动第 stage_index 阶段（由 RaceStarter 通过对话调用）
func start_race(stage_index: int = 0) -> void:
	if current_state == State.RUNNING:
		return
	if stage_index < 0 or stage_index >= stage_configs.size():
		push_error("RaceController: 阶段索引越界 " + str(stage_index))
		return
	active_config = stage_configs[stage_index]
	if active_config == null:
		push_error("RaceController: 阶段 " + str(stage_index) + " 配置为空")
		return
	active_stage_number = stage_index + 1
	completed_laps = 0
	elapsed_time = 0.0
	next_expected_index = 1
	_grace_timer = 0.0
	_result_handled = false
	_result_cleared_before = Global.has_race_clear(active_stage_number)
	_result_first_clear = false
	_result_record_broken = false
	if not _prepare_track(active_config):
		return
	# 从调用 start_race 那一刻起就禁操控（只禁输入，物理/状态机照常跑）：
	# 直到黑屏传送 + 倒计时结束才交还
	current_state = State.RUNNING
	_countdown_active = true
	_lock_player()
	_show_stage(active_config)
	await _teleport_player_to_start()
	_show_ui()
	await _run_countdown()
	# 倒计时结束：正式开始计时（宽限期给落地缓冲）
	_countdown_active = false
	_grace_timer = race_grace_period
	_unlock_player()
	_fade_out_player_ui()
	if start_sfx:
		AudioManager.play_stream_sfx(start_sfx)
	race_started.emit()

## 开跑前的 3-2-1-GO 倒计时（期间锁着操控，且不显示计时器/圈数）
func _run_countdown() -> void:
	if _ui == null or active_config == null:
		return
	for number: int in range(countdown_from, 0, -1):
		_ui.show_countdown(str(number))
		if countdown_sfx:
			AudioManager.play_stream_sfx(countdown_sfx)
		await get_tree().create_timer(maxf(countdown_step, 0.05)).timeout
	_ui.show_countdown("GO！")
	await get_tree().create_timer(maxf(countdown_step, 0.05) * 0.6).timeout
	# 切回「剩余时间 + 圈数」
	_ui.hide_countdown()
	_ui.update_timer(0.0, active_config.target_time)
	_update_ui_lap()

## 收集并复位本阶段圈道节点；失败（容器/区域缺配置）时返回 false
func _prepare_track(config: RaceStageConfig) -> bool:
	checkpoints.clear()
	var container: Node = get_node_or_null(config.checkpoint_container_path)
	if container == null:
		push_error("RaceController: 检查点容器不存在 " + str(config.checkpoint_container_path))
		return false
	for child: Node in container.get_children():
		if not child.has_signal("player_entered"):
			continue
		if not child.player_entered.is_connected(_on_checkpoint_entered):
			child.player_entered.connect(_on_checkpoint_entered)
		checkpoints.append(child)
	checkpoints.sort_custom(func(a: Node, b: Node) -> bool:
		return int(a.get("checkpoint_index")) < int(b.get("checkpoint_index"))
	)
	if checkpoints.size() < 2:
		push_error("RaceController: 圈道至少需要 1 个起点线 + 1 个检查点")
		return false
	for checkpoint: Node in checkpoints:
		if checkpoint.has_method("set_activated"):
			checkpoint.set_activated(false)
	# 读取竞速区域矩形（世界坐标），用于离开赛道判定
	_race_bounds = Rect2()
	var area: Node = get_node_or_null(config.race_area_path)
	if area != null and area.has_method("get_global_rect"):
		_race_bounds = area.get_global_rect()
	return true

## 黑屏把玩家传送到本阶段起跑点
func _teleport_player_to_start() -> void:
	if active_config == null:
		return
	var marker: Marker2D = get_node_or_null(active_config.start_position_path) as Marker2D
	if marker == null:
		return
	var player: Node = _get_player()
	if player == null:
		return
	await _black_screen_fade_out()
	player.global_position = marker.global_position
	player.velocity = Vector2.ZERO
	# 出生朝向固定为右（避免带着上一个房间的朝向开跑）
	player.is_facing_right = true
	if player.animated_sprite:
		player.animated_sprite.flip_h = false
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	if race_black_hold > 0.0:
		await get_tree().create_timer(race_black_hold).timeout
	await _black_screen_fade_in()

## 玩家进入某个圈道节点：只有按顺序经过才生效
func _on_checkpoint_entered(checkpoint: Node) -> void:
	if current_state != State.RUNNING or active_config == null:
		return
	if _grace_timer > 0.0:
		return
	var index: int = int(checkpoint.get("checkpoint_index"))
	if index == 0:
		# 起点线：途中检查点全部按顺序通过后，过线才算完成一圈
		var last_index: int = int(checkpoints[checkpoints.size() - 1].get("checkpoint_index"))
		if next_expected_index > last_index:
			_complete_lap()
		return
	if index != next_expected_index:
		# 顺序不对（前一个还没激活 / 已经过过了）→ 不激活、不计数
		return
	if checkpoint.has_method("set_activated"):
		checkpoint.set_activated(true)
	next_expected_index += 1
	if checkpoint_sfx:
		AudioManager.play_stream_sfx(checkpoint_sfx)
	_update_ui_lap()

## 完成一圈：够圈数就结算成功，否则复位检查点开始下一圈
func _complete_lap() -> void:
	if active_config == null:
		return
	completed_laps += 1
	if completed_laps >= maxi(active_config.lap_count, 1):
		_finish_race()
		return
	# 不是最后一圈：过线（完成一圈）音效
	if lap_sfx:
		AudioManager.play_stream_sfx(lap_sfx)
	for checkpoint: Node in checkpoints:
		if checkpoint.has_method("set_activated"):
			checkpoint.set_activated(false)
	next_expected_index = 1
	_update_ui_lap()

## 结算成功：记录最佳时间、展示结果，然后走回程流程
func _finish_race() -> void:
	if _result_handled:
		return
	_result_handled = true
	current_state = State.SUCCESS
	# 注意：结算瞬间**不限操控**（玩家只是在看结果面板），黑屏传送开始前才禁
	var total_time: float = elapsed_time
	# 本阶段之前是否已经通关过（决定结果对话走「首次通关」还是「重复挑战」分支）
	_result_cleared_before = Global.has_race_clear(active_stage_number)
	_result_first_clear = not _result_cleared_before
	Global.mark_race_stage_cleared(active_stage_number)
	_result_record_broken = _record_best_time(total_time)
	if success_sfx:
		AudioManager.play_stream_sfx(success_sfx)
	if _ui != null:
		_ui.show_result("挑战成功  %.2f 秒" % total_time, true)
	race_completed.emit(total_time)
	_hold_result_then_return()

## 结算失败
func _fail_race(_reason: String) -> void:
	if _result_handled:
		return
	_result_handled = true
	current_state = State.FAILED
	# 已通关过的阶段再次挑战失败：走单独的结果分支
	_result_cleared_before = Global.has_race_clear(active_stage_number)
	_result_first_clear = false
	_result_record_broken = false
	if fail_sfx:
		AudioManager.play_stream_sfx(fail_sfx)
	if _ui != null:
		_ui.show_result("挑战失败", false)
	race_failed.emit()
	_hold_result_then_return()

## 结果面板停留 → 关闭 HUD → 黑屏传送回初始位置 → **黑屏中就弹出结果对话** → 渐亮
## ★ 全程锁着操控，只有对话结束（RaceStarter 负责）才交还。
func _hold_result_then_return() -> void:
	if result_hold_time > 0.0:
		await get_tree().create_timer(result_hold_time).timeout
	if _ui != null:
		_ui.fade_out(ui_fade_duration)
		_ui = null
	var marker: Marker2D = get_node_or_null(initial_position_path) as Marker2D
	var player: Node = _get_player()
	if marker == null or player == null:
		_start_result_dialogue()
		return
	# 黑屏传送开始 → 禁操控（后面一直保持到结果对话结束）
	_lock_player()
	await _black_screen_fade_out()
	player.global_position = marker.global_position
	player.velocity = Vector2.ZERO
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	_hide_all_stages()
	_fade_in_player_ui()
	# 黑屏里立即弹对话（不再额外等待）：渐亮时玩家看到的就是已经在说的话
	_start_result_dialogue()
	if race_black_hold > 0.0:
		await get_tree().create_timer(race_black_hold).timeout
	await _black_screen_fade_in()

## 渐黑
func _black_screen_fade_out() -> void:
	if FadeManager and FadeManager.has_method("fade_out"):
		await FadeManager.fade_out(race_fade_out)

## 渐亮
func _black_screen_fade_in() -> void:
	if FadeManager and FadeManager.has_method("fade_in"):
		await FadeManager.fade_in(race_fade_in)

## 自动触发 RaceStarter 的结果对话（分支标题按结算类型决定）
func _start_result_dialogue() -> void:
	if starter_npc != null and starter_npc.has_method("start_result_dialogue_title"):
		# 交还操控由 RaceStarter 在**这一次结果对话**结束时回调 on_result_dialogue_finished()
		_awaiting_result_dialogue = true
		starter_npc.start_result_dialogue_title(_resolve_result_dialogue_title())
	else:
		# 没有触发 NPC（例如直接调 start_race 测试）：自己把操控还回去，避免永久禁控
		_unlock_player()

## 根据结算类型决定自动结果对话的标题：
##  - 首次通关：result_win_1 ~ result_win_5（每段独立）
##  - 重复挑战成功：result_repeat_record（刷新纪录） / result_repeat_no_record（未刷新）
##  - 重复挑战失败：result_repeat_lose
##  - 未通关阶段的失败：result_lose
func _resolve_result_dialogue_title() -> String:
	if current_state == State.SUCCESS:
		if _result_first_clear:
			return "result_win_" + str(active_stage_number)
		return "result_repeat_record" if _result_record_broken else "result_repeat_no_record"
	return "result_repeat_lose" if _result_cleared_before else "result_lose"

## 结果对话结束（由 RaceStarter 回调）：交还操控
func on_result_dialogue_finished() -> void:
	if not _awaiting_result_dialogue:
		return
	_awaiting_result_dialogue = false
	_unlock_player()

## 开赛对话结束时由 RaceStarter 询问：本控制器当前是否在用着禁控锁
func is_lock_owned() -> bool:
	return _lock_owned

## 禁用玩家操控（只关输入：物理与状态机仍然正常运行，不冻结玩家）
func _lock_player() -> void:
	var player: Node = _get_player()
	if player != null and player.has_method("set_player_control"):
		player.set_player_control(false)
	_lock_owned = true

## 交还玩家操控
func _unlock_player() -> void:
	var player: Node = _get_player()
	if player != null and player.has_method("set_player_control"):
		player.set_player_control(true)
	_lock_owned = false

## 记录最佳时间（只在更快时写入；返回是否刷新了记录）；刷新时立即存档 + 广播给告示牌
func _record_best_time(total_time: float) -> bool:
	if not Global.record_race_best_time(active_stage_number, total_time):
		return false
	if EventBus and EventBus.has_method("notify_race_best_time_updated"):
		EventBus.notify_race_best_time_updated(active_stage_number, total_time)
	if Global.current_save_slot >= 0:
		SaveManager.save_game(Global.current_save_slot, Global.get_save_data())
	return true

## 隐藏所有阶段的赛道
func _hide_all_stages() -> void:
	for config: RaceStageConfig in stage_configs:
		if config == null:
			continue
		var root: Node = get_node_or_null(config.stage_root_path)
		if root != null:
			root.visible = false

## 只显示当前阶段的赛道
func _show_stage(config: RaceStageConfig) -> void:
	_hide_all_stages()
	var root: Node = get_node_or_null(config.stage_root_path)
	if root != null:
		root.visible = true

## 实例化并显示竞速 HUD
func _show_ui() -> void:
	if race_ui_scene == null or active_config == null:
		push_error("RaceController: race_ui_scene 未配置")
		return
	var host: Node = get_tree().root.get_node_or_null("MainGameScene")
	if host == null:
		host = get_tree().current_scene
	if host == null:
		return
	_ui = race_ui_scene.instantiate() as RaceHUD
	if _ui == null:
		return
	_ui.name = "RaceHUD"
	host.add_child(_ui)
	_ui.setup(active_config.lap_count, active_config.target_time)
	_ui.board.modulate.a = 0.0
	_ui.fade_in(ui_fade_duration)
	_ui.update_timer(elapsed_time, active_config.target_time - elapsed_time)

## 刷新 HUD 圈数
func _update_ui_lap() -> void:
	if _ui != null and active_config != null:
		_ui.update_lap(completed_laps, active_config.lap_count)

## 隐藏玩家 HUD（复用 ChallengeUIController 的实现）
func _fade_out_player_ui() -> void:
	if _player_ui_fade != null:
		_player_ui_fade.fade_out_player_ui()

## 恢复玩家 HUD（复用 ChallengeUIController 的实现）
func _fade_in_player_ui() -> void:
	if _player_ui_fade != null:
		_player_ui_fade.fade_in_player_ui()

## 取玩家节点（带缓存）
func _get_player() -> Node:
	if is_instance_valid(_player_ref):
		return _player_ref
	_player_ref = get_tree().get_first_node_in_group("player")
	return _player_ref
