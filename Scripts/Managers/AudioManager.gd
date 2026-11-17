# AudioManager.gd
## 音频管理单例 — 纯基础设施层。
## 不包含字符串查找路径，所有音频资源由各场景通过 @export 拖拽传入。
extends Node

## 音频总线名称
const MASTER_BUS = "Master"
const BGM_BUS = "BGM" 
const SFX_BUS = "SFX"
const VOICE_BUS = "Voice"

## 音频配置
const BGM_FADE_IN_DURATION: float = 1.0  ## BGM淡入持续时间（秒）
const BGM_FADE_OUT_DURATION: float = 1.0  ## BGM淡出持续时间（秒）
const BGM_DUCK_DURATION: float = 1.0  ## 音频闪避持续时间（秒）
const BGM_DUCK_VOLUME: float = 0.5  ## 音频闪避时的音量（0-1）

## SFX 优先级常量
const SFX_PRIORITY_LOW: int = 1
const SFX_PRIORITY_NORMAL: int = 5
const SFX_PRIORITY_HIGH: int = 8
const SFX_PRIORITY_CRITICAL: int = 10

## 最大并发 SFX 实例数
const MAX_SFX_INSTANCES: int = 16
const MAX_SFX_PER_PRIORITY: Dictionary = {1: 3, 5: 5, 8: 8, 10: 16}

## 旧版兼容：BGM 名称 → 文件路径映射
## 仅保留用于 SceneManager.return_to_title 等少数场景中临时获取 BGM 流。
var bgm_paths = {
	"BGM0": "res://Assets/Audios/BGM/探险.ogg",
}

# ----- BGM 系统（新版流式） -----

## 场景切换淡入淡出时长分组
## UI→游戏（存档进游戏、返回标题等）
const UI_TO_GAME_FADE_DURATION: float = 1.5
## 房间之间切换
const ROOM_FADE_DURATION: float = 1.0
## 默认淡入淡出
const DEFAULT_FADE_DURATION: float = 1.0

## 事件播放期间是否抑制 BGM
var _event_bgm_suppress: bool = false
## 事件期间缓存的待播 BGM 流
var _pending_event_bgm: AudioStream = null

## 单 BGM 播放器
var _bgm_player: AudioStreamPlayer = null
## 退出清理是否已执行（quit_game 与 _notification 都会触发，避免重复清理）
var _exit_cleanup_done: bool = false
## 当前正在播放的 BGM 流（用于同流跳过检测）
var _current_bgm_stream: AudioStream = null
## BGM 淡入淡出 Tween
var _bgm_fade_tween: Tween = null
## 事件 BGM 播放标记（Boss 战等）
var is_event_bgm_playing: bool = false
## 事件 BGM 前保存的 BGM 流（用于条件恢复）
var _saved_bgm_stream: AudioStream = null
## BGM 流缓存（按名称索引，兼容旧接口）
var _bgm_stream_cache: Dictionary = {}

# ----- SFX 系统 -----

## 循环音效播放器映射（key → AudioStreamPlayer）
var _looped_players: Dictionary = {}
## 活跃的一次性 SFX 实例列表（含优先级排队+对象池）
var _sfx_instances: Array = []
## SFX 对象池
var _sfx_pool: Array[AudioStreamPlayer] = []
const _SFX_POOL_SIZE: int = 12

## 全局统一点击音效（所有 UI 场景共用）。默认直接指向资源；要换改这里的 preload 路径即可。
## （本脚本是 autoload 脚本而非场景，因此 @export 在这里无法在 Inspector 编辑。）
var button_click_sfx: AudioStream
## 全局统一悬停音效（所有 UI 场景共用）。
var button_hover_sfx: AudioStream
## 悬停音效最小触发间隔（秒）：鼠标快速扫过一排按钮时不至于叠成一团噪音
const HOVER_SFX_MIN_INTERVAL: float = 0.035
## 上一次悬停音效的时间戳（毫秒）
var _last_hover_sfx_ms: int = -100000
## 音频闪避 Tween
var audio_duck_tween: Tween

# ============================================================
# 🎚 音效增益表（方案 A）
# ============================================================
## 资源路径 → 增益（dB）。想单独调某个音效的音量，在这里加一行即可：
##   sfx_gain_db["res://Assets/Audios/SFX/UI/鼠标点击.wav"] = -6.0   # 太响 → 衰减 6dB
##   sfx_gain_db["res://Assets/Audios/SFX/Player/landing.wav"] = 4.0  # 太轻 → 提升 4dB
## 播放时自动套用（只改播放音量，不动素材文件、不用重新导入）；表里没写的按 0dB 处理。
var sfx_gain_db: Dictionary = {}

## 音频设置存档路径（音量是全局设置，不属于某个存档）
const AUDIO_SETTINGS_PATH: String = "user://audio_settings.cfg"
## 需要持久化的总线（改动后写盘、启动时读回）
const PERSISTED_BUSES: Array[String] = [MASTER_BUS, BGM_BUS, SFX_BUS, VOICE_BUS]
## 已有待写的设置存档，避免拖动滑条时每帧都写文件
var _settings_save_pending: bool = false

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 预创建 SFX 对象池
	for i in range(_SFX_POOL_SIZE):
		var p = AudioStreamPlayer.new()
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		p.name = &"SFXPool_%d" % i
		add_child(p)
		_sfx_pool.append(p)
	# 音效资源已在变量声明处用 preload 指向默认值（不在函数里写硬编码加载）
	# ★ 读回上次保存的音量设置：以前只改 AudioServer 而不落盘，重启就全部回到项目默认值
	_load_audio_settings()


## 读回音频设置（没有存档文件时保持项目默认的 bus layout 不变）
func _load_audio_settings() -> void:
	var config := ConfigFile.new()
	if config.load(AUDIO_SETTINGS_PATH) != OK:
		return
	for bus_name: String in PERSISTED_BUSES:
		if not config.has_section_key("volume", bus_name):
			continue
		var bus_index: int = AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			continue
		var percent: float = clampf(float(config.get_value("volume", bus_name)), 0.0, 100.0)
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(percent / 100.0))


## 音量改动后延迟一帧写盘（拖动滑条会连续触发，合并成一次）
func _schedule_audio_settings_save() -> void:
	if _settings_save_pending:
		return
	_settings_save_pending = true
	call_deferred("_save_audio_settings")


## 把四条总线的当前音量写进 user://audio_settings.cfg
func _save_audio_settings() -> void:
	_settings_save_pending = false
	var config := ConfigFile.new()
	config.load(AUDIO_SETTINGS_PATH)
	for bus_name: String in PERSISTED_BUSES:
		config.set_value("volume", bus_name, get_bus_volume_percent(bus_name))
	config.save(AUDIO_SETTINGS_PATH)

# ============================================================
# 🎵 BGM 流式接口（场景通过拖拽传入 AudioStream）
# ============================================================

## 获取或创建单 BGM 播放器
func _get_bgm_player() -> AudioStreamPlayer:
	if not _bgm_player or not is_instance_valid(_bgm_player):
		_bgm_player = AudioStreamPlayer.new()
		_bgm_player.bus = BGM_BUS
		_bgm_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_bgm_player)
	# 每次调用时显式刷新总线，确保没有被静音
	_bgm_player.bus = BGM_BUS
	return _bgm_player

## 通过 AudioStream 播放 BGM（新版主要接口）
## 同一流正在播放时自动跳过，不同流时淡出旧→淡入新
func play_bgm_stream(stream: AudioStream, fade_duration: float = BGM_FADE_IN_DURATION) -> void:
	if not stream:
		return
	# 事件播放期间抑制 BGM
	if _event_bgm_suppress:
		_pending_event_bgm = stream
		return
	var player = _get_bgm_player()
	# 同一流正在播放 → 跳过
	if stream == _current_bgm_stream and player.playing:
		return
	# 直接播放，不依赖 tween
	player.stop()
	player.stream = stream
	player.volume_db = 0.0
	player.play()
	_current_bgm_stream = stream
	# 非阻塞后台淡入
	_fade_in_bgm_player_bg(fade_duration)

## 后台淡入（不阻塞）
func _fade_in_bgm_player_bg(duration: float) -> void:
	var player = _get_bgm_player()
	if not player.playing:
		return
	if _bgm_fade_tween and _bgm_fade_tween.is_valid():
		_bgm_fade_tween.kill()
	# 从当前音量 tween 到 0dB（如果已经在 0dB 就不做任何事）
	_bgm_fade_tween = create_tween()
	_bgm_fade_tween.tween_property(player, "volume_db", 0.0, duration).from_current()

## 音频闪避 — 重要音效时临时降低 BGM 音量
func duck_bgm_for_sfx(duck_duration: float = BGM_DUCK_DURATION, duck_volume: float = BGM_DUCK_VOLUME):
	var player = _get_bgm_player()
	if not _current_bgm_stream or not player.playing:
		return
	var original_volume = player.volume_db
	if audio_duck_tween and audio_duck_tween.is_valid():
		audio_duck_tween.kill()
	audio_duck_tween = create_tween()
	audio_duck_tween.tween_property(player, "volume_db", linear_to_db(duck_volume), 0.2)
	audio_duck_tween.tween_interval(duck_duration)
	audio_duck_tween.tween_property(player, "volume_db", original_volume, 0.5)

## 播放事件 BGM — 保存当前 BGM，切换事件 BGM
func play_event_bgm(bgm_name: String):
	is_event_bgm_playing = true
	if _current_bgm_stream:
		_saved_bgm_stream = _current_bgm_stream
	var stream = _load_bgm_compat(bgm_name)
	if stream:
		play_bgm_stream(stream)

## 播放事件 BGM（流式版，推荐）
func play_event_bgm_stream(stream: AudioStream):
	if not stream:
		return
	is_event_bgm_playing = true
	if _current_bgm_stream:
		_saved_bgm_stream = _current_bgm_stream
	play_bgm_stream(stream)

## 停止事件 BGM — 条件恢复之前的 BGM
func stop_event_bgm():
	is_event_bgm_playing = false
	if _saved_bgm_stream:
		var saved = _saved_bgm_stream
		_saved_bgm_stream = null
		play_bgm_stream(saved)
	else:
		print("AudioManager: 没有可恢复的 BGM")

func is_playing_event_bgm() -> bool:
	return is_event_bgm_playing

# ----- 事件 BGM 抑制（用于入场动画/过场动画期间） -----

## 设置事件抑制状态。true=抑制BGM播放，false=恢复并播放缓存的BGM
func set_event_bgm_suppress(suppress: bool) -> void:
	_event_bgm_suppress = suppress
	if not suppress and _pending_event_bgm:
		var saved = _pending_event_bgm
		_pending_event_bgm = null
		play_bgm_stream(saved, ROOM_FADE_DURATION)

## 死亡时 BGM 淡出（联动死亡流程，非阻塞）
func fade_out_bgm_on_death(fade_duration: float = 1.2) -> void:
	var player = _get_bgm_player()
	if not player.playing:
		return
	var tween = create_tween()
	tween.tween_property(player, "volume_db", -80.0, fade_duration)
	tween.tween_callback(stop_bgm_stream)

## 旧版兼容：通过名称加载 BGM 流（仅限 BGM0）
func _load_bgm_compat(bgm_name: String) -> AudioStream:
	if _bgm_stream_cache.has(bgm_name):
		return _bgm_stream_cache[bgm_name]
	if not bgm_paths.has(bgm_name) or not bgm_paths[bgm_name]:
		return null
	if not ResourceLoader.exists(bgm_paths[bgm_name]):
		return null
	_bgm_stream_cache[bgm_name] = load(bgm_paths[bgm_name])
	return _bgm_stream_cache[bgm_name]

# ============================================================
# 🎵 BGM 旧版兼容接口（逐步淘汰）
# ============================================================

## 停止 BGM 流播放（立即停止，无淡出）
func stop_bgm_stream() -> void:
	var player = _get_bgm_player()
	if player.playing:
		player.stop()
	_current_bgm_stream = null

## 通过名称播放 BGM（内部委托给 play_bgm_stream）
func play_bgm(bgm_name: String, fade_duration: float = BGM_FADE_IN_DURATION):
	var stream = _load_bgm_compat(bgm_name)
	if not stream:
		return
	play_bgm_stream(stream, fade_duration)

## 停止 BGM（立即停止）
func stop_bgm(_fade_duration: float = BGM_FADE_OUT_DURATION):
	stop_bgm_stream()

# ============================================================
# 🎵 SFX 流式接口（含优先级排队）
# ============================================================

## 取某个音效的增益（dB）：查 sfx_gain_db，表里没有就返回 0
func get_sfx_gain_db(stream: AudioStream) -> float:
	if stream == null:
		return 0.0
	var path: String = stream.resource_path
	if path == "":
		return 0.0
	return float(sfx_gain_db.get(path, 0.0))


## 播放一次性音效（默认优先级 NORMAL）
func play_stream_sfx(stream: AudioStream, bus: String = SFX_BUS) -> void:
	play_stream_sfx_prioritized(stream, SFX_PRIORITY_NORMAL, bus)

## 全局统一点击音效（所有UI场景共用此方法）。
## stream 传 null 时使用全局默认点击音效；组件需要自定义音效时可直接传入。
func play_button_click_sfx(stream: AudioStream = null) -> void:
	play_stream_sfx(stream if stream != null else button_click_sfx)

## 全局统一悬停音效（所有UI场景共用此方法）。
## 带全局节流：HOVER_SFX_MIN_INTERVAL 以内的重复调用会被丢弃，避免快速扫过一排按钮时音效叠成一团。
func play_button_hover_sfx(stream: AudioStream = null) -> void:
	var s: AudioStream = stream if stream != null else button_hover_sfx
	if s == null:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_hover_sfx_ms < int(HOVER_SFX_MIN_INTERVAL * 1000.0):
		return
	_last_hover_sfx_ms = now
	play_stream_sfx_prioritized(s, SFX_PRIORITY_LOW)

## 播放一次性音效（带优先级 + 对象池）
func play_stream_sfx_prioritized(stream: AudioStream, priority: int = SFX_PRIORITY_NORMAL, bus: String = SFX_BUS) -> void:
	if not stream:
		return
	# 清理已释放的池条目
	_sfx_instances = _sfx_instances.filter(func(e): return e.pool_idx >= 0 and e.pool_idx < _sfx_pool.size() and is_instance_valid(_sfx_pool[e.pool_idx]))
	# 找空闲池成员
	var free_idx: int = -1
	for ei in range(_sfx_instances.size()):
		var pi = _sfx_instances[ei].pool_idx
		if pi >= 0 and pi < _sfx_pool.size():
			if not _sfx_pool[pi].playing:
				free_idx = ei
				break
	if free_idx < 0:
		# 无空闲 → 用优先级驱逐
		var max_for_priority = MAX_SFX_PER_PRIORITY.get(priority, MAX_SFX_INSTANCES)
		if _sfx_instances.size() >= _SFX_POOL_SIZE or _count_at_or_below(priority) >= max_for_priority:
			_evict_lowest(priority)
		if _sfx_instances.size() >= _SFX_POOL_SIZE:
			return
		# 如果驱逐后有池成员空闲了，用它；否则用第一个空闲池成员
		for pi in range(_sfx_pool.size()):
			if not _sfx_pool[pi].playing:
				free_idx = _sfx_instances.size()  # 新条目
				_sfx_instances.append({"pool_idx": pi, "priority": priority})
				break
	if free_idx < 0 and _sfx_instances.size() < _SFX_POOL_SIZE:
		# 还有未用过的池成员
		free_idx = _sfx_instances.size()
		_sfx_instances.append({"pool_idx": free_idx, "priority": priority})
	if free_idx < 0:
		return
	var pool_i: int = _sfx_instances[free_idx if free_idx < _sfx_instances.size() else 0].pool_idx if free_idx >= 0 else -1
	if pool_i < 0:
		return
	var player: AudioStreamPlayer = _sfx_pool[pool_i]
	player.stop()
	player.stream = stream.duplicate() if stream is AudioStream else stream
	player.bus = bus
	# ★ 套用「音效增益表」：按素材路径查 dB（查的是原始 stream，duplicate 后路径会丢）
	player.volume_db = get_sfx_gain_db(stream)
	player.play()

func _count_at_or_below(threshold: int) -> int:
	var count: int = 0
	for entry in _sfx_instances:
		var pi = entry.pool_idx
		if pi >= 0 and pi < _sfx_pool.size() and is_instance_valid(_sfx_pool[pi]) and _sfx_pool[pi].playing and entry.priority <= threshold:
			count += 1
	return count

func _evict_lowest(new_priority: int) -> void:
	var lowest_ei: int = -1
	var lowest_prio: int = 999
	for ei in range(_sfx_instances.size()):
		var entry = _sfx_instances[ei]
		var pi = entry.pool_idx
		if pi >= 0 and pi < _sfx_pool.size() and is_instance_valid(_sfx_pool[pi]):
			if _sfx_pool[pi].playing and entry.priority < lowest_prio and entry.priority < new_priority:
				lowest_prio = entry.priority
				lowest_ei = ei
	if lowest_ei >= 0:
		var victim_pi = _sfx_instances[lowest_ei].pool_idx
		if victim_pi >= 0 and victim_pi < _sfx_pool.size() and is_instance_valid(_sfx_pool[victim_pi]):
			_sfx_pool[victim_pi].stop()
		_sfx_instances.remove_at(lowest_ei)

## 启动循环音效
func play_stream_looped(key: String, stream: AudioStream, bus: String = SFX_BUS) -> void:
	if not stream or _looped_players.has(key):
		return
	var instance = stream.duplicate() if stream is AudioStream else stream
	var sfx_player = AudioStreamPlayer.new()
	sfx_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(sfx_player)
	sfx_player.stream = instance
	sfx_player.bus = bus
	# ★ 循环音效同样套用增益表
	sfx_player.volume_db = get_sfx_gain_db(stream)
	sfx_player.finished.connect(_on_looped_sfx_finished.bind(key))
	sfx_player.play()
	_looped_players[key] = sfx_player

## 停止循环音效
func stop_stream_looped(key: String) -> void:
	if not _looped_players.has(key):
		return
	var player: AudioStreamPlayer = _looped_players[key]
	if is_instance_valid(player):
		player.stop()
		player.queue_free()
	_looped_players.erase(key)

func _on_looped_sfx_finished(key: String) -> void:
	if _looped_players.has(key):
		var player: AudioStreamPlayer = _looped_players[key]
		if is_instance_valid(player):
			player.play()

# ============================================================
# 🔊 音量控制
# ============================================================

func get_bus_volume_percent(bus_name: String) -> float:
	var bus_index = AudioServer.get_bus_index(bus_name)
	if bus_index != -1:
		return db_to_linear(AudioServer.get_bus_volume_db(bus_index)) * 100.0
	return 70.0

func set_bus_volume_percent(bus_name: String, value: float):
	var bus_index = AudioServer.get_bus_index(bus_name)
	if bus_index != -1:
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(value / 100.0))
		# ★ 改完就安排写盘：否则下次启动音量会回到项目默认值
		_schedule_audio_settings_save()

func set_master_volume(value: float):
	set_bus_volume_percent("Master", value * 100.0)

func set_bgm_volume(value: float):
	set_bus_volume_percent("BGM", value * 100.0)

func set_sfx_volume(value: float):
	set_bus_volume_percent("SFX", value * 100.0)

func set_voice_volume(value: float):
	set_bus_volume_percent("Voice", value * 100.0)
## 程序退出前停止所有播放器，避免 Ogg 播放对象在 ObjectDB 清理阶段泄漏
## （否则每次关闭游戏都会打印 "ObjectDB instances leaked at exit" 与 "resources still in use"）。
## NOTIFICATION_EXIT_TREE 在引擎关闭阶段一定触发（--quit-after / 直接关闭窗口均覆盖），
## 仅靠 NOTIFICATION_WM_CLOSE_REQUEST 在无窗口或命令行退出时不会触发，故两者都监听。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_PREDELETE, NOTIFICATION_EXIT_TREE:
			_stop_all_players_for_exit()


## 供退出流程显式调用的公开入口（UIRouter.quit_game 在 tree.quit() 之前调用）。
func stop_all_for_exit() -> void:
	_stop_all_players_for_exit()


## 停止 BGM 与音效池中的全部播放器并释放播放对象
func _stop_all_players_for_exit() -> void:
	if not _exit_cleanup_done:
		_exit_cleanup_done = true
	else:
		return
	if is_instance_valid(_bgm_player):
		_bgm_player.stop()
		_bgm_player.stream = null
	for p in _sfx_pool:
		if is_instance_valid(p):
			p.stop()
			p.stream = null
	# 循环音效（play_stream_looped）是挂在 AudioManager 下的独立节点，
	# 不在 _sfx_pool 里，必须单独停止并释放，否则同样会带着 Ogg 资源泄漏。
	for key in _looped_players.keys():
		var looped = _looped_players[key]
		if is_instance_valid(looped):
			looped.stop()
			looped.stream = null
	# 兜底：遍历本节点下所有仍在播放的 AudioStreamPlayer*，统一停止并断开流引用。
	for child in get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null
		elif child is AudioStreamPlayer2D or child is AudioStreamPlayer3D:
			child.stop()
			child.stream = null
	# 清空 BGM 流缓存：缓存里持有 AudioStreamOggVorbis 的强引用，
	# 不清空会在退出时表现为 "探险.ogg 仍在使用" / ObjectDB 泄漏。
	_bgm_stream_cache.clear()
	_looped_players.clear()
	# _current_bgm_stream / _saved_bgm_stream / _pending_event_bgm 同样是强引用，
	# 只把 player.stream 置空并不能释放 AudioStreamOggVorbis 与 OggPacketSequence。
	_current_bgm_stream = null
	_saved_bgm_stream = null
	_pending_event_bgm = null
	# 说明：音频资源还挂在 ResourceLoader 的全局缓存里，Godot 4.5 没有公开的
	# “从缓存移除” API（remove_from_cache 不存在），因此这里只负责解除本管理器的全部强引用。
	# 退出阶段剩下的 Ogg 引用属于引擎缓存，不影响游戏运行，也不会出现在编辑器的错误面板里。