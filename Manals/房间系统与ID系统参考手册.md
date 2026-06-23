# 房间系统与ID系统参考手册
## 最后更新：2026-06-22

## 一、场景/实例 ID 总览

### 1. Room（房间）
- **脚本**: `Scripts/GameScenes/Room.gd`
- **ID 字段**: `@export var room_id: String = "Room1"` — **全局唯一**
- **文件位置**: `Scenes/GameScenes/Rooms/{room_id}.tscn`（支持子目录）

### 2. Door（门）
- **脚本**: `Scripts/GameScenes/Door.gd`
- **ID 字段**:
  - `door_id: String = ""` — **全局唯一**，成对门用相同 ID
  - `target_room_id: String = ""` — 引用 Room.room_id

### 3. DynamicCheckpoint（动态检查点）
- **脚本**: `Scripts/Instances/SavePoints/DynamicCheckpoint.gd`
- **ID 字段**:
  - `checkpoint_id: String = ""` — **房间内唯一**
  - `belongs_to_room: String = ""` — 引用 Room.room_id（推荐填写）

### 4. ChairSavePoint（椅子存档点）
- **脚本**: `Scripts/Instances/SavePoints/ChairSavePoint.gd`
- **ID 字段**: `save_point_id: String = "default_chair"` — **全局唯一**

### 5. TeleportPoint（传送阵）
- **脚本**: `Scripts/Instances/TeleportPoint.gd`
- **ID 字段**: `teleport_id: String = ""` — **全局唯一**

### 6. DestructibleWall（可破坏墙壁）
- **脚本**: `Scripts/Instances/DestructibleWall.gd`
- **ID 字段**: `wall_id: String = ""` — **全局唯一**

### 7. HealthUpgradeItem（生命升级道具）
- **脚本**: `Scripts/Instances/HealthUpgradeItem.gd`
- **ID 字段**: `item_id: String = ""` — **全局唯一**

### 8. BaseNPC（NPC）
- **脚本**: `Scripts/NPCs/BaseNPC.gd`
- **ID 字段**: `npc_id: String = ""` — **全局唯一**

### 9. TeleportPanelButton（传送面板按钮）
- **脚本**: `Scripts/UI/TeleportPanelButton.gd`
- **ID 字段**: `target_teleport_id: String` — 引用 TeleportPoint.teleport_id

### 10. MapData（地图数据资源）
- **脚本**: `Scripts/GameScenes/MapData.gd`
- **字段**: `room_id`（引用 Room）和 `teleport_ids`（引用 TeleportPoint）
- **位置**: `Assets/Maps/{room_id}_mapdata.tres`

---

## 二、房间管理操作清单

### 创建新房间

| # | 操作 | 文件位置 |
|---|------|---------|
| 1 | 创建 `{RoomId}.tscn` 场景，设置 `room_id` 导出变量 | `Scenes/GameScenes/Rooms/[子目录/]{RoomId}.tscn` |
| 2 | 在 `ROOM_PATHS` 字典中添加条目 | `Scripts/Managers/ScenePaths.gd` |
| 3 | 在 `room_positions` 字典中添加位置偏移 | `Assets/Configs/RoomLayoutData.tres` |
| 4 | 设置相邻房间（`adjacent_rooms` 数组） | 房间 `.tscn` 的 Inspector |
| 5 | 在房间内放置 Door / DynamicCheckpoint 等实例 | 房间 `.tscn` |
| 6 | （可选）添加地图数据资源 | `Assets/Maps/{RoomId}_mapdata.tres` |

### 修改房间命名

| # | 操作 | 文件位置 |
|---|------|---------|
| 1 | 修改 `room_id` 导出变量 | 房间 `.tscn` 的 Inspector |
| 2 | `ROOM_PATHS` 字典键 + 值 | `Scripts/Managers/ScenePaths.gd` |
| 3 | `room_positions` 字典键 | `Assets/Configs/RoomLayoutData.tres` |
| 4 | 查找 `Door.target_room_id` 引用旧 ID 的改为新 ID | 所有 `.tscn` |
| 5 | 查找 `DynamicCheckpoint.belongs_to_room` 引用旧 ID 的改为新 ID | 所有 `.tscn` |
| 6 | `MapData.room_id` 改为新 ID，文件重命名 | `Assets/Maps/` |

### 修改房间路径（移动 .tscn 位置）

| # | 操作 | 文件位置 |
|---|------|---------|
| 1 | 物理移动 `.tscn` 文件 | 文件系统 |
| 2 | `ROOM_PATHS` 更新路径值 | `Scripts/Managers/ScenePaths.gd` |
| 3 | 其他文件不受影响 | — |

### 删除房间

| # | 操作 | 文件位置 |
|---|------|---------|
| 1 | 移除 `ROOM_PATHS` 条目 | `Scripts/Managers/ScenePaths.gd` |
| 2 | 移除 `room_positions` 条目 | `Assets/Configs/RoomLayoutData.tres` |
| 3 | 清理引用该 room_id 的 Door / DynamicCheckpoint | 所有 `.tscn` |
| 4 | 删除 MapData 资源（如有） | `Assets/Maps/{RoomId}_mapdata.tres` |
| 5 | 删除 `.tscn` 文件 | `Scenes/GameScenes/Rooms/{RoomId}.tscn` |
