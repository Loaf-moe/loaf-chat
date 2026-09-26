/// Fixtures for sign-in and verification: the homeservers the mock knows,
/// and this account's secrets.
///
/// To try the flows by hand, type one of [mockServers]' names into the
/// server picker, and sign in with any password except [mockWrongPassword].
/// Unlock with [mockRecoveryKey] or [mockRecoveryPassphrase].
library;

import '../auth/sign_in_state.dart';
import '../platform.dart';
import '../verify/verify_state.dart';

/// loaf.moe delegates SSO to Kanidm and names it after itself.
const loafMoeProvider = IdentityProvider('kanidm', 'loaf.moe');

/// One server per face the sign-in screen has to get right. Any other name
/// answers nothing.
const mockServers = <String, ServerCheck>{
  'loaf.moe': ServerFound(
    ServerFlows(providers: [loafMoeProvider], password: true),
  ),
  'many-doors.test': ServerFound(
    ServerFlows(
      providers: [
        IdentityProvider('oidc-github', 'GitHub'),
        IdentityProvider('oidc-google', 'Google'),
        IdentityProvider('oidc-gitlab', 'GitLab'),
        IdentityProvider('oidc-apple', 'Apple'),
      ],
      password: true,
    ),
  ),
  'sso-only.test': ServerFound(
    ServerFlows(providers: [IdentityProvider('oidc', 'Authentik')]),
  ),
  'passwords.test': ServerFound(ServerFlows(password: true)),
  'example.com': ServerFailed(ServerProblem.notMatrix),
  'broken.test': ServerFailed(
    ServerProblem.delegationBroken,
    delegatedTo: 'matrix.broken.test',
  ),
  'quiet.test': ServerFailed(ServerProblem.noSignInInfo),
};

/// The one password the mock homeserver turns away (`M_FORBIDDEN`).
const mockWrongPassword = 'wrong';

/// This account's other sessions, which "use another device" can ask. The
/// device you are on is never among them.
List<String> mockOtherSessions() => [
  isDesktop ? "faore's iPhone" : "faore's MacBook",
  'Element on Pixel',
];

/// The device the "new sign-in" lever pretends is asking: whichever kind
/// this one isn't.
String mockNewDevice() => isDesktop ? 'loaf on iPhone' : 'loaf on MacBook';

/// The account's recovery key: base58, 12 groups of four.
const mockRecoveryKey =
    'EsTc 5rr9 Tj3W 8ZkN oAYy 1mfA hKbu m2Cq 6ZMy F8Ws dNvf cDbu';

/// The passphrase protecting the same secret storage, made in another client.
const mockRecoveryPassphrase = 'bread before breakfast';

/// What setting up recovery (or a reset) generates.
const mockNewRecoveryKey =
    'EsU1 kP4q 9dXz Rw2m Hn7b Vt3c Yf8g Ja5s Lk6e Qx4r Zu9w Mh2p';

/// Room keys in key backup, for the restore count.
const mockBackupKeys = 3380;

const mockSasEmoji = [
  SasEmoji('🐶', 'dog'),
  SasEmoji('🍕', 'pizza'),
  SasEmoji('🚀', 'rocket'),
  SasEmoji('🔑', 'key'),
  SasEmoji('🌵', 'cactus'),
  SasEmoji('🎸', 'guitar'),
  SasEmoji('☂️', 'umbrella'),
];

/// Whether [text] opens secret storage: the recovery key however it was
/// spaced, wrapped or pasted, or the passphrase.
bool unlocksRecovery(String text) {
  final squashed = text.replaceAll(RegExp(r'\s'), '');
  return squashed == mockRecoveryKey.replaceAll(' ', '') ||
      text.trim() == mockRecoveryPassphrase;
}
