extends CanvasLayer

## 传送面板
##
## 按钮控制逻辑：每个预置按钮通过 Inspector 设置 target_teleport_id，
## 面板打开时检查 TeleportManager 中该 ID 的激活状态：
##   - 已激活且 != 来源 → 可用
##   - 已激活且 == 来源 → 禁用（当前所在）
##   - 未激活 → 隐藏
## 若激活的传送阵数量 > 按钮数量 + 1（排除自身），发出警告。
##
## 层级：99（MapUI=98 之上，GameSetting=100 之下）

signal menu_closed

## 来源传送阵 ID（由 TeleportPoint 在打开面板时设置）
var source_teleport_id: String = ""

@onready var background: ColorRect = $Background
@onready var panel_root: Control = $PanelRoot
@onready var close_btn: TextureButton = $PanelRoot/CloseBtn

## 预置按钮节点（在场景中摆放，Inspector 中设置 target_teleport_id）
@onready var teleport_buttons: Array[TextureButton] = [
	$PanelRoot/Btn1,
	$PanelRoot/Btn2,
	$PanelRoot/Btn3,
]

var _original_modulate: Color
var _canvas_modulate: CanvasModulate
var _tween: Tween = null


func _ready() -> void:
	layer = 99
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	panel_root.modulate = Color(1, 1, 1, 0)
	
	close_btn.pressed.connect(_close_panel)
	_adjust_lighting()
	_update_buttons()
	
	get_tree().paused = true
	
	_open_animation()


## ── 更新按钮状态 ──
func _update_buttons() -> void:
	var activated := TeleportManager.activated
	## 排除自身的激活传送阵数量
	var available_count: int = 0
	for tid in activated:
		if tid != source_teleport_id:
			available_count += 1
	
	if available_count > teleport_buttons.size():
		push_warning("TeleportPanel: 激活的传送阵(%d) 超过按钮数量(%d)，部分传送阵无法访问" % [available_count, teleport_buttons.size()])
	
	for btn in teleport_buttons:
		var tid: String = _get_btn_target_id(btn)
		if tid == "":
			btn.visible = false
			continue
		
		if tid not in activated:
			btn.visible = false
			continue
		
		btn.visible = true
		if tid == source_teleport_id:
			btn.disabled = true
			btn.text = "● 当前所在"
		else:
			btn.disabled = false
			btn.text = _get_teleport_display_name(tid)
			btn.pressed.connect(_on_teleport_button_pressed.bind(tid), CONNECT_ONE_SHOT)


## 从按钮节点获取 target_teleport_id（按优先级：自定义元数据 > 节点名）
func _get_btn_target_id(btn: TextureButton) -> String:
	if btn.has_meta("target_teleport_id"):
		return btn.get_meta("target_teleport_id")
	## 回退：用按钮名匹配传送阵 ID
	return ""


## 获取传送阵显示名
func _get_teleport_display_name(tid: String) -> String:
	var data := TeleportManager.get_data(tid)
	if data.is_empty():
		return tid
	return data.get("display_name", tid)


## ── 传送 ──
func _on_teleport_button_pressed(target_id: String) -> void:
	await FadeManager.fade_out(0.1)
	_restore_lighting()
	get_tree().paused = false
	
	var data := TeleportManager.get_data(target_id)
	if data.is_empty():
		await FadeManager.fade_in(0.4)
		menu_closed.emit()
		queue_free()
		return
	
	var player := get_tree().get_first_node_in_group("player")
	if not player:
		await FadeManager.fade_in(0.4)
		menu_closed.emit()
		queue_free()
		return
	
	RoomManager.load_room(data.get("room_id", ""))
	player.global_position = data.get("position", Vector2.ZERO)
	player.velocity = Vector2.ZERO
	RoomManager.update_camera_limits()
	
	await get_tree().process_frame
	await get_tree().physics_frame
	RoomManager.update_camera_limits()
	
	if player.has_method("sync_camera_to_player_center"):
		player.sync_camera_to_player_center(true)
	
	await FadeManager.fade_in(0.4)
	
	menu_closed.emit()
	queue_free()


## ── UI ──
func _open_animation() -> void:
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(background, "color", Color(0, 0, 0, 0.85), 0.12)
	_tween.tween_property(panel_root, "modulate", Color(1, 1, 1, 1), 0.15)


func _close_panel() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_restore_lighting()
	get_tree().paused = false
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
