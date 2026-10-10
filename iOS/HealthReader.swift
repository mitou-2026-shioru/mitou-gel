import Combine
import Foundation
import HealthKit

@MainActor
final class HealthReader: ObservableObject {
    @Published var status = "ヘルスケア未接続"
    @Published var reading: SensorReading?
    @Published var restingHeartRate: Double?
    @Published var hrvValue: Double?
    @Published var hrvDate: Date?
    private let store = HKHealthStore()
    private var requested = false
    private var refreshing = false

    func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "この端末ではHealthKitを利用できません"
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [HealthSamples.heartRate,
                HealthSamples.hrv, HealthSamples.restingHeartRate])
            requested = true
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func refresh() async {
        guard requested, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let since = Date().addingTimeInterval(-86_400)
            async let heart = HealthSamples.latest(HealthSamples.heartRate, store: store, since: since)
            async let variability = HealthSamples.latest(HealthSamples.hrv, store: store, since: since)
            async let resting = HealthSamples.latest(HealthSamples.restingHeartRate, store: store,
                                                     since: Date().addingTimeInterval(-604_800))
            let (heartSample, hrvSample, restingSample) = try await (heart, variability, resting)
            hrvValue = hrvSample?.quantity.doubleValue(for: HealthSamples.milliseconds)
            hrvDate = hrvSample?.endDate
            restingHeartRate = restingSample?.quantity.doubleValue(for: HealthSamples.bpm)
            if let heartSample {
                reading = SensorReading(id: heartSample.uuid, measuredAt: heartSample.endDate,
                                        heartRate: heartSample.quantity.doubleValue(for: HealthSamples.bpm),
                                        hrvMilliseconds: hrvValue, hrvMeasuredAt: hrvDate, source: .healthKit)
                status = "最新サンプル取得済み（Watchとの同期には遅延があります）"
            } else {
                status = "読める心拍データがありません。権限とWatchの計測を確認してください"
            }
        } catch {
            status = error.localizedDescription
        }
    }
}
