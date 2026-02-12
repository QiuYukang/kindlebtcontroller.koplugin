--[[
Custom gettext for kindlebtcontroller.koplugin

Based on KOReader's gettext implementation.
Default language is Chinese; translations are loaded from l10n/ directory.
When KOReader's UI language matches a translation file (e.g., en), the
translated strings are used; otherwise the original Chinese strings are shown.
]]

local logger = require("logger")
local DataStorage = require("datastorage")

local GetText = {
    translation = {},
    loaded_lang = nil,  -- tracks which language we loaded
}

local GetText_mt = {}

-- Forward declaration
local doInitTranslation

function GetText_mt.__call(_, msgid)
    -- Check if KOReader's language setting has changed since we last loaded
    local current_lang
    if G_reader_settings then
        current_lang = G_reader_settings:readSetting("language")
    end
    -- current_lang may be nil (English default) — that's fine, we compare with loaded_lang
    if current_lang ~= GetText.loaded_lang then
        doInitTranslation()
    end
    return GetText.translation[msgid] or msgid
end

local function c_escape(what_full, what)
    if what == "\n" then return ""
    elseif what == "n" then return "\n"
    elseif what == "t" then return "\t"
    elseif what == "r" then return "\r"
    else return what_full
    end
end

local function loadPoFile(filepath)
    local po = io.open(filepath, "r")
    if not po then
        logger.dbg("BT Plugin i18n: cannot open translation file:", filepath)
        return false
    end

    local data = {}
    local what = nil
    while true do
        local line = po:read("*l")
        if line == nil or line == "" then
            if data.msgid and data.msgid ~= "" and data.msgstr and data.msgstr ~= "" then
                local unescaped = string.gsub(data.msgstr, "(\\(.))", c_escape)
                GetText.translation[data.msgid] = unescaped
            end
            if line == nil then break end
            data = {}
            what = nil
        else
            if not line:match("^#") then
                local w, s = line:match("^%s*(%a+)%s+\"(.*)\"%s*$")
                if w then
                    what = w
                else
                    s = line:match("^%s*\"(.*)\"%s*$")
                end
                if what and s then
                    s = s:gsub("\\n", "\n")
                    s = s:gsub('\\"', '"')
                    s = s:gsub("\\\\", "\\")
                    data[what] = (data[what] or "") .. s
                end
            end
        end
    end
    po:close()
    logger.info("BT Plugin i18n: loaded translation file:", filepath)
    return true
end

-- Resolve plugin directory from this file's own path
local function getPluginDir()
    local info = debug.getinfo(1, "S")
    local script_path = info and info.source
    if script_path and script_path:sub(1, 1) == "@" then
        script_path = script_path:sub(2)
    end
    if script_path then
        return script_path:match("(.*/)")
    end
    -- Fallback: try DataStorage
    return DataStorage:getDataDir() .. "/plugins/kindlebtcontroller.koplugin/"
end

local PLUGIN_DIR = getPluginDir()

doInitTranslation = function()
    GetText.translation = {}

    -- G_reader_settings stores the actual user-selected language.
    -- For English users, this is nil (English is KOReader's default).
    -- gettext.current_lang stays "C" for English.
    local lang_setting
    if G_reader_settings then
        lang_setting = G_reader_settings:readSetting("language")
    end
    GetText.loaded_lang = lang_setting  -- may be nil for English
    logger.info("BT Plugin i18n: G_reader_settings language =", tostring(lang_setting))

    -- Our default is Chinese, so only skip translation for Chinese users
    if lang_setting and lang_setting:match("^zh") then
        logger.info("BT Plugin i18n: Chinese detected, using default strings")
        return
    end

    -- For all non-Chinese languages (including English/nil/C), load translation
    local lang
    if lang_setting and lang_setting ~= "" and lang_setting ~= "C" then
        -- Strip encoding suffix (e.g., "fr_FR.utf8" -> "fr_FR")
        lang = lang_setting:gsub("%..*", "")
    else
        -- nil, "", or "C" means English (KOReader default)
        lang = "en"
    end

    local po_file = PLUGIN_DIR .. "l10n/" .. lang .. "/kindlebtcontroller.po"
    logger.info("BT Plugin i18n: trying translation file:", po_file)

    if not loadPoFile(po_file) then
        -- Try base language (e.g., "en_US" -> "en")
        local base_lang = lang:match("^(%a+)_")
        if base_lang then
            po_file = PLUGIN_DIR .. "l10n/" .. base_lang .. "/kindlebtcontroller.po"
            logger.info("BT Plugin i18n: trying base language file:", po_file)
            loadPoFile(po_file)
        end
    end
end

setmetatable(GetText, GetText_mt)
return GetText
