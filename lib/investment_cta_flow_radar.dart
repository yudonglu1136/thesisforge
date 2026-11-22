part of 'main.dart';

class CtaFlowRadarPanel extends StatefulWidget {
  const CtaFlowRadarPanel({
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
  State<CtaFlowRadarPanel> createState() => _CtaFlowRadarPanelState();
}

class _CtaFlowRadarPanelState extends State<CtaFlowRadarPanel> {
  static const Color _obsidian = Color(0xFF080B0F);
  static const Color _surface = Color(0xFF0E141B);
  static const Color _surfaceRaised = Color(0xFF131B24);
  static const Color _hairline = Color(0xFF25313B);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _amber = Color(0xFFF2BC60);
  static const Color _lilac = Color(0xFFB8A1EA);
  static const Color _coral = Color(0xFFEC8C98);

  Map<String, dynamic>? data;
  bool loading = true;
  String? error;

  String selectedAsset = 'SPY';
  String selectedHorizon = '10D';
  String selectedEpisodeId = '2026_11_live';
  bool showMethodology = false;
  int hoverCurveIndex = -1;
  int loadSerial = 0;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  @override
  void initState() {
    super.initState();
    final initAsset = text(widget.initialSelection['asset']).toUpperCase();
    if (initAsset == 'SPY' || initAsset == 'QQQ') {
      selectedAsset = initAsset;
    }
    final initHorizon = text(widget.initialSelection['horizon']).toUpperCase();
    if (initHorizon == '5D' || initHorizon == '10D') {
      selectedHorizon = initHorizon;
    }
    unawaited(_loadRadar());
  }

  @override
  void didUpdateWidget(covariant CtaFlowRadarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(_loadRadar());
    }
  }

  void _emitSelection() {
    widget.onSelection?.call({
      'asset': selectedAsset,
      'horizon': selectedHorizon,
    });
  }

  Future<void> _loadRadar() async {
    final serial = ++loadSerial;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final uri = Uri(
        path: '/api/investment/cta-flow-radar',
        queryParameters: {
          'asOf': widget.asOf,
          'asset': selectedAsset,
          'horizon': selectedHorizon,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      final assetMap = asMap(asMap(res['assets'])[selectedAsset]);
      final timeline = asList(assetMap['historicalTimeline']);
      var nextEpisode = selectedEpisodeId;
      if (timeline.isNotEmpty &&
          !timeline.any((e) => text(e['id']) == nextEpisode)) {
        nextEpisode = text(timeline.last['id']);
      }
      setState(() {
        data = res;
        selectedEpisodeId = nextEpisode;
        hoverCurveIndex = -1;
        loading = false;
      });
    } catch (e) {
      if (!mounted || serial != loadSerial) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  void _selectAsset(String asset) {
    if (asset == selectedAsset) return;
    final assetMap = asMap(asMap(data?['assets'])[asset]);
    final timeline = asList(assetMap['historicalTimeline']);
    var nextEpisode = selectedEpisodeId;
    if (timeline.isNotEmpty &&
        !timeline.any((e) => text(e['id']) == nextEpisode)) {
      nextEpisode = text(timeline.last['id']);
    }
    setState(() {
      selectedAsset = asset;
      selectedEpisodeId = nextEpisode;
      hoverCurveIndex = -1;
    });
    _emitSelection();
  }

  void _selectHorizon(String horizon) {
    if (horizon == selectedHorizon) return;
    setState(() {
      selectedHorizon = horizon;
      hoverCurveIndex = -1;
    });
    _emitSelection();
  }

  String _fmtSignedB(dynamic v, {int decimals = 2}) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    final sign = n > 0 ? '+' : (n < 0 ? '-' : '');
    return '$sign\$${n.abs().toStringAsFixed(decimals)}B';
  }

  String _fmtPrice(dynamic v) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    return '\$${n.toStringAsFixed(2)}';
  }

  String _fmtSignedPct(dynamic v, {int decimals = 2}) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    final sign = n > 0 ? '+' : '';
    return '$sign${n.toStringAsFixed(decimals)}%';
  }

  String _fmtPVal(dynamic v) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    if (n < 0.0001) return '<0.0001';
    return n.toStringAsFixed(4);
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 14),
            Text(
              w(
                'Calibrating Rob Carver 6-speed EWMAC & Vol-Control flow surface...',
                '正在校准 Rob Carver 六速 EWMAC 与波动率目标资金流曲面…',
              ),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _coral.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Unable to load CTA Flow Radar snapshot.',
                '暂时无法加载 CTA 系统化资金流雷达数据。',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error!,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadRadar,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final doc = data ?? const <String, dynamic>{};
    final assets = asMap(doc['assets']);
    final assetData = asMap(assets[selectedAsset]);
    final live = asMap(assetData['liveState']);
    final signals = asMap(assetData['signals']);
    final pitScale = asMap(doc['pit13fScale']);
    final evalWindow = asMap(doc['evaluationWindow']);
    final asOfDate = text(live['asOfDate'], text(doc['asOfDate']));

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final wide = constraints.maxWidth >= 1080;
        return Column(
          key: const ValueKey('cta-flow-radar-root'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            _buildHeroControlStrip(
              compact: compact,
              asOfDate: asOfDate,
              assetData: assetData,
              live: live,
              pitScale: pitScale,
              liveExtended: doc['liveExtended'] == true,
            ),
            const SizedBox(height: 14),
            _buildKpiStrip(compact: compact, live: live),
            const SizedBox(height: 14),
            _buildSignalBeacons(
              compact: compact,
              signals: signals,
              live: live,
            ),
            const SizedBox(height: 16),
            _buildModuleASurfaceAndMatrix(
              compact: compact,
              wide: wide,
              assetData: assetData,
              live: live,
            ),
            const SizedBox(height: 16),
            _buildModuleBScorecardAndTimeline(
              compact: compact,
              wide: wide,
              assetData: assetData,
              evalWindow: evalWindow,
            ),
            const SizedBox(height: 16),
            _buildMethodologyDrawer(
              compact: compact,
              wide: wide,
              assetData: assetData,
              pitScale: pitScale,
              evalWindow: evalWindow,
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeroControlStrip({
    required bool compact,
    required String asOfDate,
    required Map<String, dynamic> assetData,
    required Map<String, dynamic> live,
    required Map<String, dynamic> pitScale,
    required bool liveExtended,
  }) {
    final instCount = number(pitScale['trackedInstitutionCount']).round();
    final latestTrendB = number(pitScale['latestCtaTrendCoreB']);
    final horizonLabel = selectedHorizon == '5D'
        ? w('5D (1W) Shock Window', '5D（1 周）冲击窗口')
        : w('10D (2W) Shock Window', '10D（2 周）冲击窗口');

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _mint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: _mint.withValues(alpha: 0.4)),
                ),
                child: Text(
                  w(
                    'ROB CARVER 6-SPEED EWMAC · ZERO-LOOKAHEAD OOS',
                    'ROB CARVER 六速连续趋势 · 12 年零前视实证',
                  ),
                  style: const TextStyle(
                    color: _mint,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _surfaceRaised,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: _hairline),
                ),
                child: Text(
                  w(
                    '$instCount SEC 13F Trend Institutions (\$${latestTrendB.toStringAsFixed(1)}B Core Equity · T+45 PIT)',
                    '$instCount 家 SEC 13F 趋势机构校准（\$${latestTrendB.toStringAsFixed(1)}B 权益底仓 · T+45 法定滞后）',
                  ),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (liveExtended)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _sky.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: _sky.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    w('LIVE TAIL EXTENDED', '实时行情动态延展'),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (compact) ...[
            _buildHeroTitleBlock(
              compact: compact,
              asOfDate: asOfDate,
              horizonLabel: horizonLabel,
            ),
            const SizedBox(height: 12),
            _buildHeroSwitchWrap(),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _buildHeroTitleBlock(
                    compact: compact,
                    asOfDate: asOfDate,
                    horizonLabel: horizonLabel,
                  ),
                ),
                const SizedBox(width: 16),
                _buildHeroSwitchWrap(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildHeroTitleBlock({
    required bool compact,
    required String asOfDate,
    required String horizonLabel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                w(
                  'CTA Systematic Flow Radar',
                  'CTA 系统化资金流雷达',
                ),
                style: TextStyle(
                  color: p.text,
                  fontSize: compact ? 20 : 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              key: ValueKey('cta-open-company-$selectedAsset'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => widget.onCompany(selectedAsset),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: _surfaceRaised,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      selectedAsset,
                      style: const TextStyle(
                        color: _sky,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.open_in_new_rounded,
                      size: 12,
                      color: _sky,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          w(
            'Continuous volatility-targeted EWMAC(2/8..64/256) + 10% inertia buffer + Vol-Control (RV20/RV60) · As of $asOfDate · $horizonLabel',
            '连续波动率调整 EWMAC(2/8..64/256) + 10% 惯性缓冲带 + 波动率目标基金（RV20/RV60）· 截至 $asOfDate · $horizonLabel',
          ),
          style: TextStyle(
            color: p.muted,
            fontSize: 12.5,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _buildHeroSwitchWrap() {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildSegmentedSwitch(
          options: [
            (
              'SPY',
              w('SPY · S&P 500', 'SPY · 标普500'),
              const ValueKey('cta-asset-SPY'),
            ),
            (
              'QQQ',
              w('QQQ · Nasdaq-100', 'QQQ · 纳指100'),
              const ValueKey('cta-asset-QQQ'),
            ),
          ],
          current: selectedAsset,
          activeColor: _mint,
          onSelect: _selectAsset,
        ),
        _buildSegmentedSwitch(
          options: [
            (
              '5D',
              w('5D (1W)', '5D（1周）'),
              const ValueKey('cta-horizon-5D'),
            ),
            (
              '10D',
              w('10D (2W)', '10D（2周）'),
              const ValueKey('cta-horizon-10D'),
            ),
          ],
          current: selectedHorizon,
          activeColor: _sky,
          onSelect: _selectHorizon,
        ),
      ],
    );
  }

  Widget _buildSegmentedSwitch({
    required List<(String, String, Key)> options,
    required String current,
    required Color activeColor,
    required ValueChanged<String> onSelect,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _surfaceRaised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final opt in options)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: InkWell(
                key: opt.$3,
                borderRadius: BorderRadius.circular(6),
                onTap: () => onSelect(opt.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: current == opt.$1
                        ? activeColor.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: current == opt.$1
                          ? activeColor.withValues(alpha: 0.65)
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    opt.$2,
                    style: TextStyle(
                      color: current == opt.$1 ? p.text : p.muted,
                      fontSize: 12,
                      fontWeight: current == opt.$1
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
  }

  Widget _buildKpiStrip({
    required bool compact,
    required Map<String, dynamic> live,
  }) {
    final spot = _fmtPrice(live['spotClose']);
    final posComb = _fmtSignedB(live['posCombinedSysB']);
    final delev = _fmtSignedB(live['recentCumDeleveragingB']);
    final fCarver = number(live['fCarver']);
    final fSma = number(live['fSma']);
    final pctile = number(live['carverForecast12YrPercentile']);
    final vixRatio = number(live['vixVix3mRatio']);
    final vixInverted = live['vixBackwardation'] == true;
    final vixClose = number(live['vixClose']);
    final vix3mClose = number(live['vix3mClose']);
    final asym3 = number(live['marginalAsymmetry3Pct5d']);
    final asym5 = number(live['marginalAsymmetry5Pct5d']);

    final is5d = selectedHorizon == '5D';
    final flipPx = is5d
        ? live['zeroNetFlowBreakeven5dPx']
        : live['zeroNetFlowBreakeven10dPx'];
    final flipPct = is5d
        ? live['zeroNetFlowBreakeven5dPct']
        : live['zeroNetFlowBreakeven10dPct'];
    final flatComb = is5d
        ? live['flatInertia5dCombinedB']
        : live['flatInertia10dCombinedB'];

    final cards = <Widget>[
      _buildKpiTile(
        eyebrow: w('$selectedAsset SPOT CLOSE', '$selectedAsset 最新收盘价'),
        value: spot,
        accent: p.text,
        subtext: w(
          'Sys Exposure $posComb · 25D Deleveraging $delev',
          '当前系统化净敞口 $posComb · 近 25 日已去杠杆 $delev',
        ),
      ),
      _buildKpiTile(
        eyebrow: w('CARVER FORECAST (F)', 'CARVER 连续趋势强度 (F)'),
        value: fCarver.toStringAsFixed(2),
        accent: fCarver <= -10
            ? _mint
            : (fCarver < 0 ? _coral : _sky),
        subtext: w(
          '12Y ${pctile.toStringAsFixed(1)}%ile · Binary SMA F = ${fSma.toStringAsFixed(1)}',
          '12 年历史 ${pctile.toStringAsFixed(1)}% 分位 · 传统均线 F = ${fSma.toStringAsFixed(1)}',
        ),
      ),
      _buildKpiTile(
        eyebrow: w('VIX / VIX3M TERM LOCK', 'VIX / VIX3M 期现结构锁'),
        value: vixRatio.toStringAsFixed(3),
        accent: vixInverted ? _amber : _mint,
        subtext: vixInverted
            ? w(
                'BACKWARDATION (${vixClose.toStringAsFixed(2)} / ${vix3mClose.toStringAsFixed(2)}) · Lock ON',
                '期现倒挂（${vixClose.toStringAsFixed(2)} / ${vix3mClose.toStringAsFixed(2)}）· 风控锁激活',
              )
            : w(
                'CONTANGO (${vixClose.toStringAsFixed(2)} / ${vix3mClose.toStringAsFixed(2)}) · Clear',
                '正向升水（${vixClose.toStringAsFixed(2)} / ${vix3mClose.toStringAsFixed(2)}）· 常态波动',
              ),
      ),
      _buildKpiTile(
        eyebrow: w('MARGINAL CONVEXITY (+3%/-3%)', '纯价格边际凸性比 (+3%/-3%)'),
        value: '${asym3.toStringAsFixed(2)}x',
        accent: asym3 >= 1.8 ? _mint : _sky,
        subtext: w(
          '+5% / -5% Convexity: ${asym5.toStringAsFixed(2)}x (Threshold >= 1.80x)',
          '+5% / -5% 边际凸性比：${asym5.toStringAsFixed(2)}x（触发阈值 >= 1.80x）',
        ),
      ),
      _buildKpiTile(
        eyebrow: w(
          '$selectedHorizon \$0B BREAKEVEN FLIP',
          '$selectedHorizon 净流归零翻转价 (\$0B)',
        ),
        value: nullableNumber(flipPx) != null
            ? '${_fmtPrice(flipPx)} (${_fmtSignedPct(flipPct)})'
            : w('Beyond +8%', '高于 +8%'),
        accent: _amber,
        subtext: w(
          '0% Flat Inertia Flow: ${_fmtSignedB(flatComb)} ($selectedHorizon)',
          '0% 横盘惯性净流：${_fmtSignedB(flatComb)}（$selectedHorizon 窗口）',
        ),
      ),
    ];

    if (compact) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            cards[i],
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 1180) {
          final halfW = (c.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < cards.length; i++)
                SizedBox(
                  width: i == cards.length - 1 ? c.maxWidth : halfW,
                  child: cards[i],
                ),
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: cards[i]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildKpiTile({
    required String eyebrow,
    required String value,
    required Color accent,
    required String subtext,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            eyebrow,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.35,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: accent,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtext,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.muted,
              fontSize: 11.2,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignalBeacons({
    required bool compact,
    required Map<String, dynamic> signals,
    required Map<String, dynamic> live,
  }) {
    final primary = asMap(signals['primaryExhaustionBuy']);
    final vixGuard = asMap(signals['vixBackwardationGuardrail']);

    final primaryActive = primary['active'] == true;
    final triggerRank = nullableNumber(primary['triggerRank'])?.round();
    final completedEps = number(primary['completedEpisodes']).round();
    final curF = number(primary['currentF']);
    final curConv3 = number(primary['currentConvexity3Pct']);
    final oos = asMap(primary['oosStats']);
    final h5 = asMap(oos['5D']);
    final h21 = asMap(oos['21D']);
    final h63 = asMap(oos['63D']);

    final vixInverted = vixGuard['vixInverted'] == true;
    final vixRatio = number(vixGuard['vixRatio']);
    final invDropRate = number(vixGuard['inverted10dDropGe2PctRate']);
    final calmDropRate = number(vixGuard['calm10dDropGe2PctRate']);
    final invRvol = number(vixGuard['inverted5dRvolPct']);
    final baseRvol = number(vixGuard['base5dRvolPct']);
    final pVol = vixGuard['pValVol5d'];
    final recentBreach = text(vixGuard['recentCliffBreachDate']);

    final buyCard = Container(
      key: const ValueKey('cta-signal-exhaustion'),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: primaryActive
            ? _mint.withValues(alpha: 0.08)
            : _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: primaryActive
              ? _mint.withValues(alpha: 0.65)
              : _hairline,
          width: primaryActive ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                primaryActive
                    ? Icons.radar_rounded
                    : Icons.track_changes_rounded,
                size: 17,
                color: primaryActive ? _mint : _sky,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  w(
                    'PRIMARY ALPHA SIGNAL · Carver Marginal Short Exhaustion',
                    '核心左侧买点信号 · Carver 深度空头边际耗尽反转',
                  ),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: primaryActive
                      ? _mint.withValues(alpha: 0.2)
                      : _amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: primaryActive ? _mint : _amber.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  primaryActive
                      ? w(
                          'ACTIVE · #${triggerRank ?? (completedEps + 1)} Trigger',
                          '已触发 · 历史第 ${triggerRank ?? (completedEps + 1)} 次',
                        )
                      : w(
                          'DEEP SHORT WATCH (${curConv3.toStringAsFixed(2)}x / 1.80x)',
                          '深度超卖观察（凸性 ${curConv3.toStringAsFixed(2)}x / 1.80x）',
                        ),
                  style: TextStyle(
                    color: primaryActive ? _mint : _amber,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            w(
              'Rule: Carver F <= -10.0 (now ${curF.toStringAsFixed(2)}) AND +3%/-3% Pure Marginal Convexity >= 1.80x (now ${curConv3.toStringAsFixed(2)}x). Captures mechanical selling exhaustion where upside short-covering dwarfs residual downside supply.',
              '触发条件：Carver F <= -10.0（当前 ${curF.toStringAsFixed(2)}）且 +3%/-3% 纯价格边际凸性比 >= 1.80x（当前 ${curConv3.toStringAsFixed(2)}x），识别机械去杠杆尾声的非对称逼空赔率。',
            ),
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _statPill(
                w(
                  '+5D Win ${number(h5['winRatePct']).toStringAsFixed(1)}% (${_fmtSignedPct(h5['meanRetPct'])})',
                  '+5D 胜率 ${number(h5['winRatePct']).toStringAsFixed(1)}%（均值 ${_fmtSignedPct(h5['meanRetPct'])}）',
                ),
                _mint,
              ),
              _statPill(
                w(
                  '+21D Win ${number(h21['winRatePct']).toStringAsFixed(1)}% (${_fmtSignedPct(h21['meanRetPct'])})',
                  '+21D 胜率 ${number(h21['winRatePct']).toStringAsFixed(1)}%（均值 ${_fmtSignedPct(h21['meanRetPct'])}）',
                ),
                _sky,
              ),
              _statPill(
                w(
                  '+63D ${number(h63['winCount']).round()}/${number(h63['nEp']).round()} (${number(h63['winRatePct']).toStringAsFixed(0)}% Win · ${_fmtSignedPct(h63['meanRetPct'])} · p=${_fmtPVal(h63['pValRet'])})',
                  '+63D ${number(h63['winCount']).round()}/${number(h63['nEp']).round()} 胜（胜率 ${number(h63['winRatePct']).toStringAsFixed(0)}% · 均值 ${_fmtSignedPct(h63['meanRetPct'])} · p=${_fmtPVal(h63['pValRet'])}）',
                ),
                _mint,
              ),
            ],
          ),
        ],
      ),
    );

    final vixCard = Container(
      key: const ValueKey('cta-signal-vix-lock'),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: vixInverted
            ? _amber.withValues(alpha: 0.08)
            : _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: vixInverted
              ? _amber.withValues(alpha: 0.65)
              : _hairline,
          width: vixInverted ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                vixInverted
                    ? Icons.warning_amber_rounded
                    : Icons.shield_outlined,
                size: 17,
                color: vixInverted ? _amber : _mint,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  w(
                    'RISK-OFF GUARDRAIL · VIX Backwardation Cliff Lock',
                    '右侧风控护栏 · VIX 期现倒挂破崖波动率锁',
                  ),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: vixInverted
                      ? _amber.withValues(alpha: 0.2)
                      : _mint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: vixInverted ? _amber : _mint.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  vixInverted
                      ? w(
                          'LOCK ACTIVE (${vixRatio.toStringAsFixed(3)} >= 1.00)',
                          '倒挂锁开启（${vixRatio.toStringAsFixed(3)} >= 1.00）',
                        )
                      : w(
                          'CONTANGO CLEAR (${vixRatio.toStringAsFixed(3)})',
                          '常态升水（${vixRatio.toStringAsFixed(3)}）',
                        ),
                  style: TextStyle(
                    color: vixInverted ? _amber : _mint,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            w(
              'Never short an unconditional CTA cliff breach in VIX contango (high V-whipsaw risk). When VIX/VIX3M >= 1.00, Vol-Control + CTA deleveraging resonance triples cascade probability — cap gross beta & scale in rather than chasing leverage.',
              '严禁在 VIX 正向升水期盲目追空破位（极易遭遇 V 型逼空打脸）；仅当 VIX/VIX3M >= 1.00 期现倒挂时，波动率基金与 CTA 抛盘形成流动性共振，须严控总杠杆并分批左侧承接。',
            ),
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _statPill(
                w(
                  '10D Drop >= 2%: ${calmDropRate.toStringAsFixed(1)}% -> ${invDropRate.toStringAsFixed(1)}%',
                  '10D 续跌 >= 2% 概率：${calmDropRate.toStringAsFixed(1)}% -> ${invDropRate.toStringAsFixed(1)}%',
                ),
                _amber,
              ),
              _statPill(
                w(
                  '5D RVol: ${baseRvol.toStringAsFixed(1)}% -> ${invRvol.toStringAsFixed(1)}% (p=${_fmtPVal(pVol)})',
                  '5D 实现波动率：${baseRvol.toStringAsFixed(1)}% -> ${invRvol.toStringAsFixed(1)}%（p=${_fmtPVal(pVol)}）',
                ),
                _coral,
              ),
              if (recentBreach.isNotEmpty)
                _statPill(
                  w(
                    'Recent Cliff Alert: $recentBreach',
                    '近期破崖预警日：$recentBreach',
                  ),
                  _lilac,
                ),
            ],
          ),
        ],
      ),
    );

    if (compact) {
      return Column(
        children: [
          buyCard,
          const SizedBox(height: 10),
          vixCard,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: buyCard),
        const SizedBox(width: 12),
        Expanded(child: vixCard),
      ],
    );
  }

  Widget _statPill(String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildModuleASurfaceAndMatrix({
    required bool compact,
    required bool wide,
    required Map<String, dynamic> assetData,
    required Map<String, dynamic> live,
  }) {
    final curve = asList(assetData['flowCurve']);
    final is5d = selectedHorizon == '5D';
    final matrix = asList(is5d ? assetData['matrix5d'] : assetData['matrix10d']);
    final flipPct = nullableNumber(
      is5d
          ? live['zeroNetFlowBreakeven5dPct']
          : live['zeroNetFlowBreakeven10dPct'],
    );
    final flipPx = nullableNumber(
      is5d
          ? live['zeroNetFlowBreakeven5dPx']
          : live['zeroNetFlowBreakeven10dPx'],
    );

    final activeIdx = (hoverCurveIndex >= 0 && hoverCurveIndex < curve.length)
        ? hoverCurveIndex
        : curve.indexWhere((pt) => number(pt['movePct']).abs() < 1e-6);
    final inspectPt = (activeIdx >= 0 && activeIdx < curve.length)
        ? curve[activeIdx]
        : const <String, dynamic>{};

    final margKey = is5d ? 'marginalCarver5dB' : 'marginalCarver10dB';
    final combKey = is5d ? 'combined5dB' : 'combined10dB';
    final carvKey = is5d ? 'carver5dB' : 'carver10dB';
    final vcKey = is5d ? 'vc5dB' : 'vc10dB';

    final chartCard = Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w(
              'A. Dual-Track Price-Shock Flow Sensitivity Curve ($selectedAsset · $selectedHorizon)',
              'A. 价格冲击双轨资金流敏感度曲线（$selectedAsset · $selectedHorizon）',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            w(
              'Solid curve isolates Pure Price Marginal Impulse vs 0% Flat; dashed curve shows Combined Net Flow (incl. T-3 inertia & Vol-Control).',
              '实线剥离横盘惯性、刻画纯价格变动激发的边际冲量；虚线展示含 T-3 缓冲惯性与波动率目标基金在内的系统化总净流向。',
            ),
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _legendItem(
                color: _mint,
                dashed: false,
                label: w(
                  'Pure Marginal Impulse vs 0% Flat (\$B)',
                  '纯价格边际冲量（相对 0% 横盘，\$B）',
                ),
              ),
              _legendItem(
                color: _sky,
                dashed: true,
                label: w(
                  'Combined Net Systematic Flow (\$B)',
                  '系统化合并总净流（CTA + Vol-Control，\$B）',
                ),
              ),
              if (flipPx != null && flipPct != null)
                _legendItem(
                  color: _amber,
                  dashed: false,
                  diamond: true,
                  label: w(
                    '\$0B Flip: ${_fmtPrice(flipPx)} (${_fmtSignedPct(flipPct)})',
                    '\$0B 净流归零点：${_fmtPrice(flipPx)}（${_fmtSignedPct(flipPct)}）',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _hairline),
            ),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                Text(
                  w(
                    'Shock: ${_fmtSignedPct(inspectPt['movePct'])} (${_fmtPrice(inspectPt['targetPrice'])})',
                    '冲击幅度：${_fmtSignedPct(inspectPt['movePct'])}（目标价 ${_fmtPrice(inspectPt['targetPrice'])}）',
                  ),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  w(
                    'Pure Marginal: ${_fmtSignedB(inspectPt[margKey])}',
                    '纯边际冲量：${_fmtSignedB(inspectPt[margKey])}',
                  ),
                  style: TextStyle(
                    color: number(inspectPt[margKey]) >= 0 ? _mint : _coral,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  w(
                    'Combined Net: ${_fmtSignedB(inspectPt[combKey])}',
                    '合并总净流：${_fmtSignedB(inspectPt[combKey])}',
                  ),
                  style: const TextStyle(
                    color: _sky,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  w(
                    'Carver CTA: ${_fmtSignedB(inspectPt[carvKey])} · Vol-Ctrl: ${_fmtSignedB(inspectPt[vcKey])}',
                    'Carver CTA：${_fmtSignedB(inspectPt[carvKey])} · 波动率基金：${_fmtSignedB(inspectPt[vcKey])}',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: compact ? 245 : 295,
            child: LayoutBuilder(
              builder: (context, box) {
                void updateHover(Offset localPos) {
                  if (curve.isEmpty) return;
                  const padLeft = 52.0;
                  const padRight = 16.0;
                  final plotW = math.max(1.0, box.maxWidth - padLeft - padRight);
                  final rel = ((localPos.dx - padLeft) / plotW).clamp(0.0, 1.0);
                  final idx = (rel * (curve.length - 1)).round();
                  if (idx != hoverCurveIndex) {
                    setState(() => hoverCurveIndex = idx);
                  }
                }

                return MouseRegion(
                  onHover: (ev) => updateHover(ev.localPosition),
                  onExit: (_) => setState(() => hoverCurveIndex = -1),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (ev) => updateHover(ev.localPosition),
                    onHorizontalDragUpdate: (ev) =>
                        updateHover(ev.localPosition),
                    child: CustomPaint(
                      key: const ValueKey('cta-dual-track-curve-canvas'),
                      size: Size(box.maxWidth, compact ? 245 : 295),
                      painter: _CtaDualTrackCurvePainter(
                        curve: curve,
                        marginalKey: margKey,
                        combinedKey: combKey,
                        flipPct: flipPct,
                        hoverIndex: activeIdx,
                        textColor: p.text,
                        mutedColor: p.muted,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );

    final matrixCard = Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w(
              'Exact Price-Trigger Flow Matrix ($selectedAsset · $selectedHorizon)',
              '精确点位触发资金流矩阵（$selectedAsset · $selectedHorizon）',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            w(
              'Amber row pinpoints exact \$0B net-flow breakeven price where upside short-covering offsets T-3 inertia.',
              '琥珀色高亮行标定空头回补完全抵消横盘惯性抛盘的 \$0B 净流翻转目标价。',
            ),
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 520),
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(1.25),
                  1: FlexColumnWidth(1.15),
                  2: FlexColumnWidth(1.25),
                  3: FlexColumnWidth(1.15),
                  4: FlexColumnWidth(1.10),
                  5: FlexColumnWidth(1.25),
                  6: FlexColumnWidth(0.90),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: _hairline)),
                    ),
                    children: [
                      _th(w('Move', '涨跌幅'), alignLeft: true),
                      _th(w('Price', '目标价')),
                      _th(w('Marginal', '纯边际')),
                      _th(w('Carver CTA', 'CTA 流')),
                      _th(w('Vol-Ctrl', '波动率流')),
                      _th(w('Combined', '合并净流')),
                      _th(w('End F', '期末 F')),
                    ],
                  ),
                  for (final row in matrix) _buildMatrixTableRow(row),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (!wide) {
      return Column(
        children: [
          chartCard,
          const SizedBox(height: 14),
          matrixCard,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 11, child: chartCard),
        const SizedBox(width: 14),
        Expanded(flex: 10, child: matrixCard),
      ],
    );
  }

  TableRow _buildMatrixTableRow(Map<String, dynamic> row) {
    final isBreakeven = row['isBreakevenRow'] == true;
    final isBaseline = row['isBaselineRow'] == true;
    final movePct = number(row['movePct']);
    final margB = number(row['marginalCarverFlowB']);
    final combB = number(row['combinedFlowB']);

    final bg = isBreakeven
        ? _amber.withValues(alpha: 0.14)
        : (isBaseline
              ? _surfaceRaised
              : Colors.transparent);

    final moveLabel = isBreakeven
        ? '${_fmtSignedPct(movePct)} ★'
        : (isBaseline ? '0.00% (Flat)' : _fmtSignedPct(movePct));

    return TableRow(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          bottom: BorderSide(
            color: isBreakeven
                ? _amber.withValues(alpha: 0.45)
                : _hairline.withValues(alpha: 0.55),
          ),
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: Text(
            moveLabel,
            style: TextStyle(
              color: isBreakeven
                  ? _amber
                  : (isBaseline ? p.text : p.muted),
              fontSize: 11.5,
              fontWeight: (isBreakeven || isBaseline)
                  ? FontWeight.w800
                  : FontWeight.w600,
            ),
          ),
        ),
        _td(_fmtPrice(row['targetPrice']), highlight: isBreakeven ? _amber : p.text),
        _td(
          _fmtSignedB(margB),
          highlight: margB > 0.05 ? _mint : (margB < -0.05 ? _coral : p.muted),
          bold: true,
        ),
        _td(_fmtSignedB(row['carverCtaFlowB'])),
        _td(_fmtSignedB(row['volControlFlowB'])),
        _td(
          isBreakeven ? '\$0.00B' : _fmtSignedB(combB),
          highlight: isBreakeven
              ? _amber
              : (combB > 0.05 ? _mint : (combB < -0.05 ? _sky : p.text)),
          bold: true,
        ),
        _td(number(row['projectedCarverForecast']).toStringAsFixed(1)),
      ],
    );
  }

  Widget _th(String label, {bool alignLeft = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      child: Text(
        label,
        textAlign: alignLeft ? TextAlign.left : TextAlign.right,
        style: TextStyle(
          color: p.muted,
          fontSize: 10.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _td(String value, {Color? highlight, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      child: Text(
        value,
        textAlign: TextAlign.right,
        style: TextStyle(
          color: highlight ?? p.muted,
          fontSize: 11.5,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _legendItem({
    required Color color,
    required bool dashed,
    required String label,
    bool diamond = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (diamond)
          Icon(Icons.diamond_rounded, size: 12, color: color)
        else
          Container(
            width: 18,
            height: 2.5,
            decoration: BoxDecoration(
              color: dashed ? Colors.transparent : color,
              border: dashed
                  ? Border(bottom: BorderSide(color: color, width: 2))
                  : null,
            ),
          ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: p.muted,
            fontSize: 11.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildModuleBScorecardAndTimeline({
    required bool compact,
    required bool wide,
    required Map<String, dynamic> assetData,
    required Map<String, dynamic> evalWindow,
  }) {
    final score = asMap(assetData['empiricalScorecard']);
    final r2 = number(score['flowSurfaceEndpointR2']);
    final uncond = asMap(score['unconditionalCliffBreach']);
    final uncondCarver = asMap(uncond['carver']);
    final uncondSma = asMap(uncond['sma']);
    final whipCarver = asMap(uncondCarver['whipsaw']);
    final whipSma = asMap(uncondSma['whipsaw']);
    final c21 = asMap(asMap(uncondCarver['horizons'])['21D']);

    final vixCliff = asMap(score['vixBackwardationCliff']);
    final vixInv = asMap(vixCliff['inverted']);
    final vixCalm = asMap(vixCliff['contango']);
    final inv5 = asMap(asMap(vixInv['horizons'])['5D']);
    final whipInv = asMap(vixInv['whipsaw']);
    final whipCalm = asMap(vixCalm['whipsaw']);

    final alpha = asMap(score['shortExhaustionAlpha']);
    final carvMarg = asMap(alpha['carverMarginal']);
    final smaExh = asMap(alpha['smaExhaustion']);
    final cm63 = asMap(asMap(carvMarg['horizons'])['63D']);
    final sm63 = asMap(asMap(smaExh['horizons'])['63D']);

    final timeline = asList(assetData['historicalTimeline']);
    final selectedEp = timeline.firstWhere(
      (e) => text(e['id']) == selectedEpisodeId,
      orElse: () => timeline.isNotEmpty ? timeline.last : const <String, dynamic>{},
    );

    final startDt = text(evalWindow['start'], '2014-01-02');
    final endDt = text(evalWindow['end'], '2026-11-20');
    final nDays = number(evalWindow['tradingDays']).round();

    final verdictCards = <Widget>[
      _buildVerdictCard(
        badge: w('FORBIDDEN MYTH · p = ${_fmtPVal(c21['pValRet'])}', '证伪陷阱 · p = ${_fmtPVal(c21['pValRet'])}'),
        badgeColor: _coral,
        title: w(
          '1. Never Short Unconditional Breakdowns',
          '1. 严禁无条件追空破位“抛压崖”',
        ),
        body: w(
          'Shorting mechanical CTA cliff breaches or SMA50/100 crosses fails OOS: ${number(whipCarver['whipsawRally21dGt2PctRate']).toStringAsFixed(1)}% (Carver) and ${number(whipSma['whipsawRally21dGt2PctRate']).toStringAsFixed(1)}% (SMA) suffer >+2% V-reversal squeezes within 21D.',
          '盲目在破位日追空极易被机构限价买盘反杀：Carver 破崖后 21 日内遭遇 >+2% V 型逼空的比例高达 ${number(whipCarver['whipsawRally21dGt2PctRate']).toStringAsFixed(1)}%（传统均线破位更高达 ${number(whipSma['whipsawRally21dGt2PctRate']).toStringAsFixed(1)}%），无显著做空超额收益。',
        ),
      ),
      _buildVerdictCard(
        badge: w('VOLATILITY FILTER · p = ${_fmtPVal(inv5['pValVol'])}', '波动率分水岭 · p = ${_fmtPVal(inv5['pValVol'])}'),
        badgeColor: _amber,
        title: w(
          '2. VIX Backwardation Separates Cascades',
          '2. VIX 期现倒挂区分真雪崩与假摔',
        ),
        body: w(
          'Conditioning cliff breaches on VIX/VIX3M >= 1.00 lifts 10D >=2% follow-through drops from ${number(whipCalm['furtherDrop10dGe2PctRate']).toStringAsFixed(1)}% to ${number(whipInv['furtherDrop10dGe2PctRate']).toStringAsFixed(1)}% and 5D RVol to ${number(inv5['fwdRvolMeanPct']).toStringAsFixed(1)}%.',
          '叠加 VIX/VIX3M >= 1.00 期现倒挂过滤后，破崖后 10 日续跌 >=2% 概率从升水期的 ${number(whipCalm['furtherDrop10dGe2PctRate']).toStringAsFixed(1)}% 跃升至 ${number(whipInv['furtherDrop10dGe2PctRate']).toStringAsFixed(1)}%，5D 实现波动率飙升至 ${number(inv5['fwdRvolMeanPct']).toStringAsFixed(1)}%。',
        ),
      ),
      _buildVerdictCard(
        badge: w('PROVEN ALPHA · p = ${_fmtPVal(cm63['pValRet'])}', '高显著性买点 · p = ${_fmtPVal(cm63['pValRet'])}'),
        badgeColor: _mint,
        title: w(
          '3. Carver Continuous Exhaustion Beats SMA',
          '3. Carver 边际耗尽完胜传统均线择时',
        ),
        body: w(
          'Carver marginal exhaustion delivers ${number(cm63['winCount']).round()}/${number(cm63['nEp']).round()} (${number(cm63['winRatePct']).toStringAsFixed(0)}%) +63D win rate and ${_fmtSignedPct(cm63['meanRetPct'])} mean return vs noisy binary SMA exhaustion (p=${_fmtPVal(sm63['pValRet'])}).',
          'Carver 连续边际耗尽信号在 +63D 窗口录得 ${number(cm63['winCount']).round()}/${number(cm63['nEp']).round()}（${number(cm63['winRatePct']).toStringAsFixed(0)}% 胜率、均值 ${_fmtSignedPct(cm63['meanRetPct'])}），显著优于频繁反复的传统均线（p=${_fmtPVal(sm63['pValRet'])}）。',
        ),
      ),
    ];

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'B. 12-Year Out-of-Sample Empirical Scorecard & Battleground Timeline ($selectedAsset)',
                  'B. 12 年样本外实证计分卡与六大历史极端行情复盘（$selectedAsset）',
                ),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              _statPill(
                w(
                  '$startDt -> $endDt ($nDays Days) · 5D Flow Surface R² = ${(r2 * 100).toStringAsFixed(1)}%',
                  '$startDt 至 $endDt（$nDays 交易日）· 5D 资金流曲面拟合优度 R² = ${(r2 * 100).toStringAsFixed(1)}%',
                ),
                _sky,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!wide)
            Column(
              children: [
                for (var i = 0; i < verdictCards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  verdictCards[i],
                ],
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < verdictCards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: verdictCards[i]),
                ],
              ],
            ),
          const SizedBox(height: 16),
          Text(
            w(
              'Interactive Regime Battlegrounds (incl. 2022 Slow-Bear Model Caveat)',
              '六大历史典型战役逐日检验（含 2022 加息慢熊盲区诚实披露）',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ep in timeline) _buildEpisodeChip(ep),
            ],
          ),
          if (selectedEp.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSelectedEpisodeDetail(selectedEp, compact: compact),
          ],
        ],
      ),
    );
  }

  Widget _buildVerdictCard({
    required String badge,
    required Color badgeColor,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: badgeColor,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              color: p.text,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              color: p.muted,
              fontSize: 11.8,
              height: 1.42,
            ),
          ),
        ],
      ),
    );
  }

  Color _verdictColor(String verdict) {
    switch (verdict) {
      case 'HIT':
      case 'LIVE_ACTIVE':
        return _mint;
      case 'CAVEAT':
        return _coral;
      case 'PARTIAL':
      case 'LIVE_WATCH':
        return _amber;
      default:
        return _sky;
    }
  }

  String _verdictLabel(String verdict) {
    switch (verdict) {
      case 'HIT':
        return w('VALIDATED HIT', '精准命中');
      case 'CAVEAT':
        return w('SLOW-BEAR CAVEAT', '慢熊盲区披露');
      case 'PARTIAL':
        return w('CLIFF HIT · V-BOUNCE', '预警命中 · 未触极值');
      case 'LIVE_ACTIVE':
        return w('LIVE · BUY TRIGGERED', '实时 · 买点已触发');
      case 'LIVE_WATCH':
        return w('LIVE · OVERSOLD WATCH', '实时 · 深度超卖观察');
      default:
        return verdict;
    }
  }

  Widget _buildEpisodeChip(Map<String, dynamic> ep) {
    final id = text(ep['id']);
    final selected = id == selectedEpisodeId;
    final verdict = text(ep['verdict']);
    final accent = _verdictColor(verdict);
    return InkWell(
      key: ValueKey('cta-episode-$id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => selectedEpisodeId = id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.16) : _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? accent : _hairline,
            width: selected ? 1.3 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              w(text(ep['titleEn']), text(ep['titleZh'])),
              style: TextStyle(
                color: selected ? p.text : p.muted,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedEpisodeDetail(
    Map<String, dynamic> ep, {
    required bool compact,
  }) {
    final verdict = text(ep['verdict']);
    final accent = _verdictColor(verdict);
    final cliffDates = (ep['cliffBreachDates'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final exhDates = (ep['exhaustionBuyDates'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();

    return Container(
      key: ValueKey('cta-episode-detail-${text(ep['id'])}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(text(ep['titleEn']), text(ep['titleZh'])),
                style: TextStyle(
                  color: p.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              _statPill(_verdictLabel(verdict), accent),
              Text(
                text(ep['window']),
                style: TextStyle(color: p.muted, fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            w(text(ep['summaryEn']), text(ep['summaryZh'])),
            style: TextStyle(color: p.text, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              _statPill(
                w(
                  'Window Max DD: ${_fmtSignedPct(ep['windowMaxDdPct'])}',
                  '区间最大回撤：${_fmtSignedPct(ep['windowMaxDdPct'])}',
                ),
                _coral,
              ),
              _statPill(
                w(
                  'Sys Deleveraging: ${_fmtSignedB(ep['deleveragingB'])}',
                  '系统化去杠杆规模：${_fmtSignedB(ep['deleveragingB'])}',
                ),
                _sky,
              ),
              _statPill(
                w(
                  'Min Carver F: ${number(ep['minCarverForecast']).toStringAsFixed(2)}',
                  '最低 Carver F：${number(ep['minCarverForecast']).toStringAsFixed(2)}',
                ),
                _lilac,
              ),
              _statPill(
                cliffDates.isEmpty
                    ? w('Cliff Alerts: None', '破崖预警日：无')
                    : w(
                        'Cliff Alerts: ${cliffDates.join(", ")}',
                        '破崖预警日：${cliffDates.join("、")}',
                      ),
                _amber,
              ),
              _statPill(
                exhDates.isEmpty
                    ? w('Exhaustion Buys: None', '空头耗尽买点：未触发')
                    : w(
                        'Exhaustion Buys: ${exhDates.join(", ")}',
                        '空头耗尽买点日：${exhDates.join("、")}',
                      ),
                _mint,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMethodologyDrawer({
    required bool compact,
    required bool wide,
    required Map<String, dynamic> assetData,
    required Map<String, dynamic> pitScale,
    required Map<String, dynamic> evalWindow,
  }) {
    final quarters = asList(pitScale['quarters']);
    final reps = (pitScale['representativeInstitutions'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final ewmacRows = asList(assetData['ewmacComponents']);
    final smaRows = asList(assetData['smaComponents']);
    final q14 = number(pitScale['q1_2014CtaTrendCoreB']);
    final qLatest = number(pitScale['latestCtaTrendCoreB']);
    final mult = number(pitScale['scaleGrowthMultiplier']);
    final latestQuarter = text(pitScale['latestQuarter']);

    return Container(
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('cta-methodology-toggle'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => showMethodology = !showMethodology),
            child: Padding(
              padding: EdgeInsets.all(compact ? 14 : 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.account_balance_outlined,
                    size: 18,
                    color: _mint,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w(
                            'Methodology, 6-Speed EWMAC Sub-Signals & 31-Institution SEC Form 13F PIT Calibration',
                            '算法架构、六速 EWMAC 子信号明细与 31 家 SEC 13F 趋势机构规模校准（点击展开）',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          w(
                            '2014-Q1 \$${q14.toStringAsFixed(1)}B -> $latestQuarter \$${qLatest.toStringAsFixed(1)}B (${mult.toStringAsFixed(2)}x expansion · strict T+45 statutory filing lag)',
                            '2014-Q1 \$${q14.toStringAsFixed(1)}B -> $latestQuarter \$${qLatest.toStringAsFixed(1)}B（扩容 ${mult.toStringAsFixed(2)} 倍 · 严格执行 T+45 法定披露滞后）',
                          ),
                          style: TextStyle(color: p.muted, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    showMethodology
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: p.muted,
                  ),
                ],
              ),
            ),
          ),
          if (showMethodology) ...[
            const Divider(height: 1, color: _hairline),
            Padding(
              padding: EdgeInsets.all(compact ? 14 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'SEC Form 13F Point-in-Time Trend-Following Core Equity Scale (54 Quarters · 2014–2026)',
                      '31 家趋势跟踪/系统化宏观机构 SEC 13F 权益底仓时点演进（54 个季度 · 2014–2026）',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 145,
                    child: CustomPaint(
                      key: const ValueKey('cta-13f-pit-scale-canvas'),
                      size: const Size(double.infinity, 145),
                      painter: _Cta13fScaleBarPainter(
                        quarters: quarters,
                        mutedColor: p.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    w(
                      'Representative Filers: ${reps.join(" · ")}',
                      '代表性校准机构：${reps.join(" · ")}',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.3, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  if (!wide)
                    Column(
                      children: [
                        _buildEwmacBreakdownTable(ewmacRows),
                        const SizedBox(height: 12),
                        _buildSmaBreakdownTable(smaRows),
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 12,
                          child: _buildEwmacBreakdownTable(ewmacRows),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 10,
                          child: _buildSmaBreakdownTable(smaRows),
                        ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  Text(
                    w(
                      'Provenance & Specification: Continuous forecast F combines EWMAC(2/8, 4/16, 8/32, 16/64, 32/128, 64/256) normalized by blended 36D/2520D volatility, scaled by FDM=1.26, capped at [-20, +20], and executed through a 10% no-trade buffer with 3-day smoothing alongside RV20/RV60 volatility-targeting funds. Calibrated strictly point-in-time from public SEC Form 13F filings (45-day statutory lag), U.S. exchange daily closes, and CBOE VIX/VIX3M term structure.',
                      '数据溯源与模型规范：连续信号 F 融合 EWMAC(2/8, 4/16, 8/32, 16/64, 32/128, 64/256) 六组跨周期指数均线，经 36D/2520D 混合波动率标准化与组合乘数 FDM=1.26 缩放并截断于 [-20, +20]，叠加 10% 惯性免交易缓冲带、3 日平滑执行及 RV20/RV60 波动率目标基金联动。全程采用 SEC Form 13F 公开申报（严格遵守 T+45 法定披露滞后）、美股交易所日线收盘及 CBOE VIX/VIX3M 期限结构校准，零前视偏差。',
                    ),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 11.2,
                      height: 1.42,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEwmacBreakdownTable(List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w(
              'Rob Carver 6-Speed EWMAC Sub-Forecasts ($selectedAsset)',
              'Rob Carver 六速 EWMAC 子信号与单日翻转价（$selectedAsset）',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.35),
              1: FlexColumnWidth(1.05),
              2: FlexColumnWidth(1.05),
              3: FlexColumnWidth(0.95),
              4: FlexColumnWidth(1.30),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _hairline)),
                ),
                children: [
                  _th(w('Rule', '规则'), alignLeft: true),
                  _th(w('Fast EMA', '快线')),
                  _th(w('Slow EMA', '慢线')),
                  _th(w('Sub F', '子信号')),
                  _th(w('1D Flip', '单日翻转价')),
                ],
              ),
              for (final r in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 6,
                      ),
                      child: Text(
                        text(r['rule']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 11.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _td(_fmtPrice(r['emaFast'])),
                    _td(_fmtPrice(r['emaSlow'])),
                    _td(
                      number(r['forecast']).toStringAsFixed(2),
                      highlight: number(r['forecast']) >= 0 ? _mint : _coral,
                      bold: true,
                    ),
                    _td(
                      '${_fmtPrice(r['flip1dPrice'])} (${_fmtSignedPct(r['pctTo1dFlip'], decimals: 1)})',
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmaBreakdownTable(List<Map<String, dynamic>> rows) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w(
              'Traditional 5-Window Binary SMA Benchmark ($selectedAsset)',
              '传统五周期二元均线对照组状态（$selectedAsset）',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.1),
              1: FlexColumnWidth(0.85),
              2: FlexColumnWidth(1.15),
              3: FlexColumnWidth(1.15),
              4: FlexColumnWidth(0.95),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _hairline)),
                ),
                children: [
                  _th(w('Window', '均线'), alignLeft: true),
                  _th(w('Weight', '权重')),
                  _th(w('Level', '点位')),
                  _th(w('Distance', '偏离度')),
                  _th(w('State', '方向')),
                ],
              ),
              for (final r in rows)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 6,
                      ),
                      child: Text(
                        text(r['ma']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 11.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _td('${(number(r['weight']) * 100).toStringAsFixed(0)}%'),
                    _td(_fmtPrice(r['level'])),
                    _td(_fmtSignedPct(r['pctDistanceFromSpot'])),
                    _td(
                      text(r['state']) == 'LONG'
                          ? w('LONG', '多头')
                          : w('SHORT', '空头'),
                      highlight: text(r['state']) == 'LONG' ? _mint : _coral,
                      bold: true,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CtaDualTrackCurvePainter extends CustomPainter {
  const _CtaDualTrackCurvePainter({
    required this.curve,
    required this.marginalKey,
    required this.combinedKey,
    required this.flipPct,
    required this.hoverIndex,
    required this.textColor,
    required this.mutedColor,
  });

  final List<Map<String, dynamic>> curve;
  final String marginalKey;
  final String combinedKey;
  final double? flipPct;
  final int hoverIndex;
  final Color textColor;
  final Color mutedColor;

  static const Color _hairline = Color(0xFF25313B);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _amber = Color(0xFFF2BC60);
  static const Color _coral = Color(0xFFEC8C98);

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.length < 2) return;
    const padLeft = 52.0;
    const padRight = 16.0;
    const padTop = 14.0;
    const padBottom = 28.0;

    final plotW = math.max(1.0, size.width - padLeft - padRight);
    final plotH = math.max(1.0, size.height - padTop - padBottom);
    final rect = Rect.fromLTWH(padLeft, padTop, plotW, plotH);

    final minX = number(curve.first['movePct']);
    final maxX = number(curve.last['movePct']);
    final spanX = math.max(1e-6, maxX - minX);

    var minY = -10.0;
    var maxY = 10.0;
    for (final pt in curve) {
      final m = number(pt[marginalKey]);
      final c = number(pt[combinedKey]);
      if (m < minY) minY = m;
      if (c < minY) minY = c;
      if (m > maxY) maxY = m;
      if (c > maxY) maxY = c;
    }
    final padY = math.max(4.0, (maxY - minY) * 0.12);
    minY -= padY;
    maxY += padY;
    final spanY = math.max(1e-6, maxY - minY);

    double xOf(double pct) => rect.left + ((pct - minX) / spanX) * rect.width;
    double yOf(double valB) =>
        rect.bottom - ((valB - minY) / spanY) * rect.height;

    final gridPaint = Paint()
      ..color = _hairline.withValues(alpha: 0.7)
      ..strokeWidth = 1.0;

    for (var i = 0; i <= 4; i++) {
      final v = minY + (spanY * i / 4.0);
      final y = yOf(v);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), gridPaint);
      final label = '${v >= 0 ? "+" : "-"}\$${v.abs().toStringAsFixed(0)}B';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: mutedColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left - tp.width - 6, y - tp.height / 2));
    }

    for (final tickPct in const [-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 6.0]) {
      if (tickPct < minX || tickPct > maxX) continue;
      final x = xOf(tickPct);
      canvas.drawLine(
        Offset(x, rect.top),
        Offset(x, rect.bottom),
        Paint()
          ..color = tickPct == 0.0
              ? mutedColor.withValues(alpha: 0.45)
              : _hairline.withValues(alpha: 0.45)
          ..strokeWidth = tickPct == 0.0 ? 1.2 : 0.8,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '${tickPct > 0 ? "+" : ""}${tickPct.toStringAsFixed(0)}%',
          style: TextStyle(
            color: tickPct == 0.0 ? textColor : mutedColor,
            fontSize: 10,
            fontWeight: tickPct == 0.0 ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, rect.bottom + 6));
    }

    if (minY <= 0 && maxY >= 0) {
      final yZero = yOf(0.0);
      canvas.drawLine(
        Offset(rect.left, yZero),
        Offset(rect.right, yZero),
        Paint()
          ..color = _amber.withValues(alpha: 0.55)
          ..strokeWidth = 1.2,
      );
    }

    // Combined Net Flow dashed curve (Sky Blue)
    final combPts = [
      for (final pt in curve)
        Offset(xOf(number(pt['movePct'])), yOf(number(pt[combinedKey]))),
    ];
    final dashPaint = Paint()
      ..color = _sky
      ..strokeWidth = 2.1
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < combPts.length - 1; i++) {
      final a = combPts[i];
      final b = combPts[i + 1];
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      canvas.drawLine(a, mid, dashPaint);
    }

    // Pure Price Marginal Impulse solid curve (Coral on negative shock, Mint on positive shock)
    final negPath = Path();
    final posPath = Path();
    var negStarted = false;
    var posStarted = false;
    for (final pt in curve) {
      final pct = number(pt['movePct']);
      final o = Offset(xOf(pct), yOf(number(pt[marginalKey])));
      if (pct <= 0.001) {
        if (!negStarted) {
          negPath.moveTo(o.dx, o.dy);
          negStarted = true;
        } else {
          negPath.lineTo(o.dx, o.dy);
        }
      }
      if (pct >= -0.001) {
        if (!posStarted) {
          posPath.moveTo(o.dx, o.dy);
          posStarted = true;
        } else {
          posPath.lineTo(o.dx, o.dy);
        }
      }
    }
    canvas.drawPath(
      negPath,
      Paint()
        ..color = _coral
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      posPath,
      Paint()
        ..color = _mint
        ..strokeWidth = 2.8
        ..style = PaintingStyle.stroke,
    );

    // Highlighted Amber Diamond at $0B Net-Flow Breakeven Flip
    if (flipPct != null && flipPct! >= minX && flipPct! <= maxX) {
      final fx = xOf(flipPct!);
      final fy = yOf(0.0);
      final diamond = Path()
        ..moveTo(fx, fy - 6.5)
        ..lineTo(fx + 6.5, fy)
        ..lineTo(fx, fy + 6.5)
        ..lineTo(fx - 6.5, fy)
        ..close();
      canvas.drawPath(diamond, Paint()..color = _amber);
      canvas.drawPath(
        diamond,
        Paint()
          ..color = const Color(0xFF080B0F)
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke,
      );
    }

    // Interactive hover crosshair & dots
    if (hoverIndex >= 0 && hoverIndex < curve.length) {
      final pt = curve[hoverIndex];
      final hx = xOf(number(pt['movePct']));
      final hyMarg = yOf(number(pt[marginalKey]));
      final hyComb = yOf(number(pt[combinedKey]));

      canvas.drawLine(
        Offset(hx, rect.top),
        Offset(hx, rect.bottom),
        Paint()
          ..color = textColor.withValues(alpha: 0.35)
          ..strokeWidth = 1.0,
      );
      canvas.drawCircle(
        Offset(hx, hyComb),
        4.2,
        Paint()..color = _sky,
      );
      canvas.drawCircle(
        Offset(hx, hyMarg),
        4.8,
        Paint()..color = number(pt[marginalKey]) >= 0 ? _mint : _coral,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CtaDualTrackCurvePainter oldDelegate) {
    return oldDelegate.curve != curve ||
        oldDelegate.marginalKey != marginalKey ||
        oldDelegate.combinedKey != combinedKey ||
        oldDelegate.flipPct != flipPct ||
        oldDelegate.hoverIndex != hoverIndex;
  }
}

class _Cta13fScaleBarPainter extends CustomPainter {
  const _Cta13fScaleBarPainter({
    required this.quarters,
    required this.mutedColor,
  });

  final List<Map<String, dynamic>> quarters;
  final Color mutedColor;

  static const Color _hairline = Color(0xFF25313B);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);

  @override
  void paint(Canvas canvas, Size size) {
    if (quarters.isEmpty) return;
    const padLeft = 46.0;
    const padRight = 10.0;
    const padTop = 10.0;
    const padBottom = 22.0;

    final plotW = math.max(1.0, size.width - padLeft - padRight);
    final plotH = math.max(1.0, size.height - padTop - padBottom);
    final rect = Rect.fromLTWH(padLeft, padTop, plotW, plotH);

    var maxB = 100.0;
    for (final q in quarters) {
      final v = number(q['ctaTrendCoreB']);
      if (v > maxB) maxB = v;
    }
    maxB *= 1.08;

    for (var i = 0; i <= 2; i++) {
      final v = maxB * (i / 2.0);
      final y = rect.bottom - (v / maxB) * rect.height;
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()
          ..color = _hairline.withValues(alpha: 0.65)
          ..strokeWidth = 0.9,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '\$${v.toStringAsFixed(0)}B',
          style: TextStyle(color: mutedColor, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left - tp.width - 5, y - tp.height / 2));
    }

    final n = quarters.length;
    final slotW = rect.width / n;
    final barW = math.max(2.0, slotW * 0.72);

    for (var i = 0; i < n; i++) {
      final v = number(quarters[i]['ctaTrendCoreB']);
      final h = (v / maxB) * rect.height;
      final x = rect.left + i * slotW + (slotW - barW) / 2;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, rect.bottom - h, barW, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(
        r,
        Paint()..color = i == n - 1 ? _mint : _sky.withValues(alpha: 0.72),
      );
    }

    final midIdx = (n / 2).floor();
    for (final idx in [0, midIdx, n - 1]) {
      if (idx < 0 || idx >= n) continue;
      final qDt = text(quarters[idx]['quarterDate']);
      final x = rect.left + (idx + 0.5) * slotW;
      final tp = TextPainter(
        text: TextSpan(
          text: qDt.length >= 7 ? qDt.substring(0, 7) : qDt,
          style: TextStyle(color: mutedColor, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final clampedX = (x - tp.width / 2).clamp(
        rect.left,
        rect.right - tp.width,
      );
      tp.paint(canvas, Offset(clampedX, rect.bottom + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _Cta13fScaleBarPainter oldDelegate) {
    return oldDelegate.quarters != quarters;
  }
}
