part of 'main.dart';

// Shared Home loaders and saved-research shelf. The connected desk owns the
// manager / filing / claim selection; viewing it never saves a user decision.
extension _InvestmentHome on _InvestmentWorkspaceState {
  List<Widget> personalHomePage() {
    final snowball = isSnowballMobile;
    return [
      if (!snowball && homeResearchDesk) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              updateUI(() => homeResearchDesk = false);
              replaceBrowserQuery({'workspace': null});
            },
            icon: const Icon(Icons.arrow_back, size: 17),
            label: Text(w('Back to my portfolio', '返回我的组合')),
          ),
        ),
        ...opportunityPage(),
      ] else ...[
        if (!snowball && asList(home?['attention']).isNotEmpty) ...[
          homeReviewAlert(),
          const SizedBox(height: 18),
        ],
        PortfolioResearchPanel(
          key: const ValueKey('personal-home'),
          api: widget.api,
          palette: p,
          asOf: asOf,
          homeMode: true,
          mobileSection: snowball ? page : null,
          onSwitchMobileTab: snowball
              ? (nextTab) => unawaited(requestNavigate(nextTab))
              : null,
          userEmail: widget.userEmail,
          localPreview: widget.localPreview,
          colorBlind: widget.colorBlind,
          onToggleColorBlind: widget.onToggleColorBlind,
          onLanguage: widget.onLanguage,
          onLogout: widget.onLogout != null
              ? () => unawaited(requestLogout())
              : null,
          onSetAppPassword: widget.onUpdatePassword != null
              ? () => unawaited(showSetAppPasswordDialog())
              : null,
          onShowPairCode: widget.onCreatePairCode != null
              ? () => unawaited(showDevicePairCodeDialog())
              : null,
          onShowCutoffPicker: () => unawaited(showDateDialog()),
          onShowInstallGuide: !isStandaloneDisplayMode()
              ? () => unawaited(showIosInstallGuideDialog(context, palette: p))
              : null,
          onDetails: snowball
              ? () => unawaited(requestNavigate('holdings'))
              : () => navigate('book'),
          onExploreDiscover: snowball
              ? null
              : () {
                  discoveryTab = 'managers';
                  navigate('discover');
                },
          onExploreStrategies: snowball ? null : () => navigate('strategies'),
          onCompany: (symbol, section) =>
              unawaited(loadCompany(symbol, initialSection: section)),
          onGuru: (id, filing) {
            discoveryTab = 'managers';
            navigate('discover');
            unawaited(loadGuru(id, filingId: filing));
          },
        ),
        if (!snowball &&
            home != null &&
            (asList(home?['watches']).isNotEmpty ||
                asList(home?['decisions']).isNotEmpty)) ...[
          const SizedBox(height: 20),
          homeSavedWatchAndDecisionStrip(),
        ],
        if (!snowball) ...[
          const SizedBox(height: 22),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => navigate('discover'),
                icon: const Icon(Icons.explore_outlined, size: 18),
                label: Text(
                  w('Find your next idea in Discover', '前往「发现」寻找下一个投资机会'),
                ),
              ),
            ],
          ),
        ],
      ],
    ];
  }
  // These bundled marks use white lettering on transparent pixels. Preserve
  // the assets, with a contrasting Home backdrop; other terminal uses stay put.
  Widget homeStockLogo(String ticker, double size) => StockLogo(
    ticker: ticker,
    palette: p,
    size: size,
    backgroundColor: const {'AMZN', 'UBER'}.contains(stockLogoTicker(ticker))
        ? const Color(0xff1b2932)
        : null,
  );

  Map<String, dynamic>? get homeManager {
    final all = asList(discoveryData?['gurus']);
    return all.where((g) => g['id'] == homeGuruId).firstOrNull ??
        all.firstOrNull;
  }

  Future<void> loadHomeBrief([String? id]) async {
    final requested = id ?? text(homeManager?['id']);
    if (requested.isEmpty) return;
    final retainedFiling = requested == homeGuruId ? deskFilingId : '';
    final retainedClaim = requested == homeGuruId ? deskClaimId : '';
    final serial = ++homeBriefSerial, cutoff = asOf;
    updateUI(() {
      clearDeskResearch();
      deskFilingId = '';
      deskClaimId = '';
      homeGuruId = requested;
      homeBrief = null;
      homeBriefLoading = true;
      homeBriefError = null;
    });
    try {
      final data = await widget.api.getJson(
        '/api/investment/gurus/${Uri.encodeComponent(requested)}?asOf=$cutoff',
      );
      if (!mounted || serial != homeBriefSerial || cutoff != asOf) return;
      if (asMap(data['guru'])['id'] != requested) {
        throw StateError('brief_identity_mismatch');
      }
      updateUI(() => homeBrief = data);
      chooseDeskFiling(retainedFiling, retainedClaim: retainedClaim);
    } catch (_) {
      if (mounted && serial == homeBriefSerial && cutoff == asOf) {
        updateUI(() => homeBriefError = 'unavailable');
      }
    } finally {
      if (mounted && serial == homeBriefSerial) {
        updateUI(() => homeBriefLoading = false);
      }
    }
  }

  Future<void> loadHomeExample([String? symbol]) async {
    final requested = symbol ?? homeExampleTicker;
    if (requested.isEmpty || requested != text(deskHolding?['ticker'])) return;
    final serial = ++homeExampleSerial, cutoff = asOf;
    final manager = homeGuruId, filing = deskFilingId, claim = deskClaimId;
    updateUI(() {
      homeExampleTicker = requested;
      homeExample = null;
      homeExampleLoading = true;
      homeExampleError = null;
    });
    try {
      final data = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(requested)}?asOf=$cutoff',
      );
      if (!mounted ||
          serial != homeExampleSerial ||
          cutoff != asOf ||
          manager != homeGuruId ||
          filing != deskFilingId ||
          claim != deskClaimId) {
        return;
      }
      if (data['ticker'] != requested) {
        throw StateError('example_identity_mismatch');
      }
      updateUI(() => homeExample = data);
    } catch (error) {
      if (mounted && serial == homeExampleSerial && cutoff == asOf) {
        updateUI(
          () => homeExampleError =
              error is ApiRequestException &&
                  const {404, 422}.contains(error.statusCode) &&
                  error.code == 'no_pit_research_at_date'
              ? 'not_covered'
              : 'unavailable',
        );
      }
    } finally {
      if (mounted && serial == homeExampleSerial) {
        updateUI(() => homeExampleLoading = false);
      }
    }
  }

  void browseHomeGurus() {
    updateUI(() {
      discoveryTab = 'gurus';
      selectedGuru = null;
      discoveryQuery = '';
      followedOnly = false;
    });
    navigate('discover');
  }

  Widget homeChartLegend(Color color, String en, String zh) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, color: color, size: 9),
      const SizedBox(width: 8),
      label(en, zh, size: 11),
    ],
  );

  Widget homeSavedWatchAndDecisionStrip() {
    final watches = asList(home?['watches']);
    final decisions = asList(home?['decisions']);
    return Container(
      key: const ValueKey('home-research-briefing'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bookmark_added_outlined, color: p.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w('My Watchlist & Active Theses', '我的关注池与已保存研究'),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => navigate('research'),
                child: Text(w('Open Research →', '进入研究台 →')),
              ),
            ],
          ),
          if (watches.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in watches.take(8))
                  ActionChip(
                    key: ValueKey('home-watch-${text(item['ticker'])}'),
                    avatar: homeStockLogo(text(item['ticker']), 18),
                    backgroundColor: const Color(0xFF17171B),
                    side: BorderSide(color: p.border),
                    label: Text(
                      text(item['ticker']),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => unawaited(loadCompany(text(item['ticker']))),
                  ),
              ],
            ),
          ],
          if (decisions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in decisions.reversed.take(4))
                  ActionChip(
                    avatar: homeStockLogo(text(d['ticker']), 18),
                    backgroundColor: const Color(0xFF17171B),
                    side: BorderSide(color: p.border),
                    label: Text(
                      '${d['ticker']} · ${_InvestmentWorkspacePages(this).actionLabel(text(d['action']))} · ${d['decisionDate']}',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                    onPressed: () => unawaited(openReview(text(d['decisionId']))),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget homeReviewAlert() {
    final queue = asList(home?['attention']);
    return card([
      ExpansionTile(
        key: ValueKey('home-review-alerts-$asOf'),
        tilePadding: EdgeInsets.zero,
        leading: Icon(Icons.notifications_active_outlined, color: p.accent),
        title: Text(
          w(
            '${queue.length} saved decisions need a review',
            '${queue.length} 项已保存决策需要复核',
          ),
        ),
        subtitle: Text(queue.map((r) => text(r['ticker'])).take(5).join(' · ')),
        children: [
          for (final r in queue)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: homeStockLogo(text(r['ticker']), 30),
              title: Text('${r['ticker']} · ${r['period'] ?? ''}'),
              subtitle: Text(
                r['status'] == 'data_unavailable'
                    ? w('Data unavailable — no rule conclusion', '数据不可用，无法判断规则')
                    : [
                        for (final t in asList(
                          r['triggers'],
                        ).where((t) => t['status'] == 'review_required'))
                          '${metricName(text(asMap(t['rule'])['metric']))} ${asMap(t['rule'])['operator'] == 'lt' ? '<' : '>'} ${pct(asMap(t['rule'])['threshold'])}',
                        if (asList(r['guruChanges']).isNotEmpty)
                          w('Source Guru reported a change', '来源大师披露变化'),
                      ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(openReview(text(r['decisionId']))),
            ),
        ],
      ),
    ]);
  }

  Widget homeResearchFooter() {
    final decisions = asList(home?['decisions']),
        all = asList(discoveryData?['gurus']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 16),
          child: Divider(color: p.border, height: 1),
        ),
        LayoutBuilder(
          builder: (_, c) {
            final intro = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.description_outlined, size: 27, color: p.accent),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w('Continue research', '继续研究'),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 7),
                      label(
                        'Pick up where you left off. Save a valuation, then revisit it when the evidence changes.',
                        '继续上次的研究，保存估值，在证据变化时回来复核。',
                        size: 11,
                      ),
                    ],
                  ),
                ),
              ],
            );
            final saved = decisions.isEmpty
                ? label(
                    home == null
                        ? 'Loading your saved research…'
                        : 'Your saved research will appear here after your first decision.',
                    home == null ? '正在加载已保存研究…' : '完成第一项决策后，已保存研究会显示在这里。',
                    size: 12,
                  )
                : Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final d in decisions.reversed.take(4))
                        ActionChip(
                          avatar: homeStockLogo(text(d['ticker']), 24),
                          label: Text(
                            '${d['ticker']} · ${_InvestmentWorkspacePages(this).actionLabel(text(d['action']))} · ${d['decisionDate']}',
                          ),
                          onPressed: () =>
                              unawaited(openReview(text(d['decisionId']))),
                        ),
                    ],
                  );
            final browse = TextButton.icon(
              onPressed: browseHomeGurus,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(
                w(
                  all.isEmpty
                      ? 'Browse all Gurus'
                      : 'Browse ${all.length} Gurus',
                  all.isEmpty ? '浏览全部大师' : '浏览 ${all.length} 位大师',
                ),
              ),
            );
            if (c.maxWidth < 950) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  intro,
                  const SizedBox(height: 16),
                  saved,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: browse),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: 270, child: intro),
                const SizedBox(width: 25),
                Expanded(child: saved),
                const SizedBox(width: 20),
                browse,
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        if (home != null && asList(home?['attention']).isEmpty)
          label(
            'No saved review rules triggered at this cutoff. This is not a statement about investment risk.',
            '此截止日期未触发已保存的复核规则，不代表没有投资风险。',
            size: 10,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              updateUI(() => discoveryTab = 'copycat');
              navigate('discover');
            },
            child: Text(
              w(
                'Want executable 13F portfolios? Open Copycat Playbook',
                '想直接跟投高胜率大师组合？打开大师作业指挥台',
              ),
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}
