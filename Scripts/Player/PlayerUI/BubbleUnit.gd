extends Node2D
class_name BubbleUnit

## 单个气泡单位（对标 HealthUnit 的结构：独立场景 + AnimatedSprite2D + 状态机）
##
## 状态：
##   FULL  —— 气泡存续（循环动画）
##   POP   —— 破裂（播完自动变成 EMPTY，可在这里接音效）
##   EMPTY —— 已耗尽（占位阶段显示为半透明，正式美术可以换成"熄灭的泡泡"）
##
## ★ 美术接入方式：直接改 AnimatedSprite2D 的 SpriteFrames 即可（动画名保持 FULL / POP / EMPTY）。
##   当前用的是占位图（见 BubbleUnit.tscn）。

## 气泡状态
enum BubbleState {
	FULL,   ## 存续中
	POP,    ## 破裂动画播放中
	EMPTY   ## 已耗尽
}

## 当前状态
var current_state: BubbleState = BubbleState.EMPTY
## 动画节点
@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
## 破裂音效（留空 = 静音；后续把音频拖进来即可）
@export var pop_sound: AudioStream
## 音效播放器
@onready var _sound: AudioStreamPlayer = get_node_or_null("PopSound") as AudioStreamPlayer

## 初始化：连接动画结束回调，并默认显示为耗尽
func _ready() -> void:
	if animated_sprite != null:
		animated_sprite.animation_finished.connect(_on_animation_finished)
	show_empty()

## 立即显示为空（不播破裂动画）
func show_empty() -> void:
	_set_state(BubbleState.EMPTY, false)

## 立即显示为存续
func show_full() -> void:
	_set_state(BubbleState.FULL, false)

## 播放破裂动画（播完变成空）
func pop() -> void:
	_set_state(BubbleState.POP, true)
	if _sound != null and pop_sound != null:
		_sound.stream = pop_sound
		_sound.play()

## 切换状态；force_restart = true 时即使状态相同也重播（破裂动画需要）
func _set_state(new_state: BubbleState, force_restart: bool) -> void:
	if current_state == new_state and not force_restart:
		return
	current_state = new_state
	if animated_sprite == null:
		return
	match new_state:
		BubbleState.FULL:
			_play_if_exists("FULL")
			modulate = Color(1.0, 1.0, 1.0, 1.0)
		BubbleState.POP:
			_play_if_exists("POP")
			modulate = Color(1.0, 1.0, 1.0, 1.0)
		BubbleState.EMPTY:
			_play_if_exists("EMPTY")
			modulate = Color(1.0, 1.0, 1.0, 0.25)

## 播放指定动画（动画不存在时不报错，方便你逐步替换美术）
func _play_if_exists(anim_name: String) -> void:
	if animated_sprite.sprite_frames == null:
		return
	if not animated_sprite.sprite_frames.has_animation(anim_name):
		return
	animated_sprite.play(anim_name)

## 破裂动画播完 → 进入空状态
func _on_animation_finished() -> void:
	if current_state == BubbleState.POP:
		show_empty()
