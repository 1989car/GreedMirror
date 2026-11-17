-- GreedMirror 贪婪镜 - Tooltip.lua
-- 在鼠标提示框底部追加自己的两行文字，绝不改动原生行。
-- GameTooltip 会复用 FontString，所以必须同时校验“行号 + FontString 身份 + 文本”，
-- 否则会把别人的数据写进当前提示框。
local ADDON, GM = ...

local Tooltip = {}
GM.Tooltip = Tooltip
GM.Require("Tooltip", { "Stats", "Scan", "Rate", "DB", "I18n" })

local Stats, Scan, Rate, DB, I18n = GM.Stats, GM.Scan, GM.Rate, GM.DB, GM.I18n

local shown, drawing, installed = nil, false, false

local function safeText(fs)
    if not fs or type(fs.GetText) ~= "function" then return nil end
    local ok, text = pcall(fs.GetText, fs)
    if not ok or Stats.IsSecret(text) or type(text) ~= "string" then return nil end
    return text
end

local function equal(a, b)
    if Stats.IsSecret(a) or Stats.IsSecret(b) then return false end
    local ok, same = pcall(function() return a == b end)
    return ok and same == true
end

local function lineCount(tooltip)
    if not tooltip or type(tooltip.NumLines) ~= "function" then return nil end
    local ok, count = pcall(tooltip.NumLines, tooltip)
    if not ok or Stats.IsSecret(count) or type(count) ~= "number" then return nil end
    return count
end

-- 取第 index 行的左侧字体对象：优先用提示框自己的字段，找不到再退回全局名。
local function left(tooltip, index)
    if tooltip then
        local fs = tooltip["TextLeft" .. tostring(index)]
        if fs then return fs end
    end
    return _G["GameTooltipTextLeft" .. tostring(index)]
end

-- 当前提示框对应的单位。
-- 注意：本客户端的 GameTooltip:GetUnit() 返回的是角色名而不是单位 token，
-- 需要先按名字反查一次，否则永远拿不到单位，提示框里什么都不画。
local function tooltipUnit(tooltip)
    if not tooltip or type(tooltip.GetUnit) ~= "function" then return nil end
    local ok, a = pcall(tooltip.GetUnit, tooltip)
    if not ok or Stats.IsSecret(a) then return nil end
    if type(a) == "string" and a ~= "" then
        if Stats.PlayerGate(a) == "player" then return a end
        local token = Stats.ResolveUnitToken(a)
        if token and Stats.PlayerGate(token) == "player" then return token end
    end
    if Stats.PlayerGate("mouseover") == "player" then return "mouseover" end
    return nil
end

local function ownsRows(record)
    local count = record and lineCount(record.tooltip)
    if not count then return false end
    for _, row in ipairs(record.rows) do
        if row.index > count or left(record.tooltip, row.index) ~= row.fs or not equal(safeText(row.fs), row.text) then
            return false
        end
    end
    return true
end

local STATUS_KEYS = {
    PENDING = "STATUS_PENDING",
    FAR = "STATUS_FAR",
    TIMEOUT = "STATUS_TIMEOUT",
    COMBAT = "STATUS_COMBAT",
    BUSY = "STATUS_BUSY",
    NOAPI = "STATUS_NOAPI",
    NODATA = "STATUS_NODATA",
    HIDDEN = "STATUS_NONE",
    NPC = "STATUS_NONE",
    FACTION = "STATUS_FACTION",
    CANCELLED = "STATUS_CANCELLED",
}

local function colorOf(band)
    return GM.COLORS[band] or GM.COLORS.gray
end

-- 缺失字段 → 原因 / 建议（数据不可读时给出可操作的提示）
local FIELD_KEYS = {
    need = "FIELD_NEED",
    greed = "FIELD_GREED",
    dungeons = "FIELD_DUNGEONS",
}

local REASON_KEYS = {
    unreported = "REASON_UNREPORTED",
    restricted = "REASON_RESTRICTED",
    unknown = "REASON_UNKNOWN",
    format = "REASON_FORMAT",
    api = "REASON_API",
    error = "REASON_ERROR",
}

local HINT_UNREPORTED = {
    need = "HINT_NEED_UNREPORTED",
    greed = "HINT_GREED_UNREPORTED",
    dungeons = "HINT_DUNGEONS_UNREPORTED",
}

local HINT_BY_QUALITY = {
    restricted = "HINT_RESTRICTED",
}

local function appendUnique(list, text)
    if type(text) ~= "string" or text == "" then return end
    for _, item in ipairs(list) do
        if item == text then return end
    end
    list[#list + 1] = text
end

-- 汇总 row 里读不到的字段，以及每项的原因与建议。
-- quality 来自 Stats.ReadRow：readable | unreported | unknown | restricted | format | api | error
function Tooltip.MissingInfo(row)
    if type(row) ~= "table" then return nil end
    local info = { fields = {}, reasons = {}, hints = {} }
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        if not Stats.IsCount(row[field]) then
            local quality = (row.quality and row.quality[field]) or "unknown"
            local hintKey = HINT_UNREPORTED[field]
            if quality ~= "unreported" then hintKey = HINT_BY_QUALITY[quality] end
            appendUnique(info.fields, I18n.T(FIELD_KEYS[field]))
            appendUnique(info.reasons, I18n.T(REASON_KEYS[quality] or "REASON_UNKNOWN"))
            appendUnique(info.hints, I18n.T(hintKey or "HINT_GENERIC"))
        end
    end
    if #info.fields == 0 then return nil end
    return info
end

-- 第一行：缺哪一项
function Tooltip.NodataTitle(info)
    if type(info) ~= "table" or #info.fields == 0 then return I18n.T("STATUS_NODATA") end
    return string.format(I18n.T("NODATA_TITLE"), table.concat(info.fields, "、"))
end

-- 第二行：原因 + 建议（不受「详细次数」开关影响）
function Tooltip.NodataDetail(info)
    if type(info) ~= "table" or #info.fields == 0 then return nil end
    local reasons = table.concat(info.reasons, "；")
    local hints = table.concat(info.hints, "；")
    if reasons == "" and hints == "" then return nil end
    return string.format(I18n.T("NODATA_DETAIL"), reasons, hints)
end

-- 状态 → 中文短语（聊天输出与提示框共用）
function Tooltip.StatusText(status)
    return I18n.T(STATUS_KEYS[status] or "STATUS_NONE")
end

-- 判定结果 → 中文短语（聊天输出与提示框共用）
function Tooltip.VerdictText(result, row)
    if type(result) ~= "table" then return I18n.T("STATUS_NONE") end
    if result.status == "rated" then
        local word = Rate.SummaryWord(result)
        return string.format("%s %d%%", word, math.floor((result.ratio or 0) * 100 + 0.5))
    end
    if result.status == "small" then
        if result.ratio then
            return string.format("%s %d%%", I18n.T("VERDICT_SMALL"), math.floor(result.ratio * 100 + 0.5))
        end
        return I18n.T("VERDICT_SMALL")
    end
    if result.status == "low" then return I18n.T("VERDICT_LOW") end
    if result.status == "insufficient" then return I18n.T("VERDICT_INSUFFICIENT") end
    -- 数据不完整：说清楚缺哪一项
    local info = Tooltip.MissingInfo(row)
    if info then return Tooltip.NodataTitle(info) end
    return I18n.T("STATUS_NODATA")
end

local function ageText(seconds)
    if type(seconds) ~= "number" then return nil end
    if seconds < 60 then return string.format(I18n.T("AGE_TEXT"), math.floor(seconds)) end
    return string.format(I18n.T("AGE_TEXT_MIN"), math.floor(seconds / 60))
end

-- ------------------------------------------------------------ 聊天文本层
-- /greed self、/greed target（Core.lua reportRow）使用的文本接口。
-- “读不到的字段用 ? 占位，绝不用 0 冒充”的规则在这里与提示框共用同一份实现。

-- 计数摘要：需求 ? · 贪婪 12 · 副本 30
function Tooltip.CountsText(row)
    local function show(value)
        if Stats.IsCount(value) then return tostring(value) end
        return I18n.T("VALUE_MISSING")
    end
    if type(row) ~= "table" then row = {} end
    return string.format(I18n.T("COUNTS_CHAT"), show(row.need), show(row.greed), show(row.dungeons))
end

-- 判定短语（内部自行评估，调用方不需要再碰 Rate）
function Tooltip.ChatVerdict(row)
    return Tooltip.VerdictText(Rate.Evaluate(row), row)
end

-- 数据不可读时的第二行说明；数据完整时返回 nil
function Tooltip.NodataReport(row)
    local result = Rate.Evaluate(row)
    if result.status ~= "nodata" then return nil end
    return Tooltip.NodataDetail(Tooltip.MissingInfo(row))
end

-- 生成要追加的行：{ {text=..., color=...}, ... }
function Tooltip.BuildLines(row, result, guid)
    local lines = {}
    local detail = DB.Get("detail") == true
    if not row then return lines end

    if result.status == "rated" then
        local ratio = math.floor((result.ratio or 0) * 100 + 0.5)
        local word = Rate.SummaryWord(result)
        lines[#lines + 1] = { text = string.format("%s %d%% · %s", I18n.T("PLUGIN_NAME"), ratio, word),
            color = colorOf(result.band) }
    elseif result.status == "small" then
        local text = I18n.T("VERDICT_SMALL")
        if result.ratio then
            text = string.format("%s · %d%%", text, math.floor(result.ratio * 100 + 0.5))
        end
        lines[#lines + 1] = { text = text, color = colorOf("yellow") }
    elseif result.status == "low" then
        -- design.md：判为“低”（放弃型）后不计算需求率、也不给出任何提示，
        -- 因此悬停提示框里什么都不追加。
        return lines
    elseif result.status == "insufficient" then
        lines[#lines + 1] = { text = I18n.T("VERDICT_INSUFFICIENT"), color = colorOf("gray") }
    else
        -- 数据不完整：两行固定显示（缺哪一项 / 为什么 + 怎么办），不受「详细次数」开关影响
        local info = Tooltip.MissingInfo(row)
        lines[#lines + 1] = { text = Tooltip.NodataTitle(info), color = colorOf("gray") }
        local reason = Tooltip.NodataDetail(info)
        if reason then
            lines[#lines + 1] = { text = reason, color = colorOf("gray") }
        end
    end

    if detail then
        -- 读不到的字段用 ? 占位，绝不用 0 冒充（0 是有效数值，会误导）
        local function show(value)
            if Stats.IsCount(value) then return tostring(value) end
            return I18n.T("VALUE_MISSING")
        end
        local rolls = result.rolls
        if not Stats.IsCount(rolls) and Stats.IsCount(row.need) and Stats.IsCount(row.greed) then
            rolls = row.need + row.greed
        end
        lines[#lines + 1] = {
            text = string.format(I18n.T("COUNT_LINE"), show(row.need), show(row.greed),
                show(rolls), show(row.dungeons)),
            color = colorOf("gray"),
        }
    end

    local age = DB.CacheAge(guid)
    if age and DB.Interval() > 0 then
        lines[#lines + 1] = { text = string.format("%s · %s", I18n.T("CACHED_TAG"), ageText(age)),
            color = colorOf("gray") }
    end
    return lines
end

local function paint(tooltip, row, identity, status)
    if drawing or tooltip ~= GameTooltip or not identity then return end
    local record = shown
    local same = record and record.tooltip == tooltip and equal(record.guid, identity.guid)
    if record and not same then
        if ownsRows(record) then return end
        shown, record = nil, nil
    end
    if record and not ownsRows(record) then return end

    local lines = {}
    if row then
        lines = Tooltip.BuildLines(row, Rate.Evaluate(row), identity.guid)
    else
        local key = STATUS_KEYS[status] or "STATUS_NONE"
        lines = { { text = I18n.T(key), color = colorOf("gray") } }
    end

    drawing = true
    local ok = pcall(function()
        if not record then
            record = { tooltip = tooltip, guid = identity.guid, identity = identity, rows = {} }
        end
        for i = 1, math.max(#lines, #record.rows) do
            local line = lines[i]
            local owned = record.rows[i]
            if line then
                local text = line.text
                local color = line.color or colorOf("gray")
                if owned then
                    owned.fs:SetText(text)
                    owned.fs:SetTextColor(color[1], color[2], color[3])
                    owned.fs:Show()
                    owned.text = text
                else
                    local count = lineCount(tooltip)
                    if not count then error("tooltip line count unavailable") end
                    tooltip:AddLine(text, color[1], color[2], color[3], true)
                    record.rows[i] = { index = count + 1, fs = left(tooltip, count + 1), text = text }
                end
            elseif owned then
                -- 这次不需要这么多行：把多出来的旧行清空并隐藏。
                owned.text = ""
                owned.fs:SetText("")
                if type(owned.fs.Hide) == "function" then owned.fs:Hide() end
            end
        end
        record.status = row and "READY" or status
        record.row = row
        record.identity = identity
        shown = record
        if type(tooltip.Show) == "function" then tooltip:Show() end
    end)
    drawing = false
    if not ok then shown = nil end
end

function Tooltip.Paint(tooltip, row, identity)
    paint(tooltip, row, identity, "READY")
end

function Tooltip.PaintStatus(tooltip, status, identity)
    paint(tooltip, nil, identity, status)
end

-- 刷新单入口：扫描结果（OnReady）与看门狗（watchdog）都走这里。
-- 按 shown 记录重新解析当前提示框对应的单位，再重画；
-- 目标已变化、提示框已隐藏等情况都直接跳过。
function Tooltip.Refresh(guid, row, status)
    if drawing or not shown or Stats.IsSecret(guid) or not equal(shown.guid, guid) then return end
    local tooltip = shown.tooltip
    local ok, visible = Stats.SafeCall(tooltip.IsShown, tooltip)
    if not ok or not visible then return end
    local unit = tooltipUnit(tooltip)
    if not unit then return end
    local identity = Stats.UnitIdentity(unit)
    if not identity or not equal(identity.guid, guid) then return end
    paint(tooltip, row, identity, status)
end

function Tooltip.OnUnit(tooltip)
    if drawing or tooltip ~= GameTooltip then return end
    if not GM.IsEnabled() then return end
    if DB.Get("tooltip") ~= true then return end

    local unit = tooltipUnit(tooltip)
    if not unit then
        shown = nil
        return
    end
    local identity = Stats.UnitIdentity(unit)
    if not identity then
        shown = nil
        return
    end

    if shown and shown.guid and not equal(shown.guid, identity.guid) then
        Scan.CancelHover() -- 快速切换目标：丢弃上一个未完成的悬停请求
    end

    if identity.isSelf then
        if DB.Get("selfTooltip") ~= true then return end
        local row = Stats.SelfRow()
        if row then
            paint(tooltip, row, identity, "READY")
        else
            paint(tooltip, nil, identity, "NODATA")
        end
        return
    end

    local row, status = Scan.Request(unit, { front = true })
    if row then
        paint(tooltip, row, identity)
    elseif status then
        paint(tooltip, nil, identity, status)
    end
end

function Tooltip.Init()
    if installed then return end
    installed = true
    Scan.OnReady(Tooltip.Refresh)

    if GameTooltip and type(GameTooltip.HookScript) == "function" then
        -- 热加载时上一份模块可能已经挂过钩子，先摘掉，避免同一个提示框被画两遍
        if GM.tooltipHook and type(GameTooltip.UnhookScript) == "function" then
            pcall(GameTooltip.UnhookScript, GameTooltip, "OnTooltipSetUnit", GM.tooltipHook)
        end
        pcall(GameTooltip.HookScript, GameTooltip, "OnHide", function() shown = nil end)
        pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipCleared", function() shown = nil end)

        -- 1) 首选 TooltipDataProcessor：提示框内容生成完之后再追加，最稳。
        --    无限（camelot）等客户端的 GameTooltip 没有 OnTooltipSetUnit 这个脚本，
        --    只有这条路径能在提示框真正显示之后补上我们的行。
        if TooltipDataProcessor and type(TooltipDataProcessor.AddTooltipPostCall) == "function" then
            local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, GameTooltip, function(tooltip)
                Tooltip.OnUnit(tooltip)
            end)
            if ok then
                Tooltip.mode = "postcall"
            end
        end
    end

    -- 2) 兼容支持 OnTooltipSetUnit 的客户端
    if not Tooltip.mode and GameTooltip and type(GameTooltip.HookScript) == "function" then
        local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", Tooltip.OnUnit)
        if ok then
            GM.tooltipHook = Tooltip.OnUnit
            Tooltip.mode = "script"
        end
    end

    -- 3) 兜底：提示框显示 / 刷新时补画
    if not Tooltip.mode and GameTooltip and type(GameTooltip.HookScript) == "function" then
        pcall(GameTooltip.HookScript, GameTooltip, "OnShow", function()
            if GameTooltip and GameTooltip:IsShown() then Tooltip.OnUnit(GameTooltip) end
        end)
        pcall(GameTooltip.HookScript, GameTooltip, "OnUpdate", function()
            if GameTooltip and GameTooltip:IsShown() then Tooltip.OnUnit(GameTooltip) end
        end)
        Tooltip.mode = "event"
    end

    -- 4) 看门狗：提示框正显示、但当前单位还没画过（或我们画的行被游戏清掉了）时补画一次。
    --    有些客户端的提示框既没有 OnTooltipSetUnit 脚本，也不走 TooltipDataProcessor，
    --    只能靠轮询兜底（每 0.5 秒一次，开销极小）。
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        local function rowsAlive(record)
            local rows = record and record.rows
            if not rows or #rows == 0 then return true end
            local first = rows[1]
            if not first or not first.fs or type(first.fs.GetText) ~= "function" then return true end
            local ok, current = pcall(first.fs.GetText, first.fs)
            if not ok then return false end
            return current == first.text
        end
        local function watchdog()
            if not GM.IsEnabled() or DB.Get("tooltip") ~= true then return end
            if not GameTooltip or not GameTooltip:IsShown() then return end
            if shown and rowsAlive(shown) then return end
            -- 还没画过（或我们画的行被游戏清掉了）：交给唯一入口 OnUnit 重画。
            -- 看门狗不再自己解析单位/身份，画与不画的判断只有 OnUnit 一份。
            Tooltip.OnUnit(GameTooltip)
        end
        local function loop()
            watchdog()
            C_Timer.After(0.5, loop)
        end
        C_Timer.After(0.5, loop)
    end
end
