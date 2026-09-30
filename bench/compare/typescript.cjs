// Keep installation and loader configuration outside the corpus.
const path = require('node:path');
const fs = require('node:fs');
const [tool, scratch, repo, scope] = process.argv.slice(2);
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
