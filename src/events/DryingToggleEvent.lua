DryingToggleEvent = {}
DryingToggleEvent_mt = Class(DryingToggleEvent, Event)

InitEventClass(DryingToggleEvent, "DryingToggleEvent")

function DryingToggleEvent.emptyNew()
    return Event.new(DryingToggleEvent_mt)
end

function DryingToggleEvent.new(placeableUniqueId)
    local self = DryingToggleEvent.emptyNew()
    self.placeableUniqueId = placeableUniqueId
    return self
end

function DryingToggleEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.placeableUniqueId)
end

function DryingToggleEvent:readStream(streamId, connection)
    self.placeableUniqueId = streamReadString(streamId)
    self:run(connection)
end

function DryingToggleEvent:run(connection)
    if not g_currentMission:getIsServer() then return end

    local dryingSystem = g_currentMission.dryingSystem
    if dryingSystem == nil then return end

    local placeable = dryingSystem:getPlaceableByUniqueId(self.placeableUniqueId)
    if placeable then
        dryingSystem:toggleDrying(placeable)
    end
end
