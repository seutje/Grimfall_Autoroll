local ADDON_NAME = ...
local ITEM_NAME = "Destiny's Dice"
local ITEM_ID = 10901
local MAX_SLOTS = 4

local GFAR = CreateFrame("Frame", "GFAR_EventFrame")
GFAR:RegisterEvent("ADDON_LOADED")
GFAR:RegisterEvent("SPELLS_CHANGED")
GFAR:RegisterEvent("LEARNED_SPELL_IN_TAB")
GFAR:RegisterEvent("UNIT_AURA")
GFAR:RegisterEvent("BAG_UPDATE")
GFAR:RegisterEvent("BAG_UPDATE_COOLDOWN")

local defaults = {
    abilities = { "", "", "", "" },
    position = {
        point = "CENTER",
        relativePoint = "CENTER",
        x = 0,
        y = 0,
    },
}

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
        if type(GFAR_Saved.abilities[i]) ~= "string" then
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
        local value = Trim(GFAR_Saved.abilities[i])
        if value ~= "" then
            table.insert(abilities, value)
        end
    end

    return abilities
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
    local numericId = tonumber(Trim(spellName))

    if numericId then
        local resolvedName = GetSpellInfo(numericId)
        if resolvedName then
            target = NormalizeName(resolvedName)
        end
    end

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

local function PlayerHasAbility(spellName)
    if spellName == nil or Trim(spellName) == "" then
        return false
    end

    return HasSpellbookSpellByName(spellName) or HasAuraByName(spellName)
end

local function GetAbilityProgress()
    local configured = GetConfiguredAbilities()
    local matched = {}
    local missing = {}

    for _, spellName in ipairs(configured) do
        if PlayerHasAbility(spellName) then
            table.insert(matched, spellName)
        else
            table.insert(missing, spellName)
        end
    end

    return configured, matched, missing
end

local function HasAllConfiguredAbilities()
    local configured, _, missing = GetAbilityProgress()
    return #configured > 0 and #missing == 0
end

local function FindDiceInBags()
    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local itemId = GetItemIdFromLink(itemLink)
                local itemName = GetItemInfo(itemLink)
                if (ITEM_ID and itemId == ITEM_ID) or (not ITEM_ID and itemName == ITEM_NAME) then
                    return bag, slot
                end
            end
        end
    end

    return nil, nil
end

local function SetStatusText(message)
    if GFAR.statusText then
        GFAR.statusText:SetText(message)
    end
end

local function UpdateButtonState()
    if not GFAR.rollButton then
        return
    end

    local configured, _, missing = GetAbilityProgress()
    local bag, slot = FindDiceInBags()

    if #configured == 0 then
        GFAR.rollButton:Disable()
        GFAR.rollButton:SetText("Roll")
        return
    end

    if #missing == 0 then
        GFAR.rollButton:Disable()
        GFAR.rollButton:SetText("Done")
        return
    end

    if not bag or not slot then
        GFAR.rollButton:Disable()
        GFAR.rollButton:SetText("No Dice")
        return
    end

    GFAR.rollButton:Enable()
    GFAR.rollButton:SetText("Roll")
end

local function UpdateStatus()
    if not GFAR.statusText then
        return
    end

    local configured, matched, missing = GetAbilityProgress()

    if #configured == 0 then
        SetStatusText("Enter 1 to 4 abilities, then click Roll.")
        if GFAR.matchText then
            GFAR.matchText:SetText("Found: none")
        end
        UpdateButtonState()
        return
    end

    if #missing == 0 then
        SetStatusText("All selected abilities are currently available.")
        if GFAR.matchText then
            GFAR.matchText:SetText("Found: " .. table.concat(matched, ", "))
        end
        UpdateButtonState()
        return
    end

    local bag, slot = FindDiceInBags()
    if not bag or not slot then
        SetStatusText("Missing: " .. table.concat(missing, ", ") .. " | Destiny's Dice not found.")
    else
        SetStatusText("Missing: " .. table.concat(missing, ", "))
    end

    if #matched > 0 and GFAR.matchText then
        GFAR.matchText:SetText("Found: " .. table.concat(matched, ", "))
    elseif GFAR.matchText then
        GFAR.matchText:SetText("Found: none")
    end
    UpdateButtonState()
end

local function SaveFramePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    GFAR_Saved.position.point = point
    GFAR_Saved.position.relativePoint = relativePoint
    GFAR_Saved.position.x = x
    GFAR_Saved.position.y = y
end

local function CreateEditBox(parent, index)
    local editBox = CreateFrame("EditBox", "GFAR_AbilityBox" .. index, parent, "InputBoxTemplate")
    editBox:SetAutoFocus(false)
    editBox:SetWidth(220)
    editBox:SetHeight(24)
    editBox:SetTextInsets(6, 6, 0, 0)
    editBox:SetMaxLetters(64)
    editBox:SetText(GFAR_Saved.abilities[index] or "")

    editBox.label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editBox.label:SetPoint("BOTTOMLEFT", editBox, "TOPLEFT", 0, 4)
    editBox.label:SetText("Ability " .. index)

    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        GFAR_Saved.abilities[index] = Trim(self:GetText())
        self:SetText(GFAR_Saved.abilities[index])
        UpdateStatus()
    end)

    editBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            GFAR_Saved.abilities[index] = self:GetText()
        end
    end)

    return editBox
end

local function CreateMainFrame()
    local frame = CreateFrame("Frame", "GFAR_MainFrame", UIParent)
    frame:SetWidth(360)
    frame:SetHeight(390)
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
    frame.subtitle:SetText("Enter 1 to 4 abilities, then click roll.")

    frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    frame.editBoxes = {}
    for i = 1, MAX_SLOTS do
        local editBox = CreateEditBox(frame, i)
        if i == 1 then
            editBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, -84)
        else
            editBox:SetPoint("TOPLEFT", frame.editBoxes[i - 1], "BOTTOMLEFT", 0, -20)
        end
        frame.editBoxes[i] = editBox
    end

    frame.rollButton = CreateFrame("Button", "GFAR_RollButton", frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    frame.rollButton:SetWidth(120)
    frame.rollButton:SetHeight(24)
    frame.rollButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 28, 34)
    frame.rollButton:SetAttribute("type", "item")
    frame.rollButton:SetAttribute("item", "item:" .. ITEM_ID)
    frame.rollButton:RegisterForClicks("AnyUp")
    frame.rollButton:SetScript("PostClick", function()
        UpdateStatus()
    end)

    frame.statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statusText:SetWidth(290)
    frame.statusText:SetHeight(32)
    frame.statusText:SetJustifyH("LEFT")
    frame.statusText:SetJustifyV("TOP")
    frame.statusText:SetPoint("BOTTOMLEFT", frame.rollButton, "TOPLEFT", 0, 44)

    frame.matchText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.matchText:SetWidth(290)
    frame.matchText:SetHeight(18)
    frame.matchText:SetJustifyH("LEFT")
    frame.matchText:SetPoint("BOTTOMLEFT", frame.rollButton, "TOPLEFT", 0, 16)

    GFAR.mainFrame = frame
    GFAR.rollButton = frame.rollButton
    GFAR.statusText = frame.statusText
    GFAR.matchText = frame.matchText

    UpdateStatus()
end

local function ToggleMainFrame()
    if not GFAR.mainFrame then
        return
    end

    if GFAR.mainFrame:IsShown() then
        GFAR.mainFrame:Hide()
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

GFAR:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureSavedVariables()
        CreateMainFrame()
        return
    end

    if event == "UNIT_AURA" and arg1 ~= "player" then
        return
    end

    if GFAR.mainFrame then
        UpdateStatus()
    end
end)
