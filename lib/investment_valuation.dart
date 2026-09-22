part of 'main.dart';

// The worksheet edits a growth path. Revenue cells are another way to enter
// that same path, never a second competing set of server assumptions.
extension _PersonalValuation on _InvestmentWorkspaceState {
  bool get independentValuation =>
      asMap(company?['templateReconciliation'])['basis'] ==
      'user_defined_cashflow_path';

  void copyFirstForecastYear() {
    final firstGrowth = editedRatio(growth.first);
    if (firstGrowth == null) return;
    final paths = personalDcfMethod == 'operating_fcff'
        ? [ebitMargin, cashTaxRate, dnaMargin, capexMargin, nwcInvestmentMargin]
        : [margin];
    if (paths.any((path) => editedRatio(path.first) == null)) return;
    for (var i = 1; i < forecastHorizon; i++) {
      displayRatio(growth[i], firstGrowth);
      for (final path in paths) {
        displayRatio(path[i], editedRatio(path.first)!);
      }
    }
    syncRevenueInputs();
    scheduleCalculation();
  }

  Widget financialComparisonGrid() {
    final metrics = asList(company?['metrics']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: [
            label(
              'REPORTED ACTUALS · Read-only evidence',
              '已报告实际值 · 只读证据',
              size: 11,
              color: p.muted,
            ),
            if (assumptions.isNotEmpty)
              TextButton.icon(
                onPressed: () => selectSection('value'),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: Text(w('Build your hypothesis', '填写我的假设')),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (metrics.isEmpty)
          label(
            'No comparable financial metrics at this date.',
            '该日期没有可比较的财务指标。',
          ),
        if (metrics.isNotEmpty)
          LayoutBuilder(
            builder: (_, bounds) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: math.max(bounds.maxWidth, 720),
                child: Table(
                  columnWidths: const {
                    0: FlexColumnWidth(1.65),
                    1: FlexColumnWidth(),
                    2: FlexColumnWidth(),
                    3: FlexColumnWidth(),
                    4: FlexColumnWidth(1.5),
                  },
                  border: TableBorder(
                    horizontalInside: BorderSide(color: p.border),
                  ),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: p.background),
                      children: [
                        for (final h in [
                          ('Metric', '指标'),
                          ('Latest', '最新'),
                          ('Prior', '上期'),
                          ('Change · pp', '变化 · 百分点'),
                          ('History percentile', '历史分位'),
                        ])
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            child: label(h.$1, h.$2, size: 12),
                          ),
                      ],
                    ),
                    for (final m in metrics)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              metricName(text(m['key'])),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              pct(m['value']),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: label(
                              pct(m['previous']),
                              pct(m['previous']),
                              size: 14,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              nullableNumber(m['change']) == null
                                  ? '—'
                                  : '${number(m['change']) > 0 ? '+' : ''}${(number(m['change']) * 100).toStringAsFixed(2)}',
                              style: TextStyle(color: p.muted, fontSize: 14),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                label(
                                  m['historicalPercentile'] == null
                                      ? '—'
                                      : '${pct(m['historicalPercentile'])} (n=${m['sampleCount']})',
                                  m['historicalPercentile'] == null
                                      ? '—'
                                      : '${pct(m['historicalPercentile'])} (n=${m['sampleCount']})',
                                  size: 12,
                                ),
                                const SizedBox(height: 8),
                                if (nullableNumber(m['historicalPercentile']) !=
                                    null)
                                  LinearProgressIndicator(
                                    value: number(
                                      m['historicalPercentile'],
                                    ).clamp(0.0, 1.0),
                                    minHeight: 3,
                                    color: p.accent,
                                    backgroundColor: p.border,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
      ],
    );
  }

  String? valuationInputProblem() {
    for (var i = 0; i < forecastHorizon; i++) {
      final g = editedRatio(growth[i]);
      if (g == null || !g.isFinite || g <= -.95 || g > 2) {
        return w(
          'Year ${i + 1}: enter revenue growth above −95% and no more than 200%. Blank or invalid revenue is not zero.',
          '第 ${i + 1} 年：收入增长率须大于 −95%、不超过 200%。空白或无效收入不视为零。',
        );
      }
      if (personalDcfMethod == 'parent_fcfe') {
        final m = editedRatio(margin[i]);
        if (m == null || !m.isFinite || m < -.9 || m > .9) {
          return w(
            'Year ${i + 1}: FCFE margin must be between −90% and 90%. Negative explicit cash flow is preserved as a financing need.',
            '第 ${i + 1} 年：FCFE 率须在 −90% 至 90% 之间。显性期负现金流会保留并列为融资需求。',
          );
        }
      } else {
        final values = [
          editedRatio(ebitMargin[i]),
          editedRatio(cashTaxRate[i]),
          editedRatio(dnaMargin[i]),
          editedRatio(capexMargin[i]),
          editedRatio(nwcInvestmentMargin[i]),
        ];
        if (values.any((v) => v == null || !v.isFinite)) {
          return w(
            'Year ${i + 1}: every operating-driver input is required; a blank value is not zero.',
            '第 ${i + 1} 年：所有经营驱动参数都必须填写；空白不视为零。',
          );
        }
        final ranges = [
          (-1.0, 1.0),
          (0.0, .6),
          (0.0, 1.0),
          (0.0, 2.0),
          (-1.0, 1.0),
        ];
        for (var j = 0; j < values.length; j++) {
          if (values[j]! < ranges[j].$1 || values[j]! > ranges[j].$2) {
            return w(
              'Year ${i + 1}: an operating-driver assumption is outside the disclosed supported range.',
              '第 ${i + 1} 年：经营驱动假设超出已披露的支持范围。',
            );
          }
        }
      }
    }
    if (personalDcfMethod == 'operating_fcff' &&
        [
          netDebt,
          nci,
          nonOperatingAssets,
        ].any((c) => editedAmount(c) == null)) {
      return w(
        'Complete the equity bridge. Blank net debt, NCI or non-operating assets are not assumed to be zero.',
        '请完整填写股权价值桥。净债务、少数股东权益或非经营资产留空时不会被视为零。',
      );
    }
    return valuationRateProblem(
          personalDcfMethod == 'operating_fcff' ? wacc : ke,
        ) ??
        valuationRateProblem(terminal);
  }

  String? valuationRateProblem(TextEditingController controller) {
    final discount = editedRatio(
          personalDcfMethod == 'operating_fcff' ? wacc : ke,
        ),
        perpetual = editedRatio(terminal);
    if (controller == ke || controller == wacc) {
      if (discount == null ||
          !discount.isFinite ||
          discount < .04 ||
          discount > .30) {
        return w(
          personalDcfMethod == 'operating_fcff'
              ? 'WACC must be between 4% and 30%.'
              : 'Cost of equity must be between 4% and 30%.',
          personalDcfMethod == 'operating_fcff'
              ? 'WACC 须在 4%–30% 之间。'
              : '股权资本成本须在 4%–30% 之间。',
        );
      }
      return null;
    }
    if (perpetual == null ||
        !perpetual.isFinite ||
        perpetual < 0 ||
        perpetual > .05 ||
        (discount != null && discount - perpetual < .015)) {
      return w(
        'This model supports terminal growth of 0%–5%, at least 1.5 percentage points below Ke. Edit g to resume; your forecast is preserved.',
        '本模型支持 0%–5% 的永续增长，且须至少低于 Ke 1.5 个百分点。修改 g 后自动重算，逐年假设已保留。',
      );
    }
    return null;
  }

  // Calculation failures belong beside the inputs, not in a workspace-reload
  // banner above the viewport. Never present an older result as the new draft.
  Widget valuationCalculationState({bool compact = false}) {
    final problem = valuationInputProblem();
    final failed = calculationFailure != null;
    final awaitingInputs =
        independentValuation &&
        growth.every((c) => c.text.isEmpty) &&
        (personalDcfMethod == 'operating_fcff'
            ? ebitMargin.every((c) => c.text.isEmpty)
            : margin.every((c) => c.text.isEmpty));
    final message = problem != null
        ? (awaitingInputs
              ? w(
                  'Start with Year 1 growth and FCFE margin below. You can copy them across, then refine each year.',
                  '从下方第 1 年增长率及 FCFE 率开始，可复制到其他年份，再逐年调整。',
                )
              : compact
              ? problem
              : w(
                  'Check the highlighted assumptions to calculate your DCF.',
                  '请检查标出的假设，再计算你的 DCF。',
                ))
        : failed
        ? calculationFailure == 'timeout'
              ? w(
                  'Calculation timed out. Your inputs are preserved; retry without reloading.',
                  '计算超时，输入已保留，无需刷新页面，可直接重试。',
                )
              : w(
                  'Calculation failed. Your inputs are preserved; retry without reloading.',
                  '计算失败，输入已保留，无需刷新页面，可直接重试。',
                )
        : calculationPending
        ? w('Recalculating… Your inputs are preserved.', '正在重算…你的输入已保留。')
        : null;
    return Semantics(
      key: ValueKey('valuation-calculation-status-$compact'),
      liveRegion: true,
      child: message == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: (problem != null && !awaitingInputs) || failed
                          ? p.negative
                          : p.muted,
                      fontSize: compact ? 12 : 13,
                      height: 1.5,
                    ),
                  ),
                  if (compact && failed && problem == null)
                    button(
                      'Retry calculation',
                      '重试计算',
                      () => unawaited(recalculate()),
                      icon: Icons.refresh,
                    ),
                ],
              ),
            ),
    );
  }

  void syncRevenueInputs({int from = 0}) {
    double? value = nullableNumber(asMap(company?['base'])['revenueM']);
    for (var i = 0; i < forecastHorizon; i++) {
      final rate = editedRatio(growth[i]);
      value = value != null && rate != null ? value * (1 + rate) : null;
      if (i >= from) revenue[i].text = value?.toStringAsFixed(2) ?? '';
    }
  }

  void editRevenue(int index) {
    double? prior = nullableNumber(asMap(company?['base'])['revenueM']);
    for (var i = 0; i < index; i++) {
      final rate = editedRatio(growth[i]);
      prior = prior != null && rate != null ? prior * (1 + rate) : null;
    }
    final value = double.tryParse(revenue[index].text);
    if (prior != null && prior > 0 && value != null && value > 0) {
      displayRatio(growth[index], value / prior - 1);
    } else {
      growth[index].clear();
    }
    syncRevenueInputs(from: index + 1);
    scheduleCalculation();
  }

  void setForecastHorizon(int years) {
    if (years == forecastHorizon || (years != 5 && years != 10)) return;
    if (years == 10) {
      final lastGrowth =
          editedRatio(growth[4]) ?? editedRatio(terminal) ?? .025;
      final terminalGrowth = editedRatio(terminal) ?? .025;
      final paths = personalDcfMethod == 'operating_fcff'
          ? [
              ebitMargin,
              cashTaxRate,
              dnaMargin,
              capexMargin,
              nwcInvestmentMargin,
            ]
          : [margin];
      for (var i = 5; i < 10; i++) {
        final step = (i - 4) / 5;
        if (growth[i].text.isEmpty) {
          displayRatio(
            growth[i],
            lastGrowth + (terminalGrowth - lastGrowth) * step,
          );
        }
        for (final path in paths) {
          if (path[i].text.isEmpty) {
            displayRatio(path[i], editedRatio(path[4]) ?? 0);
          }
        }
      }
    }
    updateUI(() => forecastHorizon = years);
    syncRevenueInputs();
    scheduleCalculation();
  }

  double? researchMetricValue(String key) {
    for (final row in asList(company?['metrics'])) {
      if (row['key'] == key) return nullableNumber(row['value']);
    }
    return nullableNumber(asMap(asMap(company?['snapshot'])['metrics'])[key]);
  }

  void switchPersonalDcfMethod(String next) {
    if (next == personalDcfMethod) return;
    if (personalDcfMethod == 'operating_fcff') {
      fcffAssumptionsCache = edited();
    } else {
      fcfeAssumptionsCache = edited();
    }
    Map<String, dynamic> target;
    if (next == 'operating_fcff') {
      final cached = fcffAssumptionsCache;
      if (cached != null) {
        target = cached;
      } else {
        final sourceGrowth = growth
            .take(forecastHorizon)
            .map((c) => editedRatio(c) ?? .025)
            .toList();
        final op = (researchMetricValue('operatingMargin') ?? .15).clamp(
          -1.0,
          1.0,
        );
        final base = asMap(company?['base']);
        target = {
          'method': 'operating_fcff',
          'discountType': 'WACC',
          'ownership': 'enterprise',
          'timing': 'year_end',
          'horizonYears': forecastHorizon,
          'growth': sourceGrowth,
          'ebitMargin': List.filled(forecastHorizon, op),
          'cashTaxRate': List.filled(forecastHorizon, .25),
          'dnaMargin': List.filled(forecastHorizon, .04),
          'capexMargin': List.filled(forecastHorizon, .05),
          'nwcInvestmentMargin': List.filled(forecastHorizon, .01),
          'wacc': .10,
          'g': editedRatio(terminal) ?? .025,
          'netDebtM': nullableNumber(base['netDebtM']) ?? 0,
          'nciM': nullableNumber(base['nciM']) ?? 0,
          'nonOperatingAssetsM':
              nullableNumber(base['nonOperatingAssetsM']) ?? 0,
        };
      }
    } else {
      target =
          fcfeAssumptionsCache ?? asMap(asMap(company?['templates'])['Base']);
    }
    calculationTimer?.cancel();
    calculationSerial++;
    updateUI(() {
      assumptions = Map<String, dynamic>.from(target);
      personalDcfMethod = next;
      reverseVariable = 'growth';
      template = 'Custom';
      scenarioId = null;
      ownership = false;
      draftDirty = true;
      calculation = null;
      notice = null;
    });
    fillAssumptions();
    scheduleCalculation();
  }

  void editHypothesisMetadata() {
    updateUI(() {
      scenarioId = null;
      ownership = false;
      draftDirty = true;
      notice = null;
    });
    scheduleWorksheetSave();
  }

  Future<void> restorePersonalVersion(Map<String, dynamic> saved) async {
    if (!await allowLeaveDraft() || !mounted) return;
    calculationTimer?.cancel();
    calculationSerial++;
    final same =
        asMap(saved['snapshot'])['id'] == asMap(company?['snapshot'])['id'];
    updateUI(() {
      assumptions = asMap(saved['assumptions']);
      hypothesis.text = text(saved['hypothesis']);
      scenarioName.text = text(saved['name']);
      template = '';
      calculation = null;
      valuationReference = null;
      scenarioParentId = text(saved['id']);
      scenarioId = same ? scenarioParentId : null;
      ownership = same;
      draftDirty = !same;
      notice = same
          ? w(
              'Loaded your saved version. Editing creates a new draft.',
              '已载入你的保存版本，编辑会创建新草稿。',
            )
          : w(
              'Earlier assumptions applied to this snapshot. Review and save as a new version.',
              '历史假设已应用于当前快照，请复核并另存新版本。',
            );
    });
    fillAssumptions();
    scheduleWorksheetSave();
    await recalculate();
  }

  List<Widget> personalValueWorkspace() {
    final result = asMap(calculation?['result']);
    final price = asMap(asMap(company?['snapshot'])['price']);
    final value = nullableNumber(result['fairValue']);
    final quote = nullableNumber(price['value']);
    final gap = value != null && quote != null && quote > 0
        ? value / quote - 1
        : null;
    final saved = asList(company?['scenarios']);
    return [
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 12,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title('Your assumptions. Your valuation.', '你的假设，你的估值。'),
                    label(
                      'Edit a year. See what changes. Keep your own version.',
                      '改一年的假设，看估值变化，保存你的专属版本。',
                    ),
                  ],
                ),
                if (worksheetMemoryEnabled)
                  worksheetSaveIndicator()
                else
                  researchTag(
                    draftDirty
                        ? w('Unsaved draft', '未保存草稿')
                        : scenarioId != null
                        ? w('Saved to your account', '已存入你的账户')
                        : w(
                            'Private worksheet · not yet saved',
                            '个人假设表 · 尚未保存',
                          ),
                    draftDirty ? p.secondary : p.accent,
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (independentValuation)
              Container(
                key: const ValueKey('independent-valuation-notice'),
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: .06),
                  border: Border(left: BorderSide(color: p.accent, width: 3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label(
                      'Build your own cash-flow case',
                      '建立你自己的现金流假设',
                      color: p.text,
                      size: 16,
                    ),
                    const SizedBox(height: 8),
                    label(
                      'We have filled in a starting forecast for you. Edit any year to test your case. These are analyst assumptions, not management guidance or the platform’s published valuation.',
                      '已为你填好起始预测，修改任意一年即可测试你的判断。这是分析假设，不是管理层指引，也不代表平台已发布估值。',
                      size: 12,
                    ),
                    const SizedBox(height: 8),
                    label(
                      personalDcfMethod == 'operating_fcff'
                          ? 'Operating drivers and the enterprise-to-equity bridge are editable assumptions. WACC 9% / g 2.5% are illustrative defaults; a zero bridge input means “assumed zero pending evidence,” not a known fact.'
                          : 'Reported TTM CFO − capex: ${asMap(company?["base"])["fcfM"] == null ? '—' : formatNumber(number(asMap(company?["base"])["fcfM"]))} ${text(company?["currency"])}m · context only, not verified parent FCFE. Ke 10% / g 2.5% are editable illustrative defaults.',
                      personalDcfMethod == 'operating_fcff'
                          ? '经营驱动和企业价值到股权价值桥均为可修改假设。WACC 9% / g 2.5% 是示例默认值；桥接项为零表示“缺少证据时暂按零假设”，并非已知事实。'
                          : '报告 TTM CFO − 资本开支：${asMap(company?["base"])["fcfM"] == null ? '—' : formatNumber(number(asMap(company?["base"])["fcfM"]))} ${text(company?["currency"])} 百万，仅作背景，并非已验证母公司 FCFE。Ke 10% / g 2.5% 为可修改的示例参数。',
                      size: 12,
                    ),
                  ],
                ),
              ),
            Container(
              key: const ValueKey('personal-dcf-method-selector'),
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: p.panel,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  label('Cash-flow model', '现金流模型', color: p.text),
                  ChoiceChip(
                    key: const ValueKey('dcf-method-fcfe'),
                    label: Text(w('Simplified FCFE', '简化 FCFE')),
                    selected: personalDcfMethod == 'parent_fcfe',
                    onSelected: (_) => switchPersonalDcfMethod('parent_fcfe'),
                  ),
                  ChoiceChip(
                    key: const ValueKey('dcf-method-fcff'),
                    label: Text(w('Operating FCFF', '经营驱动 FCFF')),
                    selected: personalDcfMethod == 'operating_fcff',
                    onSelected: (_) =>
                        switchPersonalDcfMethod('operating_fcff'),
                  ),
                  label(
                    personalDcfMethod == 'operating_fcff'
                        ? 'Revenue → EBIT → cash tax → NOPAT + D&A − capex − ΔNWC → FCFF → enterprise-to-equity bridge.'
                        : 'Revenue × parent-common FCFE margin. This mode does not manufacture an EBIT bridge.',
                    personalDcfMethod == 'operating_fcff'
                        ? '收入 → EBIT → 现金税 → NOPAT + 折旧摊销 − 资本开支 − ΔNWC → FCFF → 企业价值到股权价值桥。'
                        : '收入 × 母公司普通股 FCFE 率。本模式不会凭空生成 EBIT 桥。',
                    size: 11,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: p.panel,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: LayoutBuilder(
                builder: (_, bounds) {
                  final items = [
                    valuationSummary(
                      money(value),
                      'Your DCF / share',
                      '你的 DCF / 股',
                      color: p.accent,
                    ),
                    valuationSummary(
                      money(quote),
                      'Market · ${text(price['date'])}',
                      '市价 · ${text(price['date'])}',
                    ),
                    valuationSummary(
                      pct(gap),
                      'Value / price − 1',
                      '价值 / 价格 − 1',
                      color: gap == null
                          ? p.muted
                          : gap >= 0
                          ? p.accent
                          : p.negative,
                    ),
                    valuationSummary(
                      money(asMap(company?['published'])['fairValue']),
                      'Platform · separate model',
                      '平台 · 独立模型',
                    ),
                  ];
                  final columns = bounds.maxWidth < 630 ? 2 : 4;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 20,
                    children: [
                      for (final item in items)
                        SizedBox(
                          width:
                              (bounds.maxWidth - 16 * (columns - 1)) / columns,
                          child: item,
                        ),
                    ],
                  );
                },
              ),
            ),
            valuationCalculationState(),
            valuationChangeSummary(result),
            const SizedBox(height: 20),
            pageColumns(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  valuationForecastGrid(result),
                  const SizedBox(height: 18),
                  valuationTerminalSummary(result),
                  const SizedBox(height: 18),
                  card([
                    Row(
                      children: [
                        Icon(Icons.edit_note, color: p.accent, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: title('What needs to be true?', '什么条件必须成立？'),
                        ),
                      ],
                    ),
                    label(
                      'Keep the reasoning beside the numbers. Only you can access these saved hypotheses.',
                      '把推理和数字放在一起，已保存假设仅当前账户可访问。',
                      size: 12,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('personal-hypothesis'),
                      controller: hypothesis,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 4000,
                      onChanged: (_) => editHypothesisMetadata(),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        height: 1.6,
                      ),
                      decoration: InputDecoration(
                        labelText: w('My hypothesis', '我的假设'),
                        hintText: w(
                          'Why this revenue path? What protects margins? What would prove me wrong?',
                          '为什么收入会这样增长？利润率靠什么维持？什么情况会证伪？',
                        ),
                        filled: true,
                        fillColor: p.background,
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: p.border),
                        ),
                      ),
                    ),
                  ]),
                  valuationSourceBridge(),
                  if (saved.isNotEmpty)
                    card([
                      title('Your version history', '你的版本历史'),
                      label(
                        'Saved in the backend · never overwrites a previous version.',
                        '保存在后端，每次另存版本，不覆盖历史。',
                        size: 12,
                      ),
                      const SizedBox(height: 10),
                      for (final version in saved.reversed)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.history,
                            color: p.muted,
                            size: 20,
                          ),
                          title: Text(
                            '${version['name']} · v${version['version']}',
                            style: TextStyle(color: p.text, fontSize: 14),
                          ),
                          subtitle: Text(
                            w(
                              'Saved ${text(version['recordedAt'], '—')} · As of ${version['asOf']}',
                              '保存 ${text(version['recordedAt'], '—')} · 基准日 ${version['asOf']}',
                            ),
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                          trailing: Text(
                            money(asMap(version['result'])['fairValue']),
                            style: TextStyle(color: p.accent),
                          ),
                          onTap: () =>
                              unawaited(restorePersonalVersion(version)),
                        ),
                    ]),
                ],
              ),
              card([scenarioPanel()]),
              sideWidth: 310,
            ),
            valuationDiagnostics(result),
          ],
        ),
      ),
    ];
  }

  Widget valuationSummary(String value, String en, String zh, {Color? color}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 34 * MediaQuery.textScalerOf(context).scale(1),
            child: label(en, zh, size: 12),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color ?? p.text,
              fontSize: 27,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
            ),
          ),
        ],
      );

  Widget valuationChangeSummary(Map<String, dynamic> result) {
    final before = nullableNumber(valuationReference?['fairValue']);
    final after = nullableNumber(result['fairValue']);
    final delta = before != null && after != null ? after - before : null;
    return Container(
      key: const ValueKey('valuation-change-summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.accent.withValues(alpha: .055),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 20,
        runSpacing: 12,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label(
                'What changed in your DCF?',
                '你的 DCF 变化了多少？',
                color: p.text,
                size: 14,
              ),
              const SizedBox(height: 6),
              Text(
                before == null
                    ? w(
                        'Your first valid calculation becomes the comparison point.',
                        '首次有效计算将成为对照起点。',
                      )
                    : w(
                        'Reference ${money(before)} → Now ${money(after)}',
                        '对照 ${money(before)} → 当前 ${money(after)}',
                      ),
                key: const ValueKey('valuation-before-after'),
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              label(
                'Same company, date and shares. Platform valuation stays unchanged.',
                '同一公司、日期及股数，平台估值不变。',
                size: 11,
              ),
            ],
          ),
          Text(
            delta == null
                ? '—'
                : '${delta >= 0 ? '+' : '−'}${money(delta.abs())} / ${w('share', '股')}  (${delta >= 0 ? '+' : ''}${pct(before! > 0 ? delta / before : null)})',
            key: const ValueKey('valuation-delta'),
            style: TextStyle(
              color: delta != null && delta < 0 ? p.negative : p.accent,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextButton.icon(
            key: const ValueKey('valuation-set-reference'),
            onPressed: after == null
                ? null
                : () => updateUI(() => valuationReference = Map.of(result)),
            icon: const Icon(Icons.compare_arrows, size: 17),
            label: Text(w('Use current as reference', '以当前值作为对照')),
          ),
        ],
      ),
    );
  }

  Widget valuationForecastGrid(
    Map<String, dynamic> result, {
    Map<String, dynamic>? reverseDetails,
  }) {
    final operating = personalDcfMethod == 'operating_fcff';
    final reverseMode = reverseDetails != null;
    final solvedVariable = text(reverseDetails?['variable']);
    final base = asMap(company?['base']);
    final snap = asMap(company?['snapshot']);
    final forecasts = asList(result['forecast']);
    final now = DateTime.tryParse(asOf);
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    String amount(dynamic value) =>
        nullableNumber(value) == null ? '—' : formatNumber(number(value));
    bool solvedRow(int row) => switch (solvedVariable) {
      'growth' => row == 2,
      'mature_ebit_margin' => row == 3,
      'terminal_margin' => row == 3,
      'reinvestment' => row == 7,
      _ => false,
    };
    bool solvedCell(int row, int year) =>
        solvedRow(row) &&
        (solvedVariable != 'terminal_margin' || year == forecastHorizon - 1);
    Widget cell(
      Widget child, {
      bool actual = false,
      bool header = false,
      bool solved = false,
    }) => Container(
      height: (header ? 74 : 62) * textScale,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: solved
          ? p.secondary.withValues(alpha: .13)
          : actual
          ? p.background
          : header
          ? p.accent.withValues(alpha: .055)
          : null,
      alignment: Alignment.centerRight,
      child: child,
    );
    Widget plain(String value, {Color? color, bool strong = false}) => Text(
      value,
      textAlign: TextAlign.right,
      style: TextStyle(
        color: color ?? p.muted,
        fontSize: 13,
        fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
      ),
    );
    Widget heading(String en, String zh, String detail) => Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          w(en, zh),
          maxLines: 2,
          style: TextStyle(
            color: p.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(color: p.muted, fontSize: 10, height: 1.2),
        ),
      ],
    );
    final rowNames = operating
        ? [
            (
              w('Forecast driver', '预测指标'),
              text(company?['currency']) + w(' millions', ' 百万'),
            ),
            (w('Revenue', '营业收入'), w('Editable amount', '可编辑金额')),
            (w('Revenue growth', '收入增长率'), w('Linked to revenue', '与收入联动')),
            (w('EBIT margin', 'EBIT 利润率'), w('Operating assumption', '经营假设')),
            (
              w('Cash tax rate', '现金税率'),
              w('Applied to positive EBIT', '仅作用于正 EBIT'),
            ),
            (w('D&A / revenue', '折旧摊销 / 收入'), w('Non-cash add-back', '非现金加回')),
            (w('Capex / revenue', '资本开支 / 收入'), w('Cash investment', '现金投入')),
            (w('ΔNWC / revenue', 'ΔNWC / 收入'), w('Reinvestment path', '再投资路径')),
            (w('FCFF', 'FCFF'), w('Deterministic bridge', '确定性计算桥')),
            (w('Present value', '折现现值'), w('At your WACC', '按你的 WACC 折现')),
          ]
        : [
            (
              w('Forecast driver', '预测指标'),
              text(company?['currency']) + w(' millions', ' 百万'),
            ),
            (w('Revenue', '营业收入'), w('Editable amount', '可编辑金额')),
            (w('Revenue growth', '收入增长率'), w('Linked to revenue', '与收入联动')),
            (w('FCFE margin', 'FCFE 率'), w('Parent common · %', '母公司普通股 · %')),
            (w('Free cash flow', '自由现金流'), w('Revenue × margin', '收入 × 现金流率')),
            (
              w('Present value', '折现现值'),
              w('At your cost of equity', '按你的股权成本折现'),
            ),
          ];
    return Container(
      key: ValueKey(
        reverseMode ? 'reverse-forecast-grid' : 'valuation-forecast-grid',
      ),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.table_chart_outlined, color: p.accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reverseMode
                            ? w(
                                '$forecastHorizon-year price-implied path',
                                '$forecastHorizon 年价格隐含路径',
                              )
                            : w(
                                '$forecastHorizon-year forecast',
                                '$forecastHorizon 年预测',
                              ),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      label(
                        reverseMode
                            ? 'Amber cells are solved from price · every other assumption is fixed'
                            : 'Teal cells are editable · actuals stay locked',
                        reverseMode
                            ? '琥珀色单元格由价格反推，其余假设全部固定'
                            : '青绿色单元格可编辑，历史实际值锁定',
                        size: 11,
                      ),
                    ],
                  ),
                ),
                if (!reverseMode && MediaQuery.sizeOf(context).width < 1100)
                  TextButton.icon(
                    onPressed: calculation == null || busy
                        ? null
                        : () => unawaited(confirmScenario()),
                    icon: const Icon(Icons.save_outlined, size: 17),
                    label: Text(w('Save', '保存')),
                  )
                else
                  Tooltip(
                    message: w(
                      reverseMode
                          ? 'Read-only price-implied path'
                          : worksheetMemoryEnabled
                          ? 'Edits auto-save privately. Save scenario creates a confirmed version.'
                          : 'Saved only when you choose Save scenario',
                      reverseMode
                          ? '价格隐含路径为只读结果'
                          : worksheetMemoryEnabled
                          ? '修改会自动私密保存；保存情景会创建确认版本。'
                          : '点击保存情景后才写入后端',
                    ),
                    child: Icon(Icons.lock_outline, color: p.muted, size: 17),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: p.border),
          if (!reverseMode) forecastOriginNotice(),
          if (reverseMode)
            Container(
              key: const ValueKey('reverse-same-engine-notice'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: p.secondary.withValues(alpha: .055),
              child: label(
                'Same forward DCF engine. The highlighted row is the single parameter solved to reproduce the selected market price.',
                '使用同一套正向 DCF 引擎；高亮行是为复现所选市场价格而求解的唯一参数。',
                color: p.secondary,
                size: 11,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Wrap(
              spacing: 14,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final years in [5, 10])
                  ChoiceChip(
                    key: ValueKey('forecast-horizon-$years'),
                    label: Text('${years}Y'),
                    selected: forecastHorizon == years,
                    onSelected: (_) => setForecastHorizon(years),
                  ),
                label(
                  reverseMode
                      ? '1  Choose one variable   →   2  Solve the annual path   →   3  Forward-check price and residual'
                      : worksheetMemoryEnabled
                      ? '1  Adjust the filled assumptions   →   2  See your DCF change   →   3  Edits save automatically'
                      : '1  Enter growth & cash-flow margin   →   2  DCF updates automatically   →   3  Compare & save',
                  reverseMode
                      ? '1  选择一个待求变量   →   2  反推年度路径   →   3  回代核验价格与残差'
                      : worksheetMemoryEnabled
                      ? '1  修改预填假设   →   2  查看 DCF 变化   →   3  修改自动保存'
                      : '1  填写增长与现金流率   →   2  自动更新 DCF   →   3  比较并保存',
                  size: 12,
                ),
                if (!reverseMode)
                  TextButton.icon(
                    key: const ValueKey('forecast-copy-year-one'),
                    onPressed:
                        editedRatio(growth.first) != null &&
                            (operating
                                ? [
                                    ebitMargin,
                                    cashTaxRate,
                                    dnaMargin,
                                    capexMargin,
                                    nwcInvestmentMargin,
                                  ].every(
                                    (path) => editedRatio(path.first) != null,
                                  )
                                : editedRatio(margin.first) != null)
                        ? copyFirstForecastYear
                        : null,
                    icon: const Icon(Icons.content_copy, size: 15),
                    label: Text(
                      w('Copy Year 1 to all years', '第 1 年假设应用到全部年份'),
                    ),
                  ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (_, bounds) {
              final labelWidth = bounds.maxWidth < 480 ? 116.0 : 156.0;
              final dataWidth = math.max(
                bounds.maxWidth - labelWidth,
                (forecastHorizon == 10 ? 1280.0 : 690.0) * textScale,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Column(
                      children: [
                        for (var row = 0; row < rowNames.length; row++)
                          Container(
                            height: (row == 0 ? 74 : 62) * textScale,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: reverseMode && solvedRow(row)
                                  ? p.secondary.withValues(alpha: .13)
                                  : row == 0
                                  ? p.background
                                  : null,
                              border: Border(
                                bottom: BorderSide(color: p.border),
                              ),
                            ),
                            alignment: Alignment.centerLeft,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  rowNames[row].$1,
                                  maxLines: 2,
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  rowNames[row].$2,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.muted,
                                    fontSize: 10,
                                    height: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: valuationTableScroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: valuationTableScroll,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(bottom: 10),
                        child: SizedBox(
                          width: dataWidth,
                          child: Table(
                            defaultColumnWidth: const FlexColumnWidth(),
                            border: TableBorder(
                              horizontalInside: BorderSide(color: p.border),
                              verticalInside: BorderSide(
                                color: p.border.withValues(alpha: .6),
                              ),
                            ),
                            children: [
                              TableRow(
                                children: [
                                  cell(
                                    heading(
                                      'Actual TTM',
                                      '实际 TTM',
                                      text(
                                        snap['periodEnd'],
                                        text(snap['period']),
                                      ),
                                    ),
                                    actual: true,
                                    header: true,
                                  ),
                                  for (var i = 0; i < forecastHorizon; i++)
                                    cell(
                                      heading(
                                        'Model year ${i + 1}',
                                        '预测第 ${i + 1} 年',
                                        now == null
                                            ? ''
                                            : '${now.year + i + 1}-${asOf.substring(5)}',
                                      ),
                                      header: true,
                                    ),
                                ],
                              ),
                              TableRow(
                                children: [
                                  cell(
                                    plain(amount(base['revenueM'])),
                                    actual: true,
                                  ),
                                  for (var i = 0; i < forecastHorizon; i++)
                                    cell(
                                      reverseMode
                                          ? plain(
                                              forecasts.length > i
                                                  ? amount(
                                                      forecasts[i]['revenueM'],
                                                    )
                                                  : '—',
                                              color: p.text,
                                            )
                                          : valuationCell(
                                              revenue[i],
                                              i,
                                              'revenue',
                                              () => editRevenue(i),
                                            ),
                                    ),
                                ],
                              ),
                              TableRow(
                                children: [
                                  cell(plain('—'), actual: true),
                                  for (var i = 0; i < forecastHorizon; i++)
                                    cell(
                                      reverseMode
                                          ? plain(
                                              forecasts.length > i
                                                  ? pct(forecasts[i]['growth'])
                                                  : '—',
                                              color: solvedCell(2, i)
                                                  ? p.secondary
                                                  : p.text,
                                              strong: solvedCell(2, i),
                                            )
                                          : valuationCell(
                                              growth[i],
                                              i,
                                              'growth',
                                              () {
                                                syncRevenueInputs();
                                                scheduleCalculation();
                                              },
                                            ),
                                      solved: reverseMode && solvedCell(2, i),
                                    ),
                                ],
                              ),
                              if (!operating)
                                TableRow(
                                  children: [
                                    cell(plain('—'), actual: true),
                                    for (var i = 0; i < forecastHorizon; i++)
                                      cell(
                                        reverseMode
                                            ? plain(
                                                forecasts.length > i
                                                    ? pct(
                                                        forecasts[i]['fcfeMargin'],
                                                      )
                                                    : '—',
                                                color: solvedCell(3, i)
                                                    ? p.secondary
                                                    : p.text,
                                                strong: solvedCell(3, i),
                                              )
                                            : valuationCell(
                                                margin[i],
                                                i,
                                                'FCFE margin',
                                                scheduleCalculation,
                                              ),
                                        solved: reverseMode && solvedCell(3, i),
                                      ),
                                  ],
                                ),
                              if (operating)
                                for (final row in [
                                  (
                                    ebitMargin,
                                    'EBIT margin',
                                    researchMetricValue('operatingMargin'),
                                    'ebitMargin',
                                    3,
                                  ),
                                  (
                                    cashTaxRate,
                                    'cash tax rate',
                                    null,
                                    'cashTaxRate',
                                    4,
                                  ),
                                  (dnaMargin, 'D&A / revenue', null, 'dnaM', 5),
                                  (
                                    capexMargin,
                                    'capex / revenue',
                                    null,
                                    'capexM',
                                    6,
                                  ),
                                  (
                                    nwcInvestmentMargin,
                                    'ΔNWC / revenue',
                                    null,
                                    'nwcInvestmentM',
                                    7,
                                  ),
                                ])
                                  TableRow(
                                    children: [
                                      cell(
                                        plain(
                                          row.$3 == null ? '—' : pct(row.$3),
                                        ),
                                        actual: true,
                                      ),
                                      for (var i = 0; i < forecastHorizon; i++)
                                        cell(
                                          reverseMode
                                              ? plain(
                                                  forecasts.length > i
                                                      ? pct(
                                                          row.$4 == 'dnaM' ||
                                                                  row.$4 ==
                                                                      'capexM' ||
                                                                  row.$4 ==
                                                                      'nwcInvestmentM'
                                                              ? number(
                                                                      forecasts[i][row
                                                                          .$4],
                                                                    ) /
                                                                    number(
                                                                      forecasts[i]['revenueM'],
                                                                    )
                                                              : forecasts[i][row
                                                                    .$4],
                                                        )
                                                      : '—',
                                                  color: solvedCell(row.$5, i)
                                                      ? p.secondary
                                                      : p.text,
                                                  strong: solvedCell(row.$5, i),
                                                )
                                              : valuationCell(
                                                  row.$1[i],
                                                  i,
                                                  row.$2,
                                                  scheduleCalculation,
                                                ),
                                          solved:
                                              reverseMode &&
                                              solvedCell(row.$5, i),
                                        ),
                                    ],
                                  ),
                              TableRow(
                                children: [
                                  cell(
                                    plain(
                                      operating ? '—' : amount(base['fcfM']),
                                    ),
                                    actual: true,
                                  ),
                                  for (var i = 0; i < forecastHorizon; i++)
                                    cell(
                                      plain(
                                        forecasts.length > i
                                            ? amount(
                                                forecasts[i][operating
                                                    ? 'fcffM'
                                                    : 'fcfeM'],
                                              )
                                            : '—',
                                        color: p.text,
                                      ),
                                    ),
                                ],
                              ),
                              TableRow(
                                children: [
                                  cell(plain('—'), actual: true),
                                  for (var i = 0; i < forecastHorizon; i++)
                                    cell(
                                      plain(
                                        forecasts.length > i
                                            ? amount(forecasts[i]['pvM'])
                                            : '—',
                                        color: p.text,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(
                  reverseMode
                      ? 'Scroll across for all years. This path is read-only: change the target price, required return or solved variable in the control panel.'
                      : 'Scroll across for all years. Editing revenue updates its growth rate; later years retain their growth assumptions.',
                  reverseMode
                      ? '横向滑动查看全部年度。此路径为只读；请在控制区修改目标价格、要求回报或待求变量。'
                      : '横向滑动查看全部年度。改收入会联动该年增长率，后续年份保留其增长假设。',
                  size: 11,
                ),
                const SizedBox(height: 6),
                label(
                  reverseMode
                      ? 'The implied path is a mathematical solution, not management guidance, analyst consensus or a unique market expectation.'
                      : operating
                      ? '$forecastHorizon annual periods from the cutoff, paid at each period end. The editable operating paths are analyst assumptions, not issuer guidance.'
                      : '$forecastHorizon annual periods from the cutoff, paid at each period end — not reported fiscal years. TTM cash flow is CFO − capex, not verified parent FCFE.',
                  reverseMode
                      ? '隐含路径是数学求解结果，不是公司指引、分析师共识，也不是唯一的市场预期。'
                      : operating
                      ? '从基准日起的 $forecastHorizon 个年度期末折现。可编辑经营路径属于分析假设，并非公司指引。'
                      : '从基准日起的 $forecastHorizon 个年度期末折现，并非公司已报告财年。实际 TTM 现金流为 CFO 减资本开支，尚非已核验的母公司 FCFE。',
                  size: 11,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget valuationCell(
    TextEditingController controller,
    int year,
    String metric,
    VoidCallback changed,
  ) {
    final amount = metric == 'revenue';
    final en = 'Year ${year + 1} $metric${amount ? ' m' : ' %'}';
    final metricZh = amount
        ? '收入 百万'
        : {
                'growth': '增长 %',
                'FCFE margin': 'FCFE 率 %',
                'EBIT margin': 'EBIT 利润率 %',
                'cash tax rate': '现金税率 %',
                'D&A / revenue': '折旧摊销 / 收入 %',
                'capex / revenue': '资本开支 / 收入 %',
                'ΔNWC / revenue': 'ΔNWC / 收入 %',
              }[metric] ??
              '$metric %';
    final zh = '第 ${year + 1} 年$metricZh';
    return TextField(
      key: ValueKey('forecast-$en'),
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      textAlign: TextAlign.right,
      onChanged: (_) => changed(),
      style: TextStyle(
        color: p.accent,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        isDense: true,
        semanticCounterText: w(en, zh),
        hintText: '—',
        // Labels remain accessible without repeating them in every visible cell.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.accent.withValues(alpha: .22)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.accent.withValues(alpha: .22)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.accent),
        ),
        filled: true,
        fillColor: p.accent.withValues(alpha: .045),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      ),
    ).withSemanticsLabel(w(en, zh));
  }

  Widget valuationSourceBridge() {
    final bridge = asMap(company?['templateReconciliation']);
    final operating = personalDcfMethod == 'operating_fcff';
    return card([
      title('Know your starting point', '清楚你的起点'),
      label(
        independentValuation
            ? 'Historical facts → your forecast → your DCF'
            : 'Historical facts → platform starting path → your hypotheses',
        independentValuation ? '历史事实 → 你的预测 → 你的 DCF' : '历史事实 → 平台起始路径 → 你的假设',
        size: 12,
        color: p.accent,
      ),
      const SizedBox(height: 12),
      label(
        operating
            ? 'Revenue growth and every operating driver are editable analyst assumptions. Zero-valued equity-bridge inputs are explicit defaults until supported by evidence; they are not inferred facts.'
            : independentValuation
            ? 'The starting growth anchor fades to 2.5% by the selected horizon. Cash conversion uses a historical cycle margin, then TTM margin; if neither is available, 3% is an illustrative assumption. These are editable hypotheses, not verified parent FCFE or issuer forecasts. Negative forecast cash flows are preserved and disclosed as financing needs.'
            : 'Revenue uses the stored normalized growth assumption, fading to terminal growth. FCFE margins are derived to reproduce the published cash-flow path before post-DCF adjustments, not independently forecast margins or management guidance.',
        operating
            ? '收入增长及每项经营驱动均为可编辑的分析假设。股权价值桥中的零值是等待证据支持的明确默认假设，不是推导出的事实。'
            : independentValuation
            ? '起始增长率逐年收敛至所选预测期末的 2.5%。现金流率优先取历史周期值，其次 TTM 值；均不可用时，3% 仅为示例假设。这些均可修改，并非已验证母公司 FCFE 或管理层预测。预测期负现金流会保留并显示融资需求。'
            : '收入采用已存的标准化增长假设，逐年收敛至终值增长率。FCFE 率由平台现金流路径除以预测收入反推，不是独立预测的利润率，也不是管理层指引；不含 DCF 后的附加调整。',
        size: 12,
      ),
      if (!operating &&
          independentValuation &&
          asMap(bridge['startingForecast']).isNotEmpty) ...[
        const SizedBox(height: 10),
        label(
          'Initial growth ${pct(asMap(bridge['startingForecast'])['firstGrowth'])} → 2.5%; cash-flow margin ${pct(asMap(bridge['startingForecast'])['fcfeMargin'])}. ${asMap(bridge['startingForecast'])['recoveryAssumed'] == true ? 'A recovery to positive cash flow is assumed, not established.' : ''}',
          '初始增长 ${pct(asMap(bridge['startingForecast'])['firstGrowth'])} → 2.5%；现金流率 ${pct(asMap(bridge['startingForecast'])['fcfeMargin'])}。${asMap(bridge['startingForecast'])['recoveryAssumed'] == true ? '这里假设现金流转正，并非已证实。' : ''}',
          size: 12,
        ),
      ],
      if (nullableNumber(bridge['difference']) != null &&
          number(bridge['difference']).abs() > .005) ...[
        const SizedBox(height: 10),
        label(
          'Base DCF ${money(bridge['standaloneValue'])} · published DCF component ${money(bridge['publishedDcfValue'])} · adjustment bridge ${money(bridge['difference'])}. Your worksheet does not silently apply the published post-DCF adjustment.',
          '基准 DCF ${money(bridge['standaloneValue'])} · 平台 DCF 分项 ${money(bridge['publishedDcfValue'])} · 调整差额 ${money(bridge['difference'])}。个人表格不会暗中套用平台 DCF 后调整。',
          size: 12,
        ),
      ],
      const SizedBox(height: 10),
      label(
        operating
            ? 'FCFF is discounted at WACC to enterprise value; net debt and NCI are deducted once, and non-operating assets are added once, before dividing by shares.'
            : 'FCFE margin is after tax, interest, capex, working capital and ownership adjustments — not operating margin. No extra debt/NCI deduction, dividend or buyback addition.',
        operating
            ? 'FCFF 按 WACC 折现为企业价值；净债务和少数股东权益仅扣除一次，非经营资产仅加回一次，再除以股数。'
            : 'FCFE 率已扣税、利息、资本开支、营运资本及归属调整，不是营业利润率。不重复扣债务、少数股权或叠加分红回购。',
        size: 12,
      ),
      TextButton.icon(
        onPressed: () => selectSection('financials'),
        icon: const Icon(Icons.open_in_new, size: 15),
        label: Text(w('Review management guidance & financials', '查看管理层指引与财务')),
      ),
    ]);
  }

  Widget forecastOriginNotice() {
    final seed = asMap(
      asMap(company?['templateReconciliation'])['startingForecast'],
    );
    final audit = asMap(asMap(company?['guidance'])['audit']);
    final saved =
        template.isEmpty && asMap(company?['activeWorksheet']).isNotEmpty;
    return Padding(
      key: const ValueKey('forecast-origin-notice'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label(
            saved
                ? 'Your saved assumptions · preserved, not replaced by new defaults'
                : 'Model assumptions · not management’s annual guidance',
            saved ? '你的已存假设 · 保留修改，不被新默认值覆盖' : '模型假设 · 不是管理层逐年指引',
            color: p.accent,
            size: 12,
          ),
          if (!saved && seed['firstGrowth'] != null)
            label(
              personalDcfMethod == 'operating_fcff'
                  ? 'Starting revenue growth ${pct(seed['firstGrowth'])} → ${pct(seed['finalGrowth'])} in Year $forecastHorizon. EBIT, tax, reinvestment and the equity bridge are editable analyst assumptions.'
                  : 'Starting revenue growth ${pct(seed['firstGrowth'])} → ${pct(seed['finalGrowth'])} in Year $forecastHorizon. ${independentValuation ? 'Cash conversion is an editable starting assumption.' : 'FCFE margins reconcile the existing cash-flow forecast; the starting DCF is unchanged.'}',
              personalDcfMethod == 'operating_fcff'
                  ? '起始收入增长 ${pct(seed['firstGrowth'])} → 第 $forecastHorizon 年 ${pct(seed['finalGrowth'])}。EBIT、税率、再投资和股权价值桥均为可修改的分析假设。'
                  : '起始收入增长 ${pct(seed['firstGrowth'])} → 第 $forecastHorizon 年 ${pct(seed['finalGrowth'])}。${independentValuation ? '现金流率为可修改的起始假设。' : 'FCFE 率反推以核对原现金流预测，起始 DCF 不变。'}',
              size: 11,
            ),
          label(
            '$forecastHorizon rolling model years from $asOf, not the issuer’s fiscal years. Missing guidance is not 0%.',
            '从 $asOf 起算的 $forecastHorizon 个滚动预测年度，不是公司财年。缺少指引不等于 0%。',
            size: 11,
          ),
          if (audit['annualRevenueCount'] == 0)
            label(
              'No usable company-wide annual revenue guidance in this stored snapshot; growth above is a model assumption.',
              '此存储快照未识别出可用的公司整体年度收入指引；上方增长率来自模型假设。',
              size: 11,
            ),
          if (audit['status'] == 'review_required')
            label(
              'Guidance audit needs review. Some original excerpts or stored model references did not pass; the published model has not been recertified.',
              '指引审计待复核：部分原文或已存模型引用未通过检查，平台模型尚未重新认证。',
              color: p.secondary,
              size: 11,
            ),
        ],
      ),
    );
  }

  Widget valuationTerminalSummary(Map<String, dynamic> result) => card([
    title('Terminal value', '终值'),
    label(
      'Year ${forecastHorizon + 1} onward · valued at the end of Year $forecastHorizon',
      '第 ${forecastHorizon + 1} 年及以后 · 在第 $forecastHorizon 年末估值',
      size: 12,
    ),
    const SizedBox(height: 16),
    LayoutBuilder(
      builder: (_, bounds) {
        final values = [
          (
            'Terminal value · Y$forecastHorizon',
            '第 $forecastHorizon 年末终值',
            result['terminalValueM'],
          ),
          ('Terminal present value', '终值折现现值', result['terminalPvM']),
          (
            'Years 1–$forecastHorizon present value',
            '第 1–$forecastHorizon 年现金流现值',
            result['explicitPvM'],
          ),
          ('Terminal share of DCF', '终值占 DCF 比例', result['terminalShare']),
        ];
        final columns = bounds.maxWidth < 700 ? 2 : 4;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var i = 0; i < values.length; i++)
              SizedBox(
                width: (bounds.maxWidth - 16 * (columns - 1)) / columns,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label(values[i].$1, values[i].$2, size: 12),
                    const SizedBox(height: 8),
                    Text(
                      i == 3
                          ? pct(values[i].$3)
                          : nullableNumber(values[i].$3) == null
                          ? '—'
                          : '${formatNumber(number(values[i].$3))}m',
                      style: TextStyle(
                        color: p.accent,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
    const SizedBox(height: 16),
    label(
      personalDcfMethod == 'operating_fcff'
          ? 'Amounts in ${text(company?['currency'])} millions. TV = Year $forecastHorizon FCFF × (1 + g) ÷ (WACC − g); PV(TV) = TV ÷ (1 + WACC)^$forecastHorizon.'
          : 'Amounts in ${text(company?['currency'])} millions. TV = Year $forecastHorizon FCFE × (1 + g) ÷ (Ke − g); PV(TV) = TV ÷ (1 + Ke)^$forecastHorizon.',
      personalDcfMethod == 'operating_fcff'
          ? '金额单位：百万 ${text(company?['currency'])}。终值 = 第 $forecastHorizon 年 FCFF × (1 + g) ÷ (WACC − g)；终值现值 = 终值 ÷ (1 + WACC)^$forecastHorizon。'
          : '金额单位：百万 ${text(company?['currency'])}。终值 = 第 $forecastHorizon 年 FCFE × (1 + g) ÷ (Ke − g)；终值现值 = 终值 ÷ (1 + Ke)^$forecastHorizon。',
      size: 12,
    ),
    label(
      personalDcfMethod == 'operating_fcff'
          ? 'Equity value = enterprise value − net debt − NCI + non-operating assets; per-share value = equity value ÷ shares.'
          : 'DCF = (Years 1–$forecastHorizon PV + terminal PV) ÷ shares. g is perpetual growth, not next year’s revenue growth.',
      personalDcfMethod == 'operating_fcff'
          ? '股权价值 = 企业价值 − 净债务 − 少数股东权益 + 非经营资产；每股价值 = 股权价值 ÷ 股数。'
          : 'DCF =（第 1–$forecastHorizon 年现值 + 终值现值）÷ 股数。g 是永续增长，不是下一年的收入增长。',
      size: 12,
    ),
  ]);

  Widget valuationDiagnostics(Map<String, dynamic> result) => card([
    ExpansionTile(
      key: ValueKey('valuation-diagnostics-$inspectInputs'),
      tilePadding: EdgeInsets.zero,
      title: Text(w('Stress-test & calculation details', '压力测试与计算明细')),
      initiallyExpanded: inspectInputs,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 16,
          children: [
            for (final t in [
              ('Bear', '悲观'),
              ('Base', '基准'),
              ('Bull', '乐观'),
            ].where((t) => asMap(company?['templates']).containsKey(t.$1)))
              valuationSummary(
                money(asMap(calculation?['templateResults'])[t.$1]),
                t.$1,
                t.$2,
              ),
          ],
        ),
        const SizedBox(height: 16),
        label(
          personalDcfMethod == 'operating_fcff'
              ? 'Reverse DCF solves one operating parameter at a time and re-runs the same forward FCFF engine. It is not consensus.'
              : 'Mechanical templates, not predictions. Reverse growth solves one constant $forecastHorizon-year rate with all margins fixed.',
          personalDcfMethod == 'operating_fcff'
              ? '反向 DCF 每次只求解一个经营参数，并使用同一 FCFF 正向引擎回代；它不是市场共识。'
              : '机械模板不是预测，反向估值固定现金流率，求解 $forecastHorizon 年恒定增长率。',
          size: 12,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            input(
              reversePrice,
              'Price to explain',
              '待解释价格',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            input(
              targetReturn,
              'Required return %',
              '要求回报 %',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            for (final v
                in personalDcfMethod == 'operating_fcff'
                    ? [
                        ('growth', 'Solve growth', '反推增长'),
                        (
                          'mature_ebit_margin',
                          'Solve mature EBIT margin',
                          '反推成熟 EBIT 利润率',
                        ),
                        (
                          'reinvestment',
                          'Solve ΔNWC / revenue',
                          '反推 ΔNWC / 收入',
                        ),
                      ]
                    : [
                        ('growth', 'Solve growth', '反推增长'),
                        ('terminal_margin', 'Solve final margin', '反推末期率'),
                      ])
              ChoiceChip(
                label: Text(w(v.$2, v.$3)),
                selected: reverseVariable == v.$1,
                onSelected: (_) {
                  updateUI(() => reverseVariable = v.$1);
                  scheduleCalculation();
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        label(
          asMap(calculation?['reverse'])['status'] == 'solved'
              ? 'Solved: ${pct(asMap(calculation?['reverse'])['value'])}'
              : 'No solution within supported bounds.',
          asMap(calculation?['reverse'])['status'] == 'solved'
              ? '求解：${pct(asMap(calculation?['reverse'])['value'])}'
              : '支持边界内无解。',
          color: p.accent,
        ),
        const SizedBox(height: 16),
        dataTable(
          [w('Component', '组成'), '${text(company?['currency'])} m'],
          [
            [
              personalDcfMethod == 'operating_fcff'
                  ? w('Explicit FCFF present value', '显性 FCFF 现值')
                  : w('Explicit FCFE present value', '显性 FCFE 现值'),
              nullableNumber(result['explicitPvM'])?.toStringAsFixed(2) ?? '—',
            ],
            [
              w(
                'Terminal value at Year $forecastHorizon',
                '第 $forecastHorizon 年末终值',
              ),
              nullableNumber(result['terminalValueM'])?.toStringAsFixed(2) ??
                  '—',
            ],
            [
              w('Terminal present value', '终值现值'),
              nullableNumber(result['terminalPvM'])?.toStringAsFixed(2) ?? '—',
            ],
            [
              w('Terminal share of value', '终值占比'),
              pct(result['terminalShare']),
            ],
            if (personalDcfMethod == 'operating_fcff') ...[
              [
                w('Enterprise value', '企业价值'),
                nullableNumber(
                      result['enterpriseValueM'],
                    )?.toStringAsFixed(2) ??
                    '—',
              ],
              [
                w('Net debt deducted', '扣除净债务'),
                nullableNumber(result['netDebtM'])?.toStringAsFixed(2) ?? '—',
              ],
              [
                w('NCI deducted', '扣除少数股东权益'),
                nullableNumber(result['nciM'])?.toStringAsFixed(2) ?? '—',
              ],
              [
                w('Non-operating assets added', '加回非经营资产'),
                nullableNumber(
                      result['nonOperatingAssetsM'],
                    )?.toStringAsFixed(2) ??
                    '—',
              ],
              [
                w('Equity value', '股权价值'),
                nullableNumber(result['equityValueM'])?.toStringAsFixed(2) ??
                    '—',
              ],
            ] else ...[
              [w('Net debt deducted again', '再次扣除净债务'), '0'],
              [w('NCI deducted again', '再次扣除少数股东权益'), '0'],
            ],
          ],
        ),
        dataTable(
          [
            personalDcfMethod == 'operating_fcff' ? 'WACC' : 'Ke',
            'g',
            w('Value / share', '每股价值'),
          ],
          [
            for (final r in asList(calculation?['sensitivity']))
              [
                pct(r[personalDcfMethod == 'operating_fcff' ? 'wacc' : 'ke']),
                pct(r['g']),
                money(r['fairValue']),
              ],
          ],
        ),
        if (personalDcfMethod == 'operating_fcff' &&
            asList(asMap(calculation?['isoValueCurve'])['points']).isNotEmpty)
          dataTable(
            [
              w('Revenue growth', '收入增长'),
              w('Mature EBIT margin', '成熟 EBIT 利润率'),
              w('Forward-check value', '回代价值'),
            ],
            [
              for (final row in asList(
                asMap(calculation?['isoValueCurve'])['points'],
              ))
                [
                  pct(row['growth']),
                  pct(row['matureEbitMargin']),
                  money(row['verifiedValue']),
                ],
            ],
          ),
      ],
    ),
  ]);
}

extension _ValuationSemantics on Widget {
  Widget withSemanticsLabel(String label) =>
      Semantics(label: label, child: this);
}
