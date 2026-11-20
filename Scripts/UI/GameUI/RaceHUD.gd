extends CanvasLayer
class_name RaceHUD

## 跑圈竞速 HUD（对标 ChallengeCounter）
## 内容：背景板 + 计时器文本 + 圈数文本 + 结果文本。
## 剩余时间不足时计时器会变红并放大（超时警示）。
## 本脚本只负责显示，所有判定逻辑在 RaceController 里。

## 计时器文本
@onready var timer_label: Label = $Board/TimerLabel
## 圈数文本
@onready var lap_label: Label = $Board/LapLabel
## 结果文本（成功 / 失败时显示）
@onready var result_label: Label = $Board/ResultLabel
## 开始前的 3-2-1 倒计时文本
@onready var countdown_label: Label = $Board/CountdownLabel
## 整块面板（淡入淡出用）
@onready var board: Control = $Board

@export_category("字体")
## 计时器正常字号
@export var normal_font_size: int = 22
## 计时器超时警示字号（放大）
@export var urgent_font_size: int = 30
## 圈数文本字号
@export var lap_font_size: int = 16
## 结果文本字号
@export var result_font_size: int = 24
## 倒计时字号
@export var countdown_font_size: int = 44

@export_category("超时警示")
## 剩余时间少于该秒数时进入警示状态（仅限时模式）
@export var urgent_remaining: float = 5.0
## 警示状态下的文字颜色
@export var urgent_color: Color = Color(1.0, 0.25, 0.25, 1.0)
## 正常状态下的文字颜色
@export var normal_color: Color = Color(1.0, 1.0, 1.0, 1.0)

## 本阶段总圈数
var lap_total: int = 3
## 本阶段限时（秒，<= 0 表示不限时）
var time_limit: float = 0.0
## 计时器当前是否处于警示状态
var _is_urgent: bool = false

## 初始化字号
func _ready() -> void:
	timer_label.add_theme_font_size_override("font_size", normal_font_size)
	lap_label.add_theme_font_size_override("font_size", lap_font_size)
	result_label.add_theme_font_size_override("font_size", result_font_size)
	countdown_label.add_theme_font_size_override("font_size", countdown_font_size)
	timer_label.add_theme_color_override("font_color", normal_color)
	result_label.modulate.a = 0.0
	countdown_label.visible = false

## 设置本阶段的圈数与限时
func setup(total_laps: int, limit: float) -> void:
	lap_total = maxi(total_laps, 1)
	time_limit = limit
	_is_urgent = false
	result_label.text = ""
	result_label.modulate.a = 0.0
	# 倒计时结束前不显示计时器与圈数，避免与 3-2-1 文本叠在一起
	timer_label.visible = false
	lap_label.visible = false
	countdown_label.visible = false

## 刷新计时器（限时模式显示剩余时间，否则显示已用时间）
func update_timer(elapsed: float, remaining: float) -> void:
	timer_label.visible = true
	if time_limit > 0.0:
		timer_label.text = tr("剩余 %05.2f") % maxf(remaining, 0.0)
		_set_urgent(remaining <= urgent_remaining)
	else:
		timer_label.text = tr("用时 %05.2f") % elapsed
		_set_urgent(false)

## 刷新圈数显示
func update_lap(current: int, total: int) -> void:
	lap_label.text = tr("第 %d / %d 圈") % [mini(current + 1, total), total]

## 显示结果（成功 / 失败），并隐藏计时器与圈数
func show_result(text: String, success: bool) -> void:
	timer_label.visible = false
	lap_label.visible = false
	result_label.text = text
	result_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.55, 1.0) if success else urgent_color)
	result_label.modulate.a = 1.0

## 显示倒计时文本（3 / 2 / 1 / GO！）
## ★ 倒计时期间隐藏计时器与圈数文本，避免与倒计时叠在一起（倒计时结束后才切过去）
func show_countdown(text: String) -> void:
	timer_label.visible = false
	lap_label.visible = false
	countdown_label.visible = true
	countdown_label.text = text

## 隐藏倒计时文本，并切换到「剩余时间 + 圈数」
func hide_countdown() -> void:
	countdown_label.visible = false
	timer_label.visible = true
	lap_label.visible = true
	timer_label.add_theme_color_override("font_color", normal_color)
	timer_label.add_theme_font_size_override("font_size", normal_font_size)

## 面板淡入
func fade_in(duration: float) -> void:
	var tween: Tween = create_tween()
	tween.tween_property(board, "modulate:a", 1.0, maxf(duration, 0.0))

## 面板淡出；on_complete 有效时在淡出结束后回调
func fade_out(duration: float, on_complete: Callable = Callable()) -> void:
	var tween: Tween = create_tween()
	tween.tween_property(board, "modulate:a", 0.0, maxf(duration, 0.0))
	if on_complete.is_valid():
		tween.tween_callback(on_complete)
	else:
		tween.tween_callback(queue_free)

## 切换超时警示状态（颜色 + 字号）
func _set_urgent(urgent: bool) -> void:
	if urgent == _is_urgent:
		return
	_is_urgent = urgent
	timer_label.add_theme_color_override("font_color", urgent_color if urgent else normal_color)
	timer_label.add_theme_font_size_override("font_size", urgent_font_size if urgent else normal_font_size)
