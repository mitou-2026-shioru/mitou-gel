import Foundation
import HealthKit

enum HealthSamples {
    static let heartRate = HKQuantityType(.heartRate)
    static let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    static let restingHeartRate = HKQuantityType(.restingHeartRate)
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let milliseconds = HKUnit.secondUnit(with: .milli)

    static func latest(_ type: HKQuantityType, store: HKHealthStore,
                       since: Date) async throws -> HKQuantitySample? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) {
                _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples?.first as? HKQuantitySample) }
            }
            store.execute(query)
        }
    }
}
