--[[--
Signing in to a NeoDB instance from an e-reader.

Typing on an e-ink keyboard is slow and error-prone, so the paths are ordered by
how little typing they need:

* **Pairing portal** (the default): a helper service issues a short link, we show
  it as a QR code, and the reader picks their instance and signs in on a phone.
  Nothing has to be typed here at all -- not the server address, not a code.
* **Authorize in a browser**: the same OAuth flow driven from this device, with
  the instance chosen here and the authorization code typed back by hand. No
  third party involved, at the cost of a long code on a slow keyboard.
* **Paste a token**: for readers who already made one in the instance's
  `/developer/` console.
* **Read a token from a file**: dropped onto the device over USB. No typing.

@module koplugin.neodb.login
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("neodb_api")
local Util = require("neodb_util")

--- Public instances listed in the NeoDB documentation. "Other" covers the rest.
local KNOWN_INSTANCES = {
    { host = "neodb.social",   note = _("flagship, zh/en") },
    { host = "eggplant.place", note = _("development build, en") },
    { host = "reviewdb.app",   note = _("en") },
    { host = "minreol.dk",     note = _("da") },
    { host = "db.casually.cat", note = _("en") },
    { host = "neodb.kevga.de", note = _("de") },
}

local TOKEN_FILENAME = "neodb_token.txt"

local Login = {}

--- Where we look for a token file, most convenient first.
local function tokenFilePaths()
    return {
        DataStorage:getDataDir() .. "/" .. TOKEN_FILENAME,
        DataStorage:getSettingsDir() .. "/" .. TOKEN_FILENAME,
    }
end

--[[--
Checks a token against /api/me and saves it if the server likes it.

This is the only place a token is accepted, so an instance/token mismatch is
caught before we ever try to mark a book. `grant` is the rest of what the server
sent with the token, where the sign-in route had any -- it is written only once
the token has proved good, so a rejected sign-in leaves no refresh token behind.
]]
function Login.verifyAndSave(ctx, token, grant, on_success)
    -- Store it first: the API client reads the token from the store.
    local previous = ctx.store:getToken()
    ctx.store:setToken(token)

    local done = Util.busy(_("Checking your NeoDB login…"))
    local ok, data, code = ctx.api:me()
    done()

    if not ok then
        ctx.store:setToken(previous)
        Util.alert(ctx.api:errorMessage(data, code))
        return false
    end

    ctx.store:setAccount(token, data)
    ctx.store:setGrant(grant)
    Util.alert(T(_("Signed in to NeoDB as %1."), ctx.store:getAccountLabel()))
    if on_success then on_success() end
    return true
end

-- Instance picker -----------------------------------------------------------

function Login.chooseInstance(ctx, on_done)
    local menu
    local items = {}

    for _idx, entry in ipairs(KNOWN_INSTANCES) do
        table.insert(items, {
            text = entry.host,
            mandatory = entry.note,
            callback = function()
                UIManager:close(menu)
                Login.setInstance(ctx, "https://" .. entry.host, on_done)
            end,
        })
    end
    table.insert(items, {
        text = _("Other instance…"),
        callback = function()
            UIManager:close(menu)
            Login.promptInstance(ctx, on_done)
        end,
    })

    menu = Menu:new{
        title = _("Choose your NeoDB instance"),
        subtitle = _("Your account lives on one instance; pick the one you signed up with."),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function Login.promptInstance(ctx, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("NeoDB instance"),
        description = _("Enter the address of your NeoDB server, for example neodb.social"),
        input = Util.instanceHost(ctx.store:getInstance() or ""),
        input_hint = "neodb.social",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Continue"),
                is_enter_default = true,
                callback = function()
                    local instance = Util.normalizeInstance(dialog:getInputText())
                    if not instance then
                        Util.alert(_("That does not look like a server address."))
                        return
                    end
                    UIManager:close(dialog)
                    Login.setInstance(ctx, instance, on_done)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Switching instances invalidates the old token, so drop it.
function Login.setInstance(ctx, instance, on_done)
    if ctx.store:getInstance() ~= instance then
        ctx.store:logout()
        ctx.store:setInstance(instance)
    end
    Login.manualMethods(ctx, on_done)
end

-- Method picker -------------------------------------------------------------

--- Top-level picker. The portal path needs no instance chosen up front.
function Login.chooseMethod(ctx, on_done)
    local portal = ctx.store:get("portal_url")
    local dialog
    local buttons = {}

    -- Only offered when a pairing service is configured; clearing the setting
    -- takes the third party out of the picture entirely.
    if portal and portal ~= "" then
        table.insert(buttons, {{
            text = _("Scan a QR code (easiest)"),
            callback = function()
                UIManager:close(dialog)
                Login.portalFlow(ctx, on_done)
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Enter a server address myself"),
        callback = function()
            UIManager:close(dialog)
            Login.manualMethods(ctx, on_done)
        end,
    }})
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})

    dialog = ButtonDialog:new{
        title = _("Sign in to NeoDB\n\nHow would you like to do it?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The paths that need the reader to name their instance on this device.
function Login.manualMethods(ctx, on_done)
    local instance = ctx.store:getInstance()
    if not instance then
        return Login.chooseInstance(ctx, on_done)
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Sign in to %1\n\nHow would you like to do it?"), Util.instanceHost(instance)),
        title_align = "center",
        buttons = {
            {{
                text = _("Authorize in a browser"),
                callback = function()
                    UIManager:close(dialog)
                    Login.oauthFlow(ctx, on_done)
                end,
            }},
            {{
                text = _("Type an access token"),
                callback = function()
                    UIManager:close(dialog)
                    Login.promptToken(ctx, on_done)
                end,
            }},
            {{
                text = _("Read a token from a file"),
                callback = function()
                    UIManager:close(dialog)
                    Login.importTokenFile(ctx, on_done)
                end,
            }},
            {{
                text = _("Use a different instance"),
                callback = function()
                    UIManager:close(dialog)
                    Login.chooseInstance(ctx, on_done)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Pairing portal -------------------------------------------------------------

--[[--
Signs in by way of a helper service, so nothing has to be typed on the device.

The portal issues a short-lived code, we show its join URL as a QR code, and the
reader picks their instance and signs in on a phone. The credentials come back
here when they tap Done.

The join URL is deliberately short — around thirty characters — so it survives
being read off the screen and typed by hand when a camera will not focus.
]]
function Login.portalFlow(ctx, on_done)
    local portal = ctx.store:get("portal_url")
    if not portal or portal == "" then
        Util.alert(_("No pairing service is configured."))
        return
    end

    Util.whenOnline(function()
        local done = Util.busy(_("Starting sign-in…"))
        local ok, session, code = ctx.api:portalOpenSession(portal)
        done()

        -- The join URL comes from the portal rather than being derived here: only
        -- the portal knows where it serves its own pairing pages. A session
        -- without one is unusable, so fail here rather than show a dead link.
        if not ok or not session.code or not session.fetch_token or not session.join_url then
            Util.alert(T(_("Could not start sign-in with %1.\n\n%2"),
                Util.instanceHost(portal), ctx.api:errorMessage(session, code)))
            return
        end
        Login.showPairing(ctx, portal, session, on_done)
    end)
end

function Login.showPairing(ctx, portal, session, on_done)
    local join_url = session.join_url

    local dialog
    local function finish()
        UIManager:close(dialog)
        if on_done then on_done() end
    end

    local buttons = {}

    if Util.hasQRCode() then
        table.insert(buttons, {{
            text = _("Show QR code"),
            callback = function() Util.showQRCode(join_url) end,
        }})
    end

    table.insert(buttons, {{
        text = _("Done — I've signed in"),
        callback = function()
            Login.claimPairing(ctx, portal, session, finish)
        end,
    }})

    if Device:hasClipboard() then
        table.insert(buttons, {{
            text = _("Copy link to clipboard"),
            callback = function()
                Util.copyToClipboard(join_url)
                Util.notify(_("Link copied."))
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
            -- Best effort: tell the portal to forget a session we abandoned,
            -- rather than leaving a credential slot open until it expires.
            if Util.isOnline() then
                ctx.api:portalCancel(portal, session.code, session.fetch_token)
            end
        end,
    }})

    dialog = ButtonDialog:new{
        title = T(_([[Scan this with your phone, or open:

%1

Choose your NeoDB server and sign in there, then come back and tap Done.]]),
            join_url),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)

    -- Straight to the code: that is what the reader came here for.
    if Util.hasQRCode() then Util.showQRCode(join_url) end
end

--- Collects the result of a finished pairing, or explains why there isn't one.
function Login.claimPairing(ctx, portal, session, on_done)
    Util.whenOnline(function()
        local done = Util.busy(_("Collecting your sign-in…"))
        local ok, data, code = ctx.api:portalClaim(portal, session.code, session.fetch_token)
        done()

        if ok and code == 202 then
            Util.alert(_("That sign-in hasn't finished yet.\n\nFinish on your phone, then tap Done again."))
            return
        end

        if not ok then
            if code == 404 then
                Util.alert(_("This sign-in link has expired or was already used.\n\nStart again to get a fresh one."))
            else
                Util.alert(ctx.api:errorMessage(data, code))
            end
            return
        end

        if not data.access_token or not data.instance then
            Util.alert(_("The pairing service did not return a usable sign-in."))
            return
        end

        -- The instance was chosen on the phone, so adopt it before checking the
        -- token: everything else reads the server address from the store.
        if ctx.store:getInstance() ~= data.instance then
            ctx.store:logout()
            ctx.store:setInstance(data.instance)
        end

        -- The portal registered the app on our behalf and hands the credentials
        -- over with the token, so keep them: without this, signing in directly
        -- against the same server later would register a second app for the
        -- same device.
        if data.client_id and data.client_secret then
            ctx.store:setClient(data.instance, data.client_id, data.client_secret)
        end

        Login.verifyAndSave(ctx, data.access_token, {
            refresh_token = data.refresh_token,
            token_type    = data.token_type,
            scope         = data.scope,
            -- The portal names this one for the token's own lifetime, to keep it
            -- apart from the pairing session's `expires_in`.
            expires_in    = data.token_expires_in,
        }, on_done)
    end)
end

-- OAuth --------------------------------------------------------------------

function Login.oauthFlow(ctx, on_done)
    local instance = ctx.store:getInstance()

    Util.whenOnline(function()
        local client = ctx.store:getClient(instance)
        if not client then
            local done = Util.busy(_("Registering KOReader with the server…"))
            local ok, data, code = ctx.api:registerApp(instance)
            done()
            if not ok or not data.client_id then
                Util.alert(T(_("Could not register with %1.\n\n%2"),
                    Util.instanceHost(instance), ctx.api:errorMessage(data, code)))
                return
            end
            ctx.store:setClient(instance, data.client_id, data.client_secret)
            client = ctx.store:getClient(instance)
        end

        Login.showAuthorizePrompt(ctx, instance, client, on_done)
    end)
end

function Login.showAuthorizePrompt(ctx, instance, client, on_done)
    local url = Api.authorizeUrl(instance, client.client_id)

    local dialog
    local buttons = {
        {{
            text = _("Show the link as text"),
            callback = function()
                UIManager:show(TextViewer:new{
                    title = _("Authorization link"),
                    text = url,
                    text_type = "code",
                })
            end,
        }},
        {{
            text = _("I have the code"),
            callback = function()
                UIManager:close(dialog)
                Login.promptCode(ctx, instance, client, on_done)
            end,
        }},
        {{
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        }},
    }

    if Device:hasClipboard() then
        table.insert(buttons, 2, {{
            text = _("Copy link to clipboard"),
            callback = function()
                Util.copyToClipboard(url)
                Util.notify(_("Link copied."))
            end,
        }})
    end

    if Util.hasQRCode() then
        -- By far the easiest route on an e-reader: scan it with a phone and
        -- approve there, instead of typing a long URL on a slow keyboard.
        table.insert(buttons, 1, {{
            text = _("Show QR code"),
            callback = function() Util.showQRCode(url) end,
        }})
    end

    dialog = ButtonDialog:new{
        title = _([[Open the authorization page on your phone or computer, sign in, and approve access.

NeoDB will then show you a short code. Come back here and tap "I have the code".]]),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Login.promptCode(ctx, instance, client, on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Authorization code"),
        description = _("Type the code NeoDB showed you after you approved access."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Sign in"),
                is_enter_default = true,
                callback = function()
                    local code = Util.trim(dialog:getInputText())
                    if code == "" then return end
                    UIManager:close(dialog)
                    Login.exchange(ctx, instance, client, code, on_done)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Login.exchange(ctx, instance, client, code, on_done)
    Util.whenOnline(function()
        local done = Util.busy(_("Signing in…"))
        local ok, data, http_code = ctx.api:exchangeCode(instance, client, code)
        done()

        if not ok or not data.access_token then
            local hint = _("Could not sign in with that code. Codes expire quickly — try requesting a new one.")
            if ok and not data.access_token then
                Util.alert(hint)
            else
                Util.alert(ctx.api:errorMessage(data, http_code) .. "\n\n" .. hint)
            end
            return
        end
        Login.verifyAndSave(ctx, data.access_token, {
            refresh_token = data.refresh_token,
            token_type    = data.token_type,
            scope         = data.scope,
            expires_in    = data.expires_in,
        }, on_done)
    end)
end

-- Token entry ---------------------------------------------------------------

function Login.promptToken(ctx, on_done)
    local instance = ctx.store:getInstance()
    local dialog
    dialog = InputDialog:new{
        title = _("NeoDB access token"),
        description = T(_("Create a token at %1/developer/ and type it here."),
            Util.instanceHost(instance or "")),
        input_hint = _("Access token"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Sign in"),
                is_enter_default = true,
                callback = function()
                    local token = Util.trim(dialog:getInputText())
                    if token == "" then return end
                    UIManager:close(dialog)
                    Util.whenOnline(function()
                        Login.verifyAndSave(ctx, token, nil, on_done)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
Reads a token from a plain text file placed on the device.

The least painful option when a QR code is not practical: create the token on a
computer, save it to a file, and copy it over by USB.
]]
function Login.importTokenFile(ctx, on_done)
    local paths = tokenFilePaths()

    for _idx, path in ipairs(paths) do
        local handle = io.open(path, "r")
        if handle then
            local content = handle:read("*a") or ""
            handle:close()
            -- Take the first non-empty line, so a file with a trailing newline
            -- or an explanatory comment underneath still works.
            local token
            for line in content:gmatch("[^\r\n]+") do
                local candidate = Util.trim(line)
                if candidate ~= "" and not candidate:match("^#") then
                    token = candidate
                    break
                end
            end
            if token then
                logger.dbg("NeoDB: read token from", path)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Use the token found in\n%1?"), path),
                    ok_text = _("Sign in"),
                    ok_callback = function()
                        Util.whenOnline(function()
                            Login.verifyAndSave(ctx, token, nil, on_done)
                        end)
                    end,
                })
                return
            end
        end
    end

    Util.alert(T(_([[No token file found.

Create an access token at %1/developer/, save it as a text file named %2, and copy it to either of these locations:

%3

Then try again.]]),
        Util.instanceHost(ctx.store:getInstance() or "your-instance"),
        TOKEN_FILENAME,
        table.concat(paths, "\n")))
end

-- Account screen ------------------------------------------------------------

--- Entry point from the menu: account details when signed in, setup when not.
function Login.show(ctx, on_change)
    if not ctx.store:isLoggedIn() then
        return Login.chooseMethod(ctx, on_change)
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Signed in as %1"), ctx.store:getAccountLabel()),
        title_align = "center",
        buttons = {
            {{
                text = _("Check connection"),
                callback = function()
                    UIManager:close(dialog)
                    Util.whenOnline(function()
                        local done = Util.busy(_("Contacting NeoDB…"))
                        local ok, data, code = ctx.api:me()
                        done()
                        if ok then
                            Util.alert(T(_("Connected to %1 as %2."),
                                Util.instanceHost(ctx.store:getInstance()),
                                data.display_name or data.username or "?"))
                        else
                            Util.alert(ctx.api:errorMessage(data, code))
                        end
                    end)
                end,
            }},
            {{
                text = _("Sign in again"),
                callback = function()
                    UIManager:close(dialog)
                    Login.chooseMethod(ctx, on_change)
                end,
            }},
            {{
                text = _("Sign out"),
                callback = function()
                    UIManager:close(dialog)
                    local pending = ctx.store:queueCount()
                    local text = pending > 0
                        and T(_("Sign out of NeoDB?\n\n%1 pending upload(s) will be discarded."), pending)
                        or _("Sign out of NeoDB?")
                    UIManager:show(ConfirmBox:new{
                        text = text,
                        ok_text = _("Sign out"),
                        ok_callback = function()
                            ctx.store:logout()
                            ctx.store:clearQueue()
                            Util.notify(_("Signed out of NeoDB."))
                            if on_change then on_change() end
                        end,
                    })
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

return Login
