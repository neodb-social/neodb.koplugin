--[[--
NeoDB as a target in KOReader's own "Export highlights".

KOReader's exporter already knows how to do things this plugin never will: filter
by highlight style and colour, run from the file browser, take a multi-select, and
walk every book in the history. Registering as one of its targets buys all of that
for the price of one `export` function, and puts NeoDB where a reader who already
exports to Markdown or Readwise will look for it.

What the exporter hands over is *clippings*, not annotations: already filtered, and
carrying only when each was made rather than any identity. So this module uses them
as a selection -- which highlights the reader meant -- and reads the real records
back out of each book's own sidecar, which is the only place that knows how an
annotation ended up and whether NeoDB has already been told about it.

Three things about the exporter shape the design:

* **Every enabled target fires on every export.** There is no "export only to
  NeoDB", so this target's whole say is `isEnabled`, and being enabled while it
  could not possibly work would impose a Wi-Fi prompt on somebody's Markdown
  export. Hence the preconditions live in `isEnabled` rather than in `export`.
* **`export` must answer synchronously**, so it cannot stop to ask anything. The
  consent for a run of irreversible public posts is therefore taken once, when the
  switch is turned on.
* **It keeps no record of what it exported** and re-sends everything every time.
  The per-book `sent` ledger in `neodb_annotations` stays the only thing that
  decides what NeoDB has seen.

@module koplugin.neodb.exporter
]]

local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Actions = require("neodb_actions")
local Annotations = require("neodb_annotations")
local Util = require("neodb_util")

--[[--
One string doing three jobs: the Provider key, the key our settings hang off, and
the literal KOReader prints in "%1: Exported successfully." Changing it later
orphans whatever a reader had configured, so it is a one-way door.
]]
local NAME = "NeoDB"

local Target = {
    name = NAME,
    --[[--
    Posts over the network, so KOReader wraps the whole export in
    `runWhenOnline` and reports success without a filename. Deliberately not
    `shareable`: that would add a "Share as NeoDB" row wanting a `share` method
    that has no meaning for an account you post to.
    ]]
    is_remote = true,
    version = "1.0.0",
}

--[[--
Our corner of the exporter's own settings.

`enabled` is a fact about KOReader's export list rather than about NeoDB, so it
lives where the menu that shows it lives, and a reader who resets the exporter's
settings loses this with the rest of it. Everything that shapes the *note* --
visibility, crossposting, block quotes, progress unit -- stays in the plugin's
store, shared with the automatic mirror and the composer, so one highlight cannot
come out differently depending on which path posted it.

Not flushed, which is what the exporter's own targets do too: `G_reader_settings`
is written out when KOReader exits.
]]
local function settings()
    local all = G_reader_settings:readSetting("exporter", {})
    if type(all[NAME]) ~= "table" then all[NAME] = {} end
    return all[NAME]
end

-- The attached plugin ---------------------------------------------------------
--
-- The exporter holds one target for the life of the process, but a NeoDB context
-- belongs to one ReaderUI or file browser. So the plugin hands its context over on
-- init and takes it back on close.

function Target:attach(ctx)
    self.ctx = ctx
end

--[[--
Conditional, because a ReaderUI can be built while the file browser it replaces is
still around: whoever attached last is the live one, and a late close from the one
that lost must not clear it.
]]
function Target:detach(ctx)
    if self.ctx == ctx then self.ctx = nil end
end

--[[--
The attached context, if it still describes something on screen.

A torn-down ReaderUI keeps every field it had, including a `doc_settings` already
written out and discarded -- and anything written into that one is lost. UIManager's
window stack is the only thing that knows, and both ReaderUI and the file browser
are window-level entries in it. Guarded, because older builds lack the method.
]]
local function liveCtx(self)
    local ctx = self.ctx
    if not ctx or not ctx.ui then return nil end
    if UIManager.isWidgetShown and not UIManager:isWidgetShown(ctx.ui) then
        return nil
    end
    return ctx
end

-- Being enabled ---------------------------------------------------------------

--- Signed in, with somewhere to post from.
function Target:isReadyToExport()
    return self.ctx ~= nil and self.ctx.store:isLoggedIn()
end

--[[--
Folded together on purpose.

`Exporter:requiresNetwork` decides whether to wrap an export in `runWhenOnline` by
asking every target whether it is enabled. A signed-out reader who left this switch
on should not have their Markdown export raise a Wi-Fi prompt for a target that
would refuse the work anyway -- nor collect a "NeoDB: Failed to export." line for
it. This also covers the moment before the plugin has attached anything: the
exporter is built before we are.
]]
function Target:isEnabled()
    return settings().enabled == true and self:isReadyToExport()
end

--[[--
Turning it on is where consent belongs.

`export` has to answer KOReader synchronously and so can never stop to ask, and a
dialog on every export would be a nag rather than a safeguard. So the whole
proposition is put once, here, where there is a dialog to put it in -- the same
ground `uploadAll` covers before it empties a backlog.
]]
function Target:toggle(touchmenu_instance)
    local mine = settings()
    if mine.enabled then
        mine.enabled = false
        return
    end

    if not self:isReadyToExport() then
        return Util.alert(_("Sign in to NeoDB first, under Tools → NeoDB."))
    end

    local warning = _("Post highlights to NeoDB whenever you export them?\n\nEach highlight NeoDB has not already been told about becomes a separate note on your account, at your default visibility, and cannot be taken back from here.\n\nOnly books linked to a NeoDB entry are touched, whether or not their own upload switch is on.")
    if self.ctx.store:get("crosspost_annotations") then
        warning = warning .. "\n\n"
            .. _("Crossposting shared highlights is on, so your followers will see all of them.")
    end
    UIManager:show(ConfirmBox:new{
        text = warning,
        ok_text = _("Post them"),
        ok_callback = function()
            -- Refetched rather than closed over: a reset between asking and
            -- answering would otherwise be written straight back over.
            settings().enabled = true
            -- Repainted here rather than through `check_callback_updates_menu`,
            -- which would redraw the row before this box had been answered.
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

function Target:getMenuTable()
    return {
        -- A plain string, not a `text_func`: the exporter sorts this submenu with
        -- `v1.text < v2.text`, which throws on a nil.
        text = _("NeoDB"),
        help_text = _("Posts every highlight and note NeoDB has not already been told about, each as its own note on that book's linked NeoDB entry.\n\nOnly books linked to a NeoDB entry are touched, whether or not their own \"Upload new highlights and notes\" switch is on. Books that are not linked are skipped."),
        checked_func = function() return self:isEnabled() end,
        callback = function(touchmenu_instance)
            self:toggle(touchmenu_instance)
        end,
    }
end

-- Exporting -------------------------------------------------------------------

--[[--
The creation timestamps of one book's clippings, as a set.

A clipping carries `time` as a Unix epoch and nothing else that identifies it.
`MyClipping:getTime` built that epoch out of the annotation's own `datetime` string
with `os.time`, in local time, so `os.date` turns it straight back into the key the
ledger is written with.

Anything whose `time` did not parse is counted rather than guessed at. Deriving a
key some other way -- from the text, say -- would post the same highlight a second
time the day that derivation changed.

@treturn table set of timestamp keys
@treturn int how many clippings could not be placed
]]
local function clippingKeys(booknotes)
    local keys, unplaceable = {}, 0
    for _idx, group in ipairs(booknotes) do
        for _jdx, clipping in ipairs(group) do
            if type(clipping.time) == "number" then
                keys[os.date("%Y-%m-%d %H:%M:%S", clipping.time)] = true
            else
                unplaceable = unplaceable + 1
            end
        end
    end
    return keys, unplaceable
end

--[[--
One line saying what actually happened.

The queue is finite, and whatever did not fit is deliberately left unmarked so that
the next export picks it up -- which is only any use if the reader is told to run
one. KOReader's own status message can say no more than "Exported successfully".
]]
local function report(queued, total, unlinked, unplaceable)
    local parts = {}
    if queued > 0 then
        table.insert(parts, T(_("queued %1 highlight(s)"), tostring(queued)))
    end

    local left = total - queued
    if left > 0 then
        if queued > 0 then
            table.insert(parts, T(_("%1 still to go — export again once these have uploaded"),
                tostring(left)))
        else
            table.insert(parts, T(_("%1 waiting, but the upload queue is full — upload it first, under Tools → NeoDB → Uploads"),
                tostring(left)))
        end
    end
    if unlinked > 0 then
        table.insert(parts, T(_("%1 book(s) not linked"), tostring(unlinked)))
    end
    if unplaceable > 0 then
        table.insert(parts, T(_("%1 highlight(s) could not be matched up"),
            tostring(unplaceable)))
    end

    if #parts == 0 then return end
    Util.notify("NeoDB: " .. table.concat(parts, ", ") .. ".")
end

--[[--
Posts what NeoDB has not seen, for every linked book in the export.

Planned in full before anything is written: a book that cannot be posted to has to
cost nothing, and the numbers in the report have to be the real ones.

The return value is what KOReader turns into one status line, so it means "this
target did the work it decided to do" -- queued, which for everything else in this
plugin has always been what success means too. False is kept for the three cases a
reader could act on: nothing attached or not signed in, not one book in the export
linked, and a queue too full to take anything.

@treturn bool
]]
function Target:export(t)
    local ctx = liveCtx(self)
    if not ctx then
        logger.warn("NeoDB: asked to export with no live context")
        return false
    end
    if not ctx.store:isLoggedIn() then return false end

    local plans, total, linked, unlinked, unplaceable = {}, 0, 0, 0, 0
    for _idx, booknotes in ipairs(t) do
        --[[--
        No `file` at all is how Kindle's own My Clippings entries arrive: nothing
        to find a link on, so nothing to post to.
        ]]
        local book = type(booknotes.file) == "string"
            and Annotations.bookAt(ctx, booknotes.file) or nil
        if book then
            linked = linked + 1
            -- The exporter has already worked out a page count; fall back to it
            -- when the sidecar has none, so a position can still be attached.
            book.pages = book.pages or booknotes.number_of_pages

            local keys, missed = clippingKeys(booknotes)
            unplaceable = unplaceable + missed

            local list = Annotations.unsentAt(ctx, book, keys)
            if #list > 0 then
                table.insert(plans, { book = book, list = list })
                total = total + #list
            end
        else
            unlinked = unlinked + 1
        end
    end

    if linked == 0 then
        Util.notify(unlinked > 0
            and _("None of those books are linked to NeoDB.")
            or _("Nothing there to post to NeoDB."))
        return false
    end
    if total == 0 then
        -- "Already has every highlight" would be a lie when some of them simply
        -- could not be named, and a clipping we cannot place is one nobody will
        -- ever hear about otherwise.
        if unplaceable > 0 then
            report(0, 0, unlinked, unplaceable)
        else
            Util.notify(_("NeoDB already has every highlight in there."))
        end
        return true
    end

    local queued = 0
    for _idx, plan in ipairs(plans) do
        queued = queued + Annotations.queueFor(ctx, plan.book, plan.list)
    end

    report(queued, total, unlinked, unplaceable)
    -- Next tick, so KOReader's own status message is painted before a request
    -- takes the UI thread away for the length of its timeout.
    if queued > 0 then Actions.flushSoon(ctx) end
    return queued > 0
end

return Target
