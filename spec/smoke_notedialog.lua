-- Optional smoke test with real KOReader widgets; see dev_notes.md. No network requests.
require("setupkoenv")
local plugin_dir = assert(os.getenv("NEODB_PLUGIN_DIR"), "Set NEODB_PLUGIN_DIR to the checkout")
assert(os.getenv("KO_HOME") == os.getenv("NEODB_UI_TEST_DIR"), "Use an isolated NEODB_UI_TEST_DIR as KO_HOME")
package.path = plugin_dir .. "/?.lua;" .. package.path
local language = os.getenv("NEODB_UI_LANGUAGE") or "C"
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", language)
G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
require("gettext").changeLang(language)
require("ui/bidi").setup(language)
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local Actions = require("neodb_actions")
local Store = require("neodb_store")
local Util = require("neodb_util")
local tr = require("neodb_i18n")
local store = Store:new()
store:setInstance("https://example.org")
store:setToken("preview-only")
local settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/book.lua")
store:setLink(settings, { uuid = "preview", title = "Dune" })
local ui = {
    doc_settings = settings,
    document = { file = "preview.epub", getPageCount = function() return 100 end },
    getCurrentPage = function() return 48 end,
    toc = { getTocTitleByPage = function() return "Chapter One" end },
}
store:set("note_title_style", "none")
store:set("quote_intro_style", "none")
store:set("selection_crosspost", false)
store:set("quote_position", "after")
store:set("note_attach_progress", true)
store:set("note_save_local", true)
local NoteDialog = require("neodb_notedialog")
local function open()
    Actions.addNote({store = store, ui = ui}, {quote = "Selected passage", note = "Original note", save_note = function() error("No submit") end})
    for _, window in ipairs(UIManager._window_stack) do
        if window.widget.title == tr("Add note & share") then return window.widget end
    end
    error("Missing composer")
end
local background = require("ui/widget/container/widgetcontainer"):new{}
function background:paintTo(bb) bb:fill(require("ffi/blitbuffer").COLOR_WHITE) end
UIManager:show(background)
local Geom = require("ui/geometry")
local Event = require("ui/event")
local function tapField(field)
    UIManager:_repaint()
    local bounds = field._frame_textwidget.dimen
    field:onTapTextBox(nil, { pos = Geom:new{x = bounds.x + 10, y = bounds.y + 10} })
end
local function checkDrag(dialog)
    UIManager:_repaint()
    local frame = dialog.dialog_frame.dimen
    local x, y = frame.x, frame.y
    local start = Geom:new{x = x + frame.w / 2, y = y + 10}
    dialog:handleEvent(Event:new("Gesture", {ges = "touch", pos = start}))
    dialog:handleEvent(Event:new("Gesture", {
        ges = "pan", pos = start, relative = {x = 12, y = 8},
    }))
    dialog:handleEvent(Event:new("Gesture", {ges = "pan_release", pos = start}))
    UIManager:_repaint()
    assert(dialog.dialog_frame.dimen.x == x + 12 and dialog.dialog_frame.dimen.y == y + 8,
        "Dragging the header must move the visible composer")
    assert(dialog.movable.dimen.h == dialog.dialog_frame.dimen.h,
        "Drag bounds must match the current frame: " .. dialog.movable.dimen.h .. " / " .. dialog.dialog_frame.dimen.h)
end
local dialog = open()
checkDrag(dialog)
assert(dialog:getNoteTitle() == "")
assert(dialog.button_table:getButtonById("fediverse").text == tr("Crosspost: off"))
dialog.input_fields[1]:setText("My title")
dialog.input_fields[2]:setText("Long draft\n" .. string.rep("A passage to keep.\n", 40))
local body = dialog:getNoteText()
dialog:onSwitchFocus(dialog.input_fields[1])
dialog:onSwitchFocus(dialog.input_fields[2])
dialog:onCloseKeyboard()
dialog:onShowKeyboard()
assert(dialog:getNoteTitle() == "My title" and dialog:getNoteText() == body)
UIManager:_repaint()
Device.screen.bb:writePNG(os.getenv("KO_HOME") .. "/review-normal.png")
local dirty, all_count = UIManager.setDirty, 0
UIManager.setDirty = function(self, widget, ...)
    if widget == "all" then all_count = all_count + 1 end
    return dirty(self, widget, ...)
end
dialog:resizeFields()
assert(all_count == 0, "unchanged layout must not dirty all widgets")
UIManager.setDirty = dirty
-- Simulate KOReader changing an internal API while editing.
dialog.resizeFieldsUnsafe = function() error("simulated incompatible widget API") end
dialog:resizeFields()
assert(dialog._fallback)
checkDrag(dialog)
assert(dialog:getNoteTitle() == "My title" and dialog:getNoteText() == body)
dialog:setNoteText("Fallback edited body")
assert(dialog:getNoteText() == "Fallback edited body")
dialog:onShowKeyboard()
UIManager:_repaint()
Device.screen.bb:writePNG(os.getenv("KO_HOME") .. "/review-fallback.png")
dialog:onKeyboardHeightChanged()
assert(dialog:getNoteTitle() == "My title" and dialog:getNoteText() == "Fallback edited body")
dialog.button_table:getButtonById("quote_position").callback()
assert(dialog.button_table:getButtonById("quote_position").text == tr("Quote: above note"))
dialog.button_table:getButtonById("edit_title").callback()
local title_editor
for _, window in ipairs(UIManager._window_stack) do
    if window.widget.title == tr("Title (optional)") then title_editor = window.widget end
end
assert(title_editor)
title_editor:setInputText("Fallback title")
title_editor.buttons[1][2].callback()
assert(dialog:getNoteTitle() == "Fallback title")
UIManager:close(dialog)
assert(#UIManager._window_stack == 1 and UIManager._window_stack[1].widget == background,
    "Closing composer must not leave an orphan keyboard")
-- Also exercise incompatibility on the first initialization.
local resize = NoteDialog.resizeFieldsUnsafe
NoteDialog.resizeFieldsUnsafe = function() error("simulated missing layout") end
dialog = open()
assert(dialog._fallback and dialog:getNoteText() == "Original note")
UIManager:close(dialog)
assert(#UIManager._window_stack == 1 and UIManager._window_stack[1].widget == background,
    "Closing composer must not leave an orphan keyboard")
NoteDialog.resizeFieldsUnsafe = resize
-- Physical-keyboard users may disable the virtual keyboard. Tapping either
-- field must honor that choice; touch-only devices must still allow typing.
local has_keyboard, has_screen_keyboard = Device.hasKeyboard, Device.hasScreenKB
for _, mode in ipairs({
    { physical = true, enabled = false, visible = false },
    { physical = true, enabled = true, visible = true },
    { physical = false, enabled = false, visible = true },
}) do
    Device.hasKeyboard = function() return mode.physical end
    Device.hasScreenKB = function() return false end
    G_reader_settings:saveSetting("virtual_keyboard_enabled", mode.enabled)
    dialog = open()
    assert(dialog:isKeyboardVisible() == mode.visible)
    for _, index in ipairs({2, 2, 1, 1, 2}) do
        dialog:onCloseKeyboard()
        tapField(dialog.input_fields[index])
        assert(dialog._input_widget == dialog.input_fields[index])
        assert(dialog:isKeyboardVisible() == mode.visible,
            "Tapping a field must honor the native keyboard preference")
    end
    local field = dialog._input_widget
    local charpos, top = field.charpos, field.top_line_num
    dialog:onSwitchFocus(field)
    assert(field.charpos == charpos and field.top_line_num == top,
        "Refocusing the active field must preserve cursor and scroll")
    field:onTextInput(" typed")
    assert(dialog:getNoteText():find(" typed", 1, true), "Text input must remain active")
    checkDrag(dialog)
    dialog.resizeFieldsUnsafe = function() error("simulated fallback for keyboard policy") end
    dialog:resizeFields()
    dialog:onCloseKeyboard()
    tapField(dialog._input_widget)
    assert(dialog:isKeyboardVisible() == mode.visible,
        "Fallback editor must honor the native keyboard preference")
    checkDrag(dialog)
    UIManager:close(dialog)
    assert(#UIManager._window_stack == 1, "Closing must not leave any keyboard")
end
Device.hasKeyboard, Device.hasScreenKB = has_keyboard, has_screen_keyboard
print("Review UI, keyboard preference, dragging and fallback checks passed: " .. language)
