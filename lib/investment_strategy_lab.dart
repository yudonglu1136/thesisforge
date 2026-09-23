part of 'main.dart';

bool strategyFailureHasSourceGap(Map<String, dynamic> failure) {
  if (failure['code'] != 'no_eligible_stocks') return false;
  return asList(failure['managerExclusions']).isNotEmpty ||
      asList(failure['exclusions']).any((row) => row['status'] != 'expensive');
}

// JSON transports may decode 10.0 as 10. Compare numeric values, not spelling.
bool strategyRuleValueEqual(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (k) => b.containsKey(k) && strategyRuleValueEqual(a[k], b[k]),
        );
  }
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => strategyRuleValueEqual(a[i], b[i]));
  }
  return a == b;
}

String strategyDefaultEndDate(String asOf, dynamic availableThrough) {
  final cutoff = text(availableThrough).trim();
  final parsed = DateTime.tryParse(cutoff);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(cutoff) ||
      parsed == null ||
      parsed.toIso8601String().substring(0, 10) != cutoff) {
    return asOf;
  }
  return cutoff.compareTo(asOf) < 0 ? cutoff : asOf;
}

class StrategyLabPanel extends StatefulWidget {
  const StrategyLabPanel({
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
  State<StrategyLabPanel> createState() => _StrategyLabPanelState();
}

class _StrategyLabPanelState extends State<StrategyLabPanel> {
  Map<String, dynamic>? catalog, result;
  Map<String, dynamic>? equityMix;
  Map<String, dynamic>? ctaPolicy;
  bool get canConfigureRun =>
      equityMix != null && number(asMap(equityMix?['weights'])['guru']) == 0 ||
      managers.isNotEmpty;
  double leverage = 1;
  final resultAnchor = GlobalKey();
  final managers = <String>{};
  int topN = 5, serial = 0, years = 5, ledgerIndex = -1;
  double premium = .3, ctaWeight = .3, cost = 10;
  bool valuation = true, loading = true, running = false, saving = false;
  String cta = 'KMLM',
      allocation = 'fully_invested',
      error = '',
      notice = '',
      tab = 'performance';
  late String start, end;
  bool _explicitDateRange = false, _defaultEndAdjusted = false;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  String runFailure(Object failure) {
    final code = failure is ApiRequestException ? failure.code : '';
    final cutoff = text(asMap(catalog?['storage'])['cutoff'], '—');
    if (code == 'strategy_database_cutoff_exceeded') {
      return w(
        'The strategy database is updated through $cutoff, but this test ends on $end. Refresh the source data before testing this date. Your rules and previous result are unchanged.',
        '策略数据库仅更新至 $cutoff，当前回测结束日为 $end。需先更新源数据，规则和原结果均已保留。',
      );
    }
    if (code == 'strategy_etf_cutoff_exceeded') {
      final etfs = asList(catalog?['etfs']).where((e) => e['ticker'] == cta);
      final last = etfs.isEmpty ? '—' : text(etfs.first['last']);
      return w(
        '$cta prices stop at $last, before the requested end $end. Refresh ETF prices; the test has not been shortened.',
        '$cta 行情仅到 $last，早于回测结束日 $end。需更新 ETF 行情，系统没有擅自缩短区间。',
      );
    }
    if (code == 'strategy_timeout' || code == 'strategy_busy') {
      return w(
        'The calculation is busy or timed out. Retry this run; your previous result is preserved.',
        '计算繁忙或超时，请重试本次回测；原结果已保留。',
      );
    }
    return w(
      'The backtest did not complete. Source data or the connection needs review. No result was replaced.',
      '回测未完成，需要检查源数据或连接。原结果未被替换。',
    );
  }

  bool get resultFullyInvested =>
      asMap(result?['rules'])['excludedAllocation'] == 'fully_invested';
  String pct(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(1)}%';
  String fmt(dynamic v) =>
      nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(2)}';
  TextStyle style([double size = 14, bool bold = false, Color? color]) =>
      TextStyle(
        color: color ?? p.text,
        fontSize: size,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        height: 1.4,
      );
  Map<String, dynamic> get rules => {
    'asOf': widget.asOf,
    'start': start,
    'end': end,
    'managers': managers.toList()..sort(),
    'topN': topN,
    'valuationEnabled': valuation,
    'maxPremium': premium,
    'excludedAllocation': allocation,
    'cta': cta,
    'ctaWeight': ctaWeight,
    if (cta != 'none' && ctaPolicy != null)
      'ctaPolicy': {
        ...ctaPolicy!,
        'minWeight': math.min(number(ctaPolicy!['minWeight']), ctaWeight),
      },
    'costBps': cost,
    'leverage': {'multiple': leverage, 'annualRate': .04, 'reset': 'filing'},
    if (equityMix != null) 'equityMix': strategyMixForRequest(equityMix!),
  };
  bool get dirty {
    if (result == null) return false;
    final old = asMap(result!['rules']);
    return rules.entries.any(
      (e) => !strategyRuleValueEqual(e.value, old[e.key]),
    );
  }

  @override
  void initState() {
    super.initState();
    end = widget.asOf;
    setWindow(5);
    unawaited(load());
  }

  void setWindow(int n) {
    years = n;
    final d = DateTime.parse(end);
    start = DateTime(
      d.year - n,
      d.month,
      d.day,
    ).toIso8601String().substring(0, 10);
  }

  @override
  void didUpdateWidget(covariant StrategyLabPanel old) {
    super.didUpdateWidget(old);
    if (old.asOf != widget.asOf || old.api != widget.api) {
      if (old.asOf != widget.asOf) _explicitDateRange = false;
      if (!_explicitDateRange) {
        end = widget.asOf;
        setWindow(years);
        _defaultEndAdjusted = false;
      }
      result = null;
      unawaited(load());
    }
  }

  @override
  void dispose() {
    serial++;
    super.dispose();
  }

  Future<void> load() async {
    final ticket = ++serial;
    setState(() {
      loading = true;
      catalog = null;
      running = false;
      error = '';
    });
    try {
      final v = await widget.api.getJson(
        '/api/investment/strategy-lab?asOf=${widget.asOf}',
      );
      if (!mounted || ticket != serial) return;
      if (v['version'] != 'strategy-lab-catalog-v1' ||
          v['asOf'] != widget.asOf) {
        throw StateError('contract');
      }
      setState(() {
        catalog = v;
        loading = false;
        // Metadata arrives asynchronously. Only initialize untouched defaults;
        // never rewrite a user's dates, a saved rule or a completed result.
        if (!_explicitDateRange && result == null) {
          end = strategyDefaultEndDate(
            widget.asOf,
            asMap(v['storage'])['cutoff'],
          );
          setWindow(years);
          _defaultEndAdjusted = end != widget.asOf;
        }
        managers.removeWhere(
          (id) => !asList(v['managers']).any((m) => m['id'] == id),
        );
      });
    } catch (_) {
      if (mounted && ticket == serial) {
        setState(() {
          loading = false;
          error = w(
            'Strategy data could not be loaded. Please retry.',
            '策略数据加载失败，请重试。',
          );
        });
      }
    }
  }

  Future<void> run() async {
    final ticket = ++serial, request = Map<String, dynamic>.from(rules);
    setState(() {
      running = true;
      error = '';
      notice = '';
    });
    try {
      final v = await widget.api.postJson(
        '/api/investment/strategy-backtests',
        request,
      );
      if (!mounted || ticket != serial) return;
      if (v['version'] != 'guru-valuation-cta-v1' ||
          v['rules']?['asOf'] != widget.asOf ||
          request.entries.any(
            (e) => !strategyRuleValueEqual(e.value, v['rules']?[e.key]),
          )) {
        throw StateError('contract');
      }
      setState(() {
        result = v;
        running = false;
        ledgerIndex = -1;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = resultAnchor.currentContext;
        if (mounted && ticket == serial && target != null) {
          unawaited(
            Scrollable.ensureVisible(
              target,
              duration: const Duration(milliseconds: 250),
              alignment: .05,
            ),
          );
        }
      });
    } catch (failure) {
      if (mounted && ticket == serial) {
        setState(() {
          running = false;
          error = runFailure(failure);
        });
      }
    }
  }

  Future<void> save() async {
    final captured = Map<String, dynamic>.from(rules);
    final controller = TextEditingController(
      text: equityMix == null
          ? w('My Guru + CTA strategy', '我的大佬 + CTA 策略')
          : w('My equity mix', '我的混合组合'),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(w('Save these rules', '保存本组规则')),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: InputDecoration(labelText: w('Strategy name', '策略名称')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(w('Cancel', '取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(w('Save', '保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted || captured['asOf'] != widget.asOf) return;
    setState(() {
      saving = true;
      error = '';
    });
    try {
      final v = await widget.api.postJson('/api/investment/strategy-rules', {
        ...captured,
        'name': name,
        'operationId': 'strategy_${DateTime.now().microsecondsSinceEpoch}',
      });
      if (mounted) {
        setState(() {
          saving = false;
          notice = w(
            'Private rule version saved. Existing strategies and portfolios are unchanged.',
            '已保存私人规则版本，原策略和组合未被修改。',
          );
          catalog!['saved'] = [...asList(catalog?['saved']), v];
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = w('Rules were not saved. Please retry.', '规则未保存，请重试。');
        });
      }
    }
  }

  void restore(Map<String, dynamic> record) {
    final r = asMap(record['rules']);
    setState(() {
      managers
        ..clear()
        ..addAll((r['managers'] as List).cast<String>());
      topN = number(r['topN']).toInt();
      equityMix = r['equityMix'] is Map ? asMap(r['equityMix']) : null;
      valuation = r['valuationEnabled'] == true;
      premium = number(r['maxPremium']);
      cta = text(r['cta']);
      ctaWeight = number(r['ctaWeight']);
      ctaPolicy = r['ctaPolicy'] is Map ? asMap(r['ctaPolicy']) : null;
      leverage = nullableNumber(asMap(r['leverage'])['multiple']) ?? 1;
      allocation = text(r['excludedAllocation']);
      cost = number(r['costBps']);
      start = text(r['start']);
      end = text(r['end']);
      _explicitDateRange = true;
      _defaultEndAdjusted = false;
      notice = w(
        r['hedge'] != null && r['hedge']['type'] != 'none'
            ? 'Legacy hedge rules retained in the saved version. This builder now uses leverage; run and save a new version.'
            : 'Saved rules loaded. Run to calculate against current source data.',
        r['hedge'] != null && r['hedge']['type'] != 'none'
            ? '旧版对冲规则仍保留在原版本。当前构建器已改为杠杆，请重新回测并保存新版本。'
            : '已载入保存的规则，点击回测按当前数据重新计算。',
      );
    });
  }

  Widget copy(String en, String zh, {double size = 13, Color? color}) =>
      Text(w(en, zh), style: style(size, false, color ?? p.muted));
  Widget panel(List<Widget> children, {double padding = 20}) => DecoratedBox(
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(color: p.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
  Widget button(
    String en,
    String zh,
    VoidCallback? action, {
    bool primary = false,
    IconData? icon,
  }) => primary
      ? FilledButton.icon(
          onPressed: action,
          icon: Icon(icon ?? Icons.play_arrow_rounded, size: 18),
          label: Text(w(en, zh)),
          style: FilledButton.styleFrom(
            backgroundColor: p.accent,
            foregroundColor: p.background,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
          ),
        )
      : OutlinedButton.icon(
          onPressed: action,
          icon: Icon(icon ?? Icons.bookmark_add_outlined, size: 17),
          label: Text(w(en, zh)),
          style: OutlinedButton.styleFrom(
            foregroundColor: p.text,
            side: BorderSide(color: p.border),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16),
          ),
        );
  Widget step(String n, String en, String zh, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(n, style: style(13, true, p.accent)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(w(en, zh), style: style(17, true))),
        Icon(icon, size: 20, color: p.muted),
      ],
    ),
  );
  Future<void> chooseManager() async {
    var query = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => Dialog(
          child: SizedBox(
            width: 540,
            height: 560,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          w('Choose your Gurus', '选择大佬'),
                          style: style(22, true),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  copy(
                    'Select up to 10. Duplicated stocks are combined.',
                    '最多选 10 位，重复股票将合并。',
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    autofocus: true,
                    onChanged: (v) => refresh(() => query = v.toLowerCase()),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      labelText: w('Search manager', '搜索经理'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final g in asList(catalog?['managers']).where(
                          (g) => text(g['name']).toLowerCase().contains(query),
                        ))
                          CheckboxListTile(
                            value: managers.contains(text(g['id'])),
                            secondary: GuruAvatar(
                              guru: {...g, 'avatarUrl': g['avatar']},
                              palette: p,
                              size: 40,
                            ),
                            title: Text(
                              text(g['name']),
                              style: style(14, true),
                            ),
                            subtitle: Text(
                              '${g['quarters']} ${w('reported quarters', '个披露季度')}',
                              style: style(12, false, p.muted),
                            ),
                            onChanged: (v) {
                              setState(() {
                                if (v == false) {
                                  managers.remove(text(g['id']));
                                } else if (managers.length < 10) {
                                  managers.add(text(g['id']));
                                }
                              });
                              refresh(() {});
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: button(
                      'Done (${managers.length})',
                      '完成（${managers.length}）',
                      () => Navigator.pop(ctx),
                      primary: true,
                      icon: Icons.check,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> configureMix() async {
    final configured = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => LanguageScope(
        language: context.language,
        child: StrategyMixDialog(
          palette: p,
          catalog: asList(catalog?['managers']),
          managers: managers,
          topN: topN,
          ctaWeight: ctaWeight,
          initial: equityMix,
        ),
      ),
    );
    if (!mounted || configured == null) return;
    setState(() {
      equityMix = asMap(configured['equityMix']);
      managers
        ..clear()
        ..addAll((configured['managers'] as List).cast<String>());
      topN = number(configured['topN']).toInt();
      allocation = 'fully_invested';
      notice = w(
        'Equity mix applied. Run backtest, then save rules to reuse this configuration.',
        '股票组合已应用，点击回测，保存规则后可在下次载入。',
      );
    });
  }

  Widget managerCard() => Semantics(
    button: true,
    label: w('Configure equity mix', '配置股票组合'),
    child: InkWell(
      onTap: configureMix,
      borderRadius: BorderRadius.circular(14),
      child: panel([
        step('1', 'Build your equity mix', '配置股票组合', Icons.tune),
        copy(
          'Guru strategies, quality factors or index ETFs. One source or your own mix.',
          '大佬策略、质量四因子、指数 ETF，可单选或自由搭配。',
        ),
        const SizedBox(height: 16),
        for (final key in strategyEquityComponents.where(
          (k) => equityMix == null
              ? k == 'guru'
              : number(asMap(equityMix?['weights'])[k]) > 0,
        ))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strategyComponentName(context, key),
                    style: style(14, true),
                  ),
                ),
                Text(
                  equityMix == null
                      ? '100%'
                      : pct(asMap(equityMix?['weights'])[key]),
                  style: style(18, true, p.accent),
                ),
              ],
            ),
          ),
        if (equityMix != null &&
            number(asMap(equityMix?['weights'])['factors']) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              strategyFactorSummary(context, equityMix!),
              style: style(11, false, p.muted),
            ),
          ),
        if (managers.isNotEmpty &&
            (equityMix == null ||
                number(asMap(equityMix?['weights'])['guru']) > 0))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in asList(
                  catalog?['managers'],
                ).where((g) => managers.contains(text(g['id']))))
                  Chip(
                    avatar: GuruAvatar(
                      guru: {...g, 'avatarUrl': g['avatar']},
                      palette: p,
                      size: 24,
                    ),
                    label: Text(text(g['name']), style: style(11)),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        button('Configure mix', '配置组合', configureMix, icon: Icons.tune),
        if (equityMix == null)
          button(
            'Choose Gurus',
            '选择大佬',
            chooseManager,
            icon: Icons.people_outline,
          ),
        const SizedBox(height: 12),
        copy(
          '${((1 - ctaWeight) * 100).round()}% of total portfolio · before leverage',
          '占总组合 ${((1 - ctaWeight) * 100).round()}% · 杠杆前',
          size: 11,
        ),
        copy(
          equityMix == null
              ? 'Guru Top $topN · disclosure rebalances. Configure a mix for quarterly rebalancing.'
              : '${number(asMap(equityMix?['weights'])['guru']) > 0 ? 'Guru Top $topN per manager · ' : ''}Quarterly rebalancing · fully invested within each source.',
          equityMix == null
              ? '大佬 Top $topN · 披露后调仓。配置混合组合后按季度统一调仓。'
              : '${number(asMap(equityMix?['weights'])['guru']) > 0 ? '每位大佬 Top $topN · ' : ''}季度统一调仓 · 各策略内部满仓。',
          size: 11,
        ),
      ]),
    ),
  );

  Widget valuationCard() => panel([
    step('2', 'Set a price discipline', '设置估值纪律', Icons.tune),
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: valuation,
      onChanged: (v) => setState(() => valuation = v),
      title: Text(w('Valuation filter', '启用估值过滤'), style: style(14, true)),
    ),
    copy(
      'Exclude when price is above fair value by more than',
      '剔除股价高于公允价值超过以下幅度的股票',
    ),
    Row(
      children: [
        Text(
          '${(premium * 100).round()}%',
          style: style(28, true, valuation ? p.accent : p.muted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: [
              for (final n in [.15, .30, .50])
                ChoiceChip(
                  label: Text('${(n * 100).round()}%'),
                  selected: premium == n,
                  onSelected: valuation
                      ? (_) => setState(() => premium = n)
                      : null,
                ),
            ],
          ),
        ),
      ],
    ),
    Slider(
      value: premium,
      min: 0,
      max: 1,
      divisions: 100,
      label: pct(premium),
      semanticFormatterCallback: (v) => pct(v),
      onChanged: valuation ? (v) => setState(() => premium = v) : null,
    ),
    DropdownButtonFormField<String>(
      key: ValueKey('allocation-$allocation'),
      initialValue: allocation,
      isExpanded: true,
      decoration: InputDecoration(labelText: w('Allocation policy', '资金分配规则')),
      items: [
        DropdownMenuItem(
          value: 'fully_invested',
          child: Text(
            w('Fully invest in eligible stocks', '可买股票等权满仓'),
            style: style(12),
          ),
        ),
        DropdownMenuItem(
          value: 'redistribute',
          child: Text(
            w('Legacy: redistribute expensive slots', '旧规则：仅分配高估剔除份额'),
            style: style(12),
          ),
        ),
        DropdownMenuItem(
          value: 'cash',
          child: Text(
            w('Keep the allocation in cash', '对应仓位留现金'),
            style: style(12),
          ),
        ),
      ],
      onChanged: equityMix != null || ctaPolicy != null
          ? null
          : (v) => setState(() => allocation = v!),
    ),
    const SizedBox(height: 12),
    if (equityMix != null)
      copy(
        'Applies to Guru and factor stocks only. QQQ, SPY and SCHD keep their allocation; no individual-company DCF filter.',
        '仅过滤大佬及四因子个股，QQQ、SPY、SCHD 保留既定比例，不套用个股 DCF。',
        size: 11,
      ),
    copy(
      ctaPolicy != null && cta != 'none'
          ? 'Eligible stocks share their source allocation at equity rebalances. The CTA policy independently changes the stock/CTA split. No eligible stocks means no completed backtest; cash is not substituted.'
          : equityMix != null
          ? 'Eligible stocks share their own strategy allocation equally. Component budgets and CTA stay fixed. An empty component stops the run; no cash is substituted.'
          : allocation == 'fully_invested'
          ? 'Missing filings, prices or models and overpriced stocks are excluded. Remaining eligible stocks share the stock allocation equally; CTA stays fixed. No eligible stocks means no completed backtest.'
          : 'Price / fair value − 1. Uses the prior session’s available model; missing estimates stay cash.',
      ctaPolicy != null && cta != 'none'
          ? '股票换仓时，各来源内可买股票分配该来源资金。CTA 规则独立调整股票与 CTA 比例。若无可买股票，停止回测，不以现金替代。'
          : equityMix != null
          ? '各策略内可买股票等权分配该策略全部资金，来源配比和 CTA 不变。若某个来源全部无法买入，停止回测，不以现金替代。'
          : allocation == 'fully_invested'
          ? '跳过缺申报、价格、模型或高估的候选，其余可买股票等分股票仓位；CTA 比例不变。若没有可买股票，明确停止回测。'
          : '股价 / 公允价值 − 1。使用前一交易日可得模型，缺少估值的仓位留现金。',
      size: 11,
    ),
  ]);
  Future<void> configureCta() async {
    if (cta == 'none') return;
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => LanguageScope(
        language: context.language,
        child: StrategyCtaDialog(
          palette: p,
          weight: ctaWeight,
          initial: ctaPolicy == null
              ? null
              : {
                  ...ctaPolicy!,
                  'minWeight': math.min(
                    number(ctaPolicy!['minWeight']),
                    ctaWeight,
                  ),
                },
        ),
      ),
    );
    if (!mounted || value == null) return;
    setState(() {
      ctaPolicy = value;
      allocation = 'fully_invested';
      notice = w(
        'CTA rules applied. Run backtest to compare; Save rules keeps this configuration in your account.',
        'CTA 规则已应用。运行回测查看对比；保存规则可在账户中保留此配置。',
      );
    });
  }

  Widget ctaCard() => Material(
    color: Colors.transparent,
    child: InkWell(
      key: const ValueKey('strategy-cta-card'),
      onTap: cta == 'none' ? null : configureCta,
      borderRadius: BorderRadius.circular(14),
      child: panel([
        step('3', 'Add a CTA sleeve', '配置 CTA 部分', Icons.balance_outlined),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final s in ['none', 'KMLM', 'DBMF'])
              ChoiceChip(
                label: Text(s == 'none' ? w('No CTA', '不加 CTA') : s),
                selected: cta == s,
                onSelected: (_) => setState(() {
                  cta = s;
                  ctaWeight = s == 'none'
                      ? 0
                      : ctaWeight == 0
                      ? 0.3
                      : ctaWeight;
                }),
              ),
          ],
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(
              child: copy('CTA allocation · total portfolio', 'CTA 占整个组合'),
            ),
            Text(
              '${(ctaWeight * 100).round()}%',
              style: style(27, true, p.accent),
            ),
          ],
        ),
        Slider(
          value: ctaWeight,
          min: 0,
          max: .8,
          divisions: 16,
          label: pct(ctaWeight),
          semanticFormatterCallback: (v) => pct(v),
          onChanged: cta == 'none'
              ? null
              : (v) => setState(() => ctaWeight = v == 0 ? 0.05 : v),
        ),
        Wrap(
          spacing: 7,
          children: [
            for (final n in [.3, .5])
              ChoiceChip(
                label: Text('${(n * 100).round()}%'),
                selected: ctaWeight == n,
                onSelected: cta == 'none'
                    ? null
                    : (_) => setState(() => ctaWeight = n),
              ),
          ],
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              Expanded(
                flex: ((1 - ctaWeight) * 100).round(),
                child: Container(height: 8, color: p.accent),
              ),
              if (ctaWeight > 0)
                Expanded(
                  flex: (ctaWeight * 100).round(),
                  child: Container(height: 8, color: p.secondary),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        copy(
          '${((1 - ctaWeight) * 100).round()}% ${allocation == 'fully_invested' ? 'stocks' : 'stocks / cash'} · ${(ctaWeight * 100).round()}% ${cta == 'none' ? 'CTA' : cta}',
          '${((1 - ctaWeight) * 100).round()}% ${allocation == 'fully_invested' ? '股票' : '股票 / 现金'} · ${(ctaWeight * 100).round()}% ${cta == 'none' ? 'CTA' : cta}',
          size: 12,
        ),
        const SizedBox(height: 8),
        Text(
          strategyCtaMode(context, ctaPolicy),
          style: style(13, true, p.accent),
        ),
        if (ctaPolicy?['mode'] == 'tranches')
          copy(
            'Each tranche ${pct(ctaPolicy?['trancheWeight'])} of target weight · floor ${pct(math.min(number(ctaPolicy?['minWeight']), ctaWeight))} · ${ctaPolicy?['cooldownSessions']} sessions cooldown.',
            '每批调整目标 ${pct(ctaPolicy?['trancheWeight'])} · 下限 ${pct(math.min(number(ctaPolicy?['minWeight']), ctaWeight))} · 冷却 ${ctaPolicy?['cooldownSessions']} 个交易日。',
            size: 11,
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: cta == 'none' ? null : configureCta,
          icon: const Icon(Icons.tune, size: 18),
          label: Text(w('Configure CTA rules', '配置 CTA 规则')),
        ),
        const SizedBox(height: 8),
        copy(
          ctaPolicy != null
              ? 'Independent CTA policy. Equity rotations preserve CTA units; weights drift. Real total-return ETF history only.'
              : equityMix != null
              ? 'Resets quarterly with your equity mix; weights drift between rebalances. Real ETF history only.'
              : 'Resets at disclosure rebalances; weights drift between them. Real ETF history only.',
          ctaPolicy != null
              ? '独立 CTA 规则。股票换仓保留 CTA 份额，权重随市场漂移。仅用 ETF 真实含分红复权历史。'
              : equityMix != null
              ? '与股票组合每季度一起重置，期间权重漂移。仅使用 ETF 真实历史。'
              : '披露调仓时恢复目标比例，其间权重随市场变化。只用真实 ETF 历史。',
          size: 11,
        ),
        if (cta != 'none') ...[
          const SizedBox(height: 8),
          for (final e in asList(
            catalog?['etfs'],
          ).where((e) => e['ticker'] == cta))
            copy(
              e['available'] == true
                  ? '$cta: ${e['first']} → ${e['last']}'
                  : '$cta adjusted prices are not connected.',
              '$cta${e['available'] == true ? '：${e['first']} → ${e['last']}' : '：复权价格尚未接入。'}',
              size: 11,
              color: e['available'] == true ? p.muted : p.secondary,
            ),
        ],
      ]),
    ),
  );
  Widget leverageCard() => KeyedSubtree(
    key: const Key('strategy-leverage-step'),
    child: panel([
      step('4', 'Add leverage', '加入杠杆', Icons.trending_up),
      const SizedBox(height: 18),
      copy('Scale the stocks + CTA allocation', '放大股票 + CTA 配置'),
      const SizedBox(height: 8),
      Text('${leverage.toStringAsFixed(2)}×', style: style(29, true, p.accent)),
      Slider(
        key: const Key('leverage-slider'),
        value: leverage,
        min: 1,
        max: 2,
        divisions: 20,
        label: '${leverage.toStringAsFixed(2)}×',
        onChanged: (v) => setState(() => leverage = v),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in [1.0, 1.25, 1.5, 2.0])
            ChoiceChip(
              key: ValueKey('leverage-$v'),
              label: Text(v == 1 ? w('1× · Off', '1× · 不加杠杆') : '$v×'),
              selected: leverage == v,
              onSelected: (_) => setState(() => leverage = v),
            ),
        ],
      ),
      const SizedBox(height: 18),
      Text(
        w('Financing rate · 4% / year', '融资利率 · 4% / 年'),
        style: style(15, true),
      ),
      const SizedBox(height: 8),
      copy(
        'Per \$100 equity: up to \$${(leverage * 100).round()} invested, \$${((leverage - 1) * 100).round()} borrowed.',
        '每 100 美元本金：最多配置 ${(leverage * 100).round()} 美元资产，借款 ${((leverage - 1) * 100).round()} 美元。',
      ),
      const SizedBox(height: 10),
      copy(
        equityMix != null
            ? 'No cash allocation. Exposure above 1× is financed at 4% per year. Leverage resets quarterly and drifts between rebalances.'
            : allocation == 'fully_invested'
            ? 'No cash allocation. Borrowing finances the exposure above 1× at 4% per year. Exposure resets at disclosure rebalances and drifts in between.'
            : 'Filtered cash offsets borrowing. Interest accrues over calendar days. Exposure resets at disclosure rebalances and drifts in between.',
        equityMix != null
            ? '不配置现金，超过 1 倍的敞口按 4% 年息融资。每季度重设杠杆，期间随净值漂移。'
            : allocation == 'fully_invested'
            ? '不配置现金。超过 1 倍的敞口按年利率 4% 融资；披露调仓时重设杠杆，期间随净值漂移。'
            : '过滤后现金抵减借款。利息按日历天数计算；披露调仓时重设杠杆，期间随净值漂移。',
        size: 11,
      ),
      const SizedBox(height: 10),
      copy(
        'Losses are amplified too. No broker margin-call simulation.',
        '亏损也会放大，不模拟券商追保或强平。',
        size: 11,
        color: p.secondary,
      ),
    ]),
  );

  Widget leverageSummary() {
    final r = asMap(asMap(result?['results'])['leveraged']);
    final f = asMap(r['financing']);
    return panel([
      Text(
        w('Leverage after financing costs', '扣除融资成本后的杠杆表现'),
        style: style(20, true),
      ),
      const SizedBox(height: 10),
      copy(
        '4% annual borrowing · ACT/365 · costs paid from portfolio equity',
        '借款年利率 4% · ACT/365 · 费用从组合净值扣除',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 28,
        runSpacing: 12,
        children: [
          copy(
            'Interest / initial \$100: ${fmt(number(f['interestPaid']) * 100)}',
            '每 100 美元初始本金累计利息：${fmt(number(f['interestPaid']) * 100)}',
          ),
          copy(
            'Trading costs / initial \$100: ${fmt(number(f['costPaid']) * 100)}',
            '每 100 美元初始本金累计交易费：${fmt(number(f['costPaid']) * 100)}',
          ),
        ],
      ),
      const SizedBox(height: 12),
      copy(
        'Compare the leveraged curve with the unchanged 1× blend. Cash earns 0%; 4% is a fixed research assumption, not an IBKR quote.',
        '与未改变的 1× 混合组合对比。现金收益为 0%；4% 是固定研究假设，不是 IBKR 实时报价。',
        size: 12,
      ),
      ExpansionTile(
        title: Text(w('Borrowing & interest ledger', '借款与利息账本')),
        tilePadding: EdgeInsets.zero,
        children: [
          for (final t in asList(r['trades']))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: copy(
                '${t['date']} · exposure ${pct(t['riskyWeight'])} · loan / initial \$100 ${fmt(number(t['borrowed']) * 100)} · interest since prior rebalance ${fmt(number(t['interestSincePriorRebalance']) * 100)}',
                '${t['date']} · 敞口 ${pct(t['riskyWeight'])} · 每 100 美元初始本金借款 ${fmt(number(t['borrowed']) * 100)} · 距上次调仓利息 ${fmt(number(t['interestSincePriorRebalance']) * 100)}',
                size: 12,
              ),
            ),
        ],
      ),
    ]);
  }

  Future<void> dateRange() async {
    final value = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2010),
      lastDate: DateTime.parse(widget.asOf),
      initialDateRange: DateTimeRange(
        start: DateTime.parse(start),
        end: DateTime.parse(end),
      ),
    );
    if (value != null && mounted) {
      setState(() {
        start = value.start.toIso8601String().substring(0, 10);
        end = value.end.toIso8601String().substring(0, 10);
        _explicitDateRange = true;
        _defaultEndAdjusted = false;
      });
    }
  }

  String failure(Map<String, dynamic> f) {
    final guru = asList(
      catalog?['managers'],
    ).where((g) => g['id'] == f['guruId']).firstOrNull;
    final detail = [
      guru?['name'] ?? f['guruId'],
      if (f['component'] != null)
        strategyComponentName(context, text(f['component'])),
      f['reportDate'],
      f['ticker'],
      if (f['tickers'] is List) (f['tickers'] as List).join(', '),
      f['date'],
    ].where((v) => v != null).join(' · ');
    final message = switch (text(f['code'])) {
      'no_eligible_factor_stocks' => w(
        'No stocks pass the enabled factors and valuation rules at this PIT date. This component cannot be fully invested; its allocation has not been transferred to another source.',
        '该历史节点没有通过已启用因子和估值规则的股票，此部分无法满仓，系统未将资金挪到其他来源。',
      ),
      'index_history_missing' => w(
        'The selected index ETF has no verified price at the requested start. Its real fund history is required; no substitute or shorter period is used.',
        '所选指数 ETF 在开始日期没有核验行情，需要真实基金历史；未替换标的或缩短区间。',
      ),
      'no_eligible_stocks' when strategyFailureHasSourceGap(f) => w(
        'Some required filing, model or price evidence is unavailable. This is not solely a valuation-filter result. Review the specific gaps below; no substitute curve is shown.',
        '所需申报、模型或行情证据存在缺口，并非单纯因为估值筛选太严。请查看下方具体原因；不展示替代曲线。',
      ),
      'no_eligible_stocks' => w(
        'No stocks can be bought under these rules on this date. A no-cash portfolio cannot be constructed. Adjust the filter, managers or start date; no cash-only return is substituted.',
        '该日期没有任何符合规则的可买股票，无法构建无现金组合。请调整估值筛选、经理或开始日期；不会用空仓收益替代结果。',
      ),
      'cash_settlement_requires_reinvestment' => w(
        'An acquisition paid out cash between rebalances. Reinvestment is not verified for this interval, so no completed no-cash curve is shown.',
        '持仓在两次调仓之间因收购转为现金，该区间再投资尚未核验，因此不展示为已完成的无现金曲线。',
      ),
      'filing_classification_unverified' => w(
        'The original filing’s stock, option and debt classifications have not been verified. This is a source-data issue, not an invalid strategy setting.',
        '该原始申报的普通股、期权和债券分类尚未核验。这是源数据问题，不是策略参数设置错误。',
      ),
      'manager_identity_mismatch' => w(
        'The filer has not been verified as this manager. This manager is blocked until the identity is reconciled.',
        '申报主体尚未核实为该经理，在身份完成对账前不能使用其持仓回测。',
      ),
      'leverage_equity_exhausted' || 'leverage_cost_exhausted' => w(
        'Equity was exhausted under these leverage assumptions. No completed leveraged curve or limited-loss floor is shown. Lower leverage and rerun.',
        '该杠杆假设下本金已耗尽。不显示完成的杠杆曲线，也不会把损失强行截断；请降低杠杆后重跑。',
      ),
      'original_filing_missing' => w(
        'The original quarterly filing has not passed source reconciliation. Choose a later start; a later amendment cannot replace what was public then.',
        '该季度原始申报尚未通过来源对账，请推迟开始日期；后来的修订不能替代当时已公开的持仓。',
      ),
      'amendment_requires_reconciliation' => w(
        'This 13F amendment has not been reconciled to the original book. Choose a later start; a partial amendment is not a complete portfolio.',
        '该 13F 修订申报尚未与原始组合对账，请推迟开始日期；不能把补充申报当作完整组合。',
      ),
      'cta_history_missing' => w(
        'The CTA ETF has no adjusted observation for this session. Choose a covered range.',
        'CTA ETF 在该交易日缺少复权价格，请选择有覆盖的区间。',
      ),
      'execution_coverage_below_90' => w(
        'Fewer than 90% of selected stock slots have verified execution data. The test is blocked.',
        '选中股票的可验证执行覆盖率不足 90%，本次回测被阻止。',
      ),
      'manager_history_unavailable' => w(
        'No filing for this manager was available at the requested start.${f['firstStoredPublicDate'] == null ? '' : ' The first stored filing was public on ${f['firstStoredPublicDate']}.'} Reducing Top N will not create earlier history. Your dates have not been changed.',
        '所选开始日期尚无该经理可用的申报。${f['firstStoredPublicDate'] == null ? '' : '库中最早申报的公开日期为 ${f['firstStoredPublicDate']}。'}减少 Top N 不能补出更早历史。系统没有修改你的日期。',
      ),
      'insufficient_top_n_extract' => w(
        'This stored extract has too few verified holdings for Top N. The full original filing needs recovery; missing stocks are not dropped or replaced.',
        '现有摘录的已核验持仓不足 Top N，需要补齐原始申报；不会删除或替换缺失股票。',
      ),
      'missing_active_price' || 'missing_execution_price' => w(
        'An active holding is missing an adjusted price. No zero return or forward fill is used.',
        '活动持仓缺少复权价格，不会填入零收益或沿用旧价。',
      ),
      'stale_manager_filing' => w(
        'A selected manager’s filing is too old in this window.',
        '所选经理在这个区间内的披露过旧。',
      ),
      'stale_benchmark' || 'missing_benchmark_price' => w(
        'The benchmark does not cover the requested sessions.',
        '基准数据未覆盖所请求的交易日。',
      ),
      _ => w(
        'Source data needs review for this configuration. No complete curve is claimed.',
        '当前规则所需数据仍需核查，不展示为完整有效曲线。',
      ),
    };
    return '$message${detail.isEmpty ? '' : '\n$detail'}';
  }

  String decision(String s) => switch (s) {
    'included' => w('Included', '纳入'),
    'expensive' => w('Over premium limit', '超过估值上限'),
    'no_model' =>
      resultFullyInvested
          ? w('No model · redistributed', '无模型 · 已重新分配')
          : w('No model → cash', '无模型 → 现金'),
    'comparison_price_missing' =>
      resultFullyInvested
          ? w('No comparison price · redistributed', '缺比较价格 · 已重新分配')
          : w('No comparison price → cash', '缺比较价格 → 现金'),
    'currency_unverified' =>
      resultFullyInvested
          ? w('Currency mismatch · redistributed', '币种不可比 · 已重新分配')
          : w('Currency not comparable → cash', '币种不可比 → 现金'),
    'stale_model' =>
      resultFullyInvested
          ? w('Stale model · redistributed', '模型过旧 · 已重新分配')
          : w('Stale model → cash', '模型过旧 → 现金'),
    'execution_unavailable' =>
      resultFullyInvested
          ? w('No execution price · redistributed', '缺执行价格 · 已重新分配')
          : w('No execution → cash', '无法执行 → 现金'),
    'corporate_action_cash' => w('Acquisition cash', '收购转现金'),
    _ => w('Needs review', '需要核查'),
  };
  Widget audit() {
    final rows = asList(result?['ledger']);
    if (rows.isEmpty) {
      return panel([
        copy(
          'No rebalance could be constructed for these inputs.',
          '这些输入暂时无法构建调仓记录。',
        ),
      ]);
    }
    final index = ledgerIndex < 0
            ? rows.length - 1
            : ledgerIndex.clamp(0, rows.length - 1),
        event = rows[index];
    return panel([
      Row(
        children: [
          Expanded(
            child: Text(
              w('Why these holdings?', '为什么纳入这些股票？'),
              style: style(20, true),
            ),
          ),
          Text(
            '${index + 1} / ${rows.length}',
            style: style(12, false, p.muted),
          ),
        ],
      ),
      const SizedBox(height: 14),
      DropdownButtonFormField<int>(
        key: ValueKey('rebalance-$index'),
        initialValue: index,
        isExpanded: true,
        decoration: InputDecoration(labelText: w('Rebalance close', '调仓收盘日')),
        items: [
          for (var i = rows.length - 1; i >= 0; i--)
            DropdownMenuItem(
              value: i,
              child: Text(
                '${rows[i]['executionDate']} · ${asList(rows[i]['holdings']).length} ${w('selected stocks', '只选中股票')}',
                style: style(13),
              ),
            ),
        ],
        onChanged: (i) => setState(() => ledgerIndex = i!),
      ),
      const SizedBox(height: 12),
      copy(
        'Decision inputs as of ${event['decisionDate']} · no same-close information',
        '决策数据截至 ${event['decisionDate']} · 不使用调仓当日收盘才产生的信息',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (final f in asList(event['filings']))
            Chip(
              avatar: GuruAvatar(
                guru: {
                  'id': f['guruId'],
                  'avatarUrl': '/guru-avatars/${f['guruId']}.png',
                },
                palette: p,
                size: 22,
              ),
              label: Text(
                '${f['reportDate']} · ${w('public', '公开于')} ${f['publicDate']}',
                style: style(11),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      for (final h in asList(event['holdings']))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: LayoutBuilder(
            builder: (ctx, c) {
              final heading = Row(
                children: [
                  StockLogo(ticker: text(h['ticker']), palette: p, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text(h['ticker']).isEmpty
                          ? text(h['cusip'])
                          : text(h['ticker']),
                      style: style(15, true),
                    ),
                  ),
                  Text(
                    pct(h['targetWeight']),
                    style: style(17, true, p.accent),
                  ),
                ],
              );
              final details = Wrap(
                spacing: 16,
                runSpacing: 5,
                children: [
                  Text(
                    decision(text(h['status'])),
                    style: style(
                      12,
                      false,
                      h['status'] == 'included' ? p.accent : p.secondary,
                    ),
                  ),
                  Text(
                    '${w('Price', '股价')} ${fmt(h['price'])}  /  ${w('Value', '估值')} ${fmt(h['fairValue'])}',
                    style: style(12, false, p.muted),
                  ),
                  Text(
                    '${w('Premium', '溢价')} ${pct(h['premium'])}',
                    style: style(12, false, p.muted),
                  ),
                  if (h['modelDate'] != null)
                    Text(
                      '${w('Model', '模型')} ${h['modelDate']}',
                      style: style(11, false, p.muted),
                    ),
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  const SizedBox(height: 7),
                  details,
                  if (text(h['ticker']).isNotEmpty)
                    TextButton(
                      onPressed: () => widget.onCompany(text(h['ticker'])),
                      child: Text(w('Open valuation →', '打开估值 →')),
                    ),
                  Divider(color: p.border, height: 12),
                ],
              );
            },
          ),
        ),
      const SizedBox(height: 8),
      copy(
        'Target cash ${pct(event['cashWeight'])} · CTA ${pct(event['ctaWeight'])}. ${resultFullyInvested ? 'All excluded stock slots are redistributed to eligible stocks.' : 'Unavailable slots are not redistributed.'}',
        '目标现金 ${pct(event['cashWeight'])} · CTA ${pct(event['ctaWeight'])}。${resultFullyInvested ? '全部剔除份额已分配给可买股票。' : '数据缺失仓位不参与重新分配。'}',
      ),
      const SizedBox(height: 8),
      copy(
        'Open valuation continues research at workspace cutoff ${widget.asOf}; the historical filter inputs above remain unchanged.',
        '打开估值将以工作区截止日 ${widget.asOf} 继续研究，不会改变上方历史筛选输入。',
        size: 11,
      ),
    ]);
  }

  Widget snapshotSelector() {
    final rows = asList(result?['holdingSnapshots']);
    if (rows.isEmpty) return const SizedBox.shrink();
    final index = ledgerIndex < 0
        ? rows.length - 1
        : ledgerIndex.clamp(0, rows.length - 1);
    final event = rows[index];
    final held = asList(
      event['positions'],
    ).where((h) => h['kind'] == 'stock').length;
    final excluded = asList(event['exclusions']).length;
    final skipped = asList(event['managerExclusions']).length;
    void select(int value) => setState(() {
      ledgerIndex = value;
      tab = 'snapshots';
    });
    return panel([
      Text(w('Historical snapshot', '历史调仓快照'), style: style(18, true)),
      const SizedBox(height: 6),
      copy(
        'Choose a rebalance to see what was held, what was filtered and why.',
        '选择一次调仓，查看当时持有什么、哪些被过滤，以及为什么。',
        size: 12,
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          IconButton(
            tooltip: w('Previous snapshot', '上一期快照'),
            onPressed: index > 0 ? () => select(index - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: ValueKey('snapshot-$index'),
              initialValue: index,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: w('Rebalance date', '调仓日期'),
              ),
              items: [
                for (var i = rows.length - 1; i >= 0; i--)
                  DropdownMenuItem(
                    value: i,
                    child: Text('${rows[i]['date']}', style: style(14, true)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) select(value);
              },
            ),
          ),
          IconButton(
            tooltip: w('Next snapshot', '下一期快照'),
            onPressed: index < rows.length - 1 ? () => select(index + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            w(
              '$held held · $excluded filtered',
              '持仓 $held 只 · 被过滤 $excluded 只',
            ),
            style: style(14, true, p.accent),
          ),
          if (skipped > 0)
            Text(
              w('$skipped unavailable Guru books', '$skipped 份 Guru 申报未纳入'),
              style: style(12, false, p.secondary),
            ),
          Text(
            '${index + 1} / ${rows.length}',
            style: style(12, false, p.muted),
          ),
          if (tab != 'snapshots')
            TextButton.icon(
              onPressed: () => select(index),
              icon: const Icon(Icons.manage_search, size: 18),
              label: Text(w('View holdings & filters', '查看持仓与过滤原因')),
            ),
        ],
      ),
      if (dirty)
        copy(
          'Showing the previous run. Changed controls do not change these historical decisions.',
          '正在查看上次回测。修改中的参数不会改变这些历史决策。',
          size: 12,
          color: p.secondary,
        ),
    ]);
  }

  Widget snapshots() {
    final rows = asList(result?['holdingSnapshots']);
    if (rows.isEmpty) {
      return panel([
        Text(
          w('No completed holdings history yet', '尚无已完成的持仓历史'),
          style: style(20, true),
        ),
        const SizedBox(height: 8),
        copy(
          'Run a complete backtest to browse its actual rebalance allocations. A blocked run does not create held-position snapshots.',
          '完成回测后即可翻阅每次调仓的真实模拟配置。未通过的回测不会生成看似已持有的快照。',
        ),
        if (asList(result?['ledger']).isNotEmpty)
          TextButton(
            onPressed: () => setState(() => tab = 'holdings'),
            child: Text(w('Inspect attempted rebalances →', '查看调仓尝试与审计 →')),
          ),
      ]);
    }
    final index = ledgerIndex < 0
        ? rows.length - 1
        : ledgerIndex.clamp(0, rows.length - 1);
    return StrategySnapshotInspector(
      event: rows[index],
      rules: asMap(result?['rules']),
      managers: asList(catalog?['managers']),
      palette: p,
      asOf: widget.asOf,
      onCompany: widget.onCompany,
    );
  }

  Widget methodology() => panel([
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        w('Rules, sources & limitations', '规则、来源与局限'),
        style: style(15, true),
      ),
      children: [
        if (asMap(result?['rules'])['ctaPolicy'] != null) ...[
          Text(
            strategyCtaMode(
              context,
              asMap(asMap(result?['rules'])['ctaPolicy']),
            ),
            style: style(14, true, p.accent),
          ),
          copy(
            'Flexible CTA: prior-session total-return signals execute at the following close. Each threshold is used once per cycle, at most one stage per eligible close. Buyback restores only previously trimmed target tranches. Weights refer to gross invested assets. Equity selection and financing reset independently of CTA. Trading costs are solved on actual post-fee trades for both 1× and leveraged CTA portfolios. Inspect CTA trades and actual-weight snapshots; the stock-selection ledger is not a CTA target ledger.',
            '灵活 CTA：前一交易日含分红复权信号在下一交易日收盘执行。每档每轮仅触发一次，每个可交易日最多一档。买回仅恢复已减的目标份额，比例指总投资资产。股票选股及融资重设与 CTA 独立；1× 和杠杆 CTA 组合都按扣费后的实际成交求解费用。在 CTA 调仓及实际仓位快照中核查；股票筛选审计不是 CTA 目标仓位记录。',
            size: 12,
          ),
          const SizedBox(height: 12),
        ],
        copy(
          'This is a retrospective PIT research replay, not an archived live strategy or the manager’s fund return. 13F omits shorts, private assets, cash and intra-quarter trades.',
          '这是回顾式 PIT 研究回放，不是当时存档的实盘策略或经理基金收益。13F 不含空头、私人资产、现金及季内交易。',
        ),
        const SizedBox(height: 10),
        if (asMap(result?['rules'])['equityMix'] != null)
          copy(
            'Equity mix: initial allocation and calendar-quarter rebalances use the prior session’s public information. Guru Top N survivors share the Guru budget. Factor stocks pass all enabled thresholds, then valuation, then rank by the configured enabled metric to select Top N. ROIC uses the lowest observed year for ranking; when enabled it also breaks ranking ties, followed by ticker. Disabled factors do not screen or rank. Every ROIC observation year requires valid public data even when fewer years need to clear its threshold. Each source keeps its configured budget; overlaps merge. Index ETFs are not company-valued. The stored operating-company universe is not survivorship-free, and model histories are retrospective reconstructions.',
            '混合组合：期初建仓及日历季度调仓只用前一交易日已公开信息。大佬 Top N 过滤后等分大佬份额。因子策略先过全部启用门槛，再过滤估值，按所选已启用指标排序取 Top N。ROIC 排序取观察期最低年值，启用时也用于同分排序，最后按代码排序。关闭的因子不参与筛选或排序。即使只要求部分年份过 ROIC 门槛，整个观察期仍须有已公开完整数据。各来源保留既定份额，重复持仓合并，指数 ETF 不做个股估值。当前公司范围并非无幸存者偏差，历史模型为回顾式重建。',
          ),
        if (asMap(result?['rules'])['equityMix'] == null)
          copy(
            'Top 1–10 from original quarterly common-long disclosures. Rebalance at the following market close; later amendments and confidential supplements are not applied. Selection and valuation use prior-session information. Weights drift between quarterly disclosures.',
            '从季度原始普通股多头披露提取 Top 1–10，在下一个交易日收盘调仓；不应用后来的修订或保密持仓补充。选股与估值采用前一交易日信息，权重在季度披露之间随市场漂移。',
          ),
        const SizedBox(height: 10),
        if (asMap(result?['rules'])['equityMix'] == null)
          copy(
            resultFullyInvested
                ? 'Eligible-subset strategy, not strict Guru replication: unavailable manager books and non-executable stocks are excluded. Missing, non-USD, stale or expensive models are excluded when the filter is on. Remaining stocks are equally weighted, with the CTA allocation unchanged. No lower-ranked or future-known replacements. Historical coverage limits can bias results.'
                : 'Valuation uses the published fair value, which may blend methods. Missing, non-USD, incomparable or >550-day-old model inputs stay cash. Overpriced exclusions follow your cash/redistribution rule; no lower-ranked replacement stocks.',
            resultFullyInvested
                ? '这是可买子集策略，不是严格 Guru 复制：跳过不可用的经理申报及无法执行的股票。开启估值筛选后，缺失、非美元、过旧或高估模型均剔除。剩余股票等权满仓，CTA 配比不变。不补入排名更低或未来才知道的股票。历史数据覆盖限制可能造成偏差。'
                : '估值使用平台公允价值，可能混合多种方法。缺失、非美元、不可比或超过 550 天的模型输入对应仓位留现金。高估剔除按你选择的现金/再分配规则执行，不补入排名更低的股票。',
          ),
        const SizedBox(height: 10),
        copy(
          'All return series use dividend- and split-adjusted close. Active price gaps stop that curve. Cash earns 0%. Costs are basis points on buys plus sells, including entry. ETF operating expenses are already in observed performance. SPY is gross buy-and-hold.',
          '收益均使用含分红、拆股调整的收盘价。活动持仓价格缺失会停止该曲线。现金收益为 0%。费用按买入加卖出金额收取基点，包括建仓；ETF 费用已反映在行情中。SPY 为未扣交易费用的买入持有基准。',
        ),
        const SizedBox(height: 10),
        copy(
          'Sharpe uses a 0% risk-free rate and 252 sessions/year. CAGR uses elapsed calendar days. Parameter comparisons are in-sample; trying many combinations can overfit.',
          '夏普比率采用 0% 无风险利率、每年 252 个交易日；CAGR 使用实际日历天数。参数比较是样本内的，反复试参数可能过拟合。',
        ),
        const SizedBox(height: 10),
        copy(
          'Leverage scales invested assets and debt resets on equity rebalance dates. Only net borrowing accrues 4% ACT/365 interest, capitalized at observed closes. Flexible CTA preserves its units when no CTA rule triggers; both its 1× and leveraged portfolios use actual post-fee trade costs. Standalone equity comparisons retain their original cost convention. No margin calls or forced liquidation are simulated.',
          '杠杆放大投资资产，负债在股票调仓日重设。仅净借款按 4%、ACT/365 计息，并在收盘观测日计入负债。灵活 CTA 未触发规则时保留其份额；其 1× 与杠杆组合均按扣费后的实际成交额计费。纯股票对照保留原费用算法。不模拟追保或强平。',
        ),
        const SizedBox(height: 10),
        if (result != null)
          SelectableText(
            '${w('Rule fingerprint', '规则指纹')}: ${result!['ruleHash']}',
            style: style(10, false, p.muted),
          ),
      ],
    ),
  ]);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      copy(
        'STRATEGIES / BUILD · TEST · COMPARE',
        '策略 / 构建 · 回测 · 对比',
        size: 12,
        color: p.accent,
      ),
      const SizedBox(height: 10),
      Text(
        w('Your portfolio. Your rules.', '你的组合，你的投资规则。'),
        style: style(32, true),
      ),
      const SizedBox(height: 8),
      copy(
        'Choose holdings. Filter valuations. Add CTA. Set your leverage.',
        '选择持仓 → 估值过滤 → 配置 CTA → 设置杠杆。',
      ),
      const SizedBox(height: 24),
      if (loading) LinearProgressIndicator(color: p.accent),
      if (!loading && catalog == null)
        button(
          'Retry loading',
          '重新加载',
          () => unawaited(load()),
          icon: Icons.refresh,
        ),
      if (catalog != null) ...[
        if (asList(catalog!['saved']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in asList(catalog!['saved']).reversed.take(6))
                  ActionChip(
                    avatar: const Icon(Icons.bookmark_outline, size: 16),
                    label: Text(text(s['name'])),
                    onPressed: () => restore(s),
                  ),
              ],
            ),
          ),
        LayoutBuilder(
          builder: (ctx, c) {
            final cards = [
              managerCard(),
              valuationCard(),
              ctaCard(),
              leverageCard(),
            ];
            if (c.maxWidth < 680) {
              return Column(
                children: [
                  for (final card in cards)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: card,
                    ),
                ],
              );
            }
            if (c.maxWidth < 1440) {
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final card in cards)
                    SizedBox(width: (c.maxWidth - 14) / 2, child: card),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Expanded(child: cards[i]),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        if (asMap(catalog?['storage'])['cutoff'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: copy(
              'Market-data cutoff: ${asMap(catalog?['storage'])['cutoff']} · Filings and models retain their actual publication dates.',
              '行情数据截止：${asMap(catalog?['storage'])['cutoff']} · 披露与估值保留实际发布日期。',
              size: 12,
              color:
                  text(asMap(catalog?['storage'])['cutoff']).compareTo(end) < 0
                  ? p.secondary
                  : p.muted,
            ),
          ),
        if (asMap(asMap(catalog?['storage'])['freshness']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: copy(
              '${asMap(asMap(catalog?['storage'])['freshness'])['rawSecuritiesCurrent']} securities with current return data · ${asMap(asMap(catalog?['storage'])['freshness'])['comparisonSecuritiesCurrent']} current comparison quotes. Financial-model inputs were not refreshed; some source coverage remains unavailable.',
              '${asMap(asMap(catalog?['storage'])['freshness'])['rawSecuritiesCurrent']} 个证券的收益行情、${asMap(asMap(catalog?['storage'])['freshness'])['comparisonSecuritiesCurrent']} 个证券的估值对比价格已更新。财报模型输入尚未刷新，部分源数据仍未覆盖。',
              size: 12,
              color: p.secondary,
            ),
          ),
        if (_defaultEndAdjusted)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: copy(
              'Default range ends on $end, the latest available market session before workspace date ${widget.asOf}. You can choose a different range; selected dates are never shortened automatically.',
              '默认回测截至 $end，这是工作区日期 ${widget.asOf} 之前最近的可用行情日。你可以另选区间，手动选择的日期不会被自动缩短。',
              size: 12,
              color: p.accent,
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            button(
              '$start → $end',
              '$start → $end',
              dateRange,
              icon: Icons.date_range,
            ),
            for (final n in [1, 3, 5, 10])
              ChoiceChip(
                label: Text('$n${w('Y', '年')}'),
                selected:
                    years == n &&
                    start ==
                        DateTime(
                          DateTime.parse(end).year - n,
                          DateTime.parse(end).month,
                          DateTime.parse(end).day,
                        ).toIso8601String().substring(0, 10),
                onSelected: (_) => setState(() => setWindow(n)),
              ),
            SizedBox(
              width: 148,
              child: DropdownButtonFormField<double>(
                initialValue: cost,
                key: ValueKey('cost-$cost'),
                decoration: InputDecoration(
                  labelText: w('Cost / traded value', '交易金额费率'),
                ),
                items: [
                  for (final b in [0.0, 5.0, 10.0, 25.0, 50.0])
                    DropdownMenuItem(
                      value: b,
                      child: Text('${b.toInt()} bps', style: style(12)),
                    ),
                ],
                onChanged: (v) => setState(() => cost = v!),
              ),
            ),
            button(
              running ? 'Running…' : 'Run backtest',
              running ? '回测中…' : '运行回测',
              !canConfigureRun || running ? null : () => unawaited(run()),
              primary: true,
            ),
            button(
              saving ? 'Saving…' : 'Save rules',
              saving ? '保存中…' : '保存规则',
              !canConfigureRun || saving ? null : () => unawaited(save()),
            ),
          ],
        ),
        if (!canConfigureRun)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: copy(
              'Configure an equity mix or choose a Guru to start. No strategy runs or saves until you ask.',
              '先选择大佬，点击后才运行回测或保存规则。',
            ),
          ),
      ],
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(error, style: style(14, false, p.secondary)),
        ),
      if (notice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(notice, style: style(13, false, p.accent)),
        ),
      if (running)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: LinearProgressIndicator(color: p.accent),
        ),
      if (result != null) ...[
        SizedBox(key: resultAnchor, height: 24),
        if (dirty)
          panel([
            Text(
              w(
                'Rules changed — run again to update results.',
                '规则已改变，请重新运行以更新结果。',
              ),
              style: style(14, true, p.secondary),
            ),
            copy(
              'The curves below still belong to the last completed run.',
              '下方曲线仍属于上一次完成的回测。',
            ),
          ]),
        const SizedBox(height: 12),
        if (asMap(asMap(result!['results'])['leveraged'])['financing'] !=
            null) ...[
          leverageSummary(),
          const SizedBox(height: 18),
        ],
        if (result!['failure'] != null)
          panel([
            Text(
              asMap(result!['failure'])['code'] == 'manager_history_unavailable'
                  ? w(
                      'The requested start precedes available filings',
                      '开始日期早于可用申报历史',
                    )
                  : strategyFailureHasSourceGap(asMap(result!['failure']))
                  ? w('Required source data is incomplete', '回测所需源数据不完整')
                  : asMap(result!['failure'])['code'] == 'no_eligible_stocks'
                  ? w(
                      'No stocks pass on ${asMap(result!['failure'])['date']}',
                      '${asMap(result!['failure'])['date']} 没有股票通过筛选',
                    )
                  : w('This configuration needs data review', '当前配置需要数据核查'),
              style: style(18, true, p.secondary),
            ),
            const SizedBox(height: 8),
            Text(
              failure(asMap(result!['failure'])),
              style: style(13, false, p.muted),
            ),
            if (asMap(result!['failure'])['code'] == 'no_eligible_stocks') ...[
              const SizedBox(height: 12),
              for (final item in asList(
                asMap(result!['failure'])['managerExclusions'],
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    failure(item),
                    style: style(13, false, p.secondary),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in asList(
                    asMap(result!['failure'])['exclusions'],
                  ))
                    ActionChip(
                      label: Text(
                        '${text(item['ticker'])} · ${switch (text(item['status'])) {
                          'expensive' => w('Above limit', '超过估值上限'),
                          'no_model' => w('No model', '缺少估值模型'),
                          'comparison_price_missing' => w('Missing quote', '缺少比较价格'),
                          'stale_model' => w('Stale model', '模型过旧'),
                          _ => w('Not eligible', '不符合条件'),
                        }}',
                      ),
                      onPressed: () => widget.onCompany(text(item['ticker'])),
                    ),
                ],
              ),
              if (asMap(result!['failure'])['decisionDate'] != null)
                copy(
                  'Decision data: ${asMap(result!['failure'])['decisionDate']} · price / model − 1 limit: ${pct(asMap(result!['rules'])['maxPremium'])}',
                  '决策数据日：${asMap(result!['failure'])['decisionDate']} · 价格 / 估值 − 1 上限：${pct(asMap(result!['rules'])['maxPremium'])}',
                  size: 12,
                ),
              for (final item in asList(
                asMap(result!['failure'])['exclusions'],
              ).where((h) => h['premium'] != null))
                copy(
                  '${item['ticker']}: price ${fmt(item['price'])} / model ${fmt(item['fairValue'])} · premium ${pct(item['premium'])} · model ${item['modelDate']}',
                  '${item['ticker']}：价格 ${fmt(item['price'])} / 估值 ${fmt(item['fairValue'])} · 溢价 ${pct(item['premium'])} · 模型 ${item['modelDate']}',
                  size: 12,
                ),
              const SizedBox(height: 12),
              copy(
                'Inspect a stock above, or edit your rules and run again. No rule has been changed automatically.',
                '可点击上方股票核查，或修改规则后重新运行。系统没有自动更改你的规则。',
                size: 12,
              ),
            ],
            copy(
              'Any available comparison below is separate; it is not a completed blend.',
              '下方如有可用对照曲线，也是独立结果，不代表组合回测已完成。',
            ),
          ]),
        if (asMap(result!['summary'])['minModelCoverage'] != null &&
            number(asMap(result!['summary'])['minModelCoverage']) < .8)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: panel([
              Text(
                w('Some periods have low valuation coverage', '部分时期估值覆盖不足'),
                style: style(15, true, p.secondary),
              ),
              copy(
                'Lowest rebalance coverage: ${pct(result!['summary']['minModelCoverage'])}. ${resultFullyInvested ? 'Only eligible stocks receive the full stock allocation; fewer names can increase concentration.' : 'Missing estimates remain cash; a lower drawdown can reflect lower stock exposure.'}',
                '最低调仓估值覆盖：${pct(result!['summary']['minModelCoverage'])}。${resultFullyInvested ? '全部股票资金仅分配给可买股票，数量减少可能提高集中度。' : '缺少估值的仓位留现金，较低回撤可能来自较少股票敞口。'}',
              ),
            ]),
          ),
        if (result!['summary'] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                copy(
                  '${result!['summary']['rebalances']} ${asMap(result!['rules'])['equityMix'] != null ? 'quarterly rebalances' : 'disclosure rebalances'}',
                  '${result!['summary']['rebalances']} 次披露调仓',
                ),
                copy(
                  'Minimum execution coverage ${pct(result!['summary']['minExecutionCoverage'])}',
                  '最低执行覆盖 ${pct(result!['summary']['minExecutionCoverage'])}',
                ),
                if (result!['summary']['minModelCoverage'] != null)
                  copy(
                    'Minimum valuation coverage ${pct(result!['summary']['minModelCoverage'])}',
                    '最低估值覆盖 ${pct(result!['summary']['minModelCoverage'])}',
                  ),
              ],
            ),
          ),
        if (resultFullyInvested && result!['status'] == 'ready')
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: copy(
              asMap(result?['rules'])['equityMix'] != null
                  ? 'Fully invested within each source · configured budgets preserved. Inspect component weights and exclusions in Holdings & filters.'
                  : 'Fully invested eligible subset · not a strict Guru replica. Inspect every exclusion in Holdings & filters.',
              asMap(result?['rules'])['equityMix'] != null
                  ? '各来源内部满仓 · 保留配置比例。在历史持仓快照中查看来源权重及全部剔除原因。'
                  : '可买子集等权满仓 · 不是严格 Guru 复制。全部剔除原因保留在历史持仓快照中。',
              color: p.accent,
              size: 12,
            ),
          ),
        if (tab != 'holdings' &&
            asList(result?['holdingSnapshots']).isNotEmpty) ...[
          snapshotSelector(),
          const SizedBox(height: 16),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in [
              ('performance', 'Performance', '表现'),
              ('snapshots', 'Holdings & filters', '持仓与过滤原因'),
              ('holdings', 'Rebalance audit', '调仓审计'),
              if (asMap(result?['rules'])['ctaPolicy'] != null)
                ('cta', 'CTA trades', 'CTA 调仓'),
            ])
              ChoiceChip(
                label: Text(w(t.$2, t.$3)),
                selected: tab == t.$1,
                onSelected: (_) => setState(() => tab = t.$1),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (tab == 'performance')
          StrategyLabChart(
            key: ValueKey(result!['ruleHash']),
            data: result!,
            palette: p,
          ),
        if (tab == 'holdings') audit(),
        if (tab == 'snapshots') snapshots(),
        if (tab == 'cta')
          StrategyCtaHistory(
            data: result!,
            palette: p,
            onDate: (date) {
              final rows = asList(result?['holdingSnapshots']);
              setState(() {
                ledgerIndex = rows.indexWhere((r) => r['date'] == date);
                tab = 'snapshots';
              });
            },
          ),
        const SizedBox(height: 16),
        methodology(),
      ] else if (!loading) ...[
        const SizedBox(height: 26),
        panel([
          Text(
            w('See what each rule changes.', '看清每条规则改变了什么。'),
            style: style(21, true),
          ),
          const SizedBox(height: 10),
          copy(
            'Compare your equity selection before and after valuation filtering, your CTA blend and SPY over the same dates. Browse historical holdings and inspect every exclusion.',
            '在相同日期对比估值过滤前后的股票组合、CTA 混合组合及 SPY；翻看历史持仓和每次剔除原因。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 22,
            runSpacing: 10,
            children: [
              for (final t in [
                ('CAGR', '年化收益'),
                ('Max drawdown', '最大回撤'),
                ('Volatility', '波动率'),
                ('Coverage & cash', '覆盖率与现金'),
              ])
                Text(w(t.$1, t.$2), style: style(13, true, p.accent)),
            ],
          ),
        ]),
      ],
    ],
  );
}
