import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'browser_location.dart';

part 'stock_research.dart';
part 'admin_login_activity.dart';
part 'current_valuation_scenario.dart';
part 'investment_workflow.dart';
part 'investment_graphite.dart';
part 'investment_discovery.dart';
part 'investment_guru_study.dart';
part 'investment_guru_holdings.dart';
part 'investment_guru_scatter.dart';
part 'investment_workspace_pages.dart';
part 'investment_home.dart';
part 'investment_desk.dart';
part 'investment_opportunities.dart';
part 'investment_explorer.dart';
part 'investment_13f_insights.dart';
part 'investment_discover_lenses.dart';
part 'investment_value_trend.dart';
part 'investment_growth_quality.dart';
part 'investment_research.dart';
part 'investment_company_search.dart';
part 'investment_valuation.dart';
part 'investment_valuation_memory.dart';
part 'investment_holders.dart';
part 'investment_earnings.dart';
part 'investment_earnings_book.dart';
part 'investment_portfolio.dart';
part 'investment_portfolio_tools.dart';
part 'investment_portfolio_home.dart';
part 'investment_portfolio_privacy.dart';
part 'investment_portfolio_gurus.dart';
part 'investment_portfolio_visuals.dart';
part 'investment_strategy_lab.dart';
part 'investment_strategy_mix.dart';
part 'investment_strategy_cta.dart';
part 'investment_strategy_snapshot.dart';
part 'investment_strategy_chart.dart';
part 'investment_value_flow.dart';
part 'investment_fundamentals.dart';
part 'investment_fundamental_rules.dart';
part 'investment_fundamental_desk.dart';
part 'investment_hedge.dart';
part 'investment_strategy_hedge.dart';

const investmentWorkflowEnabled = bool.fromEnvironment(
  'INVESTMENT_WORKFLOW_ENABLED',
);
// A nonvisual identity marker lets the release wrapper verify the compiled
// branch, rather than trusting the environment that was meant to reach Flutter.
const investmentWorkflowBuildMarker = investmentWorkflowEnabled
    ? 'thesisforge-workflow-enabled-v1'
    : 'thesisforge-workflow-disabled-v1';
bool isInvestmentMode(String mode) =>
    investmentWorkflowEnabled &&
    const {
      'home',
      'research',
      'discover',
      'book',
      'strategies',
      'hedge',
    }.contains(mode);

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const _apiBaseUrl = String.fromEnvironment('API_BASE_URL');
const _adminEmail = 'luyudong1136@gmail.com';
const _authDevBypass = String.fromEnvironment(
  'AUTH_DEV_BYPASS',
  defaultValue: 'false',
);
const _localDevToken = 'local-dev-token';

bool get _authConfigured =>
    _supabaseUrl.trim().isNotEmpty && _supabaseAnonKey.trim().isNotEmpty;

bool isAdminEmail(String value) => value.trim().toLowerCase() == _adminEmail;

// This controls presentation only. The API independently verifies the session
// and owner email before returning any administration data.
bool canShowAdmin({required String email, required String accessToken}) =>
    accessToken.trim().isNotEmpty &&
    accessToken != _localDevToken &&
    isAdminEmail(email);

enum AppLanguage { zh, en }

AppLanguage parseAppLanguage(String? value) =>
    text(value).trim().toLowerCase().startsWith('zh')
    ? AppLanguage.zh
    : AppLanguage.en;

String appLanguageCode(AppLanguage language) =>
    language == AppLanguage.zh ? 'zh' : 'en';

String trFor(AppLanguage language, String zh, String en) =>
    language == AppLanguage.en ? en : zh;

bool isRetiredModuleRoute(String? value, {String? path}) {
  final mode = value?.trim().toLowerCase() ?? '';
  final normalizedPath = path?.trim().toLowerCase() ?? '';
  return const {'ontology', 'dbmf'}.contains(mode) ||
      const ['/ontology', '/dbmf'].any(
        (prefix) =>
            normalizedPath == prefix || normalizedPath.startsWith('$prefix/'),
      );
}

String? retiredModuleReturnPath(
  String? value, {
  AppLanguage fallbackLanguage = AppLanguage.en,
}) {
  final candidate = value?.trim() ?? '';
  if (candidate.isEmpty) return null;
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  final Map<String, String> params;
  try {
    params = uri.queryParameters;
  } on FormatException {
    return null;
  }
  if (!isRetiredModuleRoute(params['view'] ?? params['mode'], path: uri.path)) {
    return null;
  }
  // Old login return links are local-only. Retired module state and fragments
  // are not forwarded; the authenticated account opens the current workspace.
  final language = params.containsKey('lang')
      ? parseAppLanguage(params['lang'])
      : fallbackLanguage;
  return Uri(
    path: '/',
    queryParameters: {'view': 'discover', 'lang': appLanguageCode(language)},
  ).toString();
}

class LanguageScope extends InheritedWidget {
  const LanguageScope({
    super.key,
    required this.language,
    required super.child,
  });

  final AppLanguage language;

  static AppLanguage of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.language ??
      AppLanguage.en;

  @override
  bool updateShouldNotify(covariant LanguageScope oldWidget) =>
      oldWidget.language != language;
}

extension LanguageContext on BuildContext {
  AppLanguage get language => LanguageScope.of(this);
  bool get isEnglish => language == AppLanguage.en;
  bool get isChinese => language == AppLanguage.zh;
  String tr(String zh, String en) => trFor(language, zh, en);
  String ui(String english) => localizeUiText(language, english);
}

const _uiChinese = <String, String>{
  'Other outstanding equity claims': '其他未结算股权索偿',
  'Option and warrant claims': '期权及认股权证索偿',
  'Economic cash-flow bridge': '经济现金流调整',
  'Dated acquisition/other common-equity claims deducted once after the valuation blend. Net debt and recurring SBC are not deducted again here.':
      '按对应日期的收购及其他股权索偿，在综合估值之后扣除一次；此处不再重复扣除净债务或经常性股票薪酬。',
  'Intrinsic/if-converted claims at model value, with exercise proceeds and reviewed unrecognized-service-cost credits. Credits are assumed proceeds, not cash. Customer-warrant contra-revenue is normalized first; option time value is excluded.':
      '按模型价值计算内在价值及行权所得，并抵减已审核的未确认服务成本。抵减为模型假设所得，不是真实现金；客户认股权证的非现金收入抵减先行归一化，不含期权时间价值。',
  'Reported CFO less cash capex, financing-classified operating license payments and recurring SBC. Reported GAAP inputs are preserved separately from any customer-warrant operating normalization.':
      '报告经营现金流减去现金资本开支、归入融资活动的经营性许可付款及经常性股票薪酬。报告 GAAP 数据与客户认股权证的经营归一化调整分别保留。',
  'Revenue (warrant-normalized)': '收入（认股权证调整后）',
  'Reported FCF (TTM)': '报告自由现金流（TTM）',
  'Economic FCFE (TTM)': '经济股权现金流（TTM）',
  'SBC deducted (TTM)': '扣除股票薪酬（TTM）',
  'License cash deducted (TTM)': '扣除许可付款（TTM）',
  'Cash & unrestricted investments': '现金及非受限投资',
  'Funded debt': '融资债务',
  'Operating lease liabilities': '经营租赁负债',
  'Lease cash costs remain in operating cash flow; operating leases are not deducted again as funded debt.':
      '租赁现金成本已包含在经营现金流中；经营租赁负债不再作为融资债务重复扣除。',
  'Economic cash flow is an analyst adjustment, not reported FCF. Amounts are in the selected security currency.':
      '经济现金流为分析师调整口径，并非公司报告自由现金流；金额使用该证券对应币种。',
  'Guru Intelligence Executive Summary': 'Guru Intelligence 研究终端',
  'GURU INTELLIGENCE': 'GURU INTELLIGENCE',
  '13F copy simulation': '13F 复制模拟',
  'STOCK Act copy simulation': 'STOCK Act 复制模拟',
  'Not eligible for 13F copy': '不进行 13F 复制',
  '13F market value': '13F 市值',
  'Reported 13F table value': '申报的 13F 信息表价值',
  'Reported common-long': '申报的普通股多头',
  'Reported options': '申报的期权',
  'Reported 13F value': '申报的 13F 价值',
  'information-table total': '信息表合计',
  '13F information-table total': '13F 信息表合计',
  'excludes reported options': '不含申报期权',
  'puts and calls in table': '信息表中的看跌/看涨期权',
  'latest disclosed': '最新披露',
  'waiting filing': '等待申报',
  'vs quarter end': '相对季度末',
  'Form 4 tickers tracked': '已跟踪 Form 4 股票',
  'latest post-transaction': '最近交易后持仓',
  'Form 4 trail': 'Form 4 记录',
  'profile': '资料',
  'local_missing': '本地缺失',
  'Concentrated activist compounders': '集中型维权复利股',
  'Founder-controlled liquidity': '创始人控制与流动性',
  'Control holder + liquidity signals': '控股人与流动性信号',
  'Tech and growth public equities': '科技与成长型公开市场股票',
  'Social Capital public 13F proxy': 'Social Capital 公开 13F 代理组合',
  'Systematic multi-factor U.S. long-equity disclosure': '系统化多因子美股多头披露',
  'Macro-informed concentrated 13F': '宏观驱动的集中型 13F',
  'Concentrated technology and travel compounders': '集中型科技与旅行复利股',
  'Tiger Cub technology and global growth equities': 'Tiger Cub 科技与全球成长股',
  'Tiger Cub technology and growth equities': 'Tiger Cub 科技与成长股',
  'Concentrated value compounders': '集中型价值复利股',
  'Three-legged-stool quality compounding': '三支柱高质量复利策略',
  'Concentrated quality compounders': '集中型高质量复利股',
  'Value discipline and Berkshire-oriented quality': '价值纪律与伯克希尔导向的高质量策略',
  'Patient concentrated value and growth': '耐心持有的集中型价值与成长策略',
  'Long-duration disruptive growth strategy': '长周期颠覆式成长策略',
  'Quality compounders, long holding periods': '高质量复利股与长期持有',
  'Quality growth compounders': '高质量成长复利股',
  'Patient growth and innovation platforms': '耐心持有的成长与创新平台',
  'Founder and board disclosures': '创始人与董事会披露',
  'Congressional trading disclosure lag': '国会交易披露滞后',
  'Venture operator Form 4 disclosures': '创投运营者 Form 4 披露',
  'Sparse operating-founder Form 4 disclosures': '稀疏的运营型创始人 Form 4 披露',
  'Venture and board-level Form 4 disclosures': '创投与董事会层面 Form 4 披露',
  'Founder CEO Form 4 selling and ownership': '创始人 CEO Form 4 减持与持股',
  'Insurance float and concentrated value compounders': '保险浮存金与集中型价值复利股',
  'Insurance float and long-term quality/value equities': '保险浮存金与长期高质量价值股',
  'Archived long-term compounder case study': '归档的长期复利股案例研究',
  'Multi-strategy public equities': '多策略公开市场股票',
  'Concentrated global compounders and active ownership': '集中型全球复利股与积极所有权',
  'Macro-aware value, cyclicals, and dislocated growth': '宏观驱动的价值、周期与错位成长',
  'Event-driven activism and catalyst-oriented equities': '事件驱动型维权与催化剂投资',
  'Deep value, downside protection, and special situations': '深度价值、下行保护与特殊机会',
  'Concentrated operational activism in durable franchises': '耐久品牌中的集中型经营维权',
  'Fundamental long-short growth and quality equities': '基本面多空成长与高质量股票',
  'Value, short research, and catalyst-driven equities': '价值、做空研究与催化剂投资',
  'Low-risk, high-uncertainty value and concentrated bets': '低风险、高不确定性的价值集中投资',
  'Concentrated quality compounders with durable moats': '具备持久护城河的集中型质量复利股',
  'Heard Capital public long-equity portfolio': 'Heard Capital 公开多头股票组合',
  'Concentrated profitable businesses with competitive advantages':
      '集中持有具备竞争优势的盈利企业',
  'Pacific Heights reportable long-equity sleeve':
      'Pacific Heights 申报范围内的多头股票部分',
  'Defender Capital public long-equity portfolio': 'Defender Capital 公开多头股票组合',
  'Audited manager-level public 13F model: the strict 5Y curve keeps uncovered weight in cash and requires 90% execution coverage; the extended 10Y public-sleeve proxy, when needed, renormalizes only fully priceable Top-60 holdings. This is not the Medallion Fund portfolio.':
      '经审计的管理人级公开 13F 模型：严格 5 年曲线将未覆盖权重保留为现金，并要求 90% 执行覆盖率；扩展 10 年视图在必要时使用公开持仓代理，只对 Top-60 中可完整定价的持仓重新归一化。这不是 Medallion Fund 持仓。',
  'This disclosure is not a complete quarterly 13F portfolio; copied rebalancing would be misleading.':
      '该披露不是完整季度13F组合，复制调仓会失真。',
  'Copy public 13F long-only weights on filing publication dates and backtest the trailing five audited years against SPY.':
      '按披露发布日复制公开13F长仓权重，并用最近五年可审计数据和 SPY 回测。',
  'Approximate copied trades using public disclosure dates and transaction-value ranges, then compare with SPY.':
      '按公开披露日和交易金额区间做近似复制，并和SPY对比。',
  'Counterpoint Global does not publish a clean standalone team-level 13F feed, so the app does not run proportional 13F copy-trading for this profile.':
      'Counterpoint Global 没有发布独立、干净的团队级 13F 数据，因此本档案不进行按比例的 13F 复制交易。',
  'Nomad is closed and has no current quarterly 13F feed; historical holdings are useful for case study work but not for live five-year copy-trading.':
      'Nomad 已关闭，也没有当前季度 13F 数据；历史持仓适合案例研究，不适合实时五年复制交易。',
  'Account': '账户',
  'Logout': '退出登录',
  'Refresh': '刷新',
  'Color contrast': '色彩对比',
  'Guru Stock Analysis': 'Guru 股票研究',
  'Local SQLite': '本地 SQLite',
  'Local': '本地',
  'Gurus': '投资人',
  'Firms': '机构',
  'Search guru / firm / ticker': '搜索投资人、机构或股票',
  'All': '全部',
  'Profile': '资料',
  '13F fund': '13F 基金',
  'Form 4': 'Form 4 高管交易',
  'STOCK Act': '国会交易',
  'Disclosure': '公开披露',
  'All Strategies': '全部策略',
  'All Status': '全部状态',
  'GURU UNIVERSE': '投资人名单',
  'Select Guru': '选择投资人',
  'No gurus match this filter.': '没有符合当前筛选的投资人。',
  'Select a guru to inspect.': '请选择一位投资人查看详情。',
  'Holdings': '持仓数',
  'Latest Quarter': '最新季度',
  'Filing Lag': '披露滞后',
  'Strategy': '策略',
  'Stocks': '股票数',
  'Held shares': '持有股数',
  'Cum sold': '累计卖出',
  'Latest': '最新',
  'Focus': '关注方向',
  'Source': '数据来源',
  'Activity': '动态',
  'RESEARCH PROFILE': '研究档案',
  'COPY SIMULATION': '组合模拟',
  'Backtest is not ready.': '回测尚未准备完成。',
  'Extended-history audit not ready': '扩展历史审计尚未准备完成',
  'The requested extended-history backtest is not pre-warmed under the current audit method. The request failed closed without starting a cold synchronous computation.':
      '所选扩展历史尚未按当前审计方法预热。系统已严格停止请求，且没有启动同步冷计算。',
  'At least one filing falls below the minimum adjusted-close execution coverage; the backtest fails closed instead of renormalizing the covered subset.':
      '至少一个申报季度的复权收盘价执行覆盖率低于最低要求；为避免对有价格的持仓重新归一化并夸大结果，回测已按严格规则停止。',
  'Historical filings were found, but no holdings had usable adjusted-close ticker coverage.':
      '已找到历史申报，但没有持仓具备可用的股票代码和复权收盘价覆盖。',
  'SPY adjusted-close total-return history is unavailable; the backtest fails closed instead of substituting price return.':
      'SPY 的复权收盘价总回报历史不可用；回测不会用未复权价格收益替代。',
  'Not enough historical 13F filings or SPY price points are available.':
      '历史 13F 申报或 SPY 价格数据不足，无法完成回测。',
  'A held security lacks an adjusted-close observation while active; the backtest fails closed instead of booking a zero return or carrying a stale quote.':
      '某只持仓在持有期间缺少复权收盘价；回测不会记作零收益或沿用过期报价。',
  'The drifted-position return engine did not pass its coverage or attribution reconciliation gate.':
      '漂移持仓收益引擎未通过覆盖率或归因核对门禁。',
  'Multiple disclosure events resolve to the same execution date; the backtest fails closed instead of applying ambiguous same-close rebalance order.':
      '多个披露事件落在同一执行日；因无法确定同一收盘价下的调仓顺序，回测已按严格规则停止。',
  'Not enough usable disclosed transactions or SPY price points are available.':
      '可用的已披露交易或 SPY 价格数据不足，无法完成回测。',
  'Disclosed transactions were found, but no tickers had usable price coverage at disclosure execution dates.':
      '已找到披露交易，但相关股票在披露执行日均缺少可用价格覆盖。',
  'Excess': '超额收益',
  'MDD': '最大回撤',
  'No buy/sell rows available.': '暂无买卖记录。',
  'No disclosure rows available.': '暂无披露记录。',
  'Search ticker / company': '搜索股票或公司',
  'Clear': '清除',
  'NEW / EXIT': '新买入 / 清仓',
  'QUARTERLY ATTRIBUTION': '季度贡献',
  'No quarterly attribution available.': '暂无季度贡献数据。',
  'QUICK LINKS': '快捷入口',
  'OVERVIEW': '概览',
  'SIGNAL BOARD': '信号板',
  'No fresh signals in the current local database.': '当前数据库暂无最新信号。',
  'TICKER HEATMAP': '股票热力图',
  'No external consensus exposure after filtering.': '筛选后没有外部共识敞口。',
  'LATEST FILINGS': '最新申报',
  'ADD RANKING': '加仓排行',
  'TRIM RANKING': '减仓排行',
  'No recent 13F filings in the current local database.': '当前数据库暂无近期 13F 申报。',
  'No add/new rows in the current local database.': '当前数据库暂无新增或加仓记录。',
  'No reduce/sell-out rows in the current local database.': '当前数据库暂无减仓或清仓记录。',
  'What changed in the public tape': '公开信息发生了什么变化',
  'Crowded external consensus': '拥挤的外部共识',
  'founders filtered': '已排除创始人',
  'LATEST FLOW': '最新资金流',
  'DISCLOSURE TRAIL': '披露记录',
  'Quarterly operations': '季度操作',
  'Recent records': '近期记录',
  'Top holdings': '前几大持仓',
  'No activity rows available.': '暂无动态记录。',
  'Not copy-tradable': '不可复制交易',
  'Portfolio vs SPY': '组合与 SPY 对比',
  'Reported position changes': '申报的持仓变化',
  'REPORTED POSITION CHANGES': '申报持仓变化',
  'Quarterly Contribution': '季度贡献',
  'No equity curve available.': '暂无净值曲线。',
  'OWNER ADMIN': '管理员',
  'Portfolio admin console': '组合管理后台',
  'View all user-scoped IBKR/Yodlee portfolio databases in read-only mode.':
      '以只读方式查看所有用户独立的 IBKR/Yodlee 组合数据库。',
  'Users': '用户数',
  'Accounts': '账户数',
  'Latest NAV': '最新净值',
  'Errors': '错误',
  'SYSTEM HEALTH': '系统健康',
  'Refresh health': '刷新系统状态',
  'Loading system health...': '正在载入系统状态…',
  'No background jobs were reported yet.': '尚未收到后台任务报告。',
  'USER DATABASES': '用户数据库',
  'Refresh admin index': '刷新用户索引',
  'Search email / name / hash': '搜索邮箱、姓名或哈希',
  'No portfolio users found yet.': '尚未找到组合用户。',
  'Select a portfolio user to inspect.': '请选择一位组合用户查看详情。',
  'Portfolio detail has not loaded yet.': '组合详情尚未载入。',
  'SELECTED USER': '所选用户',
  'Refresh detail': '刷新详情',
  'PORTFOLIO MANAGEMENT': '组合管理',
  'Portfolio cockpit': '组合驾驶舱',
  'IBKR holdings synced through Yodlee.': 'IBKR 持仓已通过 Yodlee 同步。',
  'Yodlee / IBKR connector is ready; credentials are not configured yet.':
      'Yodlee / IBKR 连接器已就绪，但尚未配置凭证。',
  'Net liquidation': '净清算价值',
  'Day P/L': '当日盈亏',
  'Unrealized': '未实现盈亏',
  'Cash': '现金',
  'Top weight': '最大持仓权重',
  'PERFORMANCE': '表现',
  'IBKR did not return real portfolio NAV history for this query.':
      'IBKR 未为本次查询返回真实组合净值历史。',
  'ADMIN READ-ONLY': '管理员只读',
  'No linked accounts are visible yet.': '暂未看到已连接账户。',
  'PRIVATE PORTFOLIO': '私人组合',
  'Latest sync failed.': '最近一次同步失败。',
  'Disconnecting': '正在断开',
  'Disconnect all': '断开全部账户',
  'PORTFOLIO ACCOUNT': '组合账户',
  'Close': '关闭',
  'Account label': '账户名称',
  'Yodlee Token': 'Yodlee Token',
  'Hide token': '隐藏 Token',
  'Show token': '显示 Token',
  'Yodlee Query ID': 'Yodlee Query ID',
  'Cancel': '取消',
  'Adding': '正在添加',
  'Add & update': '添加并更新',
  'Connecting': '正在连接',
  'Save & sync': '保存并同步',
  'HOLDING MIX': '持仓构成',
  'positive MV': '正市值',
  'Other': '其他',
  'Other holdings': '其他持仓',
  'No positive holdings to chart.': '暂无可绘制的正持仓。',
  'PORTFOLIO ANALYTICS': '组合分析',
  'Portfolio analytics are not available yet.': '组合分析暂不可用。',
  'Historical risk uses one-year daily returns; forward return is a model-implied scenario.':
      '历史风险采用过去一年日收益；前瞻回报为模型推演情景。',
  'No portfolio holdings are available for valuation analysis.':
      '暂无可用于估值分析的组合持仓。',
  'DIVIDENDS': '股息',
  'Dividend calendar': '股息日历',
  'Current portfolio feed did not return dividend calendar events.':
      '当前组合数据源未返回股息日历事件。',
  'Previous month': '上个月',
  'Next month': '下个月',
  'No dividend events match this filter.': '没有符合当前筛选的股息事件。',
  'Search ticker': '搜索股票',
  'Monthly': '每月',
  'Daily': '每日',
  'Yield': '股息率',
  'No payout bars for this window.': '当前区间没有股息柱状数据。',
  'No 2025/2026 dividend history for this filter.': '当前筛选没有 2025/2026 股息历史。',
  'Calendar': '日历',
  'List': '列表',
  'One year ahead': '未来一年',
  '2025 paid history': '2025 已支付历史',
  '2026 paid + forecast': '2026 已支付 + 预测',
  'Date': '日期',
  'Payout': '股息',
  'Base': '本币',
  'Holdings:': '持仓：',
  'base': '本币',
  'per share': '每股',
  'SUN': '周日',
  'MON': '周一',
  'TUE': '周二',
  'WED': '周三',
  'THU': '周四',
  'FRI': '周五',
  'SAT': '周六',
  'Jan': '1 月',
  'Feb': '2 月',
  'Mar': '3 月',
  'Apr': '4 月',
  'May': '5 月',
  'Jun': '6 月',
  'Jul': '7 月',
  'Aug': '8 月',
  'Sep': '9 月',
  'Oct': '10 月',
  'Nov': '11 月',
  'Dec': '12 月',
  'ACCOUNTS': '账户',
  'IBKR accounts': 'IBKR 账户',
  'No linked accounts yet.': '尚未连接账户。',
  'ALLOCATION': '资产配置',
  'RISK': '风险',
  'HOLDINGS': '持仓',
  'No holdings from Yodlee yet.': 'Yodlee 尚未返回持仓。',
  'FV gap': '估值差距',
  'PIT fundamentals, peer value capture, and graph-confirmed decisions.':
      'PIT 基本面、同行价值捕获与图谱确认决策。',
  'Current Signals': '当前信号',
  'Model Holdings': '模型持仓',
  'Evaluation CAGR': '评估期复合年化收益',
  'Max Drawdown': '最大回撤',
  'tradable candidates': '可交易候选',
  'current 12M book': '当前 12 个月组合',
  'evaluation period': '评估期',
  'Historical': '历史',
  'peer-confirmed': '同行确认',
  'graph-confirmed': '图谱确认',
  'monthly snapshots': '月度快照',
  '2018–2026 evaluation': '2018–2026 评估期',
  '2010–2016 development': '2010–2016 开发期',
  'Daily · net of modeled costs': '日频 · 已扣模拟成本',
  'Strategy return': '策略收益',
  'SPY return': 'SPY 收益',
  'Strategy CAGR': '策略年化收益',
  'Max drawdown': '最大回撤',
  'Period': '期间',
  'Model': '模型',
  'Alpha': '超额',
  'graph confirmed': '图谱确认',
  'peer capture': '同行确认',
  'observe': '观察',
  'PIT REPLAY': 'PIT 回放',
  'Decision history': '决策历史',
  'No PIT history is available.': '暂无 PIT 历史。',
  'Latest snapshot': '最新快照',
  'REALIZED BACKTEST': '真实回测',
  'Historical NAV vs SPY': '历史净值与 SPY 对比',
  'Historical NAV is not present in this snapshot.': '当前快照没有历史净值。',
  'DECISION BOARD': '决策板',
  'Latest PIT signals': '最新 PIT 信号',
  'Historical PIT signals': '历史 PIT 信号',
  'No tradable PIT signals for this month.': '本月没有可交易的 PIT 信号。',
  'CURRENT BOOK': '当前组合',
  'Model holdings': '模型持仓',
  'VALIDATION': '验证',
  'Strategy vs SPY': '策略与 SPY 对比',
  'POINT-IN-TIME BOOK': '时点组合',
  'INDUSTRY MAP': '行业地图',
  'TICKER RESEARCH': '个股研究',
  'SELECTED RESEARCH': '当前研究',
  'Select a ticker from the matrix.': '请从矩阵中选择一只股票。',
  'No historical valuation or price series available.': '暂无历史估值或股价序列。',
  'Fair value': '公允价值',
  'Historical nodes use point-in-time data; model-version reproducibility is shown separately.':
      '历史节点使用时点数据；模型版本可复现性单独展示。',
  'Quarter price': '季度股价',
  'Daily price': '每日股价',
  'No quarterly valuation history.': '暂无季度估值历史。',
  'Recent quarterly valuation history': '近期季度估值历史',
  'QUARTERLY MODEL BOOK': '季度模型档案',
  'MODEL INPUTS': '模型输入',
  'Revenue': '收入',
  'Revenue growth': '收入增速',
  'Operating margin': '营业利润率',
  'Normalized margin': '标准化利润率',
  'FCF after capex': '资本开支后自由现金流',
  'Shares': '股数',
  'Guidance used by model': '模型采用的管理层指引',
  'Revenue guide': '收入指引',
  'Margin guide': '利润率指引',
  'MODEL OUTPUT': '模型输出',
  'Price at date': '当期股价',
  'Upside': '上涨空间',
  '3Y scenario': '三年情景值',
  'PODCAST RADAR': '播客雷达',
  'CALL TRANSCRIPT Q&A': '电话会问答',
  'evidence strength': '证据强度',
  'DISTRIBUTION': '估值分布',
  'Where the model sees value': '模型认为价值在哪里',
  'Deep value': '深度低估',
  'Fair range': '合理区间',
  'Expensive': '偏贵',
  'MODEL CONTROL': '模型控制',
  'Price excluded from fair value': '市场价格不参与公允价值计算',
  'Retry': '重试',
  'Coverage': '覆盖范围',
  'gurus': '位投资人',
  'long equity': '多头股票',
  'Spread': '信号差',
  'buy minus sell': '买入减卖出',
  'Quarter': '季度',
  'latest filing': '最新申报',
  'Report': '报告日期',
  'Filed': '申报日期',
  'shares': '股',
  'owner only': '仅管理员',
  'read-only detail': '详情只读',
  'encrypted tokens hidden': '加密 Token 已隐藏',
  'linked': '已连接',
  'stale_report': '已保存报告（同步暂不可用）',
  'linked_partial': '部分账户同步失败',
  'Saved broker report': '已保存的券商报告',
  'Saved portfolio report': '已保存的组合报告',
  'Report day P/L': '报告日盈亏',
  'IBKR/Yodlee saved': '已保存 IBKR/Yodlee',
  'sum of latest stored NAV': '最新已存净值合计',
  'sync or decrypt issues': '同步或解密问题',
  'healthy': '健康',
  'running': '运行中',
  'failed': '失败',
  'unknown': '未知',
  'Data jobs': '数据任务',
  'Uptime': '运行时长',
  'Origins': '允许来源',
  'No completed run': '尚无已完成运行',
  'Job': '任务',
  'Guru dashboard data': 'Guru 仪表盘数据',
  'Guru simulation / backtests': 'Guru 模拟 / 回测',
  'Valuation models': '估值模型',
  'Podcast / YouTube insights': '播客 / YouTube 洞察',
  'User portfolio sync': '用户组合同步',
  'Portfolio NAV recorder': '组合净值记录器',
  'Run started but no completion was recorded.': '任务已开始，但没有完成记录。',
  'No recorded run yet.': '尚无运行记录。',
  'Latest run is getting stale.': '最近一次运行数据开始陈旧。',
  'Status': '状态',
  'Paid': '已支付',
  'Declared': '已宣布',
  'Estimated': '预估',
  'Payout type': '日期类型',
  'Pay date': '支付日',
  'Ex-date': '除息日',
  'Annual income': '年度收入',
  'events': '事件',
  'current-weight backsolve': '按当前权重回溯',
  'Portfolio': '组合',
  'Positions': '持仓数',
  'Ticker': '股票代码',
  '1Y / Vol': '一年收益 / 波动',
  'Forward': '前瞻回报',
  'Weight': '权重',
  'Top 5 weight': '前五大持仓权重',
  'Cash weight': '现金权重',
  'Unrealized P/L': '未实现盈亏',
  'No model': '无模型',
  'USD Cash': '美元现金',
  'Brokerage': '经纪账户',
  'Technology': '科技',
  'Semiconductors': '半导体',
  'Consumer Internet': '消费互联网',
  'Communication Services': '通信服务',
  'Software': '软件',
  'Media': '媒体',
  'Healthcare': '医疗保健',
  'Financial Services': '金融服务',
  'Industrials': '工业',
  'Consumer Cyclical': '周期消费',
  'Consumer Defensive': '防御性消费',
  'Energy': '能源',
  'Utilities': '公用事业',
  'Real Estate': '房地产',
  'Basic Materials': '原材料',
  'No real portfolio NAV history was returned by the upstream source.':
      '上游数据源未返回真实的组合净值历史。',
  'Current-weight reconstruction; historical risk from one-year daily returns; forward return from partial fair-value gap convergence, 3Y model IRR, and capped momentum.':
      '按当前权重重建；历史风险来自过去一年日收益；前瞻回报综合部分估值差收敛、三年模型 IRR 与封顶动量。',
  'IBKR/Yodlee credentials are not configured. Showing local sample structure.':
      '尚未配置 IBKR / Yodlee 凭证，当前显示本地示例结构。',
  'Local SQLite valuation database': '本地 SQLite 估值数据库',
  'Portfolio module sample': '组合模块示例',
  'Sample portfolio — not an account': '示例组合 — 非真实账户',
  'Illustrative local data only. It is not connected to your brokerage account.':
      '仅为本地示例数据，未连接您的任何券商账户。',
  'SAMPLE DATA · NOT AN ACCOUNT': '示例数据 · 非真实账户',
  'Sample total': '示例总值',
  'Sample day P/L': '示例当日盈亏',
  'Sample unrealized': '示例未实现盈亏',
  'Sample cash': '示例现金',
  'SAMPLE STRUCTURE': '示例结构',
  'Illustrative account': '示例账户',
  'Nasdaq dividend calendar': 'Nasdaq 股息日历',
  'Yahoo dividend history': 'Yahoo 历史股息',
  'Yahoo dividend history estimate': 'Yahoo 历史股息预估',
  'Paid dividend': '已支付股息',
  'Declared dividend': '已宣布股息',
  'Estimated dividend': '预估股息',
  'SEC CompanyFacts + YouTube earnings-call transcript metric database':
      'SEC CompanyFacts + YouTube 财报电话会逐字稿指标数据库',
  'Jansen Sharadar as-reported PIT financials + event-visible management guidance':
      'Jansen Sharadar 原始披露口径的 PIT 财务数据 + 当时可见的管理层指引',
  'Jansen Sharadar PIT financials + event-visible guidance':
      'Jansen Sharadar PIT 财务数据 + 当时可见的管理层指引',
  'methodology': '方法说明',
  'FV coverage': '估值覆盖率',
  'price coverage': '股价覆盖率',
  'gap close': '估值差收敛',
  'COMPANY': '公司',
  'UPSIDE / DOWNSIDE': '上涨 / 下跌空间',
  'PRICE / FV': '股价 / 公允价值',
  'QUALITY': '质量',
  '3Y SCENARIO': '三年情景值',
  'not configured': '未配置',
  'no_database': '无数据库',
  'Unknown user': '未知用户',
  'Email': '邮箱',
  'concentration': '集中度',
  'Admin view reads the selected user portfolio database without exposing saved credentials.':
      '管理员视图只读所选用户的组合数据库，不会暴露已保存凭证。',
  'IBKR account': 'IBKR 账户',
  'per-user encrypted DB': '用户独立加密数据库',
  'IBKR host allowlisted': 'IBKR 主机已加入白名单',
  'no browser token storage': '浏览器不保存 Token',
  'one-time setup': '仅需设置一次',
  'Current IBKR report has fewer than two NAV points.':
      '当前 IBKR 报告中的净值数据点少于两个。',
  'saved': '已保存',
  'pass': '通过',
  'watch': '观察',
  'quarterly': '季度',
  'model': '模型',
  'audit': '审计',
  'no consensus guardrail': '无外部共识校验',
  'no_external_consensus': '无外部共识',
  'consensus': '外部共识',
  'street': '市场共识',
  'live': '实时',
  'cached': '缓存',
  'error': '错误',
};

final _uiEnglish = <String, String>{
  for (final entry in _uiChinese.entries) entry.value: entry.key,
};

String localizeUiText(AppLanguage language, String source) {
  if (source.trim().isEmpty) return source;
  final enumLabel = switch (source) {
    'not_configured' => trFor(language, '未配置', 'Not configured'),
    'no_database' => trFor(language, '无数据库', 'No database'),
    'local_missing' => trFor(language, '本地缺失', 'Missing locally'),
    'not_available' => trFor(language, '暂不可用', 'Not available'),
    'ready' => trFor(language, '就绪', 'Ready'),
    'healthy' => trFor(language, '正常', 'Healthy'),
    'stale' => trFor(language, '数据陈旧', 'Stale'),
    'sample' => trFor(language, '示例', 'Sample'),
    'error' => trFor(language, '错误', 'Error'),
    'review' => trFor(language, '需复核', 'Review'),
    'fail' => trFor(language, '未通过', 'Fail'),
    'verified' => trFor(language, '已验证', 'Verified'),
    'not_verified' => trFor(language, '未验证', 'Not verified'),
    'not_validated' => trFor(language, '未做经济验证', 'Not validated'),
    'guardrail_only' => trFor(language, '仅作比较护栏', 'Guardrail only'),
    'not_run' => trFor(language, '未运行', 'Not run'),
    'full' => trFor(language, '完整', 'Full'),
    'neutral' => trFor(language, '中性', 'Neutral'),
    _ => null,
  };
  if (enumLabel != null) return enumLabel;
  if (source == '13F copy 模拟') {
    return trFor(language, '13F 复制模拟', '13F copy simulation');
  }
  if (source == 'STOCK Act copy 模拟') {
    return trFor(language, 'STOCK Act 复制模拟', 'STOCK Act copy simulation');
  }
  if (source == '不做13F复制') {
    return trFor(language, '不进行 13F 复制', 'Not eligible for 13F copy');
  }
  final genericAccountCount = RegExp(r'^(\d+) accounts$').firstMatch(source);
  if (genericAccountCount != null) {
    final count = genericAccountCount.group(1)!;
    return trFor(
      language,
      '$count 个账户',
      '$count ${count == '1' ? 'account' : 'accounts'}',
    );
  }
  if (language == AppLanguage.en) return _uiEnglish[source] ?? source;
  final exact = _uiChinese[source];
  if (exact != null) return exact;
  if (source.startsWith('No ticker matched "') && source.endsWith('".')) {
    return '没有找到匹配的股票 ${source.substring(18, source.length - 2)}。';
  }
  if (source.startsWith('Next: ')) {
    return '下一项：${source.substring(6)}';
  }
  if (source.startsWith('No dividend events in ')) {
    return '当前月份没有股息事件：${source.substring(22)}';
  }
  final timeoutMatch = RegExp(
    r'^API request timed out after (\d+)s\. Please retry\.$',
  ).firstMatch(source);
  if (timeoutMatch != null) {
    return 'API 请求在 ${timeoutMatch.group(1)} 秒后超时，请重试。';
  }
  final httpStatusMatch = RegExp(r'^API (\d{3})$').firstMatch(source);
  if (httpStatusMatch != null) {
    return 'API 请求失败（状态码 ${httpStatusMatch.group(1)}）';
  }
  final nonJsonMatch = RegExp(
    r'^API returned non-JSON from (.+) \((.+)\)$',
  ).firstMatch(source);
  if (nonJsonMatch != null) {
    return 'API ${nonJsonMatch.group(1)} 返回了非 JSON 内容（${nonJsonMatch.group(2)}）';
  }
  if (source == 'API returned a non-object payload') {
    return 'API 返回的数据不是有效对象';
  }
  if (source.startsWith('Top discount: ')) {
    return source
        .replaceFirst('Top discount: ', '最大折价：')
        .replaceFirst(' at ', '，幅度 ');
  }
  if (source.startsWith('Most stretched: ')) {
    return source
        .replaceFirst('Most stretched: ', '估值最贵：')
        .replaceFirst(' at ', '，幅度 ');
  }
  if (source.contains(' · filed ')) {
    return source.replaceFirst(' · filed ', ' · 申报于 ');
  }
  if (source.endsWith(' Portfolio')) {
    return '${source.substring(0, source.length - 10)} 组合';
  }
  final visibleMatch = RegExp(r'^(\d+) visible$').firstMatch(source);
  if (visibleMatch != null) return '${visibleMatch.group(1)} 个可见';
  final countMatch = RegExp(
    r'^(\S+) (stocks|trades|holdings|shares)$',
  ).firstMatch(source);
  if (countMatch != null) {
    final unit = switch (countMatch.group(2)) {
      'stocks' => '只股票',
      'trades' => '笔交易',
      'holdings' => '项持仓',
      _ => '股',
    };
    return '${countMatch.group(1)} $unit';
  }
  final dayCountMatch = RegExp(r'^(\S+) days$').firstMatch(source);
  if (dayCountMatch != null) return '${dayCountMatch.group(1)} 天';
  if (source.startsWith('sold ')) return '累计卖出 ${source.substring(5)}';
  final accountCountMatch = RegExp(r'^(\S+) accounts$').firstMatch(source);
  if (accountCountMatch != null) return '${accountCountMatch.group(1)} 个账户';
  final eventCountMatch = RegExp(r'^(\S+) events$').firstMatch(source);
  if (eventCountMatch != null) return '${eventCountMatch.group(1)} 个事件';
  final companyCountMatch = RegExp(r'^(\S+) companies$').firstMatch(source);
  if (companyCountMatch != null) return '${companyCountMatch.group(1)} 家公司';
  final moreCountMatch = RegExp(r'^\+(\d+) more$').firstMatch(source);
  if (moreCountMatch != null) return '另有 ${moreCountMatch.group(1)} 项';
  final modelPnlMatch = RegExp(r'^(.*) model P/L$').firstMatch(source);
  if (modelPnlMatch != null) return '${modelPnlMatch.group(1)} 模型盈亏';
  final sharpeMatch = RegExp(r'^Sharpe (.+)$').firstMatch(source);
  if (sharpeMatch != null) return '夏普比率 ${sharpeMatch.group(1)}';
  final storedDividendMatch = RegExp(
    r'^Stored dividend calendar: (\d+) event\(s\), including paid history, declared events, and history-based estimates\.$',
  ).firstMatch(source);
  if (storedDividendMatch != null) {
    return '已保存股息日历：${storedDividendMatch.group(1)} 个事件，包含已支付历史、已宣布事件与基于历史的预估。';
  }
  if (source.startsWith('rf ')) return '无风险利率 ${source.substring(3)}';
  if (source.startsWith('FV coverage ')) {
    return '估值覆盖率 ${source.substring(12)}';
  }
  if (source.startsWith('price coverage ')) {
    return '股价覆盖率 ${source.substring(15)}';
  }
  if (source.startsWith('gap close ')) {
    return '估值差收敛 ${source.substring(10)}';
  }
  if (source.startsWith('PIT as of ')) {
    return 'PIT 截至 ${source.substring(10)}';
  }
  if (source.startsWith('Report ')) return '报告日期 ${source.substring(7)}';
  if (source.startsWith('Filed ')) return '申报日期 ${source.substring(6)}';
  if (source.startsWith('filed ')) return '申报于 ${source.substring(6)}';
  return source;
}

String guruBacktestPath(
  String guruId, {
  String years = '5',
  bool fullAttribution = false,
  bool refresh = false,
}) {
  final normalizedYears = years.trim().toLowerCase();
  if (!const {'5', '10', 'all'}.contains(normalizedYears)) {
    throw ArgumentError.value(years, 'years', 'Use 5, 10, or all.');
  }
  final query = <String>['years=$normalizedYears'];
  if (fullAttribution) query.add('detail=full');
  if (refresh) query.add('refresh=1');
  return '/api/gurus/$guruId/backtest?${query.join('&')}';
}

String? _guruBacktestWindowValue(Object? value) {
  final normalized = text(value).trim().toLowerCase();
  return const {'5', '10', 'all'}.contains(normalized) ? normalized : null;
}

bool _isStrictReadyBacktest(Map<String, dynamic>? payload) =>
    text(payload?['status']) == 'ready';

bool _isProxyReadyBacktest(Map<String, dynamic>? payload) =>
    text(payload?['status']) == 'proxy_ready';

bool _isDisplayableBacktest(Map<String, dynamic>? payload) =>
    _isStrictReadyBacktest(payload) || _isProxyReadyBacktest(payload);

Map<String, dynamic> _backtestReplicability(Map<String, dynamic>? payload) =>
    asMap(payload?['publicReplicability']);

String _replicabilityReason(
  BuildContext context,
  Map<String, dynamic> replicability,
) => context.tr(
  text(replicability['reasonZh'], '严格复制不可用。'),
  text(replicability['reasonEn'], 'Strict replication is unavailable.'),
);

String _replicabilityQuarterLabel(Map<String, dynamic> replicability) {
  final quarters = asList(replicability['affectedQuarters']);
  if (quarters.isEmpty) return '';
  final quarter = asMap(quarters.first);
  final declared = text(quarter['quarterLabel']);
  if (declared.isNotEmpty) return declared;
  final reportDate = DateTime.tryParse(text(quarter['reportDate']));
  if (reportDate == null) return '';
  return '${reportDate.year} Q${((reportDate.month - 1) ~/ 3) + 1}';
}

String _replicabilityTicker(Map<String, dynamic> replicability) {
  final quarters = asList(replicability['affectedQuarters']);
  if (quarters.isEmpty) return '';
  final holdings = asList(asMap(quarters.first)['holdings']);
  if (holdings.isEmpty) return '';
  final holding = asMap(holdings.first);
  return text(holding['ticker'], text(holding['issuer']));
}

String _replicabilityHoldingWeight(Map<String, dynamic> replicability) {
  final quarters = asList(replicability['affectedQuarters']);
  if (quarters.isEmpty) return '';
  final holdings = asList(asMap(quarters.first)['holdings']);
  if (holdings.isEmpty) return '';
  final holding = asMap(holdings.first);
  final raw = holding['reportedBookWeight'];
  if (raw == null) return '';
  final value = number(raw);
  if (!value.isFinite || value < 0 || value > 1) return '';
  return '${(value * 100).toStringAsFixed(1)}%';
}

bool _supabaseReady = false;
Object? _supabaseInitError;
Future<bool>? _supabaseInitFuture;

Future<bool> _ensureSupabaseReady({bool retry = false}) {
  if (!_authConfigured) return Future.value(false);
  if (_supabaseReady) return Future.value(true);
  if (retry) {
    _supabaseInitFuture = null;
    _supabaseInitError = null;
  }
  return _supabaseInitFuture ??= () async {
    try {
      await Supabase.initialize(
        url: _supabaseUrl,
        publishableKey: _supabaseAnonKey,
      ).timeout(const Duration(seconds: 8));
      _supabaseReady = true;
      _supabaseInitError = null;
      return true;
    } catch (error) {
      _supabaseInitError = error;
      return false;
    }
  }();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GuruTerminalApp());
}

class GuruTerminalApp extends StatefulWidget {
  const GuruTerminalApp({super.key});

  @override
  State<GuruTerminalApp> createState() => _GuruTerminalAppState();
}

class _GuruTerminalAppState extends State<GuruTerminalApp>
    with WidgetsBindingObserver {
  AppLanguage _language = parseAppLanguage(readBrowserQuery()['lang']);
  Uri _routeUri = Uri.base;
  int _routeRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    final nextLanguage = parseAppLanguage(
      routeInformation.uri.queryParameters['lang'],
    );
    setState(() {
      _routeUri = routeInformation.uri;
      _routeRevision++;
      _language = nextLanguage;
    });
    return Future<bool>.value(true);
  }

  void _setLanguage(AppLanguage language) {
    if (_language == language) return;
    setState(() => _language = language);
    replaceBrowserQuery({'lang': appLanguageCode(language)});
  }

  @override
  Widget build(BuildContext context) {
    return LanguageScope(
      language: _language,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: trFor(
          _language,
          'Guru Intelligence 研究终端',
          'Guru Intelligence Research Terminal',
        ),
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0B111D),
          fontFamily: 'Inter',
          colorScheme: ColorScheme.fromSeed(
            brightness: Brightness.dark,
            seedColor: const Color(0xFF22D3A6),
            surface: const Color(0xFF111827),
          ),
        ),
        home: AuthGate(
          key: const ValueKey(investmentWorkflowBuildMarker),
          language: _language,
          routeUri: _routeUri,
          routeRevision: _routeRevision,
          onLanguage: _setLanguage,
        ),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.language,
    required this.routeUri,
    this.routeRevision = 0,
    required this.onLanguage,
  });

  final AppLanguage language;
  final Uri routeUri;
  final int routeRevision;
  final ValueChanged<AppLanguage> onLanguage;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  bool _localWorkspace = !_authConfigured && _authDevBypass == 'true';
  String? _authMessageZh;
  String? _authMessageEn;
  Session? _session;
  StreamSubscription<AuthState>? _authSub;
  late final String? _returnTo = retiredModuleReturnPath(
    readBrowserQuery()['returnTo'],
    fallbackLanguage: widget.language,
  );

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap({bool retry = false}) async {
    if (retry) {
      await _authSub?.cancel();
      _authSub = null;
    }
    if (await _ensureSupabaseReady(retry: retry)) {
      final client = Supabase.instance.client;
      _session = client.auth.currentSession;
      _authSub = client.auth.onAuthStateChange.listen(
        (event) {
          if (!mounted) return;
          setState(() => _session = event.session);
          if (event.event == AuthChangeEvent.signedIn &&
              event.session != null) {
            unawaited(
              recordAuthenticatedVisit(
                ApiClient(() => event.session!.accessToken),
              ),
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted) return;
          setState(() {
            _setAuthMessage(
              '身份验证连接暂时中断，可在页内重试。',
              'The auth connection was interrupted. Retry on this page.',
            );
          });
        },
      );
      if (_session != null && _returnTo != null) {
        try {
          final refreshed = await client.auth.refreshSession();
          _session = refreshed.session ?? client.auth.currentSession;
        } catch (_) {
          _session = client.auth.currentSession;
          if (_session?.isExpired ?? false) {
            await client.auth.signOut();
            _session = null;
            _setAuthMessage(
              '登录会话已过期，请重新登录后继续。',
              'Your session expired. Sign in again to continue.',
            );
          }
        }
        if (_session != null) {
          final session = _session!;
          await recordAuthenticatedVisit(ApiClient(() => session.accessToken));
          openBrowserPath(_returnTo);
          return;
        }
      }
      final session = _session;
      if (session != null) {
        unawaited(
          recordAuthenticatedVisit(ApiClient(() => session.accessToken)),
        );
      }
    } else if (_authConfigured) {
      _setAuthMessage(
        'Supabase 身份验证初始化失败，请检查网络、DNS 与 Supabase URL。',
        'Supabase auth did not initialize. Check DNS/network and Supabase URL.',
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _retryBootstrap() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _authMessageZh = null;
      _authMessageEn = null;
    });
    await _bootstrap(retry: true);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    if (!await _ensureSupabaseReady()) {
      if (!mounted) return;
      setState(() {
        _setAuthMessage(
          '暂时无法连接 Supabase 身份验证，请在网络或 DNS 恢复后刷新。',
          'Supabase auth is not reachable yet. Refresh after network/DNS is back.',
        );
      });
      return;
    }
    final base = Uri.base;
    final redirectTo = base.replace(fragment: '').toString();
    await Supabase.instance.client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectTo,
    );
  }

  Future<void> _logout() async {
    if (_authConfigured) {
      await Supabase.instance.client.auth.signOut();
    }
    if (!mounted) return;
    setState(() {
      _localWorkspace = false;
      _session = null;
    });
  }

  void _enterLocalWorkspace() {
    setState(() => _localWorkspace = true);
    if (_returnTo != null) {
      scheduleMicrotask(() => openBrowserPath(_returnTo));
    }
  }

  void _setAuthMessage(String zh, String en) {
    _authMessageZh = zh;
    _authMessageEn = en;
  }

  @override
  Widget build(BuildContext context) {
    final token = _localWorkspace ? _localDevToken : _session?.accessToken;
    final authenticated = token != null && token.isNotEmpty;

    Widget content;
    if (_loading) {
      content = const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    } else if (!authenticated) {
      content = LoginScreen(
        authConfigured: _authConfigured && _supabaseReady,
        localBypassEnabled: _authDevBypass == 'true',
        authMessage: trFor(
          widget.language,
          _authMessageZh ?? _supabaseInitError?.toString() ?? '',
          _authMessageEn ?? _supabaseInitError?.toString() ?? '',
        ),
        language: widget.language,
        onLanguage: widget.onLanguage,
        onGoogle: _signInWithGoogle,
        onLocal: _enterLocalWorkspace,
        onRetry: _retryBootstrap,
      );
    } else {
      final user = _localWorkspace
          ? trFor(widget.language, '本地工作区', 'Local Workspace')
          : (_session?.user.userMetadata?['full_name']?.toString() ??
                _session?.user.email ??
                trFor(widget.language, '研究用户', 'Research user'));
      final userEmail = _localWorkspace
          ? 'local-dev@guru-analysis.test'
          : (_session?.user.email ?? '');
      content = TerminalHome(
        key: ValueKey(_localWorkspace ? 'local-workspace' : _session!.user.id),
        accessToken: token,
        userId: _localWorkspace ? '' : _session!.user.id,
        userName: user,
        userEmail: userEmail,
        language: widget.language,
        routeUri: widget.routeUri,
        routeRevision: widget.routeRevision,
        onLanguage: widget.onLanguage,
        onLogout: _logout,
      );
    }

    return content;
  }
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({
    super.key,
    required this.authConfigured,
    required this.localBypassEnabled,
    this.authMessage,
    required this.language,
    required this.onLanguage,
    required this.onGoogle,
    required this.onLocal,
    required this.onRetry,
  });

  final bool authConfigured;
  final bool localBypassEnabled;
  final String? authMessage;
  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguage;
  final VoidCallback onGoogle;
  final VoidCallback onLocal;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = Palette(false);
    return Scaffold(
      body: Container(
        key: const ValueKey('login-background'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A1220), Color(0xFF0D1F24)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Container(
                    key: const ValueKey('login-panel'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: panelDecoration(palette),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: LanguageSegment(
                            language: language,
                            onLanguage: onLanguage,
                            palette: palette,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: palette.accent.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: palette.accent.withValues(alpha: .32),
                                ),
                              ),
                              child: Image.asset(
                                'assets/branding/thesisforge-mark.png',
                                fit: BoxFit.contain,
                                semanticLabel: context.tr(
                                  'ThesisForge',
                                  'ThesisForge',
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.tr('ThesisForge', 'ThesisForge'),
                                  style: TextStyle(
                                    color: palette.text,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'GURU INTELLIGENCE',
                                  style: TextStyle(
                                    color: palette.accent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          context.tr('研究终端', 'Research Terminal'),
                          style: Theme.of(context).textTheme.displaySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.tr(
                            '面向买方研究的终端，整合 13F 资金流、内部人交易、组合模拟与估值分析。',
                            'A buy-side terminal for 13F flows, insider activity, copy simulation, and valuation context.',
                          ),
                          style: TextStyle(color: palette.muted, height: 1.35),
                        ),
                        const SizedBox(height: 28),
                        FilledButton.icon(
                          onPressed: authConfigured ? onGoogle : null,
                          icon: const Icon(Icons.login_rounded),
                          label: Text(
                            context.tr('使用 Google 继续', 'Continue with Google'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const ValueKey('explore-public-isrg-case'),
                          onPressed: () => openBrowserPath('/research/isrg/'),
                          icon: const Icon(Icons.insights_rounded),
                          label: Text(
                            context.tr(
                              '查看 ISRG 英文案例 · 免登录',
                              'Explore the ISRG case — no sign-in',
                            ),
                          ),
                        ),
                        if (localBypassEnabled) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: onLocal,
                            icon: const Icon(Icons.terminal_rounded),
                            label: Text(
                              context.tr('进入本地工作区', 'Enter Local Workspace'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        Text(
                          (authMessage?.isNotEmpty ?? false)
                              ? authMessage!
                              : (authConfigured
                                    ? context.tr(
                                        '案例无需登录；登录后可进入完整研究终端。',
                                        'Explore the case freely. Sign in for the full research terminal.',
                                      )
                                    : context.tr(
                                        'Supabase 密钥未配置或身份验证暂不可用；开发环境可进入本地工作区。',
                                        'Supabase keys are not configured or auth is not reachable; local workspace mode is available for development.',
                                      )),
                          style: TextStyle(color: palette.faint, fontSize: 12),
                        ),
                        if ((authMessage?.isNotEmpty ?? false)) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(
                              context.tr(
                                '重试身份验证初始化',
                                'Retry auth initialization',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TerminalHome extends StatefulWidget {
  const TerminalHome({
    super.key,
    required this.accessToken,
    this.userId = '',
    this.api,
    required this.userName,
    required this.userEmail,
    required this.language,
    required this.routeUri,
    this.routeRevision = 0,
    required this.onLanguage,
    required this.onLogout,
  });

  final String accessToken;
  final String userId;
  final ApiClient? api;
  final String userName;
  final String userEmail;
  final AppLanguage language;
  final Uri routeUri;
  final int routeRevision;
  final ValueChanged<AppLanguage> onLanguage;
  final VoidCallback onLogout;

  @override
  State<TerminalHome> createState() => _TerminalHomeState();
}

class _TerminalHomeState extends State<TerminalHome>
    with WidgetsBindingObserver {
  late ApiClient _api = _createApi();
  int _identityEpoch = 0;
  int _browserNavigationSerial = 0;
  GlobalKey<_InvestmentWorkspaceState> _workspaceKey = GlobalKey();

  ApiClient _createApi() {
    final epoch = _identityEpoch;
    return widget.api ??
        ApiClient(
          () => widget.accessToken,
          sessionUserId: widget.userId,
          isSessionActive: () =>
              mounted && epoch == _identityEpoch && _hasSession,
        );
  }

  final TextEditingController _guruSearchController = TextEditingController();
  Map<String, dynamic>? _guruPayload;
  Map<String, dynamic>? _portfolioPayload;
  Map<String, dynamic>? _valuationPayload;
  Map<String, dynamic>? _adminPayload;
  bool _loadingGurus = false;
  bool _loadingSecondary = false;
  String _mode = 'guru';
  String _search = '';
  String _filter = 'all';
  String? _selectedGuruId;
  int _guruModule = 0;
  String _guruTradeTicker = '';
  String _guruQuarterId = '';
  String _valuationTicker = '';
  String? _error;
  String? _secondaryError;
  bool _colorBlind = false;
  Timer? _secondaryRecoveryTimer;
  bool _secondaryRecoveryScheduled = false;
  int _guruRequestSerial = 0;
  int _secondaryRequestSerial = 0;

  Palette get palette => Palette(_colorBlind);
  bool get _hasSession => widget.accessToken.trim().isNotEmpty;
  bool get _adminEnabled =>
      canShowAdmin(email: widget.userEmail, accessToken: widget.accessToken);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _secondaryRecoveryTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _recoverSecondaryIfNeeded(),
    );
    final route = widget.routeUri.queryParameters;
    _mode = normalizeRouteMode(
      route['view'] ?? route['mode'],
      path: widget.routeUri.path,
    );
    if (_mode == 'admin' && !_adminEnabled) _mode = 'guru';
    _selectedGuruId = cleanRouteValue(route['guru']);
    _guruModule = guruModuleIndex(route['module']);
    _guruTradeTicker = cleanRouteValue(route['trade'])?.toUpperCase() ?? '';
    _guruQuarterId = cleanRouteValue(route['quarter']) ?? '';
    _valuationTicker = cleanRouteValue(route['valuation'])?.toUpperCase() ?? '';
    if (shouldLoadGuruDashboard(_mode, _guruPayload)) {
      unawaited(_loadGurus());
    }
    if (_mode != 'guru') {
      unawaited(_loadSecondary(_mode));
    }
  }

  @override
  void didUpdateWidget(covariant TerminalHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.userId != widget.userId ||
        oldWidget.userEmail.trim().toLowerCase() !=
            widget.userEmail.trim().toLowerCase() ||
        oldWidget.accessToken.isEmpty != widget.accessToken.isEmpty ||
        (oldWidget.accessToken == _localDevToken) !=
            (widget.accessToken == _localDevToken);
    if (identityChanged) {
      // Never retain a prior account's admin, portfolio or research widget
      // state. Invalidating serials also rejects responses already in flight.
      _identityEpoch++;
      _guruRequestSerial++;
      _secondaryRequestSerial++;
      _api = _createApi();
      _guruPayload = null;
      _portfolioPayload = null;
      _valuationPayload = null;
      _adminPayload = null;
      _loadingGurus = false;
      _loadingSecondary = false;
      _error = null;
      _secondaryError = null;
      _restoreBrowserRoute(widget.routeUri);
      return;
    }
    if (oldWidget.accessToken != widget.accessToken) {
      _recoverSecondaryIfNeeded(forceWhenEmpty: true);
    }
    if (oldWidget.routeUri != widget.routeUri ||
        oldWidget.routeRevision != widget.routeRevision) {
      unawaited(_requestBrowserRoute(widget.routeUri));
    }
  }

  Future<void> _requestBrowserRoute(Uri uri) async {
    final request = ++_browserNavigationSerial;
    final identity = _identityEpoch;
    final workspace = _workspaceKey.currentState;
    // Browser Back must honor the same account-backed autosave and explicit
    // discard confirmation as clicking a workspace navigation item.
    if (workspace?.page == 'research' && !await workspace!.allowLeaveDraft()) {
      if (mounted &&
          request == _browserNavigationSerial &&
          identity == _identityEpoch &&
          workspace.mounted) {
        workspace.navigate(workspace.page);
      }
      return;
    }
    if (!mounted ||
        request != _browserNavigationSerial ||
        identity != _identityEpoch) {
      return;
    }
    _restoreBrowserRoute(uri);
  }

  void _restoreBrowserRoute(Uri uri) {
    final route = uri.queryParameters;
    var nextMode = normalizeRouteMode(
      route['view'] ?? route['mode'],
      path: uri.path,
    );
    if (nextMode == 'admin' && !_adminEnabled) nextMode = 'guru';
    final nextGuru = cleanRouteValue(route['guru']);
    final nextModule = guruModuleIndex(route['module']);
    final nextTrade = cleanRouteValue(route['trade'])?.toUpperCase() ?? '';
    final nextQuarter = cleanRouteValue(route['quarter']) ?? '';
    final nextValuation =
        cleanRouteValue(route['valuation'])?.toUpperCase() ?? '';
    final resetGuruUniverse =
        nextMode == 'guru' && nextGuru != null && nextGuru != _selectedGuruId;
    if (resetGuruUniverse) _guruSearchController.clear();
    setState(() {
      _workspaceKey = GlobalKey();
      _mode = nextMode;
      if (resetGuruUniverse) {
        _search = '';
        _filter = 'all';
      }
      _selectedGuruId = nextGuru;
      _guruModule = nextModule;
      _guruTradeTicker = nextTrade;
      _guruQuarterId = nextQuarter;
      _valuationTicker = nextValuation;
      _secondaryError = null;
    });
    if (shouldLoadGuruDashboard(nextMode, _guruPayload) && !_loadingGurus) {
      unawaited(_loadGurus());
    } else if (nextMode != 'guru') {
      unawaited(_loadSecondary(nextMode));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recoverSecondaryIfNeeded(forceWhenEmpty: true);
    }
  }

  @override
  void dispose() {
    _secondaryRecoveryTimer?.cancel();
    _guruSearchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadGurus({bool refresh = false}) async {
    if (!_hasSession) return;
    final requestId = ++_guruRequestSerial;
    setState(() {
      _loadingGurus = true;
      _error = null;
    });
    try {
      final payload = await _api.getJson(
        '/api/gurus${refresh ? '?refresh=1' : ''}',
      );
      final gurus = asList(payload['gurus']);
      if (!mounted || requestId != _guruRequestSerial) return;
      setState(() {
        _guruPayload = payload;
        final selectedExists = gurus.any(
          (guru) => text(guru['id']) == _selectedGuruId,
        );
        if (_selectedGuruId == null || !selectedExists) {
          _selectedGuruId = defaultGuruId(gurus);
        }
      });
      // Selecting a deterministic default after a data load is normalization,
      // not a new user navigation. Replacing the current entry preserves the
      // browser's Forward stack after a Back navigation.
      _persistRouteState(replaceCurrent: true);
    } catch (error) {
      if (mounted && requestId == _guruRequestSerial) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && requestId == _guruRequestSerial) {
        setState(() => _loadingGurus = false);
      }
    }
  }

  Map<String, dynamic>? _secondaryPayloadFor(String mode) => switch (mode) {
    'portfolio' => _portfolioPayload,
    'admin' => _adminPayload,
    _ => _valuationPayload,
  };

  void _recoverSecondaryIfNeeded({bool forceWhenEmpty = false}) {
    if (!mounted || _mode == 'guru' || _loadingSecondary) return;
    final payload = _secondaryPayloadFor(_mode);
    if (payload == null || _secondaryError != null || forceWhenEmpty) {
      unawaited(_loadSecondary(_mode, refresh: payload != null));
    }
  }

  void _scheduleSecondaryRecoveryIfStale() {
    if (_secondaryRecoveryScheduled ||
        _mode == 'guru' ||
        _loadingSecondary ||
        _secondaryError != null ||
        _secondaryPayloadFor(_mode) != null) {
      return;
    }
    _secondaryRecoveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _secondaryRecoveryScheduled = false;
      if (!mounted ||
          _mode == 'guru' ||
          _loadingSecondary ||
          _secondaryError != null ||
          _secondaryPayloadFor(_mode) != null) {
        return;
      }
      _recoverSecondaryIfNeeded(forceWhenEmpty: true);
    });
  }

  Future<void> _loadSecondary(String mode, {bool refresh = false}) async {
    if (!_hasSession) return;
    if (isInvestmentMode(mode)) return;
    if (!refresh && mode == 'portfolio' && _portfolioPayload != null) return;
    if (!refresh && mode == 'valuation' && _valuationPayload != null) return;
    if (!refresh && mode == 'admin' && _adminPayload != null) return;
    if (mode == 'admin' && !_adminEnabled) return;
    final requestId = ++_secondaryRequestSerial;
    setState(() {
      _loadingSecondary = true;
      _secondaryError = null;
    });
    try {
      final basePath = switch (mode) {
        'portfolio' => '/api/portfolio',
        'admin' => '/api/admin/portfolio-users',
        _ => '/api/valuation',
      };
      final path = refresh ? '$basePath?refresh=1' : basePath;
      final payload = await _api.getJson(path);
      if (!mounted || requestId != _secondaryRequestSerial) return;
      setState(() {
        if (mode == 'portfolio') _portfolioPayload = payload;
        if (mode == 'valuation') _valuationPayload = payload;
        if (mode == 'admin') _adminPayload = payload;
        _secondaryError = null;
      });
    } catch (error) {
      if (mounted && requestId == _secondaryRequestSerial) {
        setState(() => _secondaryError = error.toString());
      }
    } finally {
      if (mounted && requestId == _secondaryRequestSerial) {
        setState(() => _loadingSecondary = false);
      }
    }
  }

  void _changeMode(String mode) {
    final next = normalizeRouteMode(mode);
    if (next == 'admin' && !_adminEnabled) return;
    setState(() {
      _mode = next;
      _secondaryError = null;
    });
    _persistRouteState();
    if (shouldLoadGuruDashboard(next, _guruPayload) && !_loadingGurus) {
      unawaited(_loadGurus());
    } else if (next != 'guru') {
      unawaited(_loadSecondary(next));
    }
  }

  void _persistRouteState({bool replaceCurrent = false}) {
    replaceBrowserQuery({
      'view': _mode == 'guru' && !investmentWorkflowEnabled ? null : _mode,
      'guru': _mode == 'guru' ? _selectedGuruId : null,
      'module': _mode == 'guru' && _guruModule > 0
          ? guruModuleRouteName(_guruModule)
          : null,
      'trade': _mode == 'guru' && _guruTradeTicker.isNotEmpty
          ? _guruTradeTicker
          : null,
      'quarter':
          _mode == 'guru' && _guruModule == 2 && _guruQuarterId.isNotEmpty
          ? _guruQuarterId
          : null,
      'valuation': _mode == 'valuation' && _valuationTicker.isNotEmpty
          ? _valuationTicker
          : null,
      'lang': appLanguageCode(widget.language),
    }, replaceCurrent: replaceCurrent);
  }

  void _selectGuru(String id) {
    setState(() {
      _selectedGuruId = id;
      _guruTradeTicker = '';
      _guruQuarterId = '';
    });
    _persistRouteState();
  }

  void _openGuruTrade(String guruId, String ticker) {
    final target = guruTradeNavigationTarget(guruId, ticker);
    if (target == null) return;
    _guruSearchController.clear();
    setState(() {
      _mode = 'guru';
      // Market Lens is built from the full eligible-manager universe. Reset
      // universe filters before selecting its evidence row so the requested
      // manager cannot be hidden and silently replaced by the first visible
      // manager in the filtered list.
      _search = target.search;
      _filter = target.filter;
      _selectedGuruId = target.guruId;
      _guruModule = 1;
      _guruTradeTicker = target.ticker;
      _guruQuarterId = '';
      _secondaryError = null;
    });
    _persistRouteState();
  }

  void _openValuationTicker(String ticker) {
    final normalizedTicker = ticker.trim().toUpperCase();
    if (normalizedTicker.isEmpty) return;
    setState(() {
      _mode = 'valuation';
      _valuationTicker = normalizedTicker;
      _secondaryError = null;
    });
    _persistRouteState();
    unawaited(_loadSecondary('valuation'));
  }

  void _updateGuruSearch(String value) {
    _updateGuruUniverse(search: value, filter: _filter);
  }

  void _updateGuruFilter(String value) {
    _updateGuruUniverse(search: _search, filter: value);
  }

  void _updateGuruUniverse({required String search, required String filter}) {
    final visible = filterGurus(asList(_guruPayload?['gurus']), search, filter);
    final selectedVisible = visible.any(
      (guru) => text(guru['id']) == _selectedGuruId,
    );
    final nextGuruId = selectedVisible
        ? _selectedGuruId
        : (visible.isEmpty ? null : text(visible.first['id']));
    final selectionChanged = nextGuruId != _selectedGuruId;
    setState(() {
      _search = search;
      _filter = filter;
      _selectedGuruId = nextGuruId;
      if (selectionChanged) {
        _guruTradeTicker = '';
        _guruQuarterId = '';
      }
    });
    if (selectionChanged) _persistRouteState();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSession) return const SizedBox.shrink();
    _scheduleSecondaryRecoveryIfStale();
    if (isInvestmentMode(_mode)) {
      return LanguageScope(
        language: widget.language,
        child: InvestmentWorkspace(
          key: _workspaceKey,
          api: _api,
          palette: palette,
          initialPage: _mode,
          initialTicker: _valuationTicker,
          initialAsOf: widget.routeUri.queryParameters['asOf'],
          initialQuery: widget.routeUri.queryParameters,
          onLanguage: widget.onLanguage,
          onLegacy: () => _changeMode('guru'),
          onLegacyView: _changeMode,
          showAdmin: _adminEnabled,
          onLogout: widget.onLogout,
          localPreview: widget.accessToken == _localDevToken,
        ),
      );
    }
    final headerPayload = _mode == 'guru'
        ? _guruPayload
        : _secondaryPayloadFor(_mode);
    final headerLoading = _mode == 'guru' ? _loadingGurus : _loadingSecondary;
    final headerError = _mode == 'guru' ? _error : _secondaryError;
    final headerState = moduleHeaderState(
      mode: _mode,
      payload: headerPayload,
      loading: headerLoading,
      error: headerError,
    );
    return LanguageScope(
      language: widget.language,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              TerminalHeader(
                mode: _mode,
                userName: widget.userName,
                moduleState: headerState,
                colorBlind: _colorBlind,
                language: widget.language,
                showAdmin: _adminEnabled,
                onMode: _changeMode,
                onRefresh: () => _mode == 'guru'
                    ? _loadGurus(refresh: true)
                    : _loadSecondary(_mode, refresh: true),
                onColorBlind: (value) => setState(() => _colorBlind = value),
                onLanguage: widget.onLanguage,
                onLogout: widget.onLogout,
                palette: palette,
              ),
              Expanded(
                child: AnimatedSwitcher(
                  key: ValueKey('terminal-$_identityEpoch'),
                  duration: const Duration(milliseconds: 250),
                  child: _mode == 'guru'
                      ? _buildGuruMode()
                      : SecondaryDashboard(
                          key: ValueKey(_mode),
                          mode: _mode,
                          api: _api,
                          data: switch (_mode) {
                            'portfolio' => _portfolioPayload,
                            'admin' => _adminPayload,
                            _ => _valuationPayload,
                          },
                          loading: _loadingSecondary,
                          error: _secondaryError,
                          palette: palette,
                          onRefresh: () => _loadSecondary(_mode, refresh: true),
                          initialValuationTicker: _valuationTicker,
                          onValuationTickerChanged: (value) {
                            _valuationTicker = value.toUpperCase();
                            _persistRouteState();
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuruMode() {
    if (_loadingGurus && _guruPayload == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _guruPayload == null) {
      return Center(
        child: ErrorCard(message: _error!, onRetry: () => _loadGurus()),
      );
    }

    final gurus = asList(_guruPayload?['gurus']);
    final filtered = filterGurus(gurus, _search, _filter);
    final selectedGuru = filtered.firstWhere(
      (guru) => text(guru['id']) == _selectedGuruId,
      orElse: () => filtered.isNotEmpty ? filtered.first : <String, dynamic>{},
    );
    final signals = buildSignals(gurus, context.language);
    final exposures = buildExposures(gurus, language: context.language);
    final stats = buildExecutiveStats(gurus, signals);

    return StockResearchScope(
      api: _api,
      palette: palette,
      sourceLabel: guruDisplayName(selectedGuru, context.language),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1280;
          final medium = constraints.maxWidth >= 980;
          final mobile = constraints.maxWidth < 760;
          final universe = GuruUniversePanel(
            gurus: filtered,
            selectedGuruId: text(selectedGuru['id']),
            searchController: _guruSearchController,
            filter: _filter,
            palette: palette,
            onSearch: _updateGuruSearch,
            onFilter: _updateGuruFilter,
            onSelect: _selectGuru,
          );
          final mobileUniverse = MobileGuruPicker(
            gurus: filtered,
            selectedGuruId: text(selectedGuru['id']),
            searchController: _guruSearchController,
            filter: _filter,
            palette: palette,
            onSearch: _updateGuruSearch,
            onFilter: _updateGuruFilter,
            onSelect: _selectGuru,
          );
          final Widget workspace = filtered.isEmpty
              ? Panel(
                  palette: palette,
                  child: EmptyState(
                    text: context.tr(
                      '没有可显示的 Guru 研究卡；请调整搜索或筛选。',
                      'No Guru research card is visible; adjust the search or filter.',
                    ),
                    palette: palette,
                  ),
                )
              : GuruWorkspace(
                  guru: selectedGuru,
                  api: _api,
                  palette: palette,
                  initialModule: _guruModule,
                  initialTicker: _guruTradeTicker,
                  initialQuarterId: _guruQuarterId,
                  onModuleChanged: (value) {
                    _guruModule = value;
                    _persistRouteState();
                  },
                  onTickerChanged: (value) {
                    _guruTradeTicker = value.toUpperCase();
                    _persistRouteState();
                  },
                  onQuarterChanged: (value) {
                    _guruQuarterId = value;
                    _persistRouteState();
                  },
                );
          final rightRail = GuruRightRail(
            gurus: gurus,
            signals: signals.take(3).toList(),
            exposures: exposures,
            activeGuruId: text(selectedGuru['id']),
            palette: palette,
            onSelectGuru: _selectGuru,
            onOpenGuruTrade: _openGuruTrade,
            onOpenValuation: _openValuationTicker,
            deckHeight: mobile ? 720 : 860,
            deckLimit: mobile ? 12 : 16,
          );
          final content = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 270, child: universe),
                    const SizedBox(width: 10),
                    Expanded(child: workspace),
                    const SizedBox(width: 10),
                    SizedBox(width: 280, child: rightRail),
                  ],
                )
              : medium
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 276, child: universe),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        children: [
                          workspace,
                          const SizedBox(height: 10),
                          rightRail,
                        ],
                      ),
                    ),
                  ],
                )
              : mobile
              ? Column(
                  children: [
                    mobileUniverse,
                    const SizedBox(height: 10),
                    MobileOverviewBar(stats: stats, palette: palette),
                    const SizedBox(height: 10),
                    workspace,
                    const SizedBox(height: 10),
                    rightRail,
                  ],
                )
              : Column(
                  children: [
                    universe,
                    const SizedBox(height: 10),
                    workspace,
                    const SizedBox(height: 10),
                    rightRail,
                  ],
                );

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              mobile ? 8 : 10,
              10,
              mobile ? 8 : 10,
              22,
            ),
            child: Column(
              children: [
                if ((_loadingGurus && _guruPayload != null) ||
                    _error != null) ...[
                  InlineDataBanner(
                    loading: _loadingGurus,
                    error: _error,
                    palette: palette,
                    onRetry: () => _loadGurus(refresh: true),
                  ),
                  const SizedBox(height: 10),
                ],
                content,
              ],
            ),
          );
        },
      ),
    );
  }
}

class ModuleHeaderState {
  const ModuleHeaderState({
    required this.status,
    required this.source,
    required this.asOf,
  });

  final String status;
  final String source;
  final String asOf;
}

ModuleHeaderState moduleHeaderState({
  required String mode,
  required Map<String, dynamic>? payload,
  required bool loading,
  String? error,
  DateTime? now,
}) {
  final source = asMap(payload?['source']);
  final summary = asMap(payload?['summary']);
  final cache = asMap(payload?['cache']);
  final guruDates = asList(
    payload?['gurus'],
  ).map((guru) => asMap(guru['summary'])).toList();
  String latestGuruDate(String key) {
    final values =
        guruDates
            .map((value) => text(value[key]))
            .where((value) => DateTime.tryParse(value) != null)
            .toList()
          ..sort();
    return values.isEmpty ? '' : values.last;
  }

  String firstValidAsOf(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = text(candidate);
      if (value.isNotEmpty && DateTime.tryParse(value) != null) return value;
    }
    return '';
  }

  // A request/computation timestamp is not an economic as-of. Only explicit
  // upstream/source dates may appear in the terminal header or unlock LIVE.
  final asOf = switch (mode) {
    'valuation' => firstValidAsOf([
      summary['latestPriceDate'],
      source['asOf'],
      payload?['asOf'],
      summary['asOf'],
    ]),
    'guru' => firstValidAsOf([
      latestGuruDate('filingDate'),
      latestGuruDate('reportDate'),
      source['asOf'],
      payload?['asOf'],
    ]),
    'portfolio' => firstValidAsOf([
      source['asOf'],
      source['toDate'],
      source['generatedAt'],
      payload?['asOf'],
      summary['asOf'],
    ]),
    _ => firstValidAsOf([source['asOf'], payload?['asOf'], summary['asOf']]),
  };
  final explicitStatus = text(
    payload?['status'],
    text(source['mode'], text(source['status'], text(cache['status']))),
  ).toLowerCase();
  final freshnessValue = switch (mode) {
    'valuation' => text(asOf, text(payload?['generatedAt'])),
    'guru' => text(payload?['generatedAt'], asOf),
    _ => text(asOf, text(payload?['generatedAt'])),
  };
  final freshnessDate = DateTime.tryParse(freshnessValue)?.toUtc();
  final freshnessLimit = switch (mode) {
    'guru' => const Duration(hours: 48),
    'valuation' => const Duration(hours: 72),
    'portfolio' => const Duration(hours: 48),
    _ => null,
  };
  final referenceNow = (now ?? DateTime.now()).toUtc();
  final computedStale =
      freshnessLimit != null &&
      freshnessDate != null &&
      referenceNow.difference(freshnessDate) > freshnessLimit;
  final status = explicitStatus == 'sample'
      ? 'sample'
      : (error?.trim().isNotEmpty ?? false)
      ? 'error'
      : explicitStatus.contains('stale') ||
            (mode == 'portfolio' && isSavedPortfolioReport(payload)) ||
            computedStale
      ? 'stale'
      : loading && payload != null
      ? 'cached'
      : (explicitStatus == 'live' || explicitStatus.endsWith('_live')) &&
            asOf.isNotEmpty
      ? 'live'
      : 'cached';
  final sourceLabel = text(
    source['label'],
    text(source['upstreamLabel'], text(payload?['sourceLabel'])),
  );
  return ModuleHeaderState(
    status: status,
    source: sourceLabel.isEmpty ? mode : sourceLabel,
    asOf: asOf,
  );
}

class TerminalHeader extends StatelessWidget {
  const TerminalHeader({
    super.key,
    required this.mode,
    required this.userName,
    required this.moduleState,
    required this.colorBlind,
    required this.language,
    required this.showAdmin,
    required this.onMode,
    required this.onRefresh,
    required this.onColorBlind,
    required this.onLanguage,
    required this.onLogout,
    required this.palette,
  });

  final String mode;
  final String userName;
  final ModuleHeaderState moduleState;
  final bool colorBlind;
  final AppLanguage language;
  final bool showAdmin;
  final ValueChanged<String> onMode;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onColorBlind;
  final ValueChanged<AppLanguage> onLanguage;
  final VoidCallback onLogout;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final initials = userInitials(userName);
    final logo = Container(
      width: 36,
      height: 36,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: .24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.accent.withValues(alpha: .32)),
      ),
      child: Image.asset(
        'assets/branding/thesisforge-mark.png',
        fit: BoxFit.contain,
        semanticLabel: context.tr('ThesisForge', 'ThesisForge'),
      ),
    );
    final accountMenu = PopupMenuButton<String>(
      tooltip: context.ui('Account'),
      color: palette.card,
      onSelected: (value) {
        if (value == 'logout') onLogout();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'logout',
          child: Text(
            context.ui('Logout'),
            style: TextStyle(color: palette.text),
          ),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: .28),
                shape: BoxShape.circle,
              ),
              child: Text(
                initials,
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Icon(Icons.expand_more_rounded, color: palette.muted, size: 20),
          ],
        ),
      ),
    );
    final refreshButton = _ToolbarIconButton(
      tooltip: context.ui('Refresh'),
      icon: Icons.refresh_rounded,
      palette: palette,
      onPressed: onRefresh,
    );
    final contrastButton = _ToolbarIconButton(
      tooltip: context.ui('Color contrast'),
      icon: Icons.contrast_rounded,
      active: colorBlind,
      palette: palette,
      onPressed: () => onColorBlind(!colorBlind),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1200;
        final titleBlock = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Guru Intelligence',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text,
                fontSize: compact ? 14 : 15,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              compact
                  ? '${toolbarDateLabel(moduleState.asOf, context.language)} · ${context.ui(moduleState.source.replaceAll(' database', ''))}'
                  : context.ui('Guru Stock Analysis'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );

        return Container(
          height: compact ? 124 : 66,
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
          decoration: BoxDecoration(
            color: palette.background.withValues(alpha: .96),
            border: Border(bottom: BorderSide(color: palette.border)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .18),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: compact
              ? Column(
                  children: [
                    SizedBox(
                      height: 64,
                      child: Row(
                        children: [
                          logo,
                          const SizedBox(width: 10),
                          Expanded(child: titleBlock),
                          const SizedBox(width: 8),
                          StatusDot(
                            status: moduleState.status,
                            palette: palette,
                          ),
                          const SizedBox(width: 6),
                          _CompactLanguageButton(
                            language: language,
                            palette: palette,
                            onLanguage: onLanguage,
                          ),
                          const SizedBox(width: 8),
                          accountMenu,
                        ],
                      ),
                    ),
                    Container(height: 1, color: palette.border),
                    SizedBox(
                      height: 57,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ModeSegment(
                              mode: mode,
                              onMode: onMode,
                              palette: palette,
                              showAdmin: showAdmin,
                            ),
                            const SizedBox(width: 8),
                            refreshButton,
                            const SizedBox(width: 6),
                            contrastButton,
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    logo,
                    const SizedBox(width: 12),
                    SizedBox(width: 210, child: titleBlock),
                    Container(width: 1, height: 34, color: palette.border),
                    const SizedBox(width: 16),
                    Text(
                      toolbarDateLabel(moduleState.asOf, context.language),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 18),
                    StatusDot(status: moduleState.status, palette: palette),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ModeSegment(
                          mode: mode,
                          onMode: onMode,
                          palette: palette,
                          showAdmin: showAdmin,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    LanguageSegment(
                      language: language,
                      onLanguage: onLanguage,
                      palette: palette,
                    ),
                    const SizedBox(width: 10),
                    refreshButton,
                    const SizedBox(width: 6),
                    contrastButton,
                    const SizedBox(width: 8),
                    accountMenu,
                  ],
                ),
        );
      },
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.palette,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final Palette palette;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? palette.accent.withValues(alpha: .18)
                  : palette.card.withValues(alpha: .7),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active
                    ? palette.accent.withValues(alpha: .42)
                    : palette.border,
              ),
            ),
            child: Icon(
              icon,
              size: 19,
              color: active ? palette.accent : palette.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactLanguageButton extends StatelessWidget {
  const _CompactLanguageButton({
    required this.language,
    required this.palette,
    required this.onLanguage,
  });

  final AppLanguage language;
  final Palette palette;
  final ValueChanged<AppLanguage> onLanguage;

  @override
  Widget build(BuildContext context) {
    final nextLanguage = language == AppLanguage.zh
        ? AppLanguage.en
        : AppLanguage.zh;
    final label = language == AppLanguage.zh ? 'EN' : 'ZH';
    final tooltip = language == AppLanguage.zh ? '切换至英文' : 'Switch to Chinese';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onLanguage(nextLanguage),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: .8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: palette.accent,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ModeSegment extends StatelessWidget {
  const ModeSegment({
    super.key,
    required this.mode,
    required this.onMode,
    required this.palette,
    required this.showAdmin,
  });

  final String mode;
  final ValueChanged<String> onMode;
  final Palette palette;
  final bool showAdmin;

  @override
  Widget build(BuildContext context) {
    final modes = [
      if (investmentWorkflowEnabled) ('home', context.tr('工作区', 'Workspace')),
      ('guru', 'Guru'),
      ('valuation', context.tr('估值', 'Valuation')),
      ('portfolio', context.tr('组合', 'Portfolio')),
      if (showAdmin) ('admin', context.tr('管理', 'Admin')),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in modes)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                button: true,
                selected: mode == item.$1,
                label: item.$2,
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onMode(item.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: mode == item.$1
                          ? palette.accent.withValues(alpha: .18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      item.$2,
                      style: TextStyle(
                        color: mode == item.$1 ? palette.accent : palette.muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class LanguageSegment extends StatelessWidget {
  const LanguageSegment({
    super.key,
    required this.language,
    required this.onLanguage,
    required this.palette,
  });

  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguage;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final options = [
      (AppLanguage.zh, language == AppLanguage.en ? 'Chinese' : '中文'),
      (AppLanguage.en, language == AppLanguage.en ? 'English' : 'EN'),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in options)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Semantics(
                button: true,
                selected: language == option.$1,
                label: option.$2,
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onLanguage(option.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    constraints: const BoxConstraints(minHeight: 44),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: language == option.$1
                          ? palette.accent.withValues(alpha: .18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      option.$2,
                      style: TextStyle(
                        color: language == option.$1
                            ? palette.accent
                            : palette.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UniverseTopTabs extends StatelessWidget {
  const _UniverseTopTabs({
    required this.filter,
    required this.palette,
    required this.onFilter,
  });

  final String filter;
  final Palette palette;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context) {
    final firmsSelected = filter == 'manager13f';

    Widget item({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: context.ui(label),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: AnimatedContainer(
              key: ValueKey('guru-universe-${label.toLowerCase()}'),
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? palette.accent.withValues(alpha: .13)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected
                      ? palette.accent.withValues(alpha: .18)
                      : Colors.transparent,
                ),
              ),
              child: Text(
                context.ui(label),
                style: TextStyle(
                  color: selected ? palette.accent : palette.muted,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          item(
            label: 'Gurus',
            selected: !firmsSelected,
            onTap: () => onFilter('all'),
          ),
          item(
            label: 'Firms',
            selected: firmsSelected,
            onTap: () => onFilter('manager13f'),
          ),
        ],
      ),
    );
  }
}

class GuruUniversePanel extends StatelessWidget {
  const GuruUniversePanel({
    super.key,
    required this.gurus,
    required this.selectedGuruId,
    required this.searchController,
    required this.filter,
    required this.palette,
    required this.onSearch,
    required this.onFilter,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> gurus;
  final String selectedGuruId;
  final TextEditingController searchController;
  final String filter;
  final Palette palette;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final filters = const [
      ('all', 'All'),
      ('manager13f', '13F'),
      ('insider', 'Form 4'),
      ('congress', 'STOCK'),
      ('profile', 'Profile'),
    ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _UniverseTopTabs(
            filter: filter,
            palette: palette,
            onFilter: onFilter,
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: TextField(
              key: const ValueKey('guru-universe-search'),
              controller: searchController,
              onChanged: onSearch,
              style: TextStyle(color: palette.text, fontSize: 13),
              decoration: InputDecoration(
                hintText: context.ui('Search guru / firm / ticker'),
                hintStyle: TextStyle(color: palette.faint),
                prefixIcon: Icon(Icons.search_rounded, color: palette.muted),
                suffixIcon: Icon(
                  Icons.keyboard_command_key_rounded,
                  color: palette.faint,
                  size: 16,
                ),
                filled: true,
                fillColor: palette.background.withValues(alpha: .52),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: palette.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: palette.accent),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final item in filters)
                FilterChip(
                  selected: filter == item.$1,
                  onSelected: (_) => onFilter(item.$1),
                  label: Text(context.ui(item.$2)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (gurus.isEmpty)
            EmptyState(
              text: context.tr(
                '当前搜索或筛选没有匹配的投资人。',
                'No gurus match the current search or filter.',
              ),
              palette: palette,
            )
          else
            for (final guru in gurus)
              GuruListTile(
                guru: guru,
                active: text(guru['id']) == selectedGuruId,
                palette: palette,
                onTap: () => onSelect(text(guru['id'])),
              ),
        ],
      ),
    );
  }
}

class MobileGuruPicker extends StatelessWidget {
  const MobileGuruPicker({
    super.key,
    required this.gurus,
    required this.selectedGuruId,
    required this.searchController,
    required this.filter,
    required this.palette,
    required this.onSearch,
    required this.onFilter,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> gurus;
  final String selectedGuruId;
  final TextEditingController searchController;
  final String filter;
  final Palette palette;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final filters = const [
      ('all', 'All'),
      ('manager13f', '13F'),
      ('insider', 'Form 4'),
      ('congress', 'STOCK'),
      ('profile', 'Profile'),
    ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.account_tree_rounded,
            kicker: 'GURU UNIVERSE',
            title: context.tr('选择大佬', 'Select Guru'),
            trailing: Text(
              context.ui('${gurus.length} visible'),
              style: TextStyle(
                color: palette.faint,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            palette: palette,
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: TextField(
              key: const ValueKey('mobile-guru-universe-search'),
              controller: searchController,
              onChanged: onSearch,
              style: TextStyle(color: palette.text, fontSize: 13),
              decoration: InputDecoration(
                hintText: context.ui('Search guru / firm / ticker'),
                hintStyle: TextStyle(color: palette.faint),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: palette.muted,
                  size: 19,
                ),
                filled: true,
                fillColor: palette.background.withValues(alpha: .48),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: palette.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: palette.accent),
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final item in filters) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      selected: filter == item.$1,
                      onSelected: (_) => onFilter(item.$1),
                      label: Text(context.ui(item.$2)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 104,
            child: gurus.isEmpty
                ? EmptyState(
                    text: 'No gurus match this filter.',
                    palette: palette,
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: gurus.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final guru = gurus[index];
                      return _MobileGuruCard(
                        guru: guru,
                        active: text(guru['id']) == selectedGuruId,
                        palette: palette,
                        onTap: () => onSelect(text(guru['id'])),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MobileGuruCard extends StatelessWidget {
  const _MobileGuruCard({
    required this.guru,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> guru;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(guru['summary']);
    final type = text(guru['type']);
    final metric = type == 'manager13f'
        ? formatMoney(reported13fTableValue(guru))
        : type == 'insider'
        ? context.ui(
            '${formatNumber(number(summary['trackedTickers']))} stocks',
          )
        : context.ui(
            '${formatNumber(number(summary['recentTransactions']))} trades',
          );
    final sub = type == 'manager13f'
        ? context.ui(
            '${formatNumber(number(summary['totalPositions']))} holdings',
          )
        : type == 'insider'
        ? context.ui(
            'sold ${formatMoney(number(summary['cumulativeSoldValue']))}',
          )
        : disclosureLabel(type, context.language);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 174,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: active ? palette.accent.withValues(alpha: .14) : palette.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? palette.accent.withValues(alpha: .62)
                : palette.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GuruAvatar(guru: guru, palette: palette, size: 36),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        guruDisplayName(guru, context.language),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        metric,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? palette.accent : palette.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              text(guru['entityName'], disclosureLabel(type, context.language)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.faint, fontSize: 10),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${disclosureLabel(type, context.language)} · $sub',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                StatusDot(status: guruDisplayStatus(guru), palette: palette),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MobileOverviewBar extends StatelessWidget {
  const MobileOverviewBar({
    super.key,
    required this.stats,
    required this.palette,
  });

  final ExecutiveStats stats;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final cards = [
      StatCardData('Coverage', '${stats.count}', 'gurus', Icons.radar_rounded),
      StatCardData(
        'Reported 13F value',
        formatMoney(stats.aum),
        'information-table total',
        Icons.account_balance_wallet_rounded,
      ),
      StatCardData(
        'Spread',
        signedNumber(stats.netSignals),
        'buy minus sell',
        Icons.bolt_rounded,
      ),
      StatCardData(
        'Quarter',
        stats.latestQuarter,
        'latest filing',
        Icons.calendar_month_rounded,
      ),
    ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        height: 76,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cards.length,
          separatorBuilder: (context, index) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final card = cards[index];
            return Container(
              width: 142,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              child: Row(
                children: [
                  Icon(card.icon, color: palette.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          context.ui(card.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          card.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          context.ui(card.sub),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.faint, fontSize: 9),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class GuruListTile extends StatelessWidget {
  const GuruListTile({
    super.key,
    required this.guru,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> guru;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(guru['summary']);
    final type = text(guru['type']);
    final metric = type == 'manager13f'
        ? formatMoney(reported13fTableValue(guru))
        : type == 'profile'
        ? context.ui('Profile')
        : type == 'insider'
        ? context.ui(
            '${formatNumber(number(summary['trackedTickers']))} stocks',
          )
        : context.ui(
            '${formatNumber(number(summary['recentTransactions']))} trades',
          );
    final sub = type == 'manager13f'
        ? context.ui(
            '${formatNumber(number(summary['totalPositions']))} holdings',
          )
        : type == 'insider'
        ? context.ui(
            'sold ${formatMoney(number(summary['cumulativeSoldValue']))}',
          )
        : context.ui(text(guru['sourceLabel'], text(guru['disclosureKind'])));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? palette.accent.withValues(alpha: .14)
                : palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? palette.accent.withValues(alpha: .65)
                  : palette.border,
            ),
          ),
          child: Row(
            children: [
              GuruAvatar(guru: guru, palette: palette, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      guruDisplayName(guru, context.language),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${disclosureLabel(type, context.language)} · $sub',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    metric,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  StatusDot(status: guruDisplayStatus(guru), palette: palette),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GuruAvatar extends StatelessWidget {
  const GuruAvatar({
    super.key,
    required this.guru,
    required this.palette,
    this.size = 40,
  });

  final Map<String, dynamic> guru;
  final Palette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = resolvedGuruAvatarUrl(guru);
    final name = guruDisplayName(guru, context.language);
    final fallback = _AvatarInitial(name: name, palette: palette, size: size);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFDADFE6),
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 10,
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipOval(
        child: url.isEmpty
            ? fallback
            : Image.network(
                url,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
      ),
    );
  }
}

class _AvatarInitial extends StatelessWidget {
  const _AvatarInitial({
    required this.name,
    required this.palette,
    required this.size,
  });

  final String name;
  final Palette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = text(name, '?').characters.first.toUpperCase();
    return Container(
      color: palette.accent.withValues(alpha: .17),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: palette.accent,
          fontSize: math.max(13, size * .34),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class GuruWorkspace extends StatefulWidget {
  const GuruWorkspace({
    super.key,
    required this.guru,
    required this.api,
    required this.palette,
    required this.initialModule,
    required this.initialTicker,
    required this.initialQuarterId,
    required this.onModuleChanged,
    required this.onTickerChanged,
    required this.onQuarterChanged,
  });

  final Map<String, dynamic> guru;
  final ApiClient api;
  final Palette palette;
  final int initialModule;
  final String initialTicker;
  final String initialQuarterId;
  final ValueChanged<int> onModuleChanged;
  final ValueChanged<String> onTickerChanged;
  final ValueChanged<String> onQuarterChanged;

  @override
  State<GuruWorkspace> createState() => _GuruWorkspaceState();
}

class _GuruWorkspaceState extends State<GuruWorkspace> {
  int _module = 0;
  Map<String, dynamic>? _backtestPayload;
  bool _backtestLoading = false;
  String? _backtestError;
  Map<String, dynamic>? _exposurePayload;
  bool _exposureLoading = false;
  String? _exposureError;
  Map<String, dynamic>? _contextPayload;
  bool _contextLoading = false;
  String? _contextError;
  String _selectedTicker = '';
  String _selectedQuarterId = '';
  Timer? _backtestWarmupTimer;
  int _backtestWarmupPolls = 0;
  bool _backtestFullAttribution = false;
  String _backtestWindow = '5';
  String? _backtestRequestedWindow;
  String? _backtestWindowError;
  int _backtestRequestId = 0;
  int _exposureRequestId = 0;

  int get _maximumModule => text(widget.guru['type']) == 'manager13f' ? 3 : 2;

  @override
  void initState() {
    super.initState();
    _module = widget.initialModule.clamp(0, _maximumModule).toInt();
    _selectedTicker = _initialTicker();
    _selectedQuarterId = widget.initialQuarterId;
    scheduleMicrotask(() {
      _loadBacktest(fullAttribution: _module == 2);
      if (_module == 3) _loadExposure();
      if (_selectedTicker.isNotEmpty) _loadContext(_selectedTicker);
    });
  }

  @override
  void didUpdateWidget(covariant GuruWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final guruChanged = text(oldWidget.guru['id']) != text(widget.guru['id']);
    final routeChanged =
        oldWidget.initialModule != widget.initialModule ||
        oldWidget.initialTicker != widget.initialTicker ||
        oldWidget.initialQuarterId != widget.initialQuarterId;
    if (!guruChanged && !routeChanged) return;
    final ticker = _initialTicker();
    if (guruChanged) {
      _backtestWarmupTimer?.cancel();
      _backtestWarmupPolls = 0;
      _backtestRequestId += 1;
      _exposureRequestId += 1;
    }
    setState(() {
      if (guruChanged) {
        _backtestPayload = null;
        _backtestError = null;
        _backtestLoading = false;
        _backtestFullAttribution = false;
        _backtestWindow = '5';
        _backtestRequestedWindow = null;
        _backtestWindowError = null;
        _exposurePayload = null;
        _exposureError = null;
        _exposureLoading = false;
        _contextPayload = null;
        _contextError = null;
        _contextLoading = false;
      }
      _module = widget.initialModule.clamp(0, _maximumModule).toInt();
      _selectedTicker = ticker;
      _selectedQuarterId = widget.initialQuarterId;
    });
    scheduleMicrotask(() {
      if (!mounted) return;
      if (guruChanged) {
        widget.onTickerChanged(ticker);
        _loadBacktest(fullAttribution: _module == 2);
        if (_module == 3) _loadExposure();
      }
      if (ticker.isNotEmpty &&
          (guruChanged || ticker != oldWidget.initialTicker)) {
        _loadContext(ticker);
      }
      if (!guruChanged && _module == 2 && !_backtestFullAttribution) {
        _loadBacktest(fullAttribution: true);
      }
      if (!guruChanged && _module == 3 && _exposurePayload == null) {
        _loadExposure();
      }
    });
  }

  @override
  void dispose() {
    _backtestWarmupTimer?.cancel();
    super.dispose();
  }

  String _defaultTicker() {
    final rows = guruTradeRows(widget.guru);
    final primary = rows.firstWhere(
      (row) => ['new', 'sold_out'].contains(text(row['action'])),
      orElse: () => rows.isNotEmpty ? rows.first : <String, dynamic>{},
    );
    return text(primary['ticker']);
  }

  String _initialTicker() {
    final preferred = widget.initialTicker.trim().toUpperCase();
    if (preferred.isNotEmpty) {
      final rows = guruTradeRows(widget.guru);
      final match = rows.any(
        (row) => text(row['ticker']).toUpperCase() == preferred,
      );
      if (match) return preferred;
    }
    return _defaultTicker();
  }

  Map<String, dynamic> get _selectedTrade {
    final rows = guruTradeRows(widget.guru);
    return rows.firstWhere(
      (row) => text(row['ticker']) == _selectedTicker,
      orElse: () => rows.isNotEmpty ? rows.first : <String, dynamic>{},
    );
  }

  bool get _usesWorkspaceModules {
    final type = text(widget.guru['type']);
    final sim = asMap(widget.guru['simulationTag']);
    return type == 'manager13f' ||
        (type == 'congress' && text(sim['tone']) != 'muted');
  }

  bool _isBacktestWarming(Map<String, dynamic>? payload) {
    if (payload == null) return false;
    return truthy(payload['historyWarming']) ||
        text(asMap(payload['cache'])['status']) == 'sqlite-fallback';
  }

  void _scheduleBacktestWarmupPoll(Map<String, dynamic> payload) {
    _backtestWarmupTimer?.cancel();
    if (!_isBacktestWarming(payload) || _backtestWarmupPolls >= 8) return;
    _backtestWarmupPolls += 1;
    final scheduledWindow = _backtestWindow;
    _backtestWarmupTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted ||
          _backtestRequestedWindow != null ||
          _backtestWindow != scheduledWindow) {
        return;
      }
      _loadBacktest(
        quiet: true,
        fullAttribution: _backtestFullAttribution,
        years: scheduledWindow,
      );
    });
  }

  Future<void> _loadBacktest({
    bool quiet = false,
    bool fullAttribution = false,
    bool forceRefresh = false,
    String? years,
    bool explicitWindow = false,
  }) async {
    final id = text(widget.guru['id']);
    final requestedYears =
        _guruBacktestWindowValue(years ?? _backtestWindow) ?? _backtestWindow;
    final sim = asMap(widget.guru['simulationTag']);
    if (id.isEmpty || text(sim['tone']) == 'muted' || !_usesWorkspaceModules) {
      return;
    }
    if (quiet && _backtestRequestedWindow != null) return;
    if (!quiet && !explicitWindow && _backtestLoading) return;
    if (!quiet || explicitWindow) {
      _backtestWarmupTimer?.cancel();
      _backtestWarmupPolls = 0;
    }
    final requestId = ++_backtestRequestId;
    if (!quiet || _backtestPayload == null) {
      setState(() {
        _backtestLoading = true;
        _backtestError = null;
        _backtestRequestedWindow = explicitWindow ? requestedYears : null;
        _backtestWindowError = null;
      });
    }
    try {
      final payload = await widget.api.getJson(
        guruBacktestPath(
          id,
          years: requestedYears,
          fullAttribution: fullAttribution,
          refresh: forceRefresh,
        ),
      );
      if (!mounted ||
          id != text(widget.guru['id']) ||
          requestId != _backtestRequestId) {
        return;
      }
      final responseWindow = _guruBacktestWindowValue(
        asMap(payload['method'])['years'],
      );
      final windowMatches = responseWindow == requestedYears;
      final payloadStrictReady = _isStrictReadyBacktest(payload);
      final payloadProxyReady = _isProxyReadyBacktest(payload);
      final payloadDisplayable =
          windowMatches && (payloadStrictReady || payloadProxyReady);
      final existingStrictReady = _isStrictReadyBacktest(_backtestPayload);
      final existingDisplayable = _isDisplayableBacktest(_backtestPayload);
      final explicitDifferentWindow =
          explicitWindow && requestedYears != _backtestWindow;
      final adoptDisplayable =
          payloadDisplayable &&
          (!existingDisplayable ||
              payloadStrictReady ||
              !existingStrictReady ||
              explicitDifferentWindow);
      final adoptPayload =
          windowMatches && (adoptDisplayable || !existingDisplayable);
      setState(() {
        if (!windowMatches) {
          final mismatch = context.tr(
            '历史区间响应不一致：请求 $requestedYears，返回 ${responseWindow ?? '未知'}。已保留最近可用曲线。',
            'Backtest window mismatch: requested $requestedYears, received ${responseWindow ?? 'unknown'}. The latest available curve was kept.',
          );
          if (existingDisplayable) {
            _backtestWindowError = mismatch;
          } else {
            _backtestError = mismatch;
          }
        } else if (adoptPayload) {
          _backtestPayload = payload;
          _backtestWindow = requestedYears;
          _backtestFullAttribution =
              fullAttribution ||
              text(asMap(payload['detail'])['attribution']) == 'full';
          if (!_isBacktestWarming(payload)) _backtestWarmupPolls = 0;
        } else {
          _backtestWindowError = payloadProxyReady && existingStrictReady
              ? context.tr(
                  '该区间返回了公开持仓代理；已保留严格审计曲线。',
                  'This window returned a public-holdings proxy; the strict audited curve was kept.',
                )
              : text(
                  asMap(payload['method'])['reason'],
                  context.tr(
                    '所选历史区间尚未通过审计；继续显示最近可用曲线。',
                    'The requested history has not passed audit; keeping the latest available curve.',
                  ),
                );
        }
        _backtestRequestedWindow = null;
      });
      if (adoptPayload) {
        _scheduleBacktestWarmupPoll(payload);
      } else if (existingDisplayable) {
        _resumeBacktestWarmupPoll();
      }
      if (_module == 2 &&
          !fullAttribution &&
          _isDisplayableBacktest(_backtestPayload) &&
          text(asMap(_backtestPayload?['detail'])['attribution']) != 'full') {
        scheduleMicrotask(() {
          if (mounted &&
              !_backtestLoading &&
              _backtestRequestedWindow == null) {
            _loadBacktest(fullAttribution: true, years: _backtestWindow);
          }
        });
      }
    } catch (error) {
      if (!mounted ||
          id != text(widget.guru['id']) ||
          requestId != _backtestRequestId) {
        return;
      }
      if (_isDisplayableBacktest(_backtestPayload)) {
        setState(() {
          _backtestWindowError = error.toString();
          _backtestRequestedWindow = null;
        });
        _resumeBacktestWarmupPoll();
        if (_module == 2 &&
            !fullAttribution &&
            text(asMap(_backtestPayload?['detail'])['attribution']) != 'full') {
          scheduleMicrotask(() {
            if (mounted &&
                !_backtestLoading &&
                _backtestRequestedWindow == null) {
              _loadBacktest(fullAttribution: true, years: _backtestWindow);
            }
          });
        }
      } else if (!quiet || _backtestPayload == null) {
        setState(() {
          _backtestError = error.toString();
          _backtestRequestedWindow = null;
        });
      }
    } finally {
      if (mounted &&
          id == text(widget.guru['id']) &&
          requestId == _backtestRequestId &&
          (!quiet || _backtestPayload == null)) {
        setState(() {
          _backtestLoading = false;
          _backtestRequestedWindow = null;
        });
      }
    }
  }

  void _resumeBacktestWarmupPoll() {
    final payload = _backtestPayload;
    if (payload != null &&
        _isDisplayableBacktest(payload) &&
        _isBacktestWarming(payload)) {
      _scheduleBacktestWarmupPoll(payload);
    }
  }

  void _requestBacktestWindow(String years) {
    final requestedYears = _guruBacktestWindowValue(years);
    if (requestedYears == null || requestedYears == _backtestRequestedWindow) {
      return;
    }
    final existingDisplayable = _isDisplayableBacktest(_backtestPayload);
    if (existingDisplayable && requestedYears == _backtestWindow) {
      _backtestWarmupTimer?.cancel();
      _backtestWarmupPolls = 0;
      _backtestRequestId += 1;
      setState(() {
        _backtestLoading = false;
        _backtestRequestedWindow = null;
        _backtestWindowError = null;
      });
      _resumeBacktestWarmupPoll();
      return;
    }
    _loadBacktest(
      years: requestedYears,
      fullAttribution: _backtestFullAttribution,
      explicitWindow: true,
    );
  }

  void _selectModule(int value) {
    final selected = value.clamp(0, _maximumModule).toInt();
    setState(() => _module = selected);
    widget.onModuleChanged(selected);
    if (_usesWorkspaceModules &&
        selected == 2 &&
        !_backtestFullAttribution &&
        _backtestRequestedWindow == null) {
      _loadBacktest(fullAttribution: true);
    }
    if (selected == 3 && _exposurePayload == null && !_exposureLoading) {
      _loadExposure();
    }
  }

  Future<void> _loadExposure({bool forceRefresh = false}) async {
    final id = text(widget.guru['id']);
    if (id.isEmpty || text(widget.guru['type']) != 'manager13f') return;
    if (_exposureLoading) return;
    final requestId = ++_exposureRequestId;
    setState(() {
      _exposureLoading = true;
      _exposureError = null;
    });
    try {
      final encodedId = Uri.encodeComponent(id);
      final payload = await widget.api.getJson(
        '/api/gurus/$encodedId/exposure?limit=40${forceRefresh ? '&refresh=1' : ''}',
      );
      if (!mounted ||
          id != text(widget.guru['id']) ||
          requestId != _exposureRequestId) {
        return;
      }
      setState(() => _exposurePayload = payload);
    } catch (error) {
      if (!mounted ||
          id != text(widget.guru['id']) ||
          requestId != _exposureRequestId) {
        return;
      }
      setState(() => _exposureError = error.toString());
    } finally {
      if (mounted &&
          id == text(widget.guru['id']) &&
          requestId == _exposureRequestId) {
        setState(() => _exposureLoading = false);
      }
    }
  }

  Future<void> _loadContext(String ticker) async {
    final id = text(widget.guru['id']);
    if (id.isEmpty ||
        ticker.isEmpty ||
        text(widget.guru['type']) == 'profile') {
      return;
    }
    setState(() {
      _selectedTicker = ticker;
      _contextPayload = null;
      _contextError = null;
      _contextLoading = true;
    });
    widget.onTickerChanged(ticker);
    try {
      final encodedTicker = Uri.encodeQueryComponent(ticker);
      final payload = await widget.api.getJson(
        '/api/gurus/$id/context?ticker=$encodedTicker',
      );
      if (!mounted ||
          id != text(widget.guru['id']) ||
          ticker != _selectedTicker) {
        return;
      }
      setState(() => _contextPayload = payload);
    } catch (error) {
      if (!mounted ||
          id != text(widget.guru['id']) ||
          ticker != _selectedTicker) {
        return;
      }
      setState(() => _contextError = error.toString());
    } finally {
      if (mounted &&
          id == text(widget.guru['id']) &&
          ticker == _selectedTicker) {
        setState(() => _contextLoading = false);
      }
    }
  }

  void _selectTrade(Map<String, dynamic> row) {
    final ticker = text(row['ticker']);
    if (ticker.isEmpty || ticker == _selectedTicker) return;
    _loadContext(ticker);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.guru.isEmpty) {
      return Panel(
        palette: widget.palette,
        child: EmptyState(
          text: 'Select a guru to inspect.',
          palette: widget.palette,
        ),
      );
    }
    final type = text(widget.guru['type']);
    final usesWorkspaceModules = _usesWorkspaceModules;
    return Column(
      children: [
        GuruWorkspaceHeader(guru: widget.guru, palette: widget.palette),
        if (type == 'profile') ...[
          const SizedBox(height: 14),
          GuruProfileModule(guru: widget.guru, palette: widget.palette),
        ] else if (usesWorkspaceModules) ...[
          const SizedBox(height: 14),
          GuruModuleTabs(
            selected: _module,
            onChanged: _selectModule,
            palette: widget.palette,
            showPositionHistory: type == 'manager13f',
          ),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: KeyedSubtree(
              key: ValueKey(_module),
              child: switch (_module) {
                0 => GuruSimulationModule(
                  payload: _backtestPayload,
                  loading: _backtestLoading,
                  error: _backtestError,
                  guru: widget.guru,
                  palette: widget.palette,
                  loadedWindow: _backtestWindow,
                  requestedWindow: _backtestRequestedWindow,
                  windowError: _backtestWindowError,
                  onWindowRequested: _requestBacktestWindow,
                  onRetry: _backtestLoading || _backtestRequestedWindow != null
                      ? null
                      : () => _loadBacktest(forceRefresh: true),
                ),
                1 => GuruTradeModule(
                  guru: widget.guru,
                  selectedTicker: _selectedTicker,
                  selectedTrade: _selectedTrade,
                  contextPayload: _contextPayload,
                  loading: _contextLoading,
                  error: _contextError,
                  palette: widget.palette,
                  onSelect: _selectTrade,
                  onRetry: () => _loadContext(_selectedTicker),
                ),
                2 => GuruQuarterContributionModule(
                  payload: _backtestPayload,
                  loading: _backtestLoading,
                  error: _backtestError ?? _backtestWindowError,
                  selectedQuarterId: _selectedQuarterId,
                  onSelectQuarter: (value) => setState(() {
                    _selectedQuarterId = value;
                    widget.onQuarterChanged(value);
                  }),
                  palette: widget.palette,
                  onRetry: _backtestLoading || _backtestRequestedWindow != null
                      ? null
                      : () => _loadBacktest(
                          fullAttribution: true,
                          forceRefresh: true,
                          years: _backtestWindow,
                        ),
                ),
                _ => GuruPositionHistoryModule(
                  guru: widget.guru,
                  payload: _exposurePayload,
                  loading: _exposureLoading,
                  error: _exposureError,
                  palette: widget.palette,
                  onRetry: _exposureLoading
                      ? null
                      : () => _loadExposure(forceRefresh: true),
                ),
              },
            ),
          ),
        ] else ...[
          const SizedBox(height: 14),
          GuruTradeModule(
            guru: widget.guru,
            selectedTicker: _selectedTicker,
            selectedTrade: _selectedTrade,
            contextPayload: _contextPayload,
            loading: _contextLoading,
            error: _contextError,
            palette: widget.palette,
            onSelect: _selectTrade,
            onRetry: () => _loadContext(_selectedTicker),
          ),
        ],
      ],
    );
  }
}

class GuruWorkspaceHeader extends StatelessWidget {
  const GuruWorkspaceHeader({
    super.key,
    required this.guru,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(guru['summary']);
    final type = text(guru['type']);
    final reportDate = text(summary['reportDate']);
    final latestQuarter = reportQuarterLabel(reportDate);
    final filing = formatDate(text(summary['filingDate']));
    final strategy = text(guru['thesisTag'], 'Concentrated');
    final reported13fBreakdown = context.tr(
      '普通股多头 ${formatMoney(reported13fCommonLongValue(guru))} · 期权 ${formatMoney(reported13fOptionsValue(guru))}',
      'Common-long ${formatMoney(reported13fCommonLongValue(guru))} · Options ${formatMoney(reported13fOptionsValue(guru))}',
    );
    final reported13fBreakdownShort = context.tr(
      '多头 ${formatMoney(reported13fCommonLongValue(guru))} · 期权 ${formatMoney(reported13fOptionsValue(guru))}',
      'Long ${formatMoney(reported13fCommonLongValue(guru))} · Opt ${formatMoney(reported13fOptionsValue(guru))}',
    );
    return Panel(
      palette: palette,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final veryCompact = constraints.maxWidth < 420;
          final identity = Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomCenter,
                children: [
                  GuruAvatar(
                    guru: guru,
                    palette: palette,
                    size: veryCompact ? 58 : 72,
                  ),
                  Positioned(
                    bottom: -8,
                    child: BadgeLabel(
                      text: disclosureLabel(type, context.language),
                      color: palette.accent,
                    ),
                  ),
                ],
              ),
              SizedBox(width: veryCompact ? 12 : 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      guruDisplayName(guru, context.language),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: veryCompact ? 18 : 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      text(guru['entityName']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        InfoChip(context.ui(strategy), palette: palette),
                        InfoChip(
                          context.ui(
                            text(asMap(guru['simulationTag'])['label']),
                          ),
                          palette: palette,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
          final metrics = type == 'manager13f'
              ? [
                  _GuruHeaderMetric(
                    label: 'Reported 13F value',
                    value: formatMoney(reported13fTableValue(guru)),
                    sub: reported13fBreakdownShort,
                    tooltip: reported13fBreakdown,
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Holdings',
                    value: formatNumber(number(summary['totalPositions'])),
                    sub: 'latest disclosed',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Latest Quarter',
                    value: latestQuarter,
                    sub: filing == '-' ? 'waiting filing' : 'filed $filing',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Filing Lag',
                    value: filingLagVerbose(summary),
                    sub: 'vs quarter end',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Strategy',
                    value: compactStrategy(context.ui(strategy)),
                    sub: text(guru['disclosureKind'], 'High Conviction'),
                    palette: palette,
                  ),
                ]
              : type == 'insider'
              ? [
                  _GuruHeaderMetric(
                    label: 'Stocks',
                    value: formatNumber(number(summary['trackedTickers'])),
                    sub: 'Form 4 tickers tracked',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Held shares',
                    value: formatNumber(
                      number(summary['totalLatestSharesOwned']),
                    ),
                    sub: 'latest post-transaction',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Cum sold',
                    value: formatMoney(number(summary['cumulativeSoldValue'])),
                    sub:
                        '${formatNumber(number(summary['cumulativeSoldShares']))} shares',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Latest',
                    value: formatDate(text(summary['reportDate'])),
                    sub: filing == '-' ? 'Form 4 trail' : 'filed $filing',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Focus',
                    value: text(
                      summary['latestTicker'],
                      text(guru['focusTicker'], '-'),
                    ),
                    sub: compactName(
                      text(summary['latestIssuer'], text(guru['focusIssuer'])),
                    ),
                    palette: palette,
                  ),
                ]
              : [
                  _GuruHeaderMetric(
                    label: 'Source',
                    value: disclosureLabel(type, context.language),
                    sub: text(guru['sourceLabel'], text(guru['profileUrl'])),
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Activity',
                    value: formatNumber(number(summary['recentTransactions'])),
                    sub:
                        '${formatNumber(number(summary['buys']))} buy / ${formatNumber(number(summary['sells']))} sell',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Latest',
                    value: formatDate(text(summary['reportDate'])),
                    sub: filing == '-' ? 'disclosure trail' : 'filed $filing',
                    palette: palette,
                  ),
                  _GuruHeaderMetric(
                    label: 'Focus',
                    value: text(
                      summary['latestTicker'],
                      text(guru['focusTicker'], '-'),
                    ),
                    sub: compactName(
                      text(summary['latestIssuer'], text(guru['focusIssuer'])),
                    ),
                    palette: palette,
                  ),
                ];
          final metricsRow = Expanded(
            child: IntrinsicHeight(
              child: Row(
                children: [
                  for (var i = 0; i < metrics.length; i += 1) ...[
                    Expanded(child: metrics[i]),
                    if (i != metrics.length - 1)
                      VerticalDivider(color: palette.border, width: 24),
                  ],
                ],
              ),
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                const SizedBox(height: 18),
                GridWrap(minTileWidth: 130, spacing: 10, children: metrics),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: math.min(360, constraints.maxWidth * .36),
                child: identity,
              ),
              const SizedBox(width: 18),
              metricsRow,
              const SizedBox(width: 10),
              StatusDot(status: guruDisplayStatus(guru), palette: palette),
            ],
          );
        },
      ),
    );
  }
}

class _GuruHeaderMetric extends StatelessWidget {
  const _GuruHeaderMetric({
    required this.label,
    required this.value,
    required this.sub,
    required this.palette,
    this.tooltip,
  });

  final String label;
  final String value;
  final String sub;
  final Palette palette;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final metric = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ui(label),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.ui(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            context.ui(sub),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.faint,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    final message = text(tooltip);
    return message.isEmpty ? metric : Tooltip(message: message, child: metric);
  }
}

class GuruModuleTabs extends StatelessWidget {
  const GuruModuleTabs({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.palette,
    this.showPositionHistory = false,
  });

  final int selected;
  final ValueChanged<int> onChanged;
  final Palette palette;
  final bool showPositionHistory;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        Icons.stacked_line_chart_rounded,
        context.tr('模拟', 'Simulation'),
        context.tr('模拟', 'Sim'),
        'Portfolio vs SPY',
      ),
      (
        Icons.swap_vert_rounded,
        context.tr('新买入/卖出', 'New Buys & Sells'),
        context.tr('交易', 'Trades'),
        'Reported position changes',
      ),
      (
        Icons.calendar_month_rounded,
        context.tr('季度贡献', 'Quarterly Contribution'),
        context.tr('贡献', 'Contribution'),
        'Quarterly Contribution',
      ),
      if (showPositionHistory)
        (
          Icons.timeline_rounded,
          context.tr('仓位轨迹', 'Position History'),
          context.tr('轨迹', 'History'),
          context.tr('按季度与股票追踪', 'Quarter and stock trajectory'),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return Container(
          width: double.infinity,
          height: compact ? 58 : 72,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i += 1)
                Expanded(
                  child: _ModuleTabButton(
                    icon: items[i].$1,
                    label: compact ? items[i].$3 : items[i].$2,
                    sublabel: compact ? '' : items[i].$4,
                    selected: selected == i,
                    palette: palette,
                    compact: compact,
                    onTap: () => onChanged(i),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ModuleTabButton extends StatelessWidget {
  const _ModuleTabButton({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.selected,
    required this.palette,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String sublabel;
  final bool selected;
  final Palette palette;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: selected ? palette.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? palette.accent : palette.muted,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: compact
                    ? Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? palette.accent : palette.muted,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? palette.accent : palette.muted,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            context.ui(sublabel),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.faint,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
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
}

class _PublicHoldingsProxyNotice extends StatelessWidget {
  const _PublicHoldingsProxyNotice({
    required this.payload,
    required this.palette,
    required this.noticeKey,
  });

  final Map<String, dynamic>? payload;
  final Palette palette;
  final Key noticeKey;

  String _percent(Map<String, dynamic> proxy, List<String> keys) {
    final key = keys.firstWhere(
      (candidate) => proxy.containsKey(candidate) && proxy[candidate] != null,
      orElse: () => '',
    );
    if (key.isEmpty) return '—';
    var value = number(proxy[key]);
    if (!value.isFinite) return '—';
    if (value.abs() > 1) value /= 100;
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  String _count(Map<String, dynamic> proxy, List<String> keys) {
    final key = keys.firstWhere(
      (candidate) => proxy.containsKey(candidate) && proxy[candidate] != null,
      orElse: () => '',
    );
    if (key.isEmpty) return '—';
    return number(proxy[key]).round().toString();
  }

  @override
  Widget build(BuildContext context) {
    final proxy = asMap(payload?['proxy']);
    final replicability = _backtestReplicability(payload);
    final hasPrivateExecutionGap =
        text(replicability['code']) ==
        'reported_holding_private_before_execution';
    final affectedQuarter = _replicabilityQuarterLabel(replicability);
    final affectedTicker = _replicabilityTicker(replicability);
    final minimumCoverage = _percent(proxy, const [
      'minimumSelectedBookCoverage',
      'minimumReportedCoverage',
    ]);
    final averageCoverage = _percent(proxy, const [
      'averageSelectedBookCoverage',
      'averageReportedCoverage',
    ]);
    final excludedWeight = _percent(proxy, const [
      'maximumExcludedBookWeight',
      'excludedWeightMax',
    ]);
    final includedPositions = _count(proxy, const [
      'minimumIncludedPositions',
      'includedPositionCountMin',
    ]);
    final topExcluded = asList(proxy['topExcludedHoldings'])
        .map(asMap)
        .map((row) => text(row['ticker'], text(row['issuer'])))
        .where((value) => value.isNotEmpty)
        .take(4)
        .join(', ');
    final summary = hasPrivateExecutionGap
        ? context.tr(
            '严格复制不可用 · $affectedQuarter $affectedTicker 已转为私有',
            'Strict replay unavailable · $affectedQuarter $affectedTicker became private',
          )
        : context.tr(
            '公开持仓代理 · Top-60 可定价权重最低 $minimumCoverage · 最少 $includedPositions 只',
            'Public sleeve proxy · $minimumCoverage min Top-60 priceable weight · $includedPositions+ holdings',
          );

    Widget metric(String label, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: palette.accent.withValues(alpha: .24)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 11, height: 1.2),
      ),
    );

    return Material(
      key: noticeKey,
      color: palette.accent.withValues(alpha: .08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: palette.accent.withValues(alpha: .3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('guru-proxy-disclosure-expander'),
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 11),
          childrenPadding: const EdgeInsets.fromLTRB(11, 0, 11, 11),
          collapsedIconColor: palette.accent,
          iconColor: palette.accent,
          leading: Icon(
            Icons.visibility_outlined,
            color: palette.accent,
            size: 17,
          ),
          title: Text(
            summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.accent,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              height: 1.25,
            ),
          ),
          children: [
            if (hasPrivateExecutionGap) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _replicabilityReason(context, replicability),
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  metric(
                    context.tr(
                      'Top-60 最低可定价权重',
                      'Minimum Top-60 priceable weight',
                    ),
                    minimumCoverage,
                  ),
                  metric(
                    context.tr(
                      'Top-60 平均可定价权重',
                      'Average Top-60 priceable weight',
                    ),
                    averageCoverage,
                  ),
                  metric(
                    context.tr('最高排除权重', 'Maximum excluded weight'),
                    excludedWeight,
                  ),
                ],
              ),
            ),
            if (topExcluded.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.tr(
                    '主要排除标的：$topExcluded',
                    'Largest excluded holdings: $topExcluded',
                  ),
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.tr(
                  '仅重新归一化 Top-60 披露普通多头中、持有期价格完整的部分；13F 滞后且不包含完整基金头寸。该曲线不是经过严格覆盖审计的基金业绩。',
                  'Only the fully priceable part of the Top-60 disclosed common-long book is renormalized. 13F data are delayed and omit the complete fund. This is not a strict coverage-audited fund return.',
                ),
                style: TextStyle(
                  color: palette.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrictReplicationUnavailableNotice extends StatelessWidget {
  const _StrictReplicationUnavailableNotice({
    required this.payload,
    required this.palette,
  });

  final Map<String, dynamic>? payload;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final replicability = _backtestReplicability(payload);
    if (replicability.isEmpty) {
      return EmptyState(
        text: context.ui(
          text(asMap(payload?['method'])['reason'], 'Backtest is not ready.'),
        ),
        palette: palette,
      );
    }
    final quarter = _replicabilityQuarterLabel(replicability);
    final ticker = _replicabilityTicker(replicability);
    final weight = _replicabilityHoldingWeight(replicability);
    final detail = [
      if (quarter.isNotEmpty) quarter,
      if (ticker.isNotEmpty) ticker,
      if (weight.isNotEmpty)
        context.tr('申报权重 $weight', '$weight of selected book'),
    ].join(' · ');
    return Container(
      key: const ValueKey('guru-strict-replication-unavailable'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.negative.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.negative.withValues(alpha: .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 17,
                color: palette.negative,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('严格复制不可用', 'Strict replay unavailable'),
                  style: TextStyle(
                    color: palette.negative,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              detail,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 7),
          Text(
            _replicabilityReason(context, replicability),
            style: TextStyle(
              color: palette.muted,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class GuruSimulationModule extends StatefulWidget {
  const GuruSimulationModule({
    super.key,
    required this.payload,
    required this.loading,
    required this.error,
    required this.guru,
    required this.palette,
    required this.loadedWindow,
    required this.requestedWindow,
    required this.windowError,
    required this.onWindowRequested,
    required this.onRetry,
  });

  final Map<String, dynamic>? payload;
  final bool loading;
  final String? error;
  final Map<String, dynamic> guru;
  final Palette palette;
  final String loadedWindow;
  final String? requestedWindow;
  final String? windowError;
  final ValueChanged<String> onWindowRequested;
  final VoidCallback? onRetry;

  @override
  State<GuruSimulationModule> createState() => _GuruSimulationModuleState();
}

class GuruProfileModule extends StatelessWidget {
  const GuruProfileModule({
    super.key,
    required this.guru,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(guru['summary']);
    final rawNotes = guru['notes'];
    final noteTexts = rawNotes is List
        ? rawNotes.map(text).where((item) => item.isNotEmpty).toList()
        : text(rawNotes).isNotEmpty
        ? [text(guru['notes'])]
        : <String>[];
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.person_search_rounded,
            kicker: 'RESEARCH PROFILE',
            title: context.tr('资料卡', 'Profile Card'),
            palette: palette,
          ),
          const SizedBox(height: 12),
          Text(
            text(
              summary['message'],
              context.tr(
                '这个 profile 没有干净的独立 13F 或 Form 4 交易流，作为研究资料入口展示。',
                'This profile does not have a clean standalone 13F or Form 4 trading feed, so it is shown as a research profile.',
              ),
            ),
            style: TextStyle(color: palette.muted, height: 1.35),
          ),
          if (noteTexts.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final note in noteTexts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.notes_rounded, color: palette.accent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note,
                        style: TextStyle(color: palette.muted, height: 1.35),
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
}

class _GuruSimulationModuleState extends State<GuruSimulationModule> {
  RangeValues? _range;
  String _rangeSignature = '';
  String _rangeWindow = '';
  String _selectedRangeStart = '';
  String _selectedRangeEnd = '';
  bool _rangeCoversLoadedWindow = true;

  void _rememberRange(List<Map<String, dynamic>> equity, RangeValues range) {
    final lastIndex = math.max(0, equity.length - 1);
    final start = range.start.round().clamp(0, lastIndex);
    final end = range.end.round().clamp(start, lastIndex);
    _range = RangeValues(start.toDouble(), end.toDouble());
    _rangeCoversLoadedWindow = start == 0 && end == lastIndex;
    _selectedRangeStart = equity.isEmpty ? '' : text(equity[start]['date']);
    _selectedRangeEnd = equity.isEmpty ? '' : text(equity[end]['date']);
  }

  void _syncRange(List<Map<String, dynamic>> equity, String loadedWindow) {
    final signature = equity.isEmpty
        ? '$loadedWindow:empty'
        : '$loadedWindow:${equity.map((row) => text(row['date'])).join('|')}';
    if (_rangeSignature == signature) return;
    final preserveSelectedDates =
        _rangeWindow == loadedWindow &&
        !_rangeCoversLoadedWindow &&
        _selectedRangeStart.isNotEmpty &&
        _selectedRangeEnd.isNotEmpty;
    _rangeSignature = signature;
    _rangeWindow = loadedWindow;
    final maxIndex = math.max(1, equity.length - 1).toDouble();
    if (preserveSelectedDates && equity.length >= 3) {
      var start = equity.indexWhere(
        (row) => text(row['date']).compareTo(_selectedRangeStart) >= 0,
      );
      var end = equity.lastIndexWhere(
        (row) => text(row['date']).compareTo(_selectedRangeEnd) <= 0,
      );
      if (start < 0) start = 0;
      if (end < 0) end = equity.length - 1;
      if (end - start >= 2) {
        _rememberRange(equity, RangeValues(start.toDouble(), end.toDouble()));
        return;
      }
    }
    _rememberRange(equity, RangeValues(0, maxIndex));
  }

  void _selectTrailingWindow(List<Map<String, dynamic>> equity, int years) {
    if (equity.length < 3) return;
    final lastDate = DateTime.tryParse(text(equity.last['date']));
    if (lastDate == null) return;
    final target = DateTime(
      lastDate.year - years,
      lastDate.month,
      lastDate.day,
    );
    var start = 0;
    for (var i = 0; i < equity.length; i += 1) {
      final date = DateTime.tryParse(text(equity[i]['date']));
      if (date != null && !date.isBefore(target)) {
        start = i;
        break;
      }
    }
    setState(
      () => _rememberRange(
        equity,
        RangeValues(start.toDouble(), equity.length - 1),
      ),
    );
  }

  void _selectAll(List<Map<String, dynamic>> equity) {
    setState(
      () => _rememberRange(
        equity,
        RangeValues(0, math.max(1, equity.length - 1).toDouble()),
      ),
    );
  }

  void _selectServerWindow(List<Map<String, dynamic>> equity, String window) {
    if (widget.requestedWindow == window) return;
    final alreadyLoaded = widget.loadedWindow.trim().toLowerCase() == window;
    if (alreadyLoaded) _selectAll(equity);
    if (!alreadyLoaded || widget.requestedWindow != null) {
      widget.onWindowRequested(window);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sim = asMap(widget.guru['simulationTag']);
    final isProxy = _isProxyReadyBacktest(widget.payload);
    final isRenaissance = text(widget.guru['id']) == 'renaissance-technologies';
    if (text(sim['tone']) == 'muted') {
      return Panel(
        palette: widget.palette,
        child: Text(
          context.ui(
            text(
              sim['description'],
              'This profile is not suitable for proportional 13F copy trading.',
            ),
          ),
          style: TextStyle(color: widget.palette.muted),
        ),
      );
    }
    final equity = asList(widget.payload?['equity']);
    final loadedWindow = widget.loadedWindow.trim().toLowerCase();
    _syncRange(equity, loadedWindow);
    final currentRange =
        _range ?? RangeValues(0, math.max(1, equity.length - 1).toDouble());
    final startIndex =
        currentRange.start.round().clamp(0, math.max(0, equity.length - 1))
            as int;
    final endIndex =
        currentRange.end.round().clamp(
              startIndex + 1,
              math.max(1, equity.length - 1),
            )
            as int;
    final visibleEquity = equity.length < 2
        ? equity
        : equity.sublist(startIndex, math.min(equity.length, endIndex + 1));
    final chartEquity = rebaseEquity(visibleEquity);
    final warming = truthy(widget.payload?['historyWarming']);
    final sampling = asMap(widget.payload?['equitySampling']);
    final allStart = equity.isEmpty
        ? ''
        : formatDate(text(equity.first['date']));
    final allEnd = equity.isEmpty ? '' : formatDate(text(equity.last['date']));
    final selectedStart = visibleEquity.isEmpty
        ? ''
        : formatDate(text(visibleEquity.first['date']));
    final selectedEnd = visibleEquity.isEmpty
        ? ''
        : formatDate(text(visibleEquity.last['date']));
    final isAll = startIndex <= 0 && endIndex >= math.max(0, equity.length - 1);
    final sampledSummary = simulationMetrics(chartEquity);
    final payloadSummary = asMap(widget.payload?['summary']);
    final payloadBenchmark = asMap(payloadSummary['benchmark']);
    final hasAuthoritativeFullSummary =
        isAll &&
        payloadSummary.containsKey('totalReturn') &&
        payloadSummary.containsKey('maxDrawdown') &&
        payloadBenchmark.containsKey('totalReturn');
    final summary = hasAuthoritativeFullSummary
        ? SimulationMetrics(
            totalReturn: number(payloadSummary['totalReturn']),
            benchmarkReturn: number(payloadBenchmark['totalReturn']),
            excessReturn: payloadSummary.containsKey('excessTotalReturn')
                ? number(payloadSummary['excessTotalReturn'])
                : number(payloadSummary['totalReturn']) -
                      number(payloadBenchmark['totalReturn']),
            maxDrawdown: number(payloadSummary['maxDrawdown']),
          )
        : sampledSummary;
    final selectedRangeApproximate = !isAll && truthy(sampling['sampled']);
    final samplingLabel = truthy(sampling['sampled'])
        ? context.tr(
            '图表抽样 ${formatNumber(number(sampling['returnedPoints']))}/${formatNumber(number(sampling['sourcePoints']))} 个交易日${selectedRangeApproximate ? '；所选子区间 MDD 为抽样近似值' : ''}',
            'Chart sampled ${formatNumber(number(sampling['returnedPoints']))}/${formatNumber(number(sampling['sourcePoints']))} trading days${selectedRangeApproximate ? '; selected-range MDD is approximate' : ''}',
          )
        : '';
    final loadedAll = loadedWindow == 'all';
    final resetLabel = loadedAll
        ? context.tr('全部', 'All')
        : context.tr('完整 $loadedWindow 年', 'Full ${loadedWindow}Y');
    final resetTooltip = isProxy
        ? loadedAll
              ? context.tr(
                  '恢复全部公开持仓代理历史',
                  'Reset to all public-sleeve proxy history',
                )
              : context.tr(
                  '恢复完整 $loadedWindow 年公开持仓代理区间',
                  'Reset to the full ${loadedWindow}Y public-sleeve proxy window',
                )
        : loadedAll
        ? context.tr('恢复全部已审计历史', 'Reset to all audited history')
        : context.tr(
            '恢复完整 $loadedWindow 年审计区间',
            'Reset to the full audited ${loadedWindow}Y window',
          );
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final chartHeight = viewportHeight >= 1000
        ? 300.0
        : viewportHeight >= 820
        ? 200.0
        : 120.0;
    return Panel(
      palette: widget.palette,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          isRenaissance
              ? Tooltip(
                  message: context.ui(
                    text(
                      sim['description'],
                      'This is a delayed manager-level public 13F model, not the Medallion Fund portfolio.',
                    ),
                  ),
                  child: PanelTitle(
                    icon: Icons.stacked_line_chart_rounded,
                    kicker: context.tr(
                      '管理人级公开 13F · 非 MEDALLION',
                      'MANAGER-LEVEL PUBLIC 13F · NOT MEDALLION',
                    ),
                    title: isProxy
                        ? context.tr(
                            '公开持仓代理 vs SPY',
                            'Public sleeve proxy vs SPY',
                          )
                        : context.tr(
                            '模拟：组合与 SPY 对比',
                            'Simulation: Portfolio vs SPY',
                          ),
                    palette: widget.palette,
                    trailing: _RetryIconButton(
                      onPressed:
                          widget.loading || widget.requestedWindow != null
                          ? null
                          : widget.onRetry,
                      palette: widget.palette,
                    ),
                  ),
                )
              : PanelTitle(
                  icon: Icons.stacked_line_chart_rounded,
                  kicker: 'COPY SIMULATION',
                  title: isProxy
                      ? context.tr(
                          '公开持仓代理 vs SPY',
                          'Public sleeve proxy vs SPY',
                        )
                      : context.tr(
                          '模拟：组合与 SPY 对比',
                          'Simulation: Portfolio vs SPY',
                        ),
                  palette: widget.palette,
                  trailing: _RetryIconButton(
                    onPressed: widget.loading || widget.requestedWindow != null
                        ? null
                        : widget.onRetry,
                    palette: widget.palette,
                  ),
                ),
          const SizedBox(height: 14),
          if (widget.loading && widget.payload == null)
            const SizedBox(
              height: 300,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (widget.error != null && widget.payload == null)
            EmptyState(text: widget.error!, palette: widget.palette)
          else if (!_isDisplayableBacktest(widget.payload))
            _StrictReplicationUnavailableNotice(
              payload: widget.payload,
              palette: widget.palette,
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                VoidCallback? serverWindowAction(String window) {
                  final pending = widget.requestedWindow;
                  if (pending != null) {
                    if (pending == window || loadedWindow != window) {
                      return null;
                    }
                    return () => _selectServerWindow(equity, window);
                  }
                  if (widget.loading) {
                    return null;
                  }
                  return () => _selectServerWindow(equity, window);
                }

                final rangeControls = Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _RangePresetButton(
                      label: '1Y',
                      selected:
                          !isAll && trailingWindowSelected(equity, _range, 1),
                      palette: widget.palette,
                      onTap: widget.requestedWindow == null && !widget.loading
                          ? () => _selectTrailingWindow(equity, 1)
                          : null,
                    ),
                    _RangePresetButton(
                      label: '3Y',
                      selected:
                          !isAll && trailingWindowSelected(equity, _range, 3),
                      palette: widget.palette,
                      onTap: widget.requestedWindow == null && !widget.loading
                          ? () => _selectTrailingWindow(equity, 3)
                          : null,
                    ),
                    _RangePresetButton(
                      label: '5Y',
                      selected: loadedWindow == '5' && isAll,
                      palette: widget.palette,
                      onTap: serverWindowAction('5'),
                    ),
                    _RangePresetButton(
                      label: '10Y',
                      selected: loadedWindow == '10' && isAll,
                      palette: widget.palette,
                      onTap: serverWindowAction('10'),
                    ),
                    _RangePresetButton(
                      label: 'All',
                      selected: loadedAll && isAll,
                      palette: widget.palette,
                      onTap: serverWindowAction('all'),
                    ),
                    if (widget.requestedWindow != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 8,
                        ),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: widget.palette.accent,
                          ),
                        ),
                      ),
                  ],
                );
                final legend = Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    _PerformanceLegendItem(
                      label: isProxy
                          ? context.tr('公开持仓代理', 'Public sleeve proxy')
                          : isRenaissance
                          ? context.tr('文艺复兴 13F', 'Renaissance 13F')
                          : '${compactName(guruDisplayName(widget.guru, context.language))} Portfolio',
                      value: formatReturn(summary.totalReturn),
                      color: widget.palette.positive,
                      palette: widget.palette,
                    ),
                    _PerformanceLegendItem(
                      label: 'SPY',
                      value: formatReturn(summary.benchmarkReturn),
                      color: widget.palette.secondary,
                      palette: widget.palette,
                    ),
                    _PerformanceLegendItem(
                      label: 'Excess',
                      value: formatReturn(summary.excessReturn),
                      color: widget.palette.accent,
                      palette: widget.palette,
                    ),
                    _PerformanceLegendItem(
                      label: selectedRangeApproximate ? 'MDD≈' : 'MDD',
                      value: formatReturn(summary.maxDrawdown),
                      color: widget.palette.negative,
                      palette: widget.palette,
                    ),
                  ],
                );
                if (constraints.maxWidth < 640) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      rangeControls,
                      const SizedBox(height: 12),
                      legend,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    rangeControls,
                    const SizedBox(width: 16),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topRight,
                        child: legend,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            if (widget.windowError != null &&
                widget.windowError!.isNotEmpty) ...[
              Text(
                context.ui(widget.windowError!),
                style: TextStyle(
                  color: widget.palette.negative,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
            ],
            SimulationRangeBar(
              key: const ValueKey('guru-simulation-range-bar'),
              palette: widget.palette,
              range: currentRange,
              maxIndex: math.max(1, equity.length - 1).toDouble(),
              selectedStart: selectedStart,
              selectedEnd: selectedEnd,
              fullStart: allStart,
              fullEnd: allEnd,
              resetLabel: resetLabel,
              resetTooltip: resetTooltip,
              onChanged:
                  equity.length < 3 ||
                      widget.loading ||
                      widget.requestedWindow != null
                  ? null
                  : (value) {
                      final snapped = RangeValues(
                        value.start.roundToDouble(),
                        value.end.roundToDouble(),
                      );
                      if (snapped.end - snapped.start < 2) return;
                      setState(() => _rememberRange(equity, snapped));
                    },
              onReset: widget.requestedWindow == null && !widget.loading
                  ? () {
                      setState(
                        () => _rememberRange(
                          equity,
                          RangeValues(
                            0,
                            math.max(1, equity.length - 1).toDouble(),
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(height: 4),
            SizedBox(
              key: const ValueKey('guru-simulation-equity-chart'),
              height: chartHeight,
              child: EquityChart(equity: chartEquity, palette: widget.palette),
            ),
            if (isProxy) ...[
              const SizedBox(height: 8),
              _PublicHoldingsProxyNotice(
                payload: widget.payload,
                palette: widget.palette,
                noticeKey: const ValueKey('guru-simulation-proxy-notice'),
              ),
            ],
            const SizedBox(height: 10),
            if (warming) ...[
              Text(
                isProxy
                    ? context.tr(
                        '正在后台刷新公开持仓代理；先显示已缓存区间。',
                        'The public-sleeve proxy is refreshing; showing the cached window first.',
                      )
                    : loadedAll
                    ? context.tr(
                        '正在后台刷新全部可审计历史；先显示已缓存区间。',
                        'The full audited history is refreshing; showing the cached window first.',
                      )
                    : context.tr(
                        '正在后台刷新 $loadedWindow 年可审计历史；先显示已缓存区间。',
                        'The audited ${loadedWindow}Y history is refreshing; showing the cached window first.',
                      ),
                style: TextStyle(
                  color: widget.palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (samplingLabel.isNotEmpty) ...[
              Text(
                samplingLabel,
                style: TextStyle(
                  color: widget.palette.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
          LatestHoldingsList(guru: widget.guru, palette: widget.palette),
        ],
      ),
    );
  }
}

class _RangePresetButton extends StatelessWidget {
  const _RangePresetButton({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Palette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 46,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: .18)
              : palette.card,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: selected ? palette.accent : palette.border),
        ),
        child: Text(
          context.ui(label),
          style: TextStyle(
            color: selected
                ? palette.accent
                : onTap == null
                ? palette.faint
                : palette.muted,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _PerformanceLegendItem extends StatelessWidget {
  const _PerformanceLegendItem({
    required this.label,
    required this.value,
    required this.color,
    required this.palette,
  });

  final String label;
  final String value;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.ui(label),
              style: TextStyle(
                color: palette.muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class LatestHoldingsList extends StatefulWidget {
  const LatestHoldingsList({
    super.key,
    required this.guru,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final Palette palette;

  @override
  State<LatestHoldingsList> createState() => _LatestHoldingsListState();
}

class _LatestHoldingsListState extends State<LatestHoldingsList> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant LatestHoldingsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (text(oldWidget.guru['id']) != text(widget.guru['id'])) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = [...asList(widget.guru['holdings'])]
      ..sort(
        (left, right) =>
            number(right['value']).compareTo(number(left['value'])),
      );
    if (rows.isEmpty) return const SizedBox.shrink();

    final summary = asMap(widget.guru['summary']);
    final disclosedTotal = number(summary['totalValue']);
    final total = disclosedTotal > 0
        ? disclosedTotal
        : rows.fold<double>(0, (sum, row) => sum + number(row['value']));
    final reportDate = formatDate(text(summary['reportDate']));
    final visibleCount = _expanded ? rows.length : math.min(18, rows.length);
    final visibleRows = rows.take(visibleCount).toList();
    final totalPositions = math.max(
      rows.length,
      number(summary['totalPositions']).round(),
    );
    final truncated = totalPositions > rows.length;
    final headerActions = <Widget>[
      if (reportDate != '-')
        InfoChip(
          context.tr('报告期 $reportDate', 'Report $reportDate'),
          palette: widget.palette,
        ),
      InfoChip(
        truncated
            ? context.tr(
                '前 $visibleCount，共 $totalPositions',
                'Top $visibleCount of $totalPositions',
              )
            : '$visibleCount / ${rows.length}',
        palette: widget.palette,
      ),
      if (rows.length > 18)
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(
            _expanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
            size: 18,
          ),
          label: Text(
            _expanded
                ? context.tr('收起', 'Collapse')
                : truncated
                ? context.tr('显示前 ${rows.length}', 'Show top ${rows.length}')
                : context.tr('全部', 'All'),
          ),
          style: TextButton.styleFrom(
            foregroundColor: widget.palette.accent,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(58, 44),
          ),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Divider(height: 1, color: widget.palette.border),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final title = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_balance_wallet_rounded,
                  color: widget.palette.accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text(
                  context.tr('最新持仓', 'Latest holdings'),
                  style: TextStyle(
                    color: widget.palette.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            );
            final actions = Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: headerActions,
            );
            if (constraints.maxWidth < 900) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, const SizedBox(height: 10), actions],
              );
            }
            return Row(children: [title, const Spacer(), actions]);
          },
        ),
        const SizedBox(height: 14),
        if (truncated) ...[
          PortfolioDataNotice(
            icon: Icons.filter_alt_outlined,
            text: context.tr(
              '该季度共申报 $totalPositions 个普通股多头仓位；此处仅返回并展示按价值排序的前 ${rows.length} 个，较小仓位未包含。',
              'The filing reports $totalPositions common-long positions. This view returns only the top ${rows.length} by reported value; smaller positions are not included.',
            ),
            palette: widget.palette,
          ),
          const SizedBox(height: 14),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 760 || visibleRows.length < 8) {
              return Column(
                children: [
                  for (final holding in visibleRows)
                    HoldingRow(
                      holding: holding,
                      total: total,
                      palette: widget.palette,
                    ),
                ],
              );
            }
            final split = (visibleRows.length / 2).ceil();
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      for (final holding in visibleRows.take(split))
                        HoldingRow(
                          holding: holding,
                          total: total,
                          palette: widget.palette,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: Column(
                    children: [
                      for (final holding in visibleRows.skip(split))
                        HoldingRow(
                          holding: holding,
                          total: total,
                          palette: widget.palette,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class GuruPositionHistoryModule extends StatefulWidget {
  const GuruPositionHistoryModule({
    super.key,
    required this.guru,
    required this.payload,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onRetry,
  });

  final Map<String, dynamic> guru;
  final Map<String, dynamic>? payload;
  final bool loading;
  final String? error;
  final Palette palette;
  final VoidCallback? onRetry;

  @override
  State<GuruPositionHistoryModule> createState() =>
      _GuruPositionHistoryModuleState();
}

class _GuruPositionHistoryModuleState extends State<GuruPositionHistoryModule> {
  String _selectedReportDate = '';
  String _selectedHoldingId = '';

  @override
  void didUpdateWidget(covariant GuruPositionHistoryModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (text(oldWidget.guru['id']) != text(widget.guru['id'])) {
      _selectedReportDate = '';
      _selectedHoldingId = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = [...asList(widget.payload?['history'])]
      ..sort(
        (left, right) =>
            text(right['reportDate']).compareTo(text(left['reportDate'])),
      );
    final meta = asMap(widget.payload?['meta']);
    final cache = asMap(widget.payload?['cache']);
    final availableDates = {
      for (final quarter in history) text(quarter['reportDate']),
    };
    final selectedReportDate = availableDates.contains(_selectedReportDate)
        ? _selectedReportDate
        : history.isEmpty
        ? ''
        : text(history.first['reportDate']);
    final selectedQuarter = history.firstWhere(
      (quarter) => text(quarter['reportDate']) == selectedReportDate,
      orElse: () => const <String, dynamic>{},
    );
    final selectedHoldings = asList(selectedQuarter['topHoldings']);
    final holdingIds = <String>{
      for (final quarter in history)
        for (final holding in asList(quarter['topHoldings']))
          _positionHistoryHoldingId(holding),
    }..remove('');
    final selectedHoldingId = holdingIds.contains(_selectedHoldingId)
        ? _selectedHoldingId
        : selectedHoldings.isNotEmpty
        ? _positionHistoryHoldingId(selectedHoldings.first)
        : holdingIds.isEmpty
        ? ''
        : holdingIds.first;
    final observations = <_PositionHistoryObservation>[];
    if (selectedHoldingId.isNotEmpty) {
      for (final quarter in history) {
        final holding = asList(quarter['topHoldings']).firstWhere(
          (row) => _positionHistoryHoldingId(row) == selectedHoldingId,
          orElse: () => const <String, dynamic>{},
        );
        if (holding.isNotEmpty) {
          observations.add(
            _PositionHistoryObservation(quarter: quarter, holding: holding),
          );
        }
      }
    }
    final selectedHolding = observations.isEmpty
        ? const <String, dynamic>{}
        : observations.first.holding;
    final cacheStatus = text(cache['status']);
    final returnedQuarters = number(
      meta['returnedQuarters'],
    ).round().clamp(0, 40);
    final requestedQuarters = number(
      meta['requestedQuarters'],
    ).round().clamp(0, 40);

    return Panel(
      key: const ValueKey('guru-position-history-module'),
      palette: widget.palette,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.timeline_rounded,
            kicker: context.tr('申报仓位历史', 'REPORTED POSITION HISTORY'),
            title: context.tr(
              '${guruDisplayName(widget.guru, context.language)} 的仓位轨迹',
              '${guruDisplayName(widget.guru, context.language)} Position History',
            ),
            palette: widget.palette,
            trailing: _RetryIconButton(
              onPressed: widget.loading ? null : widget.onRetry,
              palette: widget.palette,
            ),
          ),
          const SizedBox(height: 12),
          if (widget.loading && widget.payload == null)
            const SizedBox(
              height: 260,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (widget.error != null && widget.payload == null)
            _PositionHistoryFailure(
              error: widget.error!,
              palette: widget.palette,
              onRetry: widget.onRetry,
            )
          else if (history.isEmpty)
            _PositionHistoryFailure(
              error: context.tr(
                '暂无可用的季度仓位历史。',
                'No quarterly position history is available yet.',
              ),
              palette: widget.palette,
              onRetry: widget.onRetry,
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                InfoChip(
                  context.tr(
                    '$returnedQuarters 个季度',
                    '$returnedQuarters quarters',
                  ),
                  palette: widget.palette,
                ),
                if (requestedQuarters > returnedQuarters)
                  InfoChip(
                    context.tr(
                      '请求 $requestedQuarters 个季度',
                      '$requestedQuarters requested',
                    ),
                    palette: widget.palette,
                  ),
                if (cacheStatus.isNotEmpty)
                  InfoChip(
                    context.tr('缓存 $cacheStatus', 'Cache $cacheStatus'),
                    palette: widget.palette,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              context.tr('选择季度', 'Select quarter'),
              style: TextStyle(
                color: widget.palette.muted,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final quarter in history) ...[
                    ChoiceChip(
                      key: ValueKey(
                        'guru-position-history-quarter-${text(quarter['reportDate'])}',
                      ),
                      label: Text(
                        text(
                          quarter['quarterLabel'],
                          reportQuarterLabel(text(quarter['reportDate'])),
                        ),
                      ),
                      selected:
                          text(quarter['reportDate']) == selectedReportDate,
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _selectedReportDate = text(quarter['reportDate']);
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _PositionHistoryMetrics(
              quarter: selectedQuarter,
              palette: widget.palette,
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final quarterPanel = _PositionHistoryQuarterHoldings(
                  quarter: selectedQuarter,
                  holdings: selectedHoldings,
                  selectedHoldingId: selectedHoldingId,
                  palette: widget.palette,
                  onSelect: (holding) => setState(
                    () =>
                        _selectedHoldingId = _positionHistoryHoldingId(holding),
                  ),
                );
                final stockPanel = _PositionHistoryStockTrajectory(
                  holding: selectedHolding,
                  observations: observations,
                  palette: widget.palette,
                );
                if (constraints.maxWidth < 760) {
                  return Column(
                    children: [
                      quarterPanel,
                      const SizedBox(height: 12),
                      stockPanel,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: quarterPanel),
                    const SizedBox(width: 14),
                    Expanded(child: stockPanel),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _PositionHistoryFailure extends StatelessWidget {
  const _PositionHistoryFailure({
    required this.error,
    required this.palette,
    required this.onRetry,
  });

  final String error;
  final Palette palette;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EmptyState(text: error, palette: palette),
        if (onRetry != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('guru-position-history-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(context.tr('重试', 'Retry')),
          ),
        ],
      ],
    );
  }
}

class _PositionHistoryMetrics extends StatelessWidget {
  const _PositionHistoryMetrics({required this.quarter, required this.palette});

  final Map<String, dynamic> quarter;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      (
        context.tr('申报的 13F 信息表价值', 'Reported 13F value'),
        nullableNumber(quarter['reported13fValue']) == null
            ? '—'
            : formatMoney(number(quarter['reported13fValue'])),
        Icons.account_balance_wallet_outlined,
      ),
      (
        context.tr('申报仓位', 'Positions'),
        formatNumber(number(quarter['positionCount'])),
        Icons.view_list_rounded,
      ),
      (
        context.tr('前十大集中度', 'Top-10 weight'),
        formatReturn(number(quarter['top10Weight'])).replaceFirst('+', ''),
        Icons.donut_large_rounded,
      ),
      (
        context.tr('仓位变化代理', 'Turnover proxy'),
        formatReturn(number(quarter['turnoverProxy'])).replaceFirst('+', ''),
        Icons.swap_horiz_rounded,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 2 : 4;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final metric in metrics)
              SizedBox(
                width: width,
                child: MiniMetric(metric.$1, metric.$2, metric.$3, palette),
              ),
          ],
        );
      },
    );
  }
}

class _PositionHistoryQuarterHoldings extends StatelessWidget {
  const _PositionHistoryQuarterHoldings({
    required this.quarter,
    required this.holdings,
    required this.selectedHoldingId,
    required this.palette,
    required this.onSelect,
  });

  final Map<String, dynamic> quarter;
  final List<Map<String, dynamic>> holdings;
  final String selectedHoldingId;
  final Palette palette;
  final ValueChanged<Map<String, dynamic>> onSelect;

  @override
  Widget build(BuildContext context) {
    final quarterLabel = text(
      quarter['quarterLabel'],
      reportQuarterLabel(text(quarter['reportDate'])),
    );
    return _PositionHistorySection(
      title: context.tr('$quarterLabel 前十大仓位', '$quarterLabel Top holdings'),
      subtitle: context.tr(
        '按普通股多头申报价值排序；点击股票查看轨迹',
        'Ranked by reported common-long value; select a stock for its trajectory',
      ),
      palette: palette,
      child: holdings.isEmpty
          ? EmptyState(
              text: context.tr(
                '本季度没有可展示的前十大仓位。',
                'No Top-10 holdings are available for this quarter.',
              ),
              palette: palette,
            )
          : Column(
              children: [
                for (final holding in holdings)
                  _PositionHistoryHoldingRow(
                    holding: holding,
                    selected:
                        _positionHistoryHoldingId(holding) == selectedHoldingId,
                    palette: palette,
                    onTap: () => onSelect(holding),
                  ),
              ],
            ),
    );
  }
}

class _PositionHistoryHoldingRow extends StatelessWidget {
  const _PositionHistoryHoldingRow({
    required this.holding,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> holding;
  final bool selected;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ticker = _positionHistoryHoldingLabel(holding);
    final weight = number(holding['pctPortfolio']).clamp(0.0, 1.0).toDouble();
    final publicTrading = marketLensPublicTradingMetadata([holding]);
    final publiclyTradable = truthy(publicTrading['publicReplicable']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        key: ValueKey('guru-position-history-holding-$ticker'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected
                ? palette.accent.withValues(alpha: .12)
                : palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? palette.accent : palette.border,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 115,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StockResearchButton(
                      ticker: text(holding['ticker'], ticker),
                      palette: palette,
                      available: publiclyTradable,
                      sourceDate: text(holding['reportDate']),
                    ),
                    if (!publiclyTradable)
                      Text(
                        context.tr('已私有化', 'Private'),
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: weight,
                    minHeight: 7,
                    backgroundColor: palette.border,
                    color: palette.accent,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 64,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatMoney(number(holding['value'])),
                      maxLines: 1,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      formatReturn(weight).replaceFirst('+', ''),
                      style: TextStyle(color: palette.muted, fontSize: 11),
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
}

class _PositionHistoryStockTrajectory extends StatelessWidget {
  const _PositionHistoryStockTrajectory({
    required this.holding,
    required this.observations,
    required this.palette,
  });

  final Map<String, dynamic> holding;
  final List<_PositionHistoryObservation> observations;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final label = _positionHistoryHoldingLabel(holding);
    final publicTrading = marketLensPublicTradingMetadata([holding]);
    final publiclyTradable = truthy(publicTrading['publicReplicable']);
    final publicTradingReason = context.language == AppLanguage.zh
        ? text(publicTrading['reasonZh'], text(publicTrading['reasonEn']))
        : text(publicTrading['reasonEn'], text(publicTrading['reasonZh']));
    final maxWeight = observations.fold<double>(
      0,
      (current, observation) =>
          math.max(current, number(observation.holding['pctPortfolio'])),
    );
    return _PositionHistorySection(
      title: label.isEmpty
          ? context.tr('股票轨迹', 'Stock trajectory')
          : context.tr('$label 仓位轨迹', '$label position trajectory'),
      subtitle: context.tr(
        '季度末前十大快照中的申报仓位',
        'Reported quarter-end position when present in the Top 10 snapshot',
      ),
      palette: palette,
      child: observations.isEmpty
          ? EmptyState(
              text: context.tr(
                '选择一个股票查看历史轨迹。',
                'Select a stock to inspect its history.',
              ),
              palette: palette,
            )
          : Column(
              children: [
                if (!publiclyTradable) ...[
                  PortfolioDataNotice(
                    icon: Icons.lock_outline_rounded,
                    text: text(
                      publicTradingReason,
                      context.tr(
                        '该历史申报证券现已私有化；保留仓位证据，但不提供公开市场估值或复制交易。',
                        'This historically reported security is now private. The position evidence remains visible, but public valuation and copy execution are unavailable.',
                      ),
                    ),
                    palette: palette,
                  ),
                  const SizedBox(height: 10),
                ],
                for (final observation in observations)
                  _PositionHistoryObservationRow(
                    observation: observation,
                    maxWeight: maxWeight,
                    palette: palette,
                  ),
                const SizedBox(height: 4),
                PortfolioDataNotice(
                  icon: Icons.info_outline_rounded,
                  text: context.tr(
                    '轨迹仅覆盖每季度前十大申报仓位；某季度未出现不代表已经清仓。13F 为滞后披露，不是实时交易记录。',
                    'This trajectory covers only each quarter\'s reported Top 10. Absence does not prove an exit. 13F filings are delayed disclosures, not live trade records.',
                  ),
                  palette: palette,
                ),
              ],
            ),
    );
  }
}

class _PositionHistoryObservationRow extends StatelessWidget {
  const _PositionHistoryObservationRow({
    required this.observation,
    required this.maxWeight,
    required this.palette,
  });

  final _PositionHistoryObservation observation;
  final double maxWeight;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final quarter = observation.quarter;
    final holding = observation.holding;
    final weight = number(holding['pctPortfolio']);
    final relative = maxWeight <= 0
        ? 0.0
        : (weight / maxWeight).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              text(
                quarter['quarterLabel'],
                reportQuarterLabel(text(quarter['reportDate'])),
              ),
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: relative,
                minHeight: 8,
                backgroundColor: palette.border,
                color: palette.secondary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(
              formatReturn(weight).replaceFirst('+', ''),
              textAlign: TextAlign.end,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              formatMoney(number(holding['value'])),
              textAlign: TextAlign.end,
              maxLines: 1,
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _PositionHistorySection extends StatelessWidget {
  const _PositionHistorySection({
    required this.title,
    required this.subtitle,
    required this.palette,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Palette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: palette.muted, fontSize: 11, height: 1.3),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _PositionHistoryObservation {
  const _PositionHistoryObservation({
    required this.quarter,
    required this.holding,
  });

  final Map<String, dynamic> quarter;
  final Map<String, dynamic> holding;
}

String _positionHistoryHoldingId(Map<String, dynamic> holding) => text(
  holding['ticker'],
  text(holding['cusip'], text(holding['issuer'])),
).toUpperCase();

String _positionHistoryHoldingLabel(Map<String, dynamic> holding) =>
    text(holding['ticker'], text(holding['issuer'], text(holding['cusip'])));

class SimulationRangeBar extends StatelessWidget {
  const SimulationRangeBar({
    super.key,
    required this.palette,
    required this.range,
    required this.maxIndex,
    required this.selectedStart,
    required this.selectedEnd,
    required this.fullStart,
    required this.fullEnd,
    required this.resetLabel,
    required this.resetTooltip,
    required this.onChanged,
    required this.onReset,
  });

  final Palette palette;
  final RangeValues range;
  final double maxIndex;
  final String selectedStart;
  final String selectedEnd;
  final String fullStart;
  final String fullEnd;
  final String resetLabel;
  final String resetTooltip;
  final ValueChanged<RangeValues>? onChanged;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.border,
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: .14),
        rangeThumbShape: const RoundRangeSliderThumbShape(
          enabledThumbRadius: 7,
        ),
        rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
        trackHeight: 5,
      ),
      child: RangeSlider(
        min: 0,
        max: maxIndex,
        divisions: math.min(maxIndex.round(), 520),
        values: RangeValues(
          range.start.clamp(0, maxIndex),
          range.end.clamp(0, maxIndex),
        ),
        onChanged: onChanged,
      ),
    );
    final reset = Tooltip(
      message: resetTooltip,
      child: TextButton.icon(
        onPressed: onReset,
        icon: const Icon(Icons.keyboard_double_arrow_left_rounded, size: 16),
        label: Text(resetLabel),
        style: TextButton.styleFrom(
          foregroundColor: palette.accent,
          minimumSize: const Size(72, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
    final decoration = BoxDecoration(
      color: palette.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: palette.border),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: decoration,
            child: Row(
              children: [
                Icon(Icons.date_range_rounded, color: palette.accent, size: 17),
                const SizedBox(width: 7),
                SizedBox(
                  width: 156,
                  child: Tooltip(
                    message: '$fullStart - $fullEnd',
                    child: Text(
                      '$selectedStart - $selectedEnd',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: slider),
                const SizedBox(width: 4),
                reset,
              ],
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
          decoration: decoration,
          child: Column(
            children: [
              Row(
                children: [
                  Icon(
                    Icons.date_range_rounded,
                    color: palette.accent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$selectedStart - $selectedEnd',
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  reset,
                ],
              ),
              slider,
              Row(
                children: [
                  Text(
                    fullStart,
                    style: TextStyle(
                      color: palette.faint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    fullEnd,
                    style: TextStyle(
                      color: palette.faint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class SimulationMetrics {
  const SimulationMetrics({
    required this.totalReturn,
    required this.benchmarkReturn,
    required this.excessReturn,
    required this.maxDrawdown,
  });

  final double totalReturn;
  final double benchmarkReturn;
  final double excessReturn;
  final double maxDrawdown;
}

List<Map<String, dynamic>> rebaseEquity(List<Map<String, dynamic>> equity) {
  if (equity.length < 2) return equity;
  final baseValue = number(equity.first['value']);
  final baseBenchmark = number(equity.first['benchmark']);
  if (baseValue <= 0 || baseBenchmark <= 0) return equity;
  return equity
      .map(
        (point) => {
          ...point,
          'value': number(point['value']) / baseValue,
          'benchmark': number(point['benchmark']) / baseBenchmark,
        },
      )
      .toList();
}

SimulationMetrics simulationMetrics(List<Map<String, dynamic>> equity) {
  if (equity.length < 2) {
    return const SimulationMetrics(
      totalReturn: 0,
      benchmarkReturn: 0,
      excessReturn: 0,
      maxDrawdown: 0,
    );
  }
  final first = equity.first;
  final last = equity.last;
  final startValue = number(first['value']);
  final endValue = number(last['value']);
  final startBenchmark = number(first['benchmark']);
  final endBenchmark = number(last['benchmark']);
  final totalReturn = startValue > 0 ? endValue / startValue - 1 : 0.0;
  final benchmarkReturn = startBenchmark > 0
      ? endBenchmark / startBenchmark - 1
      : 0.0;
  var peak = startValue;
  var drawdown = 0.0;
  for (final point in equity) {
    final value = number(point['value']);
    peak = math.max(peak, value);
    if (peak > 0) drawdown = math.min(drawdown, value / peak - 1);
  }
  return SimulationMetrics(
    totalReturn: totalReturn,
    benchmarkReturn: benchmarkReturn,
    excessReturn: totalReturn - benchmarkReturn,
    maxDrawdown: drawdown,
  );
}

class GuruTradeModule extends StatefulWidget {
  const GuruTradeModule({
    super.key,
    required this.guru,
    required this.selectedTicker,
    required this.selectedTrade,
    required this.contextPayload,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onSelect,
    required this.onRetry,
  });

  final Map<String, dynamic> guru;
  final String selectedTicker;
  final Map<String, dynamic> selectedTrade;
  final Map<String, dynamic>? contextPayload;
  final bool loading;
  final String? error;
  final Palette palette;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final VoidCallback? onRetry;

  @override
  State<GuruTradeModule> createState() => _GuruTradeModuleState();
}

class _GuruTradeModuleState extends State<GuruTradeModule> {
  String _tickerQuery = '';
  final TextEditingController _tickerController = TextEditingController();

  @override
  void didUpdateWidget(covariant GuruTradeModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (text(oldWidget.guru['id']) != text(widget.guru['id'])) {
      _tickerQuery = '';
      _tickerController.clear();
    }
  }

  @override
  void dispose() {
    _tickerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = text(widget.guru['type']);
    final reported13f = type == 'manager13f';
    final tradeWorkspace = type == 'manager13f' || type == 'congress';
    final rows = guruTradeRows(widget.guru);
    final query = _tickerQuery.trim().toLowerCase();
    final filteredRows = query.isEmpty
        ? rows
        : rows.where((row) {
            final ticker = text(row['ticker']).toLowerCase();
            final issuer = text(row['issuer']).toLowerCase();
            final action =
                (reported13f
                        ? reported13fActionLabel(
                            text(row['action']),
                            context.language,
                          )
                        : actionLabel(text(row['action']), context.language))
                    .toLowerCase();
            return ticker.contains(query) ||
                issuer.contains(query) ||
                action.contains(query);
          }).toList();
    final selected = filteredRows.firstWhere(
      (row) => text(row['ticker']) == widget.selectedTicker,
      orElse: () =>
          filteredRows.isNotEmpty ? filteredRows.first : <String, dynamic>{},
    );
    final summary = asMap(widget.guru['summary']);
    final market = asMap(widget.contextPayload?['market']);
    final selectedMarket = asMap(market['selected']);
    final points = selected.isEmpty
        ? <Map<String, dynamic>>[]
        : asList(selectedMarket['points']);
    final chartOperation = {
      ...selected,
      'date': text(
        selected['date'],
        text(selected['transactionDate'], text(summary['reportDate'])),
      ),
      'filingDate': text(
        selected['filingDate'],
        text(selected['reportDate'], text(summary['filingDate'])),
      ),
    };

    Widget buildList() {
      if (rows.isEmpty) {
        return EmptyState(
          text: tradeWorkspace
              ? 'No buy/sell rows available.'
              : 'No disclosure rows available.',
          palette: widget.palette,
        );
      }
      if (filteredRows.isEmpty) {
        return EmptyState(
          text: 'No ticker matched "$_tickerQuery".',
          palette: widget.palette,
        );
      }
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: filteredRows.length,
        separatorBuilder: (context, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final row = filteredRows[index];
          return GuruTradeRowButton(
            row: row,
            reported13f: reported13f,
            active: text(row['ticker']) == widget.selectedTicker,
            palette: widget.palette,
            onTap: () => widget.onSelect(row),
          );
        },
      );
    }

    Widget buildSearch() {
      return TextField(
        controller: _tickerController,
        onChanged: (value) => setState(() => _tickerQuery = value),
        decoration: InputDecoration(
          hintText: context.ui('Search ticker / company'),
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _tickerQuery.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _tickerController.clear();
                    setState(() => _tickerQuery = '');
                  },
                  icon: const Icon(Icons.close_rounded),
                  tooltip: context.ui('Clear'),
                ),
          filled: true,
          fillColor: widget.palette.card,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: widget.palette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: widget.palette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: widget.palette.accent.withValues(alpha: .65),
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 13,
          ),
        ),
      );
    }

    Widget buildChart() {
      if (widget.loading && widget.contextPayload == null) {
        return const SizedBox(
          height: 320,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      if (widget.error != null && widget.contextPayload == null) {
        return EmptyState(text: widget.error!, palette: widget.palette);
      }
      if (points.length < 2) {
        return EmptyState(
          text: 'No price chart available for ${widget.selectedTicker}.',
          palette: widget.palette,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BadgeLabel(
                text: text(chartOperation['ticker']),
                color: tradeToneColor(
                  text(chartOperation['action']),
                  widget.palette,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  compactName(text(chartOperation['issuer'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                reported13f
                    ? reported13fActionLabel(
                        text(chartOperation['action']),
                        context.language,
                      )
                    : actionLabel(
                        text(chartOperation['action']),
                        context.language,
                      ),
                style: TextStyle(
                  color: tradeToneColor(
                    text(chartOperation['action']),
                    widget.palette,
                  ),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 310,
            child: PriceActionChart(
              points: points,
              operation: chartOperation,
              palette: widget.palette,
              language: context.language,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InfoChip(
                formatMoney(tradeDisplayAmount(chartOperation)),
                palette: widget.palette,
              ),
              InfoChip(
                '${formatSignedNumber(tradeShareChange(chartOperation))} shares',
                palette: widget.palette,
              ),
              InfoChip(
                'Report ${formatDate(text(chartOperation['date']))}',
                palette: widget.palette,
              ),
              InfoChip(
                'Filed ${formatDate(text(chartOperation['filingDate']))}',
                palette: widget.palette,
              ),
            ],
          ),
        ],
      );
    }

    return Panel(
      palette: widget.palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.swap_vert_rounded,
            kicker: tradeWorkspace
                ? (reported13f ? 'REPORTED POSITION CHANGES' : 'NEW / EXIT')
                : disclosureLabel(type, context.language).toUpperCase(),
            title: tradeWorkspace
                ? (reported13f
                      ? context.tr(
                          '申报的新建仓 / 增持 / 减持',
                          'Reported New Positions / Increases / Reductions',
                        )
                      : context.tr('新买入 / 卖出股票', 'New Buys / Sells'))
                : context.tr('披露轨迹 / 股价走势', 'Disclosure Trail / Price Chart'),
            palette: widget.palette,
            trailing: _RetryIconButton(
              onPressed: widget.onRetry,
              palette: widget.palette,
            ),
          ),
          if (reported13f) ...[
            const SizedBox(height: 12),
            Tooltip(
              message: context.tr(
                '未进行 corporate-action 和 PIT security-master 验证；不能将 13F 股数变化视为已确认成交。',
                'Corporate-action and PIT security-master validation has not been performed; 13F share deltas are not confirmed executions.',
              ),
              child: PortfolioDataNotice(
                icon: Icons.info_outline_rounded,
                text: context.tr(
                  '这些是相邻 13F 信息表的申报持仓变化，不是成交确认。股数差异尚未做公司行为与时点证券主数据校验。',
                  'These are reported position changes between adjacent 13F information tables, not confirmed trades. Share deltas are not yet validated for corporate actions or a point-in-time security master.',
                ),
                palette: widget.palette,
              ),
            ),
          ],
          if (type == 'insider') ...[
            const SizedBox(height: 16),
            InsiderOwnershipSummary(guru: widget.guru, palette: widget.palette),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    buildSearch(),
                    const SizedBox(height: 12),
                    SizedBox(height: 360, child: buildList()),
                    const SizedBox(height: 18),
                    buildChart(),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 360,
                    child: Column(
                      children: [
                        buildSearch(),
                        const SizedBox(height: 12),
                        SizedBox(height: 560, child: buildList()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(child: buildChart()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class InsiderOwnershipSummary extends StatelessWidget {
  const InsiderOwnershipSummary({
    super.key,
    required this.guru,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(guru['summary']);
    final positions = asList(guru['insiderPositions']);
    if (positions.isEmpty) return const SizedBox.shrink();
    final windowStart = formatDate(text(summary['form4WindowStart']));
    final windowEnd = formatDate(text(summary['form4WindowEnd']));
    final windowLabel = windowStart == '-' && windowEnd == '-'
        ? '${formatNumber(number(summary['form4FilingsLoaded']))} filings'
        : '$windowStart - $windowEnd';
    final rows = positions.take(8).toList();
    final maxSold = rows
        .map((row) => number(asMap(row)['cumulativeSoldValue']))
        .fold<double>(0, math.max);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.account_balance_wallet_rounded,
                color: palette.accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr(
                        '高管持仓 / 累计卖出',
                        'Executive Holdings / Cumulative Sold',
                      ),
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.tr(
                        '按 Form 4 已加载窗口统计 · $windowLabel',
                        'Based on the loaded Form 4 window · $windowLabel',
                      ),
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridWrap(
            minTileWidth: 150,
            spacing: 10,
            children: [
              MiniMetric(
                'Tracked stocks',
                formatNumber(number(summary['trackedTickers'])),
                Icons.dataset_rounded,
                palette,
              ),
              MiniMetric(
                'Held shares',
                formatNumber(number(summary['totalLatestSharesOwned'])),
                Icons.pie_chart_rounded,
                palette,
              ),
              MiniMetric(
                'Cumulative sold',
                formatMoney(number(summary['cumulativeSoldValue'])),
                Icons.trending_down_rounded,
                palette,
              ),
              MiniMetric(
                'Sold shares',
                formatNumber(number(summary['cumulativeSoldShares'])),
                Icons.remove_circle_outline_rounded,
                palette,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: [
              for (final raw in rows)
                InsiderPositionRow(
                  row: asMap(raw),
                  maxSold: maxSold,
                  palette: palette,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class InsiderPositionRow extends StatelessWidget {
  const InsiderPositionRow({
    super.key,
    required this.row,
    required this.maxSold,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final double maxSold;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final ticker = text(row['ticker']);
    final issuer = compactName(text(row['issuer']));
    final heldShares = number(row['latestSharesOwned']);
    final soldValue = number(row['cumulativeSoldValue']);
    final soldShares = number(row['cumulativeSoldShares']);
    final boughtShares = number(row['cumulativeBoughtShares']);
    final latestDate = formatDate(
      text(row['latestSharesDate'], text(row['lastTransactionDate'])),
    );
    final progress = maxSold <= 0
        ? 0.0
        : math.max(.04, soldValue / maxSold).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ticker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  latestDate,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.faint, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issuer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: palette.border,
                    color: soldValue > 0 ? palette.negative : palette.accent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 112,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  context.tr(
                    '${formatNumber(heldShares)} 股',
                    '${formatNumber(heldShares)} sh',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.tr(
                    '累计卖出 ${formatMoney(soldValue)}',
                    'sold ${formatMoney(soldValue)}',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.negative, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(
              context.tr(
                '卖出 ${formatNumber(soldShares)} 股 · 买入 ${formatNumber(boughtShares)} 股',
                '${formatNumber(soldShares)} sold · ${formatNumber(boughtShares)} bought',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(color: palette.faint, fontSize: 11, height: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}

class GuruTradeRowButton extends StatelessWidget {
  const GuruTradeRowButton({
    super.key,
    required this.row,
    required this.reported13f,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final bool reported13f;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final action = text(row['action']);
    final tone = tradeToneColor(action, palette);
    final amount = tradeDisplayAmount(row);
    final detail = amount > 0
        ? formatMoney(amount)
        : text(
            row['amountRange'],
            '${formatNumber(tradeShareChange(row).abs())} shares',
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: active ? tone.withValues(alpha: .13) : palette.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? tone.withValues(alpha: .48) : palette.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 5,
                height: 42,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StockResearchButton(
                      ticker: text(
                        row['ticker'],
                        compactName(text(row['issuer'])),
                      ),
                      palette: palette,
                      sourceDate: text(row['reportDate']),
                      available: truthy(
                        marketLensPublicTradingMetadata([
                          row,
                        ])['publicReplicable'],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      compactName(
                        text(
                          row['issuer'],
                          actionLabel(action, context.language),
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    reported13f
                        ? reported13fActionLabel(action, context.language)
                        : actionLabel(action, context.language),
                    style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: TextStyle(color: palette.faint, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PriceActionChart extends StatefulWidget {
  const PriceActionChart({
    super.key,
    required this.points,
    required this.operation,
    required this.palette,
    required this.language,
  });

  final List<Map<String, dynamic>> points;
  final Map<String, dynamic> operation;
  final Palette palette;
  final AppLanguage language;

  @override
  State<PriceActionChart> createState() => _PriceActionChartState();
}

class _PriceActionChartState extends State<PriceActionChart> {
  int? _hoverIndex;

  void _updateHover(Offset position, double width) {
    if (widget.points.length < 2 || width <= 0) return;
    final left = PriceActionPainter.horizontalInset;
    final right = math.max(
      left + 1,
      width - PriceActionPainter.horizontalInset,
    );
    final ratio = ((position.dx - left) / (right - left)).clamp(0.0, 1.0);
    final next = (ratio * (widget.points.length - 1)).round();
    if (next == _hoverIndex) return;
    setState(() => _hoverIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Semantics(
          image: true,
          label: trFor(
            widget.language,
            '股价行为图，共 ${widget.points.length} 个数据点，可触摸探查。',
            'Price action chart with ${widget.points.length} points; touch to inspect.',
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (event) =>
                _updateHover(event.localPosition, constraints.maxWidth),
            onExit: (_) {
              if (_hoverIndex != null) setState(() => _hoverIndex = null);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _updateHover(details.localPosition, constraints.maxWidth),
              onPanDown: (details) =>
                  _updateHover(details.localPosition, constraints.maxWidth),
              onPanUpdate: (details) =>
                  _updateHover(details.localPosition, constraints.maxWidth),
              child: CustomPaint(
                painter: PriceActionPainter(
                  points: widget.points,
                  operation: widget.operation,
                  palette: widget.palette,
                  language: widget.language,
                  hoverIndex: _hoverIndex,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

class PriceActionPainter extends CustomPainter {
  PriceActionPainter({
    required this.points,
    required this.operation,
    required this.palette,
    required this.language,
    required this.hoverIndex,
  });

  static const horizontalInset = 8.0;
  static const topInset = 14.0;
  static const bottomInset = 24.0;

  final List<Map<String, dynamic>> points;
  final Map<String, dynamic> operation;
  final Palette palette;
  final AppLanguage language;
  final int? hoverIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final left = horizontalInset;
    final right = size.width - horizontalInset;
    final top = topInset;
    final bottom = size.height - bottomInset;
    final closes = points
        .map((point) => number(point['close']))
        .where((value) => value > 0)
        .toList();
    if (closes.length < 2) return;
    final minValue = closes.reduce(math.min);
    final maxValue = closes.reduce(math.max);
    final span = math.max(.0001, maxValue - minValue);
    final tone = tradeToneColor(text(operation['action']), palette);

    double xForIndex(int index) =>
        left + (right - left) * index / math.max(1, points.length - 1);

    int indexForDate(String date) {
      if (date.isEmpty) return 0;
      for (var i = 0; i < points.length; i += 1) {
        if (text(points[i]['date']).compareTo(date) >= 0) return i;
      }
      return points.length - 1;
    }

    double yForClose(double close) =>
        bottom - ((close - minValue) / span) * (bottom - top);

    final rangeStart = text(operation['date']);
    final rangeEnd = text(operation['filingDate'], rangeStart);
    final startX = xForIndex(indexForDate(rangeStart));
    final endX = xForIndex(indexForDate(rangeEnd));
    final highlightLeft = math.min(startX, endX);
    final highlightRight = math.max(startX, endX);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          highlightLeft,
          top,
          math.max(highlightLeft + 8, highlightRight),
          bottom,
        ),
        const Radius.circular(8),
      ),
      Paint()..color = tone.withValues(alpha: .13),
    );

    final gridPaint = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i += 1) {
      final y = top + (bottom - top) * i / 3;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }

    final path = Path();
    var started = false;
    for (var i = 0; i < points.length; i += 1) {
      final close = number(points[i]['close']);
      if (close <= 0) continue;
      final x = xForIndex(i);
      final y = yForClose(close);
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    if (started) {
      canvas.drawPath(
        path,
        Paint()
          ..color = palette.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final markerPaint = Paint()
      ..color = tone
      ..strokeWidth = 2;
    canvas.drawLine(Offset(endX, top), Offset(endX, bottom), markerPaint);
    final markerIndex = indexForDate(rangeEnd);
    final markerClose = number(points[markerIndex]['close']);
    if (markerClose > 0) {
      canvas.drawCircle(
        Offset(endX, yForClose(markerClose)),
        5,
        Paint()..color = tone,
      );
    }

    final labelStyle = TextStyle(
      color: palette.faint,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    _drawText(
      canvas,
      formatDate(text(points.first['date'])),
      Offset(left, bottom + 8),
      labelStyle,
    );
    _drawText(
      canvas,
      formatDate(text(points.last['date'])),
      Offset(right - 78, bottom + 8),
      labelStyle,
    );
    _drawText(
      canvas,
      '${actionLabel(text(operation['action']), language)}${trFor(language, '区间', ' window')}',
      Offset(highlightLeft + 6, top + 7),
      labelStyle.copyWith(color: tone),
    );

    final selectedIndex = hoverIndex;
    if (selectedIndex != null &&
        selectedIndex >= 0 &&
        selectedIndex < points.length) {
      final point = points[selectedIndex];
      final close = number(point['close']);
      if (close > 0) {
        final x = xForIndex(selectedIndex);
        final y = yForClose(close);
        _drawHover(canvas, size, top, bottom, Offset(x, y), point, tone);
      }
    }
  }

  void _drawHover(
    Canvas canvas,
    Size size,
    double top,
    double bottom,
    Offset offset,
    Map<String, dynamic> point,
    Color tone,
  ) {
    canvas.drawLine(
      Offset(offset.dx, top),
      Offset(offset.dx, bottom),
      Paint()
        ..color = palette.muted.withValues(alpha: .34)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      offset,
      7,
      Paint()..color = palette.accent.withValues(alpha: .16),
    );
    canvas.drawCircle(offset, 4.5, Paint()..color = palette.accent);
    canvas.drawCircle(
      offset,
      4.5,
      Paint()
        ..color = palette.panel
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    const tooltipWidth = 178.0;
    const tooltipHeight = 78.0;
    var tooltipLeft = offset.dx + 14;
    if (tooltipLeft + tooltipWidth > size.width - 6) {
      tooltipLeft = offset.dx - tooltipWidth - 14;
    }
    final maxLeft = math.max(6.0, size.width - tooltipWidth - 6);
    tooltipLeft = tooltipLeft.clamp(6.0, maxLeft).toDouble();
    var tooltipTop = offset.dy - tooltipHeight / 2;
    final maxTop = math.max(6.0, size.height - tooltipHeight - 6);
    tooltipTop = tooltipTop.clamp(6.0, maxTop).toDouble();

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tooltipLeft, tooltipTop, tooltipWidth, tooltipHeight),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = palette.card.withValues(alpha: .96),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = palette.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final date = formatDate(text(point['date']));
    final close = formatCurrencyValue(number(point['close']), 'USD');
    _drawText(
      canvas,
      date,
      Offset(tooltipLeft + 12, tooltipTop + 10),
      TextStyle(color: palette.text, fontSize: 12, fontWeight: FontWeight.w900),
      maxWidth: tooltipWidth - 24,
    );
    _drawTooltipText(
      canvas,
      tooltipLeft,
      tooltipTop + 34,
      'Close',
      close,
      palette.text,
    );
    _drawTooltipText(
      canvas,
      tooltipLeft,
      tooltipTop + 55,
      'Action',
      actionLabel(text(operation['action']), language),
      tone,
    );
  }

  void _drawTooltipText(
    Canvas canvas,
    double left,
    double top,
    String label,
    String value,
    Color valueColor,
  ) {
    _drawText(
      canvas,
      label,
      Offset(left + 12, top),
      TextStyle(
        color: palette.muted,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
      maxWidth: 68,
    );
    _drawText(
      canvas,
      value,
      Offset(left + 84, top),
      TextStyle(color: valueColor, fontSize: 11, fontWeight: FontWeight.w900),
      maxWidth: 82,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    double maxWidth = 92,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant PriceActionPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.operation != operation ||
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.palette.colorBlind != palette.colorBlind;
}

class GuruQuarterContributionModule extends StatelessWidget {
  const GuruQuarterContributionModule({
    super.key,
    required this.payload,
    required this.loading,
    required this.error,
    required this.selectedQuarterId,
    required this.onSelectQuarter,
    required this.palette,
    required this.onRetry,
  });

  final Map<String, dynamic>? payload;
  final bool loading;
  final String? error;
  final String selectedQuarterId;
  final ValueChanged<String> onSelectQuarter;
  final Palette palette;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final quarters = asList(payload?['quarterContributions']);
    final hasFullAttribution =
        text(asMap(payload?['detail'])['attribution']) == 'full';
    final selected = quarters.firstWhere(
      (quarter) => text(quarter['id']) == selectedQuarterId,
      orElse: () => quarters.isNotEmpty ? quarters.last : <String, dynamic>{},
    );
    final selectedId = text(selected['id']);
    final contributions = asList(selected['contributions']).toList()
      ..sort(
        (left, right) => number(
          right['contributionPct'],
        ).compareTo(number(left['contributionPct'])),
      );
    final maxAbsContribution = contributions.fold<double>(
      0,
      (maxValue, row) =>
          math.max(maxValue, number(row['contributionPct']).abs()),
    );

    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.calendar_month_rounded,
            kicker: 'QUARTERLY ATTRIBUTION',
            title: context.tr('季度贡献', 'Quarterly Contribution'),
            palette: palette,
            trailing: _RetryIconButton(onPressed: onRetry, palette: palette),
          ),
          const SizedBox(height: 16),
          if (_isProxyReadyBacktest(payload)) ...[
            _PublicHoldingsProxyNotice(
              payload: payload,
              palette: palette,
              noticeKey: const ValueKey('guru-quarterly-proxy-notice'),
            ),
            const SizedBox(height: 14),
          ],
          if (loading && (payload == null || !hasFullAttribution))
            const SizedBox(
              height: 300,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null && !hasFullAttribution)
            EmptyState(text: error!, palette: palette)
          else if (!_isDisplayableBacktest(payload) &&
              _backtestReplicability(payload).isNotEmpty)
            _StrictReplicationUnavailableNotice(
              payload: payload,
              palette: palette,
            )
          else if (quarters.isEmpty)
            EmptyState(
              text: 'No quarterly attribution available.',
              palette: palette,
            )
          else ...[
            QuarterTimelineSelector(
              quarters: quarters,
              selectedId: selectedId,
              palette: palette,
              onSelectQuarter: onSelectQuarter,
            ),
            const SizedBox(height: 14),
            GridWrap(
              minTileWidth: 140,
              spacing: 10,
              children: [
                MiniMetric(
                  'Portfolio',
                  formatReturn(number(selected['portfolioReturn'])),
                  Icons.account_balance_wallet_rounded,
                  palette,
                ),
                MiniMetric(
                  'SPY',
                  formatReturn(number(selected['benchmarkReturn'])),
                  Icons.show_chart_rounded,
                  palette,
                ),
                MiniMetric(
                  'Coverage',
                  formatReturn(number(selected['coveragePct'])),
                  Icons.pie_chart_rounded,
                  palette,
                ),
                MiniMetric(
                  'Positions',
                  formatNumber(number(selected['selectedPositions'])),
                  Icons.view_list_rounded,
                  palette,
                ),
              ],
            ),
            const SizedBox(height: 18),
            for (final row in contributions)
              QuarterContributionRow(
                row: row,
                maxAbsContribution: maxAbsContribution,
                palette: palette,
              ),
          ],
        ],
      ),
    );
  }
}

class QuarterTimelineSelector extends StatelessWidget {
  const QuarterTimelineSelector({
    super.key,
    required this.quarters,
    required this.selectedId,
    required this.palette,
    required this.onSelectQuarter,
  });

  final List<Map<String, dynamic>> quarters;
  final String selectedId;
  final Palette palette;
  final ValueChanged<String> onSelectQuarter;

  @override
  Widget build(BuildContext context) {
    final rows = quarters.reversed.toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timeline_rounded, color: palette.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                context.tr('历史季度', 'Historical Quarters'),
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                context.tr(
                  '${quarters.length} 个季度',
                  '${quarters.length} quarters',
                ),
                style: TextStyle(
                  color: palette.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final quarter in rows) ...[
                  QuarterTimelineChip(
                    quarter: quarter,
                    selected: text(quarter['id']) == selectedId,
                    palette: palette,
                    onTap: () => onSelectQuarter(text(quarter['id'])),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class QuarterTimelineChip extends StatelessWidget {
  const QuarterTimelineChip({
    super.key,
    required this.quarter,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> quarter;
  final bool selected;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final portfolioReturn = number(quarter['portfolioReturn']);
    final tone = portfolioReturn >= 0 ? palette.positive : palette.negative;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 116,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: .16)
              : palette.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? palette.accent.withValues(alpha: .6)
                : palette.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text(quarter['label']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? palette.accent : palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              formatDate(text(quarter['executionDate'])),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.faint,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              formatReturn(portfolioReturn),
              style: TextStyle(
                color: tone,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class QuarterContributionRow extends StatelessWidget {
  const QuarterContributionRow({
    super.key,
    required this.row,
    required this.maxAbsContribution,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final double maxAbsContribution;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final contribution = number(row['contributionPct']);
    final positive = contribution >= 0;
    final tone = positive ? palette.positive : palette.negative;
    final widthFactor = maxAbsContribution <= 0
        ? 0.0
        : (contribution.abs() / maxAbsContribution).clamp(.04, 1.0).toDouble();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StockResearchButton(
                ticker: text(row['ticker']),
                palette: palette,
                sourceDate: text(row['reportDate']),
                available: truthy(
                  marketLensPublicTradingMetadata([row])['publicReplicable'],
                ),
              ),
              const SizedBox(height: 3),
              Text(
                compactName(text(row['issuer'])),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ],
          );
          final bar = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 9,
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: widthFactor,
                    child: Container(
                      decoration: BoxDecoration(
                        color: tone,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _TinyStat(
                    'weight',
                    formatReturn(number(row['weight'])),
                    palette,
                  ),
                  _TinyStat(
                    'return',
                    formatReturn(number(row['returnPct'])),
                    palette,
                  ),
                  _TinyStat(
                    'contrib',
                    formatReturn(contribution),
                    palette,
                    color: tone,
                  ),
                ],
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 8), bar],
            );
          }
          return Row(
            children: [
              SizedBox(width: 180, child: title),
              const SizedBox(width: 14),
              Expanded(child: bar),
              const SizedBox(width: 14),
              SizedBox(
                width: 92,
                child: Text(
                  formatReturn(contribution),
                  textAlign: TextAlign.right,
                  style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TinyStat extends StatelessWidget {
  const _TinyStat(this.label, this.value, this.palette, {this.color});

  final String label;
  final String value;
  final Palette palette;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${context.ui(label)} $value',
      style: TextStyle(
        color: color ?? palette.muted,
        fontWeight: FontWeight.w800,
        fontSize: 12,
      ),
    );
  }
}

class _RetryIconButton extends StatelessWidget {
  const _RetryIconButton({required this.onPressed, required this.palette});

  final VoidCallback? onPressed;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: context.ui('Refresh'),
      onPressed: onPressed,
      icon: const Icon(Icons.refresh_rounded),
      style: IconButton.styleFrom(
        backgroundColor: palette.card,
        foregroundColor: palette.accent,
      ),
    );
  }
}

class GuruRightRail extends StatelessWidget {
  const GuruRightRail({
    super.key,
    required this.gurus,
    required this.signals,
    required this.exposures,
    required this.activeGuruId,
    required this.palette,
    required this.onSelectGuru,
    required this.onOpenGuruTrade,
    required this.onOpenValuation,
    this.deckHeight = 860,
    this.deckLimit = 16,
  });

  final List<Map<String, dynamic>> gurus;
  final List<SignalItem> signals;
  final List<ExposureItem> exposures;
  final String activeGuruId;
  final Palette palette;
  final ValueChanged<String> onSelectGuru;
  final void Function(String guruId, String ticker) onOpenGuruTrade;
  final ValueChanged<String> onOpenValuation;
  final double deckHeight;
  final int deckLimit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CompactSignalBoard(
          signals: signals,
          activeGuruId: activeGuruId,
          palette: palette,
          onSelectGuru: onSelectGuru,
        ),
        const SizedBox(height: 10),
        _CompactTickerDeck(
          gurus: gurus,
          exposures: exposures,
          palette: palette,
          onOpenGuruTrade: onOpenGuruTrade,
          onOpenValuation: onOpenValuation,
          height: deckHeight,
          itemLimit: deckLimit,
        ),
      ],
    );
  }
}

class QuickLinksPanel extends StatelessWidget {
  const QuickLinksPanel({
    super.key,
    required this.palette,
    required this.onMode,
  });

  final Palette palette;
  final ValueChanged<String> onMode;

  @override
  Widget build(BuildContext context) {
    final links = const [
      ('Fair Value Matrix', 'valuation', Icons.query_stats_rounded),
    ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.link_rounded,
            kicker: 'QUICK LINKS',
            title: context.tr('快速入口', 'Quick Links'),
            palette: palette,
          ),
          const SizedBox(height: 12),
          for (final link in links)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onMode(link.$2),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: palette.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.border),
                  ),
                  child: Row(
                    children: [
                      Icon(link.$3, color: palette.muted, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          link.$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.muted,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: palette.faint,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CenterColumn extends StatelessWidget {
  const CenterColumn({
    super.key,
    required this.stats,
    required this.signals,
    required this.exposures,
    required this.activeGuruId,
    required this.palette,
    required this.onSelectGuru,
  });

  final ExecutiveStats stats;
  final List<SignalItem> signals;
  final List<ExposureItem> exposures;
  final String activeGuruId;
  final Palette palette;
  final ValueChanged<String> onSelectGuru;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ExecutiveSummaryGrid(stats: stats, palette: palette),
        const SizedBox(height: 14),
        SignalBoard(
          signals: signals.take(12).toList(),
          activeGuruId: activeGuruId,
          palette: palette,
          onSelectGuru: onSelectGuru,
        ),
        const SizedBox(height: 14),
        TickerHeatmap(exposures: exposures.take(12).toList(), palette: palette),
      ],
    );
  }
}

class ExecutiveSummaryGrid extends StatelessWidget {
  const ExecutiveSummaryGrid({
    super.key,
    required this.stats,
    required this.palette,
  });

  final ExecutiveStats stats;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final cards = [
      StatCardData(
        'Coverage',
        '${stats.count}',
        'monitored gurus',
        Icons.radar_rounded,
      ),
      StatCardData(
        'Reported 13F table value',
        formatMoney(stats.aum),
        'information-table total',
        Icons.account_balance_wallet_rounded,
      ),
      StatCardData(
        'Signal spread',
        signedNumber(stats.netSignals),
        'buy/add minus sell/reduce',
        Icons.bolt_rounded,
      ),
      StatCardData(
        'Latest quarter',
        stats.latestQuarter,
        'dominant disclosure window',
        Icons.calendar_month_rounded,
      ),
    ];
    return GridWrap(
      minTileWidth: 190,
      spacing: 12,
      children: [
        for (final card in cards)
          ExecutiveStatCard(data: card, palette: palette),
      ],
    );
  }
}

class ExecutiveStatCard extends StatelessWidget {
  const ExecutiveStatCard({
    super.key,
    required this.data,
    required this.palette,
  });

  final StatCardData data;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(data.icon, color: palette.accent, size: 20),
          const SizedBox(height: 12),
          Text(
            data.label,
            style: TextStyle(color: palette.muted, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            data.value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: palette.text,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 4),
          Text(data.sub, style: TextStyle(color: palette.faint, fontSize: 12)),
        ],
      ),
    );
  }
}

class GuruOverviewStrip extends StatelessWidget {
  const GuruOverviewStrip({
    super.key,
    required this.stats,
    required this.signals,
    required this.exposures,
    required this.activeGuruId,
    required this.palette,
    required this.onSelectGuru,
  });

  final ExecutiveStats stats;
  final List<SignalItem> signals;
  final List<ExposureItem> exposures;
  final String activeGuruId;
  final Palette palette;
  final ValueChanged<String> onSelectGuru;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1180;
        final overview = OverallSnapshotPanel(
          stats: stats,
          palette: palette,
          height: wide ? 328 : null,
        );
        final signalBoard = CompactSignalBoard(
          signals: signals,
          activeGuruId: activeGuruId,
          palette: palette,
          onSelectGuru: onSelectGuru,
          height: wide ? 328 : null,
        );
        final heatmap = CompactTickerHeatmap(
          exposures: exposures,
          palette: palette,
          height: wide ? 328 : null,
        );

        if (!wide) {
          return Column(
            children: [
              overview,
              const SizedBox(height: 12),
              signalBoard,
              const SizedBox(height: 12),
              heatmap,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: overview),
            const SizedBox(width: 14),
            Expanded(flex: 4, child: signalBoard),
            const SizedBox(width: 14),
            Expanded(flex: 3, child: heatmap),
          ],
        );
      },
    );
  }
}

class OverallSnapshotPanel extends StatelessWidget {
  const OverallSnapshotPanel({
    super.key,
    required this.stats,
    required this.palette,
    this.height,
  });

  final ExecutiveStats stats;
  final Palette palette;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final items = [
      StatCardData('Coverage', '${stats.count}', 'gurus', Icons.radar_rounded),
      StatCardData(
        'Reported 13F table value',
        formatMoney(stats.aum),
        'information-table total',
        Icons.account_balance_wallet_rounded,
      ),
      StatCardData(
        'Signal spread',
        signedNumber(stats.netSignals),
        'buy minus sell',
        Icons.bolt_rounded,
      ),
      StatCardData(
        'Latest quarter',
        stats.latestQuarter,
        'disclosure window',
        Icons.calendar_month_rounded,
      ),
    ];
    final body = GridWrap(
      minTileWidth: 150,
      spacing: 10,
      children: [
        for (final item in items)
          OverviewMetricLine(data: item, palette: palette),
      ],
    );
    return SizedBox(
      height: height,
      child: Panel(
        palette: palette,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: Icons.dashboard_customize_rounded,
              kicker: 'OVERVIEW',
              title: context.tr('总体情况', 'Overview'),
              palette: palette,
            ),
            const SizedBox(height: 14),
            if (height == null) body else Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class OverviewMetricLine extends StatelessWidget {
  const OverviewMetricLine({
    super.key,
    required this.data,
    required this.palette,
  });

  final StatCardData data;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(data.icon, color: palette.accent, size: 18),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                data.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                data.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.faint, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class CompactSignalBoard extends StatelessWidget {
  const CompactSignalBoard({
    super.key,
    required this.signals,
    required this.activeGuruId,
    required this.palette,
    required this.onSelectGuru,
    this.height,
  });

  final List<SignalItem> signals;
  final String activeGuruId;
  final Palette palette;
  final ValueChanged<String> onSelectGuru;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        for (final signal in signals)
          CompactSignalRow(
            signal: signal,
            active: signal.guruId == activeGuruId,
            palette: palette,
            onTap: () => onSelectGuru(signal.guruId),
          ),
      ],
    );
    return SizedBox(
      height: height,
      child: Panel(
        palette: palette,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: Icons.timeline_rounded,
              kicker: 'SIGNAL BOARD',
              title: context.tr('最新信号', 'Latest Signals'),
              trailing: Text(
                context.ui('${signals.length} visible'),
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
              palette: palette,
            ),
            const SizedBox(height: 14),
            if (signals.isEmpty)
              EmptyState(
                text: 'No fresh signals in the current local database.',
                palette: palette,
              )
            else if (height == null)
              body
            else
              Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class CompactSignalRow extends StatelessWidget {
  const CompactSignalRow({
    super.key,
    required this.signal,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final SignalItem signal;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = signal.tone == 'positive'
        ? palette.positive
        : signal.tone == 'negative'
        ? palette.negative
        : palette.muted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? palette.accent.withValues(alpha: .12)
                : palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? palette.accent.withValues(alpha: .55)
                  : palette.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 30,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 9),
              StockLogo(ticker: signal.ticker, palette: palette, size: 24),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${signal.ticker} · ${actionLabel(signal.actionLabel, context.language)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      signal.guruName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                signal.value > 0
                    ? formatMoney(signal.value)
                    : context.ui(signal.detail),
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CompactTickerHeatmap extends StatelessWidget {
  const CompactTickerHeatmap({
    super.key,
    required this.exposures,
    required this.palette,
    this.height,
  });

  final List<ExposureItem> exposures;
  final Palette palette;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final maxBreadth = exposures.fold<int>(
      0,
      (max, item) => math.max(max, item.guruCount),
    );
    final body = Column(
      children: [
        for (final item in exposures)
          CompactHeatmapRow(
            item: item,
            maxBreadth: maxBreadth,
            palette: palette,
          ),
      ],
    );
    return SizedBox(
      height: height,
      child: Panel(
        palette: palette,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: Icons.grid_view_rounded,
              kicker: 'TICKER HEATMAP',
              title: context.tr('拥挤持仓', 'Crowded Holdings'),
              palette: palette,
            ),
            const SizedBox(height: 14),
            if (exposures.isEmpty)
              EmptyState(
                text: 'No external consensus exposure after filtering.',
                palette: palette,
              )
            else if (height == null)
              body
            else
              Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _CompactTickerDeck extends StatefulWidget {
  const _CompactTickerDeck({
    required this.gurus,
    required this.exposures,
    required this.palette,
    required this.onOpenGuruTrade,
    required this.onOpenValuation,
    this.height = 860,
    this.itemLimit = 16,
  });

  final List<Map<String, dynamic>> gurus;
  final List<ExposureItem> exposures;
  final Palette palette;
  final void Function(String guruId, String ticker) onOpenGuruTrade;
  final ValueChanged<String> onOpenValuation;
  final double height;
  final int itemLimit;

  @override
  State<_CompactTickerDeck> createState() => _CompactTickerDeckState();
}

class _CompactTickerDeckState extends State<_CompactTickerDeck> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_page + delta) % 4;
    final normalized = next < 0 ? next + 4 : next;
    setState(() => _page = normalized);
    _controller.animateToPage(
      normalized,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _openLens({String ticker = '', int? initialView}) {
    final view =
        initialView ??
        switch (_page) {
          2 => 1,
          3 => 2,
          _ => 0,
        };
    showQuarterlyMarketLens(
      context: context,
      gurus: widget.gurus,
      palette: widget.palette,
      initialView: view,
      initialTicker: ticker,
      onOpenGuruTrade: widget.onOpenGuruTrade,
      onOpenValuation: widget.onOpenValuation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final quarter = defaultGuruDisclosureQuarter(widget.gurus);
    final quarterKicker = quarter == '-'
        ? context.tr('等待共同季度', 'AWAITING COMMON QUARTER')
        : context.tr('$quarter · 市场全景', '$quarter · MARKET LENS');
    final changeKicker = quarter == '-'
        ? context.tr('等待共同季度', 'AWAITING COMMON QUARTER')
        : context.tr('$quarter · 申报变化', '$quarter · REPORTED CHANGES');
    final addItems = buildActivityRankItems(
      widget.gurus,
      positive: true,
      reportQuarter: quarter,
      language: context.language,
    );
    final trimItems = buildActivityRankItems(
      widget.gurus,
      positive: false,
      reportQuarter: quarter,
      language: context.language,
    );
    final pages = [
      _DeckPageSpec(
        icon: Icons.grid_view_rounded,
        kicker: quarterKicker,
        title: context.tr('拥挤持仓', 'Crowded Holdings'),
        body: _CrowdedHoldingsDeckPage(
          exposures: widget.exposures.take(widget.itemLimit).toList(),
          palette: widget.palette,
          onOpen: (ticker) => _openLens(ticker: ticker, initialView: 0),
        ),
      ),
      _DeckPageSpec(
        icon: Icons.event_note_rounded,
        kicker: 'LATEST FILINGS',
        title: context.tr('最近财报', 'Latest Filings'),
        body: _RecentFilingDeckPage(
          filings: buildRecentFilingItems(
            widget.gurus,
            language: context.language,
          ).take(widget.itemLimit).toList(),
          palette: widget.palette,
        ),
      ),
      _DeckPageSpec(
        icon: Icons.trending_up_rounded,
        kicker: changeKicker,
        title: context.tr('集中加仓', 'Crowded Adds'),
        body: _ActivityRankingDeckPage(
          items: addItems.take(widget.itemLimit).toList(),
          positive: true,
          palette: widget.palette,
          onOpen: (ticker) => _openLens(ticker: ticker, initialView: 1),
        ),
      ),
      _DeckPageSpec(
        icon: Icons.trending_down_rounded,
        kicker: changeKicker,
        title: context.tr('集中减仓', 'Crowded Trims'),
        body: _ActivityRankingDeckPage(
          items: trimItems.take(widget.itemLimit).toList(),
          positive: false,
          palette: widget.palette,
          onOpen: (ticker) => _openLens(ticker: ticker, initialView: 2),
        ),
      ),
    ];
    final current = pages[_page];

    return SizedBox(
      height: widget.height,
      child: Panel(
        palette: widget.palette,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: current.icon,
              kicker: current.kicker,
              title: current.title,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DeckNavButton(
                    key: const ValueKey('quarterly-market-lens-expand'),
                    icon: Icons.open_in_full_rounded,
                    tooltip: context.tr(
                      '打开季度全局分析',
                      'Open quarterly market lens',
                    ),
                    onTap: _openLens,
                    palette: widget.palette,
                  ),
                  const SizedBox(width: 3),
                  _DeckNavControls(
                    page: _page,
                    count: pages.length,
                    palette: widget.palette,
                    onPrevious: () => _go(-1),
                    onNext: () => _go(1),
                  ),
                ],
              ),
              palette: widget.palette,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (value) => setState(() => _page = value),
                children: [
                  for (final page in pages)
                    _DeckPageFrame(page: page, palette: widget.palette),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DeckDots(
              page: _page,
              count: pages.length,
              palette: widget.palette,
            ),
          ],
        ),
      ),
    );
  }
}

class _DeckPageSpec {
  const _DeckPageSpec({
    required this.icon,
    required this.kicker,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String kicker;
  final String title;
  final Widget body;
}

class _DeckPageFrame extends StatelessWidget {
  const _DeckPageFrame({required this.page, required this.palette});

  final _DeckPageSpec page;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return page.body;
  }
}

class _DeckNavControls extends StatelessWidget {
  const _DeckNavControls({
    required this.page,
    required this.count,
    required this.palette,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int count;
  final Palette palette;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DeckNavButton(
          icon: Icons.chevron_left_rounded,
          tooltip: context.tr('上一张', 'Previous'),
          onTap: onPrevious,
          palette: palette,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '${page + 1}/$count',
            style: TextStyle(
              color: palette.faint,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        _DeckNavButton(
          icon: Icons.chevron_right_rounded,
          tooltip: context.tr('下一张', 'Next'),
          onTap: onNext,
          palette: palette,
        ),
      ],
    );
  }
}

class _DeckNavButton extends StatelessWidget {
  const _DeckNavButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.palette,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 44,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: palette.border),
              ),
              child: Icon(icon, color: palette.muted, size: 17),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckDots extends StatelessWidget {
  const _DeckDots({
    required this.page,
    required this.count,
    required this.palette,
  });

  final int page;
  final int count;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < count; i += 1)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: i == page ? 18 : 5,
            height: 5,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(
              color: i == page ? palette.accent : palette.border,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}

class _CrowdedHoldingsDeckPage extends StatelessWidget {
  const _CrowdedHoldingsDeckPage({
    required this.exposures,
    required this.palette,
    required this.onOpen,
  });

  final List<ExposureItem> exposures;
  final Palette palette;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (exposures.isEmpty) {
      return EmptyState(
        text: 'No external consensus exposure after filtering.',
        palette: palette,
      );
    }
    final maxBreadth = exposures.fold<int>(
      0,
      (max, item) => math.max(max, item.guruCount),
    );
    return ListView.builder(
      key: const ValueKey('crowded-holdings-list'),
      padding: EdgeInsets.zero,
      primary: false,
      itemCount: exposures.length,
      itemBuilder: (context, index) => _CrowdedHoldingDeckRow(
        rank: index + 1,
        item: exposures[index],
        maxBreadth: maxBreadth,
        palette: palette,
        isLast: index == exposures.length - 1,
        onTap: () => onOpen(exposures[index].ticker),
      ),
    );
  }
}

class _CrowdedHoldingDeckRow extends StatelessWidget {
  const _CrowdedHoldingDeckRow({
    required this.rank,
    required this.item,
    required this.maxBreadth,
    required this.palette,
    required this.isLast,
    required this.onTap,
  });

  final int rank;
  final ExposureItem item;
  final int maxBreadth;
  final Palette palette;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final progress = maxBreadth <= 0
        ? 0.0
        : math.max(.05, item.guruCount / maxBreadth).clamp(0.0, 1.0).toDouble();
    final guruNames = item.guruNames.take(3).join(', ');
    final suffix = item.guruCount > 3 ? ' +' : '';
    return Semantics(
      button: true,
      label: context.tr(
        '打开 ${item.ticker} 的季度集中持仓分析',
        'Open quarterly crowded-holding analysis for ${item.ticker}',
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: isLast ? 0 : 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 99,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 22,
                            child: Text(
                              '#$rank',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.faint,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          StockLogo(
                            ticker: item.ticker,
                            palette: palette,
                            size: 21,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.ticker,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.text,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor: palette.border,
                          color: palette.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 58,
                      child: Text(
                        formatMoney(item.value),
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: palette.faint,
                      size: 16,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const SizedBox(width: 82),
                    Expanded(
                      child: Text(
                        context.tr(
                          '${item.guruCount} 位投资人 · $guruNames$suffix',
                          '${item.guruCount} gurus · $guruNames$suffix',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.faint, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentFilingDeckPage extends StatelessWidget {
  const _RecentFilingDeckPage({required this.filings, required this.palette});

  final List<GuruFilingItem> filings;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    if (filings.isEmpty) {
      return EmptyState(
        text: 'No recent 13F filings in the current local database.',
        palette: palette,
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      primary: false,
      itemCount: filings.length,
      itemBuilder: (context, index) {
        final filing = filings[index];
        return _DeckListRow(
          title: filing.guruName,
          subtitle:
              '${filing.quarter} · filed ${formatDate(filing.filingDate)}',
          value: filing.quarter,
          meta: formatMoney(filing.value),
          tone: palette.secondary,
          palette: palette,
        );
      },
    );
  }
}

class _ActivityRankingDeckPage extends StatelessWidget {
  const _ActivityRankingDeckPage({
    required this.items,
    required this.positive,
    required this.palette,
    required this.onOpen,
  });

  final List<GuruActivityRankItem> items;
  final bool positive;
  final Palette palette;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return EmptyState(
        text: positive
            ? 'No add/new rows in the current local database.'
            : 'No reduce/sell-out rows in the current local database.',
        palette: palette,
      );
    }
    final maxAmount = items.fold<double>(
      0,
      (max, item) => item.amountReliable ? math.max(max, item.amount) : max,
    );
    final tone = positive ? palette.positive : palette.negative;
    return ListView.builder(
      padding: EdgeInsets.zero,
      primary: false,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final titleLabel = positive
            ? context.tr('加仓汇总', 'Add Summary')
            : context.tr('减仓汇总', 'Trim Summary');
        return _DeckListRow(
          title: '${item.ticker} · $titleLabel',
          ticker: item.ticker,
          subtitle: activityRankSubtitle(item, context.language),
          meta: activityRankActionSummary(item, context.language),
          value: item.amountReliable
              ? context.tr(
                  '代理 ${formatMoney(item.amount)}',
                  'proxy ${formatMoney(item.amount)}',
                )
              : context.tr('代理不可靠', 'proxy N/A'),
          tone: tone,
          progress: !item.amountReliable || maxAmount <= 0
              ? 0.0
              : math
                    .max(.06, item.amount / maxAmount)
                    .clamp(0.0, 1.0)
                    .toDouble(),
          palette: palette,
          onTap: () => onOpen(item.ticker),
          semanticLabel: context.tr(
            '打开 ${item.ticker} 的本季度申报变化分析',
            'Open quarterly reported-change analysis for ${item.ticker}',
          ),
        );
      },
    );
  }
}

class _DeckListRow extends StatelessWidget {
  const _DeckListRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.tone,
    required this.palette,
    this.meta,
    this.progress,
    this.onTap,
    this.semanticLabel,
    this.ticker = '',
  });

  final String ticker;
  final String title;
  final String subtitle;
  final String value;
  final Color tone;
  final Palette palette;
  final String? meta;
  final double? progress;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Container(
          width: 4,
          height: 34,
          decoration: BoxDecoration(
            color: tone,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 9),
        if (ticker.isNotEmpty) ...[
          StockLogo(ticker: ticker, palette: palette, size: 24),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.ui(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.ui(subtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 10),
                    ),
                  ),
                  if (meta != null && meta!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      context.ui(meta!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.faint,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                  if (progress != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor: palette.border,
                          color: tone,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final interactive = onTap == null
        ? row
        : Semantics(
            button: true,
            label: semanticLabel,
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  child: row,
                ),
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: interactive,
    );
  }
}

Future<void> showQuarterlyMarketLens({
  required BuildContext context,
  required List<Map<String, dynamic>> gurus,
  required Palette palette,
  required int initialView,
  required String initialTicker,
  required void Function(String guruId, String ticker) onOpenGuruTrade,
  required ValueChanged<String> onOpenValuation,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: .72),
  builder: (dialogContext) => LanguageScope(
    language: context.language,
    child: QuarterlyMarketLensDialog(
      gurus: gurus,
      palette: palette,
      initialView: initialView,
      initialTicker: initialTicker,
      onOpenGuruTrade: onOpenGuruTrade,
      onOpenValuation: onOpenValuation,
      researchApi: StockResearchScope.maybeOf(context)?.api,
    ),
  ),
);

class QuarterlyMarketLensDialog extends StatefulWidget {
  const QuarterlyMarketLensDialog({
    super.key,
    required this.gurus,
    required this.palette,
    required this.initialView,
    required this.initialTicker,
    required this.onOpenGuruTrade,
    required this.onOpenValuation,
    this.researchApi,
  });

  final List<Map<String, dynamic>> gurus;
  final Palette palette;
  final int initialView;
  final String initialTicker;
  final void Function(String guruId, String ticker) onOpenGuruTrade;
  final ValueChanged<String> onOpenValuation;
  final ApiClient? researchApi;

  @override
  State<QuarterlyMarketLensDialog> createState() =>
      _QuarterlyMarketLensDialogState();
}

class _QuarterlyMarketLensDialogState extends State<QuarterlyMarketLensDialog> {
  late int _view;
  late String _ticker;
  late bool _mobileDetail;
  String _query = '';
  String _researchTicker = '';

  @override
  void initState() {
    super.initState();
    _view = widget.initialView.clamp(0, 2).toInt();
    _ticker = widget.initialTicker.trim().toUpperCase();
    _mobileDetail = _ticker.isNotEmpty;
  }

  void _selectView(int value) {
    if (value == _view) return;
    setState(() {
      _view = value;
      _ticker = '';
      _query = '';
      _mobileDetail = false;
      _researchTicker = '';
    });
  }

  void _selectTicker(String ticker, {required bool compact}) {
    setState(() {
      _ticker = ticker;
      _researchTicker = '';
      if (compact) _mobileDetail = true;
    });
  }

  void _openValuation(String ticker) {
    if (widget.researchApi != null) {
      setState(() => _researchTicker = ticker);
      return;
    }
    Navigator.of(context).pop();
    widget.onOpenValuation(ticker);
  }

  void _openGuruTrade(MarketLensManagerPosition position) {
    Navigator.of(context).pop();
    widget.onOpenGuruTrade(position.guruId, position.ticker);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final quarter = defaultGuruDisclosureQuarter(widget.gurus);
    final exposures = buildExposures(
      widget.gurus,
      reportQuarter: quarter,
      language: context.language,
    );
    final adds = buildActivityRankItems(
      widget.gurus,
      positive: true,
      reportQuarter: quarter,
      language: context.language,
    );
    final trims = buildActivityRankItems(
      widget.gurus,
      positive: false,
      reportQuarter: quarter,
      language: context.language,
    );
    final eligible = guruDisclosureEligibleCount(widget.gurus);
    final covered = guruDisclosureQuarterCoverage(widget.gurus, quarter);
    final quarterLabel = quarter == '-'
        ? context.tr('暂无共同季度', 'No common quarter')
        : quarter;
    final trackedValue = widget.gurus
        .where(isQuarterLensGuru)
        .where(
          (guru) =>
              reportQuarterLabel(text(asMap(guru['summary'])['reportDate'])) ==
              quarter,
        )
        .fold<double>(0, (sum, guru) => sum + reported13fCommonLongValue(guru));
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 760;
    final availableHeight = math.max(420.0, size.height - (compact ? 16 : 48));
    final currentTickers = switch (_view) {
      0 => [for (final item in exposures) item.ticker],
      1 => [for (final item in adds) item.ticker],
      _ => [for (final item in trims) item.ticker],
    };
    final selectedTicker = currentTickers.contains(_ticker)
        ? _ticker
        : (currentTickers.isEmpty ? '' : currentTickers.first);
    final selectedExposure = exposures.firstWhere(
      (item) => item.ticker == selectedTicker,
      orElse: () => const ExposureItem(
        ticker: '',
        value: 0,
        guruNames: {},
        positions: [],
      ),
    );
    final selectedActivity = (_view == 1 ? adds : trims).firstWhere(
      (item) => item.ticker == selectedTicker,
      orElse: () => const GuruActivityRankItem(
        ticker: '',
        actions: {},
        guruNames: {},
        reportDate: '',
        amount: 0,
        positions: [],
      ),
    );

    return Dialog(
      key: const ValueKey('quarterly-market-lens-dialog'),
      insetPadding: EdgeInsets.all(compact ? 8 : 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1120, maxHeight: availableHeight),
        child: Container(
          decoration: panelDecoration(palette),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  compact ? 12 : 18,
                  compact ? 8 : 12,
                  12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: palette.accent.withValues(alpha: .13),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: palette.accent.withValues(alpha: .30),
                        ),
                      ),
                      child: Icon(
                        Icons.radar_rounded,
                        color: palette.accent,
                        size: 23,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr('季度市场透镜', 'QUARTERLY MARKET LENS'),
                            style: TextStyle(
                              color: palette.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .7,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            context.tr(
                              '从榜单深入到经理级证据',
                              'From ranking to manager-level evidence',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: compact ? 17 : 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('关闭', 'Close'),
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: palette.muted),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: palette.border),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 12 : 20,
                  12,
                  compact ? 12 : 20,
                  10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        InfoChip(quarterLabel, palette: palette),
                        InfoChip(
                          context.tr(
                            '$covered/$eligible 位合资格经理已申报',
                            '$covered/$eligible eligible managers filed',
                          ),
                          palette: palette,
                        ),
                        InfoChip(
                          context.tr(
                            '${exposures.length} 只可识别普通股',
                            '${exposures.length} mapped common stocks',
                          ),
                          palette: palette,
                        ),
                        InfoChip(
                          context.tr(
                            '覆盖 ${formatMoney(trackedValue)}',
                            '${formatMoney(trackedValue)} tracked',
                          ),
                          palette: palette,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _MarketLensTab(
                            selected: _view == 0,
                            icon: Icons.grid_view_rounded,
                            label: context.tr('集中持仓', 'Crowded Holdings'),
                            palette: palette,
                            onTap: () => _selectView(0),
                          ),
                          const SizedBox(width: 8),
                          _MarketLensTab(
                            selected: _view == 1,
                            icon: Icons.trending_up_rounded,
                            label: context.tr('集中加仓', 'Reported Adds'),
                            palette: palette,
                            onTap: () => _selectView(1),
                          ),
                          const SizedBox(width: 8),
                          _MarketLensTab(
                            selected: _view == 2,
                            icon: Icons.trending_down_rounded,
                            label: context.tr('集中减仓', 'Reported Trims'),
                            palette: palette,
                            onTap: () => _selectView(2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 12 : 20,
                    0,
                    compact ? 12 : 20,
                    compact ? 12 : 20,
                  ),
                  child: compact
                      ? (_mobileDetail && selectedTicker.isNotEmpty
                            ? _buildCompactDetail(
                                context,
                                selectedTicker,
                                selectedExposure,
                                selectedActivity,
                                covered,
                              )
                            : _buildRanking(
                                context,
                                exposures,
                                adds,
                                trims,
                                selectedTicker,
                                compact: true,
                              ))
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 390,
                              child: _buildRanking(
                                context,
                                exposures,
                                adds,
                                trims,
                                selectedTicker,
                                compact: false,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _buildDetail(
                                context,
                                selectedTicker,
                                selectedExposure,
                                selectedActivity,
                                covered,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRanking(
    BuildContext context,
    List<ExposureItem> exposures,
    List<GuruActivityRankItem> adds,
    List<GuruActivityRankItem> trims,
    String selectedTicker, {
    required bool compact,
  }) {
    final palette = widget.palette;
    final query = _query.trim().toUpperCase();
    final exposureRows = exposures
        .where((item) => query.isEmpty || item.ticker.contains(query))
        .take(100)
        .toList();
    final activityRows = (_view == 1 ? adds : trims)
        .where((item) => query.isEmpty || item.ticker.contains(query))
        .take(100)
        .toList();
    final count = _view == 0 ? exposureRows.length : activityRows.length;
    final description = _view == 0
        ? context.tr(
            '优先按独立经理覆盖数排序，再看中位组合权重，避免被超大基金的绝对规模主导。',
            'Ranks independent-manager breadth first, then median book weight, reducing mega-fund size distortion.',
          )
        : context.tr(
            '优先按同季度申报该变化的经理数排序；金额是季末持仓价值变化代理，并非成交现金。',
            'Ranks managers reporting the same-quarter change first; value is a quarter-end holding-change proxy, not execution cash.',
          );
    final rows = <Widget>[
      for (var index = 0; index < count; index += 1)
        if (_view == 0)
          _MarketLensRankRow(
            rank: index + 1,
            ticker: exposureRows[index].ticker,
            primary: context.tr(
              '${exposureRows[index].guruCount} 位经理',
              '${exposureRows[index].guruCount} managers',
            ),
            secondary: context.tr(
              '${formatMoney(exposureRows[index].value)} · 中位权重 ${formatReturn(exposureRows[index].medianWeight).replaceFirst('+', '')}',
              '${formatMoney(exposureRows[index].value)} · median weight ${formatReturn(exposureRows[index].medianWeight).replaceFirst('+', '')}',
            ),
            selected: exposureRows[index].ticker == selectedTicker,
            tone: palette.accent,
            palette: palette,
            onTap: () =>
                _selectTicker(exposureRows[index].ticker, compact: compact),
          )
        else
          _MarketLensRankRow(
            rank: index + 1,
            ticker: activityRows[index].ticker,
            primary: context.tr(
              '${activityRows[index].guruCount} 位经理 · ${activityRankActionSummary(activityRows[index], context.language)}',
              '${activityRows[index].guruCount} managers · ${activityRankActionSummary(activityRows[index], context.language)}',
            ),
            secondary: activityRows[index].amountReliable
                ? context.tr(
                    '价值变化代理 ${formatMoney(activityRows[index].amount)}',
                    'Value-change proxy ${formatMoney(activityRows[index].amount)}',
                  )
                : context.tr('价值变化代理不可靠', 'Value-change proxy N/A'),
            selected: activityRows[index].ticker == selectedTicker,
            tone: _view == 1 ? palette.positive : palette.negative,
            palette: palette,
            onTap: () =>
                _selectTicker(activityRows[index].ticker, compact: compact),
          ),
    ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _view == 0
                ? context.tr('完整持仓排名', 'Full holdings ranking')
                : _view == 1
                ? context.tr('完整加仓排名', 'Full reported-add ranking')
                : context.tr('完整减仓排名', 'Full reported-trim ranking'),
            style: TextStyle(
              color: palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            description,
            style: TextStyle(color: palette.muted, fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: TextField(
              key: const ValueKey('quarterly-market-lens-search'),
              onChanged: (value) => setState(() => _query = value),
              style: TextStyle(color: palette.text, fontSize: 13),
              decoration: InputDecoration(
                hintText: context.tr('搜索股票代码', 'Search ticker'),
                hintStyle: TextStyle(color: palette.faint),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: palette.muted,
                  size: 19,
                ),
                filled: true,
                fillColor: palette.card,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: palette.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: palette.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: palette.accent),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            EmptyState(
              text: context.tr(
                '当前筛选没有可显示的申报数据。',
                'No reported data matches the current filter.',
              ),
              palette: palette,
            )
          else if (compact)
            Expanded(child: ListView(children: rows))
          else
            Expanded(child: ListView(children: rows)),
        ],
      ),
    );
  }

  Widget _buildCompactDetail(
    BuildContext context,
    String selectedTicker,
    ExposureItem exposure,
    GuruActivityRankItem activity,
    int covered,
  ) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('quarterly-market-lens-back'),
            onPressed: () => setState(() => _mobileDetail = false),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(context.tr('返回完整排名', 'Back to full ranking')),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _buildDetail(
            context,
            selectedTicker,
            exposure,
            activity,
            covered,
          ),
        ),
      ],
    );
  }

  Widget _buildDetail(
    BuildContext context,
    String selectedTicker,
    ExposureItem exposure,
    GuruActivityRankItem activity,
    int covered,
  ) {
    final palette = widget.palette;
    if (selectedTicker.isEmpty) {
      return EmptyState(
        text: context.tr(
          '选择一只股票查看经理级证据。',
          'Select a ticker to inspect manager-level evidence.',
        ),
        palette: palette,
      );
    }
    final positions =
        (_view == 0 ? exposure.positions : activity.positions).toList()
          ..sort((left, right) {
            final weightCompare = right.currentWeight.compareTo(
              left.currentWeight,
            );
            return weightCompare != 0
                ? weightCompare
                : right.currentValue.compareTo(left.currentValue);
          });
    if (_researchTicker == selectedTicker && widget.researchApi != null) {
      return StockValuationPanel(
        key: ValueKey('market-lens-research-$selectedTicker'),
        ticker: selectedTicker,
        api: widget.researchApi!,
        palette: palette,
        sourceLabel: context.tr(
          '季度大佬共识 · ${defaultGuruDisclosureQuarter(widget.gurus)}',
          'Quarterly Guru consensus · ${defaultGuruDisclosureQuarter(widget.gurus)}',
        ),
        onClose: () => setState(() => _researchTicker = ''),
      );
    }
    final issuer = positions.isEmpty ? '' : positions.first.issuer;
    final nonPublicPositions = positions
        .where((position) => !position.isPubliclyTradable)
        .toList();
    final isPubliclyTradable = nonPublicPositions.isEmpty;
    final publicTradingReason = nonPublicPositions.isEmpty
        ? ''
        : nonPublicPositions.first.publicTradingReason(context.language);
    final breadth = _view == 0 ? exposure.guruCount : activity.guruCount;
    final metricCards = _view == 0
        ? [
            MiniMetric(
              context.tr('经理覆盖', 'Manager breadth'),
              '$breadth/$covered',
              Icons.groups_2_outlined,
              palette,
            ),
            MiniMetric(
              context.tr('申报持仓合计', 'Reported value'),
              formatMoney(exposure.value),
              Icons.account_balance_wallet_outlined,
              palette,
            ),
            MiniMetric(
              context.tr('中位组合权重', 'Median book weight'),
              formatReturn(exposure.medianWeight).replaceFirst('+', ''),
              Icons.balance_outlined,
              palette,
            ),
            MiniMetric(
              context.tr('最高组合权重', 'Maximum book weight'),
              formatReturn(exposure.maxWeight).replaceFirst('+', ''),
              Icons.vertical_align_top_rounded,
              palette,
            ),
          ]
        : [
            MiniMetric(
              context.tr('一致经理数', 'Managers aligned'),
              '$breadth',
              Icons.groups_2_outlined,
              palette,
            ),
            MiniMetric(
              context.tr('价值变化代理', 'Value-change proxy'),
              activity.amountReliable ? formatMoney(activity.amount) : 'N/A',
              Icons.swap_vert_circle_outlined,
              palette,
            ),
            MiniMetric(
              context.tr('新建仓 / 调整', 'New / adjusted'),
              _view == 1
                  ? '${activity.newCount} / ${activity.increasedCount}'
                  : '${activity.soldOutCount} / ${activity.reducedCount}',
              Icons.compare_arrows_rounded,
              palette,
            ),
            MiniMetric(
              context.tr('当前中位权重', 'Median current weight'),
              formatReturn(activity.medianCurrentWeight).replaceFirst('+', ''),
              Icons.balance_outlined,
              palette,
            ),
          ];
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(16),
      child: ListView(
        key: const ValueKey('quarterly-market-lens-detail-scroll'),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 420;
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StockLogo(ticker: selectedTicker, palette: palette, size: 34),
                  const SizedBox(height: 7),
                  Text(
                    selectedTicker,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (issuer.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      issuer,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ],
              );
              final action = FilledButton.icon(
                key: const ValueKey('quarterly-market-lens-valuation'),
                onPressed: isPubliclyTradable
                    ? () => _openValuation(selectedTicker)
                    : null,
                icon: Icon(
                  isPubliclyTradable
                      ? Icons.query_stats_rounded
                      : Icons.lock_outline_rounded,
                  size: 18,
                ),
                label: Text(
                  isPubliclyTradable
                      ? context.tr('查看估值', 'Open valuation')
                      : context.tr(
                          '已私有化 · 无公开估值',
                          'Private · no public valuation',
                        ),
                ),
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [heading, const SizedBox(height: 10), action],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 10),
                  action,
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          if (!isPubliclyTradable) ...[
            PortfolioDataNotice(
              icon: Icons.lock_outline_rounded,
              text: text(
                publicTradingReason,
                context.tr(
                  '该申报证券已不再公开交易，因此保留申报证据，但不提供公开市场估值或复制交易入口。',
                  'The reported security is no longer publicly traded. Filing evidence remains visible, but public-market valuation and copy execution are unavailable.',
                ),
              ),
              palette: palette,
            ),
            const SizedBox(height: 14),
          ],
          GridWrap(minTileWidth: 145, spacing: 9, children: metricCards),
          const SizedBox(height: 14),
          PortfolioDataNotice(
            icon: Icons.insights_rounded,
            text: _view == 0
                ? context.tr(
                    '集中度来自同一报告季度中独立经理的共同持有，并优先考虑覆盖广度与组合权重，不把大基金的绝对规模误当作共识。',
                    'Crowding reflects common ownership by independent managers in one report quarter, prioritizing breadth and book weight rather than mistaking mega-fund size for consensus.',
                  )
                : context.tr(
                    '这是多位经理在同一报告季度披露同方向变化的交叉证据；它不能证明同步成交，也不能替代对每位经理投资逻辑的研究。',
                    'This is cross-manager evidence of same-direction reported changes in one quarter; it does not prove synchronized execution or a shared investment thesis.',
                  ),
            palette: palette,
          ),
          const SizedBox(height: 16),
          Text(
            context.tr('经理级证据', 'Manager-level evidence'),
            style: TextStyle(
              color: palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 9),
          for (final position in positions)
            _MarketLensManagerRow(
              position: position,
              palette: palette,
              onTap: position.hasTradeEvidence && position.isPubliclyTradable
                  ? () => _openGuruTrade(position)
                  : null,
            ),
          const SizedBox(height: 6),
          PortfolioDataNotice(
            icon: Icons.info_outline_rounded,
            text: context.tr(
              '13F 通常滞后披露。股数变化尚未按拆股等公司行动调整；价值变化还包含价格波动。当价值变化方向与申报动作相反时，金额代理显示为 N/A，不用完整持仓额代替。因此这里展示的是申报变化，不是已确认交易或成交现金。',
              '13F filings arrive with a delay. Share changes are not adjusted for corporate actions, and value changes also contain price movement. When the value change conflicts with the reported action, the amount proxy is shown as N/A instead of substituting the full position value. These are reported changes, not confirmed trades or execution cash.',
            ),
            palette: palette,
          ),
        ],
      ),
    );
  }
}

class _MarketLensTab extends StatelessWidget {
  const _MarketLensTab({
    required this.selected,
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = selected ? palette.accent : palette.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? palette.accent.withValues(alpha: .15)
                : palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? palette.accent.withValues(alpha: .52)
                  : palette.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: tone, size: 18),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: tone,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarketLensRankRow extends StatelessWidget {
  const _MarketLensRankRow({
    required this.rank,
    required this.ticker,
    required this.primary,
    required this.secondary,
    required this.selected,
    required this.tone,
    required this.palette,
    required this.onTap,
  });

  final int rank;
  final String ticker;
  final String primary;
  final String secondary;
  final bool selected;
  final Color tone;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: context.tr(
        '第 $rank 名，$ticker，$primary，打开深入分析',
        'Rank $rank, $ticker, $primary, open deep analysis',
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: InkWell(
          key: ValueKey('quarterly-market-lens-row-$ticker'),
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? tone.withValues(alpha: .13)
                  : palette.card.withValues(alpha: .62),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected ? tone.withValues(alpha: .46) : palette.border,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '#$rank',
                    style: TextStyle(
                      color: selected ? tone : palette.faint,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                StockLogo(ticker: ticker, palette: palette, size: 26),
                const SizedBox(width: 7),
                SizedBox(
                  width: 58,
                  child: Text(
                    ticker,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        primary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Icon(
                  Icons.chevron_right_rounded,
                  color: selected ? tone : palette.faint,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarketLensManagerRow extends StatelessWidget {
  const _MarketLensManagerRow({
    required this.position,
    required this.palette,
    required this.onTap,
  });

  final MarketLensManagerPosition position;
  final Palette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final changed = position.action != 'unchanged';
    final tone = tradeToneColor(position.action, palette);
    final lag = filingLag({
      'reportDate': position.reportDate,
      'filingDate': position.filingDate,
    });
    final previousWeight = position.previousValue > 0
        ? formatReturn(position.previousWeight).replaceFirst('+', '')
        : '-';
    final currentWeight = formatReturn(
      position.currentWeight,
    ).replaceFirst('+', '');
    final weightText =
        position.previousValue > 0 ||
            position.action == 'new' ||
            position.action == 'sold_out'
        ? context.tr(
            '权重 $previousWeight → $currentWeight',
            'weight $previousWeight → $currentWeight',
          )
        : context.tr('当前权重 $currentWeight', 'current weight $currentWeight');
    final content = Container(
      key: ValueKey(
        'quarterly-market-lens-manager-${position.guruId}-${position.ticker}',
      ),
      constraints: const BoxConstraints(minHeight: 66),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          GuruAvatar(
            key: ValueKey('market-lens-avatar-${position.guruId}'),
            guru: {
              'id': position.guruId,
              'name': position.guruName,
              'avatarUrl': position.guruAvatarUrl,
            },
            palette: palette,
            size: 34,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      position.guruName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    BadgeLabel(
                      text: changed
                          ? reported13fActionLabel(
                              position.action,
                              context.language,
                            )
                          : context.tr('申报持有', 'Reported holding'),
                      color: tone,
                    ),
                    if (!position.isPubliclyTradable)
                      BadgeLabel(
                        text: context.tr('已私有化', 'Private'),
                        color: palette.muted,
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${formatMoney(position.currentValue)} · $weightText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  context.tr(
                    '${formatDate(position.filingDate)} 申报 · 季末后 $lag',
                    'Filed ${formatDate(position.filingDate)} · $lag after quarter end',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.faint, fontSize: 10),
                ),
                if (!position.isPubliclyTradable) ...[
                  const SizedBox(height: 3),
                  Text(
                    text(
                      position.publicTradingReason(context.language),
                      context.tr(
                        '不提供公开市场估值或复制交易。',
                        'Public valuation and copy execution unavailable.',
                      ),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.muted, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_rounded, color: palette.faint, size: 17),
          ],
        ],
      ),
    );
    final row = onTap == null
        ? content
        : InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: onTap,
            child: content,
          );
    return Semantics(
      button: onTap != null,
      label: onTap != null
          ? context.tr(
              '打开 ${position.guruName} 对 ${position.ticker} 的申报变化',
              'Open ${position.guruName} reported changes for ${position.ticker}',
            )
          : context.tr(
              '${position.guruName} 申报持有 ${position.ticker}，本季无可跳转的变化记录',
              '${position.guruName} reported holding ${position.ticker}; no linked change record this quarter',
            ),
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: row),
    );
  }
}

class CompactHeatmapRow extends StatelessWidget {
  const CompactHeatmapRow({
    super.key,
    required this.item,
    required this.maxBreadth,
    required this.palette,
  });

  final ExposureItem item;
  final int maxBreadth;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final progress = maxBreadth <= 0
        ? 0.0
        : math.max(.05, item.guruCount / maxBreadth).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              item.ticker,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: palette.border,
                color: palette.accent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 58,
            child: Text(
              formatMoney(item.value),
              textAlign: TextAlign.end,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SignalBoard extends StatelessWidget {
  const SignalBoard({
    super.key,
    required this.signals,
    required this.activeGuruId,
    required this.palette,
    required this.onSelectGuru,
  });

  final List<SignalItem> signals;
  final String activeGuruId;
  final Palette palette;
  final ValueChanged<String> onSelectGuru;

  @override
  Widget build(BuildContext context) {
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.timeline_rounded,
            kicker: 'SIGNAL BOARD',
            title: 'What changed in the public tape',
            trailing: Text(
              context.ui('${signals.length} visible'),
              style: TextStyle(color: palette.muted),
            ),
            palette: palette,
          ),
          const SizedBox(height: 16),
          if (signals.isEmpty)
            EmptyState(
              text: 'No fresh signals in the current local database.',
              palette: palette,
            )
          else
            for (final signal in signals)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => onSelectGuru(signal.guruId),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: signal.guruId == activeGuruId
                          ? palette.accent.withValues(alpha: .12)
                          : palette.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: signal.guruId == activeGuruId
                            ? palette.accent
                            : palette.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 48,
                          decoration: BoxDecoration(
                            color: signal.tone == 'positive'
                                ? palette.positive
                                : signal.tone == 'negative'
                                ? palette.negative
                                : palette.muted,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                signal.ticker,
                                style: TextStyle(
                                  color: palette.text,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${signal.guruName} · ${context.ui(signal.type)} · ${actionLabel(signal.actionLabel, context.language)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: palette.muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              signal.value > 0
                                  ? formatMoney(signal.value)
                                  : context.ui(signal.detail),
                              style: TextStyle(
                                color: palette.text,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              formatDate(signal.date),
                              style: TextStyle(
                                color: palette.faint,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class TickerHeatmap extends StatelessWidget {
  const TickerHeatmap({
    super.key,
    required this.exposures,
    required this.palette,
  });

  final List<ExposureItem> exposures;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final maxBreadth = exposures.fold<int>(
      0,
      (max, item) => math.max(max, item.guruCount),
    );
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.grid_view_rounded,
            kicker: 'TICKER HEATMAP',
            title: 'Crowded external consensus',
            trailing: Text(
              context.ui('founders filtered'),
              style: TextStyle(color: palette.muted),
            ),
            palette: palette,
          ),
          const SizedBox(height: 16),
          if (exposures.isEmpty)
            EmptyState(
              text: 'No external consensus exposure after filtering.',
              palette: palette,
            )
          else
            for (final item in exposures)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.ticker,
                            style: TextStyle(
                              color: palette.text,
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            context.tr(
                              '${item.guruCount} 位 · ${item.guruNames}',
                              '${item.guruCount} people · ${item.guruNames}',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: palette.muted),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: maxBreadth <= 0
                              ? 0
                              : math.max(.05, item.guruCount / maxBreadth),
                          minHeight: 9,
                          backgroundColor: palette.border,
                          color: palette.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    SizedBox(
                      width: 82,
                      child: Text(
                        formatMoney(item.value),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
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
}

class GuruInspector extends StatelessWidget {
  const GuruInspector({
    super.key,
    required this.guru,
    required this.api,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final ApiClient api;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    if (guru.isEmpty) {
      return Panel(
        palette: palette,
        child: EmptyState(text: 'Select a guru to inspect.', palette: palette),
      );
    }

    final summary = asMap(guru['summary']);
    final type = text(guru['type']);
    final holdings = asList(guru['holdings']);
    final activity = asList(guru['activity']);
    final transactions = asList(guru['transactions']);
    final rows = type == 'manager13f'
        ? activity.take(8).toList()
        : transactions.take(8).toList();

    return Column(
      children: [
        Panel(
          palette: palette,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        BadgeLabel(
                          text: disclosureLabel(type, context.language),
                          color: palette.accent,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          guruDisplayName(guru, context.language),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: palette.text,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          text(guru['entityName']),
                          style: TextStyle(color: palette.muted, height: 1.25),
                        ),
                      ],
                    ),
                  ),
                  StatusDot(status: guruDisplayStatus(guru), palette: palette),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  InfoChip(
                    context.ui(text(guru['thesisTag'])),
                    palette: palette,
                  ),
                  InfoChip(
                    context.ui(text(asMap(guru['simulationTag'])['label'])),
                    palette: palette,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              GridWrap(
                minTileWidth: 140,
                spacing: 10,
                children: type == 'manager13f'
                    ? [
                        MiniMetric(
                          'Reported 13F table value',
                          formatMoney(reported13fTableValue(guru)),
                          Icons.wallet_rounded,
                          palette,
                        ),
                        MiniMetric(
                          'Holdings',
                          formatNumber(number(summary['totalPositions'])),
                          Icons.list_alt_rounded,
                          palette,
                        ),
                        MiniMetric(
                          'New / Exit',
                          '${formatNumber(number(summary['newPositions']))}/${formatNumber(number(summary['soldOutPositions']))}',
                          Icons.swap_vert_rounded,
                          palette,
                        ),
                        MiniMetric(
                          'Filing lag',
                          filingLag(summary),
                          Icons.schedule_rounded,
                          palette,
                        ),
                      ]
                    : [
                        MiniMetric(
                          'Source',
                          text(
                            guru['sourceLabel'],
                            text(guru['disclosureKind']),
                          ),
                          Icons.source_rounded,
                          palette,
                        ),
                        MiniMetric(
                          'Activity',
                          formatNumber(number(summary['recentTransactions'])),
                          Icons.receipt_long_rounded,
                          palette,
                        ),
                      ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        BacktestPreview(guru: guru, api: api, palette: palette),
        const SizedBox(height: 14),
        Panel(
          palette: palette,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PanelTitle(
                icon: Icons.fact_check_rounded,
                kicker: type == 'manager13f'
                    ? 'LATEST FLOW'
                    : 'DISCLOSURE TRAIL',
                title: type == 'manager13f'
                    ? 'Quarterly operations'
                    : 'Recent records',
                palette: palette,
              ),
              const SizedBox(height: 14),
              if (rows.isEmpty)
                EmptyState(
                  text: text(summary['message'], 'No activity rows available.'),
                  palette: palette,
                )
              else
                for (final row in rows)
                  OperationRow(
                    row: row,
                    manager: type == 'manager13f',
                    palette: palette,
                  ),
              if (holdings.isNotEmpty) ...[
                const Divider(height: 28),
                Text(
                  context.ui('Top holdings'),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                for (final holding in holdings.take(8))
                  HoldingRow(
                    holding: holding,
                    total: number(summary['totalValue']),
                    palette: palette,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class BacktestPreview extends StatefulWidget {
  const BacktestPreview({
    super.key,
    required this.guru,
    required this.api,
    required this.palette,
  });

  final Map<String, dynamic> guru;
  final ApiClient api;
  final Palette palette;

  @override
  State<BacktestPreview> createState() => _BacktestPreviewState();
}

class _BacktestPreviewState extends State<BacktestPreview> {
  Map<String, dynamic>? _payload;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BacktestPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (text(oldWidget.guru['id']) != text(widget.guru['id'])) {
      _payload = null;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = text(widget.guru['id']);
    if (id.isEmpty || text(widget.guru['type']) != 'manager13f') return;
    setState(() => _loading = true);
    try {
      final payload = await widget.api.getJson(
        '${guruBacktestPath(id)}&surface=directory-disclosure-v1',
      );
      if (mounted) setState(() => _payload = payload);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sim = asMap(widget.guru['simulationTag']);
    final isProxy = _isProxyReadyBacktest(_payload);
    if (text(widget.guru['type']) != 'manager13f' ||
        text(sim['tone']) == 'muted') {
      return Panel(
        palette: widget.palette,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: Icons.motion_photos_off_rounded,
              kicker: 'COPY SIMULATION',
              title: 'Not copy-tradable',
              palette: widget.palette,
            ),
            const SizedBox(height: 10),
            Text(
              text(
                sim['description'],
                'This profile is not suitable for proportional 13F copy trading.',
              ),
              style: TextStyle(color: widget.palette.muted),
            ),
          ],
        ),
      );
    }

    final equity = asList(_payload?['equity']);
    final summary = asMap(_payload?['summary']);
    return Panel(
      palette: widget.palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.stacked_line_chart_rounded,
            kicker: 'COPY SIMULATION',
            title: isProxy
                ? context.tr('公开持仓代理与 SPY 对比', 'Public sleeve proxy vs SPY')
                : 'Portfolio vs SPY',
            palette: widget.palette,
          ),
          const SizedBox(height: 12),
          if (_loading && _payload == null)
            const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && _payload == null)
            EmptyState(text: _error!, palette: widget.palette)
          else if (!_isDisplayableBacktest(_payload))
            _StrictReplicationUnavailableNotice(
              payload: _payload,
              palette: widget.palette,
            )
          else ...[
            GridWrap(
              minTileWidth: 120,
              spacing: 8,
              children: [
                MiniMetric(
                  'Total',
                  formatReturn(number(summary['totalReturn'])),
                  Icons.trending_up_rounded,
                  widget.palette,
                ),
                MiniMetric(
                  'SPY',
                  formatReturn(
                    number(asMap(summary['benchmark'])['totalReturn']),
                  ),
                  Icons.show_chart_rounded,
                  widget.palette,
                ),
                MiniMetric(
                  'Sharpe',
                  number(summary['sharpe']).toStringAsFixed(2),
                  Icons.speed_rounded,
                  widget.palette,
                ),
                MiniMetric(
                  'MDD',
                  formatReturn(number(summary['maxDrawdown'])),
                  Icons.arrow_downward_rounded,
                  widget.palette,
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: EquityChart(equity: equity, palette: widget.palette),
            ),
            if (isProxy) ...[
              const SizedBox(height: 8),
              _PublicHoldingsProxyNotice(
                payload: _payload,
                palette: widget.palette,
                noticeKey: const ValueKey('guru-preview-proxy-notice'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class EquityChart extends StatefulWidget {
  const EquityChart({
    super.key,
    required this.equity,
    required this.palette,
    this.onPointSelected,
  });

  final List<Map<String, dynamic>> equity;
  final Palette palette;
  final ValueChanged<Map<String, dynamic>>? onPointSelected;

  @override
  State<EquityChart> createState() => _EquityChartState();
}

class _EquityChartState extends State<EquityChart> {
  int? _hoverIndex;
  int? _selectedIndex;

  @override
  void didUpdateWidget(covariant EquityChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_hoverIndex != null && _hoverIndex! >= widget.equity.length) {
      _hoverIndex = null;
    }
    if (_selectedIndex != null && _selectedIndex! >= widget.equity.length) {
      _selectedIndex = null;
    }
  }

  int? _indexForPosition(Offset position, double width) {
    if (widget.equity.length < 2 || width <= 0) return null;
    final left = EquityPainter.horizontalInset;
    final right = math.max(left + 1, width - EquityPainter.horizontalInset);
    final ratio = ((position.dx - left) / (right - left)).clamp(0.0, 1.0);
    return (ratio * (widget.equity.length - 1)).round();
  }

  void _updateHover(Offset position, double width) {
    final next = _indexForPosition(position, width);
    if (next == null) return;
    if (next == _hoverIndex) return;
    setState(() => _hoverIndex = next);
  }

  void _selectPoint(Offset position, double width) {
    final next = _indexForPosition(position, width);
    if (next == null) return;
    setState(() => _selectedIndex = next);
    widget.onPointSelected?.call(widget.equity[next]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.equity.length < 2) {
      return EmptyState(
        text: 'No equity curve available.',
        palette: widget.palette,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return Semantics(
          image: true,
          label: context.tr(
            '组合与基准权益曲线，共 ${widget.equity.length} 个数据点，可触摸选择。',
            'Portfolio and benchmark equity curves with ${widget.equity.length} points; touch to select.',
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            onHover: (event) =>
                _updateHover(event.localPosition, constraints.maxWidth),
            onExit: (_) {
              if (_hoverIndex != null) setState(() => _hoverIndex = null);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _selectPoint(details.localPosition, constraints.maxWidth),
              onPanDown: (details) =>
                  _updateHover(details.localPosition, constraints.maxWidth),
              onPanUpdate: (details) =>
                  _updateHover(details.localPosition, constraints.maxWidth),
              child: CustomPaint(
                painter: EquityPainter(
                  equity: widget.equity,
                  palette: widget.palette,
                  hoverIndex: _hoverIndex ?? _selectedIndex,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

class EquityPainter extends CustomPainter {
  EquityPainter({
    required this.equity,
    required this.palette,
    required this.hoverIndex,
  });

  static const horizontalInset = 8.0;
  static const topInset = 12.0;
  static const bottomInset = 22.0;

  final List<Map<String, dynamic>> equity;
  final Palette palette;
  final int? hoverIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final left = horizontalInset;
    final right = size.width - horizontalInset;
    final top = topInset;
    final bottom = size.height - bottomInset;
    final values = equity
        .expand<double>(
          (point) => [number(point['value']), number(point['benchmark'])],
        )
        .where((value) => value > 0)
        .toList();
    if (values.isEmpty) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final span = math.max(.0001, maxValue - minValue);

    double xForIndex(int index) =>
        left + (right - left) * index / (equity.length - 1);

    double yForValue(double value) =>
        bottom - ((value - minValue) / span) * (bottom - top);

    final gridPaint = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i += 1) {
      final y = top + (bottom - top) * i / 3;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }

    Path pathFor(String key) {
      final path = Path();
      for (var i = 0; i < equity.length; i += 1) {
        final x = xForIndex(i);
        final y = yForValue(number(equity[i][key]));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    canvas.drawPath(
      pathFor('benchmark'),
      Paint()
        ..color = palette.secondary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    canvas.drawPath(
      pathFor('value'),
      Paint()
        ..color = palette.positive
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    final labelStyle = TextStyle(
      color: palette.faint,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    final start = formatDate(text(equity.first['date']));
    final end = formatDate(text(equity.last['date']));
    _drawText(
      canvas,
      start,
      Offset(left, bottom + 7),
      labelStyle,
      TextAlign.left,
    );
    _drawText(
      canvas,
      end,
      Offset(right - 76, bottom + 7),
      labelStyle,
      TextAlign.right,
    );

    final selectedIndex = hoverIndex;
    if (selectedIndex != null &&
        selectedIndex >= 0 &&
        selectedIndex < equity.length) {
      final point = equity[selectedIndex];
      final x = xForIndex(selectedIndex);
      final valueOffset = Offset(x, yForValue(number(point['value'])));
      final benchmarkOffset = Offset(x, yForValue(number(point['benchmark'])));
      _drawHover(
        canvas,
        size,
        top,
        bottom,
        valueOffset,
        benchmarkOffset,
        point,
      );
    }
  }

  void _drawHover(
    Canvas canvas,
    Size size,
    double top,
    double bottom,
    Offset valueOffset,
    Offset benchmarkOffset,
    Map<String, dynamic> point,
  ) {
    final crosshairPaint = Paint()
      ..color = palette.muted.withValues(alpha: .38)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(valueOffset.dx, top),
      Offset(valueOffset.dx, bottom),
      crosshairPaint,
    );

    void marker(Offset offset, Color color) {
      canvas.drawCircle(
        offset,
        7,
        Paint()..color = color.withValues(alpha: .16),
      );
      canvas.drawCircle(offset, 4.5, Paint()..color = color);
      canvas.drawCircle(
        offset,
        4.5,
        Paint()
          ..color = palette.panel
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    marker(benchmarkOffset, palette.secondary);
    marker(valueOffset, palette.positive);

    const tooltipWidth = 184.0;
    const tooltipHeight = 96.0;
    var tooltipLeft = valueOffset.dx + 14;
    if (tooltipLeft + tooltipWidth > size.width - 6) {
      tooltipLeft = valueOffset.dx - tooltipWidth - 14;
    }
    final maxLeft = math.max(6.0, size.width - tooltipWidth - 6);
    tooltipLeft = tooltipLeft.clamp(6.0, maxLeft).toDouble();

    var tooltipTop = valueOffset.dy - tooltipHeight / 2;
    final maxTop = math.max(6.0, size.height - tooltipHeight - 6);
    tooltipTop = tooltipTop.clamp(6.0, maxTop).toDouble();

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tooltipLeft, tooltipTop, tooltipWidth, tooltipHeight),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = palette.card.withValues(alpha: .96),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = palette.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final date = formatDate(text(point['date']));
    final portfolioReturn = formatReturn(number(point['value']) - 1);
    final benchmarkReturn = formatReturn(number(point['benchmark']) - 1);
    final excessReturn = formatReturn(
      number(point['value']) - number(point['benchmark']),
    );
    final x = tooltipLeft + 12;
    final y = tooltipTop + 10;
    _drawText(
      canvas,
      date,
      Offset(x, y),
      TextStyle(color: palette.text, fontSize: 12, fontWeight: FontWeight.w900),
      TextAlign.left,
      maxWidth: tooltipWidth - 24,
    );
    _drawTooltipRow(canvas, tooltipLeft, y + 24, 'Portfolio', portfolioReturn);
    _drawTooltipRow(canvas, tooltipLeft, y + 46, 'SPY', benchmarkReturn);
    _drawTooltipRow(canvas, tooltipLeft, y + 68, 'Excess', excessReturn);
  }

  void _drawTooltipRow(
    Canvas canvas,
    double left,
    double top,
    String label,
    String value,
  ) {
    _drawText(
      canvas,
      label,
      Offset(left + 12, top),
      TextStyle(
        color: palette.muted,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
      TextAlign.left,
      maxWidth: 86,
    );
    _drawText(
      canvas,
      value,
      Offset(left + 98, top),
      TextStyle(color: palette.text, fontSize: 11, fontWeight: FontWeight.w900),
      TextAlign.right,
      maxWidth: 74,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style,
    TextAlign align, {
    double maxWidth = 90,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant EquityPainter oldDelegate) =>
      oldDelegate.equity != equity ||
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.palette.colorBlind != palette.colorBlind;
}

class OperationRow extends StatelessWidget {
  const OperationRow({
    super.key,
    required this.row,
    required this.manager,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final bool manager;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final action = text(row['action']);
    final positive = ['new', 'increased', 'buy'].contains(action);
    final negative = ['reduced', 'sold_out', 'sell'].contains(action);
    final ticker = text(row['ticker'], compactName(text(row['issuer'])));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 42,
            decoration: BoxDecoration(
              color: positive
                  ? palette.positive
                  : negative
                  ? palette.negative
                  : palette.muted,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ticker,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  actionLabel(action, context.language),
                  style: TextStyle(
                    color: positive
                        ? palette.positive
                        : negative
                        ? palette.negative
                        : palette.muted,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                manager
                    ? formatMoney(
                        number(row['value']) + number(row['previousValue']),
                      )
                    : formatMoney(
                        number(row['value']) + number(row['notional']),
                      ),
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                manager
                    ? formatNumber(number(row['changeShares']).abs())
                    : formatDate(
                        text(row['transactionDate'], text(row['filingDate'])),
                      ),
                style: TextStyle(color: palette.faint, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class HoldingRow extends StatelessWidget {
  const HoldingRow({
    super.key,
    required this.holding,
    required this.total,
    required this.palette,
  });

  final Map<String, dynamic> holding;
  final double total;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final value = number(holding['value']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StockResearchButton(
                  ticker: text(
                    holding['ticker'],
                    compactName(text(holding['issuer'])),
                  ),
                  palette: palette,
                  sourceDate: text(holding['reportDate']),
                  available: truthy(
                    marketLensPublicTradingMetadata([
                      holding,
                    ])['publicReplicable'],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  compactName(text(holding['issuer'])),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 70,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: total <= 0 ? 0 : math.max(.04, value / total),
                minHeight: 8,
                backgroundColor: palette.border,
                color: palette.accent,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatMoney(value),
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class SecondaryDashboard extends StatelessWidget {
  const SecondaryDashboard({
    super.key,
    required this.mode,
    required this.api,
    required this.data,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onRefresh,
    required this.initialValuationTicker,
    required this.onValuationTickerChanged,
  });

  final String mode;
  final ApiClient api;
  final Map<String, dynamic>? data;
  final bool loading;
  final String? error;
  final Palette palette;
  final Future<void> Function() onRefresh;
  final String initialValuationTicker;
  final ValueChanged<String> onValuationTickerChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading && data == null)
            Panel(
              palette: palette,
              child: const SizedBox(
                height: 420,
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (data == null)
            Panel(
              palette: palette,
              child: error == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        EmptyState(
                          text: context.tr(
                            '当前页面数据还没有载入。',
                            'Data has not loaded yet.',
                          ),
                          palette: palette,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => unawaited(onRefresh()),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(
                            context.tr('重新载入当前页面数据', 'Load current page data'),
                          ),
                        ),
                      ],
                    )
                  : ErrorCard(
                      message: error!.replaceFirst('Exception: ', ''),
                      onRetry: () => unawaited(onRefresh()),
                    ),
            )
          else ...[
            if (loading || error != null) ...[
              InlineDataBanner(
                loading: loading,
                error: error,
                palette: palette,
                onRetry: () => unawaited(onRefresh()),
              ),
              const SizedBox(height: 10),
            ],
            switch (mode) {
              'portfolio' => PortfolioDashboard(
                data: data!,
                api: api,
                palette: palette,
                onRefresh: onRefresh,
              ),
              'admin' => AdminPortfolioDashboard(
                data: data!,
                api: api,
                palette: palette,
                onRefresh: onRefresh,
              ),
              _ => ValuationCompactDashboard(
                data: data!,
                api: api,
                palette: palette,
                initialTicker: initialValuationTicker,
                onTickerChanged: onValuationTickerChanged,
              ),
            },
          ],
        ],
      ),
    );
  }
}

class InlineDataBanner extends StatelessWidget {
  const InlineDataBanner({
    super.key,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final Palette palette;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = error?.trim().isNotEmpty ?? false;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: (failed ? palette.negative : palette.secondary).withValues(
            alpha: .10,
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: (failed ? palette.negative : palette.secondary).withValues(
              alpha: .35,
            ),
          ),
        ),
        child: Row(
          children: [
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.warning_amber_rounded, color: palette.negative),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                failed
                    ? context.tr(
                        '刷新失败，已保留上一版可用内容。${error!.replaceFirst('Exception: ', '')}',
                        'Refresh failed; the previous usable content is preserved. ${error!.replaceFirst('Exception: ', '')}',
                      )
                    : context.tr(
                        '正在刷新，当前仍显示上一版内容。',
                        'Refreshing; the previous content remains visible.',
                      ),
                style: TextStyle(color: palette.text, fontSize: 12),
              ),
            ),
            if (failed)
              TextButton(
                onPressed: onRetry,
                child: Text(context.tr('重试', 'Retry')),
              ),
          ],
        ),
      ),
    );
  }
}

class SecondaryModeHeader extends StatelessWidget {
  const SecondaryModeHeader({
    super.key,
    required this.icon,
    required this.kicker,
    required this.title,
    required this.subtitle,
    required this.metrics,
    required this.palette,
    this.chips = const [],
  });

  final IconData icon;
  final String kicker;
  final String title;
  final String subtitle;
  final List<Widget> metrics;
  final List<String> chips;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Panel(
      palette: palette,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Five portfolio/secondary metrics need more room than the global
          // navigation breakpoint.  Stack them before the identity copy starts
          // truncating at common 1024px terminal widths.
          final compact =
              constraints.maxWidth < (metrics.length >= 5 ? 1200 : 820);
          final identity = Row(
            children: [
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: palette.accent.withValues(alpha: .28),
                  ),
                ),
                child: Icon(icon, color: palette.accent, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      context.ui(kicker),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.ui(title),
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: compact ? 19 : 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.ui(subtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (chips.isNotEmpty) ...[
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          for (final chip in chips)
                            InfoChip(context.ui(chip), palette: palette),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );

          if (compact || metrics.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                if (metrics.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  GridWrap(minTileWidth: 160, spacing: 10, children: metrics),
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: math.min(430, constraints.maxWidth * .34),
                child: identity,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      for (var i = 0; i < metrics.length; i += 1) ...[
                        Expanded(child: metrics[i]),
                        if (i != metrics.length - 1)
                          VerticalDivider(color: palette.border, width: 24),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class AdminPortfolioDashboard extends StatefulWidget {
  const AdminPortfolioDashboard({
    super.key,
    required this.data,
    required this.api,
    required this.palette,
    required this.onRefresh,
  });

  final Map<String, dynamic> data;
  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onRefresh;

  @override
  State<AdminPortfolioDashboard> createState() =>
      _AdminPortfolioDashboardState();
}

class _AdminPortfolioDashboardState extends State<AdminPortfolioDashboard> {
  String _selectedHash = '';
  String _search = '';
  bool _loadingDetail = false;
  bool _loadingHealth = false;
  String? _detailError;
  String? _healthError;
  Map<String, dynamic>? _detail;
  Map<String, dynamic>? _health;

  List<Map<String, dynamic>> get _users =>
      [...asList(widget.data['users'])]..sort(compareAdminUserLastSignIn);

  @override
  void initState() {
    super.initState();
    unawaited(_loadHealth());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSelection(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant AdminPortfolioDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.data, oldWidget.data)) {
      _syncSelection();
    }
  }

  void _syncSelection({bool force = false}) {
    final users = _users;
    if (users.isEmpty) {
      setState(() {
        _selectedHash = '';
        _detail = null;
        _detailError = null;
      });
      return;
    }
    final selectedExists = users.any(
      (user) => text(user['userHash']) == _selectedHash,
    );
    if (!force && selectedExists && _selectedHash.isNotEmpty) return;
    final nextHash = text(users.first['userHash']);
    if (nextHash.isEmpty || nextHash == _selectedHash) return;
    setState(() {
      _selectedHash = nextHash;
      _detail = null;
      _detailError = null;
    });
    unawaited(_loadDetail(nextHash));
  }

  Future<void> _loadDetail([String? hash, bool refresh = false]) async {
    final targetHash = hash ?? _selectedHash;
    if (targetHash.isEmpty) return;
    setState(() {
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final payload = await widget.api.getJson(
        '/api/admin/portfolio-users/$targetHash${refresh ? '?refresh=1' : ''}',
      );
      if (!mounted || targetHash != _selectedHash) return;
      setState(() => _detail = payload);
    } catch (error) {
      if (!mounted || targetHash != _selectedHash) return;
      setState(() => _detailError = error.toString());
    } finally {
      if (mounted && targetHash == _selectedHash) {
        setState(() => _loadingDetail = false);
      }
    }
  }

  Future<void> _loadHealth() async {
    setState(() {
      _loadingHealth = true;
      _healthError = null;
    });
    try {
      final payload = await widget.api.getJson('/api/admin/system-health');
      if (!mounted) return;
      setState(() => _health = payload);
    } catch (error) {
      if (!mounted) return;
      setState(() => _healthError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingHealth = false);
    }
  }

  void _selectUser(String hash) {
    if (hash.isEmpty || hash == _selectedHash) return;
    setState(() {
      _selectedHash = hash;
      _detail = null;
      _detailError = null;
    });
    unawaited(_loadDetail(hash));
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final summary = asMap(widget.data['summary']);
    final users = _users;
    final needle = _search.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? users
        : users.where((user) {
            final haystack = [
              user['email'],
              user['name'],
              user['userHash'],
              asMap(user['connection'])['status'],
            ].map(text).join(' ').toLowerCase();
            return haystack.contains(needle);
          }).toList();

    return Column(
      children: [
        SecondaryModeHeader(
          icon: Icons.admin_panel_settings_rounded,
          kicker: 'OWNER ADMIN',
          title: 'Portfolio admin console',
          subtitle:
              'View all user-scoped IBKR/Yodlee portfolio databases in read-only mode.',
          chips: const [
            'owner only',
            'read-only detail',
            'encrypted tokens hidden',
          ],
          metrics: [
            _GuruHeaderMetric(
              label: 'Users',
              value: formatNumber(number(summary['users'])),
              sub: '${formatNumber(number(summary['linked']))} linked',
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: 'Accounts',
              value: formatNumber(number(summary['accounts'])),
              sub: 'IBKR/Yodlee saved',
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: 'Latest NAV',
              value: formatMoney(number(summary['latestNav'])),
              sub: 'sum of latest stored NAV',
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: 'Errors',
              value: formatNumber(number(summary['errors'])),
              sub: 'sync or decrypt issues',
              palette: palette,
            ),
          ],
          palette: palette,
        ),
        const SizedBox(height: 10),
        AdminUserDirectoryPanel(
          users: filtered,
          selectedHash: _selectedHash,
          search: _search,
          palette: palette,
          onSearch: (value) => setState(() => _search = value),
          onSelect: _selectUser,
          onRefresh: () async {
            await Future.wait([widget.onRefresh(), _loadHealth()]);
            _syncSelection(force: _selectedHash.isEmpty);
          },
        ),
        const SizedBox(height: 10),
        _AdminPortfolioDetailPanel(
          detail: _detail,
          loading: _loadingDetail,
          error: _detailError,
          selectedHash: _selectedHash,
          api: widget.api,
          palette: palette,
          onRefresh: () => _loadDetail(_selectedHash, true),
        ),
        const SizedBox(height: 10),
        _AdminSystemHealthPanel(
          data: _health,
          loading: _loadingHealth,
          error: _healthError,
          palette: palette,
          onRefresh: _loadHealth,
        ),
      ],
    );
  }
}

class _AdminSystemHealthPanel extends StatelessWidget {
  const _AdminSystemHealthPanel({
    required this.data,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onRefresh,
  });

  final Map<String, dynamic>? data;
  final bool loading;
  final String? error;
  final Palette palette;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final payload = data ?? const <String, dynamic>{};
    final status = text(payload['status'], loading ? 'running' : 'unknown');
    final database = asMap(payload['database']);
    final service = asMap(payload['service']);
    final auth = asMap(payload['auth']);
    final portfolio = asMap(payload['portfolio']);
    final portfolioSummary = asMap(portfolio['summary']);
    final jobs = asList(payload['jobs']);
    final issueCount = jobs
        .where(
          (job) =>
              {'failed', 'warning', 'unknown'}.contains(text(job['status'])),
        )
        .length;
    final statusColor = _adminHealthColor(status, palette);

    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.monitor_heart_rounded,
            kicker: 'SYSTEM HEALTH',
            title: context.tr('系统健康与数据任务', 'System Health'),
            palette: palette,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BadgeLabel(
                  text: _adminHealthLabel(status, context.language),
                  color: statusColor,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: context.ui('Refresh health'),
                  onPressed: loading ? null : () => unawaited(onRefresh()),
                  icon: loading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.accent,
                          ),
                        )
                      : Icon(Icons.refresh_rounded, color: palette.accent),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (error != null && data == null)
            PortfolioDataNotice(
              icon: Icons.warning_amber_rounded,
              text: error!,
              palette: palette,
            )
          else ...[
            GridWrap(
              minTileWidth: 150,
              spacing: 10,
              children: [
                MiniMetric(
                  'API',
                  _adminHealthLabel(status, context.language),
                  Icons.cloud_done_rounded,
                  palette,
                ),
                MiniMetric(
                  'SQLite',
                  _formatBytes(number(database['sizeBytes'])),
                  Icons.storage_rounded,
                  palette,
                ),
                MiniMetric(
                  'Data jobs',
                  issueCount == 0 ? '${jobs.length} OK' : '$issueCount issue',
                  Icons.task_alt_rounded,
                  palette,
                ),
                MiniMetric(
                  'Users',
                  formatNumber(number(portfolioSummary['users'])),
                  Icons.people_alt_rounded,
                  palette,
                ),
                MiniMetric(
                  'Uptime',
                  _formatDuration(
                    number(service['uptimeSeconds']),
                    context.language,
                  ),
                  Icons.av_timer_rounded,
                  palette,
                ),
                MiniMetric(
                  'Origins',
                  formatNumber(number(auth['allowedOriginCount'])),
                  Icons.public_rounded,
                  palette,
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (text(database['updatedAt']).isNotEmpty)
              Text(
                context.tr(
                  '数据库更新于 ${_formatAdminDateTime(text(database['updatedAt']))} · '
                      '${text(service['environment'], '环境未知')} · '
                      '${text(auth['apiCorsConfigured']) == 'true' ? 'CORS 正常' : '检查 CORS'}',
                  'DB updated ${_formatAdminDateTime(text(database['updatedAt']))} · '
                      '${text(service['environment'], 'env unknown')} · '
                      '${text(auth['apiCorsConfigured']) == 'true' ? 'CORS ok' : 'check CORS'}',
                ),
                style: TextStyle(
                  color: palette.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            const SizedBox(height: 12),
            if (jobs.isEmpty)
              EmptyState(
                text: loading
                    ? 'Loading system health...'
                    : 'No background jobs were reported yet.',
                palette: palette,
              )
            else
              GridWrap(
                minTileWidth: 260,
                spacing: 10,
                children: [
                  for (final job in jobs)
                    _AdminJobHealthTile(job: job, palette: palette),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _AdminJobHealthTile extends StatelessWidget {
  const _AdminJobHealthTile({required this.job, required this.palette});

  final Map<String, dynamic> job;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final status = text(job['status'], 'unknown');
    final color = _adminHealthColor(status, palette);
    final details = asMap(job['details']);
    final detailPieces = <String>[
      if (number(details['rows']) > 0)
        context.tr(
          '${formatNumber(number(details['rows']))} 行',
          '${formatNumber(number(details['rows']))} rows',
        ),
      if (number(details['tickerRows']) > 0)
        context.tr(
          '${formatNumber(number(details['tickerRows']))} 只股票',
          '${formatNumber(number(details['tickerRows']))} tickers',
        ),
      if (number(details['eventCount']) > 0)
        context.tr(
          '${formatNumber(number(details['eventCount']))} 个事件',
          '${formatNumber(number(details['eventCount']))} events',
        ),
      if (number(details['holdings']) > 0)
        context.tr(
          '${formatNumber(number(details['holdings']))} 项持仓',
          '${formatNumber(number(details['holdings']))} holdings',
        ),
      if (text(details['latestBacktestEndDate']).isNotEmpty)
        context.tr(
          '截至 ${formatDate(text(details['latestBacktestEndDate']))}',
          'through ${formatDate(text(details['latestBacktestEndDate']))}',
        ),
      if (text(details['maxExDate']).isNotEmpty)
        context.tr(
          '截至 ${formatDate(text(details['maxExDate']))}',
          'through ${formatDate(text(details['maxExDate']))}',
        ),
      if (text(details['observedThrough']).isNotEmpty)
        context.tr(
          '截至 ${formatDate(text(details['observedThrough']))}',
          'through ${formatDate(text(details['observedThrough']))}',
        ),
    ];
    final message = text(job['message']);
    final finishedAt = text(job['finishedAt']);

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.ui(text(job['label'], text(job['id'], 'Job'))),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _AdminTinyChip(
                _adminHealthLabel(status, context.language),
                color,
                palette,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            finishedAt.isEmpty
                ? context.ui('No completed run')
                : context.tr(
                    '最近运行 ${_formatAdminDateTime(finishedAt)}',
                    'Last ${_formatAdminDateTime(finishedAt)}',
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.muted,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          if (detailPieces.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              detailPieces.take(3).join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.secondary,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
          if (message.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              context.ui(message),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: status == 'failed' ? palette.negative : palette.muted,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Color _adminHealthColor(String status, Palette palette) {
  final normalized = status.toLowerCase();
  if (normalized == 'success' || normalized == 'ok') return palette.positive;
  if (normalized == 'running') return palette.accent;
  if (normalized == 'warning' || normalized == 'unknown') {
    return palette.secondary;
  }
  return palette.negative;
}

String _adminHealthLabel(
  String status, [
  AppLanguage language = AppLanguage.en,
]) {
  final normalized = status.toLowerCase();
  if (normalized == 'success' || normalized == 'ok') {
    return trFor(language, '健康', 'healthy');
  }
  if (normalized == 'running') return trFor(language, '运行中', 'running');
  if (normalized == 'warning') return trFor(language, '观察', 'watch');
  if (normalized == 'failed' || normalized == 'error') {
    return trFor(language, '失败', 'failed');
  }
  return trFor(language, '未知', 'unknown');
}

String _formatBytes(double bytes) {
  if (!bytes.isFinite || bytes <= 0) return '0 B';
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(2)} GB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  if (bytes >= 1e3) return '${(bytes / 1e3).toStringAsFixed(1)} KB';
  return '${bytes.toStringAsFixed(0)} B';
}

String _formatDuration(
  double seconds, [
  AppLanguage language = AppLanguage.en,
]) {
  if (!seconds.isFinite || seconds <= 0) return '-';
  final duration = Duration(seconds: seconds.round());
  if (duration.inDays > 0) {
    return trFor(language, '${duration.inDays} 天', '${duration.inDays}d');
  }
  if (duration.inHours > 0) {
    return trFor(language, '${duration.inHours} 小时', '${duration.inHours}h');
  }
  if (duration.inMinutes > 0) {
    return trFor(
      language,
      '${duration.inMinutes} 分钟',
      '${duration.inMinutes}m',
    );
  }
  return trFor(language, '${duration.inSeconds} 秒', '${duration.inSeconds}s');
}

String _formatAdminDateTime(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return formatDate(value);
  final local = date.toLocal();
  return '${formatDate(local.toIso8601String())} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String adminUserPortfolioRegistration(Map<String, dynamic> user) {
  final explicit = text(user['portfolioRegistration']);
  if (const {'registered', 'not_registered', 'unknown'}.contains(explicit)) {
    return explicit;
  }
  final connection = asMap(user['connection']);
  if (connection['registered'] == true ||
      connection['configured'] == true ||
      number(connection['accountCount']) > 0) {
    return 'registered';
  }
  return connection['status'] == 'read_error' ? 'unknown' : 'not_registered';
}

int compareAdminUserLastSignIn(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  int time(Map<String, dynamic> user) =>
      DateTime.tryParse(text(user['lastSignInAt']))?.millisecondsSinceEpoch ??
      0;
  final delta = time(right).compareTo(time(left));
  if (delta != 0) return delta;
  return text(
    left['email'],
    text(left['userHash']),
  ).compareTo(text(right['email'], text(right['userHash'])));
}

class AdminUserDirectoryPanel extends StatelessWidget {
  const AdminUserDirectoryPanel({
    super.key,
    required this.users,
    required this.selectedHash,
    required this.search,
    required this.palette,
    required this.onSearch,
    required this.onSelect,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> users;
  final String selectedHash;
  final String search;
  final Palette palette;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ordered = [...users]..sort(compareAdminUserLastSignIn);
    final registered = ordered
        .where((user) => adminUserPortfolioRegistration(user) == 'registered')
        .toList();
    final unregistered = ordered
        .where(
          (user) => adminUserPortfolioRegistration(user) == 'not_registered',
        )
        .toList();
    final unknown = ordered
        .where((user) => adminUserPortfolioRegistration(user) == 'unknown')
        .toList();

    Widget group(String id, String title, List<Map<String, dynamic>> rows) {
      return Column(
        key: ValueKey('admin-users-$id'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title (${rows.length})',
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                context.tr('暂无匹配用户', 'No matching users'),
                style: TextStyle(color: palette.muted),
              ),
            )
          else
            SizedBox(
              height: math.min(460.0, rows.length * 220.0),
              child: ListView.separated(
                key: ValueKey('admin-user-list-$id-$search'),
                primary: false,
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  final user = rows[index];
                  return _AdminUserTile(
                    key: ValueKey('admin-user-${text(user['userHash'])}'),
                    user: user,
                    selected: text(user['userHash']) == selectedHash,
                    palette: palette,
                    onTap: () => onSelect(text(user['userHash'])),
                  );
                },
              ),
            ),
        ],
      );
    }

    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.people_alt_rounded,
            kicker: context.tr('仅管理员可见', 'ADMIN ONLY'),
            title: context.tr('用户与上次登录', 'Users & last sign-in'),
            palette: palette,
            trailing: IconButton(
              key: const ValueKey('admin-users-refresh'),
              tooltip: context.ui('Refresh admin index'),
              onPressed: () => unawaited(onRefresh()),
              icon: Icon(Icons.refresh_rounded, color: palette.accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              '上次登录 ↓ 最新在前 · 未记录的排在最后 · ${adminLoginTimezone()}',
              'Last sign-in ↓ Newest first · Unknown times last · ${adminLoginTimezone()}',
            ),
            style: TextStyle(color: palette.accent, fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const ValueKey('admin-users-search'),
            initialValue: search,
            onChanged: onSearch,
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search_rounded, color: palette.muted),
              hintText: context.ui('Search email / name / hash'),
              hintStyle: TextStyle(color: palette.faint),
              filled: true,
              fillColor: palette.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.accent),
              ),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final yes = group(
                'registered',
                context.tr('已注册组合', 'Portfolio registered'),
                registered,
              );
              final no = group(
                'not_registered',
                context.tr('未注册组合', 'No portfolio registered'),
                unregistered,
              );
              if (constraints.maxWidth < 760) {
                return Column(children: [yes, const SizedBox(height: 18), no]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: yes),
                  const SizedBox(width: 16),
                  Expanded(child: no),
                ],
              );
            },
          ),
          if (unknown.isNotEmpty) ...[
            const SizedBox(height: 16),
            group(
              'unknown',
              context.tr(
                '组合状态读取失败，待核查',
                'Portfolio status unavailable — needs review',
              ),
              unknown,
            ),
          ],
          const SizedBox(height: 10),
          Text(
            context.tr(
              '按是否保存组合连接分组，连接失败仍算已注册。仅显示平台已识别的账号和已存组合，并非全部认证平台注册用户。上次登录来自已验证认证记录；访问、同步和令牌续期不会补造登录时间。',
              'Grouped by saved portfolio connection; failed connections still count as registered. Includes accounts observed by the platform and saved portfolios, not all Auth registrations. Sign-in times come from verified auth records, never visits, syncs or token refreshes.',
            ),
            style: TextStyle(color: palette.faint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AdminUserTile extends StatelessWidget {
  const _AdminUserTile({
    super.key,
    required this.user,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> user;
  final bool selected;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final connection = asMap(user['connection']);
    final nav = asMap(user['nav']);
    final status = text(connection['status'], 'not configured');
    final email = text(user['email']);
    final name = text(
      user['name'],
      email.isEmpty ? context.ui('Unknown user') : email,
    );
    final hash = text(user['userHash']);
    final tone = status == 'linked'
        ? palette.positive
        : status.contains('error')
        ? palette.negative
        : palette.secondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: .13)
              : palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? palette.accent.withValues(alpha: .5)
                : palette.border,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: .14),
                shape: BoxShape.circle,
                border: Border.all(color: tone.withValues(alpha: .36)),
              ),
              child: Icon(Icons.person_rounded, color: tone, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email.isEmpty
                        ? context.tr(
                            '哈希 ${shortText(hash, 10)}',
                            'hash ${shortText(hash, 10)}',
                          )
                        : email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr('上次登录：', 'Last sign-in: ') +
                        (DateTime.tryParse(text(user['lastSignInAt'])) == null
                            ? context.tr('未记录', 'Not recorded')
                            : adminLoginDateTime(text(user['lastSignInAt']))),
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.tr('最近访问：', 'Last activity: ') +
                        adminLoginDateTime(text(user['lastSeenAt'])),
                    style: TextStyle(color: palette.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _AdminTinyChip(status, tone, palette),
                      _AdminTinyChip(
                        context.tr(
                          '${formatNumber(number(connection['accountCount']))} 个账户',
                          '${formatNumber(number(connection['accountCount']))} accts',
                        ),
                        palette.secondary,
                        palette,
                      ),
                      if (text(nav['latestDate']).isNotEmpty)
                        _AdminTinyChip(
                          formatDate(text(nav['latestDate'])),
                          palette.muted,
                          palette,
                        ),
                      if (number(nav['pointCount']) > 0 ||
                          text(nav['latestDate']).isNotEmpty)
                        _AdminTinyChip(
                          formatMoney(number(nav['latestValue'])),
                          palette.text,
                          palette,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminTinyChip extends StatelessWidget {
  const _AdminTinyChip(this.label, this.color, this.palette);

  final String label;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Text(
        context.ui(label),
        style: TextStyle(
          color: color == palette.muted ? palette.muted : color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _AdminPortfolioDetailPanel extends StatelessWidget {
  const _AdminPortfolioDetailPanel({
    required this.detail,
    required this.loading,
    required this.error,
    required this.selectedHash,
    required this.api,
    required this.palette,
    required this.onRefresh,
  });

  final Map<String, dynamic>? detail;
  final bool loading;
  final String? error;
  final String selectedHash;
  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (selectedHash.isEmpty) {
      return Panel(
        palette: palette,
        child: EmptyState(
          text: 'Select a portfolio user to inspect.',
          palette: palette,
        ),
      );
    }
    if (loading && detail == null) {
      return Panel(
        palette: palette,
        child: const SizedBox(
          height: 420,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (error != null && detail == null) {
      return ErrorCard(message: error!, onRetry: () => unawaited(onRefresh()));
    }
    if (detail == null) {
      return Panel(
        palette: palette,
        child: EmptyState(
          text: 'Portfolio detail has not loaded yet.',
          palette: palette,
        ),
      );
    }

    final user = asMap(detail!['user']);
    final portfolio = asMap(detail!['portfolio']);
    final summary = asMap(portfolio['summary']);
    final connection = asMap(user['connection']);
    final title = text(
      user['name'],
      text(user['email'], shortText(selectedHash, 10)),
    );
    return Column(
      children: [
        Panel(
          palette: palette,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PanelTitle(
                icon: Icons.manage_accounts_rounded,
                kicker: 'SELECTED USER',
                title: title,
                palette: palette,
                trailing: FilledButton.icon(
                  onPressed: loading ? null : () => unawaited(onRefresh()),
                  icon: loading
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(context.ui('Refresh detail')),
                ),
              ),
              const SizedBox(height: 12),
              GridWrap(
                minTileWidth: 150,
                spacing: 10,
                children: [
                  MiniMetric(
                    'Email',
                    text(user['email'], context.ui('unknown')),
                    Icons.alternate_email_rounded,
                    palette,
                  ),
                  MiniMetric(
                    'Latest NAV',
                    formatMoney(number(summary['totalValue'])),
                    Icons.account_balance_wallet_rounded,
                    palette,
                  ),
                  MiniMetric(
                    'Holdings',
                    formatNumber(number(summary['holdings'])),
                    Icons.table_rows_rounded,
                    palette,
                  ),
                  MiniMetric(
                    'Status',
                    context.ui(text(connection['status'], 'unknown')),
                    Icons.shield_rounded,
                    palette,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        PortfolioDashboard(
          data: portfolio,
          api: api,
          palette: palette,
          onRefresh: onRefresh,
          readOnly: true,
          readOnlyNotice: context.tr(
            '${text(user['email'], selectedHash)} 的管理员只读视图。凭证仍加密保存在该用户数据库中。',
            'Admin read-only view for ${text(user['email'], selectedHash)}. Credentials remain encrypted in that user database.',
          ),
        ),
      ],
    );
  }
}

bool isSavedPortfolioReport(Map<String, dynamic>? data) =>
    asMap(data?['freshness'])['status'] == 'stale' ||
    asMap(data?['source'])['mode'] == 'saved_broker_report' ||
    truthy(asMap(data?['source'])['stale']) ||
    data?['source'] == 'saved_authenticated_broker_report';

String savedPortfolioReportNotice(
  Map<String, dynamic>? data,
  AppLanguage language,
) {
  final freshness = asMap(data?['freshness']);
  final source = asMap(data?['source']);
  String date(dynamic value) {
    final parsed = DateTime.tryParse(text(value));
    return parsed == null
        ? trFor(language, '日期未记录', 'date not recorded')
        : parsed.toIso8601String().substring(0, 10);
  }

  final report = date(freshness['reportAsOf'] ?? source['asOf']);
  final retrieved = date(freshness['retrievedAt'] ?? source['retrievedAt']);
  return trFor(
    language,
    '券商同步暂不可用。当前显示已保存的 $report 报告（读取于 $retrieved）。持仓、余额和盈亏可能已过时；本次没有完成新的同步。',
    'Broker sync is unavailable. Showing the last saved report dated $report (retrieved $retrieved). Holdings, balances and P&L may be out of date; no new sync completed.',
  );
}

class PortfolioDashboard extends StatelessWidget {
  const PortfolioDashboard({
    super.key,
    required this.data,
    required this.api,
    required this.palette,
    required this.onRefresh,
    this.readOnly = false,
    this.readOnlyNotice,
  });

  final Map<String, dynamic> data;
  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onRefresh;
  final bool readOnly;
  final String? readOnlyNotice;

  @override
  Widget build(BuildContext context) {
    final summary = asMap(data['summary']);
    final connection = asMap(data['connection']);
    final accounts = asList(data['accounts']);
    final holdings = asList(data['holdings']);
    final sectors = asList(data['sectors']);
    final performance = asList(data['performance']);
    final performanceStatus = asMap(data['performanceStatus']);
    final dividends = asList(data['dividends']);
    final dividendStatus = asMap(data['dividendStatus']);
    final analytics = asMap(data['analytics']);
    final configured = truthy(connection['configured']);
    final registered = truthy(connection['registered']) || configured;
    final dayPnl = number(summary['dayPnl']);
    final unrealizedPnl = number(summary['unrealizedPnl']);
    final tone = dayPnl >= 0 ? palette.positive : palette.negative;
    final realPerformance = truthy(performanceStatus['real']);
    final source = asMap(data['source']);
    final savedReport = isSavedPortfolioReport(data);
    final sampleMode =
        text(source['mode']).toLowerCase() == 'sample' ||
        accounts.any(
          (account) => text(account['status']).toLowerCase() == 'sample',
        );

    final dashboard = Column(
      children: [
        SecondaryModeHeader(
          icon: Icons.account_balance_wallet_rounded,
          kicker: 'PORTFOLIO MANAGEMENT',
          title: sampleMode
              ? 'Sample portfolio — not an account'
              : savedReport
              ? 'Saved portfolio report'
              : 'Portfolio cockpit',
          subtitle: sampleMode
              ? 'Illustrative local data only. It is not connected to your brokerage account.'
              : savedReport
              ? context.tr(
                  '券商同步暂不可用，下方数据来自上次保存的报告。',
                  'Broker sync is unavailable. Values below are from the last saved report.',
                )
              : configured
              ? text(
                  connection['message'],
                  'IBKR holdings synced through Yodlee.',
                )
              : 'Yodlee / IBKR connector is ready; credentials are not configured yet.',
          chips: [
            if (sampleMode)
              'SAMPLE DATA · NOT AN ACCOUNT'
            else ...[
              text(connection['provider'], 'Yodlee'),
              text(connection['institution'], 'Interactive Brokers'),
              text(
                connection['status'],
                configured ? 'linked' : 'not configured',
              ),
            ],
          ],
          metrics: [
            _GuruHeaderMetric(
              label: sampleMode ? 'Sample total' : 'Net liquidation',
              value: formatMoney(number(summary['totalValue'])),
              sub: '${formatNumber(number(summary['accounts']))} accounts',
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: sampleMode
                  ? 'Sample day P/L'
                  : savedReport
                  ? 'Report day P/L'
                  : 'Day P/L',
              value: formatMoney(dayPnl),
              sub: formatReturn(number(summary['dayPnlPct'])),
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: sampleMode ? 'Sample unrealized' : 'Unrealized',
              value: formatMoney(unrealizedPnl),
              sub: formatReturn(number(summary['unrealizedPnlPct'])),
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: sampleMode ? 'Sample cash' : 'Cash',
              value: formatMoney(number(summary['cash'])),
              sub: '${formatNumber(number(summary['holdings']))} holdings',
              palette: palette,
            ),
            _GuruHeaderMetric(
              label: 'Top weight',
              value: formatReturn(
                number(summary['topWeight']),
              ).replaceFirst('+', ''),
              sub: 'concentration',
              palette: palette,
            ),
          ],
          palette: palette,
        ),
        const SizedBox(height: 10),
        if (savedReport) ...[
          PortfolioDataNotice(
            icon: Icons.history_rounded,
            text: savedPortfolioReportNotice(data, context.language),
            palette: palette,
          ),
          const SizedBox(height: 10),
        ],
        if (sampleMode) ...[
          PortfolioSampleNotice(palette: palette),
          const SizedBox(height: 10),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1040;
            final nav = Panel(
              palette: palette,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PanelTitle(
                    icon: Icons.show_chart_rounded,
                    kicker: 'PERFORMANCE',
                    title: sampleMode
                        ? context.tr('示例净值走势', 'Sample NAV')
                        : context.tr('组合净值走势', 'Portfolio NAV'),
                    palette: palette,
                    trailing: Text(
                      formatMoney(dayPnl),
                      style: TextStyle(
                        color: tone,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 250,
                    child: PortfolioPerformanceChart(
                      points: performance,
                      status: performanceStatus,
                      palette: palette,
                    ),
                  ),
                  if (!realPerformance) ...[
                    const SizedBox(height: 12),
                    PortfolioDataNotice(
                      icon: Icons.info_outline_rounded,
                      text: text(
                        performanceStatus['message'],
                        'IBKR did not return real portfolio NAV history for this query.',
                      ),
                      palette: palette,
                    ),
                  ],
                ],
              ),
            );
            final allocation = PortfolioAllocationPieCard(
              holdings: holdings,
              palette: palette,
            );
            final hero = wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: nav),
                      const SizedBox(width: 10),
                      SizedBox(width: 390, child: allocation),
                    ],
                  )
                : Column(
                    children: [nav, const SizedBox(height: 10), allocation],
                  );
            final contextCards = [
              PortfolioAccountCard(
                accounts: accounts,
                palette: palette,
                sampleMode: sampleMode,
              ),
              PortfolioSectorCard(sectors: sectors, palette: palette),
              PortfolioRiskCard(holdings: holdings, palette: palette),
            ];
            return Column(
              children: [
                hero,
                const SizedBox(height: 10),
                PortfolioHoldingsTable(holdings: holdings, palette: palette),
                const SizedBox(height: 10),
                PortfolioAnalyticsPanel(analytics: analytics, palette: palette),
                const SizedBox(height: 10),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var index = 0;
                        index < contextCards.length;
                        index++
                      ) ...[
                        if (index > 0) const SizedBox(width: 10),
                        Expanded(child: contextCards[index]),
                      ],
                    ],
                  )
                else
                  Column(
                    children: [
                      for (final card in contextCards) ...[
                        card,
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                const SizedBox(height: 10),
                PortfolioDividendCalendarSection(
                  dividends: dividends,
                  holdings: holdings,
                  status: dividendStatus,
                  portfolioValue: number(summary['totalValue']),
                  baseCurrency: text(summary['currency'], 'USD'),
                  palette: palette,
                ),
                const SizedBox(height: 10),
                if (readOnly)
                  PortfolioAdminReadOnlyPanel(
                    connection: connection,
                    notice: readOnlyNotice,
                    palette: palette,
                  )
                else if (registered)
                  PortfolioConnectionStatusPanel(
                    connection: connection,
                    api: api,
                    palette: palette,
                    onRefresh: onRefresh,
                  )
                else
                  PortfolioConnectionPanel(
                    connection: connection,
                    api: api,
                    palette: palette,
                    onConnected: onRefresh,
                  ),
              ],
            );
          },
        ),
      ],
    );
    if (!sampleMode) return dashboard;
    return Banner(
      message: context.tr('示例数据', 'SAMPLE DATA'),
      color: palette.secondary,
      location: BannerLocation.topEnd,
      child: dashboard,
    );
  }
}

class PortfolioSampleNotice extends StatelessWidget {
  const PortfolioSampleNotice({super.key, required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: context.tr(
        '当前全部组合数字为示例，不代表任何真实账户。',
        'All portfolio figures are sample data and do not represent any real account.',
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.secondary.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: palette.secondary.withValues(alpha: .62),
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.science_outlined, color: palette.secondary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.tr(
                  '示例数据 · 非真实账户。金额、持仓、收益与风险指标仅用于展示界面结构。',
                  'SAMPLE DATA · NOT A REAL ACCOUNT. Amounts, holdings, returns, and risk metrics are illustrative UI data only.',
                ),
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PortfolioAdminReadOnlyPanel extends StatelessWidget {
  const PortfolioAdminReadOnlyPanel({
    super.key,
    required this.connection,
    required this.palette,
    this.notice,
  });

  final Map<String, dynamic> connection;
  final Palette palette;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final accounts = asList(connection['accounts']);
    final status = text(connection['status'], 'not configured');
    final failed =
        status == 'error' || text(connection['lastError']).isNotEmpty;
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: failed
                ? Icons.warning_amber_rounded
                : Icons.visibility_rounded,
            kicker: 'ADMIN READ-ONLY',
            title: failed
                ? context.tr('用户连接有同步错误', 'User Sync Error')
                : context.tr('用户组合只读快照', 'Read-Only Portfolio Snapshot'),
            palette: palette,
            trailing: InfoChip(status, palette: palette),
          ),
          const SizedBox(height: 10),
          Text(
            context.ui(
              notice ??
                  'Admin view reads the selected user portfolio database without exposing saved credentials.',
            ),
            style: TextStyle(color: palette.muted, height: 1.35),
          ),
          const SizedBox(height: 12),
          if (accounts.isEmpty)
            EmptyState(
              text: 'No linked accounts are visible yet.',
              palette: palette,
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final account in accounts)
                  Container(
                    width: 260,
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: palette.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: palette.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.account_balance_rounded,
                              color: palette.secondary,
                              size: 17,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.ui(
                                  text(account['label'], 'IBKR account'),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          [
                            if (text(account['queryId']).isNotEmpty)
                              '${context.tr('查询', 'Query')} ${text(account['queryId'])}',
                            if (text(account['tokenPreview']).isNotEmpty)
                              text(account['tokenPreview']),
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class PortfolioConnectionStatusPanel extends StatefulWidget {
  const PortfolioConnectionStatusPanel({
    super.key,
    required this.connection,
    required this.api,
    required this.palette,
    required this.onRefresh,
  });

  final Map<String, dynamic> connection;
  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onRefresh;

  @override
  State<PortfolioConnectionStatusPanel> createState() =>
      _PortfolioConnectionStatusPanelState();
}

class _PortfolioConnectionStatusPanelState
    extends State<PortfolioConnectionStatusPanel> {
  bool _disconnecting = false;
  bool _updating = false;
  String? _error;
  String? _message;

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          context.tr('断开所有组合连接？', 'Disconnect all portfolio connections?'),
        ),
        content: Text(
          context.tr(
            '这不会删除券商账户。后端会先把现有加密凭据移入 15 分钟恢复区；恢复资格到期后，后端会在下次组合访问时永久清理加密副本。操作完成前页面不会预先清空。',
            'This does not delete any brokerage account. The backend first moves the encrypted credentials into a 15-minute recovery window; after eligibility expires, it permanently purges the encrypted copy on the next portfolio access. The page will not clear until the server confirms completion.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.tr('取消', 'Cancel')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.link_off_rounded),
            label: Text(context.tr('确认断开', 'Disconnect safely')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _disconnect();
  }

  Future<void> _disconnect() async {
    setState(() {
      _disconnecting = true;
      _error = null;
      _message = null;
    });
    try {
      final payload = await widget.api.deleteJson('/api/portfolio/connection');
      final minutes = portfolioRecoveryMinutesRemaining(
        text(payload['undoUntil']),
      );
      await widget.onRefresh();
      if (mounted) {
        setState(() {
          _message = context.tr(
            '连接已断开；恢复资格将在 ${minutes > 0 ? '$minutes 分钟后' : '恢复窗口结束时'}到期，之后后端会在下次组合访问时永久清理加密副本。',
            'Disconnected. Restore eligibility expires ${minutes > 0 ? 'in $minutes minutes' : 'when the recovery window closes'}; the backend then permanently purges the encrypted copy on the next portfolio access.',
          );
        });
      }
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _disconnecting = false);
    }
  }

  Future<void> _updateData() async {
    setState(() {
      _updating = true;
      _error = null;
      _message = null;
    });
    try {
      final payload = await widget.api.postJson('/api/portfolio/sync', {});
      if (!mounted) return;
      final nestedPortfolio = asMap(payload['portfolio']);
      final report = nestedPortfolio.isNotEmpty ? nestedPortfolio : payload;
      final statuses = [
        text(asMap(payload['connection'])['status']),
        text(asMap(report['connection'])['status']),
      ];
      final savedReport =
          isSavedPortfolioReport(report) || statuses.contains('stale_report');
      final partial = statuses.contains('linked_partial');
      if (savedReport ||
          partial ||
          statuses.contains('error') ||
          payload['ok'] != true) {
        setState(() {
          _error = savedReport
              ? savedPortfolioReportNotice(report, context.language)
              : partial
              ? context.tr(
                  '仅部分账户同步成功，其他账户未能刷新。组合可能不完整；请检查账户状态后重试。已保存的报告会保留。',
                  'Only some accounts synced; other accounts could not be refreshed. The portfolio may be incomplete. Review account status and retry. Saved reports are retained.',
                )
              : context.tr(
                  '券商同步未完成。请检查账户状态后重试。已保存的报告会保留。',
                  'Broker sync did not complete. Review account status and retry. Saved reports are retained.',
                );
          _message = null;
        });
        await widget.onRefresh();
        return;
      }
      final summary = asMap(payload['summary']);
      final accountCount = number(summary['accounts']).round();
      final holdings = number(summary['holdings']).round();
      setState(() {
        _message = context.tr(
          '已从 IBKR/Yodlee 拉取并写入后端：$accountCount 个账户 · $holdings 个持仓',
          'Synced from IBKR/Yodlee into backend: $accountCount accounts · $holdings holdings',
        );
      });
      await widget.onRefresh();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _showAddAccount() async {
    await showDialog<void>(
      context: context,
      builder: (context) => PortfolioAddAccountDialog(
        api: widget.api,
        palette: widget.palette,
        onAdded: widget.onRefresh,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final connection = widget.connection;
    final savedAccounts = asList(connection['accounts']);
    final status = text(connection['status'], 'linked');
    final failed =
        status == 'error' ||
        status == 'stale_report' ||
        status == 'linked_partial' ||
        text(connection['lastError']).isNotEmpty;
    final updatedAt = formatDate(text(connection['updatedAt']));
    final lastConnectedAt = formatDate(text(connection['lastConnectedAt']));
    final queryId = text(connection['queryId']);
    final tokenPreview = text(connection['tokenPreview']);
    final compactActions = MediaQuery.sizeOf(context).width < 760;
    final connectionRows = savedAccounts.isNotEmpty
        ? savedAccounts
        : [
            {
              'label': 'IBKR account 1',
              'tokenPreview': tokenPreview,
              'queryId': queryId,
            },
          ];

    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: failed
                ? Icons.warning_amber_rounded
                : Icons.verified_user_rounded,
            kicker: 'PRIVATE PORTFOLIO',
            title: failed
                ? context.tr(
                    '连接已保存，等待修复同步',
                    'Connection Saved; Sync Needs Attention',
                  )
                : context.tr('IBKR / Yodlee 已注册', 'IBKR / Yodlee Registered'),
            palette: palette,
            trailing: _statusActions(palette, compactActions: compactActions),
          ),
          const SizedBox(height: 10),
          Text(
            failed
                ? context.tr(
                    '你的连接记录仍然保留在后端加密用户库里，不需要重新注册。同步失败通常是 token 过期或 Query ID 权限变化；需要更换时先断开再重新注册。',
                    'Your connection is still encrypted in the per-user backend store. You do not need to register again. Sync failures usually mean the token expired or the Query ID permissions changed; disconnect first only if you need to replace credentials.',
                  )
                : context.tr(
                    '以后打开 Portfolio 会直接使用后端加密保存的连接；可以在右上角继续添加账户，或手动更新数据并写入今日 NAV。',
                    'Portfolio will use the encrypted backend connection automatically. You can add another account from the top right, or update data manually to write today’s NAV.',
                  ),
            style: TextStyle(color: palette.muted, height: 1.35),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 780;
              final rows = [
                for (final account in connectionRows)
                  _accountConnectionTile(
                    account: account,
                    palette: palette,
                    updatedAt: lastConnectedAt == '-'
                        ? updatedAt
                        : lastConnectedAt,
                  ),
              ];
              if (!wide) {
                return Column(
                  children: [
                    for (final row in rows) ...[
                      row,
                      if (row != rows.last) const SizedBox(height: 10),
                    ],
                  ],
                );
              }
              return GridWrap(minTileWidth: 230, spacing: 10, children: rows);
            },
          ),
          if (failed) ...[
            const SizedBox(height: 10),
            PortfolioDataNotice(
              icon: Icons.error_outline_rounded,
              text: text(
                connection['lastError'],
                text(connection['message'], 'Latest sync failed.'),
              ),
              palette: palette,
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 10),
            PortfolioDataNotice(
              icon: Icons.cloud_done_rounded,
              text: _message!,
              palette: palette,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            PortfolioDataNotice(
              icon: Icons.error_outline_rounded,
              text: _error!,
              palette: palette,
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InfoChip(
                context.tr('独立用户数据库', 'Per-user database'),
                palette: palette,
              ),
              InfoChip(
                context.tr('后端加密保存', 'Encrypted backend storage'),
                palette: palette,
              ),
              InfoChip(
                context.tr('前端不回显密钥', 'No credential echo in browser'),
                palette: palette,
              ),
              OutlinedButton.icon(
                onPressed: _disconnecting ? null : _confirmDisconnect,
                icon: _disconnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link_off_rounded),
                label: Text(
                  context.ui(
                    _disconnecting ? 'Disconnecting' : 'Disconnect all',
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.muted,
                  side: BorderSide(color: palette.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusActions(Palette palette, {required bool compactActions}) {
    if (compactActions) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: context.tr('添加账户', 'Add account'),
            onPressed: _showAddAccount,
            icon: Icon(Icons.add_rounded, color: palette.accent),
          ),
          IconButton(
            tooltip: context.tr('更新数据', 'Update data'),
            onPressed: _updating ? null : _updateData,
            icon: _updating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.cloud_sync_rounded, color: palette.accent),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _showAddAccount,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(context.tr('添加账户', 'Add account')),
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.accent,
            side: BorderSide(color: palette.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: _updating ? null : _updateData,
          icon: _updating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_rounded, size: 18),
          label: Text(
            _updating
                ? context.tr('更新中', 'Updating')
                : context.tr('更新数据', 'Update data'),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: palette.accent,
            foregroundColor: palette.background,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _accountConnectionTile({
    required Map<String, dynamic> account,
    required Palette palette,
    required String updatedAt,
  }) {
    final label = text(account['label'], 'IBKR account');
    final queryId = text(account['queryId'], 'saved');
    final tokenPreview = text(
      account['tokenPreview'],
      context.tr('已加密', 'encrypted'),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_rounded,
            color: palette.secondary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.ui(label),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${context.tr('Query ID', 'Query ID')} $queryId · $tokenPreview',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${context.tr('上次同步', 'Last sync')} $updatedAt',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.faint, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PortfolioAddAccountDialog extends StatefulWidget {
  const PortfolioAddAccountDialog({
    super.key,
    required this.api,
    required this.palette,
    required this.onAdded,
  });

  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onAdded;

  @override
  State<PortfolioAddAccountDialog> createState() =>
      _PortfolioAddAccountDialogState();
}

class _PortfolioAddAccountDialogState extends State<PortfolioAddAccountDialog> {
  final _labelController = TextEditingController();
  final _tokenController = TextEditingController();
  final _queryController = TextEditingController();
  bool _saving = false;
  bool _showToken = false;
  String? _error;

  @override
  void dispose() {
    _labelController.dispose();
    _tokenController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _tokenController.text.trim();
    final queryId = _queryController.text.trim();
    if (token.isEmpty || queryId.isEmpty) {
      setState(() {
        _error = context.tr(
          'Token 和 Yodlee Query ID 都要填。',
          'Token and Yodlee Query ID are both required.',
        );
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.postJson('/api/portfolio/accounts', {
        'label': _labelController.text.trim(),
        'ibkrFlexToken': token,
        'ibkrFlexQueryId': queryId,
      });
      await widget.onAdded();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(18),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: panelDecoration(palette),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PanelTitle(
                icon: Icons.add_card_rounded,
                kicker: 'PORTFOLIO ACCOUNT',
                title: context.tr(
                  '添加 IBKR / Yodlee 账户',
                  'Add IBKR / Yodlee Account',
                ),
                palette: palette,
                trailing: IconButton(
                  tooltip: context.ui('Close'),
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: palette.muted),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                context.tr(
                  '复制 IBKR Third-Party Services 里 Yodlee 那一行的 Token 和 Query ID。保存后会追加到你的后端用户库，并立即更新组合数据。',
                  'Copy the Token and Query ID from the Yodlee row in IBKR Third-Party Services. After saving, it will be added to your encrypted backend user store and immediately synced.',
                ),
                style: TextStyle(color: palette.muted, height: 1.35),
              ),
              const SizedBox(height: 14),
              _field(
                controller: _labelController,
                label: 'Account label',
                hint: context.tr(
                  '例如 IBKR main / Roth / Margin',
                  'Example: IBKR main / Roth / Margin',
                ),
                icon: Icons.badge_rounded,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _tokenController,
                label: 'Yodlee Token',
                hint: context.tr(
                  '复制 Yodlee 行的 Token',
                  'Copy the Token from the Yodlee row',
                ),
                icon: Icons.key_rounded,
                obscure: !_showToken,
                suffix: IconButton(
                  tooltip: context.ui(_showToken ? 'Hide token' : 'Show token'),
                  onPressed: () => setState(() => _showToken = !_showToken),
                  icon: Icon(
                    _showToken
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    color: palette.muted,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _field(
                controller: _queryController,
                label: 'Yodlee Query ID',
                hint: context.tr(
                  '复制 Yodlee 行的 Query ID',
                  'Copy the Query ID from the Yodlee row',
                ),
                icon: Icons.tag_rounded,
                keyboardType: TextInputType.number,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                PortfolioDataNotice(
                  icon: Icons.error_outline_rounded,
                  text: _error!,
                  palette: palette,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: palette.muted,
                        side: BorderSide(color: palette.border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(context.ui('Cancel')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload_rounded),
                      label: Text(
                        context.ui(_saving ? 'Adding' : 'Add & update'),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.accent,
                        foregroundColor: palette.background,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    final palette = widget.palette;
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      cursorColor: palette.accent,
      style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        labelText: context.ui(label),
        hintText: hint,
        labelStyle: TextStyle(color: palette.muted),
        hintStyle: TextStyle(color: palette.faint),
        prefixIcon: Icon(icon, color: palette.muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: palette.background.withValues(alpha: .52),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.accent),
        ),
      ),
    );
  }
}

class PortfolioConnectionPanel extends StatefulWidget {
  const PortfolioConnectionPanel({
    super.key,
    required this.connection,
    required this.api,
    required this.palette,
    required this.onConnected,
  });

  final Map<String, dynamic> connection;
  final ApiClient api;
  final Palette palette;
  final Future<void> Function() onConnected;

  @override
  State<PortfolioConnectionPanel> createState() =>
      _PortfolioConnectionPanelState();
}

class _PortfolioConnectionPanelState extends State<PortfolioConnectionPanel> {
  final _tokenController = TextEditingController();
  final _queryController = TextEditingController();
  bool _saving = false;
  bool _restoring = false;
  bool _showToken = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _tokenController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _tokenController.text.trim();
    final queryId = _queryController.text.trim();
    if (token.isEmpty || queryId.isEmpty) {
      setState(() {
        _error = context.tr(
          'Token 和 Yodlee Query ID 都要填。',
          'Token and Yodlee Query ID are both required.',
        );
        _message = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    try {
      final payload = await widget.api.postJson('/api/portfolio/connection', {
        'provider': 'ibkr_flex',
        'ibkrFlexToken': token,
        'ibkrFlexQueryId': queryId,
      });
      final portfolio = asMap(payload['portfolio']);
      final connection = asMap(portfolio['connection']);
      setState(() {
        _message = text(
          connection['message'],
          context.tr(
            '连接已保存，正在载入你的 portfolio。',
            'Connection saved. Loading your portfolio.',
          ),
        );
      });
      await widget.onConnected();
    } catch (error) {
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _error = null;
      _message = null;
    });
    try {
      await widget.api.postJson('/api/portfolio/connection/restore', {});
      if (mounted) {
        setState(() {
          _message = context.tr(
            '连接已从加密恢复区还原。',
            'Connection restored from encrypted recovery.',
          );
        });
      }
      await widget.onConnected();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final undoUntil = text(widget.connection['undoUntil']);
    final recoveryMinutes = portfolioRecoveryMinutesRemaining(undoUntil);
    final recoveryAvailable =
        truthy(widget.connection['recoverable']) && recoveryMinutes > 0;
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final fields = [
            _connectionField(
              controller: _tokenController,
              label: 'Yodlee Token',
              hint: context.tr(
                '复制 Yodlee 行的 Token',
                'Copy the Token from the Yodlee row',
              ),
              icon: Icons.key_rounded,
              obscure: !_showToken,
              suffix: IconButton(
                tooltip: context.ui(_showToken ? 'Hide token' : 'Show token'),
                onPressed: () => setState(() => _showToken = !_showToken),
                icon: Icon(
                  _showToken
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: palette.muted,
                ),
              ),
            ),
            _connectionField(
              controller: _queryController,
              label: 'Yodlee Query ID',
              hint: context.tr(
                '复制 Yodlee 行的 Query ID',
                'Copy the Query ID from the Yodlee row',
              ),
              icon: Icons.tag_rounded,
              keyboardType: TextInputType.number,
            ),
          ];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PanelTitle(
                icon: Icons.lock_person_rounded,
                kicker: 'PRIVATE PORTFOLIO',
                title: context.tr(
                  '首次连接 IBKR / Yodlee',
                  'Connect IBKR / Yodlee',
                ),
                palette: palette,
                trailing: InfoChip('per-user encrypted DB', palette: palette),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr(
                  '这个表单只在还没有注册连接时出现。保存成功后，后端会为当前登录用户加密保存配置，之后不会再要求填写 token 或 Query ID。',
                  'This form only appears before a connection is registered. After saving, the backend encrypts the configuration for the current signed-in user, and you will not be asked for the token or Query ID again.',
                ),
                style: TextStyle(color: palette.muted, height: 1.35),
              ),
              if (recoveryAvailable) ...[
                const SizedBox(height: 14),
                Semantics(
                  liveRegion: true,
                  label: context.tr(
                    '连接已断开，可在 $recoveryMinutes 分钟内撤销。',
                    'Connection disconnected. Undo is available for $recoveryMinutes minutes.',
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.secondary.withValues(alpha: .13),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: palette.secondary.withValues(alpha: .58),
                      ),
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Text(
                            context.tr(
                              '刚才的连接已断开。加密凭据仍可在约 $recoveryMinutes 分钟内恢复；恢复资格到期后，后端会在下次组合访问时永久清理。',
                              'The previous connection is disconnected. Its encrypted credentials can be restored for about $recoveryMinutes minutes; after eligibility expires, the backend permanently purges them on the next portfolio access.',
                            ),
                            style: TextStyle(
                              color: palette.text,
                              fontWeight: FontWeight.w800,
                              height: 1.35,
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _restoring ? null : _restore,
                          icon: _restoring
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.undo_rounded),
                          label: Text(
                            context.tr(
                              _restoring ? '正在恢复' : '撤销断开',
                              _restoring ? 'Restoring' : 'Undo disconnect',
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            backgroundColor: palette.secondary,
                            foregroundColor: palette.background,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _setupGuide(palette),
              const SizedBox(height: 14),
              if (compact)
                Column(
                  children: [
                    for (final field in fields) ...[
                      field,
                      const SizedBox(height: 10),
                    ],
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: fields[0]),
                    const SizedBox(width: 10),
                    Expanded(child: fields[1]),
                  ],
                ),
              if (_error != null || _message != null) ...[
                const SizedBox(height: 10),
                PortfolioDataNotice(
                  icon: _error == null
                      ? Icons.verified_user_rounded
                      : Icons.error_outline_rounded,
                  text: _error ?? _message!,
                  palette: palette,
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_sync_rounded),
                    label: Text(
                      context.ui(_saving ? 'Connecting' : 'Save & sync'),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.accent,
                      foregroundColor: palette.background,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  InfoChip('IBKR host allowlisted', palette: palette),
                  InfoChip('no browser token storage', palette: palette),
                  InfoChip('one-time setup', palette: palette),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _setupGuide(Palette palette) {
    final steps = [
      (
        '1',
        context.tr('打开 IBKR Client Portal', 'Open IBKR Client Portal'),
        context.tr(
          '进入 Performance & Reports，然后点 Third-Party Reports。',
          'Go to Performance & Reports, then open Third-Party Reports.',
        ),
      ),
      (
        '2',
        context.tr('复制 Yodlee 那一行', 'Copy the Yodlee row'),
        context.tr(
          '在 Third-Party Services 表格里勾选 Yodlee，只复制这一行显示出来的 Token 和 Query ID。',
          'Enable Yodlee in the Third-Party Services table, then copy only the Token and Query ID shown on that row.',
        ),
      ),
      (
        '3',
        context.tr('净值曲线自动积累', 'NAV history builds automatically'),
        context.tr(
          'IBKR 这里没有 NAV ID。系统会用同一个 Yodlee Query ID 拉组合，并每天把账户 NAV 存进你的用户库，数据够了自动画线。',
          'There is no NAV ID in IBKR. The system uses the same Yodlee Query ID to fetch the portfolio and stores daily account NAV in your user database; the chart appears once enough history exists.',
        ),
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_rounded, color: palette.secondary, size: 18),
              const SizedBox(width: 8),
              Text(
                context.tr(
                  '在哪里找 Token / Query ID',
                  'Where to Find Token / Query ID',
                ),
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final children = [
                for (final step in steps)
                  _setupStep(
                    number: step.$1,
                    title: step.$2,
                    body: step.$3,
                    palette: palette,
                  ),
              ];
              if (compact) {
                return Column(
                  children: [
                    for (final child in children) ...[
                      child,
                      if (child != children.last) const SizedBox(height: 10),
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < children.length; i += 1) ...[
                    Expanded(child: children[i]),
                    if (i != children.length - 1) const SizedBox(width: 10),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _setupStep({
    required String number,
    required String title,
    required String body,
    required Palette palette,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: .16),
            shape: BoxShape.circle,
            border: Border.all(color: palette.accent.withValues(alpha: .35)),
          ),
          child: Text(
            number,
            style: TextStyle(
              color: palette.accent,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.32,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _connectionField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    final palette = widget.palette;
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      cursorColor: palette.accent,
      style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        labelText: context.ui(label),
        hintText: hint,
        labelStyle: TextStyle(color: palette.muted),
        hintStyle: TextStyle(color: palette.faint),
        prefixIcon: Icon(icon, color: palette.muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: palette.background.withValues(alpha: .52),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.accent),
        ),
      ),
    );
  }
}

class PortfolioPerformanceChart extends StatelessWidget {
  const PortfolioPerformanceChart({
    super.key,
    required this.points,
    required this.status,
    required this.palette,
  });

  final List<Map<String, dynamic>> points;
  final Map<String, dynamic> status;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
          color: palette.card.withValues(alpha: .34),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timeline_rounded, color: palette.muted, size: 30),
                const SizedBox(height: 10),
                Text(
                  context.tr('等待真实净值历史', 'Waiting for Real NAV History'),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  context.ui(
                    text(
                      status['message'],
                      'Current IBKR report has fewer than two NAV points.',
                    ),
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      image: true,
      label: context.tr(
        '组合净值历史图，共 ${points.length} 个数据点。',
        'Portfolio NAV history chart with ${points.length} points.',
      ),
      child: CustomPaint(
        painter: PortfolioPerformancePainter(points: points, palette: palette),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class PortfolioPerformancePainter extends CustomPainter {
  PortfolioPerformancePainter({required this.points, required this.palette});

  final List<Map<String, dynamic>> points;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.width <= 0 || size.height <= 0) return;
    final values = points
        .map((point) => number(point['value']))
        .where((value) => value > 0)
        .toList();
    if (values.length < 2) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final range = math.max(1, maxValue - minValue);
    final left = 14.0;
    final right = size.width - 10;
    final top = 12.0;
    final bottom = size.height - 24;
    final gridPaint = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i += 1) {
      final y = top + (bottom - top) * i / 3;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }
    final path = Path();
    for (var i = 0; i < values.length; i += 1) {
      final x = left + (right - left) * i / (values.length - 1);
      final y = bottom - (bottom - top) * ((values[i] - minValue) / range);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final stroke = Paint()
      ..color = palette.accent
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant PortfolioPerformancePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.palette != palette;
}

class PortfolioDataNotice extends StatelessWidget {
  const PortfolioDataNotice({
    super.key,
    required this.icon,
    required this.text,
    required this.palette,
  });

  final IconData icon;
  final String text;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: palette.secondary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.ui(text),
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PortfolioHoldingLogo extends StatelessWidget {
  const PortfolioHoldingLogo({
    super.key,
    required this.row,
    required this.palette,
    this.size = 28,
  });

  final Map<String, dynamic> row;
  final Palette palette;
  final double size;

  @override
  Widget build(BuildContext context) => StockLogo(
    ticker: text(row['underlyingTicker'], text(row['ticker'])),
    palette: palette,
    size: size,
  );
}

class PortfolioAllocationPieCard extends StatefulWidget {
  const PortfolioAllocationPieCard({
    super.key,
    required this.holdings,
    required this.palette,
  });

  final List<Map<String, dynamic>> holdings;
  final Palette palette;

  @override
  State<PortfolioAllocationPieCard> createState() =>
      _PortfolioAllocationPieCardState();
}

class _PortfolioAllocationPieCardState
    extends State<PortfolioAllocationPieCard> {
  int? hoveredSlice;

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final positiveHoldings = widget.holdings
        .where(
          (row) =>
              number(row['value']) > 0 &&
              !text(row['ticker']).toUpperCase().startsWith('CASH'),
        )
        .toList();
    final total = positiveHoldings.fold<double>(
      0,
      (sum, row) => sum + number(row['value']),
    );
    final colors = [
      palette.accent,
      palette.secondary,
      const Color(0xFF69A7FF),
      const Color(0xFFE7B850),
      const Color(0xFFB889F6),
      const Color(0xFFFF7E72),
      const Color(0xFF8BD7D2),
      const Color(0xFF9AC46D),
    ];
    final visible = positiveHoldings.take(7).toList();
    final otherValue = positiveHoldings
        .skip(7)
        .fold<double>(0, (sum, row) => sum + number(row['value']));
    final slices = <Map<String, dynamic>>[
      for (var index = 0; index < visible.length; index += 1)
        {
          ...visible[index],
          'sliceValue': number(visible[index]['value']),
          'sliceColor': colors[index % colors.length],
        },
      if (otherValue > 0)
        {
          'ticker': 'Other',
          'name': 'Other holdings',
          'value': otherValue,
          'sliceValue': otherValue,
          'sliceColor': palette.muted,
        },
    ];

    final hovered = hoveredSlice != null && hoveredSlice! < slices.length
        ? slices[hoveredSlice!]
        : null;
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.pie_chart_rounded,
            kicker: 'HOLDING MIX',
            title: context.tr('持仓饼图', 'Holding Mix'),
            palette: palette,
            trailing: Text(
              context.tr(
                '${positiveHoldings.length} 只持仓',
                '${positiveHoldings.length} names',
              ),
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          if (slices.isEmpty || total <= 0)
            EmptyState(text: 'No positive holdings to chart.', palette: palette)
          else ...[
            SizedBox(
              height: 178,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PortfolioPieChart(
                    slices: slices,
                    total: total,
                    palette: palette,
                    onHover: (index) {
                      if (index != hoveredSlice) {
                        setState(() => hoveredSlice = index);
                      }
                    },
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hovered == null
                            ? formatMoney(total)
                            : text(hovered['ticker'], 'Other'),
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        hovered == null
                            ? context.ui('positive MV')
                            : '${formatReturn(number(hovered['sliceValue']) / total).replaceFirst('+', '')} · ${formatMoney(number(hovered['sliceValue']))}',
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < visible.take(6).length; index += 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    PortfolioHoldingLogo(
                      row: visible[index],
                      palette: palette,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 54,
                      child: Text(
                        text(visible[index]['ticker']),
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: total <= 0
                              ? 0
                              : math.max(
                                  .04,
                                  number(visible[index]['value']) / total,
                                ),
                          minHeight: 7,
                          backgroundColor: palette.border,
                          color: colors[index % colors.length],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 58,
                      child: Text(
                        formatReturn(
                          number(visible[index]['value']) / total,
                        ).replaceFirst('+', ''),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 74,
                      child: Text(
                        formatMoney(number(visible[index]['value'])),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
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
}

class PortfolioPieChart extends StatelessWidget {
  const PortfolioPieChart({
    super.key,
    required this.slices,
    required this.total,
    required this.palette,
    this.onHover,
  });

  final List<Map<String, dynamic>> slices;
  final double total;
  final Palette palette;
  final ValueChanged<int?>? onHover;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        int? hit(Offset position) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final center = size.center(Offset.zero);
          final radius = math.min(size.width, size.height) * .38;
          final strokeWidth = math.max(22.0, radius * .34);
          final offset = position - center;
          if ((offset.distance - radius).abs() > strokeWidth / 2 + 5) {
            return null;
          }
          final angle =
              (math.atan2(offset.dy, offset.dx) + math.pi / 2 + math.pi * 2) %
              (math.pi * 2);
          var through = 0.0;
          for (var index = 0; index < slices.length; index += 1) {
            through +=
                math.pi * 2 * (number(slices[index]['sliceValue']) / total);
            if (angle <= through) return index;
          }
          return null;
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (event) => onHover?.call(hit(event.localPosition)),
          onExit: (_) => onHover?.call(null),
          child: GestureDetector(
            onTapDown: (event) => onHover?.call(hit(event.localPosition)),
            child: CustomPaint(
              painter: PortfolioPiePainter(
                slices: slices,
                total: total,
                palette: palette,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

class PortfolioPiePainter extends CustomPainter {
  PortfolioPiePainter({
    required this.slices,
    required this.total,
    required this.palette,
  });

  final List<Map<String, dynamic>> slices;
  final double total;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0 || slices.isEmpty) return;
    final radius = math.min(size.width, size.height) * .38;
    final strokeWidth = math.max(22.0, radius * .34);
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );
    final background = Paint()
      ..color = palette.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(rect, 0, math.pi * 2, false, background);

    var start = -math.pi / 2;
    for (final slice in slices) {
      final value = number(slice['sliceValue']);
      if (value <= 0) continue;
      final sweep = math.pi * 2 * (value / total);
      final paint = Paint()
        ..color = slice['sliceColor'] as Color? ?? palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant PortfolioPiePainter oldDelegate) =>
      oldDelegate.slices != slices ||
      oldDelegate.total != total ||
      oldDelegate.palette != palette;
}

class PortfolioAnalyticsPanel extends StatelessWidget {
  const PortfolioAnalyticsPanel({
    super.key,
    required this.analytics,
    required this.palette,
  });

  final Map<String, dynamic> analytics;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final rows = asList(analytics['holdings']);
    final historical = asMap(analytics['historicalOneYear']);
    final forward = asMap(analytics['forwardOneYear']);
    final coverage = asMap(analytics['coverage']);
    final assumptions = asMap(analytics['assumptions']);
    final source = asMap(analytics['source']);
    final status = text(analytics['status']);
    if (analytics.isEmpty || status == 'error') {
      return Panel(
        palette: palette,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelTitle(
              icon: Icons.insights_rounded,
              kicker: 'PORTFOLIO ANALYTICS',
              title: context.tr('估值差距 / 夏普比率', 'Valuation Gap / Sharpe'),
              palette: palette,
            ),
            const SizedBox(height: 14),
            PortfolioDataNotice(
              icon: Icons.info_outline_rounded,
              text: text(
                analytics['message'],
                'Portfolio analytics are not available yet.',
              ),
              palette: palette,
            ),
          ],
        ),
      );
    }

    final modelCoverage = number(coverage['valuationCoveredWeight']);
    final priceCoverage = number(coverage['priceCoveredWeight']);
    final riskFreeRate = number(assumptions['riskFreeRate']);
    final topRows = rows
        .where((row) => !text(row['ticker']).startsWith('CASH'))
        .take(10)
        .toList();

    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.analytics_rounded,
            kicker: 'PORTFOLIO ANALYTICS',
            title: context.tr('估值差距 / 夏普比率', 'Valuation Gap / Sharpe'),
            palette: palette,
            trailing: Tooltip(
              message: context.ui(
                text(
                  source['methodology'],
                  'Historical risk uses one-year daily returns; forward return is a model-implied scenario.',
                ),
              ),
              child: Icon(
                Icons.info_outline_rounded,
                color: palette.muted,
                size: 18,
              ),
            ),
          ),
          const SizedBox(height: 14),
          GridWrap(
            minTileWidth: 170,
            spacing: 10,
            children: [
              PortfolioAnalyticsMetricCard(
                label: context.tr('过去一年收益', 'Past 1Y Return'),
                value: formatReturn(number(historical['totalReturn'])),
                sub: 'Sharpe ${formatSharpe(number(historical['sharpe']))}',
                icon: Icons.history_rounded,
                tone: number(historical['totalReturn']),
                palette: palette,
              ),
              PortfolioAnalyticsMetricCard(
                label: context.tr('过去一年波动', 'Past 1Y Volatility'),
                value: formatReturn(
                  number(historical['volatility']),
                ).replaceFirst('+', ''),
                sub: 'current-weight backsolve',
                icon: Icons.show_chart_rounded,
                palette: palette,
              ),
              PortfolioAnalyticsMetricCard(
                label: context.tr('未来一年情景回报', 'Forward 1Y Scenario Return'),
                value: formatReturn(number(forward['expectedReturn'])),
                sub: context.tr(
                  '${formatMoney(number(forward['potentialPnl']))} 模型盈亏',
                  '${formatMoney(number(forward['potentialPnl']))} model P/L',
                ),
                icon: Icons.online_prediction_rounded,
                tone: number(forward['expectedReturn']),
                palette: palette,
              ),
              PortfolioAnalyticsMetricCard(
                label: context.tr('未来情景夏普比率', 'Forward Scenario Sharpe'),
                value: formatSharpe(number(forward['sharpe'])),
                sub: context.tr(
                  '无风险利率 ${formatReturn(riskFreeRate).replaceFirst('+', '')}',
                  'rf ${formatReturn(riskFreeRate).replaceFirst('+', '')}',
                ),
                icon: Icons.speed_rounded,
                tone: number(forward['sharpe']) - 1,
                palette: palette,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InfoChip(
                context.tr(
                  '估值覆盖率 ${formatReturn(modelCoverage).replaceFirst('+', '')}',
                  'FV coverage ${formatReturn(modelCoverage).replaceFirst('+', '')}',
                ),
                palette: palette,
              ),
              InfoChip(
                context.tr(
                  '股价覆盖率 ${formatReturn(priceCoverage).replaceFirst('+', '')}',
                  'price coverage ${formatReturn(priceCoverage).replaceFirst('+', '')}',
                ),
                palette: palette,
              ),
              InfoChip(
                context.tr(
                  '估值差收敛 ${formatReturn(number(assumptions['gapConvergenceOneYear'])).replaceFirst('+', '')}',
                  'gap close ${formatReturn(number(assumptions['gapConvergenceOneYear'])).replaceFirst('+', '')}',
                ),
                palette: palette,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (topRows.isEmpty)
            EmptyState(
              text:
                  'No portfolio holdings are available for valuation analysis.',
              palette: palette,
            )
          else
            PortfolioValuationGapList(rows: topRows, palette: palette),
        ],
      ),
    );
  }
}

class PortfolioAnalyticsMetricCard extends StatelessWidget {
  const PortfolioAnalyticsMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.palette,
    this.tone,
  });

  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Palette palette;
  final double? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == null
        ? palette.secondary
        : tone! >= 0
        ? palette.positive
        : palette.negative;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 12),
          Text(
            context.ui(label),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.ui(sub),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.faint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class PortfolioValuationGapList extends StatelessWidget {
  const PortfolioValuationGapList({
    super.key,
    required this.rows,
    required this.palette,
  });

  final List<Map<String, dynamic>> rows;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(compact ? 12 : 14),
          decoration: BoxDecoration(
            color: palette.card.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            children: [
              if (!compact)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      _PortfolioAnalyticsHeader(
                        'Ticker',
                        width: 150,
                        palette: palette,
                      ),
                      Expanded(
                        child: _PortfolioAnalyticsHeader(
                          'FV gap',
                          palette: palette,
                        ),
                      ),
                      _PortfolioAnalyticsHeader(
                        '1Y / Vol',
                        width: 120,
                        alignEnd: true,
                        palette: palette,
                      ),
                      _PortfolioAnalyticsHeader(
                        'Forward',
                        width: 110,
                        alignEnd: true,
                        palette: palette,
                      ),
                      _PortfolioAnalyticsHeader(
                        'Weight',
                        width: 90,
                        alignEnd: true,
                        palette: palette,
                      ),
                    ],
                  ),
                ),
              for (final row in rows)
                PortfolioValuationGapRow(
                  row: row,
                  compact: compact,
                  palette: palette,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PortfolioAnalyticsHeader extends StatelessWidget {
  const _PortfolioAnalyticsHeader(
    this.label, {
    required this.palette,
    this.width,
    this.alignEnd = false,
  });

  final String label;
  final Palette palette;
  final double? width;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      context.ui(label),
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: TextStyle(
        color: palette.faint,
        fontSize: 11,
        fontWeight: FontWeight.w900,
      ),
    );
    return width == null ? child : SizedBox(width: width, child: child);
  }
}

class PortfolioValuationGapRow extends StatelessWidget {
  const PortfolioValuationGapRow({
    super.key,
    required this.row,
    required this.compact,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final bool compact;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final valuation = asMap(row['valuation']);
    final gap = nullableNumber(valuation['gap']);
    final gapAbs = gap?.abs().clamp(0.0, .8) ?? 0.0;
    final tone = portfolioValuationTone(valuation, palette);
    final ticker = text(row['ticker'], 'N/A');
    final logoRow = {
      'ticker': ticker,
      'name': text(row['name'], ticker),
      'logoUrl': text(row['logoUrl']),
    };
    final gapText = gap == null ? '-' : formatReturn(gap);
    final price = nullableNumber(valuation['latestPrice']);
    final fairValue = nullableNumber(valuation['fairValue']);
    final currency = text(valuation['currency'], 'USD');
    final priceText = price == null
        ? context.tr('无模型股价', 'No model price')
        : context.tr(
            '股价 ${formatCurrencyValue(price, currency)}',
            '${formatCurrencyValue(price, currency)} price',
          );
    final fairText = fairValue == null
        ? context.tr('公允价值 -', 'FV -')
        : context.tr(
            '公允价值 ${formatCurrencyValue(fairValue, currency)}',
            'FV ${formatCurrencyValue(fairValue, currency)}',
          );
    final content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PortfolioHoldingLogo(
                    row: logoRow,
                    palette: palette,
                    size: 28,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      ticker,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  PortfolioValuationChip(
                    valuation: valuation,
                    palette: palette,
                  ),
                ],
              ),
              const SizedBox(height: 9),
              _PortfolioGapBar(value: gapAbs, color: tone, palette: palette),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$gapText · $fairText',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ),
                  Text(
                    '1Y ${formatNullableReturn(row['trailingReturn'])}',
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ],
              ),
            ],
          )
        : Row(
            children: [
              SizedBox(
                width: 150,
                child: Row(
                  children: [
                    PortfolioHoldingLogo(
                      row: logoRow,
                      palette: palette,
                      size: 26,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ticker,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            formatReturn(
                              number(row['weight']),
                            ).replaceFirst('+', ''),
                            style: TextStyle(
                              color: palette.faint,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 74,
                          child: Text(
                            gapText,
                            style: TextStyle(
                              color: tone,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _PortfolioGapBar(
                            value: gapAbs,
                            color: tone,
                            palette: palette,
                          ),
                        ),
                        const SizedBox(width: 10),
                        PortfolioValuationChip(
                          valuation: valuation,
                          palette: palette,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$priceText · $fairText',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.faint, fontSize: 11),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 120,
                child: Text(
                  '${formatNullableReturn(row['trailingReturn'])} / ${formatNullableReturn(row['annualVolatility']).replaceFirst('+', '')}',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  formatNullableReturn(row['forwardExpectedReturn']),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: nullableNumber(row['forwardExpectedReturn']) == null
                        ? palette.muted
                        : number(row['forwardExpectedReturn']) >= 0
                        ? palette.positive
                        : palette.negative,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                child: Text(
                  formatReturn(number(row['weight'])).replaceFirst('+', ''),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          );

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: .24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border.withValues(alpha: .72)),
      ),
      child: content,
    );
  }
}

class _PortfolioGapBar extends StatelessWidget {
  const _PortfolioGapBar({
    required this.value,
    required this.color,
    required this.palette,
  });

  final double value;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: math.max(.04, value / .8).clamp(0.0, 1.0),
        minHeight: 8,
        backgroundColor: palette.border,
        color: color,
      ),
    );
  }
}

class PortfolioValuationChip extends StatelessWidget {
  const PortfolioValuationChip({
    super.key,
    required this.valuation,
    required this.palette,
  });

  final Map<String, dynamic> valuation;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final color = portfolioValuationTone(valuation, palette);
    final label = context.isChinese
        ? text(valuation['labelZh'], text(valuation['label'], '无估值'))
        : text(valuation['label'], 'No valuation');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        context.ui(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

Color portfolioValuationTone(Map<String, dynamic> valuation, Palette palette) {
  final tone = text(valuation['tone']).toLowerCase();
  if (tone == 'positive') return palette.positive;
  if (tone == 'negative') return palette.negative;
  final gap = nullableNumber(valuation['gap']);
  if (gap == null) return palette.muted;
  if (gap >= .18) return palette.positive;
  if (gap <= -.18) return palette.negative;
  return palette.secondary;
}

String formatNullableReturn(dynamic value) {
  final parsed = nullableNumber(value);
  if (parsed == null) return '-';
  return formatReturn(parsed);
}

String formatSharpe(double value) {
  if (!value.isFinite) return '-';
  return value.toStringAsFixed(2);
}

class PortfolioDividendCalendarSection extends StatefulWidget {
  const PortfolioDividendCalendarSection({
    super.key,
    required this.dividends,
    required this.holdings,
    required this.status,
    required this.portfolioValue,
    required this.baseCurrency,
    required this.palette,
  });

  final List<Map<String, dynamic>> dividends;
  final List<Map<String, dynamic>> holdings;
  final Map<String, dynamic> status;
  final double portfolioValue;
  final String baseCurrency;
  final Palette palette;

  @override
  State<PortfolioDividendCalendarSection> createState() =>
      _PortfolioDividendCalendarSectionState();
}

class _PortfolioDividendCalendarSectionState
    extends State<PortfolioDividendCalendarSection> {
  String _query = '';
  String _statusFilter = 'all';
  String _dateMode = 'auto';
  String _windowMode = 'forward';
  bool _calendarView = true;
  int _monthOffset = 0;

  int _offsetForMonth(DateTime target, DateTime windowStart) {
    final base = DateTime(windowStart.year, windowStart.month, 1);
    final offset = (target.year - base.year) * 12 + target.month - base.month;
    return offset.clamp(0, 11).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final window = dividendCalendarWindowForKey(_windowMode, today);
    final start = window.start;
    final end = window.end;
    final monthOffset = _monthOffset.clamp(0, 11).toInt();
    final visibleMonthStart = DateTime(
      start.year,
      start.month + monthOffset,
      1,
    );
    final baseCurrency = normalizeDividendCurrency(widget.baseCurrency);
    final allEvents = normalizeDividendDisplayEvents(
      widget.dividends,
      widget.holdings,
      dateMode: _dateMode,
      baseCurrency: baseCurrency,
    );
    bool matchesSearchAndStatus(DividendDisplayEvent event) {
      final statusMatches =
          _statusFilter == 'all' || event.status == _statusFilter;
      final query = _query.trim().toUpperCase();
      final queryMatches =
          query.isEmpty ||
          event.ticker.contains(query) ||
          event.name.toUpperCase().contains(query);
      return statusMatches && queryMatches;
    }

    final filtered =
        allEvents.where((event) {
          final matchesWindow =
              !event.date.isBefore(start) && !event.date.isAfter(end);
          return matchesWindow && matchesSearchAndStatus(event);
        }).toList()..sort((left, right) {
          final dateOrder = left.date.compareTo(right.date);
          if (dateOrder != 0) return dateOrder;
          return right.payoutBase.abs().compareTo(left.payoutBase.abs());
        });
    final comparisonEvents =
        allEvents
            .where(
              (event) =>
                  event.date.year >= 2025 &&
                  event.date.year <= 2026 &&
                  matchesSearchAndStatus(event),
            )
            .toList()
          ..sort((left, right) {
            final dateOrder = left.date.compareTo(right.date);
            if (dateOrder != 0) return dateOrder;
            return right.payoutBase.abs().compareTo(left.payoutBase.abs());
          });
    final buckets = dividendMonthBuckets(start, filtered);
    final comparisonBuckets = _windowMode == 'forward'
        ? const <DividendYearComparisonBucket>[]
        : dividendYearComparisonBuckets(const [2025, 2026], comparisonEvents);
    final calendarBucket = buckets.firstWhere(
      (bucket) =>
          bucket.monthStart.year == visibleMonthStart.year &&
          bucket.monthStart.month == visibleMonthStart.month,
      orElse: () => buckets.first,
    );
    final calendarStart = calendarBucket.monthStart;
    final monthEvents = [...calendarBucket.events]
      ..sort((left, right) {
        final dateOrder = left.date.compareTo(right.date);
        if (dateOrder != 0) return dateOrder;
        return right.payoutBase.abs().compareTo(left.payoutBase.abs());
      });
    final monthTotal = calendarBucket.total;
    final annualIncome = filtered.fold<double>(
      0,
      (sum, event) => sum + event.payoutBase.abs(),
    );
    final monthlyIncome = annualIncome / 12;
    final dailyIncome = annualIncome / 365;
    final yield = widget.portfolioValue > 0
        ? annualIncome / widget.portfolioValue
        : 0.0;
    final currency = baseCurrency;
    final nextDividendMonth = nextDividendMonthAfter(calendarStart, filtered);
    final isCompact = MediaQuery.sizeOf(context).width < 760;

    return Panel(
      palette: widget.palette,
      padding: EdgeInsets.all(isCompact ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.event_available_rounded,
            kicker: 'DIVIDENDS',
            title: 'Dividend calendar',
            palette: widget.palette,
            trailing: Text(
              context.tr('${filtered.length} 个事件', '${filtered.length} events'),
              style: TextStyle(color: widget.palette.muted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          DividendCalendarToolbar(
            windowMode: _windowMode,
            query: _query,
            statusFilter: _statusFilter,
            dateMode: _dateMode,
            palette: widget.palette,
            onWindowChanged: (value) => setState(() {
              _windowMode = value;
              _monthOffset = 0;
            }),
            onQueryChanged: (value) => setState(() => _query = value),
            onStatusChanged: (value) => setState(() => _statusFilter = value),
            onDateModeChanged: (value) => setState(() => _dateMode = value),
          ),
          const SizedBox(height: 16),
          if (allEvents.isEmpty)
            PortfolioDataNotice(
              icon: Icons.calendar_month_rounded,
              text: text(
                widget.status['message'],
                'Current portfolio feed did not return dividend calendar events.',
              ),
              palette: widget.palette,
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 820;
                final summaryCard = DividendIncomeSummaryCard(
                  annualIncome: annualIncome,
                  monthlyIncome: monthlyIncome,
                  dailyIncome: dailyIncome,
                  yield: yield,
                  currency: currency,
                  palette: widget.palette,
                );
                final chartCard = DividendMonthlyChartCard(
                  buckets: buckets,
                  comparisonBuckets: comparisonBuckets,
                  comparisonYears: const [2025, 2026],
                  currency: currency,
                  palette: widget.palette,
                );
                if (!wide) {
                  return Column(
                    children: [
                      summaryCard,
                      const SizedBox(height: 10),
                      chartCard,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 310, child: summaryCard),
                    const SizedBox(width: 12),
                    Expanded(child: chartCard),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: monthOffset <= 0
                          ? null
                          : () => setState(() => _monthOffset -= 1),
                      icon: const Icon(Icons.chevron_left_rounded),
                      color: widget.palette.muted,
                      tooltip: context.ui('Previous month'),
                    ),
                    Text(
                      dividendWindowTitle(calendarStart, context.language),
                      style: TextStyle(
                        color: widget.palette.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    IconButton(
                      onPressed: monthOffset >= 11
                          ? null
                          : () => setState(() => _monthOffset += 1),
                      icon: const Icon(Icons.chevron_right_rounded),
                      color: widget.palette.muted,
                      tooltip: context.ui('Next month'),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: widget.palette.positive.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '+${formatDividendMoney(monthTotal, currency)}',
                        style: TextStyle(
                          color: widget.palette.positive,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                DividendViewToggle(
                  calendarView: _calendarView,
                  palette: widget.palette,
                  onChanged: (value) => setState(() => _calendarView = value),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (filtered.isEmpty)
              EmptyState(
                text: 'No dividend events match this filter.',
                palette: widget.palette,
              )
            else if (_calendarView)
              Column(
                children: [
                  if (monthEvents.isEmpty) ...[
                    DividendEmptyMonthNotice(
                      monthStart: calendarStart,
                      nextMonth: nextDividendMonth,
                      palette: widget.palette,
                      onJumpToNext: nextDividendMonth == null
                          ? null
                          : () => setState(
                              () => _monthOffset = _offsetForMonth(
                                nextDividendMonth,
                                start,
                              ),
                            ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  DividendMonthCalendarGrid(
                    monthStart: calendarStart,
                    events: monthEvents,
                    currency: currency,
                    portfolioValue: widget.portfolioValue,
                    palette: widget.palette,
                  ),
                ],
              )
            else if (monthEvents.isEmpty)
              DividendEmptyMonthNotice(
                monthStart: calendarStart,
                nextMonth: nextDividendMonth,
                palette: widget.palette,
                onJumpToNext: nextDividendMonth == null
                    ? null
                    : () => setState(
                        () => _monthOffset = _offsetForMonth(
                          nextDividendMonth,
                          start,
                        ),
                      ),
              )
            else
              DividendEventList(
                events: monthEvents,
                currency: currency,
                palette: widget.palette,
              ),
          ],
        ],
      ),
    );
  }
}

class DividendCalendarToolbar extends StatelessWidget {
  const DividendCalendarToolbar({
    super.key,
    required this.windowMode,
    required this.query,
    required this.statusFilter,
    required this.dateMode,
    required this.palette,
    required this.onWindowChanged,
    required this.onQueryChanged,
    required this.onStatusChanged,
    required this.onDateModeChanged,
  });

  final String windowMode;
  final String query;
  final String statusFilter;
  final String dateMode;
  final Palette palette;
  final ValueChanged<String> onWindowChanged;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String> onDateModeChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1080;
        final rangeControls = DividendWindowSelector(
          value: windowMode,
          palette: palette,
          onChanged: onWindowChanged,
        );

        final search = SizedBox(
          width: compact ? double.infinity : 220,
          child: TextField(
            onChanged: onQueryChanged,
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              isDense: true,
              hintText: context.ui('Search ticker'),
              hintStyle: TextStyle(color: palette.muted),
              prefixIcon: Icon(Icons.search_rounded, color: palette.muted),
              filled: true,
              fillColor: palette.card,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.accent),
              ),
            ),
          ),
        );

        final filters = Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DividendDropdown(
              value: statusFilter,
              items: const {
                'all': 'Status',
                'paid': 'Paid',
                'declared': 'Declared',
                'estimated': 'Estimated',
              },
              palette: palette,
              onChanged: onStatusChanged,
            ),
            DividendDropdown(
              value: dateMode,
              items: const {
                'auto': 'Payout type',
                'pay': 'Pay date',
                'ex': 'Ex-date',
              },
              palette: palette,
              onChanged: onDateModeChanged,
            ),
          ],
        );

        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              rangeControls,
              const SizedBox(height: 10),
              search,
              const SizedBox(height: 10),
              filters,
            ],
          );
        }
        return Row(
          children: [
            rangeControls,
            const Spacer(),
            search,
            const SizedBox(width: 10),
            filters,
          ],
        );
      },
    );
  }
}

class DividendWindowSelector extends StatelessWidget {
  const DividendWindowSelector({
    super.key,
    required this.value,
    required this.palette,
    required this.onChanged,
  });

  final String value;
  final Palette palette;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.card,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: dividendCalendarWindowOptions.map((option) {
          final selected = value == option.key;
          return InkWell(
            onTap: () => onChanged(option.key),
            borderRadius: BorderRadius.circular(999),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 16,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? palette.text.withValues(alpha: .92)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                context.ui(option.label),
                style: TextStyle(
                  color: selected ? palette.background : palette.muted,
                  fontWeight: FontWeight.w900,
                  fontSize: compact ? 12 : 13,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class DividendDropdown extends StatelessWidget {
  const DividendDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.palette,
    required this.onChanged,
  });

  final String value;
  final Map<String, String> items;
  final Palette palette;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          dropdownColor: palette.card,
          iconEnabledColor: palette.muted,
          style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
          items: [
            for (final entry in items.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(context.ui(entry.value)),
              ),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

class DividendIncomeSummaryCard extends StatelessWidget {
  const DividendIncomeSummaryCard({
    super.key,
    required this.annualIncome,
    required this.monthlyIncome,
    required this.dailyIncome,
    required this.yield,
    required this.currency,
    required this.palette,
  });

  final double annualIncome;
  final double monthlyIncome;
  final double dailyIncome;
  final double yield;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 236),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.ui('Annual income'),
                      style: TextStyle(
                        color: palette.text.withValues(alpha: .82),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.open_in_new_rounded,
                      color: palette.muted,
                      size: 12,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  formatDividendMoney(annualIncome, currency),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 28,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.background.withValues(alpha: .34),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                DividendSummaryStat(
                  icon: Icons.bar_chart_rounded,
                  label: 'Monthly',
                  value: formatDividendMoney(monthlyIncome, currency),
                  palette: palette,
                ),
                const SizedBox(height: 14),
                DividendSummaryStat(
                  icon: Icons.wb_twilight_rounded,
                  label: 'Daily',
                  value: formatDividendMoney(dailyIncome, currency),
                  palette: palette,
                ),
                const SizedBox(height: 14),
                DividendSummaryStat(
                  icon: Icons.percent_rounded,
                  label: 'Yield',
                  value: formatReturn(yield).replaceFirst('+', ''),
                  palette: palette,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DividendSummaryStat extends StatelessWidget {
  const DividendSummaryStat({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final String value;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF54B8F6), size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            context.ui(label),
            style: TextStyle(
              color: palette.text.withValues(alpha: .68),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(color: palette.text, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class DividendMonthlyChartCard extends StatelessWidget {
  const DividendMonthlyChartCard({
    super.key,
    required this.buckets,
    required this.comparisonBuckets,
    required this.comparisonYears,
    required this.currency,
    required this.palette,
  });

  final List<DividendMonthBucket> buckets;
  final List<DividendYearComparisonBucket> comparisonBuckets;
  final List<int> comparisonYears;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final hasComparison = comparisonBuckets.isNotEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 236),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 190,
            child: hasComparison
                ? PortfolioDividendYearComparisonChart(
                    buckets: comparisonBuckets,
                    years: comparisonYears,
                    currency: currency,
                    palette: palette,
                  )
                : PortfolioDividendBarChart(
                    buckets: buckets,
                    currency: currency,
                    palette: palette,
                  ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            runSpacing: 8,
            children: hasComparison
                ? [
                    DividendLegendDot(
                      '2025 paid history',
                      dividend2025Color,
                      palette,
                    ),
                    DividendLegendDot(
                      '2026 paid + forecast',
                      dividend2026Color,
                      palette,
                    ),
                  ]
                : [
                    DividendLegendDot('Paid', dividendPaidColor, palette),
                    DividendLegendDot(
                      'Declared',
                      dividendDeclaredColor,
                      palette,
                    ),
                    DividendLegendDot(
                      'Estimated',
                      dividendEstimatedColor,
                      palette,
                    ),
                  ],
          ),
        ],
      ),
    );
  }
}

class DividendLegendDot extends StatelessWidget {
  const DividendLegendDot(this.label, this.color, this.palette, {super.key});

  final String label;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          context.ui(label),
          style: TextStyle(color: palette.muted, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class PortfolioDividendBarChart extends StatelessWidget {
  const PortfolioDividendBarChart({
    super.key,
    required this.buckets,
    required this.currency,
    required this.palette,
  });

  final List<DividendMonthBucket> buckets;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final maxTotal = buckets.fold<double>(
      0,
      (maxValue, bucket) => math.max(maxValue, bucket.total),
    );
    if (maxTotal <= 0) {
      return EmptyState(
        text: 'No payout bars for this window.',
        palette: palette,
      );
    }
    return CustomPaint(
      painter: DividendGridPainter(palette: palette),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chartHeight = math.max(120.0, constraints.maxHeight - 42);
          final compact = constraints.maxWidth < 620;
          final shownBuckets = compact
              ? buckets.where((bucket) => bucket.total > 0).take(6).toList()
              : buckets;
          final visibleBuckets = shownBuckets.isEmpty
              ? buckets.take(compact ? 6 : buckets.length).toList()
              : shownBuckets;
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final bucket in visibleBuckets)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 4 : 8,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox(
                            height: 22,
                            child: bucket.total > 0
                                ? Text(
                                    formatDividendMoney(
                                      bucket.total,
                                      currency,
                                      compact: true,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.muted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          SizedBox(
                            height: chartHeight,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Tooltip(
                                message: bucket.tooltip(
                                  currency,
                                  language: context.language,
                                ),
                                child: DividendStackedBar(
                                  bucket: bucket,
                                  maxTotal: maxTotal,
                                  chartHeight: chartHeight,
                                  palette: palette,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            context.ui(bucket.label),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PortfolioDividendYearComparisonChart extends StatelessWidget {
  const PortfolioDividendYearComparisonChart({
    super.key,
    required this.buckets,
    required this.years,
    required this.currency,
    required this.palette,
  });

  final List<DividendYearComparisonBucket> buckets;
  final List<int> years;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final maxTotal = buckets.fold<double>(
      0,
      (maxValue, bucket) => math.max(maxValue, bucket.maxTotal),
    );
    if (maxTotal <= 0) {
      return EmptyState(
        text: 'No 2025/2026 dividend history for this filter.',
        palette: palette,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final chartWidth = compact ? 780.0 : constraints.maxWidth;
        return ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(scrollbars: false),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: chartWidth,
              child: CustomPaint(
                painter: DividendGridPainter(palette: palette),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final bucket in buckets)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                SizedBox(
                                  height: 24,
                                  child: Text(
                                    bucket.topLabel(currency),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.muted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  height: math.max(
                                    120.0,
                                    constraints.maxHeight - 44,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      for (final year in years) ...[
                                        DividendYearBar(
                                          bucket: bucket.bucketForYear(year),
                                          year: year,
                                          maxTotal: maxTotal,
                                          chartHeight: math.max(
                                            120.0,
                                            constraints.maxHeight - 44,
                                          ),
                                          currency: currency,
                                          palette: palette,
                                        ),
                                        if (year != years.last)
                                          const SizedBox(width: 5),
                                      ],
                                    ],
                                  ),
                                ),
                                Text(
                                  context.ui(monthNamesShort[bucket.month - 1]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DividendYearBar extends StatelessWidget {
  const DividendYearBar({
    super.key,
    required this.bucket,
    required this.year,
    required this.maxTotal,
    required this.chartHeight,
    required this.currency,
    required this.palette,
  });

  final DividendMonthBucket bucket;
  final int year;
  final double maxTotal;
  final double chartHeight;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final color = dividendYearColor(year);
    final total = bucket.total;
    final height = total <= 0 || maxTotal <= 0
        ? 2.0
        : math.max(5.0, chartHeight * .82 * total / maxTotal);
    final width = MediaQuery.sizeOf(context).width < 760 ? 22.0 : 28.0;
    final bar = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: total > 0 ? color : palette.border.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(7),
        border: total > 0
            ? Border.all(color: color.withValues(alpha: .26))
            : null,
      ),
    );
    return Tooltip(
      message: bucket.tooltip(
        currency,
        titleYear: year,
        language: context.language,
      ),
      child: bar,
    );
  }
}

class DividendStackedBar extends StatelessWidget {
  const DividendStackedBar({
    super.key,
    required this.bucket,
    required this.maxTotal,
    required this.chartHeight,
    required this.palette,
  });

  final DividendMonthBucket bucket;
  final double maxTotal;
  final double chartHeight;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final height = bucket.total <= 0 || maxTotal <= 0
        ? 2.0
        : math.max(4.0, chartHeight * .82 * bucket.total / maxTotal);
    final width = MediaQuery.sizeOf(context).width < 760 ? 26.0 : 34.0;
    if (bucket.total <= 0) {
      return Container(
        width: width,
        height: 2,
        decoration: BoxDecoration(
          color: palette.border,
          borderRadius: BorderRadius.circular(8),
        ),
      );
    }
    double segmentHeight(double value) =>
        bucket.total <= 0 ? 0 : math.max(0, height * value / bucket.total);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            DividendBarSegment(
              height: segmentHeight(bucket.estimated),
              color: dividendEstimatedColor,
            ),
            DividendBarSegment(
              height: segmentHeight(bucket.declared),
              color: dividendDeclaredColor,
            ),
            DividendBarSegment(
              height: segmentHeight(bucket.paid),
              color: dividendPaidColor,
            ),
          ],
        ),
      ),
    );
  }
}

class DividendBarSegment extends StatelessWidget {
  const DividendBarSegment({
    super.key,
    required this.height,
    required this.color,
  });

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (height <= 0) return const SizedBox.shrink();
    return Container(width: double.infinity, height: height, color: color);
  }
}

class DividendGridPainter extends CustomPainter {
  DividendGridPainter({required this.palette});

  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = palette.muted.withValues(alpha: .18)
      ..strokeWidth = 1;
    for (var i = 1; i <= 4; i += 1) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant DividendGridPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

class DividendViewToggle extends StatelessWidget {
  const DividendViewToggle({
    super.key,
    required this.calendarView,
    required this.palette,
    required this.onChanged,
  });

  final bool calendarView;
  final Palette palette;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DividendToggleButton(
            active: calendarView,
            icon: Icons.calendar_month_rounded,
            label: 'Calendar',
            palette: palette,
            onTap: () => onChanged(true),
          ),
          DividendToggleButton(
            active: !calendarView,
            icon: Icons.list_rounded,
            label: 'List',
            palette: palette,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class DividendToggleButton extends StatelessWidget {
  const DividendToggleButton({
    super.key,
    required this.active,
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? palette.text : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? palette.background : palette.muted,
            ),
            const SizedBox(width: 6),
            Text(
              context.ui(label),
              style: TextStyle(
                color: active ? palette.background : palette.muted,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DividendEmptyMonthNotice extends StatelessWidget {
  const DividendEmptyMonthNotice({
    super.key,
    required this.monthStart,
    required this.nextMonth,
    required this.palette,
    required this.onJumpToNext,
  });

  final DateTime monthStart;
  final DateTime? nextMonth;
  final Palette palette;
  final VoidCallback? onJumpToNext;

  @override
  Widget build(BuildContext context) {
    final next = nextMonth;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(Icons.calendar_month_rounded, color: palette.muted, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tr(
                '${dividendWindowTitle(monthStart, context.language)}没有股息事件。',
                '${dividendWindowTitle(monthStart, context.language)} has no dividend events.',
              ),
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (next != null)
            TextButton.icon(
              onPressed: onJumpToNext,
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: Text(
                context.tr(
                  '下一个：${dividendWindowTitle(next, context.language)}',
                  'Next: ${dividendWindowTitle(next, context.language)}',
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: palette.accent,
                textStyle: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
        ],
      ),
    );
  }
}

class DividendMonthCalendarGrid extends StatelessWidget {
  const DividendMonthCalendarGrid({
    super.key,
    required this.monthStart,
    required this.events,
    required this.currency,
    required this.portfolioValue,
    required this.palette,
  });

  final DateTime monthStart;
  final List<DividendDisplayEvent> events;
  final String currency;
  final double portfolioValue;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final start = DateTime(monthStart.year, monthStart.month, 1);
    final today = DateTime.now();
    final normalizedToday = DateTime(today.year, today.month, today.day);
    final eventsByDay = <int, List<DividendDisplayEvent>>{};
    for (final event in events) {
      eventsByDay.putIfAbsent(event.date.day, () => []).add(event);
    }
    for (final dayEvents in eventsByDay.values) {
      dayEvents.sort(
        (left, right) => right.payoutBase.compareTo(left.payoutBase),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        if (compact) {
          return DividendMonthAgenda(
            monthStart: start,
            eventsByDay: eventsByDay,
            currency: currency,
            portfolioValue: portfolioValue,
            palette: palette,
          );
        }

        final leadingBlanks = start.weekday % 7;
        final dayCount = DateTime(start.year, start.month + 1, 0).day;
        final rowCount = ((leadingBlanks + dayCount) / 7).ceil();
        final cellHeight = constraints.maxWidth >= 1180 ? 132.0 : 120.0;
        final cells = rowCount * 7;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          decoration: BoxDecoration(
            color: palette.card.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  for (final dayName in dividendWeekdayLabels)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          context.ui(dayName),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  children: [
                    for (var row = 0; row < rowCount; row += 1)
                      Row(
                        children: [
                          for (var column = 0; column < 7; column += 1)
                            Expanded(
                              child: Builder(
                                builder: (context) {
                                  final index = row * 7 + column;
                                  final day = index - leadingBlanks + 1;
                                  final inMonth = day >= 1 && day <= dayCount;
                                  final date = inMonth
                                      ? DateTime(start.year, start.month, day)
                                      : null;
                                  return DividendCalendarDayCell(
                                    height: cellHeight,
                                    day: inMonth ? day : null,
                                    date: date,
                                    events: inMonth
                                        ? eventsByDay[day] ??
                                              const <DividendDisplayEvent>[]
                                        : const <DividendDisplayEvent>[],
                                    currency: currency,
                                    portfolioValue: portfolioValue,
                                    palette: palette,
                                    isToday: date == normalizedToday,
                                    showRightBorder: column < 6,
                                    showBottomBorder: index < cells - 7,
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class DividendCalendarDayCell extends StatelessWidget {
  const DividendCalendarDayCell({
    super.key,
    required this.height,
    required this.day,
    required this.date,
    required this.events,
    required this.currency,
    required this.portfolioValue,
    required this.palette,
    required this.isToday,
    required this.showRightBorder,
    required this.showBottomBorder,
  });

  final double height;
  final int? day;
  final DateTime? date;
  final List<DividendDisplayEvent> events;
  final String currency;
  final double portfolioValue;
  final Palette palette;
  final bool isToday;
  final bool showRightBorder;
  final bool showBottomBorder;

  @override
  Widget build(BuildContext context) {
    final inMonth = day != null && date != null;
    final total = events.fold<double>(
      0,
      (sum, event) => sum + event.payoutBase.abs(),
    );
    final dayColor = inMonth
        ? palette.text.withValues(alpha: .78)
        : palette.faint.withValues(alpha: .22);

    return Container(
      height: height,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: inMonth
            ? Colors.transparent
            : palette.muted.withValues(alpha: .09),
        border: Border(
          right: showRightBorder
              ? BorderSide(color: palette.border.withValues(alpha: .8))
              : BorderSide.none,
          bottom: showBottomBorder
              ? BorderSide(color: palette.border.withValues(alpha: .8))
              : BorderSide.none,
        ),
      ),
      child: inMonth
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (isToday)
                      Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: dividendDeclaredColor,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$day',
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      )
                    else
                      Text(
                        '$day',
                        style: TextStyle(
                          color: dayColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    const Spacer(),
                    if (total > 0)
                      Text(
                        '+${formatDividendMoney(total, currency, compact: true)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.positive,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final event in events.take(1)) ...[
                  DividendCalendarEventChip(
                    event: event,
                    portfolioValue: portfolioValue,
                    palette: palette,
                  ),
                  const SizedBox(height: 6),
                ],
                if (events.length > 1)
                  Text(
                    context.tr(
                      '另有 ${events.length - 1} 项',
                      '+${events.length - 1} more',
                    ),
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

class DividendCalendarEventChip extends StatelessWidget {
  const DividendCalendarEventChip({
    super.key,
    required this.event,
    required this.portfolioValue,
    required this.palette,
  });

  final DividendDisplayEvent event;
  final double portfolioValue;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (event.status) {
      'paid' => dividendPaidColor,
      'declared' => dividendDeclaredColor,
      _ => dividendEstimatedColor,
    };
    final weight = portfolioValue > 0
        ? event.payoutBase.abs() / portfolioValue
        : 0.0;
    final tooltip = [
      '${event.ticker} ${context.ui(event.statusLabel)}',
      context.tr(
        '日期：${formatDate(event.isoDate)}',
        'Date: ${formatDate(event.isoDate)}',
      ),
      context.tr(
        '股息：${formatDividendMoney(event.payout.abs(), event.currency)}',
        'Payout: ${formatDividendMoney(event.payout.abs(), event.currency)}',
      ),
      if (event.hasCurrencyConversion)
        context.tr(
          '本币：${formatDividendMoney(event.payoutBase.abs(), event.displayCurrency)} (${event.currency} × ${event.fxRateToBase.toStringAsFixed(4)})',
          'Base: ${formatDividendMoney(event.payoutBase.abs(), event.displayCurrency)} (${event.currency} x ${event.fxRateToBase.toStringAsFixed(4)})',
        ),
      if (event.quantity > 0)
        context.tr(
          '股数：${formatNumber(event.quantity)}',
          'Shares: ${formatNumber(event.quantity)}',
        ),
    ].join('\n');

    return Tooltip(
      message: tooltip,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: palette.background.withValues(alpha: .42),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: statusColor.withValues(alpha: .28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 3, color: statusColor),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                children: [
                  Row(
                    children: [
                      PortfolioHoldingLogo(
                        row: event.logoRow,
                        palette: palette,
                        size: 22,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${event.ticker} ${compactName(event.name)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text.withValues(alpha: .9),
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Text(
                        formatDividendMoney(
                          event.payoutBase.abs(),
                          event.displayCurrency,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          formatReturn(weight).replaceFirst('+', ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DividendMonthAgenda extends StatelessWidget {
  const DividendMonthAgenda({
    super.key,
    required this.monthStart,
    required this.eventsByDay,
    required this.currency,
    required this.portfolioValue,
    required this.palette,
  });

  final DateTime monthStart;
  final Map<int, List<DividendDisplayEvent>> eventsByDay;
  final String currency;
  final double portfolioValue;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final days = eventsByDay.keys.toList()..sort();
    if (days.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.border),
        ),
        child: EmptyState(
          text: context.tr(
            '${dividendWindowTitle(monthStart, context.language)}没有股息事件。',
            'No dividend events in ${dividendWindowTitle(monthStart, context.language)}.',
          ),
          palette: palette,
        ),
      );
    }
    return Column(
      children: [
        for (final day in days)
          DividendAgendaDayCard(
            date: DateTime(monthStart.year, monthStart.month, day),
            events: eventsByDay[day] ?? const <DividendDisplayEvent>[],
            currency: currency,
            portfolioValue: portfolioValue,
            palette: palette,
          ),
      ],
    );
  }
}

class DividendAgendaDayCard extends StatelessWidget {
  const DividendAgendaDayCard({
    super.key,
    required this.date,
    required this.events,
    required this.currency,
    required this.portfolioValue,
    required this.palette,
  });

  final DateTime date;
  final List<DividendDisplayEvent> events;
  final String currency;
  final double portfolioValue;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final isoDate =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final total = events.fold<double>(
      0,
      (sum, event) => sum + event.payoutBase.abs(),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: dividendDeclaredColor.withValues(alpha: .16),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    color: dividendDeclaredColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  formatDate(isoDate),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '+${formatDividendMoney(total, currency)}',
                style: TextStyle(
                  color: palette.positive,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DividendCalendarEventChip(
                event: event,
                portfolioValue: portfolioValue,
                palette: palette,
              ),
            ),
        ],
      ),
    );
  }
}

class DividendCalendarEventGroups extends StatelessWidget {
  const DividendCalendarEventGroups({
    super.key,
    required this.events,
    required this.currency,
    required this.palette,
  });

  final List<DividendDisplayEvent> events;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final byDate = <String, List<DividendDisplayEvent>>{};
    for (final event in events) {
      byDate.putIfAbsent(event.isoDate, () => []).add(event);
    }
    final entries = byDate.entries.take(10).toList();
    return Column(
      children: [
        for (final entry in entries)
          DividendDateGroupCard(
            date: entry.key,
            events: entry.value,
            currency: currency,
            palette: palette,
          ),
      ],
    );
  }
}

class DividendDateGroupCard extends StatelessWidget {
  const DividendDateGroupCard({
    super.key,
    required this.date,
    required this.events,
    required this.currency,
    required this.palette,
  });

  final String date;
  final List<DividendDisplayEvent> events;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final total = events.fold<double>(
      0,
      (sum, event) => sum + event.payoutBase.abs(),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_today_rounded,
                color: palette.accent,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  formatDate(date),
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: palette.positive.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '+${formatDividendMoney(total, currency)}',
                  style: TextStyle(
                    color: palette.positive,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final event in events.take(5))
            DividendEventRow(event: event, palette: palette),
        ],
      ),
    );
  }
}

class DividendEventList extends StatelessWidget {
  const DividendEventList({
    super.key,
    required this.events,
    required this.currency,
    required this.palette,
  });

  final List<DividendDisplayEvent> events;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          for (final event in events.take(18))
            DividendEventRow(event: event, palette: palette),
        ],
      ),
    );
  }
}

class DividendEventRow extends StatelessWidget {
  const DividendEventRow({
    super.key,
    required this.event,
    required this.palette,
  });

  final DividendDisplayEvent event;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final statusColor = switch (event.status) {
      'paid' => dividendPaidColor,
      'declared' => dividendDeclaredColor,
      _ => dividendEstimatedColor,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          PortfolioHoldingLogo(row: event.logoRow, palette: palette, size: 28),
          const SizedBox(width: 10),
          SizedBox(
            width: compact ? 86 : 128,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.ticker,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  context.ui(event.statusLabel),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              compact
                  ? formatDate(event.isoDate)
                  : event.subtitleFor(context.language),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatDividendMoney(event.payout.abs(), event.currency),
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (!compact && event.hasCurrencyConversion)
                Text(
                  context.tr(
                    '${formatDividendMoney(event.payoutBase.abs(), event.displayCurrency)} 本币',
                    '${formatDividendMoney(event.payoutBase.abs(), event.displayCurrency)} base',
                  ),
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (!compact && event.quantity > 0)
                Text(
                  context.tr(
                    '${formatDividendMoney(event.amount.abs(), event.currency)} / 股',
                    '${formatDividendMoney(event.amount.abs(), event.currency)} / sh',
                  ),
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

const dividend2025Color = Color(0xFF8D6AF4);
const dividend2026Color = Color(0xFF54B8F6);
const dividendPaidColor = dividend2025Color;
const dividendDeclaredColor = Color(0xFF54B8F6);
const dividendEstimatedColor = Color(0xFF3F7EAA);

Color dividendYearColor(int year) => year == 2025
    ? dividend2025Color
    : year == 2026
    ? dividend2026Color
    : dividendEstimatedColor;

class DividendCalendarWindowOption {
  const DividendCalendarWindowOption(this.key, this.label);

  final String key;
  final String label;
}

class DividendCalendarWindow {
  const DividendCalendarWindow({
    required this.key,
    required this.label,
    required this.start,
    required this.end,
  });

  final String key;
  final String label;
  final DateTime start;
  final DateTime end;
}

const dividendCalendarWindowOptions = [
  DividendCalendarWindowOption('2025', '2025'),
  DividendCalendarWindowOption('2026', '2026'),
  DividendCalendarWindowOption('forward', 'One year ahead'),
];

DividendCalendarWindow dividendCalendarWindowForKey(
  String key,
  DateTime today,
) {
  final normalizedToday = DateTime(today.year, today.month, today.day);
  if (key == '2025' || key == '2026') {
    final year = int.parse(key);
    return DividendCalendarWindow(
      key: key,
      label: key,
      start: DateTime(year, 1, 1),
      end: DateTime(year, 12, 31),
    );
  }
  final start = DateTime(normalizedToday.year, normalizedToday.month, 1);
  return DividendCalendarWindow(
    key: 'forward',
    label: 'One year ahead',
    start: start,
    end: DateTime(start.year, start.month + 12, 0),
  );
}

class DividendDisplayEvent {
  DividendDisplayEvent({
    required this.ticker,
    required this.name,
    required this.date,
    required this.amount,
    required this.payout,
    required this.payoutBase,
    required this.quantity,
    required this.currency,
    required this.displayCurrency,
    required this.fxRateToBase,
    required this.status,
    required this.type,
    required this.logoUrl,
    required this.sourceLabel,
  });

  final String ticker;
  final String name;
  final DateTime date;
  final double amount;
  final double payout;
  final double payoutBase;
  final double quantity;
  final String currency;
  final String displayCurrency;
  final double fxRateToBase;
  final String status;
  final String type;
  final String logoUrl;
  final String sourceLabel;

  bool get hasCurrencyConversion =>
      normalizeDividendCurrency(currency) !=
      normalizeDividendCurrency(displayCurrency);

  String get isoDate =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String get statusLabel => switch (status) {
    'paid' => 'Paid',
    'declared' => 'Declared',
    _ => 'Estimated',
  };

  String subtitleFor(AppLanguage language) {
    final quantityText = quantity > 0
        ? trFor(
            language,
            ' · ${formatNumber(quantity)} 股',
            ' · ${formatNumber(quantity)} shares',
          )
        : '';
    return '${compactName(name)} · ${formatDate(isoDate)}$quantityText';
  }

  Map<String, dynamic> get logoRow => {
    'ticker': ticker,
    'name': name,
    'logoUrl': logoUrl,
  };
}

class DividendMonthBucket {
  DividendMonthBucket(this.monthStart);

  final DateTime monthStart;
  final events = <DividendDisplayEvent>[];

  String get label => monthNamesShort[monthStart.month - 1];
  double get paid => _sum('paid');
  double get declared => _sum('declared');
  double get estimated => _sum('estimated');
  double get total =>
      events.fold<double>(0, (sum, event) => sum + event.payoutBase.abs());

  void add(DividendDisplayEvent event) => events.add(event);

  double _sum(String status) => events
      .where((event) => event.status == status)
      .fold<double>(0, (sum, event) => sum + event.payoutBase.abs());

  String tooltip(
    String currency, {
    int? titleYear,
    required AppLanguage language,
  }) {
    final byTicker = <String, double>{};
    for (final event in events) {
      byTicker[event.ticker] =
          (byTicker[event.ticker] ?? 0) + event.payoutBase.abs();
    }
    final contributors = byTicker.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    final topContributors = contributors.take(6).map((entry) {
      return '${entry.key}: ${formatDividendMoney(entry.value, currency)}';
    });
    final month = trFor(
      language,
      '${monthStart.month} 月',
      monthNamesShort[monthStart.month - 1],
    );
    final title = titleYear == null
        ? month
        : trFor(language, '$titleYear 年 $month', '$month $titleYear');
    return [
      '$title: ${formatDividendMoney(total, currency)}',
      '${trFor(language, '已支付', 'Paid')}: ${formatDividendMoney(paid, currency)}',
      '${trFor(language, '已宣布', 'Declared')}: ${formatDividendMoney(declared, currency)}',
      '${trFor(language, '预估', 'Estimated')}: ${formatDividendMoney(estimated, currency)}',
      if (contributors.isNotEmpty) trFor(language, '持仓：', 'Holdings:'),
      ...topContributors,
      if (contributors.length > 6)
        trFor(
          language,
          '另有 ${contributors.length - 6} 项',
          '+${contributors.length - 6} more',
        ),
    ].join('\n');
  }
}

class DividendYearComparisonBucket {
  DividendYearComparisonBucket({required this.month, required List<int> years})
    : _byYear = {
        for (final year in years)
          year: DividendMonthBucket(DateTime(year, month, 1)),
      };

  final int month;
  final Map<int, DividendMonthBucket> _byYear;

  double get maxTotal => _byYear.values.fold<double>(
    0,
    (maxValue, bucket) => math.max(maxValue, bucket.total),
  );

  DividendMonthBucket bucketForYear(int year) =>
      _byYear[year] ?? DividendMonthBucket(DateTime(year, month, 1));

  void add(DividendDisplayEvent event) =>
      bucketForYear(event.date.year).add(event);

  String topLabel(String currency) {
    if (maxTotal <= 0) return '';
    return formatDividendMoney(maxTotal, currency, compact: true);
  }
}

List<DividendYearComparisonBucket> dividendYearComparisonBuckets(
  List<int> years,
  List<DividendDisplayEvent> events,
) {
  final normalizedYears = years.toSet();
  final buckets = [
    for (var month = 1; month <= 12; month += 1)
      DividendYearComparisonBucket(month: month, years: years),
  ];
  for (final event in events) {
    if (!normalizedYears.contains(event.date.year)) continue;
    buckets[event.date.month - 1].add(event);
  }
  return buckets;
}

const monthNamesShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const dividendWeekdayLabels = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

double dividendHoldingShareQuantity(Map<String, dynamic> holding) {
  final ticker = text(holding['ticker']).toUpperCase();
  final quantity =
      firstNumber([
        holding['quantity'],
        holding['shares'],
        holding['units'],
        holding['position'],
      ]) ??
      0;
  final rawPrice =
      firstNumber([
        holding['price'],
        holding['holdingPrice'],
        holding['markPrice'],
        holding['closePrice'],
        holding['reportDatePrice'],
      ]) ??
      0;
  final currency = normalizeDividendCurrency(text(holding['currency'], 'USD'));
  final fxRateToBase = math.max(
    .000001,
    firstNumber([holding['fxRateToBase'], holding['fxRate']]) ?? 1,
  );
  final value =
      firstNumber([
        holding['value'],
        holding['holdingValue'],
        holding['marketValue'],
        holding['positionValue'],
        holding['currentValue'],
      ]) ??
      0;
  var price = rawPrice;
  if (currency == 'GBP' && rawPrice > 100) {
    final pencePrice = rawPrice / 100;
    final canCompareValue = quantity > 0 && value > 0;
    if (canCompareValue) {
      final rawError =
          (quantity * rawPrice * fxRateToBase - value).abs() /
          math.max(1, value.abs());
      final penceError =
          (quantity * pencePrice * fxRateToBase - value).abs() /
          math.max(1, value.abs());
      if (penceError < rawError && (penceError < .35 || rawError > .5)) {
        price = pencePrice;
      }
    } else if (dividendTickerLooksLondon(ticker) && rawPrice >= 1000) {
      price = pencePrice;
    }
  }
  if (price <= 0 || value <= 0) return math.max(0, quantity);
  final priceInBase = price * fxRateToBase;
  final impliedQuantity = value / priceInBase;
  if (quantity <= 0) return math.max(0, impliedQuantity);
  final valueFromQuantity = quantity * priceInBase;
  final relativeValueError =
      (valueFromQuantity - value).abs() / math.max(1, value.abs());
  final quantityLooksLikeMarketValue =
      price > 1.01 &&
      value > 100 &&
      (quantity - value).abs() / math.max(1, value.abs()) < .03;
  final quantityIsImplausiblyHigh =
      price > 1.01 && quantity > impliedQuantity * 20;
  if (quantityLooksLikeMarketValue ||
      quantityIsImplausiblyHigh ||
      relativeValueError > .5) {
    return math.max(0, impliedQuantity);
  }
  return math.max(0, quantity);
}

bool dividendEventUsesPerShareAmount(
  Map<String, dynamic> event,
  String source,
) {
  final amountKind =
      '${text(event['amountKind'])} ${text(asMap(event['payload'])['amountKind'])}'
          .toLowerCase()
          .replaceAll('-', '_');
  if (amountKind.contains('total') ||
      amountKind.contains('cash') ||
      text(event['perShare']).toLowerCase() == 'false') {
    return false;
  }
  if (amountKind.contains('per_share') || truthy(event['perShare'])) {
    return true;
  }
  final status = text(event['status']).toLowerCase();
  return source.contains('yahoo') ||
      source.contains('nasdaq') ||
      source.contains('estimate') ||
      source.contains('calendar') ||
      status == 'estimated';
}

bool dividendCurrencyLooksPence(String currency) {
  final raw = currency.trim();
  final compact = raw.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase();
  return raw == 'GBp' ||
      compact == 'GBX' ||
      compact == 'GBPENCE' ||
      compact == 'PENCE' ||
      compact == 'PENNY';
}

bool dividendTickerLooksLondon(String ticker) {
  final normalized = ticker.toUpperCase();
  return normalized == 'AZN' ||
      normalized == 'LSEG' ||
      normalized == 'LSEGL' ||
      normalized == 'AZNL' ||
      normalized.endsWith('.L');
}

bool dividendAmountLooksPence({
  required String ticker,
  required String currency,
  required String source,
  required double amount,
}) {
  if (!amount.isFinite || amount.abs() < 5) return false;
  final sourceText = source.toLowerCase();
  final marketDataPenceSource =
      sourceText.contains('yahoo') ||
      sourceText.contains('lseg') ||
      sourceText.contains('market') ||
      sourceText.contains('history');
  return dividendCurrencyLooksPence(currency) ||
      ((dividendTickerLooksLondon(ticker) || sourceText.contains('london')) &&
          currency.toUpperCase() == 'GBP' &&
          marketDataPenceSource);
}

String normalizeDividendCurrency(String currency, [String fallback = 'USD']) {
  final raw = text(currency, fallback).trim();
  final compact = raw.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase();
  if (compact == 'GBX' ||
      compact == 'GBPENCE' ||
      compact == 'PENCE' ||
      compact == 'PENNY' ||
      raw == 'GBp') {
    return 'GBP';
  }
  return compact.isEmpty ? fallback.toUpperCase() : compact;
}

double fallbackDividendFxRate(String fromCurrency, String toCurrency) {
  final from = normalizeDividendCurrency(fromCurrency);
  final to = normalizeDividendCurrency(toCurrency);
  if (from == to) return 1;
  const usdRates = {
    'USD': 1.0,
    'GBP': 1.27,
    'EUR': 1.08,
    'CAD': .73,
    'JPY': .0064,
    'HKD': .128,
    'CHF': 1.12,
    'AUD': .66,
    'SGD': .74,
    'TWD': .031,
  };
  final fromUsd = usdRates[from];
  final toUsd = usdRates[to];
  if (fromUsd == null || toUsd == null || toUsd <= 0) return 1;
  return fromUsd / toUsd;
}

double dividendFxRateToBase({
  required Map<String, dynamic> event,
  required Map<String, dynamic> holding,
  required String currency,
  required String baseCurrency,
}) {
  final from = normalizeDividendCurrency(currency);
  final to = normalizeDividendCurrency(baseCurrency);
  if (from == to) return 1;
  final payload = asMap(event['payload']);
  final explicitRate = firstNumber([
    event['fxRateToBase'],
    event['fxRate'],
    payload['fxRateToBase'],
    payload['fxRate'],
    holding['fxRateToBase'],
    holding['fxRate'],
  ]);
  if (explicitRate != null &&
      explicitRate > 0 &&
      (explicitRate - 1).abs() > .0001) {
    return explicitRate;
  }
  return fallbackDividendFxRate(from, to);
}

List<DividendDisplayEvent> normalizeDividendDisplayEvents(
  List<Map<String, dynamic>> dividends,
  List<Map<String, dynamic>> holdings, {
  required String dateMode,
  required String baseCurrency,
}) {
  final holdingsByTicker = <String, Map<String, dynamic>>{};
  final quantityByTicker = <String, double>{};
  for (final holding in holdings) {
    final ticker = text(holding['ticker']).toUpperCase();
    if (ticker.isEmpty) continue;
    final assetClass =
        '${text(holding['sector'])} ${text(holding['assetCategory'])} ${text(holding['type'])}'
            .toLowerCase();
    if (assetClass.contains('option') ||
        assetClass == 'opt' ||
        assetClass.contains('future') ||
        assetClass.contains('cash')) {
      continue;
    }
    final shareQuantity = dividendHoldingShareQuantity(holding);
    if (shareQuantity <= 0) continue;
    holdingsByTicker.putIfAbsent(ticker, () => holding);
    quantityByTicker[ticker] = (quantityByTicker[ticker] ?? 0) + shareQuantity;
  }

  final events = <DividendDisplayEvent>[];
  for (final event in dividends) {
    final ticker = text(event['ticker']).toUpperCase();
    if (ticker.isEmpty) continue;
    final dateText = dividendEventDateForMode(event, dateMode);
    final date = parseDividendDate(dateText);
    if (date == null) continue;
    final source = '${text(event['source'])} ${text(event['sourceLabel'])}'
        .toLowerCase();
    final rawCurrency = text(event['currency'], 'USD');
    final rawAmount = number(event['amount']);
    if (rawAmount == 0) continue;
    final shouldNormalizePence = dividendAmountLooksPence(
      ticker: ticker,
      currency: rawCurrency,
      source: source,
      amount: rawAmount,
    );
    final amount = shouldNormalizePence ? rawAmount / 100 : rawAmount;
    final currency = shouldNormalizePence
        ? 'GBP'
        : normalizeDividendCurrency(rawCurrency);
    final amountMultiplier = rawAmount.abs() > 0 ? amount / rawAmount : 1.0;
    final holding = holdingsByTicker[ticker] ?? const <String, dynamic>{};
    final eventQuantity =
        firstNumber([
          event['quantity'],
          event['shares'],
          event['holdingQuantity'],
        ]) ??
        0;
    final fallbackQuantity = dividendHoldingShareQuantity({
      ...event,
      'quantity': eventQuantity,
    });
    final quantity = quantityByTicker[ticker] ?? fallbackQuantity;
    final perShare = dividendEventUsesPerShareAmount(event, source);
    final rawExplicitPayout = firstNumber([
      event['estimatedPayout'],
      event['payout'],
      event['totalPayout'],
      event['cashAmount'],
      event['totalAmount'],
    ]);
    final explicitPayout =
        shouldNormalizePence && perShare && rawExplicitPayout != null
        ? rawExplicitPayout * amountMultiplier
        : rawExplicitPayout;
    final payout = perShare
        ? (explicitPayout != null && explicitPayout.abs() > amount.abs()
              ? explicitPayout
              : amount * quantity)
        : (explicitPayout ?? amount);
    if (payout == 0) continue;
    final displayCurrency = normalizeDividendCurrency(baseCurrency);
    final fxRateToBase = dividendFxRateToBase(
      event: event,
      holding: holding,
      currency: currency,
      baseCurrency: displayCurrency,
    );
    final payoutBase = payout * fxRateToBase;
    final status = dividendStatusForEvent(event, date);
    events.add(
      DividendDisplayEvent(
        ticker: ticker,
        name: text(
          event['companyName'],
          text(event['name'], text(holding['name'], ticker)),
        ),
        date: date,
        amount: amount,
        payout: payout,
        payoutBase: payoutBase,
        quantity: quantity,
        currency: currency,
        displayCurrency: displayCurrency,
        fxRateToBase: fxRateToBase,
        status: status,
        type: text(event['type'], 'Dividend'),
        logoUrl: text(event['logoUrl'], text(holding['logoUrl'])),
        sourceLabel: text(event['sourceLabel'], text(event['source'])),
      ),
    );
  }
  return events;
}

List<DividendMonthBucket> dividendMonthBuckets(
  DateTime start,
  List<DividendDisplayEvent> events,
) {
  final buckets = [
    for (var index = 0; index < 12; index += 1)
      DividendMonthBucket(DateTime(start.year, start.month + index, 1)),
  ];
  for (final event in events) {
    for (final bucket in buckets) {
      if (event.date.year == bucket.monthStart.year &&
          event.date.month == bucket.monthStart.month) {
        bucket.add(event);
        break;
      }
    }
  }
  return buckets;
}

String dividendEventDateForMode(Map<String, dynamic> event, String dateMode) {
  final payDate = text(event['payDate']);
  final exDate = text(event['exDate']);
  final date = text(event['date']);
  if (dateMode == 'pay') return payDate.isNotEmpty ? payDate : date;
  if (dateMode == 'ex') return exDate.isNotEmpty ? exDate : date;
  return payDate.isNotEmpty
      ? payDate
      : exDate.isNotEmpty
      ? exDate
      : date;
}

DateTime? parseDividendDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

String dividendStatusForEvent(Map<String, dynamic> event, DateTime date) {
  final raw = '${text(event['status'])} ${text(event['type'])}'.toLowerCase();
  if (raw.contains('paid')) return 'paid';
  if (raw.contains('declared')) return 'declared';
  if (raw.contains('estimated') || raw.contains('estimate')) return 'estimated';
  final today = DateTime.now();
  final normalizedToday = DateTime(today.year, today.month, today.day);
  return date.isBefore(normalizedToday) ? 'paid' : 'declared';
}

String dividendWindowTitle(DateTime start, AppLanguage language) => trFor(
  language,
  '${start.year} 年 ${start.month} 月',
  '${monthNamesShort[start.month - 1]} ${start.year}',
);

DateTime? nextDividendMonthAfter(
  DateTime monthStart,
  List<DividendDisplayEvent> events,
) {
  final current = DateTime(monthStart.year, monthStart.month, 1);
  final months =
      events
          .map((event) => DateTime(event.date.year, event.date.month, 1))
          .where((month) => month.isAfter(current))
          .toSet()
          .toList()
        ..sort();
  return months.isEmpty ? null : months.first;
}

String formatDividendMoney(
  double value,
  String currency, {
  bool compact = false,
}) {
  if (!value.isFinite || value == 0) return '${currencySymbol(currency)}0';
  final abs = value.abs();
  final sign = value < 0 ? '-' : '';
  final symbol = currencySymbol(currency);
  if (compact) {
    if (abs >= 1e6) return '$sign$symbol${(abs / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '$sign$symbol${(abs / 1e3).toStringAsFixed(1)}K';
  }
  if (abs >= 1e9) return '$sign$symbol${(abs / 1e9).toStringAsFixed(2)}B';
  if (abs >= 1e6) return '$sign$symbol${(abs / 1e6).toStringAsFixed(2)}M';
  return '$sign$symbol${abs.toStringAsFixed(abs >= 1000 ? 0 : 2)}';
}

String dividendDateLabel(Map<String, dynamic> event) {
  final exDate = text(event['exDate']);
  final payDate = text(event['payDate']);
  final date = text(event['date']);
  if (exDate.isNotEmpty && payDate.isNotEmpty) {
    return 'Ex $exDate · Pay $payDate';
  }
  if (payDate.isNotEmpty) return 'Pay $payDate';
  if (exDate.isNotEmpty) return 'Ex $exDate';
  return date.isNotEmpty ? date : 'date pending';
}

class PortfolioAccountCard extends StatelessWidget {
  const PortfolioAccountCard({
    super.key,
    required this.accounts,
    required this.palette,
    this.sampleMode = false,
  });

  final List<Map<String, dynamic>> accounts;
  final Palette palette;
  final bool sampleMode;

  @override
  Widget build(BuildContext context) {
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.account_balance_rounded,
            kicker: sampleMode ? 'SAMPLE STRUCTURE' : 'ACCOUNTS',
            title: sampleMode ? 'Illustrative account' : 'IBKR accounts',
            palette: palette,
          ),
          const SizedBox(height: 14),
          if (accounts.isEmpty)
            EmptyState(text: 'No linked accounts yet.', palette: palette)
          else
            for (final account in accounts)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.business_center_rounded,
                      color: palette.secondary,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sampleMode
                                ? context.tr(
                                    '示例账户结构',
                                    'Illustrative account structure',
                                  )
                                : text(account['name'], 'Brokerage account'),
                            style: TextStyle(
                              color: palette.text,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            sampleMode
                                ? context.tr('仅作界面展示', 'UI example only')
                                : '${text(account['provider'], 'IBKR')} · ${context.ui(text(account['accountType']))}',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      formatMoney(number(account['value'])),
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class PortfolioSectorCard extends StatelessWidget {
  const PortfolioSectorCard({
    super.key,
    required this.sectors,
    required this.palette,
  });

  final List<Map<String, dynamic>> sectors;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final maxValue = sectors
        .map((sector) => number(sector['value']))
        .fold<double>(0, math.max);
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.donut_large_rounded,
            kicker: 'ALLOCATION',
            title: context.tr('资产配置', 'Allocation'),
            palette: palette,
          ),
          const SizedBox(height: 14),
          for (final sector in sectors.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      context.ui(text(sector['sector'], 'Other')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: maxValue <= 0
                            ? 0
                            : math.max(.05, number(sector['value']) / maxValue),
                        minHeight: 8,
                        backgroundColor: palette.border,
                        color: palette.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 56,
                    child: Text(
                      formatReturn(
                        number(sector['weight']),
                      ).replaceFirst('+', ''),
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        color: palette.muted,
                        fontWeight: FontWeight.w800,
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
}

class PortfolioRiskCard extends StatelessWidget {
  const PortfolioRiskCard({
    super.key,
    required this.holdings,
    required this.palette,
  });

  final List<Map<String, dynamic>> holdings;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final top = holdings
        .take(5)
        .fold<double>(0, (sum, row) => sum + number(row['weight']));
    final cash = holdings
        .where((row) => text(row['ticker']) == 'CASH')
        .fold<double>(0, (sum, row) => sum + number(row['weight']));
    final pnl = holdings.fold<double>(
      0,
      (sum, row) => sum + number(row['unrealizedPnl']),
    );
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.shield_rounded,
            kicker: 'RISK',
            title: context.tr('组合体检', 'Portfolio Checkup'),
            palette: palette,
          ),
          const SizedBox(height: 14),
          MiniMetric(
            'Top 5 weight',
            formatReturn(top).replaceFirst('+', ''),
            Icons.filter_5_rounded,
            palette,
          ),
          const SizedBox(height: 10),
          MiniMetric(
            'Cash weight',
            formatReturn(cash).replaceFirst('+', ''),
            Icons.savings_rounded,
            palette,
          ),
          const SizedBox(height: 10),
          MiniMetric(
            'Unrealized P/L',
            formatMoney(pnl),
            Icons.trending_up_rounded,
            palette,
          ),
        ],
      ),
    );
  }
}

class PortfolioHoldingsTable extends StatelessWidget {
  const PortfolioHoldingsTable({
    super.key,
    required this.holdings,
    required this.palette,
  });

  final List<Map<String, dynamic>> holdings;
  final Palette palette;

  String _modelArchitecture(Map<String, dynamic> valuation) {
    final model = asMap(valuation['model']);
    return switch (text(model['route'])) {
      'operating_company' => 'Operating-company blend',
      'multi_method_growth' => 'Growth-stage blend',
      'financial_institution' || 'bank' => 'Financial institution',
      'customer_cash_earnings' => 'Customer cash earnings',
      'revenue_stage' => 'Revenue-stage model',
      'bitcoin_treasury' => 'Treasury + operating value',
      _ =>
        truthy(valuation['covered']) ? 'Published model' : 'No published model',
    };
  }

  String _pointDifference(dynamic value) {
    final parsed = nullableNumber(value);
    if (parsed == null) return '—';
    final points = parsed * 100;
    return '${points >= 0 ? '+' : ''}${points.toStringAsFixed(1)} pp';
  }

  List<Map<String, dynamic>> _modelRows() {
    final source = holdings
        .where(
          (row) =>
              number(row['value']) > 0 &&
              !text(row['ticker']).toUpperCase().startsWith('CASH'),
        )
        .toList();
    double revaluedValue(Map<String, dynamic> row) {
      final valuation = asMap(row['valuation']);
      final price = nullableNumber(valuation['latestPrice']);
      final fairValue = nullableNumber(valuation['fairValue']);
      if (!truthy(valuation['covered']) ||
          price == null ||
          price <= 0 ||
          fairValue == null ||
          fairValue <= 0) {
        return 0;
      }
      return number(row['value']) * fairValue / price;
    }

    final coveredCurrent = source
        .where((row) => revaluedValue(row) > 0)
        .fold<double>(0, (sum, row) => sum + number(row['value']));
    final coveredModel = source.fold<double>(
      0,
      (sum, row) => sum + revaluedValue(row),
    );
    return [
      for (final row in source)
        {
          ...row,
          '_modelValue': revaluedValue(row),
          '_currentCoveredWeight': coveredCurrent > 0 && revaluedValue(row) > 0
              ? number(row['value']) / coveredCurrent
              : null,
          '_modelCoveredWeight': coveredModel > 0 && revaluedValue(row) > 0
              ? revaluedValue(row) / coveredModel
              : null,
          '_structureGap':
              coveredCurrent > 0 && coveredModel > 0 && revaluedValue(row) > 0
              ? revaluedValue(row) / coveredModel -
                    number(row['value']) / coveredCurrent
              : null,
        },
    ]..sort(
      (left, right) => number(right['value']).compareTo(number(left['value'])),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _modelRows();
    final covered = rows.where(
      (row) =>
          nullableNumber(row['_modelValue']) != null &&
          number(row['_modelValue']) > 0,
    );
    final coveredCurrent = covered.fold<double>(
      0,
      (sum, row) => sum + number(row['value']),
    );
    final coveredModel = covered.fold<double>(
      0,
      (sum, row) => sum + number(row['_modelValue']),
    );
    final coveredGap = coveredCurrent > 0
        ? coveredModel / coveredCurrent - 1
        : null;
    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.table_rows_rounded,
            kicker: 'HOLDINGS',
            title: context.tr('持仓与模型结构', 'Holdings & Model Structure'),
            palette: palette,
            trailing: InfoChip(
              context.tr(
                '${covered.length} / ${rows.length} 项已建模',
                '${covered.length} / ${rows.length} modelled',
              ),
              palette: palette,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              '当前仓位、每家公司使用的估值架构，以及按模型公允价值重估后已覆盖组合的结构变化。',
              'Current positions, each company’s valuation architecture, and how the covered sleeve changes when revalued to published model output.',
            ),
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: .055),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: palette.accent.withValues(alpha: .16)),
            ),
            child: Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                Text(
                  context.tr(
                    '已覆盖市值 ${formatMoney(coveredCurrent)}',
                    'Covered market value ${formatMoney(coveredCurrent)}',
                  ),
                  style: TextStyle(color: palette.text, fontSize: 12),
                ),
                Text(
                  context.tr(
                    '模型重估 ${formatMoney(coveredModel)}',
                    'Model-revalued ${formatMoney(coveredModel)}',
                  ),
                  style: TextStyle(color: palette.text, fontSize: 12),
                ),
                Text(
                  context.tr(
                    '覆盖部分价差 ${coveredGap == null ? '—' : formatReturn(coveredGap)}',
                    'Covered gap ${coveredGap == null ? '—' : formatReturn(coveredGap)}',
                  ),
                  style: TextStyle(
                    color: coveredGap == null
                        ? palette.muted
                        : coveredGap >= 0
                        ? palette.positive
                        : palette.negative,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            EmptyState(text: 'No holdings from Yodlee yet.', palette: palette)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 980 ||
                    MediaQuery.textScalerOf(context).scale(1) > 1.25) {
                  return Column(
                    children: [
                      for (final row in rows.take(30))
                        PortfolioHoldingRow(row: row, palette: palette),
                    ],
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    showCheckboxColumn: false,
                    headingRowHeight: 46,
                    dataRowMinHeight: 68,
                    dataRowMaxHeight: 76,
                    horizontalMargin: 10,
                    columnSpacing: 24,
                    columns: [
                      DataColumn(label: Text(context.tr('持仓', 'Holding'))),
                      DataColumn(
                        label: Text(context.tr('股数', 'Shares')),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(context.tr('当前市值', 'Current value')),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(context.tr('权重', 'Weight')),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(context.tr('模型架构', 'Model architecture')),
                      ),
                      DataColumn(
                        label: Text(context.tr('模型输出', 'Model output')),
                        numeric: true,
                      ),
                      DataColumn(
                        label: SizedBox(
                          width: 124,
                          child: Text(
                            context.tr('当前 → 模型', 'Current → model'),
                            textAlign: TextAlign.end,
                          ),
                        ),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text(context.tr('未实现盈亏', 'Unrealized P&L')),
                        numeric: true,
                      ),
                    ],
                    rows: [
                      for (final row in rows.take(30)) _dataRow(context, row),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 10),
          Text(
            context.tr(
              '“当前 → 模型”只比较已覆盖部分按已发布公允价值重估后的权重变化；不是目标仓位、评分或预期收益。缺失模型不会按零处理。',
              'Current → model compares weights inside the covered sleeve after applying published fair values. It is not a target allocation, rating or expected return. Missing models remain missing, not zero.',
            ),
            style: TextStyle(color: palette.muted, fontSize: 11, height: 1.45),
          ),
        ],
      ),
    );
  }

  DataRow _dataRow(BuildContext context, Map<String, dynamic> row) {
    final valuation = asMap(row['valuation']);
    final model = asMap(valuation['model']);
    final covered = truthy(valuation['covered']);
    final structureGap = nullableNumber(row['_structureGap']);
    final pnl = number(row['unrealizedPnl']);
    final pnlTone = pnl >= 0 ? palette.positive : palette.negative;
    final formula = text(model['formula'], _modelArchitecture(valuation));
    return DataRow(
      cells: [
        DataCell(
          SizedBox(
            width: 210,
            child: Row(
              children: [
                PortfolioHoldingLogo(row: row, palette: palette, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text(row['ticker'], 'N/A'),
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        context.ui(compactName(text(row['name']))),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        DataCell(
          Text(
            nullableNumber(row['quantity']) == null
                ? '—'
                : formatNumber(number(row['quantity'])),
          ),
        ),
        DataCell(
          _stackedValue(
            formatMoney(number(row['value'])),
            formatCurrencyValue(
              number(row['price']),
              text(row['currency'], 'USD'),
            ),
          ),
        ),
        DataCell(
          Text(
            formatReturn(number(row['weight'])).replaceFirst('+', ''),
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w800),
          ),
        ),
        DataCell(
          Tooltip(
            message: formula,
            child: SizedBox(
              width: 180,
              child: _stackedValue(
                _modelArchitecture(valuation),
                covered
                    ? text(
                        model['asOfDate'],
                        text(valuation['latestPriceDate'], '—'),
                      )
                    : context.tr('没有已发布模型', 'No published model'),
              ),
            ),
          ),
        ),
        DataCell(
          _stackedValue(
            covered && nullableNumber(valuation['fairValue']) != null
                ? formatCurrencyValue(
                    number(valuation['fairValue']),
                    text(valuation['currency'], 'USD'),
                  )
                : '—',
            covered && nullableNumber(valuation['gap']) != null
                ? formatReturn(number(valuation['gap']))
                : context.tr('未覆盖', 'Uncovered'),
            color: !covered || nullableNumber(valuation['gap']) == null
                ? null
                : number(valuation['gap']) >= 0
                ? palette.positive
                : palette.negative,
            alignEnd: true,
          ),
        ),
        DataCell(
          SizedBox(
            width: 124,
            child: _stackedValue(
              covered
                  ? '${formatReturn(number(row['_currentCoveredWeight'])).replaceFirst('+', '')} → ${formatReturn(number(row['_modelCoveredWeight'])).replaceFirst('+', '')}'
                  : '—',
              _pointDifference(structureGap),
              color: structureGap == null
                  ? null
                  : structureGap >= 0
                  ? palette.positive
                  : palette.negative,
              alignEnd: true,
            ),
          ),
        ),
        DataCell(
          Text(
            formatMoney(pnl),
            style: TextStyle(color: pnlTone, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  Widget _stackedValue(
    String primary,
    String secondary, {
    Color? color,
    bool alignEnd = false,
  }) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        primary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color ?? palette.text,
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        secondary,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color ?? palette.muted, fontSize: 11),
      ),
    ],
  );
}

class PortfolioHoldingRow extends StatelessWidget {
  const PortfolioHoldingRow({
    super.key,
    required this.row,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final pnl = number(row['unrealizedPnl']);
    final tone = pnl >= 0 ? palette.positive : palette.negative;
    final valuation = asMap(row['valuation']);
    final analytics = asMap(row['analytics']);
    final gap = nullableNumber(valuation['gap']);
    final gapText = gap == null ? '-' : formatReturn(gap);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        if (compact) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: .52),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PortfolioHoldingLogo(row: row, palette: palette, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            text(row['ticker'], 'N/A'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            context.ui(compactName(text(row['name']))),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PortfolioValuationChip(
                      valuation: valuation,
                      palette: palette,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _HoldingMiniLine(
                        label: 'Weight',
                        value: formatReturn(
                          number(row['weight']),
                        ).replaceFirst('+', ''),
                        palette: palette,
                      ),
                    ),
                    Expanded(
                      child: _HoldingMiniLine(
                        label: 'FV gap',
                        value: gapText,
                        palette: palette,
                      ),
                    ),
                    Expanded(
                      child: _HoldingMiniLine(
                        label: '1Y',
                        value: formatNullableReturn(
                          analytics['trailingReturn'],
                        ),
                        palette: palette,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatMoney(number(row['value'])),
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      formatMoney(pnl),
                      style: TextStyle(
                        color: tone,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              SizedBox(
                width: 132,
                child: Row(
                  children: [
                    PortfolioHoldingLogo(row: row, palette: palette, size: 26),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text(row['ticker'], 'N/A'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  context.ui(compactName(text(row['name']))),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 88,
                child: PortfolioValuationChip(
                  valuation: valuation,
                  palette: palette,
                ),
              ),
              SizedBox(
                width: 78,
                child: Text(
                  gapText,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: portfolioValuationTone(valuation, palette),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(
                width: 82,
                child: Text(
                  formatReturn(number(row['weight'])).replaceFirst('+', ''),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              SizedBox(
                width: 100,
                child: Text(
                  formatMoney(number(row['value'])),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(
                width: 100,
                child: Text(
                  formatMoney(pnl),
                  textAlign: TextAlign.end,
                  style: TextStyle(color: tone, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HoldingMiniLine extends StatelessWidget {
  const _HoldingMiniLine({
    required this.label,
    required this.value,
    required this.palette,
  });

  final String label;
  final String value;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.ui(label),
          style: TextStyle(
            color: palette.faint,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.text, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class ValuationCompactDashboard extends StatefulWidget {
  const ValuationCompactDashboard({
    super.key,
    required this.data,
    required this.api,
    required this.palette,
    required this.initialTicker,
    required this.onTickerChanged,
  });

  final Map<String, dynamic> data;
  final ApiClient api;
  final Palette palette;
  final String initialTicker;
  final ValueChanged<String> onTickerChanged;

  @override
  State<ValuationCompactDashboard> createState() =>
      _ValuationCompactDashboardState();
}

class _ValuationCompactDashboardState extends State<ValuationCompactDashboard> {
  String _selectedTicker = '';
  String _tickerSearch = '';
  String _valuationFilter = 'all';
  final String _valuationSort = 'upside';
  String _qualityFilter = 'all';
  String _expandedIndustryKey = '';
  bool _showFullResearch = false;
  final TextEditingController _tickerSearchController = TextEditingController();
  final Map<String, Map<String, dynamic>> _summaryDetailCache = {};
  final Map<String, Map<String, dynamic>> _fullDetailCache = {};
  Map<String, dynamic>? _localDashboard;
  Map<String, dynamic>? _detailPayload;
  bool _detailLoading = false;
  bool _importingTicker = false;
  String? _detailError;
  int _detailRequestSerial = 0;

  @override
  void initState() {
    super.initState();
    _selectedTicker = _defaultTicker(
      widget.data,
      preferred: widget.initialTicker,
    );
    if (_selectedTicker.isNotEmpty) {
      scheduleMicrotask(() => _loadTicker(_selectedTicker));
    }
  }

  @override
  void dispose() {
    _tickerSearchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ValuationCompactDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data == widget.data) return;
    _localDashboard = null;
    final rows = valuationRowsFromTickers(
      asList(widget.data['tickers']).isNotEmpty
          ? asList(widget.data['tickers'])
          : asList(widget.data['stocks']),
    );
    final visibleRows = _visibleRowsFor(
      rows: rows,
      tickerSearch: _tickerSearch,
      valuationFilter: _valuationFilter,
      qualityFilter: _qualityFilter,
    );
    final preferredTicker = rows.any((row) => row.ticker == _selectedTicker)
        ? _selectedTicker
        : _defaultTicker(widget.data, preferred: widget.initialTicker);
    final nextTicker = reconciledValuationTicker(visibleRows, preferredTicker);
    _summaryDetailCache.clear();
    _fullDetailCache.clear();
    setState(() {
      _selectedTicker = nextTicker;
      _detailPayload = null;
      _detailError = null;
      _detailLoading = false;
    });
    if (nextTicker.isNotEmpty) _loadTicker(nextTicker);
  }

  Map<String, dynamic> get _dashboardData => _localDashboard ?? widget.data;

  String _normalizeTickerInput(String value) =>
      value.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9.-]'), '');

  bool _matchesValuationFilter(ValuationRow row, String filter) {
    switch (filter) {
      case 'deep':
        return valuationBucketForRow(row) == 'undervalued';
      case 'fair':
        return valuationBucketForRow(row) == 'fair';
      case 'expensive':
        return valuationBucketForRow(row) == 'expensive';
      case 'audit':
        return row.lineageStatus == 'pass';
      case 'watch':
        return ['review', 'fail'].contains(row.lineageStatus);
      case 'missing':
        return !row.hasModel;
      default:
        return true;
    }
  }

  List<ValuationRow> _sortValuationRows(List<ValuationRow> rows) {
    final sorted = [...rows];
    int byTicker(ValuationRow a, ValuationRow b) =>
        a.ticker.compareTo(b.ticker);
    sorted.sort((a, b) {
      switch (_valuationSort) {
        case 'expensive':
          return a.upside.compareTo(b.upside);
        case 'ticker':
          return byTicker(a, b);
        case 'quality':
          final quality = (b.lineageStatus == 'pass' ? 1 : 0).compareTo(
            a.lineageStatus == 'pass' ? 1 : 0,
          );
          return quality == 0 ? b.upside.compareTo(a.upside) : quality;
        default:
          return b.upside.compareTo(a.upside);
      }
    });
    return sorted;
  }

  List<ValuationRow> _visibleRowsFor({
    required List<ValuationRow> rows,
    required String tickerSearch,
    required String valuationFilter,
    required String qualityFilter,
  }) {
    final tickerQuery = tickerSearch.trim().toUpperCase();
    final searchedRows = tickerQuery.isEmpty
        ? rows
        : rows.where((row) {
            final haystack = '${row.ticker} ${row.name} ${row.sector}'
                .toUpperCase();
            return haystack.contains(tickerQuery);
          }).toList();
    return _sortValuationRows(
      searchedRows
          .where((row) => _matchesValuationFilter(row, valuationFilter))
          .where((row) {
            switch (qualityFilter) {
              case 'pass':
                return row.lineageStatus == 'pass';
              case 'watch':
                return ['review', 'fail'].contains(row.lineageStatus);
              case 'missing':
                return !row.hasModel;
              default:
                return true;
            }
          })
          .toList(),
    );
  }

  void _updateVisibleControls({
    String? tickerSearch,
    String? valuationFilter,
    String? qualityFilter,
  }) {
    final nextSearch = tickerSearch ?? _tickerSearch;
    final nextValuationFilter = valuationFilter ?? _valuationFilter;
    final nextQualityFilter = qualityFilter ?? _qualityFilter;
    final data = _dashboardData;
    final rows = valuationRowsFromTickers(
      asList(data['tickers']).isNotEmpty
          ? asList(data['tickers'])
          : asList(data['stocks']),
    );
    final visibleRows = _visibleRowsFor(
      rows: rows,
      tickerSearch: nextSearch,
      valuationFilter: nextValuationFilter,
      qualityFilter: nextQualityFilter,
    );
    final nextTicker = reconciledValuationTicker(visibleRows, _selectedTicker);
    final selectionChanged = nextTicker != _selectedTicker;
    final nextRow = visibleRows
        .where((row) => row.ticker == nextTicker)
        .firstOrNull;

    setState(() {
      _tickerSearch = nextSearch;
      _valuationFilter = nextValuationFilter;
      _qualityFilter = nextQualityFilter;
      if (!selectionChanged) return;
      _detailRequestSerial += 1;
      _selectedTicker = nextTicker;
      _expandedIndustryKey = nextRow == null
          ? ''
          : valuationIndustryForRow(nextRow).key;
      _showFullResearch = false;
      _detailPayload = null;
      _detailError = null;
      _detailLoading = false;
    });

    if (!selectionChanged) return;
    if (nextTicker.isEmpty) {
      widget.onTickerChanged('');
    } else {
      unawaited(_loadTicker(nextTicker));
    }
  }

  String _defaultTicker(Map<String, dynamic> data, {String preferred = ''}) {
    return defaultValuationTicker(data, preferred: preferred);
  }

  Future<void> _loadTicker(
    String ticker, {
    bool refresh = false,
    bool fullResearch = false,
  }) async {
    if (ticker.isEmpty) return;
    final normalizedTicker = ticker.toUpperCase();
    final cache = fullResearch ? _fullDetailCache : _summaryDetailCache;
    final cachedPayload = refresh ? null : cache[normalizedTicker];
    final tickerChanged = _selectedTicker != normalizedTicker;
    final requestId = ++_detailRequestSerial;
    setState(() {
      if (tickerChanged) _showFullResearch = false;
      _selectedTicker = normalizedTicker;
      _detailPayload =
          cachedPayload ??
          (fullResearch && !tickerChanged ? _detailPayload : null);
      _detailError = null;
      _detailLoading = cachedPayload == null;
    });
    widget.onTickerChanged(normalizedTicker);
    if (cachedPayload != null) return;
    try {
      final payload = await StockResearchCache.of(
        widget.api,
      ).load(normalizedTicker, full: fullResearch, refresh: refresh);
      if (!mounted ||
          requestId != _detailRequestSerial ||
          normalizedTicker != _selectedTicker) {
        return;
      }
      cache[normalizedTicker] = payload;
      setState(() => _detailPayload = payload);
    } catch (error) {
      if (!mounted ||
          requestId != _detailRequestSerial ||
          normalizedTicker != _selectedTicker) {
        return;
      }
      setState(() => _detailError = error.toString());
    } finally {
      if (mounted &&
          requestId == _detailRequestSerial &&
          normalizedTicker == _selectedTicker) {
        setState(() => _detailLoading = false);
      }
    }
  }

  void _selectTicker(ValuationRow row) {
    setState(() {
      _expandedIndustryKey = valuationIndustryForRow(row).key;
      _showFullResearch = false;
    });
    _loadTicker(row.ticker);
  }

  Future<void> _toggleFullResearch() async {
    if (_showFullResearch) {
      setState(() => _showFullResearch = false);
      return;
    }
    setState(() => _showFullResearch = true);
    await _loadTicker(_selectedTicker, fullResearch: true);
  }

  Future<void> _importTicker(String ticker) async {
    final normalizedTicker = _normalizeTickerInput(ticker);
    if (normalizedTicker.isEmpty || _importingTicker) return;
    final requestId = ++_detailRequestSerial;
    setState(() {
      _selectedTicker = normalizedTicker;
      _detailPayload = null;
      _detailError = null;
      _detailLoading = true;
      _importingTicker = true;
    });
    widget.onTickerChanged(normalizedTicker);
    try {
      final encodedTicker = Uri.encodeComponent(normalizedTicker);
      final payload = await widget.api.postJson(
        '/api/valuation/$encodedTicker/import?pricePoints=900',
        {'pricePoints': 900},
      );
      final dashboard = await widget.api.getJson('/api/valuation');
      if (!mounted || requestId != _detailRequestSerial) return;
      final importedTicker = text(
        asMap(payload['ticker'])['ticker'],
        normalizedTicker,
      ).toUpperCase();
      _summaryDetailCache
        ..clear()
        ..[importedTicker] = payload;
      _fullDetailCache
        ..clear()
        ..[importedTicker] = payload;
      setState(() {
        _localDashboard = dashboard;
        _selectedTicker = importedTicker;
        _detailPayload = payload;
        _tickerSearch = importedTicker;
        _tickerSearchController.text = importedTicker;
      });
      widget.onTickerChanged(importedTicker);
    } catch (error) {
      if (!mounted || requestId != _detailRequestSerial) return;
      setState(() => _detailError = error.toString());
    } finally {
      if (mounted && requestId == _detailRequestSerial) {
        setState(() {
          _detailLoading = false;
          _importingTicker = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _dashboardData;
    final tickers = asList(data['tickers']).isNotEmpty
        ? asList(data['tickers'])
        : asList(data['stocks']);
    final rows = valuationRowsFromTickers(tickers);
    final normalizedTickerQuery = _normalizeTickerInput(_tickerSearch);
    final filteredRows = _visibleRowsFor(
      rows: rows,
      tickerSearch: _tickerSearch,
      valuationFilter: _valuationFilter,
      qualityFilter: _qualityFilter,
    );
    final selectedRow = filteredRows.firstWhere(
      (row) => row.ticker == _selectedTicker,
      orElse: () =>
          filteredRows.isNotEmpty ? filteredRows.first : ValuationRow.empty(),
    );
    final detailMatchesSelection =
        selectedRow.ticker.isNotEmpty && selectedRow.ticker == _selectedTicker;
    final selectedIndustry = valuationIndustryForRow(selectedRow);
    final effectiveIndustryKey = _expandedIndustryKey.isEmpty
        ? selectedIndustry.key
        : _expandedIndustryKey;

    return ValuationIndustryDashboardView(
      api: widget.api,
      palette: widget.palette,
      rows: rows,
      visibleRows: filteredRows,
      selectedRow: selectedRow,
      summary: asMap(data['summary']),
      source: asMap(data['source']),
      tickerSearchController: _tickerSearchController,
      tickerSearch: _tickerSearch,
      valuationFilter: _valuationFilter,
      qualityFilter: _qualityFilter,
      expandedIndustryKey: effectiveIndustryKey,
      detailPayload: detailMatchesSelection ? _detailPayload : null,
      detailLoading: detailMatchesSelection && _detailLoading,
      detailError: detailMatchesSelection ? _detailError : null,
      importingTicker: _importingTicker,
      showFullResearch: _showFullResearch,
      onSearchChanged: (value) => _updateVisibleControls(tickerSearch: value),
      onSearchSubmitted: () {
        if (filteredRows.isNotEmpty) {
          _selectTicker(filteredRows.first);
        } else if (normalizedTickerQuery.isNotEmpty) {
          _importTicker(normalizedTickerQuery);
        }
      },
      onClearSearch: () {
        _tickerSearchController.clear();
        _updateVisibleControls(tickerSearch: '');
      },
      onImportTicker: normalizedTickerQuery.isEmpty
          ? null
          : () => _importTicker(normalizedTickerQuery),
      onValuationFilterChanged: (value) =>
          _updateVisibleControls(valuationFilter: value),
      onQualityFilterChanged: (value) =>
          _updateVisibleControls(qualityFilter: value),
      onIndustryChanged: (value) {
        setState(() => _expandedIndustryKey = value);
      },
      onTickerSelected: _selectTicker,
      onRefresh: () {
        if (selectedRow.ticker.isNotEmpty) {
          unawaited(
            _loadTicker(
              selectedRow.ticker,
              refresh: true,
              fullResearch: _showFullResearch,
            ),
          );
        }
      },
      onToggleFullResearch: () {
        if (selectedRow.ticker.isNotEmpty) {
          if (selectedRow.ticker != _selectedTicker) {
            unawaited(_loadTicker(selectedRow.ticker));
          } else {
            unawaited(_toggleFullResearch());
          }
        }
      },
    );
  }
}

class ValuationIndustryDefinition {
  const ValuationIndustryDefinition({
    required this.key,
    required this.zh,
    required this.en,
    required this.icon,
  });

  final String key;
  final String zh;
  final String en;
  final IconData icon;
}

const valuationIndustryDefinitions = <ValuationIndustryDefinition>[
  ValuationIndustryDefinition(
    key: 'software_cloud',
    zh: '软件与云服务',
    en: 'Software & Cloud',
    icon: Icons.cloud_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'semiconductors_hardware',
    zh: '半导体与硬件',
    en: 'Semiconductors & Hardware',
    icon: Icons.memory_rounded,
  ),
  ValuationIndustryDefinition(
    key: 'internet_media',
    zh: '互联网与媒体',
    en: 'Internet & Media',
    icon: Icons.language_rounded,
  ),
  ValuationIndustryDefinition(
    key: 'healthcare',
    zh: '医疗健康',
    en: 'Healthcare',
    icon: Icons.health_and_safety_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'financials',
    zh: '金融与支付',
    en: 'Financials & Payments',
    icon: Icons.account_balance_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'consumer',
    zh: '消费',
    en: 'Consumer',
    icon: Icons.shopping_bag_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'industrials',
    zh: '工业与国防',
    en: 'Industrials & Defense',
    icon: Icons.precision_manufacturing_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'energy_utilities',
    zh: '能源与公用事业',
    en: 'Energy & Utilities',
    icon: Icons.bolt_outlined,
  ),
  ValuationIndustryDefinition(
    key: 'other',
    zh: '其他',
    en: 'Other',
    icon: Icons.category_outlined,
  ),
];

ValuationIndustryDefinition valuationIndustryForRow(ValuationRow row) {
  final sector = row.sector.toLowerCase();
  bool hasAny(Iterable<String> needles) =>
      needles.any((needle) => sector.contains(needle));

  String key;
  if (row.ticker == 'RKLX') {
    key = 'industrials';
  } else if (hasAny([
    'semiconductor',
    'foundry',
    'optical',
    'networking',
    'storage',
  ])) {
    key = 'semiconductors_hardware';
  } else if (hasAny(['software', 'information services'])) {
    key = 'software_cloud';
  } else if (hasAny([
    'platform',
    'search',
    'media',
    'telecom',
    'streaming',
    'entertainment',
  ])) {
    key = 'internet_media';
  } else if (hasAny([
    'healthcare',
    'biotech',
    'biopharma',
    'medtech',
    'diagnostic',
    'managed care',
  ])) {
    key = 'healthcare';
  } else if (hasAny(['bank', 'insurance', 'payment', 'lender'])) {
    key = 'financials';
  } else if (hasAny(['consumer', 'retail', 'beverage', 'staple'])) {
    key = 'consumer';
  } else if (hasAny(['industrial', 'defense', 'aerospace', 'space'])) {
    key = 'industrials';
  } else if (hasAny(['energy', 'utility', 'power', 'natural gas'])) {
    key = 'energy_utilities';
  } else {
    key = 'other';
  }
  return valuationIndustryDefinitions.firstWhere(
    (definition) => definition.key == key,
  );
}

String localizedValuationSector(
  BuildContext context,
  ValuationRow row, [
  String? rawValue,
]) {
  final raw = (rawValue ?? row.sector).trim();
  final definition = valuationIndustryForRow(row);
  final hasChinese = RegExp(r'[\u3400-\u9fff]').hasMatch(raw);
  if (context.isEnglish) return hasChinese || raw.isEmpty ? definition.en : raw;
  return hasChinese ? raw : definition.zh;
}

class ValuationIndustryGroupData {
  ValuationIndustryGroupData({required this.definition, required this.rows});

  final ValuationIndustryDefinition definition;
  final List<ValuationRow> rows;

  double get medianUpside => medianDouble(
    rows.where((row) => row.hasModel).map((row) => row.upside).toList(),
  );

  int get undervaluedCount =>
      rows.where((row) => valuationBucketForRow(row) == 'undervalued').length;

  int get fairCount =>
      rows.where((row) => valuationBucketForRow(row) == 'fair').length;

  int get expensiveCount =>
      rows.where((row) => valuationBucketForRow(row) == 'expensive').length;

  int get missingCount => rows.where((row) => !row.hasModel).length;
}

String valuationBucketForRow(ValuationRow row) {
  if (!row.hasModel) return 'missing';
  if (row.upside >= .05) return 'undervalued';
  if (row.upside <= -.05) return 'expensive';
  return 'fair';
}

String reconciledValuationTicker(
  List<ValuationRow> visibleRows,
  String selectedTicker,
) {
  if (visibleRows.any((row) => row.ticker == selectedTicker)) {
    return selectedTicker;
  }
  return visibleRows.firstOrNull?.ticker ?? '';
}

List<ValuationIndustryGroupData> valuationIndustryGroups(
  List<ValuationRow> rows,
) {
  final byKey = <String, List<ValuationRow>>{};
  for (final row in rows) {
    final key = valuationIndustryForRow(row).key;
    byKey.putIfAbsent(key, () => []).add(row);
  }
  return [
    for (final definition in valuationIndustryDefinitions)
      if ((byKey[definition.key] ?? const <ValuationRow>[]).isNotEmpty)
        ValuationIndustryGroupData(
          definition: definition,
          rows: [...byKey[definition.key]!]
            ..sort((a, b) => b.upside.compareTo(a.upside)),
        ),
  ];
}

class ValuationIndustryDashboardView extends StatelessWidget {
  const ValuationIndustryDashboardView({
    super.key,
    required this.api,
    required this.palette,
    required this.rows,
    required this.visibleRows,
    required this.selectedRow,
    required this.summary,
    required this.source,
    required this.tickerSearchController,
    required this.tickerSearch,
    required this.valuationFilter,
    required this.qualityFilter,
    required this.expandedIndustryKey,
    required this.detailPayload,
    required this.detailLoading,
    required this.detailError,
    required this.importingTicker,
    required this.showFullResearch,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onClearSearch,
    required this.onImportTicker,
    required this.onValuationFilterChanged,
    required this.onQualityFilterChanged,
    required this.onIndustryChanged,
    required this.onTickerSelected,
    required this.onRefresh,
    required this.onToggleFullResearch,
  });

  final ApiClient api;
  final Palette palette;
  final List<ValuationRow> rows;
  final List<ValuationRow> visibleRows;
  final ValuationRow selectedRow;
  final Map<String, dynamic> summary;
  final Map<String, dynamic> source;
  final TextEditingController tickerSearchController;
  final String tickerSearch;
  final String valuationFilter;
  final String qualityFilter;
  final String expandedIndustryKey;
  final Map<String, dynamic>? detailPayload;
  final bool detailLoading;
  final String? detailError;
  final bool importingTicker;
  final bool showFullResearch;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchSubmitted;
  final VoidCallback onClearSearch;
  final VoidCallback? onImportTicker;
  final ValueChanged<String> onValuationFilterChanged;
  final ValueChanged<String> onQualityFilterChanged;
  final ValueChanged<String> onIndustryChanged;
  final ValueChanged<ValuationRow> onTickerSelected;
  final VoidCallback onRefresh;
  final VoidCallback onToggleFullResearch;

  @override
  Widget build(BuildContext context) {
    final latestPriceDate = text(
      summary['latestPriceDate'],
      rows.isEmpty ? '' : rows.first.latestPriceDate,
    );
    final auditCounts = asMap(summary['auditLayerCounts']);
    final lineageCounts = asMap(auditCounts['lineage']);
    final economicCounts = asMap(auditCounts['economicValidation']);
    final marketCounts = asMap(auditCounts['marketCalibration']);
    int passed(Map<String, dynamic> counts) => number(counts['pass']).round();
    int reviewed(Map<String, dynamic> counts) =>
        number(counts['review']).round();
    final marketGuardrailOnly = number(marketCounts['guardrailOnly']).round();
    final marketReview = reviewed(marketCounts);
    final normalizedSearch = tickerSearch.trim().toUpperCase();
    final hasExactMatch = rows.any((row) => row.ticker == normalizedSearch);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          palette: palette,
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 900;
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.grid_view_rounded,
                        color: palette.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        context.tr('估值市场地图', 'Valuation Market Map'),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    context.tr(
                      '${rows.length} 个标的 · 股价 ${latestPriceDate.isEmpty ? '日期未提供' : formatDate(latestPriceDate)} · 各验证层独立报告',
                      '${rows.length} stocks · prices ${latestPriceDate.isEmpty ? 'date unavailable' : formatDate(latestPriceDate)} · validation layers reported separately',
                    ),
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ValuationLayerBadge(
                        label: context.tr('血缘/算术', 'Lineage/arithmetic'),
                        value: '${passed(lineageCounts)}/${rows.length}',
                        status:
                            passed(lineageCounts) == rows.length &&
                                rows.isNotEmpty
                            ? 'pass'
                            : 'review',
                        palette: palette,
                      ),
                      ValuationLayerBadge(
                        label: context.tr('模型验证', 'Model validation'),
                        value: '${passed(economicCounts)}/${rows.length}',
                        status: passed(economicCounts) > 0
                            ? 'pass'
                            : 'not_validated',
                        palette: palette,
                      ),
                      ValuationLayerBadge(
                        label: context.tr('市场校准', 'Market calibration'),
                        value: marketGuardrailOnly > 0
                            ? context.tr(
                                '$marketGuardrailOnly 个仅限 guardrail',
                                '$marketGuardrailOnly guardrail only',
                              )
                            : marketReview > 0
                            ? context.tr(
                                '$marketReview 个待复核',
                                '$marketReview review',
                              )
                            : '${passed(marketCounts)}/${rows.length}',
                        status: marketGuardrailOnly > 0
                            ? 'guardrail_only'
                            : marketReview > 0
                            ? 'review'
                            : passed(marketCounts) > 0
                            ? 'pass'
                            : 'not_run',
                        palette: palette,
                      ),
                    ],
                  ),
                ],
              );
              final controls = Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: compact ? constraints.maxWidth : 340,
                    child: TextField(
                      controller: tickerSearchController,
                      cursorColor: palette.accent,
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w800,
                      ),
                      onChanged: onSearchChanged,
                      onSubmitted: (_) => onSearchSubmitted(),
                      decoration: InputDecoration(
                        hintText: context.tr(
                          '搜索代码、公司或行业',
                          'Search ticker, company, or industry',
                        ),
                        hintStyle: TextStyle(color: palette.faint),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          color: palette.muted,
                        ),
                        suffixIcon: tickerSearch.isEmpty
                            ? null
                            : IconButton(
                                tooltip: context.tr('清除', 'Clear'),
                                onPressed: onClearSearch,
                                icon: Icon(
                                  Icons.close_rounded,
                                  color: palette.muted,
                                ),
                              ),
                        filled: true,
                        fillColor: palette.card,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 13,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: palette.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: palette.accent),
                        ),
                      ),
                    ),
                  ),
                  _ValuationToolbarMenu(
                    value: valuationFilter,
                    icon: Icons.balance_rounded,
                    label: context.tr('估值状态', 'Valuation'),
                    options: {
                      'all': context.tr('全部估值', 'All valuations'),
                      'deep': context.tr('低估', 'Undervalued'),
                      'fair': context.tr('合理', 'Fair range'),
                      'expensive': context.tr('偏贵', 'Expensive'),
                    },
                    palette: palette,
                    onChanged: onValuationFilterChanged,
                  ),
                  _ValuationToolbarMenu(
                    value: qualityFilter,
                    icon: Icons.verified_outlined,
                    label: context.tr('数据质量', 'Data quality'),
                    options: {
                      'all': context.tr('全部质量', 'All quality'),
                      'pass': context.tr('血缘/算术已检查', 'Lineage checked'),
                      'watch': context.tr('血缘需复核', 'Lineage review'),
                      'missing': context.tr('缺少估值', 'Missing FV'),
                    },
                    palette: palette,
                    onChanged: onQualityFilterChanged,
                  ),
                  IconButton.filledTonal(
                    tooltip: context.tr('刷新当前标的', 'Refresh selected ticker'),
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: 14), controls],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 18),
                  controls,
                ],
              );
            },
          ),
        ),
        if (normalizedSearch.isNotEmpty && !hasExactMatch) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    visibleRows.isEmpty
                        ? context.tr(
                            '$normalizedSearch 不在估值库中，可以抓取并建立 PIT 模型。',
                            '$normalizedSearch is not in the library. Fetch it and build a PIT model.',
                          )
                        : context.tr(
                            '显示 ${visibleRows.length} 个匹配结果。',
                            '${visibleRows.length} matching results.',
                          ),
                    style: TextStyle(color: palette.muted),
                  ),
                ),
                if (visibleRows.isEmpty && onImportTicker != null)
                  FilledButton.icon(
                    onPressed: importingTicker ? null : onImportTicker,
                    icon: importingTicker
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    label: Text(context.tr('添加并抓取', 'Add & fetch')),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        ValuationIndustryMap(
          rows: visibleRows,
          selectedTicker: selectedRow.ticker,
          expandedIndustryKey: expandedIndustryKey,
          palette: palette,
          onIndustryChanged: onIndustryChanged,
          onTickerSelected: onTickerSelected,
        ),
        const SizedBox(height: 10),
        ValuationSelectedOverview(
          payload: detailPayload,
          selectedRow: selectedRow,
          loading: detailLoading,
          error: detailError,
          palette: palette,
          showFullResearch: showFullResearch,
          onRetry: onRefresh,
          onToggleFullResearch: onToggleFullResearch,
        ),
        if (showFullResearch) ...[
          const SizedBox(height: 10),
          ValuationTickerDetailPanel(
            api: api,
            payload: detailPayload,
            selectedRow: selectedRow,
            loading: detailLoading,
            error: detailError,
            palette: palette,
            onRetry: onRefresh,
          ),
        ],
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 18,
                color: palette.accent,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  context.tr(
                    '估值输入：${context.ui(text(source['upstreamLabel'], 'Jansen Sharadar PIT 财务 + 可见管理层指引'))}。市场价格仅用于比较，不参与公允价值计算。',
                    'Inputs: ${context.ui(text(source['upstreamLabel'], 'Jansen Sharadar PIT financials + event-visible guidance'))}. Market price is comparison-only.',
                  ),
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ValuationToolbarMenu extends StatelessWidget {
  const _ValuationToolbarMenu({
    required this.value,
    required this.icon,
    required this.label,
    required this.options,
    required this.palette,
    required this.onChanged,
  });

  final String value;
  final IconData icon;
  final String label;
  final Map<String, String> options;
  final Palette palette;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: label,
      color: palette.card,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options.entries)
          PopupMenuItem<String>(
            value: option.key,
            child: Row(
              children: [
                Icon(
                  option.key == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 17,
                  color: option.key == value ? palette.accent : palette.muted,
                ),
                const SizedBox(width: 9),
                Text(
                  option.value,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: palette.muted),
            const SizedBox(width: 7),
            Text(
              options[value] ?? label,
              style: TextStyle(
                color: palette.text,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 7),
            Icon(Icons.expand_more_rounded, size: 17, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

class ValuationLayerBadge extends StatelessWidget {
  const ValuationLayerBadge({
    super.key,
    required this.label,
    required this.value,
    required this.status,
    required this.palette,
    this.tooltip,
  });

  final String label;
  final String value;
  final String status;
  final Palette palette;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final color = switch (normalized) {
      'pass' || 'verified' => palette.positive,
      'review' || 'guardrail_only' => const Color(0xFFE0B15A),
      'fail' => palette.negative,
      _ => palette.muted,
    };
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .32)),
      ),
      child: Text(
        context.ui('$label · $value'),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
    return Semantics(
      label: '$label, $value, ${context.ui(normalized)}',
      child: tooltip?.isNotEmpty ?? false
          ? Tooltip(message: tooltip!, child: content)
          : content,
    );
  }
}

class ValuationIndustryMap extends StatelessWidget {
  const ValuationIndustryMap({
    super.key,
    required this.rows,
    required this.selectedTicker,
    required this.expandedIndustryKey,
    required this.palette,
    required this.onIndustryChanged,
    required this.onTickerSelected,
  });

  final List<ValuationRow> rows;
  final String selectedTicker;
  final String expandedIndustryKey;
  final Palette palette;
  final ValueChanged<String> onIndustryChanged;
  final ValueChanged<ValuationRow> onTickerSelected;

  @override
  Widget build(BuildContext context) {
    final groups = valuationIndustryGroups(rows);
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact) ...[
            PanelTitle(
              icon: Icons.grid_view_rounded,
              kicker: 'INDUSTRY MAP',
              title: context.tr('按行业浏览估值', 'Browse valuation by industry'),
              trailing: Text(
                context.tr('${rows.length} 个可见标的', '${rows.length} visible'),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              palette: palette,
            ),
            const SizedBox(height: 14),
          ],
          if (groups.isEmpty)
            EmptyState(
              text: context.tr('当前筛选没有匹配标的。', 'No stocks match these filters.'),
              palette: palette,
            )
          else
            Column(
              children: [
                if (!compact) _ValuationIndustryHeader(palette: palette),
                for (final group in groups)
                  _ValuationIndustryRow(
                    group: group,
                    expanded: group.definition.key == expandedIndustryKey,
                    compact: compact,
                    selectedTicker: selectedTicker,
                    palette: palette,
                    onTap: () => onIndustryChanged(group.definition.key),
                    onTickerSelected: onTickerSelected,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ValuationIndustryHeader extends StatelessWidget {
  const _ValuationIndustryHeader({required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: palette.faint,
      fontSize: 10,
      fontWeight: FontWeight.w900,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 260,
            child: Text(context.tr('行业', 'INDUSTRY'), style: style),
          ),
          SizedBox(
            width: 100,
            child: Text(context.tr('覆盖数量', 'COVERAGE'), style: style),
          ),
          SizedBox(
            width: 170,
            child: Text(context.tr('中位估值差', 'MEDIAN GAP'), style: style),
          ),
          Expanded(
            child: Text(
              context.tr('估值分布', 'VALUATION DISTRIBUTION'),
              style: style,
            ),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }
}

class _ValuationIndustryRow extends StatelessWidget {
  const _ValuationIndustryRow({
    required this.group,
    required this.expanded,
    required this.compact,
    required this.selectedTicker,
    required this.palette,
    required this.onTap,
    required this.onTickerSelected,
  });

  final ValuationIndustryGroupData group;
  final bool expanded;
  final bool compact;
  final String selectedTicker;
  final Palette palette;
  final VoidCallback onTap;
  final ValueChanged<ValuationRow> onTickerSelected;

  @override
  Widget build(BuildContext context) {
    final tone = valuationTone(group.medianUpside, palette);
    final industryLabel = context.tr(group.definition.zh, group.definition.en);
    final title = Row(
      children: [
        Container(
          width: compact ? 34 : 26,
          height: compact ? 34 : 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: expanded
                ? palette.accent.withValues(alpha: .14)
                : palette.card,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: expanded
                  ? palette.accent.withValues(alpha: .4)
                  : palette.border,
            ),
          ),
          child: Icon(
            group.definition.icon,
            size: compact ? 18 : 14,
            color: expanded ? palette.accent : palette.muted,
          ),
        ),
        SizedBox(width: compact ? 10 : 8),
        Expanded(
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      industryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: expanded ? palette.text : palette.muted,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.tr(
                        '${group.rows.length} 个标的',
                        '${group.rows.length} stocks',
                      ),
                      style: TextStyle(color: palette.faint, fontSize: 11),
                    ),
                  ],
                )
              : Text(
                  industryLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: expanded ? palette.text : palette.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
        ),
      ],
    );
    final gap = Text(
      formatReturn(group.medianUpside),
      style: TextStyle(color: tone, fontSize: 15, fontWeight: FontWeight.w900),
    );
    final distribution = _ValuationDistributionBar(
      undervalued: group.undervaluedCount,
      fair: group.fairCount,
      expensive: group.expensiveCount,
      missing: group.missingCount,
      palette: palette,
    );
    final row = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 12),
                  gap,
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: palette.muted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              distribution,
            ],
          )
        : Row(
            children: [
              SizedBox(width: 260, child: title),
              SizedBox(
                width: 100,
                child: Text(
                  '${group.rows.length}',
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SizedBox(width: 170, child: gap),
              Expanded(child: distribution),
              SizedBox(
                width: 32,
                child: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: expanded ? palette.accent : palette.muted,
                ),
              ),
            ],
          );

    return Container(
      decoration: BoxDecoration(
        color: expanded
            ? palette.accent.withValues(alpha: .055)
            : Colors.transparent,
        border: Border(
          top: BorderSide(color: palette.border.withValues(alpha: .8)),
          left: BorderSide(
            width: 2,
            color: expanded ? palette.accent : Colors.transparent,
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 10 : 12,
                vertical: compact ? 12 : 5,
              ),
              child: row,
            ),
          ),
          if (expanded)
            _ValuationIndustryTickerGrid(
              rows: group.rows,
              selectedTicker: selectedTicker,
              palette: palette,
              onTickerSelected: onTickerSelected,
            ),
        ],
      ),
    );
  }
}

class _ValuationDistributionBar extends StatelessWidget {
  const _ValuationDistributionBar({
    required this.undervalued,
    required this.fair,
    required this.expensive,
    required this.missing,
    required this.palette,
  });

  final int undervalued;
  final int fair;
  final int expensive;
  final int missing;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final total = undervalued + fair + expensive + missing;
    Widget legendDot(Color color, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: palette.faint,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 12,
              child: total == 0
                  ? ColoredBox(color: palette.border.withValues(alpha: .7))
                  : ColoredBox(
                      color: palette.border.withValues(alpha: .45),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (undervalued > 0)
                            Expanded(
                              flex: undervalued,
                              child: ColoredBox(color: palette.positive),
                            ),
                          if (fair > 0)
                            Expanded(
                              flex: fair,
                              child: ColoredBox(color: palette.secondary),
                            ),
                          if (expensive > 0)
                            Expanded(
                              flex: expensive,
                              child: ColoredBox(color: palette.negative),
                            ),
                          if (missing > 0)
                            Expanded(
                              flex: missing,
                              child: ColoredBox(color: palette.faint),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Wrap(
          spacing: 8,
          children: [
            legendDot(palette.positive, '$undervalued'),
            legendDot(palette.secondary, '$fair'),
            legendDot(palette.negative, '$expensive'),
          ],
        ),
      ],
    );
  }
}

class _ValuationIndustryTickerGrid extends StatelessWidget {
  const _ValuationIndustryTickerGrid({
    required this.rows,
    required this.selectedTicker,
    required this.palette,
    required this.onTickerSelected,
  });

  final List<ValuationRow> rows;
  final String selectedTicker;
  final Palette palette;
  final ValueChanged<ValuationRow> onTickerSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1400
            ? 6
            : constraints.maxWidth >= 1050
            ? 5
            : constraints.maxWidth >= 760
            ? 4
            : constraints.maxWidth >= 330
            ? 2
            : 1;
        const gap = 8.0;
        final width =
            (constraints.maxWidth - 24 - gap * (columns - 1)) / columns;
        final previewCount = columns <= 2 ? 6 : 12;
        final visibleRows = rows.take(previewCount).toList();
        final selectedRow = rows
            .where((row) => row.ticker == selectedTicker)
            .firstOrNull;
        if (selectedRow != null &&
            !visibleRows.any((row) => row.ticker == selectedTicker)) {
          visibleRows[visibleRows.length - 1] = selectedRow;
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final row in visibleRows)
                SizedBox(
                  width: width,
                  child: _ValuationTickerCell(
                    row: row,
                    selected: row.ticker == selectedTicker,
                    dense: columns >= 4,
                    palette: palette,
                    onTap: () => onTickerSelected(row),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ValuationTickerCell extends StatelessWidget {
  const _ValuationTickerCell({
    required this.row,
    required this.selected,
    required this.dense,
    required this.palette,
    required this.onTap,
  });

  final ValuationRow row;
  final bool selected;
  final bool dense;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = row.hasModel
        ? valuationTone(row.upside, palette)
        : palette.faint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: dense ? 58 : 70,
        padding: EdgeInsets.symmetric(horizontal: 11, vertical: dense ? 7 : 9),
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: .14)
              : palette.card.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected
                ? palette.accent.withValues(alpha: .55)
                : palette.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                StockLogo(ticker: row.ticker, palette: palette, size: 22),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    row.ticker,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  row.hasModel ? formatReturn(row.upside) : '-',
                  style: TextStyle(
                    color: tone,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              row.hasModel
                  ? '${formatCurrencyValue(row.latestPrice, row.currency)}  ·  FV ${formatCurrencyValue(row.fairValue, row.currency)}'
                  : context.tr('估值待补', 'Valuation pending'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ValuationSelectedOverview extends StatelessWidget {
  const ValuationSelectedOverview({
    super.key,
    required this.payload,
    required this.selectedRow,
    required this.loading,
    required this.error,
    required this.palette,
    required this.showFullResearch,
    required this.onRetry,
    required this.onToggleFullResearch,
  });

  final Map<String, dynamic>? payload;
  final ValuationRow selectedRow;
  final bool loading;
  final String? error;
  final Palette palette;
  final bool showFullResearch;
  final VoidCallback onRetry;
  final VoidCallback onToggleFullResearch;

  @override
  Widget build(BuildContext context) {
    if (selectedRow.ticker.isEmpty) {
      return Panel(
        palette: palette,
        padding: const EdgeInsets.all(14),
        child: EmptyState(
          text: context.tr(
            '当前筛选没有匹配标的，旧的估值详情已隐藏。',
            'No ticker matches the current filters; the previous valuation detail is hidden.',
          ),
          palette: palette,
        ),
      );
    }
    final tickerPayload = asMap(payload?['ticker']);
    final currentOnly = isCurrentOnlyValuation(tickerPayload);
    final ticker = text(tickerPayload['ticker'], selectedRow.ticker);
    final name = text(tickerPayload['name'], selectedRow.name);
    final sector = localizedValuationSector(
      context,
      selectedRow,
      text(tickerPayload['sector'], selectedRow.sector),
    );
    final currency = text(tickerPayload['currency'], selectedRow.currency);
    final latest = asMap(tickerPayload['latest']);
    final history = asList(tickerPayload['history']).toList()
      ..sort((a, b) => text(a['asOfDate']).compareTo(text(b['asOfDate'])));
    final priceHistory = asList(tickerPayload['priceHistory']);
    final latestPrice =
        firstNumber([latest['latestPrice'], selectedRow.latestPrice]) ?? 0;
    final fairValue =
        firstNumber([latest['baseFairValue'], selectedRow.fairValue]) ?? 0;
    final upside =
        firstNumber([latest['upsideToBase'], selectedRow.upside]) ?? 0;
    final target =
        firstNumber([latest['targetPrice3Y'], selectedRow.targetPrice3Y]) ?? 0;
    final latestHistory = history.isEmpty ? <String, dynamic>{} : history.last;
    final previousHistory = history.length < 2
        ? <String, dynamic>{}
        : history[history.length - 2];
    final latestInputs = asMap(
      asMap(
        asMap(latestHistory['dataSnapshot'])['valuationSemantics'],
      )['scoreInputs'],
    );
    final previousInputs = asMap(
      asMap(
        asMap(previousHistory['dataSnapshot'])['valuationSemantics'],
      )['scoreInputs'],
    );
    final drivers = _valuationDrivers(
      context,
      latestHistory: latestHistory,
      previousHistory: previousHistory,
      latestInputs: latestInputs,
      previousInputs: previousInputs,
      currency: currency,
      palette: palette,
    );
    final selectedQuarterKey = history.isEmpty
        ? ''
        : valuationQuarterKey(history.last);
    final compactLayout = MediaQuery.sizeOf(context).width < 900;
    final priceText =
        currentOnly && nullableNumber(latest['latestPrice']) == null
        ? '—'
        : formatCurrencyValue(latestPrice, currency);
    final gapText =
        currentOnly && nullableNumber(latest['upsideToBase']) == null
        ? '—'
        : formatReturn(upside);
    final targetText =
        currentOnly && nullableNumber(latest['targetPrice3Y']) == null
        ? '—'
        : formatCurrencyValue(target, currency);
    final valueLabel = currentOnly
        ? context.tr('基准情景估值', 'Base scenario value')
        : context.tr('公允价值', 'Fair value');

    Widget metricGrid() => GridWrap(
      minTileWidth: 132,
      spacing: 8,
      children: [
        MiniMetric(
          context.tr('价格', 'Price'),
          priceText,
          Icons.show_chart_rounded,
          palette,
        ),
        MiniMetric(
          valueLabel,
          formatCurrencyValue(fairValue, currency),
          Icons.balance_rounded,
          palette,
        ),
        MiniMetric(
          context.tr('估值差距', 'Valuation gap'),
          gapText,
          Icons.trending_up_rounded,
          palette,
        ),
        MiniMetric(
          context.tr('三年情景值', '3Y scenario'),
          targetText,
          Icons.flag_outlined,
          palette,
        ),
      ],
    );

    Widget metricRailItem(String label, String value, Color tone) => Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: palette.faint,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                color: tone,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );

    Widget metricRail() => Padding(
      padding: const EdgeInsets.only(top: 34),
      child: Container(
        height: 286,
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: palette.border)),
        ),
        child: Column(
          children: [
            metricRailItem(
              context.tr('当前价格', 'Current price'),
              priceText,
              palette.text,
            ),
            Divider(height: 1, color: palette.border),
            metricRailItem(
              valueLabel,
              formatCurrencyValue(fairValue, currency),
              palette.accent,
            ),
            Divider(height: 1, color: palette.border),
            metricRailItem(
              context.tr('估值差距', 'Valuation gap'),
              gapText,
              valuationTone(upside, palette),
            ),
            Divider(height: 1, color: palette.border),
            metricRailItem(
              context.tr('三年情景值', '3Y scenario'),
              targetText,
              palette.secondary,
            ),
          ],
        ),
      ),
    );

    return Panel(
      palette: palette,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StockLogo(ticker: ticker, palette: palette, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.ui('SELECTED RESEARCH'),
                      style: TextStyle(
                        color: palette.faint,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      ticker.isEmpty
                          ? context.tr('选择一个标的', 'Select a ticker')
                          : '$ticker · $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: palette.text,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sector,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              BadgeLabel(
                text: currentOnly
                    ? context.tr('当期情景', 'Current scenario')
                    : selectedRow.valuationVerdict(context),
                color: valuationTone(selectedRow.upside, palette),
              ),
              const SizedBox(width: 4),
              _RetryIconButton(onPressed: onRetry, palette: palette),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ValuationLayerBadge(
                label: context.tr('血缘/算术', 'Lineage/arithmetic'),
                value: context.ui(selectedRow.lineageStatus),
                status: selectedRow.lineageStatus,
                tooltip: context.tr(
                  '仅检查 PIT 输入血缘、算术及价格排除声明；不代表模型经济有效。',
                  'Checks PIT input lineage, arithmetic, and declared price exclusion only; it does not establish economic model validity.',
                ),
                palette: palette,
              ),
              ValuationLayerBadge(
                label: context.tr('模型验证', 'Model validation'),
                value: context.ui(selectedRow.economicValidationStatus),
                status: selectedRow.economicValidationStatus,
                tooltip: context.tr(
                  '需要 walk-forward 预测误差与前瞻收益证据。',
                  'Requires walk-forward forecast-error and forward-return evidence.',
                ),
                palette: palette,
              ),
              ValuationLayerBadge(
                label: context.tr('市场校准', 'Market calibration'),
                value: context.ui(selectedRow.marketCalibrationStatus),
                status: selectedRow.marketCalibrationStatus,
                tooltip: context.tr(
                  'Guardrail 比较不等于样本外市场校准。',
                  'A comparison guardrail is not out-of-sample market calibration.',
                ),
                palette: palette,
              ),
            ],
          ),
          const SizedBox(height: 7),
          Tooltip(
            message: context.tr(
              '独立检查发布 ID、模型签名与快照签名是否可重现。',
              'Separately checks whether release ID, model signature, and snapshot signature are reproducible.',
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fingerprint_rounded, size: 15, color: palette.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    context.tr(
                      '发布可重现性：${context.ui(selectedRow.releaseStatus)}',
                      'Release reproducibility: ${context.ui(selectedRow.releaseStatus)}',
                    ),
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (compactLayout) ...[metricGrid(), const SizedBox(height: 14)],
          if (loading && payload == null)
            SizedBox(
              height: 300,
              child: Center(
                child: CircularProgressIndicator(color: palette.accent),
              ),
            )
          else if (error != null && payload == null)
            EmptyState(text: error!, palette: palette)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 900;
                final chart = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentOnly
                          ? context.tr('当期情景 / 股价', 'Current scenario / price')
                          : context.tr(
                              '历史估值 / 股价',
                              'Fair value / price history',
                            ),
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentOnly
                          ? context.tr(
                              '仅有一个经过独立核算的当期估值点，预测年份不是历史曲线。',
                              'One independently checked current value. Forecast years are not historical chart points.',
                            )
                          : context.ui(
                              'Historical nodes use point-in-time data; model-version reproducibility is shown separately.',
                            ),
                      style: TextStyle(
                        color: palette.faint,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: compact ? 240 : 286,
                      child: history.length < 2 && priceHistory.length < 2
                          ? EmptyState(
                              text: context.tr(
                                '暂无历史序列。',
                                'No historical series available.',
                              ),
                              palette: palette,
                            )
                          : ValuationTrendChart(
                              history: history,
                              priceHistory: priceHistory,
                              currency: currency,
                              palette: palette,
                              selectedQuarterKey: selectedQuarterKey,
                            ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        _ChartLegend(
                          color: palette.accent,
                          label: context.tr('公允价值', 'Fair value'),
                          palette: palette,
                        ),
                        _ChartLegend(
                          color: palette.secondary,
                          label: context.tr('季度股价', 'Quarter price'),
                          palette: palette,
                        ),
                        _ChartLegend(
                          color: palette.faint,
                          label: context.tr('每日股价', 'Daily price'),
                          palette: palette,
                        ),
                      ],
                    ),
                  ],
                );
                final Widget why = currentOnly
                    ? CurrentValuationScenarioCard(
                        detail: tickerPayload,
                        palette: palette,
                      )
                    : Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: palette.card.withValues(alpha: .72),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: palette.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.rule_rounded,
                                  color: palette.accent,
                                  size: 19,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  context.tr('为什么变化', 'Why it changed'),
                                  style: TextStyle(
                                    color: palette.text,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              context.tr(
                                '只比较相邻两个 PIT 财报节点。',
                                'Compares the two latest PIT reporting nodes.',
                              ),
                              style: TextStyle(
                                color: palette.faint,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(height: 10),
                            for (final driver in drivers) ...[
                              _ValuationDriverRow(
                                driver: driver,
                                palette: palette,
                              ),
                              if (driver != drivers.last)
                                Divider(height: 16, color: palette.border),
                            ],
                          ],
                        ),
                      );
                if (compact) {
                  return Column(
                    children: [chart, const SizedBox(height: 14), why],
                  );
                }
                final chartWithMetrics = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: chart),
                    const SizedBox(width: 12),
                    SizedBox(width: 154, child: metricRail()),
                  ],
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: chartWithMetrics),
                    const SizedBox(width: 16),
                    Expanded(flex: 3, child: why),
                  ],
                );
              },
            ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onToggleFullResearch,
              icon: Icon(
                showFullResearch
                    ? Icons.expand_less_rounded
                    : Icons.open_in_new_rounded,
              ),
              label: Text(
                showFullResearch
                    ? context.tr('收起完整研究', 'Hide full research')
                    : context.tr('打开完整研究', 'Open full research'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValuationDriver {
  const _ValuationDriver({
    required this.label,
    required this.value,
    required this.change,
    required this.note,
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final String change;
  final String note;
  final Color color;
  final IconData icon;
}

List<_ValuationDriver> _valuationDrivers(
  BuildContext context, {
  required Map<String, dynamic> latestHistory,
  required Map<String, dynamic> previousHistory,
  required Map<String, dynamic> latestInputs,
  required Map<String, dynamic> previousInputs,
  required String currency,
  required Palette palette,
}) {
  double? input(Map<String, dynamic> values, String key) =>
      nullableNumber(values[key]);
  String change(double? latest, double? previous) {
    if (latest == null || previous == null || previous == 0) return '-';
    return formatReturn(latest / previous - 1);
  }

  Color tone(double? latest, double? previous) {
    if (latest == null || previous == null || previous == 0) {
      return palette.muted;
    }
    return latest >= previous ? palette.positive : palette.negative;
  }

  final latestRevenue =
      input(latestInputs, 'revenueGuidanceM') ??
      input(latestInputs, 'valuationRevenue');
  final previousRevenue =
      input(previousInputs, 'revenueGuidanceM') ??
      input(previousInputs, 'valuationRevenue');
  final latestFcf =
      input(latestInputs, 'valuationFreeCashFlow') ??
      input(latestInputs, 'ttmFreeCashFlow');
  final previousFcf =
      input(previousInputs, 'valuationFreeCashFlow') ??
      input(previousInputs, 'ttmFreeCashFlow');
  final latestFairValue = nullableNumber(latestHistory['fairValue']);
  final previousFairValue = nullableNumber(previousHistory['fairValue']);

  return [
    _ValuationDriver(
      label: context.tr('全年收入输入', 'FY revenue input'),
      value: _formatModelAmountM(latestRevenue, currency),
      change: change(latestRevenue, previousRevenue),
      note: context.tr(
        input(latestInputs, 'revenueGuidanceM') != null
            ? '管理层全年指引，已排除下一季度和分部收入。'
            : '未找到可用全年指引，使用模型前瞻收入。',
        input(latestInputs, 'revenueGuidanceM') != null
            ? 'Management FY guide; next-quarter and segment revenue excluded.'
            : 'No valid FY guide; model-forward revenue used.',
      ),
      color: tone(latestRevenue, previousRevenue),
      icon: Icons.campaign_outlined,
    ),
    _ValuationDriver(
      label: context.tr('估值自由现金流', 'Valuation free cash flow'),
      value: _formatModelAmountM(latestFcf, currency),
      change: change(latestFcf, previousFcf),
      note: context.tr(
        input(latestInputs, 'fcfGuidanceM') != null
            ? '使用管理层全年 FCF 指引。'
            : '使用 PIT 财务与模型前瞻比例。',
        input(latestInputs, 'fcfGuidanceM') != null
            ? 'Management FY FCF guidance used.'
            : 'Uses PIT financials and the model forward scale.',
      ),
      color: tone(latestFcf, previousFcf),
      icon: Icons.account_balance_wallet_outlined,
    ),
    _ValuationDriver(
      label: context.tr('公允价值', 'Fair value'),
      value: latestFairValue == null
          ? '-'
          : formatCurrencyValue(latestFairValue, currency),
      change: change(latestFairValue, previousFairValue),
      note: context.tr(
        '保持同一估值方法，只更新当时可见的 PIT 输入。',
        'Same valuation method; only event-visible PIT inputs changed.',
      ),
      color: tone(latestFairValue, previousFairValue),
      icon: Icons.balance_outlined,
    ),
  ];
}

String _formatModelAmountM(double? value, String currency) {
  if (value == null || !value.isFinite) return '-';
  final symbol = switch (currency.toUpperCase()) {
    'GBP' => '£',
    'EUR' => '€',
    'JPY' => '¥',
    _ => r'$',
  };
  final absolute = value.abs();
  if (absolute >= 1000) {
    final digits = absolute >= 10000 ? 1 : 2;
    return '$symbol${(value / 1000).toStringAsFixed(digits)}B';
  }
  return '$symbol${value.toStringAsFixed(0)}M';
}

class _ValuationDriverRow extends StatelessWidget {
  const _ValuationDriverRow({required this.driver, required this.palette});

  final _ValuationDriver driver;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: driver.color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(driver.icon, size: 16, color: driver.color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      driver.label,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    driver.change,
                    style: TextStyle(
                      color: driver.color,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                driver.value,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                driver.note,
                style: TextStyle(
                  color: palette.faint,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ValuationWatchlistHeader extends StatelessWidget {
  const ValuationWatchlistHeader({super.key, required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) return const SizedBox.shrink();
        final style = TextStyle(
          color: palette.faint,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        );
        return Row(
          children: [
            SizedBox(
              width: 260,
              child: Text(context.ui('COMPANY'), style: style),
            ),
            Expanded(
              child: Text(context.ui('UPSIDE / DOWNSIDE'), style: style),
            ),
            SizedBox(
              width: 120,
              child: Text(
                context.ui('PRICE / FV'),
                textAlign: TextAlign.end,
                style: style,
              ),
            ),
            const SizedBox(width: 18),
            SizedBox(
              width: 120,
              child: Text(
                context.ui('3Y SCENARIO'),
                textAlign: TextAlign.end,
                style: style,
              ),
            ),
            const SizedBox(width: 18),
            SizedBox(
              width: 112,
              child: Text(
                context.ui('QUALITY'),
                textAlign: TextAlign.end,
                style: style,
              ),
            ),
          ],
        );
      },
    );
  }
}

class ValuationTickerPickerCard extends StatelessWidget {
  const ValuationTickerPickerCard({
    super.key,
    required this.row,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final ValuationRow row;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = valuationTone(row.upside, palette);
    return SizedBox(
      width: 176,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: active ? tone.withValues(alpha: .12) : palette.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? tone.withValues(alpha: .45) : palette.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.ticker,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    formatReturn(row.upside),
                    style: TextStyle(
                      color: tone,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(
                        '股价 ${formatCurrencyValue(row.latestPrice, row.currency)}',
                        'Price ${formatCurrencyValue(row.latestPrice, row.currency)}',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.faint, fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.tr(
                      '公允价值 ${formatCurrencyValue(row.fairValue, row.currency)}',
                      'FV ${formatCurrencyValue(row.fairValue, row.currency)}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ValuationWatchlistRow extends StatelessWidget {
  const ValuationWatchlistRow({
    super.key,
    required this.row,
    required this.maxAbsUpside,
    required this.active,
    required this.palette,
    required this.onTap,
  });

  final ValuationRow row;
  final double maxAbsUpside;
  final bool active;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = valuationTone(row.upside, palette);
    final barValue = maxAbsUpside <= 0
        ? 0.0
        : math.max(.04, row.upside.abs() / maxAbsUpside).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        final company = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  row.ticker,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 8),
                ValuationQualityChip(
                  label: row.coverageLabel,
                  palette: palette,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              localizedValuationSector(context, row),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.faint, fontSize: 11),
            ),
          ],
        );
        final upside = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    formatReturn(row.upside),
                    style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: barValue,
                      minHeight: 8,
                      backgroundColor: palette.border,
                      color: tone,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.consensusTextFor(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.faint, fontSize: 11),
            ),
          ],
        );
        final price = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatCurrencyValue(row.latestPrice, row.currency),
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              context.tr(
                '公允价值 ${formatCurrencyValue(row.fairValue, row.currency)}',
                'FV ${formatCurrencyValue(row.fairValue, row.currency)}',
              ),
              style: TextStyle(
                color: palette.faint,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );
        final target = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatCurrencyValue(row.targetPrice3Y, row.currency),
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              context.tr(
                '${formatReturn(row.expectedReturn3Y)} 年化收益',
                '${formatReturn(row.expectedReturn3Y)} IRR',
              ),
              style: TextStyle(color: palette.faint, fontSize: 12),
            ),
          ],
        );
        final quality = Align(
          alignment: Alignment.centerRight,
          child: ValuationQualityChip(
            label: context.tr(
              '血缘 ${context.ui(row.auditLabel)}',
              'lineage ${context.ui(row.auditLabel)}',
            ),
            palette: palette,
            strong: row.auditStatus == 'pass',
          ),
        );

        final content = compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: company),
                      quality,
                    ],
                  ),
                  const SizedBox(height: 9),
                  upside,
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Expanded(child: price),
                      const SizedBox(width: 16),
                      Expanded(child: target),
                    ],
                  ),
                ],
              )
            : Row(
                children: [
                  SizedBox(width: 260, child: company),
                  Expanded(child: upside),
                  const SizedBox(width: 18),
                  SizedBox(width: 120, child: price),
                  const SizedBox(width: 18),
                  SizedBox(width: 120, child: target),
                  const SizedBox(width: 18),
                  SizedBox(width: 112, child: quality),
                ],
              );

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: active
                    ? tone.withValues(alpha: .10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active
                      ? tone.withValues(alpha: .40)
                      : Colors.transparent,
                ),
              ),
              child: content,
            ),
          ),
        );
      },
    );
  }
}

class ValuationTickerDetailPanel extends StatelessWidget {
  const ValuationTickerDetailPanel({
    super.key,
    required this.api,
    required this.payload,
    required this.selectedRow,
    required this.loading,
    required this.error,
    required this.palette,
    required this.onRetry,
  });

  final ApiClient api;
  final Map<String, dynamic>? payload;
  final ValuationRow selectedRow;
  final bool loading;
  final String? error;
  final Palette palette;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tickerPayload = asMap(payload?['ticker']);
    final ticker = text(tickerPayload['ticker'], selectedRow.ticker);
    final name = text(tickerPayload['name'], selectedRow.name);
    final sector = localizedValuationSector(
      context,
      selectedRow,
      text(tickerPayload['sector'], selectedRow.sector),
    );
    final currency = text(tickerPayload['currency'], selectedRow.currency);
    final latest = asMap(tickerPayload['latest']);
    final history = asList(tickerPayload['history']);
    final priceHistory = asList(tickerPayload['priceHistory']);
    final methodCards = asList(tickerPayload['methodCards']).take(3).toList();
    final podcastInsights = asList(tickerPayload['podcastInsights']);
    final latestPrice =
        firstNumber([latest['latestPrice'], selectedRow.latestPrice]) ?? 0;
    final fairValue =
        firstNumber([latest['baseFairValue'], selectedRow.fairValue]) ?? 0;
    final upside =
        firstNumber([latest['upsideToBase'], selectedRow.upside]) ?? 0;
    final target =
        firstNumber([latest['targetPrice3Y'], selectedRow.targetPrice3Y]) ?? 0;

    return Panel(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelTitle(
            icon: Icons.insights_rounded,
            kicker: 'TICKER RESEARCH',
            title: ticker.isEmpty
                ? context.tr('单票历史估值', 'Ticker Valuation History')
                : context.tr(
                    '$ticker 历史估值 / 股价走势',
                    '$ticker Valuation / Price History',
                  ),
            trailing: _RetryIconButton(onPressed: onRetry, palette: palette),
            palette: palette,
          ),
          const SizedBox(height: 14),
          if (loading)
            const SizedBox(
              height: 280,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            EmptyState(text: error!, palette: palette)
          else if (ticker.isEmpty)
            EmptyState(
              text: 'Select a ticker from the matrix.',
              palette: palette,
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sector,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                BadgeLabel(
                  text: selectedRow.coverageLabel,
                  color: palette.accent,
                ),
              ],
            ),
            const SizedBox(height: 14),
            GridWrap(
              minTileWidth: 140,
              spacing: 10,
              children: [
                MiniMetric(
                  'Price',
                  formatCurrencyValue(latestPrice, currency),
                  Icons.show_chart_rounded,
                  palette,
                ),
                MiniMetric(
                  'Fair value',
                  formatCurrencyValue(fairValue, currency),
                  Icons.balance_rounded,
                  palette,
                ),
                MiniMetric(
                  'Upside',
                  formatReturn(upside),
                  Icons.trending_up_rounded,
                  palette,
                ),
                MiniMetric(
                  '3Y scenario',
                  formatCurrencyValue(target, currency),
                  Icons.flag_rounded,
                  palette,
                ),
              ],
            ),
            ValuationTickerHistorySection(
              api: api,
              rows: history,
              priceHistory: priceHistory,
              fallbackMethodCards: methodCards,
              currency: currency,
              palette: palette,
            ),
            const SizedBox(height: 12),
            ValuationPodcastInsightsSection(
              ticker: ticker,
              insights: podcastInsights,
              palette: palette,
            ),
          ],
        ],
      ),
    );
  }
}

class ValuationTickerHistorySection extends StatefulWidget {
  const ValuationTickerHistorySection({
    super.key,
    required this.api,
    required this.rows,
    required this.priceHistory,
    required this.fallbackMethodCards,
    required this.currency,
    required this.palette,
  });

  final ApiClient api;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> priceHistory;
  final List<Map<String, dynamic>> fallbackMethodCards;
  final String currency;
  final Palette palette;

  @override
  State<ValuationTickerHistorySection> createState() =>
      _ValuationTickerHistorySectionState();
}

class _ValuationTickerHistorySectionState
    extends State<ValuationTickerHistorySection> {
  String _selectedQuarterKey = '';

  @override
  void didUpdateWidget(covariant ValuationTickerHistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rows == widget.rows) return;
    if (_selectedQuarterKey.isEmpty) return;
    final hasSelected = widget.rows.any(
      (row) => valuationQuarterKey(row) == _selectedQuarterKey,
    );
    if (!hasSelected) _selectedQuarterKey = '';
  }

  @override
  Widget build(BuildContext context) {
    final sortedRows = widget.rows.toList()
      ..sort((a, b) => text(b['asOfDate']).compareTo(text(a['asOfDate'])));
    final effectiveSelectedKey = _selectedQuarterKey.isNotEmpty
        ? _selectedQuarterKey
        : (sortedRows.isEmpty ? '' : valuationQuarterKey(sortedRows.first));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        if (widget.rows.length < 2 && widget.priceHistory.length < 2)
          EmptyState(
            text: 'No historical valuation or price series available.',
            palette: widget.palette,
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final chartHeight = constraints.maxWidth < 560 ? 250.0 : 320.0;
              return SizedBox(
                height: chartHeight,
                child: ValuationTrendChart(
                  history: widget.rows,
                  priceHistory: widget.priceHistory,
                  currency: widget.currency,
                  palette: widget.palette,
                  selectedQuarterKey: effectiveSelectedKey,
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _ChartLegend(
              color: widget.palette.accent,
              label: 'Fair value',
              palette: widget.palette,
            ),
            _ChartLegend(
              color: widget.palette.secondary,
              label: 'Quarter price',
              palette: widget.palette,
            ),
            _ChartLegend(
              color: widget.palette.faint,
              label: 'Daily price',
              palette: widget.palette,
            ),
          ],
        ),
        const SizedBox(height: 18),
        ValuationQuarterResearchPanel(
          api: widget.api,
          rows: widget.rows,
          fallbackMethodCards: widget.fallbackMethodCards,
          currency: widget.currency,
          palette: widget.palette,
          selectedQuarterKey: effectiveSelectedKey,
          onSelectQuarter: (value) {
            setState(() => _selectedQuarterKey = value);
          },
        ),
      ],
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({
    required this.color,
    required this.label,
    required this.palette,
  });

  final Color color;
  final String label;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 4,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: palette.muted,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class ValuationChartWindow {
  const ValuationChartWindow({
    required this.valuationPoints,
    required this.pricePoints,
  });

  final List<Map<String, dynamic>> valuationPoints;
  final List<Map<String, dynamic>> pricePoints;
}

/// Aligns the chart viewport with the first point-in-time fair-value estimate.
/// Source history remains untouched; only the rows sent to the painter are
/// trimmed, so a price-only lead-in cannot stretch the chart's x-axis.
ValuationChartWindow valuationChartWindow(
  List<Map<String, dynamic>> history,
  List<Map<String, dynamic>> priceHistory,
) {
  final validValuations =
      history
          .where((row) => DateTime.tryParse(text(row['asOfDate'])) != null)
          .toList()
        ..sort((a, b) => text(a['asOfDate']).compareTo(text(b['asOfDate'])));
  final pricesByDate = <String, Map<String, dynamic>>{};
  for (final row in priceHistory) {
    final date = text(row['date']);
    if (DateTime.tryParse(date) == null ||
        (nullableNumber(row['close']) ?? 0) <= 0) {
      continue;
    }
    pricesByDate[date] = row;
  }
  final validPrices = pricesByDate.values.toList()
    ..sort((a, b) => text(a['date']).compareTo(text(b['date'])));
  final modeledValuations = validValuations.where((row) {
    final fairValue = nullableNumber(row['fairValue']);
    return fairValue != null && fairValue > 0;
  }).toList();

  // A single estimate is not a trend and should not hide otherwise useful
  // price history. This also protects partial or newly onboarded tickers.
  if (modeledValuations.length < 2) {
    return ValuationChartWindow(
      valuationPoints: validValuations,
      pricePoints: validPrices,
    );
  }

  final windowStart = DateTime.parse(text(modeledValuations.first['asOfDate']));
  final trimmedPrices = validPrices
      .where((row) => !DateTime.parse(text(row['date'])).isBefore(windowStart))
      .toList();

  return ValuationChartWindow(
    valuationPoints: validValuations
        .where(
          (row) => !DateTime.parse(text(row['asOfDate'])).isBefore(windowStart),
        )
        .toList(),
    // If the price series and model do not overlap, preserve the original
    // price series instead of leaving a misleading empty or one-point line.
    pricePoints: trimmedPrices.length >= 2 ? trimmedPrices : validPrices,
  );
}

class ValuationTrendChart extends StatelessWidget {
  const ValuationTrendChart({
    super.key,
    required this.history,
    required this.priceHistory,
    required this.currency,
    required this.palette,
    required this.selectedQuarterKey,
    this.labelFontSize = 10,
  });

  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> priceHistory;
  final String currency;
  final Palette palette;
  final String selectedQuarterKey;
  final double labelFontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: context.tr(
        '公允价值与股价历史图，${history.length} 个估值节点，${priceHistory.length} 个股价点。',
        'Fair-value and price history chart with ${history.length} valuation nodes and ${priceHistory.length} price points.',
      ),
      child: CustomPaint(
        painter: ValuationTrendPainter(
          history: history,
          priceHistory: priceHistory,
          currency: currency,
          palette: palette,
          selectedQuarterKey: selectedQuarterKey,
          labelFontSize: labelFontSize,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class ValuationTrendPainter extends CustomPainter {
  ValuationTrendPainter({
    required this.history,
    required this.priceHistory,
    required this.currency,
    required this.palette,
    required this.selectedQuarterKey,
    this.labelFontSize = 10,
  });

  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> priceHistory;
  final String currency;
  final Palette palette;
  final String selectedQuarterKey;
  final double labelFontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 54.0;
    final right = size.width - 14;
    final top = 16.0;
    final bottom = size.height - 28;
    final chartWindow = valuationChartWindow(history, priceHistory);
    final valuationPoints = chartWindow.valuationPoints;
    final pricePoints = chartWindow.pricePoints;
    final dateValues = <int>[
      for (final row in pricePoints)
        ?DateTime.tryParse(text(row['date']))?.millisecondsSinceEpoch,
      for (final row in valuationPoints)
        ?DateTime.tryParse(text(row['asOfDate']))?.millisecondsSinceEpoch,
    ];
    final values = <double>[
      for (final row in pricePoints) number(row['close']),
      for (final row in valuationPoints) ...[
        firstNumber([row['fairValue']]) ?? 0,
        firstNumber([row['priceAtDate'], row['currentPrice']]) ?? 0,
      ],
    ].where((value) => value > 0 && value.isFinite).toList();
    if (dateValues.length < 2 || values.length < 2) return;

    final minMs = dateValues.reduce(math.min);
    final maxMs = dateValues.reduce(math.max);
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final dateSpan = math.max(1, maxMs - minMs).toDouble();
    final valueSpan = math.max(.0001, maxValue - minValue);

    double xForDate(String value) {
      final date = DateTime.tryParse(value);
      if (date == null) return left;
      return left +
          (right - left) * (date.millisecondsSinceEpoch - minMs) / dateSpan;
    }

    double yForValue(double value) =>
        bottom - ((value - minValue) / valueSpan) * (bottom - top);

    final gridPaint = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: palette.faint,
      fontSize: labelFontSize,
      fontWeight: FontWeight.w700,
    );
    for (var i = 0; i < 4; i += 1) {
      final y = top + (bottom - top) * i / 3;
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
      final labelValue = maxValue - valueSpan * i / 3;
      _drawText(
        canvas,
        formatCurrencyValue(labelValue, currency),
        Offset(0, y - 7),
        labelStyle,
      );
    }

    Path pathFromRows(
      List<Map<String, dynamic>> rows,
      String dateKey,
      List<String> valueKeys,
    ) {
      final path = Path();
      var started = false;
      for (final row in rows) {
        final value = firstNumber([for (final key in valueKeys) row[key]]);
        final date = text(row[dateKey]);
        if (value == null || value <= 0 || date.isEmpty) continue;
        final point = Offset(xForDate(date), yForValue(value));
        if (!started) {
          path.moveTo(point.dx, point.dy);
          started = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      return path;
    }

    canvas.drawPath(
      pathFromRows(pricePoints, 'date', const ['close']),
      Paint()
        ..color = palette.faint.withValues(alpha: .72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7,
    );
    canvas.drawPath(
      pathFromRows(valuationPoints, 'asOfDate', const [
        'priceAtDate',
        'currentPrice',
      ]),
      Paint()
        ..color = palette.secondary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    canvas.drawPath(
      pathFromRows(valuationPoints, 'asOfDate', const ['fairValue']),
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    for (final row in valuationPoints) {
      final x = xForDate(text(row['asOfDate']));
      final fairValue = firstNumber([row['fairValue']]);
      final price = firstNumber([row['priceAtDate'], row['currentPrice']]);
      final isSelected =
          selectedQuarterKey.isNotEmpty &&
          valuationQuarterKey(row) == selectedQuarterKey;
      if (price != null && price > 0) {
        final point = Offset(x, yForValue(price));
        if (isSelected) {
          canvas.drawCircle(
            point,
            8,
            Paint()..color = palette.secondary.withValues(alpha: .22),
          );
          canvas.drawCircle(
            point,
            5.4,
            Paint()
              ..color = palette.text.withValues(alpha: .70)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.7,
          );
        }
        canvas.drawCircle(
          point,
          isSelected ? 4.8 : 3.5,
          Paint()..color = palette.secondary,
        );
      }
      if (fairValue != null && fairValue > 0) {
        final point = Offset(x, yForValue(fairValue));
        if (isSelected) {
          canvas.drawCircle(
            point,
            10,
            Paint()..color = palette.accent.withValues(alpha: .24),
          );
          canvas.drawCircle(
            point,
            6.4,
            Paint()
              ..color = palette.text.withValues(alpha: .76)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.8,
          );
        }
        canvas.drawCircle(
          point,
          isSelected ? 5.8 : 4.5,
          Paint()..color = palette.accent,
        );
      }
    }

    final startDate = DateTime.fromMillisecondsSinceEpoch(
      minMs,
    ).toIso8601String();
    final endDate = DateTime.fromMillisecondsSinceEpoch(
      maxMs,
    ).toIso8601String();
    _drawText(
      canvas,
      formatDate(startDate),
      Offset(left, bottom + 9),
      labelStyle,
    );
    _drawText(
      canvas,
      formatDate(endDate),
      Offset(right - (labelFontSize > 10 ? 94 : 70), bottom + 9),
      labelStyle,
    );
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: labelFontSize > 10 ? 96 : 72);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant ValuationTrendPainter oldDelegate) =>
      oldDelegate.labelFontSize != labelFontSize ||
      oldDelegate.history != history ||
      oldDelegate.priceHistory != priceHistory ||
      oldDelegate.selectedQuarterKey != selectedQuarterKey ||
      oldDelegate.palette.colorBlind != palette.colorBlind;
}

class ValuationHistoryTable extends StatelessWidget {
  const ValuationHistoryTable({
    super.key,
    required this.rows,
    required this.currency,
    required this.palette,
  });

  final List<Map<String, dynamic>> rows;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final latestRows = rows.toList()
      ..sort((a, b) => text(b['asOfDate']).compareTo(text(a['asOfDate'])));
    final visible = latestRows.take(8).toList();
    if (visible.isEmpty) {
      return EmptyState(
        text: 'No quarterly valuation history.',
        palette: palette,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.ui('Recent quarterly valuation history'),
          style: TextStyle(color: palette.text, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        for (final row in visible)
          ValuationHistoryLine(row: row, currency: currency, palette: palette),
      ],
    );
  }
}

class ValuationHistoryLine extends StatelessWidget {
  const ValuationHistoryLine({
    super.key,
    required this.row,
    required this.currency,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final price = firstNumber([row['priceAtDate'], row['currentPrice']]) ?? 0;
    final fairValue = firstNumber([row['fairValue']]) ?? 0;
    final upside =
        firstNumber([row['upsideDownside']]) ??
        (price > 0 && fairValue > 0 ? fairValue / price - 1 : 0);
    final tone = valuationTone(upside, palette);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        if (compact) {
          return Container(
            margin: const EdgeInsets.only(bottom: 9),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: palette.card.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.border),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        text(row['label'], '-'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      formatReturn(upside),
                      style: TextStyle(
                        color: tone,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatDate(text(row['asOfDate'])),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                    ),
                    Text(
                      context.tr(
                        '股价 ${formatCurrencyValue(price, currency)}',
                        'Price ${formatCurrencyValue(price, currency)}',
                      ),
                      style: TextStyle(
                        color: palette.faint,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      context.tr(
                        '公允价值 ${formatCurrencyValue(fairValue, currency)}',
                        'FV ${formatCurrencyValue(fairValue, currency)}',
                      ),
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  text(row['label'], '-'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  formatDate(text(row['asOfDate'])),
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ),
              SizedBox(
                width: 96,
                child: Text(
                  formatCurrencyValue(price, currency),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(
                  formatCurrencyValue(fairValue, currency),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 72,
                child: Text(
                  formatReturn(upside),
                  textAlign: TextAlign.end,
                  style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ValuationQuarterResearchPanel extends StatefulWidget {
  const ValuationQuarterResearchPanel({
    super.key,
    required this.api,
    required this.rows,
    required this.fallbackMethodCards,
    required this.currency,
    required this.palette,
    required this.selectedQuarterKey,
    required this.onSelectQuarter,
  });

  final ApiClient api;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> fallbackMethodCards;
  final String currency;
  final Palette palette;
  final String selectedQuarterKey;
  final ValueChanged<String> onSelectQuarter;

  @override
  State<ValuationQuarterResearchPanel> createState() =>
      _ValuationQuarterResearchPanelState();
}

class _ValuationQuarterResearchPanelState
    extends State<ValuationQuarterResearchPanel> {
  String _selectedKey = '';
  int? _expandedQaIndex;

  List<Map<String, dynamic>> get _sortedRows {
    final rows = widget.rows.toList()
      ..sort((a, b) => text(b['asOfDate']).compareTo(text(a['asOfDate'])));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _sortedRows;
    if (rows.isEmpty) {
      return EmptyState(
        text: 'No quarterly valuation history.',
        palette: widget.palette,
      );
    }

    final selected = _selectedRow(rows);
    final selectedIndex = rows.indexOf(selected);
    final previous = selectedIndex >= 0 && selectedIndex + 1 < rows.length
        ? rows[selectedIndex + 1]
        : null;
    final selectedKey = _rowKey(selected, selectedIndex);
    final quarterCountLabel =
        '${formatNumber(rows.length.toDouble())} quarters';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: widget.palette.card.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: widget.palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_note_rounded, color: widget.palette.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.ui('QUARTERLY MODEL BOOK'),
                      style: TextStyle(
                        color: widget.palette.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.tr('季度研究卡', 'Quarterly Model Book'),
                      style: TextStyle(
                        color: widget.palette.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                quarterCountLabel,
                style: TextStyle(
                  color: widget.palette.faint,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < rows.length; index += 1)
                  Padding(
                    padding: EdgeInsets.only(
                      right: index == rows.length - 1 ? 0 : 10,
                    ),
                    child: ValuationQuarterChip(
                      row: rows[index],
                      selected: _rowKey(rows[index], index) == selectedKey,
                      currency: widget.currency,
                      palette: widget.palette,
                      onTap: () {
                        setState(() {
                          _selectedKey = _rowKey(rows[index], index);
                          _expandedQaIndex = null;
                        });
                        widget.onSelectQuarter(_selectedKey);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 780;
              final inputCard = ValuationInputResearchCard(
                row: selected,
                currency: widget.currency,
                palette: widget.palette,
              );
              final outputCard = ValuationOutputResearchCard(
                row: selected,
                fallbackMethodCards: widget.fallbackMethodCards,
                currency: widget.currency,
                palette: widget.palette,
              );
              if (compact) {
                return Column(
                  children: [inputCard, const SizedBox(height: 12), outputCard],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: inputCard),
                  const SizedBox(width: 12),
                  Expanded(child: outputCard),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          ValuationQuarterQaList(
            api: widget.api,
            row: selected,
            previous: previous,
            currency: widget.currency,
            palette: widget.palette,
            expandedIndex: _expandedQaIndex,
            onToggle: (index) {
              setState(() {
                _expandedQaIndex = _expandedQaIndex == index ? null : index;
              });
            },
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _selectedRow(List<Map<String, dynamic>> rows) {
    if (widget.selectedQuarterKey.isNotEmpty) {
      for (var index = 0; index < rows.length; index += 1) {
        if (_rowKey(rows[index], index) == widget.selectedQuarterKey) {
          return rows[index];
        }
      }
    }
    if (_selectedKey.isNotEmpty) {
      for (var index = 0; index < rows.length; index += 1) {
        if (_rowKey(rows[index], index) == _selectedKey) return rows[index];
      }
    }
    return rows.first;
  }

  String _rowKey(Map<String, dynamic> row, int index) {
    final key = valuationQuarterKey(row);
    if (key.isNotEmpty) return key;
    return 'quarter-$index';
  }
}

String valuationQuarterKey(Map<String, dynamic> row) {
  final periodId = text(row['periodId']);
  if (periodId.isNotEmpty) return periodId;
  final asOfDate = text(row['asOfDate']);
  final label = text(row['label']);
  if (asOfDate.isNotEmpty || label.isNotEmpty) return '$label-$asOfDate';
  final fiscalYear = text(row['fiscalYear']);
  final fiscalQuarter = text(row['fiscalQuarter']);
  if (fiscalYear.isNotEmpty || fiscalQuarter.isNotEmpty) {
    return '$fiscalYear-$fiscalQuarter';
  }
  return '';
}

class ValuationQuarterChip extends StatelessWidget {
  const ValuationQuarterChip({
    super.key,
    required this.row,
    required this.selected,
    required this.currency,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final bool selected;
  final String currency;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final price = firstNumber([row['priceAtDate'], row['currentPrice']]) ?? 0;
    final fairValue = firstNumber([row['fairValue']]) ?? 0;
    final upside =
        firstNumber([row['upsideDownside']]) ??
        (price > 0 && fairValue > 0 ? fairValue / price - 1 : 0);
    final tone = valuationTone(upside, palette);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? palette.accent.withValues(alpha: .16)
              : palette.panel.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? palette.accent : palette.border,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text(row['label'], '-'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? palette.accent : palette.text,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              formatDate(text(row['asOfDate'])),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? palette.muted : palette.faint,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatCurrencyValue(fairValue, currency),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  formatReturn(upside),
                  style: TextStyle(color: tone, fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ValuationInputResearchCard extends StatelessWidget {
  const ValuationInputResearchCard({
    super.key,
    required this.row,
    required this.currency,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final snapshot = asMap(row['dataSnapshot']);
    final selectedPeriod = asMap(snapshot['selectedFinancialPeriod']);
    final fiscal = asMap(snapshot['fiscalFinancials']);
    final ttm = asMap(snapshot['trailingTwelveMonths']);
    final semantics = asMap(snapshot['valuationSemantics']);
    final scoreInputs = asMap(semantics['scoreInputs']);
    final youtube = asMap(snapshot['youtubeEarnings']);
    final economicInput = asMap(scoreInputs['reviewedEconomicInput']);
    final economicTtm = asMap(economicInput['ttm']);
    final economicBalance = asMap(economicInput['balanceNormalization']);
    final evidence = asList(youtube['evidence']);
    final revenue = firstNumber([
      fiscal['revenue_m'],
      ttm['revenue_m'],
      scoreInputs['ttmRevenue'],
    ]);
    final revenueGrowth = firstNumber([
      fiscal['revenue_growth_pct'],
      scoreInputs['revenueGrowth'],
    ]);
    final fcf = firstNumber([
      fiscal['fcf_after_capex_m'],
      ttm['fcf_after_capex_m'],
      scoreInputs['ttmFreeCashFlow'],
    ]);
    final operatingMargin = firstNumber([
      fiscal['operating_margin_pct'],
      ttm['operating_margin_pct'],
      scoreInputs['operatingMargin'],
    ]);
    final normalizedMargin = firstNumber([scoreInputs['normalizedMargin']]);
    final guidanceRevenue = firstNumber([
      scoreInputs['revenueGuidanceM'],
      youtube['revenueGuidanceM'],
    ]);
    final guidanceMargin = firstNumber([
      scoreInputs['guidanceOperatingMargin'],
      youtube['operatingMargin'],
    ]);
    final sourceQuality = text(
      snapshot['sourceQuality'],
      text(row['sourceType']),
    );

    return ValuationResearchCard(
      palette: palette,
      icon: Icons.dataset_rounded,
      kicker: 'MODEL INPUTS',
      title: context.tr('财务与指引数据', 'Financials & Guidance Inputs'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InfoChip(
                text(selectedPeriod['periodEndDate']).isEmpty
                    ? text(row['label'], '-')
                    : 'Period end ${formatDate(text(selectedPeriod['periodEndDate']))}',
                palette: palette,
              ),
              InfoChip(sourceQuality, palette: palette),
              InfoChip(
                '${formatNumber(number(snapshot['financialPeriodCount']))} financial rows',
                palette: palette,
              ),
              if (number(snapshot['transcriptCandidateCount']) > 0)
                InfoChip(
                  '${formatNumber(number(snapshot['transcriptCandidateCount']))} transcript metrics',
                  palette: palette,
                ),
            ],
          ),
          const SizedBox(height: 12),
          GridWrap(
            minTileWidth: 132,
            spacing: 8,
            children: [
              ValuationResearchMetric(
                label: economicInput['warrantNormalization'] != null
                    ? 'Revenue (warrant-normalized)'
                    : 'Revenue',
                value: formatMillions(revenue),
                palette: palette,
              ),
              ValuationResearchMetric(
                label: 'Revenue growth',
                value: formatPercentInput(revenueGrowth),
                palette: palette,
              ),
              ValuationResearchMetric(
                label: 'Operating margin',
                value: formatPercentInput(operatingMargin),
                palette: palette,
              ),
              ValuationResearchMetric(
                label: 'Normalized margin',
                value: formatPercentInput(normalizedMargin),
                palette: palette,
              ),
              ValuationResearchMetric(
                label: economicInput.isNotEmpty
                    ? 'Economic FCFE (TTM)'
                    : 'FCF after capex',
                value: formatMillions(
                  economicInput.isNotEmpty
                      ? firstNumber([economicTtm['economicFcfeM']])
                      : fcf,
                ),
                palette: palette,
              ),
              if (economicInput.isNotEmpty) ...[
                ValuationResearchMetric(
                  label: 'Reported FCF (TTM)',
                  value: formatMillions(
                    firstNumber([economicTtm['reportedFcfM']]),
                  ),
                  palette: palette,
                ),
                ValuationResearchMetric(
                  label: 'SBC deducted (TTM)',
                  value: formatMillions(firstNumber([economicTtm['sbcM']])),
                  palette: palette,
                ),
                ValuationResearchMetric(
                  label: 'License cash deducted (TTM)',
                  value: formatMillions(
                    firstNumber([economicTtm['licensePaymentsM']]),
                  ),
                  palette: palette,
                ),
              ],
              if (economicBalance.isNotEmpty) ...[
                ValuationResearchMetric(
                  label: 'Cash & unrestricted investments',
                  value: formatMillions(firstNumber([fiscal['cash_m']])),
                  palette: palette,
                ),
                ValuationResearchMetric(
                  label: 'Funded debt',
                  value: formatMillions(
                    firstNumber([economicBalance['fundedDebtM']]),
                  ),
                  palette: palette,
                ),
                ValuationResearchMetric(
                  label: 'Operating lease liabilities',
                  value: formatMillions(
                    firstNumber([economicBalance['operatingLeaseCurrentM']]) !=
                                null &&
                            firstNumber([
                                  economicBalance['operatingLeaseNoncurrentM'],
                                ]) !=
                                null
                        ? number(economicBalance['operatingLeaseCurrentM']) +
                              number(
                                economicBalance['operatingLeaseNoncurrentM'],
                              )
                        : null,
                  ),
                  palette: palette,
                ),
              ],
              ValuationResearchMetric(
                label: 'Shares',
                value: formatSharesMillions(
                  firstNumber([fiscal['shares_m'], scoreInputs['sharesM']]),
                  context.language,
                ),
                palette: palette,
              ),
            ],
          ),
          if (economicInput.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.ui(
                'Economic cash flow is an analyst adjustment, not reported FCF. Amounts are in the selected security currency.',
              ),
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ],
          if (economicBalance.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.ui(
                'Lease cash costs remain in operating cash flow; operating leases are not deducted again as funded debt.',
              ),
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ],
          if (guidanceRevenue != null || guidanceMargin != null) ...[
            const SizedBox(height: 12),
            Text(
              context.ui('Guidance used by model'),
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (guidanceRevenue != null)
                  InfoChip(
                    context.tr(
                      '收入指引 ${formatMillions(guidanceRevenue)}',
                      'Revenue guide ${formatMillions(guidanceRevenue)}',
                    ),
                    palette: palette,
                  ),
                if (guidanceMargin != null)
                  InfoChip(
                    context.tr(
                      '利润率指引 ${formatPercentInput(guidanceMargin)}',
                      'Margin guide ${formatPercentInput(guidanceMargin)}',
                    ),
                    palette: palette,
                  ),
                if (number(snapshot['guidanceCandidateCount']) > 0)
                  InfoChip(
                    '${formatNumber(number(snapshot['guidanceCandidateCount']))} guide signals',
                    palette: palette,
                  ),
              ],
            ),
          ],
          if (evidence.isNotEmpty) ...[
            const SizedBox(height: 12),
            ValuationEvidenceSnippet(
              evidence: evidence.first,
              palette: palette,
            ),
          ],
        ],
      ),
    );
  }
}

class ValuationOutputResearchCard extends StatelessWidget {
  const ValuationOutputResearchCard({
    super.key,
    required this.row,
    required this.fallbackMethodCards,
    required this.currency,
    required this.palette,
  });

  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> fallbackMethodCards;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final snapshot = asMap(row['dataSnapshot']);
    final semantics = asMap(snapshot['valuationSemantics']);
    final scoreInputs = asMap(semantics['scoreInputs']);
    final weights = asMap(scoreInputs['methodWeights']);
    final methods = asList(row['methodOutputs']).isNotEmpty
        ? asList(row['methodOutputs'])
        : fallbackMethodCards;
    const economicKeys = {
      'other-equity-claims',
      'vested-option-claims',
      'economic-fcfe-bridge',
    };
    final visibleMethods = [
      ...methods
          .where(
            (item) =>
                !text(item['key']).toLowerCase().contains('weight') &&
                !economicKeys.contains(text(item['key'])),
          )
          .take(5),
      ...methods.where((item) => economicKeys.contains(text(item['key']))),
    ];
    final weightNotes = methods
        .where((item) => text(item['key']).toLowerCase().contains('weight'))
        .toList();
    final price = firstNumber([row['priceAtDate'], row['currentPrice']]) ?? 0;
    final fairValue = firstNumber([row['fairValue']]) ?? 0;
    final target = firstNumber([row['targetPrice3Y']]) ?? 0;
    final upside =
        firstNumber([row['upsideDownside']]) ??
        (price > 0 && fairValue > 0 ? fairValue / price - 1 : 0);

    return ValuationResearchCard(
      palette: palette,
      icon: Icons.functions_rounded,
      kicker: 'MODEL OUTPUT',
      title: context.tr('估值输出与权重', 'Valuation Output & Weights'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridWrap(
            minTileWidth: 132,
            spacing: 8,
            children: [
              ValuationResearchMetric(
                label: 'Fair value',
                value: formatCurrencyValue(fairValue, currency),
                palette: palette,
                strong: true,
              ),
              ValuationResearchMetric(
                label: 'Price at date',
                value: formatCurrencyValue(price, currency),
                palette: palette,
              ),
              ValuationResearchMetric(
                label: 'Upside',
                value: formatReturn(upside),
                palette: palette,
                valueColor: valuationTone(upside, palette),
              ),
              ValuationResearchMetric(
                label: '3Y scenario',
                value: formatCurrencyValue(target, currency),
                palette: palette,
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final method in visibleMethods)
            ValuationMethodWeightRow(
              method: method,
              weight: firstNumber([weights[text(method['key'])]]),
              currency: currency,
              palette: palette,
            ),
          if (weightNotes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              text(weightNotes.first['description']),
              style: TextStyle(
                color: palette.faint,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
          if (text(semantics['fairValueFormula']).isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.panel.withValues(alpha: .66),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              child: Text(
                text(semantics['fairValueFormula']),
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ValuationResearchCard extends StatelessWidget {
  const ValuationResearchCard({
    super.key,
    required this.palette,
    required this.icon,
    required this.kicker,
    required this.title,
    required this.child,
    this.trailing,
  });

  final Palette palette;
  final IconData icon;
  final String kicker;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: .84),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: palette.secondary, size: 18),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.ui(kicker),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.ui(title),
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class ValuationResearchMetric extends StatelessWidget {
  const ValuationResearchMetric({
    super.key,
    required this.label,
    required this.value,
    required this.palette,
    this.valueColor,
    this.strong = false,
  });

  final String label;
  final String value;
  final Palette palette;
  final Color? valueColor;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: strong ? .92 : .62),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: strong
              ? palette.accent.withValues(alpha: .45)
              : palette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ui(label),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? palette.text,
              fontSize: strong ? 16 : 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class ValuationMethodWeightRow extends StatelessWidget {
  const ValuationMethodWeightRow({
    super.key,
    required this.method,
    required this.weight,
    required this.currency,
    required this.palette,
  });

  final Map<String, dynamic> method;
  final double? weight;
  final String currency;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final isEconomicBridge = const {
      'other-equity-claims',
      'vested-option-claims',
      'economic-fcfe-bridge',
    }.contains(text(method['key']));
    final normalizedWeight = weight == null
        ? null
        : weight!.abs() > 1
        ? weight! / 100
        : weight;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.ui(
                    text(method['label'], text(method['key'], 'Method')),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                formatValuationMethodValue(method, currency),
                style: TextStyle(
                  color: palette.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (normalizedWeight != null) ...[
                const SizedBox(width: 10),
                Text(
                  formatReturn(normalizedWeight).replaceFirst('+', ''),
                  style: TextStyle(
                    color: palette.secondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          if (isEconomicBridge)
            Text(
              context.ui(text(method['description'])),
              style: TextStyle(color: palette.secondary, fontSize: 11),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: normalizedWeight == null
                    ? .08
                    : normalizedWeight.clamp(0, 1).toDouble(),
                minHeight: 5,
                backgroundColor: palette.border,
                color: normalizedWeight == null
                    ? palette.faint
                    : palette.accent,
              ),
            ),
        ],
      ),
    );
  }
}

class ValuationEvidenceSnippet extends StatelessWidget {
  const ValuationEvidenceSnippet({
    super.key,
    required this.evidence,
    required this.palette,
  });

  final Map<String, dynamic> evidence;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final metric = text(evidence['metricName'], 'transcript');
    final date = formatDate(text(evidence['observedAt']));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.accent.withValues(alpha: .24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('$metric 证据 · $date', '$metric evidence · $date'),
            style: TextStyle(
              color: palette.accent,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            text(evidence['excerpt']),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class ValuationPodcastInsightsSection extends StatefulWidget {
  const ValuationPodcastInsightsSection({
    super.key,
    required this.ticker,
    required this.insights,
    required this.palette,
  });

  final String ticker;
  final List<Map<String, dynamic>> insights;
  final Palette palette;

  @override
  State<ValuationPodcastInsightsSection> createState() =>
      _ValuationPodcastInsightsSectionState();
}

class _ValuationPodcastInsightsSectionState
    extends State<ValuationPodcastInsightsSection> {
  int _expandedIndex = 0;

  @override
  void didUpdateWidget(covariant ValuationPodcastInsightsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticker != widget.ticker) _expandedIndex = 0;
  }

  @override
  Widget build(BuildContext context) {
    final insights = widget.insights.take(8).toList();
    final channels = <String>{
      for (final item in insights)
        if (text(item['channel']).isNotEmpty) text(item['channel']),
    };
    final latestDate = insights
        .map((item) => text(item['observedAt']))
        .where((value) => value.isNotEmpty)
        .fold<String>(
          '',
          (latest, value) => value.compareTo(latest) > 0 ? value : latest,
        );

    return ValuationResearchCard(
      palette: widget.palette,
      icon: Icons.podcasts_rounded,
      kicker: 'PODCAST RADAR',
      title: context.tr('频道前瞻看点', 'Podcast Forward Views'),
      trailing: insights.isEmpty
          ? null
          : InfoChip('${insights.length} notes', palette: widget.palette),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InfoChip('${channels.length} channels', palette: widget.palette),
              if (latestDate.isNotEmpty)
                InfoChip(
                  'latest ${formatDate(latestDate)}',
                  palette: widget.palette,
                ),
              InfoChip('not an FV input', palette: widget.palette),
            ],
          ),
          const SizedBox(height: 12),
          if (insights.isEmpty)
            EmptyState(
              text: context.tr(
                '还没有为 ${widget.ticker} 生成 podcast 前瞻看点。',
                'No podcast forward views have been generated for ${widget.ticker} yet.',
              ),
              palette: widget.palette,
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 720;
                return Column(
                  children: [
                    for (var index = 0; index < insights.length; index += 1)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: index == insights.length - 1 ? 0 : 8,
                        ),
                        child: ValuationPodcastInsightCard(
                          insight: insights[index],
                          index: index,
                          compact: compact,
                          expanded: _expandedIndex == index,
                          palette: widget.palette,
                          onTap: () {
                            setState(() {
                              _expandedIndex = _expandedIndex == index
                                  ? -1
                                  : index;
                            });
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class ValuationPodcastInsightCard extends StatelessWidget {
  const ValuationPodcastInsightCard({
    super.key,
    required this.insight,
    required this.index,
    required this.compact,
    required this.expanded,
    required this.palette,
    required this.onTap,
  });

  final Map<String, dynamic> insight;
  final int index;
  final bool compact;
  final bool expanded;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stance = text(insight['stance'], 'mixed');
    final tone = stanceTone(stance, palette);
    final confidence = number(insight['confidence']).clamp(0, 1).toDouble();
    final summary = context.isChinese
        ? text(
            insight['summaryZh'],
            text(insight['summary'], 'No summary available.'),
          )
        : text(insight['summary'], 'No summary available.');
    final theme = text(insight['theme'], 'Forward-looking debate');
    final channel = text(insight['channel'], 'Podcast');
    final speaker = text(insight['speaker'], channel);
    final observedAt = formatDate(text(insight['observedAt']));
    final videoTitle = text(insight['videoTitle']);
    final excerpt = text(insight['evidenceExcerpt']);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: expanded
              ? palette.accent.withValues(alpha: .08)
              : palette.card.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: expanded
                ? palette.accent.withValues(alpha: .46)
                : palette.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BadgeLabel(
                  text: stanceLabel(stance, context.language),
                  color: tone,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    theme,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: palette.muted,
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              context.tr('谁说：$speaker', 'Said by: $speaker'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.secondary,
                fontSize: 12,
                height: 1.25,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              summary,
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text,
                fontSize: 13,
                height: 1.42,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PodcastSourceLine(
                        speaker: speaker,
                        channel: channel,
                        observedAt: observedAt,
                        title: videoTitle,
                        palette: palette,
                      ),
                      const SizedBox(height: 8),
                      _PodcastConfidenceBar(
                        confidence: confidence,
                        color: tone,
                        palette: palette,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: _PodcastSourceLine(
                          channel: channel,
                          speaker: speaker,
                          observedAt: observedAt,
                          title: videoTitle,
                          palette: palette,
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 180,
                        child: _PodcastConfidenceBar(
                          confidence: confidence,
                          color: tone,
                          palette: palette,
                        ),
                      ),
                    ],
                  ),
            if (expanded && excerpt.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: palette.panel.withValues(alpha: .70),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('原文证据', 'Source Evidence'),
                      style: TextStyle(
                        color: palette.secondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      excerpt,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12,
                        height: 1.38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PodcastSourceLine extends StatelessWidget {
  const _PodcastSourceLine({
    required this.speaker,
    required this.channel,
    required this.observedAt,
    required this.title,
    required this.palette,
  });

  final String speaker;
  final String channel;
  final String observedAt;
  final String title;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (speaker.isNotEmpty && speaker != channel) speaker,
      channel,
      if (observedAt.isNotEmpty) observedAt,
      if (title.isNotEmpty) title,
    ].join(' · ');
    return Text(
      subtitle,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.faint,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        height: 1.3,
      ),
    );
  }
}

class _PodcastConfidenceBar extends StatelessWidget {
  const _PodcastConfidenceBar({
    required this.confidence,
    required this.color,
    required this.palette,
  });

  final double confidence;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: confidence <= 0 ? .08 : confidence,
                  minHeight: 6,
                  backgroundColor: palette.border,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(confidence * 100).round()}%',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          context.ui('evidence strength'),
          style: TextStyle(
            color: palette.faint,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

Color stanceTone(String stance, Palette palette) {
  final normalized = stance.toLowerCase();
  if (normalized.contains('risk') || normalized.contains('negative')) {
    return palette.negative;
  }
  if (normalized.contains('positive') || normalized.contains('bull')) {
    return palette.accent;
  }
  return palette.secondary;
}

String stanceLabel(String stance, [AppLanguage language = AppLanguage.en]) {
  final normalized = stance.toLowerCase();
  if (normalized.contains('risk') || normalized.contains('negative')) {
    return trFor(language, '风险', 'Risk');
  }
  if (normalized.contains('positive') || normalized.contains('bull')) {
    return trFor(language, '正面', 'Positive');
  }
  return trFor(language, '混合', 'Mixed');
}

class ValuationQuarterQaList extends StatefulWidget {
  const ValuationQuarterQaList({
    super.key,
    required this.api,
    required this.row,
    required this.previous,
    required this.currency,
    required this.palette,
    required this.expandedIndex,
    required this.onToggle,
  });

  final ApiClient api;
  final Map<String, dynamic> row;
  final Map<String, dynamic>? previous;
  final String currency;
  final Palette palette;
  final int? expandedIndex;
  final ValueChanged<int> onToggle;

  @override
  State<ValuationQuarterQaList> createState() => _ValuationQuarterQaListState();
}

class _ValuationQuarterQaListState extends State<ValuationQuarterQaList> {
  @override
  Widget build(BuildContext context) {
    final showChinese = context.isChinese;
    final items = valuationQaItems(
      widget.row,
      widget.previous,
      widget.currency,
    );
    return ValuationResearchCard(
      palette: widget.palette,
      icon: Icons.question_answer_rounded,
      kicker: 'CALL TRANSCRIPT Q&A',
      title: context.tr('电话会 Q&A', 'Call Transcript Q&A'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (items.isEmpty)
            EmptyState(
              text: valuationQaEmptyText(widget.row, showChinese),
              palette: widget.palette,
            )
          else ...[
            for (var index = 0; index < items.length; index += 1)
              ValuationQaAccordionItem(
                index: index,
                question: items[index].questionFor(showChinese),
                answer: items[index].answerFor(showChinese),
                metadata: showChinese
                    ? items[index].metadataZh
                    : items[index].metadata,
                answerLabel: context.tr('管理层回答', 'Management answer'),
                expanded: widget.expandedIndex == index,
                translating: false,
                isLast: index == items.length - 1,
                palette: widget.palette,
                onTap: () => widget.onToggle(index),
              ),
          ],
        ],
      ),
    );
  }
}

class ValuationQaAccordionItem extends StatelessWidget {
  const ValuationQaAccordionItem({
    super.key,
    required this.index,
    required this.question,
    required this.answer,
    required this.metadata,
    required this.answerLabel,
    required this.expanded,
    required this.translating,
    required this.isLast,
    required this.palette,
    required this.onTap,
  });

  final int index;
  final String question;
  final String answer;
  final String metadata;
  final String answerLabel;
  final bool expanded;
  final bool translating;
  final bool isLast;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 0 : 8),
      decoration: BoxDecoration(
        color: palette.card.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: expanded ? palette.accent : palette.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BadgeLabel(text: 'Q${index + 1}', color: palette.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      question,
                      maxLines: expanded ? null : 1,
                      overflow: expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        height: 1.34,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (translating) ...[
                    const SizedBox(width: 8),
                    Text(
                      context.tr('翻译中', 'Translating'),
                      style: TextStyle(
                        color: palette.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: palette.muted,
                  ),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (metadata.isNotEmpty) ...[
                        Text(
                          metadata,
                          style: TextStyle(
                            color: palette.faint,
                            height: 1.35,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        answerLabel,
                        style: TextStyle(
                          color: palette.secondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        answer,
                        style: TextStyle(
                          color: palette.muted,
                          height: 1.48,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                crossFadeState: expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 160),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ValuationQaDatum {
  const ValuationQaDatum({
    required this.question,
    required this.answer,
    required this.questionZh,
    required this.answerZh,
    required this.metadata,
    required this.metadataZh,
  });

  final String question;
  final String answer;
  final String questionZh;
  final String answerZh;
  final String metadata;
  final String metadataZh;

  String questionFor(bool showChinese) =>
      showChinese && questionZh.isNotEmpty ? questionZh : question;

  String answerFor(bool showChinese) =>
      showChinese && answerZh.isNotEmpty ? answerZh : answer;
}

class ValuationQualityChip extends StatelessWidget {
  const ValuationQualityChip({
    super.key,
    required this.label,
    required this.palette,
    this.strong = false,
  });

  final String label;
  final Palette palette;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final normalized = label.toLowerCase();
    final color =
        strong ||
            normalized.contains('pass') ||
            normalized.contains('quarterly')
        ? palette.positive
        : normalized.contains('watch') || normalized.contains('partial')
        ? palette.secondary
        : palette.faint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        context.ui(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class ValuationDistribution extends StatelessWidget {
  const ValuationDistribution({
    super.key,
    required this.rows,
    required this.best,
    required this.worst,
    required this.palette,
  });

  final List<ValuationRow> rows;
  final ValuationRow? best;
  final ValuationRow? worst;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final deepValue = rows.where((row) => row.upside >= .25).length;
    final fair = rows
        .where((row) => row.upside > -.10 && row.upside < .25)
        .length;
    final expensive = rows.where((row) => row.upside <= -.10).length;
    final total = math.max(1, rows.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PanelTitle(
          icon: Icons.donut_large_rounded,
          kicker: 'DISTRIBUTION',
          title: 'Where the model sees value',
          palette: palette,
        ),
        const SizedBox(height: 14),
        ValuationBucketRow(
          label: 'Deep value',
          count: deepValue,
          total: total,
          color: palette.positive,
          palette: palette,
        ),
        ValuationBucketRow(
          label: 'Fair range',
          count: fair,
          total: total,
          color: palette.secondary,
          palette: palette,
        ),
        ValuationBucketRow(
          label: 'Expensive',
          count: expensive,
          total: total,
          color: palette.negative,
          palette: palette,
        ),
        const SizedBox(height: 10),
        if (best != null)
          Text(
            context.ui(
              'Top discount: ${best!.ticker} at ${formatReturn(best!.upside)}.',
            ),
            style: TextStyle(color: palette.muted, height: 1.35),
          ),
        if (worst != null)
          Text(
            context.ui(
              'Most stretched: ${worst!.ticker} at ${formatReturn(worst!.upside)}.',
            ),
            style: TextStyle(color: palette.muted, height: 1.35),
          ),
      ],
    );
  }
}

class ValuationBucketRow extends StatelessWidget {
  const ValuationBucketRow({
    super.key,
    required this.label,
    required this.count,
    required this.total,
    required this.color,
    required this.palette,
  });

  final String label;
  final int count;
  final int total;
  final Color color;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              context.ui(label),
              style: TextStyle(
                color: palette.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: count / total,
                minHeight: 9,
                backgroundColor: palette.border,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 46,
            child: Text(
              '$count',
              textAlign: TextAlign.end,
              style: TextStyle(
                color: palette.text,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ValuationSourceNote extends StatelessWidget {
  const ValuationSourceNote({
    super.key,
    required this.source,
    required this.summary,
    required this.palette,
  });

  final Map<String, dynamic> source;
  final Map<String, dynamic> summary;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PanelTitle(
          icon: Icons.rule_rounded,
          kicker: 'MODEL CONTROL',
          title: 'Price excluded from fair value',
          palette: palette,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            InfoChip(
              context.ui(
                text(source['upstreamLabel'], 'SEC + transcript model'),
              ),
              palette: palette,
            ),
            InfoChip(
              '${formatNumber(number(summary['modelInputAuditPassCount']))} input audits pass',
              palette: palette,
            ),
            InfoChip(
              '${formatNumber(number(summary['externalConsensusTickerCount']))} consensus checks',
              palette: palette,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          text(
            source['modelInputPolicy'],
            'Fair value uses reported financials, normalized earnings/FCF assumptions, and transcript evidence. Market price is comparison only.',
          ),
          style: TextStyle(color: palette.muted, height: 1.35),
        ),
      ],
    );
  }
}

class ApiRequestException implements Exception {
  const ApiRequestException({
    required this.statusCode,
    required this.message,
    this.code = '',
  });
  final int statusCode;
  final String code;
  final String message;

  factory ApiRequestException.fromResponse(http.Response response) {
    var message = response.body;
    var code = '';
    try {
      final payload = jsonDecode(response.body);
      if (payload is Map) {
        code = text(payload['error']);
        message = text(payload['message'], code);
      }
    } catch (_) {}
    return ApiRequestException(
      statusCode: response.statusCode,
      code: code,
      message: message.isEmpty ? 'API ${response.statusCode}' : message,
    );
  }

  @override
  String toString() => 'Exception: $message';
}

class ApiClient {
  ApiClient(
    this._accessTokenProvider, {
    this.sessionUserId = '',
    this.isSessionActive,
  });

  static const Duration _requestTimeout = Duration(seconds: 95);
  static const Duration _retryDelay = Duration(milliseconds: 450);

  final String Function() _accessTokenProvider;
  final String sessionUserId;
  final bool Function()? isSessionActive;

  String get accessToken {
    if (isSessionActive?.call() == false) {
      throw StateError('This account session is no longer active.');
    }
    if (_authConfigured && _supabaseReady) {
      final session = Supabase.instance.client.auth.currentSession;
      if (sessionUserId.isNotEmpty && session?.user.id != sessionUserId) {
        throw StateError('This account session is no longer active.');
      }
      final token = session?.accessToken;
      if (token != null && token.isNotEmpty) return token;
    }
    return _accessTokenProvider();
  }

  Map<String, String> _headersFor(String token) => {
    'authorization': 'Bearer $token',
    'content-type': 'application/json',
  };

  Future<http.Response> _sendWithAuthRetry(
    Future<http.Response> Function(String token) send, {
    bool retryTransient = false,
  }) async {
    var response = await _sendOnce(send, retryTransient: retryTransient);
    if (response.statusCode == 401 && await _refreshSession()) {
      response = await _sendOnce(send, retryTransient: retryTransient);
    }
    if (retryTransient && _isTransientStatus(response.statusCode)) {
      await Future<void>.delayed(_retryDelay);
      response = await _sendOnce(send, retryTransient: false);
    }
    return response;
  }

  Future<http.Response> _sendOnce(
    Future<http.Response> Function(String token) send, {
    required bool retryTransient,
  }) async {
    try {
      return await send(accessToken).timeout(_requestTimeout);
    } on TimeoutException {
      throw Exception(
        'API request timed out after ${_requestTimeout.inSeconds}s. Please retry.',
      );
    } on http.ClientException {
      if (!retryTransient) rethrow;
      await Future<void>.delayed(_retryDelay);
      return send(accessToken).timeout(_requestTimeout);
    }
  }

  bool _isTransientStatus(int statusCode) =>
      statusCode == 502 || statusCode == 503 || statusCode == 504;

  Future<bool> _refreshSession() async {
    if (!_authConfigured || !_supabaseReady) return false;
    if (isSessionActive?.call() == false) return false;
    if (sessionUserId.isNotEmpty &&
        Supabase.instance.client.auth.currentSession?.user.id !=
            sessionUserId) {
      return false;
    }
    try {
      final response = await Supabase.instance.client.auth.refreshSession();
      return response.session?.accessToken.isNotEmpty == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final uri = apiUri(path);
    final response = await _sendWithAuthRetry(
      (token) => http.get(uri, headers: {'authorization': 'Bearer $token'}),
      retryTransient: true,
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _sendWithAuthRetry(
      (token) => http.post(
        apiUri(path),
        headers: _headersFor(token),
        body: jsonEncode(body),
      ),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> deleteJson(String path) async {
    final response = await _sendWithAuthRetry(
      (token) => http.delete(apiUri(path), headers: _headersFor(token)),
    );
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiRequestException.fromResponse(response);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      final source = response.request?.url.toString() ?? 'unknown API URL';
      final contentType = response.headers['content-type'] ?? 'unknown type';
      throw Exception('API returned non-JSON from $source ($contentType)');
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
    throw Exception('API returned a non-object payload');
  }
}

Uri apiUri(String path) {
  final base = apiBaseUrl();
  final normalized = path.startsWith('/') ? path : '/$path';
  if (base.isNotEmpty) {
    return Uri.parse('$base$normalized');
  }
  return Uri.base.resolve(normalized);
}

String apiBaseUrl() {
  final configured = _apiBaseUrl.trim();
  if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/+$'), '');
  final host = Uri.base.host;
  if (host == 'localhost' || host == '127.0.0.1' || host.isEmpty) {
    return 'http://127.0.0.1:8787';
  }
  return '';
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    required this.palette,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final Palette palette;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: panelDecoration(palette),
      child: child,
    );
  }
}

BoxDecoration panelDecoration(Palette palette) {
  return BoxDecoration(
    color: palette.panel,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: palette.border),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: .16),
        blurRadius: 24,
        offset: const Offset(0, 16),
      ),
    ],
  );
}

class PanelTitle extends StatelessWidget {
  const PanelTitle({
    super.key,
    required this.icon,
    required this.kicker,
    required this.title,
    required this.palette,
    this.trailing,
  });

  final IconData icon;
  final String kicker;
  final String title;
  final Palette palette;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: palette.accent, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.ui(kicker),
                style: TextStyle(
                  color: palette.muted,
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                context.ui(title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class MiniMetric extends StatelessWidget {
  const MiniMetric(
    this.label,
    this.value,
    this.icon,
    this.palette, {
    super.key,
  });

  final String label;
  final String value;
  final IconData icon;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: palette.secondary, size: 17),
          const SizedBox(height: 10),
          Text(
            context.ui(label),
            style: TextStyle(
              color: palette.muted,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class BadgeLabel extends StatelessWidget {
  const BadgeLabel({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(
        context.ui(text),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: .4,
        ),
      ),
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip(this.label, {super.key, required this.palette});

  final String label;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border),
      ),
      child: Text(
        context.ui(label),
        style: TextStyle(
          color: palette.muted,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, required this.palette});

  final String status;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final normalized = status.trim().toLowerCase();
    final color = switch (normalized) {
      'live' || 'profile' => palette.positive,
      'sample' => palette.secondary,
      'cached' => palette.muted,
      'stale' => const Color(0xFFE0B15A),
      _ => palette.negative,
    };
    final label = context.ui(normalized.isEmpty ? 'cached' : normalized);
    return Semantics(
      label: context.tr('数据状态：$label', 'Data status: $label'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text, required this.palette});

  final String text;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Text(context.ui(text), style: TextStyle(color: palette.muted)),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = Palette(false);
    return Panel(
      palette: palette,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, color: palette.negative, size: 34),
          const SizedBox(height: 12),
          Text(context.ui(message), style: TextStyle(color: palette.text)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: Text(context.ui('Retry'))),
        ],
      ),
    );
  }
}

class GridWrap extends StatelessWidget {
  const GridWrap({
    super.key,
    required this.children,
    this.minTileWidth = 180,
    this.spacing = 12,
  });

  final List<Widget> children;
  final double minTileWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = math.max(1, (width / minTileWidth).floor());
        final itemWidth = (width - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

class Palette {
  Palette(this.colorBlind);

  final bool colorBlind;

  Color get background => const Color(0xFF0B111D);
  Color get panel => const Color(0xFF111827);
  Color get card => const Color(0xFF172033);
  Color get text => const Color(0xFFF7FAFC);
  Color get muted => const Color(0xFFAAB5C4);
  Color get faint => const Color(0xFF708093);
  Color get border => const Color(0xFF273244);
  Color get accent =>
      colorBlind ? const Color(0xFF58A6FF) : const Color(0xFF22D3A6);
  Color get secondary => const Color(0xFFE0B15A);
  Color get positive =>
      colorBlind ? const Color(0xFF4EA1F3) : const Color(0xFF18A878);
  Color get negative =>
      colorBlind ? const Color(0xFFFFB454) : const Color(0xFFE15A5A);
}

class ExecutiveStats {
  const ExecutiveStats({
    required this.count,
    required this.aum,
    required this.netSignals,
    required this.latestQuarter,
  });

  final int count;
  final double aum;
  final int netSignals;
  final String latestQuarter;
}

class SignalItem {
  const SignalItem({
    required this.guruId,
    required this.guruName,
    required this.type,
    required this.ticker,
    required this.actionLabel,
    required this.date,
    required this.value,
    required this.detail,
    required this.tone,
  });

  final String guruId;
  final String guruName;
  final String type;
  final String ticker;
  final String actionLabel;
  final String date;
  final double value;
  final String detail;
  final String tone;
}

class ExposureItem {
  const ExposureItem({
    required this.ticker,
    required this.value,
    required this.guruNames,
    required this.positions,
  });

  final String ticker;
  final double value;
  final Set<String> guruNames;
  final List<MarketLensManagerPosition> positions;

  int get guruCount => guruNames.length;
  double get medianWeight =>
      medianValue([for (final position in positions) position.currentWeight]);
  double get maxWeight => positions.fold<double>(
    0,
    (maximum, position) => math.max(maximum, position.currentWeight),
  );
  bool get hasNonPublicPosition =>
      positions.any((position) => !position.isPubliclyTradable);
}

class MarketLensManagerPosition {
  const MarketLensManagerPosition({
    required this.guruId,
    required this.guruName,
    required this.ticker,
    required this.issuer,
    this.guruAvatarUrl = '',
    required this.action,
    required this.reportDate,
    required this.filingDate,
    required this.currentValue,
    required this.previousValue,
    required this.currentWeight,
    required this.previousWeight,
    required this.changeShares,
    this.hasTradeEvidence = false,
    this.publicTradingStatus = 'public',
    this.publicReplicable = true,
    this.publicTradingReasonEn = '',
    this.publicTradingReasonZh = '',
  });

  final String guruId;
  final String guruName;
  final String ticker;
  final String issuer;
  final String guruAvatarUrl;
  final String action;
  final String reportDate;
  final String filingDate;
  final double currentValue;
  final double previousValue;
  final double currentWeight;
  final double previousWeight;
  final double changeShares;
  final bool hasTradeEvidence;
  final String publicTradingStatus;
  final bool publicReplicable;
  final String publicTradingReasonEn;
  final String publicTradingReasonZh;

  double get valueChange => currentValue - previousValue;
  double get weightChange => currentWeight - previousWeight;
  bool get isPubliclyTradable =>
      publicReplicable && !publicTradingStatus.startsWith('private');

  String publicTradingReason(AppLanguage language) => language == AppLanguage.zh
      ? text(publicTradingReasonZh, publicTradingReasonEn)
      : text(publicTradingReasonEn, publicTradingReasonZh);
}

class GuruFilingItem {
  const GuruFilingItem({
    required this.guruId,
    required this.guruName,
    required this.quarter,
    required this.reportDate,
    required this.filingDate,
    required this.value,
  });

  final String guruId;
  final String guruName;
  final String quarter;
  final String reportDate;
  final String filingDate;
  final double value;
}

class GuruActivityRankItem {
  const GuruActivityRankItem({
    required this.ticker,
    required this.actions,
    required this.guruNames,
    required this.reportDate,
    required this.amount,
    required this.positions,
    this.amountReliable = true,
  });

  final String ticker;
  final Map<String, int> actions;
  final Set<String> guruNames;
  final String reportDate;
  final double amount;
  final List<MarketLensManagerPosition> positions;
  final bool amountReliable;

  int get guruCount => guruNames.length;
  int get newCount => actions['new'] ?? 0;
  int get increasedCount => actions['increased'] ?? 0;
  int get reducedCount => actions['reduced'] ?? 0;
  int get soldOutCount => actions['sold_out'] ?? 0;
  double get medianCurrentWeight =>
      medianValue([for (final position in positions) position.currentWeight]);

  String get primaryAction {
    if (actions.isEmpty) return '';
    final entries = actions.entries.toList()
      ..sort((a, b) {
        final countCompare = b.value.compareTo(a.value);
        return countCompare != 0 ? countCompare : a.key.compareTo(b.key);
      });
    return entries.first.key;
  }
}

class StatCardData {
  const StatCardData(this.label, this.value, this.sub, this.icon);

  final String label;
  final String value;
  final String sub;
  final IconData icon;
}

class ValuationRow {
  const ValuationRow({
    required this.ticker,
    required this.name,
    required this.sector,
    required this.currency,
    required this.latestPrice,
    required this.fairValue,
    required this.upside,
    required this.targetPrice3Y,
    required this.expectedReturn3Y,
    required this.latestPriceDate,
    required this.coverageKind,
    required this.lineageStatus,
    required this.releaseStatus,
    required this.economicValidationStatus,
    required this.marketCalibrationStatus,
    required this.consensusStatus,
    required this.consensusUpside,
  });

  static ValuationRow empty() => const ValuationRow(
    ticker: '',
    name: 'Company',
    sector: 'Unclassified',
    currency: 'USD',
    latestPrice: 0,
    fairValue: 0,
    upside: 0,
    targetPrice3Y: 0,
    expectedReturn3Y: 0,
    latestPriceDate: '',
    coverageKind: '',
    lineageStatus: '',
    releaseStatus: '',
    economicValidationStatus: 'not_validated',
    marketCalibrationStatus: 'not_run',
    consensusStatus: '',
    consensusUpside: null,
  );

  final String ticker;
  final String name;
  final String sector;
  final String currency;
  final double latestPrice;
  final double fairValue;
  final double upside;
  final double targetPrice3Y;
  final double expectedReturn3Y;
  final String latestPriceDate;
  final String coverageKind;
  final String lineageStatus;
  final String releaseStatus;
  final String economicValidationStatus;
  final String marketCalibrationStatus;
  final String consensusStatus;
  final double? consensusUpside;

  bool get hasModel => latestPrice > 0 && fairValue > 0;

  String valuationVerdict(BuildContext context) {
    if (!hasModel) return context.tr('无估值', 'No FV');
    if (upside >= .25) return context.tr('深度折价', 'Deep value');
    if (upside >= .05) return context.tr('偏便宜', 'Undervalued');
    if (upside <= -.10) return context.tr('偏贵', 'Expensive');
    return context.tr('接近公允', 'Near fair');
  }

  String get coverageLabel {
    if (coverageKind.isEmpty) return 'model';
    return coverageKind.length <= 9
        ? coverageKind
        : coverageKind.substring(0, 9);
  }

  String get auditStatus => lineageStatus;

  String get auditLabel => lineageStatus.isEmpty ? 'not_run' : lineageStatus;

  String consensusTextFor(BuildContext context) {
    if (consensusUpside == null) {
      return context.ui(
        consensusStatus.isEmpty ? 'no consensus guardrail' : consensusStatus,
      );
    }
    final status = context.ui(
      consensusStatus.isEmpty ? 'consensus' : consensusStatus,
    );
    return context.tr(
      '$status · 市场 ${formatReturn(consensusUpside!)}',
      '$status · street ${formatReturn(consensusUpside!)}',
    );
  }
}

double reported13fTableValue(Map<String, dynamic> guru) {
  final summary = asMap(guru['summary']);
  return firstNumber([
        summary['reported13fValue'],
        summary['reportedTableValue'],
        summary['totalValue'],
      ]) ??
      0;
}

double reported13fOptionsValue(Map<String, dynamic> guru) {
  final summary = asMap(guru['summary']);
  final explicit = firstNumber([
    summary['reported13fOptionsValue'],
    summary['reportedOptionsValue'],
    summary['optionsValue'],
    summary['optionValue'],
  ]);
  if (explicit != null) return explicit;
  return asList(guru['holdings'])
      .where((holding) => text(holding['putCall']).isNotEmpty)
      .fold<double>(0, (sum, holding) => sum + number(holding['value']));
}

double reported13fCommonLongValue(Map<String, dynamic> guru) {
  final summary = asMap(guru['summary']);
  final explicit = firstNumber([
    summary['reported13fCommonLongValue'],
    summary['reportedCommonLongValue'],
    summary['commonLongValue'],
  ]);
  if (explicit != null) return explicit;
  return math.max(
    0,
    reported13fTableValue(guru) - reported13fOptionsValue(guru),
  );
}

String guruDisplayStatus(Map<String, dynamic> guru) {
  final persistedStatus = text(
    asMap(guru['dataStatus'])['status'],
  ).toLowerCase();
  if (persistedStatus == 'local-db') return 'cached';
  if (persistedStatus.isNotEmpty) return persistedStatus;
  return text(guru['status'], 'cached').toLowerCase();
}

ExecutiveStats buildExecutiveStats(
  List<Map<String, dynamic>> gurus,
  List<SignalItem> signals,
) {
  final aum = gurus
      .where((guru) => text(guru['type']) == 'manager13f')
      .fold<double>(0, (sum, guru) => sum + reported13fTableValue(guru));
  final buys = signals.where((item) => item.tone == 'positive').length;
  final sells = signals.where((item) => item.tone == 'negative').length;
  final quarters =
      gurus
          .map((guru) => text(asMap(guru['summary'])['reportDate']))
          .where((value) => value.isNotEmpty)
          .toList()
        ..sort();
  return ExecutiveStats(
    count: gurus.length,
    aum: aum,
    netSignals: buys - sells,
    latestQuarter: quarters.isEmpty ? '-' : formatDate(quarters.last),
  );
}

List<Map<String, dynamic>> filterGurus(
  List<Map<String, dynamic>> gurus,
  String search,
  String filter,
) {
  final needle = search.trim().toLowerCase();
  return gurus.where((guru) {
    final type = text(guru['type']);
    if (filter != 'all' && type != filter) return false;
    if (needle.isEmpty) return true;
    final haystack = [
      guru['name'],
      guru['chineseName'],
      guru['entityName'],
      guru['thesisTag'],
      asMap(guru['summary'])['latestTicker'],
    ].map(text).join(' ').toLowerCase();
    return haystack.contains(needle);
  }).toList();
}

String? cleanRouteValue(String? value) {
  final cleaned = value?.trim() ?? '';
  return cleaned.isEmpty ? null : cleaned;
}

({String guruId, String ticker, String search, String filter})?
guruTradeNavigationTarget(String guruId, String ticker) {
  final normalizedGuruId = guruId.trim();
  final normalizedTicker = ticker.trim().toUpperCase();
  if (normalizedGuruId.isEmpty || normalizedTicker.isEmpty) return null;
  return (
    guruId: normalizedGuruId,
    ticker: normalizedTicker,
    search: '',
    filter: 'all',
  );
}

String shortText(String value, [int length = 10]) {
  final cleaned = value.trim();
  if (cleaned.length <= length) return cleaned;
  return cleaned.substring(0, length);
}

String normalizeRouteMode(String? value, {String? path}) {
  final mode = value?.trim().toLowerCase() ?? '';
  // Production uses Discover. Legacy-flag builds remain on a supported page,
  // never issue retired API requests or treat Discover as a valuation module.
  if (isRetiredModuleRoute(mode, path: path)) {
    return investmentWorkflowEnabled ? 'discover' : 'guru';
  }
  if (investmentWorkflowEnabled) {
    if (mode == 'portfolio') return 'book';
    if (mode == 'guru') return 'discover';
  }
  if (isInvestmentMode(mode)) return mode;
  return const {'guru', 'valuation', 'portfolio', 'admin'}.contains(mode)
      ? mode
      : investmentWorkflowEnabled
      ? 'home'
      : 'guru';
}

bool shouldLoadGuruDashboard(String mode, Map<String, dynamic>? guruPayload) =>
    mode == 'guru' && guruPayload == null;

String valuationTickerDetailPath(String ticker, {bool fullResearch = false}) {
  final normalizedTicker = ticker.trim().toUpperCase();
  final encodedTicker = Uri.encodeComponent(normalizedTicker);
  final pricePoints = fullResearch ? 900 : 300;
  final detail = fullResearch ? 'full' : 'summary';
  return '/api/valuation/$encodedTicker?pricePoints=$pricePoints&detail=$detail';
}

int guruModuleIndex(String? value) {
  final module = value?.trim().toLowerCase() ?? '';
  return switch (module) {
    '1' || 'trade' || 'trades' || 'new' || 'new-exit' => 1,
    '2' || 'quarter' || 'quarters' || 'contribution' => 2,
    '3' || 'position' || 'positions' || 'exposure' || 'history' => 3,
    _ => 0,
  };
}

String guruModuleRouteName(int value) {
  return switch (value) {
    1 => 'trades',
    2 => 'contribution',
    3 => 'positions',
    _ => 'simulation',
  };
}

String? defaultGuruId(List<Map<String, dynamic>> gurus) {
  if (gurus.isEmpty) return null;
  final bill = gurus.firstWhere(
    (guru) => text(guru['id']) == 'bill-ackman',
    orElse: () => const <String, dynamic>{},
  );
  if (bill.isNotEmpty) return text(bill['id']);
  final manager = gurus.firstWhere(
    (guru) => text(guru['type']) == 'manager13f',
    orElse: () => const <String, dynamic>{},
  );
  if (manager.isNotEmpty) return text(manager['id']);
  return text(gurus.first['id']);
}

List<SignalItem> buildSignals(
  List<Map<String, dynamic>> gurus, [
  AppLanguage language = AppLanguage.en,
]) {
  final signals = <SignalItem>[];
  for (final guru in gurus) {
    final type = text(guru['type']);
    final guruName = guruDisplayName(guru, language);
    final guruId = text(guru['id']);
    final summary = asMap(guru['summary']);
    if (type == 'manager13f') {
      for (final item in asList(guru['activity']).take(14)) {
        final action = text(item['action']);
        final positive = action == 'new' || action == 'increased';
        final negative = action == 'reduced' || action == 'sold_out';
        signals.add(
          SignalItem(
            guruId: guruId,
            guruName: guruName,
            type: disclosureLabel(type),
            ticker: text(item['ticker'], compactName(text(item['issuer']))),
            actionLabel: action,
            date: text(summary['reportDate']),
            value: number(item['value']) + number(item['previousValue']),
            detail:
                '${formatNumber(number(item['changeShares']).abs())} shares',
            tone: positive
                ? 'positive'
                : negative
                ? 'negative'
                : 'neutral',
          ),
        );
      }
    } else {
      for (final tx in asList(guru['transactions']).take(18)) {
        final action = text(tx['action']);
        final positive = action == 'buy';
        final negative = action == 'sell';
        signals.add(
          SignalItem(
            guruId: guruId,
            guruName: guruName,
            type: disclosureLabel(type),
            ticker: text(tx['ticker'], compactName(text(tx['issuer']))),
            actionLabel: action,
            date: text(tx['transactionDate'], text(tx['filingDate'])),
            value: number(tx['value']) + number(tx['notional']),
            detail: text(
              tx['amountRange'],
              '${formatNumber(number(tx['shares']))} shares',
            ),
            tone: positive
                ? 'positive'
                : negative
                ? 'negative'
                : 'neutral',
          ),
        );
      }
    }
  }
  signals.sort((a, b) => b.date.compareTo(a.date));
  return signals;
}

bool isQuarterLensGuru(Map<String, dynamic> guru) =>
    text(guru['type']) == 'manager13f' && !truthy(guru['excludeFromHeatmap']);

String defaultGuruDisclosureQuarter(List<Map<String, dynamic>> gurus) {
  final coverage = <String, _QuarterCoverage>{};
  for (final guru in gurus.where(isQuarterLensGuru)) {
    final reportDate = text(asMap(guru['summary'])['reportDate']);
    final quarter = reportQuarterLabel(reportDate);
    if (quarter == '-') continue;
    final current = coverage.putIfAbsent(
      quarter,
      () => _QuarterCoverage(quarter),
    );
    current.managerCount += 1;
    if (reportDate.compareTo(current.latestReportDate) > 0) {
      current.latestReportDate = reportDate;
    }
  }
  if (coverage.isEmpty) return '-';
  final rows = coverage.values.toList()
    ..sort((left, right) {
      final countCompare = right.managerCount.compareTo(left.managerCount);
      if (countCompare != 0) return countCompare;
      final dateCompare = right.latestReportDate.compareTo(
        left.latestReportDate,
      );
      return dateCompare != 0
          ? dateCompare
          : right.quarter.compareTo(left.quarter);
    });
  return rows.first.quarter;
}

int guruDisclosureEligibleCount(List<Map<String, dynamic>> gurus) =>
    gurus.where(isQuarterLensGuru).length;

int guruDisclosureQuarterCoverage(
  List<Map<String, dynamic>> gurus,
  String quarter,
) => quarter == '-'
    ? 0
    : gurus
          .where(isQuarterLensGuru)
          .where(
            (guru) =>
                reportQuarterLabel(
                  text(asMap(guru['summary'])['reportDate']),
                ) ==
                quarter,
          )
          .length;

String normalizedMarketLensTicker(Map<String, dynamic> row) {
  final ticker = text(
    row['ticker'],
    compactName(text(row['issuer'])),
  ).toUpperCase();
  return RegExp(r'^[A-Z][A-Z0-9.-]{0,9}$').hasMatch(ticker) ? ticker : '';
}

Map<String, dynamic> marketLensPublicTradingMetadata(
  Iterable<Map<String, dynamic>> rows,
) {
  for (final row in rows) {
    final nested = asMap(row['publicTrading']);
    final status = text(
      nested['publicTradingStatus'],
      text(row['publicTradingStatus'], 'public'),
    );
    final explicitlyReplicable = nested.containsKey('publicReplicable')
        ? truthy(nested['publicReplicable'])
        : row.containsKey('publicReplicable')
        ? truthy(row['publicReplicable'])
        : !status.startsWith('private');
    if (explicitlyReplicable && !status.startsWith('private')) continue;
    return <String, dynamic>{
      'publicTradingStatus': status,
      'publicReplicable': false,
      'reasonEn': text(nested['reasonEn'], text(row['reasonEn'])),
      'reasonZh': text(nested['reasonZh'], text(row['reasonZh'])),
    };
  }
  return const <String, dynamic>{
    'publicTradingStatus': 'public',
    'publicReplicable': true,
    'reasonEn': '',
    'reasonZh': '',
  };
}

String primaryReportedAction(Iterable<String> actions) {
  final counts = <String, int>{};
  for (final raw in actions) {
    final action = raw.trim().toLowerCase();
    if (action.isEmpty || action == 'unchanged') continue;
    counts[action] = (counts[action] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'unchanged';
  const priority = {'new': 0, 'increased': 1, 'reduced': 2, 'sold_out': 3};
  final rows = counts.entries.toList()
    ..sort((left, right) {
      final countCompare = right.value.compareTo(left.value);
      if (countCompare != 0) return countCompare;
      return (priority[left.key] ?? 9).compareTo(priority[right.key] ?? 9);
    });
  return rows.first.key;
}

double medianValue(Iterable<double> values) {
  final rows = values.where((value) => value.isFinite).toList()..sort();
  if (rows.isEmpty) return 0;
  final middle = rows.length ~/ 2;
  if (rows.length.isOdd) return rows[middle];
  return (rows[middle - 1] + rows[middle]) / 2;
}

List<ExposureItem> buildExposures(
  List<Map<String, dynamic>> gurus, {
  String? reportQuarter,
  AppLanguage language = AppLanguage.en,
}) {
  final selectedQuarter = text(
    reportQuarter,
    defaultGuruDisclosureQuarter(gurus),
  );
  if (selectedQuarter == '-') return const [];
  final byTicker = <String, _ExposureAccumulator>{};
  for (final guru in gurus.where(isQuarterLensGuru)) {
    final summary = asMap(guru['summary']);
    final reportDate = text(summary['reportDate']);
    if (reportQuarterLabel(reportDate) != selectedQuarter) continue;
    final guruId = text(guru['id']);
    final guruName = guruDisplayName(guru, language);
    final commonLongValue = reported13fCommonLongValue(guru);
    final previousCommonLongValue =
        firstNumber([
          summary['previousCommonLongValue'],
          summary['previousValue'],
        ]) ??
        0;
    final activityByTicker = <String, List<Map<String, dynamic>>>{};
    for (final activity in asList(guru['activity'])) {
      final ticker = normalizedMarketLensTicker(activity);
      if (ticker.isEmpty) continue;
      activityByTicker.putIfAbsent(ticker, () => []).add(activity);
    }
    final holdingsByTicker = <String, List<Map<String, dynamic>>>{};
    for (final holding in asList(guru['holdings'])) {
      final ticker = normalizedMarketLensTicker(holding);
      if (ticker.isEmpty || number(holding['value']) <= 0) continue;
      holdingsByTicker.putIfAbsent(ticker, () => []).add(holding);
    }
    for (final entry in holdingsByTicker.entries) {
      final holdings = entry.value;
      final ticker = entry.key;
      final value = holdings.fold<double>(
        0,
        (sum, holding) => sum + number(holding['value']),
      );
      final activity = activityByTicker[ticker] ?? const [];
      final publicTrading = marketLensPublicTradingMetadata([
        ...holdings,
        ...activity,
      ]);
      final previousValue = activity.fold<double>(
        0,
        (sum, row) => sum + number(row['previousValue']),
      );
      final action = primaryReportedAction([
        for (final row in activity) text(row['action']),
        for (final row in holdings) text(row['action']),
      ]);
      final position = MarketLensManagerPosition(
        guruId: guruId,
        guruName: guruName,
        guruAvatarUrl: text(guru['avatarUrl'], '/guru-avatars/$guruId.png'),
        ticker: ticker,
        issuer: text(
          holdings.first['issuer'],
          activity.isEmpty ? ticker : text(activity.first['issuer'], ticker),
        ),
        action: action,
        reportDate: reportDate,
        filingDate: text(summary['filingDate'], reportDate),
        currentValue: value,
        previousValue: previousValue,
        currentWeight: commonLongValue > 0
            ? value / commonLongValue
            : holdings.fold<double>(
                0,
                (sum, row) =>
                    sum +
                    (firstNumber([row['pctCommonLong'], row['pctPortfolio']]) ??
                        0),
              ),
        previousWeight: previousCommonLongValue > 0 && previousValue > 0
            ? previousValue / previousCommonLongValue
            : 0,
        changeShares: activity.fold<double>(
          0,
          (sum, row) => sum + number(row['changeShares']),
        ),
        hasTradeEvidence: activity.any(
          (row) => const {
            'new',
            'increased',
            'reduced',
            'sold_out',
          }.contains(text(row['action'])),
        ),
        publicTradingStatus: text(publicTrading['publicTradingStatus']),
        publicReplicable: truthy(publicTrading['publicReplicable']),
        publicTradingReasonEn: text(publicTrading['reasonEn']),
        publicTradingReasonZh: text(publicTrading['reasonZh']),
      );
      final current = byTicker.putIfAbsent(
        ticker,
        () => _ExposureAccumulator(ticker),
      );
      current.value += value;
      current.guruNames.add(guruName);
      current.positions.add(position);
    }
  }
  final rows = byTicker.values
      .map(
        (item) => ExposureItem(
          ticker: item.ticker,
          value: item.value,
          guruNames: Set.unmodifiable(item.guruNames),
          positions: List.unmodifiable(item.positions),
        ),
      )
      .toList();
  rows.sort((left, right) {
    final breadthCompare = right.guruCount.compareTo(left.guruCount);
    if (breadthCompare != 0) return breadthCompare;
    final weightCompare = right.medianWeight.compareTo(left.medianWeight);
    if (weightCompare != 0) return weightCompare;
    final valueCompare = right.value.compareTo(left.value);
    return valueCompare != 0
        ? valueCompare
        : left.ticker.compareTo(right.ticker);
  });
  return rows;
}

class _QuarterCoverage {
  _QuarterCoverage(this.quarter);

  final String quarter;
  int managerCount = 0;
  String latestReportDate = '';
}

class _ExposureAccumulator {
  _ExposureAccumulator(this.ticker);

  final String ticker;
  double value = 0;
  final Set<String> guruNames = <String>{};
  final List<MarketLensManagerPosition> positions = [];
}

List<GuruFilingItem> buildRecentFilingItems(
  List<Map<String, dynamic>> gurus, {
  AppLanguage language = AppLanguage.en,
}) {
  final rows = <GuruFilingItem>[];
  for (final guru in gurus) {
    if (text(guru['type']) != 'manager13f') continue;
    final summary = asMap(guru['summary']);
    final reportDate = text(summary['reportDate']);
    final filingDate = text(summary['filingDate']);
    if (reportDate.isEmpty && filingDate.isEmpty) continue;
    rows.add(
      GuruFilingItem(
        guruId: text(guru['id']),
        guruName: guruDisplayName(guru, language),
        quarter: reportQuarterLabel(reportDate),
        reportDate: reportDate,
        filingDate: filingDate.isEmpty ? reportDate : filingDate,
        value: number(summary['totalValue']),
      ),
    );
  }
  rows.sort((a, b) {
    final dateCompare = b.filingDate.compareTo(a.filingDate);
    return dateCompare != 0 ? dateCompare : b.value.compareTo(a.value);
  });
  return rows;
}

List<GuruActivityRankItem> buildActivityRankItems(
  List<Map<String, dynamic>> gurus, {
  required bool positive,
  String? reportQuarter,
  AppLanguage language = AppLanguage.en,
}) {
  final selectedQuarter = text(
    reportQuarter,
    defaultGuruDisclosureQuarter(gurus),
  );
  if (selectedQuarter == '-') return const [];
  final byTicker = <String, _ActivityRankAccumulator>{};
  final wanted = positive
      ? const {'new', 'increased'}
      : const {'reduced', 'sold_out'};
  for (final guru in gurus.where(isQuarterLensGuru)) {
    final summary = asMap(guru['summary']);
    final reportDate = text(summary['reportDate']);
    if (reportQuarterLabel(reportDate) != selectedQuarter) continue;
    final guruId = text(guru['id']);
    final guruName = guruDisplayName(guru, language);
    final currentCommonLongValue = reported13fCommonLongValue(guru);
    final previousCommonLongValue =
        firstNumber([
          summary['previousCommonLongValue'],
          summary['previousValue'],
        ]) ??
        0;
    final activityByTicker = <String, List<Map<String, dynamic>>>{};
    for (final activity in asList(guru['activity'])) {
      final action = text(activity['action']);
      if (!wanted.contains(action)) continue;
      final ticker = normalizedMarketLensTicker(activity);
      if (ticker.isEmpty) continue;
      activityByTicker.putIfAbsent(ticker, () => []).add(activity);
    }
    for (final entry in activityByTicker.entries) {
      final ticker = entry.key;
      final activities = entry.value;
      final publicTrading = marketLensPublicTradingMetadata(activities);
      var amount = 0.0;
      var amountReliable = true;
      for (final activity in activities) {
        final proxy = activityRankAmount(activity, positive: positive);
        if (proxy == null) {
          amountReliable = false;
        } else {
          amount += proxy;
        }
      }
      final currentValue = activities.fold<double>(
        0,
        (sum, row) => sum + number(row['value']),
      );
      final previousValue = activities.fold<double>(
        0,
        (sum, row) => sum + number(row['previousValue']),
      );
      final action = primaryReportedAction([
        for (final activity in activities) text(activity['action']),
      ]);
      final current = byTicker.putIfAbsent(
        ticker,
        () => _ActivityRankAccumulator(ticker),
      );
      current.amount += amount;
      current.amountReliable = current.amountReliable && amountReliable;
      current.guruNames.add(guruName);
      if (action.isNotEmpty) {
        current.actions[action] = (current.actions[action] ?? 0) + 1;
      }
      current.positions.add(
        MarketLensManagerPosition(
          guruId: guruId,
          guruName: guruName,
          guruAvatarUrl: text(guru['avatarUrl'], '/guru-avatars/$guruId.png'),
          ticker: ticker,
          issuer: text(activities.first['issuer'], ticker),
          action: action,
          reportDate: reportDate,
          filingDate: text(summary['filingDate'], reportDate),
          currentValue: currentValue,
          previousValue: previousValue,
          currentWeight: currentCommonLongValue > 0
              ? currentValue / currentCommonLongValue
              : activities.fold<double>(
                  0,
                  (sum, row) =>
                      sum +
                      (firstNumber([
                            row['pctCommonLong'],
                            row['pctPortfolio'],
                          ]) ??
                          0),
                ),
          previousWeight: previousCommonLongValue > 0 && previousValue > 0
              ? previousValue / previousCommonLongValue
              : 0,
          changeShares: activities.fold<double>(
            0,
            (sum, row) => sum + number(row['changeShares']),
          ),
          hasTradeEvidence: true,
          publicTradingStatus: text(publicTrading['publicTradingStatus']),
          publicReplicable: truthy(publicTrading['publicReplicable']),
          publicTradingReasonEn: text(publicTrading['reasonEn']),
          publicTradingReasonZh: text(publicTrading['reasonZh']),
        ),
      );
      if (reportDate.compareTo(current.reportDate) > 0) {
        current.reportDate = reportDate;
      }
    }
  }
  final rows = byTicker.values
      .map(
        (item) => GuruActivityRankItem(
          ticker: item.ticker,
          actions: Map.unmodifiable(item.actions),
          guruNames: Set.unmodifiable(item.guruNames),
          reportDate: item.reportDate,
          amount: item.amount,
          positions: List.unmodifiable(item.positions),
          amountReliable: item.amountReliable,
        ),
      )
      .toList();
  rows.sort((a, b) {
    final breadthCompare = b.guruCount.compareTo(a.guruCount);
    if (breadthCompare != 0) return breadthCompare;
    final reliabilityCompare = (b.amountReliable ? 1 : 0).compareTo(
      a.amountReliable ? 1 : 0,
    );
    if (reliabilityCompare != 0) return reliabilityCompare;
    if (a.amountReliable && b.amountReliable) {
      final amountCompare = b.amount.compareTo(a.amount);
      if (amountCompare != 0) return amountCompare;
    }
    final dateCompare = b.reportDate.compareTo(a.reportDate);
    return dateCompare != 0 ? dateCompare : a.ticker.compareTo(b.ticker);
  });
  return rows;
}

class _ActivityRankAccumulator {
  _ActivityRankAccumulator(this.ticker);

  final String ticker;
  double amount = 0;
  bool amountReliable = true;
  String reportDate = '';
  final Set<String> guruNames = <String>{};
  final Map<String, int> actions = <String, int>{};
  final List<MarketLensManagerPosition> positions = [];
}

double? activityRankAmount(
  Map<String, dynamic> activity, {
  required bool positive,
}) {
  final action = text(activity['action']);
  final value = number(activity['value']);
  final previousValue = number(activity['previousValue']);
  if (positive) {
    if (action == 'new') return value;
    final delta = value - previousValue;
    return delta >= 0 ? delta : null;
  }
  if (action == 'sold_out') return previousValue > 0 ? previousValue : value;
  final delta = previousValue - value;
  return delta >= 0 ? delta : null;
}

String activityRankSubtitle(
  GuruActivityRankItem item, [
  AppLanguage language = AppLanguage.en,
]) {
  final names = item.guruNames.take(3).join(', ');
  final suffix = item.guruCount > 3 ? ' +' : '';
  final quarter = reportQuarterLabel(item.reportDate);
  final prefix = trFor(
    language,
    '${item.guruCount} 位投资人',
    '${item.guruCount} gurus',
  );
  final namePart = names.isEmpty ? '' : ' · $names$suffix';
  final quarterPart = quarter == '-'
      ? ''
      : trFor(language, ' · 申报季度 $quarter', ' · reported $quarter');
  return '$prefix$namePart$quarterPart';
}

String activityRankActionSummary(
  GuruActivityRankItem item, [
  AppLanguage language = AppLanguage.en,
]) {
  if (item.actions.isEmpty) return '';
  final parts = item.actions.entries.toList()
    ..sort((a, b) {
      final countCompare = b.value.compareTo(a.value);
      return countCompare != 0 ? countCompare : a.key.compareTo(b.key);
    });
  return parts
      .map((entry) => '${actionLabel(entry.key, language)}×${entry.value}')
      .take(2)
      .join(' / ');
}

List<Map<String, dynamic>> asList(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry('$key', value)))
      .toList();
}

Map<String, dynamic> asMap(dynamic value) {
  if (value is! Map) return const {};
  return value.map((key, value) => MapEntry('$key', value));
}

String text(dynamic value, [String fallback = '']) {
  final string = value?.toString().trim() ?? '';
  return string.isEmpty ? fallback : string;
}

String guruDisplayName(
  Map<String, dynamic> guru, [
  AppLanguage language = AppLanguage.en,
]) {
  final englishName = text(guru['name'], text(guru['id'], '?'));
  return language == AppLanguage.zh
      ? text(guru['chineseName'], englishName)
      : englishName;
}

int portfolioRecoveryMinutesRemaining(String undoUntil, {DateTime? now}) {
  final expiresAt = DateTime.tryParse(undoUntil)?.toUtc();
  if (expiresAt == null) return 0;
  final remaining = expiresAt.difference((now ?? DateTime.now()).toUtc());
  if (remaining <= Duration.zero) return 0;
  return math.max(1, (remaining.inSeconds / 60).ceil());
}

String publicAssetUrl(dynamic value) {
  final raw = text(value);
  if (raw.isEmpty) return '';
  if (raw.startsWith('http://') ||
      raw.startsWith('https://') ||
      raw.startsWith('data:')) {
    return raw;
  }
  return raw.startsWith('/') ? raw : '/$raw';
}

const _guruAvatarAssetVersion = '144-20260912r2';

String resolvedGuruAvatarUrl(Map<String, dynamic> guru) {
  for (final value in [guru['avatarUrl'], guru['avatar']]) {
    if (text(value).trim().isNotEmpty) return versionedGuruAvatarUrl(value);
  }
  final id = text(guru['id'] ?? guru['guruId']);
  // Only canonical slugs may form a static asset URL; never use display names.
  if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id)) return '';
  return versionedGuruAvatarUrl('/guru-avatars/$id.png');
}

String versionedGuruAvatarUrl(dynamic value) {
  final url = publicAssetUrl(value);
  if (url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.path.startsWith('/guru-avatars/')) return url;
  return uri
      .replace(
        queryParameters: {...uri.queryParameters, 'v': _guruAvatarAssetVersion},
      )
      .toString();
}

double number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(text(value).replaceAll(',', '')) ?? 0;
}

double? nullableNumber(dynamic value) {
  if (value is num && value.isFinite) return value.toDouble();
  final raw = text(value);
  if (raw.isEmpty) return null;
  final parsed = double.tryParse(raw.replaceAll(',', ''));
  return parsed == null || !parsed.isFinite ? null : parsed;
}

double? firstNumber(List<dynamic> values) {
  for (final value in values) {
    final parsed = nullableNumber(value);
    if (parsed != null) return parsed;
  }
  return null;
}

bool truthy(dynamic value) =>
    value == true || text(value).toLowerCase() == 'true';

String compactName(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r' - COMMON STOCK.*$', caseSensitive: false), '')
    .trim();

String disclosureLabel(String type, [AppLanguage language = AppLanguage.en]) =>
    switch (type) {
      'manager13f' => trFor(language, '13F 基金', '13F fund'),
      'insider' => trFor(language, 'Form 4 高管交易', 'Form 4'),
      'congress' => trFor(language, '国会交易', 'STOCK Act'),
      'profile' => trFor(language, '资料', 'Profile'),
      _ => type.isEmpty ? trFor(language, '公开披露', 'Disclosure') : type,
    };

String actionLabel(String action, [AppLanguage language = AppLanguage.en]) =>
    switch (action) {
      'new' => trFor(language, '新增', 'New'),
      'increased' => trFor(language, '加仓', 'Add'),
      'reduced' => trFor(language, '减仓', 'Reduce'),
      'sold_out' => trFor(language, '清仓', 'Sold out'),
      'buy' => trFor(language, '买入', 'Buy'),
      'sell' => trFor(language, '卖出', 'Sell'),
      'award' => trFor(language, '授予', 'Award'),
      'option_exercise' => trFor(language, '行权', 'Option exercise'),
      'tax_withholding' => trFor(language, '税务扣缴', 'Tax withholding'),
      'gift' => trFor(language, '赠与', 'Gift'),
      'disposed_to_issuer' => trFor(language, '处置给发行人', 'Disposed to issuer'),
      'other' => trFor(language, '其他', 'Other'),
      _ => action.isEmpty ? trFor(language, '其他', 'Other') : action,
    };

String reported13fActionLabel(
  String action, [
  AppLanguage language = AppLanguage.en,
]) => switch (action) {
  'new' => trFor(language, '申报新建仓', 'Reported new position'),
  'increased' => trFor(language, '申报增持', 'Reported increase'),
  'reduced' => trFor(language, '申报减持', 'Reported reduction'),
  'sold_out' => trFor(language, '不再申报', 'No longer reported'),
  _ => actionLabel(action, language),
};

List<Map<String, dynamic>> guruTradeRows(Map<String, dynamic> guru) {
  final manager = text(guru['type']) == 'manager13f';
  final rows = manager
      ? asList(guru['activity'])
            .where(
              (row) => {
                'new',
                'increased',
                'reduced',
                'sold_out',
              }.contains(text(row['action'])),
            )
            .toList()
      : asList(guru['transactions'])
            .where((row) => text(row['ticker']).isNotEmpty)
            .map(
              (row) => {
                ...row,
                'date': text(row['transactionDate'], text(row['reportDate'])),
                'value': tradeDisplayAmount(row),
                'changeShares': tradeShareChange(row),
              },
            )
            .toList();
  final priority = {
    'new': 0,
    'buy': 0,
    'sold_out': 1,
    'sell': 1,
    'increased': 2,
    'reduced': 3,
    'option_exercise': 4,
    'award': 5,
    'tax_withholding': 6,
    'gift': 7,
  };
  rows.sort((left, right) {
    if (!manager) {
      final dateCompare = text(
        right['date'],
        text(right['filingDate']),
      ).compareTo(text(left['date'], text(left['filingDate'])));
      if (dateCompare != 0) return dateCompare;
      return tradeDisplayAmount(right).compareTo(tradeDisplayAmount(left));
    }
    final leftPriority = priority[text(left['action'])] ?? 9;
    final rightPriority = priority[text(right['action'])] ?? 9;
    if (leftPriority != rightPriority) {
      return leftPriority.compareTo(rightPriority);
    }
    final leftValue = tradeDisplayAmount(left);
    final rightValue = tradeDisplayAmount(right);
    return rightValue.compareTo(leftValue);
  });
  return rows;
}

double tradeDisplayAmount(Map<String, dynamic> row) {
  final values = [
    number(row['value']),
    number(row['notional']),
    number(row['estimatedValue']),
    number(row['previousValue']),
  ].where((value) => value > 0).toList();
  if (values.isNotEmpty) return values.reduce(math.max);

  final shares = tradeShareChange(row).abs();
  final price = number(row['price']);
  if (shares > 0 && price > 0) return shares * price;
  return 0;
}

double tradeShareChange(Map<String, dynamic> row) {
  final change = number(row['changeShares']);
  if (change != 0) return change;
  final shares = number(row['shares']);
  if (shares == 0) return 0;
  final action = text(row['action']);
  if (action == 'sell' || action == 'reduced' || action == 'sold_out') {
    return -shares.abs();
  }
  return shares;
}

Color tradeToneColor(String action, Palette palette) {
  if (action == 'new' || action == 'increased' || action == 'buy') {
    return palette.positive;
  }
  if (action == 'reduced' || action == 'sold_out' || action == 'sell') {
    return palette.negative;
  }
  return palette.muted;
}

String formatSignedNumber(double value) {
  if (!value.isFinite || value == 0) return '0';
  final sign = value > 0 ? '+' : '';
  return '$sign${formatNumber(value)}';
}

String filingLag(Map<String, dynamic> summary) {
  final report = DateTime.tryParse(text(summary['reportDate']));
  final filing = DateTime.tryParse(text(summary['filingDate']));
  if (report == null || filing == null) return '13F';
  return '${filing.difference(report).inDays}d';
}

String filingLagVerbose(Map<String, dynamic> summary) {
  final report = DateTime.tryParse(text(summary['reportDate']));
  final filing = DateTime.tryParse(text(summary['filingDate']));
  if (report == null || filing == null) return '13F';
  return '${filing.difference(report).inDays} days';
}

String reportQuarterLabel(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value.isEmpty ? '-' : value;
  final quarter = ((date.month - 1) ~/ 3) + 1;
  return '${date.year}/Q$quarter';
}

String compactStrategy(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\bcompounders\b', caseSensitive: false), '')
      .replaceAll(RegExp(r'\bportfolio\b', caseSensitive: false), '')
      .trim();
  if (cleaned.isEmpty) return 'Focused';
  return cleaned.length <= 18 ? cleaned : cleaned.substring(0, 18).trim();
}

String toolbarDateLabel(
  String generatedAt, [
  AppLanguage language = AppLanguage.en,
]) {
  final date = DateTime.tryParse(generatedAt)?.toLocal();
  if (date == null) {
    return trFor(language, '截至日期未提供', 'As-of unavailable');
  }
  final weekdays = language == AppLanguage.zh
      ? const ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
      : const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final day = weekdays[date.weekday - 1];
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ($day)';
}

String userInitials(String value) {
  final words = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'YL';
  if (words.length == 1) {
    return words.first.characters.take(2).toString().toUpperCase();
  }
  return '${words.first.characters.first}${words.last.characters.first}'
      .toUpperCase();
}

bool trailingWindowSelected(
  List<Map<String, dynamic>> equity,
  RangeValues? range,
  int years,
) {
  if (range == null || equity.length < 3) return false;
  final lastDate = DateTime.tryParse(text(equity.last['date']));
  if (lastDate == null) return false;
  final target = DateTime(lastDate.year - years, lastDate.month, lastDate.day);
  var expected = 0;
  for (var i = 0; i < equity.length; i += 1) {
    final date = DateTime.tryParse(text(equity[i]['date']));
    if (date != null && !date.isBefore(target)) {
      expected = i;
      break;
    }
  }
  return (range.start.round() - expected).abs() <= 2 &&
      range.end.round() >= equity.length - 3;
}

String formatDate(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value.isEmpty ? '-' : value;
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

String formatNumber(double value) {
  if (!value.isFinite) return '-';
  final rounded = value.round();
  final chars = rounded.abs().toString().split('').reversed.toList();
  final buffer = StringBuffer();
  for (var i = 0; i < chars.length; i += 1) {
    if (i > 0 && i % 3 == 0) buffer.write(',');
    buffer.write(chars[i]);
  }
  final body = buffer.toString().split('').reversed.join();
  return rounded < 0 ? '-$body' : body;
}

String signedNumber(int value) => value >= 0 ? '+$value' : '$value';

String formatMoney(double value) {
  if (!value.isFinite || value == 0) return '\$0';
  final abs = value.abs();
  final sign = value < 0 ? '-' : '';
  if (abs >= 1e9) return '$sign\$${(abs / 1e9).toStringAsFixed(2)}B';
  if (abs >= 1e6) return '$sign\$${(abs / 1e6).toStringAsFixed(1)}M';
  if (abs >= 1e3) return '$sign\$${(abs / 1e3).toStringAsFixed(1)}K';
  return '$sign\$${abs.toStringAsFixed(0)}';
}

String formatCurrencyValue(double value, String currency) {
  if (!value.isFinite || value == 0) return '${currencySymbol(currency)}0';
  final symbol = currencySymbol(currency);
  return '$symbol${value.toStringAsFixed(value >= 100 ? 0 : 2)}';
}

String formatValuationMethodValue(Map<String, dynamic> card, String currency) {
  final rawValue = firstNumber([card['value'], card['amount'], card['score']]);
  if (rawValue == null) return '-';
  final format = text(card['format']).toLowerCase();
  if (format == 'millions') {
    return '${currencySymbol(currency)}${formatMillions(rawValue)}';
  }
  if (format.contains('currency') || format.contains('price')) {
    return formatCurrencyValue(rawValue, text(card['currency'], currency));
  }
  if (format.contains('percent') || format.contains('ratio')) {
    final normalized = rawValue.abs() > 3 ? rawValue / 100 : rawValue;
    return formatReturn(normalized);
  }
  if (rawValue.abs() >= 1000) return formatNumber(rawValue);
  return rawValue.toStringAsFixed(rawValue.abs() >= 10 ? 1 : 2);
}

String currencySymbol(String currency) => switch (currency.toUpperCase()) {
  'GBP' => '£',
  'EUR' => '€',
  'USD' => '\$',
  _ => '${currency.toUpperCase()} ',
};

String formatReturn(double value) {
  if (!value.isFinite) return '-';
  final sign = value >= 0 ? '+' : '';
  return '$sign${(value * 100).toStringAsFixed(1)}%';
}

String formatMillions(double? value) {
  if (value == null || !value.isFinite) return '-';
  final abs = value.abs();
  final sign = value < 0 ? '-' : '';
  if (abs >= 1000) {
    final scaled = abs / 1000;
    return '$sign${scaled.toStringAsFixed(scaled >= 10 ? 1 : 2)}B';
  }
  return '$sign${abs.toStringAsFixed(abs >= 100 ? 0 : 1)}M';
}

String formatSharesMillions(double? value, AppLanguage language) {
  if (value == null || !value.isFinite) return '-';
  final abs = value.abs();
  final sign = value < 0 ? '-' : '';
  if (abs >= 1000) {
    final scaled = abs / 1000;
    return trFor(
      language,
      '$sign${scaled.toStringAsFixed(scaled >= 10 ? 1 : 2)}B 股',
      '$sign${scaled.toStringAsFixed(scaled >= 10 ? 1 : 2)}B sh',
    );
  }
  return trFor(
    language,
    '$sign${abs.toStringAsFixed(abs >= 100 ? 0 : 1)}M 股',
    '$sign${abs.toStringAsFixed(abs >= 100 ? 0 : 1)}M sh',
  );
}

String formatPercentInput(double? value) {
  if (value == null || !value.isFinite) return '-';
  final normalized = value.abs() <= 1.5 ? value * 100 : value;
  final sign = normalized > 0 ? '+' : '';
  return '$sign${normalized.toStringAsFixed(1)}%';
}

List<ValuationQaDatum> valuationQaItems(
  Map<String, dynamic> row,
  Map<String, dynamic>? previous,
  String currency,
) {
  final snapshot = asMap(row['dataSnapshot']);
  final youtube = asMap(snapshot['youtubeEarnings']);
  final qaRows = asList(youtube['qa']);
  return qaRows
      .map((item) {
        final question = text(item['question']);
        final answer = text(item['answer']);
        if (question.isEmpty) return null;
        final askedBy = text(item['askedBy'], text(item['speaker']));
        final askedByZh = text(item['askedByZh'], askedBy);
        final callDate = text(item['callDate']);
        final title = text(item['title']);
        final titleZh = text(item['titleZh'], title);
        final metadata = [
          if (askedBy.isNotEmpty) 'Asked by $askedBy',
          if (callDate.isNotEmpty) formatDate(callDate),
          if (title.isNotEmpty) title,
        ].join(' · ');
        final metadataZh = [
          if (askedByZh.isNotEmpty) '提问人 $askedByZh',
          if (callDate.isNotEmpty) formatDate(callDate),
          if (titleZh.isNotEmpty) titleZh,
        ].join(' · ');
        final body = answer.isNotEmpty
            ? answer
            : 'Management response context is not available in the structured transcript extract.';
        final bodyZh = text(item['answerZh']);
        return ValuationQaDatum(
          question: question,
          answer: body,
          questionZh: text(item['questionZh']),
          answerZh: bodyZh,
          metadata: metadata,
          metadataZh: metadataZh,
        );
      })
      .whereType<ValuationQaDatum>()
      .take(6)
      .toList();
}

String valuationQaEmptyText(Map<String, dynamic> row, bool showChinese) {
  final snapshot = asMap(row['dataSnapshot']);
  final youtube = asMap(snapshot['youtubeEarnings']);
  final coverage = asMap(youtube['qaCoverage']);
  final status = text(coverage['status']);
  final callDate = text(coverage['callDate']);
  final title = text(coverage['title']);
  final source = [
    if (callDate.isNotEmpty) formatDate(callDate),
    if (title.isNotEmpty) title,
  ].join(' · ');
  final suffix = source.isEmpty
      ? ''
      : (showChinese ? '\n来源：$source' : '\nSource: $source');

  if (showChinese) {
    switch (status) {
      case 'locked_preview':
        return '这个季度的电话会 transcript 在当前源里只有锁定预览，没有包含分析师 Q&A；已写入数据库并标记为待补抓。$suffix';
      case 'partial_transcript':
        return '这个季度的 transcript 太短，不足以抽取完整分析师问答；已记录为部分 transcript。$suffix';
      case 'no_segments':
        return '这个季度有电话会记录，但本地 transcript segments 为空；已记录为待重新同步。$suffix';
      case 'transcript_not_in_source':
        return '这个季度本地 transcript 库没有对应电话会，所以无法显示真实分析师问答；已记录为缺失源数据。$suffix';
      case 'qa_parse_miss':
        return '这个季度的 transcript 里有疑似问题文本，但没有可靠识别出“分析师提问 + 管理层回答”的配对；已标记为解析待修。$suffix';
      case 'has_qa':
        return '数据库标记这个季度应该有 Q&A，但前端没有收到可渲染的问题；请重新同步 valuation Q&A。$suffix';
      default:
        return '这个季度没有可用的结构化分析师问答；数据库会保留具体覆盖状态，等待补抓或重跑解析。$suffix';
    }
  }

  switch (status) {
    case 'locked_preview':
      return 'This quarter has only a locked transcript preview in the current source, so analyst Q&A is not available yet.$suffix';
    case 'partial_transcript':
      return 'The stored transcript is too short to extract a complete analyst Q&A section.$suffix';
    case 'no_segments':
      return 'The earnings-call record exists, but transcript segments are missing.$suffix';
    case 'transcript_not_in_source':
      return 'No matching earnings-call transcript is stored locally for this valuation quarter yet.$suffix';
    case 'qa_parse_miss':
      return 'The transcript contains question-like text, but the parser could not safely pair analyst questions with management answers.$suffix';
    case 'has_qa':
      return 'This quarter is marked as having Q&A, but no renderable question reached the client. Please resync valuation Q&A.$suffix';
    default:
      return 'No structured analyst Q&A is available for this quarter yet; the database keeps the coverage reason for follow-up.$suffix';
  }
}

String valuationWeightSummary(Map<String, dynamic> row) {
  final methods = asList(row['methodOutputs']);
  final snapshot = asMap(row['dataSnapshot']);
  final semantics = asMap(snapshot['valuationSemantics']);
  final scoreInputs = asMap(semantics['scoreInputs']);
  final weights = asMap(scoreInputs['methodWeights']);
  if (weights.isNotEmpty) {
    return weights.entries
        .take(4)
        .map((entry) {
          final key = entry.key;
          final label = valuationMethodLabel(methods, key);
          final value = firstNumber([entry.value]);
          return '$label ${formatPercentInput(value)}';
        })
        .join(' / ');
  }
  for (final method in methods) {
    if (text(method['key']).toLowerCase().contains('weight')) {
      return text(method['description'], text(method['label']));
    }
  }
  return 'no explicit method-weight map was returned for this quarter';
}

String valuationMethodLabel(List<Map<String, dynamic>> methods, String key) {
  for (final method in methods) {
    if (text(method['key']) == key) {
      final label = text(method['label'], key);
      return label.length <= 24 ? label : '${label.substring(0, 21)}...';
    }
  }
  return key.replaceAll('-', ' ');
}

String defaultValuationTicker(
  Map<String, dynamic> data, {
  String preferred = '',
}) {
  final tickers = asList(data['tickers']).isNotEmpty
      ? asList(data['tickers'])
      : asList(data['stocks']);
  final rows = valuationRowsFromTickers(tickers);
  final normalizedPreferred = preferred.trim().toUpperCase();
  if (normalizedPreferred.isNotEmpty &&
      rows.any((row) => row.ticker == normalizedPreferred)) {
    return normalizedPreferred;
  }
  final featuredTicker = text(data['featuredTicker']).trim().toUpperCase();
  if (featuredTicker.isNotEmpty &&
      rows.any((row) => row.ticker == featuredTicker)) {
    return featuredTicker;
  }
  final neutralCandidates =
      rows.where((row) => row.hasModel && row.lineageStatus == 'pass').toList()
        ..sort((a, b) => a.ticker.compareTo(b.ticker));
  if (neutralCandidates.isNotEmpty) return neutralCandidates.first.ticker;
  final modeledRows = rows.where((row) => row.hasModel).toList()
    ..sort((a, b) => a.ticker.compareTo(b.ticker));
  if (modeledRows.isNotEmpty) return modeledRows.first.ticker;
  final fallbackRows = [...rows]..sort((a, b) => a.ticker.compareTo(b.ticker));
  return fallbackRows.isEmpty ? '' : fallbackRows.first.ticker;
}

List<ValuationRow> valuationRowsFromTickers(
  List<Map<String, dynamic>> tickers,
) {
  return tickers
      .map((ticker) {
        final latest = asMap(ticker['latest']);
        final quality = asMap(ticker['dataQuality']);
        final inputAudit = asMap(quality['modelInputAudit']);
        final unifiedAudit = asMap(quality['unifiedValuationAudit']);
        final auditLayers = asMap(quality['auditLayers']);
        final lineage = asMap(auditLayers['lineage']);
        final release = asMap(auditLayers['release']);
        final economicValidation = asMap(auditLayers['economicValidation']);
        final marketCalibration = asMap(auditLayers['marketCalibration']);
        final consensus = asMap(unifiedAudit['externalConsensus']);
        final consensusCheck = asMap(unifiedAudit['externalConsensusCheck']);
        final currency = text(
          ticker['currency'],
          text(consensus['currency'], 'USD'),
        );
        final latestPrice =
            firstNumber([latest['latestPrice'], consensus['currentPrice']]) ??
            0;
        final fairValue =
            firstNumber([
              latest['baseFairValue'],
              asList(ticker['scenarios']).isNotEmpty
                  ? asList(ticker['scenarios']).first['fairValue']
                  : null,
            ]) ??
            0;
        final upside =
            firstNumber([latest['upsideToBase']]) ??
            (latestPrice > 0 && fairValue > 0
                ? fairValue / latestPrice - 1
                : 0);
        return ValuationRow(
          ticker: text(ticker['ticker'], text(ticker['symbol'])).toUpperCase(),
          name: text(
            ticker['companyName'],
            text(ticker['name'], text(ticker['description'], 'Company')),
          ),
          sector: compactValuationSector(
            text(ticker['sector'], 'Unclassified'),
          ),
          currency: currency,
          latestPrice: latestPrice,
          fairValue: fairValue,
          upside: upside,
          targetPrice3Y: firstNumber([latest['targetPrice3Y']]) ?? fairValue,
          expectedReturn3Y: firstNumber([latest['expectedReturn3Y']]) ?? 0,
          latestPriceDate: text(latest['latestPriceDate']),
          coverageKind: text(
            quality['valuationCoverageKind'],
            text(quality['coverageKind']),
          ),
          lineageStatus: text(
            lineage['status'],
            text(inputAudit['status'], 'not_run'),
          ).toLowerCase(),
          releaseStatus: text(release['status'], 'not_verified').toLowerCase(),
          economicValidationStatus: text(
            economicValidation['status'],
            'not_validated',
          ).toLowerCase(),
          marketCalibrationStatus: text(
            marketCalibration['status'],
            'not_run',
          ).toLowerCase(),
          consensusStatus: text(consensusCheck['status']),
          consensusUpside: nullableNumber(consensus['impliedUpside']),
        );
      })
      .where((row) => row.ticker.isNotEmpty)
      .toList()
    ..sort((a, b) => b.upside.compareTo(a.upside));
}

double medianDouble(List<double> values) {
  final finite = values.where((value) => value.isFinite).toList()..sort();
  if (finite.isEmpty) return 0;
  final middle = finite.length ~/ 2;
  if (finite.length.isOdd) return finite[middle];
  return (finite[middle - 1] + finite[middle]) / 2;
}

Color valuationTone(double upside, Palette palette) {
  if (upside >= .05) return palette.positive;
  if (upside <= -.05) return palette.negative;
  return palette.secondary;
}

String compactValuationSector(String value) {
  final cleaned = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length <= 42) return cleaned;
  final firstSegment = cleaned.split('/').first.trim();
  if (firstSegment.length >= 8 && firstSegment.length <= 42) {
    return firstSegment;
  }
  return '${cleaned.substring(0, 39).trim()}...';
}
