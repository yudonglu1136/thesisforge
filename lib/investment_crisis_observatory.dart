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
  // Canonical Dark-Obsidian institutional palette
  static const Color _bgObsidian = Color(0xFF080B0F);
  static const Color _bgCard = Color(0xFF0D131A);
  static const Color _bgInset = Color(0xFF111922);
  static const Color _borderLine = Color(0xFF25313B);
  static const Color _fgPrimary = Color(0xFFEDF1F5);
  static const Color _fgMuted = Color(0xFF9CABB9);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _amber = Color(0xFFF2BC60);
  static const Color _lilac = Color(0xFFB8A1EA);
  static const Color _coral = Color(0xFFEC8C98);
  static const Color _slate = Color(0xFF52616E);

  final TextEditingController _navCtrl = TextEditingController(text: '100000');
  double accountNav = 100000.0;

  Map<String, dynamic>? data;
  bool loading = true;
  bool switchingWindow = false;
  String? error;

  String selectedWindow = '11y_opra';
  bool useLogScale = true;
  bool showLedger = false;
  bool showPlaybookManual = false;
  String ledgerFilter = 'all';
  int hoverIndex = -1;
  int loadSerial = 0;

  // Interactive time-range brush / zoom state for the equity chart
  int? rangeStartIdx;
  int? rangeEndIdx;
  String activeQuickRange = 'all';
  bool rebaseZoomedSlice = true;
  String _brushDragMode = '';
  double _brushDragStartDx = 0.0;
  int _brushDragOrigStart = 0;
  int _brushDragOrigEnd = 0;
  MouseCursor _brushCursor = SystemMouseCursors.click;

  // Point-in-Time (PIT) historical replay state (click any point on curve)
  String? pinnedPitDate;
  Map<String, dynamic>? pitSnapshot;
  bool loadingPit = false;
  String? pitError;
  int pitSerial = 0;
  final Map<String, Map<String, dynamic>> _pitCache = {};
  final Map<String, Map<String, dynamic>> _windowCache = {};
  String _hoverEventsCacheKey = '';
  Map<String, List<Map<String, dynamic>>> _hoverEventsByDate = const {};

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  String _normalizeWindow(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == '5y_live' || v == '5yr_live' || v == '5y' || v == 'live') {
      return '5y_live';
    }
    return '11y_opra';
  }

  @override
  void initState() {
    super.initState();
    final initWin = text(
      widget.initialSelection['window'] ??
          widget.initialSelection['co_window'] ??
          '',
    );
    selectedWindow = _normalizeWindow(initWin);
    unawaited(_loadDashboard());
  }

  @override
  void didUpdateWidget(covariant CrisisObservatoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf) {
      _windowCache.clear();
      pinnedPitDate = null;
      pitSnapshot = null;
      unawaited(_loadDashboard());
    }
  }

  @override
  void dispose() {
    _navCtrl.dispose();
    super.dispose();
  }

  void _emitSelection() {
    widget.onSelection?.call({'window': selectedWindow});
  }

  Future<void> _loadDashboard({bool isWindowSwitch = false}) async {
    final serial = ++loadSerial;
    final targetWin = selectedWindow;
    final cacheKey = '${widget.asOf}|$targetWin';
    final cached = _windowCache[cacheKey];
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        data = cached;
        loading = false;
        switchingWindow = false;
        error = null;
        hoverIndex = -1;
        rangeStartIdx = null;
        rangeEndIdx = null;
        activeQuickRange = 'all';
      });
      return;
    }

    setState(() {
      if (isWindowSwitch && data != null) {
        switchingWindow = true;
      } else {
        loading = true;
      }
      error = null;
    });

    try {
      final qp = <String, String>{'window': targetWin};
      if (widget.asOf.isNotEmpty) qp['asOf'] = widget.asOf;
      final uri = Uri(
        path: '/api/investment/crisis-observatory',
        queryParameters: qp,
      );
      final resp = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      final map = asMap(resp);
      _windowCache[cacheKey] = map;
      setState(() {
        data = map;
        loading = false;
        switchingWindow = false;
        hoverIndex = -1;
        rangeStartIdx = null;
        rangeEndIdx = null;
        activeQuickRange = 'all';
      });
    } catch (e) {
      if (!mounted || serial != loadSerial) return;
      setState(() {
        error = e.toString();
        loading = false;
        switchingWindow = false;
      });
    }
  }

  void _selectWindow(String winId) {
    final norm = _normalizeWindow(winId);
    if (norm == selectedWindow) return;
    final prevPinned = pinnedPitDate;
    setState(() {
      selectedWindow = norm;
      hoverIndex = -1;
      rangeStartIdx = null;
      rangeEndIdx = null;
      activeQuickRange = 'all';
    });
    _emitSelection();
    unawaited(_loadDashboard(isWindowSwitch: true));
    if (prevPinned != null && prevPinned.isNotEmpty) {
      unawaited(_loadPitDate(prevPinned, windowOverride: norm));
    }
  }

  void _ensureDateInRange(String date) {
    final backtest = asMap(data?['backtest']);
    final win = asMap(backtest['active_window']);
    final series = asList(win['daily_series']);
    if (series.length < 2) return;
    final maxIdx = series.length - 1;
    final sIdx = (rangeStartIdx ?? 0).clamp(0, maxIdx - 1).toInt();
    final eIdx = (rangeEndIdx ?? maxIdx).clamp(sIdx + 1, maxIdx).toInt();
    if (sIdx == 0 && eIdx == maxIdx) return;

    int targetIdx = -1;
    for (var i = 0; i < series.length; i++) {
      if (text(asMap(series[i])['date']) == date) {
        targetIdx = i;
        break;
      }
    }
    if (targetIdx < 0) return;
    if (targetIdx >= sIdx && targetIdx <= eIdx) return;

    final span = math.max(20, eIdx - sIdx);
    final halfSpan = (span / 2).floor();
    final nextStart = (targetIdx - halfSpan).clamp(0, math.max(0, maxIdx - span)).toInt();
    final nextEnd = (nextStart + span).clamp(math.min(maxIdx, nextStart + 1), maxIdx).toInt();
    rangeStartIdx = nextStart;
    rangeEndIdx = nextEnd;
    activeQuickRange = 'custom';
    hoverIndex = -1;
  }

  void _applyQuickRange(
    List<dynamic> series,
    String id, {
    String? startDate,
    String? endDate,
    int? trailingDays,
  }) {
    if (series.length < 2) return;
    final maxIdx = series.length - 1;
    const minSpan = 15;
    int s = 0;
    int e = maxIdx;
    if (id == 'all') {
      s = 0;
      e = maxIdx;
    } else if (trailingDays != null) {
      s = math.max(0, maxIdx - trailingDays);
      e = maxIdx;
    } else if (startDate != null && endDate != null) {
      s = 0;
      for (var i = 0; i <= maxIdx; i++) {
        if (text(asMap(series[i])['date']).compareTo(startDate) >= 0) {
          s = i;
          break;
        }
      }
      e = maxIdx;
      for (var i = maxIdx; i >= 0; i--) {
        if (text(asMap(series[i])['date']).compareTo(endDate) <= 0) {
          e = i;
          break;
        }
      }
      if (e - s < minSpan) {
        e = math.min(maxIdx, s + minSpan);
        s = math.max(0, e - minSpan);
      }
    }
    setState(() {
      rangeStartIdx = s;
      rangeEndIdx = e;
      activeQuickRange = (s == 0 && e == maxIdx) ? 'all' : id;
      hoverIndex = -1;
    });
  }

  Future<void> _loadPitDate(String date, {String? windowOverride}) async {
    if (date.isEmpty) return;
    final win = windowOverride ?? selectedWindow;
    final serial = ++pitSerial;
    final cacheKey = '$win|$date';
    final cached = _pitCache[cacheKey];
    if (cached != null) {
      setState(() {
        pinnedPitDate = date;
        pitSnapshot = cached;
        loadingPit = false;
        pitError = null;
        if (windowOverride == null) _ensureDateInRange(date);
      });
      return;
    }
    setState(() {
      pinnedPitDate = date;
      loadingPit = true;
      pitError = null;
      if (windowOverride == null) _ensureDateInRange(date);
    });
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory/pit',
        queryParameters: {'date': date, 'window': win},
      );
      final resp = await widget.api.getJson(uri.toString());
      if (!mounted || serial != pitSerial) return;
      final map = asMap(resp);
      _pitCache[cacheKey] = map;
      setState(() {
        pitSnapshot = map;
        loadingPit = false;
        pitError = null;
      });
    } catch (e) {
      if (!mounted || serial != pitSerial) return;
      setState(() {
        loadingPit = false;
        pitError = e.toString();
      });
    }
  }

  void _clearPitReplay() {
    setState(() {
      pinnedPitDate = null;
      pitSnapshot = null;
      loadingPit = false;
      pitError = null;
    });
  }

  Color _toneColor(String tone) {
    return switch (tone) {
      'mint' => _mint,
      'sky' => _sky,
      'amber' => _amber,
      'coral' => _coral,
      'lilac' => _lilac,
      _ => _fgMuted,
    };
  }

  Color _severityColor(String sev) {
    return switch (sev) {
      'action' => _mint,
      'crisis' => _coral,
      'elevated' => _amber,
      'watch' => _sky,
      _ => _mint,
    };
  }

  String _fmtUsd(num? v, {int dec = 0, bool signed = false}) {
    if (v == null || !v.isFinite) return '--';
    final absV = v.abs();
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final fixed = absV.toStringAsFixed(dec);
    final parts = fixed.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      final rev = intPart.length - i;
      buf.write(intPart[i]);
      if (rev > 1 && rev % 3 == 1) buf.write(',');
    }
    final decPart = parts.length > 1 ? '.${parts[1]}' : '';
    return '$sign\$$buf$decPart';
  }

  String _fmtPct(num? v, {int dec = 2, bool signed = true}) {
    if (v == null || !v.isFinite) return '--';
    final s = signed && v >= 0 ? '+' : '';
    return '$s${v.toStringAsFixed(dec)}%';
  }

  String _fmtNum(num? v, {int dec = 2, bool signed = false}) {
    if (v == null || !v.isFinite) return '--';
    final s = signed && v >= 0 ? '+' : '';
    return '$s${v.toStringAsFixed(dec)}';
  }

  num? _n(dynamic v) {
    if (v is num) return v.isFinite ? v : null;
    if (v is String) return num.tryParse(v);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return Container(
        key: const ValueKey('crisis-v2-loading'),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _bgObsidian,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _borderLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 2, color: _mint),
            const SizedBox(height: 14),
            Text(
              w(
                'Loading ThesisForge v3.0 Double-Champion Crisis Cockpit...',
                '正在加载 ThesisForge v3.0 双冠终极版危机观测舱...',
              ),
              style: const TextStyle(color: _fgMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return Container(
        key: const ValueKey('crisis-v2-error'),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _bgObsidian,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _coral.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Unable to load Crisis Observatory v3.0 data.',
                '暂时无法加载危机观测 v3.0 数据。',
              ),
              style: const TextStyle(
                color: _fgPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => unawaited(_loadDashboard()),
              child: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final root = data ?? const <String, dynamic>{};
    final activeCockpit = pinnedPitDate != null && pitSnapshot != null
        ? asMap(pitSnapshot!['live_cockpit'])
        : asMap(root['live_cockpit']);
    final freshness = asMap(root['data_freshness']);
    final backtest = asMap(root['backtest']);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 760;
        final isWide = constraints.maxWidth >= 1040;
        return Container(
          key: const ValueKey('crisis-v2-root'),
          padding: EdgeInsets.all(isCompact ? 12 : 18),
          decoration: BoxDecoration(
            color: _bgObsidian,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _borderLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Section 1: T+1 Live Action Command Center (Hero Card)
              _buildSection1CommandCenter(
                activeCockpit,
                freshness,
                isCompact: isCompact,
                isWide: isWide,
              ),
              const SizedBox(height: 16),

              // Section 2: Dual-CTA Slow-Bear Radar & +8% Hysteresis Latch Panel
              _buildSection2DualCtaRadar(
                activeCockpit,
                isCompact: isCompact,
                isWide: isWide,
              ),
              const SizedBox(height: 16),

              // Section 3: Three-Pillar Real-Time Crisis Sensors (P1 / P2 / P3)
              _buildSection3ThreePillars(
                activeCockpit,
                isCompact: isCompact,
                isWide: isWide,
              ),
              const SizedBox(height: 16),

              // Section 4: Tiered Put TP & Skew Microstructure Strip
              _buildSection4TpMicrostructure(
                activeCockpit,
                isCompact: isCompact,
                isWide: isWide,
              ),
              const SizedBox(height: 16),

              // Section 5: Real MIT OPRA Historical Verification (v3.0 Plan D vs 100% QQQ)
              _buildSection5OpraBacktest(
                backtest,
                isCompact: isCompact,
                isWide: isWide,
              ),
              const SizedBox(height: 16),

              // Section 6: v3.0 Double-Champion Full Strategy Operating Manual (Expandable)
              _buildSection6PlaybookManual(isCompact),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 1: T+1 LIVE ACTION COMMAND CENTER (HERO CARD)
  // ---------------------------------------------------------------------------
  Widget _buildSection1CommandCenter(
    Map<String, dynamic> cockpit,
    Map<String, dynamic> freshness, {
    required bool isCompact,
    required bool isWide,
  }) {
    final market = asMap(cockpit['market']);
    final cmd = asMap(cockpit['command_center']);
    final pillars = asMap(cockpit['three_pillars']);
    final strikes = asMap(cmd['target_strikes']);
    final r1Strike = asMap(strikes['route1_125d_15otm']);
    final r2Strike = asMap(
      strikes['route2_m4_90d_15otm'] ?? strikes['route2_m4_90d_10otm'],
    );
    final subEngines = asList(cmd['sub_engines']);

    final asOfDate = text(cockpit['date']);
    final isPit = cockpit['is_pit_replay'] == true;
    final sev = text(cmd['severity']);
    final sevColor = _severityColor(sev);
    final stressIdx = _n(pillars['live_stress_index'])?.round() ?? 0;
    final rawProb = _n(pillars['raw_crisis_prob'])?.round() ?? 0;
    final entProb = _n(pillars['entry_crisis_prob'])?.round() ?? 0;
    final qqqClose = _n(market['qqq_close']) ?? 0;
    final dbmfClose = _n(market['dbmf_close']) ?? 0;
    final kmlmClose = _n(market['kmlm_close']) ?? 0;
    final boxRate = _n(market['box_rate_pct']) ?? 4.23;
    final effrPct = _n(market['effr_pct']) ?? 3.88;

    return Container(
      key: const ValueKey('crisis-v2-hero'),
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sevColor.withValues(alpha: 0.45), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Eyebrow & Data Freshness Header
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _mint.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _mint.withValues(alpha: 0.55)),
                    ),
                    child: Text(
                      w(
                        'v3.0 DOUBLE-CHAMPION (PLAN D)',
                        'v3.0 双冠终极版（PLAN D）',
                      ),
                      style: const TextStyle(
                        color: _mint,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  Text(
                    w(
                      '100% QQQ + 20% Dual-CTA Box (Natural Drift) + Taleb B020_M125 (-15% OTM) + CONT_2M',
                      '100% QQQ + 20% 双CTA Box（自然漂移无砍仓）+ 正统 Taleb B020_M125（统一 -15% OTM）+ CONT_2M',
                    ),
                    style: const TextStyle(
                      color: _fgMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _pillBadge(
                    isPit
                        ? w('PIT REPLAY · $asOfDate', '历史回放 · $asOfDate')
                        : w('LIVE EOD · $asOfDate', '实时收盘 · $asOfDate'),
                    isPit ? _lilac : _sky,
                  ),
                  if (!isPit)
                    Text(
                      w(
                        text(freshness['source_summary_en']),
                        text(freshness['source_summary_zh']),
                      ),
                      style: const TextStyle(color: _fgMuted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),

          // PIT Historical Replay Controls Bar (only visible when user clicks a curve date)
          if (pinnedPitDate != null) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('crisis-v2-pit-banner'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _lilac.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _lilac.withValues(alpha: 0.5)),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    loadingPit
                        ? w(
                            'Loading PIT snapshot for $pinnedPitDate...',
                            '正在加载 $pinnedPitDate 历史实况...',
                          )
                        : w(
                            'Point-in-Time Replay: $asOfDate · QQQ ${_fmtUsd(qqqClose, dec: 2)} (${_fmtPct(_n(market['qqq_ath_dd_pct']))} vs ATH)',
                            '历史时点回放：$asOfDate · QQQ ${_fmtUsd(qqqClose, dec: 2)}（距前高 ${_fmtPct(_n(market['qqq_ath_dd_pct']))}）',
                          ),
                    style: const TextStyle(
                      color: _fgPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      if (text(pitSnapshot?['prev_date']).isNotEmpty)
                        _miniBtn(
                          w('Prev Day', '前一日'),
                          () => unawaited(
                            _loadPitDate(text(pitSnapshot?['prev_date'])),
                          ),
                        ),
                      if (text(pitSnapshot?['next_date']).isNotEmpty)
                        _miniBtn(
                          w('Next Day', '后一日'),
                          () => unawaited(
                            _loadPitDate(text(pitSnapshot?['next_date'])),
                          ),
                        ),
                      _miniBtn(
                        w('Back to Live', '返回实时'),
                        _clearPitReplay,
                        accent: _mint,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // Main T+1 Action Directive Box
          Container(
            key: const ValueKey('crisis-v2-action-directive'),
            padding: EdgeInsets.all(isCompact ? 12 : 16),
            decoration: BoxDecoration(
              color: sevColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sevColor.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _pillBadge(
                      w(
                        'LIVE STRESS $stressIdx / 100 · ${text(pillars['live_stress_label_en'])}',
                        '实时危机压力 $stressIdx / 100 · ${text(pillars['live_stress_label_zh'])}',
                      ),
                      stressIdx >= 75
                          ? _coral
                          : (stressIdx >= 50 ? _amber : _mint),
                    ),
                    _pillBadge(
                      w('RAW ALERT $rawProb%', '原始预警 $rawProb%'),
                      rawProb >= 35 ? _amber : _fgMuted,
                    ),
                    _pillBadge(
                      w('VOL-GATE ENTRY $entProb%', '低波建仓 $entProb%'),
                      entProb >= 35 ? _mint : _sky,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  w(text(cmd['headline_en']), text(cmd['headline_zh'])),
                  style: TextStyle(
                    color: _fgPrimary,
                    fontSize: isCompact ? 15 : 17,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  w(text(cmd['summary_en']), text(cmd['summary_zh'])),
                  style: const TextStyle(
                    color: _fgMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 5 Live Sub-Engine Status Pills
          LayoutBuilder(
            builder: (_, c) {
              final cols = c.maxWidth >= 980 ? 5 : (c.maxWidth >= 600 ? 3 : 1);
              final cardW = (c.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(
                key: const ValueKey('crisis-v2-subengines-grid'),
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final rawEng in subEngines)
                    Builder(
                      builder: (_) {
                        final eng = asMap(rawEng);
                        final col = _toneColor(text(eng['tone']));
                        return SizedBox(
                          width: cardW,
                          child: Container(
                            padding: const EdgeInsets.all(11),
                            decoration: BoxDecoration(
                              color: _bgInset,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: col.withValues(alpha: 0.42),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  w(
                                    text(eng['label_en']),
                                    text(eng['label_zh']),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _fgMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  w(
                                    text(eng['value_en']),
                                    text(eng['value_zh']),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: col,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  w(
                                    text(eng['detail_en']),
                                    text(eng['detail_zh']),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _fgMuted,
                                    fontSize: 10.5,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),

          const SizedBox(height: 14),

          // Live Target Put Strikes & Interactive Account NAV Sizer
          Container(
            key: const ValueKey('crisis-v2-sizer'),
            padding: EdgeInsets.all(isCompact ? 11 : 14),
            decoration: BoxDecoration(
              color: _bgInset,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _borderLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      w(
                        'Live Target Strikes & 1.20x Account Allocation Sizer (QQQ ${_fmtUsd(qqqClose, dec: 2)})',
                        '实时目标 Put 行权价与 1.20x 仓位计算器（QQQ 现价 ${_fmtUsd(qqqClose, dec: 2)}）',
                      ),
                      style: const TextStyle(
                        color: _fgPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(
                      width: 175,
                      height: 34,
                      child: TextField(
                        key: const ValueKey('crisis-v2-nav-input'),
                        controller: _navCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                          color: _fgPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          prefixText: 'NAV \$ ',
                          prefixStyle: const TextStyle(
                            color: _mint,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                          filled: true,
                          fillColor: _bgObsidian,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(color: _borderLine),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: const BorderSide(color: _borderLine),
                          ),
                        ),
                        onChanged: (val) {
                          final parsed = double.tryParse(
                            val.replaceAll(',', '').trim(),
                          );
                          if (parsed != null && parsed >= 1000) {
                            setState(() => accountNav = parsed);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _sizerChip(
                      w('100% QQQ Core', '100% QQQ 底仓'),
                      _fmtUsd(accountNav),
                      qqqClose > 0
                          ? '${(accountNav / qqqClose).toStringAsFixed(1)} sh'
                          : '--',
                      _sky,
                    ),
                    _sizerChip(
                      w('10% DBMF', '10% DBMF'),
                      _fmtUsd(accountNav * 0.10),
                      dbmfClose > 0
                          ? '${(accountNav * 0.10 / dbmfClose).toStringAsFixed(1)} sh'
                          : '--',
                      _mint,
                    ),
                    _sizerChip(
                      w('10% KMLM', '10% KMLM'),
                      _fmtUsd(accountNav * 0.10),
                      kmlmClose > 0
                          ? '${(accountNav * 0.10 / kmlmClose).toStringAsFixed(1)} sh'
                          : '--',
                      _mint,
                    ),
                    _sizerChip(
                      w('20% Box Financing', '20% SPX Box 借款'),
                      _fmtUsd(accountNav * 0.20),
                      w(
                        '${boxRate.toFixedSafe(2)}%/yr (${_fmtUsd(accountNav * 0.20 * boxRate / 100)}/yr · EFFR ${effrPct.toFixedSafe(2)}%)',
                        '年化 ${boxRate.toFixedSafe(2)}%（年息 ${_fmtUsd(accountNav * 0.20 * boxRate / 100)} · EFFR ${effrPct.toFixedSafe(2)}%）',
                      ),
                      _amber,
                    ),
                    Builder(
                      builder: (_) {
                        final sbOv = r1Strike['slow_bear_override'] == true;
                        final tgtD = (_n(r1Strike['target_dte']) ?? 125).toInt();
                        final rlD = (_n(r1Strike['roll_dte']) ?? 75).toInt();
                        return _sizerChip(
                          w(
                            'B020 Base (0.20% · ${tgtD}D -15%${sbOv ? ' · Slow-Bear' : ''})',
                            'B020 常态盾 0.20% · ${tgtD}D -15%${sbOv ? ' · 慢熊禁125D' : ''}',
                          ),
                          'K = \$${_n(r1Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.002)})',
                          w(
                            'Exact ${_fmtUsd(_n(r1Strike['exact_strike']), dec: 2)} · VIX<=20 · Hard ${rlD}D ${sbOv ? 'Salvage' : 'Roll'}',
                            '精确 ${_fmtUsd(_n(r1Strike['exact_strike']), dec: 2)} · VIX<=20 · ${rlD}D ${sbOv ? '强行收回' : '强滚'}',
                          ),
                          sbOv ? _lilac : _sky,
                        );
                      },
                    ),
                    Builder(
                      builder: (_) {
                        final sbOv = r1Strike['slow_bear_override'] == true;
                        final tgtD = (_n(r1Strike['target_dte']) ?? 125).toInt();
                        final rlD = (_n(r1Strike['roll_dte']) ?? 75).toInt();
                        return _sizerChip(
                          w(
                            'M7G Ladder (1-3 x 1.25% · ${tgtD}D -15%)',
                            'M7G 阶梯盾 1-3x1.25% · ${tgtD}D -15%',
                          ),
                          'K = \$${_n(r1Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.0125)}/s · Max ${_fmtUsd(accountNav * 0.0375)})',
                          w(
                            'Score >=35/45/65 -> 1/2/3 Slots · Hard ${rlD}D ${sbOv ? 'Salvage' : 'Roll'}',
                            '得分 >=35/45/65 -> 开 1/2/3 槽 · ${rlD}D ${sbOv ? '强行收回' : '强滚'}',
                          ),
                          sbOv ? _lilac : _amber,
                        );
                      },
                    ),
                    _sizerChip(
                      w(
                        'M4 +8% Latch (1.25%/s · 90D -15%)',
                        'M4 +8% 磁滞锁存 1.25%/槽 · 90D -15%',
                      ),
                      'K = \$${_n(r2Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.0125)}/s)',
                      w(
                        'Uniform -15% OTM (${_fmtUsd(_n(r2Strike['exact_strike']), dec: 2)}) · Hard 30D Roll',
                        '统一 -15% OTM（${_fmtUsd(_n(r2Strike['exact_strike']), dec: 2)}）· 30D 强滚',
                      ),
                      _lilac,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 2: DUAL-CTA SLOW-BEAR RADAR & +8% HYSTERESIS LATCH PANEL
  // ---------------------------------------------------------------------------
  Widget _buildSection2DualCtaRadar(
    Map<String, dynamic> cockpit, {
    required bool isCompact,
    required bool isWide,
  }) {
    final radar = asMap(cockpit['dual_cta_radar']);
    final latch = asMap(radar['slow_bear_latch']);
    final timer = asMap(radar['cont_2m_timer']);
    final lev = asMap(radar['leverage_guard']);
    final market = asMap(cockpit['market']);

    final latchArmed = latch['armed'] == true;
    final corr60 = _n(latch['corr60'])?.toDouble() ?? 0.0;
    final ctaHi252 = _n(latch['dual_cta_gain_since_hi252_pct']) ?? 0.0;
    final dbHi252 = _n(latch['dbmf_gain_since_hi252_pct']) ?? 0.0;
    final kmHi252 = _n(latch['kmlm_gain_since_hi252_pct']) ?? 0.0;
    final above200 = _n(latch['above_200dma_streak'])?.round() ?? 0;
    final resetTarget = _n(latch['reset_target_days'])?.round() ?? 10;
    final gates = asList(latch['gates']);

    final c2mActive = timer['active'] == true;
    final c2mConfirmed = timer['confirmed'] == true;
    final c2mDays = _n(timer['continuous_cal_days'])?.round() ?? 0;
    final c2mTarget = _n(timer['target_cal_days'])?.round() ?? 60;
    final ddAth = _n(timer['qqq_ath_dd_pct']) ?? 0.0;
    final dbAth = _n(timer['dbmf_ret_since_ath_pct']) ?? 0.0;
    final kmAth = _n(timer['kmlm_ret_since_ath_pct']) ?? 0.0;

    final leftCard = Container(
      key: const ValueKey('crisis-v2-latch-card'),
      padding: EdgeInsets.all(isCompact ? 13 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (latchArmed ? _lilac : _borderLine).withValues(alpha: 0.75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'Slow-Bear +8% Hysteresis Latch (M4 Gate)',
                  '慢熊 +8% 滞回锁存开关（M4 前置门控）',
                ),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              _pillBadge(
                latchArmed
                    ? w('ARMED (ON)', '已激活锁存 (ON)')
                    : w('OFF (DISARMED)', '未锁存 (OFF)'),
                latchArmed ? _lilac : _slate,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Live DualCTA / DBMF / KMLM performance since QQQ 1Y high & ATH
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metricBox(
                w('DualCTA vs QQQ 1Y High', '双CTA 距 QQQ 1Y高点'),
                _fmtPct(ctaHi252),
                ctaHi252 >= 8.0 ? _mint : _fgPrimary,
                sub: w('Gate >= +8.0%', '激活线 >= +8.0%'),
              ),
              _metricBox(
                w('DBMF (1Y Hi / ATH)', 'DBMF（1Y高 / ATH）'),
                '${_fmtPct(dbHi252, dec: 1)} / ${_fmtPct(dbAth, dec: 1)}',
                dbAth > 0 ? _mint : _coral,
                sub: '\$${_fmtNum(_n(market['dbmf_close']))}',
              ),
              _metricBox(
                w('KMLM (1Y Hi / ATH)', 'KMLM（1Y高 / ATH）'),
                '${_fmtPct(kmHi252, dec: 1)} / ${_fmtPct(kmAth, dec: 1)}',
                kmAth > 0 ? _mint : _coral,
                sub: '\$${_fmtNum(_n(market['kmlm_close']))}',
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Live Corr60(DualCTA, QQQ) Visual Gauge (-1.0 .. 0.0 .. +1.0)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bgInset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _borderLine),
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
                        'Corr60(DualCTA, QQQ) Gauge',
                        '60日相关性 Corr60(双CTA, QQQ)',
                      ),
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_fmtNum(corr60, dec: 3, signed: true)} (${corr60 < 0 ? w('NEG-CORR PASS', '负相关达标') : w('POS-CORR BLOCKED', '正相关拦截')})',
                      style: TextStyle(
                        color: corr60 < 0 ? _mint : _amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 14,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _CorrGaugePainter(corr: corr60),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '-1.0',
                      style: TextStyle(color: _mint, fontSize: 10),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        w('0.0 (<0 PASS)', '0.0 (<0 通过)'),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _fgMuted, fontSize: 10),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '+1.0',
                      style: TextStyle(color: _coral, fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 4 ARM Gates checklist
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final rawG in gates)
                Builder(
                  builder: (_) {
                    final g = asMap(rawG);
                    final ok = g['passed'] == true;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: (ok ? _mint : _slate).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: (ok ? _mint : _borderLine).withValues(
                            alpha: 0.55,
                          ),
                        ),
                      ),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(
                            ok
                                ? Icons.check_circle_outline
                                : Icons.radio_button_unchecked,
                            size: 13,
                            color: ok ? _mint : _fgMuted,
                          ),
                          Text(
                            '${w(text(g['label_en']), text(g['label_zh']))}: ${text(g['value'])}',
                            style: TextStyle(
                              color: ok ? _fgPrimary : _fgMuted,
                              fontSize: 11,
                              fontWeight: ok
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Hysteresis Retention + Reset Counter Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _bgObsidian,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _borderLine),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    latchArmed
                        ? w(
                            'Armed ${text(latch['arm_date'])} · Peak CTA ${_fmtPct(_n(latch['peak_cta_gain_pct']))} (stays ON during bounces)',
                            '锁存于 ${text(latch['arm_date'])} · 峰值 CTA ${_fmtPct(_n(latch['peak_cta_gain_pct']))}（反抽回吐仍保持开启）',
                          )
                        : w(
                            'Hysteresis Reset Rule: QQQ > 200DMA for 10 consecutive trading days',
                            '滞回复位规则：连续 10 个交易日站回 QQQ > 200DMA 才解除锁存',
                          ),
                    style: const TextStyle(color: _fgMuted, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                _pillBadge(
                  w(
                    'Reset $above200/$resetTarget D',
                    '复位计数 $above200/$resetTarget 天',
                  ),
                  above200 >= resetTarget ? _mint : _sky,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final rightCard = Container(
      key: const ValueKey('crisis-v2-timer-card'),
      padding: EdgeInsets.all(isCompact ? 13 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (c2mConfirmed ? _coral : (c2mActive ? _amber : _borderLine))
              .withValues(alpha: 0.75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  '2-Month Continuous Bear Timer (CONT_2M) & Natural-Drift Box Guard',
                  '双CTA 2个月持续熊市计时器（CONT_2M）与自然漂移 Box 护栏',
                ),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              _pillBadge(
                c2mConfirmed
                    ? w('CONFIRMED ($c2mDays/60d)', '已确认 ($c2mDays/60天)')
                    : c2mActive
                    ? w('RUNNING ($c2mDays/60d)', '计时中 ($c2mDays/60天)')
                    : w('IDLE (> -12%)', '待命 (> -12%)'),
                c2mConfirmed ? _coral : (c2mActive ? _amber : _slate),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Progress bar toward 60 continuous calendar days <= -12.0%
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'QQQ ATH DD: ${_fmtPct(ddAth)} (Trigger <= -12.0%)',
                  'QQQ 距前高回撤：${_fmtPct(ddAth)}（起算门槛 <= -12.0%）',
                ),
                style: TextStyle(
                  color: ddAth <= -12.0 ? _amber : _fgMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '$c2mDays / $c2mTarget d',
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: (c2mDays / c2mTarget).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: _bgObsidian,
              color: c2mConfirmed ? _coral : _amber,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            c2mActive
                ? w(
                    'Continuous since ${text(timer['timer_start_date'])} · Projected 60d confirmation: ${text(timer['projected_confirm_date'])}',
                    '起算日 ${text(timer['timer_start_date'])} · 若持续 <= -12%，预计满 60 天确认日：${text(timer['projected_confirm_date'])}',
                  )
                : w(
                    'Timer resets immediately whenever QQQ recovers above -12.0% from ATH.',
                    '只要 QQQ 回撤缩窄至高于 -12.0%，计时器自动清零，杜绝假突破换仓。',
                  ),
            style: const TextStyle(color: _fgMuted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),

          // Per-ETF > 0% profit gate pills
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _pillBadge(
                w(
                  'DBMF vs ATH ${_fmtPct(dbAth)} · ${dbAth > 0 ? 'ELIGIBLE >0%' : 'BLOCKED <=0%'}',
                  'DBMF 距前高 ${_fmtPct(dbAth)} · ${dbAth > 0 ? '允许切股 >0%' : '亏损禁切 <=0%'}',
                ),
                dbAth > 0 ? _mint : _coral,
              ),
              _pillBadge(
                w(
                  'KMLM vs ATH ${_fmtPct(kmAth)} · ${kmAth > 0 ? 'ELIGIBLE >0%' : 'BLOCKED <=0%'}',
                  'KMLM 距前高 ${_fmtPct(kmAth)} · ${kmAth > 0 ? '允许切股 >0%' : '亏损禁切 <=0%'}',
                ),
                kmAth > 0 ? _mint : _coral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '• ${w(text(timer['rotation_rule_en']), text(timer['rotation_rule_zh']))}\n'
            '• ${w(text(timer['restore_rule_en']), text(timer['restore_rule_zh']))}',
            style: const TextStyle(
              color: _fgMuted,
              fontSize: 11,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),

          // Natural-Drift Box Leverage Guard Strip (NO daily 1.20x forced crash deleveraging cap)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bgInset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _mint.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    _inlineStat(
                      w('Live / Peak Drift', '实时 / 11Y峰值杠杆'),
                      '${_fmtNum(_n(lev['live_gross_leverage']) ?? _n(lev['target_gross']) ?? 1.2, dec: 3)}x (Pk ${_fmtNum(_n(lev['observed_peak_drift_11y']) ?? 1.257, dec: 2)}x)',
                      _mint,
                    ),
                    _inlineStat(
                      w('IBKR PM Cushion', 'IBKR PM 强平垫'),
                      _fmtPct(
                        _n(lev['ibkr_pm_crash_cushion_pct']) ?? -80.39,
                      ),
                      _mint,
                    ),
                    _inlineStat(
                      w('Reg-T Cushion', 'Reg-T 强平垫'),
                      _fmtPct(_n(lev['reg_t_crash_cushion_pct']) ?? -77.78),
                      _sky,
                    ),
                    _inlineStat(
                      w('SPX Box Cost', 'Box 融资成本'),
                      '${_fmtNum(_n(lev['box_rate_pct']), dec: 2)}% (${_fmtNum(_n(lev['box_annual_drag_pct_nav']) ?? 0.85, dec: 2)}%/yr)',
                      _amber,
                    ),
                  ],
                ),
                if (text(lev['policy_en']).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    w(text(lev['policy_en']), text(lev['policy_zh'])),
                    style: const TextStyle(
                      color: _fgMuted,
                      fontSize: 10.6,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (isWide) {
      return Row(
        key: const ValueKey('crisis-v2-dualcta-radar'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: leftCard),
          const SizedBox(width: 14),
          Expanded(child: rightCard),
        ],
      );
    }
    return Column(
      key: const ValueKey('crisis-v2-dualcta-radar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [leftCard, const SizedBox(height: 14), rightCard],
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 3: THREE-PILLAR REAL-TIME CRISIS SENSORS (P1 / P2 / P3)
  // ---------------------------------------------------------------------------
  Widget _buildSection3ThreePillars(
    Map<String, dynamic> cockpit, {
    required bool isCompact,
    required bool isWide,
  }) {
    final tp = asMap(cockpit['three_pillars']);
    final breakdown = asMap(tp['live_stress_breakdown']);
    final pillars = asList(tp['pillars']);
    final stressIdx = _n(tp['live_stress_index'])?.round() ?? 0;
    final rawProb = _n(tp['raw_crisis_prob'])?.round() ?? 0;
    final rawSlots = _n(tp['raw_target_slots'])?.round() ??
        (rawProb >= 65 ? 3 : (rawProb >= 45 ? 2 : (rawProb >= 35 ? 1 : 0)));
    final entProb = _n(tp['entry_crisis_prob'])?.round() ?? 0;
    final actSlots = _n(tp['actionable_m7g_slots'])?.round() ?? 0;
    final actBud = _n(tp['actionable_m7g_budget_pct']) ?? (actSlots * 1.25);
    final m7Info = asMap(tp['m7g_ladder_and_bleed']);
    final grossTurn = _n(m7Info['gross_turnover_pct_nav_yr']) ?? 6.11;
    final salvPct = _n(m7Info['roll_salvage_pct']) ?? 67.1;
    final netBleed = _n(m7Info['true_net_bleed_pct_nav_yr']) ?? 2.04;
    final vgStatus = text(tp['vol_gate_status']);
    final vgColor = vgStatus == 'ENTRY_ALLOWED'
        ? _mint
        : (vgStatus == 'POST_TP_LOCKOUT' ? _coral : _amber);

    return Container(
      key: const ValueKey('crisis-v2-pillars'),
      padding: EdgeInsets.all(isCompact ? 13 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderLine),
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
              Text(
                w(
                  'Three-Pillar Real-Time Crisis Sensors · M7G Graded Ladder (1-3 x 1.25%)',
                  '三支柱实时危机雷达 · M7G 阶梯加码（1-3 槽 x 1.25% NAV）',
                ),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _pillBadge(
                    w(
                      'Track A · Stress $stressIdx/100 · Raw $rawProb ($rawSlots/3 Slots)',
                      '轨道 A · 压力 $stressIdx/100 · 原始 $rawProb（$rawSlots/3 槽）',
                    ),
                    stressIdx >= 75
                        ? _coral
                        : (stressIdx >= 50 ? _amber : _mint),
                  ),
                  _pillBadge(
                    w(
                      'Track B · Actionable $actSlots/3 (${actBud.toStringAsFixed(2)}% · Score $entProb)',
                      '轨道 B · 可开 $actSlots/3 槽（${actBud.toStringAsFixed(2)}% · 得分 $entProb）',
                    ),
                    vgColor,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Vol-Gate explanation banner (eliminates any confusion about 0% entry during high vol!)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: vgColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: vgColor.withValues(alpha: 0.42)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w(
                    text(tp['vol_gate_reason_en']),
                    text(tp['vol_gate_reason_zh']),
                  ),
                  style: TextStyle(
                    color: _fgPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _subBarLabel(
                      w('Regime/Vol', '波动与状态'),
                      _n(breakdown['regime_vol']) ?? 0,
                      _n(breakdown['regime_vol_cap']) ?? 30,
                    ),
                    _subBarLabel(
                      w('Trend/DD', '趋势与回撤'),
                      _n(breakdown['trend_dd']) ?? 0,
                      _n(breakdown['trend_dd_cap']) ?? 25,
                    ),
                    _subBarLabel(
                      w('Credit/Macro', '信用与宏观'),
                      _n(breakdown['credit_macro']) ?? 0,
                      _n(breakdown['credit_macro_cap']) ?? 25,
                    ),
                    _subBarLabel(
                      w('Breadth/Tail', '宽度与尾部'),
                      _n(breakdown['breadth_tail']) ?? 0,
                      _n(breakdown['breadth_tail_cap']) ?? 20,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 8,
                  runSpacing: 5,
                  children: [
                    _pillBadge(
                      w(
                        'M7G Ladder: >=35 -> 1s (1.25%) | >=45 -> 2s (2.50%) | >=65 -> 3s (3.75%) · Uniform -15% OTM',
                        'M7G 阶梯：>=35 开1槽(1.25%) | >=45 开2槽(2.50%) | >=65 开3槽(3.75%) · 统一 -15% OTM',
                      ),
                      _sky,
                    ),
                    _pillBadge(
                      w(
                        'Hard 75D/30D Roll: Gross ${grossTurn.toStringAsFixed(2)}%/yr -> Salvage ${salvPct.toStringAsFixed(1)}% -> True Net Bleed ${netBleed.toStringAsFixed(2)}% NAV/yr',
                        '75D/30D 强滚成本：名义流水 ${grossTurn.toStringAsFixed(2)}%/yr -> 回收 ${salvPct.toStringAsFixed(1)}% 残值 -> 真实净损耗仅 ${netBleed.toStringAsFixed(2)}% NAV/yr',
                      ),
                      _mint,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 3 Pillar Cards
          LayoutBuilder(
            builder: (_, c) {
              final cols = c.maxWidth >= 980 ? 3 : 1;
              final cardW = (c.maxWidth - (cols - 1) * 12) / cols;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final rawP in pillars)
                    SizedBox(
                      width: cardW,
                      child: _buildPillarCard(asMap(rawP)),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPillarCard(Map<String, dynamic> pillar) {
    final rawLit = pillar['raw_alert_lit'] == true;
    final entLit = pillar['entry_lit'] == true;
    final accent = entLit ? _mint : (rawLit ? _amber : _borderLine);
    final sensors = asList(pillar['sensors']);

    return Container(
      key: ValueKey('crisis-v2-pillar-${text(pillar['id'])}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _bgInset,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  w(text(pillar['title_en']), text(pillar['title_zh'])),
                  style: const TextStyle(
                    color: _fgPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                w(
                  'Raw ${pillar['raw_score']} · Entry ${pillar['entry_score']}/${pillar['max_score']}',
                  '预警 ${pillar['raw_score']} · 建仓 ${pillar['entry_score']}/${pillar['max_score']}',
                ),
                style: TextStyle(
                  color: entLit ? _mint : (rawLit ? _amber : _fgMuted),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _pillBadge(
            w(text(pillar['route_badge_en']), text(pillar['route_badge_zh'])),
            text(pillar['id']) == 'P3' ? _lilac : _sky,
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < sensors.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _buildSensorRow(asMap(sensors[i])),
          ],
        ],
      ),
    );
  }

  Widget _buildSensorRow(Map<String, dynamic> s) {
    final rawLit = s['raw_alert'] == true;
    final entLit = s['entry_triggered'] == true;
    final statusCode = text(s['status_code']);
    final isM4 = text(s['id']) == 'M4';
    final metrics = asList(s['metrics']);

    final rawBadgeText = rawLit
        ? w('RAW ALERT LIT', '结构预警已亮')
        : w('STRUCT CALM', '结构未触发');
    final rawBadgeColor = rawLit ? _amber : _slate;

    final gateBadgeText = switch (statusCode) {
      'ACTIONABLE' => w('ENTRY ALLOWED', '允许建仓'),
      'RAW_ALERT_HIGH_VOL' => w('HIGH-VOL NO CHASE', '高波禁追'),
      'LATCH_OFF' => w('LATCH OFF', '滞回锁存未开'),
      _ =>
        s['vol_gate_ok'] == true
            ? w('VOL OK', '波动率达标')
            : w('HIGH VOL', '高波门控'),
    };
    final gateBadgeColor = switch (statusCode) {
      'ACTIONABLE' => _mint,
      'RAW_ALERT_HIGH_VOL' => _coral,
      'LATCH_OFF' => _lilac,
      _ => s['vol_gate_ok'] == true ? _sky : _coral,
    };

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _bgObsidian,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (entLit ? _mint : (rawLit ? _amber : _borderLine)).withValues(
            alpha: 0.55,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(text(s['name_en']), text(s['name_zh'])),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              _pillBadge(
                w(text(s['route_tag_en']), text(s['route_tag_zh'])),
                isM4 ? _lilac : _sky,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _pillBadge(rawBadgeText, rawBadgeColor),
              _pillBadge(gateBadgeText, gateBadgeColor),
            ],
          ),
          const SizedBox(height: 7),
          for (final rawM in metrics)
            Builder(
              builder: (_) {
                final m = asMap(rawM);
                final ok = m['passed'] == true;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          w(text(m['label_en']), text(m['label_zh'])),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _fgMuted, fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          text(m['value']),
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ok ? _mint : _fgMuted,
                            fontSize: 11,
                            fontWeight: ok ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 4),
          Text(
            w(text(s['explanation_en']), text(s['explanation_zh'])),
            style: const TextStyle(
              color: _fgMuted,
              fontSize: 10.8,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 4: TIERED PUT TP & SKEW MICROSTRUCTURE STRIP
  // ---------------------------------------------------------------------------
  Widget _buildSection4TpMicrostructure(
    Map<String, dynamic> cockpit, {
    required bool isCompact,
    required bool isWide,
  }) {
    final tp = asMap(cockpit['tp_and_microstructure']);
    final t1 = asMap(tp['tier1_partial']);
    final t2 = asMap(tp['tier2_full']);
    final m = asMap(tp['metrics']);

    final vix = _n(m['vix']) ?? 0;
    final vxn = _n(m['vxn']) ?? 0;
    final vr = _n(m['vix_ratio']) ?? 0;
    final ddPct = _n(m['qqq_ath_dd_pct']) ?? 0;
    final skew10 = _n(m['skew10']) ?? 0;
    final skewP75 = _n(m['skew_p75']) ?? 0;
    final vvix = _n(m['vvix']) ?? 0;
    final vvixP75 = _n(m['vvix_p75']) ?? 0;

    final t2Fired = t2['triggered_today'] == true;
    final t2VrOk = t2['vr_ok'] == true;
    final t2NearItmOk = (t2['near_itm_ok'] ?? t2['dd_ok']) == true;
    final t2VixPanicOk = t2['vix_panic_ok'] == true || vix >= 45.0;
    final nearItmSpot = _n(t2['near_itm_spot_target']);
    final vrGap = _n(t2['vr_gap']) ?? 0;

    return Container(
      key: const ValueKey('crisis-v2-tp-strip'),
      padding: EdgeInsets.all(isCompact ? 13 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: t2Fired ? _mint.withValues(alpha: 0.75) : _borderLine,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w(
              'Right-Tail Put Take-Profit Radar (tp_near_itm_late5x) & Volatility/Skew Microstructure',
              '右尾 Put 止盈雷达（近实值 / VIX>=45 / 晚段 5x）与波动率 / 偏度微结构',
            ),
            style: const TextStyle(
              color: _fgPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),

          // Volatility & Skew Microstructure Tiles
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _metricBox(
                'VIX',
                _fmtNum(vix),
                vix <= 20.0 ? _mint : (vix >= 45.0 ? _mint : (vix >= 30.0 ? _coral : _amber)),
                sub: w('B020 <= 20 · Panic TP >= 45', '常态盾 <= 20 · 恐慌止盈 >= 45'),
              ),
              _metricBox(
                'VXN',
                _fmtNum(vxn),
                vxn <= 27.0 ? _mint : _coral,
                sub: w('M7G <= 27 · M4 <= 28', 'M7G 门控 <= 27 · M4 <= 28'),
              ),
              _metricBox(
                'VIX / VIX3M',
                _fmtNum(vr, dec: 3),
                vr >= 1.10 ? _mint : (vr >= 1.02 ? _coral : _sky),
                sub: w(
                  'VIX3M ${_fmtNum(_n(m['vix3m']))} · TP >= 1.10',
                  'VIX3M ${_fmtNum(_n(m['vix3m']))} · 止盈 >= 1.10',
                ),
              ),
              _metricBox(
                w('QQQ ATH DD', 'QQQ 距前高回撤'),
                _fmtPct(ddPct),
                ddPct <= -12.0 ? _amber : _fgPrimary,
                sub: nearItmSpot != null
                    ? w(
                        'Near-ITM <= \$${nearItmSpot.toStringAsFixed(0)} · CONT_2M <= -12%',
                        '近实值 <= \$${nearItmSpot.toStringAsFixed(0)} · 轮动 <= -12%',
                      )
                    : w('CONT_2M <= -12.0%', '慢熊轮动 <= -12.0%'),
              ),
              _metricBox(
                'SKEW (10D)',
                _fmtNum(skew10, dec: 1),
                skew10 >= skewP75 ? _amber : _fgPrimary,
                sub: 'P75 ${_fmtNum(skewP75, dec: 1)}',
              ),
              _metricBox(
                'VVIX',
                _fmtNum(vvix, dec: 1),
                vvix >= vvixP75 ? _amber : _fgPrimary,
                sub: 'P75 ${_fmtNum(vvixP75, dec: 1)}',
              ),
              ..._buildOptionPricingTiles(asMap(tp['option_pricing'])),
            ],
          ),
          const SizedBox(height: 12),

          // Late 5x TP & Full Right-Tail TP Cards (tp_near_itm_late5x)
          LayoutBuilder(
            builder: (_, c) {
              final twoCol = c.maxWidth >= 780;
              final tier1Box = Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _bgInset,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: _sky.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Text(
                          w(
                            'Late 5x Full TP (<= 60D Base / <= 45D Crisis & >= 5.0x)',
                            '晚段 5x 全额止盈（<= 60D 常态 / <= 45D 危机 且 >= 5.0x）',
                          ),
                          style: const TextStyle(
                            color: _sky,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        _pillBadge(
                          w('100% LIQUIDATE', '100% 清仓落袋'),
                          _sky,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      w(text(t1['rule_en']), text(t1['rule_zh'])),
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              );

              final tier2Box = Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _bgInset,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: (t2Fired ? _mint : _amber).withValues(alpha: 0.55),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        Text(
                          w(
                            'Full Right-Tail TP · (VR >= 1.10 & Near-ITM) OR VIX >= 45',
                            '右尾全额止盈 · (VR >= 1.10 且近实值) 或 VIX >= 45',
                          ),
                          style: TextStyle(
                            color: t2Fired ? _mint : _amber,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        _pillBadge(
                          t2Fired
                              ? w('TRIGGERED 100% TP', '已触发 100% 全额止盈')
                              : w(
                                  'VR Gap ${vrGap > 0 ? '+${vrGap.toStringAsFixed(3)}' : 'MET'}',
                                  '距倒挂线 ${vrGap > 0 ? '+${vrGap.toStringAsFixed(3)}' : '已达标'}',
                                ),
                          t2Fired ? _mint : _amber,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _pillBadge(
                          'VIX/3M ${_fmtNum(vr, dec: 3)} >= 1.10',
                          t2VrOk ? _mint : _slate,
                        ),
                        _pillBadge(
                          nearItmSpot != null
                              ? w(
                                  'Near-ITM <= \$${nearItmSpot.toStringAsFixed(1)} (1.05xK)',
                                  '近实值 <= \$${nearItmSpot.toStringAsFixed(1)} (1.05xK)',
                                )
                              : w('Near-ITM (QQQ <= 1.05xK)', '近实值 (QQQ <= 1.05xK)'),
                          t2NearItmOk ? _mint : _slate,
                        ),
                        _pillBadge(
                          'OR VIX ${_fmtNum(vix, dec: 1)} >= 45.0',
                          t2VixPanicOk ? _mint : _slate,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      w(
                        text(tp['deploy_5d_rule_en']),
                        text(tp['deploy_5d_rule_zh']),
                      ),
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 11.2,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              );

              if (twoCol) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: tier1Box),
                    const SizedBox(width: 12),
                    Expanded(child: tier2Box),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [tier1Box, const SizedBox(height: 10), tier2Box],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 5: REAL MIT OPRA HISTORICAL VERIFICATION (SINGLE v2.0 vs 100% QQQ)
  // ---------------------------------------------------------------------------
  Widget _buildSection5OpraBacktest(
    Map<String, dynamic> backtest, {
    required bool isCompact,
    required bool isWide,
  }) {
    final prov = asMap(backtest['opra_provenance']);
    final win = asMap(backtest['active_window']);
    final opraCutoff = text(win['opra_cutoff_date']).isNotEmpty
        ? text(win['opra_cutoff_date'])
        : '2025-12-15';
    final winEnd = text(win['end_date']).isNotEmpty
        ? text(win['end_date'])
        : '2026-11-25';
    final endYm = winEnd.length >= 7
        ? winEnd.substring(0, 7).replaceAll('-', '.')
        : winEnd;
    final kPri = asMap(win['kpi_primary']);
    final kStr = asMap(win['kpi_stress']);
    final kQqq = asMap(win['kpi_qqq']);
    final series = asList(win['daily_series']);
    final crises = asList(win['crisis_comparison']);
    final putLedger = asList(win['put_ledger']);
    final openPutsAtEnd = asList(win['open_puts_at_end']);
    final ctaLedger = asList(win['cta_rotation_ledger']);
    final ctaRestoreLedger = asList(win['cta_restore_ledger']);

    // Filter combined ledger
    final filteredPuts = putLedger.where((raw) {
      final t = asMap(raw);
      final sl = text(t['sleeve']);
      if (ledgerFilter == 'base') return sl == 'base';
      if (ledgerFilter == 'route1') return sl == 'crisis';
      if (ledgerFilter == 'm4') return sl == 'crisis_m4';
      return ledgerFilter != 'cta';
    }).toList();

    return Container(
      key: const ValueKey('crisis-v2-backtest'),
      padding: EdgeInsets.all(isCompact ? 13 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header + 11Y / 5Y Zero-Splice Window Toggle (ONLY 1 Strategy!)
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'Real MIT OPRA Historical Verification · v3.0 Double-Champion (Plan D) vs 100% QQQ',
                      '真实 MIT OPRA 历史验证 · v3.0 双冠终极版（Plan D）vs 100% QQQ',
                    ),
                    style: const TextStyle(
                      color: _fgPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      '6,382,288 real MIT OPRA quotes (2015-2025.12) + real spot & OPRA-calibrated Z-surface BSM extension (2025.12-$endYm) · Hover for trades · Click to pin PIT',
                      '6,382,288 条真实 OPRA 盘口（2015-2025.12）+ 真实现货与 OPRA 残差校准 BSM 延展（2025.12-$endYm）· 悬停即看逐笔买卖明细 · 点击锁定 PIT 回放',
                    ),
                    style: const TextStyle(color: _fgMuted, fontSize: 11.5),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _windowToggleBtn(
                    '11y_opra',
                    w('12Y Full (2015-$endYm)', '全周期（2015-$endYm）'),
                  ),
                  _windowToggleBtn(
                    '5y_live',
                    w('6Y Zero-Splice (2020.12-$endYm)', '零拼接（2020.12-$endYm）'),
                  ),
                  _miniBtn(
                    useLogScale ? w('Log Scale', '对数坐标') : w('Linear', '线性坐标'),
                    () => setState(() => useLogScale = !useLogScale),
                    accent: _sky,
                  ),
                ],
              ),
            ],
          ),

          if (switchingWindow) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2, color: _mint),
          ],

          const SizedBox(height: 12),

          // 3-Row Clean KPI Comparison Table (v2.0 Primary vs Stress vs 100% QQQ)
          _horizontalTable(
            minWidth: isCompact ? 760 : 880,
            child: Container(
              decoration: BoxDecoration(
                color: _bgInset,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: _borderLine),
              ),
              child: Column(
                children: [
                  _kpiHeaderRow(),
                  _kpiDataRow(
                    w(
                      'v3.0 Plan D (Box +35bp · IBKR Limit)',
                      'v3.0 双冠主策略（Box +35bp · 限价）',
                    ),
                    kPri,
                    highlight: true,
                  ),
                  _kpiDataRow(
                    w(
                      'v3.0 Stress (IBKR +150bp · Full Ask/Bid)',
                      'v3.0 极端压测（IBKR +150bp · 对手盘）',
                    ),
                    kStr,
                  ),
                  _kpiDataRow(
                    w('100% QQQ Buy & Hold', '100% QQQ 买入持有基准'),
                    kQqq,
                    isBench: true,
                  ),
                ],
              ),
            ),
          ),

          if (asMap(win['kpi_opra_verified_primary']).isNotEmpty) ...[
            const SizedBox(height: 8),
            Builder(
              builder: (_) {
                final kOp = asMap(win['kpi_opra_verified_primary']);
                final gTurn = _n(kOp['put_gross_turnover_pct_nav_yr']) ?? 6.11;
                final rSalv = _n(kOp['put_roll_salvage_pct']) ?? 67.1;
                final nBld = _n(kOp['put_true_net_bleed_pct_nav_yr']) ?? 2.04;
                return Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _pillBadge(
                      w(
                        'Pure Real MIT OPRA (${text(win['start_date'])} -> $opraCutoff): ${_fmtPct(_n(kOp['cagr_pct']), signed: false)} CAGR · ${_fmtPct(_n(kOp['max_dd_pct']), signed: false)} MDD · ${_fmtNum(_n(kOp['calmar']), dec: 3)} Calmar · ${_fmtUsd(_n(kOp['end_nav']))}',
                        '纯真 MIT OPRA 审计段（${text(win['start_date'])} -> $opraCutoff）：CAGR ${_fmtPct(_n(kOp['cagr_pct']), signed: false)} · MDD ${_fmtPct(_n(kOp['max_dd_pct']), signed: false)} · Calmar ${_fmtNum(_n(kOp['calmar']), dec: 3)} · 终值 ${_fmtUsd(_n(kOp['end_nav']))}',
                      ),
                      _mint,
                    ),
                    _pillBadge(
                      w(
                        'Roll Cost Audit: Gross ${gTurn.toStringAsFixed(2)}%/yr -> Salvage ${rSalv.toStringAsFixed(1)}% -> True Net Bleed ${nBld.toStringAsFixed(2)}% NAV/yr',
                        '滚仓成本审计：名义流水 ${gTurn.toStringAsFixed(2)}%/yr -> 残值回收 ${rSalv.toStringAsFixed(1)}% -> 真实净损耗仅 ${nBld.toStringAsFixed(2)}% NAV/yr',
                      ),
                      _amber,
                    ),
                  ],
                );
              },
            ),
          ],

          const SizedBox(height: 8),
          Text(
            w(text(win['disclosure_en']), text(win['disclosure_zh'])),
            style: const TextStyle(color: _fgMuted, fontSize: 11),
          ),
          if (asMap(prov['bsm_calibration']).isNotEmpty) ...[
            const SizedBox(height: 6),
            Builder(
              builder: (_) {
                final cal = asMap(prov['bsm_calibration']);
                return Container(
                  key: const ValueKey('crisis-v2-bsm-calibration-note'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _sky.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: _sky.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    w(
                      'OPRA-Residual Calibration (1.50M real OPRA puts + ${cal['oos_2026_real_n'] ?? 9937} OOS 2026 real trades): '
                      '125D -15% MedAPE ${cal['d125_medape_before_pct']}% -> ${cal['d125_medape_after_pct']}% (entry sim/real ${cal['entry_104_med_sim_real']}x) · '
                      'Crash TP MedAPE ${cal['crash_tp_medape_before_pct']}% -> ${cal['crash_tp_medape_after_pct']}% (eliminated +${cal['crash_tp_bias_before_pct']}% overpricing) · '
                      '2026 OOS MedAPE ${cal['oos_2026_medape_before_pct']}% -> ${cal['oos_2026_medape_after_pct']}% · Half-Spread MedAE ${cal['hs_125d_medae_before_pp']}pp -> ${cal['hs_125d_medae_after_pp']}pp.',
                      'OPRA 实盘残差校准（150 万条真实期权拟合 + ${cal['oos_2026_real_n'] ?? 9937} 条 2026 样本外实盘校验）：'
                      '125D -15% 中位误差 ${cal['d125_medape_before_pct']}% -> ${cal['d125_medape_after_pct']}%（建仓比 ${cal['entry_104_med_sim_real']}x）· '
                      '崩盘止盈误差 ${cal['crash_tp_medape_before_pct']}% -> ${cal['crash_tp_medape_after_pct']}%（消除 +${cal['crash_tp_bias_before_pct']}% 高估）· '
                      '2026 样本外实盘误差 ${cal['oos_2026_medape_before_pct']}% -> ${cal['oos_2026_medape_after_pct']}% · 半价差误差 ${cal['hs_125d_medae_before_pp']}pp -> ${cal['hs_125d_medae_after_pp']}pp。',
                    ),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 10.6,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                );
              },
            ),
          ],

          const SizedBox(height: 14),

          // Interactive Dual-Panel Equity + Drawdown + Leverage Chart + PIT Event Markers
          if (series.isNotEmpty)
            _buildInteractiveChart(
              series,
              putLedger,
              isCompact,
              opraCutoffDate: opraCutoff,
              openPutsAtEnd: openPutsAtEnd,
              ctaLedger: ctaLedger,
              ctaRestoreLedger: ctaRestoreLedger,
            ),

          const SizedBox(height: 12),

          // Interactive PIT Historical Operation, Put TP, Skew Ratio & 1-Put/1-Lot-QQQ Inspector
          _buildPitOperationsInspector(putLedger, isCompact),

          const SizedBox(height: 16),

          // 8-Crisis Historical Anatomy Comparison Table
          Text(
            w(
              'Historical Crisis Anatomy (v3.0 Double-Champion vs 100% QQQ)',
              '历次真实危机解剖对比（v3.0 双冠终极版 vs 100% QQQ）',
            ),
            style: const TextStyle(
              color: _fgPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          _horizontalTable(
            minWidth: isCompact ? 720 : 860,
            child: Container(
              decoration: BoxDecoration(
                color: _bgInset,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: _borderLine),
              ),
              child: Column(
                children: [
                  _crisisHeaderRow(),
                  for (final rawC in crises) _crisisDataRow(asMap(rawC)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Collapsible Real MIT OPRA Put & Dual-CTA Trade Ledger
          InkWell(
            key: const ValueKey('crisis-v2-ledger-toggle'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => showLedger = !showLedger),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _bgInset,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _borderLine),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      w(
                        'Real MIT OPRA Put (${putLedger.length}) & Dual-CTA Rotation (${ctaLedger.length}) Forensic Ledger',
                        '真实 MIT OPRA 期权（${putLedger.length} 笔）与双CTA 轮动（${ctaLedger.length} 笔）逐笔审计台账',
                      ),
                      style: const TextStyle(
                        color: _fgPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    showLedger
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: _fgMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),

          if (showLedger) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ledgerFilterChip('all', w('All Puts', '全部 Put')),
                _ledgerFilterChip('base', w('B020 Base (0.20%)', 'B020 常态盾 0.20%')),
                _ledgerFilterChip(
                  'route1',
                  w('M7G Standard (125D -15%)', 'M7G 标准 125D -15%'),
                ),
                _ledgerFilterChip('m4', w('M4 Slow-Bear (90D -15%)', 'M4 慢熊 90D -15%')),
                _ledgerFilterChip(
                  'cta',
                  w('Dual-CTA CONT_2M', '双CTA CONT_2M 轮动'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (ledgerFilter == 'cta')
              _buildCtaLedgerTable(ctaLedger, isCompact)
            else
              _buildPutLedgerTable(filteredPuts, isCompact),
          ],

          const SizedBox(height: 10),
          Text(
            w(
              'Provenance: ${text(prov['primary_fill_en'])} · Stress: ${text(prov['stress_fill_en'])}. Historical backtest for quantitative research only.',
              '数据口径：${text(prov['primary_fill_zh'])} · 压测：${text(prov['stress_fill_zh'])}。历史回测仅作量化研究参考。',
            ),
            style: const TextStyle(color: _slate, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildOptionPricingTiles(Map<String, dynamic> op) {
    if (op.isEmpty) return const [];
    final sk = asMap(op['skew_ratio']);
    final p125 = asMap(op['put_125d_15otm']);
    final p90 = asMap(op['put_90d_15otm'] ?? op['put_90d_10otm']);
    final isReal = text(op['quote_source']) == 'real_opra';
    final srcTag = isReal ? w('OPRA', 'OPRA实盘') : w('BSM Est', 'BSM估算');
    final sk20 = _n(sk['opra_iv_20_10']);
    final sk15 = _n(sk['opra_iv_15_atm']);
    final lot125 = _n(p125['put_to_lot_pct']);
    final lot90 = _n(p90['put_to_lot_pct']);

    return [
      _metricBox(
        w('Skew Ratio (-20/-10)', '偏度比 IV(-20/-10)'),
        sk20 != null ? '${sk20.toStringAsFixed(3)}x' : '--',
        (sk20 ?? 0) >= 1.22 ? _amber : _mint,
        sub:
            'IV(-15/ATM) ${sk15 != null ? '${sk15.toStringAsFixed(2)}x' : '--'} · $srcTag',
      ),
      _metricBox(
        w('1 Put / 100 QQQ (125D -15%)', '1张 Put / 1手 QQQ（125D -15%）'),
        lot125 != null ? '${lot125.toStringAsFixed(2)}%' : '--',
        (lot125 ?? 99) <= 1.25 ? _mint : ((lot125 ?? 0) >= 2.2 ? _coral : _sky),
        sub:
            '${_fmtUsd(_n(p125['one_put_usd']))} / ${_fmtUsd(_n(p125['one_lot_qqq_usd']))} · K \$${_fmtNum(_n(p125['strike']), dec: 0)}',
      ),
      _metricBox(
        w('1 Put / 100 QQQ (M4 90D -15%)', '1张 Put / 1手 QQQ（M4 90D -15%）'),
        lot90 != null ? '${lot90.toStringAsFixed(2)}%' : '--',
        _lilac,
        sub:
            '${_fmtUsd(_n(p90['one_put_usd']))} / ${_fmtUsd(_n(p90['one_lot_qqq_usd']))} · K \$${_fmtNum(_n(p90['strike']), dec: 0)} · IV ${_fmtNum(_n(p90['iv_pct']), dec: 1)}%',
      ),
    ];
  }

  String _pitReasonLabel(String r) {
    return switch (r) {
      'tp_near_itm' => w(
        'Right-Tail Full TP (Near-ITM / VIX>=45)',
        '右尾全额止盈（近实值 / VIX>=45）',
      ),
      'base_tp_near_itm' => w(
        'Base Right-Tail TP (Near-ITM / VIX>=45)',
        '常态盾右尾止盈（近实值 / VIX>=45）',
      ),
      'tp_5x_late' => w(
        'Late 5x Full TP (<=45D & >=5.0x)',
        '危机盾晚段 5x 全额止盈（<=45D）',
      ),
      'base_tp_5x_late' => w(
        'Base Late 5x Full TP (<=60D/45D & >=5.0x)',
        '常态盾晚段 5x 全额止盈',
      ),
      'tp_vr110_dd10_full' => w(
        'Full Right-Tail TP',
        '右尾全额止盈',
      ),
      'tp_5x_partial' => w(
        '5x Take-Profit',
        '5x 止盈落袋',
      ),
      'roll_75d' => w('Hard 75D Roll / Salvage', '75D 强制早滚 / 回收残值'),
      'roll_30d' => w('Hard 30D Roll / Salvage', '30D 强制收回 / 滚仓'),
      'salvage_30d_slowbear' => w(
        'Slow-Bear 30D Salvage (VIX > 20 Pause)',
        '慢熊 30DTE 残值收回（VIX > 20 暂停）',
      ),
      'salvage_vix_expensive' => w(
        '75D Salvage (VIX > 20 Pause)',
        '75D 残值回收（VIX > 20 暂停）',
      ),
      'close_75d_signal_off' => w(
        '75D Signal-Off Recycle',
        '75D 信号熄灭回收残值',
      ),
      'recycle_30d_m4' => w('M4 30D Salvage Recycle', 'M4 30D 残值回收'),
      'expiry' || 'expiry_itm' || 'expiry_otm' => w('Contract Expiry Settlement', '合约到期结算'),
      'cont_2m_cta_to_qqq' => w(
        'CONT_2M Dual-CTA -> QQQ Rotation',
        '持续2月跌超-12% · 卖CTA买QQQ',
      ),
      '1y_mechanical_restore' => w(
        '1-Year Mechanical LTCG Restore',
        '满1年 LTCG 机械恢复 DBMF/KMLM',
      ),
      _ => r,
    };
  }

  String _fmtStrike(num? k) {
    if (k == null || !k.isFinite) return '--';
    final d = k.toDouble();
    if ((d - d.round()).abs() < 0.01) return d.round().toString();
    return d.toStringAsFixed(2);
  }

  String _shortExp(String exp) {
    if (exp.length == 10 && exp.startsWith('20')) return exp.substring(2);
    return exp;
  }

  String _sleeveShortTag(String sl) {
    return switch (sl) {
      'base' => w('B020 Base', 'B020 常态盾'),
      'crisis' => w('M7G Crisis', 'M7G 危机盾'),
      'crisis_m4' => w('M4 Slow-Bear', 'M4 慢熊盾'),
      _ => sl,
    };
  }

  Map<String, List<Map<String, dynamic>>> _getHoverEventsByDate(
    List<dynamic> putLedger,
    List<dynamic> openPutsAtEnd,
    List<dynamic> ctaLedger,
    List<dynamic> ctaRestoreLedger,
  ) {
    final firstPutId = putLedger.isNotEmpty
        ? text(asMap(putLedger.first)['tranche_id'])
        : '';
    final lastPutDate = putLedger.isNotEmpty
        ? text(asMap(putLedger.last)['exit_date'])
        : '';
    final key =
        '${widget.asOf}|$selectedWindow|${putLedger.length}|${openPutsAtEnd.length}|${ctaLedger.length}|${ctaRestoreLedger.length}|$firstPutId|$lastPutDate';
    if (key == _hoverEventsCacheKey && _hoverEventsByDate.isNotEmpty) {
      return _hoverEventsByDate;
    }

    final map = <String, List<Map<String, dynamic>>>{};
    void addEvent(String d, Map<String, dynamic> ev) {
      if (d.isEmpty) return;
      (map[d] ??= <Map<String, dynamic>>[]).add(ev);
    }

    final seenEntryKeys = <String>{};
    void indexPutEntry(Map<String, dynamic> t) {
      final ed = text(t['entry_date']);
      if (ed.isEmpty) return;
      final dk =
          '${text(t['tranche_id'])}|$ed|${text(t['strike'])}|${text(t['exp'])}';
      if (!seenEntryKeys.add(dk)) return;
      addEvent(ed, {
        'action': 'PUT_OPEN',
        'sleeve': text(t['sleeve']),
        'exp': text(t['exp']),
        'strike': _n(t['strike']),
        'target_dte': _n(t['target_dte']),
        'roll_dte': _n(t['roll_dte']),
        'contracts': _n(t['contracts']),
        'fill': _n(t['entry_fill']),
        'amount_usd': _n(t['cost_usd']),
        'dte': _n(t['entry_dte']),
        'lot_pct': _n(t['entry_lot_pct']),
        'quote_source': text(t['quote_source']),
        'priority': text(t['sleeve']) == 'base' ? 2 : 1,
      });
    }

    for (final raw in putLedger) {
      final t = asMap(raw);
      indexPutEntry(t);
      final xd = text(t['exit_date']);
      if (xd.isEmpty) continue;
      final reason = text(t['exit_reason']);
      final isTp = reason.contains('tp_');
      final isRoll = reason.startsWith('roll_');
      addEvent(xd, {
        'action': isTp ? 'PUT_TP' : (isRoll ? 'PUT_ROLL' : 'PUT_CLOSE'),
        'sleeve': text(t['sleeve']),
        'exp': text(t['exp']),
        'strike': _n(t['strike']),
        'contracts': _n(t['contracts']),
        'fill': _n(t['exit_fill']),
        'entry_fill': _n(t['entry_fill']),
        'amount_usd': _n(t['exit_usd']),
        'cost_usd': _n(t['cost_usd']),
        'net_pnl_usd': _n(t['net_pnl_usd']),
        'roi_mult': _n(t['roi_mult']),
        'dte': _n(t['exit_dte']),
        'lot_pct': _n(t['exit_lot_pct']),
        'reason': reason,
        'quote_source': text(t['quote_source']),
        'priority': isTp ? 0 : 3,
      });
    }

    for (final raw in openPutsAtEnd) {
      indexPutEntry(asMap(raw));
    }

    for (final raw in ctaLedger) {
      final c = asMap(raw);
      final d = text(c['date']).isNotEmpty
          ? text(c['date'])
          : text(c['exec_date']);
      addEvent(d, {
        'action': 'CTA_ROTATE',
        'sleeve': text(c['sleeve']),
        'tranche': _n(c['tranche'])?.toInt(),
        'amount_usd': _n(c['sold_usd']),
        'qqq_dd_pct': _n(c['qqq_dd_pct']),
        'restore_due': text(c['restore_due']),
        'priority': 1,
      });
    }

    for (final raw in ctaRestoreLedger) {
      final c = asMap(raw);
      final d = text(c['date']);
      addEvent(d, {
        'action': 'CTA_RESTORE',
        'sleeve': text(c['sleeve']),
        'lots_matured': _n(c['lots_matured'])?.toInt() ?? 1,
        'amount_usd': _n(c['restored_usd']),
        'hold_days': _n(c['hold_days'])?.toInt() ?? 365,
        'priority': 1,
      });
    }

    for (final list in map.values) {
      list.sort(
        (a, b) =>
            ((a['priority'] as int?) ?? 9).compareTo((b['priority'] as int?) ?? 9),
      );
    }

    _hoverEventsCacheKey = key;
    _hoverEventsByDate = map;
    return map;
  }

  Widget _buildInteractiveChart(
    List<dynamic> series,
    List<dynamic> putLedger,
    bool isCompact, {
    String opraCutoffDate = '2025-12-15',
    List<dynamic> openPutsAtEnd = const [],
    List<dynamic> ctaLedger = const [],
    List<dynamic> ctaRestoreLedger = const [],
  }) {
    final eventsByDate = _getHoverEventsByDate(
      putLedger,
      openPutsAtEnd,
      ctaLedger,
      ctaRestoreLedger,
    );
    final totalN = series.length;
    final maxIdx = math.max(0, totalN - 1);
    final minSpan = math.min(15, maxIdx);
    final sIdx = totalN < 2
        ? 0
        : (rangeStartIdx ?? 0).clamp(0, math.max(0, maxIdx - minSpan)).toInt();
    final eIdx = totalN < 2
        ? 0
        : (rangeEndIdx ?? maxIdx).clamp(math.min(maxIdx, sIdx + minSpan), maxIdx).toInt();
    final isZoomed = totalN >= 2 && (sIdx > 0 || eIdx < maxIdx);
    final visibleSeries = totalN < 2
        ? series
        : series.sublist(sIdx, eIdx + 1);
    final rebaseActive = isZoomed && rebaseZoomedSlice;

    int pinnedVisIdx = -1;
    if (pinnedPitDate != null) {
      for (var i = 0; i < visibleSeries.length; i++) {
        if (text(asMap(visibleSeries[i])['date']) == pinnedPitDate) {
          pinnedVisIdx = i;
          break;
        }
      }
    }
    final activeIdx = hoverIndex >= 0 && hoverIndex < visibleSeries.length
        ? hoverIndex
        : (pinnedVisIdx >= 0
              ? pinnedVisIdx
              : math.max(0, visibleSeries.length - 1));
    final activeRow = visibleSeries.isNotEmpty
        ? asMap(visibleSeries[activeIdx])
        : const <String, dynamic>{};
    final activeEvt = (_n(activeRow['evt'])?.toInt()) ?? 0;
    final chartH = isCompact ? 268.0 : 330.0;

    // Real-time slice return & within-slice MDD
    double sliceV2Ret = 0.0;
    double sliceQRet = 0.0;
    double sliceV2Mdd = 0.0;
    double sliceQMdd = 0.0;
    double activeSliceV2Ret = 0.0;
    double activeSliceQRet = 0.0;
    if (visibleSeries.length >= 2) {
      final firstM = asMap(visibleSeries.first);
      final lastM = asMap(visibleSeries.last);
      final bV2 = math.max(1e-6, (_n(firstM['nav_v2']) ?? 100000.0).toDouble());
      final bQ = math.max(1e-6, (_n(firstM['nav_qqq']) ?? 100000.0).toDouble());
      final eV2 = (_n(lastM['nav_v2']) ?? bV2).toDouble();
      final eQ = (_n(lastM['nav_qqq']) ?? bQ).toDouble();
      sliceV2Ret = (eV2 / bV2 - 1.0) * 100.0;
      sliceQRet = (eQ / bQ - 1.0) * 100.0;
      final aV2 = (_n(activeRow['nav_v2']) ?? bV2).toDouble();
      final aQ = (_n(activeRow['nav_qqq']) ?? bQ).toDouble();
      activeSliceV2Ret = (aV2 / bV2 - 1.0) * 100.0;
      activeSliceQRet = (aQ / bQ - 1.0) * 100.0;

      double pkV2 = bV2;
      double pkQ = bQ;
      for (final raw in visibleSeries) {
        final m = raw as Map;
        final v2 = (m['nav_v2'] as num?)?.toDouble() ?? bV2;
        final q = (m['nav_qqq'] as num?)?.toDouble() ?? bQ;
        if (v2 > pkV2) pkV2 = v2;
        if (q > pkQ) pkQ = q;
        final d2 = (v2 / pkV2 - 1.0) * 100.0;
        final dq = (q / pkQ - 1.0) * 100.0;
        if (d2 < sliceV2Mdd) sliceV2Mdd = d2;
        if (dq < sliceQMdd) sliceQMdd = dq;
      }
    }

    // Aggregate distinct Put TP dates for 1-click quick-jump badges
    final tpMap = <String, Map<String, dynamic>>{};
    for (final raw in putLedger) {
      final t = asMap(raw);
      if (!text(t['exit_reason']).contains('tp_')) continue;
      final d = text(t['exit_date']);
      if (d.isEmpty) continue;
      final roi = _n(t['roi_mult'])?.toDouble() ?? 0.0;
      final pnl = _n(t['net_pnl_usd'])?.toDouble() ?? 0.0;
      final cur = tpMap[d];
      if (cur == null) {
        tpMap[d] = {'date': d, 'max_roi': roi, 'net_pnl': pnl, 'count': 1};
      } else {
        cur['max_roi'] = math.max((cur['max_roi'] as double), roi);
        cur['net_pnl'] = (cur['net_pnl'] as double) + pnl;
        cur['count'] = (cur['count'] as int) + 1;
      }
    }
    final tpList = tpMap.values.toList()
      ..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));

    return Container(
      key: const ValueKey('crisis-v2-chart'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _bgObsidian,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Frameless horizontal legend + active hover readout
          Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 11,
                runSpacing: 4,
                children: [
                  _legendDot(
                    rebaseActive
                        ? w('v3.0 Plan D (Base 100)', 'v3.0 双冠归一净值')
                        : w('v3.0 Plan D NAV', 'v3.0 双冠净值'),
                    _mint,
                  ),
                  _legendDot(
                    rebaseActive
                        ? w('QQQ (Base 100)', 'QQQ 归一基准')
                        : w('100% QQQ B&H', '100% QQQ 基准'),
                    _sky,
                  ),
                  _legendDot(w('Daily Lev (Natural Drift)', '每日杠杆（自然漂移）'), _amber),
                  _legendDot(w('Slow-Bear Latch', '慢熊锁存期'), _lilac),
                  _legendMarker('◆', w('Put TP', 'Put 止盈'), _amber),
                  _legendMarker('▲', w('M7G Crisis Open', 'M7G 危机盾建仓'), _coral),
                  _legendMarker('▼', w('75D/30D Salvage', '75D/30D 残值收回'), _lilac),
                  _legendMarker('●', w('B020 Base Put', 'B020 常态盾'), _sky),
                  _legendMarker('■', w('CTA Rotate', '双CTA轮动'), _mint),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    isZoomed
                        ? '${text(activeRow['date'])}  ·  v3.0 ${_fmtPct(activeSliceV2Ret)} (${_fmtUsd(_n(activeRow['nav_v2']))})  ·  QQQ ${_fmtPct(activeSliceQRet)}  ·  Lev ${_fmtNum(_n(activeRow['lev']), dec: 3)}x'
                        : '${text(activeRow['date'])}  ·  v3.0 ${_fmtUsd(_n(activeRow['nav_v2']))} (${_fmtPct(_n(activeRow['dd_v2']), signed: false)})  ·  QQQ ${_fmtUsd(_n(activeRow['nav_qqq']))}  ·  Lev ${_fmtNum(_n(activeRow['lev']), dec: 3)}x',
                    style: const TextStyle(
                      color: _fgPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((activeEvt & 4) != 0)
                    _pillBadge(w('◆ Put TP', '◆ Put 止盈'), _amber),
                  if ((activeEvt & 2) != 0)
                    _pillBadge(w('▲ Crisis Put Open', '▲ 危机 Put 建仓'), _coral),
                  if ((activeEvt & 1) != 0)
                    _pillBadge(w('● 0.2% Base Open', '● 常态 0.2% 建仓'), _sky),
                  if ((activeEvt & 8) != 0)
                    _pillBadge(
                      w('▼ 75D/30D Salvage', '▼ 75D/30D 残值收回'),
                      _lilac,
                    ),
                  if ((activeEvt & 16) != 0)
                    _pillBadge(w('■ Dual-CTA Rotate', '■ 双CTA 轮动'), _mint),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (_, c) {
              final width = c.maxWidth;
              int snapIdxFromDx(double dx) {
                if (visibleSeries.isEmpty) return 0;
                const padL = 54.0;
                const padR = 14.0;
                final plotW = math.max(1.0, width - padL - padR);
                final maxVIdx = math.max(0, visibleSeries.length - 1);
                final frac = ((dx - padL) / plotW).clamp(0.0, 1.0);
                final exactIdx = (frac * maxVIdx).round();
                final exactRow = asMap(visibleSeries[exactIdx]);
                final exactEvt = (_n(exactRow['evt'])?.toInt()) ?? 0;
                final exactDate = text(exactRow['date']);
                if (exactEvt != 0 ||
                    (eventsByDate[exactDate]?.isNotEmpty ?? false) ||
                    maxVIdx == 0) {
                  return exactIdx;
                }
                int prioOf(int evt) {
                  if ((evt & 4) != 0) return 5;
                  if ((evt & 2) != 0) return 4;
                  if ((evt & 16) != 0) return 3;
                  if ((evt & 8) != 0) return 2;
                  if ((evt & 1) != 0) return 1;
                  return 0;
                }

                const snapPx = 5.5;
                final stepRadius = math.max(
                  1,
                  ((snapPx / plotW) * maxVIdx).ceil(),
                );
                final lo = math.max(0, exactIdx - stepRadius);
                final hi = math.min(maxVIdx, exactIdx + stepRadius);
                int bestIdx = exactIdx;
                int bestPrio = 0;
                double bestDist = double.infinity;
                for (var i = lo; i <= hi; i++) {
                  final ev = (_n(asMap(visibleSeries[i])['evt'])?.toInt()) ?? 0;
                  final pr = prioOf(ev);
                  if (pr == 0) continue;
                  final px = padL + (i / maxVIdx) * plotW;
                  final dist = (px - dx).abs();
                  if (dist <= snapPx &&
                      (pr > bestPrio || (pr == bestPrio && dist < bestDist))) {
                    bestPrio = pr;
                    bestDist = dist;
                    bestIdx = i;
                  }
                }
                return bestIdx;
              }

              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (ev) {
                  final nextIdx = snapIdxFromDx(ev.localPosition.dx);
                  if (nextIdx != hoverIndex) {
                    setState(() => hoverIndex = nextIdx);
                  }
                },
                onExit: (_) {
                  if (hoverIndex != -1) setState(() => hoverIndex = -1);
                },
                child: GestureDetector(
                  onTapUp: (details) {
                    if (visibleSeries.isEmpty) return;
                    final idx = snapIdxFromDx(details.localPosition.dx);
                    final d = text(asMap(visibleSeries[idx])['date']);
                    if (d.isNotEmpty) unawaited(_loadPitDate(d));
                  },
                  child: SizedBox(
                    key: const ValueKey('crisis-v2-chart-canvas'),
                    height: chartH,
                    width: width,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _CrisisV2EquityChartPainter(
                              series: visibleSeries,
                              useLogScale: useLogScale,
                              rebaseTo100: rebaseActive,
                              hoverIndex: hoverIndex,
                              pinnedDate: pinnedPitDate,
                              opraCutoffDate: opraCutoffDate,
                              simExtTag: w(
                                '2026 BSM Sim ->',
                                '2026 BSM模拟 ->',
                              ),
                            ),
                          ),
                        ),
                        if (hoverIndex >= 0 &&
                            hoverIndex < visibleSeries.length)
                          _buildChartHoverTooltip(
                            width: width,
                            chartH: chartH,
                            visibleSeries: visibleSeries,
                            hoverIdx: hoverIndex,
                            isZoomed: isZoomed,
                            activeSliceV2Ret: activeSliceV2Ret,
                            activeSliceQRet: activeSliceQRet,
                            opraCutoffDate: opraCutoffDate,
                            eventsByDate: eventsByDate,
                            putLedger: putLedger,
                            openPutsAtEnd: openPutsAtEnd,
                            isCompact: isCompact,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          if (totalN >= 2) ...[
            const SizedBox(height: 10),
            _buildRangeBrushBar(
              series: series,
              sIdx: sIdx,
              eIdx: eIdx,
              isZoomed: isZoomed,
              sliceV2Ret: sliceV2Ret,
              sliceQRet: sliceQRet,
              sliceV2Mdd: sliceV2Mdd,
              sliceQMdd: sliceQMdd,
              isCompact: isCompact,
              opraCutoffDate: opraCutoffDate,
            ),
          ],
          if (tpList.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w('Jump to Put TP:', '一键直达 Put 止盈日：'),
                  style: const TextStyle(
                    color: _fgMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final tp in tpList)
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => unawaited(_loadPitDate(tp['date'] as String)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: pinnedPitDate == tp['date']
                            ? _amber.withValues(alpha: 0.22)
                            : _bgInset,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: pinnedPitDate == tp['date']
                              ? _amber
                              : _amber.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        '◆ ${tp['date']} (${(tp['max_roi'] as double).toStringAsFixed(1)}x · ${_fmtUsd(tp['net_pnl'] as double, signed: true)})',
                        style: TextStyle(
                          color: pinnedPitDate == tp['date']
                              ? _fgPrimary
                              : _amber,
                          fontSize: 10.6,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChartHoverTooltip({
    required double width,
    required double chartH,
    required List<dynamic> visibleSeries,
    required int hoverIdx,
    required bool isZoomed,
    required double activeSliceV2Ret,
    required double activeSliceQRet,
    required String opraCutoffDate,
    required Map<String, List<Map<String, dynamic>>> eventsByDate,
    required List<dynamic> putLedger,
    required List<dynamic> openPutsAtEnd,
    required bool isCompact,
  }) {
    const padL = 54.0;
    const padR = 14.0;
    final plotW = math.max(1.0, width - padL - padR);
    final maxVIdx = math.max(1, visibleSeries.length - 1);
    final mx = visibleSeries.length < 2
        ? padL
        : padL + (hoverIdx / maxVIdx) * plotW;

    final row = asMap(visibleSeries[hoverIdx]);
    final hoverDate = text(row['date']);
    final qqqPx = _n(row['qqq'])?.toDouble();
    final vr = _n(row['vr'])?.toDouble();
    final navV2 = _n(row['nav_v2'])?.toDouble();
    final navQqq = _n(row['nav_qqq'])?.toDouble();
    final ddV2 = _n(row['dd_v2'])?.toDouble();
    final lev = _n(row['lev'])?.toDouble();
    final isRealOpra =
        hoverDate.isNotEmpty && hoverDate.compareTo(opraCutoffDate) <= 0;

    final dayEvents = eventsByDate[hoverDate] ?? const <Map<String, dynamic>>[];

    // Accent border reflects highest-priority trade on this date
    Color borderAccent = _borderLine;
    if (dayEvents.isNotEmpty) {
      final topAct = text(dayEvents.first['action']);
      final topSl = text(dayEvents.first['sleeve']);
      borderAccent = switch (topAct) {
        'PUT_TP' => _amber.withValues(alpha: 0.85),
        'CTA_ROTATE' || 'CTA_RESTORE' => _mint.withValues(alpha: 0.80),
        'PUT_OPEN' =>
          (topSl == 'crisis_m4'
                  ? _lilac
                  : (topSl == 'crisis' ? _coral : _sky))
              .withValues(alpha: 0.80),
        'PUT_ROLL' || 'PUT_CLOSE' => _lilac.withValues(alpha: 0.80),
        _ => _fgMuted.withValues(alpha: 0.65),
      };
    }

    // Scan active open Put shields on quiet days (zero trades executed on hoverDate)
    final activeOpenPuts = <Map<String, dynamic>>[];
    if (dayEvents.isEmpty && hoverDate.isNotEmpty) {
      for (final raw in putLedger) {
        final t = asMap(raw);
        final ed = text(t['entry_date']);
        final xd = text(t['exit_date']);
        if (ed.isNotEmpty &&
            ed.compareTo(hoverDate) <= 0 &&
            (xd.isEmpty || hoverDate.compareTo(xd) < 0)) {
          activeOpenPuts.add(t);
        }
      }
      for (final raw in openPutsAtEnd) {
        final t = asMap(raw);
        final ed = text(t['entry_date']);
        if (ed.isNotEmpty && ed.compareTo(hoverDate) <= 0) {
          activeOpenPuts.add(t);
        }
      }
    }

    // Aggregate daily execution totals for instant headline scan
    double sumPutBuyUsd = 0.0;
    double sumPutSellUsd = 0.0;
    double sumPutNetPnl = 0.0;
    double sumCtaRotUsd = 0.0;
    double sumCtaResUsd = 0.0;
    bool hasPutSell = false;
    for (final ev in dayEvents) {
      final act = text(ev['action']);
      final amt = (_n(ev['amount_usd']) ?? 0).toDouble();
      if (act == 'PUT_OPEN') {
        sumPutBuyUsd += amt;
      } else if (act == 'PUT_TP' || act == 'PUT_ROLL' || act == 'PUT_CLOSE') {
        sumPutSellUsd += amt;
        sumPutNetPnl += (_n(ev['net_pnl_usd']) ?? 0).toDouble();
        hasPutSell = true;
      } else if (act == 'CTA_ROTATE') {
        sumCtaRotUsd += amt;
      } else if (act == 'CTA_RESTORE') {
        sumCtaResUsd += amt;
      }
    }

    final summaryParts = <String>[];
    if (sumPutBuyUsd > 0) {
      summaryParts.add(
        w('Buy ${_fmtUsd(sumPutBuyUsd)}', '买入 ${_fmtUsd(sumPutBuyUsd)}'),
      );
    }
    if (hasPutSell) {
      summaryParts.add(
        w(
          'Sell ${_fmtUsd(sumPutSellUsd)} (${_fmtUsd(sumPutNetPnl, signed: true)})',
          '卖出 ${_fmtUsd(sumPutSellUsd)}（净 ${_fmtUsd(sumPutNetPnl, signed: true)}）',
        ),
      );
    }
    if (sumCtaRotUsd > 0) {
      summaryParts.add(
        w(
          'CTA->QQQ ${_fmtUsd(sumCtaRotUsd)}',
          '卖CTA买QQQ ${_fmtUsd(sumCtaRotUsd)}',
        ),
      );
    }
    if (sumCtaResUsd > 0) {
      summaryParts.add(
        w(
          'QQQ->CTA ${_fmtUsd(sumCtaResUsd)}',
          '卖QQQ买CTA ${_fmtUsd(sumCtaResUsd)}',
        ),
      );
    }

    final cardW = math.min(
      isCompact ? 268.0 : 386.0,
      math.max(204.0, width - 16.0),
    );
    final preferLeft = mx > width * 0.52;
    final rawLeft = preferLeft ? mx - cardW - 14.0 : mx + 14.0;
    final maxLeft = math.max(4.0, width - cardW - 4.0);
    final minLeft = math.min(padL + 4.0, maxLeft);
    final cardLeft = rawLeft.clamp(minLeft, maxLeft).toDouble();

    final maxShownTrades = isCompact ? 2 : 4;
    final shownTrades = dayEvents.take(maxShownTrades).toList();
    final hiddenTrades = math.max(0, dayEvents.length - shownTrades.length);
    final denseRows = isCompact || dayEvents.length >= 3;

    return Positioned(
      left: cardLeft,
      top: 8.0,
      width: cardW,
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.max(120.0, chartH - 14.0)),
          child: Container(
            key: const ValueKey('crisis-v2-hover-tooltip'),
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 8 : 10,
              vertical: isCompact ? 7 : 8,
            ),
            decoration: BoxDecoration(
              color: const Color(0xF20B1117),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: borderAccent, width: 1.15),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top header: Date · QQQ · VIX/3M · OPRA/BSM source tag
                  Row(
                    children: [
                      Text(
                        hoverDate,
                        style: const TextStyle(
                          color: _fgPrimary,
                          fontSize: 11.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (qqqPx != null)
                        Expanded(
                          child: Text(
                            'QQQ \$${qqqPx.toStringAsFixed(2)}${vr != null ? ' · V/3M ${vr.toStringAsFixed(2)}' : ''}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _sky,
                              fontSize: 10.3,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: (isRealOpra ? _mint : _sky)
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: (isRealOpra ? _mint : _sky)
                                .withValues(alpha: 0.55),
                          ),
                        ),
                        child: Text(
                          isRealOpra
                              ? w('OPRA', 'OPRA实盘')
                              : w('BSM Cal', 'BSM校准'),
                          style: TextStyle(
                            color: isRealOpra ? _mint : _sky,
                            fontSize: 9.2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // Portfolio state readout
                  Text(
                    isZoomed
                        ? 'v3.0 ${_fmtUsd(navV2)} (${_fmtPct(activeSliceV2Ret)}) · QQQ ${_fmtPct(activeSliceQRet)} · Lev ${_fmtNum(lev, dec: 2)}x'
                        : 'v3.0 ${_fmtUsd(navV2)} (DD ${_fmtPct(ddV2, signed: false)}) · QQQ ${_fmtUsd(navQqq)} · Lev ${_fmtNum(lev, dec: 2)}x',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _fgMuted,
                      fontSize: 10.0,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 5),
                    child: Divider(height: 1, color: _borderLine),
                  ),
                  if (dayEvents.isNotEmpty) ...[
                    Text(
                      '${w('${dayEvents.length} Trade${dayEvents.length > 1 ? 's' : ''}', '当日成交 ${dayEvents.length} 笔')}${summaryParts.isNotEmpty ? ' · ${summaryParts.join(' · ')}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _fgPrimary,
                        fontSize: 10.3,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final ev in shownTrades)
                      _buildHoverTradeRow(
                        ev,
                        qqqPx: qqqPx,
                        compact: denseRows,
                      ),
                    if (hiddenTrades > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 1, bottom: 2),
                        child: Text(
                          w(
                            '+$hiddenTrades more trade${hiddenTrades > 1 ? 's' : ''} (click curve to inspect all)',
                            '+$hiddenTrades 笔成交未展开（点击曲线查看全部）',
                          ),
                          style: const TextStyle(
                            color: _amber,
                            fontSize: 9.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ] else if (activeOpenPuts.isNotEmpty) ...[
                    Text(
                      w(
                        'No execution · Active Put Shields (${activeOpenPuts.length})',
                        '当日无买卖成交 · 在手活跃 Put（${activeOpenPuts.length} 笔）',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 10.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final ap in activeOpenPuts.take(isCompact ? 2 : 3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '• [${_sleeveShortTag(text(ap['sleeve']))}] QQQ ${_shortExp(text(ap['exp']))} \$${_fmtStrike(_n(ap['strike']))}P · ${_fmtNum(_n(ap['contracts']), dec: 2)} ${w('cts', '张')} · ${w('Cost', '成本')} ${_fmtUsd(_n(ap['cost_usd']))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _fgPrimary,
                            fontSize: 9.8,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (activeOpenPuts.length > (isCompact ? 2 : 3))
                      Text(
                        w(
                          '+${activeOpenPuts.length - (isCompact ? 2 : 3)} more active puts',
                          '+${activeOpenPuts.length - (isCompact ? 2 : 3)} 笔在手 Put',
                        ),
                        style: const TextStyle(color: _fgMuted, fontSize: 9.4),
                      ),
                  ] else ...[
                    Text(
                      w(
                        'No execution · Quiet holding day (no active Puts)',
                        '当日无买卖成交 · 静默持仓（无在手 Put）',
                      ),
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 10.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Click curve to pin full PIT orderbook & skew replay',
                      '点击曲线锁定当日完整 PIT 盘口与偏度明细',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _slate,
                      fontSize: 9.2,
                      fontWeight: FontWeight.w600,
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

  Widget _buildHoverTradeRow(
    Map<String, dynamic> ev, {
    required double? qqqPx,
    required bool compact,
  }) {
    final act = text(ev['action']);
    final sl = text(ev['sleeve']);
    final reason = text(ev['reason']);
    final amt = _n(ev['amount_usd'])?.toDouble();
    final netPnlVal = _n(ev['net_pnl_usd'])?.toDouble();

    final Color accent;
    final String dirTag;
    if (act == 'PUT_TP') {
      accent = _amber;
      dirTag = w('◆ SELL TP', '◆ 止盈卖出');
    } else if (act == 'PUT_OPEN') {
      accent = sl == 'crisis_m4' ? _lilac : (sl == 'crisis' ? _coral : _sky);
      dirTag = sl == 'base'
          ? w('● BUY PUT', '● 买入开仓')
          : w('▲ BUY PUT', '▲ 买入开仓');
    } else if (act == 'PUT_ROLL') {
      accent = _lilac;
      dirTag = reason == 'roll_30d'
          ? w('▼ 30D SALVAGE', '▼ 30D 残值收回')
          : w('▼ 75D ROLL/SALV', '▼ 75D 滚仓收回');
    } else if (act == 'PUT_CLOSE') {
      accent = _lilac;
      dirTag = reason == 'salvage_30d_slowbear'
          ? w('▼ 30D SALVAGE', '▼ 30D 残值收回')
          : w('▼ SALVAGE SELL', '▼ 残值收回卖出');
    } else if (act == 'CTA_ROTATE') {
      accent = _mint;
      dirTag = w('■ SELL CTA', '■ 卖CTA买QQQ');
    } else {
      accent = _mint;
      dirTag = w('■ BUY CTA', '■ 卖QQQ买CTA');
    }

    String instrument;
    String qtyAmtLine;
    String? subLine;

    if (act == 'CTA_ROTATE') {
      final tr = _n(ev['tranche'])?.toInt() ?? 1;
      final estSh = (qqqPx != null && qqqPx > 0 && amt != null)
          ? amt / qqqPx
          : null;
      instrument = w(
        'Sell $sl -> Buy QQQ (#$tr/5)',
        '卖出 $sl -> 买入 QQQ（第 $tr/5 批）',
      );
      qtyAmtLine = w(
        'Sell ${_fmtUsd(amt)}${estSh != null ? ' · Buy ≈${estSh.toStringAsFixed(1)} sh QQQ @ \$${qqqPx!.toStringAsFixed(2)}' : ''}',
        '卖出金额 ${_fmtUsd(amt)}${estSh != null ? ' · 买入 QQQ ≈${estSh.toStringAsFixed(1)} 股 @ \$${qqqPx!.toStringAsFixed(2)}' : ''}',
      );
      final due = text(ev['restore_due']);
      if (!compact && due.isNotEmpty) {
        subLine = w(
          'QQQ DD ${_fmtPct(_n(ev['qqq_dd_pct']))} · 1Y Restore $due',
          'QQQ 回撤 ${_fmtPct(_n(ev['qqq_dd_pct']))} · 满1年恢复日 $due',
        );
      }
    } else if (act == 'CTA_RESTORE') {
      final lots = _n(ev['lots_matured'])?.toInt() ?? 1;
      final estSh = (qqqPx != null && qqqPx > 0 && amt != null)
          ? amt / qqqPx
          : null;
      instrument = w(
        'Sell QQQ -> Restore $sl',
        '卖出 QQQ -> 恢复买入 $sl',
      );
      qtyAmtLine = w(
        'Buy ${_fmtUsd(amt)}${estSh != null ? ' · Sell ≈${estSh.toStringAsFixed(1)} sh QQQ @ \$${qqqPx!.toStringAsFixed(2)}' : ''} ($lots lot)',
        '买回金额 ${_fmtUsd(amt)}${estSh != null ? ' · 卖出 QQQ ≈${estSh.toStringAsFixed(1)} 股 @ \$${qqqPx!.toStringAsFixed(2)}' : ''}（$lots 批到期）',
      );
    } else {
      final exp = _shortExp(text(ev['exp']));
      final strike = _fmtStrike(_n(ev['strike']));
      final dte = _n(ev['dte'])?.round();
      final cts = _n(ev['contracts'])?.toDouble();
      final fill = _n(ev['fill'])?.toDouble();
      final lotPct = _n(ev['lot_pct'])?.toDouble();
      final ctsStr = cts != null ? cts.toStringAsFixed(2) : '--';
      final fillStr = fill != null ? '\$${fill.toStringAsFixed(2)}' : '--';
      final putSuffix = compact ? 'P' : ' Put';
      instrument =
          'QQQ $exp \$$strike$putSuffix${dte != null ? ' (${dte}D)' : ''} · ${_sleeveShortTag(sl)}';
      if (act == 'PUT_OPEN') {
        qtyAmtLine = w(
          'Qty $ctsStr cts @ $fillStr · Buy ${_fmtUsd(amt)}${lotPct != null ? ' (${lotPct.toStringAsFixed(2)}%/lot)' : ''}',
          '数量 $ctsStr 张 @ $fillStr · 买入金额 ${_fmtUsd(amt)}${lotPct != null ? '（占1手 ${lotPct.toStringAsFixed(2)}%）' : ''}',
        );
      } else {
        final netPnl = _n(ev['net_pnl_usd'])?.toDouble();
        final roi = _n(ev['roi_mult'])?.toDouble();
        final costUsd = _n(ev['cost_usd'])?.toDouble();
        final entryFill = _n(ev['entry_fill'])?.toDouble();
        final reason = text(ev['reason']);
        final pnlTag = netPnl != null
            ? '${_fmtUsd(netPnl, signed: true)}${roi != null ? ' / ${roi.toStringAsFixed(2)}x' : ''}'
            : '';
        qtyAmtLine = w(
          'Qty $ctsStr cts @ $fillStr · Sell ${_fmtUsd(amt)}${pnlTag.isNotEmpty ? ' ($pnlTag)' : ''}',
          '数量 $ctsStr 张 @ $fillStr · 卖出金额 ${_fmtUsd(amt)}${pnlTag.isNotEmpty ? '（$pnlTag）' : ''}',
        );
        if (!compact) {
          subLine = w(
            'Cost ${_fmtUsd(costUsd)}${entryFill != null ? ' (@ \$${entryFill.toStringAsFixed(2)})' : ''} · ${_pitReasonLabel(reason)}',
            '原买成本 ${_fmtUsd(costUsd)}${entryFill != null ? '（@ \$${entryFill.toStringAsFixed(2)}）' : ''} · ${_pitReasonLabel(reason)}',
          );
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4.5),
      decoration: BoxDecoration(
        color: _bgInset.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                ),
                child: Text(
                  dirTag,
                  style: TextStyle(
                    color: accent,
                    fontSize: 9.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  instrument,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _fgPrimary,
                    fontSize: 10.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2.5),
          Text(
            qtyAmtLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: act == 'PUT_TP'
                  ? _amber
                  : ((act == 'PUT_ROLL' || act == 'PUT_CLOSE') &&
                            (netPnlVal ?? 0) > 0
                        ? _mint
                        : _fgPrimary),
              fontSize: 10.0,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          if (subLine != null && subLine.isNotEmpty) ...[
            const SizedBox(height: 1.5),
            Text(
              subLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _fgMuted,
                fontSize: 9.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRangeBrushBar({
    required List<dynamic> series,
    required int sIdx,
    required int eIdx,
    required bool isZoomed,
    required double sliceV2Ret,
    required double sliceQRet,
    required double sliceV2Mdd,
    required double sliceQMdd,
    required bool isCompact,
    String opraCutoffDate = '2025-12-15',
  }) {
    final maxIdx = series.length - 1;
    final minSpan = math.min(15, maxIdx);
    final firstDate = text(asMap(series.first)['date']);
    final lastDate = text(asMap(series.last)['date']);
    final selStartDate = text(asMap(series[sIdx])['date']);
    final selEndDate = text(asMap(series[eIdx])['date']);
    final selDays = eIdx - sIdx + 1;

    final presets = <Map<String, dynamic>>[
      {'id': 'all', 'en': 'All', 'zh': '全部'},
      if (series.length > 260) {'id': '1y', 'en': '1Y', 'zh': '近1年', 'days': 252},
      if (series.length > 760) {'id': '3y', 'en': '3Y', 'zh': '近3年', 'days': 756},
      {'id': '2015', 'en': '2015 FX', 'zh': '2015 汇改', 's': '2015-07-01', 'e': '2016-05-31'},
      {'id': '2018', 'en': '2018 QT', 'zh': '2018 缩表', 's': '2018-01-02', 'e': '2019-05-31'},
      {'id': '2020', 'en': '2020 COVID', 'zh': '2020 熔断', 's': '2020-01-02', 'e': '2020-09-30'},
      {'id': '2022', 'en': '2022 Bear', 'zh': '2022 慢熊', 's': '2021-11-01', 'e': '2023-06-30'},
      {'id': '2024', 'en': '2024 Yen', 'zh': '2024 日元', 's': '2024-06-01', 'e': '2024-11-30'},
      {'id': '2025', 'en': '2025 Tariff', 'zh': '2025 关税', 's': '2024-12-15', 'e': '2025-07-31'},
      {'id': '2026', 'en': '2026 Sim Ext', 'zh': '2026 模拟延展', 's': '2025-12-16', 'e': '2026-12-31'},
    ].where((p) {
      final s = p['s'] as String?;
      final e = p['e'] as String?;
      if (s == null || e == null) return true;
      return e.compareTo(firstDate) > 0 && s.compareTo(lastDate) < 0;
    }).toList();

    Widget rangeChip(String id, String label, VoidCallback onTap, {bool active = false, Color? accent}) {
      final col = accent ?? _mint;
      return InkWell(
        key: ValueKey('crisis-v2-range-preset-$id'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
          decoration: BoxDecoration(
            color: active ? col.withValues(alpha: 0.18) : _bgInset,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? col : _borderLine,
              width: active ? 1.1 : 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? col : _fgMuted,
              fontSize: 10.6,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('crisis-v2-range-brush'),
      padding: EdgeInsets.fromLTRB(isCompact ? 8 : 10, 8, isCompact ? 8 : 10, 8),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 5,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Time Range:', '时间区间：'),
                    style: const TextStyle(
                      color: _fgMuted,
                      fontSize: 10.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  for (final p in presets)
                    rangeChip(
                      p['id'] as String,
                      w(p['en'] as String, p['zh'] as String),
                      () => _applyQuickRange(
                        series,
                        p['id'] as String,
                        startDate: p['s'] as String?,
                        endDate: p['e'] as String?,
                        trailingDays: p['days'] as int?,
                      ),
                      active: activeQuickRange == p['id'],
                    ),
                  if (isZoomed)
                    rangeChip(
                      'rebase_toggle',
                      rebaseZoomedSlice
                          ? w('Base = 100', '起点归一=100')
                          : w('Abs NAV (\$)', '绝对净值(\$)'),
                      () => setState(() => rebaseZoomedSlice = !rebaseZoomedSlice),
                      active: true,
                      accent: _sky,
                    ),
                ],
              ),
              Text(
                '$selStartDate -> $selEndDate ($selDays${w('D', '交易日')})  ·  v3.0 ${_fmtPct(sliceV2Ret)} (MDD ${_fmtPct(sliceV2Mdd, signed: false)})  vs  QQQ ${_fmtPct(sliceQRet)} (MDD ${_fmtPct(sliceQMdd, signed: false)})',
                style: TextStyle(
                  color: isZoomed ? _mint : _fgMuted,
                  fontSize: 10.8,
                  fontWeight: isZoomed ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (_, c) {
              final width = c.maxWidth;
              const padL = 44.0;
              const padR = 4.0;
              final plotW = math.max(1.0, width - padL - padR);
              final startX = padL + (sIdx / maxIdx) * plotW;
              final endX = padL + (eIdx / maxIdx) * plotW;

              int idxFromX(double dx) {
                final frac = ((dx - padL) / plotW).clamp(0.0, 1.0);
                return (frac * maxIdx).round();
              }

              String hitMode(double dx) {
                const grabTol = 20.0;
                final dL = (dx - startX).abs();
                final dR = (dx - endX).abs();
                if (dL <= grabTol && dL <= dR) return 'left';
                if (dR <= grabTol) return 'right';
                if (dx > startX && dx < endX) {
                  return isZoomed ? 'move' : 'brush';
                }
                return 'jump';
              }

              return MouseRegion(
                cursor: _brushCursor,
                onHover: (ev) {
                  final mode = hitMode(ev.localPosition.dx);
                  final nextCur = (mode == 'left' || mode == 'right')
                      ? SystemMouseCursors.resizeLeftRight
                      : (mode == 'move'
                            ? SystemMouseCursors.grab
                            : (mode == 'brush'
                                  ? SystemMouseCursors.precise
                                  : SystemMouseCursors.click));
                  if (nextCur != _brushCursor) {
                    setState(() => _brushCursor = nextCur);
                  }
                },
                child: GestureDetector(
                  key: const ValueKey('crisis-v2-range-track'),
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () => _applyQuickRange(series, 'all'),
                  onTapUp: (details) {
                    final dx = details.localPosition.dx;
                    final mode = hitMode(dx);
                    if (mode == 'jump' && isZoomed) {
                      final clicked = idxFromX(dx);
                      final span = eIdx - sIdx;
                      final halfSpan = (span / 2).floor();
                      final ns = (clicked - halfSpan).clamp(
                        0,
                        math.max(0, maxIdx - span),
                      ).toInt();
                      final ne = (ns + span).clamp(
                        math.min(maxIdx, ns + minSpan),
                        maxIdx,
                      ).toInt();
                      setState(() {
                        rangeStartIdx = ns;
                        rangeEndIdx = ne;
                        activeQuickRange = 'custom';
                        hoverIndex = -1;
                      });
                    }
                  },
                  onHorizontalDragStart: (details) {
                    final dx = details.localPosition.dx;
                    final mode = hitMode(dx);
                    _brushDragMode = mode == 'jump'
                        ? ((dx < startX) ? 'left' : 'right')
                        : mode;
                    _brushDragStartDx = dx;
                    _brushDragOrigStart = _brushDragMode == 'brush'
                        ? idxFromX(dx)
                        : sIdx;
                    _brushDragOrigEnd = eIdx;
                  },
                  onHorizontalDragUpdate: (details) {
                    final dx = details.localPosition.dx;
                    final deltaIdx =
                        (((dx - _brushDragStartDx) / plotW) * maxIdx).round();
                    int ns = sIdx;
                    int ne = eIdx;
                    if (_brushDragMode == 'left') {
                      ns = (_brushDragOrigStart + deltaIdx).clamp(
                        0,
                        math.max(0, _brushDragOrigEnd - minSpan),
                      ).toInt();
                      ne = _brushDragOrigEnd;
                    } else if (_brushDragMode == 'right') {
                      ns = _brushDragOrigStart;
                      ne = (_brushDragOrigEnd + deltaIdx).clamp(
                        math.min(maxIdx, _brushDragOrigStart + minSpan),
                        maxIdx,
                      ).toInt();
                    } else if (_brushDragMode == 'move') {
                      final span = _brushDragOrigEnd - _brushDragOrigStart;
                      ns = (_brushDragOrigStart + deltaIdx).clamp(
                        0,
                        math.max(0, maxIdx - span),
                      ).toInt();
                      ne = ns + span;
                    } else if (_brushDragMode == 'brush') {
                      final anchor = _brushDragOrigStart;
                      final cur = idxFromX(dx);
                      ns = math.min(anchor, cur);
                      ne = math.max(anchor, cur);
                      if (ne - ns < minSpan) {
                        if (cur >= anchor) {
                          ne = math.min(maxIdx, ns + minSpan);
                        } else {
                          ns = math.max(0, ne - minSpan);
                        }
                      }
                    }
                    if (ns != sIdx || ne != eIdx) {
                      setState(() {
                        rangeStartIdx = ns;
                        rangeEndIdx = ne;
                        activeQuickRange = (ns == 0 && ne == maxIdx)
                            ? 'all'
                            : 'custom';
                        hoverIndex = -1;
                      });
                    }
                  },
                  onHorizontalDragEnd: (_) {
                    _brushDragMode = '';
                  },
                  child: SizedBox(
                    height: 46,
                    width: width,
                    child: CustomPaint(
                      painter: _CrisisRangeBrushPainter(
                        series: series,
                        startIdx: sIdx,
                        endIdx: eIdx,
                        padL: padL,
                        padR: padR,
                        hintLabel: w('ZOOM', '区间'),
                        opraCutoffDate: opraCutoffDate,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPitOperationsInspector(List<dynamic> putLedger, bool isCompact) {
    if (pinnedPitDate == null) {
      return Container(
        key: const ValueKey('crisis-v2-pit-prompt'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _bgInset,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: _borderLine),
        ),
        child: Row(
          children: [
            const Icon(Icons.touch_app_outlined, color: _sky, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w(
                  'Click any date on the curve above or any "◆ Put TP" badge to inspect exact PIT operations, Put take-profit fills (IBKR Mid ± 35% HS), real OPRA Skew Ratio, and 1-Contract Put / 1-Lot (100sh) QQQ price ratio.',
                  '点击上方曲线任意日期或任意「◆ Put 止盈」徽章，即可原地展开当日 PIT 历史操作、Put 止盈（IBKR Mid ± 35% 半价差限价成交）、真实 OPRA Skew Ratio 与「一张 Put 占比一手 QQQ 价格比例」。',
                ),
                style: const TextStyle(color: _fgMuted, fontSize: 11.5),
              ),
            ),
          ],
        ),
      );
    }

    final snap = asMap(pitSnapshot);
    final cockpit = asMap(snap['live_cockpit']);
    final market = asMap(cockpit['market']);
    final qqqClose = _n(market['qqq_close']);
    final hist = asMap(snap['pit_history']);
    final tpMic = asMap(cockpit['tp_and_microstructure']);
    final op = asMap(tpMic['option_pricing']);
    final sk = asMap(op['skew_ratio']);
    final p125 = asMap(op['put_125d_15otm']);
    final p90 = asMap(op['put_90d_15otm'] ?? op['put_90d_10otm']);
    final navSnap = asMap(hist['nav_snapshot']);
    final events = asList(hist['events_on_date']);
    final activePuts = asList(hist['active_puts_on_date']);
    final cumStats = asMap(hist['cum_put_stats_to_date']);
    final metrics = asMap(tpMic['metrics']);
    final isReal = text(op['quote_source']) == 'real_opra';

    final prevDay = text(snap['prev_date']);
    final nextDay = text(snap['next_date']);
    final prevEvt = text(hist['prev_event_date']);
    final nextEvt = text(hist['next_event_date']);
    final prevTp = text(hist['prev_tp_date']);
    final nextTp = text(hist['next_tp_date']);

    return Container(
      key: const ValueKey('crisis-v2-pit-inspector'),
      padding: EdgeInsets.all(isCompact ? 11 : 14),
      decoration: BoxDecoration(
        color: _bgObsidian,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _amber.withValues(alpha: 0.65), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header + Quick Navigation Controls
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _pillBadge('PIT · $pinnedPitDate', _amber),
                  _pillBadge(
                    isReal
                        ? w('REAL MIT OPRA 16:00 ET', '真实 OPRA 盘口')
                        : w('BSM LIVE EST', 'BSM 盘口估算'),
                    isReal ? _mint : _sky,
                  ),
                  if (loadingPit)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _amber,
                      ),
                    ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (prevDay.isNotEmpty)
                    _miniBtn(
                      w('<- Prev Day', '← 上一日'),
                      () => unawaited(_loadPitDate(prevDay)),
                    ),
                  if (nextDay.isNotEmpty)
                    _miniBtn(
                      w('Next Day ->', '下一日 →'),
                      () => unawaited(_loadPitDate(nextDay)),
                    ),
                  if (prevEvt.isNotEmpty)
                    _miniBtn(
                      w('Prev Trade', '上一操作'),
                      () => unawaited(_loadPitDate(prevEvt)),
                      accent: _sky,
                    ),
                  if (nextEvt.isNotEmpty)
                    _miniBtn(
                      w('Next Trade', '下一操作'),
                      () => unawaited(_loadPitDate(nextEvt)),
                      accent: _sky,
                    ),
                  if (prevTp.isNotEmpty)
                    _miniBtn(
                      w('◆ Prev TP', '◆ 上一止盈'),
                      () => unawaited(_loadPitDate(prevTp)),
                      accent: _amber,
                    ),
                  if (nextTp.isNotEmpty)
                    _miniBtn(
                      w('◆ Next TP', '◆ 下一止盈'),
                      () => unawaited(_loadPitDate(nextTp)),
                      accent: _amber,
                    ),
                  _miniBtn(
                    w('Back to Live', '回今日实盘'),
                    _clearPitReplay,
                    accent: _coral,
                  ),
                ],
              ),
            ],
          ),

          if (pitError != null && snap.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${w('Failed to load PIT snapshot', 'PIT 数据加载失败')}: $pitError',
              style: const TextStyle(color: _coral, fontSize: 11.2),
            ),
          ],
          if (snap.isNotEmpty) ...[
            const SizedBox(height: 10),
            // 4-Card Real OPRA Microstructure & 1-Put/1-Lot-QQQ Ratio Strip
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _metricBox(
                  w('OPRA Skew Ratio (125D)', 'OPRA 偏度比 Skew Ratio'),
                  _n(sk['opra_iv_20_10']) != null
                      ? '${_n(sk['opra_iv_20_10'])!.toStringAsFixed(3)}x'
                      : '--',
                  (_n(sk['opra_iv_20_10']) ?? 0) >= 1.22 ? _amber : _mint,
                  sub:
                      'IV(-15/ATM) ${_n(sk['opra_iv_15_atm']) != null ? '${_n(sk['opra_iv_15_atm'])!.toStringAsFixed(3)}x' : '--'} · CBOE SKEW ${_fmtNum(_n(sk['cboe_skew_spot']), dec: 1)}',
                ),
                _metricBox(
                  w(
                    '1 Put / 100 QQQ · 125D -15% (IBKR Limit)',
                    '1张 Put / 1手 QQQ · 125D -15%（限价）',
                  ),
                  _n(p125['put_to_lot_pct']) != null
                      ? '${_n(p125['put_to_lot_pct'])!.toStringAsFixed(2)}%'
                      : '--',
                  (_n(p125['put_to_lot_pct']) ?? 99) <= 1.25
                      ? _mint
                      : ((_n(p125['put_to_lot_pct']) ?? 0) >= 2.2
                            ? _coral
                            : _sky),
                  sub:
                      '${w('1 ct', '1张')} ${_fmtUsd(_n(p125['one_put_usd']))} / ${w('100 QQQ', '1手QQQ')} ${_fmtUsd(_n(p125['one_lot_qqq_usd']))} · Bid ${_fmtNum(_n(p125['bid']))}/Ask ${_fmtNum(_n(p125['ask']))} · HS ${_fmtNum(_n(p125['half_spread_pct']), dec: 1)}%',
                ),
                _metricBox(
                  w(
                    '1 Put / 100 QQQ · M4 90D -15% (IBKR Limit)',
                    '1张 Put / 1手 QQQ · M4 90D -15%（限价）',
                  ),
                  _n(p90['put_to_lot_pct']) != null
                      ? '${_n(p90['put_to_lot_pct'])!.toStringAsFixed(2)}%'
                      : '--',
                  _lilac,
                  sub:
                      '${w('1 ct', '1张')} ${_fmtUsd(_n(p90['one_put_usd']))} / ${w('100 QQQ', '1手QQQ')} ${_fmtUsd(_n(p90['one_lot_qqq_usd']))} · K \$${_fmtNum(_n(p90['strike']), dec: 0)} · IV ${_fmtNum(_n(p90['iv_pct']), dec: 1)}%',
                ),
                _metricBox(
                  w('PIT Portfolio & Vol State', 'PIT 组合净值与波动率'),
                  navSnap.isNotEmpty
                      ? '${_fmtUsd(_n(navSnap['nav_v2']))} (${_fmtPct(_n(navSnap['dd_v2']), signed: false)})'
                      : 'QQQ ${_fmtUsd(qqqClose, dec: 2)}',
                  _fgPrimary,
                  sub:
                      'QQQ \$${_fmtNum(qqqClose, dec: 2)} · VIX ${_fmtNum(_n(metrics['vix']), dec: 1)} · VIX/3M ${_fmtNum(_n(metrics['vix_ratio']), dec: 3)} · Lev ${_fmtNum(_n(navSnap['lev']), dec: 3)}x',
                ),
              ],
            ),

            const SizedBox(height: 10),
            // Events Executed ON This PIT Date
            Text(
              w(
                'PIT Operations Executed on $pinnedPitDate (${events.length}) · Cumulative Realized Put PnL: ${_fmtUsd(_n(cumStats['realized_net_pnl_usd']), signed: true)} (${cumStats['tp_count'] ?? 0} TPs)',
                '$pinnedPitDate 当日 PIT 实盘操作明细（${events.length} 笔）· 截至当日累计 Put 已实现净盈亏 ${_fmtUsd(_n(cumStats['realized_net_pnl_usd']), signed: true)}（已止盈 ${cumStats['tp_count'] ?? 0} 次）',
              ),
              style: const TextStyle(
                color: _fgPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            if (events.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _bgInset,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _borderLine),
                ),
                child: Text(
                  w(
                    'No Put or Dual-CTA execution occurred on $pinnedPitDate (quiet holding day). Use "Prev Trade" / "Next Trade" or "◆ Put TP" pills above to inspect execution days.',
                    '$pinnedPitDate 当日无开平仓或轮动成交（静默持仓日）。可点右上角「上一操作 / 下一操作」或「◆ Put 止盈」快速跳转。',
                  ),
                  style: const TextStyle(color: _fgMuted, fontSize: 11.2),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final rawEv in events)
                    _buildPitEventCard(asMap(rawEv)),
                ],
              ),

            // Active Open Put Shields Held on This PIT Date
            if (activePuts.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                w(
                  'Active Open Put Shields Held on $pinnedPitDate (${activePuts.length})',
                  '$pinnedPitDate 当日在手活跃 Put 防御仓位（${activePuts.length} 笔）',
                ),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 11.8,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final rawAp in activePuts)
                    _buildActivePutChip(asMap(rawAp)),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPitEventCard(Map<String, dynamic> ev) {
    final action = text(ev['action']);
    final sl = text(ev['sleeve']);
    final isTp = action == 'PUT_TP';
    final isOpen = action == 'PUT_OPEN';
    final isCta = action == 'CTA_ROTATE' || action == 'CTA_RESTORE';

    final accent = isTp
        ? _amber
        : (isCta
              ? _mint
              : (isOpen
                    ? (sl == 'crisis_m4'
                          ? _lilac
                          : (sl == 'crisis' ? _coral : _sky))
                    : _fgMuted));

    final isSlowBear90 =
        (_n(ev['target_dte'])?.toInt() == 90) ||
        (_n(ev['roll_dte'])?.toInt() == 30);
    final slLabel = sl == 'crisis_m4'
        ? w('M4 Slow-Bear 90D -15%', 'M4 慢熊 90D -15%')
        : (sl == 'crisis'
              ? (isSlowBear90
                    ? w('M7G Slow-Bear 90D->30D', 'M7G 慢熊 90D->30D')
                    : w('M7G Crisis 125D -15%', 'M7G 危机盾 125D -15%'))
              : (sl == 'base'
                    ? (isSlowBear90
                          ? w('B020 Slow-Bear 0.20% 90D->30D', 'B020 慢熊 0.20% 90D->30D')
                          : w('B020 Base 0.20% 125D', 'B020 常态 0.20% 基底盾'))
                    : sl));

    final actionTag = switch (action) {
      'PUT_TP' => w('◆ PUT TAKE-PROFIT', '◆ PUT 止盈兑现'),
      'PUT_OPEN' => w('▲ PUT ENTRY (IBKR LMT)', '▲ PUT 建仓（IBKR 限价）'),
      'PUT_ROLL' => w('↻ HARD ROLL EXIT', '↻ 强制早滚平旧'),
      'PUT_CLOSE' => w('× PUT SALVAGE / CLOSE', '× Put 残值回收 / 平仓'),
      'CTA_ROTATE' => w('■ CTA -> QQQ ROTATION', '■ 卖盈利 CTA 抄底 QQQ'),
      'CTA_RESTORE' => w('■ 1Y LTCG CTA RESTORE', '■ 满1年 LTCG 恢复双CTA'),
      _ => action,
    };

    if (isCta) {
      final isRot = action == 'CTA_ROTATE';
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _bgInset,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.55)),
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _pillBadge(actionTag, accent),
            Text(
              isRot
                  ? '$sl #${ev['tranche']}/5 · ${_fmtUsd(_n(ev['sold_usd']))} -> QQQ · DD ${_fmtPct(_n(ev['qqq_dd_pct']))} · ${w('1Y Restore', '恢复日')} ${text(ev['restore_due'])}'
                  : '$sl · ${_fmtUsd(_n(ev['restored_usd']))} (${ev['lots_matured']} ${w('lots matured', '批满1年恢复')})',
              style: const TextStyle(
                color: _fgPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    final roi = _n(ev['roi_mult']);
    final netPnl = _n(ev['net_pnl_usd']);
    final entryLot = _n(ev['entry_lot_pct']);
    final exitLot = _n(ev['exit_lot_pct']);
    final jumpDate = isOpen ? text(ev['eventual_exit_date']) : text(ev['entry_date']);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isTp ? _amber.withValues(alpha: 0.08) : _bgInset,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: accent.withValues(alpha: isTp ? 0.85 : 0.45),
          width: isTp ? 1.2 : 0.9,
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
              Wrap(
                spacing: 7,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _pillBadge(actionTag, accent),
                  _pillBadge(slLabel, _fgMuted),
                  if (text(ev['quote_source']) == 'BSM_SIM_2026')
                    _pillBadge(w('OPRA-CAL BSM', 'OPRA校准 BSM'), _sky),
                  Text(
                    'Strike \$${_fmtNum(_n(ev['strike']), dec: 0)} · Exp ${text(ev['exp'])}',
                    style: const TextStyle(
                      color: _fgPrimary,
                      fontSize: 11.8,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              if (!isOpen && roi != null)
                Text(
                  '${_fmtUsd(netPnl, signed: true)}  (${roi.toStringAsFixed(2)}x)',
                  style: TextStyle(
                    color: (netPnl ?? 0) >= 0 ? _mint : _coral,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          if (isOpen)
            Text(
              '${w('IBKR Limit Buy', 'IBKR 限价买入')}: \$${_fmtNum(_n(ev['entry_fill']), dec: 3)} '
              '(Bid ${_fmtNum(_n(ev['entry_bid']))} / Ask ${_fmtNum(_n(ev['entry_ask']))} / Mid ${_fmtNum(_n(ev['entry_mid']))} · HS ${_fmtNum(_n(ev['entry_hs_pct']), dec: 1)}%)  ·  '
              '${w('Cost', '投入')} ${_fmtUsd(_n(ev['cost_usd']))} (${_fmtNum(_n(ev['contracts']), dec: 2)} ${w('cts', '张')})  ·  '
              '${w('1 Put / 100 QQQ', '1张占1手QQQ')}: ${entryLot != null ? '${entryLot.toStringAsFixed(2)}%' : '--'}  ·  '
              'Skew(-20/-10): ${_n(ev['entry_sk20_10']) != null ? '${_n(ev['entry_sk20_10'])!.toStringAsFixed(3)}x' : '--'}',
              style: const TextStyle(
                color: _fgMuted,
                fontSize: 11,
                height: 1.4,
              ),
            )
          else
            Text(
              '${w('Fill', 'IBKR 限价')}: \$${_fmtNum(_n(ev['entry_fill']), dec: 3)} -> \$${_fmtNum(_n(ev['exit_fill']), dec: 3)} '
              '(Exit Bid ${_fmtNum(_n(ev['exit_bid']))} / Ask ${_fmtNum(_n(ev['exit_ask']))} · DTE ${ev['entry_dte']}->${ev['exit_dte']}D)  ·  '
              '${_fmtUsd(_n(ev['cost_usd']))} -> ${_fmtUsd(_n(ev['exit_usd']))}  ·  '
              '${w('1 Put / 100 QQQ', '1张占1手QQQ')}: ${entryLot != null ? '${entryLot.toStringAsFixed(2)}%' : '--'} -> ${exitLot != null ? '${exitLot.toStringAsFixed(2)}%' : '--'}  ·  '
              '${_pitReasonLabel(text(ev['reason']))}',
              style: const TextStyle(
                color: _fgMuted,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          if (jumpDate.isNotEmpty) ...[
            const SizedBox(height: 5),
            InkWell(
              onTap: () => unawaited(_loadPitDate(jumpDate)),
              child: Text(
                isOpen
                    ? '→ ${w('Jump to exit/TP date', '点击跳转平仓/止盈日')}: $jumpDate (${_n(ev['eventual_roi_mult'])?.toStringAsFixed(2) ?? '--'}x · ${_pitReasonLabel(text(ev['eventual_reason']))})'
                    : '← ${w('Jump to entry date', '点击回看建仓日')}: $jumpDate (QQQ \$${_fmtNum(_n(ev['entry_spot']), dec: 2)})',
                style: const TextStyle(
                  color: _sky,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActivePutChip(Map<String, dynamic> ap) {
    final sl = text(ap['sleeve']);
    final col = sl == 'crisis_m4'
        ? _lilac
        : (sl == 'crisis' ? _amber : _sky);
    final slName = sl == 'crisis_m4'
        ? 'M4 90D -15%'
        : (sl == 'crisis' ? 'M7G 125D -15%' : 'B020 0.20%');
    final exitD = text(ap['eventual_exit_date']);
    final isTpExit = text(ap['eventual_reason']).contains('tp_');
    final lot = _n(ap['entry_lot_pct']);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: exitD.isNotEmpty ? () => unawaited(_loadPitDate(exitD)) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _bgInset,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: col.withValues(alpha: 0.5)),
        ),
        child: Text(
          '$slName · K \$${_fmtNum(_n(ap['strike']), dec: 0)} · ${w('Rem', '余')} ${ap['rem_dte']}D · '
          '${w('Entry', '建仓')} ${text(ap['entry_date'])} (${lot != null ? '${lot.toStringAsFixed(2)}% /100QQQ' : '--'}) · '
          '${_fmtUsd(_n(ap['cost_usd']))}'
          '${exitD.isNotEmpty ? '  →  ${isTpExit ? '◆ TP ' : ''}$exitD (${_n(ap['eventual_roi_mult'])?.toStringAsFixed(2) ?? '--'}x)' : ''}',
          style: TextStyle(
            color: isTpExit ? _amber : _fgPrimary,
            fontSize: 10.8,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _legendMarker(String glyph, String label, Color col) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          glyph,
          style: TextStyle(color: col, fontSize: 10.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: _fgMuted, fontSize: 11)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // TABLES & COMPACT UI PRIMITIVES
  // ---------------------------------------------------------------------------
  Widget _kpiHeaderRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _borderLine)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              w('Strategy / Basis (\$100K Start)', '策略口径（\$100K 起步）'),
              style: _thStyle,
            ),
          ),
          Expanded(flex: 2, child: Text(w('End NAV', '终值'), style: _thStyle)),
          Expanded(flex: 2, child: Text('CAGR', style: _thStyle)),
          Expanded(flex: 2, child: Text(w('Max DD', '最大回撤'), style: _thStyle)),
          Expanded(flex: 1, child: Text('Calmar', style: _thStyle)),
          Expanded(flex: 1, child: Text('Sharpe', style: _thStyle)),
          Expanded(flex: 1, child: Text('Sortino', style: _thStyle)),
          Expanded(
            flex: 2,
            child: Text(w('Peak Lev', '峰值杠杆'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('Put Net / Mult', 'Put 净盈亏 / 倍数'), style: _thStyle),
          ),
        ],
      ),
    );
  }

  Widget _kpiDataRow(
    String label,
    Map<String, dynamic> k, {
    bool highlight = false,
    bool isBench = false,
  }) {
    final textCol = highlight ? _mint : (isBench ? _sky : _fgPrimary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: highlight ? _mint.withValues(alpha: 0.07) : Colors.transparent,
        border: const Border(bottom: BorderSide(color: _borderLine, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: TextStyle(
                color: textCol,
                fontSize: 12,
                fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _fmtUsd(_n(k['end_nav'])),
              style: TextStyle(
                color: textCol,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _fmtPct(_n(k['cagr_pct']), signed: false),
              style: TextStyle(
                color: textCol,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _fmtPct(_n(k['max_dd_pct']), signed: false),
              style: TextStyle(
                color: highlight ? _mint : _coral,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              _fmtNum(_n(k['calmar']), dec: 3),
              style: TextStyle(color: textCol, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              _fmtNum(_n(k['sharpe']), dec: 3),
              style: TextStyle(color: _fgPrimary, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              _fmtNum(_n(k['sortino']), dec: 3),
              style: TextStyle(color: _fgPrimary, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              isBench
                  ? '1.000x'
                  : '${_fmtNum(_n(k['peak_gross_leverage']), dec: 3)}x',
              style: TextStyle(
                color: isBench ? _fgMuted : _mint,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              isBench
                  ? '--'
                  : '${_fmtUsd(_n(k['put_net_pnl_usd']), signed: true)} (${_fmtNum(_n(k['put_payoff_mult']), dec: 2)}x)',
              style: TextStyle(
                color: (_n(k['put_net_pnl_usd']) ?? 0) >= 0 ? _mint : _coral,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _crisisHeaderRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _borderLine)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(w('Crisis Episode', '历史危机窗口'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('Dates', '区间'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('v3.0 MDD', 'v3.0 最大回撤'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('QQQ MDD', 'QQQ 最大回撤'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('Cushion', '回撤减震'), style: _thStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(w('Put TP / M4 / CTA', '止盈 / M4 / 轮动'), style: _thStyle),
          ),
        ],
      ),
    );
  }

  Widget _crisisDataRow(Map<String, dynamic> c) {
    final cushion = _n(c['mdd_cushion_pp']) ?? 0;
    final epStart = text(c['start_date']);
    final epEnd = text(c['end_date']);
    return InkWell(
      onTap: (epStart.isNotEmpty && epEnd.isNotEmpty)
          ? () {
              final series = asList(
                asMap(asMap(data?['backtest'])['active_window'])['daily_series'],
              );
              _applyQuickRange(
                series,
                'ep_$epStart',
                startDate: epStart,
                endDate: epEnd,
              );
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _borderLine, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                w(text(c['name_en']), text(c['name_zh'])),
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '$epStart .. ${epEnd.length >= 5 ? epEnd.substring(5) : epEnd}',
                style: const TextStyle(color: _sky, fontSize: 11),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _fmtPct(_n(c['v2_mdd_pct']), signed: false),
                style: const TextStyle(
                  color: _mint,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _fmtPct(_n(c['qqq_mdd_pct']), signed: false),
                style: const TextStyle(color: _coral, fontSize: 12),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '${cushion >= 0 ? '+' : ''}${cushion.toStringAsFixed(2)}pp',
                style: TextStyle(
                  color: cushion >= 0 ? _mint : _amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                'TP ${c['put_tp_count']} · M4 ${c['m4_trades']} · CTA ${c['cta_rot_slices']}',
                style: const TextStyle(color: _fgMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _horizontalTable({required double minWidth, required Widget child}) {
    return LayoutBuilder(
      builder: (_, c) {
        final wFinite = c.maxWidth.isFinite
            ? math.max(c.maxWidth, minWidth)
            : minWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: wFinite, child: child),
        );
      },
    );
  }

  Widget _buildPutLedgerTable(List<dynamic> rows, bool isCompact) {
    if (rows.isEmpty) {
      return Text(
        w('No trades match this filter.', '当前筛选下无交易记录。'),
        style: const TextStyle(color: _fgMuted, fontSize: 12),
      );
    }
    return _horizontalTable(
      minWidth: isCompact ? 760 : 860,
      child: Container(
          decoration: BoxDecoration(
            color: _bgObsidian,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _borderLine),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _borderLine)),
                ),
                child: Row(
                  children: [
                    Expanded(flex: 2, child: Text(w('Sleeve', '账本'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Entry', '建仓日'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Exit', '平仓日'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Strike / DTE', '行权价 / DTE'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Cost -> Exit', '成本 -> 回收'), style: _thStyle)),
                    Expanded(flex: 1, child: Text(w('ROI', '倍数'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Reason', '出场原因'), style: _thStyle)),
                  ],
                ),
              ),
              for (final raw in rows.reversed.take(50))
                Builder(
                  builder: (_) {
                    final r = asMap(raw);
                    final sl = text(r['sleeve']);
                    final slCol = sl == 'crisis_m4'
                        ? _lilac
                        : (sl == 'crisis' ? _amber : _sky);
                    final isSimBsm = text(r['quote_source']) == 'BSM_SIM_2026';
                    final isSb90Row =
                        (_n(r['target_dte'])?.toInt() == 90) ||
                        (_n(r['roll_dte'])?.toInt() == 30);
                    final slNameBase = sl == 'crisis_m4'
                        ? w('M4 90D -15%', 'M4 90D -15%')
                        : (sl == 'crisis'
                              ? (isSb90Row
                                    ? w('M7G 90D->30D', 'M7G 慢熊 90D')
                                    : w('M7G 125D -15%', 'M7G 125D -15%'))
                              : (isSb90Row
                                    ? w('B020 90D->30D', '常态慢熊 90D')
                                    : w('B020 0.20%', '常态 0.20%')));
                    final slName = isSimBsm ? '$slNameBase [BSM]' : slNameBase;
                    final roi = _n(r['roi_mult']) ?? 0;
                    final isTpRow = text(r['exit_reason']).contains('tp_');
                    final clickDate = isTpRow
                        ? text(r['exit_date'])
                        : text(r['entry_date']);
                    return InkWell(
                      onTap: clickDate.isNotEmpty
                          ? () => unawaited(_loadPitDate(clickDate))
                          : null,
                      child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: pinnedPitDate != null &&
                                (pinnedPitDate == text(r['exit_date']) ||
                                    pinnedPitDate == text(r['entry_date']))
                            ? _amber.withValues(alpha: 0.12)
                            : null,
                        border: const Border(
                          bottom: BorderSide(color: _borderLine, width: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              slName,
                              style: TextStyle(
                                color: slCol,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              text(r['entry_date']),
                              style: const TextStyle(
                                color: _fgPrimary,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              text(r['exit_date']),
                              style: TextStyle(
                                color: isTpRow ? _amber : _fgMuted,
                                fontSize: 11,
                                fontWeight: isTpRow
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '\$${_fmtNum(_n(r['strike']), dec: 0)} · ${r['entry_dte']}->${r['exit_dte']}D',
                              style: const TextStyle(
                                color: _fgPrimary,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${_fmtUsd(_n(r['cost_usd']))} -> ${_fmtUsd(_n(r['exit_usd']))}',
                              style: const TextStyle(
                                color: _fgMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              '${roi.toStringAsFixed(2)}x',
                              style: TextStyle(
                                color: roi >= 1.0 ? _mint : _coral,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              _pitReasonLabel(text(r['exit_reason'])),
                              style: TextStyle(
                                color: isTpRow ? _amber : _fgMuted,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    );
                  },
                ),
            ],
          ),
        ),
    );
  }

  Widget _buildCtaLedgerTable(List<dynamic> rows, bool isCompact) {
    if (rows.isEmpty) {
      return Text(
        w('No Dual-CTA rotations triggered in this window.', '本窗口未触发双CTA 轮动。'),
        style: const TextStyle(color: _fgMuted, fontSize: 12),
      );
    }
    return _horizontalTable(
      minWidth: isCompact ? 620 : 720,
      child: Container(
          decoration: BoxDecoration(
            color: _bgObsidian,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _borderLine),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _borderLine)),
                ),
                child: Row(
                  children: [
                    Expanded(flex: 2, child: Text(w('Date', '换仓日'), style: _thStyle)),
                    Expanded(flex: 1, child: Text('ETF', style: _thStyle)),
                    Expanded(flex: 1, child: Text(w('Tranche', '批次'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('Rotated -> QQQ', '换入 QQQ 金额'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('QQQ DD', '当日回撤'), style: _thStyle)),
                    Expanded(flex: 2, child: Text(w('1Y Restore Due', '1年机械恢复日'), style: _thStyle)),
                  ],
                ),
              ),
              for (final raw in rows)
                Builder(
                  builder: (_) {
                    final r = asMap(raw);
                    final ctaD = text(r['date']);
                    return InkWell(
                      onTap: ctaD.isNotEmpty
                          ? () => unawaited(_loadPitDate(ctaD))
                          : null,
                      child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: pinnedPitDate == ctaD
                            ? _mint.withValues(alpha: 0.12)
                            : null,
                        border: const Border(
                          bottom: BorderSide(color: _borderLine, width: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              ctaD,
                              style: const TextStyle(
                                color: _fgPrimary,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              text(r['sleeve']),
                              style: const TextStyle(
                                color: _mint,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              '#${r['tranche']}/5',
                              style: const TextStyle(
                                color: _fgMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              _fmtUsd(_n(r['sold_usd'])),
                              style: const TextStyle(
                                color: _fgPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              _fmtPct(_n(r['qqq_dd_pct']), signed: false),
                              style: const TextStyle(
                                color: _coral,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              text(r['restore_due']),
                              style: const TextStyle(
                                color: _sky,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    );
                  },
                ),
            ],
          ),
        ),
    );
  }

  // ---------------------------------------------------------------------------
  // SECTION 6: v3.0 DOUBLE-CHAMPION FULL STRATEGY OPERATING MANUAL (PLAN D)
  // ---------------------------------------------------------------------------
  Widget _buildSection6PlaybookManual(bool isCompact) {
    return Container(
      key: const ValueKey('crisis-v3-playbook-manual'),
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: showPlaybookManual
              ? _mint.withValues(alpha: 0.48)
              : _borderLine,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('crisis-v3-playbook-toggle'),
            onTap: () =>
                setState(() => showPlaybookManual = !showPlaybookManual),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _mint.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _mint.withValues(alpha: 0.55)),
                    ),
                    child: Text(
                      w('SOP MANUAL', '操作手册'),
                      style: const TextStyle(
                        color: _mint,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      w(
                        'v3.0 Double-Champion (Plan D) Full Operating Manual & IBKR Execution Checklist',
                        'v3.0 双冠终极版（Plan D）完整策略操作手册与 IBKR 实盘执行清单',
                      ),
                      style: const TextStyle(
                        color: _fgPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    showPlaybookManual
                        ? w('Collapse ▲', '收起手册 ▲')
                        : w('Read Full SOP ▼', '展开完整手册 ▼'),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (showPlaybookManual) ...[
            const SizedBox(height: 12),
            Text(
              w(
                'Single locked production ruleset verified on 11Y MIT Real OPRA (2015-01-02 to 2025-12-15: 22.62% CAGR / -24.31% MDD / 0.930 Calmar), 5Y Zero-Splice OPRA (2020-12-03 to 2025-12-15: 24.23% CAGR / -23.11% MDD / 1.048 Calmar), and extended through 2026-11-25 (\$994,681 / 21.30% CAGR).',
                '全站唯一锁定实盘规则集：11年纯真实 MIT OPRA（2015-01-02 至 2025-12-15）实证 22.62% 年化 / -24.31% 最大回撤 / 0.930 Calmar；5年零拼接纯实盘窗口（2020-12-03 至 2025-12-15）24.23% 年化 / -23.11% 最大回撤 / 1.048 Calmar；平滑延伸至 2026-11-25 净值达 \$994,681（21.30% 年化）。',
              ),
              style: const TextStyle(
                color: _fgMuted,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            _manualChapterCard(
              badge: '01',
              accent: _mint,
              title: w(
                'Core + Borrowed Dual-CTA Box Stack (Natural Drift, Zero Forced Crash Liquidation)',
                '一、底仓 + 借入双CTA Box 叠加（允许自然漂移，彻底取消底部强制砍仓线）',
              ),
              bullets: [
                w(
                  'Target Allocation: 100% Layer-1 Core (QQQ + B020_M125 Tail Puts) + 10% DBMF + 10% KMLM = 1.20x gross exposure funded by a 20% European cash-settled SPX Short Box Spread at NY Fed EFFR + 35 bps (IBKR stress test uses EFFR + 150 bps).',
                  '目标仓位：100% 第一层底仓（QQQ + B020_M125 尾部看跌核）+ 10% DBMF + 10% KMLM = 1.20x 总敞口；其中 20% 资金通过欧式现金交割 SPX Short Box Spread 融入（利率 NY Fed EFFR + 35 bps；极端压测按 IBKR Pro EFFR + 150 bps）。',
                ),
                w(
                  'Natural-Drift Leverage Policy: Daily 1.20x forced drawdown deleveraging cap is permanently REMOVED. During drawdowns, gross leverage naturally drifts to around 1.25x-1.26x (11Y peak 1.257x, 5Y peak 1.249x) without ever selling QQQ at crash bottoms. Quarterly calm-market calibration resets back to 1.20x.',
                  '自然漂移杠杆纪律：永久取消逐日 1.20x 跌市强制砍仓上限。下跌期间允许总杠杆自然漂移至 1.25x-1.26x（11年历史峰值 1.257x，5年峰值 1.249x），绝不在崩盘底部被迫低卖 QQQ；仅在季度平稳期校准回 1.20x。',
                ),
                w(
                  'Margin Safety Margin: Even at 1.26x peak drift, IBKR Portfolio Margin (15% maintenance) tolerates an additional 80%+ QQQ drop (around 82% at 1.20x) before any margin call, and Reg-T (25% maintenance) still retains around 79% crash headroom.',
                  '保证金安全垫：即使处于 1.26x 峰值自然漂移，IBKR Portfolio Margin（15% 维持保证金）仍可承受逾 80% 的 QQQ 额外暴跌而不触发强平（1.20x 时约 82%）；Reg-T（25% 维持）亦保有约 79% 安全垫。',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _manualChapterCard(
              badge: '02',
              accent: _sky,
              title: w(
                'True Taleb Put Engine: B020 Floor + M7G 1-3x1.25% Graded Ladder (Uniform -15% OTM)',
                '二、正统 Taleb 满血期权核：B020 常态底盾 + M7G 1-3 槽阶梯加码（统一 -15% OTM）',
              ),
              bullets: [
                w(
                  'Sleeve A — B020 Baseline Floor (0.20% NAV): Active entry when VIX <= 20.0 AND VIX/VIX3M < 1.02 AND not in 5D Post-TP Lockout. Normal regime: buy 125 DTE -15% OTM QQQ Put (Hard 75D roll). Slow-Bear Latch override: NEVER open 125D — strictly open 90 DTE -15% OTM and hold to Hard 30 DTE salvage/roll.',
                  'A 轨 · B020 常态基底盾（0.20% NAV）：当 VIX <= 20.0 且 VIX/VIX3M < 1.02 且未处 5日止盈冷冻期时建仓。常态买入 125 DTE、-15% OTM Put（剩 75 DTE 强滚）；一旦进入 +8% 慢熊锁存期严禁开 125D，只能开 90 DTE -15% OTM 并强行拿到 30 DTE 收回残值/滚仓。',
                ),
                w(
                  'Sleeve B — M7G Graded Crisis Ladder (1-3 Slots x 1.25% NAV = up to 3.75% NAV): Composite Score = min(100, Pillar1_Top + Pillar2_Shock + 10 if M3 + 35 if M4_Latch_v2). Score >= 35 opens 1 slot (1.25%), >= 45 opens 2 slots (2.50%), >= 65 opens 3 slots (3.75%).',
                  'B 轨 · M7G 阶梯危机加码（1-3 槽 x 1.25% NAV，最高 3.75% NAV）：综合得分 = min(100, 支柱一顶部 + 支柱二冲击 + M3加10分 + M4磁滞锁存加35分)。>= 35 开 1 槽（1.25%），>= 45 开 2 槽（2.50%），>= 65 开 3 槽（3.75%）。',
                ),
                w(
                  'Standard P1/P2/M3 Low-Vol Entry Gate & Cooldown: Enter only when VXN <= 27.0 AND VIX/VIX3M < 1.02 AND not in 5D Lockout. Minimum spacing between slot escalations: 30 calendar days (Slot 1 -> 2) and 21 calendar days (Slot 2 -> 3). Normal contract: 125 DTE -> Hard 75D Roll (-15% OTM); during +8% Slow-Bear Latch, ALL new puts strictly route to 90 DTE -> Hard 30D salvage/roll.',
                  '常规 P1/P2/M3 低波入场门控与冷却期：仅当 VXN <= 27.0 且 VIX/VIX3M < 1.02 且非冷冻期才允许入场；槽位递增冷却为 30 自然日（1->2 槽）与 21 自然日（2->3 槽）。常态买 125 DTE -> 75D 强滚、-15% OTM；慢熊锁存期内一律禁开 125D，强制开 90 DTE -> 30D 收回。',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _manualChapterCard(
              badge: '03',
              accent: _lilac,
              title: w(
                'Slow-Bear +8% Hysteresis Latch (M4_latch_v2 · Uniform -15% OTM 90D->30D)',
                '三、用户独创 +8% 慢熊磁滞锁存引擎（M4_latch_v2 · 严格统一 -15% OTM）',
              ),
              bullets: [
                w(
                  'ARM Latch (ON): All 4 conditions must hold simultaneously — QQQ < 200DMA, QQQ drawdown from 252d high <= -10.0%, 60d rolling correlation Corr60(DualCTA, QQQ) < 0, AND Dual-CTA cumulative gain since QQQ 252d high >= +8.0%.',
                  '锁存激活（ARM ON）：须同时满足 4 项条件 —— QQQ < 200日均线、QQQ 距 252 日高点回撤 <= -10.0%、双CTA 与 QQQ 60 日滚动相关性 < 0、且双CTA 自 QQQ 252 日高点以来累计涨幅 >= +8.0%。',
                ),
                w(
                  'RESET Latch (OFF): Stays latched ON across bear-market rallies until QQQ closes above 200DMA for 10 consecutive trading days (prevents premature reset during 2022-style dead-cat bounces).',
                  '磁滞复位（RESET OFF）：一旦锁存开启，熊市反抽不会将其误关，必须等 QQQ 连续 10 个交易日收盘站稳 200 日均线上方后才复位关闭（精准防 2022 式假突破）。',
                ),
                w(
                  'M4 Dead-Cat Bounce Trigger & Uniform -15% Strike: When Latch == ON AND QQQ < 200DMA AND 3-Speed EWMAC < 0 AND QQQ > EMA20 AND VXN <= 28.0 AND VIX/VIX3M <= 0.90 -> buy 1.25% NAV per slot in UNIFORM 90 DTE -> Hard 30D Roll, -15% OTM Put (K = 0.85 x S, never -10% OTM) to preserve maximum Taleb gamma convexity.',
                  'M4 死猫反抽入场与统一 -15% 铁律：当锁存 ON 且 QQQ < 200DMA 且三速 EWMAC < 0 且 QQQ > EMA20 且 VXN <= 28.0 且 VIX/VIX3M <= 0.90 时，每槽买 1.25% NAV 的 90 DTE -> 30D 强滚合约，严格坚持统一 -15% OTM（绝不用昂贵 -10% OTM），保留满血 Taleb 尾部凸性。',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _manualChapterCard(
              badge: '04',
              accent: _amber,
              title: w(
                'Hard 75D/30D Roll Salvage Audit + Right-Tail Take-Profit (tp_near_itm_late5x) & 5D Lockout',
                '四、75D/30D 强滚残值审计 + 右尾止盈（tp_near_itm_late5x）与 5日冷冻期',
              ),
              bullets: [
                w(
                  'True Roll Cost vs Gross Turnover: Gross annual put turnover is 6.11% NAV/yr (11Y OPRA), NOT net bleed! Hard rolling at 75D (normal) and holding to 30D (Slow-Bear Latch 90D->30D) recovers 67.1% salvage on non-TP rolls so True Net Roll Bleed is ONLY 2.04% NAV/yr — while net put PnL is +\$113,321 (1.57x payout ratio across 109 trades).',
                  '真实净磨损审计（勿把总换手误读为亏损）：11年总期权名义换手 6.11% NAV/yr，凭借常态 75D 硬滚与慢熊锁存期统一 90D->30D 强行收回，非止盈滚仓平均回收 67.1% 残值，真实年化净滚仓成本仅 2.04% NAV/yr；全期权账本净赚 +\$113,321（109 笔总赔付比 1.57x）。',
                ),
                w(
                  'Full Take-Profit (100% Liquidate): Triggered when (VIX/VIX3M >= 1.10 AND QQQ <= 1.05 x Strike [Near-ITM]) OR VIX >= 45.0. Late 5x Take-Profit: Remaining DTE <= 60D (Base) or <= 45D (Crisis) AND option ROI >= 5.0x -> 100% liquidate.',
                  '右尾全额止盈（100% 平仓）：满足（VIX/VIX3M >= 1.10 且 QQQ <= 1.05 x 行权价 [近实值]）或 VIX >= 45.0 即全平；末段 5x 止盈：剩 <= 60D（底盾）或 <= 45D（危机槽）且期权倍数 >= 5.0x 即全平。',
                ),
                w(
                  'T+1 Lump-Sum QQQ Reinvestment & 5D Contango Lockout: 100% of harvested put cash buys QQQ lump-sum at T+1 close. Both Base and Crisis books immediately lock out new entries until VIX/VIX3M < 1.00 for 5 consecutive trading days (eliminates post-crash IV-crush overpaying).',
                  'T+1 一次性复投 QQQ 与 5日升水冷冻期：止盈现金在 T+1 收盘 100% 一次性买入 QQQ 锁定复利；同时锁定 A/B 两轨新开仓，直到 VIX/VIX3M 连续 5 个交易日回到 < 1.00 升水区才解冻（杜绝暴跌后高 IV 追高挨双打）。',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _manualChapterCard(
              badge: '05',
              accent: _mint,
              title: w(
                'Dual-CTA Slow-Bear Rotation (CONT_2M + 5-Tranche + 1Y LTCG Lock) & IBKR Discipline',
                '五、双CTA 慢熊轮动（CONT_2M 60天 + 分5批 + 1年 LTCG 锁）与 IBKR 实盘下单规范',
              ),
              bullets: [
                w(
                  'CONT_2M 60-Day Timer: Count consecutive calendar days with QQQ drawdown from ATH <= -12.0%. Once >= 60 continuous calendar days (filters out V-shaped flash crashes like 2020 COVID or 2025 Tariff shock), any CTA ETF (DBMF or KMLM independently) whose return since QQQ ATH is > 0% enters 5-tranche rotation.',
                  'CONT_2M 60天连续慢熊计时器：统计 QQQ 距历史前高回撤 <= -12.0% 的连续自然日。只有满 60 天才激活（天然免疫 2020 疫情、2025 关税等 V 型闪崩误触发），凡自 QQQ 前高以来录得正收益（> 0%）的 CTA（DBMF / KMLM 独立判定）启动分批换仓。',
                ),
                w(
                  '5-Tranche Execution & 365-Day Mechanical LTCG Restore: Sell 20% of the qualifying CTA sleeve into pure QQQ every 5 trading days (5 equal tranches total; cancel remaining tranches if QQQ recovers above -12.0% DD). Hold each rotated QQQ lot mechanically for 365 calendar days (qualifies for US Long-Term Capital Gains tax rate), then sell QQQ lot back to 10% DBMF + 10% KMLM (1.20x).',
                  '分5批换仓与 365天机械 LTCG 恢复：每间隔 5 个交易日卖出该盈利 CTA 的 20% 换入纯 QQQ（共 5 批；若中途 QQQ 回到 -12.0% 以内则取消余批）。每批换入的 QQQ 机械持有满 365 自然日（满足美股长期资本利得税率 LTCG），到期机械换回 10% DBMF + 10% KMLM（1.20x）。',
                ),
                w(
                  'IBKR Execution Checklist: Always place Limit Orders at Mid + 0.25 x (Ask - Bid) for QQQ puts (never Market Orders on deep OTM options). Check daily close signals after 15:45 ET and execute on T+1 open/close. For SPX Box Spreads, use European AM-settled SPX combos (verify implied financing vs EFFR + 35 bps).',
                  'IBKR 实盘下单纪律：QQQ 深虚值 Put 一律下限价单 Mid + 0.25 x (Ask - Bid)，严禁市价单扫盘；每日美东 15:45 后按本页面实时状态核对 T+1 动作；SPX Box Spread 务必选用欧式现金交割 SPX 组合单并核验隐含利率接近 EFFR + 35 bps。',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _manualChapterCard({
    required String badge,
    required Color accent,
    required String title,
    required List<String> bullets,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _bgObsidian,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _fgPrimary,
                    fontSize: 12.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final line in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(
                        color: _fgMuted,
                        fontSize: 11.4,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static const TextStyle _thStyle = TextStyle(
    color: _fgMuted,
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );

  Widget _pillBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap, {Color accent = _fgMuted}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: accent.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _windowToggleBtn(String winId, String label) {
    final active = selectedWindow == winId;
    return InkWell(
      key: ValueKey('crisis-v2-win-$winId'),
      onTap: () => _selectWindow(winId),
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active ? _mint.withValues(alpha: 0.16) : _bgInset,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: active ? _mint : _borderLine),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? _mint : _fgMuted,
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _ledgerFilterChip(String id, String label) {
    final active = ledgerFilter == id;
    return InkWell(
      onTap: () => setState(() => ledgerFilter = id),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _sky.withValues(alpha: 0.16) : _bgObsidian,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? _sky : _borderLine),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? _sky : _fgMuted,
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _sizerChip(String title, String primary, String sub, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _bgObsidian,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _fgMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            primary,
            style: TextStyle(
              color: accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 1),
          Text(sub, style: const TextStyle(color: _fgMuted, fontSize: 10.2)),
        ],
      ),
    );
  }

  Widget _metricBox(String label, String val, Color col, {String? sub}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: _bgInset,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _fgMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            val,
            style: TextStyle(
              color: col,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 1),
            Text(sub, style: const TextStyle(color: _fgMuted, fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _inlineStat(String label, String val, Color col) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: _fgMuted, fontSize: 10.2)),
        Text(
          val,
          style: TextStyle(
            color: col,
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _subBarLabel(String label, num val, num cap) {
    return Text(
      '$label: ${val.toStringAsFixed(1)}/${cap.toStringAsFixed(0)}',
      style: const TextStyle(color: _fgMuted, fontSize: 11),
    );
  }

  Widget _legendDot(String label, Color col) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 3,
          decoration: BoxDecoration(
            color: col,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: _fgMuted, fontSize: 11)),
      ],
    );
  }
}

extension _NumSafeExt on num {
  String toFixedSafe(int dec) => isFinite ? toStringAsFixed(dec) : '--';
}

// -----------------------------------------------------------------------------
// CORR60 HORIZONTAL GAUGE PAINTER
// -----------------------------------------------------------------------------
class _CorrGaugePainter extends CustomPainter {
  const _CorrGaugePainter({required this.corr});
  final double corr;

  @override
  void paint(Canvas canvas, Size size) {
    final trackR = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 3, size.width, size.height - 6),
      const Radius.circular(4),
    );
    canvas.drawRRect(trackR, Paint()..color = const Color(0xFF1A232D));

    // Left half (< 0) shaded mint zone
    final leftR = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 3, size.width * 0.5, size.height - 6),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      leftR,
      Paint()..color = const Color(0xFF80C6A8).withValues(alpha: 0.22),
    );

    // Center 0.0 tick line
    final zeroX = size.width * 0.5;
    canvas.drawLine(
      Offset(zeroX, 0),
      Offset(zeroX, size.height),
      Paint()
        ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.65)
        ..strokeWidth = 1.2,
    );

    // Current corr marker
    final clamped = corr.clamp(-1.0, 1.0);
    final x = ((clamped + 1.0) / 2.0) * size.width;
    final col = clamped < 0 ? const Color(0xFF80C6A8) : const Color(0xFFF2BC60);
    canvas.drawCircle(
      Offset(x, size.height / 2),
      5.5,
      Paint()..color = col,
    );
    canvas.drawCircle(
      Offset(x, size.height / 2),
      5.5,
      Paint()
        ..color = const Color(0xFF080B0F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _CorrGaugePainter oldDelegate) =>
      oldDelegate.corr != corr;
}

// -----------------------------------------------------------------------------
// 3-TRACK EQUITY + DRAWDOWN + DAILY LEVERAGE (<=1.20x) CHART PAINTER
// -----------------------------------------------------------------------------
class _CrisisV2EquityChartPainter extends CustomPainter {
  const _CrisisV2EquityChartPainter({
    required this.series,
    required this.useLogScale,
    required this.rebaseTo100,
    required this.hoverIndex,
    required this.pinnedDate,
    this.opraCutoffDate = '2025-12-15',
    this.simExtTag = '2026 BSM Sim ->',
  });

  final List<dynamic> series;
  final bool useLogScale;
  final bool rebaseTo100;
  final int hoverIndex;
  final String? pinnedDate;
  final String opraCutoffDate;
  final String simExtTag;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    const padL = 54.0;
    const padR = 14.0;
    const padT = 10.0;
    const padB = 22.0;
    final plotW = math.max(1.0, size.width - padL - padR);
    final totalH = math.max(60.0, size.height - padT - padB);
    final eqH = totalH * 0.56;
    final ddTop = padT + eqH + 10.0;
    final ddH = totalH * 0.22;
    final levTop = ddTop + ddH + 10.0;
    final levH = math.max(24.0, totalH - eqH - ddH - 20.0);

    double xAt(int i) => padL + (i / (series.length - 1)) * plotW;

    final firstM = series.first as Map;
    final baseV2 = math.max(1e-6, (firstM['nav_v2'] as num?)?.toDouble() ?? 100000.0);
    final baseQ = math.max(1e-6, (firstM['nav_qqq'] as num?)?.toDouble() ?? 100000.0);

    final v2Vals = List<double>.filled(series.length, 100.0);
    final qVals = List<double>.filled(series.length, 100.0);
    final ddV2Vals = List<double>.filled(series.length, 0.0);
    final ddQVals = List<double>.filled(series.length, 0.0);

    double minEq = double.infinity;
    double maxEq = -double.infinity;
    double minDd = -5.0;
    double pkV2 = rebaseTo100 ? 100.0 : baseV2;
    double pkQ = rebaseTo100 ? 100.0 : baseQ;

    for (var i = 0; i < series.length; i++) {
      final m = series[i] as Map;
      final rawV2 = (m['nav_v2'] as num?)?.toDouble() ?? 100000.0;
      final rawQ = (m['nav_qqq'] as num?)?.toDouble() ?? 100000.0;
      final v2 = rebaseTo100 ? (rawV2 / baseV2) * 100.0 : rawV2;
      final q = rebaseTo100 ? (rawQ / baseQ) * 100.0 : rawQ;
      v2Vals[i] = v2;
      qVals[i] = q;
      double d2;
      double dq;
      if (rebaseTo100) {
        if (v2 > pkV2) pkV2 = v2;
        if (q > pkQ) pkQ = q;
        d2 = (v2 / pkV2 - 1.0) * 100.0;
        dq = (q / pkQ - 1.0) * 100.0;
      } else {
        d2 = (m['dd_v2'] as num?)?.toDouble() ?? 0.0;
        dq = (m['dd_qqq'] as num?)?.toDouble() ?? 0.0;
      }
      ddV2Vals[i] = d2;
      ddQVals[i] = dq;

      final tV2 = useLogScale ? math.log(math.max(1.0, v2)) : v2;
      final tQ = useLogScale ? math.log(math.max(1.0, q)) : q;
      if (tV2 < minEq) minEq = tV2;
      if (tQ < minEq) minEq = tQ;
      if (tV2 > maxEq) maxEq = tV2;
      if (tQ > maxEq) maxEq = tQ;
      if (d2 < minDd) minDd = d2;
      if (dq < minDd) minDd = dq;
    }
    if ((maxEq - minEq).abs() < 1e-6) maxEq = minEq + 1.0;

    double yEq(double val) {
      final tv = useLogScale ? math.log(math.max(1.0, val)) : val;
      final frac = ((tv - minEq) / (maxEq - minEq)).clamp(0.0, 1.0);
      return padT + eqH - frac * eqH;
    }

    double yDd(double dd) {
      final frac = (dd / math.min(-5.0, minDd)).clamp(0.0, 1.0);
      return ddTop + frac * ddH;
    }

    double yLev(double lev) {
      final frac = ((lev - 0.95) / 0.37).clamp(0.0, 1.0);
      return levTop + levH - frac * levH;
    }

    // Post-OPRA calibrated BSM simulation shading + vertical dashed boundary at opraCutoffDate (2025-12-15)
    int firstSimIdx = -1;
    for (var i = 0; i < series.length; i++) {
      final dtStr = ((series[i] as Map)['date'] ?? '').toString();
      if (dtStr.compareTo(opraCutoffDate) > 0) {
        firstSimIdx = i;
        break;
      }
    }
    if (firstSimIdx >= 0) {
      final simX = xAt(firstSimIdx);
      canvas.drawRect(
        Rect.fromLTRB(simX, padT, padL + plotW, levTop + levH),
        Paint()..color = const Color(0xFF7DB8F0).withValues(alpha: 0.055),
      );
      if (firstSimIdx > 0) {
        final dashPaint = Paint()
          ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.65)
          ..strokeWidth = 1.1;
        double yCur = padT;
        while (yCur < levTop + levH) {
          canvas.drawLine(
            Offset(simX, yCur),
            Offset(simX, math.min(levTop + levH, yCur + 4.0)),
            dashPaint,
          );
          yCur += 7.5;
        }
      }
      final tagX = math.min(padL + plotW - 92.0, math.max(padL + 4.0, simX + 4.0));
      _drawText(canvas, simExtTag, Offset(tagX, padT + 2.0), const Color(0xFF7DB8F0), 9.0);
    }

    // Slow-Bear Latch shaded bands
    final latchPaint = Paint()
      ..color = const Color(0xFFB8A1EA).withValues(alpha: 0.13);
    int? bandStart;
    for (var i = 0; i < series.length; i++) {
      final on = ((series[i] as Map)['latch'] as num? ?? 0) > 0;
      if (on && bandStart == null) {
        bandStart = i;
      } else if (!on && bandStart != null) {
        canvas.drawRect(
          Rect.fromLTRB(xAt(bandStart), padT, xAt(i - 1), levTop + levH),
          latchPaint,
        );
        bandStart = null;
      }
    }
    if (bandStart != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          xAt(bandStart),
          padT,
          xAt(series.length - 1),
          levTop + levH,
        ),
        latchPaint,
      );
    }

    // Hairline grid
    final gridPaint = Paint()
      ..color = const Color(0xFF25313B)
      ..strokeWidth = 0.8;
    for (var k = 0; k <= 3; k++) {
      final y = padT + (eqH * k / 3.0);
      canvas.drawLine(Offset(padL, y), Offset(padL + plotW, y), gridPaint);
      final tv = maxEq - (maxEq - minEq) * (k / 3.0);
      final v = useLogScale ? math.exp(tv) : tv;
      final lbl = rebaseTo100
          ? v.toStringAsFixed(v >= 200 ? 0 : 1)
          : (v >= 1000000
                ? '\$${(v / 1000000).toStringAsFixed(1)}M'
                : '\$${(v / 1000).toStringAsFixed(0)}k');
      _drawText(canvas, lbl, Offset(4, y - 6), const Color(0xFF9CABB9), 9.5);
    }

    // Drawdown & Leverage panel dividers
    canvas.drawLine(
      Offset(padL, ddTop),
      Offset(padL + plotW, ddTop),
      gridPaint,
    );
    _drawText(canvas, '0%', Offset(24, ddTop - 5), const Color(0xFF9CABB9), 9);
    _drawText(
      canvas,
      '${minDd.toStringAsFixed(0)}%',
      Offset(12, ddTop + ddH - 8),
      const Color(0xFFEC8C98),
      9,
    );

    // 1.20x Quarterly Calibration reference + 1.26x Natural Drift ceiling band (NO daily forced crash cap!)
    final calY = yLev(1.20);
    final driftY = yLev(1.26);
    canvas.drawRect(
      Rect.fromLTRB(padL, driftY, padL + plotW, calY),
      Paint()..color = const Color(0xFFF2BC60).withValues(alpha: 0.07),
    );
    canvas.drawLine(
      Offset(padL, calY),
      Offset(padL + plotW, calY),
      Paint()
        ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.55)
        ..strokeWidth = 1.0,
    );
    canvas.drawLine(
      Offset(padL, driftY),
      Offset(padL + plotW, driftY),
      Paint()
        ..color = const Color(0xFFF2BC60).withValues(alpha: 0.45)
        ..strokeWidth = 0.8,
    );
    _drawText(canvas, '1.26x', Offset(12, driftY - 6), const Color(0xFFF2BC60), 8.5);
    _drawText(canvas, '1.20x', Offset(12, calY - 5), const Color(0xFF7DB8F0), 8.5);
    _drawText(
      canvas,
      '1.00x',
      Offset(12, yLev(1.00) - 5),
      const Color(0xFF9CABB9),
      8.5,
    );

    // Build paths
    final pV2 = Path();
    final pQ = Path();
    final pDdV2 = Path();
    final pDdQ = Path();
    final pLev = Path();
    int pinnedIdx = -1;

    for (var i = 0; i < series.length; i++) {
      final m = series[i] as Map;
      final x = xAt(i);
      final v2 = v2Vals[i];
      final q = qVals[i];
      final d2 = ddV2Vals[i];
      final dq = ddQVals[i];
      final lv = (m['lev'] as num?)?.toDouble() ?? 1.2;
      if (pinnedDate != null && m['date'] == pinnedDate) pinnedIdx = i;
      if (i == 0) {
        pV2.moveTo(x, yEq(v2));
        pQ.moveTo(x, yEq(q));
        pDdV2.moveTo(x, yDd(d2));
        pDdQ.moveTo(x, yDd(dq));
        pLev.moveTo(x, yLev(lv));
      } else {
        pV2.lineTo(x, yEq(v2));
        pQ.lineTo(x, yEq(q));
        pDdV2.lineTo(x, yDd(d2));
        pDdQ.lineTo(x, yDd(dq));
        pLev.lineTo(x, yLev(lv));
      }
    }

    canvas.drawPath(
      pQ,
      Paint()
        ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawPath(
      pV2,
      Paint()
        ..color = const Color(0xFF80C6A8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
    canvas.drawPath(
      pDdQ,
      Paint()
        ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
    canvas.drawPath(
      pDdV2,
      Paint()
        ..color = const Color(0xFF80C6A8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawPath(
      pLev,
      Paint()
        ..color = const Color(0xFFF2BC60)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );

    // Draw PIT operation markers along v2.0 equity curve from compact evt bitmask:
    //   1 = Base 0.2% Put Open | 2 = Crisis R1/M4 Put Open | 4 = Put TP (Diamond) | 8 = 75D/30D Roll/Salvage Exit (Down-Tri) | 16 = CTA Rotate/Restore (Square)
    final outlinePaint = Paint()
      ..color = const Color(0xFF080B0F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < series.length; i++) {
      final m = series[i] as Map;
      final evt = (m['evt'] as num?)?.toInt() ?? 0;
      if (evt == 0) continue;
      final x = xAt(i);
      final y = yEq(v2Vals[i]);

      // Base 0.2% Put Open: subtle small sky dot
      if ((evt & 1) != 0 && (evt & 6) == 0) {
        canvas.drawCircle(
          Offset(x, y),
          2.2,
          Paint()..color = const Color(0xFF7DB8F0).withValues(alpha: 0.85),
        );
      }
      // Standalone 75D / 30D Roll & Salvage Exit (e.g., 2022 M4 30DTE & 75D salvage): crisp lilac down-triangle ▼
      if ((evt & 8) != 0 && (evt & 7) == 0) {
        final downTri = Path()
          ..moveTo(x, y + 4.8)
          ..lineTo(x - 3.8, y - 3.0)
          ..lineTo(x + 3.8, y - 3.0)
          ..close();
        canvas.drawPath(downTri, Paint()..color = const Color(0xFFB8A1EA));
        canvas.drawPath(downTri, outlinePaint);
      }
      // CTA Rotation / Restore: crisp mint square slightly below curve
      if ((evt & 16) != 0) {
        final rect = Rect.fromCenter(
          center: Offset(x, y + 6.5),
          width: 5.8,
          height: 5.8,
        );
        canvas.drawRect(rect, Paint()..color = const Color(0xFF80C6A8));
        canvas.drawRect(rect, outlinePaint);
      }
      // Crisis Put Entry (R1 / M4): coral up-triangle
      if ((evt & 2) != 0 && (evt & 4) == 0) {
        final tri = Path()
          ..moveTo(x, y - 4.8)
          ..lineTo(x - 3.8, y + 3.0)
          ..lineTo(x + 3.8, y + 3.0)
          ..close();
        canvas.drawPath(tri, Paint()..color = const Color(0xFFEC8C98));
        canvas.drawPath(tri, outlinePaint);
      }
      // Put Take-Profit (TP): prominent bright amber gold diamond ◆
      if ((evt & 4) != 0) {
        final dia = Path()
          ..moveTo(x, y - 5.8)
          ..lineTo(x + 5.0, y)
          ..lineTo(x, y + 5.8)
          ..lineTo(x - 5.0, y)
          ..close();
        canvas.drawPath(dia, Paint()..color = const Color(0xFFF2BC60));
        canvas.drawPath(dia, outlinePaint);
      }
    }

    // Date ticks along bottom (adaptive YY-MM-DD when zoomed tight vs YYYY-MM on wide view)
    final shortSpan = series.length < 180;
    final step = math.max(1, (series.length / 5).floor());
    for (var i = 0; i < series.length; i += step) {
      final dt = ((series[i] as Map)['date'] ?? '').toString();
      if (dt.length >= 10) {
        final tickLbl = shortSpan ? dt.substring(2, 10) : dt.substring(0, 7);
        _drawText(
          canvas,
          tickLbl,
          Offset(math.min(padL + plotW - 48, xAt(i) - 18), levTop + levH + 5),
          const Color(0xFF9CABB9),
          9.5,
        );
      }
    }

    // Crosshair for hover or pinned date
    final markerIdx = hoverIndex >= 0 ? hoverIndex : pinnedIdx;
    if (markerIdx >= 0 && markerIdx < series.length) {
      final mx = xAt(markerIdx);
      final my = yEq(v2Vals[markerIdx]);
      final mEvt = ((series[markerIdx] as Map)['evt'] as num?)?.toInt() ?? 0;
      canvas.drawLine(
        Offset(mx, padT),
        Offset(mx, levTop + levH),
        Paint()
          ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.48)
          ..strokeWidth = 1.0,
      );
      if ((mEvt & 31) != 0) {
        // Luminous selection ring around painted trade marker so the icon stays visible
        canvas.drawCircle(
          Offset(mx, my),
          7.2,
          Paint()
            ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.90)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      } else {
        canvas.drawCircle(
          Offset(mx, my),
          4.0,
          Paint()..color = const Color(0xFF80C6A8),
        );
        canvas.drawCircle(
          Offset(mx, my),
          4.0,
          Paint()
            ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1,
        );
      }
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double size,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CrisisV2EquityChartPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.useLogScale != useLogScale ||
      oldDelegate.rebaseTo100 != rebaseTo100 ||
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.pinnedDate != pinnedDate ||
      oldDelegate.opraCutoffDate != opraCutoffDate ||
      oldDelegate.simExtTag != simExtTag;
}

// -----------------------------------------------------------------------------
// INTERACTIVE TIME-RANGE OVERVIEW BRUSH / SCRUBBER BAR PAINTER
// -----------------------------------------------------------------------------
class _CrisisRangeBrushPainter extends CustomPainter {
  const _CrisisRangeBrushPainter({
    required this.series,
    required this.startIdx,
    required this.endIdx,
    required this.padL,
    required this.padR,
    required this.hintLabel,
    this.opraCutoffDate = '2025-12-15',
  });

  final List<dynamic> series;
  final int startIdx;
  final int endIdx;
  final double padL;
  final double padR;
  final String hintLabel;
  final String opraCutoffDate;

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    final plotW = math.max(1.0, size.width - padL - padR);
    const padT = 5.0;
    const padB = 5.0;
    final plotH = math.max(12.0, size.height - padT - padB);
    final maxIdx = series.length - 1;

    double xAt(int i) => padL + (i / maxIdx) * plotW;

    // Left gutter label
    final lblPainter = TextPainter(
      text: TextSpan(
        text: hintLabel,
        style: const TextStyle(
          color: Color(0xFF9CABB9),
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    lblPainter.paint(
      canvas,
      Offset(4, (size.height - lblPainter.height) / 2),
    );

    // Track background
    final trackRect = Rect.fromLTWH(padL, padT, plotW, plotH);
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      const Radius.circular(6),
    );
    canvas.drawRRect(trackRRect, Paint()..color = const Color(0xFF080B0F));

    canvas.save();
    canvas.clipRRect(trackRRect);

    // Compute log-NAV range for miniature preview sparkline
    double minEq = double.infinity;
    double maxEq = -double.infinity;
    for (final raw in series) {
      final m = raw as Map;
      final v2 = math.log(math.max(1.0, (m['nav_v2'] as num?)?.toDouble() ?? 100000.0));
      final q = math.log(math.max(1.0, (m['nav_qqq'] as num?)?.toDouble() ?? 100000.0));
      if (v2 < minEq) minEq = v2;
      if (q < minEq) minEq = q;
      if (v2 > maxEq) maxEq = v2;
      if (q > maxEq) maxEq = q;
    }
    if ((maxEq - minEq).abs() < 1e-6) maxEq = minEq + 1.0;

    double yMini(double nav) {
      final lv = math.log(math.max(1.0, nav));
      final frac = ((lv - minEq) / (maxEq - minEq)).clamp(0.0, 1.0);
      return padT + plotH - 3.0 - frac * (plotH - 6.0);
    }

    // Post-OPRA calibrated BSM extension tint & boundary in overview track
    for (var i = 0; i < series.length; i++) {
      if (((series[i] as Map)['date'] ?? '').toString().compareTo(opraCutoffDate) > 0) {
        final sx = xAt(i);
        canvas.drawRect(
          Rect.fromLTRB(sx, padT, padL + plotW, padT + plotH),
          Paint()..color = const Color(0xFF7DB8F0).withValues(alpha: 0.08),
        );
        canvas.drawLine(
          Offset(sx, padT),
          Offset(sx, padT + plotH),
          Paint()
            ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.55)
            ..strokeWidth = 1.0,
        );
        break;
      }
    }

    // Latch bands in overview track
    final latchPaint = Paint()
      ..color = const Color(0xFFB8A1EA).withValues(alpha: 0.14);
    int? bandStart;
    for (var i = 0; i < series.length; i++) {
      final on = ((series[i] as Map)['latch'] as num? ?? 0) > 0;
      if (on && bandStart == null) {
        bandStart = i;
      } else if (!on && bandStart != null) {
        canvas.drawRect(
          Rect.fromLTRB(xAt(bandStart), padT, xAt(i - 1), padT + plotH),
          latchPaint,
        );
        bandStart = null;
      }
    }
    if (bandStart != null) {
      canvas.drawRect(
        Rect.fromLTRB(xAt(bandStart), padT, xAt(maxIdx), padT + plotH),
        latchPaint,
      );
    }

    // Mini sparklines (QQQ muted sky + v2.0 mint + TP gold bottom ticks)
    final pQ = Path();
    final pV2 = Path();
    final tpPaint = Paint()
      ..color = const Color(0xFFF2BC60).withValues(alpha: 0.85)
      ..strokeWidth = 1.6;
    for (var i = 0; i < series.length; i++) {
      final m = series[i] as Map;
      final x = xAt(i);
      final v2 = (m['nav_v2'] as num?)?.toDouble() ?? 100000.0;
      final q = (m['nav_qqq'] as num?)?.toDouble() ?? 100000.0;
      if (i == 0) {
        pV2.moveTo(x, yMini(v2));
        pQ.moveTo(x, yMini(q));
      } else {
        pV2.lineTo(x, yMini(v2));
        pQ.lineTo(x, yMini(q));
      }
      final evt = (m['evt'] as num?)?.toInt() ?? 0;
      if ((evt & 4) != 0) {
        canvas.drawLine(
          Offset(x, padT + plotH - 5.5),
          Offset(x, padT + plotH),
          tpPaint,
        );
      }
    }

    canvas.drawPath(
      pQ,
      Paint()
        ..color = const Color(0xFF7DB8F0).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawPath(
      pV2,
      Paint()
        ..color = const Color(0xFF80C6A8).withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );

    // Dimmed unselected overlays
    final xStart = xAt(startIdx);
    final xEnd = xAt(endIdx);
    final maskPaint = Paint()
      ..color = const Color(0xFF080B0F).withValues(alpha: 0.72);
    if (xStart > padL) {
      canvas.drawRect(
        Rect.fromLTRB(padL, padT, xStart, padT + plotH),
        maskPaint,
      );
    }
    if (xEnd < padL + plotW) {
      canvas.drawRect(
        Rect.fromLTRB(xEnd, padT, padL + plotW, padT + plotH),
        maskPaint,
      );
    }

    // Selected active window tint & mint top/bottom rails
    canvas.drawRect(
      Rect.fromLTRB(xStart, padT, xEnd, padT + plotH),
      Paint()..color = const Color(0xFF80C6A8).withValues(alpha: 0.11),
    );
    final railPaint = Paint()
      ..color = const Color(0xFF80C6A8)
      ..strokeWidth = 1.6;
    canvas.drawLine(Offset(xStart, padT + 0.8), Offset(xEnd, padT + 0.8), railPaint);
    canvas.drawLine(
      Offset(xStart, padT + plotH - 0.8),
      Offset(xEnd, padT + plotH - 0.8),
      railPaint,
    );

    canvas.restore();

    // Outer track border
    canvas.drawRRect(
      trackRRect,
      Paint()
        ..color = const Color(0xFF25313B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Left & right draggable handle capsules with grip lines
    void drawHandle(double hx) {
      final clampedX = hx.clamp(padL + 5.0, padL + plotW - 5.0);
      final hRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(clampedX, padT + plotH / 2),
          width: 10.0,
          height: 24.0,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(hRect, Paint()..color = const Color(0xFF15212C));
      canvas.drawRRect(
        hRect,
        Paint()
          ..color = const Color(0xFF80C6A8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
      final grip = Paint()
        ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.85)
        ..strokeWidth = 1.0;
      canvas.drawLine(
        Offset(clampedX - 1.5, padT + plotH / 2 - 5),
        Offset(clampedX - 1.5, padT + plotH / 2 + 5),
        grip,
      );
      canvas.drawLine(
        Offset(clampedX + 1.5, padT + plotH / 2 - 5),
        Offset(clampedX + 1.5, padT + plotH / 2 + 5),
        grip,
      );
    }

    drawHandle(xStart);
    drawHandle(xEnd);
  }

  @override
  bool shouldRepaint(covariant _CrisisRangeBrushPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.startIdx != startIdx ||
      oldDelegate.endIdx != endIdx ||
      oldDelegate.padL != padL ||
      oldDelegate.padR != padR ||
      oldDelegate.hintLabel != hintLabel;
}
