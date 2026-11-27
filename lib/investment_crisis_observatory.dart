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
  String ledgerFilter = 'all';
  int hoverIndex = -1;
  int loadSerial = 0;

  // Point-in-Time (PIT) historical replay state (click any point on curve)
  String? pinnedPitDate;
  Map<String, dynamic>? pitSnapshot;
  bool loadingPit = false;
  int pitSerial = 0;
  final Map<String, Map<String, dynamic>> _pitCache = {};
  final Map<String, Map<String, dynamic>> _windowCache = {};

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
    setState(() {
      selectedWindow = norm;
      hoverIndex = -1;
    });
    _emitSelection();
    unawaited(_loadDashboard(isWindowSwitch: true));
  }

  Future<void> _loadPitDate(String date) async {
    if (date.isEmpty) return;
    final serial = ++pitSerial;
    final cached = _pitCache[date];
    if (cached != null) {
      setState(() {
        pinnedPitDate = date;
        pitSnapshot = cached;
        loadingPit = false;
      });
      return;
    }
    setState(() {
      pinnedPitDate = date;
      loadingPit = true;
    });
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory/pit',
        queryParameters: {'date': date},
      );
      final resp = await widget.api.getJson(uri.toString());
      if (!mounted || serial != pitSerial) return;
      final map = asMap(resp);
      _pitCache[date] = map;
      setState(() {
        pitSnapshot = map;
        loadingPit = false;
      });
    } catch (_) {
      if (!mounted || serial != pitSerial) return;
      setState(() {
        loadingPit = false;
      });
    }
  }

  void _clearPitReplay() {
    setState(() {
      pinnedPitDate = null;
      pitSnapshot = null;
      loadingPit = false;
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
                'Loading ThesisForge v2.0 Single-Strategy Crisis Cockpit...',
                '正在加载 ThesisForge v2.0 唯一锁定主策略危机观测舱...',
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
                'Unable to load Crisis Observatory v2.0 data.',
                '暂时无法加载危机观测 v2.0 数据。',
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

              // Section 5: Real MIT OPRA Historical Verification (v2.0 vs 100% QQQ)
              _buildSection5OpraBacktest(
                backtest,
                isCompact: isCompact,
                isWide: isWide,
              ),
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
    final r2Strike = asMap(strikes['route2_m4_90d_10otm']);
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
                        'v2.0 LOCKED MASTER STRATEGY',
                        'v2.0 唯一锁定主策略',
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
                      '100% QQQ + 10% DBMF + 10% KMLM (<=1.20x) + Dual-Sleeve Tail Put',
                      '100% QQQ + 10% DBMF + 10% KMLM（<=1.20x）+ 双轨尾部 Put',
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
                    _sizerChip(
                      w('Sleeve A (0.2% · 125D -15%)', '常态盾 0.2% · 125D -15%'),
                      'K = \$${_n(r1Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.002)})',
                      w(
                        'Exact ${_fmtUsd(_n(r1Strike['exact_strike']), dec: 2)} · Roll <=75D',
                        '精确 ${_fmtUsd(_n(r1Strike['exact_strike']), dec: 2)} · <=75D 滚仓',
                      ),
                      _sky,
                    ),
                    _sizerChip(
                      w(
                        'Sleeve B R1 (1.0% · 125D -15%)',
                        '危机盾 R1 1.0% · 125D -15%',
                      ),
                      'K = \$${_n(r1Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.010)})',
                      w(
                        'P1/P2/M3 >=35% · Roll/Recycle 75D',
                        'P1/P2/M3 >=35% · 75D 滚仓/回收',
                      ),
                      _amber,
                    ),
                    _sizerChip(
                      w(
                        'Sleeve B M4 (1.0% · 90D -10%)',
                        '慢熊 M4 1.0% · 90D -10%',
                      ),
                      'K = \$${_n(r2Strike['suggested_strike'])?.round() ?? 0} (${_fmtUsd(accountNav * 0.010)})',
                      w(
                        'Exact ${_fmtUsd(_n(r2Strike['exact_strike']), dec: 2)} · Recycle <=30D',
                        '精确 ${_fmtUsd(_n(r2Strike['exact_strike']), dec: 2)} · <=30D 回收残值',
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
                  '2-Month Continuous Bear Timer (CONT_2M) & 1.20x Guard',
                  '双CTA 2个月持续熊市计时器（CONT_2M）与 1.20x 红线',
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

          // Hard <= 1.200x Daily Leverage Guard Strip
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bgInset,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _mint.withValues(alpha: 0.4)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              children: [
                _inlineStat(
                  w('Hard Daily Cap', '每日硬杠杆上限'),
                  '<= ${_fmtNum(_n(lev['hard_cap']), dec: 3)}x',
                  _mint,
                ),
                _inlineStat(
                  w('Init LTV', '初始 LTV'),
                  '${_fmtNum(_n(lev['init_ltv_pct']), dec: 2)}%',
                  _sky,
                ),
                _inlineStat(
                  w('Reg-T Cushion', 'Reg-T 强平垫'),
                  _fmtPct(_n(lev['reg_t_crash_cushion_pct'])),
                  _mint,
                ),
                _inlineStat(
                  w('SPX Box Rate', 'Box 融资利率'),
                  '${_fmtNum(_n(lev['box_rate_pct']), dec: 2)}%',
                  _amber,
                ),
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
    final entProb = _n(tp['entry_crisis_prob'])?.round() ?? 0;
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
                  'Three-Pillar Real-Time Crisis Sensors (Raw Structure vs Vol-Gate)',
                  '三支柱实时危机雷达（原始结构预警 vs 低波建仓门控）',
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
                      'Track A · Stress $stressIdx/100 · Raw $rawProb%',
                      '轨道 A · 实时压力 $stressIdx/100 · 原始预警 $rawProb%',
                    ),
                    stressIdx >= 75
                        ? _coral
                        : (stressIdx >= 50 ? _amber : _mint),
                  ),
                  _pillBadge(
                    w(
                      'Track B · Vol-Gate Entry $entProb%',
                      '轨道 B · 低波建仓 $entProb%',
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
    final t2DdOk = t2['dd_ok'] == true;
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
              'Tiered Put Take-Profit Radar & Volatility/Skew Microstructure',
              '两档 Put 止盈雷达与波动率 / 偏度微结构',
            ),
            style: const TextStyle(
              color: _fgPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),

          // 6 Volatility & Skew Microstructure Tiles
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _metricBox(
                'VIX',
                _fmtNum(vix),
                vix < 20.0 ? _mint : (vix >= 30.0 ? _coral : _amber),
                sub: w('Sleeve A < 20.0', '常态盾门槛 < 20.0'),
              ),
              _metricBox(
                'VXN',
                _fmtNum(vxn),
                vxn <= 28.0 ? _mint : _coral,
                sub: w('M4 Gate <= 28.0', 'M4 门控 <= 28.0'),
              ),
              _metricBox(
                'VIX / VIX3M',
                _fmtNum(vr, dec: 3),
                vr >= 1.10 ? _mint : (vr >= 1.0 ? _coral : _sky),
                sub: w(
                  'VIX3M ${_fmtNum(_n(m['vix3m']))} · TP >= 1.10',
                  'VIX3M ${_fmtNum(_n(m['vix3m']))} · 止盈 >= 1.10',
                ),
              ),
              _metricBox(
                w('QQQ ATH DD', 'QQQ 距前高回撤'),
                _fmtPct(ddPct),
                ddPct <= -10.0 ? _amber : _fgPrimary,
                sub: w('Full TP <= -10.0%', '全额止盈 <= -10.0%'),
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
            ],
          ),
          const SizedBox(height: 12),

          // Tier 1 & Tier 2 Take-Profit Cards
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
                            'Tier 1 · Partial TP (>= 5.0x & VIX/3M < 1.00)',
                            '一档分批止盈（>= 5.0x 且 VIX/3M < 1.00）',
                          ),
                          style: const TextStyle(
                            color: _sky,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        _pillBadge(
                          t1['contango_ok'] == true
                              ? w('CONTANGO OK', '非倒挂就绪')
                              : w('INVERTED -> TIER 2', '已倒挂 -> 看二档'),
                          t1['contango_ok'] == true ? _sky : _amber,
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
                            'Tier 2 · 100% Full TP (VR >= 1.10 & ATH DD <= -10%)',
                            '二档 100% 清仓止盈（VR >= 1.10 且回撤 <= -10%）',
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
                          'ATH DD ${_fmtPct(ddPct)} <= -10.0%',
                          t2DdOk ? _mint : _slate,
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
    final kPri = asMap(win['kpi_primary']);
    final kStr = asMap(win['kpi_stress']);
    final kQqq = asMap(win['kpi_qqq']);
    final series = asList(win['daily_series']);
    final crises = asList(win['crisis_comparison']);
    final putLedger = asList(win['put_ledger']);
    final ctaLedger = asList(win['cta_rotation_ledger']);

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
                      'Real MIT OPRA Historical Verification · v2.0 Master Strategy vs 100% QQQ',
                      '真实 MIT OPRA 历史验证 · v2.0 唯一主策略 vs 100% QQQ',
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
                      '6,382,288 real 16:00 ET US OPRA quotes · 0 execution fallbacks · Click any date on curve to replay PIT cockpit',
                      '6,382,288 条美股 16:00 ET 真实 OPRA 盘口 · 0 次回退 · 点击净值曲线任意日期可一键回放当日实况',
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
                    w('11Y OPRA (2015-2025.12)', '11年 OPRA（2015-2025.12）'),
                  ),
                  _windowToggleBtn(
                    '5y_live',
                    w('5Y Zero-Splice (2020.12-2025.12)', '5年零拼接（2020.12-2025.12）'),
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
                      'v2.0 Master (Box +35bp · IBKR Limit)',
                      'v2.0 唯一主策略（Box +35bp · 限价）',
                    ),
                    kPri,
                    highlight: true,
                  ),
                  _kpiDataRow(
                    w(
                      'v2.0 Stress (IBKR +150bp · Full Ask/Bid)',
                      'v2.0 极端压测（IBKR +150bp · 对手盘）',
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

          const SizedBox(height: 8),
          Text(
            w(text(win['disclosure_en']), text(win['disclosure_zh'])),
            style: const TextStyle(color: _fgMuted, fontSize: 11),
          ),

          const SizedBox(height: 14),

          // Interactive Dual-Panel Equity + Drawdown + Leverage Chart
          if (series.isNotEmpty) _buildInteractiveChart(series, isCompact),

          const SizedBox(height: 16),

          // 8-Crisis Historical Anatomy Comparison Table
          Text(
            w(
              'Historical Crisis Anatomy (v2.0 Single Strategy vs 100% QQQ)',
              '历次真实危机解剖对比（v2.0 唯一主策略 vs 100% QQQ）',
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
                _ledgerFilterChip('base', w('Sleeve A (0.2%)', '常态盾 0.2%')),
                _ledgerFilterChip(
                  'route1',
                  w('Route 1 (125D -15%)', '三支柱 125D -15%'),
                ),
                _ledgerFilterChip('m4', w('M4 Slow-Bear (90D -10%)', 'M4 慢熊 90D -10%')),
                _ledgerFilterChip(
                  'cta',
                  w('Dual-CTA Rotations', '双CTA 轮动记录'),
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

  Widget _buildInteractiveChart(List<dynamic> series, bool isCompact) {
    final activeIdx = hoverIndex >= 0 && hoverIndex < series.length
        ? hoverIndex
        : series.length - 1;
    final activeRow = asMap(series[activeIdx]);
    final chartH = isCompact ? 260.0 : 320.0;

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
                spacing: 12,
                runSpacing: 4,
                children: [
                  _legendDot(w('v2.0 Master NAV', 'v2.0 主策略净值'), _mint),
                  _legendDot(w('100% QQQ B&H', '100% QQQ 基准'), _sky),
                  _legendDot(w('Daily Lev (<=1.20x)', '每日杠杆 (<=1.20x)'), _amber),
                  _legendDot(w('Slow-Bear Latch ON', '慢熊滞回锁存期'), _lilac),
                ],
              ),
              Text(
                '${text(activeRow['date'])}  ·  v2.0 ${_fmtUsd(_n(activeRow['nav_v2']))} (${_fmtPct(_n(activeRow['dd_v2']), signed: false)})  ·  QQQ ${_fmtUsd(_n(activeRow['nav_qqq']))}  ·  Lev ${_fmtNum(_n(activeRow['lev']), dec: 3)}x',
                style: const TextStyle(
                  color: _fgPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (_, c) {
              final width = c.maxWidth;
              int idxFromDx(double dx) {
                const padL = 54.0;
                const padR = 14.0;
                final plotW = math.max(1.0, width - padL - padR);
                final frac = ((dx - padL) / plotW).clamp(0.0, 1.0);
                return (frac * (series.length - 1)).round();
              }

              return MouseRegion(
                onHover: (ev) {
                  final nextIdx = idxFromDx(ev.localPosition.dx);
                  if (nextIdx != hoverIndex) {
                    setState(() => hoverIndex = nextIdx);
                  }
                },
                onExit: (_) {
                  if (hoverIndex != -1) setState(() => hoverIndex = -1);
                },
                child: GestureDetector(
                  onTapUp: (details) {
                    final idx = idxFromDx(details.localPosition.dx);
                    final d = text(asMap(series[idx])['date']);
                    if (d.isNotEmpty) unawaited(_loadPitDate(d));
                  },
                  child: SizedBox(
                    height: chartH,
                    width: width,
                    child: CustomPaint(
                      painter: _CrisisV2EquityChartPainter(
                        series: series,
                        useLogScale: useLogScale,
                        hoverIndex: hoverIndex,
                        pinnedDate: pinnedPitDate,
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
            child: Text(w('v2.0 MDD', 'v2.0 最大回撤'), style: _thStyle),
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
    return Container(
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
              '${text(c['start_date'])} .. ${text(c['end_date']).substring(5)}',
              style: const TextStyle(color: _fgMuted, fontSize: 11),
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
                    final slName = sl == 'crisis_m4'
                        ? w('M4 90D -10%', 'M4 90D -10%')
                        : (sl == 'crisis'
                              ? w('R1 125D -15%', 'R1 125D -15%')
                              : w('Base 0.2%', '常态 0.2%'));
                    final roi = _n(r['roi_mult']) ?? 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
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
                              style: const TextStyle(
                                color: _fgMuted,
                                fontSize: 11,
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
                              text(r['exit_reason']),
                              style: const TextStyle(
                                color: _fgMuted,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
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
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: _borderLine, width: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              text(r['date']),
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
                    );
                  },
                ),
            ],
          ),
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
    required this.hoverIndex,
    required this.pinnedDate,
  });

  final List<dynamic> series;
  final bool useLogScale;
  final int hoverIndex;
  final String? pinnedDate;

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

    double minEq = double.infinity;
    double maxEq = -double.infinity;
    double minDd = -5.0;
    for (final raw in series) {
      final m = raw as Map;
      final v2 = (m['nav_v2'] as num?)?.toDouble() ?? 100000.0;
      final q = (m['nav_qqq'] as num?)?.toDouble() ?? 100000.0;
      final d2 = (m['dd_v2'] as num?)?.toDouble() ?? 0.0;
      final dq = (m['dd_qqq'] as num?)?.toDouble() ?? 0.0;
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
      final frac = ((lev - 0.90) / 0.36).clamp(0.0, 1.0);
      return levTop + levH - frac * levH;
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
      final lbl = v >= 1000000
          ? '\$${(v / 1000000).toStringAsFixed(1)}M'
          : '\$${(v / 1000).toStringAsFixed(0)}k';
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

    // 1.20x Hard Cap redline on Leverage panel
    final capY = yLev(1.20);
    canvas.drawLine(
      Offset(padL, capY),
      Offset(padL + plotW, capY),
      Paint()
        ..color = const Color(0xFFEC8C98).withValues(alpha: 0.7)
        ..strokeWidth = 1.0,
    );
    _drawText(canvas, '1.20x', Offset(12, capY - 6), const Color(0xFFEC8C98), 9);
    _drawText(
      canvas,
      '1.00x',
      Offset(12, yLev(1.00) - 5),
      const Color(0xFF9CABB9),
      9,
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
      final v2 = (m['nav_v2'] as num?)?.toDouble() ?? 100000.0;
      final q = (m['nav_qqq'] as num?)?.toDouble() ?? 100000.0;
      final d2 = (m['dd_v2'] as num?)?.toDouble() ?? 0.0;
      final dq = (m['dd_qqq'] as num?)?.toDouble() ?? 0.0;
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

    // Date ticks along bottom
    final step = math.max(1, (series.length / 5).floor());
    for (var i = 0; i < series.length; i += step) {
      final dt = ((series[i] as Map)['date'] ?? '').toString();
      if (dt.length >= 7) {
        _drawText(
          canvas,
          dt.substring(0, 7),
          Offset(math.min(padL + plotW - 42, xAt(i) - 18), levTop + levH + 5),
          const Color(0xFF9CABB9),
          9.5,
        );
      }
    }

    // Crosshair for hover or pinned date
    final markerIdx = hoverIndex >= 0 ? hoverIndex : pinnedIdx;
    if (markerIdx >= 0 && markerIdx < series.length) {
      final mx = xAt(markerIdx);
      canvas.drawLine(
        Offset(mx, padT),
        Offset(mx, levTop + levH),
        Paint()
          ..color = const Color(0xFFEDF1F5).withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
      final m = series[markerIdx] as Map;
      final v2 = (m['nav_v2'] as num?)?.toDouble() ?? 100000.0;
      canvas.drawCircle(
        Offset(mx, yEq(v2)),
        4.0,
        Paint()..color = const Color(0xFF80C6A8),
      );
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
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.pinnedDate != pinnedDate;
}
