extends CanvasLayer
## 开场过场动画（工作室 Logo 式），整个游戏只播放一次。
##
## 作为 Autoload 在「游戏启动时」自动创建并播放，播完即隐藏；
## 返回 TitleScene 或任何场景切换都不会重播。
##
## 帧素材请在本场景的 CutsceneSprite(AnimatedSprite2D) 的 SpriteFrames 里直接拖入 —— 只需一个动画。
##
## 时序：
##   1. 进场动画（intro）播放一遍
##   2. 发出 intro_finished —— 此刻外部（TitleScene）开始自己的入场演出
##   3. 自身淡出 fade_out_duration 秒，露出已经开始演出的场景
## 全程不 await 外部、不改任何场景的输入锁与流程。

@export_category("开关")
## 关闭后，游戏启动时不会播放过场动画。
@export var enabled: bool = true

@export_category("动画")
## 进场动画名（对应 CutsceneSprite 的 SpriteFrames 动画名），只播放一遍。
@export var intro_animation: StringName = &"intro"

@export_category("时长参数")
## 进场动画播完后的停留时长（秒），0 = 立刻开始淡出。
@export var intro_hold_duration: float = 0.0
## 淡出时长（秒）。
@export var fade_out_duration: float = 0.3
## 总时长兜底上限（秒）。超过该时长强制结束，避免异常时黑屏卡死。
@export var max_total_duration: float = 6.0

## 进场动画播放完毕、淡出即将开始的那一刻发出。
## 外部（如 TitleScene）可在此刻开始自己的入场演出，从而与淡出无缝衔接。
signal intro_finished
## 过场完全结束、覆盖层已隐藏时发出。
signal cutscene_finished

@onready var overlay: ColorRect = get_node_or_null("Overlay") as ColorRect
@onready var cutscene_sprite: AnimatedSprite2D = get_node_or_null("CutsceneSprite") as AnimatedSprite2D

var _playing: bool = false
var _intro_finished: bool = true
var _finished: bool = false


func _ready() -> void:
	# 允许在暂停时照常演出（UI 场景可能把树暂停）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	if overlay:
		# 绝不吞掉输入事件，避免影响 UI 交互。
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not enabled or not _has_any_frame():
		_hide_now()
		return
	_run_cutscene()


## 过场是否正在播放（含淡出阶段）。
func is_playing() -> bool:
	return _playing


## 进场动画是否已经播完（未播放过、或已播完、或已隐藏均为 true）。
func is_intro_finished() -> bool:
	return _intro_finished


## 若过场正在播放且进场动画尚未播完，等待它播完。
## 注意：这是协程，调用方必须 await 本函数；只想等信号时请直接 await intro_finished。
func wait_until_intro_finished() -> void:
	if not _playing or _intro_finished:
		return
	await intro_finished


## 手动重播（调试用）。
func replay() -> void:
	if not enabled or not _has_any_frame():
		return
	_playing = false
	_intro_finished = false
	_finished = false
	if overlay:
		overlay.visible = true
		overlay.color = Color(0.0, 0.0, 0.0, 1.0)
	if cutscene_sprite:
		cutscene_sprite.visible = true
		cutscene_sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_run_cutscene()


## 是否至少有一帧可播放素材。
func _has_any_frame() -> bool:
	if cutscene_sprite == null:
		return false
	var frames: SpriteFrames = cutscene_sprite.sprite_frames
	if frames == null or not frames.has_animation(intro_animation):
		return false
	return frames.get_frame_count(intro_animation) > 0


## 立即隐藏（不播放）。
func _hide_now() -> void:
	_playing = false
	_intro_finished = true
	_finished = true
	if overlay:
		overlay.visible = false
	if cutscene_sprite:
		cutscene_sprite.stop()
		cutscene_sprite.visible = false
	set_process(false)
	set_process_input(false)


## 主流程：立即开始，全程不阻塞外部调用方。
func _run_cutscene() -> void:
	if _playing:
		return
	_playing = true
	_intro_finished = false
	var budget: float = maxf(max_total_duration, 0.1)

	cutscene_sprite.visible = true
	cutscene_sprite.play(intro_animation)
	await _wait(minf(_animation_duration(intro_animation), budget))
	if _finished:
		return

	await _wait(minf(intro_hold_duration, budget))
	if _finished:
		return

	# 关键时刻：进场动画播完、淡出即将开始 —— 通知外部开始各自的入场演出。
	_intro_finished = true
	intro_finished.emit()

	await _fade_out_and_hide()


## 计算动画播放一遍所需时长（秒）。
func _animation_duration(anim_name: StringName) -> float:
	if cutscene_sprite == null:
		return 0.0
	var frames: SpriteFrames = cutscene_sprite.sprite_frames
	if frames == null or not frames.has_animation(anim_name):
		return 0.0
	var frame_count: int = frames.get_frame_count(anim_name)
	if frame_count <= 0:
		return 0.0
	var fps: float = frames.get_animation_speed(anim_name)
	if fps <= 0.0:
		fps = 1.0
	var anim_speed_scale: float = cutscene_sprite.speed_scale
	if anim_speed_scale <= 0.0:
		anim_speed_scale = 1.0
	return float(frame_count) / fps / anim_speed_scale


func _wait(seconds: float) -> void:
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds, true, false, false).timeout


func _fade_out_and_hide() -> void:
	if overlay == null and cutscene_sprite == null:
		_hide_now()
		cutscene_finished.emit()
		return
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	if overlay:
		tween.tween_property(overlay, "color:a", 0.0, fade_out_duration)
	if cutscene_sprite:
		tween.tween_property(cutscene_sprite, "modulate:a", 0.0, fade_out_duration)
	tween.set_parallel(false)
	await tween.finished
	_hide_now()
	cutscene_finished.emit()
