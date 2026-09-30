/// What this build is, and where it looks for the next one.
library;

/// The release pipeline passes `--dart-define=LOAF_BUILD=<commit count>`.
/// Zero means a build made by hand, which nothing updates.
const buildNumber = int.fromEnvironment('LOAF_BUILD');

final latestFeed = Uri.parse('https://get.loaf.moe/latest.json');

/// The release key's public half. Its private half signs `latest.json` in
/// CI; see tool/release/keygen.sh.
const appImagePublicKey = 'pkPvo7yx06M9su5PnOilqBnM2okapgEXH3B1e6BY+bo=';
