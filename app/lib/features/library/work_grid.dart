import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import 'work_poster.dart';

/// Works as posters, in as many columns as the window allows.
///
/// One grid for the library, the search and anything else that shows a pile
/// of works: the column count comes from the poster width for this screen
/// size, so a phone, a tablet and a desktop differ by one number rather than
/// by three implementations.
class WorkGrid extends StatelessWidget {
  const WorkGrid({
    super.key,
    required this.works,
    required this.onOpen,
    this.padding,
  });

  final List<WorkView> works;
  final void Function(WorkView) onOpen;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final stage = FundusStageSize.of(context);
    final compact = context.fundus.density == FundusDensity.compact;
    final target = compact ? stage.posterWidth * .78 : stage.posterWidth;
    final margin =
        padding ??
        EdgeInsets.fromLTRB(
          stage.gutter,
          FundusSpace.x4,
          stage.gutter,
          FundusSpace.x16,
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - margin.horizontal;
        final columns = ((available + stage.railGap) / (target + stage.railGap))
            .floor()
            .clamp(2, 12);
        final width = (available - stage.railGap * (columns - 1)) / columns;

        // A grid of thousands has to be virtualised; GridView.builder only
        // builds what is on screen.
        return GridView.builder(
          padding: margin,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: FundusSpace.x6,
            crossAxisSpacing: stage.railGap,
            mainAxisExtent: workPosterExtent(
              width: width,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
          itemCount: works.length,
          itemBuilder: (context, index) => WorkPoster(
            work: works[index],
            width: width,
            onTap: () => onOpen(works[index]),
          ),
        );
      },
    );
  }
}
