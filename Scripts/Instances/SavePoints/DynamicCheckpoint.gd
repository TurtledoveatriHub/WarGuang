# DynamicCheckpoint.gd
extends Area2D
## 检查点唯一 ID（字符串，房间内唯一即可）
@export var checkpoint_id: String = ""  
## 所属房间 ID（必须填写）
@export var belongs_to_room: String = ""  

func _ready():
	if checkpoint_id == "":
		print("错误：检查点必须设置 checkpoint_id")
	
	if belongs_to_room == "":
		# 尝试自动获取所属房间
		determine_belongs_to_room()
		if belongs_to_room == "":
			print("严重错误：检查点", checkpoint_id, "无法确定所属房间，请手动设置 belongs_to_room")
	
	connect("body_entered", _on_body_entered)
	
	# 注册到 DynamicCheckpointManager
	DynamicCheckpointManager.register_checkpoint(checkpoint_id, global_position, belongs_to_room)
	
## 确定检查点所属房间
func determine_belongs_to_room():
	if belongs_to_room != "":
		return  # 已经设置了
	
	# 向上查找房间节点
	var parent = get_parent()
	var depth = 0
	while parent and depth < 10:  # 防止无限循环
		if parent.has_method("get_room_data"):
			var room_data = parent.get_room_data()
			belongs_to_room = room_data["id"]
			print("自动确定检查点", checkpoint_id, "所属房间:", belongs_to_room)
			return
		parent = parent.get_parent()
		depth += 1
	print("警告：无法自动确定检查点", checkpoint_id, "的所属房间")

func _on_body_entered(body):
	if body.is_in_group("player"):
		var current_room = RoomManager.current_room
		if belongs_to_room != "" and belongs_to_room != current_room:
			print("[DC] 忽略: 不属于当前房间")
			return
		DynamicCheckpointManager.set_current_checkpoint(checkpoint_id, current_room)
