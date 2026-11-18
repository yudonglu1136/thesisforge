part of 'main.dart';

// Visual target confirmed by the user: exec-82f085f7... Connected Research
// Workbench. The exact manager / filing / common claim drives every pane.
extension _InvestmentDesk on _InvestmentWorkspaceState {
  List<Map<String, dynamic>> get deskFilings {
    final rows = <String, Map<String, dynamic>>{};
    for (final f in [
      ...asList(homeBrief?['history']),
      asMap(homeBrief?['latest']),
    ]) {
      final id = text(f['accessionNumber']), available = text(f['filingDate']);
      if (id.isNotEmpty &&
          available.isNotEmpty &&
          available.compareTo(asOf) <= 0 &&
          text(f['reportDate']).compareTo(available) <= 0) {
        rows[id] = f;
      }
    }
    return rows.values.toList()..sort(
      (a, b) => (text(a['filingDate']) + text(a['accessionNumber'])).compareTo(
        text(b['filingDate']) + text(b['accessionNumber']),
      ),
    );
  }

  Map<String, dynamic> get deskFiling =>
      deskFilings
          .where((f) => f['accessionNumber'] == deskFilingId)
          .firstOrNull ??
      {};
  List<Map<String, dynamic>> get deskHoldings =>
      asList(deskFiling['topHoldings'])
          .where(
            (h) =>
                text(h['id']).endsWith('-COMMON') &&
                stockLogoTicker(text(h['ticker'])).isNotEmpty,
          )
          .toList();
  Map<String, dynamic>? get deskHolding =>
      deskHoldings.where((h) => h['id'] == deskClaimId).firstOrNull;

  void clearDeskResearch() {
    homeExampleSerial++;
    homeExample = null;
    homeExampleLoading = false;
    homeExampleError = null;
    homeExampleTicker = '';
  }

  void syncDeskLocation() {
    if (page != 'home') return;
    replaceBrowserQuery({
      'deskGuru': homeGuruId,
      'deskFiling': deskFilingId,
      'deskClaim': deskClaimId,
      'deskTab': deskTab,
    }, replaceCurrent: true);
  }

  void chooseDeskFiling(String accession, {String? retainedClaim}) {
    final claim = retainedClaim ?? deskClaimId;
    updateUI(() {
      deskFilingId = text(
        deskFilings
            .where((f) => f['accessionNumber'] == accession)
            .firstOrNull?['accessionNumber'],
        text(deskFilings.lastOrNull?['accessionNumber']),
      );
      final h =
          deskHoldings.where((h) => h['id'] == claim).firstOrNull ??
          (homeGuruId == 'bill-ackman' && claim.isEmpty
              ? deskHoldings.where((h) => h['ticker'] == 'MSFT').firstOrNull
              : null) ??
          deskHoldings.firstOrNull;
      deskClaimId = text(h?['id']);
      clearDeskResearch();
      homeExampleTicker = text(h?['ticker']);
    });
    syncDeskLocation();
    if (deskHolding != null) unawaited(loadHomeExample());
  }

  void chooseDeskHolding(Map<String, dynamic> h) {
    if (!deskHoldings.any((row) => row['id'] == h['id'])) return;
    updateUI(() {
      deskClaimId = text(h['id']);
      clearDeskResearch();
      homeExampleTicker = text(h['ticker']);
      homeMobileTab = 'value';
    });
    syncDeskLocation();
    unawaited(loadHomeExample());
  }

  void deskHistory() {
    final manager = homeGuruId,
        filing = deskFilingId,
        symbol = text(deskHolding?['ticker']);
    if (symbol.isEmpty) return;
    updateUI(() {
      discoveryTab = 'gurus';
      selectedGuru = null;
      selectedQuarter = '';
      selectedHolding = '';
    });
    navigate('discover');
    unawaited(loadGuru(manager, filingId: filing, holdingTicker: symbol));
  }

  void deskValuation() {
    if (deskHolding == null || homeExample == null) return;
    unawaited(
      loadCompany(
        text(deskHolding?['ticker']),
        initialSection: 'value',
        origin: 'guru_disclosure',
        evidence: {
          'guruId': homeGuruId,
          'name': homeManager?['name'],
          'accession': deskFilingId,
          'reportDate': deskFiling['reportDate'],
          'availableAt': deskFiling['filingDate'],
        },
      ),
    );
  }

  void searchDesk() {
    final query = search.text.trim();
    if (query.isEmpty) return;
    final managers = asList(discoveryData?['gurus'])
        .where(
          (g) => ('${text(g['name'])} ${text(g['entityName'])}')
              .toLowerCase()
              .contains(query.toLowerCase()),
        )
        .toList();
    final holdings = deskHoldings
        .where(
          (h) => ('${text(h['ticker'])} ${text(h['issuer'])}')
              .toLowerCase()
              .contains(query.toLowerCase()),
        )
        .toList();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(w('Search research desk', '搜索研究工作台')),
        content: SizedBox(
          width: 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final g in managers)
                  ListTile(
                    title: Text(text(g['name'])),
                    subtitle: Text(text(g['entityName'])),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(loadHomeBrief(text(g['id'])));
                    },
                  ),
                for (final h in holdings)
                  ListTile(
                    leading: homeStockLogo(text(h['ticker']), 30),
                    title: Text(text(h['ticker'])),
                    subtitle: Text(text(h['issuer'])),
                    onTap: () {
                      Navigator.pop(ctx);
                      chooseDeskHolding(h);
                    },
                  ),
                if (stockLogoTicker(query).isNotEmpty)
                  ListTile(
                    title: Text(
                      w(
                        'Open company research: ${query.toUpperCase()}',
                        '打开公司研究：${query.toUpperCase()}',
                      ),
                    ),
                    subtitle: Text(
                      w(
                        'Direct search, independent of a Guru.',
                        '直接搜索，不归属于特定投资大师。',
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(loadCompany(query));
                    },
                  ),
                if (managers.isEmpty &&
                    holdings.isEmpty &&
                    stockLogoTicker(query).isEmpty)
                  label(
                    'No match. Try a manager name or exact ticker.',
                    '暂无匹配，请输入经理姓名或准确股票代码。',
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(w('Close', '关闭')),
          ),
        ],
      ),
    );
  }

  void showDeskFiling() {
    final f = deskFiling, url = text(asMap(deskFiling['filing'])['secUrl']);
    final uri = Uri.tryParse(url);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(w('Source filing', '原始申报')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text(homeManager?['entityName'])),
                const SizedBox(height: 12),
                Text(
                  '${text(f['quarterLabel'])} · ${text(f['accessionNumber'])}',
                ),
                const SizedBox(height: 8),
                Text(
                  w('Held ', '持仓日 ') +
                      text(f['reportDate']) +
                      w(' · Filed ', ' · 披露日 ') +
                      text(f['filingDate']),
                ),
                const SizedBox(height: 16),
                if (url.isNotEmpty)
                  SelectableText(url)
                else
                  label(
                    'Source link unavailable in this extract.',
                    '此摘录未提供原始链接。',
                  ),
                const SizedBox(height: 16),
                label(
                  '13F is a delayed disclosure, not live trading evidence.',
                  '13F 是滞后披露，不是实时交易证据。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(w('Close', '关闭')),
          ),
          if (uri?.scheme == 'https' &&
              const {'www.sec.gov', 'sec.gov'}.contains(uri?.host))
            TextButton(
              onPressed: () => openBrowserPath(url),
              child: Text(w('Open SEC filing', '打开 SEC 申报')),
            ),
        ],
      ),
    );
  }

  TextStyle deskHeading(double size) => TextStyle(
    color: p.text,
    fontSize: size,
    height: context.isChinese ? 1.28 : 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: context.isChinese ? 0 : -.5,
  );

  List<Widget> deskPage() => [
    LayoutBuilder(
      builder: (_, c) {
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label(
              'YOUR INVESTMENT RESEARCH DESK',
              '你的投资研究工作台',
              color: p.accent,
              size: 11,
            ),
            const SizedBox(height: 10),
            Text(
              w('Research desk', '研究工作台'),
              style: deskHeading(c.maxWidth < 600 ? 30 : 38),
            ),
            const SizedBox(height: 8),
            label(
              'From a disclosed holding to your own valuation.',
              '从披露的持仓，走向自己的估值判断。',
              size: 16,
            ),
          ],
        );
        final searchBox = TextField(
          key: const ValueKey('home-company-search'),
          controller: search,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => searchDesk(),
          decoration: InputDecoration(
            hintText: w('Find a company or investor…', '搜索公司或投资人…'),
            prefixIcon: const Icon(Icons.search, size: 21),
            suffixIcon: IconButton(
              tooltip: w('Search desk', '搜索工作台'),
              onPressed: searchDesk,
              icon: const Icon(Icons.arrow_forward, size: 20),
            ),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        );
        final date = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: showDateDialog,
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(w('As of ', '截至 ') + asOf),
            ),
            const SizedBox(height: 5),
            label('Historical PIT', '历史时点（PIT）', size: 11),
          ],
        );
        if (c.maxWidth < 950) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              const SizedBox(height: 18),
              searchBox,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: date),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            const SizedBox(width: 24),
            SizedBox(width: c.maxWidth * .29, child: searchBox),
            const SizedBox(width: 18),
            date,
          ],
        );
      },
    ),
    const SizedBox(height: 22),
    Divider(color: p.border, height: 1),
    const SizedBox(height: 24),
    if (asList(home?['attention']).isNotEmpty) homeReviewAlert(),
    LayoutBuilder(
      builder: (_, c) {
        if (c.maxWidth < 950) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in [
                    ('gurus', 'Investor', '投资人'),
                    ('holdings', 'Holdings', '持仓'),
                    ('value', 'Research', '研究'),
                  ])
                    ChoiceChip(
                      label: Text(w(t.$2, t.$3)),
                      selected: homeMobileTab == t.$1,
                      onSelected: (_) => updateUI(() => homeMobileTab = t.$1),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              if (homeMobileTab == 'gurus')
                deskInvestors()
              else if (homeMobileTab == 'holdings')
                deskStocks()
              else
                deskResearch(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: c.maxWidth >= 1150 ? 204 : 166,
              child: deskInvestors(),
            ),
            Container(
              width: 1,
              height: 660,
              margin: const EdgeInsets.symmetric(horizontal: 18),
              color: p.border,
            ),
            SizedBox(
              width: c.maxWidth >= 1150 ? 300 : 242,
              child: deskStocks(),
            ),
            Container(
              width: 1,
              height: 660,
              margin: const EdgeInsets.symmetric(horizontal: 20),
              color: p.border,
            ),
            Expanded(child: deskResearch()),
          ],
        );
      },
    ),
    homeResearchFooter(),
  ];

  Widget deskInvestors() {
    final all = asList(discoveryData?['gurus']),
        featured = <Map<String, dynamic>>[];
    for (final id in [
      'bill-ackman',
      'warren-buffett',
      'gavin-baker',
      homeGuruId,
    ]) {
      final row = all.where((g) => g['id'] == id).firstOrNull;
      if (row != null && !featured.any((g) => g['id'] == id)) featured.add(row);
    }
    if (featured.isEmpty) featured.addAll(all.take(3));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(w('Start with an investor', '从投资人出发'), style: deskHeading(18)),
        const SizedBox(height: 24),
        if (discoveryLoading) const LinearProgressIndicator(minHeight: 2),
        for (final g in featured)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: homeGuruId == g['id']
                  ? p.accent.withValues(alpha: .13)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                key: ValueKey('home-investor-${text(g['id'])}'),
                onTap: () {
                  updateUI(() => homeMobileTab = 'holdings');
                  unawaited(loadHomeBrief(text(g['id'])));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: homeGuruId == g['id']
                            ? p.accent
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      GuruAvatar(
                        guru: {...g, 'avatarUrl': g['avatar']},
                        palette: p,
                        size: 48,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          guruDisplayName(g, context.language),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, color: p.muted, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        Divider(color: p.border, height: 1),
        const SizedBox(height: 22),
        if (homeManager != null)
          label(
            text(homeManager?['entityName']),
            text(homeManager?['entityName']),
            color: p.text,
          ),
        const SizedBox(height: 22),
        for (final r in [
          ('Quarter', '季度', text(deskFiling['quarterLabel'], '—')),
          ('Held', '持仓日', text(deskFiling['reportDate'], '—')),
          ('Filed', '披露日', text(deskFiling['filingDate'], '—')),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: label(r.$1, r.$2, size: 12)),
                const SizedBox(width: 8),
                Text(r.$3, style: TextStyle(color: p.text, fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 10),
        PopupMenuButton<String>(
          key: const ValueKey('home-manager-menu'),
          tooltip: w('Choose any investor', '选择任一投资人'),
          onSelected: (id) {
            updateUI(() => homeMobileTab = 'holdings');
            unawaited(loadHomeBrief(id));
          },
          itemBuilder: (_) => [
            for (final g in all)
              PopupMenuItem(
                value: text(g['id']),
                child: Text(guruDisplayName(g, context.language)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    w('Browse ', '浏览 ') +
                        all.length.toString() +
                        w(' Gurus', ' 位投资大师'),
                    style: TextStyle(color: p.accent, fontSize: 14),
                  ),
                ),
                Icon(Icons.arrow_forward, color: p.accent, size: 18),
              ],
            ),
          ),
        ),
        if (discoveryError != null || homeBriefError != null) ...[
          const SizedBox(height: 12),
          label(
            'Disclosures unavailable. No holdings were substituted.',
            '披露暂不可用，未替换为其他持仓。',
            size: 12,
          ),
          button(
            'Retry disclosures',
            '重新加载披露数据',
            () => unawaited(
              discoveryError != null ? loadDiscovery() : loadHomeBrief(),
            ),
          ),
        ],
        if (all.isEmpty && !discoveryLoading && discoveryError == null)
          label(
            'No manager disclosures at this cutoff. Try another date.',
            '此截止日期暂无经理披露，请尝试其他日期。',
          ),
      ],
    );
  }

  Widget deskStocks() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(w('Reported holdings', '申报持仓'), style: deskHeading(18)),
          ),
          if (deskFilings.isNotEmpty)
            PopupMenuButton<String>(
              key: const ValueKey('home-quarter-menu'),
              tooltip: w('Choose filing', '选择申报'),
              onSelected: (v) => chooseDeskFiling(v),
              itemBuilder: (_) => [
                for (final f in deskFilings.reversed)
                  PopupMenuItem(
                    value: text(f['accessionNumber']),
                    child: Text(
                      '${text(f['quarterLabel'])} · ${text(f['filingDate'])} · ${text(f['accessionNumber']).split('-').last}',
                    ),
                  ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: p.border),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      text(deskFiling['quarterLabel']),
                      style: TextStyle(color: p.text, fontSize: 12),
                    ),
                    Icon(Icons.expand_more, size: 16, color: p.muted),
                  ],
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(child: label('Issuer', '公司', size: 12)),
          label('Weight', '权重', size: 12),
        ],
      ),
      const SizedBox(height: 12),
      Divider(color: p.border, height: 1),
      if (homeBriefLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: LinearProgressIndicator(minHeight: 2),
        )
      else if (deskHoldings.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: label(
            'No common shares available in this filing extract.',
            '这份申报摘录暂无可用普通股持仓。',
          ),
        )
      else
        SizedBox(
          height: 420,
          child: Scrollbar(
            child: ListView(
              key: ValueKey('desk-holdings-$homeGuruId-$deskFilingId'),
              primary: false,
              padding: EdgeInsets.zero,
              children: [for (final h in deskHoldings) deskStockRow(h)],
            ),
          ),
        ),
      const SizedBox(height: 20),
      label(
        'Selected common shares · reported weights',
        '部分普通股摘录 · 申报权重',
        size: 12,
      ),
      const SizedBox(height: 8),
      label(
        'Not the complete book. A filing is not a buy signal.',
        '不是完整持仓，申报不等于买入信号。',
        size: 11,
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: deskHolding == null ? null : deskHistory,
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: Text(w('View quarterly history', '查看历季持仓')),
        ),
      ),
    ],
  );

  Widget deskStockRow(Map<String, dynamic> h) {
    final selected = h['id'] == deskClaimId;
    return Semantics(
      selected: selected,
      button: true,
      label: w(
        'Select ${text(h['ticker'])} holding',
        '选择 ${text(h['ticker'])} 持仓',
      ),
      child: Material(
        color: selected ? p.accent.withValues(alpha: .13) : Colors.transparent,
        child: InkWell(
          key: ValueKey('home-holding-${text(h['ticker'])}'),
          onTap: () => chooseDeskHolding(h),
          child: Container(
            constraints: const BoxConstraints(minHeight: 70),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: selected ? p.accent : Colors.transparent,
                  width: 3,
                ),
                bottom: BorderSide(color: p.border.withValues(alpha: .65)),
              ),
            ),
            child: Row(
              children: [
                homeStockLogo(text(h['ticker']), 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text(h['ticker']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        text(h['issuer']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  pct(h['pctPortfolio']),
                  style: TextStyle(color: p.text, fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget deskResearch() {
    final h = deskHolding, c = homeExample;
    if (homeBriefLoading) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: label('Loading the selected disclosure…', '正在加载所选披露…'),
      );
    }
    if (h == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: label(
          'Select an investor and a disclosed holding to begin.',
          '选择投资人和一只披露的股票，开始研究。',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${homeManager == null ? '' : guruDisplayName(homeManager!, context.language)}  /  ${text(deskFiling['quarterLabel'])}  /  ${text(h['ticker'])}',
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            homeStockLogo(text(h['ticker']), 50),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text(c?['name'], text(h['issuer'], text(h['ticker']))),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: deskHeading(28),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    text(h['ticker']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (final t in [
              ('value', 'Business & value', '经营与估值'),
              ('position', 'Position history', '仓位历史'),
            ])
              Expanded(
                child: InkWell(
                  key: ValueKey('home-detail-${t.$1}'),
                  onTap: () {
                    updateUI(() => deskTab = t.$1);
                    syncDeskLocation();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: deskTab == t.$1 ? p.accent : p.border,
                          width: deskTab == t.$1 ? 3 : 1,
                        ),
                      ),
                    ),
                    child: Text(
                      w(t.$2, t.$3),
                      style: TextStyle(
                        color: deskTab == t.$1 ? p.text : p.muted,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (deskTab == 'position')
          deskPosition()
        else if (homeExampleLoading) ...[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 18),
          label(
            'Loading ${text(h['ticker'])} research at $asOf…',
            '正在加载截至 $asOf 的 ${text(h['ticker'])} 研究…',
          ),
        ] else if (c == null || homeExampleError != null) ...[
          if (homeExampleError == 'not_covered')
            label(
              'No PIT research is available for ${text(h['ticker'])} at $asOf. You can still inspect its filing and position history.',
              '截至 $asOf 暂无 ${text(h['ticker'])} 的历史时点（PIT）研究模型，仍可查看原始申报和仓位历史。',
            )
          else
            label(
              'Research is unavailable for ${text(h['ticker'])} at this cutoff. No substitute stock is shown.',
              '此截止日期的 ${text(h['ticker'])} 研究不可用，不会显示其他股票。',
            ),
          const SizedBox(height: 16),
          if (homeExampleError != 'not_covered')
            button(
              'Retry research',
              '重试研究',
              () => unawaited(loadHomeExample()),
            ),
        ] else
          deskValue(c),
        if (deskTab == 'position' || (!homeExampleLoading && c == null))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: showDeskFiling,
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(w('View filing', '查看申报')),
            ),
          ),
        const SizedBox(height: 16),
        label(
          'Research uses information available at $asOf, not the manager’s entry valuation.',
          '研究使用 $asOf 前可得的信息，不是经理买入时的估值。',
          size: 11,
        ),
      ],
    );
  }

  Widget deskValue(Map<String, dynamic> c) {
    final snap = asMap(c['snapshot']),
        price = asMap(snap['price']),
        currency = text(c['currency']);
    String amount(dynamic v) => nullableNumber(v) == null
        ? '—'
        : currencySymbol(currency) + number(v).toStringAsFixed(2);
    final history = asList(
      c['history'],
    ).where((h) => text(h['availableAt']).compareTo(asOf) <= 0).toList();
    final prices = asList(
      c['priceHistory'],
    ).where((h) => text(h['date']).compareTo(asOf) <= 0).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: deskPrice(
                amount(price['value']),
                'Market price',
                '市场价格',
                text(price['date'], '—'),
              ),
            ),
            Container(
              width: 1,
              height: 70,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              color: p.border,
            ),
            Expanded(
              child: deskPrice(
                amount(asMap(c['published'])['fairValue']),
                'Published blended value',
                '已发布综合估值',
                text(snap['availableAt'], '—'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            homeChartLegend(
              p.muted,
              'Price (${text(c['ticker'])})',
              '股价（${text(c['ticker'])}）',
            ),
            homeChartLegend(
              p.accent,
              'Published model (fair value)',
              '已发布模型（公允价值）',
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (history.length >= 2 && prices.length >= 2)
          SizedBox(
            height: 244,
            child: ValuationTrendChart(
              history: [
                for (final h in history)
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
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: label(
              'Not enough dated observations to draw a comparison.',
              '带日期的观测不足，暂不能绘制对比曲线。',
            ),
          ),
        const SizedBox(height: 14),
        Divider(color: p.border, height: 1),
        const SizedBox(height: 16),
        label(
          'Latest disclosed financials · ${text(snap['period'])} · ${text(snap['availableAt'])}',
          '最新披露财务 · ${text(snap['period'])} · ${text(snap['availableAt'])}',
          size: 12,
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (_, bounds) => Wrap(
            spacing: 10,
            runSpacing: 14,
            children: [
              for (final m in [
                ('revenueGrowth', 'Revenue YoY', '收入同比'),
                ('operatingMargin', 'TTM operating margin', 'TTM 营业利润率'),
                ('fcfMargin', 'TTM FCF margin', 'TTM 自由现金流率'),
              ])
                SizedBox(
                  width: (bounds.maxWidth - 20) / 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label(m.$2, m.$3, size: 12),
                      const SizedBox(height: 6),
                      Text(
                        pct(
                          asList(c['metrics'])
                              .where((r) => r['key'] == m.$1)
                              .firstOrNull?['value'],
                        ),
                        style: deskHeading(22),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            TextButton.icon(
              onPressed: showDeskFiling,
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(w('View filing', '查看申报')),
            ),
            FilledButton.icon(
              onPressed: deskValuation,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(
                w(
                  'Open ${text(c['ticker'])} valuation',
                  '打开 ${text(c['ticker'])} 估值',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget deskPosition() {
    final rows = <Map<String, dynamic>>[];
    for (final f in deskFilings.where(
      (f) =>
          text(f['filingDate']).compareTo(text(deskFiling['filingDate'])) <=
              0 &&
          text(f['reportDate']).compareTo(text(deskFiling['reportDate'])) <= 0,
    )) {
      final h = [...asList(f['topHoldings']), ...asList(f['largestChanges'])]
          .where(
            (h) =>
                h['id'] == deskClaimId && h['ticker'] == deskHolding?['ticker'],
          )
          .firstOrNull;
      rows.add({'filing': f, 'holding': h});
    }
    final visible = rows.reversed.take(12).toList();
    double maximum = 0;
    for (final r in visible) {
      maximum = math.max(maximum, number(asMap(r['holding'])[deskMetric]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in [
              ('shares', 'Shares', '股数'),
              ('pctPortfolio', 'Weight', '权重'),
              ('value', 'Reported value', '申报市值'),
            ])
              ChoiceChip(
                label: Text(w(m.$2, m.$3)),
                selected: deskMetric == m.$1,
                onSelected: (_) => updateUI(() => deskMetric = m.$1),
              ),
          ],
        ),
        const SizedBox(height: 18),
        for (final r in visible)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  child: label(
                    text(asMap(r['filing'])['quarterLabel']),
                    text(asMap(r['filing'])['quarterLabel']),
                    size: 12,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: nullableNumber(asMap(r['holding'])[deskMetric]) == null
                      ? label('Not in extract', '摘录未包含', size: 11)
                      : LinearProgressIndicator(
                          value: maximum > 0
                              ? number(asMap(r['holding'])[deskMetric]) /
                                    maximum
                              : 0,
                          minHeight: 7,
                          color: p.accent,
                          backgroundColor: p.border,
                          borderRadius: BorderRadius.circular(4),
                        ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 88,
                  child: Text(
                    nullableNumber(asMap(r['holding'])[deskMetric]) == null
                        ? '—'
                        : deskMetric == 'pctPortfolio'
                        ? pct(asMap(r['holding'])[deskMetric])
                        : deskMetric == 'value'
                        ? formatMoney(number(asMap(r['holding'])[deskMetric]))
                        : formatNumber(number(asMap(r['holding'])[deskMetric])),
                    textAlign: TextAlign.right,
                    style: TextStyle(color: p.text, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        label(
          'Up to 12 filings through the selected quarter. A missing extract is not zero or a confirmed new position. Corporate actions are not verified here.',
          '截至所选季度最多 12 份披露。摘录缺失不等于零或确认新建仓；此处尚未核验公司行动。',
          size: 12,
        ),
        const SizedBox(height: 18),
        button(
          'View quarterly history',
          '查看历季持仓',
          deskHistory,
          icon: Icons.arrow_forward,
        ),
      ],
    );
  }

  Widget deskPrice(String value, String en, String zh, String date) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: TextStyle(
            color: p.text,
            fontSize: 34,
            fontWeight: FontWeight.w600,
            letterSpacing: -.8,
          ),
        ),
      ),
      const SizedBox(height: 8),
      label(en, zh, size: 12),
      const SizedBox(height: 4),
      label(date, date, size: 11),
    ],
  );
}
