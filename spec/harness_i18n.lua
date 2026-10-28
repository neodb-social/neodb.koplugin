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
check.ok(count > 300, "coverage includes the complete plugin")
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
    check.eq(_("Highlight & share"), "高亮&分享", "Simplified Chinese locale " .. lang)
end
for _idx, lang in ipairs({ "C", "en", "en_US", "en_GB", "fr", "zh_TW" }) do
    gettext.current_lang = lang
    check.eq(_("Highlight & share"), "Highlight & share", "English/KOReader fallback for " .. lang)
end
gettext.current_lang = "zh_CN"
check.eq(_("A new untranslated message"), "A new untranslated message", "unknown messages remain readable")
check.eq(T(_("Post %1 highlights and notes from “%2” to NeoDB?\n\nEach one becomes a separate note, and they cannot be taken back from here."), 12, "Dune"),
    "将《Dune》中的 12 条高亮和笔记发布到 NeoDB？\n\n每条内容都会成为一篇独立笔记，无法在此撤回。",
    "Chinese can reorder placeholders")

check.section("Bilingual composer, menu actions and API payloads")
local Actions = require("neodb_actions")
local Store = require("neodb_store")
local Api = require("neodb_api")
local Util = require("neodb_util")
local NeoDB = require("main")
for _idx, language in ipairs({ "zh_CN", "C" }) do
    gettext.current_lang = language
    Stubs.reset()
    Stubs.online = false
    local store = Store:new()
    store:setInstance("https://example.org")
    store:setToken("test-only")
    store:set("quote_position", "after")
    store:set("quote_as_blockquote", true)
    store:set("post_to_fediverse", true)
    store:set("selection_crosspost", true)
    store:set("note_title_style", "decorated")
    store:set("quote_intro_style", "decorated")
    store:set("default_visibility", 0)
    local settings = Stubs.newSidecar("/books/i18n.epub", {})
    store:setLink(settings, { uuid = "book", title = "Dune" })
    local ui = {
        document = { file = "/books/i18n.epub", getPageCount = function() return 100 end },
        doc_settings = settings,
        getCurrentPage = function() return 48 end,
        toc = { getTocTitleByPage = function() return "Chapter One" end },
        highlight = { addToHighlightDialog = function(self, id, factory) self[id] = factory end },
    }
    local ctx = { ui = ui, store = store, api = Api:new{ store = store } }
    NeoDB.addHighlightAction({ ui = ui, ctx = ctx })
    check.eq(ui.highlight["14_neodb_note"]({}).text, _("Add note & share"), "localized note action " .. language)
    check.eq(ui.highlight["15_neodb_highlight"]({}).text, _("Highlight & share"), "localized highlight action " .. language)
    check.eq(Util.visibilityLabel(0), _("Public"), "visibility follows language " .. language)
    check.eq(Util.shelfLabel("complete"), _("Finished"), "shelf follows language " .. language)
    check.eq(Util.postVisibilityLabel("private"), _("Followers only"), "social visibility follows language " .. language)
    check.eq(Api.describeError("queue_full"), _("Too many uploads are already waiting. Upload them first, under Tools → NeoDB → Uploads."),
        "errors follow language " .. language)
    Actions.addNote(ctx, { quote = "A passage", save_note = function() error("local save is disabled in this test") end })
    local dialog = Stubs.lastShown("InputDialog")
    check.eq(dialog.title, _("Add note & share"), "composer title " .. language)
    check.eq(dialog:label("progress"), T(_("At: %1"), "48%"), "progress label " .. language)
    check.eq(dialog:label("visibility"), T(_("Visible to: %1"), _("Public")), "visibility label " .. language)
    check.eq(dialog:label("fediverse"), _("Crosspost: on"), "crosspost label " .. language)
    check.eq(dialog:label("quote_position"), _("Quote: below note"), "quote label " .. language)
    check.eq(dialog:getNoteTitle(), language == "zh_CN"
        and "📖 读书笔记｜《Dune》· Chapter One · 48%" or "📖 Reading notes | Dune · Chapter One · 48%",
        "generated title " .. language)
    dialog:press("save_local")
    check.eq(dialog:label("post"), _("Share only"), "share-only button " .. language)
    dialog:typeText("我的文字 / My own words")
    dialog:press("post")
    local queue = store:getQueue()
    local op = queue[#queue]
    check.eq(op.body.content, "我的文字 / My own words\n\n" .. _("Quoted passage: 👇") .. "\n\n> A passage",
        "only the introduction is translated; user text is unchanged " .. language)
    check.eq(op.body.visibility, 0, "visibility API value is not translated " .. language)
    check.eq(op.body.progress_type, "percentage", "progress API value is not translated " .. language)
    check.eq(op.body.post_to_fediverse, true, "crosspost flag is retained " .. language)
end
check.finish()
