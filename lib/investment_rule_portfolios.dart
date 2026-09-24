part of 'main.dart';

class StrategyWorkspacePanel extends StatefulWidget {
  const StrategyWorkspacePanel({
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
  State<StrategyWorkspacePanel> createState() => _StrategyWorkspacePanelState();
}

class _StrategyWorkspacePanelState extends State<StrategyWorkspacePanel> {
  bool rules = false, opened = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const ValueKey('strategy-builder-tab'),
            selected: !rules,
            label: Text(context.tr('策略构建器', 'Strategy builder')),
            onSelected: (_) => setState(() => rules = false),
          ),
          ChoiceChip(
            key: const ValueKey('strategy-styles-tab'),
            selected: rules,
            label: Text(context.tr('规则组合', 'Rule portfolios')),
            onSelected: (_) => setState(() {
              rules = true;
              opened = true;
            }),
          ),
        ],
      ),
      const SizedBox(height: 16),
      // Preserve the user's builder state when comparing the separate rule portfolios.
      Offstage(
        offstage: rules,
        child: StrategyLabPanel(
          api: widget.api,
          palette: widget.palette,
          asOf: widget.asOf,
          onCompany: widget.onCompany,
        ),
      ),
      if (opened)
        Offstage(
          offstage: !rules,
          child: InvestorStylesDashboard(
            api: widget.api,
            palette: widget.palette,
            asOf: widget.asOf,
            onCompany: widget.onCompany,
          ),
        ),
    ],
  );
}

class InvestorStylesDashboard extends StatefulWidget {
  const InvestorStylesDashboard({
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
  State<InvestorStylesDashboard> createState() => _RulePortfolioState();
}

class _RulePortfolioState extends State<InvestorStylesDashboard> {
  Map<String, dynamic>? data;
  bool loading = true, failed = false, drawdown = false;
  String active = 'quality_rank';
  int epoch = 0, quarter = -1, hover = -1;
  RangeValues range = const RangeValues(0, 1);
  final enabled = <String>{'quality_rank', 'ackman', 'spy'};
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.4,
  );
  String name(String id) => switch (id) {
    'quality_rank' => w('Quality Rank · Top 10', '质量排名 · 前十'),
    'ackman' => w('Ackman · quantitative proxy', 'Ackman · 量化代理'),
    _ => 'SPY',
  };
  Color color(String id) => id == 'quality_rank'
      ? p.accent
      : id == 'ackman'
      ? const Color(0xff7eabfa)
      : p.secondary;
  String pct(dynamic value) => nullableNumber(value) == null
      ? '—'
      : '${(number(value) * 100).toStringAsFixed(2)}%';
  String decimal(dynamic value) =>
      nullableNumber(value) == null ? '—' : number(value).toStringAsFixed(3);
  List<Map<String, dynamic>> get styles => asList(data?['styles']);
  Map<String, dynamic> get selected =>
      styles.firstWhere((r) => r['id'] == active, orElse: () => {});
  List<Map<String, dynamic>> get quarters => asList(selected['quarters']);
  Map<String, dynamic> get q =>
      quarters.isEmpty ? {} : quarters[quarter.clamp(0, quarters.length - 1)];

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant InvestorStylesDashboard old) {
    super.didUpdateWidget(old);
    if (old.asOf != widget.asOf || old.api != widget.api) unawaited(load());
  }

  Future<void> load() async {
    final request = ++epoch;
    setState(() {
      loading = true;
      failed = false;
      data = null;
    });
    try {
      final response = await widget.api.getJson(
        '/api/investment/investor-styles?asOf=${Uri.encodeQueryComponent(widget.asOf)}',
      );
      if (!mounted || request != epoch) return;
      setState(() {
        data = response;
        loading = false;
        range = const RangeValues(0, 1);
        hover = -1;
        quarter = quarters.length - 1;
      });
    } catch (_) {
      if (!mounted || request != epoch) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  Widget panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.border),
    ),
    child: child,
  );
  void select(String id) => setState(() {
    active = id;
    quarter = quarters.length - 1;
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w('Loading verified rule portfolios…', '正在读取已校验的规则组合…'),
              style: s(),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(color: p.accent),
          ],
        ),
      );
    }
    if (failed || data == null) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w('Rule portfolios could not be loaded.', '暂时无法读取规则组合。'),
              style: s(16, true),
            ),
            Text(
              w(
                'Your saved strategies are unchanged. No sample returns are substituted.',
                '已保存策略未变更；不会使用示例收益替代。',
              ),
              style: s(12, false, p.muted),
            ),
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
      return panel(
        Text(
          w(
            'No observed backtest history is available by this cutoff.',
            '该截止日前尚无可用的回测观测记录。',
          ),
          style: s(15),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(w('Rule portfolio dashboard', '规则组合看板'), style: s(24, true)),
              const SizedBox(height: 6),
              Text(
                w(
                  'Two independent portfolios. Inspect the rules, then each quarterly decision.',
                  '两条独立策略，先看执行规则，再查看每个季度的选股依据。',
                ),
                style: s(13, false, p.muted),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in styles)
                    ChoiceChip(
                      key: ValueKey('style-${r['id']}'),
                      selected: active == r['id'],
                      label: Text(name(text(r['id']))),
                      onSelected: (_) => select(text(r['id'])),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                w(
                  'Observed through ${data?['dataThrough']} · 25 bps on buys + sells · research backtest',
                  '实测数据至 ${data?['dataThrough']} · 买入和卖出分别计 25bp · 研究回测',
                ),
                style: s(12, false, p.secondary),
              ),
              Text(
                w(
                  'The 15% cap applies at rebalance; weights can drift between quarters. Turning a curve off does not trade or change saved strategies.',
                  '15% 上限用于调仓目标，季度内权重随价格漂移。关闭曲线不会交易，也不会修改已保存的策略。',
                ),
                style: s(11, false, p.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        chart(curve),
        const SizedBox(height: 16),
        RuleRangeAnalysisPanel(
          api: widget.api,
          palette: p,
          asOf: widget.asOf,
          snapshotId: text(data?['snapshotId']),
          curve: curve,
          range: range,
          onCompany: widget.onCompany,
        ),
        const SizedBox(height: 16),
        holdings(),
        const SizedBox(height: 16),
        method(),
      ],
    );
  }

  Widget chart(List<Map<String, dynamic>> curve) {
    final first = (range.start * (curve.length - 1)).round().clamp(
      0,
      curve.length - 2,
    );
    final last = (range.end * (curve.length - 1)).round().clamp(
      first + 1,
      curve.length - 1,
    );
    final rows = curve.sublist(first, last + 1);
    final series = <String, List<double>>{},
        metrics = <String, Map<String, double?>>{};
    for (final id in ['quality_rank', 'ackman', 'spy']) {
      metrics[id] = strategyRangeMetrics([
        for (final r in rows) {'date': r['date'], 'value': r[id]},
      ], includeEntry: first == 0);
      if (!enabled.contains(id)) continue;
      final origin = first == 0 ? 1.0 : number(rows.first[id]);
      var peak = origin;
      series[id] = rows.map((r) {
        final v = number(r[id]);
        peak = math.max(peak, v);
        return drawdown ? (v / peak - 1) * 100 : v / origin * 100;
      }).toList();
    }
    final index = hover < 0 ? rows.length - 1 : hover.clamp(0, rows.length - 1);
    final stats = metrics[active] ?? {};
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(w('Compare performance', '对比表现'), style: s(19, true)),
              ChoiceChip(
                label: Text(w('Growth of 100', '100 起点净值')),
                selected: !drawdown,
                onSelected: (_) => setState(() => drawdown = false),
              ),
              ChoiceChip(
                label: Text(w('Drawdown', '回撤')),
                selected: drawdown,
                onSelected: (_) => setState(() => drawdown = true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in ['quality_rank', 'ackman', 'spy'])
                FilterChip(
                  key: ValueKey('curve-toggle-$id'),
                  label: Text(name(id)),
                  selected: enabled.contains(id),
                  avatar: Icon(Icons.show_chart, size: 16, color: color(id)),
                  onSelected: (on) => setState(() {
                    if (on) {
                      enabled.add(id);
                    } else {
                      enabled.remove(id);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              Text(text(rows[index]['date']), style: s(12, true)),
              for (final id in series.keys)
                Text(
                  '${name(id)} ${series[id]![index].toStringAsFixed(2)}${drawdown ? '%' : ''}',
                  style: s(12, false, color(id)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (series.isEmpty)
            SizedBox(
              height: 220,
              child: Center(
                child: Text(
                  w('Turn on a portfolio to compare.', '打开一条曲线开始比较。'),
                  style: s(),
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                void inspect(double x) => setState(
                  () => hover =
                      ((x - 46) /
                              math.max(1, box.maxWidth - 62) *
                              (rows.length - 1))
                          .round(),
                );
                return Semantics(
                  label: w(
                    'Daily portfolio and SPY returns. Exact values shown above.',
                    '组合与 SPY 日频收益；精确数值显示在上方。',
                  ),
                  child: MouseRegion(
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
                              for (final id in series.keys) id: color(id),
                            },
                            palette: p,
                            drawdown: drawdown,
                            cursor: index,
                          ),
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
              Text(text(rows.first['date']), style: s(11)),
              Text(text(rows.last['date']), style: s(11)),
            ],
          ),
          RangeSlider(
            values: range,
            divisions: curve.length - 1,
            onChanged: (v) {
              if ((v.end - v.start) * (curve.length - 1) >= 1) {
                setState(() {
                  range = v;
                  hover = -1;
                });
              }
            },
          ),
          TextButton(
            onPressed: () => setState(() => range = const RangeValues(0, 1)),
            child: Text(w('Reset full range', '重置全部区间')),
          ),
          const SizedBox(height: 8),
          Text(name(active), style: s(13, true, color(active))),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              for (final item in [
                (w('Total return', '累计收益'), pct(stats['totalReturn'])),
                (w('CAGR', '年化收益'), pct(stats['cagr'])),
                (
                  w('Sharpe · 0% Rf', '夏普 · 0% 无风险'),
                  decimal(stats['sharpeZeroRf']),
                ),
                (w('Annualized vol', '年化波动率'), pct(stats['volatility'])),
                (w('Max drawdown', '最大回撤'), pct(stats['maxDrawdown'])),
              ])
                SizedBox(
                  width: 150,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.$1, style: s(11, false, p.muted)),
                      Text(item.$2, style: s(22, true)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            w(
              'Statistics use every daily observation in the selected range, not sampled chart points.',
              '统计使用所选区间的全部日频观测，而非图上抽样点。',
            ),
            style: s(11, false, p.muted),
          ),
        ],
      ),
    );
  }

  Widget holdings() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              w('Quarterly holdings & changes', '季度持仓与变化'),
              style: s(19, true),
            ),
            if (quarters.isNotEmpty)
              DropdownButton<int>(
                key: const ValueKey('holdings-quarter'),
                value: quarter.clamp(0, quarters.length - 1),
                items: [
                  for (var i = quarters.length - 1; i >= 0; i--)
                    DropdownMenuItem(
                      value: i,
                      child: Text(text(quarters[i]['quarter']), style: s(13)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => quarter = v);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${w('Signal close', '信号收盘')} ${q['signalDate']} · ${w('Execution', '执行')} ${q['executionDate']}',
          style: s(12, false, p.muted),
        ),
        Text(
          '${q['selectedCount']} ${w('stocks', '只股票')} · ${q['eligibleCount']} ${w('eligible', '只通过门槛')} · ${w('Cash target', '现金目标')} ${pct(q['cashWeight'])}',
          style: s(12, true),
        ),
        const SizedBox(height: 6),
        Text(
          q['mature'] == true
              ? w('COMPLETED RETURN WINDOW', '已完成收益期')
              : w('LATEST · RETURN NOT MATURE', '最新 · 收益尚未成熟'),
          style: s(11, true, p.secondary),
        ),
        const SizedBox(height: 12),
        Text(
          w(
            'Select a holding to inspect raw inputs, percentiles and score contributions. Weight change compares quarter-end targets, not actual trading flow.',
            '点击持仓查看原始指标、分位数和评分贡献。权重变化比较前后季度目标，并非实际交易资金流。',
          ),
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 10),
        for (final row in asList(q['positions']))
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Material(
              color: p.card,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                key: ValueKey('holding-${row['ticker']}'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => evidence(row),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '#${row['rank']}',
                          style: s(12, false, p.muted),
                        ),
                      ),
                      StockLogo(
                        ticker: text(row['ticker']),
                        palette: p,
                        size: 30,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(text(row['ticker']), style: s(15, true)),
                            Text(
                              '${w('Score', '评分')} ${decimal(row['score'])} · ${row['action'] == 'new' ? w('New', '新建') : w('Rebalance', '调仓')}',
                              style: s(11, false, p.muted),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            pct(row['weight']),
                            style: s(16, true, color(active)),
                          ),
                          Text(
                            '${pct(row['previousTargetWeight'])} → ${pct(row['weight'])}',
                            style: s(10, false, p.muted),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.chevron_right, color: p.muted, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (asList(q['exits']).isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            w('Exited this quarter', '本季度退出'),
            style: s(13, true, p.secondary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final row in asList(q['exits']))
                Chip(
                  label: Text(
                    '${row['ticker']} · ${pct(row['previousTargetWeight'])} → 0%',
                    style: s(11),
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  String inputName(String id) => switch (id) {
    'revenue_yoy' => w('Quarterly revenue YoY', '季度收入同比'),
    'opmargin' => w('TTM operating margin', 'TTM 营业利润率'),
    'fcfmargin' => w('TTM FCF margin', 'TTM 自由现金流利润率'),
    'roic_min5' => w('Minimum 5Y pretax capital return', '五年最低税前资本回报'),
    'roic_verified' => w('TTM pretax capital return', 'TTM 税前资本回报'),
    'fcf_yield' => w('TTM FCF / market cap', 'TTM 自由现金流 / 市值'),
    'operating_earnings_yield' => w(
      'TTM EBIT / simplified EV',
      'TTM EBIT / 简化企业价值',
    ),
    'opmargin_change_yoy' => w('Quarterly margin YoY change', '季度利润率同比变化'),
    'net_equity_cash_payout_yield' => w(
      'Net equity cash payout / market cap',
      '股票净融资流出 / 市值',
    ),
    _ => id,
  };

  Future<void> evidence(Map<String, dynamic> row) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.panel,
      title: Text('${row['ticker']} · #${row['rank']}', style: s(21, true)),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${q['quarter']} · ${w('Population', '排名样本')} ${q['populationCount']} · ${w('Score', '得分')} ${decimal(row['score'])}',
                style: s(12, false, p.muted),
              ),
              const SizedBox(height: 12),
              for (final input in asList(row['inputs']))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(inputName(text(input['id'])), style: s(13, true)),
                      Text(
                        '${w('Raw', '原始值')} ${pct(input['value'])}',
                        style: s(14, false, p.accent),
                      ),
                      Text(
                        '${w('Percentile', '分位数')} ${pct(input['percentile'])} × ${w('weight', '权重')} ${pct(input['weight'])} = ${w('contribution', '贡献')} ${decimal(input['contribution'])}',
                        style: s(12, false, p.muted),
                      ),
                    ],
                  ),
                ),
              if (active == 'quality_rank')
                Text(
                  '${w('Conviction', '配置系数')} √(11 − ${row['rank']}) = ${decimal(row['conviction'])}\n${w('Legacy pretax-return screen', '沿用税前回报筛选')} ${pct(row['pretaxReturn'])} > ${w('assumed WACC', '假设 WACC')} ${pct(row['wacc'])}',
                  style: s(12),
                ),
              const SizedBox(height: 12),
              Text(
                w(
                  'Fact OS · SF1 · original-availability dates on current-vintage facts',
                  'Fact OS · SF1 · 当前版本事实，按原始披露日筛选',
                ),
                style: s(12, true),
              ),
              for (final entry in asMap(row['sourcePeriods']).entries)
                Text(
                  '${sourceLabel(entry.key)}: ${entry.value}',
                  style: s(11, false, p.muted),
                ),
              for (final entry in asMap(row['sourceDates']).entries)
                Text(
                  '${sourceLabel(entry.key)}: ${entry.value}',
                  style: s(11, false, p.muted),
                ),
              Text(
                '${w('Method', '方法')} ${asMap(selected['rule'])['methodId']}',
                style: s(10, false, p.muted),
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
            widget.onCompany(text(row['ticker']));
          },
          child: Text(w('Research company', '研究公司')),
        ),
      ],
    ),
  );

  String sourceLabel(String key) => switch (key) {
    'ttm_reportperiod' => w('TTM period end', 'TTM 期末'),
    'q0_reportperiod' => w('Quarter period end', '季度期末'),
    'y0_reportperiod' => w('Annual period end', '年度期末'),
    'ttm_date' => w('TTM available', 'TTM 披露日'),
    'q0_date' => w('Quarter available', '本季度披露日'),
    'q4_date' => w('Year-ago quarter available', '去年同期披露日'),
    _ => w(
      'Annual observation ${key.substring(1, 2)} available',
      '年度观测 ${key.substring(1, 2)} 披露日',
    ),
  };

  Widget method() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(w('How the strategy works', '策略如何运作'), style: s(19, true)),
        const SizedBox(height: 10),
        Text(
          active == 'quality_rank'
              ? w(
                  'Score = 25% revenue-growth percentile + 25% operating-margin percentile + 25% FCF-margin percentile + 25% five-year minimum pretax-capital-return percentile. Rank before gates; ties use lower historical Beta, then ticker.',
                  '评分 = 收入增速分位数 ×25% + 营业利润率分位数 ×25% + 自由现金流利润率分位数 ×25% + 五年最低税前资本回报分位数 ×25%。先按固定样本评分，再筛选；同分依次按历史 Beta 较低、股票代码排序。',
                )
              : w(
                  'Score = 40% quality (equal shares of pretax capital return, FCF margin and operating margin) + 30% value (FCF yield and EBIT / simplified EV) + 30% improvement (margin change and net-equity cash payout yield). Each input is an average-rank percentile in the complete matched cohort, before gates. Ties use ticker.',
                  '评分 = 质量组40%（税前资本回报、自由现金流利润率、营业利润率等权）+ 价值组30%（FCF收益率、EBIT/简化企业价值等权）+ 改善组30%（利润率变化、股票净融资流出收益率等权）。指标先在完整可比样本内计算平均排名分位数，再筛选；同分按代码排序。',
                ),
          style: s(13),
        ),
        const SizedBox(height: 12),
        Text(
          active == 'quality_rank'
              ? w(
                  'Gates: revenue YoY > 8%; TTM operating margin ≥ 10%; TTM FCF margin ≥ 5%; each of five annual pretax returns ≥ 10%; latest pretax return above assumed WACC. Keep only ranks 1–10. Conviction = sqrt(11 − rank); normalize, then cap each target at 15%. Capped excess stays cash; no leverage, no buffer retention.',
                  '门槛：收入同比 >8%；TTM营业利润率 ≥10%；TTM自由现金流率 ≥5%；过去五年税前资本回报每年 ≥10%；最新税前回报高于假设WACC。仅持有前10名。配置系数 = √(11−排名)，归一化后逐股限制15%；超额留现金，不加杠杆，也不保留缓冲区旧持仓。',
                )
              : w(
                  'Gates: positive revenue, FCF, EBITDA and simplified EV; net debt / EBITDA ≤ 3. Buy the top 20 at 5% each. Unfilled slots stay cash. Exit names outside the selection; reset remaining targets each quarter. Net common-equity financing is not gross buybacks. This proxy does not implement activism or qualitative catalysts.',
                  '门槛：收入、FCF、EBITDA和简化企业价值均为正；净债务/EBITDA ≤3。前20名各占5%，不足20名的空位留现金。退出落选公司，每季度重设目标权重。股票净融资并非总回购额；此代理不包含主动干预或主观催化判断。',
                ),
          style: s(13),
        ),
        const SizedBox(height: 12),
        Text(
          w(
            'Execution: quarter-end information, next SPY session close; long only; zero cash yield; adjusted total-return prices. Costs: 25 bps per dollar bought or sold, including initial entry, no terminal liquidation. SPY is uncharged. Missing held prices block the replay; only verified corporate actions are applied.',
            '执行：季度末可知信息，下一SPY交易日收盘调仓；只做多，现金收益为零，采用总回报调整价格。每单位买卖金额计25bp，含首次建仓，不计期末清仓；SPY不扣费。持仓价格缺失会阻断回测，仅应用已核实公司行动。',
          ),
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 12),
        Text(
          w(
            'Research limits: current-vintage facts and classifications, not strict archived-vintage PIT. Rules were explored after observing results; these are not validated alpha or actual fund returns. Provider capital return is pretax EBIT / average invested capital, not after-tax ROIC. Comparing it with assumed WACC is a legacy screen, not an economic value-creation spread.',
            '研究边界：使用当前版本事实与分类，不是严格历史版本 PIT。规则曾在查看结果后进行探索，不能视为已验证超额收益或真实基金业绩。供应商资本回报是税前 EBIT/平均投入资本，并非税后ROIC；与假设WACC的比较只是沿用筛选规则，不是经济价值创造利差。',
          ),
          style: s(12, false, p.secondary),
        ),
        if (active == 'quality_rank') ...[
          const SizedBox(height: 10),
          Text(
            w(
              'WACC assumptions: prior observed 10Y Treasury + clipped Beta [0.5, 2] × 5% for equity; debt cost = max(interest/debt, Treasury + 1.5%), capped at 15%, with assumed 21% tax. Capital weights use observed market cap and debt. Beta is not a score component.',
              'WACC假设：股权成本=此前可观测10年国债利率+限制在[0.5,2]内的Beta×5%；债务成本=max(利息/债务,国债+1.5%)，上限15%，假设税率21%。资本权重按当时市值和债务计算。Beta不参与评分。',
            ),
            style: s(11, false, p.muted),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          '${w('Method', '方法')} ${asMap(selected['rule'])['methodId']} · ${w('Snapshot', '快照')} ${text(data?['snapshotId']).substring(0, math.min(12, text(data?['snapshotId']).length))}',
          style: s(10, false, p.muted),
        ),
      ],
    ),
  );
}
