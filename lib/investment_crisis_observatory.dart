part of 'main.dart';

class CrisisObservatoryPanel extends StatefulWidget {
  const CrisisObservatoryPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    this.initialSelection = const {},
    this.onSelection,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;

  @override
  State<CrisisObservatoryPanel> createState() => _CrisisObservatoryPanelState();
}

class _CrisisObservatoryPanelState extends State<CrisisObservatoryPanel> {
  // Calm institutional Dark-Obsidian semantic accents; everything else uses native Palette tokens.
  static const Color _emerald = Color(0xFF5EC49E);
  static const Color _amber = Color(0xFFE5B45B);
  static const Color _coral = Color(0xFFE47F8B);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _lilac = Color(0xFFB8A1EA);

  static const List<String> _primaryStrategies = [
    'M7G_Graded',
    'Core3_Adaptive',
    'M7_Ensemble',
    'U1_PureOptions',
    'B1c_PureAD',
    'D2_SixLights',
    'NoPut_CallOnly',
  ];

  static const List<String> _fillModeIds = ['ibkr_limit', 'ask_bid'];

  static const List<String> _putOtmIds = ['otm15', 'otm20'];

  static const List<String> _m7TpModeIds = ['standard', 'itm_tp'];

  static const List<String> _rollModeIds = [
    'adaptive_120_90',
    '120d_roll50',
    '90d_hold',
  ];

  static const List<String> _tpModeIds = [
    'layered_itm',
    'standard_dual',
    'both_4x',
  ];

  static const List<String> _ccModeIds = [
    'cc_off',
    'cc_d12_d35',
    'cc_d12_r45',
    'cc_d12_cr55',
  ];

  static const List<String> _spModeIds = [
    'sp_off',
    'sp_14d_cap10',
    'sp_10d_vixf',
    'sp_14d_unf',
  ];

  static const List<String> _wcModeIds = [
    'wc_reclaim_30d_d35',
    'wc_30d_c5s5',
    'wc_14d_c0s2',
  ];

  static const Map<String, String> _strategyNavKeys = {
    'M7G_Graded': 'nav_m7g',
    'Core3_Adaptive': 'nav_c3',
    'M7_Ensemble': 'nav_m7',
    'U1_PureOptions': 'nav_u1',
    'B1c_PureAD': 'nav_b1c',
    'D2_SixLights': 'nav_d2',
    'H2_G4_PriceGate': 'nav_h2',
    'NoPut_CallOnly': 'nav_cc',
    'BH_Pure_QQQ': 'nav_bh',
  };

  Map<String, dynamic>? data;
  final Map<String, Map<String, dynamic>> _tpModeCache = {};
  final TextEditingController _qqqSharesCtrl = TextEditingController(
    text: '1000',
  );
  double customQqqShares = 1000.0;
  bool loading = true;
  bool switchingTpMode = false;
  String? error;

  String selectedProfile = 'full_m7_adaptive';
  String selectedStrategyId = 'M7G_Graded';
  String selectedFillMode = 'ibkr_limit';
  String selectedPutOtm = 'otm15';
  String selectedM7TpMode = 'standard';
  String selectedRollMode = 'adaptive_120_90';
  bool selectedM0Enabled = true;
  String selectedTpMode = 'layered_itm';
  String selectedCcMode = 'cc_off';
  String selectedSpMode = 'sp_off';
  String selectedWcMode = 'wc_reclaim_30d_d35';
  String selectedWindowId = 'ALL';
  String activeForensicWindowId = '2026-08_11_LIVE';
  bool useLogScale = true;
  bool showRulesDisclosure = false;
  bool showSignalSubTrack = true;
  bool showFullLedger = false;
  bool showCcLedger = false;
  bool showSpLedger = false;
  bool showEngineAttribution = true;
  final Set<int> expandedTrancheIds = <int>{};
  int hoverIndex = -1;
  int loadSerial = 0;

  // Point-in-Time (PIT) historical replay state (click any point on curve)
  String? pinnedPitDate;
  Map<String, dynamic>? pinnedPitRow;
  Map<String, dynamic>? pitSnapshot;
  bool loadingPit = false;
  int pitSerial = 0;
  final Map<String, Map<String, dynamic>> _pitSnapshotCache = {};
  final GlobalKey _threePillarsAnchorKey = GlobalKey();

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  bool get _isCore3 => selectedStrategyId == 'Core3_Adaptive';
  bool get _isM7Strategy =>
      selectedStrategyId == 'M7G_Graded' ||
      selectedStrategyId == 'Core3_Adaptive' ||
      selectedStrategyId == 'M7_Ensemble';
  bool get _isLegacyStrategy =>
      selectedStrategyId == 'U1_PureOptions' ||
      selectedStrategyId == 'B1c_PureAD' ||
      selectedStrategyId == 'D2_SixLights' ||
      selectedStrategyId == 'H2_G4_PriceGate';

  String _normalizeProfile(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'core3_adaptive' || v == 'core3' || v == 'core3_minimal') {
      return 'core3_adaptive';
    }
    return 'full_m7_adaptive';
  }

  String _normalizeStrategyId(String raw) {
    final mapped = switch (raw) {
      'm7g' || 'm7_graded' || 'M7G' || 'full_m7_adaptive' => 'M7G_Graded',
      'core3' ||
      'core3_adaptive' ||
      'core3_minimal' ||
      'Core3' =>
        'Core3_Adaptive',
      'm7' || 'm7_ensemble' || 'M7' => 'M7_Ensemble',
      'U4_DualEngine' => 'U1_PureOptions',
      '' || 'BH_Pure_QQQ' => 'M7G_Graded',
      _ => raw,
    };
    return _strategyNavKeys.containsKey(mapped) ? mapped : 'M7G_Graded';
  }

  String _normalizeFillMode(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'ask_bid' ||
        v == 'askbid' ||
        v == 'strict' ||
        v == 'conservative') {
      return 'ask_bid';
    }
    return 'ibkr_limit';
  }

  String _normalizePutOtm(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'otm20' || v == '20' || v == '-20' || v == '-20%') return 'otm20';
    return 'otm15';
  }

  String _normalizeM7TpMode(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'itm_tp' || v == 'itm' || v == 'deep_itm') return 'itm_tp';
    return 'standard';
  }

  String _normalizeRollMode(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == '90d_hold' || v == '90d' || v == 'hold') {
      return '90d_hold';
    }
    if (v == '120d_roll50' || v == '120d' || v == 'roll50') {
      return '120d_roll50';
    }
    return 'adaptive_120_90';
  }

  bool _normalizeM0Enabled(dynamic raw) {
    if (raw is bool) return raw;
    final v = text(raw).trim().toLowerCase();
    if (v == 'false' || v == '0' || v == 'off' || v == 'no') return false;
    return true;
  }

  String _normalizeTpMode(String raw) {
    return _tpModeIds.contains(raw) ? raw : 'layered_itm';
  }

  String _normalizeCcMode(String raw) {
    final mapped = switch (raw) {
      'cc_high_vol' || 'cc_hv_8' || 'cc_hv_9' || 'cc_d12_3x' => 'cc_d12_d35',
      'cc_always' || 'cc_always_8' || 'cc_otm8_3x' => 'cc_d12_r45',
      _ => raw,
    };
    return _ccModeIds.contains(mapped) ? mapped : 'cc_off';
  }

  String _normalizeSpMode(String raw) {
    final mapped = switch (raw) {
      'off' || 'none' => 'sp_off',
      'sp_cap10' || 'cap10' || '14d_cap10' => 'sp_14d_cap10',
      'sp_vixf' || 'vix_falling' || '10d_vixf' => 'sp_10d_vixf',
      'sp_unf' || 'unfiltered' || '14d_unf' => 'sp_14d_unf',
      _ => raw,
    };
    return _spModeIds.contains(mapped) ? mapped : 'sp_off';
  }

  String _normalizeWcMode(String raw) {
    final mapped = switch (raw) {
      'reclaim' || 'd35' || 'reclaim_30d_d35' || 'rec' || 'default' =>
        'wc_reclaim_30d_d35',
      '30d' || '30d_c5s5' || 'c5s5' => 'wc_30d_c5s5',
      '14d' || '14d_c0s2' || 'c0s2' || 'legacy' || 'breakeven' => 'wc_14d_c0s2',
      _ => raw,
    };
    return _wcModeIds.contains(mapped) ? mapped : 'wc_reclaim_30d_d35';
  }

  @override
  void initState() {
    super.initState();
    final rawProfile = text(
      widget.initialSelection['profile'] ??
          widget.initialSelection['co_profile'],
    );
    final rawStrategy = text(
      widget.initialSelection['strategy'] ?? widget.initialSelection['strat'],
    );
    if (rawProfile.isNotEmpty) {
      selectedProfile = _normalizeProfile(rawProfile);
      selectedStrategyId = selectedProfile == 'core3_adaptive'
          ? 'Core3_Adaptive'
          : (rawStrategy.isNotEmpty
                ? _normalizeStrategyId(rawStrategy)
                : 'M7G_Graded');
      if (selectedProfile == 'full_m7_adaptive' &&
          selectedStrategyId == 'Core3_Adaptive') {
        selectedStrategyId = 'M7G_Graded';
      }
    } else {
      selectedStrategyId = _normalizeStrategyId(rawStrategy);
      selectedProfile = selectedStrategyId == 'Core3_Adaptive'
          ? 'core3_adaptive'
          : 'full_m7_adaptive';
    }
    selectedFillMode = _normalizeFillMode(
      text(
        widget.initialSelection['fillMode'] ??
            widget.initialSelection['co_fillMode'] ??
            widget.initialSelection['fill'],
      ),
    );
    selectedPutOtm = _normalizePutOtm(
      text(widget.initialSelection['putOtm'] ?? widget.initialSelection['otm']),
    );
    selectedM7TpMode = _normalizeM7TpMode(
      text(
        widget.initialSelection['m7TpMode'] ?? widget.initialSelection['m7Tp'],
      ),
    );
    final parsedRoll = _normalizeRollMode(
      text(widget.initialSelection['rollMode']),
    );
    // Safety Guardrail: Core-3 Minimal strictly locks to optimal Adaptive 120/90 Roll (never 90D Hold)
    selectedRollMode = _isCore3 ? 'adaptive_120_90' : parsedRoll;
    selectedM0Enabled = _isCore3
        ? true
        : _normalizeM0Enabled(
            widget.initialSelection['m0Enabled'] ??
                widget.initialSelection['m0'],
          );
    selectedTpMode = _normalizeTpMode(
      text(widget.initialSelection['tpMode']),
    );
    selectedCcMode = _normalizeCcMode(
      text(widget.initialSelection['ccMode']),
    );
    selectedSpMode = _normalizeSpMode(
      text(widget.initialSelection['spMode']),
    );
    selectedWcMode = _normalizeWcMode(
      text(widget.initialSelection['wcMode']),
    );
    final initWin = text(
      widget.initialSelection['window'] ?? widget.initialSelection['win'],
    );
    if (initWin.isNotEmpty) {
      selectedWindowId = initWin;
      if (initWin != 'ALL' && initWin != '1Y' && initWin != '3Y') {
        activeForensicWindowId = initWin;
      }
    }
    unawaited(_loadObservatory());
  }

  @override
  void dispose() {
    _qqqSharesCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CrisisObservatoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      _tpModeCache.clear();
      unawaited(_loadObservatory());
    }
  }

  void _emitSelection() {
    widget.onSelection?.call({
      'profile': selectedProfile,
      'strategy': selectedStrategyId,
      'fillMode': selectedFillMode,
      'window': selectedWindowId,
      'putOtm': selectedPutOtm,
      'm7TpMode': selectedM7TpMode,
      'rollMode': selectedRollMode,
      'm0Enabled': selectedM0Enabled ? 'true' : 'false',
      'tpMode': selectedTpMode,
      'ccMode': selectedCcMode,
      'spMode': selectedSpMode,
      if (selectedSpMode != 'sp_off') 'wcMode': selectedWcMode,
    });
  }

  void _selectProfile(String profileId) {
    final norm = _normalizeProfile(profileId);
    final nextStrat = norm == 'core3_adaptive' ? 'Core3_Adaptive' : 'M7G_Graded';
    final nextRoll = norm == 'core3_adaptive'
        ? 'adaptive_120_90'
        : selectedRollMode;
    final nextM0 = norm == 'core3_adaptive' ? true : selectedM0Enabled;
    if (selectedProfile == norm &&
        selectedStrategyId == nextStrat &&
        selectedRollMode == nextRoll &&
        selectedM0Enabled == nextM0) {
      return;
    }
    setState(() {
      selectedProfile = norm;
      selectedStrategyId = nextStrat;
      hoverIndex = -1;
      expandedTrancheIds.clear();
    });
    if (nextRoll != selectedRollMode || nextM0 != selectedM0Enabled) {
      _selectModes(rollMode: nextRoll, m0Enabled: nextM0);
    } else {
      _emitSelection();
      if (pinnedPitDate != null) {
        unawaited(_loadPitSnapshot(pinnedPitDate!));
      }
    }
  }

  void _selectModes({
    String? fillMode,
    String? putOtm,
    String? m7TpMode,
    String? rollMode,
    bool? m0Enabled,
    String? tpMode,
    String? ccMode,
    String? spMode,
    String? wcMode,
  }) {
    final nextFill = fillMode != null
        ? _normalizeFillMode(fillMode)
        : selectedFillMode;
    final nextOtm = putOtm != null ? _normalizePutOtm(putOtm) : selectedPutOtm;
    final nextM7Tp = m7TpMode != null
        ? _normalizeM7TpMode(m7TpMode)
        : selectedM7TpMode;
    final rawRoll = rollMode != null
        ? _normalizeRollMode(rollMode)
        : selectedRollMode;
    final nextRoll = _isCore3 ? 'adaptive_120_90' : rawRoll;
    final nextM0 = _isCore3 ? true : (m0Enabled ?? selectedM0Enabled);
    final nextTp = tpMode != null ? _normalizeTpMode(tpMode) : selectedTpMode;
    final nextCc = ccMode != null ? _normalizeCcMode(ccMode) : selectedCcMode;
    final nextSp = spMode != null ? _normalizeSpMode(spMode) : selectedSpMode;
    final nextWc = wcMode != null ? _normalizeWcMode(wcMode) : selectedWcMode;
    if (nextFill == selectedFillMode &&
        nextOtm == selectedPutOtm &&
        nextM7Tp == selectedM7TpMode &&
        nextRoll == selectedRollMode &&
        nextM0 == selectedM0Enabled &&
        nextTp == selectedTpMode &&
        nextCc == selectedCcMode &&
        nextSp == selectedSpMode &&
        nextWc == selectedWcMode &&
        data != null) {
      return;
    }
    final effectiveWc = nextSp == 'sp_off' ? 'wc_reclaim_30d_d35' : nextWc;
    final cacheKey =
        '${widget.asOf}::$nextFill::$nextOtm::$nextM7Tp::$nextRoll::$nextM0::$nextTp::$nextCc::$nextSp::$effectiveWc';
    final cached = _tpModeCache[cacheKey];
    if (cached != null) {
      setState(() {
        selectedFillMode = nextFill;
        selectedPutOtm = nextOtm;
        selectedM7TpMode = nextM7Tp;
        selectedRollMode = nextRoll;
        selectedM0Enabled = nextM0;
        selectedTpMode = nextTp;
        selectedCcMode = nextCc;
        selectedSpMode = nextSp;
        selectedWcMode = nextWc;
        data = cached;
        hoverIndex = -1;
        switchingTpMode = false;
      });
      _emitSelection();
      if (pinnedPitDate != null) {
        unawaited(_loadPitSnapshot(pinnedPitDate!));
      }
      return;
    }
    setState(() {
      selectedFillMode = nextFill;
      selectedPutOtm = nextOtm;
      selectedM7TpMode = nextM7Tp;
      selectedRollMode = nextRoll;
      selectedM0Enabled = nextM0;
      selectedTpMode = nextTp;
      selectedCcMode = nextCc;
      selectedSpMode = nextSp;
      selectedWcMode = nextWc;
      switchingTpMode = data != null;
      hoverIndex = -1;
    });
    _emitSelection();
    unawaited(_loadObservatory(isModeSwitch: data != null));
    if (pinnedPitDate != null) {
      unawaited(_loadPitSnapshot(pinnedPitDate!));
    }
  }

  void _selectFillMode(String modeId) => _selectModes(fillMode: modeId);

  void _selectPutOtm(String modeId) => _selectModes(putOtm: modeId);

  void _selectM7TpMode(String modeId) => _selectModes(m7TpMode: modeId);

  void _selectRollMode(String modeId) {
    if (_isCore3) return;
    _selectModes(rollMode: modeId);
  }

  void _toggleM0Enabled() {
    if (_isCore3) return;
    _selectModes(m0Enabled: !selectedM0Enabled);
  }

  void _selectTpMode(String modeId) => _selectModes(tpMode: modeId);

  void _selectCcMode(String modeId) => _selectModes(ccMode: modeId);

  void _selectSpMode(String modeId) => _selectModes(spMode: modeId);

  void _selectWcMode(String modeId) => _selectModes(wcMode: modeId);

  void _switchToFlagshipM7g() {
    setState(() {
      selectedProfile = 'full_m7_adaptive';
      selectedStrategyId = 'M7G_Graded';
      hoverIndex = -1;
    });
    _emitSelection();
    _selectModes(
      putOtm: 'otm15',
      m7TpMode: 'standard',
      rollMode: 'adaptive_120_90',
      m0Enabled: true,
    );
  }

  Future<void> _loadObservatory({bool isModeSwitch = false}) async {
    final serial = ++loadSerial;
    final targetProfile = selectedProfile;
    final targetFill = selectedFillMode;
    final targetOtm = selectedPutOtm;
    final targetM7Tp = selectedM7TpMode;
    final targetRoll = _isCore3 ? 'adaptive_120_90' : selectedRollMode;
    final targetM0 = _isCore3 ? true : selectedM0Enabled;
    final targetTp = selectedTpMode;
    final targetCc = selectedCcMode;
    final targetSp = selectedSpMode;
    final targetWc = selectedWcMode;
    final effectiveWc = targetSp == 'sp_off' ? 'wc_reclaim_30d_d35' : targetWc;
    setState(() {
      if (!isModeSwitch) {
        loading = true;
      } else {
        switchingTpMode = true;
      }
      error = null;
    });
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory',
        queryParameters: {
          'asOf': widget.asOf,
          'profile': targetProfile,
          'strategy': selectedStrategyId,
          'fillMode': targetFill,
          'putOtm': targetOtm,
          'm7TpMode': targetM7Tp,
          'rollMode': targetRoll,
          'm0Enabled': targetM0 ? 'true' : 'false',
          'tpMode': targetTp,
          'ccMode': targetCc,
          'spMode': targetSp,
          if (targetSp != 'sp_off') 'wcMode': targetWc,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      _tpModeCache['${widget.asOf}::$targetFill::$targetOtm::$targetM7Tp::$targetRoll::$targetM0::$targetTp::$targetCc::$targetSp::$effectiveWc'] =
          res;
      final windows = asList(res['crisis_windows']);
      var nextForensic = activeForensicWindowId;
      if (windows.isNotEmpty &&
          !windows.any((item) => text(item['id']) == nextForensic)) {
        nextForensic = text(windows.last['id']);
      }
      var nextWindow = selectedWindowId;
      if (nextWindow != 'ALL' &&
          nextWindow != '1Y' &&
          nextWindow != '3Y' &&
          !windows.any((item) => text(item['id']) == nextWindow)) {
        nextWindow = 'ALL';
      }
      setState(() {
        data = res;
        activeForensicWindowId = nextForensic;
        selectedWindowId = nextWindow;
        hoverIndex = -1;
        loading = false;
        switchingTpMode = false;
      });
    } catch (e) {
      if (!mounted || serial != loadSerial) return;
      setState(() {
        error = e.toString();
        loading = false;
        switchingTpMode = false;
      });
    }
  }

  String _pitCacheKeyFor(String date) {
    final effectiveWc = selectedSpMode == 'sp_off'
        ? 'wc_reclaim_30d_d35'
        : selectedWcMode;
    return '$date::$selectedProfile::$selectedStrategyId::$selectedFillMode::$selectedPutOtm::$selectedM7TpMode::$selectedRollMode::$selectedM0Enabled::$selectedTpMode::$selectedCcMode::$selectedSpMode::$effectiveWc';
  }

  Map<String, dynamic>? _findDailyBarByDate(String date) {
    final daily = asList(data?['daily_series']);
    for (final row in daily) {
      if (text(row['date']) == date) return row;
    }
    return null;
  }

  void _selectPitDate(String date, {Map<String, dynamic>? barRow}) {
    final cleanDate = date.trim();
    if (cleanDate.isEmpty) return;
    final latestDate = text(data?['as_of_date']);
    if (latestDate.isNotEmpty && cleanDate == latestDate) {
      _clearPitSelection();
      return;
    }
    final resolvedBar = barRow ?? _findDailyBarByDate(cleanDate);
    final cacheKey = _pitCacheKeyFor(cleanDate);
    final cached = _pitSnapshotCache[cacheKey];
    if (cached != null) {
      setState(() {
        pinnedPitDate = cleanDate;
        pinnedPitRow = resolvedBar;
        pitSnapshot = cached;
        loadingPit = false;
      });
      return;
    }
    setState(() {
      pinnedPitDate = cleanDate;
      pinnedPitRow = resolvedBar;
      loadingPit = true;
    });
    unawaited(_loadPitSnapshot(cleanDate));
  }

  void _clearPitSelection() {
    pitSerial++;
    setState(() {
      pinnedPitDate = null;
      pinnedPitRow = null;
      pitSnapshot = null;
      loadingPit = false;
    });
  }

  void _stepPitDate(int delta) {
    final daily = asList(data?['daily_series']);
    if (daily.isEmpty || pinnedPitDate == null) return;
    final idx = daily.indexWhere((r) => text(r['date']) == pinnedPitDate);
    if (idx < 0) return;
    final nextIdx = (idx + delta).clamp(0, daily.length - 1);
    if (nextIdx == idx) return;
    final nextRow = daily[nextIdx];
    final nextDate = text(nextRow['date']);
    if (nextIdx == daily.length - 1) {
      _clearPitSelection();
    } else {
      _selectPitDate(nextDate, barRow: nextRow);
    }
  }

  void _jumpToThreePillars() {
    final ctx = _threePillarsAnchorKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  Future<void> _loadPitSnapshot(String date) async {
    final serial = ++pitSerial;
    final cacheKey = _pitCacheKeyFor(date);
    final cached = _pitSnapshotCache[cacheKey];
    if (cached != null) {
      if (!mounted || serial != pitSerial) return;
      setState(() {
        pitSnapshot = cached;
        loadingPit = false;
      });
      return;
    }
    final targetProfile = selectedProfile;
    final targetFill = selectedFillMode;
    final targetOtm = selectedPutOtm;
    final targetM7Tp = selectedM7TpMode;
    final targetRoll = _isCore3 ? 'adaptive_120_90' : selectedRollMode;
    final targetM0 = _isCore3 ? true : selectedM0Enabled;
    final targetTp = selectedTpMode;
    final targetCc = selectedCcMode;
    final targetSp = selectedSpMode;
    final targetWc = selectedWcMode;
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory/pit',
        queryParameters: {
          'date': date,
          'profile': targetProfile,
          'strategy': selectedStrategyId,
          'fillMode': targetFill,
          'putOtm': targetOtm,
          'm7TpMode': targetM7Tp,
          'rollMode': targetRoll,
          'm0Enabled': targetM0 ? 'true' : 'false',
          'tpMode': targetTp,
          'ccMode': targetCc,
          'spMode': targetSp,
          if (targetSp != 'sp_off') 'wcMode': targetWc,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != pitSerial) return;
      if (asMap(res['m7_live_dashboard']).isNotEmpty ||
          asMap(res['live_market_snapshot']).isNotEmpty) {
        _pitSnapshotCache[cacheKey] = res;
        setState(() {
          pitSnapshot = res;
          loadingPit = false;
        });
      } else {
        setState(() => loadingPit = false);
      }
    } catch (_) {
      if (!mounted || serial != pitSerial) return;
      setState(() => loadingPit = false);
    }
  }

  Map<String, dynamic> _resolveEffectiveTopDoc(Map<String, dynamic> doc) {
    final pitDate = pinnedPitDate;
    if (pitDate == null || pitDate.isEmpty) return doc;

    final snapDoc = pitSnapshot;
    if (snapDoc != null && text(snapDoc['pit_date']) == pitDate) {
      return <String, dynamic>{
        ...doc,
        'pit_mode': true,
        'pit_date': pitDate,
        'latest_as_of_date': text(snapDoc['latest_as_of_date']).isNotEmpty
            ? text(snapDoc['latest_as_of_date'])
            : text(doc['as_of_date']),
        'as_of_date': pitDate,
        'liveExtended': false,
        if (asMap(snapDoc['live_market_snapshot']).isNotEmpty)
          'live_market_snapshot': snapDoc['live_market_snapshot'],
        if (asMap(snapDoc['m7_live_dashboard']).isNotEmpty)
          'm7_live_dashboard': snapDoc['m7_live_dashboard'],
        if (asMap(snapDoc['m7_live_dashboards_by_strategy']).isNotEmpty)
          'm7_live_dashboards_by_strategy':
              snapDoc['m7_live_dashboards_by_strategy'],
        if (asList(snapDoc['six_crisis_lights']).isNotEmpty)
          'six_crisis_lights': snapDoc['six_crisis_lights'],
        if (asMap(snapDoc['ad_line_signal']).isNotEmpty)
          'ad_line_signal': snapDoc['ad_line_signal'],
        if (asMap(snapDoc['live_signal_state']).isNotEmpty)
          'live_signal_state': snapDoc['live_signal_state'],
        if (asMap(snapDoc['live_signal_states_by_strategy']).isNotEmpty)
          'live_signal_states_by_strategy':
              snapDoc['live_signal_states_by_strategy'],
        if (asMap(snapDoc['live_sp_state']).isNotEmpty)
          'live_sp_state': snapDoc['live_sp_state'],
        if (asMap(snapDoc['live_sp_states_by_strategy']).isNotEmpty)
          'live_sp_states_by_strategy': snapDoc['live_sp_states_by_strategy'],
        if (asList(snapDoc['strategies_summary']).isNotEmpty)
          'strategies_summary': snapDoc['strategies_summary'],
      };
    }

    // Instant optimistic PIT overlay from daily_series bar while /pit is in flight
    final bar = pinnedPitRow ?? _findDailyBarByDate(pitDate);
    if (bar == null) return doc;

    final qqq = _numVal(bar['qqq_close']);
    final dd = _numVal(bar['dd_ath_pct']);
    final vxn = _numVal(bar['vxn']);
    final vr = _numVal(bar['vix_ratio']);
    final useCore3Bar = _isCore3 && bar['c3_prob'] is num;
    final m7Prob = _numVal(useCore3Bar ? bar['c3_prob'] : bar['m7_prob']).round();
    final p1 = _numVal(useCore3Bar ? bar['c3_p1'] : bar['m7_p1']).round();
    final p2 = _numVal(useCore3Bar ? bar['c3_p2'] : bar['m7_p2']).round();
    final p3 = _numVal(useCore3Bar ? bar['c3_p3'] : bar['m7_p3']).round();
    final tgtSlots = _numVal(
      useCore3Bar ? bar['c3_target_slots'] : bar['m7_target_slots'],
    ).round();
    final actSlots = _numVal(
      useCore3Bar ? bar['c3_active_slots'] : bar['m7_active_slots'],
    ).round();
    final m7Mask = _numVal(useCore3Bar ? bar['c3_mask'] : bar['m7_mask']).round();
    final lightsMask = _numVal(bar['lights_mask']).round();
    final modTriggered = <String, bool>{
      'M0': (m7Mask & 1) != 0,
      'M6': (m7Mask & 2) != 0,
      'M2': !_isCore3 && (m7Mask & 4) != 0,
      'M5': !_isCore3 && (m7Mask & 8) != 0,
      'M4': (m7Mask & 16) != 0,
      'M3': !_isCore3 && (m7Mask & 32) != 0,
    };
    final pillarScores = <String, int>{'P1': p1, 'P2': p2, 'P3': p3};

    final baseDash = _resolveM7LiveDashboard(doc);
    final optStress = _numVal(
      bar['live_stress'],
      _numVal(baseDash['live_stress_index']),
    ).round();
    final optPillars = asList(baseDash['pillars']).map((pil) {
      final pid = text(pil['id']);
      final mods = asList(pil['modules']).map((mod) {
        final mid = text(mod['id']);
        final trig = modTriggered[mid] ?? false;
        final pts = _numVal(mod['points']).round();
        return <String, dynamic>{
          ...mod,
          'triggered': trig,
          'earned_points': trig ? pts : 0,
        };
      }).toList();
      return <String, dynamic>{
        ...pil,
        'score': pillarScores[pid] ?? 0,
        'modules': mods,
      };
    }).toList();

    final optDash = <String, dynamic>{
      ...baseDash,
      'as_of_date': pitDate,
      'crisis_prob': m7Prob,
      'p1_score': p1,
      'p2_score': p2,
      'p3_score': p3,
      'live_stress_index': optStress,
      'live_stress_level': optStress >= 75
          ? 'crisis'
          : (optStress >= 50
                ? 'elevated'
                : (optStress >= 25 ? 'building' : 'calm')),
      'live_stress_label_en': _stressLevelFallbackEn(optStress),
      'live_stress_label_zh': _stressLevelFallbackZh(optStress),
      'data_freshness': <String, dynamic>{
        ...asMap(baseDash['data_freshness']),
        'yahoo_eod_date': pitDate,
        'ad_line_date': pitDate,
        'is_pit_replay': true,
      },
      'target_slots': tgtSlots,
      'active_slots': actSlots,
      'redline': <String, dynamic>{
        ...asMap(baseDash['redline']),
        'vxn': vxn,
        'vix_ratio': vr,
        'blocked': vxn > 27.0 || vr >= 1.02,
      },
      'book_b_vix_gate': <String, dynamic>{
        ...asMap(baseDash['book_b_vix_gate']),
        'vix': _numVal(bar['vix']),
        'vix_ratio': vr,
        'vix_ok': _numVal(bar['vix']) <= 20.0,
        'ratio_ok': vr < 1.02,
        'gate_open':
            _numVal(bar['vix']) <= 20.0 &&
            vr < 1.02 &&
            asMap(baseDash['post_tp_lockout'])['locked'] != true,
      },
      'sizing_calculator': <String, dynamic>{
        ...asMap(baseDash['sizing_calculator']),
        'qqq_spot': qqq,
        'vxn': vxn,
      },
      'pillars': optPillars,
    };

    final optLights = asList(doc['six_crisis_lights']).asMap().entries.map((e) {
      final lit = ((lightsMask >> e.key) & 1) != 0;
      return <String, dynamic>{
        ...e.value,
        'lit': lit,
        'pit_historical': true,
      };
    }).toList();

    final optSnap = <String, dynamic>{
      ...asMap(doc['live_market_snapshot']),
      'as_of_date': pitDate,
      'qqq_close': qqq,
      'dd_from_ath_pct': dd,
      'vxn': vxn,
      'vix': _numVal(bar['vix']),
      'vix3m': _numVal(bar['vix3m']),
      'vix_vix3m_ratio': vr,
      'raw_crisis_score': _numVal(bar['crisis_lights']).round(),
    };

    return <String, dynamic>{
      ...doc,
      'pit_mode': true,
      'pit_date': pitDate,
      'latest_as_of_date': text(doc['as_of_date']),
      'as_of_date': pitDate,
      'liveExtended': false,
      'live_market_snapshot': optSnap,
      'm7_live_dashboard': optDash,
      'm7_live_dashboards_by_strategy': <String, dynamic>{
        'M7G_Graded': optDash,
        'Core3_Adaptive': optDash,
        'M7_Ensemble': optDash,
      },
      'six_crisis_lights': optLights,
    };
  }

  Widget _buildPitReplayBanner(
    Map<String, dynamic> fullDoc,
    Map<String, dynamic> topDoc, {
    required String keyPrefix,
    required bool compact,
    bool showStepButtons = true,
  }) {
    final pitDate = pinnedPitDate;
    if (pitDate == null || pitDate.isEmpty) return const SizedBox.shrink();
    final snap = asMap(topDoc['live_market_snapshot']);
    final bar = pinnedPitRow ?? _findDailyBarByDate(pitDate);
    final qqqClose = _numVal(snap['qqq_close'], _numVal(bar?['qqq_close']));
    final ddAth = _numVal(snap['dd_from_ath_pct'], _numVal(bar?['dd_ath_pct']));
    final vxnNow = _numVal(snap['vxn'], _numVal(bar?['vxn']));
    final vixRatio = _numVal(
      snap['vix_vix3m_ratio'],
      _numVal(bar?['vix_ratio']),
    );
    final latestDate = text(fullDoc['as_of_date']).isNotEmpty
        ? text(fullDoc['as_of_date'])
        : widget.asOf;
    final daily = asList(fullDoc['daily_series']);
    final curIdx = daily.indexWhere((r) => text(r['date']) == pitDate);
    final canPrev = curIdx > 0;
    final canNext = curIdx >= 0 && curIdx + 1 < daily.length;

    return Container(
      key: ValueKey('crisis-pit-$keyPrefix-banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: _sky.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _sky.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: _sky.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _sky.withValues(alpha: 0.55)),
                    ),
                    child: Text(
                      w('PIT REPLAY', 'PIT 历史状态回放'),
                      style: const TextStyle(
                        color: _sky,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    pitDate,
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 14 : 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(
                    'QQQ \$${qqqClose.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    w(
                      '(${_fmtPct(ddAth)} vs ATH · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)})',
                      '（距前高 ${_fmtPct(ddAth)} · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)}）',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.8),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (showStepButtons) ...[
                    InkWell(
                      key: ValueKey('crisis-pit-$keyPrefix-prev-btn'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: canPrev ? () => _stepPitDate(-1) : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: p.card,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: canPrev
                                ? _sky.withValues(alpha: 0.45)
                                : p.border,
                          ),
                        ),
                        child: Text(
                          w('◀ Prev', '◀ 上一日'),
                          style: TextStyle(
                            color: canPrev ? p.text : p.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    InkWell(
                      key: ValueKey('crisis-pit-$keyPrefix-next-btn'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: canNext ? () => _stepPitDate(1) : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: p.card,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: canNext
                                ? _sky.withValues(alpha: 0.45)
                                : p.border,
                          ),
                        ),
                        child: Text(
                          w('Next ▶', '下一日 ▶'),
                          style: TextStyle(
                            color: canNext ? p.text : p.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                  InkWell(
                    key: ValueKey('crisis-pit-$keyPrefix-return-live-btn'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: _clearPitSelection,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4.5,
                      ),
                      decoration: BoxDecoration(
                        color: _emerald.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _emerald.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Text(
                        w(
                          'Return to Live ($latestDate)',
                          '回到最新（$latestDate）',
                        ),
                        style: const TextStyle(
                          color: _emerald,
                          fontSize: 11.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (loadingPit) ...[
            const SizedBox(height: 6),
            const LinearProgressIndicator(minHeight: 2, color: _sky),
          ],
        ],
      ),
    );
  }

  double _numVal(dynamic v, [double fallback = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    if (v is String) {
      final parsed = double.tryParse(v);
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return fallback;
  }

  String _fmtUsd(double v, {bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final fixed = v.abs().round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < fixed.length; i++) {
      if (i > 0 && (fixed.length - i) % 3 == 0) buf.write(',');
      buf.write(fixed[i]);
    }
    return '$sign\$$buf';
  }

  String _fmtUsdCents(double v, {bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final parts = v.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '$sign\$$buf.${parts[1]}';
  }

  String _fmtUsdCompact(double v, {bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final a = v.abs();
    if (a >= 1000000) return '$sign\$${(a / 1000000).toStringAsFixed(2)}M';
    if (a >= 1000) return '$sign\$${(a / 1000).toStringAsFixed(1)}K';
    return '$sign\$${a.round()}';
  }

  String _fmtPct(double v, {int digits = 1, bool signed = true}) {
    final sign = v > 0 && signed ? '+' : '';
    return '$sign${v.toStringAsFixed(digits)}%';
  }

  String _fmtShares(double v, {int digits = 1, bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final parts = v.abs().toStringAsFixed(digits).split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return digits > 0 ? '$sign$buf.${parts[1]}' : '$sign$buf';
  }

  String _humanStrategyLabel(String id) {
    return switch (id) {
      'M7G_Graded' => w(
        'Full M7 Shield (Recommended)',
        '全套 M7 护盾（默认推荐）',
      ),
      'Core3_Adaptive' => w(
        'Core-3 Minimal (Low Freq · High PF)',
        '精简 3 核（低频高赔率）',
      ),
      'M7_Ensemble' => w('M7 2-Slot Ensemble', 'M7 三支柱双槽'),
      'U1_PureOptions' => w('Legacy U1 Dual-Slot', '旧版对照 · U1 双槽'),
      'B1c_PureAD' => w('Legacy B1c AD Breadth', '旧版 · B1c 宽度背离'),
      'D2_SixLights' => w('Legacy D2 6-Light Collar', '旧版 · D2 六灯领口'),
      'NoPut_CallOnly' => selectedSpMode == 'sp_off'
          ? w('No Put (Call Only)', '不买 Put（仅卖 Call）')
          : w('No Put (Overlay Only)', '不买危机 Put（仅叠加）'),
      'H2_G4_PriceGate' => w('Legacy Price Gate', '旧版 · 价格低波门控'),
      'BH_Pure_QQQ' => w('Buy & Hold QQQ', '死拿 QQQ'),
      _ => w('Protected Strategy', '保护策略'),
    };
  }

  String _pricingSourceShortLabel(String rawSrc) {
    final s = rawSrc.trim().toLowerCase();
    if (s == 'real_opra' || s.startsWith('real_opra')) {
      return w('OPRA Real', 'OPRA 实盘');
    }
    if (s.startsWith('real_polygon')) return w('Polygon Real', 'Polygon 实盘');
    if (s == 'real_hybrid') return w('Real Hybrid', '实盘混合');
    if (s == 'calibrated_bsm' || s == 'bsm_calibrated') {
      return w('BSM* Calib.', 'BSM* 校准');
    }
    return w('BSM* Calib.', 'BSM* 校准');
  }

  Color _pricingSourceColor(String rawSrc) {
    final s = rawSrc.trim().toLowerCase();
    if (s == 'real_opra' || s.startsWith('real_opra')) return _emerald;
    if (s.startsWith('real_polygon') || s == 'real_hybrid') return _sky;
    return _amber;
  }

  String _humanPutOtmLabel(String modeId) {
    return switch (modeId) {
      'otm20' => w('-20% OTM (Compare)', '-20% OTM（深虚值对照）'),
      _ => w('-15% OTM (Real-OPRA #1)', '-15% OTM（真实 OPRA 冠军）'),
    };
  }

  String _humanPutOtmShort(String modeId) {
    return modeId == 'otm20' ? '-20% OTM' : '-15% OTM';
  }

  String _humanFillModeLabel(String modeId) {
    return switch (modeId) {
      'ask_bid' => w(
        'Strict Ask/Bid (\$1.69M)',
        '严格买一卖一（\$168.8万）',
      ),
      _ => w(
        'IBKR Limit Default (\$1.74M)',
        'IBKR 限价默认（\$174.0万）',
      ),
    };
  }

  String _humanFillModeShort(String modeId) {
    return modeId == 'ask_bid'
        ? w('Ask/Bid', '严格盘口')
        : w('IBKR Limit', 'IBKR限价');
  }

  String _humanRollModeLabel(String modeId) {
    return switch (modeId) {
      'adaptive_120_90' => w(
        'Adaptive 125->75 / CTA 90->30 (Locked)',
        '自适应 125→75 / CTA 90→30（锁定）',
      ),
      '120d_roll50' => w(
        'Unified 120->50 Roll',
        '统一 120→50 滚仓',
      ),
      _ => w('90D Hold to Expiry', '90D 持有到期'),
    };
  }

  String _humanRollModeShort(String modeId) {
    return switch (modeId) {
      'adaptive_120_90' => w('Adaptive 125/90', '自适应 125/90'),
      '120d_roll50' => w('Unified 120->50', '统一 120→50'),
      _ => w('90D Hold', '90D 持有'),
    };
  }

  String _humanM7TpModeLabel(String modeId) {
    return switch (modeId) {
      'itm_tp' => w(
        'STRICT ITM (1.00×K)',
        '严格实值止盈（1.00×K）',
      ),
      _ => w(
        'NEAR-ITM 1.05×K + 5D Lock (Default)',
        '准实值 1.05×K + 5天禁买锁（默认）',
      ),
    };
  }

  String _humanM7TpModeShort(String modeId) {
    return modeId == 'itm_tp' ? 'STRICT_ITM' : 'NEAR_ITM_5D';
  }

  String _humanM7EngineHint(Map<String, dynamic> stratSummary) {
    final trN = _numVal(stratSummary['tranches_total']).round();
    final tpN = _numVal(stratSummary['tp_count']).round();
    final rollN = _numVal(
      stratSummary['roll_total_count'] ?? stratSummary['roll_75d_count'] ?? stratSummary['roll_50d_count'],
    ).round();
    final salvPct = _numVal(
      stratSummary['avg_roll_salvage_pct'] ?? stratSummary['avg_salvage_pct'],
    );
    final maxRoi = _numVal(stratSummary['max_roi_mult']);
    final pf = _numVal(
      stratSummary['profit_factor'],
      _numVal(stratSummary['put_profit_factor']),
    );
    const max5xDte = 45;
    final String tenorEn;
    final String tenorZh;
    final String rollClauseEn;
    final String rollClauseZh;
    if (selectedRollMode == 'adaptive_120_90') {
      tenorEn = 'Book B 0.20% (VIX<=20, 125->75D) + Book M 1.25%/slot (125->75D / CTA 90->30D)';
      tenorZh = 'Book B 0.20% 常态基底(VIX≤20, 125→75D) + Book M 1.25%/槽(125→75D / CTA 90→30D)';
      rollClauseEn =
          ' · hard roll/salvage ($rollN rolls, avg ${salvPct.toStringAsFixed(1)}% recovered)';
      rollClauseZh =
          ' · 硬滚仓回收（共 $rollN 次 · 平均回收 ${salvPct.toStringAsFixed(1)}%）';
    } else if (selectedRollMode == '120d_roll50') {
      tenorEn = 'Book B 0.20% + Book M 1.25%/slot 120D';
      tenorZh = 'Book B 0.20% + Book M 1.25%/槽 120D';
      rollClauseEn =
          ' · <=50 DTE residual roll/salvage ($rollN rolls, avg ${salvPct.toStringAsFixed(1)}% recovered)';
      rollClauseZh =
          ' · 剩 ≤50 DTE 残值滚仓回收（共 $rollN 次 · 平均回收 ${salvPct.toStringAsFixed(1)}%）';
    } else {
      tenorEn = 'Book B 0.20% + Book M 1.25%/slot 90D';
      tenorZh = 'Book B 0.20% + Book M 1.25%/槽 90D';
      rollClauseEn = ' · hold to TP or 90D expiry';
      rollClauseZh = ' · 持有至止盈或 90D 到期';
    }
    final pfTxt = pf > 0 ? ' · PF ${pf.toStringAsFixed(2)}x' : '';
    return w(
      '$tenorEn ${_humanPutOtmShort(selectedPutOtm)} · ${_humanM7TpModeShort(selectedM7TpMode)} + 5x (DTE<=$max5xDte)$rollClauseEn$pfTxt -> $trN tranches ($tpN TPs, peak ${maxRoi.toStringAsFixed(1)}x)',
      '$tenorZh ${_humanPutOtmShort(selectedPutOtm)} · 止盈 ${_humanM7TpModeShort(selectedM7TpMode)} + 5x（DTE≤$max5xDte）$rollClauseZh$pfTxt → 共 $trN 笔（止盈 $tpN 次 · 单笔最高 ${maxRoi.toStringAsFixed(1)}x）',
    );
  }

  String _activeComboBadgeText() {
    final putPart = _humanStrategyLabel(selectedStrategyId);
    final callPart = _humanCcModeLabel(selectedCcMode);
    final spPart = _humanSpModeLabel(selectedSpMode);
    final wcShort = _humanWcModeShort(selectedWcMode);
    final hasCall = selectedCcMode != 'cc_off';
    final hasSp = selectedSpMode != 'sp_off';
    final spWithWc = '$spPart · $wcShort';
    if (selectedStrategyId == 'NoPut_CallOnly') {
      if (!hasCall && !hasSp) {
        return w(
          'Active Combo: Buy & Hold QQQ (No Put · No Call · No Wheel)',
          '当前组合：不买 Put · 不卖 Call · 不开卖 Put Wheel（等效死拿 QQQ）',
        );
      }
      if (!hasCall && hasSp) {
        return w(
          'Active Combo: Pure QQQ + Standalone Panic Put Wheel ($spWithWc)',
          '当前组合：纯持有 QQQ + 单独叠加「$spWithWc」',
        );
      }
      if (hasCall && !hasSp) {
        return w(
          'Active Combo: No Crisis Put · Overlay $callPart',
          '当前组合：不买危机 Put · 纯叠加「$callPart」',
        );
      }
      return w(
        'Active Combo: No Crisis Put · $callPart + Wheel ($spWithWc)',
        '当前组合：不买危机 Put · 叠加「$callPart」 + 「$spWithWc」',
      );
    }
    final tpPart = _isM7Strategy
        ? '0.20%/1.25% · ${_humanFillModeShort(selectedFillMode)} · ${_humanPutOtmShort(selectedPutOtm)} · ${_humanRollModeShort(selectedRollMode)} · ${_humanM7TpModeShort(selectedM7TpMode)}${selectedM0Enabled ? '' : ' · No-M0'}'
        : _humanTpModeLabel(selectedTpMode);
    if (!hasCall && !hasSp) {
      return w(
        'Active Combo: $putPart ($tpPart) · No Normal-Time Call',
        '当前组合：$putPart（$tpPart）· 不叠加平时卖 Call',
      );
    }
    if (hasCall && !hasSp) {
      return w(
        'Active Combo: $putPart ($tpPart) + $callPart',
        '当前组合：$putPart（$tpPart） + 叠加「$callPart」',
      );
    }
    if (!hasCall && hasSp) {
      return w(
        'Active Combo: $putPart ($tpPart) + Panic Wheel ($spWithWc)',
        '当前组合：$putPart（$tpPart） + 恐慌卖 Put Wheel「$spWithWc」',
      );
    }
    return w(
      'Active 3-Engine Combo: $putPart ($tpPart) + $callPart + Wheel ($spWithWc)',
      '当前三引擎组合：$putPart（$tpPart） + 「$callPart」 + 「$spWithWc」',
    );
  }

  List<Map<String, dynamic>> _buildCcChartEvents(
    List<Map<String, dynamic>> ccLedger,
    String visibleStart,
    String visibleEnd,
  ) {
    if (ccLedger.isEmpty || visibleStart.isEmpty || visibleEnd.isEmpty) {
      return const [];
    }
    final rollLegByDateAndGen = <String, Map<String, dynamic>>{};
    for (final cc in ccLedger) {
      final rg = _numVal(cc['roll_gen']).round();
      if (rg > 0) {
        rollLegByDateAndGen['${text(cc['entry_date'])}#$rg'] = cc;
      }
    }
    final out = <Map<String, dynamic>>[];
    for (final cc in ccLedger) {
      final entryDate = text(cc['entry_date']);
      final exitDate = text(cc['exit_date']);
      final rollGen = _numVal(cc['roll_gen']).round();
      final exitReason = text(cc['exit_reason']);
      final entrySpot = _numVal(cc['entry_spot']);
      final kc = _numVal(cc['kc']);
      final otmPct = entrySpot > 0 ? (kc / entrySpot - 1.0) * 100.0 : 0.0;

      if (rollGen == 0 &&
          entryDate.compareTo(visibleStart) >= 0 &&
          entryDate.compareTo(visibleEnd) <= 0) {
        out.add({
          'date': entryDate,
          'event_type': 'cc_open',
          'spot': entrySpot,
          'kc': kc,
          'otm_pct': otmPct,
          'prem_usd': _numVal(cc['prem_usd']),
          'entry_vxn': _numVal(cc['entry_vxn']),
        });
      }

      if (exitDate.isNotEmpty &&
          exitDate.compareTo(visibleStart) >= 0 &&
          exitDate.compareTo(visibleEnd) <= 0) {
        if (exitReason == 'delta_roll_up' || exitReason == 'delta_credit_roll') {
          final succ = rollLegByDateAndGen['$exitDate#${rollGen + 1}'];
          out.add({
            'date': exitDate,
            'event_type': exitReason == 'delta_credit_roll'
                ? 'cc_credit_roll'
                : 'cc_roll_up',
            'spot': _numVal(cc['exit_spot']),
            'old_kc': kc,
            'new_kc': succ != null ? _numVal(succ['kc']) : null,
            'loss_usd': _numVal(cc['loss_usd']),
            'new_prem_usd': succ != null ? _numVal(succ['prem_usd']) : 0.0,
            'net_pnl_usd': _numVal(cc['net_pnl_usd']),
          });
        } else if (exitReason == 'delta_stop') {
          out.add({
            'date': exitDate,
            'event_type': 'cc_delta_stop',
            'spot': _numVal(cc['exit_spot']),
            'kc': kc,
            'prem_usd': _numVal(cc['prem_usd']),
            'loss_usd': _numVal(cc['loss_usd']),
            'net_pnl_usd': _numVal(cc['net_pnl_usd']),
          });
        }
      }
    }
    return out;
  }

  String _humanTpModeLabel(String modeId) {
    return switch (modeId) {
      'layered_itm' => w('Layered ITM (Rec.)', '分层实值（推荐）'),
      'standard_dual' => w('Standard 1.10', '标准 1.10'),
      'both_4x' => w('Deep 4x Both', '两槽 4x 深度'),
      _ => w('Layered ITM', '分层实值'),
    };
  }

  String _humanTpModeHint(String modeId) {
    return switch (modeId) {
      'layered_itm' => w(
        'Collar exits at VIX/3M >= 1.10 to unlock Call cap · Naked Put ignores shallow spikes until ITM (QQQ <= K_P) · +5x slow-bear lock (DTE <= 45)',
        '次仓领口见 VIX/3M ≥ 1.10 即平解封卖 Call · 首仓裸 Put 浅跌无视倒挂，必须跌破行权价 (QQQ ≤ K_P) 进实值才平 · 叠加后半程 5x 慢熊锁利',
      ),
      'standard_dual' => w(
        'Both slots exit immediately on VIX/3M >= 1.10 panic inversion · +5x slow-bear lock (DTE <= 45)',
        '双槽统一：见 VIX/3M ≥ 1.10 恐慌倒挂即次日开盘止盈抄底 · 叠加后半程（DTE ≤ 45）Put ≥ 5x 慢熊锁利',
      ),
      'both_4x' => w(
        'Both slots require VIX/3M >= 1.10 AND Put >= 4x entry cost (filters shallow spikes) · +5x slow-bear lock (DTE <= 45)',
        '双槽统一：必须 VIX/3M ≥ 1.10 且 Put ≥ 4 倍成本才认恐慌止盈（过滤浅跌假倒挂） · 叠加后半程 5x 慢熊锁利',
      ),
      _ => '',
    };
  }

  String _humanCcModeLabel(String modeId) {
    return switch (modeId) {
      'cc_off' => w('Off', '关闭'),
      'cc_d12_d35' => w(
        '12Δ · Delta 0.35 Stop (Rec. · 0 Breach)',
        '全天候 12Δ · Delta 0.35 止损（推荐 · 0穿最稳）',
      ),
      'cc_d12_r45' => w(
        '12Δ · Delta 0.45 Roll (30D Up)',
        '全天候 12Δ · Delta 0.45 展期 Roll（30D 上移）',
      ),
      'cc_d12_cr55' => w(
        '12Δ · Delta 0.55 Credit Roll (45D)',
        '全天候 12Δ · Delta 0.55 零成本 Roll（45D）',
      ),
      _ => w('Off', '关闭'),
    };
  }

  String _humanCcModeHint(String modeId, Map<String, dynamic> stratSummary) {
    final ccN = _numVal(stratSummary['cc_trades_count']).round();
    final ccAsgn = _numVal(stratSummary['cc_assigned_count']).round();
    final ccStop = _numVal(stratSummary['cc_stop_count']).round();
    final ccRoll = _numVal(stratSummary['cc_roll_count']).round();
    final ccYrs = _numVal(stratSummary['cc_active_years']).round();
    final ccPrem = _numVal(stratSummary['cc_gross_prem_usd']);
    final ccLoss = _numVal(stratSummary['cc_gross_loss_usd']);
    final ccPutFund = _numVal(stratSummary['cc_funded_puts_usd']);
    return switch (modeId) {
      'cc_off' => w(
        'Normal-time covered calls OFF · 100% uncapped upside during bull trends',
        '平时不卖 Call · 牛市主升浪 100% 零封顶损耗',
      ),
      'cc_d12_d35' => w(
        '25D 12-Delta (min +5% OTM) whenever ATH <= 3% + Delta >= 0.35 stop buyback -> $ccN trades across $ccYrs yrs ($ccStop stops, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, stop/close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ（保底 +5% OTM）Call，Delta ≥ 0.35 即止损平仓：覆盖 $ccYrs 年共 $ccN 笔（止损 $ccStop 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 止损/平仓 ${_fmtUsd(-ccLoss)}）',
      ),
      'cc_d12_r45' => w(
        '25D 12-Delta whenever ATH <= 3% + Delta >= 0.45 roll out 30D to fresh higher 12-Delta strike -> $ccN trades across $ccYrs yrs ($ccRoll rolls, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ Call，Delta ≥ 0.45 同步展期 30 天上移至新 12Δ 高行权价：覆盖 $ccYrs 年共 $ccN 笔（展期上移 $ccRoll 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 平旧仓 ${_fmtUsd(-ccLoss)}）',
      ),
      'cc_d12_cr55' => w(
        '25D 12-Delta whenever ATH <= 3% + Delta >= 0.55 zero-cost credit roll 45D (or close if no OTM credit) -> $ccN trades across $ccYrs yrs ($ccRoll rolls, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ Call，Delta ≥ 0.55 尝试向后 45 天做零成本上移 Roll（无虚值零成本可展则平仓）：覆盖 $ccYrs 年共 $ccN 笔（零成本展期 $ccRoll 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 平旧仓 ${_fmtUsd(-ccLoss)}）',
      ),
      _ => '',
    };
  }

  String _ccExitReasonTag(String reason) {
    return switch (reason) {
      'delta_stop' => w('Δ0.35 Stop', 'Δ0.35止损'),
      'delta_roll_up' => w('Δ0.45 Roll Up', 'Δ0.45展期上移'),
      'delta_credit_roll' => w('Δ0.55 Credit Roll', 'Δ0.55零成本Roll'),
      'stop_3x_cap' => w('3x Stop', '3×止损'),
      'assigned_breach' => w('Breached', '穿价'),
      'closed_for_collar' => w('For Collar', '让位领口'),
      'panic_close_uncap' => w('Panic Uncap', '恐慌解封'),
      _ => w('Expired \$0', '到期归零'),
    };
  }

  List<Map<String, dynamic>> _currentCcLedgerForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['cc_ledgers_by_strategy']);
    return asList(byStrat[selectedStrategyId]);
  }

  String _humanSpModeLabel(String modeId) {
    return switch (modeId) {
      'sp_off' => w('Off (0 Leverage)', '关闭（0 杠杆）'),
      'sp_14d_cap10' => w(
        '14D 10% Cap (Calmar #1 · Rec.)',
        '14D 10%帽（Calmar冠军 · 推荐）',
      ),
      'sp_10d_vixf' => w(
        '10D VIX Falling (20% Cap)',
        '10D VIX回落（20%帽）',
      ),
      'sp_14d_unf' => w(
        '14D Unfiltered (20% Cap · NAV #1)',
        '14D 无过滤（20%帽 · 收益冠军）',
      ),
      _ => w('Off (0 Leverage)', '关闭（0 杠杆）'),
    };
  }

  String _humanWcModeLabel(String modeId) {
    return switch (modeId) {
      'wc_reclaim_30d_d35' => w(
        'Reclaim K -> 30D 0.35Δ (Rec.)',
        '涨回接货价卖 30D 0.35Δ（推荐）',
      ),
      'wc_30d_c5s5' => w(
        '30D +5% Cost/Spot (Immediate)',
        '30D 双+5%（立即卖）',
      ),
      'wc_14d_c0s2' => w(
        '14D Breakeven+2% (Legacy)',
        '14D 保本+2%（原基准）',
      ),
      _ => w('Reclaim K -> 30D 0.35Δ (Rec.)', '涨回接货价卖 30D 0.35Δ（推荐）'),
    };
  }

  String _humanWcModeShort(String modeId) {
    return switch (modeId) {
      'wc_reclaim_30d_d35' => w('Reclaim -> 30D 0.35Δ', '涨回卖 30D 0.35Δ'),
      'wc_30d_c5s5' => w('30D +5% WC', '30D 双+5% Call'),
      'wc_14d_c0s2' => w('14D BE+2% WC', '14D 保本+2% Call'),
      _ => w('Reclaim -> 30D 0.35Δ', '涨回卖 30D 0.35Δ'),
    };
  }

  String _humanWcModeFormulaHint(
    String modeId,
    Map<String, dynamic> stratSummary,
  ) {
    final maxCyc = _numVal(stratSummary['max_wheel_cycle_days']).round();
    final cycEn = maxCyc > 0 ? ' · max cycle ${maxCyc}d' : '';
    final cycZh = maxCyc > 0 ? ' · 最长清债周期 $maxCyc 天' : '';
    return switch (modeId) {
      'wc_reclaim_30d_d35' => w(
        'Hold uncapped while QQQ < K_assign; once EOD >= K_assign, sell 30D 0.35Δ Call next open$cycEn',
        '水下严禁封顶卖 Call，保留 100% 反弹斜率；收盘涨回 ≥ 接货价后次日开盘卖 30D 0.35Δ Call$cycZh',
      ),
      'wc_30d_c5s5' => w(
        'Strike = max(1.05x Cost, 1.05x Spot) · Immediately sells 30D Call after assignment$cycEn',
        '行权价 = max(1.05×成本, 1.05×现价) · 接货次日立即卖 30D Call$cycZh',
      ),
      'wc_14d_c0s2' => w(
        'Strike = max(Cost, 1.02x Spot) · Fast breakeven call-away de-leveraging$cycEn',
        '行权价 = max(成本, 1.02×现价) · 快速保本去杠杆$cycZh',
      ),
      _ => '',
    };
  }

  String _humanSpModeHint(String modeId, Map<String, dynamic> stratSummary) {
    final spN = _numVal(stratSummary['sp_trades_count']).round();
    final winPct = _numVal(stratSummary['sp_win_rate_pct']);
    final spAsgn = _numVal(stratSummary['sp_assignments_count']).round();
    final wcN = _numVal(stratSummary['wc_trades_count']).round();
    final wcCalled = _numVal(stratSummary['wc_called_away_count']).round();
    final spPrem = _numVal(stratSummary['sp_gross_prem_usd']);
    final wcPrem = _numVal(stratSummary['wc_gross_prem_usd']);
    final marginInt = _numVal(stratSummary['margin_interest_usd']);
    final maxLev = _numVal(stratSummary['max_gross_stock_lev'], 1.0);
    final calmar = _numVal(stratSummary['calmar']);
    final wcRuleEn = switch (selectedWcMode) {
      'wc_reclaim_30d_d35' => 'Wait reclaim >= K_assign then 30D 0.35Δ Wheel Call',
      'wc_30d_c5s5' => '30D +5% Wheel Call max(1.05*K_assign, 1.05*S)',
      _ =>
        '${modeId == 'sp_10d_vixf' ? '10D' : '14D'} Breakeven+2% Wheel Call max(K_assign, 1.02*S)',
    };
    final wcRuleZh = switch (selectedWcMode) {
      'wc_reclaim_30d_d35' => '接货水下不封顶 · 涨回接货价后卖 30D 0.35Δ Call 去杠杆',
      'wc_30d_c5s5' => '接货反向卖 30D 双+5% Call 去杠杆',
      _ =>
        '接货反向卖 ${modeId == 'sp_10d_vixf' ? '10D' : '14D'} 保本+2% Call 去杠杆',
    };
    return switch (modeId) {
      'sp_off' => w(
        'Engine 3 OFF · 0 margin debt, max stock exposure strictly 1.00x',
        '第三引擎关闭 · 0 融资负债、0 利息，股票总敞口严格 1.00x',
      ),
      'sp_14d_cap10' => w(
        'VIX/3M >= 1.00 sells 14D 5% OTM Put (<= 10% equity cap) + $wcRuleEn -> $spN puts (${winPct.toStringAsFixed(1)}% win, $spAsgn assigned), $wcN wheel calls ($wcCalled called away), prem ${_fmtUsd(spPrem + wcPrem, signed: true)}, 12Y IBKR interest ${_fmtUsdCents(marginInt)}, max stock lev ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
        'VIX/3M ≥ 1.00 卖 14D 5% OTM Put（名义严控 ≤ 10% 净值）+ $wcRuleZh：共 $spN 笔卖 Put（胜率 ${winPct.toStringAsFixed(1)}% · 接货 $spAsgn 次）+ $wcN 笔 Wheel Call（被 Call 走 $wcCalled 次），收租 ${_fmtUsd(spPrem + wcPrem, signed: true)} · 12 年 IBKR 融资总利息仅 ${_fmtUsdCents(marginInt)} · 峰值股票敞口 ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
      ),
      'sp_10d_vixf' => w(
        'Requires VIX/3M >= 1.00 AND daily VIX falling (panic cresting) -> sells 10D 5% OTM Put (<= 20% cap) + $wcRuleEn -> $spN puts (${winPct.toStringAsFixed(1)}% win, $spAsgn assigned), $wcN wheel calls ($wcCalled called away), prem ${_fmtUsd(spPrem + wcPrem, signed: true)}, 12Y IBKR interest ${_fmtUsdCents(marginInt)}, max stock lev ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
        '要求 VIX/3M ≥ 1.00 且当日 VIX 较前日回落（恐慌见顶拐头）才卖 10D 5% OTM Put（≤ 20% 帽）+ $wcRuleZh：共 $spN 笔卖 Put（胜率 ${winPct.toStringAsFixed(1)}% · 接货 $spAsgn 次）+ $wcN 笔 Wheel Call（被 Call 走 $wcCalled 次），收租 ${_fmtUsd(spPrem + wcPrem, signed: true)} · 12 年总利息仅 ${_fmtUsdCents(marginInt)} · 峰值敞口 ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
      ),
      'sp_14d_unf' => w(
        'Sells 14D 5% OTM Put whenever VIX/3M >= 1.00 (<= 20% equity cap) + $wcRuleEn -> $spN puts (${winPct.toStringAsFixed(1)}% win, $spAsgn assigned), $wcN wheel calls ($wcCalled called away), prem ${_fmtUsd(spPrem + wcPrem, signed: true)}, 12Y IBKR interest ${_fmtUsdCents(marginInt)}, max stock lev ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
        '只要 VIX/3M ≥ 1.00 即卖 14D 5% OTM Put（≤ 20% 名义帽）+ $wcRuleZh：共 $spN 笔卖 Put（胜率 ${winPct.toStringAsFixed(1)}% · 接货 $spAsgn 次）+ $wcN 笔 Wheel Call（被 Call 走 $wcCalled 次），收租 ${_fmtUsd(spPrem + wcPrem, signed: true)} · 12 年总利息 ${_fmtUsdCents(marginInt)} · 峰值敞口 ${maxLev.toStringAsFixed(2)}x · Calmar ${calmar.toStringAsFixed(3)}',
      ),
      _ => '',
    };
  }

  String _spExitReasonTag(String legType, String reason, bool isOpenLive) {
    if (isOpenLive) return w('Open Live', '实盘持仓中');
    if (legType == 'wheel_call') {
      return switch (reason) {
        'called_away' => w('Called Away · Debt Cleared', '被 Call 走 · 清债去杠杆'),
        _ => w('Expired OTM · Keep Stock', '到期归零 · 续卖 Wheel Call'),
      };
    }
    return switch (reason) {
      'assigned_enter_wheel' || 'assigned' => w(
        'Assigned · Enter Wheel',
        '到期接货 · 进入 Wheel',
      ),
      _ => w('Expired OTM · Banked QQQ', '到期归零 · 保费复投 QQQ'),
    };
  }

  List<Map<String, dynamic>> _currentSpLedgerForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['sp_ledgers_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['sp_ledger']);
  }

  List<Map<String, dynamic>> _buildSpChartEvents(
    List<Map<String, dynamic>> spLedger,
    String visibleStart,
    String visibleEnd,
  ) {
    if (spLedger.isEmpty || visibleStart.isEmpty || visibleEnd.isEmpty) {
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final leg in spLedger) {
      final legType = text(leg['leg_type']);
      final entryDate = text(leg['entry_date']);
      final exitDate = text(leg['exit_date']);
      final exitReason = text(leg['exit_reason']);
      if (legType == 'short_put') {
        if (entryDate.compareTo(visibleStart) >= 0 &&
            entryDate.compareTo(visibleEnd) <= 0) {
          out.add({
            'date': entryDate,
            'event_type': 'sp_open',
            'spot': _numVal(leg['entry_spot']),
            'strike': _numVal(leg['strike']),
            'dte': _numVal(leg['dte']).round(),
            'shares': _numVal(leg['shares']),
            'prem_usd': _numVal(leg['prem_usd']),
          });
        }
        if (exitReason.contains('assigned') &&
            exitDate.isNotEmpty &&
            exitDate.compareTo(visibleStart) >= 0 &&
            exitDate.compareTo(visibleEnd) <= 0) {
          out.add({
            'date': exitDate,
            'event_type': 'sp_assign',
            'spot': _numVal(leg['exit_spot']),
            'strike': _numVal(leg['strike']),
            'shares': _numVal(leg['shares']),
            'prem_usd': _numVal(leg['prem_usd']),
          });
        }
      } else if (legType == 'wheel_call') {
        if (exitReason == 'called_away' &&
            exitDate.isNotEmpty &&
            exitDate.compareTo(visibleStart) >= 0 &&
            exitDate.compareTo(visibleEnd) <= 0) {
          out.add({
            'date': exitDate,
            'event_type': 'wc_called',
            'spot': _numVal(leg['exit_spot']),
            'strike': _numVal(leg['strike']),
            'assigned_cost_k': _numVal(leg['assigned_cost_k']),
            'shares': _numVal(leg['shares']),
            'prem_usd': _numVal(leg['prem_usd']),
            'net_pnl_usd': _numVal(leg['net_pnl_usd']),
          });
        }
      }
    }
    return out;
  }

  String _humanWindowChipLabel(Map<String, dynamic> win) {
    final id = text(win['id']);
    return switch (id) {
      '2015-08' => w('2015 Aug', '2015 汇改'),
      '2018-Q4' => w('2018 Q4', '2018 缩表'),
      '2020-03' => w('2020 COVID', '2020 熔断'),
      '2022' => w('2022 Bear', '2022 慢熊'),
      '2024-08' => w('2024 Yen', '2024 日元'),
      '2025-04' => w('2025 Tariff', '2025 关税'),
      '2026-08_11_LIVE' => w('2026 LIVE', '2026 LIVE'),
      _ => w(text(win['pill_en']), text(win['pill_zh'])),
    };
  }

  String _humanWindowTitle(Map<String, dynamic> win) {
    final id = text(win['id']);
    return switch (id) {
      '2015-08' => w(
        '2015 Flash Crash & Devaluation Shock',
        '2015 年 8 月汇改闪崩',
      ),
      '2018-Q4' => w(
        '2018 Q4 Fed Tightening Selloff',
        '2018 四季度联储缩表急跌',
      ),
      '2020-03' => w(
        '2020 COVID-19 Liquidity Crash',
        '2020 年 3 月疫情流动性熔断',
      ),
      '2022' => w(
        '2022 Rate-Hike Grinding Bear Market',
        '2022 加息周期慢熊阴跌',
      ),
      '2024-08' => w(
        '2024 August Yen Carry Unwind',
        '2024 年 8 月日元套息平仓闪崩',
      ),
      '2025-04' => w(
        '2025 April Tariff Crash',
        '2025 年 4 月关税冲击大跌',
      ),
      '2026-08_11_LIVE' => w(
        '2026 Autumn Correction (Live)',
        '2026 秋季回调实战（进行中）',
      ),
      _ => w(text(win['title_en']), text(win['title_zh'])),
    };
  }

  List<Map<String, dynamic>> _currentEventsForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['events_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['events']);
  }

  List<Map<String, dynamic>> _currentLedgerForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['trade_ledgers_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['trade_ledger']);
  }

  Map<String, dynamic>? _findWindow(Map<String, dynamic> doc, String id) {
    for (final wItem in asList(doc['crisis_windows'])) {
      if (text(wItem['id']) == id) return wItem;
    }
    return null;
  }

  Map<String, dynamic> _findStrategySummary(
    Map<String, dynamic> doc,
    String id,
  ) {
    for (final s in asList(doc['strategies_summary'])) {
      if (text(s['id']) == id) return s;
    }
    return const {};
  }

  BoxDecoration _calmSurfaceDecoration() => BoxDecoration(
    color: p.card,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: p.border, width: 1),
  );

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-loading'),
        padding: const EdgeInsets.all(28),
        decoration: _calmSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 2, color: _emerald),
            const SizedBox(height: 14),
            Text(
              w('Loading Crisis Observatory...', '正在加载危机观测数据...'),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-error'),
        padding: const EdgeInsets.all(24),
        decoration: _calmSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Crisis Observatory data is temporarily unavailable.',
                '危机观测数据暂时无法加载。',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('crisis-observatory-retry'),
              onPressed: () => unawaited(_loadObservatory()),
              child: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final doc = data ?? const <String, dynamic>{};
    final topDoc = _resolveEffectiveTopDoc(doc);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final desktop = constraints.maxWidth >= 960;
        final gap = compact ? 18.0 : 24.0;
        final m7Dash = _resolveM7LiveDashboard(topDoc);
        return Column(
          key: const ValueKey('crisis-observatory-root'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTopProfileAndProvenanceHeader(
              doc,
              compact: compact,
              desktop: desktop,
            ),
            SizedBox(height: compact ? 12 : 16),
            _buildVerdictBlock(
              topDoc,
              fullDoc: doc,
              compact: compact,
              desktop: desktop,
            ),
            SizedBox(height: gap),
            if (m7Dash.isNotEmpty)
              _buildThreePillarBlock(
                topDoc,
                fullDoc: doc,
                m7Dash: m7Dash,
                maxWidth: constraints.maxWidth,
                compact: compact,
                desktop: desktop,
              ),
            SizedBox(height: gap),
            _buildHeroChartBlock(doc, compact: compact, desktop: desktop),
            SizedBox(height: gap),
            _buildCrisisStoryAndTimelineBlock(
              doc,
              compact: compact,
              desktop: desktop,
            ),
          ],
        );
      },
    );
  }

  Widget _buildTopProfileAndProvenanceHeader(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final prov = asMap(doc['pricing_provenance']);
    final stripEn = text(prov['strip_en']).isNotEmpty
        ? text(prov['strip_en'])
        : '2015-01-02 to 2025-12-15: MIT Real QQQ OPRA Chain (9.88M Quotes, 0 Fallbacks) · 2025-12-16 to Live: OPRA-Calibrated BSM';
    final stripZh = text(prov['strip_zh']).isNotEmpty
        ? text(prov['strip_zh'])
        : '2015-01-02 至 2025-12-15：MIT 真实 QQQ OPRA 期权盘口（987.5万条报价，0回退） · 2025-12-16 至 实时：OPRA实盘校准 BSM';

    final isFullActive =
        selectedStrategyId == 'M7G_Graded' &&
        selectedProfile == 'full_m7_adaptive';
    final isCore3Active = _isCore3;

    final fullCard = _buildProfileOptionCard(
      profileId: 'full_m7_adaptive',
      active: isFullActive,
      accent: _emerald,
      title: w(
        '🛡️ Full M7 Shield · Recommended (0.20% + 1.25%)',
        '🛡️ 全套 M7 护盾 · 默认推荐（0.20% + 1.25%）',
      ),
      summary: w(
        'Locked 0.20% Base (VIX<=20, 125->75D) + 1.25%/slot M7G (125->75D / CTA 90->30D) + Near-ITM 1.05×K TP + 5D Lockout',
        '写死 0.20% 常态基底(VIX≤20, 125→75D) + 1.25%/槽 6维M7G(125→75D / CTA 90→30D) + 准实值止盈 + 5天倒挂禁买锁',
      ),
      metricsLine: w(
        '2015–2025 Real OPRA: IBKR Limit \$1,740,267 (+\$454K vs QQQ) · Ask/Bid \$1,688,420 · CAGR 21.85% · MDD -26.17% · Calmar 0.835 · PF 2.28x',
        '2015–2025 真实 OPRA：IBKR限价 \$1,740,267（超额 +\$454K）· 严格盘口 \$1,688,420 · 年化 21.85% · 回撤 -26.17% · 卡玛 0.835 · 盈亏比 2.28x',
      ),
      compact: compact,
    );

    final core3Card = _buildProfileOptionCard(
      profileId: 'core3_adaptive',
      active: isCore3Active,
      accent: _sky,
      title: w(
        '⚡ Core-3 Minimal · Low Freq (0.20% + 1.25%)',
        '⚡ 精简 3 核 · 低频对照（0.20% + 1.25%）',
      ),
      summary: w(
        '0.20% Base (VIX<=20) + 1.25%/slot Core-3 (M0+M6+M4 Only) · Adaptive Hard Roll + Near-ITM TP + 5D Lockout; omits exogenous P2/M3 sensors',
        '0.20% 常态基底(VIX≤20) + 1.25%/槽精简3核(仅 M0+M6+M4) · 硬滚仓 + 准实值止盈 + 5天禁买锁；不含外生突发预警',
      ),
      metricsLine: w(
        '2015–2025 Real OPRA: IBKR Limit \$1,514,395 (+\$228K vs QQQ) · Ask/Bid \$1,478,049 · MDD -28.08% · Calmar 0.724 · PF 1.56x · 100 trades',
        '2015–2025 真实 OPRA：IBKR限价 \$1,514,395（超额 +\$228K）· 严格盘口 \$1,478,049 · 回撤 -28.08% · 卡玛 0.724 · 盈亏比 1.56x · 100 笔',
      ),
      compact: compact,
    );

    return Column(
      key: const ValueKey('crisis-profile-switcher'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (desktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: fullCard),
                const SizedBox(width: 12),
                Expanded(child: core3Card),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              fullCard,
              const SizedBox(height: 10),
              core3Card,
            ],
          ),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('crisis-data-provenance-strip'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14,
            vertical: compact ? 8 : 9,
          ),
          decoration: BoxDecoration(
            color: _emerald.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _emerald.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(
                Icons.verified_outlined,
                size: 15,
                color: _emerald,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w(stripEn, stripZh),
                  style: TextStyle(
                    color: p.text,
                    fontSize: compact ? 11.2 : 11.8,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('crisis-locked-ruleset-strip'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 14,
            vertical: compact ? 8 : 9,
          ),
          decoration: BoxDecoration(
            color: p.text.withValues(alpha: 0.028),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: _emerald,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      w(
                        'Hard-Coded Production Ruleset: Book B 0.20% (VIX<=20 Gate, 125->75D) + Book M 1.25%/slot + Near-ITM 1.05×K TP + 5D VIX/3M<1.00 Lockout',
                        '实盘写死双账本规则：Book B 0.20% 常态盾（VIX≤20 门控 · 125→75D） + Book M 1.25%/槽固定预算 + 1.05×K 准实值清仓 + 止盈后连续 5 天 VIX/3M<1.00 解锁',
                      ),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: compact ? 11.0 : 11.4,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                key: const ValueKey('crisis-fill-mode-bar'),
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Execution Fill:', '回测/实盘撮合：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final fid in _fillModeIds)
                    InkWell(
                      key: ValueKey('crisis-fill-pill-$fid'),
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => _selectFillMode(fid),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8.5,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selectedFillMode == fid
                              ? _emerald.withValues(alpha: 0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: selectedFillMode == fid
                                ? _emerald.withValues(alpha: 0.72)
                                : p.border,
                          ),
                        ),
                        child: Text(
                          _humanFillModeLabel(fid),
                          style: TextStyle(
                            color: selectedFillMode == fid ? p.text : p.muted,
                            fontSize: 11.0,
                            fontWeight: selectedFillMode == fid
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProfileOptionCard({
    required String profileId,
    required bool active,
    required Color accent,
    required String title,
    required String summary,
    required String metricsLine,
    required bool compact,
  }) {
    return InkWell(
      key: ValueKey('crisis-profile-$profileId'),
      borderRadius: BorderRadius.circular(13),
      onTap: () => _selectProfile(profileId),
      child: Container(
        padding: EdgeInsets.all(compact ? 13 : 16),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.08) : p.card,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: active ? accent.withValues(alpha: 0.72) : p.border,
            width: active ? 1.4 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 14 : 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.15,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? accent.withValues(alpha: 0.18)
                        : p.text.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: active ? accent.withValues(alpha: 0.55) : p.border,
                    ),
                  ),
                  child: Text(
                    active ? w('ACTIVE', '当前启用') : w('SELECT', '点击切换'),
                    style: TextStyle(
                      color: active ? accent : p.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              summary,
              style: TextStyle(
                color: p.muted,
                fontSize: compact ? 11.8 : 12.2,
                height: 1.42,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              metricsLine,
              style: TextStyle(
                color: active ? accent : p.text.withValues(alpha: 0.85),
                fontSize: compact ? 11.0 : 11.4,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _resolveM7LiveDashboard(Map<String, dynamic> doc) {
    final byStrat = asMap(doc['m7_live_dashboards_by_strategy']);
    final key = selectedStrategyId == 'Core3_Adaptive'
        ? 'Core3_Adaptive'
        : (selectedStrategyId == 'M7_Ensemble' ? 'M7_Ensemble' : 'M7G_Graded');
    final found = asMap(byStrat[key]);
    if (found.isNotEmpty) return found;
    return asMap(doc['m7_live_dashboard']);
  }

  // ===========================================================================
  // BLOCK 1: Clean Verdict Header (今日信号结论 · M7-Graded Command Deck)
  // ===========================================================================
  Widget _buildVerdictBlock(
    Map<String, dynamic> doc, {
    required Map<String, dynamic> fullDoc,
    required bool compact,
    required bool desktop,
  }) {
    final m7Dash = _resolveM7LiveDashboard(doc);
    if (_isM7Strategy && m7Dash.isNotEmpty) {
      return _buildM7VerdictBlock(
        doc,
        fullDoc: fullDoc,
        m7Dash: m7Dash,
        compact: compact,
        desktop: desktop,
      );
    }
    final snap = asMap(doc['live_market_snapshot']);
    final sigByStrat = asMap(doc['live_signal_states_by_strategy']);
    final stratSig = asMap(sigByStrat[selectedStrategyId]);
    final sig = stratSig.isNotEmpty
        ? stratSig
        : asMap(doc['live_signal_state']);
    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final asOfDate = text(doc['as_of_date']).isEmpty
        ? widget.asOf
        : text(doc['as_of_date']);

    final qqqClose = _numVal(snap['qqq_close']);
    final ddAth = _numVal(snap['dd_from_ath_pct']);
    final vixRatio = _numVal(snap['vix_vix3m_ratio']);
    final rawLights = _numVal(snap['raw_crisis_score']).round();

    final regimeCode = text(sig['regime_code']);
    final slot1 = asMap(sig['slot1_naked_put']);
    final slot2 = asMap(sig['slot2_collar']);
    final s1OpenMap = asMap(slot1['open_position']);
    final s2OpenMap = asMap(slot2['open_position']);
    final s1Act = asMap(slot1['latest_action']);
    final s2Act = asMap(slot2['latest_action']);
    final gates = asList(sig['gate_checklist']);

    final s1Open = s1OpenMap.isNotEmpty;
    final s1PendingTp = s1Open && s1OpenMap['pending_tp'] == true;
    final s2Open = s2OpenMap.isNotEmpty;
    final s2PendingTp = s2Open && s2OpenMap['pending_tp'] == true;

    final Color statusColor = regimeCode == 'VIX110_TP_TRIGGERED'
        ? _emerald
        : (rawLights >= 5
              ? _coral
              : (rawLights >= 3 || regimeCode.contains('ACTIVE')
                    ? _amber
                    : _emerald));

    final String verdictHeadline = switch (regimeCode) {
      'VIX110_TP_TRIGGERED' => w(
        'Deep-ITM Panic Harvest Armed · Monetize Put Next Open ($rawLights/6 Lights)',
        '深跌实值恐慌触发 · 期权次日开盘止盈换股（$rawLights/6 亮灯）',
      ),
      'DUAL_SLOT_FULL_SHIELD' => w(
        'Full Hedge Active · Naked Put + Collar On',
        '双槽满盾保护中 · 首仓裸 Put + 次仓领口',
      ),
      'SLOT1_NAKED_PUT_ACTIVE' => w(
        'Early Warning · First-Half Naked Put Active',
        '高位预警 · 首仓 50% 裸 Put 保护中',
      ),
      'LOW_SPOT_FREEZE_NO_NEW_COLLAR' => w(
        '100% Hold QQQ · Call Caps Paused in Pullback ($rawLights/6 Lights)',
        '100% 持有 QQQ · 低位暂停新卖 Call（$rawLights/6 亮灯）',
      ),
      _ => w(
        'Calm Trend · 100% Hold QQQ ($rawLights/6 Lights)',
        '顺风区间 · 100% 持有 QQQ（$rawLights/6 亮灯）',
      ),
    };

    final totalLastHarvest =
        _numVal(s1Act['u1_net_pnl_usd']) + _numVal(s2Act['u1_net_pnl_usd']);
    final totalLastShares =
        _numVal(s1Act['u1_shares_added']) + _numVal(s2Act['u1_shares_added']);
    final lastExitDate = text(s2Act['exit_date']).length >= 10
        ? text(s2Act['exit_date']).substring(5)
        : (text(s1Act['exit_date']).length >= 10
              ? text(s1Act['exit_date']).substring(5)
              : '');

    final String humanSummary;
    if (regimeCode == 'VIX110_TP_TRIGGERED') {
      final armedMap = s1PendingTp ? s1OpenMap : s2OpenMap;
      final armedPnl = _numVal(armedMap['mtm_pnl_usd']);
      final armedSh = _numVal(armedMap['est_shares_added']);
      final armedKp = _numVal(armedMap['kp']);
      final armedSpot = _numVal(armedMap['mtm_spot'], qqqClose);
      final s2Pnl = _numVal(s2Act['u1_net_pnl_usd']);
      final s2Date = text(s2Act['exit_date']).length >= 10
          ? text(s2Act['exit_date']).substring(5)
          : '';
      humanSummary = w(
        '${s2Pnl > 0 && s2Date.isNotEmpty ? 'Collar already banked ${_fmtUsd(s2Pnl, signed: true)} on $s2Date and freed the Call cap; ' : ''}active Put (K=\$${armedKp.toStringAsFixed(0)}) ignored the shallow inversion and is now deep ITM at \$${armedSpot.toStringAsFixed(0)} — armed to monetize ${_fmtUsd(armedPnl, signed: true)} (+${armedSh.toStringAsFixed(1)} QQQ sh) at next Open.',
        '${s2Pnl > 0 && s2Date.isNotEmpty ? '$s2Date 次仓领口已先行落袋 ${_fmtUsd(s2Pnl, signed: true)} 并解除卖 Call 封顶；' : ''}持仓保护（行权 \$${armedKp.toStringAsFixed(0)}）无视前期浅倒挂，今日深跌实值至 \$${armedSpot.toStringAsFixed(0)} 触发止盈（浮盈 ${_fmtUsd(armedPnl, signed: true)} / +${armedSh.toStringAsFixed(1)} 股待次日开盘换股）。',
      );
    } else if (regimeCode == 'LOW_SPOT_FREEZE_NO_NEW_COLLAR') {
      humanSummary = w(
        '${lastExitDate.isNotEmpty && totalLastHarvest > 0 ? 'Harvested ${_fmtUsd(totalLastHarvest, signed: true)} (+${totalLastShares.toStringAsFixed(1)} extra QQQ shares) on $lastExitDate panic spike; ' : ''}new Call caps stay paused below -5% drawdown while holding 100% QQQ for full rebound upside.',
        '${lastExitDate.isNotEmpty && totalLastHarvest > 0 ? '$lastExitDate 已在恐慌倒挂中止盈落袋 ${_fmtUsd(totalLastHarvest, signed: true)}（低位增持 +${totalLastShares.toStringAsFixed(1)} 股 QQQ）；' : ''}当前跌离高点超 5% 暂停新卖 Call，100% 满仓 QQQ 完整保留反弹空间。',
      );
    } else if (regimeCode == 'DUAL_SLOT_FULL_SHIELD' ||
        regimeCode == 'SLOT1_NAKED_PUT_ACTIVE') {
      humanSummary = w(
        'Protective puts are in place near market highs; hold 100% QQQ until ${_humanTpModeLabel(selectedTpMode)} take-profit triggers to monetize into extra shares.',
        '高位看跌保护已就位；底仓 100% 持有 QQQ，按当前「${_humanTpModeLabel(selectedTpMode)}」规则等待止盈触发并抄底增持正股。',
      );
    } else {
      humanSummary = w(
        'Hold 100% QQQ with zero option drag until top breadth divergence or 4+ crisis lights appear near highs.',
        '保持 100% QQQ 现货复利、零期权损耗，静待高位出现市场宽度背离或 4 盏以上危机灯再买保护。',
      );
    }

    // 3 plain-human pure-options status columns (Core QQQ + Slot 1 + Slot 2)
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final totalShares = _numVal(stratSummary['final_shares'], 2719.32);
    final bhShares = _numVal(
      stratSummary['bh_final_shares'],
      _numVal(bhSummary['final_shares'], 2117.34),
    );
    final extraShares = _numVal(
      stratSummary['extra_shares_vs_bh'],
      totalShares - bhShares,
    );
    final extraSharesPct = _numVal(
      stratSummary['extra_shares_pct'],
      bhShares > 0 ? (extraShares / bhShares) * 100.0 : 0.0,
    );
    final coreValue = w(
      '100% QQQ · ${_fmtShares(totalShares)} sh',
      '100% 满仓 QQQ · ${_fmtShares(totalShares)} 股',
    );
    final coreSub = w(
      'vs ${_fmtShares(bhShares)} sh BH · ${_fmtShares(extraShares, signed: true)} sh (${_fmtPct(extraSharesPct)})',
      '基准 ${_fmtShares(bhShares)} 股 · 累计多买 ${_fmtShares(extraShares, signed: true)} 股（${_fmtPct(extraSharesPct)}）',
    );

    final s1Value = s1PendingTp
        ? w(
            'TP Armed ${_fmtUsd(_numVal(s1OpenMap['mtm_pnl_usd']), signed: true)} · Next Open',
            '实值止盈已触发 ${_fmtUsd(_numVal(s1OpenMap['mtm_pnl_usd']), signed: true)}',
          )
        : (s1Open
              ? w('Active Hedge', '保护运行中')
              : (_numVal(s1Act['u1_net_pnl_usd']) > 0
                    ? w(
                        'Harvested ${_fmtUsd(_numVal(s1Act['u1_net_pnl_usd']), signed: true)} · Standby',
                        '已止盈 ${_fmtUsd(_numVal(s1Act['u1_net_pnl_usd']), signed: true)} · 待命',
                      )
                    : w('Standby', '待命')));
    final s1Sub = s1Open
        ? w(
            '${text(s1OpenMap['entry_date']).length >= 10 ? text(s1OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s1OpenMap['entry_spot']).toStringAsFixed(0)} (K=\$${_numVal(s1OpenMap['kp']).toStringAsFixed(0)}) · ${_numVal(s1OpenMap['rem_dte']).round()}D left · +${_numVal(s1OpenMap['est_shares_added']).toStringAsFixed(1)} sh',
            '${text(s1OpenMap['entry_date']).length >= 10 ? text(s1OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s1OpenMap['entry_spot']).toStringAsFixed(0)} 开（行权 \$${_numVal(s1OpenMap['kp']).toStringAsFixed(0)}）· 剩 ${_numVal(s1OpenMap['rem_dte']).round()} 天 · +${_numVal(s1OpenMap['est_shares_added']).toStringAsFixed(1)} 股',
          )
        : (text(s1Act['entry_date']).length >= 10 &&
                  text(s1Act['exit_date']).length >= 10
              ? w(
                  '${text(s1Act['entry_date']).substring(5)} @\$${_numVal(s1Act['entry_spot']).toStringAsFixed(0)} -> ${text(s1Act['exit_date']).substring(5)} @\$${_numVal(s1Act['exit_spot']).toStringAsFixed(0)} (+${_numVal(s1Act['u1_shares_added']).toStringAsFixed(1)} sh)',
                  '${text(s1Act['entry_date']).substring(5)} @\$${_numVal(s1Act['entry_spot']).toStringAsFixed(0)} 开 → ${text(s1Act['exit_date']).substring(5)} @\$${_numVal(s1Act['exit_spot']).toStringAsFixed(0)} 平（+${_numVal(s1Act['u1_shares_added']).toStringAsFixed(1)} 股）',
                )
              : w('50% size · No upside Call cap', '50% 仓位 · 不卖 Call 保留冲顶'));

    final s2Frozen = text(slot2['status']).contains('FROZEN');
    final s2Value = s2PendingTp
        ? w(
            'TP Armed ${_fmtUsd(_numVal(s2OpenMap['mtm_pnl_usd']), signed: true)} · Next Open',
            '止盈已触发 ${_fmtUsd(_numVal(s2OpenMap['mtm_pnl_usd']), signed: true)}',
          )
        : (s2Open
              ? w('Active Collar', '领口保护中')
              : (s2Frozen
                    ? (_numVal(s2Act['u1_net_pnl_usd']) > 0
                          ? w(
                              'Harvested ${_fmtUsd(_numVal(s2Act['u1_net_pnl_usd']), signed: true)} · Paused',
                              '已止盈 ${_fmtUsd(_numVal(s2Act['u1_net_pnl_usd']), signed: true)} · 低位暂停',
                            )
                          : w('Paused Below -5%', '低位暂停卖 Call'))
                    : w('Standby (30D Step)', '待命（满 30 天开启）')));
    final s2Sub = s2Open
        ? w(
            '${text(s2OpenMap['entry_date']).length >= 10 ? text(s2OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s2OpenMap['entry_spot']).toStringAsFixed(0)} (K=\$${_numVal(s2OpenMap['kp']).toStringAsFixed(0)}) · ${_numVal(s2OpenMap['rem_dte']).round()}D left',
            '${text(s2OpenMap['entry_date']).length >= 10 ? text(s2OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s2OpenMap['entry_spot']).toStringAsFixed(0)} 开（行权 \$${_numVal(s2OpenMap['kp']).toStringAsFixed(0)}）· 剩 ${_numVal(s2OpenMap['rem_dte']).round()} 天',
          )
        : (text(s2Act['entry_date']).length >= 10 &&
                  text(s2Act['exit_date']).length >= 10
              ? w(
                  '${text(s2Act['entry_date']).substring(5)} @\$${_numVal(s2Act['entry_spot']).toStringAsFixed(0)} -> ${text(s2Act['exit_date']).substring(5)} @\$${_numVal(s2Act['exit_spot']).toStringAsFixed(0)} (+${_numVal(s2Act['u1_shares_added']).toStringAsFixed(1)} sh)',
                  '${text(s2Act['entry_date']).substring(5)} @\$${_numVal(s2Act['entry_spot']).toStringAsFixed(0)} 开 → ${text(s2Act['exit_date']).substring(5)} @\$${_numVal(s2Act['exit_spot']).toStringAsFixed(0)} 平（+${_numVal(s2Act['u1_shares_added']).toStringAsFixed(1)} 股）',
                )
              : w('Zero-cost Put + Call collar', '零成本领口保护'));

    return Container(
      key: const ValueKey('crisis-observatory-command-center'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: pinnedPitDate != null
          ? BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _sky.withValues(alpha: 0.45)),
            )
          : _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pinnedPitDate != null)
            _buildPitReplayBanner(
              fullDoc,
              doc,
              keyPrefix: 'cmd',
              compact: compact,
              showStepButtons: false,
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      verdictHeadline,
                      style: TextStyle(
                        color: p.text,
                        fontSize: compact ? 17 : 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InkWell(
                    key: const ValueKey('crisis-observatory-qqq-chip'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onCompany('QQQ'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'QQQ \$${qqqClose.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    w(
                      '· ${_fmtPct(ddAth)} off high · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                      '· 距高点 ${_fmtPct(ddAth)} · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            humanSummary,
            style: TextStyle(
              color: p.muted,
              fontSize: compact ? 13 : 13.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Container(height: 1, color: p.border),
          const SizedBox(height: 16),
          if (desktop)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'core',
                      label: w('Core Equity Position', '现货底仓'),
                      value: coreValue,
                      sub: coreSub,
                      accent: p.text,
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    color: p.border,
                  ),
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'slot1',
                      label: w('First-Half Naked Put (50%)', '首仓裸 Put（50%）'),
                      value: s1Value,
                      sub: s1Sub,
                      accent: s1PendingTp ? _emerald : (s1Open ? _amber : _emerald),
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    color: p.border,
                  ),
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'slot2',
                      label: w('Second-Half Collar (50%)', '次仓领口（50%）'),
                      value: s2Value,
                      sub: s2Sub,
                      accent: s2PendingTp
                          ? _emerald
                          : (s2Open ? _amber : (s2Frozen ? p.text : _emerald)),
                    ),
                  ),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMinimalSlotColumn(
                  keyId: 'core',
                  label: w('Core Equity Position', '现货底仓'),
                  value: coreValue,
                  sub: coreSub,
                  accent: p.text,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(height: 1, color: p.border),
                ),
                _buildMinimalSlotColumn(
                  keyId: 'slot1',
                  label: w('First-Half Naked Put (50%)', '首仓裸 Put（50%）'),
                  value: s1Value,
                  sub: s1Sub,
                  accent: s1PendingTp ? _emerald : (s1Open ? _amber : _emerald),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(height: 1, color: p.border),
                ),
                _buildMinimalSlotColumn(
                  keyId: 'slot2',
                  label: w('Second-Half Collar (50%)', '次仓领口（50%）'),
                  value: s2Value,
                  sub: s2Sub,
                  accent: s2PendingTp
                      ? _emerald
                      : (s2Open ? _amber : (s2Frozen ? p.text : _emerald)),
                ),
              ],
            ),
          const SizedBox(height: 14),
          _buildLiveEngine3Strip(doc, snap),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                key: const ValueKey('crisis-rules-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    setState(() => showRulesDisclosure = !showRulesDisclosure),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        showRulesDisclosure
                            ? w('Hide Trigger Rules', '收起触发条件')
                            : w('View Trigger Rules', '查看触发条件'),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        showRulesDisclosure
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: p.muted,
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                w(
                  'Take-Profit: ${_humanTpModeLabel(selectedTpMode)}${selectedCcMode != 'cc_off' ? ' · CC: ${_humanCcModeLabel(selectedCcMode)}' : ''}${selectedSpMode != 'sp_off' ? ' · Wheel: ${_humanSpModeLabel(selectedSpMode)} (${_humanWcModeShort(selectedWcMode)})' : ''}',
                  '止盈：${_humanTpModeLabel(selectedTpMode)}${selectedCcMode != 'cc_off' ? ' · 卖 Call：${_humanCcModeLabel(selectedCcMode)}' : ''}${selectedSpMode != 'sp_off' ? ' · 卖 Put Wheel：${_humanSpModeLabel(selectedSpMode)}（${_humanWcModeShort(selectedWcMode)}）' : ''}',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (showRulesDisclosure) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 18,
                    runSpacing: 8,
                    children: [
                      for (final g in gates) _buildCalmGateItem(g),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    w(
                      'Execution rules: 1) Hold 100% QQQ forever. 2) Within 5% of ATH with calm volatility (VXN <= 22) and either AD < 50DMA or >= 4 lights -> buy 50% 90-day -10% Put (no Call cap). 3) After 30 days if still active -> add 50% zero-cost Collar. 4) Selectable Take-Profit (${_humanTpModeLabel(selectedTpMode)}): ${_humanTpModeHint(selectedTpMode)}. 5) Never open new Collars below -5% drawdown.',
                      '实战规则：① 底仓 100% 持有 QQQ 永不卖股；② 距高点 5% 内、波动率 VXN ≤ 22，且涨跌线跌破 50 日线或亮起 ≥ 4 盏灯 → 次日开盘买 50% 仓位 90 天 -10% 裸 Put（不卖封顶）；③ 满 30 天仍预警 → 补齐 50% 零成本领口；④ 可选止盈模式（${_humanTpModeLabel(selectedTpMode)}）：${_humanTpModeHint(selectedTpMode)}；⑤ 跌离高点超 5% 严禁新卖 Call。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveEngine3Strip(
    Map<String, dynamic> doc,
    Map<String, dynamic> snap,
  ) {
    final spByStrat = asMap(doc['live_sp_states_by_strategy']);
    final stratKey = selectedStrategyId == 'BH_Pure_QQQ'
        ? 'M7G_Graded'
        : selectedStrategyId;
    final stratSp = asMap(spByStrat[stratKey]);
    final spState = stratSp.isNotEmpty ? stratSp : asMap(doc['live_sp_state']);

    final vix = _numVal(spState['vix'], _numVal(snap['vix']));
    final vixChg = _numVal(spState['vix_change'], _numVal(snap['vix_change']));
    final vixFalling = spState['vix_falling'] == true;
    final vixRatio = _numVal(
      spState['vix_vix3m_ratio'],
      _numVal(snap['vix_vix3m_ratio']),
    );
    final inverted = vixRatio >= 1.0;
    final tone = text(spState['status_tone']);
    final enabled = selectedSpMode != 'sp_off';

    final Color accent = !enabled
        ? (inverted ? _amber : p.muted)
        : (tone == 'wheel'
              ? _amber
              : (tone == 'active' ? _emerald : p.muted));

    final vixDeltaTxt =
        '${vixChg >= 0 ? '+' : ''}${vixChg.toStringAsFixed(2)} ${vixFalling ? w('falling', '回落') : w('rising', '上行')}';
    final badgeText = enabled && text(spState['badge_en']).isNotEmpty
        ? w(text(spState['badge_en']), text(spState['badge_zh']))
        : (inverted
              ? w(
                  'Engine 3 Off · VIX/3M ${vixRatio.toStringAsFixed(2)} Inverted · VIX ${vix.toStringAsFixed(2)} ($vixDeltaTxt) — Enable 14D 10% Cap below',
                  '第三引擎未开启 · VIX/3M ${vixRatio.toStringAsFixed(2)} 倒挂触发 · VIX ${vix.toStringAsFixed(2)}（日变动 $vixDeltaTxt）— 可在下方开启 14D 10%帽',
                )
              : w(
                  'Engine 3 Off · VIX/3M ${vixRatio.toStringAsFixed(2)} Contango (< 1.00) · VIX ${vix.toStringAsFixed(2)} ($vixDeltaTxt)',
                  '第三引擎未开启 · VIX/3M ${vixRatio.toStringAsFixed(2)} 正常顺水（< 1.00）· VIX ${vix.toStringAsFixed(2)}（$vixDeltaTxt）',
                ));
    final detailText = enabled ? w(text(spState['detail_en']), text(spState['detail_zh'])) : '';

    return Container(
      key: const ValueKey('crisis-sp-live-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: enabled
            ? accent.withValues(alpha: 0.07)
            : p.text.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: enabled ? accent.withValues(alpha: 0.38) : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      enabled
                          ? w(
                              'Engine 3 Live (${_humanSpModeLabel(selectedSpMode)} · ${_humanWcModeShort(selectedWcMode)}): $badgeText',
                              '第三引擎实盘状态（${_humanSpModeLabel(selectedSpMode)} · ${_humanWcModeShort(selectedWcMode)}）：$badgeText',
                            )
                          : badgeText,
                      style: TextStyle(
                        color: enabled ? p.text : p.muted,
                        fontSize: 12,
                        fontWeight: enabled ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              if (enabled)
                Text(
                  'VIX/3M ${vixRatio.toStringAsFixed(2)} · VIX ${vix.toStringAsFixed(2)} ($vixDeltaTxt)',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
            ],
          ),
          if (detailText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(
                detailText,
                style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.35),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMinimalSlotColumn({
    required String keyId,
    required String label,
    required String value,
    required String sub,
    required Color accent,
  }) {
    return Column(
      key: ValueKey('crisis-slot-card-$keyId'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _buildCalmGateItem(Map<String, dynamic> gate) {
    final passed = gate['passed'] == true;
    final label = w(text(gate['label_en']), text(gate['label_zh']));
    final reading = text(gate['reading']);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: passed ? _emerald : p.muted.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$label: $reading',
          style: TextStyle(
            color: passed ? p.text : p.muted,
            fontSize: 12,
            fontWeight: passed ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  Widget _buildM7VerdictBlock(
    Map<String, dynamic> doc, {
    required Map<String, dynamic> fullDoc,
    required Map<String, dynamic> m7Dash,
    required bool compact,
    required bool desktop,
  }) {
    final snap = asMap(doc['live_market_snapshot']);
    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final asOfDate = text(m7Dash['as_of_date']).isNotEmpty
        ? text(m7Dash['as_of_date'])
        : (text(doc['as_of_date']).isEmpty ? widget.asOf : text(doc['as_of_date']));

    final qqqClose = _numVal(
      asMap(m7Dash['sizing_calculator'])['qqq_spot'],
      _numVal(snap['qqq_close']),
    );
    final ddAth = _numVal(snap['dd_from_ath_pct']);
    final vxnNow = _numVal(
      asMap(m7Dash['redline'])['vxn'],
      _numVal(snap['vxn']),
    );
    final vixRatio = _numVal(
      asMap(m7Dash['redline'])['vix_ratio'],
      _numVal(snap['vix_vix3m_ratio']),
    );

    final crisisProb = _numVal(m7Dash['crisis_prob']).round();
    final p1Score = _numVal(m7Dash['p1_score']).round();
    final p2Score = _numVal(m7Dash['p2_score']).round();
    final p3Score = _numVal(m7Dash['p3_score']).round();
    final liveStress = _numVal(m7Dash['live_stress_index']).round();
    final stressLblEn = text(m7Dash['live_stress_label_en']).isNotEmpty
        ? text(m7Dash['live_stress_label_en'])
        : _stressLevelFallbackEn(liveStress);
    final stressLblZh = text(m7Dash['live_stress_label_zh']).isNotEmpty
        ? text(m7Dash['live_stress_label_zh'])
        : _stressLevelFallbackZh(liveStress);
    final stressBreakdown = asMap(m7Dash['live_stress_breakdown']);
    final rvPts = _numVal(stressBreakdown['regime_vol']);
    final tdPts = _numVal(stressBreakdown['trend_dd']);
    final cmPts = _numVal(stressBreakdown['credit_macro']);
    final btPts = _numVal(stressBreakdown['breadth_tail']);
    final volBlockedCount = _numVal(m7Dash['vol_blocked_sensor_count']).round();
    final warmingCount = _numVal(m7Dash['warming_count']).round();
    final freshness = asMap(m7Dash['data_freshness']);
    final yahooDate = text(freshness['yahoo_eod_date']).isNotEmpty
        ? text(freshness['yahoo_eod_date'])
        : asOfDate;
    final baaDate = text(freshness['fred_baa_date']);
    final nfciDate = text(freshness['fred_nfci_date']);
    final adDate = text(freshness['ad_line_date']);
    final isPitFresh =
        freshness['is_pit_replay'] == true || pinnedPitDate != null;

    final targetSlots = _numVal(m7Dash['target_slots']).round();
    final activeSlots = _numVal(m7Dash['active_slots']).round();
    final maxSlots = math.max(1, _numVal(m7Dash['max_slots'], 3).round());
    final bookBGate = asMap(m7Dash['book_b_vix_gate']);
    final lockoutMap = asMap(m7Dash['post_tp_lockout']);
    final baseActiveSlots = _numVal(
      m7Dash['base_active_slots'] ?? bookBGate['active_slots'],
    ).round();
    final vixNow = _numVal(bookBGate['vix'], _numVal(snap['vix']));
    final bookBVixOk = bookBGate['vix_ok'] != null
        ? bookBGate['vix_ok'] == true
        : vixNow <= 20.0;
    final lockoutLocked = lockoutMap['locked'] == true;
    final lockoutStreak = _numVal(lockoutMap['non_inverted_streak']).round();
    final lockoutReq = math.max(
      1,
      _numVal(lockoutMap['required_streak'], 5).round(),
    );
    final lockoutEpisodes = _numVal(lockoutMap['episodes_count'], 6).round();
    final lockoutDaysTot = _numVal(lockoutMap['days_total'], 91).round();
    final bookBGateOpen = bookBGate['gate_open'] != null
        ? bookBGate['gate_open'] == true
        : (bookBVixOk && vixRatio < 1.02 && !lockoutLocked);

    final redline = asMap(m7Dash['redline']);
    final redlineBlocked = redline['blocked'] == true;
    final cooldown = asMap(m7Dash['cooldown']);
    final cooldownPassed = cooldown['passed'] == true;
    final t1 = asMap(m7Dash['t1_action']);
    final t1Code = text(t1['code']);
    final t1Badge = w(text(t1['badge_en']), text(t1['badge_zh']));
    final t1Title = w(text(t1['title_en']), text(t1['title_zh']));

    final Color statusColor = t1Code.contains('TP') || t1Code.contains('HARVEST')
        ? _emerald
        : (liveStress >= 75 || redlineBlocked
              ? _coral
              : (liveStress >= 50 || crisisProb >= 45 || activeSlots >= 2
                    ? _amber
                    : (liveStress >= 25 || crisisProb >= 35 || activeSlots >= 1
                          ? _sky
                          : _emerald)));

    final totalShares = _numVal(stratSummary['final_shares'], 2764.81);
    final bhShares = _numVal(
      stratSummary['bh_final_shares'],
      _numVal(bhSummary['final_shares'], 2117.34),
    );
    final extraShares = _numVal(
      stratSummary['extra_shares_vs_bh'],
      totalShares - bhShares,
    );
    final extraSharesPct = _numVal(
      stratSummary['extra_shares_pct'],
      bhShares > 0 ? (extraShares / bhShares) * 100.0 : 0.0,
    );

    final tpMon = asMap(m7Dash['tp_monitor']);
    final openSlots = asList(tpMon['open_slots']);
    final firstOpen = openSlots.isNotEmpty ? openSlots.first : const <String, dynamic>{};
    final fiveXMaxDte = _numVal(
      tpMon['five_x_max_dte'],
      45,
    ).round();

    final stressAccent = _stressAccent(liveStress);
    final probAccent = crisisProb >= 65
        ? _coral
        : (crisisProb >= 35
              ? _amber
              : (redlineBlocked ? _coral : _emerald));

    Widget buildBreakdownChip(String lbl, Color chipColor) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2.5),
        decoration: BoxDecoration(
          color: p.text.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
        ),
        child: Text(
          lbl,
          style: TextStyle(
            color: chipColor,
            fontSize: 10.8,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final stressTrackCard = Container(
      key: const ValueKey('crisis-m7-stress-track'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: stressAccent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: stressAccent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'Real-Time Crisis Stress (0–100)',
                  '实时危机压力指数（连续 0–100 · 不受低波门控清零）',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: stressAccent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: stressAccent.withValues(alpha: 0.5)),
                ),
                child: Text(
                  w(stressLblEn, stressLblZh),
                  style: TextStyle(
                    color: stressAccent,
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '$liveStress%',
                style: TextStyle(
                  color: stressAccent,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: (liveStress / 100.0).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: p.border,
                    color: stressAccent,
                  ),
                ),
              ),
            ],
          ),
          if (stressBreakdown.isNotEmpty) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                buildBreakdownChip(
                  w(
                    'Vol/HMM ${rvPts.toStringAsFixed(0)}/30',
                    '状态波动 ${rvPts.toStringAsFixed(0)}/30',
                  ),
                  rvPts >= 15 ? stressAccent : p.muted,
                ),
                buildBreakdownChip(
                  w(
                    'Trend/DD ${tdPts.toStringAsFixed(0)}/25',
                    '趋势回撤 ${tdPts.toStringAsFixed(0)}/25',
                  ),
                  tdPts >= 12 ? stressAccent : p.muted,
                ),
                buildBreakdownChip(
                  w(
                    'Credit/Macro ${cmPts.toStringAsFixed(0)}/25',
                    '信用宏观 ${cmPts.toStringAsFixed(0)}/25',
                  ),
                  cmPts >= 12 ? stressAccent : p.muted,
                ),
                buildBreakdownChip(
                  w(
                    'Breadth/Tail ${btPts.toStringAsFixed(0)}/20',
                    '宽度尾部 ${btPts.toStringAsFixed(0)}/20',
                  ),
                  btPts >= 10 ? stressAccent : p.muted,
                ),
              ],
            ),
          ],
        ],
      ),
    );

    final String gateBadgeText = redlineBlocked
        ? w('High-IV Freeze · No Chasing', '高波红线冻结防追高')
        : (crisisProb >= 35
              ? w(
                  'Low-Vol Entry Armed · Target $targetSlots/$maxSlots',
                  '低波击球激活 · 目标 $targetSlots/$maxSlots 槽',
                )
              : w('Low-Vol Gate Open · Standby', '低波窗口开放 · 0槽待命'));
    final Color gateBadgeColor = redlineBlocked
        ? _coral
        : (crisisProb >= 35 ? _amber : _emerald);

    final String readinessNote = volBlockedCount > 0 || warmingCount > 0
        ? w(
            '${volBlockedCount > 0 ? '$volBlockedCount Sensor Red (IV Blocked) · ' : ''}$warmingCount Warming',
            '${volBlockedCount > 0 ? '$volBlockedCount核预警已亮(高波禁追) · ' : ''}$warmingCount核蓄力预热',
          )
        : w('All sensors calm', '各子核平静待命');

    final gateTrackCard = Container(
      key: const ValueKey('crisis-m7-gate-track'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.text.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: redlineBlocked
              ? _coral.withValues(alpha: 0.32)
              : (crisisProb >= 35
                    ? _amber.withValues(alpha: 0.4)
                    : p.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'Low-Vol Put Entry Gate (P1+P2+P3)',
                  '低波买盾执行分（三支柱加总 · 仅低波潜伏买盾）',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: gateBadgeColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: gateBadgeColor.withValues(alpha: 0.48),
                  ),
                ),
                child: Text(
                  gateBadgeText,
                  style: TextStyle(
                    color: gateBadgeColor,
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '$crisisProb%',
                style: TextStyle(
                  color: probAccent,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: (crisisProb / 100.0).clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: p.border,
                    color: probAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'P1 $p1Score/45 · P2 $p2Score/40 · P3 $p3Score/45',
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '· $readinessNote',
                style: TextStyle(
                  color: volBlockedCount > 0
                      ? _coral
                      : (warmingCount > 0 ? _amber : p.muted),
                  fontSize: 11.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final probCard = Container(
      key: const ValueKey('crisis-m7-prob-card'),
      child: !compact
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: stressTrackCard),
                  const SizedBox(width: 12),
                  Expanded(child: gateTrackCard),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                stressTrackCard,
                const SizedBox(height: 10),
                gateTrackCard,
              ],
            ),
    );

    final slotsCard = Column(
      key: const ValueKey('crisis-m7-slots-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Dual-Book Put Slots & Core QQQ', '双账本槽位（0.20% + 1.25%）与底仓'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 5,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              w(
                'B $baseActiveSlots/1 · M $activeSlots/$maxSlots (Tgt $targetSlots)',
                'B盾 $baseActiveSlots/1 · M盾 $activeSlots/$maxSlots（目标$targetSlots）',
              ),
              style: TextStyle(
                color: (activeSlots > 0 || baseActiveSlots > 0)
                    ? _amber
                    : _emerald,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: baseActiveSlots > 0
                    ? _sky.withValues(alpha: 0.18)
                    : p.text.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: baseActiveSlots > 0
                      ? _sky.withValues(alpha: 0.75)
                      : p.border,
                ),
              ),
              child: Text(
                'B0',
                style: TextStyle(
                  color: baseActiveSlots > 0 ? _sky : p.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (var s = 1; s <= maxSlots; s++)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: s <= activeSlots
                      ? _amber.withValues(alpha: 0.18)
                      : (s <= targetSlots
                            ? _sky.withValues(alpha: 0.14)
                            : p.text.withValues(alpha: 0.04)),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: s <= activeSlots
                        ? _amber.withValues(alpha: 0.7)
                        : p.border,
                  ),
                ),
                child: Text(
                  'S$s',
                  style: TextStyle(
                    color: s <= activeSlots ? _amber : p.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          w(
            '100% QQQ · ${_fmtShares(totalShares)} sh (${_fmtPct(extraSharesPct)} vs BH)',
            '100% 满仓 QQQ · ${_fmtShares(totalShares)} 股（较死拿 ${_fmtPct(extraSharesPct)}）',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
      ],
    );

    final redlineCard = Column(
      key: const ValueKey('crisis-m7-redline-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Hard Risk Redline & Cooldown', '硬性禁开红线与阶梯冷却'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          redlineBlocked
              ? w(
                  'BLOCKED · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)}',
                  '红线禁开 · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)}',
                )
              : w(
                  'CLEAR · VXN ${vxnNow.toStringAsFixed(1)}<=27 · VIX/3M ${vixRatio.toStringAsFixed(2)}<1.02',
                  '红线安全 · VXN ${vxnNow.toStringAsFixed(1)}≤27 · VIX/3M ${vixRatio.toStringAsFixed(2)}<1.02',
                ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: redlineBlocked ? _coral : _emerald,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          w(text(cooldown['label_en']), text(cooldown['label_zh'])),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cooldownPassed ? p.muted : _amber,
            fontSize: 11.5,
          ),
        ),
      ],
    );

    final String tpCardSub;
    if (firstOpen.isNotEmpty) {
      final remDte = _numVal(firstOpen['rem_dte']).round();
      final kp = _numVal(firstOpen['kp']);
      final mult = _numVal(firstOpen['roi_mult']);
      final rollFloor = _numVal(firstOpen['roll_floor_dte']).round();
      final daysToRoll = _numVal(
        firstOpen['days_to_roll'] ?? firstOpen['days_to_roll50'],
      ).round();
      final rollCountdown =
          (selectedRollMode == 'adaptive_120_90' ||
                  selectedRollMode == '120d_roll50') &&
              rollFloor > 0
          ? w(
              ' · ${daysToRoll}d to ${rollFloor}D roll',
              ' · 距${rollFloor}D滚仓 $daysToRoll天',
            )
          : '';
      tpCardSub = w(
        'S${_numVal(firstOpen['slot_num']).round()} K=\$${kp.toStringAsFixed(0)} · ${remDte}D left · ${mult.toStringAsFixed(2)}x$rollCountdown',
        'S${_numVal(firstOpen['slot_num']).round()} 行权 \$${kp.toStringAsFixed(0)} · 剩$remDte天 · ${mult.toStringAsFixed(2)}x$rollCountdown',
      );
    } else {
      final nextKp = _numVal(tpMon['simulated_next_slot_kp']);
      tpCardSub = selectedRollMode == 'adaptive_120_90'
          ? w(
              'Next K=\$${nextKp.toStringAsFixed(0)} · Adaptive 125→75 / CTA 90→30',
              '模拟行权 \$${nextKp.toStringAsFixed(0)} · 自适应 125→75 / CTA 90→30',
            )
          : (selectedRollMode == '120d_roll50'
                ? w(
                    'Next K=\$${nextKp.toStringAsFixed(0)} · 5x<=45D · <=50D Roll/Salvage',
                    '模拟行权 \$${nextKp.toStringAsFixed(0)} · 5x≤45D · ≤50D残值滚仓',
                  )
                : w(
                    'Next K=\$${nextKp.toStringAsFixed(0)} · 5x<=${fiveXMaxDte}D Slow-Bear Lock',
                    '模拟行权 \$${nextKp.toStringAsFixed(0)} · 5x≤${fiveXMaxDte}D 慢熊锁利',
                  ));
    }

    final tpCard = Column(
      key: const ValueKey('crisis-m7-tp-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Take-Profit & Hard Roll Monitor', '准实值止盈与硬滚仓阈值'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          selectedM7TpMode == 'itm_tp'
              ? w(
                  'STRICT ITM · VIX/3M ${vixRatio.toStringAsFixed(2)}/1.10 & QQQ<=1.00×K',
                  '严格实值 · VIX/3M ${vixRatio.toStringAsFixed(2)}/1.10 且破 1.00×K',
                )
              : w(
                  'NEAR-ITM 1.05×K · VIX/3M ${vixRatio.toStringAsFixed(2)}/1.10',
                  '准实值 1.05×K · VIX/3M ${vixRatio.toStringAsFixed(2)}/1.10',
                ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: vixRatio >= 1.10 ? _emerald : p.text,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tpCardSub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
      ],
    );

    final bookBGateCard = Column(
      key: const ValueKey('crisis-book-b-gate-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Book B · 0.20% Calm Floor (VIX<=20 Gate)', 'Book B · 0.20% 常态基底（VIX≤20 门控）'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          bookBGateOpen
              ? w(
                  'GATE OPEN · VIX ${vixNow.toStringAsFixed(1)} <= 20 · Active $baseActiveSlots/1',
                  '门控开启 · VIX ${vixNow.toStringAsFixed(1)} ≤ 20 · 在途 $baseActiveSlots/1',
                )
              : (lockoutLocked
                    ? w(
                        'LOCKED (5D Post-TP) · VIX ${vixNow.toStringAsFixed(1)}',
                        '5天禁买锁冻结 · VIX ${vixNow.toStringAsFixed(1)}',
                      )
                    : w(
                        'GATE CLOSED · VIX ${vixNow.toStringAsFixed(1)} > 20 (No Expensive Roll)',
                        '高波禁买 · VIX ${vixNow.toStringAsFixed(1)} > 20（禁买高价盾）',
                      )),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: bookBGateOpen
                ? _emerald
                : (lockoutLocked ? _amber : _coral),
            fontSize: 13.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          w(
            '125D -15% Put · <=75D Hard Roll if VIX<=20 else Salvage to QQQ',
            '125D -15% 裸Put · 剩≤75D 仅在 VIX≤20 续滚，否则残值回流 QQQ',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.2),
        ),
      ],
    );

    final lockoutGateCard = Column(
      key: const ValueKey('crisis-post-tp-lockout-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('5D Post-Inversion Lockout (Both Books)', '止盈后 5 天倒挂解除锁（双账本共振禁买）'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          lockoutLocked
              ? w(
                  'LOCKED · $lockoutStreak/$lockoutReq days VIX/3M < 1.00',
                  '禁买锁定中 · 连续 $lockoutStreak/$lockoutReq 天 VIX/3M < 1.00',
                )
              : w(
                  'UNLOCKED · Contango Streak >= $lockoutReq days (< 1.00)',
                  '已解锁 · 顺水连续达标 ≥ $lockoutReq 天（VIX/3M < 1.00）',
                ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: lockoutLocked ? _amber : _emerald,
            fontSize: 13.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          w(
            'Blocks post-crash IV re-entry ($lockoutEpisodes episodes / ${lockoutDaysTot}d in 2015–2025)',
            '防崩盘止盈后买回天价余震波动率（2015–2025 触发 $lockoutEpisodes 次 / $lockoutDaysTot 天）',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.2),
        ),
      ],
    );

    final nearItmGateCard = Column(
      key: const ValueKey('crisis-near-itm-tp-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Near-ITM Crash Clearance Rule', '准实值谷底清仓换股规则'),
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          w(
            'QQQ <= ${selectedM7TpMode == 'itm_tp' ? '1.00' : '1.05'}×K & VIX/3M >= 1.10 | VIX >= 45',
            'QQQ ≤ ${selectedM7TpMode == 'itm_tp' ? '1.00' : '1.05'}×K 且 VIX/3M ≥ 1.10 | VIX ≥ 45',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: (vixNow >= 45.0 || vixRatio >= 1.10) ? _emerald : p.text,
            fontSize: 13.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          w(
            'OR >=5.0x Mid (<=60D Book B / <=45D Book M) -> 100% into QQQ',
            '或期权浮盈 ≥ 5.0x（Book B 剩≤60D / Book M 剩≤45D）→ 100% 换股抄底 QQQ',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.2),
        ),
      ],
    );

    return Container(
      key: const ValueKey('crisis-observatory-command-center'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: pinnedPitDate != null
          ? BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _sky.withValues(alpha: 0.45)),
            )
          : _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pinnedPitDate != null)
            _buildPitReplayBanner(
              fullDoc,
              doc,
              keyPrefix: 'cmd',
              compact: compact,
              showStepButtons: false,
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      t1Badge.isNotEmpty
                          ? t1Badge
                          : (_isCore3
                                ? w(
                                    'Core-3 Minimal Put Overlay (M0+M6+M4)',
                                    '精简 3 核分层 Put 风控引擎（M0+M6+M4）',
                                  )
                                : w(
                                    'M7-Graded Three-Pillar Put Overlay',
                                    'M7-Graded 三支柱概率分层 Put 风控引擎',
                                  )),
                      style: TextStyle(
                        color: p.text,
                        fontSize: compact ? 16.5 : 18.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (doc['liveExtended'] == true)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6.5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _emerald.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _emerald.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        w('LIVE EOD', '实时收盘'),
                        style: const TextStyle(
                          color: _emerald,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  InkWell(
                    key: const ValueKey('crisis-observatory-qqq-chip'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onCompany('QQQ'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'QQQ \$${qqqClose.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    w(
                      '· ${_fmtPct(ddAth)} off high · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                      '· 距高点 ${_fmtPct(ddAth)} · VXN ${vxnNow.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t1Title,
            style: TextStyle(
              color: p.muted,
              fontSize: compact ? 13 : 13.5,
              height: 1.48,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            key: const ValueKey('crisis-m7-freshness-strip'),
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isPitFresh)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: _sky.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _sky.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    w('PIT Replay', 'PIT 历史回放'),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 10.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Text(
                [
                  'Yahoo EOD $yahooDate',
                  if (baaDate.isNotEmpty)
                    w('FRED Baa/2Y $baaDate (+1D)', 'FRED 利差/2Y $baaDate (+1D)'),
                  if (nfciDate.isNotEmpty) 'NFCI $nfciDate (+5D)',
                  if (adDate.isNotEmpty) 'A-D $adDate',
                ].join(' · '),
                style: TextStyle(
                  color: p.muted.withValues(alpha: 0.85),
                  fontSize: 11.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          probCard,
          const SizedBox(height: 14),
          Container(height: 1, color: p.border),
          const SizedBox(height: 14),
          if (desktop)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: slotsCard),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: p.border,
                  ),
                  Expanded(child: redlineCard),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: p.border,
                  ),
                  Expanded(child: tpCard),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                slotsCard,
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Container(height: 1, color: p.border),
                ),
                redlineCard,
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Container(height: 1, color: p.border),
                ),
                tpCard,
              ],
            ),
          const SizedBox(height: 12),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          if (desktop)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: bookBGateCard),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: p.border,
                  ),
                  Expanded(child: lockoutGateCard),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: p.border,
                  ),
                  Expanded(child: nearItmGateCard),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bookBGateCard,
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(height: 1, color: p.border),
                ),
                lockoutGateCard,
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(height: 1, color: p.border),
                ),
                nearItmGateCard,
              ],
            ),
          const SizedBox(height: 14),
          _buildM7SizingCalculator(
            m7Dash: m7Dash,
            stratSummary: stratSummary,
            compact: compact,
          ),
          const SizedBox(height: 12),
          _buildLiveEngine3Strip(doc, snap),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                key: const ValueKey('crisis-rules-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    setState(() => showRulesDisclosure = !showRulesDisclosure),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        showRulesDisclosure
                            ? w('Hide Execution Rules', '收起执行规则')
                            : w('View Execution Rules', '查看执行规则'),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        showRulesDisclosure
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: p.muted,
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                w(
                  'Tier Mapping: ${text(m7Dash['tier_rule_en'])}',
                  '概率映射：${text(m7Dash['tier_rule_zh'])}',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (showRulesDisclosure) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Text(
                w(
                  'Hard-Coded Execution Rules (Strict T+1 Close · 2015-01-02 to 2025-12-15 MIT Real QQQ OPRA Quotes [${_humanFillModeLabel(selectedFillMode)}]; 2025-12-16 to Live OPRA-Calibrated BSM): 1) Hold 100% QQQ core forever (DRIP, 0 stock selling). 2) Book B (0.20% Calm Floor): max 1 slot, fixed 0.20% of NAV into 125-DTE -15% OTM Put ONLY when VIX <= 20.0 AND VIX/VIX3M < 1.02 and unlocked; hard-exits at <=75 DTE (rolls only if VIX <= 20 & unlocked, else salvages to QQQ). 3) Book M (1.25%/slot Tactical M7G): daily score maps to 0–3 slots (<35->0, 35-44->1, 45-64->2, >=65->3) at fixed 1.25% of NAV per slot into ${_humanPutOtmShort(selectedPutOtm)} Put (P1/P2 125D->75D hard roll, P3 CTA M4 90D->30D hard roll; VXN<=27 & VIX/VIX3M<1.02 redline; 30D/21D cooldown). 4) Near-ITM Crash Clearance: 100% clear to QQQ when (VIX/VIX3M >= 1.10 & QQQ <= ${selectedM7TpMode == 'itm_tp' ? '1.00' : '1.05'}×K) OR VIX >= 45 OR >=5.0x Mid (<=60D B / <=45D M). 5) 5-Day Post-Inversion Lockout: after any crash TP, block all Book B & Book M entries/re-buys until VIX/VIX3M < 1.00 holds for 5 consecutive trading days.',
                  '实盘写死双账本执行规则（严格零前视 T+1 收盘成交 · 2015-01-02 至 2025-12-15 采用 MIT 真实 OPRA 盘口［${_humanFillModeLabel(selectedFillMode)}］；2025-12-16 至实时采用 OPRA 校准 BSM）：① 底仓 100% 持有 QQQ 永不择时卖股；② Book B（0.20% 常态基底）：最多 1 槽，仅在 VIX ≤ 20.0 且 VIX/VIX3M < 1.02 且未处禁买锁时按当前净值固定 0.20% 买入 125D -15% Put，剩 ≤75D 强制平仓（若 VIX ≤ 20 且未锁定则续滚新 125D，否则残值回流 QQQ 绝不追高）；③ Book M（1.25%/槽战术盾）：日度总分映射 0–3 槽（<35→0，35–44→1，45–64→2，≥65→3），每槽固定当前净值 1.25% 买入 ${_humanPutOtmShort(selectedPutOtm)} Put（P1/P2 125D→75D 硬滚仓，P3 M4 CTA 90D→30D 硬滚仓；VXN>27 或 VIX/VIX3M≥1.02 红线禁开；30天/21天阶梯冷却）；④ 准实值谷底清仓：满足（VIX/VIX3M ≥ 1.10 且 QQQ ≤ ${selectedM7TpMode == 'itm_tp' ? '1.00' : '1.05'}×K）或 VIX ≥ 45 或期权浮盈 ≥ 5.0x（Book B 剩≤60D / Book M 剩≤45D）时 100% 清仓换股抄底 QQQ；⑤ 5 天倒挂解除锁：任一笔触发崩盘止盈后，双账本全面禁买新盾，直至 VIX/VIX3M < 1.00 连续站稳满 5 个交易日。',
                ),
                style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildM7SizingCalculator({
    required Map<String, dynamic> m7Dash,
    required Map<String, dynamic> stratSummary,
    required bool compact,
  }) {
    final calc = asMap(m7Dash['sizing_calculator']);
    final dte = _numVal(
      calc['dte'],
      selectedRollMode == '90d_hold'
          ? 90
          : (selectedRollMode == '120d_roll50' ? 120 : 125),
    ).round();
    final qqqSpotCalc = _numVal(calc['qqq_spot'], 608.45);
    final selMap = asMap(
      calc[selectedPutOtm == 'otm20' ? 'otm20' : 'otm15'],
    );
    final baseMap15 = asMap(calc['otm15']);
    final selStrike = _numVal(selMap['strike']);
    final selAsk = _numVal(
      selectedFillMode == 'ask_bid'
          ? selMap['ask_sh']
          : (selMap['exec_buy_sh'] ?? selMap['ask_sh']),
      _numVal(selMap['ask_sh']),
    );
    final baseExecPx = _numVal(
      selectedFillMode == 'ask_bid'
          ? baseMap15['ask_sh']
          : (baseMap15['exec_buy_sh'] ?? baseMap15['ask_sh']),
      selAsk,
    );
    final selIv = _numVal(selMap['iv_pct']);
    final skewRatio = _numVal(calc['skew_ratio_20_10']);
    final skewThresh = _numVal(calc['skew_switch_threshold'], 1.18);
    final skewFav = calc['favorable_otm20_skew'] == true;
    final modelShares = _numVal(
      calc['model_qqq_shares'],
      _numVal(stratSummary['final_shares'], 1000.0),
    );

    final shCount = customQqqShares > 0 ? customQqqShares : 1000.0;
    final navEstUsd = shCount * qqqSpotCalc;
    final baseBudgetUsd = navEstUsd * 0.0020;
    final perSlotBudgetUsd = navEstUsd * 0.0125;
    final baseContractsEst =
        baseExecPx > 0 ? baseBudgetUsd / (baseExecPx * 100.0) : 0.0;
    final contractsEst = selAsk > 0 ? perSlotBudgetUsd / (selAsk * 100.0) : 0.0;

    return Container(
      key: const ValueKey('crisis-m7-sizing-calculator'),
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: p.text.withValues(alpha: 0.028),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('QQQ Shares:', '持有 QQQ 股数：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(
                    width: 86,
                    height: 30,
                    child: TextField(
                      key: const ValueKey('crisis-qqq-shares-input'),
                      controller: _qqqSharesCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        filled: true,
                        fillColor: p.card,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: p.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: _emerald),
                        ),
                      ),
                      onChanged: (val) {
                        final parsed = double.tryParse(
                          val.replaceAll(',', '').trim(),
                        );
                        if (parsed != null && parsed > 0 && parsed <= 1e7) {
                          setState(() => customQqqShares = parsed);
                        }
                      },
                    ),
                  ),
                  InkWell(
                    key: const ValueKey('crisis-use-model-shares-btn'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      final rounded = modelShares.roundToDouble();
                      _qqqSharesCtrl.text = rounded.toStringAsFixed(0);
                      setState(() => customQqqShares = rounded);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: p.border),
                      ),
                      child: Text(
                        w(
                          'Model (${modelShares.toStringAsFixed(0)})',
                          '策略股数(${modelShares.toStringAsFixed(0)})',
                        ),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                w(
                  'Book B 0.20%: ${_fmtUsdCents(baseBudgetUsd)} (${baseContractsEst.toStringAsFixed(2)} ctr) · Book M 1.25%/slot: ${_fmtUsdCents(perSlotBudgetUsd)} -> Buy ${contractsEst.toStringAsFixed(2)} ctr (${dte}D K=\$${selStrike.toStringAsFixed(1)} Put @ \$${selAsk.toStringAsFixed(2)} · IV ${selIv.toStringAsFixed(1)}%)',
                  '固定预算 · Book B 0.20%：${_fmtUsdCents(baseBudgetUsd)}（${baseContractsEst.toStringAsFixed(2)}张）· Book M 单槽 1.25%：${_fmtUsdCents(perSlotBudgetUsd)} → 买 ${contractsEst.toStringAsFixed(2)} 张（${dte}D 行权 \$${selStrike.toStringAsFixed(1)} Put @ \$${selAsk.toStringAsFixed(2)} · IV ${selIv.toStringAsFixed(1)}%）',
                ),
                key: const ValueKey('crisis-m7-budget-output'),
                style: const TextStyle(
                  color: _emerald,
                  fontSize: 12.0,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                key: const ValueKey('crisis-otm-mode-bar'),
                spacing: 5,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Strike:', '虚值行权价：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  for (final oid in _putOtmIds) _buildCalmPutOtmTab(oid),
                ],
              ),
              Wrap(
                key: const ValueKey('crisis-roll-mode-bar'),
                spacing: 5,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Tenor / Roll:', '期限与滚仓：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (_isCore3)
                    Container(
                      key: const ValueKey('crisis-core3-roll-locked-badge'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4.5,
                      ),
                      decoration: BoxDecoration(
                        color: _sky.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: _sky.withValues(alpha: 0.65),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 12,
                            color: _sky,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              w(
                                'Locked to Optimal Adaptive Hard Roll 125→75 / CTA 90→30 (90D Hold disabled)',
                                '已锁定最优自适应硬滚仓 125→75 / CTA 90→30（禁用 90D 持有）',
                              ),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 11.0,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (final rid in _rollModeIds) _buildCalmRollModeTab(rid),
                ],
              ),
              Wrap(
                key: const ValueKey('crisis-m7-tp-bar'),
                spacing: 5,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('TP Rule:', '止盈规则：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  for (final tid in _m7TpModeIds) _buildCalmM7TpTab(tid),
                ],
              ),
              Container(
                key: const ValueKey('crisis-skew-indicator'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: skewFav
                      ? _emerald.withValues(alpha: 0.12)
                      : p.text.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: skewFav ? _emerald.withValues(alpha: 0.45) : p.border,
                  ),
                ),
                child: Text(
                  w(
                    'Skew IV(-20/-10) ${skewRatio.toStringAsFixed(3)} vs ${skewThresh.toStringAsFixed(2)} ${skewFav ? '(Favorable -20%)' : '(Steep Skew)'}',
                    '尾部偏度 IV(-20/-10) ${skewRatio.toStringAsFixed(3)} vs ${skewThresh.toStringAsFixed(2)} ${skewFav ? '（宜切 -20%）' : '（偏度较陡）'}',
                  ),
                  style: TextStyle(
                    color: skewFav ? _emerald : p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _stressAccent(int stress) {
    if (stress >= 75) return _coral;
    if (stress >= 50) return const Color(0xFFF97316);
    if (stress >= 25) return _amber;
    return _emerald;
  }

  String _stressLevelFallbackEn(int stress) {
    if (stress >= 75) return 'Active Crisis';
    if (stress >= 50) return 'Elevated Stress';
    if (stress >= 25) return 'Stress Building';
    return 'Calm Low-Vol';
  }

  String _stressLevelFallbackZh(int stress) {
    if (stress >= 75) return '危机爆发中';
    if (stress >= 50) return '高压警戒';
    if (stress >= 25) return '隐患蓄力';
    return '平静低波';
  }

  // ===========================================================================
  // BLOCK 2A: M7-Graded Three-Pillar & 6 Sub-Module Status Matrix
  // ===========================================================================
  Widget _buildThreePillarBlock(
    Map<String, dynamic> doc, {
    required Map<String, dynamic> fullDoc,
    required Map<String, dynamic> m7Dash,
    required double maxWidth,
    required bool compact,
    required bool desktop,
  }) {
    final pillars = asList(m7Dash['pillars']);
    final crisisProb = _numVal(m7Dash['crisis_prob']).round();
    final p1 = _numVal(m7Dash['p1_score']).round();
    final p2 = _numVal(m7Dash['p2_score']).round();
    final p3 = _numVal(m7Dash['p3_score']).round();
    final liveStress = _numVal(m7Dash['live_stress_index']).round();
    final stressAccent = _stressAccent(liveStress);
    final stressLbl = w(
      text(m7Dash['live_stress_label_en']).isNotEmpty
          ? text(m7Dash['live_stress_label_en'])
          : _stressLevelFallbackEn(liveStress),
      text(m7Dash['live_stress_label_zh']).isNotEmpty
          ? text(m7Dash['live_stress_label_zh'])
          : _stressLevelFallbackZh(liveStress),
    );
    final redlineBlocked = asMap(m7Dash['redline'])['blocked'] == true;
    final Color gatePillColor = redlineBlocked && crisisProb == 0
        ? _coral
        : (crisisProb >= 35 ? _amber : _emerald);
    final String gatePillText = redlineBlocked && crisisProb == 0
        ? w(
            'Put Gate 0% (High-IV Freeze)',
            '低波买盾分 0%（高波红线冻结防追高）',
          )
        : w(
            'Put Gate $crisisProb% ($p1+$p2+$p3)',
            '低波买盾分 $crisisProb%（$p1+$p2+$p3）',
          );

    return Container(
      key: _threePillarsAnchorKey,
      child: Container(
        key: const ValueKey('crisis-observatory-three-pillars'),
        padding: EdgeInsets.all(compact ? 16 : 22),
        decoration: pinnedPitDate != null
            ? BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _sky.withValues(alpha: 0.55)),
              )
            : _calmSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pinnedPitDate != null)
              _buildPitReplayBanner(
                fullDoc,
                doc,
                keyPrefix: 'pillars',
                compact: compact,
                showStepButtons: true,
              ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isCore3
                          ? w(
                              'Three-Pillar Crisis Probability Matrix (Core-3 Minimal · M0+M6+M4 Active)',
                              '三支柱概率分层监控矩阵（精简 3 核 · 仅激活 M0+M6+M4）',
                            )
                          : w(
                              'Three-Pillar Crisis Probability Matrix (M7-Graded)',
                              '三支柱概率分层监控矩阵（M7-Graded · 六大子模块）',
                            ),
                      style: TextStyle(
                        color: p.text,
                        fontSize: compact ? 15.5 : 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isCore3
                          ? w(
                              'M0 Breadth + M6 Crowding (P1) + M4 CTA Bear-Rally (P3) · M2/M5/M3 dimmed off in Core-3',
                              'M0 宽度背离 + M6 集中度 (P1) + M4 CTA 慢熊反弹 (P3) · M2/M5/M3 在精简模式下已关闭',
                            )
                          : w(
                              'Calm-Top Fragility (P1) + Options/HMM Jump (P2) + Bear Rally & Credit PIT (P3)',
                              '高位脆弱顶背离 (P1) + 期权偏度与因果 HMM 跃迁 (P2) + 慢熊反弹自满与滞后信用利差 (P3)',
                            ),
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      key: const ValueKey('crisis-pillars-stress-pill'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: stressAccent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: stressAccent.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        w(
                          'Stress $liveStress% ($stressLbl)',
                          '实时危机压力 $liveStress%（$stressLbl）',
                        ),
                        style: TextStyle(
                          color: stressAccent,
                          fontSize: 11.4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      key: const ValueKey('crisis-pillars-gate-pill'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: gatePillColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: gatePillColor.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        gatePillText,
                        style: TextStyle(
                          color: gatePillColor,
                          fontSize: 11.4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (desktop && pillars.length == 3)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildM7PillarColumn(pillars[0])),
                    const SizedBox(width: 12),
                    Expanded(child: _buildM7PillarColumn(pillars[1])),
                    const SizedBox(width: 12),
                    Expanded(child: _buildM7PillarColumn(pillars[2])),
                  ],
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < pillars.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _buildM7PillarColumn(pillars[i]),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildM7PillarColumn(Map<String, dynamic> pillar) {
    final pid = text(pillar['id']);
    final score = _numVal(pillar['score']).round();
    final cap = _numVal(pillar['cap']).round();
    final modules = asList(pillar['modules']);
    final disabledInCore3 =
        pillar['disabled_in_core3'] == true || (_isCore3 && pid == 'P2');
    final Color accent = switch (pid) {
      'P1' => _emerald,
      'P2' => _sky,
      _ => _amber,
    };
    final active = !disabledInCore3 && score > 0;

    final colCard = Container(
      key: ValueKey('crisis-m7-pillar-$pid'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.text.withValues(alpha: disabledInCore3 ? 0.01 : 0.02),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.5) : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  w(text(pillar['title_en']), text(pillar['title_zh'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: disabledInCore3 ? p.muted : p.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                key: disabledInCore3
                    ? ValueKey('crisis-pillar-core3-off-$pid')
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: active
                      ? accent.withValues(alpha: 0.16)
                      : p.text.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  disabledInCore3
                      ? w('Off in Core-3', '精简模式已关闭')
                      : '$score / $cap',
                  style: TextStyle(
                    color: active ? accent : p.muted,
                    fontSize: 11.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            w(text(pillar['subtitle_en']), text(pillar['subtitle_zh'])),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < modules.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _buildM7ModuleCard(modules[i], accent: accent),
          ],
        ],
      ),
    );
    return disabledInCore3 ? Opacity(opacity: 0.56, child: colCard) : colCard;
  }

  Widget _buildM7ModuleCard(
    Map<String, dynamic> mod, {
    required Color accent,
  }) {
    final mid = text(mod['id']);
    final pts = _numVal(mod['points']).round();
    final earned = _numVal(mod['earned_points']).round();
    final disabledInCore3 =
        mod['disabled_in_core3'] == true ||
        (_isCore3 && (mid == 'M2' || mid == 'M5' || mid == 'M3'));
    final triggered = !disabledInCore3 && mod['triggered'] == true;
    final pluggable = mod['pluggable'] == true && !_isCore3;
    final enabled = !disabledInCore3 && mod['enabled'] != false;
    final volOk = !disabledInCore3 && mod['vol_gate_passed'] == true;
    final metrics = asList(mod['metrics']);
    final statusCode = text(mod['status_code']);
    final sensorTrig = !disabledInCore3 && mod['sensor_triggered'] == true;
    final rMet = _numVal(mod['readiness_met']).round();
    final rTot = _numVal(
      mod['readiness_total'],
      metrics.length.toDouble(),
    ).round();
    final hintText = w(
      text(mod['next_trigger_hint_en']),
      text(mod['next_trigger_hint_zh']),
    );
    final isVolBlockedRed =
        enabled &&
        !triggered &&
        (statusCode == 'SENSOR_RED_VOL_BLOCKED' || (sensorTrig && !volOk));
    final isWarming =
        enabled &&
        !triggered &&
        !isVolBlockedRed &&
        (statusCode == 'WARMING_UP' || rMet > 0);

    final Color dotColor = !enabled
        ? p.muted.withValues(alpha: 0.35)
        : (triggered
              ? accent
              : (isVolBlockedRed
                    ? _coral
                    : (isWarming ? _amber : p.muted.withValues(alpha: 0.45))));
    final Color cardBorderColor = triggered
        ? accent.withValues(alpha: 0.58)
        : (isVolBlockedRed
              ? _coral.withValues(alpha: 0.52)
              : (isWarming
                    ? _amber.withValues(alpha: 0.36)
                    : p.border.withValues(alpha: 0.8)));

    Widget buildModuleRightBadge() {
      if (disabledInCore3) {
        return Container(
          key: ValueKey('crisis-mod-core3-off-$mid'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: p.text.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: p.border),
          ),
          child: Text(
            w('Off in Core-3', '精简模式已关闭'),
            style: TextStyle(
              color: p.muted,
              fontSize: 10.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      if (!enabled) {
        return Text(
          w('OFF', '已关'),
          key: ValueKey('crisis-mod-status-$mid'),
          style: TextStyle(
            color: p.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        );
      }
      if (triggered) {
        return Container(
          key: ValueKey('crisis-mod-status-$mid'),
          padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: Text(
            w('+$earned% BUY', '已触发 +$earned%'),
            style: TextStyle(
              color: accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      }
      if (isVolBlockedRed) {
        return Container(
          key: ValueKey('crisis-mod-status-$mid'),
          padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
          decoration: BoxDecoration(
            color: _coral.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _coral.withValues(alpha: 0.48)),
          ),
          child: Text(
            w('Alert $rMet/$rTot · IV Freeze', '预警 $rMet/$rTot · 高波禁追'),
            style: const TextStyle(
              color: _coral,
              fontSize: 10.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      }
      if (isWarming) {
        return Container(
          key: ValueKey('crisis-mod-status-$mid'),
          padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 1.5),
          decoration: BoxDecoration(
            color: _amber.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _amber.withValues(alpha: 0.42)),
          ),
          child: Text(
            w('Warming $rMet/$rTot', '预热 $rMet/$rTot'),
            style: const TextStyle(
              color: _amber,
              fontSize: 10.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      }
      return Text(
        rTot > 0 ? '$rMet/$rTot · 0/+$pts' : '0 / +$pts',
        key: ValueKey('crisis-mod-status-$mid'),
        style: TextStyle(
          color: p.muted,
          fontSize: 10.8,
          fontWeight: FontWeight.w700,
        ),
      );
    }

    final card = Container(
      key: ValueKey('crisis-m7-module-$mid'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: cardBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      w(text(mod['name_en']), text(mod['name_zh'])),
                      style: TextStyle(
                        color: enabled ? p.text : p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pluggable) ...[
                    _buildCalmM0Switch(compactPill: true),
                    const SizedBox(width: 5),
                  ],
                  buildModuleRightBadge(),
                ],
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Icon(
                volOk ? Icons.check_circle_outline : Icons.shield_outlined,
                size: 12,
                color: volOk
                    ? _emerald
                    : (isVolBlockedRed ? _coral : p.muted),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  w(text(mod['vol_gate_en']), text(mod['vol_gate_zh'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: volOk
                        ? _emerald
                        : (isVolBlockedRed ? _coral : p.muted),
                    fontSize: 10.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(height: 1, color: p.border.withValues(alpha: 0.55)),
          const SizedBox(height: 6),
          for (final m in metrics)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: !disabledInCore3 && m['passed'] == true
                          ? _emerald
                          : p.muted.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      w(text(m['label_en']), text(m['label_zh'])),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text(m['value']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: !disabledInCore3 && m['passed'] == true
                            ? p.text
                            : p.muted,
                        fontSize: 11,
                        fontWeight: !disabledInCore3 && m['passed'] == true
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (hintText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              hintText,
              key: ValueKey('crisis-mod-hint-$mid'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: triggered
                    ? accent
                    : (isVolBlockedRed
                          ? _coral
                          : (isWarming ? _amber : p.muted)),
                fontSize: 10.4,
                height: 1.32,
                fontWeight: isVolBlockedRed || triggered
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
    return disabledInCore3 ? Opacity(opacity: 0.48, child: card) : card;
  }

  Widget _buildCalmPutOtmTab(String modeId) {
    final active = selectedPutOtm == modeId;
    return InkWell(
      key: ValueKey('crisis-otm-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectPutOtm(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active ? _emerald.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.72) : p.border,
          ),
        ),
        child: Text(
          _humanPutOtmLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmRollModeTab(String modeId) {
    final active = selectedRollMode == modeId;
    final accent = modeId == 'adaptive_120_90'
        ? _emerald
        : (modeId == '120d_roll50' ? _sky : p.muted);
    return InkWell(
      key: ValueKey('crisis-roll-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectRollMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? accent.withValues(alpha: 0.72) : p.border,
          ),
        ),
        child: Text(
          _humanRollModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmM7TpTab(String modeId) {
    final active = selectedM7TpMode == modeId;
    return InkWell(
      key: ValueKey('crisis-m7-tp-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectM7TpMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active ? _emerald.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.72) : p.border,
          ),
        ),
        child: Text(
          _humanM7TpModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmM0Switch({bool compactPill = false}) {
    final on = selectedM0Enabled;
    return InkWell(
      key: ValueKey(
        compactPill ? 'crisis-m0-toggle' : 'crisis-m0-workbench-toggle',
      ),
      borderRadius: BorderRadius.circular(6),
      onTap: _toggleM0Enabled,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compactPill ? 6.5 : 8.5,
          vertical: compactPill ? 2.0 : 4.5,
        ),
        decoration: BoxDecoration(
          color: on
              ? _emerald.withValues(alpha: 0.14)
              : p.text.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: on ? _emerald.withValues(alpha: 0.65) : p.border,
          ),
        ),
        child: Text(
          on
              ? w('M0: ON (+35)', 'M0开关：开启(+35)')
              : w('M0: OFF (Pure 5-Mod)', 'M0开关：关闭(纯5模块)'),
          style: TextStyle(
            color: on ? _emerald : p.muted,
            fontSize: compactPill ? 10.2 : 11.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // BLOCK 3: Hero Interactive Chart + Crisis Zoom-In (历史保护策略 vs 死拿 QQQ)
  // ===========================================================================
  Widget _buildHeroChartBlock(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final allDaily = asList(doc['daily_series']);
    final windows = asList(doc['crisis_windows']);
    final activeWin = (selectedWindowId == 'ALL' ||
            selectedWindowId == '1Y' ||
            selectedWindowId == '3Y')
        ? null
        : _findWindow(doc, selectedWindowId);

    final List<Map<String, dynamic>> visibleDaily;
    if (activeWin != null) {
      visibleDaily = allDaily.where((row) {
        final dt = text(row['date']);
        return dt.compareTo(text(activeWin['start_date'])) >= 0 &&
            dt.compareTo(text(activeWin['end_date'])) <= 0;
      }).toList();
    } else if (selectedWindowId == '1Y' && allDaily.length > 252) {
      visibleDaily = allDaily.sublist(allDaily.length - 252);
    } else if (selectedWindowId == '3Y' && allDaily.length > 756) {
      visibleDaily = allDaily.sublist(allDaily.length - 756);
    } else {
      visibleDaily = allDaily;
    }

    final rebasedMode = selectedWindowId != 'ALL';
    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final navKey = _strategyNavKeys[selectedStrategyId] ?? 'nav_u1';

    final allEvents = _currentEventsForStrategy(doc);
    final ccLedgerForStrat = _currentCcLedgerForStrategy(doc);
    final spLedgerForStrat = _currentSpLedgerForStrategy(doc);
    final visibleStart = visibleDaily.isNotEmpty
        ? text(visibleDaily.first['date'])
        : '';
    final visibleEnd = visibleDaily.isNotEmpty
        ? text(visibleDaily.last['date'])
        : '';
    final visibleEvents = visibleDaily.isEmpty
        ? const <Map<String, dynamic>>[]
        : allEvents.where((ev) {
            final et = text(ev['event_type']);
            if (et == 'base_020_put' ||
                et == 'base_roll_75d' ||
                et == 'base_salvage_75d') {
              return false;
            }
            final dt = text(ev['date']);
            return dt.compareTo(visibleStart) >= 0 &&
                dt.compareTo(visibleEnd) <= 0;
          }).toList();
    final ccChartEvents = selectedCcMode == 'cc_off'
        ? const <Map<String, dynamic>>[]
        : _buildCcChartEvents(ccLedgerForStrat, visibleStart, visibleEnd);
    final spChartEvents = selectedSpMode == 'sp_off'
        ? const <Map<String, dynamic>>[]
        : _buildSpChartEvents(spLedgerForStrat, visibleStart, visibleEnd);
    final combinedVisibleEvents = <Map<String, dynamic>>[
      ...visibleEvents,
      ...ccChartEvents,
      ...spChartEvents,
    ];
    final hasPutLayer = selectedStrategyId != 'NoPut_CallOnly';
    final hasCallLayer = selectedCcMode != 'cc_off';
    final hasSpLayer = selectedSpMode != 'sp_off';
    final hasRollLayer =
        selectedCcMode == 'cc_d12_r45' || selectedCcMode == 'cc_d12_cr55';
    final hasStopLayer = selectedCcMode == 'cc_d12_d35';

    final isHoverActive = hoverIndex >= 0 && hoverIndex < visibleDaily.length;
    final pinnedIndex = (pinnedPitDate != null && pinnedPitDate!.isNotEmpty)
        ? visibleDaily.indexWhere((r) => text(r['date']) == pinnedPitDate)
        : -1;
    final pinnedBarForStrip = pinnedIndex >= 0
        ? visibleDaily[pinnedIndex]
        : (pinnedPitRow ??
              (pinnedPitDate != null
                  ? _findDailyBarByDate(pinnedPitDate!)
                  : null));
    final hoveredRow = isHoverActive
        ? visibleDaily[hoverIndex]
        : (pinnedBarForStrip ??
              (visibleDaily.isNotEmpty
                  ? visibleDaily.last
                  : const <String, dynamic>{}));

    final startStratNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first[navKey], 200000)
        : 200000.0;
    final startBhNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first['nav_bh'], 200000)
        : 200000.0;

    final hovStratNav = _numVal(hoveredRow[navKey]);
    final hovBhNav = _numVal(hoveredRow['nav_bh']);
    final hovStratRet = startStratNav > 0
        ? (hovStratNav / startStratNav - 1) * 100
        : 0.0;
    final hovBhRet = startBhNav > 0 ? (hovBhNav / startBhNav - 1) * 100 : 0.0;

    final strategyTabs = [
      ..._primaryStrategies,
      if (!_primaryStrategies.contains(selectedStrategyId)) selectedStrategyId,
    ];

    final String subtitleText;
    if (activeWin != null) {
      subtitleText = w(
        'Zoomed In: ${_humanWindowTitle(activeWin)} (Rebased to 100)',
        '危机放大：${_humanWindowTitle(activeWin)}（起点归 100）',
      );
    } else if (selectedWindowId == '1Y') {
      subtitleText = w(
        'Trailing 1 Year ($visibleStart to $visibleEnd, Rebased to 100)',
        '近 1 年走势（$visibleStart 至 $visibleEnd · 起点归 100）',
      );
    } else if (selectedWindowId == '3Y') {
      subtitleText = w(
        'Trailing 3 Years ($visibleStart to $visibleEnd, Rebased to 100)',
        '近 3 年走势（$visibleStart 至 $visibleEnd · 起点归 100）',
      );
    } else {
      subtitleText = w(
        '\$200,000 initial capital (2015–2026, dividends reinvested)',
        '\$200,000 起投（2015–2026 股息再投 · 含真实期权滑点）',
      );
    }

    return Container(
      key: const ValueKey('crisis-observatory-chart-section'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'Protected Strategy vs Buy & Hold QQQ',
                      '历史保护策略 vs 死拿 QQQ',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 16 : 17.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitleText,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                  if (stratSummary['real_trades_pct'] is num &&
                      _numVal(stratSummary['real_trades_pct']) > 0) ...[
                    const SizedBox(height: 6),
                    Builder(
                      builder: (_) {
                        final realPct = _numVal(
                          stratSummary['real_trades_pct'],
                        );
                        final opraCnt = _numVal(
                          stratSummary['real_opra_trades_count'],
                        ).round();
                        final simCnt = _numVal(
                          stratSummary['sim_trades_count'],
                        ).round();
                        final hasBreakdown = (opraCnt + simCnt) > 0;
                        final detailEn = hasBreakdown
                            ? '2015–2025 MIT Real OPRA: $opraCnt trades (0 fallbacks) · Post-2025 Calib. BSM: $simCnt'
                            : '2015–2025 MIT Real OPRA (0 fallbacks) · Post-2025 Calibrated BSM';
                        final detailZh = hasBreakdown
                            ? '2015–2025 MIT 真实 OPRA：$opraCnt 笔（0回退）· 2025-12-16后校准 BSM：$simCnt 笔'
                            : '2015–2025 MIT 真实 OPRA（0回退）· 2025-12-16后校准 BSM';
                        return Container(
                          key: const ValueKey(
                            'crisis-real-data-provenance-pill',
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _emerald.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _emerald.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            w(
                              'Real OPRA Chain ${realPct.toStringAsFixed(1)}% · $detailEn',
                              '真实盘口覆盖 ${realPct.toStringAsFixed(1)}% · $detailZh',
                            ),
                            style: const TextStyle(
                              color: _emerald,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
              Wrap(
                spacing: compact ? 16 : 24,
                runSpacing: 8,
                children: [
                  _heroStatMetric(
                    label: w('Ending Value', '策略终值'),
                    value: _fmtUsd(_numVal(stratSummary['end_nav'])),
                    sub: w(
                      'vs QQQ ${_fmtUsd(_numVal(stratSummary['bh_parity_end_nav'], _numVal(bhSummary['end_nav'])))}',
                      '死拿 ${_fmtUsd(_numVal(stratSummary['bh_parity_end_nav'], _numVal(bhSummary['end_nav'])))}',
                    ),
                    color: p.text,
                  ),
                  _heroStatMetric(
                    label: w('Net Alpha', '累计超额'),
                    value: _fmtUsd(
                      _numVal(stratSummary['net_alpha_usd']),
                      signed: true,
                    ),
                    sub: w(
                      'CAGR ${_numVal(stratSummary['cagr_pct']).toStringAsFixed(1)}%',
                      '年化 ${_numVal(stratSummary['cagr_pct']).toStringAsFixed(1)}%',
                    ),
                    color: _emerald,
                  ),
                  Builder(
                    builder: (_) {
                      final totSh = _numVal(stratSummary['final_shares']);
                      final bhSh = _numVal(
                        stratSummary['bh_final_shares'],
                        _numVal(bhSummary['final_shares'], 2117.34),
                      );
                      final exSh = _numVal(
                        stratSummary['extra_shares_vs_bh'],
                        totSh - bhSh,
                      );
                      final exPct = _numVal(
                        stratSummary['extra_shares_pct'],
                        bhSh > 0 ? (exSh / bhSh) * 100.0 : 0.0,
                      );
                      return _heroStatMetric(
                        label: w('Total Shares · Extra %', '总股数 · 多买比例'),
                        value: w(
                          '${_fmtShares(totSh)} sh',
                          '${_fmtShares(totSh)} 股',
                        ),
                        sub: w(
                          '${_fmtShares(exSh, signed: true)} sh (${_fmtPct(exPct)})',
                          '多买 ${_fmtShares(exSh, signed: true)} 股（${_fmtPct(exPct)}）',
                        ),
                        color: exPct >= 0 ? _emerald : p.text,
                      );
                    },
                  ),
                  _heroStatMetric(
                    label: w('Max Drawdown', '最大回撤'),
                    value:
                        '${_numVal(stratSummary['max_dd_pct']).toStringAsFixed(1)}%',
                    sub: w(
                      'vs ${_numVal(bhSummary['max_dd_pct']).toStringAsFixed(1)}% · Calmar ${_numVal(stratSummary['calmar']).toStringAsFixed(3)}',
                      '死拿 ${_numVal(bhSummary['max_dd_pct']).toStringAsFixed(1)}% · 卡玛 ${_numVal(stratSummary['calmar']).toStringAsFixed(3)}',
                    ),
                    color: p.text,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (switchingTpMode)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(minHeight: 2, color: _emerald),
            ),
          if (_isLegacyStrategy) ...[
            Container(
              key: const ValueKey('crisis-legacy-upgrade-banner'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _amber.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _amber.withValues(alpha: 0.40)),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w(
                      'Viewing legacy comparison (${_humanStrategyLabel(selectedStrategyId)}). Switch to Full M7 Shield (Adaptive 120→50 / CTA 90→30).',
                      '当前正在查看旧版对照曲线（${_humanStrategyLabel(selectedStrategyId)}，通常由旧链接参数保留）。全面升级版全套 M7 护盾（自适应 120→50 / CTA 90→30 · 真实 OPRA 盘口）在实盘回测中大幅领先旧版 U1。',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  InkWell(
                    key: const ValueKey('crisis-switch-to-m7g-btn'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: _switchToFlagshipM7g,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: _emerald.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _emerald.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Text(
                        w(
                          'Switch to M7-Graded Flagship',
                          '一键切换至 M7-Graded 全面升级旗舰',
                        ),
                        style: const TextStyle(
                          color: _emerald,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          _buildThreeEngineWorkbench(
            doc,
            stratSummary: stratSummary,
            bhSummary: bhSummary,
            strategyTabs: strategyTabs,
            hasPutLayer: hasPutLayer,
            rebasedMode: rebasedMode,
            compact: compact,
            desktop: desktop,
          ),
          const SizedBox(height: 12),
          _buildEngineAttributionPanel(
            doc,
            stratSummary: stratSummary,
            bhSummary: bhSummary,
            compact: compact,
            desktop: desktop,
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildCleanZoomChip(
                  id: 'ALL',
                  label: w('All 12Y', '全部 12 年'),
                  isLive: false,
                ),
                const SizedBox(width: 6),
                _buildCleanZoomChip(
                  id: '1Y',
                  label: w('1Y', '近 1 年'),
                  isLive: false,
                ),
                const SizedBox(width: 6),
                _buildCleanZoomChip(
                  id: '3Y',
                  label: w('3Y', '近 3 年'),
                  isLive: false,
                ),
                for (final win in windows) ...[
                  const SizedBox(width: 6),
                  _buildCleanZoomChip(
                    id: text(win['id']),
                    label: _humanWindowChipLabel(win),
                    isLive: win['is_live'] == true,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                key: const ValueKey('crisis-chart-legend'),
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _cleanLegendItem(
                    color: _emerald,
                    dashed: false,
                    label: _humanStrategyLabel(selectedStrategyId),
                  ),
                  _cleanLegendItem(
                    color: p.muted,
                    dashed: true,
                    label: w('Buy & Hold QQQ', '死拿 QQQ'),
                  ),
                  if (hasPutLayer) ...[
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.putOpen,
                      label: _isM7Strategy
                          ? w('Buy Graded Put (S1–S3)', '分层买 Put (S1–S3)')
                          : w('Buy Put / Collar', '买 Put / 领口'),
                    ),
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.putTp,
                      label: w('Put TP Harvest', 'Put 止盈换股'),
                    ),
                    if (_isM7Strategy &&
                        (selectedRollMode == 'adaptive_120_90' ||
                            selectedRollMode == '120d_roll50'))
                      _cleanVectorMarkerLegend(
                        kind: _CrisisMarkerKind.putRoll50,
                        label: selectedRollMode == 'adaptive_120_90'
                            ? w('75D/30D Hard Roll', '75D/30D 硬滚仓回收')
                            : w('50D Roll / Salvage', '50D 残值滚仓'),
                      ),
                  ],
                  if (hasCallLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccOpen,
                      label: w('Sell Call (▲ Up)', '卖 Call 开仓'),
                    ),
                  if (hasRollLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccRoll,
                      label: w('Call Roll Up', 'Call 展期 Roll'),
                    ),
                  if (hasStopLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccStop,
                      label: w('Call Δ0.35 Stop', 'Call Δ0.35 止损'),
                    ),
                  if (hasSpLayer) ...[
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.spOpen,
                      label: w('Sell Panic Put', '卖恐慌 Put'),
                    ),
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.spAssign,
                      label: w('Wheel Assigned', '接货进 Wheel'),
                    ),
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.wcCalled,
                      label: w('Wheel Call Exit', '被 Call 走清债'),
                    ),
                  ],
                ],
              ),
              if (hoveredRow.isNotEmpty)
                Builder(
                  builder: (_) {
                    final probField = _isCore3 && hoveredRow['c3_prob'] is num
                        ? 'c3_prob'
                        : 'm7_prob';
                    final probTag = _isCore3 ? 'Core-3' : 'M7';
                    final probStr = hoveredRow[probField] is num
                        ? ' · $probTag ${_numVal(hoveredRow[probField]).round()}%'
                        : '';
                    return Text(
                      !rebasedMode
                          ? '${text(hoveredRow['date'])} · ${_fmtUsd(hovStratNav)} vs ${_fmtUsd(hovBhNav)}$probStr · VIX/3M ${_numVal(hoveredRow['vix_ratio']).toStringAsFixed(2)}'
                          : '${text(hoveredRow['date'])} · ${_fmtPct(hovStratRet)} vs QQQ ${_fmtPct(hovBhRet)}$probStr · QQQ \$${_numVal(hoveredRow['qqq_close']).toStringAsFixed(1)}',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (pinnedPitDate != null && pinnedBarForStrip != null) ...[
            Container(
              key: const ValueKey('crisis-pit-chart-strip'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _sky.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _sky.withValues(alpha: 0.40)),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Builder(
                    builder: (_) {
                      final useC3 =
                          _isCore3 && pinnedBarForStrip['c3_prob'] is num;
                      final pProb = _numVal(
                        pinnedBarForStrip[useC3 ? 'c3_prob' : 'm7_prob'],
                      ).round();
                      final p1 = _numVal(
                        pinnedBarForStrip[useC3 ? 'c3_p1' : 'm7_p1'],
                      ).round();
                      final p2 = _numVal(
                        pinnedBarForStrip[useC3 ? 'c3_p2' : 'm7_p2'],
                      ).round();
                      final p3 = _numVal(
                        pinnedBarForStrip[useC3 ? 'c3_p3' : 'm7_p3'],
                      ).round();
                      final tag = _isCore3 ? 'Core-3' : 'M7';
                      return Text(
                        w(
                          'Pinned PIT: $pinnedPitDate · QQQ \$${_numVal(pinnedBarForStrip['qqq_close']).toStringAsFixed(2)} · $tag $pProb% (P1:$p1 · P2:$p2 · P3:$p3)',
                          '已锁定 PIT 回放：$pinnedPitDate · QQQ \$${_numVal(pinnedBarForStrip['qqq_close']).toStringAsFixed(2)} · $tag $pProb%（P1:$p1 · P2:$p2 · P3:$p3）',
                        ),
                        style: const TextStyle(
                          color: _sky,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      InkWell(
                        key: const ValueKey('crisis-pit-chart-prev-btn'),
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => _stepPitDate(-1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: p.card,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: p.border),
                          ),
                          child: Text(
                            '◀',
                            style: TextStyle(color: p.text, fontSize: 10.5),
                          ),
                        ),
                      ),
                      InkWell(
                        key: const ValueKey('crisis-pit-chart-next-btn'),
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => _stepPitDate(1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: p.card,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: p.border),
                          ),
                          child: Text(
                            '▶',
                            style: TextStyle(color: p.text, fontSize: 10.5),
                          ),
                        ),
                      ),
                      InkWell(
                        key: const ValueKey('crisis-pit-jump-pillars-btn'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: _jumpToThreePillars,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _sky.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: _sky.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            w('View 3 Pillars ↑', '查看上方三支柱 ↑'),
                            style: const TextStyle(
                              color: _sky,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        key: const ValueKey('crisis-pit-chart-clear-btn'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: _clearPitSelection,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _emerald.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: _emerald.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Text(
                            w('Back to Live ×', '回到最新 ×'),
                            style: const TextStyle(
                              color: _emerald,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            Text(
              w(
                'Tip: Click any historical point on the curve to replay exact Point-In-Time (PIT) Three-Pillar & Command Deck states above.',
                '提示：点击曲线上任意历史点，即可在上方三大支柱与指挥台完整回放当日 PIT 实时状态、日期与价格。',
              ),
              style: TextStyle(
                color: p.muted.withValues(alpha: 0.85),
                fontSize: 11,
              ),
            ),
          ],
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, chartConstraints) {
              final chartWidth = chartConstraints.maxWidth;
              final mainHeight = compact ? 290.0 : 350.0;
              final totalHeight = showSignalSubTrack
                  ? mainHeight + 84.0
                  : mainHeight;
              final hoverEvents = isHoverActive
                  ? _eventsNearHoverIndex(
                      visibleDaily: visibleDaily,
                      visibleEvents: combinedVisibleEvents,
                      hoverIdx: hoverIndex,
                      chartWidth: chartWidth,
                    )
                  : const <Map<String, dynamic>>[];

              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (ev) => _updateHoverFromDx(
                  ev.localPosition.dx,
                  chartWidth,
                  visibleDaily.length,
                ),
                onExit: (_) => setState(() => hoverIndex = -1),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  onTapUp: (d) => _pinPitFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily,
                  ),
                  onPanDown: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  onPanUpdate: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  child: SizedBox(
                    key: const ValueKey('crisis-observatory-canvas'),
                    width: chartWidth,
                    height: totalHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            size: Size(chartWidth, totalHeight),
                            painter: _CrisisObservatoryChartPainter(
                              rows: visibleDaily,
                              events: combinedVisibleEvents,
                              navKey: navKey,
                              probKey: _isCore3 ? 'c3_prob' : 'm7_prob',
                              rebasedMode: rebasedMode,
                              useLogScale: !rebasedMode && useLogScale,
                              showSubTrack: showSignalSubTrack,
                              hoverIndex: hoverIndex,
                              pinnedIndex: pinnedIndex,
                              borderColor: p.border,
                              mutedColor: p.muted,
                              textColor: p.text,
                            ),
                          ),
                        ),
                        if (isHoverActive && hoveredRow.isNotEmpty)
                          _buildCleanHoverTooltip(
                            row: hoveredRow,
                            hoverEvents: hoverEvents,
                            navKey: navKey,
                            startStratNav: startStratNav,
                            startBhNav: startBhNav,
                            rebasedMode: rebasedMode,
                            hoverIdx: hoverIndex,
                            totalVisible: visibleDaily.length,
                            chartWidth: chartWidth,
                            compact: compact,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              key: const ValueKey('crisis-subtrack-toggle'),
              borderRadius: BorderRadius.circular(6),
              onTap: () =>
                  setState(() => showSignalSubTrack = !showSignalSubTrack),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  showSignalSubTrack
                      ? w(
                          'Hide M7 Prob & VIX Sub-Track',
                          '收起 M7 概率与恐慌副图',
                        )
                      : w(
                          'Show M7 Prob & VIX Sub-Track',
                          '展开 M7 概率与恐慌副图',
                        ),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _eventsNearHoverIndex({
    required List<Map<String, dynamic>> visibleDaily,
    required List<Map<String, dynamic>> visibleEvents,
    required int hoverIdx,
    required double chartWidth,
  }) {
    if (visibleDaily.isEmpty ||
        visibleEvents.isEmpty ||
        hoverIdx < 0 ||
        hoverIdx >= visibleDaily.length) {
      return const [];
    }
    final hoverDate = text(visibleDaily[hoverIdx]['date']);
    final exact = visibleEvents
        .where((ev) => text(ev['date']) == hoverDate)
        .toList();
    if (exact.isNotEmpty) return exact;

    final n = visibleDaily.length;
    if (n <= 1) return const [];
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final hoverX = padL + (hoverIdx / (n - 1)) * plotW;

    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(visibleDaily[i]['date']): i,
    };
    String? bestDate;
    var bestDist = 9.0;
    for (final ev in visibleEvents) {
      final evDate = text(ev['date']);
      final evIdx = idxByDate[evDate];
      if (evIdx == null) continue;
      final evX = padL + (evIdx / (n - 1)) * plotW;
      final dist = (evX - hoverX).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestDate = evDate;
      }
    }
    if (bestDate == null) return const [];
    return visibleEvents.where((ev) => text(ev['date']) == bestDate).toList();
  }

  Widget _buildCleanHoverTooltip({
    required Map<String, dynamic> row,
    required List<Map<String, dynamic>> hoverEvents,
    required String navKey,
    required double startStratNav,
    required double startBhNav,
    required bool rebasedMode,
    required int hoverIdx,
    required int totalVisible,
    required double chartWidth,
    required bool compact,
  }) {
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final cursorX = totalVisible > 1
        ? padL + (hoverIdx / (totalVisible - 1)) * plotW
        : padL;
    final cardWidth = math.min(compact ? 230.0 : 270.0, chartWidth - 16.0);
    final placeLeft = cursorX > chartWidth * 0.56;
    final rawLeft = placeLeft ? cursorX - cardWidth - 12.0 : cursorX + 12.0;
    final clampedLeft = rawLeft.clamp(4.0, math.max(4.0, chartWidth - cardWidth - 4.0));

    final stratNav = _numVal(row[navKey]);
    final bhNav = _numVal(row['nav_bh']);
    final stratRet = startStratNav > 0 ? (stratNav / startStratNav - 1) * 100 : 0.0;
    final bhRet = startBhNav > 0 ? (bhNav / startBhNav - 1) * 100 : 0.0;
    final lights = _numVal(row['crisis_lights']).round();
    final useC3Row = _isCore3 && row['c3_prob'] is num;
    final hasM7Row = useC3Row || row['m7_prob'] is num;
    final m7Prob = _numVal(row[useC3Row ? 'c3_prob' : 'm7_prob']).round();
    final m7TargetSlots = _numVal(
      row[useC3Row ? 'c3_target_slots' : 'm7_target_slots'] ?? row['m7_slots'],
    ).round();
    final m7ActiveSlots = _numVal(
      row[useC3Row ? 'c3_active_slots' : 'm7_active_slots'],
    ).round();
    final m7P1 = _numVal(row[useC3Row ? 'c3_p1' : 'm7_p1']).round();
    final m7P2 = _numVal(row[useC3Row ? 'c3_p2' : 'm7_p2']).round();
    final m7P3 = _numVal(row[useC3Row ? 'c3_p3' : 'm7_p3']).round();
    final vixRatio = _numVal(row['vix_ratio']);
    final qqqClose = _numVal(row['qqq_close']);

    double netPnlSum = 0;
    double sharesSum = 0;
    bool hasVixTp = false;
    bool hasNearItmTp = false;
    bool hasVix45Tp = false;
    bool hasItmTp = false;
    bool has4xTp = false;
    bool hasPut5xTp = false;
    bool hasLiveArmed = false;
    bool hasOpen = false;
    Map<String, dynamic>? firstOpenEv;
    Map<String, dynamic>? firstRoll50Ev;
    Map<String, dynamic>? firstCcOpenEv;
    Map<String, dynamic>? firstCcRollEv;
    Map<String, dynamic>? firstCcStopEv;
    Map<String, dynamic>? firstSpOpenEv;
    Map<String, dynamic>? firstSpAssignEv;
    Map<String, dynamic>? firstWcCalledEv;
    for (final ev in hoverEvents) {
      final et = text(ev['event_type']);
      if (et == 'vix110_tp' ||
          et == 'vix110_near_itm_tp' ||
          et == 'vix45_panic_tp' ||
          et == 'vix110_itm_tp' ||
          et == 'vix110_4x_tp' ||
          et == 'put5x_dte45_tp' ||
          et == 'base_tp_5x_late' ||
          et == 'live_tp_armed') {
        if (et == 'put5x_dte45_tp' || et == 'base_tp_5x_late') {
          hasPut5xTp = true;
        } else if (et == 'live_tp_armed') {
          hasLiveArmed = true;
        } else if (et == 'vix110_near_itm_tp') {
          hasNearItmTp = true;
        } else if (et == 'vix45_panic_tp') {
          hasVix45Tp = true;
        } else if (et == 'vix110_itm_tp') {
          hasItmTp = true;
        } else if (et == 'vix110_4x_tp') {
          has4xTp = true;
        } else {
          hasVixTp = true;
        }
        netPnlSum += _numVal(ev['net_pnl_usd']);
        sharesSum += _numVal(ev['shares_added']);
      } else if (et == 'roll_75d' ||
          et == 'roll_50d' ||
          et == 'roll_30d' ||
          et == 'live_roll75_armed' ||
          et == 'live_roll50_armed' ||
          et == 'live_roll30_armed') {
        firstRoll50Ev ??= ev;
      } else if (et.startsWith('slot')) {
        hasOpen = true;
        firstOpenEv ??= ev;
      } else if (et == 'cc_open') {
        firstCcOpenEv ??= ev;
      } else if (et == 'cc_roll_up' || et == 'cc_credit_roll') {
        firstCcRollEv ??= ev;
      } else if (et == 'cc_delta_stop') {
        firstCcStopEv ??= ev;
      } else if (et == 'sp_open') {
        firstSpOpenEv ??= ev;
      } else if (et == 'sp_assign') {
        firstSpAssignEv ??= ev;
      } else if (et == 'wc_called') {
        firstWcCalledEv ??= ev;
      }
    }
    final hasTp =
        hasVixTp ||
        hasNearItmTp ||
        hasVix45Tp ||
        hasItmTp ||
        has4xTp ||
        hasPut5xTp ||
        hasLiveArmed;
    final hasAnyMarkerEvent =
        hasTp ||
        hasOpen ||
        firstRoll50Ev != null ||
        firstCcOpenEv != null ||
        firstCcRollEv != null ||
        firstCcStopEv != null ||
        firstSpOpenEv != null ||
        firstSpAssignEv != null ||
        firstWcCalledEv != null;

    return Positioned(
      left: clampedLeft.toDouble(),
      top: 10,
      width: cardWidth,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('crisis-chart-hover-tooltip'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 2,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    text(row['date']),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'QQQ \$${qqqClose.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)}',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                rebasedMode
                    ? '${_humanStrategyLabel(selectedStrategyId)} ${_fmtPct(stratRet)} vs QQQ ${_fmtPct(bhRet)}'
                    : '${_fmtUsd(stratNav)} vs QQQ ${_fmtUsd(bhNav)}',
                style: TextStyle(
                  color: _emerald,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              if (qqqClose > 0) ...[
                Builder(
                  builder: (_) {
                    final eqSh = stratNav / qqqClose;
                    final bhEqSh = bhNav / qqqClose;
                    final exPct = bhEqSh > 0 ? (eqSh / bhEqSh - 1) * 100 : 0.0;
                    return Text(
                      w(
                        'Equiv. ${_fmtShares(eqSh)} sh (${_fmtPct(exPct)} vs BH)',
                        '等效持仓 ${_fmtShares(eqSh)} 股（较死拿 ${_fmtPct(exPct)}）',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 11),
                    );
                  },
                ),
                const SizedBox(height: 2),
              ],
              if (hasM7Row) ...[
                Text(
                  m7Prob == 0 && m7ActiveSlots > 0
                      ? w(
                          'M7 Entry Score: 0% (Crash Active · Holding $m7ActiveSlots Put Slot${m7ActiveSlots > 1 ? 's' : ''})',
                          'M7 开仓分：0%（暴跌中禁追买 · 持仓 $m7ActiveSlots 槽保护待止盈）',
                        )
                      : w(
                          'M7 Crisis Prob: $m7Prob% (P1:$m7P1 · P2:$m7P2 · P3:$m7P3 · Target $m7TargetSlots / Held $m7ActiveSlots)',
                          'M7 危机概率：$m7Prob%（P1:$m7P1 · P2:$m7P2 · P3:$m7P3 · 目标 $m7TargetSlots / 持仓 $m7ActiveSlots 槽）',
                        ),
                  style: TextStyle(
                    color: m7Prob >= 35
                        ? _amber
                        : (m7ActiveSlots > 0 ? _emerald : p.muted),
                    fontSize: 11,
                    fontWeight: m7Prob >= 35 || m7ActiveSlots > 0
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 2),
              ] else
                Text(
                  w(
                    'Crisis Lights: $lights / 6 active',
                    '当日危机灯：$lights / 6 亮起',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
              if (hasAnyMarkerEvent) ...[
                const SizedBox(height: 6),
                Container(height: 1, color: p.border),
                const SizedBox(height: 6),
                if (hasTp || hasOpen)
                  Text(
                    hasLiveArmed
                        ? w(
                            '◆ Crash Harvest Armed (Next Close) · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                            '◆ 暴跌止盈触发（次日收盘） · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                          )
                        : (hasVix45Tp
                              ? w(
                                  '◆ VIX>=45 Crash Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                  '◆ VIX≥45 极端恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                )
                              : (hasNearItmTp
                                    ? w(
                                        '◆ Near-ITM 1.05×K Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                        '◆ 近实值 1.05×K 恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                      )
                                    : (hasPut5xTp
                                          ? w(
                                              '◆ 5x Slow-Bear Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                              '◆ 5x 慢熊止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                            )
                                          : (hasItmTp
                                                ? w(
                                                    '◆ Deep-ITM Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                                    '◆ 实值恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                                  )
                                                : (has4xTp
                                                      ? w(
                                                          '◆ 4x Deep Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                                          '◆ 4x 深度恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                                        )
                                                      : (hasVixTp
                                                            ? w(
                                                                '◆ 1.10 Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                                                '◆ 1.10 恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                                              )
                                                            : (firstOpenEv?['slot_num'] != null
                                                                  ? w(
                                                                      '▼ Open Slot S${_numVal(firstOpenEv?['slot_num']).round()} Put @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)} (K=\$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)} · M7 ${_numVal(firstOpenEv?['crisis_prob']).round()}%)',
                                                                      '▼ 开启第 ${_numVal(firstOpenEv?['slot_num']).round()} 槽裸 Put @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)}（行权 \$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)} · 概率 ${_numVal(firstOpenEv?['crisis_prob']).round()}%）',
                                                                    )
                                                                  : w(
                                                                      '▼ Buy ${text(firstOpenEv?['tranche_type']) == 'naked_put' ? 'Naked Put' : 'Collar'} @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)} (K=\$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)})',
                                                                      '▼ 买${text(firstOpenEv?['tranche_type']) == 'naked_put' ? '首仓裸 Put' : '次仓领口'} @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)}（行权 \$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)}）',
                                                                    )))))))),
                    style: TextStyle(
                      color: hasTp ? _emerald : _amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (firstRoll50Ev != null) ...[
                  if (hasTp || hasOpen) const SizedBox(height: 4),
                  Builder(
                    builder: (_) {
                      final etRoll = text(firstRoll50Ev!['event_type']);
                      final dTag = etRoll.contains('75')
                          ? '75D'
                          : (etRoll.contains('30') ? '30D' : '50D');
                      return Text(
                        w(
                          '⟳ $dTag Hard Roll / Salvage · Recovered ${_fmtUsd(_numVal(firstRoll50Ev['exit_val_usd']))} (${_fmtUsd(_numVal(firstRoll50Ev['net_pnl_usd']), signed: true)})',
                          '⟳ 剩≤$dTag 硬滚仓/回收 · 残值 ${_fmtUsd(_numVal(firstRoll50Ev['exit_val_usd']))}（净盈亏 ${_fmtUsd(_numVal(firstRoll50Ev['net_pnl_usd']), signed: true)}）',
                        ),
                        style: const TextStyle(
                          color: _sky,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ],
                if (firstCcOpenEv != null) ...[
                  if (hasTp || hasOpen) const SizedBox(height: 4),
                  Text(
                    w(
                      '▲ Sell 25D 12Δ Call · K=\$${_numVal(firstCcOpenEv['kc']).toStringAsFixed(0)} (+${_numVal(firstCcOpenEv['otm_pct']).toStringAsFixed(1)}%) · Prem ${_fmtUsd(_numVal(firstCcOpenEv['prem_usd']), signed: true)}',
                      '▲ 卖 25D 12Δ Call · 行权 \$${_numVal(firstCcOpenEv['kc']).toStringAsFixed(0)}（+${_numVal(firstCcOpenEv['otm_pct']).toStringAsFixed(1)}%）· 收租 ${_fmtUsd(_numVal(firstCcOpenEv['prem_usd']), signed: true)}',
                    ),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (firstCcRollEv != null) ...[
                  if (hasTp || hasOpen || firstCcOpenEv != null)
                    const SizedBox(height: 4),
                  Builder(
                    builder: (_) {
                      final isCredit =
                          text(firstCcRollEv!['event_type']) ==
                          'cc_credit_roll';
                      final oldK = _numVal(firstCcRollEv['old_kc']);
                      final newK = firstCcRollEv['new_kc'] is num
                          ? (firstCcRollEv['new_kc'] as num).toDouble()
                          : null;
                      final net = _numVal(firstCcRollEv['net_pnl_usd']);
                      final moveTxt = newK != null
                          ? w(
                              '\$${oldK.toStringAsFixed(0)} -> \$${newK.toStringAsFixed(0)}',
                              '\$${oldK.toStringAsFixed(0)} → \$${newK.toStringAsFixed(0)}',
                            )
                          : w(
                              'Closed K=\$${oldK.toStringAsFixed(0)}',
                              '平旧 \$${oldK.toStringAsFixed(0)}（无虚值可展）',
                            );
                      return Text(
                        isCredit
                            ? w(
                                '↻ Δ0.55 Credit Roll 45D · $moveTxt (${_fmtUsd(net, signed: true)})',
                                '↻ Δ0.55 零成本 Roll 45D · $moveTxt（旧腿 ${_fmtUsd(net, signed: true)}）',
                              )
                            : w(
                                '↻ Δ0.45 Roll Up 30D · $moveTxt (${_fmtUsd(net, signed: true)})',
                                '↻ Δ0.45 展期 Roll 30D · $moveTxt（旧腿 ${_fmtUsd(net, signed: true)}）',
                              ),
                        style: const TextStyle(
                          color: _lilac,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ],
                if (firstCcStopEv != null) ...[
                  if (hasTp ||
                      hasOpen ||
                      firstCcOpenEv != null ||
                      firstCcRollEv != null)
                    const SizedBox(height: 4),
                  Text(
                    w(
                      '✕ Δ0.35 Call Stop Buyback · K=\$${_numVal(firstCcStopEv['kc']).toStringAsFixed(0)} (${_fmtUsd(_numVal(firstCcStopEv['net_pnl_usd']), signed: true)})',
                      '✕ Δ0.35 卖 Call 止损平仓 · 原行权 \$${_numVal(firstCcStopEv['kc']).toStringAsFixed(0)}（净盈亏 ${_fmtUsd(_numVal(firstCcStopEv['net_pnl_usd']), signed: true)}）',
                    ),
                    style: const TextStyle(
                      color: _coral,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (firstSpOpenEv != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    w(
                      '◎ Sell ${_numVal(firstSpOpenEv['dte']).round()}D 5% OTM Put · K=\$${_numVal(firstSpOpenEv['strike']).toStringAsFixed(0)} · Prem ${_fmtUsd(_numVal(firstSpOpenEv['prem_usd']), signed: true)}',
                      '◎ 卖 ${_numVal(firstSpOpenEv['dte']).round()}D 恐慌 Put · 行权 \$${_numVal(firstSpOpenEv['strike']).toStringAsFixed(0)} · 收租 ${_fmtUsd(_numVal(firstSpOpenEv['prem_usd']), signed: true)}',
                    ),
                    style: const TextStyle(
                      color: _amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (firstSpAssignEv != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    w(
                      '■ Put Assigned into Wheel · ${_numVal(firstSpAssignEv['shares']).toStringAsFixed(0)} sh @ \$${_numVal(firstSpAssignEv['strike']).toStringAsFixed(0)}',
                      '■ 恐慌 Put 接货进 Wheel · ${_numVal(firstSpAssignEv['shares']).toStringAsFixed(0)} 股 @ \$${_numVal(firstSpAssignEv['strike']).toStringAsFixed(0)}',
                    ),
                    style: const TextStyle(
                      color: _amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (firstWcCalledEv != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    w(
                      '◈ Wheel Call Exercised · Debt Cleared (${_fmtUsd(_numVal(firstWcCalledEv['net_pnl_usd']), signed: true)})',
                      '◈ Wheel Call 被行权清债去杠杆（净落袋 ${_fmtUsd(_numVal(firstWcCalledEv['net_pnl_usd']), signed: true)}）',
                    ),
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 5),
              Text(
                pinnedPitDate == text(row['date'])
                    ? w(
                        '● Pinned PIT replay active above',
                        '● 已锁定该日上方 PIT 回放',
                      )
                    : w(
                        'Click point to replay PIT Three Pillars above',
                        '点击该点在上方回放当日三支柱 PIT 状态',
                      ),
                style: TextStyle(
                  color: pinnedPitDate == text(row['date'])
                      ? _sky
                      : p.muted.withValues(alpha: 0.8),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroStatMetric({
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(sub, style: TextStyle(color: p.muted, fontSize: 11)),
      ],
    );
  }

  Map<String, dynamic> _resolveEngineAttribution(
    Map<String, dynamic> doc,
    Map<String, dynamic> stratSummary,
    Map<String, dynamic> bhSummary,
  ) {
    final byStrat = asMap(doc['engine_attribution_by_strategy']);
    final found = asMap(byStrat[selectedStrategyId]);
    if (found.isNotEmpty) return found;
    final bhNav = _numVal(bhSummary['end_nav']);
    final bhSh = _numVal(bhSummary['final_shares']);
    final totNav = _numVal(stratSummary['end_nav'], bhNav);
    final totSh = _numVal(stratSummary['final_shares'], bhSh);
    final totAlpha = totNav - bhNav;
    final hasE1 =
        selectedStrategyId != 'NoPut_CallOnly' &&
        selectedStrategyId != 'BH_Pure_QQQ';
    final hasE2 = selectedCcMode != 'cc_off';
    final hasE3 = selectedSpMode != 'sp_off';
    final activeCnt = (hasE1 ? 1 : 0) + (hasE2 ? 1 : 0) + (hasE3 ? 1 : 0);
    return {
      'base_end_nav': bhNav,
      'base_shares': bhSh,
      'base_cagr_pct': _numVal(bhSummary['cagr_pct']),
      'base_max_dd_pct': _numVal(bhSummary['max_dd_pct']),
      'base_calmar': _numVal(bhSummary['calmar']),
      'total_end_nav': totNav,
      'total_alpha_usd': totAlpha,
      'total_extra_shares': totSh - bhSh,
      'total_extra_shares_pct': bhSh > 0 ? ((totSh - bhSh) / bhSh) * 100 : 0.0,
      'active_engines_count': activeCnt,
      'correlations': const <String, dynamic>{},
      'engine1': {
        'active': hasE1,
        'delta_usd': hasE1 && !hasE2 && !hasE3 ? totAlpha : 0.0,
        'standalone_alpha_usd': hasE1 && !hasE2 && !hasE3 ? totAlpha : 0.0,
        'share_of_alpha_pct': hasE1 && !hasE2 && !hasE3 ? 100.0 : 0.0,
        'delta_shares': hasE1 && !hasE2 && !hasE3 ? (totSh - bhSh) : 0.0,
        'delta_extra_pct': hasE1 && !hasE2 && !hasE3 && bhSh > 0
            ? ((totSh - bhSh) / bhSh) * 100
            : 0.0,
        'delta_cagr_pp': hasE1 && !hasE2 && !hasE3
            ? _numVal(stratSummary['cagr_pct']) - _numVal(bhSummary['cagr_pct'])
            : 0.0,
        'delta_mdd_pp': hasE1 && !hasE2 && !hasE3
            ? _numVal(stratSummary['max_dd_pct']) -
                  _numVal(bhSummary['max_dd_pct'])
            : 0.0,
        'delta_calmar': hasE1 && !hasE2 && !hasE3
            ? _numVal(stratSummary['calmar']) - _numVal(bhSummary['calmar'])
            : 0.0,
        'tranches_total': _numVal(stratSummary['tranches_total']).round(),
        'tp_count': _numVal(stratSummary['tp_count']).round(),
        'naked_prem_spent_usd': _numVal(stratSummary['naked_prem_spent_usd']),
        'gross_put_monetized_usd': _numVal(
          stratSummary['gross_put_monetized_usd'],
        ),
        'pct_days_hedged': _numVal(stratSummary['pct_days_hedged']),
      },
      'engine2': {
        'active': hasE2,
        'delta_usd': !hasE1 && hasE2 && !hasE3 ? totAlpha : 0.0,
        'standalone_alpha_usd': !hasE1 && hasE2 && !hasE3 ? totAlpha : 0.0,
        'share_of_alpha_pct': !hasE1 && hasE2 && !hasE3 ? 100.0 : 0.0,
        'delta_shares': !hasE1 && hasE2 && !hasE3 ? (totSh - bhSh) : 0.0,
        'delta_extra_pct': !hasE1 && hasE2 && !hasE3 && bhSh > 0
            ? ((totSh - bhSh) / bhSh) * 100
            : 0.0,
        'delta_cagr_pp': 0.0,
        'delta_mdd_pp': 0.0,
        'delta_calmar': 0.0,
        'trades_count': _numVal(stratSummary['cc_trades_count']).round(),
        'active_years': _numVal(stratSummary['cc_active_years']).round(),
        'stop_count': _numVal(stratSummary['cc_stop_count']).round(),
        'roll_count': _numVal(stratSummary['cc_roll_count']).round(),
        'assigned_count': _numVal(stratSummary['cc_assigned_count']).round(),
        'gross_prem_usd': _numVal(stratSummary['cc_gross_prem_usd']),
        'gross_loss_usd': _numVal(stratSummary['cc_gross_loss_usd']),
        'funded_puts_usd': _numVal(stratSummary['cc_funded_puts_usd']),
      },
      'engine3': {
        'active': hasE3,
        'delta_usd': !hasE1 && !hasE2 && hasE3 ? totAlpha : 0.0,
        'standalone_alpha_usd': !hasE1 && !hasE2 && hasE3 ? totAlpha : 0.0,
        'share_of_alpha_pct': !hasE1 && !hasE2 && hasE3 ? 100.0 : 0.0,
        'delta_shares': !hasE1 && !hasE2 && hasE3 ? (totSh - bhSh) : 0.0,
        'delta_extra_pct': !hasE1 && !hasE2 && hasE3 && bhSh > 0
            ? ((totSh - bhSh) / bhSh) * 100
            : 0.0,
        'delta_cagr_pp': 0.0,
        'delta_mdd_pp': 0.0,
        'delta_calmar': 0.0,
        'sp_trades_count': _numVal(stratSummary['sp_trades_count']).round(),
        'sp_win_rate_pct': _numVal(stratSummary['sp_win_rate_pct']),
        'sp_assignments_count': _numVal(
          stratSummary['sp_assignments_count'],
        ).round(),
        'wc_trades_count': _numVal(stratSummary['wc_trades_count']).round(),
        'wc_called_away_count': _numVal(
          stratSummary['wc_called_away_count'],
        ).round(),
        'gross_prem_usd':
            _numVal(stratSummary['sp_gross_prem_usd']) +
            _numVal(stratSummary['wc_gross_prem_usd']),
        'margin_interest_usd': _numVal(stratSummary['margin_interest_usd']),
        'days_levered_stock': _numVal(
          stratSummary['days_levered_stock'],
        ).round(),
        'max_wheel_cycle_days': _numVal(
          stratSummary['max_wheel_cycle_days'],
        ).round(),
        'max_gross_stock_lev': _numVal(
          stratSummary['max_gross_stock_lev'],
          1.0,
        ),
      },
    };
  }

  Widget _buildThreeEngineWorkbench(
    Map<String, dynamic> doc, {
    required Map<String, dynamic> stratSummary,
    required Map<String, dynamic> bhSummary,
    required List<String> strategyTabs,
    required bool hasPutLayer,
    required bool rebasedMode,
    required bool compact,
    required bool desktop,
  }) {
    final attr = _resolveEngineAttribution(doc, stratSummary, bhSummary);
    final e1 = asMap(attr['engine1']);
    final e2 = asMap(attr['engine2']);
    final e3 = asMap(attr['engine3']);
    final corrs = asMap(attr['correlations']);
    final activeCount = _numVal(attr['active_engines_count']).round();
    final e1Active = e1['active'] == true;
    final e2Active = e2['active'] == true;
    final e3Active = e3['active'] == true;

    final corrTags = <String>[];
    if (corrs['e1_e2'] is num) {
      corrTags.add(
        'E1×E2 r=${(corrs['e1_e2'] as num).toDouble().toStringAsFixed(2)}',
      );
    }
    if (corrs['e1_e3'] is num) {
      corrTags.add(
        'E1×E3 r=${(corrs['e1_e3'] as num).toDouble().toStringAsFixed(2)}',
      );
    }
    if (corrs['e2_e3'] is num) {
      corrTags.add(
        'E2×E3 r=${(corrs['e2_e3'] as num).toDouble().toStringAsFixed(2)}',
      );
    }

    final card1 = _buildOrthogonalModuleCard(
      keyId: 'e1',
      indexTag: '01',
      title: _isM7Strategy
          ? w('M7-Graded Crisis Put Overlay', 'M7 三支柱分层买 Put')
          : w('Crisis Long Put Shield', '危机买 Put 保护'),
      regimeTag: _isM7Strategy
          ? w(
              '0.20% Calm Floor (VIX<=20) + 1.25%/slot M7G OTM Put',
              '0.20% 常态基底(VIX≤20) + 1.25%/槽 M7G 固定预算裸 Put',
            )
          : w(
              'Top warning · Left-tail convexity insurance',
              '高位预警 · 左尾防暴跌凸性保险',
            ),
      accent: _emerald,
      active: e1Active,
      deltaUsd: _numVal(e1['delta_usd']),
      sharePct: _numVal(e1['share_of_alpha_pct']),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            key: const ValueKey('crisis-put-strategy-bar'),
            spacing: 5,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Crisis Put Strategy:', '危机 Put 策略：'),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              for (final sid in strategyTabs) _buildCalmStrategyTab(sid),
            ],
          ),
          if (hasPutLayer && _isM7Strategy) ...[
            const SizedBox(height: 8),
            Wrap(
              key: const ValueKey('crisis-e1-m7-controls'),
              spacing: 5,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w('M7 Config:', 'M7 参数：'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                for (final oid in _putOtmIds)
                  InkWell(
                    key: ValueKey('crisis-e1-otm-$oid'),
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => _selectPutOtm(oid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7.5,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: selectedPutOtm == oid
                            ? _emerald.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: selectedPutOtm == oid
                              ? _emerald.withValues(alpha: 0.72)
                              : p.border,
                        ),
                      ),
                      child: Text(
                        _humanPutOtmShort(oid),
                        style: TextStyle(
                          color: selectedPutOtm == oid ? p.text : p.muted,
                          fontSize: 10.8,
                          fontWeight: selectedPutOtm == oid
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                if (_isCore3)
                  Container(
                    key: const ValueKey('crisis-e1-core3-roll-locked'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7.5,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _sky.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: _sky.withValues(alpha: 0.55)),
                    ),
                    child: Text(
                      w('Locked Adaptive 125/90', '锁定自适应 125/90'),
                      style: const TextStyle(
                        color: _sky,
                        fontSize: 10.8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  for (final rid in _rollModeIds)
                    InkWell(
                      key: ValueKey('crisis-e1-roll-$rid'),
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => _selectRollMode(rid),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7.5,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selectedRollMode == rid
                              ? _sky.withValues(alpha: 0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: selectedRollMode == rid
                                ? _sky.withValues(alpha: 0.72)
                                : p.border,
                          ),
                        ),
                        child: Text(
                          _humanRollModeShort(rid),
                          style: TextStyle(
                            color: selectedRollMode == rid ? p.text : p.muted,
                            fontSize: 10.8,
                            fontWeight: selectedRollMode == rid
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                for (final tid in _m7TpModeIds)
                  InkWell(
                    key: ValueKey('crisis-e1-tp-$tid'),
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => _selectM7TpMode(tid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7.5,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: selectedM7TpMode == tid
                            ? _amber.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: selectedM7TpMode == tid
                              ? _amber.withValues(alpha: 0.72)
                              : p.border,
                        ),
                      ),
                      child: Text(
                        _humanM7TpModeShort(tid),
                        style: TextStyle(
                          color: selectedM7TpMode == tid ? p.text : p.muted,
                          fontSize: 10.8,
                          fontWeight: selectedM7TpMode == tid
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _humanM7EngineHint(stratSummary),
              key: const ValueKey('crisis-m7-engine-hint'),
              style: TextStyle(color: p.muted, fontSize: 11, height: 1.38),
            ),
          ] else if (hasPutLayer) ...[
            const SizedBox(height: 8),
            Wrap(
              key: const ValueKey('crisis-tp-mode-bar'),
              spacing: 5,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w('Put Take-Profit:', 'Put 止盈规则：'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                for (final mid in _tpModeIds) _buildCalmTpModeTab(mid),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _humanTpModeHint(selectedTpMode),
              key: const ValueKey('crisis-tp-mode-hint'),
              style: TextStyle(color: p.muted, fontSize: 11, height: 1.38),
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              w(
                'Crisis Put layer OFF · Pure equity + selected overlay sleeves only.',
                '危机 Put 保护关闭 · 仅保留现货底仓与已开启的卖权叠加模块。',
              ),
              style: TextStyle(color: p.muted, fontSize: 11, height: 1.38),
            ),
          ],
        ],
      ),
    );

    final card2 = _buildOrthogonalModuleCard(
      keyId: 'e2',
      indexTag: '02',
      title: w('Calm-Regime Short Call', '平时卖 Call 收租'),
      regimeTag: w(
        'Within 3% of ATH · Self-funding VRP rent',
        '距前高 ≤ 3% 平静牛市 · 免费抵保费',
      ),
      accent: _sky,
      active: e2Active,
      deltaUsd: _numVal(e2['delta_usd']),
      sharePct: _numVal(e2['share_of_alpha_pct']),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            key: const ValueKey('crisis-cc-mode-bar'),
            spacing: 5,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Overlay Short Call:', '叠加平时卖 Call：'),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              for (final cid in _ccModeIds) _buildCalmCcModeTab(cid),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _humanCcModeHint(selectedCcMode, stratSummary),
            key: const ValueKey('crisis-cc-mode-hint'),
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.38),
          ),
        ],
      ),
    );

    final card3 = _buildOrthogonalModuleCard(
      keyId: 'e3',
      indexTag: '03',
      title: w('Panic Put Reverse Wheel', '恐慌卖 Put Wheel'),
      regimeTag: w(
        'VIX/3M >= 1.00 inversion · Reclaim K -> 30D 0.35Δ Call',
        'VIX/3M ≥ 1.00 倒挂抄底 · 涨回成本卖 30D 0.35Δ Call',
      ),
      accent: _amber,
      active: e3Active,
      deltaUsd: _numVal(e3['delta_usd']),
      sharePct: _numVal(e3['share_of_alpha_pct']),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            key: const ValueKey('crisis-sp-mode-bar'),
            spacing: 5,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Panic Put Wheel:', '恐慌卖 Put Wheel：'),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              for (final sid in _spModeIds) _buildCalmSpModeTab(sid),
            ],
          ),
          if (selectedSpMode != 'sp_off') ...[
            const SizedBox(height: 7),
            Wrap(
              key: const ValueKey('crisis-wc-mode-bar'),
              spacing: 5,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w('Wheel Call:', 'Wheel Call 出场：'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                for (final wid in _wcModeIds) _buildCalmWcModeTab(wid),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _humanWcModeFormulaHint(selectedWcMode, stratSummary),
              key: const ValueKey('crisis-wc-mode-hint'),
              style: TextStyle(color: _amber, fontSize: 11, height: 1.35),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            _humanSpModeHint(selectedSpMode, stratSummary),
            key: const ValueKey('crisis-sp-mode-hint'),
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.38),
          ),
        ],
      ),
    );

    return Column(
      key: const ValueKey('crisis-three-engine-grid'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w(
                    'Three Orthogonal Option Engines',
                    '三大正交期权引擎 · 模块化独立组合',
                  ),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _emerald.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _emerald.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    w('$activeCount / 3 Active', '$activeCount / 3 运行中'),
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (corrTags.isNotEmpty)
                  Container(
                    key: const ValueKey('crisis-engine-corr-pill'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: p.text.withValues(alpha: 0.035),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: p.border),
                    ),
                    child: Text(
                      w(
                        'Daily Alpha Corr: ${corrTags.join(' · ')}',
                        '正交日度 Alpha 相关：${corrTags.join(' · ')}',
                      ),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
            if (!rebasedMode)
              InkWell(
                key: const ValueKey('crisis-scale-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => useLogScale = !useLogScale),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    useLogScale
                        ? w('Scale: Log', '坐标：对数')
                        : w('Scale: Linear', '坐标：线性'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              )
            else
              InkWell(
                key: const ValueKey('crisis-zoom-reset-btn'),
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  setState(() {
                    selectedWindowId = 'ALL';
                    hoverIndex = -1;
                  });
                  _emitSelection();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    w('Reset to All 12Y', '返回全部 12 年'),
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (desktop)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: card1),
                _buildOrthogonalJoiner(),
                Expanded(child: card2),
                _buildOrthogonalJoiner(),
                Expanded(child: card3),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              card1,
              const SizedBox(height: 8),
              card2,
              const SizedBox(height: 8),
              card3,
            ],
          ),
      ],
    );
  }

  Widget _buildOrthogonalJoiner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Center(
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.text.withValues(alpha: 0.04),
            shape: BoxShape.circle,
            border: Border.all(color: p.border),
          ),
          child: Text(
            '⊕',
            style: TextStyle(
              color: p.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOrthogonalModuleCard({
    required String keyId,
    required String indexTag,
    required String title,
    required String regimeTag,
    required Color accent,
    required bool active,
    required double deltaUsd,
    required double sharePct,
    required Widget body,
  }) {
    final borderCol = active ? accent.withValues(alpha: 0.42) : p.border;
    final bgCol = active
        ? accent.withValues(alpha: 0.045)
        : p.text.withValues(alpha: 0.018);
    final statusBadge = active
        ? '${_fmtUsdCompact(deltaUsd, signed: true)} · ${sharePct.toStringAsFixed(0)}%'
        : w('Off', '已关闭');

    return Container(
      key: ValueKey('crisis-engine-card-$keyId'),
      decoration: BoxDecoration(
        color: bgCol,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderCol, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 2.5,
              color: active ? accent : p.border.withValues(alpha: 0.6),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5.5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: (active ? accent : p.muted).withValues(
                            alpha: 0.16,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          indexTag,
                          style: TextStyle(
                            color: active ? accent : p.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: active ? p.text : p.muted,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6.5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: active
                              ? accent.withValues(alpha: 0.14)
                              : p.text.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusBadge,
                          style: TextStyle(
                            color: active
                                ? (deltaUsd < 0 ? _coral : accent)
                                : p.muted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    regimeTag,
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(height: 1, color: p.border.withValues(alpha: 0.65)),
                  const SizedBox(height: 8),
                  body,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEngineAttributionPanel(
    Map<String, dynamic> doc, {
    required Map<String, dynamic> stratSummary,
    required Map<String, dynamic> bhSummary,
    required bool compact,
    required bool desktop,
  }) {
    final attr = _resolveEngineAttribution(doc, stratSummary, bhSummary);
    final e1 = asMap(attr['engine1']);
    final e2 = asMap(attr['engine2']);
    final e3 = asMap(attr['engine3']);
    final corrs = asMap(attr['correlations']);

    final baseNav = _numVal(attr['base_end_nav']);
    final totNav = _numVal(attr['total_end_nav']);
    final totAlpha = _numVal(attr['total_alpha_usd']);
    final d1 = _numVal(e1['delta_usd']);
    final d2 = _numVal(e2['delta_usd']);
    final d3 = _numVal(e3['delta_usd']);
    final s1Pct = _numVal(e1['share_of_alpha_pct']);
    final s2Pct = _numVal(e2['share_of_alpha_pct']);
    final s3Pct = _numVal(e3['share_of_alpha_pct']);

    final attrCard1 = _buildEngineAttributionCard(
      keyId: 'e1',
      indexTag: '01',
      title: w('Engine 1 · Crisis Put Shield', '模块 01 · 危机买 Put 保护'),
      regimeRole: w(
        'Active in top warning & crash left tail',
        '分工体制：高位预警与暴跌左尾护盘',
      ),
      accent: _emerald,
      active: e1['active'] == true,
      deltaUsd: d1,
      standaloneUsd: _numVal(e1['standalone_alpha_usd']),
      sharePct: s1Pct,
      deltaShares: _numVal(e1['delta_shares']),
      deltaExtraPct: _numVal(e1['delta_extra_pct']),
      deltaCagrPp: _numVal(e1['delta_cagr_pp']),
      deltaMddPp: _numVal(e1['delta_mdd_pp']),
      deltaCalmar: _numVal(e1['delta_calmar']),
      telemetry: e1['active'] == true
          ? w(
              '${_numVal(e1['tranches_total']).round()} tranches · ${_numVal(e1['tp_count']).round()} TP harvests · Put spend ${_fmtUsdCompact(_numVal(e1['naked_prem_spent_usd']))} · Gross monetized ${_fmtUsdCompact(_numVal(e1['gross_put_monetized_usd']))} · Hedged ${_numVal(e1['pct_days_hedged']).toStringAsFixed(1)}% days',
              '共 ${_numVal(e1['tranches_total']).round()} 笔保护 · ${_numVal(e1['tp_count']).round()} 次止盈换股 · 裸 Put 保费 ${_fmtUsdCompact(_numVal(e1['naked_prem_spent_usd']))} · 累计毛赔付 ${_fmtUsdCompact(_numVal(e1['gross_put_monetized_usd']))} · 持盾天数 ${_numVal(e1['pct_days_hedged']).toStringAsFixed(1)}%',
            )
          : w(
              'Disabled · Select U1 / B1c / D2 above to enable left-tail crisis protection.',
              '未启用 · 在上方选择 U1 / B1c / D2 开启左尾暴跌保险。',
            ),
    );

    final attrCard2 = _buildEngineAttributionCard(
      keyId: 'e2',
      indexTag: '02',
      title: w('Engine 2 · Calm Short Call', '模块 02 · 平时卖 Call 收租'),
      regimeRole: w(
        'Active in calm bull trends (ATH <= 3%)',
        '分工体制：平静牛市收租 · 免费抵 Put 保费',
      ),
      accent: _sky,
      active: e2['active'] == true,
      deltaUsd: d2,
      standaloneUsd: _numVal(e2['standalone_alpha_usd']),
      sharePct: s2Pct,
      deltaShares: _numVal(e2['delta_shares']),
      deltaExtraPct: _numVal(e2['delta_extra_pct']),
      deltaCagrPp: _numVal(e2['delta_cagr_pp']),
      deltaMddPp: _numVal(e2['delta_mdd_pp']),
      deltaCalmar: _numVal(e2['delta_calmar']),
      telemetry: e2['active'] == true
          ? w(
              '${_numVal(e2['trades_count']).round()} trades / ${_numVal(e2['active_years']).round()} yrs · ${_numVal(e2['assigned_count']).round()} breached · ${_numVal(e2['stop_count']).round() + _numVal(e2['roll_count']).round()} stops/rolls · Gross rent ${_fmtUsdCompact(_numVal(e2['gross_prem_usd']))} · Put cost funded ${_fmtUsdCompact(_numVal(e2['funded_puts_usd']))}',
              '覆盖 ${_numVal(e2['active_years']).round()} 年共 ${_numVal(e2['trades_count']).round()} 笔 · 穿价 ${_numVal(e2['assigned_count']).round()} 次 · 止损/Roll ${_numVal(e2['stop_count']).round() + _numVal(e2['roll_count']).round()} 次 · 毛收租 ${_fmtUsdCompact(_numVal(e2['gross_prem_usd']))} · 抵 Put 保费 ${_fmtUsdCompact(_numVal(e2['funded_puts_usd']))}',
            )
          : w(
              'Disabled · Select 12Δ Short Call above to monetize calm upside VRP.',
              '未启用 · 在上方开启平时 12Δ 卖 Call 收割牛市右翼 VRP。',
            ),
    );

    final attrCard3 = _buildEngineAttributionCard(
      keyId: 'e3',
      indexTag: '03',
      title: w('Engine 3 · Panic Put Wheel', '模块 03 · 恐慌卖 Put Wheel'),
      regimeRole: w(
        'Active in VIX/3M >= 1.00 inversion rebounds',
        '分工体制：VIX 倒挂期卖恐慌保费与反弹接货',
      ),
      accent: _amber,
      active: e3['active'] == true,
      deltaUsd: d3,
      standaloneUsd: _numVal(e3['standalone_alpha_usd']),
      sharePct: s3Pct,
      deltaShares: _numVal(e3['delta_shares']),
      deltaExtraPct: _numVal(e3['delta_extra_pct']),
      deltaCagrPp: _numVal(e3['delta_cagr_pp']),
      deltaMddPp: _numVal(e3['delta_mdd_pp']),
      deltaCalmar: _numVal(e3['delta_calmar']),
      telemetry: e3['active'] == true
          ? w(
              '${_numVal(e3['sp_trades_count']).round()} puts (${_numVal(e3['sp_win_rate_pct']).toStringAsFixed(1)}% win, ${_numVal(e3['sp_assignments_count']).round()} asgn) · ${_numVal(e3['wc_trades_count']).round()} WC (${_numVal(e3['wc_called_away_count']).round()} cleared) · Prem ${_fmtUsdCompact(_numVal(e3['gross_prem_usd']))} · Interest ${_fmtUsdCompact(_numVal(e3['margin_interest_usd']))} · ${_numVal(e3['days_levered_stock']).round()}d lev (max ${_numVal(e3['max_gross_stock_lev'], 1.0).toStringAsFixed(2)}x)',
              '${_numVal(e3['sp_trades_count']).round()} 笔 Put（胜率 ${_numVal(e3['sp_win_rate_pct']).toStringAsFixed(1)}% · 接货 ${_numVal(e3['sp_assignments_count']).round()} 次）· ${_numVal(e3['wc_trades_count']).round()} 笔 Wheel Call（清债 ${_numVal(e3['wc_called_away_count']).round()} 次）· 总租 ${_fmtUsdCompact(_numVal(e3['gross_prem_usd']))} · 12年息 ${_fmtUsdCompact(_numVal(e3['margin_interest_usd']))} · 杠杆 ${_numVal(e3['days_levered_stock']).round()} 天（峰值 ${_numVal(e3['max_gross_stock_lev'], 1.0).toStringAsFixed(2)}x）',
            )
          : w(
              'Disabled · Strictly 0 margin debt & 1.00x max stock exposure.',
              '未启用 · 严格 0 融资负债、0 利息、股票峰值敞口 1.00x。',
            ),
    );

    return Container(
      key: const ValueKey('crisis-engine-attribution-panel'),
      padding: EdgeInsets.all(compact ? 11 : 14),
      decoration: BoxDecoration(
        color: p.text.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _activeComboBadgeText(),
                        key: const ValueKey('crisis-active-combo-badge'),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _bridgeEquationPill(
                            label: w('QQQ B&H', '死拿基准'),
                            value: _fmtUsdCompact(baseNav),
                            color: p.muted,
                          ),
                          Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                          _bridgeEquationPill(
                            label: w('E1 Put', '引擎1'),
                            value: e1['active'] == true
                                ? _fmtUsdCompact(d1, signed: true)
                                : w('Off', '关'),
                            color: e1['active'] == true ? _emerald : p.muted,
                          ),
                          Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                          _bridgeEquationPill(
                            label: w('E2 Call', '引擎2'),
                            value: e2['active'] == true
                                ? _fmtUsdCompact(d2, signed: true)
                                : w('Off', '关'),
                            color: e2['active'] == true ? _sky : p.muted,
                          ),
                          Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                          _bridgeEquationPill(
                            label: w('E3 Wheel', '引擎3'),
                            value: e3['active'] == true
                                ? _fmtUsdCompact(d3, signed: true)
                                : w('Off', '关'),
                            color: e3['active'] == true ? _amber : p.muted,
                          ),
                          Text('=', style: TextStyle(color: p.muted, fontSize: 11)),
                          _bridgeEquationPill(
                            label: w('Total', '总终值'),
                            value: _fmtUsdCompact(totNav),
                            color: p.text,
                            bold: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildAttributionToggleButton(),
              ],
            )
          else ...[
            Text(
              _activeComboBadgeText(),
              key: const ValueKey('crisis-active-combo-badge'),
              style: TextStyle(
                color: p.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _bridgeEquationPill(
                  label: w('QQQ B&H', '死拿基准'),
                  value: _fmtUsdCompact(baseNav),
                  color: p.muted,
                ),
                Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                _bridgeEquationPill(
                  label: w('E1', '引擎1'),
                  value: e1['active'] == true
                      ? _fmtUsdCompact(d1, signed: true)
                      : w('Off', '关'),
                  color: e1['active'] == true ? _emerald : p.muted,
                ),
                Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                _bridgeEquationPill(
                  label: w('E2', '引擎2'),
                  value: e2['active'] == true
                      ? _fmtUsdCompact(d2, signed: true)
                      : w('Off', '关'),
                  color: e2['active'] == true ? _sky : p.muted,
                ),
                Text('+', style: TextStyle(color: p.muted, fontSize: 11)),
                _bridgeEquationPill(
                  label: w('E3', '引擎3'),
                  value: e3['active'] == true
                      ? _fmtUsdCompact(d3, signed: true)
                      : w('Off', '关'),
                  color: e3['active'] == true ? _amber : p.muted,
                ),
                Text('=', style: TextStyle(color: p.muted, fontSize: 11)),
                _bridgeEquationPill(
                  label: w('Total', '总终值'),
                  value: _fmtUsdCompact(totNav),
                  color: p.text,
                  bold: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: _buildAttributionToggleButton(),
            ),
          ],
          const SizedBox(height: 10),
          _buildStackedAlphaShareBar(
            totAlpha: totAlpha,
            d1: d1,
            d2: d2,
            d3: d3,
            s1Pct: s1Pct,
            s2Pct: s2Pct,
            s3Pct: s3Pct,
            e1Active: e1['active'] == true,
            e2Active: e2['active'] == true,
            e3Active: e3['active'] == true,
          ),
          if (showEngineAttribution) ...[
            const SizedBox(height: 12),
            if (desktop)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: attrCard1),
                    const SizedBox(width: 10),
                    Expanded(child: attrCard2),
                    const SizedBox(width: 10),
                    Expanded(child: attrCard3),
                  ],
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  attrCard1,
                  const SizedBox(height: 8),
                  attrCard2,
                  const SizedBox(height: 8),
                  attrCard3,
                ],
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w(
                    'Orthogonal Regime Split: E1 guards crash left tail (long convexity) · E2 harvests calm bull VRP · E3 monetizes inversion rebounds (marginal step-up from QQQ B&H).',
                    '三大正交模块分工：引擎 1 守暴跌左尾买凸性 · 引擎 2 收牛市平静租抵保费 · 引擎 3 吃倒挂恐慌反弹（均为基于死拿 QQQ 递进叠加的精确边际归因）。',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
                if (corrs['e1_e3'] is num || corrs['e2_e3'] is num)
                  Text(
                    w(
                      'Note: Negative E1×E3 corr reflects left-tail convexity offset vs rebound beta (cap <= 10% preserves shield).',
                      '风控提示：E1×E3 负相关含暴跌日凸性对抵效应，建议锁死 10% 杠杆帽保护左尾。',
                    ),
                    style: TextStyle(
                      color: _amber.withValues(alpha: 0.9),
                      fontSize: 10.8,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAttributionToggleButton() {
    return InkWell(
      key: const ValueKey('crisis-engine-attribution-toggle'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(
        () => showEngineAttribution = !showEngineAttribution,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: p.text.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              showEngineAttribution
                  ? w('Hide 3-Engine Breakdown', '收起三大块分部贡献')
                  : w('Expand 3-Engine Breakdown', '展开三大块分部贡献'),
              style: TextStyle(
                color: p.text,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              showEngineAttribution
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 16,
              color: p.muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bridgeEquationPill({
    required String label,
    required String value,
    required Color color,
    bool bold = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bold ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: bold ? 0.35 : 0.25),
        ),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 11, color: p.muted),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStackedAlphaShareBar({
    required double totAlpha,
    required double d1,
    required double d2,
    required double d3,
    required double s1Pct,
    required double s2Pct,
    required double s3Pct,
    required bool e1Active,
    required bool e2Active,
    required bool e3Active,
  }) {
    final pos1 = e1Active && d1 > 0 ? d1 : 0.0;
    final pos2 = e2Active && d2 > 0 ? d2 : 0.0;
    final pos3 = e3Active && d3 > 0 ? d3 : 0.0;
    final sumPos = pos1 + pos2 + pos3;

    final flex1 = sumPos > 0 ? (pos1 / sumPos * 1000).round() : 0;
    final flex2 = sumPos > 0 ? (pos2 / sumPos * 1000).round() : 0;
    final flex3 = sumPos > 0 ? (pos3 / sumPos * 1000).round() : 0;

    return Column(
      key: const ValueKey('crisis-engine-alpha-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 8,
            child: sumPos <= 0
                ? Container(color: p.border)
                : Row(
                    children: [
                      if (flex1 > 0)
                        Expanded(
                          flex: flex1,
                          child: Container(color: _emerald),
                        ),
                      if (flex2 > 0) ...[
                        if (flex1 > 0) const SizedBox(width: 2),
                        Expanded(flex: flex2, child: Container(color: _sky)),
                      ],
                      if (flex3 > 0) ...[
                        if (flex1 > 0 || flex2 > 0) const SizedBox(width: 2),
                        Expanded(flex: flex3, child: Container(color: _amber)),
                      ],
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _alphaLegendDot(
              color: _emerald,
              active: e1Active,
              textStr: e1Active
                  ? w(
                      'E1 Crisis Put: ${s1Pct.toStringAsFixed(1)}% (${_fmtUsdCompact(d1, signed: true)})',
                      '引擎 1 危机买 Put：${s1Pct.toStringAsFixed(1)}%（${_fmtUsdCompact(d1, signed: true)}）',
                    )
                  : w('E1 Crisis Put: Off', '引擎 1 危机买 Put：关闭'),
            ),
            _alphaLegendDot(
              color: _sky,
              active: e2Active,
              textStr: e2Active
                  ? w(
                      'E2 Short Call: ${s2Pct.toStringAsFixed(1)}% (${_fmtUsdCompact(d2, signed: true)})',
                      '引擎 2 平时卖 Call：${s2Pct.toStringAsFixed(1)}%（${_fmtUsdCompact(d2, signed: true)}）',
                    )
                  : w('E2 Short Call: Off', '引擎 2 平时卖 Call：关闭'),
            ),
            _alphaLegendDot(
              color: _amber,
              active: e3Active,
              textStr: e3Active
                  ? w(
                      'E3 Put Wheel: ${s3Pct.toStringAsFixed(1)}% (${_fmtUsdCompact(d3, signed: true)})',
                      '引擎 3 恐慌 Wheel：${s3Pct.toStringAsFixed(1)}%（${_fmtUsdCompact(d3, signed: true)}）',
                    )
                  : w('E3 Put Wheel: Off', '引擎 3 恐慌 Wheel：关闭'),
            ),
            Text(
              w(
                'Total Net Alpha ${_fmtUsdCompact(totAlpha, signed: true)}',
                '合计超额 ${_fmtUsdCompact(totAlpha, signed: true)}',
              ),
              style: TextStyle(
                color: p.muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _alphaLegendDot({
    required Color color,
    required bool active,
    required String textStr,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? color : p.muted.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            textStr,
            style: TextStyle(
              color: active ? p.text : p.muted,
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEngineAttributionCard({
    required String keyId,
    required String indexTag,
    required String title,
    required String regimeRole,
    required Color accent,
    required bool active,
    required double deltaUsd,
    required double standaloneUsd,
    required double sharePct,
    required double deltaShares,
    required double deltaExtraPct,
    required double deltaCagrPp,
    required double deltaMddPp,
    required double deltaCalmar,
    required String telemetry,
  }) {
    final shareFrac = active ? (sharePct.clamp(0.0, 100.0) / 100.0) : 0.0;
    final mddColor = !active
        ? p.muted
        : (deltaMddPp > 0.05
              ? _emerald
              : (deltaMddPp < -0.05 ? _coral : p.text));
    final mddStr = !active
        ? '—'
        : (deltaMddPp >= 0
              ? w(
                  'MDD +${deltaMddPp.toStringAsFixed(1)}pp (Less DD)',
                  '回撤改善 +${deltaMddPp.toStringAsFixed(1)}%',
                )
              : w(
                  'MDD ${deltaMddPp.toStringAsFixed(1)}pp (Wider DD)',
                  '回撤扩大 ${deltaMddPp.toStringAsFixed(1)}%',
                ));
    final calmarStr = !active
        ? '—'
        : w(
            'Calmar ${deltaCalmar >= 0 ? '+' : ''}${deltaCalmar.toStringAsFixed(3)}',
            '卡玛 ${deltaCalmar >= 0 ? '+' : ''}${deltaCalmar.toStringAsFixed(3)}',
          );

    return Container(
      key: ValueKey('crisis-attr-card-$keyId'),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: active
            ? p.card.withValues(alpha: 0.9)
            : p.text.withValues(alpha: 0.015),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.32) : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: active ? accent : p.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? p.text : p.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                active
                    ? w(
                        '${sharePct.toStringAsFixed(1)}% share',
                        '占超额 ${sharePct.toStringAsFixed(1)}%',
                      )
                    : w('Inactive', '未启用'),
                style: TextStyle(
                  color: active ? accent : p.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            regimeRole,
            style: TextStyle(color: p.muted, fontSize: 10.5),
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: shareFrac,
              minHeight: 4,
              backgroundColor: p.border.withValues(alpha: 0.55),
              color: active ? accent : p.muted.withValues(alpha: 0.3),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: _buildAttributionMetricCell(
                  label: w('Marginal Alpha', '边际增量 Alpha'),
                  value: active
                      ? w(
                          'Delta ${_fmtUsd(deltaUsd, signed: true)}',
                          '增量 ${_fmtUsd(deltaUsd, signed: true)}',
                        )
                      : '—',
                  sub: active
                      ? w(
                          'Solo ${_fmtUsdCompact(standaloneUsd, signed: true)}',
                          '独立运行 ${_fmtUsdCompact(standaloneUsd, signed: true)}',
                        )
                      : w('Turn on above', '上方开启生效'),
                  valueColor: active
                      ? (deltaUsd < 0 ? _coral : accent)
                      : p.muted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildAttributionMetricCell(
                  label: w('Extra QQQ Shares', '多买 QQQ 股数'),
                  value: active
                      ? w(
                          '${_fmtShares(deltaShares, signed: true)} sh',
                          '${_fmtShares(deltaShares, signed: true)} 股',
                        )
                      : '—',
                  sub: active
                      ? w(
                          '${_fmtPct(deltaExtraPct)} vs BH',
                          '较死拿 ${_fmtPct(deltaExtraPct)}',
                        )
                      : '—',
                  valueColor: active ? p.text : p.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildAttributionMetricCell(
                  label: w('CAGR Lift', '年化 CAGR 贡献'),
                  value: active
                      ? '${deltaCagrPp >= 0 ? '+' : ''}${deltaCagrPp.toStringAsFixed(2)}%'
                      : '—',
                  sub: calmarStr,
                  valueColor: active
                      ? (deltaCagrPp < 0 ? _coral : p.text)
                      : p.muted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildAttributionMetricCell(
                  label: w('Drawdown Impact', '最大回撤影响'),
                  value: mddStr,
                  sub: active
                      ? (deltaMddPp >= 0
                            ? w('Risk-reducing sleeve', '降低组合波动回撤')
                            : w('Leverage risk trade-off', '轻杠杆收益换回撤'))
                      : '—',
                  valueColor: mddColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: p.border.withValues(alpha: 0.6)),
          const SizedBox(height: 6),
          Text(
            telemetry,
            style: TextStyle(color: p.muted, fontSize: 10.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildAttributionMetricCell({
    required String label,
    required String value,
    required String sub,
    required Color valueColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: p.muted, fontSize: 10.2)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: valueColor,
            fontSize: 12.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 10.2),
        ),
      ],
    );
  }

  Widget _buildCalmCcModeTab(String modeId) {
    final active = selectedCcMode == modeId;
    final isOff = modeId == 'cc_off';
    final accent = isOff ? p.muted : _sky;
    return InkWell(
      key: ValueKey('crisis-cc-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectCcMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: isOff ? 0.12 : 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: isOff ? 0.45 : 0.72)
                : p.border,
          ),
        ),
        child: Text(
          _humanCcModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmTpModeTab(String modeId) {
    final active = selectedTpMode == modeId;
    return InkWell(
      key: ValueKey('crisis-tp-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectTpMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active
              ? _emerald.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.72) : p.border,
          ),
        ),
        child: Text(
          _humanTpModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmSpModeTab(String modeId) {
    final active = selectedSpMode == modeId;
    final isOff = modeId == 'sp_off';
    final accent = isOff ? p.muted : _amber;
    return InkWell(
      key: ValueKey('crisis-sp-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectSpMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: isOff ? 0.12 : 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: isOff ? 0.45 : 0.72)
                : p.border,
          ),
        ),
        child: Text(
          _humanSpModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmWcModeTab(String modeId) {
    final active = selectedWcMode == modeId;
    return InkWell(
      key: ValueKey('crisis-wc-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(7),
      onTap: () => _selectWcMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active
              ? _amber.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? _amber.withValues(alpha: 0.72) : p.border,
          ),
        ),
        child: Text(
          _humanWcModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmStrategyTab(String sid) {
    final active = selectedStrategyId == sid;
    final isOff = sid == 'NoPut_CallOnly';
    final accent = isOff
        ? p.muted
        : (sid == 'Core3_Adaptive' ? _sky : _emerald);
    return InkWell(
      key: ValueKey('crisis-strategy-pill-$sid'),
      borderRadius: BorderRadius.circular(7),
      onTap: () {
        if (selectedStrategyId == sid) return;
        if (sid == 'Core3_Adaptive') {
          _selectProfile('core3_adaptive');
          return;
        }
        if (sid == 'M7G_Graded') {
          _selectProfile('full_m7_adaptive');
          return;
        }
        setState(() {
          selectedStrategyId = sid;
        });
        if (sid == 'NoPut_CallOnly' &&
            selectedCcMode == 'cc_off' &&
            selectedSpMode == 'sp_off') {
          _selectCcMode('cc_d12_d35');
          return;
        }
        _emitSelection();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4.5),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: isOff ? 0.12 : 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: isOff ? 0.45 : 0.72)
                : p.border,
          ),
        ),
        child: Text(
          _humanStrategyLabel(sid),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 11.2,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCleanZoomChip({
    required String id,
    required String label,
    required bool isLive,
  }) {
    final active = selectedWindowId == id;
    return InkWell(
      key: ValueKey('crisis-zoom-pill-$id'),
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() {
          selectedWindowId = id;
          if (id != 'ALL' && id != '1Y' && id != '3Y') {
            activeForensicWindowId = id;
            showFullLedger = false;
          }
          hoverIndex = -1;
        });
        _emitSelection();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
        decoration: BoxDecoration(
          color: active
              ? _emerald.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.65) : p.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLive) ...[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: _coral,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: active ? p.text : p.muted,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cleanLegendItem({
    required Color color,
    required bool dashed,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dashed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 5, height: 2, color: color),
              const SizedBox(width: 2),
              Container(width: 5, height: 2, color: color),
            ],
          )
        else
          Container(width: 12, height: 2.5, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
      ],
    );
  }

  Widget _cleanVectorMarkerLegend({
    required _CrisisMarkerKind kind,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CustomPaint(painter: _CrisisMarkerGlyphPainter(kind: kind)),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
      ],
    );
  }

  void _updateHoverFromDx(double dx, double width, int count) {
    if (count <= 1 || width <= 64) return;
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, width - padL - padR);
    final rel = ((dx - padL) / plotW).clamp(0.0, 1.0);
    final idx = (rel * (count - 1)).round().clamp(0, count - 1);
    if (idx != hoverIndex) {
      setState(() => hoverIndex = idx);
    }
  }

  void _pinPitFromDx(
    double dx,
    double width,
    List<Map<String, dynamic>> visibleDaily,
  ) {
    final count = visibleDaily.length;
    if (count <= 1 || width <= 64) return;
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, width - padL - padR);
    final rel = ((dx - padL) / plotW).clamp(0.0, 1.0);
    final idx = (rel * (count - 1)).round().clamp(0, count - 1);
    final row = visibleDaily[idx];
    final d = text(row['date']);
    if (d.isEmpty) return;
    setState(() => hoverIndex = idx);
    _selectPitDate(d, barRow: row);
  }

  // ===========================================================================
  // BLOCK 4: Zoomed-In Crisis Story & Clean Action Timeline (危机复盘与具体操作)
  // ===========================================================================
  Widget _buildCrisisStoryAndTimelineBlock(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final windows = asList(doc['crisis_windows']);
    final forensicWin =
        _findWindow(doc, activeForensicWindowId) ??
        (windows.isNotEmpty ? windows.last : const <String, dynamic>{});
    final winId = text(forensicWin['id']);
    final winStratStats = asMap(
      asMap(forensicWin['strategy_stats'])[selectedStrategyId],
    );

    final fullLedger = _currentLedgerForStrategy(doc);
    final winStart = text(forensicWin['start_date']);
    final winEnd = text(forensicWin['end_date']);

    final filteredTranches = showFullLedger
        ? fullLedger.reversed.toList()
        : fullLedger.where((tr) {
            final ent = text(tr['entry_date']);
            final ex = text(tr['exit_date']);
            final inStart = ent.compareTo(winEnd) <= 0;
            final inEnd = ex.isEmpty || ex.compareTo(winStart) >= 0;
            return inStart && inEnd;
          }).toList();

    final qqqMdd = _numVal(forensicWin['qqq_mdd']);
    final stratMdd = _numVal(
      winStratStats['mdd_pct'],
      _numVal(forensicWin['u1_mdd']),
    );
    final excessPct = _numVal(
      winStratStats['excess_ret_pct'],
      _numVal(forensicWin['excess_ret_u1']),
    );
    final harvestedUsd = _numVal(
      winStratStats['harvested_tp_usd'],
      _numVal(forensicWin['harvested_usd']),
    );
    final sharesAdded = _numVal(
      winStratStats['shares_added_tp'],
      _numVal(forensicWin['shares_added']),
    );

    return Container(
      key: const ValueKey('crisis-observatory-forensic-section'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    showFullLedger
                        ? w(
                            'All 12-Year Historical Operations (2015–2026)',
                            '全部 12 年历史实战记录（2015–2026）',
                          )
                        : _humanWindowTitle(forensicWin),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 16 : 17.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!showFullLedger) ...[
                    const SizedBox(height: 2),
                    Text(
                      '$winStart → $winEnd',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final win in windows) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          key: ValueKey(
                            'crisis-forensic-pill-${text(win['id'])}',
                          ),
                          borderRadius: BorderRadius.circular(999),
                          onTap: () {
                            final id = text(win['id']);
                            setState(() {
                              activeForensicWindowId = id;
                              selectedWindowId = id;
                              showFullLedger = false;
                              hoverIndex = -1;
                            });
                            _emitSelection();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4.5,
                            ),
                            decoration: BoxDecoration(
                              color: !showFullLedger && winId == text(win['id'])
                                  ? p.text.withValues(alpha: 0.09)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color:
                                    !showFullLedger && winId == text(win['id'])
                                    ? p.text.withValues(alpha: 0.28)
                                    : p.border,
                              ),
                            ),
                            child: Text(
                              _humanWindowChipLabel(win),
                              style: TextStyle(
                                color:
                                    !showFullLedger && winId == text(win['id'])
                                    ? p.text
                                    : p.muted,
                                fontSize: 11.5,
                                fontWeight:
                                    !showFullLedger && winId == text(win['id'])
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (!showFullLedger) ...[
            const SizedBox(height: 12),
            Text(
              (_isM7Strategy && text(forensicWin['m7_narrative_en']).isNotEmpty)
                  ? w(
                      text(forensicWin['m7_narrative_en']),
                      text(forensicWin['m7_narrative_zh']),
                    )
                  : w(
                      text(forensicWin['narrative_en']),
                      text(forensicWin['narrative_zh']),
                    ),
              style: TextStyle(
                color: p.muted,
                fontSize: compact ? 12.5 : 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: compact ? 20 : 36,
              runSpacing: 12,
              children: [
                _heroStatMetric(
                  label: w('Drawdown vs QQQ', '区间回撤对比'),
                  value:
                      '${stratMdd.toStringAsFixed(1)}% vs ${qqqMdd.toStringAsFixed(1)}%',
                  sub: w(
                    'Protection ${_fmtPct(excessPct)}',
                    '区间超额 ${_fmtPct(excessPct)}',
                  ),
                  color: excessPct >= 0 ? _emerald : p.text,
                ),
                _heroStatMetric(
                  label: w('Option Profit Harvested', '期权止盈落袋'),
                  value: _fmtUsd(harvestedUsd, signed: harvestedUsd > 0),
                  sub: w('Monetized via dual-track TP', '双轨止盈变现现金'),
                  color: harvestedUsd > 0 ? _emerald : p.text,
                ),
                _heroStatMetric(
                  label: w('QQQ Shares Added', '低位增持 QQQ'),
                  value: '+${sharesAdded.toStringAsFixed(1)} ${w('sh', '股')}',
                  sub: w(
                    'Peak VIX/3M ${_numVal(forensicWin['peak_vix_ratio']).toStringAsFixed(2)}',
                    '峰值恐慌比 ${_numVal(forensicWin['peak_vix_ratio']).toStringAsFixed(2)}',
                  ),
                  color: sharesAdded > 0 ? _emerald : p.text,
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Container(height: 1, color: p.border),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                showFullLedger
                    ? w(
                        'Chronological Operations (${fullLedger.length})',
                        '逐笔操作明细（共 ${fullLedger.length} 笔）',
                      )
                    : w('Operations in This Crisis', '当期具体操作时间线'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              InkWell(
                key: const ValueKey('crisis-ledger-scope-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => showFullLedger = !showFullLedger),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    showFullLedger
                        ? w('Show Selected Crisis Only', '仅看当前危机')
                        : w(
                            'View All 12Y (${fullLedger.length})',
                            '查看全部 12 年（${fullLedger.length} 笔）',
                          ),
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (filteredTranches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                w(
                  'No option hedges triggered during this window; 100% QQQ held unhedged.',
                  '该窗口内未触发期权保护，全程 100% 持有 QQQ 现货。',
                ),
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            )
          else
            for (final tr in filteredTranches)
              _buildCleanTimelineTrancheRow(tr, compact: compact),
          if (selectedCcMode != 'cc_off') ...[
            Builder(
              builder: (_) {
                final ccList = _currentCcLedgerForStrategy(doc);
                if (ccList.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 14),
                    Container(height: 1, color: p.border),
                    const SizedBox(height: 10),
                    InkWell(
                      key: const ValueKey('crisis-cc-ledger-toggle'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => showCcLedger = !showCcLedger),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              w(
                                'Normal-Time 25D 12Δ Covered Call Cash Ledger (${ccList.length} trades)',
                                '平时卖 25D 12Δ Call 攒现金明细（共 ${ccList.length} 笔）',
                              ),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Icon(
                              showCcLedger
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 16,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showCcLedger) ...[
                      const SizedBox(height: 8),
                      for (final cc in ccList.reversed)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: p.border, width: 1),
                            ),
                          ),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (text(cc['pricing_source']).isNotEmpty)
                                    _smallTimelineTag(
                                      _pricingSourceShortLabel(
                                        text(cc['pricing_source']),
                                      ),
                                      _pricingSourceColor(
                                        text(cc['pricing_source']),
                                      ),
                                    ),
                                  Text(
                                    w(
                                      '${text(cc['entry_date'])} -> ${text(cc['exit_date'])} · Sold K=\$${_numVal(cc['kc']).toStringAsFixed(0)} Call (VXN ${_numVal(cc['entry_vxn']).toStringAsFixed(1)}, Exit \$${_numVal(cc['exit_spot']).toStringAsFixed(0)})',
                                      '${text(cc['entry_date'])} → ${text(cc['exit_date'])} · 卖 \$${_numVal(cc['kc']).toStringAsFixed(0)} Call（VXN ${_numVal(cc['entry_vxn']).toStringAsFixed(1)} · 收盘 \$${_numVal(cc['exit_spot']).toStringAsFixed(0)}）',
                                    ),
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                w(
                                  'Prem ${_fmtUsd(_numVal(cc['prem_usd']), signed: true)} · Net ${_fmtUsd(_numVal(cc['net_pnl_usd']), signed: true)} · ${_ccExitReasonTag(text(cc['exit_reason']))}',
                                  '收租 ${_fmtUsd(_numVal(cc['prem_usd']), signed: true)} · 净盈亏 ${_fmtUsd(_numVal(cc['net_pnl_usd']), signed: true)} · ${_ccExitReasonTag(text(cc['exit_reason']))}',
                                ),
                                style: TextStyle(
                                  color: _numVal(cc['net_pnl_usd']) >= 0
                                      ? _emerald
                                      : _coral,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
          if (selectedSpMode != 'sp_off') ...[
            Builder(
              builder: (_) {
                final spList = _currentSpLedgerForStrategy(doc);
                if (spList.isEmpty) return const SizedBox.shrink();
                final stratSummary = _findStrategySummary(
                  doc,
                  selectedStrategyId,
                );
                final marginInt = _numVal(stratSummary['margin_interest_usd']);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 14),
                    Container(height: 1, color: p.border),
                    const SizedBox(height: 10),
                    InkWell(
                      key: const ValueKey('crisis-sp-ledger-toggle'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => showSpLedger = !showSpLedger),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                w(
                                  'Panic Put & Reverse Wheel Ledger (${spList.length} legs · 12Y Margin Interest ${_fmtUsdCents(marginInt)})',
                                  '恐慌卖 Put Wheel 实战明细（共 ${spList.length} 笔 · 12年融资总利息 ${_fmtUsdCents(marginInt)}）',
                                ),
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              showSpLedger
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 16,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showSpLedger) ...[
                      const SizedBox(height: 8),
                      for (final leg in spList.reversed)
                        Builder(
                          builder: (_) {
                            final legType = text(leg['leg_type']);
                            final isWc = legType == 'wheel_call';
                            final isOpenLive = leg['is_open_live'] == true;
                            final exitReason = text(leg['exit_reason']);
                            final isAssigned = exitReason.contains('assigned');
                            final strike = _numVal(leg['strike']);
                            final dte = _numVal(leg['dte']).round();
                            final sh = _numVal(leg['shares']);
                            final prem = _numVal(leg['prem_usd']);
                            final netPnl = _numVal(leg['net_pnl_usd']);
                            final exitDate = text(leg['exit_date']).isEmpty
                                ? w('LIVE', '持仓中')
                                : text(leg['exit_date']);
                            final tagText = isWc
                                ? w('Wheel Call', 'Wheel Call')
                                : w('Panic Put', '恐慌卖 Put');
                            final tagColor = isWc ? _emerald : _amber;
                            return Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: p.border, width: 1),
                                ),
                              ),
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _smallTimelineTag(tagText, tagColor),
                                      if (text(leg['pricing_source']).isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        _smallTimelineTag(
                                          _pricingSourceShortLabel(
                                            text(leg['pricing_source']),
                                          ),
                                          _pricingSourceColor(
                                            text(leg['pricing_source']),
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          w(
                                            '${text(leg['entry_date'])} -> $exitDate · ${dte}D K=\$${strike.toStringAsFixed(2)} (${sh.toStringAsFixed(0)} sh, Spot \$${_numVal(leg['entry_spot']).toStringAsFixed(1)} -> \$${_numVal(leg['exit_spot']).toStringAsFixed(1)})',
                                            '${text(leg['entry_date'])} → $exitDate · ${dte}D 行权 \$${strike.toStringAsFixed(2)}（${sh.toStringAsFixed(0)}股 · 正股 \$${_numVal(leg['entry_spot']).toStringAsFixed(1)} → \$${_numVal(leg['exit_spot']).toStringAsFixed(1)}）',
                                          ),
                                          style: TextStyle(
                                            color: p.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    w(
                                      'Prem ${_fmtUsd(prem, signed: true)} · Net ${_fmtUsd(netPnl, signed: true)} · ${_spExitReasonTag(legType, exitReason, isOpenLive)}',
                                      '收租 ${_fmtUsd(prem, signed: true)} · 净落袋 ${_fmtUsd(netPnl, signed: true)} · ${_spExitReasonTag(legType, exitReason, isOpenLive)}',
                                    ),
                                    style: TextStyle(
                                      color: isAssigned
                                          ? _amber
                                          : (netPnl >= 0 ? _emerald : _coral),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCleanTimelineTrancheRow(
    Map<String, dynamic> tr, {
    required bool compact,
  }) {
    final trancheId = _numVal(tr['tranche_id']).round();
    final expanded = expandedTrancheIds.contains(trancheId);
    final isM7Tranche =
        tr['crisis_prob'] is num ||
        tr['slot_num'] is num ||
        text(tr['book']).isNotEmpty ||
        text(tr['trigger_code']).isNotEmpty;
    final isBaseBook =
        text(tr['book']) == 'base' ||
        (isM7Tranche && _numVal(tr['slot_num'], -1).round() == 0);
    final isNaked = text(tr['tranche_type']) == 'naked_put' || isM7Tranche;
    final isOpenLive = tr['is_open_live'] == true;
    final exitReason = text(tr['exit_reason']);
    final isLiveArmed = exitReason == 'live_tp_armed_next_open';
    final isLiveRoll75Armed = exitReason == 'live_roll75_armed_next_open';
    final isLiveRoll50Armed = exitReason == 'live_roll50_armed_next_open';
    final isLiveRoll30Armed = exitReason == 'live_roll30_armed_next_open';
    final isVixSalvage = exitReason == 'salvage_vix_expensive';
    final isRoll75 = exitReason == 'roll_75d' || isLiveRoll75Armed;
    final isRoll30 = exitReason == 'roll_30d' || isLiveRoll30Armed;
    final isRoll50 =
        exitReason == 'roll_50d' ||
        isLiveRoll50Armed ||
        isRoll75 ||
        isRoll30 ||
        isVixSalvage;
    final isOpenCutoff = tr['exit_date'] == null && !isOpenLive;
    final isNearItmTp = exitReason.contains('near_itm_tp');
    final isVix45Tp = exitReason.contains('vix45');
    final isPut5xTp =
        exitReason.contains('put_5x') || exitReason == 'tp_5x_late';
    final isItmTp = exitReason.contains('itm_tp') && !isNearItmTp;
    final is4xTp = exitReason.contains('4x_tp');
    final isTp = exitReason.contains('tp') && !isOpenLive;
    final netPnl = _numVal(tr['net_pnl_usd']);
    final shAdded = _numVal(tr['shares_added']);
    final kp = _numVal(tr['kp']);
    final kc = tr['kc'] == null ? null : _numVal(tr['kc']);

    final slotNum = _numVal(tr['slot_num'], 1).round();
    final maxSlots = _numVal(
      tr['max_slots'],
      selectedStrategyId == 'M7_Ensemble' ? 2 : 3,
    ).round();
    final dte = _numVal(
      tr['target_dte'],
      selectedRollMode == '90d_hold' ? 90 : 125,
    ).round();
    final rawOtmVal = _numVal(
      tr['put_otm_pct'],
      selectedPutOtm == 'otm20' ? 20.0 : 15.0,
    );
    final otmPct = (rawOtmVal <= 1.0 ? rawOtmVal * 100.0 : rawOtmVal).round();
    final pricingSourceRaw = text(tr['quoteSource']).isNotEmpty
        ? text(tr['quoteSource'])
        : text(tr['pricing_source']);
    final hasPricingSource = pricingSourceRaw.isNotEmpty;
    final occSymbol = text(tr['occSymbol']);
    final prob = _numVal(tr['crisis_prob']).round();
    final trigCode = text(tr['trigger_code']);
    final roiMult = tr['roi_mult'] is num
        ? (tr['roi_mult'] as num).toDouble()
        : null;
    final entryCostUsd = _numVal(
      tr['entry_cost_usd'],
      _numVal(tr['gross_cost_usd']),
    );
    final contractsEst = _numVal(tr['contracts_est']);

    final tagLabel = isBaseBook
        ? w('Book B · 0.20%', 'B账本 · 0.20%')
        : (isM7Tranche
              ? w(
                  'S$slotNum/$maxSlots · 1.25%',
                  'M账本 S$slotNum/$maxSlots · 1.25%',
                )
              : (isNaked
                    ? w('First-Half Put', '首仓裸 Put')
                    : w('Zero-Cost Collar', '次仓领口')));
    final tagColor = isBaseBook ? _emerald : (isNaked ? _amber : p.muted);
    final String? subSignalLabel = isM7Tranche && trigCode.isNotEmpty
        ? (isBaseBook ? trigCode : '$trigCode · $prob%')
        : null;

    final entrySpot = _numVal(tr['entry_spot']).toStringAsFixed(1);
    final exitSpot = _numVal(tr['exit_spot']).toStringAsFixed(1);
    final rawExitDate = isOpenLive
        ? text(tr['mtm_date'])
        : text(tr['exit_date']);
    final exitShort = isOpenCutoff || rawExitDate.length < 10
        ? ''
        : rawExitDate.substring(5);
    final tpLabelEn = (isLiveRoll75Armed || isLiveRoll50Armed || isLiveRoll30Armed)
        ? '${isLiveRoll75Armed ? '75D' : (isLiveRoll30Armed ? '30D' : '50D')} Roll Armed (Next Close)'
        : (isLiveArmed
              ? 'Crash TP Armed (Next Close)'
              : (isVixSalvage
                    ? '75D VIX>20 Salvage'
                    : (isRoll75
                          ? '75D Hard Roll'
                          : (isRoll30
                                ? '30D Hard Roll'
                                : (isRoll50
                                      ? '50D Roll / Salvage'
                                      : (isOpenLive
                                            ? 'Open Live MTM'
                                            : (isVix45Tp
                                                  ? 'VIX>=45 Crash Harvest'
                                                  : (isNearItmTp
                                                        ? 'Near-ITM 1.05×K Harvest'
                                                        : (isPut5xTp
                                                              ? '5x Slow-Bear Harvest'
                                                              : (isItmTp
                                                                    ? 'Deep-ITM Panic Harvest'
                                                                    : (is4xTp
                                                                          ? '4x Deep Panic Harvest'
                                                                          : (isTp
                                                                                ? '1.10 Panic Harvest'
                                                                                : 'Expired'))))))))))));
    final tpLabelZh = (isLiveRoll75Armed || isLiveRoll50Armed || isLiveRoll30Armed)
        ? '剩≤${isLiveRoll75Armed ? '75D' : (isLiveRoll30Armed ? '30D' : '50D')} 待次日硬滚仓'
        : (isLiveArmed
              ? '暴跌止盈触发 · 待次日收盘平仓'
              : (isVixSalvage
                    ? '75D VIX>20/锁定期止买回收'
                    : (isRoll75
                          ? '75D 硬滚仓回收'
                          : (isRoll30
                                ? '30D 硬滚仓回收'
                                : (isRoll50
                                      ? '50D 残值滚仓回收'
                                      : (isOpenLive
                                            ? '实盘持仓浮盈'
                                            : (isVix45Tp
                                                  ? 'VIX≥45 极端恐慌止盈'
                                                  : (isNearItmTp
                                                        ? '近实值 1.05×K 恐慌止盈'
                                                        : (isPut5xTp
                                                              ? '5x 慢熊止盈'
                                                              : (isItmTp
                                                                    ? '实值恐慌止盈'
                                                                    : (is4xTp
                                                                          ? '4x 深度恐慌止盈'
                                                                          : (isTp ? '恐慌止盈' : '到期结算'))))))))))));

    final String actionSentence;
    if (isM7Tranche) {
      actionSentence = isOpenCutoff
          ? w(
              'QQQ \$$entrySpot -> Bought ${dte}D \$${kp.toStringAsFixed(1)} Put (${_fmtUsd(entryCostUsd)} · ${contractsEst.toStringAsFixed(1)} ctr) · Open',
              'QQQ \$$entrySpot 买 ${dte}D \$${kp.toStringAsFixed(1)} 裸 Put（预算 ${_fmtUsd(entryCostUsd)} · ${contractsEst.toStringAsFixed(1)} 张）· 持仓中',
            )
          : w(
              'QQQ \$$entrySpot -> ${dte}D \$${kp.toStringAsFixed(1)} Put (${_fmtUsd(entryCostUsd)}) · $tpLabelEn $exitShort @\$$exitSpot',
              'QQQ \$$entrySpot 买 ${dte}D \$${kp.toStringAsFixed(1)} 裸 Put（${_fmtUsd(entryCostUsd)}） → $exitShort @\$$exitSpot $tpLabelZh',
            );
    } else if (isNaked) {
      actionSentence = isOpenCutoff
          ? w(
              'QQQ \$$entrySpot -> Bought 90D \$${kp.toStringAsFixed(1)} Put (no upside cap) · Open',
              'QQQ \$$entrySpot 买入 90 天 \$${kp.toStringAsFixed(1)} 看跌保护（不卖封顶）· 持仓中',
            )
          : w(
              'QQQ \$$entrySpot -> Bought \$${kp.toStringAsFixed(1)} Put (no cap) · $tpLabelEn $exitShort @\$$exitSpot',
              'QQQ \$$entrySpot 买入 \$${kp.toStringAsFixed(1)} 看跌保护（不卖封顶） → $exitShort @\$$exitSpot $tpLabelZh',
            );
    } else {
      actionSentence = isOpenCutoff
          ? w(
              'QQQ \$$entrySpot -> Zero-cost Collar (\$${kp.toStringAsFixed(0)} Put / \$${(kc ?? 0).toStringAsFixed(0)} Call) · Open',
              'QQQ \$$entrySpot 开启零成本领口（保护 \$${kp.toStringAsFixed(0)} / 封顶 \$${(kc ?? 0).toStringAsFixed(0)}）· 持仓中',
            )
          : w(
              'QQQ \$$entrySpot -> Collar (\$${kp.toStringAsFixed(0)} Put / \$${(kc ?? 0).toStringAsFixed(0)} Call) · ${isTp || isOpenLive ? '$tpLabelEn $exitShort @\$$exitSpot' : 'Settled $exitShort @\$$exitSpot'}',
              'QQQ \$$entrySpot 零成本领口（保护 \$${kp.toStringAsFixed(0)} / 封顶 \$${(kc ?? 0).toStringAsFixed(0)}） → $exitShort @\$$exitSpot $tpLabelZh',
            );
    }

    final roiSuffix = roiMult != null && !isOpenCutoff
        ? ' · ${roiMult.toStringAsFixed(2)}x'
        : '';
    final pnlText = isOpenCutoff
        ? w('Open', '持仓中')
        : '${_fmtUsd(netPnl, signed: true)}$roiSuffix${shAdded.abs() >= 0.1 ? ' · ${shAdded >= 0 ? '+' : ''}${shAdded.toStringAsFixed(1)} ${w('sh', '股')}' : ''}';
    final pnlColor = isOpenCutoff
        ? _amber
        : (isRoll50 && netPnl <= 0
              ? _sky
              : (netPnl > 0 ? _emerald : p.muted));

    return InkWell(
      key: ValueKey('crisis-tranche-row-$trancheId'),
      onTap: isOpenCutoff
          ? null
          : () => setState(() {
              if (expanded) {
                expandedTrancheIds.remove(trancheId);
              } else {
                expandedTrancheIds.add(trancheId);
              }
            }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border, width: 1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        text(tr['entry_date']),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      _smallTimelineTag(tagLabel, tagColor),
                      if (subSignalLabel != null)
                        _smallTimelineTag(subSignalLabel, _sky),
                      if (hasPricingSource)
                        _smallTimelineTag(
                          _pricingSourceShortLabel(pricingSourceRaw),
                          _pricingSourceColor(pricingSourceRaw),
                        ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          pnlText,
                          style: TextStyle(
                            color: pnlColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!isOpenCutoff) ...[
                        const SizedBox(width: 4),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: p.muted,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                actionSentence,
                style: TextStyle(color: p.text, fontSize: 13, height: 1.4),
              ),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 82,
                    child: Text(
                      text(tr['entry_date']),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12.2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _smallTimelineTag(tagLabel, tagColor),
                  if (subSignalLabel != null) ...[
                    const SizedBox(width: 5),
                    _smallTimelineTag(subSignalLabel, _sky),
                  ],
                  if (hasPricingSource) ...[
                    const SizedBox(width: 5),
                    _smallTimelineTag(
                      _pricingSourceShortLabel(pricingSourceRaw),
                      _pricingSourceColor(pricingSourceRaw),
                    ),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      actionSentence,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    flex: 0,
                    child: Text(
                      pnlText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: pnlColor,
                        fontSize: 13.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!isOpenCutoff) ...[
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: p.muted,
                    ),
                  ],
                ],
              ),
            if (expanded && !isOpenCutoff) ...[
              const SizedBox(height: 9),
              Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  if (isM7Tranche && text(tr['signal_date']).isNotEmpty)
                    Text(
                      '${w('Signal EOD', '信号收盘日')}: ${text(tr['signal_date'])}',
                      style: TextStyle(color: p.muted, fontSize: 11.5),
                    ),
                  Text(
                    '${w('Trigger', '触发信号')}: ${w(text(tr['trigger_en']), text(tr['trigger_zh']))}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  if (occSymbol.isNotEmpty)
                    Text(
                      'OCC: $occSymbol',
                      style: TextStyle(
                        color: _emerald.withValues(alpha: 0.9),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (isM7Tranche && tr['entry_put_ask'] is num)
                    Text(
                      w(
                        'Put Buy \$${_numVal(tr['entry_put_ask']).toStringAsFixed(2)} -> Sell \$${_numVal(tr['exit_put_val']).toStringAsFixed(2)} (Rem ${_numVal(tr['rem_dte']).round()}D)',
                        '期权成交买价 \$${_numVal(tr['entry_put_ask']).toStringAsFixed(2)} → 卖价 \$${_numVal(tr['exit_put_val']).toStringAsFixed(2)}（剩 ${_numVal(tr['rem_dte']).round()}天）',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 11.5),
                    ),
                  Text(
                    'Delta ${_fmtUsd(_numVal(tr['delta_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    'Gamma ${_fmtUsd(_numVal(tr['gamma_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    'Vega ${_fmtUsd(_numVal(tr['vega_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    '${w('Time & Slippage', '时间损耗与滑点')} ${_fmtUsd(_numVal(tr['theta_slip_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _smallTimelineTag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// =============================================================================
// Minimalist Apple-Stocks / Linear Style Equity Curve Painter
// =============================================================================
class _CrisisObservatoryChartPainter extends CustomPainter {
  _CrisisObservatoryChartPainter({
    required this.rows,
    required this.events,
    required this.navKey,
    this.probKey = 'm7_prob',
    required this.rebasedMode,
    required this.useLogScale,
    required this.showSubTrack,
    required this.hoverIndex,
    this.pinnedIndex = -1,
    required this.borderColor,
    required this.mutedColor,
    required this.textColor,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> events;
  final String navKey;
  final String probKey;
  final bool rebasedMode;
  final bool useLogScale;
  final bool showSubTrack;
  final int hoverIndex;
  final int pinnedIndex;
  final Color borderColor;
  final Color mutedColor;
  final Color textColor;

  static const Color _emerald = Color(0xFF5EC49E);
  static const Color _amber = Color(0xFFE5B45B);
  static const Color _coral = Color(0xFFE47F8B);
  static const Color _sky = Color(0xFF7DB8F0);

  double _val(dynamic v, [double fb = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    return fb;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.length < 2) return;

    const padL = 52.0;
    const padR = 12.0;
    const padT = 10.0;
    const padB = 24.0;
    final plotW = math.max(1.0, size.width - padL - padR);
    final totalH = math.max(1.0, size.height - padT - padB);

    final subH = showSubTrack ? 68.0 : 0.0;
    final gap = showSubTrack ? 14.0 : 0.0;
    final mainH = math.max(80.0, totalH - subH - gap);

    final mainTop = padT;
    final mainBot = mainTop + mainH;
    final subTop = mainBot + gap;
    final subBot = subTop + subH;

    final n = rows.length;
    double xAt(int i) => padL + (i / (n - 1)) * plotW;

    final baseStrat = math.max(1e-6, _val(rows.first[navKey], 200000));
    final baseBh = math.max(1e-6, _val(rows.first['nav_bh'], 200000));

    final stratVals = <double>[];
    final bhVals = <double>[];
    for (final r in rows) {
      final sv = _val(r[navKey], baseStrat);
      final bv = _val(r['nav_bh'], baseBh);
      if (rebasedMode) {
        stratVals.add((sv / baseStrat) * 100.0);
        bhVals.add((bv / baseBh) * 100.0);
      } else {
        stratVals.add(useLogScale ? math.log(math.max(1.0, sv)) : sv);
        bhVals.add(useLogScale ? math.log(math.max(1.0, bv)) : bv);
      }
    }

    var yMin = math.min(stratVals.reduce(math.min), bhVals.reduce(math.min));
    var yMax = math.max(stratVals.reduce(math.max), bhVals.reduce(math.max));
    if ((yMax - yMin).abs() < 1e-6) {
      yMax += 1.0;
      yMin -= 1.0;
    }
    final padY = (yMax - yMin) * 0.08;
    yMin -= padY;
    yMax += padY;

    double yMain(double v) =>
        mainBot - ((v - yMin) / (yMax - yMin)).clamp(0.0, 1.0) * mainH;

    // 1. Ultra-subtle translucent crisis tint when Prob >= 55% or >= 5 lights ON
    final crisisTint = Paint()..color = _coral.withValues(alpha: 0.045);
    final stepW = math.max(1.0, plotW / (n - 1));
    for (var i = 0; i < n; i++) {
      final pr = _val(rows[i][probKey] ?? rows[i]['m7_prob']);
      if (pr >= 55 || _val(rows[i]['crisis_lights']) >= 5) {
        canvas.drawRect(
          Rect.fromLTWH(xAt(i) - stepW * 0.5, mainTop, stepW, mainH),
          crisisTint,
        );
      }
    }

    // 2. Clean 3 horizontal gridlines
    final gridPaint = Paint()
      ..color = borderColor.withValues(alpha: 0.7)
      ..strokeWidth = 0.8;
    for (var g = 0; g <= 3; g++) {
      final frac = g / 3.0;
      final gy = mainBot - frac * mainH;
      canvas.drawLine(Offset(padL, gy), Offset(padL + plotW, gy), gridPaint);
      final rawVal = yMin + frac * (yMax - yMin);
      final String lbl;
      if (rebasedMode) {
        lbl = rawVal.toStringAsFixed(0);
      } else {
        final usd = useLogScale ? math.exp(rawVal) : rawVal;
        lbl = usd >= 1000000
            ? '\$${(usd / 1000000).toStringAsFixed(1)}M'
            : '\$${(usd / 1000).toStringAsFixed(0)}K';
      }
      _drawLabel(canvas, lbl, Offset(2, gy - 6), mutedColor, 10.0);
    }

    // 3. Dashed Buy & Hold QQQ curve + Solid Emerald Strategy curve with soft area fill
    final bhPath = Path();
    final stratPath = Path();
    final fillPath = Path();
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      final yb = yMain(bhVals[i]);
      final ys = yMain(stratVals[i]);
      if (i == 0) {
        bhPath.moveTo(x, yb);
        stratPath.moveTo(x, ys);
        fillPath.moveTo(x, mainBot);
        fillPath.lineTo(x, ys);
      } else {
        bhPath.lineTo(x, yb);
        stratPath.lineTo(x, ys);
        fillPath.lineTo(x, ys);
      }
    }
    fillPath
      ..lineTo(xAt(n - 1), mainBot)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, mainTop),
          Offset(0, mainBot),
          [
            _emerald.withValues(alpha: 0.13),
            _emerald.withValues(alpha: 0.0),
          ],
        ),
    );

    _drawDashedPath(
      canvas,
      bhPath,
      Paint()
        ..color = mutedColor.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.45,
    );

    canvas.drawPath(
      stratPath,
      Paint()
        ..color = _emerald
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );

    // 4. Distinct vector markers:
    //    - ▼ Amber downward triangle = Buy Put / Collar
    //    - ◆ Emerald diamond         = Crisis Put TP Harvest
    //    - ▲ Sky Blue UPWARD equilateral triangle = Sell Call Open
    //    - ↻ Lilac circular-arrow Roll logo       = Call Roll Up / Credit Roll
    //    - ✕ Coral stop-badge                     = Call Δ0.35 Stop Buyback
    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(rows[i]['date']): i,
    };
    final baseR = rebasedMode ? 5.2 : 4.0;
    // Draw Sell Call ▲ slightly above the curve first, then Put/TP, then Roll/Stop on top so critical actions never get buried.
    for (final ev in events) {
      final et = text(ev['event_type']);
      if (et != 'cc_open') continue;
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = (yMain(stratVals[idx]) - (rebasedMode ? 7.5 : 5.5)).clamp(
        mainTop + 5.0,
        mainBot - 5.0,
      );
      _paintCrisisMarkerGlyph(
        canvas,
        Offset(x, y),
        rebasedMode ? 4.8 : 3.6,
        _CrisisMarkerKind.ccOpen,
      );
    }
    for (final ev in events) {
      final et = text(ev['event_type']);
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = yMain(stratVals[idx]);
      if (et == 'slot1_naked_put' ||
          et == 'slot2_naked_put' ||
          et == 'slot3_naked_put' ||
          et == 'slot2_collar' ||
          et == 'slot1_collar' ||
          et == 'slot3_collar') {
        final slotNum = _val(ev['slot_num']).round();
        final dyOff = slotNum >= 2
            ? (rebasedMode ? 5.0 + (slotNum - 1) * 2.2 : 3.2 + (slotNum - 1) * 1.4)
            : (rebasedMode ? 4.5 : 3.0);
        final drawPos = Offset(
          x,
          (y + dyOff).clamp(mainTop + 5.0, mainBot - 5.0),
        );
        _paintCrisisMarkerGlyph(
          canvas,
          drawPos,
          baseR,
          _CrisisMarkerKind.putOpen,
          rimColor: slotNum >= 3 ? _coral : (slotNum == 2 ? _sky : null),
        );
      } else if (et == 'roll_75d' ||
          et == 'roll_50d' ||
          et == 'roll_30d' ||
          et == 'live_roll75_armed' ||
          et == 'live_roll50_armed' ||
          et == 'live_roll30_armed') {
        _paintCrisisMarkerGlyph(
          canvas,
          Offset(
            x,
            (y + (rebasedMode ? 5.2 : 3.8)).clamp(mainTop + 6.0, mainBot - 6.0),
          ),
          rebasedMode ? 5.2 : 4.0,
          _CrisisMarkerKind.putRoll50,
        );
      } else if (et == 'vix110_tp' ||
          et == 'vix110_near_itm_tp' ||
          et == 'vix45_panic_tp' ||
          et == 'vix110_itm_tp' ||
          et == 'vix110_4x_tp' ||
          et == 'put5x_dte45_tp' ||
          et == 'base_tp_5x_late' ||
          et == 'live_tp_armed') {
        _paintCrisisMarkerGlyph(
          canvas,
          Offset(x, y),
          rebasedMode ? 5.4 : 4.2,
          _CrisisMarkerKind.putTp,
          rimColor: et == 'live_tp_armed'
              ? Colors.white
              : ((et == 'put5x_dte45_tp' || et == 'base_tp_5x_late')
                    ? _amber
                    : null),
        );
      }
    }
    for (final ev in events) {
      final et = text(ev['event_type']);
      if (et != 'cc_roll_up' &&
          et != 'cc_credit_roll' &&
          et != 'cc_delta_stop') {
        continue;
      }
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = (yMain(stratVals[idx]) - (rebasedMode ? 9.0 : 6.5)).clamp(
        mainTop + 7.0,
        mainBot - 7.0,
      );
      _paintCrisisMarkerGlyph(
        canvas,
        Offset(x, y),
        rebasedMode ? 6.2 : 5.0,
        et == 'cc_delta_stop'
            ? _CrisisMarkerKind.ccStop
            : _CrisisMarkerKind.ccRoll,
      );
    }

    for (final ev in events) {
      final et = text(ev['event_type']);
      if (et != 'sp_open' && et != 'sp_assign' && et != 'wc_called') {
        continue;
      }
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final yOffset = et == 'wc_called'
          ? -(rebasedMode ? 6.5 : 5.0)
          : (rebasedMode ? 7.0 : 5.2);
      final y = (yMain(stratVals[idx]) + yOffset).clamp(
        mainTop + 6.0,
        mainBot - 6.0,
      );
      _paintCrisisMarkerGlyph(
        canvas,
        Offset(x, y),
        et == 'sp_open' ? (rebasedMode ? 4.3 : 3.3) : (rebasedMode ? 5.2 : 4.1),
        et == 'sp_assign'
            ? _CrisisMarkerKind.spAssign
            : (et == 'wc_called'
                  ? _CrisisMarkerKind.wcCalled
                  : _CrisisMarkerKind.spOpen),
      );
    }

    // 5. Optional compact sub-track (M7 Crisis Prob 0..100% + VIX/3M 1.10 threshold)
    if (showSubTrack) {
      canvas.drawLine(
        Offset(padL, subTop),
        Offset(padL + plotW, subTop),
        gridPaint,
      );
      canvas.drawLine(
        Offset(padL, subBot),
        Offset(padL + plotW, subBot),
        gridPaint,
      );
      _drawLabel(canvas, '1.10', Offset(6, subTop + 6), _amber, 9.5);
      _drawLabel(canvas, '35%', Offset(6, subBot - 22), _sky, 9.5);

      double yProb(double pr) =>
          subBot - (pr / 100.0).clamp(0.0, 1.0) * subH;
      final hasAnyM7 = rows.any(
        (r) => r[probKey] is num || r['m7_prob'] is num,
      );
      if (hasAnyM7) {
        final y35 = yProb(35.0);
        _drawDashedPath(
          canvas,
          Path()
            ..moveTo(padL, y35)
            ..lineTo(padL + plotW, y35),
          Paint()
            ..color = _sky.withValues(alpha: 0.42)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.85,
        );
        final probPath = Path();
        final probFill = Path();
        for (var i = 0; i < n; i++) {
          final x = xAt(i);
          final pr = _val(rows[i][probKey] ?? rows[i]['m7_prob']);
          final y = yProb(pr);
          if (i == 0) {
            probPath.moveTo(x, y);
            probFill.moveTo(x, subBot);
            probFill.lineTo(x, y);
          } else {
            probPath.lineTo(x, y);
            probFill.lineTo(x, y);
          }
        }
        probFill
          ..lineTo(xAt(n - 1), subBot)
          ..close();
        canvas.drawPath(
          probFill,
          Paint()..color = _sky.withValues(alpha: 0.11),
        );
        canvas.drawPath(
          probPath,
          Paint()
            ..color = _sky.withValues(alpha: 0.80)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.15,
        );
      }

      const vMin = 0.75;
      const vMax = 1.35;
      double yVix(double vr) =>
          subBot - ((vr - vMin) / (vMax - vMin)).clamp(0.0, 1.0) * subH;

      final y110 = yVix(1.10);
      _drawDashedPath(
        canvas,
        Path()
          ..moveTo(padL, y110)
          ..lineTo(padL + plotW, y110),
        Paint()
          ..color = _amber.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );

      final vixPath = Path();
      for (var i = 0; i < n; i++) {
        final x = xAt(i);
        final vr = _val(rows[i]['vix_ratio'], 0.90);
        final y = yVix(vr);
        if (i == 0) {
          vixPath.moveTo(x, y);
        } else {
          vixPath.lineTo(x, y);
        }
      }
      canvas.drawPath(
        vixPath,
        Paint()
          ..color = _amber.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25,
      );
    }

    // 6. Clean X-axis date ticks (zero overlap)
    final axisBaseY = showSubTrack ? subBot : mainBot;
    final tickIndices = [
      0,
      ((n - 1) * 0.25).round(),
      ((n - 1) * 0.50).round(),
      ((n - 1) * 0.75).round(),
      n - 1,
    ];
    double lastRight = -999;
    for (final ti in tickIndices) {
      final dt = text(rows[ti]['date']);
      final lbl = rebasedMode ? dt.substring(2) : dt.substring(0, 7);
      final x = xAt(ti);
      final estW = lbl.length * 5.8;
      final drawX = (x - estW * 0.5)
          .clamp(padL, math.max(padL, padL + plotW - estW))
          .toDouble();
      if (drawX - lastRight < 14) continue;
      _drawLabel(canvas, lbl, Offset(drawX, axisBaseY + 6), mutedColor, 10.0);
      lastRight = drawX + estW;
    }

    // 7. Pinned PIT replay crosshair + luminous ring + date/price canvas badge
    if (pinnedIndex >= 0 && pinnedIndex < n) {
      final px = xAt(pinnedIndex);
      final pinLinePath = Path()
        ..moveTo(px, mainTop)
        ..lineTo(px, axisBaseY);
      _drawDashedPath(
        canvas,
        pinLinePath,
        Paint()
          ..color = _sky.withValues(alpha: 0.85)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
        dash: 5.0,
        gap: 3.0,
      );
      final psY = yMain(stratVals[pinnedIndex]);
      final pbY = yMain(bhVals[pinnedIndex]);
      canvas.drawCircle(
        Offset(px, pbY),
        3.5,
        Paint()..color = _sky.withValues(alpha: 0.7),
      );
      canvas.drawCircle(
        Offset(px, psY),
        8.5,
        Paint()..color = _sky.withValues(alpha: 0.22),
      );
      canvas.drawCircle(
        Offset(px, psY),
        5.0,
        Paint()..color = const Color(0xFF080B0F),
      );
      canvas.drawCircle(
        Offset(px, psY),
        3.6,
        Paint()..color = _sky,
      );

      final pRow = rows[pinnedIndex];
      final pDate = (pRow['date'] ?? '').toString();
      final pQqq = _val(pRow['qqq_close']);
      final tagText = 'PIT $pDate · \$${pQqq.toStringAsFixed(2)}';
      final tp = TextPainter(
        text: TextSpan(
          text: tagText,
          style: const TextStyle(
            color: Color(0xFFEDF1F5),
            fontSize: 10.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pillW = tp.width + 12.0;
      final pillH = tp.height + 6.0;
      final pillX = (px - pillW * 0.5)
          .clamp(padL + 2.0, math.max(padL + 2.0, padL + plotW - pillW - 2.0))
          .toDouble();
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(pillX, mainTop + 2.0, pillW, pillH),
        const Radius.circular(5),
      );
      canvas.drawRRect(
        pillRect,
        Paint()..color = const Color(0xE80D1622),
      );
      canvas.drawRRect(
        pillRect,
        Paint()
          ..color = _sky.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      tp.paint(canvas, Offset(pillX + 6.0, mainTop + 5.0));
    }

    // 8. Calm hover crosshair + active dots
    if (hoverIndex >= 0 && hoverIndex < n) {
      final hx = xAt(hoverIndex);
      canvas.drawLine(
        Offset(hx, mainTop),
        Offset(hx, axisBaseY),
        Paint()
          ..color = textColor.withValues(alpha: 0.28)
          ..strokeWidth = 1.0,
      );
      final hsY = yMain(stratVals[hoverIndex]);
      final hbY = yMain(bhVals[hoverIndex]);
      canvas.drawCircle(Offset(hx, hbY), 3.2, Paint()..color = mutedColor);
      canvas.drawCircle(Offset(hx, hsY), 4.2, Paint()..color = _emerald);
    }
  }

  void _drawDashedPath(
    Canvas canvas,
    Path source,
    Paint paint, {
    double dash = 4.5,
    double gap = 3.5,
  }) {
    for (final metric in source.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dash + gap;
      }
    }
  }

  void _drawLabel(
    Canvas canvas,
    String value,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CrisisObservatoryChartPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.events != events ||
        oldDelegate.navKey != navKey ||
        oldDelegate.probKey != probKey ||
        oldDelegate.rebasedMode != rebasedMode ||
        oldDelegate.useLogScale != useLogScale ||
        oldDelegate.showSubTrack != showSubTrack ||
        oldDelegate.hoverIndex != hoverIndex ||
        oldDelegate.pinnedIndex != pinnedIndex ||
        oldDelegate.borderColor != borderColor;
  }
}

enum _CrisisMarkerKind {
  putOpen,
  putTp,
  putRoll50,
  ccOpen,
  ccRoll,
  ccStop,
  spOpen,
  spAssign,
  wcCalled,
}

void _paintCrisisMarkerGlyph(
  Canvas canvas,
  Offset c,
  double r,
  _CrisisMarkerKind kind, {
  Color? rimColor,
}) {
  const obsidian = Color(0xFF0A0E14);
  const emerald = Color(0xFF5EC49E);
  const amber = Color(0xFFE5B45B);
  const coral = Color(0xFFE47F8B);
  const sky = Color(0xFF7DB8F0);
  const lilac = Color(0xFFB8A1EA);

  switch (kind) {
    case _CrisisMarkerKind.ccOpen:
      // Equilateral triangle pointing UP (正三角形向上 = 卖 Call)
      final h = r * 1.12;
      final halfW = r * 0.98;
      final tri = Path()
        ..moveTo(c.dx, c.dy - h)
        ..lineTo(c.dx - halfW, c.dy + h * 0.68)
        ..lineTo(c.dx + halfW, c.dy + h * 0.68)
        ..close();
      canvas.drawPath(tri, Paint()..color = sky);
      canvas.drawPath(
        tri,
        Paint()
          ..color = obsidian.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
      break;

    case _CrisisMarkerKind.putOpen:
      // Equilateral triangle pointing DOWN (倒三角形向下 = 买 Put 防下跌)
      final h = r * 1.08;
      final halfW = r * 0.94;
      final tri = Path()
        ..moveTo(c.dx, c.dy + h)
        ..lineTo(c.dx - halfW, c.dy - h * 0.66)
        ..lineTo(c.dx + halfW, c.dy - h * 0.66)
        ..close();
      canvas.drawPath(tri, Paint()..color = amber);
      canvas.drawPath(
        tri,
        Paint()
          ..color = rimColor ?? obsidian.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = rimColor != null ? 1.15 : 0.9,
      );
      break;

    case _CrisisMarkerKind.putRoll50:
      // Sky-Mint Circular Roll Badge (⟳ 120D -> 50D 剩余期限残值滚仓/回收)
      canvas.drawCircle(c, r, Paint()..color = obsidian.withValues(alpha: 0.94));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = sky.withValues(alpha: 0.42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.95,
      );
      final arcR50 = r * 0.60;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: arcR50),
        -math.pi * 0.25,
        math.pi * 1.45,
        false,
        Paint()
          ..color = sky
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, r * 0.24)
          ..strokeCap = StrokeCap.round,
      );
      final tipA50 = -math.pi * 0.25;
      final tip50 = Offset(
        c.dx + arcR50 * math.cos(tipA50),
        c.dy + arcR50 * math.sin(tipA50),
      );
      final ah50 = math.max(2.0, r * 0.40);
      final arr50 = Path()
        ..moveTo(tip50.dx + ah50 * 0.35, tip50.dy + ah50 * 0.15)
        ..lineTo(tip50.dx - ah50 * 0.70, tip50.dy - ah50 * 0.65)
        ..lineTo(tip50.dx + ah50 * 0.40, tip50.dy - ah50 * 0.80)
        ..close();
      canvas.drawPath(arr50, Paint()..color = emerald);
      break;

    case _CrisisMarkerKind.putTp:
      // Diamond (◆ 危机 Put 止盈换股)
      final dia = Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close();
      canvas.drawPath(dia, Paint()..color = emerald);
      canvas.drawPath(
        dia,
        Paint()
          ..color = rimColor ?? obsidian.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = rimColor != null ? 1.3 : 0.9,
      );
      break;

    case _CrisisMarkerKind.ccRoll:
      // Distinct Roll Logo: dark halo badge + bright Lilac 270° circular arc + crisp arrowhead (↻)
      canvas.drawCircle(c, r, Paint()..color = obsidian.withValues(alpha: 0.94));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = lilac.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
      final arcR = r * 0.62;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: arcR),
        -math.pi * 0.2,
        math.pi * 1.48,
        false,
        Paint()
          ..color = lilac
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.25, r * 0.24)
          ..strokeCap = StrokeCap.round,
      );
      // Arrowhead at the top-right end of the clockwise roll arc
      final tipAngle = -math.pi * 0.2;
      final tip = Offset(
        c.dx + arcR * math.cos(tipAngle),
        c.dy + arcR * math.sin(tipAngle),
      );
      final ah = math.max(2.1, r * 0.42);
      final arrow = Path()
        ..moveTo(tip.dx + ah * 0.35, tip.dy + ah * 0.15)
        ..lineTo(tip.dx - ah * 0.72, tip.dy - ah * 0.65)
        ..lineTo(tip.dx + ah * 0.42, tip.dy - ah * 0.82)
        ..close();
      canvas.drawPath(arrow, Paint()..color = lilac);
      break;

    case _CrisisMarkerKind.ccStop:
      // Distinct Stop Badge: dark halo badge + Coral ring + crisp ✕
      canvas.drawCircle(c, r * 0.92, Paint()..color = obsidian.withValues(alpha: 0.94));
      canvas.drawCircle(
        c,
        r * 0.92,
        Paint()
          ..color = coral
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.15,
      );
      final cr = r * 0.44;
      final xPaint = Paint()
        ..color = coral
        ..strokeWidth = math.max(1.2, r * 0.24)
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(c.dx - cr, c.dy - cr), Offset(c.dx + cr, c.dy + cr), xPaint);
      canvas.drawLine(Offset(c.dx + cr, c.dy - cr), Offset(c.dx - cr, c.dy + cr), xPaint);
      break;

    case _CrisisMarkerKind.spOpen:
      // Hollow Amber-Mint Ring (◎ 卖恐慌短久期 Put)
      canvas.drawCircle(c, r * 0.92, Paint()..color = obsidian.withValues(alpha: 0.92));
      canvas.drawCircle(
        c,
        r * 0.92,
        Paint()
          ..color = amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.25, r * 0.30),
      );
      canvas.drawCircle(c, r * 0.30, Paint()..color = emerald);
      break;

    case _CrisisMarkerKind.spAssign:
      // Solid Gold Rounded Square (■ 接货进反向 Wheel)
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: r * 1.65, height: r * 1.65),
        Radius.circular(r * 0.32),
      );
      canvas.drawRRect(rect, Paint()..color = amber);
      canvas.drawRRect(
        rect,
        Paint()
          ..color = obsidian.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.95,
      );
      break;

    case _CrisisMarkerKind.wcCalled:
      // Gold-Rim Emerald Diamond Badge (◈ 反向 Wheel Call 被行权清债去杠杆)
      final dia = Path()
        ..moveTo(c.dx, c.dy - r * 1.05)
        ..lineTo(c.dx + r * 1.05, c.dy)
        ..lineTo(c.dx, c.dy + r * 1.05)
        ..lineTo(c.dx - r * 1.05, c.dy)
        ..close();
      canvas.drawPath(dia, Paint()..color = emerald);
      canvas.drawPath(
        dia,
        Paint()
          ..color = amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.3, r * 0.28),
      );
      break;
  }
}

class _CrisisMarkerGlyphPainter extends CustomPainter {
  const _CrisisMarkerGlyphPainter({required this.kind});

  final _CrisisMarkerKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) * 0.42;
    _paintCrisisMarkerGlyph(canvas, c, r, kind);
  }

  @override
  bool shouldRepaint(covariant _CrisisMarkerGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind;
}
