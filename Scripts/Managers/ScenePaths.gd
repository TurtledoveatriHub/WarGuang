# Scripts/Resources/ScenePaths.gd
extends Node
## 全局场景路径管理器
## 集中管理所有场景和资源路径
## 避免硬编码路径分散在各处

# ============================================
# UI 场景路径常量
# ============================================
const UI_TITLE = "res://Scenes/UI/Scenes/TitleScene.tscn"
const UI_SAVE_SELECT = "res://Scenes/UI/Scenes/SaveSelectScene.tscn"
const UI_SETTINGS = "res://Scenes/UI/Scenes/SettingsScene.tscn"
const UI_GAME_SETTING = "res://Scenes/UI/Scenes/GameSettingScene.tscn"
const UI_DELETE_CONFIRM = "res://Scenes/UI/Scenes/DeleteConfirmDialog.tscn"
const UI_CHALLENGE_COUNTER = "res://Scenes/UI/ChallengeCounter.tscn"
const UI_MY_BALLOON = "res://Scenes/UI/MyBalloon.tscn"
const UI_DARK_OVERLAY = "res://Scenes/Managers/DarkOverlay.tscn"

# ============================================
# 玩家相关场景
# ============================================
const PLAYER_UI_DIR = "res://Scenes/Player/PlayerUI"
const PLAYER_HEALTH_UNIT = PLAYER_UI_DIR + "/HealthUnit.tscn"
const PLAYER_UI = PLAYER_UI_DIR + "/PlayerUI.tscn"
const PLAYER_AFTERIMAGE = "res://Scenes/Instances/ObjectPools/Afterimage.tscn"

# ============================================
# NPC 场景
# ============================================
const NPC_MANIAC = "res://Scenes/NPCs/ManiacNPC.tscn"
const NPC_MERCHANT = "res://Scenes/NPCs/MerchantNPC.tscn"
const NPC_MASTER = "res://Scenes/NPCs/MasterNPC.tscn"

# ============================================
# 游戏主场景
# ============================================
const GAME_MAIN = "res://Scenes/GameScenes/MainGameScene.tscn"

# ============================================
# 快捷加载方法（可选，但更方便）
# ============================================
static func load_title() -> PackedScene:
	return load(UI_TITLE)

static func load_save_select() -> PackedScene:
	return load(UI_SAVE_SELECT)

static func load_settings() -> PackedScene:
	return load(UI_SETTINGS)

static func load_game_setting() -> PackedScene:
	return load(UI_GAME_SETTING)

static func load_delete_confirm() -> PackedScene:
	return load(UI_DELETE_CONFIRM)

static func load_challenge_counter() -> PackedScene:
	return load(UI_CHALLENGE_COUNTER)

static func load_my_balloon() -> PackedScene:
	return load(UI_MY_BALLOON)

static func load_dark_overlay() -> PackedScene:
	return load(UI_DARK_OVERLAY)

static func load_health_unit() -> PackedScene:
	return load(PLAYER_HEALTH_UNIT)

static func load_player_ui() -> PackedScene:
	return load(PLAYER_UI)

static func load_afterimage() -> PackedScene:
	return load(PLAYER_AFTERIMAGE)

static func load_maniac() -> PackedScene:
	return load(NPC_MANIAC)

static func load_merchant() -> PackedScene:
	return load(NPC_MERCHANT)

static func load_master() -> PackedScene:
	return load(NPC_MASTER)

static func load_main_game() -> PackedScene:
	return load(GAME_MAIN)

# ============================================
# 房间场景路径（按需加载用）
# ============================================
const ROOMS_DIR = "res://Scenes/GameScenes/Rooms/"
const ROOM_PATHS = {
	"Room1": ROOMS_DIR + "Room1.tscn",
	"Room2": ROOMS_DIR + "Room2.tscn",
	"Room3": ROOMS_DIR + "Room3.tscn",
	"Room4": ROOMS_DIR + "Room4.tscn",
	"Room5": ROOMS_DIR + "Room5.tscn",
	"Room6": ROOMS_DIR + "Room6.tscn",
	"RoomDream10": ROOMS_DIR + "RoomDream10.tscn",
	"Room39": ROOMS_DIR + "Room39.tscn",
	"Room61": ROOMS_DIR + "Room61.tscn",
	"Room62": ROOMS_DIR + "Room62.tscn",
	"Room63": ROOMS_DIR + "Room63.tscn",
	"Room64": ROOMS_DIR + "Room64.tscn",
	"Room65": ROOMS_DIR + "Room65.tscn",
	"Room66": ROOMS_DIR + "Room66.tscn",
	"Room67": ROOMS_DIR + "Room67.tscn",
	"Room68": ROOMS_DIR + "Room68.tscn",
	"Room69": ROOMS_DIR + "Room69.tscn",
	"SnowMountain1": ROOMS_DIR + "SnowMountain/SnowMountain1.tscn",
	"SnowMountain2": ROOMS_DIR + "SnowMountain/SnowMountain2.tscn",
	"SnowMountain3": ROOMS_DIR + "SnowMountain/SnowMountain3.tscn",
	"SnowMountain4": ROOMS_DIR + "SnowMountain/SnowMountain4.tscn",
	"SnowMountain5": ROOMS_DIR + "SnowMountain/SnowMountain5.tscn",
	"SnowMountain6": ROOMS_DIR + "SnowMountain/SnowMountain6.tscn",
	
}

## 获取房间场景文件路径
static func get_room_path(room_id: String) -> String:
	if ROOM_PATHS.has(room_id):
		return ROOM_PATHS[room_id]
	push_error("ScenePaths: 未知的房间ID: ", room_id)
	return ""
