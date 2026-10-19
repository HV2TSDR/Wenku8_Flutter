import 'package:flutter/widgets.dart';

import 'publication_catalog.dart';
import 'wenku_account.dart';
import 'wenku_shelf_sync.dart';

class WenkuFeatures {
  const WenkuFeatures({
    required this.account,
    required this.publications,
    this.shelfSync,
  });
  final WenkuAccount account;
  final PublicationCatalog publications;
  final WenkuShelfSync? shelfSync;
}

/// Capabilities are injected once, not subscribed at the application root.
class WenkuFeaturesScope extends InheritedWidget {
  const WenkuFeaturesScope({
    super.key,
    required this.features,
    required super.child,
  });
  final WenkuFeatures? features;
  static WenkuFeatures? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WenkuFeaturesScope>()
      ?.features;
  @override
  bool updateShouldNotify(WenkuFeaturesScope oldWidget) =>
      features != oldWidget.features;
}
