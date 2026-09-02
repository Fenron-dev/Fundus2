import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';

/// Downloads and offline copies.
///
/// Offline is a state of a work, not a separate holding: what shows up here is
/// the same catalogue filtered to `offline gesichert`. The four sections of
/// the design — running, queued, available, incomplete — arrive with the
/// network slice; until then this lists what is already local.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final offline = scope.library.works
        .where((work) => work.origin == FundusOrigin.offline)
        .toList(growable: false);

    if (offline.isEmpty) {
      return const FundusEmptyState(
        title: 'Nichts heruntergeladen',
        reason:
            'Offline gesicherte Werke erscheinen hier, sobald eine gekoppelte '
            'Quelle Inhalte für unterwegs bereitstellt.',
        icon: null,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        for (final work in offline)
          ListTile(
            leading: FundusOriginMark(work.origin),
            title: Text(work.title),
            subtitle: Text(work.subtitle),
          ),
      ],
    );
  }
}
