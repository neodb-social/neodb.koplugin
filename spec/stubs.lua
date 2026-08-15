--[[--
Enough of KOReader to load this plugin's modules under plain luajit.

The modules are written against KOReader's frontend, which needs a device, a
screen and a running UIManager. None of that is necessary to test what they
actually decide, so this file stands in for the parts they touch and records what
they did with them.

Three of the stubs do more than stand in, and the tests depend on it:

* `luasettings.open` hands back a settings object with real semantics, including
  that `readSetting(key, default)` writes the default in only when it is truthy.
  That is what makes `Store` -- and so `NeoDB:new{}` -- constructible.
* `docsettings.open` copies the sidecar on open and writes it back on flush, the
  way KOReader does. Opening two instances for one book therefore loses the first
  one's writes here as well, so a test can catch that.
* the dialog widgets keep their buttons and let a test press one by id, so a
  broken `relabel` or a button wired to the wrong callback is visible.

@module spec.stubs
]]

local Stubs = {}

-- Assertions ------------------------------------------------------------------

local Check = { count = 0, failures = {}, skipped = 0 }

local function describe(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) == "table" then
        local parts = {}
        for k, v in pairs(value) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(value)
end

function Check.ok(condition, name)
    Check.count = Check.count + 1
    if not condition then
        table.insert(Check.failures, name)
        print(string.format("  FAIL  %s", name))
    end
    return condition
end

function Check.eq(actual, expected, name)
    local same = actual == expected
    if not same then
        Check.count = Check.count + 1
        table.insert(Check.failures, name)
        print(string.format("  FAIL  %s\n          expected %s\n          actual   %s",
            name, describe(expected), describe(actual)))
        return false
    end
    return Check.ok(true, name)
end

function Check.skip(name)
    Check.skipped = Check.skipped + 1
    print(string.format("  skip  %s", name))
end

function Check.section(name)
    print("\n" .. name)
end

function Check.finish()
    print(string.format("\n%d checks, %d failed, %d skipped",
        Check.count, #Check.failures, Check.skipped))
    if #Check.failures > 0 then
        for _idx, name in ipairs(Check.failures) do print("  failed: " .. name) end
        os.exit(1)
    end
    os.exit(0)
end

Stubs.check = Check

-- Recorded output -------------------------------------------------------------

Stubs.notifications = {}
Stubs.alerts = {}
Stubs.shown = {}
Stubs.logs = {}
Stubs.dispatcher_actions = {}
Stubs.providers = {}
Stubs.requests = {}

function Stubs.reset()
    Stubs.notifications = {}
    Stubs.alerts = {}
    Stubs.shown = {}
    Stubs.logs = {}
    Stubs.requests = {}
end

--- The most recent widget of a kind, which is nearly always the one under test.
function Stubs.lastShown(kind)
    for i = #Stubs.shown, 1, -1 do
        if Stubs.shown[i].kind == kind then return Stubs.shown[i] end
    end
    return nil
end

function Stubs.lastNotification()
    return Stubs.notifications[#Stubs.notifications]
end

function Stubs.lastAlert()
    return Stubs.alerts[#Stubs.alerts]
end

-- Settings objects ------------------------------------------------------------

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

Stubs.copy = copy

--[[--
A LuaSettings-shaped object over `data`.

`on_flush` is how the DocSettings stub models writing back to disk: the settings
object holds its own copy, exactly as KOReader's does, and only a flush publishes
it.
]]
local function makeSettings(data, on_flush)
    local settings = { data = data, flush_count = 0 }

    function settings:readSetting(key, default)
        -- luasettings.lua:89 -- the default is installed only when it is truthy.
        if self.data[key] == nil and default then
            self.data[key] = default
        end
        return self.data[key]
    end

    function settings:saveSetting(key, value)
        self.data[key] = value
        return self
    end

    function settings:delSetting(key)
        self.data[key] = nil
        return self
    end

    function settings:has(key)
        return self.data[key] ~= nil
    end

    function settings:flush()
        self.flush_count = self.flush_count + 1
        if on_flush then on_flush(self.data) end
    end

    return settings
end

Stubs.makeSettings = makeSettings

-- Module stubs ----------------------------------------------------------------

local modules = {}

modules["gettext"] = setmetatable({}, {
    __call = function(_self, text) return text end,
})

modules["logger"] = {
    dbg  = function(...) table.insert(Stubs.logs, { level = "dbg", ... }) end,
    info = function(...) table.insert(Stubs.logs, { level = "info", ... }) end,
    warn = function(...) table.insert(Stubs.logs, { level = "warn", ... }) end,
    err  = function(...) table.insert(Stubs.logs, { level = "err", ... }) end,
}

--- KOReader's `%1`-style templating, which is not Lua's `string.format`.
local function template(str, ...)
    local args = { ... }
    return (tostring(str):gsub("%%(%d)", function(index)
        local value = args[tonumber(index)]
        return value ~= nil and tostring(value) or ""
    end))
end

modules["ffi/util"] = { template = template }

modules["util"] = {
    trim = function(text)
        if text == nil then return nil end
        return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
    end,
    urlEncode = function(text)
        return (tostring(text):gsub("[^%w%-%_%.%~]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    end,
    splitToChars = function(text)
        -- Split on UTF-8 lead bytes: luajit has no utf8 library, and character
        -- boundaries are the whole point of the function this stands in for.
        local chars = {}
        for char in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            table.insert(chars, char)
        end
        return chars
    end,
    cleanupSelectedText = function(text)
        return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
    end,
    tableDeepCopy = copy,
}

-- JSON ------------------------------------------------------------------------
--
-- Small but real: `Util.jsonArray` asks for the array marker, and `Api:raw`
-- encodes every request body through this.

local JSON = {}
local ARRAY = {}

JSON.util = {
    InitArray = function(t)
        return setmetatable(t, ARRAY)
    end,
}

local function encodeValue(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        if value % 1 == 0 then return string.format("%d", value) end
        return tostring(value)
    end
    if kind == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' end
            if c == "\\" then return "\\\\" end
            if c == "\n" then return "\\n" end
            return string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end
    if kind ~= "table" then return "null" end

    local is_array = getmetatable(value) == ARRAY
    if not is_array then
        local count = 0
        for _k in pairs(value) do count = count + 1 end
        is_array = count > 0 and #value == count
    end

    local parts = {}
    if is_array then
        for _idx, item in ipairs(value) do
            table.insert(parts, encodeValue(item))
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k in pairs(value) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    for _idx, key in ipairs(keys) do
        table.insert(parts, encodeValue(key) .. ":" .. encodeValue(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

JSON.encode = encodeValue

local function skipSpace(text, pos)
    return text:find("[^ \t\r\n]", pos) or #text + 1
end

local decodeValue

local function decodeString(text, pos)
    local out = {}
    pos = pos + 1
    while pos <= #text do
        local c = text:sub(pos, pos)
        if c == '"' then return table.concat(out), pos + 1 end
        if c == "\\" then
            local escape = text:sub(pos + 1, pos + 1)
            local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
            if escape == "u" then
                table.insert(out, "?")
                pos = pos + 6
            else
                table.insert(out, map[escape] or escape)
                pos = pos + 2
            end
        else
            table.insert(out, c)
            pos = pos + 1
        end
    end
    error("unterminated string")
end

decodeValue = function(text, pos)
    pos = skipSpace(text, pos)
    local c = text:sub(pos, pos)
    if c == "{" then
        local out = {}
        pos = skipSpace(text, pos + 1)
        if text:sub(pos, pos) == "}" then return out, pos + 1 end
        while true do
            local key, value
            key, pos = decodeString(text, skipSpace(text, pos))
            pos = skipSpace(text, pos)
            pos = pos + 1 -- ':'
            value, pos = decodeValue(text, pos)
            out[key] = value
            pos = skipSpace(text, pos)
            local sep = text:sub(pos, pos)
            pos = pos + 1
            if sep == "}" then return out, pos end
        end
    elseif c == "[" then
        local out = {}
        pos = skipSpace(text, pos + 1)
        if text:sub(pos, pos) == "]" then return out, pos + 1 end
        while true do
            local value
            value, pos = decodeValue(text, pos)
            table.insert(out, value)
            pos = skipSpace(text, pos)
            local sep = text:sub(pos, pos)
            pos = pos + 1
            if sep == "]" then return out, pos end
        end
    elseif c == '"' then
        return decodeString(text, pos)
    elseif text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif text:sub(pos, pos + 3) == "null" then
        -- luajson decodes null into a sentinel function rather than nil, which is
        -- the whole reason `Util.scrubNulls` exists.
        return function() end, pos + 4
    else
        local literal = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not literal then error("bad json at " .. pos) end
        return tonumber(literal), pos + #literal
    end
end

JSON.decode = function(text)
    local value = decodeValue(text, 1)
    return value
end

modules["json"] = JSON

-- Device and screen -----------------------------------------------------------

Stubs.clipboard = nil

modules["device"] = {
    model = "Kobo_frost",
    hasClipboard = function() return true end,
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
    },
    input = {
        setClipboardText = function(text) Stubs.clipboard = text end,
    },
}

-- UIManager -------------------------------------------------------------------

local UIManager = {
    _tasks = {},
    _stack = {},
    repaints = 0,
}

function UIManager:show(widget)
    table.insert(self._stack, widget)
    if widget and widget.kind then table.insert(Stubs.shown, widget) end
    return widget
end

function UIManager:close(widget)
    for i = #self._stack, 1, -1 do
        if self._stack[i] == widget then table.remove(self._stack, i) end
    end
    if widget then widget.closed = true end
end

function UIManager:scheduleIn(seconds, action)
    table.insert(self._tasks, { at = seconds, action = action })
end

function UIManager:nextTick(action)
    table.insert(self._tasks, { at = 0, action = action })
end

function UIManager:unschedule(action)
    for i = #self._tasks, 1, -1 do
        if self._tasks[i].action == action then table.remove(self._tasks, i) end
    end
end

function UIManager:setDirty() end
function UIManager:forceRePaint() self.repaints = self.repaints + 1 end

function UIManager:isWidgetShown(widget)
    for _idx, entry in ipairs(self._stack) do
        if entry == widget then return true end
    end
    return false
end

function UIManager:getTopmostVisibleWidget()
    return self._stack[#self._stack]
end

--- Runs every task scheduled so far, once, in order.
function UIManager:runTasks()
    local tasks = self._tasks
    self._tasks = {}
    for _idx, task in ipairs(tasks) do task.action() end
    return #tasks
end

function UIManager:scheduledCount(action)
    local count = 0
    for _idx, task in ipairs(self._tasks) do
        if action == nil or task.action == action then count = count + 1 end
    end
    return count
end

function UIManager:clearTasks()
    self._tasks = {}
end

function UIManager:clearStack()
    self._stack = {}
end

modules["ui/uimanager"] = UIManager
Stubs.uimanager = UIManager

-- Widgets ---------------------------------------------------------------------

--[[--
Gives a dialog stub a button table a test can operate.

Rows come from `buttons` (InputDialog, ButtonDialog) or `buttons_table`
(TextViewer). `press` and `label` work by button id where there is one, so a test
can catch a `relabel` that stopped finding its button.
]]
local function pressable(widget)
    local rows = widget.buttons or widget.buttons_table or {}

    widget.button_table = {
        getButtonById = function(_self, id)
            for _r, row in ipairs(rows) do
                for _c, button in ipairs(row) do
                    if button.id == id then
                        button.setText = button.setText or function(this, text)
                            this.text = text
                        end
                        return button
                    end
                end
            end
            return nil
        end,
    }

    function widget:findButton(id_or_text)
        for _r, row in ipairs(rows) do
            for _c, button in ipairs(row) do
                if button.id == id_or_text or button.text == id_or_text then
                    return button
                end
            end
        end
        return nil
    end

    function widget:press(id_or_text)
        local button = self:findButton(id_or_text)
        if not button then error("no such button: " .. tostring(id_or_text)) end
        if button.enabled == false then error("button disabled: " .. tostring(id_or_text)) end
        button.callback()
        return button
    end

    function widget:label(id)
        local button = self:findButton(id)
        return button and button.text or nil
    end

    function widget:labels()
        local out = {}
        for _r, row in ipairs(rows) do
            for _c, button in ipairs(row) do table.insert(out, button.text) end
        end
        return out
    end

    return widget
end

Stubs.pressable = pressable

local function widgetClass(kind, extra)
    local class = { kind = kind }
    class.__index = class
    class.new = function(self, fields)
        local widget = setmetatable(fields or {}, self)
        widget.kind = kind
        if extra then extra(widget) end
        return widget
    end
    return class
end

modules["ui/widget/infomessage"] = widgetClass("InfoMessage", function(widget)
    table.insert(Stubs.alerts, widget.text)
end)

modules["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = "always",
    notify = function(_self, text)
        table.insert(Stubs.notifications, text)
    end,
}

modules["ui/widget/confirmbox"] = widgetClass("ConfirmBox", function(widget)
    function widget:accept()
        if self.ok_callback then self.ok_callback() end
        UIManager:close(self)
    end
    function widget:decline()
        if self.cancel_callback then self.cancel_callback() end
        UIManager:close(self)
    end
end)

modules["ui/widget/buttondialog"] = widgetClass("ButtonDialog", pressable)

modules["ui/widget/inputdialog"] = widgetClass("InputDialog", function(widget)
    pressable(widget)
    widget.typed = widget.input or ""
    function widget:getInputText() return self.typed end
    function widget:setInputText(text) self.typed = text end
    function widget:typeText(text) self.typed = text end
    function widget:onShowKeyboard() self.keyboard = true end
    function widget:onCloseKeyboard() self.keyboard = false end
end)

modules["ui/widget/textviewer"] = widgetClass("TextViewer", pressable)
modules["ui/widget/menu"] = widgetClass("Menu", function(widget)
    function widget:select(text)
        for _idx, item in ipairs(self.item_table or {}) do
            if item.text == text then
                if item.callback then item.callback() end
                return item
            end
        end
        error("no such menu row: " .. tostring(text))
    end
end)

-- QR code support is optional, and absent unless a test asks for it.
Stubs.qr_available = false
Stubs.qr_codes = {}
modules["ui/widget/qrmessage"] = false

-- Widget container ------------------------------------------------------------

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer

function WidgetContainer:extend(prototype)
    local class = prototype or {}
    class.__index = class
    return setmetatable(class, self)
end

function WidgetContainer:new(fields)
    local instance = setmetatable(fields or {}, self)
    if instance.init then instance:init() end
    return instance
end

modules["ui/widget/container/widgetcontainer"] = WidgetContainer

-- Dispatcher and Provider -----------------------------------------------------

modules["dispatcher"] = {
    registerAction = function(_self, name, spec)
        -- Idempotent, as KOReader's is: `init` runs in both ReaderUI and the
        -- file browser.
        if Stubs.dispatcher_actions[name] == nil then
            Stubs.dispatcher_actions[name] = spec
        end
    end,
}

modules["provider"] = {
    register = function(_self, feature, name, implementation)
        Stubs.providers[feature] = Stubs.providers[feature] or {}
        Stubs.providers[feature][name] = implementation
    end,
    getProvidersTable = function(_self, feature)
        return Stubs.providers[feature] or {}
    end,
}

-- Storage ---------------------------------------------------------------------

modules["datastorage"] = {
    getSettingsDir = function() return "/tmp/neodb-spec/settings" end,
    getDataDir = function() return "/tmp/neodb-spec" end,
}

Stubs.settings_files = {}

modules["luasettings"] = {
    open = function(_self, path)
        Stubs.settings_files[path] = Stubs.settings_files[path] or {}
        local data = Stubs.settings_files[path]
        return makeSettings(data)
    end,
}

--[[--
Sidecars, with KOReader's own hazard preserved.

`open` hands back a fresh instance holding a *copy*, and only `flush` publishes
it. So a second instance opened for a book that is already open really does
overwrite the first one's writes here, which is the failure `resolveBook` exists
to prevent.
]]
Stubs.sidecars = {}
Stubs.docsettings_opens = 0

local DocSettings = {}

function DocSettings:hasSidecarFile(path)
    return type(path) == "string" and Stubs.sidecars[path] ~= nil
end

function DocSettings:open(path)
    if type(path) ~= "string" then error("bad path") end
    Stubs.docsettings_opens = Stubs.docsettings_opens + 1
    Stubs.sidecars[path] = Stubs.sidecars[path] or {}
    local snapshot = copy(Stubs.sidecars[path])
    return makeSettings(snapshot, function(data)
        Stubs.sidecars[path] = copy(data)
    end)
end

modules["docsettings"] = DocSettings

--- Creates a sidecar for `path` and returns the live settings object for it.
function Stubs.newSidecar(path, data)
    Stubs.sidecars[path] = data or {}
    return DocSettings:open(path)
end

-- Network ---------------------------------------------------------------------

Stubs.wifi_on = true
Stubs.online = true

modules["ui/network/manager"] = {
    isWifiOn = function() return Stubs.wifi_on end,
    isOnline = function() return Stubs.online end,
    runWhenOnline = function(_self, callback)
        if Stubs.online then return callback() end
        Stubs.notifications[#Stubs.notifications + 1] = "[wifi prompt]"
    end,
}

modules["socketutil"] = {
    set_timeout = function() end,
    reset_timeout = function() end,
    TIMEOUT_CODE = "timeout",
    SINK_TIMEOUT_CODE = "sink timeout",
}

modules["socket"] = {
    skip = function(count, ...)
        local values = { ... }
        local out = {}
        for i = count + 1, #values do table.insert(out, values[i]) end
        return table.unpack and table.unpack(out) or unpack(out)
    end,
    gettime = function() return 0 end,
}

modules["ltn12"] = {
    sink = {
        table = function(t)
            return function(chunk)
                if chunk then table.insert(t, chunk) end
                return 1
            end
        end,
    },
    source = {
        string = function(s) return function() return s end end,
    },
}

--[[--
The HTTP transport.

`Stubs.respond` is what a test sets: it is handed the request and returns
`code, headers, status`, plus the body it wants written into the sink.
]]
Stubs.respond = nil

modules["socket.http"] = {
    request = function(request)
        table.insert(Stubs.requests, request)
        if not Stubs.respond then
            return 1, 200, { ["content-type"] = "application/json" }, "OK"
        end
        local code, headers, body = Stubs.respond(request)
        if code == nil then
            -- A transport failure: LuaSocket answers nil plus a reason.
            return nil, headers or "connection refused"
        end
        if body and request.sink then request.sink(body) end
        return 1, code, headers or {}, tostring(code)
    end,
}

-- Loader ----------------------------------------------------------------------

local plugin_dir = (...):match("^(.*)%.stubs$")
plugin_dir = plugin_dir and plugin_dir:gsub("%.", "/") or "spec"
package.path = table.concat({
    "./?.lua",
    "../?.lua",
    plugin_dir .. "/../?.lua",
    package.path,
}, ";")

table.insert(package.loaders or package.searchers, 1, function(name)
    if name == "ui/widget/qrmessage" and not Stubs.qr_available then
        return nil
    end
    local module = modules[name]
    if module ~= nil then
        return function() return module end
    end
    return nil
end)

--- Lets a test turn the QR widget on, since half the sign-in UI depends on it.
function Stubs.enableQR(enabled)
    Stubs.qr_available = enabled and true or false
    modules["ui/widget/qrmessage"] = widgetClass("QRMessage", function(widget)
        table.insert(Stubs.qr_codes, widget.text)
    end)
end

return Stubs
