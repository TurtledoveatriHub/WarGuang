# Scripts/Managers/ScenePaths.gd
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
const NPC_MANIAC = "res://Scenes/Entities/NPCs/Maniac.tscn"
const NPC_MERCHANT = "res://Scenes/Entities/NPCs/Salesclerk.tscn"
const NPC_MASTER = "res://Scenes/Entities/NPCs/Master.tscn"

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
	"GrassLand1": ROOMS_DIR + "GrassLand/GrassLand1.tscn",
	"GrassLand2": ROOMS_DIR + "GrassLand/GrassLand2.tscn",
	"GrassLand3": ROOMS_DIR + "GrassLand/GrassLand3.tscn",
	"GrassLand4": ROOMS_DIR + "GrassLand/GrassLand4.tscn",
	"GrassLand5": ROOMS_DIR + "GrassLand/GrassLand5.tscn",
	"GrassLand6": ROOMS_DIR + "GrassLand/GrassLand6.tscn",
	"GrassLand7": ROOMS_DIR + "GrassLand/GrassLand7.tscn",
	"GrassLand8": ROOMS_DIR + "GrassLand/GrassLand8.tscn",
	"GrassLand9": ROOMS_DIR + "GrassLand/GrassLand9.tscn",
	"GrassLand10": ROOMS_DIR + "GrassLand/GrassLand10.tscn",
	"GrassLand11": ROOMS_DIR + "GrassLand/GrassLand11.tscn",
	"GrassLand12": ROOMS_DIR + "GrassLand/GrassLand12.tscn",
	"GrassLand13": ROOMS_DIR + "GrassLand/GrassLand13.tscn",
	"GrassLand14": ROOMS_DIR + "GrassLand/GrassLand14.tscn",
	"GrassLand15": ROOMS_DIR + "GrassLand/GrassLand15.tscn",
	"GrassLand16": ROOMS_DIR + "GrassLand/GrassLand16.tscn",
	"GrassLand17": ROOMS_DIR + "GrassLand/GrassLand17.tscn",
	"GrassLand18": ROOMS_DIR + "GrassLand/GrassLand18.tscn",
	
	"SnowMountain1": ROOMS_DIR + "SnowMountain/SnowMountain1.tscn",
	"SnowMountain2": ROOMS_DIR + "SnowMountain/SnowMountain2.tscn",
	"SnowMountain3": ROOMS_DIR + "SnowMountain/SnowMountain3.tscn",
	"SnowMountain4": ROOMS_DIR + "SnowMountain/SnowMountain4.tscn",
	"SnowMountain5": ROOMS_DIR + "SnowMountain/SnowMountain5.tscn",
	"SnowMountain6": ROOMS_DIR + "SnowMountain/SnowMountain6.tscn",
	"SnowMountain7": ROOMS_DIR + "SnowMountain/SnowMountain7.tscn",
	"SnowMountain8": ROOMS_DIR + "SnowMountain/SnowMountain8.tscn",
	"SnowMountain9": ROOMS_DIR + "SnowMountain/SnowMountain9.tscn",
	"SnowMountain10": ROOMS_DIR + "SnowMountain/SnowMountain10.tscn",
	"SnowMountain11": ROOMS_DIR + "SnowMountain/SnowMountain11.tscn",
	"SnowMountain12": ROOMS_DIR + "SnowMountain/SnowMountain12.tscn",
	"SnowMountain13": ROOMS_DIR + "SnowMountain/SnowMountain13.tscn",
	"SnowMountain14": ROOMS_DIR + "SnowMountain/SnowMountain14.tscn",
	"SnowMountain15": ROOMS_DIR + "SnowMountain/SnowMountain15.tscn",
	"SnowMountain16": ROOMS_DIR + "SnowMountain/SnowMountain16.tscn",
	"SnowMountain17": ROOMS_DIR + "SnowMountain/SnowMountain17.tscn",
	"SnowMountain18": ROOMS_DIR + "SnowMountain/SnowMountain18.tscn",
	"SnowMountain19": ROOMS_DIR + "SnowMountain/SnowMountain19.tscn",
	"SnowMountain20": ROOMS_DIR + "SnowMountain/SnowMountain20.tscn",
	"SnowMountain21": ROOMS_DIR + "SnowMountain/SnowMountain21.tscn",
	
	"Cave1": ROOMS_DIR + "Cave/Cave1.tscn",
	"Cave2": ROOMS_DIR + "Cave/Cave2.tscn",
	"Cave3": ROOMS_DIR + "Cave/Cave3.tscn",
	
	"WindValley1": ROOMS_DIR + "WindValley/WindValley1.tscn",
	"WindValley2": ROOMS_DIR + "WindValley/WindValley2.tscn",
	"WindValley3": ROOMS_DIR + "WindValley/WindValley3.tscn",
	"WindValley4": ROOMS_DIR + "WindValley/WindValley4.tscn",
	"WindValley5": ROOMS_DIR + "WindValley/WindValley5.tscn",
	"WindValley6": ROOMS_DIR + "WindValley/WindValley6.tscn",
	"WindValley7": ROOMS_DIR + "WindValley/WindValley7.tscn",
	"WindValley8": ROOMS_DIR + "WindValley/WindValley8.tscn",
	"WindValley9": ROOMS_DIR + "WindValley/WindValley9.tscn",
	"WindValley10": ROOMS_DIR + "WindValley/WindValley10.tscn",
	"WindValley11": ROOMS_DIR + "WindValley/WindValley11.tscn",
	"WindValley12": ROOMS_DIR + "WindValley/WindValley12.tscn",
	"WindValley13": ROOMS_DIR + "WindValley/WindValley13.tscn",
	
	"Town1": ROOMS_DIR + "Town/Town1.tscn",
	"Town2": ROOMS_DIR + "Town/Town2.tscn",
	"Town3": ROOMS_DIR + "Town/Town3.tscn",
	"Town4": ROOMS_DIR + "Town/Town4.tscn",
	"Town5": ROOMS_DIR + "Town/Town5.tscn",
	"Town6": ROOMS_DIR + "Town/Town6.tscn",
	"Town7": ROOMS_DIR + "Town/Town7.tscn",
	
	"SuperMario2": ROOMS_DIR + "SuperMario/SuperMario2.tscn",
	
}

## 获取房间场景文件路径
static func get_room_path(room_id: String) -> String:
	if ROOM_PATHS.has(room_id):
		return ROOM_PATHS[room_id]
	push_error("ScenePaths: 未知的房间ID: ", room_id)
	return ""
