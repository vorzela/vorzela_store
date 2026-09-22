import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../utils.dart';

class AvoidTemporaryDirectoryForVorzStore extends DartLintRule {
  const AvoidTemporaryDirectoryForVorzStore() : super(code: _code);

  static const _code = LintCode(
    name: 'avoid_temporary_directory_for_vorz_store',
    problemMessage:
        'VorzStore on tmp/cache dirs is wiped on reboot — data will not survive.',
    correctionMessage:
        'Omit directory: (Application Support default) or pass Application Support / documents.',
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    context.registry.addMethodInvocation((node) {
      if (!isVorzStoreStaticCall(node, 'open')) return;
      Expression? directory;
      for (final arg in node.argumentList.arguments) {
        if (arg is NamedExpression && arg.name.label.name == 'directory') {
          directory = arg.expression;
          break;
        }
      }
      if (directory == null) return;
      if (!expressionInvolvesEphemeralDirectory(directory)) return;
      reporter.atNode(directory, code);
    });
  }
}
