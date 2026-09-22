import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:custom_lint_builder/custom_lint_builder.dart';

bool isTestPath(CustomLintResolver resolver) {
  final path = resolver.source.fullName.replaceAll(r'\', '/');
  return path.contains('/test/') || path.endsWith('_test.dart');
}

bool isVorzStoreStaticCall(MethodInvocation node, String method) {
  if (node.methodName.name != method) return false;
  final target = node.target;
  if (target is SimpleIdentifier && target.name == 'VorzStore') return true;
  if (target is PrefixedIdentifier && target.identifier.name == 'VorzStore') {
    return true;
  }
  return false;
}

bool compilationUnitImportsVorzelaStore(CompilationUnit unit) {
  for (final directive in unit.directives) {
    if (directive is! ImportDirective) continue;
    final uri = directive.uri.stringValue;
    if (uri == null) continue;
    if (uri.contains('vorzela_store')) return true;
  }
  return false;
}

bool expressionInvolvesEphemeralDirectory(Expression expression) {
  var found = false;
  expression.accept(
    _EphemeralDirVisitor(onMatch: () => found = true),
  );
  return found;
}

class _EphemeralDirVisitor extends RecursiveAstVisitor<void> {
  _EphemeralDirVisitor({required this.onMatch});

  final void Function() onMatch;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'getTemporaryDirectory' ||
        name == 'getApplicationCacheDirectory') {
      onMatch();
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.constructorName.type.toSource();
    if (type.contains('TemporaryDirectory')) {
      onMatch();
    }
    super.visitInstanceCreationExpression(node);
  }
}

bool functionBodyContainsClose(FunctionBody body) {
  var found = false;
  body.accept(
    _CloseCallVisitor(onClose: () => found = true),
  );
  return found;
}

class _CloseCallVisitor extends RecursiveAstVisitor<void> {
  _CloseCallVisitor({required this.onClose});

  final void Function() onClose;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'close') {
      onClose();
    }
    super.visitMethodInvocation(node);
  }
}

bool mapLiteralHasBytesKey(Expression expression) {
  if (expression is! SetOrMapLiteral) return false;
  for (final element in expression.elements) {
    if (element is MapLiteralEntry) {
      final key = element.key;
      if (key is StringLiteral && key.stringValue == 'bytes') return true;
    }
  }
  return false;
}
