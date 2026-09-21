part of 'main.dart';

List<Map<String, dynamic>> matchResearchCompanies(
  List<Map<String, dynamic>> companies,
  String query,
) {
  final q = query.trim().toLowerCase();
  final words = q.split(RegExp(r'\s+'));
  int rank(Map<String, dynamic> r) {
    final ticker = text(r['ticker']).toLowerCase();
    if (ticker == q) return 0;
    if (ticker.startsWith(q)) return 1;
    if (text(r['name']).toLowerCase().startsWith(q)) return 2;
    return 3;
  }

  return companies.where((r) {
    final haystack = '${r['ticker']} ${r['name']}'.toLowerCase();
    return words.every(haystack.contains);
  }).toList()..sort((a, b) {
    final score = rank(a).compareTo(rank(b));
    return score != 0 ? score : text(a['ticker']).compareTo(text(b['ticker']));
  });
}

class CompanySearchDialog extends StatefulWidget {
  const CompanySearchDialog({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.currentTicker,
    this.recentTickers = const [],
  });
  final ApiClient api;
  final Palette palette;
  final String asOf, currentTicker;
  final List<String> recentTickers;
  @override
  State<CompanySearchDialog> createState() => _CompanySearchDialogState();
}

class _CompanySearchDialogState extends State<CompanySearchDialog> {
  final query = TextEditingController();
  final searchFocus = FocusNode();
  final resultsScroll = ScrollController();
  List<Map<String, dynamic>> companies = [];
  bool loading = true, failed = false;
  int active = 0, request = 0;
  Timer? searchTimer;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  double get rowHeight => math.max(
    84,
    30 +
        MediaQuery.textScalerOf(
          context,
        ).scale(MediaQuery.sizeOf(context).width < 600 ? 72 : 43.5),
  );
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    query.dispose();
    searchFocus.dispose();
    resultsScroll.dispose();
    searchTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final serial = ++request;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final search = Uri.encodeQueryComponent(query.text.trim());
      final data = await widget.api
          .getJson(
            '/api/investment/companies?asOf=${widget.asOf}&search=$search&limit=120',
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted || serial != request) return;
      if (data['asOf'] != widget.asOf || data['companies'] is! List) {
        throw StateError('invalid_company_index');
      }
      final rows = asList(data['companies']);
      final seen = <String>{};
      for (final r in rows) {
        final symbol = text(r['ticker']), date = text(r['availableAt']);
        if (!RegExp(r'^[A-Z][A-Z0-9.\-]{0,14}$').hasMatch(symbol) ||
            date.length != 10 ||
            date.compareTo(widget.asOf) > 0 ||
            !const {'stored_model', 'fact_os_only'}.contains(r['coverage']) ||
            !seen.add(symbol)) {
          throw StateError('invalid_company_index');
        }
      }
      setState(() {
        companies = rows;
        loading = false;
        active = 0;
      });
    } catch (_) {
      if (mounted && serial == request) {
        setState(() {
          loading = false;
          failed = true;
        });
      }
    }
  }

  List<Map<String, dynamic>> get rows {
    final all = matchResearchCompanies(companies, query.text);
    if (query.text.trim().isNotEmpty) return all;
    final recent = {widget.currentTicker, ...widget.recentTickers}.toList();
    return [
      for (final ticker in recent) ...all.where((r) => r['ticker'] == ticker),
      ...all.where((r) => !recent.contains(r['ticker'])),
    ];
  }

  void changeQuery(String _) {
    setState(() => active = 0);
    if (resultsScroll.hasClients) resultsScroll.jumpTo(0);
    searchTimer?.cancel();
    searchTimer = Timer(const Duration(milliseconds: 220), load);
  }

  void choose(String symbol) => Navigator.of(context).pop(symbol);
  void move(int direction) {
    final count = rows.length;
    if (count == 0) return;
    setState(() => active = (active + direction).clamp(0, count - 1));
    if (resultsScroll.hasClients) {
      final position = resultsScroll.position;
      // Ensure the highlighted row remains in the scroll viewport without
      // transferring keyboard focus away from the search field.
      final top = active * rowHeight, bottom = top + rowHeight;
      if (top < position.pixels) {
        resultsScroll.jumpTo(top.clamp(0, position.maxScrollExtent));
      }
      if (bottom > position.pixels + position.viewportDimension) {
        resultsScroll.jumpTo(
          (bottom - position.viewportDimension).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      }
    }
  }

  TextStyle style(
    double size, {
    Color? color,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(fontSize: size, color: color ?? p.text, fontWeight: weight);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context), mobile = size.width < 600;
    final matches = rows;
    final hasQuery = query.text.trim().isNotEmpty;
    return Dialog(
      alignment: Alignment.topCenter,
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      insetPadding: EdgeInsets.fromLTRB(
        mobile ? 12 : 28,
        mobile ? 24 : math.min(160, size.height * .16),
        mobile ? 12 : 28,
        18,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 680),
        child: Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              move(1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              move(-1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(mobile ? 18 : 24, 18, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            w('Find a company', '查找公司'),
                            style: style(23, weight: FontWeight.w600),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            w(
                              'Go straight to its research and valuation.',
                              '直接查看公司的研究与估值。',
                            ),
                            style: style(13, color: p.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: w('Close search', '关闭搜索'),
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, size: 21, color: p.muted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: mobile ? 18 : 24),
                child: TextField(
                  key: const ValueKey('company-search-input'),
                  controller: query,
                  focusNode: searchFocus,
                  autofocus: !mobile,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: style(16),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: w('Search name or ticker', '搜索公司名或股票代码'),
                    hintStyle: style(15, color: p.muted),
                    prefixIcon: Icon(Icons.search, color: p.accent, size: 23),
                    suffixIcon: hasQuery
                        ? IconButton(
                            tooltip: w('Clear search', '清空搜索'),
                            onPressed: () {
                              query.clear();
                              searchTimer?.cancel();
                              setState(() => active = 0);
                              if (resultsScroll.hasClients) {
                                resultsScroll.jumpTo(0);
                              }
                              // Clearing is an explicit request to restore the
                              // dated directory, so do not make the user wait
                              // through the typing debounce.
                              unawaited(load());
                              searchFocus.requestFocus();
                            },
                            icon: Icon(
                              Icons.cancel_outlined,
                              color: p.muted,
                              size: 19,
                            ),
                          )
                        : null,
                    filled: true,
                    fillColor: p.background,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 17,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: p.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: p.accent),
                    ),
                  ),
                  onChanged: changeQuery,
                  onSubmitted: (_) {
                    if (!loading && !failed && matches.isNotEmpty) {
                      choose(text(matches[active]['ticker']));
                    }
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(mobile ? 18 : 24, 15, 24, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        loading
                            ? w('Loading companies…', '正在加载公司…')
                            : failed
                            ? w('Search unavailable', '搜索暂不可用')
                            : hasQuery
                            ? w(
                                '${matches.length} ${matches.length == 1 ? 'result' : 'results'}',
                                '${matches.length} 个结果',
                              )
                            : w(
                                'Browse companies · ${companies.length}',
                                '浏览公司 · ${companies.length}',
                              ),
                        style: style(
                          12,
                          color: p.muted,
                          weight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!mobile)
                      Text(
                        w('MODEL AS OF', '模型日期'),
                        style: style(
                          10,
                          color: p.muted,
                          weight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.border),
              Flexible(
                child: loading
                    ? Center(
                        heightFactor: 3,
                        child: Semantics(
                          label: w('Loading companies', '正在加载公司'),
                          child: const CircularProgressIndicator(),
                        ),
                      )
                    : failed
                    ? emptyState(
                        Icons.cloud_off_outlined,
                        w('Couldn’t load companies', '暂时无法加载公司'),
                        w(
                          'Your current research is still open. Try again.',
                          '当前研究未改变，请重试。',
                        ),
                        w('Try again', '重试'),
                        load,
                      )
                    : matches.isEmpty
                    ? emptyState(
                        Icons.search_off,
                        w('No matching companies', '没有匹配的公司'),
                        w(
                          'Try a company name or ticker. Fact OS companies remain available even without a platform valuation.',
                          '请尝试公司名或股票代码。即使暂无平台估值，Fact OS 公司仍可研究。',
                        ),
                        hasQuery ? w('Clear search', '清空搜索') : null,
                        () {
                          query.clear();
                          searchTimer?.cancel();
                          setState(() => active = 0);
                          if (resultsScroll.hasClients) {
                            resultsScroll.jumpTo(0);
                          }
                          unawaited(load());
                          searchFocus.requestFocus();
                        },
                      )
                    : Scrollbar(
                        controller: resultsScroll,
                        child: ListView.builder(
                          shrinkWrap: true,
                          controller: resultsScroll,
                          itemCount: matches.length,
                          itemExtent: rowHeight,
                          itemBuilder: (context, index) {
                            final r = matches[index],
                                symbol = text(r['ticker']);
                            final current = symbol == widget.currentTicker;
                            final recent =
                                !current &&
                                widget.recentTickers.contains(symbol);
                            return Semantics(
                              selected: index == active,
                              child: Material(
                                color: index == active
                                    ? p.accent.withValues(alpha: .075)
                                    : Colors.transparent,
                                child: InkWell(
                                  onTap: () => choose(symbol),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: mobile ? 18 : 24,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        StockLogo(
                                          ticker: symbol,
                                          palette: p,
                                          size: 38,
                                          backgroundColor:
                                              const {
                                                'AMZN',
                                                'UBER',
                                                'ABBV',
                                              }.contains(
                                                stockLogoTicker(symbol),
                                              )
                                              ? const Color(0xff1b2932)
                                              : null,
                                        ),
                                        const SizedBox(width: 13),
                                        Expanded(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    symbol,
                                                    style: style(
                                                      16,
                                                      weight: FontWeight.w600,
                                                    ),
                                                  ),
                                                  if (current || recent) ...[
                                                    const SizedBox(width: 8),
                                                    Flexible(
                                                      child: Text(
                                                        current
                                                            ? w('Current', '当前')
                                                            : w(
                                                                'Recent',
                                                                '最近查看',
                                                              ),
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: style(
                                                          10,
                                                          color: current
                                                              ? p.accent
                                                              : p.muted,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                text(r['name']),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: style(
                                                  13,
                                                  color: p.muted,
                                                ),
                                              ),
                                              if (mobile) ...[
                                                const SizedBox(height: 3),
                                                Text(
                                                  w(
                                                    r['coverage'] ==
                                                            'stored_model'
                                                        ? 'Model · ${r['availableAt']}'
                                                        : 'Facts · ${r['availableAt']}',
                                                    r['coverage'] ==
                                                            'stored_model'
                                                        ? '模型 · ${r['availableAt']}'
                                                        : '财务事实 · ${r['availableAt']}',
                                                  ),
                                                  style: style(
                                                    10,
                                                    color: p.muted,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        if (!mobile) ...[
                                          const SizedBox(width: 14),
                                          Text(
                                            text(r['availableAt']),
                                            style: style(12, color: p.muted),
                                          ),
                                        ],
                                        const SizedBox(width: 12),
                                        Icon(
                                          current
                                              ? Icons.check
                                              : Icons.arrow_forward,
                                          size: 18,
                                          color: index == active
                                              ? p.accent
                                              : p.muted,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: mobile ? 18 : 24,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: p.background,
                  border: Border(top: BorderSide(color: p.border)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.history, color: p.muted, size: 15),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        w(
                          'Research as of ${widget.asOf}',
                          '研究截止日 ${widget.asOf}',
                        ),
                        style: style(11, color: p.muted),
                      ),
                    ),
                    if (!mobile)
                      Text(
                        w(
                          '↑ ↓ navigate   ↵ open   esc close',
                          '↑ ↓ 选择   ↵ 打开   esc 关闭',
                        ),
                        style: style(11, color: p.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget emptyState(
    IconData icon,
    String heading,
    String description,
    String? action,
    VoidCallback onTap,
  ) => Center(
    heightFactor: 1,
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: p.muted),
            const SizedBox(height: 16),
            Text(
              heading,
              textAlign: TextAlign.center,
              style: style(18, weight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: style(13, color: p.muted),
            ),
            if (action != null) ...[
              const SizedBox(height: 15),
              TextButton(onPressed: onTap, child: Text(action)),
            ],
          ],
        ),
      ),
    ),
  );
}
