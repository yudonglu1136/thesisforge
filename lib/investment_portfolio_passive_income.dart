part of 'main.dart';

// Calm, low-glare institutional dark-mode palette:
// Soft steel-sky blue for option premium vs muted sage-teal for cash dividends.
Color passiveCallColor(Palette p) =>
    p.colorBlind ? const Color(0xFF6BA3E8) : const Color(0xFF6B9FD4);

Color passiveDividendColor(Palette p) =>
    p.colorBlind ? const Color(0xFF9F8FEF) : const Color(0xFF4CA98E);

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
  String? selectedScope;
  int? hoveredIndex;
  bool showLedger = false;

  String w(String en, String zh) => context.tr(zh, en);

  String fmtMoney(dynamic v, {bool signed = false}) {
    if (widget.hideAmounts) return '••••';
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = n < 0 ? '-' : (signed && n > 0 ? '+' : '');
    return '$prefix${widget.currency} ${formatNumber(n.abs())}';
  }

  String fmtPct(dynamic v, {bool signed = true}) {
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = signed && n > 0 ? '+' : '';
    return '$prefix${(n * 100).toStringAsFixed(1)}%';
  }

  String fmtShare(double part, double whole) {
    if (!part.isFinite || !whole.isFinite || whole <= 0) return '—';
    return '${(part / whole * 100).toStringAsFixed(1)}%';
  }

  List<String> _resolveYears(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
  ) {
    final raw = data['availableYears'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => text(e)).where((s) => s.length == 4).toList();
    }
    final yrs = <String>{};
    for (final m in allMonths) {
      final ym = text(m['month']);
      if (ym.length >= 4) yrs.add(ym.substring(0, 4));
    }
    final sorted = yrs.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  Map<String, dynamic> _resolveYearData(
    String year,
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
  ) {
    final annual = asMap(data['annual']);
    final stored = asMap(annual[year]);
    if (stored.isNotEmpty) return stored;

    // Fallback synthesis for minimal fixtures that omit precomputed `annual`
    final yrMonths = allMonths
        .where((m) => text(m['month']).startsWith('$year-'))
        .toList();
    final monthByYm = {for (final m in allMonths) text(m['month']): m};
    final priorYear = ((int.tryParse(year) ?? 2026) - 1).toString().padLeft(
      4,
      '0',
    );
    final monthly12 = <Map<String, dynamic>>[];
    var divSum = 0.0, callSum = 0.0;
    var divCount = 0, callCount = 0;
    for (var m = 1; m <= 12; m++) {
      final mm = m.toString().padLeft(2, '0');
      final ym = '$year-$mm';
      final priorYm = '$priorYear-$mm';
      final cur = monthByYm[ym];
      final prev = monthByYm[priorYm];
      final d = number(cur?['dividends']);
      final c = number(cur?['expiredCalls']);
      divSum += d;
      callSum += c;
      divCount += number(cur?['dividendCount']).round();
      callCount += number(cur?['callCount']).round();
      monthly12.add({
        'month': ym,
        'covered': cur != null,
        'dividends': d,
        'expiredCalls': c,
        'total': d + c,
        'dividendCount': number(cur?['dividendCount']).round(),
        'callCount': number(cur?['callCount']).round(),
        'priorYearMonth': priorYm,
        'priorYearCovered': prev != null,
        'priorYearDividends': number(prev?['dividends']),
        'priorYearCalls': number(prev?['expiredCalls']),
        'priorYearTotal': number(prev?['total']),
      });
    }
    final overlapMonths = monthly12
        .where((m) => m['covered'] == true && m['priorYearCovered'] == true)
        .toList();
    Map<String, dynamic> yoy;
    if (overlapMonths.isNotEmpty) {
      final currComp = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['total']),
      );
      final priorComp = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearTotal']),
      );
      final currCalls = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['expiredCalls']),
      );
      final priorCalls = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearCalls']),
      );
      final currDivs = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['dividends']),
      );
      final priorDivs = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearDividends']),
      );
      yoy = {
        'status': overlapMonths.length == yrMonths.length
            ? 'full_same_period'
            : 'overlapping_subperiod',
        'priorYear': priorYear,
        'currentFrom': '${overlapMonths.first['month']}-01',
        'currentTo': '${overlapMonths.last['month']}-28',
        'priorFrom': '${overlapMonths.first['priorYearMonth']}-01',
        'priorTo': '${overlapMonths.last['priorYearMonth']}-28',
        'currentTotal': currComp,
        'priorTotal': priorComp,
        'deltaTotal': currComp - priorComp,
        'pctTotal': priorComp > 0 ? (currComp - priorComp) / priorComp : null,
        'currentCalls': currCalls,
        'priorCalls': priorCalls,
        'deltaCalls': currCalls - priorCalls,
        'pctCalls': priorCalls > 0 ? (currCalls - priorCalls) / priorCalls : null,
        'currentDividends': currDivs,
        'priorDividends': priorDivs,
        'deltaDividends': currDivs - priorDivs,
        'pctDividends': priorDivs > 0 ? (currDivs - priorDivs) / priorDivs : null,
      };
    } else {
      yoy = {'status': 'prior_year_unavailable', 'priorYear': priorYear};
    }

    final events = asList(
      data['recentEvents'],
    ).where((e) => text(e['date']).startsWith('$year-')).toList();

    return {
      'year': year,
      'fromDate': yrMonths.isNotEmpty
          ? '${yrMonths.first['month']}-01'
          : '$year-01-01',
      'toDate': yrMonths.isNotEmpty
          ? text(data['toDate'], '${yrMonths.last['month']}-28')
          : '$year-12-31',
      'isFullYear': yrMonths.length == 12,
      'isYtd': yrMonths.length < 12,
      'totalConfirmed': divSum + callSum,
      'dividends': {
        'grossAmount': divSum,
        'withholdingTax': yrsSingle(data, year)
            ? asMap(data['dividends'])['withholdingTax']
            : null,
        'netAmount': yrsSingle(data, year)
            ? asMap(data['dividends'])['netAmount']
            : null,
        'eventCount': divCount,
      },
      'expiredCalls': {
        'amount': callSum,
        'settlementCount': callCount,
        'contractCount': callCount,
      },
      'monthly': monthly12,
      'byTicker': yrsSingle(data, year) ? asList(data['byTicker']) : const [],
      'recentEvents': events,
      'yoy': yoy,
    };
  }

  bool yrsSingle(Map<String, dynamic> data, String year) {
    final ms = asList(data['monthly']);
    return ms.isNotEmpty &&
        ms.every((m) => text(m['month']).startsWith('$year-'));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final callColor = passiveCallColor(p);
    final divColor = passiveDividendColor(p);
    final data = widget.passiveIncome;
    final ready = data['status'] == 'ready';
    final pending = asMap(data['pendingShortCalls']);
    final pendingRows = asList(pending['rows']);
    if (!ready && pendingRows.isEmpty) return const SizedBox.shrink();

    final allMonths = asList(data['monthly']);
    final years = _resolveYears(data, allMonths);
    final validScopes = <String>{
      ...years,
      if (allMonths.length > 6) 'TTM',
      'ALL',
    };
    final defaultScope = years.isNotEmpty ? years.first : 'ALL';
    final activeScope =
        selectedScope != null && validScopes.contains(selectedScope)
        ? selectedScope!
        : defaultScope;
    final isYearScope = years.contains(activeScope);

    late final List<Map<String, dynamic>> displayMonths;
    late final double windowDivs;
    late final double windowCalls;
    late final int windowDivCount;
    late final int windowCallCount;
    late final double? taxAmount;
    late final double? netDividends;
    late final List<Map<String, dynamic>> scopedByTicker;
    late final List<Map<String, dynamic>> scopedEvents;
    late final Map<String, dynamic> yoyInfo;
    late final String periodLabel;

    if (isYearScope) {
      final yrData = _resolveYearData(activeScope, data, allMonths);
      final yrDivInfo = asMap(yrData['dividends']);
      final yrCallInfo = asMap(yrData['expiredCalls']);
      displayMonths = asList(yrData['monthly']);
      windowDivs = number(yrDivInfo['grossAmount']);
      windowCalls = number(yrCallInfo['amount']);
      windowDivCount = number(yrDivInfo['eventCount']).round();
      windowCallCount = number(yrCallInfo['contractCount']).round();
      taxAmount = nullableNumber(yrDivInfo['withholdingTax']);
      netDividends = nullableNumber(yrDivInfo['netAmount']);
      final yrTickers = asList(yrData['byTicker']);
      scopedByTicker = yrTickers.isNotEmpty
          ? yrTickers
          : asList(data['byTicker']);
      scopedEvents = asList(yrData['recentEvents']);
      yoyInfo = asMap(yrData['yoy']);
      periodLabel =
          '${text(yrData['fromDate'], '$activeScope-01-01')} → ${text(yrData['toDate'], '$activeScope-12-31')}';
    } else if (activeScope == 'TTM') {
      displayMonths = allMonths.length > 12
          ? allMonths.sublist(allMonths.length - 12)
          : allMonths;
      windowDivs = displayMonths.fold<double>(
        0,
        (s, m) => s + number(m['dividends']),
      );
      windowCalls = displayMonths.fold<double>(
        0,
        (s, m) => s + number(m['expiredCalls']),
      );
      windowDivCount = displayMonths.fold<int>(
        0,
        (s, m) => s + number(m['dividendCount']).round(),
      );
      windowCallCount = displayMonths.fold<int>(
        0,
        (s, m) => s + number(m['callCount']).round(),
      );
      taxAmount = null;
      netDividends = null;
      scopedByTicker = asList(data['byTicker']);
      final minYm = displayMonths.isNotEmpty
          ? text(displayMonths.first['month'])
          : '';
      scopedEvents = asList(
        data['recentEvents'],
      ).where((e) => text(e['date']).compareTo(minYm) >= 0).toList();
      yoyInfo = const {};
      periodLabel = displayMonths.isNotEmpty
          ? '${displayMonths.first['month']} → ${displayMonths.last['month']}'
          : '—';
    } else {
      final divInfo = asMap(data['dividends']);
      final callInfo = asMap(data['expiredCalls']);
      displayMonths = allMonths;
      windowDivs = number(divInfo['grossAmount']);
      windowCalls = number(callInfo['amount']);
      windowDivCount = number(divInfo['eventCount']).round();
      windowCallCount = number(callInfo['contractCount']).round();
      taxAmount = nullableNumber(divInfo['withholdingTax']);
      netDividends = nullableNumber(divInfo['netAmount']);
      scopedByTicker = asList(data['byTicker']);
      scopedEvents = asList(data['recentEvents']);
      yoyInfo = years.isNotEmpty
          ? asMap(_resolveYearData(years.first, data, allMonths)['yoy'])
          : const {};
      periodLabel =
          '${text(data['fromDate'], '—')} → ${text(data['toDate'], '—')}';
    }

    final windowTotal = windowDivs + windowCalls;
    final allTimeTotal = number(data['totalConfirmed']);

    // Default active month on chart: latest covered month
    int? defaultChartIdx;
    for (var i = displayMonths.length - 1; i >= 0; i--) {
      if (displayMonths[i]['covered'] != false) {
        defaultChartIdx = i;
        break;
      }
    }
    final activeIdx = displayMonths.isEmpty
        ? null
        : (hoveredIndex ?? defaultChartIdx ?? (displayMonths.length - 1)).clamp(
            0,
            displayMonths.length - 1,
          );
    final activeMonth = activeIdx != null ? displayMonths[activeIdx] : null;

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
            _buildHeader(
              p: p,
              callColor: callColor,
              divColor: divColor,
              ready: ready,
              years: years,
              allMonthsCount: allMonths.length,
              activeScope: activeScope,
              data: data,
              allMonths: allMonths,
              periodLabel: periodLabel,
            ),
            if (ready) ...[
              const SizedBox(height: 16),
              _buildSummaryGrid(
                p: p,
                callColor: callColor,
                divColor: divColor,
                activeScope: activeScope,
                isYearScope: isYearScope,
                years: years,
                data: data,
                allMonths: allMonths,
                windowTotal: windowTotal,
                allTimeTotal: allTimeTotal,
                windowCalls: windowCalls,
                windowDivs: windowDivs,
                windowCallCount: windowCallCount,
                windowDivCount: windowDivCount,
                taxAmount: taxAmount,
                netDividends: netDividends,
                yoyInfo: yoyInfo,
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (_, c) {
                  final monthlyChart = _buildMonthlyChart(
                    p: p,
                    callColor: callColor,
                    divColor: divColor,
                    months: displayMonths,
                    hoveredIdx: hoveredIndex,
                    activeMonth: activeMonth,
                    isYearScope: isYearScope,
                    activeScope: activeScope,
                  );
                  final sourceBreakdown = _buildSourceBreakdown(
                    p: p,
                    callColor: callColor,
                    divColor: divColor,
                    rows: scopedByTicker,
                    scopeTotal: windowTotal > 0 ? windowTotal : allTimeTotal,
                    scopeLabel: isYearScope
                        ? w('$activeScope breakdown', '$activeScope 年贡献明细')
                        : w('Cumulative breakdown', '累计贡献明细'),
                  );
                  if (c.maxWidth >= 880 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.25) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: monthlyChart),
                        const SizedBox(width: 22),
                        Container(width: 1, height: 258, color: p.border),
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
              _buildPendingShortCalls(p, callColor, pending, pendingRows),
            ],
            if (asList(asMap(data['pendingShortPuts'])['rows']).isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildPendingShortPuts(
                p,
                asMap(data['pendingShortPuts']),
                asList(asMap(data['pendingShortPuts'])['rows']),
              ),
            ],
            if (ready && scopedEvents.isNotEmpty) ...[
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
                            'View confirmed records (${scopedEvents.length})',
                            '查看已确认流水（${scopedEvents.length} 笔）',
                          ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (showLedger)
                _buildRecentLedger(p, callColor, divColor, scopedEvents),
            ],
          ],
        ),
      ),
    );
  }

  String _yearOptionLabel(
    String yr,
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
    String latestYear,
  ) {
    final info = _resolveYearData(yr, data, allMonths);
    final isYtd = info['isYtd'] == true || yr == latestYear && info['isFullYear'] != true;
    final fromD = text(info['fromDate']);
    final isPartialStart =
        fromD.length >= 10 && !fromD.endsWith('-01-01') && yr != latestYear;
    if (isYtd) {
      return w('$yr (YTD)', '$yr 年（今年迄今）');
    }
    if (isPartialStart) {
      final startMm = fromD.substring(5, 7);
      return w('$yr (from $startMm)', '$yr 年（$startMm月起）');
    }
    return w('$yr Full Year', '$yr 全年');
  }

  Widget _buildHeader({
    required Palette p,
    required Color callColor,
    required Color divColor,
    required bool ready,
    required List<String> years,
    required int allMonthsCount,
    required String activeScope,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required String periodLabel,
  }) {
    final dropdownItems = <(String, String)>[
      for (final yr in years)
        (yr, _yearOptionLabel(yr, data, allMonths, years.first)),
      if (allMonthsCount > 6) ('TTM', w('Trailing 12M', '近 12 个月（滚动）')),
      ('ALL', w('All years combined', '全部年份累计')),
    ];

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: p.border),
              ),
              child: Icon(
                Icons.payments_outlined,
                size: 17,
                color: p.muted,
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
                      'Received cash dividends + OTM expired short calls · $periodLabel',
                      '实际到账股息 + 到期作废确认卖 Call 权利金 · $periodLabel',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (ready && dropdownItems.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today_outlined, size: 14, color: p.muted),
                const SizedBox(width: 7),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey('passive-year-dropdown'),
                    value: dropdownItems.any((e) => e.$1 == activeScope)
                        ? activeScope
                        : dropdownItems.first.$1,
                    isDense: true,
                    dropdownColor: p.panel,
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: p.text,
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    items: [
                      for (final item in dropdownItems)
                        DropdownMenuItem<String>(
                          value: item.$1,
                          child: Text(item.$2),
                        ),
                    ],
                    onChanged: (next) {
                      if (next == null) return;
                      setState(() {
                        selectedScope = next;
                        hoveredIndex = null;
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSummaryGrid({
    required Palette p,
    required Color callColor,
    required Color divColor,
    required String activeScope,
    required bool isYearScope,
    required List<String> years,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required double windowTotal,
    required double allTimeTotal,
    required double windowCalls,
    required double windowDivs,
    required int windowCallCount,
    required int windowDivCount,
    required double? taxAmount,
    required double? netDividends,
    required Map<String, dynamic> yoyInfo,
  }) {
    final yoyStatus = text(yoyInfo['status']);
    final hasComparableYoy =
        yoyStatus == 'full_same_period' || yoyStatus == 'overlapping_subperiod';
    final callYoyPct = hasComparableYoy
        ? nullableNumber(yoyInfo['pctCalls'])
        : null;
    final divYoyPct = hasComparableYoy
        ? nullableNumber(yoyInfo['pctDividends'])
        : null;

    return LayoutBuilder(
      builder: (_, c) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final cols = c.maxWidth >= 940 && textScale <= 1.25
            ? 4
            : (c.maxWidth >= 560 && textScale <= 1.3 ? 2 : 1);
        final tileWidth = cols == 1
            ? c.maxWidth
            : (c.maxWidth - (cols - 1) * 12) / cols;

        final tiles = <Widget>[
          _summaryTile(
            p: p,
            accentColor: p.text,
            title: isYearScope
                ? w('$activeScope confirmed total', '$activeScope 年已确认合计')
                : w('Total confirmed', '已确认被动收入合计'),
            value: widget.hideAmounts
                ? (windowTotal > 0 ? '100.0%' : '—')
                : fmtMoney(windowTotal),
            badge: null,
            subtitle: widget.hideAmounts
                ? w(
                    'Calls ${fmtShare(windowCalls, windowTotal)} · Dividends ${fmtShare(windowDivs, windowTotal)}',
                    '卖 Call ${fmtShare(windowCalls, windowTotal)} · 股息 ${fmtShare(windowDivs, windowTotal)}',
                  )
                : (isYearScope && years.length > 1
                      ? w(
                          'Calls ${fmtShare(windowCalls, windowTotal)} · Divs ${fmtShare(windowDivs, windowTotal)} · All-time ${fmtMoney(allTimeTotal)}',
                          'Call ${fmtShare(windowCalls, windowTotal)} · 股息 ${fmtShare(windowDivs, windowTotal)} · 跨年累计 ${fmtMoney(allTimeTotal)}',
                        )
                      : w(
                          'Calls ${fmtShare(windowCalls, windowTotal)} · Dividends ${fmtShare(windowDivs, windowTotal)}',
                          '卖 Call 占 ${fmtShare(windowCalls, windowTotal)} · 股息占 ${fmtShare(windowDivs, windowTotal)}',
                        )),
            highlight: true,
          ),
          _summaryTile(
            p: p,
            accentColor: callColor,
            title: w('Expired short calls', '卖 Call 到期确认收入'),
            value: widget.hideAmounts
                ? fmtShare(windowCalls, windowTotal)
                : fmtMoney(windowCalls),
            badge: callYoyPct != null
                ? '${w('YoY', '同比')} ${fmtPct(callYoyPct)}'
                : null,
            badgePositive: callYoyPct == null ? null : callYoyPct >= 0,
            subtitle: widget.hideAmounts
                ? w('Share of confirmed income', '占当期已确认收入比例')
                : w(
                    '$windowCallCount expired contracts · net of fees',
                    '$windowCallCount 张期权到期作废确认 · 已扣佣金',
                  ),
          ),
          _summaryTile(
            p: p,
            accentColor: divColor,
            title: w('Cash dividends', '已到账现金股息'),
            value: widget.hideAmounts
                ? fmtShare(windowDivs, windowTotal)
                : fmtMoney(windowDivs),
            badge: divYoyPct != null
                ? '${w('YoY', '同比')} ${fmtPct(divYoyPct)}'
                : null,
            badgePositive: divYoyPct == null ? null : divYoyPct >= 0,
            subtitle: widget.hideAmounts
                ? w('Share of confirmed income', '占当期已确认收入比例')
                : (taxAmount != null && taxAmount < 0 && netDividends != null
                      ? w(
                          'Net ${fmtMoney(netDividends)} after ${fmtMoney(taxAmount)} tax',
                          '税后净额 ${fmtMoney(netDividends)}（预扣税 ${fmtMoney(taxAmount)}）',
                        )
                      : w(
                          '$windowDivCount broker cash payouts received',
                          '$windowDivCount 笔券商现金分红入账',
                        )),
          ),
          _buildYoySummaryTile(
            p: p,
            activeScope: activeScope,
            isYearScope: isYearScope,
            years: years,
            data: data,
            allMonths: allMonths,
            yoyInfo: yoyInfo,
          ),
        ];

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }

  Widget _buildYoySummaryTile({
    required Palette p,
    required String activeScope,
    required bool isYearScope,
    required List<String> years,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required Map<String, dynamic> yoyInfo,
  }) {
    final status = text(yoyInfo['status']);
    final priorYear = text(
      yoyInfo['priorYear'],
      isYearScope
          ? '${(int.tryParse(activeScope) ?? 2026) - 1}'
          : (years.length > 1 ? years[1] : ''),
    );

    if (!isYearScope && activeScope == 'ALL' && years.length >= 2) {
      final y0 = _resolveYearData(years[0], data, allMonths);
      final y1 = _resolveYearData(years[1], data, allMonths);
      final t0 = number(y0['totalConfirmed']);
      final t1 = number(y1['totalConfirmed']);
      return Container(
        key: const ValueKey('passive-yoy-card'),
        child: _summaryTile(
          p: p,
          accentColor: p.accent,
          title: w('Annual history overview', '历年被动收入对比'),
          value: w('${years.length} years', '共 ${years.length} 个年度'),
          subtitle: widget.hideAmounts
              ? w(
                  'Select any year in dropdown for YoY view',
                  '右上角下拉可按年份回看及对比同期',
                )
              : '${years[0]}: ${fmtMoney(t0)} · ${years[1]}: ${fmtMoney(t1)}',
        ),
      );
    }

    if (status == 'full_same_period' || status == 'overlapping_subperiod') {
      final deltaTotal = number(yoyInfo['deltaTotal']);
      final pctTotal = nullableNumber(yoyInfo['pctTotal']);
      final priorTotal = number(yoyInfo['priorTotal']);
      final deltaCalls = number(yoyInfo['deltaCalls']);
      final deltaDivs = number(yoyInfo['deltaDividends']);
      final priorFrom = text(yoyInfo['priorFrom']);
      final priorTo = text(yoyInfo['priorTo']);
      final windowSpan = priorFrom.length >= 10 && priorTo.length >= 10
          ? '${priorFrom.substring(5)}~${priorTo.substring(5)}'
          : priorYear;
      final up = deltaTotal >= 0;
      final tone = up ? p.positive : p.negative;

      return Container(
        key: const ValueKey('passive-yoy-card'),
        child: _summaryTile(
          p: p,
          accentColor: tone,
          title: status == 'full_same_period'
              ? w('vs $priorYear same period (YoY)', '对比 $priorYear 去年同期')
              : w('vs $priorYear matched window', '对比 $priorYear 可比同期 ($windowSpan)'),
          value: widget.hideAmounts
              ? (pctTotal != null ? fmtPct(pctTotal) : (up ? '↑' : '↓'))
              : fmtMoney(deltaTotal, signed: true),
          badge: !widget.hideAmounts && pctTotal != null
              ? fmtPct(pctTotal)
              : null,
          badgePositive: up,
          valueColor: tone,
          subtitle: widget.hideAmounts
              ? w(
                  'Same-period comparison ($windowSpan)',
                  '严格同日历区间对比 ($windowSpan)',
                )
              : w(
                  '$priorYear ($windowSpan): ${fmtMoney(priorTotal)} · Call ${fmtMoney(deltaCalls, signed: true)} · Div ${fmtMoney(deltaDivs, signed: true)}',
                  '$priorYear 同期 ${fmtMoney(priorTotal)} · Call ${fmtMoney(deltaCalls, signed: true)} · 股息 ${fmtMoney(deltaDivs, signed: true)}',
                ),
        ),
      );
    }

    return Container(
      key: const ValueKey('passive-yoy-card'),
      child: _summaryTile(
        p: p,
        accentColor: p.faint,
        title: priorYear.isNotEmpty
            ? w('vs $priorYear same period (YoY)', '对比 $priorYear 去年同期')
            : w('Year-over-year comparison', '与去年同期对比'),
        value: w('Baseline year', '基准记录年'),
        subtitle: priorYear.isNotEmpty
            ? w(
                'No $priorYear same-period broker history yet; YoY unlocks automatically as annual history accumulates.',
                '暂无 $priorYear 同日历区间券商流水，跨满周年后将自动展示同期增减对比。',
              )
            : w(
                'YoY comparison activates automatically across years.',
                '跨年度流水积累后自动展示同期同比增减。',
              ),
      ),
    );
  }

  Widget _summaryTile({
    required Palette p,
    required Color accentColor,
    required String title,
    required String value,
    required String subtitle,
    String? badge,
    bool? badgePositive,
    Color? valueColor,
    bool highlight = false,
  }) {
    final badgeTint = badgePositive == null
        ? p.muted
        : (badgePositive ? p.positive : p.negative);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: highlight ? .62 : .42),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: highlight ? p.text.withValues(alpha: .16) : p.border,
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
                  color: accentColor.withValues(alpha: .88),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeTint.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: badgeTint,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 9),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? p.text,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -.3,
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
  }

  Widget _buildMonthlyChart({
    required Palette p,
    required Color callColor,
    required Color divColor,
    required List<Map<String, dynamic>> months,
    required int? hoveredIdx,
    required Map<String, dynamic>? activeMonth,
    required bool isYearScope,
    required String activeScope,
  }) {
    if (months.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          w('No monthly observations in this range.', '所选区间暂无月度确认收入。'),
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
      );
    }
    final hasAnyPriorOverlay =
        isYearScope &&
        months.any(
          (m) =>
              m['priorYearCovered'] == true && number(m['priorYearTotal']) > 0,
        );
    final maxTotal = months.fold<double>(0, (mx, r) {
      final cur = number(r['total']);
      final prev = isYearScope && r['priorYearCovered'] == true
          ? number(r['priorYearTotal'])
          : 0.0;
      return math.max(mx, math.max(cur, prev));
    });

    final activeCovered = activeMonth?['covered'] != false;
    final activeTotal = number(activeMonth?['total']);
    final activeCalls = number(activeMonth?['expiredCalls']);
    final activeDivs = number(activeMonth?['dividends']);
    final activePriorCovered =
        isYearScope && activeMonth?['priorYearCovered'] == true;
    final activePriorTotal = number(activeMonth?['priorYearTotal']);

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
              isYearScope
                  ? w(
                      '$activeScope monthly cashflow (Jan–Dec)',
                      '$activeScope 年月度确认收入（1–12月）',
                    )
                  : w('Monthly confirmed cashflow', '月度已确认被动收入'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _legendDot(p, callColor, w('Expired Call', '卖 Call 到期')),
                _legendDot(p, divColor, w('Cash Dividend', '现金股息')),
                if (hasAnyPriorOverlay)
                  _legendTick(p, w('Prior yr month', '去年同月')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (activeMonth != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                !activeCovered
                    ? '${text(activeMonth['month'])} · ${w('Not yet reached / outside report window', '尚未进入该月份或不在报表区间')}'
                    : widget.hideAmounts
                    ? '${text(activeMonth['month'])} · ${activeTotal > 0 ? '${w('Call', '卖 Call')} ${fmtShare(activeCalls, activeTotal)} · ${w('Div', '股息')} ${fmtShare(activeDivs, activeTotal)}' : w('No confirmed income', '无确认收入')}'
                    : '${text(activeMonth['month'])} · ${fmtMoney(activeTotal)}',
                style: TextStyle(
                  color: activeCovered && activeTotal > 0 ? p.text : p.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (activeCovered && !widget.hideAmounts) ...[
                Text(
                  '${w('Call', '卖 Call')} ${fmtMoney(activeCalls)}',
                  style: TextStyle(
                    color: callColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${w('Div', '股息')} ${fmtMoney(activeDivs)}',
                  style: TextStyle(
                    color: divColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (activeCovered && activePriorCovered && !widget.hideAmounts)
                Text(
                  '· ${w('Prior yr', '去年同月')} ${fmtMoney(activePriorTotal)}${activePriorTotal > 0 ? ' (${fmtPct((activeTotal - activePriorTotal) / activePriorTotal)})' : ''}',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
            ],
          ),
        const SizedBox(height: 12),
        SizedBox(
          key: const ValueKey('passive-income-monthly-chart'),
          height: 188,
          child: LayoutBuilder(
            builder: (_, c) {
              void selectAt(double dx) {
                if (months.isEmpty) return;
                const leftPad = 48.0;
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
                      callColor: callColor,
                      divColor: divColor,
                      activeIndex: hoveredIdx,
                      hideAmounts: widget.hideAmounts,
                      isYearScope: isYearScope,
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
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: p.text, fontSize: 11)),
    ],
  );

  Widget _legendTick(Palette p, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 2,
        decoration: BoxDecoration(
          color: p.text.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
    ],
  );

  Widget _buildSourceBreakdown({
    required Palette p,
    required Color callColor,
    required Color divColor,
    required List<Map<String, dynamic>> rows,
    required double scopeTotal,
    required String scopeLabel,
  }) {
    final top = rows.where((r) => number(r['total']) > 0).take(6).toList();
    final maxRow = top.fold<double>(
      0,
      (m, r) => math.max(m, number(r['total'])),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              w('By underlying source', '按标的来源贡献'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(scopeLabel, style: TextStyle(color: p.muted, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 12),
        if (top.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              w('No confirmed passive income in this period.', '该区间暂无已确认被动收入记录。'),
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
                        child: Wrap(
                          spacing: 5,
                          runSpacing: 3,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              text(r['ticker']),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (number(r['expiredCalls']) > 0)
                              _miniTag(
                                callColor,
                                widget.hideAmounts
                                    ? w('Call', '卖 Call')
                                    : '${w('Call', 'Call')} ${fmtMoney(r['expiredCalls'])}',
                              ),
                            if (number(r['dividends']) > 0)
                              _miniTag(
                                divColor,
                                widget.hideAmounts
                                    ? w('Div', '股息')
                                    : '${w('Div', '股息')} ${fmtMoney(r['dividends'])}',
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.hideAmounts
                            ? fmtShare(number(r['total']), scopeTotal)
                            : fmtMoney(r['total']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  LayoutBuilder(
                    builder: (_, barConstraints) {
                      final fullW = barConstraints.maxWidth;
                      final hasBoth =
                          number(r['expiredCalls']) > 0 &&
                          number(r['dividends']) > 0;
                      final gap = hasBoth ? 2.0 : 0.0;
                      final usableW = math.max(0.0, fullW - gap);
                      final callW = maxRow > 0
                          ? (number(r['expiredCalls']) / maxRow * usableW)
                                .clamp(0.0, usableW)
                                .toDouble()
                          : 0.0;
                      final divW = maxRow > 0
                          ? (number(r['dividends']) / maxRow * usableW)
                                .clamp(0.0, math.max(0.0, usableW - callW))
                                .toDouble()
                          : 0.0;
                      return Container(
                        height: 5.5,
                        decoration: BoxDecoration(
                          color: p.border.withValues(alpha: .42),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          children: [
                            if (callW > 0)
                              Container(
                                width: callW,
                                height: 5.5,
                                decoration: BoxDecoration(
                                  color: callColor.withValues(alpha: .82),
                                  borderRadius: BorderRadius.horizontal(
                                    left: const Radius.circular(3),
                                    right: hasBoth
                                        ? const Radius.circular(1)
                                        : const Radius.circular(3),
                                  ),
                                ),
                              ),
                            if (hasBoth) SizedBox(width: gap),
                            if (divW > 0)
                              Container(
                                width: divW,
                                height: 5.5,
                                decoration: BoxDecoration(
                                  color: divColor.withValues(alpha: .82),
                                  borderRadius: BorderRadius.horizontal(
                                    left: hasBoth
                                        ? const Radius.circular(1)
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

  Widget _miniTag(Color tint, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
    decoration: BoxDecoration(
      color: tint.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: tint.withValues(alpha: .22), width: 0.6),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: tint.withValues(alpha: .92),
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _buildPendingShortCalls(
    Palette p,
    Color callColor,
    Map<String, dynamic> pending,
    List<Map<String, dynamic>> pendingRows,
  ) => Container(
    key: const ValueKey('passive-pending-short-calls'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .38),
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
                  color: callColor.withValues(alpha: .85),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    w(
                      'Pending short calls · confirmed only after expiration',
                      '待到期卖 Call · 未到期暂不计入确认收入',
                    ),
                    style: TextStyle(
                      color: p.muted,
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
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
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
  );

  Widget _buildPendingShortPuts(
    Palette p,
    Map<String, dynamic> pendingPuts,
    List<Map<String, dynamic>> putRows,
  ) {
    const putColor = Color(0xFF8E8CD8);
    return Container(
      key: const ValueKey('passive-pending-short-puts'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: .38),
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
                  const Icon(Icons.shield_outlined, size: 15, color: putColor),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      w(
                        'Open short puts · collateral & unconfirmed premium',
                        '在途卖 Put · 接盘备付金与待确认权利金',
                      ),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (!widget.hideAmounts)
                Text(
                  [
                    if (nullableNumber(pendingPuts['collectedPremium']) != null)
                      w(
                        'Premium: ${fmtMoney(pendingPuts['collectedPremium'])}',
                        '权利金：${fmtMoney(pendingPuts['collectedPremium'])}',
                      ),
                    if (nullableNumber(pendingPuts['collateralExposure']) !=
                        null)
                      w(
                        'Assignment notional: ${fmtMoney(pendingPuts['collateralExposure'])}',
                        '行权接盘敞口：${fmtMoney(pendingPuts['collateralExposure'])}',
                      ),
                  ].join(' · '),
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
              for (final r in putRows)
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
                        : '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? formatNumber(number(r['strike'])) : ''}P · ${text(r['expiry'], '—')} ×${number(r['contracts']).round()}',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentLedger(
    Palette p,
    Color callColor,
    Color divColor,
    List<Map<String, dynamic>> events,
  ) => Container(
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .36),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: p.border),
    ),
    child: Column(
      children: [
        for (var i = 0; i < events.take(20).length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (events[i]['kind'] == 'expired_call'
                                ? callColor
                                : divColor)
                            .withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    events[i]['kind'] == 'expired_call'
                        ? w('Call', '卖 Call')
                        : w('Div', '股息'),
                    style: TextStyle(
                      color: events[i]['kind'] == 'expired_call'
                          ? callColor
                          : divColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                        ? callColor
                        : divColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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
    required this.callColor,
    required this.divColor,
    required this.activeIndex,
    required this.hideAmounts,
    required this.isYearScope,
  });

  final List<Map<String, dynamic>> months;
  final double maxTotal;
  final Palette palette;
  final Color callColor;
  final Color divColor;
  final int? activeIndex;
  final bool hideAmounts;
  final bool isYearScope;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const bottomPad = 24.0;
    const topPad = 8.0;
    final rect = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - 8,
      size.height - bottomPad,
    );
    if (rect.width <= 0 || rect.height <= 0 || months.isEmpty) return;

    final scaleMax = maxTotal > 0 ? maxTotal * 1.14 : 100.0;
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
    final barW = (slotW * 0.58).clamp(6.0, 26.0);
    final labelStep = months.length > 12 ? 2 : 1;

    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final covered = m['covered'] != false;
      final calls = number(m['expiredCalls']);
      final divs = number(m['dividends']);
      final cx = rect.left + (i + 0.5) * slotW;
      final isFocused = activeIndex == null || activeIndex == i;

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
          Paint()..color = palette.text.withValues(alpha: .06),
        );
      }

      if (!covered) {
        // Subtle placeholder base tick for future/uncovered months in a 12-month year view
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, rect.bottom - 1.5),
              width: barW * 0.7,
              height: 2,
            ),
            const Radius.circular(1),
          ),
          Paint()..color = palette.border.withValues(alpha: .45),
        );
      } else {
        final divH = maxTotal > 0 ? (divs / scaleMax) * rect.height : 0.0;
        final callH = maxTotal > 0 ? (calls / scaleMax) * rect.height : 0.0;
        final hasBoth = divH > 1.5 && callH > 1.5;
        final gap = hasBoth ? 1.8 : 0.0;

        final barAlpha = activeIndex == null
            ? 0.80
            : (isFocused ? 0.94 : 0.36);

        if (divH > 0) {
          final adjDivH = math.max(1.5, divH - (hasBoth ? gap * 0.5 : 0));
          final divRect = Rect.fromLTWH(
            cx - barW / 2,
            rect.bottom - adjDivH,
            barW,
            adjDivH,
          );
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              divRect,
              topLeft: hasBoth
                  ? const Radius.circular(1.5)
                  : const Radius.circular(3.5),
              topRight: hasBoth
                  ? const Radius.circular(1.5)
                  : const Radius.circular(3.5),
            ),
            Paint()..color = divColor.withValues(alpha: barAlpha),
          );
        }
        if (callH > 0) {
          final baseOffset = divH > 0 ? divH + gap * 0.5 : 0.0;
          final adjCallH = math.max(1.5, callH - (hasBoth ? gap * 0.5 : 0));
          final callRect = Rect.fromLTWH(
            cx - barW / 2,
            rect.bottom - baseOffset - adjCallH,
            barW,
            adjCallH,
          );
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              callRect,
              topLeft: const Radius.circular(3.5),
              topRight: const Radius.circular(3.5),
              bottomLeft: hasBoth ? const Radius.circular(1.5) : Radius.zero,
              bottomRight: hasBoth ? const Radius.circular(1.5) : Radius.zero,
            ),
            Paint()..color = callColor.withValues(alpha: barAlpha),
          );
        }
      }

      // Draw prior-year same-month reference tick when viewing a specific year
      if (isYearScope &&
          m['priorYearCovered'] == true &&
          number(m['priorYearTotal']) > 0 &&
          maxTotal > 0) {
        final priorH = (number(m['priorYearTotal']) / scaleMax) * rect.height;
        final py = rect.bottom - priorH;
        canvas.drawLine(
          Offset(cx - barW * 0.58, py),
          Offset(cx + barW * 0.58, py),
          Paint()
            ..color = palette.text.withValues(alpha: isFocused ? 0.72 : 0.35)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }

      if (i % labelStep == 0 || i == months.length - 1) {
        final rawM = text(m['month']);
        final shortM = isYearScope && rawM.length >= 7
            ? rawM.substring(5)
            : (rawM.length >= 7 ? rawM.substring(2) : rawM);
        final mtp = TextPainter(
          text: TextSpan(
            text: shortM,
            style: TextStyle(
              color: activeIndex == i
                  ? palette.text
                  : (covered ? palette.muted : palette.faint),
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
      old.palette != palette ||
      old.callColor != callColor ||
      old.divColor != divColor ||
      old.activeIndex != activeIndex ||
      old.hideAmounts != hideAmounts ||
      old.isYearScope != isYearScope;
}
