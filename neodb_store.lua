--[[--
Persistence for the NeoDB plugin.

Three separate things live here:

1. Account and preferences, in `settings/neodb.lua` (global).
2. The book <-> NeoDB item link, in the book's own sidecar file, so it travels
   with the book and survives a plugin reinstall.
3. An upload queue, so marks made with Wi-Fi off are not lost.

@module koplugin.neodb.store
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Util = require("neodb_util")

local Store = {}
Store.__index = Store

--- Preferences and their defaults. Anything not listed here has no default.
local DEFAULTS = {
    default_visibility     = 0,       -- public
    post_to_fediverse      = false,   -- don't broadcast unless asked
    progress_unit          = "auto",  -- auto | page | percentage
    auto_progress_on_close = false,
    auto_mark_finished     = false,
    quote_as_blockquote    = true,

    --- Whether a newly linked book mirrors its highlights and notes to NeoDB.
    --- Each book keeps its own switch; this is only what a new link starts with.
    auto_upload_annotations = false,

    --- Crossposting for shared highlights, deliberately separate from
    --- `post_to_fediverse`: a book's worth of quotes is a different proposition
    --- for whoever follows you than the marks and notes you write by hand.
    crosspost_annotations   = false,

    --- Pairing service used by the QR sign-in. Point it at your own deployment
    --- if you would rather not involve a third party in the handshake.
    portal_url             = "https://p.neodb.net",
}

--[[--
Ops we may keep queued, newest wins per dedup key.

The queue is one LuaSettings blob rewritten in full on every change, and a note op
carries its whole quote, so this bounds how much gets rewritten as much as it
bounds how much is waiting. A batch too big for it is not lost: `enqueueAll`
refuses the tail rather than dropping the head, and whatever did not fit stays
unrecorded for the next attempt.
]]
local MAX_QUEUE = 100

function Store:new()
    local instance = setmetatable({}, self)
    instance.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/neodb.lua")
    return instance
end

function Store:get(key)
    local value = self.settings:readSetting(key)
    if value == nil then return DEFAULTS[key] end
    return value
end

function Store:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Store:toggle(key)
    self:set(key, not self:get(key))
    return self:get(key)
end

-- Account -------------------------------------------------------------------

function Store:getInstance()
    return self.settings:readSetting("instance")
end

function Store:setInstance(instance)
    self:set("instance", instance)
end

function Store:getToken()
    return self.settings:readSetting("access_token")
end

--[[--
Sets just the token, without touching the account details.

Used when trying a token out: the API client reads the token from here, so it has
to be in place before we can check it, and put back if the server rejects it.
]]
function Store:setToken(token)
    self.settings:saveSetting("access_token", token)
    self.settings:flush()
end

function Store:isLoggedIn()
    return self:getInstance() ~= nil and self:getToken() ~= nil
end

--- Stores the token plus whatever /api/me told us about the account.
function Store:setAccount(token, user)
    self.settings:saveSetting("access_token", token)
    self.settings:saveSetting("username", user and user.username)
    self.settings:saveSetting("display_name", user and user.display_name)
    self.settings:flush()
end

--[[--
Records the rest of an OAuth grant, beyond the access token itself.

`expires_in` is a lifetime, which means nothing once written down, so it is
banked as an absolute `token_expires_at` instead.

Always called when a sign-in succeeds, `grant` or not: a route that carries no
grant details (a hand-typed token) must clear whatever the previous sign-in left
behind, or a stale refresh token would outlive the account it belonged to.
]]
function Store:setGrant(grant)
    grant = grant or {}
    self.settings:saveSetting("refresh_token", grant.refresh_token)
    self.settings:saveSetting("token_type", grant.token_type)
    self.settings:saveSetting("token_scope", grant.scope)
    self.settings:saveSetting("token_expires_at",
        grant.expires_in and (os.time() + grant.expires_in) or nil)
    self.settings:flush()
end

function Store:getGrant()
    return {
        refresh_token = self.settings:readSetting("refresh_token"),
        token_type    = self.settings:readSetting("token_type"),
        scope         = self.settings:readSetting("token_scope"),
        expires_at    = self.settings:readSetting("token_expires_at"),
    }
end

function Store:getAccountLabel()
    local name = self.settings:readSetting("username")
    local host = (self:getInstance() or ""):gsub("^%a+://", "")
    if not name then return host ~= "" and host or nil end
    return "@" .. name .. "@" .. host
end

--- OAuth client credentials, kept per instance so switching hosts re-registers.
function Store:getClient(instance)
    local clients = self.settings:readSetting("oauth_clients", {})
    return clients[instance]
end

function Store:setClient(instance, client_id, client_secret)
    local clients = self.settings:readSetting("oauth_clients", {})
    clients[instance] = { client_id = client_id, client_secret = client_secret }
    self.settings:flush()
end

--[[--
Forgets the account but keeps the instance and its registered app.

The app registration identifies this device to the server and is reusable by
whoever signs in next; everything the grant carried belongs to the account that
just left, refresh token included.
]]
function Store:logout()
    self.settings:delSetting("access_token")
    self.settings:delSetting("username")
    self.settings:delSetting("display_name")
    self.settings:delSetting("refresh_token")
    self.settings:delSetting("token_type")
    self.settings:delSetting("token_scope")
    self.settings:delSetting("token_expires_at")
    self.settings:flush()
end

-- Per-book link -------------------------------------------------------------
--
-- Stored in the book's sidecar, keyed under "neodb_link". Includes the instance
-- it came from: a UUID from one instance is meaningless on another.

local LINK_KEY = "neodb_link"

function Store:getLink(doc_settings)
    if not doc_settings then return nil end
    local link = doc_settings:readSetting(LINK_KEY)
    if type(link) ~= "table" or not link.uuid then return nil end
    if link.instance and link.instance ~= self:getInstance() then
        -- Linked against a different server; treat as unlinked rather than
        -- posting this book's marks to the wrong account.
        return nil, link
    end
    return link
end

function Store:setLink(doc_settings, link)
    if not doc_settings then return end
    link.instance = link.instance or self:getInstance()

    --[[--
    The link is what the highlight mirror hangs off, so a book that has just
    acquired one starts from the global preference -- and always with a starting
    point, so that turning that preference on can never post highlights made
    before anybody asked for it.
    ]]
    if link.annotation_sync == nil then
        link.annotation_sync = {
            enabled = self:get("auto_upload_annotations") == true,
            since   = Util.timestamp(),
        }
    end

    doc_settings:saveSetting(LINK_KEY, link)
    -- Write it out now: a link is expensive to recreate by hand.
    doc_settings:flush()
end

function Store:clearLink(doc_settings)
    if not doc_settings then return end
    doc_settings:delSetting(LINK_KEY)
    doc_settings:flush()
end

--[[--
Caches the last known server-side mark on the link.

Posting a mark *replaces* it, so a plain "Reading -> Finished" would wipe an
existing rating, comment and tags. We keep the last known values around and
send them back untouched unless the user actually changes them.
]]
function Store:cacheMark(doc_settings, mark)
    local link = self:getLink(doc_settings)
    if not link then return end
    link.mark = mark and {
        shelf_type   = mark.shelf_type,
        visibility   = mark.visibility,
        rating_grade = mark.rating_grade,
        comment_text = mark.comment_text,
        tags         = mark.tags,
    } or nil
    self:setLink(doc_settings, link)
end

function Store:cacheProgress(doc_settings, progress_type, progress_value)
    local link = self:getLink(doc_settings)
    if not link then return end
    link.progress = { type = progress_type, value = progress_value }
    self:setLink(doc_settings, link)
end

-- Upload queue --------------------------------------------------------------

function Store:getQueue()
    return self.settings:readSetting("queue", {})
end

function Store:queueCount()
    return #self:getQueue()
end

--- The cap itself, so a message can name the number instead of guessing it.
function Store:queueLimit()
    return MAX_QUEUE
end

--- How many more ops the queue will take before it is full.
function Store:queueRoom()
    return math.max(0, MAX_QUEUE - #self:getQueue())
end

--[[--
Puts `op` into the slot of the one it supersedes, if there is one.

A superseding op takes over that slot rather than moving to the back. Order
matters between ops for the same book -- progress needs the mark that precedes it
to have been created -- and jumping the queue would break it.

@treturn bool whether it replaced something
]]
local function supersede(queue, op)
    if not op.dedup then return false end
    for i = 1, #queue do
        if queue[i].dedup == op.dedup then
            queue[i] = op
            return true
        end
    end
    return false
end

--[[--
Adds an op to the upload queue.

`op.dedup` collapses supersedable ops: a second progress update for the same
book replaces the first rather than piling up. Ops without a dedup key (notes,
reviews) always append, because each one is a distinct post.
]]
function Store:enqueue(op)
    local queue = self:getQueue()
    if not supersede(queue, op) then
        table.insert(queue, op)
        while #queue > MAX_QUEUE do
            logger.warn("NeoDB: upload queue full, dropping", queue[1].label)
            table.remove(queue, 1)
        end
    end
    self.settings:flush()
end

--[[--
Queues a whole batch at once, and says how much of it it took.

Two things this does that `enqueue` in a loop does not:

* **It stops at the cap instead of dropping from the front.** Callers mark what
  they queued as sent, so a batch that quietly lost its first half would be notes
  recorded as sent and never posted, with nothing left to retry them. Refusing
  the tail is recoverable instead: what was not accepted stays unmarked, and the
  next attempt picks up exactly there.
* **It writes the settings file once.** `enqueue` flushes per call, so a few
  hundred of them rewrite the whole blob a few hundred times.

Ops are taken in order and it stops at the first one that will not fit, so the
result is a prefix count: the caller marks the first `n` and leaves the rest.

@treturn int how many of `ops` were accepted
]]
function Store:enqueueAll(ops)
    local queue = self:getQueue()
    local accepted = 0
    for _idx, op in ipairs(ops) do
        if supersede(queue, op) then
            -- Took the slot of one already waiting, so it costs no room.
            accepted = accepted + 1
        elseif #queue < MAX_QUEUE then
            table.insert(queue, op)
            accepted = accepted + 1
        else
            logger.warn("NeoDB: upload queue full, leaving",
                #ops - accepted, "for the next attempt")
            break
        end
    end
    if accepted > 0 then self.settings:flush() end
    return accepted
end

function Store:replaceQueue(queue)
    self.settings:saveSetting("queue", queue)
    self.settings:flush()
end

function Store:clearQueue()
    self:replaceQueue({})
end

return Store
