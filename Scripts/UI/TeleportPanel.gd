extends CanvasLayer

## 传送面板（参考 MapUI 模式，Esc 关闭，互斥打开）
## 层级：99（MapUI=98 之上，GameSetting=100 之下）

signal menu_closed

var source_teleport_id: String = ""

@onready var background: ColorRect = $Background
@onready var panel_root: Node2D = $PanelRoot
@onready var close_btn: TextureButton = $PanelRoot/CloseBtn

@onready var teleport_buttons: Array[TextureButton] = [
	$PanelRoot/Btn1,
	$PanelRoot/Btn3,
	$PanelRoot/Btn4,
]

var _original_modulate: Color
var _canvas_modulate: CanvasModulate


func _ready() -> void:
	layer = 99
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	visible = true
	panel_root.visible = true
	background.color = Color(0, 0, 0, 0.85)
	
	close_btn.pressed.connect(_close_panel)
	_adjust_lighting()
	_update_buttons()
	_set_game_setting_btn_visible(false)
	
	get_tree().paused = true


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close_panel()
		get_viewport().set_input_as_handled()
	if event.is_action_pressed("map"):
		get_viewport().set_input_as_handled()


func _set_game_setting_btn_visible(state: bool) -> void:
	var ui = get_tree().get_first_node_in_group("player_ui")
	if ui and "game_setting_button" in ui:
		## 按钮已被 PlayerUI 移动到独立 CanvasLayer，不能通过 get_node 查找
		ui.game_setting_button.visible = state


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
	## 注意：打开 TeleportPanel 时 get_tree().paused = true
	## FadeManager 设置了 PROCESS_MODE_ALWAYS，其 tween 在暂停态下仍可推进
	
	## 步骤1：黑屏（FadeManager 在游戏暂停时仍能正常工作）
	await FadeManager.fade_out(0.1)
	
	## 步骤2：黑屏中关闭面板（不暴露在黑屏外）
	_restore_lighting()
	get_tree().paused = false
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	visible = false  ## 隐藏但不 free，避免 await 后脚本失效
	
	## 步骤3：传送
	var data: Dictionary = TeleportManager.get_data(target_id)
	var player := get_tree().get_first_node_in_group("player")
	if data.is_empty() or not player:
		await FadeManager.fade_in(0.4)
		queue_free()
		return
	
	if player.has_method("lock_control"):
		player.lock_control(999.0, "teleport")
	player.velocity = Vector2.ZERO
	
	var target_room: String = data.get("room_id", "")
	RoomManager.load_room(target_room)
	player.global_position = data.get("position", Vector2.ZERO)
	player.velocity = Vector2.ZERO
	RoomManager.update_camera_limits()
	
	await get_tree().process_frame
	await get_tree().physics_frame
	RoomManager.update_camera_limits()
	
	if player.has_method("sync_camera_after_room_teleport"):
		player.sync_camera_after_room_teleport()
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	
	if player.has_method("lock_control"):
		player.lock_control(0.0, "teleport_end")
	
	await get_tree().physics_frame
	await FadeManager.fade_in(0.4)
	
	## 步骤4：全部流程完成后才释放面板
	queue_free()


func _close_panel() -> void:
	_restore_lighting()
	get_tree().paused = false
	_set_game_setting_btn_visible(true)
	menu_closed.emit()
	queue_free()


func _adjust_lighting() -> void:
	if RoomManager and RoomManager.global_canvas_modulate:
		_canvas_modulate = RoomManager.global_canvas_modulate
		_original_modulate = _canvas_modulate.color
		_canvas_modulate.color = Color(
			_original_modulate.r * 0.3,
			_original_modulate.g * 0.3,
			_original_modulate.b * 0.3,
			1.0
		)


func _restore_lighting() -> void:
	if _canvas_modulate and is_instance_valid(_canvas_modulate):
		_canvas_modulate.color = _original_modulate
