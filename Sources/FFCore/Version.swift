/// Single source of truth for the release version. Bumped at release
/// time; the Makefile parses `string` to stamp the bundle and name the
/// DMG, and `ffctl --version` prints it.
public enum FFVersion {
    public static let string = "0.5.0"
}
