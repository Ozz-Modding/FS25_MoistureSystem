MSInitialClientStateEvent = {}
local MSInitialClientStateEvent_mt = Class(MSInitialClientStateEvent, Event)

InitEventClass(MSInitialClientStateEvent, "MSInitialClientStateEvent")

function MSInitialClientStateEvent.emptyNew()
    return Event.new(MSInitialClientStateEvent_mt)
end

-- farm is the joining player's farm, forwarded from FSBaseMission's own
-- sendInitialClientState so irrigation can send that farm's pending jobs and
-- nobody else's.
function MSInitialClientStateEvent.new(farm)
    local self = MSInitialClientStateEvent.emptyNew()
    self.farm = farm
    return self
end

function MSInitialClientStateEvent:writeStream(streamId, connection)
    g_currentMission.MoistureSystem:writeInitialClientState(streamId, connection)
    g_currentMission.WeatherProfileSystem:writeClientState(streamId)
    g_currentMission.irrigationSystem:writeClientState(streamId, self.farm)
end

function MSInitialClientStateEvent:readStream(streamId, connection)
    g_currentMission.MoistureSystem:readInitialClientState(streamId, connection)
    g_currentMission.WeatherProfileSystem:readClientState(streamId)
    g_currentMission.irrigationSystem:readClientState(streamId)
    self:run(connection)
end

function MSInitialClientStateEvent:run(connection)
    -- Trigger any post-sync updates if needed
end
