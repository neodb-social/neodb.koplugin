-- Plugin-local translations. Do not load our strings into KOReader's global
-- gettext table: common labels must not change in other plugins or the reader.
local gettext = require("gettext")
local zh_CN = require("neodb_zh_cn")

return setmetatable({}, {
    __call = function(_, message)
        local language = (gettext.current_lang or "C"):lower():gsub("-", "_")
        if language == "zh" or language:match("^zh_cn")
                or language:match("^zh_sg") or language:match("^zh_hans") then
            return zh_CN[message] or gettext(message)
        end
        -- English strings are the source. Other languages can still use any
        -- matching translations already provided by KOReader.
        return gettext(message)
    end,
})
