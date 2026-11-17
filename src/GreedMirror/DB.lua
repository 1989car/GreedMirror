-- GreedMirror 贪婪镜 - DB.lua
-- 设置项与名单写入 SavedVariables（跨会话保留）；
-- 玩家统计缓存只存在内存里，重载后自然清空。
local ADDON, GM = ...

local DB = {}
GM.DB = DB
GM.Require("DB")

DB.DEFAULTS = {
    enabled = true,      -- 插件总开关
    tooltip = true,      -- 鼠标提示框显示
    selfTooltip = true,  -- 显示自身数据
    detail = false,      -- 详细次数
    partyAlert = true,   -- 队伍高需求率提示
    interval = 3600,     -- 查询间隔（秒）
}

DB.cache = {}      -- 运行期缓存：guid -> row
DB.watchlist = {}  -- 持久化名单：guid -> entry

local function now()
    return time and time() or 0
end

function DB.Init()
    local sv = _G.GreedMirrorDB
    if type(sv) ~= "table" then
        sv = {}
        _G.GreedMirrorDB = sv
    end
    DB.sv = sv
    if type(sv.options) ~= "table" then sv.options = {} end
    for key, value in pairs(DB.DEFAULTS) do
        if sv.options[key] == nil then sv.options[key] = value end
    end
    -- 兼容非法值
    if type(sv.options.interval) ~= "number" then sv.options.interval = DB.DEFAULTS.interval end
    if type(sv.watchlist) ~= "table" then sv.watchlist = {} end
    DB.watchlist = sv.watchlist
    DB.cache = {}
end

function DB.Get(key)
    local options = DB.sv and DB.sv.options
    if type(options) ~= "table" then return DB.DEFAULTS[key] end
    local value = options[key]
    if value == nil then return DB.DEFAULTS[key] end
    return value
end

function DB.Set(key, value)
    if not DB.sv then return end
    DB.sv.options[key] = value
    DB.Save()
end

function DB.Save()
    if DB.sv then _G.GreedMirrorDB = DB.sv end
end

-- ---------------------------------------------------------------- 缓存

function DB.CachePut(guid, row)
    if type(guid) ~= "string" or guid == "" or type(row) ~= "table" then return end
    row.at = row.at or now()
    DB.cache[guid] = row
end

function DB.CacheGet(guid)
    if type(guid) ~= "string" then return nil end
    return DB.cache[guid]
end

function DB.CacheAge(guid)
    local row = DB.CacheGet(guid)
    if not row or type(row.at) ~= "number" then return nil end
    return now() - row.at
end

function DB.Interval()
    local interval = tonumber(DB.Get("interval"))
    if type(interval) ~= "number" or interval < 0 then return DB.DEFAULTS.interval end
    return interval
end

-- 缓存是否仍然新鲜（实时档位 interval=0 表示永不命中，必须重新查询）。
function DB.CacheFresh(guid)
    local row = DB.CacheGet(guid)
    if not row then return false end
    local interval = DB.Interval()
    if interval <= 0 then return false end
    local age = DB.CacheAge(guid)
    if type(age) ~= "number" then return false end
    return age < interval
end

function DB.ClearCache()
    DB.cache = {}
end

function DB.CacheCount()
    local count = 0
    for _ in pairs(DB.cache) do count = count + 1 end
    return count
end

-- ------------------------------------------------------------ 高需求率名单

function DB.WatchGet(guid)
    if type(guid) ~= "string" then return nil end
    return DB.watchlist[guid]
end

function DB.WatchPut(guid, entry)
    if type(guid) ~= "string" or guid == "" or type(entry) ~= "table" then return end
    entry.guid = guid
    entry.at = entry.at or now()
    DB.watchlist[guid] = entry
    DB.Save()
end

function DB.WatchRemove(guid)
    if type(guid) ~= "string" then return end
    DB.watchlist[guid] = nil
    DB.Save()
end

function DB.WatchClear()
    DB.watchlist = {}
    if DB.sv then DB.sv.watchlist = DB.watchlist end
    DB.Save()
end

function DB.WatchList()
    local list = {}
    for guid, entry in pairs(DB.watchlist) do
        list[#list + 1] = { guid = guid, name = entry.name, realm = entry.realm,
            race = entry.race, class = entry.class,
            rate = entry.rate, need = entry.need, greed = entry.greed,
            rolls = entry.rolls, dungeons = entry.dungeons, at = entry.at }
    end
    table.sort(list, function(a, b)
        if (a.rate or 0) ~= (b.rate or 0) then return (a.rate or 0) > (b.rate or 0) end
        return tostring(a.name) < tostring(b.name)
    end)
    return list
end

function DB.WatchCount()
    local count = 0
    for _ in pairs(DB.watchlist) do count = count + 1 end
    return count
end
