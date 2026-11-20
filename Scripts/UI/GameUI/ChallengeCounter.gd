extends CanvasLayer
class_name ChallengeCounterUI

## 挑战计数器 UI
## 显示当前挑战进度 (例如：1/12)
## 无尽模式（ChallengeConfig.endless_mode）下只显示当前积分，不显示目标积分；
## 积分达到 endless_gold_threshold（默认 99）及以上时文本变金色。

## 无尽模式积分变金色的阈值
@export var endless_gold_threshold: int = 99
## 无尽模式达到阈值后的文字颜色
@export var endless_gold_color: Color = Color(1.0, 0.84, 0.0, 1.0)

@onready var label: Label = $MarginContainer/HBoxContainer/TextureRect/Label

## 普通模式下的文字颜色（_ready 时记录，避免主题色被写死）
var _normal_color: Color = Color.WHITE

## 初始化：记录普通模式文字颜色
func _ready() -> void:
	if label:
		_normal_color = label.get_theme_color("font_color")

## 更新计数器显示（endless = true 时只显示当前积分）
func update_counter(current: int, target: int, endless: bool = false):
	if label:
		label.text = str(current) if endless else (str(current) + "/" + str(target))
		label.add_theme_color_override("font_color", _endless_text_color(current) if endless else _normal_color)
	else:
		push_error("ChallengeCounterUI: Label 节点未找到！")

## 无尽模式文字颜色：达到阈值后变金色
func _endless_text_color(current: int) -> Color:
	return endless_gold_color if current >= endless_gold_threshold else _normal_color
