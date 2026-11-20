# Scripts/Managers/ScenePaths.gd
extends Node
## 全局场景 / 脚本路径管理器（Autoload 名字：ScenePaths）
##
## ★ 项目约定：**所有场景与脚本的 res:// 路径都只写在这里**，其它脚本一律通过
##   `ScenePaths.XXX` 取值，不要再散落字面量。
##   以后挪文件夹 / 改文件名，只需要改这一个文件，不用全项目搜索替换。
##
## ★ 两条「看起来像例外」的情况其实都不需要硬编码：
##   1. `extends "res://xxx.gd"` —— 语法上必须字面量，但本项目被继承的脚本都带 class_name，
##      直接 `extends 类名` 即可（EnvironmentZoneBase / MechanismObject / NeutralBug / UIButtonFx ...）。
##   2. `preload("res://xxx")` —— 只能吃常量表达式，所以场景统一走
##      `load(ScenePaths.XXX)` 或下面现成的 `load_xxx()`。
##      ResourceLoader 自带缓存，重复 load 同一个路径不会重复读盘。
##
## ★ 本文件没有 @tool，但 RoomScanner 这类编辑器工具会直接 load 本脚本、读常量表，
##   所以 ROOM_PATHS 必须保持「纯 const 字典」的写法（不能改成运行时拼装）。

# ============================================
# 目录常量（分级目录只在这里拼一次）
# ============================================
## 场景根目录
const SCENES_DIR = "res://Scenes"
## UI 场景根目录
const UI_DIR = SCENES_DIR + "/UI"
## 游戏内 HUD / 浮层：MapUI / TeleportPanel / ChallengeCounter / MyBalloon / RaceHUD
const UI_GAME_DIR = UI_DIR + "/GameUI"
## 独立整页界面：标题 / 存读档 / 设置 / 成就 / 更新说明 / 开场动画
const UI_SCENES_DIR = UI_DIR + "/ScenesUI"

## UI 脚本根目录
const UI_SCRIPT_DIR = "res://Scripts/UI"
## 游戏内 HUD 脚本
const UI_GAME_SCRIPT_DIR = UI_SCRIPT_DIR + "/GameUI"
## 独立界面脚本
const UI_SCENES_SCRIPT_DIR = UI_SCRIPT_DIR + "/ScenesUI"
## UI 动效脚本（按钮动效 / 动效总线）
const UI_FX_SCRIPT_DIR = UI_SCRIPT_DIR + "/UIFx"


# ============================================
# UI 覆盖层规范脚本（黑幕 alpha / 世界亮度 / 过渡时长）
# 注意：该脚本自带 class_name OverlaySpec，直接引用类名即可，不需要路径
# ============================================
const SCRIPT_OVERLAY_SPEC = UI_SCENES_SCRIPT_DIR + "/DarkOverlay.gd"

# ============================================
# UI 场景路径常量
# ============================================
## 标题界面
const UI_TITLE = UI_SCENES_DIR + "/TitleScene.tscn"
## 存档选择界面
const UI_SAVE_SELECT = UI_SCENES_DIR + "/SaveSelectScene.tscn"
## 设置界面（独立整页）
const UI_SETTINGS = UI_SCENES_DIR + "/SettingsScene.tscn"
## 游戏内设置面板（覆盖层）
const UI_GAME_SETTING = UI_SCENES_DIR + "/GameSettingScene.tscn"
## 删除存档确认对话框
const UI_DELETE_CONFIRM = UI_SCENES_DIR + "/DeleteConfirmDialog.tscn"
## 关于作者
const UI_ABOUT_AUTHOR = UI_SCENES_DIR + "/AboutAuthor.tscn"
## 成就界面
const UI_ACHIEVEMENT = UI_SCENES_DIR + "/AchievementScene.tscn"
## 成就条目（成就界面内部实例化）
const UI_ACHIEVEMENT_ROW = UI_SCENES_DIR + "/AchievementRow.tscn"
## 更新说明
const UI_UPDATE_NOTES = UI_SCENES_DIR + "/UpdateNotes.tscn"
## 开场动画（同时是 Autoload BootCutscene 的场景）
const UI_BOOT_CUTSCENE = UI_SCENES_DIR + "/BootCutscene.tscn"

## 挑战计数 HUD
const UI_CHALLENGE_COUNTER = UI_GAME_DIR + "/ChallengeCounter.tscn"
## NPC 对话气泡
const UI_MY_BALLOON = UI_GAME_DIR + "/MyBalloon.tscn"
## 地图界面
const UI_MAP = UI_GAME_DIR + "/MapUI.tscn"
## 传送面板
const UI_TELEPORT_PANEL = UI_GAME_DIR + "/TeleportPanel.tscn"
## 竞速 HUD
const UI_RACE_HUD = UI_GAME_DIR + "/RaceHUD.tscn"

## 全屏黑幕 / 遮罩（Autoload DarkOverlay 的场景，挂在 Managers 下而不是 UI 下）
const UI_DARK_OVERLAY = SCENES_DIR + "/Managers/DarkOverlay.tscn"

# ============================================
# 玩家相关场景
# ============================================
const PLAYER_UI_DIR = SCENES_DIR + "/Player/PlayerUI"
const PLAYER_HEALTH_UNIT = PLAYER_UI_DIR + "/HealthUnit.tscn"
const PLAYER_UI = PLAYER_UI_DIR + "/PlayerUI.tscn"
const PLAYER_AFTERIMAGE = SCENES_DIR + "/Instances/ObjectPools/Afterimage.tscn"

# ============================================
# NPC 场景
# ============================================
const NPC_DIR = SCENES_DIR + "/Entities/NPCs"
const NPC_MANIAC = NPC_DIR + "/Maniac.tscn"
const NPC_MERCHANT = NPC_DIR + "/Salesclerk.tscn"
const NPC_MASTER = NPC_DIR + "/Master.tscn"

# ============================================
# 游戏主场景
# ============================================
const GAME_MAIN = SCENES_DIR + "/GameScenes/MainGameScene.tscn"

# ============================================
# 快捷加载方法（场景统一走这里，避免 preload 字面量）
# ★ 这些写成普通方法（不是 static）：本文件是 Autoload，调用方一律
#   `ScenePaths.load_xxx()`，与项目里其它单例（AudioManager / FadeManager）用法一致。
# ============================================
func load_title() -> PackedScene:
	return load(UI_TITLE) as PackedScene

func load_save_select() -> PackedScene:
	return load(UI_SAVE_SELECT) as PackedScene

func load_settings() -> PackedScene:
	return load(UI_SETTINGS) as PackedScene

func load_game_setting() -> PackedScene:
	return load(UI_GAME_SETTING) as PackedScene

func load_delete_confirm() -> PackedScene:
	return load(UI_DELETE_CONFIRM) as PackedScene

func load_achievement() -> PackedScene:
	return load(UI_ACHIEVEMENT) as PackedScene

func load_update_notes() -> PackedScene:
	return load(UI_UPDATE_NOTES) as PackedScene

func load_boot_cutscene() -> PackedScene:
	return load(UI_BOOT_CUTSCENE) as PackedScene

func load_challenge_counter() -> PackedScene:
	return load(UI_CHALLENGE_COUNTER) as PackedScene

func load_my_balloon() -> PackedScene:
	return load(UI_MY_BALLOON) as PackedScene

func load_map_ui() -> PackedScene:
	return load(UI_MAP) as PackedScene

func load_teleport_panel() -> PackedScene:
	return load(UI_TELEPORT_PANEL) as PackedScene

func load_race_hud() -> PackedScene:
	return load(UI_RACE_HUD) as PackedScene

func load_dark_overlay() -> PackedScene:
	return load(UI_DARK_OVERLAY) as PackedScene

func load_health_unit() -> PackedScene:
	return load(PLAYER_HEALTH_UNIT) as PackedScene

func load_player_ui() -> PackedScene:
	return load(PLAYER_UI) as PackedScene

func load_afterimage() -> PackedScene:
	return load(PLAYER_AFTERIMAGE) as PackedScene

func load_maniac() -> PackedScene:
	return load(NPC_MANIAC) as PackedScene

func load_merchant() -> PackedScene:
	return load(NPC_MERCHANT) as PackedScene

func load_master() -> PackedScene:
	return load(NPC_MASTER) as PackedScene

func load_main_game() -> PackedScene:
	return load(GAME_MAIN) as PackedScene

# ============================================
# 房间场景路径（按需加载用）
# ============================================
const ROOMS_DIR = SCENES_DIR + "/GameScenes/Rooms/"
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
func get_room_path(room_id: String) -> String:
	if ROOM_PATHS.has(room_id):
		return ROOM_PATHS[room_id]
	push_error("ScenePaths: 未知的房间ID: ", room_id)
	return ""
