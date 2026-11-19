part of 'main.dart';

final Expando<Map<String, Map<String, dynamic>>> _researchFundamentalsCache =
    Expando<Map<String, Map<String, dynamic>>>();

// Route fallback is exact, never a substitute company. An explicit research
// ticker wins over the candidate retained by the discovery workspace.
String researchEntryTicker(String page, String explicit, String? candidate) =>
    (explicit.trim().isNotEmpty
            ? explicit
            : page == 'research'
            ? candidate ?? ''
            : '')
        .trim()
        .toUpperCase();

String researchReportKey(Map<String, dynamic> row) =>
    '${text(row['period'])}|${text(row['availableAt'])}';

List<Map<String, dynamic>> researchDatedRows(
  List<Map<String, dynamic>> rows,
  String dateKey,
  String asOf, {
  String from = '',
}) => rows.where((r) {
  final date = text(r[dateKey]);
  return DateTime.tryParse(date) != null &&
      date.compareTo(asOf) <= 0 &&
      (from.isEmpty || date.compareTo(from) >= 0);
}).toList()..sort((a, b) => text(a[dateKey]).compareTo(text(b[dateKey])));

// A displayed model change requires a common methodology and version. It is a
// change between model nodes, not an attribution of causality to one input.
double? researchValueChange(
  Map<String, dynamic> now,
  Map<String, dynamic>? prior,
) {
  if (prior == null ||
      text(now['publishedFormula']).isEmpty ||
      now['publishedFormula'] != prior['publishedFormula'] ||
      text(asMap(now['source'])['modelVersion']).isEmpty ||
      asMap(now['source'])['modelVersion'] !=
          asMap(prior['source'])['modelVersion']) {
    return null;
  }
  final a = nullableNumber(now['publishedFairValue']);
  final b = nullableNumber(prior['publishedFairValue']);
  return a != null && b != null && b > 0 ? a / b - 1 : null;
}

int? researchFinancialQuarter(Map<String, dynamic> row) {
  final fiscal = RegExp(
    r'^(\d{4})-?Q([1-4])$',
  ).firstMatch(text(row['fiscalperiod']));
  if (fiscal != null) {
    return int.parse(fiscal[1]!) * 4 + int.parse(fiscal[2]!) - 1;
  }
  final date = DateTime.tryParse(
    text(
      row['calendardate'],
      text(row['period_end'], text(row['reportperiod'])),
    ),
  );
  return date == null ? null : date.year * 4 + ((date.month - 1) / 3).floor();
}

String researchFinancialQuarterLabel(Map<String, dynamic> row) {
  final index = researchFinancialQuarter(row);
  return index == null
      ? text(row['reportperiod'])
      : '${(index / 4).floor()} Q${index % 4 + 1}';
}

// Compare exact periods, not adjacent displayed bars: missing quarters must
// never turn a six-month change into QoQ. API facts are already PIT selected.
Map<String, dynamic>? researchFinancialPrior(
  Map<String, dynamic> row,
  List<Map<String, dynamic>> rows,
  int quarters,
) {
  final index = researchFinancialQuarter(row);
  if (index == null) return null;
  final matches = rows
      .where((r) => researchFinancialQuarter(r) == index - quarters)
      .toList();
  return matches.length == 1 ? matches.single : null;
}

String formatResearchStatementUnitValue(double value, String unit) =>
    switch (unit) {
      'percent' => '${(value * 100).toStringAsFixed(1)}%',
      'multiple' => '${value.toStringAsFixed(2)}x',
      'per_share' => '\$${value.toStringAsFixed(value.abs() < 1 ? 3 : 2)}',
      _ => formatNumber(value),
    };

double? researchFinancialReportedValue(
  Map<String, dynamic> period,
  String key,
) {
  double? ratioFrom(String numKey, String denKey) {
    final numVal = researchFinancialReportedValue(period, numKey);
    final denVal = researchFinancialReportedValue(period, denKey);
    if (numVal == null || denVal == null || !numVal.isFinite || !denVal.isFinite || denVal == 0) {
      return null;
    }
    return numVal / denVal;
  }

  switch (key) {
    case 'grossmargin_calc':
      return ratioFrom('gp', 'revenue');
    case 'opmargin_calc':
      return ratioFrom('opinc', 'revenue');
    case 'ebitdamargin_calc':
      return ratioFrom('ebitda', 'revenue');
    case 'netmargin_calc':
      return ratioFrom('netinccmn', 'revenue');
    case 'fcfmargin_calc':
      return ratioFrom('fcf', 'revenue');
    case 'de_calc':
      return ratioFrom('debt', 'equity');
    case 'currentratio_calc':
      return ratioFrom('assetsc', 'liabilitiesc');
  }

  if (period['kind'] != 'ttm') return nullableNumber(asMap(period['row'])[key]);
  if (const {'roe', 'roa', 'roic'}.contains(key)) {
    return nullableNumber(asMap(period['row'])[key]);
  }
  final rows = asList(period['rows']);
  if (rows.length != 4) return null;
  final indices = rows.map(researchFinancialQuarter).toList();
  if (indices.any((i) => i == null) ||
      List.generate(
        3,
        (i) => indices[i]! - indices[i + 1]!,
      ).any((gap) => gap != 1)) {
    return null;
  }
  final currencies = rows
      .map((r) => text(r['currency']))
      .where((c) => c.isNotEmpty)
      .toSet();
  if (currencies.length > 1) return null;
  final values = rows.map((r) => nullableNumber(r[key])).toList();
  if (values.any((v) => v == null || !v.isFinite)) return null;
  final total = values.fold<double>(0, (sum, value) => sum + value!);
  // A TTM weighted-average share count needs period-day weights, absent here.
  return const {'sharesbas', 'shareswa', 'shareswadil', 'bvps'}.contains(key)
      ? nullableNumber(asMap(period['row'])[key])
      : total;
}

({double? value, String reason}) researchFinancialGrowth(
  Map<String, dynamic> period,
  String key,
  String comparison, {
  String unit = 'currency',
}) {
  if (comparison == 'qoq' && const {'annual', 'ttm'}.contains(period['kind'])) {
    return (value: null, reason: 'quarterly_only');
  }
  final prior = asMap(period[comparison]);
  final value = researchFinancialReportedValue(period, key);
  final base = prior.isEmpty
      ? null
      : researchFinancialReportedValue(prior, key);
  if (value == null || !value.isFinite || base == null || !base.isFinite) {
    return (value: null, reason: 'missing_comparable_period');
  }
  final currency = text(asMap(period['row'])['currency']);
  final baseCurrency = text(asMap(prior['row'])['currency']);
  if (currency.isNotEmpty &&
      baseCurrency.isNotEmpty &&
      currency != baseCurrency) {
    return (value: null, reason: 'currency_changed');
  }
  if (unit == 'percent') {
    return (value: value - base, reason: 'pp_delta');
  }
  if (base <= 0) return (value: null, reason: 'non_positive_base');
  return (value: value / base - 1, reason: 'available');
}

class _ResearchFinancialSeries {
  const _ResearchFinancialSeries({
    required this.keyName,
    required this.label,
    required this.color,
    required this.values,
    required this.yoy,
    required this.qoq,
    this.unit = 'currency',
  });
  final String keyName, label, unit;
  final Color color;
  final List<double?> values;
  final List<({double? value, String reason})> yoy, qoq;
}

class _ResearchFinancialBarChart extends StatefulWidget {
  const _ResearchFinancialBarChart({
    required this.periods,
    required this.series,
    required this.muted,
    required this.textColor,
    required this.grid,
    required this.details,
  });
  final List<String> periods;
  final List<_ResearchFinancialSeries> series;
  final Color muted, textColor, grid;
  final List<String> details;

  @override
  State<_ResearchFinancialBarChart> createState() =>
      _ResearchFinancialBarChartState();
}

class _ResearchFinancialBarChartState
    extends State<_ResearchFinancialBarChart> {
  int? hovered;

  @override
  void didUpdateWidget(covariant _ResearchFinancialBarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.periods.join('|') != widget.periods.join('|')) hovered = null;
  }

  String growthText(
    BuildContext context,
    ({double? value, String reason}) growth,
  ) {
    if (growth.value case final value?) {
      if (growth.reason == 'pp_delta') {
        return '${value >= 0 ? '+' : ''}${(value * 100).toStringAsFixed(1)} pp';
      }
      return '${value >= 0 ? '+' : ''}${(value * 100).toStringAsFixed(1)}%';
    }
    return switch (growth.reason) {
      'quarterly_only' => context.tr('仅季度', 'Quarterly only'),
      'non_positive_base' => context.tr('不适用（基期≤0）', 'N/M (base ≤ 0)'),
      'currency_changed' => context.tr('币种不同', 'Currency changed'),
      _ => context.tr('— 缺少可比期', '— Missing base'),
    };
  }

  void updateHover(Offset position, double width) {
    const left = 62.0, right = 10.0;
    final plot = math.max(1, width - left - right);
    final raw = ((position.dx - left) / plot * widget.periods.length).floor();
    final next = raw >= 0 && raw < widget.periods.length ? raw : null;
    if (next != hovered) setState(() => hovered = next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.series.isEmpty || widget.periods.isEmpty) {
      return Center(
        child: Text(
          context.tr('选择一个报表项目', 'Select a reported line item'),
          style: TextStyle(color: widget.muted, fontSize: 12),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final series in widget.series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: series.color,
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        series.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: widget.textColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (_, bounds) => MouseRegion(
              key: const ValueKey('research-financial-hover-area'),
              onHover: (event) =>
                  updateHover(event.localPosition, bounds.maxWidth),
              onExit: (_) => setState(() => hovered = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (event) =>
                    updateHover(event.localPosition, bounds.maxWidth),
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size.infinite,
                      painter: _ResearchFinancialBarPainter(
                        periods: widget.periods,
                        series: widget.series,
                        muted: widget.muted,
                        grid: widget.grid,
                        hovered: hovered,
                        language: context.language,
                      ),
                    ),
                    if (hovered case final index?)
                      Positioned(
                        top: 4,
                        left: math
                            .min(
                              math.max(
                                4.0,
                                62 +
                                    (bounds.maxWidth - 72) *
                                        (index + .5) /
                                        widget.periods.length -
                                    150,
                              ),
                              math.max(4.0, bounds.maxWidth - 312),
                            )
                            .toDouble(),
                        child: IgnorePointer(
                          child: Container(
                            key: const ValueKey('research-financial-tooltip'),
                            width: math.min(304.0, bounds.maxWidth - 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF14181F),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: widget.grid),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 10),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.periods[index],
                                  style: TextStyle(
                                    color: widget.textColor,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (widget.details[index].isNotEmpty)
                                  Text(
                                    widget.details[index],
                                    style: TextStyle(
                                      color: widget.muted,
                                      fontSize: 9.5,
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                for (final series in widget.series)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${series.label}: ${series.values[index] == null ? '—' : formatResearchStatementUnitValue(series.values[index]!, series.unit)}',
                                          style: TextStyle(
                                            color: series.color,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Wrap(
                                          spacing: 12,
                                          runSpacing: 2,
                                          children: [
                                            Text(
                                              '${context.tr('同比', 'YoY')} ${growthText(context, series.yoy[index])}',
                                              style: TextStyle(
                                                color: widget.textColor,
                                                fontSize: 11,
                                              ),
                                            ),
                                            Text(
                                              '${context.tr('环比', 'QoQ')} ${growthText(context, series.qoq[index])}',
                                              style: TextStyle(
                                                color: widget.textColor,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
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
    );
  }
}

class _ResearchFinancialBarPainter extends CustomPainter {
  _ResearchFinancialBarPainter({
    required this.periods,
    required this.series,
    required this.muted,
    required this.grid,
    required this.hovered,
    this.language = AppLanguage.en,
  });
  final List<String> periods;
  final List<_ResearchFinancialSeries> series;
  final Color muted, grid;
  final int? hovered;
  final AppLanguage language;

  String axis(double value) {
    final unit = series.isNotEmpty ? series.first.unit : 'currency';
    if (unit == 'percent') {
      return '${(value * 100).toStringAsFixed(value.abs() < 0.1 ? 1 : 0)}%';
    }
    if (unit == 'multiple') {
      return '${value.toStringAsFixed(1)}x';
    }
    if (unit == 'per_share') {
      return '\$${value.toStringAsFixed(value.abs() < 5 ? 2 : 1)}';
    }
    final magnitude = value.abs();
    if (language == AppLanguage.zh) {
      final sign = value < 0 ? '-' : '';
      if (magnitude >= 1e12) {
        return '$sign${(magnitude / 1e12).toStringAsFixed(1)}万亿';
      }
      if (magnitude >= 1e8) {
        return '$sign${(magnitude / 1e8).toStringAsFixed(magnitude >= 1e10 ? 0 : 1)}亿';
      }
      if (magnitude >= 1e4) {
        return '$sign${(magnitude / 1e4).toStringAsFixed(0)}万';
      }
    }
    if (magnitude >= 1e12) return '${(value / 1e12).toStringAsFixed(1)}T';
    if (magnitude >= 1e9) return '${(value / 1e9).toStringAsFixed(1)}B';
    if (magnitude >= 1e6) return '${(value / 1e6).toStringAsFixed(0)}M';
    if (magnitude >= 1e3) return '${(value / 1e3).toStringAsFixed(0)}K';
    return value.toStringAsFixed(magnitude < 10 ? 1 : 0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 62.0, right = 10.0, top = 12.0, bottom = 34.0;
    final width = math.max(1.0, size.width - left - right);
    final height = math.max(1.0, size.height - top - bottom);
    final finiteValues = <double>[
      for (final item in series)
        for (final value in item.values)
          if (value != null && value.isFinite) value,
    ];
    if (finiteValues.isEmpty) return;
    var low = math.min(0.0, finiteValues.reduce(math.min));
    var high = math.max(0.0, finiteValues.reduce(math.max));
    if ((high - low).abs() < 1e-9) high = low + 1;
    final range = high - low;
    double y(double value) => top + (high - value) / range * height;
    final zero = y(0);
    final gridPaint = Paint()..color = grid.withValues(alpha: .75);
    final groupWidth = width / periods.length;
    if (hovered case final index?) {
      canvas.drawRect(
        Rect.fromLTWH(left + index * groupWidth, top, groupWidth, height),
        Paint()..color = grid.withValues(alpha: .16),
      );
    }
    for (var tick = 0; tick <= 4; tick++) {
      final value = low + range * tick / 4;
      final dy = y(value);
      canvas.drawLine(
        Offset(left, dy),
        Offset(size.width - right, dy),
        gridPaint,
      );
      final label = axis(value);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: muted,
            fontSize: 10.5,
            fontFamilyFallback: kCjkFontFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 8);
      painter.paint(
        canvas,
        Offset(left - 8 - painter.width, dy - painter.height / 2),
      );
    }
    canvas.drawLine(
      Offset(left, zero),
      Offset(size.width - right, zero),
      Paint()..color = muted.withValues(alpha: .55),
    );
    final clusterWidth = groupWidth * .68;
    final barWidth = math.max(3.0, clusterWidth / math.max(1, series.length));
    for (var period = 0; period < periods.length; period++) {
      final start =
          left + period * groupWidth + (groupWidth - clusterWidth) / 2;
      for (var item = 0; item < series.length; item++) {
        final value = period < series[item].values.length
            ? series[item].values[period]
            : null;
        if (value == null || !value.isFinite) continue;
        final valueY = y(value);
        final rect = Rect.fromLTRB(
          start + item * barWidth + 1,
          math.min(zero, valueY),
          start + (item + 1) * barWidth - 1,
          math.max(zero, valueY),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = series[item].color.withValues(alpha: .94),
        );
      }
      final labelPainter = TextPainter(
        text: TextSpan(
          text: periods[period],
          style: TextStyle(
            color: muted,
            fontSize: 10.5,
            fontFamilyFallback: kCjkFontFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: groupWidth);
      labelPainter.paint(
        canvas,
        Offset(
          left + period * groupWidth + (groupWidth - labelPainter.width) / 2,
          size.height - bottom + 10,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResearchFinancialBarPainter oldDelegate) =>
      oldDelegate.periods != periods ||
      oldDelegate.series != series ||
      oldDelegate.hovered != hovered ||
      oldDelegate.grid != grid ||
      oldDelegate.muted != muted ||
      oldDelegate.language != language;
}

extension _InvestmentResearch on _InvestmentWorkspaceState {
  static const Color _emerald = Color(0xFF20C997);
  static const Color _amber = Color(0xFFF5A623);

  List<Map<String, dynamic>> get researchHistory =>
      researchDatedRows(asList(company?['history']), 'availableAt', asOf);

  bool get researchHasPlatformModel {
    final coverage = asMap(company?['coverage'])['platformModel'];
    if (coverage == 'available') return true;
    if (coverage != null) return false;
    return assumptions.isNotEmpty ||
        nullableNumber(asMap(company?['published'])['fairValue']) != null ||
        asList(asMap(company?['publishedBreakdown'])['components']).isNotEmpty;
  }

  bool get researchNeedsFullFinancials {
    final facts = researchFundamental;
    if (facts == null) return true;
    return asList(facts['annual']).isEmpty ||
        asMap(facts['transportCoverage'])['fullFacts'] == 'on_demand';
  }

  String _fmtMillions(dynamic rawM, String currency) =>
      formatCompactMoneyMillionsLocalized(rawM, currency, context.language);

  // ---------------------------------------------------------------------------
  // MAIN RESEARCH SHELL & EXECUTIVE COMPANY COCKPIT
  // ---------------------------------------------------------------------------

  List<Widget> refinedResearch() {
    if (company == null) return researchEntry();
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1100;
    final compact = width < 720;
    final pad = desktop ? 28.0 : (compact ? 14.0 : 18.0);
    final snap = asMap(company?['snapshot']);

    return [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, compact ? 6 : 14, pad, compact ? 8 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTopActionRow(desktop),
            SizedBox(height: compact ? 6 : 12),
            _buildExecutiveCompanyHero(snap),
          ],
        ),
      ),
      _buildPrimaryResearchTabs(pad),
      Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (section == 'evidence') ...researchOverview(),
            if (section == 'dividends') ...buildResearchDividendsHub(),
            if (section == 'financials') ..._buildFinancialsAndFilingsHub(snap),
            if (section == 'institutions') researchInstitutionPanel(),
            if (section == 'records') researchRecordsPanel(),
            if (section == 'decision') ...decisionPage(),
            if (section == 'review') ...comparisonPage(),
            const SizedBox(height: 14),
            label(
              'Research only · Historical financial facts & corporate actions · No orders are placed.',
              '仅供投研参考 · 基于已披露历史财报与除息公告 · 不执行交易',
              size: 11,
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildTopActionRow(bool desktop) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 12,
    runSpacing: 8,
    children: [
      sourceBreadcrumb(),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (desktop) dateControl(),
          OutlinedButton.icon(
            onPressed: () => changeResearchCompany(),
            icon: const Icon(Icons.search, size: 16),
            label: Text(w('Switch company', '切换公司')),
          ),
          researchWatchButton(),
        ],
      ),
    ],
  );

  Widget _buildExecutiveCompanyHero(Map<String, dynamic> snap) {
    final price = asMap(snap['price']);
    final meta = asMap(company?['companyMeta']);
    final factCompany = asMap(researchFundamental?['company']);
    final base = asMap(company?['base']);
    final divSum = asMap(researchDividendData?['summary']);
    final divPaying = researchDividendData?['status'] == 'paying';
    final currency = text(company?['currency'], 'USD');

    final marketPrice = nullableNumber(price['value']);
    final sectorText = text(
      meta['sector'],
      text(factCompany['sector'], text(factCompany['industry'])),
    );
    final mcapM = nullableNumber(meta['marketCapM']);
    final ttmRevM = nullableNumber(base['revenueM']);
    final ttmFcfM = nullableNumber(base['fcfM']);
    final divYield = nullableNumber(divSum['currentYield']);
    final annDps = nullableNumber(divSum['annualizedDps']);

    Widget heroMetric({
      required String titleEn,
      required String titleZh,
      required String mainValue,
      required String subText,
      Color? valueColor,
      Color? subColor,
      VoidCallback? onTap,
    }) {
      final box = Container(
        constraints: const BoxConstraints(minWidth: 142),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(titleEn, titleZh),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              mainValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: valueColor ?? p.text,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                letterSpacing: -.4,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subColor ?? p.muted,
                fontSize: 10.5,
                fontWeight: subColor != null ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      );
      if (onTap == null) return box;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: box,
      );
    }

    final isCompactScreen = MediaQuery.sizeOf(context).width < 720;

    return Container(
      key: const ValueKey('research-executive-hero'),
      padding: EdgeInsets.symmetric(
        horizontal: isCompactScreen ? 10 : 18,
        vertical: isCompactScreen ? 8 : 16,
      ),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: LayoutBuilder(
        builder: (_, c) {
          final identity = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              homeStockLogo(ticker, isCompactScreen ? 34 : 50),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(ticker, style: deskHeading(isCompactScreen ? 22 : 28)),
                        Text(
                          text(company?['name']),
                          style: TextStyle(
                            color: p.muted,
                            fontSize: isCompactScreen ? 13 : 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (!isCompactScreen && sectorText.isNotEmpty)
                          researchTag(context.ui(sectorText), p.accent),
                        researchTag(
                          '${text(snap['period'], '—')} · ${w('Filed', '披露')} ${text(snap['availableAt'], '—')} · $currency',
                          p.muted,
                        ),
                        if (isCompactScreen && marketPrice != null)
                          researchTag(
                            '${money(marketPrice)}${divPaying && divYield != null && divYield > 0 ? ' · ${w('Yield', '股息率')} ${(divYield * 100).toStringAsFixed(2)}%' : ''}',
                            p.accent,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );

          if (isCompactScreen) return identity;

          if (c.maxWidth < 920) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity,
                const SizedBox(height: 8),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${w('Price', '市价')} ${marketPrice == null ? '—' : money(marketPrice)}',
                      style: TextStyle(
                        color: p.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (divPaying && divYield != null && divYield > 0)
                      Text(
                        '${w('Dividend Yield', '股息率')} ${(divYield * 100).toStringAsFixed(2)}%',
                        style: const TextStyle(
                          color: _emerald,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ],
            );
          }

          final scoreboard = Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              heroMetric(
                titleEn: 'Market price',
                titleZh: '最新市价',
                mainValue: marketPrice == null ? '—' : money(marketPrice),
                subText: [
                  if (text(price['date']).isNotEmpty) text(price['date']),
                  if (mcapM != null)
                    '${w('Mkt cap', '市值')} ${_fmtMillions(mcapM, currency)}',
                ].join(' · '),
              ),
              if (ttmRevM != null || ttmFcfM != null)
                heroMetric(
                  titleEn: 'TTM Revenue',
                  titleZh: 'TTM 营业收入',
                  mainValue: ttmRevM != null
                      ? _fmtMillions(ttmRevM, currency)
                      : '—',
                  subText: ttmFcfM != null
                      ? 'TTM FCF ${_fmtMillions(ttmFcfM, currency)}'
                      : '${w('Period', '报告期')} ${text(snap['period'], '—')}',
                  valueColor: p.text,
                ),
              heroMetric(
                titleEn: 'Dividend yield (TTM)',
                titleZh: '股息率 (TTM)',
                mainValue: divPaying && divYield != null && divYield > 0
                    ? '${(divYield * 100).toStringAsFixed(2)}%'
                    : (researchDividendData == null ? '…' : '0.00%'),
                subText: divPaying && annDps != null && annDps > 0
                    ? '${w('Annual', '年派息')} \$${annDps.toStringAsFixed(annDps < 1 ? 3 : 2)}/${w('sh', '股')}'
                    : w('Click for payout history', '点击查看历史股息与派放'),
                valueColor: divPaying && (divYield ?? 0) > 0 ? _emerald : p.muted,
                onTap: () => selectResearchSection('dividends'),
              ),
            ],
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: identity),
              const SizedBox(width: 18),
              scoreboard,
            ],
          );
        },
      ),
    );
  }

  Widget _buildPrimaryResearchTabs(double pad) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final tabs = [
      (
        'evidence',
        'Financial statements',
        '财务报表',
        Icons.stacked_bar_chart_rounded,
      ),
      (
        'dividends',
        'Dividends & yield',
        '股息与派息',
        Icons.payments_outlined,
      ),
      (
        'financials',
        'Filings & calls',
        '财报与电话会',
        Icons.article_outlined,
      ),
      (
        'institutions',
        'Institutional 13F',
        '机构持仓',
        Icons.groups_2_outlined,
      ),
      ('records', 'Research notes', '研究笔记', Icons.fact_check_outlined),
    ];

    return Container(
      key: const ValueKey('research-primary-nav'),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: .6),
        border: Border(
          top: BorderSide(color: p.border.withValues(alpha: .5)),
          bottom: BorderSide(color: p.border),
        ),
      ),
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: compact
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tab in tabs)
                    Semantics(
                      selected: section == tab.$1,
                      child: Material(
                        color: section == tab.$1
                            ? const Color(0xFF252D3D)
                            : const Color(0xFF141923),
                        borderRadius: BorderRadius.circular(999),
                        child: InkWell(
                          key: ValueKey('research-tab-${tab.$1}'),
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => selectResearchSection(tab.$1),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 36),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: section == tab.$1
                                    ? p.accent.withValues(alpha: .45)
                                    : Colors.white.withValues(alpha: .05),
                              ),
                            ),
                            child: Text(
                              w(tab.$2, tab.$3),
                              style: TextStyle(
                                color: section == tab.$1 ? p.text : p.muted,
                                fontSize: 12,
                                fontWeight: section == tab.$1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          : Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                for (final tab in tabs)
                  Semantics(
                    selected: section == tab.$1,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: section == tab.$1
                                ? p.accent
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: TextButton.icon(
                        key: ValueKey('research-tab-${tab.$1}'),
                        style: TextButton.styleFrom(
                          foregroundColor: section == tab.$1 ? p.text : p.muted,
                          shape: const RoundedRectangleBorder(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                        ),
                        onPressed: () => selectResearchSection(tab.$1),
                        icon: Icon(
                          tab.$4,
                          size: 16,
                          color: section == tab.$1 ? p.accent : p.muted,
                        ),
                        label: Text(
                          w(tab.$2, tab.$3),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: section == tab.$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // SCREEN 0: EMPTY RESEARCH LAUNCHER (company == null)
  // ---------------------------------------------------------------------------

  List<Widget> researchEntry() {
    final watches = asList(home?['watches']);
    final decisions = asList(home?['decisions']);
    final notebook = asList(home?['researchNotebook']);

    return [
      title('Financial statements & dividends', '财务报表与股息研究'),
      label(
        'Explore dynamic multi-year financial statements, historical dividend yield channels, payout records, and 13F holdings.',
        '动态透视三大财务报表、历年股息率通道、除息派放记录与大师 13F 持仓。',
      ),
      const SizedBox(height: 20),
      card([
        if (busy) const LinearProgressIndicator(),
        if (ticker.isNotEmpty && !busy && error != null) ...[
          label(
            'Research could not be loaded for $ticker. Your selection is unchanged.',
            '$ticker 研究加载失败，所选股票未改变。',
            color: p.secondary,
          ),
          const SizedBox(height: 12),
        ],
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => changeResearchCompany(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.accent.withValues(alpha: .4)),
            ),
            child: Row(
              children: [
                Icon(Icons.search, color: p.accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    w(
                      'Search by company name or ticker across modeled & Fact OS universe...',
                      '按公司名称或股票代码快速检索全部可研究标的…',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ),
                researchTag(w('⌘K / Search', '⌘K / 搜索'), p.accent),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            searchBox(),
            button(
              'Explore research candidates',
              '浏览研究候选',
              () => requestNavigate('discover'),
              icon: Icons.explore_outlined,
            ),
          ],
        ),
        const SizedBox(height: 12),
        label(
          'Use a ticker directly, search by company name above, or pick from Discover to retain Guru & filing provenance.',
          '可直接输入股票代码、点击上方搜索框按公司名检索，或从发现页进入以保留投资大师与申报上下文。',
          size: 12,
        ),
      ]),
      card([
        Row(
          children: [
            Icon(Icons.bookmarks_outlined, size: 18, color: p.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                watches.isNotEmpty || researchRecentTickers.isNotEmpty
                    ? w('Watchlist & Quick Launch', '观察列表与快捷直达')
                    : w(
                        'Quick Launch: Statements & Dividend Leaders',
                        '快捷直达：代表性公司与高息股',
                      ),
                style: deskHeading(17),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final sym in {
              ...watches.map((wRow) => text(wRow['ticker'])),
              ...researchRecentTickers,
              'AAPL',
              'MSFT',
              'NVDA',
              'AVGO',
              'JNJ',
              'KO',
              'O',
              'AMZN',
            }.where((s) => s.isNotEmpty).take(12))
              ActionChip(
                avatar: StockLogo(ticker: sym, palette: p, size: 20),
                label: Text(
                  sym,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onPressed: () => loadCompany(sym),
              ),
          ],
        ),
      ]),
      if (decisions.isNotEmpty)
        card([
          title('Continue your research', '继续你的研究'),
          const SizedBox(height: 8),
          for (final d in decisions.take(6))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: homeStockLogo(text(d['ticker']), 32),
              title: Text(
                text(d['ticker']),
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                '${d['asOf']} · ${actionLabel(text(d['action']))}',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => loadCompany(text(d['ticker'])),
            ),
        ]),
      if (notebook.isNotEmpty)
        card([
          Row(
            key: const ValueKey('global-research-notebook'),
            children: [
              Icon(Icons.menu_book_outlined, size: 18, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w('My Research Notebook', '我的跨公司投研笔记本'),
                  style: deskHeading(17),
                ),
              ),
              researchTag('${notebook.length}', p.accent),
            ],
          ),
          const SizedBox(height: 10),
          for (final n in notebook.take(10))
            ListTile(
              key: ValueKey('notebook-row-${text(n['id'])}'),
              contentPadding: EdgeInsets.zero,
              leading: homeStockLogo(text(n['ticker']), 30),
              title: Text(
                '${text(n['ticker'])} · ${text(n['question'])}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              subtitle: Text(
                [
                  text(n['asOf']),
                  _recordStatusLabel(text(n['status'], 'open')),
                  if (text(n['reviewDate']).isNotEmpty)
                    '${w('Review', '复核')} ${text(n['reviewDate'])}',
                  if (asList(n['tags']).isNotEmpty)
                    (n['tags'] as List).take(3).map((t) => '#$t').join(' '),
                ].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(
                loadCompany(text(n['ticker']), initialSection: 'records'),
              ),
            ),
        ]),
    ];
  }

  // ---------------------------------------------------------------------------
  // NAVIGATION & LAZY PANEL LOADERS
  // ---------------------------------------------------------------------------

  Future<void> openGlobalCompanySearch() async {
    if (page == 'research' && !await allowLeaveDraft()) return;
    if (!mounted) return;
    await changeResearchCompany(forceNavigate: true);
  }

  Future<void> changeResearchCompany({bool forceNavigate = false}) async {
    final selected = await showDialog<String>(
      context: context,
      barrierLabel: w('Close search', '关闭搜索'),
      barrierColor: Colors.black.withValues(alpha: .55),
      builder: (ctx) => CompanySearchDialog(
        api: widget.api,
        palette: p,
        asOf: asOf,
        currentTicker: ticker,
        recentTickers: researchRecentTickers,
      ),
    );
    if (selected != null &&
        (forceNavigate ||
            selected != ticker ||
            page != 'research' ||
            company == null) &&
        mounted) {
      await loadCompany(selected);
    }
  }

  void selectResearchSection(String next) {
    final target = next == 'value' ? 'evidence' : next;
    selectSection(target);
    if (target == 'evidence' && researchNeedsFullFinancials) {
      unawaited(loadResearchOverviewFinancials());
    } else if (target == 'dividends' && researchDividendData == null) {
      unawaited(loadResearchDividends());
    } else if (target == 'financials' &&
        (researchDocumentsData == null || researchFundamental == null)) {
      unawaited(loadResearchPanel('financials'));
    } else if (target == 'institutions' && researchInstitution == null) {
      unawaited(loadResearchPanel('institutions'));
    } else if (target == 'records' && researchRecordsData == null) {
      unawaited(loadResearchPanel('records'));
    }
  }

  Future<void> loadResearchOverviewFinancials() async {
    if (researchFinancialsLoading || ticker.isEmpty) return;
    final symbol = ticker, cutoff = asOf, serial = requestSerial;
    final cached = _researchFundamentalsCache[widget.api]?['$symbol|$cutoff'];
    if (cached != null) {
      updateUI(() {
        researchFundamental = cached;
        researchFinancialsLoading = false;
        researchFinancialsError = null;
      });
      return;
    }
    updateUI(() {
      researchFinancialsLoading = true;
      researchFinancialsError = null;
    });
    try {
      final value = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(symbol)}/fundamentals?asOf=$cutoff',
      );
      if (!mounted || serial != requestSerial || ticker != symbol) return;
      final store = _researchFundamentalsCache[widget.api] ??=
          <String, Map<String, dynamic>>{};
      if (store.length >= 24) store.remove(store.keys.first);
      store['$symbol|$cutoff'] = value;
      updateUI(() => researchFundamental = value);
    } catch (e) {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchFinancialsError = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchFinancialsLoading = false);
      }
    }
  }

  Future<void> loadResearchPanel(String panel) async {
    if (researchPanelLoading || ticker.isEmpty) return;
    final symbol = ticker, cutoff = asOf, serial = requestSerial;
    updateUI(() {
      researchPanelLoading = true;
      researchPanelError = null;
    });
    try {
      if (panel == 'financials') {
        if (researchNeedsFullFinancials) {
          unawaited(loadResearchOverviewFinancials());
        }
        final documents = await widget.api.getJson(
          '/api/investment/research/${Uri.encodeComponent(symbol)}/documents?asOf=$cutoff',
        );
        if (!mounted || serial != requestSerial) return;
        updateUI(() => researchDocumentsData = documents);
      } else if (panel == 'institutions') {
        final value = await widget.api.getJson(
          '/api/investment/research/${Uri.encodeComponent(symbol)}/institutions?asOf=$cutoff',
        );
        if (!mounted || serial != requestSerial) return;
        updateUI(() => researchInstitution = value);
      } else if (panel == 'records') {
        final value = await widget.api.getJson(
          '/api/investment/research/${Uri.encodeComponent(symbol)}/records?asOf=$cutoff',
        );
        if (!mounted || serial != requestSerial) return;
        updateUI(() => researchRecordsData = value);
      }
    } catch (e) {
      if (mounted && serial == requestSerial) {
        updateUI(() => researchPanelError = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial) {
        updateUI(() => researchPanelLoading = false);
      }
    }
  }

  Widget researchPanelState() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (researchPanelLoading) const LinearProgressIndicator(),
      if (researchPanelError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: label(
            'This research layer could not be loaded. Existing evidence remains visible.',
            '这一研究层暂时无法载入，已有证据仍然保留显示。',
            color: p.secondary,
          ),
        ),
      if (researchPanelError != null && !researchPanelLoading)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('research-layer-retry'),
            onPressed: () => loadResearchPanel(section),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(w('Retry this section', '重试这一研究层')),
          ),
        ),
    ],
  );

  Widget researchEvidenceSidebar() {
    final dates = asMap(company?['researchDates']);
    return card([
      Row(
        children: [
          Icon(Icons.verified_outlined, size: 15, color: p.accent),
          const SizedBox(width: 6),
          Expanded(
            child: label('POINT-IN-TIME SNAPSHOT', '时点证据对齐', size: 10, color: p.accent),
          ),
        ],
      ),
      const SizedBox(height: 12),
      for (final item in [
        ('Research cutoff', '研究截止日', dates['cutoff'] ?? asOf),
        ('Financial period', '财报所属期', dates['financialPeriod']),
        ('Disclosure date', '公开披露日', dates['disclosureDate']),
        ('Price date', '市价日期', dates['priceDate']),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              Expanded(child: label(item.$1, item.$2, size: 11.5)),
              Text(
                text(item.$3, '—'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      Divider(color: p.border),
      label(
        'As-reported financial statements, dividend corporate actions, 13F filings, and personal notes aligned to $asOf.',
        '原始披露财务报表、历年股息除息公告、13F 机构持仓与个人研究笔记均严格对齐至 $asOf。',
        size: 11,
      ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // TAB 1: RESEARCH OVERVIEW (EXECUTIVE DASHBOARD)
  // ---------------------------------------------------------------------------

  List<Widget> researchOverview() {
    final pulse = _buildGuruAndGuidancePulse();
    final insights = _buildSynthesizedFactInsights();
    final divBanner = buildCompactDividendPulseBanner();
    final kpis = _buildCoreOperatingKpiStrip();
    return [
      researchFinancialStatements(),
      if (divBanner != null) ...[const SizedBox(height: 16), divBanner],
      if (asList(company?['metrics']).isNotEmpty) ...[
        const SizedBox(height: 16),
        kpis,
      ],
      if (insights != null) ...[const SizedBox(height: 16), insights],
      if (pulse != null) ...[const SizedBox(height: 16), pulse],
    ];
  }

  Widget _buildCoreOperatingKpiStrip() {
    final metrics = asList(company?['metrics']);
    if (metrics.isEmpty) return const SizedBox.shrink();
    final base = asMap(company?['base']);
    final currency = text(company?['currency'], 'USD');
    final qualityYears = asList(company?['qualityAnnual']);
    final latestQuality = qualityYears.firstOrNull;
    final latestRoic = nullableNumber(latestQuality?['roic']);

    Map<String, dynamic>? byKey(String k) =>
        metrics.where((m) => m['key'] == k).firstOrNull;

    final revM = byKey('revenueGrowth');
    final opM = byKey('operatingMargin');
    final fcfM = byKey('fcfMargin');
    final capexM = byKey('capexIntensity');

    Widget kpiCard({
      required IconData icon,
      required String titleEn,
      required String titleZh,
      required String primary,
      required String subLine,
      Color? deltaColor,
      double? percentileVal,
    }) => Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  w(titleEn, titleZh),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            primary,
            style: TextStyle(
              color: p.text,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: deltaColor ?? p.muted,
              fontSize: 11,
              height: 1.3,
            ),
          ),
          if (percentileVal != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: percentileVal.clamp(0.0, 1.0),
                minHeight: 4,
                color: p.accent,
                backgroundColor: p.border,
              ),
            ),
          ],
        ],
      ),
    );

    String fmtDelta(Map<String, dynamic>? m, {String? prefix}) {
      if (m == null) return '—';
      final chg = nullableNumber(m['change']);
      final pctTile = nullableNumber(m['historicalPercentile']);
      final parts = <String>[
        if (prefix != null && prefix != '—') prefix,
        if (chg != null)
          '${chg >= 0 ? '+' : ''}${(chg * 100).toStringAsFixed(1)} pp ${w('vs prior', '环比上期')}',
        if (pctTile != null) '${w('Hist', '分位')} ${pct(pctTile)}',
      ];
      return parts.isEmpty ? text(m['period'], '—') : parts.join(' · ');
    }

    Color? deltaTone(Map<String, dynamic>? m, {bool invert = false}) {
      final chg = nullableNumber(m?['change']);
      if (chg == null || chg.abs() < 0.001) return null;
      final good = invert ? chg < 0 : chg > 0;
      return good ? _emerald : _amber;
    }

    final cards = [
      if (revM != null)
        kpiCard(
          icon: Icons.trending_up,
          titleEn: 'Revenue Growth (YoY)',
          titleZh: '单季营收同比增速',
          primary: pct(revM['value']),
          subLine: fmtDelta(
            revM,
            prefix: base['revenueM'] != null
                ? 'TTM ${_fmtMillions(base['revenueM'], currency)}'
                : null,
          ),
          deltaColor: deltaTone(revM),
          percentileVal: nullableNumber(revM['historicalPercentile']),
        ),
      if (opM != null)
        kpiCard(
          icon: Icons.analytics_outlined,
          titleEn: 'Operating Margin (TTM)',
          titleZh: '营业利润率 (TTM)',
          primary: pct(opM['value']),
          subLine: fmtDelta(
            opM,
            prefix: base['operatingIncomeM'] != null
                ? _fmtMillions(base['operatingIncomeM'], currency)
                : null,
          ),
          deltaColor: deltaTone(opM),
          percentileVal: nullableNumber(opM['historicalPercentile']),
        ),
      if (fcfM != null)
        kpiCard(
          icon: Icons.water_drop_outlined,
          titleEn: 'Free Cash Flow Margin',
          titleZh: '自由现金流利润率 (TTM)',
          primary: pct(fcfM['value']),
          subLine: fmtDelta(
            fcfM,
            prefix: base['fcfM'] != null
                ? _fmtMillions(base['fcfM'], currency)
                : null,
          ),
          deltaColor: deltaTone(fcfM),
          percentileVal: nullableNumber(fcfM['historicalPercentile']),
        ),
      if (capexM != null || latestRoic != null)
        kpiCard(
          icon: Icons.bolt_outlined,
          titleEn: latestRoic != null
              ? 'ROIC & Capex Intensity'
              : 'Capex Intensity (TTM)',
          titleZh: latestRoic != null ? '投入资本回报率与资本开支' : '资本开支强度 (TTM)',
          primary: latestRoic != null ? pct(latestRoic) : pct(capexM?['value']),
          subLine: latestRoic != null
              ? 'FY${latestQuality?['year']} ROIC · ${w('Capex/Rev', '资本开支率')} ${pct(capexM?['value'])}'
              : fmtDelta(
                  capexM,
                  prefix: base['capexM'] != null
                      ? _fmtMillions(base['capexM'], currency)
                      : null,
                ),
          deltaColor: latestRoic != null
              ? (latestRoic >= 0.15 ? _emerald : p.muted)
              : deltaTone(capexM, invert: true),
          percentileVal: nullableNumber(capexM?['historicalPercentile']),
        ),
    ];

    if (cards.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      key: const ValueKey('research-overview-kpis'),
      builder: (_, bounds) {
        final cols = bounds.maxWidth >= 980
            ? cards.length
            : (bounds.maxWidth >= 560 ? 2 : 1);
        final wTile = (bounds.maxWidth - (cols - 1) * 12) / cols;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in cards) SizedBox(width: wTile, child: c),
          ],
        );
      },
    );
  }

  Widget? _buildSynthesizedFactInsights() {
    final fact = researchFundamental;
    final judgment = asMap(fact?['judgment']);
    final counter = asMap(fact?['counterEvidence']);
    final changes = asList(fact?['importantChanges']);
    if (judgment.isEmpty && changes.isEmpty) return null;

    final langKey = context.language == AppLanguage.zh ? 'zh' : 'en';
    String trMap(dynamic v) => text(asMap(v)[langKey], text(v));
    final summaryText = trMap(judgment['summary']);
    final counterText = trMap(counter['statement']);
    if (summaryText.isEmpty && changes.isEmpty) return null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.accent.withValues(alpha: .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, size: 17, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w('Core Fundamental Diagnosis', '核心基本面诊断洞察'),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (summaryText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              summaryText,
              style: TextStyle(
                color: p.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ],
          if (changes.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final chg in changes.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Icon(
                        Icons.check_circle_outline,
                        size: 14,
                        color: _emerald,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          trMap(chg['summary']),
                          if ((chg['evidence'] is List) &&
                              (chg['evidence'] as List).isNotEmpty)
                            (chg['evidence'] as List)
                                .map(
                                  (e) => localizeMetricEvidenceKey(
                                    text(e),
                                    context.language,
                                  ),
                                )
                                .join(' · '),
                        ].where((s) => s.isNotEmpty).join(' — '),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (counterText.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: _amber.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _amber.withValues(alpha: .28)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: _amber,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${w('Key Risk / Gap', '关键反证与关注点')}: $counterText',
                      style: TextStyle(
                        color: p.text,
                        fontSize: 12,
                        height: 1.35,
                      ),
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

  Widget? _buildGuruAndGuidancePulse() {
    final holders = orderedDisclosedHolders(asList(company?['provenance']), '');
    final guidance = asList(asMap(company?['guidance'])['evidence']);
    if (holders.isEmpty && guidance.isEmpty) return null;

    Widget? guruCard;
    if (holders.isNotEmpty) {
      guruCard = card([
        Row(
          children: [
            Icon(Icons.groups_2_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w(
                  'Tracked Superinvestor Holders (${holders.length})',
                  '跟踪投资大师持仓动向（${holders.length} 家）',
                ),
                style: deskHeading(15.5),
              ),
            ),
            TextButton(
              onPressed: () => selectResearchSection('institutions'),
              child: Text(w('All 13F data →', '全市场 13F →')),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final g in holders.take(4))
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => unawaited(openHolderGuru(g)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  holderAvatar(g, 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(g['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${w('Period', '报告期')} ${text(g['reportDate'])} · ${w('Filed', '披露')} ${text(g['availableAt'])}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  if (nullableNumber(g['weight']) != null)
                    researchTag(
                      '${w('Book', '占组合')} ${pct(g['weight'])}',
                      p.accent,
                    ),
                ],
              ),
            ),
          ),
      ]);
    }

    Widget? guidanceCard;
    if (guidance.isNotEmpty) {
      guidanceCard = card([
        Row(
          children: [
            const Icon(Icons.record_voice_over_outlined, size: 17, color: _emerald),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w('Management Guidance & Commentary', '管理层核心指引摘录'),
                style: deskHeading(15.5),
              ),
            ),
            TextButton(
              onPressed: () => selectResearchSection('financials'),
              child: Text(w('Earnings Q&A →', '财报会与问答 →')),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final e in guidance.take(2))
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: p.accent.withValues(alpha: .55), width: 2.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cleanTranscriptMojibake(
                    text(e['excerpt'], text(e['quote'])),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 4),
                Text(
                  [text(e['speaker']), text(e['observedAt'])]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
              ],
            ),
          ),
      ]);
    }

    if (guruCard != null && guidanceCard != null) {
      return LayoutBuilder(
        builder: (_, c) {
          if (c.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: guruCard!),
                const SizedBox(width: 16),
                Expanded(child: guidanceCard!),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [guruCard!, const SizedBox(height: 16), guidanceCard!],
          );
        },
      );
    }
    return guruCard ?? guidanceCard;
  }

  // ---------------------------------------------------------------------------
  // THREE-STATEMENT INTERACTIVE CHART & TABLE
  // ---------------------------------------------------------------------------

  List<({String key, String en, String zh, String unit})>
  get _researchStatementRows => switch (researchStatement) {
    'balance' => [
      (
        key: 'cashneq',
        en: 'Cash & equivalents',
        zh: '现金及等价物',
        unit: 'currency',
      ),
      (key: 'receivables', en: 'Receivables', zh: '应收款项', unit: 'currency'),
      (key: 'inventory', en: 'Inventory', zh: '存货', unit: 'currency'),
      (key: 'assetsc', en: 'Current assets', zh: '流动资产', unit: 'currency'),
      (
        key: 'ppnenet',
        en: 'Net property, plant & equipment',
        zh: '物业厂房设备净额',
        unit: 'currency',
      ),
      (
        key: 'intangibles',
        en: 'Intangible assets',
        zh: '无形资产',
        unit: 'currency',
      ),
      (key: 'assets', en: 'Total assets', zh: '总资产', unit: 'currency'),
      (key: 'payables', en: 'Payables', zh: '应付款项', unit: 'currency'),
      (
        key: 'liabilitiesc',
        en: 'Current liabilities',
        zh: '流动负债',
        unit: 'currency',
      ),
      (key: 'debt', en: 'Total debt', zh: '总债务', unit: 'currency'),
      (
        key: 'liabilities',
        en: 'Total liabilities',
        zh: '总负债',
        unit: 'currency',
      ),
      (key: 'equity', en: 'Shareholders’ equity', zh: '股东权益', unit: 'currency'),
      (
        key: 'workingcapital',
        en: 'Working capital',
        zh: '营运资本',
        unit: 'currency',
      ),
      (key: 'invcap', en: 'Invested capital', zh: '投入资本', unit: 'currency'),
      (key: 'deposits', en: 'Deposits', zh: '存款', unit: 'currency'),
    ],
    'cash' => [
      (
        key: 'ncfo',
        en: 'Cash from operations',
        zh: '经营活动现金流',
        unit: 'currency',
      ),
      (key: 'capex', en: 'Capital expenditure', zh: '资本支出', unit: 'currency'),
      (key: 'fcf', en: 'Free cash flow', zh: '自由现金流', unit: 'currency'),
      (key: 'ncfi', en: 'Cash from investing', zh: '投资活动现金流', unit: 'currency'),
      (key: 'ncff', en: 'Cash from financing', zh: '融资活动现金流', unit: 'currency'),
      (
        key: 'sbcomp',
        en: 'Stock-based compensation',
        zh: '股权激励',
        unit: 'currency',
      ),
      (
        key: 'ncfcommon',
        en: 'Net common stock financing',
        zh: '普通股净融资',
        unit: 'currency',
      ),
      (key: 'ncfdebt', en: 'Net debt financing', zh: '债务净融资', unit: 'currency'),
      (key: 'ncfdiv', en: 'Cash dividends', zh: '现金股息', unit: 'currency'),
      (
        key: 'depamor',
        en: 'Depreciation & amortization',
        zh: '折旧与摊销',
        unit: 'currency',
      ),
      (key: 'ncf', en: 'Net change in cash', zh: '现金净变动', unit: 'currency'),
    ],
    'ratios' => [
      (
        key: 'grossmargin_calc',
        en: 'Gross margin',
        zh: '毛利率',
        unit: 'percent',
      ),
      (
        key: 'opmargin_calc',
        en: 'Operating margin',
        zh: '营业利润率',
        unit: 'percent',
      ),
      (
        key: 'ebitdamargin_calc',
        en: 'EBITDA margin',
        zh: 'EBITDA 利润率',
        unit: 'percent',
      ),
      (
        key: 'netmargin_calc',
        en: 'Net profit margin',
        zh: '净利率',
        unit: 'percent',
      ),
      (
        key: 'fcfmargin_calc',
        en: 'Free cash flow margin',
        zh: '自由现金流利润率',
        unit: 'percent',
      ),
      (key: 'roe', en: 'Return on equity (ROE)', zh: '净资产收益率 (ROE)', unit: 'percent'),
      (key: 'roa', en: 'Return on assets (ROA)', zh: '总资产回报率 (ROA)', unit: 'percent'),
      (key: 'roic', en: 'Return on invested capital (ROIC)', zh: '投入资本回报率 (ROIC)', unit: 'percent'),
      (key: 'de_calc', en: 'Debt / Equity', zh: '资产负债比 (Debt/Equity)', unit: 'multiple'),
      (key: 'currentratio_calc', en: 'Current ratio', zh: '流动比率', unit: 'multiple'),
    ],
    _ => [
      (key: 'revenue', en: 'Revenue', zh: '营业收入', unit: 'currency'),
      (key: 'cor', en: 'Cost of revenue', zh: '营业成本', unit: 'currency'),
      (key: 'gp', en: 'Gross profit', zh: '毛利润', unit: 'currency'),
      (key: 'rnd', en: 'Research & development', zh: '研发费用', unit: 'currency'),
      (
        key: 'sgna',
        en: 'Selling, general & administrative',
        zh: '销售及管理费用',
        unit: 'currency',
      ),
      (key: 'opex', en: 'Operating expenses', zh: '经营费用', unit: 'currency'),
      (key: 'opinc', en: 'Operating income', zh: '营业利润', unit: 'currency'),
      (key: 'ebitda', en: 'EBITDA', zh: 'EBITDA', unit: 'currency'),
      (key: 'ebit', en: 'EBIT', zh: '息税前利润', unit: 'currency'),
      (key: 'intexp', en: 'Interest expense', zh: '利息费用', unit: 'currency'),
      (key: 'taxexp', en: 'Income tax expense', zh: '所得税费用', unit: 'currency'),
      (key: 'netinc', en: 'Net income', zh: '净利润', unit: 'currency'),
      (
        key: 'netinccmn',
        en: 'Net income to common',
        zh: '归属普通股净利润',
        unit: 'currency',
      ),
      (key: 'epsdil', en: 'Diluted EPS', zh: '稀释每股收益 (EPS)', unit: 'per_share'),
      (
        key: 'shareswadil',
        en: 'Diluted weighted-average shares',
        zh: '摊薄加权平均股数',
        unit: 'shares',
      ),
      (key: 'dps', en: 'Dividends per share', zh: '每股股息', unit: 'per_share'),
    ],
  };

  List<Map<String, dynamic>> _researchFinancialPeriods() {
    final annual = asList(researchFundamental?['annual']);
    final quarters = asList(researchFundamental?['quarterly']);
    Map<String, dynamic>? prior(
      Map<String, dynamic> row,
      List<Map<String, dynamic>> rows,
      int offset,
    ) {
      final found = researchFinancialPrior(row, rows, offset);
      return found == null ? null : {'row': found};
    }

    final qCap = researchFinancialMaxPeriods <= 5 ? 8 : 16;
    final aCap = researchFinancialMaxPeriods <= 5 ? 5 : 10;

    if (researchFinancialFrequency == 'quarterly') {
      return [
        for (final row in quarters.take(qCap).toList().reversed)
          {
            'label': researchFinancialQuarterLabel(row),
            'kind': 'quarterly',
            'row': row,
            'yoy': prior(row, quarters, 4),
            'qoq': prior(row, quarters, 1),
          },
      ];
    }
    final periods = <Map<String, dynamic>>[
      for (final row in annual.take(aCap).toList().reversed)
        {
          'label': text(
            row['reportperiod'],
            text(row['period_end']),
          ).split('-').first,
          'kind': 'annual',
          'row': row,
          'yoy': prior(row, annual, 4),
        },
    ];
    if (quarters.isNotEmpty) {
      final latest = quarters.first;
      final previousYear = researchFinancialPrior(latest, quarters, 4);
      final isPointInTime = researchStatement == 'balance';
      periods.add({
        'label': isPointInTime ? w('Latest', '最新') : 'TTM',
        'kind': isPointInTime ? 'latest' : 'ttm',
        'row': latest,
        'rows': quarters.take(4).toList(),
        'yoy': previousYear == null
            ? null
            : {
                'kind': isPointInTime ? 'latest' : 'ttm',
                'row': previousYear,
                'rows': quarters
                    .skip(quarters.indexOf(previousYear))
                    .take(4)
                    .toList(),
              },
        'qoq': isPointInTime ? prior(latest, quarters, 1) : null,
      });
    }
    return periods;
  }

  double? _researchFinancialValue(Map<String, dynamic> period, String key) {
    return researchFinancialReportedValue(period, key);
  }

  void _selectResearchStatement(String statement) {
    final defaults = switch (statement) {
      'balance' => ['cashneq', 'debt', 'equity'],
      'cash' => ['ncfo', 'capex', 'fcf'],
      'ratios' => ['grossmargin_calc', 'opmargin_calc', 'fcfmargin_calc'],
      _ => ['revenue', 'opinc', 'netinccmn'],
    };
    updateUI(() {
      researchStatement = statement;
      researchFinancialMetrics = defaults;
    });
  }

  void _toggleResearchFinancialMetric(String key, String unit) {
    updateUI(() {
      final selected = [...researchFinancialMetrics];
      if (selected.contains(key)) {
        if (selected.length > 1) selected.remove(key);
      } else {
        final definitions = {
          for (final row in _researchStatementRows) row.key: row,
        };
        final currentUnit = selected.isEmpty
            ? unit
            : definitions[selected.first]?.unit;
        if (currentUnit != unit) selected.clear();
        if (selected.length >= 3) selected.removeAt(0);
        selected.add(key);
      }
      researchFinancialMetrics = selected;
    });
  }

  Widget researchFinancialStatements() {
    final periods = _researchFinancialPeriods();
    final definitions = _researchStatementRows;
    final definitionByKey = {for (final row in definitions) row.key: row};
    final colors = [p.accent, _emerald, _amber];
    final selected = [
      for (var index = 0; index < researchFinancialMetrics.length; index++)
        if (definitionByKey[researchFinancialMetrics[index]] case final row?)
          _ResearchFinancialSeries(
            keyName: row.key,
            label: w(row.en, row.zh),
            unit: row.unit,
            color: colors[index % colors.length],
            values: [
              for (final period in periods)
                _researchFinancialValue(period, row.key),
            ],
            yoy: [
              for (final period in periods)
                researchFinancialGrowth(period, row.key, 'yoy', unit: row.unit),
            ],
            qoq: [
              for (final period in periods)
                researchFinancialGrowth(period, row.key, 'qoq', unit: row.unit),
            ],
          ),
    ];
    return card([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label(
                'DYNAMIC FINANCIAL STATEMENTS',
                '三大财务报表与核心比率动态透视',
                size: 10,
                color: p.accent,
              ),
              const SizedBox(height: 4),
              Text(
                w('Interactive Multi-Period Statements & Ratios', '动态财务报表：图表联动与多期对比'),
                style: deskHeading(20),
              ),
              const SizedBox(height: 3),
              label(
                'Click up to 3 table rows below to compare trends dynamically. Hover or tap bars for exact YoY & QoQ.',
                '点击下方表格任意项目（最多叠加 3 项）实时联动绘图；悬停或点击柱体查看精确同比 YoY 与环比 QoQ。',
                size: 11.5,
              ),
            ],
          ),
          researchTag(
            '${w('As-reported', '原始财报口径')} · ${text(company?['currency'], 'USD')}',
            p.muted,
          ),
        ],
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final statement in [
            ('income', 'Income statement', '利润表'),
            ('balance', 'Balance sheet', '资产负债表'),
            ('cash', 'Cash flow', '现金流量表'),
            ('ratios', 'Margins & returns', '利润率与回报'),
          ])
            ChoiceChip(
              key: ValueKey('research-statement-${statement.$1}'),
              label: Text(w(statement.$2, statement.$3)),
              selected: researchStatement == statement.$1,
              onSelected: (_) => _selectResearchStatement(statement.$1),
            ),
          const SizedBox(width: 6),
          for (final frequency in [
            ('annual', 'Annual · TTM', '年度 · TTM'),
            ('quarterly', 'Quarterly · Q', '季度 · Q'),
          ])
            ChoiceChip(
              key: ValueKey('research-frequency-${frequency.$1}'),
              label: Text(w(frequency.$2, frequency.$3)),
              selected: researchFinancialFrequency == frequency.$1,
              onSelected: (_) =>
                  updateUI(() => researchFinancialFrequency = frequency.$1),
            ),
          ChoiceChip(
            key: const ValueKey('research-depth-compact'),
            label: Text(
              researchFinancialFrequency == 'quarterly'
                  ? w('8Q', '近8季')
                  : w('5Y', '近5年'),
            ),
            selected: researchFinancialMaxPeriods <= 5,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => updateUI(() => researchFinancialMaxPeriods = 5),
          ),
          ChoiceChip(
            key: const ValueKey('research-depth-full'),
            label: Text(
              researchFinancialFrequency == 'quarterly'
                  ? w('16Q', '近16季')
                  : w('10Y', '近10年'),
            ),
            selected: researchFinancialMaxPeriods > 5,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => updateUI(() => researchFinancialMaxPeriods = 10),
          ),
          FilterChip(
            key: const ValueKey('research-table-yoy-toggle'),
            label: Text(w('Show YoY %', '显示同比')),
            selected: researchFinancialShowGrowthInTable,
            visualDensity: VisualDensity.compact,
            onSelected: (v) =>
                updateUI(() => researchFinancialShowGrowthInTable = v),
          ),
        ],
      ),
      const SizedBox(height: 14),
      if (researchFinancialsLoading) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 10),
        label('Loading reported statements…', '正在载入已报告财务报表…', size: 11),
      ] else if (researchFinancialsError != null)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: label(
            'The statement history could not be loaded. No values are substituted.',
            '财务报表历史暂时无法载入；系统不会填入替代数值。',
            color: p.secondary,
          ),
        )
      else if (periods.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: label(
            'No corporate statement history is filed for this security (e.g. ETF/Fund). Check the Dividends & Yield tab for distribution analytics.',
            '该标的暂无企业三张财务报表（例如 ETF/基金）；可切换至「股息与派息」查看完整历史股息率与派息记录。',
          ),
        )
      else ...[
        Container(
          key: const ValueKey('research-financial-chart'),
          height: MediaQuery.sizeOf(context).width < 600 ? 320 : 330,
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: _ResearchFinancialBarChart(
            periods: [for (final period in periods) text(period['label'])],
            details: [
              for (final period in periods)
                '${w('Period end', '报告期末')} ${text(asMap(period['row'])['reportperiod'], '—')} · ${w('Disclosed', '披露')} ${text(asMap(period['row'])['date'], '—')}',
            ],
            series: selected,
            muted: p.muted,
            textColor: p.text,
            grid: p.border,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          w(
            'Tap any line item below to plot or remove it from the chart above.',
            '点击下方任意报表项目，即可在上方图表中叠加或移除对比。',
          ),
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: ValueKey('research-financial-table-$researchStatement'),
            showCheckboxColumn: false,
            headingRowHeight: 40,
            dataRowMinHeight: researchFinancialShowGrowthInTable ? 50 : 44,
            dataRowMaxHeight: researchFinancialShowGrowthInTable ? 56 : 48,
            columns: [
              DataColumn(label: Text(w('Reported line item', '报表项目'))),
              for (final period in periods)
                DataColumn(label: Text(text(period['label'])), numeric: true),
            ],
            rows: [
              for (final row in definitions)
                DataRow(
                  selected: researchFinancialMetrics.contains(row.key),
                  onSelectChanged: (_) =>
                      _toggleResearchFinancialMetric(row.key, row.unit),
                  cells: [
                    DataCell(
                      Row(
                        key: ValueKey('research-financial-row-${row.key}'),
                        children: [
                          Container(
                            width: 4,
                            height: 26,
                            decoration: BoxDecoration(
                              color: researchFinancialMetrics.contains(row.key)
                                  ? selected
                                            .where(
                                              (series) =>
                                                  series.keyName == row.key,
                                            )
                                            .map((series) => series.color)
                                            .firstOrNull ??
                                        p.accent
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Icon(
                            researchFinancialMetrics.contains(row.key)
                                ? Icons.bar_chart_rounded
                                : Icons.add_chart_outlined,
                            size: 15,
                            color: researchFinancialMetrics.contains(row.key)
                                ? p.accent
                                : p.muted.withValues(alpha: .65),
                          ),
                          const SizedBox(width: 7),
                          SizedBox(
                            width: 210,
                            child: Text(
                              w(row.en, row.zh),
                              style: TextStyle(
                                fontWeight:
                                    researchFinancialMetrics.contains(row.key)
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final period in periods)
                      _buildStatementDataCell(period, row),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        label(
          'As-reported issuer currency figures (${text(company?['currency'], 'USD')}) visible by $asOf. Missing periods remain blank and are never zero-filled.',
          '截至 $asOf 可见的发行人原始财报币种数值（${text(company?['currency'], 'USD')}）；缺失期间保持留空，绝不补零。',
          size: 10.5,
        ),
      ],
    ]);
  }

  DataCell _buildStatementDataCell(
    Map<String, dynamic> period,
    ({String key, String en, String zh, String unit}) row,
  ) {
    final val = _researchFinancialValue(period, row.key);
    final yoy = researchFinancialShowGrowthInTable
        ? researchFinancialGrowth(period, row.key, 'yoy', unit: row.unit)
        : (value: null, reason: 'hidden');
    return DataCell(
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            val == null ? '—' : formatResearchStatementUnitValue(val, row.unit),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (yoy.value != null)
            Text(
              yoy.reason == 'pp_delta'
                  ? '${yoy.value! >= 0 ? '+' : ''}${(yoy.value! * 100).toStringAsFixed(1)}pp'
                  : '${yoy.value! >= 0 ? '+' : ''}${(yoy.value! * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 10.5,
                color: yoy.value! >= 0 ? _emerald : _amber,
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 2: ANNOUNCEMENTS, EARNINGS CALLS, INSIDERS & FILINGS HUB
  // ---------------------------------------------------------------------------

  List<Widget> _buildFinancialsAndFilingsHub(Map<String, dynamic> snap) {
    final focusOptions = [
      ('all', 'All sections', '全部视图'),
      ('earnings', 'Quarterly Calls & Q&A', '财报会与问答'),
      ('filings', 'Filings & Financial Ratios', '披露目录与财务诊断'),
      ('insiders', 'Insider Activity', '内部人交易'),
      ('holders', 'Guru 13F Claims', '大师 13F 申报'),
    ];
    final activeFocus = focusOptions.any((o) => o.$1 == researchFinancialsFocus)
        ? researchFinancialsFocus
        : 'all';

    return [
      Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.border),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.filter_list_rounded, size: 16, color: p.muted),
            Text(
              w('Focus view:', '聚焦模块：'),
              style: TextStyle(
                color: p.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            for (final opt in focusOptions)
              ChoiceChip(
                label: Text(
                  w(opt.$2, opt.$3),
                  style: const TextStyle(fontSize: 12),
                ),
                selected: activeFocus == opt.$1,
                visualDensity: VisualDensity.compact,
                onSelected: (_) =>
                    updateUI(() => researchFinancialsFocus = opt.$1),
              ),
          ],
        ),
      ),
      if (activeFocus == 'all' || activeFocus == 'earnings') ...[
        EarningsResearchPanel(
          api: widget.api,
          ticker: ticker,
          asOf: asOf,
          palette: p,
          history: researchHistory,
        ),
        const SizedBox(height: 18),
      ],
      if (activeFocus == 'all' || activeFocus == 'filings') ...[
        researchDocumentsPanel(),
        const SizedBox(height: 18),
      ],
      if (activeFocus == 'all' || activeFocus == 'insiders') ...[
        ResearchInsidersPanel(
          api: widget.api,
          palette: p,
          ticker: ticker,
          asOf: asOf,
        ),
        const SizedBox(height: 18),
      ],
      if (activeFocus == 'all' || activeFocus == 'holders')
        ...evidenceView(includeHistory: false),
    ];
  }

  Widget researchDocumentsPanel() {
    final documents = asList(researchDocumentsData?['rows']);
    final fundamental = researchFundamental;
    final sections = asList(fundamental?['sections']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        researchPanelState(),
        if (researchFinancialsError != null)
          card([
            label(
              'Financial history could not be loaded. Announcements remain available.',
              '财务历史暂时无法载入，公告仍可查看。',
              color: p.secondary,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: researchFinancialsLoading
                    ? null
                    : loadResearchOverviewFinancials,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(w('Retry financial history', '重试财务历史')),
              ),
            ),
          ]),
        pageColumns(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              card([
                Row(
                  children: [
                    Icon(Icons.description_outlined, size: 18, color: p.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w(
                          'Financial Disclosures & Source Links',
                          '财务披露目录与原文链接',
                        ),
                        style: deskHeading(18),
                      ),
                    ),
                    if (documents.isNotEmpty)
                      researchTag(
                        w('${documents.length} filings', '${documents.length} 份记录'),
                        p.muted,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                label(
                  'Point-in-time filing index with verified external SEC/issuer links. Full filing text is not cached locally.',
                  '按研究截止日对齐的财务披露索引与外部核验链接（本地不缓存长篇原文，故不自动生成全文摘要）。',
                  size: 11.5,
                ),
                const SizedBox(height: 12),
                if (documents.isEmpty &&
                    !researchPanelLoading &&
                    researchPanelError == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: label(
                      'No announcement catalog is available at this cutoff.',
                      '该截止日暂无公告目录。',
                    ),
                  ),
                for (var i = 0; i < math.min(documents.length, 12); i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: p.border.withValues(alpha: .6)),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        researchTag(
                          localizeFilingFormLabel(
                            text(documents[i]['form'], '10-Q/K'),
                            context.language,
                          ),
                          p.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                localizeFilingTitle(
                                  text(documents[i]['title']),
                                  context.language,
                                ),
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${w('Period', '报告期')} ${text(documents[i]['reportPeriod'], '—')} · ${w('Published', '披露日')} ${text(documents[i]['publishedAt'], '—')}',
                                style: TextStyle(color: p.muted, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        if (Uri.tryParse(text(documents[i]['sourceUrl']))?.scheme ==
                            'https')
                          TextButton.icon(
                            onPressed: () => openBrowserPath(
                              text(documents[i]['sourceUrl']),
                            ),
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: Text(w('Source', '原文')),
                          ),
                      ],
                    ),
                  ),
                ],
              ]),
              if (sections.isNotEmpty) ...[
                const SizedBox(height: 16),
                card([
                  Text(
                    w(
                      'Diagnostic Ratios by Research Question',
                      '按研究维度拆解财务诊断指标',
                    ),
                    style: deskHeading(18),
                  ),
                  const SizedBox(height: 6),
                  label(
                    'Structured profitability, cash-conversion, capital-structure, and per-share diagnostics.',
                    '围绕增长质量、现金流转化、资本结构与每股指标的结构化核查。',
                    size: 11.5,
                  ),
                  const SizedBox(height: 8),
                  for (final sec in sections)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        text(
                          asMap(
                            sec['title'],
                          )[context.language == AppLanguage.zh ? 'zh' : 'en'],
                        ),
                        style: deskHeading(14.5),
                      ),
                      children: [
                        for (final row in asList(sec['rows']))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        text(
                                          asMap(
                                            row['label'],
                                          )[context.language == AppLanguage.zh
                                              ? 'zh'
                                              : 'en'],
                                        ),
                                        style: TextStyle(
                                          color: p.text,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (text(row['formula']).isNotEmpty)
                                        Text(
                                          localizeDiagnosticFormula(
                                            text(row['id']),
                                            text(row['formula']),
                                            context.language,
                                          ),
                                          style: TextStyle(
                                            color: p.muted,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  formatDiagnosticRatioValue(
                                    row,
                                    text(company?['currency'], 'USD'),
                                    context.language,
                                  ),
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ]),
              ],
            ],
          ),
          researchEvidenceSidebar(),
          sideWidth: 320,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 3: INSTITUTIONAL HOLDINGS (GURU SPOTLIGHT + FULL 13F ANALYTICS)
  // ---------------------------------------------------------------------------

  Widget researchInstitutionPanel() {
    final data = researchInstitution;
    final rowSummary = asMap(data?['row']);
    final details = asMap(data?['details']);
    final history = asList(details['history']);
    final analysis = asMap(details['analysis']);
    final evidence = asMap(analysis['evidence']);
    final breadth = asMap(evidence['breadth']);
    final shares = asMap(evidence['shares']);
    final weights = asMap(evidence['weights']);
    final importantChanges = asList(analysis['importantChanges']);
    final trackedGurus = orderedDisclosedHolders(
      asList(company?['provenance']),
      '',
    );

    final institutions = <Map<String, dynamic>>[
      for (final action in ['new', 'increased', 'reduced', 'exited'])
        for (final row in asList(details[action])) {...row, 'action': action},
    ];
    final historyLimit = researchRange == 'All'
        ? history.length
        : researchRange == '10Y'
        ? 40
        : 20;
    final visibleHistory = history.length > historyLimit
        ? history.sublist(history.length - historyLimit)
        : history;
    final visibleDetails = {...details, 'history': visibleHistory};

    Color instActionColor(String act) => switch (act) {
      'new' || 'increased' => _emerald,
      'reduced' => _amber,
      'exited' => p.negative,
      _ => p.muted,
    };

    String instActionLabel(String act) => switch (act) {
      'new' => w('New', '新建仓'),
      'increased' => w('Added', '增持'),
      'reduced' => w('Reduced', '减持'),
      'exited' => w('Exited', '清仓'),
      _ => act,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        researchPanelState(),
        title('Institutional Ownership & 13F Flow', '机构持仓全景与 13F 动向'),
        label(
          'Split-normalized 13F institutional holdings and tracked Superinvestors. Form 13F is a delayed U.S. long-equity snapshot, not live fund flow.',
          '按拆合股校准的全市场 13F 机构持仓与投资大师重仓追踪（13F 为滞后披露的美股多头快照，不代表实时资金流）。',
        ),
        const SizedBox(height: 16),
        if (data != null) ...[
          LayoutBuilder(
            builder: (_, c) {
              final cols = c.maxWidth >= 860 ? 4 : (c.maxWidth >= 520 ? 2 : 1);
              final wBox = (c.maxWidth - (cols - 1) * 12) / cols;
              final ownPct = nullableNumber(
                rowSummary['institutionalOwnershipPct'],
              );
              final addCount =
                  (nullableNumber(rowSummary['newPositions'])?.round() ?? 0) +
                  (nullableNumber(rowSummary['increases'])?.round() ?? 0);
              final trimCount =
                  (nullableNumber(rowSummary['reductions'])?.round() ?? 0) +
                  (nullableNumber(rowSummary['exits'])?.round() ?? 0);

              Widget instStat(String lEn, String lZh, String val, String sub, {Color? color}) =>
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w(lEn, lZh),
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          val,
                          style: TextStyle(
                            color: color ?? p.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 10.5),
                        ),
                      ],
                    ),
                  );

              final items = [
                instStat(
                  'Reporting 13F Holders',
                  '13F 持仓机构数',
                  '${rowSummary['holders'] ?? '—'}',
                  '${w('As of period', '统计期末')} ${text(data['reportDate'], '—')}',
                ),
                instStat(
                  'Institutional Ownership',
                  '机构申报持股占比',
                  ownPct == null ? '—' : '${ownPct.toStringAsFixed(1)}%',
                  rowSummary['currentValueM'] != null
                      ? '${w('Reported value', '持仓总值')} ${_fmtMillions(rowSummary['currentValueM'], 'USD')}'
                      : w('Common equity basis', '普通股口径'),
                  color: p.accent,
                ),
                instStat(
                  'Activity Breadth',
                  '机构增减广度',
                  '$addCount ${w('Buy', '增/新')} · $trimCount ${w('Sell', '减/清')}',
                  w('Across comparable filers', '可比连续申报机构'),
                  color: addCount >= trimCount ? _emerald : _amber,
                ),
                instStat(
                  'Public Visibility Cutoff',
                  '公开披露可见日',
                  text(data['availableAt'], '—'),
                  w('Point-in-time cutoff aligned', '严格按历史可见日对齐'),
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final it in items) SizedBox(width: wBox, child: it),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
        ],
        pageColumns(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (trackedGurus.isNotEmpty)
                card([
                  Row(
                    children: [
                      Icon(Icons.stars_outlined, size: 18, color: _emerald),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w(
                            'Tracked ThesisForge Gurus (${trackedGurus.length})',
                            '平台重点追踪投资大师持仓（${trackedGurus.length} 位）',
                          ),
                          style: deskHeading(17),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final g in trackedGurus.take(8))
                        InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => unawaited(openHolderGuru(g)),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: p.card.withValues(alpha: .55),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: p.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                holderAvatar(g, 28),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '${text(g['name'])}${nullableNumber(g['weight']) != null ? ' · ${pct(g['weight'])}' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.text,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ]),
              if (data == null && !researchPanelLoading)
                card([
                  label(
                    'No covered 13F security record is available at this cutoff.',
                    '该截止日暂无覆盖的 13F 个股记录。',
                  ),
                ]),
              if (analysis.isNotEmpty)
                card([
                  label(
                    'EVIDENCE-BASED READ',
                    '本季机构行为定性',
                    size: 9.5,
                    color: p.accent,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _insightBehaviorHeadline(text(analysis['headlineKey'])),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 6),
                  label(
                    '${reportQuarterLabel(text(data?['reportDate']))} vs ${reportQuarterLabel(text(data?['previousReportDate']))} · ${w('13F filings are delayed snapshots, not live trades.', '13F 是延迟披露的持仓快照，不是实时交易。')}',
                    '${reportQuarterLabel(text(data?['reportDate']))} 对比 ${reportQuarterLabel(text(data?['previousReportDate']))} · 13F 是延迟披露的持仓快照，不是实时交易。',
                    size: 10.5,
                  ),
                  if (breadth.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-breadth'),
                      icon: Icons.groups_2_outlined,
                      title: w('Breadth of the move', '增减广度'),
                      summary:
                          '${_integer(breadth['adds'])} ${w('adding', '增加方向')} · ${_integer(breadth['trims'])} ${w('reducing', '减少方向')}',
                      details: [
                        label(
                          '${w('Net breadth', '净广度')} ${_integer(breadth['netFilers'])} · ${w('Adding share of changed filers', '增加方向占发生变化机构')} ${pct(breadth['addsPct'])}',
                          '${w('Net breadth', '净广度')} ${_integer(breadth['netFilers'])} · ${w('Adding share of changed filers', '增加方向占发生变化机构')} ${pct(breadth['addsPct'])}',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                  if (shares.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-shares'),
                      icon: Icons.stacked_line_chart,
                      title: w('Net reported share change', '股数净变化'),
                      summary:
                          '${_sharesFromThousands(shares['netUnitsChangeK'])} · ${nullableNumber(shares['netChangePctPrior']) == null ? '—' : '${number(shares['netChangePctPrior']).toStringAsFixed(2)}%'} ${w('of prior reported shares', '占上季申报股数')}',
                      details: [
                        label(
                          '${w('As % of shares outstanding', '占总股本变化')} ${nullableNumber(shares['netChangePctOutstanding']) == null ? '—' : '${number(shares['netChangePctOutstanding']).toStringAsFixed(2)}%'} · ${w('split-adjusted basis', '拆股折算口径')} ${text(shares['shareBasisDate'], '—')}',
                          '${w('As % of shares outstanding', '占总股本变化')} ${nullableNumber(shares['netChangePctOutstanding']) == null ? '—' : '${number(shares['netChangePctOutstanding']).toStringAsFixed(2)}%'} · ${w('split-adjusted basis', '拆股折算口径')} ${text(shares['shareBasisDate'], '—')}',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                  if (weights.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-weight'),
                      icon: Icons.balance_outlined,
                      title: w('Portfolio-weight evidence', '重要机构组合权重'),
                      summary:
                          '${_integer(weights['importantChangesEvaluated'])} ${w('important changes reviewed', '项重要变动')} · ${_integer(weights['sharesUpWeightDown'])} ${w('shares-up / weight-down divergences', '项股数增加但权重下降')}',
                      details: [
                        label(
                          'Weight is measured inside each filer’s reported common-stock portfolio; it is not total fund AUM.',
                          '权重分母是各机构申报的普通股组合，不代表其完整基金 AUM。',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                ]),
              if (history.isNotEmpty)
                card([
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      Text(
                        w('All-institution history', '全市场机构持仓历史趋势'),
                        style: deskHeading(17),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final range in ['5Y', '10Y', 'All'])
                            ChoiceChip(
                              label: Text(
                                range == 'All' ? w('All', '全部') : range,
                              ),
                              selected: researchRange == range,
                              onSelected: (_) =>
                                  updateUI(() => researchRange = range),
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _insightHistoryCharts(visibleDetails),
                ]),
              if (importantChanges.isNotEmpty)
                card([
                  Row(
                    key: const ValueKey(
                      'research-13f-changes-worth-researching',
                    ),
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w('Changes worth researching', '重点机构大额调仓'),
                              style: deskHeading(17),
                            ),
                            const SizedBox(height: 3),
                            label(
                              'Largest institutional additions and reductions ranked by reported dollar value change.',
                              '按申报市值绝对变动额排序的重点机构增持与减持明细。',
                              size: 11,
                            ),
                          ],
                        ),
                      ),
                      researchTag(
                        '${importantChanges.length} ${w('moves', '项')}',
                        p.accent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final change in importantChanges)
                    _insightImportantChangeRow(change),
                ]),
              if (institutions.isNotEmpty)
                card([
                  Text(
                    w('Comparable Institution Activity', '可比机构调仓明细'),
                    style: deskHeading(17),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < math.min(institutions.length, 30); i++) ...[
                    if (i > 0)
                      Divider(height: 1, color: p.border.withValues(alpha: .55)),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          researchTag(
                            instActionLabel(text(institutions[i]['action'])),
                            instActionColor(text(institutions[i]['action'])),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text(
                                    institutions[i]['name'],
                                    text(
                                      institutions[i]['manager'],
                                      text(institutions[i]['investorId'], '—'),
                                    ),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${w('Shares (K)', '千股')} ${nullableNumber(institutions[i]['currentUnitsK']) == null ? '—' : formatNumber(number(institutions[i]['currentUnitsK']))} · ${w('Book weight', '组合权重')} ${pct(institutions[i]['currentWeight'])}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: p.muted, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            institutions[i]['action'] == 'exited'
                                ? money(institutions[i]['activityValueM'])
                                : pct(institutions[i]['weightChange']),
                            style: TextStyle(
                              color: instActionColor(
                                text(institutions[i]['action']),
                              ),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ]),
            ],
          ),
          researchEvidenceSidebar(),
          sideWidth: 320,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TAB 5: RESEARCH RECORDS (STRUCTURED THESIS & FALSIFICATION JOURNAL)
  // ---------------------------------------------------------------------------

  String _recordStatusLabel(String st) => switch (st) {
    'validated' => w('Validated ✓', '已验证 ✓'),
    'invalidated' => w('Invalidated ✕', '已证伪 ✕'),
    'archived' => w('Archived', '已归档'),
    _ => w('Active thesis', '跟踪中'),
  };

  Color _recordStatusColor(String st) => switch (st) {
    'validated' => _emerald,
    'invalidated' => p.negative,
    _ => p.accent,
  };

  void _startEditingRecord(Map<String, dynamic> row) {
    final tags = (row['tags'] is List)
        ? (row['tags'] as List).map((e) => e.toString()).join(', ')
        : '';
    updateUI(() {
      editingRecordId = text(row['id']);
      researchQuestion.text = text(row['question']);
      researchSupport.text = text(row['supportingEvidence']);
      researchOpposition.text = text(row['opposingEvidence']);
      researchInvalidation.text = text(row['invalidationCondition']);
      researchReviewDate.text = text(row['reviewDate']);
      researchTagsInput.text = tags;
      researchRecordStatus = const {
        'open',
        'validated',
        'invalidated',
      }.contains(row['status'])
          ? text(row['status'])
          : 'open';
    });
  }

  void _cancelEditingRecord() {
    updateUI(() {
      editingRecordId = null;
      researchRecordStatus = 'open';
      researchQuestion.clear();
      researchSupport.clear();
      researchOpposition.clear();
      researchInvalidation.clear();
      researchReviewDate.clear();
      researchTagsInput.clear();
    });
  }

  Future<void> _copyRecordMarkdown(Map<String, dynamic> row) async {
    final md = StringBuffer()
      ..writeln('## $ticker — ${text(row['question'])}')
      ..writeln(
        context.isChinese
            ? '- **状态**：${_recordStatusLabel(text(row['status'], 'open'))} | **基准日**：${text(row['asOf'])} | **复核日**：${text(row['reviewDate'], '—')}'
            : '- **Status**: ${_recordStatusLabel(text(row['status'], 'open'))} | **As of**: ${text(row['asOf'])} | **Review**: ${text(row['reviewDate'], '—')}',
      );
    if (row['tags'] is List && (row['tags'] as List).isNotEmpty) {
      md.writeln(
        '- **${w('Tags', '标签')}**: ${(row['tags'] as List).map((t) => '`$t`').join(' ')}',
      );
    }
    if (text(row['supportingEvidence']).isNotEmpty) {
      md.writeln(
        '- **${w('Supporting Evidence', '支持证据')}**: ${text(row['supportingEvidence'])}',
      );
    }
    if (text(row['opposingEvidence']).isNotEmpty) {
      md.writeln(
        '- **${w('Counter / Gap', '反对证据与缺口')}**: ${text(row['opposingEvidence'])}',
      );
    }
    if (text(row['invalidationCondition']).isNotEmpty) {
      md.writeln(
        '- **${w('Invalidation Trigger', '证伪失效条件')}**: ${text(row['invalidationCondition'])}',
      );
    }
    await Clipboard.setData(ClipboardData(text: md.toString()));
    if (mounted) {
      updateUI(
        () => notice = w(
          'Research record copied as Markdown.',
          '研究记录已复制为 Markdown。',
        ),
      );
    }
  }

  Future<void> _updateRecordQuickStatus(
    Map<String, dynamic> row,
    String nextStatus,
  ) async {
    try {
      await widget.api.postJson('/api/investment/research-records', {
        'operationId': op(),
        'ticker': ticker,
        'asOf': asOf,
        'parentRecordId': text(row['id']),
        'question': text(row['question']),
        'status': nextStatus,
      });
      await loadResearchPanel('records');
      await loadHome();
    } catch (e) {
      if (mounted) updateUI(() => researchPanelError = e.toString());
    }
  }

  Widget researchRecordsPanel() {
    final rows = asList(researchRecordsData?['rows'] ?? company?['researchRecords']);
    final quickTags = context.isChinese
        ? const ['财报业绩', '估值定价', '护城河', '风险点', '催化剂']
        : const ['Earnings', 'Valuation', 'Moat', 'Risk', 'Catalyst'];

    Widget journalField(
      TextEditingController ctrl,
      String en,
      String zh, {
      int minLines = 1,
      int maxLines = 3,
      ValueChanged<String>? onChanged,
    }) => TextField(
      controller: ctrl,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      style: TextStyle(color: p.text, fontSize: 13.5, height: 1.45),
      decoration: InputDecoration(
        labelText: w(en, zh),
        alignLabelWithHint: maxLines > 1,
        filled: true,
        fillColor: p.card.withValues(alpha: .45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.border),
        ),
      ),
    );

    return pageColumns(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          researchPanelState(),
          title(
            editingRecordId != null
                ? 'Edit research record'
                : 'Save a falsifiable research record',
            editingRecordId != null ? '编辑研究记录' : '保存可证伪的研究记录',
          ),
          label(
            'A valuation model is optional. Document your core question, supporting & opposing evidence, invalidation trigger, tags, and review date.',
            '无需强制绑定估值模型；结构化记录核心研究问题、正反双向证据、证伪失效条件、标签与下次复核日期。',
          ),
          const SizedBox(height: 16),
          card([
            if (editingRecordId != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: p.accent.withValues(alpha: .35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.edit_note, color: p.accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w(
                          'Editing saved record · saving creates a versioned revision.',
                          '正在编辑已保存记录 · 保存后将生成带审计轨迹的新修订版。',
                        ),
                        style: TextStyle(color: p.text, fontSize: 12.5),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelEditingRecord,
                      child: Text(w('Cancel edit', '取消编辑')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            journalField(
              researchQuestion,
              'Research question',
              '研究问题',
              minLines: 1,
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (_, c) {
                final supportBox = journalField(
                  researchSupport,
                  'Supporting evidence',
                  '支持证据',
                  minLines: 3,
                  maxLines: 5,
                );
                final opposeBox = journalField(
                  researchOpposition,
                  'Opposing evidence / gap',
                  '反对证据 / 解释缺口',
                  minLines: 3,
                  maxLines: 5,
                );
                if (c.maxWidth >= 640) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: supportBox),
                      const SizedBox(width: 12),
                      Expanded(child: opposeBox),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    supportBox,
                    const SizedBox(height: 12),
                    opposeBox,
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (_, c) {
                final invBox = journalField(
                  researchInvalidation,
                  'Invalidation condition',
                  '失效条件',
                  minLines: 1,
                  maxLines: 2,
                );
                final revRow = Row(
                  children: [
                    Expanded(
                      child: journalField(
                        researchReviewDate,
                        'Review date · YYYY-MM-DD',
                        '复核日期 · YYYY-MM-DD',
                        minLines: 1,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      key: const ValueKey('record-pick-review-date'),
                      tooltip: w('Pick review date', '选择复核日期'),
                      onPressed: () async {
                        final now = DateTime.now();
                        final initial =
                            DateTime.tryParse(researchReviewDate.text.trim()) ??
                            now.add(const Duration(days: 90));
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: initial,
                          firstDate: DateTime(2020, 1, 1),
                          lastDate: DateTime(now.year + 5, 12, 31),
                          helpText: w('Select review date', '选择下次复核日期'),
                          cancelText: w('Cancel', '取消'),
                          confirmText: w('OK', '确定'),
                        );
                        if (picked != null && mounted) {
                          updateUI(
                            () => researchReviewDate.text =
                                '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
                          );
                        }
                      },
                      icon: Icon(Icons.event_outlined, color: p.accent, size: 19),
                    ),
                  ],
                );
                if (c.maxWidth >= 640) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: invBox),
                      const SizedBox(width: 12),
                      Expanded(flex: 2, child: revRow),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [invBox, const SizedBox(height: 12), revRow],
                );
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  child: journalField(
                    researchTagsInput,
                    'Tags (comma-separated)',
                    '标签（逗号分隔）',
                    minLines: 1,
                    maxLines: 1,
                  ),
                ),
                for (final qt in quickTags)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('#$qt', style: const TextStyle(fontSize: 11.5)),
                    onPressed: () {
                      final cur = researchTagsInput.text
                          .split(',')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList();
                      if (!cur.contains(qt)) {
                        cur.add(qt);
                        updateUI(() => researchTagsInput.text = cur.join(', '));
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'open',
                      label: Text(w('Active', '跟踪中'), style: const TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment(
                      value: 'validated',
                      label: Text(w('Validated', '已验证'), style: const TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment(
                      value: 'invalidated',
                      label: Text(w('Invalidated', '已证伪'), style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                  selected: {researchRecordStatus},
                  onSelectionChanged: (s) {
                    if (s.isNotEmpty) {
                      updateUI(() => researchRecordStatus = s.first);
                    }
                  },
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: researchQuestion,
                  builder: (_, value, _) => button(
                    editingRecordId != null
                        ? 'Update research record'
                        : 'Save research record',
                    editingRecordId != null ? '保存修改' : '保存研究记录',
                    value.text.trim().isEmpty
                        ? null
                        : () => unawaited(saveResearchRecord()),
                    primary: true,
                  ),
                ),
              ],
            ),
          ]),
          for (final row in rows.reversed)
            card([
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Text(text(row['question']), style: deskHeading(16)),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      researchTag(
                        _recordStatusLabel(text(row['status'], 'open')),
                        _recordStatusColor(text(row['status'], 'open')),
                      ),
                      researchTag(
                        '${text(row['asOf'])} · ${w('Review', '复核')} ${text(row['reviewDate'], '—')}',
                        p.muted,
                      ),
                    ],
                  ),
                ],
              ),
              if (row['tags'] is List && (row['tags'] as List).isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tg in (row['tags'] as List))
                      researchTag('#$tg', p.accent),
                  ],
                ),
              ],
              if (text(row['supportingEvidence']).isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.add_circle_outline,
                        size: 14,
                        color: _emerald,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${w('Support', '支持证据')}: ${text(row['supportingEvidence'])}',
                        style: TextStyle(color: p.text, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ],
              if (text(row['opposingEvidence']).isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.remove_circle_outline,
                        size: 14,
                        color: _amber,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${w('Counter', '反证缺口')}: ${text(row['opposingEvidence'])}',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (text(row['invalidationCondition']).isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.flag_outlined, size: 14, color: p.negative),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${w('Invalidation', '证伪条件')}: ${text(row['invalidationCondition'])}',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  TextButton.icon(
                    key: ValueKey('record-edit-${text(row['id'])}'),
                    onPressed: () => _startEditingRecord(row),
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    label: Text(w('Edit', '编辑'), style: const TextStyle(fontSize: 12)),
                  ),
                  if (text(row['status'], 'open') != 'validated')
                    TextButton.icon(
                      key: ValueKey('record-validate-${text(row['id'])}'),
                      onPressed: () =>
                          unawaited(_updateRecordQuickStatus(row, 'validated')),
                      icon: const Icon(Icons.check_circle_outline, size: 15),
                      label: Text(
                        w('Mark validated', '标为已验证'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  TextButton.icon(
                    key: ValueKey('record-copy-${text(row['id'])}'),
                    onPressed: () => unawaited(_copyRecordMarkdown(row)),
                    icon: const Icon(Icons.copy_all_outlined, size: 15),
                    label: Text(
                      w('Copy Markdown', '复制 Markdown'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    key: ValueKey('record-archive-${text(row['id'])}'),
                    onPressed: () =>
                        unawaited(_updateRecordQuickStatus(row, 'archived')),
                    icon: Icon(Icons.delete_outline, size: 15, color: p.negative),
                    label: Text(
                      w('Remove', '移除'),
                      style: TextStyle(fontSize: 12, color: p.negative),
                    ),
                  ),
                ],
              ),
            ]),
        ],
      ),
      researchEvidenceSidebar(),
      sideWidth: 320,
    );
  }

  Future<void> saveResearchRecord() async {
    final question = researchQuestion.text.trim();
    if (question.isEmpty) return;
    final parsedTags = researchTagsInput.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(8)
        .toList();
    try {
      await widget.api.postJson('/api/investment/research-records', {
        'operationId': op(),
        'ticker': ticker,
        'asOf': asOf,
        if (editingRecordId != null) 'parentRecordId': editingRecordId,
        'question': question,
        'supportingEvidence': researchSupport.text,
        'opposingEvidence': researchOpposition.text,
        'invalidationCondition': researchInvalidation.text,
        'reviewDate': researchReviewDate.text.trim().isEmpty
            ? null
            : researchReviewDate.text.trim(),
        'tags': parsedTags,
        'status': researchRecordStatus,
        'evidenceRefs': <String>[],
        'discoveryOrigin': discoveryOrigin,
        if (discoveryOrigin == 'ai_insights')
          'discoveryContext': asMap(entryEvidence?['aiInsights']),
        'personalScenarioId': scenarioId,
        'impliedScenario': asMap(calculation?['reverse']).isEmpty
            ? null
            : asMap(calculation?['reverse']),
      });
      _cancelEditingRecord();
      await loadResearchPanel('records');
      await loadHome();
    } catch (e) {
      if (mounted) updateUI(() => researchPanelError = e.toString());
    }
  }

  Widget researchTag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: .26)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );

  Widget researchWatchButton() {
    final saved = asList(home?['watches']).any((r) => r['ticker'] == ticker);
    return OutlinedButton.icon(
      key: const ValueKey('research-watch-toggle'),
      onPressed: busy
          ? null
          : () => command(() async {
              final symbol = ticker, cutoff = asOf;
              if (saved) {
                await widget.api.postJson('/api/investment/watches', {
                  'operationId': op(),
                  'ticker': symbol,
                  'asOf': cutoff,
                  'active': false,
                });
                await loadHome();
                if (mounted) {
                  updateUI(
                    () => notice = w(
                      '$symbol removed from watch.',
                      '$symbol 已移出观察列表。',
                    ),
                  );
                }
                return;
              }
              await widget.api.postJson('/api/investment/watches', {
                'operationId': op(),
                'ticker': symbol,
                'asOf': cutoff,
                'origin': !researchHasPlatformModel
                    ? 'fact_os'
                    : opportunityReturnDate.isNotEmpty
                    ? opportunityLens
                    : 'value',
              });
              await loadHome();
              if (mounted) {
                updateUI(
                  () => notice = w(
                    researchHasPlatformModel
                        ? '$symbol saved to watch with its dated platform model. No investment decision was made.'
                        : '$symbol saved to watch.',
                    researchHasPlatformModel
                        ? '$symbol 已保存带日期的平台模型至观察列表，未记录投资决策。'
                        : '$symbol 已加入观察列表。',
                  ),
                );
              }
            }),
      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border, size: 16),
      label: Text(
        w(saved ? 'Saved to watch' : 'Save to watch', saved ? '已保存观察' : '保存观察'),
      ),
    );
  }
}
