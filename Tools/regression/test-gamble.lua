-- Offline checks for Gamble's session flow, roll tracking, tie-breaks and Deathroll.
local checks = 0
local function check(label, value) assert(value, label); checks = checks + 1 end

local state = { settings = { enabled = true, gamble = false, gambleChannel = "PARTY", gamblePool = 200,
    gambleMode = "classic", gambleJoinWord = "join", gambleLeaveWord = "leave",
    gambleSessionStats = true, gambleLifetimeStats = true }, account = {}, buttons = {}, chats = {}, addons = {},
    prints = {}, frames = {}, listeners = {}, editboxes = {}, fonts = {}, inRaid = false }

local widgetMethods = {}
function widgetMethods:SetText(text) self.text = text end
function widgetMethods:GetText() return self.text or "" end
function widgetMethods:SetScript(key, callback)
    self.scripts[key] = callback
    if key == "OnEvent" then state.events = self end
end
function widgetMethods:HookScript(key, callback)
    self.hooks[key] = self.hooks[key] or {}
    self.hooks[key][#self.hooks[key] + 1] = callback
end
function widgetMethods:Show()
    if self.shown then return end
    self.shown = true
    for _, callback in ipairs(self.hooks.OnShow or {}) do callback(self) end
end
function widgetMethods:Hide()
    if not self.shown then return end
    self.shown = false
    for _, callback in ipairs(self.hooks.OnHide or {}) do callback(self) end
end
function widgetMethods:IsShown() return self.shown end
function widgetMethods:SetEnabled(enabled) self.enabled = enabled end
function widgetMethods:Click()
    if self.enabled == false then return end
    if self.onClick then self.onClick(self) end
end
function widgetMethods:RegisterEvent(event) self.events[event] = true end
function widgetMethods:UnregisterAllEvents() self.events = {} end
function widgetMethods:ClearFocus() self.focused = false end
function widgetMethods:HasFocus() return self.focused == true end
function widgetMethods:SetPoint() end
function widgetMethods:SetSize() end
function widgetMethods:SetHeight() end
function widgetMethods:SetNumeric() end
function widgetMethods:SetScale() end
function widgetMethods:SetJustifyH() end
function widgetMethods:SetJustifyV() end
function widgetMethods:SetPoint() end
function widgetMethods:SetWidth() end
function widgetMethods:SetMovable() end
function widgetMethods:SetFrameStrata() end
function widgetMethods:SetToplevel() end
function widgetMethods:SetClampedToScreen() end
function widgetMethods:EnableMouse() end
function widgetMethods:RegisterForDrag() end

local function widget()
    local item = { scripts = {}, hooks = {}, events = {}, shown = false }
    return setmetatable(item, { __index = function(_, key)
        return widgetMethods[key] or function() end
    end })
end

local parts = {}
function parts.Window()
    local frame = widget()
    frame.backdrop = widget()
    state.window = frame
    return frame
end
function parts.TitleBar(_, _, _, _, onClose)
    local close = widget()
    close.text = "X"
    close.onClick = function() state.window:Hide(); if onClose then onClose() end end
    state.buttons[#state.buttons + 1] = close
    return close
end
function parts.FooterBrand() end
function parts.SidePanel(actions, buildView)
    local panel = widget()
    panel.title = widget()
    panel.actions = actions
    panel.view = buildView(widget())
    state.options = panel
    return panel
end
function parts.ShowBeside(panel) panel:Show() end

local S = {}
function S.Get(key) return state.settings[key] end
function S.Set(key, value)
    state.settings[key] = value
    for _, listener in ipairs(state.listeners) do listener(key, value) end
end
function S.OnChange(listener)
    state.listeners = state.listeners or {}
    state.listeners[#state.listeners + 1] = listener
end

local ns = {
    QoLSettings = S,
    THEME = { muted = {}, accent = {} },
    Shared = { Parts = parts, Style = { WINDOW_PAD = 12, WINDOW_HEADER = 52, WINDOW_FOOTER = 28 },
        Settings = { Page = function() return { Card = function(_, spec) state.card = spec end } end } },
    UI = {},
}
function ns.Font()
    local font = widget()
    state.fonts[#state.fonts + 1] = font
    return font
end
function ns.NewEditBox()
    local box = widget()
    state.editboxes[#state.editboxes + 1] = box
    return box
end
function ns.Button(_, text, _, _, onClick)
    local button = widget()
    button.text, button.onClick = text, onClick
    state.buttons[#state.buttons + 1] = button
    return button
end
function ns.SetButtonText(button, text) button.text = text end
function ns.AccentBorder(button) return button end
function ns.UIScale() return 1 end
function ns.Print(text) state.prints[#state.prints + 1] = text end
function ns.AccountSettings() return state.account end
function ns.Confirm(text, accept) state.confirm = { text = text, accept = accept } end

local env = setmetatable({
    _G = { NaowhForever = ns },
    RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)",
    C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendChatMessage = function(text, channel) state.chats[#state.chats + 1] = { text, channel } end,
        SendAddonMessage = function(prefix, text, channel)
            state.addons[#state.addons + 1] = { prefix, text, channel }
        end,
    },
    CreateFrame = function()
        local frame = widget()
        state.frames[#state.frames + 1] = frame
        return frame
    end,
    UnitName = function() return "Host" end,
    UnitFullName = function() return "Host" end,
    Ambiguate = function(name, mode)
        return mode == "short" and (name:gsub("%-%w+$", "")) or name
    end,
    IsInGuild = function() return true end,
    IsInRaid = function() return state.inRaid end,
    IsInGroup = function() return true end,
    GetTime = function() return 10 end,
    RandomRoll = function(minimum, maximum) state.roll = { minimum, maximum } end,
    strlower = string.lower,
    strtrim = function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end,
    math = { floor = math.floor, abs = math.abs, random = function() return 1 end },
}, { __index = _G })
env._G.NaowhForever = ns
env._G.RandomRoll = env.RandomRoll
env._G.RANDOM_ROLL_RESULT = env.RANDOM_ROLL_RESULT
local file = assert(io.open("NaowhForever_QoL/Gambling/Gamble.lua", "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local chunk = assert(loadstring(source, "Gamble.lua"))
setfenv(chunk, env)
chunk()

local function Button(text)
    for _, button in ipairs(state.buttons) do
        if button.text == text then return button end
    end
    error("missing button: " .. text)
end

local function Event(event, ...)
    assert(state.events and state.events.events[event], "event not registered: " .. event)
    state.events.scripts.OnEvent(state.events, event, ...)
end

local function Chat(text, channel)
    for i = #state.chats, 1, -1 do
        if state.chats[i][1]:find(text, 1, true) and (not channel or state.chats[i][2] == channel) then
            return true
        end
    end
    return false
end

ns.ToggleGamble()
check("off by default, Gamble builds no frames", #state.frames == 0 and #state.prints == 1)
S.Set("gamble", true)
ns.ToggleGamble()
check("opening registers the session listeners", state.window:IsShown() and state.events.events.CHAT_MSG_SYSTEM)
state.inRaid = true
local addonCount = #state.addons
Button("New Game"):Click()
check("Party chat is not offered as a partial-raid channel",
    #state.addons == addonCount and state.prints[#state.prints]:find("party or raid", 1, true) ~= nil)
state.inRaid = false
Button("New Game"):Click()
check("a new Classic session is announced in the selected channel",
    Chat("Classic, pool 200", "PARTY") and state.addons[#state.addons][2]:match("^O|"))
check("the session announcement includes its join and leave words",
    state.addons[#state.addons][2]:match("^O|[^|]+|200|classic|join|leave|Host$") ~= nil)
Button("Join"):Click()
Event("CHAT_MSG_PARTY", "join", "Alice Stone")
Event("CHAT_MSG_PARTY", "join", "Bob")
check("join words fill the host roster", state.window and Button("Joined") ~= nil)
Button("Start Rolling"):Click()
check("Classic asks every joined player to roll", Chat("Host, Alice Stone and Bob", "PARTY"))
Button("Roll for Me"):Click()
check("the roll button rolls only for its owner", state.roll[1] == 1 and state.roll[2] == 200)
Event("CHAT_MSG_SYSTEM", "Host rolls 90 (1-200)")
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 90 (1-200)")
Event("CHAT_MSG_SYSTEM", "Bob rolls 20 (1-200)")
check("a tied extreme starts a tie-break round", Chat("Tie-break: Host, Alice Stone and Bob", "PARTY"))
Event("CHAT_MSG_SYSTEM", "Host rolls 70 (1-200)")
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 80 (1-200)")
Event("CHAT_MSG_SYSTEM", "Bob rolls 30 (1-200)")
check("the lowest pays the highest the roll difference", Chat("Bob pays Alice Stone 50 gold", "PARTY"))
check("Classic results persist lifetime win/loss stats",
    state.account.gambleStats["alice stone"].net == 50 and state.account.gambleStats.bob.net == -50)

S.Set("gambleMode", "deathroll")
Button("New Game"):Click()
Button("Join"):Click()
Event("CHAT_MSG_PARTY", "join", "Alice Stone")
Button("Start Rolling"):Click()
Button("Roll for Me"):Click()
check("Deathroll begins with the selected player and full pool", state.roll[1] == 1 and state.roll[2] == 200)
Event("CHAT_MSG_SYSTEM", "Host rolls 40 (1-200)")
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 1 (1-40)")
check("rolling 1 pays the full Deathroll pool", Chat("Alice Stone pays Host 200 gold", "PARTY"))

Event("CHAT_MSG_ADDON", "NaowhGamble", "O|remote|200|classic|ready|gone|Guest",
    "PARTY", "Host")
Button("Join"):Click()
check("joining a discovered session uses its host-configured join word", Chat("ready", "PARTY"))
local localRoster = state.fonts[3].text
Event("CHAT_MSG_ADDON", "NaowhGamble", "R|remote|1|1|2|Host,Alice", "PARTY", "Host")
check("a partial roster waits for every chunk", state.fonts[3].text == localRoster)
Event("CHAT_MSG_ADDON", "NaowhGamble", "R|remote|1|2|2|Bob,Charlie", "PARTY", "Host")
check("chunked rosters assemble before display", state.fonts[3].text:find("Charlie", 1, true) ~= nil)
Event("CHAT_MSG_ADDON", "NaowhGamble", "C|remote|1|100|1|2|Host,Alice", "PARTY", "Host")
Event("CHAT_MSG_ADDON", "NaowhGamble", "C|remote|1|100|2|2|Bob,Charlie", "PARTY", "Host")
check("chunked roll rounds enable the local player's roll", Button("Roll for Me").enabled)

Button("Options"):Click()
check("the options panel exposes configurable game mode", state.options and state.options:IsShown())
local savedJoinWord = S.Get("gambleJoinWord")
state.editboxes[2]:SetText("ready|bad")
state.editboxes[3]:SetText("gone")
state.options.actions[1][2]()
check("join words cannot break the addon-message payload",
    S.Get("gambleJoinWord") == savedJoinWord and state.prints[#state.prints]:find("without |", 1, true) ~= nil)
Button("Game mode: Deathroll"):Click()
check("the mode option toggles to Classic", S.Get("gambleMode") == "classic")
Button("Clear Stats"):Click()
check("clearing stats asks for confirmation", state.confirm and state.confirm.text == "Clear all saved Gamble stats?")
state.confirm.accept()
check("confirmed clearing removes the saved stats", next(state.account.gambleStats) == nil)

Button("X"):Click()
check("closing keeps listeners active for the joined session",
    not state.window:IsShown() and state.events.events.CHAT_MSG_ADDON)
Event("CHAT_MSG_ADDON", "NaowhGamble", "D|remote|Bob|Alice|10", "PARTY", "Host")
check("a completed session unregisters hidden-window listeners", next(state.events.events) == nil)
print(("test-gamble: %d checks passed"):format(checks))
