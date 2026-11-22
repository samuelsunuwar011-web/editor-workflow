import SwiftUI

/// Drop-in for `@State`. In current SDKs `@State` is a macro whose plugin ships only with Xcode;
/// this wrapper builds with the Command Line Tools alone.
final class LocalBox<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

@propertyWrapper struct Local<T>: DynamicProperty {
    @StateObject private var box: LocalBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }
    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
}
