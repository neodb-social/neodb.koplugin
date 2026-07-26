--[[--
Stateless helpers shared by the NeoDB plugin modules.

@module koplugin.neodb.util
]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")

--- Fallback app name, for platforms that do not report a device model.
local SOFTWARE_NAME = "KOReader"

--- Longest app name the pairing portal accepts.
local MAX_CLIENT_NAME = 64

local Util = {}

--[[--
Drops JSON `null` placeholders from a decoded response, in place.

KOReader bundles luajson, which decodes `null` into a sentinel *function* rather
than into `nil`. Without this pass, `if mark.comment_text then` is true even when
the server sent `"comment_text": null`, and NeoDB sends null a lot.
]]
function Util.scrubNulls(value, depth)
    if type(value) ~= "table" then return value end
    depth = (depth or 0) + 1
    if depth > 16 then return value end -- paranoia: bail out on pathological nesting
    for k, v in pairs(value) do
        local value_type = type(v)
        if value_type == "function" or value_type == "userdata" then
            value[k] = nil
        elseif value_type == "table" then
            Util.scrubNulls(v, depth)
        end
    end
    return value
end

--[[--
Returns a copy of `list` that luajson will always encode as a JSON array.

luajson infers array-ness from a table's contents, and its `IsArray` reports an
*empty* table as not-an-array — so a bare `{}` is encoded as the JSON object
`{}`, which any endpoint expecting a list rejects. `InitArray` marks it
explicitly. (This is what made NeoDB answer 422 to every mark: `tags = {}` went
out as `"tags":{}`.)
]]
function Util.jsonArray(list)
    local copy = {}
    if type(list) == "table" then
        for index, value in ipairs(list) do copy[index] = value end
    end
    if JSON.util and JSON.util.InitArray then
        return JSON.util.InitArray(copy)
    end
    return copy
end

--- Percent-encodes a table into a query string / form body.
function Util.buildQuery(params)
    local parts = {}
    for k, v in pairs(params) do
        if v ~= nil then
            table.insert(parts, util.urlEncode(tostring(k)) .. "=" .. util.urlEncode(tostring(v)))
        end
    end
    return table.concat(parts, "&")
end

Util.trim = util.trim

--- Truncates on character (not byte) boundaries, so we never split a UTF-8 sequence.
function Util.ellipsize(text, max_chars)
    text = Util.trim(text or "")
    local chars = util.splitToChars(text)
    if #chars <= max_chars then return text end
    return table.concat(chars, "", 1, math.max(1, max_chars - 1)) .. "…"
end

--[[--
What this client calls itself when registering with a NeoDB instance.

The name lands on the instance's authorization screen, where the reader is being
asked to approve *this device* -- so the device is the useful thing to name.
KOReader's model strings are internal codenames ("Kobo_frost") rather than
marketing ones, but they still identify the reader in hand better than the
software name does. Platforms that report no model fall back to it.
]]
function Util.clientName()
    local model = Device.model
    if type(model) ~= "string" then return SOFTWARE_NAME end
    -- Extra parentheses: gsub also returns a count, which trim must not see.
    local name = Util.trim((model:gsub("_", " ")))
    -- A name too long for the pairing portal would fail the whole sign-in, and
    -- no real model comes close -- so treat it as no model at all.
    if name == "" or #name > MAX_CLIENT_NAME then return SOFTWARE_NAME end
    return name
end

--- Brief, non-blocking toast.
function Util.notify(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

function Util.alert(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--[[--
Shows a "please wait" box and returns a function that closes it.

LuaSocket blocks the UI thread for the whole request, so the message has to be
painted *before* we start; otherwise the screen just freezes with no explanation.
]]
function Util.busy(text)
    local widget = InfoMessage:new{ text = text or _("Contacting NeoDB…") }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return function() UIManager:close(widget) end
end

--- Runs `callback` once the device is online, prompting for Wi-Fi if needed.
function Util.whenOnline(callback)
    NetworkMgr:runWhenOnline(callback)
end

--[[--
True when a request stands a chance of succeeding.

`NetworkMgr:isOnline()` resolves a hostname to decide, which is a real network
round trip, so skip it when the radio is off and we already know the answer.
(On platforms with no Wi-Fi toggle, `isWifiOn` reports true and we fall through.)
]]
function Util.isOnline()
    if not NetworkMgr:isWifiOn() then return false end
    return NetworkMgr:isOnline()
end

--[[--
Whether this KOReader can render a QR code.

Loaded lazily and defensively: a build without the widget should still run the
plugin, just without the QR shortcuts.
]]
function Util.hasQRCode()
    local ok, widget = pcall(require, "ui/widget/qrmessage")
    return ok and widget ~= nil
end

--- Shows `text` as a full-screen QR code, sized so a phone camera can read it.
function Util.showQRCode(text)
    local ok, QRMessage = pcall(require, "ui/widget/qrmessage")
    if not ok or not QRMessage then return false end
    UIManager:show(QRMessage:new{
        text = text,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
    })
    return true
end

function Util.copyToClipboard(text)
    if Device:hasClipboard() then
        Device.input.setClipboardText(text)
        return true
    end
    return false
end

--- NeoDB shelves, in the order we present them.
Util.SHELVES = { "wishlist", "progress", "complete", "dropped" }

local SHELF_LABELS = {
    wishlist = _("Want to read"),
    progress = _("Reading"),
    complete = _("Finished"),
    dropped  = _("Dropped"),
}

function Util.shelfLabel(shelf)
    return SHELF_LABELS[shelf] or _("Not marked")
end

--- NeoDB visibility levels (0 is the most open).
local VISIBILITY_LABELS = {
    [0] = _("Public"),
    [1] = _("Followers only"),
    [2] = _("Private"),
}

function Util.visibilityLabel(visibility)
    return VISIBILITY_LABELS[visibility] or VISIBILITY_LABELS[0]
end

Util.VISIBILITIES = { 0, 1, 2 }

--- Renders a NeoDB 1-10 rating grade as half-stars, or nil when unrated.
function Util.stars(grade)
    if type(grade) ~= "number" or grade < 1 then return nil end
    grade = math.min(10, math.floor(grade))
    return string.rep("★", math.floor(grade / 2)) .. (grade % 2 == 1 and "½" or "")
end

function Util.ratingLabel(grade)
    local stars = Util.stars(grade)
    if not stars then return _("No rating") end
    return string.format("%s %d/10", stars, math.min(10, math.floor(grade)))
end

--[[--
Turns whatever the user typed into "https://host", or nil if it is unusable.

Accepts "neodb.social", "https://neodb.social/", "https://neodb.social/users/me/".
]]
function Util.normalizeInstance(input)
    local host = Util.trim(input or "")
    if host == "" then return nil end
    host = host:gsub("^%a+://", "")
    host = host:gsub("/.*$", "") -- drop any path that got pasted along
    host = host:gsub("%s", "")
    if host == "" or not host:match("^[%w%-%._:%[%]]+$") then return nil end
    -- A bare word is far more likely to be a typo than a real host, but allow
    -- host:port so self-hosted instances on a LAN still work.
    if not host:find("%.") and not host:find(":") then return nil end
    return "https://" .. host
end

function Util.instanceHost(instance)
    return (instance or ""):gsub("^%a+://", "")
end

--[[--
Resolves a possibly-relative URL against an instance.

The catalog reports item links as paths -- `"url": "/book/<uuid>"` -- and keeps the
absolute address in a separate field. Stored as-is, that path is no use to the two
features that exist to get a reader off the device: the QR code and the clipboard.

Returns nil when there is nothing usable to build, so callers can hide the option
rather than offer a broken one.
]]
function Util.absoluteUrl(instance, url)
    if type(url) ~= "string" then return nil end
    url = Util.trim(url)
    if url == "" then return nil end
    if url:match("^%a[%w%+%-%.]*://") then return url end
    local base = Util.trim(instance or ""):gsub("/+$", "")
    if base == "" then return nil end
    if not url:match("^/") then url = "/" .. url end
    return base .. url
end

local function isbn13Valid(digits)
    local sum = 0
    for i = 1, 13 do
        local n = tonumber(digits:sub(i, i))
        if not n then return false end
        sum = sum + n * ((i % 2 == 1) and 1 or 3)
    end
    return sum % 10 == 0
end

local function isbn10Valid(digits)
    local sum = 0
    for i = 1, 10 do
        local c = digits:sub(i, i)
        local n = (i == 10 and c == "X") and 10 or tonumber(c)
        if not n then return false end
        sum = sum + n * (11 - i)
    end
    return sum % 11 == 0
end

--[[--
Looks for a checksum-valid ISBN in any of the given strings.

KOReader's document properties do not include a structured identifier, so we
scan what we do get -- filename, keywords, description -- for something that
looks like an ISBN. The checksum keeps false positives rare, and we only ever
use the result as a *search query*: the server has to confirm the match before
anything is linked.
]]
function Util.findISBN(...)
    for i = 1, select("#", ...) do
        local text = select(i, ...)
        if type(text) == "string" and #text > 0 then
            for run in text:gmatch("[%dXx][%dXx%s%-]*[%dXx]") do
                local digits = run:gsub("[%s%-]", ""):upper()
                local len = #digits
                if len >= 10 and len <= 40 then
                    -- Prefer ISBN-13: a 10-digit window inside a 13-digit ISBN
                    -- can pass its own checksum by chance.
                    for start = 1, len - 12 do
                        local candidate = digits:sub(start, start + 12)
                        local prefix = candidate:sub(1, 3)
                        if (prefix == "978" or prefix == "979") and isbn13Valid(candidate) then
                            return candidate
                        end
                    end
                    for start = 1, len - 9 do
                        local candidate = digits:sub(start, start + 9)
                        if isbn10Valid(candidate) then return candidate end
                    end
                end
            end
        end
    end
    return nil
end

--- Joins a NeoDB string array (authors, publishers…) for display.
function Util.joinList(list, separator)
    if type(list) ~= "table" or #list == 0 then return nil end
    local parts = {}
    for _idx, v in ipairs(list) do
        if type(v) == "string" and v ~= "" then table.insert(parts, v) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, separator or ", ")
end

--- Human-readable one-liner for a catalog item: "Title — Author (Year)".
function Util.itemSummary(item)
    if not item then return "" end
    local text = item.title or item.display_title or _("Untitled")
    local author = Util.joinList(item.author)
    if author then text = text .. " — " .. author end
    if item.pub_year then text = text .. string.format(" (%s)", tostring(item.pub_year)) end
    return text
end

return Util
