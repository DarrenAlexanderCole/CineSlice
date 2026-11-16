import CoreMedia
import EditCore

extension MediaTime {
    /// Invalid / indefinite CMTimes become zero.
    init(_ cm: CMTime) {
        if cm.isNumeric && cm.timescale > 0 {
            self.init(value: cm.value, timescale: cm.timescale)
        } else {
            self.init(value: 0)
        }
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

extension MediaTimeRange {
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}
