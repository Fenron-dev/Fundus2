import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import 'work_grid.dart';

/// Searching, on a screen of its own.
///
/// There was no way to search on a phone at all: the field lived in the
/// desktop header, which the compact shell does not have. It is its own place
/// now, reached from the bottom bar, with the field where a thumb is and the
/// shelves underneath as a way in when nothing has been typed yet.
///
/// What it filters is the ordinary view filter, so a search carries over into
/// the library rather than being a second, parallel idea of "what is shown".
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final text = FundusScope.of(context).filter.text;
    if (_controller.text != text) _controller.text = text;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final stage = FundusStageSize.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final query = scope.filter.text.trim();
    final hits = query.isEmpty
        ? const <WorkView>[]
        : scope.filter.apply(scope.library.works);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            stage.gutter,
            FundusSpace.x4,
            stage.gutter,
            FundusSpace.x3,
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onChanged: (value) =>
                scope.setFilter(scope.filter.copyWith(text: value)),
            decoration: InputDecoration(
              hintText: 'Titel, Urheber, Reihe …',
              filled: true,
              fillColor: tokens.surface,
              border: const OutlineInputBorder(
                borderRadius: FundusArtwork.cardRadius,
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: FundusArtwork.cardRadius,
                borderSide: BorderSide.none,
              ),
              prefixIcon: Icon(FundusIcons.search, size: FundusIcons.sizeMd),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _controller.clear();
                        scope.setFilter(scope.filter.copyWith(text: ''));
                      },
                      icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
                      tooltip: 'Leeren',
                    ),
            ),
          ),
        ),
        if (query.isEmpty)
          Expanded(child: _Shelves(stage: stage))
        else if (hits.isEmpty)
          Expanded(
            child: FundusEmptyState(
              icon: FundusIcons.search,
              title: 'Nichts gefunden',
              reason:
                  'Für „$query" gibt es in dieser Bibliothek keinen Treffer.',
            ),
          )
        else ...[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: stage.gutter),
            child: Text(
              hits.length == 1 ? 'Ein Treffer' : '${hits.length} Treffer',
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ),
          Expanded(
            child: WorkGrid(
              works: hits,
              onOpen: (work) => scope.navigation.go(WorkRoute(work.id)),
            ),
          ),
        ],
      ],
    );
  }
}

/// Where to go when nothing has been typed yet.
class _Shelves extends StatelessWidget {
  const _Shelves({required this.stage});

  final FundusStageSize stage;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final counts = scope.library.worksPerMediaType;
    final types = [
      for (final type in MediaTypes.all)
        if ((counts[type.id] ?? 0) > 0) type,
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(
        stage.gutter,
        FundusSpace.x3,
        stage.gutter,
        FundusSpace.x16,
      ),
      children: [
        Text('Durchsuchen', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x3),
        Wrap(
          spacing: FundusSpace.x2,
          runSpacing: FundusSpace.x2,
          children: [
            for (final type in types)
              ActionChip(
                avatar: Icon(type.icon, size: FundusIcons.sizeSm),
                label: Text('${type.label} · ${counts[type.id]}'),
                onPressed: () => scope.openMediaType(type.id),
              ),
          ],
        ),
      ],
    );
  }
}
