/// Which bridge a user id belongs to: the appservice namespace is the only tell.
library;

import '../ui/model/models.dart';

/// OOYE's namespace on loaf.moe.
const _ooye = '@_ooye_';

Bridge? bridgeOf(String userId) =>
    userId.startsWith(_ooye) ? Bridge.discord : null;
