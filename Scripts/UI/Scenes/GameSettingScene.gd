extends UIScene  # UI 页面统一基类（生命周期 / 输入锁 / 动效总线）

## 设置界面场景（在 Inspector 中拖拽 SettingsScene.tscn）
@export var settings_scene_resource: PackedScene
@onready var continue_button = $ContinueButton
@onready var settings_button = $SettingsButton
@onready var main_menu_button = $MainMenuButton

signal menu_closed

@export var transition_duration: float = 0.1

## 覆盖层暗化规范（黑幕 alpha / 世界亮度 / 黑幕过渡时长）—— 全项目唯一来源
const OverlaySpec := preload("res://Scripts/UI/DarkOverlay.gd")

var original_modulate_color: Color
var game_canvas_modulate: CanvasModulate
var is_open: bool = false
var _is_closing: bool = false
var _is_game_lighting_dimmed: bool = false


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 开合动画改为交给动效总线（UIFxDirector）：
	# 「哪些节点参与开合」只在场景里的 UIFxDirector 上配一处（Background + 三个按钮），
	# 持续时间/峰值倍率/漂移距离也都在那里调，本脚本不再复制一份时长参数。
	# 仍设 drive_components = false：这三个按钮用 UIButtonFx，
	# 组件轨道会给它们再叠一层错开缩放，与页面开合动画抢 scale。
	lock_swallows_mouse = false
	
	continue_button.pressed.connect(_on_continue_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	main_menu_button.pressed.connect(_on_main_menu_button_pressed)
	
	layer = 100  # 直接使用内置的 layer 属性
	
	get_tree().paused = true
	is_open = true
	# 面板打开期间隐藏移动端 HUD：本页面会把树暂停，而 HUD 是 PROCESS_MODE_ALWAYS，
	# 它会继续在 _input 里处理触摸/鼠标。若不同步隐藏，HUD 会抢走本页面及其子页面的
	# 鼠标「按下」事件 → 表现成「按钮点一下只悬停、要按两次」和「设置页虚拟按键拖不动」。
	_set_mobile_hud_visibility(false)
	if Global:
		Global.pause_play_time_session()
	
	# 关键修复：显示黑色遮罩层 —— 从全透明立即开始渐暗（约 1 秒），
	# 不再“啵”地一下整块盖上；fade_in_overlay 内部会强制重置旧状态，
	# 避免重复打开 SettingsScene 时造成遮罩叠加。
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.fade_in_overlay(self, OverlaySpec.OVERLAY_FADE_DURATION)
	# 关键修复：如果对话框存在，暂时隐藏它
	var balloon = get_node_or_null("/root/MyBalloon")
	if balloon:
		balloon.visible = false
	
	if continue_button is Control:
		continue_button.grab_focus()

	_set_menu_buttons_enabled(false)
	# 统一暗化：与世界亮度系数、黑幕透明度都由 DarkOverlay 定义，
	# 本页面不再自己写死数字（_adjust_game_lighting 之前定义了却从未被调用）。
	_adjust_game_lighting()
	# 入场：总线摆起始态 → 播动画 → 等播完 → 解锁输入（含兜底超时）。
	# 本面板是 PlayerUI 直接 add_child() 上来的（不经过 UIRouter / SceneManager），
	# 这里显式走一遍基类入场流程，否则基类的 ESC 门禁会一直是关闭的。
	await ui_enter()

## 覆盖基类：把输入锁应用到本页面的按钮上。
func _on_input_lock_applied(locked: bool) -> void:
	_set_menu_buttons_enabled(not locked)

## 覆盖基类：ESC 关闭本面板（设置覆盖层开着时不关）。
func _on_ui_cancel() -> void:
	if not is_open:
		return
	if UIRouter.has_overlay():
		return
	await _close_game_setting()

func _input(event: InputEvent) -> void:
	super._input(event)
	## 设置界面打开时阻止 Tab 打开地图
	if event.is_action_pressed("map") and is_open:
		get_viewport().set_input_as_handled()

func _close_menu():
	is_open = false
	
	if continue_button is Control:
		continue_button.grab_focus()
	
	FadeManager.fade_in(FadeManager.ui_switch_fade_in_duration)
	
	if game_canvas_modulate and is_instance_valid(game_canvas_modulate):
		var target_color = Color(
			original_modulate_color.r,
			original_modulate_color.g,
			original_modulate_color.b,
			1.0
		)
		
		game_canvas_modulate.color = target_color

func _adjust_game_lighting():
	if _is_game_lighting_dimmed:
		return
	if RoomManager and RoomManager.global_canvas_modulate:
		game_canvas_modulate = RoomManager.global_canvas_modulate
		original_modulate_color = game_canvas_modulate.color
		# 世界亮度系数取自 DarkOverlay 的统一规范，不再由本页面自己写死：
		# 地图 / 传送面板 / 本页面三个覆盖层必须用同一个数字。
		var factor: float = OverlaySpec.WORLD_DARKEN_MULTIPLIER
		var target_color = Color(
			original_modulate_color.r * factor,
			original_modulate_color.g * factor,
			original_modulate_color.b * factor,
			1.0
		)
		game_canvas_modulate.color = target_color
		_is_game_lighting_dimmed = true
	else:
		print("GameSettingScene: 错误: 无法获取CanvasModulate")

func _restore_game_lighting():
	if not _is_game_lighting_dimmed:
		return
	if game_canvas_modulate and is_instance_valid(game_canvas_modulate):
		var tween = create_tween()
		tween.tween_property(game_canvas_modulate, "color", original_modulate_color, transition_duration)
		await tween.finished
		_is_game_lighting_dimmed = false
	else:
		print("GameSettingScene: 无法恢复光照")

func _close_game_setting():
	if not is_open or _is_closing:
		return

	_is_closing = true
	is_open = false
	set_input_locked(true)
	# 点了关闭按钮就**立刻**恢复暂停与游戏计时，不等退场动画 / 黑幕渐变播完。
	# 本页面是 PROCESS_MODE_ALWAYS，所以取消暂停后动画与补间照常推进。
	_resume_game_now()
	# 交回移动端 HUD（与 _ready 里的隐藏成对）。
	_set_mobile_hud_visibility(true)
	# 记下黑幕渐亮起始时间戳
	var fade_started_ms: int = Time.get_ticks_msec()
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.fade_out_overlay(self, OverlaySpec.OVERLAY_FADE_DURATION)
	# 世界亮度与黑幕同时恢复，避免黑幕散尽之后画面再“啪”地亮一下。
	# 这里不 await：本函数末尾还会 await 一次，保证 queue_free() 之前补间已经落定。
	_restore_game_lighting()
	# 退场动画交给动效总线；ui_exit() 内部会等动画播完（含兜底超时）。
	await ui_exit()
	# 等黑幕也渐亮完，否则黑幕会被瞬间切掉、看不到渐亮过程
	await _wait_overlay_fade(fade_started_ms)
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.reset_overlay()
		DarkOverlay.hide_overlay()
	# 关键修正：必须先等待亮度恢复完成，再销毁场景。
	# 之前未 await，queue_free() 会杀掉绑定在本节点上的补间，
	# 导致 CanvasModulate 永远停在暗色，出现“只消失一层”的残留。
	await _restore_game_lighting()
	menu_closed.emit()
	queue_free()


## 立刻恢复暂停 + 游戏计时（不等退场动画）。本页面是 PROCESS_MODE_ALWAYS，
## 因此取消暂停后它自己的退场动画、黑幕渐变与亮度补间都会继续推进。
func _resume_game_now() -> void:
	if get_tree() != null and get_tree().paused:
		get_tree().paused = false
	if Global:
		Global.resume_play_time_session()

func _on_continue_button_pressed():
	# TODO 定位后连同其它 [UIIN] 打印一起删除。
	print("[UIIN][GameSetting] 鼠标点击“继续游戏”（对照组：这条能出现就说明鼠标路径正常）")
	if not continue_button or continue_button.disabled:
		return
	await _close_game_setting()

func _set_mobile_hud_visibility(show_state: bool) -> void:
	for hud in get_tree().get_nodes_in_group("mobile_touch_hud"):
		if hud.has_method("set_hud_visible"):
			hud.set_hud_visible(show_state)
		elif hud.has_method("_set_visible_state"):
			hud._set_visible_state(show_state)

func _on_settings_button_pressed():
	if not is_open or UIRouter.has_overlay():
		return

	# 修复：使用@export 的资源而不是 preload
	if not settings_scene_resource:
		push_error("GameSettingScene: settings_scene_resource 未配置！")
		return

	var settings_page: Node = settings_scene_resource.instantiate()
	settings_page.layer = layer + 1
	# 关键修正：SettingsScene 打开时不得叠加任何暗化层。
	# 场景后方已经由 DarkOverlay 提供唯一一层暗化（单一开关状态），
	# 若再调暗全局 CanvasModulate，就会形成“多层暗化”，返回后还会残留一层无法消除。
	# 退场/淡出/挂载/入场/淡入的顺序统一由 UIRouter 定义。
	await UIRouter.open_overlay(settings_page, self)

func _on_main_menu_button_pressed():
	# 点击音效由 UIButtonFx 组件层在 button_down 时统一播放
	
	if not is_open or _is_closing:
		return

	_is_closing = true
	is_open = false
	
	var balloon = get_node_or_null("/root/MyBalloon")
	if balloon:
		balloon.visible = false
		if balloon.has_method("end_dialogue"):
			balloon.end_dialogue()
	
	if DialogueManager and DialogueManager.has_method("hide_balloon"):
		DialogueManager.hide_balloon()
	
	if Global.current_save_slot >= 0:
		# notify = false：从游戏内设置退回标题这一次的存档**不弹**「存档已更新」。
		# 存档提示层（AchievementToast）挂在 /root 上、跨场景存活，而这次存档发生在
		# 切场之前，提示会在标题界面上继续播完 —— 属于噪声。
		SaveManager.save_game(Global.current_save_slot, Global.get_save_data(), false)

	set_input_locked(true)
	# 点了关闭按钮就**立刻**恢复暂停与游戏计时，不等退场动画 / 黑幕渐变播完。
	_resume_game_now()
	# 记下黑幕渐亮起始时间戳
	var fade_started_ms: int = Time.get_ticks_msec()
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.fade_out_overlay(self, OverlaySpec.OVERLAY_FADE_DURATION)
	# 世界亮度与黑幕同时恢复
	_restore_game_lighting()
	# 退场动画交给动效总线
	await ui_exit()
	# 等黑幕渐亮完再关掉遮罩
	await _wait_overlay_fade(fade_started_ms)
	if DarkOverlay and is_instance_valid(DarkOverlay):
		DarkOverlay.hide_overlay()
	# 关键修正：等待亮度恢复完成后再切换场景，避免补间随场景销毁而中断。
	await _restore_game_lighting()
	var switched: bool = await SceneManager.return_to_title_from_game_setting(false)
	if switched:
		# 本面板是挂在 /root 上的（不属于任何场景），换场景不会把它带走 ——
		# 必须显式销毁，否则它会留在 /root 里继续吞掉所有按键：
		# 表现就是「从游戏内设置返回标题、再开新游戏后，空格推不动对话」。
		queue_free()
	else:
		_is_closing = false
		is_open = true
		set_input_locked(false)

func _exit_tree():
	if is_open:
		is_open = false
		get_tree().paused = false
		# 节点即将销毁，补间无法完成，必须立即恢复亮度。
		_restore_game_lighting_immediate()

## 等黑幕渐亮剩余的时间（started_ms 是开始渐亮时记下的 Time.get_ticks_msec()）
## 黑幕由 DarkOverlay 持有，计时必须按真实时间算 —— 页面自己的退场动画时长与它无关。
func _wait_overlay_fade(started_ms: int) -> void:
	var elapsed: float = float(Time.get_ticks_msec() - started_ms) / 1000.0
	var remaining: float = OverlaySpec.OVERLAY_FADE_DURATION - elapsed
	if remaining > 0.0:
		await wait_seconds(remaining)


## 立即恢复全局亮度（无补间）——用于节点即将被销毁的情况。
func _restore_game_lighting_immediate() -> void:
	if not _is_game_lighting_dimmed:
		return
	if game_canvas_modulate and is_instance_valid(game_canvas_modulate):
		game_canvas_modulate.color = original_modulate_color
		_is_game_lighting_dimmed = false

func _set_menu_buttons_enabled(enabled: bool) -> void:
	continue_button.disabled = not enabled
	settings_button.disabled = not enabled
	main_menu_button.disabled = not enabled
