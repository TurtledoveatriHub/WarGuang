extends Node

var _scene_switch_in_progress: bool = false
var _scene_switch_started_ms: int = -1
const _SCENE_SWITCH_STALE_TIMEOUT_MS: int = 12000

# UI 场景切换统一入口（普通 UI 场景之间）。
func switch_scene(scene_path: String):
	if not _begin_scene_switch("switch_scene -> %s" % scene_path):
		return
	if scene_path != ScenePaths.GAME_MAIN and Global:
		Global.stop_play_time_session()

	# 修复：切换场景前确保结束当前对话
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	if dialogue_system and dialogue_system.is_dialogue_active:
		dialogue_system.end_dialogue()

	var target_bgm = _resolve_target_bgm(scene_path)
	await _do_scene_transition(
		scene_path,
		FadeManager.ui_switch_fade_out_duration,
		FadeManager.ui_switch_black_hold_duration,
		FadeManager.ui_switch_fade_in_duration,
		target_bgm
	)
	_end_scene_switch()
	print("场景切换完成")

# 特殊处理：从 GameSettingScene 返回到 TitleScene
func return_to_title_from_game_setting(already_black: bool = false) -> bool:
	if not _begin_scene_switch("return_to_title_from_game_setting"):
		if already_black and FadeManager and FadeManager.has_method("is_fully_black") and FadeManager.is_fully_black():
			if FadeManager.has_method("force_fade_in"):
				FadeManager.force_fade_in()
		return false
	if Global:
		Global.stop_play_time_session()

	if already_black:
		AudioManager.stop_bgm_stream()
		await _do_scene_transition(
			ScenePaths.UI_TITLE,
			0.0,
			FadeManager.ui_switch_black_hold_duration,
			FadeManager.ui_switch_fade_in_duration,
			""  # BGM 由 TitleScene._ready() 通过 @export title_bgm_stream 播放
		)
	else:
		await _do_scene_transition(
			ScenePaths.UI_TITLE,
			FadeManager.ui_switch_fade_out_duration,
			FadeManager.ui_switch_black_hold_duration,
			FadeManager.ui_switch_fade_in_duration,
			""  # BGM 由 TitleScene._ready() 通过 @export title_bgm_stream 播放
		)
	# 暂停已在 _do_scene_transition() 换场后统一解除，这里不再重复。

	_end_scene_switch()
	return true

## 等主场景真正有画面可看（房间已加载 + 视口又渲染了几帧）再淡入。
## 最长等 2 秒，超时就照常淡入，绝不把玩家卡在黑幕里。
func _wait_room_ready_for_reveal() -> void:
	var deadline_ms: int = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline_ms:
		var room_manager: Node = get_node_or_null("/root/RoomManager")
		if room_manager == null or str(room_manager.get("current_room")) != "":
			break
		await get_tree().process_frame
	# 再多等两帧，确保这一帧的画面已经真的画出来
	await get_tree().process_frame
	await get_tree().process_frame


## 把 PhantomCamera 瞬间对齐到玩家（跳过跟随阻尼），避免进场时先看到相机「飞过去」。
## 优先用 PhantomCamera2D.teleport_position()；没有 PCam 时退回直接摆 Camera2D。
func _snap_phantom_camera_to_player() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var player: Node = tree.get_first_node_in_group("player")
	if player == null or not is_instance_valid(player) or not (player is Node2D):
		return
	var phantom: Node = player.get_node_or_null("PhantomCamera2D")
	if phantom != null and phantom.has_method("teleport_position"):
		phantom.call("teleport_position")
		return
	var viewport: Viewport = player.get_viewport()
	if viewport == null:
		return
	var camera: Camera2D = viewport.get_camera_2d()
	if camera != null:
		camera.global_position = (player as Node2D).global_position


# 从存档进入游戏
func start_game_from_save(slot_index: int):
	if not _begin_scene_switch("start_game_from_save"):
		return

	# 新增：清理门注册（防止从标题重新进入时重复注册）
	var door_manager = get_node_or_null("/root/DoorManager")
	if door_manager and door_manager.has_method("clear_all_doors"):
		door_manager.clear_all_doors()
	
	Global.current_save_slot = slot_index
	# 当前槽位是否已经存在真实存档文件。
	var save_exists: bool = SaveManager.save_exists(slot_index)
	var is_new_save_opening: bool = not save_exists
	
	# 记录开始时间（从点击存档开始）
	var start_time = Time.get_ticks_msec()
	
	# 加载存档数据
	if save_exists:
		if Global and Global.has_method("clear_boot_cinematic_request"):
			Global.clear_boot_cinematic_request()
		var data = SaveManager.load_game(slot_index)
		if not data.is_empty():
			Global.load_save_data(data)
		else:
			Global.initialize_new_game()
			SaveManager.save_game(slot_index, Global.get_save_data())
	else:
		Global.initialize_new_game()
		if Global and Global.has_method("request_boot_cinematic"):
			Global.request_boot_cinematic(&"new_save_opening")
		SaveManager.save_game(slot_index, Global.get_save_data())
	
	# 确保 TaskManager 重置 NPC 状态
	var task_manager = get_node_or_null("/root/TaskManager")
	if task_manager and task_manager.has_method("reset_for_scene_load"):
		task_manager.reset_for_scene_load()
	
	# 存档进游戏采用专用流程：淡出 -> 全黑保持 -> 切场并等待主场景可视准备 -> 淡入。
	var black_start_ms: int = Time.get_ticks_msec()
	# ★ 这里用真正的淡出（时长 = ui_save_to_game_fade_out_duration）。
	#   之前写的是 force_black()（瞬间全黑）→ 那个导出参数成了死参数，怎么改都没效果。
	#   淡出发生在 change_scene 之前，此时 SaveSelect 场景还活着，Tween 不会被切场截断。
	await FadeManager.fade_out(FadeManager.ui_save_to_game_fade_out_duration)
	# 以「刚刚全黑」为起点重新计时，这样 ui_save_to_game_black_hold_duration 就是真实的全黑时长
	black_start_ms = Time.get_ticks_msec()
	# 新存档入场动画期间抑制 BGM，并停止当前标题 BGM
	if is_new_save_opening:
		AudioManager.stop_bgm_stream()
		AudioManager.set_event_bgm_suppress(true)
	get_tree().change_scene_to_file(ScenePaths.GAME_MAIN)
	if FadeManager and FadeManager.has_method("force_black"):
		FadeManager.force_black()
	await get_tree().process_frame
	if FadeManager and FadeManager.has_method("force_black"):
		FadeManager.force_black()
	var main_scene = get_tree().current_scene
	if main_scene and main_scene.has_method("wait_until_boot_visual_ready"):
		await main_scene.wait_until_boot_visual_ready()
	var elapsed_black: float = float(Time.get_ticks_msec() - black_start_ms) / 1000.0
	var remain_black: float = maxf(0.0, FadeManager.ui_save_to_game_black_hold_duration - elapsed_black)
	if remain_black > 0.0:
		await get_tree().create_timer(remain_black).timeout
	if not is_new_save_opening:
		# 清除所有残留黑幕锁，确保淡入正常执行
		# （FadeManager 是 autoload，hold_black 标签可能从之前游戏会话残留）
		if FadeManager and FadeManager.has_method("clear_black_holds"):
			FadeManager.clear_black_holds()
		# 注：相机对齐由 MainGameScene 自己负责（它在 boot_visual_ready 之前调
		# sync_camera_to_player_center(true)），这里不要再插手，否则会打乱跟随。
		await FadeManager.fade_in(FadeManager.ui_save_to_game_fade_in_duration)
	if Global:
		Global.start_play_time_session()

	# 等待一帧让淡入后的状态稳定
	await get_tree().process_frame
	
	# 确保 DialogueManager 重置
	if DialogueManager and DialogueManager.has_method("reset"):
		DialogueManager.reset()
	
	# 修复：确保 DialogueSystem 也重置
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	if dialogue_system and dialogue_system.has_method("reset"):
		dialogue_system.reset()
	
	# 强制重置 DialogueSystem 状态
	if DialogueSystem:
		DialogueSystem.is_dialogue_active = false
	
	# 确保 BGM 播放
	if RoomManager.current_room != "":
		await get_tree().create_timer(0.5).timeout
		RoomManager.switch_room_bgm(RoomManager.current_room)
	
	# 获取玩家实例
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var lock_time = player.warp_control_lock_time
		
		# 计算已用时间
		var elapsed_time = (Time.get_ticks_msec() - start_time) / 1000.0
		var remaining_time = max(0, lock_time - elapsed_time)
		
		# 等待剩余禁用时间
		if remaining_time > 0:
			await get_tree().create_timer(remaining_time).timeout
		
		# 恢复玩家控制
		player.set_player_control(true)
		player.exit_sleep_state()
		
		# 清除输入阻塞
		var viewport = get_viewport()
		if viewport:
			viewport.set_input_as_handled()

	_end_scene_switch()

func _resolve_target_bgm(_scene_path: String) -> String:
	# BGM 由各场景自行通过 @export 拖拽管理，切场时不主动播放 BGM
	return ""

func _do_scene_transition(scene_path: String, fade_out_duration: float, black_hold_duration: float, fade_in_duration: float, target_bgm: String) -> void:
	await FadeManager.fade_out(fade_out_duration)
	UIRouter.set_phase(UIRouter.Phase.BLACK)
	# 淡出结束的这一刻屏幕刚好全黑 —— 以此为起点计「全黑时长」。
	# 关键：change_scene 会花时间加载/实例化新场景（不可预测），
	# 如果直接再等 black_hold_duration，实际全黑时长就变成「加载时间 + 参数值」，
	# 这就是「调小参数黑屏依然很长」的原因。改为减去已耗时间，参数即真实全黑时长。
	var black_start_ms: int = Time.get_ticks_msec()

	if target_bgm != "":
		await AudioManager.play_bgm(target_bgm, fade_out_duration)

	get_tree().change_scene_to_file(scene_path)
	await get_tree().process_frame
	# 新场景的入场动画 / Tween / 粒子 / 灯光都靠 _process 推进：
	# 若树还停在暂停态（典型的：从游戏内设置页返回标题，那个页面会 paused = true），
	# 它们会整段冻住 —— 表现就是「卡一下、粒子要等一秒才开始动」。
	# 此时旧场景已经被换掉，立刻解除暂停是安全的。
	if get_tree().paused:
		get_tree().paused = false

	if black_hold_duration > 0.0:
		var elapsed_black: float = float(Time.get_ticks_msec() - black_start_ms) / 1000.0
		var remain_black: float = maxf(0.0, black_hold_duration - elapsed_black)
		if remain_black > 0.0:
			await get_tree().create_timer(remain_black).timeout

	# 黑幕完全遮住屏幕时只「摆位」：把所有动效轨道置为入场起始态（不播动画）。
	# 这样等下的入场动画才不会在黑幕/淡入期间被盖掉。
	var current_scene := get_tree().current_scene
	if current_scene and current_scene.has_method("ui_prepare_enter"):
		current_scene.call("ui_prepare_enter")

	# 防呆：FadeManager 是 autoload，若游戏侧过场事件（新存档开场 / 梦境房间）留下的
	# hold_black 标签没被释放，fade_in() 会直接拒绝淡入（force_black 后立即返回），
	# 表现为「参数改了也没用、黑屏异常久」。UI 场景切换与会场过场无关，清掉即可。
	if FadeManager and FadeManager.has_method("clear_black_holds"):
		FadeManager.clear_black_holds()

	# 先淡入：等黑屏过渡**完全结束**、画面完全可见，之后才播入场动画。
	# （反过来做的话，入场动画会被黑幕/淡入盖掉：轻则只看到后半段，重则已经播完）
	UIRouter.set_phase(UIRouter.Phase.ENTERING)
	await FadeManager.fade_in(fade_in_duration)

	if current_scene and current_scene.has_method("ui_enter"):
		await current_scene.call("ui_enter")
	UIRouter.set_phase(UIRouter.Phase.IDLE)

func _begin_scene_switch(tag: String) -> bool:
	if _scene_switch_in_progress:
		var now_ms: int = Time.get_ticks_msec()
		if _scene_switch_started_ms > 0 and now_ms - _scene_switch_started_ms > _SCENE_SWITCH_STALE_TIMEOUT_MS:
			print("SceneManager: 检测到切场锁超时，自动恢复。tag=", tag)
			_scene_switch_in_progress = false
			_scene_switch_started_ms = -1
		else:
			print("SceneManager: 切场请求被拒绝（进行中） tag=", tag)
			return false
	_scene_switch_in_progress = true
	_scene_switch_started_ms = Time.get_ticks_msec()
	return true

func _end_scene_switch() -> void:
	_scene_switch_in_progress = false
	_scene_switch_started_ms = -1

## 当前是否正在切场（含从存档进入游戏的整个过渡期）。
## 供外部在过渡期间屏蔽交互：过渡期间调用切场 API 会被 _begin_scene_switch() 拒绝，
## 若此时允许玩家打开菜单，菜单里的「返回主菜单 / 退回标题」按钮就会点了没反应。
func is_scene_switch_in_progress() -> bool:
	return _scene_switch_in_progress
