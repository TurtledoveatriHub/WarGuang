extends BaseNPC
class_name Maniac

## ── 巡逻设置 ──
## 活动范围宽度（以编辑器初始位置为中心，左右各 patrol_width/2）
@export var patrol_width: float = 200.0
## MOVE 状态下的移动速度
@export var move_speed: float = 180.0

## ── 挑战系统 ──
## ChallengeController 的 NodePath
@export_node_path var challenge_controller_path: NodePath

var challenge_controller: ChallengeController = null
var current_challenge_stage: int = 0

## 动画状态配置（内部变量）
## idle_animation: 待机空闲动画名称
var idle_animation: String = "IDLE"

## move_animation: 巡逻移动动画名称
var move_animation: String = "MOVE"

## talk_animation: 对话交互动画名称
var talk_animation: String = "TALK"

## impressed_animation: 对玩家表现印象深刻时的动画名称
var impressed_animation: String = "IMPRESSED"

## amazed_animation: 对玩家表现感到惊讶时的动画名称
var amazed_animation: String = "AMAZED"

## stunned_animation: 对玩家表现感到震惊时的动画名称
var stunned_animation: String = "STUNNED"

## go_fanatical_animation: 狂热状态动画名称（此状态下不可交互）
var go_fanatical_animation: String = "GOFANATICAL"

# 待机状态枚举
enum IdleState { IDLE, MOVE, GOFANATICAL }

# 交互状态枚举
enum InteractionState { TALK, IMPRESSED, AMAZED, STUNNED }

# 状态变量
var current_idle_state: IdleState = IdleState.IDLE
var state_timer: float = 0.0
var state_duration: float = 8.0
var initial_position: Vector2
var patrol_bounds: Rect2
var afterimage_trail: Node = null
var afterimage_timer: float = 0.0



## 缓存的对话系统引用（_ready 里取一次）
var _dialogue_system: Node = null
## 缓存的玩家引用（避免每帧做组查找）
var _player_ref: Node = null

## 取玩家节点（带缓存）
func _get_player() -> Node:
	if is_instance_valid(_player_ref):
		return _player_ref
	_player_ref = get_tree().get_first_node_in_group("player")
	return _player_ref

## 身体进入信号处理（覆盖 BaseNPC）
func _on_body_entered(body):
	if body.is_in_group("player"):
		player_in_range = true
		_update_interaction_prompt_visibility()

## 身体离开信号处理（覆盖 BaseNPC）
func _on_body_exited(body):
	if body.is_in_group("player"):
		player_in_range = false
		if interaction_prompt:
			interaction_prompt.visible = false

func _init_patrol_bounds():
	pass

func _ready():
	super._ready()
	npc_id = "Maniac"
	initial_position = position
	# 缓存对话系统引用：原来每帧 get_node_or_null("/root/DialogueSystem") 是热路径上的多余开销
	_dialogue_system = get_node_or_null("/root/DialogueSystem")

func _process(delta):
	super._process(delta)
	
	var in_dialogue = _dialogue_system != null and _dialogue_system.is_dialogue_active
	var in_challenge = challenge_controller and challenge_controller.current_state == ChallengeController.State.ACTIVE
	
	if not in_dialogue and not in_challenge:
		_update_idle_state(delta)

## 更新待机状态
func _update_idle_state(delta):
	state_timer += delta
	
	if state_timer >= state_duration:
		state_timer = 0.0
		_switch_idle_state()
	
	match current_idle_state:
		IdleState.IDLE:
			play_animation(idle_animation)
			_update_interaction_prompt_visibility()
		IdleState.MOVE:
			play_animation(move_animation)
			_update_interaction_prompt_visibility()
			# 以初始位置为中心正弦摆动巡逻
			var off = sin(state_timer * 0.5) * (patrol_width / 2)
			position.x = move_toward(position.x, initial_position.x + off, move_speed * delta)
		IdleState.GOFANATICAL:
			play_animation(go_fanatical_animation)
			# 狂热状态立即隐藏交互提示
			if interaction_prompt:
				interaction_prompt.visible = false

## 根据当前状态更新交互提示可见性
func _update_interaction_prompt_visibility():
	if not player_in_range:
		if interaction_prompt:
			interaction_prompt.visible = false
		return
	
	# 检查玩家是否在冲刺
	var player = _get_player()
	if player and player.current_state == player.PlayerState.DASH:
		if interaction_prompt:
			interaction_prompt.visible = false
		return
	
	# 非狂热状态且可以交互时才显示
	if current_idle_state != IdleState.GOFANATICAL:
		if !interact_once or (interact_once and !has_interacted):
			if interaction_prompt:
				interaction_prompt.visible = true
		else:
			if interaction_prompt:
				interaction_prompt.visible = false
	else:
		if interaction_prompt:
			interaction_prompt.visible = false

## 切换待机状态
func _switch_idle_state():
	var states = [IdleState.IDLE, IdleState.MOVE, IdleState.GOFANATICAL]
	states.erase(current_idle_state)
	current_idle_state = states[randi() % states.size()]

## 尝试交互（覆盖 BaseNPC 的方法）
func try_interact():
	if current_idle_state == IdleState.GOFANATICAL:
		return
	
	# 使用 challenge_controller 检查
	if challenge_controller and challenge_controller.current_state == ChallengeController.State.ACTIVE:
		return
	
	# 调用 BaseNPC 的 try_interact
	super.try_interact()

## 开始交互
func _start_interaction():
	var dialogue_system = get_node_or_null("/root/DialogueSystem")
	var in_dialogue = false
	if dialogue_system:
		in_dialogue = dialogue_system.is_dialogue_active
	
	if in_dialogue:
		return
	
	if not dialogue_resource:
		push_error("Maniac: 没有配置对话资源！请在检查器中指定")
		return
	
	if not balloon_scene:
		push_error("Maniac: balloon_scene 未配置！请在 Inspector 中拖拽 MyBalloon.tscn")
		return
	
	var balloon = balloon_scene.instantiate()
	get_tree().current_scene.add_child(balloon)
	
	# 传递 npc 引用，让对话文件可以调用 NPC 的方法
	var game_states = {
		"npc": self,
		"ManiacChallenge": challenge_controller,
		"Global": Global,
		"TaskManager": get_node_or_null("/root/TaskManager")
	}
	
	balloon.start(dialogue_resource, "start", [game_states])
	
	if animated_sprite and animated_sprite.sprite_frames:
		if animated_sprite.sprite_frames.has_animation(talk_animation):
			play_animation(talk_animation)

## 对话结束处理
func _on_dialogue_ended():
	await get_tree().process_frame
	super._on_dialogue_ended()
	_play_default_idle()

func _play_default_idle():
	if animated_sprite and animated_sprite.sprite_frames:
		if animated_sprite.sprite_frames.has_animation(idle_animation):
			play_animation(idle_animation)

## 获取当前动画帧纹理
func get_current_frame_texture() -> Texture2D:
	if animated_sprite and animated_sprite.sprite_frames:
		var frame_count = animated_sprite.sprite_frames.get_frame_count(animated_sprite.animation)
		if frame_count > 0 and animated_sprite.frame < frame_count:
			return animated_sprite.sprite_frames.get_frame_texture(
				animated_sprite.animation, 
				animated_sprite.frame
			)
	return null

## 清理残影资源（当 NPC 被销毁时调用）
func cleanup_afterimages():
	if afterimage_trail:
		# 移除 AfterimageTrail 组件
		afterimage_trail.queue_free()
		afterimage_trail = null

## 启动挑战（由对话文件调用）
func launch_challenge():
	_start_challenge_stage(0)

func launch_stage2_challenge():
	_start_challenge_stage(1)

func launch_stage3_challenge():
	_start_challenge_stage(2)

func launch_stage4_challenge():
	_start_challenge_stage(3)

## 启动第五阶段挑战（索引 4）
func launch_stage5_challenge():
	_start_challenge_stage(4)

## 启动第六阶段挑战（索引 5）
func launch_stage6_challenge():
	_start_challenge_stage(5)

## 统一启动入口
func _start_challenge_stage(stage_index: int) -> void:
	if challenge_controller_path == NodePath() or challenge_controller_path.is_empty():
		push_error("Maniac: 未设置 challenge_controller_path")
		return
	var ctrl = get_node_or_null(challenge_controller_path) as ChallengeController
	if ctrl == null:
		push_error("Maniac: 找不到 ChallengeController")
		return
	challenge_controller = ctrl
	current_challenge_stage = stage_index + 1
	
	# 断开旧信号连接（避免重复）
	if challenge_controller.challenge_completed.is_connected(_on_challenge_completed):
		challenge_controller.challenge_completed.disconnect(_on_challenge_completed)
	if challenge_controller.challenge_failed.is_connected(_on_challenge_failed):
		challenge_controller.challenge_failed.disconnect(_on_challenge_failed)
	challenge_controller.challenge_completed.connect(_on_challenge_completed)
	challenge_controller.challenge_failed.connect(_on_challenge_failed)
	
	challenge_controller.start_challenge(stage_index)

## 挑战完成回调
func _on_challenge_completed():
	print("[Maniac] 挑战完成, stage=", current_challenge_stage)
	var s = current_challenge_stage
	if s == 1:
		Global.maniac_challenge_completed = true
		# 走统一解锁入口：会广播 EventBus 信号（成就 ACH1 由它触发）并写入存档，
		# 已解锁时自身就是空操作。直接写 Global.unlocked_abilities 会绕过这些。
		Global.unlock_ability("double_jump")
	elif s == 2:
		Global.maniac_stage2_challenge_completed = true
	elif s == 3:
		Global.maniac_stage3_challenge_completed = true
	elif s == 4:
		Global.maniac_stage4_challenge_completed = true
	elif s == 5:
		Global.maniac_stage5_challenge_completed = true
	elif s == 6:
		Global.maniac_stage6_challenge_completed = true
	if Global.current_save_slot >= 0:
		SaveManager.save_game(Global.current_save_slot, Global.get_save_data())

## 挑战失败回调
func _on_challenge_failed():
	print("[Maniac] 挑战失败, stage=", current_challenge_stage)
	var s = current_challenge_stage
	if s == 1:
		Global.maniac_last_challenge_failed = true
	elif s == 2:
		Global.maniac_stage2_last_challenge_failed = true
	elif s == 3:
		Global.maniac_stage3_last_challenge_failed = true
	elif s == 4:
		Global.maniac_stage4_last_challenge_failed = true
	elif s == 5:
		Global.maniac_stage5_last_challenge_failed = true
	elif s == 6:
		Global.maniac_stage6_last_challenge_failed = true
	
func _play_impressed_animation():
	if animated_sprite and animated_sprite.sprite_frames:
		if animated_sprite.sprite_frames.has_animation(impressed_animation):
			play_animation(impressed_animation)
