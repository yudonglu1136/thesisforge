part of 'main.dart';

// Visual shell only. Sources, calculations and the append-only decision ledger
// remain owned by the existing investment workflow and server.
class _GraphitePalette extends Palette {
  _GraphitePalette(super.colorBlind);
  @override
  Color get background => const Color(0xFF0E171F);
  @override
  Color get panel => const Color(0xFF111C25);
  @override
  Color get card => const Color(0xFF17252E);
  @override
  Color get border => const Color(0xFF293A46);
  @override
  Color get accent => colorBlind ? super.accent : const Color(0xFF48DAB3);
  @override
  Color get muted => const Color(0xFFB0BDCC);
}

extension _GraphiteWorkspace on _InvestmentWorkspaceState {
  Widget graphiteBuild(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 1100;
    final base = Theme.of(context);
    final theme = base.copyWith(
      scaffoldBackgroundColor: p.background,
      colorScheme: ColorScheme.dark(
        primary: p.accent,
        onPrimary: p.background,
        surface: p.panel,
        onSurface: p.text,
        outline: p.border,
      ),
      textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
      dividerColor: p.border,
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
          backgroundColor: p.accent,
          foregroundColor: p.background,
          minimumSize: const Size(44, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
        selectedColor: p.accent.withValues(alpha: .20),
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
                    if (busy)
                      LinearProgressIndicator(minHeight: 2, color: p.accent),
                    Expanded(
                      child: SingleChildScrollView(
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
                                      page == 'research' && ticker.isNotEmpty
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
                                    ? const EdgeInsets.fromLTRB(24, 16, 24, 24)
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
                                    if (page == 'home') ...personalHomePage(),
                                    if (page == 'discover') ...discoveryPage(),
                                    if (page == 'research') ...researchView(),
                                    if (page == 'book')
                                      ...researchPortfolioPage(),
                                    if (page == 'strategies') ...strategyPage(),
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
    );
  }

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
        'assets/branding/thesisforge-mark.png',
        width: 32,
        height: 36,
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
              fontSize: size,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
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
          padding: const EdgeInsets.fromLTRB(24, 26, 16, 28),
          child: brand(),
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
                          ? p.accent.withValues(alpha: .17)
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
                                color: page == item.$1 ? p.accent : p.muted,
                                size: 25,
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Text(
                                  w(item.$2, item.$3),
                                  style: TextStyle(
                                    color: page == item.$1 ? p.text : p.muted,
                                    fontSize: 17,
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
          padding: const EdgeInsets.symmetric(horizontal: 20),
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
              Expanded(child: brand(size: 21)),
              TextButton(
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

  Widget dateControl() => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      OutlinedButton.icon(
        onPressed: showDateDialog,
        icon: const Icon(Icons.calendar_today_outlined, size: 18),
        label: Text(
          '${w('As of', '截至')} $asOf',
          style: TextStyle(color: p.text, fontSize: 14),
        ),
      ),
      const SizedBox(height: 7),
      label(
        widget.localPreview
            ? 'Local preview · Historical PIT'
            : 'Historical point-in-time data',
        widget.localPreview ? '本地预览 · 历史 PIT' : '历史时点数据',
        size: 11,
      ),
    ],
  );

  Future<void> showDateDialog() async {
    if (!await allowLeaveDraft() || !mounted) return;
    dateInput.text = asOf;
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(
          w('Information available by', '信息截止日期'),
          style: TextStyle(color: p.text),
        ),
        content: input(dateInput, 'YYYY-MM-DD', '年-月-日', width: 240),
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
    );
    if (apply != true || !mounted) return;
    await command(() async {
      final previous = asOf;
      asOf = dateInput.text;
      await loadHome();
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
                label('Snapshot / source lineage', '快照 / 来源链'),
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(company?['snapshot']),
                  style: TextStyle(color: p.muted, fontSize: 12),
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
          letterSpacing: -.8,
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
        if (!independentValuation)
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
                          scenarioName.text = name;
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
        scenarioRate(ke, 'Cost of equity (Ke)', '股权资本成本 (Ke)'),
        scenarioRate(terminal, 'Terminal growth (g)', '永续增长 (g)'),
        label(
          'Model range: g 0%–5%; Ke − g ≥ 1.5pp.',
          '模型范围：g 0%–5%；Ke − g ≥ 1.5 个百分点。',
          size: 11,
        ),
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
              ? 'Annual revenue growth for 5 years · at ${targetReturn.text}% required return'
              : 'Required terminal margin · at ${targetReturn.text}% return',
          reverseVariable == 'growth'
              ? '未来 5 年每年收入增长 · 要求回报 ${targetReturn.text}%'
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
                        'I have reviewed parent-common FCFE ownership. Taxes, interest, capex and working capital are already in my FCFE margin.',
                        '我已检查母公司普通股的 FCFE 归属，现金流率已包含税、利息、资本支出和营运资本。',
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
