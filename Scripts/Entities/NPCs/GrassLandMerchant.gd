extends BaseNPC
class_name GrassLandMerchant
## 草原商铺店长：只做「卖东西」这一件事的简化商人（参照 Salesclerk，但**没有心情系统**）。
##
## 动画：只有三个
##   IDLE   默认待机
##   TALK   交互时切过去（对话结束回 IDLE）
##   HAPPY  买到一件商品后播一遍（播完回 IDLE）
##
## 音效：
##   * 交互音效沿用 BaseNPC.npc_interact_sounds（交互时随机播一个，由基类负责）
##   * 购买成功额外播 purchase_success_sfx，买不成/放弃播 no_purchase_sfx
##
## 购买流程建议全部走本脚本的 purchase()，对话文件里只需一行 `do npc.purchase("map")`；
## 这样扣钱、解锁、音效、动画都只有一处实现，不容易漏。

@export_category("动画")
## 待机动画名
@export var idle_animation: String = "IDLE"
## 交互时动画名
@export var talk_animation: String = "TALK"
## 买到东西后播一遍的动画名
@export var happy_animation: String = "HAPPY"

@export_category("音效")
## 购买成功音效（在 BaseNPC 的交互音效之外额外播一次）
@export var purchase_success_sfx: AudioStream
## 钱不够 / 放弃购买时播一次
@export var no_purchase_sfx: AudioStream

@export_category("商品")
## 商品表：[{ item_id, item_name, price }]。对话文件里用 npc.get_item_price(id) / npc.get_item_name(id) 取用。
## item_id = "map" 是特殊商品：买下后解锁地图能力（Global.unlock_ability("map")）。
@export var shop_items: Array[Dictionary] = [
	{"item_id": "potion_speed", "item_name": "加速药水", "price": 50},
	{"item_id": "potion_gravity", "item_name": "重力药水", "price": 150},
	{"item_id": "map", "item_name": "地图", "price": 200},
]

## 地图商品的价格（对话里也直接用 npc.map_price 读）
@export var map_price: int = 200

## 本次交互是否买过东西
var _purchased: bool = false

## HAPPY 动画是否正在播（播完要切回 IDLE）
var _happy_playing: bool = false


func _ready():
	npc_id = "GrassLandMerchant"
	super._ready()
	_play_default_idle()


## 覆盖基类：切 TALK 动画 + 随机交互音效 + 用带 state 的方式开对话
func _start_interaction():
	# ★ 标记「这次对话由本 NPC 发起」：DialogueSystem.dialogue_ended 是全局信号，必须靠它过滤
	owns_dialogue = true
	_purchased = false
	_play_random_interact_sound()
	_play_animation_or_idle(talk_animation)

	var task_manager: Node = get_node_or_null("/root/TaskManager")
	if task_manager:
		task_manager.record_npc_dialogue(npc_id)

	if dialogue_resource == null:
		push_error("GrassLandMerchant: dialogue_resource 未配置！")
		return
	if not balloon_scene:
		balloon_scene = load(ScenePaths.UI_MY_BALLOON)
	if not balloon_scene:
		push_error("GrassLandMerchant: balloon_scene 未配置！")
		return

	var balloon: Node = balloon_scene.instantiate()
	get_tree().current_scene.add_child(balloon)
	# 传给对话文件的 state：对话里用 npc / global / player / task_manager 这几个名字取用
	var game_states: Dictionary = {
		"npc": self,
		"player": get_tree().get_first_node_in_group("player"),
		"global": Global,
		"task_manager": task_manager,
	}
	if balloon.has_method("start"):
		balloon.start(dialogue_resource, "start", [game_states])


## 对话结束：回到待机（只有自己发起的那次对话才处理）
func _on_dialogue_ended():
	if not owns_dialogue:
		return
	await get_tree().process_frame
	super._on_dialogue_ended()
	_happy_playing = false
	_play_default_idle()


## 取商品价格；找不到返回 0
func get_item_price(item_id: String) -> int:
	for item: Dictionary in shop_items:
		if str(item.get("item_id", "")) == item_id:
			return int(item.get("price", 0))
	if item_id == "map":
		return map_price
	return 0


## 取商品名；找不到返回 item_id 本身
func get_item_name(item_id: String) -> String:
	for item: Dictionary in shop_items:
		if str(item.get("item_id", "")) == item_id:
			return str(item.get("item_name", item_id))
	if item_id == "map":
		return "地图"
	return item_id


## 玩家的钱够不够买这件商品
func can_afford(item_id: String) -> bool:
	if Global == null:
		return false
	return Global.player_coins >= get_item_price(item_id)


## 地图是否还没买过（买了就不再卖）
func map_available() -> bool:
	if Global == null:
		return false
	if Global.has_method("is_ability_unlocked"):
		return not bool(Global.call("is_ability_unlocked", "map"))
	return not bool(Global.unlocked_abilities.get("map", false))


## 买一件商品：扣钱 → 生效 → 播购买音效 → 播一遍 HAPPY。
## 返回 true 表示成交。对话文件里只需要 `do npc.purchase("map")`（或 `if npc.purchase(...)`）。
func purchase(item_id: String) -> bool:
	if not can_afford(item_id):
		AudioManager.play_stream_sfx(no_purchase_sfx)
		return false
	var price: int = get_item_price(item_id)
	if Global.has_method("spend_coins"):
		Global.call("spend_coins", price)
	else:
		Global.player_coins -= price
	# 「地图」是能力商品，其它商品暂时只记一笔（后续要做实际效果就加在这里）
	if item_id == "map":
		if Global.has_method("unlock_ability"):
			Global.call("unlock_ability", "map")
		else:
			Global.unlocked_abilities["map"] = true
	_purchased = true
	AudioManager.play_stream_sfx(purchase_success_sfx)
	play_happy_once()
	return true


## 放弃购买 / 钱不够（对话里选「离开」时调用）
func on_leave_without_purchase() -> void:
	if _purchased:
		return
	AudioManager.play_stream_sfx(no_purchase_sfx)


## 播一遍 HAPPY 动画，播完自动回 IDLE
func play_happy_once() -> void:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	if not animated_sprite.sprite_frames.has_animation(happy_animation):
		# 动画还没做：不报错，直接保持待机（SpriteFrames 里补上 HAPPY 即可生效）
		print("提示：GrassLandMerchant 的 SpriteFrames 里还没有 ", happy_animation, " 动画")
		_play_default_idle()
		return
	_happy_playing = true
	animated_sprite.play(happy_animation)
	if not animated_sprite.animation_finished.is_connected(_on_happy_animation_finished):
		animated_sprite.animation_finished.connect(_on_happy_animation_finished, CONNECT_ONE_SHOT)


## HAPPY 播完 → 回 IDLE
func _on_happy_animation_finished() -> void:
	if not _happy_playing:
		return
	_happy_playing = false
	_play_default_idle()


## 播指定动画；不存在就退回待机（不报错）
func _play_animation_or_idle(animation_name: String) -> void:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	if animated_sprite.sprite_frames.has_animation(animation_name):
		animated_sprite.play(animation_name)
	else:
		_play_default_idle()
