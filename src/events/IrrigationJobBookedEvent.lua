---
-- Server -> all: hours have been consumed on this day.
--
-- Carries the CONTRACTOR INDEX because without it a client cannot tell whether
-- six consumed hours are one contractor's afternoon or six contractors' first
-- hour, and its diary misrenders.
--
-- The farm id rides along so the booking farm can attach its own job record;
-- other farms use only the day, contractor and hours. Other farms' jobs are
-- never synced -- a client needs only its own farm's pending job to render its
-- tab, and the diary shows how many hours are free, not who took them.
---
IrrigationJobBookedEvent = {}
local IrrigationJobBookedEvent_mt = Class(IrrigationJobBookedEvent, Event)

InitEventClass(IrrigationJobBookedEvent, "IrrigationJobBookedEvent")

function IrrigationJobBookedEvent.emptyNew()
    return Event.new(IrrigationJobBookedEvent_mt)
end

function IrrigationJobBookedEvent.new(farmlandId, day, hours, contractorIndex, farmId, job)
    local self = IrrigationJobBookedEvent.emptyNew()
    self.farmlandId = farmlandId
    self.day = day
    self.hours = hours
    self.contractorIndex = contractorIndex
    self.farmId = farmId
    self.job = job
    return self
end

function IrrigationJobBookedEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmlandId, g_farmlandManager.numberOfBits)
    streamWriteInt32(streamId, self.day)
    streamWriteUIntN(streamId, self.hours, 5)
    streamWriteUIntN(streamId, self.contractorIndex, 3)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.job.startHour, 5)
    streamWriteFloat32(streamId, self.job.targetBoost)
end

function IrrigationJobBookedEvent:readStream(streamId, connection)
    self.farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
    self.day = streamReadInt32(streamId)
    self.hours = streamReadUIntN(streamId, 5)
    self.contractorIndex = streamReadUIntN(streamId, 3)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.job = {
        startHour = streamReadUIntN(streamId, 5),
        targetBoost = streamReadFloat32(streamId),
    }
    self:run(connection)
end

function IrrigationJobBookedEvent:run(connection)
    if g_currentMission:getIsServer() then return end

    local irrigation = g_currentMission.irrigationSystem
    if irrigation == nil then return end

    irrigation:onJobBooked(self.farmlandId, self.day, self.hours, self.contractorIndex,
        self.farmId, self.job)
end
