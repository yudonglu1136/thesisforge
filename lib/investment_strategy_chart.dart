part of 'main.dart';

// Full daily rows, not painted or sampled points, drive selected-range metrics.
Map<String, double?> strategyRangeMetrics(
  List<Map<String, dynamic>> rows, {
  bool includeEntry = false,
}) {
  if (rows.length < 2) return {};
  final origin = includeEntry ? 1.0 : number(rows.first['value']);
  final values = rows.map((r) => number(r['value']) / origin).toList();
  final returns = [
    for (var i = 1; i < values.length; i++) values[i] / values[i - 1] - 1,
  ];
  final avg = returns.reduce((a, b) => a + b) / returns.length;
  final variance = returns.length > 1
      ? returns
                .map((r) => math.pow(r - avg, 2).toDouble())
                .reduce((a, b) => a + b) /
            (returns.length - 1)
      : null;
  var peak = 1.0, drawdown = 0.0;
  for (final v in values) {
    peak = math.max(peak, v);
    drawdown = math.min(drawdown, v / peak - 1);
  }
  final days = DateTime.parse(
    text(rows.last['date']),
  ).difference(DateTime.parse(text(rows.first['date']))).inDays;
  return {
    'totalReturn': values.last - 1,
    'cagr': days > 0
        ? math.pow(values.last, 365.25 / days).toDouble() - 1
        : null,
    'maxDrawdown': drawdown,
    'volatility': variance == null ? null : math.sqrt(variance * 252),
    'sharpeZeroRf': variance != null && variance > 0
        ? avg / math.sqrt(variance) * math.sqrt(252)
        : null,
  };
}

class StrategyLabChart extends StatefulWidget {
  const StrategyLabChart({
    super.key,
    required this.data,
    required this.palette,
  });
  final Map<String, dynamic> data;
  final Palette palette;
  @override
  State<StrategyLabChart> createState() => _StrategyLabChartState();
}

class _StrategyLabChartState extends State<StrategyLabChart> {
  RangeValues range = const RangeValues(0, 1);
  bool drawdown = false;
  int? hover;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle style([double size = 13, bool bold = false, Color? color]) =>
      TextStyle(
        fontSize: size,
        color: color ?? p.text,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        height: 1.4,
      );
  final hidden = <String>{};
  String pct(dynamic n) => nullableNumber(n) == null
      ? '—'
      : '${(number(n) * 100).toStringAsFixed(1)}%';
  String name(String key) => switch (key) {
    'guru' =>
      asMap(widget.data['rules'])['equityMix'] != null
          ? w('Equity mix · unfiltered', '股票组合 · 未做估值过滤')
          : widget.data['selectionBasis'] == 'eligible_subset_full_investment'
          ? w('Eligible stocks · unfiltered', '可买股票 · 未做估值过滤')
          : w('Guru · unfiltered', '大佬 · 未过滤'),
    'filtered' =>
      asMap(widget.data['rules'])['equityMix'] != null
          ? w('Equity mix · filtered', '股票组合 · 估值过滤')
          : w('Stocks · filtered', '股票 · 估值过滤'),
    'blend' => w('Your blend · 1×', '你的混合组合 · 1×'),
    'leveraged' => w(
      'Leveraged · ${number(asMap(asMap(widget.data['rules'])['leverage'])['multiple']).toStringAsFixed(2)}×',
      '杠杆组合 · ${number(asMap(asMap(widget.data['rules'])['leverage'])['multiple']).toStringAsFixed(2)}×',
    ),
    _ => 'SPY',
  };
  Color color(String key) => switch (key) {
    'guru' => p.muted,
    'filtered' => const Color(0xff72b9e8),
    'blend' => p.accent,
    'leveraged' => const Color(0xffba9cff),
    _ => p.secondary,
  };
  @override
  void didUpdateWidget(covariant StrategyLabChart old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) {
      range = const RangeValues(0, 1);
      hover = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = asMap(widget.data['results']);
    final available = <String, List<Map<String, dynamic>>>{
      for (final key in ['guru', 'filtered', 'blend', 'leveraged', 'spy'])
        if (results[key]?['status'] == 'ready')
          key: asList(results[key]['equity']),
    };
    if (available.isEmpty) {
      return Text(
        w(
          'No complete curve is available for these rules. Open the rebalance audit for the exact data failure.',
          '这组规则暂时没有完整曲线，可在调仓审计中查看具体数据问题。',
        ),
        style: style(14, false, p.muted),
      );
    }
    final count = available.values.first.length;
    if (count < 2) return const SizedBox.shrink();
    final begin = (range.start * (count - 1)).round().clamp(0, count - 2),
        finish = (range.end * (count - 1)).round().clamp(begin + 1, count - 1);
    final slices = {
      for (final e in available.entries)
        e.key: e.value.sublist(begin, finish + 1),
    };
    final selected = slices.values.first;
    final metrics = {
      for (final e in slices.entries)
        e.key: strategyRangeMetrics(e.value, includeEntry: begin == 0),
    };
    final plot = <String, List<double>>{};
    for (final e in slices.entries) {
      final origin = begin == 0 ? 1.0 : number(e.value.first['value']);
      var peak = origin;
      plot[e.key] = e.value.map((r) {
        final value = number(r['value']);
        peak = math.max(peak, value);
        return drawdown ? (value / peak - 1) * 100 : value / origin * 100;
      }).toList();
    }
    final cursor = (hover ?? selected.length - 1).clamp(0, selected.length - 1);
    final currentRules = asMap(widget.data['rules']),
        latest = asMap(asMap(widget.data['summary'])['latest']);
    final mixWeights = asMap(asMap(currentRules['equityMix'])['weights']);
    final selectionSummary = mixWeights.isEmpty
        ? '${asList(asMap(widget.data['sources'])['managers']).isEmpty ? (currentRules['managers'] as List? ?? []).join(' + ') : asList(asMap(widget.data['sources'])['managers']).map((m) => text(m['name'])).join(' + ')} · Top ${currentRules['topN']}'
        : mixWeights.entries
              .where((e) => number(e.value) > 0)
              .map(
                (e) =>
                    '${strategyComponentName(context, e.key)} ${pct(e.value)}',
              )
              .join(' · ');
    final filterSummary =
        mixWeights.isNotEmpty &&
            number(mixWeights['guru']) == 0 &&
            number(mixWeights['factors']) == 0
        ? w('Index ETFs exempt from valuation filtering', '指数 ETF 不做个股估值过滤')
        : currentRules['valuationEnabled'] == true
        ? w(
            'Premium limit ${pct(currentRules['maxPremium'])}',
            '溢价上限 ${pct(currentRules['maxPremium'])}',
          )
        : w('Valuation filter off', '未启用估值过滤');
    final finalCurve = asMap(
      results[number(asMap(currentRules['leverage'])['multiple']) > 1
          ? 'leveraged'
          : 'blend'],
    );
    final allocationHistory = asList(finalCurve['allocationHistory']);
    final cash = allocationHistory.isEmpty
            ? number(latest['cashWeight'])
            : number(allocationHistory.last['cashWeight']),
        cta = allocationHistory.isEmpty
            ? number(latest['ctaWeight'])
            : number(allocationHistory.last['ctaWeight']),
        stocks = math.max(0.0, 1 - cash - cta);
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(w('Portfolio backtest', '组合回测'), style: style(22, true)),
              Text(
                '${selected.first['date']} → ${selected.last['date']}',
                style: style(12, false, p.muted),
              ),
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
          const SizedBox(height: 8),
          Text(
            '$selectionSummary · $filterSummary',
            style: style(13, true, p.text),
          ),
          if (number(mixWeights['factors']) > 0) ...[
            const SizedBox(height: 8),
            Text(
              strategyFactorSummary(context, asMap(currentRules['equityMix'])),
              style: style(12, false, p.muted),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            w(
              'Same dates · fractional holdings · ${currentRules['costBps']} bps on buys + sells · SPY before trading costs',
              '同一区间 · 可持有零碎股 · 买卖金额收取 ${currentRules['costBps']} bps · SPY 未扣交易费用',
            ),
            style: style(11, false, p.muted),
          ),
          if (cta > 0)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '${w('Initial blend', '初始配置')}: ${pct(1 - number(currentRules['ctaWeight']))} ${w('stock sleeve', '股票部分')} + ${pct(currentRules['ctaWeight'])} ${currentRules['cta']}${currentRules['ctaPolicy'] == null ? '' : ' · ${strategyCtaMode(context, asMap(currentRules['ctaPolicy']))}'}',
                style: style(12, false, p.accent),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final key in available.keys)
                FilterChip(
                  selected: !hidden.contains(key),
                  selectedColor: color(key).withValues(alpha: .12),
                  avatar: Icon(
                    key == 'spy' ? Icons.more_horiz : Icons.show_chart,
                    color: color(key),
                    size: 17,
                  ),
                  label: Text(name(key), style: style(12, true, color(key))),
                  onSelected: (on) => setState(() {
                    if (on) {
                      hidden.remove(key);
                    } else if (hidden.length < available.length - 1) {
                      hidden.add(key);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              Text(text(selected[cursor]['date']), style: style(12, true)),
              for (final key in available.keys.where(
                (k) => !hidden.contains(k),
              ))
                Text(
                  '${name(key)}  ${plot[key]![cursor].toStringAsFixed(2)}${drawdown ? '%' : ''}',
                  style: style(12, false, color(key)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (ctx, c) {
              void inspect(double x) {
                final index =
                    ((x - 46) / (c.maxWidth - 62) * (selected.length - 1))
                        .round()
                        .clamp(0, selected.length - 1);
                setState(() => hover = index);
              }

              return Semantics(
                label: w(
                  'Daily ${drawdown ? 'drawdown' : 'indexed value'} comparison. Use the range control below; exact selected-range statistics follow.',
                  '每日${drawdown ? '回撤' : '净值'}对比。下方可调整区间并查看精确统计。',
                ),
                child: MouseRegion(
                  onHover: (e) => inspect(e.localPosition.dx),
                  onExit: (_) => setState(() => hover = null),
                  child: GestureDetector(
                    onTapDown: (e) => inspect(e.localPosition.dx),
                    child: SizedBox(
                      width: c.maxWidth,
                      height: 280,
                      child: CustomPaint(
                        painter: StrategyCurvePainter(
                          series: {
                            for (final e in plot.entries)
                              if (!hidden.contains(e.key)) e.key: e.value,
                          },
                          colors: {for (final k in plot.keys) k: color(k)},
                          palette: p,
                          drawdown: drawdown,
                          cursor: cursor,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 46, right: 16),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    text(selected.first['date']),
                    style: style(10, false, p.muted),
                  ),
                  Text(
                    text(selected.last['date']),
                    style: style(10, false, p.muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  w('Drag to inspect a period', '拖动查看任意区间'),
                  style: style(12, false, p.muted),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  range = const RangeValues(0, 1);
                  hover = null;
                }),
                child: Text(w('Full range', '全部区间')),
              ),
            ],
          ),
          RangeSlider(
            values: range,
            min: 0,
            max: 1,
            divisions: count - 1,
            labels: RangeLabels(
              text(selected.first['date']),
              text(selected.last['date']),
            ),
            onChanged: (v) {
              if ((v.end - v.start) * (count - 1) >= 1) {
                setState(() {
                  range = v;
                  hover = null;
                });
              }
            },
          ),
          Text(
            w(
              '$count actual daily observations. Selected windows rebase the curves and recalculate the table; they do not rerun selection. Entry cost is retained when the original start is included.',
              '$count 个真实日频观测。选择区间会重置曲线起点并重算下表，不重新执行选股；包含原起点时保留建仓费用。',
            ),
            style: style(11, false, p.muted),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: DataTable(
                  horizontalMargin: 0,
                  columnSpacing: 25,
                  headingRowHeight: 38,
                  dataRowMinHeight: 46,
                  dataRowMaxHeight: 54,
                  columns: [
                    for (final c in [
                      ('Strategy', '策略'),
                      ('Total return', '累计收益'),
                      ('CAGR', '年化收益'),
                      ('Max drawdown', '最大回撤'),
                      ('Volatility', '波动率'),
                      ('Sharpe · 0% Rf', '夏普 · 0% 无风险'),
                    ])
                      DataColumn(
                        label: Text(
                          w(c.$1, c.$2),
                          style: style(12, false, p.muted),
                        ),
                      ),
                  ],
                  rows: [
                    for (final k in [
                      'guru',
                      'filtered',
                      'blend',
                      if (number(asMap(currentRules['leverage'])['multiple']) >
                          1)
                        'leveraged',
                      'spy',
                    ])
                      DataRow(
                        cells: [
                          DataCell(
                            Text(name(k), style: style(13, true, color(k))),
                          ),
                          for (final field in [
                            'totalReturn',
                            'cagr',
                            'maxDrawdown',
                            'volatility',
                            'sharpeZeroRf',
                          ])
                            DataCell(
                              Text(
                                metrics[k] == null
                                    ? '—'
                                    : field == 'sharpeZeroRf'
                                    ? (metrics[k]?[field]?.toStringAsFixed(2) ??
                                          '—')
                                    : pct(metrics[k]?[field]),
                                style: style(
                                  13,
                                  k == 'blend' || k == 'leveraged',
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Divider(color: p.border),
          const SizedBox(height: 14),
          Text(
            allocationHistory.isEmpty
                ? w('Last rebalance · unlevered allocation', '最后一次调仓 · 未加杠杆配置')
                : w(
                    'End of backtest · allocation before leverage',
                    '回测期末 · 杠杆前配置',
                  ),
            style: style(15, true),
          ),
          const SizedBox(height: 8),
          Text(
            allocationHistory.isEmpty
                ? '${latest['executionDate'] ?? '—'} · ${w('Target weights, not today’s drifting weights', '目标权重，不是当前漂移后的权重')}'
                : '${allocationHistory.last['date']} · ${w('Actual simulated weights after market drift', '市场漂移后的实际模拟权重')}',
            style: style(11, false, p.muted),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Row(
              children: [
                if (stocks > 0)
                  Expanded(
                    flex: math.max(1, (stocks * 10000).round()),
                    child: Container(height: 12, color: p.accent),
                  ),
                if (cta > 0)
                  Expanded(
                    flex: math.max(1, (cta * 10000).round()),
                    child: Container(height: 12, color: p.secondary),
                  ),
                if (cash > 0)
                  Expanded(
                    flex: math.max(1, (cash * 10000).round()),
                    child: Container(height: 12, color: p.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 20,
            runSpacing: 6,
            children: [
              Text(
                '${w('Stocks', '股票')} ${pct(stocks)}',
                style: style(13, true, p.accent),
              ),
              Text(
                '${currentRules['cta'] == 'none' ? 'CTA' : currentRules['cta']} ${pct(cta)}',
                style: style(13, true, p.secondary),
              ),
              Text(
                '${w('Cash', '现金')} ${pct(cash)}',
                style: style(13, true, p.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class StrategyCurvePainter extends CustomPainter {
  StrategyCurvePainter({
    required this.series,
    required this.colors,
    required this.palette,
    required this.drawdown,
    required this.cursor,
  });
  final Map<String, List<double>> series;
  final Map<String, Color> colors;
  final Palette palette;
  final bool drawdown;
  final int cursor;
  @override
  void paint(Canvas canvas, Size size) {
    final points = series.values.expand((v) => v).toList();
    if (points.isEmpty) return;
    var low = points.reduce(math.min), high = points.reduce(math.max);
    if (drawdown) {
      high = 0;
      low = math.min(low, -1);
    } else {
      low = math.min(low, 100);
      high = math.max(high, 100);
    }
    final delta = math.max(high - low, 1.0);
    if (!drawdown) high += delta * .07;
    low -= delta * .06;
    const left = 46.0, right = 16.0, top = 12.0, bottom = 10.0;
    final width = size.width - left - right,
        height = size.height - top - bottom;
    double y(double v) => top + (high - v) / (high - low) * height;
    for (var i = 0; i <= 4; i++) {
      final value = low + (high - low) * i / 4, py = y(value);
      canvas.drawLine(
        Offset(left, py),
        Offset(size.width - right, py),
        Paint()
          ..color = palette.border
          ..strokeWidth = .7,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${value.toStringAsFixed(0)}${drawdown ? '%' : ''}',
          style: TextStyle(fontSize: 10, color: palette.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 42);
      label.paint(
        canvas,
        Offset(left - label.width - 8, py - label.height / 2),
      );
    }
    // Preserve legacy layering, then paint new callers' explicitly enabled
    // series too; a fixed ID allow-list silently hid the rule portfolios.
    for (final key in {
      'guru',
      'filtered',
      'spy',
      'blend',
      'leveraged',
      ...series.keys,
    }) {
      final values = series[key];
      if (values == null || values.length < 2) continue;
      final path = Path();
      for (var i = 0; i < values.length; i++) {
        final x = left + width * i / (values.length - 1);
        if (i == 0) {
          path.moveTo(x, y(values[i]));
        } else {
          path.lineTo(x, y(values[i]));
        }
      }
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = key == 'blend' || key == 'leveraged' ? 2.5 : 1.5
        ..color = colors[key]!;
      if (key == 'spy') {
        for (final metric in path.computeMetrics()) {
          for (var offset = 0.0; offset < metric.length; offset += 11) {
            canvas.drawPath(
              metric.extractPath(offset, math.min(offset + 6, metric.length)),
              pen,
            );
          }
        }
      } else {
        canvas.drawPath(path, pen);
      }
      final cx = left + width * cursor / (values.length - 1);
      canvas.drawCircle(
        Offset(cx, y(values[cursor])),
        3,
        Paint()..color = colors[key]!,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StrategyCurvePainter old) => true;
}
