-- GreedMirror 贪婪镜 - Party.lua
-- 记录需求率极高的玩家，并在队伍里再次遇到该玩家时给出
-- “只有自己可见”的提醒（聊天框一行 + 屏幕中央一��）。
-- 不使用任何聊天频道发送，因此不会广播给其他人。
local ADDON, GM = ...

local Party = {}
GM.Party = Party
GM.Require("Party", { "DB", "I18n", "Rate" })

local DB, I18n, Rate = GM.DB, GM.I18n, GM.Rate

local NOTICE_COOLDOWN = 600 -- 同一玩家 10 分钟内不重复提醒
local notified = {}
local noticeFrame, noticeText, noticeUntil = nil, nil, 0

local function ensureNoticeFrame()
    if noticeFrame then return end
    noticeFrame = CreateFrame("Frame", nil, UIParent)
    noticeFrame:SetSize(760, 120)
    noticeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    noticeFrame:SetFrameStrata("HIGH")
    noticeFrame:Hide()
    noticeText = noticeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    noticeText:SetPoint("CENTER", noticeFrame, "CENTER")
    noticeText:SetTextColor(1.0, 0.25, 0.25)
end

local function showScreenNotice(text)
    ensureNoticeFrame()
    noticeText:SetText(text)
    noticeFrame:Show()
    noticeUntil = (GetTime and GetTime() or 0) + 4
    noticeFrame:SetScript("OnUpdate", function(self)
        if (GetTime and GetTime() or 0) >= noticeUntil then
            self:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

local function dateText(timestamp)
    if type(timestamp) ~= "number" then return "" end
    if date then return date("%Y-%m-%d", timestamp) end
    return tostring(timestamp)
end

-- 聊天框提醒：只用 print，只写入自己的聊天记录。
function Party.Notify(entry)
    if type(entry) ~= "table" then return end
    local now = time and time() or 0
    if notified[entry.guid] and (now - notified[entry.guid]) < NOTICE_COOLDOWN then return end
    notified[entry.guid] = now

    local name = tostring(entry.name or "?")
    local rate = math.floor((entry.rate or 0) + 0.5)
    print(string.format(I18n.T("PARTY_NOTICE"), name, rate, dateText(entry.at)))
    showScreenNotice(string.format(I18n.T("PARTY_NOTICE_SCREEN"), name, rate))
end

-- 判定为极高时写入名单（跨会话保留）。
-- 只做入库，返回 entry, isFirst；是否提示、何时提示由 OnScanResult 决定。
function Party.Record(guid, identity, row, result)
    if not Rate.IsHighRate(result) then return nil, false end
    local existing = DB.WatchGet(guid)
    local entry = {
        guid = guid,
        name = (identity and identity.name) or (existing and existing.name) or "?",
        realm = (identity and identity.realm) or (existing and existing.realm),
        race = (row and row.race) or (existing and existing.race),
        class = (row and row.class) or (existing and existing.class),
        rate = math.floor((result.ratio or 0) * 100 + 0.5),
        need = row.need,
        greed = row.greed,
        rolls = result.rolls,
        dungeons = row.dungeons,
        at = time and time() or 0,
    }
    DB.WatchPut(guid, entry)
    return entry, existing == nil
end

-- 扫描结果 → 名单策略（唯一入口，Core 的扫描回调只转发到这里）：
--   1) 需求率极高 → 入库；
--   2) 首次进入名单 → 聊天提示一次（避免每次悬停刷屏）；
--   3) 开着队伍提醒且该玩家在队伍里 → Notify（自带 10 分钟冷却）。
function Party.OnScanResult(guid, row, status)
    if status ~= "READY" or type(row) ~= "table" or type(guid) ~= "string" then return end
    local result = Rate.Evaluate(row)
    local entry, isFirst = Party.Record(guid, { name = row.name, realm = row.realm }, row, result)
    if not entry then return end
    if isFirst then
        GM.Print(I18n.T("CMD_WATCH_ADDED", entry.name, entry.rate))
    end
    if DB.Get("partyAlert") == true and Party.IsInGroup(entry.guid) then
        Party.Notify(entry)
    end
end

function Party.IsInGroup(guid)
    if type(guid) ~= "string" then return false end
    for _, unit in ipairs(Party.GroupUnits()) do
        local ok, unitGuid = pcall(UnitGUID, unit)
        if ok and type(unitGuid) == "string" and unitGuid == guid then return true end
    end
    return false
end

function Party.GroupUnits()
    local units = {}
    local inRaid = type(IsInRaid) == "function" and IsInRaid() and true or false
    if inRaid then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    return units
end

-- 扫描队伍/团队名单：命中“高需求率名单”时**一次性汇总**提醒
-- （进入队伍/团队时最关心的是“队里有谁需求率极高”，而不是被逐个刷屏）。
function Party.CheckRoster()
    if not GM.IsEnabled() then return end
    if DB.Get("partyAlert") ~= true then return end
    local now = time and time() or 0
    local matches = {}
    for _, unit in ipairs(Party.GroupUnits()) do
        local ok, guid = pcall(UnitGUID, unit)
        if ok and type(guid) == "string" and guid ~= "" then
            local entry = DB.WatchGet(guid)
            -- 同一玩家 10 分钟内不重复提醒
            if entry and (not notified[guid] or (now - notified[guid]) >= NOTICE_COOLDOWN) then
                matches[#matches + 1] = entry
            end
        end
    end
    if #matches == 0 then return end

    local chatParts, screenParts = {}, {}
    for _, entry in ipairs(matches) do
        local name = tostring(entry.name or "?")
        local rate = math.floor((entry.rate or 0) + 0.5)
        chatParts[#chatParts + 1] = string.format("%s(%d%%)", name, rate)
        screenParts[#screenParts + 1] = string.format("%s %d%%", name, rate)
        notified[entry.guid] = now
    end
    print(string.format(I18n.T("PARTY_ROSTER_CHAT"), table.concat(chatParts, "、")))
    showScreenNotice(string.format(I18n.T("PARTY_ROSTER_SCREEN"), table.concat(screenParts, " · ")))
end

local frame = CreateFrame("Frame")
GM.partyFrame = frame

function Party.Init()
    -- 队伍事件名各客户端不同：无限（camelot）只有 GROUP_ROSTER_UPDATE / GROUP_JOINED /
    -- GROUP_FORMED / GROUP_LEFT，零售端才叫 GROUP_JOINED_GROUP / LEAVE_GROUP。
    -- 未知事件注册会抛错，所以一律用 pcall 包住，取不到的就跳过。
    local function safeRegister(event)
        return pcall(frame.RegisterEvent, frame, event)
    end
    safeRegister("GROUP_ROSTER_UPDATE")
    safeRegister("GROUP_JOINED")
    safeRegister("GROUP_FORMED")
    safeRegister("GROUP_LEFT")
    safeRegister("GROUP_JOINED_GROUP")
    safeRegister("LEAVE_GROUP")
    frame:SetScript("OnEvent", function()
        Party.CheckRoster()
    end)
end
