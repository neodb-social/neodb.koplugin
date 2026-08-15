--[[--
Tests for the KOReader "Export highlights" target.

    cd spec && TZ=America/New_York luajit harness_exporter.lua

**Run it in a timezone that observes DST.** The clock cases below turn on a
wall-clock time that does not exist locally, which is how a clipping can fail to
name the annotation it came from. The gap is found at run time and the cases are
skipped in a zone that has none (UTC, Asia/Shanghai), so it passes everywhere --
but it only proves anything where there is a gap to fall into.

@module spec.harness_exporter
]]

local Stubs = require("stubs")
local check = Stubs.check
local UIManager = Stubs.uimanager

-- The exporter keeps its switch in KOReader's global settings, which is a global.
G_reader_settings = Stubs.makeSettings({})

local NeoDB = require("main")
local Target = require("neodb_exporter")

local INSTANCE = "https://neodb.social"
local BOOK = "/books/dune.epub"

local function reset()
    Stubs.reset()
    Stubs.settings_files = {}
    Stubs.sidecars = {}
    Stubs.wifi_on = true
    Stubs.online = true
    G_reader_settings = Stubs.makeSettings({})
    UIManager:clearTasks()
    UIManager:clearStack()
    Target.ctx = nil
end

local function enable()
    G_reader_settings:readSetting("exporter", {})["NeoDB"] = { enabled = true }
end

local function newReaderUI(file, sidecar)
    local doc_settings = Stubs.newSidecar(file, sidecar or {})
    local ui = {
        document = {
            file = file,
            getPageCount = function() return 400 end,
            getProps = function() return {} end,
        },
        doc_settings = doc_settings,
        doc_props = { title = "Dune" },
        annotation = { annotations = sidecar and sidecar.annotations or {} },
        menu = { registerToMainMenu = function() end },
        highlight = { addToHighlightDialog = function() end },
    }
    function ui:getCurrentPage() return 100 end
    return ui
end

local function newPlugin(ui)
    local plugin = NeoDB:new{ ui = ui }
    plugin.store:setInstance(INSTANCE)
    plugin.store:setToken("token-1")
    UIManager:show(ui)
    return plugin
end

--- A link table as it sits in a sidecar, for books built by hand.
local function link(fields)
    local out = {
        uuid = "item-1",
        title = "Dune",
        instance = INSTANCE,
        annotation_sync = { enabled = false, since = "2026-01-01 00:00:00" },
    }
    for k, v in pairs(fields or {}) do out[k] = v end
    return out
end

local function annotation(datetime, fields)
    local a = {
        datetime = datetime,
        text     = "The spice must flow.",
        chapter  = "Chapter One",
        pageno   = 100,
        drawer   = "lighten",
    }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end

--- The exporter's own shape: a book, holding chapter groups, holding clippings.
local function booknotes(file, times, extra)
    local out = { file = file, title = "Dune", number_of_pages = 400 }
    for _idx, time in ipairs(times) do
        table.insert(out, { { text = "The spice must flow.", time = time, page = 100 } })
    end
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

--- The epoch a clipping carries, rebuilt from a datetime the way KOReader does.
local function epochOf(datetime)
    local y, m, d, hh, mm, ss = datetime:match(
        "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
    return os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(hh), min = tonumber(mm), sec = tonumber(ss),
    })
end

--[[--
A local wall-clock time that does not exist, or nil where the zone has no gap.

Spring forward skips an hour, so `os.time` silently normalises a time inside it
to a different instant -- and `os.date` then gives back a different string. That
is exactly the mismatch a clipping key has to survive.
]]
local function findDstGap()
    for month = 1, 12 do
        for day = 1, 28 do
            for hour = 0, 3 do
                local wanted = string.format("%04d-%02d-%02d %02d:30:00", 2026, month, day, hour)
                local epoch = os.time({
                    year = 2026, month = month, day = day,
                    hour = hour, min = 30, sec = 0,
                })
                if epoch and os.date("%Y-%m-%d %H:%M:%S", epoch) ~= wanted then
                    return wanted, epoch
                end
            end
        end
    end
    return nil
end

-- The contract the exporter relies on -----------------------------------------

check.section("What KOReader's exporter expects of a target")
do
    reset()
    check.eq(Target.name, "NeoDB", "the target is named")
    check.eq(Target.is_remote, true, "and declares that it goes over the network")
    check.eq(Target.shareable, nil, "and is not shareable, having nothing to share to")

    local menu = Target:getMenuTable()
    check.eq(type(menu.text), "string",
        "its menu row carries a plain string, since the exporter sorts on it")
    check.eq(type(menu.checked_func), "function", "and reports its own state")
end

check.section("Being enabled")
do
    reset()
    check.eq(Target:isEnabled(), false, "nothing is enabled before the plugin has attached")

    enable()
    check.eq(Target:isEnabled(), false,
        "and the switch alone is not enough, or a signed-out reader's Markdown "
        .. "export would raise a Wi-Fi prompt for us")

    newPlugin(newReaderUI(BOOK))
    check.eq(Target:isEnabled(), true, "switched on and signed in, it is enabled")

    Target.ctx.store:logout()
    check.eq(Target:isEnabled(), false, "signing out disables it again")
end

check.section("Consent is taken when the switch goes on")
do
    reset()
    newPlugin(newReaderUI(BOOK))

    Target:toggle()
    local box = Stubs.lastShown("ConfirmBox")
    check.ok(box ~= nil, "turning it on asks first")
    check.eq(Target:isEnabled(), false, "and does not turn on while the question stands")

    box:accept()
    check.eq(Target:isEnabled(), true, "answering yes turns it on")

    Target:toggle()
    check.eq(Target:isEnabled(), false, "turning it off asks nothing")
end

-- Exporting -------------------------------------------------------------------

check.section("Exporting an open book")
do
    reset()
    local annotations = {
        annotation("2026-08-01 09:00:00"),
        annotation("2026-08-01 10:00:00"),
    }
    local ui = newReaderUI(BOOK, { annotations = annotations, neodb_link = link() })
    local plugin = newPlugin(ui)
    Stubs.online = false -- keep the queue still, so it can be inspected

    local ok = Target:export({
        booknotes(BOOK, { epochOf("2026-08-01 09:00:00"), epochOf("2026-08-01 10:00:00") }),
    })
    check.eq(ok, true, "the export reports that it did the work")
    check.eq(plugin.store:queueCount(), 2, "both highlights are queued")

    local op = plugin.store:getQueue()[1]
    check.eq(op.path, "/api/me/note/item/item-1/", "as notes on the linked item")
    check.eq(op.annotation.file, BOOK, "tagged with the book they came from")

    -- The ledger is what stops a second export posting them again.
    local sent = plugin.store:getLink(ui.doc_settings).annotation_sync.sent
    check.ok(sent["2026-08-01 09:00:00"] ~= nil, "and recorded as sent")

    plugin.store:clearQueue()
    ok = Target:export({
        booknotes(BOOK, { epochOf("2026-08-01 09:00:00"), epochOf("2026-08-01 10:00:00") }),
    })
    check.eq(plugin.store:queueCount(), 0, "so exporting again posts nothing")
    check.eq(Stubs.lastNotification(), "NeoDB already has every highlight in there.",
        "and says so")
end

check.section("Exporting a book that is not open")
do
    reset()
    local other = "/books/messiah.epub"
    Stubs.newSidecar(other, {
        doc_pages = 300,
        annotations = { annotation("2026-08-02 09:00:00", { page = 150, pageno = 150 }) },
        neodb_link = link({ uuid = "item-2", title = "Messiah" }),
    })
    local plugin = newPlugin(newReaderUI(BOOK))
    Stubs.online = false

    local ok = Target:export({ booknotes(other, { epochOf("2026-08-02 09:00:00") }) })
    check.eq(ok, true, "a closed book is exported from its own sidecar")

    local op = plugin.store:getQueue()[1]
    check.eq(op.path, "/api/me/note/item/item-2/", "against its own item")
    check.eq(op.body.progress_type, "page",
        "and a numeric page means the file paginates for itself")
    check.eq(op.body.progress_value, "150", "so the annotation keeps its place")

    local sent = Stubs.sidecars[other].neodb_link.annotation_sync.sent
    check.ok(sent["2026-08-02 09:00:00"] ~= nil, "the ledger is written into that book")
end

check.section("Books that cannot be posted to")
do
    reset()
    local plugin = newPlugin(newReaderUI(BOOK))
    Stubs.online = false

    local ok = Target:export({ booknotes("/books/unknown.epub", { 1754038800 }) })
    check.eq(ok, false, "a book with no link is not something to report success for")
    check.eq(Stubs.lastNotification(), "None of those books are linked to NeoDB.",
        "and the reader is told why")
    check.eq(plugin.store:queueCount(), 0, "nothing is queued")

    -- Kindle's own My Clippings entries arrive with no file at all.
    ok = Target:export({ booknotes(nil, { 1754038800 }) })
    check.eq(ok, false, "a clipping with no file behind it is skipped")
end

check.section("A context that is no longer on screen")
do
    reset()
    local ui = newReaderUI(BOOK, { annotations = { annotation("2026-08-01 09:00:00") },
        neodb_link = link() })
    newPlugin(ui)
    UIManager:clearStack() -- the ReaderUI has been torn down

    local ok = Target:export({ booknotes(BOOK, { epochOf("2026-08-01 09:00:00") }) })
    check.eq(ok, false, "a torn-down context is refused")
    check.eq(Stubs.sidecars[BOOK].neodb_link.annotation_sync.sent, nil,
        "and nothing is written into a sidecar that is about to be overwritten")
end

check.section("A queue too full to take everything")
do
    reset()
    local annotations, times = {}, {}
    for i = 1, 120 do
        local stamp = string.format("2026-08-01 %02d:%02d:00", math.floor(i / 60), i % 60)
        table.insert(annotations, annotation(stamp))
        table.insert(times, epochOf(stamp))
    end
    local ui = newReaderUI(BOOK, { annotations = annotations, neodb_link = link() })
    local plugin = newPlugin(ui)
    Stubs.online = false

    local ok = Target:export({ booknotes(BOOK, times) })
    check.eq(ok, true, "what fits is still worth doing")
    check.eq(plugin.store:queueCount(), plugin.store:queueLimit(),
        "the queue takes what it can hold")

    local sent = plugin.store:getLink(ui.doc_settings).annotation_sync.sent
    local marked = 0
    for _key in pairs(sent) do marked = marked + 1 end
    check.eq(marked, plugin.store:queueLimit(),
        "and only what was accepted is recorded as sent")

    local told = Stubs.lastNotification() or ""
    check.ok(told:find("still to go", 1, true) ~= nil,
        "the reader is told there is more to come, since KOReader's own message cannot")

    -- Draining the queue and exporting again picks up exactly where it stopped.
    plugin.store:clearQueue()
    Target:export({ booknotes(BOOK, times) })
    check.eq(plugin.store:queueCount(), 20, "a second export queues exactly the remainder")
end

check.section("Clippings that cannot be matched up")
do
    reset()
    local ui = newReaderUI(BOOK, {
        annotations = { annotation("2026-08-01 09:00:00") },
        neodb_link = link(),
    })
    local plugin = newPlugin(ui)
    Stubs.online = false

    local notes = booknotes(BOOK, {})
    -- A clipping whose time did not parse: counted, never guessed at.
    table.insert(notes, { { text = "orphan", time = nil } })
    local ok = Target:export({ notes })
    check.eq(ok, true, "the target did what it could, so KOReader is not told it failed")
    check.eq(plugin.store:queueCount(), 0, "but nothing is queued on a guess")
    check.eq(Stubs.lastNotification(), "NeoDB: 1 highlight(s) could not be matched up.",
        "and the reader hears about the ones that were dropped, "
        .. "rather than being told everything is already there")
end

check.section("The spring-forward gap")
do
    local gap = findDstGap()
    if not gap then
        check.skip("this timezone has no DST gap to fall into")
    else
        reset()
        local ui = newReaderUI(BOOK, {
            annotations = { annotation(gap) },
            neodb_link = link(),
        })
        local plugin = newPlugin(ui)
        Stubs.online = false

        local epoch = epochOf(gap)
        check.ok(os.date("%Y-%m-%d %H:%M:%S", epoch) ~= gap,
            "a wall-clock time inside the gap does not survive the round trip")

        Target:export({ booknotes(BOOK, { epoch }) })
        check.eq(plugin.store:queueCount(), 0,
            "so the clipping matches no annotation and is skipped")

        local sent = plugin.store:getLink(ui.doc_settings).annotation_sync.sent
        check.eq(sent, nil,
            "and no invented key is written, which would post it again tomorrow")
    end
end

check.finish()
