import Foundation

extension Bundle {
    /// Returns the bundle containing ScoutLib resources.
    /// Uses `Bundle.module` for SPM builds and the framework
    /// bundle for Xcode builds.
    static var scoutResources: Bundle {
        #if SWIFT_PACKAGE
            return Bundle.module
        #else
            return Bundle(for: BundleFinder.self)
        #endif
    }
}

/// Anchor class used to locate the ScoutLib framework bundle.
private class BundleFinder {}
