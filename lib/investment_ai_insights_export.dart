part of 'main.dart';

/// The downloadable report is rendered from the already pinned screen payload.
/// It has no controls, requests, invented values or locale-dependent copy.
class _AiInsightsExportReport extends StatelessWidget {
  const _AiInsightsExportReport({
    required this.data,
    required this.asOf,
    required this.quarter,
    required this.metric,
    required this.palette,
  });
  final Map<String, dynamic> data;
  final String asOf, quarter, metric;
  final Palette palette;
  Palette get p => palette;
  List<Map<String, dynamic>> get series => asList(data['series']);
  List<Map<String, dynamic>> get companies => asList(data['companies']);
  String get growthLabel => metric == 'yoy' ? 'YoY' : 'QoQ · unadjusted';
  Color color(String id) => switch (id) {
    'capex' => p.accent,
    'hardware' => const Color(0xFF7FAAFF),
    _ => p.secondary,
  };
  String label(String id) => switch (id) {
    'capex' => 'Capital investment',
    'hardware' => 'Hardware basket revenue',
    _ => 'Software basket revenue',
  };
  TextStyle style([double size = 14, bool bold = false, Color? color]) =>
      TextStyle(
        color: color ?? p.text,
        fontSize: size,
        height: 1.4,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      );
  Widget section(String title, String subtitle, Widget child) => Container(
    margin: const EdgeInsets.only(top: 22),
    padding: const EdgeInsets.all(26),
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(color: p.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: style(22, true)),
        const SizedBox(height: 5),
        Text(subtitle, style: style(13, false, p.muted)),
        const SizedBox(height: 18),
        child,
      ],
    ),
  );
  Widget legend(List<(String, Color)> items) => Wrap(
    spacing: 20,
    children: [
      for (final item in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 16, height: 4, color: item.$2),
            const SizedBox(width: 7),
            Text(item.$1, style: style(12, false, p.muted)),
          ],
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ctx = asMap(data['context']);
    return Material(
      color: p.background,
      child: Padding(
        padding: const EdgeInsets.all(42),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'THESISFORGE / DISCOVER',
                        style: style(12, true, p.accent),
                      ),
                      const SizedBox(height: 12),
                      Text('AI Insights', style: style(42, true)),
                      const SizedBox(height: 7),
                      Text(
                        'Capital investment → revenue growth → earnings quality',
                        style: style(17, false, p.muted),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(quarter.replaceAll('-', ' '), style: style(26, true)),
                    Text(
                      'Information cutoff: $asOf',
                      style: style(13, false, p.muted),
                    ),
                    const SizedBox(height: 5),
                    Text(growthLabel, style: style(14, true, p.accent)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 30),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final id in ['capex', 'hardware', 'software']) ...[
                  if (id != 'capex') const SizedBox(width: 16),
                  Expanded(child: summary(id)),
                ],
              ],
            ),
            section(
              'Capital investment: big four + covered neocloud',
              'USD · net cash investment proxy · fiscal-quarter aligned',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  legend([
                    ('Big four', p.accent),
                    ('Neocloud', const Color(0xFF648F96)),
                  ]),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 300,
                    child: CustomPaint(
                      painter: _AiInsightsChartPainter(
                        palette: p,
                        labels: [
                          for (final row in series) text(row['quarter']),
                        ],
                        series: [
                          for (final group in ['big4', 'neocloud'])
                            _AiChartSeries(
                              group == 'big4' ? 'Big four' : 'Neocloud',
                              group == 'big4'
                                  ? p.accent
                                  : const Color(0xFF648F96),
                              [
                                for (final row in series)
                                  nullableNumber(
                                    asMap(
                                      asMap(row['capex'])['breakdown'],
                                    )[group],
                                  ),
                              ],
                            ),
                        ],
                        stacked: true,
                        percent: false,
                        hovered: null,
                        selectedQuarter: quarter,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Cash investment includes non-AI business. Net disposal inflows remain negative. Missing reports are not zero.',
                    style: style(11, false, p.muted),
                  ),
                ],
              ),
            ),
            section(
              'Are the growth rates moving together?',
              '$growthLabel · matched companies in current and prior periods · independent baskets',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  legend([
                    for (final id in ['capex', 'hardware', 'software'])
                      (label(id), color(id)),
                  ]),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 330,
                    child: CustomPaint(
                      painter: _AiInsightsChartPainter(
                        palette: p,
                        labels: [
                          for (final row in series) text(row['quarter']),
                        ],
                        series: [
                          for (final id in ['capex', 'hardware', 'software'])
                            _AiChartSeries(label(id), color(id), [
                              for (final row in series)
                                nullableNumber(asMap(row[id])[metric]),
                            ]),
                        ],
                        stacked: false,
                        percent: true,
                        hovered: null,
                        selectedQuarter: quarter,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  rateTable(),
                ],
              ),
            ),
            section(
              'Hardware: growth and earnings quality',
              'Top 10 by revenue ${metric == 'yoy' ? 'YoY' : 'QoQ'} · all scores relative to hardware peers',
              ranking('hardware'),
            ),
            section(
              'Software: growth and earnings quality',
              'Top 10 by revenue ${metric == 'yoy' ? 'YoY' : 'QoQ'} · all scores relative to software peers',
              ranking('software'),
            ),
            section(
              'Read the evidence, keep the scope clear',
              'Point-in-time reconstruction from Fact OS',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Growth = matched current total / matched prior total − 1. Weights use prior-period revenue; coverage may differ between YoY and QoQ.',
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Revenue is a company-total proxy, not disclosed AI revenue. These baskets cannot be summed or interpreted as AI ROI. Fiscal alignment retains each company’s actual period end.',
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Growth score: 40% revenue YoY, 30% QoQ, 15% YoY acceleration, 15% TTM gross-profit YoY. Quality: 25% operating margin, 25% FCF margin, 20% lower accrual ratio, 15% lower SBC/revenue, 15% gross-margin change. Composite = 50% growth + 50% quality.',
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Required inputs are never filled with zero or reweighted. Scores require at least eight eligible peers. QoQ is unadjusted. Current fixed-basket history is not a historical investable universe; disclosure dates have day precision.',
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Universe: ${text(ctx['universeVersion'])} · Method: ${text(ctx['methodologyVersion'])}',
                    style: style(10, false, p.faint),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Snapshot: ${text(ctx['snapshotId'], text(data['snapshotId']))}',
                    style: style(10, false, p.faint),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            Text(
              'THESISFORGE                                      $quarter  /  AS OF $asOf                                      FACT OS',
              style: style(11, true, p.faint),
            ),
          ],
        ),
      ),
    );
  }

  Widget summary(String id) {
    final metric = asMap(asMap(data['summary'])[id]),
        coverage = asMap(asMap(asMap(data['summary'])[id])['coverage']);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border(top: BorderSide(color: color(id), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label(id), style: style(13, true, p.muted)),
          const SizedBox(height: 16),
          Text(aiInsightsAmount(metric['amount']), style: style(34, true)),
          const SizedBox(height: 10),
          Text(
            'YoY  ${aiInsightsPercent(metric['yoy'], signed: true)}    QoQ  ${aiInsightsPercent(metric['qoq'], signed: true)}',
            style: style(13, true, color(id)),
          ),
          const SizedBox(height: 16),
          Text(
            '${coverage['disclosed'] ?? 0}/${coverage['expected'] ?? 0} reported · paired YoY ${coverage['yoyComparable'] ?? 0} / QoQ ${coverage['qoqComparable'] ?? 0}',
            style: style(11, false, p.muted),
          ),
          const SizedBox(height: 5),
          Text(
            id == 'capex'
                ? 'Net cash investment proxy · USD'
                : 'Company total revenue proxy · USD',
            style: style(11, false, p.faint),
          ),
        ],
      ),
    );
  }

  Widget rateTable() => Table(
    columnWidths: const {0: FlexColumnWidth(1.6)},
    children: [
      TableRow(
        children: [
          cell('Quarter', bold: true),
          for (final id in ['capex', 'hardware', 'software'])
            cell(label(id), bold: true, color: color(id)),
        ],
      ),
      for (final row in series)
        TableRow(
          children: [
            cell(text(row['quarter'])),
            for (final id in ['capex', 'hardware', 'software'])
              cell(aiInsightsPercent(asMap(row[id])[metric], signed: true)),
          ],
        ),
    ],
  );

  Widget ranking(String group) {
    final rows = filterAiInsightsCompanies(
      companies,
      group: group,
      sort: metric == 'yoy' ? 'revenueYoY' : 'revenueQoQ',
    ).take(10).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Table(
          columnWidths: const {
            0: FlexColumnWidth(1.25),
            1: FlexColumnWidth(1.1),
          },
          border: TableBorder(
            horizontalInside: BorderSide(color: p.border, width: .7),
          ),
          children: [
            TableRow(
              children: [
                for (final name in [
                  'Company',
                  'Revenue',
                  'YoY',
                  'QoQ',
                  'Op. margin¹',
                  'FCF margin¹',
                  'Growth²',
                  'Quality²',
                  'Composite²',
                ])
                  cell(name, bold: true, color: p.muted),
              ],
            ),
            for (final row in rows)
              TableRow(
                children: [
                  cell(
                    '${text(row['ticker'])}${asMap(row['comparability'])['growth'] == 'scope_bridge_required' ? '*' : ''}',
                    bold: true,
                    color: color(group),
                  ),
                  cell(aiInsightsAmount(row['revenue'])),
                  cell(aiInsightsPercent(row['revenueYoY'], signed: true)),
                  cell(aiInsightsPercent(row['revenueQoQ'], signed: true)),
                  cell(aiInsightsPercent(row['ttmOperatingMargin'])),
                  cell(aiInsightsPercent(row['ttmFcfMargin'])),
                  for (final field in [
                    'growthScore',
                    'qualityScore',
                    'compositeScore',
                  ])
                    cell(nullableNumber(row[field])?.toStringAsFixed(1) ?? '—'),
                ],
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '¹ TTM.  ² Peer percentile scores, 0–100.  — = unavailable.  * Business-scope bridge required; raw growth is as reported, not organic.',
          style: style(10, false, p.muted),
        ),
        const SizedBox(height: 6),
        Text(
          'Coverage: ${companies.where((r) => r['group'] == group).map((r) => r['ticker']).join(' · ')}',
          style: style(10, false, p.faint),
        ),
      ],
    );
  }

  Widget cell(String value, {bool bold = false, Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
    child: Text(value, style: style(12, bold, color)),
  );
}
