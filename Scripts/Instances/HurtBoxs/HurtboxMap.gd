extends TileMapLayer

## 默认伤害类型（0=普通，1=阴影）
@export var default_damage_type: int = 0
## 默认是否传送伤害
@export var default_is_warp: bool = false
## ★ 对 player 的击退力（Vector2统一参数）
@export var player_knockback: Vector2 = Vector2(50, 100)
## ★ 对 Layer8 敌人的击退力（Vector2统一参数）
@export var enemy_knockback: Vector2 = Vector2(1000, 100)
## 伤害冷却间隔（秒）
@export var damage_cooldown_time: float = 0.2

## 对 Layer8 敌人的伤害值（不区分伤害类型）
@export var enemy_damage: int = 1

## 自定义数据层名称（需与 TileSet 编辑器中完全一致）
@export var data_damage_type: String = "dmg_type"
@export var data_is_warp: String = "is_warp"
@export var data_knockback: String = "knockback"

var _hurt_area: Area2D
## 当前在区域内的玩家列表（用于连续检测）
var _players_in_area: Array = []
## 当前在区域内的 Layer8 敌人列表
var _enemies_in_area: Array = []
var _damage_cooldown: Dictionary = {}


func _ready():
	if tile_set == null:
		push_warning("HurtboxMap: 未设置 TileSet")
		return
	
	_hurt_area = Area2D.new()
	_hurt_area.name = "HurtArea"
	_hurt_area.collision_layer = 16   # 层5 HurtBox(2^4=16)
	_hurt_area.collision_mask = 129   # 监听层1 Player(2^0=1) + 层8 Enemy(2^7=128)
	
	var count: int = 0
	
	# 收集所有有 TileData 的格子
	var hurt_cells: Array[Vector2i] = []
	for cell in get_used_cells():
		if get_cell_tile_data(cell) != null:
			hurt_cells.append(cell)
	
	if hurt_cells.is_empty():
		push_warning("HurtboxMap: 未找到任何有 TileData 的格子")
		return
	
	# 每个伤害格子创建一个独立矩形碰撞体（不合并）
	var tile_size: Vector2 = tile_set.tile_size
	for cell in hurt_cells:
		_add_cell_shape(cell, tile_size)
		count += 1
	
	if count == 0:
		push_warning("HurtboxMap: 未找到任何有 TileData 的格子")
		return
	
	add_child(_hurt_area)
	_hurt_area.body_entered.connect(_on_body_entered)
	_hurt_area.body_exited.connect(_on_body_exited)
	
	if not Engine.is_editor_hint():
		print("HurtboxMap: 生成了 ", count, " 个碰撞体（每格独立）")


## 单个格子的矩形碰撞体，中心对齐格子中心
func _add_cell_shape(cell: Vector2i, tile_size: Vector2) -> void:
	var shape := CollisionShape2D.new()
	shape.shape = RectangleShape2D.new()
	(shape.shape as RectangleShape2D).size = tile_size
	shape.position = map_to_local(cell)
	_hurt_area.add_child(shape)


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player") and not body in _players_in_area:
		_players_in_area.append(body)
	elif body is CharacterBody2D and (body.collision_layer & 128) != 0:
		if not body in _enemies_in_area:
			_enemies_in_area.append(body)
			# 敌人不区分伤害类型，进入即直接扣 enemy_damage 血
			var enemy_base = body.get_node_or_null("EnemyBase")
			if enemy_base and enemy_base.has_method("take_damage"):
				## ★ 以具体格子位置计算击退方向
				var cell: Vector2i = local_to_map(to_local(body.global_position))
				var cell_world: Vector2 = to_global(map_to_local(cell))
				var knockback: Vector2 = Vector2(
					sign(body.global_position.x - cell_world.x) * enemy_knockback.x,
					-enemy_knockback.y)
				enemy_base.take_damage(enemy_damage, knockback)


func _on_body_exited(body: Node) -> void:
	var idx: int = _players_in_area.find(body)
	if idx >= 0:
		_players_in_area.remove_at(idx)
	var eidx: int = _enemies_in_area.find(body)
	if eidx >= 0:
		_enemies_in_area.remove_at(eidx)
	if _damage_cooldown.has(body):
		_damage_cooldown.erase(body)


## 连续伤害检测（每帧执行，与 HurtBox.gd handle_damage 逻辑一致）
func _process(delta: float) -> void:
	for i in range(_players_in_area.size() - 1, -1, -1):
		var body = _players_in_area[i]
		if not is_instance_valid(body):
			_players_in_area.remove_at(i)
			continue
		
		# 冷却中
		if _damage_cooldown.has(body) and _damage_cooldown[body] > 0.0:
			_damage_cooldown[body] -= delta
			if _damage_cooldown[body] <= 0.0:
				_damage_cooldown.erase(body)
			continue
		
		# 无敌检测（与 HurtBox.gd apply_damage 一致）
		if body.has_method("is_invincible") and body.is_invincible:
			continue
		if body.has_method("get_player_state") \
		and body.get_player_state() == body.PlayerState.DASH \
		and body.has_method("is_black_dash_unlocked") \
		and body.is_black_dash_unlocked():
			continue
		
		_try_apply_damage(body)
	
	# Layer8 敌人持续伤害（与玩家同间隔逻辑，但伤害值固定为 enemy_damage）
	for i in range(_enemies_in_area.size() - 1, -1, -1):
		var body = _enemies_in_area[i]
		if not is_instance_valid(body):
			_enemies_in_area.remove_at(i)
			continue
		# ★ 修复：冷却中需要递减（与玩家逻辑一致）
		if _damage_cooldown.has(body) and _damage_cooldown[body] > 0.0:
			_damage_cooldown[body] -= delta
			if _damage_cooldown[body] <= 0.0:
				_damage_cooldown.erase(body)
			continue
		var enemy_base = body.get_node_or_null("EnemyBase")
		if enemy_base and enemy_base.has_method("take_damage"):
			if not enemy_base.is_dead():
				## ★ 以具体格子位置计算击退方向
				var cell: Vector2i = local_to_map(to_local(body.global_position))
				var cell_world: Vector2 = to_global(map_to_local(cell))
				var knockback: Vector2 = Vector2(
					sign(body.global_position.x - cell_world.x) * enemy_knockback.x,
					-enemy_knockback.y)
				enemy_base.take_damage(enemy_damage, knockback)
				_damage_cooldown[body] = damage_cooldown_time

## 查找玩家所在格子的 TileData 并施加伤害
func _try_apply_damage(body: Node) -> void:
	if not body.has_method("take_damage"):
		return
	
	# 查找玩家所在格子的 TileData（含邻居搜索）
	var cell: Vector2i = local_to_map(to_local(body.global_position))
	var data: TileData = get_cell_tile_data(cell)
	
	# 如果精确格子无数据，搜索相邻 8 格
	if data == null:
		for dx in [-1, 0, 1]:
			if data != null: break
			for dy in [-1, 0, 1]:
				if dx == 0 and dy == 0: continue
				var near: Vector2i = cell + Vector2i(dx, dy)
				data = get_cell_tile_data(near)
				if data != null:
					cell = near
					break
	
	if data == null:
		return  # 附近都没有伤害格子
	
	var dmg_type: int = default_damage_type
	var is_warp: bool = default_is_warp
	var kb: Vector2 = player_knockback
	
	var ct: Variant = data.get_custom_data(data_damage_type)
	if ct != null: dmg_type = ct
	var cw: Variant = data.get_custom_data(data_is_warp)
	if cw != null: is_warp = cw
	var ck: Variant = data.get_custom_data(data_knockback)
	if ck != null: kb = ck
	
	var damage: int = 2 if dmg_type >= 1 else 1
	var final_type: int = dmg_type + (2 if is_warp else 0)
	
	var dir: Vector2 = (body.global_position - global_position).normalized()
	var angle: float = abs(atan2(dir.y, dir.x) - PI / 2.0)
	var total_f: float = sqrt(kb.x * kb.x + kb.y * kb.y)
	var kv: Vector2 = Vector2(
		-sign(dir.x) * abs(total_f * sin(angle)),
		-abs(total_f * cos(angle))
	)
	
	body.take_damage(global_position, damage, final_type, kv)
	_damage_cooldown[body] = damage_cooldown_time
