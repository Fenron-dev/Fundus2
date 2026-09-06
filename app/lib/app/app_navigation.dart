import 'package:flutter/foundation.dart';

import '../features/library/shelf_sections.dart';

/// Where the content column currently is.
///
/// Screens are values, not widget subtrees: the shell stays put, the content
/// column swaps. That is what lets the navigation column keep its two states
/// (full and collapsed) without either of them becoming a second design.
@immutable
sealed class FundusRoute {
  const FundusRoute();
}

/// Choosing which vault to open. The only screen shown without one.
final class VaultRoute extends FundusRoute {
  const VaultRoute();
}

final class DashboardRoute extends FundusRoute {
  const DashboardRoute();
}

final class LibraryRoute extends FundusRoute {
  const LibraryRoute({
    this.mediaTypeId,
    this.group,
    this.subgroup,
    this.section,
  });

  /// Null shows everything the vault holds.
  final String? mediaTypeId;

  /// A group the user descended into — a folder, a series, a system.
  final String? group;

  /// A second step below it.
  ///
  /// „Urheber" is the one grouping with a level under it that is worth
  /// walking: an author's shelf is series and single books, and a series is
  /// its volumes in order. Everywhere else this stays null.
  final String? subgroup;

  /// Eine der Reihen von der Bühne, ganz statt angeschnitten.
  ///
  /// Die Überschrift einer Reihe ist ein Versprechen: „Zuletzt hinzugefügt"
  /// heißt, dass es mehr davon gibt als die zwanzig, die nebeneinander
  /// passen. Sie führt hierher.
  final ShelfSection? section;

  LibraryRoute withGroup(String? value) =>
      LibraryRoute(mediaTypeId: mediaTypeId, group: value);
}

final class WorkRoute extends FundusRoute {
  const WorkRoute(this.workId);

  final String workId;
}

final class SearchRoute extends FundusRoute {
  const SearchRoute();
}

final class SettingsRoute extends FundusRoute {
  const SettingsRoute({this.category});

  /// Null is the overview of all areas. A phone lands there — with no
  /// permanent column, an area picked for the person is an area they cannot
  /// leave.
  final String? category;
}

final class DownloadsRoute extends FundusRoute {
  const DownloadsRoute();
}

/// Alle Listen — Playlisten wie Leselisten.
final class ListsRoute extends FundusRoute {
  const ListsRoute();
}

/// Eine einzelne Liste, mit dem, was in ihr steht.
final class ListRoute extends FundusRoute {
  const ListRoute(this.playlistId);

  final String playlistId;
}

/// The navigation history, with the back and forward arrows the header shows.
class AppNavigation extends ChangeNotifier {
  AppNavigation({FundusRoute initial = const VaultRoute()})
    : _history = [initial];

  final List<FundusRoute> _history;
  int _index = 0;

  FundusRoute get current => _history[_index];
  bool get canGoBack => _index > 0;
  bool get canGoForward => _index < _history.length - 1;

  /// True while no vault is open — the shell hides its chrome then.
  bool get isVaultSelection => current is VaultRoute;

  void go(FundusRoute route) {
    if (_index < _history.length - 1) {
      _history.removeRange(_index + 1, _history.length);
    }
    _history.add(route);
    _index = _history.length - 1;
    notifyListeners();
  }

  /// Replaces the whole history — used when a vault opens or closes, where
  /// keeping the previous vault's screens would only mislead.
  void reset(FundusRoute route) {
    _history
      ..clear()
      ..add(route);
    _index = 0;
    notifyListeners();
  }

  void back() {
    if (!canGoBack) return;
    _index--;
    notifyListeners();
  }

  void forward() {
    if (!canGoForward) return;
    _index++;
    notifyListeners();
  }
}
