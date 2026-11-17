part of 'main.dart';

const Color _kDividendBlue = Color(0xFF72A9F8);

class PortfolioPassiveIncomeCard extends StatefulWidget {
  const PortfolioPassiveIncomeCard({
    super.key,
    required this.passiveIncome,
    required this.currency,
    required this.palette,
    required this.hideAmounts,
    this.onCompany,
  });

  final Map<String, dynamic> passiveIncome;
  final String currency;
  final Palette palette;
  final bool hideAmounts;
  final void Function(String ticker, String section)? onCompany;

  @override
  State<PortfolioPassiveIncomeCard> createState() =>
      _PortfolioPassiveIncomeCardState();
}

class _PortfolioPassiveIncomeCardState
    extends State<PortfolioPassiveIncomeCard> {
  String range = 'All';
  int? hoveredIndex;
  bool showLedger = false;

  String w(String en, String zh) => context.tr(zh, en);

  String fmtMoney(dynamic v) {
    if (widget.hideAmounts) return '••••';
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final sign = n < 0 ? '-' : '';
    return '$sign${widget.currency} ${formatNumber(n.abs())}';
  }

  String fmtShare(double part, double whole) {
    if (!part.isFinite || !whole.isFinite || whole <= 0) return '—';
    return '${(part / whole * 100).toStringAsFixed(1)}%';
  }

  List<Map<String, dynamic>> _filteredMonths(List<Map<String, dynamic>> all) {
    if (all.isEmpty || range == 'All') return all;
    final lastMonth = text(all.last['month']);
    if (lastMonth.length < 7) return all;
    final parts = lastMonth.split('-');
    final endYear = int.tryParse(parts[0]) ?? 2026;
    final endMonth = int.tryParse(parts[1]) ?? 12;
    if (range == 'YTD') {
      final prefix = '${endYear.toString().padLeft(4, '0')}-';
      return all.where((m) => text(m['month']).startsWith(prefix)).toList();
    }
    final keep = range == '3M' ? 3 : 6;
    final totalMonths = endYear * 12 + (endMonth - 1);
    final minMonths = totalMonths - (keep - 1);
    final minYear = (minMonths / 12).floor();
    final minM = (minMonths % 12) + 1;
    final cutoff =
        '${minYear.toString().padLeft(4, '0')}-${minM.toString().padLeft(2, '0')}';
    return all.where((m) => text(m['month']).compareTo(cutoff) >= 0).toList();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final data = widget.passiveIncome;
    final ready = data['status'] == 'ready';
    final pending = asMap(data['pendingShortCalls']);
    final pendingRows = asList(pending['rows']);
    if (!ready && pendingRows.isEmpty) return const SizedBox.shrink();

    final allMonths = asList(data['monthly']);
    final months = _filteredMonths(allMonths);
    final divInfo = asMap(data['dividends']);
    final callInfo = asMap(data['expiredCalls']);

    final windowDivs = range == 'All'
        ? number(divInfo['grossAmount'])
        : months.fold<double>(0, (s, m) => s + number(m['dividends']));
    final windowCalls = range == 'All'
        ? number(callInfo['amount'])
        : months.fold<double>(0, (s, m) => s + number(m['expiredCalls']));
    final windowTotal = windowDivs + windowCalls;
    final windowDivCount = range == 'All'
        ? number(divInfo['eventCount']).round()
        : months.fold<int>(0, (s, m) => s + number(m['dividendCount']).round());
    final windowCallCount = range == 'All'
        ? number(callInfo['contractCount']).round()
        : months.fold<int>(0, (s, m) => s + number(m['callCount']).round());

    final activeIdx = months.isEmpty
        ? null
        : (hoveredIndex ?? (months.length - 1)).clamp(0, months.length - 1);
    final activeMonth = activeIdx != null ? months[activeIdx] : null;

    final byTicker = asList(data['byTicker']);
    final recentEvents = asList(data['recentEvents']);
    final taxAmount = nullableNumber(divInfo['withholdingTax']);
    final netDividends = nullableNumber(divInfo['netAmount']);

    final periodLabel = months.isNotEmpty
        ? (range == 'All'
              ? '${text(data['fromDate'], '—')} → ${text(data['toDate'], '—')}'
              : '${months.first['month']} → ${months.last['month']}')
        : '—';

    return Container(
      key: const ValueKey('portfolio-passive-income-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: p.accent.withValues(alpha: .11),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.payments_outlined,
                        size: 18,
                        color: p.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            w('Confirmed passive income', '已收被动收入（已确认）'),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            w(
                              'Received cash dividends + OTM short calls confirmed at expiration · $periodLabel',
                              '实际到账股息 + 已到期作废确认的卖 Call 权利金 · $periodLabel',
                            ),
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (ready && allMonths.length > 1)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final r in [
                        ('3M', '3M', '近3月'),
                        ('6M', '6M', '近6月'),
                        ('YTD', 'YTD', '今年'),
                        ('All', 'All', '全部'),
                      ])
                        ChoiceChip(
                          key: ValueKey('passive-range-${r.$1}'),
                          label: Text(
                            w(r.$2, r.$3),
                            style: const TextStyle(fontSize: 12),
                          ),
                          visualDensity: VisualDensity.compact,
                          selected: range == r.$1,
                          onSelected: (_) => setState(() {
                            range = r.$1;
                            hoveredIndex = null;
                          }),
                        ),
                    ],
                  ),
              ],
            ),
            if (ready) ...[
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (_, c) {
                  final cols =
                      c.maxWidth >= 780 &&
                          MediaQuery.textScalerOf(context).scale(1) <= 1.25
                      ? 3
                      : 1;
                  final tileWidth = cols == 3
                      ? (c.maxWidth - 24) / 3
                      : c.maxWidth;
                  final tiles = [
                    _summaryTile(
                      p: p,
                      dotColor: p.text,
                      title: w('Total confirmed', '已确认被动收入合计'),
                      value: widget.hideAmounts
                          ? (windowTotal > 0 ? '100.0%' : '—')
                          : fmtMoney(windowTotal),
                      subtitle: widget.hideAmounts
                          ? w(
                              'Calls ${fmtShare(windowCalls, windowTotal)} · Dividends ${fmtShare(windowDivs, windowTotal)}',
                              '卖 Call ${fmtShare(windowCalls, windowTotal)} · 股息 ${fmtShare(windowDivs, windowTotal)}',
                            )
                          : w(
                              'Excludes un-expired & early-closed options',
                              '不含未到期期权与提前平仓差价',
                            ),
                      highlight: true,
                    ),
                    _summaryTile(
                      p: p,
                      dotColor: p.accent,
                      title: w('Expired short calls', '卖 Call 到期确认收入'),
                      value: widget.hideAmounts
                          ? fmtShare(windowCalls, windowTotal)
                          : fmtMoney(windowCalls),
                      subtitle: widget.hideAmounts
                          ? w(
                              'Share of confirmed passive income',
                              '占已确认被动收入比例',
                            )
                          : w(
                              '$windowCallCount expired contracts · net of commission',
                              '$windowCallCount 张期权到期作废确认 · 已扣佣金',
                            ),
                    ),
                    _summaryTile(
                      p: p,
                      dotColor: _kDividendBlue,
                      title: w('Cash dividends', '已到账现金股息'),
                      value: widget.hideAmounts
                          ? fmtShare(windowDivs, windowTotal)
                          : fmtMoney(windowDivs),
                      subtitle: widget.hideAmounts
                          ? w(
                              'Share of confirmed passive income',
                              '占已确认被动收入比例',
                            )
                          : (range == 'All' &&
                                    taxAmount != null &&
                                    taxAmount < 0 &&
                                    netDividends != null
                                ? w(
                                    'Net ${fmtMoney(netDividends)} after ${fmtMoney(taxAmount)} withholding tax',
                                    '税后净额 ${fmtMoney(netDividends)}（预扣税 ${fmtMoney(taxAmount)}）',
                                  )
                                : w(
                                    '$windowDivCount broker cash payouts received',
                                    '$windowDivCount 笔券商现金分红入账',
                                  )),
                    ),
                  ];
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final tile in tiles)
                        SizedBox(width: tileWidth, child: tile),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (_, c) {
                  final monthlyChart = _buildMonthlyChart(
                    p,
                    months,
                    activeIdx,
                    activeMonth,
                  );
                  final sourceBreakdown = _buildSourceBreakdown(
                    p,
                    byTicker,
                    number(data['totalConfirmed']),
                  );
                  if (c.maxWidth >= 880 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.25) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: monthlyChart),
                        const SizedBox(width: 22),
                        Container(width: 1, height: 252, color: p.border),
                        const SizedBox(width: 22),
                        Expanded(flex: 5, child: sourceBreakdown),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      monthlyChart,
                      const SizedBox(height: 16),
                      Divider(height: 1, color: p.border),
                      const SizedBox(height: 16),
                      sourceBreakdown,
                    ],
                  );
                },
              ),
            ],
            if (pendingRows.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                key: const ValueKey('passive-pending-short-calls'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: p.card.withValues(alpha: .48),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.schedule_rounded,
                              size: 15,
                              color: p.secondary,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                w(
                                  'Pending short calls · confirmed only after expiration',
                                  '待到期卖 Call · 未到期暂不计入确认收入',
                                ),
                                style: TextStyle(
                                  color: p.secondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (!widget.hideAmounts &&
                            nullableNumber(pending['collectedPremium']) != null)
                          Text(
                            w(
                              'Collected premium: ${fmtMoney(pending['collectedPremium'])}',
                              '待确认权利金：${fmtMoney(pending['collectedPremium'])}',
                            ),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final r in pendingRows)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: p.panel,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: p.border),
                            ),
                            child: Text(
                              widget.hideAmounts
                                  ? '${text(r['ticker'])} · ${text(r['expiry'], '—')}'
                                  : '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? formatNumber(number(r['strike'])) : ''}C · ${text(r['expiry'], '—')} ×${number(r['contracts']).round()}',
                              style: TextStyle(color: p.muted, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (ready && recentEvents.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('passive-income-ledger-toggle'),
                  onPressed: () => setState(() => showLedger = !showLedger),
                  icon: Icon(
                    showLedger
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                  ),
                  label: Text(
                    showLedger
                        ? w('Hide confirmed records', '收起已确认流水')
                        : w(
                            'View confirmed records (${recentEvents.length})',
                            '查看最近已确认流水（${recentEvents.length} 笔）',
                          ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (showLedger) _buildRecentLedger(p, recentEvents),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryTile({
    required Palette p,
    required Color dotColor,
    required String title,
    required String value,
    required String subtitle,
    bool highlight = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: highlight ? .68 : .42),
      borderRadius: BorderRadius.circular(11),
      border: Border.all(
        color: highlight ? p.accent.withValues(alpha: .32) : p.border,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          value,
          style: TextStyle(
            color: p.text,
            fontSize: 23,
            fontWeight: FontWeight.w700,
            letterSpacing: -.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11, height: 1.35),
        ),
      ],
    ),
  );

  Widget _buildMonthlyChart(
    Palette p,
    List<Map<String, dynamic>> months,
    int? activeIdx,
    Map<String, dynamic>? activeMonth,
  ) {
    if (months.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          w('No monthly observations in this range.', '所选区间暂无月度确认收入。'),
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
      );
    }
    final maxTotal = months.fold<double>(
      0,
      (m, r) => math.max(m, number(r['total'])),
    );
    final activeTotal = number(activeMonth?['total']);
    final activeCalls = number(activeMonth?['expiredCalls']);
    final activeDivs = number(activeMonth?['dividends']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            Text(
              w('Monthly confirmed cashflow', '月度已确认被动收入'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                _legendDot(p, p.accent, w('Expired calls', '到期卖 Call')),
                _legendDot(p, _kDividendBlue, w('Dividends', '到账股息')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (activeMonth != null)
          Text(
            widget.hideAmounts
                ? '${text(activeMonth['month'])} · ${activeTotal > 0 ? '${w('Calls', '卖 Call')} ${fmtShare(activeCalls, activeTotal)} · ${w('Dividends', '股息')} ${fmtShare(activeDivs, activeTotal)}' : w('No confirmed income', '无确认收入')}'
                : '${text(activeMonth['month'])} · ${fmtMoney(activeTotal)}  (${w('Calls', '卖 Call')} ${fmtMoney(activeCalls)} · ${w('Dividends', '股息')} ${fmtMoney(activeDivs)})',
            style: TextStyle(
              color: activeTotal > 0 ? p.accent : p.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          key: const ValueKey('passive-income-monthly-chart'),
          height: 186,
          child: LayoutBuilder(
            builder: (_, c) {
              void selectAt(double dx) {
                if (months.isEmpty) return;
                final leftPad = 48.0;
                final plotW = math.max(1.0, c.maxWidth - leftPad - 8);
                final frac = ((dx - leftPad) / plotW).clamp(0.0, 0.9999);
                final idx = (frac * months.length).floor().clamp(
                  0,
                  months.length - 1,
                );
                if (hoveredIndex != idx) setState(() => hoveredIndex = idx);
              }

              return MouseRegion(
                onHover: (e) => selectAt(e.localPosition.dx),
                onExit: (_) => setState(() => hoveredIndex = null),
                child: GestureDetector(
                  onTapDown: (e) => selectAt(e.localPosition.dx),
                  child: CustomPaint(
                    painter: _PassiveIncomeBarPainter(
                      months: months,
                      maxTotal: maxTotal,
                      palette: p,
                      activeIndex: activeIdx,
                      hideAmounts: widget.hideAmounts,
                    ),
                    size: Size.infinite,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Palette p, Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
    ],
  );

  Widget _buildSourceBreakdown(
    Palette p,
    List<Map<String, dynamic>> rows,
    double grandTotal,
  ) {
    final top = rows.where((r) => number(r['total']) > 0).take(6).toList();
    final maxRow = top.fold<double>(
      0,
      (m, r) => math.max(m, number(r['total'])),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              w('By underlying source', '按标的来源贡献'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (range != 'All')
              Text(
                w('Full period', '全周期累计'),
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (top.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              w('No confirmed passive income yet.', '暂无已确认被动收入记录。'),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ),
        for (final r in top)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onCompany != null && text(r['ticker']) != 'CASH'
                  ? () => widget.onCompany!(text(r['ticker']), 'evidence')
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      StockLogo(
                        ticker: text(r['ticker']),
                        palette: p,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                text(r['ticker']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              number(r['expiredCalls']) > 0 &&
                                      number(r['dividends']) > 0
                                  ? w('Call + Div', '卖 Call + 股息')
                                  : number(r['expiredCalls']) > 0
                                  ? w('Expired Call', '到期卖 Call')
                                  : w('Dividend', '现金股息'),
                              style: TextStyle(color: p.muted, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        widget.hideAmounts
                            ? fmtShare(number(r['total']), grandTotal)
                            : fmtMoney(r['total']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  LayoutBuilder(
                    builder: (_, barConstraints) {
                      final fullW = barConstraints.maxWidth;
                      final callW = maxRow > 0
                          ? (number(r['expiredCalls']) / maxRow * fullW)
                                .clamp(0.0, fullW)
                                .toDouble()
                          : 0.0;
                      final divW = maxRow > 0
                          ? (number(r['dividends']) / maxRow * fullW)
                                .clamp(0.0, math.max(0.0, fullW - callW))
                                .toDouble()
                          : 0.0;
                      return Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: p.border.withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          children: [
                            if (callW > 0)
                              Container(
                                width: callW,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: p.accent,
                                  borderRadius: BorderRadius.horizontal(
                                    left: const Radius.circular(3),
                                    right: divW > 0
                                        ? Radius.zero
                                        : const Radius.circular(3),
                                  ),
                                ),
                              ),
                            if (divW > 0)
                              Container(
                                width: divW,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: _kDividendBlue,
                                  borderRadius: BorderRadius.horizontal(
                                    left: callW > 0
                                        ? Radius.zero
                                        : const Radius.circular(3),
                                    right: const Radius.circular(3),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecentLedger(Palette p, List<Map<String, dynamic>> events) =>
      Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .36),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Column(
          children: [
            for (var i = 0; i < events.take(15).length; i++) ...[
              if (i > 0) Divider(height: 1, color: p.border),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: events[i]['kind'] == 'expired_call'
                            ? p.accent
                            : _kDividendBlue,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 9),
                    SizedBox(
                      width: 78,
                      child: Text(
                        text(events[i]['date']),
                        style: TextStyle(color: p.muted, fontSize: 11.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        events[i]['kind'] == 'expired_call'
                            ? '${text(events[i]['ticker'])} · ${w('Expired Short Call', '卖 Call 到期作废')}${!widget.hideAmounts && nullableNumber(events[i]['strike']) != null ? ' (${formatNumber(number(events[i]['strike']))}C)' : ''}'
                            : '${text(events[i]['ticker'])} · ${w('Cash Dividend', '现金股息')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.text, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.hideAmounts
                          ? '••••'
                          : '+${fmtMoney(events[i]['amount'])}',
                      style: TextStyle(
                        color: events[i]['kind'] == 'expired_call'
                            ? p.accent
                            : _kDividendBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
}

class _PassiveIncomeBarPainter extends CustomPainter {
  _PassiveIncomeBarPainter({
    required this.months,
    required this.maxTotal,
    required this.palette,
    required this.activeIndex,
    required this.hideAmounts,
  });

  final List<Map<String, dynamic>> months;
  final double maxTotal;
  final Palette palette;
  final int? activeIndex;
  final bool hideAmounts;

  @override
  void paint(Canvas canvas, Size size) {
    final leftPad = 48.0;
    final bottomPad = 24.0;
    final topPad = 8.0;
    final rect = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - 8,
      size.height - bottomPad,
    );
    if (rect.width <= 0 || rect.height <= 0 || months.isEmpty) return;

    final scaleMax = maxTotal > 0 ? maxTotal * 1.12 : 100.0;
    for (var g = 0; g <= 3; g++) {
      final frac = g / 3;
      final y = rect.bottom - frac * rect.height;
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()
          ..color = palette.border.withValues(alpha: .55)
          ..strokeWidth = 1,
      );
      final val = scaleMax * frac;
      final labelText = hideAmounts
          ? (maxTotal > 0 ? '${(frac * 100).round()}%' : '—')
          : val >= 1000
          ? '${(val / 1000).toStringAsFixed(1)}K'
          : val.toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(color: palette.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 6);
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    final slotW = rect.width / months.length;
    final barW = (slotW * 0.62).clamp(6.0, 28.0);
    final labelStep = months.length > 9 ? 2 : 1;

    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final calls = number(m['expiredCalls']);
      final divs = number(m['dividends']);
      final cx = rect.left + (i + 0.5) * slotW;

      if (activeIndex == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - slotW * 0.46,
              rect.top,
              cx + slotW * 0.46,
              rect.bottom,
            ),
            const Radius.circular(6),
          ),
          Paint()..color = palette.accent.withValues(alpha: .07),
        );
      }

      final divH = maxTotal > 0 ? (divs / scaleMax) * rect.height : 0.0;
      final callH = maxTotal > 0 ? (calls / scaleMax) * rect.height : 0.0;

      if (divH > 0) {
        final divRect = Rect.fromLTWH(
          cx - barW / 2,
          rect.bottom - divH,
          barW,
          divH,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            divRect,
            topLeft: callH > 0 ? Radius.zero : const Radius.circular(3),
            topRight: callH > 0 ? Radius.zero : const Radius.circular(3),
          ),
          Paint()
            ..color = _kDividendBlue.withValues(
              alpha: activeIndex == null || activeIndex == i ? 0.95 : 0.5,
            ),
        );
      }
      if (callH > 0) {
        final callRect = Rect.fromLTWH(
          cx - barW / 2,
          rect.bottom - divH - callH,
          barW,
          callH,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            callRect,
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()
            ..color = palette.accent.withValues(
              alpha: activeIndex == null || activeIndex == i ? 0.95 : 0.5,
            ),
        );
      }

      if (i % labelStep == 0 || i == months.length - 1) {
        final rawM = text(m['month']);
        final shortM = rawM.length >= 7 ? rawM.substring(2) : rawM;
        final mtp = TextPainter(
          text: TextSpan(
            text: shortM,
            style: TextStyle(
              color: activeIndex == i ? palette.text : palette.muted,
              fontSize: 9.5,
              fontWeight: activeIndex == i
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        mtp.paint(canvas, Offset(cx - mtp.width / 2, rect.bottom + 6));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PassiveIncomeBarPainter old) =>
      old.months != months ||
      old.maxTotal != maxTotal ||
      old.activeIndex != activeIndex ||
      old.hideAmounts != hideAmounts ||
      old.palette != palette;
}
