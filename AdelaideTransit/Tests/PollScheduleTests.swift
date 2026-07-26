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
            lastHeader: now.addingTimeInterval(-60), cycle: cycle, multiplier: 1, gotNewData: false, now: now
        )
        #expect(delay == PollSchedule.missRetry)
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
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(20), multiplier: 1
        )
        #expect(learned == 20)
    }

    /// The trap this guard exists for: a feed polled every 4th cycle sees 60s gaps. Learning from those
    /// would ratchet the cadence slower on every pass until it stopped being live at all.
    @Test func doesNotLearnWhileDeliberatelySkippingCycles() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(60), multiplier: 4
        )
        #expect(learned == 15)
    }

    @Test func ignoresImplausibleGaps() {
        let tooLong = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(3600), multiplier: 1
        )
        let tooShort = PollSchedule.learnedCycle(
            previous: 15, lastHeader: now, newHeader: now.addingTimeInterval(0.5), multiplier: 1
        )
        #expect(tooLong == 15)
        #expect(tooShort == 15)
    }

    @Test func keepsPreviousValueWithNoHistory() {
        let learned = PollSchedule.learnedCycle(
            previous: 15, lastHeader: nil, newHeader: now, multiplier: 1
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
