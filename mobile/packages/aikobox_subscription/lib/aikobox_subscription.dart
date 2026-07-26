/// Pure-Dart subscription payload normalisation, share-link URI parsing and
/// bounds enforcement for AikoBox.
///
/// A subscription body is hostile input. It arrives over the network from a
/// server the user picked but does not control, and it is fed straight into
/// the config that decides where every packet on the device goes. Everything
/// in this package is written on that assumption (non-negotiable N7):
///
///  * Nothing is guessed at. A body that is not recognisably Clash YAML, a
///    share-link list or a Base64-wrapped share-link list is refused, never
///    partially imported.
///  * Every cap the desktop applies is applied here, byte for byte, so the
///    same subscription is accepted or refused on both platforms.
///  * No error message may carry payload bytes, a URL, a token or a secret.
///    [redactUrl] and [redactSecrets] exist for the messages that need to name
///    a subscription at all.
///
/// The whole package is synchronous and has no I/O, so it is safe to call from
/// an isolate and easy to test exhaustively.
///
/// Ported from `src/main/config/subscriptionPayload.ts`,
/// `src/main/utils/yaml.ts` and the redaction helpers in
/// `src/main/config/profile.ts`.
library;

export 'src/bounds.dart'
    show
        asClashDict,
        asClashList,
        assertBoundedClashSubscription,
        kMaxSubscriptionGroups,
        kMaxSubscriptionLineLength,
        kMaxSubscriptionProviders,
        kMaxSubscriptionProxies,
        kMaxSubscriptionRules;
export 'src/exceptions.dart'
    show SubscriptionBoundsException, SubscriptionFormatException;
export 'src/normalize.dart'
    show
        NormalizedSubscription,
        SubscriptionFormat,
        normalizeSubscription,
        normalizeSubscriptionPayload;
export 'src/redact.dart'
    show
        kMaxRedactedMessageLength,
        kRedactedAuthorization,
        kRedactedUrlPlaceholder,
        redactSecrets,
        redactUrl;
export 'src/share_links.dart' show kSupportedShareLinkSchemes, parseShareLink;
