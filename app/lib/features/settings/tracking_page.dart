import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/fundus_scope.dart';
import '../../data/tracking_controller.dart';
import '../../metadata/tracking_services.dart';
import 'settings_shell.dart';

/// Connecting AniList, MyAnimeList and Trakt.
///
/// Each one needs its own free client registration; Fundus ships no keys of
/// its own, so nobody's account depends on one that could be revoked. No
/// sign-in listens on a local port: AniList shows its token on a page,
/// MyAnimeList's address is pasted back, Trakt asks for a typed code.
class TrackingPage extends StatelessWidget {
  const TrackingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tracking = scope.tracking;
    final theme = Theme.of(context);
    return SettingsPage(
      title: 'Fortschritt melden',
      subtitle:
          'Fundus kann AniList, MyAnimeList und Trakt sagen, was du gesehen '
          'und gelesen hast — ab dem Verbinden, nie rückwirkend, und nie für '
          'geschützte Werke. Gemeldet wird, wo das Werk mit dem Dienst '
          'verknüpft ist.',
      children: [
        if (tracking.lastProblem case final problem?)
          SettingsCard(
            child: Text(
              problem,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: context.fundus.danger,
              ),
            ),
          ),
        const _AniListCard(),
        const _MalCard(),
        const _TraktCard(),
        if (TrackingController.services.any(tracking.isConnected))
          SettingsCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tracking.pending == 0
                        ? 'Alles gemeldet.'
                        : '${tracking.pending} Meldungen warten auf Verbindung.',
                  ),
                ),
                OutlinedButton(
                  onPressed: tracking.isRunning ? null : tracking.reconcile,
                  child: const Text('Jetzt abgleichen'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ConnectedRow extends StatelessWidget {
  const _ConnectedRow({required this.service, required this.label});

  final String service;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tracking = FundusScope.of(context).tracking;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (tracking.isConnected(service)) ...[
          const FundusTag('verbunden'),
          const SizedBox(width: FundusSpace.x3),
          TextButton(
            onPressed: () => tracking.disconnect(service),
            child: const Text('Trennen'),
          ),
        ] else
          const FundusTag('nicht verbunden'),
      ],
    );
  }
}

class _AniListCard extends StatefulWidget {
  const _AniListCard();

  @override
  State<_AniListCard> createState() => _AniListCardState();
}

class _AniListCardState extends State<_AniListCard> {
  final _client = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    _client.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracking = FundusScope.of(context).tracking;
    final theme = Theme.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ConnectedRow(service: 'anilist', label: 'AniList'),
          if (!tracking.isConnected('anilist')) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              'Unter anilist.co → Einstellungen → Developer einen Client '
              'anlegen, als Weiterleitung '
              'https://anilist.co/api/v2/oauth/pin eintragen.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: FundusSpace.x3),
            TextField(
              controller: _client,
              decoration: const InputDecoration(
                labelText: 'Client-ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            OutlinedButton(
              onPressed: () {
                final id = _client.text.trim();
                if (id.isEmpty) return;
                unawaited(launchUrl(AniListTracker.authorizeUrl(id)));
              },
              child: const Text('Bei AniList anmelden'),
            ),
            const SizedBox(height: FundusSpace.x3),
            TextField(
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Angezeigtes Token einfügen',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            FilledButton(
              onPressed: () async {
                final token = _token.text.trim();
                if (token.length < 20) return;
                await tracking.connect('anilist', {
                  'client_id': _client.text.trim(),
                  'token': token,
                });
                _token.clear();
              },
              child: const Text('Verbinden'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MalCard extends StatefulWidget {
  const _MalCard();

  @override
  State<_MalCard> createState() => _MalCardState();
}

class _MalCardState extends State<_MalCard> {
  final _address = TextEditingController();
  String? _verifier;
  String? _state;
  String? _problem;
  bool _working = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _complete(String clientId) async {
    final verifier = _verifier;
    final state = _state;
    if (verifier == null || state == null) return;
    final code = MalTracker.codeFrom(_address.text, state: state);
    if (code == null) {
      setState(() => _problem = 'In der Adresse steht kein gültiger Code.');
      return;
    }
    setState(() => _working = true);
    try {
      final tokens = await MalTracker.exchange(
        clientId: clientId,
        code: code,
        verifier: verifier,
      );
      if (!mounted) return;
      await FundusScope.of(
        context,
      ).tracking.connect('mal', {'client_id': clientId, ...tokens});
      _address.clear();
      setState(() {
        _verifier = null;
        _problem = null;
      });
    } on Object {
      if (mounted) {
        setState(() => _problem = 'MyAnimeList hat die Anmeldung abgelehnt.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tracking = scope.tracking;
    final clientId = scope.settings.malClientId;
    final theme = Theme.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ConnectedRow(service: 'mal', label: 'MyAnimeList'),
          if (!tracking.isConnected('mal')) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              clientId.isEmpty
                  ? 'Zuerst unter „Metadaten & Quellen" die '
                        'MyAnimeList-Client-ID hinterlegen.'
                  : 'Nach der Anmeldung landet der Browser auf der '
                        'Weiterleitungsadresse deines MAL-Clients. Diese '
                        'Adresse komplett kopieren und hier einfügen.',
              style: theme.textTheme.bodySmall,
            ),
            if (clientId.isNotEmpty) ...[
              const SizedBox(height: FundusSpace.x3),
              OutlinedButton(
                onPressed: () {
                  final verifier = MalTracker.newVerifier();
                  final state = MalTracker.newVerifier().substring(0, 24);
                  setState(() {
                    _verifier = verifier;
                    _state = state;
                    _problem = null;
                  });
                  unawaited(
                    launchUrl(
                      MalTracker.authorizeUrl(
                        clientId: clientId,
                        verifier: verifier,
                        state: state,
                      ),
                    ),
                  );
                },
                child: const Text('Bei MyAnimeList anmelden'),
              ),
              if (_verifier != null) ...[
                const SizedBox(height: FundusSpace.x3),
                TextField(
                  controller: _address,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Adresse nach der Anmeldung',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: FundusSpace.x2),
                FilledButton(
                  onPressed: _working ? null : () => _complete(clientId),
                  child: const Text('Verbinden'),
                ),
              ],
            ],
            if (_problem case final problem?) ...[
              const SizedBox(height: FundusSpace.x2),
              Text(
                problem,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.fundus.danger,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _TraktCard extends StatefulWidget {
  const _TraktCard();

  @override
  State<_TraktCard> createState() => _TraktCardState();
}

class _TraktCardState extends State<_TraktCard> {
  final _clientId = TextEditingController();
  final _secret = TextEditingController();
  String? _userCode;
  Uri? _url;
  String? _problem;
  bool _waiting = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _clientId.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final clientId = _clientId.text.trim();
    final secret = _secret.text.trim();
    if (clientId.isEmpty || secret.isEmpty) return;
    final tracking = FundusScope.of(context).tracking;
    setState(() {
      _waiting = true;
      _problem = null;
    });
    try {
      final login = await TraktTracker.startDeviceLogin(clientId);
      if (_disposed) return;
      setState(() {
        _userCode = login.userCode;
        _url = login.url;
      });
      final deadline = DateTime.now().add(login.expiresIn);
      while (!_disposed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(login.interval);
        if (_disposed) return;
        final tokens = await TraktTracker.pollDeviceLogin(
          clientId: clientId,
          clientSecret: secret,
          deviceCode: login.deviceCode,
        );
        if (tokens == null) continue;
        await tracking.connect('trakt', {
          'client_id': clientId,
          'client_secret': secret,
          ...tokens,
        });
        _secret.clear();
        if (!_disposed) setState(() => _userCode = null);
        return;
      }
      if (!_disposed) {
        setState(() => _problem = 'Der Code ist abgelaufen. Noch einmal?');
      }
    } on Object {
      if (!_disposed) {
        setState(() => _problem = 'Trakt hat die Anmeldung abgelehnt.');
      }
    } finally {
      if (!_disposed) setState(() => _waiting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracking = FundusScope.of(context).tracking;
    final theme = Theme.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ConnectedRow(service: 'trakt', label: 'Trakt'),
          if (!tracking.isConnected('trakt')) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              'Unter trakt.tv/oauth/applications eine App anlegen '
              '(Weiterleitung: urn:ietf:wg:oauth:2.0:oob) und Client-ID '
              'und Secret hier eintragen. Filme und Serienfolgen werden '
              'als gesehen gemeldet.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: FundusSpace.x3),
            TextField(
              controller: _clientId,
              decoration: const InputDecoration(
                labelText: 'Client-ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            TextField(
              controller: _secret,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Client-Secret',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: FundusSpace.x2),
            FilledButton(
              onPressed: _waiting ? null : _login,
              child: const Text('Bei Trakt anmelden'),
            ),
            if (_userCode case final code?) ...[
              const SizedBox(height: FundusSpace.x3),
              SelectableText(
                'Code: $code',
                style: theme.textTheme.headlineSmall,
              ),
              TextButton(
                onPressed: _url == null ? null : () => launchUrl(_url!),
                child: Text('Auf ${_url?.host ?? 'trakt.tv'} eingeben'),
              ),
            ],
            if (_problem case final problem?)
              Text(
                problem,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.fundus.danger,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
