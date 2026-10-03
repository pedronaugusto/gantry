// Keep installation and loader configuration outside the corpus.
// performance.now() counts from process start: with BENCH_PHASES set, node's
// boot, module loading, analysis and output go to stderr apart.
const booted = performance.now();
const marks = [];
const mark = name => marks.push([name, performance.now()]);
const report = () => {
  if (!process.env.BENCH_PHASES) return;
  let last = 0;
  for (const [name, at] of [['boot', booted], ...marks]) { process.stderr.write(`PHASE\t${name}\t${(at - last).toFixed(3)}\n`); last = at; }
};
const path = require('node:path');
const fs = require('node:fs');
const [tool, scratch, repo, scope] = process.argv.slice(2);
if (tool === 'resolve') {
  // Witness only: TypeScript's own answer for one importer and specifier,
  // under the repository config nearest the importer.
  const ts = require(path.join(scratch, 'npm/node_modules/typescript'));
  const [, , , , importer, specifier] = process.argv.slice(2);
  const file = path.join(repo, importer);
  const found = ts.findConfigFile(path.dirname(file), ts.sys.fileExists);
  const options = found ? ts.parseJsonConfigFileContent(ts.readConfigFile(found, ts.sys.readFile).config, ts.sys, path.dirname(found)).options : {};
  const resolved = ts.resolveModuleName(specifier, file, options, ts.sys).resolvedModule;
  process.stdout.write(JSON.stringify({version: ts.version, config: found ? path.relative(repo, found) : null,
    resolved: resolved ? path.relative(repo, resolved.resolvedFileName) : null}));
  return;
}
const config = path.join(scratch, 'typescript-config.json');
fs.writeFileSync(config, JSON.stringify({compilerOptions: {baseUrl: path.join(repo, 'src'), moduleResolution: 'node', allowJs: true}}));
if (tool === 'madge') {
  const madge = require(path.join(scratch, 'npm/node_modules/madge'));
  mark('import');
  madge(path.join(repo, scope), {
    baseDir: repo, fileExtensions: ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts'], tsConfig: config,
    detectiveOptions: {ts: {skipTypeImports: false}, tsx: {skipTypeImports: false}}
  }).then(result => { mark('analysis'); process.stdout.write(JSON.stringify({graph: result.obj(), warnings: result.warnings()})); mark('output'); report(); })
    .catch(error => { console.error(error); process.exitCode = 1; });
} else {
  (async () => {
    const {cruise} = await import(path.join(scratch, 'npm/node_modules/dependency-cruiser/src/main/index.mjs'));
    mark('import');
    const result = await cruise([scope], {
      baseDir: repo, outputType: 'json', tsPreCompilationDeps: true,
      doNotFollow: {path: 'node_modules'}, exclude: {path: 'node_modules'},
      ruleSet: {forbidden: [], options: {tsConfig: {fileName: config}}}
    }, {tsConfig: config}, {tsConfig: {options: {baseUrl: path.join(repo, 'src')}}});
    mark('analysis');  // dependency-cruiser serializes its JSON inside cruise().
    process.stdout.write(result.output);
    mark('output');
    report();
  })().catch(error => {console.error(error); process.exitCode = 1;});
}
