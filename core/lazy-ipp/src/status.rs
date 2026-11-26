//! The status codes of RFC 8011 appendix B and PWG 5100.13.

pub const SUCCESSFUL_OK: u16 = 0x0000;
pub const SUCCESSFUL_OK_IGNORED_OR_SUBSTITUTED_ATTRIBUTES: u16 = 0x0001;
pub const SUCCESSFUL_OK_CONFLICTING_ATTRIBUTES: u16 = 0x0002;
pub const SUCCESSFUL_OK_IGNORED_SUBSCRIPTIONS: u16 = 0x0003;
pub const SUCCESSFUL_OK_TOO_MANY_EVENTS: u16 = 0x0005;
pub const SUCCESSFUL_OK_EVENTS_COMPLETE: u16 = 0x0007;
pub const CLIENT_ERROR_BAD_REQUEST: u16 = 0x0400;
pub const CLIENT_ERROR_FORBIDDEN: u16 = 0x0401;
pub const CLIENT_ERROR_NOT_AUTHENTICATED: u16 = 0x0402;
pub const CLIENT_ERROR_NOT_AUTHORIZED: u16 = 0x0403;
pub const CLIENT_ERROR_NOT_POSSIBLE: u16 = 0x0404;
pub const CLIENT_ERROR_TIMEOUT: u16 = 0x0405;
pub const CLIENT_ERROR_NOT_FOUND: u16 = 0x0406;
pub const CLIENT_ERROR_GONE: u16 = 0x0407;
pub const CLIENT_ERROR_REQUEST_ENTITY_TOO_LARGE: u16 = 0x0408;
pub const CLIENT_ERROR_REQUEST_VALUE_TOO_LONG: u16 = 0x0409;
pub const CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED: u16 = 0x040a;
pub const CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED: u16 = 0x040b;
pub const CLIENT_ERROR_URI_SCHEME_NOT_SUPPORTED: u16 = 0x040c;
pub const CLIENT_ERROR_CHARSET_NOT_SUPPORTED: u16 = 0x040d;
pub const CLIENT_ERROR_CONFLICTING_ATTRIBUTES: u16 = 0x040e;
pub const CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED: u16 = 0x040f;
pub const CLIENT_ERROR_COMPRESSION_ERROR: u16 = 0x0410;
pub const CLIENT_ERROR_DOCUMENT_FORMAT_ERROR: u16 = 0x0411;
pub const CLIENT_ERROR_DOCUMENT_ACCESS_ERROR: u16 = 0x0412;
pub const CLIENT_ERROR_ATTRIBUTES_NOT_SETTABLE: u16 = 0x0413;
pub const CLIENT_ERROR_IGNORED_ALL_SUBSCRIPTIONS: u16 = 0x0414;
pub const CLIENT_ERROR_TOO_MANY_SUBSCRIPTIONS: u16 = 0x0415;
pub const CLIENT_ERROR_DOCUMENT_PASSWORD_ERROR: u16 = 0x0418;
pub const CLIENT_ERROR_DOCUMENT_PERMISSION_ERROR: u16 = 0x0419;
pub const CLIENT_ERROR_DOCUMENT_SECURITY_ERROR: u16 = 0x041a;
pub const CLIENT_ERROR_DOCUMENT_UNPRINTABLE_ERROR: u16 = 0x041b;
pub const CLIENT_ERROR_ACCOUNT_INFO_NEEDED: u16 = 0x041c;
pub const CLIENT_ERROR_ACCOUNT_CLOSED: u16 = 0x041d;
pub const CLIENT_ERROR_ACCOUNT_LIMIT_REACHED: u16 = 0x041e;
pub const CLIENT_ERROR_ACCOUNT_AUTHORIZATION_FAILED: u16 = 0x041f;
pub const CLIENT_ERROR_NOT_FETCHABLE: u16 = 0x0420;
pub const SERVER_ERROR_INTERNAL_ERROR: u16 = 0x0500;
pub const SERVER_ERROR_OPERATION_NOT_SUPPORTED: u16 = 0x0501;
pub const SERVER_ERROR_SERVICE_UNAVAILABLE: u16 = 0x0502;
pub const SERVER_ERROR_VERSION_NOT_SUPPORTED: u16 = 0x0503;
pub const SERVER_ERROR_DEVICE_ERROR: u16 = 0x0504;
pub const SERVER_ERROR_TEMPORARY_ERROR: u16 = 0x0505;
pub const SERVER_ERROR_NOT_ACCEPTING_JOBS: u16 = 0x0506;
pub const SERVER_ERROR_BUSY: u16 = 0x0507;
pub const SERVER_ERROR_JOB_CANCELED: u16 = 0x0508;
pub const SERVER_ERROR_MULTIPLE_DOCUMENT_JOBS_NOT_SUPPORTED: u16 = 0x0509;
pub const SERVER_ERROR_PRINTER_IS_DEACTIVATED: u16 = 0x050a;
pub const SERVER_ERROR_TOO_MANY_JOBS: u16 = 0x050b;
pub const SERVER_ERROR_TOO_MANY_DOCUMENTS: u16 = 0x050c;

const NAMES: &[(u16, &str)] = &[
    (SUCCESSFUL_OK, "successful-ok"),
    (
        SUCCESSFUL_OK_IGNORED_OR_SUBSTITUTED_ATTRIBUTES,
        "successful-ok-ignored-or-substituted-attributes",
    ),
    (
        SUCCESSFUL_OK_CONFLICTING_ATTRIBUTES,
        "successful-ok-conflicting-attributes",
    ),
    (
        SUCCESSFUL_OK_IGNORED_SUBSCRIPTIONS,
        "successful-ok-ignored-subscriptions",
    ),
    (
        SUCCESSFUL_OK_TOO_MANY_EVENTS,
        "successful-ok-too-many-events",
    ),
    (
        SUCCESSFUL_OK_EVENTS_COMPLETE,
        "successful-ok-events-complete",
    ),
    (CLIENT_ERROR_BAD_REQUEST, "client-error-bad-request"),
    (CLIENT_ERROR_FORBIDDEN, "client-error-forbidden"),
    (
        CLIENT_ERROR_NOT_AUTHENTICATED,
        "client-error-not-authenticated",
    ),
    (CLIENT_ERROR_NOT_AUTHORIZED, "client-error-not-authorized"),
    (CLIENT_ERROR_NOT_POSSIBLE, "client-error-not-possible"),
    (CLIENT_ERROR_TIMEOUT, "client-error-timeout"),
    (CLIENT_ERROR_NOT_FOUND, "client-error-not-found"),
    (CLIENT_ERROR_GONE, "client-error-gone"),
    (
        CLIENT_ERROR_REQUEST_ENTITY_TOO_LARGE,
        "client-error-request-entity-too-large",
    ),
    (
        CLIENT_ERROR_REQUEST_VALUE_TOO_LONG,
        "client-error-request-value-too-long",
    ),
    (
        CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
        "client-error-document-format-not-supported",
    ),
    (
        CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED,
        "client-error-attributes-or-values-not-supported",
    ),
    (
        CLIENT_ERROR_URI_SCHEME_NOT_SUPPORTED,
        "client-error-uri-scheme-not-supported",
    ),
    (
        CLIENT_ERROR_CHARSET_NOT_SUPPORTED,
        "client-error-charset-not-supported",
    ),
    (
        CLIENT_ERROR_CONFLICTING_ATTRIBUTES,
        "client-error-conflicting-attributes",
    ),
    (
        CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED,
        "client-error-compression-not-supported",
    ),
    (
        CLIENT_ERROR_COMPRESSION_ERROR,
        "client-error-compression-error",
    ),
    (
        CLIENT_ERROR_DOCUMENT_FORMAT_ERROR,
        "client-error-document-format-error",
    ),
    (
        CLIENT_ERROR_DOCUMENT_ACCESS_ERROR,
        "client-error-document-access-error",
    ),
    (
        CLIENT_ERROR_ATTRIBUTES_NOT_SETTABLE,
        "client-error-attributes-not-settable",
    ),
    (
        CLIENT_ERROR_IGNORED_ALL_SUBSCRIPTIONS,
        "client-error-ignored-all-subscriptions",
    ),
    (
        CLIENT_ERROR_TOO_MANY_SUBSCRIPTIONS,
        "client-error-too-many-subscriptions",
    ),
    (
        CLIENT_ERROR_DOCUMENT_PASSWORD_ERROR,
        "client-error-document-password-error",
    ),
    (
        CLIENT_ERROR_DOCUMENT_PERMISSION_ERROR,
        "client-error-document-permission-error",
    ),
    (
        CLIENT_ERROR_DOCUMENT_SECURITY_ERROR,
        "client-error-document-security-error",
    ),
    (
        CLIENT_ERROR_DOCUMENT_UNPRINTABLE_ERROR,
        "client-error-document-unprintable-error",
    ),
    (
        CLIENT_ERROR_ACCOUNT_INFO_NEEDED,
        "client-error-account-info-needed",
    ),
    (CLIENT_ERROR_ACCOUNT_CLOSED, "client-error-account-closed"),
    (
        CLIENT_ERROR_ACCOUNT_LIMIT_REACHED,
        "client-error-account-limit-reached",
    ),
    (
        CLIENT_ERROR_ACCOUNT_AUTHORIZATION_FAILED,
        "client-error-account-authorization-failed",
    ),
    (CLIENT_ERROR_NOT_FETCHABLE, "client-error-not-fetchable"),
    (SERVER_ERROR_INTERNAL_ERROR, "server-error-internal-error"),
    (
        SERVER_ERROR_OPERATION_NOT_SUPPORTED,
        "server-error-operation-not-supported",
    ),
    (
        SERVER_ERROR_SERVICE_UNAVAILABLE,
        "server-error-service-unavailable",
    ),
    (
        SERVER_ERROR_VERSION_NOT_SUPPORTED,
        "server-error-version-not-supported",
    ),
    (SERVER_ERROR_DEVICE_ERROR, "server-error-device-error"),
    (SERVER_ERROR_TEMPORARY_ERROR, "server-error-temporary-error"),
    (
        SERVER_ERROR_NOT_ACCEPTING_JOBS,
        "server-error-not-accepting-jobs",
    ),
    (SERVER_ERROR_BUSY, "server-error-busy"),
    (SERVER_ERROR_JOB_CANCELED, "server-error-job-canceled"),
    (
        SERVER_ERROR_MULTIPLE_DOCUMENT_JOBS_NOT_SUPPORTED,
        "server-error-multiple-document-jobs-not-supported",
    ),
    (
        SERVER_ERROR_PRINTER_IS_DEACTIVATED,
        "server-error-printer-is-deactivated",
    ),
    (SERVER_ERROR_TOO_MANY_JOBS, "server-error-too-many-jobs"),
    (
        SERVER_ERROR_TOO_MANY_DOCUMENTS,
        "server-error-too-many-documents",
    ),
];

/// The keyword of a status code ("client-error-not-found"), or its number ("0x0421") for one not listed.
pub fn status_name(code: u16) -> String {
    match NAMES.iter().find(|(c, _)| *c == code) {
        Some((_, name)) => name.to_string(),
        None => format!("0x{code:04X}"),
    }
}
