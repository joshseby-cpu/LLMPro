import SwiftUI

extension Binding where Value == Double {
    /// Bridges an `Int` binding to the `Double` that `Slider`/`Stepper` want.
    /// Reads convert `Int → Double`; writes round to the nearest `Int`.
    ///
    /// Replaces the repeated inline
    /// `Binding(get: { Double(x) }, set: { x = Int($0.rounded()) })` at call
    /// sites. Beyond the obvious de-duplication, the inline form is a closure the
    /// type-checker has to infer in place — cheap once, but the SwiftUI
    /// preview-dylib compiler (which instruments every literal) is far more
    /// sensitive to it, and several such bindings clustered in one form add up.
    /// This concrete factory removes that per-site inference.
    static func rounding(_ source: Binding<Int>) -> Binding<Double> {
        Binding<Double>(
            get: { Double(source.wrappedValue) },
            set: { source.wrappedValue = Int($0.rounded()) }
        )
    }
}
