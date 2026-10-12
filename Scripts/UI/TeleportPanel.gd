extends CanvasLayer

## 传送面板（参考 MapUI 模式，Esc 关闭，互斥打开）
## 层级：99（MapUI=98 之上，GameSetting=100 之下）

## 覆盖层暗化规范（黑幕 alpha / 世界亮度 / 黑幕过渡时长）—— 全项目唯一来源
const OverlaySpec := preload("res://Scripts/UI/DarkOverlay.gd")

signal menu_closed

var source_teleport_id: String = ""

## ── 黑屏效果参数 ──
@export_category("黑屏效果")
## 淡出时长（秒，画面渐黑）
@export var fade_out_duration: float = 0.4
## 黑屏保持时长（秒，全黑期间执行传送逻辑）
@export var black_hold_duration: float = 0.6
## 淡入时长（秒，渐亮恢复画面）
@export var fade_in_duration: float = 0.4

@onready var background: ColorRect = $Background
@onready var panel_root: Node2D = $PanelRoot
## 动效总线（开合动画由它驱动）
@onready var fx_director: Node = $UIFxDirector

@onready var teleport_buttons: Array[TextureButton] = [
	$PanelRoot/GrassLand1,
	$PanelRoot/GrassLand7,
	$PanelRoot/GrassLand12,
	$PanelRoot/GrassLand14,
	$PanelRoot/SnowMountain4
]

var _original_modulate: Color
var _canvas_modulate: CanvasModulate
var _owns_pause: bool = false

## 开合动画统一交给 UIFxDirector（动效总线）驱动 PanelRoot，本脚本只负责收尾逻辑。
## 注意：Background(ColorRect 暗化层) 不能放进总线目标列表（总线只写 modulate，
## 而 ColorRect 的暗化靠 color.a）。
var _open_fallback_timer: SceneTreeTimer = null
var _close_fallback_timer: SceneTreeTimer = null
var _closing_started: bool = false
var _closing_finished: bool = false
var _teleport_started: bool = false
## 记录按钮原始 normal 纹理（悬停/按下反馈会临时替换 texture_normal，需据此还原）
var _btn_original_normal: Dictionary = {}


func _ready() -> void:
	layer = 99
	# 打开时会把游戏置为暂停，关闭时又要在「按下关闭按钮的那一刻」就立刻恢复运行 ——
	# 所以必须用 ALWAYS：用 WHEN_PAUSED 的话，一旦取消暂停本节点的补间与黑幕渐变就会停住。
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = true
	panel_root.visible = true
	# 黑幕从全透明开始，立即开始渐暗（约 1 秒）；数值取自 DarkOverlay 的统一规范，
	# 不再在本文件里写死（之前写死 0.85 + ×0.3，比地图界面明显偏暗）。
	background.color = Color(0, 0, 0, 0)
	OverlaySpec.fade_rect_alpha(background, OverlaySpec.OVERLAY_ALPHA, self)
	
	for btn in teleport_buttons:
		_btn_original_normal[btn.get_instance_id()] = btn.texture_normal
	_adjust_lighting()
	_update_buttons()
	_set_game_setting_btn_visible(false)
	
	get_tree().paused = true
	_owns_pause = true
	
	_play_fx_enter()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close_panel()
		get_viewport().set_input_as_handled()
		return
	# Tab（map 动作）不再是关闭键，但仍要吞掉：否则事件会落到 PlayerUI 把地图弹出来盖住本面板
	if event.is_action_pressed("map"):
		get_viewport().set_input_as_handled()
		return
	# U（交互键）：面板打开期间的关闭键（原来是 Tab，已改为 U）
	if event.is_action_pressed("interactive"):
		_close_panel()
		get_viewport().set_input_as_handled()
		return
	# 兜底命中：按钮是 Node2D(PanelRoot) 的子级 Control，某些情况下鼠标路由不可靠。
	# 在 _input 阶段手动命中（_input 先于 GUI 处理，set_input_as_handled 可避免与 pressed 重复触发）。
	_handle_pointer_release(event)

## 鼠标左键 / 触摸释放时，若命中某个可用传送按钮则触发传送逻辑。
func _handle_pointer_release(event: InputEvent) -> void:
	var is_release := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		is_release = not event.pressed
	elif event is InputEventScreenTouch:
		is_release = not event.pressed
	if not is_release:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	for btn in teleport_buttons:
		if btn.visible and not btn.disabled and btn.get_global_rect().has_point(mouse_pos):
			var tid: String = String(btn.get("target_teleport_id"))
			if tid != "":
				_start_teleport(tid)
				get_viewport().set_input_as_handled()
			return


func _set_game_setting_btn_visible(state: bool) -> void:
	var ui = get_tree().get_first_node_in_group("player_ui")
	if ui and ui.has_method("set_icon_locked"):
		## 按钮已被 PlayerUI 移动到独立 CanvasLayer，不能通过 get_node 查找。
		## 按要求：传送面板打开期间**不隐藏**图标，只保持按下外观并禁止再按。
		ui.set_icon_locked(not state)


## 每帧根据指针位置手动驱动按钮的悬停/按下纹理反馈。
## 原因：这些按钮位于 Node2D(PanelRoot) 之下，本项目的 GUI 鼠标路由在其上不可靠
## （点击已由 _handle_pointer_release 兜底），悬停/按下状态也需要手动模拟。
func _process(_delta: float) -> void:
	_update_button_pointer_visuals()

func _update_button_pointer_visuals() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var pointer_down: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	for btn in teleport_buttons:
		_set_button_pointer_state(
			btn,
			btn.visible and not btn.disabled and btn.get_global_rect().has_point(mouse_pos),
			pointer_down
		)

## 依据悬停/按下状态临时切换 texture_normal，使 hover/pressed 纹理生效；
## 无悬停时恢复原始 normal 纹理。
func _set_button_pointer_state(btn: TextureButton, hovered: bool, pointer_down: bool) -> void:
	if btn == null:
		return
	var original: Texture2D = _btn_original_normal.get(btn.get_instance_id())
	if original == null:
		return
	var target: Texture2D = original
	if hovered and pointer_down and btn.texture_pressed:
		target = btn.texture_pressed
	elif hovered and btn.texture_hover:
		target = btn.texture_hover
	if btn.texture_normal != target:
		btn.texture_normal = target


## ── 更新按钮状态 ──
func _update_buttons() -> void:
	var activated: Array = TeleportManager.activated
	var available_count: int = 0
	for tid in activated:
		if tid != source_teleport_id:
			available_count += 1
	
	if available_count > teleport_buttons.size():
		push_warning("TeleportPanel: 激活传送阵(%d) > 按钮(%d)" % [available_count, teleport_buttons.size()])
	
	for btn in teleport_buttons:
		var tid: String = ""
		if "target_teleport_id" in btn:
			tid = btn.target_teleport_id
		
		if tid == "" or tid not in activated:
			btn.visible = false
			continue
		
		btn.visible = true
		if tid == source_teleport_id:
			btn.disabled = true
			btn.modulate = Color(0.5, 0.5, 0.5, 1)
		else:
			btn.disabled = false
			btn.modulate = Color(1, 1, 1, 1)
			btn.pressed.connect(_on_teleport_button_pressed.bind(tid), CONNECT_ONE_SHOT)


## ── 传送（参考 Door 的传送效果，但不自动走位）──
func _on_teleport_button_pressed(target_id: String) -> void:
	_start_teleport(target_id)

func _start_teleport(target_id: String) -> void:
	# 防重入：指针兜底与 GUI pressed 都可能触发，只允许执行一次。
	if _teleport_started:
		return
	_teleport_started = true
	## 注意：打开 TeleportPanel 时 get_tree().paused = true
	## FadeManager 设置了 PROCESS_MODE_ALWAYS，其 tween 在暂停态下仍可推进
	
	## 步骤1：淡出 → 黑屏
	await FadeManager.fade_out(fade_out_duration)
	
	## 步骤2：黑屏中关闭面板 + 执行传送（不暴露在黑屏外）
	_restore_lighting()
	get_tree().paused = false
	_owns_pause = false
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	visible = false
	
	## 步骤3：黑屏期间传送（参考 Door 的流程：黑屏持续期间操作场景树安全）
	var data: Dictionary = TeleportManager.get_data(target_id)
	var player := get_tree().get_first_node_in_group("player")
	if data.is_empty() or not player:
		await FadeManager.fade_in(fade_in_duration)
		queue_free()
		return
	
	if player.has_method("lock_control"):
		player.lock_control(999.0, "teleport")
	player.velocity = Vector2.ZERO
	
	var target_room: String = data.get("room_id", "")
	
	if RoomManager and RoomManager.has_method("suppress_player_room_enter"):
		RoomManager.suppress_player_room_enter(0.45)
	
	var tp_pos_raw = data.get("position", Vector2.ZERO)
	var tp_pos: Vector2 = Vector2.ZERO
	if typeof(tp_pos_raw) == TYPE_VECTOR2:
		tp_pos = tp_pos_raw
	elif typeof(tp_pos_raw) == TYPE_ARRAY and tp_pos_raw.size() == 2:
		tp_pos = Vector2(tp_pos_raw[0], tp_pos_raw[1])
	
	if RoomManager and RoomManager.has_method("prepare_room_background_for_entry"):
		RoomManager.prepare_room_background_for_entry(target_room, tp_pos)
	
	RoomManager.load_room(target_room)
	player.global_position = tp_pos
	player.velocity = Vector2.ZERO
	RoomManager.update_camera_limits()
	
	await get_tree().physics_frame
	RoomManager.update_camera_limits()
	
	if player.has_method("sync_camera_after_room_teleport"):
		player.sync_camera_after_room_teleport()
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	
	if player.has_method("lock_control"):
		player.lock_control(0.0, "teleport_end")
	
	## 步骤4：黑屏保持
	if black_hold_duration > 0.0:
		await get_tree().create_timer(black_hold_duration).timeout
	
	## 步骤5：淡入
	await FadeManager.fade_in(fade_in_duration)
	queue_free()


func _close_panel() -> void:
	# 点了关闭就**立刻**恢复暂停与暗化，不等动画 / 黑幕渐变播完：
	# 暗化消失与组件退场动画同时开始，而不是等动画播完才开始。
	if _closing_started:
		return
	_closing_started = true
	_resume_game()
	_restore_lighting()
	OverlaySpec.fade_rect_alpha(background, 0.0, self)
	_play_fx_exit()


## 立刻恢复暂停。退场动画与黑幕渐变继续推进（本节点是 PROCESS_MODE_ALWAYS）。
func _resume_game() -> void:
	if get_tree() != null and get_tree().paused:
		get_tree().paused = false
	_owns_pause = false


func _finish_close_panel() -> void:
	if _closing_finished:
		return
	_closing_finished = true
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	queue_free()

## 入场动画：交给 UIFxDirector；另设兜底计时器，补间异常时把面板拉回基准状态
func _play_fx_enter() -> void:
	if fx_director == null:
		return
	fx_director.call("play_enter")
	var duration: float = float(fx_director.call("estimate_duration", "enter"))
	_open_fallback_timer = get_tree().create_timer(duration + 0.2)
	_open_fallback_timer.timeout.connect(_fx_open_fallback)

## 入场兜底：仍在打开状态时，把面板恢复到基准可见状态
func _fx_open_fallback() -> void:
	if not _closing_started and fx_director != null:
		fx_director.call("reset_state")

## 退场动画：交给 UIFxDirector；结束时（或兜底超时）执行关闭收尾
## 收尾必须等【内容退场】与【黑幕渐亮】都完成，否则黑幕会被瞬间切掉、看不到渐亮过程。
func _play_fx_exit() -> void:
	var fx_duration: float = 0.0
	if fx_director != null:
		fx_director.call("play_exit")
		fx_duration = float(fx_director.call("estimate_duration", "exit"))
	var total: float = maxf(fx_duration, OverlaySpec.OVERLAY_FADE_DURATION) + 0.2
	_close_fallback_timer = get_tree().create_timer(total)
	_close_fallback_timer.timeout.connect(_finish_close_panel)

func _exit_tree() -> void:
	# 兜底：任何异常路径下都恢复亮度；若仍持有暂停也一并恢复，避免残留暂停/暗化。
	_restore_lighting()
	if _owns_pause and get_tree() and get_tree().paused:
		get_tree().paused = false
		_owns_pause = false


func _adjust_lighting() -> void:
	if RoomManager == null or RoomManager.global_canvas_modulate == null:
		return
	_canvas_modulate = RoomManager.global_canvas_modulate
	_original_modulate = _canvas_modulate.color
	var factor: float = OverlaySpec.WORLD_DARKEN_MULTIPLIER
	_canvas_modulate.color = Color(
		_original_modulate.r * factor,
		_original_modulate.g * factor,
		_original_modulate.b * factor,
		1.0
	)


func _restore_lighting() -> void:
	if _canvas_modulate and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate
