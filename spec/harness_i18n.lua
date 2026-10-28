local Stubs = require("stubs")
local check = Stubs.check
local gettext = require("gettext")
local _ = require("neodb_i18n")
local catalog = require("neodb_zh_cn")
local T = require("ffi/util").template

-- Read literal gettext calls, including escaped quotes and Lua long strings.
-- Checking the actual module sources prevents new UI strings silently lacking
-- Chinese translations. Only string literals are evaluated, never source code.
local function messages(source)
    local result, cursor = {}, 1
    while true do
        local start, finish = source:find("%f[%w_]_%(%s*", cursor)
        if not start then return result end
        local first = finish + 1
        local char = source:sub(first, first)
        local last
        if char == '"' or char == "'" then
            local i = first + 1
            while i <= #source do
                local next_char = source:sub(i, i)
                if next_char == "\\" then i = i + 2
                elseif next_char == char then last = i; break
                else i = i + 1 end
            end
        elseif source:sub(first, first + 1) == "[[" then
            local closing = source:find("]]", first + 2, true)
            if closing then last = closing + 1 end
        end
        assert(last, "gettext call must have a literal message")
        local message = assert(loadstring("return " .. source:sub(first, last)))()
        result[message] = true
        cursor = last + 1
    end
end

local function placeholders(text)
    local tokens = {}
    for token in text:gmatch("%%[%d]+") do tokens[#tokens + 1] = token end
    for token in text:gmatch("%%[dsf]") do tokens[#tokens + 1] = token end
    table.sort(tokens)
    return table.concat(tokens, ",")
end

check.section("Translation coverage and placeholders")
local used = {}
for _idx, path in ipairs(arg) do
    local file = assert(io.open(path))
    local source = file:read("*a")
    file:close()
    for message in pairs(messages(source)) do used[message] = true end
end
local count = 0
for message in pairs(used) do
    count = count + 1
    if type(catalog[message]) ~= "string" or catalog[message] == "" then
        print("  WARNING: missing Chinese translation: " .. message)
    end
end
check.ok(count > 0, "source strings were scanned")
for message, translated in pairs(catalog) do
    if not used[message] then print("  WARNING: unused translation: " .. message) end
    check.eq(placeholders(translated), placeholders(message), "placeholders: " .. message)
    gettext.current_lang = "zh_CN"
    check.eq(_(message), translated, "Chinese: " .. message)
    gettext.current_lang = "C"
    check.eq(_(message), message, "English: " .. message)
    check.eq(gettext(message), message, "global gettext is untouched: " .. message)
end

check.section("Language selection and fallback")
for _idx, lang in ipairs({ "zh_CN", "zh-CN", "zh_CN.UTF-8", "zh_Hans", "zh_SG", "zh" }) do
    gettext.current_lang = lang
    check.eq(_("Settings"), "设置", "Simplified Chinese locale " .. lang)
end
for _idx, lang in ipairs({ "C", "en", "en_US", "en_GB", "fr", "zh_TW" }) do
    gettext.current_lang = lang
    check.eq(_("Settings"), "Settings", "English/KOReader fallback for " .. lang)
end
gettext.current_lang = "zh_CN"
check.eq(_("A new untranslated message"), "A new untranslated message", "unknown messages remain readable")
check.eq(T(_("Post %1 highlights and notes from “%2” to NeoDB?\n\nEach one becomes a separate note, and they cannot be taken back from here."), 12, "Dune"),
    "将《Dune》中的 12 条高亮和笔记发布到 NeoDB？\n\n每条内容都会成为一篇独立笔记，无法在此撤回。",
    "Chinese can reorder placeholders")

check.finish()
