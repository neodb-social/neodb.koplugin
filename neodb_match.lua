--[[--
Matching the open file to a NeoDB catalog entry, and remembering the result.

The link is the foundation for everything else, so it is worth getting right
with as little typing as possible: we try the book's ISBN first (a server-
confirmed match needs no confirmation at all), then fall back to a title and
author search, then to whatever the reader types.

@module koplugin.neodb.match
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Util = require("neodb_util")

local Match = {}

--- Everything we know about the open file that might help identify it.
function Match.getBookMeta(ui)
    local props = ui.doc_props or {}
    local path = ui.document and ui.document.file or ""
    local basename = path:match("([^/\\]+)$") or path
    local filename = basename:gsub("%.%w+$", "")

    -- The sidecar keeps only a fixed set of properties; the document itself may
    -- still expose a description or keywords that mention the ISBN.
    local raw = {}
    if ui.document and ui.document.getProps then
        local ok, result = pcall(ui.document.getProps, ui.document)
        if ok and type(result) == "table" then raw = result end
    end

    -- KOReader joins multiple authors with newlines.
    local authors = props.authors or raw.authors
    local first_author = authors and authors:match("^[^\n]+") or nil

    local title = props.title or raw.title
    local query_parts = {}
    if title then table.insert(query_parts, title) end
    if first_author then table.insert(query_parts, first_author) end

    return {
        title    = title,
        authors  = authors,
        author   = first_author,
        filename = filename,
        pages    = props.pages,
        isbn     = Util.findISBN(props.keywords, raw.keywords, raw.description, filename),
        query    = #query_parts > 0 and table.concat(query_parts, " ") or filename,
    }
end

local function isBookItem(item)
    return type(item) == "table" and item.uuid and (item.category == "book" or item.category == nil)
end

--- An entry whose ISBN the server itself reports as ours needs no confirmation.
local function findExactIsbn(results, isbn)
    for _idx, item in ipairs(results or {}) do
        if isBookItem(item) and type(item.isbn) == "string" then
            local candidate = item.isbn:gsub("[%s%-]", ""):upper()
            if candidate == isbn then return item end
        end
    end
    return nil
end

--- Multi-line description of a catalog entry, for confirmation and info screens.
function Match.describeItem(item)
    local lines = { item.title or item.display_title or _("Untitled") }
    if item.subtitle then table.insert(lines, item.subtitle) end

    local author = Util.joinList(item.author)
    if author then table.insert(lines, T(_("By %1"), author)) end

    local translator = Util.joinList(item.translator)
    if translator then table.insert(lines, T(_("Translated by %1"), translator)) end

    local publisher = Util.joinList(item.publisher)
    local published = publisher
    if item.pub_year then
        published = published and T("%1, %2", published, tostring(item.pub_year))
            or tostring(item.pub_year)
    end
    if published then table.insert(lines, published) end

    if item.isbn then table.insert(lines, T(_("ISBN %1"), item.isbn)) end
    if item.pages then table.insert(lines, T(_("%1 pages"), tostring(item.pages))) end
    if item.rating and item.rating_count and item.rating_count > 0 then
        table.insert(lines, T(_("NeoDB rating: %1 (%2 ratings)"),
            string.format("%.1f", item.rating), tostring(item.rating_count)))
    end

    return table.concat(lines, "\n")
end

-- Linking -------------------------------------------------------------------

--[[--
Stores the link and seeds the cached mark from the server.

We are already online at this point, so one extra request buys us an accurate
status display and, more importantly, the existing rating/comment/tags that a
later status change must not clobber.
]]
function Match.linkTo(ctx, item, on_done)
    local link = {
        uuid   = item.uuid,
        -- The catalog sends `url` as a path and the absolute address as `id`;
        -- resolve now, so what we store is something a phone can open.
        url    = Util.absoluteUrl(ctx.store:getInstance(), item.url or item.id),
        title  = item.title or item.display_title,
        author = Util.joinList(item.author),
        isbn   = item.isbn,
        pages  = tonumber(item.pages),
    }
    ctx.store:setLink(ctx.ui.doc_settings, link)

    local done = Util.busy(_("Reading your NeoDB status for this book…"))
    local ok, mark = ctx.api:getMark(item.uuid)
    done()
    if ok then
        ctx.store:cacheMark(ctx.ui.doc_settings, mark)
    end

    --[[--
    The status just read is what the dialog opens on, so this costs no extra
    request. `neodb_actions` is resolved here rather than at the top of the file:
    it requires this module, and requiring it back would be a cycle.

    `on_done` waits for the dialog rather than firing under it -- whoever asked
    for the match usually wants the screen next, and today that meant a sheet
    opening on top of the answer.
    ]]
    require("neodb_actions").showLinkOptions(ctx, on_done)
end

function Match.confirmLink(ctx, item, on_done)
    UIManager:show(ConfirmBox:new{
        text = T(_("Link this book to:\n\n%1"), Match.describeItem(item)),
        ok_text = _("Link"),
        ok_callback = function()
            Util.whenOnline(function() Match.linkTo(ctx, item, on_done) end)
        end,
    })
end

-- Searching -----------------------------------------------------------------

function Match.showResults(ctx, result, query, page, on_done)
    local menu
    local items = {}

    for _idx, item in ipairs(result.data or {}) do
        if isBookItem(item) then
            -- Search often returns several editions of the same work, so name
            -- the publisher: it is usually what tells them apart.
            local label = item.title or item.display_title or _("Untitled")
            local author = Util.joinList(item.author)
            if author then label = label .. " — " .. author end
            local publisher = Util.joinList(item.publisher)
            if publisher then label = label .. " · " .. publisher end

            table.insert(items, {
                text = label,
                mandatory = item.pub_year and tostring(item.pub_year) or nil,
                callback = function()
                    UIManager:close(menu)
                    Match.confirmLink(ctx, item, on_done)
                end,
            })
        end
    end

    if #items == 0 then
        Util.alert(T(_("Nothing on NeoDB matched “%1”."), Util.ellipsize(query, 60)))
        return Match.searchPrompt(ctx, query, on_done)
    end

    if (result.pages or 1) > page then
        table.insert(items, {
            text = T(_("More results (page %1 of %2)…"), page + 1, tostring(result.pages)),
            callback = function()
                UIManager:close(menu)
                Match.runSearch(ctx, query, page + 1, on_done)
            end,
        })
    end

    table.insert(items, {
        text = _("Search with different words…"),
        callback = function()
            UIManager:close(menu)
            Match.searchPrompt(ctx, query, on_done)
        end,
    })

    menu = Menu:new{
        title = T(_("NeoDB: %1 result(s)"), tostring(result.count or #items)),
        subtitle = Util.ellipsize(query, 70),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        -- Titles plus author plus publisher rarely fit one line on a 6" screen.
        multilines_show_more_text = true,
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Match.runSearch(ctx, query, page, on_done)
    Util.whenOnline(function()
        local done = Util.busy(T(_("Searching NeoDB for “%1”…"), Util.ellipsize(query, 40)))
        local ok, data, code = ctx.api:searchBooks(query, page)
        done()
        if not ok then
            Util.alert(ctx.api:errorMessage(data, code))
            return
        end
        Match.showResults(ctx, data, query, page, on_done)
    end)
end

function Match.searchPrompt(ctx, initial_query, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Search NeoDB for a book"),
        description = _("Title, author, or ISBN."),
        input = initial_query or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = Util.trim(dialog:getInputText())
                    if query == "" then return end
                    UIManager:close(dialog)
                    Match.runSearch(ctx, query, 1, on_done)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
Identifies the open book, with as few taps as possible.

A checksum-valid ISBN that the server confirms is linked outright; anything less
certain is put in front of the reader to confirm.
]]
function Match.autoMatch(ctx, on_done)
    local meta = Match.getBookMeta(ctx.ui)

    Util.whenOnline(function()
        if meta.isbn then
            local done = Util.busy(T(_("Looking up ISBN %1 on NeoDB…"), meta.isbn))
            local ok, data = ctx.api:searchBooks(meta.isbn, 1)
            done()
            if ok and data.data then
                local exact = findExactIsbn(data.data, meta.isbn)
                if exact then
                    -- The server agrees on the ISBN, so this is not a guess.
                    return Match.linkTo(ctx, exact, on_done)
                end
                if #data.data > 0 then
                    return Match.showResults(ctx, data, meta.isbn, 1, on_done)
                end
            end
        end

        local query = meta.query
        if not query or Util.trim(query) == "" then
            return Match.searchPrompt(ctx, "", on_done)
        end

        local done = Util.busy(T(_("Searching NeoDB for “%1”…"), Util.ellipsize(query, 40)))
        local ok, data, code = ctx.api:searchBooks(query, 1)
        done()
        if not ok then
            Util.alert(ctx.api:errorMessage(data, code))
            return
        end
        Match.showResults(ctx, data, query, 1, on_done)
    end)
end

--[[--
Offers to identify a book the first time it opens.

Returns true when the offer was made, so the caller can tell "asked" from "not
now" without reading the sidecar back.

Everything about this is shaped by its being uninvited. It happens once per book
and says so; it carries its own off switch, because a prompt nobody asked for
with no visible way to stop it is the thing readers uninstall a plugin over; and
it gives up rather than waiting for a better moment, since a dialog arriving in
the middle of a page is worse than one that never arrives at all.

@treturn bool whether the dialog was shown
]]
function Match.offerLink(ctx)
    if ctx.store:get("offer_link_on_open") ~= true then return false end
    -- A prompt that leads straight into a sign-in wall is worse than no prompt.
    if not ctx.store:isLoggedIn() then return false end

    local doc_settings = ctx.ui.doc_settings
    if not doc_settings then return false end
    if ctx.store:linkOffered(doc_settings) then return false end

    --[[--
    Any link at all, including one this account cannot use: a book linked against
    another server was linked on purpose, and a bare "find this book?" is not the
    place to explain what became of it. The shelf menu already says that, to
    somebody who went looking.
    ]]
    local link, foreign = ctx.store:getLink(doc_settings)
    if link or foreign then
        -- Recorded even so, so the question is settled for good either way.
        ctx.store:markLinkOffered(doc_settings)
        return false
    end

    local meta = Match.getBookMeta(ctx.ui)
    local title = meta.title or meta.filename
    local lines = {}
    if title and Util.trim(title) ~= "" then
        table.insert(lines, T(_("“%1”"), Util.ellipsize(title, 50)))
        table.insert(lines, "")
    end
    table.insert(lines, _("Find this book on NeoDB?"))
    table.insert(lines, "")
    table.insert(lines, _("Each book gets this question one time."))

    -- Before the dialog rather than after an answer: a dismissal, or the device
    -- dying while it is up, must not buy the reader a second one.
    ctx.store:markLinkOffered(doc_settings)

    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "center",
        buttons = {
            --[[--
            The one affirmative gets a row to itself; the two ways of declining
            share the one below. Tapping outside is a third way of declining, and
            costs nothing, the offer being already recorded.
            ]]
            {
                {
                    text = _("Find book"),
                    callback = function()
                        UIManager:close(dialog)
                        Match.autoMatch(ctx)
                    end,
                },
            },
            {
                {
                    text = _("Not this book"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Stop asking"),
                    callback = function()
                        UIManager:close(dialog)
                        ctx.store:set("offer_link_on_open", false)
                        Util.notify(_("You will not be asked again. Turn this back on in the NeoDB settings."))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

--[[--
Links by URL.

NeoDB can resolve its own item pages and a number of third-party book sites, so
pasting a link is often the fastest route for a book its search does not surface.
]]
function Match.promptUrl(ctx, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Link by URL"),
        description = _("Paste a NeoDB book link, or a link from a site NeoDB can import from."),
        input_hint = "https://neodb.social/book/…",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Look up"),
                is_enter_default = true,
                callback = function()
                    local url = Util.trim(dialog:getInputText())
                    if url == "" then return end
                    UIManager:close(dialog)
                    Util.whenOnline(function()
                        local done = Util.busy(_("Asking NeoDB about that link…"))
                        local ok, data, code = ctx.api:fetchByUrl(url)
                        done()
                        if not ok then
                            Util.alert(ctx.api:errorMessage(data, code))
                            return
                        end
                        if not data.uuid then
                            -- 202: NeoDB accepted the URL and is fetching it.
                            Util.alert(_("NeoDB is still importing that page. Try again in a moment."))
                            return
                        end
                        if data.category and data.category ~= "book" then
                            Util.alert(T(_("That link is a %1, not a book."), tostring(data.category)))
                            return
                        end
                        Match.confirmLink(ctx, data, on_done)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Managing an existing link --------------------------------------------------

function Match.showLinkedInfo(ctx)
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then
        Util.alert(_("This book is not linked to NeoDB yet."))
        return
    end

    -- Resolve here as well as on save: a link made by an earlier version holds a
    -- bare path, and this is the screen its URL is offered from.
    local url = Util.absoluteUrl(link.instance or ctx.store:getInstance(), link.url)

    local lines = { link.title or _("Untitled") }
    if link.author then table.insert(lines, link.author) end
    if link.isbn then table.insert(lines, T(_("ISBN %1"), link.isbn)) end
    if link.pages then table.insert(lines, T(_("%1 pages"), tostring(link.pages))) end
    table.insert(lines, "")

    local mark = link.mark
    if mark then
        table.insert(lines, T(_("Status: %1"), Util.shelfLabel(mark.shelf_type)))
        table.insert(lines, T(_("Rating: %1"), Util.ratingLabel(mark.rating_grade)))
        table.insert(lines, T(_("Visibility: %1"), Util.visibilityLabel(mark.visibility)))
        if mark.comment_text and mark.comment_text ~= "" then
            table.insert(lines, T(_("Comment: %1"), mark.comment_text))
        end
        local tags = Util.joinList(mark.tags)
        if tags then table.insert(lines, T(_("Tags: %1"), tags)) end
    else
        table.insert(lines, _("Status: not known yet (never synced)."))
    end

    if link.progress and link.progress.value then
        table.insert(lines, T(_("Last progress sent: %1 %2"),
            tostring(link.progress.value), tostring(link.progress.type)))
    end

    if url then
        table.insert(lines, "")
        table.insert(lines, url)
    end

    local viewer
    local buttons = {{
        {
            text = _("Refresh from NeoDB"),
            callback = function()
                UIManager:close(viewer)
                Match.refreshMark(ctx, function() Match.showLinkedInfo(ctx) end)
            end,
        },
        {
            text = _("Close"),
            callback = function() UIManager:close(viewer) end,
        },
    }}
    if url and Device:hasClipboard() then
        table.insert(buttons, 1, {{
            text = _("Copy link to clipboard"),
            callback = function()
                Util.copyToClipboard(url)
                Util.notify(_("Link copied."))
            end,
        }})
    end
    if url and Util.hasQRCode() then
        -- The quickest way off the device: scan it and carry on reading about
        -- the book on a phone.
        table.insert(buttons, 1, {{
            text = _("Show QR code"),
            callback = function() Util.showQRCode(url) end,
        }})
    end

    viewer = TextViewer:new{
        title = _("Linked NeoDB book"),
        text = table.concat(lines, "\n"),
        text_type = "book_info",
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

--[[--
Re-points the stored link at the item this one was merged into.

NeoDB merges duplicate catalog entries, and afterwards the uuid we stored answers
with a redirect to whichever entry survived. The API client spots that and calls
here, so the link is corrected once rather than every request paying for it.

The survivor can be a different edition, so its details are refetched rather than
assumed: the title, ISBN, page count and URL all belong to the old entry.
]]
function Match.adoptMerge(ctx, old_uuid, new_uuid)
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link or link.uuid ~= old_uuid or old_uuid == new_uuid then return end

    link.uuid = new_uuid
    -- Anything we cannot confirm belongs to the entry that just went away.
    local ok, item = ctx.api:getBook(new_uuid)
    if ok and type(item) == "table" and item.uuid then
        link.url    = Util.absoluteUrl(ctx.store:getInstance(), item.url or item.id)
        link.title  = item.title or item.display_title or link.title
        link.author = Util.joinList(item.author) or link.author
        link.isbn   = item.isbn or link.isbn
        link.pages  = tonumber(item.pages) or link.pages
    else
        -- Keep the uuid fix regardless; a stale URL is better than a stale item.
        link.url = nil
    end
    ctx.store:setLink(ctx.ui.doc_settings, link)
    logger.info("NeoDB: relinked", old_uuid, "to", new_uuid)
    return link
end

--- Pulls the server's current mark into the cache.
function Match.refreshMark(ctx, on_done)
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then return end
    Util.whenOnline(function()
        local done = Util.busy(_("Reading your NeoDB status…"))
        local ok, mark, code = ctx.api:getMark(link.uuid)
        done()
        if not ok then
            Util.alert(ctx.api:errorMessage(mark, code))
            return
        end
        ctx.store:cacheMark(ctx.ui.doc_settings, mark)
        if on_done then on_done() end
    end)
end

function Match.unlink(ctx, on_done)
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then
        Util.alert(_("This book is not linked to NeoDB."))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Unlink this book from “%1”?\n\nYour NeoDB marks are not touched."),
            link.title or "?"),
        ok_text = _("Unlink"),
        ok_callback = function()
            ctx.store:clearLink(ctx.ui.doc_settings)
            Util.notify(_("Unlinked from NeoDB."))
            if on_done then on_done() end
        end,
    })
end

return Match
