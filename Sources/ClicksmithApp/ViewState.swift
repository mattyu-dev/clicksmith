import SwiftUI

/// Drop-in for `@State`. On this Mac (Command Line Tools only, no Xcode) the SwiftUI macro
/// plugin is missing, so `@State` does not compile. Wrapping `State` by hand avoids the macro.
/// See vault/06 Knowledge/Toolchain without Xcode.md.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>
    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
