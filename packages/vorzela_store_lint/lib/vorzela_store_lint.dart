import 'package:custom_lint_builder/custom_lint_builder.dart';

import 'src/rules/avoid_temporary_directory_for_vorz_store.dart';
import 'src/rules/avoid_vorz_store_open_memory_in_app.dart';
import 'src/rules/prefer_store_models_helper.dart';
import 'src/rules/prefer_vorz_blob_store_for_bytes.dart';
import 'src/rules/prefer_wipe_keys_then_close.dart';

/// Entrypoint for `custom_lint` — must stay `createPlugin` in this library.
PluginBase createPlugin() => _VorzelaStoreLint();

class _VorzelaStoreLint extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [
        const AvoidTemporaryDirectoryForVorzStore(),
        const AvoidVorzStoreOpenMemoryInApp(),
        const PreferVorzBlobStoreForBytes(),
        const PreferStoreModelsHelper(),
        const PreferWipeKeysThenClose(),
      ];
}
