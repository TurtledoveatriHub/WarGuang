extends Area2D
class_name BaseNPC

## NPC 唯一标识符（TaskManager 按它统计对话次数，子类一般在 _ready 里写死）
var npc_id: String = ""

@export_category("对话")
## 对话资源（.dialogue）；为空时交互不做任何事
@export var dialogue_resource: DialogueResource
## 对话气泡场景；留空时自动使用 ScenePaths.UI_MY_BALLOON
@export var balloon_scene: PackedScene
## 只允许交互一次：第一次对话结束后不再响应交互提示
@export var interact_once: bool = false

@export_category("音效")
## 交互音效候选：玩家与之交互时随机抽一个播一次
@export var npc_interact_sounds: Array[AudioStream]

@export_category("看向玩家")
## 开启后 NPC 会左右转去看玩家（不是镜像纹理，而是切换到另一套动画）。
## 需要的动画：IDLE_L / IDLE_R / TALK_L / TALK_R / TURN_L→R（缺少时不报错，会退回普通动画）。
@export var enable_player_facing: bool = false
## 默认朝向：true = 面朝右（玩家太远或刚进场景时用）
@export var default_facing_right: bool = true
## 死区：玩家横向偏离超过这个像素数才认为「在另一边」（避免玩家站正上方时反复抽动）
@export var facing_dead_zone: float = 24.0
## 兴趣范围：玩家超过这个距离就不理会（屏幕外的玩家不该让 NPC 转来转去）
@export var facing_interest_radius: float = 320.0
## 转向间隙（秒）：方向变了要等这么久、且方向仍然没变，才真的转过去
@export var facing_turn_cooldown: float = 0.35
## 转身过渡动画名（L→R / R→L 共用；SpriteFrames 里没有就直接切姿势）
@export var turn_animation: String = "TURN_L→R"

@onready var animated_sprite = $AnimatedSprite2D if has_node("AnimatedSprite2D") else null
@onready var interaction_prompt = $InteractionPrompt if has_node("InteractionPrompt") else null

var player_in_range: bool = false
var has_interacted: bool = false
var is_talking: bool = false

## 本次对话是否由本 NPC 发起。
## ★ DialogueSystem 的 dialogue_ended 是**全局信号**，场上每个 NPC 的处理器都会收到，
##   必须靠这个标志过滤 —— 否则会互相触发对方的收尾逻辑
##   （典型症状：和 MasterNPC 说完话，结束时却播了商人的「没买东西」音效、
##     并且所有 NPC 的动画都被重置成待机）。
var owns_dialogue: bool = false

## 当前朝向（true = 朝右）；enable_player_facing 打开时生效
var facing_right: bool = true
## 待确认的朝向（等冷却结束才落地）。与 facing_right 相同时表示没有待切换
var _pending_facing_right: bool = true
## 转向冷却剩余时间（秒）
var _turn_cooldown_timer: float = 0.0
## 是否正在播转身过渡动画
var _turning: bool = false

func _ready():
	# 朝向玩家：初始朝向由导出决定
	facing_right = default_facing_right
	_pending_facing_right = facing_right
	var ds = get_node_or_null("/root/DialogueSystem")
	if ds:
		if ds.has_signal("dialogue_started"):
			ds.dialogue_started.connect(_on_dialogue_started)
		if ds.has_signal("dialogue_ended"):
			ds.dialogue_ended.connect(_on_dialogue_ended)
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)
	if not body_exited.is_connected(_on_body_exited):
		body_exited.connect(_on_body_exited)
	if interaction_prompt:
		interaction_prompt.visible = false
	_play_default_idle()

func _process(delta):
	# 看向玩家（开关打开时）：死区 + 冷却判定
	if enable_player_facing:
		_update_player_facing(delta)
	if player_in_range:
		if Input.is_action_just_pressed("interactive"):
			try_interact()

## 尝试与 NPC 交互（子类可覆盖）
func try_interact():
	if not player_in_range:
		return
	
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	var in_dialogue = false
	if dialogue_system:
		in_dialogue = dialogue_system.is_dialogue_active
	
	if in_dialogue:
		return
	
	if interact_once and has_interacted:
		return
	
	_start_interaction()

func _start_interaction():
	owns_dialogue = true
	_play_random_interact_sound()
	var task_manager = get_node_or_null("/root/TaskManager")
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)
	
	if not balloon_scene:
		balloon_scene = load(ScenePaths.UI_MY_BALLOON)
	
	if not balloon_scene:
		push_error("BaseNPC: balloon_scene 未配置！")
		return
	
	var balloon = balloon_scene.instantiate()
	get_tree().current_scene.add_child(balloon)
	
	if balloon.has_method("set_dialogue"):
		balloon.set_dialogue(dialogue_resource, self)
	
	if interaction_prompt:
		interaction_prompt.visible = false

## 播放指定动画（动画不存在时只打字告警，不会报错）
func play_animation(animation_name: String):
	if not animated_sprite:
		return
	
	if not animated_sprite.sprite_frames:
		return
	
	if animated_sprite.sprite_frames.has_animation(animation_name):
		animated_sprite.play(animation_name)
	else:
		print("警告：NPC ", npc_id, " 没有动画:", animation_name)

func _play_default_idle():
	# 开启「看向玩家」时走 IDLE_L / IDLE_R（没有对应动画会自动退回 IDLE）
	if enable_player_facing:
		_play_facing_animation("IDLE")
		return
	if animated_sprite and animated_sprite.sprite_frames:
		var idle_names = ["IDLE", "idle", "Idle"]
		for animation_name in idle_names:
			if animated_sprite.sprite_frames.has_animation(animation_name):
				animated_sprite.play(animation_name)
				return

func _on_dialogue_started():
	is_talking = true
	# 开启「看向玩家」时：说话动画也按当前朝向取（TALK_L / TALK_R）
	if enable_player_facing:
		_play_facing_animation("TALK")

## 交互时从 npc_interact_sounds 里随机播一个（空槽会被跳过）
func _play_random_interact_sound() -> void:
	if npc_interact_sounds.is_empty():
		return
	var index: int = randi() % npc_interact_sounds.size()
	var stream: AudioStream = npc_interact_sounds[index]
	if stream != null:
		AudioManager.play_stream_sfx(stream)

func _on_dialogue_ended():
	# ★ 只处理「由本 NPC 发起」的那次对话收尾（dialogue_ended 是全局信号）
	if not owns_dialogue:
		return
	owns_dialogue = false
	await get_tree().process_frame
	is_talking = false
	
	if interact_once:
		has_interacted = true
		if interaction_prompt:
			interaction_prompt.visible = false

## ============================ 看向玩家 ============================
## 设计：不做纹理镜像，而是切到另一套动画（IDLE_L/IDLE_R、TALK_L/TALK_R）。
## 判定用「死区 + 冷却」两道闸门，解决玩家在正上方或快速左右横跳时反复抖动的问题。

## 每帧判定：方向变了先进入「待确认」，冷却结束且方向仍不变才真正转过去
func _update_player_facing(delta: float) -> void:
	if _turning:
		return
	if _turn_cooldown_timer > 0.0:
		_turn_cooldown_timer = maxf(_turn_cooldown_timer - delta, 0.0)
		if _turn_cooldown_timer > 0.0:
			return
		# 冷却结束：再确认一次，方向仍未变才落地
		if _pending_facing_right != facing_right:
			_commit_facing(_pending_facing_right)
		return
	var player: Node2D = _get_facing_player()
	if player == null:
		return
	if facing_interest_radius > 0.0 and global_position.distance_to(player.global_position) > facing_interest_radius:
		return
	var dx: float = player.global_position.x - global_position.x
	if absf(dx) <= facing_dead_zone:
		return
	var desired_right: bool = dx > 0.0
	if desired_right == facing_right:
		return
	# 先记下待切朝向，等冷却结束再确认 —— 这一段就是「时间间隙」
	_pending_facing_right = desired_right
	_turn_cooldown_timer = facing_turn_cooldown


## 取玩家节点（不在场景树里就算了）
func _get_facing_player() -> Node2D:
	if not is_inside_tree():
		return null
	var player: Node = get_tree().get_first_node_in_group("player")
	if player is Node2D:
		return player
	return null


## 真正切换朝向：对话中直接换姿势，待机时先播一遍转身过渡动画
func _commit_facing(right: bool) -> void:
	facing_right = right
	_pending_facing_right = right
	_turn_cooldown_timer = 0.0
	if is_talking:
		_play_facing_animation("TALK")
		return
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	if animated_sprite.sprite_frames.has_animation(turn_animation):
		_turning = true
		animated_sprite.play(turn_animation)
		if not animated_sprite.animation_finished.is_connected(_on_turn_animation_finished):
			animated_sprite.animation_finished.connect(_on_turn_animation_finished, CONNECT_ONE_SHOT)
	else:
		_play_default_idle()


## 转身过渡播完 → 回到待机
func _on_turn_animation_finished() -> void:
	_turning = false
	_play_default_idle()


## 按「动画名_朝向」播放（IDLE_L / IDLE_R / TALK_L / TALK_R）；
## 对应朝向的动画不存在时退回不带后缀的名字，保证没配朝向动画的 NPC 照常工作。
func _play_facing_animation(base_name: String) -> void:
	if not enable_player_facing:
		play_animation(base_name)
		return
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	var target: String = base_name + ("_R" if facing_right else "_L")
	if animated_sprite.sprite_frames.has_animation(target):
		animated_sprite.play(target)
		return
	play_animation(base_name)


func _on_body_entered(body):
	if body.is_in_group("player"):
		player_in_range = true
		var player = get_tree().get_first_node_in_group("player")
		if player and player.current_state == player.PlayerState.DASH:
			if interaction_prompt:
				interaction_prompt.visible = false
		else:
			if !interact_once or (interact_once and !has_interacted):
				if interaction_prompt:
					interaction_prompt.visible = true

func _on_body_exited(body):
	if body.is_in_group("player"):
		player_in_range = false
		if interaction_prompt:
			interaction_prompt.visible = false
