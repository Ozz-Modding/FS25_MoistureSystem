ObjectMoistureResponseEvent = {}
ObjectMoistureResponseEvent_mt = Class(ObjectMoistureResponseEvent, Event)

InitEventClass(ObjectMoistureResponseEvent, "ObjectMoistureResponseEvent")

function ObjectMoistureResponseEvent.emptyNew()
    return Event.new(ObjectMoistureResponseEvent_mt)
end

function ObjectMoistureResponseEvent.new(objectId, fillTypes)
    local self = ObjectMoistureResponseEvent.emptyNew()
    self.objectId = objectId
    self.fillTypes = fillTypes or {}
    return self
end

function ObjectMoistureResponseEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.objectId)

    local count = 0
    for _ in pairs(self.fillTypes) do count = count + 1 end
    streamWriteInt32(streamId, count)

    for fillTypeName, info in pairs(self.fillTypes) do
        streamWriteString(streamId, fillTypeName)
        streamWriteFloat32(streamId, info.moisture or 0)
        streamWriteFloat32(streamId, info.quality or 100)
    end
end

function ObjectMoistureResponseEvent:readStream(streamId, connection)
    self.objectId = streamReadInt32(streamId)
    self.fillTypes = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local fillTypeName = streamReadString(streamId)
        local moisture = streamReadFloat32(streamId)
        local quality = streamReadFloat32(streamId)
        self.fillTypes[fillTypeName] = { moisture = moisture, quality = quality }
    end
    self:run(connection)
end

function ObjectMoistureResponseEvent:run(connection)
    local object = NetworkUtil.getObject(self.objectId)
    if object == nil or object.uniqueId == nil then return end

    local ms = g_currentMission.MoistureSystem
    ms.objectInfo[object.uniqueId] = self.fillTypes
    ms.objectMoistureTimestamps[object.uniqueId] = g_time
    ms.pendingObjectRequests[object.uniqueId] = nil
end
