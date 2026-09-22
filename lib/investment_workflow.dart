part of 'main.dart';

// The server owns calculations and immutable versions. This widget only edits
// a sandbox and issues explicit user commands through the existing auth client.
class InvestmentWorkspace extends StatefulWidget {
  const InvestmentWorkspace({
    super.key,
    required this.api,
    required this.palette,
    required this.initialPage,
    required this.initialTicker,
    this.initialAsOf,
    this.initialQuery,
    required this.onLanguage,
    required this.onLegacy,
    this.onLegacyView,
    this.showAdmin = false,
    this.onLogout,
    this.localPreview = false,
  });
  final ApiClient api;
  final Palette palette;
  final String initialPage, initialTicker;
  final String? initialAsOf;
  final Map<String, String>? initialQuery;
  final ValueChanged<AppLanguage> onLanguage;
  final VoidCallback onLegacy;
  final ValueChanged<String>? onLegacyView;
  final bool showAdmin;
  final VoidCallback? onLogout;
  final bool localPreview;
  @override
  State<InvestmentWorkspace> createState() => _InvestmentWorkspaceState();
}

class _InvestmentWorkspaceState extends State<InvestmentWorkspace> {
  late final SemanticsHandle semanticsHandle;
  late String page, asOf;
  String section = 'evidence',
      valuationSection = 'published',
      ticker = '',
      template = 'Base',
      decisionAction = '',
      reviewAction = '';
  String ruleMetric = 'revenueGrowth', ruleOperator = 'lt';
  String? scenarioId, reviewId, scenarioParentId;
  String discoveryOrigin = 'direct_research';
  final sourceGuruIds = <String>{};
  final researchRecentTickers = <String>[];
  Map<String, dynamic>? home, company, calculation, review;
  Map<String, dynamic>? researchFundamental,
      researchInstitution,
      researchDocumentsData,
      researchRecordsData;
  bool researchPanelLoading = false;
  String? researchPanelError;
  bool researchFinancialsLoading = false;
  String? researchFinancialsError;
  String researchStatement = 'income';
  String researchFinancialFrequency = 'annual';
  List<String> researchFinancialMetrics = ['revenue', 'netinccmn'];
  Map<String, dynamic> assumptions = {};
  bool busy = false, ownership = false, priority = false;
  bool ruleEnabled = false, draftDirty = false, reviewOriginal = false;
  Map<String, dynamic>? discoveryData, selectedGuru, entryEvidence;
  Map<String, dynamic> aiInsightsSelection = {};
  // Backward-compatible state for the Value Flow panel still present on the
  // committed production shell. The AI Insights replacement is being
  // developed separately and must not be pulled into this release.
  Map<String, dynamic> valueFlowSelection = {};
  Map<String, dynamic> fundamentalSelection = {};
  Map<String, dynamic> guruStudySelection = {};
  Map<String, dynamic>? homeExample;
  String homeGuruId = 'bill-ackman',
      homeExampleTicker = 'MSFT',
      homeMobileTab = 'gurus';
  String deskFilingId = '',
      deskClaimId = '',
      deskTab = 'value',
      deskMetric = 'shares';
  bool homeExampleLoading = false;
  String? homeExampleError;
  int homeExampleSerial = 0;
  Map<String, dynamic>? homeBrief;
  bool homeBriefLoading = false;
  String? homeBriefError;
  int homeBriefSerial = 0;
  String discoveryTab = 'gurus',
      discoveryQuery = '',
      selectedQuarter = '',
      selectedHolding = '',
      trajectoryMetric = 'shares',
      portfolioTab = 'positions';
  bool followedOnly = false, discoveryLoading = false, guruLoading = false;
  String? discoveryError;
  int discoverySerial = 0, guruSerial = 0, strategyTopN = 3;
  final strategyManagers = <String>{};
  String? error, notice;
  int requestSerial = 0, operationSerial = 0;
  int calculationSerial = 0;
  bool calculationPending = false;
  String? calculationFailure;
  Map<String, dynamic>? valuationReference;
  Timer? calculationTimer;
  Timer? worksheetTimer;
  Future<bool>? worksheetFlight;
  Map<String, dynamic>? worksheetRetry;
  String? worksheetHead, worksheetFailure, worksheetSavedFingerprint;
  String worksheetStatus = 'initial';
  final search = TextEditingController(),
      discoverSearchInput = TextEditingController(),
      insightSearchInput = TextEditingController(),
      dateInput = TextEditingController(),
      notes = TextEditingController();
  final units = TextEditingController(), weight = TextEditingController();
  final threshold = TextEditingController(text: '15'),
      consecutive = TextEditingController(text: '1');
  final scenarioName = TextEditingController(text: 'Base'),
      reversePrice = TextEditingController(),
      targetReturn = TextEditingController(text: '10');
  final reviewNotes = TextEditingController();
  String reverseVariable = 'growth';
  String personalDcfMethod = 'parent_fcfe';
  int forecastHorizon = 5;
  final growth = List.generate(10, (_) => TextEditingController());
  final revenue = List.generate(10, (_) => TextEditingController());
  final hypothesis = TextEditingController();
  final valuationTableScroll = ScrollController();
  final margin = List.generate(10, (_) => TextEditingController());
  final ebitMargin = List.generate(10, (_) => TextEditingController());
  final cashTaxRate = List.generate(10, (_) => TextEditingController());
  final dnaMargin = List.generate(10, (_) => TextEditingController());
  final capexMargin = List.generate(10, (_) => TextEditingController());
  final nwcInvestmentMargin = List.generate(10, (_) => TextEditingController());
  final researchQuestion = TextEditingController(),
      researchSupport = TextEditingController(),
      researchOpposition = TextEditingController(),
      researchInvalidation = TextEditingController(),
      researchReviewDate = TextEditingController();
  final ke = TextEditingController(),
      wacc = TextEditingController(),
      terminal = TextEditingController(),
      netDebt = TextEditingController(),
      nci = TextEditingController(),
      nonOperatingAssets = TextEditingController();
  final displayedRatios = <TextEditingController, (String, double)>{};
  Map<String, dynamic>? fcfeAssumptionsCache, fcffAssumptionsCache;
  bool inspectInputs = false;
  String researchRange = '5Y', researchReport = '';
  String researchHolderId = '', holderQuery = '';
  final holderSearch = TextEditingController();
  RangeValues? researchWindow;
  Map<String, dynamic>? opportunities,
      institutional13f,
      opportunityCompany,
      opportunityEvents,
      watchComparison;
  String opportunityLens = 'holdings',
      opportunityTicker = '',
      opportunityQuarter = '',
      opportunityCutoff = '',
      opportunityError = '';
  String opportunitySearch = '', opportunityReturnDate = '';
  String discoverCollection = 'all',
      discoverManager = '',
      discoverCoverage = 'all',
      discoverSort = 'managers',
      discoverSearch = '',
      opportunityReturnPage = 'home';
  String insightQuarter = '',
      insightUniverse = 'all',
      insightAction = 'increased',
      insightPerspective = 'stocks',
      insightStockRanking = 'amount',
      insightMarketSegment = 'all',
      insightTicker = '',
      insightInvestor = '',
      insightSearch = '',
      insightError = '';
  int insightInstitutionLimit = 8;
  Timer? insightSearchTimer;
  final Map<String, Map<String, dynamic>> insightDetailCache = {};
  final Set<String> insightDetailLoading = {};
  final discoverDetailKey = GlobalKey();
  GrowthQualityRules growthQuality = const GrowthQualityRules();
  final researchHoldersKey = GlobalKey();
  bool opportunityLoading = false,
      insightLoading = false,
      opportunityDetailLoading = false,
      opportunityMobileDetail = false,
      managerDesk = false,
      homeResearchDesk = false;
  int opportunitySerial = 0, opportunityDetailSerial = 0;
  int insightSerial = 0;
  Palette get p => _GraphitePalette(widget.palette.colorBlind);
  String w(String en, String zh) => context.tr(zh, en);
  String pct(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  String money(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${currencySymbol(text(company?['currency'], 'USD'))}${number(v).toStringAsFixed(2)}';
  String op() =>
      'workflow_${DateTime.now().microsecondsSinceEpoch}_${operationSerial++}';
  @override
  void initState() {
    super.initState();
    semanticsHandle = SemanticsBinding.instance.ensureSemantics();
    page = widget.initialPage == 'hedge' ? 'strategies' : widget.initialPage;
    asOf =
        widget.initialAsOf ??
        DateTime.now().toUtc().toIso8601String().substring(0, 10);
    dateInput.text = asOf;
    ticker = widget.initialTicker;
    search.text = ticker;
    final query = widget.initialQuery ?? readBrowserQuery();
    ticker = researchEntryTicker(page, ticker, query['candidate']);
    search.text = ticker;
    opportunityLens =
        const {
          'holdings',
          'adds',
          'trims',
          'value',
          'watching',
        }.contains(query['lens'])
        ? query['lens']!
        : 'holdings';
    opportunityTicker = query['candidate'] ?? '';
    opportunityReturnDate = query['returnAsOf'] ?? '';
    opportunityReturnPage = query['returnView'] == 'discover'
        ? 'discover'
        : 'home';
    discoverCollection =
        const {
          'all',
          'new',
          'increased',
          'reduced',
          'exited',
          'adds',
          'growth',
          'revision',
          'debate',
        }.contains(query['collection'])
        ? query['collection']!
        : 'all';
    discoverManager = query['managerFilter'] ?? '';
    growthQuality = GrowthQualityRules.fromQuery(query);
    discoverCoverage =
        const {'all', 'modelled', 'missing'}.contains(query['coverage'])
        ? query['coverage']!
        : 'all';
    discoverSort =
        const {
          'managers',
          'newPositions',
          'increases',
          'reductions',
          'exits',
          'adds',
          'growth',
          'gap',
          'revision',
          'quality',
        }.contains(query['sort'])
        ? query['sort']!
        : 'managers';
    discoverSearch = query['discoverSearch'] ?? '';
    discoverSearchInput.text = discoverSearch;
    insightQuarter = query['insightQuarter'] ?? '';
    insightUniverse = query['insightScope'] == 'active' ? 'active' : 'all';
    insightAction =
        const {
          'new',
          'increased',
          'reduced',
          'exited',
        }.contains(query['insightAction'])
        ? query['insightAction']!
        : 'increased';
    insightPerspective = 'stocks';
    insightStockRanking = switch (query['insightRank']) {
      'amount' || 'netShares' => 'amount',
      'shareChange' || 'netPct' => 'shareChange',
      'institutions' || 'holders' => 'institutions',
      'sharesHeldPct' || 'shares' => 'sharesHeldPct',
      _ => 'amount',
    };
    insightMarketSegment =
        const {
          'sp500',
          'nasdaq100Proxy',
          'smallCap',
        }.contains(query['insightSegment'])
        ? query['insightSegment']!
        : 'all';
    insightInstitutionLimit = switch (query['insightLimit']) {
      '20' => 20,
      '50' => 50,
      _ => 8,
    };
    insightTicker = query['insightTicker'] ?? '';
    insightInvestor = query['insightInvestor'] ?? '';
    insightSearch = query['insightSearch'] ?? '';
    insightSearchInput.text = insightSearch;
    discoveryTab =
        const {
          'gurus',
          'managers',
          'fundamentals',
          'aiinsights',
        }.contains(query['discoverTab'])
        ? query['discoverTab']!
        : query['discoverTab'] == 'valueflow'
        ? 'aiinsights'
        : 'gurus';
    aiInsightsSelection = {
      for (final key in [
        'quarter',
        'tab',
        'metric',
        'group',
        'sector',
        'sort',
        'query',
        'selected',
        'snapshotId',
      ])
        if (query['ai_$key'] != null) key: query['ai_$key'],
      if (query['ai_window'] != null)
        'window': int.tryParse(query['ai_window']!) ?? 8,
      if (query['ai_tickers'] != null)
        'tickers': query['ai_tickers']!.split(','),
    };
    if (query['discoverTab'] == 'valueflow') {
      replaceBrowserQuery({'discoverTab': 'aiinsights'}, replaceCurrent: true);
    }
    // Guru consensus owns a compact, cacheable bootstrap payload. Loading the
    // full home dashboard here previously added an unrelated database pass to
    // first paint. Screens that consume home state still request it normally.
    if (page == 'home' ||
        page == 'research' ||
        (page == 'discover' && discoveryTab == 'gurus')) {
      unawaited(loadHome());
    }
    opportunityQuarter = query['quarter'] ?? '';
    managerDesk = query['workspace'] == 'manager';
    homeResearchDesk = managerDesk || query['workspace'] == 'research';
    if ((page == 'home' && homeResearchDesk) ||
        (page == 'discover' && discoveryTab == 'fundamentals')) {
      unawaited(loadOpportunities());
    }
    if (page == 'home' && homeResearchDesk) {
      homeGuruId = query['deskGuru'] ?? homeGuruId;
      deskFilingId = query['deskFiling'] ?? '';
      deskClaimId = query['deskClaim'] ?? '';
      deskTab = query['deskTab'] == 'position' ? 'position' : 'value';
      unawaited(loadDiscovery());
    }
    if (page == 'discover') {
      if (discoveryTab == 'gurus') unawaited(load13FInsights());
      if (text(query['guru']).isNotEmpty) {
        unawaited(
          loadGuru(
            query['guru']!,
            filingId: query['filing'],
            holdingTicker: query['holding'],
          ),
        );
      }
    }
    if (ticker.isNotEmpty && page == 'research') {
      unawaited(
        loadCompany(
          ticker,
          origin: query['origin'] ?? 'direct_research',
          initialSection: query['section'],
          evidence: query['entryGuru'] == null
              ? (query['origin'] == 'ai_insights'
                    ? {
                        'aiInsights': Map<String, dynamic>.from(
                          aiInsightsSelection,
                        ),
                      }
                    : null)
              : {
                  'guruId': query['entryGuru'],
                  'accession': query['entryFiling'],
                },
        ),
      );
    }
  }

  @override
  void dispose() {
    valuationTableScroll.dispose();
    semanticsHandle.dispose();
    calculationTimer?.cancel();
    worksheetTimer?.cancel();
    insightSearchTimer?.cancel();
    for (final c in [
      search,
      holderSearch,
      discoverSearchInput,
      insightSearchInput,
      dateInput,
      notes,
      units,
      weight,
      threshold,
      consecutive,
      scenarioName,
      reversePrice,
      targetReturn,
      reviewNotes,
      researchQuestion,
      researchSupport,
      researchOpposition,
      researchInvalidation,
      researchReviewDate,
      ke,
      wacc,
      terminal,
      netDebt,
      nci,
      nonOperatingAssets,
      ...growth,
      ...revenue,
      hypothesis,
      ...margin,
      ...ebitMargin,
      ...cashTaxRate,
      ...dnaMargin,
      ...capexMargin,
      ...nwcInvestmentMargin,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void navigate(String value) {
    setState(() {
      page = value;
      error = null;
    });
    replaceBrowserQuery({
      'view': value,
      'valuation': ticker.isEmpty ? null : ticker,
      'asOf': asOf,
      'lang': appLanguageCode(context.language),
      'section': value == 'research' ? section : null,
      'origin': value == 'research' ? discoveryOrigin : null,
      'entryGuru': value == 'research' ? text(entryEvidence?['guruId']) : null,
      'entryFiling': value == 'research'
          ? text(entryEvidence?['accession'])
          : null,
      'guru': value == 'discover'
          ? text(asMap(selectedGuru?['guru'])['id'])
          : null,
      'filing': value == 'discover' ? selectedQuarter : null,
      'holding': value == 'discover' ? selectedHolding : null,
    });
    if (value == 'home' && home == null) {
      unawaited(loadHome());
    }
    if (value == 'research' && home == null) {
      unawaited(loadHome());
    }
    if (value == 'home' &&
        homeResearchDesk &&
        discoveryData == null &&
        !discoveryLoading) {
      unawaited(loadDiscovery());
    }
    if (value == 'discover' &&
        discoveryTab == 'gurus' &&
        institutional13f == null &&
        !insightLoading) {
      unawaited(load13FInsights());
    }
    if (((value == 'home' && homeResearchDesk) ||
            (value == 'discover' && discoveryTab == 'fundamentals')) &&
        opportunities == null &&
        !opportunityLoading) {
      unawaited(loadOpportunities());
    }
    if (value == 'home' &&
        homeResearchDesk &&
        deskHolding != null &&
        homeExample == null &&
        !homeExampleLoading) {
      unawaited(loadHomeExample());
    }
    if (value == 'home' &&
        homeResearchDesk &&
        discoveryData != null &&
        homeBrief == null &&
        !homeBriefLoading) {
      unawaited(loadHomeBrief());
    }
  }

  Future<void> loadHome() async {
    final requestedAsOf = asOf;
    try {
      final data = await widget.api.getJson('/api/investment/home?asOf=$asOf');
      if (mounted && requestedAsOf == asOf) setState(() => home = data);
    } catch (e) {
      if (mounted && requestedAsOf == asOf) {
        setState(() => error = e.toString());
      }
    }
  }

  Future<void> loadCompany(
    String symbol, {
    String origin = 'direct_research',
    Map<String, dynamic>? evidence,
    String? initialSection,
  }) async {
    if (!await allowLeaveDraft() || !mounted) return;
    final serial = ++requestSerial;
    calculationSerial++;
    calculationTimer?.cancel();
    worksheetTimer?.cancel();
    setState(() {
      busy = true;
      error = null;
      company = null;
      researchFundamental = null;
      researchInstitution = null;
      researchDocumentsData = null;
      researchRecordsData = null;
      researchPanelLoading = false;
      researchPanelError = null;
      researchFinancialsLoading = false;
      researchFinancialsError = null;
      researchStatement = 'income';
      researchFinancialMetrics = ['revenue', 'netinccmn'];
      review = null;
      scenarioId = null;
      scenarioParentId = null;
      hypothesis.clear();
      ownership = false;
      calculation = null;
      valuationReference = null;
      calculationPending = false;
      calculationFailure = null;
      assumptions = {};
      personalDcfMethod = 'parent_fcfe';
      fcfeAssumptionsCache = null;
      fcffAssumptionsCache = null;
      forecastHorizon = 5;
      valuationSection = 'published';
      draftDirty = false;
      worksheetHead = null;
      worksheetRetry = null;
      worksheetFailure = null;
      worksheetSavedFingerprint = null;
      worksheetStatus = 'initial';
      researchRange = '5Y';
      researchReport = '';
      researchHolderId = '';
      holderQuery = '';
      holderSearch.clear();
      researchWindow = null;
      discoveryOrigin = origin;
      sourceGuruIds.clear();
      entryEvidence = evidence;
      final evidenceGuruId = text(evidence?['guruId']);
      if (evidenceGuruId.isNotEmpty) sourceGuruIds.add(evidenceGuruId);
      ticker = symbol.trim().toUpperCase();
      search.text = ticker;
      page = 'research';
      decisionAction = '';
      ruleEnabled = false;
      priority = false;
      units.clear();
      weight.clear();
      notes.clear();
    });
    try {
      final data = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(ticker)}?asOf=$asOf',
      );
      if (!mounted || serial != requestSerial) return;
      if (text(data['ticker']).toUpperCase() != ticker) {
        throw StateError(
          w(
            'The returned company does not match $ticker. No substitute is shown.',
            '返回的公司与 $ticker 不符，不显示替代股票。',
          ),
        );
      }
      final sourceEvidence = asMap(evidence);
      final evidenceGuruId = text(sourceEvidence['guruId']);
      if (evidenceGuruId.isNotEmpty && sourceEvidence['reportDate'] == null) {
        final detail = await widget.api.getJson(
          '/api/investment/gurus/${Uri.encodeComponent(evidenceGuruId)}?asOf=$asOf',
        );
        if (!mounted || serial != requestSerial) return;
        final filing = asList(detail['history'])
            .where((f) => f['accessionNumber'] == sourceEvidence['accession'])
            .firstOrNull;
        if (filing == null) {
          throw StateError(
            w(
              'The selected filing is not available at this cutoff.',
              '所选披露在该截止日不可用。',
            ),
          );
        }
        entryEvidence = {
          ...sourceEvidence,
          'name': asMap(detail['guru'])['name'],
          'reportDate': filing['reportDate'],
          'availableAt': filing['filingDate'],
        };
        selectedGuru = detail;
        selectedQuarter = text(filing['accessionNumber']);
        selectedHolding = symbol.toUpperCase();
      }
      setState(() {
        company = data;
        ticker = text(data['ticker']);
        researchRecentTickers.remove(ticker);
        researchRecentTickers.insert(0, ticker);
        if (researchRecentTickers.length > 6) {
          researchRecentTickers.removeLast();
        }
        search.text = ticker;
        page = 'research';
        section =
            [
              'evidence',
              'financials',
              'institutions',
              'value',
              'records',
            ].contains(initialSection)
            ? initialSection!
            : 'evidence';
        template = 'Base';
        scenarioName.text = 'Base';
        inspectInputs = false;
        assumptions = asMap(asMap(data['templates'])['Base']);
        researchFundamental = asMap(data['fundamental']).isEmpty
            ? null
            : asMap(data['fundamental']);
        researchRecordsData = {'rows': asList(data['researchRecords'])};
        worksheetHead = data['worksheetHead'] as String?;
        final saved = asList(data['scenarios']);
        final active = asMap(data['activeWorksheet']);
        final legacySaved =
            !data.containsKey('activeWorksheet') && saved.isNotEmpty;
        if ((active.isNotEmpty || legacySaved) && assumptions.isNotEmpty) {
          final latest = active.isNotEmpty ? active : saved.last;
          assumptions = asMap(latest['assumptions']);
          scenarioName.text = text(latest['name']);
          hypothesis.text = text(latest['hypothesis']);
          final same =
              asMap(latest['snapshot'])['id'] == asMap(data['snapshot'])['id'];
          final draft = latest['kind'] == 'valuation_draft';
          scenarioId = !draft && same ? text(latest['id']) : null;
          scenarioParentId = draft
              ? latest['parentId'] as String?
              : text(latest['id']);
          ownership = !draft && same;
          draftDirty = draft || !same;
          worksheetStatus = 'saved';
          if (!same) {
            notice = w(
              'Your saved assumptions are restored. Financial data or the cutoff changed; values are recalculated, not your assumptions.',
              '已恢复你的假设。财务数据或截止日有变化：仅重算结果，不改动你的假设。',
            );
          }
          template = '';
        }
        if (active.isEmpty &&
            number(data['worksheetIgnoredTestVersions']) > 0) {
          notice = w(
            'Starting forecast loaded. Older local QA scenarios remain in version history; they are not used as your defaults.',
            '已载入起始预测。旧的本地 QA 测试情景仍保留在历史版本中，不会被当成你的默认假设。',
          );
        }
        reversePrice.text = number(
          asMap(asMap(data['snapshot'])['price'])['value'],
        ).toStringAsFixed(2);
      });
      fillAssumptions();
      worksheetSavedFingerprint = worksheetFingerprint();
      navigate('research');
      // Deep links must load the same lazy panel as an in-app tab click. The
      // route already knows the requested section; leaving it empty until the
      // user clicks the active tab made refreshed Research links look as if
      // their 13F/document coverage were missing.
      if (section == 'financials' &&
          (researchDocumentsData == null || researchFundamental == null)) {
        unawaited(loadResearchPanel('financials'));
      } else if (section == 'evidence' && researchNeedsFullFinancials) {
        unawaited(loadResearchOverviewFinancials());
      } else if (section == 'institutions' && researchInstitution == null) {
        unawaited(loadResearchPanel('institutions'));
      } else if (section == 'records' && researchRecordsData == null) {
        unawaited(loadResearchPanel('records'));
      }
      if (assumptions.isNotEmpty) await recalculate();
    } catch (e) {
      if (mounted && serial == requestSerial) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial) setState(() => busy = false);
    }
  }

  void fillAssumptions() {
    personalDcfMethod = assumptions['method'] == 'operating_fcff'
        ? 'operating_fcff'
        : 'parent_fcfe';
    final storedGrowth = assumptions['growth'] as List?;
    final storedMargin = assumptions['margin'] as List?;
    forecastHorizon =
        (nullableNumber(assumptions['horizonYears']) ??
                storedGrowth?.length.toDouble() ??
                5)
            .round();
    if (forecastHorizon != 10) forecastHorizon = 5;
    for (var i = 0; i < 10; i++) {
      displayOptionalRatio(
        growth[i],
        storedGrowth != null && i < storedGrowth.length
            ? storedGrowth[i]
            : null,
      );
      displayOptionalRatio(
        margin[i],
        storedMargin != null && i < storedMargin.length
            ? storedMargin[i]
            : null,
      );
      for (final entry in [
        (ebitMargin, assumptions['ebitMargin'] as List?),
        (cashTaxRate, assumptions['cashTaxRate'] as List?),
        (dnaMargin, assumptions['dnaMargin'] as List?),
        (capexMargin, assumptions['capexMargin'] as List?),
        (nwcInvestmentMargin, assumptions['nwcInvestmentMargin'] as List?),
      ]) {
        displayOptionalRatio(
          entry.$1[i],
          entry.$2 != null && i < entry.$2!.length ? entry.$2![i] : null,
        );
      }
    }
    displayRatio(ke, number(assumptions['ke']));
    displayRatio(wacc, number(assumptions['wacc']));
    displayRatio(terminal, number(assumptions['g']));
    netDebt.text = number(assumptions['netDebtM']).toStringAsFixed(2);
    nci.text = number(assumptions['nciM']).toStringAsFixed(2);
    nonOperatingAssets.text = number(
      assumptions['nonOperatingAssetsM'],
    ).toStringAsFixed(2);
    final discount = personalDcfMethod == 'operating_fcff'
        ? number(assumptions['wacc'])
        : number(assumptions['ke']);
    targetReturn.text = (discount * 100).toStringAsFixed(2);
    if (personalDcfMethod == 'operating_fcff' &&
        !const {
          'growth',
          'mature_ebit_margin',
          'reinvestment',
        }.contains(reverseVariable)) {
      reverseVariable = 'growth';
    }
    if (personalDcfMethod == 'parent_fcfe' &&
        !const {'growth', 'terminal_margin'}.contains(reverseVariable)) {
      reverseVariable = 'growth';
    }
    syncRevenueInputs();
  }

  // Display rounding is presentation only. Untouched controls return the exact
  // original input; user edits are percentages converted once at the API boundary.
  void displayRatio(TextEditingController c, double value) {
    c.text = (value * 100).toStringAsFixed(2);
    displayedRatios[c] = (c.text, value);
  }

  void displayOptionalRatio(TextEditingController c, dynamic value) {
    final parsed = nullableNumber(value);
    if (parsed == null) {
      c.clear();
      displayedRatios.remove(c);
    } else {
      displayRatio(c, parsed);
    }
  }

  double? editedRatio(TextEditingController c) {
    final original = displayedRatios[c];
    if (original != null && original.$1 == c.text) return original.$2;
    final value = double.tryParse(c.text);
    return value == null || !value.isFinite ? null : value / 100;
  }

  double? editedAmount(TextEditingController c) {
    final value = double.tryParse(c.text.trim());
    return value != null && value.isFinite ? value : null;
  }

  Map<String, dynamic> edited() {
    final common = {
      'horizonYears': forecastHorizon,
      'growth': growth.take(forecastHorizon).map(editedRatio).toList(),
      'g': editedRatio(terminal),
    };
    if (personalDcfMethod == 'operating_fcff') {
      return {
        'method': 'operating_fcff',
        'discountType': 'WACC',
        'ownership': 'enterprise',
        'timing': 'year_end',
        ...common,
        'ebitMargin': ebitMargin
            .take(forecastHorizon)
            .map(editedRatio)
            .toList(),
        'cashTaxRate': cashTaxRate
            .take(forecastHorizon)
            .map(editedRatio)
            .toList(),
        'dnaMargin': dnaMargin.take(forecastHorizon).map(editedRatio).toList(),
        'capexMargin': capexMargin
            .take(forecastHorizon)
            .map(editedRatio)
            .toList(),
        'nwcInvestmentMargin': nwcInvestmentMargin
            .take(forecastHorizon)
            .map(editedRatio)
            .toList(),
        'wacc': editedRatio(wacc),
        'netDebtM': editedAmount(netDebt),
        'nciM': editedAmount(nci),
        'nonOperatingAssetsM': editedAmount(nonOperatingAssets),
      };
    }
    return {
      'method': 'parent_fcfe',
      'discountType': 'Ke',
      'ownership': 'parent_common',
      'timing': 'year_end',
      ...common,
      'margin': margin.take(forecastHorizon).map(editedRatio).toList(),
      'ke': editedRatio(ke),
    };
  }

  void scheduleCalculation() {
    calculationSerial++;
    setState(() {
      scenarioId = null;
      ownership = false;
      calculation = null;
      calculationPending = valuationInputProblem() == null;
      calculationFailure = null;
      draftDirty = true;
      template = 'Custom';
      notice = null;
    });
    calculationTimer?.cancel();
    calculationTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(recalculate()),
    );
    scheduleWorksheetSave();
  }

  Future<void> recalculate() async {
    final serial = ++calculationSerial;
    final problem = valuationInputProblem();
    if (problem != null) {
      if (mounted) {
        setState(() {
          calculation = null;
          calculationPending = false;
          calculationFailure = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      calculationPending = true;
      calculationFailure = null;
    });
    try {
      final result = await widget.api
          .postJson('/api/investment/calculate', {
            'ticker': ticker,
            'asOf': asOf,
            'snapshotId': asMap(company?['snapshot'])['id'],
            'assumptions': edited(),
            'reversePrice': double.tryParse(reversePrice.text),
            'reverseVariable': reverseVariable,
            'targetReturn': (double.tryParse(targetReturn.text) ?? 0) / 100,
          })
          .timeout(const Duration(seconds: 12));
      if (mounted && serial == calculationSerial) {
        setState(() {
          calculation = result;
          valuationReference ??= asMap(result['result']);
          calculationPending = false;
          calculationFailure = null;
        });
      }
    } catch (e) {
      if (mounted && serial == calculationSerial) {
        setState(() {
          calculation = null;
          calculationPending = false;
          calculationFailure = e is TimeoutException ? 'timeout' : e.toString();
        });
      }
    }
  }

  Future<void> command(Future<void> Function() run) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await run();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveScenario() => command(() async {
    if (worksheetMemoryEnabled && !await persistWorksheet()) return;
    final savedFingerprint = worksheetFingerprint();
    final contextSerial = requestSerial;
    final data = await widget.api.postJson('/api/investment/scenarios', {
      'operationId': op(),
      'ticker': ticker,
      'asOf': asOf,
      'name': scenarioName.text,
      'hypothesis': hypothesis.text,
      'assumptions': edited(),
      'snapshotId': asMap(company?['snapshot'])['id'],
      'ownershipConfirmed': ownership,
      'parentId': review == null
          ? scenarioParentId
          : asMap(review?['activeScenario'])['id'],
    });
    if (mounted && contextSerial == requestSerial) {
      setState(() {
        final unchanged = savedFingerprint == worksheetFingerprint();
        scenarioId = unchanged ? text(data['id']) : null;
        scenarioParentId = text(data['id']);
        worksheetHead = text(data['id']);
        worksheetStatus = 'saved';
        if (unchanged) worksheetSavedFingerprint = worksheetFingerprint();
        draftDirty = !unchanged;
        company?['scenarios'] = [...asList(company?['scenarios']), data];
        if (worksheetMemoryEnabled) {
          company?['activeWorksheet'] = data;
          company?['worksheetHead'] = worksheetHead;
        }
        notice = w(
          'Scenario v${data['version']} saved. Your sandbox no longer changes this version.',
          '情景 v${data['version']} 已保存，之后的试算不会修改此版本。',
        );
      });
      if (draftDirty) scheduleWorksheetSave();
    }
  });
  Future<void> saveDecision() => command(() async {
    if (scenarioId == null) {
      throw StateError(w('Save a scenario first.', '请先保存情景。'));
    }
    final data = await widget.api.postJson('/api/investment/decisions', {
      'operationId': op(),
      'ticker': ticker,
      'asOf': asOf,
      'action': decisionAction,
      'scenarioId': scenarioId,
      'units': decisionAction == 'Invest' ? double.tryParse(units.text) : 0,
      'targetWeight': decisionAction == 'Invest'
          ? (double.tryParse(weight.text) ?? -1) / 100
          : 0,
      'notes': notes.text,
      'priority': priority,
      'sourceGuruIds': sourceGuruIds.toList(),
      if (discoveryOrigin == 'ai_insights' && sourceGuruIds.isEmpty)
        'discoveryContext': asMap(entryEvidence?['aiInsights']),
      if (opportunityReturnDate.isNotEmpty && ticker == opportunityTicker)
        'candidateContext': {
          'lens':
              const {
                'holdings',
                'adds',
                'trims',
                'value',
              }.contains(opportunityLens)
              ? opportunityLens
              : 'holdings',
          'reportDate': asOf == opportunityReturnDate
              ? opportunityQuarter
              : null,
        },
      if (text(entryEvidence?['guruId']).isNotEmpty)
        'entryEvidence': {
          'guruId': entryEvidence?['guruId'],
          'accession': entryEvidence?['accession'],
        },
      'discoveryOrigin': sourceGuruIds.isNotEmpty
          ? 'guru_disclosure'
          : discoveryOrigin,
      'rules': [
        if (ruleEnabled)
          {
            'metric': ruleMetric,
            'operator': ruleOperator,
            'threshold': (double.tryParse(threshold.text) ?? double.nan) / 100,
            'consecutive': int.tryParse(consecutive.text),
            'scope': 'new_financial_periods',
            'severity': 'review',
          },
      ],
    });
    await loadHome();
    if (mounted) {
      setState(() {
        reviewId = text(data['id']);
        page = 'book';
        notice = w(
          'Decision saved permanently. No broker order was sent.',
          '决策已永久保存，未发送券商订单。',
        );
      });
      navigate('book');
    }
  });
  Future<void> openReview(String id) => command(() async {
    final data = await widget.api.getJson(
      '/api/investment/review/$id?asOf=$asOf',
    );
    if (mounted) {
      setState(() {
        review = data;
        reviewId = id;
        company = asMap(data['now']);
        ticker = text(company?['ticker']);
        reversePrice.text = number(
          asMap(asMap(company?['snapshot'])['price'])['value'],
        ).toStringAsFixed(2);
        assumptions = asMap(asMap(data['activeScenario'])['assumptions']);
        scenarioId = null;
        ownership = false;
        section = 'review';
        page = 'research';
        reviewAction = '';
        reviewOriginal = false;
        draftDirty = false;
        discoveryOrigin = text(
          asMap(asMap(data['decision'])['discoveryOrigin'])['kind'],
          'direct_research',
        );
        entryEvidence =
            asMap(asMap(data['decision'])['entryEvidence']).isNotEmpty
            ? asMap(asMap(data['decision'])['entryEvidence'])
            : asList(asMap(data['decision'])['discovery']).firstOrNull;
        if (discoveryOrigin == 'ai_insights') {
          final savedContext = asMap(
            asMap(data['decision'])['discoveryContext'],
          );
          aiInsightsSelection = {
            ...asMap(savedContext['filters']),
            'quarter': savedContext['selectedQuarter'],
            'window': savedContext['window'] ?? 8,
            'snapshotId': savedContext['snapshotId'],
            'selected':
                asMap(savedContext['filters'])['selected'] ??
                savedContext['ticker'],
            'tickers': savedContext['compareTickers'] ?? <String>[],
          };
          entryEvidence = {
            'aiInsights': Map<String, dynamic>.from(aiInsightsSelection),
          };
          discoveryTab = 'aiinsights';
        }
        sourceGuruIds.clear();
        reviewNotes.clear();
        units.text = text(data['activeUnits']);
      });
      navigate('research');
    }
    fillAssumptions();
    await recalculate();
  });
  Future<void> saveReview() => command(() async {
    await widget.api.postJson('/api/investment/reviews', {
      'operationId': op(),
      'decisionId': reviewId,
      'asOf': asOf,
      'expectedHeadId': review?['headId'],
      'action': reviewAction,
      'notes': reviewNotes.text,
      'scenarioId': reviewAction == 'Change' ? scenarioId : null,
      'units': double.tryParse(units.text),
    });
    await loadHome();
    if (mounted) {
      setState(() {
        notice = w(
          'Review recorded. Original decision is unchanged.',
          '复核已记录，原始决策保持不变。',
        );
        page = 'book';
      });
      navigate('book');
    }
  });
  Widget label(String en, String zh, {double size = 14, Color? color}) => Text(
    w(en, zh),
    style: TextStyle(fontSize: size, color: color ?? p.muted, height: 1.5),
  );
  Widget title(String en, String zh) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      w(en, zh),
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: p.text,
      ),
    ),
  );
  Widget card(List<Widget> children, {Color? border, Key? key}) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 18),
    child: Material(
      color: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: border ?? p.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
  Widget input(
    TextEditingController c,
    String en,
    String zh, {
    double width = 190,
    bool numeric = false,
    ValueChanged<String>? changed,
  }) => SizedBox(
    width: width,
    child: TextField(
      controller: c,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      onChanged: changed,
      style: TextStyle(color: p.text, fontSize: 14),
      decoration: InputDecoration(
        labelText: w(en, zh),
        border: const OutlineInputBorder(),
        isDense: true,
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
      ? FilledButton(onPressed: busy ? null : action, child: Text(w(en, zh)))
      : OutlinedButton.icon(
          onPressed: busy ? null : action,
          icon: Icon(icon ?? Icons.chevron_right, size: 16),
          label: Text(w(en, zh)),
        );
  Widget dataTable(
    List<String> columns,
    List<List<String>> rows,
  ) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      headingTextStyle: TextStyle(color: p.muted, fontWeight: FontWeight.w600),
      dataTextStyle: TextStyle(color: p.text, fontSize: 14),
      columns: columns.map((c) => DataColumn(label: Text(c))).toList(),
      rows: rows
          .map((r) => DataRow(cells: r.map((c) => DataCell(Text(c))).toList()))
          .toList(),
    ),
  );
  String metricName(String key) => switch (key) {
    'revenueGrowth' => w('Revenue YoY', '收入同比'),
    'operatingMargin' => w('Operating margin', '营业利润率'),
    'fcfMargin' => w('FCF margin', '自由现金流率'),
    'capexIntensity' => w('Capex / revenue', '资本支出 / 收入'),
    _ => key,
  };

  @override
  Widget build(BuildContext context) => graphiteBuild(context);

  void updateUI(VoidCallback change) => setState(change);

  Widget searchBox() => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      input(search, 'Company ticker', '股票代码', width: 220),
      button(
        'Open research',
        '打开研究',
        () => unawaited(loadCompany(search.text)),
        primary: true,
      ),
    ],
  );
  List<Widget> homeView() => [
    title('Know what needs your attention.', '知道什么需要你关注。'),
    label(
      'Follow the evidence. Set your assumptions. Keep a record of every decision.',
      '跟踪事实，设定假设，保留每次决策的记录。',
    ),
    const SizedBox(height: 20),
    card([
      title('Review required', '需要复核'),
      if (asList(home?['attention']).isEmpty)
        label(
          'No triggered reviews at this cutoff. Only held and priority-watched companies appear here.',
          '此截止日期没有触发复核，只检查持仓和重点观察公司。',
        ),
      for (final r in asList(home?['attention']))
        ListTile(
          title: Text('${r['ticker']} · ${r['period'] ?? ''}'),
          subtitle: Text(
            w(
              r['status'] == 'data_unavailable'
                  ? 'Data unavailable. No rule conclusion can be calculated.'
                  : 'A saved rule or original Guru disclosure changed.',
              r['status'] == 'data_unavailable'
                  ? '数据不可用，无法计算规则结论。'
                  : '保存的规则或原始大佬披露发生变化。',
            ),
          ),
          trailing: button(
            'Review',
            '复核',
            () => unawaited(openReview(text(r['decisionId']))),
          ),
        ),
    ]),
    card([
      title('Continue your research', '继续研究'),
      searchBox(),
      const SizedBox(height: 12),
      for (final d in asList(home?['decisions']).take(5))
        ListTile(
          title: Text('${d['ticker']} · ${d['decisionDate']}'),
          subtitle: Text(
            '${context.ui(text(d['action']))} · ${w('Scenario', '情景')} v${asMap(d['scenario'])['version']}',
          ),
          trailing: button(
            'Then vs Now',
            '当时与现在',
            () => unawaited(openReview(text(d['decisionId']))),
          ),
        ),
    ]),
    card([
      title('Discover with an explicit rule', '用明确规则发现公司'),
      label(
        'Quarterly revenue growth ≥ 15%, using only the latest period available at your cutoff. Alphabetical, not ranked as investment quality.',
        '仅使用截止日期前最新季度收入同比 ≥ 15% 的公司，按字母排序，不是投资质量排名。',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in asList(home?['discovery']).take(12))
            ActionChip(
              label: Text('${r['ticker']}  ${pct(r['revenueGrowth'])}'),
              onPressed: () => unawaited(
                loadCompany(text(r['ticker']), origin: 'fundamental_rule'),
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      button('Explore all matches', '查看全部匹配', () => navigate('discover')),
    ]),
    card([
      title('Your portfolio', '你的组合'),
      label(
        '${asList(asMap(home?['portfolio'])['positions']).length} research positions · CTA not connected · combined risk unavailable',
        '${asList(asMap(home?['portfolio'])['positions']).length} 个研究仓位 · CTA 未连接 · 组合风险不可用',
      ),
      button('Open portfolio', '打开组合', () => navigate('book')),
    ]),
  ];
  List<Widget> discoverView() => [
    title('A starting point. Not a recommendation.', '研究起点，不是投资建议。'),
    searchBox(),
    const SizedBox(height: 18),
    card([
      title('Fundamental discovery', '基本面发现'),
      label(
        'Latest disclosed quarter · revenue YoY ≥ 15% · ticker ascending',
        '最新已披露季度 · 收入同比 ≥ 15% · 代码升序',
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in asList(home?['discovery']))
            ActionChip(
              label: Text('${r['ticker']}  ${pct(r['revenueGrowth'])}'),
              onPressed: () => unawaited(
                loadCompany(text(r['ticker']), origin: 'fundamental_rule'),
              ),
            ),
        ],
      ),
    ]),
    card([
      title('Follow public disclosures', '关注公开披露'),
      label(
        '13F shows reported holdings, not why the manager invested. Following never adds a valuation filter to a strategy.',
        '13F 展示申报持仓，不代表投资原因。关注操作不会为策略添加估值过滤。',
      ),
      for (final g in asList(home?['gurus']))
        SwitchListTile(
          title: Text(text(g['name'])),
          value: g['followed'] == true,
          onChanged: busy
              ? null
              : (v) => unawaited(
                  command(() async {
                    await widget.api.postJson('/api/investment/follows', {
                      'operationId': op(),
                      'guruId': g['id'],
                      'followed': v,
                    });
                    await loadHome();
                  }),
                ),
        ),
    ]),
  ];
  List<Widget> researchView() => graphiteResearch();

  List<Widget> evidenceView({bool includeHistory = true}) {
    final c = company!;
    final snap = asMap(c['snapshot']);
    final price = asMap(snap['price']);
    return [
      card([
        title('What is changing?', '什么发生了变化？'),
        financialComparisonGrid(),
        label(
          'Growth is quarterly YoY; margins and capex use TTM. Historical percentile uses up to 20 prior available periods, at least 4 valid observations.',
          '增长为季度同比，利润率和资本开支为 TTM。历史分位使用最多 20 个过去可用期，至少 4 个有效样本。',
        ),
        label(
          'Peer cohort, ROIC and operating KPIs are not verified in this slice. Missing is not zero.',
          '本轮暂未验证同行样本、ROIC 和运营指标。缺失不等于零。',
        ),
      ]),
      if (includeHistory)
        card([
          title('Published valuation history', '已发布估值历史'),
          SizedBox(
            height: 260,
            child: ValuationTrendChart(
              history: [
                for (final h in asList(c['history']))
                  {
                    'asOfDate': h['availableAt'],
                    'fairValue': h['publishedFairValue'],
                  },
              ],
              priceHistory: asList(c['priceHistory']),
              currency: text(c['currency']),
              palette: p,
              selectedQuarterKey: '',
            ),
          ),
          label(
            'Mint: published blended fair value · Grey: dated price. Your FCFE sandbox below is separate.',
            '绿色：已发布综合估值；灰色：对应日期股价。下方 FCFE 试算与综合估值独立。',
          ),
          label(
            'Price ${money(price['value'])} · ${price['date']} · ${price['source']}',
            '股价 ${money(price['value'])} · ${price['date']} · ${price['source']}',
          ),
          button(
            'Set my assumptions',
            '设定我的假设',
            () => setState(() => section = 'value'),
            primary: true,
          ),
        ]),
      disclosedHoldersWorkspace(),
      card([
        ExpansionTile(
          title: Text(w('Sources, formulas and dates', '来源、公式和日期')),
          children: [
            for (final m in asList(c['metrics']))
              ListTile(
                title: Text(metricName(text(m['key']))),
                subtitle: SelectableText(
                  '${m['formula']}\n${m['source']} · ${m['availableAt']}',
                ),
              ),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(snap),
              style: TextStyle(fontSize: 11, color: p.muted),
            ),
          ],
        ),
        ExpansionTile(
          title: Text(w('Stored management guidance evidence', '已存管理层指引证据')),
          children: [
            label(
              'Evidence only. Changing the sandbox does not reinterpret or re-extract management statements.',
              '仅作为证据，修改试算不会重新解释或提取管理层表述。',
            ),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(c['guidance']),
              style: TextStyle(fontSize: 11, color: p.muted),
            ),
          ],
        ),
      ]),
    ];
  }

  List<Widget> detailedValueView() {
    if (assumptions.isEmpty) {
      return [
        if (company != null) ...opportunityValue(company!),
        const SizedBox(height: 18),
        card([
          title('Published model · read-only', '平台模型 · 只读'),
          label(
            'No supported parent FCFE route is available. We will not apply an operating-company DCF to this security.',
            '暂无受支持的母公司 FCFE 路径，不会将经营公司 DCF 强套到该证券。',
          ),
        ]),
      ];
    }
    final result = asMap(calculation?['result']),
        reverse = asMap(calculation?['reverse']);
    return [
      if (asList(company?['scenarios']).isNotEmpty)
        card([
          title('Saved scenario versions', '已保存的情景版本'),
          label(
            'Load saved assumptions. If the data cutoff changed, save a new version before making a decision.',
            '载入已保存假设。数据截止日期变更后，需保存新版本才能决策。',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final saved in asList(company?['scenarios']))
                ActionChip(
                  label: Text(
                    '${saved['name']} · v${saved['version']} · ${saved['asOf']}',
                  ),
                  onPressed: () {
                    setState(() {
                      assumptions = asMap(saved['assumptions']);
                      scenarioName.text = text(saved['name']);
                      final same =
                          asMap(saved['snapshot'])['id'] ==
                          asMap(company?['snapshot'])['id'];
                      scenarioId = same ? text(saved['id']) : null;
                      ownership = same;
                    });
                    fillAssumptions();
                    unawaited(recalculate());
                  },
                ),
            ],
          ),
        ]),
      card([
        title('What do you believe?', '你相信什么？'),
        label(
          '$forecastHorizon forward years · parent FCFE / Ke · year-end discounting · no second debt or NCI deduction. All rate inputs are percentages.',
          '未来 $forecastHorizon 年 · 母公司 FCFE / Ke · 年末折现 · 不重复扣债务或少数权益。比率输入均为百分数。',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: [
            for (final name in ['Bear', 'Base', 'Bull'])
              ChoiceChip(
                label: Text(
                  w(name, {'Bear': '悲观', 'Base': '基准', 'Bull': '乐观'}[name]!),
                ),
                selected: template == name,
                onSelected: (_) {
                  setState(() {
                    template = name;
                    scenarioName.text = name;
                    assumptions = asMap(asMap(company?['templates'])[name]);
                    scenarioId = null;
                    ownership = false;
                  });
                  fillAssumptions();
                  unawaited(recalculate());
                },
              ),
          ],
        ),
        label(
          'Base preserves the released cash-flow path before post-DCF adjustments. Bear/Bull stress growth ±5pp, margin ±3pp and Ke ∓1pp, within supported bounds. These are editable templates, not management guidance.',
          '基准保留平台现金流路径，不含 DCF 后调整。悲观/乐观在支持边界内按增长 ±5pp、现金流率 ±3pp、Ke ∓1pp 压测。这些是可编辑模板，不是管理层指引。',
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < forecastHorizon; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                input(
                  growth[i],
                  'Year ${i + 1} growth %',
                  '第 ${i + 1} 年增长 %',
                  numeric: true,
                  changed: (_) => scheduleCalculation(),
                  width: 230,
                ),
                input(
                  margin[i],
                  'Year ${i + 1} FCFE margin %',
                  '第 ${i + 1} 年 FCFE 率 %',
                  numeric: true,
                  changed: (_) => scheduleCalculation(),
                  width: 230,
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            input(
              ke,
              'Cost of equity Ke %',
              '股权资本成本 Ke %',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            input(
              terminal,
              'Terminal growth g %',
              '永续增长 g %',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '${w('Standalone FCFE value', '独立 FCFE 估值')}  ${money(result['fairValue'])}',
          style: TextStyle(
            color: p.accent,
            fontSize: 28,
            fontWeight: FontWeight.w800,
          ),
        ),
        label(
          'Published blended value: ${money(asMap(company?['published'])['fairValue'])}. Not the same model.',
          '已发布综合估值：${money(asMap(company?['published'])['fairValue'])}，两者不是同一模型。',
        ),
        ExpansionTile(
          title: Text(w('Show the math', '展开计算')),
          children: [
            dataTable(
              [w('Year', '年'), w('Revenue M', '收入 百万'), 'FCFE M', 'PV M'],
              [
                for (final r in asList(result['forecast']))
                  [
                    '${r['year']}',
                    number(r['revenueM']).toStringAsFixed(2),
                    number(r['fcfeM']).toStringAsFixed(2),
                    number(r['pvM']).toStringAsFixed(2),
                  ],
              ],
            ),
            label(
              'Terminal share ${pct(result['terminalShare'])} · TV PV ${number(result['terminalPvM']).toStringAsFixed(2)} M',
              '终值占比 ${pct(result['terminalShare'])} · 终值现值 ${number(result['terminalPvM']).toStringAsFixed(2)} 百万',
            ),
            SelectableText(text(result['formula'])),
            SelectableText(text(result['signature'])),
          ],
        ),
      ]),
      card([
        title('What must I believe?', '价格要求你相信什么？'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            input(
              reversePrice,
              'Price to explain',
              '待解释股价',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            input(
              targetReturn,
              'Required return %',
              '要求回报率 %',
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(w('Revenue growth', '收入增长')),
              selected: reverseVariable == 'growth',
              onSelected: (_) {
                setState(() => reverseVariable = 'growth');
                unawaited(recalculate());
              },
            ),
            ChoiceChip(
              label: Text(w('Terminal FCFE margin', '终值 FCFE 率')),
              selected: reverseVariable == 'terminal_margin',
              onSelected: (_) {
                setState(() => reverseVariable = 'terminal_margin');
                unawaited(recalculate());
              },
            ),
          ],
        ),
        Text(
          reverse['status'] == 'solved'
              ? pct(reverse['value'])
              : reverse['status'] == 'outside_bounds'
              ? w('No solution inside the disclosed bounds', '在规定范围内无解')
              : w(
                  'Reverse valuation unavailable — check price and required return.',
                  '反向估值不可用，请检查股价和要求回报率。',
                ),
          style: TextStyle(
            color: p.accent,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        label(
          'Growth solve fixes margins and g. Terminal-margin solve fixes growth and years 1–${forecastHorizon - 1} margins. Target return is the discount rate, not a promised return.',
          '增长求解固定现金流率和 g；终值率求解固定增长和前 ${forecastHorizon - 1} 年现金流率。要求回报率作为折现率，不是回报承诺。',
        ),
        ExpansionTile(
          title: Text(w('Sensitivity: Ke × terminal growth', '敏感性：Ke × 永续增长')),
          children: [
            dataTable(
              ['Ke', 'g', w('Value / share', '每股价值')],
              [
                for (final r in asList(calculation?['sensitivity']))
                  [pct(r['ke']), pct(r['g']), money(r['fairValue'])],
              ],
            ),
          ],
        ),
      ]),
      card([
        title('Save a version, not a moving target.', '保存版本，而非不断变化的数字。'),
        input(scenarioName, 'Scenario name', '情景名称', width: 300),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            w(
              'I have reviewed parent-common FCFE ownership. Taxes, interest, capex and working capital are already in my FCFE margin.',
              '我已检查母公司普通股的 FCFE 归属，现金流率已包含税、利息、资本支出和营运资本。',
            ),
          ),
          value: ownership,
          onChanged: (v) => setState(() => ownership = v ?? false),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            button(
              'Save scenario version',
              '保存情景版本',
              ownership && calculation != null
                  ? () => unawaited(saveScenario())
                  : null,
              primary: true,
            ),
            button(
              'Continue to decision',
              '继续决策',
              scenarioId == null
                  ? null
                  : () => setState(() => section = 'decision'),
            ),
          ],
        ),
      ]),
    ];
  }

  List<Widget> decisionView() => [
    card([
      title('Your decision. Your record.', '你的决策，你的记录。'),
      label(
        'Select a saved scenario before recording a decision. An Invest record creates a research position, not a broker trade.',
        '记录决策前请保存情景。Invest 创建研究仓位，不发送券商订单。',
      ),
      if (scenarioId == null)
        button(
          'Save a scenario first',
          '先保存情景',
          () => setState(() => section = 'value'),
        ),
      Wrap(
        spacing: 8,
        children: [
          for (final action in ['Watch', 'Pass', 'Invest'])
            ChoiceChip(
              label: Text(
                w(
                  action,
                  {'Watch': '观察', 'Pass': '放弃', 'Invest': '投资'}[action]!,
                ),
              ),
              selected: decisionAction == action,
              onSelected: (_) => setState(() => decisionAction = action),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (decisionAction == 'Invest')
            input(units, 'Research units', '研究仓位股数', numeric: true),
          input(weight, 'Target portfolio weight %', '目标组合权重 %', numeric: true),
        ],
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          w('Priority watch: include in Home monitoring', '重点观察：加入首页监测'),
        ),
        value: priority,
        onChanged: (v) => setState(() => priority = v ?? false),
      ),
      TextField(
        controller: notes,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: w('My rationale / what could go wrong', '我的理由 / 可能出错的地方'),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 18),
      title('Set a review rule', '设定复核规则'),
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
              onSelected: (_) => setState(() => ruleMetric = m),
            ),
        ],
      ),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          ChoiceChip(
            label: Text(w('Below', '低于')),
            selected: ruleOperator == 'lt',
            onSelected: (_) => setState(() => ruleOperator = 'lt'),
          ),
          ChoiceChip(
            label: Text(w('Above', '高于')),
            selected: ruleOperator == 'gt',
            onSelected: (_) => setState(() => ruleOperator = 'gt'),
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
        'Applies only to newly available financial periods. Missing observations cannot trigger or satisfy the rule. Severity: review; no automatic trade.',
        '仅针对新可用财务期，缺失值不能触发或满足规则。级别：复核，不自动交易。',
      ),
      const SizedBox(height: 16),
      button(
        'Record decision snapshot',
        '记录决策快照',
        scenarioId == null ? null : () => unawaited(saveDecision()),
        primary: true,
      ),
    ]),
  ];
  List<Widget> reviewView() {
    if (review == null) return [];
    final d = asMap(review?['decision']),
        now = asMap(asMap(review?['now'])['snapshot']);
    return [
      card([
        title('Then vs Now', '当时与现在'),
        label(
          'Original: ${d['decisionDate']} · Now: ${now['availableAt']} · ${now['period']}',
          '原始决策：${d['decisionDate']} · 现在：${now['availableAt']} · ${now['period']}',
        ),
        dataTable(
          [w('Metric', '指标'), w('Then', '当时'), w('Now', '现在')],
          [
            for (final r in asList(review?['delta']))
              [metricName(text(r['metric'])), pct(r['then']), pct(r['now'])],
          ],
        ),
        label(
          'Original scenario value: ${money(review?['thenValue'])}',
          '原始情景价值：${money(review?['thenValue'])}',
        ),
        label(
          'Recalculation uses your last confirmed scenario v${asMap(review?['activeScenario'])['version']}, saved for ${asMap(review?['activeScenario'])['asOf']}.',
          '以下重算使用最后确认的情景 v${asMap(review?['activeScenario'])['version']}，对应 ${asMap(review?['activeScenario'])['asOf']}。',
        ),
        Text(
          '${w('New actuals, unchanged assumptions', '新实际数据、原假设不变')}  ${money(asMap(review?['sameAssumptions'])['fairValue'])}',
          style: TextStyle(
            color: p.accent,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        for (final r in asList(review?['triggers']))
          ListTile(
            leading: Icon(
              r['status'] == 'review_required'
                  ? Icons.flag_outlined
                  : Icons.fact_check_outlined,
              color: r['status'] == 'review_required' ? p.secondary : p.muted,
            ),
            title: Text(
              '${metricName(text(asMap(r['rule'])['metric']))} ${asMap(r['rule'])['operator'] == 'lt' ? '<' : '>'} ${pct(asMap(r['rule'])['threshold'])}',
            ),
            subtitle: Text(
              w(
                '${r['status']} · ${asMap(r['rule'])['consecutive']} new periods',
                '${r['status'] == 'review_required'
                    ? '需要复核'
                    : r['status'] == 'not_triggered'
                    ? '未触发'
                    : '数据不足'} · ${asMap(r['rule'])['consecutive']} 个新报告期',
              ),
            ),
          ),
        if (asList(review?['guruChanges']).isNotEmpty)
          label(
            'An original discovery Guru reported fewer shares. Corporate-action comparability still needs review; no inferred intent.',
            '原始发现来源的大佬申报股数减少，仍需检查公司行动可比性，不推断动机。',
            color: p.secondary,
          ),
        ExpansionTile(
          title: Text(w('Evidence and immutable original', '证据及不可变原始记录')),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert({
                'original': d,
                'triggers': review?['triggers'],
                'guruChanges': review?['guruChanges'],
              }),
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
          ],
        ),
        ExpansionTile(
          title: Text(w('Saved review history', '已保存的复核历史')),
          children: [
            for (final r in asList(review?['reviewHistory']))
              ExpansionTile(
                title: Text(
                  '${r['asOf']} · ${context.ui(text(r['action']))} · v${asMap(r['scenario'])['version']}',
                ),
                subtitle: Text(text(r['notes'])),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(r),
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
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
            for (final a in ['Maintain', 'Change', 'Add', 'Reduce', 'Exit'])
              ChoiceChip(
                label: Text(
                  w(
                    a,
                    {
                      'Maintain': '维持',
                      'Change': '修改假设',
                      'Add': '加仓',
                      'Reduce': '减仓',
                      'Exit': '退出',
                    }[a]!,
                  ),
                ),
                selected: reviewAction == a,
                onSelected: (_) => setState(() => reviewAction = a),
              ),
          ],
        ),
        if (reviewAction == 'Change') ...[
          label(
            'Edit and save a new scenario version, then return here. The old forecast will remain intact.',
            '编辑并保存新情景后返回此处，旧预测保持不变。',
          ),
          button(
            'Edit scenario',
            '编辑情景',
            () => setState(() => section = 'value'),
          ),
        ],
        if (reviewAction == 'Add' || reviewAction == 'Reduce')
          input(units, 'New total research units', '新的研究总股数', numeric: true),
        const SizedBox(height: 12),
        TextField(
          controller: reviewNotes,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: w('Why maintain or change?', '为什么维持或改变？'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        button(
          'Save review snapshot',
          '保存复核快照',
          reviewAction == 'Change' && scenarioId == null
              ? null
              : () => unawaited(saveReview()),
          primary: true,
        ),
        label(
          'Maintain records a review without changing forecasts. No action here submits a broker order.',
          '维持会保存复核记录，不更改预测。此处操作均不向券商下单。',
        ),
      ]),
    ];
  }

  List<Widget> portfolioView() {
    final book = asMap(home?['portfolio']);
    return [
      title('A portfolio of decisions.', '由决策组成的组合。'),
      card([
        title('Fundamental research book', '基本面研究组合'),
        label(
          'Separate from your connected brokerage account. No execution or corporate-action reconciliation yet.',
          '独立于已连接券商账户，尚未进行成交或公司行动对账。',
        ),
        if (asList(book['positions']).isEmpty)
          label(
            'No research positions yet. Start with a company and save an Invest decision.',
            '暂无研究仓位，打开公司并保存 Invest 决策开始。',
          ),
        for (final r in asList(book['positions']))
          ListTile(
            leading: StockLogo(ticker: text(r['ticker']), palette: p),
            title: Text('${r['ticker']} · ${r['units']} ${w('units', '股')}'),
            subtitle: Text(
              '${r['currency']} ${nullableNumber(r['marketValue'])?.toStringAsFixed(2) ?? '—'} · ${pct(r['weight'])}',
            ),
            trailing: button(
              'Review',
              '复核',
              () => unawaited(openReview(text(r['decisionId']))),
            ),
          ),
      ]),
      card([
        title('Watch / pass / decision journal', '观察 / 放弃 / 决策记录'),
        for (final r in asList(home?['decisions']))
          ListTile(
            title: Text('${r['ticker']} · ${r['decisionDate']}'),
            subtitle: Text(
              '${r['action']} · ${w('Scenario', '情景')} v${asMap(r['scenario'])['version']}',
            ),
            trailing: button(
              'Then vs Now',
              '当时与现在',
              () => unawaited(openReview(text(r['decisionId']))),
            ),
          ),
      ]),
      card([
        title('Fundamental vs Guru Shadow', '基本面组合与大佬影子组合'),
        label(
          'Overlap is a comparison, not a recommendation to eliminate differences. Incomplete selected books do not generate substitute weights.',
          '重合用于对照，不建议消除差异。选股集合不完整时不会生成替代权重。',
        ),
        if (asList(book['overlap']).isEmpty)
          label(
            'Comparison unavailable: no complete common-currency pair of books.',
            '对比暂不可用：缺少完整且币种可比的两个组合。',
          ),
        dataTable(
          [
            w('Ticker', '代码'),
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
      ]),
      card([
        title('CTA · separate risk sleeve', 'CTA · 独立风险模块'),
        label(
          'No verified CTA engine or aligned NAV series is connected. Allocation, correlation, combined drawdown and diversification benefit are unavailable—not zero.',
          '尚未连接已验证 CTA 引擎或对齐净值序列。配置、相关性、组合回撤和分散效果不可用，不是零。',
        ),
      ]),
    ];
  }

  List<Widget> strategyView() {
    final shadow = asMap(asMap(home?['portfolio'])['shadow']);
    return [
      title('Rules before results.', '规则先于结果。'),
      card([
        title('Guru Top 3 · disclosure preview', '大佬 Top 3 · 披露预览'),
        label(
          'Each manager’s common-long Top 3, duplicate securities combined, equal weights. No DCF filter. New rule versions never rewrite the original audited strategy.',
          '每位经理普通股多头前 3 名，合并重复证券后等权，不设 DCF 过滤。新规则版本不会改写原已审计策略。',
        ),
        label(
          'This preview has no execution or return claim. Existing backtests remain in the terminal.',
          '本预览不代表可执行仓位或收益，已有回测保留在原终端。',
        ),
        if (asList(shadow['issues']).isNotEmpty)
          label(
            'Selected book incomplete. Missing identities or filings are shown below; no reconstructed performance is displayed.',
            '所选持仓不完整，下方列出缺失身份或申报，不展示拼造收益。',
            color: p.secondary,
          ),
        ExpansionTile(
          title: Text(w('Rules and disclosure evidence', '规则与披露证据')),
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(shadow),
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
          ],
        ),
        button(
          'Save Top 3 rule version',
          '保存 Top 3 规则版本',
          () => unawaited(
            command(() async {
              await widget.api.postJson('/api/investment/strategies', {
                'operationId': op(),
                'asOf': asOf,
                'managers': [
                  'gavin-baker',
                  'bill-ackman',
                  'stanley-druckenmiller',
                ],
                'topN': 3,
              });
              await loadHome();
              notice = w(
                'Strategy version saved. Existing backtest unchanged.',
                '策略版本已保存，原回测未修改。',
              );
            }),
          ),
          primary: true,
        ),
        button(
          'Open the new research workspace',
          '打开新版研究工作台',
          () => navigate('discover'),
        ),
      ]),
    ];
  }
}
