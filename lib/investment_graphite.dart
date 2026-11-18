part of 'main.dart';

// Visual shell only. Sources, calculations and the append-only decision ledger
// remain owned by the existing investment workflow and server.
class _GraphitePalette extends Palette {
  _GraphitePalette(super.colorBlind);
  @override
  Color get background =>
      blackEditionPreview ? Colors.black : const Color(0xFF0E171F);
  @override
  Color get panel =>
      blackEditionPreview ? const Color(0xFF080808) : const Color(0xFF111C25);
  @override
  Color get card =>
      blackEditionPreview ? const Color(0xFF121212) : const Color(0xFF17252E);
  @override
  Color get border =>
      blackEditionPreview ? const Color(0xFF2A2A2A) : const Color(0xFF293A46);
  @override
  Color get accent => colorBlind
      ? super.accent
      : blackEditionPreview
      ? const Color(0xFF52AEF5)
      : const Color(0xFF48DAB3);
  @override
  Color get muted =>
      blackEditionPreview ? const Color(0xFFABABAB) : const Color(0xFFB0BDCC);
  @override
  Color get faint =>
      blackEditionPreview ? const Color(0xFF858585) : super.faint;
  @override
  Color get text => blackEditionPreview ? const Color(0xFFF5F5F5) : super.text;
  @override
  Color get positive => blackEditionPreview && !colorBlind
      ? const Color(0xFF36CF88)
      : super.positive;
  @override
  Color get negative => blackEditionPreview && !colorBlind
      ? const Color(0xFFFF6963)
      : super.negative;
}

extension _GraphiteWorkspace on _InvestmentWorkspaceState {
  Widget graphiteBuild(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 1100;
    final base = Theme.of(context);
    final theme = base.copyWith(
      scaffoldBackgroundColor: p.background,
      colorScheme: ColorScheme.dark(
        primary: p.accent,
        onPrimary: blackEditionPreview ? Colors.black : p.background,
        surface: p.panel,
        onSurface: p.text,
        outline: p.border,
      ),
      textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
      dividerColor: p.border,
      splashFactory: blackEditionPreview
          ? InkSparkle.splashFactory
          : base.splashFactory,
      dataTableTheme: !blackEditionPreview
          ? base.dataTableTheme
          : base.dataTableTheme.copyWith(
              headingTextStyle: TextStyle(
                color: p.muted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              dataTextStyle: TextStyle(
                color: p.text,
                fontSize: 13,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
              dividerThickness: .5,
            ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: TextStyle(color: p.muted, fontSize: 13),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: p.accent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: blackEditionPreview ? p.text : p.accent,
          foregroundColor: p.background,
          minimumSize: const Size(44, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(blackEditionPreview ? 4 : 8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.muted,
          minimumSize: const Size(44, 46),
          side: BorderSide(color: p.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: p.panel,
        selectedColor: blackEditionPreview
            ? const Color(0xFF292929)
            : p.accent.withValues(alpha: .20),
        side: BorderSide(color: p.border),
        labelStyle: TextStyle(color: p.text),
        showCheckmark: false,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        textColor: p.text,
        collapsedTextColor: p.muted,
        iconColor: p.accent,
        collapsedIconColor: p.muted,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
    );
    return Theme(
      data: theme,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              unawaited(openGlobalCompanySearch()),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              unawaited(openGlobalCompanySearch()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: p.background,
            body: SafeArea(
              child: Row(
                children: [
                  if (desktop) graphiteRail(),
                  Expanded(
                    child: Column(
                      children: [
                        if (!desktop) graphiteMobileHeader(),
                        if (widget.sessionExpired) sessionExpiredBanner(),
                        if (busy)
                          LinearProgressIndicator(minHeight: 2, color: p.accent),
                    Expanded(
                      child: page == 'admin' && widget.adminContent != null
                          ? widget.adminContent!
                          : SingleChildScrollView(
                              key: ValueKey(
                                'workflow-$page-${page == 'research' ? '$ticker-$section' : '$discoveryTab-${text(asMap(selectedGuru?['guru'])['id'])}'}-$asOf-${page == 'discover' && MediaQuery.sizeOf(context).width < 1380 ? opportunityMobileDetail : false}',
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (page != 'home' &&
                                      page != 'book' &&
                                      page != 'discover' &&
                                      (page != 'research' || company == null))
                                    Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        desktop ? 34 : 18,
                                        24,
                                        24,
                                        0,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: dateControl(),
                                      ),
                                    ),
                                  if (error != null)
                                    Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: card([
                                        label(
                                          'Could not complete this step. Saved records are unchanged.',
                                          '本次操作未完成，已保存记录不变。',
                                          color: p.negative,
                                        ),
                                        SelectableText(
                                          error!,
                                          style: TextStyle(
                                            color: p.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                        button(
                                          'Retry workspace',
                                          '重载工作区',
                                          () => unawaited(
                                            page == 'research' &&
                                                    ticker.isNotEmpty
                                                ? loadCompany(
                                                    ticker,
                                                    origin: discoveryOrigin,
                                                    evidence: entryEvidence,
                                                    initialSection: section,
                                                  )
                                                : page == 'discover'
                                                ? loadDiscovery()
                                                : loadHome(),
                                          ),
                                        ),
                                      ], border: p.negative),
                                    ),
                                  if (notice != null)
                                    Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Text(
                                        notice!,
                                        style: TextStyle(color: p.accent),
                                      ),
                                    ),
                                  if (page == 'research' && company != null)
                                    ...researchView()
                                  else
                                    Padding(
                                      padding:
                                          desktop &&
                                              page == 'discover' &&
                                              discoveryTab == 'managers'
                                          ? const EdgeInsets.fromLTRB(
                                              24,
                                              16,
                                              24,
                                              24,
                                            )
                                          : page == 'book'
                                          ? EdgeInsets.fromLTRB(
                                              desktop ? 34 : 18,
                                              20,
                                              desktop ? 34 : 18,
                                              24,
                                            )
                                          : EdgeInsets.all(desktop ? 34 : 18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (page == 'home')
                                            ...personalHomePage(),
                                          if (page == 'discover')
                                            ...discoveryPage(),
                                          if (page == 'research')
                                            ...researchView(),
                                          if (page == 'book')
                                            ...researchPortfolioPage(),
                                          if (page == 'strategies')
                                            ...strategyPage(),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get todayUtcIso =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);
  bool get isHistoricalReplay => asOf.compareTo(todayUtcIso) < 0;

  Widget sessionExpiredBanner() => Container(
    key: const ValueKey('session-expired-banner'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF2A1C08),
      border: Border(
        bottom: BorderSide(
          color: const Color(0xFFF5A623).withValues(alpha: .45),
        ),
      ),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.lock_clock_outlined,
          color: Color(0xFFF5A623),
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            w(
              'Your sign-in session has expired. Sign in again to refresh live data while keeping saved records safe.',
              '当前登录会话已过期，请重新登录以刷新数据（已保存记录不会丢失）。',
            ),
            style: TextStyle(color: p.text, fontSize: 12.5),
          ),
        ),
        if (widget.onLogout != null)
          FilledButton.tonal(
            onPressed: () => unawaited(requestLogout()),
            child: Text(w('Sign in again', '重新登录')),
          ),
      ],
    ),
  );

  List<(String, String, String, IconData)> get graphitePages => [
    ('home', 'Home', '首页', Icons.home_outlined),
    ('discover', 'Discover', '发现', Icons.explore_outlined),
    ('research', 'Research', '研究', Icons.search),
    ('book', 'Portfolio', '组合', Icons.bar_chart_outlined),
    ('strategies', 'Strategies', '策略', Icons.layers_outlined),
    if (widget.showAdmin && widget.onLegacyView != null)
      ('admin', 'Admin', '管理', Icons.admin_panel_settings_outlined),
  ];

  Widget brand({double size = 23}) => Row(
    children: [
      Image.asset(
        thesisForgeMarkAsset,
        width: blackEditionPreview ? 40 : 32,
        height: blackEditionPreview ? 40 : 36,
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            'ThesisForge',
            style: TextStyle(
              color: p.text,
              fontSize: blackEditionPreview ? size - 2 : size,
              fontWeight: blackEditionPreview
                  ? FontWeight.w600
                  : FontWeight.w700,
              letterSpacing: blackEditionPreview ? -.9 : -.5,
            ),
          ),
        ),
      ),
    ],
  );

  Widget graphiteRail() => Container(
    width: 216,
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: p.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 16, 16),
          child: brand(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Material(
            color: const Color(0xFF111113),
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              key: const ValueKey('global-search-trigger'),
              onTap: () => unawaited(openGlobalCompanySearch()),
              borderRadius: BorderRadius.circular(7),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: p.muted, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w('Search', '搜索'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C20),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: p.border),
                      ),
                      child: Text(
                        '⌘K',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final item in graphitePages)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Material(
                      color: page == item.$1
                          ? blackEditionPreview
                                ? const Color(0xFF1C1C1C)
                                : p.accent.withValues(alpha: .17)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                      child: InkWell(
                        onTap: () => unawaited(requestNavigate(item.$1)),
                        borderRadius: BorderRadius.circular(5),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.$4,
                                color: page == item.$1
                                    ? blackEditionPreview
                                          ? p.text
                                          : p.accent
                                    : p.muted,
                                size: blackEditionPreview ? 21 : 25,
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Text(
                                  w(item.$2, item.$3),
                                  style: TextStyle(
                                    color: page == item.$1 ? p.text : p.muted,
                                    fontSize: blackEditionPreview ? 14 : 17,
                                    fontWeight: page == item.$1
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              TextButton(
                onPressed: () => widget.onLanguage(
                  context.language == AppLanguage.en
                      ? AppLanguage.zh
                      : AppLanguage.en,
                ),
                child: Text(context.language == AppLanguage.en ? '中文' : 'EN'),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('workspace-preferences-button'),
                tooltip: w('Preferences & account', '偏好与账户'),
                onPressed: showWorkspacePreferences,
                icon: Icon(Icons.tune_outlined, color: p.muted, size: 19),
              ),
              if (widget.onLogout != null)
                IconButton(
                  tooltip: w('Sign out', '退出登录'),
                  onPressed: () => unawaited(requestLogout()),
                  icon: Icon(Icons.logout, color: p.muted, size: 20),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
          child: TextButton.icon(
            onPressed: showMethodology,
            icon: Icon(Icons.description_outlined, color: p.muted, size: 20),
            label: Text(
              w('Sources & methodology', '来源与方法'),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ),
        ),
      ],
    ),
  );

  Widget graphiteMobileHeader() => Container(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: p.border)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Row(
            children: [
              Expanded(child: brand(size: 19)),
              IconButton(
                key: const ValueKey('mobile-search-trigger'),
                tooltip: w('Search ticker (⌘K)', '搜索公司'),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => unawaited(openGlobalCompanySearch()),
                icon: Icon(Icons.search_rounded, color: p.muted, size: 19),
              ),
              IconButton(
                tooltip: w('Preferences & account', '偏好与账户'),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: showWorkspacePreferences,
                icon: Icon(Icons.tune_outlined, color: p.muted, size: 18),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => widget.onLanguage(
                  context.language == AppLanguage.en
                      ? AppLanguage.zh
                      : AppLanguage.en,
                ),
                child: Text(context.language == AppLanguage.en ? '中文' : 'EN'),
              ),
              if (widget.onLogout != null)
                IconButton(
                  tooltip: w('Sign out', '退出登录'),
                  onPressed: () => unawaited(requestLogout()),
                  icon: Icon(Icons.logout, color: p.muted, size: 20),
                ),
            ],
          ),
        ),
        Row(
          children: [
            for (final item in graphitePages)
              Expanded(
                child: InkWell(
                  onTap: () => unawaited(requestNavigate(item.$1)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: page == item.$1
                              ? p.accent
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      w(item.$2, item.$3),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: page == item.$1 ? p.accent : p.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget dateControl() {
    final replay = isHistoricalReplay;
    final statusColor = replay
        ? const Color(0xFFF5A623)
        : const Color(0xFF20C997);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('global-date-control'),
              onPressed: showDateDialog,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(
                  color: replay
                      ? statusColor.withValues(alpha: .55)
                      : p.border,
                ),
              ),
              icon: Icon(
                replay ? Icons.history_rounded : Icons.calendar_today_outlined,
                size: 15,
                color: replay ? statusColor : p.muted,
              ),
              label: Text(
                '${w('As of', '截至')} $asOf',
                style: TextStyle(color: p.text, fontSize: 13),
              ),
            ),
            if (replay)
              TextButton.icon(
                key: const ValueKey('date-reset-live'),
                onPressed: () => unawaited(applyCutoffDate(todayUtcIso)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(
                  Icons.bolt_rounded,
                  size: 13,
                  color: Color(0xFF20C997),
                ),
                label: Text(
                  w('Live', '最新'),
                  style: const TextStyle(
                    color: Color(0xFF20C997),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 5,
          runSpacing: 2,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              replay
                  ? w(
                      'Point-in-time replay active',
                      '历史时点回放模式',
                    )
                  : widget.localPreview
                  ? w('Local preview · Latest PIT', '本地预览 · 最新时点')
                  : w('Live · Latest available data', '实时最新数据 · 支持时点回放'),
              style: TextStyle(
                color: replay ? statusColor : p.muted,
                fontSize: 11,
                fontWeight: replay ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> showDateDialog() async {
    if (!await allowLeaveDraft() || !mounted) return;
    final today = todayUtcIso;
    dateInput.text = asOf;
    final oneYearAgo = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 365))
        .toIso8601String()
        .substring(0, 10);
    final presets = <(String, String)>[
      (w('● Live (Today)', '● 最新数据 (今天)'), today),
      (w('2026 Q3 End', '2026 Q3 季末'), '2026-09-30'),
      (w('1Y Ago', '一年前'), oneYearAgo),
      (w('2025 Year-End', '2025 年底'), '2025-12-31'),
      (w('2022 Trough', '2022 底部'), '2022-10-14'),
    ].where((item) => item.$2.compareTo(today) <= 0).toList();

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: p.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: p.border),
          ),
          title: Text(
            w('Information available by', '信息截止日期与历史回放'),
            style: TextStyle(
              color: p.text,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w(
                    'Stay on Live for current research, or rewind to any historical date to inspect strictly what filings, 13F books, and prices were known then.',
                    '保持“最新数据”进行日常研究，或切回任意历史日期回放当时真实可见的财报、13F 持仓与股价。',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in presets)
                      ActionChip(
                        backgroundColor: dateInput.text.trim() == preset.$2
                            ? p.accent.withValues(alpha: .18)
                            : const Color(0xFF17171A),
                        side: BorderSide(
                          color: dateInput.text.trim() == preset.$2
                              ? p.accent
                              : p.border,
                        ),
                        label: Text(
                          preset.$1,
                          style: TextStyle(
                            color: dateInput.text.trim() == preset.$2
                                ? p.text
                                : p.muted,
                            fontSize: 12,
                          ),
                        ),
                        onPressed: () =>
                            setModalState(() => dateInput.text = preset.$2),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: input(dateInput, 'YYYY-MM-DD', '年-月-日', width: 240),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      key: const ValueKey('date-open-calendar'),
                      onPressed: () async {
                        final initial =
                            DateTime.tryParse(dateInput.text.trim()) ??
                            DateTime.now().toUtc();
                        final nowUtc = DateTime.now().toUtc();
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: initial.isAfter(nowUtc)
                              ? nowUtc
                              : initial,
                          firstDate: DateTime.utc(2005, 1, 1),
                          lastDate: DateTime.utc(
                            nowUtc.year,
                            nowUtc.month,
                            nowUtc.day,
                          ),
                        );
                        if (picked != null) {
                          final formatted =
                              '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                          setModalState(() => dateInput.text = formatted);
                        }
                      },
                      icon: const Icon(Icons.event_outlined, size: 16),
                      label: Text(w('Calendar', '日历')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(w('Cancel', '取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(w('Apply date', '应用日期')),
            ),
          ],
        ),
      ),
    );
    if (apply != true || !mounted) return;
    await applyCutoffDate(dateInput.text.trim());
  }

  Future<void> applyCutoffDate(String requested) async {
    if (!await allowLeaveDraft() || !mounted) return;
    await command(() async {
      final previous = asOf;
      final parsed = DateTime.tryParse(requested);
      if (parsed == null ||
          parsed.toIso8601String().substring(0, 10) != requested ||
          requested.compareTo(todayUtcIso) > 0) {
        throw StateError(
          w('Enter a valid date no later than today.', '请输入不晚于今天的有效日期。'),
        );
      }
      asOf = requested;
      dateInput.text = requested;
      // A snapshot is bound to one information cutoff even when the user
      // changes the date from another Discover module or Research. Never let a
      // hidden AI panel revive that stale generation/date tuple later.
      aiInsightsSelection.remove('snapshotId');
      final selectedAiQuarter = text(aiInsightsSelection['quarter']);
      final latestAiQuarter = '${parsed.year}Q${((parsed.month - 1) ~/ 3) + 1}';
      if (selectedAiQuarter.replaceAll('-', '').compareTo(latestAiQuarter) >
          0) {
        aiInsightsSelection.remove('quarter');
        aiInsightsSelection.remove('quarterPinned');
      }
      if (page == 'discover' && discoveryTab == 'aiinsights') {
        home = null;
      } else {
        await loadHome();
      }
      if (error != null) {
        asOf = previous;
        return;
      }
      final wasReview = reviewId != null && review != null;
      requestSerial++;
      calculationSerial++;
      calculationTimer?.cancel();
      company = null;
      calculation = null;
      review = null;
      scenarioId = null;
      ownership = false;
      discoveryData = null;
      discoverySerial++;
      discoveryLoading = false;
      homeExampleSerial++;
      homeExampleLoading = false;
      homeExample = null;
      homeExampleError = null;
      homeBriefSerial++;
      homeBrief = null;
      homeBriefLoading = false;
      homeBriefError = null;
      selectedGuru = null;
      selectedQuarter = '';
      entryEvidence = null;
      opportunitySerial++;
      opportunityDetailSerial++;
      opportunities = null;
      opportunityReturnDate = '';
      opportunityCompany = null;
      opportunityEvents = null;
      watchComparison = null;
      opportunityQuarter = '';
      opportunityCutoff = '';
      opportunityLoading = false;
      opportunityDetailLoading = false;
      if (page == 'research' && ticker.isNotEmpty) {
        if (wasReview) {
          // openReview uses the guarded command wrapper; reopen after this one.
          notice = w(
            'Date changed. Reopen the saved decision from Portfolio.',
            '日期已更新，请从组合重新打开已保存决策。',
          );
          navigate('book');
        } else {
          await loadCompany(ticker);
        }
      } else {
        navigate(page);
      }
    });
  }

  void showWorkspacePreferences() {
    var cb = widget.colorBlind;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: p.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: p.border),
          ),
          title: Text(
            w('Workspace preferences & account', '工作区偏好与账户'),
            style: TextStyle(
              color: p.text,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141417),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.verified_user_outlined, color: p.accent, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w('Signed-in session', '当前登录账户'),
                              style: TextStyle(color: p.muted, fontSize: 11),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.localPreview
                                  ? w('Local preview mode', '本地开发预览')
                                  : (widget.userEmail.trim().isNotEmpty
                                        ? widget.userEmail.trim()
                                        : w('Authenticated investor', '已认证账户')),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.onToggleColorBlind != null)
                  SwitchListTile.adaptive(
                    key: const ValueKey('toggle-color-blind-mode'),
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: p.accent,
                    title: Text(
                      w('Color-blind safe palette', '色盲友好高区分度配色'),
                      style: TextStyle(color: p.text, fontSize: 13.5),
                    ),
                    subtitle: Text(
                      w(
                        'Replaces red/green pairs with high-contrast blue/orange cues.',
                        '使用蓝/橙高对比视觉色替代红绿语义对比。',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 11.5),
                    ),
                    value: cb,
                    onChanged: (next) {
                      setModalState(() => cb = next);
                      widget.onToggleColorBlind!(next);
                    },
                  ),
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        w('Interface language', '界面语言'),
                        style: TextStyle(color: p.text, fontSize: 13.5),
                      ),
                    ),
                    SegmentedButton<AppLanguage>(
                      segments: const [
                        ButtonSegment(value: AppLanguage.en, label: Text('EN')),
                        ButtonSegment(value: AppLanguage.zh, label: Text('中文')),
                      ],
                      selected: {context.language},
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) {
                          widget.onLanguage(s.first);
                          Navigator.pop(ctx);
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                showMethodology();
              },
              child: Text(w('Sources & methodology', '来源与方法')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(w('Done', '完成')),
            ),
          ],
        ),
      ),
    );
  }

  void showMethodology() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.panel,
      title: Text(
        w('Sources & methodology', '来源与方法'),
        style: TextStyle(color: p.text),
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label(
                'Historical PIT research. Published blended fair value and your standalone parent FCFE scenario are different calculations.',
                '历史 PIT 研究。已发布综合估值与个人母公司 FCFE 情景是两个不同计算。',
                size: 15,
              ),
              const SizedBox(height: 16),
              label(
                'FCFE is discounted at Ke over five forward years, with year-end discounting and Gordon terminal value. Do not deduct debt or minority ownership again.',
                '未来五年 FCFE 以 Ke 年末折现，使用永续增长终值，不重复扣除债务或少数权益。',
                size: 15,
              ),
              const SizedBox(height: 16),
              label(
                '13F reports holdings with a delay, not investment intent. Decisions here are research records, not live orders. Missing data is never zero.',
                '13F 是滞后持仓披露，不代表投资意图。此处决策是研究记录，不是实盘订单。缺失数据不等于零。',
                size: 15,
              ),
              if (company != null) ...[
                const SizedBox(height: 16),
                label('Snapshot / source lineage', '快照与数据来源链'),
                const SizedBox(height: 6),
                for (final entry in <(String, String)>[
                  (
                    w('Dataset', '数据集'),
                    context.ui(
                      text(
                        asMap(asMap(company?['snapshot'])['source'])['dataset'],
                        '—',
                      ),
                    ),
                  ),
                  (
                    w('Period end', '报告期末'),
                    text(asMap(company?['snapshot'])['periodEnd'], '—'),
                  ),
                  (
                    w('Disclosed / available', '公开可见日'),
                    text(asMap(company?['snapshot'])['availableAt'], '—'),
                  ),
                  (
                    w('Model version', '模型版本'),
                    text(
                      asMap(asMap(company?['snapshot'])['source'])['modelVersion'],
                      '—',
                    ),
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${entry.$1}：${entry.$2}',
                      style: TextStyle(color: p.muted, fontSize: 12.5),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(w('Close', '关闭')),
        ),
      ],
    ),
  );

  List<Widget> graphiteResearch() => refinedResearch();

  Widget metricDisplay(
    String value,
    String en,
    String zh, {
    String? detail,
    double size = 38,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: TextStyle(
          fontSize: size,
          height: 1.2,
          color: p.text,
          fontWeight: FontWeight.w700,
          letterSpacing: context.isChinese ? 0 : -.8,
        ),
      ),
      const SizedBox(height: 6),
      label(en, zh, size: 16),
      if (detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(detail, style: TextStyle(color: p.muted, fontSize: 13)),
        ),
    ],
  );

  Widget scenarioPanel() {
    final reverse = asMap(calculation?['reverse']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title('Your scenario', '你的情景'),
        Padding(
          key: const ValueKey('valuation-live-result'),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w(
                  'Your DCF · ${money(asMap(calculation?['result'])['fairValue'])}',
                  '你的 DCF · ${money(asMap(calculation?['result'])['fairValue'])}',
                ),
                style: TextStyle(
                  color: p.accent,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              label(
                'Reference · ${money(valuationReference?['fairValue'])} / share',
                '对照 · ${money(valuationReference?['fairValue'])} / 股',
                size: 12,
              ),
              const SizedBox(height: 4),
              label(
                'Updates as you edit · separate from platform value',
                '随输入自动重算 · 与平台估值分开',
                size: 11,
              ),
            ],
          ),
        ),
        // Keep the editor's sibling positions stable when the first keystroke
        // changes a saved scenario into a draft; otherwise Flutter drops focus.
        Padding(
          padding: EdgeInsets.only(bottom: draftDirty ? 10 : 0),
          child: worksheetMemoryEnabled
              ? worksheetSaveIndicator()
              : draftDirty
              ? label(
                  'Unsaved changes · sandbox only',
                  '未保存修改 · 仅为试算',
                  color: p.secondary,
                  size: 12,
                )
              : const SizedBox.shrink(),
        ),
        if (asList(company?['scenarios']).isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              w(
                'Saved versions (${asList(company?['scenarios']).length})',
                '已存版本（${asList(company?['scenarios']).length}）',
              ),
            ),
            children: [
              for (final saved in asList(company?['scenarios']).reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${saved['name']} · v${saved['version']}'),
                  subtitle: Text(text(saved['asOf'])),
                  onTap: () => unawaited(restorePersonalVersion(saved)),
                ),
            ],
          ),
        if (independentValuation)
          label(
            'Editable starting forecast · separate from platform value',
            '可编辑起始预测 · 与平台估值分开',
            size: 12,
            color: p.accent,
          ),
        if (!independentValuation && personalDcfMethod == 'parent_fcfe')
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                for (final name in ['Bear', 'Base', 'Bull'])
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: template == name
                            ? p.accent.withValues(alpha: .36)
                            : Colors.transparent,
                        foregroundColor: template == name ? p.text : p.muted,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        minimumSize: const Size(40, 38),
                      ),
                      onPressed: () {
                        calculationTimer?.cancel();
                        calculationSerial++;
                        updateUI(() {
                          template = name;
                          scenarioName.text = w(
                            name,
                            {
                                  'Bear': '悲观情景',
                                  'Base': '基准情景',
                                  'Bull': '乐观情景',
                                }[name] ??
                                name,
                          );
                          assumptions = asMap(
                            asMap(company?['templates'])[name],
                          );
                          scenarioId = null;
                          ownership = false;
                          draftDirty = true;
                          calculation = null;
                          notice = null;
                        });
                        fillAssumptions();
                        scheduleWorksheetSave();
                        unawaited(recalculate());
                      },
                      child: Text(
                        w(
                          name,
                          {'Bear': '悲观', 'Base': '基准', 'Bull': '乐观'}[name]!,
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Divider(color: p.border),
        const SizedBox(height: 10),
        input(
          scenarioName,
          'Scenario name',
          '情景名称',
          width: double.infinity,
          changed: (_) => editHypothesisMetadata(),
        ),
        const SizedBox(height: 14),
        scenarioRate(
          personalDcfMethod == 'operating_fcff' ? wacc : ke,
          personalDcfMethod == 'operating_fcff'
              ? 'Weighted average cost of capital (WACC)'
              : 'Cost of equity (Ke)',
          personalDcfMethod == 'operating_fcff'
              ? '加权平均资本成本 (WACC)'
              : '股权资本成本 (Ke)',
        ),
        scenarioRate(terminal, 'Terminal growth (g)', '永续增长 (g)'),
        label(
          personalDcfMethod == 'operating_fcff'
              ? 'Model range: g 0%–5%; WACC − g ≥ 1.5pp.'
              : 'Model range: g 0%–5%; Ke − g ≥ 1.5pp.',
          personalDcfMethod == 'operating_fcff'
              ? '模型范围：g 0%–5%；WACC − g ≥ 1.5 个百分点。'
              : '模型范围：g 0%–5%；Ke − g ≥ 1.5 个百分点。',
          size: 11,
        ),
        if (personalDcfMethod == 'operating_fcff') ...[
          const SizedBox(height: 12),
          label(
            'Enterprise-to-equity bridge · ${text(company?['currency'])} millions',
            '企业价值到股权价值桥 · ${text(company?['currency'])} 百万',
            size: 12,
            color: p.accent,
          ),
          input(
            netDebt,
            'Net debt',
            '净债务',
            numeric: true,
            width: double.infinity,
            changed: (_) => scheduleCalculation(),
          ),
          input(
            nci,
            'Non-controlling interests',
            '少数股东权益',
            numeric: true,
            width: double.infinity,
            changed: (_) => scheduleCalculation(),
          ),
          input(
            nonOperatingAssets,
            'Non-operating assets',
            '非经营资产',
            numeric: true,
            width: double.infinity,
            changed: (_) => scheduleCalculation(),
          ),
          label(
            'Zero is an explicit editable assumption, not a verified fact. Review the evidence before saving.',
            '零是明确、可修改的假设，不代表已核验事实；保存前请检查证据。',
            size: 10,
            color: p.secondary,
          ),
        ],
        valuationCalculationState(compact: true),
        const SizedBox(height: 12),
        label(
          'Shares held fixed: ${formatNumber(number(asMap(company?['base'])['sharesM']))}m',
          '固定股数：${formatNumber(number(asMap(company?['base'])['sharesM']))} 百万',
          size: 12,
        ),
        const SizedBox(height: 16),
        Divider(color: p.border),
        const SizedBox(height: 14),
        title('What must I believe?', '价格要求你相信什么？'),
        Text(
          reverse['status'] == 'solved' ? pct(reverse['value']) : '—',
          style: TextStyle(
            color: p.accent,
            fontSize: 28,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 4),
        label(
          reverseVariable == 'growth'
              ? 'Annual revenue growth for $forecastHorizon years · at ${targetReturn.text}% required return'
              : personalDcfMethod == 'operating_fcff'
              ? reverseVariable == 'mature_ebit_margin'
                    ? 'Required mature EBIT margin · at ${targetReturn.text}% WACC'
                    : 'Required ΔNWC / revenue · at ${targetReturn.text}% WACC'
              : 'Required terminal margin · at ${targetReturn.text}% return',
          reverseVariable == 'growth'
              ? '未来 $forecastHorizon 年每年收入增长 · 要求回报 ${targetReturn.text}%'
              : personalDcfMethod == 'operating_fcff'
              ? reverseVariable == 'mature_ebit_margin'
                    ? '所需成熟期 EBIT 利润率 · WACC ${targetReturn.text}%'
                    : '所需 ΔNWC / 收入 · WACC ${targetReturn.text}%'
              : '所需终值现金流率 · 要求回报 ${targetReturn.text}%',
          size: 13,
        ),
        if (reverse['status'] != 'solved')
          label(
            'Inspect inputs for the solver status and bounds.',
            '展开输入查看求解状态与边界。',
            size: 11,
          ),
        const SizedBox(height: 22),
        button(
          'Save scenario',
          '保存情景',
          calculation == null ? null : () => unawaited(confirmScenario()),
          primary: true,
        ),
        const SizedBox(height: 8),
        label(
          'Private to your account · saved as a new backend version',
          '当前账户专属 · 在后端保存为新版本',
          size: 11,
        ),
        const SizedBox(height: 10),
        button(
          inspectInputs ? 'Hide detailed inputs' : 'Inspect inputs',
          inspectInputs ? '收起详细输入' : '展开输入',
          () => updateUI(() => inspectInputs = !inspectInputs),
          icon: inspectInputs ? Icons.expand_less : Icons.expand_more,
        ),
        if (scenarioId != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: button(
              review != null ? 'Return to review' : 'Continue to decision',
              review != null ? '返回复核' : '继续决策',
              () => selectSection(review != null ? 'review' : 'decision'),
            ),
          ),
        const SizedBox(height: 20),
        label(
          'Assumptions are yours. Calculations are traceable.',
          '假设由你负责，计算可以追溯。',
          size: 12,
        ),
        const SizedBox(height: 14),
        Divider(color: p.border),
        TextButton.icon(
          onPressed: showMethodology,
          icon: const Icon(Icons.expand_more, size: 19),
          label: Text(
            w('Sources & methodology', '来源与方法'),
            style: TextStyle(color: p.muted, fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget scenarioRate(TextEditingController c, String en, String zh) => Padding(
    key: ValueKey('scenario-rate-$en'),
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: label(en, zh, size: 16)),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: Semantics(
            label: w(en, zh),
            child: TextField(
              key: ValueKey('compact-$en'),
              controller: c,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (_) => scheduleCalculation(),
              style: TextStyle(color: p.text, fontSize: 16),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 2,
                ),
                hintText: w(en, zh),
                suffixText: '%',
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: valuationRateProblem(c) != null
                        ? p.negative
                        : p.muted,
                  ),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: valuationRateProblem(c) != null
                        ? p.negative
                        : p.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> confirmScenario() async {
    var confirmed = false;
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, dialogSetState) => AlertDialog(
          backgroundColor: p.panel,
          title: Text(
            w('Save a scenario version', '保存情景版本'),
            style: TextStyle(color: p.text),
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  input(
                    scenarioName,
                    'Scenario name',
                    '情景名称',
                    width: 460,
                    changed: (_) => editHypothesisMetadata(),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: confirmed,
                    onChanged: (v) =>
                        dialogSetState(() => confirmed = v ?? false),
                    title: Text(
                      w(
                        personalDcfMethod == 'operating_fcff'
                            ? 'I have reviewed the operating assumptions and the enterprise-to-equity bridge, including net debt and NCI.'
                            : 'I have reviewed parent-common FCFE ownership. Taxes, interest, capex and working capital are already in my FCFE margin.',
                        personalDcfMethod == 'operating_fcff'
                            ? '我已检查经营假设及企业价值到股权价值桥，包括净债务和少数股东权益。'
                            : '我已检查母公司普通股的 FCFE 归属，现金流率已包含税、利息、资本支出和营运资本。',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 14),
                    ),
                  ),
                  label(
                    'This saves an immutable research version. No broker order is sent.',
                    '此操作保存不可变研究版本，不发送券商订单。',
                    size: 12,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(w('Cancel', '取消')),
            ),
            FilledButton(
              onPressed: confirmed ? () => Navigator.pop(ctx, true) : null,
              child: Text(w('Save version', '保存版本')),
            ),
          ],
        ),
      ),
    );
    if (save == true && mounted) {
      updateUI(() => ownership = true);
      await saveScenario();
    }
  }
}
