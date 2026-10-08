class_name UIScene
extends CanvasLayer
## 所有 UI 页面的统一基类（UI 架构重做第 1 层：页面壳层）。
##
## ── 唯一的一条生命周期路径 ──────────────────────────────────────
##     ui_enter():  锁输入 → [子类入场表现] → 动效总线入场 → 等总线空闲 → 解锁输入
##     ui_exit():   锁输入 → 动效总线退场 → 等总线空闲
##   「什么时候播什么」由动效总线（UIFxDirector）决定；「页面自己怎么开合」由
##   子类覆盖 `_on_page_enter()` / `_on_page_exit()`；「点这个按钮干什么」由业务回调决定。
##
## ── 为什么要基类 ──────────────────────────────────────────────
##   * 以前 TitleScene / SettingsScene / SaveSelectScene 各自复制了一份
##     `_ui_fx_poll_busy` / `_wait_seconds` / `_ui_loop_play_*` / `_collect_*` 等共 25 处重复定义，
##     加一个动效要同时改 4 个文件。
##   * 以前「谁先 await 谁」散落在业务代码里，曾出现 await 一次性信号导致输入锁
##     永不解除（按钮永久点不动）的严重 bug。现在全项目只有这里轮询状态、只有这里有兜底超时。
##
## ── 给子类的约定 ─────────────────────────────────────────────
##   * 只写业务，不要再自己写等待/锁/收集节点的代码。
##   * 想禁用自己的按钮：覆盖 `_on_input_lock_applied(locked)`。
##   * 入场时想额外做点什么（灯光、面板开合）：覆盖 `_on_page_enter()`（可以是协程）。
##   * ESC 返回：覆盖 `_on_ui_cancel()`。

@export_category("动效总线")
## 动效总线节点路径（场景里有 UIFxDirector 节点时自动找到；没有则自动创建）。
@export var fx_bus_path: NodePath = ^"UIFxDirector"
## 是否使用动效总线。页面自带整体开合动画、不希望按钮再参与错开入场时可设为 false。
@export var use_fx_bus: bool = true
## 等动效播完的兜底超时（秒）：即使动效系统异常，输入锁也一定会解除。
## 默认 4 秒（入场/退场动画正常都在 1 秒内）；设太大会让异常时玩家干等很久。
@export var fx_deadline_seconds: float = 4.0

@export_category("输入")
## 锁定输入时是否同时吞掉鼠标事件（设置界面锁定期间仍要点按钮 → 设为 false）。
@export var lock_swallows_mouse: bool = true
## 覆盖层打开时是否让鼠标事件穿透到覆盖层（默认 true，否则会挡住上层的设置界面按钮）。
@export var overlay_pass_through_input: bool = true

## 当前输入锁状态。
var _input_locked: bool = true
## 是否处于「被上层覆盖层盖住」状态。
var _overlay_active: bool = false
## 是否已经进入退场流程（防止 ESC 在退场途中重复触发返回）。
var _exit_started: bool = false
## 本页入场动画是否已播完（ESC 必须等它播完才允许触发，否则退场动画会打断入场）。
var _enter_done: bool = false
## 动效总线缓存。
var _fx_bus: Node = null
## 循环动画节点缓存（没有总线时的降级路径用）。
var _ui_loop_animators: Array[Node] = []


# ════════════════════════════════════════════════════════════
# 生命周期
# ════════════════════════════════════════════════════════════

## 进树时显式打开输入回调。
## `_input` / `_unhandled_input` 定义在基类，显式启用可避免
## 「子类脚本未声明这两个回调 → 引擎不启用回调」这种不确定行为。
func _enter_tree() -> void:
	set_process_input(true)
	set_process_unhandled_input(true)


## 播放入场：锁输入 → 子类入场表现 → 动效总线入场 → 解锁。协程，调用方需 await。
func ui_enter() -> void:
	_overlay_active = false
	_exit_started = false
	_enter_done = false
	set_input_locked(true)
	# 调用方（SceneManager / UIRouter）没在黑屏期间 prepare 过时兜底补一次
	# （例如编辑器直接运行本场景），保证入场动画一定从起始态开始。
	ui_prepare_enter()
	# 基类默认实现不是协程，但子类会覆写成协程，所以这里必须保留 await。
	# 「有 await 的也会被当作协程」→ 子类里请勿在这里 await 帧/时长，
	# 否则入场动画会晚一帧才开始，表现为「先完整显示一帧、再补入动画」的闪动。
	@warning_ignore("redundant_await")
	await _on_page_enter()
	_play_fx_enter()
	await ui_await_idle()
	_enter_done = true
	set_input_locked(false)


## 只把本页所有动效轨道摆到「入场起始态」，**不播动画、不加锁**。
## 由 SceneManager / UIRouter 在「屏幕被黑幕完全遮住」时调用；
## 之后再淡入，淡入结束后才 ui_enter() 播入场动画 —— 这样黑屏过渡与入场动画不重叠
## （过去两者重叠：入场动画播完了、玩家才看到画面，或者只看到动画的后半段）。
func ui_prepare_enter() -> void:
	var bus: Node = _get_fx_bus()
	if bus != null and bus.has_method("prepare_enter"):
		bus.call("prepare_enter")


## 播放退场：锁输入 → 动效总线退场。**结束后不解锁**（页面随即会被销毁/覆盖）。
func ui_exit() -> void:
	_exit_started = true
	set_input_locked(true)
	@warning_ignore("redundant_await")
	await _on_page_exit()
	_play_fx_exit()
	await ui_await_idle()


## 动效是否还在播。
func ui_is_busy() -> bool:
	var bus: Node = _get_fx_bus(false)
	if bus != null and bus.has_method("is_busy"):
		return bool(bus.call("is_busy"))
	return false


## 等动效播完（轮询状态 + 兜底超时）。
## **绝不要 await 动效信号**：Godot 4 中调用协程不返回可等待对象，
## 且信号可能在调用方开始等待之前就已发出 → 永久等待 → 输入锁永不解除。
func ui_await_idle() -> void:
	var deadline_ms: int = Time.get_ticks_msec() + int(maxf(fx_deadline_seconds, 0.0) * 1000.0)
	while ui_is_busy() and Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame
	# 走到这里还 busy = 动效系统出状况了（时长被改得过大 / Tween 被 kill 后没人接替），
	# 强制放行并把原因喊出来，避免以后又变成「莫名其妙卡住」的悬案。
	if ui_is_busy():
		push_warning("UIScene(%s): 动效等待超过 %.1fs，强制解除输入锁。请检查动效时长与 Tween 生命周期。" % [name, fx_deadline_seconds])


## 场景自行打开时（编辑器直接运行 / 非黑屏切换）自动入场；
## 由 UIRouter / SceneManager 在黑屏下打开的场景，则由调用方显式 `ui_enter()`。
func auto_enter_unless_black() -> void:
	if FadeManager and FadeManager.has_method("get_black_alpha") and FadeManager.get_black_alpha() > 0.01:
		return
	call_deferred("ui_enter")


## 子类覆盖：本页面自己的入场表现。
## **不要在这里 await**（帧 / 时长都不行）：本函数返回后基类才会让动效总线把所有组件
## 置为「起始态」，一旦你在这里等一帧，就会出现「先完整显示一帧、再补入场动画」的闪动。
func _on_page_enter() -> void:
	pass


## 子类覆盖：本页面自己的退场表现。同样不要在里 await。
func _on_page_exit() -> void:
	pass


# ════════════════════════════════════════════════════════════
# 输入锁
# ════════════════════════════════════════════════════════════

## 设置输入锁。子类请覆盖 `_on_input_lock_applied` 而不是本函数。
func set_input_locked(locked: bool) -> void:
	_input_locked = locked
	_on_input_lock_applied(locked)


func is_input_locked() -> bool:
	return _input_locked


## 覆盖层（如标题界面上的设置界面）打开/关闭。
func set_overlay_active(active: bool) -> void:
	_overlay_active = active
	if active:
		# 被覆盖层盖住：先锁住自己，避免穿透点击。解锁交给之后的 ui_enter()。
		set_input_locked(true)


## 是否正被上层覆盖层盖住。
func is_overlay_active() -> bool:
	return _overlay_active


## 输入锁当前是否**真正生效**（生效时会吞掉键鼠事件）。
## 覆盖层打开时必须返回 false，否则本页面会把事件吞掉、上层覆盖层的按钮点不动。
func is_input_lock_effective() -> bool:
	if _overlay_active and overlay_pass_through_input:
		return false
	return _input_locked


## 子类覆盖：把输入锁状态应用到自己页面内的可交互控件上。
## 默认什么都不做——不同页面的按钮集合与禁用策略差异很大，
## 基类做「递归禁用所有 Button」会误伤隐形热区、且会改变 disabled 贴图。
func _on_input_lock_applied(_locked: bool) -> void:
	pass


## 子类覆盖：ESC / 返回键。只在输入未锁定时触发。
func _on_ui_cancel() -> void:
	pass


func _input(event: InputEvent) -> void:
	# ESC（ui_cancel）永远不被输入锁吞掉：输入锁只用来防连点，
	# 过去它会让「入场/退场动画播放期间按 ESC 毫无反应」，表现成「ESC 返回失效」。
	# 这里放在吞噬之前处理，并用 _exit_started 防止退场途中重复触发。
	# 被覆盖层盖住的宿主页面不处理（交给上层覆盖层）。
	# TODO 定位「空格/ESC 失效」后连同其它 [UIIN] 打印一起删除。
	if event.is_action_pressed("ui_cancel"):
		print("[UIIN][%s] ESC：_exit_started=%s _enter_done=%s overlay=%s locked=%s" % [
			name, _exit_started, _enter_done, is_overlay_active(), _input_locked
		])
	if not _exit_started and _enter_done and not is_overlay_active() and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_ui_cancel()
		return
	if not is_input_lock_effective():
		return
	if event is InputEventKey or event is InputEventJoypadButton:
		# TODO 定位用：本行出现就说明这个页面刚刚把按键吞了（它此刻还锁着输入）。
		if event is InputEventKey and event.pressed:
			print("[UIIN][%s] 输入锁生效，吞掉按键 %s（visible=%s overlay=%s）" % [
				name, event.as_text(), visible, is_overlay_active()
			])
		get_viewport().set_input_as_handled()
		return
	if lock_swallows_mouse and event is InputEventMouseButton:
		get_viewport().set_input_as_handled()


## 子类在 `_ready` 里调用：显式接管 ESC（只在未锁定时触发 `_on_ui_cancel`）。
func _ensure_cancel_handling() -> void:
	set_process_input(true)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if is_input_locked():
		return
	if event.is_action_pressed("ui_cancel"):
		_on_ui_cancel()


# ════════════════════════════════════════════════════════════
# 动效总线
# ════════════════════════════════════════════════════════════

## 取得动效总线。`create_if_missing = true` 时，场景若没有显式放总线节点就自动创建一个，
## 保证**所有页面走同一条动效路径**，业务层不需要关心自己有没有放节点。
func _get_fx_bus(create_if_missing: bool = true) -> Node:
	if not use_fx_bus:
		return null
	if _fx_bus != null and is_instance_valid(_fx_bus):
		return _fx_bus
	_fx_bus = get_node_or_null(fx_bus_path)
	if _fx_bus == null and create_if_missing:
		var bus: Node = UIFxDirector.new()
		bus.name = "UIFxDirector"
		add_child(bus)
		_fx_bus = bus
	return _fx_bus


func _play_fx_enter() -> void:
	var bus: Node = _get_fx_bus()
	if bus != null:
		bus.call("play_enter")
		return
	_play_loop_animators(true)


func _play_fx_exit() -> void:
	var bus: Node = _get_fx_bus()
	if bus != null:
		bus.call("play_exit")
		return
	_play_loop_animators(false)


## 降级路径（`use_fx_bus = false`）：只驱动常态循环动画。
func _play_loop_animators(forward: bool) -> void:
	for animator in get_ui_loop_animators():
		animator.call("play_enter" if forward else "play_exit")


# ════════════════════════════════════════════════════════════
# 通用工具（以前每个页面各复制一份）
# ════════════════════════════════════════════════════════════

## 等待固定时长（协程）。**不要用 await Tween.finished**：被 kill 的 Tween 不会发 finished。
func wait_seconds(seconds: float) -> void:
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds, true, false, false).timeout


## 收集本页面内所有 UILoopAnimator（递归扫描、不依赖节点名；节点被编辑器改名也不会失效）。
func get_ui_loop_animators() -> Array[Node]:
	for animator in _ui_loop_animators:
		if not is_instance_valid(animator) or not is_ancestor_of(animator):
			_ui_loop_animators.clear()
			break
	if _ui_loop_animators.is_empty():
		_collect_ui_loop_animators(self, _ui_loop_animators)
	return _ui_loop_animators


func _collect_ui_loop_animators(node: Node, acc: Array[Node]) -> void:
	for child in node.get_children():
		var script_ref: Script = child.get_script()
		if child is AnimatedSprite2D and script_ref != null and str(script_ref.resource_path).ends_with("UILoopAnimator.gd"):
			acc.append(child)
		_collect_ui_loop_animators(child, acc)


## 收集本页面内所有「动效组件」（鸭子类型：play_enter + play_exit + get_fx_duration）。
func get_fx_components() -> Array[Node]:
	var found: Array[Node] = []
	_collect_fx_components(self, found)
	return found


func _collect_fx_components(node: Node, acc: Array[Node]) -> void:
	for child in node.get_children():
		if child.has_method("play_enter") and child.has_method("play_exit") and child.has_method("get_fx_duration"):
			acc.append(child)
		_collect_fx_components(child, acc)


## 统一启用/禁用一组按钮（页面自己决定禁用哪些）。
func set_buttons_disabled(buttons: Array, locked: bool) -> void:
	for b in buttons:
		if b is BaseButton and is_instance_valid(b):
			(b as BaseButton).disabled = locked


# ════════════════════════════════════════════════════════════
# 兼容别名（旧调用点仍可用，新代码请用上面的规范名）
# ════════════════════════════════════════════════════════════

## 旧名 → ui_enter()。保留是为了既有的 SceneManager / 覆盖层调用点不需要同时改。
func _on_scene_transition_enter_begin() -> void:
	await ui_enter()


## 旧名 → set_input_locked()。
func _set_scene_input_locked(locked: bool) -> void:
	set_input_locked(locked)


## 旧名 → is_input_locked()。
func is_scene_interaction_locked() -> bool:
	return is_input_locked()


## 旧名 → wait_seconds()。
func _wait_seconds(seconds: float) -> void:
	await wait_seconds(seconds)
