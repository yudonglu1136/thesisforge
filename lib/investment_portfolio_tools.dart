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
  String broker = 'ibkr_flex';
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
    if (broker != 'ibkr_flex') {
      await showDialog<void>(context: context, builder: (_) => PortfolioReadOnlyBroker(
        api: widget.api, palette: widget.palette, provider: broker));
      return;
    }
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
      title: Text(w('Add a brokerage account', '添加券商账户')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: broker,
                decoration: InputDecoration(labelText: w('Broker', '券商')),
                items: const [
                  DropdownMenuItem(value: 'ibkr_flex', child: Text('Interactive Brokers')),
                  DropdownMenuItem(value: 'questrade', child: Text('Questrade')),
                  DropdownMenuItem(value: 'futu', child: Text('Futu / moomoo')),
                ],
                onChanged: saving ? null : (value) {
                  if (value == null) return;
                  token.clear();
                  query.clear();
                  history.clear();
                  setState(() { broker = value; error = null; });
                },
              ),
              const SizedBox(height: 16),
              if (broker != 'ibkr_flex') ...[
                Text(w('Read-only account access', '只读账户访问')),
                const SizedBox(height: 12),
                Text(broker == 'questrade'
                    ? w('Use a personal API token from Questrade API Centre. Never enter your trading password. Account snapshots are kept separately from IBKR.',
                        '使用 Questrade API Centre 生成的个人 API Token，请勿输入交易密码。账户快照与 IBKR 分开保存。')
                    : w('Connect the official OpenD gateway on your Mac. The connector uploads read-only snapshots; keep the OpenD port private.',
                        '连接这台 Mac 上的官方 OpenD 网关。连接器上传只读快照，请勿将 OpenD 端口暴露到公网。'),
                  style: TextStyle(color: p.muted, height: 1.5)),
                const SizedBox(height: 12),
                Text(w('No order placement, cancellation or transfers.', '不提供下单、撤单或转账功能。')),
              ],
              if (broker == 'ibkr_flex') ...[
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
          child: Text(broker == 'ibkr_flex'
              ? w('Connect & sync', '连接并同步')
              : w('Set up / view account', '设置／查看账户')),
        ),
      ],
    );
  }
}

class PortfolioReadOnlyBroker extends StatefulWidget {
  const PortfolioReadOnlyBroker({super.key, required this.api,
    required this.palette, required this.provider});
  final ApiClient api;
  final Palette palette;
  final String provider;
  @override
  State<PortfolioReadOnlyBroker> createState() => _PortfolioReadOnlyBrokerState();
}

class _PortfolioReadOnlyBrokerState extends State<PortfolioReadOnlyBroker> {
  final token = TextEditingController();
  Map<String, dynamic>? state;
  String? pairingToken, failure;
  bool busy = false;
  String w(String en, String zh) => context.tr(zh, en);
  String get endpoint => '/api/portfolio/broker/${widget.provider}';
  @override
  void initState() { super.initState(); read(); }
  @override
  void dispose() { token.clear(); token.dispose(); super.dispose(); }
  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; failure = null; });
    try { await action(); }
    catch (_) { if (mounted) { setState(() => failure = w(
      'Request failed. Any saved snapshot remains available; it is not a new sync.',
      '请求失败。已保存的快照仍保留，但不代表本次同步成功。')); } }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> read() => run(() async {
    final result = await widget.api.getJson(endpoint);
    if (mounted) setState(() => state = result);
  });
  Future<void> connect() => run(() async {
    if (widget.provider == 'questrade') {
      final result = await widget.api.postJson('$endpoint/connect', {'refreshToken': token.text.trim()});
      token.clear();
      if (mounted) setState(() => state = result);
    } else {
      final result = await widget.api.postJson('$endpoint/pair', {});
      if (mounted) setState(() => pairingToken = result['connectorToken'] as String?);
    }
  });
  Future<void> sync() => run(() async {
    final result = await widget.api.postJson('$endpoint/sync', {});
    if (mounted) setState(() => state = result);
  });
  Future<void> disconnect() => run(() async {
    await widget.api.deleteJson(endpoint);
    if (mounted) setState(() { state = null; pairingToken = null; token.clear(); });
  });
  String value(dynamic n) => n is num ? n.toStringAsFixed(2) : '—';
  @override
  Widget build(BuildContext context) {
    final q = widget.provider == 'questrade';
    final snapshot = asMap(state?['snapshot']);
    final accounts = (snapshot['accounts'] as List? ?? []).map(asMap).toList();
    return AlertDialog(
      backgroundColor: widget.palette.panel,
      title: Text('${q ? 'Questrade' : 'Futu / moomoo'} · ${w('Read only', '只读')}'),
      content: SizedBox(width: 720, child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
        children: [
          Text(w('Broker snapshots · separate from IBKR analysis. No orders or transfers. Values retain broker units; currencies are never added together.',
            '券商快照，与 IBKR 分析分开显示。不提供下单或转账。保留券商金额单位，不将不同币种直接相加。')),
          const SizedBox(height: 12),
          if (q) ...[
            TextField(controller: token, obscureText: true, autocorrect: false, enableSuggestions: false,
              decoration: InputDecoration(labelText: w('Personal refresh token', '个人 Refresh Token'))),
            TextButton(onPressed: () => openBrowserPath('https://www.questrade.com/api/documentation/getting-started'),
              child: Text(w('Questrade API Centre instructions ↗', 'Questrade API Centre 操作说明 ↗'))),
          ] else ...[
            Text(w('Log in to official OpenD on this Mac. Generate a connector token below, then run the connector and paste the token into its hidden prompt. It expires in 30 days; disconnect revokes it immediately.',
              '在这台 Mac 登录官方 OpenD。下方生成连接器 Token，然后运行连接器，在隐藏输入提示中粘贴。Token 30 天过期；断开连接会立即撤销。')),
            SelectableText('tmp/futu-connector-venv/bin/python scripts/futu_connector.py --account-id YOUR_ACCOUNT_ID --firm FUTUSECURITIES'),
            if (pairingToken != null) ...[
              const SizedBox(height: 12),
              Text(w('Copy now; this token is only shown here. Keep it private.', '请立即复制；Token 仅在此显示，请勿分享。')),
              SelectableText(pairingToken!),
            ],
          ],
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: busy ? null : connect, child: Text(q
              ? w('Connect & sync', '连接并同步') : w('Generate connector token', '生成连接器 Token'))),
            if (q && state?['connected'] == true)
              TextButton(onPressed: busy ? null : sync, child: Text(w('Sync now', '立即同步'))),
            TextButton(onPressed: busy ? null : read, child: Text(w('Reload snapshot', '重新读取快照'))),
            if (state?['connected'] == true || pairingToken != null)
              TextButton(onPressed: busy ? null : disconnect, child: Text(w('Disconnect', '断开连接'))),
          ]),
          if (busy) const LinearProgressIndicator(),
          if (failure != null) Text(failure!, style: TextStyle(color: widget.palette.secondary)),
          if (state?['status'] == 'error') Text(w('Last sync failed. Snapshot below is retained from an earlier sync.', '最近同步失败。下方为之前保存的快照。')),
          if (snapshot['retrievedAt'] != null) Text('${w('Retrieved', '读取时间')}: ${snapshot['retrievedAt']}'),
          if (accounts.isEmpty) Text(w('No account snapshot received yet.', '尚未收到账户快照。')),
          for (final account in accounts) ...[
            const Divider(),
            Text('${account['name']} · ${account['id']}'),
            for (final b in (account['balances'] as List? ?? []).map(asMap))
              Text('${b['currency']} · ${w('Equity', '净资产')} ${value(b['totalEquity'])} · ${w('Cash', '现金')} ${value(b['cash'])}'),
            Text(w('Position values use the broker currency; — means the source did not specify it.', '持仓金额使用券商币种；— 表示来源未提供币种。')),
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: [
              for (final label in [w('Symbol', '代码'), w('Quantity', '数量'), w('Price', '价格'), w('Value', '市值'), w('Currency', '币种')])
                DataColumn(label: Text(label)),
            ], rows: [for (final pos in (account['positions'] as List? ?? []).map(asMap))
              DataRow(cells: [DataCell(Text('${pos['ticker']}')), DataCell(Text(value(pos['quantity']))),
                DataCell(Text(value(pos['price']))), DataCell(Text(value(pos['value']))), DataCell(Text('${pos['currency'] ?? '—'}'))])])),
          ],
        ],
      ))),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(w('Close', '关闭')))],
    );
  }
}
