import Combine
import Foundation
import HealthKit

@MainActor
final class WatchSessionModel: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    @Published var running = false
    @Published var busy = false
    @Published var heartRate: Double?
    @Published var measuredAt: Date?
    @Published var startedAt: Date?
    @Published var message = ""
    let bridge = WatchBridge()
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var hrv: HKQuantitySample?
    private var lastHRVQuery = Date.distantPast
    private var finalizing = false

    func start() async {
        guard !running, !busy else { return }
        busy = true
        defer { busy = false }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "HealthKitを利用できません"
            return
        }
        do {
            let workout = HKObjectType.workoutType()
            let energy = HKQuantityType(.activeEnergyBurned)
            try await store.requestAuthorization(toShare: [workout, energy, HealthSamples.heartRate],
                                                  read: [HealthSamples.heartRate, HealthSamples.hrv, energy])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .mindAndBody
            configuration.locationType = .indoor
            let created = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let liveBuilder = created.associatedWorkoutBuilder()
            created.delegate = self
            liveBuilder.delegate = self
            liveBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session = created
            builder = liveBuilder
            heartRate = nil
            measuredAt = nil
            let start = Date()
            startedAt = start
            created.startActivity(with: start)
            try await liveBuilder.beginCollection(at: start)
            running = true
            message = "心拍の取得待ち"
            await refreshHRV()
        } catch {
            session?.end()
            builder?.discardWorkout()
            session = nil
            builder = nil
            running = false
            message = error.localizedDescription
        }
    }

    func stop() {
        guard running, !busy else { return }
        busy = true
        running = false
        message = "保存中"
        session?.end()
    }

    private func finish(at date: Date) async {
        guard !finalizing, let builder else { return }
        finalizing = true
        defer {
            session = nil
            self.builder = nil
            busy = false
            running = false
            finalizing = false
        }
        do {
            try await builder.endCollection(at: date)
            _ = try await builder.finishWorkout()
            message = "保存しました"
        } catch {
            builder.discardWorkout()
            message = error.localizedDescription
        }
    }

    private func refreshHRV() async {
        guard Date().timeIntervalSince(lastHRVQuery) > 60 else { return }
        lastHRVQuery = Date()
        hrv = try? await HealthSamples.latest(HealthSamples.hrv, store: store,
                                              since: Date().addingTimeInterval(-86_400))
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(HealthSamples.heartRate),
              let statistics = workoutBuilder.statistics(for: HealthSamples.heartRate),
              let quantity = statistics.mostRecentQuantity(),
              let interval = statistics.mostRecentQuantityDateInterval() else { return }
        let value = quantity.doubleValue(for: HealthSamples.bpm)
        let date = interval.end
        Task { @MainActor in
            guard self.running else { return }
            self.heartRate = value
            self.measuredAt = date
            self.message = "計測中"
            self.bridge.send(SensorReading(measuredAt: date, heartRate: value,
                hrvMilliseconds: self.hrv?.quantity.doubleValue(for: HealthSamples.milliseconds),
                hrvMeasuredAt: self.hrv?.endDate, source: .watch))
            await self.refreshHRV()
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended {
            Task { @MainActor in await self.finish(at: date) }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.running = false
            self.busy = false
            self.builder?.discardWorkout()
            self.builder = nil
            self.session = nil
            self.message = message
        }
    }
}
