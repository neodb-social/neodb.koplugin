--[[--
NeoDB HTTP client.

Every call here blocks the UI thread for the duration of the request, so callers
are expected to have shown a "please wait" box first (see `Util.busy`) and to
have made sure we are online (see `Util.whenOnline`).

@module koplugin.neodb.api
]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local Util = require("neodb_util")

-- Short enough that a flaky connection does not lock up the reader, long enough
-- for a sleepy self-hosted instance to answer.
local BLOCK_TIMEOUT = 10
local TOTAL_TIMEOUT = 25

local OOB_REDIRECT = "urn:ietf:wg:oauth:2.0:oob"
local OAUTH_SCOPES = "read write"

--- Enough hops for a merge chain the server already collapsed into one.
local MAX_REDIRECTS = 3

local Api = {}
Api.__index = Api

function Api:new(fields)
    return setmetatable(fields or {}, self)
end

--[[--
Resolves a `Location` header against the URL it came from.

NeoDB answers with root-relative locations ("/api/book/<uuid>"), but a redirect may
legitimately be absolute, so handle both rather than assuming.
]]
function Api.resolveLocation(base, location)
    if type(location) ~= "string" then return nil end
    location = Util.trim(location)
    if location == "" then return nil end
    if location:match("^%a[%w%+%-%.]*://") then return location end
    local origin = tostring(base or ""):match("^(%a[%w%+%-%.]*://[^/]+)")
    if not origin then return nil end
    if location:sub(1, 1) == "/" then return origin .. location end
    -- Relative to the directory of the base path.
    local dir = tostring(base):match("^(%a[%w%+%-%.]*://[^/]+.*/)")
    return (dir or (origin .. "/")) .. location
end

--- scheme://host[:port], lowercased, or nil if `url` has none.
local function originOf(url)
    local origin = tostring(url or ""):match("^(%a[%w%+%-%.]*://[^/]+)")
    return origin and origin:lower() or nil
end

--- The path part of an absolute URL.
function Api.pathOf(url)
    return tostring(url or ""):match("^%a[%w%+%-%.]*://[^/]*(/.*)$")
end

--[[--
Pulls the item uuid out of an item-scoped API path.

Every endpoint we redirect through names the item the same way -- shelf, progress
and note paths all carry it after "/item/", the catalog reads it after the category
-- so comparing before and after is enough to notice the item changed under us.
]]
function Api.uuidFromPath(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("[?#].*$", "")
    return path:match("/item/([^/]+)") or path:match("^/api/%a[%w_]*/([^/]+)")
end

--[[--
Performs one HTTP request against an absolute URL.

`opts.auth` selects how the bearer token is handled:

* `"required"` (default) -- fail early rather than send an anonymous request.
* `"optional"` -- send the token if we have one. The catalog is public on
  neodb.social, but a self-hosted instance may well require a login to read it,
  so we always identify ourselves when we can.
* `"none"` -- never send it (the OAuth endpoints, which have no token yet).

@treturn bool ok
@treturn table|string decoded body on success, an error kind on failure
@treturn int HTTP status code, when there was one
]]
function Api:raw(method, url, opts)
    opts = opts or {}
    -- Set before anything can return early: a value left over from the previous
    -- request would look to `call` like this item had moved.
    self.final_url = url

    local headers = { ["Accept"] = "application/json" }

    local auth = opts.auth or "required"
    if auth ~= "none" then
        local token = self.store:getToken()
        if token then
            headers["Authorization"] = "Bearer " .. token
        elseif auth == "required" then
            return false, "unauthorized"
        end
    end

    if opts.headers then
        for name, value in pairs(opts.headers) do headers[name] = value end
    end

    local body
    if opts.json then
        body = JSON.encode(opts.json)
        headers["Content-Type"] = "application/json"
    elseif opts.form then
        body = Util.buildQuery(opts.form)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    end
    if body then
        headers["Content-Length"] = tostring(#body)
    elseif method == "POST" or method == "PUT" or method == "PATCH" then
        -- Some servers reject a bodyless POST that does not say so explicitly.
        headers["Content-Length"] = "0"
    end

    local origin = originOf(url)
    local target, hops = url, 0

    while true do
        local sink = {}
        local request = {
            url = target,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(sink),
            -- We follow redirects ourselves. A merged catalog item answers with
            -- one, and *that it happened* is information the caller needs; LuaSocket
            -- would swallow it. It also declines to follow a redirected write at
            -- all, which is exactly the case that matters, and how it resolves a
            -- relative Location differs between the version KOReader bundles and
            -- others.
            redirect = false,
        }
        if body then request.source = ltn12.source.string(body) end

        logger.dbg("NeoDB:", method, target)

        socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
        local code, response_headers, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        -- On a transport failure LuaSocket returns nil plus an error string, which
        -- socket.skip shifts into `code`.
        if response_headers == nil then
            -- Whatever a previous call's server detail said, it is not an
            -- explanation for this one -- and errorMessage would otherwise append
            -- it verbatim.
            self.last_detail = nil
            local reason = tostring(status or code or "unknown")
            logger.err("NeoDB: request failed:", reason)
            if reason:find(socketutil.TIMEOUT_CODE, 1, true)
                or reason:find(socketutil.SINK_TIMEOUT_CODE, 1, true) then
                return false, "timeout"
            end
            return false, "network_error"
        end

        local content = table.concat(sink)

        --[[--
        A redirect, which for us means the item was merged into another one.

        307 and 308 replay the method and body, which is what NeoDB uses for writes
        precisely so a mark is not degraded into a GET. 301/302/303 are only
        followed for reads: turning a write into a GET would silently drop it, so
        surface it instead of guessing.
        ]]
        local follow
        local redirected = code == 307 or code == 308
            or ((code == 301 or code == 302 or code == 303)
                and (method == "GET" or method == "HEAD"))
        if redirected and hops < MAX_REDIRECTS then
            local location = Api.resolveLocation(target, response_headers["location"])
            -- Never carry the token to another host.
            if location and originOf(location) == origin then follow = location end
        end

        if follow then
            hops = hops + 1
            target = follow
            self.final_url = follow
            logger.dbg("NeoDB: following redirect to", follow)
        elseif code == 200 or code == 201 or code == 202 or code == 204 then
            self.last_detail = nil
            if content == "" then return true, {}, code end
            local ok, decoded = pcall(JSON.decode, content)
            if not ok or type(decoded) ~= "table" then
                logger.err("NeoDB: unparseable response:", Util.ellipsize(content, 200))
                return false, "bad_json", code
            end
            return true, Util.scrubNulls(decoded), code
        else
            self.last_detail = Api.explainErrorBody(content)
            logger.err("NeoDB: HTTP", code, Util.ellipsize(content, 200))
            if code == 401 then return false, "unauthorized", code end
            if code == 403 then return false, "forbidden", code end
            if code == 404 then return false, "not_found", code end
            if code == 429 then return false, "rate_limited", code end
            if type(code) == "number" and code >= 500 then return false, "server_error", code end
            return false, "http_error", code
        end
    end
end

--[[--
Same as `raw`, but resolves `path` against the configured instance.

@treturn bool ok
@treturn table|string body, or the error kind
@treturn int|nil HTTP status
@treturn string|nil the path this item now lives at, when it turned out to be merged
]]
function Api:call(method, path, opts)
    local instance = self.store:getInstance()
    if not instance then return false, "no_instance" end

    local ok, data, code = self:raw(method, instance .. path, opts)

    --[[--
    NeoDB merges duplicate catalog entries, and afterwards the uuid we stored
    answers with a redirect to whichever entry survived. Comparing the uuid we asked
    about with the one we ended up at is how that becomes visible, and it costs
    nothing when nothing has moved.
    ]]
    local moved_to
    local final_path = Api.pathOf(self.final_url)
    if final_path and final_path ~= path then
        local from, to = Api.uuidFromPath(path), Api.uuidFromPath(final_path)
        if from and to and from ~= to then
            moved_to = final_path
            logger.info("NeoDB: item", from, "is merged into", to)
            -- The hook re-enters this method to refetch the survivor, so guard it.
            if self.on_item_moved and not self.following_move then
                self.following_move = true
                local hook_ok, err = pcall(self.on_item_moved, from, to)
                self.following_move = false
                if not hook_ok then logger.err("NeoDB: on_item_moved failed:", tostring(err)) end
            end
        end
    end

    return ok, data, code, moved_to
end

--[[--
Pulls a human-readable reason out of an error response body.

NeoDB answers its own refusals with `{"message": "..."}`, while django-ninja
reports schema violations as `{"detail": [{"loc": [...], "msg": "..."}]}`.
Surfacing either beats a generic failure: a validation error names the field.
]]
function Api.explainErrorBody(content)
    if type(content) ~= "string" or content == "" then return nil end
    local ok, decoded = pcall(JSON.decode, content)
    if not ok or type(decoded) ~= "table" then return nil end
    Util.scrubNulls(decoded)

    if type(decoded.message) == "string" and decoded.message ~= "" then
        return decoded.message
    end

    if type(decoded.detail) == "table" then
        local parts = {}
        for _idx, entry in ipairs(decoded.detail) do
            if type(entry) == "table" and type(entry.msg) == "string" then
                local field = type(entry.loc) == "table" and entry.loc[#entry.loc] or nil
                table.insert(parts, field and (tostring(field) .. ": " .. entry.msg) or entry.msg)
            end
        end
        if #parts > 0 then return table.concat(parts, "\n") end
        if type(decoded.detail) == "string" then return decoded.detail end
    elseif type(decoded.detail) == "string" and decoded.detail ~= "" then
        return decoded.detail
    end

    if type(decoded.error) == "string" and decoded.error ~= "" then
        return decoded.error
    end
    return nil
end

--- Base text for an error kind, with no server specifics.
function Api.describeError(err, code)
    if err == "no_instance" then return _("No NeoDB instance configured.") end
    if err == "offline" then return _("No network connection.") end
    if err == "network_error" then return _("Could not reach the NeoDB server.") end
    if err == "timeout" then return _("The NeoDB server took too long to answer.") end
    if err == "unauthorized" then return _("Your NeoDB login has expired. Please sign in again.") end
    if err == "forbidden" then return _("NeoDB refused this request. Your token may lack write access.") end
    if err == "not_found" then return _("Not found on NeoDB.") end
    if err == "rate_limited" then return _("NeoDB is rate-limiting us. Please try again in a minute.") end
    if err == "server_error" then return _("The NeoDB server reported an error.") end
    if err == "bad_json" then return _("The NeoDB server sent something unexpected.") end
    if code then return string.format(_("NeoDB request failed (HTTP %d)."), code) end
    return _("NeoDB request failed.")
end

--[[--
Reader-facing message for the request that just failed.

Appends whatever the server said about it. Without this a schema mismatch shows
up as a bare "request failed", which is almost impossible to diagnose from a
device with no console.
]]
function Api:errorMessage(err, code)
    local message = Api.describeError(err, code)
    if self.last_detail and self.last_detail ~= "" then
        message = message .. "\n\n" .. self.last_detail
    end
    return message
end

-- Account -------------------------------------------------------------------

function Api:me()
    return self:call("GET", "/api/me")
end

--- Registers this KOReader install as an OAuth app (Mastodon-compatible API).
function Api:registerApp(instance)
    return self:raw("POST", instance .. "/api/v1/apps", {
        auth = "none",
        form = {
            client_name   = Util.clientName(),
            redirect_uris = OOB_REDIRECT,
            -- Mastodon defaults to read-only when scopes are omitted, which
            -- would silently break every mark.
            scopes        = OAUTH_SCOPES,
        },
    })
end

function Api.authorizeUrl(instance, client_id)
    return instance .. "/oauth/authorize?response_type=code"
        .. "&client_id=" .. util.urlEncode(client_id)
        .. "&redirect_uri=" .. util.urlEncode(OOB_REDIRECT)
        .. "&scope=" .. util.urlEncode(OAUTH_SCOPES)
end

function Api:exchangeCode(instance, client, code)
    return self:raw("POST", instance .. "/oauth/token", {
        auth = "none",
        form = {
            client_id     = client.client_id,
            client_secret = client.client_secret,
            code          = code,
            redirect_uri  = OOB_REDIRECT,
            grant_type    = "authorization_code",
        },
    })
end

-- Catalog -------------------------------------------------------------------

function Api:searchBooks(query, page)
    return self:call("GET", "/api/catalog/search?category=book&page=" .. tostring(page or 1)
        .. "&query=" .. util.urlEncode(query), { auth = "optional" })
end

--[[--
Resolves a URL to a catalog item.

Works for NeoDB item URLs and for supported third-party sites. NeoDB answers
with a 302 to the item (which LuaSocket follows for us) or a 202 when it has
queued the page for fetching.
]]
function Api:fetchByUrl(url)
    return self:call("GET", "/api/catalog/fetch?url=" .. util.urlEncode(url),
        { auth = "optional" })
end

function Api:getBook(uuid)
    return self:call("GET", "/api/book/" .. uuid, { auth = "optional" })
end

-- Pairing portal -------------------------------------------------------------
--
-- An optional helper service (the neodb-portal project) that lets the reader
-- sign in on a phone instead of typing a server address and a long authorization
-- code on an e-ink keyboard. We open a session, show its short URL as a QR code,
-- and collect the result afterwards. The fetch token authenticates that
-- collection and never appears in the URL, so the code in the QR is not on its
-- own enough for anyone else to take the credentials.

-- `client_name` is required and is what the reader will be asked to approve on
-- their phone, so it names the device rather than this plugin where it can.
function Api:portalOpenSession(portal)
    return self:raw("POST", portal .. "/api/session", {
        auth = "none",
        form = { client_name = Util.clientName() },
    })
end

--- Answers `true, data, 202` while the reader has not finished on their phone.
function Api:portalClaim(portal, code, fetch_token)
    return self:raw("GET", portal .. "/api/session/" .. code, {
        auth = "none",
        headers = { ["Authorization"] = "Bearer " .. fetch_token },
    })
end

function Api:portalCancel(portal, code, fetch_token)
    return self:raw("DELETE", portal .. "/api/session/" .. code, {
        auth = "none",
        headers = { ["Authorization"] = "Bearer " .. fetch_token },
    })
end

-- Marks, progress, notes, reviews -------------------------------------------

--[[--
Fetches the current mark for an item.

An unmarked item answers 404, which is not an error as far as we are concerned,
so that case comes back as `true, nil`.
]]
function Api:getMark(uuid)
    local ok, data, code = self:call("GET", "/api/me/shelf/item/" .. uuid)
    if not ok and code == 404 then return true, nil end
    return ok, data, code
end

function Api:markPath(uuid)
    return "/api/me/shelf/item/" .. uuid
end

function Api:progressPath(uuid)
    return "/api/me/shelf/item/" .. uuid .. "/progress"
end

function Api:notePath(uuid)
    return "/api/me/note/item/" .. uuid .. "/"
end

--[[--
Where a post that is about nothing in particular goes.

The one endpoint here that is not NeoDB's own API. A post with no catalog item
attached is a plain fediverse status, and NeoDB has no route for one: an instance
sends `/api/v1` straight through to the Takahe it federates with, whose
`POST /api/v1/statuses` is Mastodon-compatible. Nothing extra is needed to reach
it -- that side asks for `write:statuses` and accepts the bare `write` we already
hold -- but `visibility` there is one of the strings in `Util.POST_VISIBILITIES`,
not the integer the shelf and note endpoints take.
]]
function Api:statusPath()
    return "/api/v1/statuses"
end

function Api:getProgress(uuid)
    local ok, data, code = self:call("GET", self:progressPath(uuid))
    if not ok and (code == 404 or code == 400) then return true, nil end
    return ok, data, code
end

function Api:deleteMark(uuid)
    return self:call("DELETE", self:markPath(uuid))
end

-- Write queue ---------------------------------------------------------------

--[[--
Announces that an op reached the server, and what came back.

Some ops care about the reply. A note's uuid is the only handle NeoDB gives us for
editing or deleting it later, and it does not exist until the post has gone out --
which, for something that may have waited days in the queue, is nowhere near where
the op was created. A queued op cannot carry a callback either, since the queue is
written to disk, so the plugin wires one hook here, the same way it does for
merged items.
]]
function Api:announceSent(op, data)
    if not self.on_op_sent then return end
    local ok, err = pcall(self.on_op_sent, op, data)
    if not ok then logger.err("NeoDB: on_op_sent failed:", tostring(err)) end
end

--[[--
Sends a write op, or queues it if the network is not cooperating.

@param is_online pass the already-known state to skip a second connectivity
                 check; `Util.isOnline` resolves a hostname, so callers that
                 have just checked should not make us check again
@treturn string "sent", "queued", or "failed"
@treturn table|string response body, or the error kind
]]
function Api:submit(op, is_online)
    if is_online == nil then is_online = Util.isOnline() end
    if not is_online then
        self.store:enqueue(op)
        return "queued"
    end

    local ok, data, code, moved_to = self:call(op.method, op.path, { json = op.body })
    -- The item was merged; keep the new address so a queued retry does not have to
    -- rediscover it.
    if moved_to then op.path = moved_to end
    if ok then
        self:announceSent(op, data)
        return "sent", data
    end

    -- Only queue things that might succeed later. A 403 will still be a 403.
    if data == "network_error" or data == "timeout" or data == "server_error" then
        self.store:enqueue(op)
        return "queued", data
    end
    return "failed", data, code
end

--[[--
Uploads everything that is queued.

@treturn int number sent
@treturn int number still queued
@treturn int number dropped as permanently failed
]]
function Api:flushQueue()
    local queue = self.store:getQueue()
    if #queue == 0 then return 0, 0, 0 end

    local remaining, sent, dropped = {}, 0, 0
    for _idx, op in ipairs(queue) do
        local ok, data, _code, moved_to = self:call(op.method, op.path, { json = op.body })
        -- Follow the item to wherever it was merged, so an op queued against a uuid
        -- that has since been merged away is delivered instead of discarded.
        if moved_to then op.path = moved_to end
        if ok then
            self:announceSent(op, data)
            sent = sent + 1
        elseif data == "network_error" or data == "timeout" or data == "server_error" then
            table.insert(remaining, op)
        else
            -- Keeping these forever would block the queue behind an op that can
            -- never succeed (deleted item, revoked token, item merged away).
            logger.warn("NeoDB: dropping queued op", op.label, "-", tostring(data))
            dropped = dropped + 1
        end
    end

    self.store:replaceQueue(remaining)
    return sent, #remaining, dropped
end

return Api
