extends RaceTimeBoard
class_name EndlessScoreBoard

## 无尽模式积分榜告示牌（与 RaceTimeBoard 同样的交互：靠近按交互键 → 弹出对话）
## 唯一区别是对话资源不同：这里用 {{Global.get_endless_board_text()}} 读无尽模式历史前三积分。
## 交互逻辑全部继承 RaceTimeBoard（它负责把 Global 传进对话），本脚本不再重写。
