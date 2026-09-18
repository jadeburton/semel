import HelloCore

/// What the app shows, from a package two modules deep: the app imports HelloKit, and
/// HelloKit's module was built against HelloCore, so both modules have to reach the
/// app's compile — which is what the product's module tree carries.
public enum Greeting {
    public static var subtitle: String {
        "via HelloKit, \(Core.counted(2)) modules"
    }
}
