local ADDON_NAME = ...
local ITEM_ID = 10901
local ITEM_NAME = "Destiny's Dice"
local MAX_SLOTS = 4
local SPELL_SCAN_MAX_ID = 80000
local SPELL_SCAN_CHUNK = 750
local SPELL_SCAN_REFRESH_STEP = 4500
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

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

UpdateStatus = function()
    local configured, matched, missing = GetAbilityProgress()

    RefreshAbilitySlots()

    if #configured == 0 then
        SetStatusText("Choose 1 to 4 abilities, then click Roll.")
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

local function CreateAbilitySlot(parent, index)
    local slotFrame = CreateFrame("Frame", nil, parent)
    slotFrame:SetWidth(150)
    slotFrame:SetHeight(72)
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
    slotFrame.nameText:SetWidth(94)
    slotFrame.nameText:SetHeight(40)
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
    picker.subtitle:SetText("Filter by spell name. Click a result to assign it.")

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
            if not self.entry or not picker.activeSlotIndex then
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

local function CreateMainFrame()
    local frame = CreateFrame("Frame", "GFAR_MainFrame", UIParent)
    frame:SetWidth(390)
    frame:SetHeight(400)
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
    frame.subtitle:SetText("Click a square to choose a spell. Right-click to clear.")

    frame.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    frame.slots = {}
    for index = 1, MAX_SLOTS do
        local slotFrame = CreateAbilitySlot(frame, index)

        if index == 1 then
            slotFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 28, -84)
        elseif index == 2 then
            slotFrame:SetPoint("TOPLEFT", frame.slots[1], "TOPRIGHT", 28, 0)
        elseif index == 3 then
            slotFrame:SetPoint("TOPLEFT", frame.slots[1], "BOTTOMLEFT", 0, -18)
        else
            slotFrame:SetPoint("TOPLEFT", frame.slots[2], "BOTTOMLEFT", 0, -18)
        end

        frame.slots[index] = slotFrame
    end

    frame.rollButton = CreateFrame("Button", "GFAR_RollButton", frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    frame.rollButton:SetWidth(120)
    frame.rollButton:SetHeight(24)
    frame.rollButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 28, 30)
    frame.rollButton:SetAttribute("type", "item")
    frame.rollButton:SetAttribute("item", "item:" .. ITEM_ID)
    frame.rollButton:RegisterForClicks("AnyUp")
    frame.rollButton:SetScript("PostClick", function()
        UpdateStatus()
    end)

    frame.statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statusText:SetWidth(320)
    frame.statusText:SetHeight(36)
    frame.statusText:SetJustifyH("LEFT")
    frame.statusText:SetJustifyV("TOP")
    frame.statusText:SetPoint("BOTTOMLEFT", frame.rollButton, "TOPLEFT", 0, 40)

    frame.matchText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.matchText:SetWidth(320)
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
