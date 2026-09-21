part of 'main.dart';

// One dated research loop. The existing manager desk and valuation editor stay
// intact; this view joins their read models and owns a lightweight watch record.
extension _InvestmentOpportunities on _InvestmentWorkspaceState {
  void persistOpportunity() => replaceBrowserQuery({
    'lens': opportunityLens,
    'candidate': opportunityTicker,
    'quarter': opportunityQuarter,
    'workspace': managerDesk ? 'manager' : null,
    'returnAsOf': opportunityReturnDate.isEmpty ? null : opportunityReturnDate,
    'returnView': opportunityReturnDate.isEmpty ? null : opportunityReturnPage,
  }, replaceCurrent: true);

  Future<void> loadOpportunities({String? quarter}) async {
    final serial = ++opportunitySerial, cutoff = asOf;
    updateUI(() {
      opportunityLoading = true;
      opportunityError = '';
    });
    try {
      final q = quarter ?? opportunityQuarter;
      final data = await widget.api.getJson(
        '/api/investment/opportunities?asOf=$cutoff${q.isEmpty ? '' : '&quarter=$q'}',
      );
      if (!mounted || serial != opportunitySerial || cutoff != asOf) return;
      updateUI(() {
        opportunities = data;
        opportunityQuarter = text(data['reportDate']);
        final available = page == 'discover'
            ? discoverMatches
            : asList(data['rows']);
        if (!asList(
              data['rows'],
            ).any((r) => r['ticker'] == opportunityTicker) ||
            !available.any((r) => r['ticker'] == opportunityTicker)) {
          opportunityTicker = text(available.firstOrNull?['ticker']);
        }
      });
      persistOpportunity();
      if (opportunityTicker.isNotEmpty) {
        unawaited(selectOpportunity(opportunityTicker, showMobile: false));
      }
    } catch (_) {
      if (mounted && serial == opportunitySerial) {
        updateUI(
          () => opportunityError = w(
            'Could not load the dated opportunity list.',
            '暂时无法加载该日期的研究列表。',
          ),
        );
      }
    } finally {
      if (mounted && serial == opportunitySerial) {
        updateUI(() => opportunityLoading = false);
      }
    }
  }

  Map<String, dynamic> get opportunityRow =>
      asList(
        opportunities?['rows'],
      ).where((r) => r['ticker'] == opportunityTicker).firstOrNull ??
      {};

  Future<void> selectOpportunity(
    String symbol, {
    String? at,
    bool showMobile = true,
  }) async {
    final serial = ++opportunityDetailSerial, cutoff = at ?? asOf;
    updateUI(() {
      opportunityTicker = symbol;
      opportunityCutoff = cutoff;
      opportunityCompany = null;
      opportunityError = '';
      watchComparison = null;
      opportunityDetailLoading = true;
      if (at == null) opportunityEvents = null;
      if (showMobile) opportunityMobileDetail = true;
    });
    persistOpportunity();
    if (showMobile && page == 'discover' && at == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = discoverDetailKey.currentContext;
        if (mounted && page == 'discover' && target != null) {
          unawaited(Scrollable.ensureVisible(target));
        }
      });
    }
    try {
      final results = await Future.wait([
        widget.api
            .getJson(
              '/api/investment/research/${Uri.encodeComponent(symbol)}?asOf=$cutoff',
            )
            .then<Map<String, dynamic>?>((v) => v)
            .catchError((Object error) {
              if (error is ApiRequestException &&
                  error.statusCode == 422 &&
                  error.code == 'no_pit_research_at_date') {
                return null;
              }
              throw error;
            }),
        widget.api.getJson(
          '/api/investment/opportunities/${Uri.encodeComponent(symbol)}?asOf=$asOf',
        ),
      ]);
      if (!mounted ||
          serial != opportunityDetailSerial ||
          opportunityTicker != symbol ||
          opportunityCutoff != cutoff) {
        return;
      }
      if (results[0] != null && results[0]!['ticker'] != symbol) {
        throw StateError('identity_mismatch');
      }
      updateUI(() {
        opportunityCompany = results[0];
        opportunityEvents = results[1];
      });
    } catch (_) {
      if (mounted && serial == opportunityDetailSerial) {
        updateUI(
          () => opportunityError = w(
            'This research request failed. Your selection is unchanged.',
            '研究请求失败，已保留所选股票。',
          ),
        );
      }
    } finally {
      if (mounted && serial == opportunityDetailSerial) {
        updateUI(() => opportunityDetailLoading = false);
      }
    }
  }

  Future<void> watchOpportunity() => command(() async {
    final symbol = opportunityTicker, cutoff = opportunityCutoff;
    await widget.api.postJson('/api/investment/watches', {
      'operationId': op(),
      'ticker': symbol,
      'asOf': cutoff,
      'reportDate': cutoff == asOf ? opportunityQuarter : null,
      'origin': opportunityLens,
    });
    await loadHome();
    if (mounted) {
      updateUI(
        () => notice = w(
          '$symbol saved with its dated evidence and platform model. No investment decision was made.',
          '$symbol 已保存日期、证据和平台模型；未记录投资决策。',
        ),
      );
    }
  });

  Future<void> openWatch(String id) => command(() async {
    final data = await widget.api.getJson(
      '/api/investment/watches/$id?asOf=$asOf',
    );
    if (mounted) {
      updateUI(() {
        watchComparison = data;
        opportunityLens = 'watching';
        managerDesk = false;
      });
    }
    persistOpportunity();
  });

  Future<void> acknowledgeWatch() => command(() async {
    final r = watchComparison!;
    await widget.api.postJson('/api/investment/watch-reviews', {
      'operationId': op(),
      'watchId': asMap(r['watch'])['id'],
      'asOf': asOf,
      'comparisonId': r['comparisonId'],
    });
    await loadHome();
    final fresh = await widget.api.getJson(
      '/api/investment/watches/${asMap(r['watch'])['id']}?asOf=$asOf',
    );
    if (mounted) {
      updateUI(() {
        watchComparison = fresh;
        notice = w(
          'Reviewed. Your original observation is unchanged.',
          '复核已记录，最初观察保持不变。',
        );
      });
    }
  });

  Future<void> openOpportunityValuation({String section = 'value'}) async {
    opportunityReturnPage = page;
    opportunityReturnDate = asOf;
    asOf = opportunityCutoff;
    persistOpportunity();
    await loadCompany(opportunityTicker, initialSection: section);
  }

  Future<void> returnToOpportunities() async {
    if (!await allowLeaveDraft() || !mounted) return;
    if (opportunityReturnDate.isNotEmpty) asOf = opportunityReturnDate;
    opportunityReturnDate = '';
    navigate(opportunityReturnPage == 'discover' ? 'discover' : 'home');
    persistOpportunity();
  }

  List<Widget> opportunityPage({bool inDiscover = false}) {
    final coverage = asMap(opportunities?['coverage']);
    final compact = MediaQuery.sizeOf(context).width < 600;
    return [
      if (!inDiscover && !managerDesk) ...[
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 18,
          runSpacing: 16,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact)
                  label(
                    'FROM DISCLOSURE TO YOUR OWN JUDGMENT',
                    '从披露线索到独立判断',
                    size: 11,
                    color: p.accent,
                  ),
                if (!compact) const SizedBox(height: 10),
                Text(
                  compact
                      ? w('Research desk', '研究工作台')
                      : w('Find the idea. Test the price.', '发现公司，检验价格。'),
                  style: deskHeading(compact ? 28 : 32),
                ),
                const SizedBox(height: 8),
                label(
                  compact
                      ? 'Holdings. Fundamentals. Valuation.'
                      : 'Guru ownership, business changes and valuation — in one research desk.',
                  compact ? '集合持仓 · 基本面 · 估值' : '在同一研究台查看大佬持仓、经营变化与估值。',
                  size: 14,
                ),
              ],
            ),
            dateControl(),
          ],
        ),
        const SizedBox(height: 24),
      ],
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in [
              ('holdings', 'Shared holdings', '集合持仓'),
              ('adds', 'Reported adds', '申报增持'),
              ('trims', 'Reported trims', '申报减持'),
              ('value', 'Valuation lens', '估值视角'),
              ('watching', 'Watching', '我的观察'),
            ])
              ChoiceChip(
                label: Text(w(t.$2, t.$3)),
                selected: !managerDesk && opportunityLens == t.$1,
                onSelected: (_) => updateUI(() {
                  managerDesk = false;
                  opportunityLens = t.$1;
                  opportunityMobileDetail = false;
                  watchComparison = null;
                  persistOpportunity();
                }),
              ),
            ChoiceChip(
              label: Text(w('Managers', '按经理研究')),
              selected: managerDesk,
              onSelected: (_) {
                updateUI(() => managerDesk = true);
                persistOpportunity();
                if (homeBrief == null) unawaited(loadHomeBrief());
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 22),
      if (managerDesk) ...[
        if (inDiscover) ...guruCatalogPage() else ...deskPage(),
      ] else if (opportunityLens == 'watching')
        ...watchingPage()
      else ...[
        Wrap(
          spacing: 20,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (opportunityQuarter.isNotEmpty)
              DropdownButton<String>(
                key: const ValueKey('opportunity-quarter'),
                value: opportunityQuarter,
                dropdownColor: p.card,
                underline: const SizedBox.shrink(),
                items: [
                  for (final q in (opportunities?['quarters'] as List? ?? []))
                    DropdownMenuItem(
                      value: '$q',
                      child: Text(
                        reportQuarterLabel('$q'),
                        style: TextStyle(color: p.text),
                      ),
                    ),
                ],
                onChanged: (q) {
                  if (q != null) {
                    opportunityDetailSerial++;
                    updateUI(() {
                      opportunityCompany = null;
                    });
                    unawaited(loadOpportunities(quarter: q));
                  }
                },
              ),
            label(
              '${coverage['reportedManagers'] ?? '—'}/${coverage['eligibleManagers'] ?? '—'} managers filed',
              '${coverage['reportedManagers'] ?? '—'}/${coverage['eligibleManagers'] ?? '—'} 位经理已披露',
              size: 12,
            ),
            label(
              '${coverage['modelled'] ?? '—'}/${coverage['total'] ?? '—'} stocks with comparable models',
              '${coverage['modelled'] ?? '—'}/${coverage['total'] ?? '—'} 只股票有可比模型',
              size: 12,
            ),
          ],
        ),
        if (number(coverage['extractedBooks']) > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: label(
              'Historical extracts: observed manager counts are lower bounds, not a complete consensus ranking.',
              '历史摘录：可见经理数量是下限，不是完整共识排名。',
              size: 12,
              color: p.secondary,
            ),
          ),
        const SizedBox(height: 12),
        if (opportunityLoading) const LinearProgressIndicator(minHeight: 2),
        if (opportunityError.isNotEmpty) ...[
          Text(opportunityError, style: TextStyle(color: p.secondary)),
          TextButton(
            onPressed: () => unawaited(loadOpportunities()),
            child: Text(w('Retry dated research', '重试该日期研究')),
          ),
        ],
        if (opportunities != null)
          LayoutBuilder(
            builder: (_, c) {
              final wide = c.maxWidth >= 930;
              if (!wide) {
                return opportunityMobileDetail && opportunityTicker.isNotEmpty
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => updateUI(
                                () => opportunityMobileDetail = false,
                              ),
                              icon: const Icon(Icons.arrow_back),
                              label: Text(w('Back to candidates', '返回候选列表')),
                            ),
                          ),
                          opportunityDetail(),
                        ],
                      )
                    : opportunityList();
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: math.min(420, c.maxWidth * .40),
                    child: opportunityList(),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(left: 24),
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: p.border)),
                      ),
                      child: opportunityDetail(),
                    ),
                  ),
                ],
              );
            },
          ),
        const SizedBox(height: 20),
        label(
          'Reported holdings are not confirmed trades. Model gaps are estimates, not expected returns.',
          '申报持仓不是已确认成交；模型价差是估计，不是预期收益。',
          size: 12,
        ),
      ],
      if (!inDiscover &&
          !managerDesk &&
          asList(home?['attention']).isNotEmpty) ...[
        const SizedBox(height: 24),
        homeReviewAlert(),
      ],
    ];
  }

  Widget opportunityList() {
    final rows = asList(opportunities?['rows']).where((r) {
      if (opportunityLens == 'adds' && number(r['adds']) == 0) return false;
      if (opportunityLens == 'trims' && number(r['trims']) == 0) return false;
      return '${r['ticker']} ${r['name']}'.toLowerCase().contains(
        opportunitySearch.toLowerCase(),
      );
    }).toList();
    rows.sort((a, b) {
      final field = opportunityLens == 'adds'
          ? 'adds'
          : opportunityLens == 'trims'
          ? 'trims'
          : opportunityLens == 'value'
          ? 'modelGap'
          : 'managerCount';
      return (nullableNumber(b[field]) ?? -1e10).compareTo(
        nullableNumber(a[field]) ?? -1e10,
      );
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const ValueKey('opportunity-search'),
          initialValue: opportunitySearch,
          onChanged: (v) => updateUI(() => opportunitySearch = v),
          style: TextStyle(color: p.text, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: w('Find a company…', '查找公司…'),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: label(
                '${rows.length} CANDIDATES',
                '${rows.length} 只候选',
                size: 11,
              ),
            ),
            SizedBox(width: 62, child: label('Gurus', '经理', size: 11)),
            SizedBox(width: 78, child: label('Model gap', '模型价差', size: 11)),
            SizedBox(width: 65, child: label('Value Δ', '估值变化', size: 11)),
          ],
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: label(
              'No companies match. Clear your search or change the lens.',
              '没有匹配公司，请清除搜索或切换视角。',
            ),
          ),
        SizedBox(
          height: math.max(
            320,
            math.min(660, MediaQuery.sizeOf(context).height - 335),
          ),
          child: ListView.builder(
            key: PageStorageKey(
              'opportunities-$opportunityLens-$opportunityQuarter',
            ),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i], selected = r['ticker'] == opportunityTicker;
              return Material(
                color: selected
                    ? p.accent.withValues(alpha: .12)
                    : Colors.transparent,
                child: InkWell(
                  key: ValueKey('candidate-${r['ticker']}'),
                  onTap: () => unawaited(selectOpportunity(text(r['ticker']))),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: selected ? p.accent : Colors.transparent,
                          width: 3,
                        ),
                        bottom: BorderSide(color: p.border),
                      ),
                    ),
                    child: Row(
                      children: [
                        homeStockLogo(text(r['ticker']), 30),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                text(r['ticker']),
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${r['adds']} ↑  ${r['trims']} ↓',
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 58,
                          child: Text(
                            '${r['managerCount']}',
                            style: TextStyle(color: p.text),
                          ),
                        ),
                        SizedBox(
                          width: 78,
                          child: Text(
                            pct(r['modelGap']),
                            style: TextStyle(
                              color: nullableNumber(r['modelGap']) == null
                                  ? p.muted
                                  : number(r['modelGap']) >= 0
                                  ? p.accent
                                  : p.negative,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(
                            pct(asMap(r['valuation'])['change']),
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String opportunityAction(String action) => switch (action) {
    'new' => w('New position', '首次持仓'),
    'increased' => w('Reported increase', '申报增加'),
    'reduced' => w('Reported reduction', '申报减少'),
    'sold_out' => w('Reported exit', '申报退出'),
    'mixed_claims' => w('Mixed share classes', '多种股权变化'),
    _ => w('Reported holding', '申报持仓'),
  };

  Widget opportunityDetail() {
    final r = opportunityRow, c = opportunityCompany;
    if (r.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: label(
          'Select a company to connect ownership with valuation.',
          '选择公司，联动持仓与估值。',
        ),
      );
    }
    final watches = asList(
      home?['watches'],
    ).where((w) => w['ticker'] == opportunityTicker).toList();
    final dates =
        <String>{
          asOf,
          opportunityCutoff,
          for (final e in asList(opportunityEvents?['events'])) text(e['date']),
          for (final h in asList(c?['history'])) text(h['availableAt']),
        }.where((d) => d.isNotEmpty && d.compareTo(asOf) <= 0).toList()..sort(
          (a, b) => b.compareTo(a),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            homeStockLogo(opportunityTicker, 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(opportunityTicker, style: deskHeading(28)),
                  Text(
                    text(c?['name'], text(r['name'])),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: w('Save observation', '保存观察'),
              onPressed: busy || opportunityDetailLoading || watches.isNotEmpty
                  ? null
                  : () => unawaited(watchOpportunity()),
              icon: Icon(
                watches.isEmpty ? Icons.bookmark_border : Icons.bookmark,
                color: p.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              label(
                '${r['managerCount']} managers hold · ${r['adds']} increased · ${r['trims']} reduced',
                '${r['managerCount']} 位持有 · ${r['adds']} 位增加 · ${r['trims']} 位减少',
                size: 13,
                color: p.text,
              ),
              label(
                'Reported quarter ${reportQuarterLabel(opportunityQuarter)}',
                '申报季度 ${reportQuarterLabel(opportunityQuarter)}',
                size: 11,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (page == 'discover' && discoverCollection != 'all') ...[
          discoverLensEvidence(),
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            Expanded(
              child: label(
                'RESEARCH TIMELINE',
                '研究时间线',
                size: 11,
                color: p.accent,
              ),
            ),
            DropdownButton<String>(
              key: const ValueKey('opportunity-timeline'),
              value: dates.contains(opportunityCutoff)
                  ? opportunityCutoff
                  : null,
              dropdownColor: p.card,
              items: [
                for (final d in dates)
                  DropdownMenuItem(
                    value: d,
                    child: Text(
                      d == asOf ? w('$d · Workspace', '$d · 工作区') : d,
                      style: TextStyle(color: p.text, fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (d) {
                if (d != null) {
                  unawaited(selectOpportunity(opportunityTicker, at: d));
                }
              },
            ),
          ],
        ),
        if (opportunityCutoff != asOf)
          label(
            'Historical evidence as of $opportunityCutoff; the candidate list remains at $asOf.',
            '历史证据截止 $opportunityCutoff；候选列表仍截止 $asOf。',
            size: 12,
            color: p.secondary,
          ),
        if (opportunityDetailLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (c != null)
          ...opportunityValue(c)
        else if (opportunityError.isNotEmpty)
          card([
            Text(opportunityError, style: TextStyle(color: p.secondary)),
            button(
              'Retry research',
              '重试研究',
              () => unawaited(
                selectOpportunity(opportunityTicker, at: opportunityCutoff),
              ),
            ),
          ])
        else
          card([
            label(
              'No published model at this date. Ownership evidence remains available.',
              '该日期没有可用模型，仍可研究持仓证据。',
            ),
            button(
              'Retry company research',
              '重试公司研究',
              () => unawaited(
                selectOpportunity(opportunityTicker, at: opportunityCutoff),
              ),
            ),
          ]),
        const SizedBox(height: 18),
        if (!opportunityDetailLoading)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: busy || watches.isNotEmpty
                    ? null
                    : () => unawaited(watchOpportunity()),
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: Text(
                  w(
                    watches.isEmpty ? 'Save to watch' : 'Saved to watch',
                    watches.isEmpty ? '保存观察' : '已保存观察',
                  ),
                ),
              ),
              if (c != null)
                OutlinedButton.icon(
                  onPressed: () => unawaited(openOpportunityValuation()),
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    asMap(c['templates']).isNotEmpty
                        ? w('Test my assumptions', '检验我的假设')
                        : w('View valuation method', '查看估值方法'),
                  ),
                ),
              if (watches.isNotEmpty)
                TextButton(
                  onPressed: () =>
                      unawaited(openWatch(text(watches.first['id']))),
                  child: Text(w('Review saved observation', '复核已保存观察')),
                ),
            ],
          ),
        const SizedBox(height: 18),
        if (page == 'discover' && discoverCollection != 'all')
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              w('All quarterly holder disclosures', '全部季度持有者披露'),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            children: [opportunityManagerEvidence()],
          )
        else
          opportunityManagerEvidence(),
      ],
    );
  }

  List<Widget> opportunityValue(Map<String, dynamic> c) {
    final snap = asMap(c['snapshot']),
        price = asMap(snap['price']),
        published = asMap(c['published']),
        currency = text(c['currency']);
    String amount(dynamic v, [String? unit]) => nullableNumber(v) == null
        ? '—'
        : '${currencySymbol(unit ?? currency)}${number(v).toStringAsFixed(2)}';
    final hist = asList(c['history']), prices = asList(c['priceHistory']);
    return [
      Row(
        children: [
          Expanded(
            child: deskPrice(
              amount(price['value']),
              'Market price',
              '市场价格',
              text(price['date']),
            ),
          ),
          Expanded(
            child: deskPrice(
              amount(published['fairValue']),
              'Published model',
              '平台模型估值',
              text(snap['availableAt']),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 18,
        children: [
          homeChartLegend(p.muted, 'Price', '股价'),
          homeChartLegend(p.accent, 'Published fair value', '平台公允价值'),
        ],
      ),
      const SizedBox(height: 8),
      if (hist.length >= 2 && prices.length >= 2)
        SizedBox(
          height: 210,
          child: ValuationTrendChart(
            history: [
              for (final h in hist)
                {
                  'asOfDate': h['availableAt'],
                  'fairValue': h['publishedFairValue'],
                },
            ],
            priceHistory: prices,
            currency: currency,
            palette: p,
            selectedQuarterKey: '',
            labelFontSize: 11,
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.all(24),
          child: label(
            'Insufficient dated history to draw a curve.',
            '带日期的历史不足，暂不绘制曲线。',
          ),
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 18,
        runSpacing: 12,
        children: [
          for (final m in asList(c['metrics']).take(3))
            SizedBox(
              width: 145,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label(
                    metricName(text(m['key'])),
                    metricName(text(m['key'])),
                    size: 12,
                  ),
                  const SizedBox(height: 4),
                  Text(pct(m['value']), style: deskHeading(21)),
                  label(
                    '${w('Prior', '前值')} ${pct(m['previous'])}',
                    '${w('Prior', '前值')} ${pct(m['previous'])}',
                    size: 11,
                  ),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          w('Why this model? Assumptions & guidance', '估值依据：假设与管理层指引'),
          style: const TextStyle(fontSize: 13),
        ),
        children: [
          label(
            text(published['formula']),
            text(published['formula']),
            size: 12,
          ),
          const SizedBox(height: 10),
          if (asMap(c['templates']).isNotEmpty)
            label(
              'Standalone FCFE component · Ke ${pct(asMap(asMap(c['templates'])['Base'])['ke'])} · terminal growth ${pct(asMap(asMap(c['templates'])['Base'])['g'])}. The platform result may include other methods.',
              '独立 FCFE 部分 · Ke ${pct(asMap(asMap(c['templates'])['Base'])['ke'])} · 永续增长 ${pct(asMap(asMap(c['templates'])['Base'])['g'])}。平台结果可能包含其他方法。',
              size: 12,
            ),
          const SizedBox(height: 10),
          for (final e in asList(asMap(c['guidance'])['evidence']).take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    text(
                      e['excerpt'],
                      text(e['quote'], text(e['evidence'], text(e['text']))),
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                  if (text(e['observedAt']).isNotEmpty)
                    label(
                      '${e['observedAt']} · ${text(e['speaker'])}',
                      '${e['observedAt']} · ${text(e['speaker'])}',
                      size: 11,
                    ),
                  if (Uri.tryParse(text(e['url']))?.scheme == 'https')
                    TextButton.icon(
                      onPressed: () => openBrowserPath(text(e['url'])),
                      icon: const Icon(Icons.open_in_new, size: 13),
                      label: Text(w('Open evidence', '打开证据来源')),
                    ),
                ],
              ),
            ),
          if (asList(asMap(c['guidance'])['evidence']).isEmpty)
            label(
              'No guidance evidence attached to this model node. This does not prove management issued no guidance.',
              '此模型节点未附指引证据，不代表管理层未发布指引。',
              size: 12,
            ),
        ],
      ),
    ];
  }

  Widget opportunityManagerEvidence() {
    final current = opportunityCutoff == asOf;
    final rows = current
        ? asList(opportunityRow['managers'])
        : <Map<String, dynamic>>[];
    if (!current) {
      final seen = <String>{};
      final dated = asList(opportunityEvents?['events'])
          .where((e) => text(e['date']).compareTo(opportunityCutoff) <= 0)
          .toList();
      final quarters = dated.map((e) => text(e['reportDate'])).toList()..sort();
      final latestQuarter = quarters.lastOrNull;
      for (final e in dated.where((e) => e['reportDate'] == latestQuarter)) {
        if (seen.add(text(e['guruId']))) {
          rows.add({...e, 'availableAt': e['date']});
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                current
                    ? w('Who holds it — and what changed', '谁持有，什么变了')
                    : w('Quarterly disclosure evidence', '季度披露证据'),
                style: deskHeading(17),
              ),
            ),
            Text('${rows.length}', style: TextStyle(color: p.muted)),
          ],
        ),
        const SizedBox(height: 8),
        if (!current)
          label(
            'Historical extracts; a missing observation is not an exit.',
            '历史摘录，缺少记录不代表清仓。',
            size: 11,
            color: p.secondary,
          ),
        for (final m in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: GuruAvatar(
              guru: {
                'id': m['guruId'],
                'name': m['name'],
                'avatarUrl': m['avatar'] ?? '/guru-avatars/${m['guruId']}.png',
              },
              palette: p,
              size: 32,
            ),
            title: Text(
              text(m['name']),
              style: TextStyle(color: p.text, fontSize: 13),
            ),
            subtitle: Text(
              '${opportunityAction(text(m['action']))} · ${w('Filed', '披露')} ${m['availableAt']}\n${w('Held', '持仓截至')} ${m['reportDate']} · ${pct(m['weight'])}',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () {
              updateUI(() {
                managerDesk = true;
                selectedGuru = null;
                discoveryTab = 'gurus';
              });
              navigate('discover');
              unawaited(
                loadGuru(
                  text(m['guruId']),
                  filingId: text(m['accession']),
                  holdingTicker: opportunityTicker,
                ),
              );
            },
          ),
      ],
    );
  }

  List<Widget> watchingPage() {
    final watches = asList(home?['watches']);
    return [
      Text(
        w('Your research, since you saved it.', '从保存那一刻，持续跟踪变化。'),
        style: deskHeading(24),
      ),
      const SizedBox(height: 8),
      label(
        'Dated observations, not portfolio positions. Updates are checked when you open this workspace.',
        '带日期的观察记录，不是持仓。打开工作区时检查更新。',
        size: 13,
      ),
      const SizedBox(height: 20),
      if (watches.isEmpty)
        card([
          label(
            'Save a company from any research lens. No DCF setup is required.',
            '在任意研究视角保存公司，无须先填写 DCF。',
          ),
          button(
            'Explore companies',
            '浏览公司',
            () => updateUI(() => opportunityLens = 'holdings'),
          ),
        ]),
      for (final w0 in watches)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: homeStockLogo(text(w0['ticker']), 36),
          title: Text(
            text(w0['ticker']),
            style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${w('Saved', '保存于')} ${w0['asOf']} · ${w0['status'] == 'new_evidence'
                ? w('New evidence to review', '有新证据待复核')
                : w0['status'] == 'data_unavailable'
                ? w('Data unavailable', '数据不可用')
                : w('No new evidence', '暂无新证据')}',
            style: TextStyle(color: p.muted),
          ),
          trailing: TextButton(
            onPressed: () => unawaited(openWatch(text(w0['id']))),
            child: Text(w('Review changes', '复核变化')),
          ),
        ),
      if (watchComparison != null) ...watchComparisonView(),
    ];
  }

  List<Widget> watchComparisonView() {
    final r = watchComparison!,
        watch = asMap(r['watch']),
        then = asMap(watch['baseline']),
        now = asMap(r['now']),
        saved13f = asMap(watch['researchEvidence']),
        current13f = asMap(r['institutionalEvidence']);
    final currency = text(asMap(then['price'])['currency']);
    String amount(dynamic v, [String? unit]) => nullableNumber(v) == null
        ? '—'
        : '${currencySymbol(unit ?? currency)}${number(v).toStringAsFixed(2)}';
    return [
      const SizedBox(height: 24),
      card([
        Text(
          '${watch['ticker']} · ${w('Then → Now', '当时 → 现在')}',
          style: deskHeading(24),
        ),
        const SizedBox(height: 8),
        label(
          '${then['asOf']} → $asOf · ${w('Original observation preserved', '原始观察保持不变')}',
          '${then['asOf']} → $asOf · 原始观察保持不变',
          size: 13,
        ),
        if (saved13f.isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.accent.withValues(alpha: .35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(
                  'SAVED 13F RESEARCH OBSERVATION',
                  '已保存的 13F 研究观察',
                  size: 9,
                  color: p.accent,
                ),
                const SizedBox(height: 6),
                Text(
                  _insightBehaviorHeadline(text(saved13f['headlineKey'])),
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                label(
                  '${reportQuarterLabel(text(saved13f['reportDate']))} · ${w('frozen with', '保存')} ${asList(saved13f['importantChanges']).length} ${w('important changes', '项重要变动')}',
                  '${reportQuarterLabel(text(saved13f['reportDate']))} · 保存 ${asList(saved13f['importantChanges']).length} 项重要变动',
                  size: 10,
                ),
                if (current13f.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '${w('Latest comparable quarter', '最新可比季度')} ${reportQuarterLabel(text(current13f['reportDate']))} · ${_insightBehaviorHeadline(text(current13f['headlineKey']))}',
                    style: TextStyle(color: p.muted, fontSize: 11, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        for (final row in [
          (
            w('Market price', '市场价格'),
            amount(asMap(then['price'])['value']),
            amount(
              asMap(now['price'])['value'],
              text(asMap(now['price'])['currency']),
            ),
          ),
          (
            w('Published model', '平台模型'),
            amount(
              asMap(then['published'])['fairValue'],
              text(asMap(asMap(then['snapshot'])['base'])['currency']),
            ),
            amount(
              asMap(now['published'])['fairValue'],
              text(asMap(asMap(now['snapshot'])['base'])['currency']),
            ),
          ),
          for (final m in asList(r['metrics']))
            (metricName(text(m['key'])), pct(m['then']), pct(m['now'])),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(row.$1, style: TextStyle(color: p.muted)),
                ),
                Expanded(
                  child: Text(row.$2, style: TextStyle(color: p.text)),
                ),
                const Icon(Icons.arrow_forward, size: 14),
                Expanded(
                  child: Text(
                    row.$3,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: p.text),
                  ),
                ),
              ],
            ),
          ),
        if (r['comparable'] != true)
          label(
            'Model methods or coverage differ; no valuation-change percentage is claimed.',
            '模型方法或覆盖不同，不计算估值变化百分比。',
            color: p.secondary,
            size: 12,
          )
        else
          label(
            'Model change ${pct(r['modelChange'])} · Price change ${pct(r['priceChange'])}',
            '模型变化 ${pct(r['modelChange'])} · 股价变化 ${pct(r['priceChange'])}',
            color: p.accent,
          ),
        const SizedBox(height: 16),
        label(
          '${asList(r['newFilings']).length} new manager disclosures since the last review',
          '上次复核后新增 ${asList(r['newFilings']).length} 份经理披露',
          size: 13,
        ),
        for (final e in asList(r['newFilings']).take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(
              '${e['name']} · ${opportunityAction(text(e['action']))} · ${e['availableAt']}',
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ),
        const SizedBox(height: 16),
        label(
          'This compares published model observations. It does not change your assumptions or place an order.',
          '这里只比较平台模型观察，不修改个人假设，也不会下单。',
          size: 12,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: busy ? null : () => unawaited(acknowledgeWatch()),
              child: Text(w('Mark reviewed', '标记已复核')),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                loadCompany(text(watch['ticker']), initialSection: 'value'),
              ),
              child: Text(w('Open valuation', '打开估值研究')),
            ),
          ],
        ),
      ]),
    ];
  }
}
