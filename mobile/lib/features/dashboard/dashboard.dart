/// The AikoBox dashboard.
///
/// One import for the app shell:
///
/// ```dart
/// import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
/// ```
///
/// The shell needs exactly two things from this feature: [DashboardPage], and
/// an override for [dashboardNavigateProvider] so cards can open the other
/// pages. Everything else is internal, and is exported only because the cards
/// and their providers are useful to test in isolation.
library;

export 'card_layout_sheet.dart'
    show DashboardLayoutEditor, showDashboardLayoutSheet;
export 'dashboard_card_shell.dart'
    show
        DashboardCard,
        DashboardCountBadge,
        DashboardKeyValue,
        DashboardMetric,
        dashboardCardHeight,
        dashboardOpen,
        kDashboardNoValue,
        kDashboardRowUnit;
export 'dashboard_cards.dart'
    show
        DashboardCardSpec,
        buildDashboardGridItems,
        dashboardCardSpec,
        defaultDashboardCardStatus,
        kDashboardCards,
        kLatencyCardKey,
        resolveDashboardCardOrder;
export 'dashboard_error.dart'
    show
        DashboardErrorPresentation,
        dashboardErrorPresentation,
        showDashboardErrorSheet;
export 'dashboard_format.dart'
    show
        daysUntil,
        formatBytes,
        formatDate,
        formatDateTime,
        formatDelay,
        formatSpeed,
        usagePercent;
export 'dashboard_navigation.dart'
    show DashboardDestination, DashboardNavigate, dashboardNavigateProvider;
export 'dashboard_page.dart' show DashboardPage;
export 'dashboard_providers.dart'
    show
        LatencyProbeResult,
        LatencyTarget,
        NetworkLatencyNotifier,
        ProfileRuntimeSummary,
        TrafficHistoryNotifier,
        coreVersionProvider,
        kDefaultLatencyTargets,
        kTrafficHistoryLength,
        latencyHttpClientProvider,
        latencyTargetsProvider,
        networkLatencyProvider,
        normalizeLatencyUrl,
        probeLatency,
        profileRuntimeSummaryProvider,
        trafficHistoryProvider;
export 'start_button.dart' show DashboardStartButton;
