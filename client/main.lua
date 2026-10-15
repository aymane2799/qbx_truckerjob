local config = require 'config.client'
local sharedConfig = require 'config.shared'
local currentZones = {}
local currentLocation = {}
local currentBlip = 0
local hasBox = false
local truckerBlip = 0
local depotPed
local returningToStation = false
local currentPlate
local boxObject
local boxModel = `hei_prop_heist_box`
local boxAnimDict = 'anim@heists@box_carry@'

local function stopCarryingBox()
    if boxObject and DoesEntityExist(boxObject) then DeleteEntity(boxObject) end
    boxObject = nil
    hasBox = false
    StopAnimTask(cache.ped, boxAnimDict, 'idle', 1.0)
end

local function playBoxAnimation()
    lib.playAnim(cache.ped, boxAnimDict, 'idle', 8.0, -8.0, -1, 49, 0, false, false, false)
end

local function startCarryingBox()
    stopCarryingBox()
    lib.requestModel(boxModel)
    local coords = GetEntityCoords(cache.ped)
    boxObject = CreateObject(boxModel, coords.x, coords.y, coords.z, true, true, false)
    SetModelAsNoLongerNeeded(boxModel)
    if not DoesEntityExist(boxObject) then
        boxObject = nil
        return false
    end

    AttachEntityToEntity(boxObject, cache.ped, GetPedBoneIndex(cache.ped, 60309),
        0.025, 0.08, 0.255, -145.0, 290.0, 0.0, true, true, false, true, 1, true)
    playBoxAnimation()
    hasBox = true
    return true
end

-- Functions
local function returnToStation()
    SetBlipRoute(truckerBlip, true)
    returningToStation = true
end

local function isTruckerVehicle(vehicle)
    return config.vehicles[GetEntityModel(vehicle)]
end

local function removeElements()
    ClearAllBlipRoutes()
    if DoesBlipExist(truckerBlip) then
        RemoveBlip(truckerBlip)
        truckerBlip = 0
    end

    if DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
        currentBlip = 0
    end

    for _, zone in ipairs(currentZones) do
        zone:remove()
    end

    currentZones = {}
    returningToStation = false
end

local function getPaid()
    TriggerServerEvent('qbx_truckerjob:server:getPaid')

    if DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
        ClearAllBlipRoutes()
        currentBlip = 0
    end
end

local function returnVehicle()
    if not lib.callback.await('qbx_truckerjob:server:returnVehicle', false) then return end

    stopCarryingBox()

    if DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
        currentBlip = 0
    end

    if next(currentLocation) and currentLocation.zoneCombo then
        currentLocation.zoneCombo:remove()
    end

    ClearAllBlipRoutes()
    currentLocation = {}
    currentPlate = nil

    if not returningToStation then return end

    returningToStation = false
    exports.qbx_core:Notify(locale('mission.job_completed'), 'success')
end

local function openMenuGarage()
    local truckMenu = {}
    for k in pairs(config.vehicles) do
        truckMenu[#truckMenu + 1] = {
            title = config.vehicles[k],
            serverEvent = 'qbx_truckerjob:server:doBail',
            args = k
        }
    end

    lib.registerContext({
        id = 'trucker_veh_menu',
        title = locale('menu.header'),
        options = truckMenu
    })

    lib.showContext('trucker_veh_menu')
end

-- Atlas fork: the dispatcher of the depot replaces the two marker zones (paycheck, vehicles). The ped is
-- local and exists only while the player is near the depot. Only truckers get the options.
local function removeDepotPed()
    if not depotPed then return end

    exports.ox_target:removeLocalEntity(depotPed)
    if DoesEntityExist(depotPed) then DeletePed(depotPed) end
    depotPed = nil
end

local function spawnDepotPed()
    if depotPed then return end

    local data = sharedConfig.locations.ped
    local model = lib.requestModel(data.model, 10000)
    depotPed = CreatePed(0, model, data.coords.x, data.coords.y, data.coords.z, data.coords.w, false, false)
    SetModelAsNoLongerNeeded(model)
    FreezeEntityPosition(depotPed, true)
    SetEntityInvincible(depotPed, true)
    SetBlockingOfNonTemporaryEvents(depotPed, true)

    if data.scenario then
        TaskStartScenarioInPlace(depotPed, data.scenario, 0, true)
    end

    exports.ox_target:addLocalEntity(depotPed, {
        {
            name = 'trucker_rent',
            label = locale('target.rent'),
            icon = 'fa-solid fa-truck',
            groups = 'trucker',
            distance = 2.5,
            onSelect = openMenuGarage,
        },
        {
            name = 'trucker_return',
            label = locale('target.return_vehicle'),
            icon = 'fa-solid fa-warehouse',
            groups = 'trucker',
            distance = 2.5,
            onSelect = returnVehicle,
        },
        {
            name = 'trucker_paycheck',
            label = locale('target.paycheck'),
            icon = 'fa-solid fa-money-bill',
            groups = 'trucker',
            distance = 2.5,
            onSelect = getPaid,
        },
    })
end

lib.points.new({
    coords = sharedConfig.locations.ped.coords.xyz,
    distance = 60.0,
    onEnter = spawnDepotPed,
    onExit = removeDepotPed,
})

local function areBackDoorsOpen(vehicle) -- This is hardcoded for the rumpo currently
    return GetVehicleDoorAngleRatio(vehicle, 5) > 0.0
        or GetVehicleDoorAngleRatio(vehicle, 2) > 0.0
        and GetVehicleDoorAngleRatio(vehicle, 3) > 0.0
end

local function getInTrunk()
    if cache.vehicle then
        return exports.qbx_core:Notify(locale('error.get_out_vehicle'), 'error')
    end

    local vehicle = GetVehiclePedIsIn(cache.ped, true)
    if not isTruckerVehicle(vehicle) or currentPlate ~= qbx.getVehiclePlate(vehicle) then
        return exports.qbx_core:Notify(locale('error.vehicle_not_correct'), 'error')
    end

    -- Atlas fork: the rear doors are opened for the driver. Upstream refused with "backdoors not open"
    -- unless both rear doors had been opened by hand.
    if not areBackDoorsOpen(vehicle) then
        SetVehicleDoorOpen(vehicle, 2, false, false)
        SetVehicleDoorOpen(vehicle, 3, false, false)
    end

    local pedCoords = GetEntityCoords(cache.ped, true)
    local trunkCoords = GetOffsetFromEntityInWorldCoords(vehicle, 0, -2.5, 0)
    if #(pedCoords - trunkCoords) > 1.5 then
        return exports.qbx_core:Notify(locale('error.too_far_from_trunk'), 'error')
    end

    if lib.progressCircle({
        duration = 2000,
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = {
            car = true,
            mouse = false,
            combat = true,
            move = true,
        },
        anim = {
            dict = 'anim@gangops@facility@servers@',
            clip = 'hotwire'
        },
    }) then
        if not startCarryingBox() then return exports.qbx_core:Notify(locale('error.cancelled'), 'error') end
        exports.qbx_core:Notify(locale('info.deliver_to_store'), 'info')
    else
        exports.qbx_core:Notify(locale('error.cancelled'), 'error')
    end
end

local function deliver()
    if lib.progressCircle({
        duration = 3000,
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = {
            car = true,
            mouse = false,
            combat = true,
            move = true,
        },
        anim = {
            dict = 'anim@gangops@facility@servers@',
            clip = 'hotwire'
        },
    }) then
        stopCarryingBox()
        ClearPedTasks(cache.ped)
        currentLocation.currentCount += 1
        lib.print.debug('count:', currentLocation.currentCount, '/', currentLocation.dropCount)
        if currentLocation.currentCount == currentLocation.dropCount then
            if DoesBlipExist(currentBlip) then
                RemoveBlip(currentBlip)
                ClearAllBlipRoutes()
                currentBlip = 0
            end
            currentLocation.zoneCombo:remove()
            currentLocation = {}

            return true
        else
            exports.qbx_core:Notify(locale('mission.another_box'), 'info')
        end
    else
        ClearPedTasks(cache.ped)
        playBoxAnimation()
        exports.qbx_core:Notify(locale('error.cancelled'), 'error')
    end
end

local function getNewLocation(locationIndex, drop)
    local location = sharedConfig.locations.stores[locationIndex]
    currentLocation = { dropCount = drop, currentCount = 0 }

    local marker = lib.marker.new({
        coords = location.coords,
        type = location.markerType or 2,
        height = 0.2,
        width = 0.3
    })

    currentLocation.zoneCombo = lib.zones.box({
        name = location.label,
        coords = location.coords,
        size = location.size,
        rotation = location.rotation,
        debug = location.debug,
        onEnter = function()
            exports.qbx_core:Notify(locale('mission.store_reached'), 'info')
        end,
        inside = function ()
            marker:draw()

            if IsControlJustReleased(0, 38) then
                if cache.vehicle then
                    return exports.qbx_core:Notify(locale('error.get_out_vehicle'), 'error')
                elseif not hasBox then
                    getInTrunk()
                elseif #(GetEntityCoords(cache.ped) - location.coords) < 5 then
                    if deliver() then
                        local newLocation, newDrop = lib.callback.await('qbx_truckerjob:server:getNewTask', false)
                        if not newLocation or QBX.PlayerData.job.name ~= 'trucker' then return
                        elseif newLocation == 0 then
                            exports.qbx_core:Notify(locale('mission.return_to_station'), 'info')
                            returnToStation()
                        else
                            exports.qbx_core:Notify(locale('mission.goto_next_point'), 'info')
                            getNewLocation(newLocation, newDrop)
                        end
                    end
                else
                    exports.qbx_core:Notify(locale('error.too_far_from_delivery'), 'error')
                end
            end
        end,
    })

    currentBlip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
    SetBlipColour(currentBlip, 3)
    SetBlipRoute(currentBlip, true)
    SetBlipRouteColour(currentBlip, 3)
end

local function createElement(location, sprinteId)
    local element = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
    SetBlipSprite(element, sprinteId)
    SetBlipDisplay(element, 4)
    SetBlipScale(element, 0.6)
    SetBlipAsShortRange(element, true)
    SetBlipColour(element, 5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(location.label)
    EndTextCommandSetBlipName(element)

    return element
end

local function createElements()
    if QBX.PlayerData.job.name ~= 'trucker' then return end

    truckerBlip = createElement(sharedConfig.locations.main, 479)
end

-- Events

local function setInitState()
    stopCarryingBox()
    removeElements()
    currentLocation = {}
    currentBlip = 0
    hasBox = false
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    setInitState()
    createElements()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    setInitState()
    createElements()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    setInitState()
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function()
    stopCarryingBox()
    removeElements()

    if next(currentLocation) and currentLocation.zoneCombo then
        currentLocation.zoneCombo:remove()
    end

    createElements()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    stopCarryingBox()
    removeDepotPed()
end)

RegisterNetEvent('qbx_truckerjob:client:spawnVehicle', function(veh)
    local netId, plate = lib.callback.await('qbx_truckerjob:server:spawnVehicle', false, veh)
    if not netId then return end
    currentPlate = plate
    local vehicle = NetToVeh(netId)
    SetVehicleEngineOn(vehicle, true, true, false)

    local location, drop = lib.callback.await('qbx_truckerjob:server:getNewTask', false, true)

    if not location then return end
    getNewLocation(location, drop)
end)
