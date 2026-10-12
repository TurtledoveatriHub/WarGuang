extends CanvasLayer
## 成就达成提示（屏幕右下角，独立于 PlayerUI）。
##
## ── 为什么独立成一个 autoload ──────────────────────────────
## 解锁可能发生在任何场景（能力解锁经常在剧情/过场里），而 PlayerUI 只存在于游戏场景。
## 放在本层：任何场景都能显示；没有 PlayerUI（标题、菜单）时只写记录、不弹提示。
##
## ── 与存档提示（PlayerUI 的 SaveLabeI）的关系 ──────────────
## 两者都在屏幕右下角，同时出现会叠在一起看不清。规则：**成就提示优先** ——
##   * 成就提示正在播 → 存档提示让位（PlayerUI.show_save_label 会先问本层）；
##   * 成就提示消失 1 秒后，如果期间有存档提示被压住，本层补发一次。

## 单条提示的停留时长（秒）
@export var show_duration: float = 2.0
## 淡入 / 淡出时长（秒）
@export var fade_duration: float = 0.3
## 成就提示消失后，延迟多久补发被压住的存档提示（秒）
@export var save_label_delay: float = 1.0
## 达成音效
@export var sfx_stream: AudioStream = preload("res://Assets/Audios/SFX/Instances/成就解锁.wav")

@export_category("存档提示（存档已更新 . . .）")
## 提示停留时长（秒）
@export var save_hint_show_duration: float = 2.0
## 提示淡入 / 淡出时长（秒）
@export var save_hint_fade_duration: float = 0.5

@onready var toast_root: Control = $Toast
@onready var toast_label: Label = $Toast/ToastText
@onready var save_hint: Label = $SaveHint

## 待播提示队列（同一次可能解锁多个，排队依次播，不互相盖掉）
var _queue: Array[StringName] = []
var _showing: bool = false
## 成就提示期间被压住的存档提示请求
var _reshow_save_label: bool = false
## 存档提示的 Tween（重复触发时先 kill）
var _save_hint_tween: Tween = null


func _ready() -> void:
	toast_root.visible = false
	toast_root.modulate.a = 0.0
	save_hint.visible = false
	save_hint.modulate.a = 0.0
	AchievementManager.achievement_unlocked.connect(_on_achievement_unlocked)


## 存档提示调用本函数：正在展示成就提示时返回 true（并记住结束后补发一次）。
func defer_save_label() -> bool:
	if not _showing:
		return false
	_reshow_save_label = true
	return true


# ════════════════════════════════════════════════════════════
# 存档提示（「存档已更新 . . .」）
# ════════════════════════════════════════════════════════════
# 设计说明：全项目的「右下角文字提示」都集中在本层 ——
# 谁要提示只管调 show_save_hint()，不需要各自持有 Label / Tween，
# 也就不会出现两个提示抢同一块位置、或 HUD 显隐顺手把提示点亮这类问题。

func show_save_hint() -> void:
	if save_hint == null:
		return
	# 文字提示只在游戏内出现：没有 PlayerUI（标题 / 选存档 / 设置等 UI 场景）就不提示。
	if _get_player_ui() == null:
		return
	# 成就提示优先：正在播成就提示时这次让位，成就提示播完 1 秒后由本层补发。
	if defer_save_label():
		return
	_show_save_hint_now()


## 立即收掉正在显示的存档提示（不做动画）：成就提示要占用同一块位置。
func hide_save_hint_now() -> void:
	if save_hint == null:
		return
	if _save_hint_tween != null:
		_save_hint_tween.kill()
	save_hint.visible = false


func is_save_hint_visible() -> bool:
	return save_hint != null and save_hint.visible


func _show_save_hint_now() -> void:
	if _save_hint_tween != null:
		_save_hint_tween.kill()
	save_hint.visible = true
	save_hint.modulate.a = 0.0
	_save_hint_tween = create_tween()
	_save_hint_tween.tween_property(save_hint, "modulate:a", 1.0, save_hint_fade_duration)
	_save_hint_tween.tween_interval(save_hint_show_duration)
	_save_hint_tween.tween_property(save_hint, "modulate:a", 0.0, save_hint_fade_duration)
	_save_hint_tween.tween_callback(func(): save_hint.visible = false)


func _on_achievement_unlocked(id: StringName) -> void:
	# 不在游戏里（标题 / 菜单）：只写记录，不弹提示、也不补存档提示。
	if _get_player_ui() == null:
		return
	# 正在显示的存档提示让位（同一块位置，叠着看不清）
	if is_save_hint_visible():
		_reshow_save_label = true
		hide_save_hint_now()
	_queue.append(id)
	if not _showing:
		_play_queue()


func _play_queue() -> void:
	_showing = true
	while not _queue.is_empty():
		await _play_toast(_describe(_queue.pop_front()))
	_showing = false
	# 提示全部播完，再等 1 秒补发被压住的存档提示
	await _wait(save_label_delay)
	if _reshow_save_label:
		_reshow_save_label = false
		show_save_hint()


func _play_toast(text: String) -> void:
	toast_label.text = "成就达成：" + text
	if sfx_stream != null:
		AudioManager.play_stream_sfx(sfx_stream)
	toast_root.visible = true
	var tween: Tween = create_tween()
	tween.tween_property(toast_root, "modulate:a", 1.0, fade_duration)
	tween.tween_interval(show_duration)
	tween.tween_property(toast_root, "modulate:a", 0.0, fade_duration)
	# 用「时长等待」而不是 await tween.finished（本项目约定：Tween 被 kill 时信号不会发）。
	await _wait(fade_duration + show_duration + fade_duration)
	toast_root.visible = false


## 把成就 ID 翻成玩家看得懂的文字（目录里的描述）。
func _describe(id: StringName) -> String:
	for data in AchievementManager.get_achievements():
		if data.id == id:
			return data.description
	return String(id)


func _get_player_ui() -> Node:
	return get_tree().get_first_node_in_group("player_ui")


func _wait(seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout
