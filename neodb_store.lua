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

    --- Pairing service used by the QR sign-in. Point it at your own deployment
    --- if you would rather not involve a third party in the handshake.
    portal_url             = "https://p.neodb.net",
}

--- Ops we may keep queued, newest wins per dedup key.
local MAX_QUEUE = 50

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

--[[--
Adds an op to the upload queue.

`op.dedup` collapses supersedable ops: a second progress update for the same
book replaces the first rather than piling up. Ops without a dedup key (notes,
reviews) always append, because each one is a distinct post.

A superseding op takes over the slot of the one it replaces rather than moving to
the back. Order matters between ops for the same book -- progress needs the mark
that precedes it to have been created -- and jumping the queue would break it.
]]
function Store:enqueue(op)
    local queue = self:getQueue()
    if op.dedup then
        for i = 1, #queue do
            if queue[i].dedup == op.dedup then
                queue[i] = op
                self.settings:flush()
                return
            end
        end
    end
    table.insert(queue, op)
    while #queue > MAX_QUEUE do
        logger.warn("NeoDB: upload queue full, dropping", queue[1].label)
        table.remove(queue, 1)
    end
    self.settings:flush()
end

function Store:replaceQueue(queue)
    self.settings:saveSetting("queue", queue)
    self.settings:flush()
end

function Store:clearQueue()
    self:replaceQueue({})
end

return Store
