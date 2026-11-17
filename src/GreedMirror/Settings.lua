-- GreedMirror 贪婪镜 - Settings.lua
-- 设置页采用 Blizzard 原生的「插件 → 子面板」结构（与 TotemTimers 一致）：
--   游戏 → 插件 → 贪婪镜（父分类，列表行左侧出现 ＋/－ 展开钮）
--       ├─ 常用
--       └─ 名单
-- 三个画布各是一个 Frame：Blizzard 设置面板激活分类时会
--   frame:SetParent(settingsCanvas); frame:ClearAllPoints(); frame:SetAllPoints(settingsCanvas); frame:Show()
-- 所以画布本身不预设锚点（也不预设尺寸），内容一律相对画布左上角定位。
-- 注册顺序：父分类 RegisterCanvasLayoutCategory + RegisterAddOnCategory，
--           再用父分类对象 RegisterCanvasLayoutSubcategory 注册两个子分类。
-- 若现代 API 不可用，依次退回旧版 InterfaceOptions_AddCategory、/greed settings 自绘面板。
local ADDON, GM = ...

local Settings = {}
GM.Settings = Settings

local DB, I18n = GM.DB, GM.I18n

local overviewFrame = nil      -- 父分类画布（总览）
local generalFrame = nil       -- 子分类画布（常用）
local watchFrame = nil         -- 子分类画布（名单）
local checks = {}
local intervalButton = nil
local watchButton = nil
local cacheButton = nil
local category = nil           -- 父分类对象
local generalCategory = nil    -- 常用子分类对象
local watchCategory = nil      -- 名单子分类对象
local legacy = false
local watchTitle = nil
local watchEmpty = nil
local watchScrollHint = nil
local watchRows = {}
local watchScroll = 0
local WATCH_ROW_COUNT = 8
local FALLBACK_WIDTH = 620
local FALLBACK_HEIGHT = 470

local function label(parent, text, x, y, width, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    if width then fs:SetWidth(width) end
    return fs
end

local function hint(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    if width then fs:SetWidth(width) end
    return fs
end

local function button(parent, text, x, y, width, onClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 140, 24)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    btn:SetText(text)
    if onClick then btn:SetScript("OnClick", onClick) end
    return btn
end

local function makeCheck(parent, key, title, hintText, top)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, top)
    local fs = label(parent, title, 46, top + 1, 540)
    local hs = hint(parent, hintText, 46, top - 17, 540)
    check:SetScript("OnClick", function(self)
        DB.Set(key, self:GetChecked() == true)
        Settings.Refresh()
    end)
    checks[key] = { check = check, title = fs, hint = hs }
    return check
end

local function intervalLabel()
    local seconds = DB.Interval()
    for _, entry in ipairs(GM.INTERVALS) do
        if entry.value == seconds then return I18n.T(entry.key) end
    end
    return I18n.T("INTERVAL_60")
end

-- ------------------------------------------------------------ 名单列表

local function watchEntryText(entry)
    local stamp = ""
    if type(entry.at) == "number" and date then stamp = date("%Y-%m-%d", entry.at) end
    return I18n.T("WATCH_ROW", tostring(entry.name or "?"),
        I18n.RaceClassText(entry.race, entry.class),
        entry.rate or 0, entry.need or 0, entry.greed or 0, stamp)
end

-- 重画名单：每次滚动、刷新、增删记录后都调用
local function renderWatchList()
    local list = DB.WatchList()
    local total = #list
    local maxScroll = total - WATCH_ROW_COUNT
    if maxScroll < 0 then maxScroll = 0 end
    if watchScroll < 0 then watchScroll = 0 end
    if watchScroll > maxScroll then watchScroll = maxScroll end

    for i = 1, WATCH_ROW_COUNT do
        local fs = watchRows[i]
        if fs then
            local entry = list[watchScroll + i]
            if entry then
                fs:SetText(watchEntryText(entry))
            else
                fs:SetText("")
            end
        end
    end

    if watchTitle then watchTitle:SetText(I18n.T("WATCH_TITLE", total)) end
    if watchEmpty then watchEmpty:SetShown(total == 0) end
    if watchScrollHint then
        if total == 0 then
            watchScrollHint:SetText("")
        elseif total <= WATCH_ROW_COUNT then
            watchScrollHint:SetText(I18n.T("WATCH_LIST_ALL", total))
        else
            watchScrollHint:SetText(I18n.T("WATCH_SCROLL_HINT", watchScroll + 1,
                math.min(total, watchScroll + WATCH_ROW_COUNT), total))
        end
    end
end

-- 滚轮翻动（delta > 0 向上，delta < 0 向下）
local function scrollWatchList(delta)
    local total = #DB.WatchList()
    local maxScroll = total - WATCH_ROW_COUNT
    if maxScroll < 0 then maxScroll = 0 end
    if delta > 0 then
        watchScroll = watchScroll - 1
    elseif delta < 0 then
        watchScroll = watchScroll + 1
    end
    if watchScroll < 0 then watchScroll = 0 end
    if watchScroll > maxScroll then watchScroll = maxScroll end
    renderWatchList()
end

-- 对外暴露：滚动名单（排障脚本可直接调用）
Settings.ScrollWatch = scrollWatchList
_G.GreedMirrorSettings = Settings

-- ------------------------------------------------------------ 刷新

function Settings.Refresh()
    for key, entry in pairs(checks) do
        entry.check:SetChecked(DB.Get(key) == true)
    end
    if intervalButton then
        intervalButton:SetText(I18n.T("OPT_INTERVAL") .. "：" .. intervalLabel())
    end
    if watchButton then
        watchButton:SetText(I18n.T("BTN_CLEAR_WATCH") .. "（" .. DB.WatchCount() .. "）")
    end
    if cacheButton then
        cacheButton:SetText(I18n.T("BTN_CLEAR_CACHE") .. "（" .. DB.CacheCount() .. "）")
    end
    renderWatchList()
end

local function cycleInterval()
    local current = DB.Interval()
    local index = 1
    for i, entry in ipairs(GM.INTERVALS) do
        if entry.value == current then
            index = i
            break
        end
    end
    local next = GM.INTERVALS[(index % #GM.INTERVALS) + 1]
    DB.Set("interval", next.value)
    Settings.Refresh()
end

-- ------------------------------------------------------------ 页面构建

local function buildOverview(parent)
    label(parent, I18n.T("SETTINGS_TITLE", GM.VERSION), 16, -16, 560, "GameFontNormalLarge")
    hint(parent, I18n.T("SETTINGS_OVERVIEW_HINT"), 16, -50, 580)
    hint(parent, I18n.T("SETTINGS_OVERVIEW_COMMANDS"), 16, -96, 580)

    button(parent, I18n.T("BTN_OPEN_GENERAL"), 16, -136, 160, function() Settings.OpenPage("general") end)
    button(parent, I18n.T("BTN_OPEN_WATCH"), 188, -136, 160, function() Settings.OpenPage("watch") end)
end

local function buildGeneral(parent)
    -- 画布顶部已经有暴雪画的分类名（常用），这里不再重复画标题

    makeCheck(parent, "enabled", I18n.T("OPT_ENABLED"), I18n.T("OPT_ENABLED_HINT"), -84)
    makeCheck(parent, "tooltip", I18n.T("OPT_TOOLTIP"), I18n.T("OPT_TOOLTIP_HINT"), -124)
    makeCheck(parent, "selfTooltip", I18n.T("OPT_SELF"), I18n.T("OPT_SELF_HINT"), -164)
    makeCheck(parent, "detail", I18n.T("OPT_DETAIL"), I18n.T("OPT_DETAIL_HINT"), -204)
    makeCheck(parent, "partyAlert", I18n.T("OPT_PARTY_ALERT"), I18n.T("OPT_PARTY_ALERT_HINT"), -244)

    intervalButton = button(parent, "", 16, -288, 240, cycleInterval)
    hint(parent, I18n.T("OPT_INTERVAL_HINT"), 16, -318, 580)

    cacheButton = button(parent, I18n.T("BTN_CLEAR_CACHE"), 16, -352, 240, function(self)
        DB.ClearCache()
        self:SetText(I18n.T("BTN_CLEAR_CACHE") .. "（" .. DB.CacheCount() .. "）")
    end)
    hint(parent, I18n.T("BTN_CLEAR_CACHE_HINT"), 16, -382, 580)
end

local function buildWatch(parent)
    -- 画布顶部已经有暴雪画的分类名（名单），这里不再重复画标题

    watchTitle = label(parent, "", 16, -56, 560, "GameFontNormal")
    hint(parent, I18n.T("WATCH_LIST_HINT"), 16, -78, 580)

    local watchConfirmAt = 0
    watchButton = button(parent, I18n.T("BTN_CLEAR_WATCH"), 16, -108, 240, function(self)
        local now = time and time() or 0
        if now > watchConfirmAt then
            watchConfirmAt = now + 5
            self:SetText(I18n.T("CONFIRM"))
            return
        end
        watchConfirmAt = 0
        DB.WatchClear()
        watchScroll = 0
        self:SetText(I18n.T("BTN_CLEAR_WATCH") .. "（" .. DB.WatchCount() .. "）")
        renderWatchList()
    end)
    hint(parent, I18n.T("BTN_CLEAR_WATCH_HINT"), 16, -138, 580)

    -- 列表区域：透明 frame 接收滚轮（本客户端没有可用的滚动条模板）
    local scrollArea = CreateFrame("Frame", nil, parent)
    scrollArea:SetSize(588, 160)
    scrollArea:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -152)
    scrollArea:EnableMouse(true)
    scrollArea:EnableMouseWheel(true)
    scrollArea:SetScript("OnMouseWheel", function(_, delta) scrollWatchList(delta or 0) end)

    watchEmpty = label(parent, I18n.T("WATCH_EMPTY"), 16, -162, 560)

    for i = 1, WATCH_ROW_COUNT do
        watchRows[i] = label(parent, "", 16, -162 - (i - 1) * 20, 580)
    end

    watchScrollHint = hint(parent, "", 16, -326, 580)
end

-- ------------------------------------------------------------ 初始化 / 注册

function Settings.Init()
    if overviewFrame then return end

    -- 三个画布：不设锚点、不设尺寸，由 Blizzard 设置面板摆位
    overviewFrame = CreateFrame("Frame", "GreedMirrorSettingsFrame", UIParent)
    generalFrame = CreateFrame("Frame", "GreedMirrorSettingsGeneralFrame", UIParent)
    watchFrame = CreateFrame("Frame", "GreedMirrorSettingsWatchFrame", UIParent)
    overviewFrame:Hide()
    generalFrame:Hide()
    watchFrame:Hide()

    buildOverview(overviewFrame)
    buildGeneral(generalFrame)
    buildWatch(watchFrame)

    -- 面板显示分类时会调用 frame:OnRefresh()，借此刷新控件状态
    overviewFrame.OnRefresh = function() Settings.Refresh() end
    generalFrame.OnRefresh = function() Settings.Refresh() end
    watchFrame.OnRefresh = function() Settings.Refresh() end

    -- 1) 现代 Settings API：父分类 + 两个子分类（TotemTimers 同款结构）
    local api = _G.Settings
    if type(api) == "table" and type(api.RegisterCanvasLayoutCategory) == "function" then
        local ok, created = pcall(api.RegisterCanvasLayoutCategory, overviewFrame, I18n.T("SETTINGS_CATEGORY"))
        if ok and created then
            category = created
            pcall(api.RegisterAddOnCategory, category)
            Settings.mode = "settings-api"

            if type(api.RegisterCanvasLayoutSubcategory) == "function" then
                local ok1, sub1 = pcall(api.RegisterCanvasLayoutSubcategory, category, generalFrame, I18n.T("TAB_GENERAL"))
                if ok1 and sub1 then generalCategory = sub1 end
                local ok2, sub2 = pcall(api.RegisterCanvasLayoutSubcategory, category, watchFrame, I18n.T("TAB_WATCH"))
                if ok2 and sub2 then watchCategory = sub2 end
            end

            -- 与 AceConfig 一致：把分类 ID 记在 frame.name / frame.parent 上
            local parentID = category.ID
            if type(category.GetID) == "function" then
                local _, value = pcall(category.GetID, category)
                if value ~= nil then parentID = value end
            end
            overviewFrame.name = parentID
            generalFrame.parent = parentID
            watchFrame.parent = parentID
            if generalCategory then generalFrame.name = generalCategory.ID end
            if watchCategory then watchFrame.name = watchCategory.ID end
        end
    end

    -- 2) 旧版插件设置
    if not category and type(InterfaceOptions_AddCategory) == "function" then
        local ok = pcall(InterfaceOptions_AddCategory, overviewFrame)
        if ok then
            legacy = true
            Settings.mode = "interface-options"
        end
    end

    -- 3) 降级：只有 /greed settings 能打开
    Settings.mode = Settings.mode or "command-only"

    Settings.Refresh()
end

-- 打开指定页面：settings-api → 直接定位到分类；降级 → 自绘居中
function Settings.OpenPage(page)
    if not overviewFrame then Settings.Init() end

    if category and _G.Settings and type(_G.Settings.OpenToCategory) == "function" then
        local target = category
        if page == "general" and generalCategory then
            target = generalCategory
        elseif page == "watch" and watchCategory then
            target = watchCategory
        end
        -- 不同客户端的 category 取 ID 方式不同：有的有 GetID()，有的只有 .ID 字段
        local id = nil
        if type(target.GetID) == "function" then
            local ok, value = pcall(target.GetID, target)
            if ok then id = value end
        end
        if id == nil then id = target.ID end
        if id ~= nil then
            local ok = pcall(_G.Settings.OpenToCategory, id)
            if ok then return true end
        end
    end

    if legacy and type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        pcall(InterfaceOptionsFrame_OpenToCategory, overviewFrame)
        return true
    end

    -- 自绘降级：把对应画布居中显示
    local frames = { overview = overviewFrame, general = generalFrame, watch = watchFrame }
    for name, f in pairs(frames) do
        if f then
            f:ClearAllPoints()
            f:SetSize(FALLBACK_WIDTH, FALLBACK_HEIGHT)
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            f:SetShown(name == page)
        end
    end
    Settings.Refresh()
    return true
end

function Settings.Open()
    return Settings.OpenPage("general")
end
