part of 'main.dart';

extension _InvestmentDiscovery on _InvestmentWorkspaceState {
  Future<void> loadDiscovery() async {
    final serial = ++discoverySerial, cutoff = asOf;
    updateUI(() {
      discoveryLoading = true;
      discoveryError = null;
    });
    try {
      final data = await widget.api.getJson(
        '/api/investment/discover?asOf=$cutoff',
      );
      if (mounted && serial == discoverySerial && cutoff == asOf) {
        updateUI(() => discoveryData = data);
        if (page == 'home') unawaited(loadHomeBrief());
      }
    } catch (e) {
      if (mounted && serial == discoverySerial && cutoff == asOf) {
        updateUI(() => discoveryError = e.toString());
      }
    } finally {
      if (mounted && serial == discoverySerial) {
        updateUI(() => discoveryLoading = false);
      }
    }
  }

  Future<void> loadGuru(
    String id, {
    String? filingId,
    String? holdingTicker,
  }) async {
    final serial = ++guruSerial, cutoff = asOf;
    updateUI(() {
      guruLoading = true;
      discoveryError = null;
    });
    try {
      final data = await widget.api.getJson(
        '/api/investment/gurus/${Uri.encodeComponent(id)}?asOf=$cutoff',
      );
      if (!mounted ||
          serial != guruSerial ||
          cutoff != asOf ||
          page != 'discover') {
        return;
      }
      updateUI(() {
        selectedGuru = data;
        discoveryTab = 'managers';
        selectedQuarter =
            asList(data['history']).any((f) => f['accessionNumber'] == filingId)
            ? filingId!
            : text(asMap(data['latest'])['accessionNumber']);
        selectedHolding = text(
          asList(
            selectedFiling['topHoldings'],
          ).where((h) => h['ticker'] == holdingTicker).firstOrNull?['ticker'],
          text(asList(selectedFiling['topHoldings']).firstOrNull?['ticker']),
        );
      });
      navigate('discover');
    } catch (e) {
      if (mounted && serial == guruSerial && cutoff == asOf) {
        updateUI(() => discoveryError = e.toString());
      }
    } finally {
      if (mounted && serial == guruSerial) updateUI(() => guruLoading = false);
    }
  }

  Future<void> followGuru(Map<String, dynamic> guru) => command(() async {
    await widget.api.postJson('/api/investment/follows', {
      'operationId': op(),
      'guruId': guru['id'],
      'followed': guru['followed'] != true,
    });
    await loadDiscovery();
    await loadHome();
  });

  List<Widget> discoveryPage() => [
    discoverIntro(),
    const SizedBox(height: 20),
    LayoutBuilder(
      builder: (_, c) => Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (final tab in [
            ('gurus', '13F Insights', '13F 洞察'),
            ('managers', 'Guru', 'Guru'),
            ('fundamentals', 'Fundamentals', '基本面'),
            ('valueflow', 'Value Flow', '价值链'),
          ])
            SizedBox(
              width: c.maxWidth < 650 ? math.max(0, c.maxWidth - 10) / 2 : null,
              child: ChoiceChip(
                label: Text(w(tab.$2, tab.$3)),
                selected: discoveryTab == tab.$1,
                onSelected: (_) {
                  updateUI(() {
                    discoveryTab = tab.$1;
                    if (tab.$1 == 'gurus') selectedGuru = null;
                  });
                  persistDiscover();
                  if (tab.$1 == 'gurus' && institutional13f == null) {
                    unawaited(load13FInsights());
                  }
                  if (const {'fundamentals', 'valueflow'}.contains(tab.$1) &&
                      opportunities == null) {
                    unawaited(loadOpportunities());
                  }
                },
              ),
            ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    if ((discoveryLoading && discoveryTab != 'managers') || guruLoading)
      const LinearProgressIndicator(minHeight: 2),
    if (discoveryError != null)
      card([
        label(
          'We could not load the disclosures. Your saved research is unchanged.',
          '暂时无法加载披露，已保存研究不受影响。',
        ),
        button('Retry disclosures', '重试披露', () => unawaited(loadDiscovery())),
      ]),
    if (discoveryTab == 'gurus' && selectedGuru == null)
      ...institutional13fInsightsPage(),
    if (discoveryTab == 'managers' && selectedGuru == null)
      GuruDiscoveryDesk(
        api: widget.api,
        palette: p,
        asOf: asOf,
        gurus: asList(discoveryData?['gurus']),
        initialSelection: guruStudySelection,
        onSelection: (v) => guruStudySelection = v,
        onExplore: (id, filing) => unawaited(loadGuru(id, filingId: filing)),
        onFollow: followGuru,
        onCompany: (symbol) => unawaited(
          loadCompany(
            symbol,
            origin: 'direct_research',
            initialSection: 'value',
          ),
        ),
      ),
    if ({'gurus', 'managers'}.contains(discoveryTab) && selectedGuru != null)
      ...guruDetailPage(),
    if (discoveryTab == 'fundamentals')
      FundamentalsPanel(
        api: widget.api,
        palette: p,
        asOf: asOf,
        initialSelection: fundamentalSelection,
        onSelection: (selection) => fundamentalSelection = selection,
        onCompany: (symbol, destination) {
          opportunityReturnDate = '';
          unawaited(
            loadCompany(
              symbol,
              origin: 'fundamental_research',
              initialSection: destination,
            ),
          );
        },
      ),
    if (discoveryTab == 'valueflow')
      ValueFlowPanel(
        api: widget.api,
        palette: p,
        asOf: asOf,
        initialSelection: valueFlowSelection,
        onSelection: (selection) => valueFlowSelection = selection,
        onCompany: (symbol, destination) {
          opportunityReturnDate = '';
          unawaited(
            loadCompany(
              symbol,
              origin: 'value_flow',
              initialSection: destination,
            ),
          );
        },
        onGuru: (id) => unawaited(loadGuru(id)),
      ),
  ];

  List<Widget> guruCatalogPage() {
    final rows = asList(discoveryData?['gurus'])
        .where(
          (g) =>
              (!followedOnly || g['followed'] == true) &&
              '${g['name']} ${g['entityName']}'.toLowerCase().contains(
                discoveryQuery.toLowerCase(),
              ),
        )
        .toList();
    return [
      Wrap(
        spacing: 14,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 300,
            child: TextFormField(
              initialValue: discoveryQuery,
              onChanged: (v) => updateUI(() => discoveryQuery = v),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: w('Find a manager', '搜索基金经理'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          FilterChip(
            label: Text(w('Following', '已关注')),
            selected: followedOnly,
            onSelected: (v) => updateUI(() => followedOnly = v),
          ),
          label('${rows.length} managers', '${rows.length} 位经理'),
        ],
      ),
      const SizedBox(height: 18),
      if (rows.isEmpty && !discoveryLoading)
        card([
          label(
            'No managers match. Clear the search or turn off Following.',
            '暂无匹配经理，请清空搜索或取消已关注筛选。',
          ),
        ]),
      LayoutBuilder(
        builder: (_, c) {
          final columns = c.maxWidth >= 1020
              ? 3
              : c.maxWidth >= 660
              ? 2
              : 1;
          final width = (c.maxWidth - (columns - 1) * 16) / columns;
          return Wrap(
            spacing: 16,
            children: [
              for (final guru in rows)
                SizedBox(width: width, child: guruCard(guru)),
            ],
          );
        },
      ),
      label(
        '13F filings are delayed disclosures, not live trades or buy signals. Holdings shown here are a bounded published extract.',
        '13F 是滞后披露，不是实时交易或买入信号。此处持仓来自有范围限制的已发布摘录。',
        size: 12,
      ),
    ];
  }

  Widget guruCard(Map<String, dynamic> guru) {
    final latest = asMap(guru['latest']);
    return card([
      Row(
        children: [
          GuruAvatar(
            guru: {...guru, 'avatarUrl': guru['avatar']},
            palette: p,
            size: 48,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text(guru['name']),
              style: TextStyle(
                color: p.text,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        text(guru['entityName']),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 18),
      if (latest.isEmpty)
        label('No filing at this cutoff', '截止日期前无披露')
      else ...[
        Row(
          children: [
            Expanded(
              child: label(
                text(latest['quarter']),
                text(latest['quarter']),
                color: p.text,
              ),
            ),
            Text(
              nullableNumber(latest['reported13fValue']) == null
                  ? '—'
                  : formatMoney(number(latest['reported13fValue'])),
              style: TextStyle(
                color: p.text,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        label(
          'Filed ${latest['availableAt']} · reported 13F value',
          '披露 ${latest['availableAt']} · 13F 信息表价值',
          size: 12,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            for (final h in asList(latest['topHoldings']))
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StockLogo(ticker: text(h['ticker']), palette: p, size: 23),
                  const SizedBox(width: 5),
                  label(
                    text(h['ticker']),
                    text(h['ticker']),
                    color: p.text,
                    size: 12,
                  ),
                ],
              ),
          ],
        ),
      ],
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          button(
            'Explore quarters',
            '查看季度',
            latest.isEmpty ? null : () => unawaited(loadGuru(text(guru['id']))),
            primary: true,
          ),
          button(
            guru['followed'] == true ? 'Following' : 'Follow',
            guru['followed'] == true ? '已关注' : '关注',
            () => unawaited(followGuru(guru)),
            icon: guru['followed'] == true ? Icons.check : Icons.add,
          ),
        ],
      ),
    ]);
  }

  Map<String, dynamic> get selectedFiling =>
      asList(
        selectedGuru?['history'],
      ).where((h) => h['accessionNumber'] == selectedQuarter).firstOrNull ??
      {};

  List<Widget> guruDetailPage() {
    final guru = asMap(selectedGuru?['guru']), filing = selectedFiling;
    final history = asList(selectedGuru?['history']);
    final sourceError = filing['status'] == 'source_error';
    final comparisonError =
        filing['comparisonStatus'] == 'previous_source_error';
    final holdings = sourceError
        ? <Map<String, dynamic>>[]
        : asList(filing['topHoldings']);
    final errorCodes = filing['sourceErrorCodes'] is List
        ? filing['sourceErrorCodes'] as List
        : const [];
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            updateUI(() => selectedGuru = null);
            navigate('discover');
          },
          icon: const Icon(Icons.arrow_back, size: 18),
          label: Text(w('All managers', '全部经理')),
        ),
      ),
      Row(
        children: [
          GuruAvatar(
            guru: {...guru, 'avatarUrl': guru['avatar']},
            palette: p,
            size: 60,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title(text(guru['name']), text(guru['name'])),
                label(text(guru['entityName']), text(guru['entityName'])),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      card([
        Wrap(
          spacing: 26,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                key: ValueKey('filing-$selectedQuarter'),
                initialValue: selectedQuarter.isEmpty ? null : selectedQuarter,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: w('Reported quarter', '申报季度'),
                ),
                items: history.reversed
                    .map(
                      (h) => DropdownMenuItem(
                        value: text(h['accessionNumber']),
                        child: Text(
                          '${h['quarterLabel']} · ${h['filingDate']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  updateUI(() {
                    selectedQuarter = v ?? '';
                    selectedHolding = text(
                      asList(
                        selectedFiling['topHoldings'],
                      ).firstOrNull?['ticker'],
                    );
                  });
                  navigate('discover');
                },
              ),
            ),
            metricDisplay(
              sourceError || nullableNumber(filing['reported13fValue']) == null
                  ? '—'
                  : formatMoney(number(filing['reported13fValue'])),
              'Reported 13F value',
              '13F 信息表价值',
              size: 26,
            ),
            metricDisplay(
              sourceError ? '—' : text(filing['positionCount'], '—'),
              'Reported positions',
              '申报持仓数',
              size: 26,
            ),
            metricDisplay(
              text(filing['filingDate'], '—'),
              'Public filing date',
              '公开披露日期',
              size: 22,
            ),
          ],
        ),
        const SizedBox(height: 14),
        label(
          'Reported ${filing['reportDate']} · Available ${filing['filingDate']} · ${history.length} filings before $asOf',
          '报告期 ${filing['reportDate']} · 披露 ${filing['filingDate']} · $asOf 前共 ${history.length} 份申报',
          size: 12,
        ),
      ]),
      if (sourceError || comparisonError)
        card([
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: p.secondary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: title(
                  sourceError
                      ? 'This filing needs source review'
                      : 'Quarterly changes are unavailable',
                  sourceError ? '这份申报需要核查来源' : '本季度仓位变化暂不可用',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          label(
            !sourceError
                ? 'The current holdings are available, but the previous quarter has a source error. New, added, reduced and exited positions are not inferred.'
                : errorCodes.contains('reported_value_error')
                ? 'The original filing contains an inconsistent reported value. Holdings, amounts and position history for this quarter are withheld pending source review.'
                : errorCodes.contains('invalid_13f_identifier')
                ? 'The original filing contains invalid security identifiers. Holdings, amounts and position history for this quarter are withheld pending source review.'
                : 'The source filing cannot be verified. Holdings, amounts and position history for this quarter are withheld pending source review.',
            !sourceError
                ? '当期持仓可查看，但上一季度存在来源错误，因此不推断新建、加仓、减仓或清仓。'
                : errorCodes.contains('reported_value_error')
                ? '原始申报的市值存在不一致。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。'
                : errorCodes.contains('invalid_13f_identifier')
                ? '原始申报包含无效的证券标识。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。'
                : '原始申报暂无法核实。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。',
          ),
          if (sourceError) ...[
            const SizedBox(height: 8),
            label(
              'This is a data gap, not an empty portfolio or an exit. Choose another reported quarter above.',
              '这是数据缺口，不代表空仓或清仓。可在上方选择其他申报季度。',
            ),
          ],
          const SizedBox(height: 8),
          label(
            'Report ${text(filing['reportDate'])} · Filing ${text(filing['accessionNumber'])}',
            '报告期 ${text(filing['reportDate'])} · 申报编号 ${text(filing['accessionNumber'])}',
            size: 12,
          ),
        ]),
      if (!sourceError)
        LayoutBuilder(
          builder: (_, c) {
            final table = card([
              title('What did they own?', '他们持有哪些股票？'),
              label(
                'Select a stock to trace its reported position.',
                '选择股票，查看申报仓位轨迹。',
              ),
              const SizedBox(height: 12),
              for (final h in holdings)
                Material(
                  color: h['ticker'] == selectedHolding
                      ? p.accent.withValues(alpha: .09)
                      : Colors.transparent,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: StockLogo(
                      ticker: text(h['ticker']),
                      palette: p,
                      size: 34,
                    ),
                    title: Text(
                      text(h['ticker']),
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      text(h['issuer']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                    trailing: Text(
                      pct(h['pctPortfolio']),
                      style: TextStyle(color: p.text),
                    ),
                    onTap: () {
                      updateUI(() => selectedHolding = text(h['ticker']));
                      navigate('discover');
                    },
                  ),
                ),
            ]);
            final trajectory = holdingTrajectory();
            if (c.maxWidth < 850) return Column(children: [table, trajectory]);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: table),
                const SizedBox(width: 20),
                Expanded(child: trajectory),
              ],
            );
          },
        ),
      label(
        'Top holdings extract, not the entire book. A missing row is not an exit. Reported share changes require corporate-action checks; do not infer trading intent.',
        '主要持仓摘录，不是完整持仓。缺少记录不代表清仓；申报股数变化须核对公司行动，不据此推断交易动机。',
        size: 12,
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: button(
          'Open full backtest terminal',
          '打开完整回测终端',
          () => unawaited(enterTerminal()),
        ),
      ),
    ];
  }

  Widget holdingTrajectory() {
    final points = <Map<String, dynamic>>[];
    for (final f in asList(selectedGuru?['history'])) {
      if (text(f['filingDate']).compareTo(text(selectedFiling['filingDate'])) >
          0) {
        continue;
      }
      final row = [...asList(f['topHoldings']), ...asList(f['largestChanges'])]
          .where(
            (h) =>
                h['ticker'] == selectedHolding &&
                text(h['id']).endsWith('-COMMON'),
          )
          .firstOrNull;
      points.add({
        'quarter': f['quarterLabel'],
        'date': f['filingDate'],
        'holding': f['status'] == 'source_error' ? null : row,
        'sourceError': f['status'] == 'source_error',
      });
    }
    final visible = points.reversed.take(12).toList().reversed.toList();
    final field = trajectoryMetric == 'weight'
        ? 'pctPortfolio'
        : trajectoryMetric == 'value'
        ? 'value'
        : 'shares';
    var maxValue = 0.0;
    for (final pt in visible) {
      final v = number(asMap(pt['holding'])[field]);
      if (v > maxValue) maxValue = v;
    }
    final current = asList(
      selectedFiling['topHoldings'],
    ).where((h) => h['ticker'] == selectedHolding).firstOrNull;
    return card([
      Row(
        children: [
          StockLogo(ticker: selectedHolding, palette: p, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: title(
              '$selectedHolding · position history',
              '$selectedHolding · 仓位轨迹',
            ),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final metric in [
            ('shares', 'Shares', '股数'),
            ('weight', 'Weight', '权重'),
            ('value', 'Value', '申报市值'),
          ])
            ChoiceChip(
              label: Text(w(metric.$2, metric.$3)),
              selected: trajectoryMetric == metric.$1,
              onSelected: (_) => updateUI(() => trajectoryMetric = metric.$1),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (visible.isEmpty)
        label('No comparable reported observations.', '暂无可比较的申报记录。'),
      for (final point in visible)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                child: label(
                  text(point['quarter']),
                  text(point['quarter']),
                  size: 12,
                ),
              ),
              Expanded(
                child: nullableNumber(asMap(point['holding'])[field]) == null
                    ? point['sourceError'] == true
                          ? label('Source unavailable', '来源不可用', size: 12)
                          : label('Not in extract', '摘录未包含', size: 12)
                    : LinearProgressIndicator(
                        value: maxValue > 0
                            ? number(asMap(point['holding'])[field]) / maxValue
                            : 0,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                        color: p.accent,
                        backgroundColor: p.border,
                      ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 78,
                child: Text(
                  nullableNumber(asMap(point['holding'])[field]) == null
                      ? '—'
                      : field == 'pctPortfolio'
                      ? pct(asMap(point['holding'])[field])
                      : field == 'value'
                      ? formatMoney(number(asMap(point['holding'])[field]))
                      : formatNumber(number(asMap(point['holding'])[field])),
                  textAlign: TextAlign.right,
                  style: TextStyle(color: p.text, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      label(
        'Up to 12 filings through the selected filing. Bars show reported observations, not a return curve.',
        '显示截至所选披露的最近 12 份申报，柱状图是申报记录，不是收益曲线。',
        size: 12,
      ),
      const SizedBox(height: 18),
      button(
        'Research $selectedHolding',
        '研究 $selectedHolding',
        current == null
            ? null
            : () => unawaited(
                loadCompany(
                  selectedHolding,
                  origin: 'guru_disclosure',
                  evidence: {
                    'guruId': asMap(selectedGuru?['guru'])['id'],
                    'name': asMap(selectedGuru?['guru'])['name'],
                    'accession': selectedFiling['accessionNumber'],
                    'reportDate': selectedFiling['reportDate'],
                    'availableAt': selectedFiling['filingDate'],
                  },
                ),
              ),
        primary: true,
      ),
      label(
        'Valuation uses data available at $asOf, not the manager’s purchase-date value.',
        '估值使用 $asOf 前可用数据，不是经理买入时的估值。',
        size: 12,
      ),
    ]);
  }
}
