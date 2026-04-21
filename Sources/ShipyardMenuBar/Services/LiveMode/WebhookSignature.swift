import Foundation
import CryptoKit

/// GitHub webhook HMAC-SHA256 signature validation.
///
/// GitHub signs every webhook body with the secret you registered on
/// the hook and includes the signature in `X-Hub-Signature-256` as
/// `sha256=<hex>`. The server MUST reject any request whose signature
/// doesn't match the recomputed one — otherwise the webhook endpoint
/// is unauthenticated (the URL alone is not secret enough).
enum WebhookSignature {

    /// Constant-time verify a GitHub `sha256=…` header against the
    /// body + shared secret. Returns true on match.
    static func isValid(body: Data, secret: String, header: String?) -> Bool {
        guard let header, !header.isEmpty else { return false }
        // Accept either "sha256=<hex>" (GitHub's format) or the bare
        // hex, to keep callers defensive.
        let provided: String
        if header.hasPrefix("sha256=") {
            provided = String(header.dropFirst("sha256=".count))
        } else {
            provided = header
        }
        let expected = hmacSHA256Hex(body: body, secret: secret)
        return constantTimeEquals(expected, provided)
    }

    /// Compute the hex-encoded HMAC-SHA256 for a body + secret.
    static func hmacSHA256Hex(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time string compare so an attacker can't use timing
    /// differences to infer the expected signature.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }

    /// Generate a fresh 32-byte secret, base64-encoded. Stored in
    /// Keychain and handed to GitHub when registering the hook.
    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
