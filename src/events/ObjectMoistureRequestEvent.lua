ObjectMoistureRequestEvent = {}
ObjectMoistureRequestEvent_mt = Class(ObjectMoistureRequestEvent, Event)

InitEventClass(ObjectMoistureRequestEvent, "ObjectMoistureRequestEvent")

function ObjectMoistureRequestEvent.emptyNew()
    return Event.new(ObjectMoistureRequestEvent_mt)
end

function ObjectMoistureRequestEvent.new(objectId)
    local self = ObjectMoistureRequestEvent.emptyNew()
    self.objectId = objectId
    return self
end

function ObjectMoistureRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.objectId)
end

function ObjectMoistureRequestEvent:readStream(streamId, connection)
    self.objectId = streamReadInt32(streamId)
    self:run(connection)
end

function ObjectMoistureRequestEvent:run(connection)
    if not g_currentMission:getIsServer() then return end

    local object = NetworkUtil.getObject(self.objectId)
    if object == nil or object.uniqueId == nil then return end

    local ms = g_currentMission.MoistureSystem
    local data = ms.objectInfo[object.uniqueId]

    connection:sendEvent(ObjectMoistureResponseEvent.new(self.objectId, data))
end
