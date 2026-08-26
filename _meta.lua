local _ = require("gettext")

--[[--
`version` is the released tag, and "dev" in a checkout.

The release workflow stamps the tag over the line below, in its own copy, and
fails the build if it cannot find it. So keep the line spelled exactly as it is:
a reworded one ships as "dev" and says nothing about which build it is.

KOReader reads none of this: `PluginLoader:_load` merges every key here onto the
plugin module, which the instance inherits from, and the plugin's own "About this
plugin" row is what shows it.
]]
return {
    fullname = _("NeoDB"),
    description = _([[Links the book you are reading to a NeoDB instance, so you can set its reading status and progress, and share notes, quotes, ratings and comments.]]),
    version = "dev",
}
