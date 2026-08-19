---
-- Server -> the requesting client only: accepted, or a reason code.
--
-- The server never silently corrects a booking. Money must not leave the
-- account at a price the player did not see, so a mismatch rejects and books
-- nothing; the tab re-quotes off the back of this.
---
IrrigationBookResultEvent = {}
local IrrigationBookResultEvent_mt = Class(IrrigationBookResultEvent, Event)

InitEventClass(IrrigationBookResultEvent, "IrrigationBookResultEvent")

function IrrigationBookResultEvent.emptyNew()
    return Event.new(IrrigationBookResultEvent_mt)
end

function IrrigationBookResultEvent.new(accepted, reason)
    local self = IrrigationBookResultEvent.emptyNew()
    self.accepted = accepted
    self.reason = reason or IrrigationSystem.REJECT_INVALID
    return self
end

function IrrigationBookResultEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.accepted)
    if not self.accepted then
        streamWriteUIntN(streamId, self.reason, 3)
    end
end

function IrrigationBookResultEvent:readStream(streamId, connection)
    self.accepted = streamReadBool(streamId)
    if not self.accepted then
        self.reason = streamReadUIntN(streamId, 3)
    end
    self:run(connection)
end

function IrrigationBookResultEvent:run(connection)
    local irrigation = g_currentMission.irrigationSystem
    if irrigation ~= nil then
        irrigation:onBookResult(self.accepted, self.reason)
    end
end
