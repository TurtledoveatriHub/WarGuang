extends UIPopupPanel
## 游戏成就弹窗：每页 5 个成就（图标 + 描述纵向排列）。
## 分页：鼠标点分页按钮，或键盘 A/D（left / right 动作，含方向键）切页，切页带出/入场动画。
## 成就定义来自 AchievementManager（目录：Assets/Configs/AchievementCatalog.tres）。
##
## 「每页 5 个」是硬约束（与场景里预置的 5 个成就行一致）；
## 分页按钮也在场景里预置好（编辑器里可见、样式可调），页数超过按钮数量时会 push_warning。

## 每页显示的成就数量（必须与场景里 Rows 下预置的成就行数量一致）
const ROWS_PER_PAGE: int = 5

@export_category("切页动画")
## 当前页出场时长（秒）
@export var page_exit_duration: float = 0.16
## 新页入场时长（秒）
@export var page_enter_duration: float = 0.22
## 切页时的位移量（像素，向下漂移）
@export var page_drift_distance: float = 14.0
## 出场结束时缩小到多少倍（0.04 ≈ 收成一点）
@export var page_exit_min_scale: float = 0.04
## 入场起始的放大倍率
@export var page_peak_scale: float = 1.06
## 切页缩放的轴心（RowsRoot 父坐标系里的点）。
## **必须与面板整体开合的缩放轴心重合**：面板开合缩放的是 PanelContentRoot，轴心就是
## 它自己的原点（场景里已把它放在成就列表中心），而 RowsRoot 正好就在它的原点上 ——
## 所以这里填 (0, 0)，开合与切页就绕同一个点缩放，两边效果一致。
## （改成别的值只影响切页，两者就又对不上了。）
@export var page_scale_pivot: Vector2 = Vector2.ZERO

@onready var rows_root: Node2D = $PanelContentRoot/RowsRoot
@onready var rows_container: VBoxContainer = $PanelContentRoot/RowsRoot/Rows
@onready var page_buttons_root: HBoxContainer = $PageButtonsRoot
## 临时调试按钮：清空所有成就解锁记录（正式发布前把它和 _on_reset_pressed 一起删掉）。
@onready var reset_button: TextureButton = get_node_or_null("ResetButton")

## 5 个成就行（场景里预置，横向内容：图标 + 描述）
var _rows: Array[Node] = []
## 分页按钮（场景里预置，数量即为最多支持的页数）
var _page_buttons: Array[TextureButton] = []
var _page_count: int = 1
var _current_page: int = 0
var _switching: bool = false
## 成就列表的基态（切页动画每次都从这里出发）
var _base_position: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	super._ready()
	_rows = rows_container.get_children()
	for child in page_buttons_root.get_children():
		if child is TextureButton:
			_page_buttons.append(child as TextureButton)
			child.pressed.connect(_on_page_button_pressed.bind(_page_buttons.size() - 1))
	if reset_button != null:
		reset_button.pressed.connect(_on_reset_pressed)
	# 基态必须在总线把 RowsRoot **之外**的节点摆成入场起始态之后读 ——
	# RowsRoot 的父节点 PanelContentRoot 才是总线目标，所以这里的值永远是编辑器里的原值。
	_base_position = rows_root.position
	_base_scale = rows_root.scale
	_compute_page_count()
	_show_page(0)
	_apply_page_buttons()


func _input(event: InputEvent) -> void:
	super._input(event)
	if _closing or _switching:
		return
	if event.is_action_pressed("left") or event.is_action_pressed("ui_left"):
		get_viewport().set_input_as_handled()
		_switch_page(-1)
	elif event.is_action_pressed("right") or event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()
		_switch_page(1)


# ════════════════════════════════════════════════════════════
# 分页
# ════════════════════════════════════════════════════════════

func _compute_page_count() -> void:
	var total: int = AchievementManager.get_total_count()
	_page_count = maxi(1, int(ceil(float(total) / float(ROWS_PER_PAGE))))
	# 成就多到分页按钮不够时明确报出来，而不是让后面的页悄悄点不到。
	if _page_count > _page_buttons.size():
		push_warning("AchievementScene: 成就共 %d 页，但场景里只有 %d 个分页按钮。请照 PageButton1 再复制几个。" % [_page_count, _page_buttons.size()])
		_page_count = _page_buttons.size()


func _on_page_button_pressed(page_index: int) -> void:
	if _switching or page_index == _current_page:
		return
	_switch_page_to(page_index)


func _switch_page(delta: int) -> void:
	if _page_count <= 1:
		return
	_switch_page_to(wrapi(_current_page + delta, 0, _page_count))


## 切页：先让旧页出场 → 换内容 → 新页入场。
## 选中态在点击瞬间就切好，玩家点下去立刻有反馈（与设置界面的分类按钮同理）。
func _switch_page_to(page_index: int) -> void:
	if page_index == _current_page:
		return
	_switching = true
	_apply_page_buttons(page_index)
	await _play_page_exit()
	_current_page = page_index
	_show_page(_current_page)
	await _play_page_enter()
	_switching = false


## 把第 page_index 页的内容填进 5 行（不足 5 个的行隐藏）。
func _show_page(page_index: int) -> void:
	var definitions: Array[AchievementData] = AchievementManager.get_achievements()
	var start: int = page_index * ROWS_PER_PAGE
	for i in _rows.size():
		var data_index: int = start + i
		var data: AchievementData = definitions[data_index] if data_index < definitions.size() else null
		_rows[i].visible = data != null
		if data != null:
			_rows[i].call("apply", data, AchievementManager.is_unlocked(data.id))


## 分页按钮：当前页保持「按下」外观，切页时旧按钮自己把按下态收回去。
func _apply_page_buttons(active_page: int = -1) -> void:
	var active: int = _current_page if active_page < 0 else active_page
	for i in _page_buttons.size():
		var button: TextureButton = _page_buttons[i]
		button.visible = i < _page_count
		button.toggle_mode = true
		button.button_pressed = i == active
		if button.has_method("set_locked_visual"):
			button.call("set_locked_visual", i == active)


## 临时调试：清空所有成就解锁记录，方便反复测试「未解锁 → 已解锁」的变化。
func _on_reset_pressed() -> void:
	AchievementManager.reset_all()
	_compute_page_count()
	_current_page = 0
	_show_page(0)
	_apply_page_buttons()


# ════════════════════════════════════════════════════════════
# 切页动画（绕 page_scale_pivot 缩放，与设置界面切页同一套算法）
# ════════════════════════════════════════════════════════════

## 绕 page_scale_pivot 缩放 factor 倍时该有的位置：
## 位置是倍率的仿射函数，与缩放用同一缓动即可保证全程绕该点缩放。
func _pivot_position(base: Vector2, factor: float, extra: Vector2 = Vector2.ZERO) -> Vector2:
	return page_scale_pivot + (base - page_scale_pivot) * factor + extra


func _play_page_exit() -> void:
	rows_root.position = _base_position
	rows_root.scale = _base_scale
	var target_position: Vector2 = _pivot_position(_base_position, page_exit_min_scale, Vector2(0.0, page_drift_distance))
	var target_scale: Vector2 = _base_scale * page_exit_min_scale
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(rows_root, "position", target_position, page_exit_duration)
	tween.parallel().tween_property(rows_root, "scale", target_scale, page_exit_duration)
	tween.parallel().tween_property(rows_root, "modulate:a", 0.0, page_exit_duration)
	# 用「时长等待」而不是 await tween.finished（本项目约定：Tween 被 kill 时信号不会发）。
	await _wait(page_exit_duration)
	rows_root.position = target_position
	rows_root.scale = target_scale
	rows_root.modulate.a = 0.0


func _play_page_enter() -> void:
	rows_root.position = _pivot_position(_base_position, page_peak_scale, Vector2(0.0, page_drift_distance))
	rows_root.scale = _base_scale * page_peak_scale
	rows_root.modulate.a = 0.0
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(rows_root, "position", _base_position, page_enter_duration)
	tween.parallel().tween_property(rows_root, "scale", _base_scale, page_enter_duration)
	tween.parallel().tween_property(rows_root, "modulate:a", 1.0, page_enter_duration)
	await _wait(page_enter_duration)
	rows_root.position = _base_position
	rows_root.scale = _base_scale
	rows_root.modulate.a = 1.0


func _wait(seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout
