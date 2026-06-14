## 已移动到 res://Scripts/GameScenes/MapData.gd
extends Resource

## 单个房间的地图数据资源文件。
##
## 每创建一个新房间，都应在 Assets/Maps/ 下创建一个对应的 .tres 文件。
## MapManager 按需加载这些资源，避免将所有房间的数据硬编码在代码中。
##
## 使用方式：
##   1. 创建 .tres 文件：
##      var data = MapData.new()
##      data.room_id = "Room1"
##      data.map_position = Vector2(100, 200)
##      ResourceSaver.save(data, "res://Assets/Maps/Room1_mapdata.tres")
##
##   2. 在 MapManager 中加载：
##      var data = load("res://Assets/Maps/Room1_mapdata.tres") as MapData

## 对应的房间 ID（必须与 Room.gd 中的 room_id 一致）
@export var room_id: String = ""

## 该房间在地图上的中心坐标（像素）
@export var map_position: Vector2 = Vector2.ZERO

## 该房间在地图上占的矩形尺寸（用于概览模式的色块）
@export var map_size: Vector2 = Vector2(200, 150)

## 概览模式（0.5x 缩放）的房间块纹理
@export var block_texture: Texture2D = null

## 具体模式（1.0x 缩放）的房间结构纹理
@export var detail_texture: Texture2D = null

## 房间名称（在地图上显示的标签）
@export var room_display_name: String = ""

## 相邻房间 ID 列表（用于绘制连接线）
@export var adjacent_rooms: Array[String] = []

## 该房间内的传送阵 ID 列表
@export var teleport_ids: Array[String] = []
