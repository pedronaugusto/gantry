// Node-side comparisons, with the same output rows as bench/ops.
// `performance.now()` counts from process start, so node's own boot, module
// loading and the analysis are reported apart.
const booted = performance.now();
const path = require('node:path');
const fs = require('node:fs');
const [workload, scratch, arg] = process.argv.slice(2);
const smoke = Boolean(process.env.BENCH_SMOKE);
const row = (side, metric, value, unit) => process.stdout.write(`${side}\t${workload}\t${metric}\t${value}\t${unit}\n`);
const phases = (side, loaded, analysed) => {
  if (smoke) return;
  row(side, 'boot_ms', booted.toFixed(3), 'ms');
  row(side, 'import_ms', (loaded - booted).toFixed(3), 'ms');
  row(side, 'analysis_ms', (analysed - loaded).toFixed(3), 'ms');
};

if (workload === 'imports/javascript') {
  // TypeScript's own import scanner: preProcessFile lists import, export,
  // require and dynamic import specifiers without building a full program.
  const ts = require(path.join(scratch, 'npm/node_modules/typescript'));
  const text = fs.readFileSync(arg, 'utf8');
  const op = () => ts.preProcessFile(text, true, true).importedFiles.length;
  let count = op();
  if (smoke) row('typescript', 'ns_per_op', 0, 'ns');
  else {
    let iterations = 0;
    const start = process.hrtime.bigint();
    while (iterations < 3 || process.hrtime.bigint() - start < 200_000_000n) { count = op(); iterations++; }
    row('typescript', 'ns_per_op', (Number(process.hrtime.bigint() - start) / iterations).toFixed(3), 'ns');
    row('typescript', 'iterations', iterations, 'iterations');
  }
  row('typescript', 'source', Buffer.byteLength(text), 'bytes');
  row('typescript', 'imports', count, 'count');
} else if (workload === 'kinds/javascript') {
  // The TypeScript compiler's syntax tree: an import or re-export brings in
  // types alone when the clause says `type`, or its every named binding
  // does with no default; import("x") in a type is an ImportTypeNode; any
  // other import("x") call is dynamic. dependency-cruiser reads the same.
  const ts = require(path.join(scratch, 'npm/node_modules/typescript'));
  const text = fs.readFileSync(arg, 'utf8');
  const typeOnlyImport = (clause) => clause && (clause.isTypeOnly || (!clause.name && clause.namedBindings
    && ts.isNamedImports(clause.namedBindings) && clause.namedBindings.elements.length > 0
    && clause.namedBindings.elements.every(e => e.isTypeOnly)));
  const typeOnlyExport = (node) => node.isTypeOnly || (node.exportClause && ts.isNamedExports(node.exportClause)
    && node.exportClause.elements.length > 0 && node.exportClause.elements.every(e => e.isTypeOnly));
  const op = () => {
    const counts = {static: 0, type_only: 0, dynamic: 0};
    const visit = (node) => {
      if (ts.isImportDeclaration(node)) counts[typeOnlyImport(node.importClause) ? 'type_only' : 'static']++;
      else if (ts.isExportDeclaration(node) && node.moduleSpecifier) counts[typeOnlyExport(node) ? 'type_only' : 'static']++;
      else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) counts[node.isTypeOnly ? 'type_only' : 'static']++;
      else if (ts.isImportTypeNode(node)) counts.type_only++;
      else if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) counts.dynamic++;
      ts.forEachChild(node, visit);
    };
    visit(ts.createSourceFile('kinds.ts', text, ts.ScriptTarget.Latest, false, ts.ScriptKind.TS));
    return counts;
  };
  let counts = op();
  if (smoke) row('typescript', 'ns_per_op', 0, 'ns');
  else {
    let iterations = 0;
    const start = process.hrtime.bigint();
    while (iterations < 3 || process.hrtime.bigint() - start < 200_000_000n) { counts = op(); iterations++; }
    row('typescript', 'ns_per_op', (Number(process.hrtime.bigint() - start) / iterations).toFixed(3), 'ns');
    row('typescript', 'iterations', iterations, 'iterations');
  }
  row('typescript', 'source', Buffer.byteLength(text), 'bytes');
  for (const kind of ['static', 'type_only', 'dynamic']) row('typescript', kind, counts[kind], 'count');
} else if (workload === 'process/metrics-js') {
  // dependency-cruiser's --metrics over the corpus's js tree: distinct
  // dependencies between two modules (itself aside), and its folders'
  // efferent couplings.
  (async () => {
    const {cruise} = await import(path.join(scratch, 'npm/node_modules/dependency-cruiser/src/main/index.mjs'));
    const loaded = performance.now();
    const result = await cruise(['js'], {baseDir: arg, metrics: true, outputType: 'json', tsPreCompilationDeps: true});
    const output = JSON.parse(result.output);
    const analysed = performance.now();
    let fanOut = 0;
    for (const module of output.modules) fanOut += new Set(module.dependencies.map(d => d.resolved).filter(r => r !== module.source)).size;
    const folders = output.folders || [];
    phases('dependency-cruiser', loaded, analysed);
    row('dependency-cruiser', 'files', output.modules.length, 'count');
    row('dependency-cruiser', 'folders', folders.length, 'count');
    row('dependency-cruiser', 'fan_out', fanOut, 'count');
    row('dependency-cruiser', 'folder_fan_in', folders.reduce((sum, f) => sum + f.afferentCouplings, 0), 'count');
    row('dependency-cruiser', 'folder_fan_out', folders.reduce((sum, f) => sum + f.efferentCouplings, 0), 'count');
  })().catch(error => { console.error(error); process.exitCode = 1; });
} else if (workload === 'process/reach-js') {
  // dependency-cruiser's `reachable: true` forbidden rule: every f9 module a
  // chain leads from to an f1 module.
  (async () => {
    const {cruise} = await import(path.join(scratch, 'npm/node_modules/dependency-cruiser/src/main/index.mjs'));
    const loaded = performance.now();
    const result = await cruise(['js'], {
      baseDir: arg, validate: true, outputType: 'json', tsPreCompilationDeps: true,
      ruleSet: {forbidden: [{name: 'far', severity: 'error',
        from: {path: '^js/g[0-9]+/f9[.]ts$'}, to: {path: '^js/g[0-9]+/f1[.]ts$', reachable: true}}]}
    });
    const output = JSON.parse(result.output);
    const analysed = performance.now();
    const sources = new Set(output.summary.violations.map(v => v.from));
    phases('dependency-cruiser', loaded, analysed);
    row('dependency-cruiser', 'files', output.modules.length, 'count');
    row('dependency-cruiser', 'findings', sources.size, 'count');
  })().catch(error => { console.error(error); process.exitCode = 1; });
} else if (workload === 'process/check-js') {
  // dependency-cruiser validating one forbidden rule over the corpus's js tree.
  (async () => {
    const {cruise} = await import(path.join(scratch, 'npm/node_modules/dependency-cruiser/src/main/index.mjs'));
    const loaded = performance.now();
    const result = await cruise(['js'], {
      baseDir: arg, validate: true, outputType: 'json', tsPreCompilationDeps: true,
      ruleSet: {forbidden: [{name: 'forbid', severity: 'error',
        from: {path: '^js/g[0-9]+/f5[.]ts$'}, to: {path: '^js/g[0-9]+/f4[.]ts$'}}]}
    });
    const output = JSON.parse(result.output);
    const analysed = performance.now();
    const pairs = new Set(output.summary.violations.map(v => v.from + '\t' + v.to));
    phases('dependency-cruiser', loaded, analysed);
    row('dependency-cruiser', 'files', output.modules.length, 'count');
    row('dependency-cruiser', 'findings', pairs.size, 'count');
  })().catch(error => { console.error(error); process.exitCode = 1; });
} else {
  console.error(`unknown workload ${workload}`);
  process.exitCode = 2;
}
