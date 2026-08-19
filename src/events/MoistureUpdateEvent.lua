MoistureUpdateEvent = {}
MoistureUpdateEvent_mt = Class(MoistureUpdateEvent, Event)

InitEventClass(MoistureUpdateEvent, "MoistureUpdateEvent")

function MoistureUpdateEvent.emptyNew()
    local self = Event.new(MoistureUpdateEvent_mt)
    return self
end

function MoistureUpdateEvent.new(moisturePercent)
    local self = MoistureUpdateEvent.emptyNew()
    self.moisturePercent = moisturePercent
    return self
end

function MoistureUpdateEvent:writeStream(streamId, connection)
    streamWriteFloat32(streamId, self.moisturePercent)
end

function MoistureUpdateEvent:readStream(streamId, connection)
    self.moisturePercent = streamReadFloat32(streamId)
    self:run(connection)
end

function MoistureUpdateEvent:run(connection)
    g_currentMission.MoistureSystem.currentMoisturePercent = self.moisturePercent
    g_currentMission.MoistureSystem:invalidateMoistureCache()
end
