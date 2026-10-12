extends Area2D
class_name RaceStartLine

## 起点 / 终点线
## 只负责「玩家经过」这件事 —— 不做任何纹理变化（按需求），
## 圈数由 RaceController 在玩家过线时更新 RaceHUD 的 LapLabel。

## 玩家经过起点线时发出
signal player_entered(checkpoint: Node)

@export_category("起点线")
## 序号固定为 0（圈道里唯一）
@export var checkpoint_index: int = 0
## 名称（仅调试显示用）
@export var checkpoint_label: String = "起点/终点线"

## 初始化：连接进入信号
func _ready() -> void:
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

## 玩家进入 → 交给 RaceController 判定是否完成一圈
func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	player_entered.emit(self)
