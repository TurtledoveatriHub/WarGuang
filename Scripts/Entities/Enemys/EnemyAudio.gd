# Scripts/Entities/Enemys/EnemyAudio.gd
## 敌怪通用音效子节点 —— 挂到敌怪根节点下（可挂可不挂）。
## 挂上并拖入素材 = 有音效；不挂 = 完全无音效（互不影响）。
## 它订阅的是敌怪脚本发出的事件信号与 EnemyBase 的受伤/死亡信号：
##   - spotted(发现玩家)         → discover_sfx
##   - attack_started(准备攻击)  → attack_sfx
##   - EnemyBase.damage_taken    → hurt_sfx
##   - EnemyBase.enemy_died      → die_sfx
## 所有音频经 AudioManager 的 SFX 池播放；素材字段留空即可安全跳过。
extends Node
class_name EnemyAudio

## ── 音效素材（在 Inspector 拖入；留空则对应事件不出声）──
@export_category("音效素材")
## 发现玩家
@export var discover_sfx: AudioStream
## 准备攻击
@export var attack_sfx: AudioStream
## 受伤
@export var hurt_sfx: AudioStream
## 死亡
@export var die_sfx: AudioStream

var _enemy: Node = null
var _base: Node = null


func _ready() -> void:
	_enemy = get_parent()
	if _enemy == null:
		set_process(false)
		return
	# 敌怪脚本事件（父节点信号）
	if _enemy.has_signal("spotted"):
		_enemy.spotted.connect(_on_spotted)
	if _enemy.has_signal("attack_started"):
		_enemy.attack_started.connect(_on_attack_started)
	# EnemyBase 受伤/死亡（敌怪根节点的子节点 EnemyBase）
	_base = _enemy.get_node_or_null("EnemyBase")
	if _base:
		if _base.has_signal("damage_taken"):
			_base.damage_taken.connect(_on_hurt)
		if _base.has_signal("enemy_died"):
			_base.enemy_died.connect(_on_die)


func _on_spotted() -> void:
	_play(discover_sfx)


func _on_attack_started() -> void:
	_play(attack_sfx)


func _on_hurt(_damage: int, _current_health: int) -> void:
	_play(hurt_sfx)


func _on_die() -> void:
	_play(die_sfx)


## 播放一段音效（经 AudioManager 的 SFX 池；用 /root 路径查找，不强依赖编译期 autoload）
func _play(stream: AudioStream) -> void:
	if stream == null:
		return
	var am: Node = get_node_or_null("/root/AudioManager")
	if am and am.has_method("play_stream_sfx"):
		am.play_stream_sfx(stream)
