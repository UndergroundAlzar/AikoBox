/// The profiles feature: the subscription list, the import form, the YAML and
/// rules editors, and the per-profile override document.
///
/// The shell only needs [ProfilesPage]; everything else is exported because the
/// deep-link handler and the dashboard's profile card both need to open the
/// import form and the editors, and because the data layer is worth testing on
/// its own.
///
/// ## On-disk layout this feature owns
///
/// ```
/// profiles/<id>.override.yaml   the override document (rules + patch + schedule)
/// profiles/<id>.base.yaml       the pristine profile, while an override is in force
/// ```
///
/// plus one keystore entry per profile for its subscription `Authorization`
/// value. `profiles/<id>.yaml` itself belongs to the core's `ProfileStore`;
/// this feature only ever writes it back through that store, so every write
/// stays atomic and serialised (N6).
library;

export 'data/deep_merge.dart';
export 'data/profile_batch_update.dart';
export 'data/profile_error_text.dart' show ProfileErrorText, redactProfileMessage;
export 'data/profile_format.dart';
export 'data/profile_overlay_store.dart';
export 'data/profile_secret_store.dart';
export 'data/profiles_providers.dart';
export 'data/rule_editor_model.dart';
export 'data/rule_overlay.dart';
export 'data/rule_syntax.dart';
export 'data/update_schedule.dart';
export 'data/yaml_document.dart';
export 'pages/profile_editor_page.dart'
    show ProfileEditorPage, pushImportSubscription, pushProfileEditor;
export 'pages/profile_override_page.dart'
    show ProfileOverridePage, pushProfileOverride;
export 'pages/profile_rules_page.dart' show ProfileRulesPage, pushProfileRules;
export 'pages/profile_source_page.dart'
    show ProfileSourcePage, pushProfileSource;
export 'pages/yaml_editor_page.dart' show YamlEditorPage;
export 'profiles_page.dart' show ProfilesPage;
export 'widgets/profile_card.dart' show ProfileCard, ProfileCardAction;
export 'widgets/subscription_qr_sheet.dart'
    show SubscriptionQrSheet, showSubscriptionQrSheet;
export 'widgets/subscription_usage_bar.dart' show SubscriptionUsageBar;
export 'widgets/yaml_source_field.dart' show YamlSourceField;
