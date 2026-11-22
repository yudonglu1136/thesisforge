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
  bool get isSnowballMobile =>
      MediaQuery.sizeOf(context).width < 640 && !homeResearchDesk;
  bool get _isSnowballPocketRoute =>
      const {'home', 'holdings', 'income', 'accounts'}.contains(page);

  Widget graphiteBuild(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final desktop = screenWidth >= 1100;
    final snowballMobile = screenWidth < 640;
    final compactDialog = screenWidth < 600;
    final base = Theme.of(context);
    final theme = base.copyWith(
      scaffoldBackgroundColor: p.background,
      dialogTheme: DialogThemeData(
        backgroundColor: p.panel,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compactDialog ? 14 : 40,
          vertical: 20,
        ),
        actionsPadding: EdgeInsets.fromLTRB(
          compactDialog ? 12 : 20,
          0,
          compactDialog ? 12 : 20,
          14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.border),
        ),
      ),
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
            backgroundColor: desktop ? p.background : const Color(0xFF0D0F14),
            body: SafeArea(
              bottom: desktop,
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
                                snowballMobile && _isSnowballPocketRoute
                                    ? 'snowball-pocket-$asOf'
                                    : 'workflow-$page-${page == 'research' ? '$ticker-$section' : '$discoveryTab-${text(asMap(selectedGuru?['guru'])['id'])}'}-$asOf-${page == 'discover' && MediaQuery.sizeOf(context).width < 1380 ? opportunityMobileDetail : false}',
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (! _isSnowballPocketRoute &&
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
                                    Align(
                                      alignment: Alignment.topCenter,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1620,
                                        ),
                                        child: Padding(
                                          padding: !desktop
                                              ? const EdgeInsets.fromLTRB(
                                                  14,
                                                  10,
                                                  14,
                                                  18,
                                                )
                                              : page == 'discover'
                                              ? const EdgeInsets.fromLTRB(
                                                  26,
                                                  16,
                                                  26,
                                                  26,
                                                )
                                              : const EdgeInsets.fromLTRB(
                                                  28,
                                                  18,
                                                  28,
                                                  28,
                                                ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              if (_isSnowballPocketRoute)
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
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ),
                        if (!desktop) graphiteMobileBottomNavBar(),
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

  List<(String, String, String, IconData, IconData)> get mobileGraphitePages =>
      isSnowballMobile
      ? const [
          (
            'home',
            'Overview',
            '总览',
            Icons.pie_chart_outline_rounded,
            Icons.pie_chart_rounded,
          ),
          (
            'holdings',
            'Holdings',
            '持仓',
            Icons.account_balance_wallet_outlined,
            Icons.account_balance_wallet_rounded,
          ),
          (
            'income',
            'Income',
            '收益',
            Icons.payments_outlined,
            Icons.payments_rounded,
          ),
          (
            'accounts',
            'Account',
            '账户',
            Icons.person_outline_rounded,
            Icons.person_rounded,
          ),
        ]
      : const [
          ('home', 'Home', '首页', Icons.home_outlined, Icons.home_rounded),
          (
            'discover',
            'Discover',
            '发现',
            Icons.explore_outlined,
            Icons.explore_rounded,
          ),
          (
            'research',
            'Research',
            '研究',
            Icons.search_rounded,
            Icons.manage_search_rounded,
          ),
          (
            'book',
            'Portfolio',
            '组合',
            Icons.pie_chart_outline_rounded,
            Icons.pie_chart_rounded,
          ),
          (
            'strategies',
            'Strategies',
            '策略',
            Icons.layers_outlined,
            Icons.layers_rounded,
          ),
        ];

  Widget brand({double size = 20, bool compact = false}) => Row(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 6 : 7),
        child: Image.asset(
          thesisForgeMarkAsset,
          width: compact ? 26 : 28,
          height: compact ? 26 : 28,
        ),
      ),
      SizedBox(width: compact ? 7 : 10),
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            'ThesisForge',
            style: TextStyle(
              color: p.text,
              fontSize: blackEditionPreview ? size - 2 : size,
              fontWeight: FontWeight.w700,
              letterSpacing: -.55,
            ),
          ),
        ),
      ),
    ],
  );

  Widget graphiteRail() => Container(
    width: 204,
    decoration: BoxDecoration(
      color: p.background,
      border: Border(right: BorderSide(color: p.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 16, 14),
          child: brand(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: Material(
            color: p.card,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: const ValueKey('global-search-trigger'),
              onTap: () => unawaited(openGlobalCompanySearch()),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: p.muted, size: 15),
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
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: p.panel,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: p.border),
                      ),
                      child: Text(
                        '⌘K',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 10,
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
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Material(
                      color: page == item.$1
                          ? blackEditionPreview
                                ? const Color(0xFF171717)
                                : p.accent.withValues(alpha: .17)
                          : Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                        side: page == item.$1 && blackEditionPreview
                            ? BorderSide(color: p.border)
                            : BorderSide.none,
                      ),
                      child: InkWell(
                        onTap: () => unawaited(requestNavigate(item.$1)),
                        borderRadius: BorderRadius.circular(7),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9.5,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.$4,
                                color: page == item.$1
                                    ? blackEditionPreview
                                          ? p.accent
                                          : p.accent
                                    : p.muted,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  w(item.$2, item.$3),
                                  style: TextStyle(
                                    color: page == item.$1 ? p.text : p.muted,
                                    fontSize: 13.5,
                                    fontWeight: page == item.$1
                                        ? FontWeight.w600
                                        : FontWeight.w500,
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
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.border.withValues(alpha: .6))),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message: widget.localPreview
                    ? w('Local preview mode', '本地开发预览')
                    : (widget.userEmail.trim().isNotEmpty
                          ? '${w('Signed in as', '当前登录')} ${widget.userEmail.trim()} · ${w('Click to switch account', '点击切换或退出账号')}'
                          : w('Click to view account & switch', '点击查看或切换账号')),
                child: Material(
                  color: p.card,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: p.border),
                  ),
                  child: InkWell(
                    key: const ValueKey('rail-active-account-card'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: showWorkspacePreferences,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: .16),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              (widget.userEmail.trim().isNotEmpty
                                      ? widget.userEmail.trim().substring(0, 1)
                                      : 'U')
                                  .toUpperCase(),
                              style: TextStyle(
                                color: p.accent,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.localPreview
                                      ? w('Local Workspace', '本地工作区')
                                      : (widget.userEmail.trim().isNotEmpty
                                            ? widget.userEmail.trim()
                                            : w('Signed in', '已登录账户')),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  widget.showAdmin
                                      ? w('Admin · Switch account', '管理员 · 切换账号')
                                      : w('Switch / Sign out', '切换账号 / 偏好'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: p.muted, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.swap_horiz_rounded, size: 15, color: p.muted),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => widget.onLanguage(
                      context.language == AppLanguage.en
                          ? AppLanguage.zh
                          : AppLanguage.en,
                    ),
                    child: Text(
                      context.language == AppLanguage.en ? '中文' : 'EN',
                      style: TextStyle(color: p.muted, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('workspace-preferences-button'),
                    visualDensity: VisualDensity.compact,
                    tooltip: w('Preferences & account', '偏好与账户'),
                    onPressed: showWorkspacePreferences,
                    icon: Icon(Icons.tune_outlined, color: p.muted, size: 17),
                  ),
                  if (widget.onLogout != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: w('Sign out', '退出登录'),
                      onPressed: () => unawaited(requestLogout()),
                      icon: Icon(Icons.logout, color: p.muted, size: 17),
                    ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: showMethodology,
                  icon: Icon(Icons.description_outlined, color: p.muted, size: 15),
                  label: Text(
                    w('Sources & methodology', '来源与方法'),
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _snowballHeaderTitle() {
    switch (page) {
      case 'holdings':
        return w('Holdings', '持仓明细');
      case 'income':
        return w('Realized & Income', '收益账本');
      case 'accounts':
        return w('Account & Security', '账户与安全');
      case 'home':
      default:
        return 'ThesisForge';
    }
  }

  Widget graphiteMobileHeader() {
    final replay = isHistoricalReplay;
    final snowball = isSnowballMobile && _isSnowballPocketRoute;
    final statusTint = replay
        ? const Color(0xFFF5A623)
        : const Color(0xFF20C997);
    return Container(
      key: const ValueKey('ios-mobile-top-header'),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0F14),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: .045),
            width: 0.6,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                thesisForgeMarkAsset,
                width: 27,
                height: 27,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  snowball ? _snowballHeaderTitle() : 'ThesisForge',
                  style: TextStyle(
                    color: p.text,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('mobile-date-control'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: showDateDialog,
                  child: Center(
                    widthFactor: 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: statusTint.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusTint,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4.5),
                          Text(
                            replay ? asOf.substring(5) : w('Live', '实时'),
                            maxLines: 1,
                            style: TextStyle(
                              color: statusTint,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (snowball)
              ValueListenableBuilder<bool>(
                valueListenable: portfolioPrivacyMode,
                builder: (_, hidden, _) => IconButton(
                  key: const ValueKey('mobile-header-privacy-toggle'),
                  tooltip: hidden
                      ? w('Show amounts', '显示金额')
                      : w('Hide amounts', '隐藏金额'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: () =>
                      portfolioPrivacyMode.value = !portfolioPrivacyMode.value,
                  icon: Container(
                    width: 35,
                    height: 35,
                    decoration: BoxDecoration(
                      color: const Color(0xFF171C26),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .06),
                      ),
                    ),
                    child: Icon(
                      hidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: hidden ? const Color(0xFF34D399) : p.text,
                      size: 17,
                    ),
                  ),
                ),
              )
            else
              IconButton(
                key: const ValueKey('mobile-search-trigger'),
                tooltip: w('Search ticker', '搜索公司'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: () => unawaited(openGlobalCompanySearch()),
                icon: Container(
                  width: 35,
                  height: 35,
                  decoration: BoxDecoration(
                    color: const Color(0xFF171C26),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .06),
                    ),
                  ),
                  child: Icon(Icons.search_rounded, color: p.text, size: 18),
                ),
              ),
            IconButton(
              key: const ValueKey('mobile-account-sheet-button'),
              tooltip: w('Account & settings', '账户与设置'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              onPressed: showMobileAccountSheet,
              icon: Container(
                width: 35,
                height: 35,
                decoration: BoxDecoration(
                  color: const Color(0xFF171C26),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .06),
                  ),
                ),
                child: Icon(
                  snowball ? Icons.person_outline_rounded : Icons.tune_rounded,
                  color: p.text,
                  size: 17,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> showSetAppPasswordDialog() async {
    final handler = widget.onUpdatePassword;
    if (handler == null) return;
    var draftPassword = '';
    var draftConfirm = '';
    var saving = false;
    var obscure = true;
    String? errMsg;
    var savedOk = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          key: const ValueKey('app-password-dialog'),
          backgroundColor: const Color(0xFF131720),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: .08)),
          ),
          title: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF34D399).withValues(alpha: .14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.face_retouching_natural_rounded,
                  color: Color(0xFF34D399),
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  w('Set Direct App Password', '设置 App 直登密码 (FaceID)'),
                  style: const TextStyle(
                    color: Color(0xFFF8FAFC),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    w(
                      'Sign in directly inside the iPhone Home Screen App in 0.3s with FaceID — no browser jump and no email wait.',
                      '设置后可在手机桌面 App 内「密码直登 · FaceID」0.3 秒进入，彻底告别跳浏览器与等邮件。',
                    ),
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          key: const ValueKey('app-password-input'),
                          onChanged: (v) => draftPassword = v,
                          obscureText: obscure,
                          autofillHints: const [AutofillHints.newPassword],
                          style: const TextStyle(
                            color: Color(0xFFF8FAFC),
                            fontSize: 14.5,
                          ),
                          decoration: InputDecoration(
                            labelText: w('New password (>= 8 chars)', '新直登密码（至少 8 位）'),
                            filled: true,
                            fillColor: const Color(0xFF0D0F14),
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setModalState(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 18,
                                color: const Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('app-password-confirm-input'),
                          onChanged: (v) => draftConfirm = v,
                          obscureText: obscure,
                          autofillHints: const [AutofillHints.newPassword],
                          style: const TextStyle(
                            color: Color(0xFFF8FAFC),
                            fontSize: 14.5,
                          ),
                          decoration: InputDecoration(
                            labelText: w('Confirm password', '再次确认新密码'),
                            filled: true,
                            fillColor: const Color(0xFF0D0F14),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (errMsg != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errMsg!,
                      style: const TextStyle(
                        color: Color(0xFFFB7185),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (savedOk) ...[
                    const SizedBox(height: 10),
                    Text(
                      w(
                        'Direct App password enabled! iOS FaceID can save it on your next sign-in.',
                        'App 直登密码已生效！下次可直接在 App 内刷 FaceID 秒登。',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: Text(savedOk ? w('Done', '完成') : w('Cancel', '取消')),
            ),
            if (!savedOk)
              FilledButton(
                key: const ValueKey('app-password-submit'),
                onPressed: saving
                    ? null
                    : () async {
                        final p1 = draftPassword.trim();
                        final p2 = draftConfirm.trim();
                        if (p1.length < 8) {
                          setModalState(
                            () => errMsg = w(
                              'Password must be at least 8 characters.',
                              '密码长度至少需要 8 位字符。',
                            ),
                          );
                          return;
                        }
                        if (p1 != p2) {
                          setModalState(
                            () => errMsg = w(
                              'Passwords do not match.',
                              '两次输入的密码不一致。',
                            ),
                          );
                          return;
                        }
                        setModalState(() {
                          saving = true;
                          errMsg = null;
                        });
                        try {
                          final resErr = await handler(p1);
                          if (resErr != null && resErr.trim().isNotEmpty) {
                            if (ctx.mounted) {
                              setModalState(() {
                                saving = false;
                                errMsg = resErr;
                              });
                            }
                            return;
                          }
                          TextInput.finishAutofillContext();
                          if (ctx.mounted) {
                            setModalState(() {
                              saving = false;
                              savedOk = true;
                            });
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setModalState(() {
                              saving = false;
                              errMsg = e
                                  .toString()
                                  .replaceFirst('Exception: ', '')
                                  .replaceFirst('Bad state: ', '');
                            });
                          }
                        }
                      },
                child: Text(
                  saving ? w('Saving…', '保存中…') : w('Save Password', '保存直登密码'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> showDevicePairCodeDialog() async {
    final handler = widget.onCreatePairCode;
    if (handler == null) return;
    String? code;
    String? errMsg;
    var loadingCode = true;
    var copied = false;
    var started = false;

    Future<void> mint(StateSetter setModalState) async {
      setModalState(() {
        loadingCode = true;
        errMsg = null;
        copied = false;
      });
      try {
        final next = await handler();
        setModalState(() {
          code = text(next['code']);
          loadingCode = false;
        });
      } catch (e) {
        setModalState(() {
          loadingCode = false;
          errMsg = e
              .toString()
              .replaceFirst('Exception: ', '')
              .replaceFirst('Bad state: ', '');
        });
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          if (!started) {
            started = true;
            Future<void>.microtask(() {
              if (ctx.mounted) unawaited(mint(setModalState));
            });
          }
          final raw = (code ?? '').trim();
          final formatted = raw.length == 6
              ? '${raw.substring(0, 3)} ${raw.substring(3)}'
              : raw;
          return AlertDialog(
            key: const ValueKey('device-pair-code-dialog'),
            backgroundColor: const Color(0xFF131720),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: .08)),
            ),
            title: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.phonelink_lock_rounded,
                    color: Color(0xFF38BDF8),
                    size: 16,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    w('6-Digit App Sign-In Code', '手机 App 6 位数字秒登码'),
                    style: const TextStyle(
                      color: Color(0xFFF8FAFC),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 370),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    w(
                      'Open the ThesisForge App on your iPhone, tap "Have a 6-digit code?", and enter this single-use code within 5 minutes — zero email required.',
                      '打开手机主屏幕 ThesisForge App，点击登录页「已有 6 位数字码？直接输入秒登」并输入下方数字码（5 分钟内单次有效，无需收邮件）。',
                    ),
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D0F14),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF34D399).withValues(alpha: .32),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: loadingCode
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : errMsg != null
                        ? Text(
                            errMsg!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFFB7185),
                              fontSize: 12.5,
                            ),
                          )
                        : SelectableText(
                            formatted,
                            key: const ValueKey('device-pair-code-value'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFF8FAFC),
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 4,
                              fontFeatures: [ui.FontFeature.tabularFigures()],
                            ),
                          ),
                  ),
                  if (raw.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('device-pair-code-copy'),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: raw));
                        if (ctx.mounted) {
                          setModalState(() => copied = true);
                        }
                      },
                      icon: Icon(
                        copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 16,
                      ),
                      label: Text(
                        copied
                            ? w('Copied 6-digit code', '已复制 6 位数字码')
                            : w('Copy 6-digit code', '复制 6 位数字码'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loadingCode ? null : () => unawaited(mint(setModalState)),
                child: Text(w('Refresh code', '重新生成')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(w('Close', '关闭')),
              ),
            ],
          );
        },
      ),
    );
  }

  void showMobileAccountSheet() {
    var cb = widget.colorBlind;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.88,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              key: const ValueKey('mobile-account-bottom-sheet'),
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E3A4B),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF080B0F),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: .14),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.verified_user_outlined,
                              color: p.accent,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
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
                                            : w(
                                                'Authenticated investor',
                                                '已认证账户',
                                              )),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SegmentedButton<AppLanguage>(
                            key: const ValueKey('sheet-language-toggle'),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: const [
                              ButtonSegment(
                                value: AppLanguage.zh,
                                label: Text('中文'),
                              ),
                              ButtonSegment(
                                value: AppLanguage.en,
                                label: Text('EN'),
                              ),
                            ],
                            selected: {context.language},
                            onSelectionChanged: (s) {
                              if (s.isNotEmpty) {
                                widget.onLanguage(s.first);
                                Navigator.pop(sheetCtx);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (widget.onUpdatePassword != null)
                      ListTile(
                        key: const ValueKey('sheet-set-app-password'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: const Icon(
                          Icons.face_retouching_natural_rounded,
                          color: Color(0xFF34D399),
                          size: 20,
                        ),
                        title: Text(
                          w(
                            'Set App Direct Password (FaceID)',
                            '设置 App 直登密码（开启 FaceID 秒登）',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: p.muted,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          unawaited(showSetAppPasswordDialog());
                        },
                      ),
                    if (widget.onCreatePairCode != null)
                      ListTile(
                        key: const ValueKey('sheet-show-pair-code'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: const Icon(
                          Icons.phonelink_lock_rounded,
                          color: Color(0xFF38BDF8),
                          size: 20,
                        ),
                        title: Text(
                          w(
                            'Generate 6-Digit App Sign-In Code',
                            '生成其他设备 6 位数字登录码',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: p.muted,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          unawaited(showDevicePairCodeDialog());
                        },
                      ),
                    ListTile(
                      key: const ValueKey('sheet-date-picker'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        Icons.history_toggle_off_rounded,
                        color: isHistoricalReplay
                            ? const Color(0xFFF5A623)
                            : p.accent,
                        size: 20,
                      ),
                      title: Text(
                        w('Information cutoff / PIT replay', '信息截止日与历史时点回放'),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        isHistoricalReplay
                            ? '${w('Replaying', '历史回放')} $asOf'
                            : '${w('Live', '实时最新数据')} ($asOf)',
                        style: TextStyle(color: p.muted, fontSize: 11.5),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        color: p.muted,
                        size: 20,
                      ),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        unawaited(showDateDialog());
                      },
                    ),
                    if (widget.onToggleColorBlind != null)
                      SwitchListTile.adaptive(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        activeThumbColor: p.accent,
                        title: Text(
                          w('Color-blind safe palette', '色盲友好高对比配色'),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        value: cb,
                        onChanged: (next) {
                          setSheetState(() => cb = next);
                          widget.onToggleColorBlind!(next);
                        },
                      ),
                    if (widget.showAdmin && widget.onLegacyView != null)
                      ListTile(
                        key: const ValueKey('sheet-open-admin'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: Icon(
                          Icons.admin_panel_settings_outlined,
                          color: p.muted,
                          size: 20,
                        ),
                        title: Text(
                          w('Admin console', '系统管理后台'),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: p.muted,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          unawaited(requestNavigate('admin'));
                        },
                      ),
                    if (!isStandaloneDisplayMode())
                      ListTile(
                        key: const ValueKey('sheet-install-ios-app'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: Icon(
                          Icons.phone_iphone_rounded,
                          color: p.accent,
                          size: 20,
                        ),
                        title: Text(
                          w(
                            'Install Fullscreen App (.mobileconfig)',
                            '安装 iPhone 纯净全屏客户端 (.mobileconfig)',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: p.muted,
                          size: 20,
                        ),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          unawaited(
                            showIosInstallGuideDialog(context, palette: p),
                          );
                        },
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        Icons.description_outlined,
                        color: p.muted,
                        size: 20,
                      ),
                      title: Text(
                        w('Sources & methodology', '数据来源与方法论'),
                        style: TextStyle(color: p.text, fontSize: 13.5),
                      ),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        showMethodology();
                      },
                    ),
                    if (widget.onLogout != null) ...[
                      const Divider(height: 14),
                      if (widget.onSwitchAccount != null && !isSnowballMobile)
                        ListTile(
                          key: const ValueKey('sheet-switch-account'),
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: Icon(
                            Icons.swap_horiz_rounded,
                            color: p.accent,
                            size: 20,
                          ),
                          title: Text(
                            w(
                              'Switch Google account',
                              '切换其他 Google 账号登录',
                            ),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(sheetCtx);
                            unawaited(requestSwitchAccount());
                          },
                        ),
                      ListTile(
                        key: const ValueKey('sheet-logout'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        leading: Icon(
                          Icons.logout_rounded,
                          color: p.negative,
                          size: 20,
                        ),
                        title: Text(
                          w(
                            'Sign out of current account',
                            '退出当前账号（彻底清除会话）',
                          ),
                          style: TextStyle(
                            color: p.negative,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          unawaited(requestLogout());
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget graphiteMobileBottomNavBar() => Container(
    key: const ValueKey('ios-bottom-nav-bar'),
    decoration: BoxDecoration(
      color: const Color(0xFF11151E),
      border: Border(
        top: BorderSide(
          color: Colors.white.withValues(alpha: .055),
          width: 0.6,
        ),
      ),
    ),
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            for (final item in mobileGraphitePages)
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: ValueKey('mobile-nav-${item.$1}'),
                    onTap: () => unawaited(requestNavigate(item.$1)),
                    child: SizedBox.expand(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 5,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                page == item.$1 ? item.$5 : item.$4,
                                size: 21,
                                color: page == item.$1
                                    ? p.accent
                                    : const Color(0xFF7D8B9D),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                w(item.$2, item.$3),
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  letterSpacing: -0.1,
                                  fontWeight: page == item.$1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: page == item.$1
                                      ? p.accent
                                      : const Color(0xFF7D8B9D),
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
          ],
        ),
      ),
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
            OutlinedButton(
              key: const ValueKey('top-utility-language-toggle'),
              onPressed: () => widget.onLanguage(
                context.language == AppLanguage.en
                    ? AppLanguage.zh
                    : AppLanguage.en,
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                side: BorderSide(color: p.border),
              ),
              child: Text(
                context.language == AppLanguage.en ? '中文' : 'EN',
                style: TextStyle(
                  color: p.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
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
      if (page == 'discover' &&
          const {'aiinsights', 'copycat', 'cta_radar'}.contains(discoveryTab)) {
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
                if (widget.onLogout != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (widget.onSwitchAccount != null) ...[
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const ValueKey('prefs-switch-account'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 38),
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              unawaited(requestSwitchAccount());
                            },
                            icon: Icon(
                              Icons.swap_horiz_rounded,
                              size: 16,
                              color: p.accent,
                            ),
                            label: Text(
                              w('Switch Google account', '切换 Google 账号'),
                              style: TextStyle(color: p.text, fontSize: 12.5),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('prefs-logout'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 38),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            side: BorderSide(color: p.negative.withValues(alpha: .45)),
                          ),
                          onPressed: () {
                            Navigator.pop(ctx);
                            unawaited(requestLogout());
                          },
                          icon: Icon(
                            Icons.logout_rounded,
                            size: 16,
                            color: p.negative,
                          ),
                          label: Text(
                            w('Sign out', '退出当前账号'),
                            style: TextStyle(color: p.negative, fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
                const Divider(height: 20),
                if (widget.onCreatePairCode != null) ...[
                  OutlinedButton.icon(
                    key: const ValueKey('prefs-show-pair-code'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(showDevicePairCodeDialog());
                    },
                    icon: const Icon(
                      Icons.phonelink_lock_rounded,
                      size: 17,
                      color: Color(0xFF38BDF8),
                    ),
                    label: Text(
                      w(
                        'Generate iPhone App 6-Digit Sign-In Code',
                        '生成手机 App 6 位数字登录码',
                      ),
                      style: TextStyle(color: p.text, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (widget.onUpdatePassword != null) ...[
                  OutlinedButton.icon(
                    key: const ValueKey('prefs-set-app-password'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(showSetAppPasswordDialog());
                    },
                    icon: const Icon(
                      Icons.face_retouching_natural_rounded,
                      size: 17,
                      color: Color(0xFF34D399),
                    ),
                    label: Text(
                      w(
                        'Set App Direct Password (FaceID)',
                        '设置 App 直登密码（FaceID 秒登）',
                      ),
                      style: TextStyle(color: p.text, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                OutlinedButton.icon(
                  key: const ValueKey('prefs-install-ios-app'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(showIosInstallGuideDialog(context, palette: p));
                  },
                  icon: Icon(
                    Icons.phone_iphone_rounded,
                    size: 17,
                    color: p.accent,
                  ),
                  label: Text(
                    w(
                      'Install on iPhone Home Screen',
                      '安装到 iPhone 主屏幕（全屏 App）',
                    ),
                    style: TextStyle(color: p.text, fontSize: 13),
                  ),
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
            reverse['status'] == 'outside_bounds'
                ? 'Market price implies assumptions outside realistic solver bounds (very extreme growth/margin). Inspect inputs for solver bounds.'
                : 'Inspect inputs for the solver status and bounds.',
            reverse['status'] == 'outside_bounds'
                ? '当前市场价格隐含的增速或利润率超出了常规合理求解边界（预期极高或极低），可展开输入查看边界详情。'
                : '展开输入查看求解状态与边界。',
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
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
