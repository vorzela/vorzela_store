import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../utils.dart';

class PreferWipeKeysThenClose extends DartLintRule {
  const PreferWipeKeysThenClose() : super(code: _code);

  static const _code = LintCode(
    name: 'prefer_wipe_keys_then_close',
    problemMessage:
        'After wipeKeys(), close the store so engines and watchers shut down cleanly.',
    correctionMessage: 'Call await store.close() in the same function after wipeKeys().',
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    context.registry.addMethodInvocation((node) {
      if (node.methodName.name != 'wipeKeys') return;
      final body = node.thisOrAncestorOfType<BlockFunctionBody>() ??
          node.thisOrAncestorOfType<ExpressionFunctionBody>();
      if (body == null) return;
      if (functionBodyContainsClose(body)) return;
      reporter.atNode(node.methodName, code);
    });
  }
}
