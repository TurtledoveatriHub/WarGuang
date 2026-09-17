extends TileMapLayer
## 隐藏房间 / 隐藏背景效果（把本脚本挂到持有“隐藏背景/隐藏房间”瓦片的 TileMapLayer 上）。
##
## 目标：一个隐藏区域 = 一个 TileMapLayer（本脚本只影响自身这一层）。
##   Player 踩到本层“任意瓦片”并持续按住 trigger_hold_time 秒后，
##   整层 modulate 淡出并隐藏，同时播放 reveal_sfx；
##   若 permanent_hide=false，每次 Player 离开本层瓦片后再淡入渐显（可再次触发）。
##   中途离开（不足 trigger_hold_time）会清零计时，不触发淡出。
##
## 不同隐藏房间请分别放在不同的 TileMapLayer 上：脚本只读写 self 的
## modulate / visible，各层互不影响（即使共用同一个 TileSet 也互不影响）。

@export_category("隐藏区域")
## 是否永久淡出（默认 true）。
## 若设为 false：首次触发淡出后，每次 Player 离开本层瓦片时再淡入渐显（可再次触发淡出）。
@export var permanent_hide: bool = true
## 淡出时长（秒）
@export var fade_out_duration: float = 0.5
## 淡入时长（秒，仅 permanent_hide=false 时用到）
@export var fade_in_duration: float = 0.5
## 触发淡出前，Player 需“持续踩在本层任意瓦片上”的时长（秒）。
## 中途离开本层瓦片会清零计时，不会触发淡出。
@export var trigger_hold_time: float = 1.0
## 首次激活（淡出开始）时播放的音效（走 AudioManager 的 SFX 总线）
@export var reveal_sfx: AudioStream = null
## 存档标识（用于跨存档记录“本层已永久淡出”）。留空时自动使用 room_id::本层节点名。
@export var save_id: String = ""

## 当前是否处于“淡出隐藏”状态
var _faded_out: bool = false
## 永久隐藏已完成（停止处理）
var _done: bool = false
## 当前 tween（避免叠加）
var _tween: Tween = null
## Player 已“持续踩在本层瓦片上”的累计时长（秒）
var _touch_hold_time: float = 0.0
## “有瓦片”的格子集合（有效格）
var _used_cells: Dictionary = {}


## 无效格子哨兵值
const INVALID_CELL: Vector2i = Vector2i(999999, 999999)


func _ready() -> void:
	_used_cells.clear()
	for cell in get_used_cells():
		if get_cell_source_id(cell) != -1:
			_used_cells[cell] = true
	# 该层已在存档中被记录为“永久淡出”：加载时直接保持隐藏，不再处理触发。
	if _is_activated_in_save():
		_faded_out = true
		_done = true
		visible = false
		modulate.a = 0.0
		set_physics_process(false)


## 解析所在房间 ID（与 GroundParallaxController 同款逻辑）。
func _resolve_room_id() -> String:
	var current: Node = self
	while current:
		if current.has_method("get_room_data"):
			var data: Dictionary = current.get_room_data()
			if data.has("id"):
				return str(data.id)
		current = current.get_parent()
	return ""


## 计算本层的存档标识：优先使用自定义 save_id，否则 room_id::本层节点名。
func _compute_save_id() -> String:
	if save_id.strip_edges() != "":
		return save_id
	var region := str(name)
	var room_id := _resolve_room_id()
	if room_id != "":
		region = room_id + "::" + region
	return region


## 该层是否已在存档中被记录为永久淡出。
func _is_activated_in_save() -> bool:
	if not Global:
		return false
	if Global.has_method("is_hidden_room_activated"):
		return Global.is_hidden_room_activated(_compute_save_id())
	return false


func _physics_process(_delta: float) -> void:
	if _done:
		return
	var touching := _player_touches_used()
	if not touching:
		# 未踩在本层瓦片上：清零计时；若为非永久隐藏，玩家离开后淡入渐显。
		_touch_hold_time = 0.0
		if _faded_out and not permanent_hide:
			_start_fade_in()
		return
	# 已处于淡出隐藏状态（且仍在本层内）：维持隐藏，不做任何事。
	if _faded_out:
		return
	# 持续踩在本层瓦片累计时长，达到 trigger_hold_time 才触发淡出（含音效）。
	_touch_hold_time += _delta
	if _touch_hold_time >= trigger_hold_time:
		_start_fade_out()


## 玩家是否踩在本层任意有效瓦片上（只判定玩家脚下那一格）。
func _player_touches_used() -> bool:
	var cell := _player_cell()
	if cell == INVALID_CELL:
		return false
	return _used_cells.has(cell)


## 玩家当前所在格；找不到玩家返回无效值。
func _player_cell() -> Vector2i:
	var player := get_tree().get_first_node_in_group("player")
	if not is_instance_valid(player) or not player.is_inside_tree():
		return INVALID_CELL
	return local_to_map(to_local(player.global_position))


## 用法 A：整层淡出隐藏（激活；播放音效）。
func _start_fade_out() -> void:
	if _faded_out or _done:
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	_faded_out = true
	_play_reveal_sfx()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, maxf(fade_out_duration, 0.001))
	_tween.tween_callback(func():
		visible = false
		if permanent_hide:
			# 登记到存档数据（到存档点/菜单保存时写入磁盘，重进后仍保持淡出）。
			if Global and Global.has_method("mark_hidden_room_activated"):
				Global.mark_hidden_room_activated(_compute_save_id())
			_done = true
			set_physics_process(false)
	)


## 用法 A：整层淡入渐显（Player 离开隐藏区域后）。
func _start_fade_in() -> void:
	if not _faded_out or _done:
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	visible = true
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, maxf(fade_in_duration, 0.001))
	_tween.tween_callback(func():
		_faded_out = false
	)


func _play_reveal_sfx() -> void:
	if reveal_sfx == null:
		return
	if AudioManager and AudioManager.has_method("play_stream_sfx"):
		AudioManager.play_stream_sfx(reveal_sfx)
