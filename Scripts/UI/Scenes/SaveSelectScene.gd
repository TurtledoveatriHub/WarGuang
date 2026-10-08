extends UIScene  # UI 页面统一基类（生命周期 / 输入锁 / 动效总线）

## 删除确认对话框场景（在 Inspector 中拖拽 DeleteConfirmDialog.tscn）
@export var delete_confirm_scene: PackedScene


class SaveData:
	var exists: bool = false
	var player_max_health: int = 3
	var coins: int = 0
	var last_save_room: String = "GrassLand1"
	var play_time_seconds: int = 0
	var timestamp: String = ""

var save_slots = []  ## 存档槽数据数组，存储每个槽位的存档信息
var is_dialog_open: bool = false  ## 删除确认对话框是否打开状态
## 当前选中的存档槽（-1 = 未选中）。选中后才会出现「进入存档 / 清空存档」两个按钮。
var _selected_slot: int = -1
## 存档槽当前是否可点（= 输入锁状态）。选中的那个槽不接收鼠标，用它与输入锁区分开。
var _slot_buttons_interactive: bool = true
## 两个操作按钮当前是否显示中。
var _action_buttons_shown: bool = false
## 操作按钮动画的代次号：连点存档槽时只让最后一次生效。
var _action_anim_token: int = 0

@export_category("SaveSlot 填充纹理按区域映射")
## 按房间ID配置填充纹理（键为房间ID，值为 Texture2D）。
@export var room_filled_texture_map: Dictionary = {}

## 过渡轨道已并入 UIFxDirector（动效总线）：这里保留旧名字指向总线，业务代码无需改动。
@onready var ui_transition_animator: Node = _get_fx_bus()

@onready var save_slot_buttons = [
	$SaveSlot1,
	$SaveSlot2, 
	$SaveSlot3
]

@onready var play_time_labels = [
	$SaveSlot1/PlayTimeLabel,
	$SaveSlot2/PlayTimeLabel,
	$SaveSlot3/PlayTimeLabel
]

## 选中某个存档槽后才出现的操作按钮（图片按钮 + 文本子节点，挂在 UIButtonFx 组件上）
@onready var enter_save_button: TextureButton = $EnterSaveButton
@onready var clear_save_button: TextureButton = $ClearSaveButton

## 房间ID到纹理的运行时查询表
var _room_texture_lookup: Dictionary = {}

## 初始化存档选择场景
func _ready():
	_load_save_data()
	_rebuild_room_texture_lookup()
	_connect_signals()
	_update_slot_display()
	set_input_locked(true)
	if ui_transition_animator:
		ui_transition_animator.reset_state()

	$BackButton.pressed.connect(_on_back_button_pressed)
	# 两个操作按钮默认不显示，选中存档槽后才进入场动画出现。
	_set_action_buttons_visible(false)
	_apply_slot_selection_visual()
	# 黑屏场景切换时由 SceneManager / UIRouter 显式调用 ui_enter()；
	# 非黑屏（编辑器直接运行本场景）时自行入场。
	auto_enter_unless_black()
	
	await get_tree().create_timer(0.1).timeout
	
	## 修改：调用LightingManager的统一函数
	LightingManager.setup_ui_breathing_effect(self)

## 加载存档数据
## 读取所有存档槽的数据
func _load_save_data():
	save_slots = []
	for i in range(3):
		var save_data = SaveData.new()
		var save_info = SaveManager.get_save_info(i)
		save_data.exists = save_info.get("exists", false)
		if save_data.exists:
			save_data.player_max_health = save_info.get("player_max_health", 3)
			save_data.coins = save_info.get("player_coins", 0)
			save_data.last_save_room = save_info.get("last_save_room", "GrassLand1")
			save_data.play_time_seconds = int(save_info.get("play_time_seconds", 0))
			save_data.timestamp = save_info.get("timestamp", "")
		save_slots.append(save_data)

## 连接信号
## 连接存档槽相关信号
func _connect_signals():
	for i in range(3):
		var slot_button = save_slot_buttons[i]
		
		if slot_button.pressed.is_connected(_on_save_slot_pressed):
			slot_button.pressed.disconnect(_on_save_slot_pressed)
		
		slot_button.pressed.connect(_on_save_slot_pressed.bind(i))
	
	# 悬停反馈（缩放 / 像素位移 / 文本提亮 / 音效）已交给 SaveSlot 上的 UIButtonFx 组件，
	# 这里不再手写 mouse_entered / mouse_exited 补间。
	if not enter_save_button.pressed.is_connected(_on_enter_save_pressed):
		enter_save_button.pressed.connect(_on_enter_save_pressed)
	if not clear_save_button.pressed.is_connected(_on_clear_save_pressed):
		clear_save_button.pressed.connect(_on_clear_save_pressed)

## 更新存档槽显示
## 刷新存档槽显示
func _update_slot_display():
	for i in range(3):
		var slot_button = save_slot_buttons[i]
		var save_data = save_slots[i]
		var filled_slot: Sprite2D = slot_button.get_node("FilledSlot")
		var play_time_label: Label = play_time_labels[i]
		
		slot_button.get_node("EmptySlot").visible = !save_data.exists
		filled_slot.visible = save_data.exists
		if save_data.exists:
			filled_slot.texture = _resolve_filled_texture(i, save_data.last_save_room, filled_slot.texture)
			play_time_label.text = _format_play_time(save_data.play_time_seconds)
			play_time_label.visible = true
		else:
			play_time_label.visible = false

## 处理存档槽按钮按下
## 点击存档槽：只做「选中」，不再直接进游戏；
## 进游戏还是清空存档由随后出现的两个操作按钮决定。
func _on_save_slot_pressed(slot_index: int):
	if is_input_locked() or is_dialog_open:
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	if slot_index == _selected_slot and _action_buttons_shown:
		return
	# 旧槽会在这一句里自己把「按下态」收回去，新槽保持按下态。
	_selected_slot = slot_index
	_apply_slot_selection_visual()
	_refresh_action_buttons()

## 重建房间纹理映射缓存（运行时只做字典查询）
## 重建房间到纹理的查询表
func _rebuild_room_texture_lookup() -> void:
	_room_texture_lookup.clear()
	for key_variant in room_filled_texture_map.keys():
		var key: String = str(key_variant).strip_edges()
		if key == "":
			continue
		var tex_variant: Variant = room_filled_texture_map.get(key_variant)
		if tex_variant is Texture2D:
			_room_texture_lookup[key] = tex_variant

## 按房间ID解析填充纹理
## 根据房间ID选择填充纹理
func _resolve_filled_texture(_slot_index: int, room_id: String, fallback: Texture2D) -> Texture2D:
	var key: String = room_id.strip_edges()
	if key != "" and _room_texture_lookup.has(key):
		var mapped: Variant = _room_texture_lookup.get(key)
		if mapped is Texture2D:
			return mapped
	return fallback

## 将秒数格式化为显示文本
func _format_play_time(total_seconds: int) -> String:
	var safe_seconds: int = max(0, total_seconds)
	var hours: int = int(safe_seconds / 3600.0)
	var minutes: int = int((safe_seconds % 3600) / 60.0)
	var seconds: int = safe_seconds % 60
	return "游戏时长 %02d:%02d:%02d" % [hours, minutes, seconds]

## 显示「进入存档 / 清空存档」两个按钮。
## 若它们已经显示着（玩家点了另一个存档槽）：**先完整播一遍出场动画，再重新播入场动画**。
## 注意：它们也是 UIButtonFx 组件，所以页面退场时会被 UIFxDirector 一并带走（此时它们正好是可见的）。
## 这里只对这两个组件本身调 play_enter()/play_exit()，不经过总线
## —— 否则会把整页所有组件重新播一遍。
func _refresh_action_buttons() -> void:
	if _selected_slot < 0 or _selected_slot >= save_slots.size():
		return
	_action_anim_token += 1
	var token: int = _action_anim_token
	if _action_buttons_shown:
		_action_buttons_shown = false
		# 用「时长等待」而不是 await 动画信号：Tween 被 kill 时不会发 finished，
		# 等信号会有挂死的风险（本项目吃过大亏）。
		enter_save_button.play_exit()
		clear_save_button.play_exit()
		var exit_wait: float = maxf(enter_save_button.get_fx_duration("exit"), clear_save_button.get_fx_duration("exit"))
		await wait_seconds(exit_wait)
		if token != _action_anim_token:
			return
	# 空存档没有「清空」语义，把清空按钮藏起来（而不是让它点下去没反应）
	var has_save: bool = save_slots[_selected_slot].exists
	enter_save_button.visible = true
	clear_save_button.visible = has_save
	enter_save_button.play_enter(0.0)
	if has_save:
		clear_save_button.play_enter(0.06)
	_action_buttons_shown = true

## 隐藏两个操作按钮并复位它们的动效状态（下次显示时会重新播入场）
func _set_action_buttons_visible(shown: bool) -> void:
	_action_buttons_shown = shown
	_action_anim_token += 1
	enter_save_button.visible = shown
	clear_save_button.visible = shown
	if not shown:
		enter_save_button.settle_now()
		clear_save_button.settle_now()

## 点击「进入存档」：真正进入游戏
func _on_enter_save_pressed() -> void:
	if is_input_locked() or is_dialog_open or _selected_slot < 0:
		return
	# 退场动画 / 黑屏 / 换场景 / 新页入场的顺序只在 UIRouter 里定义一处。
	await ui_exit()
	await SceneManager.start_game_from_save(_selected_slot)

## 覆盖基类：ESC 返回（对话框打开时不返回）。
## ESC 不受输入锁限制：输入锁只用来防连点，若把它也拿来挡 ESC，
## 就会出现「动画还没结束所以按什么都没反应」的误解。
func _on_ui_cancel() -> void:
	if is_dialog_open:
		return
	_go_back_to_title()

## 点击返回按钮（受输入锁保护；按钮本身在锁定时也是 disabled 的）
func _on_back_button_pressed():
	if is_input_locked():
		return
	if is_dialog_open:
		return
	_go_back_to_title()

func _go_back_to_title() -> void:
	LightingManager.stop_all_light_effects()
	# 退场动画 / 黑屏 / 换场景 / 新页入场的顺序只在 UIRouter 里定义一处。
	await UIRouter.goto_scene(ScenePaths.UI_TITLE)

## 点击「清空存档」：弹删除确认对话框
func _on_clear_save_pressed():
	if is_input_locked() or is_dialog_open or _selected_slot < 0:
		return
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	if not delete_confirm_scene:
		push_error("SaveSelectScene: delete_confirm_scene 未配置！请在 Inspector 中拖拽 DeleteConfirmDialog.tscn")
		return
	
	# 对话框期间标记为打开，并让本页面整层「失活」：
	# 按钮既点不动、也不再播悬停动画，ESC 也交给对话框处理 —— 也就是完全无视本层内容。
	# 因为 UIScene.overlay_pass_through_input = true，本页不会吞掉事件，
	# 所以对话框自己的按钮照常可点。
	is_dialog_open = true
	set_overlay_active(true)
	LightingManager.dim_lights(0.0, 0.5)
	
	var confirm_dialog = delete_confirm_scene.instantiate()
	add_child(confirm_dialog)
	confirm_dialog.confirm_callback = _on_confirm_delete.bind(_selected_slot)
	confirm_dialog.tree_exited.connect(_on_dialog_closed)

## 设置所有按钮的启用状态
func _set_buttons_enabled(enabled: bool):
	_slot_buttons_interactive = enabled
	for i in save_slot_buttons.size():
		_apply_slot_button_selected(save_slot_buttons[i], i == _selected_slot)
	$BackButton.disabled = !enabled
	enter_save_button.disabled = !enabled
	clear_save_button.disabled = !enabled


## 把「哪个槽被选中」应用到三个存档按钮上。
func _apply_slot_selection_visual() -> void:
	for i in save_slot_buttons.size():
		_apply_slot_button_selected(save_slot_buttons[i], i == _selected_slot)


## 被选中的存档槽保持「按下」外观（与 SettingsScene 的分类按钮同一套做法）：
##   * button_pressed → 画 texture_pressed（槽位当前没配贴图，配了就自动生效）；
##   * set_locked_visual(true) → 保持按下时的缩放 + 像素位移 + 文本提亮，
##     切换到其它槽时传 false，它会自己播一遍「取消选中」的回收动画；
##   * 不用 disabled 表现选中：disabled 会画 texture_disabled，那不是按下态。
func _apply_slot_button_selected(button: TextureButton, selected: bool) -> void:
	if button == null:
		return
	button.disabled = false
	button.toggle_mode = true
	button.button_pressed = selected
	var interactive: bool = _slot_buttons_interactive and not selected
	button.mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	if button.has_method("set_locked_visual"):
		button.call("set_locked_visual", selected)

## 处理对话框关闭
## 处理删除确认对话框关闭
func _on_dialog_closed():
	is_dialog_open = false
	# 解除「被覆盖」状态：恢复按钮启用（含选中态的按下外观）
	set_overlay_active(false)
	set_input_locked(false)
	LightingManager.restore_lights(0.5)
	
	## 重新启用ESC键处理
	set_process_input(true)

## 确认删除存档
## 确认删除指定存档
func _on_confirm_delete(slot_index: int):
	if SaveManager.delete_save(slot_index):
		save_slots[slot_index].exists = false
		_update_slot_display()
		# 槽位已空：收起两个操作按钮并清除选中（贴图与锁定视觉一并收回去）
		_selected_slot = -1
		_set_action_buttons_visible(false)
		_apply_slot_selection_visual()
		
		# 关键修复：如果删除的是当前存档，需要清空 Global 数据
		if slot_index == Global.current_save_slot:
			Global.destructible_walls_destroyed = []
			# 保险措施：避免后续逻辑把运行态数据再保存回已删除的槽位
			Global.current_save_slot = -1

## 退出场景时停止灯光效果
## 退出场景时清理灯光
func _exit_tree():
	LightingManager.stop_all_light_effects()

## 覆盖基类：把输入锁应用到本页面的按钮上。
func _on_input_lock_applied(locked: bool) -> void:
	_set_buttons_enabled(not locked)


## ---- 以下动效 / 等待 / 节点收集逻辑已全部上提到 UIScene / UIFxDirector，本文件不再重复实现 ----
