part of 'main.dart';

const strategyEquityComponents = ['guru', 'factors', 'QQQ', 'SPY', 'SCHD'];
const strategyFactorDefaults = {
  'growth': .15,
  'operatingMargin': .10,
  'fcfMargin': .05,
  'roic': .15,
};
String strategyFactorName(BuildContext context, String key) => switch (key) {
  'growth' => context.tr('增长', 'Growth'),
  'operatingMargin' => context.tr('盈利性', 'Profitability'),
  'fcfMargin' => context.tr('现金流', 'Cash flow'),
  'roic' => context.tr('长期 ROIC', 'Durable ROIC'),
  _ => key,
};
// Expand older saved mixes without changing their original all-four behavior.
Map<String, dynamic> strategyMixForRequest(Map<String, dynamic> mix) {
  final f = asMap(mix['factors']);
  final enabled = strategyFactorDefaults.keys
      .where(
        (key) => f['enabled'] is! List || (f['enabled'] as List).contains(key),
      )
      .toList();
  return {
    ...mix,
    'factors': {
      ...strategyFactorDefaults,
      'qualityYears': 5,
      'topN': 10,
      ...f,
      'enabled': enabled,
      'rankBy': enabled.contains(f['rankBy'])
          ? f['rankBy']
          : enabled.firstOrNull,
      'qualityPassYears': f['qualityPassYears'] ?? f['qualityYears'] ?? 5,
    },
  };
}

String strategyComponentName(BuildContext context, String key) => switch (key) {
  'guru' => context.tr('大师策略', 'Guru strategy'),
  'factors' => context.tr('四因子策略', 'Four-factor strategy'),
  _ => key,
};
String strategyFactorSummary(BuildContext context, Map<String, dynamic> mix) {
  final f = asMap(strategyMixForRequest(mix)['factors']);
  final enabled = (f['enabled'] as List).cast<String>();
  final conditions = enabled
      .map((key) {
        final threshold = '${(number(f[key]) * 100).toStringAsFixed(1)}%';
        final years = key == 'roic'
            ? context.tr(
                '（${f['qualityYears']} 年中 ${f['qualityPassYears']} 年达标）',
                ' (${f['qualityPassYears']}/${f['qualityYears']} years)',
              )
            : '';
        return '${strategyFactorName(context, key)} ≥ $threshold$years';
      })
      .join(' · ');
  return '${context.tr('同时满足', 'Match all')}: $conditions · ${context.tr('前 ${f['topN']} 名', 'Top ${f['topN']}')} · ${context.tr('排序', 'Rank')}: ${strategyFactorName(context, text(f['rankBy']))} ↓';
}

/// Transactional editor: nothing in the parent changes until Apply is pressed.
class StrategyMixDialog extends StatefulWidget {
  const StrategyMixDialog({
    super.key,
    required this.palette,
    required this.catalog,
    required this.managers,
    required this.topN,
    required this.ctaWeight,
    this.initial,
  });
  final Palette palette;
  final List<Map<String, dynamic>> catalog;
  final Set<String> managers;
  final int topN;
  final double ctaWeight;
  final Map<String, dynamic>? initial;
  @override
  State<StrategyMixDialog> createState() => _StrategyMixDialogState();
}

class _StrategyMixDialogState extends State<StrategyMixDialog> {
  final form = GlobalKey<FormState>();
  final factorSectionKey = GlobalKey();
  final weights = <String, double?>{};
  final factors = <String, double?>{};
  final enabledFactors = <String>{};
  final controllers = <String, TextEditingController>{};
  late Set<String> managers;
  late int topN;
  int factorTopN = 10, qualityYears = 5;
  int qualityPassYears = 5;
  String? rankBy = 'growth';
  String query = '';
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  double get total => weights.values.fold(0, (a, b) => a + (b ?? 0));
  bool get valid =>
      weights.values.every(
        (v) => v != null && v.isFinite && v >= 0 && v <= 100,
      ) &&
      (total - 100).abs() < .000001 &&
      ((weights['guru'] ?? 0) == 0 || managers.isNotEmpty) &&
      ((weights['factors'] ?? 0) == 0 ||
          enabledFactors.isNotEmpty &&
              enabledFactors
                  .map((key) => factors[key])
                  .every((v) => v != null && v.isFinite && v >= 0 && v <= 100));
  // An inactive source must not block applying an unrelated index/Guru mix.
  // Invalid hidden drafts are not saved as executable factor assumptions.
  double savedFactor(String key) {
    final value = factors[key];
    if (value != null && value.isFinite && value >= 0 && value <= 100) {
      return value / 100;
    }
    return nullableNumber(asMap(widget.initial?['factors'])[key]) ??
        strategyFactorDefaults[key]!;
  }

  @override
  void initState() {
    super.initState();
    managers = {...widget.managers};
    topN = widget.topN;
    final initial = asMap(widget.initial?['weights']);
    for (final key in strategyEquityComponents) {
      weights[key] = initial.isEmpty
          ? (key == 'guru' ? 100 : 0)
          : number(initial[key]) * 100;
      controllers[key] = TextEditingController(
        text: weights[key]!.toStringAsFixed(2),
      );
    }
    final f = asMap(strategyMixForRequest(widget.initial ?? {})['factors']);
    enabledFactors.addAll((f['enabled'] as List).cast<String>());
    rankBy = f['rankBy'] as String?;
    for (final entry in strategyFactorDefaults.entries) {
      factors[entry.key] = (nullableNumber(f[entry.key]) ?? entry.value) * 100;
    }
    factorTopN = (nullableNumber(f['topN']) ?? 10).toInt();
    qualityYears = (nullableNumber(f['qualityYears']) ?? 5).toInt();
    qualityPassYears = (nullableNumber(f['qualityPassYears']) ?? qualityYears)
        .toInt();
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void preset(Map<String, double> values) => setState(() {
    for (final key in strategyEquityComponents) {
      weights[key] = values[key] ?? 0;
      controllers[key]!.text = weights[key]!.toStringAsFixed(2);
    }
  });
  void toggleFactor(String key, bool enabled) => setState(() {
    if (enabled) {
      enabledFactors.add(key);
    } else {
      enabledFactors.remove(key);
    }
    if (!enabledFactors.contains(rankBy)) {
      rankBy = strategyFactorDefaults.keys
          .where(enabledFactors.contains)
          .firstOrNull;
    }
  });

  Widget factorCard(String key) {
    final enabled = enabledFactors.contains(key);
    final description = switch (key) {
      'growth' => w('Latest reported quarter · revenue YoY', '最新披露季度 · 营收同比增长'),
      'operatingMargin' => w(
        'Trailing 12 months · operating margin',
        '最近 12 个月 · 营业利润率',
      ),
      'fcfMargin' => w(
        'Trailing 12 months · free-cash-flow margin',
        '最近 12 个月 · 自由现金流率',
      ),
      _ => w('Consecutive fiscal years · pre-tax ROIC', '连续财年 · 税前投入资本回报率'),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: enabled ? p.accent.withValues(alpha: .06) : p.background,
        border: Border.all(
          color: enabled ? p.accent.withValues(alpha: .5) : p.border,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              key: ValueKey('mix-enable-$key'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                strategyFactorName(context, key),
                style: TextStyle(
                  color: enabled ? p.text : p.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              value: enabled,
              onChanged: (v) => toggleFactor(key, v),
            ),
          ),
          Text(
            description,
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: ValueKey('mix-factor-$key'),
            initialValue: factors[key]?.toStringAsFixed(1) ?? '',
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: w('Minimum threshold', '最低门槛'),
              suffixText: '%',
              errorText:
                  enabled &&
                      (factors[key] == null ||
                          !factors[key]!.isFinite ||
                          factors[key]! < 0 ||
                          factors[key]! > 100)
                  ? w('Enter 0–100%', '请输入 0–100%')
                  : null,
            ),
            onChanged: (v) => setState(() => factors[key] = double.tryParse(v)),
          ),
          if (key == 'roic') ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              key: const ValueKey('mix-quality-years'),
              initialValue: qualityYears,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: w('Observation years', '观察年数'),
              ),
              items: [
                for (final n in [3, 4, 5])
                  DropdownMenuItem(
                    value: n,
                    child: Text(w('$n consecutive years', '连续 $n 年')),
                  ),
              ],
              onChanged: !enabled
                  ? null
                  : (v) => setState(() {
                      if (qualityPassYears == qualityYears) {
                        qualityPassYears = v!;
                      }
                      qualityYears = v!;
                      qualityPassYears = math.min(
                        qualityPassYears,
                        qualityYears,
                      );
                    }),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              key: ValueKey('mix-quality-pass-$qualityYears-$qualityPassYears'),
              initialValue: qualityPassYears,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: w('Years above threshold', '至少达标年数'),
              ),
              items: [
                for (var n = 1; n <= qualityYears; n++)
                  DropdownMenuItem(
                    value: n,
                    child: Text(
                      w('$n of $qualityYears years', '$qualityYears 年中至少 $n 年'),
                    ),
                  ),
              ],
              onChanged: !enabled
                  ? null
                  : (v) => setState(() => qualityPassYears = v!),
            ),
            const SizedBox(height: 10),
            caption(
              'All observation years need published data. Missing years do not pass.',
              '观察期每年都必须有当时已披露的数据，缺失不能算达标。',
            ),
          ],
          if (!enabled) ...[
            const SizedBox(height: 8),
            caption(
              'Not used in screening or ranking. Enable to add it back.',
              '不参与筛选和排序，开启即可重新加入。',
            ),
          ],
        ],
      ),
    );
  }

  Widget caption(String en, String zh) => Text(
    w(en, zh),
    style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
  );
  Widget section(String en, String zh, List<Widget> children, {Key? key}) =>
      Container(
        key: key,
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(en, zh),
              style: TextStyle(
                color: p.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: p.panel,
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 820,
        maxHeight: MediaQuery.sizeOf(context).height - 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w('Build your equity mix', '配置股票组合'),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      caption(
                        'One strategy or a mix. You decide the allocation.',
                        '单一策略或自由搭配，比例由你决定。',
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: w('Cancel', '取消'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final entry in <String, Map<String, double>>{
                          w('Guru only', '仅大师'): {'guru': 100},
                          w('Four-factor only', '仅四因子'): {'factors': 100},
                          w('Index only', '仅指数'): {'QQQ': 100},
                          w('Mix strategies', '混合策略'): {
                            'guru': 40,
                            'factors': 30,
                            'QQQ': 30,
                          },
                        }.entries)
                          OutlinedButton(
                            onPressed: () => preset(entry.value),
                            child: Text(entry.key),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    caption(
                      'These weights divide the equity part, before CTA and leverage. Set a source to 0% to exclude it.',
                      '以下比例分配股票部分，再叠加 CTA 和杠杆。设为 0% 即不使用该来源。',
                    ),
                    const SizedBox(height: 8),
                    for (final key in strategyEquityComponents)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (weights[key] ?? 0) > 0
                              ? p.accent.withValues(alpha: .08)
                              : p.background,
                          border: Border.all(
                            color: (weights[key] ?? 0) > 0
                                ? p.accent.withValues(alpha: .4)
                                : p.border,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              key == 'guru'
                                  ? Icons.people_outline
                                  : key == 'factors'
                                  ? Icons.fact_check_outlined
                                  : Icons.stacked_line_chart,
                              color: p.accent,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    strategyComponentName(context, key),
                                    style: TextStyle(
                                      color: p.text,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  caption(
                                    '${((weights[key] ?? 0) * (1 - widget.ctaWeight)).toStringAsFixed(1)}% of total portfolio before leverage',
                                    '杠杆前占总组合 ${((weights[key] ?? 0) * (1 - widget.ctaWeight)).toStringAsFixed(1)}%',
                                  ),
                                  if (key == 'factors' &&
                                      (weights[key] ?? 0) > 0)
                                    TextButton(
                                      onPressed: () async {
                                        final target =
                                            factorSectionKey.currentContext;
                                        if (target != null) {
                                          await Scrollable.ensureVisible(
                                            target,
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                          );
                                        }
                                      },
                                      child: Text(
                                        w('Configure factors →', '配置因子 →'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 100,
                              child: TextFormField(
                                key: ValueKey('mix-weight-$key'),
                                controller: controllers[key],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: w('Weight', '比例'),
                                  suffixText: '%',
                                ),
                                onChanged: (v) => setState(
                                  () => weights[key] = double.tryParse(v),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            w(
                              'Allocated: ${total.toStringAsFixed(2)}% / 100%',
                              '已分配：${total.toStringAsFixed(2)}% / 100%',
                            ),
                            style: TextStyle(
                              color: (total - 100).abs() < .000001
                                  ? p.accent
                                  : p.secondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed:
                              total > 0 &&
                                  weights.values.every(
                                    (v) => v != null && v.isFinite && v >= 0,
                                  )
                              ? () {
                                  final active = strategyEquityComponents
                                      .where((k) => (weights[k] ?? 0) > 0)
                                      .toList();
                                  final next = <String, double>{};
                                  double assigned = 0;
                                  for (final k in active) {
                                    final n = k == active.last
                                        ? 100 - assigned
                                        : ((weights[k]! / total * 10000)
                                                  .round() /
                                              100);
                                    next[k] = n;
                                    assigned += n;
                                  }
                                  preset(next);
                                }
                              : null,
                          child: Text(w('Normalize to 100%', '归一至 100%')),
                        ),
                      ],
                    ),
                    if ((weights['guru'] ?? 0) > 0)
                      section('Guru rules', '大师策略规则', [
                        caption(
                          'Select up to 10 managers. Their Top N common stocks are merged and equally weighted.',
                          '最多选择 10 位投资大师，各自前 N 大普通股合并去重后等权。',
                        ),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final n in [1, 3, 5, 10])
                              ChoiceChip(
                                label: Text(w('Top $n', '前 $n 名')),
                                selected: topN == n,
                                onSelected: (_) => setState(() => topN = n),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          decoration: InputDecoration(
                            labelText: w('Search Gurus', '搜索投资大师'),
                            prefixIcon: const Icon(Icons.search),
                          ),
                          onChanged: (v) =>
                              setState(() => query = v.toLowerCase()),
                        ),
                        SizedBox(
                          height: 215,
                          child: ListView(
                            children: [
                              for (final g in widget.catalog.where(
                                (g) =>
                                    text(g['name']).toLowerCase().contains(
                                      query,
                                    ) ||
                                    guruDisplayName(
                                      g,
                                      context.language,
                                    ).toLowerCase().contains(query),
                              ))
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: managers.contains(text(g['id'])),
                                  secondary: GuruAvatar(
                                    guru: {...g, 'avatarUrl': g['avatar']},
                                    palette: p,
                                    size: 34,
                                  ),
                                  title: Text(
                                    guruDisplayName(g, context.language),
                                  ),
                                  onChanged:
                                      managers.length < 10 ||
                                          managers.contains(text(g['id']))
                                      ? (v) => setState(() {
                                          if (v == true) {
                                            managers.add(text(g['id']));
                                          } else {
                                            managers.remove(text(g['id']));
                                          }
                                        })
                                      : null,
                                ),
                            ],
                          ),
                        ),
                        Text(
                          w(
                            '${managers.length} selected · at least one required',
                            '已选 ${managers.length} 位 · 至少选择一位',
                          ),
                          style: TextStyle(
                            color: managers.isEmpty ? p.secondary : p.accent,
                          ),
                        ),
                      ]),
                    if ((weights['factors'] ?? 0) > 0)
                      section('Configure factors', '单独配置因子', [
                        caption(
                          'Enable any one or more factors. A stock must pass all enabled factors using information available at each quarterly decision.',
                          '自由添加或取消因子，至少启用一项。股票须在每个季度满足当时已公开数据下的全部启用条件。',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          enabledFactors.isEmpty
                              ? w(
                                  'Select at least one factor to run this strategy.',
                                  '请至少启用一个因子才能运行此策略。',
                                )
                              : w(
                                  '${enabledFactors.length} / 4 factors enabled · match all selected',
                                  '已启用 ${enabledFactors.length} / 4 项 · 同时满足所选条件',
                                ),
                          style: TextStyle(
                            color: enabledFactors.isEmpty
                                ? p.secondary
                                : p.accent,
                          ),
                        ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth >= 620
                                ? (constraints.maxWidth - 12) / 2
                                : constraints.maxWidth;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final key in strategyFactorDefaults.keys)
                                  SizedBox(
                                    width: width,
                                    child: factorCard(key),
                                  ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            SizedBox(
                              width: 210,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                  'mix-rank-${enabledFactors.join('-')}-$rankBy',
                                ),
                                initialValue: rankBy,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: w(
                                    'Rank eligible stocks by',
                                    '合格股票排序依据',
                                  ),
                                ),
                                items: [
                                  for (final key
                                      in strategyFactorDefaults.keys.where(
                                        enabledFactors.contains,
                                      ))
                                    DropdownMenuItem(
                                      value: key,
                                      child: Text(
                                        strategyFactorName(context, key),
                                      ),
                                    ),
                                ],
                                onChanged: enabledFactors.isEmpty
                                    ? null
                                    : (v) => setState(() => rankBy = v),
                              ),
                            ),
                            SizedBox(
                              width: 210,
                              child: DropdownButtonFormField<int>(
                                initialValue: factorTopN,
                                decoration: InputDecoration(
                                  labelText: w(
                                    'Factor portfolio size',
                                    '四因子股票数量',
                                  ),
                                ),
                                items: [
                                  for (var n = 1; n <= 10; n++)
                                    DropdownMenuItem(
                                      value: n,
                                      child: Text(w('Top $n', '前 $n 名')),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => factorTopN = v!),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        caption(
                          'Filter first, then rank highest to lowest and select Top N. ROIC ranking uses the lowest year in the observation window. Disabled factors do not screen or rank stocks.',
                          '先过因子及估值门槛，再按所选指标从高到低选前 N 名。ROIC 排序取观察期最低年度值。已关闭的因子不参与筛选或排序。',
                        ),
                      ], key: factorSectionKey),
                    section('How your mix is tested', '组合如何回测', [
                      caption(
                        'Initial allocation, then quarterly rebalancing. Weights drift between rebalances. Index ETFs are exempt from company valuation filters.',
                        '期初建仓、随后每季度一起调仓，期间比例随价格漂移。指数 ETF 不套用个股估值过滤。',
                      ),
                      const SizedBox(height: 8),
                      caption(
                        'Eligible stocks fully share their own strategy allocation. An empty strategy blocks the run; its budget is never silently moved elsewhere. Historical holdings and exclusions remain inspectable.',
                        '可买股票分配各自策略的全部仓位。如果某个策略无可买股票，将停止回测，不擅自挪用其资金。可查看历史持仓及剔除原因。',
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                caption(
                  'Apply configures only. Run backtest when ready; Save rules keeps a reusable version.',
                  '应用只修改配置。准备好后运行回测，保存规则可供下次载入。',
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(w('Cancel', '取消')),
                    ),
                    FilledButton(
                      key: const ValueKey('apply-equity-mix'),
                      onPressed: valid
                          ? () => Navigator.pop(context, <String, dynamic>{
                              'managers': managers.toList()..sort(),
                              'topN': topN,
                              'equityMix': {
                                'weights': {
                                  for (final k in strategyEquityComponents)
                                    k: weights[k]! / 100,
                                },
                                'factors': {
                                  for (final key in factors.keys)
                                    key: savedFactor(key),
                                  'qualityYears': qualityYears,
                                  'qualityPassYears': qualityPassYears,
                                  'enabled': strategyFactorDefaults.keys
                                      .where(enabledFactors.contains)
                                      .toList(),
                                  'rankBy': rankBy,
                                  'topN': factorTopN,
                                },
                              },
                            })
                          : null,
                      child: Text(w('Apply mix', '应用组合')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
