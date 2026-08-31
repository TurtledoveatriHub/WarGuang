extends Node
class_name ChallengeController
const ChallengeUIControllerScript = preload("res://Scripts/UI/ChallengeUIController.gd")

## ── 挑战音效 ──
@export_category("挑战音效")
## 挑战开始时播放一遍
@export var start_sfx: AudioStream
## 挑战成功时播放一遍
@export var success_sfx: AudioStream
## 挑战失败时播放一遍
@export var fail_sfx: AudioStream

## ── 各阶段配置（Inspector 中依次拖入各 ChallengeConfig 资源） ──
## 索引 0=第一阶段，1=第二阶段，2=第三阶段...
@export var stage_configs: Array[ChallengeConfig] = []

## ── 挑战区域 ──
@export_category("挑战区域")
## 挑战区域 TextArea 节点路径（用于 require_in_bounds 检测玩家离开区域）
@export_node_path var challenge_area_path: NodePath = NodePath()
## 挑战开始位置（Marker2D 节点路径）
## 挑战开始时 player 会被传送到此位置，黑屏过渡后再正式开始
@export_node_path var start_position_path: NodePath = NodePath()

## ── 黑屏效果参数 ──
@export_category("黑屏效果")
## 淡出时长（秒，画面渐黑）
@export var challenge_fade_out: float = 0.4
## 黑屏保持时长（秒，全黑期间传送 player 到起始位置）
@export var challenge_black_hold: float = 0.4
## 淡入时长（秒，渐亮恢复画面，挑战正式开始）
@export var challenge_fade_in: float = 0.4

## ── 挑战规则 ──
@export_category("挑战规则")
## 挑战开始后的宽限期（秒），期间不检测失败条件
## 等待 player 传送到起始位置 + JumpBox 激活完成后再开始正式检测
@export var challenge_grace_period: float = 2.0

## ── UI ──
@export_category("UI")
## 挑战 UI 场景（ChallengeCounter.tscn）
@export var challenge_ui_scene: PackedScene
## UI 淡入淡出时间（秒）
@export var ui_fade_duration: float = 1.0

enum State { INACTIVE, ACTIVE, SUCCESS, FAILED }
var current_state: State = State.INACTIVE

var active_config: ChallengeConfig = null
var triggered_count: int = 0
var spawned_jumpboxes: Array = []
var challenge_bounds: Rect2
var has_triggered_first: bool = false
var _challenge_grace_timer: float = 0.0
var player_ref: Node = null
var ui_controller = null

signal challenge_started()
signal challenge_completed()
signal challenge_failed()

func _ready():
	ui_controller = ChallengeUIControllerScript.new()
	if challenge_ui_scene:
		ui_controller.setup(self, challenge_ui_scene, ui_fade_duration)

## 初始化挑战边界（从 ChallengeArea TextArea 读取）
func _init_challenge_bounds() -> void:
	if challenge_area_path == NodePath() or challenge_area_path.is_empty():
		push_warning("ChallengeController: 未设置 challenge_area_path，区域检测禁用")
		return
	var area = get_node_or_null(challenge_area_path)
	if area and area.has_method("get_global_rect"):
		challenge_bounds = area.get_global_rect()

## ManiacNPC 调用此方法启动挑战
func start_challenge(stage_index: int = 0) -> void:
	if current_state == State.ACTIVE:
		return
	if stage_index < 0 or stage_index >= stage_configs.size():
		push_error("ChallengeController: 阶段索引越界 ", stage_index)
		return
	active_config = stage_configs[stage_index]
	if active_config == null:
		push_error("ChallengeController: 阶段 ", stage_index, " 配置为空")
		return
	
	current_state = State.ACTIVE
	triggered_count = 0
	has_triggered_first = false
	_challenge_grace_timer = challenge_grace_period
	challenge_bounds = Rect2()
	_init_challenge_bounds()
	if ui_controller != null:
		ui_controller.setup(self, challenge_ui_scene, ui_fade_duration)
	
	# 黑屏传送到挑战起始位置
	await _teleport_player_to_start()
	
	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_callback(_fade_out_player_ui)
	tw.tween_callback(_activate_container_jumpboxes)
	tw.tween_callback(_show_challenge_ui)
	tw.tween_callback(_update_challenge_ui)
	if start_sfx:
		AudioManager.play_stream_sfx(start_sfx)
	challenge_started.emit()

## 黑屏将 player 传送到挑战起始位置（参考 Door 的传送效果）
func _teleport_player_to_start() -> void:
	if start_position_path == NodePath() or start_position_path.is_empty():
		return
	var marker = get_node_or_null(start_position_path) as Marker2D
	if marker == null:
		return
	var player = _get_player()
	if player == null:
		return
	# 淡出 → 黑屏
	if FadeManager and FadeManager.has_method("fade_out"):
		await FadeManager.fade_out(challenge_fade_out)
	# 黑屏中传送 player
	player.global_position = marker.global_position
	player.velocity = Vector2.ZERO
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	# 黑屏保持
	if challenge_black_hold > 0.0:
		await get_tree().create_timer(challenge_black_hold).timeout
	# 淡入恢复
	if FadeManager and FadeManager.has_method("fade_in"):
		await FadeManager.fade_in(challenge_fade_in)
	var tw = create_tween()
	tw.set_parallel(true)
	tw.tween_callback(_fade_out_player_ui)
	tw.tween_callback(_activate_container_jumpboxes)
	tw.tween_callback(_show_challenge_ui)
	tw.tween_callback(_update_challenge_ui)
	challenge_started.emit()

## 激活容器下所有 is_challenge_jumpbox=true 的 JumpBox（不扫描子容器）
func _activate_container_jumpboxes() -> void:
	spawned_jumpboxes.clear()
	var container = get_node_or_null(active_config.challenge_container_path)
	if container == null:
		push_error("ChallengeController: 容器不存在 ", active_config.challenge_container_path)
		return
	for child in container.get_children():
		if child is JumpBox and child.is_challenge_jumpbox:
			spawned_jumpboxes.append(child)
			child.play_start_animation()
			if child.has_signal("bounce_triggered"):
				if child.bounce_triggered.is_connected(_on_jumpbox_bounce):
					child.bounce_triggered.disconnect(_on_jumpbox_bounce)
				child.bounce_triggered.connect(_on_jumpbox_bounce.bind(child))
	if spawned_jumpboxes.is_empty():
		push_warning("ChallengeController: 容器无 JumpBox")

func _on_jumpbox_bounce(body, _jumpbox) -> void:
	if body.is_in_group("player") and current_state == State.ACTIVE:
		var eligible = body.current_animation == "JUMP2"
		if not eligible and body.has_method("is_recent_double_jump_start"):
			eligible = body.is_recent_double_jump_start(0.12)
		if not eligible:
			return
		triggered_count += 1
		_update_challenge_ui()
		has_triggered_first = true
		if triggered_count >= active_config.target_count:
			_complete_challenge()

func _process(_delta: float) -> void:
	if current_state == State.ACTIVE:
		# 宽限期内不检测失败条件（等待 player 传送到位 + JumpBox 激活）
		if _challenge_grace_timer > 0.0:
			_challenge_grace_timer -= _delta
			return
		_check_failure_conditions()

func _check_failure_conditions() -> void:
	var player = _get_player()
	if not player or active_config == null:
		return
	if active_config.require_in_bounds:
		if challenge_bounds != Rect2() and challenge_bounds.has_point(player.global_position) == false:
				print("[Challenge] 离开区域，失败")
				_fail_challenge()
				return
	if active_config.require_no_floor and has_triggered_first:
		if player.is_on_floor():
			print("[Challenge] 落地，失败")
			_fail_challenge()

func _get_player() -> Node:
	if is_instance_valid(player_ref):
		return player_ref
	player_ref = get_tree().get_first_node_in_group("player")
	return player_ref

func _complete_challenge() -> void:
	if current_state != State.ACTIVE:
		return
	current_state = State.SUCCESS
	_deactivate_all_jumpboxes()
	_hide_challenge_ui_with_fade()
	_do_fade_in_player_ui()
	if success_sfx:
		AudioManager.play_stream_sfx(success_sfx)
	challenge_completed.emit()

func _fail_challenge() -> void:
	if current_state != State.ACTIVE:
		return
	current_state = State.FAILED
	_deactivate_all_jumpboxes()
	_hide_challenge_ui_with_fade()
	_do_fade_in_player_ui()
	if fail_sfx:
		AudioManager.play_stream_sfx(fail_sfx)
	challenge_failed.emit()

func _deactivate_all_jumpboxes() -> void:
	for jb in spawned_jumpboxes:
		if is_instance_valid(jb):
			jb.play_end_and_hide()
	spawned_jumpboxes.clear()

func _fade_out_player_ui() -> void:
	if ui_controller: ui_controller.fade_out_player_ui()
func _do_fade_in_player_ui() -> void:
	if ui_controller: ui_controller.fade_in_player_ui()
func _show_challenge_ui() -> void:
	if ui_controller: ui_controller.show_challenge_ui()
func _hide_challenge_ui_with_fade() -> void:
	if ui_controller: ui_controller.hide_challenge_ui_with_fade(Callable())
func _update_challenge_ui() -> void:
	if ui_controller and active_config != null:
		ui_controller.update_challenge_ui(triggered_count, active_config.target_count)
