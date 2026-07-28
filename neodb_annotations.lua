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
  was made under. `uploadAll` is the deliberate exception.

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

--- The open book's link and its sync state, or nil when it is not linked.
local function linkedState(ctx)
    local link = ctx.store:getLink(ctx.ui and ctx.ui.doc_settings)
    if not link then return nil end
    return link, syncState(link)
end

function Annotations.isEnabled(ctx)
    local link, state = linkedState(ctx)
    return link ~= nil and state.enabled == true
end

--[[--
Turns the mirror on or off for the open book.

Switching it on re-stamps `since`. The highlights already in the book were made
before the reader asked for any of this, and a switch that empties a backlog into
a timeline is not one anybody flips twice. "Upload all" is there for when that
backlog is what they actually wanted.
]]
function Annotations.setEnabled(ctx, enabled)
    local link, state = linkedState(ctx)
    if not link then return false end

    enabled = enabled == true
    if enabled and not state.enabled then
        state.since = Util.timestamp()
    end
    state.enabled = enabled
    link.annotation_sync = state
    ctx.store:setLink(ctx.ui.doc_settings, link)
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
local function pending(ctx, state, include_backlog)
    local annotations = ctx.ui.annotation and ctx.ui.annotation.annotations
    if type(annotations) ~= "table" then return {} end

    local sent = sentTable(state)
    local since = include_backlog and "" or (state.since or "")
    local list = {}
    for _idx, annotation in ipairs(annotations) do
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
]]
function Annotations.noteBody(ctx, annotation)
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

    local progress_type, value = Actions.annotationPosition(ctx, annotation)
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

@treturn int how many were queued
]]
local function enqueueAll(ctx, link, state, list)
    local sent = sentTable(state)
    for _idx, annotation in ipairs(list) do
        local created = annotation.datetime
        ctx.store:enqueue({
            method = "POST",
            path   = ctx.api:notePath(link.uuid),
            body   = Annotations.noteBody(ctx, annotation),
            label  = T(_("Highlight from “%1”"), link.title or "?"),
            -- Marked sent below, so this key should not come round again -- but
            -- if it somehow does, one post is the right answer, not two.
            dedup  = "annotation:" .. link.uuid .. ":" .. created,
            --[[--
            Plain data, because the queue is written to disk: this is how the reply
            is matched back to the annotation that caused it. `file` names the book
            so that a reply arriving while some *other* book is open can still be
            filed; it is a hint rather than a promise, since by then the file may
            have been renamed or deleted.
            ]]
            annotation = {
                item = link.uuid,
                key  = created,
                file = ctx.ui.document and ctx.ui.document.file or nil,
            },
        })
        sent[created] = true
    end

    state.sent = sent
    link.annotation_sync = state
    ctx.store:setLink(ctx.ui.doc_settings, link)
    logger.dbg("NeoDB: queued", #list, "annotation(s) for", link.title)
    return #list
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
Writes a note uuid into the sidecar of a book KOReader does not have open.

`DocSettings:open` hands out a fresh instance every time, so this must never run
for the open book: the live instance holds its own copy of the same data and would
write it back over ours when the book closes. The caller checks that first.

Gated on the sidecar already existing, because `DocSettings:open` on a path with
none would invent one, and a book that has been deleted should not be given a new
metadata file. The link is checked too, so a path since taken by a different book
is left alone.

@treturn bool whether the uuid was filed
]]
local function writeToClosedBook(ctx, tag, record)
    if type(tag.file) ~= "string" or tag.file == "" then return false end

    --[[--
    Checked here rather than trusted to the caller. The reader can unlink a book
    while its notes are still queued, which leaves the caller unable to recognise
    its own open book -- and the cost of getting this wrong is not an error but
    silent loss, hours later, when KOReader writes its copy back over ours.
    ]]
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    if open_file and open_file == tag.file then return false end

    if not DocSettings:hasSidecarFile(tag.file) then return false end

    local doc_settings = DocSettings:open(tag.file)
    if not doc_settings then return false end

    local link = ctx.store:getLink(doc_settings)
    if not link or link.uuid ~= tag.item then return false end

    local state = syncState(link)
    local sent = sentTable(state)
    sent[tag.key] = record
    state.sent = sent
    link.annotation_sync = state
    -- Saves and flushes, which for a DocSettings is the sidecar written out.
    ctx.store:setLink(doc_settings, link)
    return true
end

--[[--
Files the uuid NeoDB gave a note we posted.

Three ways this can land, in order of preference:

1. the book is open, so its live sidecar is the only one safe to touch;
2. it is closed but still where we left it, so its sidecar is written directly;
3. it has been renamed, moved or deleted, so the uuid waits in the stash until
   that book is opened again.
]]
function Annotations.recordSent(ctx, op, data)
    local tag = type(op) == "table" and op.annotation or nil
    if type(tag) ~= "table" or type(tag.key) ~= "string" or not tag.item then return end

    local record = {
        uuid = type(data) == "table" and data.uuid or nil,
        at   = Util.timestamp(),
    }

    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    local link, state = linkedState(ctx)
    --[[--
    Matched on the file rather than the item: two copies of one book share a NeoDB
    entry but not their annotations, so the uuid has to go to the copy it came
    from. Ops queued before `file` was recorded fall back to the item.
    ]]
    local is_open_book = link ~= nil
        and (tag.file and tag.file == open_file or (not tag.file and link.uuid == tag.item))

    if is_open_book then
        local sent = sentTable(state)
        sent[tag.key] = record
        state.sent = sent
        link.annotation_sync = state
        ctx.store:setLink(ctx.ui.doc_settings, link)
        return
    end

    -- Touching the filesystem, so failure is a real possibility: a read-only card
    -- or an unplugged one must fall through to the stash, not lose the uuid.
    local ok, filed = pcall(writeToClosedBook, ctx, tag, record)
    if not ok then
        logger.warn("NeoDB: could not write", tostring(tag.file), "-", tostring(filed))
        filed = false
    end
    if filed then return end

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

    local link, state = linkedState(ctx)
    if not link then return 0 end

    local sent = sentTable(state)
    local keep, adopted = {}, 0
    for _idx, entry in ipairs(list) do
        if type(entry) == "table" and entry.item == link.uuid
            and type(entry.key) == "string" then
            sent[entry.key] = { uuid = entry.uuid, at = entry.at }
            adopted = adopted + 1
        else
            table.insert(keep, entry)
        end
    end
    if adopted == 0 then return 0 end

    state.sent = sent
    link.annotation_sync = state
    ctx.store:setLink(ctx.ui.doc_settings, link)
    ctx.store:set(STASH_KEY, keep)
    logger.dbg("NeoDB: adopted", adopted, "stashed note uuid(s)")
    return adopted
end

--[[--
Queues the annotations made since the switch was turned on.

@treturn int how many were queued
]]
function Annotations.queueNew(ctx)
    if not ctx.store:isLoggedIn() then return 0 end

    local link, state = linkedState(ctx)
    if not link or not state.enabled then return 0 end

    --[[--
    A switch that is on with nothing to measure against would treat the whole book
    as new. Nothing should be able to leave it in that state, but the failure would
    be a few hundred posts, so repair it and wait for the next round.
    ]]
    if not state.since then
        logger.warn("NeoDB: annotation sync had no start point; stamping now")
        state.since = Util.timestamp()
        link.annotation_sync = state
        ctx.store:setLink(ctx.ui.doc_settings, link)
        return 0
    end

    local list = pending(ctx, state, false)
    if #list == 0 then return 0 end
    return enqueueAll(ctx, link, state, list)
end

--[[--
Uploads every highlight and note in the book that NeoDB has not been told about.

Unlike the automatic path this ignores when the switch was turned on, and works
whether it is on at all: asking for the backlog is the whole point, and it is the
one case where posting what came before the switch is what the reader meant.
]]
function Annotations.uploadAll(ctx)
    Actions.requireLink(ctx, function(link)
        local state = syncState(link)
        local list = pending(ctx, state, true)
        if #list == 0 then
            Util.notify(_("NeoDB already has every highlight in this book."))
            return
        end

        local function go()
            enqueueAll(ctx, link, state, list)
            Actions.flushQueue(ctx, false)
        end

        if #list <= MANUAL_WARN_THRESHOLD then return go() end

        --[[--
        Worth a confirmation past a certain size. Each highlight is a separate
        NeoDB note, so this is the one action here that can turn into a hundred
        posts from one tap, and it cannot be taken back from the reader's side.
        ]]
        local warning = T(_("Post %1 highlights and notes from “%2” to NeoDB?\n\nEach one becomes a separate note, and they cannot be taken back from here."),
            tostring(#list), Util.ellipsize(link.title or "?", 40))
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

return Annotations
