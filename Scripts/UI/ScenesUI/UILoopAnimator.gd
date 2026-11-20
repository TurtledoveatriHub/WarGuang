class_name UILoopAnimator
extends AnimatedSprite2D
## 常态 UI 循环动画播放器（AnimatedSprite2D + SpriteFrames）。
##
## 约定三个动画（名字可在 Inspector 里改）：
##   start（开始）：进入该 UI 场景时播放一遍，播完自动切到 loop。
##   loop （循环）：长期循环播放。
##   end  （结束）：离开该 UI 场景时播放一遍。
##
## 设计约束（与 UITransitionAnimator 同步）：
##   * play_enter() / play_exit() 调用后立即切换动画，**绝不 await、绝不阻塞调用方**。
##   * 不等待 start / end 播完，因此不会拖慢或改变任何现有场景切换流程。
##   * 帧素材直接在本节点的 SpriteFrames 里拖入即可；没有帧时本节点完全不显示、也不报错。

@export_category("动画名")
## 进入场景时播放一遍的动画名。
@export var start_animation: StringName = &"start"
## 长期循环播放的动画名。
@export var loop_animation: StringName = &"loop"
## 离开场景时播放一遍的动画名。
@export var end_animation: StringName = &"end"

@export_category("行为")
## 节点进入场景树时自动执行 play_enter()（场景切换时立即开始“开始 → 循环”）。
@export var autoplay_on_ready: bool = true
## “开始”动画不存在或没有帧时，是否直接播放“循环”。
@export var fallback_to_loop: bool = true
## 像素画工程：强制使用最近邻采样，避免缩放时出现模糊色块。
@export var force_nearest_filter: bool = true

## 播放令牌：每次 play_enter() 递增，用于让过期的兜底回调失效。
var _play_token: int = 0
## “开始”动画播放期间收到 play_exit() 时置位：等 start 播完再切 end（不硬切）。
var _exit_pending: bool = false
var _signal_connected: bool = false


func _ready() -> void:
	if force_nearest_filter:
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_connect_finished_signal()
	if autoplay_on_ready:
		play_enter()


## 进入 UI 场景：立即播放“开始”动画（播完自动进入“循环”）。不阻塞调用方。
func play_enter() -> void:
	_play_token += 1
	_exit_pending = false
	var token: int = _play_token
	if not _play_if_available(start_animation):
		if fallback_to_loop:
			play_loop()
		return
	_start_fallback_watch(token)


## 只播放“循环”动画（可随时手动调用）。
func play_loop() -> void:
	_exit_pending = false
	_play_if_available(loop_animation)


## 离开 UI 场景：播放“结束”动画。不阻塞、不等待播放完成。
## 若“开始”动画还没播完，不硬切到 end，而是先记下退出意图，
## 等 start 自然播完后再切 end（避免 start 被截断的突兀感）。
func play_exit() -> void:
	if animation == start_animation and is_playing() and start_animation != end_animation:
		_exit_pending = true
		return
	_exit_pending = false
	_play_if_available(end_animation)


## 停止播放并隐藏（供特殊情况下手动调用）。
func stop_and_hide() -> void:
	_play_token += 1
	_exit_pending = false
	stop()
	visible = false


func _connect_finished_signal() -> void:
	if _signal_connected:
		return
	_signal_connected = true
	if not animation_finished.is_connected(_on_animation_finished):
		animation_finished.connect(_on_animation_finished)


func _on_animation_finished() -> void:
	# 只有“开始”动画播完才需要收尾：有待执行的退出就切 end，否则进 loop。
	if animation == start_animation:
		_finish_start(_play_token)


## “开始”动画播完（或兜底超时）后的收尾。
func _finish_start(token: int) -> void:
	if token != _play_token:
		return
	if animation != start_animation:
		return
	if _exit_pending:
		# 播放 start 期间收到过 play_exit()：现在补上“结束”动画。
		_exit_pending = false
		_play_if_available(end_animation)
		return
	_play_if_available(loop_animation)


## 兜底：即使“开始”动画被 SpriteFrames 设成了循环（animation_finished 不会触发），
## 也会在动画时长结束后自动收尾（进 loop 或执行待定的 end）。
func _start_fallback_watch(token: int) -> void:
	var wait_time: float = _animation_duration(start_animation)
	if wait_time <= 0.0:
		_finish_start(token)
		return
	await get_tree().create_timer(wait_time + 0.04, true, false, false).timeout
	_finish_start(token)


func _play_if_available(anim_name: StringName) -> bool:
	if sprite_frames == null:
		return false
	if not sprite_frames.has_animation(anim_name):
		return false
	if sprite_frames.get_frame_count(anim_name) <= 0:
		return false
	visible = true
	if animation == anim_name and is_playing():
		return true
	play(anim_name)
	return true


## 计算动画播放一遍所需时长（秒）。
func _animation_duration(anim_name: StringName) -> float:
	if sprite_frames == null or not sprite_frames.has_animation(anim_name):
		return 0.0
	var frame_count: int = sprite_frames.get_frame_count(anim_name)
	if frame_count <= 0:
		return 0.0
	var fps: float = sprite_frames.get_animation_speed(anim_name)
	if fps <= 0.0:
		fps = 1.0
	# 不能命名为 speed_scale：会遮蔽 AnimatedSprite2D 基类属性（SHADOWED_VARIABLE_BASE_CLASS）。
	var anim_speed_scale: float = self.speed_scale
	if anim_speed_scale <= 0.0:
		anim_speed_scale = 1.0
	return float(frame_count) / fps / anim_speed_scale
