MSInitialClientStateEvent = {}
local MSInitialClientStateEvent_mt = Class(MSInitialClientStateEvent, Event)

InitEventClass(MSInitialClientStateEvent, "MSInitialClientStateEvent")

function MSInitialClientStateEvent.emptyNew()
    return Event.new(MSInitialClientStateEvent_mt)
end

function MSInitialClientStateEvent.new()
    return MSInitialClientStateEvent.emptyNew()
end

function MSInitialClientStateEvent:writeStream(streamId, connection)
    g_currentMission.MoistureSystem:writeInitialClientState(streamId, connection)
    g_currentMission.WeatherProfileSystem:writeClientState(streamId)
    g_currentMission.irrigationSystem:writeClientState(streamId)
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
