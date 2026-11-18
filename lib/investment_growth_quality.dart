part of 'main.dart';

// User-selected screens, not a calibrated quality score or investment advice.
class GrowthQualityRules {
  final bool enabled, useFcf, useCash, useMargin;
  final int years, passingYears;
  final double growth, roic, fcf, cash, margin;
  const GrowthQualityRules({
    this.enabled = true,
    this.years = 5,
    this.passingYears = 5,
    this.growth = .15,
    this.roic = .15,
    this.useFcf = false,
    this.fcf = .05,
    this.useCash = false,
    this.cash = .8,
    this.useMargin = false,
    this.margin = .15,
  });

  factory GrowthQualityRules.fromQuery(Map<String, String> q) {
    double number(String key, double fallback, double maximum) {
      final v = double.tryParse(q[key] ?? '');
      return v != null && v.isFinite && v >= 0 && v <= maximum ? v : fallback;
    }

    final y = int.tryParse(q['qYears'] ?? '') ?? 5;
    final years = [3, 5, 10].contains(y) ? y : 5;
    final pass = int.tryParse(q['qPass'] ?? '') ?? years;
    return GrowthQualityRules(
      enabled: q['quality'] != 'off',
      years: years,
      passingYears: pass.clamp(1, years),
      growth: number('qGrowth', .15, 3),
      roic: number('qRoic', .15, 2),
      useFcf: q['qFcf'] != null,
      fcf: number('qFcf', .05, 1),
      useCash: q['qCash'] != null,
      cash: number('qCash', .8, 3),
      useMargin: q['qMargin'] != null,
      margin: number('qMargin', .15, 1),
    );
  }
  GrowthQualityRules copyWith({
    bool? enabled,
    int? years,
    int? passingYears,
    double? growth,
    double? roic,
    bool? useFcf,
    double? fcf,
    bool? useCash,
    double? cash,
    bool? useMargin,
    double? margin,
  }) => GrowthQualityRules(
    enabled: enabled ?? this.enabled,
    years: years ?? this.years,
    passingYears: (passingYears ?? years ?? this.passingYears).clamp(
      1,
      years ?? this.years,
    ),
    growth: growth ?? this.growth,
    roic: roic ?? this.roic,
    useFcf: useFcf ?? this.useFcf,
    fcf: fcf ?? this.fcf,
    useCash: useCash ?? this.useCash,
    cash: cash ?? this.cash,
    useMargin: useMargin ?? this.useMargin,
    margin: margin ?? this.margin,
  );
  Map<String, String?> get query => {
    'quality': enabled ? 'on' : 'off',
    'qYears': '$years',
    'qPass': '$passingYears',
    'qGrowth': '$growth',
    'qRoic': '$roic',
    'qFcf': useFcf ? '$fcf' : null,
    'qCash': useCash ? '$cash' : null,
    'qMargin': useMargin ? '$margin' : null,
  };
}

class GrowthQualityAssessment {
  final bool complete, passes;
  final int passingYears, validYears;
  final double? mean, worst;
  final List<Map<String, dynamic>> years;
  const GrowthQualityAssessment({
    required this.complete,
    required this.passes,
    required this.passingYears,
    required this.validYears,
    required this.mean,
    required this.worst,
    required this.years,
  });
}

GrowthQualityAssessment assessGrowthQuality(
  Map<String, dynamic> row,
  GrowthQualityRules rules,
) {
  final quality = asMap(row['quality']);
  final years = asList(quality['years']).take(rules.years).toList();
  var continuous =
      years.length == rules.years && quality['status'] == 'available';
  for (var i = 0; i < years.length; i++) {
    final date = DateTime.tryParse(text(years[i]['periodEnd']));
    final available = DateTime.tryParse(text(years[i]['availableAt']));
    final cutoff = DateTime.tryParse(text(quality['asOf']));
    if (date == null ||
        available == null ||
        cutoff == null ||
        date.isAfter(available) ||
        available.isAfter(cutoff) ||
        (i == 0 && cutoff.difference(date).inDays > 550)) {
      continuous = false;
    }
    if (i > 0) {
      final prior = DateTime.tryParse(text(years[i - 1]['periodEnd']));
      final gap = date == null || prior == null
          ? 0
          : prior.difference(date).inDays;
      if (nullableNumber(years[i - 1]['year']) !=
              (nullableNumber(years[i]['year']) ?? -1) + 1 ||
          gap < 300 ||
          gap > 430) {
        continuous = false;
      }
    }
  }
  final roics = years
      .map((y) => nullableNumber(y['roic']))
      .whereType<double>()
      .where((v) => v.isFinite)
      .toList();
  var complete = continuous && roics.length == rules.years;
  bool every(String metric, double minimum) {
    final values = years
        .map((y) => nullableNumber(y[metric]))
        .whereType<double>()
        .where((v) => v.isFinite)
        .toList();
    if (values.length != rules.years) complete = false;
    return values.length == rules.years &&
        values.every((v) => v + 1e-10 >= minimum);
  }

  final cashPass = !rules.useCash || every('cashConversion', rules.cash);
  final fcfPass = !rules.useFcf || every('fcfMargin', rules.fcf);
  final marginPass = !rules.useMargin || every('operatingMargin', rules.margin);
  final passing = roics.where((v) => v + 1e-10 >= rules.roic).length;
  return GrowthQualityAssessment(
    complete: complete,
    passes:
        complete &&
        passing >= rules.passingYears &&
        cashPass &&
        fcfPass &&
        marginPass,
    passingYears: passing,
    validYears: roics.length,
    mean: roics.isEmpty ? null : roics.reduce((a, b) => a + b) / roics.length,
    worst: roics.isEmpty ? null : roics.reduce(math.min),
    years: years,
  );
}

class _QualityNumberField extends StatefulWidget {
  final String title, error;
  final double value, maximum;
  final Color color;
  final ValueChanged<double> onChanged;
  const _QualityNumberField({
    super.key,
    required this.title,
    required this.error,
    required this.value,
    required this.maximum,
    required this.color,
    required this.onChanged,
  });
  @override
  State<_QualityNumberField> createState() => _QualityNumberFieldState();
}

class _QualityNumberFieldState extends State<_QualityNumberField> {
  late final TextEditingController input;
  final focus = FocusNode();
  String display(double v) =>
      (v * 100).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  @override
  void initState() {
    super.initState();
    input = TextEditingController(text: display(widget.value));
    focus.addListener(() {
      if (!focus.hasFocus) apply();
    });
  }

  void apply() {
    final n = double.tryParse(input.text);
    if (n != null &&
        n.isFinite &&
        n >= 0 &&
        n <= widget.maximum * 100 &&
        (n / 100 - widget.value).abs() > 1e-10) {
      widget.onChanged(n / 100);
    }
  }

  @override
  void didUpdateWidget(covariant _QualityNumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) input.text = display(widget.value);
  }

  @override
  void dispose() {
    focus.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: input,
    focusNode: focus,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    style: TextStyle(color: widget.color, fontSize: 14),
    decoration: InputDecoration(
      labelText: widget.title,
      suffixText: '%',
      isDense: true,
    ),
    validator: (s) {
      final n = double.tryParse(s ?? '');
      return n == null || !n.isFinite || n < 0 || n > widget.maximum * 100
          ? widget.error
          : null;
    },
    onFieldSubmitted: (_) => apply(),
    onTapOutside: (_) => focus.unfocus(),
  );
}

extension _InvestmentGrowthQuality on _InvestmentWorkspaceState {
  void changeGrowthQuality(GrowthQualityRules next) => changeDiscover(() {
    growthQuality = next;
    if (discoverSort == 'growth' || discoverSort == 'quality') {
      discoverSort = next.enabled ? 'quality' : 'growth';
    }
  });

  Widget qualityNumber(
    String id,
    String title,
    double value,
    double maxValue,
    ValueChanged<double> onChanged,
  ) => SizedBox(
    width: 176,
    child: _QualityNumberField(
      key: ValueKey(id),
      title: title,
      value: value,
      maximum: maxValue,
      color: p.text,
      onChanged: onChanged,
      error: w(
        '0–${(maxValue * 100).round()} required',
        '请输入 0–${(maxValue * 100).round()}',
      ),
    ),
  );

  Widget growthQualityControls() {
    final r = growthQuality;
    final growthRows = filterDiscoverCandidates(
      asList(opportunities?['rows']),
      collection: 'growth',
      qualityRules: r.copyWith(enabled: false),
    );
    final audited = growthRows
        .map((row) => assessGrowthQuality(row, r))
        .toList();
    final passed = audited.where((a) => a.passes).length;
    final missing = audited.where((a) => !a.complete).length;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(
          color: const Color(0xFF76BCEB).withValues(alpha: .4),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w('Growth is the start. Quality is the test.', '增长是起点，质量才是考验。'),
            style: deskHeading(16),
          ),
          const SizedBox(height: 6),
          label(
            'Choose a starting point, then make the rules yours.',
            '先选一组条件，再按自己的要求调整。',
            size: 12,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in ['growth', 'roic', 'cash'])
                OutlinedButton(
                  key: ValueKey('quality-preset-$preset'),
                  onPressed: () => changeGrowthQuality(
                    preset == 'growth'
                        ? r.copyWith(enabled: false)
                        : GrowthQualityRules(
                            growth: r.growth,
                            useFcf: preset == 'cash',
                            useCash: preset == 'cash',
                          ),
                  ),
                  child: Text(
                    preset == 'growth'
                        ? w('Growth only', '只看增长')
                        : preset == 'roic'
                        ? w('Durable ROIC', '持续高 ROIC')
                        : w('Cash-backed', '现金流支持'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  w('Long-term quality filter', '长期质量筛选'),
                  style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
                ),
              ),
              Switch(
                key: const ValueKey('quality-enabled'),
                value: r.enabled,
                onChanged: (v) => changeGrowthQuality(r.copyWith(enabled: v)),
              ),
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 16,
            children: [
              qualityNumber(
                'quality-growth',
                w('Revenue YoY ≥', '收入同比 ≥'),
                r.growth,
                3,
                (v) => changeGrowthQuality(r.copyWith(growth: v)),
              ),
              if (r.enabled) ...[
                discoverSelect(
                  'quality-years',
                  '${r.years}',
                  {
                    for (final n in [3, 5, 10])
                      '$n': w('Last $n fiscal years', '最近 $n 个财年'),
                  },
                  (v) => changeGrowthQuality(r.copyWith(years: int.parse(v))),
                  172,
                ),
                qualityNumber(
                  'quality-roic',
                  w('Pre-tax ROIC ≥', '税前 ROIC ≥'),
                  r.roic,
                  2,
                  (v) => changeGrowthQuality(r.copyWith(roic: v)),
                ),
                discoverSelect(
                  'quality-pass',
                  '${r.passingYears}',
                  {
                    for (var n = 1; n <= r.years; n++)
                      '$n': w(
                        '$n / ${r.years} years must pass',
                        '$n / ${r.years} 年须达标',
                      ),
                  },
                  (v) => changeGrowthQuality(
                    r.copyWith(passingYears: int.parse(v)),
                  ),
                  195,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          label(
            'Press Enter or leave a field to apply. Presets apply immediately.',
            '按回车或移出输入框后应用；预设立即生效。',
            size: 11,
          ),
          if (r.enabled) ...[
            const SizedBox(height: 10),
            ExpansionTile(
              key: const ValueKey('quality-extra'),
              tilePadding: EdgeInsets.zero,
              title: Text(
                w('More quality factors', '更多质量因子'),
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                w(
                  'Each enabled factor must pass in every selected year.',
                  '勾选的因子必须在观察窗口内每年达标。',
                ),
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
              children: [
                qualityExtra(
                  'fcf',
                  w('FCF margin', '自由现金流率'),
                  r.useFcf,
                  r.fcf,
                  1,
                  (v) => changeGrowthQuality(r.copyWith(useFcf: v)),
                  (v) => changeGrowthQuality(r.copyWith(fcf: v)),
                ),
                qualityExtra(
                  'cash',
                  w('CFO / net income', '经营现金流 / 净利润'),
                  r.useCash,
                  r.cash,
                  3,
                  (v) => changeGrowthQuality(r.copyWith(useCash: v)),
                  (v) => changeGrowthQuality(r.copyWith(cash: v)),
                ),
                qualityExtra(
                  'margin',
                  w('Operating margin', '营业利润率'),
                  r.useMargin,
                  r.margin,
                  1,
                  (v) => changeGrowthQuality(r.copyWith(useMargin: v)),
                  (v) => changeGrowthQuality(r.copyWith(margin: v)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              w(
                '${growthRows.length} growing → $passed qualify · ${growthRows.length - passed - missing} fail · $missing incomplete',
                '${growthRows.length} 家增长公司 → $passed 家通过 · ${growthRows.length - passed - missing} 家未达标 · $missing 家数据不足',
              ),
              style: TextStyle(color: p.accent, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 4),
            label(
              'Before manager/search filters. Missing years never pass. Thresholds are yours, not a buy signal.',
              '以上统计未应用经理和搜索条件。缺失年份不算通过；门槛由你设定，不构成买入信号。',
              size: 11,
            ),
          ],
        ],
      ),
    );
  }

  Widget qualityExtra(
    String id,
    String title,
    bool enabled,
    double value,
    double maxValue,
    ValueChanged<bool> toggle,
    ValueChanged<double> change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: ValueKey('quality-$id-enabled'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: enabled,
          title: Text(title, style: const TextStyle(fontSize: 13)),
          onChanged: (v) => toggle(v ?? false),
        ),
        if (enabled)
          qualityNumber(
            'quality-$id',
            w('Every year ≥', '每年 ≥'),
            value,
            maxValue,
            change,
          ),
      ],
    ),
  );

  Widget growthQualityEvidence(Map<String, dynamic> row) {
    final r = growthQuality, a = assessGrowthQuality(row, growthQuality);
    final q = asMap(row['quality']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(w('Has quality lasted?', '高质量持续了多久？'), style: deskHeading(18)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 22,
          runSpacing: 16,
          children: [
            lensStat(
              w('Years ROIC ≥ ${pct(r.roic)}', 'ROIC ≥ ${pct(r.roic)} 的年份'),
              '${a.passingYears} / ${r.years}',
              color: p.accent,
            ),
            lensStat(
              w('${r.years}Y average ROIC', '${r.years} 年平均 ROIC'),
              a.complete ? pct(a.mean) : '—',
            ),
            lensStat(
              w('Worst-year ROIC', '最差年份 ROIC'),
              a.complete ? pct(a.worst) : '—',
            ),
          ],
        ),
        lensNote(
          !a.complete
              ? 'Annual quality history is incomplete or stale. This company does not pass an enabled quality screen.'
              : a.passes
              ? 'Passes your current quality rules. That does not establish an attractive price.'
              : 'Does not pass your current quality rules. Inspect the individual years below.',
          !a.complete
              ? '年度质量数据不完整或已陈旧，不能通过已启用的质量筛选。'
              : a.passes
              ? '符合你当前的质量条件，但不代表价格合适。'
              : '未通过当前质量条件，请检查下面的逐年数据。',
          caution: !a.passes,
        ),
        const SizedBox(height: 14),
        if (a.years.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              horizontalMargin: 0,
              columnSpacing: 24,
              dataRowMinHeight: 46,
              dataRowMaxHeight: 60,
              columns: [
                for (final title in [
                  w('Fiscal year / available', '财年 / 披露日'),
                  w('Pre-tax ROIC', '税前 ROIC'),
                  w('FCF margin', '自由现金流率'),
                  w('CFO / income', '现金流 / 净利润'),
                  w('Op. margin', '营业利润率'),
                ])
                  DataColumn(
                    label: Text(
                      title,
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                  ),
              ],
              rows: [
                for (final y in a.years.reversed)
                  DataRow(
                    cells: [
                      DataCell(
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w('FY ${y['year']}', '${y['year']} 财年'),
                              style: TextStyle(color: p.text, fontSize: 12),
                            ),
                            Text(
                              text(y['availableAt']),
                              style: TextStyle(color: p.muted, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      for (final key in [
                        'roic',
                        'fcfMargin',
                        'cashConversion',
                        'operatingMargin',
                      ])
                        DataCell(
                          Text(
                            pct(y[key]),
                            style: TextStyle(
                              fontSize: 12,
                              color: key == 'roic'
                                  ? (nullableNumber(y[key]) ?? -1) >= r.roic
                                        ? p.accent
                                        : p.secondary
                                  : p.text,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        lensNote(
          'Source: ${q['source'] ?? 'unavailable'} · ART at fiscal Q4, one observation per year. Availability dates obey your workspace cutoff.',
          '来源：${q['source'] == null || q['source'] == 'unavailable' ? '暂无数据' : q['source']} · 每个财年 Q4 的滚动四季口径（ART），每年一条，披露时间不晚于工作区截止日。',
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('Definitions & limitations', '口径与局限'),
            style: const TextStyle(fontSize: 12),
          ),
          children: [
            lensNote(
              'ROIC is Sharadar’s pre-tax EBIT / average invested capital, not after-tax NOPAT ROIC. Invested capital excludes intangibles and cash; small capital bases can inflate returns. Nonpositive or missing capital cannot pass.',
              'ROIC 使用 Sharadar 税前 EBIT / 平均投入资本，不是税后 NOPAT ROIC。投入资本扣除无形资产及现金，小分母会抬高回报率；资本非正或缺失时不算通过。',
            ),
            lensNote(
              'FCF = operating cash flow less capital spending; it is not verified parent FCFE. Cash conversion uses CFO / positive net income. Each enabled extra factor must meet its threshold in all selected years. Annual averages are equally weighted; incomplete windows have no full-window statistics.',
              '自由现金流为经营现金流减资本开支，不等同于已核实的母公司 FCFE。现金转化采用经营现金流 / 正净利润。额外勾选的因子必须每年达标；年度均值等权，窗口不完整时不显示完整窗口统计。',
            ),
          ],
        ),
        const Divider(height: 28),
      ],
    );
  }
}
