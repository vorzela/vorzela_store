import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/listener.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

import '../utils.dart';

class PreferVorzBlobStoreForBytes extends DartLintRule {
  const PreferVorzBlobStoreForBytes() : super(code: _code);

  static const _code = LintCode(
    name: 'prefer_vorz_blob_store_for_bytes',
    problemMessage:
        'Large binary payloads belong in VorzBlobStore — document \$set(\'bytes\') bloats the engine.',
    correctionMessage:
        'Use VorzBlobStore for reboot-safe media; keep small metadata in documents.',
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    var usesStore = false;
    context.registry.addCompilationUnit((unit) {
      usesStore = compilationUnitImportsVorzelaStore(unit);
    });

    context.registry.addMethodInvocation((node) {
      if (!usesStore) return;
      if (node.methodName.name == r'$set') {
        final args = node.argumentList.arguments;
        if (args.isEmpty) return;
        final first = args.first;
        if (first is StringLiteral && first.stringValue == 'bytes') {
          reporter.atNode(first, code);
        }
        return;
      }
      if (node.methodName.name == 'put') {
        final args = node.argumentList.arguments;
        if (args.length < 2) return;
        if (mapLiteralHasBytesKey(args[1])) {
          reporter.atNode(args[1], code);
        }
      }
    });
  }
}
