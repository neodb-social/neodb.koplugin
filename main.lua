--[[--
NeoDB for KOReader.

Links the book you are reading to an entry on a NeoDB instance, then lets you
set its reading status and progress and share notes, quotes, ratings and reviews
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
local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Actions = require("neodb_actions")
local Api = require("neodb_api")
local Login = require("neodb_login")
local Match = require("neodb_match")
local Store = require("neodb_store")
local Util = require("neodb_util")

local NeoDB = WidgetContainer:extend{
    name = "neodb",
}

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

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Document-only features. The plugin is also loaded in the file browser,
    -- where there is no book to mark.
    if self.ui.document then
        self:addHighlightAction()
    end
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

-- Highlight menu ------------------------------------------------------------

--[[--
Adds "Share on NeoDB" to the text selection menu.

Sharing a quote is the one action worth reaching from inside the text, and the
highlight menu is where the reader already is when they have something to say.
]]
function NeoDB:addHighlightAction()
    if not self.ui.highlight then return end
    self.ui.highlight:addToHighlightDialog("13_neodb_quote", function(this)
        return {
            text = _("Share on NeoDB"),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text.text)
                this:onClose()
                Actions.addNote(self.ctx, { quote = text })
            end,
        }
    end)
end

-- Menu ----------------------------------------------------------------------

--- Short line describing the linked book, shown on the menu entry itself.
function NeoDB:linkStatusText()
    if not self:isReader() then
        return self.store:isLoggedIn() and self.store:getAccountLabel() or _("Not signed in")
    end
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

    -- Status line, doubling as the entry point to the quick sheet.
    table.insert(items, {
        text_func = function() return self:linkStatusText() end,
        enabled_func = function() return self:isReader() end,
        keep_menu_open = false,
        callback = function() Actions.showSheet(ctx) end,
        separator = true,
    })

    if self:isReader() then
        table.insert(items, {
            text = _("Reading status"),
            sub_item_table_func = function() return self:shelfMenu() end,
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
            separator = true,
        })
        table.insert(items, {
            text = _("This book"),
            sub_item_table_func = function() return self:linkMenu() end,
        })
    end

    table.insert(items, {
        text_func = function()
            local pending = self.store:queueCount()
            if pending == 0 then return _("Uploads: all sent") end
            return T(_("Uploads: %1 waiting"), pending)
        end,
        enabled_func = function() return self.store:queueCount() > 0 end,
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

    table.insert(items, {
        text = _("Settings"),
        sub_item_table_func = function() return self:settingsMenu() end,
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
        })
    end
    table.insert(items, {
        text = _("Remove mark from NeoDB…"),
        separator = true,
        keep_menu_open = false,
        callback = function() Actions.removeMark(ctx) end,
    })
    return items
end

function NeoDB:linkMenu()
    local ctx = self.ctx
    return {
        {
            text = _("Find this book on NeoDB…"),
            keep_menu_open = false,
            callback = function() Match.autoMatch(ctx) end,
        },
        {
            text = _("Search by title or author…"),
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
        {
            text = _("Show linked book"),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Match.showLinkedInfo(ctx) end,
        },
        {
            text = _("Refresh status from NeoDB"),
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
            text = _("Unlink this book…"),
            enabled_func = function()
                return self.store:getLink(self.ui.doc_settings) ~= nil
            end,
            keep_menu_open = false,
            callback = function() Match.unlink(ctx) end,
        },
    }
end

function NeoDB:queueMenu()
    local ctx = self.ctx
    local items = {
        {
            text = _("Upload now"),
            keep_menu_open = false,
            callback = function() Actions.flushQueue(ctx, false) end,
        },
        {
            text = _("Discard pending uploads…"),
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
        },
    }
    -- List what is actually waiting, so "3 waiting" is not a mystery.
    for _idx, op in ipairs(self.store:getQueue()) do
        table.insert(items, {
            text = op.label or _("Pending change"),
            enabled = false,
        })
    end
    return items
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
            text = _("Crosspost to connected social networks"),
            help_text = _("Marks, notes and reviews are always saved to NeoDB. This also announces them to your followers."),
            checked_func = function() return store:get("post_to_fediverse") end,
            callback = function() store:toggle("post_to_fediverse") end,
        },
        {
            text = _("Quote highlights as block quotes"),
            help_text = _("Prefixes shared highlights with \"> \" so they read as a quotation."),
            checked_func = function() return store:get("quote_as_blockquote") end,
            callback = function() store:toggle("quote_as_blockquote") end,
            separator = true,
        },
        {
            text = _("Send progress when closing a book"),
            help_text = _("Only for linked books, and only if the position moved. Queued silently; nothing is uploaded until you are next online."),
            checked_func = function() return store:get("auto_progress_on_close") end,
            callback = function() store:toggle("auto_progress_on_close") end,
        },
        {
            text = _("Mark as Finished at the end of a book"),
            help_text = _("When you reach the last page of a linked book, set its NeoDB status to Finished."),
            checked_func = function() return store:get("auto_mark_finished") end,
            callback = function() store:toggle("auto_mark_finished") end,
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

Marks, notes and reviews are saved to your NeoDB account. Anything made while offline is queued and uploaded next time you are online.]]),
                    Util.instanceHost(store:getInstance() or "") ~= "" and Util.instanceHost(store:getInstance()) or _("not set"),
                    store:getAccountLabel() or _("not signed in")))
            end,
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
    if not Util.isOnline() then return end
    UIManager:nextTick(function()
        local sent, remaining, dropped = self.api:flushQueue()
        logger.dbg("NeoDB: flushed queue,", sent, "sent,", remaining, "left,", dropped, "dropped")
    end)
end

--[[--
Records progress when a linked book is closed.

Queued, never sent from here: a request can block the UI thread for the length
of its timeout, and closing a book must not stall on a bad connection. It goes
out with the next upload instead.
]]
function NeoDB:onCloseDocument()
    if not self:isReader() then return end
    if not self.store:get("auto_progress_on_close") then return end
    if not self.store:isLoggedIn() then return end

    local link = self.store:getLink(self.ui.doc_settings)
    if not link then return end

    -- Progress hangs off the mark, so there has to be one. Creating a mark as a
    -- side effect of closing a book would be presumptuous, so skip instead.
    if not (link.mark and link.mark.shelf_type) then return end

    local progress_type, value = Actions.readingPosition(self.ctx)
    local last = link.progress
    if last and last.type == progress_type and last.value == tostring(value) then
        return -- nothing moved since last time
    end

    self.store:enqueue({
        method = "POST",
        path   = self.api:progressPath(link.uuid),
        body   = { type = progress_type, value = tostring(value) },
        label  = T(_("Progress for “%1”"), link.title or "?"),
        dedup  = "progress:" .. link.uuid,
    })
    self.store:cacheProgress(self.ui.doc_settings, progress_type, tostring(value))
    logger.dbg("NeoDB: queued closing progress", progress_type, value)
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

    -- Shared builder, so the no-clobber rules and the array-encoding fix live in
    -- exactly one place.
    local body = Actions.markBody(self.ctx, link, {
        shelf_type        = "complete",
        post_to_fediverse = self.store:get("post_to_fediverse"),
    })

    -- Queue, then upload on the next tick. Sending inline would block the UI
    -- thread before KOReader's own end-of-book dialog even gets painted.
    self.store:enqueue({
        method = "POST",
        path   = self.api:markPath(link.uuid),
        body   = body,
        label  = T(_("Mark “%1” as Finished"), link.title or "?"),
        dedup  = "mark:" .. link.uuid,
    })
    self.store:cacheMark(self.ui.doc_settings, body)
    Util.notify(_("Marked as Finished on NeoDB."))
    self:flushSoon()
    -- Deliberately no `return true`: KOReader's end-of-book handling continues.
end

--[[--
Opportunistically drains the upload queue when opening a book.

No Wi-Fi is turned on for this and nothing is reported: it is housekeeping, and
it only runs when the device happens to be connected already.
]]
function NeoDB:onReaderReady()
    if self.store:queueCount() == 0 then return end
    if not self.store:isLoggedIn() then return end
    self:flushSoon()
end

return NeoDB
