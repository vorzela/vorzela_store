import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

class PreferStoreModelsHelper extends DartLintRule {
  const PreferStoreModelsHelper() : super(code: _code);

  static const _code = LintCode(
    name: 'prefer_store_models_helper',
    problemMessage:
        'JsonModel collections can use store.models(...) instead of collection(..., fromJson: ...).',
    correctionMessage: 'Prefer await store.models(name, fromJson: YourModel.fromJson).',
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    context.registry.addMethodInvocation((node) {
      if (node.methodName.name != 'collection') return;
      final hasFromJson = node.argumentList.arguments.any(
        (arg) => arg is NamedExpression && arg.name.label.name == 'fromJson',
      );
      if (!hasFromJson) return;
      reporter.atNode(node.methodName, code);
    });
  }
}
