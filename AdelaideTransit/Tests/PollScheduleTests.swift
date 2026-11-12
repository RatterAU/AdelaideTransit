import Testing
import Foundation
@testable import AdelaideTransit

/// The feeds publish every 15s with no ETag and no compression, so every mistimed poll is a full
/// uncompressed payload re-downloaded for nothing. This is the logic that keeps that from happening.
struct PollScheduleTests {

    private let cycle: TimeInterval = 15
    private let now = Date(timeIntervalSince1970: 1_784_530_100)

    // MARK: - nextDelay

    /// Freshly-published data: wait out the remaining cycle plus the lag before it becomes fetchable.
    @Test func aimsJustAfterTheNextPublish() {
        let delay = PollSchedule.nextDelay(
            lastHeader: now, cycle: cycle, multiplier: 1, gotNewData: true, now: now
        )
        #expect(delay == cycle + PollSchedule.publishLag)
    }

    /// The point of phase locking: a poll landing late in the cycle waits less, not a fixed interval.
    @Test func compensatesForTimeAlreadyElapsedSinceThePublish() {
        let delay = PollSchedule.nextDelay(
            lastHeader: now.addingTimeInterval(-10), cycle: cycle, multiplier: 1, gotNewData: true, now: now
        )
        #expect(delay == 10) // 15 + 5 lag - 10 already elapsed
    }

    @Test func retriesQuicklyWhenAlreadyPastTheExpectedPublish() {
        let delay = PollSchedule.nextDelay(
            lastHeader: now.addingTimeInterval(-25), cycle: cycle, multiplier: 1, gotNewData: false, now: now
        )
        #expect(delay == PollSchedule.missRetry)
    }

    /// A stalled publisher answers 200 with the same header, so it never counts as a failure. The chase has
    /// to give up on its own, or that is a full payload every 3s for as long as the stall lasts.
    @Test func theChaseGivesUpAfterOneCycleOfAStalledPublisher() {
        let delay = PollSchedule.nextDelay(
            lastHeader: now.addingTimeInterval(-60), cycle: cycle, multiplier: 1, gotNewData: false, now: now
        )
        #expect(delay == cycle)
    }

    @Test func multiplierStretchesTheCycleForWarmAndSaverModes() {
        let delay = PollSchedule.nextDelay(
            lastHeader: now, cycle: cycle, multiplier: 4, gotNewData: true, now: now
        )
        #expect(delay == cycle * 4 + PollSchedule.publishLag)
    }

    @Test func withNoHistoryWaitsACycleAfterSuccess() {
        let delay = PollSchedule.nextDelay(
            lastHeader: nil, cycle: cycle, multiplier: 1, gotNewData: true, now: now
        )
        #expect(delay == cycle)
    }

    @Test func withNoHistoryRetriesQuicklyAfterAMiss() {
        let delay = PollSchedule.nextDelay(
            lastHeader: nil, cycle: cycle, multiplier: 1, gotNewData: false, now: now
        )
        #expect(delay == PollSchedule.missRetry)
    }

    /// Never return a negative or zero sleep — that would spin the loop against the server.
    @Test func delayIsAlwaysPositive() {
        for elapsed in stride(from: 0.0, through: 300.0, by: 7) {
            let delay = PollSchedule.nextDelay(
                lastHeader: now.addingTimeInterval(-elapsed), cycle: cycle,
                multiplier: 1, gotNewData: true, now: now
            )
            #expect(delay > 0)
        }
    }

    // MARK: - learnedCycle

    @Test func learnsTheRealCadenceFromConsecutivePublishes() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(20), multiplier: 1, chased: true
        )
        #expect(learned == 20)
    }

    /// The ratchet. The map warms trip_updates every 4th cycle; open a stop and the next sample is at
    /// multiplier 1 but its gap spans cycles it never saw. Learned as the cadence, polling on it sees that
    /// same gap again and a 15s feed stays on 45s for the session.
    @Test func aLongGapThatNothingPinnedIsNotTheCadence() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(45), multiplier: 1, chased: false
        )
        #expect(learned == 15)
    }

    /// Two-sided: a shorter gap can't be an artefact of sampling late, so it needs no chase to be believed —
    /// which is also what walks a slowed estimate back down.
    @Test func aShorterGapIsAlwaysLearned() {
        let learned = PollSchedule.learnedCycle(
            previous: 45, lastHeader: now, newHeader: now.addingTimeInterval(15), multiplier: 1, chased: false
        )
        #expect(learned == 15)
    }

    /// The trap this guard exists for: a feed polled every 4th cycle sees 60s gaps. Learning from those
    /// would ratchet the cadence slower on every pass until it stopped being live at all.
    @Test func doesNotLearnWhileDeliberatelySkippingCycles() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(60), multiplier: 4, chased: true
        )
        #expect(learned == 15)
    }

    @Test func ignoresImplausibleGaps() {
        let tooLong = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(3600), multiplier: 1, chased: true
        )
        let tooShort = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(0.5), multiplier: 1, chased: true
        )
        #expect(tooLong == 15)
        #expect(tooShort == 15)
    }

    /// trip_updates publishes every 59–61 s (measured 2026-11-12/13), and a cap of exactly 60 refused every
    /// 61 s gap: the learned cadence stayed at 15 and each real publish cost ~7 identical 118 KB downloads.
    @Test func learnsAMinuteLongCadenceEvenWithJitter() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(61), multiplier: 1, chased: true
        )
        #expect(learned == 61)
    }

    /// One cycle of chasing at a 60 s cadence is twenty full downloads of a stalled feed. Publish lag ran to
    /// 8.5 s at worst (2026-11-12), so chasing past `maxChase` finds nothing a scheduled poll wouldn't.
    @Test func theChaseIsBoundedInSecondsOnASlowFeed() {
        let lastHeader = now.addingTimeInterval(-(60 + PollSchedule.publishLag + 20))
        let delay = PollSchedule.nextDelay(
            lastHeader: lastHeader, cycle: 60, multiplier: 1, gotNewData: false, now: now
        )
        #expect(delay == 60)
        // Two-sided: just past the expected publish it still chases.
        let justLate = PollSchedule.nextDelay(
            lastHeader: now.addingTimeInterval(-(60 + PollSchedule.publishLag + 2)),
            cycle: 60, multiplier: 1, gotNewData: false, now: now
        )
        #expect(justLate == PollSchedule.missRetry)
    }

    /// The map warms trip_updates so the first tap on a stop has live times. Four cycles was a minute at a
    /// 15 s cadence and four minutes at the 60 s one the feed now runs.
    @Test func mapWarmRateIsAboutAMinuteWhateverTheCadence() {
        #expect(PollSchedule.warmMultiplier(cycle: 15) == 4)
        #expect(PollSchedule.warmMultiplier(cycle: 60) == 1)
        #expect(PollSchedule.warmMultiplier(cycle: 61) == 1)
        #expect(PollSchedule.warmMultiplier(cycle: 30) == 2)
    }

    /// The range probe reads the publish time off the front of a payload it never downloads in full.
    @Test func headerTimestampIsReadFromThePrefixOfAFullFeed() throws {
        var message = TransitRealtime_FeedMessage()
        message.header.gtfsRealtimeVersion = "2.0"
        message.header.timestamp = 1_794_476_107
        message.entity = (0..<200).map { i in
            var entity = TransitRealtime_FeedEntity()
            entity.id = "trip-\(i)"
            entity.tripUpdate.trip.tripID = "\(1_000_000 + i)"
            return entity
        }
        let full: Data = try message.serializedBytes()
        #expect(full.count > RealtimeEngine.probeBytes)
        #expect(RealtimeEngine.headerTimestamp(prefix: full.prefix(RealtimeEngine.probeBytes)) == 1_794_476_107)
        // Two-sided: a prefix that cuts the header short is "don't know", never a wrong timestamp.
        #expect(RealtimeEngine.headerTimestamp(prefix: full.prefix(6)) == nil)
        #expect(RealtimeEngine.headerTimestamp(prefix: Data([0x12, 0x00])) == nil)
    }

    @Test func keepsPreviousValueWithNoHistory() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: nil, newHeader: now, multiplier: 1, chased: true
        )
        #expect(learned == 15)
    }

    /// End to end: from a cold start, repeated scheduling should converge on one poll per publish
    /// rather than the 1.5 the old fixed-10s-interval produced against a 15s feed.
    @Test func convergesToOnePollPerPublishCycle() {
        let publishCycle: TimeInterval = 15
        var clock = now
        var lastHeader: Date? = nil
        var polls = 0
        var newFrames = 0

        // Simulate 5 minutes of polling against a feed publishing every 15s with a 5s availability lag.
        let deadline = now.addingTimeInterval(300)
        while clock < deadline {
            polls += 1
            // Newest frame actually fetchable at this instant.
            let elapsed = clock.timeIntervalSince(now)
            let available = now.addingTimeInterval(
                (elapsed - PollSchedule.publishLag < 0)
                    ? 0
                    : (((elapsed - PollSchedule.publishLag) / publishCycle).rounded(.down) * publishCycle)
            )
            let gotNewData = lastHeader.map { available > $0 } ?? true
            if gotNewData {
                newFrames += 1
                lastHeader = available
            }
            clock = clock.addingTimeInterval(
                PollSchedule.nextDelay(
                    lastHeader: lastHeader, cycle: publishCycle,
                    multiplier: 1, gotNewData: gotNewData, now: clock
                )
            )
        }

        // Ideal is 1.0 requests per published frame; the old fixed 10s interval gave 1.5.
        let ratio = Double(polls) / Double(newFrames)
        #expect(ratio < 1.2, "wasted \(polls - newFrames) of \(polls) requests")
    }
}
