--[[--
The plugin's own tests, run outside KOReader.

    cd spec && luajit harness.lua

Everything the modules decide for themselves is covered here: where the reader is
in a book, which annotations are outstanding, what the upload queue does when it
is full or when the server refuses, and what the menus offer. Anything that would
need a real screen or a real server is stubbed in `stubs.lua`.

@module spec.harness
]]

local Stubs = require("stubs")
local check = Stubs.check
local UIManager = Stubs.uimanager

local NeoDB = require("main")
local Actions = require("neodb_actions")
local Annotations = require("neodb_annotations")
local Api = require("neodb_api")
local Match = require("neodb_match")
local Store = require("neodb_store")
local Util = require("neodb_util")

-- Fixtures ---------------------------------------------------------------------

local INSTANCE = "https://neodb.social"
local BOOK = "/books/dune.epub"

local function reset()
    Stubs.reset()
    Stubs.settings_files = {}
    Stubs.sidecars = {}
    Stubs.docsettings_opens = 0
    Stubs.wifi_on = true
    Stubs.online = true
    Stubs.respond = nil
    UIManager:clearTasks()
    UIManager:clearStack()
end

--[[--
A ReaderUI good enough for this plugin.

`opts.paging` makes it a fixed-layout document, which is the discriminator every
progress decision turns on; `opts.labels` gives it publisher page numbers.
]]
local function newReaderUI(opts)
    opts = opts or {}
    local file = opts.file or BOOK
    local doc_settings = Stubs.newSidecar(file, opts.sidecar or {
        doc_pages = opts.pages or 400,
        percent_finished = opts.percent,
    })

    local ui = {
        document = {
            file = file,
            getPageCount = function() return opts.pages or 400 end,
            getProps = function() return opts.props or {} end,
        },
        doc_settings = doc_settings,
        doc_props = opts.doc_props or { title = "Dune", authors = "Frank Herbert" },
        annotation = { annotations = opts.annotations or {} },
        paging = opts.paging,
        menu = { registerToMainMenu = function() end },
        highlight = {
            addToHighlightDialog = function(self, id, fn)
                self.buttons = self.buttons or {}
                self.buttons[id] = fn
            end,
        },
    }
    function ui:getCurrentPage() return opts.page or 100 end

    -- The footer's own live percentage, which is what KOReader shows and what
    -- the sidecar only catches up with when it is saved.
    if opts.footer_percent then
        ui.view = { footer = { percent_finished = opts.footer_percent } }
    end

    if opts.labels then
        ui.pagemap = {
            wantsPageLabels = function() return true end,
            getCurrentPageLabel = function() return opts.labels end,
        }
    end
    return ui
end

--- A plugin instance, signed in unless told otherwise.
local function newPlugin(opts)
    opts = opts or {}
    local ui = opts.ui or newReaderUI(opts)
    local plugin = NeoDB:new{ ui = ui }
    if opts.signed_out ~= true then
        plugin.store:setInstance(INSTANCE)
        plugin.store:setToken("token-1")
    end
    -- The window stack is what "is the reader mid-something?" is read from.
    UIManager:show(ui)
    return plugin, ui
end

local function linkBook(plugin, fields)
    local link = {
        uuid  = "item-1",
        title = "Dune",
        url   = INSTANCE .. "/book/item-1",
        pages = 400,
    }
    for k, v in pairs(fields or {}) do link[k] = v end
    plugin.store:setLink(plugin.ui.doc_settings, link)
    return link
end

--[[--
Field value meaning "this annotation does not have that field".

`pairs` skips a nil value, so `annotation{ drawer = nil }` would quietly keep the
default and test nothing. Every "field is absent" case here is one the plugin
decides on, so absence needs to be sayable.
]]
local NONE = setmetatable({}, { __tostring = function() return "NONE" end })

local function annotation(fields)
    local a = {
        datetime = "2026-07-01 10:00:00",
        text     = "The spice must flow.",
        chapter  = "Chapter One",
        pageno   = 100,
        drawer   = "lighten",
    }
    for k, v in pairs(fields or {}) do
        if v == NONE then a[k] = nil else a[k] = v end
    end
    return a
end

--- Replaces the API's one network entry point with a recorder.
local function recordCalls(api, answer)
    local calls = {}
    api.call = function(_self, method, path, opts)
        table.insert(calls, { method = method, path = path, body = opts and opts.json })
        if answer then return answer(#calls, path) end
        return true, { uuid = "note-" .. #calls }, 200
    end
    return calls
end

-- Util --------------------------------------------------------------------------

check.section("Util")
do
    check.eq(Util.ellipsize("abcdefghij", 5), "abcd…",
        "ellipsize keeps max-1 characters and adds the ellipsis")
    check.eq(Util.ellipsize("abcde", 5), "abcde", "ellipsize leaves a text that fits")
    check.eq(Util.stars(7), "★★★½", "seven of ten is three and a half stars")
    check.eq(Util.stars(0), nil, "an unrated book has no stars")
    check.eq(Util.ratingLabel(0), "No rating", "and says so in words")

    check.eq(Util.normalizeInstance("neodb.social"), "https://neodb.social",
        "a bare host gets a scheme")
    check.eq(Util.normalizeInstance("https://neodb.social/users/me/"), "https://neodb.social",
        "a pasted path is dropped")
    check.eq(Util.normalizeInstance("localhost"), nil, "a bare word is refused")
    check.eq(Util.normalizeInstance("localhost:8000"), "https://localhost:8000",
        "but host:port is allowed, for a LAN instance")

    check.eq(Util.postVisibilityFor(0), "public", "level 0 posts publicly")
    check.eq(Util.postVisibilityFor(1), "private", "level 1 is Mastodon's followers-only")
    check.eq(Util.postVisibilityFor(2), "direct", "level 2 is Mastodon's mentioned-only")

    check.eq(Util.findISBN("isbn 978-0-441-01359-3"), "9780441013593",
        "a hyphenated ISBN-13 is found")
    check.eq(Util.findISBN("9780441013590"), nil, "a bad checksum is refused")
    check.eq(Util.absoluteUrl(INSTANCE, "/book/x"), INSTANCE .. "/book/x",
        "a catalog path is resolved against the instance")
end

-- Store -------------------------------------------------------------------------

check.section("Store")
do
    reset()
    local store = Store:new()
    check.eq(store:get("default_visibility"), 0, "posts default to public")
    check.eq(store:get("auto_progress"), false, "automatic progress is off until asked for")
    check.eq(store:get("quote_as_blockquote"), true, "quotes are block quotes by default")

    -- The rename: whoever had the old switch on meant "keep NeoDB current".
    reset()
    Stubs.settings_files["/tmp/neodb-spec/settings/neodb.lua"] = { auto_progress_on_close = true }
    local migrated = Store:new()
    check.eq(migrated:get("auto_progress"), true, "the old close-only switch carries over")
    check.eq(migrated.settings:readSetting("auto_progress_on_close"), nil,
        "and the old key is removed")

    --[[--
    Automatic progress is per book now, and the global is what a new one starts
    with. A link made before the question was asked carries no answer, so it goes
    on following that global until its own switch is touched -- otherwise every
    book somebody had already linked would go quiet on upgrade, with no dialog
    coming to ask, since the dialog only follows a fresh link.
    ]]
    reset()
    store = Store:new()
    check.eq(store:autoProgress({ uuid = "x" }), false,
        "a link with no answer follows the global default")
    store:set("auto_progress", true)
    check.eq(store:autoProgress({ uuid = "x" }), true, "including when that default is on")
    check.eq(store:autoProgress({ uuid = "x", auto_progress = false }), false,
        "but a book that has answered outranks it")
    check.eq(store:autoProgress(nil), false, "and no link at all is not a book to report on")

    reset()
    store = Store:new()
    store:enqueue({ label = "a", dedup = "x" })
    store:enqueue({ label = "b" })
    store:enqueue({ label = "c", dedup = "x" })
    local queue = store:getQueue()
    check.eq(#queue, 2, "a superseding op does not lengthen the queue")
    check.eq(queue[1].label, "c", "it takes the slot of the one it replaces")
    check.eq(queue[2].label, "b", "so the order of everything else is kept")

    check.eq(store:removeByDedup("x"), true, "a waiting op can be pulled back out")
    check.eq(store:queueCount(), 1, "and is gone from the queue")

    reset()
    store = Store:new()
    local batch = {}
    for i = 1, store:queueLimit() + 20 do
        table.insert(batch, { label = "note " .. i })
    end
    check.eq(store:enqueueAll(batch), store:queueLimit(),
        "a batch too big for the queue is accepted as far as it fits")
    check.eq(store:queueCount(), store:queueLimit(), "and the queue stops at its cap")
    check.eq(store:getQueue()[1].label, "note 1",
        "the head is kept, so what was refused is the tail")

    --[[--
    A full queue must refuse the newcomer rather than make room for it. The op at
    the head may be a highlight already recorded as sent in its book's ledger, and
    nothing ever retries one of those -- whereas a refusal is something the caller
    can act on and the reader can be told about.
    ]]
    check.eq(store:enqueue({ label = "one too many" }), false,
        "a full queue refuses another op")
    check.eq(store:getQueue()[1].label, "note 1", "and does not evict the one at the head")
    check.eq(store:queueCount(), store:queueLimit(), "so the queue is unchanged")

    check.eq(store:enqueue({ label = "newer note 1", dedup = "d" }), false,
        "a full queue with nothing to supersede still refuses")
    store:replaceQueue({ { label = "a", dedup = "d" } })
    check.eq(store:enqueue({ label = "b", dedup = "d" }), true,
        "but superseding one already waiting always fits")
    check.eq(store:queueCount(), 1, "since it takes a slot rather than adding one")
end

check.section("Store: the book link")
do
    reset()
    local store = Store:new()
    store:setInstance(INSTANCE)
    local sidecar = Stubs.newSidecar(BOOK, {})

    store:setLink(sidecar, { uuid = "item-1", title = "Dune" })
    local link = store:getLink(sidecar)
    check.eq(link.uuid, "item-1", "a link is read back")
    check.eq(link.instance, INSTANCE, "stamped with the instance it came from")
    check.ok(link.annotation_sync ~= nil and link.annotation_sync.since ~= nil,
        "and always with a starting point for the highlight mirror")
    check.eq(link.annotation_sync.enabled, false,
        "which starts from the global preference, off by default")

    store:setInstance("https://other.example")
    local none, foreign = store:getLink(sidecar)
    check.eq(none, nil, "a link made on another instance does not count as linked")
    check.eq(foreign.uuid, "item-1", "but is reported, so the reader can be told why")
end

-- Reading position ---------------------------------------------------------------

check.section("Reading position")
do
    reset()
    local plugin = newPlugin{ paging = true, page = 100, pages = 400 }
    local kind, value, total = Actions.readingPosition(plugin.ctx)
    check.eq(kind, "page", "a fixed-layout file reports its own page numbers")
    check.eq(value, "100", "as the page the reader is on")
    check.eq(total, 400, "with the count, for display")

    reset()
    plugin = newPlugin{ page = 100, pages = 400, percent = 0.25 }
    kind, value = Actions.readingPosition(plugin.ctx)
    check.eq(kind, "percentage", "a reflowable file reports a percentage instead")
    check.eq(value, "25", "rounded to a whole one")

    kind, value = Actions.readingPosition(plugin.ctx, "page")
    check.eq(kind, "page", "unless a unit is forced")
    check.eq(value, "100", "in which case the page is used as it stands")

    reset()
    plugin = newPlugin{ page = 100, pages = 400, percent = 0.25, labels = "xii" }
    local label_total
    kind, value, label_total = Actions.readingPosition(plugin.ctx)
    check.eq(kind, "page", "publisher page numbers win over a percentage")
    check.eq(value, "xii", "and are sent as printed")
    check.eq(label_total, nil,
        "with no total, since the only count we have is KOReader's own and "
        .. "“page xii of 400” puts two different numberings either side of “of”")

    check.eq(Actions.positionLabel("percentage", "25"), "25%", "a percentage reads as one")
    check.eq(Actions.positionLabel("page", "100", 400), "page 100 of 400",
        "a page says what it is out of")
    check.eq(Actions.positionLabel("page", "xii"), "page xii",
        "and drops the total when there is none")
end

check.section("Progress while the book is still open")
do
    --[[--
    KOReader writes percent_finished to the sidecar only when it saves settings,
    so during a session that number is as old as the last autosave, and never
    changes at all for a reader who saves only on close. Reporting from it made
    the hourly update decide, all session, that nothing had moved.
    ]]
    reset()
    local plugin = newPlugin{ page = 100, pages = 400, percent = 0.10, footer_percent = 0.25 }
    local _kind, value = Actions.readingPosition(plugin.ctx)
    check.eq(value, "25", "the live position wins over the one last written to disk")

    reset()
    plugin = newPlugin{ page = 100, pages = 400, percent = 0.10 }
    _kind, value = Actions.readingPosition(plugin.ctx)
    check.eq(value, "10", "with no live one, the sidecar answers")

    reset()
    plugin = newPlugin{ page = 100, pages = 400 }
    _kind, value = Actions.readingPosition(plugin.ctx)
    check.eq(value, "25", "and failing that, the page count does")

    -- Which is the whole point of the hourly update.
    reset()
    plugin = newPlugin{ page = 100, pages = 400, percent = 0.10, footer_percent = 0.10 }
    linkBook(plugin, { auto_progress = true })
    plugin.store:cacheMark(plugin.ui.doc_settings, { shelf_type = "progress" })
    Stubs.online = false

    check.eq(plugin:queueProgressIfMoved(), true, "the first tick reports where the reader is")
    plugin.store:clearQueue()
    check.eq(plugin:queueProgressIfMoved(), false, "a tick after no reading reports nothing")

    plugin.ui.view.footer.percent_finished = 0.20
    check.eq(plugin:queueProgressIfMoved(), true,
        "but reading on is noticed, though the sidecar has not been written since")
    check.eq(plugin.store:getQueue()[1].body.value, "20", "at the position now reached")
end

check.section("Where an annotation sits")
do
    reset()
    local plugin = newPlugin{ page = 300, pages = 400, percent = 0.75 }
    local kind, value = Actions.annotationPosition(plugin.ctx, annotation{ pageno = 100 })
    check.eq(kind, "percentage", "an annotation is placed in the book's own unit")
    check.eq(value, "25", "at its own position, not wherever the reader has got to")

    -- A book that is not open answers from what it wrote down.
    local closed = { live = false, pages = 400 }
    kind, value = Actions.annotationPosition(plugin.ctx,
        annotation{ pageno = 100, page = 100 }, closed)
    check.eq(kind, "page", "a numeric page means the file paginates for itself")
    check.eq(value, "100", "so its page number travels")

    kind = Actions.annotationPosition(plugin.ctx,
        annotation{ pageno = 100, page = "/body/DocFragment[3]", pageref = "[3]1" }, closed)
    check.eq(kind, "percentage",
        "a bracketed flow label is refused rather than posted as a page number")

    kind = Actions.annotationPosition(plugin.ctx,
        annotation{ pageno = NONE, page = NONE }, closed)
    check.eq(kind, nil, "an annotation that cannot be placed gets no position at all")
end

-- The highlight mirror ------------------------------------------------------------

check.section("Annotations: the per-book switch")
do
    reset()
    local plugin = newPlugin()
    check.eq(Annotations.isEnabled(plugin.ctx), false, "an unlinked book mirrors nothing")

    linkBook(plugin)
    check.eq(Annotations.setEnabled(plugin.ctx, true), true, "the switch goes on")
    local link = plugin.store:getLink(plugin.ui.doc_settings)
    local since = link.annotation_sync.since
    check.ok(since ~= nil, "and stamps when it was turned on")
    check.eq(Annotations.isEnabled(plugin.ctx), true, "which is what isEnabled reports")

    Annotations.setEnabled(plugin.ctx, false)
    Annotations.setEnabled(plugin.ctx, true)
    link = plugin.store:getLink(plugin.ui.doc_settings)
    check.ok(link.annotation_sync.since >= since,
        "turning it off and on again re-stamps, so a backlog is never emptied by a switch")
end

check.section("Annotations: what is outstanding")
do
    reset()
    local plugin, ui = newPlugin{
        annotations = {
            annotation{ datetime = "2026-06-01 09:00:00", text = "old" },
            annotation{ datetime = "2026-08-01 09:00:00", text = "new" },
            annotation{ datetime = "2026-08-01 09:30:00", text = "", note = "" },
            annotation{ datetime = "2026-08-01 10:00:00", text = "mid-drag", is_tmp = true },
            annotation{ datetime = "2026-08-01 11:00:00", text = "bookmark", drawer = NONE },
        },
    }
    linkBook(plugin, { annotation_sync = { enabled = true, since = "2026-07-01 00:00:00" } })

    local queued = Annotations.queueNew(plugin.ctx)
    check.eq(queued, 1, "only the highlight made after the switch went on is queued")

    local op = plugin.store:getQueue()[1]
    check.eq(op.method, "POST", "as a note")
    check.eq(op.path, "/api/me/note/item/item-1/", "on the linked item")
    check.eq(op.body.content, "> new", "with the passage quoted")
    check.eq(op.body.title, "Chapter One", "titled with the chapter it came from")
    check.eq(op.annotation.key, "2026-08-01 09:00:00", "tagged with the annotation it came from")
    check.eq(op.annotation.file, ui.document.file, "and with the book, so the reply can be filed")

    check.eq(Annotations.queueNew(plugin.ctx), 0, "a second round has nothing left to do")

    -- The repair path: a switch that is on with nothing to measure against would
    -- treat the whole book as new.
    local link = plugin.store:getLink(ui.doc_settings)
    link.annotation_sync.since = nil
    plugin.store:setLink(ui.doc_settings, link)
    check.eq(Annotations.queueNew(plugin.ctx), 0, "a missing start point posts nothing")
    link = plugin.store:getLink(ui.doc_settings)
    check.ok(link.annotation_sync.since ~= nil, "and is stamped for next time")
end

check.section("Sharing a highlight by hand")
do
    --[[--
    The highlight menu is reachable for an annotation the book already holds,
    through the edit dialog's "…" button, which hands the button factory the
    annotation's index. So the composer and the mirror can be looking at the same
    highlight, and only the ledger keeps one of them from posting it twice.
    ]]
    reset()
    local plugin, ui = newPlugin{
        annotations = { annotation{ datetime = "2026-08-01 09:00:00" } },
    }
    linkBook(plugin, { annotation_sync = { enabled = true, since = "2026-07-01 00:00:00" } })
    Stubs.online = false

    local factory = ui.highlight.buttons["13_neodb_quote"]
    check.ok(factory ~= nil, "the highlight menu offers sharing")

    local button = factory({
        selected_text = { text = "The spice must flow." },
        onClose = function() end,
    }, 1)
    button.callback()

    local dialog = Stubs.lastShown("InputDialog")
    check.eq(dialog.title, "Share a quote", "the composer opens with the passage")
    dialog:press("Post")

    check.eq(plugin.store:queueCount(), 1, "the note is queued")
    local op = plugin.store:getQueue()[1]
    check.eq(op.annotation and op.annotation.key, "2026-08-01 09:00:00",
        "tagged with the annotation it came from, so its uuid can be filed")

    check.eq(Annotations.queueNew(plugin.ctx), 0,
        "and the mirror does not post the same highlight a second time")

    -- A fresh selection is not an annotation yet, so there is nothing to record.
    reset()
    plugin, ui = newPlugin()
    linkBook(plugin)
    Stubs.online = false
    -- Refetched: the factory closes over the plugin that registered it.
    factory = ui.highlight.buttons["13_neodb_quote"]
    button = factory({
        selected_text = { text = "A passage nobody highlighted." },
        onClose = function() end,
    }, nil)
    button.callback()
    Stubs.lastShown("InputDialog"):press("Post")
    check.eq(plugin.store:getQueue()[1].annotation, nil,
        "sharing a bare selection tags nothing")

    -- A refusal must not leave the highlight recorded as posted.
    reset()
    plugin, ui = newPlugin{ annotations = { annotation{ datetime = "2026-08-01 09:00:00" } } }
    linkBook(plugin, { annotation_sync = { enabled = true, since = "2026-07-01 00:00:00" } })
    recordCalls(plugin.api, function() return false, "forbidden", 403 end)
    factory = ui.highlight.buttons["13_neodb_quote"]
    button = factory({ selected_text = { text = "x" }, onClose = function() end }, 1)
    button.callback()
    Stubs.lastShown("InputDialog"):press("Post")
    check.eq(Annotations.queueNew(plugin.ctx), 1,
        "a note the server refused is left for the mirror to try again")
end

check.section("Annotations: uploading the backlog")
do
    reset()
    local plugin = newPlugin{
        annotations = {
            annotation{ datetime = "2026-06-01 09:00:00", text = "old" },
            annotation{ datetime = "2026-08-01 09:00:00", text = "new" },
        },
    }
    linkBook(plugin, { annotation_sync = { enabled = false, since = "2026-07-01 00:00:00" } })
    Stubs.online = false -- so the queue is not drained out from under the check

    Annotations.uploadAll(plugin.ctx)
    check.eq(plugin.store:queueCount(), 2,
        "uploading everything ignores the cutoff, and the switch being off")

    reset()
    plugin = newPlugin{ annotations = {} }
    linkBook(plugin)
    Annotations.uploadAll(plugin.ctx)
    check.eq(Stubs.lastNotification(), "NeoDB already has every highlight in this book.",
        "a book with nothing outstanding says so")
end

check.section("Annotations: filing the uuid a note comes back with")
do
    -- The book is open: its own live sidecar takes the uuid.
    reset()
    local plugin, ui = newPlugin()
    linkBook(plugin)
    Annotations.recordSent(plugin.ctx,
        { annotation = { item = "item-1", key = "k1", file = BOOK } },
        { uuid = "note-9" })
    local link = plugin.store:getLink(ui.doc_settings)
    check.eq(link.annotation_sync.sent.k1.uuid, "note-9", "a live book records it directly")
    check.eq(Stubs.docsettings_opens, 1,
        "and no second DocSettings is opened for a book KOReader already has open")

    -- A different book, merely closed: its own sidecar is opened and written.
    reset()
    plugin = newPlugin()
    local other = "/books/messiah.epub"
    local other_settings = Stubs.newSidecar(other, {})
    plugin.store:setLink(other_settings, { uuid = "item-2", title = "Messiah" })
    Annotations.recordSent(plugin.ctx,
        { annotation = { item = "item-2", key = "k2", file = other } },
        { uuid = "note-8" })
    local stored = Stubs.sidecars[other].neodb_link
    check.eq(stored.annotation_sync.sent.k2.uuid, "note-8",
        "a closed book is written through its own sidecar")

    -- Nowhere to put it: the stash holds it until that book turns up again.
    reset()
    plugin = newPlugin()
    Annotations.recordSent(plugin.ctx,
        { annotation = { item = "item-3", key = "k3", file = "/books/gone.epub" } },
        { uuid = "note-7" })
    local stash = plugin.store:get("pending_note_uuids")
    check.eq(#stash, 1, "a book that has moved or gone leaves the uuid stashed")
    check.eq(stash[1].uuid, "note-7", "with the uuid intact")

    -- ...and it is adopted when that book is opened.
    local ui2 = newReaderUI{ file = "/books/gone.epub" }
    local plugin2 = NeoDB:new{ ui = ui2 }
    plugin2.store:setLink(ui2.doc_settings, { uuid = "item-3", title = "Gone" })
    check.eq(Annotations.adoptStashed(plugin2.ctx), 1, "opening that book adopts it")
    local link2 = plugin2.store:getLink(ui2.doc_settings)
    check.eq(link2.annotation_sync.sent.k3.uuid, "note-7", "into its own ledger")
    check.eq(#plugin2.store:get("pending_note_uuids"), 0, "and the stash is emptied")
end

check.section("Annotations: deletions")
do
    -- Delivered, so there is a uuid to delete on the server.
    reset()
    local plugin = newPlugin{ annotations = {} }
    linkBook(plugin, {
        annotation_sync = {
            enabled = true,
            since = "2026-07-01 00:00:00",
            sent = { ["2026-08-01 09:00:00"] = { uuid = "note-5", at = "2026-08-01 09:00:10" } },
        },
    })
    check.eq(Annotations.queueDeletions(plugin.ctx), 1, "a deleted highlight is deleted on NeoDB")
    local op = plugin.store:getQueue()[1]
    check.eq(op.method, "DELETE", "with a DELETE")
    check.eq(op.path, "/api/me/note/note-5", "against the note's own uuid")

    -- Still queued, so the post is pulled instead of being posted and deleted.
    reset()
    plugin = newPlugin{ annotations = {} }
    linkBook(plugin, {
        annotation_sync = {
            enabled = true,
            since = "2026-07-01 00:00:00",
            sent = { ["2026-08-01 09:00:00"] = true },
        },
    })
    plugin.store:enqueue({ label = "pending note", dedup = "annotation:item-1:2026-08-01 09:00:00" })
    check.eq(Annotations.queueDeletions(plugin.ctx), 0, "one still waiting needs no server call")
    check.eq(plugin.store:queueCount(), 0, "its pending post is pulled back out of the queue")

    -- Still present, so nothing happened.
    reset()
    plugin = newPlugin{ annotations = { annotation{ datetime = "2026-08-01 09:00:00" } } }
    linkBook(plugin, {
        annotation_sync = {
            enabled = true,
            since = "2026-07-01 00:00:00",
            sent = { ["2026-08-01 09:00:00"] = { uuid = "note-5" } },
        },
    })
    check.eq(Annotations.queueDeletions(plugin.ctx), 0, "an annotation still in the book is left alone")

    -- The switch is off, so NeoDB is not being kept in step with this book.
    reset()
    plugin = newPlugin{ annotations = {} }
    linkBook(plugin, {
        annotation_sync = {
            enabled = false,
            sent = { ["2026-08-01 09:00:00"] = { uuid = "note-5" } },
        },
    })
    check.eq(Annotations.queueDeletions(plugin.ctx), 0, "with the switch off, nothing is deleted")

    -- A queue with no room must leave the deletion to be noticed again.
    reset()
    plugin = newPlugin{ annotations = {} }
    linkBook(plugin, {
        annotation_sync = {
            enabled = true,
            since = "2026-07-01 00:00:00",
            sent = { ["2026-08-01 09:00:00"] = { uuid = "note-5" } },
        },
    })
    local filler = {}
    for i = 1, plugin.store:queueLimit() do table.insert(filler, { label = "filler " .. i }) end
    plugin.store:enqueueAll(filler)
    check.eq(Annotations.queueDeletions(plugin.ctx), 0, "a full queue takes no deletion")
    local ledger = plugin.store:getLink(plugin.ui.doc_settings).annotation_sync.sent
    check.ok(ledger["2026-08-01 09:00:00"] ~= nil,
        "and the ledger entry stays, so the deletion is not forgotten")

    -- No list at all must mean stop, not "the reader deleted everything".
    reset()
    plugin = newPlugin()
    plugin.ui.annotation.annotations = nil
    linkBook(plugin, {
        annotation_sync = {
            enabled = true,
            sent = { ["2026-08-01 09:00:00"] = { uuid = "note-5" } },
        },
    })
    check.eq(Annotations.queueDeletions(plugin.ctx), 0,
        "a missing annotation list deletes nothing")
end

-- Marks ----------------------------------------------------------------------------

check.section("Marks keep what the reader did not touch")
do
    reset()
    local plugin = newPlugin()
    local link = linkBook(plugin, {
        mark = {
            shelf_type = "progress",
            rating_grade = 8,
            comment_text = "Excellent.",
            tags = { "sf" },
            visibility = 1,
        },
    })

    local body = Actions.markBody(plugin.ctx, link, { shelf_type = "complete" })
    check.eq(body.shelf_type, "complete", "the status changes")
    check.eq(body.rating_grade, 8, "the rating is resent untouched")
    check.eq(body.comment_text, "Excellent.", "so is the comment")
    check.eq(body.visibility, 1, "and the visibility it was saved with")
    check.eq(#body.tags, 1, "tags are resent as a list")

    body = Actions.markBody(plugin.ctx, link, { shelf_type = "complete", rating_grade = 0 })
    check.eq(body.rating_grade, 0, "but a rating cleared on purpose is cleared")

    body = Actions.markBody(plugin.ctx, { uuid = "x" }, { shelf_type = "wishlist" })
    check.eq(body.tags, nil,
        "with no tags to resend the field is omitted, not sent as an empty object")
end

check.section("A mark that will not fit in the queue")
do
    reset()
    local plugin = newPlugin()
    linkBook(plugin, { mark_checked = "2026-08-01 00:00:00" })
    Stubs.online = false

    local filler = {}
    for i = 1, plugin.store:queueLimit() do table.insert(filler, { label = "filler " .. i }) end
    plugin.store:enqueueAll(filler)

    Actions.setShelf(plugin.ctx, "complete")
    check.ok((Stubs.lastAlert() or ""):find("waiting", 1, true) ~= nil,
        "a status the queue could not take is reported as such, not as saved")
    check.eq(plugin.store:getLink(plugin.ui.doc_settings).mark, nil,
        "and is not cached as though it had gone")
end

check.section("A mark this device has never been told about")
do
    --[[--
    Posting a mark replaces it, so the fields the reader did not touch are resent
    from the cache. A link whose first fetch failed, or one made by a version that
    did not cache, has no cache to resend from -- and would post an empty comment
    and no rating over whatever is actually on NeoDB.
    ]]
    reset()
    local plugin = newPlugin()
    linkBook(plugin) -- linked, but nothing known about the mark
    local calls = recordCalls(plugin.api, function(_nth, path)
        if path:find("/progress") then return true, {}, 200 end
        return true, {
            shelf_type = "progress", rating_grade = 9,
            comment_text = "Read it twice.", visibility = 0,
        }, 200
    end)

    Actions.setShelf(plugin.ctx, "complete")
    check.eq(calls[1].method, "GET", "the mark is read before it is written")
    check.eq(calls[2].method, "POST", "and only then posted")
    check.eq(calls[2].body.rating_grade, 9, "with the rating NeoDB already held")
    check.eq(calls[2].body.comment_text, "Read it twice.", "and the comment")
    check.eq(calls[2].body.shelf_type, "complete", "while the status is the one asked for")

    -- Knowing there is no mark is knowing enough: an unmarked book must not pay
    -- for a request on every status tap.
    reset()
    plugin = newPlugin()
    linkBook(plugin)
    calls = recordCalls(plugin.api, function() return true, nil, 404 end)
    Actions.setShelf(plugin.ctx, "wishlist")
    local reads = 0
    for _idx, call in ipairs(calls) do
        if call.method == "GET" then reads = reads + 1 end
    end
    check.eq(reads, 1, "the first write on an unknown mark reads it")

    calls = recordCalls(plugin.api, function() return true, {}, 200 end)
    Actions.setShelf(plugin.ctx, "complete")
    check.eq(calls[1].method, "POST",
        "and a second write goes straight out, knowing there was nothing to keep")

    -- Offline there is no way to find out, so the reader is asked.
    reset()
    plugin = newPlugin()
    linkBook(plugin)
    Stubs.online = false
    Actions.setShelf(plugin.ctx, "complete")
    local box = Stubs.lastShown("ConfirmBox")
    check.ok(box ~= nil, "offline, a write that could replace an unread mark asks first")
    check.eq(plugin.store:queueCount(), 0, "and queues nothing while the question stands")
    box:accept()
    check.eq(plugin.store:queueCount(), 1, "answering yes queues the mark")
end

-- Automatic progress -----------------------------------------------------------------

check.section("Automatic progress")
do
    reset()
    local plugin = newPlugin{ paging = true, page = 100, pages = 400 }
    linkBook(plugin, { auto_progress = false })
    check.eq(plugin:queueProgressIfMoved(), false, "nothing is sent while the switch is off")

    --[[--
    And the switch is this book's, not the device's: a global left on does not
    speak for a book that has answered the question itself.
    ]]
    plugin.store:set("auto_progress", true)
    check.eq(plugin:queueProgressIfMoved(), false,
        "not even with the default for new books on, once this one has said no")

    plugin.store:setAutoProgress(plugin.ui.doc_settings, true)
    check.eq(plugin:queueProgressIfMoved(), false,
        "nor for a book with no mark, since progress hangs off one")

    plugin.store:cacheMark(plugin.ui.doc_settings, { shelf_type = "progress" })
    check.eq(plugin:queueProgressIfMoved(), true, "a marked book reports its position")
    local op = plugin.store:getQueue()[1]
    check.eq(op.path, "/api/me/shelf/item/item-1/progress", "to the progress endpoint")
    check.eq(op.body.value, "100", "with the page it is on")
    check.eq(op.dedup, "progress:item-1", "keyed so a later position supersedes it")

    check.eq(plugin:queueProgressIfMoved(), false, "and nothing more while it has not moved")

    -- The hourly clock reschedules itself before doing anything, so one bad tick
    -- cannot stop it.
    reset()
    plugin = newPlugin{ paging = true, page = 100, pages = 400 }
    UIManager:clearTasks()
    plugin:progressTick()
    check.eq(UIManager:scheduledCount(plugin.progress_task), 1, "a tick schedules the next one")

    plugin:onCloseDocument()
    check.eq(UIManager:scheduledCount(plugin.progress_task), 0,
        "and closing the book stops the clock")
end

check.section("What a new link is asked about")
do
    --[[--
    Linking a book ends in one dialog with three answers on it, and the reason
    they are together is that two of them are worthless without the first: a book
    on no shelf cannot report progress, so a status asked for separately, later,
    is how the switches end up on and silent.
    ]]
    reset()
    local plugin = newPlugin{ paging = true, page = 100, pages = 400 }
    Stubs.respond = function(request)
        if request.method == "GET" then
            return 200, {}, '{"shelf_type":"progress","rating_grade":8,"comment_text":"good"}'
        end
        return 200, {}, "{}"
    end
    Match.linkTo(plugin.ctx, { uuid = "item-1", title = "Dune", url = "/book/item-1" })

    local dialog = Stubs.lastShown("ButtonDialog")
    check.ok(dialog ~= nil, "linking opens the dialog rather than an alert")
    check.eq(dialog.dismissable, false, "which cannot be tapped away, since a status is the point")
    check.ok(dialog.title:find("On NeoDB: Reading", 1, true) ~= nil,
        "and it opens on what the server already holds")
    check.eq(dialog:label("shelf_progress"), "✓ Reading", "with that shelf preselected")
    check.eq(dialog:label("auto_progress"), "Update progress: off",
        "both switches showing the default for a new book")
    check.eq(dialog:label("upload"), "Upload highlights: off")

    -- Saving what the server already said posts nothing: a re-marked book is a
    -- request and a notification for no change at all.
    dialog:press("save")
    check.eq(plugin.store:queueCount(), 0, "saving an unchanged status writes no mark")
    local link = plugin.store:getLink(plugin.ui.doc_settings)
    check.eq(link.auto_progress, false,
        "but the answer is pinned, so a later change of default leaves this book alone")

    --[[--
    A book NeoDB has never heard of still leaves the dialog on a shelf, and the
    two switches open whichever way the defaults say -- which is all those globals
    do now.
    ]]
    reset()
    plugin = newPlugin{ paging = true, page = 100, pages = 400 }
    plugin.store:set("auto_progress", true)
    plugin.store:set("auto_upload_annotations", true)
    Stubs.respond = function(request)
        if request.method == "GET" then return 404, {}, "{}" end
        return 200, {}, "{}"
    end
    Match.linkTo(plugin.ctx, { uuid = "item-1", title = "Dune", url = "/book/item-1" })
    dialog = Stubs.lastShown("ButtonDialog")
    check.ok(dialog.title:find("Not on any NeoDB shelf yet", 1, true) ~= nil,
        "an unmarked book says so")
    check.eq(dialog:label("shelf_progress"), "✓ Reading",
        "and still opens on Reading, which is what linking a book usually means")

    check.eq(dialog:label("auto_progress"), "Update progress: on",
        "the switches open whichever way the defaults say")
    check.eq(dialog:label("upload"), "Upload highlights: on")

    dialog:press("shelf_complete")
    check.eq(dialog:label("shelf_complete"), "✓ Finished", "picking another moves the tick")
    check.eq(dialog:label("shelf_progress"), "Reading", "off the one that had it")

    dialog:press("auto_progress")
    check.eq(dialog:label("auto_progress"), "Update progress: off",
        "a switch says which way it is, since a tick alone cannot say “off”")
    dialog:press("auto_progress")
    check.eq(dialog:label("auto_progress"), "Update progress: on", "and turns back")
    dialog:press("upload")
    check.eq(dialog:label("upload"), "Upload highlights: off")

    check.eq(plugin.store:getLink(plugin.ui.doc_settings).auto_progress, nil,
        "and nothing is written while the reader is still deciding")

    Stubs.online = false -- so the mark stays in the queue to be looked at
    dialog:press("save")
    link = plugin.store:getLink(plugin.ui.doc_settings)
    check.eq(link.auto_progress, true,
        "Save records the switches on the book, the ones left alone included")
    check.eq(link.annotation_sync.enabled, false, "and the one that was changed")
    check.eq(plugin.store:getQueue()[1].body.shelf_type, "complete",
        "and marks it with the status that was chosen")

    -- Which is what makes the defaults only defaults: this book has answered now.
    plugin.store:set("auto_progress", false)
    check.eq(plugin.store:autoProgress(plugin.store:getLink(plugin.ui.doc_settings)), true,
        "and a later change of default does not reach back into it")
end

check.section("Offering a link when a book opens")
do
    --[[--
    The one thing here that speaks before it is spoken to, so most of what is
    checked is the not-speaking: every reason to stay quiet, and the record that
    keeps it quiet afterwards.
    ]]
    reset()
    local plugin = newPlugin()
    plugin.store:set("offer_link_on_open", false)
    check.eq(Match.offerLink(plugin.ctx), false, "nothing is offered while the option is off")
    check.eq(plugin.store:linkOffered(plugin.ui.doc_settings), false,
        "and staying quiet is not the same as having asked")

    reset()
    plugin = newPlugin{ signed_out = true }
    check.eq(Match.offerLink(plugin.ctx), false,
        "nor to a signed-out reader, who would only meet a sign-in wall")
    check.eq(plugin.store:linkOffered(plugin.ui.doc_settings), false,
        "and they are asked properly once they have an account")

    -- A linked book is settled, so it is recorded rather than merely skipped:
    -- unlinking it later must not bring the question back.
    reset()
    plugin = newPlugin()
    linkBook(plugin)
    check.eq(Match.offerLink(plugin.ctx), false, "a linked book is not offered a link")
    check.eq(plugin.store:linkOffered(plugin.ui.doc_settings), true, "and the question is closed")
    Match.unlink(plugin.ctx)
    Stubs.lastShown("ConfirmBox"):accept()
    check.eq(plugin.store:getLink(plugin.ui.doc_settings), nil, "unlinking it drops the link")
    check.eq(Match.offerLink(plugin.ctx), false, "but does not start the question again")

    -- The offer itself.
    reset()
    plugin = newPlugin()
    check.eq(Match.offerLink(plugin.ctx), true, "a book nobody has linked is offered one")
    local dialog = Stubs.lastShown("ButtonDialog")
    check.ok(dialog.title:find("“Dune”", 1, true) ~= nil, "the dialog names the book")
    check.ok(dialog.title:find("Find this book on NeoDB?", 1, true) ~= nil, "and what it is asking")
    check.ok(dialog.title:find("one time", 1, true) ~= nil, "and says it will not ask again")
    check.eq(table.concat(dialog:labels(), " | "),
        "Find book | Not this book | Stop asking",
        "the one yes on its own row, the two ways of declining together below")

    -- Recorded when it is shown, not when it is answered: a dismissed dialog, or
    -- a device that dies with it up, must not buy the reader a second one.
    check.eq(plugin.store:linkOffered(plugin.ui.doc_settings), true,
        "showing it is what closes the question")
    check.eq(Match.offerLink(plugin.ctx), false, "so the same book is never offered twice")

    -- Reopening the book reads that record back out of its sidecar.
    local reopened = newPlugin{ ui = newReaderUI{ sidecar = Stubs.sidecars[BOOK] } }
    check.eq(Match.offerLink(reopened.ctx), false, "including on a later open of it")

    -- Saying yes is the ordinary find-this-book path, nothing new.
    reset()
    plugin = newPlugin()
    Stubs.respond = function() return 200, {}, '{"data":[]}' end
    Match.offerLink(plugin.ctx)
    Stubs.lastShown("ButtonDialog"):press("Find book")
    check.ok(Stubs.requests[1] ~= nil and Stubs.requests[1].url:find("catalog/search", 1, true) ~= nil,
        "“Find book” searches NeoDB, the same as the menu row does")

    -- A prompt nobody asked for carries its own way of stopping it.
    reset()
    plugin = newPlugin()
    Match.offerLink(plugin.ctx)
    Stubs.lastShown("ButtonDialog"):press("Stop asking")
    check.eq(plugin.store:get("offer_link_on_open"), false, "“Stop asking” turns the option off")
    check.ok(Stubs.lastNotification():find("NeoDB settings", 1, true) ~= nil,
        "and says where to turn it back on, a global change being invisible otherwise")

    --[[--
    Timing. The offer waits for the page to be painted, and gives up rather than
    waiting for a better moment: a suggestion landing on top of whatever the
    reader is already doing is an interruption, not an offer.
    ]]
    reset()
    plugin = newPlugin()
    plugin:onReaderReady()
    check.eq(UIManager:scheduledCount(plugin.link_offer_task), 1, "opening a book schedules the offer")
    plugin:onCloseDocument()
    check.eq(UIManager:scheduledCount(plugin.link_offer_task), 0, "and closing it calls the offer off")

    reset()
    plugin = newPlugin()
    UIManager:show({ kind = "InputDialog" }) -- the reader is mid-something
    plugin:offerLink()
    check.eq(Stubs.lastShown("ButtonDialog"), nil, "nothing is offered over a dialog")
    check.eq(plugin.store:linkOffered(plugin.ui.doc_settings), false,
        "and nothing is recorded, so the next open of the book tries again")
end

check.section("End of book")
do
    reset()
    local plugin = newPlugin()
    linkBook(plugin, { mark = { shelf_type = "progress", rating_grade = 6 } })
    plugin.store:set("auto_mark_finished", true)
    Stubs.online = false -- so the queue is not drained out from under the check

    plugin:onEndOfBook()
    check.eq(plugin.store:queueCount(), 0,
        "nothing happens inline, so KOReader's own end-of-book dialog is painted first")

    UIManager:runTasks()
    local op = plugin.store:getQueue()[1]
    check.eq(op.body.shelf_type, "complete", "reaching the end marks the book Finished")
    check.eq(op.body.rating_grade, 6, "without losing the rating")
    check.eq(plugin.store:getLink(plugin.ui.doc_settings).mark.shelf_type, "complete",
        "and the cached status is updated at once")

    plugin.store:clearQueue()
    plugin:onEndOfBook()
    check.eq(plugin.store:queueCount(), 0, "a book already Finished is not marked again")
end

-- The upload queue ---------------------------------------------------------------------

check.section("The upload queue")
do
    reset()
    local store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    local api = Api:new{ store = store }

    store:enqueue({ method = "POST", path = "/a", label = "a" })
    store:enqueue({ method = "POST", path = "/b", label = "b" })
    recordCalls(api)
    local sent, remaining, dropped = api:flushQueue()
    check.eq(sent, 2, "everything that succeeds is sent")
    check.eq(remaining, 0, "and leaves nothing behind")
    check.eq(dropped, 0, "and nothing is discarded")

    -- A transient failure is worth keeping.
    reset()
    store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    api = Api:new{ store = store }
    store:enqueue({ method = "POST", path = "/a", label = "a" })
    recordCalls(api, function() return false, "timeout" end)
    sent, remaining, dropped = api:flushQueue()
    check.eq(sent, 0, "a timeout sends nothing")
    check.eq(remaining, 1, "and the op waits for the next attempt")
    check.eq(dropped, 0, "rather than being thrown away")

    -- A refusal that will not change is not worth keeping.
    reset()
    store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    api = Api:new{ store = store }
    store:enqueue({ method = "POST", path = "/a", label = "a" })
    store:enqueue({ method = "POST", path = "/b", label = "b" })
    local calls = recordCalls(api, function(nth)
        if nth == 1 then return false, "not_found", 404 end
        return true, {}, 200
    end)
    sent, remaining, dropped = api:flushQueue()
    check.eq(dropped, 1, "an op the server will always refuse is dropped")
    check.eq(sent, 1, "and the rest of the queue still goes out")
    check.eq(#calls, 2, "so one dead op does not stall the ones behind it")
end

check.section("A flush that should stop rather than carry on")
do
    --[[--
    Every op costs its own timeout, and every one of those blocks the UI thread.
    A queue of a hundred against a server that stopped answering is therefore
    minutes of frozen screen, spent proving the same thing a hundred times.
    ]]
    reset()
    local store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    local api = Api:new{ store = store }
    for i = 1, 5 do
        store:enqueue({ method = "POST", path = "/" .. i, label = "op " .. i })
    end

    local calls = recordCalls(api, function(nth)
        if nth == 1 then return true, {}, 200 end
        return false, "timeout"
    end)
    local sent, remaining, dropped, stopped = api:flushQueue()
    check.eq(sent, 1, "what went out before the connection died is sent")
    check.eq(#calls, 2, "and the flush stops at the first sign the network has gone")
    check.eq(remaining, 4, "the rest are kept")
    check.eq(dropped, 0, "and none are thrown away")
    check.eq(stopped, "timeout", "the caller is told why it stopped")

    local queue = store:getQueue()
    check.eq(queue[1].label, "op 2", "the queue resumes exactly where it stopped")
    check.eq(queue[4].label, "op 5", "in the order it was in")

    --[[--
    A revoked token answers 401 for every op. Dropping the queue over it would
    throw away highlights the ledger already records as sent, and nothing ever
    retries those.
    ]]
    reset()
    store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    api = Api:new{ store = store }
    for i = 1, 3 do
        store:enqueue({ method = "POST", path = "/" .. i, label = "op " .. i })
    end
    calls = recordCalls(api, function() return false, "unauthorized", 401 end)
    sent, remaining, dropped, stopped = api:flushQueue()
    check.eq(dropped, 0, "a refused token discards nothing")
    check.eq(remaining, 3, "the whole queue is kept")
    check.eq(#calls, 1, "and it is only asked once")
    check.eq(stopped, "unauthorized", "with the reason passed back")

    -- Being rate-limited is the server asking us to wait, not to give up.
    reset()
    store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    api = Api:new{ store = store }
    store:enqueue({ method = "POST", path = "/a", label = "a" })
    store:enqueue({ method = "POST", path = "/b", label = "b" })
    calls = recordCalls(api, function() return false, "rate_limited", 429 end)
    sent, remaining, dropped, stopped = api:flushQueue()
    check.eq(dropped, 0, "nothing is discarded for being too fast")
    check.eq(remaining, 2, "everything waits")
    check.eq(#calls, 1, "and we stop asking")
    check.eq(stopped, "rate_limited", "with the reason passed back")
end

check.section("Submitting one write")
do
    reset()
    local store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    local api = Api:new{ store = store }

    Stubs.online = false
    local status = api:submit({ method = "POST", path = "/a", label = "a" }, false)
    check.eq(status, "queued", "a write made offline is queued, not lost")
    check.eq(store:queueCount(), 1, "and is in the queue")

    -- A queue with no room says so, rather than reporting a write it did not take.
    local batch = {}
    for i = 1, store:queueLimit() do table.insert(batch, { label = "filler " .. i }) end
    store:replaceQueue({})
    store:enqueueAll(batch)
    local kind
    status, kind = api:submit({ method = "POST", path = "/a", label = "a" }, false)
    check.eq(status, "failed", "a write the queue cannot take is not called queued")
    check.eq(kind, "queue_full", "and names the reason")
    check.ok(api:errorMessage(kind):find("waiting", 1, true) ~= nil,
        "which turns into something the reader can act on")

    reset()
    store = Store:new()
    store:setInstance(INSTANCE)
    store:setToken("t")
    api = Api:new{ store = store }
    local seen = {}
    api.on_op_sent = function(op, data) table.insert(seen, { op = op, data = data }) end
    recordCalls(api)
    status = api:submit({ method = "POST", path = "/a", label = "a" }, true)
    check.eq(status, "sent", "a write made online goes straight out")
    check.eq(seen[1].data.uuid, "note-1", "and its reply is announced, uuid and all")
end

-- Errors -------------------------------------------------------------------------------

check.section("Explaining a refusal")
do
    check.eq(Api.explainErrorBody('{"message":"Item not found"}'), "Item not found",
        "NeoDB's own refusals are surfaced")
    check.eq(Api.explainErrorBody('{"detail":[{"loc":["body","visibility"],"msg":"bad value"}]}'),
        "visibility: bad value", "a schema error names the field")
    check.eq(Api.explainErrorBody('{"error":"Status is too long"}'), "Status is too long",
        "and so does the Mastodon-compatible side")
    check.eq(Api.explainErrorBody("not json"), nil, "anything unreadable explains nothing")
end

-- Posting ---------------------------------------------------------------------------------

check.section("Posting something with no book behind it")
do
    reset()
    local plugin = newPlugin()
    Stubs.online = false

    Actions.postStatus(plugin.ctx)
    local dialog = Stubs.lastShown("InputDialog")
    check.eq(dialog.title, "Post to NeoDB", "the composer opens")
    check.eq(dialog:label("visibility"), "Visible to: Public",
        "starting from the reader's own default visibility")

    dialog:press("Post")
    check.eq(Stubs.lastAlert(), "The post is empty.", "an empty post is refused")
    check.eq(plugin.store:queueCount(), 0, "and nothing is queued")

    dialog:typeText("Reading Dune again.")
    dialog:press("Post")
    local op = plugin.store:getQueue()[1]
    check.eq(op.path, "/api/v1/statuses", "a post goes to the Mastodon-compatible endpoint")
    check.eq(op.body.status, "Reading Dune again.", "with what was typed")
    check.eq(op.body.visibility, "public", "and a visibility that side understands")
    check.eq(op.body.media_ids, nil, "and nothing else, so no empty array is encoded")
    check.eq(op.label, "Post: Reading Dune again.", "the queue row says what is waiting")

    -- The picker writes back to the dialog's own button.
    reset()
    plugin = newPlugin()
    Stubs.online = false
    Actions.postStatus(plugin.ctx)
    dialog = Stubs.lastShown("InputDialog")
    dialog:press("visibility")
    local picker = Stubs.lastShown("ButtonDialog")
    check.eq(#picker:labels(), 5, "the picker offers four visibilities and a way out")
    picker:press("Unlisted")
    check.eq(dialog:label("visibility"), "Visible to: Unlisted",
        "and the choice shows on the button that opened it")

    dialog:typeText("Quiet thought.")
    dialog:press("Post")
    check.eq(plugin.store:getQueue()[1].body.visibility, "unlisted", "and is what gets posted")
end

-- Menus ------------------------------------------------------------------------------------

check.section("The menu")
do
    reset()
    local plugin = newPlugin()
    local rows = plugin:buildMenu()
    local function labelOf(row)
        return row.text or (row.text_func and row.text_func())
    end

    check.eq(labelOf(rows[1]), "This book isn't linked",
        "the first row states where the book stands")
    check.ok(labelOf(rows[2]):match("^Update progress"), "then progress")
    check.eq(labelOf(rows[3]), "Rate and comment…", "then rating")
    check.eq(labelOf(rows[4]), "Add note…", "then notes")
    check.eq(labelOf(rows[5]), "Upload all highlights and notes…", "then the backlog")
    check.eq(labelOf(rows[6]), "Uploads: all sent", "then the queue")
    check.ok(labelOf(rows[7]):match("^Account"), "then the account")
    check.eq(labelOf(rows[8]), "Settings for this book", "then this book's settings")
    check.eq(labelOf(rows[9]), "Settings", "then the global ones")
    check.eq(labelOf(rows[10]), "Post something…", "and a post needs no book, so it comes last")

    check.eq(rows[5].enabled_func(), false,
        "uploading a backlog is offered only once the book is linked")
    linkBook(plugin)
    check.eq(rows[5].enabled_func(), true, "and enabled once it is")
    check.eq(labelOf(rows[1]), "Linked, status not synced",
        "the status row says when the mark was never fetched")

    plugin.store:cacheMark(plugin.ui.doc_settings, { shelf_type = "progress", rating_grade = 8 })
    check.eq(labelOf(rows[1]), "Reading ★★★★", "and otherwise the shelf and the rating")

    --[[--
    Both automatic switches are the book's own, so both live under this book's
    settings. What is left in the global list is only what a new book starts
    with, and that is a submenu rather than two more rows among switches that act
    the moment they are tapped.
    ]]
    local book_rows = plugin:linkMenu()
    local progress_row
    for _idx, row in ipairs(book_rows) do
        if row.text == "Update progress automatically" then progress_row = row end
    end
    check.ok(progress_row ~= nil, "this book has its own automatic-progress switch")
    check.eq(progress_row.checked_func(), false, "off, as a new link starts")
    progress_row.callback()
    check.eq(plugin.store:getLink(plugin.ui.doc_settings).auto_progress, true,
        "and tapping it records the answer on the book")
    check.eq(progress_row.checked_func(), true, "which is what the row then shows")

    local defaults
    for _idx, row in ipairs(plugin:settingsMenu()) do
        if row.text == "Defaults for a new book" then defaults = row end
    end
    check.ok(defaults ~= nil, "the global list keeps only the defaults")
    check.eq(#defaults.sub_item_table, 3, "which are everything about a book NeoDB does not know")
    -- In the order the three happen in: suggested, then linked, then read.
    check.eq(defaults.sub_item_table[1].text, "Suggest to link with NeoDB (only once per book)")
    check.eq(defaults.sub_item_table[2].text, "Update progress automatically")
    check.eq(defaults.sub_item_table[3].text, "Upload new highlights and notes")

    local suggest = defaults.sub_item_table[1]
    check.eq(suggest.checked_func(), true, "the offer is on out of the box")
    suggest.callback()
    check.eq(suggest.checked_func(), false, "and the row turns it off")
    suggest.callback()

    -- The file browser has no book, so it offers only what needs none.
    reset()
    local fm = NeoDB:new{ ui = { menu = { registerToMainMenu = function() end } } }
    fm.store:setInstance(INSTANCE)
    fm.store:setToken("t")
    rows = fm:buildMenu()
    check.eq(#rows, 4, "the file browser gets four rows")
    check.eq(labelOf(rows[1]), "Uploads: all sent", "the queue")
    check.eq(labelOf(rows[4]), "Post something…", "and a post, which needs no book")
end

check.section("The queue row says what happened to it")
do
    reset()
    local plugin = newPlugin()
    check.eq(plugin:queueRowText(), "Uploads: all sent", "an empty queue that emptied itself")
    check.eq(plugin:lastFlushNote(), nil, "has nothing to explain")

    -- Uploads given up on in the background are otherwise invisible: the count
    -- goes to zero because they are gone, not because they arrived.
    plugin.store:setLastFlush({ sent = 0, remaining = 0, dropped = 2 })
    check.eq(plugin:queueRowText(), "Uploads: 2 could not be sent",
        "so a queue emptied by failure does not read as success")
    check.ok(plugin:lastFlushNote() ~= nil, "and the row can be opened to find out why")

    -- Stopped because of the account: it will not start again by itself.
    plugin.store:setLastFlush({ sent = 0, remaining = 3, dropped = 0, stopped = "unauthorized" })
    plugin.store:enqueue({ label = "a" })
    check.eq(plugin:queueRowText(), "Uploads: 1 waiting, paused",
        "a paused queue says so rather than looking like it is working")
    check.ok(plugin:lastFlushNote():find("Sign in", 1, true) ~= nil,
        "and names what to do about it")

    local rows = plugin:queueMenu()
    check.eq(rows[1].text, plugin:lastFlushNote(), "the reason heads the submenu")
    check.eq(rows[1].enabled, false, "as a line to read, not a thing to tap")

    --[[--
    A connection that comes and goes is the ordinary state of an e-reader, so a
    flush that could not reach the server is not the queue being stuck: it goes
    out with the next one.
    ]]
    plugin.store:setLastFlush({ sent = 0, remaining = 1, dropped = 0, stopped = "timeout" })
    check.eq(plugin:queueRowText(), "Uploads: 1 waiting",
        "an unreachable server is not called paused")
    check.ok(plugin:lastFlushNote() ~= nil,
        "though the submenu still says the last attempt did not get through")

    plugin.store:setLastFlush({ sent = 2, remaining = 0, dropped = 0 })
    plugin.store:clearQueue()
    check.eq(plugin:queueRowText(), "Uploads: all sent", "a clean run reads clean again")

    -- Discarding on purpose settles the matter: what the last attempt came to is
    -- no longer a description of anything.
    plugin.store:setLastFlush({ sent = 0, remaining = 0, dropped = 2 })
    plugin.store:clearQueue()
    check.eq(plugin:lastFlushNote(), nil, "discarding the queue forgets its last attempt")
    check.eq(plugin:queueRowText(), "Uploads: all sent", "and the row stops explaining it")
end

check.section("The background flush says one thing, once")
do
    reset()
    local plugin = newPlugin()
    plugin.store:enqueue({ method = "POST", path = "/a", label = "a" })
    recordCalls(plugin.api, function() return false, "unauthorized", 401 end)

    Actions.flushSoon(plugin.ctx)
    UIManager:runTasks()
    check.eq(Stubs.lastNotification(),
        "NeoDB uploads are paused: sign in again to send them.",
        "uploads stopped by the account are worth interrupting for once")

    Stubs.notifications = {}
    Actions.flushSoon(plugin.ctx)
    UIManager:runTasks()
    check.eq(Stubs.lastNotification(), nil,
        "but not every time a book is opened, which is when this path runs")
end

check.section("A post longer than the server takes")
do
    reset()
    local plugin = newPlugin()
    Stubs.online = false
    Actions.postStatus(plugin.ctx)
    local dialog = Stubs.lastShown("InputDialog")

    dialog:typeText(string.rep("x", 501))
    dialog:press("Post")
    check.eq(plugin.store:queueCount(), 0,
        "an over-long post is not queued to fail out of sight days later")
    local box = Stubs.lastShown("ConfirmBox")
    check.ok(box ~= nil, "the reader is warned")
    check.ok(box.text:find("501", 1, true) ~= nil, "with the length it actually is")

    -- The limit belongs to the server, so this warns rather than refuses.
    box:accept()
    check.eq(plugin.store:queueCount(), 1, "and can still post it anyway")

    reset()
    plugin = newPlugin()
    Stubs.online = false
    Actions.postStatus(plugin.ctx)
    dialog = Stubs.lastShown("InputDialog")
    dialog:typeText(string.rep("x", 500))
    dialog:press("Post")
    check.eq(plugin.store:queueCount(), 1, "a post inside the limit is not questioned")
end

check.section("The progress dialog after switching unit")
do
    reset()
    local plugin = newPlugin{ page = 100, pages = 400, percent = 0.25, labels = "xii" }
    linkBook(plugin)
    Actions.updateProgress(plugin.ctx)

    local dialog = Stubs.lastShown("InputDialog")
    check.eq(dialog.description, "You're at page xii.", "it opens at the reader's position")
    check.eq(dialog:label("unit"), "Unit: page", "in this book's own unit")
    check.eq(dialog.input_type, nil,
        "with no number pad, since a publisher page label is not a number")

    dialog:press("unit")
    local switched = Stubs.lastShown("InputDialog")
    check.ok(switched ~= dialog, "switching unit rebuilds the dialog")
    check.eq(dialog.closed, true, "and closes the one it replaces")
    check.eq(switched.description, "You're at 25%.",
        "so the description cannot be left describing the other unit")
    check.eq(switched:label("unit"), "Unit: percent", "the button agrees")
    check.eq(switched.typed, "25", "and so does the box")
    check.eq(switched.input_type, "number", "which now wants a number pad")
end

check.section("Uploading a backlog bigger than the queue")
do
    reset()
    local annotations = {}
    for i = 1, 120 do
        table.insert(annotations, annotation{
            datetime = string.format("2026-08-01 %02d:%02d:00", math.floor(i / 60), i % 60),
        })
    end
    local plugin = newPlugin{ annotations = annotations }
    linkBook(plugin)
    recordCalls(plugin.api, function() return true, {}, 200 end)

    Annotations.uploadAll(plugin.ctx)
    Stubs.lastShown("ConfirmBox"):accept()
    check.eq(Stubs.lastNotification(),
        "20 more to go — upload again once these are sent.",
        "what the queue could not take is reported, since a second run is needed")
end

check.section("The status row offers whatever is actually in the way")
do
    --[[--
    The row states where the book stands, so its submenu has to offer the thing
    that would change that. Shelves under a book that is not linked, or under no
    account at all, only lead to a question the reader never asked.
    ]]
    reset()
    local plugin = newPlugin{ signed_out = true }
    local rows = plugin:shelfMenu()
    check.eq(#rows, 1, "signed out, there is one thing to do")
    check.eq(rows[1].text, "Sign in to NeoDB…", "and it says so plainly")

    -- Signed in, but this book is not linked to anything yet.
    reset()
    plugin = newPlugin()
    rows = plugin:shelfMenu()
    check.eq(rows[1].text, "Find this book on NeoDB…", "unlinked, the ways to link it")
    check.eq(rows[2].text, "Find by title or author…", "including searching by hand")
    check.eq(rows[3].text, "Link by URL…", "and pasting a link")
    check.eq(#rows, 3, "and no shelves, since there is nothing to put on one")

    -- A link belonging to another server is not one this account can use.
    reset()
    plugin = newPlugin()
    plugin.store:setLink(plugin.ui.doc_settings,
        { uuid = "item-9", title = "Dune", instance = "https://other.example" })
    rows = plugin:shelfMenu()
    check.eq(rows[1].text, "Find this book on NeoDB…", "a foreign link offers the same")
    check.ok(rows[1].help_text ~= nil, "and explains why it is not simply linked")

    -- Linked: now the shelves mean something.
    reset()
    plugin = newPlugin()
    linkBook(plugin)
    rows = plugin:shelfMenu()
    check.eq(rows[1].text, "Want to read", "linked, the shelves are the answer")
    check.eq(rows[4].text, "Dropped", "all four of them")
    -- And only them: a row that was not a status read here as a fifth shelf.
    check.eq(#rows, 4, "with nothing among them that is not one")
    check.eq(rows[4].separator, nil, "and no rule drawn under the last, with nothing below it")

    -- The same three rows are shared with "Settings for this book", where they
    -- come after everything about the link that already exists.
    local book_rows = plugin:linkMenu()
    check.eq(book_rows[1].text, "Show linked book", "which still leads with the link itself")
    check.eq(book_rows[#book_rows - 2].text, "Find this book on NeoDB…",
        "and ends with the same three ways to link")
    check.eq(book_rows[#book_rows].text, "Link by URL…", "in the same order")
    check.eq(book_rows[#book_rows].separator, true, "keeping the separator under them")
end

check.section("Gesture actions")
do
    check.ok(Stubs.dispatcher_actions["neodb_book_sheet"] ~= nil, "the quick sheet is bindable")
    check.eq(Stubs.dispatcher_actions["neodb_book_sheet"].reader, true,
        "and is offered under the reader, where a book exists")
    check.eq(Stubs.dispatcher_actions["neodb_post_status"].general, true,
        "while a post is a general action, since it needs no book")
end

check.section("Where the row sits in the Tools menu")
do
    --[[--
    `sorting_hint` picks the tab, not the place in it: MenuSorter appends anything
    KOReader's own order does not name to the end, behind every built-in. So the
    plugin names itself in that order.
    ]]
    for _idx, which in ipairs({ "reader", "filemanager" }) do
        local order = require("ui/elements/" .. which .. "_menu_order")
        local at, seen = nil, 0
        for index, id in ipairs(order.tools) do
            if id == "neodb" then at = index; seen = seen + 1 end
        end
        check.eq(seen, 1, which .. ": the row is claimed exactly once")
        check.eq(at, 3, which .. ": as the third Tools row, not the last")
    end
end

check.section("The export target is registered at load")
do
    check.ok(Stubs.providers.exporter ~= nil and Stubs.providers.exporter.NeoDB ~= nil,
        "requiring main.lua registers NeoDB with the exporter")
end

check.finish()
