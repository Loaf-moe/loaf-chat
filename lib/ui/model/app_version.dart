/// Which release this copy is, as the about section shows it.
library;

/// The release pipeline passes `--dart-define=LOAF_VERSION=<tag, minus v>`.
/// Empty means a build made by hand.
const appVersion = String.fromEnvironment('LOAF_VERSION');
