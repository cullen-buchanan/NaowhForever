-- Offline checks for Gamble's session flow, roll tracking, tie-breaks and Deathroll.
local checks = 0
local function check(label, value) assert(value, label); checks = checks + 1 end

local state = { settings = { enabled = true, gamble = false, gambleChannel = "PARTY", gamblePool = 200,
    gambleMode = "classic", gambleJoinWord = "join", gambleLeaveWord = "leave" },
    buttons = {}, chats = {}, addons = {},
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
function widgetMethods:SetPoint(...)
    local points = rawget(self, "anchorPoints") or {}
    points[#points + 1] = { ... }
    rawset(self, "anchorPoints", points)
end
function widgetMethods:SetSize(width, height)
    rawset(self, "width", width)
    rawset(self, "height", height)
end
function widgetMethods:SetHeight() end
function widgetMethods:SetNumeric() end
function widgetMethods:SetScale() end
function widgetMethods:SetJustifyH() end
function widgetMethods:SetJustifyV() end
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
    Shared = { Parts = parts, Style = { WINDOW_PAD = 12, WINDOW_HEADER = 52, WINDOW_FOOTER = 28,
        CONTENT_INSET = 22 },
        Settings = { Page = function() return { Card = function(_, spec) state.card = spec end } end } },
    UI = {},
}
function ns.Font(parent)
    local font = widget()
    font.parent = parent
    if parent == state.controls and not state.poolLabel then state.poolLabel = font end
    if parent == state.window then
        if not state.status then state.status = font else state.roster = font end
    end
    state.fonts[#state.fonts + 1] = font
    return font
end
function ns.NewEditBox(parent)
    local box = widget()
    box.parent = parent
    state.editboxes[#state.editboxes + 1] = box
    return box
end
function ns.Button(parent, text, width, height, onClick)
    local button = widget()
    button.parent, button.text, button.onClick = parent, text, onClick
    button:SetSize(width, height)
    state.buttons[#state.buttons + 1] = button
    return button
end
function ns.SetButtonText(button, text) button.text = text end
function ns.AccentBorder(button) return button end
function ns.UIScale() return 1 end
function ns.Print(text) state.prints[#state.prints + 1] = text end

local env = setmetatable({
    _G = { NaowhForever = ns },
    RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)",
    YOU_ROLL_RESULT = "You roll %d (%d-%d)",
    C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendChatMessage = function(text, channel) state.chats[#state.chats + 1] = { text, channel } end,
        SendAddonMessage = function(prefix, text, channel)
            state.addons[#state.addons + 1] = { prefix, text, channel }
        end,
    },
    CreateFrame = function(_, _, parent)
        local frame = widget()
        frame.parent = parent
        state.frames[#state.frames + 1] = frame
        if parent == state.window then state.controls = frame end
        return frame
    end,
    UnitName = function() return "Host" end,
    UnitFullName = function() return "Host" end,
    Ambiguate = function(name, mode)
        return mode == "short" and (name:gsub("%-%w+$", "")) or name
    end,
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
env._G.YOU_ROLL_RESULT = env.YOU_ROLL_RESULT
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

local function HasButton(text)
    for _, button in ipairs(state.buttons) do
        if button.text == text then return true end
    end
    return false
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
check("pool, chat and announce controls are inset within the Gamble card",
    state.controls and state.controls.parent == state.window
        and rawget(state.controls, "anchorPoints")[1][4] >= ns.Shared.Style.WINDOW_PAD + 8
        and -rawget(state.controls, "anchorPoints")[1][5] >= ns.Shared.Style.WINDOW_HEADER
            + ns.Shared.Style.WINDOW_PAD + 8
        and rawget(state.poolLabel, "anchorPoints")[1][4] == ns.Shared.Style.WINDOW_PAD
        and rawget(state.editboxes[1], "anchorPoints")[1][2] == state.poolLabel
        and state.editboxes[1].parent == state.controls
        and Button("Party Chat").parent == state.controls
        and Button("Announce Rolls").parent == state.controls
        and rawget(Button("Party Chat"), "anchorPoints")[1][1] == "LEFT"
        and rawget(Button("Party Chat"), "anchorPoints")[1][2] == state.editboxes[1]
        and rawget(Button("Party Chat"), "anchorPoints")[1][3] == "RIGHT"
        and rawget(Button("Announce Rolls"), "anchorPoints")[1][1] == "LEFT"
        and rawget(Button("Announce Rolls"), "anchorPoints")[1][2] == Button("Party Chat")
        and rawget(Button("Announce Rolls"), "anchorPoints")[1][3] == "RIGHT"
        and rawget(Button("Announce Rolls"), "anchorPoints")[1][4] == 10
        and rawget(Button("Announce Rolls"), "anchorPoints")[1][5] == 0
        and rawget(Button("Announce Rolls"), "height") == rawget(Button("Party Chat"), "height")
        and state.editboxes[2].parent == state.controls and state.editboxes[2]:GetText() == "join"
        and state.editboxes[3].parent == state.controls and state.editboxes[3]:GetText() == "leave"
        and HasButton("Game mode: Classic") and not HasButton("Options")
        and not HasButton("Join") and not HasButton("Roll for Me"))
Button("Party Chat"):Click()
check("chat channel selection switches from Party to Raid",
    S.Get("gambleChannel") == "RAID" and HasButton("Raid Chat"))
Button("Raid Chat"):Click()
check("chat channel selection cycles from Raid back to Party",
    S.Get("gambleChannel") == "PARTY" and HasButton("Party Chat"))
state.inRaid = true
local addonCount = #state.addons
Button("New Game"):Click()
check("Party chat is not offered as a partial-raid channel",
    #state.addons == addonCount and state.prints[#state.prints]:find("party or raid", 1, true) ~= nil)
state.inRaid = false
S.Set("gambleChannel", "UNSUPPORTED")
Button("New Game"):Click()
check("a new Classic session is announced in the selected channel",
    S.Get("gambleChannel") == "PARTY" and Chat("Classic, pool 200", "PARTY")
        and state.addons[#state.addons][2]:match("^O|"))
check("the new-game announcement explains how to leave",
    Chat('Say "join" to join or "leave" to leave; use /roll when it\'s your turn.', "PARTY"))
check("the session announcement includes its join and leave words",
    state.addons[#state.addons][2]:match("^O|[^|]+|200|classic|join|leave|Host$") ~= nil)
Button("Start Rolling"):Click()
check("Start Rolling explains when more players are needed",
    state.prints[#state.prints]:find("At least two players", 1, true) ~= nil)
Event("CHAT_MSG_PARTY", "join", "Host")
Event("CHAT_MSG_PARTY", "join", "Alice Stone")
Event("CHAT_MSG_PARTY", "join", "Bob")
check("host and players join through group chat",
    state.roster.text:find("Host", 1, true) ~= nil
        and state.roster.text:find("Alice Stone", 1, true) ~= nil
        and state.roster.text:find("Bob", 1, true) ~= nil)
Button("Start Rolling"):Click()
check("Start Rolling starts the Classic round when players joined",
    state.status.text == "Waiting for rolls")
Button("Announce Rolls"):Click()
check("Classic announces only players still waiting and the roll range",
    Chat("Still need to roll: Host, Alice Stone and Bob. Roll from 1 to 200", "PARTY"))
Event("CHAT_MSG_SYSTEM", "You roll 90 (1-200)")
check("a local /roll result is counted for the host", state.roster.text:find("Host  90", 1, true) ~= nil)
Button("Announce Rolls"):Click()
check("Classic roll calls exclude players who already rolled",
    Chat("Still need to roll: Alice Stone and Bob. Roll from 1 to 200", "PARTY"))
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 90 (1-200)")
Event("CHAT_MSG_SYSTEM", "Bob rolls 20 (1-200)")
Event("CHAT_MSG_SYSTEM", "Host rolls 70 (1-200)")
Button("Announce Rolls"):Click()
check("Classic roll calls exclude players who already rolled",
    Chat("Still need to roll: Alice Stone and Bob. Roll from 1 to 200", "PARTY"))
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 80 (1-200)")
Event("CHAT_MSG_SYSTEM", "Bob rolls 30 (1-200)")
check("the lowest pays the highest the roll difference", Chat("Bob pays Alice Stone 50 gold", "PARTY"))

state.editboxes[2]:SetText("ready|bad")
state.editboxes[3]:SetText("gone")
state.editboxes[2].scripts.OnEnterPressed()
check("inline join words reject addon-message delimiters",
    S.Get("gambleJoinWord") == "join" and state.prints[#state.prints]:find("without |", 1, true) ~= nil)
state.editboxes[2]:SetText("ready")
state.editboxes[2].scripts.OnEnterPressed()
check("inline join and leave words save from the main window",
    S.Get("gambleJoinWord") == "ready" and S.Get("gambleLeaveWord") == "gone")
Button("Game mode: Classic"):Click()
check("the main-window mode button switches to Deathroll",
    S.Get("gambleMode") == "deathroll" and HasButton("Game mode: Deathroll"))
Button("New Game"):Click()
check("custom join and leave words are announced for a new game",
    Chat('Say "ready" to join or "gone" to leave; use /roll when it\'s your turn.', "PARTY"))
Event("CHAT_MSG_PARTY", "ready", "Host")
Event("CHAT_MSG_PARTY", "ready", "Alice Stone")
Button("Start Rolling"):Click()
check("Deathroll starts and waits for its first /roll",
    state.status.text == "Deathroll in progress")
Event("CHAT_MSG_SYSTEM", "You roll 40 (1-200)")
check("Deathroll does not automatically announce every next turn", not Chat("Alice Stone, roll", "PARTY"))
Button("Announce Rolls"):Click()
check("Deathroll announces the current player and their roll range on demand",
    Chat("Alice Stone, roll from 1 to 40", "PARTY"))
Event("CHAT_MSG_SYSTEM", "Alice Stone rolls 1 (1-40)")
check("rolling 1 pays the full Deathroll pool", Chat("Alice Stone pays Host 200 gold", "PARTY"))

Event("CHAT_MSG_ADDON", "NaowhGamble", "O|remote|200|classic|ready|gone|Guest",
    "PARTY", "Host")
check("players use the advertised chat join word instead of a Join button",
    not HasButton("Join") and Chat('Say "ready" to join or "gone" to leave', "PARTY"))
local localRoster = state.roster.text
Event("CHAT_MSG_ADDON", "NaowhGamble", "R|remote|1|1|2|Host,Alice", "PARTY", "Host")
check("a partial roster waits for every chunk", state.roster.text == localRoster)
Event("CHAT_MSG_ADDON", "NaowhGamble", "R|remote|1|2|2|Bob,Charlie", "PARTY", "Host")
check("chunked rosters assemble before display", state.roster.text:find("Charlie", 1, true) ~= nil)
Event("CHAT_MSG_ADDON", "NaowhGamble", "C|remote|1|100|1|2|Host,Alice", "PARTY", "Host")
Event("CHAT_MSG_ADDON", "NaowhGamble", "C|remote|1|100|2|2|Bob,Charlie", "PARTY", "Host")
check("chunked roll rounds accept player /roll messages",
    state.events.events.CHAT_MSG_SYSTEM and not HasButton("Roll for Me"))

Button("X"):Click()
check("closing keeps listeners active for the joined session",
    not state.window:IsShown() and state.events.events.CHAT_MSG_ADDON)
Event("CHAT_MSG_ADDON", "NaowhGamble", "D|remote|Bob|Alice|10", "PARTY", "Host")
check("a completed session unregisters hidden-window listeners", next(state.events.events) == nil)
print(("test-gamble: %d checks passed"):format(checks))
