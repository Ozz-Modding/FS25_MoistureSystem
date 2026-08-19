---
-- Server -> all, once per game hour: every live boost, plus any start/finish
-- notifications raised this hour.
--
-- Boosts reach clients only so the two display-only readers (the field info box
-- and the moisture meter) do not show a lie; no simulation runs client-side.
--
-- Notifications are tagged with the farm that owns the job and compared against
-- the receiving player's CURRENT farm on arrival, not at booking time: a player
-- can switch farms mid-game, and deciding at booking would keep telling them
-- about the farm they left. Other farms are never notified.
---
IrrigationBoostUpdateEvent = {}
local IrrigationBoostUpdateEvent_mt = Class(IrrigationBoostUpdateEvent, Event)

InitEventClass(IrrigationBoostUpdateEvent, "IrrigationBoostUpdateEvent")

function IrrigationBoostUpdateEvent.emptyNew()
    return Event.new(IrrigationBoostUpdateEvent_mt)
end

function IrrigationBoostUpdateEvent.new(boosts, notifications)
    local self = IrrigationBoostUpdateEvent.emptyNew()
    self.boosts = boosts or {}
    self.notifications = notifications or {}
    return self
end

function IrrigationBoostUpdateEvent:writeStream(streamId, connection)
    local count = 0
    for _ in pairs(self.boosts) do count = count + 1 end
    streamWriteUIntN(streamId, count, 12)
    for farmlandId, boost in pairs(self.boosts) do
        streamWriteUIntN(streamId, farmlandId, g_farmlandManager.numberOfBits)
        streamWriteFloat32(streamId, boost.value)
    end

    -- Hard-capped at what the 5-bit count can carry. Two per job and one job
    -- per farmland make this unreachable in practice, but overflowing the field
    -- would corrupt the rest of the stream, so it is clamped rather than
    -- trusted.
    local count = math.min(#self.notifications, 31)
    streamWriteUIntN(streamId, count, 5)
    for i = 1, count do
        local notification = self.notifications[i]
        streamWriteUIntN(streamId, notification.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, notification.text)
    end
end

function IrrigationBoostUpdateEvent:readStream(streamId, connection)
    self.boosts = {}
    local count = streamReadUIntN(streamId, 12)
    for _ = 1, count do
        local farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
        self.boosts[farmlandId] = { value = streamReadFloat32(streamId) }
    end

    self.notifications = {}
    local notificationCount = streamReadUIntN(streamId, 5)
    for _ = 1, notificationCount do
        table.insert(self.notifications, {
            farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            text = streamReadString(streamId),
        })
    end

    self:run(connection)
end

function IrrigationBoostUpdateEvent:run(connection)
    if g_currentMission:getIsServer() then return end

    local irrigation = g_currentMission.irrigationSystem
    if irrigation == nil then return end

    irrigation:applyBoostUpdate(self.boosts)

    local myFarmId = g_currentMission:getFarmId()
    for _, notification in ipairs(self.notifications) do
        if notification.farmId == myFarmId then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, notification.text)
        end
    end
end
