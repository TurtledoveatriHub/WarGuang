extends Node

# 能力解锁信号
signal dash_unlocked()
signal double_jump_unlocked() 
signal glide_unlocked()
signal black_dash_unlocked()
signal wall_grip_unlocked()
signal super_dash_unlocked()
signal backstep_unlocked()
signal vertical_dash_unlocked()
signal map_unlocked()

# 竞速挑战：某个阶段刷新了最佳时间时广播（参数：阶段序号、新最佳时间秒数）
signal race_best_time_updated(stage_number: int, best_time: float)

# 单例实例
static var instance: EventBus

## 广播「某阶段刷新了竞速最佳时间」。
## ★ 走这个入口而不是外部直接 emit：信号在声明类里被显式使用，才不会有 UNUSED_SIGNAL 告警。
func notify_race_best_time_updated(stage_number: int, best_time: float) -> void:
	race_best_time_updated.emit(stage_number, best_time)

func _ready():
	instance = self
	
	# 添加这行来"使用"信号，消除警告
	_use_signals()

# 这个函数只是为了使用信号，避免警告
func _use_signals():
	# 这些调用不会执行，只是为了让Godot知道信号被"使用"了
	if false:
		dash_unlocked.emit()
		double_jump_unlocked.emit()
		glide_unlocked.emit()
		black_dash_unlocked.emit()
		wall_grip_unlocked.emit()
		super_dash_unlocked.emit()
		backstep_unlocked.emit()
		vertical_dash_unlocked.emit()
		map_unlocked.emit()
