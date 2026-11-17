-- GreedMirror 贪婪镜 - I18n.lua
-- 全部界面文案为简体中文；不使用聊天频道广播，只用 print（仅自己可见）。
local ADDON, GM = ...

local I18n = {}
GM.I18n = I18n
GM.Require("I18n")

I18n.zhCN = {
    -- 名称与提示
    PLUGIN_NAME = "贪婪镜",
    TAG = "|cff1eff00贪婪镜|r",

    -- 判定结果（tooltip 第一行）
    VERDICT_RATED_NORMAL = "需求率正常",
    VERDICT_HIGH = "需求率偏高",
    VERDICT_VERY_HIGH = "需求率极高",
    VERDICT_LOW = "活跃度过低（不显示需求率）",
    VERDICT_INSUFFICIENT = "数据不足",
    VERDICT_SMALL = "样本少（不做档位判定）",

    -- 失败状态
    STATUS_NODATA = "数据不可读",
    STATUS_PENDING = "查询中…",
    STATUS_FAR = "不可比较（距离过远或无法查看）",
    STATUS_TIMEOUT = "查询超时（服务端限频）",
    STATUS_COMBAT = "战斗中未查询",
    STATUS_BUSY = "成就窗口被占用",
    STATUS_NOAPI = "当前客户端缺少所需接口",
    STATUS_CANCELLED = "查询已取消",
    STATUS_FACTION = "敌方阵营（插件只对同阵营玩家生效）",
    STATUS_NONE = "无数据",

    -- 明细
    COUNT_LINE = "需求 %s · 贪婪 %s · 掷骰 %s · 副本 %s",
    COUNTS_CHAT = "需求 %s · 贪婪 %s · 副本 %s",
    RATE_LINE = "需求率 %d%%",
    CACHED_TAG = "缓存",
    AGE_TEXT = "%d 秒前",
    AGE_TEXT_MIN = "%d 分钟前",
    MISSING_FIELD = "（%s 不可读）",
    FIELD_NEED = "需求次数",
    FIELD_GREED = "贪婪次数",
    FIELD_DUNGEONS = "进本次数",

    -- 数据不完整：分层提示（缺哪一项 / 为什么 / 怎么办）
    NODATA_TITLE = "数据不完整：缺 %s",
    NODATA_DETAIL = "原因：%s · 建议：%s",
    REASON_UNREPORTED = "服务端未上报该统计项",
    REASON_RESTRICTED = "数值受保护，当前状态读不到",
    REASON_UNKNOWN = "返回值无法识别",
    REASON_FORMAT = "返回值格式异常",
    REASON_API = "客户端缺少该统计的读取接口",
    REASON_ERROR = "读取接口调用失败",
    HINT_NEED_UNREPORTED = "尚未掷过需求骰子，或服务端尚未同步",
    HINT_GREED_UNREPORTED = "尚未掷过贪婪骰子，或服务端尚未同步",
    HINT_DUNGEONS_UNREPORTED = "尚未进过 5 人地下城，或服务端尚未同步",
    HINT_RESTRICTED = "退出战斗或等加载结束后再试",
    HINT_GENERIC = "稍后重试，或用 /greed probe 查看原始返回值",
    VALUE_MISSING = "?",

    -- 队伍提示
    PARTY_NOTICE = "【贪婪镜】%s 需求率 %d%%（记录于 %s）",
    PARTY_NOTICE_SCREEN = "高需求率：%s（%d%%）",
    PARTY_NOTICE_DETAIL = "需求 %d · 贪婪 %d · 掷骰 %d · 副本 %d",

    -- 设置页
    SETTINGS_CATEGORY = "贪婪镜",
    SETTINGS_TITLE = "贪婪镜 %s",
    SETTINGS_OVERVIEW_HINT = "在插件列表左侧展开「贪婪镜」，可以进入两个子页：常用（开关与常规操作）、名单（高需求率名单）。",
    SETTINGS_OVERVIEW_COMMANDS = "命令：/greed self（自己）· /greed target [名字]（目标）· /greed party（扫描队伍）· /greed watch（查看名单）· /greed probe（自检）",
    BTN_OPEN_GENERAL = "打开常用设置",
    BTN_OPEN_WATCH = "打开名单",
    OPT_ENABLED = "启用插件",
    OPT_ENABLED_HINT = "关闭后插件完全不查询、不显示任何内容。",
    OPT_TOOLTIP = "鼠标提示框显示",
    OPT_TOOLTIP_HINT = "鼠标指向玩家时，在提示框追加需求率统计。",
    OPT_SELF = "显示自身数据",
    OPT_SELF_HINT = "鼠标指向自己时也显示统计。",
    OPT_DETAIL = "详细次数",
    OPT_DETAIL_HINT = "在提示框中额外显示需求/贪婪/掷骰/副本次数。",
    OPT_PARTY_ALERT = "队伍高需求率提示",
    OPT_PARTY_ALERT_HINT = "遇到名单中的高需求率玩家时，聊天框与屏幕中央给出仅自己可见的提醒。",
    OPT_INTERVAL = "查询间隔",
    OPT_INTERVAL_HINT = "每位玩家的统计结果单独缓存，到期后在你下次查看时刷新。",
    INTERVAL_REALTIME = "实时",
    INTERVAL_15 = "15 分钟",
    INTERVAL_30 = "30 分钟",
    INTERVAL_60 = "60 分钟",
    BTN_CLEAR_CACHE = "清除缓存",
    BTN_CLEAR_CACHE_HINT = "清空当前会话内所有玩家的统计缓存（下次查看时重新查询）。",
    BTN_CLEAR_WATCH = "清空高需求率名单",
    BTN_CLEAR_WATCH_HINT = "删除名单中的全部记录（需要再次点击确认）。",
    BTN_OPEN = "打开设置页",
    WATCH_TITLE = "高需求率名单（%d 条）",
    WATCH_EMPTY = "名单为空。",
    WATCH_ROW = "%s%s · %d%% · 需求 %d · 贪婪 %d · 记录于 %s",
    RACE_CLASS = "（%s）",
    TAB_GENERAL = "常用",
    TAB_WATCH = "名单",
    WATCH_LIST_HINT = "名单记录所有查询过、且需求率 ≥ 50% 的玩家；进入队伍或团队时会提示名单上的队友。",
    WATCH_SCROLL_HINT = "第 %d-%d / 共 %d 条 · 滚轮上下滚动",
    WATCH_LIST_ALL = "共 %d 条",
    PARTY_ROSTER_CHAT = "【贪婪镜】队伍中有高需求率玩家：%s",
    PARTY_ROSTER_SCREEN = "队伍高需求率：%s",
    CONFIRM = "再点一次确认",

    -- 斜杠命令
    CMD_HELP = "命令：/greed self | /greed target [名字] | /greed party | /greed watch | /greed probe | /greed settings | /greed cache",
    CMD_SELF = "正在读取自己的统计…",
    CMD_TARGET = "正在读取 %s 的统计…",
    CMD_TARGET_NONE = "鼠标没有指向玩家，或该目标不可比较。",
    CMD_TARGET_PARTY = "队伍中未找到名为 %s 的玩家。",
    CMD_PARTY_DONE = "队伍扫描完成：请求 %d 人，命中缓存 %d 人。",
    CMD_PARTY_NONE = "当前不在 5 人小队中。",
    CMD_WATCH_CLEARED = "已清空高需求率名单。",
    CMD_CACHE_CLEARED = "已清空统计缓存。",
    CMD_SELF_RESULT = "你的统计：%s → %s",
    CMD_TARGET_RESULT = "%s 的统计：%s → %s",
    CMD_PROBE_DONE = "自检输出见上（/greed probe）。",
    CMD_SETTINGS_HINT = "设置页可在“游戏 → 插件 → 贪婪镜”中打开。",
    CMD_SETTINGS_OPEN = "已打开设置页。",
    CMD_WATCH_ADDED = "已记录高需求率玩家 %s（%d%%）。",
    CMD_DISABLED = "贪婪镜已关闭。",
    CMD_ENABLED = "贪婪镜已开启。",

    -- 状态与摘要
    SUMMARY_NORMAL = "正常",
    SUMMARY_HIGH = "偏高",
    SUMMARY_VERY_HIGH = "极高",
    VALUE_UNKNOWN = "不可读",
    RATE_HIDDEN = "不显示",
    PROBE_TITLE = "贪婪镜 API 自检",
}

function I18n.T(key, ...)
    local text = I18n.zhCN[key]
    if text == nil then text = key end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
    end
    return text
end

-- 名单行里的「（种族 职业）」：只有一项时只显示那项，两项都缺时返回空串
-- （旧记录没有种族/职业字段时不会显示多余的括号）。
function I18n.RaceClassText(race, class)
    local parts = {}
    if type(race) == "string" and race ~= "" then parts[#parts + 1] = race end
    if type(class) == "string" and class ~= "" then parts[#parts + 1] = class end
    if #parts == 0 then return "" end
    return I18n.T("RACE_CLASS", table.concat(parts, " "))
end

-- 名单条目 → 一行展示文本。
-- 名单呈现的唯一格式化点：/greed watch（Core）与设置页名单（Settings）都用它，
-- 改列格式只需要改这一个函数。
function I18n.WatchRowText(entry)
    if type(entry) ~= "table" then return "" end
    local stamp = ""
    if type(entry.at) == "number" and date then stamp = date("%Y-%m-%d", entry.at) end
    return I18n.T("WATCH_ROW", tostring(entry.name or "?"),
        I18n.RaceClassText(entry.race, entry.class),
        entry.rate or 0, entry.need or 0, entry.greed or 0, stamp)
end
