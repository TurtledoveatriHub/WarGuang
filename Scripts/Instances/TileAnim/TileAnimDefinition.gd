extends Resource
class_name TileAnimDefinition

## 一条“瓦片动画”定义：id 对应触发瓦片的自定义数据值，sprite_frames 是要播放的动画。
## 用法：在 TileAnimTriggerController 的 definitions 数组里逐条配置，不需要改代码。

@export_category("标识")
## 触发 id（必须与 TileMapLayer 自定义数据里该格子的值一致）
@export var id: StringName = &""
## 只播放 SpriteFrames 里的哪个动画（留空 = 播第一个动画）
@export var animation_name: StringName = &""

@export_category("表现")
## 播放内容（SpriteFrames；建议只放“播一次”的动画）
@export var sprite_frames: SpriteFrames = null
## 相对触发瓦片中心的世界坐标偏移（像素）
@export var offset: Vector2 = Vector2.ZERO
## 相对触发瓦片图层的 z_index 偏移（一般 >0，保证浮在瓦片之上）
@export var z_index_offset: int = 1
## 是否水平翻转播放
@export var flip_h: bool = false
## 额外缩放（默认 1，方便不同房间微调大小）
@export var scale_multiplier: Vector2 = Vector2.ONE
## 覆盖播放时长（秒；<=0 表示用动画自身时长）
@export var duration_override: float = 0.0
## 同一格再次触发的冷却时间（秒；0 = 离开格子后即可再次触发）
@export var cooldown: float = 0.0


## 返回实际要播放的动画名（animation_name 为空时取 SpriteFrames 的第一个动画）
func get_play_animation() -> StringName:
	if animation_name != &"":
		return animation_name
	if sprite_frames and sprite_frames.get_animation_names().size() > 0:
		return StringName(sprite_frames.get_animation_names()[0])
	return &""
