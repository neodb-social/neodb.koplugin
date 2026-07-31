--[[--
Mirrors KOReader's own highlights and notes to NeoDB as they are made.

The awkward part is not the posting but knowing when an annotation is finished.
KOReader announces a highlight the moment it saves one, which for "Add note" is
*before* the note editor has even opened; extending a selection deletes the
annotation and makes a new one; and editing an existing note's text announces
nothing at all. So nothing here trusts an event: the caller waits for the reader to
stop, and then this module reads the annotation list, which is the only place that
knows how each one ended up.

Two rules follow from that:

* **Each annotation is posted once**, as it stands when things settle. Reading the
  list means a highlight made and then deleted is never posted, and one extended
  twice is posted once.
* **What a book already holds is left alone.** The state records when the switch
  was turned on; a preference nobody had yet cannot be what a year of highlights
  was made under. `uploadAll` and the exporter target are the deliberate
  exceptions.

Everything here works through a *book handle* (`resolveBook`), because the reply to
a post usually arrives while some other book is open, or none at all, and because
KOReader's exporter hands us whole shelves of books that are not open. The handle
is what decides -- once, and never at a call site -- which `DocSettings` it is safe
to write to.

@module koplugin.neodb.annotations
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Actions = require("neodb_actions")
local Util = require("neodb_util")

--- More posts than this in one go is worth asking about before starting.
local MANUAL_WARN_THRESHOLD = 10

--- Note uuids waiting for their book to turn up again. See `stash`.
local STASH_KEY = "pending_note_uuids"

--- Enough to cover a long stretch offline. A lost uuid costs an edit, not a note.
local MAX_STASH = 200

local Annotations = {}

--[[--
Per-book state, kept on the link so it travels with the book and goes away with it:

    enabled  whether new annotations are posted at all
    since    only annotations created after this are eligible
    sent     what has been handed to the upload queue, keyed by creation time

A `sent` entry is `{ uuid, at }` once the post has actually gone out -- `uuid`
being NeoDB's handle for that note, the only way to edit or delete it later, and
`at` when we last wrote it, to compare against KOReader's own
`datetime_updated`. Until then it is simply `true`, and a plugin version older
than any of this left `true` behind for good, so presence is what counts and the
shape never is.
]]
local function syncState(link)
    if type(link.annotation_sync) == "table" then return link.annotation_sync end
    return {}
end

local function sentTable(state)
    if type(state.sent) == "table" then return state.sent end
    return {}
end

-- Book handles ---------------------------------------------------------------

--[[--
A book, and the one `DocSettings` it is safe to write to.

    file          the document's path, as far as we know it
    doc_settings  where its link lives
    live          true when this is KOReader's own instance for the open book
    pages         how many pages it was last counted to have

`DocSettings:open` hands out a **fresh instance every call**; there is no cache.
Opening a second one for the book KOReader has open means its live copy is written
back over ours when the book closes -- silent loss, hours later. Which route to
take is therefore decided here and never left to a caller: the reader can unlink a
book while its notes are still queued, which leaves a caller unable to recognise
even its own open book.

@param file document path, or nil for whatever is open
@treturn table|nil handle, or nil when there is nothing safe to touch
]]
local function resolveBook(ctx, file)
    local ui = ctx.ui
    local open_file = ui and ui.document and ui.document.file

    if file == nil or (open_file ~= nil and file == open_file) then
        if not (ui and ui.doc_settings) then return nil end
        return {
            file         = open_file,
            doc_settings = ui.doc_settings,
            live         = true,
            pages        = ui.doc_settings:readSetting("doc_pages"),
        }
    end

    -- `getSidecarFilename` calls `:match` on the path, so a non-string throws.
    if type(file) ~= "string" or file == "" then return nil end

    --[[--
    `DocSettings:open` on a path with no sidecar *invents* one, and `flush` would
    then write it out -- giving a book that has been deleted a fresh metadata file.
    ]]
    if not DocSettings:hasSidecarFile(file) then return nil end

    local doc_settings = DocSettings:open(file)
    if not doc_settings then return nil end
    return {
        file         = file,
        doc_settings = doc_settings,
        live         = false,
        -- No default argument: `readSetting` installs a truthy default, and
        -- `saveState` flushes, so a default would grow the sidecar a stale key.
        pages        = doc_settings:readSetting("doc_pages"),
    }
end

--[[--
The same, but only for a book that is actually linked to something postable.

@param expect_uuid optional NeoDB uuid the link must still match, for when a path
                   may have been taken over by a different book since
]]
local function linkedBook(ctx, file, expect_uuid)
    local book = resolveBook(ctx, file)
    if not book then return nil end

    -- Also nil for a book linked to a different instance, which is what we want:
    -- its uuid means nothing on the server we are signed in to.
    local link = ctx.store:getLink(book.doc_settings)
    if not link then return nil end
    if expect_uuid and link.uuid ~= expect_uuid then return nil end

    book.link = link
    book.state = syncState(link)
    return book
end

--[[--
Writes a handle's sync state back to its book.

Assigning `annotation_sync` before `setLink` is the point: `setLink` seeds a fresh
one for a link that has none, and would otherwise replace everything recorded
here. For a `DocSettings` this saves *and* flushes, so the sidecar is on disk when
this returns.
]]
local function saveState(ctx, book)
    book.link.annotation_sync = book.state
    ctx.store:setLink(book.doc_settings, book.link)
end

--- The annotations a book holds, from wherever this one keeps them.
local function annotationList(ctx, book)
    local annotations
    if book.live then
        annotations = ctx.ui.annotation and ctx.ui.annotation.annotations
    else
        annotations = book.doc_settings:readSetting("annotations")
    end
    return type(annotations) == "table" and annotations or {}
end

-- The per-book switch --------------------------------------------------------

function Annotations.isEnabled(ctx)
    local book = linkedBook(ctx, nil)
    return book ~= nil and book.state.enabled == true
end

--[[--
Turns the mirror on or off for the open book.

Switching it on re-stamps `since`. The highlights already in the book were made
before the reader asked for any of this, and a switch that empties a backlog into
a timeline is not one anybody flips twice. "Upload all" is there for when that
backlog is what they actually wanted.
]]
function Annotations.setEnabled(ctx, enabled)
    local book = linkedBook(ctx, nil)
    if not book then return false end

    enabled = enabled == true
    if enabled and not book.state.enabled then
        book.state.since = Util.timestamp()
    end
    book.state.enabled = enabled
    saveState(ctx, book)
    return enabled
end

--[[--
Whether an annotation is something to post.

`drawer` is what separates a highlight from a plain page bookmark, which marks a
place and says nothing. `is_tmp` is the scaffolding KOReader leaves in the list
while a multi-page selection is still being dragged out.
]]
local function isShareable(annotation)
    if type(annotation) ~= "table" then return false end
    if not annotation.drawer or annotation.is_tmp then return false end
    return Util.trim(annotation.text or "") ~= ""
        or Util.trim(annotation.note or "") ~= ""
end

--[[--
The annotations NeoDB has not been told about, in the order the book holds them.

@param include_backlog drop the "only what came after the switch" cutoff, for when
                       the reader has asked for everything on purpose
]]
local function pending(ctx, book, include_backlog)
    local sent = sentTable(book.state)
    local since = include_backlog and "" or (book.state.since or "")
    local list = {}
    for _idx, annotation in ipairs(annotationList(ctx, book)) do
        local created = annotation.datetime
        -- Compared as strings, which is what KOReader's timestamp format is for.
        if type(created) == "string" and created > since
            and sent[created] == nil and isShareable(annotation) then
            table.insert(list, annotation)
        end
    end
    return list
end

--[[--
The NeoDB note for one KOReader annotation.

Shaped like what the "Share on NeoDB" composer produces, so an automatic post and
a hand-made one read alike: the passage as a quote, the reader's own note under
it, and the position it was made at attached.

@param book optional handle, so a book that is not open can still be placed
]]
function Annotations.noteBody(ctx, annotation, book)
    local parts = {}

    local quote = Util.trim(annotation.text or "")
    if quote ~= "" then
        if ctx.store:get("quote_as_blockquote") then
            quote = "> " .. quote:gsub("\n", "\n> ")
        end
        table.insert(parts, quote)
    end

    local note = Util.trim(annotation.note or "")
    if note ~= "" then table.insert(parts, note) end

    local body = {
        -- The chapter is the context a bare quote is missing, and KOReader has
        -- already worked it out and stored it on the annotation.
        title             = Util.trim(annotation.chapter or ""),
        content           = table.concat(parts, "\n\n"),
        visibility        = ctx.store:get("default_visibility"),
        -- Its own switch, not the one that governs marks and hand-written notes:
        -- a book's worth of quotes is a different proposition for whoever follows
        -- you than the handful you chose to post one at a time.
        post_to_fediverse = ctx.store:get("crosspost_annotations") == true,
        sensitive         = false,
    }

    local progress_type, value = Actions.annotationPosition(ctx, annotation, book)
    if progress_type then
        body.progress_type  = progress_type
        body.progress_value = tostring(value)
    end
    return body
end

--[[--
Puts a batch on the upload queue and records that it went.

Queued rather than sent: a request blocks the UI thread for as long as its
timeout, and a highlight is made in the middle of a page. Whether to drain the
queue afterwards is the caller's business.

Marked sent here rather than when the post lands, which costs us the retry of an
op the queue eventually gives up on. The alternative costs worse: a book whose
notes went out while it was closed would come back looking untouched, and post
every one of them again.

Only what the queue actually accepted is marked. A full queue therefore means the
tail of a batch stays outstanding rather than being recorded as sent and never
posted, and the next attempt picks up exactly there.

@treturn int how many were queued
]]
function Annotations.queueFor(ctx, book, list)
    if #list == 0 then return 0 end

    local ops = {}
    for _idx, annotation in ipairs(list) do
        table.insert(ops, {
            method = "POST",
            path   = ctx.api:notePath(book.link.uuid),
            body   = Annotations.noteBody(ctx, annotation, book),
            label  = T(_("Highlight from “%1”"), book.link.title or "?"),
            -- Marked sent below, so this key should not come round again -- but
            -- if it somehow does, one post is the right answer, not two.
            dedup  = "annotation:" .. book.link.uuid .. ":" .. annotation.datetime,
            --[[--
            Plain data, because the queue is written to disk: this is how the reply
            is matched back to the annotation that caused it. `file` names the book
            so that a reply arriving while some *other* book is open can still be
            filed; it is a hint rather than a promise, since by then the file may
            have been renamed or deleted.
            ]]
            annotation = {
                item = book.link.uuid,
                key  = annotation.datetime,
                file = book.file,
            },
        })
    end

    local accepted = ctx.store:enqueueAll(ops)
    if accepted == 0 then
        logger.warn("NeoDB: queue full, none of", #ops, "annotation(s) taken")
        return 0
    end

    local sent = sentTable(book.state)
    for i = 1, accepted do
        sent[ops[i].annotation.key] = true
    end
    book.state.sent = sent
    saveState(ctx, book)
    logger.dbg("NeoDB: queued", accepted, "of", #ops, "annotation(s) for",
        book.link.title)
    return accepted
end

-- Filing the uuid a posted note comes back with --------------------------------
--
-- A note's uuid is NeoDB's only handle for editing or deleting it later, and it
-- does not exist until the post has gone out -- which, for something that waited
-- in the queue, is usually while some *other* book is open, or none at all. It
-- belongs in the book's own sidecar, so getting it there is the whole problem.

--[[--
Parks a uuid whose book we could not reach.

The stash is drained by `adoptStashed` when a book is opened, which is the other
moment we can be certain of having the right sidecar in front of us. Kept in the
plugin's own settings rather than in the queue: the note is already posted, and
re-posting it is exactly what must not happen.
]]
local function stash(ctx, entry)
    local list = ctx.store:get(STASH_KEY)
    if type(list) ~= "table" then list = {} end

    -- One entry per annotation: a second reply for one we already hold is the
    -- same note, reported again.
    for i = 1, #list do
        if list[i].item == entry.item and list[i].key == entry.key then
            list[i] = entry
            ctx.store:set(STASH_KEY, list)
            return
        end
    end

    table.insert(list, entry)
    while #list > MAX_STASH do
        logger.warn("NeoDB: uuid stash full, dropping one for item", list[1].item)
        table.remove(list, 1)
    end
    ctx.store:set(STASH_KEY, list)
end

--[[--
Files the uuid NeoDB gave a note we posted.

`linkedBook` sorts out where it goes: the live sidecar when that book is open, its
own sidecar when it is merely closed, and nothing at all when it has been renamed,
moved or deleted -- in which case the uuid waits in the stash until that book is
opened again.

Matched on the file rather than the item, because two copies of one book share a
NeoDB entry but not their annotations, so the uuid has to reach the copy it came
from. Ops queued before `file` was recorded fall back to the open book, which is
what `linkedBook(ctx, nil, item)` checks.
]]
function Annotations.recordSent(ctx, op, data)
    local tag = type(op) == "table" and op.annotation or nil
    if type(tag) ~= "table" or type(tag.key) ~= "string" or not tag.item then return end

    local record = {
        uuid = type(data) == "table" and data.uuid or nil,
        at   = Util.timestamp(),
    }

    -- Touching the filesystem, so failure is a real possibility: a read-only card
    -- or an unplugged one must fall through to the stash, not lose the uuid.
    local ok, filed = pcall(function()
        local book = linkedBook(ctx, tag.file, tag.item)
        if not book then return false end
        local sent = sentTable(book.state)
        sent[tag.key] = record
        book.state.sent = sent
        saveState(ctx, book)
        return true
    end)
    if not ok then
        logger.warn("NeoDB: could not write", tostring(tag.file), "-", tostring(filed))
    elseif filed then
        return
    end

    stash(ctx, { item = tag.item, key = tag.key, uuid = record.uuid, at = record.at })
    logger.dbg("NeoDB: stashed a note uuid until its book turns up again")
end

--[[--
Files any stashed uuids belonging to the book that has just opened.

@treturn int how many were adopted
]]
function Annotations.adoptStashed(ctx)
    local list = ctx.store:get(STASH_KEY)
    if type(list) ~= "table" or #list == 0 then return 0 end

    local book = linkedBook(ctx, nil)
    if not book then return 0 end

    local sent = sentTable(book.state)
    local keep, adopted = {}, 0
    for _idx, entry in ipairs(list) do
        if type(entry) == "table" and entry.item == book.link.uuid
            and type(entry.key) == "string" then
            sent[entry.key] = { uuid = entry.uuid, at = entry.at }
            adopted = adopted + 1
        else
            table.insert(keep, entry)
        end
    end
    if adopted == 0 then return 0 end

    book.state.sent = sent
    saveState(ctx, book)
    ctx.store:set(STASH_KEY, keep)
    logger.dbg("NeoDB: adopted", adopted, "stashed note uuid(s)")
    return adopted
end

-- Posting --------------------------------------------------------------------

--[[--
Queues the annotations made since the switch was turned on.

@treturn int how many were queued
]]
function Annotations.queueNew(ctx)
    if not ctx.store:isLoggedIn() then return 0 end

    local book = linkedBook(ctx, nil)
    if not book or not book.state.enabled then return 0 end

    --[[--
    A switch that is on with nothing to measure against would treat the whole book
    as new. Nothing should be able to leave it in that state, but the failure would
    be a few hundred posts, so repair it and wait for the next round.
    ]]
    if not book.state.since then
        logger.warn("NeoDB: annotation sync had no start point; stamping now")
        book.state.since = Util.timestamp()
        saveState(ctx, book)
        return 0
    end

    return Annotations.queueFor(ctx, book, pending(ctx, book, false))
end

--[[--
Deletes from NeoDB what the reader has deleted from the book.

Only for a book whose mirror switch is on: the switch is what "keep NeoDB in step
with this book" means, so notes posted deliberately -- the share composer, the
exporter on a book that never had the switch -- outlive their highlight, the same
way they were posted without it.

The ledger is the record of what went out, so a `sent` key with no matching
annotation left in the book is a deletion. Extending a selection is not one:
KOReader recreates the annotation with its `datetime` carried over, synchronously,
so by the time the settle timer comes round the key is present again.

What happens depends on how far the note got:

* Delivered (`{ uuid, at }`): queue a DELETE against that uuid.
* Still only queued (`true`): pull the pending post back out of the queue, so a
  deleted highlight is never posted at all. `true` is also what a plugin version
  that kept no uuids left behind for good -- for those the post is long gone and
  there is no handle to delete with, so the entry is simply let go.

Either way the ledger entry is dropped here, at queue time, matching how it was
marked at queue time when the note went out.

@treturn int how many server-side deletions were queued
]]
function Annotations.queueDeletions(ctx)
    if not ctx.store:isLoggedIn() then return 0 end

    local book = linkedBook(ctx, nil)
    if not book or not book.state.enabled then return 0 end

    local sent = sentTable(book.state)
    if next(sent) == nil then return 0 end

    --[[--
    `annotationList` reads a missing list as an empty one, which everywhere else
    is harmless -- nothing to post. Here it would read as "the reader deleted
    everything" and delete a book's worth of notes off the server, so a list that
    is not actually there must mean stop, not empty.
    ]]
    if not (ctx.ui and ctx.ui.annotation
        and type(ctx.ui.annotation.annotations) == "table") then
        return 0
    end

    local present = {}
    for _idx, annotation in ipairs(annotationList(ctx, book)) do
        if type(annotation) == "table" and type(annotation.datetime) == "string" then
            present[annotation.datetime] = true
        end
    end

    -- Clearing an existing key mid-iteration is the one mutation `next` allows.
    local queued, changed = 0, false
    for key, record in pairs(sent) do
        if not present[key] then
            if type(record) == "table" and record.uuid then
                ctx.store:enqueue({
                    method = "DELETE",
                    path   = ctx.api:noteSelfPath(record.uuid),
                    label  = T(_("Delete highlight from “%1”"), book.link.title or "?"),
                    dedup  = "notedelete:" .. record.uuid,
                })
                queued = queued + 1
            else
                ctx.store:removeByDedup("annotation:" .. book.link.uuid .. ":" .. key)
            end
            sent[key] = nil
            changed = true
        end
    end

    if changed then
        book.state.sent = sent
        saveState(ctx, book)
        logger.dbg("NeoDB: noticed deleted annotation(s),", queued, "deletion(s) queued")
    end
    return queued
end

--[[--
Uploads every highlight and note in the book that NeoDB has not been told about.

Unlike the automatic path this ignores when the switch was turned on, and works
whether it is on at all: asking for the backlog is the whole point, and it is the
one case where posting what came before the switch is what the reader meant.
]]
function Annotations.uploadAll(ctx)
    Actions.requireLink(ctx, function()
        local book = linkedBook(ctx, nil)
        if not book then return end

        local list = pending(ctx, book, true)
        if #list == 0 then
            Util.notify(_("NeoDB already has every highlight in this book."))
            return
        end

        local function go()
            Annotations.queueFor(ctx, book, list)
            Actions.flushQueue(ctx, false)
        end

        if #list <= MANUAL_WARN_THRESHOLD then return go() end

        --[[--
        Worth a confirmation past a certain size. Each highlight is a separate
        NeoDB note, so this is the one action here that can turn into a hundred
        posts from one tap, and it cannot be taken back from the reader's side.
        ]]
        local warning = T(_("Post %1 highlights and notes from “%2” to NeoDB?\n\nEach one becomes a separate note, and they cannot be taken back from here."),
            tostring(#list), Util.ellipsize(book.link.title or "?", 40))
        if ctx.store:get("crosspost_annotations") then
            warning = warning .. "\n\n"
                .. _("Crossposting shared highlights is on, so your followers will see all of them.")
        end
        UIManager:show(ConfirmBox:new{
            text = warning,
            ok_text = _("Post them"),
            ok_callback = go,
        })
    end)
end

-- For KOReader's own "Export highlights" -------------------------------------

--[[--
The link and sync state of a book named by path, or nil when nothing can be posted.

Nil covers every reason at once -- not linked, linked to another instance, no
sidecar, path since taken by a different book -- because the caller's answer to
all of them is the same: skip this book.
]]
function Annotations.bookAt(ctx, file)
    return linkedBook(ctx, file)
end

--[[--
The annotations named by `keys` that NeoDB has not been told about, in book order.

`keys` is a set of creation timestamps, which is how a caller working from
something other than the annotation list says which ones it means -- KOReader's
exporter hands over its own filtered *clippings*, which carry no identity beyond
when they were made.

The book's own list still decides. It is the only place that knows how each
annotation ended up, and `isShareable` still applies: the exporter's filter only
looks at `drawer`, so the scaffolding KOReader leaves behind mid-drag would
otherwise be posted.
]]
function Annotations.unsentAt(ctx, book, keys)
    local sent = sentTable(book.state)
    local list = {}
    for _idx, annotation in ipairs(annotationList(ctx, book)) do
        local created = annotation.datetime
        if type(created) == "string" and keys[created]
            and sent[created] == nil and isShareable(annotation) then
            table.insert(list, annotation)
        end
    end
    return list
end

return Annotations
