class_name AchievementCatalog
extends Resource
## 成就总目录：**列表顺序 = 成就界面里的展示顺序**（每页 5 个，自动分页）。
##
## 元素类型声明成 Resource 而不是 AchievementData，是为了让 .tres 在任何加载顺序下
## 都能解析（class_name 的全局注册是异步的，早期加载时可能还没注册好）。
## 实际拖进来的资源必须是 AchievementData。

@export var achievements: Array[Resource] = []
