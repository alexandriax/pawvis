import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "com.pawvis.Pawvis", category: "app")
    static let camera = Logger(subsystem: "com.pawvis.Pawvis", category: "camera")
    static let tracking = Logger(subsystem: "com.pawvis.Pawvis", category: "tracking")
    static let mouse = Logger(subsystem: "com.pawvis.Pawvis", category: "mouse")
    static let voice = Logger(subsystem: "com.pawvis.Pawvis", category: "voice")
}
