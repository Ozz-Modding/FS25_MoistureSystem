DryingToggleEvent = {}
DryingToggleEvent_mt = Class(DryingToggleEvent, Event)

InitEventClass(DryingToggleEvent, "DryingToggleEvent")

function DryingToggleEvent.emptyNew()
    return Event.new(DryingToggleEvent_mt)
end

-- When newState is nil this is a client→server toggle request.
-- When newState is a bool this is a server→client state broadcast.
function DryingToggleEvent.new(placeableUniqueId, newState)
    local self = DryingToggleEvent.emptyNew()
    self.placeableUniqueId = placeableUniqueId
    self.newState = newState
    return self
end

function DryingToggleEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.placeableUniqueId)
    local hasState = self.newState ~= nil
    streamWriteBool(streamId, hasState)
    if hasState then
        streamWriteBool(streamId, self.newState)
    end
end

function DryingToggleEvent:readStream(streamId, connection)
    self.placeableUniqueId = streamReadString(streamId)
    local hasState = streamReadBool(streamId)
    if hasState then
        self.newState = streamReadBool(streamId)
    end
    self:run(connection)
end

function DryingToggleEvent:run(connection)
    local dryingSystem = g_currentMission.dryingSystem
    if dryingSystem == nil then return end

    if g_currentMission:getIsServer() then
        if self.newState == nil then
            -- Toggle request from a client
            local placeable = dryingSystem:getPlaceableByUniqueId(self.placeableUniqueId)
            if placeable then
                dryingSystem:toggleDrying(placeable)
                local isNowDrying = dryingSystem:isDrying(placeable.uniqueId)
                g_server:broadcastEvent(DryingToggleEvent.new(self.placeableUniqueId, isNowDrying))
            end
        end
        -- Ignore inbound state-broadcast packets on the server (sent to clients only)
    elseif self.newState ~= nil then
        dryingSystem:setDryingState(self.placeableUniqueId, self.newState)
    end
end
