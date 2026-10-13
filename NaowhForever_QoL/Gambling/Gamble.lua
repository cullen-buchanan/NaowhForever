--- Group chat-based gambling sessions with Classic rolls and Deathroll.
-- The host tracks the roster and roll results, synchronizes session state with
-- addon messages, and announces settlements without transferring gold.
-- @script Gamble
local ns = _G.NaowhForever

local Ambiguate, IsInGroup, IsInRaid = Ambiguate, IsInGroup, IsInRaid
local UnitFullName, UnitName = UnitFullName, UnitName
local floor, random = math.floor, math.random
local concat, remove = table.concat, table.remove
local lower, trim = strlower, strtrim
local RegisterAddonMessagePrefix = C_ChatInfo.RegisterAddonMessagePrefix
local SendAddonMessage, SendChatMessage = C_ChatInfo.SendAddonMessage, C_ChatInfo.SendChatMessage

local S = ns.QoLSettings
local T = ns.THEME
local Parts, St = ns.Shared.Parts, ns.Shared.Style

-- Addon-message identity and the QoL settings page that owns this feature.
local PREFIX = "NaowhGamble"
local PAGE = "QoL/Questing & Group"

-- Window and widget dimensions are shared by the main frame and its controls.
local WINDOW_W, WINDOW_H = 520, 470
local PAD, HEADER, FOOTER = St.WINDOW_PAD, St.WINDOW_HEADER, St.WINDOW_FOOTER
local INSET, ROW_GAP = St.CONTENT_INSET, 10
local CONTROLS_H, CONFIG_FIELD_W, MODE_BUTTON_W = 84, 130, 160
local POOL_W, POOL_H = 100, 28
local CHANNEL_W, CHANNEL_H = 118, 28
local ANNOUNCE_W = 120
local BUTTON_W, BUTTON_H, BUTTON_GAP = 112, 28, 8
local FIELD_INSET = 8
local HELP_TEXT_HEIGHT = 1000

-- Bounds keep session values and pipe-delimited addon payloads within safe sizes.
local MAX_POOL, MAX_WORD = 100000000, 24
local MAX_PARTICIPANTS, MAX_PLAYER_NAME, MAX_ROSTER_CHUNK = 40, 48, 150

--- Map registered chat events to the channel used by Gamble.
-- @table CHAT_EVENTS
-- @field CHAT_MSG_PARTY PARTY and party-leader messages.
-- @field CHAT_MSG_RAID RAID and raid-leader messages.
local CHAT_EVENTS = {
    CHAT_MSG_PARTY = "PARTY", CHAT_MSG_PARTY_LEADER = "PARTY",
    CHAT_MSG_RAID = "RAID", CHAT_MSG_RAID_LEADER = "RAID",
}

--- Channels available for session announcements and addon messages.
-- @table CHANNELS
local CHANNELS = { "PARTY", "RAID" }

--- Human-readable labels for WoW chat channel identifiers and game modes.
-- @table CHANNEL_LABEL
local CHANNEL_LABEL = { PARTY = "Party", RAID = "Raid" }
--- Human-readable labels for the supported game mode identifiers.
-- @table MODE_LABEL
local MODE_LABEL = { classic = "Classic", deathroll = "Deathroll" }

--- Lua pattern escapes used to match WoW's localized roll text literally.
-- @table PATTERN_ESCAPE
local PATTERN_ESCAPE = {
    ["%"] = "%%", ["^"] = "%^", ["$"] = "%$", ["("] = "%(", [")"] = "%)",
    ["."] = "%.", ["["] = "%[", ["]"] = "%]", ["*"] = "%*", ["+"] = "%+",
    ["-"] = "%-", ["?"] = "%?",
}
-- Window labels and user-facing chat or validation messages.
local TITLE, SUBTITLE = "Gamble", "Classic and Deathroll"
local TEXT_POOL = "Pool"
local TEXT_CHANNEL = "%s Chat"
local TEXT_NEW, TEXT_LAST_CALL = "New Game", "Last Call"
local TEXT_START = "Start Rolling"
local TEXT_CANCEL = "Cancel Session"
local TEXT_NO_GAME = "Start a new session before rolling."
local TEXT_NOT_LOBBY = "This session is already rolling."
local TEXT_NOT_HOST = "Only the session host can start a new session."
local TEXT_NEED_PLAYERS = "At least two players must join first."
local TEXT_BAD_POOL = "Enter a whole-number pool between 1 and %d."
local TEXT_BAD_WORD = "Join and leave words must be different single words without |."
local TEXT_NEED_GROUP = "Join a party or raid before using that chat channel."
local TEXT_STARTED = "Gamble session started: %s, pool %d. Say \"%s\" to join or \"%s\" to leave; use /roll when it's your turn."
local TEXT_CANCELLED = "Gamble session cancelled by %s."
local TEXT_LAST = "Last call: say \"%s\" in %s chat to join."
local TEXT_JOINED = "%s joined the Gamble session."
local TEXT_LEFT = "%s left the Gamble session."
local TEXT_DUEL = "Deathroll: %s and %s are playing for %d gold."
local TEXT_DUEL_START = "%s was randomly selected to roll first. Roll from 1 to %d."
local TEXT_ANNOUNCE, TEXT_STILL_NEED = "Announce Rolls", "Still need to roll: %s. Roll from 1 to %d."
local TEXT_NEXT_ROLL = "%s, roll from 1 to %d."
local TEXT_NO_ROLLS = "Everyone has rolled."
local TEXT_SETTLEMENT = "%s pays %s %d gold."
local TEXT_ROSTER = "No players have joined yet."
local TEXT_ROSTER_ROW = "%s  %s"
local TEXT_MODE = "Game mode: %s"
local TEXT_JOIN_WORD = "Join word"
local TEXT_LEAVE_WORD = "Leave word"
local TEXT_COMM_FAILED = "Gamble could not register its group message prefix."
local TEXT_NOT_ACTIVE = "Turn on Gamble under QoL > Questing & Group first."

-- Lazily-created main-window widgets; nil until Gamble is first opened.
local window, controls, poolBox, channelButton, announceButton, status, roster, helpView
local joinBox, leaveBox, modeButton
local newButton, lastCallButton, startButton, cancelButton, helpButton

-- The single event frame is created on demand; the prefix only needs registering once.
local events, prefixRegistered
local OnEvent

-- Active local or discovered session. It tracks the host, lobby, and phase;
-- `round` stores eligible players, rolls seen, and the current roll maximum;
-- `duel` stores the two Deathroll opponents, next roller, and pot.
local game

--- Normalize a player name for case-insensitive lookup.
-- @local
-- @param name Player name, optionally including a realm.
-- @return Lowercase normalized key, or nil for an invalid name.
local function PlayerKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    return lower(Ambiguate(name, "none"))
end

--- Format player names as a readable list.
-- @local
-- @param players Array of player names or player records.
-- @return Names joined with commas and a final "and".
local function Names(players)
    local names = {}
    for i, player in ipairs(players) do
        names[i] = type(player) == "table" and player.name or player
    end
    if #names < 3 then return concat(names, " and ") end
    return concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

--- Get the local player's full name when available.
-- @local
-- @return Full character name, short name, or a safe fallback.
local function PlayerName()
    return UnitFullName("player") or UnitName("player") or "Player"
end

--- Report whether Gamble is enabled both globally and in QoL settings.
-- @local
-- @return True when Gamble is active.
local function IsOn()
    return S.Get("enabled") and S.Get("gamble")
end

--- Validate configured chat words and their addon-payload constraints.
-- @local
-- @param joinWord Word players say to join a lobby.
-- @param leaveWord Word players say to leave a lobby.
-- @return True when both are distinct, single, bounded words without "|".
local function ValidWords(joinWord, leaveWord)
    return type(joinWord) == "string" and type(leaveWord) == "string"
        and joinWord:match("^%S+$") and leaveWord:match("^%S+$")
        and not joinWord:find("|", 1, true) and not leaveWord:find("|", 1, true)
        and #joinWord <= MAX_WORD and #leaveWord <= MAX_WORD
        and lower(joinWord) ~= lower(leaveWord)
end

--- Check that the player can use the selected group-chat channel.
-- @local
-- @param channel WoW channel identifier.
-- @return True when the player is in the required party or raid.
local function ChannelAvailable(channel)
    if channel == "RAID" then return IsInRaid() end
    return channel == "PARTY" and IsInGroup() and not IsInRaid()
end

--- Send a public session message after verifying the channel is available.
-- @local
-- @param text Message to send.
-- @param channel WoW channel identifier.
-- @return True if sent; otherwise print the appropriate group requirement.
local function SendChat(text, channel)
    if not ChannelAvailable(channel) then
        ns.Print(TEXT_NEED_GROUP)
        return false
    end
    SendChatMessage(text, channel)
    return true
end

--- Send a session synchronization message to an available channel.
-- @local
-- @param text Encoded Gamble protocol message.
-- @param channel WoW channel identifier.
-- @return True if sent, false if the channel is unavailable.
local function SendAddon(text, channel)
    if not ChannelAvailable(channel) then return false end
    SendAddonMessage(PREFIX, text, channel)
    return true
end

--- Decide whether Gamble needs to listen for chat and roll events.
-- @local
-- @return True while the window is open or a session is still active.
local function NeedEvents()
    return IsOn() and ((window and window:IsShown()) or (game and game.phase ~= "complete"))
end

--- Register or unregister the events required by the current feature state.
-- @local
local function UpdateListening()
    local listen = NeedEvents()
    if not listen then
        if events then events:UnregisterAllEvents() end
        return
    end
    if not prefixRegistered then
        local registered = RegisterAddonMessagePrefix(PREFIX)
        if registered == false then
            ns.Print(TEXT_COMM_FAILED)
            return
        end
        prefixRegistered = true
    end
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    events:UnregisterAllEvents()
    events:RegisterEvent("CHAT_MSG_SYSTEM")
    events:RegisterEvent("CHAT_MSG_ADDON")
    for event in pairs(CHAT_EVENTS) do events:RegisterEvent(event) end
end

--- Send one addon message over every channel currently available to the player.
-- @local
-- @param text Encoded Gamble protocol message.
local function SendAddonToAvailable(text)
    for _, channel in ipairs(CHANNELS) do
        if ChannelAvailable(channel) then SendAddon(text, channel) end
    end
end

--- Ask nearby Gamble hosts to resend any active session state.
-- @local
local function RequestOpenSessions()
    SendAddonToAvailable("Q")
end

--- Look up a session participant by normalized player name.
-- @local
-- @param name Player name, optionally including a realm.
-- @return Participant record or nil if the player is not in this session.
local function FindPlayer(name)
    local key = PlayerKey(name)
    if not key or not game then return nil end
    return game.players[key]
end

--- Add a unique participant while respecting the session roster limit.
-- @local
-- @param name Player name to add.
-- @return True if added; false if invalid, duplicate, or over capacity.
local function AddPlayer(name)
    local key = PlayerKey(name)
    if not (key and game and not game.players[key]) then return false end
    if #game.participants >= MAX_PARTICIPANTS then return false end
    local player = { key = key, name = Ambiguate(name, "none") }
    game.players[key] = player
    game.participants[#game.participants + 1] = player
    return true
end

--- Remove a participant from both the roster array and name lookup.
-- @local
-- @param name Player name to remove.
-- @return True if removed, false if the player was not in the session.
local function RemovePlayer(name)
    local player = FindPlayer(name)
    if not player then return false end
    game.players[player.key] = nil
    for i, entry in ipairs(game.participants) do
        if entry == player then
            remove(game.participants, i)
            break
        end
    end
    return true
end

--- Decode a comma-separated roster chunk into validated participant records.
-- @local
-- @param encoded Comma-separated player names.
-- @return Player records, or nil if the names are invalid or over the limits.
local function DecodePlayers(encoded)
    local players = {}
    if type(encoded) ~= "string" or #encoded > MAX_PARTICIPANTS * (MAX_PLAYER_NAME + 1) then return nil end
    local seen = {}
    for name in encoded:gmatch("[^,]+") do
        if #name > MAX_PLAYER_NAME or #players >= MAX_PARTICIPANTS then return nil end
        local key = PlayerKey(name)
        if not key or seen[key] then return nil end
        seen[key] = true
        players[#players + 1] = { key = key, name = Ambiguate(name, "none") }
    end
    return players
end

--- Build a name-keyed lookup table from an ordered player list.
-- @local
-- @param players Array of participant records.
-- @return Map from normalized player key to participant record.
local function RosterMap(players)
    local out = {}
    for _, player in ipairs(players) do out[player.key] = player end
    return out
end

--- Refresh the visible session status, roster, and control availability.
-- @local
local function UpdateDisplay()
    if not (window and window:IsShown()) then return end
    local phaseText = game and game.phase or "No session"
    if game and game.phase == "lobby" then phaseText = "Waiting for players to join" end
    if game and game.phase == "rolling" then phaseText = "Waiting for rolls" end
    if game and game.phase == "deathroll" then phaseText = "Deathroll in progress" end
    if game and game.phase == "complete" then
        phaseText = game.cancelled and "Session cancelled" or "Session complete"
    end
    status:SetText(phaseText)

    local rows = {}
    for _, player in ipairs(game and game.participants or {}) do
        local value = game.round and game.round.rolls[player.key]
        if value then
            rows[#rows + 1] = TEXT_ROSTER_ROW:format(player.name, tostring(value))
        else
            rows[#rows + 1] = player.name
        end
    end
    roster:SetText(#rows > 0 and concat(rows, "\n") or TEXT_ROSTER)

    local channel = game and game.phase ~= "complete" and game.channel or S.Get("gambleChannel")
    channel = CHANNEL_LABEL[channel] and channel or "PARTY"
    ns.SetButtonText(channelButton, TEXT_CHANNEL:format(CHANNEL_LABEL[channel]))
    if game and game.phase ~= "complete" then poolBox:SetText(tostring(game.pool)) end
    lastCallButton:SetEnabled(game ~= nil and game.phase == "lobby" and game.isHost)
    startButton:SetEnabled(game ~= nil and game.phase == "lobby" and game.isHost)
    cancelButton:SetEnabled(game ~= nil and game.phase ~= "complete" and game.isHost)
    announceButton:SetEnabled(game ~= nil and game.isHost and game.round ~= nil
        and (game.phase == "rolling" or game.phase == "deathroll"))
    channelButton:SetEnabled(not (game and game.phase ~= "complete"))
    poolBox:SetEnabled(not (game and game.phase ~= "complete"))
end

--- Encode a protocol message with the active session identifier.
-- Message kinds are O=open, R=roster, C=classic round, M=duel, T=turn,
-- D=settlement, X=close, and Q=request state.
-- @local
-- @param kind Single-character protocol message kind.
-- @param ... Message-specific fields, serialized with "|" separators.
-- @return Encoded message, or just the kind when there is no active session.
local function AddonPayload(kind, ...)
    if not game then return kind end
    return kind .. "|" .. game.id .. "|" .. concat({ ... }, "|")
end

--- Broadcast the host's current participant roster in bounded-size chunks.
-- @local
local function BroadcastRoster()
    if not (game and game.isHost) then return end
    if #game.participants == 0 then return end
    game.rosterVersion = (game.rosterVersion or 0) + 1
    local chunks, current, size = {}, {}, 0
    for _, player in ipairs(game.participants) do
        local name = player.name
        local added = #name + (#current > 0 and 1 or 0)
        if size + added > MAX_ROSTER_CHUNK then
            chunks[#chunks + 1] = concat(current, ",")
            current, size = {}, 0
            added = #name
        end
        current[#current + 1], size = name, size + added
    end
    if #current > 0 then chunks[#chunks + 1] = concat(current, ",") end
    for index, chunk in ipairs(chunks) do
        SendAddon(AddonPayload("R", game.rosterVersion, index, #chunks, chunk), game.channel)
    end
end

--- Broadcast the players eligible for the current Classic round.
-- @local
local function BroadcastRound()
    if not (game and game.isHost and game.round) then return end
    game.roundVersion = (game.roundVersion or 0) + 1
    local chunks, current, size = {}, {}, 0
    for _, player in ipairs(game.round.players) do
        local name = player.name
        local added = #name + (#current > 0 and 1 or 0)
        if size + added > MAX_ROSTER_CHUNK then
            chunks[#chunks + 1] = concat(current, ",")
            current, size = {}, 0
            added = #name
        end
        current[#current + 1], size = name, size + added
    end
    if #current > 0 then chunks[#chunks + 1] = concat(current, ",") end
    for index, chunk in ipairs(chunks) do
        SendAddon(AddonPayload("C", game.roundVersion, game.round.max, index, #chunks, chunk), game.channel)
    end
end

--- Collect ordered roster chunks and decode them once a full version arrives.
-- Older or incomplete message sets are ignored so stale state cannot replace
-- a newer roster or round.
-- @local
-- @param kind Assembly key, distinguishing roster and round chunks.
-- @param version Monotonically increasing sequence number.
-- @param index One-based index of this chunk.
-- @param count Total number of chunks in this sequence.
-- @param encoded Comma-separated player names in this chunk.
-- @return Decoded participants when the sequence is complete, otherwise nil.
local function AssemblePlayers(kind, version, index, count, encoded)
    version, index, count = tonumber(version), tonumber(index), tonumber(count)
    if not (version and index and count and version >= 0 and index >= 1
        and count >= 1 and count <= MAX_PARTICIPANTS and index <= count
        and #encoded <= MAX_ROSTER_CHUNK) then return nil end
    game.playerVersions = game.playerVersions or {}
    if version <= (game.playerVersions[kind] or 0) then return nil end
    game.playerAssemblies = game.playerAssemblies or {}
    local assembly = game.playerAssemblies[kind]
    if assembly and version < assembly.version then return nil end
    if not (assembly and assembly.version == version and assembly.count == count) then
        assembly = { version = version, count = count, chunks = {} }
        game.playerAssemblies[kind] = assembly
    end
    assembly.chunks[index] = encoded
    for part = 1, count do
        if not assembly.chunks[part] then return nil end
    end
    game.playerAssemblies[kind] = nil
    game.playerVersions[kind] = version
    return DecodePlayers(concat(assembly.chunks, ","))
end

--- Announce a new session and its settings to other addon users.
-- @local
local function BroadcastOpen()
    if not (game and game.isHost) then return end
    SendAddon(AddonPayload("O", game.pool, game.mode, game.joinWord, game.leaveWord, PlayerName()), game.channel)
end

--- Begin a Classic round with the supplied players and maximum roll value.
-- @local
-- @param players Participants expected to roll in this round.
-- @param max Upper bound for each /roll.
local function SetClassicRound(players, max)
    local expected = RosterMap(players)
    game.phase = "rolling"
    game.round = { expected = expected, rolls = {}, players = players, max = max }
    game.rollMax = max
    if game.isHost then
        BroadcastRound()
    end
    UpdateDisplay()
end

--- Set the active Deathroll turn and tell clients who must roll next.
-- @local
-- @param player Participant who owns the current turn.
-- @param max Upper bound for the current /roll.
local function SetDeathrollTurn(player, max)
    game.phase = "deathroll"
    game.round = { expected = { [player.key] = player }, rolls = {}, players = { player }, max = max }
    game.rollMax = max
    if game.isHost then
        SendAddon(AddonPayload("T", max, player.name), game.channel)
    end
    UpdateDisplay()
end

--- Choose two distinct participants and start their Deathroll duel.
-- @local
local function StartDeathroll()
    local players = game.participants
    local firstIndex, secondIndex = random(#players), random(#players - 1)
    if secondIndex >= firstIndex then secondIndex = secondIndex + 1 end
    local first, second = players[firstIndex], players[secondIndex]
    SendChat(TEXT_DUEL:format(first.name, second.name, game.pool), game.channel)
    local starter = random(2) == 1 and first or second
    game.duel = { first = first, second = second, next = starter, pot = game.pool }
    SendAddon(AddonPayload("M", game.pool, first.name, second.name, starter.name), game.channel)
    SendChat(TEXT_DUEL_START:format(starter.name, game.pool), game.channel)
    SetDeathrollTurn(starter, game.pool)
end

--- Start the selected game mode after validating host and lobby state.
-- @local
local function StartRolling()
    if not game then ns.Print(TEXT_NO_GAME); return end
    if not game.isHost then ns.Print(TEXT_NOT_HOST); return end
    if game.phase ~= "lobby" then ns.Print(TEXT_NOT_LOBBY); return end
    if #game.participants < 2 then
        ns.Print(TEXT_NEED_PLAYERS)
        return
    end
    if game.mode == "deathroll" then
        StartDeathroll()
    else
        SetClassicRound(game.participants, game.pool)
    end
end

--- Resolve a completed Classic round, rerolling ties before settlement.
-- @local
local function ClassicResult()
    local round = game.round
    local high, low, highs, lows
    for _, player in ipairs(round.players) do
        local value = round.rolls[player.key]
        if value then
            if high == nil or value > high then high, highs = value, { player }
            elseif value == high then highs[#highs + 1] = player end
            if low == nil or value < low then low, lows = value, { player }
            elseif value == low then lows[#lows + 1] = player end
        end
    end
    if #highs > 1 or #lows > 1 then
        local tied, seen = {}, {}
        for _, player in ipairs(highs) do
            if not seen[player.key] then tied[#tied + 1], seen[player.key] = player, true end
        end
        for _, player in ipairs(lows) do
            if not seen[player.key] then tied[#tied + 1], seen[player.key] = player, true end
        end
        SetClassicRound(tied, game.pool)
        return
    end
    local loser, winner = lows[1], highs[1]
    local amount = high - low
    if loser and winner and loser ~= winner and amount > 0 then
        SendChat(TEXT_SETTLEMENT:format(loser.name, winner.name, amount), game.channel)
        SendAddon(AddonPayload("D", loser.name, winner.name, amount), game.channel)
    end
    game.phase = "complete"
    UpdateListening()
    UpdateDisplay()
end

--- Resolve a Deathroll result or pass the turn to the other duelist.
-- @local
-- @param player Participant who just rolled.
-- @param value Their roll result.
local function DeathrollResult(player, value)
    local duel = game.duel
    if not duel then return end
    if value == 1 then
        local winner = player.key == duel.first.key and duel.second or duel.first
        SendChat(TEXT_SETTLEMENT:format(player.name, winner.name, duel.pot), game.channel)
        SendAddon(AddonPayload("D", player.name, winner.name, duel.pot), game.channel)
        game.phase = "complete"
        UpdateListening()
        UpdateDisplay()
        return
    end
    local nextPlayer = player.key == duel.first.key and duel.second or duel.first
    duel.next = nextPlayer
    SetDeathrollTurn(nextPlayer, value)
end

--- Record a valid roll and let the host resolve a finished round.
-- @local
-- @param name Rolling player's name.
-- @param value Roll result.
-- @param minimum Lower bound reported by the game.
-- @param maximum Upper bound reported by the game.
local function OnRoll(name, value, minimum, maximum)
    local key = PlayerKey(name)
    if not (key and game and game.round and game.round.expected[key]) then return end
    if minimum ~= 1 or maximum ~= game.round.max or value < minimum or value > maximum then return end
    game.round.rolls[key] = value
    UpdateDisplay()
    if not game.isHost then return end
    local count = 0
    for _ in pairs(game.round.expected) do count = count + 1 end
    local rolled = 0
    for _ in pairs(game.round.rolls) do rolled = rolled + 1 end
    if rolled < count then return end
    if game.phase == "rolling" then
        ClassicResult()
    elseif game.phase == "deathroll" then
        DeathrollResult(game.round.expected[key], value)
    end
end

--- Convert a localized WoW roll-result format string into a Lua pattern.
-- Percent-s and percent-d placeholders become captures; all other pattern
-- characters are escaped so localized punctuation is matched literally.
-- @local
-- @param format Format string supplied by the WoW client.
-- @param expectedCaptures Number of captures required for this result format.
-- @return Anchored Lua pattern, or nil when the format is unsupported.
local function CompileRollPattern(format, expectedCaptures)
    if type(format) ~= "string" then return nil end
    local pattern, captures, index = { "^" }, 0, 1
    while index <= #format do
        local char = format:sub(index, index)
        if char == "%" and index < #format then
            local nextChar = format:sub(index + 1, index + 1)
            if nextChar == "s" then
                pattern[#pattern + 1], captures, index = "(.+)", captures + 1, index + 2
            elseif nextChar == "d" then
                pattern[#pattern + 1], captures, index = "(%d+)", captures + 1, index + 2
            else
                pattern[#pattern + 1] = PATTERN_ESCAPE[char] or char
                index = index + 1
            end
        else
            pattern[#pattern + 1] = PATTERN_ESCAPE[char] or char
            index = index + 1
        end
    end
    pattern[#pattern + 1] = "$"
    if captures ~= (expectedCaptures or 4) then return nil end
    return concat(pattern)
end

-- WoW supplies localized message templates; compile them once for roll parsing.
local ROLL_PATTERN = CompileRollPattern(_G.RANDOM_ROLL_RESULT)
local SELF_ROLL_PATTERN = CompileRollPattern(_G.YOU_ROLL_RESULT, 3)

--- Parse a localized system message and forward any roll result.
-- @local
-- @param message System chat text generated by /roll.
local function OnSystemMessage(message)
    if not (ROLL_PATTERN and game and game.round) then return end
    local name, value, minimum, maximum = tostring(message):match(ROLL_PATTERN)
    if name then
        if name == "You" then name = PlayerName() end
    elseif SELF_ROLL_PATTERN then
        value, minimum, maximum = tostring(message):match(SELF_ROLL_PATTERN)
        if value then name = PlayerName() end
    end
    if not name then return end
    OnRoll(name, tonumber(value), tonumber(minimum), tonumber(maximum))
end

--- Handle configured join and leave words in the active lobby channel.
-- Only the host changes the roster; resulting updates are broadcast to clients.
-- @local
-- @param event WoW chat event name.
-- @param message Chat message text.
-- @param sender Character who sent the message.
local function OnChannelMessage(event, message, sender)
    if not (game and game.isHost and game.phase == "lobby"
        and CHAT_EVENTS[event] == game.channel and type(sender) == "string") then return end
    local normalized = lower(trim(message or ""))
    local joinWord = lower(game.joinWord)
    local leaveWord = lower(game.leaveWord)
    if normalized == joinWord and AddPlayer(sender) then
        SendChat(TEXT_JOINED:format(Ambiguate(sender, "none")), game.channel)
        BroadcastRoster()
        UpdateDisplay()
    elseif normalized == leaveWord and RemovePlayer(sender) then
        SendChat(TEXT_LEFT:format(Ambiguate(sender, "none")), game.channel)
        BroadcastRoster()
        UpdateDisplay()
    end
end

--- Validate an open-session message and create a client-side lobby.
-- @local
-- @param sender Addon-message sender and host identity.
-- @param channel Channel on which the session was announced.
-- @param id Unique session identifier.
-- @param pool Initial stake amount.
-- @param mode Game mode identifier.
-- @param joinWord Configured lobby join word.
-- @param leaveWord Configured lobby leave word.
-- @param ownerName Host's display name.
local function OpenPayload(sender, channel, id, pool, mode, joinWord, leaveWord, ownerName)
    local amount = tonumber(pool)
    if not (amount and amount >= 1 and amount <= MAX_POOL and amount == floor(amount)
        and (mode == "classic" or mode == "deathroll") and #id <= 64
        and ValidWords(joinWord, leaveWord) and #ownerName <= 48) then return end
    if game and game.phase ~= "complete" then return end
    game = {
        id = id, pool = amount, mode = mode, channel = channel, phase = "lobby",
        hostKey = PlayerKey(sender), isHost = false, participants = {}, players = {},
        joinWord = joinWord, leaveWord = leaveWord, hostName = Ambiguate(ownerName, "none"),
    }
    UpdateListening()
    UpdateDisplay()
end

--- Process Gamble protocol messages and synchronize the local session state.
-- The host is authoritative for roster, round, turn, settlement, and close
-- messages; each message is validated before it updates the local game record.
-- @local
-- @param prefix Addon-message prefix.
-- @param message Encoded Gamble protocol message.
-- @param channel WoW channel used for the message.
-- @param sender Addon-message sender.
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or type(message) ~= "string" or type(sender) ~= "string" then return end
    local key = PlayerKey(sender)
    if message == "Q" then
        if game and game.isHost and game.phase ~= "complete" and game.channel == channel then
            BroadcastOpen()
            BroadcastRoster()
            if game.phase == "rolling" and game.round then
                BroadcastRound()
            elseif game.phase == "deathroll" and game.round then
                SendAddon(AddonPayload("M", game.duel.pot, game.duel.first.name, game.duel.second.name,
                    game.duel.first.name), game.channel)
                local player = game.round.players[1]
                SendAddon(AddonPayload("T", game.round.max, player.name), game.channel)
            end
        end
        return
    end
    local kind, id, rest = message:match("^([A-Z])|([^|]+)|?(.*)$")
    if kind == "O" then
        local pool, mode, joinWord, leaveWord, ownerName = rest:match("^(%d+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)$")
        if pool and ChannelAvailable(channel) then
            OpenPayload(sender, channel, id, pool, mode, joinWord, leaveWord, ownerName)
        end
        return
    end
    if not (game and game.id == id and game.channel == channel) then return end
    if kind == "J" then
        if game.isHost and game.phase == "lobby" and AddPlayer(sender) then
            SendChat(TEXT_JOINED:format(Ambiguate(sender, "none")), game.channel)
            BroadcastRoster()
            UpdateDisplay()
        end
        return
    end
    if key ~= game.hostKey then return end
    if kind == "R" then
        local version, index, count, chunk = rest:match("^(%d+)|(%d+)|(%d+)|(.+)$")
        local players = chunk and AssemblePlayers("R", version, index, count, chunk)
        if players and #players > 0 then
            game.participants, game.players = players, RosterMap(players)
            UpdateDisplay()
        end
    elseif kind == "C" then
        local version, max, index, count, chunk =
            rest:match("^(%d+)|(%d+)|(%d+)|(%d+)|(.+)$")
        local players = chunk and AssemblePlayers("C", version, index, count, chunk)
        max = tonumber(max)
        if max and max <= MAX_POOL and players and #players > 0 then
            game.phase, game.mode = "rolling", "classic"
            game.round = { expected = RosterMap(players), players = players, rolls = {}, max = max }
            game.rollMax = max
            UpdateDisplay()
        end
    elseif kind == "M" then
        local amount, firstName, secondName, starter = rest:match("^(%d+)|([^|]+)|([^|]+)|([^|]+)$")
        amount = tonumber(amount)
        local first, second = FindPlayer(firstName), FindPlayer(secondName)
        local firstRoller = FindPlayer(starter)
        if amount and amount <= MAX_POOL and first and second and firstRoller then
            game.mode = "deathroll"
            game.duel = { first = first, second = second, next = firstRoller, pot = amount }
            UpdateDisplay()
        end
    elseif kind == "T" then
        local max, name = rest:match("^(%d+)|([^|]+)$")
        max = tonumber(max)
        local player = FindPlayer(name)
        if max and max <= MAX_POOL and player then
            game.mode = "deathroll"
            game.duel = game.duel or { first = player, second = player, next = player, pot = game.pool }
            game.phase = "deathroll"
            game.round = { expected = { [player.key] = player }, players = { player }, rolls = {}, max = max }
            game.rollMax = max
            UpdateDisplay()
        end
    elseif kind == "D" and game.phase ~= "complete" then
        local loser, winner, amount = rest:match("^([^|]+)|([^|]+)|(%d+)$")
        amount = tonumber(amount)
        if loser and winner and amount and amount <= MAX_POOL then
            game.phase = "complete"
            UpdateListening()
            UpdateDisplay()
        end
    elseif kind == "X" then
        game.phase = "complete"
        game.cancelled = true
        UpdateListening()
        UpdateDisplay()
    end
end

--- Dispatch registered chat, system-roll, and addon-message events.
-- @param _ Frame receiving the event.
-- @param event WoW event name.
-- @param ... Event-specific arguments.
function OnEvent(_, event, ...)
    if event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(...)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif CHAT_EVENTS[event] then
        OnChannelMessage(event, ...)
    end
end

--- Validate the pool input and persist it as the configured default.
-- @local
-- @return Positive integer pool amount, or nil after displaying an error.
local function GetPool()
    local text = trim(poolBox:GetText() or "")
    local amount = tonumber(text)
    if not (amount and amount >= 1 and amount <= MAX_POOL and amount == floor(amount)) then
        ns.Print(TEXT_BAD_POOL:format(MAX_POOL))
        return nil
    end
    S.Set("gamblePool", amount)
    return amount
end

--- Validate settings and open a new host-owned session.
-- @local
local function NewGame()
    if not IsOn() then ns.Print(TEXT_NOT_ACTIVE); return end
    if game and game.phase ~= "complete" and not game.isHost then
        ns.Print(TEXT_NOT_HOST)
        return
    end
    if game and game.phase ~= "complete" and game.phase ~= "lobby" then
        ns.Print(TEXT_NOT_LOBBY)
        return
    end
    local channel = S.Get("gambleChannel")
    if not CHANNEL_LABEL[channel] then
        channel = "PARTY"
        S.Set("gambleChannel", channel)
    end
    if not ChannelAvailable(channel) then
        ns.Print(TEXT_NEED_GROUP)
        return
    end
    local pool = GetPool()
    if not pool then return end
    local joinWord, leaveWord = S.Get("gambleJoinWord"), S.Get("gambleLeaveWord")
    if not ValidWords(joinWord, leaveWord) then
        ns.Print(TEXT_BAD_WORD)
        return
    end
    if game and game.isHost and game.phase == "lobby" then
        SendAddon(AddonPayload("X"), game.channel)
    end
    game = nil
    local mode = S.Get("gambleMode")
    if mode ~= "deathroll" then mode = "classic" end
    game = {
        id = ("%d:%s"):format(floor(GetTime() * 1000), PlayerName()),
        pool = pool, mode = mode, channel = channel, phase = "lobby", isHost = true,
        hostKey = PlayerKey(PlayerName()), participants = {}, players = {},
        joinWord = joinWord, leaveWord = leaveWord,
    }
    UpdateListening()
    BroadcastOpen()
    SendChat(TEXT_STARTED:format(MODE_LABEL[mode], pool, game.joinWord, game.leaveWord), channel)
    UpdateDisplay()
end

--- Remind players how to join before the lobby starts.
-- @local
local function LastCall()
    if not (game and game.isHost and game.phase == "lobby") then ns.Print(TEXT_NOT_LOBBY); return end
    SendChat(TEXT_LAST:format(game.joinWord, CHANNEL_LABEL[game.channel]), game.channel)
end

--- Cancel the active session and notify its participants.
-- @local
local function CancelSession()
    if not game or game.phase == "complete" then ns.Print(TEXT_NO_GAME); return end
    if not game.isHost then ns.Print(TEXT_NOT_HOST); return end
    SendAddon(AddonPayload("X"), game.channel)
    SendChat(TEXT_CANCELLED:format(PlayerName()), game.channel)
    game.phase = "complete"
    game.cancelled = true
    UpdateListening()
    UpdateDisplay()
end

--- Announce who still needs to roll, or the active Deathroll turn and limit.
-- @local
local function AnnounceRolls()
    if not (game and game.isHost and game.round) then return end
    if game.phase == "deathroll" then
        local player = game.duel and game.duel.next or game.round.players[1]
        if player then SendChat(TEXT_NEXT_ROLL:format(player.name, game.round.max), game.channel) end
        return
    end
    if game.phase ~= "rolling" then return end
    local waiting = {}
    for _, player in ipairs(game.round.players) do
        if not game.round.rolls[player.key] then waiting[#waiting + 1] = player.name end
    end
    local message = #waiting > 0 and TEXT_STILL_NEED:format(Names(waiting), game.round.max)
        or TEXT_NO_ROLLS
    SendChat(message, game.channel)
end

--- Cycle the configured announcement channel through supported choices.
-- @local
local function CycleChannel()
    local current = S.Get("gambleChannel") or "PARTY"
    local nextIndex = 1
    for index, channel in ipairs(CHANNELS) do
        if channel == current then nextIndex = index % #CHANNELS + 1; break end
    end
    S.Set("gambleChannel", CHANNELS[nextIndex])
    ns.SetButtonText(channelButton, TEXT_CHANNEL:format(CHANNEL_LABEL[CHANNELS[nextIndex]]))
end

--- Validate and persist the join and leave words from the settings fields.
-- @local
local function SaveWords()
    local joinWord = trim(joinBox:GetText() or "")
    local leaveWord = trim(leaveBox:GetText() or "")
    if not ValidWords(joinWord, leaveWord) then
        ns.Print(TEXT_BAD_WORD)
        return
    end
    S.Set("gambleJoinWord", joinWord)
    S.Set("gambleLeaveWord", leaveWord)
    joinBox:SetText(joinWord)
    leaveBox:SetText(leaveWord)
end

--- Toggle the configured game mode between Classic and Deathroll.
-- @local
local function ToggleMode()
    S.Set("gambleMode", S.Get("gambleMode") == "deathroll" and "classic" or "deathroll")
    ns.SetButtonText(modeButton, TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")]))
end

--- Persist a valid pool value after the edit box loses focus or is submitted.
-- @local
local function SavePool()
    if not poolBox then return end
    GetPool()
    poolBox:ClearFocus()
end

--- Switch between the main controls and the scrollable how-to-play guide.
-- @local
-- @param show True to display the guide, false to show the game controls.
local function ShowHelp(show)
    if not helpView then return end
    if show then helpView:Show() else helpView:Hide() end
    if show then controls:Hide() else controls:Show() end
    if show then status:Hide() else status:Show() end
    if show then roster:Hide() else roster:Show() end
    if show then newButton:Hide() else newButton:Show() end
    if show then lastCallButton:Hide() else lastCallButton:Show() end
    if show then startButton:Hide() else startButton:Show() end
    if show then cancelButton:Hide() else cancelButton:Show() end
    ns.SetButtonText(helpButton, show and "Back to game" or "How to play")
end

--- Toggle the guide view without closing the Gamble window.
-- @local
local function ToggleHelp()
    ShowHelp(not helpView:IsShown())
end

--- Create the inline pool, channel, join/leave, and mode controls.
-- @local
local function CreateControls()
    controls = CreateFrame("Frame", nil, window)
    controls:SetPoint("TOPLEFT", window, "TOPLEFT", INSET, -(HEADER + INSET + ROW_GAP))
    controls:SetSize(WINDOW_W - INSET * 2, CONTROLS_H)
    local poolLabel = ns.Font(controls, 12, nil, T.muted)
    poolLabel:SetPoint("TOPLEFT", controls, "TOPLEFT", PAD, 0)
    poolLabel:SetText(TEXT_POOL)
    poolBox = ns.NewEditBox(controls, { inset = FIELD_INSET })
    poolBox:SetSize(POOL_W, POOL_H)
    poolBox:SetPoint("LEFT", poolLabel, "RIGHT", ROW_GAP, 0)
    poolBox:SetText(tostring(S.Get("gamblePool") or 200))
    poolBox:SetNumeric(true)
    poolBox:SetScript("OnEnterPressed", SavePool)
    poolBox:SetScript("OnEditFocusLost", SavePool)

    channelButton = ns.Button(controls, "", CHANNEL_W, CHANNEL_H, CycleChannel)
    channelButton:SetPoint("LEFT", poolBox, "RIGHT", ROW_GAP, 0)
    ns.SetButtonText(channelButton,
        TEXT_CHANNEL:format(CHANNEL_LABEL[S.Get("gambleChannel")] or CHANNEL_LABEL.PARTY))
    announceButton = ns.Button(controls, TEXT_ANNOUNCE, ANNOUNCE_W, CHANNEL_H, AnnounceRolls)
    announceButton:SetPoint("LEFT", channelButton, "RIGHT", ROW_GAP, 0)

    local configTop = POOL_H + ROW_GAP
    local joinLabel = ns.Font(controls, 12, nil, T.muted)
    joinLabel:SetPoint("TOPLEFT", controls, "TOPLEFT", PAD, -configTop)
    joinLabel:SetText(TEXT_JOIN_WORD)
    joinBox = ns.NewEditBox(controls, { inset = FIELD_INSET })
    joinBox:SetSize(CONFIG_FIELD_W, 26)
    joinBox:SetPoint("TOPLEFT", controls, "TOPLEFT", PAD, -(configTop + 16))
    joinBox:SetText(S.Get("gambleJoinWord") or "join")
    joinBox:SetScript("OnEnterPressed", SaveWords)
    joinBox:SetScript("OnEditFocusLost", SaveWords)

    local leaveLabel = ns.Font(controls, 12, nil, T.muted)
    leaveLabel:SetPoint("TOPLEFT", controls, "TOPLEFT", PAD + CONFIG_FIELD_W + 22, -configTop)
    leaveLabel:SetText(TEXT_LEAVE_WORD)
    leaveBox = ns.NewEditBox(controls, { inset = FIELD_INSET })
    leaveBox:SetSize(CONFIG_FIELD_W, 26)
    leaveBox:SetPoint("TOPLEFT", controls, "TOPLEFT", PAD + CONFIG_FIELD_W + 22, -(configTop + 16))
    leaveBox:SetText(S.Get("gambleLeaveWord") or "leave")
    leaveBox:SetScript("OnEnterPressed", SaveWords)
    leaveBox:SetScript("OnEditFocusLost", SaveWords)

    modeButton = ns.Button(controls, "", MODE_BUTTON_W, BUTTON_H, ToggleMode)
    modeButton:SetPoint("LEFT", leaveBox, "RIGHT", ROW_GAP, 0)
    ns.SetButtonText(modeButton, TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")] or MODE_LABEL.classic))
end

--- Build the main Gamble window, its controls, and its event hooks.
-- @local
local function CreateWindow()
    assert(type(ns.GambleHelpText) == "string", "Gamble help text was not loaded")
    window = Parts.Window(WINDOW_W, WINDOW_H, "gambleWindow")
    window.backdrop:Card(PAD, HEADER + PAD, PAD, FOOTER + PAD)
    local closeButton = Parts.TitleBar(window, TITLE, SUBTITLE, PAGE)
    helpButton = ns.Button(window, "How to play", 104, BUTTON_H, ToggleHelp)
    helpButton:SetPoint("RIGHT", closeButton, "LEFT", -ROW_GAP, 0)
    Parts.FooterBrand(window, PAGE)
    CreateControls()

    helpView = CreateFrame("Frame", nil, window)
    helpView:SetPoint("TOPLEFT", window, "TOPLEFT", INSET, -(HEADER + INSET))
    helpView:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -INSET, FOOTER + INSET)
    local helpScroll = ns.UI.SlimScroll(helpView)
    helpScroll:SetPoint("TOPLEFT")
    helpScroll:SetPoint("BOTTOMRIGHT", -8, 0)
    local helpContent = CreateFrame("Frame", nil, helpScroll)
    helpContent:SetSize(WINDOW_W - INSET * 2 - 32, 1)
    helpScroll:SetScrollChild(helpContent)
    local helpText = ns.Font(helpContent, 13, nil, T.fg)
    helpText:SetPoint("TOPLEFT", helpContent, "TOPLEFT", 0, 0)
    helpText:SetWidth(WINDOW_W - INSET * 2 - 32)
    helpText:SetJustifyH("LEFT")
    helpText:SetJustifyV("TOP")
    helpText:SetWordWrap(true)
    helpText:SetText(ns.GambleHelpText)
    local textHeight = helpText:GetStringHeight()
    helpContent:SetHeight(textHeight > 0 and textHeight or HELP_TEXT_HEIGHT)
    helpView:Hide()

    status = ns.Font(window, 13, "OUTLINE", T.accent)
    status:SetPoint("TOPLEFT", INSET, -(HEADER + INSET + CONTROLS_H + ROW_GAP))
    roster = ns.Font(window, 12)
    roster:SetPoint("TOPLEFT", INSET, -(HEADER + INSET + CONTROLS_H + ROW_GAP + 28))
    roster:SetPoint("RIGHT", -INSET, 0)
    roster:SetHeight(140)
    roster:SetJustifyH("LEFT")
    roster:SetJustifyV("TOP")

    newButton = ns.Button(window, TEXT_NEW, BUTTON_W, BUTTON_H, NewGame)
    lastCallButton = ns.Button(window, TEXT_LAST_CALL, BUTTON_W, BUTTON_H, LastCall)
    startButton = ns.AccentBorder(ns.Button(window, TEXT_START, BUTTON_W, BUTTON_H, StartRolling))
    cancelButton = ns.Button(window, TEXT_CANCEL, BUTTON_W, BUTTON_H, CancelSession)
    local rowWidth = BUTTON_W * 4 + BUTTON_GAP * 3
    local rowLeft = floor((WINDOW_W - rowWidth) / 2)
    local rowBottom = FOOTER + PAD + 6
    newButton:SetPoint("BOTTOMLEFT", rowLeft, rowBottom)
    lastCallButton:SetPoint("BOTTOMLEFT", rowLeft + BUTTON_W + BUTTON_GAP, rowBottom)
    startButton:SetPoint("BOTTOMLEFT", rowLeft + (BUTTON_W + BUTTON_GAP) * 2, rowBottom)
    cancelButton:SetPoint("BOTTOMLEFT", rowLeft + (BUTTON_W + BUTTON_GAP) * 3, rowBottom)
    window:HookScript("OnShow", function()
        UpdateListening()
        RequestOpenSessions()
        UpdateDisplay()
    end)
    window:HookScript("OnHide", UpdateListening)
    UpdateDisplay()
end

--- Toggle the Gamble window, lazily creating it on first use.
function ns.ToggleGamble()
    if not IsOn() then ns.Print(TEXT_NOT_ACTIVE); return end
    if not window then CreateWindow() end
    if window:IsShown() then
        window:Hide()
    else
        window:SetScale(ns.UIScale())
        window:Show()
        window.backdrop:Paint(1)
    end
end

--- React to Gamble-related setting changes and keep the window synchronized.
-- @local
-- @param key Setting name reported by the shared settings manager.
local function OnSettingChanged(key)
    if key == "enabled" or key == "gamble" then
        if not IsOn() then
            game = nil
            if window then window:Hide() end
        end
        UpdateListening()
    elseif key == "gambleChannel" and channelButton then
        local channel = game and game.phase ~= "complete" and game.channel or S.Get("gambleChannel")
        ns.SetButtonText(channelButton,
            TEXT_CHANNEL:format(CHANNEL_LABEL[channel] or CHANNEL_LABEL.PARTY))
    elseif key == "gambleMode" and modeButton then
        ns.SetButtonText(modeButton,
            TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")] or MODE_LABEL.classic))
    end
    UpdateDisplay()
end

--- Dispatch chat, system-roll, and addon-message events to their handlers.
-- @local
-- @param _ Frame receiving the event.
-- @param event WoW event name.
-- @param ... Event-specific arguments.
OnEvent = function(_, event, ...)
    if event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(...)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif CHAT_EVENTS[event] then
        OnChannelMessage(event, ...)
    end
end
S.OnChange(OnSettingChanged)
ns.Shared.Settings.Page(PAGE, S):Card({
    id = "gamble", name = "Gamble", order = 50, switch = "gamble",
    help = "Run Classic gambling sessions or a two-player Deathroll.",
    rows = {
        { label = "Open Gamble", buttonText = "Open", button = ns.ToggleGamble,
          help = "Opens the Gamble window." },
    },
})
