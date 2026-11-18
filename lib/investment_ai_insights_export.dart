part of 'main.dart';

/// The downloadable report is rendered from the already pinned screen payload.
/// Supports both English (`AppLanguage.en`) and Chinese (`AppLanguage.zh`).
class _AiInsightsExportReport extends StatelessWidget {
  const _AiInsightsExportReport({
    required this.data,
    required this.asOf,
    required this.quarter,
    required this.metric,
    required this.palette,
    this.language = AppLanguage.en,
  });
  final Map<String, dynamic> data;
  final String asOf, quarter, metric;
  final Palette palette;
  final AppLanguage language;

  Palette get p => palette;
  bool get isZh => language == AppLanguage.zh;
  String w(String en, String zh) => isZh ? zh : en;

  List<Map<String, dynamic>> get series => asList(data['series']);
  List<Map<String, dynamic>> get companies => asList(data['companies']);
  String get growthLabel => metric == 'yoy'
      ? w('YoY', '同比 (YoY)')
      : w('QoQ · unadjusted', '环比 (QoQ · 未季调)');

  Color color(String id) => switch (id) {
    'capex' => p.accent,
    'hardware' => const Color(0xFF7FAAFF),
    _ => p.secondary,
  };

  String label(String id) => switch (id) {
    'capex' => w('Capital investment', '资本投入'),
    'hardware' => w('Hardware basket revenue', '硬件组公司收入'),
    _ => w('Software basket revenue', '软件组公司收入'),
  };

  TextStyle style([double size = 14, bool bold = false, Color? color]) =>
      TextStyle(
        color: color ?? p.text,
        fontSize: size,
        height: 1.4,
        fontFamilyFallback: kCjkFontFallback,
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
                        w('THESISFORGE / DISCOVER', 'THESISFORGE · 发现'),
                        style: style(12, true, p.accent),
                      ),
                      const SizedBox(height: 12),
                      Text(w('AI Insights', 'AI 洞察'), style: style(42, true)),
                      const SizedBox(height: 7),
                      Text(
                        w(
                          'Capital investment → revenue growth → earnings quality',
                          '资本投入 → 营收增长 → 盈利质量全链路追踪',
                        ),
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
                      w('Information cutoff: $asOf', '信息截止日：$asOf'),
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
              w(
                'Capital investment: big four + covered neocloud',
                '资本投入规模：四大科技 + 已覆盖新兴算力云',
              ),
              w(
                'USD · net cash investment proxy · fiscal-quarter aligned',
                '美元口径 · 净现金投入代理 · 按财报季度对齐',
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  legend([
                    (w('Big four', '四大科技'), p.accent),
                    (w('Neocloud', '新兴算力云'), const Color(0xFF648F96)),
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
                              group == 'big4'
                                  ? w('Big four', '四大科技')
                                  : w('Neocloud', '新兴算力云'),
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
                        emptyLabel: w(
                          'No comparable observations',
                          '暂无可比观测数据',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    w(
                      'Cash investment includes non-AI business. Net disposal inflows remain negative. Missing reports are not zero.',
                      '现金投入包含非 AI 业务。资产处置净流入保留负号；未披露财报不计为零。',
                    ),
                    style: style(11, false, p.muted),
                  ),
                ],
              ),
            ),
            section(
              w(
                'Are the growth rates moving together?',
                '三条增速曲线是否同频共振？',
              ),
              w(
                '$growthLabel · matched companies in current and prior periods · independent baskets',
                '$growthLabel · 本期与基期可比公司配对计算 · 三个独立样本组',
              ),
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
                        emptyLabel: w(
                          'No comparable observations',
                          '暂无可比观测数据',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  rateTable(),
                ],
              ),
            ),
            section(
              w(
                'Hardware: growth and earnings quality',
                '硬件算力组：营收增长与盈利质量',
              ),
              w(
                'Top 10 by revenue ${metric == 'yoy' ? 'YoY' : 'QoQ'} · all scores relative to hardware peers',
                '按收入${metric == 'yoy' ? '同比' : '环比'}前 10 名排序 · 评分在硬件同组内百分位对比',
              ),
              ranking('hardware'),
            ),
            section(
              w(
                'Software: growth and earnings quality',
                '软件平台组：营收增长与盈利质量',
              ),
              w(
                'Top 10 by revenue ${metric == 'yoy' ? 'YoY' : 'QoQ'} · all scores relative to software peers',
                '按收入${metric == 'yoy' ? '同比' : '环比'}前 10 名排序 · 评分在软件同组内百分位对比',
              ),
              ranking('software'),
            ),
            section(
              w(
                'Read the evidence, keep the scope clear',
                '严谨阅读证据，明确研究口径边界',
              ),
              w(
                'Point-in-time reconstruction from Fact OS',
                '基于披露日粒度 PIT（Point-in-Time）历史回溯重构',
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    w(
                      'Growth = matched current total / matched prior total − 1. Weights use prior-period revenue; coverage may differ between YoY and QoQ.',
                      '组合增速 = 可比公司本期合计 / 同组基期合计 − 1。权重采用基期收入；同比与环比可比样本数可能不同。',
                    ),
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    w(
                      'Revenue is a company-total proxy, not disclosed AI revenue. These baskets cannot be summed or interpreted as AI ROI. Fiscal alignment retains each company’s actual period end.',
                      '收入采用公司总营收代理，并非单独披露的纯 AI 收入；各组金额不可相加或直接推导 AI 投资回报率（ROI）。',
                    ),
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    w(
                      'Growth score: 40% revenue YoY, 30% QoQ, 15% YoY acceleration, 15% TTM gross-profit YoY. Quality: 25% operating margin, 25% FCF margin, 20% lower accrual ratio, 15% lower SBC/revenue, 15% gross-margin change. Composite = 50% growth + 50% quality.',
                      '增长评分：40% 收入同比 + 30% 收入环比 + 15% 同比加速 + 15% TTM 毛利额同比。质量评分：25% 营业利润率 + 25% FCF 利润率 + 20% 低应计比率 + 15% 低股份支付占比 + 15% 毛利率变化。综合分 = 50% 增长 + 50% 质量。',
                    ),
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    w(
                      'Required inputs are never filled with zero or reweighted. Scores require at least eight eligible peers. QoQ is unadjusted. Current fixed-basket history is not a historical investable universe; disclosure dates have day precision.',
                      '必要输入缺失时绝不补零或重分配权重；评分需同组至少 8 家合格公司。环比未经季节性调整；披露日期精确至日。',
                    ),
                    style: style(12, false, p.muted),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    w(
                      'Universe: ${text(ctx['universeVersion'])} · Method: ${text(ctx['methodologyVersion'])}',
                      '样本池版本：${text(ctx['universeVersion'])} · 方法版本：${text(ctx['methodologyVersion'])}',
                    ),
                    style: style(10, false, p.faint),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    w(
                      'Snapshot: ${text(ctx['snapshotId'], text(data['snapshotId']))}',
                      '数据快照：${text(ctx['snapshotId'], text(data['snapshotId']))}',
                    ),
                    style: style(10, false, p.faint),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 26),
            Text(
              isZh
                  ? 'THESISFORGE                                      $quarter  /  截至 $asOf                                      投研工作台'
                  : 'THESISFORGE                                      $quarter  /  AS OF $asOf                                      FACT OS',
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
            isZh
                ? '同比 ${aiInsightsPercent(metric['yoy'], signed: true)}    环比 ${aiInsightsPercent(metric['qoq'], signed: true)}'
                : 'YoY  ${aiInsightsPercent(metric['yoy'], signed: true)}    QoQ  ${aiInsightsPercent(metric['qoq'], signed: true)}',
            style: style(13, true, color(id)),
          ),
          const SizedBox(height: 16),
          Text(
            w(
              '${coverage['disclosed'] ?? 0}/${coverage['expected'] ?? 0} reported · paired YoY ${coverage['yoyComparable'] ?? 0} / QoQ ${coverage['qoqComparable'] ?? 0}',
              '${coverage['disclosed'] ?? 0}/${coverage['expected'] ?? 0} 家已披露 · 同比可比 ${coverage['yoyComparable'] ?? 0} / 环比可比 ${coverage['qoqComparable'] ?? 0}',
            ),
            style: style(11, false, p.muted),
          ),
          const SizedBox(height: 5),
          Text(
            id == 'capex'
                ? w('Net cash investment proxy · USD', '净现金投入代理 · 美元')
                : w('Company total revenue proxy · USD', '集团总收入代理 · 美元'),
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
          cell(w('Quarter', '季度'), bold: true),
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
                  w('Company', '公司'),
                  w('Revenue', '收入'),
                  w('YoY', '同比'),
                  w('QoQ', '环比'),
                  w('Op. margin¹', '营业利润率¹'),
                  w('FCF margin¹', 'FCF利润率¹'),
                  w('Growth²', '增长分²'),
                  w('Quality²', '质量分²'),
                  w('Composite²', '综合分²'),
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
          w(
            '¹ TTM.  ² Peer percentile scores, 0–100.  — = unavailable.  * Business-scope bridge required; raw growth is as reported, not organic.',
            '¹ 滚动四季度（TTM）。  ² 同组百分位评分（0–100）。  — = 暂无数据。  * 需业务范围桥接；原始增速为财报口径，非内生增速。',
          ),
          style: style(10, false, p.muted),
        ),
        const SizedBox(height: 6),
        Text(
          w(
            'Coverage: ${companies.where((r) => r['group'] == group).map((r) => r['ticker']).join(' · ')}',
            '覆盖标的：${companies.where((r) => r['group'] == group).map((r) => r['ticker']).join(' · ')}',
          ),
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
