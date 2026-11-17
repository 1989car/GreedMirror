-- GreedMirror 贪婪镜 - Core.lua
-- 命名空间、常量、生命周期与斜杠命令入口。
local ADDON, GM = ...

GM.ADDON = ADDON or "GreedMirror"
GM.VERSION = "1.0.0"

-- 显式依赖契约：模块加载顺序由 GreedMirror.toc 保证，违反契约时在加载期直接报错，
-- 而不是等运行期某个 GM.X 为 nil 才在玩家面前炸出来。
function GM.Require(name, deps)
    for _, dep in ipairs(deps or {}) do
        if not GM[dep] then
            error(string.format("GreedMirror: 模块 %s 缺少依赖 %s（请检查 GreedMirror.toc 的加载顺序）",
                tostring(name), tostring(dep)), 0)
        end
    end
    return GM
end

-- 三个统计项（暴雪成就/统计 ID，见 /greed probe 自检）
GM.STAT = { need = 1044, greed = 1043, dungeons = 932 }
GM.STAT_RESOLVED = nil   -- 运行时自检/自动发现后的实际 ID

-- 判定阈值（与 design.md 一致）
GM.RULE = {
    activeMul = 5.4,
    minDungeons = 4,
    minRolls = 20,
    redRolls = 30,
    darkGreenBelow = 0.10,
    greenBelow = 0.30,
    yellowBelow = 0.50,
}

-- 查询间隔档位（秒）
GM.INTERVALS = {
    { value = 0, key = "INTERVAL_REALTIME" },
    { value = 900, key = "INTERVAL_15" },
    { value = 1800, key = "INTERVAL_30" },
    { value = 3600, key = "INTERVAL_60" },
}

-- 扫描节流参数
GM.SCAN = {
    floor = 1.2,        -- 两次 SetAchievementComparisonUnit 的最小间隔（秒）
    debounce = 0.35,    -- 悬停请求的防抖
    hoverTimeout = 4.0, -- 悬停请求超时
    manualTimeout = 8.0,-- 手动请求超时
    farTTL = 30,        -- 比较失败（距离过远）后的冷却
    queueMax = 40,      -- 队列上限
}

GM.COLORS = {
    darkgreen = { 0.00, 0.55, 0.25 },
    green = { 0.25, 0.85, 0.35 },
    yellow = { 1.00, 0.82, 0.00 },
    red = { 1.00, 0.25, 0.25 },
    gray = { 0.72, 0.72, 0.72 },
}

function GM.Print(message)
    print("|cff1eff00贪婪镜|r " .. tostring(message))
end

function GM.IsEnabled()
    return GM.DB and GM.DB.Get("enabled") == true
end

-- ------------------------------------------------------------ 生命周期

local frame = CreateFrame("Frame")
GM.frame = frame

-- 注册事件必须容错：无限（camelot）等客户端没有 ADDON_ENABLED / ADDON_DISABLED，
-- RegisterEvent 遇到未知事件会直接抛错并中断整个文件，
-- 那样 OnEvent 脚本与斜杠命令都注册不上，插件表现为“完全没启动”。
local function safeRegister(event)
    return pcall(frame.RegisterEvent, frame, event)
end

safeRegister("ADDON_LOADED")
safeRegister("ADDON_ENABLED")
safeRegister("ADDON_DISABLED")
safeRegister("PLAYER_LOGIN")

-- 斜杠命令与扫描回调共用的局部状态（先声明，后面再定义实现）
local reportRow
local pendingTarget = nil

-- 扫描结果回调（Core 只保留命令回显这一件事）：
--   1) 名单入库与组队提醒 → Party.OnScanResult（业务策略在 Party）
--   2) /greed target 的查询结果回显 → reportRow（展示在 Tooltip 的文本层）
local function onScanResult(guid, row, status)
    if GM.Party and GM.Party.OnScanResult then
        GM.Party.OnScanResult(guid, row, status)
    end

    if pendingTarget and guid and guid == pendingTarget.guid then
        local name = pendingTarget.name
        pendingTarget = nil
        if row then
            reportRow(row, GM.I18n.T("CMD_TARGET_RESULT"), name)
        else
            GM.Print(GM.Tooltip.StatusText(status))
        end
    end
end

local function setup()
    -- 热加载时文件是逐个执行的，setup() 可能早于其它模块加载完成；
    -- 此时直接返回，等下一次调用（ADDON_LOADED / PLAYER_LOGIN / 定时重试）再初始化。
    if not GM.I18n or not GM.DB then return end
    -- 同一套模块只初始化一次。热加载会把模块表换成新的（GM.DB 变成另一张表），
    -- 用模块身份判断新旧，热加载后新的模块仍会被正确初始化。
    if GM.setupOwner == GM.DB then return end
    GM.setupOwner = GM.DB
    GM.initialized = true
    if GM.DB and GM.DB.Init then GM.DB.Init() end
    if GM.Settings and GM.Settings.Init then GM.Settings.Init() end
    if GM.Scan and GM.Scan.Init then GM.Scan.Init() end
    if GM.Tooltip and GM.Tooltip.Init then GM.Tooltip.Init() end
    if GM.Party and GM.Party.Init then GM.Party.Init() end
    if GM.Probe and GM.Probe.Init then GM.Probe.Init() end
    if GM.Scan and GM.Scan.OnReady then GM.Scan.OnReady(onScanResult) end
    GM.Print(GM.I18n.T("PLUGIN_NAME") .. " " .. GM.VERSION .. " 已加载。" .. GM.I18n.T("CMD_HELP"))
end

frame:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" then
        if addon == GM.ADDON then setup() end
        return
    end
    if event == "ADDON_ENABLED" then
        if addon == GM.ADDON then setup() end
        return
    end
    if event == "ADDON_DISABLED" then
        if addon == GM.ADDON then
            if GM.Scan and GM.Scan.Cancel then GM.Scan.Cancel("CANCELLED") end
            if GM.DB then GM.DB.ClearCache() end
            GM.Print(GM.I18n.T("CMD_DISABLED"))
        end
        return
    end
    if event == "PLAYER_LOGIN" then setup() end
end)

-- 兜底：如果插件文件是在登录之后才被载入（例如热加载），ADDON_LOADED / PLAYER_LOGIN
-- 都已经触发过，不会再补发一次，此时直接初始化，避免插件“加载了却没启动”。
-- 必须延后并重试：热加载是逐个文件执行的，此刻 I18n/DB 等模块可能还没加载完，
-- 立刻 setup() 会因 GM.I18n 为 nil 报错，还会把 Core.lua 剩下的代码
-- （斜杠命令注册）一起中断，表现为“插件完全没启动”。
local function setupWhenReady(attempts)
    -- 每轮都尝试 setup()：setup() 内部用「模块身份」判断是否已经初始化过，
    -- 因此热加载时新模块替换旧模块后，这里会自动再初始化一次。
    if GM.I18n and GM.DB then
        setup()
    end
    if attempts <= 0 then return end
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0.2, function() setupWhenReady(attempts - 1) end)
    end
end

if type(IsLoggedIn) == "function" and IsLoggedIn() then
    -- 120 × 0.2 秒 ≈ 24 秒，覆盖热加载逐文件发送的时间
    setupWhenReady(120)
end

-- ------------------------------------------------------------ 斜杠命令

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function targetUnit()
    local unit = "mouseover"
    if UnitExists and UnitExists(unit) and UnitIsPlayer and UnitIsPlayer(unit) then
        return unit
    end
    if UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target") then
        return "target"
    end
    return nil
end

local function partyUnitByName(name)
    local lowered = string.lower(name)
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local ok, unitName = pcall(UnitName, unit)
            if ok and type(unitName) == "string" and string.lower(unitName) == lowered then
                return unit
            end
        end
    end
    return nil
end

-- 聊天输出只有排版：计数与判定文案全部来自 Tooltip 的文本层
-- （“读不到用 ? 占位”“数据不完整分层提示”的规则在 Tooltip 里只写一遍）。
reportRow = function(row, prefix, name)
    local counts = GM.Tooltip.CountsText(row)
    local verdict = GM.Tooltip.ChatVerdict(row)
    if name then
        GM.Print(string.format(prefix, name, counts, verdict))
    else
        GM.Print(string.format(prefix, counts, verdict))
    end
    local detail = GM.Tooltip.NodataReport(row)
    if detail then GM.Print(detail) end
end

local function handleCommand(text)
    local command, rest = text:match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    rest = trim(rest)

    if command == "" then
        GM.Print(GM.I18n.T("CMD_HELP"))
        return
    end

    if command == "self" then
        local row = GM.Stats.SelfRow()
        if not row then
            GM.Print(GM.I18n.T("STATUS_NONE"))
            return
        end
        GM.Print(GM.I18n.T("CMD_SELF"))
        reportRow(row, GM.I18n.T("CMD_SELF_RESULT"))
        return
    end

    if command == "target" then
        local unit, name = targetUnit(), nil
        if rest ~= "" then
            unit = partyUnitByName(rest)
            if not unit then
                GM.Print(GM.I18n.T("CMD_TARGET_PARTY", rest))
                return
            end
        end
        if not unit then
            GM.Print(GM.I18n.T("CMD_TARGET_NONE"))
            return
        end
        local identity = GM.Stats.UnitIdentity(unit)
        if not identity then
            -- 对立阵营玩家：插件不适用，直接说明原因而不是「没有指向玩家」
            if GM.Stats.PlayerGate(unit) == "player"
                and GM.Stats.FactionRelation(unit) == "hostile" then
                GM.Print(GM.I18n.T("STATUS_FACTION"))
            else
                GM.Print(GM.I18n.T("CMD_TARGET_NONE"))
            end
            return
        end
        name = identity.name
        GM.Print(GM.I18n.T("CMD_TARGET", name))
        pendingTarget = nil
        if type(identity.guid) == "string" then
            pendingTarget = { guid = identity.guid, name = name }
        end
        local row, status = GM.Scan.Request(unit, { manual = true, front = true })
        if row then
            -- 命中缓存：立刻输出
            pendingTarget = nil
            reportRow(row, GM.I18n.T("CMD_TARGET_RESULT"), name)
        elseif status and status ~= "PENDING" then
            -- 查询当场失败：输出状态
            pendingTarget = nil
            GM.Print(GM.Tooltip.StatusText(status))
        end
        -- PENDING：结果到达时由 onScanResult 回显
        return
    end

    if command == "party" then
        local requested, ready = GM.Scan.ScanParty(true)
        GM.Print(GM.I18n.T("CMD_PARTY_DONE", requested, ready))
        return
    end

    if command == "watch" then
        if rest == "clear" then
            GM.DB.WatchClear()
            GM.Print(GM.I18n.T("CMD_WATCH_CLEARED"))
            return
        end
        local list = GM.DB.WatchList()
        GM.Print(GM.I18n.T("WATCH_TITLE", #list))
        if #list == 0 then
            GM.Print(GM.I18n.T("WATCH_EMPTY"))
            return
        end
        for _, entry in ipairs(list) do
            GM.Print(GM.I18n.WatchRowText(entry))
        end
        return
    end

    if command == "probe" then
        if GM.Probe then GM.Probe.Run() end
        return
    end

    if command == "settings" then
        if GM.Settings and GM.Settings.Open then
            GM.Settings.Open()
            GM.Print(GM.I18n.T("CMD_SETTINGS_OPEN"))
        else
            GM.Print(GM.I18n.T("CMD_SETTINGS_HINT"))
        end
        return
    end

    if command == "cache" then
        GM.DB.ClearCache()
        GM.Print(GM.I18n.T("CMD_CACHE_CLEARED"))
        return
    end

    GM.Print(GM.I18n.T("CMD_HELP"))
end

SLASH_GREEDMIRROR1 = "/greed"
SLASH_GREEDMIRROR2 = "/贪婪镜"
SlashCmdList.GREEDMIRROR = function(text)
    handleCommand(text or "")
end
