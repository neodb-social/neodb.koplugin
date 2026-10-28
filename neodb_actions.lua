--[[--
The things a reader actually wants to do: set a status, send progress, rate,
comment, share a quote or a note, write a review.

Two habits run through this module:

* **Nothing is clobbered.** Posting a mark to NeoDB replaces it wholesale, so a
  plain "Reading -> Finished" would silently erase an existing rating, comment
  and tags. Every write resends the last known values for the fields the reader
  did not touch.
* **Nothing is lost.** Writes go through the upload queue, so a mark made with
  Wi-Fi off is kept and sent later instead of failing.

@module koplugin.neodb.actions
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("neodb_i18n")
local T = require("ffi/util").template

local Login = require("neodb_login")
local Match = require("neodb_match")
local NoteDialog = require("neodb_notedialog")
local Util = require("neodb_util")

--[[--
The post length Takahe accepts by default (its `config.post_length`).

An instance is free to raise it, so this is what a warning is measured against
rather than a limit enforced here.
]]
local POST_LENGTH_LIMIT = 500

local Actions = {}

--[[--
`neodb_annotations`, resolved on first use rather than required at the top.

That module requires this one, so requiring it back here would be a cycle. By the
time any of this can run, both are loaded and this is a table lookup.
]]
local function annotations()
    return require("neodb_annotations")
end

-- Shared plumbing -----------------------------------------------------------

--- Reports the outcome of a queued write in one consistent way.
local function report(ctx, status, data, code, success_text)
    if status == "sent" then
        Util.notify(success_text)
    elseif status == "queued" then
        Util.notify(_("Saved — will upload when you're online."))
    else
        Util.alert(ctx.api:errorMessage(data, code))
    end
    return status ~= "failed"
end

--[[--
Hides an InputDialog's keyboard before something is opened on top of it.

An InputDialog is flagged `is_always_active` and its keyboard is a window of its
own, so a picker stacked above one competes with both for taps and the reader ends
up tapping a dialog that cannot answer. KOReader does the same thing before showing
a ButtonDialog over its dictionary search box.

The keyboard is not brought back afterwards: tapping the text box does that, and an
e-ink screen is better off without the extra repaint.
]]
local function hideKeyboard(dialog)
    if dialog and dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
end

--[[--
Finds a button by id, whichever kind of dialog is holding it.

The two spellings are not interchangeable and there is no common base: an
`InputDialog` and a `TextViewer` keep theirs in `button_table`, a `ButtonDialog`
in `buttontable` -- and only the last exposes a `getButtonById` of its own. Asking
for the wrong one gets nil, which is indistinguishable from "no such button", so
this silently did nothing rather than failing loudly.
]]
local function buttonById(dialog, id)
    if dialog.getButtonById then return dialog:getButtonById(id) end
    local buttons = dialog.button_table or dialog.buttontable
    return buttons and buttons:getButtonById(id)
end

--- Replaces a dialog button's label in place, without rebuilding the dialog.
local function relabel(dialog, id, text)
    local button = buttonById(dialog, id)
    if not button then return end
    -- Passing the existing width keeps the grid geometry, so no full relayout.
    button:setText(text, button.width)
    UIManager:setDirty(dialog, "ui")
end

local function requireLogin(ctx)
    if ctx.store:isLoggedIn() then return true end
    UIManager:show(ConfirmBox:new{
        text = _("You are not signed in to NeoDB yet."),
        ok_text = _("Sign in"),
        ok_callback = function() Login.show(ctx) end,
    })
    return false
end

--[[--
Runs `on_ready(link)` once we have a signed-in account and a linked book,
offering to fix whichever is missing.

This lets the reader tap "Finished" on a book that was never linked and end up
where they meant to go, instead of getting an error.
]]
function Actions.requireLink(ctx, on_ready)
    if not requireLogin(ctx) then return end

    local link, foreign = ctx.store:getLink(ctx.ui.doc_settings)
    if link then return on_ready(link) end

    UIManager:show(ConfirmBox:new{
        text = foreign
            and _("This book is linked to a different NeoDB instance.\n\nFind it on the one you're signed in to?")
            or _("This book isn't linked to a NeoDB entry yet.\n\nFind it now?"),
        ok_text = _("Find book"),
        ok_callback = function()
            Match.autoMatch(ctx, function()
                local linked = ctx.store:getLink(ctx.ui.doc_settings)
                if linked then on_ready(linked) end
            end)
        end,
    })
end

-- Reading position ----------------------------------------------------------

--- Whole percent, clamped, from a 0..1 fraction.
local function wholePercent(fraction)
    return math.max(0, math.min(100, math.floor((fraction or 0) * 100 + 0.5)))
end

--- Pages in the document, however this one counts them.
local function pageCount(ui)
    return ui.doc_settings and ui.doc_settings:readSetting("doc_pages")
        or (ui.document and ui.document:getPageCount())
end

--[[--
Whether this file carries publisher page numbers.

An EPUB with a page map can report real printed page numbers, which are the one
kind of page number that means something to other people.
]]
local function hasPageLabels(ui)
    return ui.pagemap ~= nil and ui.pagemap.wantsPageLabels ~= nil
        and ui.pagemap:wantsPageLabels()
end

--[[--
An annotation's publisher page label, for a book we cannot ask.

`hasPageLabels` is the honest test, but it needs the open document's pagemap. For
a book that is merely on the card, `pageref` is all there is -- and it is
overloaded: `ReaderAnnotation:getPageRef` fills it with a page-map label when the
file has one, but with a flow-relative "[3]1" when it has hidden flows and no page
map. Posting that to NeoDB as a page number is worse than posting no position at
all, so the bracketed form is refused.
]]
local function publisherLabel(annotation)
    local label = annotation.pageref
    if type(label) ~= "string" or label == "" then return nil end
    if label:match("^%[") then return nil end
    return label
end

--[[--
Chooses the unit for a position we already hold both ways.

Shared by the reader's own position and by an annotation's, so a shared quote and
a progress update never disagree about what this book's page numbers are worth.

`is_paging` is passed in rather than read off `ctx.ui`, because an annotation from
a book that is not open has to answer the same question from what it wrote down.
]]
local function inPreferredUnit(ctx, page, percent_int, label, total, is_paging, force_unit)
    --[[--
    A publisher page label is reported without a total, deliberately.

    The only count we have is KOReader's own, which for a file with a page map is
    a different numbering from the labels themselves -- so "page xii of 400" puts
    two unrelated systems either side of the word "of". Written out rather than as
    `label and nil or total`, which in Lua evaluates to `total`.
    ]]
    local preference = force_unit or ctx.store:get("progress_unit")
    if preference == "page" then
        if label then return "page", tostring(label), nil end
        return "page", tostring(page or 1), total
    elseif preference == "percentage" then
        return "percentage", tostring(percent_int), total
    end

    if label then return "page", tostring(label), nil end
    if is_paging then
        -- Fixed-layout files (PDF, DjVu, CBZ): our page numbers are the book's.
        return "page", tostring(page or 1), total
    end
    -- Reflowable text repaginates per device, font and margin, so our page
    -- numbers would mean nothing to anyone else. Percentages travel.
    return "percentage", tostring(percent_int), total
end

--[[--
How far through the book the reader is, as a 0..1 fraction.

`percent_finished` in the sidecar is written by `onSaveSettings` and nowhere else
(`readerrolling.lua:338`, `readerpaging.lua:163`), so while a book is open it is
as old as the last autosave: fifteen minutes by default, and never refreshed at
all for a reader who has set saving to "only on close and suspend". Reporting
from it meant the hourly progress update kept deciding nothing had moved.

The footer keeps a live one, recomputed on every page and position change and by
the same arithmetic KOReader shows the reader (`pageno / pages`, flow-relative
where the file has hidden flows). It is a widget that exists whether or not it is
drawn. The sidecar is the fallback for a book that is not open, and the page
count for one that has no stored percentage yet.
]]
local function currentPercent(ui, page, total)
    local footer = ui.view and ui.view.footer
    if footer and type(footer.percent_finished) == "number" then
        return footer.percent_finished
    end

    local stored = ui.doc_settings and ui.doc_settings:readSetting("percent_finished")
    if type(stored) == "number" then return stored end

    if page and total and total > 0 then return page / total end
    return nil
end

--[[--
Works out what to report as the reader's position.

@param force_unit optional "page"/"percentage", overriding the preference
@treturn string NeoDB progress type ("page" or "percentage")
@treturn string value, as NeoDB wants it
@treturn int|nil total pages, for display only
]]
function Actions.readingPosition(ctx, force_unit)
    local ui = ctx.ui
    local page = ui.getCurrentPage and ui:getCurrentPage() or nil
    local total = pageCount(ui)

    local percent = currentPercent(ui, page, total)
    local label = hasPageLabels(ui) and ui.pagemap:getCurrentPageLabel(true) or nil

    return inPreferredUnit(ctx, page, wholePercent(percent), label, total,
        ui.paging, force_unit)
end

--[[--
Where an annotation sits, in the unit this book's progress is reported in.

The annotation's own place in the book, not the reader's: by the time a highlight
is queued they have usually read on, and a quote stamped with wherever they happen
to be now is worse than one carrying no position at all -- which is also what an
annotation we cannot place gets.

@param book optional resolved book handle (see `neodb_annotations`); passing one
            that is not the open document is what says "answer from the sidecar,
            do not ask the reader's own document"
@treturn string|nil NeoDB progress type, or nil when the position is unknown
@treturn string|nil value, as NeoDB wants it
]]
function Actions.annotationPosition(ctx, annotation, book)
    local label, total, is_paging
    if book and not book.live then
        label = publisherLabel(annotation)
        total = book.pages
        --[[--
        `pageno` is an xpointer resolved to a page number for reflowable files and
        the page itself for fixed-layout ones, so which of the two this is can be
        read straight off `page`: a number means the file paginates for itself.
        ]]
        is_paging = type(annotation.page) == "number"
    else
        local ui = ctx.ui
        -- `pageref` is this annotation's own publisher page label, filled in by
        -- KOReader when it made the annotation.
        label = hasPageLabels(ui) and annotation.pageref or nil
        total = pageCount(ui)
        is_paging = ui.paging
    end

    local page = tonumber(annotation.pageno)
    if not page and not label then return nil end

    local percent = (page and total and total > 0) and (page / total) or nil
    return inPreferredUnit(ctx, page, wholePercent(percent), label, total, is_paging)
end

function Actions.positionLabel(progress_type, value, total)
    if progress_type == "percentage" then
        return T(_("%1%"), value)
    elseif total then
        return T(_("page %1 of %2"), value, tostring(total))
    end
    return T(_("page %1"), value)
end

-- Marks: status, rating, comment ---------------------------------------------

--[[--
Builds a mark body that preserves everything the reader did not change.

NeoDB's own docs are explicit: "updating mark without `rating_grade`,
`comment_text` or `tags` field will clear them." So every write has to resend the
last known values for the fields this particular action is not about.
]]
function Actions.markBody(ctx, link, overrides)
    local cached = link.mark or {}
    local body = {
        shelf_type        = overrides.shelf_type or cached.shelf_type,
        visibility        = overrides.visibility or cached.visibility
                            or ctx.store:get("default_visibility"),
        comment_text      = overrides.comment_text or cached.comment_text or "",
        rating_grade      = overrides.rating_grade or cached.rating_grade or 0,
        post_to_fediverse = overrides.post_to_fediverse == true,
    }
    -- Omit `tags` entirely when we have none: the schema already defaults it to
    -- an empty list, and omitting sidesteps the empty-array encoding trap
    -- whatever JSON library is underneath.
    if type(cached.tags) == "table" and #cached.tags > 0 then
        body.tags = Util.jsonArray(cached.tags)
    end
    return body
end
local markBody = Actions.markBody

--[[--
Runs `on_ready(link)` with a link whose cached mark can be trusted.

Every mark write resends the fields the reader did not touch, from the cache. A
link that has never been told what NeoDB holds has nothing to resend, so it would
post an empty comment and no rating over a rating and comment made elsewhere.
That state is reachable: a link made while the mark fetch failed, or one made by
a version before any of this was cached.

Nothing is refetched once the answer is known, and knowing there is *no* mark
counts -- an unmarked book has nothing to lose and must not pay for a request on
every status tap. That is what `mark_checked` records.

@param opts.assume proceed rather than ask when the answer cannot be had, for the
                   automatic paths, which have no reader in front of them
]]
function Actions.withKnownMark(ctx, link, on_ready, opts)
    if link.mark ~= nil or link.mark_checked then return on_ready(link) end

    if Util.isOnline() then
        local done = Util.busy(_("Reading your NeoDB status for this book…"))
        local ok, mark = ctx.api:getMark(link.uuid)
        done()
        if ok then
            ctx.store:cacheMark(ctx.ui.doc_settings, mark)
            return on_ready(ctx.store:getLink(ctx.ui.doc_settings) or link)
        end
    end

    if opts and opts.assume then return on_ready(link) end

    UIManager:show(ConfirmBox:new{
        text = _("This device has not been told what NeoDB holds for this book.\n\nSaving now would replace any rating and comment you made elsewhere."),
        ok_text = _("Save anyway"),
        ok_callback = function() on_ready(link) end,
    })
end

local function submitMark(ctx, link, body, success_text, on_done)
    local status, data, code
    local finish = function()
        -- Cache optimistically: a queued mark is still what the reader intends
        -- this book's status to be, and the status display should say so.
        if status ~= "failed" then
            ctx.store:cacheMark(ctx.ui.doc_settings, body)
        end
        report(ctx, status, data, code, success_text)
        -- Pass the outcome on: a caller chaining another request behind this one
        -- needs to know whether the mark actually landed.
        if on_done then on_done(status) end
    end

    local op = {
        method = "POST", path = ctx.api:markPath(link.uuid), body = body,
        label = T(_("Mark “%1” as %2"), link.title or "?", Util.shelfLabel(body.shelf_type)),
        dedup = "mark:" .. link.uuid,
    }

    -- Offline, queue quietly rather than interrupting the reader with a Wi-Fi
    -- prompt: they asked to change a status, not to go online. All three returns,
    -- because queueing can itself fail when the queue is full, and the reason is
    -- what makes that message say so.
    if not Util.isOnline() then
        status, data, code = ctx.api:submit(op, false)
        return finish()
    end

    Util.whenOnline(function()
        local done = Util.busy(_("Sending to NeoDB…"))
        status, data, code = ctx.api:submit(op, true)
        done()
        finish()
    end)
end

--- One-tap status change, keeping any existing rating, comment and tags.
function Actions.setShelf(ctx, shelf, on_done)
    Actions.requireLink(ctx, function(link)
        Actions.withKnownMark(ctx, link, function(known)
            local body = markBody(ctx, known, {
                shelf_type = shelf,
                post_to_fediverse = ctx.store:get("post_to_fediverse"),
            })
            submitMark(ctx, known, body,
                T(_("Marked as %1 on NeoDB."), Util.shelfLabel(shelf)), on_done)
        end)
    end)
end

--- Half-star picker. Two columns keeps it thumb-sized on a small screen.
function Actions.pickRating(current, on_pick)
    local dialog
    local rows = {}

    local function button(grade)
        local label = Util.stars(grade) .. " " .. tostring(grade)
        if current == grade then label = "✓ " .. label end
        return {
            text = label,
            callback = function()
                UIManager:close(dialog)
                on_pick(grade)
            end,
        }
    end

    -- Descending, so five stars sits at the top where the thumb lands first.
    for grade = 10, 2, -2 do
        table.insert(rows, { button(grade), button(grade - 1) })
    end
    table.insert(rows, {
        {
            text = (not current or current == 0) and _("✓ No rating") or _("No rating"),
            callback = function()
                UIManager:close(dialog)
                on_pick(0)
            end,
        },
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("Your rating"),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end

--[[--
The "who can see this?" picker, over whichever vocabulary the endpoint uses.

A mark or a note is given an integer and a post one of Mastodon's strings, but the
question put to the reader is the same one, so only the list and its labels differ.
]]
local function pickVisibilityFrom(values, labeller, current, on_pick, footnote)
    local dialog
    local rows = {}
    for _idx, visibility in ipairs(values) do
        local label = labeller(visibility)
        if current == visibility then label = "✓ " .. label end
        table.insert(rows, {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                on_pick(visibility)
            end,
        }})
    end
    table.insert(rows, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})

    local title = _("Who can see this?")
    if footnote then title = title .. "\n" .. footnote end

    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end

function Actions.pickVisibility(current, on_pick)
    pickVisibilityFrom(Util.VISIBILITIES, Util.visibilityLabel, current, on_pick)
end

--- Same picker, for a post. The extra line is there because "unlisted" is not obvious.
function Actions.pickPostVisibility(current, on_pick)
    pickVisibilityFrom(Util.POST_VISIBILITIES, Util.postVisibilityLabel, current, on_pick,
        _("Unlisted posts are not shown in public timelines."))
end

--[[--
The rate-and-comment sheet itself, once there is a link and a mark to resend.

Rating, visibility and the fediverse toggle live on buttons whose labels update
in place, so the reader can see the whole state without leaving the dialog.
]]
local function rateAndCommentDialog(ctx, link, on_done)
    local cached = link.mark or {}
    local rating = cached.rating_grade or 0
    local visibility = cached.visibility or ctx.store:get("default_visibility")
    local shelf = cached.shelf_type
    local post = ctx.store:get("post_to_fediverse")

    local dialog
    dialog = InputDialog:new{
        title = T(_("Rate “%1”"), Util.ellipsize(link.title or "?", 40)),
        description = shelf
            and T(_("Status on NeoDB: %1"), Util.shelfLabel(shelf))
            or _("This book isn't on a NeoDB shelf yet; saving will mark it as Reading."),
        input = cached.comment_text or "",
        input_hint = _("Comment (optional)"),
        allow_newline = true,
        buttons = {
            {
                {
                    text = T(_("Rating: %1"), Util.ratingLabel(rating)),
                    id = "rating",
                    callback = function()
                        hideKeyboard(dialog)
                        Actions.pickRating(rating, function(grade)
                            rating = grade
                            relabel(dialog, "rating", T(_("Rating: %1"), Util.ratingLabel(grade)))
                        end)
                    end,
                },
            },
            {
                {
                    text = T(_("Visible to: %1"), Util.visibilityLabel(visibility)),
                    id = "visibility",
                    callback = function()
                        hideKeyboard(dialog)
                        Actions.pickVisibility(visibility, function(value)
                            visibility = value
                            relabel(dialog, "visibility",
                                T(_("Visible to: %1"), Util.visibilityLabel(value)))
                        end)
                    end,
                },
                {
                    text = post and _("Crosspost: on") or _("Crosspost: off"),
                    id = "fediverse",
                    callback = function()
                        post = not post
                        relabel(dialog, "fediverse",
                            post and _("Crosspost: on") or _("Crosspost: off"))
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local comment = Util.trim(dialog:getInputText())
                        UIManager:close(dialog)
                        local body = markBody(ctx, link, {
                            -- Rating something you never shelved implies you
                            -- are at least reading it.
                            shelf_type        = shelf or "progress",
                            visibility        = visibility,
                            comment_text      = comment,
                            rating_grade      = rating,
                            post_to_fediverse = post,
                        })
                        submitMark(ctx, link, body, _("Saved to NeoDB."), on_done)
                    end,
                },
            },
        },
    }
    -- No keyboard up front: the reader came here to tap a rating, and the
    -- comment is optional. Tapping the text box brings it up.
    UIManager:show(dialog)
end

--[[--
Rate and comment on the open book.

The mark is read before the dialog opens, so the comment box is prefilled with
what is actually on NeoDB. An empty box that then replaces a comment written
elsewhere is the one mistake this dialog can make and not take back.
]]
function Actions.rateAndComment(ctx, on_done)
    Actions.requireLink(ctx, function(link)
        Actions.withKnownMark(ctx, link, function(known)
            rateAndCommentDialog(ctx, known, on_done)
        end)
    end)
end

function Actions.removeMark(ctx, on_done)
    Actions.requireLink(ctx, function(link)
        UIManager:show(ConfirmBox:new{
            text = T(_("Remove your NeoDB mark for “%1”?\n\nThe rating, comment and status will be deleted."),
                link.title or "?"),
            ok_text = _("Remove"),
            ok_callback = function()
                Util.whenOnline(function()
                    local done = Util.busy(_("Removing…"))
                    local ok, data, code = ctx.api:deleteMark(link.uuid)
                    done()
                    if ok then
                        ctx.store:cacheMark(ctx.ui.doc_settings, nil)
                        Util.notify(_("Mark removed from NeoDB."))
                        if on_done then on_done() end
                    else
                        Util.alert(ctx.api:errorMessage(data, code))
                    end
                end)
            end,
        })
    end)
end

-- Progress ------------------------------------------------------------------

--[[--
Sends a progress update.

@param opts.quiet   suppress the success notification (automatic syncs)
@param opts.on_done called with (status, data, code)
]]
function Actions.sendProgress(ctx, link, progress_type, value, opts)
    opts = opts or {}
    local op = {
        method = "POST",
        path   = ctx.api:progressPath(link.uuid),
        body   = { type = progress_type, value = tostring(value) },
        label  = T(_("Progress for “%1”"), link.title or "?"),
        -- Only the newest position matters, so a queued update supersedes.
        dedup  = "progress:" .. link.uuid,
    }

    local function finish(status, data, code)
        if status ~= "failed" then
            ctx.store:cacheProgress(ctx.ui.doc_settings, progress_type, tostring(value))
        end
        if opts.quiet then
            if status == "failed" then
                logger.warn("NeoDB: progress sync failed:", tostring(data))
            end
        else
            report(ctx, status, data, code,
                T(_("Progress sent: %1"), Actions.positionLabel(progress_type, tostring(value))))
        end
        if opts.on_done then opts.on_done(status, data, code) end
    end

    if not Util.isOnline() then
        return finish(ctx.api:submit(op, false))
    end
    Util.whenOnline(function()
        local done = opts.quiet and function() end or Util.busy(_("Sending progress…"))
        local status, data, code = ctx.api:submit(op, true)
        done()
        finish(status, data, code)
    end)
end

--[[--
Makes sure the book is on a shelf, then sends the progress.

Progress hangs off the mark, so a book on no shelf at all has nothing to attach
it to. *Which* shelf is irrelevant — only that one exists — so an already-marked
book is left exactly where the reader put it, Finished and Dropped included. An
unmarked one goes on Reading, which is what sending progress implies anyway.
]]
function Actions.sendProgressForBook(ctx, link, progress_type, value, quiet, on_done)
    local opts = { quiet = quiet, on_done = on_done }

    local current = ctx.store:getLink(ctx.ui.doc_settings)
    if current and current.mark and current.mark.shelf_type then
        return Actions.sendProgress(ctx, link, progress_type, value, opts)
    end

    Actions.setShelf(ctx, "progress", function(status)
        if status == "failed" then
            if on_done then on_done("failed") end
            return
        end
        Actions.sendProgress(ctx, link, progress_type, value, opts)
    end)
end

--[[--
Progress dialog, pre-filled with where the reader actually is.

The unit button lets them switch between a page number and a percentage; which
one starts selected depends on whether page numbers mean anything for this file
(see `readingPosition`).
]]
function Actions.updateProgress(ctx, on_done)
    Actions.requireLink(ctx, function(link)
        local dialog

        --[[--
        Rebuilt rather than relabelled when the unit changes.

        Three things depend on the unit -- the description, the value in the box
        and whether the keyboard should be the numeric one -- and only a button
        label can be changed in place. Relabelling left the other two saying the
        wrong thing: "You're at 25%" over a box holding a page number, and a
        number pad for a publisher page label like "xii". Nothing is lost by
        rebuilding, since switching unit recomputes the value from the book
        anyway rather than converting what was typed.
        ]]
        local function show(force_unit)
            local progress_type, value, total = Actions.readingPosition(ctx, force_unit)
            if dialog then UIManager:close(dialog) end

            dialog = InputDialog:new{
                title = _("Update reading progress"),
                description = T(_("You're at %1."),
                    Actions.positionLabel(progress_type, value, total)),
                input = value,
                input_type = tonumber(value) and "number" or nil,
                buttons = {
                    {
                        {
                            text = progress_type == "page"
                                and _("Unit: page") or _("Unit: percent"),
                            id = "unit",
                            callback = function()
                                show(progress_type == "page" and "percentage" or "page")
                            end,
                        },
                    },
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("Send"),
                            is_enter_default = true,
                            callback = function()
                                local entered = Util.trim(dialog:getInputText())
                                if entered == "" then return end
                                --[[--
                                Checked here rather than left to the server: a bad
                                value typed offline would meet its refusal days
                                later, in the background, and be given up on. Books
                                whose pages are named rather than numbered ("xii")
                                take whatever is typed -- there is nothing to check
                                a label against.
                                ]]
                                if progress_type == "percentage" then
                                    local number = tonumber(entered)
                                    if not number or number < 0 or number > 100 then
                                        Util.alert(_("Enter a percentage between 0 and 100."))
                                        return
                                    end
                                    entered = tostring(math.floor(number + 0.5))
                                elseif total then
                                    -- This book's pages are numbers -- a label
                                    -- book reports no total (`inPreferredUnit`),
                                    -- and gets no check even when the reader
                                    -- happens to sit on a numeric label.
                                    local number = tonumber(entered)
                                    if not number or number < 1 or number % 1 ~= 0 then
                                        Util.alert(_("Enter a page number."))
                                        return
                                    end
                                    if total and number > total then
                                        Util.alert(T(_("This book has %1 pages."),
                                            tostring(total)))
                                        return
                                    end
                                    entered = tostring(number)
                                end
                                UIManager:close(dialog)
                                Actions.sendProgressForBook(
                                    ctx, link, progress_type, entered, false, on_done)
                            end,
                        },
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        show()
    end)
end

-- Notes and quotes ----------------------------------------------------------

-- Generate a fresh, editable title at the reading position where the composer
-- opens. Missing chapter/progress metadata should not leave empty separators.
local function defaultNoteTitle(ctx, link)
    local style = ctx.store:get("note_title_style")
    if style == "none" then return "" end
    local ui = ctx.ui
    local function singleLine(text)
        return Util.trim((text or ""):gsub("%s+", " "))
    end
    local book_title = singleLine(ui.doc_props and ui.doc_props.title)
    if book_title == "" then book_title = singleLine(link.title) end
    if book_title == "" then book_title = _("Untitled book") end
    book_title = book_title:match("^《(.*)》$") or book_title
    local page = ui.getCurrentPage and ui:getCurrentPage()
    local chapter = page and ui.toc and ui.toc:getTocTitleByPage(page)
    chapter = singleLine(chapter)
    local percent = currentPercent(ui, page, pageCount(ui))
    local progress = percent and tostring(wholePercent(percent)) .. "%" or ""
    if style == "custom" then
        local values = { book = book_title, chapter = chapter, progress = progress }
        return singleLine((ctx.store:get("note_title_template") or ""):gsub("{(%w+)}", function(key)
            return values[key] or "{" .. key .. "}"
        end))
    end
    local title
    if style == "plain" or style == "decorated" then
        title = T(style == "decorated" and _("📖 Reading notes | %1") or _("Reading notes | %1"), book_title)
    elseif style == "book" or style == "book_chapter" or style == "book_progress" then
        title = T(_("Book: %1"), book_title)
    else
        return ""
    end
    if style ~= "book" and style ~= "book_progress" and chapter ~= "" then
        title = T(_("%1 · %2"), title, chapter)
    end
    if style ~= "book" and style ~= "book_chapter" and progress ~= "" then
        title = title .. " · " .. progress
    end
    return title
end

local function quoteWithIntroduction(ctx, quote)
    local style = ctx.store:get("quote_intro_style")
    if style == "plain" then return _("Quoted passage:") .. "\n\n" .. quote end
    if style == "decorated" then return _("Quoted passage: 👇") .. "\n\n" .. quote end
    if style == "excerpt" then return _("Excerpt:") .. "\n\n" .. quote end
    if style == "original" then return _("Original text:") .. "\n\n" .. quote end
    if style == "from_book" then return _("From the book:") .. "\n\n" .. quote end
    if style == "custom" then
        local intro = Util.trim(ctx.store:get("quote_intro_text") or "")
        if intro ~= "" then return intro .. "\n\n" .. quote end
    end
    return quote
end

-- One tap, no composer, color picker or network prompt. Save locally first,
-- durably enqueue the post, then use the existing silent upload/retry path.
function Actions.highlightAndShare(ctx, highlight, index)
    local selection = highlight.selected_text
    if not selection or not selection.pos0 or not selection.pos1 then return end
    local quote = Util.trim(util.cleanupSelectedText(selection.text or ""))
    if quote == "" then return end
    local saved = index and ctx.ui.annotation.annotations[index] or nil
    if not saved and not index then
        local new_index = highlight:saveHighlight()
        saved = new_index and ctx.ui.annotation.annotations[new_index]
    end
    highlight:onClose()
    if not saved then
        Util.notify(index and _("The original highlight is no longer available. Please select the text again.")
            or _("Could not save the highlight. Please select the text again."))
        return
    end
    ctx.ui.annotation:onSaveSettings()

    -- These prerequisites cannot be fixed without opening an interactive flow.
    -- Keep the highlight and report the missing setup without launching one.
    if not ctx.store:isLoggedIn() then
        Util.notify(_("Highlight saved. Sign in from the NeoDB menu before sharing."))
        return
    end
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then
        Util.notify(_("Highlight saved. Link this book from the NeoDB menu before sharing."))
        return
    end
    if ctx.store:get("quote_as_blockquote") then
        quote = "> " .. quote:gsub("\n", "\n> ")
    end
    local progress_type, value = Actions.readingPosition(ctx)
    local op = {
        method = "POST",
        path = ctx.api:notePath(link.uuid),
        label = T(_("Note on “%1”"), link.title or "?"),
        body = {
            title = defaultNoteTitle(ctx, link),
            content = quoteWithIntroduction(ctx, quote),
            visibility = ctx.store:get("default_visibility"),
            post_to_fediverse = ctx.store:get("selection_crosspost"),
            sensitive = false,
        },
        annotation = {
            item = link.uuid,
            key = saved.datetime,
            file = ctx.ui.document.file,
        },
    }
    if ctx.store:get("note_attach_progress") then
        op.body.progress_type = progress_type
        op.body.progress_value = tostring(value)
    end
    local marked = annotations().markQueued(ctx, saved.datetime)
    op.annotation.release_on_failure = marked
    op.notify_result = true
    local status, data, code = ctx.api:submit(op, false)
    if status == "failed" then
        if marked then annotations().unmarkQueued(ctx, saved.datetime) end
        Util.notify(T(_("Highlight saved, but sharing could not be queued: %1"), ctx.api:errorMessage(data, code)))
        return
    end
    Util.notify(_("Highlight saved; sharing queued."))
    UIManager:nextTick(function() Actions.flushSoon(ctx) end)
end

-- Keep the selection separately: closing its menu clears it, and cancelling the
-- composer must not create a highlight or alter an existing note.
function Actions.addNoteAndShare(ctx, highlight, index)
    local selection = util.tableDeepCopy(highlight.selected_text)
    local saved = index and ctx.ui.annotation.annotations[index] or nil
    if not selection or not selection.pos0 or not selection.pos1 then return end
    local document = ctx.ui.document
    highlight:onClose()

    Actions.addNote(ctx, {
        quote = util.cleanupSelectedText(selection.text),
        note = saved and saved.note or "",
        annotation_key = saved and saved.datetime or nil,
        existing_annotation = saved ~= nil,
        custom_note = saved and saved.neodb_custom_note,
        save_note = function(note, mode)
            if ctx.ui.document ~= document then
                Util.alert(_("The book was closed. The note could not be saved."))
                return
            end
            if saved then
                local present = false
                for _, item in ipairs(ctx.ui.annotation.annotations) do
                    if item == saved then present = true; break end
                end
                if not present then
                    Util.alert(_("The original highlight was deleted. The note could not be saved."))
                    return
                end
            else
                -- Use KOReader's normal save path for both EPUB and PDF. Do not
                -- extend to a sentence: share exactly the passage selected.
                local previous_selection = highlight.selected_text
                highlight.selected_text = selection
                local new_index = highlight:saveHighlight()
                highlight.selected_text = previous_selection
                saved = new_index and ctx.ui.annotation.annotations[new_index]
                if not saved then
                    Util.alert(_("Could not save the note. Please select the text again."))
                    return
                end
            end

            local had_note = saved.note ~= nil and saved.note ~= ""
            local has_note = note ~= ""
            highlight:writePdfAnnotation("content", saved, note)
            saved.note = has_note and note or nil
            saved.neodb_custom_note = has_note and mode == "custom" or nil
            local note_delta = (has_note and 1 or 0) - (had_note and 1 or 0)
            ctx.ui:handleEvent(Event:new("AnnotationsModified", {
                saved,
                nb_highlights_added = note_delta ~= 0 and -note_delta or nil,
                nb_notes_added = note_delta ~= 0 and note_delta or nil,
            }))
            UIManager:setDirty(highlight.dialog, "ui")
            -- Use the reader's annotation save lifecycle; do not force a full
            -- document settings flush for every selection.
            ctx.ui.annotation:onSaveSettings()
            return saved.datetime
        end,
    })
end

--[[--
Note composer, also used for sharing a highlighted quote.

@param opts.quote          highlighted text to quote
@param opts.note           initial note text, without the quote
@param opts.save_note      optional callback saving the local note and returning
                           its annotation key; nil means saving failed
@param opts.title          suggested note title
@param opts.annotation_key creation time of the annotation being shared, when the
                           quote came from one the book already holds. It is what
                           the highlight mirror keys its ledger on, so passing it
                           is what stops the mirror posting the same highlight
                           again ten seconds later.
]]
function Actions.addNote(ctx, opts)
    opts = opts or {}
    Actions.requireLink(ctx, function(link)
        local progress_type, value, total = Actions.readingPosition(ctx)
        local attach_progress = ctx.store:get("note_attach_progress")
        local visibility = ctx.store:get("default_visibility")
        local post = ctx.store:get(opts.quote and "selection_crosspost" or "post_to_fediverse")
        local save_local = opts.save_note ~= nil and not opts.existing_annotation
            and ctx.store:get("note_save_local")

        local quote = Util.trim(opts.quote or "")
        local quote_modes = { after = "before", before = "none", none = "custom", custom = "after" }
        local quote_position = ctx.store:get("quote_position")
        if not quote_modes[quote_position] then quote_position = "after" end
        if quote == "" then quote_position = "none" end
        local plain_draft = opts.note or ""
        local custom_draft
        local function customDraft()
            if custom_draft == nil then
                local editable_quote = quote
                if ctx.store:get("quote_as_blockquote") then
                    editable_quote = "> " .. quote:gsub("\n", "\n> ")
                end
                -- Old versions saved the whole custom body without metadata.
                -- Recognize an existing prefill too, so reopening is idempotent.
                local initial = Util.trim(plain_draft)
                if opts.custom_note or initial == editable_quote
                        or initial:sub(1, #editable_quote + 2) == editable_quote .. "\n\n" then
                    custom_draft = plain_draft
                else
                    custom_draft = editable_quote .. "\n\n" .. plain_draft
                end
            end
            return custom_draft
        end

        local dialog
        local function progressLabel()
            return attach_progress
                and T(_("At: %1"), Actions.positionLabel(progress_type, value, total))
                or _("At: not attached")
        end
        local function quoteLabel()
            local labels = {
                after = _("Quote: below note"),
                before = _("Quote: above note"),
                none = _("Quote: none"),
                custom = _("Quote: custom"),
            }
            return labels[quote_position]
        end
        local function saveLocalLabel()
            return save_local and _("Save locally: on") or _("Save locally: off")
        end
        local function postLabel()
            if not opts.save_note then return _("Post") end
            return save_local and _("Save & share") or _("Share only")
        end

        local dialog_config = {
            title = opts.save_note and _("Add note & share")
                or (opts.quote and _("Share a quote") or _("Add a note")),
            description = T(_("On “%1”"), Util.ellipsize(link.title or "?", 40)),
            note_title = opts.title or defaultNoteTitle(ctx, link),
            note_text = quote_position == "custom" and customDraft() or plain_draft,
            note_hint = opts.quote
                and _("Note text (optional)") or _("Note text"),
            -- No scroll buttons: they would be injected into our first button
            -- row. Swipe north/south scrolls the text box anyway.
            buttons = {
                {
                    {
                        text = progressLabel(),
                        id = "progress",
                        callback = function()
                            attach_progress = not attach_progress
                            relabel(dialog, "progress", progressLabel())
                        end,
                    },
                },
                {
                    {
                        text = T(_("Visible to: %1"), Util.visibilityLabel(visibility)),
                        id = "visibility",
                        callback = function()
                            hideKeyboard(dialog)
                            Actions.pickVisibility(visibility, function(chosen)
                                visibility = chosen
                                relabel(dialog, "visibility",
                                    T(_("Visible to: %1"), Util.visibilityLabel(chosen)))
                            end)
                        end,
                    },
                    {
                        text = post and _("Crosspost: on") or _("Crosspost: off"),
                        id = "fediverse",
                        callback = function()
                            post = not post
                            relabel(dialog, "fediverse",
                                post and _("Crosspost: on") or _("Crosspost: off"))
                        end,
                    },
                },
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = postLabel(),
                        id = "post",
                        callback = function()
                            local note_title = Util.trim(dialog:getNoteTitle())
                            local note = Util.trim(dialog:getNoteText())
                            local automatic_quote = quote ~= ""
                                and (quote_position == "before" or quote_position == "after")
                            if note == "" and not automatic_quote then
                                Util.alert(_("The note is empty."))
                                return
                            end
                            local key = opts.annotation_key
                            if save_local then
                                key = opts.save_note(note, quote_position)
                                if not key then return end
                            end
                            -- Automatic modes append a separate quote. Custom
                            -- mode posts the edited content as-is; local saving,
                            -- if enabled, also saves exactly this editor text.
                            local content = note
                            if automatic_quote then
                                local formatted_quote = quote
                                if ctx.store:get("quote_as_blockquote") then
                                    formatted_quote = "> " .. quote:gsub("\n", "\n> ")
                                end
                                formatted_quote = quoteWithIntroduction(ctx, formatted_quote)
                                if note == "" then
                                    content = formatted_quote
                                elseif quote_position == "after" then
                                    content = note .. "\n\n" .. formatted_quote
                                else
                                    content = formatted_quote .. "\n\n" .. note
                                end
                            end
                            UIManager:close(dialog)

                            local body = {
                                title             = note_title,
                                content           = content,
                                visibility        = visibility,
                                post_to_fediverse = post,
                                sensitive         = false,
                            }
                            if attach_progress then
                                body.progress_type  = progress_type
                                body.progress_value = tostring(value)
                            end

                            local op = {
                                method = "POST",
                                path   = ctx.api:notePath(link.uuid),
                                body   = body,
                                label  = T(_("Note on “%1”"), link.title or "?"),
                                -- No dedup: each note is its own post.
                            }

                            --[[--
                            Sharing a highlight the book already holds: tag the op
                            so its uuid is filed like any other, and record it as
                            handed over *before* the write, since the mirror's
                            timer comes round long before a queued post does.
                            ]]
                            local marked = false
                            if type(key) == "string" then
                                op.annotation = {
                                    item = link.uuid,
                                    key  = key,
                                    file = ctx.ui.document and ctx.ui.document.file,
                                }
                                marked = annotations().markQueued(ctx, key)
                                op.annotation.release_on_failure = marked
                            end

                            local function finish(status, data, code)
                                -- Refused for good: give the highlight back to the
                                -- mirror rather than leaving it recorded as posted.
                                if status == "failed" and marked then
                                    annotations().unmarkQueued(ctx, key)
                                end
                                report(ctx, status, data, code, _("Note posted to NeoDB."))
                            end
                            if not Util.isOnline() then
                                return finish(ctx.api:submit(op, false))
                            end
                            Util.whenOnline(function()
                                local done = Util.busy(_("Posting note…"))
                                local status, data, code = ctx.api:submit(op, true)
                                done()
                                finish(status, data, code)
                            end)
                        end,
                    },
                },
            },
        }
        if quote ~= "" then
            table.insert(dialog_config.buttons[1], {
                text = quoteLabel(),
                id = "quote_position",
                callback = function()
                    if quote_position == "custom" then
                        custom_draft = dialog:getNoteText()
                    else
                        plain_draft = dialog:getNoteText()
                    end
                    local previous = quote_position
                    quote_position = quote_modes[quote_position]
                    if quote_position == "custom" then
                        dialog:setNoteText(customDraft())
                    elseif previous == "custom" then
                        dialog:setNoteText(plain_draft)
                    end
                    relabel(dialog, "quote_position", quoteLabel())
                end,
            })
        end
        if opts.save_note then
            table.insert(dialog_config.buttons, #dialog_config.buttons, {{
                text = saveLocalLabel(),
                id = "save_local",
                callback = function()
                    save_local = not save_local
                    relabel(dialog, "save_local", saveLocalLabel())
                    relabel(dialog, "post", postLabel())
                end,
            }})
        end
        dialog = NoteDialog:new(dialog_config)
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end)
end

-- Standalone posts ----------------------------------------------------------

--[[--
The post composer: a fediverse status with no book behind it.

The only thing in this module that needs neither a link nor an open document, so
it asks for nothing but a sign-in and is offered in the file browser as well. It
goes out through the upload queue like every other write, so a thought typed with
Wi-Fi off waits rather than being lost.

Visibility starts from the reader's stored default, mapped into the vocabulary
this endpoint uses (see `Util.postVisibilityFor`), and can be changed per post.
]]
function Actions.postStatus(ctx)
    if not requireLogin(ctx) then return end

    local visibility = Util.postVisibilityFor(ctx.store:get("default_visibility"))

    local dialog
    local function visibilityLabel()
        return T(_("Visible to: %1"), Util.postVisibilityLabel(visibility))
    end

    --- Queues or sends what has been typed, once its length has been settled.
    local function send(content)
        UIManager:close(dialog)

        local op = {
            method = "POST",
            path   = ctx.api:statusPath(),
            --[[--
            Only the two fields the reader actually decided. The rest of that
            schema defaults sensibly, and sending an empty `media_ids` would walk
            into the same empty-array encoding trap `markBody` avoids for `tags`.
            ]]
            body   = { status = content, visibility = visibility },
            -- Newlines collapsed: this label is one line in a menu.
            label  = T(_("Post: %1"), Util.ellipsize((content:gsub("%s+", " ")), 30)),
            -- No dedup: each post is its own.
        }
        local function finish(status, data, code)
            report(ctx, status, data, code, _("Posted to NeoDB."))
        end
        if not Util.isOnline() then
            return finish(ctx.api:submit(op, false))
        end
        Util.whenOnline(function()
            local done = Util.busy(_("Posting…"))
            local status, data, code = ctx.api:submit(op, true)
            done()
            finish(status, data, code)
        end)
    end

    dialog = InputDialog:new{
        title = _("Post to NeoDB"),
        description = T(_("As %1"), ctx.store:getAccountLabel() or "?"),
        input_hint = _("What do you want to say?"),
        allow_newline = true,
        use_available_height = true,
        -- No scroll buttons: they would be injected into our first button row,
        -- and swiping north/south scrolls the text box anyway.
        buttons = {
            {
                {
                    text = visibilityLabel(),
                    id = "visibility",
                    callback = function()
                        -- Two keyboards at once is a state KOReader does not track,
                        -- so this one goes before the picker opens.
                        hideKeyboard(dialog)
                        Actions.pickPostVisibility(visibility, function(chosen)
                            visibility = chosen
                            relabel(dialog, "visibility", visibilityLabel())
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Post"),
                    callback = function()
                        local content = Util.trim(dialog:getInputText())
                        if content == "" then
                            Util.alert(_("The post is empty."))
                            return
                        end

                        --[[--
                        Over the server's limit this comes back as a refusal -- and
                        a post written offline would collect that refusal days
                        later, out of sight, and be given up on. So the length is
                        checked here, but only warned about: the limit belongs to
                        the server, and a self-hosted one may well allow more.
                        ]]
                        local length = Util.charCount(content)
                        if length > POST_LENGTH_LIMIT then
                            hideKeyboard(dialog)
                            UIManager:show(ConfirmBox:new{
                                text = T(_("This post is %1 characters long. Most NeoDB servers accept %2.\n\nPost it anyway?"),
                                    tostring(length), tostring(POST_LENGTH_LIMIT)),
                                ok_text = _("Post anyway"),
                                ok_callback = function() send(content) end,
                            })
                            return
                        end
                        send(content)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Upload queue --------------------------------------------------------------

--[[--
How long to wait before each further attempt at a queue that would not go.

Three of them, so a flush that fails gives up rather than settling into a poll:
nothing here is urgent enough to be worth a radio that never gets to sleep. They
climb steeply because each attempt against a server that has stopped answering
costs one timeout on the UI thread -- one, not one per op, since `flushQueue`
stops at the first failure of that kind and keeps the rest in order.

The reason a short first wait is affordable at all is that this is the *recovery*
path, not the discovery one. Coming online is announced rather than polled for
(`onNetworkConnected` in `main.lua`), and these cover the seconds after that
announcement, during which the link is up but DNS is not yet answering.
]]
local RETRY_DELAYS = { 8, 24, 72 }

--[[--
The retry budget for one episode, kept on the context.

In memory on purpose. A queue that could not be sent an hour ago deserves a fresh
set of attempts now, not the exhausted remains of the last try, and "fresh" is
exactly what a restart, a book being opened or the network coming back all mean.
The task closure is built once and reused, because `UIManager` matches scheduled
tasks by identity and a new closure each time would leave the old ones to fire.
]]
local function retryState(ctx)
    ctx.flush_retry = ctx.flush_retry or { attempt = 0 }
    return ctx.flush_retry
end

--- Forward declaration: the retry task calls back into the flush below.
local backgroundFlush

--[[--
Gives up on the current episode and forgets that it happened.

Called when the queue is empty, when it emptied, and from `main.lua` when the
plugin is torn down or the network goes away -- retrying with no link is a
guaranteed timeout, paid for on the UI thread.
]]
function Actions.cancelRetry(ctx)
    local state = retryState(ctx)
    if state.task then UIManager:unschedule(state.task) end
    state.attempt = 0
end

--- Books the next attempt, if this episode has one left.
local function armRetry(ctx)
    local state = retryState(ctx)
    local delay = RETRY_DELAYS[state.attempt + 1]
    -- Budget spent. Deliberately left spent: only a fresh occasion re-arms this,
    -- and `flushSoon` is what decides something counts as one.
    if not delay then
        logger.dbg("NeoDB: giving up on the queue for now")
        return
    end

    state.attempt = state.attempt + 1
    state.task = state.task or function() backgroundFlush(ctx) end
    UIManager:unschedule(state.task)
    UIManager:scheduleIn(delay, state.task)
    logger.dbg("NeoDB: retrying the queue in", delay, "s (attempt", state.attempt, ")")
end

--[[--
Uploads the queue after the current screen has been drawn, if we can.

Deliberately silent and deliberately not `whenOnline`: this is the background
path, and a sync nobody asked for must never turn a radio on or raise a dialog.
Next tick rather than now so whatever prompted it gets painted first -- a request
blocks the UI thread for as long as its timeout.

The two ways of being offline are not the same thing here, which is why `Util`
separates them. A radio that is off will not come on by itself, so a timer
against it is battery spent on a foregone conclusion; `onNetworkConnected` is
what covers that case, for free. A radio that is on but cannot yet resolve a name
is the ordinary state for the first seconds after that very event, and is worth
coming back to.
]]
backgroundFlush = function(ctx)
    -- Cheap guards first. Both of these run on a path that fires whenever the
    -- device connects, and `isOnline` below is a real DNS round trip, so a reader
    -- who is signed out or has nothing waiting must not pay for one.
    if ctx.store:queueCount() == 0 then return Actions.cancelRetry(ctx) end
    if not ctx.store:isLoggedIn() then return Actions.cancelRetry(ctx) end

    if not Util.isWifiOn() then return Actions.cancelRetry(ctx) end
    if not Util.isOnline() then return armRetry(ctx) end

    UIManager:nextTick(function()
        -- Read before the flush overwrites it: what we have already said about.
        local previous = ctx.store:getLastFlush()
        local sent, remaining, dropped, stopped = ctx.api:flushQueue()
        logger.dbg("NeoDB: flushed queue,", sent, "sent,", remaining, "left,",
            dropped, "dropped")

        --[[--
        Silent by design, with one exception: uploads that have stopped because of
        the account are not going to start again by themselves, and this path runs
        every time a book is opened. Said once per change of circumstance, so it is
        a notice rather than a nag; the Uploads row carries it from then on.
        ]]
        if stopped == "unauthorized" or stopped == "forbidden" then
            if stopped ~= (type(previous) == "table" and previous.stopped or nil) then
                Util.notify(_("NeoDB uploads are paused: sign in again to send them."))
            end
            -- No amount of waiting fixes a sign-in, so this episode ends here
            -- rather than spending its attempts finding that out twice more.
            return Actions.cancelRetry(ctx)
        end

        if remaining > 0 then return armRetry(ctx) end
        Actions.cancelRetry(ctx)
    end)
end

--[[--
Sends the queue because something just happened that makes it worth a try.

Every caller is a fresh occasion -- a book opened, highlights settled, progress
moved, the end of a book, an export, the device coming online -- so each one is
owed a full set of attempts, whatever an earlier episode came to.
]]
function Actions.flushSoon(ctx)
    -- Cancelled rather than merely reset: an attempt still on the clock from the
    -- last episode would otherwise fire alongside this one and flush twice.
    Actions.cancelRetry(ctx)
    return backgroundFlush(ctx)
end

function Actions.flushQueue(ctx, quiet, on_done)
    local pending = ctx.store:queueCount()
    if pending == 0 then
        if not quiet then Util.notify(_("Nothing waiting to upload.")) end
        if on_done then on_done() end
        return
    end

    Util.whenOnline(function()
        local done = quiet and function() end
            or Util.busy(T(_("Uploading %1 pending change(s)…"), pending))
        local sent, remaining, dropped = ctx.api:flushQueue()
        done()

        if not quiet or dropped > 0 then
            local parts = {}
            if sent > 0 then table.insert(parts, T(_("%1 uploaded"), sent)) end
            if remaining > 0 then table.insert(parts, T(_("%1 still waiting"), remaining)) end
            if dropped > 0 then table.insert(parts, T(_("%1 failed and discarded"), dropped)) end
            if #parts > 0 then Util.notify(table.concat(parts, ", ") .. ".") end
        end
        if on_done then on_done() end
    end)
end

-- What a new link is asked about --------------------------------------------

--[[--
The one question a freshly linked book is worth interrupting for.

Three answers are settled here, and they are settled together on purpose. A
status is what NeoDB hangs everything else off -- progress cannot be reported for
a book on no shelf at all -- so asking for it separately, later, is how the two
switches below it end up on and doing nothing.

Which is why there is no way out but `Save`: the dialog opens on whatever NeoDB
already holds, or on "Reading" when it holds nothing, and closing it always
leaves the book somewhere. A reader who wanted none of it has "Remove mark from
NeoDB…" under "Settings for this book"; that is a rarer thing to want than a
book being shelved when they linked it.

Both switches open on the global defaults and are written onto this book, so a
later change to those defaults leaves books already linked alone.

@param on_close called once the dialog is gone, for whoever wants the screen back
]]
function Actions.showLinkOptions(ctx, on_close)
    local link = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then
        if on_close then on_close() end
        return
    end

    --[[--
    What the server said, as against what the dialog will do about it. A mark we
    could not read is not the same as one that is not there: both preselect
    "Reading", but only the second means the shelf is already right.
    ]]
    local known = link.mark_checked ~= nil
    local server_shelf = link.mark and link.mark.shelf_type or nil
    local chosen = server_shelf or "progress"
    local auto_progress = ctx.store:autoProgress(link)
    local upload = annotations().isEnabled(ctx)

    local title_lines = { T(_("Linked to “%1”"), link.title or "?") }
    if server_shelf then
        local state = Util.shelfLabel(server_shelf)
        local stars = Util.stars(link.mark.rating_grade)
        if stars then state = state .. "  " .. stars end
        table.insert(title_lines, T(_("On NeoDB: %1"), state))
    elseif known then
        table.insert(title_lines, _("Not on any NeoDB shelf yet"))
    else
        table.insert(title_lines, _("Could not read your NeoDB status"))
    end

    local dialog

    --[[--
    A switch reads as its own state rather than as a box to tick.

    KOReader's bundled fonts do not reliably carry the ballot-box characters, and
    a bare tick cannot say "off" -- so these follow the same "label: value" shape
    the visibility button already uses, and are relabelled in place on tap.
    ]]
    local function switch(id, label, get, set)
        return {
            id = id,
            text = T(_("%1: %2"), label, get() and _("on") or _("off")),
            callback = function()
                set(not get())
                relabel(dialog, id, T(_("%1: %2"), label, get() and _("on") or _("off")))
            end,
        }
    end

    local function shelfButton(shelf)
        local label = Util.shelfLabel(shelf)
        if chosen == shelf then label = "✓ " .. label end
        return {
            id = "shelf_" .. shelf,
            text = label,
            callback = function()
                if chosen == shelf then return end
                relabel(dialog, "shelf_" .. chosen, Util.shelfLabel(chosen))
                chosen = shelf
                relabel(dialog, "shelf_" .. shelf, "✓ " .. Util.shelfLabel(shelf))
            end,
        }
    end

    --[[--
    Nothing is written until Save, so a reader who changes their mind twice costs
    one sidecar write rather than four. `nil ~= false` is what pins a default the
    reader left alone: a fresh link carries no answer, so the first Save records
    one either way.
    ]]
    local function save()
        UIManager:close(dialog)

        if link.auto_progress ~= auto_progress then
            ctx.store:setAutoProgress(ctx.ui.doc_settings, auto_progress)
        end
        if annotations().isEnabled(ctx) ~= upload then
            annotations().setEnabled(ctx, upload)
        end

        -- Only when it would actually change something: re-posting the shelf the
        -- server already has is a request, and a notification, for nothing.
        if chosen ~= server_shelf then
            Actions.setShelf(ctx, chosen, function()
                if on_close then on_close() end
            end)
            return
        end
        if on_close then on_close() end
    end

    dialog = ButtonDialog:new{
        title = table.concat(title_lines, "\n"),
        title_align = "center",
        -- Save is the only way out: see above.
        dismissable = false,
        buttons = {
            { shelfButton("wishlist"), shelfButton("progress") },
            { shelfButton("complete"), shelfButton("dropped") },
            {
                switch("auto_progress", _("Update progress"),
                    function() return auto_progress end,
                    function(on) auto_progress = on end),
            },
            {
                switch("upload", _("Upload highlights"),
                    function() return upload end,
                    function(on) upload = on end),
            },
            {
                {
                    id = "save",
                    text = _("Save"),
                    callback = save,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- The quick-action sheet ----------------------------------------------------

--[[--
The single screen most interactions go through, reachable from a gesture.

It opens instantly from the cached status: asking NeoDB first would mean a
network round trip (and possibly a Wi-Fi prompt) before the reader can even see
their options. "Refresh" is there when they want the authoritative answer.
]]
function Actions.showSheet(ctx)
    if not requireLogin(ctx) then return end

    local link, foreign = ctx.store:getLink(ctx.ui.doc_settings)
    if not link then
        UIManager:show(ConfirmBox:new{
            text = foreign
                and _("This book is linked to a different NeoDB instance.\n\nFind it on the one you're signed in to?")
                or _("This book isn't linked to a NeoDB entry yet.\n\nFind it now?"),
            ok_text = _("Find book"),
            ok_callback = function()
                Match.autoMatch(ctx, function() Actions.showSheet(ctx) end)
            end,
        })
        return
    end

    local cached = link.mark
    local progress_type, value, total = Actions.readingPosition(ctx)

    local title_lines = { link.title or _("Untitled") }
    if cached then
        local state = Util.shelfLabel(cached.shelf_type)
        local stars = Util.stars(cached.rating_grade)
        if stars then state = state .. "  " .. stars end
        table.insert(title_lines, state)
    else
        table.insert(title_lines, _("Status unknown — never synced"))
    end

    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local function shelfButton(shelf)
        local label = Util.shelfLabel(shelf)
        if cached and cached.shelf_type == shelf then label = "✓ " .. label end
        return {
            text = label,
            callback = act(function() Actions.setShelf(ctx, shelf) end),
        }
    end

    dialog = ButtonDialog:new{
        title = table.concat(title_lines, "\n"),
        title_align = "center",
        buttons = {
            { shelfButton("wishlist"), shelfButton("progress") },
            { shelfButton("complete"), shelfButton("dropped") },
            {
                {
                    text = T(_("Progress: %1"),
                        Actions.positionLabel(progress_type, value, total)),
                    callback = act(function() Actions.updateProgress(ctx) end),
                },
            },
            {
                {
                    text = _("Rate & comment"),
                    callback = act(function() Actions.rateAndComment(ctx) end),
                },
                {
                    text = _("Add note"),
                    callback = act(function() Actions.addNote(ctx) end),
                },
            },
            {
                {
                    text = _("Book details"),
                    callback = act(function() Match.showLinkedInfo(ctx) end),
                },
                {
                    text = _("Refresh from NeoDB"),
                    callback = act(function()
                        Match.refreshMark(ctx, function() Actions.showSheet(ctx) end)
                    end),
                },
            },
        },
    }
    UIManager:show(dialog)
end

return Actions
