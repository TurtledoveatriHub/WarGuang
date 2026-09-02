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

	# 收集所有有有效 TileData 的格子。
	# 先跳过引用“已不存在 atlas source”的脏格子（例如删掉某个 source 后遗留的旧格子），
	# 避免 get_cell_tile_data → get_source 触发 “No TileSet atlas source” 的刷屏报错。
	var valid_sources := {}
	for i in tile_set.get_source_count():
		valid_sources[tile_set.get_source_id(i)] = true
	var hurt_cells: Array[Vector2i] = []
	for cell in get_used_cells():
		var source_id: int = get_cell_source_id(cell)
		if source_id < 0 or not valid_sources.has(source_id):
			continue
		if get_cell_tile_data(cell) != null:
			hurt_cells.append(cell)
	
	if hurt_cells.is_empty():
		push_warning("HurtboxMap: 未找到任何有 TileData 的格子")
		return
	
	# 每个伤害格子只在其存在 TileSet 物理层多边形时生成碰撞体（伤害范围 = 物理层区域）。
	for cell in hurt_cells:
		if _add_cell_shape(cell):
			count += 1
	
	if count == 0:
		push_warning("HurtboxMap: 未找到任何有物理多边形的伤害格子")
		return
	
	add_child(_hurt_area)
	_hurt_area.body_entered.connect(_on_body_entered)
	_hurt_area.body_exited.connect(_on_body_exited)
	
	if not Engine.is_editor_hint():
		print("HurtboxMap: 生成了 ", count, " 个伤害格子碰撞体（仅物理多边形区域）")


## 为单个格子生成伤害碰撞体，返回是否生成了至少一个形状。
## 只在该格存在 TileSet 物理层多边形时生成，伤害范围 = 物理层区域；
## 没有物理多边形的格子不产生任何伤害（绝不整格回退）。
func _add_cell_shape(cell: Vector2i) -> bool:
	var tile_data: TileData = get_cell_tile_data(cell)
	var added := false
	if tile_data != null and tile_set != null:
		# 该 Godot 版本里，TileSet 物理层的多边形 API 名为 collision（tres 序列化为 physics_layer_0）。
		for layer in tile_set.get_physics_layers_count():
			var poly_count: int = tile_data.get_collision_polygons_count(layer)
			for poly_idx in poly_count:
				var points: PackedVector2Array = tile_data.get_collision_polygon_points(layer, poly_idx)
				if points.size() >= 3 and _add_cell_polygon(cell, points):
					added = true
	return added

## 按 TileSet 物理多边形生成伤害碰撞体。
## 该 TileSet 的多边形坐标以“格子原点 = map_to_local(cell)”为中心（整格是 -half..half），
## 因此直接使用原坐标、不再偏移。凹多边形先三角化；三角化失败时退回多边形包围盒。
func _add_cell_polygon(cell: Vector2i, points: PackedVector2Array) -> bool:
	# Geometry2D.triangulate_polygon 返回三角形顶点“索引”，每 3 个索引组成一个三角形。
	var indices: PackedInt32Array = Geometry2D.triangulate_polygon(points)
	if indices.size() >= 3:
		for i in range(0, indices.size(), 3):
			var a: Vector2 = points[indices[i]]
			var b: Vector2 = points[indices[i + 1]]
			var c: Vector2 = points[indices[i + 2]]
			var tri_shape := CollisionShape2D.new()
			var convex := ConvexPolygonShape2D.new()
			convex.points = PackedVector2Array([a, b, c])
			tri_shape.shape = convex
			tri_shape.position = map_to_local(cell)
			_hurt_area.add_child(tri_shape)
		return true
	# 兜底：用多边形包围盒生成矩形（保持与物理区域相近，不会扩到整格）。
	var mn := Vector2(points[0])
	var mx := Vector2(points[0])
	for p in points:
		mn = mn.min(p)
		mx = mx.max(p)
	var size := mx - mn
	if size.x <= 0.0 or size.y <= 0.0:
		return false
	var box_shape := CollisionShape2D.new()
	box_shape.shape = RectangleShape2D.new()
	(box_shape.shape as RectangleShape2D).size = size
	box_shape.position = map_to_local(cell)
	_hurt_area.add_child(box_shape)
	return true


func _on_body_entered(body: Node) -> void:
	if body.is_in_group("player") and not body in _players_in_area:
		_players_in_area.append(body)
	elif body is CharacterBody2D and (body.collision_layer & 128) != 0:
		if not body in _enemies_in_area:
			_enemies_in_area.append(body)
			# 敌人不区分伤害类型，进入即直接扣 enemy_damage 血
			var enemy_base = body.get_node_or_null("EnemyBase")
			if enemy_base and enemy_base.has_method("take_damage"):
				## 击退源点=该敌人所在的伤害格中心，方向=目标远离该格中心。
				var source_pos: Vector2 = _resolve_source_world(body)
				var direction: Vector2 = (body.global_position - source_pos).normalized()
				if direction == Vector2.ZERO:
					direction = Vector2.UP
				var knockback: Vector2 = Vector2(
					direction.x * abs(enemy_knockback.x),
					direction.y * abs(enemy_knockback.y)
				)
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
				## 统一按“目标 - 所在伤害格中心”的方向施加击退，保证上方/左右/下方都不会被反向。
				var source_pos: Vector2 = _resolve_source_world(body)
				var direction: Vector2 = (body.global_position - source_pos).normalized()
				if direction == Vector2.ZERO:
					direction = Vector2.UP
				var knockback: Vector2 = Vector2(
					direction.x * abs(enemy_knockback.x),
					direction.y * abs(enemy_knockback.y)
				)
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
	
	## 击退源点必须用玩家所在那格的中心，而不是整个 TileMap 图层的原点。
	## 这样站在尖刺正上方会被向上弹、在左侧会被向左弹、在右侧会被向右弹。
	var source_pos: Vector2 = to_global(map_to_local(cell))
	var dir: Vector2 = (body.global_position - source_pos).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.UP
	var kv: Vector2 = Vector2(
		dir.x * abs(kb.x),
		dir.y * abs(kb.y)
	)
	
	body.take_damage(source_pos, damage, final_type, kv)
	_damage_cooldown[body] = damage_cooldown_time

## 解析目标(玩家/敌人)当前所在(或相邻)的伤害格世界中心，作为击退源点。
## 找不到任何伤害格时退回本图层原点（旧行为，仅作兜底）。
func _resolve_source_world(body: Node) -> Vector2:
	var cell: Vector2i = local_to_map(to_local(body.global_position))
	if get_cell_tile_data(cell) != null:
		return to_global(map_to_local(cell))
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var near: Vector2i = cell + Vector2i(dx, dy)
			if get_cell_tile_data(near) != null:
				return to_global(map_to_local(near))
	return global_position
