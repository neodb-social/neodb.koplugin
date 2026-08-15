--[[--
NeoDB for KOReader.

Links the book you are reading to an entry on a NeoDB instance, then lets you
set its reading status and progress and share notes, quotes, ratings and comments
without leaving the book.

Design notes, since e-readers are not phones:

* Network access is never assumed. Every request is gated behind KOReader's
  network manager, and writes fall back to an upload queue so a mark made with
  Wi-Fi off is sent later rather than lost.
* Requests block the UI thread, so each one paints a "please wait" box first and
  uses short timeouts.
* Reading the book comes first: nothing here opens a dialog on its own, and the
  automatic syncs are opt-in and silent.

@module koplugin.neodb
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Actions = require("neodb_actions")
local Annotations = require("neodb_annotations")
local Api = require("neodb_api")
local ExportTarget = require("neodb_exporter")
local Login = require("neodb_login")
local Match = require("neodb_match")
local Store = require("neodb_store")
local Util = require("neodb_util")

local NeoDB = WidgetContainer:extend{
    name = "neodb",
}

--[[--
Offers NeoDB to KOReader's own "Export highlights".

Registered here, in the module body, rather than from `init`. The exporter builds
its list of targets in its own `init`, and it is constructed before we are --
plugins are loaded in path order, and `exporter.koplugin` sorts before
`neodb.koplugin`. Registering any later would leave us out of that first list, and
so out of `isReady`, out of `requiresNetwork`, and out of both gesture actions,
until the reader happened to open the export menu once and it was rebuilt. Module
load is the last moment early enough, and a disabled plugin never gets this far, so
nothing can leave a row behind for a plugin that is switched off.

`provider` only exists from KOReader v2025.04, and there is nothing to be done on
an older build but carry on without the target.
]]
local provider_ok, Provider = pcall(require, "provider")
if provider_ok and type(Provider) == "table" and Provider.register then
    Provider:register("exporter", ExportTarget.name, ExportTarget)
end

--[[--
How long the reader has to leave their annotations alone before we act on them.

Only counts while nothing is on screen, so writing a note takes as long as it
takes; this is the pause after the dialogs are gone, covering the reader who taps
a highlight again to add a second thought to it.
]]
local ANNOTATION_SETTLE_SECONDS = 10

--- How often "Automatically update progress" looks at where the book stands.
local PROGRESS_TICK_SECONDS = 3600

function NeoDB:init()
    self.store = Store:new()
    self.api = Api:new{ store = self.store }

    -- One context object, passed to every module, so they never reach back into
    -- the plugin instance.
    self.ctx = {
        ui    = self.ui,
        store = self.store,
        api   = self.api,
    }

    --[[--
    NeoDB merges duplicate catalog entries, and the API client notices when a uuid
    we hold redirects to whatever survived. Fixing the link needs the open book's
    sidecar, which only this object knows about, so it is wired here -- once, for
    every endpoint, rather than at each call site.

    A queue flush can carry ops for books that are not open; `adoptMerge` checks the
    uuid before touching anything, and those links are corrected when their own book
    is next used.
    ]]
    self.api.on_item_moved = function(old_uuid, new_uuid)
        if not self.ui.doc_settings then return end
        Match.adoptMerge(self.ctx, old_uuid, new_uuid)
    end

    --[[--
    Wired for the same reason: a queued op cannot carry a callback, so the one
    thing a shared highlight needs from its reply -- the note's uuid, which is
    NeoDB's only handle for editing or deleting it later -- is collected here.

    Deliberately not gated on a document being open. The queue can be drained from
    the file browser, and a reply for a book that is merely closed is one we can
    still file; `recordSent` works out where it goes.
    ]]
    self.api.on_op_sent = function(op, data)
        Annotations.recordSent(self.ctx, op, data)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Document-only features. The plugin is also loaded in the file browser,
    -- where there is no book to mark.
    if self.ui.document then
        self:addHighlightAction()
        -- One stable closure each: UIManager matches scheduled tasks by identity,
        -- so rescheduling a new one each time would leave the old ones to fire.
        self.annotation_task = function() self:syncAnnotations() end
        self.progress_task = function() self:progressTick() end
    end

    --[[--
    The export target outlives any one of these objects, so it is lent the context
    belonging to whichever is current. Not gated on a document: exporting a
    multi-select happens in the file browser.
    ]]
    ExportTarget:attach(self.ctx)
end

--- Takes the lent context back, so a torn-down UI cannot be exported through.
function NeoDB:onCloseWidget()
    ExportTarget:detach(self.ctx)
end

function NeoDB:isReader()
    return self.ui.document ~= nil
end

-- Gesture / profile actions --------------------------------------------------

function NeoDB:onDispatcherRegisterActions()
    Dispatcher:registerAction("neodb_book_sheet", {
        category = "none",
        event = "NeoDBBookSheet",
        title = _("NeoDB: book actions"),
        reader = true,
    })
    Dispatcher:registerAction("neodb_update_progress", {
        category = "none",
        event = "NeoDBUpdateProgress",
        title = _("NeoDB: update reading progress"),
        reader = true,
    })
    Dispatcher:registerAction("neodb_add_note", {
        category = "none",
        event = "NeoDBAddNote",
        title = _("NeoDB: add note"),
        reader = true,
    })
    Dispatcher:registerAction("neodb_post_status", {
        category = "none",
        event = "NeoDBPostStatus",
        title = _("NeoDB: post something"),
        -- `general`, not `reader`, unlike the three above: a post needs no book,
        -- so this is worth having on a file browser gesture too.
        general = true,
    })
end

function NeoDB:onNeoDBBookSheet()
    if not self:isReader() then return end
    Actions.showSheet(self.ctx)
    return true
end

function NeoDB:onNeoDBUpdateProgress()
    if not self:isReader() then return end
    Actions.updateProgress(self.ctx)
    return true
end

function NeoDB:onNeoDBAddNote()
    if not self:isReader() then return end
    Actions.addNote(self.ctx)
    return true
end

--- Deliberately not gated on a document: this is the one action that needs none.
function NeoDB:onNeoDBPostStatus()
    Actions.postStatus(self.ctx)
    return true
end

-- Highlight menu ------------------------------------------------------------

--[[--
Adds "Share on NeoDB" to the text selection menu.

Sharing a quote is the one action worth reaching from inside the text, and the
highlight menu is where the reader already is when they have something to say.
]]
function NeoDB:addHighlightAction()
    if not self.ui.highlight then return end
    self.ui.highlight:addToHighlightDialog("13_neodb_quote", function(this, index)
        return {
            text = _("Share on NeoDB"),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text.text)
                --[[--
                An `index` means this is not a fresh selection but a highlight the
                book already holds, reached through the edit dialog's "…" button.
                The mirror is watching that one, so the composer has to say which
                annotation it is posting or both of them will post it.
                ]]
                local shared = index and self.ui.annotation
                    and self.ui.annotation.annotations[index] or nil
                this:onClose()
                Actions.addNote(self.ctx, {
                    quote = text,
                    annotation_key = type(shared) == "table" and shared.datetime or nil,
                })
            end,
        }
    end)
end

-- Menu ----------------------------------------------------------------------

--[[--
Short line describing the open book's status, used as a menu label in its own right.

Reader-only: the row it names is only built there, and in the file browser the
account row already says what there is to say.
]]
function NeoDB:linkStatusText()
    if not self.store:isLoggedIn() then return _("Not signed in") end

    local link, foreign = self.store:getLink(self.ui.doc_settings)
    if not link then
        return foreign and _("Linked to another instance") or _("This book isn't linked")
    end
    local mark = link.mark
    if not mark then return _("Linked, status not synced") end

    local text = Util.shelfLabel(mark.shelf_type)
    local stars = Util.stars(mark.rating_grade)
    if stars then text = text .. " " .. stars end
    return text
end

function NeoDB:addToMainMenu(menu_items)
    menu_items.neodb = {
        text = _("NeoDB"),
        --[[--
        Third-party plugins are not in KOReader's menu order table, so say where we
        belong instead of landing in the first tab with a NEW: prefix.

        The Tools tab itself, alongside Calibre, Wallabag and Progress sync -- the
        other "talks to a service about your books" entries -- rather than a level
        deeper in More tools, which is where a plugin nobody can find lives.
        ]]
        sorting_hint = "tools",
        sub_item_table = self:buildMenu(),
    }
end

function NeoDB:buildMenu()
    local ctx = self.ctx
    local items = {}

    if self:isReader() then
        --[[--
        The status line and the shelf picker under it were two rows saying the same
        thing, so this is one row: it states where the book stands and opens the
        list that changes it.

        The quick sheet it used to open moves to a long press. Nothing goes with
        it -- every button on that sheet is also a row in this menu -- and it keeps
        its gesture, which is where a sheet built for one-tap access belongs.
        ]]
        table.insert(items, {
            text_func = function() return self:linkStatusText() end,
            sub_item_table_func = function() return self:shelfMenu() end,
            hold_callback = function() Actions.showSheet(ctx) end,
            hold_keep_menu_open = false,
        })
        table.insert(items, {
            text_func = function()
                local progress_type, value, total = Actions.readingPosition(ctx)
                return T(_("Update progress (%1)"),
                    Actions.positionLabel(progress_type, value, total))
            end,
            callback = function() Actions.updateProgress(ctx) end,
        })
        table.insert(items, {
            text = _("Rate and comment…"),
            callback = function() Actions.rateAndComment(ctx) end,
        })
        table.insert(items, {
            text = _("Add note…"),
            callback = function() Actions.addNote(ctx) end,
        })
        table.insert(items, {
            text = _("Upload all highlights and notes…"),
            help_text = _("Posts every highlight and note in this book that NeoDB has not been told about, however long ago you made it. Works whether the per-book switch under “This book” is on or not."),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Annotations.uploadAll(ctx) end,
            separator = true,
        })
    end

    table.insert(items, {
        text_func = function() return self:queueRowText() end,
        --[[--
        Also reachable with an empty queue, when the last attempt left something
        worth reading: an upload given up on in the background is otherwise a thing
        that happened to the reader with no way to find out about it.
        ]]
        enabled_func = function()
            return self.store:queueCount() > 0 or self:lastFlushNote() ~= nil
        end,
        sub_item_table_func = function() return self:queueMenu() end,
    })

    table.insert(items, {
        text_func = function()
            if not self.store:isLoggedIn() then return _("Sign in to NeoDB…") end
            return T(_("Account: %1"), self.store:getAccountLabel() or "?")
        end,
        keep_menu_open = false,
        callback = function() Login.show(ctx) end,
    })

    if self:isReader() then
        table.insert(items, {
            text = _("Settings for this book"),
            sub_item_table_func = function() return self:linkMenu() end,
        })
    end

    table.insert(items, {
        text = _("Settings"),
        sub_item_table_func = function() return self:settingsMenu() end,
    })

    --[[--
    Below the settings, and outside the reader-only block above: a post is the one
    thing here that is about nothing in particular, so it needs no book and belongs
    in the file browser too.
    ]]
    table.insert(items, {
        text = _("Post something…"),
        help_text = _("Writes a post on your NeoDB account, with no book attached to it. Queued like everything else if you are offline."),
        keep_menu_open = false,
        callback = function() Actions.postStatus(ctx) end,
    })

    return items
end

function NeoDB:shelfMenu()
    local ctx = self.ctx
    local items = {}
    for _idx, shelf in ipairs(Util.SHELVES) do
        table.insert(items, {
            text = Util.shelfLabel(shelf),
            checked_func = function()
                local link = self.store:getLink(self.ui.doc_settings)
                return link and link.mark and link.mark.shelf_type == shelf or false
            end,
            radio = true,
            keep_menu_open = false,
            callback = function() Actions.setShelf(ctx, shelf) end,
            separator = shelf == Util.SHELVES[#Util.SHELVES],
        })
    end

    --[[--
    The one row that is not a status.

    The quick sheet is opened by holding the row above this one, and nothing said
    so: KOReader shows `help_text` on hold only when a row has no `hold_callback`,
    so the hint cannot go where the gesture is. A row that opens the sheet can,
    and it is also how a reader finds the thing worth binding to a gesture.
    ]]
    table.insert(items, {
        text = _("Quick actions…"),
        help_text = _("One screen with the status, progress, rating and notes on it. Holding the row this menu came from opens it too, as does the “NeoDB: book actions” gesture."),
        keep_menu_open = false,
        callback = function() Actions.showSheet(ctx) end,
    })

    -- Removing the mark lives under "This book", with the other undoing.
    return items
end

function NeoDB:linkMenu()
    local ctx = self.ctx
    return {
        {
            text = _("Show linked book"),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Match.showLinkedInfo(ctx) end,
        },
        {
            text = _("Refresh book info from NeoDB"),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function()
                Match.refreshMark(ctx, function()
                    Util.notify(self:linkStatusText())
                end)
            end,
        },
        {
            text = _("Upload new highlights and notes for this book"),
            help_text = _("Posts every highlight and note you make in this book from now on to NeoDB, quietly and without asking: the passage, whatever you wrote about it, and where in the book it is. What the book already holds is left alone."),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            checked_func = function() return Annotations.isEnabled(ctx) end,
            callback = function()
                Annotations.setEnabled(ctx, not Annotations.isEnabled(ctx))
            end,
            separator = true,
        },
        {
            text = _("Remove mark from NeoDB…"),
            help_text = _("Deletes your status, rating and comment for this book from NeoDB. The book stays linked."),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Actions.removeMark(ctx) end,
        },
        {
            text = _("Unlink this book…"),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Match.unlink(ctx) end,
        },
        {
            text = _("Find this book on NeoDB…"),
            keep_menu_open = false,
            callback = function() Match.autoMatch(ctx) end,
        },
        {
            text = _("Find by title or author…"),
            keep_menu_open = false,
            callback = function()
                local meta = Match.getBookMeta(self.ui)
                Match.searchPrompt(ctx, meta.query)
            end,
        },
        {
            text = _("Link by URL…"),
            keep_menu_open = false,
            callback = function() Match.promptUrl(ctx) end,
            separator = true,
        },
    }
end

--[[--
Reasons the queue will not start moving again on its own.

A connection that comes and goes is the ordinary state of an e-reader, so a
flush that could not reach the server is not worth calling the queue paused over
-- it will go out with the next one. These will not.
]]
local STUCK_REASONS = {
    unauthorized = true,
    forbidden    = true,
    rate_limited = true,
}

--[[--
Why the last flush did not simply work, in one line, or nil when it did.

Only the outcomes a reader can act on: uploads that stopped and are waiting for
something, and uploads given up on for good.
]]
function NeoDB:lastFlushNote()
    local last = self.store:getLastFlush()
    if type(last) ~= "table" then return nil end

    if last.stopped == "unauthorized" or last.stopped == "forbidden" then
        return _("Paused: NeoDB did not accept your login. Sign in again to send these.")
    elseif last.stopped == "rate_limited" then
        return _("Paused: NeoDB asked us to slow down. Try again in a minute.")
    elseif last.stopped == "timeout" or last.stopped == "network_error" then
        return _("Paused: the NeoDB server could not be reached.")
    end

    if (last.dropped or 0) > 0 then
        return T(_("%1 upload(s) could not be sent and were given up on."), last.dropped)
    end
    return nil
end

function NeoDB:queueRowText()
    local pending = self.store:queueCount()
    if pending == 0 then
        -- Something was given up on: the count is zero because they are gone, not
        -- because they arrived, and saying "all sent" would be a lie.
        local last = self.store:getLastFlush()
        if type(last) == "table" and (last.dropped or 0) > 0 then
            return T(_("Uploads: %1 could not be sent"), last.dropped)
        end
        return _("Uploads: all sent")
    end
    -- Only when they will not move again by themselves; the submenu still carries
    -- the detail of a flush that merely could not reach the server.
    local last = self.store:getLastFlush()
    if type(last) == "table" and STUCK_REASONS[last.stopped] then
        return T(_("Uploads: %1 waiting, paused"), pending)
    end
    return T(_("Uploads: %1 waiting"), pending)
end

function NeoDB:queueMenu()
    local ctx = self.ctx
    local items = {}

    -- Why nothing is moving, first, since it is the thing that explains the rest.
    local note = self:lastFlushNote()
    if note then
        table.insert(items, { text = note, enabled = false, separator = true })
    end

    table.insert(items, {
        text = _("Upload now"),
        enabled_func = function() return self.store:queueCount() > 0 end,
        keep_menu_open = false,
        callback = function() Actions.flushQueue(ctx, false) end,
    })
    table.insert(items, {
        text = _("Discard pending uploads…"),
        enabled_func = function() return self.store:queueCount() > 0 end,
        keep_menu_open = false,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Discard %1 pending upload(s)?"), self.store:queueCount()),
                ok_text = _("Discard"),
                ok_callback = function()
                    self.store:clearQueue()
                    Util.notify(_("Pending uploads discarded."))
                end,
            })
        end,
        separator = true,
    })

    -- List what is actually waiting, so "3 waiting" is not a mystery.
    for _idx, op in ipairs(self.store:getQueue()) do
        table.insert(items, {
            text = op.label or _("Pending change"),
            enabled = false,
        })
    end
    return items
end

--- Where to send a reader who wants the whole story.
local NEODB_HOME = "https://neodb.net"

--[[--
What NeoDB actually is, for whoever installed this without knowing.

A TextViewer rather than the `Util.alert` the About row uses: this is a few hundred
characters, and an InfoMessage does not scroll, so on a small screen the end of it
would simply be off the bottom.

The QR code and clipboard buttons are the two the linked-book sheet already offers,
and are here for the same reason -- "learn more at a URL" is not something a device
with no browser can act on by itself.
]]
local function showWhatIsNeoDB()
    local viewer
    local buttons = {{
        {
            text = _("Close"),
            callback = function() UIManager:close(viewer) end,
        },
    }}
    if Device:hasClipboard() then
        table.insert(buttons, 1, {{
            text = _("Copy link to clipboard"),
            callback = function()
                Util.copyToClipboard(NEODB_HOME)
                Util.notify(_("Link copied."))
            end,
        }})
    end
    if Util.hasQRCode() then
        table.insert(buttons, 1, {{
            text = _("Show QR code"),
            callback = function() Util.showQRCode(NEODB_HOME) end,
        }})
    end

    viewer = TextViewer:new{
        title = _("What is NeoDB"),
        text = T(_([[NeoDB is a free open-sourced software and a distributed community, somewhat similar to Goodreads, but instead of being a single commercial service holding everyone's data, NeoDB is a network of self-hosted servers that interconnected via open protocols like ActivityPub and ATProto. You may use NeoDB to share your reading journey with friends on Mastodon and Bluesky, or use it purely for private reading log, as NeoDB's privacy setup supports both.

Learn more at %1]]), NEODB_HOME),
        text_type = "book_info",
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

function NeoDB:settingsMenu()
    local store = self.store
    local ctx = self.ctx

    local visibility_items = {}
    for _idx, visibility in ipairs(Util.VISIBILITIES) do
        table.insert(visibility_items, {
            text = Util.visibilityLabel(visibility),
            checked_func = function() return store:get("default_visibility") == visibility end,
            radio = true,
            callback = function() store:set("default_visibility", visibility) end,
        })
    end

    local unit_items = {}
    local units = {
        { key = "auto",       text = _("Automatic") },
        { key = "page",       text = _("Page number") },
        { key = "percentage", text = _("Percentage") },
    }
    for _idx, unit in ipairs(units) do
        table.insert(unit_items, {
            text = unit.text,
            help_text = unit.key == "auto"
                and _("Page numbers for fixed-layout files and for EPUBs with publisher page numbers; percentage otherwise, since reflowed page numbers differ on every device.")
                or nil,
            checked_func = function() return store:get("progress_unit") == unit.key end,
            radio = true,
            callback = function() store:set("progress_unit", unit.key) end,
        })
    end

    return {
        {
            text_func = function()
                return T(_("Default visibility: %1"),
                    Util.visibilityLabel(store:get("default_visibility")))
            end,
            sub_item_table = visibility_items,
        },
        {
            text_func = function()
                return T(_("Progress unit: %1"), (function()
                    local unit = store:get("progress_unit")
                    if unit == "page" then return _("page number") end
                    if unit == "percentage" then return _("percentage") end
                    return _("automatic")
                end)())
            end,
            sub_item_table = unit_items,
        },
        {
            text = _("Automatically update progress"),
            help_text = _("Every hour while reading, and when the book is closed -- whenever the position moved. Only for books already marked on NeoDB. Queued silently; nothing turns on Wi-Fi."),
            checked_func = function() return store:get("auto_progress") end,
            callback = function() store:toggle("auto_progress") end,
        },
        {
            text = _("Mark as Finished at the end of a book"),
            help_text = _("When you reach the last page of a linked book, set its NeoDB status to Finished."),
            checked_func = function() return store:get("auto_mark_finished") end,
            callback = function() store:toggle("auto_mark_finished") end,
        },
        {
            text = _("Upload new highlights and notes"),
            help_text = _("What a book starts with when it is linked. Every highlight and note you then make in it is posted to NeoDB as a note."),
            checked_func = function() return store:get("auto_upload_annotations") end,
            callback = function() store:toggle("auto_upload_annotations") end,
        },
        {
            text = _("Quote highlights as block quotes"),
            help_text = _("Prefixes shared highlights with \"> \" so they read as a quotation."),
            checked_func = function() return store:get("quote_as_blockquote") end,
            callback = function() store:toggle("quote_as_blockquote") end,
        },
        {
            text = _("Crosspost to connected social networks"),
            help_text = _("Ratings, notes and comments are always saved to NeoDB. This also announces them to your followers."),
            checked_func = function() return store:get("post_to_fediverse") end,
            callback = function() store:toggle("post_to_fediverse") end,
        },
        {
            text = _("Crosspost shared highlights"),
            help_text = _("Announces each shared highlight to your followers as well."),
            checked_func = function() return store:get("crosspost_annotations") end,
            callback = function() store:toggle("crosspost_annotations") end,
            separator = true,
        },
        {
            text_func = function()
                local portal = store:get("portal_url")
                return T(_("Pairing service: %1"),
                    portal ~= "" and Util.instanceHost(portal) or _("off"))
            end,
            help_text = _("Used by the QR code sign-in, which lets you choose a server and sign in on your phone. It only ever holds one sign-in for a few minutes. Clear it to hide that option."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local dialog
                dialog = InputDialog:new{
                    title = _("Pairing service"),
                    description = _("Address of the service used for QR code sign-in. Leave empty to turn that option off."),
                    input = store:get("portal_url") or "",
                    input_hint = "https://p.neodb.net",
                    buttons = {{
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local entered = util.trim(dialog:getInputText())
                                if entered == "" then
                                    store:set("portal_url", "")
                                else
                                    local normalized = Util.normalizeInstance(entered)
                                    if not normalized then
                                        Util.alert(_("That does not look like a server address."))
                                        return
                                    end
                                    store:set("portal_url", normalized)
                                end
                                UIManager:close(dialog)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
            separator = true,
        },
        {
            text = _("About this plugin"),
            keep_menu_open = true,
            callback = function()
                Util.alert(T(_([[NeoDB for KOReader

Instance: %1
Account: %2

Marks, notes and progresses are saved to your NeoDB account. Anything made while offline is queued and uploaded next time you are online.]]),
                    Util.instanceHost(store:getInstance() or "") ~= "" and Util.instanceHost(store:getInstance()) or _("not set"),
                    store:getAccountLabel() or _("not signed in")))
            end,
        },
        {
            text = _("What is NeoDB…"),
            keep_menu_open = true,
            callback = showWhatIsNeoDB,
        },
    }
end

-- Automatic syncing ---------------------------------------------------------
--
-- Both hooks below are opt-in and deliberately quiet. They never turn Wi-Fi on
-- by themselves: work is queued and flushed the next time the reader does
-- something online, so finishing a book never triggers a radio and a dialog.

--- Uploads the queue after the current screen has been drawn, if we can.
function NeoDB:flushSoon()
    Actions.flushSoon(self.ctx)
end

--[[--
Notices that the reader's own highlights changed.

Nothing is decided here. KOReader announces a highlight the moment it saves one,
which for "Add note" is before the note editor has even opened, and extending a
selection deletes the annotation and makes a new one -- so we only note that
something moved, and let it settle.
]]
function NeoDB:onAnnotationsModified()
    if not self:isReader() then return end
    if not Annotations.isEnabled(self.ctx) then return end
    self:scheduleAnnotationSync()
    -- Deliberately no `return true`: KOReader's own listeners want this too.
end

function NeoDB:scheduleAnnotationSync()
    UIManager:unschedule(self.annotation_task)
    UIManager:scheduleIn(ANNOTATION_SETTLE_SECONDS, self.annotation_task)
end

--[[--
Queues whatever is new, once the reader is not in the middle of something.

Anything on screen above the book means they are: the note editor is a dialog and
its keyboard is another, so a quote queued while the note is still being typed
would go out without it. Waiting costs nothing -- the timer comes round again.
]]
function NeoDB:syncAnnotations()
    if not self:isReader() then return end
    if UIManager.getTopmostVisibleWidget
        and UIManager:getTopmostVisibleWidget() ~= self.ui then
        return self:scheduleAnnotationSync()
    end
    local queued = Annotations.queueNew(self.ctx)
        + Annotations.queueDeletions(self.ctx)
    if queued > 0 then self:flushSoon() end
end

--[[--
Records where a linked book stands, if it moved -- hourly and when it closes.

Queued, never sent from here: a request can block the UI thread for the length
of its timeout, and neither a page turn nor closing a book must stall on a bad
connection. It goes out with the next upload instead.

@treturn bool whether an update was queued
]]
function NeoDB:queueProgressIfMoved()
    if not self.store:get("auto_progress") then return false end
    if not self.store:isLoggedIn() then return false end

    local link = self.store:getLink(self.ui.doc_settings)
    if not link then return false end

    -- Progress hangs off the mark, so there has to be one. Creating a mark as a
    -- side effect of a timer or of closing a book would be presumptuous, so skip.
    if not (link.mark and link.mark.shelf_type) then return false end

    local progress_type, value = Actions.readingPosition(self.ctx)
    local last = link.progress
    if last and last.type == progress_type and last.value == tostring(value) then
        return false -- nothing moved since last time
    end

    -- A queue with no room leaves the position unrecorded on purpose: caching it
    -- would make the next tick think it had already been sent.
    local taken = self.store:enqueue({
        method = "POST",
        path   = self.api:progressPath(link.uuid),
        body   = { type = progress_type, value = tostring(value) },
        label  = T(_("Progress for “%1”"), link.title or "?"),
        dedup  = "progress:" .. link.uuid,
    })
    if not taken then return false end
    self.store:cacheProgress(self.ui.doc_settings, progress_type, tostring(value))
    logger.dbg("NeoDB: queued progress", progress_type, value)
    return true
end

--[[--
The hourly half of "Automatically update progress".

Reschedules itself first, so one bad tick cannot kill the clock, and stays
scheduled while the switch is off -- the reader may flip it mid-book and expect
it to count from then. `flushSoon` already declines to touch the radio, so a
tick costs nothing when offline and nothing has moved.
]]
function NeoDB:progressTick()
    if not self:isReader() then return end
    UIManager:scheduleIn(PROGRESS_TICK_SECONDS, self.progress_task)
    if self:queueProgressIfMoved() then self:flushSoon() end
end

--[[--
Last call before the book goes away.

Both halves only queue, for the reason above, and the settle timer has to go: it
would otherwise come round to a document that is no longer there.
]]
function NeoDB:onCloseDocument()
    if not self:isReader() then return end
    UIManager:unschedule(self.annotation_task)
    UIManager:unschedule(self.progress_task)
    Annotations.queueNew(self.ctx)
    Annotations.queueDeletions(self.ctx)
    self:queueProgressIfMoved()
end

--[[--
Marks a linked book Finished when the reader reaches the end.

KOReader's own end-of-book dialog is already on screen at this point, so we stay
out of the way and only show a short notification.
]]
function NeoDB:onEndOfBook()
    if not self:isReader() then return end
    if not self.store:get("auto_mark_finished") then return end
    if not self.store:isLoggedIn() then return end

    local link = self.store:getLink(self.ui.doc_settings)
    if not link then return end
    if link.mark and link.mark.shelf_type == "complete" then return end

    --[[--
    All of it on the next tick, so KOReader's own end-of-book dialog is painted
    first: reading the mark below can take the UI thread for the length of a
    request, and queueing writes a settings file.
    ]]
    UIManager:nextTick(function()
        --[[--
        `assume`, because there is no reader in front of this: an unknown mark is
        read when that is possible and otherwise written over. Not marking the book
        at all would fail the switch they turned on.
        ]]
        Actions.withKnownMark(self.ctx, link, function(known)
            self:queueFinished(known)
        end, { assume = true })
    end)
    -- Deliberately no `return true`: KOReader's end-of-book handling continues.
end

--- The second half of `onEndOfBook`, once the mark is as known as it can be.
function NeoDB:queueFinished(link)
    -- Shared builder, so the no-clobber rules and the array-encoding fix live in
    -- exactly one place.
    local body = Actions.markBody(self.ctx, link, {
        shelf_type        = "complete",
        post_to_fediverse = self.store:get("post_to_fediverse"),
    })

    local taken = self.store:enqueue({
        method = "POST",
        path   = self.api:markPath(link.uuid),
        body   = body,
        label  = T(_("Mark “%1” as Finished"), link.title or "?"),
        dedup  = "mark:" .. link.uuid,
    })
    if not taken then
        -- Nothing is cached either, so reaching the end again will try afresh.
        Util.notify(_("Could not mark as Finished: too many uploads are waiting."))
        return
    end
    self.store:cacheMark(self.ui.doc_settings, body)
    Util.notify(_("Marked as Finished on NeoDB."))
    self:flushSoon()
end

--[[--
Housekeeping for the book that has just opened.

No Wi-Fi is turned on for any of it and nothing is reported: the queue is only
drained when the device happens to be connected already.
]]
function NeoDB:onReaderReady()
    -- A note uuid that could not be filed when its post went out, because this
    -- book was closed or had moved. Opening it is the next chance to put the uuid
    -- where an edit would go looking for it.
    Annotations.adoptStashed(self.ctx)

    -- The hourly progress clock. Scheduled whether or not the switch is on --
    -- the tick checks -- so flipping it mid-book needs no replumbing.
    if self.progress_task then
        UIManager:scheduleIn(PROGRESS_TICK_SECONDS, self.progress_task)
    end

    if self.store:queueCount() == 0 then return end
    if not self.store:isLoggedIn() then return end
    self:flushSoon()
end

return NeoDB
