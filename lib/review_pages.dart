import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'catalog.dart';
import 'feature_pages.dart';
import 'legacy_transport.dart';
import 'library_state.dart';
import 'local_platform.dart';
import 'wenku_account.dart';
import 'wenku_features.dart';
import 'wenku_reviews.dart';

class BookCommunityActions extends StatelessWidget {
  const BookCommunityActions({
    super.key,
    required this.novel,
    required this.state,
    required this.repository,
  });
  final Novel novel;
  final LibraryState state;
  final NovelRepository repository;
  Future<bool> _login(BuildContext context, WenkuAccount account) async {
    if (!account.authenticated) {
      await pushNovelPage<void>(
        context,
        WenkuAccountPage(
          account: account,
          state: state,
          repository: repository,
        ),
        reduceMotion: state.reduceMotion,
      );
    }
    return context.mounted && account.authenticated;
  }

  Future<void> _mutate(
    BuildContext context,
    WenkuAccount account,
    bool recommend,
  ) async {
    if (account.busy || !await _login(context, account)) return;
    try {
      if (recommend) {
        await account.recommend(novel.id);
      } else {
        await account.addCloud(novel.id);
      }
      if (context.mounted) {
        showNovelFeedback(context, recommend ? '推荐已提交' : '已收藏到云书架');
      }
    } catch (error) {
      if (context.mounted) {
        showNovelFeedback(context, WenkuAccount.describeError(error));
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final text =
        '${novel.title}\n${novel.author}\nhttps://www.wenku8.net/book/${novel.id}.htm';
    try {
      if (LocalPlatform.android) {
        await LocalPlatform.shareText(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) showNovelFeedback(context, '图书链接已复制');
      }
    } catch (_) {
      if (context.mounted) showNovelFeedback(context, '分享未完成，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final features = WenkuFeaturesScope.maybeOf(context);
    if (features == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: features.account,
      builder: (context, _) {
        final actions = [
          GlassTextButton(
            key: const ValueKey('detail-cloud-save'),
            compact: true,
            onPressed: features.account.busy
                ? null
                : () => _mutate(context, features.account, false),
            child: const AppText('云端收藏'),
          ),
          GlassTextButton(
            key: const ValueKey('detail-recommend'),
            compact: true,
            onPressed: features.account.busy
                ? null
                : () => _mutate(context, features.account, true),
            child: const AppText('推荐作品'),
          ),
          GlassTextButton(
            key: const ValueKey('detail-reviews'),
            compact: true,
            child: const AppText('评论'),
            onPressed: () => pushNovelPage<void>(
              context,
              WenkuReviewsPage(
                novel: novel,
                account: features.account,
                state: state,
                repository: repository,
              ),
              reduceMotion: state.reduceMotion,
            ),
          ),
          GlassTextButton(
            key: const ValueKey('detail-share'),
            compact: true,
            child: const AppText('分享'),
            onPressed: () => _share(context),
          ),
        ];
        final row = Row(
          key: const ValueKey('detail-community-actions'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < actions.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              actions[index],
            ],
          ],
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: row,
        );
      },
    );
  }
}

class WenkuReviewsPage extends StatefulWidget {
  const WenkuReviewsPage({
    super.key,
    required this.novel,
    required this.account,
    required this.state,
    required this.repository,
    this.thread,
    this.feed,
    this.onPosted,
  });
  final Novel novel;
  final WenkuAccount account;
  final LibraryState state;
  final NovelRepository repository;
  final WenkuReview? thread;
  final WenkuReviewFeed? feed;
  final VoidCallback? onPosted;
  @override
  State<WenkuReviewsPage> createState() => _WenkuReviewsPageState();
}

class _WenkuReviewsPageState extends State<WenkuReviewsPage> {
  late final _feed =
      widget.feed ??
      WenkuReviewFeed(
        id: widget.thread?.id ?? widget.novel.id,
        replies: widget.thread != null,
      );
  @override
  void initState() {
    super.initState();
    unawaited(_feed.load());
  }

  @override
  void dispose() {
    if (widget.feed == null) _feed.dispose();
    super.dispose();
  }

  Future<void> _compose() async {
    if (widget.account.busy) return;
    if (!widget.account.authenticated) {
      await pushNovelPage<void>(
        context,
        WenkuAccountPage(
          account: widget.account,
          state: widget.state,
          repository: widget.repository,
        ),
        reduceMotion: widget.state.reduceMotion,
      );
    }
    if (!mounted || !widget.account.authenticated) return;
    if (widget.account.profile == null) {
      try {
        await widget.account.refreshProfile();
      } catch (error) {
        if (mounted) {
          showNovelFeedback(context, WenkuAccount.describeError(error));
        }
        return;
      }
      if (!mounted) return;
    }
    final posted = await pushNovelPage<bool>(
      context,
      ReviewComposerPage(
        novel: widget.novel,
        account: widget.account,
        reduceMotion: widget.state.reduceMotion,
        thread: widget.thread,
      ),
      reduceMotion: widget.state.reduceMotion,
    );
    if (mounted && posted == true) {
      showNovelFeedback(context, widget.thread == null ? '评论已发表' : '回复已发表');
      widget.onPosted?.call();
      unawaited(_feed.load(refresh: true));
    }
  }

  Future<void> _openThread(WenkuReview review) async {
    var changed = false;
    await pushNovelPage<void>(
      context,
      WenkuReviewsPage(
        novel: widget.novel,
        account: widget.account,
        state: widget.state,
        repository: widget.repository,
        thread: review,
        onPosted: () => changed = true,
      ),
      // A list and its thread share a Widget type, but are distinct routes.
      // Coalesce repeated activation per actual thread, not per Widget type.
      slot: ('review-thread', widget.novel.id, review.id),
      reduceMotion: widget.state.reduceMotion,
    );
    if (mounted && changed) unawaited(_feed.load(refresh: true));
  }

  Future<void> _loginToRead() async {
    if (widget.account.busy) return;
    await pushNovelPage<void>(
      context,
      WenkuAccountPage(
        account: widget.account,
        state: widget.state,
        repository: widget.repository,
      ),
      reduceMotion: widget.state.reduceMotion,
    );
    if (mounted && widget.account.authenticated) {
      await _feed.load(refresh: true);
    }
  }

  @override
  Widget build(BuildContext context) => ArchiveFeaturePage(
    title: widget.thread?.title ?? '作品评论',
    code: widget.thread == null
        ? 'REVIEW / ${ArchiveDesign.fileCode(widget.novel.id)}'
        : 'THREAD / ${widget.thread!.id}',
    actions: [
      GlassIconButton(
        icon: CupertinoIcons.refresh,
        label: '刷新书评',
        onPressed: () => _feed.load(refresh: true),
      ),
    ],
    child: AnimatedBuilder(
      animation: _feed,
      builder: (context, _) => _feed.requiresLogin && _feed.items.isEmpty
          ? ContentNotice(
              icon: CupertinoIcons.person_crop_circle,
              title: '登录后查看书评',
              message: '本机阅读记录和收藏不受影响。',
              actionLabel: '登录账号',
              onRetry: _loginToRead,
            )
          : LoadedContentSequence(
              generation: _feed.revision,
              firstIndex: _feed.firstIndex + 1,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.vertical &&
                      notification.metrics.extentAfter < 600 &&
                      !_feed.loading &&
                      _feed.error == null &&
                      _feed.hasMore) {
                    unawaited(_feed.load());
                  }
                  return false;
                },
                child: ListView.builder(
                  padding: featurePadding(context),
                  itemCount: _feed.items.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: AppText(
                                  widget.novel.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    height: 1.6,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              GlassTextButton(
                                key: const ValueKey('review-compose'),
                                compact: true,
                                onPressed: _compose,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(CupertinoIcons.pencil, size: 15),
                                    const SizedBox(width: 6),
                                    AppText(
                                      widget.thread == null ? '写评论' : '回复',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          if (_feed.totalPages > 1) ...[
                            AppText(
                              '已载入第 ${_feed.page} / ${_feed.totalPages} 页',
                            ),
                            const SizedBox(height: 12),
                          ],
                        ],
                      );
                    }
                    if (index == _feed.items.length + 1) {
                      return Column(
                        children: [
                          FeatureError(_feed.error),
                          if (_feed.loading)
                            Column(
                              children: [
                                for (
                                  var item = 0;
                                  item < (_feed.items.isEmpty ? 3 : 1);
                                  item++
                                )
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: ReviewCardSkeleton(
                                      thread: widget.thread != null,
                                    ),
                                  ),
                              ],
                            ),
                          if (_feed.error != null)
                            GlassTextButton(
                              onPressed: _feed.requiresLogin
                                  ? _loginToRead
                                  : () => _feed.load(),
                              child: AppText(
                                _feed.requiresLogin
                                    ? '登录后继续查看'
                                    : widget.thread == null
                                    ? '重试书评'
                                    : '重试正文与回复',
                              ),
                            ),
                          if (!_feed.loading &&
                              _feed.error == null &&
                              _feed.items.isEmpty)
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: 60),
                              child: AppText(
                                widget.thread == null ? '还没有书评' : '暂时没有内容',
                              ),
                            ),
                          if (!_feed.loading &&
                              _feed.error == null &&
                              _feed.hasMore)
                            GlassTextButton(
                              onPressed: () => _feed.load(),
                              child: AppText(
                                widget.thread == null ? '更多书评' : '更多回复',
                              ),
                            ),
                        ],
                      );
                    }
                    final review = _feed.items[index - 1];
                    return LoadedContentItem(
                      key: ValueKey(review.identity),
                      index: index,
                      placeholder: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ReviewCardSkeleton(
                          thread: widget.thread != null,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ContentPanel(
                          key: ValueKey('review-card-${review.identity}'),
                          onTap: widget.thread != null
                              ? null
                              : () => _openThread(review),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.thread != null) ...[
                                ArchiveCode(
                                  index == 1
                                      ? '01 / ORIGINAL POST'
                                      : '${index.toString().padLeft(2, '0')} / REPLY',
                                ),
                                const SizedBox(height: 10),
                              ],
                              if (review.title.isNotEmpty) ...[
                                AppText(
                                  review.title,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                              if (review.content.isNotEmpty) ...[
                                AppText(
                                  review.content,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.8,
                                  ),
                                ),
                                const SizedBox(height: 14),
                              ],
                              AppText(
                                '${review.user}  ·  ${review.date}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (widget.thread == null) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: AppText(
                                        '${review.replies} 条回复 · 查看全文',
                                      ),
                                    ),
                                    const Icon(
                                      CupertinoIcons.chevron_right,
                                      size: 14,
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    ),
  );
}

class ReviewCardSkeleton extends StatelessWidget {
  const ReviewCardSkeleton({super.key, this.thread = false});
  final bool thread;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ContentPanel(
      child: SizedBox(
        height:
            (thread ? 174 : 104) *
            (MediaQuery.textScalerOf(context).scale(14) / 14),
        width: double.infinity,
        child: LoadingSkeleton(
          layout: thread ? SkeletonLayout.reviewThread : SkeletonLayout.review,
          label: thread ? '正在读取正文与回复' : '正在读取书评',
        ),
      ),
    ),
  );
}

class ReviewComposerPage extends StatefulWidget {
  const ReviewComposerPage({
    super.key,
    required this.novel,
    required this.account,
    required this.reduceMotion,
    this.thread,
  });
  final Novel novel;
  final WenkuAccount account;
  final bool reduceMotion;
  final WenkuReview? thread;
  @override
  State<ReviewComposerPage> createState() => _ReviewComposerPageState();
}

class _ReviewComposerPageState extends State<ReviewComposerPage> {
  final _title = TextEditingController(), _body = TextEditingController();
  SharedPreferences? _preferences;
  Timer? _saveDelay;
  Future<void> _writes = Future.value();
  bool _busy = false, _loaded = false, _posted = false;
  String? _error;
  String get _key =>
      'review_draft_${widget.account.profile?.id ?? 0}_${widget.novel.id}_${widget.thread?.id ?? 0}';
  late final String _draftKey = _key;
  @override
  void initState() {
    super.initState();
    _title.addListener(_edited);
    _body.addListener(_edited);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _preferences = prefs;
      _title.text = prefs.getString('${_draftKey}_title') ?? '';
      _body.text = prefs.getString('${_draftKey}_body') ?? '';
    } catch (_) {
      _error = '草稿读取失败，当前编辑内容请先保留';
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _edited() {
    if (!_loaded || _posted) return;
    _saveDelay?.cancel();
    _saveDelay = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() {
    _saveDelay?.cancel();
    final title = _title.text, body = _body.text, prefs = _preferences;
    if (prefs == null || _posted) return _writes;
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) async {
          if (!await prefs.setString('${_draftKey}_title', title) ||
              !await prefs.setString('${_draftKey}_body', body)) {
            throw StateError('Draft write failed');
          }
        })
        .catchError((Object _) {
          if (mounted) setState(() => _error = '草稿保存失败，请保留当前内容后重试');
        });
  }

  Future<void> _post() async {
    if (_busy || !_loaded || _posted) return;
    final title = _title.text.trim(), content = _body.text.trim();
    if (content.length < 10) {
      setState(() => _error = '请填写至少 10 字的正文');
      return;
    }
    if (widget.thread == null && title.length < 2) {
      setState(() => _error = '请填写至少 2 字的标题');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    await _save();
    try {
      final encodedContent = await LegacyTransport.encodeReview(content);
      final action = widget.thread != null
          ? 'action=review&do=reply&rid=${widget.thread!.id}&content=$encodedContent'
          : 'action=review&do=post&aid=${widget.novel.id}&title=${await LegacyTransport.encodeReview(title)}&content=$encodedContent';
      await widget.account.submitReview(action);
      _posted = true;
      await _writes;
      try {
        await _preferences?.remove('${_draftKey}_title');
        await _preferences?.remove('${_draftKey}_body');
      } catch (_) {
        /* A successful server post is not retried for a draft cleanup error. */
      }
      if (mounted) {
        setState(() => _busy = false);
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = WenkuAccount.describeError(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _saveDelay?.cancel();
    if (!_posted) unawaited(_save());
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: ArchiveFeaturePage(
      title: widget.thread == null ? '写评论' : '回复评论',
      code: 'REVIEW / COMPOSE',
      canPop: !_busy,
      actions: [
        GlassTextButton(
          key: const ValueKey('review-submit'),
          compact: true,
          onPressed: !_loaded || _busy || _posted ? null : _post,
          child: AppText(
            _posted
                ? '已发表'
                : _busy
                ? '正在发表'
                : '发表',
          ),
        ),
      ],
      child: ListView(
        padding: featurePadding(context),
        children: [
          AppText(
            widget.thread?.title ?? widget.novel.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          AppText(
            '草稿自动保存',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (!_loaded)
            const SizedBox(
              height: 200,
              child: LoadingSkeleton(layout: SkeletonLayout.reader),
            )
          else
            ContentPanel(
              child: Column(
                children: [
                  if (widget.thread == null)
                    TextField(
                      key: const ValueKey('review-title'),
                      controller: _title,
                      enabled: !_busy,
                      maxLength: 60,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        hintText: appText(context, '标题'),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                  TextField(
                    key: const ValueKey('review-body'),
                    controller: _body,
                    enabled: !_busy,
                    minLines: 8,
                    maxLines: 20,
                    maxLength: 4000,
                    style: const TextStyle(fontSize: 14, height: 1.8),
                    decoration: InputDecoration(
                      hintText: appText(context, '写下你的想法…'),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                  ),
                  FeatureError(_error),
                  if (_busy)
                    const SizedBox(
                      height: 64,
                      child: LoadingSkeleton(
                        layout: SkeletonLayout.actions,
                        label: '正在发表',
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
