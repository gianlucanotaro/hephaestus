/// Single source of truth for the version. `build.sh` reads this line for CFBundleShortVersionString,
/// so keep the `current = "x.y"` shape.
public enum HephaestusVersion {
    public static let current = "0.2.1"
}
