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
