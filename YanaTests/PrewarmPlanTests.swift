// YanaTests/PrewarmPlanTests.swift
import Testing
@testable import Yana

struct PrewarmPlanTests {
    @Test func forwardBiasOrdersAheadFirst() {
        let r = PrewarmPlan.indices(current: 5, count: 20, radius: 2, direction: .forward)
        #expect(r == [6, 7, 4, 3])
    }

    @Test func backwardBiasOrdersBehindFirst() {
        let r = PrewarmPlan.indices(current: 5, count: 20, radius: 2, direction: .backward)
        #expect(r == [4, 3, 6, 7])
    }

    @Test func clampsToBounds() {
        let r = PrewarmPlan.indices(current: 1, count: 4, radius: 3, direction: .forward)
        // ahead: 2,3 (4+ out of range); behind: 0
        #expect(r == [2, 3, 0])
    }

    @Test func excludesCurrentAndHandlesEmpty() {
        #expect(PrewarmPlan.indices(current: 0, count: 0, radius: 5, direction: .forward).isEmpty)
        #expect(PrewarmPlan.indices(current: 0, count: 1, radius: 5, direction: .forward).isEmpty)
    }
}
