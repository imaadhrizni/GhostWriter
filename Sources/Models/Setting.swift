import Foundation

// MARK: - @Setting property wrapper

/// A `UserDefaults`-backed setting on `AppSettings`, collapsing the repetitive
/// four-line `get { typed(Key, Default) } set { set(newValue, Key) }` accessor
/// into a single declaration:
///
///     @Setting(Key.redactEmails, Default.redactEmails) var redactEmails: Bool
///
/// The value is **not** stored in the wrapper — `UserDefaults` remains the single
/// source of truth, so `resetToDefaults()` (which clears the keys) and external
/// `defaults` writes stay authoritative. Live SwiftUI updates are preserved: the
/// enclosing-instance `subscript` fires `AppSettings.objectWillChange` on write,
/// exactly as the hand-written `set(_:_:)` helper did.
///
/// Only pure scalar keys use this wrapper. Keys with bespoke logic (JSON-encoded
/// dictionaries, trailing-slash trimming, path expansion) keep their computed
/// accessors — this wrapper deliberately does not try to model them.
@propertyWrapper
struct Setting<Value> {

    let key: String
    let defaultValue: Value
    private let read: (UserDefaults) -> Value
    private let write: (UserDefaults, Value) -> Void

    fileprivate init(key: String, defaultValue: Value,
                     read: @escaping (UserDefaults) -> Value,
                     write: @escaping (UserDefaults, Value) -> Void) {
        self.key = key
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
    }

    // Direct member access (`settings.foo`) routes through the enclosing-instance
    // subscript below. But **key-path** access does NOT — and SwiftUI builds every
    // `$settings.foo` binding from a `ReferenceWritableKeyPath`, so a Toggle/Picker/
    // Menu write lands *here*, not on the subscript. This therefore has to be fully
    // functional (read + persist + notify), or UI edits silently vanish. It routes
    // through the `AppSettings.shared` singleton — the only instance these live on —
    // so both access paths behave identically.
    var wrappedValue: Value {
        get { read(AppSettings.shared.defaults) }
        set {
            AppSettings.shared.objectWillChange.send()
            write(AppSettings.shared.defaults, newValue)
        }
    }

    static subscript(
        _enclosingInstance instance: AppSettings,
        wrapped _: ReferenceWritableKeyPath<AppSettings, Value>,
        storage: ReferenceWritableKeyPath<AppSettings, Setting<Value>>
    ) -> Value {
        get {
            let s = instance[keyPath: storage]
            return s.read(instance.defaults)
        }
        set {
            let s = instance[keyPath: storage]
            instance.objectWillChange.send()
            s.write(instance.defaults, newValue)
        }
    }
}

// MARK: - Typed initializers (one per scalar kind)

extension Setting where Value == Bool {
    init(_ key: String, _ def: Bool) {
        self.init(key: key, defaultValue: def,
                  read: { $0.object(forKey: key) == nil ? def : $0.bool(forKey: key) },
                  write: { $0.set($1, forKey: key) })
    }
}

extension Setting where Value == Int {
    init(_ key: String, _ def: Int) {
        self.init(key: key, defaultValue: def,
                  read: { $0.object(forKey: key) == nil ? def : $0.integer(forKey: key) },
                  write: { $0.set($1, forKey: key) })
    }
}

extension Setting where Value == Double {
    init(_ key: String, _ def: Double) {
        self.init(key: key, defaultValue: def,
                  read: { $0.object(forKey: key) == nil ? def : $0.double(forKey: key) },
                  write: { $0.set($1, forKey: key) })
    }
}

extension Setting where Value == Float {
    init(_ key: String, _ def: Float) {
        self.init(key: key, defaultValue: def,
                  read: { $0.object(forKey: key) == nil ? def : $0.float(forKey: key) },
                  write: { $0.set($1, forKey: key) })
    }
}

extension Setting where Value == String {
    init(_ key: String, _ def: String) {
        self.init(key: key, defaultValue: def,
                  read: { $0.string(forKey: key) ?? def },
                  write: { $0.set($1, forKey: key) })
    }
}
