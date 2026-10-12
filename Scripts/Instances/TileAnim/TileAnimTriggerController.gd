extends Node2D
class_name TileAnimTriggerController

## 瓦片动画触发器（B 方案框架）：玩家经过带自定义数据的瓦片时，在该格播放一次预设动画。
##
## 使用步骤（全部在编辑器完成，不需要写代码）：
##   1. 做一张“触发层”TileMapLayer（可以和视觉瓦片层共用同一张 TileSet），
##      里面只放需要触发的格子，甚至可以完全不显示图形；
##   2. 在 TileSet 里新建一个自定义数据层（类型 int），键名填到本节点的 custom_data_key，
##      给每个触发格子的该键填上动画 id；
##   3. 在场景里加一个本脚本的节点，把触发层 / 玩家 / 动画定义填进 Inspector；
##   4. 以后要加新动画：只加一条 TileAnimDefinition（id + SpriteFrames）即可。
##
## 注意：
##   - 本节点不要缩放/旋转（特效节点是它的子节点，位置按世界坐标换算）。
##   - 想用 .tscn 里预先摆好的特效节点，直接放 AnimatedSprite2D 子节点即可，
##     它们会被自动收进对象池当作初始成员。
##
## 性能：常态下每物理帧只查“玩家所在格 + N 格邻域”（默认 3×3，最多 9 次字典查询），
## 与地图大小无关；播放时从对象池取节点，同时播放数上限 = pool_size。
@export_category("触发源")
## 触发层（用自定义数据标记哪些格子要播动画）
@export var trigger_layer: TileMapLayer = null
## TileSet 自定义数据键名（值 = TileAnimDefinition.id）
@export var custom_data_key: StringName = &"tile_anim_id"
## 玩家节点（留空则自动取 group "player"）
@export var player_path: NodePath
## 触发查询半径（格）：玩家所在格周围 ±N 格
@export_range(0, 3, 1) var query_radius_cells: int = 1

@export_category("播放")
## 动画定义表
@export var definitions: Array[TileAnimDefinition] = []
## 是否“进入一次只播一次”（关闭则只要待在格子里、冷却结束就会重复播）
@export var one_shot_per_entry: bool = true
## 对象池大小（同时播放上限）
@export var pool_size: int = 16
## 是否叠加触发层的 z_index
@export var use_layer_z_index: bool = true

## 玩家节点引用
var _player: Node2D = null
## id → TileAnimDefinition 表
var _definition_by_id: Dictionary = {}
## 空闲对象池
var _pool: Array[AnimatedSprite2D] = []
## 正在播放的条目：{node, remaining}
var _playing: Array[Dictionary] = []
## 当前“一次进入”内已触发过的格子（离开格子后清除）
var _played_cells: Dictionary = {}
## 格子 → 冷却结束时间（毫秒时间戳）
var _cooldown_until_ms: Dictionary = {}


## 初始化：收集预摆特效、建立定义表、解析玩家
func _ready() -> void:
	_collect_preplaced_sprites()
	_rebuild_definition_table()
	_resolve_player()


## 每物理帧：推进播放 + 只扫描玩家附近格子
func _physics_process(delta: float) -> void:
	_update_playing(delta)
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
	if _player == null or trigger_layer == null:
		return
	_scan_player_area()


## 把场景里预先摆好的 AnimatedSprite2D 收进对象池（隐藏待用）
func _collect_preplaced_sprites() -> void:
	for child in get_children():
		if child is AnimatedSprite2D:
			var sprite: AnimatedSprite2D = child as AnimatedSprite2D
			sprite.visible = false
			_pool.append(sprite)


## 构建 id → 定义表（无 id 的定义会被忽略）
func _rebuild_definition_table() -> void:
	_definition_by_id.clear()
	for definition in definitions:
		if definition == null or definition.id == &"":
			continue
		_definition_by_id[definition.id] = definition


## 解析玩家节点（优先 player_path，其次 group "player"）
func _resolve_player() -> void:
	if player_path != NodePath():
		var candidate: Node = get_node_or_null(player_path)
		if candidate is Node2D:
			_player = candidate as Node2D
			return
	for node in get_tree().get_nodes_in_group("player"):
		if node is Node2D:
			_player = node as Node2D
			return


## 扫描玩家所在格及邻域，命中触发格就播一次；离开的格子清掉“已触发”标记
func _scan_player_area() -> void:
	var center_cell: Vector2i = trigger_layer.local_to_map(trigger_layer.to_local(_player.global_position))
	var hit_cells: Dictionary = {}
	for dy in range(-query_radius_cells, query_radius_cells + 1):
		for dx in range(-query_radius_cells, query_radius_cells + 1):
			var cell: Vector2i = center_cell + Vector2i(dx, dy)
			hit_cells[cell] = true
			_try_trigger_cell(cell)
	for cell in _played_cells.keys():
		if not hit_cells.has(cell):
			_played_cells.erase(cell)


## 尝试触发单个格子
func _try_trigger_cell(cell: Vector2i) -> void:
	var tile_data: TileData = trigger_layer.get_cell_tile_data(cell)
	if tile_data == null:
		return
	if not tile_data.has_custom_data(custom_data_key):
		return
	var id: StringName = StringName(str(tile_data.get_custom_data(custom_data_key)))
	if id == &"":
		return
	if one_shot_per_entry and _played_cells.has(cell):
		return
	var now_ms: int = Time.get_ticks_msec()
	if _cooldown_until_ms.has(cell) and now_ms < int(_cooldown_until_ms[cell]):
		return
	var definition: TileAnimDefinition = _definition_by_id.get(id, null) as TileAnimDefinition
	if definition == null or definition.sprite_frames == null:
		return
	if not _spawn_animation(cell, definition):
		return
	_played_cells[cell] = true
	_cooldown_until_ms[cell] = now_ms + int(maxf(definition.cooldown, 0.0) * 1000.0)


## 从池里取节点并播放一次动画；返回是否成功播放
func _spawn_animation(cell: Vector2i, definition: TileAnimDefinition) -> bool:
	var anim_name: StringName = definition.get_play_animation()
	if anim_name == &"":
		return false
	var sprite: AnimatedSprite2D = _acquire_sprite()
	if sprite == null:
		return false
	sprite.sprite_frames = definition.sprite_frames
	sprite.flip_h = definition.flip_h
	sprite.scale = definition.scale_multiplier
	sprite.global_position = trigger_layer.to_global(trigger_layer.map_to_local(cell)) + definition.offset
	var base_z: int = trigger_layer.z_index if use_layer_z_index else 0
	sprite.z_index = definition.z_index_offset + base_z
	sprite.visible = true
	sprite.play(anim_name)
	var duration: float = definition.duration_override
	if duration <= 0.0:
		duration = _measure_animation_length(definition.sprite_frames, anim_name)
	_playing.append({"node": sprite, "remaining": maxf(duration, 0.01)})
	return true


## 取一个可用节点（池空则新建，但不超过 pool_size 个同时播放）
func _acquire_sprite() -> AnimatedSprite2D:
	if not _pool.is_empty():
		return _pool.pop_back() as AnimatedSprite2D
	if _playing.size() >= maxi(pool_size, 1):
		return null
	var sprite: AnimatedSprite2D = AnimatedSprite2D.new()
	sprite.name = "TileAnim_%d" % get_child_count()
	add_child(sprite)
	return sprite


## 推进正在播放的条目，播完归还对象池
func _update_playing(delta: float) -> void:
	for index in range(_playing.size() - 1, -1, -1):
		var entry: Dictionary = _playing[index]
		entry["remaining"] = float(entry["remaining"]) - delta
		if float(entry["remaining"]) > 0.0:
			continue
		var node: AnimatedSprite2D = entry["node"] as AnimatedSprite2D
		if node != null:
			node.visible = false
			_pool.append(node)
		_playing.remove_at(index)


## 取动画时长（秒）；取不到时给一个保守值
func _measure_animation_length(frames: SpriteFrames, anim_name: StringName) -> float:
	if not frames.has_animation(anim_name):
		return 0.2
	var count: int = frames.get_frame_count(anim_name)
	var speed: float = frames.get_animation_speed(anim_name)
	if speed <= 0.0:
		return 0.2
	return float(count) / speed
