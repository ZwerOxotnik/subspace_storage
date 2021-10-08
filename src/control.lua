require("util")
require("config")
local mod_gui = require("mod-gui")

local clusterio_api = require("__clusterio_lib__/api")

local compat = require("compat")


local restrictionEnabled = settings.global["subspace_storage-range-restriction-enabled"].value
local zoneWidth = settings.global["subspace_storage-zone-width"].value
local zoneHeight = settings.global["subspace_storage-zone-height"].value


local SUBSPACE_ENTITIES = {
	["subspace-item-injector"] = function(entity)
		--add the chests to a lists if these chests so they can be interated over
		table.insert(global.inputChestsData.entitiesData, {
			entity = entity,
			inv = entity.get_inventory(defines.inventory.chest)
		})
	end,
	["subspace-item-extractor"] = function(entity)
		--add the chests to a lists if these chests so they can be interated over
		table.insert(global.outputChestsData.entitiesData, {
			entity = entity,
			inv = entity.get_inventory(defines.inventory.chest),
		})
	end,
	["subspace-fluid-injector"] = function(entity)
		--add the chests to a lists if these chests so they can be interated over
		table.insert(global.inputTanksData.entitiesData, {
			entity = entity,
			fluidbox = entity.fluidbox
		})
	end,
	["subspace-fluid-extractor"] = function(entity)
		--add the chests to a lists if these chests so they can be interated over
		table.insert(global.outputTanksData.entitiesData, {
			entity = entity,
			fluidbox = entity.fluidbox
		})
		--previous version made then inactive which isn't desired anymore
		entity.active = true
	end,
	[INV_COMBINATOR_NAME] = function(entity)
		global.invControls[entity.unit_number] = entity.get_or_create_control_behavior()
		entity.operable=false
	end,
	["subspace-electricity-injector"] = function(entity)
		table.insert(global.inputElectricityData.entitiesData, {
			entity = entity
		})
	end,
	["subspace-electricity-extractor"] = function(entity)
		table.insert(global.outputElectricityData.entitiesData, {
			entity = entity,
			bufferSize = entity.electric_buffer_size
		})
	end
}
local function AddEntity(entity)
	local f = SUBSPACE_ENTITIES[entity.name]
	if f then f(entity) end
end


--------------------
--[[Misc methods]]--
--------------------
local function RequestItemsFromUseableStorage(itemName, itemCount)
	--if infinite resources then the whole request is approved
	if global.hasInfiniteResources then
		return itemCount
	end

	--if result is nil then there is no items in storage
	--which means that no items can be given
	if global.useableItemStorage[itemName] == nil then
		return 0
	end
	--if the number of items in storage is lower than the number of items
	--requested then take the number of items there are left otherwise take the requested amount
	local itemData = global.useableItemStorage[itemName]
	local remainingItems = itemData.remainingItems
	local itemsTakenFromStorage = math.min(remainingItems, itemCount)
	itemData.remainingItems = remainingItems - itemsTakenFromStorage

	return itemsTakenFromStorage
end

local function GetInitialItemCount(itemName)
	--this method is used so the mod knows hopw to distribute
	--the items between all entities. If infinite resources is enabled
	--then all entities should get their requests fulfilled-
	--To simulate that this method returns 1mil which should be enough
	--for all entities to fulfill their whole item request
	if global.hasInfiniteResources then
		return 1000000 --1.000.000
	end

	if global.useableItemStorage[itemName] == nil then
		return 0
	end
	return global.useableItemStorage[itemName].initialItemCount
end

local function GiveItemsToUseableStorage(itemName, itemCount)
	if global.useableItemStorage[itemName] == nil then
		global.useableItemStorage[itemName] =
		{
			initialItemCount = 0,
			remainingItems = 0
		}
	end
	global.useableItemStorage[itemName].remainingItems = global.useableItemStorage[itemName].remainingItems + itemCount
end

local function GiveItemsToStorage(itemName, itemCount)
	--if this is called for the first time for an item then the result
	--is nil. if that's the case then set the result to 0 so it can
	--be used in arithmetic operations
	global.itemStorage[itemName] = (global.itemStorage[itemName] or 0) + itemCount
end

local function AddItemToInputList(itemName, itemCount)
	global.inputList[itemName] = (global.inputList[itemName] or 0) + itemCount
end

local function AddItemToOutputList(itemName, itemCount)
	global.outputList[itemName] = (global.outputList[itemName] or 0) + itemCount
end

local function isItemLegal(name)
	for _,itemName in pairs(global.config.BWitems) do
		if itemName==name then
			return global.config.item_is_whitelist
		end
	end
	return not global.config.item_is_whitelist
end

local function isFluidLegal(name)
	for _,itemName in pairs(global.config.BWfluids) do
		if itemName==name then
			return global.config.fluid_is_whitelist
		end
	end
	return not global.config.fluid_is_whitelist
end

----------------------------------------
--[[Methods that talk with Clusterio]]--
----------------------------------------
local function ExportInputList()
	local items = {}
	for name, count in pairs(global.inputList) do
		table.insert(items, {name, count})
	end
	global.inputList = {}
	if #items > 0 then
		clusterio_api.send_json("subspace_storage:output", items)
	end
end

local function ExportOutputList()
	local items = {}
	for name, count in pairs(global.outputList) do
		table.insert(items, {name, count})
	end
	global.outputList = {}
	if #items > 0 then
		clusterio_api.send_json("subspace_storage:orders", items)
	end
end

function Import(data)
	local items = game.json_to_table(data)
	for _, item in ipairs(items) do
		GiveItemsToStorage(item[1], item[2])
	end
end

local function UpdateInvCombinators()
	-- Update all inventory Combinators
	-- Prepare a frame from the last inventory report, plus any virtuals
	local invframe = {}
	local instance_id = clusterio_api.get_instance_id()
	if instance_id then
		table.insert(invframe,{count=instance_id,index=#invframe+1,signal={name="signal-localid",type="virtual"}})
	end

	local items = game.item_prototypes
	local fluids = game.fluid_prototypes
	local virtuals = game.virtual_signal_prototypes
	if global.invdata then
		for name, count in pairs(global.invdata) do
			-- Combinator signals are limited to a max value of 2^31-1
			count = math.min(count, 0x7fffffff)
			if virtuals[name] then
				invframe[#invframe+1] = {count=count,index=#invframe+1,signal={name=name,type="virtual"}}
			elseif fluids[name] then
				invframe[#invframe+1] = {count=count,index=#invframe+1,signal={name=name,type="fluid"}}
			elseif items[name] then
				invframe[#invframe+1] = {count=count,index=#invframe+1,signal={name=name,type="item"}}
			end
		end
	end

	for i,invControl in pairs(global.invControls) do
		if invControl.valid then
			compat.set_parameters(invControl, invframe)
			invControl.enabled=true
		end
	end
end

function UpdateInvData(data, full)
	if full then
		global.invdata = {}
	end
	local items = game.json_to_table(data)
	for _, item in ipairs(items) do
		global.invdata[item[1]] = item[2]
	end
	UpdateInvCombinators()
end


local SUBSPACE_ENTITIES_FOR_BUILT = {
	["subspace-item-injector"] = true,
	["subspace-item-extractor"] = true,
	["subspace-fluid-injector"] = true,
	["subspace-fluid-extractor"] = true
}
------------------------------------------------------------
--[[Method that handle creation and deletion of entities]]--
------------------------------------------------------------
local function OnBuiltEntity(event)
	local entity = event.created_entity
	if not (entity and entity.valid) then return end

	local player = false
	if event.player_index then player = game.get_player(event.player_index) end

	local spawn
	if player and player.valid then
		spawn = player.force.get_spawn_position(entity.surface)
	else
		spawn = game.forces.player.get_spawn_position(entity.surface)
	end
	local x = entity.position.x - spawn.x
	local y = entity.position.y - spawn.y

	local name = entity.name
	if name == "entity-ghost" then name = entity.ghost_name end

	if restrictionEnabled and SUBSPACE_ENTITIES_FOR_BUILT[name] then
		if ((zoneWidth == 0 or (math.abs(x) < zoneWidth / 2)) and (zoneHeight == 0 or (math.abs(y) < zoneHeight / 2))) then
			--only add entities that are not ghosts
			if entity.type ~= "entity-ghost" then
				AddEntity(entity)
			end
		else
			if player and player.valid then
				-- Tell the player what is happening
				if player then player.print("Subspace interactor outside allowed area (placed at x "..x.." y "..y.." out of allowed "..(zoneWidth > 0 and zoneWidth or "inf").. " x "..(zoneHeight > 0 and zoneHeight or "inf")..")") end
				-- kill entity, try to give it back to the player though
				if not player.mine_entity(entity, true) then
					entity.destroy()
				end
			else
				-- it wasn't placed by a player, we can't tell em whats wrong
				entity.destroy()
			end
		end
	else
		--only add entities that are not ghosts
		if entity.type ~= "entity-ghost" then
			AddEntity(entity)
		end
	end
end

local function TableWithKeysLength(tableA)
	local count = 0
	for k, v in pairs(tableA) do
		count = count + 1
	end
	return count
end

local function AddRequestToTable(requests, itemName, missingAmount, storage)
	--If this is the first entry for this item type then
	--create a table for this item type first
	if requests[itemName] == nil then
		requests[itemName] =
		{
			requestedAmount = 0,
			requesters = {}
		}
	end

	local itemEntry = requests[itemName]

	--Add missing item to the count and add this chest inv to the list
	itemEntry.requestedAmount = itemEntry.requestedAmount + missingAmount
	itemEntry.requesters[#itemEntry.requesters + 1] =
	{
		storage = storage,
		missingAmount = missingAmount
	}

	return itemEntry.requesters[#itemEntry.requesters]
end

local function GetOutputChestRequest(requests, entityData)
	local entity = entityData.entity
	local chestInventory = entityData.inv
	--Don't insert items into the chest if it's being deconstructed
	--as that just leads to unnecessary bot work
	if entity.valid and not entity.to_be_deconstructed(entity.force) then
		--Go though each request slot
		for i = 1, entity.request_slot_count do
			local requestItem = entity.get_request_slot(i)

			--Some request slots may be empty and some items are not allowed
			--to be imported
			if requestItem ~= nil and isItemLegal(requestItem.name) then
				local itemsInChest = chestInventory.get_item_count(requestItem.name)

				--If there isn't enough items in the chest
				local missingAmount = requestItem.count - itemsInChest
				if missingAmount > 0 then
					local entry = AddRequestToTable(requests, requestItem.name, missingAmount, entity)
					entry.inv = chestInventory
				end
			end
		end
	end
end

local function GetOutputTankRequest(requests, entityData)
	local entity = entityData.entity
	local fluidbox = entityData.fluidbox
	--The type of fluid the tank should output
	--is determined by the recipe set in the  entity.
	--If no recipe is set then it shouldn't output anything

	if entity.valid then
		local recipe = entity.get_recipe()
		if recipe == nil then
			return
		end
		--Get name of the fluid to output
		local fluidName = recipe.products[1].name
		--Some fluids may be illegal. If that's the case then don't process them
		if isFluidLegal(fluidName) then
			--Either get the current fluid or reset it to the requested fluid
			local fluid = fluidbox[1] or {name = fluidName, amount = 0}

			--If the current fluid isn't the correct fluid
			--then remove that fluid
			if fluid.name ~= fluidName then
				fluid = {name = fluidName, amount = 0}
			end

			local missingFluid = math.max(math.ceil(MAX_FLUID_AMOUNT - fluid.amount), 0)
			--If the entity is missing fluid than add a request for fluid
			if missingFluid > 0 then
				local entry = AddRequestToTable(requests, fluidName, missingFluid, entity)
				entry.fluidbox = fluidbox
			end
		end
	end
end

local function GetOutputElectricityRequest(requests, entityData)
	local entity = entityData.entity
	local bufferSize = entityData.bufferSize
	if entity.valid then
		local energy = entity.energy
		local missingElectricity = math.floor((bufferSize - energy) / ELECTRICITY_RATIO)
		if missingElectricity > 0 then
			local entry = AddRequestToTable(requests, ELECTRICITY_ITEM_NAME, missingElectricity, entity)
			entry.energy = energy
		end
	end
end

local function AddAllEntitiesOfNames(names)
	for _, surface in pairs(game.surfaces) do
		for _, name in ipairs(names) do
			for _, entity in pairs(surface.find_entities_filtered{ name = name }) do
				AddEntity(entity)
			end
		end
	end
end

local function RemoveEntity(list, entity)
	for i, v in ipairs(list) do
		if v.entity == entity then
			table.remove(list, i)
			break
		end
	end
end

local DESTROYED_SUBSPACE_ENTITIES = {
	["subspace-item-injector"] = function(entity)
		RemoveEntity(global.inputChestsData.entitiesData, entity)
	end,
	["subspace-item-extractor"] = function(entity)
		RemoveEntity(global.outputChestsData.entitiesData, entity)
	end,
	["subspace-fluid-injector"] = function(entity)
		RemoveEntity(global.inputTanksData.entitiesData, entity)
	end,
	["subspace-fluid-extractor"] = function(entity)
		RemoveEntity(global.outputTanksData.entitiesData, entity)
	end,
	[INV_COMBINATOR_NAME] = function(entity)
		global.invControls[entity.unit_number] = nil
	end,
	["subspace-electricity-injector"] = function(entity)
		RemoveEntity(global.inputElectricityData.entitiesData, entity)
	end,
	["subspace-electricity-extractor"] = function(entity)
		RemoveEntity(global.outputElectricityData.entitiesData, entity)
	end,
}
local function OnKilledEntity(event)
	local entity = event.entity
	if entity.type ~= "entity-ghost" then
		--remove the entities from the tables as they are dead
		local f = DESTROYED_SUBSPACE_ENTITIES[entity.name]
		if f then f(entity) end
	end
end


-----------------------------
--[[Thing creation events]]--
-----------------------------
script.on_event(defines.events.on_built_entity, OnBuiltEntity)
script.on_event(defines.events.on_robot_built_entity, OnBuiltEntity)


----------------------------
--[[Thing killing events]]--
----------------------------
do
	local filter = {
		{filter = "name", name = "subspace-item-injector", mode = "or"},
		{filter = "name", name = "subspace-item-extractor", mode = "or"},
		{filter = "name", name = "subspace-fluid-injector", mode = "or"},
		{filter = "name", name = "subspace-fluid-extractor", mode = "or"},
		{filter = "name", name = INV_COMBINATOR_NAME, mode = "or"},
		{filter = "name", name = "subspace-electricity-injector", mode = "or"},
		{filter = "name", name = "subspace-electricity-extractor", mode = "or"}
	}
	script.on_event(defines.events.on_entity_died, OnKilledEntity, filter)
	script.on_event(defines.events.on_robot_pre_mined, OnKilledEntity, filter)
	script.on_event(defines.events.on_pre_player_mined_item, OnKilledEntity, filter)
	script.on_event(defines.events.script_raised_destroy, OnKilledEntity, filter)
end


------------------------
--[[Clusterio events]]--
------------------------
local function RegisterClusterioEvents()
	script.on_event(clusterio_api.events.on_instance_updated, UpdateInvCombinators)
end

------------------------------
--[[Thing resetting events]]--
------------------------------
function Reset()
	global.ticksSinceMasterPinged = 601
	global.isConnected = false
	global.prevIsConnected = false
	global.allowedToMakeElectricityRequests = false
	global.workTick = 0
	global.hasInfiniteResources = false

	if global.config == nil then
		global.config =
		{
			BWitems = {},
			item_is_whitelist = false,
			BWfluids = {},
			fluid_is_whitelist = false,
		}
	end
	if global.invdata == nil then
		global.invdata = {}
	end

	rendering.clear("subspace_storage")
	global.zoneDraw = {}

	global.outputList = {}
	global.inputList = {}
	global.itemStorage = {}
	global.useableItemStorage = {}

	global.inputChestsData =
	{
		entitiesData = { pos = 0 },
	}
	global.outputChestsData =
	{
		entitiesData = { pos = 0 },
		requests = {},
		requestsLL = nil
	}

	global.inputTanksData =
	{
		entitiesData = { pos = 0 },
	}
	global.outputTanksData =
	{
		entitiesData = { pos = 0 },
		requests = {},
		requestsLL = nil
	}

	global.inputElectricityData =
	{
		entitiesData = { pos = 0 },
	}
	global.outputElectricityData =
	{
		entitiesData = { pos = 0 },
		requests = {},
		requestsLL = nil
	}
	global.lastElectricityUpdate = 0
	global.maxElectricity = 100000000000000 / ELECTRICITY_RATIO --100TJ assuming a ratio of 1.000.000

	global.invControls = {}

	AddAllEntitiesOfNames(
	{
		"subspace-item-injector",
		"subspace-item-extractor",
		"subspace-fluid-injector",
		"subspace-fluid-extractor",
		INV_COMBINATOR_NAME,
		"subspace-electricity-injector",
		"subspace-electricity-extractor"
	})
end

script.on_init(function()
	clusterio_api.init()
	RegisterClusterioEvents()
	Reset()
end)

script.on_load(function()
	clusterio_api.init()
	RegisterClusterioEvents()
end)

script.on_configuration_changed(function(data)
	if data.mod_changes and data.mod_changes["subspace_storage"] then
		Reset()
	end
end)

----------------------------------------
--[[Getter and setter update methods]]--
----------------------------------------
local function ResetRequestGathering()
	global.outputChestsData.entitiesData.pos = 0
	global.outputChestsData.requests = {}

	global.outputTanksData.entitiesData.pos = 0
	global.outputTanksData.requests = {}

	global.outputElectricityData.entitiesData.pos = 0
	global.outputElectricityData.requests = {}
end

local function ResetFulfillRequestIterators()
	global.outputChestsData.requestsLL.pos = 0
	global.outputTanksData.requestsLL.pos = 0
	global.outputElectricityData.requestsLL.pos = 0
end

local function ResetPutterIterators()
	global.inputChestsData.entitiesData.pos = 0
	global.inputTanksData.entitiesData.pos = 0
	global.inputElectricityData.entitiesData.pos = 0
end

local function PrepareRequests(array, shouldSort)
	local requests = { pos = 0 }
	for itemName, requestInfo in pairs(array) do
		if shouldSort then
			--To be able to distribute it fairly, the requesters need to be sorted in order of how
			--much they are missing, so the requester with the least missing of the item will be first.
			--If this isn't done then there could be items leftover after they have been distributed
			--even though they could all have been distributed if they had been distributed in order.
			table.sort(requestInfo.requesters, function(left, right)
				return left.missingAmount < right.missingAmount
			end)
		end

		for i = 1, #requestInfo.requesters do
			local request = requestInfo.requesters[i]
			request.itemName = itemName
			request.requestedAmount = requestInfo.requestedAmount
			table.insert(requests, request)
		end
	end

	return requests
end

local function PrepareToFulfillRequests()
	global.outputChestsData.requestsLL      = PrepareRequests(global.outputChestsData.requests     , true)
	global.outputTanksData.requestsLL       = PrepareRequests(global.outputTanksData.requests      , false)
	global.outputElectricityData.requestsLL = PrepareRequests(global.outputElectricityData.requests, false)
end

local function iterator(state, pos)
	if pos >= state.endpoint or pos >= #state.list then
		return nil, nil
	end
	return pos + 1, state.list[pos + 1]
end

-- Iterates through a sequence over a number of separate runs
local function partial_ipairs(list, runs_left)
	local pos = list.pos
	local endpoint = pos + math.max(0, math.ceil((#list - pos) / runs_left))
	list.pos = endpoint
	return iterator, { list = list, endpoint = endpoint }, pos
end

local function RetrieveGetterRequests(allowedToGetElectricityRequests, ticksLeft)
	local chestData = global.outputChestsData.entitiesData
	for _, data in partial_ipairs(chestData, ticksLeft) do
		GetOutputChestRequest(global.outputChestsData.requests, data)
	end

	local tankData = global.outputTanksData.entitiesData
	for _, data in partial_ipairs(tankData, ticksLeft) do
		GetOutputTankRequest(global.outputTanksData.requests, data)
	end

	if allowedToGetElectricityRequests then
		local electricityData = global.outputElectricityData.entitiesData
		for _, data in partial_ipairs(electricityData, ticksLeft) do
			GetOutputElectricityRequest(global.outputElectricityData.requests, data)
		end
	end
end

local function HandleInputChest(entityData)
	local entity = entityData.entity
	local inventory = entityData.inv
	if entity.valid then
		local stack = {name = "", count = 1}
		for itemName, itemCount in pairs(inventory.get_contents()) do
			if isItemLegal(itemName) then
				AddItemToInputList(itemName, itemCount)
				stack.name = itemName
				stack.count = itemCount
				inventory.remove(stack)
			end
		end
	end
end

local function HandleInputTank(entityData)
	local entity  = entityData.entity
	local fluidbox = entityData.fluidbox
	if entity.valid then
		local fluid = fluidbox[1]
		if fluid ~= nil and math.floor(fluid.amount) > 0 then
			if isFluidLegal(fluid.name) then
				if fluid.amount > 1 then
					local fluid_taken = math.ceil(fluid.amount) - 1
					AddItemToInputList(fluid.name, fluid_taken)
					fluid.amount = fluid.amount - fluid_taken
					fluidbox[1] = fluid
				end
			end
		end
	end
end

local function HandleInputElectricity(entityData)
	--if there is too much energy in the network then stop outputting more
	if global.invdata and global.invdata[ELECTRICITY_ITEM_NAME] and global.invdata[ELECTRICITY_ITEM_NAME] >= global.maxElectricity then
		return
	end

	local entity = entityData.entity
	if entity.valid then
		local energy = entity.energy
		local availableEnergy = math.floor(energy / ELECTRICITY_RATIO)
		if availableEnergy > 0 then
			AddItemToInputList(ELECTRICITY_ITEM_NAME, availableEnergy)
			entity.energy = energy - (availableEnergy * ELECTRICITY_RATIO)
		end
	end
end

local function OutputChestInputMethod(request, itemName, evenShareOfItems)
	if request.storage.valid then
		return request.inv.insert({name = itemName, count = evenShareOfItems})
	else
		return 0
	end
end

local function OutputTankInputMethod(request, fluidName, evenShareOfFluid)
	if request.storage.valid then
		local fluid = request.fluidbox[1] or {name = fluidName, amount = 0}
		fluid.amount = fluid.amount + evenShareOfFluid

		--Need to set steams heat because otherwise it's too low
		if fluid.name == "steam" then
			fluid.temperature = 165
		end

		request.fluidbox[1] = fluid
		return evenShareOfFluid
	else
		return 0
	end
end

local function EvenlyDistributeItems(request, functionToInsertItems)
	--Take the required item count from storage or how much storage has
	local itemCount = RequestItemsFromUseableStorage(request.itemName, request.requestedAmount)

	--need to scale all the requests according to how much of the requested items are available.
	--Can't be more than 100% because otherwise the chests will overfill
	local avaiableItemsRatio = math.min(GetInitialItemCount(request.itemName) / request.requestedAmount, 1)
	--Floor is used here so no chest uses more than its fair share.
	--If they used more then the last entity would bet less which would be
	--an issue with +1000 entities requesting items.
	local chestHold = math.floor(request.missingAmount * avaiableItemsRatio)
	--If there is less items than requests then floor will return zero and thus not
	--distributes the remaining items. Thus here the mining is set to 1 but still
	--it can't be set to 1 if there is no more items to distribute, which is what
	--the last min corresponds to.
	chestHold = math.max(chestHold, 1)
	chestHold = math.min(chestHold, itemCount)

	--If there wasn't enough items to fulfill the whole request
	--then ask for more items from outside the game
	local missingItems = request.missingAmount - chestHold
	if missingItems > 0 then
		AddItemToOutputList(request.itemName, missingItems)
	end

	if itemCount > 0 then
		--No need to insert 0 of something
		if chestHold > 0 then
			local insertedItemsCount = functionToInsertItems(request, request.itemName, chestHold)
			itemCount = itemCount - insertedItemsCount
		end

		--In some cases it's possible for the entity to not use up
		--all the items.
		--In those cases the items should be put back into storage.
		if itemCount > 0 then
			GiveItemsToUseableStorage(request.itemName, itemCount)
		end
	end
end

local function OutputElectricityinputMethod(request, _, evenShare)
	if request.storage.valid then
		request.storage.energy = request.energy + (evenShare * ELECTRICITY_RATIO)
		return evenShare
	else
		return 0
	end
end

local function FulfillGetterRequests(allowedToGetElectricityRequests, ticksLeft)
	local chestRequests = global.outputChestsData.requestsLL
	for _, data in partial_ipairs(chestRequests, ticksLeft) do
		EvenlyDistributeItems(data, OutputChestInputMethod)
	end

	local tankRequests = global.outputTanksData.requestsLL
	for _, data in partial_ipairs(tankRequests, ticksLeft) do
		EvenlyDistributeItems(data, OutputTankInputMethod)
	end

	if allowedToGetElectricityRequests then
		local electricityRequests = global.outputElectricityData.requestsLL
		for _, data in partial_ipairs(electricityRequests, ticksLeft) do
			EvenlyDistributeItems(data, OutputElectricityinputMethod)
		end
	end
end

local function UpdateUseableStorage()
	local useableItemStorage = global.useableItemStorage
	for k, v in pairs(global.itemStorage) do
		GiveItemsToUseableStorage(k, v)
		useableItemStorage[k].initialItemCount = useableItemStorage[k].remainingItems
	end
	global.itemStorage = {}
end

local function EmptyPutters(ticksLeft)
	local chestData = global.inputChestsData.entitiesData
	for _, data in partial_ipairs(chestData, ticksLeft) do
		HandleInputChest(data)
	end

	local tankData = global.inputTanksData.entitiesData
	for _, data in partial_ipairs(tankData, ticksLeft) do
		HandleInputTank(data)
	end

	local electricityData = global.inputElectricityData.entitiesData
	for _, data in partial_ipairs(electricityData, ticksLeft) do
		HandleInputElectricity(data)
	end
end

script.on_event(defines.events.on_tick, function(event)

	--If the mod isn't connected then still pretend that it's
	--so items requests and removals can be fulfilled
	if global.hasInfiniteResources then
		global.ticksSinceMasterPinged = 0
	end

	global.ticksSinceMasterPinged = global.ticksSinceMasterPinged + 1
	if global.ticksSinceMasterPinged < 300 then
		global.isConnected = true


		if global.prevIsConnected == false then
			global.workTick = 0
		end

		if global.workTick == 0 then
			--importing electricity should be limited because it requests so
			--much at once. If it wasn't limited then the electricity could
			--make small burst of requests which requests >10x more than it needs
			--which could temporarily starve other networks.
			--Updating every 4 seconds give two chances to give electricity in
			--the 10 second period.
			local timeSinceLastElectricityUpdate = game.tick - global.lastElectricityUpdate
			global.allowedToMakeElectricityRequests = timeSinceLastElectricityUpdate > 60 * 3.5
		end

		--First retrieve requests and then fulfill them
		if global.workTick >= 0 and global.workTick < TICKS_TO_COLLECT_REQUESTS then
			if global.workTick == 0 then
				ResetRequestGathering()
			end
			RetrieveGetterRequests(global.allowedToMakeElectricityRequests, TICKS_TO_COLLECT_REQUESTS - global.workTick)
		elseif global.workTick >= TICKS_TO_COLLECT_REQUESTS and global.workTick < TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS then
			if global.workTick == TICKS_TO_COLLECT_REQUESTS then
				UpdateUseableStorage()
				PrepareToFulfillRequests()
				ResetFulfillRequestIterators()
			end
			local ticksLeft = (TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS) - global.workTick
			FulfillGetterRequests(global.allowedToMakeElectricityRequests, ticksLeft)
		end

		--Emptying putters will continiously happen
		--while requests are gathered and fulfilled
		if global.workTick >= 0 and global.workTick < TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS then
			if global.workTick == 0 then
				ResetPutterIterators()
			end
			EmptyPutters((TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS) - global.workTick)
		end

		if global.workTick == TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS + 0 then
			ExportInputList()
			global.workTick = global.workTick + 1
		elseif global.workTick == TICKS_TO_COLLECT_REQUESTS + TICKS_TO_FULFILL_REQUESTS + 1 then
			ExportOutputList()

			--Restart loop
			global.workTick = 0
			if global.allowedToMakeElectricityRequests then
				global.lastElectricityUpdate = game.tick
			end
		else
			global.workTick = global.workTick + 1
		end
	else
		global.isConnected = false
	end
	global.prevIsConnected = global.isConnected
end)

---------------------------------
--[[Update combinator methods]]--
---------------------------------

local function AreTablesSame(tableA, tableB)
	if tableA == nil and tableB ~= nil then
		return false
	elseif tableA ~= nil and tableB == nil then
		return false
	elseif tableA == nil and tableB == nil then
		return true
	end

	if TableWithKeysLength(tableA) ~= TableWithKeysLength(tableB) then
		return false
	end

	for keyA, valueA in pairs(tableA) do
		local valueB = tableB[keyA]
		if type(valueA) == "table" and type(valueB) == "table" then
			if not AreTablesSame(valueA, valueB) then
				return false
			end
		elseif type(valueA) ~= type(valueB) then
			return false
		elseif valueA ~= valueB then
			return false
		end
	end

	return true
end


---------------------
--[[Remote things]]--
---------------------
remote.add_interface("clusterio",
{
	printStorage = function()
		local items = ""
		for itemName, itemCount in pairs(global.itemStorage) do
			items = items.."\n"..itemName..": "..tostring(itemCount)
		end
		game.print(items)
	end,
	reset = Reset,
})


-------------------
--[[GUI methods]]--
-------------------
local function createElemGui_INTERNAL(pane, guiName, elem_type, loadingList)
	local gui = pane.add{type = "table", name = guiName, column_count = 5}
	for _, item in pairs(loadingList) do
		gui.add{type = "choose-elem-button", elem_type = elem_type, item = item, fluid = item}
	end
	gui.add{type = "choose-elem-button", elem_type = elem_type}
end

local function toggleBWItemListGui(parent)
	if parent["clusterio-black-white-item-list-config"] then
		parent["clusterio-black-white-item-list-config"].destroy()
		return
	end

	local pane = parent.add{type = "frame", name = "clusterio-black-white-item-list-config", direction = "vertical"}
	pane.add{type = "label", caption = "Item"}
	pane.add{type = "checkbox", name = "clusterio-is-item-whitelist", caption = "whitelist", state = global.config.item_is_whitelist}
	createElemGui_INTERNAL(pane, "item-black-white-list", "item", global.config.BWitems)
end

local function toggleBWFluidListGui(parent)
	if parent["clusterio-black-white-fluid-list-config"] then
		parent["clusterio-black-white-fluid-list-config"].destroy()
		return
	end

	local pane = parent.add{type = "frame", name = "clusterio-black-white-fluid-list-config", direction = "vertical"}
	pane.add{type = "label", caption = "Fluid"}
	pane.add{type = "checkbox", name = "clusterio-is-fluid-whitelist", caption = "whitelist", state = global.config.fluid_is_whitelist}
	createElemGui_INTERNAL(pane, "fluid-black-white-list", "fluid", global.config.BWfluids)
end

local function processElemGui(event, toUpdateConfigName)--VERY WIP
	local parent = event.element.parent
	if event.element.elem_value == nil then
		event.element.destroy()
	else
		parent.add{type = "choose-elem-button", elem_type=parent.children[1].elem_type}
	end

	global.config[toUpdateConfigName] = {}
	for _, guiElement in pairs(parent.children) do
		if guiElement.elem_value ~= nil then
			table.insert(global.config[toUpdateConfigName], guiElement.elem_value)
		end
	end
end

local function addInfinityModeButton(parent)
	if global.hasInfiniteResources then
		parent.add{type = "button", name = "clusterio-infinity-button", caption = "Infinity mode enabled "}
	else
		parent.add{type = "button", name = "clusterio-infinity-button", caption = "Infinity mode disabled"}
	end
end

local function toggleMainConfigGui(parent)
	if parent["clusterio-main-config-gui"] then
		parent["clusterio-main-config-gui"].destroy()
		return
	end

	local pane = parent.add{type = "frame", name = "clusterio-main-config-gui", direction = "vertical"}
	pane.add{type = "button", name = "clusterio-Item-WB-list", caption = "Item White/Black list"}
	pane.add{type = "button", name = "clusterio-Fluid-WB-list", caption = "Fluid White/Black list"}

	--Electricity panel
	local electricityPane = pane.add{type = "frame", name = "clusterio-main-config-gui", direction = "horizontal"}
	electricityPane.add{type = "label", name = "clusterio-electricity-label", caption = "Max electricity"}
	electricityPane.add{type = "textfield", name = "clusterio-electricity-field", text = global.maxElectricity}

	--Infinity mode button
	addInfinityModeButton(pane)
end

local function processMainConfigGui(event)
	local element = event.element
	if element.name == "clusterio-Item-WB-list" then
		toggleBWItemListGui(game.get_player(event.player_index).gui.top)
	elseif element.name == "clusterio-Fluid-WB-list" then
		toggleBWFluidListGui(game.get_player(event.player_index).gui.top)
	elseif element.name == "clusterio-infinity-button" then
		local parent = element.parent
		element.destroy()
		if global.hasInfiniteResources then
			global.hasInfiniteResources = false
		else
			global.hasInfiniteResources = true
		end
		addInfinityModeButton(parent)
	end
end

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	local element = event.element
	if not (element.parent) then
		return
	end

	if element.name == "clusterio-is-fluid-whitelist" then
		global.config.fluid_is_whitelist = element.state
	elseif element.name == "clusterio-is-item-whitelist" then
		global.config.item_is_whitelist = element.state
	end
end)

script.on_event(defines.events.on_gui_click, function(event)
	if not (event.element and event.element.valid) then
		return
	end
	if not (event.element.parent) then
		return
	end

	if event.element.parent.name == "clusterio-main-config-gui" then
		processMainConfigGui(event)
	elseif event.element.name == "clusterio-main-config-gui-toggle-button" then
		local player = game.get_player(event.player_index)
		toggleMainConfigGui(player.gui.top)
	end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
	if not (event.element and event.element.valid) then
		return
	end
	if not (event.element.parent) then
		return
	end

	if event.element.parent.name == "item-black-white-list" then
		processElemGui(event,"BWitems")
	elseif event.element.parent.name == "fluid-black-white-list" then
		processElemGui(event,"BWfluids")
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	if not (event.element and event.element.valid) then
		return
	end

	if event.element.name == "clusterio-electricity-field" then
		local newMax = tonumber(event.element.text)
		if newMax and newMax >= 0 then
			global.maxElectricity = newMax
		end
	end
end)


--------------------------
--[[Some random events]]--
--------------------------
script.on_event(defines.events.on_player_joined_game,function(event)
	local player = game.get_player(event.player_index)
	if player.admin then
		local button = player.gui.top["clusterio-main-config-gui-button"]
		if button then
			button.destroy()
		end

		local button_flow = mod_gui.get_button_flow(player)
		if not button_flow["clusterio-main-config-gui-toggle-button"] then
			button_flow.add{type = "sprite-button", name = "clusterio-main-config-gui-toggle-button", sprite="clusterio"}
		end
	end
end)

local SUBSPACE_ITEMS = {
	["subspace-item-injector"] = true,
	["subspace-item-extractor"] = true,
	["subspace-fluid-injector"] = true,
	["subspace-fluid-extractor"] = true,
	["subspace-electricity-injector"] = true,
	["subspace-electricity-extractor"] = true
}
local ZONE_COLOR = {r=0.8 , g=0.1, b=0}
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
	local player = game.get_player(event.player_index)
	if not player or not player.valid then
		return
	end

	local drawZone = false
	if restrictionEnabled then
		local stack = player.cursor_stack
		if stack and stack.valid and stack.valid_for_read then
			local name = stack.name
			if SUBSPACE_ITEMS[name] then
				drawZone = true
			end
		end
	end

	if drawZone then
		local zoneDraw = global.zoneDraw
		if not zoneDraw[event.player_index] then
			local spawn = player.force.get_spawn_position(player.surface)
			local x0 = spawn.x
			local y0 = spawn.y

			local width, height
			if zoneWidth == 0 then
				width = 2000000 / 2
			else
				width = zoneWidth / 2
			end
			if zoneHeight == 0 then
				height = 2000000 / 2
			else
				height = zoneHeight / 2
			end

			zoneDraw[event.player_index] = rendering.draw_rectangle{
				color = ZONE_COLOR,
				width = 12,
				filled = false,
				left_top = {x0 - width, y0 - height},
				right_bottom = {x0 + width, y0 + height},
				surface = player.surface,
				players = {player},
				draw_on_ground = true,
			}
		end
	else
		local zoneDraw = global.zoneDraw
		if zoneDraw[event.player_index] then
			rendering.destroy(zoneDraw[event.player_index])
			zoneDraw[event.player_index] = nil
		end
	end
end)

local mod_settings = {
	["subspace_storage-range-restriction-enabled"] = function(value)
		restrictionEnabled = value
	end,
	["subspace_storage-zone-height"] = function(value)
		zoneHeight = value
	end,
	["subspace_storage-zone-width"] = function(value)
		zoneWidth = value
	end
}
script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	local f = mod_settings[event.setting]
	if f then f(settings.global[event.setting].value) end
end)
