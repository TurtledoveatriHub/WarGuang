# Scripts/Enemys/SacredBird.gd
## 神鸟 —— 特殊事件飞行敌怪（继承 FlyingEnemy，复用其仇恨/弹幕/突进全部逻辑）
## 在基础之上追加：
##   1. 首次发现玩家时触发一次演出（相机抖动 + 专属音效）。
##   2. 发现玩家后周期性召唤小怪（约每 summon_interval 秒一次，场上存活 summon_cap 只）。
##      小怪被放到“当前容器”（即本房间的怪物容器），玩家切换房间时随容器一起自然消失。
##   3. 预留“放置指定道具后不再出现”：disappear_progress_flag 置位后，将来接入
##      全局进度（ProgressManager.has_flag）时会自行消失；道具系统未做前留空即可。
extends FlyingEnemy
class_name SacredBird

## 召唤物组名（用于统计场上存活召唤物）
const MINION_GROUP: StringName = &"sacred_bird_minion"

## ── 神鸟·召唤 ──
@export_category("神鸟·召唤")
## 被召唤的小怪场景（默认 SnowBird 飞行怪）
@export var minion_scene: PackedScene
## 彩蛋小怪场景：每次召唤以 bonus_minion_chance 概率改为召唤它（可为空=无彩蛋）
@export var bonus_minion_scene: PackedScene
## 召唤彩蛋小怪的概率（0~1）
@export var bonus_minion_chance: float = 0.25
## 发现玩家后“首次召唤”的等待（秒）
@export var summon_first_delay: float = 12.0
## 后续召唤间隔（秒）
@export var summon_interval: float = 36.0
## 场上存活召唤物上限（切房间后随房间容器销毁）
@export var summon_cap: int = 3
## 召唤点相对自身随机散布范围（x 横向 / y 纵向，像素）
@export var summon_offset: Vector2 = Vector2(120, 60)
## 召唤预警动画时长（秒，期间播放 Attack 动画）
@export var summon_telegraph: float = 0.7
## 召唤音效（可留空）
@export var summon_sfx: AudioStream

## ── 神鸟·首次遭遇 ──
@export_category("神鸟·首次遭遇")
## 是否启用首次遭遇演出
@export var enable_first_effects: bool = true
## 相机抖动预设名（走 CameraShakeManager）
@export var first_shake_preset: String = "general_strong"
## 首次遭遇专属音效（可留空）
@export var first_encounter_sfx: AudioStream

## ── 神鸟·出现控制 ──
@export_category("神鸟·出现控制")
## 预留：该进度标记被置位后此神鸟不再出现（需未来 ProgressManager.has_flag；留空=总是出现）
@export var disappear_progress_flag: String = ""

## 是否已处于“召唤周期”中（发现玩家）
var _summon_engaged: bool = false
## 召唤倒计时（秒）
var _summon_cd: float = 0.0
## 召唤预警倒计时（秒，>0 表示正在播召唤预警）
var _summon_pending: float = 0.0
## 首次演出是否已触发（本实例生命周期内只一次）
var _first_effect_done: bool = false


func _ready() -> void:
	super()
	if _is_disabled_by_progress():
		queue_free()


func _physics_process(d: float) -> void:
	super(d)
	_update_summons(d)


## 是否被进度标记禁用（道具放置后不再出现；道具系统未接入前始终 false）
func _is_disabled_by_progress() -> bool:
	if disappear_progress_flag.is_empty():
		return false
	var pm: Node = get_node_or_null("/root/ProgressManager")
	if pm and pm.has_method("has_flag"):
		return pm.has_flag(disappear_progress_flag)
	return false


## 覆写发现：仅在“新建立仇恨”时进入召唤周期并触发首次演出
func _on_player_detected(body: Node) -> void:
	var had_target: bool = _player != null and is_instance_valid(_player)
	super(body)
	if had_target:
		return
	if _player != body:
		return
	_on_engage()


## 进入交战时：开始召唤周期，首次遭遇时触发演出
func _on_engage() -> void:
	_summon_engaged = true
	_summon_cd = summon_first_delay
	_summon_pending = 0.0
	if not _first_effect_done and enable_first_effects:
		_first_effect_done = true
		_do_first_encounter_fx()


## 首次遭遇演出：专属音效 + 相机抖动
func _do_first_encounter_fx() -> void:
	_play_sfx(first_encounter_sfx)
	var cam: Node = null
	if _player:
		var v: Variant = _player.get("phantom_camera")
		if v is Node:
			cam = v
	var sm: Node = get_node_or_null("/root/CameraShakeManager")
	if sm and sm.has_method("shake"):
		sm.shake(first_shake_preset, cam)


## 每帧更新召唤（低频判断，仅在交战时进行）
func _update_summons(d: float) -> void:
	if _base and _base.has_method("is_dead") and _base.is_dead():
		return
	if not is_instance_valid(_player):
		_summon_engaged = false
		return
	if not _summon_engaged:
		return
	if _state != State.CHASE and _state != State.ATTACK:
		return
	if _summon_pending > 0.0:
		# 召唤预警阶段
		_summon_pending -= d
		if _summon_pending <= 0.0:
			_summon_pending = 0.0
			_do_summon()
		return
	_summon_cd -= d
	if _summon_cd <= 0.0 and _count_minions() < summon_cap:
		# 达到召唤时机：先播放预警，再实际生成
		_summon_pending = summon_telegraph
		_play("Attack")


## 统计场上存活召唤物数量（用于上限控制）
func _count_minions() -> int:
	var c: int = 0
	for n in get_tree().get_nodes_in_group(MINION_GROUP):
		if is_instance_valid(n):
			c += 1
	return c


## 生成一只小怪：放入当前容器（切房间随容器自然销毁），并加入组以便统计上限
func _do_summon() -> void:
	_summon_cd = summon_interval
	# 彩蛋：以一定概率召唤另一小怪类型（上限不变，只替换生成场景）
	var scene_to_spawn: PackedScene = minion_scene
	if bonus_minion_scene != null and randf() < bonus_minion_chance:
		scene_to_spawn = bonus_minion_scene
	if scene_to_spawn == null:
		return
	var m: Node = scene_to_spawn.instantiate()
	var pos: Vector2 = global_position + Vector2(
		randf_range(-summon_offset.x, summon_offset.x),
		randf_range(-summon_offset.y, summon_offset.y)
	)
	m.global_position = pos
	m.add_to_group(MINION_GROUP)
	var container: Node = get_parent()
	if container:
		container.add_child(m)
	_play_sfx(summon_sfx)


## 播放音效（经 AudioManager；/root 路径查找，兼容未启动 autoload 的场景）
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_stream_sfx"):
		am.play_stream_sfx(stream)
