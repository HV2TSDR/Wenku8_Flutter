import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_interactions.dart';
import '../app_ui.dart';
import 'app_updates.dart';
import 'release_highlights.dart';

class AppUpdatesScope extends InheritedNotifier<AppUpdates> {
  const AppUpdatesScope({
    super.key,
    required AppUpdates updates,
    required super.child,
  }) : super(notifier: updates);
  static AppUpdates? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdatesScope>()?.notifier;
}

/// Announcements wait for the current page to settle and never stack over an
/// existing menu, sheet or Android back gesture. No polling ticker is needed.
class AppUpdateNavigation extends NavigatorObserver with ChangeNotifier {
  Route<dynamic>? _top;
  Animation<double>? _enter, _leave;
  bool _gesture = false;

  bool get ready =>
      navigator != null &&
      _top is PageRoute &&
      _top!.isCurrent &&
      !_gesture &&
      (_enter == null || _enter!.status == AnimationStatus.completed) &&
      (_leave == null || _leave!.status == AnimationStatus.dismissed);

  void _animationChanged(AnimationStatus _) => notifyListeners();

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _enter?.removeStatusListener(_animationChanged);
    _leave?.removeStatusListener(_animationChanged);
    _top = topRoute;
    _enter = topRoute is ModalRoute ? topRoute.animation : null;
    _leave = topRoute is ModalRoute ? topRoute.secondaryAnimation : null;
    _enter?.addStatusListener(_animationChanged);
    _leave?.addStatusListener(_animationChanged);
    notifyListeners();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _gesture = true;
    notifyListeners();
  }

  @override
  void didStopUserGesture() {
    _gesture = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _enter?.removeStatusListener(_animationChanged);
    _leave?.removeStatusListener(_animationChanged);
    super.dispose();
  }
}

class AppUpdateMonitor extends StatefulWidget {
  const AppUpdateMonitor({
    super.key,
    required this.updates,
    required this.child,
    this.navigation,
  });
  final AppUpdates updates;
  final Widget child;
  final AppUpdateNavigation? navigation;
  @override
  State<AppUpdateMonitor> createState() => _AppUpdateMonitorState();
}

class _AppUpdateMonitorState extends State<AppUpdateMonitor>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _pendingForegroundCheck = true;
  bool _promptQueued = false, _promptOpen = false;
  String? _notesPresentedKey;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.updates.addListener(_queuePrompt);
    widget.navigation?.addListener(_queuePrompt);
    unawaited(widget.updates.loadInstalled().catchError((Object _) {}));
    _schedule();
  }

  @override
  void didUpdateWidget(AppUpdateMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates.removeListener(_queuePrompt);
      widget.updates.addListener(_queuePrompt);
    }
    if (oldWidget.navigation != widget.navigation) {
      oldWidget.navigation?.removeListener(_queuePrompt);
      widget.navigation?.addListener(_queuePrompt);
    }
    _queuePrompt();
  }

  void _queuePrompt() {
    if (!mounted || _promptQueued || _promptOpen) return;
    _promptQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptQueued = false;
      if (mounted) unawaited(_showPromptIfReady());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showPromptIfReady() async {
    final service = widget.updates;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final navigation = widget.navigation;
    if (_promptOpen ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed ||
        navigation?.ready != true) {
      return;
    }
    final navigator = navigation!.navigator!;
    final overlay = navigator.overlay!.context;
    if (MediaQuery.viewInsetsOf(overlay).bottom > 0) return;
    if (service.shouldShowReleaseNotes &&
        _notesPresentedKey != service.installedReleaseKey) {
      _notesPresentedKey = service.installedReleaseKey;
      _promptOpen = true;
      try {
        FocusManager.instance.primaryFocus?.unfocus();
        await showInstalledReleaseNotes(
          overlay,
          updates: service,
          automatic: true,
        );
      } finally {
        _promptOpen = false;
        if (mounted) _queuePrompt();
      }
      return;
    }
    if (!service.autoCheck ||
        service.checking ||
        service.downloading ||
        service.installing ||
        service.error != null ||
        !service.shouldPrompt) {
      return;
    }
    final release = service.release!;
    final route = _AppUpdatePromptRoute(
      release: release,
      canDownload: service.asset != null,
      appearance: GlassAppearance.of(overlay),
      reduceMotion: MediaQuery.disableAnimationsOf(overlay),
    );
    _promptOpen = true;
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      final answer = navigator.push<bool>(route);
      // Save only after actually presenting a prompt, not when a menu or a
      // background app prevented it. Dismissing outside also counts as later.
      try {
        await service.rememberPrompt(release);
      } catch (_) {
        if (mounted && overlay.mounted) {
          showNovelFeedback(overlay, '提醒偏好未保存，下次打开可能再次提示');
        }
      }
      final accepted = await answer;
      await route.completed;
      if (!mounted || !navigator.mounted || accepted != true) return;
      unawaited(
        pushNovelPage<void>(
          navigator.overlay!.context,
          AppUpdatePage(updates: service),
          reduceMotion: route.reduceMotion,
        ),
      );
      // The button is explicit download consent, never installation consent.
      if (service.release?.tag == release.tag &&
          service.asset != null &&
          service.downloaded == null) {
        unawaited(service.download());
      }
    } finally {
      _promptOpen = false;
      if (mounted) _queuePrompt();
    }
  }

  void _schedule() {
    _timer?.cancel();
    // Check once for each foreground session, after the first screen settles.
    // Transient inactive states (notification shade, system dialogs) are not a
    // new launch. A background return is, regardless of the last check's age.
    _timer = Timer(const Duration(seconds: 2), () {
      _timer = null;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          lifecycle != null && lifecycle != AppLifecycleState.resumed) {
        return;
      }
      _pendingForegroundCheck = false;
      unawaited(widget.updates.check(automatic: true));
    });
  }

  @override
  void didChangeMetrics() => _queuePrompt();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        widget.updates.loadInstalled(refresh: true).catchError((Object _) {}),
      );
      if (_pendingForegroundCheck) _schedule();
      _queuePrompt();
    } else {
      _timer?.cancel();
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        _pendingForegroundCheck = true;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.updates.removeListener(_queuePrompt);
    widget.navigation?.removeListener(_queuePrompt);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppUpdatesScope(updates: widget.updates, child: widget.child);
}

class _AppUpdatePromptRoute extends PopupRoute<bool> {
  _AppUpdatePromptRoute({
    required this.release,
    required this.canDownload,
    required this.appearance,
    required this.reduceMotion,
  });
  final AppRelease release;
  final bool canDownload;
  final GlassAppearance appearance;
  final bool reduceMotion;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : NovelMotion.enter;
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : NovelMotion.exit;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => Colors.black.withValues(alpha: .16);
  @override
  String get barrierLabel => '稍后提醒';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => GlassAppearance(
    blur: appearance.blur,
    opacity: appearance.opacity,
    child: Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24) +
              MediaQuery.viewInsetsOf(context),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
              child: GlassOverlayTransition(
                animation: animation,
                kind: GlassOverlayKind.sheet,
                reduceMotion: reduceMotion,
                child: GlassOverlaySurface(
                  key: const ValueKey('app-update-prompt'),
                  child: Semantics(
                    namesRoute: true,
                    label: '发现新版本 ${release.version.name}',
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  CupertinoIcons.arrow_up_circle,
                                  size: 28,
                                ),
                                const SizedBox(height: 16),
                                const AppText(
                                  '发现新版本',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                AppText(
                                  '轻小说文库 ${release.version.name}',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                ReleaseNotes(
                                  release.notes.trim().isEmpty
                                      ? '新版本已准备好，可以下载更新。'
                                      : release.notes,
                                ),
                                const SizedBox(height: 8),
                                AppText(
                                  '选择稍后提醒，24 小时内不再提示此版本。',
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.5,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final later = GlassTextButton(
                                key: const ValueKey('postpone-app-update'),
                                onPressed: () => Navigator.pop(context, false),
                                child: const AppText('稍后提醒'),
                              );
                              final update = GlassTextButton(
                                key: const ValueKey('confirm-app-update'),
                                onPressed: () => Navigator.pop(context, true),
                                child: AppText(
                                  canDownload ? '立即更新' : '查看更新',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                              if (constraints.maxWidth < 300 ||
                                  MediaQuery.textScalerOf(context).scale(14) >
                                      19) {
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    update,
                                    const SizedBox(height: 4),
                                    later,
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(child: later),
                                  const SizedBox(width: 12),
                                  Expanded(child: update),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AppUpdatePage extends StatelessWidget {
  const AppUpdatePage({super.key, this.updates});
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) => updates == null
      ? _page(context)
      : AnimatedBuilder(
          animation: updates!,
          builder: (context, _) => _page(context),
        );

  Widget _page(BuildContext context) {
    final service = updates;
    final padding = MediaQuery.paddingOf(context);
    final version = service?.installed?.version ?? currentAppVersion;
    final build = service?.installed?.build ?? currentAppBuild;
    final available = service?.available ?? false;
    return Scaffold(
      body: Atmosphere(
        child: GlassHeaderLayout(
          header: ArchiveHeaderBar(
            leading: GlassIconButton(
              icon: CupertinoIcons.back,
              label: '返回设置',
              onPressed: () => Navigator.pop(context),
            ),
            title: const ArchiveRouteTitle(
              title: '关于轻小说文库',
              code: 'SYSTEM / ABOUT',
            ),
          ),
          body: ListView(
            key: const ValueKey('update-page-scroll'),
            padding: EdgeInsets.fromLTRB(
              24 + padding.left,
              padding.top + FrostedHeader.toolbarHeight + 20,
              24 + padding.right,
              padding.bottom + 32,
            ),
            children: [
              const ArchiveSection(title: '轻小说文库', code: 'WENKU8 / FLUTTER'),
              const SizedBox(height: 12),
              AppText(
                '当前版本 $version · 构建 $build',
                key: const ValueKey('installed-app-version'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              if (service != null) ...[
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: AppText(
                              '自动检查更新',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 12),
                          AppControls.toggle(
                            context,
                            key: const ValueKey('automatic-update-check'),
                            value: service.autoCheck,
                            onChanged: (value) async {
                              try {
                                await service.setAutoCheck(value);
                              } catch (_) {
                                if (context.mounted) {
                                  showNovelFeedback(context, '设置保存失败，请重试');
                                }
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AppText(
                        '每次打开应用时检查新版本，下载与安装由你确认。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      GlassTextButton(
                        key: const ValueKey('check-app-update'),
                        onPressed: service.busy ? null : () => service.check(),
                        child: AppText(service.checking ? '正在检查版本' : '检查更新'),
                      ),
                      if (service.checking) ...[
                        const SizedBox(height: 12),
                        const SizedBox(
                          height: 16,
                          child: LoadingSkeleton(layout: SkeletonLayout.inline),
                        ),
                      ] else if (service.checked && !available) ...[
                        const SizedBox(height: 12),
                        AppText(
                          service.release == null ? '暂未发布可用的正式版本' : '已是最新版本',
                        ),
                      ],
                      if (service.checked && service.release != null) ...[
                        const SizedBox(height: 8),
                        AppText(
                          '最新正式版 ${service.release!.version.name}',
                          key: const ValueKey('latest-app-version'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (service.error != null) ...[
                        const SizedBox(height: 12),
                        AppText(
                          service.error!,
                          key: const ValueKey('update-error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (available) ...[
                  const SizedBox(height: 24),
                  ArchiveSection(
                    title: '发现新版本 ${service.release!.version.name}',
                    code: 'GITHUB / RELEASE',
                  ),
                  const SizedBox(height: 14),
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ReleaseNotes(
                          service.release!.notes.isEmpty
                              ? '此版本未提供更新说明。'
                              : service.release!.notes,
                        ),
                        const SizedBox(height: 16),
                        if (service.downloading) ...[
                          AppText(
                            '已下载 ${(service.bytes / 1024 / 1024).toStringAsFixed(1)} / ${(service.asset!.size / 1024 / 1024).toStringAsFixed(1)} MB',
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: (service.bytes / service.asset!.size).clamp(
                              0.0,
                              1.0,
                            ),
                            color: Theme.of(context).colorScheme.primary,
                            minHeight: 2,
                          ),
                          GlassTextButton(
                            onPressed: service.cancelDownload,
                            child: const AppText('取消下载'),
                          ),
                        ] else if (service.downloaded != null) ...[
                          AppText(
                            '安装包 ${service.downloadedInfo!.version} · 构建 ${service.downloadedInfo!.build}',
                            key: const ValueKey('downloaded-app-version'),
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (service.needsPermission)
                            AppText(
                              '请允许本应用安装更新，返回后再次点击「安装更新」。',
                              style: TextStyle(
                                height: 1.5,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (service.needsPermission)
                            GlassTextButton(
                              onPressed: () => _open(
                                context,
                                service.platform.allowInstalls,
                              ),
                              child: const AppText('允许安装更新'),
                            ),
                          GlassTextButton(
                            key: const ValueKey('install-app-update'),
                            onPressed: service.busy ? null : service.install,
                            child: AppText(
                              service.installing ? '正在打开安装程序' : '安装更新',
                            ),
                          ),
                        ] else if (service.asset != null)
                          GlassTextButton(
                            key: const ValueKey('download-app-update'),
                            onPressed: service.busy ? null : service.download,
                            child: AppText(
                              '下载更新 · ${(service.asset!.size / 1024 / 1024).toStringAsFixed(1)} MB',
                            ),
                          )
                        else
                          const AppText('此版本暂无适合本机的 APK。'),
                        GlassTextButton(
                          onPressed: () => _open(
                            context,
                            () => service.openProjectPage(showRelease: true),
                          ),
                          child: const AppText('查看版本与下载入口'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 28),
              ],
              CurrentReleaseCard(updates: service),
              const SizedBox(height: 28),
              const ArchiveSection(title: '项目与许可', code: 'SOURCE / LICENSES'),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppText(
                      '基于 MewX 与原项目贡献者的轻小说文库 Android 客户端重构。原项目 GPL v2 或后续版本许可保留；本 Flutter 组合版本按 GPL v3 分发。',
                      style: TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    const AppText(
                      '小说正文、封面和插图的权利属于各自权利人。',
                      style: TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    const AppText(
                      '内置字体：Adobe 思源宋体 CN，SIL OFL 1.1。在线语音协议适配：rany2/edge-tts，LGPL v3。接口运行库 libcpp.so 原样保留，其授权独立于本项目源码。',
                      style: TextStyle(height: 1.6),
                    ),
                    GlassTextButton(
                      key: const ValueKey('app-open-source-licenses'),
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: '轻小说文库',
                        applicationVersion: currentAppVersion,
                        applicationLegalese:
                            'Copyright © MewX and contributors\nFlutter modifications © 2026 Wenku8 Flutter contributors',
                      ),
                      child: const AppText('开源许可与字体授权'),
                    ),
                    if (service != null) ...[
                      const SizedBox(height: 12),
                      GlassTextButton(
                        onPressed: () =>
                            _open(context, () => service.openProjectPage()),
                        child: const AppText('项目介绍与下载'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '暂时无法打开，请稍后重试');
    }
  }
}

class ReleaseNotes extends StatelessWidget {
  const ReleaseNotes(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final line in text.trim().split('\n'))
        if (line.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppText(
              line
                  .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
                  .replaceFirst(RegExp(r'^[-*]\s+'), '· '),
              style: TextStyle(
                height: 1.6,
                fontWeight: line.startsWith('#')
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
    ],
  );
}
