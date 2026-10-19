import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'archive_motion.dart';
import 'library_reflow.dart';

/// A retained browsing pane and an independently selected detail pane. Reading
/// still uses the root navigator, so a book opens across the whole window.
class LibraryWorkspace extends StatefulWidget {
  const LibraryWorkspace({
    super.key,
    required this.child,
    this.reduceMotion = false,
  });
  final Widget child;
  final bool reduceMotion;

  static bool open(
    BuildContext context,
    Object identity,
    WidgetBuilder builder,
  ) {
    final scope = context.getInheritedWidgetOfExactType<_WorkspaceScope>();
    if (scope == null || !scope.enabled) return false;
    scope.owner.open(identity, builder);
    return true;
  }

  static bool close(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_WorkspaceScope>();
    if (scope?.owner._detail == null) return false;
    scope!.owner.close();
    return true;
  }

  @override
  State<LibraryWorkspace> createState() => _LibraryWorkspaceState();
}

class _LibraryWorkspaceState extends State<LibraryWorkspace>
    with SingleTickerProviderStateMixin {
  Object? _identity;
  WidgetBuilder? _detail;
  bool _closing = false;
  int _transition = 0;
  late final AnimationController _motion;
  late final Animation<double> _detailMotion;
  final _reflow = LibraryReflowController();
  @override
  void initState() {
    super.initState();
    _motion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 420),
          reverseDuration: const Duration(milliseconds: 280),
        )..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && _closing && mounted) {
            setState(() {
              _reflow.finish();
              _detail = null;
              _identity = null;
              _closing = false;
            });
          } else if (status == AnimationStatus.completed &&
              _reflow.active &&
              mounted) {
            setState(_reflow.finish);
          }
        });
    _detailMotion = CurvedAnimation(
      parent: _motion,
      curve: Curves.linear,
      reverseCurve: Curves.easeInCubic,
    );
  }

  void open(Object identity, WidgetBuilder builder) {
    if (_identity == identity && !_closing) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final reduced =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    if (!reduced && (_detail == null || _closing)) _reflow.begin(_motion);
    setState(() {
      _identity = identity;
      _detail = builder;
      _closing = false;
    });
    final ticket = ++_transition;
    if (reduced) {
      _motion.value = 1;
    } else {
      _motion.value = 0;
      // Prepare the new pane constraints before starting the composited move.
      // A cold directory/layout must not consume the first animation interval.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ticket == _transition && !_closing) _motion.forward();
      });
    }
  }

  void close() {
    if (_closing) return;
    _transition++;
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _detail = null;
        _identity = null;
      });
    } else {
      _reflow.begin(ReverseAnimation(_motion));
      setState(() => _closing = true);
      final ticket = _transition;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _closing && ticket == _transition) _motion.reverse();
      });
    }
  }

  @override
  void dispose() {
    _reflow.dispose();
    (_detailMotion as CurvedAnimation).dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1000 && constraints.maxHeight >= 500;
      final selected = _detail != null;
      final total = math.min(
        constraints.maxWidth,
        selected && wide ? 1440.0 : 1200.0,
      );
      final split = (total - 24) / 2;
      final master = selected && wide && !_closing
          ? split
          : math.min(total, 1200.0);
      final masterLeft = _closing && wide ? (total - master) / 2 : 0.0;
      // The browsing element keeps the same parent/identity on select, close and
      // resize. Only its constraints change once; no list reflow on motion ticks.
      return _WorkspaceScope(
        owner: this,
        enabled: wide,
        child: PopScope<void>(
          canPop: !selected,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selected) close();
          },
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: SizedBox(
                width: total,
                child: Stack(
                  children: [
                    Positioned(
                      key: const ValueKey('library-master-pane'),
                      left: masterLeft,
                      top: 0,
                      bottom: 0,
                      width: master,
                      child: Offstage(
                        offstage: selected && !wide,
                        child: TickerMode(
                          enabled: !selected || wide,
                          child: ExcludeFocus(
                            excluding: selected && !wide,
                            child: LibraryReflowScope(
                              controller: _reflow,
                              enabled:
                                  wide &&
                                  !widget.reduceMotion &&
                                  !MediaQuery.disableAnimationsOf(context),
                              active: _reflow.active,
                              generation: _reflow.generation,
                              child: IgnorePointer(
                                ignoring: _reflow.active,
                                child: LibraryReflowClip(
                                  controller: _reflow,
                                  child: RepaintBoundary(
                                    key: const ValueKey(
                                      'library-master-content',
                                    ),
                                    child: _PaneMedia(child: widget.child),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        key: const ValueKey('library-detail-pane'),
                        left: wide ? split + 24 : 0,
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: _PaneMedia(
                          child: IgnorePointer(
                            ignoring: _closing,
                            child: AnimatedBuilder(
                              animation: _reflow,
                              builder: (_, child) => FractionalTranslation(
                                translation: Offset(
                                  _closing ? _reflow.progress : 0,
                                  0,
                                ),
                                child: child,
                              ),
                              child: ArchivePlaneTransition(
                                animation: _closing
                                    ? const AlwaysStoppedAnimation(1)
                                    : _detailMotion,
                                child: RepaintBoundary(
                                  key: const ValueKey('library-detail-content'),
                                  child: HeroMode(
                                    enabled: false,
                                    child: KeyedSubtree(
                                      key: ValueKey(_identity),
                                      child: Builder(builder: _detail!),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _WorkspaceScope extends InheritedWidget {
  const _WorkspaceScope({
    required this.owner,
    required this.enabled,
    required super.child,
  });
  final _LibraryWorkspaceState owner;
  final bool enabled;
  @override
  bool updateShouldNotify(_WorkspaceScope oldWidget) =>
      enabled != oldWidget.enabled;
}

class _PaneMedia extends StatelessWidget {
  const _PaneMedia({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: constraints.biggest),
      child: child,
    ),
  );
}
