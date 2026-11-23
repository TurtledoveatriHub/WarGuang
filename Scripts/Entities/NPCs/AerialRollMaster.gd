extends BaseNPC
class_name AerialRollMaster
## 空中翻滚大师：第一次对话授予二段跳，之后不再教学。

## 动画状态名（本 NPC 只用固定的 IDLE / TALK，不做导出配置）
var idle_animation: String = "IDLE"
var talk_animation: String = "TALK"

@export_category("待机翻滚")
## 翻滚动画名（SpriteFrames 里必须是 loop = false，否则播完不会发 animation_finished）
@export var aerial_roll_animation: String = "AerialRoll"
## 每隔多少秒判定一次（只在本 NPC 处于待机且没在对话时累计）
@export var aerial_roll_interval: float = 1.0
## 每次判定触发翻滚的概率（0~1）
@export_range(0.0, 1.0, 0.05) var aerial_roll_chance: float = 0.75

@export_category("翻滚音效")
## 切到翻滚动画时，从这两个里随机播一个
@export var roll_sfx_a: AudioStream
@export var roll_sfx_b: AudioStream
## 从其它状态回到待机（翻滚结束 / 对话结束）时播一次
@export var idle_sfx_c: AudioStream

@export_category("音效空间感")
## 超过这个距离就完全听不到（像素）
@export var sfx_max_distance: float = 420.0
## 衰减陡峭程度：越大越「近处响、远处轻」
@export_range(0.0, 4.0, 0.1) var sfx_attenuation: float = 1.8
## 基础音量（分贝）
@export var sfx_volume_db: float = 0.0

## 本 NPC 专属的 2D 音源。
## ★ 空间感（玩家越远声音越小）直接交给 AudioStreamPlayer2D 自己算：
##   它以当前 Camera2D 为听者，按 attenuation / max_distance 自动衰减，
##   不用每帧手算距离，也不会因为相机缩放 / 暂停而算错。
var _sfx_player: AudioStreamPlayer2D = null
## 待机判定计时（秒）
var _roll_timer: float = 0.0
## 是否正在翻滚（翻滚期间不允许交互）
var _rolling: bool = false

func _ready():
	npc_id = "AerialRollMaster"
	super._ready()
	_setup_sfx_player()
	if animated_sprite:
		if not animated_sprite.animation_finished.is_connected(_on_animation_finished):
			animated_sprite.animation_finished.connect(_on_animation_finished)
	_play_default_idle()


## 每帧：只在「待机 + 没在对话 + 没在翻滚」时累计计时，到点后按概率翻滚
func _process(delta):
	super._process(delta)
	if _rolling or is_talking:
		return
	if not _is_idle_now():
		return
	_roll_timer += delta
	if _roll_timer < aerial_roll_interval:
		return
	_roll_timer = 0.0
	if randf() < aerial_roll_chance:
		_start_aerial_roll()


## 翻滚期间不响应交互
func try_interact():
	if _rolling:
		return
	super.try_interact()


## 当前是否确实停在待机动画上
func _is_idle_now() -> bool:
	if animated_sprite == null:
		return false
	return str(animated_sprite.animation) == idle_animation


## 开始翻滚：切动画 + 随机播 A / B 之一，期间把交互提示藏起来
func _start_aerial_roll() -> void:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	if not animated_sprite.sprite_frames.has_animation(aerial_roll_animation):
		push_warning("AerialRollMaster: SpriteFrames 里没有动画 " + aerial_roll_animation)
		return
	_rolling = true
	_roll_timer = 0.0
	if interaction_prompt:
		interaction_prompt.visible = false
	_play_spatial_sfx(_pick_random_sfx([roll_sfx_a, roll_sfx_b]))
	animated_sprite.play(aerial_roll_animation)


## 动画播完（AerialRoll 的 loop 必须为 false 才会触发）
func _on_animation_finished() -> void:
	if not _rolling:
		return
	_rolling = false
	_play_default_idle()
	_play_idle_sfx()
	if interaction_prompt and player_in_range and not is_talking:
		interaction_prompt.visible = true


## 回到待机时的音效（C）
func _play_idle_sfx() -> void:
	_play_spatial_sfx(idle_sfx_c)


## 从候选里随机取一个非空音效；全空返回 null
func _pick_random_sfx(candidates: Array) -> AudioStream:
	var valid: Array = []
	for candidate: Variant in candidates:
		if candidate is AudioStream:
			valid.append(candidate)
	if valid.is_empty():
		return null
	return valid[randi() % valid.size()]


## 建一个专属 AudioStreamPlayer2D（总线与全局 SFX 保持一致）
func _setup_sfx_player() -> void:
	_sfx_player = AudioStreamPlayer2D.new()
	_sfx_player.name = "NpcSfxPlayer"
	_sfx_player.bus = "SFX"
	_sfx_player.max_distance = sfx_max_distance
	_sfx_player.attenuation = sfx_attenuation
	_sfx_player.volume_db = sfx_volume_db
	add_child(_sfx_player)


## 播一个带空间衰减的音效（空音效直接忽略）
func _play_spatial_sfx(stream: AudioStream) -> void:
	if stream == null or _sfx_player == null:
		return
	_sfx_player.stream = stream
	_sfx_player.play()


## 覆盖基类：翻滚期间不能交互；开始对话前先标记「本次对话由本 NPC 发起」
func _start_interaction():
	# 翻滚过程中不接受交互（try_interact 已挡一层，这里再兜一层）
	if _rolling:
		return
	# ★ dialogue_ended 是全局信号：必须靠 owns_dialogue 过滤，否则会触发其它 NPC 的收尾
	owns_dialogue = true
	_play_random_interact_sound()
	var player = get_tree().get_first_node_in_group("player")
	var task_manager = get_node_or_null("/root/TaskManager")
	
	if not player:
		return
	
	if not dialogue_resource:
		return
	
	if animated_sprite and animated_sprite.sprite_frames:
		if animated_sprite.sprite_frames.has_animation(talk_animation):
			play_animation(talk_animation)
	
	var dialogue_count = TaskManager.get_npc_dialogue_count(npc_id)
	
	var balloon: Node = MyDialogueBalloon.acquire(get_tree().current_scene, balloon_scene)
	if balloon == null:
		return
	
	if dialogue_count == 0:
		_grant_double_jump(player)
		balloon.start(dialogue_resource, "first_meeting", [])
	else:
		balloon.start(dialogue_resource, "no_more_teachings", [])
	
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)


## 授予二段跳。Player 与 Global 两边都要写：前者是本局立即生效，后者是存档数据。
func _grant_double_jump(player):
	if player.has_method("unlock_ability"):
		player.unlock_ability("double_jump")
	
	Global.unlock_ability("double_jump")


func _on_dialogue_ended():
	# ★ 只处理「由本 NPC 发起」的那次对话收尾（dialogue_ended 是全局信号）
	if not owns_dialogue:
		return
	await get_tree().process_frame
	super._on_dialogue_ended()
	_play_default_idle()
	# 对话结束回到待机 → 播 C 音效
	_play_idle_sfx()
