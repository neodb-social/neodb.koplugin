-- A title and a long note in one composer. MultiInputDialog handles focus and
-- keyboards, but its fields grow to their initial text height. Bound the title
-- to one line and give the scrollable body the remaining screen space instead.
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local _ = require("neodb_i18n")
local logger = require("logger")

local NoteDialog = MultiInputDialog:extend{
    focused_field_idx = 2,
}

function NoteDialog:init()
    if self._fallback then return InputDialog.init(self) end
    self.fields = self.fields or {
        { text = self.note_title or "", hint = _("Title (optional)") },
        { text = self.note_text or "", hint = self.note_hint or _("Note text"), allow_newline = true },
    }
    self._building_fields = true
    MultiInputDialog.init(self)
    self._building_fields = false
    -- MultiInputDialog replaces the frame built by InputDialog. Reattach its
    -- native movable wrapper to the new frame so header dragging still works.
    if self.is_movable then
        self.movable[1] = self.dialog_frame
        self[1][1] = self.movable
    end
    -- Enter in the title moves to the body; it never submits the post.
    self.input_fields[1].enter_callback = function()
        self:onSwitchFocus(self.input_fields[2])
    end
    self:resizeFields()
end

function NoteDialog:getNoteTitle()
    if self._fallback then return self.note_title end
    return (self.input_fields[1]:getText():gsub("[\r\n]+", " "))
end

function NoteDialog:getNoteText()
    if self._fallback then return self:getInputText() end
    return self.input_fields[2]:getText()
end

function NoteDialog:setNoteText(text)
    if self._fallback then return self:setInputText(text) end
    local body = self.input_fields[2]
    body.charpos = nil
    body.top_line_num = nil
    body.cursor_at_end = true
    body:setText(text)
    UIManager:setDirty(self, "ui")
end

-- Tested with KOReader v2026.07.1. The layout optimization uses internal
-- widgets; if their contract changes, retain drafts in a standard InputDialog.
function NoteDialog:resizeFields()
    if self._fallback or self._building_fields or self._switching_focus then return end
    local ok, err = pcall(self.resizeFieldsUnsafe, self)
    if not ok then
        logger.warn("NeoDB: falling back to standard note editor:", tostring(err))
        self:useStandardEditor()
    end
end

function NoteDialog:useStandardEditor()
    local title, body = self:getNoteTitle(), self:getNoteText()
    self._fallback = true
    for _idx, field in ipairs(self.input_fields) do
        -- Freeing a keyboard does not remove its window from UIManager.
        field:onCloseKeyboard()
        field:onCloseWidget()
    end
    self:free()
    self.input_fields = nil
    -- Let InputText use its standard focus and keyboard policy in this mode.
    self.onSwitchFocus = false
    self.note_title, self.input = title, body
    self.allow_newline, self.use_available_height = true, true
    self.input_hint = self.note_hint
    table.insert(self.buttons, #self.buttons, {{
        text = _("Edit title"),
        id = "edit_title",
        callback = function()
            self:onCloseKeyboard()
            local editor
            editor = InputDialog:new{
                title = _("Title (optional)"), input = self.note_title,
                buttons = {{
                    { text = _("Cancel"), callback = function() UIManager:close(editor) end },
                    { text = _("Save"), callback = function()
                        self.note_title = editor:getInputText():gsub("[\r\n]+", " ")
                        UIManager:close(editor)
                    end },
                }},
            }
            UIManager:show(editor)
            editor:onShowKeyboard()
        end,
    }})
    self._buttons_backup_done, self._buttons_backup = false, nil
    InputDialog.init(self)
    -- A one-time fallback can shrink the frame; repaint the exposed reader.
    UIManager:setDirty("all", "ui")
end

function NoteDialog:resizeFieldsUnsafe()
    local group = self.dialog_frame[1]
    local title, body = self.input_fields[1], self.input_fields[2]
    local rows = {}
    for _, row in ipairs(group) do
        if row[1] == title or row[1] == body then rows[row[1]] = row end
    end
    assert(rows[title] and rows[body], "unknown multi-input layout")
    for _idx, field in ipairs({ title, body }) do
        assert(type(field.resyncPos) == "function" and type(field.initTextBox) == "function"
            and type(field.initEventListener) == "function", "unknown input widget API")
    end
    local changed = false
    local function resize(field, height)
        if field.height ~= height then
            changed = true
            field:resyncPos()
            field.height = height
            field.scroll = true
            field:initTextBox()
            field:initEventListener()
        end
        rows[field].dimen.h = field:getSize().h
    end
    resize(title, title:getLineHeight())
    group:resetLayout()
    local keyboard_height = self.keyboard_visible and self._input_widget:getKeyboardDimen().h or 0
    local available = Device.screen:getHeight() - keyboard_height
    local overhead = self.dialog_frame:getSize().h - body.height
    local line_height = body:getLineHeight()
    resize(body, math.max(line_height, math.floor((available - overhead) / line_height) * line_height))
    group:resetLayout()
    if self[1].dimen.h ~= available then changed = true end
    self[1].dimen.h = available
    if changed then
        -- Both containers cache their size after painting. Keep their hit and
        -- drag bounds in sync when the keyboard changes the body's height.
        local size = self.dialog_frame:getSize()
        if self.dialog_frame.dimen then
            self.dialog_frame.dimen.w, self.dialog_frame.dimen.h = size.w, size.h
        end
        if self.movable and self.movable.dimen then
            self.movable.dimen.w, self.movable.dimen.h = size.w, size.h
        end
        UIManager:setDirty(self, "ui")
    end
end

function NoteDialog:onShowKeyboard(...)
    InputDialog.onShowKeyboard(self, ...)
    self:resizeFields()
end

function NoteDialog:onCloseKeyboard()
    InputDialog.onCloseKeyboard(self)
    self:resizeFields()
end

function NoteDialog:onSwitchFocus(field)
    if field == self._input_widget then
        -- Match InputText's normal tap behavior without rebuilding the field
        -- (which would reset its cursor/scroll position).
        if not ((Device:hasKeyboard() or Device:hasScreenKB())
            and G_reader_settings:nilOrFalse("virtual_keyboard_enabled")) then
            self:onShowKeyboard()
        end
        Device:startTextInput()
        field.focused = true
        return
    end
    self._switching_focus = true
    MultiInputDialog.onSwitchFocus(self, field)
    self._switching_focus = false
    self:resizeFields()
end

function NoteDialog:onKeyboardHeightChanged()
    if self._fallback then return InputDialog.onKeyboardHeightChanged(self) end
    return MultiInputDialog.onKeyboardHeightChanged(self)
end

return NoteDialog
