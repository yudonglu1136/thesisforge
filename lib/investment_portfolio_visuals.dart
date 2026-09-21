part of 'main.dart';

// These charts render the API's reported weights, never synthetic holdings or
// amounts. Cash and short exposures cannot be slices of a long-only allocation.
List<Map<String, dynamic>> portfolioAllocationSlices(
  List<Map<String, dynamic>> source, {
  String nameKey = 'ticker',
  int limit = 5,
}) {
  final rows =
      source
          .where((r) {
            final value = nullableNumber(r['weight']);
            return value != null && value.isFinite && value > 0;
          })
          .map(
            (r) => <String, dynamic>{
              'name': text(r[nameKey]),
              'weight': r['weight'],
              if (r['value'] != null) 'value': r['value'],
              if (r['category'] != null) 'category': r['category'],
              if (r['quantity'] != null) 'quantity': r['quantity'],
              if (r['perShare'] != null) 'perShare': r['perShare'],
              if (r['ticker'] != null && nameKey != 'ticker')
                'ticker': r['ticker'],
            },
          )
          .toList()
        ..sort((a, b) => number(b['weight']).compareTo(number(a['weight'])));
  final total = rows.fold<double>(0, (sum, r) => sum + number(r['weight']));
  // Reject inconsistent totals instead of silently rescaling the report.
  if (total > 1.001 || rows.isEmpty) return [];
  final result = rows.take(limit).toList();
  final other = rows
      .skip(limit)
      .fold<double>(0, (sum, r) => sum + number(r['weight']));
  if (other > 0) {
    final tail = rows.skip(limit).toList();
    result.add({
      'name': 'Other',
      'weight': other,
      'aggregate': true,
      if (tail.every((r) => nullableNumber(r['value']) != null))
        'value': tail.fold<double>(0, (n, r) => n + number(r['value'])),
    });
  }
  if (total < .999) {
    result.add({'name': 'Unspecified', 'weight': 1 - total, 'aggregate': true});
  }
  return result;
}

Color portfolioChartColor(int index, Palette p) => [
  p.accent,
  const Color(0xFF72A9F8),
  const Color(0xFFB9A1EE),
  p.secondary,
  const Color(0xFF78CAD4),
  p.faint,
  const Color(0xFFB1B9C4),
][index % 7];

// Follow only the API's explicit economic-model link, not a guessed ticker
// alias. The portfolio continues to display the held share class and its price.
String portfolioValuationTicker(Map<String, dynamic> group, String ticker) {
  final position = asList(
    group['positions'],
  ).where((row) => text(row['ticker']) == ticker).firstOrNull;
  final linked = text(asMap(position?['model'])['modelTicker']).trim();
  return linked.isEmpty ? ticker : linked;
}

class PortfolioAllocationChart extends StatefulWidget {
  const PortfolioAllocationChart({
    super.key,
    required this.group,
    required this.palette,
    required this.onHolding,
    this.hideAmounts = false,
    this.compact = false,
  });
  final Map<String, dynamic> group;
  final Palette palette;
  final ValueChanged<String> onHolding;
  final bool hideAmounts;
  final bool compact;
  @override
  State<PortfolioAllocationChart> createState() =>
      _PortfolioAllocationChartState();
}

class _PortfolioAllocationChartState extends State<PortfolioAllocationChart> {
  bool sectors = false;
  bool income = false, incomeTypes = false;
  String? selected;
  String? hovered;
  String w(String en, String zh) => context.tr(zh, en);
  @override
  void didUpdateWidget(covariant PortfolioAllocationChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group['currency'] != widget.group['currency']) {
      selected = null;
      hovered = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final received = asMap(asMap(widget.group['home'])['trailingDividends']);
    final slices = portfolioAllocationSlices(
      income
          ? received['status'] == 'ready'
                ? asList(
                    received[incomeTypes ? 'byType' : 'byInstrument'],
                  ).map((r) => {...r, 'value': r['amount']}).toList()
                : []
          : asList(widget.group[sectors ? 'sectors' : 'concentration']),
      nameKey: income
          ? 'id'
          : sectors
          ? 'name'
          : 'ticker',
      limit: income && !incomeTypes ? 100 : 5,
    );
    final pinned = slices.indexWhere((s) => s['name'] == selected);
    final over = slices.indexWhere((s) => s['name'] == hovered);
    final active = over >= 0 ? over : pinned;
    final top = sectors
        ? slices
              .where((s) => s['aggregate'] != true)
              .take(5)
              .fold<double>(0, (sum, s) => sum + number(s['weight']))
        : nullableNumber(widget.group['top5Weight']);
    String category(dynamic key) => switch (key) {
      'dividends' => w('Dividends', '股息'),
      'bond_interest' => w('Bond interest', '债券利息'),
      'cash_interest' => w('Cash interest', '现金利息'),
      'substitute_dividends' => w('Dividend substitutes', '代付股息'),
      _ => w('Income', '收入'),
    };
    String label(Map<String, dynamic> s) => switch (s['name']) {
      'Other' =>
        income
            ? w('Other income sources', '其他收入来源')
            : w('Other holdings', '其余持仓'),
      'Unspecified' => w('Unspecified', '未注明'),
      'Unclassified' => w('Unclassified', '未分类'),
      _ =>
        income
            ? incomeTypes || s['ticker'] == 'CASH'
                  ? category(s['category'])
                  : text(s['ticker'])
            : text(s['name']),
    };
    String details(Map<String, dynamic> s) => [
      label(s),
      if (income &&
          !incomeTypes &&
          s['ticker'] != 'CASH' &&
          s['aggregate'] != true)
        category(s['category']),
      '${(number(s['weight']) * 100).toStringAsFixed(1)}%',
      if (!widget.hideAmounts && nullableNumber(s['value']) != null)
        '${widget.group['currency']} ${formatNumber(number(s['value']))}',
      if (income &&
          !incomeTypes &&
          !widget.hideAmounts &&
          nullableNumber(s['quantity']) != null &&
          nullableNumber(s['perShare']) != null)
        '${formatNumber(number(s['quantity']))} ${w('current shares', '当前股数')} × USD ${number(s['perShare']).toStringAsFixed(2)} ${w('TTM / share', '过去12个月每股')}',
    ].join(' · ');
    final selectedWeight = active >= 0
        ? number(slices[active]['weight'])
        : income
        ? 1.0
        : top;
    final modelTicker = selected == null
        ? ''
        : portfolioValuationTicker(widget.group, selected!);
    String? hit(Offset local, double size) {
      final offset = local - Offset(size / 2, size / 2);
      if (offset.distance < size / 2 - 30 || offset.distance > size / 2) {
        return null;
      }
      final angle =
          (math.atan2(offset.dy, offset.dx) + math.pi / 2 + math.pi * 2) %
          (math.pi * 2);
      var through = 0.0;
      for (final s in slices) {
        through += number(s['weight']) * math.pi * 2;
        if (angle <= through) return text(s['name']);
      }
      return null;
    }

    Widget ring(double size) => SizedBox(
      key: const ValueKey('portfolio-allocation-donut'),
      width: size,
      height: size,
      child: Semantics(
        label: w(
          'Hover or tap a slice, or select a legend row to inspect.',
          '悬停或点选扇区，也可选择图例查看。',
        ),
        child: MouseRegion(
          onHover: (event) {
            final value = hit(event.localPosition, size);
            if (value != hovered) setState(() => hovered = value);
          },
          onExit: (_) => setState(() => hovered = null),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapUp: (event) {
              final value = hit(event.localPosition, size);
              if (value != null) setState(() => selected = value);
            },
            child: CustomPaint(
              painter: _PortfolioDonutPainter(slices, p, active),
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(size * .20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        active >= 0
                            ? label(slices[active])
                            : income
                            ? w('Estimated TTM dividends', '估算过去12个月股息')
                            : w('Top 5', '前五大'),
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        child: Text(
                          income && active < 0 && !widget.hideAmounts
                              ? formatNumber(number(received['annualAmount']))
                              : selectedWeight == null
                              ? '—'
                              : '${(selectedWeight * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            color: p.text,
                            fontSize: size * .16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (income && active < 0 && !widget.hideAmounts)
                        Text(
                          text(widget.group['currency']),
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final legend = Column(
      children: [
        for (var i = 0; i < slices.length; i++)
          MouseRegion(
            onEnter: (_) => setState(() => hovered = text(slices[i]['name'])),
            onExit: (_) => setState(() => hovered = null),
            child: Tooltip(
              message: details(slices[i]),
              child: Semantics(
                selected: active == i,
                child: TextButton(
                  key: ValueKey('allocation-legend-${slices[i]['name']}'),
                  style: TextButton.styleFrom(
                    foregroundColor: p.text,
                    backgroundColor: active == i
                        ? portfolioChartColor(i, p).withValues(alpha: .10)
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () =>
                      setState(() => selected = text(slices[i]['name'])),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: portfolioChartColor(i, p),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label(slices[i]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (income &&
                                !incomeTypes &&
                                slices[i]['aggregate'] != true &&
                                slices[i]['ticker'] != 'CASH')
                              Text(
                                category(slices[i]['category']),
                                style: TextStyle(color: p.muted, fontSize: 10),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(number(slices[i]['weight']) * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                key: const ValueKey('allocation-position'),
                label: Text(w('Position', '仓位')),
                selected: !income,
                onSelected: (_) => setState(() {
                  income = false;
                  selected = null;
                  hovered = null;
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('allocation-income'),
                label: Text(w('TTM dividends', '过去12个月股息')),
                selected: income,
                onSelected: (_) => setState(() {
                  income = true;
                  selected = null;
                  hovered = null;
                }),
              ),
              const SizedBox(width: 12),
              Container(width: 1, height: 24, color: p.border),
              const SizedBox(width: 12),
              ChoiceChip(
                key: const ValueKey('allocation-breakdown-primary'),
                label: Text(
                  income
                      ? w('Dividend holdings', '股息来源持仓')
                      : w('Holdings', '持仓'),
                ),
                selected: income ? !incomeTypes : !sectors,
                onSelected: (_) => setState(() {
                  if (income) {
                    incomeTypes = false;
                  } else {
                    sectors = false;
                  }
                  selected = null;
                  hovered = null;
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('allocation-breakdown-secondary'),
                label: Text(
                  income ? w('Income type', '收入类型') : w('Sectors', '行业'),
                ),
                selected: income ? incomeTypes : sectors,
                onSelected: (_) => setState(() {
                  if (income) {
                    incomeTypes = true;
                  } else {
                    sectors = true;
                  }
                  selected = null;
                  hovered = null;
                }),
              ),
            ],
          ),
        ),
        if (income) ...[
          const SizedBox(height: 12),
          Text(
            w(
              'Sharadar trailing 12 months · ${text(received['fromDate'], '—')} → ${text(received['toDate'], '—')} · ${text(received['coveredHoldings'], '—')}/${text(received['eligibleHoldings'], '—')} holdings covered',
              'Sharadar 过去12个月 · ${text(received['fromDate'], '—')} → ${text(received['toDate'], '—')} · 覆盖 ${text(received['coveredHoldings'], '—')}/${text(received['eligibleHoldings'], '—')} 项持仓',
            ),
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
        ],
        SizedBox(height: widget.compact ? 12 : 20),
        if (slices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Text(
              income
                  ? received['status'] == 'ready'
                        ? w(
                            'No positive Sharadar dividend events were reported in the trailing 12 months.',
                            'Sharadar 在过去12个月未记录正数股息事件。',
                          )
                        : w(
                            'Trailing dividend facts are unavailable for these holdings. No legacy provider or broker receipt was substituted.',
                            '这些持仓缺少过去12个月股息事实，未使用旧数据源或券商到账记录替代。',
                          )
                  : w('Allocation data is not available.', '暂无可用仓位结构数据。'),
              style: TextStyle(color: p.muted),
            ),
          )
        else
          LayoutBuilder(
            builder: (_, c) {
              final size = widget.compact
                  ? c.maxWidth >= 440
                        ? 184.0
                        : 156.0
                  : c.maxWidth >= 440
                  ? 224.0
                  : 172.0;
              return c.maxWidth >= 330 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.2
                  ? Row(
                      children: [
                        ring(size),
                        SizedBox(width: widget.compact ? 12 : 18),
                        Expanded(child: legend),
                      ],
                    )
                  : Column(
                      children: [
                        ring(size),
                        const SizedBox(height: 12),
                        legend,
                      ],
                    );
            },
          ),
        if (slices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              key: const ValueKey('allocation-hover-detail'),
              constraints: BoxConstraints(minHeight: widget.compact ? 38 : 44),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                active >= 0
                    ? details(slices[active])
                    : w(
                        'Hover a slice to explore · tap to keep it selected',
                        '悬停扇区查看 · 点选保留选择',
                      ),
                style: TextStyle(
                  color: active >= 0 ? p.text : p.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ),
        if (pinned >= 0 &&
            !income &&
            !sectors &&
            slices[pinned]['aggregate'] != true)
          TextButton.icon(
            onPressed: () => widget.onHolding(text(slices[pinned]['name'])),
            icon: const Icon(Icons.arrow_forward, size: 16),
            label: Text(
              w(
                'Research ${slices[pinned]['name']}',
                '研究 ${slices[pinned]['name']}',
              ),
            ),
          ),
        if (pinned >= 0 && !income && !sectors && modelTicker != selected)
          Text(
            w(
              '$selected uses the $modelTicker economic per-share model. Research opens that model; portfolio weights and prices remain $selected.',
              '$selected 使用 $modelTicker 每股经济价值模型。研究入口打开该模型，持仓权重与价格仍为 $selected。',
            ),
            style: TextStyle(color: p.secondary, fontSize: 11, height: 1.5),
          ),
        SizedBox(height: widget.compact ? 8 : 14),
        Text(
          income
              ? w(
                  'Estimate = current verified shares × the sum of Sharadar split-adjusted dividend-per-share events over the trailing 12 months. Ex-date basis; not broker cash received, future dividends, withholding tax or FX.',
                  '估算值 = 当前已核验股数 × Sharadar 过去12个月拆股调整后每股股息事件之和。按除息日统计，不代表券商实际到账、未来股息、预扣税或汇率结果。',
                )
              : w(
                  'Positive non-cash exposure. Cash and shorts are separate.',
                  '正市值非现金持仓口径。现金与空头单独展示。',
                ),
          style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
        ),
        if (income && number(received['reversals']) < 0)
          Text(
            widget.hideAmounts
                ? w(
                    'Negative income reversals are excluded from this gross-receipts chart.',
                    '此总收入图不包含负数收入冲正。',
                  )
                : w(
                    'Income reversals excluded: ${widget.group['currency']} ${formatNumber(number(received['reversals']))}',
                    '未计入图中的收入冲正：${widget.group['currency']} ${formatNumber(number(received['reversals']))}',
                  ),
            style: TextStyle(color: p.secondary, fontSize: 11),
          ),
        if (income && asList(received['unavailableTickers']).isNotEmpty)
          Text(
            w(
              'Not covered: ${asList(received['unavailableTickers']).map((row) => text(row)).join(', ')}',
              '未覆盖：${asList(received['unavailableTickers']).map((row) => text(row)).join('、')}',
            ),
            style: TextStyle(color: p.secondary, fontSize: 11),
          ),
        if (sectors && !income)
          Text(
            w(
              'Stored issuer classifications; unknowns stay visible.',
              '使用已存发行人分类，未知分类保持可见。',
            ),
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
          ),
      ],
    );
  }
}

class _PortfolioDonutPainter extends CustomPainter {
  _PortfolioDonutPainter(this.slices, this.p, this.active);
  final List<Map<String, dynamic>> slices;
  final Palette p;
  final int active;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 14;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = p.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 21,
    );
    var angle = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = number(slices[i]['weight']) * 2 * math.pi;
      final gap = math.min(.025, sweep * .12);
      canvas.drawArc(
        rect,
        angle + gap / 2,
        sweep - gap,
        false,
        Paint()
          ..color = portfolioChartColor(
            i,
            p,
          ).withValues(alpha: active < 0 || i == active ? 1 : .35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == active ? 27 : 21,
      );
      angle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PortfolioDonutPainter old) =>
      old.slices != slices || old.active != active || old.p != p;
}

// A shared zero baseline makes positive and negative values comparable. Values
// are not independently scaled per row; labels retain exact unscaled values.
class PortfolioDivergingBar extends StatelessWidget {
  const PortfolioDivergingBar({
    super.key,
    required this.value,
    required this.extent,
    required this.palette,
  });
  final double? value;
  final double extent;
  final Palette palette;
  @override
  Widget build(BuildContext context) {
    final valid =
        value != null && value!.isFinite && extent.isFinite && extent > 0;
    final fraction = valid ? (value!.abs() / extent).clamp(0.0, 1.0) : 0.0;
    return LayoutBuilder(
      builder: (_, c) => SizedBox(
        height: 16,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              height: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.border.withValues(alpha: .45),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            if (valid)
              Positioned(
                left: value! < 0
                    ? c.maxWidth * .5 * (1 - fraction)
                    : c.maxWidth / 2,
                width: c.maxWidth * .5 * fraction,
                top: 5,
                height: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value! < 0 ? palette.negative : palette.accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            Positioned(
              left: c.maxWidth / 2,
              top: 1,
              bottom: 1,
              width: 1,
              child: ColoredBox(color: palette.muted.withValues(alpha: .65)),
            ),
          ],
        ),
      ),
    );
  }
}

extension _PortfolioVisualDashboard on _PortfolioResearchPanelState {
  Widget visualSectionHeader(
    String en,
    String zh,
    IconData icon, {
    Widget? action,
  }) => Row(
    children: [
      Icon(icon, color: p.accent, size: 18),
      const SizedBox(width: 10),
      Expanded(child: title(en, zh, 18)),
      ?action,
    ],
  );

  Widget portfolioHistoryPanel(Map<String, dynamic> g) {
    final h = asMap(g['home']);
    return panel([
      visualSectionHeader(
        'Portfolio value & P&L',
        '组合净值与盈亏',
        Icons.show_chart_rounded,
      ),
      const SizedBox(height: 18),
      PortfolioAccountValueChart(
        key: ValueKey('book-nav-$selectedCurrency'),
        rows: asList(asMap(h['nav'])['rows']),
        history: asMap(h['history']),
        currency: selectedCurrency,
        palette: p,
        hideAmounts: hideAmounts,
        chartHeight: 205,
      ),
      if (asList(asMap(h['nav'])['rows']).length < 2)
        TextButton.icon(
          onPressed: homeHistoryHelp,
          icon: const Icon(Icons.add_chart, size: 16),
          label: Text(w('Set up account history', '设置账户历史数据')),
        ),
    ]);
  }

  Widget portfolioAllocationPanel(Map<String, dynamic> g) => panel([
    visualSectionHeader(
      'Allocation',
      '持仓结构',
      Icons.donut_large_rounded,
      action: IconButton(
        tooltip: w('View holdings', '查看持仓'),
        onPressed: () => homeUpdate(() => tab = 'holdings'),
        icon: Icon(Icons.arrow_forward, size: 18, color: p.accent),
      ),
    ),
    const SizedBox(height: 12),
    PortfolioAllocationChart(
      hideAmounts: hideAmounts,
      compact: true,
      group: g,
      palette: p,
      onHolding: (ticker) =>
          widget.onCompany(portfolioValuationTicker(g, ticker), 'value'),
    ),
    const SizedBox(height: 12),
    Divider(color: p.border),
    valueRow(
      'Borrowing / NAV',
      '负现金 / 净资产',
      percent(asMap(g['leverage'])['borrowingToNav']),
    ),
  ]);

  Widget portfolioOverviewMetrics(Map<String, dynamic> g) {
    final h = asMap(g['home']), daily = asMap(h['daily']);
    final nav = portfolioDatedNav(asList(asMap(h['nav'])['rows']));
    final history = asList(asMap(asMap(h['history'])['cashAdjusted'])['rows']);
    final latest = history.length > 1 ? history.last : null;
    final ratio = nav.length > 1
        ? portfolioRatio(nav.last['nav'], nav.first['nav'])
        : null;
    final basis = portfolioNavBasis(
      nav,
      text(
        daily['status'] == 'ready' ? daily['date'] : latest?['previousDate'],
      ),
      strictlyBefore: daily['status'] == 'ready',
      exact: daily['status'] != 'ready',
    );
    final pnl = nullableNumber(
      daily['status'] == 'ready' ? daily['pnl'] : latest?['pnl'],
    );
    final coverage = asMap(g['coverage']);
    final cards = [
      homeMetric(
        hideAmounts ? 'Account value change' : 'Account value',
        hideAmounts ? '账户净值变化' : '账户净值',
        hideAmounts
            ? portfolioRateLabel(ratio == null ? null : ratio - 1)
            : amount(h['accountValue']),
        hideAmounts
            ? w('Includes transfers · not investment return', '含转入转出 · 非投资收益率')
            : w(
                'Broker report · ${h['reportDate'] ?? '—'}',
                '券商报告 · ${h['reportDate'] ?? '—'}',
              ),
        accent: true,
      ),
      homeMetric(
        daily['status'] == 'ready' ? 'Session P&L' : 'Latest P&L estimate',
        daily['status'] == 'ready' ? '当日盈亏' : '最近一期盈亏估算',
        hideAmounts
            ? portfolioRateLabel(portfolioRatio(pnl, basis))
            : amount(pnl),
        daily['status'] == 'ready'
            ? text(daily['date'])
            : latest != null
            ? '${latest['previousDate']} → ${latest['date']}'
            : w('Daily MTM report needed', '需要每日 MTM 盈亏报告'),
        color: pnl == null
            ? p.muted
            : pnl < 0
            ? p.negative
            : p.accent,
      ),
      homeMetric(
        'Model coverage',
        '模型覆盖',
        percent(coverage['weight']),
        w(
          '${coverage['count']} / ${coverage['total']} positive non-cash holdings',
          '正市值非现金持仓 ${coverage['count']} / ${coverage['total']} 项',
        ),
      ),
      homeMetric(
        'Top 5 concentration',
        '前五大持仓集中度',
        percent(g['top5Weight']),
        w('Of positive non-cash holdings', '占正市值非现金持仓'),
      ),
    ];
    return LayoutBuilder(
      builder: (_, c) {
        final cols =
            c.maxWidth >= 900 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.3
            ? 4
            : c.maxWidth >= 520
            ? 2
            : 1;
        if (cols == 4) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Expanded(child: cards[i]),
                ],
              ],
            ),
          );
        }
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final card in cards)
              SizedBox(
                width: (c.maxWidth - 14 * (cols - 1)) / cols,
                child: card,
              ),
          ],
        );
      },
    );
  }

  Widget portfolioVisualHero(Map<String, dynamic> g) => LayoutBuilder(
    builder: (_, c) {
      final chart = portfolioHistoryPanel(g),
          allocation = portfolioAllocationPanel(g);
      return c.maxWidth >= 960 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.3
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: chart),
                const SizedBox(width: 18),
                Expanded(flex: 2, child: allocation),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [chart, const SizedBox(height: 18), allocation],
            );
    },
  );

  Widget valuationVisual(Map<String, dynamic> g) {
    final rows =
        asList(g['positions'])
            .where(
              (r) =>
                  r['kind'] == 'equity' &&
                  nullableNumber(r['modelGap'])?.isFinite == true,
            )
            .toList()
          ..sort((a, b) => number(b['value']).compareTo(number(a['value'])));
    final extent = rows.fold<double>(
      .10,
      (max, r) => math.max(max, number(r['modelGap']).abs()),
    );
    return panel([
      visualSectionHeader(
        'Valuation by holding',
        '各持仓估值价差',
        Icons.tune_rounded,
        action: IconButton(
          tooltip: w('Holdings & value', '持仓与估值'),
          onPressed: () => homeUpdate(() => tab = 'holdings'),
          icon: Icon(Icons.arrow_forward, color: p.accent, size: 18),
        ),
      ),
      const SizedBox(height: 6),
      copy(
        'Published model / price − 1 · not an expected return',
        '平台模型 / 价格 − 1 · 非预期收益',
        size: 12,
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(child: copy('Below market price', '低于市场价格', size: 11)),
          copy('Above market price', '高于市场价格', size: 11),
        ],
      ),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        copy('No covered equities at this cutoff.', '截止日没有模型覆盖的股票。'),
      for (final r in rows.take(7))
        InkWell(
          onTap: () => widget.onCompany(
            portfolioValuationTicker(g, text(r['ticker'])),
            'value',
          ),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                StockLogo(ticker: text(r['ticker']), palette: p, size: 26),
                const SizedBox(width: 8),
                SizedBox(
                  width: 54,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text(r['ticker']), style: heading(12)),
                      if (portfolioValuationTicker(g, text(r['ticker'])) !=
                          r['ticker'])
                        Text(
                          w(
                            '${portfolioValuationTicker(g, text(r['ticker']))} model',
                            '${portfolioValuationTicker(g, text(r['ticker']))} 模型',
                          ),
                          style: TextStyle(color: p.muted, fontSize: 10),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: PortfolioDivergingBar(
                    value: nullableNumber(r['modelGap']),
                    extent: extent,
                    palette: p,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 62,
                  child: Text(
                    percent(r['modelGap']),
                    textAlign: TextAlign.end,
                    style: heading(13).copyWith(
                      color: number(r['modelGap']) < 0 ? p.negative : p.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 14),
      copy(
        'Missing models are excluded, not valued at zero. Select a stock to inspect its valuation, financials and Guru activity.',
        '缺失模型不纳入图中，不按零估值处理。点击股票查看估值、财务与大佬动向。',
        size: 11,
      ),
    ]);
  }

  Widget portfolioDesk(Map<String, dynamic> g) {
    final hasHistory = asMap(g['home']).isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasHistory) portfolioVisualHero(g) else portfolioAllocationPanel(g),
        const SizedBox(height: 18),
        portfolioHoldingsTable(g),
      ],
    );
  }

  String portfolioModelArchitecture(Map<String, dynamic> row) {
    final model = asMap(row['model']);
    return switch (text(model['modelRoute'])) {
      'operating_company' => w('Operating-company blend', '经营公司加权模型'),
      'multi_method_growth' => w('Growth-stage blend', '成长阶段加权模型'),
      'financial_institution' => w('Financial institution', '金融机构模型'),
      'customer_cash_earnings' => w('Customer cash earnings', '客户现金收益模型'),
      'revenue_stage' => w('Revenue-stage model', '收入阶段模型'),
      'bitcoin_treasury' => w('Treasury + operating value', '资产储备 + 经营价值'),
      _ =>
        row['modelStatus'] == 'covered'
            ? w('Published model', '已发布模型')
            : statusLabel(text(row['modelStatus'])),
    };
  }

  String portfolioPointDifference(dynamic value) {
    final n = nullableNumber(value);
    if (n == null) return '—';
    final points = n * 100;
    return '${points >= 0 ? '+' : ''}${points.toStringAsFixed(1)} pp';
  }

  List<Map<String, dynamic>> portfolioTableRows(Map<String, dynamic> g) {
    final source = asList(
      g['positions'],
    ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList();
    final covered = source.where(
      (r) =>
          r['modelStatus'] == 'covered' &&
          number(r['value']) > 0 &&
          number(r['modelValue']) > 0,
    );
    final coveredMark = covered.fold<double>(
      0,
      (total, row) => total + number(row['value']),
    );
    final coveredModel = covered.fold<double>(
      0,
      (total, row) => total + number(row['modelValue']),
    );
    final rows = source
        .where(
          (r) => '${r['ticker']} ${r['name']}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .map((r) {
          final currentShare = coveredMark > 0 && r['modelStatus'] == 'covered'
              ? number(r['value']) / coveredMark
              : null;
          final modelShare = coveredModel > 0 && r['modelStatus'] == 'covered'
              ? number(r['modelValue']) / coveredModel
              : null;
          return {
            ...r,
            '_currentCoveredWeight': currentShare,
            '_modelCoveredWeight': modelShare,
            '_structureGap': currentShare != null && modelShare != null
                ? modelShare - currentShare
                : null,
          };
        })
        .toList();
    dynamic key(Map<String, dynamic> row) => switch (portfolioSortColumn) {
      0 => text(row['ticker']),
      1 => nullableNumber(row['quantity']),
      2 => nullableNumber(row['value']),
      3 => nullableNumber(row['netWeight']),
      4 => portfolioModelArchitecture(row),
      5 => nullableNumber(row['modelGap']),
      6 => nullableNumber(row['_structureGap']),
      _ => nullableNumber(row['value']),
    };
    rows.sort((a, b) {
      final left = key(a), right = key(b);
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      final result = left is num && right is num
          ? left.compareTo(right)
          : left.toString().compareTo(right.toString());
      return portfolioSortAscending ? result : -result;
    });
    return rows;
  }

  Widget portfolioTableSearchAndSort(int count) => LayoutBuilder(
    builder: (_, c) {
      final field = TextField(
        controller: search,
        onChanged: (value) => homeUpdate(() {
          query = value;
          holdingLimit = 20;
        }),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded),
          hintText: w('Find a holding', '查找持仓'),
          suffixText: '$count',
        ),
      );
      final sort = DropdownButtonFormField<int>(
        initialValue: portfolioSortColumn,
        isExpanded: true,
        decoration: InputDecoration(labelText: w('Sort by', '排序')),
        items: [
          DropdownMenuItem(value: 2, child: Text(w('Current value', '当前市值'))),
          DropdownMenuItem(
            value: 3,
            child: Text(w('Portfolio weight', '组合权重')),
          ),
          DropdownMenuItem(value: 5, child: Text(w('Model gap', '模型价差'))),
          DropdownMenuItem(value: 6, child: Text(w('Structure shift', '结构变化'))),
        ],
        onChanged: (value) {
          if (value == null) return;
          homeUpdate(() {
            portfolioSortColumn = value;
            portfolioSortAscending = false;
          });
        },
      );
      if (c.maxWidth >= 700) {
        return Row(
          children: [
            Expanded(child: field),
            const SizedBox(width: 12),
            SizedBox(width: 210, child: sort),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [field, const SizedBox(height: 10), sort],
      );
    },
  );

  Widget portfolioHoldingsTable(Map<String, dynamic> g) {
    final rows = portfolioTableRows(g);
    final coverage = asMap(g['coverage']), valuation = asMap(g['valuation']);
    return panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.start,
        spacing: 16,
        runSpacing: 10,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title('Holdings & model structure', '持仓与模型结构'),
              const SizedBox(height: 6),
              copy(
                'Current weights, the model used for each company, and how the covered sleeve changes when positions are revalued to model output.',
                '同时查看当前权重、每家公司使用的估值架构，以及按模型输出重估后已覆盖组合的结构变化。',
                size: 12,
              ),
            ],
          ),
          tag(
            '${coverage['count']} / ${coverage['total']} modelled · ${percent(coverage['weight'])} coverage',
            '${coverage['count']} / ${coverage['total']} 项已建模 · 覆盖 ${percent(coverage['weight'])}',
          ),
        ],
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: .055),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: p.accent.withValues(alpha: .16)),
        ),
        child: Wrap(
          spacing: 24,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            copy(
              '${w('Net holdings', '净持仓')}  ${amount(g['netValue'])}',
              '净持仓  ${amount(g['netValue'])}',
              color: p.text,
              size: 12,
            ),
            copy(
              '${w('Covered market value', '已覆盖市值')}  ${amount(valuation['coveredMark'])}',
              '已覆盖市值  ${amount(valuation['coveredMark'])}',
              color: p.text,
              size: 12,
            ),
            copy(
              '${w('Model-revalued', '模型重估')}  ${amount(valuation['coveredModel'])}',
              '模型重估  ${amount(valuation['coveredModel'])}',
              color: p.text,
              size: 12,
            ),
            copy(
              '${w('Covered gap', '覆盖部分价差')}  ${percent(valuation['gap'])}',
              '覆盖部分价差  ${percent(valuation['gap'])}',
              color: nullableNumber(valuation['gap']) == null
                  ? p.muted
                  : number(valuation['gap']) >= 0
                  ? p.accent
                  : p.negative,
              size: 12,
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      portfolioTableSearchAndSort(rows.length),
      const SizedBox(height: 12),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: copy('No matching positions.', '没有匹配的持仓。'),
        )
      else
        LayoutBuilder(
          builder: (_, c) =>
              c.maxWidth >= 1040 &&
                  MediaQuery.textScalerOf(context).scale(1) <= 1.25
              ? portfolioDesktopTable(g, rows.take(holdingLimit).toList())
              : Column(
                  children: [
                    for (final row in rows.take(holdingLimit))
                      portfolioMobileTableRow(g, row),
                  ],
                ),
        ),
      if (rows.length > holdingLimit)
        Align(
          alignment: Alignment.center,
          child: TextButton(
            onPressed: () => homeUpdate(() => holdingLimit += 20),
            child: Text(
              w(
                'Show 20 more · ${rows.length} positions',
                '再显示 20 项 · 共 ${rows.length} 项持仓',
              ),
            ),
          ),
        ),
      const SizedBox(height: 8),
      copy(
        'Current → model structure compares weights inside the covered sleeve after applying published fair values. It is not a target allocation, score or expected return. Missing models remain missing, not zero.',
        '“当前 → 模型结构”仅比较已覆盖部分按平台公允价值重估后的权重变化，不是目标仓位、评分或预期收益；缺失模型不会按零处理。',
        size: 11,
      ),
    ]);
  }

  Widget portfolioDesktopTable(
    Map<String, dynamic> g,
    List<Map<String, dynamic>> rows,
  ) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      sortColumnIndex: portfolioSortColumn,
      sortAscending: portfolioSortAscending,
      showCheckboxColumn: false,
      headingRowHeight: 46,
      dataRowMinHeight: 68,
      dataRowMaxHeight: 78,
      horizontalMargin: 12,
      columnSpacing: 28,
      columns: [
        DataColumn(label: Text(w('Holding', '持仓')), onSort: portfolioSort),
        DataColumn(
          label: Text(w('Position', '仓位')),
          numeric: true,
          onSort: portfolioSort,
        ),
        DataColumn(
          label: Text(w('Current value', '当前市值')),
          numeric: true,
          onSort: portfolioSort,
        ),
        DataColumn(
          label: Text(w('Weight', '权重')),
          numeric: true,
          onSort: portfolioSort,
        ),
        DataColumn(
          label: Text(w('Model architecture', '模型架构')),
          onSort: portfolioSort,
        ),
        DataColumn(
          label: Text(w('Model output', '模型输出')),
          numeric: true,
          onSort: portfolioSort,
        ),
        DataColumn(
          label: Text(w('Current → model', '当前 → 模型')),
          numeric: true,
          onSort: portfolioSort,
        ),
        DataColumn(label: Text(w('Research', '研究'))),
      ],
      rows: [for (final row in rows) portfolioDataRow(g, row)],
    ),
  );

  void portfolioSort(int column, bool ascending) => homeUpdate(() {
    portfolioSortColumn = column;
    portfolioSortAscending = ascending;
  });

  DataRow portfolioDataRow(Map<String, dynamic> g, Map<String, dynamic> row) {
    final model = asMap(row['model']);
    final covered = row['modelStatus'] == 'covered';
    final structureGap = nullableNumber(row['_structureGap']);
    final architecture = portfolioModelArchitecture(row);
    return DataRow(
      key: ValueKey('portfolio-table-${row['id'] ?? row['ticker']}'),
      onSelectChanged: row['kind'] == 'equity'
          ? (_) => widget.onCompany(text(row['ticker']), 'overview')
          : null,
      cells: [
        DataCell(
          SizedBox(
            width: 210,
            child: Row(
              children: [
                StockLogo(ticker: text(row['ticker']), palette: p, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text(row['ticker']), style: heading(14)),
                      Text(
                        text(row['name']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(
          _portfolioStackedValue(
            hideAmounts
                ? '••••'
                : nullableNumber(row['quantity']) == null
                ? '—'
                : formatNumber(number(row['quantity'])),
            text(row['reportDate'], '—'),
            alignEnd: true,
          ),
        ),
        DataCell(
          _portfolioStackedValue(
            amount(row['value']),
            amount(row['price'], text(row['currency'])),
            alignEnd: true,
          ),
        ),
        DataCell(Text(percent(row['netWeight']), style: heading(13))),
        DataCell(
          Tooltip(
            message: text(model['formula'], architecture),
            child: SizedBox(
              width: 180,
              child: _portfolioStackedValue(
                architecture,
                covered
                    ? w(
                        'Published ${model['date'] ?? '—'}',
                        '发布于 ${model['date'] ?? '—'}',
                      )
                    : statusLabel(text(row['modelStatus'])),
              ),
            ),
          ),
        ),
        DataCell(
          _portfolioStackedValue(
            covered ? amount(model['fairValue'], text(model['currency'])) : '—',
            covered
                ? percent(row['modelGap'])
                : statusLabel(text(row['modelStatus'])),
            color: !covered || nullableNumber(row['modelGap']) == null
                ? null
                : number(row['modelGap']) >= 0
                ? p.accent
                : p.negative,
            alignEnd: true,
          ),
        ),
        DataCell(
          _portfolioStackedValue(
            covered
                ? '${percent(row['_currentCoveredWeight'])} → ${percent(row['_modelCoveredWeight'])}'
                : '—',
            portfolioPointDifference(structureGap),
            color: structureGap == null
                ? null
                : structureGap >= 0
                ? p.accent
                : p.negative,
            alignEnd: true,
          ),
        ),
        DataCell(
          TextButton(
            onPressed: row['kind'] == 'equity'
                ? () => widget.onCompany(
                    covered
                        ? portfolioValuationTicker(g, text(row['ticker']))
                        : text(row['ticker']),
                    covered ? 'value' : 'overview',
                  )
                : null,
            child: Text(
              covered ? w('Valuation →', '估值 →') : w('Research →', '研究 →'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _portfolioStackedValue(
    String primary,
    String secondary, {
    Color? color,
    bool alignEnd = false,
  }) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        primary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color ?? p.text,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        secondary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color ?? p.muted, fontSize: 11),
      ),
    ],
  );

  Widget portfolioMobileTableRow(
    Map<String, dynamic> g,
    Map<String, dynamic> row,
  ) {
    final covered = row['modelStatus'] == 'covered';
    final model = asMap(row['model']);
    final structureGap = nullableNumber(row['_structureGap']);
    return InkWell(
      key: ValueKey('portfolio-mobile-${row['id'] ?? row['ticker']}'),
      onTap: row['kind'] == 'equity'
          ? () => widget.onCompany(text(row['ticker']), 'overview')
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                StockLogo(ticker: text(row['ticker']), palette: p, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text(row['ticker']), style: heading(15)),
                      Text(
                        text(row['name']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _portfolioStackedValue(
                  amount(row['value']),
                  percent(row['netWeight']),
                  alignEnd: true,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                smallMetric(
                  'Model architecture',
                  '模型架构',
                  portfolioModelArchitecture(row),
                ),
                smallMetric(
                  'Model output',
                  '模型输出',
                  covered
                      ? '${amount(model['fairValue'], text(model['currency']))} · ${percent(row['modelGap'])}'
                      : '—',
                ),
                smallMetric(
                  'Current → model',
                  '当前 → 模型',
                  covered
                      ? '${percent(row['_currentCoveredWeight'])} → ${percent(row['_modelCoveredWeight'])} (${portfolioPointDifference(structureGap)})'
                      : '—',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
