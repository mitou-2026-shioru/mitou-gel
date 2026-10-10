import Accelerate
import Foundation

public enum CircumplexAudioFeatures {
    public static func analyze(_ samples: [Float], sampleRate: Int = 16_000) -> [String: Double]? {
        guard sampleRate == 16_000, (8_000...128_000).contains(samples.count),
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1.5 }),
              let spectrumTransform = AcousticTransform(size: 2_048, direction: .FORWARD),
              let correlationTransform = AcousticTransform(size: 4_096, direction: .FORWARD),
              let inverseTransform = AcousticTransform(size: 4_096, direction: .INVERSE) else { return nil }
        let frameSize = 2_048
        let hop = 512
        let window = (0..<frameSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frameSize - 1))) }
        let frequencies = (0..<(frameSize / 2)).map { Double($0 * sampleRate) / Double(frameSize) }
        var rms: [Double] = []
        var pitches: [Double] = []
        var harmonicity: [Double] = []
        var series: [String: [Double]] = [:]
        var previousSpectrum = Array(repeating: 0.0, count: frameSize / 2)
        for offset in stride(from: 0, through: samples.count - frameSize, by: hop) {
            let frame = Array(samples[offset..<(offset + frameSize)])
            rms.append(sqrt(frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frameSize)))
            let crossings = (1..<frameSize).filter { frame[$0].sign != frame[$0 - 1].sign }.count
            series["zcr", default: []].append(Double(crossings) / Double(frameSize - 1))
            let transformed = spectrumTransform.execute(frame.indices.map { Double(frame[$0] * window[$0]) })
            let spectrum = (0..<(frameSize / 2)).map { hypot(transformed.real[$0], transformed.imaginary[$0]) }
            let total = max(spectrum.reduce(0, +), 1e-8)
            let centroid = spectrum.indices.reduce(0.0) { $0 + spectrum[$1] * frequencies[$1] } / total
            let bandwidth = sqrt(spectrum.indices.reduce(0.0) { $0 + spectrum[$1] * pow(frequencies[$1] - centroid, 2) } / total)
            var cumulative = 0.0
            var rolloff = 0.0
            for index in spectrum.indices {
                cumulative += spectrum[index]
                if cumulative >= total * 0.85 { rolloff = frequencies[index]; break }
            }
            func band(_ lower: Double, _ upper: Double) -> Double {
                spectrum.indices.reduce(0.0) { total, index in
                    total + (frequencies[index] >= lower && frequencies[index] < upper ? spectrum[index] : 0)
                }
            }
            let low = band(80, 700)
            let mid = band(700, 1_800)
            let high = band(1_800, 6_000)
            let full = max(band(80, 8_000), 1e-8)
            let power = spectrum.map { $0 * $0 }
            let flatness = exp(power.reduce(0) { $0 + log(max($1, 1e-12)) } / Double(power.count))
                / max(power.reduce(0, +) / Double(power.count), 1e-12)
            let maximum = max(spectrum.max() ?? 0, 1e-8)
            let normalized = spectrum.map { $0 / maximum }
            let flux = offset == 0 ? 0 : normalized.indices.reduce(0.0) { $0 + max(normalized[$1] - previousSpectrum[$1], 0) }
                / Double(normalized.count)
            previousSpectrum = normalized
            let spectral: [String: Double] = ["centroid": centroid, "bandwidth": bandwidth, "rolloff85": rolloff,
                "high_ratio": high / max(low + high, 1e-8), "mid_ratio": mid / max(low + mid + high, 1e-8),
                "spectral_tilt": log10(max(low, 1e-8)) - log10(max(high, 1e-8)), "flatness": flatness, "flux": flux]
            for (name, value) in spectral { series[name, default: []].append(value) }
            for (lower, upper) in [(80, 250), (250, 500), (500, 1_000), (1_000, 2_000), (2_000, 4_000), (4_000, 8_000)] {
                series["band\(lower)_\(upper)_ratio", default: []].append(band(Double(lower), Double(upper)) / full)
            }
            let average = Float(frame.reduce(0.0) { $0 + Double($1) } / Double(frameSize))
            let centered = frame.map { Double($0 - average) }
            let energy = centered.reduce(0) { $0 + $1 * $1 }
            if energy > 1e-8 {
                let padded = centered + Array(repeating: 0.0, count: frameSize)
                let transformed = correlationTransform.execute(padded)
                let power = transformed.real.indices.map { pow(transformed.real[$0], 2) + pow(transformed.imaginary[$0], 2) }
                let correlation = inverseTransform.execute(power).real
                let best = (sampleRate / 420...sampleRate / 70).max { correlation[$0] < correlation[$1] } ?? 0
                let strength = best > 0 ? correlation[best] / Double(padded.count) / energy : 0
                pitches.append(strength > 0.28 && best > 0 ? Double(sampleRate) / Double(best) : 0)
                harmonicity.append(strength)
            } else {
                pitches.append(0)
                harmonicity.append(0)
            }
        }
        let noise = max(percentile(rms, 0.1), 1e-5)
        var threshold = max(percentile(rms, 0.25), percentile(rms, 0.95) * 0.12, noise * 2)
        if rms.filter({ $0 >= threshold }).count < max(3, rms.count / 10) { threshold = percentile(rms, 0.7) }
        let active = rms.indices.filter { rms[$0] >= threshold }
        let voiced = active.filter { pitches[$0] > 0 }
        let activeRMS = active.map { rms[$0] }
        let activePitches = voiced.map { pitches[$0] }
        let globalRMS = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        var result: [String: Double] = ["active_ratio": Double(active.count) / Double(rms.count),
            "rms_global": globalRMS, "dbfs_global": decibels(globalRMS),
            "rms_active_p50": percentile(activeRMS, 0.5), "rms_active_p90": percentile(activeRMS, 0.9),
            "dbfs_active_p50": decibels(percentile(activeRMS, 0.5)), "dbfs_active_p90": decibels(percentile(activeRMS, 0.9)),
            "crest_factor": Double(samples.map { abs($0) }.max() ?? 0) / max(globalRMS, 1e-8),
            "voiced_ratio": Double(voiced.count) / Double(rms.count),
            "pitch_active_p50": percentile(activePitches, 0.5), "pitch_active_p75": percentile(activePitches, 0.75),
            "pitch_active_p90": percentile(activePitches, 0.9),
            "pitch_active_range": percentile(activePitches, 0.9) - percentile(activePitches, 0.1),
            "pitch_active_std": deviation(activePitches),
            "harmonicity_active_p50": percentile(active.map { harmonicity[$0] }, 0.5),
            "harmonicity_active_p75": percentile(active.map { harmonicity[$0] }, 0.75)]
        for (name, values) in series {
            let selected = active.map { values[$0] }
            for (suffix, fraction) in [("p50", 0.5), ("p75", 0.75), ("p90", 0.9)] {
                result["\(name)_active_\(suffix)"] = percentile(selected, fraction)
            }
        }
        for (prefix, values, indices) in [("energy_active", activeRMS.map(decibels), active),
                                          ("pitch_active", activePitches, voiced)] {
            let times = indices.map { Double($0 * hop) / Double(sampleRate) }
            let meanTime = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
            let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            let denominator = times.reduce(0) { $0 + pow($1 - meanTime, 2) }
            let numerator = values.indices.reduce(0.0) { $0 + (times[$1] - meanTime) * (values[$1] - mean) }
            let delta = values.count > 1 ? (1..<values.count).map { values[$0] - values[$0 - 1] } : []
            let peakThreshold = percentile(values, 0.75)
            let peaks = values.count >= 3 ? (1..<(values.count - 1)).filter {
                values[$0] > values[$0 - 1] && values[$0] > values[$0 + 1] && values[$0] >= peakThreshold
            }.count : 0
            result["\(prefix)_range"] = percentile(values, 0.9) - percentile(values, 0.1)
            result["\(prefix)_slope"] = denominator > 1e-9 ? numerator / denominator : 0
            result["\(prefix)_delta_mean_abs"] = delta.isEmpty ? 0 : delta.reduce(0) { $0 + abs($1) } / Double(delta.count)
            result["\(prefix)_delta_std"] = deviation(delta)
            result["\(prefix)_rising_ratio"] = delta.isEmpty ? 0 : Double(delta.filter { $0 > 0 }.count) / Double(delta.count)
            result["\(prefix)_peak_count"] = Double(peaks)
        }
        return result.values.allSatisfy(\.isFinite) ? result : nil
    }

    private static func decibels(_ value: Double) -> Double { 20 * log10(max(value, 1e-8)) }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = fraction * Double(sorted.count - 1)
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - Double(lower))
    }

    private static func deviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count))
    }
}

private final class AcousticTransform {
    private let setup: vDSP_DFT_SetupD
    private let size: Int

    init?(size: Int, direction: vDSP_DFT_Direction) {
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(size), direction) else { return nil }
        self.setup = setup
        self.size = size
    }

    deinit { vDSP_DFT_DestroySetupD(setup) }

    func execute(_ real: [Double]) -> (real: [Double], imaginary: [Double]) {
        let imaginary = Array(repeating: 0.0, count: size)
        var outputReal = Array(repeating: 0.0, count: size)
        var outputImaginary = Array(repeating: 0.0, count: size)
        vDSP_DFT_ExecuteD(setup, real, imaginary, &outputReal, &outputImaginary)
        return (outputReal, outputImaginary)
    }
}
