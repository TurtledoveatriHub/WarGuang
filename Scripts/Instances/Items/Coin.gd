extends Area2D
## 金币收集音效（拖拽 .wav 文件）
@export var coin_collect_sfx: AudioStream

@onready var animated_sprite = $AnimatedSprite2D
@onready var collision_shape = $CollisionShape2D

@export var coin_value: int = 1
# 删除 coin_id 相关代码

func _ready():
	body_entered.connect(_on_body_entered)
	animated_sprite.play("IDLE")

func _on_body_entered(body):
	if body.is_in_group("player"):
		# 禁用碰撞，防止重复触发
		collision_shape.set_deferred("disabled", true)
		
		# 播放收集动画
		animated_sprite.play("COLLECT")
		
		# 增加硬币
		Global.add_coins(coin_value)
		
		# 播放收集音效
		AudioManager.play_stream_sfx(coin_collect_sfx)
		
		# 等待动画播放完毕
		await animated_sprite.animation_finished
		
		# 销毁硬币
		queue_free()
