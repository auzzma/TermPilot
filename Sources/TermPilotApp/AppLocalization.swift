import Foundation
import SwiftUI
import TermPilotDomain
import TermPilotRemote

enum AppLocalization {
    static func string(_ key: String) -> String {
        let language = AppPreferences.normalizedLanguage(
            UserDefaults.standard.string(forKey: AppPreferences.language)
                ?? AppPreferences.defaultLanguage
        )
        let bundle = AppResourceLocator.localizedBundle(for: language)
        return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
    }

    static func errorDescription(_ error: any Error) -> String {
        switch error {
        case PortForwardValidationError.missingName:
            string("Forward name is required.")
        case PortForwardValidationError.invalidLocalPort:
            string("Local port must be between 1 and 65535.")
        case PortForwardValidationError.invalidRemoteHost:
            string("Remote host is required.")
        case PortForwardValidationError.invalidRemotePort:
            string("Remote port must be between 1 and 65535.")
        case ProductivityValidationError.missingTitle:
            string("Title is required.")
        case ProductivityValidationError.missingShell:
            string("Shell is required.")
        case AppStateError.invalidHost:
            string("Choose a saved host before starting this workflow.")
        case AppStateError.notReady:
            string("TermPilot is still starting.")
        case AppStateError.invalidSession:
            string("The saved session is missing its connection details.")
        case AppStateError.invalidCredential:
            string("The selected credential no longer exists.")
        case AppStateError.invalidProxyProfile:
            string("The selected proxy no longer exists.")
        case AppStateError.invalidProxyCredential:
            string("The selected proxy credential must contain a username and password.")
        case AppStateError.invalidGroup:
            string("The selected group no longer exists.")
        case AppStateError.missingProxyBridge:
            string("The TermPilot proxy helper is missing from the app bundle.")
        case AppStateError.missingSFTPBridge:
            string("The TermPilot SFTP bridge helper is missing from the app bundle.")
        case AppStateError.missingSSH2Bridge:
            string("The TermPilot ssh2 bridge helper is missing from the app bundle.")
        case AppStateError.missingCredentialKeyGenerator:
            string("The TermPilot SSH key generator is missing from the app bundle.")
        case AppStateError.missingSSH2BridgeRuntime:
            string("The bundled TermPilot ssh2 bridge runtime is missing. Rebuild the app with scripts/build-app.sh.")
        case let AppStateError.workflowRunFailed(message):
            message
        case QuickConnectFormError.missingPassword:
            string("Enter the SSH password.")
        case QuickConnectError.empty:
            string("Enter a host to connect.")
        case QuickConnectError.invalidFormat:
            string("Use user@host, user@host:port, or ssh://user@host:port.")
        case QuickConnectError.missingUsername:
            string("Include the SSH username.")
        case QuickConnectError.invalidPort:
            string("Port must be between 1 and 65535.")
        case HostValidationError.missingLabel:
            string("Host name is required.")
        case HostValidationError.invalidHostname:
            string("Enter a valid hostname or IP address.")
        case HostValidationError.invalidPort:
            string("Port must be between 1 and 65535.")
        case HostValidationError.missingUsername:
            string("Username is required.")
        case HostValidationError.missingIdentityFile:
            string("Select a private key file.")
        case CredentialValidationError.missingLabel:
            string("Credential label is required.")
        case CredentialValidationError.missingUsername:
            string("Credential username is required.")
        case CredentialValidationError.missingPassword:
            string("Credential password is required.")
        case CredentialValidationError.missingPrivateKey:
            string("Private key content is required.")
        case SSHCredentialKeyError.invalidECDSABits:
            string("ECDSA bits must be 256, 384, or 521.")
        case SSHCredentialKeyError.invalidRSABits:
            string("RSA bits must be 1024, 2048, or 4096.")
        case SSHCredentialKeyError.invalidPublicKey:
            string("The credential does not contain a valid SSH public key.")
        case SSHCredentialKeyError.invalidGeneratorResponse:
            string("The SSH key generator returned invalid data.")
        case SSHCredentialKeyError.generationFailed(let message),
             SSHCredentialKeyError.remoteInstallFailed(let message):
            message
        case SSHCredentialKeyError.keyAuthenticationRejected:
            string("The public key was installed, but the server rejected key authentication. The host's original login configuration was preserved.")
        case SSHProxyValidationError.missingLabel:
            string("Proxy name is required.")
        case SSHProxyValidationError.invalidHost:
            string("Enter a valid proxy host.")
        case SSHProxyValidationError.invalidPort:
            string("Proxy port must be between 1 and 65535.")
        case SSHProxyValidationError.missingCommand:
            string("ProxyCommand is required.")
        case SSHConfigurationError.missingIdentityFile:
            string("The selected host has no private key file.")
        case SSHConfigurationError.unsafeHostname:
            string("Hostnames beginning with a dash are not allowed.")
        case SSH2SFTPBridgeError.closed:
            string("The SFTP bridge is closed.")
        case let SSH2SFTPBridgeError.remote(message):
            string(message)
        default:
            string(error.localizedDescription)
        }
    }
}

extension PortForwardKind {
    var appLocalizedTitleKey: LocalizedStringKey {
        switch self {
        case .local:
            "Local"
        case .remote:
            "Remote"
        case .dynamic:
            "Dynamic"
        }
    }

    var appLocalizedTitle: String {
        AppLocalization.string(appLocalizationKey)
    }

    var appLocalizedDescriptionKey: LocalizedStringKey {
        switch self {
        case .local:
            "Port Forward Local Description"
        case .remote:
            "Port Forward Remote Description"
        case .dynamic:
            "Port Forward Dynamic Description"
        }
    }

    private var appLocalizationKey: String {
        switch self {
        case .local:
            "Local"
        case .remote:
            "Remote"
        case .dynamic:
            "Dynamic"
        }
    }
}

extension PortForwardStatus {
    var appLocalizedTitle: String {
        AppLocalization.string(appLocalizationKey)
    }

    private var appLocalizationKey: String {
        switch self {
        case .inactive:
            "Inactive"
        case .connecting:
            "Connecting"
        case .active:
            "Active"
        case .error:
            "Error"
        }
    }
}

extension SSHCredentialKind {
    var appLocalizedTitle: String {
        switch self {
        case .password:
            AppLocalization.string("Password")
        case .identityKey:
            AppLocalization.string("Private Key")
        }
    }
}
