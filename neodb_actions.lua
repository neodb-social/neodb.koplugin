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
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Login = require("neodb_login")
local Match = require("neodb_match")
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

--- Replaces a dialog button's label in place, without rebuilding the dialog.
local function relabel(dialog, id, text)
    local button = dialog.button_table and dialog.button_table:getButtonById(id)
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

    local percent = ui.doc_settings and ui.doc_settings:readSetting("percent_finished")
    if not percent and page and total and total > 0 then
        percent = page / total
    end
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

--[[--
Note composer, also used for sharing a highlighted quote.

@param opts.quote          highlighted text to quote
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
        local attach_progress = true
        local visibility = ctx.store:get("default_visibility")
        local post = ctx.store:get("post_to_fediverse")
        local note_title = opts.title or ""

        local prefill = ""
        if opts.quote and opts.quote ~= "" then
            local quote = Util.trim(opts.quote)
            if ctx.store:get("quote_as_blockquote") then
                quote = "> " .. quote:gsub("\n", "\n> ")
            end
            -- Cursor lands after the quote, ready for the reader's own thought.
            prefill = quote .. "\n\n"
        end

        local dialog
        local function progressLabel()
            return attach_progress
                and T(_("At: %1"), Actions.positionLabel(progress_type, value, total))
                or _("At: not attached")
        end
        local function titleLabel()
            return note_title ~= ""
                and T(_("Title: %1"), Util.ellipsize(note_title, 20))
                or _("Title: none")
        end

        dialog = InputDialog:new{
            title = opts.quote and _("Share a quote") or _("Add a note"),
            description = T(_("On “%1”"), Util.ellipsize(link.title or "?", 40)),
            input = prefill,
            input_hint = opts.quote and _("Add your thoughts (optional)") or _("Your note"),
            allow_newline = true,
            use_available_height = true,
            cursor_at_end = true,
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
                    {
                        text = titleLabel(),
                        id = "note_title",
                        callback = function()
                            -- Two keyboards at once is a state KOReader does not
                            -- track, so the note's has to go before this one opens.
                            hideKeyboard(dialog)
                            local title_dialog
                            title_dialog = InputDialog:new{
                                title = _("Note title"),
                                input = note_title,
                                buttons = {{
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function() UIManager:close(title_dialog) end,
                                    },
                                    {
                                        text = _("Set"),
                                        is_enter_default = true,
                                        callback = function()
                                            note_title = Util.trim(title_dialog:getInputText())
                                            UIManager:close(title_dialog)
                                            relabel(dialog, "note_title", titleLabel())
                                        end,
                                    },
                                }},
                            }
                            UIManager:show(title_dialog)
                            title_dialog:onShowKeyboard()
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
                        text = _("Post"),
                        callback = function()
                            local content = Util.trim(dialog:getInputText())
                            if content == "" then
                                Util.alert(_("The note is empty."))
                                return
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
                            local key = opts.annotation_key
                            local marked = false
                            if type(key) == "string" then
                                op.annotation = {
                                    item = link.uuid,
                                    key  = key,
                                    file = ctx.ui.document and ctx.ui.document.file,
                                }
                                marked = annotations().markQueued(ctx, key)
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
Uploads the queue after the current screen has been drawn, if we can.

Deliberately silent and deliberately not `whenOnline`: this is the background
path, and a sync nobody asked for must never turn a radio on or raise a dialog.
Next tick rather than now so whatever prompted it gets painted first -- a request
blocks the UI thread for as long as its timeout.
]]
function Actions.flushSoon(ctx)
    if not Util.isOnline() then return end
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
        if (stopped == "unauthorized" or stopped == "forbidden")
            and stopped ~= (type(previous) == "table" and previous.stopped or nil) then
            Util.notify(_("NeoDB uploads are paused: sign in again to send them."))
        end
    end)
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
