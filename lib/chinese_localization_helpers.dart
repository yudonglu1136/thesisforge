part of 'main.dart';

const kCjkFontFallback = <String>[
  'PingFang SC',
  'Hiragino Sans GB',
  'Heiti SC',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Source Han Sans SC',
  'sans-serif',
];

const _guruChineseNamesById = <String, String>{
  'jeff-bezos': '贝索斯',
  'elon-musk': '马斯克',
  'gavin-baker': '加文·贝克',
  'renaissance-technologies': '文艺复兴科技',
  'chamath-palihapitiya': '查马斯·帕里哈皮蒂亚',
  'bill-ackman': '比尔·阿克曼',
  'stanley-druckenmiller': '德鲁肯米勒',
  'brad-gerstner': '布拉德·格斯特纳',
  'chase-coleman': '蔡斯·科尔曼',
  'philippe-laffont': '菲利普·拉丰',
  'li-lu': '李录',
  'chuck-akre': '查克·阿克雷',
  'dev-kantesaria': '德夫·坎特萨里亚',
  'chris-bloomstran': '克里斯·布鲁姆斯特兰',
  'samantha-mclemore': '萨曼莎·麦克勒莫',
  'dennis-lynch': '丹尼斯·林奇',
  'terry-smith': '特里·史密斯',
  'stan-moss': '斯坦·莫斯',
  'baillie-gifford': '柏基投资',
  'peter-thiel': '彼得·蒂尔',
  'nancy-pelosi': '佩洛西',
  'david-sacks': '大卫·萨克斯',
  'david-friedberg': '大卫·弗里德伯格',
  'reid-hoffman': '里德·霍夫曼',
  'alex-karp': '亚历克斯·卡普',
  'warren-buffett': '巴菲特',
  'tom-gayner': '汤姆·盖纳',
  'nick-sleep-qais-zakaria': '尼克·斯利普 / 凯斯·扎卡里亚',
  'chris-hohn': '克里斯·霍恩',
  'david-tepper': '大卫·泰珀',
  'dan-loeb': '丹·勒布',
  'seth-klarman': '塞思·卡拉曼',
  'nelson-peltz': '纳尔逊·佩尔茨',
  'andreas-halvorsen': '安德烈亚斯·哈尔沃森',
  'david-einhorn': '大卫·艾因霍恩',
  'mohnish-pabrai': '莫尼什·帕伯莱',
  'pat-dorsey': '帕特·多尔西',
  'william-heard': '威廉·赫德',
  'evan-mcgoff': '埃文·麦戈夫',
  'michael-cuggino': '迈克尔·库吉诺',
  'john-stamas': '约翰·斯塔马斯',
  'george-soros': '索罗斯',
};

const _guruChineseNamesByEnglishName = <String, String>{
  'Jeff Bezos': '贝索斯',
  'Elon Musk': '马斯克',
  'Gavin Baker': '加文·贝克',
  'Renaissance Technologies': '文艺复兴科技',
  'Chamath Palihapitiya': '查马斯·帕里哈皮蒂亚',
  'Bill Ackman': '比尔·阿克曼',
  'Stanley Druckenmiller': '德鲁肯米勒',
  'Brad Gerstner': '布拉德·格斯特纳',
  'Chase Coleman': '蔡斯·科尔曼',
  'Philippe Laffont': '菲利普·拉丰',
  'Li Lu': '李录',
  'Chuck Akre': '查克·阿克雷',
  'Dev Kantesaria': '德夫·坎特萨里亚',
  'Chris Bloomstran': '克里斯·布鲁姆斯特兰',
  'Samantha McLemore': '萨曼莎·麦克勒莫',
  'Dennis Lynch': '丹尼斯·林奇',
  'Terry Smith': '特里·史密斯',
  'Stan Moss': '斯坦·莫斯',
  'Baillie Gifford': '柏基投资',
  'Peter Thiel': '彼得·蒂尔',
  'Nancy Pelosi': '佩洛西',
  'David Sacks': '大卫·萨克斯',
  'David Friedberg': '大卫·弗里德伯格',
  'Reid Hoffman': '里德·霍夫曼',
  'Alex Karp': '亚历克斯·卡普',
  'Warren Buffett': '巴菲特',
  'Tom Gayner': '汤姆·盖纳',
  'Nick Sleep / Qais Zakaria': '尼克·斯利普 / 凯斯·扎卡里亚',
  'Chris Hohn': '克里斯·霍恩',
  'David Tepper': '大卫·泰珀',
  'Dan Loeb': '丹·勒布',
  'Seth Klarman': '塞思·卡拉曼',
  'Nelson Peltz': '纳尔逊·佩尔茨',
  'Andreas Halvorsen': '安德烈亚斯·哈尔沃森',
  'David Einhorn': '大卫·艾因霍恩',
  'Mohnish Pabrai': '莫尼什·帕伯莱',
  'Pat Dorsey': '帕特·多尔西',
  'William Heard': '威廉·赫德',
  'Evan McGoff': '埃文·麦戈夫',
  'Michael Cuggino': '迈克尔·库吉诺',
  'John Stamas': '约翰·斯塔马斯',
  'George Soros': '索罗斯',
};

String? guruChineseNameFallback({String? id, String? englishName}) {
  final cleanId = (id ?? '').trim().toLowerCase();
  if (cleanId.isNotEmpty && _guruChineseNamesById.containsKey(cleanId)) {
    return _guruChineseNamesById[cleanId];
  }
  final cleanName = (englishName ?? '').trim();
  if (cleanName.isNotEmpty &&
      _guruChineseNamesByEnglishName.containsKey(cleanName)) {
    return _guruChineseNamesByEnglishName[cleanName];
  }
  return null;
}

String guruIdToDisplayName(
  String rawId,
  List<Map<String, dynamic>> gurus,
  AppLanguage language,
) {
  final clean = rawId.trim();
  if (clean.isEmpty) return '';
  final match = gurus.where((g) => text(g['id']) == clean).firstOrNull;
  if (match != null) return guruDisplayName(match, language);
  if (language == AppLanguage.zh) {
    final zh = _guruChineseNamesById[clean.toLowerCase()];
    if (zh != null) return zh;
  }
  return clean;
}

const _extraUiChinese = <String, String>{
  // 42 Guru roles
  'Amazon founder / executive chair': '亚马逊创始人 / 执行董事长',
  'Tesla CEO / controlling owner': '特斯拉首席执行官 / 控股股东',
  'Atreides Management': 'Atreides 资产管理创始人',
  'Quantitative investment manager / public 13F proxy': '量化投资管理机构 / 公开 13F 代理组合',
  'Social Capital founder / public equity manager proxy':
      'Social Capital 创始人 / 公开股票代理组合',
  'Pershing Square founder / CEO': '潘兴广场创始人 / 首席执行官',
  'Duquesne Family Office founder / macro public-equity proxy':
      '杜肯家族办公室创始人 / 宏观股票多头代理',
  'Altimeter Capital founder / CEO': 'Altimeter 资本创始人 / 首席执行官',
  'Tiger Global founder / public-equity manager proxy':
      '老虎环球创始人 / 公开二级市场组合代理',
  'Coatue founder / portfolio manager': 'Coatue 创始人 / 基金经理',
  'Himalaya Capital founder / Munger-style value investor':
      '喜马拉雅资本创始人 / 芒格式价值投资人',
  'Akre Capital founder / quality compounder investor':
      'Akre 资本创始人 / 高质量复利投资人',
  'Valley Forge Capital founder / concentrated quality investor':
      'Valley Forge 资本创始人 / 集中型高质量投资人',
  'Semper Augustus president / value investor': 'Semper Augustus 总裁 / 价值投资人',
  'Patient Capital founder / long-term public-equity investor':
      'Patient Capital 创始人 / 长线股票投资人',
  'Counterpoint Global head / public fund manager profile':
      '摩根士丹利 Counterpoint Global 负责人',
  'Fundsmith founder / CIO': 'Fundsmith 创始人 / 首席投资官',
  'Polen Capital CEO': 'Polen 资本首席执行官',
  'Long-duration global growth manager': '长久期全球成长投资机构',
  'Founder / board-level investor': '联合创始人 / 董事会级投资人',
  'U.S. Representative / household STOCK Act disclosures':
      '美国众议员 / 家庭国会交易披露',
  'Craft Ventures co-founder / public issuer reporting owner':
      'Craft Ventures 联合创始人 / 上市公司重要股东披露',
  'The Production Board founder / public issuer reporting owner':
      'The Production Board 创始人 / 上市公司重要股东披露',
  'LinkedIn co-founder / Greylock partner / public issuer reporting owner':
      '领英联合创始人 / Greylock 合伙人 / 重要股东披露',
  'Palantir co-founder / CEO': 'Palantir 联合创始人 / 首席执行官',
  'Berkshire Hathaway chairman / value investor': '伯克希尔·哈撒韦董事长 / 价值投资大师',
  'Markel CEO / investment chief': 'Markel 首席执行官 / 首席投资官',
  'Nomad Investment Partnership founders / archived 13F case study':
      'Nomad 投资合伙创始人 / 归档 13F 经典案例',
  'TCI founder / concentrated activist investor': 'TCI 基金创始人 / 集中型积极股东',
  'Appaloosa founder / opportunistic value investor':
      'Appaloosa 创始人 / 机会型价值投资人',
  'Third Point founder / CEO': 'Third Point 创始人 / 首席执行官',
  'Baupost CEO / portfolio manager': 'Baupost 首席执行官 / 基金经理',
  'Trian founding partner / activist investor': 'Trian 创始合伙人 / 积极主义投资人',
  'Viking Global founder / CIO': '维京全球创始人 / 首席投资官',
  'Greenlight Capital founder / value investor': '绿光资本创始人 / 价值投资人',
  'Pabrai Funds founder / concentrated value investor':
      '帕伯莱基金创始人 / 集中型价值投资人',
  'Dorsey Asset Management founder / CIO': 'Dorsey 资管创始人 / 首席投资官',
  'Heard Capital founder / CEO / CIO': 'Heard 资本创始人 / 首席执行官兼首席投资官',
  'Dock Street Asset Management CIO': 'Dock Street 资管首席投资官',
  'Pacific Heights Asset Management president / portfolio manager':
      'Pacific Heights 资管总裁 / 基金经理',
  'Defender Capital CIO': 'Defender 资本首席投资官',
  'Soros Fund Management': '索罗斯基金管理公司',
  // Guru simulation notes
  'Removed from the current Guru directory: the configured reporting entity is not verified as this manager. Historical records are retained for audit, not offered as a valid manager backtest.':
      '已从当前投资大师目录移除：所配置的申报主体未能核验归属于该管理人。历史记录仅供审计留存，不作为有效管理人回测展示。',
  'The audited 5Y public-holdings simulation is available. The 10Y window is not published because the early filing history contains a single reportable position and does not meet the existing diversified proxy threshold.':
      '经审计的近 5 年公开持仓模拟可用；因早期申报历史仅含单一可申报持仓、未达分散化代理门槛，暂不发布 10 年窗口。',
  'Historical holdings remain available, but the public 13F copy simulation is disabled because the audited filing history does not meet the existing price-coverage threshold. No lower-quality or cash-substitute curve is published.':
      '历史持仓仍可查阅，但因经审计的申报历史未达到复权价格覆盖率门槛，公开 13F 复制模拟已停用；系统不发布降级或现金替代曲线。',
  'The audited 5Y public-holdings simulation is available. The 10Y window is not published because verified price coverage for the early filing history remains below the existing 30% proxy threshold.':
      '经审计的近 5 年公开持仓模拟可用；因早期申报历史的核验价格覆盖率低于 30% 代理门槛，暂不发布 10 年窗口。',
  'This profile is not a 13F institutional manager; open Form 4 / STOCK Act disclosures below.':
      '该档案不属于 13F 机构管理人，请在下方查看 Form 4 高管或国会交易披露记录。',
  // 40 Valuation Archetype Sectors + GICS Aliases
  'AI networking hardware': 'AI 网络硬件',
  'AI semiconductor growth': 'AI 半导体成长',
  'Asset manager': '资产管理',
  'Broker / capital markets': '券商与资本市场',
  'Closed-loop card network / lender': '闭环卡组织与信贷',
  'Commodity merchant / processor': '大宗商品贸易与加工',
  'Consumer and commercial credit': '消费与商业信贷',
  'Consumer cyclical': '可选消费',
  'Consumer staples': '必选消费',
  'Consumer Discretionary': '可选消费',
  'Consumer Staples': '必选消费',
  'Information Technology': '信息技术',
  'Health Care': '医疗保健',
  'Financials': '金融',
  'Materials': '原材料',
  'Telecommunication Services': '电信服务',
  'Defense growth': '国防科技成长',
  'Defense prime': '国防军工龙头',
  'Emerging biotech': '新兴生物科技',
  'Energy infrastructure / integrated': '能源基础设施与综合油气',
  'Energy technology': '能源科技',
  'Enterprise software growth': '企业软件成长',
  'Equity REIT': '权益型房地产信托 (REIT)',
  'Healthcare distribution': '医药分销',
  'Healthcare services / diagnostics': '医疗服务与诊断',
  'Hypergrowth AI software': '高增长 AI 软件',
  'Industrial growth': '工业成长',
  'Information services': '信息与数据服务',
  'Insurance broker': '保险经纪',
  'Large-cap bank': '大型商业银行',
  'Large-cap biopharma': '大型生物制药',
  'Managed care': '管理式医疗保险',
  'Materials / building products': '材料与建材产品',
  'Mature medical technology': '成熟医疗器械',
  'Media / telecom network': '传媒与电信网络',
  'Mega-cap platform': '超大型科技平台',
  'Natural gas E&P': '天然气勘探与开发',
  'Optical networking turnaround': '光通信周期反转',
  'P&C insurance': '财产与意外险',
  'Platform reinvestment': '再投资型互联网平台',
  'Power utility / generation': '电力公用事业与发电',
  'Quality consumer compounder': '高质量消费复利',
  'Semiconductor equipment': '半导体设备',
  'Semiconductor value': '价值型半导体',
  'Software platform': '软件平台',
  'Technology hardware': '科技硬件',
  'Transportation / travel': '交通运输与出行',
  // Missing UI / Legacy / Valuation Method Keys
  'weight': '权重',
  'return': '收益',
  'contrib': '贡献',
  'STOCK': '国会披露',
  '1Y': '近1年',
  '3Y': '近3年',
  '5Y': '近5年',
  '10Y': '近10年',
  'MDD≈': '最大回撤≈',
  'Tracked stocks': '跟踪股票数',
  'Cumulative sold': '累计卖出金额',
  'Sold shares': '累计卖出股数',
  'New / Exit': '新建 / 清仓',
  'Filing lag': '披露滞后',
  'Total': '总回报',
  'Sharpe': '夏普比率',
  'monitored gurus': '跟踪投资大师',
  'Signal spread': '信号净差',
  'buy/add minus sell/reduce': '建仓加仓减清仓减仓',
  'Latest quarter': '最新季度',
  'dominant disclosure window': '主要披露窗口',
  'disclosure window': '披露窗口',
  'Concentrated': '集中持仓',
  'High Conviction': '高确信度',
  '13F-HR': '13F 季度持仓申报',
  'insider': 'Form 4 内部人披露',
  'congress': '国会交易披露',
  'disclosure trail': '披露记录',
  'Fair Value Matrix': '公允价值矩阵',
  'Current-only FCFE scenario': '当期股权现金流情景模型',
  'Current-only parent-economic FCFE': '当期归母经济股权现金流模型',
  'Historical valuation coverage': '历史估值覆盖范围',
  'Legacy fundamental-analysis stock modules': '历史基本面股票估值模块',
  'Sharadar Local Fact OS': '财报事实库 (Sharadar)',
  'EV/sales equity value': 'EV/销售额股权估值',
  'Normalized earnings power': '标准化盈利能力估值',
  'Normalized earnings': '标准化盈利能力估值',
  'Five-year FCFE DCF': '五年期 FCFE 现金流折现',
  'Cycle-normalized FCFE DCF': '周期标准化 FCFE 折现',
  'ROE-implied P/B value': 'ROE 隐含市净率估值',
  'EPS cross-check': 'EPS 盈利交叉核验估值',
  'Reported equity': '报告期股东权益账面值',
  'Forward-looking debate': '前瞻多空焦点',
  'No summary available.': '暂无摘要说明。',
  'not an FV input': '不计入公允价值输入',
  'local_data_unavailable': '本地数据包暂不可用',
  'research_release_unavailable': '研究数据包暂未就绪',
  'strategy_analysis_updating': '策略分析数据正在更新',
  'valuation_not_covered': '暂未纳入平台估值模型覆盖',
  'production': '生产环境',
  'development': '开发环境',
  'current_only': '仅当期情景覆盖',
  'full_history': '完整历史覆盖',
};

String localizeDecisionAction(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en) return clean;
  return switch (clean.toLowerCase()) {
    'watch' => '观察',
    'pass' => '放弃',
    'invest' => '建仓',
    'maintain' => '维持',
    'change' => '调整',
    'add' => '加仓',
    'reduce' => '减仓',
    'exit' => '清仓',
    'review' => '复核',
    _ => localizeUiText(language, clean),
  };
}

String localizeValuationMethodLabel(
  String keyOrLabel,
  AppLanguage language, {
  String fallbackLabel = '',
}) {
  final raw = fallbackLabel.trim().isNotEmpty
      ? fallbackLabel.trim()
      : keyOrLabel.trim();
  if (language == AppLanguage.en) return raw;
  if (raw == 'Cycle-normalized FCFE DCF') return '周期标准化 FCFE 现金流折现';
  return switch (keyOrLabel.trim()) {
    'ev-sales-equity-value' => 'EV/销售额股权估值',
    'normalized-earnings-power' => '标准化盈利能力估值',
    'fcfe-dcf' => '五年期 FCFE 现金流折现',
    'roe-implied-book-value' => 'ROE 隐含市净率估值',
    'eps-cross-check' => 'EPS 盈利交叉核验估值',
    'reported-equity' => '报告期股东权益账面值',
    _ => _extraUiChinese[raw] ?? localizeUiText(language, raw),
  };
}

String localizeValuationStepLabel(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  return switch (clean) {
    'Forward revenue × target EV/sales' => '前瞻营收 × 目标 EV/销售额倍数',
    'Enterprise value − net debt' => '企业价值 − 净债务',
    'Implied equity value / diluted shares' => '隐含股权价值 ÷ 摊薄总股本',
    'Normalized net income / diluted shares' => '标准化净利润 ÷ 摊薄总股本',
    'Normalized EPS × target P/E' => '标准化每股收益 × 目标市盈率 (P/E)',
    'Explicit FCFE present value' => '显式预测期 FCFE 现值合计',
    'Terminal present value' => '永续终值现值',
    'Total FCFE value / diluted shares' => '股权现金流现值合计 ÷ 摊薄总股本',
    'Book value per share × ROE-implied P/B' => '每股净资产 × ROE 隐含市净率',
    _ => localizeValuationFormula(clean, language),
  };
}

String localizeValuationParamLabel(
  String key,
  String fallbackLabel,
  AppLanguage language,
) {
  if (language == AppLanguage.en) {
    return fallbackLabel.trim().isNotEmpty ? fallbackLabel : key;
  }
  return switch (key.trim()) {
    'forwardRevenueM' => '前瞻营收',
    'evSalesMultiple' => '目标 EV/销售额倍数',
    'netDebtM' => '净债务',
    'dilutedSharesM' => '摊薄总股本',
    'normalizedMargin' => '标准化净利率',
    'peMultiple' => '目标市盈率 (P/E)',
    'costOfEquity' => '股权资本成本 (Ke)',
    'terminalGrowth' => '永续增长率 (g)',
    'fcfeMargin' => 'FCFE 利润率',
    'bookValuePerShare' => '每股净资产',
    'throughCycleRoe' => '跨周期 ROE',
    'impliedPb' => '隐含市净率 (P/B)',
    'revenueGuidanceM' => '管理层营收指引',
    'transcript' => '电话会纪要指标',
    _ => _extraUiChinese[fallbackLabel] ??
        localizeUiText(
          language,
          fallbackLabel.trim().isNotEmpty ? fallbackLabel : key,
        ),
  };
}

String localizeValuationExclusionReason(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  return switch (clean) {
    'Stored published weight is zero.' => '该模型分支在当前企业模板中的权重为 0%。',
    'The stored snapshot did not produce this method.' =>
      '当前期快照输入不满足该方法计算条件，未生成估值。',
    'Negative or unavailable input prevents a meaningful positive value.' =>
      '核心输入为负值或缺失，无法生成有经济意义的正向估值。',
    'FCF was unavailable or negative, so earnings power carries the row.' =>
      '当期自由现金流缺失或为负值，本行由标准化盈利能力估值承载权重。',
    'FCF was unavailable or negative.' =>
      '当期自由现金流缺失或为负值，未计入正向折现。',
    'Normalized earnings were not positive, so the row relies on FCFE DCF.' =>
      '标准化盈利未呈正值，本行由 FCFE 现金流折现承载权重。',
    _ => localizeValuationFormula(clean, language),
  };
}

String localizeValuationFormula(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  if (_extraUiChinese.containsKey(clean)) return _extraUiChinese[clean]!;
  return clean
      .replaceAll('five-year FCFE DCF', '五年期 FCFE 折现')
      .replaceAll('Five-year FCFE DCF', '五年期 FCFE 折现')
      .replaceAll('cycle-normalized FCFE DCF', '周期标准化 FCFE 折现')
      .replaceAll('Cycle-normalized FCFE DCF', '周期标准化 FCFE 折现')
      .replaceAll('normalized earnings power', '标准化盈利能力')
      .replaceAll('Normalized earnings power', '标准化盈利能力')
      .replaceAll('normalized earnings', '标准化盈利')
      .replaceAll('EV/sales equity value', 'EV/销售额股权估值')
      .replaceAll('EV/sales', 'EV/销售额')
      .replaceAll('ROE-implied book value', 'ROE 隐含账面价值')
      .replaceAll('ROE-implied P/B value', 'ROE 隐含市净率估值')
      .replaceAll('EPS cross-check', 'EPS 交叉核验')
      .replaceAll('Target Multiple', '目标估值倍数')
      .replaceAll('based on usable inputs.', '（按当期有效输入加权）')
      .replaceAll('based on usable inputs', '（按当期有效输入加权）')
      .replaceAll('; no market price input', '；不引入市场价格作为模型输入')
      .replaceAll(
        '; historical fair value adjusted to split-adjusted price basis',
        '；历史公允价值已按前复权拆股口径对齐',
      );
}

String localizeValuationDescription(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  final pbMatch = RegExp(
    r'^Book value per share x ([0-9.]+)x implied P/B from ([0-9.]+%) through-cycle ROE and ([0-9.]+%) cost of equity\.$',
  ).firstMatch(clean);
  if (pbMatch != null) {
    return '每股净资产 × ${pbMatch.group(1)}x 隐含市净率（基于跨周期 ROE ${pbMatch.group(2)} 与股权成本 ${pbMatch.group(3)}）。';
  }
  return localizeValuationFormula(clean, language);
}

String localizeMetricEvidenceKey(String key, AppLanguage language) {
  final clean = key.trim();
  if (language == AppLanguage.en) return clean;
  return switch (clean) {
    'revenueGrowth' => '单季营收同比',
    'priorRevenueGrowth' => '上季单季营收同比',
    'revenueGrowthPriorQuarter' => '上季营收同比',
    'operatingMargin' => 'TTM 营业利润率',
    'operatingMarginPriorYear' => '上年同期营业利润率',
    'operatingMarginPriorQuarter' => '上季 TTM 营业利润率',
    'fcfMargin' => 'TTM FCF 利润率',
    'fcfMarginPriorYear' => '上年同期 FCF 利润率',
    'fcfMarginPriorQuarter' => '上季 TTM FCF 利润率',
    'grossMargin' => 'TTM 毛利率',
    'grossMarginPriorQuarter' => '上季 TTM 毛利率',
    'cfoMargin' => 'TTM 经营现金流利润率',
    'cfoMarginPriorYear' => '上年同期经营现金流利润率',
    'capexIntensityPriorYear' => '上年同期资本开支强度',
    'dilutedSharesGrowth' => '摊薄股本同比变化',
    'netIncomeGrowth' => '归母净利润同比',
    'perShareIncomeGrowth' => '每股收益同比',
    'netCommonFinancing' => '普通股净融资/回购现金流',
    'capexIntensity' => '资本开支强度',
    'preTaxCapitalReturn' => '税前投入资本回报率',
    'priceReturn' => '区间复权股价涨跌幅',
    'interestCoverage' => '利息保障倍数',
    'netDebtToFcf' => '净债务 / FCF',
    _ => clean,
  };
}

String localizeDiagnosticStatus(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en) return clean;
  return switch (clean) {
    'available' => '已覆盖',
    'missing' => '数据缺失',
    'not_observed' => '期内未观测到分红',
    'not_modeled' => '暂无平台估值模型',
    'price_unavailable' => '缺少可比市价',
    'currency_unverified' => '币种口径待核验',
    'insufficient_peer_count' => '可比同业不足 5 家',
    _ => localizeUiText(language, clean),
  };
}

String localizeInstitutionContinuity(
  Map<String, dynamic> change,
  AppLanguage language,
) {
  final raw = text(change['continuity']).trim();
  if (raw.isEmpty) return '';
  if (language == AppLanguage.en) return raw.replaceAll('_', ' ');
  if (raw == 'new_position') return '首次建仓';
  if (raw == 'exit_after_hold') return '持有后清仓';
  final inc = RegExp(r'^increased_(\d+)_quarters?$').firstMatch(raw);
  if (inc != null) return '连续增持 ${inc.group(1)} 个季度';
  final red = RegExp(r'^reduced_(\d+)_quarters?$').firstMatch(raw);
  if (red != null) return '连续减持 ${red.group(1)} 个季度';
  return raw.replaceAll('_', ' ');
}

String localizeReverseDcfStatus(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en) {
    return clean.isEmpty ? 'not calculated' : clean.replaceAll('_', ' ');
  }
  return switch (clean) {
    '' || 'not_calculated' => '尚未计算',
    'ready' || 'solved' => '已求解',
    'outside_bounds' => '超出合理求解区间',
    'multiple_solutions' => '存在多解（非单调区间）',
    'unavailable' => '暂不可计算（缺少同币种市价）',
    _ => localizeUiText(language, clean),
  };
}

String localizeReverseDcfFixed(
  String rawFixed,
  String method,
  String variable,
  int horizon,
  AppLanguage language,
) {
  if (language == AppLanguage.en || rawFixed.trim().isEmpty) return rawFixed;
  if (method == 'operating_fcff') {
    return switch (variable) {
      'mature_ebit_margin' =>
        '固定营收增速与现金流转化参数，反推由第 1 年线性过渡至第 $horizon 年的稳态 EBIT 利润率。',
      'reinvestment' =>
        '固定营收增速、EBIT 利润率、现金税率、折旧摊销、资本开支、WACC 与永续增速 g，反推单一营运资本再投资率（ΔNWC / 收入）。',
      _ =>
        '固定 EBIT 利润率、现金税率、折旧摊销、资本开支、营运资本再投资、WACC 与永续增速 g，反推单一恒定年度营收增速。',
    };
  }
  return switch (variable) {
    'terminal_margin' =>
      '固定营收增速及第 1 至第 ${horizon - 1} 年利润率，反推第 $horizon 年及永续期 FCFE 利润率。',
    _ => '固定全部 $horizon 年 FCFE 利润率、股权成本 Ke 与永续增速 g，反推单一恒定年度营收增速。',
  };
}

String localizeInsiderTxCode(
  String kind,
  String? txCode,
  AppLanguage language,
) {
  final c = (txCode ?? '').trim().toUpperCase();
  final zh = language == AppLanguage.zh;
  return switch (kind) {
    'purchase' => zh ? '公开市场买入 · P' : 'Open-market purchase · P',
    'sale' => zh ? '公开市场卖出 · S' : 'Open-market sale · S',
    'award' => zh ? '股权授予/奖励 · A' : 'Grant / award · A',
    'exercise' => zh ? '衍生品行权/转换 · M' : 'Derivative exercise · M',
    'conversion' => zh ? '衍生证券转换 · C' : 'Conversion · C',
    'tax_withholding' => zh ? '代扣税款/行权抵扣 · F' : 'Tax withholding · F',
    'gift' => zh ? '股权赠与 · G' : 'Gift · G',
    'holding' => zh ? '期末持股披露' : 'Reported holding',
    _ => switch (c) {
      'P' => zh ? '公开/协议买入 · P' : 'Purchase · P',
      'S' => zh ? '公开/协议卖出 · S' : 'Sale · S',
      'A' => zh ? '股权授予/奖励 · A' : 'Grant / award · A',
      'D' => zh ? '向公司交回/处置 · D' : 'Disposition to issuer · D',
      'F' => zh ? '代扣税款/行权抵扣 · F' : 'Tax withholding · F',
      'M' => zh ? '衍生品行权/转换 · M' : 'Exercise / conversion · M',
      'C' => zh ? '衍生证券转换 · C' : 'Conversion · C',
      'G' => zh ? '股权赠与 · G' : 'Gift · G',
      'X' => zh ? '实值期权行权 · X' : 'In-the-money exercise · X',
      'J' => zh ? '其他特定变更 · J' : 'Other acquisition/disposition · J',
      'I' => zh ? '计划内自主交易 · I' : 'Discretionary transaction · I',
      'W' => zh ? '继承或遗嘱过户 · W' : 'Will / descent transfer · W',
      'U' => zh ? '要约收购交股 · U' : 'Tender of shares · U',
      'L' => zh ? '小额增持 · L' : 'Small acquisition · L',
      _ => zh
          ? '其他变动${c.isEmpty ? '' : ' · $c'}'
          : 'Other${c.isEmpty ? '' : ' · $c'}',
    },
  };
}

String localizeInsiderOfficerTitle(String? raw, AppLanguage language) {
  final clean = (raw ?? '').trim();
  if (clean.isEmpty || language == AppLanguage.en) return clean;
  const map = <String, String>{
    'CEO': '首席执行官 (CEO)',
    'CFO': '首席财务官 (CFO)',
    'COO': '首席运营官 (COO)',
    'CTO': '首席技术官 (CTO)',
    'CIO': '首席信息官 (CIO)',
    'CMO': '首席营销官 (CMO)',
    'CLO': '首席法务官',
    'CAO': '首席会计官',
    'CHRO': '首席人力资源官',
    'CCO': '首席合规官',
    'CRO': '首席风险/营收官',
    'CXO': '首席高管 (CXO)',
    'Pres': '总裁',
    'President': '总裁',
    'Chair': '董事长',
    'Chairman': '董事长',
    'Co-Chair': '联席董事长',
    'Vice Chair': '副董事长',
    'EVP': '执行副总裁',
    'SVP': '高级副总裁',
    'VP': '副总裁',
    'AVP': '助理副总裁',
    'Sec': '董事会秘书',
    'Secretary': '董事会秘书',
    'Treas': '司库/财务主管',
    'Treasurer': '财务主管',
    'Cont': '财务总监',
    'Controller': '财务总监',
    'GC': '总法律顾问',
    'MD': '董事总经理',
    'Dir': '董事',
    'Director': '董事',
    '10%': '持股10%以上大股东',
    'Other': '其他高管',
  };
  return clean
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((token) => map[token] ?? token)
      .join('、');
}

String localizeInsiderSecurityTitle(String? raw, AppLanguage language) {
  final clean = (raw ?? '').trim();
  if (clean.isEmpty) return '—';
  if (language == AppLanguage.en) return clean;
  const map = <String, String>{
    'Com': '普通股',
    'Common Stock': '普通股',
    'ClA': 'A类普通股',
    'ClB': 'B类普通股',
    'ClC': 'C类普通股',
    'RSU': '限制性股票单位 (RSU)',
    'PSU': '绩效股票单位 (PSU)',
    'Rest': '限制性股票',
    'Opt': '股票期权',
    'ESO': '员工股票期权',
    'NQSO': '非合格股票期权',
    'ISO': '激励性股票期权',
    'SAR': '股票增值权 (SAR)',
    'Phant': '虚拟股',
    'Pref': '优先股',
    'Conv': '可转换证券',
    'Warr': '认股权证',
    'Unit': '份额单位',
    'LP': '有限合伙份额',
    'Def': '递延股权',
    'ADR': '美国存托凭证 (ADR)',
    'Dep': '存托股份',
    'Right': '认购权',
    'DER': '股息等价权',
    'Other': '其他证券',
  };
  return clean
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((token) => map[token] ?? token)
      .join(' / ');
}

String localizeInsiderAdCode(String? raw, AppLanguage language) {
  final clean = (raw ?? '').trim().toUpperCase();
  if (clean.isEmpty) return '—';
  if (language == AppLanguage.en) return clean;
  return switch (clean) {
    'NA' => '非衍生证券·取得 (NA)',
    'ND' => '非衍生证券·处置 (ND)',
    'N' => '非衍生证券·持有 (N)',
    'DA' => '衍生证券·取得 (DA)',
    'DD' => '衍生证券·处置 (DD)',
    'D' => '衍生证券·持有 (D)',
    _ => clean,
  };
}

String localizeInsiderFormType(String? raw, AppLanguage language) {
  final clean = (raw ?? '').trim().toUpperCase();
  if (clean.isEmpty) return '—';
  if (language == AppLanguage.en) {
    return clean.startsWith('FORM') ? clean : 'Form $clean';
  }
  if (clean == '3') return 'Form 3（初始持股申报）';
  if (clean == '4') return 'Form 4（内部人变动申报）';
  if (clean == '5') return 'Form 5（年度持股申报）';
  if (clean.contains('RESTATED') || clean.endsWith('/A')) {
    final numPart = RegExp(r'[345]').firstMatch(clean)?.group(0) ?? '4';
    return 'Form $numPart/A（更正申报）';
  }
  return 'Form $clean';
}

String localizeExecutiveSpeaker(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (clean.isEmpty || language == AppLanguage.en) return clean;
  return clean
      .replaceAll('President and CFO', '总裁兼首席财务官 (CFO)')
      .replaceAll('President & CFO', '总裁兼首席财务官 (CFO)')
      .replaceAll('President and CEO', '总裁兼首席执行官 (CEO)')
      .replaceAll('President & CEO', '总裁兼首席执行官 (CEO)')
      .replaceAll('Chair and CEO', '董事长兼首席执行官 (CEO)')
      .replaceAll('Chairman and CEO', '董事长兼首席执行官 (CEO)')
      .replaceAll('Chief Executive Officer', '首席执行官 (CEO)')
      .replaceAll('Chief Financial Officer', '首席财务官 (CFO)')
      .replaceAll('Chief Operating Officer', '首席运营官 (COO)');
}

String formatCompactSharesLocalized(
  num shares,
  AppLanguage language, {
  bool signed = false,
}) {
  final abs = shares.abs().toDouble();
  final prefix = shares < 0 ? '-' : (signed && shares > 0 ? '+' : '');
  if (language == AppLanguage.zh) {
    if (abs >= 1e8) return '$prefix${(abs / 1e8).toStringAsFixed(2)}亿股';
    if (abs >= 1e4) return '$prefix${(abs / 1e4).toStringAsFixed(1)}万股';
    return '$prefix${abs.round()}股';
  }
  if (abs >= 1e9) return '$prefix${(abs / 1e9).toStringAsFixed(2)}B';
  if (abs >= 1e6) return '$prefix${(abs / 1e6).toStringAsFixed(2)}M';
  if (abs >= 1e3) return '$prefix${(abs / 1e3).toStringAsFixed(1)}K';
  return '$prefix${abs.round()}';
}

String formatCompactMoneyMillionsLocalized(
  double millions,
  String currencySymbolText,
  AppLanguage language,
) {
  final abs = millions.abs();
  final sign = millions < 0 ? '-' : '';
  if (language == AppLanguage.zh) {
    // 1 million = 100万 = 0.01亿; 100 million = 1亿; 1,000,000 million = 1万亿
    if (abs >= 1e6) {
      return '$sign$currencySymbolText${(abs / 1e6).toStringAsFixed(2)}万亿';
    }
    if (abs >= 100) {
      return '$sign$currencySymbolText${(abs / 100).toStringAsFixed(1)}亿';
    }
    return '$sign$currencySymbolText${abs.toStringAsFixed(0)}百万';
  }
  if (abs >= 1e6) {
    return '$sign$currencySymbolText${(abs / 1e6).toStringAsFixed(2)}T';
  }
  if (abs >= 1e3) {
    return '$sign$currencySymbolText${(abs / 1e3).toStringAsFixed(1)}B';
  }
  return '$sign$currencySymbolText${abs.toStringAsFixed(0)}M';
}

String formatOccOptionContract(
  String rawTicker, {
  int? contracts,
  String? side,
  required AppLanguage language,
}) {
  final clean = rawTicker.trim();
  final stripped = clean.startsWith('O:') ? clean.substring(2) : clean;
  final match = RegExp(
    r'^([A-Z]{1,6})(\d{2})(\d{2})(\d{2})([CP])(\d{8})$',
  ).firstMatch(stripped);
  if (match == null) {
    if (contracts == null) return clean;
    if (language == AppLanguage.zh) {
      final verb = side == 'long'
          ? '买入 '
          : side == 'short'
          ? '卖出 '
          : '';
      return '$verb$contracts 张 · $clean';
    }
    final verb = side == 'long'
        ? 'Buy '
        : side == 'short'
        ? 'Sell '
        : '';
    return '$verb$contracts × $clean';
  }
  final under = match.group(1)!;
  final exp = '20${match.group(2)}-${match.group(3)}-${match.group(4)}';
  final isCall = match.group(5) == 'C';
  final strikeVal = int.parse(match.group(6)!) / 1000.0;
  final strikeStr = strikeVal == strikeVal.roundToDouble()
      ? strikeVal.round().toString()
      : strikeVal.toStringAsFixed(2);
  if (language == AppLanguage.zh) {
    final verb = side == 'long'
        ? '买入 '
        : side == 'short'
        ? '卖出 '
        : '';
    final qtyPart = contracts != null ? '$contracts 张 ' : '';
    final rightZh = isCall ? '看涨(Call)' : '看跌(Put)';
    return '$verb$qtyPart$under \$$strikeStr $rightZh · $exp 到期';
  }
  final verb = side == 'long'
      ? 'Buy '
      : side == 'short'
      ? 'Sell '
      : '';
  final qtyPart = contracts != null ? '$contracts × ' : '';
  return '$verb$qtyPart$under $exp \$$strikeStr ${isCall ? 'Call' : 'Put'}';
}

String localizeHedgeReason(String? rawReason, AppLanguage language) {
  final code = (rawReason ?? '').trim();
  if (code.isEmpty) return '';
  if (language == AppLanguage.en) return code.replaceAll('_', ' ');
  return switch (code) {
    'hedge_notional_below_one_contract' =>
      '组合规模不足 1 张 QQQ 期权合约名义本金（100 股），无法执行整数张对冲。',
    'hedge_observation_unavailable' => '该调仓观察日缺少对应的历史期权链收盘快照。',
    'hedge_expiry_incomplete' => '所选到期月份缺少可成交的目标执行价期权合约。',
    'hedge_untraded_contract' => '目标执行价合约当日无真实市场成交收盘价。',
    'hedge_data_unavailable' => '历史期权行情库当前不可用。',
    _ => '期权合约覆盖受限（$code）。',
  };
}

String localizeBrokerError(String raw, AppLanguage language) {
  final clean = raw.replaceFirst('Exception: ', '').trim();
  if (clean.isEmpty) return clean;
  final lower = clean.toLowerCase();
  final zh = language == AppLanguage.zh;

  if (lower.contains('error 1012') || lower.contains('token has expired')) {
    return zh
        ? 'IBKR 返回 Error 1012：该 Flex Token 已过期。请前往 IBKR「Third-Party Services」重新启用或刷新 Yodlee 行的 Token 后再试。'
        : 'IBKR Error 1012: Flex token has expired. Re-enable or refresh the Yodlee token row in IBKR Third-Party Services and retry.';
  }
  if (lower.contains('error 1015') || lower.contains('token is invalid')) {
    return zh
        ? 'IBKR 返回 Error 1015：Token 无效。请确认复制的是 IBKR「Third-Party Services -> Yodlee」同一行的完整数字 Token（不含空格），若刚启用请等待 1 分钟生效后重试。'
        : 'IBKR Error 1015: Token is invalid. Copy the exact numeric Token from the IBKR Third-Party Services -> Yodlee row (if just enabled, wait ~1 minute and retry).';
  }
  if (lower.contains('error 1013') || lower.contains('ip address')) {
    return zh
        ? 'IBKR 返回 Error 1013：Token 开启了 IP 白名单限制，拦截了云服务器拉取。请在 IBKR Flex 设置中清空 IP 限制或使用 Third-Party Services 默认 Yodlee 行。'
        : 'IBKR Error 1013: IP restriction blocked cloud sync. Clear IP allowlist restrictions on the IBKR token or use the default Third-Party Services Yodlee row.';
  }
  if (lower.contains('error 1014') ||
      lower.contains('query is invalid') ||
      lower.contains('query not found')) {
    return zh
        ? 'IBKR 返回 Error 1014：Query ID 无效或与当前 Token 不匹配。请确认 Token 与 Query ID 来自同一账户的同一行（例如 Yodlee 行），并移除旧失效查询。'
        : 'IBKR Error 1014: Query ID is invalid or does not match this Token. Ensure both come from the same row (e.g., Yodlee) and remove stale accounts.';
  }
  if (lower.contains('error 1018') ||
      lower.contains('error 1019') ||
      lower.contains('too many requests') ||
      lower.contains('generation in progress')) {
    return zh
        ? 'IBKR 正在后台生成您的首次报表或触发短时限流（Error 1018/1019）。请等待 10–20 秒后再次点击同步即可。'
        : 'IBKR is still generating the report or rate-limiting rapid retries (Error 1018/1019). Wait 10–20 seconds and sync again.';
  }
  if (lower.contains('error 1003') || lower.contains('statement is not available')) {
    return zh
        ? 'IBKR 返回 Error 1003：报表暂不可用。若刚新开户或刚勾选 Yodlee，IBKR 通常在数分钟或首个结算日后产出报表。'
        : 'IBKR Error 1003: Statement is not available yet. Newly opened accounts or freshly enabled Yodlee rows may take a few minutes to populate.';
  }
  if (lower.contains('token format looks invalid')) {
    return zh
        ? 'IBKR Token 格式无效（应为 12 位以上纯数字或字母数字组合，请勿粘贴整行文字）。'
        : 'IBKR token format looks invalid (paste only the alphanumeric token string).';
  }
  if (lower.contains('query id must be numeric')) {
    return zh
        ? 'Activity Flex Query ID 必须为纯数字（例如 Yodlee 行右侧的 6–8 位数字）。'
        : 'Activity Flex Query ID must be numeric (the 6–8 digit number on the Yodlee row).';
  }
  if (language == AppLanguage.en) return clean;
  if (clean.contains('token/query id are not configured')) {
    return '尚未配置 IBKR Flex 令牌（Token）或活动查询 ID（Query ID）。';
  }
  if (clean.contains('Some broker accounts could not refresh')) {
    final detailMatch = RegExp(r'\((.+)\)').firstMatch(clean);
    if (detailMatch != null && detailMatch.group(1)!.trim().isNotEmpty) {
      final inner = localizeBrokerError(detailMatch.group(1)!, language);
      return '部分旧账户刷新未完成（$inner）。请下方移除或替换失效账户后重新同步。';
    }
    return '部分券商账户刷新未完成，已保留最近一次验证通过的持仓快照。请移除或更新失效旧账户。';
  }
  if (clean.startsWith('Broker refresh unavailable. Showing the saved report dated ')) {
    final dateMatch = RegExp(r'dated ([0-9-]+)').firstMatch(clean);
    final asOf = dateMatch?.group(1) ?? '';
    return asOf.isNotEmpty
        ? '本次券商实时刷新未完成，当前展示 $asOf 已验证保存的持仓快照（非实时报价）。'
        : '本次券商实时刷新未完成，当前展示最近一次已保存持仓快照。';
  }
  final aggMatch = RegExp(
    r'^Aggregated (\d+) IBKR/Yodlee account\(s\)',
  ).firstMatch(clean);
  if (aggMatch != null) {
    if (clean.contains('failed to refresh')) {
      return '已汇总 ${aggMatch.group(1)} 个有效账户，但仍有部分旧账户刷新失败；请移除失效旧账户以恢复完整状态。';
    }
    return '已汇总 ${aggMatch.group(1)} 个已绑定券商账户的持仓与净值数据。';
  }
  if (clean.startsWith('IBKR SendRequest:') ||
      clean.startsWith('IBKR GetStatement:')) {
    return '盈透（IBKR）报表接口返回提示：${clean.split(':').skip(1).join(':').trim()}';
  }
  return localizeUiText(language, clean);
}

String localizeDiagnosticFormula(
  String id,
  String rawFormula,
  AppLanguage language,
) {
  final clean = rawFormula.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  return switch (id) {
    'revenueGrowth' => '单季营业收入 ÷ 去年同期营业收入 − 1',
    'grossMargin' => '滚动四季（TTM）毛利 ÷ TTM 营业收入',
    'operatingMargin' => 'TTM 营业利润 ÷ TTM 营业收入',
    'cfoMargin' => 'TTM 经营活动现金流净额 ÷ TTM 营业收入',
    'fcfMargin' => 'TTM 自由现金流 ÷ TTM 营业收入',
    'sbcMargin' => 'TTM 股份支付费用 ÷ TTM 营业收入',
    'workingCapital' => '资产负债表披露营运资本余额（不视作当期现金流贡献）',
    'netIncomeGrowth' => '当期 TTM 普通股净利润 ÷ 去年同期 TTM − 1',
    'perShareIncomeGrowth' => '（TTM 普通股净利润 ÷ 摊薄股数）同比增速',
    'dilutedSharesGrowth' => '最新一期摊薄总股本 ÷ 去年同期摊薄总股本 − 1',
    'netCommonFinancing' => '普通股发行与回购现金净额（非毛回购金额）',
    'dividends' => '过去 365 天除息日拆股调整后每股现金股息合计',
    'capexIntensity' => 'TTM 资本开支绝对值 ÷ TTM 营业收入',
    'preTaxCapitalReturn' => 'TTM 息税前利润（EBIT）÷ 平均投入资本',
    'debt' => '最新财报披露总有息债务余额',
    'interestCoverage' => 'TTM 息税前利润（EBIT）÷ TTM 利息费用绝对值',
    'marketPrice' => '截至所选日期的原始收盘报价（与前复权回报序列独立）',
    'modelGap' => '平台公允估值 ÷ 可比市场股价 − 1',
    'peerRevenueGrowthPercentile' => '同一经济模型及行业候选组内的收入增速百分位',
    'peerOperatingMarginPercentile' => '同一经济模型及行业候选组内的营业利润率百分位',
    'peerFcfMarginPercentile' => '同一经济模型及行业候选组内的自由现金流利润率百分位',
    _ => localizeValuationFormula(clean, language),
  };
}

String formatDiagnosticRatioValue(
  Map<String, dynamic> row,
  String currency,
  AppLanguage language,
) {
  final val = nullableNumber(row['value']);
  if (val == null || !val.isFinite) {
    final st = text(row['status']);
    return st.isNotEmpty && st != 'available' && st != 'missing'
        ? localizeDiagnosticStatus(st, language)
        : '—';
  }
  final id = text(row['id']);
  const pctIds = {
    'revenueGrowth',
    'grossMargin',
    'operatingMargin',
    'cfoMargin',
    'fcfMargin',
    'sbcMargin',
    'netIncomeGrowth',
    'perShareIncomeGrowth',
    'dilutedSharesGrowth',
    'capexIntensity',
    'preTaxCapitalReturn',
    'modelGap',
    'peerRevenueGrowthPercentile',
    'peerOperatingMarginPercentile',
    'peerFcfMarginPercentile',
  };
  if (pctIds.contains(id)) {
    final signed = const {
      'revenueGrowth',
      'netIncomeGrowth',
      'perShareIncomeGrowth',
      'dilutedSharesGrowth',
      'modelGap',
    }.contains(id);
    final sign = signed && val > 0 ? '+' : '';
    return '$sign${(val * 100).toStringAsFixed(1)}%';
  }
  if (id == 'interestCoverage') {
    return '${val.toStringAsFixed(1)}×';
  }
  if (id == 'marketPrice' || id == 'dividends') {
    return formatCurrencyValue(val, currency.isEmpty ? 'USD' : currency);
  }
  if (const {'workingCapital', 'netCommonFinancing', 'debt'}.contains(id)) {
    if (val.abs() >= 1e6) {
      // Raw USD / currency units in Sharadar SF1
      return formatCompactMoneyMillionsLocalized(
        val / 1e6,
        currency.isEmpty ? 'USD' : currency,
        language,
      );
    }
    return formatNumber(val);
  }
  return formatNumber(val);
}

String localizeFilingFormLabel(String form, AppLanguage language) {
  final clean = form.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  return switch (clean.toUpperCase()) {
    'ARQ' => '季报披露 (ARQ)',
    'ARY' => '年报披露 (ARY)',
    'ART' => '滚动四季披露 (ART)',
    'MRQ' => '重述季报 (MRQ)',
    'MRY' => '重述年报 (MRY)',
    'FINANCIAL_UPDATE' => '财报更新',
    _ => clean,
  };
}

String localizeFilingTitle(String rawTitle, AppLanguage language) {
  final clean = rawTitle.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  final m = RegExp(
    r'^([A-Z0-9.-]+)\s+([0-9QFY-]+)\s+financial disclosure$',
    caseSensitive: false,
  ).firstMatch(clean);
  if (m != null) {
    return '${m.group(1)} ${m.group(2)} 财务披露记录';
  }
  return clean.replaceAll('financial disclosure', '财务披露记录');
}

String localizeStrategyMetricText(String raw, AppLanguage language) {
  final clean = raw.trim();
  if (language == AppLanguage.en || clean.isEmpty) return clean;
  return switch (clean) {
    '8.91x vs 3.48x (Chase) / -8% Adverse Selection' =>
      '8.91x 对比 3.48x（直接追高）/ -8% 逆向选择',
    'MDD -29.9% (ATR Stop) vs -55% (No-Stop Tail) / 4.35x (-7% Stop)' =>
      '最大回撤 -29.9%（ATR 止损）对比 -55%（无止损尾部）/ 4.35x（-7% 紧止损）',
    '8.91x (4.0x ATR Chandelier) vs 1.57x (MA20 Tight Exit)' =>
      '8.91x（4.0x ATR 吊灯止盈）对比 1.57x（MA20 紧止盈）',
    '100% QQQ · Avg 72.3%' => '100% QQQ · 均值 72.3%',
    '70% -> 45% -> 0% QQQ' => '70% → 45% → 0% QQQ',
    'VIX >= 32 / RSI <= 28 -> 100%' => 'VIX ≥ 32 / RSI ≤ 28 → 100%',
    '11 Live Switches · 5 bps' => '11 次实盘切换 · 5 基点',
    'Only 5 Live Switches' => '实盘仅 5 次切换',
    'PE >= 34.5x + WkRSI >= 68' => 'PE ≥ 34.5x + 周线 RSI ≥ 68',
    '98.1% Rolling 5Y Win Rate' => '滚动 5 年胜率 98.1%',
    '21.39% CAGR · 18.55x' => '年化 21.39% · 18.55x',
    '50% QQQ Floor Never Sold' => '50% QQQ 底仓永不卖出',
    'Ann. Turnover Only 23.2%' => '年化换手仅 23.2%',
    '50% -> 100% QQQ Snipe' => '50% → 100% QQQ 满仓快反',
    '95.9% Rolling 5Y Win Rate' => '滚动 5 年胜率 95.9%',
    '2Y Drawdown <= -18%' => '近 2 年回撤 ≤ -18%',
    'FCF Yield >= 2.75% & Pos-PE <= 28.5x' => 'FCF 收益率 ≥ 2.75% 且盈利股 PE ≤ 28.5x',
    'CBOE VIX >= 32 OR Daily RSI(14) <= 28' => 'VIX ≥ 32 或日线 RSI(14) ≤ 28',
    'QQQ Close > MA150 + 1.5%' => 'QQQ 收盘价 > MA150 + 1.5%',
    'FCF Yield >= 2.55% & Pos-PE <= 31.0x' => 'FCF 收益率 ≥ 2.55% 且盈利股 PE ≤ 31.0x',
    _ => clean
        .replaceAll('<= ', '≤ ')
        .replaceAll('>= ', '≥ ')
        .replaceAll(' -> ', ' → ')
        .replaceAll(' OR ', ' 或 ')
        .replaceAll(' or ', ' 或 ')
        .replaceAll('vs MA150', '对比 MA150'),
  };
}

String polishStrategyProseZh(String raw, AppLanguage language) {
  if (language == AppLanguage.en || raw.isEmpty) return raw;
  return raw
      .replaceAll('死拿', '长期持有')
      .replaceAll('拒绝打脸', '规避假信号磨损')
      .replaceAll('打脸', '假信号磨损')
      .replaceAll('实质白菜价', '处于深度低估区间')
      .replaceAll('白菜价', '深度低估区间')
      .replaceAll('一把满仓杀回', '全仓切回')
      .replaceAll('满仓杀回', '全仓切回')
      .replaceAll('一把全卖', '一次性全额卖出')
      .replaceAll('一把满仓抄底', '全仓切回抄底')
      .replaceAll('一把清空', '全额卖出')
      .replaceAll('满仓接刀', '过早左侧抄底')
      .replaceAll('单笔怒赚', '单笔录得')
      .replaceAll('怒赚', '斩获');
}
