part of 'main.dart';

/// Never bridge missing marks or independently funded history segments.
Map<String, double?> ruleRangeMetrics(
  List<Map<String, dynamic>> curve,
  String id,
  int first,
  int last,
  List<Map<String, dynamic>> styles,
) {
  final rows = curve.sublist(first, last + 1);
  final style = styles.firstWhere((s) => s['id'] == id, orElse: () => {});
  final segments = asList(asMap(style['coverage'])['segments']);
  final segment = segments.where(
    (s) =>
        text(s['from']).compareTo(text(rows.first['date'])) <= 0 &&
        text(s['to']).compareTo(text(rows.last['date'])) >= 0,
  );
  if (rows.any((r) => nullableNumber(r[id]) == null) ||
      (segments.isNotEmpty && segment.isEmpty)) {
    return {};
  }
  return strategyRangeMetrics(
    [
      for (final r in rows) {'date': r['date'], 'value': r[id]},
    ],
    includeEntry:
        first == 0 ||
        (segment.isNotEmpty && segment.first['from'] == rows.first['date']),
  );
}

/// Range returns and stock attribution deliberately have different denominators:
/// daily NAV for risk metrics, unique stocks (including open holdings) for P&L.
class RuleRangeAnalysisPanel extends StatefulWidget {
  const RuleRangeAnalysisPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.snapshotId,
    required this.curve,
    required this.range,
    required this.onCompany,
    this.styles = const [],
    this.universe = 'all',
  });
  final ApiClient api;
  final Palette palette;
  final String asOf, snapshotId, universe;
  final List<Map<String, dynamic>> curve;
  final List<Map<String, dynamic>> styles;
  final RangeValues range;
  final ValueChanged<String> onCompany;
  @override
  State<RuleRangeAnalysisPanel> createState() => _RuleRangeAnalysisState();
}

class _RuleRangeAnalysisState extends State<RuleRangeAnalysisPanel> {
  Timer? debounce;
  int epoch = 0;
  bool loading = true, failed = false;
  int? selectedDistributionBin;
  Map<String, dynamic>? detail;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.45,
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
  String name(String id) => id == 'quality_rank'
      ? w('Quality Rank · Top 10', '质量排名 · 前十')
      : w('Ackman · quantitative proxy', 'Ackman · 量化代理');
  Color color(String id) =>
      id == 'quality_rank' ? p.accent : const Color(0xff7eabfa);
  String pct(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  String ratio(dynamic v) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(2);
  String money(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${number(v) < -1e-10 ? '−' : ''}\$${formatNumber(number(v).abs() * 100000)}';
  String price(dynamic v) =>
      nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(4)}';
  Map<String, dynamic> result(String id) => asList(
    detail?['styles'],
  ).firstWhere((r) => r['id'] == id, orElse: () => {});

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(covariant RuleRangeAnalysisPanel old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range ||
        old.universe != widget.universe ||
        old.asOf != widget.asOf ||
        old.snapshotId != widget.snapshotId ||
        old.api != widget.api) {
      schedule();
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    epoch++;
    super.dispose();
  }

  void schedule() {
    debounce?.cancel();
    epoch++;
    detail = null;
    loading = true;
    failed = false;
    debounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(load()),
    );
  }

  Future<void> load() async {
    final request = ++epoch,
        requestedStart = start,
        requestedEnd = end,
        snapshot = widget.snapshotId;
    setState(() {
      loading = true;
      failed = false;
      detail = null;
    });
    try {
      final query = Uri(
        queryParameters: {
          'asOf': widget.asOf,
          'snapshotId': snapshot,
          'universe': widget.universe,
          'start': requestedStart,
          'end': requestedEnd,
        },
      ).query;
      final response = await widget.api.getJson(
        '/api/investment/investor-styles/analysis?$query',
      );
      if (!mounted || epoch != request) return;
      if (response['snapshotId'] != snapshot ||
          (response['universe'] ?? 'all') != widget.universe ||
          response['start'] != requestedStart ||
          response['end'] != requestedEnd ||
          ![
            'rule-range-attribution-v1',
            'rule-range-attribution-v2',
          ].contains(response['version'])) {
        throw StateError('range_snapshot_mismatch');
      }
      setState(() {
        detail = response;
        loading = false;
      });
    } catch (_) {
      if (!mounted || epoch != request) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  Widget box(Widget child, {Color? background}) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: background ?? p.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.border),
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );

  @override
  Widget build(BuildContext context) {
    const ids = ['quality_rank', 'ackman'];
    final metrics = {
      for (final id in ids)
        id: ruleRangeMetrics(widget.curve, id, first, last, widget.styles),
    };
    final labels = [
      w('Return · after costs', '回报率 · 扣费后'),
      w('Annualized return', '年化回报'),
      w('Sharpe · Rf = 0%', 'Sharpe · 无风险 0%'),
      w('Vol · annualized', 'Vol · 年化波动'),
      w('MDD', 'MDD · 最大回撤'),
      w('Stock win rate', '个股区间胜率'),
      w('Payoff · avg win / avg loss', '盈亏比 · 平均盈 / 平均亏'),
      w('Winning / losing / flat', '盈利 / 亏损 / 持平'),
      w('Turnover · one-way', '区间换手率 · 单边'),
      w('Annualized turnover · one-way', '年化换手率 · 单边'),
      w('Executed rebalances', '实际调仓次数'),
    ];
    List<String> values(String id) {
      final m = metrics[id]!, t = asMap(result(id)['tradeStats']);
      final turnover = asMap(result(id)['turnover']);
      return [
        pct(m['totalReturn']),
        pct(m['cagr']),
        ratio(m['sharpeZeroRf']),
        pct(m['volatility']),
        pct(m['maxDrawdown']),
        pct(t['winRate']),
        ratio(t['payoffRatio']),
        t.isEmpty ? '—' : '${t['wins']} / ${t['losses']} / ${t['flat']}',
        pct(turnover['oneWay']),
        pct(turnover['annualizedOneWay']),
        turnover['executions']?.toString() ?? '—',
      ];
    }

    return box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w('Your selected range · both strategies', '所选区间 · 双策略分析'),
            key: const ValueKey('rule-range-analysis'),
            style: s(21, true),
          ),
          const SizedBox(height: 4),
          Text(
            '$start → $end · ${last - first + 1} ${w('daily observations', '个日频观测')}',
            style: s(12, false, p.muted),
          ),
          const SizedBox(height: 18),
          Table(
            key: const ValueKey('rule-range-metrics'),
            columnWidths: const {
              0: FlexColumnWidth(1.2),
              1: FlexColumnWidth(1),
              2: FlexColumnWidth(1),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(horizontalInside: BorderSide(color: p.border)),
            children: [
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      w('Measure', '统计指标'),
                      style: s(12, false, p.muted),
                    ),
                  ),
                  for (final id in ids)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(name(id), style: s(13, true, color(id))),
                    ),
                ],
              ),
              for (var i = 0; i < labels.length; i++)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(labels[i], style: s(12, false, p.muted)),
                    ),
                    for (final id in ids)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          values(id)[i],
                          key: ValueKey('range-$id-$i'),
                          style: s(15, true),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            w(
              'Risk metrics use all daily net returns (252 sessions/year, sample volatility). Win rate and payoff compare each stock’s net P&L within this range, including marked open holdings; flat stocks are excluded from win rate. No losing or winning stocks: payoff is unavailable, not zero.',
              '风险指标使用全部日频净收益（每年 252 个交易日、样本波动率）。胜率和盈亏比按个股区间净盈亏统计，含期末未卖出的持仓估值；持平股票不计入胜率。没有盈利或亏损股票时，盈亏比为不可用，不补零。',
            ),
            style: s(11, false, p.muted),
          ),
          const SizedBox(height: 8),
          Text(
            w(
              'One-way turnover = Σ (buys + sells) ÷ (2 × each pre-trade NAV). Initial entry is included when the range starts at inception or an independent segment restart (100% invested = 50% one-way); other opening-day trades are excluded. Annualized = range turnover × 252 ÷ daily return intervals, not a forecast. Corporate-action exchanges are not trades.',
              '单边换手率＝Σ（买入额＋卖出额）÷（2 × 各次调仓前净值）。区间从策略起点或独立片段起点开始时计入首次建仓（100%建仓计50%）；其他起始日收盘前交易不计入。年化值＝区间换手率 × 252 ÷ 日收益区间数，不是预测；公司行动换股不算交易。',
            ),
            style: s(11, false, p.muted),
          ),
          const SizedBox(height: 24),
          Text(w('Stock P&L distribution', '个股盈亏分布'), style: s(18, true)),
          if (loading) ...[
            const SizedBox(height: 18),
            LinearProgressIndicator(color: p.accent),
            const SizedBox(height: 8),
            Text(
              w(
                'Reconciling stock P&L with the published daily NAV…',
                '正在核对逐股盈亏与已发布的日净值…',
              ),
              style: s(12, false, p.muted),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 14),
            Text(
              w(
                'Stock attribution is unavailable or could not reconcile. The net-return statistics above remain available; no trade prices have been invented.',
                '逐股归因数据暂不可用或未能对账。上方净值统计仍可使用；不会编造买卖价格。',
              ),
              style: s(13, false, p.secondary),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: load,
                icon: const Icon(Icons.refresh),
                label: Text(w('Retry attribution', '重试逐股分析')),
              ),
            ),
          ],
          if (detail != null) ...[
            const SizedBox(height: 24),
            distribution(ids),
            const SizedBox(height: 24),
            Text(
              w('Largest winners & losers', '最大盈利与亏损股票'),
              style: s(18, true),
            ),
            Text(
              w(
                'USD P&L scaled to a hypothetical \$100,000 at the start of your range, after attributed trading costs. Prices are total-return-adjusted simulation prices, not historical executed quotes.',
                '按区间起点假设投入 100,000 美元计算净盈亏，已分摊交易费用。买卖价格为总回报复权的模拟价格，不是历史真实成交报价。',
              ),
              style: s(11, false, p.muted),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = [
                  for (final id in ids)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(name(id), style: s(14, true, color(id))),
                        const SizedBox(height: 10),
                        if (result(id)['status'] == 'coverage_gap')
                          gapNotice(id)
                        else
                          extreme(id, asMap(result(id)['best']), true),
                        const SizedBox(height: 12),
                        if (result(id)['status'] != 'coverage_gap')
                          extreme(id, asMap(result(id)['worst']), false),
                        const SizedBox(height: 12),
                        if (result(id)['status'] != 'coverage_gap')
                          Text(
                            '${w('Still held', '期末仍持有')}: ${asMap(result(id)['tradeStats'])['open']} · ${w('P&L reconciliation residual', '盈亏对账残差')}: ${money(asMap(result(id)['reconciliation'])['difference'])}',
                            style: s(11, false, p.muted),
                          ),
                      ],
                    ),
                ];
                return constraints.maxWidth < 700
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          columns[0],
                          const SizedBox(height: 24),
                          columns[1],
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: columns[0]),
                          const SizedBox(width: 18),
                          Expanded(child: columns[1]),
                        ],
                      );
              },
            ),
            const SizedBox(height: 18),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                w(
                  'All stock P&L · inspect dates & prices',
                  '全部股票盈亏 · 查看买卖日期和价格',
                ),
                style: s(14, true),
              ),
              children: [
                for (final id in ids) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(name(id), style: s(14, true, color(id))),
                  ),
                  for (final h in asList(result(id)['holdings']))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: StockLogo(
                        ticker: text(h['ticker']),
                        palette: p,
                        size: 30,
                      ),
                      title: Text(text(h['ticker']), style: s(14, true)),
                      subtitle: Text(
                        h['openAtEnd'] == true
                            ? w('Open · marked at range end', '未卖出 · 按期末估值')
                            : w('No equity holding at range end', '期末无该股持仓'),
                        style: s(11, false, p.muted),
                      ),
                      trailing: Text(
                        money(h['netContribution']),
                        style: s(
                          14,
                          true,
                          number(h['netContribution']) >= 0
                              ? p.accent
                              : p.secondary,
                        ),
                      ),
                      onTap: () => showStock(h),
                    ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget distribution(List<String> ids) {
    final a = asList(result(ids[0])['distribution']),
        b = asList(result(ids[1])['distribution']);
    if (a.length != 9 && b.length != 9) {
      return Text(w('Distribution data unavailable', '分布数据不可用'), style: s());
    }
    final maxCount = [
      ...a,
      ...b,
    ].fold<double>(0, (n, r) => math.max(n, number(r['count'])));
    final step = math.max(1, (maxCount / 3).ceil());
    final ceiling = step * 3;
    final selected =
        selectedDistributionBin ??
        List.generate(9, (i) => i).reduce(
          (i, j) =>
              (a.length == 9 ? number(a[i]['count']) : 0) +
                      (b.length == 9 ? number(b[i]['count']) : 0) >=
                  (a.length == 9 ? number(a[j]['count']) : 0) +
                      (b.length == 9 ? number(b[j]['count']) : 0)
              ? i
              : j,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          w(
            'Loss → profit across the horizontal axis. Height and labels show stock counts; both charts use the same scale. Hover or tap a bar for exact bounds.',
            '横轴从亏损到盈利；柱高和柱顶数字表示股票数量，两图共用刻度。悬停或点按柱子查看完整区间。',
          ),
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final charts = [
              a.length == 9
                  ? distributionChart(ids[0], a, ceiling, step, selected)
                  : gapNotice(ids[0]),
              b.length == 9
                  ? distributionChart(ids[1], b, ceiling, step, selected)
                  : gapNotice(ids[1]),
            ];
            return constraints.maxWidth >= 840
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: charts[0]),
                      const SizedBox(width: 28),
                      Expanded(child: charts[1]),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      charts[0],
                      const SizedBox(height: 28),
                      charts[1],
                    ],
                  );
          },
        ),
        const SizedBox(height: 12),
        Text(
          w(
            'Bands are net contributions to portfolio return (percentage points), not each stock’s return. Unequal-width bands are ordered categories, not a density scale. Open holdings are marked at the selected end date.',
            '分组口径为对组合收益的净贡献（百分点），不是个股涨跌幅。不等宽区间按类别排列，不表示概率密度；未卖出持仓按所选期末估值。',
          ),
          style: s(11, false, p.muted),
        ),
      ],
    );
  }

  String distributionBand(int i) => [
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

  Widget gapNotice(String id) => Text(
    '${name(id)} · ${w('This range crosses a data gap. Select 2013–2019-11-19 or 2020-01-02 onward for complete statistics. Independent segments are not compounded together; missing values are not zero.', '此区间跨越数据缺口。请选择 2013 至 2019-11-19，或 2020-01-02 之后的区间查看完整统计。独立片段不拼接复利，缺失值不是零。')}',
    key: ValueKey('rule-gap-$id'),
    style: s(12, false, p.secondary),
  );

  Widget distributionChart(
    String id,
    List<Map<String, dynamic>> bins,
    int ceiling,
    int step,
    int selected,
  ) {
    const labels = [
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
    const plotHeight = 174.0;
    final total = bins.fold<int>(0, (n, r) => n + number(r['count']).toInt());
    final count = number(bins[selected]['count']).toInt();
    String description(int i) =>
        '${name(id)} · ${distributionBand(i)} '
        '${w('pp', '个百分点')} · ${bins[i]['count']} ${w('stocks', '只股票')}';
    return Column(
      key: ValueKey('distribution-chart-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(name(id), style: s(15, true, color(id))),
        const SizedBox(height: 4),
        Text(
          '${w('Number of stocks', '股票数量（只）')} · '
          '${w('Total', '合计')} $total',
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: plotHeight + 48,
          child: Stack(
            children: [
              for (var tick = 0; tick <= 3; tick++)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: tick * plotHeight / 3,
                  height: 28,
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
                bottom: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < 9; i++)
                      Expanded(
                        child: MouseRegion(
                          onEnter: (_) =>
                              setState(() => selectedDistributionBin = i),
                          child: Tooltip(
                            message: description(i),
                            child: Semantics(
                              label: description(i),
                              button: true,
                              child: InkWell(
                                key: ValueKey('distribution-bin-$id-$i'),
                                onTap: () =>
                                    setState(() => selectedDistributionBin = i),
                                onFocusChange: (focused) {
                                  if (focused) {
                                    setState(() => selectedDistributionBin = i);
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text(
                                        '${bins[i]['count']}',
                                        style: s(13, true, color(id)),
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        key: ValueKey(
                                          'distribution-bar-$id-$i',
                                        ),
                                        height:
                                            plotHeight *
                                            number(bins[i]['count']) /
                                            ceiling,
                                        constraints: const BoxConstraints(
                                          maxWidth: 50,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color(id).withValues(
                                            alpha: i == selected ? 1 : .65,
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
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 32, top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < 9; i++)
                Expanded(
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: s(11, i == selected),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(w('← Loss', '← 亏损'), style: s(12, true, p.secondary)),
            ),
            Text(w('Flat', '持平'), style: s(12, false, p.muted)),
            Expanded(
              child: Text(
                w('Profit →', '盈利 →'),
                textAlign: TextAlign.right,
                style: s(12, true, color(id)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          key: ValueKey('distribution-readout-$id'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.border.withValues(alpha: .25),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${distributionBand(selected)} ${w('pp', '个百分点')} · '
            '$count ${w('stocks', '只股票')}'
            '${total > 0 ? ' · ${pct(count / total)}' : ''}',
            style: s(12, true),
          ),
        ),
      ],
    );
  }

  Widget extreme(String id, Map<String, dynamic> h, bool winner) => box(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          winner ? w('Largest profit', '最大盈利') : w('Largest loss', '最大亏损'),
          style: s(11, true, winner ? p.accent : p.secondary),
        ),
        if (h.isEmpty)
          Text(w('None in this range', '该区间没有此类股票'), style: s(14))
        else ...[
          const SizedBox(height: 12),
          Row(
            children: [
              StockLogo(ticker: text(h['ticker']), palette: p, size: 34),
              const SizedBox(width: 10),
              Expanded(child: Text(text(h['ticker']), style: s(20, true))),
              Text(
                money(h['netContribution']),
                style: s(20, true, winner ? p.accent : p.secondary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${pct(h['netContribution'])} ${w('of starting NAV', '占区间起点净值')}',
            style: s(12, false, p.muted),
          ),
          const SizedBox(height: 10),
          if (asList(h['purchases']).isNotEmpty)
            Text(
              '${w('First simulated buy', '首次模拟买入')} · ${asList(h['purchases']).first['date']} · ${price(asList(h['purchases']).first['price'])}',
              style: s(12),
            ),
          if (asList(h['sales']).isNotEmpty)
            Text(
              '${w('Latest simulated sale', '区间内最近卖出')} · ${asList(h['sales']).last['date']} · ${price(asList(h['sales']).last['price'])}',
              style: s(12),
            ),
          if (h['openAtStart'] == true)
            Text(
              '${w('Opening holding mark', '期初持仓估值')} · ${price(asMap(h['openingMark'])['price'])}',
              style: s(11, false, p.muted),
            ),
          if (h['openAtEnd'] == true)
            Text(
              '${w('Still held · closing mark, not a sale', '仍持有 · 期末估值，非卖出')} · $end · ${price(asMap(h['closingMark'])['price'])}',
              style: s(11, false, p.muted),
            ),
          if (h['openAtEnd'] != true && asList(h['sales']).isEmpty)
            Text(
              w(
                'Settled or converted by a corporate action; inspect evidence.',
                '公司行动结算或换股，请展开依据。',
              ),
              style: s(11, false, p.muted),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: ValueKey('range-$id-${winner ? 'best' : 'worst'}'),
            onPressed: () => showStock(h),
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: Text(w('All buys, sells & marks', '全部买卖与估值记录')),
          ),
        ],
      ],
    ),
  );

  void showStock(Map<String, dynamic> h) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => LanguageScope(
        language: context.language,
        child: RuleTradeDetailDialog(
          stock: h,
          start: start,
          end: end,
          palette: p,
          onCompany: widget.onCompany,
        ),
      ),
    );
  }
}

/// Matched, auditable holding intervals; no client-side financial calculations.
class RuleTradeDetailDialog extends StatelessWidget {
  const RuleTradeDetailDialog({
    super.key,
    required this.stock,
    required this.start,
    required this.end,
    required this.palette,
    required this.onCompany,
  });
  final Map<String, dynamic> stock;
  final String start, end;
  final Palette palette;
  final ValueChanged<String> onCompany;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    String w(String en, String zh) => context.tr(zh, en);
    TextStyle s([double size = 13, bool bold = false, Color? color]) =>
        TextStyle(
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          color: color ?? p.text,
          height: 1.45,
        );
    String money(dynamic v) => nullableNumber(v) == null
        ? '—'
        : '${number(v) < -1e-10 ? '−' : ''}\$${formatNumber(number(v).abs() * 100000)}';
    String price(dynamic v) =>
        nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(4)}';
    String pct(dynamic v) => nullableNumber(v) == null
        ? '—'
        : '${(number(v) * 100).toStringAsFixed(2)}%';
    String qty(dynamic v) => nullableNumber(v) == null
        ? '—'
        : (number(v) * 100000).toStringAsFixed(4);
    final h = stock;
    final analysis = asMap(h['lotAnalysis']);
    final ready = analysis['status'] == 'available';
    final intervals = asList(analysis['intervals']);
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final row in intervals) {
      final key = '${row['buyDate']}:${row['buyPrice']}:${row['entryDate']}';
      groups.putIfAbsent(key, () => []).add(row);
    }
    Widget summary(String label, dynamic value, {bool primary = false}) =>
        Container(
          width: MediaQuery.sizeOf(context).width < 732
              ? (MediaQuery.sizeOf(context).width - 64 - (primary ? 0 : 10)) /
                    (primary ? 1 : 2)
              : (math.min(1040, MediaQuery.sizeOf(context).width - 32) - 52) /
                    3,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: primary ? p.accent.withValues(alpha: .5) : p.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: s(12, false, p.muted)),
              const SizedBox(height: 4),
              Text(
                money(value),
                style: s(22, true, number(value) < 0 ? p.secondary : p.accent),
              ),
            ],
          ),
        );
    Widget exitCell(Map<String, dynamic> row) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${row['exitDate']} · ${row['status'] == 'open'
              ? w('Still held', '仍持有')
              : row['exitKind'] == 'exit'
              ? w('Exit', '清仓')
              : w('Partial sale', '部分卖出')}',
          style: s(13, true),
        ),
        Text(
          '${price(row['exitPrice'])}${row['status'] == 'open' ? w(' · closing mark, not a sale', ' · 期末估值，非卖出') : ''}',
          style: s(12, false, p.muted),
        ),
      ],
    );
    Widget pnlCell(Map<String, dynamic> row) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          money(row['netContribution']),
          style: s(
            17,
            true,
            number(row['netContribution']) < 0 ? p.secondary : p.accent,
          ),
        ),
        Text(
          '${pct(row['returnOnBasis'])} · ${w('on lot basis', '批次收益率')}',
          style: s(11, false, p.muted),
        ),
      ],
    );
    Widget batch(List<Map<String, dynamic>> rows, bool narrow) {
      final row = rows.first;
      if (row['status'] == 'fee') {
        return ListTile(
          title: Text(w('Historical modeled fee', '历史模拟费用'), style: s()),
          trailing: Text(money(row['netContribution']), style: s()),
        );
      }
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: p.card,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.south_west_rounded, size: 18, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${w('Bought', '买入')} ${row['buyDate']} · ${price(row['buyPrice'])}',
                          style: s(14, true),
                        ),
                      ),
                    ],
                  ),
                  if (row['carriedIn'] == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        '${w('Carried in · range basis', '区间前已持有 · 本段计价起点')} ${row['entryDate']} · ${price(row['entryPrice'])}',
                        style: s(12, false, p.secondary),
                      ),
                    ),
                ],
              ),
            ),
            if (!narrow)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Text(
                        w('Sell / range-end mark', '卖出／期末估值'),
                        style: s(11, false, p.muted),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        w('Adjusted units', '复权模拟数量'),
                        style: s(11, false, p.muted),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        w('Basis → proceeds', '区间成本 → 金额'),
                        style: s(11, false, p.muted),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        w('Net P&L', '本段净盈亏'),
                        textAlign: TextAlign.end,
                        style: s(11, false, p.muted),
                      ),
                    ),
                  ],
                ),
              ),
            for (final r in rows)
              Container(
                key: ValueKey('lot-${r['id']}'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: p.border)),
                ),
                child: narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          exitCell(r),
                          const SizedBox(height: 10),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '${w('Units', '数量')} ${qty(r['quantity'])}\n${money(r['entryValue'])} → ${money(r['exitValue'])}',
                                  style: s(12),
                                ),
                              ),
                              pnlCell(r),
                            ],
                          ),
                          Text(
                            '${w('Allocated costs', '分摊费用')} ${money(r['costContribution'])}',
                            style: s(11, false, p.muted),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(flex: 4, child: exitCell(r)),
                          Expanded(
                            flex: 2,
                            child: Text(qty(r['quantity']), style: s()),
                          ),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${money(r['entryValue'])} → ${money(r['exitValue'])}',
                                  style: s(12),
                                ),
                                Text(
                                  '${w('Costs', '费用')} ${money(r['costContribution'])}',
                                  style: s(11, false, p.muted),
                                ),
                              ],
                            ),
                          ),
                          Expanded(flex: 2, child: pnlCell(r)),
                        ],
                      ),
              ),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: p.panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: 1040,
        height: math.min(820, MediaQuery.sizeOf(context).height - 48),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  StockLogo(ticker: text(h['ticker']), palette: p, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${h['ticker']} · ${w('Holding intervals', '持仓区间明细')}',
                          style: s(19, true),
                        ),
                        Text('$start → $end', style: s(12, false, p.muted)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: w('Close', '关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: p.muted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          summary(
                            w('Total range P&L', '区间总盈亏'),
                            h['netContribution'],
                            primary: true,
                          ),
                          if (ready)
                            summary(
                              w('Sold portions · net P&L', '已卖出部分 · 净盈亏'),
                              analysis['realized'],
                            ),
                          if (ready)
                            summary(
                              w('Still held · floating P&L', '仍持有部分 · 浮动盈亏'),
                              analysis['unrealized'],
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        w(
                          'FIFO · earliest purchases are matched first. Partial sales split a purchase into separate intervals. All amounts use an illustrative \$100,000 at the selected range start; units and prices are total-return adjusted.',
                          'FIFO 先买先卖 · 部分卖出拆成独立区间。金额按所选区间初始 10 万美元折算；数量和价格均为总回报复权模拟口径。',
                        ),
                        style: s(12, false, p.muted),
                      ),
                      Text(
                        '${w('Before costs', '扣费前')} ${money(h['grossContribution'])} − ${w('Costs', '费用')} ${money(h['costContribution'])} = ${money(h['netContribution'])}',
                        style: s(12),
                      ),
                      const SizedBox(height: 16),
                      if (ready) ...[
                        for (final rows in groups.values)
                          batch(rows, constraints.maxWidth < 700),
                        Text(
                          '${w('Paired intervals reconcile · difference', '区间配对已对账 · 差额')} ${money(asMap(analysis['reconciliation'])['difference'])}',
                          style: s(12, false, p.accent),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          w(
                            'Fees retain the published model’s pre-cost target-turnover basis. Quantities reconcile to post-cost holdings. Original purchase prices are context only when the selected range starts later.',
                            '费用保留已发布模型的扣费前目标调仓口径；数量与扣费后持仓一致。买入早于所选区间时，仅展示原买价作背景，本段盈亏从区间起点计。',
                          ),
                          style: s(11, false, p.muted),
                        ),
                      ] else ...[
                        Text(
                          w(
                            'Matched intervals are unavailable for this record. Corporate actions are not treated as ordinary sales. Original events are shown below.',
                            '该记录暂无法配对持仓批次；公司行动不视为普通卖出。下方保留原始事件。',
                          ),
                          style: s(13, false, p.secondary),
                        ),
                        const SizedBox(height: 10),
                        for (final side in ['purchases', 'sales']) ...[
                          Text(
                            side == 'purchases'
                                ? w('Buys · up to range end', '买入 · 截至区间末')
                                : w('Sells · within range', '卖出 · 区间内'),
                            style: s(14, true),
                          ),
                          for (final e in asList(h[side]))
                            Text(
                              '${e['date']} · ${e['tradedTicker'] ?? h['ticker']} · ${price(e['price'])}',
                              style: s(),
                            ),
                        ],
                        for (final a in asList(h['corporateActions']))
                          Text(
                            '${w('Corporate action · not a trade', '公司行动 · 非买卖')} · ${a['effectiveDate']} → ${a['successorTicker'] ?? w('Cash entitlement', '现金对价')}',
                            style: s(),
                          ),
                        if (h['openAtEnd'] == true)
                          Text(
                            '${w('Open at range end', '期末未卖出')} · $end · ${price(asMap(h['closingMark'])['price'])}',
                            style: s(),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: p.border),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(w('Close', '关闭')),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onCompany(text(h['ticker']));
                    },
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text(w('Research company', '研究公司')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
