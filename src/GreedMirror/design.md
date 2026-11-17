# 贪婪镜 GreedMirror — 设计说明（节选）

## 1. 问题：只说「数据不可读」等于没说

玩家看到「数据不可读」时，无法判断三件事：

1. **缺哪一项** —— 需求次数 / 贪婪次数 / 进本次数？
2. **为什么缺** —— 暴雪没上报？被保护了？还是接口调用失败？
3. **能不能自己解决** —— 需要去刷副本？等战斗结束？还是就这样？

实测（无限服 camelot 客户端，本角色）：`GetStatistic(932)`（进入 5 人地下城副本的次数）返回 `--`，
即服务端**未上报**该统计项；`1044`（需求骰子）/`1043`（贪婪骰子）可读。
这类"从未产生过该行为"的统计项，是最常撞上「数据不可读」的真实场景。

## 2. 新方案：分层提示（三段式）

| 位置 | 内容 | 是否受「详细次数」开关影响 |
| --- | --- | --- |
| 第 1 行 | `数据不完整：缺 进本次数` | 否 |
| 第 2 行 | `原因：服务端未上报该统计项 · 建议：尚未进过 5 人地下城，或服务端尚未同步` | 否 |
| 第 3 行（次数明细） | `需求 1 · 贪婪 1 · 掷骰 2 · 副本 ?` | 是 |

要点：

- **绝不用 0 冒充不可读的字段**：`0` 是合法数值，显示成 0 会让玩家以为"真的没需求"。
  读不到的字段一律显示 `?`（旧代码 `row.need or 0` 是 bug）。
- 原因按 `Stats.ReadRow` 早已解析好的 `quality` 分类，不再丢弃信息：

  | quality | 原因文案 | 建议 |
  | --- | --- | --- |
  | `unreported` | 服务端未上报该统计项 | 按字段给：尚未掷过需求骰子 / 尚未掷过贪婪骰子 / 尚未进过 5 人地下城，或服务端尚未同步 |
  | `restricted` | 数值受保护，当前状态读不到 | 退出战斗或等加载结束后再试 |
  | `unknown` | 返回值无法识别 | 稍后重试，或用 `/greed probe` 查看原始返回值 |
  | `format` | 返回值格式异常 | 同上 |
  | `api` | 客户端缺少该统计的读取接口 | 同上 |
  | `error` | 读取接口调用失败 | 同上 |

- **判定逻辑不变**：`Rate.Evaluate` 仍然是"三项缺一即 `nodata`"，
  不因为"只缺进本"就给出需求率（需求率的分母就是进本次数，缺了就无法判定）。
- 聊天输出（`/greed self`、`/greed target`）与提示框共用同一套文案。

## 3. 改动清单

| 文件 | 改动 |
| --- | --- |
| `I18n.lua` | 新增 `NODATA_TITLE` / `NODATA_DETAIL` / `REASON_*` / `HINT_*` / `VALUE_MISSING`；`COUNT_LINE` 由 `%d` 改为 `%s` 以支持 `?` 占位 |
| `Tooltip.lua` | 新增 `Tooltip.MissingInfo(row)` / `Tooltip.NodataTitle(info)` / `Tooltip.NodataDetail(info)` / `Tooltip.StatusText(status)`；`Tooltip.VerdictText(result, row)` 接受 row 并给出"缺哪一项"；`Tooltip.BuildLines` 的 nodata 分支固定输出两行原因提示，次数明细改用 `?` 占位 |
| `Scan.lua` | `finish()` 在 NODATA 时**保留 row**（连同 `quality`）一起 `notify`，提示框/聊天才能说明原因；读不到的行仍然**不写缓存**，避免下次命中缓存却拿不到原因 |
| `Core.lua` | `reportRow` 支持 `name` 参数并输出缺失原因行；`/greed target` 接入结果回显（此前只打印"正在读取…"）；新增 `Scan.OnReady` 回调，把队伍/团队中的高需求率玩家写入名单 |
| `Party.lua` | 同一人、同一需求率不重复打印"已记录高需求率玩家" |

## 4. 顺手修掉的两处接线问题

1. **`/greed target` 没有结果**：原代码只 `Scan.Request(...)` 然后 `return`，
   查询结果回来时无人打印。现在 `pendingTarget` 记住这次查询，扫描回调命中后立刻输出。
2. **`Party.Record` 从未被调用**：高需求率名单永远是空的（`/greed watch` 只能显示空列表）。
   现在在扫描回调里，对**队伍/团队成员**中需求率极高（≥50%）的玩家调用 `Party.Record`。
   只记录队伍成员，避免随机悬停把名单塞满路人。

## 5. 顺带发现的本客户端坑：提示框一直没画出来

实测（无限服 camelot 客户端）：

- `GameTooltip:GetUnit()` 返回的是**角色名**而不是单位 token
  （`SetUnit("player")` 之后返回的是玩家名字 `上呀么上好佳`）。
  旧代码把它直接丢给 `UnitExists` / `UnitIsPlayer`，结果永远是 `false` →
  `tooltipUnit()` 返回 nil → 提示框里一行都不画（这正是"数据不可读"看不到细节的根因之一）。
- 修复：新增 `Stats.ResolveUnitToken(name)`，在 `mouseover / target / focus / player /
  party1-4 / raid1-40 / nameplate1-40` 里按名字反查单位 token，再交给 `Stats.UnitIdentity`。
- 顺带把取第 N 行字体对象的 `left()` 改成优先用 `tooltip["TextLeft" .. N]`，
  找不到再退回全局名 `GameTooltipTextLeftN`（运行时新建的行未必有全局名）。

## 6. 提示框挂载方式：本客户端没有 `OnTooltipSetUnit` 脚本

排查「提示框一行都不画」时发现的第二个根因：

- 本客户端 `GameTooltip` **没有 `OnTooltipSetUnit` 这个脚本**：
  `GameTooltip:HookScript("OnTooltipSetUnit", f)` 直接报
  `bad argument #2 to '?' (Usage: local success = self:HookScript(scriptTypeName, script [, bindingType]))`。
  旧代码用 `pcall` 包住，失败后落到 `UPDATE_MOUSEOVER_UNIT` 轮询分支，
  而该事件触发时提示框往往还没显示（`GameTooltip:IsShown()` 为 false），
  之后不再有事件 → 永远不画。
- 本客户端可用的脚本：`OnShow` / `OnHide` / `OnTooltipCleared` / `OnUpdate` 均可用。
  `TooltipDataProcessor` 是 table，`AddTooltipPostCall` / `AddTooltipPreCall` 是 function，
  但**单位提示框并不走它的 post call**（实测 `SetUnit` 后同步读行数仍是游戏自己的 2 行）。

因此 `Tooltip.Init()` 改成三级链路 + 一个看门狗：

| 顺序 | 手段 | 适用 |
| --- | --- | --- |
| 1 | `TooltipDataProcessor.AddTooltipPostCall` | 零售等走标准管线的客户端 |
| 2 | `HookScript("OnTooltipSetUnit")` | 支持该脚本的客户端（并记 `GM.tooltipHook` 便于热加载摘钩） |
| 3 | `HookScript("OnShow")` + `HookScript("OnUpdate")` | 兜底 |
| 4 | 看门狗：`C_Timer.After(0.5)` 轮询 | 兜底（本客户端实际生效的就是这条） |

看门狗的判定：提示框已显示 → 找到当前单位 → 若「还没为这个单位画过」
或「我们画的行被游戏清掉了」（游戏重建提示框会清空所有行）→ 重新画一次。
行是否还在通过比对 `rows[1].fs:GetText()` 与我们写入的文本来判断。
自己画的行始终复用（`tooltip:AddLine` 只在缺行时调用），所以不会重复堆行。

实测（游戏内 `GameTooltip:SetUnit("player")` 后读回 7 行）：

```
1:上呀么上好佳 味呀么味道香                          ← 游戏
2:23 牛头人 萨满祭司                                 ← 游戏
3:目标: 腐蚀兽                                       ← 游戏
4:物品等级: 10.9                                     ← 游戏
5:数据不完整：缺 进本次数                            ← 插件
6:原因：服务端未上报该统计项 · 建议：尚未进过 5 人地下城，或服务端尚未同步  ← 插件
7:需求 1 · 贪婪 1 · 掷骰 2 · 副本 ?                  ← 插件（详细次数开启时）
```

聊天输出同步为三行：

```
贪婪镜 正在读取自己的统计…
贪婪镜 你的统计：需求 1 · 贪婪 1 · 副本 ? → 数据不完整：缺 进本次数
贪婪镜 原因：服务端未上报该统计项 · 建议：尚未进过 5 人地下城，或服务端尚未同步
```

## 7. 设置页拆成「常用 / 名单」两个子页

### 目标

- 设置页分为两个子页：**常用**（开关与常规操作）、**名单**（高需求率名单）。
- 「清空高需求率名单」按钮从常用页移到名单页。
- 名单页按钮下方按行显示名单里每个玩家的姓名与数据（每行一个）。

### 做法（用户已拍板）

| 决定点 | 选择 |
| --- | --- |
| 子页形式 | 左侧一个「**+**」按钮，点开弹出两项菜单（常用 / 名单）；**仍只注册一个分类**「贪婪镜」（游戏 → 插件 → 贪婪镜） |
| 名单过长 | 鼠标滚轮滚动，固定 8 行，底部显示「第 1-8 / 共 n 条」 |
| 每行内容 | 复用 `WATCH_ROW`：`姓名 · 需求率% · 需求 · 贪婪 · 记录于 日期`（与 `/greed watch` 一致） |

### 布局

```
贪婪镜 1.0.0
[+]                                ← 左上角「+」，点开是常用 / 名单两项菜单
  ┌──────────────┐
  │ 常用         │                ← 选中项黄色，未选中灰色
  │ 名单         │
  └──────────────┘
常用页：启用插件 / 提示框 / 自身数据 / 详细次数 / 队伍高需求率提示
        查询间隔 / 清除缓存 / 打开设置页
名单页：高需求率名单（n 条）
        [ 清空高需求率名单 ]（二次点击确认）
        姓名 · 62% · 需求 31 · 贪婪 48 · 记录于 2026-11-16
        ……（最多 8 行）
        第 1-8 / 共 23 条 · 滚轮上下滚动
```

### 实现要点

- `Settings.SetPage(page)`：切换两个内容面板的显示、收起菜单、并更新菜单项配色
  （`GM.COLORS.yellow` / `GM.COLORS.gray`）。
- `Settings.ToggleMenu()`：点「+」展开 / 收起菜单；设置页隐藏时（`OnHide`）自动收起。
- 菜单 = 一个 132×56 的浮层（半透明黑底）+ 两个 `UIPanelButtonTemplate` 按钮。
- `Settings.Refresh()` 扩展为：刷新勾选项 + 各按钮文字 + **重新渲染名单列表**；
  `frame:OnShow` 时刷新并停在上次所在页（默认「常用」）。
- 名单列表 = 8 行 `FontString`（`GameFontNormal`），数据来自 `DB.WatchList()`
  （已按需求率降序）。文本复用 `I18n.T("WATCH_ROW", ...)`，与聊天输出一致。
- 滚轮：名单页容器 `EnableMouseWheel(true)` + `OnMouseWheel` 调整偏移（每次 1 行），
  只在名单页激活时响应；偏移越界自动夹紧。
- 新增 I18n 键：`TAB_GENERAL`、`TAB_WATCH`、`WATCH_SCROLL_HINT`（复用 `WATCH_EMPTY` 作为空态）。
- 不改 `DB`、不改名单数据结构、不改扫描与判定逻辑。

### 约束与边界

- 本客户端 `CreateFrame` 不支持 `ScrollBar` 类型，`UIPanelScrollFrameTemplate` 一用就报
  `Unknown script element OnScrollRangeChanged / OnVerticalScroll` → **放不了原生滚动条**，
  故采用滚轮方案。
- 名单内容来自 `Party.Record`，而它只记录**队伍 / 团队成员**，因此单人状态下名单为空属预期，
  页面应显示空态文案而不是空白。

### 验证

`check` 0 错误 → 玩家点一次 UI 重载 → 打开设置页 → 切到「名单」页 → 确认两页都能渲染、
空态文案正常；与队友一起打本后再确认列表出现真实行。

## 8. 名单语义调整（用户补充的需求）

用户澄清：「高需求率名单应该是**所有查询过玩家之中**高需求率的玩家，并在**进入自己所在队伍或团队**时给我提示。」

### 8.1 记录范围：队伍成员 → 所有查询过的玩家

上一版（Core.lua `onScanResult`）只把**队伍/团队成员**写入名单，理由是"避免随机悬停把名单塞满路人"。
现按用户要求改为：**任何被查询到且需求率 ≥ 50% 的玩家都进名单**（无论是否在队伍里）。

- 改动点：`Core.lua:92-97` 去掉 `GM.Party.IsInGroup(guid)` 过滤，只保留
  `status == "READY"` + `Rate.IsHighRate(result)` 两个条件。
- 名单持久化在 SavedVariables（`DB.watchlist`），会随查询逐渐变长；
  「清空高需求率名单」按钮在名单页，可随时清。
- 仍保留 `Party.Record` 里"同一人同一需求率不重复打印"的去重。

### 8.2 进入队伍/团队时的提示：逐人 → 一次性汇总

现状 `Party.CheckRoster()` 在每个队伍事件（GROUP_ROSTER_UPDATE / GROUP_JOINED /
GROUP_FORMED / GROUP_LEFT）上触发，逐个命中名单的玩家调用 `Party.Notify`，
每人一行聊天 + 一次屏幕中央提示。改成**一次性汇总**：

- 聊天一行：`【贪婪镜】队伍中有高需求率玩家：张三(62%)、李四(70%)`
- 屏幕中央一行：`队伍高需求率：张三 62% · 李四 70%`
- 命中的人仍受 600 秒冷却限制（`notified` 表），避免每次名单变动都刷屏。
- 受设置项 `partyAlert`（队伍高需求率提示）控制，默认开启。
- 命中判定用 GUID 查名单，因此**即使这些队友本次会话没被查询过**，只要历史名单里有就会提示 —— 这正是"进入队伍时提醒"的意义。

### 8.3 新增文案键

| 键 | 文案 |
| --- | --- |
| `TAB_GENERAL` | 常用 |
| `TAB_WATCH` | 名单 |
| `WATCH_SCROLL_HINT` | 第 %d-%d / 共 %d 条 · 滚轮上下滚动 |
| `PARTY_ROSTER_CHAT` | 【贪婪镜】队伍中有高需求率玩家：%s |
| `PARTY_ROSTER_SCREEN` | 队伍高需求率：%s |

## 9. 设置页改成 TotemTimers 式的暴雪原生子分类

### 用户要求（参考 TotemTimers 截图）

「游戏 → 插件」列表里，TotemTimers 那一行左侧有「－/＋」展开钮，展开后缩进列出
「按钮设置 / 追踪器设置 / 警告设置 …」。**不要自绘页内标签或浮层菜单**，
要用暴雪原生的「插件 → 多个子面板」结构。

本节取代第 7 节里「页内 ＋ 按钮 + 浮层菜单」的界面形式；
第 7 节的功能内容（常用 / 名单 两页、名单逐行显示、滚轮滚动）保持不变。

### 暴雪原生结构（实测）

- 运行时可用（api_search 手册查不到，但游戏里存在）：
  `Settings.RegisterCanvasLayoutCategory(frame, name)`、`Settings.RegisterAddOnCategory(category)`、
  `Settings.RegisterCanvasLayoutSubcategory(parentCategory, frame, name)`、`Settings.OpenToCategory(id)`。
- 面板激活分类时，暴雪会接管画布：
  `frame:SetParent(settingsCanvas)` → `ClearAllPoints()` → `SetAllPoints(settingsCanvas)` → `Show()`
  → 调用 `frame:OnRefresh()`。**所以画布 frame 不能预设锚点与尺寸。**
- 插件列表里同一个分类下有子分类时，该行左侧出现「＋/－」展开钮，子分类缩进显示。
  参照实现：本机 TotemTimers 自带的 `AceConfigDialog-3.0.lua:1983-2041`
  （父分类先注册，再用父分类对象注册子分类）。

### 实现

`Settings.lua` 重写为三个画布：

| 画布 | 全局名 | 角色 |
| --- | --- | --- |
| `overviewFrame` | `GreedMirrorSettingsFrame` | 父分类（列表里那一行「贪婪镜」） |
| `generalFrame` | `GreedMirrorSettingsGeneralFrame` | 子分类「常用」 |
| `watchFrame` | `GreedMirrorSettingsWatchFrame` | 子分类「名单」 |

- 注册顺序：`RegisterCanvasLayoutCategory(overviewFrame, "贪婪镜")` → `RegisterAddOnCategory(category)`
  → `RegisterCanvasLayoutSubcategory(category, generalFrame, "常用")` /
  `RegisterCanvasLayoutSubcategory(category, watchFrame, "名单")`。
- 分类 ID 写进 `frame.name` / `frame.parent`（与 AceConfig 一致）。
- `Settings.OpenPage(page)`：`Settings.OpenToCategory(子分类 ID)`；
  取 ID 兼容 `category:GetID()` 与 `category.ID`。
- 回退链：现代 API → `InterfaceOptions_AddCategory` → `/greed settings` 自绘面板。
- 画布顶部已有暴雪画的分类名，插件不再重复画标题。
- `Core.lua` 只调用 `GM.Settings.Init()` / `GM.Settings.Open()`，无其它引用。

### 实测（UI 重载后）

```
分类 贪婪镜#19  subs=[常用#20, 名单#21]
画布 GreedMirrorSettingsFrame        name=19  parent=nil
画布 GreedMirrorSettingsGeneralFrame name=20  parent=19
画布 GreedMirrorSettingsWatchFrame   name=21  parent=19
```

游戏里「游戏 → 插件」列表：贪婪镜行左侧出现展开钮，展开后缩进列出「常用 / 名单」；
名单页渲染出名单行与「第 1-8 / 共 n 条 · 滚轮上下滚动」；清空按钮二次点击确认后名单被清空。

### 顺带修的健壮性问题

`Core.lua` 的 `setupWhenReady()` 原来在第一次成功初始化后就停止重试，
热加载时新模块替换旧模块便不会再初始化（新模块 `DB.sv=nil`、提示框 `mode=nil`）。
现在改成整个窗口内每 0.2 秒尝试一次，由 `setup()` 内部的「模块身份」判断是否已初始化，
窗口长度 120 × 0.2 秒 ≈ 24 秒，覆盖热加载逐文件发送的时间。

## 10. 名单行显示「种族 / 职业」

### 用户要求

「名单中应该显示 玩家姓名 种族 职业 及相关数据。」

### 之前的问题

名单 entry 只存了 `guid / name / realm / rate / need / greed / rolls / dungeons / at`，
**没有种族，也没有职业**——因为扫描流程里 `Stats.UnitIdentity()` 只取了 `UnitClass`，
从头到尾就没读过 `UnitRace`。

### 改动

| 文件 | 改动 |
| --- | --- |
| `Stats.lua` | `Stats.UnitIdentity()` 追加 `UnitRace(unit)`（`Stats.SafeCall` 包装，接口缺失/受保护时按 nil 处理）→ identity 增加 `race`；自身行 `row.race = identity.race` |
| `Scan.lua` | 队列项存 `race`；READY 时 `row.race = entry.race`；pending 刷新时补 `pending.class` / `pending.race` |
| `Party.lua` | `Party.Record()` 的 entry 增加 `race` / `class`（新记录取 row，旧记录回落到已有 entry） |
| `DB.lua` | `DB.WatchList()` 复制 `race` / `class` 字段 |
| `I18n.lua` | `WATCH_ROW` 改为 `"%s%s · %d%% · 需求 %d · 贪婪 %d · 记录于 %s"`；新增 `RACE_CLASS = "（%s）"` 与 `I18n.RaceClassText(race, class)` |
| `Settings.lua` | 名单行文本传入 `I18n.RaceClassText(entry.race, entry.class)` |
| `Core.lua` | `/greed watch` 聊天输出同样传入该描述 |

### 显示效果

```
张三（牛头人 萨满祭司）· 62% · 需求 31 · 贪婪 48 · 记录于 2026-11-16
```

- `RaceClassText()` 按「有种族就显示种族、有职业就显示职业」拼装，**旧记录（没有这两个字段）不会显示空括号**。
- 客户端实测：`UnitRace("player")` → `牛头人`、`UnitClass("player")` → `萨满祭司`（zhCN 本地化），`UnitRaceText` 不存在、`UnitClassification` 存在但用不上（normal/personalized 与需求率无关）。

## 11. 只对同阵营玩家生效

### 用户要求

「该插件仅作用于同阵营玩家，遇到对立阵营玩家不生效。」

用户拍板：**提示框里完全不留任何内容**（与没装插件一样），**不做成可关的设置项**（固定规则）。

### 客户端能力（实测）

| 接口 | 本客户端行为 |
| --- | --- |
| `UnitFactionGroup(unit)` | 存在。第一个返回值是英文 token（`UnitFactionGroup("player")` → `"Horde"`），第二个是本地化名称（`"部落"`）；**本服阵营是真的部落/联盟，不是归一化的 `"player"`** |
| `UnitIsEnemy(unit, "player")` | 存在，对敌对单位返回 true |
| `UnitIsFriend` / `UnitReaction` / `UnitCanAttack` | 存在；`UnitReaction("player","player")` 返回 5（对自己不可靠），故不采用 |
| `UnitDetailedRace` | 不存在 |

### 实现

`Stats.FactionRelation(unit)` → `friendly` | `hostile`：

1. `UnitIsEnemy(unit, "player")` 为 true → 直接判定 `hostile`（战争地带与敌对状态最准）；
2. 否则比较 `UnitFactionGroup(unit)` 与 `UnitFactionGroup("player")`：两者都是有效 token 且不同 → `hostile`
   （若任一为 `"player"` 则不判定，归一化服务器上交给第 1 条判断）；
3. 其余 → `friendly`。

接入点：

| 文件 | 改动 |
| --- | --- |
| `Stats.lua` | 新增 `Stats.FactionRelation(unit)`；`Stats.UnitIdentity()` 在确认是玩家后追加阵营判断，敌对则 `return nil, "enemy"` |
| `Scan.lua` | `Scan.Request()` 把 `why == "enemy"` 映射为新状态 `FACTION`（不进队列 → 不发查询请求，也不会进名单） |
| `Tooltip.lua` | `STATUS_KEYS.FACTION = "STATUS_FACTION"`（只用于聊天输出；提示框路径走不到，敌对玩家时 `UnitIdentity` 为 nil，直接不画任何行） |
| `I18n.lua` | 新增 `STATUS_FACTION = "敌方阵营（插件只对同阵营玩家生效）"` |
| `Core.lua` | `/greed target` 指向敌对玩家时打印该状态；NPC 仍打印原来的「鼠标没有指向玩家…」 |

### 效果

- 鼠标悬停对立阵营玩家：提示框里**只有游戏自己的行**，插件一行都不加（不查询、不显示）。
- `/greed target <敌对玩家>`：聊天提示「敌方阵营（插件只对同阵营玩家生效）」。
- 敌对玩家不会进入高需求率名单。

### 自检扩展：/greed probe 增加「阵营判定」段

`Probe.lua` 新增 `factionInfo()`，在自检输出里追加一段，便于回答「为什么这个玩家插件没反应」：

```
—— 阵营判定 ——
  我的阵营：Horde
  player：上呀么上好佳 | 阵营 Horde | 敌对 false | 判定 friendly
  说明：判定 hostile（敌对）的玩家，插件不会显示提示框、也不会查统计。
```

对 `player` / `target` / `mouseover` 各打印：名字、阵营 token、`UnitIsEnemy` 结果、
`Stats.FactionRelation()` 的判定结果。

### 验证（UI 重载后实机）

| 项 | 结果 |
| --- | --- |
| `/greed probe` | 新增「阵营判定」段正常输出：我的阵营 Horde；player 判定 friendly ✓ |
| 真实单位上的 `FactionRelation` 逻辑（与插件同代码） | player(上呀么上好佳, Horde) → friendly ✓；target「雷鳞蜥蜴」→ hostile ✓；nameplate1「乱齿捕猎者」→ hostile ✓；nameplate2「雷鳞蜥蜴」→ hostile ✓ |
| `/greed self` | 仍输出三行（你的统计 / 数据不完整：缺 进本次数 / 原因·建议）✓ |
| 自身提示框 | 4 行游戏内容 + 3 行插件内容（数据不完整：缺 进本次数 / 原因·建议 / 需求 1 · 贪婪 1 · 掷骰 2 · 副本 ?）✓ |
| `errors`（addon=GreedMirror） | 0 条 ✓ |
| `check` | 0 错误（仅 AchievementFrame / InterfaceOptions_AddCategory / InterfaceOptionsFrame_OpenToCategory 的既有 nil 警告） |

⚠️ 仍无法端到端验证：**真实的敌对玩家**（身边只有同阵营玩家「露比」，且用户不便测试）、
**读他人统计**、**队友进队时自动写入/提示名单**。


