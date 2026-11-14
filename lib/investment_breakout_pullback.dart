part of 'main.dart';

class StrategyPortfolioPanel extends StatefulWidget {
  const StrategyPortfolioPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;

  @override
  State<StrategyPortfolioPanel> createState() => _StrategyPortfolioPanelState();
}

class _StrategyPortfolioPanelState extends State<StrategyPortfolioPanel> {
  String selectedStrategy = 'breakout_pullback';
  bool rulePortfoliosOpened = false;
  Map<String, dynamic>? breakoutSummary;
  Map<String, dynamic>? ruleAllMarketSummary;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.42,
  );

  @override
  void initState() {
    super.initState();
    final query = readBrowserQuery();
    final initial = query['portfolioStrategy'];
    if (const [
      'breakout_pullback',
      'quality_rank',
      'ackman',
    ].contains(initial)) {
      selectedStrategy = initial!;
    }
    rulePortfoliosOpened = selectedStrategy != 'breakout_pullback';
    unawaited(_prefetchRuleSummary());
  }

  @override
  void didUpdateWidget(covariant StrategyPortfolioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(_prefetchRuleSummary());
    }
  }

  Future<void> _prefetchRuleSummary() async {
    try {
      final response = await widget.api.getJson(
        '/api/investment/investor-styles?asOf=${Uri.encodeQueryComponent(widget.asOf)}&universe=all',
      );
      if (!mounted) return;
      setState(() => ruleAllMarketSummary = response);
    } catch (_) {
      // Non-fatal: individual dashboard handles its own retry state if selected.
    }
  }

  void _selectStrategy(String id) {
    if (selectedStrategy == id) return;
    setState(() {
      selectedStrategy = id;
      if (id != 'breakout_pullback') {
        rulePortfoliosOpened = true;
      }
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': id,
    }, replaceCurrent: true);
  }

  String _fmtMult(dynamic v) =>
      nullableNumber(v) == null ? '—' : '${number(v).toStringAsFixed(2)}x';
  String _fmtPct(dynamic v, [int digits = 1]) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(digits)}%';
  String _fmtDec(dynamic v, [int digits = 2]) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(digits);

  Map<String, dynamic> _ruleMetricsFor(String styleId) {
    final styles = asList(ruleAllMarketSummary?['styles']);
    final found = styles.firstWhere(
      (r) => r['id'] == styleId,
      orElse: () => {},
    );
    return asMap(found['metrics']);
  }

  Widget _buildSelectorCard({
    required String id,
    required String categoryLabel,
    required Color accentColor,
    required String title,
    required String subtitle,
    required List<String> statPills,
  }) {
    final isSelected = selectedStrategy == id;
    return Material(
      color: isSelected
          ? accentColor.withValues(alpha: 0.11)
          : p.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('portfolio-card-$id'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _selectStrategy(id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? accentColor : p.border,
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        categoryLabel,
                        overflow: TextOverflow.ellipsis,
                        style: s(10.5, true, accentColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: isSelected ? accentColor : p.muted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(title, style: s(16.5, true)),
              const SizedBox(height: 5),
              Text(subtitle, style: s(12, false, p.muted)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final pill in statPills)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: p.panel.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSelected
                              ? accentColor.withValues(alpha: 0.35)
                              : p.border,
                        ),
                      ),
                      child: Text(pill, style: s(11, true)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final flagMetrics = asMap(
      asMap(asMap(breakoutSummary?['modesSummary'])['flagship'])['metrics'],
    );
    final qMetrics = _ruleMetricsFor('quality_rank');
    final aMetrics = _ruleMetricsFor('ackman');

    final flagPills = flagMetrics.isNotEmpty
        ? [
            '10Y ${_fmtMult(flagMetrics['endingValue'])}',
            'CAGR ${_fmtPct(flagMetrics['cagr'])}',
            'Sharpe ${_fmtDec(flagMetrics['sharpeZeroRf'])}',
            'MDD ${_fmtPct(flagMetrics['maxDrawdown'])}',
            '10 bps',
          ]
        : [
            '10Y 8.91x',
            'CAGR 24.4%',
            'Sharpe 1.03',
            'MDD -29.9%',
            '10 bps',
          ];

    final qualityPills = qMetrics.isNotEmpty
        ? [
            '${w('Nav', '净值')} ${_fmtMult(nullableNumber(qMetrics['totalReturn']) == null ? null : number(qMetrics['totalReturn']) + 1)}',
            'CAGR ${_fmtPct(qMetrics['cagr'])}',
            'Sharpe ${_fmtDec(qMetrics['sharpeZeroRf'])}',
            'MDD ${_fmtPct(qMetrics['maxDrawdown'])}',
            '25 bps',
          ]
        : [
            w('All / S&P 500 / NDX', '全市场 / 标普 / 纳指'),
            w('Top 10 Sqrt Weight', '前 10 信念配权'),
            '25 bps',
          ];

    final ackmanPills = aMetrics.isNotEmpty
        ? [
            '${w('Nav', '净值')} ${_fmtMult(nullableNumber(aMetrics['totalReturn']) == null ? null : number(aMetrics['totalReturn']) + 1)}',
            'CAGR ${_fmtPct(aMetrics['cagr'])}',
            'Sharpe ${_fmtDec(aMetrics['sharpeZeroRf'])}',
            'MDD ${_fmtPct(aMetrics['maxDrawdown'])}',
            '25 bps',
          ]
        : [
            w('All / S&P 500 / NDX', '全市场 / 标普 / 纳指'),
            w('Top 20 Equal 5%', '前 20 等权 5%'),
            '25 bps',
          ];

    final cards = [
      _buildSelectorCard(
        id: 'breakout_pullback',
        categoryLabel: w(
          'DAILY TACTICAL · PRICE & VOLUME',
          'DAILY TACTICAL · 日频量价趋势',
        ),
        accentColor: p.positive,
        title: w('Hot Breakout Pullback', '美股热门股突破浅回撤'),
        subtitle: w(
          'Top 50 Dollar Volume · 63d High Breakout + -5% Limit Pullback (15d) · ATR Stop & Loose Exit',
          'Top 50 成交额龙头 · 破 63 日新高后挂 -5% 浅回撤限价单 · ATR 止损与宽幅止盈',
        ),
        statPills: flagPills,
      ),
      _buildSelectorCard(
        id: 'quality_rank',
        categoryLabel: w(
          'QUARTERLY FUNDAMENTAL · 4-FACTOR',
          'QUARTERLY FUNDAMENTAL · 季度基本面',
        ),
        accentColor: p.accent,
        title: w('Four-Factor Quality · Top 10', '四因子质量排名 · 前十'),
        subtitle: w(
          'Equal-weight percentile of Rev YoY + Op Margin + FCF Margin + 5Y Min Pretax ROIC · Top 10',
          '收入增速 + 营业利润率 + FCF利润率 + 五年最低税前资本回报等权分位 · 前 10 名',
        ),
        statPills: qualityPills,
      ),
      _buildSelectorCard(
        id: 'ackman',
        categoryLabel: w(
          'QUARTERLY FUNDAMENTAL · QUALITY-VALUE',
          'QUARTERLY FUNDAMENTAL · 季度基本面',
        ),
        accentColor: const Color(0xff7eabfa),
        title: w('Ackman Quality-Value · Top 20', 'Ackman 质量价值代理 · 前二十'),
        subtitle: w(
          '40% Quality + 30% Valuation + 30% Margin & Net Payout Improvement · Top 20 at 5% each',
          '40% 质量 + 30% 估值 + 30% 利润率与净回购改善 · 前 20 名各占 5%',
        ),
        statPills: ackmanPills,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Strategy Portfolio', 'Strategy Portfolio · 策略组合'),
                    key: const ValueKey('strategy-portfolio-heading'),
                    style: s(23, true),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      w('3 Audited Model Portfolios', '3 套实证规则模型组合'),
                      style: s(11, true, p.accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                w(
                  'Institutional rule-based model portfolios · Select one strategy card below to inspect its dedicated controls, 5-step execution blueprint, audited backtest, range attribution, and live holdings/signals without cross-strategy confusion.',
                  '机构级规则化模型组合 · 点击下方任一策略名片卡，独立检视其专属参数开关、五步执行蓝图、实证净值曲线、区间逐股归因与当前持仓/观察池信号（互不干扰）。',
                ),
                style: s(12.5, false, p.muted),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 980) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[1]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[2]),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      cards[0],
                      const SizedBox(height: 10),
                      cards[1],
                      const SizedBox(height: 10),
                      cards[2],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Offstage(
          offstage: selectedStrategy != 'breakout_pullback',
          child: BreakoutPullbackDashboard(
            api: widget.api,
            palette: p,
            asOf: widget.asOf,
            onCompany: widget.onCompany,
            onSummaryLoaded: (payload) {
              if (!mounted) return;
              if (breakoutSummary?['snapshotId'] != payload['snapshotId']) {
                setState(() => breakoutSummary = payload);
              }
            },
          ),
        ),
        if (rulePortfoliosOpened)
          Offstage(
            offstage: selectedStrategy == 'breakout_pullback',
            child: InvestorStylesDashboard(
              api: widget.api,
              palette: p,
              asOf: widget.asOf,
              onCompany: widget.onCompany,
              focusedStyleId: selectedStrategy == 'ackman'
                  ? 'ackman'
                  : 'quality_rank',
              onDataLoaded: (payload) {
                if (!mounted) return;
                setState(() => ruleAllMarketSummary = payload);
              },
            ),
          ),
      ],
    );
  }
}

class BreakoutPullbackDashboard extends StatefulWidget {
  const BreakoutPullbackDashboard({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    this.onSummaryLoaded,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;
  final ValueChanged<Map<String, dynamic>>? onSummaryLoaded;

  @override
  State<BreakoutPullbackDashboard> createState() =>
      _BreakoutPullbackDashboardState();
}

class _BreakoutPullbackDashboardState extends State<BreakoutPullbackDashboard> {
  Map<String, dynamic>? data;
  bool loading = true;
  bool failed = false;
  bool drawdown = false;
  String mode = 'flagship';
  String bookTab = 'holdings';
  String tradeYearFilter = 'all';
  String tradeReasonFilter = 'all';
  String tradeSearch = '';
  int tradeLimit = 40;
  int epoch = 0;
  int hover = -1;
  RangeValues range = const RangeValues(0, 1);
  String? savedStart;
  String? savedEnd;
  final Set<String> enabledCurves = {'flagship', 'balanced', 'qqq', 'spy'};

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.42,
  );

  @override
  void initState() {
    super.initState();
    final q = readBrowserQuery();
    if (const ['flagship', 'balanced'].contains(q['breakoutMode'])) {
      mode = q['breakoutMode']!;
    }
    savedStart = q['breakoutFrom'];
    savedEnd = q['breakoutTo'];
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant BreakoutPullbackDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(load());
    }
  }

  Future<void> load() async {
    final request = ++epoch;
    final requestedMode = mode;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final response = await widget.api.getJson(
        '/api/investment/breakout-pullback?asOf=${Uri.encodeQueryComponent(widget.asOf)}&mode=$requestedMode',
      );
      if (!mounted || request != epoch) return;
      widget.onSummaryLoaded?.call(response);
      final curve = asList(asMap(response['backtest'])['curve']);
      setState(() {
        data = response;
        loading = false;
        hover = -1;
        range = _restoreRange(curve);
      });
    } catch (_) {
      if (!mounted || request != epoch) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  RangeValues _restoreRange(List<Map<String, dynamic>> curve) {
    if (curve.length < 2 || savedStart == null || savedEnd == null) {
      return const RangeValues(0, 1);
    }
    final first = curve.indexWhere(
      (r) => text(r['date']).compareTo(savedStart!) >= 0,
    );
    final last = curve.lastIndexWhere(
      (r) => text(r['date']).compareTo(savedEnd!) <= 0,
    );
    if (first < 0 || last <= first) return const RangeValues(0, 1);
    return RangeValues(first / (curve.length - 1), last / (curve.length - 1));
  }

  void _switchMode(String nextMode) {
    if (nextMode == mode) return;
    setState(() {
      mode = nextMode;
      tradeLimit = 40;
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'breakout_pullback',
      'breakoutMode': nextMode,
    }, replaceCurrent: true);
    unawaited(load());
  }

  void _changeRange(RangeValues value, List<Map<String, dynamic>> curve) {
    final first = (value.start * (curve.length - 1)).round();
    final last = (value.end * (curve.length - 1)).round();
    if (first >= last) return;
    setState(() {
      range = value;
      hover = -1;
      savedStart = text(curve[first]['date']);
      savedEnd = text(curve[last]['date']);
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'breakout_pullback',
      'breakoutMode': mode,
      'breakoutFrom': savedStart,
      'breakoutTo': savedEnd,
    }, replaceCurrent: true);
  }

  Future<void> _pickBoundary(
    List<Map<String, dynamic>> curve,
    bool beginning,
  ) async {
    final requestEpoch = epoch;
    final first = (range.start * (curve.length - 1)).round();
    final last = (range.end * (curve.length - 1)).round();
    final minimum = DateTime.parse(
      text(curve[beginning ? 0 : first + 1]['date']),
    );
    final maximum = DateTime.parse(
      text(curve[beginning ? last - 1 : curve.length - 1]['date']),
    );
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(
        text(curve[beginning ? first : last]['date']),
      ),
      firstDate: minimum,
      lastDate: maximum,
      helpText: beginning
          ? w('Select start date', '选择起始日期')
          : w('Select end date', '选择结束日期'),
      cancelText: w('Cancel', '取消'),
      confirmText: w('Apply', '应用'),
      selectableDayPredicate: (d) =>
          curve.any((r) => r['date'] == d.toIso8601String().substring(0, 10)),
    );
    if (!mounted || day == null || requestEpoch != epoch) return;
    final index = curve.indexWhere(
      (r) => r['date'] == day.toIso8601String().substring(0, 10),
    );
    if (index < 0) return;
    _changeRange(
      RangeValues(
        (beginning ? index : first) / (curve.length - 1),
        (beginning ? last : index) / (curve.length - 1),
      ),
      curve,
    );
  }

  Color _curveColor(String id) => switch (id) {
    'flagship' => p.positive,
    'balanced' => p.accent,
    'qqq' => const Color(0xffb589ff),
    _ => p.secondary,
  };

  String _curveName(String id) => switch (id) {
    'flagship' => w('Flagship · 8.91x', '进攻旗舰版 · 8.91x'),
    'balanced' => w('Balanced · 7.54x', '高夏普稳健版 · 7.54x'),
    'qqq' => 'QQQ',
    _ => 'SPY',
  };

  String _pct(dynamic v, [int digits = 2]) => nullableNumber(v) == null
      ? '—'
      : '${number(v) >= 0 ? '+' : ''}${(number(v) * 100).toStringAsFixed(digits)}%';

  String _pctUnsigned(dynamic v, [int digits = 2]) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(digits)}%';

  String _dec(dynamic v, [int digits = 2]) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(digits);

  String _mult(dynamic v) =>
      nullableNumber(v) == null ? '—' : '${number(v).toStringAsFixed(2)}x';

  String _price(dynamic v) =>
      nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(2)}';

  String _bilingual(dynamic node) {
    final m = asMap(node);
    if (m.isEmpty) return text(node);
    return context.tr(text(m['zh']), text(m['en']));
  }

  String _exitReasonLabel(String reason) => switch (reason) {
    'Trailing_TakeProfit' => w('Chandelier 4x ATR Profit', '4.0x ATR 吊灯止盈'),
    'Target_TakeProfit' => w('+25% Target Profit', '+25% 目标止盈'),
    'Hard_StopLoss' => w('ATR Hard Stop-Loss', 'ATR 硬止损'),
    'Time_Backstop_180d' => w('180d Time Backstop', '180 日时间兜底'),
    'Delist_Liquidation' => w('Delisting Liquidation', '退市末日清算'),
    'Open_Position' => w('Open Position', '当前持仓中'),
    _ => reason,
  };

  Color _exitReasonColor(String reason) => switch (reason) {
    'Trailing_TakeProfit' || 'Target_TakeProfit' => p.positive,
    'Hard_StopLoss' => p.negative,
    'Open_Position' => p.accent,
    _ => p.secondary,
  };

  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.border),
    ),
    child: child,
  );

  Widget _moduleHeader(String step, String enTitle, String zhTitle) => Row(
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _curveColor(mode).withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(step, style: s(12, true, _curveColor(mode))),
      ),
      const SizedBox(width: 9),
      Expanded(child: Text(w(enTitle, zhTitle), style: s(18.5, true))),
    ],
  );

  Widget _buildModeSwitchBar() {
    final modesSummary = asMap(data?['modesSummary']);
    final fMetrics = asMap(asMap(modesSummary['flagship'])['metrics']);
    final bMetrics = asMap(asMap(modesSummary['balanced'])['metrics']);

    Widget modeOption({
      required String id,
      required String title,
      required String desc,
      required List<String> tags,
      required Color accent,
    }) {
      final selected = mode == id;
      return Material(
        color: selected ? accent.withValues(alpha: 0.12) : p.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('breakout-mode-$id'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _switchMode(id),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? accent : p.border,
                width: selected ? 1.8 : 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: selected ? accent : p.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(title, style: s(15, true))),
                  ],
                ),
                const SizedBox(height: 5),
                Text(desc, style: s(12, false, p.muted)),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: p.panel,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: p.border),
                        ),
                        child: Text(t, style: s(11, true, accent)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final optFlagship = modeOption(
      id: 'flagship',
      accent: p.positive,
      title: w(
        'Offensive Flagship · 8.91x Champion',
        '进攻旗舰版 · 8.91x 总收益冠军',
      ),
      desc: w(
        'Top 50 20d Dollar Volume + 63d High Breakout + -5% Pullback Limit (15d) + 2.5x ATR14 Stop + 4.0x ATR14 Chandelier Exit',
        'Top 50 成交额龙头 + 63 日新高 + 回撤 5% 限价挂单(15日窗口) + 2.5x ATR14 硬止损 + 4.0x ATR14 吊灯止盈',
      ),
      tags: [
        '${w('Multiple', '累计净值')} ${fMetrics.isNotEmpty ? _mult(fMetrics['endingValue']) : '8.91x'}',
        'CAGR ${fMetrics.isNotEmpty ? _pctUnsigned(fMetrics['cagr'], 1) : '24.4%'}',
        'Sharpe ${fMetrics.isNotEmpty ? _dec(fMetrics['sharpeZeroRf']) : '1.03'}',
        'MDD ${fMetrics.isNotEmpty ? _pctUnsigned(fMetrics['maxDrawdown'], 1) : '-29.9%'}',
      ],
    );

    final optBalanced = modeOption(
      id: 'balanced',
      accent: p.accent,
      title: w(
        'High-Sharpe Defensive · 7.54x Balanced',
        '高夏普稳健版 · 7.54x 抗跌优选',
      ),
      desc: w(
        'Top 100 Dollar Volume & Close > MA50 > MA200 + 63d Breakout + -5% Pullback Limit (15d) + 3.5x ATR14 Stop + +25% Target (180d)',
        'Top 100 成交额且 Close > MA50 > MA200 + 63 日新高 + 回撤 5% 挂单 + 3.5x ATR14 止损 + +25% 目标止盈(180日兜底)',
      ),
      tags: [
        '${w('Multiple', '累计净值')} ${bMetrics.isNotEmpty ? _mult(bMetrics['endingValue']) : '7.54x'}',
        'Sharpe ${bMetrics.isNotEmpty ? _dec(bMetrics['sharpeZeroRf']) : '1.12'}',
        'MDD ${bMetrics.isNotEmpty ? _pctUnsigned(bMetrics['maxDrawdown'], 1) : '-22.3%'}',
        w('2022 Bear: -3.6%', '2022 熊市仅 -3.6%'),
      ],
    );

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Strategy Mode Switch', '策略版本切换 · 双模式内嵌'),
                style: s(16, true),
              ),
              Text(
                w(
                  'Dedicated to Hot Breakout Pullback · Both modes use 10 equal-weight slots, 10 bps cost & zero survivorship bias',
                  '仅作用于热门股突破浅回撤策略 · 两版本均为 10 等权槽位、双边 10 bps 成本、0 幸存者偏差',
                ),
                style: s(11.5, false, p.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 820) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: optFlagship),
                    const SizedBox(width: 12),
                    Expanded(child: optBalanced),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  optFlagship,
                  const SizedBox(height: 10),
                  optBalanced,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBlueprintModule() {
    final activeMode = asMap(data?['activeMode']);
    final steps = asList(activeMode['blueprint']);
    final lineage = asMap(data?['lineage']);
    final epStats = asMap(activeMode['episodeStats']);

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _moduleHeader(
            '01',
            'How It Works · 5-Step Execution Blueprint',
            '策略运作蓝图 · 五步执行规则',
          ),
          const SizedBox(height: 6),
          Text(
            w(
              'Observed ${data?['inceptionDate']} → ${data?['dataThrough']} · ${lineage['delistedStocksIncluded'] ?? 183} delisted common stocks included · -5% limit fill rate ${_pctUnsigned(epStats['fillRate'], 1)} · 10 bps round-trip cost',
              '实测区间 ${data?['inceptionDate']} → ${data?['dataThrough']} · 含 ${lineage['delistedStocksIncluded'] ?? 183} 只已退市美股普通股（0 幸存者偏差） · -5% 挂单成交率 ${_pctUnsigned(epStats['fillRate'], 1)} · 双边共 10 bps 摩擦成本',
            ),
            style: s(12, false, p.secondary),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 1100
                  ? 5
                  : constraints.maxWidth >= 700
                  ? 3
                  : 1;
              const gap = 10.0;
              final itemWidth =
                  (constraints.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final step in steps)
                    Container(
                      width: itemWidth,
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: p.card,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'STEP ${step['step']}',
                            style: s(10, true, _curveColor(mode)),
                          ),
                          const SizedBox(height: 4),
                          Text(_bilingual(step['title']), style: s(14, true)),
                          const SizedBox(height: 6),
                          Text(
                            _bilingual(step['summary']),
                            style: s(12, false, p.muted),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Map<String, double?> _rangeStatsForSeries(
    List<Map<String, dynamic>> curve,
    String key,
    int first,
    int last,
  ) {
    final rows = curve.sublist(first, last + 1);
    if (rows.any((r) => nullableNumber(r[key]) == null)) return {};
    final base = strategyRangeMetrics(
      [
        for (final r in rows) {'date': r['date'], 'value': r[key]},
      ],
      includeEntry: first == 0,
    );
    final cagr = base['cagr'];
    final mdd = base['maxDrawdown'];
    final calmar = (cagr != null && mdd != null && mdd < -1e-9)
        ? cagr / mdd.abs()
        : null;
    final origin = first == 0 ? 1.0 : number(rows.first[key]);
    final endingMultiple = origin > 0 ? number(rows.last[key]) / origin : null;
    return {...base, 'calmar': calmar, 'endingMultiple': endingMultiple};
  }

  Widget _buildPerformanceModule(List<Map<String, dynamic>> curve) {
    final first = (range.start * (curve.length - 1)).round().clamp(
      0,
      curve.length - 2,
    );
    final last = (range.end * (curve.length - 1)).round().clamp(
      first + 1,
      curve.length - 1,
    );
    final rows = curve.sublist(first, last + 1);

    const allSeriesIds = ['flagship', 'balanced', 'qqq', 'spy'];
    final series = <String, List<double>>{};
    final metricsMap = <String, Map<String, double?>>{};

    for (final id in allSeriesIds) {
      metricsMap[id] = _rangeStatsForSeries(curve, id, first, last);
      if (!enabledCurves.contains(id) || metricsMap[id]!.isEmpty) continue;
      final origin = first == 0 ? 1.0 : number(rows.first[id]);
      var peak = origin;
      series[id] = rows.map((r) {
        final v = number(r[id]);
        peak = math.max(peak, v);
        return drawdown ? (v / peak - 1) * 100 : (v / origin) * 100;
      }).toList();
    }

    final cursorIdx = hover < 0
        ? rows.length - 1
        : hover.clamp(0, rows.length - 1);
    final activeStats = metricsMap[mode] ?? {};
    final yearlyReturns = asList(data?['yearlyReturns']);

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _moduleHeader(
            '02',
            'Performance, Underwater Drawdown & Yearly Alpha',
            '净值曲线、水下回撤与 2016–2026 逐年牛熊表现',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                key: const ValueKey('breakout-chart-growth'),
                label: Text(w('Growth of 100', '100 起点净值')),
                selected: !drawdown,
                onSelected: (_) => setState(() => drawdown = false),
              ),
              ChoiceChip(
                key: const ValueKey('breakout-chart-drawdown'),
                label: Text(w('Underwater Drawdown', '水下回撤')),
                selected: drawdown,
                onSelected: (_) => setState(() => drawdown = true),
              ),
              const SizedBox(width: 8),
              for (final id in allSeriesIds)
                FilterChip(
                  key: ValueKey('breakout-curve-toggle-$id'),
                  label: Text(_curveName(id)),
                  selected: enabledCurves.contains(id),
                  avatar: Icon(
                    Icons.show_chart,
                    size: 16,
                    color: _curveColor(id),
                  ),
                  onSelected: (on) => setState(() {
                    if (on) {
                      enabledCurves.add(id);
                    } else if (enabledCurves.length > 1) {
                      enabledCurves.remove(id);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              Text(text(rows[cursorIdx]['date']), style: s(12, true)),
              for (final id in series.keys)
                Text(
                  '${_curveName(id)}: ${series[id]![cursorIdx].toStringAsFixed(2)}${drawdown ? '%' : ''}',
                  style: s(12, true, _curveColor(id)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) {
              void inspect(double x) => setState(
                () => hover =
                    ((x - 46) /
                            math.max(1, box.maxWidth - 62) *
                            (rows.length - 1))
                        .round(),
              );
              return MouseRegion(
                onHover: (e) => inspect(e.localPosition.dx),
                onExit: (_) => setState(() => hover = -1),
                child: GestureDetector(
                  onTapDown: (e) => inspect(e.localPosition.dx),
                  child: SizedBox(
                    height: 280,
                    width: box.maxWidth,
                    child: CustomPaint(
                      painter: StrategyCurvePainter(
                        series: series,
                        colors: {
                          for (final id in series.keys) id: _curveColor(id),
                        },
                        palette: p,
                        drawdown: drawdown,
                        cursor: cursorIdx,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(text(rows.first['date']), style: s(11, false, p.muted)),
              Text(text(rows.last['date']), style: s(11, false, p.muted)),
            ],
          ),
          RangeSlider(
            values: range,
            divisions: curve.length - 1,
            labels: RangeLabels(
              text(rows.first['date']),
              text(rows.last['date']),
            ),
            onChanged: (v) {
              if ((v.end - v.start) * (curve.length - 1) >= 1) {
                _changeRange(v, curve);
              }
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('breakout-range-start'),
                onPressed: () => _pickBoundary(curve, true),
                icon: const Icon(Icons.calendar_today_outlined, size: 15),
                label: Text('${w('From', '从')} ${rows.first['date']}'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('breakout-range-end'),
                onPressed: () => _pickBoundary(curve, false),
                icon: const Icon(Icons.calendar_today_outlined, size: 15),
                label: Text('${w('To', '至')} ${rows.last['date']}'),
              ),
              for (final years in [1, 3, 5, 10])
                TextButton(
                  key: ValueKey('breakout-range-${years}y'),
                  onPressed: () {
                    final endDt = DateTime.parse(text(curve.last['date']));
                    final target = DateTime(
                      endDt.year - years,
                      endDt.month,
                      endDt.day,
                    ).toIso8601String().substring(0, 10);
                    final sIdx = curve.indexWhere(
                      (r) => text(r['date']).compareTo(target) >= 0,
                    );
                    _changeRange(
                      RangeValues(
                        math.max(0, sIdx) / (curve.length - 1),
                        1,
                      ),
                      curve,
                    );
                  },
                  child: Text('${years}Y'),
                ),
              for (final yr in [2020, 2022, 2024])
                if (curve.any((r) => text(r['date']).startsWith('$yr-')))
                  OutlinedButton(
                    key: ValueKey('breakout-range-year-$yr'),
                    onPressed: () {
                      final fIdx = curve.indexWhere(
                        (r) => text(r['date']).startsWith('$yr-'),
                      );
                      final tIdx = curve.lastIndexWhere(
                        (r) => text(r['date']).startsWith('$yr-'),
                      );
                      if (fIdx >= 0 && tIdx > fIdx) {
                        _changeRange(
                          RangeValues(
                            math.max(0, fIdx - 1) / (curve.length - 1),
                            tIdx / (curve.length - 1),
                          ),
                          curve,
                        );
                      }
                    },
                    child: Text('$yr'),
                  ),
              TextButton(
                key: const ValueKey('breakout-range-reset'),
                onPressed: () => _changeRange(const RangeValues(0, 1), curve),
                child: Text(w('Reset full range', '重置全部区间')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${_curveName(mode)} · ${rows.first['date']} → ${rows.last['date']}',
            style: s(13, true, _curveColor(mode)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 12,
            children: [
              for (final kpi in [
                (
                  w('Wealth Multiple', '区间净值倍数'),
                  _mult(activeStats['endingMultiple']),
                  _pct(activeStats['totalReturn'], 1),
                ),
                (
                  w('Annualized CAGR', '年化复合收益'),
                  _pctUnsigned(activeStats['cagr']),
                  w('Net of 10 bps', '已扣 10 bps 成本'),
                ),
                (
                  w('Sharpe · Rf=0%', '夏普比率 · 0% Rf'),
                  _dec(activeStats['sharpeZeroRf']),
                  w('252 sessions/yr', '252 交易日年化'),
                ),
                (
                  w('Max Drawdown', '区间最大回撤'),
                  _pctUnsigned(activeStats['maxDrawdown']),
                  w('Peak-to-trough', '日频峰值回撤'),
                ),
                (
                  w('Annualized Vol', '年化波动率'),
                  _pctUnsigned(activeStats['volatility']),
                  w('Daily net NAV', '日净值样本波动'),
                ),
                (
                  w('Calmar Ratio', '卡玛比率 (CAGR/MDD)'),
                  _dec(activeStats['calmar']),
                  w('Return / Drawdown', '收益回撤效率'),
                ),
              ])
                Container(
                  width: 168,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kpi.$1, style: s(11, false, p.muted)),
                      const SizedBox(height: 3),
                      Text(kpi.$2, style: s(20, true)),
                      const SizedBox(height: 2),
                      Text(kpi.$3, style: s(10.5, false, p.secondary)),
                    ],
                  ),
                ),
            ],
          ),
          if (yearlyReturns.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              w(
                'Calendar Year Returns vs. Benchmarks (Click any year to zoom)',
                '2016–2026 逐年收益对比（点击任意年份可一键定位区间）',
              ),
              style: s(15, true),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 680),
                child: Table(
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  columnWidths: const {
                    0: FixedColumnWidth(84),
                    1: FixedColumnWidth(132),
                    2: FixedColumnWidth(132),
                    3: FixedColumnWidth(112),
                    4: FixedColumnWidth(112),
                    5: FixedColumnWidth(128),
                  },
                  border: TableBorder(
                    horizontalInside: BorderSide(color: p.border),
                  ),
                  children: [
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            w('Year', '年份'),
                            style: s(11.5, true, p.muted),
                          ),
                        ),
                        Text(
                          w('Flagship 8.91x', '进攻旗舰 8.91x'),
                          style: s(11.5, true, p.positive),
                        ),
                        Text(
                          w('Balanced 7.54x', '高夏普稳健 7.54x'),
                          style: s(11.5, true, p.accent),
                        ),
                        Text('SPY', style: s(11.5, true, p.secondary)),
                        Text(
                          'QQQ',
                          style: s(11.5, true, const Color(0xffb589ff)),
                        ),
                        Text(
                          w('Active Alpha vs SPY', '当前模式超额 vs SPY'),
                          style: s(11.5, true, p.muted),
                        ),
                      ],
                    ),
                    for (final yr in yearlyReturns)
                      TableRow(
                        children: [
                          InkWell(
                            onTap: () {
                              final yStr = '${yr['year']}-';
                              final fIdx = curve.indexWhere(
                                (r) => text(r['date']).startsWith(yStr),
                              );
                              final tIdx = curve.lastIndexWhere(
                                (r) => text(r['date']).startsWith(yStr),
                              );
                              if (fIdx >= 0 && tIdx > fIdx) {
                                _changeRange(
                                  RangeValues(
                                    math.max(0, fIdx - 1) / (curve.length - 1),
                                    tIdx / (curve.length - 1),
                                  ),
                                  curve,
                                );
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              child: Text(
                                text(yr['label']),
                                style: s(12.5, true),
                              ),
                            ),
                          ),
                          Text(
                            _pct(yr['flagship'], 1),
                            style: s(
                              12.5,
                              mode == 'flagship',
                              number(yr['flagship']) >= 0
                                  ? p.positive
                                  : p.negative,
                            ),
                          ),
                          Text(
                            _pct(yr['balanced'], 1),
                            style: s(
                              12.5,
                              mode == 'balanced',
                              number(yr['balanced']) >= 0
                                  ? p.accent
                                  : p.negative,
                            ),
                          ),
                          Text(
                            _pct(yr['spy'], 1),
                            style: s(
                              12,
                              false,
                              number(yr['spy']) >= 0 ? p.text : p.negative,
                            ),
                          ),
                          Text(
                            _pct(yr['qqq'], 1),
                            style: s(
                              12,
                              false,
                              number(yr['qqq']) >= 0 ? p.text : p.negative,
                            ),
                          ),
                          Builder(
                            builder: (_) {
                              final alpha =
                                  number(yr[mode]) - number(yr['spy']);
                              return Text(
                                _pct(alpha, 1),
                                style: s(
                                  12.5,
                                  true,
                                  alpha >= 0 ? p.positive : p.negative,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              w(
                '* Partial boundary years: 2016 starts 2016-11-10; latest year runs through ${data?['dataThrough']}.',
                '* 首尾星号年份说明：2016* 自回测起点 2016-11-10 起算；最新年份统计至 ${data?['dataThrough']}。',
              ),
              style: s(11, false, p.muted),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showTradeReplayDialog(Map<String, dynamic> trade) =>
      showDialog<void>(
        context: context,
        builder: (ctx) {
          final tk = text(trade['ticker']);
          final ret = number(trade['netReturn']);
          final reason = text(trade['exitReason']);
          return AlertDialog(
            backgroundColor: p.panel,
            title: Row(
              children: [
                StockLogo(ticker: tk, palette: p, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tk, style: s(19, true)),
                      Text(text(trade['name']), style: s(12, false, p.muted)),
                    ],
                  ),
                ),
                Text(
                  _pct(ret),
                  style: s(19, true, ret >= 0 ? p.positive : p.negative),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _exitReasonColor(reason).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _exitReasonLabel(reason),
                        style: s(12, true, _exitReasonColor(reason)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (final row in [
                      (
                        w('1. 63d Breakout Signal', '1. 63 日新高突破日'),
                        '${trade['breakoutDate']} · ${w('Close', '收盘')} ${_price(trade['breakoutClose'])}',
                      ),
                      (
                        w('2. Pullback Wait Window', '2. 等待浅回撤天数'),
                        '${trade['waitDays'] ?? '—'} ${w('trading sessions', '个交易日')}',
                      ),
                      (
                        w('3. -5% Pullback Fill', '3. -5% 限价低吸成交'),
                        '${trade['entryDate']} · ${_price(trade['entryPrice'])}',
                      ),
                      if (nullableNumber(trade['hardStopPrice']) != null)
                        (
                          w('4. Initial ATR Hard Stop', '4. 初始 ATR 硬止损位'),
                          _price(trade['hardStopPrice']),
                        ),
                      if (nullableNumber(trade['targetPrice']) != null)
                        (
                          w('5. +25% Profit Target', '5. +25% 目标止盈位'),
                          _price(trade['targetPrice']),
                        ),
                      (
                        trade['isOpen'] == true
                            ? w('Latest Mark', '最新收盘估值')
                            : w('Exit Execution', '出场日期与成交价'),
                        '${trade['exitDate']} · ${_price(trade['exitPrice'])} (${trade['holdDays']} ${w('sessions held', '个交易日持仓')})',
                      ),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 5,
                              child: Text(row.$1, style: s(12, false, p.muted)),
                            ),
                            Expanded(
                              flex: 6,
                              child: Text(row.$2, style: s(12.5, true)),
                            ),
                          ],
                        ),
                      ),
                    if (trade['isDelisted'] == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          w(
                            'Historical PIT constituent (subsequently delisted or acquired).',
                            '历史时点真实在市普通股（后续已退市或并购摘牌，零幸存者偏差）。',
                          ),
                          style: s(11.5, false, p.secondary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(w('Close', '关闭')),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onCompany(tk);
                },
                child: Text(w('Research company', '研究公司')),
              ),
            ],
          );
        },
      );

  Widget _buildLiveBookAndLedgerModule() {
    final liveBook = asMap(data?['liveBook']);
    final openPositions = asList(liveBook['openPositions']);
    final watchlist = asList(liveBook['pendingWatchlist']);
    final allTrades = asList(data?['trades']);

    final years = <String>{
      for (final tr in allTrades)
        if (text(tr['entryDate']).length >= 4)
          text(tr['entryDate']).substring(0, 4),
    }.toList()
      ..sort((a, b) => b.compareTo(a));

    final filteredTrades = allTrades.where((tr) {
      if (tradeYearFilter != 'all' &&
          !text(tr['entryDate']).startsWith('$tradeYearFilter-')) {
        return false;
      }
      if (tradeReasonFilter != 'all') {
        final r = text(tr['exitReason']);
        if (tradeReasonFilter == 'profit' &&
            r != 'Trailing_TakeProfit' &&
            r != 'Target_TakeProfit') {
          return false;
        }
        if (tradeReasonFilter == 'stop' && r != 'Hard_StopLoss') {
          return false;
        }
        if (tradeReasonFilter == 'open' && r != 'Open_Position') {
          return false;
        }
      }
      if (tradeSearch.trim().isNotEmpty) {
        final q = tradeSearch.trim().toUpperCase();
        if (!text(tr['ticker']).toUpperCase().contains(q) &&
            !text(tr['name']).toUpperCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _moduleHeader(
            '04',
            'Current Holdings · Live -5% Watchlist · Trade Ledger',
            '当前持仓 · 破新高待回撤挂单观察池 · 历史逐笔交割单',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('breakout-book-tab-holdings'),
                selected: bookTab == 'holdings',
                label: Text(
                  '${w('Active Holdings', '当前持仓')} (${openPositions.length})',
                ),
                onSelected: (_) => setState(() => bookTab = 'holdings'),
              ),
              ChoiceChip(
                key: const ValueKey('breakout-book-tab-watchlist'),
                selected: bookTab == 'watchlist',
                label: Text(
                  '${w('Live -5% Pullback Watchlist', '破新高待回撤挂单池')} (${watchlist.length})',
                ),
                onSelected: (_) => setState(() => bookTab = 'watchlist'),
              ),
              ChoiceChip(
                key: const ValueKey('breakout-book-tab-trades'),
                selected: bookTab == 'trades',
                label: Text(
                  '${w('Trade History', '历史逐笔交割单')} (${allTrades.length})',
                ),
                onSelected: (_) => setState(() => bookTab = 'trades'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (bookTab == 'holdings') ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  Text(
                    '${w('As of', '截至')} ${liveBook['asOfDate'] ?? data?['dataThrough']}',
                    style: s(12.5, true),
                  ),
                  Text(
                    '${w('Active Slots', '占用槽位')}: ${liveBook['usedSlots'] ?? openPositions.length} / ${liveBook['maxSlots'] ?? 10}',
                    style: s(12.5, true, _curveColor(mode)),
                  ),
                  Text(
                    '${w('Invested Exposure', '股票仓位')}: ${_pctUnsigned(liveBook['investedWeight'], 1)}',
                    style: s(12.5, false),
                  ),
                  Text(
                    '${w('Cash Reserve', '现金仓位')}: ${_pctUnsigned(liveBook['cashWeight'], 1)}',
                    style: s(12.5, false, p.secondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (openPositions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  w(
                    '100% Cash as of this session — no open positions currently held. Inspect the Live -5% Pullback Watchlist tab for pending limit orders.',
                    '截至该交易日组合为 100% 现金空仓防守状态。可切换至「破新高待回撤挂单池」查看正在等待 -5% 触发的候选龙头。',
                  ),
                  style: s(13, false, p.muted),
                ),
              )
            else
              for (final pos in openPositions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Material(
                    color: p.card,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      key: ValueKey('breakout-open-${pos['ticker']}'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () => widget.onCompany(text(pos['ticker'])),
                      child: Padding(
                        padding: const EdgeInsets.all(13),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LayoutBuilder(
                              builder: (context, rowBox) {
                                final leftInfo = Row(
                                  children: [
                                    StockLogo(
                                      ticker: text(pos['ticker']),
                                      palette: p,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            text(pos['ticker']),
                                            style: s(15.5, true),
                                          ),
                                          Text(
                                            '${pos['name']} · ${w('Entry', '买入')} ${pos['entryDate']} @ ${_price(pos['entryPrice'])} (${pos['holdingDays']}d)',
                                            style: s(11.5, false, p.muted),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                                final rightStats = Column(
                                  crossAxisAlignment: rowBox.maxWidth >= 460
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _pct(pos['unrealizedNetReturn']),
                                      style: s(
                                        15.5,
                                        true,
                                        number(pos['unrealizedNetReturn']) >= 0
                                            ? p.positive
                                            : p.negative,
                                      ),
                                    ),
                                    Text(
                                      '${w('Weight', '仓位')} ${_pctUnsigned(pos['weight'], 1)} · ${w('Close', '现价')} ${_price(pos['latestClose'])}',
                                      style: s(11, false, p.muted),
                                    ),
                                  ],
                                );
                                if (rowBox.maxWidth >= 460) {
                                  return Row(
                                    children: [
                                      Expanded(child: leftInfo),
                                      const SizedBox(width: 10),
                                      rightStats,
                                    ],
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    leftInfo,
                                    const SizedBox(height: 6),
                                    rightStats,
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 9),
                            Wrap(
                              spacing: 14,
                              runSpacing: 6,
                              children: [
                                Text(
                                  '${w('Hard Stop', 'ATR 硬止损')}: ${_price(pos['hardStopPrice'])}',
                                  style: s(11.5, true, p.negative),
                                ),
                                if (nullableNumber(
                                      pos['chandelierStopPrice'],
                                    ) !=
                                    null)
                                  Text(
                                    '${w('Chandelier 4x ATR', '4.0x ATR 吊灯线')}: ${_price(pos['chandelierStopPrice'])}',
                                    style: s(11.5, true, p.positive),
                                  ),
                                if (nullableNumber(pos['targetPrice']) != null)
                                  Text(
                                    '${w('+25% Target', '+25% 止盈价')}: ${_price(pos['targetPrice'])} (${pos['remainingTimeStopDays']}d ${w('left', '剩余时间窗')})',
                                    style: s(11.5, true, p.accent),
                                  ),
                                Text(
                                  '${w('Effective Stop Trigger', '当前生效保护线')}: ${_price(pos['effectiveStopPrice'])}',
                                  style: s(11.5, true, p.secondary),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          ],
          if (bookTab == 'watchlist') ...[
            Text(
              w(
                'Fresh 63-day breakouts within the past 15 trading sessions awaiting a -5% pullback below post-breakout peak close. Ordered by proximity to the limit buy price.',
                '过去 15 个交易日内刚突破 63 日新高、尚未成交且正在等待「突破后最高收盘价 -5%」触发的热门龙头，按距离限价成交由近及远排序。',
              ),
              style: s(12, false, p.muted),
            ),
            const SizedBox(height: 12),
            if (watchlist.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  w(
                    'No pending breakout episodes in the active 15-day watch window at this date.',
                    '当前 15 日观察窗口内暂无待回撤触发的新高股票。',
                  ),
                  style: s(13, false, p.muted),
                ),
              )
            else
              for (final item in watchlist)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Material(
                    color: p.card,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      key: ValueKey('breakout-watch-${item['ticker']}'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () => widget.onCompany(text(item['ticker'])),
                      child: Padding(
                        padding: const EdgeInsets.all(13),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LayoutBuilder(
                              builder: (context, rowBox) {
                                final leftInfo = Row(
                                  children: [
                                    StockLogo(
                                      ticker: text(item['ticker']),
                                      palette: p,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Wrap(
                                            spacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              Text(
                                                text(item['ticker']),
                                                style: s(15.5, true),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: p.accent.withValues(
                                                    alpha: 0.16,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Text(
                                                  '#${item['dvolRank']} ${w('Dollar Vol', '成交额排名')}',
                                                  style: s(
                                                    10.5,
                                                    true,
                                                    p.accent,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            '${item['name']} · ${w('Breakout', '突破日')} ${item['breakoutDate']} (${w('Peak Close', '突破后最高收')} ${_price(item['peakClose'])})',
                                            style: s(11.5, false, p.muted),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                                final rightStats = Column(
                                  crossAxisAlignment: rowBox.maxWidth >= 480
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${w('Limit Buy', '-5% 挂单价')} ${_price(item['limitBuyPrice'])}',
                                      style: s(15, true, p.positive),
                                    ),
                                    Text(
                                      '${w('Latest', '最新收')} ${_price(item['latestClose'])} (${_pct(item['distanceToLimitPct'], 2)} ${w('to fill', '触发距离')})',
                                      style: s(
                                        11.5,
                                        true,
                                        number(item['distanceToLimitPct'])
                                                    .abs() <=
                                                0.02
                                            ? p.secondary
                                            : p.muted,
                                      ),
                                    ),
                                  ],
                                );
                                if (rowBox.maxWidth >= 480) {
                                  return Row(
                                    children: [
                                      Expanded(child: leftInfo),
                                      const SizedBox(width: 10),
                                      rightStats,
                                    ],
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    leftInfo,
                                    const SizedBox(height: 6),
                                    rightStats,
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 14,
                              runSpacing: 6,
                              children: [
                                Text(
                                  '${w('Remaining Window', '剩余有效观察期')}: ${item['remainingWatchDays']} / 15 ${w('sessions', '个交易日')}',
                                  style: s(11.5, true, p.secondary),
                                ),
                                Text(
                                  '${w('20d Avg Dollar Vol', '20日均成交额')}: \$${(number(item['dvol20']) / 1e9).toStringAsFixed(2)}B',
                                  style: s(11.5, false, p.muted),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          ],
          if (bookTab == 'trades') ...[
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 210,
                  child: TextField(
                    key: const ValueKey('breakout-trade-search'),
                    style: s(13),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 17, color: p.muted),
                      hintText: w('Search ticker or name…', '搜索股票代码或名称…'),
                      hintStyle: s(12, false, p.muted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    onChanged: (val) => setState(() {
                      tradeSearch = val;
                      tradeLimit = 40;
                    }),
                  ),
                ),
                DropdownButton<String>(
                  key: const ValueKey('breakout-trade-year-filter'),
                  value: tradeYearFilter,
                  dropdownColor: p.panel,
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(w('All Years', '全部年份'), style: s(12.5)),
                    ),
                    for (final y in years)
                      DropdownMenuItem(
                        value: y,
                        child: Text(y, style: s(12.5)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        tradeYearFilter = v;
                        tradeLimit = 40;
                      });
                    }
                  },
                ),
                for (final filter in [
                  ('all', w('All Exits', '全部状态')),
                  ('profit', w('Profit Exits', '止盈出局')),
                  ('stop', w('Hard Stops', '止损出局')),
                  ('open', w('Open', '持仓中')),
                ])
                  ChoiceChip(
                    selected: tradeReasonFilter == filter.$1,
                    label: Text(filter.$2),
                    onSelected: (_) => setState(() {
                      tradeReasonFilter = filter.$1;
                      tradeLimit = 40;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${w('Matching trades', '符合条件笔数')}: ${filteredTrades.length} · ${w('Click any row to inspect breakout, pullback fill & exit replay', '点击任意交割单查看突破日、-5% 成交价、止损位与出场完整回放')}',
              style: s(11.5, false, p.muted),
            ),
            const SizedBox(height: 10),
            for (final tr in filteredTrades.take(tradeLimit))
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Material(
                  color: p.card,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    key: ValueKey('breakout-trade-${tr['lotId']}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _showTradeReplayDialog(tr),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          StockLogo(
                            ticker: text(tr['ticker']),
                            palette: p,
                            size: 30,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      text(tr['ticker']),
                                      style: s(14.5, true),
                                    ),
                                    Text(
                                      _exitReasonLabel(text(tr['exitReason'])),
                                      style: s(
                                        11,
                                        true,
                                        _exitReasonColor(
                                          text(tr['exitReason']),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${tr['entryDate']} @ ${_price(tr['entryPrice'])} → ${tr['exitDate']} @ ${_price(tr['exitPrice'])} (${tr['holdDays']}d)',
                                  style: s(11.5, false, p.muted),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            _pct(tr['netReturn']),
                            style: s(
                              15,
                              true,
                              number(tr['netReturn']) >= 0
                                  ? p.positive
                                  : p.negative,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.chevron_right, size: 18, color: p.muted),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (filteredTrades.length > tradeLimit)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => tradeLimit += 60),
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: Text(
                    '${w('Show more trades', '加载更多交割单')} (${filteredTrades.length - tradeLimit} ${w('remaining', '笔未展开')})',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpiricalProofModule() {
    final proof = asMap(data?['empiricalProof']);
    final findings = asList(proof['findings']);
    final guardrails = asList(proof['guardrails']);

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _moduleHeader(
            '05',
            '6,912-Grid Empirical Proof & Research Guardrails',
            '6,912 组全网格实证结论与研究边界声明',
          ),
          const SizedBox(height: 6),
          Text(
            w(
              'Tested across ${proof['gridSize'] ?? 6912} parameter combinations (${proof['dimensions'] ?? ''}) on 10-year PIT US common stocks.',
              '基于 10 年全市场 PIT 普通股样本对 ${proof['gridSize'] ?? 6912} 组量价参数矩阵进行系统性压力测试。',
            ),
            style: s(12, false, p.muted),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 960 ? 3 : 1;
              const gap = 12.0;
              final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final f in findings)
                    Container(
                      width: itemW,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: p.card,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            text(f['metric']),
                            style: s(11, true, _curveColor(mode)),
                          ),
                          const SizedBox(height: 5),
                          Text(_bilingual(f['title']), style: s(14, true)),
                          const SizedBox(height: 7),
                          Text(
                            _bilingual(f['detail']),
                            style: s(12, false, p.muted),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          if (guardrails.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final g in guardrails)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 15,
                      color: p.secondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _bilingual(g),
                        style: s(11.5, false, p.muted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          Text(
            '${w('Snapshot', '校验快照')} ${text(data?['snapshotId']).substring(0, math.min(12, text(data?['snapshotId']).length))} · ${w('Source Generation', '数据源版本')} ${text(asMap(data?['lineage'])['sourceGeneration']).substring(0, math.min(12, text(asMap(data?['lineage'])['sourceGeneration']).length))}',
            style: s(10.5, false, p.faint),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return _panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Loading audited Hot Breakout Pullback portfolio…',
                '正在读取已校验的美股热门股突破浅回撤组合…',
              ),
              style: s(),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(color: p.positive),
          ],
        ),
      );
    }

    if (failed || data == null) {
      return _panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Hot Breakout Pullback portfolio could not be loaded.',
                '暂时无法读取热门股突破浅回撤策略组合。',
              ),
              style: s(16, true),
            ),
            const SizedBox(height: 4),
            Text(
              w(
                'No synthetic returns are substituted. Please retry.',
                '绝不使用模拟示例数据替代，请点击重试。',
              ),
              style: s(12, false, p.muted),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: load,
              icon: const Icon(Icons.refresh),
              label: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final curve = asList(asMap(data?['backtest'])['curve']);
    if (curve.length < 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildModeSwitchBar(),
          const SizedBox(height: 16),
          _panel(
            Text(
              w(
                'No observed backtest history is available by this cutoff (${widget.asOf}). Strategy inception is ${data?['inceptionDate'] ?? '2016-11-10'}.',
                '该截止日（${widget.asOf}）尚无可用回测历史记录；本策略实测起点为 ${data?['inceptionDate'] ?? '2016-11-10'}。',
              ),
              style: s(14),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildModeSwitchBar(),
        const SizedBox(height: 16),
        _buildBlueprintModule(),
        const SizedBox(height: 16),
        _buildPerformanceModule(curve),
        const SizedBox(height: 16),
        BreakoutRangeAnalysisPanel(
          api: widget.api,
          palette: p,
          asOf: widget.asOf,
          mode: mode,
          modeColor: _curveColor(mode),
          modeLabel: _curveName(mode),
          snapshotId: text(data?['snapshotId']),
          curve: curve,
          range: range,
          onCompany: widget.onCompany,
        ),
        const SizedBox(height: 16),
        _buildLiveBookAndLedgerModule(),
        const SizedBox(height: 16),
        _buildEmpiricalProofModule(),
      ],
    );
  }
}

class BreakoutRangeAnalysisPanel extends StatefulWidget {
  const BreakoutRangeAnalysisPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.mode,
    required this.modeColor,
    required this.modeLabel,
    required this.snapshotId,
    required this.curve,
    required this.range,
    required this.onCompany,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final String mode;
  final Color modeColor;
  final String modeLabel;
  final String snapshotId;
  final List<Map<String, dynamic>> curve;
  final RangeValues range;
  final ValueChanged<String> onCompany;

  @override
  State<BreakoutRangeAnalysisPanel> createState() =>
      _BreakoutRangeAnalysisPanelState();
}

class _BreakoutRangeAnalysisPanelState
    extends State<BreakoutRangeAnalysisPanel> {
  Timer? debounce;
  int epoch = 0;
  bool loading = true;
  bool failed = false;
  int? selectedBin;
  Map<String, dynamic>? detail;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.42,
  );

  int get first => (widget.range.start * (widget.curve.length - 1))
      .round()
      .clamp(0, widget.curve.length - 2);
  int get last => (widget.range.end * (widget.curve.length - 1)).round().clamp(
    first + 1,
    widget.curve.length - 1,
  );
  String get start => text(widget.curve[first]['date']);
  String get end => text(widget.curve[last]['date']);

  String _pct(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  String _ratio(dynamic v) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(2);
  String _money(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${number(v) < -1e-10 ? '−' : '+'}\$${formatNumber(number(v).abs() * 100000)}';
  String _price(dynamic v) =>
      nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(2)}';

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant BreakoutRangeAnalysisPanel old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range ||
        old.mode != widget.mode ||
        old.asOf != widget.asOf ||
        old.snapshotId != widget.snapshotId ||
        old.api != widget.api) {
      _schedule();
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    epoch++;
    super.dispose();
  }

  void _schedule() {
    debounce?.cancel();
    epoch++;
    detail = null;
    loading = true;
    failed = false;
    debounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_load()),
    );
  }

  Future<void> _load() async {
    final req = ++epoch;
    final reqStart = start;
    final reqEnd = end;
    final reqMode = widget.mode;
    final reqSnap = widget.snapshotId;

    setState(() {
      loading = true;
      failed = false;
      detail = null;
    });

    try {
      final query = Uri(
        queryParameters: {
          'asOf': widget.asOf,
          'mode': reqMode,
          'snapshotId': reqSnap,
          'start': reqStart,
          'end': reqEnd,
        },
      ).query;
      final res = await widget.api.getJson(
        '/api/investment/breakout-pullback/analysis?$query',
      );
      if (!mounted || req != epoch) return;
      if (res['snapshotId'] != reqSnap ||
          res['mode'] != reqMode ||
          res['start'] != reqStart ||
          res['end'] != reqEnd) {
        throw StateError('breakout_range_mismatch');
      }
      setState(() {
        detail = res;
        loading = false;
      });
    } catch (_) {
      if (!mounted || req != epoch) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  String _bandLabel(int i) => [
    '< −10',
    '−10 ≤ x < −5',
    '−5 ≤ x < −1',
    '−1 ≤ x < 0',
    w('0 · flat', '0 · 持平'),
    '0 < x < +1',
    '+1 ≤ x < +5',
    '+5 ≤ x < +10',
    '≥ +10',
  ][i];

  Future<void> _showStockLotsDialog(Map<String, dynamic> holding) =>
      showDialog<void>(
        context: context,
        builder: (ctx) {
          final tk = text(holding['ticker']);
          final lots = asList(holding['lots']);
          return AlertDialog(
            backgroundColor: p.panel,
            title: Row(
              children: [
                StockLogo(ticker: tk, palette: p, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tk, style: s(19, true)),
                      Text(text(holding['name']), style: s(12, false, p.muted)),
                    ],
                  ),
                ),
                Text(
                  _money(holding['netContribution']),
                  style: s(
                    18,
                    true,
                    number(holding['netContribution']) >= 0
                        ? p.positive
                        : p.negative,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$start → $end · ${w('Net contribution to starting NAV', '占区间起点净值贡献')}: ${_pct(holding['netContribution'])}',
                      style: s(12, false, p.muted),
                    ),
                    const SizedBox(height: 12),
                    for (final lot in lots)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: p.card,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: p.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${lot['entryDate']} @ ${_price(lot['entryPrice'])} → ${lot['exitDate']} @ ${_price(lot['exitPrice'])}',
                                  style: s(12.5, true),
                                ),
                                Text(
                                  _money(lot['rangeNetContribution']),
                                  style: s(
                                    13,
                                    true,
                                    number(lot['rangeNetContribution']) >= 0
                                        ? p.positive
                                        : p.negative,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${w('Breakout', '突破日')} ${lot['breakoutDate']} (${_price(lot['breakoutClose'])}) · ${lot['holdDays']}d · ${lot['exitReason']}',
                              style: s(11.5, false, p.muted),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(w('Close', '关闭')),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onCompany(tk);
                },
                child: Text(w('Research company', '研究公司')),
              ),
            ],
          );
        },
      );

  Widget _buildDistributionChart(List<Map<String, dynamic>> bins) {
    if (bins.length != 9) return const SizedBox.shrink();
    const shortLabels = [
      '<−10',
      '−10\n−5',
      '−5\n−1',
      '−1\n0',
      '0',
      '0\n+1',
      '+1\n+5',
      '+5\n+10',
      '≥+10',
    ];
    const plotHeight = 164.0;
    final maxCount = bins.fold<double>(
      0,
      (acc, b) => math.max(acc, number(b['count'])),
    );
    final step = math.max(1, (maxCount / 3).ceil());
    final ceiling = step * 3;
    final total = bins.fold<int>(0, (acc, b) => acc + number(b['count']).toInt());
    final sel = selectedBin ??
        List.generate(9, (i) => i).reduce(
          (i, j) => number(bins[i]['count']) >= number(bins[j]['count']) ? i : j,
        );
    final selCount = number(bins[sel]['count']).toInt();

    return Column(
      key: const ValueKey('breakout-distribution-chart'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          w(
            '9-Band Stock Portfolio Contribution Distribution (pp of starting NAV)',
            '9 档个股组合净收益贡献分布（占区间起点净值百分点）',
          ),
          style: s(15.5, true),
        ),
        const SizedBox(height: 4),
        Text(
          '${w('Total unique stocks traded/held in window', '区间内参与持仓/交易独立股票总数')}: $total',
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: plotHeight + 46,
          child: Stack(
            children: [
              for (var tick = 0; tick <= 3; tick++)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: tick * plotHeight / 3,
                  height: 26,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Text(
                          '${tick * step}',
                          style: s(11, false, p.muted),
                        ),
                      ),
                      Expanded(child: Container(height: 1, color: p.border)),
                    ],
                  ),
                ),
              Positioned.fill(
                left: 32,
                bottom: 13,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < 9; i++)
                      Expanded(
                        child: MouseRegion(
                          onEnter: (_) => setState(() => selectedBin = i),
                          child: InkWell(
                            key: ValueKey('breakout-dist-bin-$i'),
                            onTap: () => setState(() => selectedBin = i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    '${bins[i]['count']}',
                                    style: s(
                                      12.5,
                                      true,
                                      i < 4
                                          ? p.negative
                                          : i > 4
                                          ? widget.modeColor
                                          : p.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    height:
                                        plotHeight *
                                        number(bins[i]['count']) /
                                        ceiling,
                                    constraints: const BoxConstraints(
                                      maxWidth: 52,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (i < 4
                                              ? p.negative
                                              : i > 4
                                              ? widget.modeColor
                                              : p.muted)
                                          .withValues(
                                            alpha: i == sel ? 1.0 : 0.62,
                                          ),
                                      borderRadius:
                                          const BorderRadius.vertical(
                                            top: Radius.circular(3),
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
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 32, top: 6),
          child: Row(
            children: [
              for (var i = 0; i < 9; i++)
                Expanded(
                  child: Text(
                    shortLabels[i],
                    textAlign: TextAlign.center,
                    style: s(10.5, i == sel),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.border),
          ),
          child: Text(
            '${_bandLabel(sel)} ${w('pp', '个百分点')} · $selCount ${w('stocks', '只股票')}${total > 0 ? ' (${_pct(selCount / total)})' : ''}',
            style: s(12, true),
          ),
        ),
      ],
    );
  }

  Widget _buildExtremeGroup(
    String title,
    List<Map<String, dynamic>> items,
    bool isWinner,
  ) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: p.card,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: s(13.5, true, isWinner ? p.positive : p.negative),
        ),
        const SizedBox(height: 10),
        if (items.isEmpty)
          Text(w('None in this range', '该区间暂无记录'), style: s(12.5, false, p.muted))
        else
          for (final h in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => _showStockLotsDialog(h),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      StockLogo(
                        ticker: text(h['ticker']),
                        palette: p,
                        size: 28,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(text(h['ticker']), style: s(14, true)),
                            Text(
                              '${asList(h['lots']).length} ${w('lot(s)', '笔交易')} · ${_pct(h['netContribution'])} ${w('of NAV', '净值贡献')}',
                              style: s(11, false, p.muted),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _money(h['netContribution']),
                        style: s(
                          14.5,
                          true,
                          isWinner ? p.positive : p.negative,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tStats = asMap(detail?['tradeStats']);
    final turnover = asMap(detail?['turnover']);
    final mStats = asMap(detail?['metrics']);
    final recon = asMap(detail?['reconciliation']);

    final statItems = [
      (w('Range Net Return', '区间扣费净收益'), _pct(mStats['totalReturn'])),
      (w('Stock Win Rate', '个股区间胜率'), _pct(tStats['winRate'])),
      (w('Stock Payoff Ratio', '个股盈亏比'), _ratio(tStats['payoffRatio'])),
      (
        w('Win / Loss / Flat Stocks', '盈利 / 亏损 / 持平股数'),
        tStats.isEmpty
            ? '—'
            : '${tStats['wins']} / ${tStats['losses']} / ${tStats['flat']}',
      ),
      (w('Lot Win Rate', '逐笔交易胜率'), _pct(tStats['lotWinRate'])),
      (w('Lot Payoff Ratio', '逐笔盈亏比'), _ratio(tStats['lotPayoffRatio'])),
      (
        w('Avg Holding Period', '平均持仓交易日'),
        nullableNumber(tStats['avgHoldingDays']) == null
            ? '—'
            : '${number(tStats['avgHoldingDays']).toStringAsFixed(1)}d',
      ),
      (
        w('Profit Exit / Stop Share', '止盈占比 / 止损占比'),
        tStats.isEmpty
            ? '—'
            : '${_pct(tStats['profitExitShare'])} / ${_pct(tStats['stopLossExitShare'])}',
      ),
      (w('One-Way Turnover', '区间单边换手率'), _pct(turnover['oneWay'])),
      (
        w('Annualized Turnover', '年化单边换手率'),
        _pct(turnover['annualizedOneWay']),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: widget.modeColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('03', style: s(12, true, widget.modeColor)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  w(
                    'Selected Range Attribution, Win/Payoff & P&L Distribution',
                    '所选区间逐股归因、胜率盈亏比与 9 档盈亏分布',
                  ),
                  key: const ValueKey('breakout-range-analysis'),
                  style: s(18.5, true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '${widget.modeLabel} · $start → $end · ${last - first + 1} ${w('daily observations · Hypothetical \$100,000 starting capital', '个日频观测 · 按区间起点 100,000 美元本金折算净盈亏')}',
            style: s(12, false, p.muted),
          ),
          if (loading) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(color: widget.modeColor),
          ],
          if (failed) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    w(
                      'Range attribution could not be loaded for this window.',
                      '该区间的逐股归因数据加载失败。',
                    ),
                    style: s(12.5, false, p.secondary),
                  ),
                ),
                TextButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(w('Retry', '重试')),
                ),
              ],
            ),
          ],
          if (detail != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                for (final item in statItems)
                  Container(
                    width: 176,
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: p.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.$1, style: s(11, false, p.muted)),
                        const SizedBox(height: 3),
                        Text(item.$2, style: s(15, true)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _buildDistributionChart(asList(detail?['distribution'])),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final winBox = _buildExtremeGroup(
                  w('Top 3 Contributors (Click to inspect)', '区间前三大盈利贡献股（点击查看明细）'),
                  asList(detail?['topWinners']),
                  true,
                );
                final loseBox = _buildExtremeGroup(
                  w('Top 3 Detractors (Click to inspect)', '区间前三大亏损拖累股（点击查看明细）'),
                  asList(detail?['topLosers']),
                  false,
                );
                if (constraints.maxWidth >= 760) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: winBox),
                      const SizedBox(width: 14),
                      Expanded(child: loseBox),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    winBox,
                    const SizedBox(height: 12),
                    loseBox,
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            Text(
              '${w('Open at range end', '期末仍持有股票数')}: ${tStats['open'] ?? 0} · ${w('Daily NAV reconciliation residual', '日频净值逐股对账残差')}: ${_money(recon['difference'])}',
              style: s(11, false, p.muted),
            ),
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${w('All Stock P&L in Selected Range', '展开查看区间全部股票净贡献与买卖明细')} (${asList(detail?['holdings']).length})',
                  style: s(14, true),
                ),
                children: [
                  for (final h in asList(detail?['holdings']))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: StockLogo(
                        ticker: text(h['ticker']),
                        palette: p,
                        size: 28,
                      ),
                      title: Text(text(h['ticker']), style: s(14, true)),
                      subtitle: Text(
                        '${h['name']} · ${asList(h['lots']).length} ${w('lot(s)', '笔')} · ${h['openAtEnd'] == true ? w('Open at range end', '期末持仓中') : w('Closed', '已平仓')}',
                        style: s(11.5, false, p.muted),
                      ),
                      trailing: Text(
                        _money(h['netContribution']),
                        style: s(
                          14,
                          true,
                          number(h['netContribution']) >= 0
                              ? p.positive
                              : p.negative,
                        ),
                      ),
                      onTap: () => _showStockLotsDialog(h),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
