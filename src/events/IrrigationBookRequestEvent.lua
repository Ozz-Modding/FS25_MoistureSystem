---
-- Client -> server: please book this job.
--
-- Three single-purpose events rather than DryingToggleEvent's "one event,
-- direction inferred from a nil field" shape. That works for a toggle, which
-- cannot fail; booking CAN fail, so the reply has to carry an outcome the
-- request never has.
--
-- On single-player or a listen-server host the request path is a direct call to
-- IrrigationSystem:handleBookRequest and this event is never constructed.
--
-- Farmland ids go on the wire directly at the farmland manager's own bit width.
-- CLAUDE.md's rule against sending uniqueId does not apply: farmland ids come
-- from map XML and are identical on every peer -- the base game sends them the
-- same way (economy/FarmlandStateEvent.lua).
---
IrrigationBookRequestEvent = {}
local IrrigationBookRequestEvent_mt = Class(IrrigationBookRequestEvent, Event)

InitEventClass(IrrigationBookRequestEvent, "IrrigationBookRequestEvent")

function IrrigationBookRequestEvent.emptyNew()
    return Event.new(IrrigationBookRequestEvent_mt)
end

function IrrigationBookRequestEvent.new(farmlandId, boostPp, day, expectedPrice)
    local self = IrrigationBookRequestEvent.emptyNew()
    self.farmlandId = farmlandId
    self.boostPp = boostPp
    self.day = day
    self.expectedPrice = expectedPrice
    return self
end

function IrrigationBookRequestEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmlandId, g_farmlandManager.numberOfBits)
    streamWriteFloat32(streamId, self.boostPp)
    streamWriteInt32(streamId, self.day)
    streamWriteFloat32(streamId, self.expectedPrice)
end

function IrrigationBookRequestEvent:readStream(streamId, connection)
    self.farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
    self.boostPp = streamReadFloat32(streamId)
    self.day = streamReadInt32(streamId)
    self.expectedPrice = streamReadFloat32(streamId)
    self:run(connection)
end

function IrrigationBookRequestEvent:run(connection)
    if not g_currentMission:getIsServer() then return end

    local irrigation = g_currentMission.irrigationSystem
    if irrigation == nil then return end

    local farmId = g_currentMission:getFarmId(connection)
    local accepted, reason = irrigation:handleBookRequest(
        self.farmlandId, self.boostPp, self.day, farmId, connection, self.expectedPrice)

    connection:sendEvent(IrrigationBookResultEvent.new(accepted, reason))
end
