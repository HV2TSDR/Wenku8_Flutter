import 'dart:math' as math;
import 'package:flutter/cupertino.dart';

import 'app_ui.dart';
import 'native_effects.dart' show NativeGlassGroup;

/// Scroll-edge treatment, mounted only while the reader controls are visible.
class ReaderEdgeBlur extends StatelessWidget {
  const ReaderEdgeBlur({
    super.key,
    this.animation = const AlwaysStoppedAnimation(1),
    this.topInset = 0,
    this.compact = false,
    this.blurBottom = true,
  });
  final Animation<double> animation;
  final double topInset;
  final bool compact, blurBottom;

  @override
  Widget build(BuildContext context) {
    final view = View.of(context);
    final top = math.max(
      MediaQuery.paddingOf(context).top,
      view.viewPadding.top / view.devicePixelRatio,
    );
    final blur = GlassAppearance.of(context).blur;
    final topHeight =
        top +
        topInset +
        FrostedHeader.toolbarHeight +
        (compact ? 24 : FrostedHeader.featherHeight);
    final highContrast = MediaQuery.highContrastOf(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final strength = Curves.easeInOut.transform(animation.value);
        if (strength == 0) return const SizedBox.shrink();
        return IgnorePointer(
          child: Stack(
            children: [
              if (!highContrast)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topHeight,
                  child: ProgressiveBlur(
                    maxSigma: blur * strength,
                    plateauHeight: top,
                  ),
                ),
              if (blurBottom)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height:
                      MediaQuery.viewPaddingOf(context).bottom +
                      (compact ? 32 : 52),
                  child: ProgressiveBlur(
                    maxSigma: math.min(3, blur * .16) * strength,
                    plateauHeight: MediaQuery.viewPaddingOf(context).bottom,
                    fromBottom: true,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Live glass leaves the viewport without an opacity saveLayer. An opacity
/// subpass changes the backdrop's origin/contents on its first partial frame.
/// At zero controls have no paint, hit targets or accessibility focus.
class ReaderChromeLayer extends StatelessWidget {
  const ReaderChromeLayer({
    super.key,
    required this.animation,
    required this.child,
    this.slide = Offset.zero,
    this.paintPadding = EdgeInsets.zero,
  });
  final Animation<double> animation;
  final Widget child;
  final Offset slide;
  final EdgeInsets paintPadding;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) => Offstage(
      offstage: animation.value == 0,
      child: IgnorePointer(
        ignoring: animation.value < .95,
        child: ExcludeSemantics(
          excluding: animation.value < .95,
          child: NativeGlassGroup(
            inherit: false,
            child: ClipRect(
              child: FractionalTranslation(
                translation:
                    slide *
                    (1 - Curves.easeOutCubic.transform(animation.value)),
                child: Padding(padding: paintPadding, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A separate, finite entrance: recovering follow never changes article layout
/// or replays the main reader chrome. Live glass is clipped, not alpha-layered.
class ReaderFollowDock extends StatefulWidget {
  const ReaderFollowDock({
    super.key,
    required this.visible,
    required this.chrome,
    required this.onEnable,
    this.extraControlsHeight = 0,
    this.reduceMotion = false,
  });
  final bool visible;
  final Animation<double> chrome;
  final VoidCallback onEnable;
  final double extraControlsHeight;
  final bool reduceMotion;

  @override
  State<ReaderFollowDock> createState() => _ReaderFollowDockState();
}

class _ReaderFollowDockState extends State<ReaderFollowDock>
    with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: NovelMotion.enter,
    reverseDuration: NovelMotion.exit,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(ReaderFollowDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _entrance.forward();
    } else {
      _entrance.reverse();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.chrome,
    child: IgnorePointer(
      ignoring: !widget.visible,
      child: ReaderChromeLayer(
        animation: _entrance,
        slide: const Offset(0, 1),
        paintPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: GlassTextButton(
          key: const ValueKey('reader-enable-follow'),
          onPressed: widget.onEnable,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.location_fill, size: 17),
              SizedBox(width: 8),
              AppText('开启跟随'),
            ],
          ),
        ),
      ),
    ),
    builder: (context, child) => Padding(
      padding: EdgeInsets.only(
        bottom:
            MediaQuery.viewPaddingOf(context).bottom +
            12 +
            (74 + widget.extraControlsHeight) *
                Curves.easeOutCubic.transform(widget.chrome.value),
      ),
      child: child,
    ),
  );
}
