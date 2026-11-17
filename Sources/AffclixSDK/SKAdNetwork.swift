import Foundation
#if canImport(StoreKit) && os(iOS)
import StoreKit
#endif

/// SKAdNetwork 4 coarse conversion value.
public enum CoarseConversionValue {
    case low, medium, high
}

/// SKAdNetwork conversion value updates — Apple's privacy-preserving install
/// attribution, which works without ATT consent. On iOS 17.4+ Apple's
/// AdAttributionKit also accepts these SKAdNetwork calls.
protocol ConversionValueUpdating {
    func update(fine: Int, coarse: CoarseConversionValue?, lockWindow: Bool, completion: ((Error?) -> Void)?)
}

extension ConversionValueUpdating {
    /// First-launch registration: conversion value 0 starts the measurement window.
    func register() {
        update(fine: 0, coarse: nil, lockWindow: false, completion: nil)
    }
}

struct SystemSKAdNetwork: ConversionValueUpdating {
    func update(fine: Int, coarse: CoarseConversionValue?, lockWindow: Bool, completion: ((Error?) -> Void)?) {
        #if canImport(StoreKit) && os(iOS)
        let fine = min(max(fine, 0), 63)
        if #available(iOS 16.1, *), let coarse = coarse {
            let value: SKAdNetwork.CoarseConversionValue
            switch coarse {
            case .low: value = .low
            case .medium: value = .medium
            case .high: value = .high
            }
            SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: value, lockWindow: lockWindow) { completion?($0) }
        } else if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(fine) { completion?($0) }
        } else if #available(iOS 14.0, *) {
            SKAdNetwork.updateConversionValue(fine)
            completion?(nil)
        } else {
            completion?(nil)
        }
        #else
        completion?(nil)
        #endif
    }
}
