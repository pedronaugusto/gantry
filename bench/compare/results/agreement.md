# Edge agreement (agreement)

Gantry: `a02e572b06d7d45bd61c22d74f79730aec1a3b3b` (dirty: False).

| Language / rival | Agreed | Gantry only | Rival only |
|---|---:|---:|---:|
| typescript / madge | 50459 | 29 | 49 |
| typescript / dependency-cruiser | 50488 | 0 | 20 |
| python / pydeps | 4596 | 697 | 10 |
| python / grimp | 3002 | 2291 | 0 |
| go / go-list | 2600 | 677 | 4513 |
| rust / cargo-modules | 126 | 32 | 31 |
| zig / none | — | 996 total edges | — |

## typescript

Scope: `src`, 4323 selected files.

### madge

agreed: 50459; sample:

- `src/bootstrap-esm.ts` → `src/bootstrap-meta.ts`
- `src/bootstrap-esm.ts` → `src/bootstrap-node.ts`
- `src/bootstrap-esm.ts` → `src/vs/base/common/performance.ts`
- `src/bootstrap-esm.ts` → `src/vs/nls.ts`
- `src/bootstrap-fork.ts` → `src/bootstrap-esm.ts`

gantry_only: 29; sample:

- `src/vs/base/browser/dom.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/common/marked/marked.js`
- `src/vs/base/browser/ui/button/button.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/test/browser/markdownRenderer.test.ts` → `src/vs/base/common/marked/marked.js`

rival_only: 49; sample:

- `src/bootstrap-window.ts` → `src/vs/base/parts/sandbox/common/sandboxTypes.ts`
- `src/bootstrap-window.ts` → `src/vs/platform/window/electron-sandbox/window.ts`
- `src/vs/base/browser/dom.ts` → `src/vs/base/browser/dompurify/dompurify.d.ts`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/browser/dompurify/dompurify.d.ts`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/common/marked/marked.d.ts`

- scope: gantry chooses exact runtime .js; madge chooses its .d.ts declaration: 29
- scope: tsconfig baseUrl aliases are not resolved by gantry: 12
- scope: declaration-file resolution is outside gantry's documented suffix order: 37

Unexplained edges requiring review: 0.

### dependency-cruiser

agreed: 50488; sample:

- `src/bootstrap-esm.ts` → `src/bootstrap-meta.ts`
- `src/bootstrap-esm.ts` → `src/bootstrap-node.ts`
- `src/bootstrap-esm.ts` → `src/vs/base/common/performance.ts`
- `src/bootstrap-esm.ts` → `src/vs/nls.ts`
- `src/bootstrap-fork.ts` → `src/bootstrap-esm.ts`

gantry_only: 0; sample:


rival_only: 20; sample:

- `src/bootstrap-window.ts` → `src/vs/base/parts/sandbox/common/sandboxTypes.ts`
- `src/bootstrap-window.ts` → `src/vs/platform/window/electron-sandbox/window.ts`
- `src/vs/base/parts/sandbox/electron-sandbox/preload.ts` → `src/vs/base/parts/sandbox/common/sandboxTypes.ts`
- `src/vs/code/electron-sandbox/processExplorer/processExplorer.ts` → `src/vs/code/electron-sandbox/processExplorer/processExplorerMain.ts`
- `src/vs/code/electron-sandbox/processExplorer/processExplorer.ts` → `src/vs/platform/process/common/process.ts`

- scope: tsconfig baseUrl aliases are not resolved by gantry: 12
- scope: declaration-file resolution is outside gantry's documented suffix order: 8

Unexplained edges requiring review: 0.

## python

Scope: `django`, 879 selected files.

### pydeps

agreed: 4596; sample:

- `django/__init__.py` → `django/__init__.py`
- `django/__init__.py` → `django/apps/__init__.py`
- `django/__init__.py` → `django/conf/__init__.py`
- `django/__init__.py` → `django/urls/__init__.py`
- `django/__init__.py` → `django/utils/log.py`

gantry_only: 697; sample:

- `django/__init__.py` → `django/utils/__init__.py`
- `django/__main__.py` → `django/core/__init__.py`
- `django/apps/config.py` → `django/core/__init__.py`
- `django/apps/config.py` → `django/utils/__init__.py`
- `django/apps/registry.py` → `django/core/__init__.py`

rival_only: 10; sample:

- `django/contrib/auth/apps.py` → `django/contrib/__init__.py`
- `django/core/checks/async_checks.py` → `django/__init__.py`
- `django/db/migrations/__init__.py` → `django/db/migrations/operations/base.py`
- `django/db/migrations/__init__.py` → `django/db/migrations/operations/fields.py`
- `django/db/migrations/__init__.py` → `django/db/migrations/operations/models.py`

- scope: gantry includes selected ancestor/package initializers: 683
- rival limit: pydeps skips migrations when constructing its dummy entry module: 14
- scope: pydeps modulefinder records additional ancestors of relative imports: 6
- scope: pydeps follows star re-exported symbols; gantry records the literal imported module: 4

Unexplained edges requiring review: 0.

### grimp

agreed: 3002; sample:

- `django/__init__.py` → `django/apps/__init__.py`
- `django/__init__.py` → `django/conf/__init__.py`
- `django/__init__.py` → `django/urls/__init__.py`
- `django/__init__.py` → `django/utils/log.py`
- `django/__init__.py` → `django/utils/version.py`

gantry_only: 2291; sample:

- `django/__init__.py` → `django/__init__.py`
- `django/__init__.py` → `django/utils/__init__.py`
- `django/__main__.py` → `django/__init__.py`
- `django/__main__.py` → `django/core/__init__.py`
- `django/apps/config.py` → `django/__init__.py`

rival_only: 0; sample:


- scope: gantry includes selected ancestor/package initializers: 2291

Unexplained edges requiring review: 0.

## go

Scope: `pkg`, 8145 selected files.

### go-list

agreed: 2600; sample:

- `pkg/api/endpoints/testing` → `pkg/apis/core`
- `pkg/api/job` → `pkg/api/pod`
- `pkg/api/job` → `pkg/apis/batch`
- `pkg/api/job` → `pkg/apis/core`
- `pkg/api/node` → `pkg/apis/core`

gantry_only: 677; sample:

- `pkg/api/job` → `test/utils/ktesting`
- `pkg/api/storage` → `pkg/apis/core`
- `pkg/api/testing` → `pkg/api/pod`
- `pkg/api/testing` → `pkg/api/testing/compat`
- `pkg/api/testing` → `pkg/apis/apps/v1`

rival_only: 4513; sample:

- `pkg/api/endpoints/testing` → `staging/src/k8s.io/apimachinery/pkg/apis/meta/v1`
- `pkg/api/job` → `staging/src/k8s.io/apimachinery/pkg/util/validation/field`
- `pkg/api/legacyscheme` → `staging/src/k8s.io/apimachinery/pkg/runtime`
- `pkg/api/legacyscheme` → `staging/src/k8s.io/apimachinery/pkg/runtime/serializer`
- `pkg/api/node` → `staging/src/k8s.io/apimachinery/pkg/apis/meta/v1`

- scope: test files are selected by gantry and excluded by go list: 605
- scope: build/platform variants excluded by go list are selected by gantry: 72
- scope: go.mod replacements/workspace modules are not resolved by gantry: 4513

Unexplained edges requiring review: 0.

## rust

Scope: `crates/ide/src`, 74 selected files.

### cargo-modules

agreed: 126; sample:

- `ide` → `ide::annotations`
- `ide` → `ide::call_hierarchy`
- `ide` → `ide::doc_links`
- `ide` → `ide::expand_macro`
- `ide` → `ide::extend_selection`

gantry_only: 32; sample:

- `ide` → `ide::fixture`
- `ide::annotations` → `ide::fixture`
- `ide::annotations::fn_references` → `ide::fixture`
- `ide::call_hierarchy` → `ide::fixture`
- `ide::doc_links` → `ide::doc_links::tests`

rival_only: 31; sample:

- `ide::annotations` → `ide::navigation_target`
- `ide::call_hierarchy` → `ide`
- `ide::call_hierarchy` → `ide::navigation_target`
- `ide::goto_declaration` → `ide`
- `ide::goto_definition` → `ide`

- scope: test modules are selected by gantry and excluded by cargo-modules cfg: 32
- scope: semantic definitions, re-exports and type dependencies are outside gantry resolution: 31

Unexplained edges requiring review: 0.

## zig

Scope: `lib/std`, 565 selected files.

Gantry edge sample:

- `lib/std/Build.zig` → `lib/std/Build/Cache.zig`
- `lib/std/Build.zig` → `lib/std/Build/Fuzz.zig`
- `lib/std/Build.zig` → `lib/std/Build/Module.zig`
- `lib/std/Build.zig` → `lib/std/Build/Step.zig`
- `lib/std/Build.zig` → `lib/std/Build/Watch.zig`

No benchmark timings. Smoke samples prove instrumentation only.
