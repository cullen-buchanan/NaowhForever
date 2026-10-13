-- Gamble.lua: group gambling sessions with Classic rolls and Deathroll.
local ns = _G.NaowhForever

local Ambiguate, IsInGuild, IsInGroup, IsInRaid = Ambiguate, IsInGuild, IsInGroup, IsInRaid
local RandomRoll, UnitFullName, UnitName = RandomRoll, UnitFullName, UnitName
local abs, floor, random = math.abs, math.floor, math.random
local concat, remove = table.concat, table.remove
local lower, trim = strlower, strtrim
local RegisterAddonMessagePrefix = C_ChatInfo.RegisterAddonMessagePrefix
local SendAddonMessage, SendChatMessage = C_ChatInfo.SendAddonMessage, C_ChatInfo.SendChatMessage

local S = ns.QoLSettings
local T = ns.THEME
local Parts, St = ns.Shared.Parts, ns.Shared.Style

local PREFIX = "NaowhGamble"
local PAGE = "QoL/Questing & Group"
local WINDOW_W, WINDOW_H = 520, 470
local PAD, HEADER, FOOTER = St.WINDOW_PAD, St.WINDOW_HEADER, St.WINDOW_FOOTER
local INSET, ROW_GAP = 16, 10
local POOL_W, POOL_H = 100, 28
local CHANNEL_W, CHANNEL_H = 118, 28
local BUTTON_W, BUTTON_H, BUTTON_GAP = 148, 28, 10
local FIELD_INSET = 8
local MAX_POOL, MAX_WORD = 100000000, 24
local MAX_PARTICIPANTS, MAX_PLAYER_NAME, MAX_ROSTER_CHUNK = 40, 48, 150
local CHAT_EVENTS = {
    CHAT_MSG_PARTY = "PARTY", CHAT_MSG_PARTY_LEADER = "PARTY",
    CHAT_MSG_RAID = "RAID", CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_GUILD = "GUILD",
}
local CHANNELS = { "PARTY", "RAID", "GUILD" }
local CHANNEL_LABEL = { PARTY = "Party", RAID = "Raid", GUILD = "Guild" }
local MODE_LABEL = { classic = "Classic", deathroll = "Deathroll" }
local PATTERN_ESCAPE = {
    ["%"] = "%%", ["^"] = "%^", ["$"] = "%$", ["("] = "%(", [")"] = "%)",
    ["."] = "%.", ["["] = "%[", ["]"] = "%]", ["*"] = "%*", ["+"] = "%+",
    ["-"] = "%-", ["?"] = "%?",
}
local TITLE, SUBTITLE = "Gamble", "Classic rolls and Deathroll"
local TEXT_POOL = "Pool"
local TEXT_CHANNEL = "%s Chat"
local TEXT_NEW, TEXT_JOIN, TEXT_LAST_CALL = "New Game", "Join", "Last Call"
local TEXT_START, TEXT_ROLL, TEXT_OPTIONS = "Start Rolling", "Roll for Me", "Options"
local TEXT_NO_GAME = "Start a new session before joining."
local TEXT_NOT_LOBBY = "This session is already rolling."
local TEXT_NOT_HOST = "Only the session host can start a new session."
local TEXT_NEED_PLAYERS = "At least two players must join first."
local TEXT_BAD_POOL = "Enter a whole-number pool between 1 and %d."
local TEXT_BAD_WORD = "Join and leave words must be different single words without |."
local TEXT_NEED_GROUP = "Join a party or raid before using that chat channel."
local TEXT_NEED_GUILD = "Join a guild before using guild chat."
local TEXT_STARTED = "Gamble session started: %s, pool %d. Say \"%s\" to join."
local TEXT_LAST = "Last call: say \"%s\" in %s chat to join."
local TEXT_JOINED = "%s joined the Gamble session."
local TEXT_LEFT = "%s left the Gamble session."
local TEXT_ROLLS = "%s, please begin rolling from 1 to %d."
local TEXT_TIE = "Tie-break: %s, please reroll from 1 to %d."
local TEXT_DUEL = "Deathroll: %s and %s. %s, roll from 1 to %d."
local TEXT_TURN = "%s, roll from 1 to %d."
local TEXT_SETTLEMENT = "%s pays %s %d gold."
local TEXT_ROSTER = "No players have joined yet."
local TEXT_ROSTER_ROW = "%s  %s"
local TEXT_STATS = "This session: %s\nLifetime: %s"
local TEXT_STATS_NONE = "No settled games"
local TEXT_STATS_LINE = "%d game%s, %d win%s, %d loss%s, net %s gold"
local TEXT_MODE = "Game mode: %s"
local TEXT_SESSION_STATS = "Track session stats: %s"
local TEXT_LIFETIME_STATS = "Track lifetime stats: %s"
local TEXT_CLEAR_STATS = "Clear Stats"
local TEXT_CLEAR_ASK = "Clear all saved Gamble stats?"
local TEXT_JOIN_WORD = "Join word"
local TEXT_LEAVE_WORD = "Leave word"
local TEXT_SAVE, TEXT_CANCEL = "Save", "Close"
local TEXT_COMM_FAILED = "Gamble could not register its group message prefix."
local TEXT_NOT_ACTIVE = "Turn on Gamble under QoL > Questing & Group first."

local window, poolBox, channelButton, status, roster, stats
local options
local joinBox, leaveBox, modeButton, sessionStatsButton, lifetimeStatsButton
local joinButton, lastCallButton, startButton, rollButton
local events, prefixRegistered
local OnEvent
local game

local function PlayerKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    return lower(Ambiguate(name, "none"))
end

local function PlayerName()
    return UnitFullName("player") or UnitName("player") or "Player"
end

local function IsOn()
    return S.Get("enabled") and S.Get("gamble")
end

local function ValidWords(joinWord, leaveWord)
    return type(joinWord) == "string" and type(leaveWord) == "string"
        and joinWord:match("^%S+$") and leaveWord:match("^%S+$")
        and not joinWord:find("|", 1, true) and not leaveWord:find("|", 1, true)
        and #joinWord <= MAX_WORD and #leaveWord <= MAX_WORD
        and lower(joinWord) ~= lower(leaveWord)
end

local function ChannelAvailable(channel)
    if channel == "GUILD" then return IsInGuild() end
    if channel == "RAID" then return IsInRaid() end
    return channel == "PARTY" and IsInGroup() and not IsInRaid()
end

local function SendChat(text, channel)
    if not ChannelAvailable(channel) then
        ns.Print(channel == "GUILD" and TEXT_NEED_GUILD or TEXT_NEED_GROUP)
        return false
    end
    SendChatMessage(text, channel)
    return true
end

local function SendAddon(text, channel)
    if not ChannelAvailable(channel) then return false end
    SendAddonMessage(PREFIX, text, channel)
    return true
end

local function NeedEvents()
    return IsOn() and ((window and window:IsShown()) or (game and game.phase ~= "complete"))
end

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

local function SendAddonToAvailable(text)
    for _, channel in ipairs(CHANNELS) do
        if ChannelAvailable(channel) then SendAddon(text, channel) end
    end
end

local function RequestOpenSessions()
    SendAddonToAvailable("Q")
end

local function Names(players)
    local names = {}
    for i, player in ipairs(players) do names[i] = player.name end
    if #names < 3 then return concat(names, " and ") end
    return concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function FindPlayer(name)
    local key = PlayerKey(name)
    if not key or not game then return nil end
    return game.players[key]
end

local function AddPlayer(name)
    local key = PlayerKey(name)
    if not (key and game and not game.players[key]) then return false end
    if #game.participants >= MAX_PARTICIPANTS then return false end
    local player = { key = key, name = Ambiguate(name, "none") }
    game.players[key] = player
    game.participants[#game.participants + 1] = player
    return true
end

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

local function RosterMap(players)
    local out = {}
    for _, player in ipairs(players) do out[player.key] = player end
    return out
end

local function LifetimeStats()
    local account = ns.AccountSettings()
    if type(account.gambleStats) ~= "table" then account.gambleStats = {} end
    return account.gambleStats
end

local function StatsLine(entry)
    if type(entry) ~= "table" or not entry.games then return TEXT_STATS_NONE end
    local net = entry.net or 0
    local amount = tostring(abs(net))
    if net > 0 then amount = "+" .. amount elseif net < 0 then amount = "-" .. amount end
    return TEXT_STATS_LINE:format(entry.games, entry.games == 1 and "" or "s",
        entry.wins or 0, (entry.wins or 0) == 1 and "" or "s",
        entry.losses or 0, (entry.losses or 0) == 1 and "" or "s", amount)
end

local function UpdateEntry(store, player, won, amount)
    local entry = store[player.key]
    if type(entry) ~= "table" then
        entry = { games = 0, wins = 0, losses = 0, net = 0 }
        store[player.key] = entry
    end
    entry.games = entry.games + 1
    entry.net = entry.net + (won and amount or -amount)
    local field = won and "wins" or "losses"
    entry[field] = (entry[field] or 0) + 1
end

local function RecordResult(loserName, winnerName, amount)
    local loser, winner = FindPlayer(loserName), FindPlayer(winnerName)
    if not (loser and winner and amount > 0) then return end
    game.sessionStats = game.sessionStats or {}
    if S.Get("gambleSessionStats") then
        UpdateEntry(game.sessionStats, loser, false, amount)
        UpdateEntry(game.sessionStats, winner, true, amount)
    end
    if S.Get("gambleLifetimeStats") then
        local saved = LifetimeStats()
        UpdateEntry(saved, loser, false, amount)
        UpdateEntry(saved, winner, true, amount)
    end
end

local function UpdateDisplay()
    if not (window and window:IsShown()) then return end
    local phaseText = game and game.phase or "No session"
    if game and game.phase == "lobby" then phaseText = "Waiting for players" end
    if game and game.phase == "rolling" then phaseText = "Waiting for rolls" end
    if game and game.phase == "deathroll" then phaseText = "Deathroll in progress" end
    if game and game.phase == "complete" then phaseText = "Session complete" end
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

    local key = PlayerKey(PlayerName())
    local session = game and game.sessionStats and game.sessionStats[key]
    local saved = ns.AccountSettings().gambleStats
    local lifetime = key and type(saved) == "table" and saved[key]
    stats:SetText(TEXT_STATS:format(StatsLine(session), StatsLine(lifetime)))
    local channel = game and game.phase ~= "complete" and game.channel or S.Get("gambleChannel")
    channel = CHANNEL_LABEL[channel] and channel or "PARTY"
    ns.SetButtonText(channelButton, TEXT_CHANNEL:format(CHANNEL_LABEL[channel]))
    if game and game.phase ~= "complete" then poolBox:SetText(tostring(game.pool)) end
    ns.SetButtonText(joinButton, FindPlayer(PlayerName()) and "Joined" or TEXT_JOIN)
    joinButton:SetEnabled(game ~= nil and game.phase == "lobby" and not FindPlayer(PlayerName()))
    lastCallButton:SetEnabled(game ~= nil and game.phase == "lobby" and game.isHost)
    startButton:SetEnabled(game ~= nil and game.phase == "lobby" and game.isHost)
    rollButton:SetEnabled(game ~= nil and game.round ~= nil and key ~= nil
        and game.round.expected[key] ~= nil and game.round.rolls[key] == nil)
    channelButton:SetEnabled(not (game and game.phase ~= "complete"))
    poolBox:SetEnabled(not (game and game.phase ~= "complete"))
end

local function AddonPayload(kind, ...)
    if not game then return kind end
    return kind .. "|" .. game.id .. "|" .. concat({ ... }, "|")
end

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

local function BroadcastOpen()
    if not (game and game.isHost) then return end
    SendAddon(AddonPayload("O", game.pool, game.mode, game.joinWord, game.leaveWord, PlayerName()), game.channel)
end

local function SetClassicRound(players, max, tieBreak)
    local expected = RosterMap(players)
    game.phase = "rolling"
    game.round = { expected = expected, rolls = {}, players = players, max = max }
    game.rollMax = max
    if game.isHost then
        local announcement = tieBreak and TEXT_TIE:format(Names(players), max)
            or TEXT_ROLLS:format(Names(players), max)
        SendChat(announcement, game.channel)
        BroadcastRound()
    end
    UpdateDisplay()
end

local function SetDeathrollTurn(player, max)
    game.phase = "deathroll"
    game.round = { expected = { [player.key] = player }, rolls = {}, players = { player }, max = max }
    game.rollMax = max
    if game.isHost then
        SendChat(TEXT_TURN:format(player.name, max), game.channel)
        SendAddon(AddonPayload("T", max, player.name), game.channel)
    end
    UpdateDisplay()
end

local function StartDeathroll()
    local players = game.participants
    local firstIndex, secondIndex = random(#players), random(#players - 1)
    if secondIndex >= firstIndex then secondIndex = secondIndex + 1 end
    local first, second = players[firstIndex], players[secondIndex]
    if random(2) == 2 then first, second = second, first end
    game.duel = { first = first, second = second, next = first, pot = game.pool }
    SendChat(TEXT_DUEL:format(first.name, second.name, first.name, game.pool), game.channel)
    SendAddon(AddonPayload("M", game.pool, first.name, second.name, first.name), game.channel)
    SetDeathrollTurn(first, game.pool)
end

local function StartRolling()
    if not (game and game.isHost and game.phase == "lobby") then return end
    if #game.participants < 2 then
        ns.Print(TEXT_NEED_PLAYERS)
        return
    end
    if game.mode == "deathroll" then
        StartDeathroll()
    else
        SetClassicRound(game.participants, game.pool, false)
    end
end

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
        SetClassicRound(tied, game.pool, true)
        return
    end
    local loser, winner = lows[1], highs[1]
    local amount = high - low
    if loser and winner and loser ~= winner and amount > 0 then
        RecordResult(loser.name, winner.name, amount)
        SendChat(TEXT_SETTLEMENT:format(loser.name, winner.name, amount), game.channel)
        SendAddon(AddonPayload("D", loser.name, winner.name, amount), game.channel)
    end
    game.phase = "complete"
    UpdateListening()
    UpdateDisplay()
end

local function DeathrollResult(player, value)
    local duel = game.duel
    if not duel then return end
    if value == 1 then
        local winner = player.key == duel.first.key and duel.second or duel.first
        RecordResult(player.name, winner.name, duel.pot)
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

local function CompileRollPattern(format)
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
    if captures ~= 4 then return nil end
    return concat(pattern)
end

local ROLL_PATTERN = CompileRollPattern(RANDOM_ROLL_RESULT)

local function OnSystemMessage(message)
    if not (ROLL_PATTERN and game and game.round) then return end
    local name, value, minimum, maximum = tostring(message):match(ROLL_PATTERN)
    if not name then return end
    OnRoll(name, tonumber(value), tonumber(minimum), tonumber(maximum))
end

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

local function OpenPayload(sender, channel, id, pool, mode, joinWord, leaveWord, ownerName)
    local amount = tonumber(pool)
    if not (amount and amount >= 1 and amount <= MAX_POOL and amount == floor(amount)
        and (mode == "classic" or mode == "deathroll") and #id <= 64
        and ValidWords(joinWord, leaveWord) and #ownerName <= 48) then return end
    if game and game.phase ~= "complete" then return end
    game = {
        id = id, pool = amount, mode = mode, channel = channel, phase = "lobby",
        hostKey = PlayerKey(sender), isHost = false, participants = {}, players = {}, sessionStats = {},
        joinWord = joinWord, leaveWord = leaveWord, hostName = Ambiguate(ownerName, "none"),
    }
    UpdateListening()
    UpdateDisplay()
end

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
            RecordResult(loser, winner, amount)
            game.phase = "complete"
            UpdateListening()
            UpdateDisplay()
        end
    elseif kind == "X" then
        game.phase = "complete"
        UpdateListening()
        UpdateDisplay()
    end
end

function OnEvent(_, event, ...)
    if event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(...)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif CHAT_EVENTS[event] then
        OnChannelMessage(event, ...)
    end
end

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
    local channel = S.Get("gambleChannel") or "PARTY"
    if not ChannelAvailable(channel) then
        ns.Print(channel == "GUILD" and TEXT_NEED_GUILD or TEXT_NEED_GROUP)
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
        hostKey = PlayerKey(PlayerName()), participants = {}, players = {}, sessionStats = {},
        joinWord = joinWord, leaveWord = leaveWord,
    }
    UpdateListening()
    BroadcastOpen()
    SendChat(TEXT_STARTED:format(MODE_LABEL[mode], pool, game.joinWord), channel)
    UpdateDisplay()
end

local function Join()
    if not (game and game.phase == "lobby") then ns.Print(TEXT_NO_GAME); return end
    if FindPlayer(PlayerName()) then return end
    if AddPlayer(PlayerName()) then
        SendChat(game.joinWord, game.channel)
        if game.isHost then
            SendChat(TEXT_JOINED:format(PlayerName()), game.channel)
            BroadcastRoster()
        else
            SendAddon(AddonPayload("J"), game.channel)
        end
        UpdateDisplay()
    end
end

local function LastCall()
    if not (game and game.isHost and game.phase == "lobby") then ns.Print(TEXT_NOT_LOBBY); return end
    SendChat(TEXT_LAST:format(game.joinWord, CHANNEL_LABEL[game.channel]), game.channel)
end

local function RollForPlayer()
    local key = PlayerKey(PlayerName())
    local round = game and game.round
    if not (round and round.expected[key] and not round.rolls[key]) then return end
    RandomRoll(1, round.max)
end

local function CycleChannel()
    local current = S.Get("gambleChannel") or "PARTY"
    local nextIndex = 1
    for index, channel in ipairs(CHANNELS) do
        if channel == current then nextIndex = index % #CHANNELS + 1; break end
    end
    S.Set("gambleChannel", CHANNELS[nextIndex])
    ns.SetButtonText(channelButton, TEXT_CHANNEL:format(CHANNEL_LABEL[CHANNELS[nextIndex]]))
end

local function SaveOptions()
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
    if options then options:Hide() end
end

local function ClearStats()
    ns.Confirm(TEXT_CLEAR_ASK, function()
        ns.AccountSettings().gambleStats = {}
        if game then game.sessionStats = {} end
        UpdateDisplay()
    end)
end

local function ToggleMode()
    S.Set("gambleMode", S.Get("gambleMode") == "deathroll" and "classic" or "deathroll")
    ns.SetButtonText(modeButton, TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")]))
end

local function ToggleSessionStats()
    S.Set("gambleSessionStats", not S.Get("gambleSessionStats"))
    ns.SetButtonText(sessionStatsButton, TEXT_SESSION_STATS:format(S.Get("gambleSessionStats") and "On" or "Off"))
end

local function ToggleLifetimeStats()
    S.Set("gambleLifetimeStats", not S.Get("gambleLifetimeStats"))
    ns.SetButtonText(lifetimeStatsButton, TEXT_LIFETIME_STATS:format(S.Get("gambleLifetimeStats") and "On" or "Off"))
end

local function BuildOptionsView(scroll)
    local view = CreateFrame("Frame", nil, scroll)
    view:SetHeight(380)
    local label = ns.Font(view, 12, nil, T.muted)
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(TEXT_JOIN_WORD)
    joinBox = ns.NewEditBox(view, { inset = FIELD_INSET })
    joinBox:SetSize(240, 26)
    joinBox:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)

    label = ns.Font(view, 12, nil, T.muted)
    label:SetPoint("TOPLEFT", joinBox, "BOTTOMLEFT", 0, -ROW_GAP)
    label:SetText(TEXT_LEAVE_WORD)
    leaveBox = ns.NewEditBox(view, { inset = FIELD_INSET })
    leaveBox:SetSize(240, 26)
    leaveBox:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)

    modeButton = ns.Button(view, "", 260, BUTTON_H, ToggleMode)
    modeButton:SetPoint("TOPLEFT", leaveBox, "BOTTOMLEFT", 0, -ROW_GAP)
    sessionStatsButton = ns.Button(view, "", 260, BUTTON_H, ToggleSessionStats)
    sessionStatsButton:SetPoint("TOPLEFT", modeButton, "BOTTOMLEFT", 0, -ROW_GAP)
    lifetimeStatsButton = ns.Button(view, "", 260, BUTTON_H, ToggleLifetimeStats)
    lifetimeStatsButton:SetPoint("TOPLEFT", sessionStatsButton, "BOTTOMLEFT", 0, -ROW_GAP)
    local clear = ns.Button(view, TEXT_CLEAR_STATS, 140, BUTTON_H, ClearStats)
    clear:SetPoint("TOPLEFT", lifetimeStatsButton, "BOTTOMLEFT", 0, -ROW_GAP)

    joinBox:SetText(S.Get("gambleJoinWord") or "join")
    leaveBox:SetText(S.Get("gambleLeaveWord") or "leave")
    ns.SetButtonText(modeButton, TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")] or MODE_LABEL.classic))
    ns.SetButtonText(sessionStatsButton,
        TEXT_SESSION_STATS:format(S.Get("gambleSessionStats") and "On" or "Off"))
    ns.SetButtonText(lifetimeStatsButton,
        TEXT_LIFETIME_STATS:format(S.Get("gambleLifetimeStats") and "On" or "Off"))
    return view
end

local function OpenOptions()
    if not options then
        options = Parts.SidePanel({ { TEXT_SAVE, SaveOptions }, { TEXT_CANCEL, function() options:Hide() end } },
            BuildOptionsView, function() return 1 end)
        options.title:SetText("Gamble Options")
    end
    joinBox:SetText(S.Get("gambleJoinWord") or "join")
    leaveBox:SetText(S.Get("gambleLeaveWord") or "leave")
    ns.SetButtonText(modeButton, TEXT_MODE:format(MODE_LABEL[S.Get("gambleMode")] or MODE_LABEL.classic))
    Parts.ShowBeside(options, window)
end

local function SavePool()
    if not poolBox then return end
    GetPool()
    poolBox:ClearFocus()
end

local function CreateWindow()
    window = Parts.Window(WINDOW_W, WINDOW_H, "gambleWindow")
    window.backdrop:Card(PAD, HEADER + PAD, PAD, FOOTER + PAD)
    Parts.TitleBar(window, TITLE, SUBTITLE, PAGE)
    Parts.FooterBrand(window, PAGE)

    local poolLabel = ns.Font(window, 12, nil, T.muted)
    poolLabel:SetPoint("TOPLEFT", INSET, -(HEADER + ROW_GAP))
    poolLabel:SetText(TEXT_POOL)
    poolBox = ns.NewEditBox(window, { inset = FIELD_INSET })
    poolBox:SetSize(POOL_W, POOL_H)
    poolBox:SetPoint("LEFT", poolLabel, "RIGHT", ROW_GAP, 0)
    poolBox:SetText(tostring(S.Get("gamblePool") or 200))
    poolBox:SetNumeric(true)
    poolBox:SetScript("OnEnterPressed", SavePool)
    poolBox:SetScript("OnEditFocusLost", SavePool)

    channelButton = ns.Button(window, "", CHANNEL_W, CHANNEL_H, CycleChannel)
    channelButton:SetPoint("LEFT", poolBox, "RIGHT", ROW_GAP, 0)
    ns.SetButtonText(channelButton,
        TEXT_CHANNEL:format(CHANNEL_LABEL[S.Get("gambleChannel")] or CHANNEL_LABEL.PARTY))

    status = ns.Font(window, 13, "OUTLINE", T.accent)
    status:SetPoint("TOPLEFT", INSET, -(HEADER + 62))
    roster = ns.Font(window, 12)
    roster:SetPoint("TOPLEFT", INSET, -(HEADER + 90))
    roster:SetPoint("RIGHT", -INSET, 0)
    roster:SetHeight(140)
    roster:SetJustifyH("LEFT")
    roster:SetJustifyV("TOP")

    stats = ns.Font(window, 11, nil, T.muted)
    stats:SetPoint("BOTTOMLEFT", INSET, FOOTER + PAD + 80)
    stats:SetPoint("RIGHT", -INSET, 0)
    stats:SetJustifyH("LEFT")

    local newButton = ns.Button(window, TEXT_NEW, BUTTON_W, BUTTON_H, NewGame)
    joinButton = ns.Button(window, TEXT_JOIN, BUTTON_W, BUTTON_H, Join)
    lastCallButton = ns.Button(window, TEXT_LAST_CALL, BUTTON_W, BUTTON_H, LastCall)
    startButton = ns.AccentBorder(ns.Button(window, TEXT_START, BUTTON_W, BUTTON_H, StartRolling))
    rollButton = ns.Button(window, TEXT_ROLL, BUTTON_W, BUTTON_H, RollForPlayer)
    local openOptionsButton = ns.Button(window, TEXT_OPTIONS, BUTTON_W, BUTTON_H, OpenOptions)
    local buttons = { newButton, joinButton, lastCallButton }
    for index, button in ipairs(buttons) do
        button:SetPoint("BOTTOMLEFT", INSET + (index - 1) * (BUTTON_W + BUTTON_GAP), FOOTER + PAD + 42)
    end
    local bottomButtons = { startButton, rollButton, openOptionsButton }
    for index, button in ipairs(bottomButtons) do
        button:SetPoint("BOTTOMLEFT", INSET + (index - 1) * (BUTTON_W + BUTTON_GAP), FOOTER + PAD + 6)
    end
    window:HookScript("OnShow", function()
        UpdateListening()
        RequestOpenSessions()
        UpdateDisplay()
    end)
    window:HookScript("OnHide", UpdateListening)
    UpdateDisplay()
end

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

local function OnSettingChanged(key)
    if key == "enabled" or key == "gamble" then
        if not IsOn() then
            game = nil
            if options then options:Hide() end
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
