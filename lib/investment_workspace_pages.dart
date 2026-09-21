part of 'main.dart';

extension _InvestmentWorkspacePages on _InvestmentWorkspaceState {
  Future<bool> allowLeaveDraft() async {
    if (worksheetMemoryEnabled) {
      if (await persistWorksheet()) return true;
    } else if (!draftDirty) {
      return true;
    }
    if (!mounted) return false;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(w('Leave this unsaved scenario?', '离开未保存的情景？')),
        content: Text(
          w(
            'Your saved versions will stay intact. This sandbox has changes that have not been saved.',
            '已保存版本不会改变，但本次试算包含未保存的修改。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(w('Keep editing', '继续编辑')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(w('Leave without saving', '不保存并离开')),
          ),
        ],
      ),
    );
    if (discard == true && mounted) updateUI(() => draftDirty = false);
    return discard == true;
  }

  Future<void> requestNavigate(String next) async {
    if (page == next) return;
    if (page == 'research' && !await allowLeaveDraft()) return;
    if (next == 'admin') {
      if (mounted && widget.showAdmin) widget.onLegacyView?.call('admin');
      return;
    }
    if (next == 'research' &&
        company == null &&
        opportunityCompany != null &&
        opportunityCutoff == asOf &&
        opportunityCompany?['ticker'] == opportunityTicker) {
      opportunityReturnPage = page == 'discover' ? 'discover' : 'home';
      opportunityReturnDate = asOf;
      persistOpportunity();
      await loadCompany(opportunityTicker);
      return;
    }
    if (page == 'research' &&
        const {'home', 'discover'}.contains(next) &&
        opportunityReturnDate.isNotEmpty) {
      asOf = opportunityReturnDate;
      opportunityReturnDate = '';
      persistOpportunity();
    }
    if (mounted) navigate(next);
  }

  Future<void> requestLogout() async {
    if (page == 'research' && !await allowLeaveDraft()) return;
    if (mounted) widget.onLogout?.call();
  }

  void selectSection(String next) {
    updateUI(() => section = next);
    navigate('research');
    if (next == 'financials' &&
        (researchDocumentsData == null || researchFundamental == null)) {
      unawaited(loadResearchPanel('financials'));
    } else if (next == 'institutions' && researchInstitution == null) {
      unawaited(loadResearchPanel('institutions'));
    } else if (next == 'records' && researchRecordsData == null) {
      unawaited(loadResearchPanel('records'));
    }
  }

  Future<void> enterTerminal({String mode = 'guru'}) async {
    if (!await allowLeaveDraft() || !mounted) return;
    navigate(mode == 'portfolio' ? 'book' : 'discover');
  }

  Widget sourceBreadcrumb() {
    final entry = entryEvidence;
    String source = w('Direct company research', '直接研究公司');
    if (discoveryOrigin == 'fundamental_research') {
      source = w(
        'Discover / Fundamental changes / $ticker / $asOf',
        '发现 / 基本面变化 / $ticker / $asOf',
      );
    }
    if (discoveryOrigin == 'value_flow') {
      source = w(
        'Discover / AI value chain / $ticker / $asOf',
        '发现 / AI 产业链 / $ticker / $asOf',
      );
    }
    if (opportunityReturnDate.isNotEmpty && ticker == opportunityTicker) {
      source = opportunityReturnPage == 'discover'
          ? '${w('Discover', '发现')} / ${discoverCollectionName(discoverCollection)} / $opportunityTicker / $asOf'
          : w(
              'Shared holdings / $opportunityTicker / Evidence as of $asOf',
              '集合持仓 / $opportunityTicker / 证据截止 $asOf',
            );
    }
    if (discoveryOrigin == 'fundamental_rule') {
      source = w(
        'Discover / Quarterly revenue growth ≥ 15%',
        '发现 / 季度收入同比 ≥ 15%',
      );
    }
    if (discoveryOrigin == 'guru_disclosure' && entry != null) {
      final g = asList(
        home?['gurus'],
      ).where((g) => g['id'] == entry['guruId']).firstOrNull;
      final name = text(entry['name'], text(g?['name'], text(entry['guruId'])));
      source = 'Discover / $name';
      if (text(entry['reportDate']).isNotEmpty) {
        source += ' / ${entry['reportDate']}';
      }
    }
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          onPressed: () => unawaited(
            opportunityReturnDate.isNotEmpty
                ? returnToOpportunities()
                : requestNavigate('discover'),
          ),
          icon: const Icon(Icons.arrow_back, size: 15),
          label: Text(
            discoveryOrigin == 'fundamental_research'
                ? w('Back to business changes', '返回经营变化')
                : discoveryOrigin == 'value_flow'
                ? w('Back to value chain', '返回产业链')
                : opportunityReturnDate.isNotEmpty
                ? w('Back to candidates', '返回候选列表')
                : w('Discover', '发现'),
          ),
        ),
        FlexibleText(source, p: p),
        if (entry != null && text(entry['availableAt']).isNotEmpty)
          label(
            'Filed ${entry['availableAt']}',
            '披露 ${entry['availableAt']}',
            size: 12,
          ),
      ],
    );
  }

  Widget pageColumns(
    Widget main,
    Widget side, {
    double sideWidth = 340,
    bool sideFirstOnCompact = false,
  }) => LayoutBuilder(
    builder: (_, c) {
      if (c.maxWidth < 850) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sideFirstOnCompact
              ? [side, const SizedBox(height: 28), main]
              : [main, side],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: main),
          const SizedBox(width: 22),
          SizedBox(width: sideWidth, child: side),
        ],
      );
    },
  );

  // Legacy route helpers remain for old saved URLs while Research owns the new flow.
  // ignore: unused_element
  List<Widget> valueWorkspace() =>
      assumptions.isEmpty ? detailedValueView() : personalValueWorkspace();

  String actionLabel(String a) => w(
    a,
    {
          'Watch': '观察',
          'Pass': '放弃',
          'Invest': '投资',
          'Maintain': '维持',
          'Change': '修改假设',
          'Add': '加仓',
          'Reduce': '减仓',
          'Exit': '退出',
        }[a] ??
        a,
  );

  // ignore: unused_element
  List<Widget> decisionPage() => [
    card([
      title('What do you want to do?', '你准备怎么做？'),
      label(
        'A decision links your rationale to a fixed scenario and dated evidence. Nothing here places a broker order.',
        '决策将理由、固定情景版本和有日期的证据绑定，不发送券商订单。',
      ),
      const SizedBox(height: 18),
      if (scenarioId == null) ...[
        label(
          'First, confirm the assumptions you want this decision to use.',
          '请先确认本次决策采用的假设。',
          color: p.secondary,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: button(
            'Review and save a scenario',
            '检查并保存情景',
            () => selectSection('value'),
          ),
        ),
      ] else
        label(
          '$ticker · ${money(asMap(calculation?['result'])['fairValue'])} / share · $asOf · saved version',
          '$ticker · 每股 ${money(asMap(calculation?['result'])['fairValue'])} · $asOf · 已保存版本',
          color: p.accent,
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (final a in ['Watch', 'Pass', 'Invest'])
            ChoiceChip(
              label: Text(actionLabel(a)),
              selected: decisionAction == a,
              onSelected: (_) => updateUI(() {
                decisionAction = a;
                if (a != 'Watch') priority = false;
              }),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (decisionAction == 'Watch')
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            w('Priority watch — include in Home monitoring', '重点观察 — 加入首页监测'),
          ),
          value: priority,
          onChanged: (v) => updateUI(() => priority = v ?? false),
        ),
      if (decisionAction == 'Invest') ...[
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            input(units, 'Research units', '研究股数', numeric: true),
            input(
              weight,
              'Target portfolio weight %',
              '目标组合权重 %',
              numeric: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        label(
          'This creates a research position, separate from your brokerage account.',
          '这会建立研究仓位，与券商账户分开。',
        ),
      ],
      if (decisionAction == 'Pass')
        label(
          'Keep the evidence and your reason for passing. You can revisit the record later.',
          '保留证据和放弃理由，之后仍可重新复核。',
        ),
      const SizedBox(height: 14),
      TextField(
        controller: notes,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: w('My rationale / what could go wrong', '我的理由 / 可能出错的地方'),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(w('Add a fundamental review rule', '增加基本面复核规则')),
        subtitle: Text(
          w('Optional. No rule is enabled by default.', '可选，默认不启用任何规则。'),
        ),
        value: ruleEnabled,
        onChanged: (v) => updateUI(() => ruleEnabled = v ?? false),
      ),
      if (ruleEnabled) ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in [
              'revenueGrowth',
              'operatingMargin',
              'fcfMargin',
              'capexIntensity',
            ])
              ChoiceChip(
                label: Text(metricName(m)),
                selected: ruleMetric == m,
                onSelected: (_) => updateUI(() => ruleMetric = m),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 12,
          children: [
            for (final o in [('lt', 'Below', '低于'), ('gt', 'Above', '高于')])
              ChoiceChip(
                label: Text(w(o.$2, o.$3)),
                selected: ruleOperator == o.$1,
                onSelected: (_) => updateUI(() => ruleOperator = o.$1),
              ),
            input(threshold, 'Threshold %', '阈值 %', numeric: true),
            input(
              consecutive,
              'Consecutive new periods',
              '连续新报告期',
              numeric: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        label(
          'Only newly disclosed financial periods count. Missing observations cannot satisfy a rule. Triggers request a review, never a trade.',
          '仅统计新披露财务期。缺失值不能满足规则；触发只要求复核，不会交易。',
          size: 12,
        ),
      ],
      const SizedBox(height: 22),
      Align(
        alignment: Alignment.centerLeft,
        child: button(
          'Record decision snapshot',
          '记录决策快照',
          scenarioId == null || decisionAction.isEmpty
              ? null
              : () => unawaited(saveDecision()),
          primary: true,
        ),
      ),
    ]),
  ];

  // ignore: unused_element
  List<Widget> comparisonPage() {
    if (review == null) return [];
    final original = asMap(review?['decision']),
        active = asMap(review?['activeScenario']);
    final baseline = reviewOriginal ? asMap(original['scenario']) : active;
    final now = asMap(asMap(review?['now'])['snapshot']);
    final rows = asList(review?[reviewOriginal ? 'delta' : 'activeDelta']);
    return [
      card([
        title('Then vs Now', '当时与现在'),
        label(
          'Compare new facts using the same saved assumptions. An edited scenario is a separate decision.',
          '用同一份已保存假设比较新事实。修改情景是另一项决策。',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(w('Last confirmed', '最近确认')),
              selected: !reviewOriginal,
              onSelected: (_) => updateUI(() => reviewOriginal = false),
            ),
            ChoiceChip(
              label: Text(w('Original decision', '原始决策')),
              selected: reviewOriginal,
              onSelected: (_) => updateUI(() => reviewOriginal = true),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 38,
          runSpacing: 18,
          children: [
            metricDisplay(
              money(review?[reviewOriginal ? 'thenValue' : 'activeThenValue']),
              'Then · saved v${baseline['version']}',
              '当时 · 已保存 v${baseline['version']}',
              detail: w('As of ${baseline['asOf']}', '截至 ${baseline['asOf']}'),
              size: 34,
            ),
            metricDisplay(
              money(
                asMap(
                  review?[reviewOriginal
                      ? 'originalSameAssumptions'
                      : 'sameAssumptions'],
                )['fairValue'],
              ),
              'Now · same assumptions',
              '现在 · 相同假设',
              detail: w('As of $asOf', '截至 $asOf'),
              size: 34,
            ),
          ],
        ),
        const SizedBox(height: 16),
        label(
          'Now uses ${now['period']} financials, available ${now['availableAt']}. Both values use the selected baseline assumptions.',
          '现在使用 ${now['period']} 财务数据，可用日期 ${now['availableAt']}。两侧估值使用同一组选定假设。',
          size: 12,
        ),
        const SizedBox(height: 12),
        dataTable(
          [
            w('Metric', '指标'),
            w('Then', '当时'),
            w('Now', '现在'),
            w('Change (pp)', '变化（百分点）'),
          ],
          [
            for (final r in rows)
              [
                metricName(text(r['metric'])),
                pct(r['then']),
                pct(r['now']),
                nullableNumber(r['then']) == null ||
                        nullableNumber(r['now']) == null
                    ? '—'
                    : ((number(r['now']) - number(r['then'])) * 100)
                          .toStringAsFixed(2),
              ],
          ],
        ),
        if (asList(review?['guruChanges']).isNotEmpty)
          label(
            'The original discovery Guru reported a share-count change. Corporate-action comparability is unverified.',
            '原始来源大佬的申报股数发生变化，公司行动可比性尚未验证。',
            color: p.secondary,
          ),
        ExpansionTile(
          title: Text(w('Review rules and observations', '复核规则与观测')),
          children: [
            if (asList(review?['triggers']).isEmpty)
              label('No rules were saved for this decision.', '此决策未保存复核规则。'),
            for (final t in asList(review?['triggers']))
              ListTile(
                title: Text(
                  '${metricName(text(asMap(t['rule'])['metric']))} ${asMap(t['rule'])['operator'] == 'lt' ? '<' : '>'} ${pct(asMap(t['rule'])['threshold'])}',
                ),
                subtitle: Text(
                  w(
                    text(t['status']).replaceAll('_', ' '),
                    t['status'] == 'review_required'
                        ? '需要复核'
                        : t['status'] == 'not_triggered'
                        ? '未触发'
                        : '数据不足',
                  ),
                ),
              ),
          ],
        ),
        ExpansionTile(
          title: Text(w('Saved review history', '已保存复核历史')),
          children: [
            if (asList(review?['reviewHistory']).isEmpty)
              label('No reviews yet.', '尚无复核记录。'),
            for (final r in asList(review?['reviewHistory']))
              ListTile(
                title: Text(
                  '${r['asOf']} · ${actionLabel(text(r['action']))} · v${asMap(r['scenario'])['version']}',
                ),
                subtitle: Text(text(r['notes'])),
              ),
          ],
        ),
      ]),
      card([
        title('What do you decide now?', '现在你如何决定？'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in [
              'Maintain',
              'Change',
              if (number(review?['activeUnits']) > 0) ...[
                'Add',
                'Reduce',
                'Exit',
              ],
            ])
              ChoiceChip(
                label: Text(actionLabel(a)),
                selected: reviewAction == a,
                onSelected: (_) => updateUI(() => reviewAction = a),
              ),
          ],
        ),
        if (reviewAction == 'Change') ...[
          const SizedBox(height: 12),
          label(
            scenarioId == null
                ? 'Edit and save a new version. Return here to confirm the change.'
                : 'A new scenario version is ready to attach to this review.',
            scenarioId == null ? '编辑并保存新版本，再回到这里确认修改。' : '新情景版本已保存，可以绑定本次复核。',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: button(
              'Edit scenario',
              '编辑情景',
              () => selectSection('value'),
            ),
          ),
        ],
        if (reviewAction == 'Add' || reviewAction == 'Reduce')
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: input(
              units,
              'New total research units',
              '新的研究总股数',
              numeric: true,
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: reviewNotes,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: w('What changed in my thinking?', '我的判断发生了什么变化？'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: button(
            'Save review snapshot',
            '保存复核快照',
            reviewAction.isEmpty ||
                    (reviewAction == 'Change' && scenarioId == null)
                ? null
                : () => unawaited(saveReview()),
            primary: true,
          ),
        ),
        label(
          'A review never overwrites the original. No broker order is sent.',
          '复核不会覆盖原始记录，不发送券商订单。',
          size: 12,
        ),
      ]),
    ];
  }

  List<Widget> researchPortfolioPage() {
    return [
      PortfolioResearchPanel(
        api: widget.api,
        palette: p,
        asOf: asOf,
        cutoffControl: dateControl(),
        onCompany: (symbol, section) =>
            unawaited(loadCompany(symbol, initialSection: section)),
        onGuru: (id, filing) {
          discoveryTab = 'managers';
          navigate('discover');
          unawaited(loadGuru(id, filingId: filing));
        },
      ),
      const SizedBox(height: 24),
      ValueListenableBuilder<bool>(
        valueListenable: portfolioPrivacyMode,
        builder: (_, hidden, _) => ExpansionTile(
          key: ValueKey('research-ledger-privacy-$hidden'),
          tilePadding: EdgeInsets.zero,
          leading: Icon(Icons.history_edu_outlined, color: p.muted),
          title: Text(w('Research decisions & allocations', '研究决策与模拟仓位')),
          subtitle: Text(
            hidden
                ? w(
                    'Hidden in privacy mode — notes may contain amounts',
                    '隐私模式下已隐藏，笔记可能包含金额',
                  )
                : w('Separate from your connected accounts', '与真实账户持仓分开记录'),
          ),
          enabled: !hidden,
          children: hidden ? const [] : researchDecisionLedgerPage(),
        ),
      ),
    ];
  }

  List<Widget> researchDecisionLedgerPage() {
    final book = asMap(home?['portfolio']);
    return [
      title('A portfolio of decisions.', '由决策组成的组合。'),
      label(
        'Research positions, not a brokerage account. Every holding starts with a saved investment case.',
        '这是研究组合，不是券商账户。每个仓位都有保存的投资判断。',
      ),
      const SizedBox(height: 22),
      Wrap(
        spacing: 8,
        children: [
          for (final t in [
            ('positions', 'Positions', '持仓'),
            ('journal', 'Decision journal', '决策记录'),
            ('shadow', 'Guru comparison', '大佬对照'),
          ])
            ChoiceChip(
              label: Text(w(t.$2, t.$3)),
              selected: portfolioTab == t.$1,
              onSelected: (_) => updateUI(() => portfolioTab = t.$1),
            ),
        ],
      ),
      const SizedBox(height: 20),
      if (portfolioTab == 'positions')
        card([
          if (asList(book['positions']).isEmpty) ...[
            title(
              'Your first position starts with a thesis.',
              '第一笔仓位，从一份判断开始。',
            ),
            label(
              'Research a company, save a scenario and choose Invest. Watch and Pass decisions stay in the journal.',
              '研究公司、保存情景并选择投资。观察和放弃记录保留在决策日志。',
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: button(
                'Start research',
                '开始研究',
                () => navigate('discover'),
                primary: true,
              ),
            ),
          ],
          for (final t in asList(book['totals']))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: metricDisplay(
                nullableNumber(t['marketValue']) == null
                    ? '—'
                    : '${t['currency']} ${formatNumber(number(t['marketValue']))}',
                'Research market value',
                '研究仓位市值',
                detail: w(
                  '${t['unpriced']} unpriced · no currency mixing',
                  '${t['unpriced']} 个缺失价格 · 不混合币种',
                ),
                size: 30,
              ),
            ),
          for (final r in asList(book['positions']))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: StockLogo(
                ticker: text(r['ticker']),
                palette: p,
                size: 34,
              ),
              title: Text('${r['ticker']} · ${r['units']} ${w('units', '股')}'),
              subtitle: Text(
                '${r['currency']} ${nullableNumber(r['marketValue'])?.toStringAsFixed(2) ?? '—'} · ${w('Weight', '权重')} ${pct(r['weight'])} · ${asMap(r['price'])['date'] ?? ''}',
              ),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () => unawaited(openReview(text(r['decisionId']))),
            ),
        ]),
      if (portfolioTab == 'journal')
        card([
          title('The decision — and the reason.', '记录决定，也记录理由。'),
          if (asList(home?['decisions']).isEmpty)
            label('No saved decisions yet.', '尚无保存的决策。'),
          for (final d in asList(home?['decisions']).reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: StockLogo(
                ticker: text(d['ticker']),
                palette: p,
                size: 32,
              ),
              title: Text('${d['ticker']} · ${actionLabel(text(d['action']))}'),
              subtitle: Text(
                '${d['decisionDate']} · v${asMap(d['scenario'])['version']}\n${text(d['notes'])}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.arrow_forward),
              onTap: () => unawaited(openReview(text(d['decisionId']))),
            ),
        ]),
      if (portfolioTab == 'shadow')
        card([
          title('Your book vs Guru Shadow', '你的组合与大佬影子组合'),
          label(
            'Differences are research questions, not instructions to copy. Requires complete selected books in a common currency.',
            '差异是研究问题，不是跟单指令。需要完整且币种可比的选定组合。',
          ),
          if (asList(book['overlap']).isEmpty)
            label(
              'No comparable pair of books yet. Configure your Guru selection in Strategies.',
              '暂时没有可比较的两组持仓，请到策略中设置大佬选择。',
            ),
          if (asList(book['overlap']).isNotEmpty)
            dataTable(
              [
                w('Stock', '股票'),
                w('Yours', '你的权重'),
                'Shadow',
                w('Difference', '偏差'),
              ],
              [
                for (final r in asList(book['overlap']))
                  [
                    text(r['ticker']),
                    pct(r['fundamentalWeight']),
                    pct(r['shadowWeight']),
                    pct(r['deviation']),
                  ],
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: button(
              'Configure Guru Shadow',
              '配置大佬影子组合',
              () => navigate('strategies'),
            ),
          ),
        ]),
      label(
        'Broker execution, corporate-action reconciliation and CTA risk metrics are not connected in this workspace. Missing metrics are not zero.',
        '此工作区未连接券商成交、公司行动对账和 CTA 风险指标。指标缺失不代表为零。',
        size: 12,
      ),
    ];
  }

  List<Widget> strategyPage() {
    return [
      StrategyLabPanel(
        api: widget.api,
        palette: p,
        asOf: asOf,
        onCompany: (ticker) =>
            unawaited(loadCompany(ticker, initialSection: 'value')),
      ),
    ];
  }

  // Kept during the gated workflow migration; the terminal and stored rules
  // remain separate from Strategy Lab's versioned backtest rules.
  // ignore: unused_element
  List<Widget> legacyStrategySelectionPage() {
    final shadow = asMap(asMap(home?['portfolio'])['shadow']);
    return [
      title('Rules before results.', '规则先于结果。'),
      label(
        'Choose the managers and the rule. Keep the assumptions visible before looking at performance.',
        '先选择经理和规则，再查看表现，始终明确假设。',
      ),
      const SizedBox(height: 24),
      pageColumns(
        card([
          title('Build a Guru Shadow selection', '建立大佬影子组合选股规则'),
          label('1. Select up to 10 managers', '1. 选择最多 10 位经理'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in asList(home?['gurus']))
                FilterChip(
                  avatar: GuruAvatar(
                    guru: {...g, 'avatarUrl': g['avatar']},
                    palette: p,
                    size: 24,
                  ),
                  label: Text(text(g['name'])),
                  selected: strategyManagers.contains(text(g['id'])),
                  onSelected: (v) => updateUI(() {
                    if (!v) {
                      strategyManagers.remove(text(g['id']));
                    } else if (strategyManagers.length < 10) {
                      strategyManagers.add(text(g['id']));
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 22),
          label(
            '2. Choose each manager’s top common-stock holdings',
            '2. 选择每位经理普通股多头前几名',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final n in [1, 2, 3])
                ChoiceChip(
                  label: Text('Top $n'),
                  selected: strategyTopN == n,
                  onSelected: (_) => updateUI(() => strategyTopN = n),
                ),
            ],
          ),
          const SizedBox(height: 20),
          label(
            '3. Duplicate stocks are combined, then equally weighted. Filings must be available by your cutoff. No DCF filter.',
            '3. 合并重复股票后等权；只使用截止日可得披露，不使用 DCF 过滤。',
          ),
          const SizedBox(height: 22),
          Align(
            alignment: Alignment.centerLeft,
            child: button(
              'Save selection rules',
              '保存选股规则',
              strategyManagers.isEmpty
                  ? null
                  : () => unawaited(
                      command(() async {
                        await widget.api
                            .postJson('/api/investment/strategies', {
                              'operationId': op(),
                              'asOf': asOf,
                              'managers': strategyManagers.toList(),
                              'topN': strategyTopN,
                            });
                        await loadHome();
                        if (mounted) {
                          updateUI(
                            () => notice = w(
                              'Rule version saved. The disclosure preview below uses this selection.',
                              '规则版本已保存，下方披露预览使用本次选择。',
                            ),
                          );
                        }
                      }),
                    ),
              primary: true,
            ),
          ),
        ]),
        card([
          title('Know what this is.', '明确这个结果是什么。'),
          label(
            'A disclosure-based selection preview — not a live portfolio, executable strategy or fund return.',
            '这是基于披露的选股预览，不是实时组合、可执行策略或基金收益。',
          ),
          const SizedBox(height: 14),
          label(
            'Full return curves, execution coverage checks and free date-range controls remain in the existing backtest terminal.',
            '完整收益曲线、执行覆盖检查和自由区间保留在现有回测终端。',
          ),
          const SizedBox(height: 18),
          button(
            'Open audited backtests',
            '打开已有审计回测',
            () => unawaited(enterTerminal()),
          ),
        ]),
      ),
      card([
        title('Published-holdings preview', '已披露持仓预览'),
        label(
          'Active rule: Top ${asMap(shadow['rules'])['topN'] ?? '—'} · ${(asMap(shadow['rules'])['managers'] as List? ?? []).length} managers · $asOf',
          '生效规则：Top ${asMap(shadow['rules'])['topN'] ?? '—'} · ${(asMap(shadow['rules'])['managers'] as List? ?? []).length} 位经理 · $asOf',
        ),
        label(
          '${shadow['strategyVersionId'] == null ? 'Default preset (not your saved selection)' : 'Saved selection'}: ${(asMap(shadow['rules'])['managers'] as List? ?? []).join(', ')}',
          '${shadow['strategyVersionId'] == null ? '默认预设（非你保存的选择）' : '已保存选择'}：${(asMap(shadow['rules'])['managers'] as List? ?? []).join(', ')}',
          size: 12,
        ),
        for (final i in asList(shadow['issues']))
          label(
            '${i['guruId']} · ${text(i['reason']).replaceAll('_', ' ')}',
            '${i['guruId']} · 持仓身份或披露不完整',
            color: p.secondary,
          ),
        if (asList(shadow['holdings']).isEmpty)
          label(
            'No complete selected book is available. No substitute weights or returns are generated.',
            '暂无完整选定组合，不生成替代权重或收益。',
          ),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: [
            for (final h in asList(shadow['holdings']))
              ActionChip(
                avatar: StockLogo(
                  ticker: text(h['ticker']),
                  palette: p,
                  size: 24,
                ),
                label: Text('${h['ticker']} · ${pct(h['weight'])}'),
                onPressed: () => unawaited(loadCompany(text(h['ticker']))),
              ),
          ],
        ),
      ]),
    ];
  }
}

class FlexibleText extends StatelessWidget {
  const FlexibleText(this.value, {super.key, required this.p});
  final String value;
  final Palette p;
  @override
  Widget build(BuildContext context) =>
      Text(value, style: TextStyle(color: p.muted, fontSize: 13, height: 1.5));
}
