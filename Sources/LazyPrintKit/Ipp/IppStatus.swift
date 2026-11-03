import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppStatus.cs: the status codes of RFC 8011 §B and PWG 5100.13.

public enum IppStatus: UInt16, Sendable {
    case successfulOk = 0x0000
    case successfulOkIgnoredOrSubstitutedAttributes = 0x0001
    case successfulOkConflictingAttributes = 0x0002
    case successfulOkIgnoredSubscriptions = 0x0003
    case successfulOkTooManyEvents = 0x0005
    case successfulOkEventsComplete = 0x0007

    case clientErrorBadRequest = 0x0400
    case clientErrorForbidden = 0x0401
    case clientErrorNotAuthenticated = 0x0402
    case clientErrorNotAuthorized = 0x0403
    case clientErrorNotPossible = 0x0404
    case clientErrorTimeout = 0x0405
    case clientErrorNotFound = 0x0406
    case clientErrorGone = 0x0407
    case clientErrorRequestEntityTooLarge = 0x0408
    case clientErrorRequestValueTooLong = 0x0409
    case clientErrorDocumentFormatNotSupported = 0x040A
    case clientErrorAttributesOrValuesNotSupported = 0x040B
    case clientErrorUriSchemeNotSupported = 0x040C
    case clientErrorCharsetNotSupported = 0x040D
    case clientErrorConflictingAttributes = 0x040E
    case clientErrorCompressionNotSupported = 0x040F
    case clientErrorCompressionError = 0x0410
    case clientErrorDocumentFormatError = 0x0411
    case clientErrorDocumentAccessError = 0x0412
    case clientErrorAttributesNotSettable = 0x0413
    case clientErrorIgnoredAllSubscriptions = 0x0414
    case clientErrorTooManySubscriptions = 0x0415
    case clientErrorDocumentPasswordError = 0x0418
    case clientErrorDocumentPermissionError = 0x0419
    case clientErrorDocumentSecurityError = 0x041A
    case clientErrorDocumentUnprintableError = 0x041B
    case clientErrorAccountInfoNeeded = 0x041C
    case clientErrorAccountClosed = 0x041D
    case clientErrorAccountLimitReached = 0x041E
    case clientErrorAccountAuthorizationFailed = 0x041F
    case clientErrorNotFetchable = 0x0420

    case serverErrorInternalError = 0x0500
    case serverErrorOperationNotSupported = 0x0501
    case serverErrorServiceUnavailable = 0x0502
    case serverErrorVersionNotSupported = 0x0503
    case serverErrorDeviceError = 0x0504
    case serverErrorTemporaryError = 0x0505
    case serverErrorNotAcceptingJobs = 0x0506
    case serverErrorBusy = 0x0507
    case serverErrorJobCanceled = 0x0508
    case serverErrorMultipleDocumentJobsNotSupported = 0x0509
    case serverErrorPrinterIsDeactivated = 0x050A
    case serverErrorTooManyJobs = 0x050B
    case serverErrorTooManyDocuments = 0x050C
}

public enum IppStatuses {
    /// The keyword of a status code ("client-error-not-found"), or its number ("0x0421") for one not listed.
    public static func name(_ code: UInt16) -> String {
        guard let status = IppStatus(rawValue: code) else { return String(format: "0x%04X", Int(code)) }
        var keyword = ""
        for character in String(describing: status) {
            if character.isUppercase && !keyword.isEmpty { keyword += "-" }
            keyword += character.lowercased()
        }
        return keyword
    }
}
