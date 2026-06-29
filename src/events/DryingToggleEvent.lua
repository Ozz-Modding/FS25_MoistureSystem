DryingToggleEvent = {}
DryingToggleEvent_mt = Class(DryingToggleEvent, Event)

InitEventClass(DryingToggleEvent, "DryingToggleEvent")

function DryingToggleEvent.emptyNew()
    return Event.new(DryingToggleEvent_mt)
end

-- objectId: network object ID (from NetworkUtil.getObjectId)
-- newState: nil = client→server toggle request; bool = server→client state broadcast
function DryingToggleEvent.new(objectId, newState)
    local self = DryingToggleEvent.emptyNew()
    self.objectId = objectId
    self.newState = newState
    return self
end

function DryingToggleEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.objectId)
    local hasState = self.newState ~= nil
    streamWriteBool(streamId, hasState)
    if hasState then
        streamWriteBool(streamId, self.newState)
    end
end

function DryingToggleEvent:readStream(streamId, connection)
    self.objectId = streamReadInt32(streamId)
    local hasState = streamReadBool(streamId)
    if hasState then
        self.newState = streamReadBool(streamId)
    end
    self:run(connection)
end

function DryingToggleEvent:run(connection)
    local dryingSystem = g_currentMission.dryingSystem
    if dryingSystem == nil then return end

    local placeable = NetworkUtil.getObject(self.objectId)
    if placeable == nil then return end

    if g_currentMission:getIsServer() then
        if self.newState == nil then
            -- Toggle request from a client
            dryingSystem:toggleDrying(placeable)
            local isNowDrying = dryingSystem:isDrying(placeable.uniqueId)
            g_server:broadcastEvent(DryingToggleEvent.new(self.objectId, isNowDrying))
        end
    elseif self.newState ~= nil then
        dryingSystem:setDryingState(placeable.uniqueId, self.newState)
    end
end
