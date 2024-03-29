local _
if LibCombatUnits then assert(false, "Global variable 'LibCombatUnits' already exists. Loading of LibCombatUnits abborted") end
local lcu = {}
LibCombatUnits = lcu
---@diagnostic disable-next-line: undefined-global
local em = EventCallbackManager and EventCallbackManager:New("LCU_EventManager") or GetEventManager()
local wm = GetWindowManager()

local UnitHandler = ZO_InitializingObject:Subclass() -- internal object to store everything about a unit
local UnitAPIHandler = ZO_InitializingObject:Subclass()	-- object to expose data about units

-- Basic values
lcu.name = "LibCombatUnits"
lcu.initials = "LCU"
lcu.author = "Solinur"
lcu.version = 1

-- internal objects
lcu.internal = {
	cm               = ZO_CallbackObject:New(),
	debug            = true, -- or GetDisplayName() == "@Solinur",
	unitCache        = {},
	unitIdsByRawName = {},
	unitIdsByName    = {},
	unitIdsByTag     = {},
	groupTagByName   = {},
	petData          = {},
	bossTagByName    = {},
	petTagByName     = {},
	effectCache      = {},
	effectSlotCache  = {},
	UnitExportCache  = {},
	debugPanel       = {init = false},
}

local lcuint           = lcu.internal
local UnitCache       = lcuint.unitCache -- localized for performance reasons since it is called very often by OnCombatEvent
local EffectCache     = lcuint.effectCache -- localized for performance reasons since it is called very often by OnCombatEvent
local EffectSlotCache = lcuint.effectSlotCache -- localized for performance reasons since it is called very often by OnCombatEvent
local UnitExportCache = lcuint.UnitExportCache -- localized for convinience

---@diagnostic disable-next-line: undefined-global
local COMBAT_UNIT_TYPE_GROUP_COMPANION = COMBAT_UNIT_TYPE_GROUP_COMPANION or (COMBAT_UNIT_TYPE_GROUP + 100)

-- Logger (requires LibDebugLogger)

local mainlogger
local subloggers        = {}
local LOG_LEVEL_VERBOSE = "V"
local LOG_LEVEL_DEBUG   = "D"
local LOG_LEVEL_INFO    = "I"
local LOG_LEVEL_WARNING = "W"
local LOG_LEVEL_ERROR   = "E"

if LibDebugLogger then

	mainlogger = LibDebugLogger.Create(lcu.initials)

	LOG_LEVEL_VERBOSE = LibDebugLogger.LOG_LEVEL_VERBOSE
	LOG_LEVEL_DEBUG   = LibDebugLogger.LOG_LEVEL_DEBUG
	LOG_LEVEL_INFO    = LibDebugLogger.LOG_LEVEL_INFO
	LOG_LEVEL_WARNING = LibDebugLogger.LOG_LEVEL_WARNING
	LOG_LEVEL_ERROR   = LibDebugLogger.LOG_LEVEL_ERROR

	subloggers["dev"] = mainlogger:Create("dev")

end

local function Print(category, level, ...)

	if mainlogger == nil then df(...) return end

	local logger = category and subloggers[category] or mainlogger

	if category == "dev" and lcuint.debug ~= true then return end

	if type(logger.Log) == "function" then logger:Log(level, ...) end

end

-- Internal functions

local function spairs(t, order) -- from https://stackoverflow.com/questions/15706270/sort-a-table-in-lua

    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

local function IsValidUnitId(unitId)

	return unitId and (unitId >= 0)

end

local function IsValidUnitName(unitName)

	return unitName and (unitName ~= "") and (unitName ~= "Offline")

end

local function IsValidUnitData(rawName, unitId, unitType)

	return IsValidUnitName(rawName) and IsValidUnitId(unitId) and unitType

end

local function UpdatePlayerId(newPlayerId)

	if lcuint.playerId == newPlayerId then return end -- check if it changed

	local oldPlayerId = lcuint.playerId
	lcuint.playerId = newPlayerId

	if oldPlayerId then UnitCache[oldPlayerId]:Delete() end -- delete old unit since it is obsolete

end

local function UpdateUnitTagId(unitTag, unitId)

	local UnitIdsByTag = lcuint.unitIdsByTag

	local oldUnitId = UnitIdsByTag[unitTag]

	if oldUnitId then UnitCache[oldUnitId]:RemoveUnitTag(unitTag) end
	UnitIdsByTag[unitTag] = unitId

end

local function CheckForPetUnit(rawName, unitId) -- TODO: potentially detect other people's pets ?

end

-- Event Callbacks

-- Discover names of special units:

local GroupUnitTags = {} -- preassemble unit tags

for i = 1, GROUP_SIZE_MAX do

	GroupUnitTags[i] = "group" .. i

end

local BossUnitTags = {} -- preassemble unit tags

for i = 1, MAX_BOSSES do

	BossUnitTags[i] = "boss" .. i

end

local PetUnitTags = {} -- preassemble unit tags

for i = 1, MAX_PET_UNIT_TAGS do

	PetUnitTags[i] = "playerpet" .. i

end

local function onGroupChange()

	lcuint.inGroup = IsUnitGrouped("player")
	lcuint.groupTagByName = {}

	if lcuint.inGroup == true then

		local groupTagByName = lcuint.groupTagByName

		for i = 1, GetGroupSize() do

			local unitTag = GroupUnitTags[i]

			if DoesUnitExist(unitTag) == true and AreUnitsEqual(unitTag, "player") == false then

				local rawName = GetUnitName(unitTag)

				groupTagByName[rawName] = unitTag

			end
		end
	end
end

local hasMultipleTags = "multiple tags found"

local function onBossesChanged(_) -- Detect Bosses

	local bossTagByName = {} -- holds only bosses discovered in this round

	for i = 1, MAX_BOSSES do

		local unitTag = BossUnitTags[i]

		if DoesUnitExist(unitTag) then

			local rawName = GetUnitName(unitTag)

			if bossTagByName[rawName] and bossTagByName[rawName] ~= unitTag then

				Print("dev", LOG_LEVEL_WARNING, "Multiple tags found for %s (%s, %s)", rawName, bossTagByName[rawName], unitTag)
				bossTagByName[rawName] = hasMultipleTags

			end

			lcuint.bossTagByName[rawName] = bossTagByName[rawName]

		end
	end
end

local function onPlayerPetsChanged(_) -- TODO: figure out when to call this

	local petTagByName = lcuint.petTagByName

	for i = 1, MAX_PET_UNIT_TAGS do

		local unitTag = PetUnitTags[i]

		if DoesUnitExist(unitTag) == true then

			local rawName = GetUnitName(unitTag)

			petTagByName[rawName] = unitTag

		end
	end
end

local unitDetectionResults = {	-- valid values of result from combat events to determine info from

	[ACTION_RESULT_DAMAGE] = true,
	[ACTION_RESULT_CRITICAL_DAMAGE] = true,
	[ACTION_RESULT_HEAL] = true,
	[ACTION_RESULT_CRITICAL_HEAL] = true,
	[ACTION_RESULT_POWER_DRAIN] = true,
	[ACTION_RESULT_POWER_ENERGIZE] = true,
	[ACTION_RESULT_IMMUNE] = true,
	[ACTION_RESULT_SILENCED] = true,
	[ACTION_RESULT_STUNNED] = true,
	[ACTION_RESULT_SNARED] = true,
	[ACTION_RESULT_BUSY] = true,
	[ACTION_RESULT_BAD_TARGET] = true,
	[ACTION_RESULT_TARGET_DEAD] = true,
	[ACTION_RESULT_CASTER_DEAD] = true,
	[ACTION_RESULT_TARGET_NOT_IN_VIEW] = true,
	[ACTION_RESULT_ABILITY_ON_COOLDOWN] = true,
	[ACTION_RESULT_INSUFFICIENT_RESOURCE] = true,
	[ACTION_RESULT_TARGET_OUT_OF_RANGE] = true,
	[ACTION_RESULT_FAILED] = true,
	[ACTION_RESULT_DODGED] = true,
	[ACTION_RESULT_BLOCKED_DAMAGE] = true,
	[ACTION_RESULT_BEGIN] = true,
	[ACTION_RESULT_INTERRUPT] = true,
	[ACTION_RESULT_EFFECT_GAINED] = true,
	[ACTION_RESULT_EFFECT_GAINED_DURATION] = true,
	[ACTION_RESULT_EFFECT_FADED] = true,
	[ACTION_RESULT_DIED] = true,
	[ACTION_RESULT_DIED_XP] = true,
	[ACTION_RESULT_CANNOT_USE] = true,
	[ACTION_RESULT_FAILED_REQUIREMENTS] = true,
	[ACTION_RESULT_FEARED] = true,
	[ACTION_RESULT_CANT_SEE_TARGET] = true,
	[ACTION_RESULT_QUEUED] = true,
	[ACTION_RESULT_TARGET_TOO_CLOSE] = true,
	[ACTION_RESULT_FALL_DAMAGE] = true,
	[ACTION_RESULT_OFFBALANCE] = true,
	[ACTION_RESULT_DAMAGE_SHIELDED] = true,
	[ACTION_RESULT_STAGGERED] = true,
	[ACTION_RESULT_KNOCKBACK] = true,
	[ACTION_RESULT_FALLING] = true,
	[ACTION_RESULT_NO_LOCATION_FOUND] = true,
	[ACTION_RESULT_SPRINTING] = true,
	[ACTION_RESULT_SOUL_GEM_RESURRECTION_ACCEPTED] = true,
	[ACTION_RESULT_DOT_TICK] = true,
	[ACTION_RESULT_DOT_TICK_CRITICAL] = true,
	[ACTION_RESULT_HOT_TICK] = true,
	[ACTION_RESULT_HOT_TICK_CRITICAL] = true,

}

local function OnCombatEvent(eventCode, result, isError, abilityName, abilityGraphic, abilityActionSlotType, sourceName,
                             sourceType, targetName, targetType, hitValue, powerType, damageType, log, sourceUnitId,
                             targetUnitId, abilityId, overflow)

	if not unitDetectionResults[result] then return end

	if IsValidUnitData(sourceName, sourceUnitId, sourceType) then

		if UnitCache[sourceUnitId] == nil then
			UnitHandler:New(sourceName, sourceUnitId, sourceType)
		else
			UnitCache[sourceUnitId]:Update(sourceName, sourceType)
		end

	end

	if IsValidUnitData(targetName, targetUnitId, targetType) then

		if UnitCache[targetUnitId] == nil then
			UnitHandler:New(targetName, targetUnitId, targetType)
		else
			UnitCache[targetUnitId]:Update(targetName, targetType)
		end

	end
end

local function GetUnitTypeFromTag(unitTag)

	if unitTag == "player" then return COMBAT_UNIT_TYPE_PLAYER
	elseif unitTag == "companion" then return COMBAT_UNIT_TYPE_PLAYER_COMPANION
	elseif string.sub(unitTag,1,9) == "playerpet" then return COMBAT_UNIT_TYPE_PLAYER_PET
	elseif string.sub(unitTag,1,4) == "boss" then return COMBAT_UNIT_TYPE_OTHER
	elseif string.sub(unitTag,1,5) == "group" then
		if string.len(unitTag) < 8 then
			return COMBAT_UNIT_TYPE_GROUP
		else
			return COMBAT_UNIT_TYPE_GROUP_COMPANION
		end
	else return nil
	end

end

local function OnTargetChange()

	if not DoesUnitExist("reticleover") then

		if lcuint.unitIdsByTag["reticleover"] then 

			UpdateUnitTagId("reticleover", nil)
			Print("dev", LOG_LEVEL_INFO, "ReticleOverUnit removed.")

		end

		return
	end
	local numBuffs = GetNumBuffs("reticleover")

	for i = 1, numBuffs do

		local _, _, endTime, buffSlot, _, _, _, _, _, _, abilityId, _ = GetUnitBuffInfo("reticleover", i)

		local unitId = EffectCache[abilityId] and EffectCache[abilityId][endTime] or nil
		local unit = unitId and UnitCache[unitId] or nil

		if unit and unit.effectTimeData[buffSlot] == endTime then

			Print("dev", LOG_LEVEL_INFO, "ReticleOverUnit found: %s (%d)", unit.name, unitId)

			unit:UpdateUnitTag("reticleover")
			break

		end
	end

	Print("dev", LOG_LEVEL_INFO, "ReticleOverUnit not found: %s (%d buffs)", GetUnitName("reticleover"), numBuffs)
end

local function OnEffectChanged(eventCode, changeType, effectSlot, effectName, unitTag, beginTime, endTime, stackCount,
                               iconName, buffType, effectType, abilityType, statusEffectType, unitName, unitId, abilityId
                               , sourceType)

	local unitType = GetUnitTypeFromTag(unitTag)

	if IsValidUnitData(unitName, unitId, unitType) then	-- Allow even if unitType is not known?

		if UnitCache[unitId] == nil then
			UnitHandler:New(unitName, unitId, unitType, unitTag)
		else
			UnitCache[unitId]:Update(unitName, unitType, unitTag)
		end

	end

	if (changeType ~= EFFECT_RESULT_GAINED and changeType ~= EFFECT_RESULT_FADED and changeType ~= EFFECT_RESULT_UPDATED) or
		(effectType ~= BUFF_EFFECT_TYPE_BUFF and effectType ~= BUFF_EFFECT_TYPE_DEBUFF) then return end

	if IsValidUnitId(unitId) and UnitCache[unitId] then UnitCache[unitId]:UpdateEffectData(abilityId, changeType, endTime,
			effectSlot)
	end

	OnTargetChange()
end

-- UnitHandler

---@diagnostic disable-next-line: duplicate-set-field
function UnitHandler:Initialize(rawName, unitId, unitType, unitTag)

	if unitType == COMBAT_UNIT_TYPE_PLAYER then	UpdatePlayerId(unitId) end

	local name = ZO_CachedStrFormat(SI_UNIT_NAME, rawName) -- name

	self.unitId         = unitId
	self.name           = name
	self.rawName        = rawName
	self.unitType       = unitType -- type of unit: player, group, pet, companion, group_companion or boss
	self.effectData     = {}
	self.effectTimeData = {}

	if (unitTag == nil or unitTag == "") then self:LookupUnitTag() end

	local UnitIdByRawName = lcuint.unitIdsByRawName
	local UnitIdByName = lcuint.unitIdsByName

	if UnitIdByRawName[rawName] then table.insert(UnitIdByRawName[rawName], unitId) else UnitIdByRawName[rawName] = { unitId } end
	if UnitIdByName[name] then table.insert(UnitIdByName[name], unitId) else UnitIdByName[name] = { unitId } end

	self:UpdateUnitTag(unitTag)

	self.firstSeen = GetGameTimeSeconds()
	self.lastSeen = GetGameTimeSeconds()

	UnitCache[unitId] = self

	Print("dev", LOG_LEVEL_INFO, "New Unit: %s (%d, %d, %s)", name, unitId, unitType, unitTag or "")
end

function UnitHandler:LookupUnitTag()

	if self.unitType == nil then return end

	if     self.unitType == COMBAT_UNIT_TYPE_PLAYER     then self:UpdateUnitTag("player")
	elseif self.unitType == COMBAT_UNIT_TYPE_GROUP      then self:UpdateUnitTag(lcuint.groupTagByName[self.rawName]) -- Todo: Group Companion? 
	elseif self.unitType == COMBAT_UNIT_TYPE_PLAYER_PET then self:UpdateUnitTag(lcuint.petTagByName[self.rawName])
	else

		CheckForPetUnit(self.rawName, self.unitId)
		local bossTag = lcuint.bossTagByName[self.rawName]

		if bossTag then

			self.isBoss = true

			if bossTag ~= hasMultipleTags then

				self:UpdateUnitTag(bossTag)

			end
		end
	end
end

function UnitHandler:UpdateFriendlyStatus(unitType)

	self.isFriendly = false

	if unitType == COMBAT_UNIT_TYPE_PLAYER or unitType == COMBAT_UNIT_TYPE_GROUP or unitType == COMBAT_UNIT_TYPE_GROUP_COMPANION or unitType == COMBAT_UNIT_TYPE_PLAYER_PET then

		self.isFriendly = true

	end

end

function UnitHandler:Update(rawName, unitType, unitTag)

	self.lastSeen = GetGameTimeSeconds()

	if self.rawName ~= rawName then

		local unitId = self.unitId
		self:Delete()
		local unit = UnitHandler:New(rawName, unitId, unitType, unitTag)

		return
	end

	if unitTag then self:UpdateUnitTag(unitTag) end

	if unitType and self.unitType ~= unitType then

		Print("dev", "I", "unitType changed: %d -> %d %s (%d)", self.unitType, unitType, self.name, self.unitId)
		self.unitType = unitType

	end
end

function UnitHandler:UpdateUnitTagData(unitTag)

	-- TODO: check limitations and only update necessary values

	-- General
	self.gender = GetUnitGender(unitTag)

	-- Player characters	TODO: check classification
	self.displayName = GetUnitDisplayName(unitTag)
	self.class = GetUnitClass(unitTag)
	self.classId = GetUnitClassId(unitTag)
	self.CP = GetUnitChampionPoints(unitTag)
	self.effectiveCP = GetUnitEffectiveChampionPoints(unitTag)
	self.effectiveLevel = GetUnitEffectiveLevel(unitTag)

	-- Status
	self.isDead = IsUnitDead(unitTag)
	self.isReincarnating = IsUnitReincarnating(unitTag)
	self.isAlive = not IsUnitDeadOrReincarnating(unitTag)


	-- TODO: Add more data from unitTag if possible

end

function UnitHandler:UpdateUnitTag(newUnitTag)

	if newUnitTag == nil or newUnitTag == "" or (self.unitTags and self.unitTags[newUnitTag]) then return end

	local unitId = self.unitId
	self:UpdateUnitTagData(newUnitTag)

	if self.unitTags == nil then

		self.unitTags = { [newUnitTag] = newUnitTag }
		UpdateUnitTagId(newUnitTag, unitId)

	else

		for unitTag, _ in pairs(self.unitTags) do

			if AreUnitsEqual(unitTag, newUnitTag) == false then

				self.unitTags[unitTag] = nil -- this tag doesn't belong to this unit
				if lcuint.unitIdsByTag[unitTag] == unitId then lcuint.unitIdsByTag[unitTag] = nil end

			end
		end

		self.unitTags[newUnitTag] = newUnitTag
		UpdateUnitTagId(newUnitTag, unitId)
	end
end

function UnitHandler:RemoveUnitTag(unitTag)

	self.unitTags[unitTag] = nil

end

function UnitHandler:Delete()

	UnitCache[self.unitId] = nil
	UnitExportCache[self.unitId] = nil
	
	if self.unitTags then

		for _, unitTag in pairs(self.unitTags) do

			if self.unitId == lcuint.unitIdsByTag[unitTag] then lcuint.unitIdsByTag[unitTag] = nil end

		end
	end

	for i, unitId in ipairs(lcuint.unitIdsByRawName) do
		if unitId == self.unitId then

			table.remove(lcuint.unitIdsByRawName, i)
			table.remove(lcuint.unitIdsByName, i)
			break

		end
	end

	for effectSlot, abilityId in pairs(self.effectData) do	-- remove cached effects

		local endTime = self.effectTimeData[effectSlot]

		if EffectCache[abilityId] and EffectCache[abilityId][endTime] then EffectCache[abilityId][endTime] = nil end

	end
end

function UnitHandler:UpdateEffectData(abilityId, changeType, endTime, effectSlot)

	local effectData = self.effectData
	local effectTimeData = self.effectTimeData

	if changeType == EFFECT_RESULT_GAINED or changeType == EFFECT_RESULT_UPDATED then

		effectData[effectSlot]     = abilityId -- effectSlot should be unique per unit
		effectTimeData[effectSlot] = endTime

		EffectCache[abilityId] = EffectCache[abilityId] or {}
		EffectCache[abilityId][endTime] = self.unitId

	elseif changeType == EFFECT_RESULT_FADED then

		effectData[effectSlot] = nil
		effectTimeData[effectSlot] = nil

		if EffectCache[abilityId] and EffectCache[abilityId][endTime] then EffectCache[abilityId][endTime] = nil end

	end
end

-- Unit object for exporting info

---@diagnostic disable-next-line: duplicate-set-field
function UnitAPIHandler:Initialize(unitId)

	self.unitId = unitId

	UnitExportCache[unitId] = self

end

function UnitAPIHandler:GetFullUnitData()

	local unitData = {

		["unitId"]   = self.unitId,
		["name"]     = self:GetUnitName(),
		["rawName"]  = self:GetUnitRawName(),
		["unitType"] = self:GetUnitType()

	}

	return unitData

end

function UnitAPIHandler:GetUnitName()

	return UnitCache[self.unitId].name

end

function UnitAPIHandler:GetUnitRawName()

	return UnitCache[self.unitId].rawName

end

function UnitAPIHandler:GetUnitType()

	return UnitCache[self.unitId].unitType

end

function UnitAPIHandler:GetUnitTags()

	return UnitCache[self.unitId].unitTags

end

local function GetExportUnit(unitId)

	return UnitExportCache[unitId] or UnitAPIHandler:New(unitId)

end

-- API

function lcu.GetUnitByTag(unitTag)

	local unitId = lcuint.unitIdsByTag[unitTag]

	return GetExportUnit(unitId)

end

function lcu.GetUnitIdByTag(unitTag)

	return lcuint.unitIdsByTag[unitTag]

end

function lcu.GetUnitsByName(unitName)

	local unitIds = lcuint.unitIdsByName[unitName]

	local units = {}

	for i, unitId in ipairs(unitIds) do
		units[i] = GetExportUnit(unitId)
	end

	return unpack(units)
end

function lcu.GetUnitIdsByName(unitName)

	return unpack(lcuint.unitIdsByName[unitName])

end

function lcu.GetUnitsByRawName(unitName)

	local unitIds = lcuint.unitIdsByRawName[unitName]

	local units = {}

	for i, unitId in ipairs(unitIds) do
		units[i] = GetExportUnit(unitId)
	end

	return unpack(units)

end

function lcu.GetUnitIdsByRawName(unitName)

	return unpack(lcuint.unitIdsByRawName[unitName])

end

function lcu.GetUnitById(unitId)

	return GetExportUnit(unitId)

end

-- Debug Utilities

local logBase = math.log(5)

local function GetUnitSummary() -- gives a list of all units with names and id and the laast seen time: 

	local unitData = {}

	local now  = GetGameTimeSeconds()

	for unitId, unit in pairs(UnitCache) do

		unitData[unitId] = {
			["unitName"] = unit.name,
			["lastSeenRange"] = math.log(now - unit.lastSeen) / logBase,

		}

	end

	return unitData
end

local function InitDebugPanel()

	local tlw = wm:CreateTopLevelWindow("LCUDebugPanel")
	local bg = wm:CreateControl("Bg", tlw, CT_BACKDROP)
	wm:ApplyTemplateToControl(bg, "ZO_EditBackdrop")
	local textbox = wm:CreateControl("TextBox", tlw, CT_EDITBOX)
	wm:ApplyTemplateToControl(textbox, "ZO_DefaultEditForBackdrop")
	wm:ApplyTemplateToControl(textbox, "ZO_EditDefaultText")
	
	tlw:SetMouseEnabled(true)
	tlw:SetMovable(true)
	tlw:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, 0, 0)
	tlw:SetDimensions(500, 1000)
	
	bg:SetAnchorFill(tlw)
	
	---@cast textbox EditControl
	textbox:SetAnchorFill(tlw)
	textbox:SetMultiLine(true)
	textbox:SetNewLineEnabled(true)
	textbox:SetAllowMarkupType(ALLOW_MARKUP_TYPE_ALL)
	textbox:SetFont("$(MEDIUM_FONT)|$(KB_14)")
	textbox:SetText("TEST TEST \n TEST", true)
	textbox:SetMaxInputChars(10000)
	textbox:SetMouseEnabled(false)

	local debugPanel = lcuint.debugPanel
	debugPanel.tlw = tlw
	debugPanel.textbox = textbox
	debugPanel.init = true

end

local function UnitSummaryOrder(table, a, b)

	local ishigher = false

	local lastSeenRangeA = table[a].lastSeenRange*10
	local lastSeenRangeB = table[b].lastSeenRange*10

	if lastSeenRangeB - lastSeenRangeA > 0.1 then ishigher = true
	elseif math.abs(lastSeenRangeA - lastSeenRangeB) < 0.1 then ishigher = b > a end

	return ishigher
end

local typeStrings = {
	[0] = "npc", -- COMBAT_UNIT_TYPE_NONE
	[1] = "player", -- COMBAT_UNIT_TYPE_PLAYER
	[2] = "pet", -- COMBAT_UNIT_TYPE_PLAYER_PET
	[3] = "group", -- COMBAT_UNIT_TYPE_GROUP
	[4] = "other", -- COMBAT_UNIT_TYPE_OTHER
	[5] = "dummy", -- COMBAT_UNIT_TYPE_TARGET_DUMMY
	[6] = "companion", -- COMBAT_UNIT_TYPE_GROUP_COMPANION
}
local function UpdateDebugPanel()

	local unitData = GetUnitSummary()
	local now = GetGameTimeSeconds()

	local stringArray = {}

	local lines = 0

	for unitId, unitData in spairs(unitData, UnitSummaryOrder) do

		local unit = UnitCache[unitId]

		local g = (4 - math.min(math.max(2, unitData.lastSeenRange), 4)) / 2
		local r = math.min(math.max(1, unitData.lastSeenRange), 2)-1

		local tags = {}

		for unitTag, _ in pairs(unit.unitTags or {}) do
			tags[#tags+1] = unitTag
		end

		local tags = table.concat(tags, ", ")
		local type = typeStrings[unit.unitType]

		local string = string.format("%s (%d, %s, %s): %.1f", unit.name, unitId, type, tags, now - unit.lastSeen)

		stringArray[#stringArray+1] = string.format("|c%.2x%.2x%.2x%s|r", math.floor(r * 255), math.floor(g * 255), 0, string)

		lines = lines + 1

		if lines >= 40 then break end

	end

	local fullstring = table.concat(stringArray, "\n")

	lcuint.debugPanel.textbox:SetText(fullstring)
end

function lcuint.toggleDebug(override)

	lcuint.debug = override or (not lcuint.debug)

	if lcuint.debug then

		if lcuint.debugPanel.init == false then InitDebugPanel() end
		lcuint.debugPanel.tlw:SetHidden(false)
		em:RegisterForUpdate("LCU_DebugPanel", 500, UpdateDebugPanel)

	else

		lcuint.debugPanel.tlw:SetHidden(true)
		em:UnregisterForUpdate("LCU_DebugPanel")

	end

	lcuint.debugPanel.tlw:SetHidden(not lcuint.debug)
end

-- Init

local function RegisterEvents()

	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_COMBAT_EVENT, OnCombatEvent)
	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_EFFECT_CHANGED, OnEffectChanged)
	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_RETICLE_TARGET_CHANGED , OnTargetChange)

	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_GROUP_UPDATE, onGroupChange)
	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_PLAYER_ACTIVATED, onGroupChange)
	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_BOSSES_CHANGED, onBossesChanged)
	EVENT_MANAGER:RegisterForEvent(lcu.name, EVENT_PLAYER_ACTIVATED, onBossesChanged)
	EVENT_MANAGER:RegisterForUpdate(lcu.name, 500, onPlayerPetsChanged) --  TODO: find better way to determine if pets changed

end

local function onAddonLoaded(_, addonName)

	if addonName ~= lcu.name then return end

	EVENT_MANAGER:UnregisterForEvent(lcu.name, EVENT_ADD_ON_LOADED)

	lcuint.rawPlayername = GetRawUnitName("player")
	lcuint.playername = ZO_CachedStrFormat(SI_UNIT_NAME, lcuint.rawPlayername)
	lcuint.accountname = ZO_CachedStrFormat(SI_UNIT_NAME, GetDisplayName())

	RegisterEvents()

	Print("dev", LOG_LEVEL_INFO, "Initialized.")

	SLASH_COMMANDS["/lcudebug"] = lcuint.toggleDebug

end

em:RegisterForEvent(lcu.name, EVENT_ADD_ON_LOADED, onAddonLoaded)