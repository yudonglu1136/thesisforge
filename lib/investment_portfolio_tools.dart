part of 'main.dart';

class PortfolioRiskChart extends StatefulWidget {
  const PortfolioRiskChart({
    super.key,
    required this.rows,
    required this.palette,
  });
  final List<Map<String, dynamic>> rows;
  final Palette palette;
  @override
  State<PortfolioRiskChart> createState() => _PortfolioRiskChartState();
}

class _PortfolioRiskChartState extends State<PortfolioRiskChart> {
  bool drawdown = false;
  int? hover;
  String w(String en, String zh) => context.tr(zh, en);
  @override
  Widget build(BuildContext context) {
    final rows = widget.rows, p = widget.palette;
    if (rows.length < 2) return const SizedBox.shrink();
    final cursor = (hover ?? rows.length - 1).clamp(0, rows.length - 1);
    List<double> values(String key) {
      var peak = 1.0;
      return rows.map((r) {
        final v = number(r[key]);
        peak = math.max(peak, v);
        return drawdown ? (v / peak - 1) * 100 : v * 100;
      }).toList();
    }

    final stock = values('portfolio'), spy = values('benchmark');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: Text(w('Growth of 100', '100 起点净值')),
              selected: !drawdown,
              onSelected: (_) => setState(() => drawdown = false),
            ),
            ChoiceChip(
              label: Text(w('Drawdown', '回撤')),
              selected: drawdown,
              onSelected: (_) => setState(() => drawdown = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            Text('${rows[cursor]['date']}', style: TextStyle(color: p.muted)),
            Text(
              '${w('Covered sleeve', '已覆盖部分')} ${stock[cursor].toStringAsFixed(1)}${drawdown ? '%' : ''}',
              style: TextStyle(color: p.accent),
            ),
            Text(
              'SPY ${spy[cursor].toStringAsFixed(1)}${drawdown ? '%' : ''}',
              style: TextStyle(color: p.secondary),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (_, c) => MouseRegion(
            onHover: (event) => setState(
              () => hover =
                  (((event.localPosition.dx - 46) / (c.maxWidth - 62)) *
                          (rows.length - 1))
                      .round()
                      .clamp(0, rows.length - 1),
            ),
            child: Semantics(
              label: w(
                'Daily covered-holdings simulation and SPY. Use the date slider to inspect values.',
                '已覆盖持仓与 SPY 每日模拟曲线，使用日期滑块查看数值。',
              ),
              child: SizedBox(
                height: 300,
                child: CustomPaint(
                  painter: StrategyCurvePainter(
                    series: {'blend': stock, 'spy': spy},
                    colors: {'blend': p.accent, 'spy': p.secondary},
                    palette: p,
                    drawdown: drawdown,
                    cursor: cursor,
                  ),
                ),
              ),
            ),
          ),
        ),
        Slider(
          value: cursor.toDouble(),
          min: 0,
          max: (rows.length - 1).toDouble(),
          divisions: rows.length - 1,
          label: text(rows[cursor]['date']),
          semanticFormatterCallback: (v) => text(rows[v.round()]['date']),
          onChanged: (v) => setState(() => hover = v.round()),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 6,
          children: [
            Text(
              text(rows.first['date']),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            Text(
              text(rows.last['date']),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}

class PortfolioIbkrSetup extends StatefulWidget {
  const PortfolioIbkrSetup({
    super.key,
    required this.api,
    required this.palette,
  });
  final ApiClient api;
  final Palette palette;
  @override
  State<PortfolioIbkrSetup> createState() => _PortfolioIbkrSetupState();
}

class _PortfolioIbkrSetupState extends State<PortfolioIbkrSetup> {
  final token = TextEditingController(),
      query = TextEditingController(),
      history = TextEditingController();
  bool saving = false;
  String? error;
  String w(String en, String zh) => context.tr(zh, en);
  @override
  void dispose() {
    token.clear();
    token.dispose();
    query.dispose();
    history.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (token.text.trim().isEmpty ||
        !RegExp(r'^\d+$').hasMatch(query.text.trim()) ||
        (history.text.trim().isNotEmpty &&
            !RegExp(r'^\d+$').hasMatch(history.text.trim()))) {
      setState(
        () => error = w(
          'Enter a Token and a numeric Query ID.',
          '请输入 Token 和数字 Query ID。',
        ),
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await widget.api.postJson('/api/portfolio/connection', {
        'provider': 'ibkr_flex',
        'ibkrFlexToken': token.text.trim(),
        'ibkrFlexQueryId': query.text.trim(),
        if (history.text.trim().isNotEmpty)
          'ibkrFlexHistoryQueryId': history.text.trim(),
      });
      if (!mounted) return;
      final status = asMap(asMap(result['portfolio'])['connection'])['status'];
      if (!['linked', 'linked_empty', 'linked_partial'].contains(status)) {
        setState(
          () => error = w(
            'Connection saved, but the report did not load. Check token expiry, allowed IPs, query permissions and XML sections in IBKR.',
            '连接已保存，但报告读取失败。请检查 Token 有效期、IP 限制、查询权限与 XML 报告内容。',
          ),
        );
        return;
      }
      token.clear();
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = w(
            'Could not connect. Check your login and IBKR report settings. No holdings were replaced.',
            '连接失败，请检查平台登录与 IBKR 报告设置。原有持仓未被替换。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AlertDialog(
      backgroundColor: p.panel,
      title: Text(w('Connect your IBKR portfolio', '连接你的 IBKR 组合')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                w(
                  'Read-only reporting access. Never enter your IBKR trading password.',
                  '只读报告权限，请勿输入 IBKR 交易密码。',
                ),
                style: TextStyle(color: p.muted),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: token,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'IBKR Flex Web Service Token',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: query,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: w(
                    'Activity Flex Query ID',
                    'Activity Flex Query ID',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: history,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: w(
                    'Historical Activity Flex Query ID · optional',
                    '历史 Activity Flex Query ID · 可选',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                w(
                  'Yodlee is only the third-party template name inside IBKR—not another account or API key. The Activity Flex report must include positions, base-currency NAV and Detailed Cash Transactions for received dividends and interest. Credentials are encrypted per user on the server.',
                  'Yodlee 只是 IBKR 内的第三方报告模板名称，不是另一套账户或 API key。Activity Flex 报告需包含持仓、基础币种净值，以及用于实际股息和利息的 Detailed Cash Transactions。凭证按用户隔离并在服务器加密保存。',
                ),
                style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
              ),
              if (error != null) ...[
                const SizedBox(height: 14),
                Text(error!, style: TextStyle(color: p.secondary)),
              ],
              if (saving) ...[
                const SizedBox(height: 14),
                const LinearProgressIndicator(),
                Text(w('IBKR is preparing your report…', 'IBKR 正在准备报告…')),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.of(context).pop(false),
          child: Text(w('Cancel', '取消')),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(w('Connect & sync', '连接并同步')),
        ),
      ],
    );
  }
}
