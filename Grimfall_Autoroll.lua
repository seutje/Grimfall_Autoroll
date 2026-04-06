local ADDON_NAME = ...
local ITEM_ID = 10901
local ITEM_NAME = "Destiny's Dice"
local MAX_SLOTS = 4
local SPELL_SCAN_MAX_ID = 80000
local SPELL_SCAN_CHUNK = 750
local SPELL_SCAN_REFRESH_STEP = 4500
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local CIRCLE_TEXTURE = "Interface\\AddOns\\Grimfall_Autoroll\\Media\\circle.tga"
local GAME_BOARD_WIDTH = 332
local GAME_BOARD_HEIGHT = 222
local GAME_PEG_RADIUS = 5
local GAME_BALL_RADIUS = 4
local GAME_LAUNCH_SPEED = 350
local GAME_GRAVITY = 520
local GAME_MAX_STEP = 0.02
local GAME_COLLISION_COOLDOWN = 0.05
local GAME_MIN_ORANGE = 5

local GFAR = CreateFrame("Frame", "GFAR_EventFrame")
GFAR:RegisterEvent("ADDON_LOADED")
GFAR:RegisterEvent("SPELLS_CHANGED")
GFAR:RegisterEvent("LEARNED_SPELL_IN_TAB")
GFAR:RegisterEvent("UNIT_AURA")
GFAR:RegisterEvent("BAG_UPDATE")
GFAR:RegisterEvent("BAG_UPDATE_COOLDOWN")

GFAR.spellCatalog = {}
GFAR.spellCatalogByKey = {}
GFAR.filteredSpells = {}
GFAR.scanState = {
    active = false,
    complete = false,
    nextId = 1,
    refreshProgress = 0,
}
GFAR.game = {
    level = 1,
    pegs = {},
    aimX = GAME_BOARD_WIDTH * 0.5,
    aimY = 84,
    pegsRemaining = 0,
    orangeLeft = 0,
    boardEnabled = false,
    refreshElapsed = 0,
    ball = {
        active = false,
        x = GAME_BOARD_WIDTH * 0.5,
        y = 18,
        vx = 0,
        vy = 0,
        collisionCooldown = 0,
    },
}

local defaults = {
    abilities = { nil, nil, nil, nil },
    position = {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
    },
}

local UpdateStatus
local OpenSpellPicker
local ApplySpellFilter
local UpdateSpellList
local RefreshPickerStatus
local StartSpellCatalogScan
local CreatePeggleBoard
local GeneratePeggleLevel
local UpdatePeggleInfo
local UpdatePeggleAim
local StartPeggleShot

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GFAR|r: " .. message)
end

local function Trim(text)
    local value = text or ""
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

local function NormalizeName(text)
    return string.lower(Trim(text))
end

local function Clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end

    if value > maximum then
        return maximum
    end

    return value
end

local function Atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end

    if x > 0 then
        return math.atan(y / x)
    end

    if x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    end

    if x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    end

    if y > 0 then
        return math.pi * 0.5
    end

    if y < 0 then
        return -math.pi * 0.5
    end

    return 0
end

local function Noise(level, index, salt)
    local value = math.sin((level * 97.13) + (index * 57.29) + (salt * 17.71)) * 43758.5453
    return value - math.floor(value)
end

local function GetItemIdFromLink(itemLink)
    if not itemLink then
        return nil
    end

    local itemId = string.match(itemLink, "item:(%d+)")
    if itemId then
        return tonumber(itemId)
    end

    return nil
end

local function ResolveSpellEntry(spellID, name, icon)
    local resolvedId = tonumber(spellID)
    local resolvedName = Trim(name)
    local resolvedIcon = icon

    if resolvedId then
        local spellName, _, spellIcon = GetSpellInfo(resolvedId)
        if spellName then
            resolvedName = spellName
            resolvedIcon = spellIcon or resolvedIcon
        end
    end

    if resolvedName == "" and resolvedId then
        local spellName, _, spellIcon = GetSpellInfo(resolvedId)
        if spellName then
            resolvedName = spellName
            resolvedIcon = spellIcon or resolvedIcon
        end
    end

    if resolvedName == "" then
        return nil
    end

    if not resolvedIcon or resolvedIcon == "" then
        local _, _, spellIcon = GetSpellInfo(resolvedName)
        resolvedIcon = spellIcon or EMPTY_ICON
    end

    return {
        spellID = resolvedId,
        name = resolvedName,
        icon = resolvedIcon or EMPTY_ICON,
        searchName = NormalizeName(resolvedName),
    }
end

local function GetSpellLinkForEntry(entry)
    if not entry then
        return nil
    end

    if entry.spellID then
        local spellLink = GetSpellLink(entry.spellID)
        if spellLink then
            return spellLink
        end
    end

    if entry.name and entry.name ~= "" then
        return GetSpellLink(entry.name)
    end

    return nil
end

local function TryInsertSpellLink(entry)
    if not entry or not IsModifiedClick("CHATLINK") then
        return false
    end

    local spellLink = GetSpellLinkForEntry(entry)
    if not spellLink then
        return false
    end

    return ChatEdit_InsertLink(spellLink)
end

local function EnsureSavedVariables()
    if type(GFAR_Saved) ~= "table" then
        GFAR_Saved = {}
    end

    if type(GFAR_Saved.abilities) ~= "table" then
        GFAR_Saved.abilities = {}
    end

    if type(GFAR_Saved.position) ~= "table" then
        GFAR_Saved.position = {}
    end

    for i = 1, MAX_SLOTS do
        local entry = GFAR_Saved.abilities[i]

        if type(entry) == "string" then
            GFAR_Saved.abilities[i] = ResolveSpellEntry(nil, entry)
        elseif type(entry) == "table" then
            GFAR_Saved.abilities[i] = ResolveSpellEntry(entry.spellID or entry.id, entry.name or entry.spellName, entry.icon)
        else
            GFAR_Saved.abilities[i] = defaults.abilities[i]
        end
    end

    local position = GFAR_Saved.position
    position.point = position.point or defaults.position.point
    position.relativePoint = position.relativePoint or defaults.position.relativePoint
    position.x = position.x or defaults.position.x
    position.y = position.y or defaults.position.y
end

local function GetConfiguredAbilities()
    local abilities = {}

    for i = 1, MAX_SLOTS do
        local entry = GFAR_Saved.abilities[i]
        if entry and entry.name and Trim(entry.name) ~= "" then
            table.insert(abilities, entry)
        end
    end

    return abilities
end

local function BuildAbilityNameList(entries)
    local names = {}

    for _, entry in ipairs(entries) do
        table.insert(names, entry.name)
    end

    return table.concat(names, ", ")
end

local function HasAuraByName(spellName)
    local target = NormalizeName(spellName)

    for i = 1, 40 do
        local auraName = UnitBuff("player", i)
        if not auraName then
            break
        end

        if NormalizeName(auraName) == target then
            return true
        end
    end

    return false
end

local function HasSpellbookSpellByName(spellName)
    local target = NormalizeName(spellName)
    local numTabs = GetNumSpellTabs()

    for tab = 1, numTabs do
        local _, _, offset, numSpells = GetSpellTabInfo(tab)
        for spellIndex = offset + 1, offset + numSpells do
            local knownName = GetSpellName(spellIndex, BOOKTYPE_SPELL)
            if knownName and NormalizeName(knownName) == target then
                return true
            end
        end
    end

    return false
end

local function PlayerHasAbility(entry)
    if not entry or not entry.name then
        return false
    end

    return HasSpellbookSpellByName(entry.name) or HasAuraByName(entry.name)
end

local function GetAbilityProgress()
    local configured = GetConfiguredAbilities()
    local matched = {}
    local missing = {}

    for _, entry in ipairs(configured) do
        if PlayerHasAbility(entry) then
            table.insert(matched, entry)
        else
            table.insert(missing, entry)
        end
    end

    return configured, matched, missing
end

local function FindDiceInBags()
    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local itemId = GetItemIdFromLink(itemLink)
                local itemName = GetItemInfo(itemLink)

                if itemId == ITEM_ID or (not ITEM_ID and itemName == ITEM_NAME) then
                    return bag, slot
                end
            end
        end
    end

    return nil, nil
end

local function IsDiceOnCooldown()
    local startTime, duration, enable = GetItemCooldown(ITEM_ID)
    if enable == 0 or not startTime or not duration then
        return false
    end

    if startTime <= 0 or duration <= 0 then
        return false
    end

    return ((startTime + duration) - GetTime()) > 0.15
end

local function SaveFramePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    GFAR_Saved.position.point = point
    GFAR_Saved.position.relativePoint = relativePoint
    GFAR_Saved.position.x = x
    GFAR_Saved.position.y = y
end

local function SetStatusText(message)
    if GFAR.statusText then
        GFAR.statusText:SetText(message)
    end
end

local function SetMatchText(message)
    if GFAR.matchText then
        GFAR.matchText:SetText(message)
    end
end

local function SetAbilityForSlot(index, entry)
    GFAR_Saved.abilities[index] = ResolveSpellEntry(entry and entry.spellID, entry and entry.name, entry and entry.icon)
end

local function ClearAbilitySlot(index)
    GFAR_Saved.abilities[index] = nil
end

local function UpdateAbilitySlotDisplay(slotFrame)
    local entry = GFAR_Saved.abilities[slotFrame.slotIndex]
    local hasAbility = entry and PlayerHasAbility(entry)

    if entry then
        slotFrame.icon:SetTexture(entry.icon or EMPTY_ICON)
        slotFrame.nameText:SetText(entry.name)
        if hasAbility then
            slotFrame.nameText:SetTextColor(0.3, 1.0, 0.3)
            slotFrame.button:SetBackdropBorderColor(0.2, 0.9, 0.2, 1)
        else
            slotFrame.nameText:SetTextColor(1.0, 0.82, 0)
            slotFrame.button:SetBackdropBorderColor(0.9, 0.8, 0.5, 1)
        end
    else
        slotFrame.icon:SetTexture(EMPTY_ICON)
        slotFrame.nameText:SetText("Click to choose")
        slotFrame.nameText:SetTextColor(0.7, 0.7, 0.7)
        slotFrame.button:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
    end
end

local function RefreshAbilitySlots()
    if not GFAR.mainFrame or not GFAR.mainFrame.slots then
        return
    end

    for i = 1, MAX_SLOTS do
        UpdateAbilitySlotDisplay(GFAR.mainFrame.slots[i])
    end
end

local function UpdateButtonState()
    if not GFAR.gameBoard then
        return
    end

    local configured, _, missing = GetAbilityProgress()
    local bag, slot = FindDiceInBags()
    local canShoot = false
    local message = "Aim with the cursor and click the board to shoot Destiny's Dice."

    if #configured == 0 then
        message = "Choose 1 to 4 abilities before taking a shot."
    elseif #missing == 0 then
        message = "All requested abilities are already active. No shot needed."
    elseif not bag or not slot then
        message = "Destiny's Dice is missing from your bags."
    elseif GFAR.game.ball.active then
        message = "Ball in play. Wait for it to drain before clicking again."
    elseif IsDiceOnCooldown() then
        message = "Destiny's Dice is on cooldown."
    else
        canShoot = true
    end

    GFAR.game.boardEnabled = canShoot

    if canShoot then
        GFAR.gameBoard:Enable()
        GFAR.gameBoard:SetBackdropBorderColor(0.85, 0.72, 0.3, 1)
    else
        GFAR.gameBoard:Disable()
        GFAR.gameBoard:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    if GFAR.boardPromptText then
        GFAR.boardPromptText:SetText(message)
    end
end

UpdateStatus = function()
    local configured, matched, missing = GetAbilityProgress()

    RefreshAbilitySlots()

    if #configured == 0 then
        SetStatusText("Choose 1 to 4 abilities, then click the Peggle board.")
        SetMatchText("Found: none")
        UpdateButtonState()
        return
    end

    if #missing == 0 then
        SetStatusText("All selected abilities are currently available.")
        SetMatchText("Found: " .. BuildAbilityNameList(matched))
        UpdateButtonState()
        return
    end

    local bag, slot = FindDiceInBags()
    if not bag or not slot then
        SetStatusText("Missing: " .. BuildAbilityNameList(missing) .. " | Destiny's Dice not found.")
    else
        SetStatusText("Missing: " .. BuildAbilityNameList(missing))
    end

    if #matched > 0 then
        SetMatchText("Found: " .. BuildAbilityNameList(matched))
    else
        SetMatchText("Found: none")
    end

    UpdateButtonState()
end

local function SetBoardRegionPoint(board, region, x, y)
    region:ClearAllPoints()
    region:SetPoint("CENTER", board, "TOPLEFT", x, -y)
end

local function GetPegColor(isOrange)
    if isOrange then
        return 1.0, 0.48, 0.12
    end

    return 0.18, 0.72, 1.0
end

local function HidePegVisual(visual)
    visual.glow:Hide()
    visual.core:Hide()
    visual.highlight:Hide()
end

local function AcquirePegVisual(board, index)
    if board.pegPool[index] then
        return board.pegPool[index]
    end

    local visual = {}

    visual.glow = board:CreateTexture(nil, "BACKGROUND")
    visual.glow:SetTexture(CIRCLE_TEXTURE)
    visual.glow:SetWidth(13)
    visual.glow:SetHeight(13)
    visual.glow:SetBlendMode("ADD")

    visual.core = board:CreateTexture(nil, "ARTWORK")
    visual.core:SetTexture(CIRCLE_TEXTURE)
    visual.core:SetWidth(7)
    visual.core:SetHeight(7)

    visual.highlight = board:CreateTexture(nil, "OVERLAY")
    visual.highlight:SetTexture(CIRCLE_TEXTURE)
    visual.highlight:SetWidth(3)
    visual.highlight:SetHeight(3)
    visual.highlight:SetVertexColor(1, 1, 1, 0.9)

    board.pegPool[index] = visual
    return visual
end

local function SetPegVisual(board, peg, index)
    local visual = AcquirePegVisual(board, index)
    local red, green, blue = GetPegColor(peg.isOrange)

    peg.visual = visual
    SetBoardRegionPoint(board, visual.glow, peg.x, peg.y)
    SetBoardRegionPoint(board, visual.core, peg.x, peg.y)
    SetBoardRegionPoint(board, visual.highlight, peg.x - 1.5, peg.y - 1.5)

    visual.glow:SetVertexColor(red, green, blue, 0.42)
    visual.core:SetVertexColor(red, green, blue, 0.95)
    visual.highlight:Show()
    visual.glow:Show()
    visual.core:Show()
end

local function HideAllPegVisuals(board)
    for _, visual in ipairs(board.pegPool) do
        HidePegVisual(visual)
    end
end

local function SetBallPosition(board, ball)
    SetBoardRegionPoint(board, board.ballGlow, ball.x, ball.y)
    SetBoardRegionPoint(board, board.ballTexture, ball.x, ball.y)
    SetBoardRegionPoint(board, board.ballSpark, ball.x - 3, ball.y - 3)
end

local function HideAimPreview(board)
    for _, dot in ipairs(board.aimDots) do
        dot:Hide()
    end
end

local function DrawAimPreviewSegment(board, startX, startY, endX, endY, startIndex, alpha)
    local deltaX = endX - startX
    local deltaY = endY - startY
    local length = math.sqrt((deltaX * deltaX) + (deltaY * deltaY))
    local dotIndex = startIndex
    local spacing = 10

    if length <= 1 then
        return dotIndex
    end

    local steps = math.max(2, math.floor(length / spacing) + 1)
    for step = 0, steps do
        local t = step / steps
        local dot = board.aimDots[dotIndex]
        if not dot then
            return dotIndex
        end

        SetBoardRegionPoint(board, dot, startX + (deltaX * t), startY + (deltaY * t))
        dot:SetVertexColor(1.0, 0.92, 0.48, alpha)
        dot:Show()
        dotIndex = dotIndex + 1
    end

    return dotIndex
end

local function UpdateAimPreview(board)
    local spawnX = GAME_BOARD_WIDTH * 0.5
    local spawnY = 18
    local deltaX = GFAR.game.aimX - spawnX
    local deltaY = math.max(GFAR.game.aimY - spawnY, 30)
    local distance = math.sqrt((deltaX * deltaX) + (deltaY * deltaY))
    local directionX
    local directionY
    local minX = GAME_BALL_RADIUS
    local maxX = GAME_BOARD_WIDTH - GAME_BALL_RADIUS
    local maxY = GAME_BOARD_HEIGHT - GAME_BALL_RADIUS

    if GFAR.game.ball.active then
        HideAimPreview(board)
        return
    end

    if distance < 0.001 then
        HideAimPreview(board)
        return
    end

    HideAimPreview(board)

    directionX = deltaX / distance
    directionY = deltaY / distance

    local sideTime = nil
    if directionX > 0.001 then
        sideTime = (maxX - spawnX) / directionX
    elseif directionX < -0.001 then
        sideTime = (minX - spawnX) / directionX
    end

    local bottomTime = (maxY - spawnY) / math.max(directionY, 0.001)
    local firstTime = bottomTime
    local bounced = false

    if sideTime and sideTime > 0 and sideTime < firstTime then
        firstTime = sideTime
        bounced = true
    end

    local firstEndX = spawnX + (directionX * firstTime)
    local firstEndY = spawnY + (directionY * firstTime)
    local nextDotIndex = DrawAimPreviewSegment(board, spawnX, spawnY, firstEndX, firstEndY, 1, 0.6)

    if not bounced then
        return
    end

    directionX = -directionX
    local secondSideTime = nil
    if directionX > 0.001 then
        secondSideTime = (maxX - firstEndX) / directionX
    elseif directionX < -0.001 then
        secondSideTime = (minX - firstEndX) / directionX
    end

    local secondBottomTime = (maxY - firstEndY) / math.max(directionY, 0.001)
    local secondTime = secondBottomTime

    if secondSideTime and secondSideTime > 0 and secondSideTime < secondTime then
        secondTime = secondSideTime
    end

    local secondEndX = firstEndX + (directionX * secondTime)
    local secondEndY = firstEndY + (directionY * secondTime)
    DrawAimPreviewSegment(board, firstEndX, firstEndY, secondEndX, secondEndY, nextDotIndex, 0.35)
end

local function SetPegHit(peg)
    peg.hit = true
    if peg.visual then
        HidePegVisual(peg.visual)
    end
end

UpdatePeggleInfo = function(message)
    if not GFAR.courseText then
        return
    end

    local game = GFAR.game
    local summary = string.format("Course %d | Orange %d | Pegs %d", game.level, game.orangeLeft, game.pegsRemaining)
    GFAR.courseText:SetText(summary)

    if GFAR.courseHintText then
        GFAR.courseHintText:SetText(message or "Aim with the cursor and click the board to shoot Destiny's Dice.")
    end
end

local function StopPeggleBall(message)
    local game = GFAR.game
    game.ball.active = false
    GFAR.gameBoard.ballTexture:Hide()
    GFAR.gameBoard.ballGlow:Hide()
    GFAR.gameBoard.ballSpark:Hide()

    if game.orangeLeft <= 0 or game.pegsRemaining <= 0 then
        GeneratePeggleLevel(game.level + 1)
        UpdatePeggleInfo("Course cleared. A new procedurally generated board is ready.")
    else
        UpdatePeggleInfo(message or "Shot drained. Line up the next autoroll shot.")
        UpdateButtonState()
    end
end

local function UpdatePeggleBall(elapsed)
    local board = GFAR.gameBoard
    local game = GFAR.game
    local ball = game.ball

    if not board or not ball.active then
        return
    end

    local remaining = elapsed

    while remaining > 0 do
        local step = remaining
        if step > GAME_MAX_STEP then
            step = GAME_MAX_STEP
        end
        remaining = remaining - step

        ball.collisionCooldown = math.max(0, ball.collisionCooldown - step)
        ball.vy = ball.vy + (GAME_GRAVITY * step)
        ball.x = ball.x + (ball.vx * step)
        ball.y = ball.y + (ball.vy * step)

        if ball.x < GAME_BALL_RADIUS then
            ball.x = GAME_BALL_RADIUS
            ball.vx = math.abs(ball.vx)
        elseif ball.x > GAME_BOARD_WIDTH - GAME_BALL_RADIUS then
            ball.x = GAME_BOARD_WIDTH - GAME_BALL_RADIUS
            ball.vx = -math.abs(ball.vx)
        end

        if ball.y < GAME_BALL_RADIUS then
            ball.y = GAME_BALL_RADIUS
            ball.vy = math.abs(ball.vy)
        end

        if ball.collisionCooldown <= 0 then
            for _, peg in ipairs(game.pegs) do
                if not peg.hit then
                    local dx = ball.x - peg.x
                    local dy = ball.y - peg.y
                    local distanceSquared = (dx * dx) + (dy * dy)
                    local minimumDistance = GAME_BALL_RADIUS + GAME_PEG_RADIUS

                    if distanceSquared <= (minimumDistance * minimumDistance) then
                        local distance = math.sqrt(distanceSquared)
                        local nx
                        local ny

                        if distance < 0.001 then
                            nx = 0
                            ny = 1
                        else
                            nx = dx / distance
                            ny = dy / distance
                        end

                        local dot = (ball.vx * nx) + (ball.vy * ny)
                        if dot < 0 then
                            ball.vx = ball.vx - (2 * dot * nx)
                            ball.vy = ball.vy - (2 * dot * ny)
                        else
                            ball.vx = ball.vx + (nx * 80)
                            ball.vy = ball.vy + (ny * 80)
                        end

                        local speed = math.sqrt((ball.vx * ball.vx) + (ball.vy * ball.vy))
                        if speed < (GAME_LAUNCH_SPEED * 0.7) then
                            local multiplier = (GAME_LAUNCH_SPEED * 0.7) / math.max(speed, 1)
                            ball.vx = ball.vx * multiplier
                            ball.vy = ball.vy * multiplier
                        end

                        ball.x = peg.x + (nx * (minimumDistance + 1))
                        ball.y = peg.y + (ny * (minimumDistance + 1))
                        ball.collisionCooldown = GAME_COLLISION_COOLDOWN

                        SetPegHit(peg)
                        game.pegsRemaining = game.pegsRemaining - 1
                        if peg.isOrange then
                            game.orangeLeft = game.orangeLeft - 1
                        end

                        UpdatePeggleInfo("Peg smashed. Keep shooting until the requested skills land.")
                        break
                    end
                end
            end
        end

        if ball.y > (GAME_BOARD_HEIGHT + GAME_BALL_RADIUS + 4) then
            StopPeggleBall()
            return
        end
    end

    SetBallPosition(board, ball)
end

UpdatePeggleAim = function(board)
    local left = board:GetLeft()
    local top = board:GetTop()
    if not left or not top then
        return
    end

    local scale = board:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    local localX = (cursorX / scale) - left
    local localY = top - (cursorY / scale)

    GFAR.game.aimX = Clamp(localX, 18, GAME_BOARD_WIDTH - 18)
    GFAR.game.aimY = Clamp(localY, 46, GAME_BOARD_HEIGHT - 18)

    SetBoardRegionPoint(board, board.aimHorizontal, GFAR.game.aimX, GFAR.game.aimY)
    SetBoardRegionPoint(board, board.aimVertical, GFAR.game.aimX, GFAR.game.aimY)
    SetBoardRegionPoint(board, board.aimDot, GFAR.game.aimX, GFAR.game.aimY)
    UpdateAimPreview(board)
end

local function BuildFallbackPegRow(board, level, startIndex)
    local game = GFAR.game
    local step = (GAME_BOARD_WIDTH - 72) / 5

    for column = 0, 5 do
        local pegIndex = startIndex + column
        local peg = {
            x = 36 + (column * step),
            y = 118 + ((Noise(level, pegIndex, 14) - 0.5) * 18),
            isOrange = column == 1 or column == 4,
            hit = false,
        }

        table.insert(game.pegs, peg)
        SetPegVisual(board, peg, #game.pegs)
    end
end

GeneratePeggleLevel = function(level)
    local board = GFAR.gameBoard
    if not board then
        return
    end

    local game = GFAR.game
    local rowCount = 5 + math.floor(Noise(level, 1, 1) * 3)
    local orangeAssigned = 0

    HideAllPegVisuals(board)
    wipe(game.pegs)
    game.level = level
    game.ball.active = false
    board.ballTexture:Hide()
    board.ballGlow:Hide()
    board.ballSpark:Hide()

    for row = 1, rowCount do
        local columns = 5 + math.floor(Noise(level, row, 2) * 4)
        local verticalSpace = (GAME_BOARD_HEIGHT - 94) / math.max(1, rowCount - 1)
        local rowY = 60 + ((row - 1) * verticalSpace)
        local rowShift = (Noise(level, row, 3) - 0.5) * 28

        for column = 1, columns do
            local presenceRoll = Noise(level, (row * 100) + column, 4)
            if presenceRoll > 0.15 or columns <= 5 then
                local step = (GAME_BOARD_WIDTH - 52) / math.max(1, columns - 1)
                local peg = {
                    x = Clamp(26 + ((column - 1) * step) + rowShift + ((Noise(level, (row * 100) + column, 5) - 0.5) * 18), 20, GAME_BOARD_WIDTH - 20),
                    y = Clamp(rowY + ((Noise(level, (row * 100) + column, 6) - 0.5) * 16), 54, GAME_BOARD_HEIGHT - 18),
                    isOrange = Noise(level, (row * 100) + column, 7) > 0.7,
                    hit = false,
                }

                if peg.isOrange then
                    orangeAssigned = orangeAssigned + 1
                end

                table.insert(game.pegs, peg)
            end
        end
    end

    if #game.pegs < 15 then
        BuildFallbackPegRow(board, level, #game.pegs + 1)
    end

    if orangeAssigned < GAME_MIN_ORANGE then
        for pegIndex, peg in ipairs(game.pegs) do
            if orangeAssigned >= GAME_MIN_ORANGE then
                break
            end

            if not peg.isOrange and Noise(level, pegIndex, 8) > 0.45 then
                peg.isOrange = true
                orangeAssigned = orangeAssigned + 1
            end
        end
    end

    for pegIndex, peg in ipairs(game.pegs) do
        SetPegVisual(board, peg, pegIndex)
    end

    game.pegsRemaining = #game.pegs
    game.orangeLeft = 0
    for _, peg in ipairs(game.pegs) do
        if peg.isOrange then
            game.orangeLeft = game.orangeLeft + 1
        end
    end

    UpdatePeggleAim(board)
    UpdatePeggleInfo("New procedurally generated course loaded.")
    UpdateButtonState()
end

StartPeggleShot = function()
    local board = GFAR.gameBoard
    local game = GFAR.game

    if not board or game.ball.active or not game.boardEnabled then
        return
    end

    local spawnX = GAME_BOARD_WIDTH * 0.5
    local spawnY = 18
    local dx = game.aimX - spawnX
    local dy = math.max(game.aimY - spawnY, 30)
    local distance = math.sqrt((dx * dx) + (dy * dy))
    if distance < 0.001 then
        distance = 1
    end

    game.ball.active = true
    game.ball.x = spawnX
    game.ball.y = spawnY
    game.ball.vx = (dx / distance) * GAME_LAUNCH_SPEED
    game.ball.vy = (dy / distance) * GAME_LAUNCH_SPEED
    game.ball.collisionCooldown = 0

    SetBallPosition(board, game.ball)
    board.ballGlow:Show()
    board.ballTexture:Show()
    board.ballSpark:Show()
    HideAimPreview(board)

    UpdatePeggleInfo("Ball in play. The click also consumed Destiny's Dice.")
    UpdateButtonState()
end

local function CreateAbilitySlot(parent, index)
    local slotFrame = CreateFrame("Frame", nil, parent)
    slotFrame:SetWidth(150)
    slotFrame:SetHeight(74)
    slotFrame.slotIndex = index

    slotFrame.label = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    slotFrame.label:SetPoint("TOPLEFT", slotFrame, "TOPLEFT", 0, 0)
    slotFrame.label:SetText("Ability " .. index)

    slotFrame.button = CreateFrame("Button", nil, slotFrame)
    slotFrame.button:SetWidth(42)
    slotFrame.button:SetHeight(42)
    slotFrame.button:SetPoint("TOPLEFT", slotFrame.label, "BOTTOMLEFT", 0, -6)
    slotFrame.button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    slotFrame.button:SetBackdropColor(0, 0, 0, 0.85)
    slotFrame.button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    slotFrame.icon = slotFrame.button:CreateTexture(nil, "ARTWORK")
    slotFrame.icon:SetPoint("TOPLEFT", slotFrame.button, "TOPLEFT", 3, -3)
    slotFrame.icon:SetPoint("BOTTOMRIGHT", slotFrame.button, "BOTTOMRIGHT", -3, 3)
    slotFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    slotFrame.highlight = slotFrame.button:CreateTexture(nil, "HIGHLIGHT")
    slotFrame.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    slotFrame.highlight:SetBlendMode("ADD")
    slotFrame.highlight:SetAllPoints(slotFrame.icon)

    slotFrame.nameText = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotFrame.nameText:SetWidth(98)
    slotFrame.nameText:SetHeight(48)
    slotFrame.nameText:SetJustifyH("LEFT")
    slotFrame.nameText:SetJustifyV("TOP")
    slotFrame.nameText:SetPoint("TOPLEFT", slotFrame.button, "TOPRIGHT", 10, -2)

    slotFrame.button:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ClearAbilitySlot(index)
            UpdateStatus()
        else
            OpenSpellPicker(index)
        end
    end)

    slotFrame.button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(slotFrame.button, "ANCHOR_RIGHT")

        local entry = GFAR_Saved.abilities[index]
        if entry and entry.spellID then
            GameTooltip:SetHyperlink("spell:" .. entry.spellID)
        elseif entry and entry.name then
            GameTooltip:AddLine(entry.name, 1, 1, 1)
        else
            GameTooltip:AddLine("Ability " .. index, 1, 1, 1)
        end

        GameTooltip:AddLine("Left-click to choose a spell.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click to clear this slot.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)

    slotFrame.button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdateAbilitySlotDisplay(slotFrame)

    return slotFrame
end

UpdateSpellList = function()
    if not GFAR.spellPicker then
        return
    end

    local picker = GFAR.spellPicker
    FauxScrollFrame_Update(picker.scrollFrame, #GFAR.filteredSpells, #picker.rows, 28)
    local offset = FauxScrollFrame_GetOffset(picker.scrollFrame)

    for rowIndex = 1, #picker.rows do
        local button = picker.rows[rowIndex]
        local entry = GFAR.filteredSpells[offset + rowIndex]

        if entry then
            button.entry = entry
            button.icon:SetTexture(entry.icon or EMPTY_ICON)
            button.nameText:SetText(entry.name)
            button:Show()
        else
            button.entry = nil
            button:Hide()
        end
    end
end

RefreshPickerStatus = function()
    if not GFAR.spellPicker or not GFAR.spellPicker.scanText then
        return
    end

    local picker = GFAR.spellPicker
    local loadedCount = #GFAR.spellCatalog

    if GFAR.scanState.complete then
        picker.scanText:SetText(loadedCount .. " spells loaded")
    else
        picker.scanText:SetText("Loading spells: " .. (GFAR.scanState.nextId - 1) .. "/" .. SPELL_SCAN_MAX_ID)
    end
end

ApplySpellFilter = function()
    if not GFAR.spellPicker then
        return
    end

    local query = NormalizeName(GFAR.spellPicker.searchBox:GetText())
    wipe(GFAR.filteredSpells)

    for _, entry in ipairs(GFAR.spellCatalog) do
        if query == "" or string.find(entry.searchName, query, 1, true) then
            table.insert(GFAR.filteredSpells, entry)
        end
    end

    UpdateSpellList()
    RefreshPickerStatus()
end

StartSpellCatalogScan = function()
    if GFAR.scanState.active or GFAR.scanState.complete then
        return
    end

    GFAR.scanState.active = true

    if not GFAR.scanFrame then
        GFAR.scanFrame = CreateFrame("Frame")
    end

    GFAR.scanFrame:SetScript("OnUpdate", function()
        local scanState = GFAR.scanState

        for _ = 1, SPELL_SCAN_CHUNK do
            local spellID = scanState.nextId

            if spellID > SPELL_SCAN_MAX_ID then
                scanState.active = false
                scanState.complete = true
                GFAR.scanFrame:SetScript("OnUpdate", nil)

                table.sort(GFAR.spellCatalog, function(left, right)
                    return left.searchName < right.searchName
                end)

                ApplySpellFilter()
                return
            end

            local spellName, _, spellIcon = GetSpellInfo(spellID)
            if spellName and spellIcon then
                local key = NormalizeName(spellName)
                if key ~= "" and not GFAR.spellCatalogByKey[key] then
                    local entry = {
                        spellID = spellID,
                        name = spellName,
                        icon = spellIcon,
                        searchName = key,
                    }

                    GFAR.spellCatalogByKey[key] = entry
                    table.insert(GFAR.spellCatalog, entry)
                end
            end

            scanState.nextId = spellID + 1
        end

        scanState.refreshProgress = scanState.refreshProgress + SPELL_SCAN_CHUNK
        if scanState.refreshProgress >= SPELL_SCAN_REFRESH_STEP then
            scanState.refreshProgress = 0
            if GFAR.spellPicker and GFAR.spellPicker:IsShown() then
                ApplySpellFilter()
            else
                RefreshPickerStatus()
            end
        end
    end)
end

local function CreateSpellPicker()
    local picker = CreateFrame("Frame", "GFAR_SpellPicker", UIParent)
    picker:SetWidth(460)
    picker:SetHeight(500)
    picker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    picker:SetFrameStrata("DIALOG")
    picker:SetToplevel(true)
    picker:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    picker:EnableMouse(true)
    picker:SetMovable(true)
    picker:RegisterForDrag("LeftButton")
    picker:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    picker:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    picker:Hide()

    picker.title = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    picker.title:SetPoint("TOP", picker, "TOP", 0, -16)
    picker.title:SetText("Choose Ability")

    picker.subtitle = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    picker.subtitle:SetPoint("TOP", picker.title, "BOTTOM", 0, -8)
    picker.subtitle:SetText("Filter by spell name. Click to assign, Shift-click to link in chat.")

    picker.closeButton = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
    picker.closeButton:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -4, -4)

    picker.searchBox = CreateFrame("EditBox", "GFAR_SpellSearchBox", picker, "InputBoxTemplate")
    picker.searchBox:SetAutoFocus(false)
    picker.searchBox:SetWidth(240)
    picker.searchBox:SetHeight(24)
    picker.searchBox:SetTextInsets(6, 6, 0, 0)
    picker.searchBox:SetPoint("TOPLEFT", picker, "TOPLEFT", 24, -72)
    picker.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    picker.searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    picker.searchBox:SetScript("OnTextChanged", function()
        ApplySpellFilter()
    end)

    picker.searchLabel = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    picker.searchLabel:SetPoint("BOTTOMLEFT", picker.searchBox, "TOPLEFT", 0, 4)
    picker.searchLabel:SetText("Filter")

    picker.helpText = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    picker.helpText:SetPoint("LEFT", picker.searchBox, "RIGHT", 14, 0)
    picker.helpText:SetText("Blank search shows every loaded spell.")

    picker.scrollFrame = CreateFrame("ScrollFrame", "GFAR_SpellPickerScrollFrame", picker, "FauxScrollFrameTemplate")
    picker.scrollFrame:SetPoint("TOPLEFT", picker, "TOPLEFT", 24, -110)
    picker.scrollFrame:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -34, 54)
    picker.scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 28, UpdateSpellList)
    end)

    picker.rows = {}
    for rowIndex = 1, 12 do
        local row = CreateFrame("Button", nil, picker)
        row:SetWidth(378)
        row:SetHeight(24)
        row:SetPoint("TOPLEFT", picker, "TOPLEFT", 28, -114 - ((rowIndex - 1) * 28))
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row:RegisterForClicks("LeftButtonUp")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(20)
        row.icon:SetHeight(20)
        row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.nameText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.nameText:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            if not self.entry then
                return
            end

            if TryInsertSpellLink(self.entry) then
                return
            end

            if not picker.activeSlotIndex then
                return
            end

            SetAbilityForSlot(picker.activeSlotIndex, self.entry)
            picker:Hide()
            UpdateStatus()
        end)

        row:SetScript("OnEnter", function(self)
            if not self.entry then
                return
            end

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("spell:" .. self.entry.spellID)
            GameTooltip:AddLine("Left-click to assign. Shift-click to link in chat.", 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)

        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        picker.rows[rowIndex] = row
    end

    picker.scanText = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    picker.scanText:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 28, 24)
    picker.scanText:SetWidth(300)
    picker.scanText:SetJustifyH("LEFT")

    picker.clearButton = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
    picker.clearButton:SetWidth(100)
    picker.clearButton:SetHeight(24)
    picker.clearButton:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -34, 20)
    picker.clearButton:SetText("Clear Slot")
    picker.clearButton:SetScript("OnClick", function()
        if picker.activeSlotIndex then
            ClearAbilitySlot(picker.activeSlotIndex)
            picker:Hide()
            UpdateStatus()
        end
    end)

    GFAR.spellPicker = picker
    RefreshPickerStatus()
end

OpenSpellPicker = function(slotIndex)
    if not GFAR.spellPicker then
        CreateSpellPicker()
    end

    local picker = GFAR.spellPicker
    picker.activeSlotIndex = slotIndex
    picker.title:SetText("Choose Ability " .. slotIndex)
    picker.searchBox:SetText("")
    picker.searchBox:ClearFocus()
    picker:Show()
    picker:Raise()

    StartSpellCatalogScan()
    ApplySpellFilter()
end

CreatePeggleBoard = function(parent)
    local board = CreateFrame("Button", "GFAR_PeggleBoard", parent, "SecureActionButtonTemplate")
    board:SetWidth(GAME_BOARD_WIDTH)
    board:SetHeight(GAME_BOARD_HEIGHT)
    board:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, -112)
    board:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    board:SetBackdropColor(0.03, 0.05, 0.1, 0.96)
    board:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    board:RegisterForClicks("LeftButtonUp")
    board:SetAttribute("type", "item")
    board:SetAttribute("item", "item:" .. ITEM_ID)
    board.pegPool = {}

    board.gridLineHorizontal = board:CreateTexture(nil, "BACKGROUND")
    board.gridLineHorizontal:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.gridLineHorizontal:SetVertexColor(0.1, 0.2, 0.35, 0.4)
    board.gridLineHorizontal:SetPoint("TOPLEFT", board, "TOPLEFT", 12, -48)
    board.gridLineHorizontal:SetPoint("TOPRIGHT", board, "TOPRIGHT", -12, -48)
    board.gridLineHorizontal:SetHeight(1)

    board.gridLineVertical = board:CreateTexture(nil, "BACKGROUND")
    board.gridLineVertical:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.gridLineVertical:SetVertexColor(0.1, 0.2, 0.35, 0.35)
    board.gridLineVertical:SetPoint("TOP", board, "TOP", 0, -18)
    board.gridLineVertical:SetPoint("BOTTOM", board, "BOTTOM", 0, 18)
    board.gridLineVertical:SetWidth(1)

    board.launchPadGlow = board:CreateTexture(nil, "ARTWORK")
    board.launchPadGlow:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.launchPadGlow:SetWidth(30)
    board.launchPadGlow:SetHeight(30)
    board.launchPadGlow:SetVertexColor(1.0, 0.78, 0.28, 0.32)
    SetBoardRegionPoint(board, board.launchPadGlow, GAME_BOARD_WIDTH * 0.5, 18)

    board.launchPad = board:CreateTexture(nil, "ARTWORK")
    board.launchPad:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.launchPad:SetWidth(12)
    board.launchPad:SetHeight(12)
    board.launchPad:SetVertexColor(1.0, 0.84, 0.32, 1)
    SetBoardRegionPoint(board, board.launchPad, GAME_BOARD_WIDTH * 0.5, 18)

    board.aimHorizontal = board:CreateTexture(nil, "OVERLAY")
    board.aimHorizontal:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.aimHorizontal:SetWidth(18)
    board.aimHorizontal:SetHeight(2)
    board.aimHorizontal:SetVertexColor(1.0, 0.88, 0.42, 0.9)

    board.aimVertical = board:CreateTexture(nil, "OVERLAY")
    board.aimVertical:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.aimVertical:SetWidth(2)
    board.aimVertical:SetHeight(18)
    board.aimVertical:SetVertexColor(1.0, 0.88, 0.42, 0.9)

    board.aimDot = board:CreateTexture(nil, "OVERLAY")
    board.aimDot:SetTexture("Interface\\Buttons\\WHITE8x8")
    board.aimDot:SetWidth(6)
    board.aimDot:SetHeight(6)
    board.aimDot:SetVertexColor(1.0, 0.92, 0.48, 1)

    board.aimDots = {}
    for dotIndex = 1, 48 do
        local dot = board:CreateTexture(nil, "OVERLAY")
        dot:SetTexture(CIRCLE_TEXTURE)
        dot:SetWidth(3)
        dot:SetHeight(3)
        dot:SetBlendMode("ADD")
        dot:Hide()
        board.aimDots[dotIndex] = dot
    end

    board.ballGlow = board:CreateTexture(nil, "OVERLAY")
    board.ballGlow:SetTexture(CIRCLE_TEXTURE)
    board.ballGlow:SetWidth(10)
    board.ballGlow:SetHeight(10)
    board.ballGlow:SetBlendMode("ADD")
    board.ballGlow:SetVertexColor(1, 1, 1, 0.38)
    board.ballGlow:Hide()

    board.ballTexture = board:CreateTexture(nil, "OVERLAY")
    board.ballTexture:SetTexture(CIRCLE_TEXTURE)
    board.ballTexture:SetWidth(6)
    board.ballTexture:SetHeight(6)
    board.ballTexture:SetVertexColor(1, 1, 1, 1)
    board.ballTexture:Hide()

    board.ballSpark = board:CreateTexture(nil, "OVERLAY")
    board.ballSpark:SetTexture(CIRCLE_TEXTURE)
    board.ballSpark:SetWidth(2)
    board.ballSpark:SetHeight(2)
    board.ballSpark:SetVertexColor(1, 0.95, 0.65, 0.9)
    board.ballSpark:Hide()

    board:SetScript("OnEnter", function(self)
        UpdatePeggleAim(self)

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Autoroll Peggle", 1, 1, 1)
        GameTooltip:AddLine("Click the board to launch a ball and use Destiny's Dice.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Procedural layouts refresh when you clear a course or click New Course.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    board:SetScript("OnLeave", function()
        HideAimPreview(board)
        GameTooltip:Hide()
    end)
    board:SetScript("OnUpdate", function(self, elapsed)
        GFAR.game.refreshElapsed = GFAR.game.refreshElapsed + elapsed
        if GFAR.game.refreshElapsed >= 0.2 then
            GFAR.game.refreshElapsed = 0
            if GFAR.mainFrame and GFAR.mainFrame:IsShown() then
                UpdateButtonState()
            end
        end

        if self:IsMouseOver() and not GFAR.game.ball.active then
            UpdatePeggleAim(self)
        end

        UpdatePeggleBall(elapsed)
    end)
    board:SetScript("PostClick", function(self)
        UpdatePeggleAim(self)
        StartPeggleShot()
        UpdateStatus()
    end)

    GFAR.gameBoard = board
    return board
end

local function CreateMainFrame()
    local frame = CreateFrame("Frame", "GFAR_MainFrame", UIParent)
    frame:SetWidth(390)
    frame:SetHeight(700)
    frame:SetPoint(
        GFAR_Saved.position.point,
        UIParent,
        GFAR_Saved.position.relativePoint,
        GFAR_Saved.position.x,
        GFAR_Saved.position.y
    )
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFramePosition(self)
    end)
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -16)
    frame.title:SetText("Grimfall Autoroll")

    frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.subtitle:SetPoint("TOP", frame.title, "BOTTOM", 0, -8)
    frame.subtitle:SetWidth(332)
    frame.subtitle:SetHeight(28)
    frame.subtitle:SetJustifyH("CENTER")
    frame.subtitle:SetJustifyV("TOP")
    frame.subtitle:SetText("Choose target abilities, then click the Peggle board to fire Destiny's Dice.")

    frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    frame.gameBoard = CreatePeggleBoard(frame)

    frame.boardPromptText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.boardPromptText:SetWidth(332)
    frame.boardPromptText:SetHeight(34)
    frame.boardPromptText:SetJustifyH("LEFT")
    frame.boardPromptText:SetPoint("TOPLEFT", frame.gameBoard, "BOTTOMLEFT", 2, -10)

    frame.courseText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.courseText:SetPoint("TOPLEFT", frame.boardPromptText, "BOTTOMLEFT", 0, -8)
    frame.courseText:SetWidth(332)
    frame.courseText:SetJustifyH("LEFT")

    frame.courseHintText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.courseHintText:SetPoint("TOPLEFT", frame.courseText, "BOTTOMLEFT", 0, -4)
    frame.courseHintText:SetWidth(332)
    frame.courseHintText:SetHeight(22)
    frame.courseHintText:SetJustifyH("LEFT")
    frame.courseHintText:SetJustifyV("TOP")

    frame.slots = {}
    for index = 1, MAX_SLOTS do
        local slotFrame = CreateAbilitySlot(frame, index)

        if index == 1 then
            slotFrame:SetPoint("TOPLEFT", frame.courseHintText, "BOTTOMLEFT", 0, -12)
        elseif index == 2 then
            slotFrame:SetPoint("TOPLEFT", frame.slots[1], "TOPRIGHT", 28, 0)
        elseif index == 3 then
            slotFrame:SetPoint("TOPLEFT", frame.slots[1], "BOTTOMLEFT", 0, -12)
        else
            slotFrame:SetPoint("TOPLEFT", frame.slots[2], "BOTTOMLEFT", 0, -12)
        end

        frame.slots[index] = slotFrame
    end

    frame.statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statusText:SetWidth(332)
    frame.statusText:SetHeight(32)
    frame.statusText:SetJustifyH("LEFT")
    frame.statusText:SetJustifyV("TOP")
    frame.statusText:SetPoint("TOPLEFT", frame.slots[3], "BOTTOMLEFT", 0, -2)

    frame.matchText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.matchText:SetWidth(332)
    frame.matchText:SetHeight(18)
    frame.matchText:SetJustifyH("LEFT")
    frame.matchText:SetPoint("TOPLEFT", frame.statusText, "BOTTOMLEFT", 0, 0)

    frame.newCourseButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.newCourseButton:SetWidth(120)
    frame.newCourseButton:SetHeight(24)
    frame.newCourseButton:SetPoint("TOPLEFT", frame.matchText, "BOTTOMLEFT", 0, -4)
    frame.newCourseButton:SetText("New Course")
    frame.newCourseButton:SetScript("OnClick", function()
        GeneratePeggleLevel(GFAR.game.level + 1)
    end)

    GFAR.mainFrame = frame
    GFAR.statusText = frame.statusText
    GFAR.matchText = frame.matchText
    GFAR.boardPromptText = frame.boardPromptText
    GFAR.courseText = frame.courseText
    GFAR.courseHintText = frame.courseHintText

    GeneratePeggleLevel(1)
    UpdateStatus()
end

local function ToggleMainFrame()
    if not GFAR.mainFrame then
        return
    end

    if GFAR.mainFrame:IsShown() then
        GFAR.mainFrame:Hide()
        if GFAR.spellPicker then
            GFAR.spellPicker:Hide()
        end
    else
        GFAR.mainFrame:Show()
        UpdateStatus()
    end
end

local function PrintBagItemIds(searchText)
    local filter = NormalizeName(searchText or "")

    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local itemName = GetItemInfo(itemLink)
                local itemId = GetItemIdFromLink(itemLink)
                local normalizedName = NormalizeName(itemName or "")

                if filter == "" or string.find(normalizedName, filter, 1, true) then
                    Print("Bag " .. bag .. ", slot " .. slot .. ": " .. itemLink .. " (ID " .. (itemId or "unknown") .. ")")
                end
            end
        end
    end
end

SlashCmdList["GFAR"] = function()
    ToggleMainFrame()
end
SLASH_GFAR1 = "/gfar"

SlashCmdList["GFARITEM"] = function(msg)
    local query = Trim(msg)
    if query == "" then
        Print("Usage: /gfaritem <part of item name>")
        return
    end

    PrintBagItemIds(query)
end
SLASH_GFARITEM1 = "/gfaritem"

GFAR:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureSavedVariables()
        CreateMainFrame()
        CreateSpellPicker()
        StartSpellCatalogScan()
        return
    end

    if event == "UNIT_AURA" and arg1 ~= "player" then
        return
    end

    if GFAR.mainFrame then
        UpdateStatus()
    end
end)
