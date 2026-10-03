// Keep installation and loader configuration outside the corpus.
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
  require(path.join(scratch, 'npm/node_modules/madge'))(path.join(repo, scope), {
    baseDir: repo, fileExtensions: ['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts'], tsConfig: config,
    detectiveOptions: {ts: {skipTypeImports: false}, tsx: {skipTypeImports: false}}
  }).then(result => process.stdout.write(JSON.stringify({graph: result.obj(), warnings: result.warnings()})))
    .catch(error => { console.error(error); process.exitCode = 1; });
} else {
  (async () => {
    const {cruise} = await import(path.join(scratch, 'npm/node_modules/dependency-cruiser/src/main/index.mjs'));
    const result = await cruise([scope], {
      baseDir: repo, outputType: 'json', tsPreCompilationDeps: true,
      doNotFollow: {path: 'node_modules'}, exclude: {path: 'node_modules'},
      ruleSet: {forbidden: [], options: {tsConfig: {fileName: config}}}
    }, {tsConfig: config}, {tsConfig: {options: {baseUrl: path.join(repo, 'src')}}});
    process.stdout.write(result.output);
  })().catch(error => {console.error(error); process.exitCode = 1;});
}
