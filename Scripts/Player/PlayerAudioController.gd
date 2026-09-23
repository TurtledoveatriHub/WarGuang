# PlayerAudioController.gd
## 玩家音效控制器 — 作为 Player 子节点，管理所有玩家动作音效。
## 所有音效通过 @export 暴露在 Inspector 中，支持拖拽替换为正式音效。
## ============================================================
## 🎵 音效资源配置（Inspector 拖拽）
## ============================================================

extends Node
class_name PlayerAudioController


@export_category("移动音效")
## 默认脚步声（无材质标记时的回退）
@export var default_step_sfx: AudioStream
## 行走脚步声（无表面检测时的回退）
@export var move_step_sfx: AudioStream
## 材质脚步声映射 — key=surface_type(int), value=AudioStream
## 在 TileSet 的 Custom Data Layers 中给 Tile 设置 surface_type 值（0=默认, 1=石头, 2=泥土…）
@export var surface_step_map: Dictionary = {}

@export_category("跳跃落地音效")
## 一段跳音效 — 地面起跳时播放
@export var jump1_sfx: AudioStream
## 二段跳音效 — 空中再次跳跃时播放
@export var jump2_sfx: AudioStream
## 奔跑跳跃音效 — 奔跑状态下起跳时播放（比普通起跳更厚重）
@export var run_jump_sfx: AudioStream
## 普通落地音效 — 从空中回到地面时播放
@export var landing_sfx: AudioStream
## 高空重落地音效 — 从高处下落落地时播放
@export var landing_heavy_sfx: AudioStream

@export_category("冲刺音效")
## 普通冲刺音效 — 地面或空中冲刺起始时播放
@export var dash_sfx: AudioStream
## 暗影冲刺音效 — 解锁黑冲后冲刺时播放
@export var black_dash_sfx: AudioStream

@export_category("滑翔攀墙墙跳音效")
## 滑翔音效 — 进入滑翔时播放一遍（不循环）
@export var glide_sfx: AudioStream
## 攀墙音效 — 抓住墙壁时播放一遍（不循环）
@export var wall_grip_sfx: AudioStream
## 墙跳音效 — 从墙壁弹跳时播放
@export var wall_jump_sfx: AudioStream
## 奔跑撞墙音效 — 奔跑时撞到墙壁时播放
@export var wall_bump_sfx: AudioStream

@export_category("受伤死亡音效")
## 受伤音效 — 受到伤害时播放（不分普通/传送，伤害方块音效由方块自身触发）
@export var hurt_sfx: AudioStream
## 死亡音效 — 玩家死亡时播放
@export var die_sfx: AudioStream

@export_category("超级冲刺音效")
## 超级冲刺蓄力音效 — 蓄力期间的持续音效（循环）
@export var super_dash_charge_sfx: AudioStream
## 超级冲刺蓄力完成音效 — 蓄力满时播放一遍（之后不再播蓄力音效，即使仍按住）
@export var super_dash_charge_complete_sfx: AudioStream
## 超级冲刺飞行起始音效 — 发射瞬间播放一遍
@export var super_dash_start_sfx: AudioStream
## 超级冲刺飞行循环音效 — 飞行期间持续播放（循环）
@export var super_dash_loop_sfx: AudioStream
## 超级冲刺结束音效 — 减速阶段播放
@export var super_dash_end_sfx: AudioStream

@export_category("后撤步音效")
## 后撤步音效 — 后撤步时播放
@export var backstep_sfx: AudioStream
## 后撤步防反成功音效 — 防反成功时播放
@export var backstep_counter_sfx: AudioStream

@export_category("特殊效果音效")
## 睡眠音效 — 玩家睡觉时播放
@export var sleep_sfx: AudioStream

## ============================================================
## ⚙️ 参数配置
## ============================================================

## 受伤时 BGM 闪避设置
@export_category("受伤 BGM 闪避")
## 受伤时 BGM 音量降低的时长（秒）
@export var hurt_bgm_duck_duration: float = 1.5
## 受伤时 BGM 降低到的音量（0~1, 0=静音, 1=原音量）
@export var hurt_bgm_duck_volume: float = 0.3

## 脚步声周期
@export_category("脚步声周期")
## 奔跑脚步声间隔（秒）
@export var run_step_interval: float = 0.2
## 走路脚步声间隔（秒）
@export var move_step_interval: float = 0.4

## ============================================================
## 🔗 内部变量
## ============================================================

## 绑定的玩家引用
var player: Player = null

## 脚步声周期计时器
var step_timer: float = 0.0
## 当前是否在脚步周期中
var is_step_active: bool = false

## 循环音效播放器映射（key → 占位标记）
var loop_keys: Dictionary = {}

## 超级冲刺飞行状态追踪
var was_super_dash_flying: bool = false
## 超级冲刺飞行循环是否已启动
var super_dash_loop_started: bool = false
## 蓄力完成音效是否已播放过（本次蓄力内只播一次）
var _charge_complete_played: bool = false

## ----- 表面检测缓存 -----
## 缓存的当前表面类型（-1=未知/无）
var _cached_surface_type: int = -1
## 表面类型缓存帧（避免每帧重复射线检测）
var _surface_cache_frame: int = -1

## ============================================================
## 🏗️ 初始化
## ============================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)

## 绑定玩家并注册反馈事件
func setup(player_ref: Player) -> void:
	player = player_ref
	if not is_instance_valid(player):
		return
	if player.has_method("register_feedback_hook"):
		player.register_feedback_hook(&"state_changed", Callable(self, "_on_state_changed"))
		player.register_feedback_hook(&"landed", Callable(self, "_on_landed"))
		player.register_feedback_hook(&"backstep_counter", Callable(self, "_on_backstep_counter"))
		player.register_feedback_hook(&"wall_bump", Callable(self, "_on_wall_bump"))
		player.register_feedback_hook(&"damage_taken", Callable(self, "_on_damage_taken"))

## ============================================================
## 🔄 每帧处理（脚步声 + 超级冲刺飞行循环管理）
## ============================================================

func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return
	_handle_step_sfx(delta)
	_handle_super_dash_audio()
	_handle_super_dash_charge_complete()

## 脚步声处理（含表面材质检测）
func _handle_step_sfx(delta: float) -> void:
	var state = player.current_state
	var should_step: bool = (state == player.PlayerState.RUN or state == player.PlayerState.MOVE) and player.is_on_floor()

	if should_step:
		if not is_step_active:
			is_step_active = true
			step_timer = 0.0
		else:
			step_timer += delta
			var interval = run_step_interval if state == player.PlayerState.RUN else move_step_interval
			if step_timer >= interval:
				step_timer = 0.0
				_play_one_shot(_get_step_sfx())
	else:
		is_step_active = false
		step_timer = 0.0

## 获取当前地面材质对应的脚步声 AudioStream
func _get_step_sfx() -> AudioStream:
	var surface_type: int = _detect_surface_type()
	if surface_type >= 0 and surface_step_map.has(surface_type):
		var stream = surface_step_map[surface_type]
		if stream is AudioStream:
			return stream
	if default_step_sfx:
		return default_step_sfx
	# 最后回退（没有 default_step_sfx 时静音）
	return null

## 通过射线检测玩家脚下的 TileMap 表面类型
func _detect_surface_type() -> int:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return -1
	var current_frame: int = Engine.get_process_frames()
	if current_frame == _surface_cache_frame:
		return _cached_surface_type
	_surface_cache_frame = current_frame
	_cached_surface_type = -1

	var space = player.get_world_2d().direct_space_state
	if not space:
		return -1
	var query = PhysicsRayQueryParameters2D.create(player.global_position, player.global_position + Vector2(0, 4.0))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var result = space.intersect_ray(query)
	if result.is_empty():
		return -1
	var collider = result.get("collider")
	if not collider:
		return -1

	# 检测脚下的 TileMapLayer / TileMap：统一通过其 tile_set 的“自定义数据层 surface_type”读取表面类型。
	# 注意本 Godot 版本：判断“是否存在该自定义数据层”用 TileSet.has_custom_data_layer_by_name，
	# 读取“某格该层的值”用 TileData.get_custom_data_by_layer_id。
	if collider is TileMapLayer or collider is TileMap:
		var local_pos: Vector2 = collider.to_local(result.get("position", Vector2.ZERO))
		var cell: Vector2i = collider.local_to_map(local_pos)
		var tile_data = collider.get_cell_tile_data(cell)
		_cached_surface_type = _read_surface_type(collider.tile_set, tile_data)
	return -1

## 从 TileSet 的 surface_type 自定义数据层读取格子表面类型；无该层/无数据/非 int → -1。
func _read_surface_type(tile_set_ref: TileSet, tile_data: TileData) -> int:
	if tile_set_ref == null or tile_data == null:
		return -1
	if not tile_set_ref.has_custom_data_layer_by_name("surface_type"):
		return -1
	var layer_id: int = tile_set_ref.get_custom_data_layer_by_name("surface_type")
	if layer_id < 0:
		return -1
	var value = tile_data.get_custom_data_by_layer_id(layer_id)
	if typeof(value) == TYPE_INT:
		return int(value)
	return -1

## 超级冲刺飞行音效管理
func _handle_super_dash_audio() -> void:
	var is_flying: bool = player.current_state == player.PlayerState.SUPERDASH
	var is_decelerating: bool = player.super_dash_deceleration_timer > 0.0

	if is_flying and not is_decelerating:
		# 飞行中（非减速阶段）
		if not was_super_dash_flying:
			# 刚进入飞行：播放起始一次音效
			_play_one_shot(super_dash_start_sfx)
			super_dash_loop_started = false
		elif not super_dash_loop_started:
			# 起始音效放完后（下一帧），启动循环音效
			_start_loop("super_dash_flight", super_dash_loop_sfx)
			super_dash_loop_started = true
	elif is_flying and is_decelerating:
		# 减速阶段：停止循环，播放结束音效
		if was_super_dash_flying and super_dash_loop_started:
			_stop_loop("super_dash_flight")
			super_dash_loop_started = false
		if was_super_dash_flying and not super_dash_loop_started:
			_play_one_shot(super_dash_end_sfx)
			super_dash_loop_started = false
	else:
		# 不在飞行状态：清理状态
		if was_super_dash_flying:
			_stop_loop("super_dash_flight")
		super_dash_loop_started = false

	was_super_dash_flying = is_flying

## 蓄力完成检测：蓄力满时停掉蓄力循环音效，并播一遍“蓄力完成”音效
## （之后即使仍按住超级冲刺键，也不会再播 super_dash_charge_sfx）
func _handle_super_dash_charge_complete() -> void:
	if not is_instance_valid(player):
		return
	if player.current_state != player.PlayerState.SUPERDASHSTART:
		_charge_complete_played = false
		return
	if _charge_complete_played:
		return
	if player.super_dash_charge_timer < player.super_dash_charge_time:
		return
	_charge_complete_played = true
	_stop_loop("super_dash_charge")
	_play_one_shot(super_dash_charge_complete_sfx)


## ============================================================
## 🎬 反馈事件处理
## ============================================================

## 状态切换事件 — 触发一次性音效
func _on_state_changed(payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	var from_state = payload.get("from", -1)
	var to_state = payload.get("to", -1)
	if from_state == to_state:
		return

	## 进入状态处理
	match to_state:
		player.PlayerState.JUMP:
			# 垂直冲刺结束会自然进入 JUMP/DOWN（速度向上），这不是真正跳跃，不播跳跃音效；
			# 否则上冲刺会以“跳跃音效”收尾（冲刺起始的 dash_sfx 已经播过）。
			if from_state == player.PlayerState.DASH and player.dash_locked_vector.y != 0:
				pass
			# 二段跳优先（不受奔跑跳跃影响），其次奔跑跳跃替换一段跳
			elif player.has_double_jumped:
				_play_one_shot(jump2_sfx)
			elif player.is_run_jumping:
				_play_one_shot(run_jump_sfx)
			else:
				_play_one_shot(jump1_sfx)

		player.PlayerState.DASH:
			if player.black_dash_unlocked:
				_play_one_shot(black_dash_sfx)
			else:
				_play_one_shot(dash_sfx)

		player.PlayerState.GLIDE:
			_play_one_shot(glide_sfx)

		player.PlayerState.WALLGRIP:
			_play_one_shot(wall_grip_sfx)

		player.PlayerState.WALLJUMP:
			_play_one_shot(wall_jump_sfx)

		player.PlayerState.HURT:
			_play_one_shot(hurt_sfx)

		player.PlayerState.DIE:
			_play_one_shot(die_sfx)

		player.PlayerState.SUPERDASHSTART:
			_charge_complete_played = false
			_start_loop("super_dash_charge", super_dash_charge_sfx)

		player.PlayerState.BACKSTEP:
			_play_one_shot(backstep_sfx)

		player.PlayerState.SLEEP:
			_play_one_shot(sleep_sfx)

	## 离开状态处理
	match from_state:
		player.PlayerState.SUPERDASHSTART:
			_stop_loop("super_dash_charge")
			_charge_complete_played = false

## 落地事件 — 根据下落速度区分普通落地/重落地
func _on_landed(payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	var velocity = payload.get("velocity", Vector2.ZERO)
	if abs(velocity.y) >= abs(player.max_fall_speed * 0.9):
		_play_one_shot(landing_heavy_sfx)
	else:
		_play_one_shot(landing_sfx)

## 后撤步防反成功事件
func _on_backstep_counter(_payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	_play_one_shot(backstep_counter_sfx)

## 奔跑撞墙事件
func _on_wall_bump(_payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	_play_one_shot(wall_bump_sfx)

## 受伤事件 — 触发 BGM 闪避（空洞骑士式效果）
func _on_damage_taken(_payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	AudioManager.duck_bgm_for_sfx(hurt_bgm_duck_duration, hurt_bgm_duck_volume)

## ============================================================
## 🔊 音效播放工具
## ============================================================

## 播放一次性音效
func _play_one_shot(stream: AudioStream) -> void:
	if not stream:
		return
	AudioManager.play_stream_sfx(stream)

## 启动循环音效
func _start_loop(key: String, stream: AudioStream) -> void:
	if not stream:
		return
	if loop_keys.has(key):
		return
	AudioManager.play_stream_looped(key, stream)
	loop_keys[key] = true

## 停止循环音效
func _stop_loop(key: String) -> void:
	if not loop_keys.has(key):
		return
	AudioManager.stop_stream_looped(key)
	loop_keys.erase(key)
