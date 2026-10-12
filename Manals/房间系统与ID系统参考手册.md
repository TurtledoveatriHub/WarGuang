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

### 新增传送阵（TeleportPoint）完整清单

传送阵由三部分咬合，**ID 必须三处完全一致**，任何一处不同就会「激活了但面板上没有按钮」或「按钮点了传送不了」：

| # | 操作 | 文件位置 | 关键字段 |
|---|------|---------|---------|
| 1 | 场景里放一个 `TeleportPoint` | 房间 `.tscn`（建议放在 `TeleportPoints` 容器下） | `teleport_id` —— 全局唯一，建议直接写房间 ID（如 `"GrassLand14"`）。**留空会自动生成 `teleport_<坐标>`，几乎不可能是你想要的** |
| 2 | 面板里加一个按钮 | `Scenes/UI/TeleportPanel.tscn` 的 `PanelRoot` 下 | `target_teleport_id` —— **必须与第 1 步的 `teleport_id` 逐字符相同** |
| 3 | 把按钮登记进脚本数组 | `Scripts/UI/TeleportPanel.gd` 的 `teleport_buttons` | 数组元素是**节点路径**，漏登记则按钮不参与显隐/点击逻辑 |
| 4 | 设置按钮文字 | 按钮下的 `Label.text` | 纯显示，随便改 |

**显隐规则**（`TeleportPanel._update_buttons()`）：按钮只在
`target_teleport_id` **出现在 `TeleportManager.activated` 里** 时才 `visible = true`。
而 `activated` 只在玩家走到某个传送阵按交互键、播放完 `ACTIVATEBLEND` 后由
`TeleportManager.activate()` 写入。所以：

* 「已激活但按钮不显示」= 第 1/2 步的 ID 对不上（最常见是复制粘贴时漏改 `target_teleport_id`）；
* 「激活了另一个传送阵后按钮才出现」= 该按钮的 `target_teleport_id` 写成了别人的 ID；
* 当前传送阵自身的按钮会被 `disabled` + 变灰（自己不能传自己）。

> 注意：面板目前是**固定 5 个按钮**的写法（数组里写死 5 个节点路径）。
> 要加第 6 个传送阵，必须同时做第 2、3 步；只做第 1 步是不够的。

### 世界坐标（room_positions）怎么求

房间之间的相对位置不是随便填的：**同一对门的两个门节点，在世界坐标里必须重合**。
所以新增房间时：

1. 先把房间摆进 `Scenes/Tools/WorldLayout.tscn`（拖拽对齐门），或用下式直接算：

   ```
   新房间位置 = 邻房间位置 + 邻房间配对门的本地坐标 − 新房间配对门的本地坐标
   ```

   配对判据：两个门节点 `door_id` 相同（分居两个房间），即为同一对。

2. 把结果写进 `WorldLayout.tscn` 的 `RoomSlot` 节点 `position`，以及
   `Assets/Configs/RoomLayoutData.tres` 的 `room_positions`。

3. 地图画布（`map_world_origin` / `map_texture_size`）**不需要手改**：运行时
   `MapManager._prepare_generated_map()` 会调 `RoomLayoutData.sync_generated_canvas()`
   按全部房间的包围盒重算。

## 三、当前登记状态（2026-10-09 核对）

* `ROOM_PATHS`：GrassLand1~16、SnowMountain1~7、Cave1、Cave2、SuperMario2 —— 共 26 个。
* 仍有门 / 相邻关系指向**未登记房间**（属于后续要做的房间，不报错但连不过去）：
  `SnowMountain8`、`SnowMountain9`、`Cave3`。
* 「传送阵」面板按钮只有 5 个：GrassLand1 / GrassLand7 / GrassLand12 / GrassLand14 / SnowMountain4。
