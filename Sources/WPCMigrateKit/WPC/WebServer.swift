/// The web server in front of PHP in a wp-container site.
public enum WebServer: String, Sendable, CaseIterable, Encodable {
    /// wp-container's default.
    case apache
    case nginx
}
