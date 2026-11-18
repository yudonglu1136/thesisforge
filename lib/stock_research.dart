part of 'main.dart';

// Exact issuer symbols only. Share classes and exchange suffixes are not stripped.
String stockLogoTicker(String value) {
  final ticker = value.trim().toUpperCase();
  final option = RegExp(r'^([A-Z]{1,6})\d{6}[CP]\d{8}$').firstMatch(ticker);
  if (option != null) return option.group(1)!;
  return RegExp(r'^[A-Z][A-Z0-9.-]{0,14}$').hasMatch(ticker) ? ticker : '';
}

const stockLogoVersion = '20260905a';

class StockLogo extends StatelessWidget {
  const StockLogo({
    super.key,
    required this.ticker,
    required this.palette,
    this.size = 28,
    this.backgroundColor,
  });
  final String ticker;
  final Palette palette;
  final double size;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final symbol = stockLogoTicker(ticker);
    final fallback = Tooltip(
      message: context.tr('$ticker：暂无可用 Logo', '$ticker: logo unavailable'),
      child: Center(
        child: Text(
          symbol.isEmpty
              ? '—'
              : symbol.substring(0, math.min(2, symbol.length)),
          style: TextStyle(
            color: palette.faint,
            fontWeight: FontWeight.w800,
            fontSize: size * .32,
          ),
        ),
      ),
    );
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final decodePx = (size * dpr).round().clamp(32, 256);
    return Semantics(
      label: context.tr('$ticker 公司标识', '$ticker company identity'),
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * .12),
        decoration: BoxDecoration(
          color: backgroundColor ?? const Color(0xFFF4F6F8),
          borderRadius: BorderRadius.circular(size * .23),
        ),
        child: symbol.isEmpty
            ? fallback
            : Image.network(
                '/stock-logos/${Uri.encodeComponent(symbol)}.png?v=$stockLogoVersion',
                key: ValueKey('stock-logo-$symbol'),
                fit: BoxFit.contain,
                cacheWidth: decodePx,
                cacheHeight: decodePx,
                excludeFromSemantics: true,
                errorBuilder: (context, error, stack) => Image.network(
                  apiUri(
                    '/api/logo/${Uri.encodeComponent(symbol)}?v=$stockLogoVersion',
                  ).toString(),
                  fit: BoxFit.contain,
                  cacheWidth: decodePx,
                  cacheHeight: decodePx,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) => fallback,
                ),
              ),
      ),
    );
  }
}

// Scoped to the signed-in API client: no cross-account response cache.
class StockResearchCache {
  StockResearchCache(this.api);
  final ApiClient api;
  static final _instances = Expando<StockResearchCache>();
  static StockResearchCache of(ApiClient api) =>
      _instances[api] ??= StockResearchCache(api);
  final _entries = <String, ({DateTime at, Map<String, dynamic> data})>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  String? _session;

  Future<Map<String, dynamic>> load(
    String ticker, {
    bool full = false,
    bool refresh = false,
  }) {
    final session = api.accessToken;
    if (_session != session) {
      _entries.clear();
      _pending.clear();
      _session = session;
    }
    final path = valuationTickerDetailPath(
      ticker.toUpperCase(),
      fullResearch: full,
    );
    if (refresh) {
      _entries.remove(
        valuationTickerDetailPath(ticker.toUpperCase(), fullResearch: false),
      );
      _entries.remove(
        valuationTickerDetailPath(ticker.toUpperCase(), fullResearch: true),
      );
    }
    final cached = _entries[path];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return Future.value(cached.data);
    }
    if (!refresh && _pending[path] != null) return _pending[path]!;
    late final Future<Map<String, dynamic>> request;
    request = api
        .getJson(path)
        .then((data) {
          if (_session == session && identical(_pending[path], request)) {
            if (_entries.length >= 24) _entries.remove(_entries.keys.first);
            _entries[path] = (at: DateTime.now(), data: data);
          }
          return data;
        })
        .whenComplete(() {
          if (identical(_pending[path], request)) _pending.remove(path);
        });
    _pending[path] = request;
    return request;
  }
}

class StockResearchScope extends InheritedWidget {
  const StockResearchScope({
    super.key,
    required this.api,
    required this.palette,
    required this.sourceLabel,
    required super.child,
  });
  final ApiClient api;
  final Palette palette;
  final String sourceLabel;
  static StockResearchScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StockResearchScope>();
  @override
  bool updateShouldNotify(StockResearchScope oldWidget) =>
      oldWidget.api != api ||
      oldWidget.sourceLabel != sourceLabel ||
      oldWidget.palette != palette;
}

class StockResearchButton extends StatelessWidget {
  const StockResearchButton({
    super.key,
    required this.ticker,
    required this.palette,
    this.sourceDate = '',
    this.available = true,
    this.showLogo = true,
  });
  final String ticker;
  final Palette palette;
  final String sourceDate;
  final bool available;
  final bool showLogo;
  @override
  Widget build(BuildContext context) {
    final scope = StockResearchScope.maybeOf(context);
    final valid = available && stockLogoTicker(ticker).isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLogo) ...[
          StockLogo(ticker: ticker, palette: palette, size: 26),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: Tooltip(
            message: valid
                ? context.tr('查看 $ticker 的估值', 'View valuation for $ticker')
                : context.tr(
                    '非公开或未解析证券：暂无公开估值',
                    'Private or unresolved security: no public valuation',
                  ),
            child: TextButton(
              key: ValueKey('stock-research-$ticker'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                minimumSize: const Size(0, 36),
                foregroundColor: palette.accent,
              ),
              onPressed: scope == null || !valid
                  ? null
                  : () => showStockResearch(
                      context,
                      ticker: ticker,
                      api: scope.api,
                      palette: palette,
                      sourceLabel: scope.sourceLabel,
                      sourceDate: sourceDate,
                    ),
              child: Text(
                ticker,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
        if (scope != null && valid)
          Icon(Icons.chevron_right_rounded, size: 15, color: palette.accent),
      ],
    );
  }
}

Future<void> showStockResearch(
  BuildContext context, {
  required String ticker,
  required ApiClient api,
  required Palette palette,
  String sourceLabel = '',
  String sourceDate = '',
}) {
  final language = context.language;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.tr('关闭股票估值', 'Close stock valuation'),
    barrierColor: Colors.black.withValues(alpha: .35),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    transitionBuilder: (context, animation, secondary, child) =>
        SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
    pageBuilder: (context, animation, secondary) => LanguageScope(
      language: language,
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: MediaQuery.sizeOf(context).width < 760
                ? MediaQuery.sizeOf(context).width
                : 580,
            height: double.infinity,
            child: Material(
              color: palette.panel,
              elevation: 16,
              child: StockValuationPanel(
                ticker: ticker,
                api: api,
                palette: palette,
                sourceLabel: sourceLabel,
                sourceDate: sourceDate,
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class StockValuationPanel extends StatefulWidget {
  const StockValuationPanel({
    super.key,
    required this.ticker,
    required this.api,
    required this.palette,
    required this.onClose,
    this.sourceLabel = '',
    this.sourceDate = '',
  });
  final String ticker;
  final ApiClient api;
  final Palette palette;
  final VoidCallback onClose;
  final String sourceLabel;
  final String sourceDate;
  @override
  State<StockValuationPanel> createState() => _StockValuationPanelState();
}

class _StockValuationPanelState extends State<StockValuationPanel> {
  Map<String, dynamic>? _payload;
  bool _loading = true, _failed = false, _full = false;
  bool _notCovered = false, _sessionFailed = false;
  int _serial = 0;
  String _quarterKey = '';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StockValuationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ticker != oldWidget.ticker || widget.api != oldWidget.api) {
      _payload = null;
      _full = false;
      _quarterKey = '';
      _load();
    }
  }

  Future<void> _load({bool full = false, bool refresh = false}) async {
    final serial = ++_serial;
    setState(() {
      _loading = true;
      _failed = false;
      _notCovered = false;
      _sessionFailed = false;
    });
    try {
      final payload = await StockResearchCache.of(
        widget.api,
      ).load(widget.ticker, full: full, refresh: refresh);
      // Reject unrelated/default-ticker responses instead of displaying a wrong model.
      final returned = text(asMap(payload['ticker'])['ticker']).toUpperCase();
      if (returned != widget.ticker.toUpperCase()) {
        throw StateError('ticker mismatch');
      }
      if (mounted && serial == _serial) {
        setState(() {
          _payload = payload;
          _full = full;
        });
      }
    } catch (error) {
      if (mounted && serial == _serial) {
        setState(() {
          _failed = true;
          _notCovered =
              error is ApiRequestException &&
              error.statusCode == 404 &&
              error.code == 'valuation_not_covered';
          _sessionFailed =
              error is ApiRequestException &&
              (error.statusCode == 401 || error.statusCode == 403);
          // A previously cached quote must not contradict a confirmed removal
          // or remain visible after authorization is lost.
          if (_notCovered || _sessionFailed) _payload = null;
        });
      }
    } finally {
      if (mounted && serial == _serial) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final detail = asMap(_payload?['ticker']);
    final latest = asMap(detail['latest']);
    final currentOnly = isCurrentOnlyValuation(detail);
    final auditLayers = asMap(asMap(detail['dataQuality'])['auditLayers']);
    final history = asList(detail['history']).toList()
      ..sort((a, b) => text(a['asOfDate']).compareTo(text(b['asOfDate'])));
    final prices = asList(detail['priceHistory']);
    final last = history.isEmpty ? <String, dynamic>{} : history.last;
    final previous = history.length < 2
        ? <String, dynamic>{}
        : history[history.length - 2];
    final currency = text(detail['currency']);
    final price = nullableNumber(latest['latestPrice']);
    final fairValue = nullableNumber(latest['baseFairValue']);
    final gap = nullableNumber(latest['upsideToBase']);
    String money(double? value) => value == null || currency.isEmpty
        ? '—'
        : formatCurrencyValue(value, currency);
    String date(dynamic value) => text(value).isEmpty
        ? context.tr('日期未提供', 'Date unavailable')
        : formatDate(text(value));
    final drivers = _valuationDrivers(
      context,
      latestHistory: last,
      previousHistory: previous,
      latestInputs: asMap(
        asMap(asMap(last['dataSnapshot'])['valuationSemantics'])['scoreInputs'],
      ),
      previousInputs: asMap(
        asMap(
          asMap(previous['dataSnapshot'])['valuationSemantics'],
        )['scoreInputs'],
      ),
      currency: currency,
      palette: p,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.tr('股票估值速览', 'Stock valuation'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: context.tr('刷新估值', 'Refresh valuation'),
                onPressed: _loading || _notCovered
                    ? null
                    : () => _load(full: _full, refresh: true),
                icon: Icon(Icons.refresh, color: p.muted),
              ),
              IconButton(
                key: const ValueKey('stock-research-close'),
                tooltip: context.tr('返回原研究位置', 'Back to your research'),
                onPressed: widget.onClose,
                icon: Icon(Icons.close, color: p.text),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: p.border),
        Expanded(
          child: ListView(
            key: ValueKey('stock-research-scroll-${widget.ticker}'),
            padding: const EdgeInsets.all(18),
            children: [
              if (widget.sourceLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    [
                      widget.sourceLabel,
                      if (widget.sourceDate.isNotEmpty) date(widget.sourceDate),
                    ].join(' · '),
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ),
              Row(
                children: [
                  StockLogo(ticker: widget.ticker, palette: p, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.ticker,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 25,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          text(detail['name']),
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (investmentWorkflowEnabled)
                FilledButton.icon(
                  onPressed: () => openBrowserPath(
                    Uri(
                      path: '/',
                      queryParameters: {
                        'view': 'research',
                        'valuation': widget.ticker,
                        'lang': appLanguageCode(context.language),
                      },
                    ).toString(),
                  ),
                  icon: const Icon(Icons.account_tree_outlined),
                  label: Text(
                    context.tr('研究、估值与决策', 'Research, value & decide'),
                  ),
                ),
              Text(
                context.tr(
                  '知名机构持仓披露 ≠ 买入建议。以下是当前估值，不代表机构买入时的价格或估值。',
                  'A Guru filing is not a buy signal. This is the latest model, not the Guru’s entry price or entry-date valuation.',
                ),
                style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: LinearProgressIndicator(),
                ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _notCovered
                            ? context.tr(
                                '${widget.ticker} 尚无已发布的估值模型。刷新不会生成估值；你可以返回继续研究原持仓。',
                                'No valuation model has been published for ${widget.ticker}. Refreshing will not create one; you can return to the original holding.',
                              )
                            : _sessionFailed
                            ? context.tr(
                                '无法验证当前访问权限，请重新登录后再查看估值。',
                                'Your access could not be verified. Sign in again to view this valuation.',
                              )
                            : context.tr(
                                '估值暂时加载失败，尚不能判断是否已覆盖。请重试；不会显示其他股票的估值。',
                                'Valuation unavailable: the request failed, so coverage could not be checked. Please retry; no substitute stock is shown.',
                              ),
                        style: TextStyle(color: p.muted),
                      ),
                      if (!_notCovered)
                        TextButton(
                          onPressed: () => _load(full: _full, refresh: true),
                          child: Text(context.tr('重试', 'Retry')),
                        ),
                    ],
                  ),
                ),
              if (_payload != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 5,
                  children: [
                    Text(
                      '${context.tr('数据来源', 'Lineage')}: ${context.ui(text(asMap(auditLayers['lineage'])['status'], 'not_run'))}',
                      style: TextStyle(color: p.muted, fontSize: 10),
                    ),
                    Text(
                      '${context.tr('模型验证', 'Model validation')}: ${context.ui(text(asMap(auditLayers['economicValidation'])['status'], 'not_validated'))}',
                      style: TextStyle(color: p.secondary, fontSize: 10),
                    ),
                    Text(
                      '${context.tr('市场校准', 'Market calibration')}: ${context.ui(text(asMap(auditLayers['marketCalibration'])['status'], 'not_run'))}',
                      style: TextStyle(color: p.muted, fontSize: 10),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _metric(
                      context.tr('当前股价', 'Market price'),
                      money(price),
                      p.text,
                    ),
                    _metric(
                      currentOnly
                          ? context.tr('基准情景估值', 'Base scenario value')
                          : context.tr('模型公允价值', 'Model fair value'),
                      money(fairValue),
                      p.accent,
                    ),
                    _metric(
                      context.tr('估值空间', 'Model gap'),
                      gap == null ? '—' : formatReturn(gap),
                      gap == null
                          ? p.muted
                          : gap >= 0
                          ? p.positive
                          : p.negative,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${context.tr('股价', 'Price')} · ${date(latest['latestPriceDate'])}   |   ${context.tr('模型基准日', 'Model node')} · ${date(last['asOfDate'])}',
                  style: TextStyle(color: p.faint, fontSize: 11),
                ),
                const SizedBox(height: 22),
                Text(
                  currentOnly
                      ? context.tr('当期情景 / 股价', 'Current scenario / price')
                      : context.tr('价格与公允价值', 'Price vs. fair value'),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                if (history.length >= 2 || prices.length >= 2)
                  SizedBox(
                    height: 245,
                    child: ValuationTrendChart(
                      history: history,
                      priceHistory: prices,
                      currency: currency,
                      palette: p,
                      selectedQuarterKey: _quarterKey.isEmpty
                          ? valuationQuarterKey(last)
                          : _quarterKey,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      currentOnly
                          ? context.tr(
                              '仅有当期估值，不绘制未经审核的历史曲线。',
                              'Current valuation only. No unreviewed historical curve is drawn.',
                            )
                          : context.tr(
                              '历史数据不足，暂不绘制曲线。',
                              'Insufficient history to draw a chart.',
                            ),
                      style: TextStyle(color: p.muted),
                    ),
                  ),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _ChartLegend(
                      color: p.accent,
                      label: context.tr('公允价值', 'Fair value'),
                      palette: p,
                    ),
                    _ChartLegend(
                      color: p.secondary,
                      label: context.tr('季度价格', 'Quarter price'),
                      palette: p,
                    ),
                    _ChartLegend(
                      color: p.faint,
                      label: context.tr('每日价格', 'Daily price'),
                      palette: p,
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                if (currentOnly)
                  CurrentValuationScenarioCard(detail: detail, palette: p)
                else
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: p.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: p.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('估值为什么变化', 'Why the valuation changed'),
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.tr(
                            '比较最近两个可见模型节点',
                            'Comparing the latest two visible model nodes',
                          ),
                          style: TextStyle(color: p.faint, fontSize: 11),
                        ),
                        for (final driver in drivers)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: _ValuationDriverRow(
                              driver: driver,
                              palette: p,
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  context.tr(
                    '模型估计，不是保证回报。数据来源检查不等于模型预测能力验证；请在完整研究中核查方法、假设与风险。',
                    'Model estimate, not a promised return. Source checks do not validate predictive accuracy. Review the methodology, assumptions and risks in full research.',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 16),
                if (_full)
                  ValuationQuarterResearchPanel(
                    api: widget.api,
                    rows: history,
                    fallbackMethodCards: asList(detail['methodCards']),
                    currency: currency,
                    palette: p,
                    selectedQuarterKey: _quarterKey.isEmpty
                        ? valuationQuarterKey(last)
                        : _quarterKey,
                    onSelectQuarter: (value) =>
                        setState(() => _quarterKey = value),
                  ),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
        Divider(height: 1, color: p.border),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: widget.onClose,
                  child: Text(context.tr('返回原研究', 'Back to research')),
                ),
              ),
              const SizedBox(width: 10),
              if (_payload != null)
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('stock-research-full'),
                    onPressed: _loading
                        ? null
                        : _full
                        ? () => setState(() => _full = false)
                        : () => _load(full: true),
                    child: Text(
                      _full
                          ? context.tr('收起完整研究', 'Collapse research')
                          : context.tr('展开完整研究', 'Open full research'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, String value, Color color) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: widget.palette.muted, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 23,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}
