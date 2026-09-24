part of 'main.dart';

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
  });
  final ApiClient api;
  final Palette palette;
  final String asOf, snapshotId;
  final List<Map<String, dynamic>> curve;
  final RangeValues range;
  final ValueChanged<String> onCompany;
  @override
  State<RuleRangeAnalysisPanel> createState() => _RuleRangeAnalysisState();
}

class _RuleRangeAnalysisState extends State<RuleRangeAnalysisPanel> {
  Timer? debounce;
  int epoch = 0;
  bool loading = true, failed = false;
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
          'start': requestedStart,
          'end': requestedEnd,
        },
      ).query;
      final response = await widget.api.getJson(
        '/api/investment/investor-styles/analysis?$query',
      );
      if (!mounted || epoch != request) return;
      if (response['snapshotId'] != snapshot ||
          response['start'] != requestedStart ||
          response['end'] != requestedEnd ||
          response['version'] != 'rule-range-attribution-v1') {
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
        id: strategyRangeMetrics([
          for (final r in widget.curve.sublist(first, last + 1))
            {'date': r['date'], 'value': r[id]},
        ], includeEntry: first == 0),
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
    ];
    List<String> values(String id) {
      final m = metrics[id]!, t = asMap(result(id)['tradeStats']);
      return [
        pct(m['totalReturn']),
        pct(m['cagr']),
        ratio(m['sharpeZeroRf']),
        pct(m['volatility']),
        pct(m['maxDrawdown']),
        pct(t['winRate']),
        ratio(t['payoffRatio']),
        t.isEmpty ? '—' : '${t['wins']} / ${t['losses']} / ${t['flat']}',
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
                        extreme(id, asMap(result(id)['best']), true),
                        const SizedBox(height: 12),
                        extreme(id, asMap(result(id)['worst']), false),
                        const SizedBox(height: 12),
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
    final maxCount = math.max(
      1.0,
      [...a, ...b].fold<double>(0, (n, r) => math.max(n, number(r['count']))),
    );
    final labels = [
      '< −10',
      '−10 … −5',
      '−5 … −1',
      '−1 … 0',
      '0',
      '0 … 1',
      '1 … 5',
      '5 … 10',
      '≥ 10',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          w(
            'Bins: net contribution to portfolio return in percentage points. Bar length: number of stocks.',
            '分组：对组合收益的净贡献（百分点）；柱长：股票数量。',
          ),
          style: s(11, false, p.muted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            for (final id in ids)
              Text('━ ${name(id)}', style: s(12, true, color(id))),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < math.min(9, math.min(a.length, b.length)); i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(labels[i], style: s(11, false, p.muted)),
                ),
                Expanded(
                  child: Column(
                    children: [
                      for (var j = 0; j < 2; j++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  label:
                                      '${name(ids[j])}, ${labels[i]} ${w('percentage points', '个百分点')}: ${(j == 0 ? a : b)[i]['count']} ${w('stocks', '只股票')}',
                                  child: ExcludeSemantics(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(
                                        minHeight: 9,
                                        value:
                                            number(
                                              (j == 0 ? a : b)[i]['count'],
                                            ) /
                                            maxCount,
                                        color: color(ids[j]),
                                        backgroundColor: p.border.withValues(
                                          alpha: .4,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 25,
                                child: Text(
                                  '${(j == 0 ? a : b)[i]['count']}',
                                  style: s(11),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
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
      builder: (dialogContext) => AlertDialog(
        backgroundColor: p.panel,
        title: Text('${h['ticker']} · ${w('Range P&L', '区间盈亏')}'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$start → $end', style: s(12, false, p.muted)),
                Text(
                  '${money(h['netContribution'])} · ${pct(h['netContribution'])}',
                  style: s(22, true),
                ),
                Text(
                  '${w('Before costs', '扣费前')}: ${money(h['grossContribution'])} · ${w('Costs', '费用')}: ${money(h['costContribution'])}',
                  style: s(12),
                ),
                const SizedBox(height: 12),
                Text(
                  w(
                    'Simulated rebalance dates; USD total-return-adjusted prices. Multiple buys and partial sales are retained. Purchases before the selected range are context only, not the interval cost basis.',
                    '以下是模拟调仓日期及美元总回报复权价格，保留多次加仓和部分卖出。区间前买入仅提供持仓背景，不用其价格冒充区间成本。',
                  ),
                  style: s(12, false, p.muted),
                ),
                for (final side in ['purchases', 'sales']) ...[
                  const SizedBox(height: 14),
                  Text(
                    side == 'purchases'
                        ? w('Buys · up to range end', '买入 · 截至区间末')
                        : w('Sells · within range', '卖出 · 区间内'),
                    style: s(14, true),
                  ),
                  if (asList(h[side]).isEmpty) Text(w('None', '无'), style: s()),
                  for (final e in asList(h[side]))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${e['date']} · ${e['tradedTicker'] ?? h['ticker']} · ${price(e['price'])}${e['beforeRange'] == true ? w(' · before range', ' · 区间之前') : ''}',
                        style: s(13),
                      ),
                    ),
                ],
                for (final a in asList(h['corporateActions'])) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${w('Corporate action · not a trade', '公司行动 · 非买卖')} · ${a['effectiveDate']} · ${a['considerationType']}${a['successorTicker'] == null ? '' : ' → ${a['successorTicker']}'}',
                    style: s(12, false, p.secondary),
                  ),
                ],
                const SizedBox(height: 12),
                if (h['openAtEnd'] == true)
                  Text(
                    '${w('Open at range end', '期末未卖出')} · $end · ${price(asMap(h['closingMark'])['price'])}',
                    style: s(13),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(w('Close', '关闭')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              widget.onCompany(text(h['ticker']));
            },
            child: Text(w('Research company', '研究公司')),
          ),
        ],
      ),
    );
  }
}
