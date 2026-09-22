import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../utils.dart';

class AvoidVorzStoreOpenMemoryInApp extends DartLintRule {
  const AvoidVorzStoreOpenMemoryInApp() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_vorz_store_open_memory_in_app',
    problemMessage:
        'VorzStore.openMemory is in-memory only — not durable across app restarts.',
    correctionMessage: 'Use VorzStore.open in app code; openMemory in tests only.',
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    if (isTestPath(resolver)) return;
    context.registry.addMethodInvocation((node) {
      if (!isVorzStoreStaticCall(node, 'openMemory')) return;
      reporter.atNode(node.methodName, code);
    });
  }
}
