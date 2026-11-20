class_name UIRouter
extends RefCounted
## UI 路由——**全项目唯一定义「页面怎么切」的地方**（纯静态工具类，无需挂到场景树上）。
##
## 以前「退场动画 → 黑屏 → 换场景/挂载 → 入场动画 → 淡入」这套顺序被抄在
## TitleScene / SaveSelectScene / GameSettingScene / SceneManager 里各写一遍，
## 每处的 await 顺序、时长、谁先谁后都不完全一致——这正是 UI 逻辑难维护的主因。
## 现在业务层只喊一句：
##     await UIRouter.goto_scene(ScenePaths.UI_SAVE_SELECT)
##     await UIRouter.open_overlay(page, self)
##     await UIRouter.close_overlay()
##     UIRouter.quit_game(1.0)
##
## 页面只需要实现 UIScene 的 `ui_enter()` / `ui_exit()`（基类已提供），
## 路由层负责把它们与黑屏过渡串成唯一一条标准时间线。
##
## 为什么不用 autoload：路由是**无状态纯逻辑**，不需要节点，也不需要被场景树访问；
## 静态类同时避免「新增 autoload 后编辑器必须重载项目」这一坑。

## 是否正在转场（防止连点重入）。
static var _busy: bool = false
## _busy 置位的时刻（毫秒），用于防呆超时。
static var _busy_since_ms: int = 0
## _busy 防呆超时（毫秒）。转场协程若因脚本错误 / 节点被释放而中断，
## `_busy = false` 那一行就永远不会执行，表现为「ESC 与返回按钮从此全部失效」。
## 超过这个时长就自动放行，宁可重复触发一次也不能卡死。
const BUSY_STALE_TIMEOUT_MS: int = 10000

## 转场阶段（只用于观察/调试；busy 判定仍由 _busy + 防呆超时负责）。
## 把「现在到底卡在哪一步」变成可读状态，调试 HUD / 日志直接显示 get_phase_name() 即可。
enum Phase { IDLE = 0, EXITING = 1, BLACK = 2, ENTERING = 3 }
static var _phase: int = Phase.IDLE
## 当前覆盖层（例如标题界面上的设置界面）。
static var _overlay: Node = null
## 覆盖层的宿主页面（关闭后需要重新入场的那个页面）。
static var _overlay_owner: Node = null


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


# ════════════════════════════════════════════════════════════
# 场景切换
# ════════════════════════════════════════════════════════════

## 当前页面（当前场景根节点，且它实现了 UIScene 的 ui_enter）。
static func get_current_page() -> Node:
	var tree: SceneTree = _tree()
	if tree == null:
		return null
	var scene: Node = tree.current_scene
	if scene != null and scene.has_method("ui_enter"):
		return scene
	return null


static func is_busy() -> bool:
	# 防呆：转场协程被中断时 _busy 会永久为 true —— 这里超时自动放行。
	if _busy and _busy_since_ms > 0 and Time.get_ticks_msec() - _busy_since_ms > BUSY_STALE_TIMEOUT_MS:
		push_warning("UIRouter: 转场锁超时，自动恢复（ESC / 返回重新可用）。")
		_busy = false
		_busy_since_ms = 0
	return _busy


## 统一写转场锁（带时间戳，供 is_busy() 做防呆超时）。
static func _set_busy(value: bool) -> void:
	_busy = value
	_busy_since_ms = Time.get_ticks_msec() if value else 0


## 当前转场阶段（调试用）。
static func get_phase() -> int:
	return _phase


## 当前阶段名（调试 HUD / 日志用）。
static func get_phase_name() -> String:
	match _phase:
		Phase.EXITING:
			return "EXITING"
		Phase.BLACK:
			return "BLACK"
		Phase.ENTERING:
			return "ENTERING"
		_:
			return "IDLE"


## 由 SceneManager 在切场过程中标注黑屏 / 入场阶段（路由自身不判断黑屏时机）。
static func set_phase(phase: int) -> void:
	_phase = phase


static func has_overlay() -> bool:
	return _overlay != null and is_instance_valid(_overlay)


## 切到另一个 UI 场景。顺序：当前页退场 → 黑屏 → 换场景 → 新页入场 → 淡入。
## （SceneManager.switch_scene 内部已包含 淡出 / change_scene / 新页 ui_enter / 淡入）
static func goto_scene(scene_path: String) -> void:
	if is_busy():
		return
	_set_busy(true)
	_phase = Phase.EXITING
	var page: Node = get_current_page()
	if page != null:
		await page.call("ui_exit")
	await SceneManager.switch_scene(scene_path)
	_set_busy(false)
	_phase = Phase.IDLE


# ════════════════════════════════════════════════════════════
# 覆盖层（标题 ↔ 设置 这类「不换场景」的叠加页面）
# ════════════════════════════════════════════════════════════

## 打开覆盖层：宿主页面退场并进入「被覆盖」状态 → 淡出 → 挂载 → 覆盖层入场 → 淡入。
## （必须先淡出再挂载，否则覆盖层会在淡出过程中提前显形。）
static func open_overlay(page: Node, owner_page: Node = null) -> void:
	if page == null or has_overlay():
		return
	var owner: Node = owner_page if owner_page != null else get_current_page()
	_overlay_owner = owner
	_phase = Phase.EXITING
	if owner != null and owner.has_method("ui_exit"):
		await owner.call("ui_exit")
	if owner != null and owner.has_method("set_overlay_active"):
		owner.call("set_overlay_active", true)
	_phase = Phase.BLACK
	await FadeManager.fade_out(FadeManager.ui_switch_fade_out_duration)
	_overlay = page
	_tree().root.add_child(page)
	# 先摆位（黑幕仍然遮着屏幕），等淡入结束再播入场动画。
	if page.has_method("ui_prepare_enter"):
		page.call("ui_prepare_enter")
	_phase = Phase.ENTERING
	await FadeManager.fade_in(FadeManager.ui_switch_fade_in_duration)
	if page.has_method("ui_enter"):
		await page.call("ui_enter")
	_phase = Phase.IDLE


## 关闭覆盖层：覆盖层退场 → 淡出 → 释放 → 宿主页面重新入场 → 淡入。
static func close_overlay() -> void:
	if not has_overlay():
		return
	var page: Node = _overlay
	_overlay = null
	_phase = Phase.EXITING
	if page.has_method("ui_exit"):
		await page.call("ui_exit")
	_phase = Phase.BLACK
	await FadeManager.fade_out(FadeManager.ui_switch_fade_out_duration)
	if is_instance_valid(page):
		page.queue_free()
	var owner: Node = _overlay_owner
	_overlay_owner = null
	if owner != null and is_instance_valid(owner):
		if owner.has_method("set_overlay_active"):
			owner.call("set_overlay_active", false)
		# 宿主页面同样先摆位、再淡入、最后播入场动画。
		if owner.has_method("ui_prepare_enter"):
			owner.call("ui_prepare_enter")
	_phase = Phase.ENTERING
	await FadeManager.fade_in(FadeManager.ui_switch_fade_in_duration)
	if owner != null and is_instance_valid(owner) and owner.has_method("ui_enter"):
		await owner.call("ui_enter")
	_phase = Phase.IDLE


# ════════════════════════════════════════════════════════════
# 退出游戏
# ════════════════════════════════════════════════════════════

## 黑屏后退出。退场动画与黑屏**并行**推进（不等退场动画播完），保证点击瞬间就有反馈。
static func quit_game(fade_duration: float = 1.0) -> void:
	if is_busy():
		return
	_set_busy(true)
	# 先停音频再利用淡出时间：停止 Ogg 流式播放是异步的，
	# 只有提前停、并留出足够时长，混音线程才会真正把 AudioStreamPlaybackOggVorbis 释放掉；
	# 否则退出时引擎会报 "ObjectDB instances leaked at exit / 2 resources still in use"。
	_release_audio_before_quit()
	FadeManager.fade_out(fade_duration)
	var page: Node = get_current_page()
	if page != null and page.has_method("ui_exit"):
		page.call("ui_exit")
	await _tree().create_timer(fade_duration).timeout
	await _tree().process_frame
	await _tree().process_frame
	_tree().quit()


## 退出前释放音频引用。
## 标题场景把 BGM 以 @export 强引用挂在场景实例上，直接 quit 会让 AudioStreamOggVorbis
## 在引擎资源清理阶段仍被引用，表现为关闭游戏时打印
## "ObjectDB instances leaked at exit" 与 "2 resources still in use"（探险.ogg）。
static func _release_audio_before_quit() -> void:
	var root := _tree().root
	if root == null:
		return
	var audio_manager: Node = root.get_node_or_null("AudioManager")
	if audio_manager == null:
		return
	if audio_manager.has_method("stop_all_for_exit"):
		audio_manager.call("stop_all_for_exit")
	# 释放当前 UI 页面持有的音频导出引用（例如 TitleScene.title_bgm_stream）。
	var page: Node = get_current_page()
	if page != null:
		for prop in page.get_property_list():
			if str(prop.get("name", "")).contains("bgm") and prop.get("type", 0) == TYPE_OBJECT:
				page.set(str(prop["name"]), null)
