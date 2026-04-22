/**
 * Shared cryptographic helpers for Pulse Library bundle signing and verification.
 */
public with sharing class PulseCrypto {

    /**
     * Strips PEM header/footer lines and whitespace, returning the raw base64 body.
     * Works for both public and private keys (BEGIN/END ... KEY).
     */
    public static String stripPemHeaders(String pem) {
        if (String.isBlank(pem)) {
            return '';
        }
        String stripped = pem
            .replaceAll('-----BEGIN [A-Z ]+-----', '')
            .replaceAll('-----END [A-Z ]+-----', '')
            .replaceAll('\\s', '');
        return stripped;
    }

    /**
     * Returns a truncated SHA-256 fingerprint (first 32 chars of base64)
     * suitable for display and matching purposes.
     */
    public static String sha256Fingerprint(String input) {
        if (String.isBlank(input)) {
            return '';
        }
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(input));
        String full = EncodingUtil.base64Encode(digest);
        return full.substring(0, Math.min(32, full.length()));
    }
}
