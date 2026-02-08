using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Dynamics.Nav.CodeAnalysis;
using Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics;

namespace ALCops.PlatformCop.Analyzers;

[DiagnosticAnalyzer]
public sealed class TransferFieldsRelationsJsonCollector : DiagnosticAnalyzer
{
    private const string TransferFieldsMethodName = "TransferFields";

    private static readonly OperationKind InvocationOperationKind =
        (OperationKind)Enum.Parse(typeof(OperationKind), "InvocationExpression");

    private static readonly MethodKind BuiltInMethodKind =
        (MethodKind)Enum.Parse(typeof(MethodKind), "BuiltInMethod");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DictionaryKeyPolicy = JsonNamingPolicy.CamelCase

    };

    private static readonly DiagnosticDescriptor CollectorDescriptor =
        new(
            id: "TRANSFERFIELDS_RELATIONS_JSON_COLLECTOR",
            title: "TransferFields relations JSON collector",
            messageFormat: "Internal collector (no diagnostics are reported).",
            category: "ALCops.Collector",
            defaultSeverity: DiagnosticSeverity.Hidden,
            isEnabledByDefault: true);

    public override ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics =>
        ImmutableArray.Create(CollectorDescriptor);

    // One compilation → one stable ID → one temp folder
    private static readonly ConditionalWeakTable<Compilation, string> CompilationIds = new();

    public override void Initialize(AnalysisContext context) =>
        context.RegisterOperationAction(AnalyzeInvocation, InvocationOperationKind);

    private static void AnalyzeInvocation(OperationAnalysisContext ctx)
    {
        if (ctx.Operation is not IInvocationExpression invocation)
            return;

        var targetMethod = invocation.TargetMethod;
        if (targetMethod is null ||
            targetMethod.MethodKind != BuiltInMethodKind ||
            !string.Equals(targetMethod.Name, TransferFieldsMethodName, StringComparison.Ordinal))
        {
            return;
        }

        if (IsSkipFieldsNotMatchingTypeEnabled(invocation))
            return;

        // Direction is: Source (argument record) -> Target (invocation instance / implicit record)
        var sourceTable = TryResolveSymbolFromArgument(invocation) as ITableTypeSymbol;
        var targetTable =
            invocation.Instance?.Type.OriginalDefinition as ITableTypeSymbol
            ?? ctx.ContainingSymbol.GetContainingApplicationObjectTypeSymbol()?.OriginalDefinition as ITableTypeSymbol;

        if (sourceTable is null || targetTable is null)
            return;

        var sourceName = sourceTable.Name;
        var sourceNamespace = GetQualifiedNamespace(sourceTable);

        var targetName = targetTable.Name;
        var targetNamespace = GetQualifiedNamespace(targetTable);

        // Skip self-relations (same source and target)
        if (string.Equals(sourceName, targetName, StringComparison.Ordinal) &&
            string.Equals(sourceNamespace ?? string.Empty, targetNamespace ?? string.Empty, StringComparison.Ordinal))
        {
            return;
        }

        var containingMethod =
            ctx.ContainingSymbol as IMethodSymbol
            ?? ctx.ContainingSymbol.GetContainingObjectTypeSymbol() as IMethodSymbol;

        var containingObject = ctx.ContainingSymbol.GetContainingApplicationObjectTypeSymbol();

        var moduleInfo = ctx.Compilation.ModuleInfo;

        var record = new RelationJsonlRecord(
            Relation: new RelationRecord(
                Source: sourceTable.Name,
                SourceNamespace: GetQualifiedNamespace(sourceTable),
                SourceObjectId: sourceTable.Id,
                Target: targetTable.Name,
                TargetNamespace: GetQualifiedNamespace(targetTable),
                TargetObjectId: targetTable.Id,
                FoundInObjectQualified: BuildQualifiedObjectName(
                    containingObject is null ? null : GetQualifiedNamespace(containingObject),
                    containingObject?.Name),
                FoundInMethod: containingMethod?.Name),
            AppId: moduleInfo.AppId,
            ExtensionName: moduleInfo.Name,
            Publisher: moduleInfo.Publisher,
            Version: moduleInfo.Version.ToString());

        WriteRecord(ctx.Compilation, record);
    }

    private static void WriteRecord(Compilation compilation, RelationJsonlRecord record)
    {
        var compilationId = CompilationIds.GetValue(
            compilation,
            _ => Guid.NewGuid().ToString("N"));

        var root = Path.Combine(
            Path.GetTempPath(),
            "ALCops",
            "TransferFields",
            compilationId);

        Directory.CreateDirectory(root);

        var file = Path.Combine(root, "relations.jsonl");

        var json = JsonSerializer.Serialize(record, JsonOptions);

        File.AppendAllText(file, json + Environment.NewLine);
    }

    private static bool IsSkipFieldsNotMatchingTypeEnabled(IInvocationExpression invocation)
    {
        if (invocation.Arguments.Length < 3)
            return false;

        var constant = invocation.Arguments[2].Value.ConstantValue;
        return constant.HasValue && constant.Value is true;
    }

    private static ISymbol? TryResolveSymbolFromArgument(IInvocationExpression invocation)
    {
        if (invocation.Arguments.Length < 1)
            return null;

        var value = invocation.Arguments[0].Value;

        if (value is IConversionExpression conv)
            return conv.Operand.Type?.OriginalDefinition;

        return value.Type?.OriginalDefinition;
    }

    private static string? GetQualifiedNamespace(ISymbol symbol)
    {
        var ns = symbol.ContainingNamespace?.QualifiedName;
        return string.IsNullOrWhiteSpace(ns) ? null : ns;
    }

    private static string? BuildQualifiedObjectName(string? ns, string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
            return null;

        if (string.IsNullOrWhiteSpace(ns))
            return name;

        return ns + "." + name;
    }

    private sealed record RelationJsonlRecord(
        RelationRecord Relation,
        Guid AppId,
        string? ExtensionName,
        string? Publisher,
        string? Version);

    private sealed record RelationRecord(
        string Source,
        string? SourceNamespace,
        int SourceObjectId,
        string Target,
        string? TargetNamespace,
        int TargetObjectId,
        string? FoundInObjectQualified,
        string? FoundInMethod);
}
