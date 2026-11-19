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
    final nextFollowed = guru['followed'] != true;
    await widget.api.postJson('/api/investment/follows', {
      'operationId': op(),
      'guruId': guru['id'],
      'followed': nextFollowed,
    });
    updateUI(() {
      if (selectedGuru != null &&
          asMap(selectedGuru?['guru'])['id'] == guru['id']) {
        selectedGuru = {
          ...?selectedGuru,
          'guru': {...asMap(selectedGuru?['guru']), 'followed': nextFollowed},
        };
      }
      if (home != null) {
        final existing = asList(
          home?['follows'],
        ).where((f) => text(f['guruId'], text(f['id'])) != text(guru['id'])).toList();
        home = {
          ...?home,
          'follows': [
            ...existing,
            {'guruId': guru['id'], 'followed': nextFollowed},
          ],
        };
      }
    });
    if (discoveryData != null) await loadDiscovery();
    await loadHome();
  });

  List<Widget> discoveryPage() => [
    discoverIntro(),
    const SizedBox(height: 12),
    LayoutBuilder(
      builder: (_, c) {
        final tabs = const [
          ('gurus', '13F Insights', '13F 洞察'),
          ('managers', 'Guru', '大师持仓'),
          ('fundamentals', 'Fundamentals', '基本面'),
          ('aiinsights', 'AI Insights', 'AI 洞察'),
        ];
        if (c.maxWidth < 650) {
          return Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Row(
              children: [
                for (final tab in tabs)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        updateUI(() {
                          discoveryTab = tab.$1;
                          if (tab.$1 == 'gurus') selectedGuru = null;
                        });
                        persistDiscover();
                        if (tab.$1 == 'gurus' && institutional13f == null) {
                          unawaited(load13FInsights());
                        }
                        if (tab.$1 == 'fundamentals' && opportunities == null) {
                          unawaited(loadOpportunities());
                        }
                      },
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: discoveryTab == tab.$1
                              ? p.card
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            w(tab.$2, tab.$3),
                            maxLines: 1,
                            style: TextStyle(
                              color: discoveryTab == tab.$1 ? p.text : p.muted,
                              fontSize: 11.5,
                              fontWeight: discoveryTab == tab.$1
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
          );
        }
        return Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          child: Row(
            children: [
              for (final tab in tabs)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(6),
                    ),
                    onTap: () {
                      updateUI(() {
                        discoveryTab = tab.$1;
                        if (tab.$1 == 'gurus') selectedGuru = null;
                      });
                      persistDiscover();
                      if (tab.$1 == 'gurus' && institutional13f == null) {
                        unawaited(load13FInsights());
                      }
                      if (tab.$1 == 'fundamentals' && opportunities == null) {
                        unawaited(loadOpportunities());
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: discoveryTab == tab.$1
                                ? p.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        w(tab.$2, tab.$3),
                        style: TextStyle(
                          color: discoveryTab == tab.$1 ? p.text : p.muted,
                          fontSize: 13.5,
                          fontWeight: discoveryTab == tab.$1
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
      },
    ),
    const SizedBox(height: 14),
    if ((discoveryLoading && discoveryTab == 'gurus') || guruLoading)
      const LinearProgressIndicator(minHeight: 2),
    if (discoveryError != null && {'gurus', 'managers'}.contains(discoveryTab))
      card([
        label(
          'We could not load the disclosures. Your saved research is unchanged.',
          '暂时无法加载披露，已保存研究不受影响。',
        ),
        button('Retry disclosures', '重新加载披露数据', () => unawaited(loadDiscovery())),
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
    if (discoveryTab == 'aiinsights')
      AiInsightsPanel(
        api: widget.api,
        palette: p,
        asOf: asOf,
        initialSelection: aiInsightsSelection,
        onSelection: (selection) {
          aiInsightsSelection = selection;
          persistDiscover();
        },
        onCompany: (symbol, destination) {
          opportunityReturnDate = '';
          unawaited(
            loadCompany(
              symbol,
              origin: 'ai_insights',
              evidence: {
                'aiInsights': Map<String, dynamic>.from(aiInsightsSelection),
              },
              initialSection: destination == 'overview' ? 'evidence' : destination,
            ),
          );
        },
      ),
  ];

  List<Widget> guruCatalogPage() {
    final rows = asList(discoveryData?['gurus'])
        .where(
          (g) =>
              (!followedOnly || g['followed'] == true) &&
              '${g['name']} ${guruDisplayName(g, AppLanguage.zh)} ${g['entityName']}'
                  .toLowerCase()
                  .contains(discoveryQuery.toLowerCase()),
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
              guruDisplayName(guru, context.language),
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
    final baseDetail = asMap(selectedGuru);
    final rawGuru = asMap(baseDetail['guru']);
    final guruId = text(rawGuru['id']);
    final dirEntry = asList(
      discoveryData?['gurus'],
    ).where((g) => g['id'] == guruId).firstOrNull;
    final followedFromHome = asList(
      home?['follows'],
    ).any((f) => text(f['guruId'], text(f['id'])) == guruId && f['followed'] != false);
    final resolvedFollowed =
        rawGuru['followed'] as bool? ??
        dirEntry?['followed'] as bool? ??
        followedFromHome;
    final mergedDetail = {
      ...baseDetail,
      'guru': {
        ...?dirEntry,
        ...rawGuru,
        'followed': resolvedFollowed,
      },
    };
    return [
      GuruResearchDossier(
        detail: mergedDetail,
        selectedQuarter: selectedQuarter,
        selectedHolding: selectedHolding,
        trajectoryMetric: trajectoryMetric,
        asOf: asOf,
        palette: p,
        onBack: () {
          updateUI(() => selectedGuru = null);
          navigate('discover');
        },
        onSelectQuarter: (v) {
          updateUI(() {
            selectedQuarter = v;
            selectedHolding = text(
              asList(selectedFiling['topHoldings']).firstOrNull?['ticker'],
            );
          });
          navigate('discover');
        },
        onSelectHolding: (sym) {
          updateUI(() => selectedHolding = sym);
          navigate('discover');
        },
        onSelectTrajectoryMetric: (m) => updateUI(() => trajectoryMetric = m),
        onResearchCompany: (sym, evidence) => unawaited(
          loadCompany(sym, origin: 'guru_disclosure', evidence: evidence),
        ),
        onOpenTerminal: () => unawaited(enterTerminal()),
        onFollow: guruId.isNotEmpty
            ? () => unawaited(
                followGuru(asMap(mergedDetail['guru'])),
              )
            : null,
      ),
    ];
  }
}
