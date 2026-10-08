extends CanvasLayer

# ════════════════════════════════════════════════════════════
# 覆盖层暗化规范（全项目唯一来源 —— 只改这里，所有界面一起变）
# ════════════════════════════════════════════════════════════
# 全屏覆盖界面（地图 / 传送面板 / 游戏内设置）的暗化固定由两个数字描述：
#
#   一、【黑幕】一层全屏纯黑 ColorRect，alpha = OVERLAY_ALPHA
#       作用：把玩家的注意力收到浮层上，同时盖住背景画面。
#
#   二、【世界亮度】RoomManager.global_canvas_modulate 乘一个系数
#       作用：让身后的世界轮廓隐约可见（知道自己站哪），但不抢戏。
#
# 为什么要有这个文件：过去三个界面各写一套（0.68 / 0.85 / 0.7 与 ×0.4 / ×0.3 / 无），
# 同一个玩家看到的是 “地图有点暗、传送面板很暗、设置界面忘了调暗世界”，逻辑碎且不一致。
# 现在所有界面都引用下面两个常量，改一个数字就能全局统一。

## 【黑幕】全屏黑幕的不透明度
const OVERLAY_ALPHA := 0.7

## 【世界亮度】世界亮度乘法系数（1.0 = 不调暗）
const WORLD_DARKEN_MULTIPLIER := 0.45

## 【黑幕过渡】黑幕自身渐暗 / 渐亮的时长（秒）
## 打开界面时黑幕在这么长时间内从全透明渐到 OVERLAY_ALPHA，
## 点击关闭时在同样时长内从当前值渐回全透明 —— 三个界面时长完全一致。
const OVERLAY_FADE_DURATION := 0.5

## 黑幕补间存在 ColorRect 元数据里的键名（用于杀掉上一次未播完的补间）
const OVERLAY_TWEEN_META := "_overlay_fade_tween"


## 让任意全屏黑幕 ColorRect 在 duration 秒内渐变到 target_alpha。
## host 用来创建补间（传场景根节点，保证 gameplay 暂停时也能推进）。
## 会自动杀掉同一 ColorRect 上未播完的上一次黑幕渐变，避免快速开关时两条补间抟 alpha。
static func fade_rect_alpha(rect: ColorRect, target_alpha: float, host: Node, duration: float = OVERLAY_FADE_DURATION) -> void:
	if rect == null or host == null or not is_instance_valid(host) or not is_instance_valid(rect):
		return
	_kill_fade_tween(rect)
	if duration <= 0.0:
		rect.color = Color(rect.color.r, rect.color.g, rect.color.b, target_alpha)
		return
	var tween: Tween = host.create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(rect, "color:a", target_alpha, duration)
	rect.set_meta(OVERLAY_TWEEN_META, tween)


## 杀掉某个 ColorRect 上未播完的黑幕渐变补间
static func _kill_fade_tween(rect: ColorRect) -> void:
	if rect == null or not is_instance_valid(rect):
		return
	if not rect.has_meta(OVERLAY_TWEEN_META):
		return
	var previous: Variant = rect.get_meta(OVERLAY_TWEEN_META)
	if previous is Tween and (previous as Tween).is_valid():
		(previous as Tween).kill()

@onready var color_rect: ColorRect = $ColorRect

## 遮罩的透明度（0-1）。默认取统一规范值；只有特殊界面才需要单独调节。
@export var overlay_alpha: float = OVERLAY_ALPHA
var _overlay_request_count: int = 0

func _ready():
	# 设置层级在对话框之上，设置界面之下
	layer = 95
	
	# 初始隐藏
	visible = false
	
	# 设置 ColorRect 全屏
	if color_rect:
		color_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		color_rect.color = Color(0, 0, 0, overlay_alpha)
	_apply_overlay_state()

func set_overlay_alpha(alpha_value: float) -> void:
	overlay_alpha = clampf(alpha_value, 0.0, 1.0)
	if color_rect:
		color_rect.color = Color(0, 0, 0, overlay_alpha)

func set_overlay_state(should_show: bool, force_reset: bool = false) -> void:
	if force_reset:
		_overlay_request_count = 1 if should_show else 0
	elif should_show:
		# 关键修正：这个遮罩必须是单一开关状态，不能用递增计数叠加。
		# GameSettingScene 与 SettingsScene 之间反复切换时，计数会越来越大，
		# 最终出现多层暗化，并且只消失一层，剩下的会永久残留。
		_overlay_request_count = 1
	else:
		_overlay_request_count = 0
	_apply_overlay_state()

func _apply_overlay_state() -> void:
	_kill_fade_tween(color_rect)
	visible = _overlay_request_count > 0
	if color_rect:
		color_rect.color = Color(0, 0, 0, overlay_alpha)


## 打开遮罩，并让黑幕从全透明在 duration 秒内渐暗到 OVERLAY_ALPHA。
## 用这个而不是 show_overlay()，否则黑幕会“啵”地一下子出现。
func fade_in_overlay(host: Node, duration: float = OVERLAY_FADE_DURATION) -> void:
	if color_rect == null:
		return
	_overlay_request_count = 1
	visible = true
	color_rect.color = Color(0, 0, 0, 0)
	fade_rect_alpha(color_rect, overlay_alpha, host, duration)


## 让黑幕从当前 alpha 在 duration 秒内渐亮到全透明。
## **不会隐藏**遮罩 —— 渐亮结束后调用方自行 hide_overlay()，否则黑幕会被瞬间切掉。
func fade_out_overlay(host: Node, duration: float = OVERLAY_FADE_DURATION) -> void:
	if color_rect == null:
		return
	fade_rect_alpha(color_rect, 0.0, host, duration)

## 显示遮罩
func show_overlay():
	set_overlay_state(true)

## 隐藏遮罩
func hide_overlay():
	set_overlay_state(false)

func reset_overlay():
	_overlay_request_count = 0
	_apply_overlay_state()
