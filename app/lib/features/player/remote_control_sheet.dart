import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_design/fundus_design.dart';

/// Starts [workId] on a paired machine and shows a remote for its player.
Future<void> playOnPeer(
  BuildContext context, {
  required FundusRemoteClient client,
  required String peerName,
  required String libraryId,
  required String workId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await client.remotePlay(libraryId: libraryId, workId: workId);
  } on FundusRemoteException catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          error.statusCode == 403
              ? 'Auf „$peerName“ ist die Fernbedienung für dieses Gerät nicht '
                    'erlaubt. Dort unter Geräte & Abgleich einschalten.'
              : '„$peerName“ konnte das Werk nicht starten.',
        ),
      ),
    );
    return;
  } on Object {
    messenger?.showSnackBar(
      SnackBar(content: Text('„$peerName“ ist gerade nicht erreichbar.')),
    );
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        _RemoteControlSheet(client: client, peerName: peerName),
  );
}

class _RemoteControlSheet extends StatefulWidget {
  const _RemoteControlSheet({required this.client, required this.peerName});

  final FundusRemoteClient client;
  final String peerName;

  @override
  State<_RemoteControlSheet> createState() => _RemoteControlSheetState();
}

class _RemoteControlSheetState extends State<_RemoteControlSheet> {
  RemotePlayerState? _state;
  String? _problem;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // Two seconds is close enough to live for a position, and far from a
    // flood of requests while the sheet is open.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final state = await widget.client.remotePlayerState();
      if (mounted) {
        setState(() {
          _state = state;
          _problem = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _problem = '„${widget.peerName}“ antwortet nicht.');
      }
    }
  }

  Future<void> _send(String action, {Duration? position}) async {
    try {
      await widget.client.remoteCommand(action, position: position);
    } on Object {
      if (mounted) {
        setState(() => _problem = 'Der Befehl kam nicht an.');
      }
    }
    await _refresh();
  }

  static String _time(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final state = _state;
    final duration = state?.duration;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FundusSpace.x8,
          0,
          FundusSpace.x8,
          FundusSpace.x8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Läuft auf „${widget.peerName}“',
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            Text(
              state == null
                  ? 'Verbinde …'
                  : state.idle
                  ? 'Gerade läuft dort nichts.'
                  : state.private
                  ? 'Wiedergabe läuft'
                  : state.title ?? 'Wiedergabe läuft',
              style: theme.textTheme.titleLarge,
            ),
            if (state?.trackTitle case final track? when !state!.private)
              Text(
                track,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
            if (state != null && !state.idle && duration != null) ...[
              const SizedBox(height: FundusSpace.x4),
              Slider(
                value: state.position.inMilliseconds
                    .clamp(0, duration.inMilliseconds)
                    .toDouble(),
                max: duration.inMilliseconds.toDouble().clamp(
                  1,
                  double.infinity,
                ),
                onChanged: null,
                onChangeEnd: null,
              ),
              Row(
                children: [
                  Text(_time(state.position)),
                  const Spacer(),
                  Text(_time(duration)),
                ],
              ),
            ],
            const SizedBox(height: FundusSpace.x3),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Zurück springen',
                  onPressed: state == null || state.idle
                      ? null
                      : () => _send('skip_backward'),
                  icon: Icon(FundusIcons.skipBack, size: FundusIcons.sizeLg),
                ),
                const SizedBox(width: FundusSpace.x6),
                IconButton.filled(
                  tooltip: state?.playing == true ? 'Anhalten' : 'Abspielen',
                  onPressed: state == null || state.idle
                      ? null
                      : () => _send(state.playing ? 'pause' : 'resume'),
                  icon: Icon(
                    state?.playing == true
                        ? FundusIcons.pause
                        : FundusIcons.play,
                    size: FundusIcons.sizeLg,
                  ),
                ),
                const SizedBox(width: FundusSpace.x6),
                IconButton(
                  tooltip: 'Vor springen',
                  onPressed: state == null || state.idle
                      ? null
                      : () => _send('skip_forward'),
                  icon: Icon(FundusIcons.skipForward, size: FundusIcons.sizeLg),
                ),
              ],
            ),
            if (_problem case final problem?) ...[
              const SizedBox(height: FundusSpace.x2),
              Text(
                problem,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.danger,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
