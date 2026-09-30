# Edge agreement (agreement)

Gantry: `2761173a2fb925e6c5397c1117b531172633f381` (dirty: False).

| Language / rival | Agreed | Gantry only | Rival only |
|---|---:|---:|---:|
| typescript / madge | 50508 | 0 | 0 |
| typescript / dependency-cruiser | 50479 | 29 | 29 |
| python / pydeps | 4605 | 705 | 1 |
| python / grimp | 3002 | 0 | 0 |
| go / go-list | 7113 | 0 | 0 |
| rust / cargo-modules | 115 | 0 | 42 |
| zig / none | — | 996 total edges | — |

## typescript

Scope: `src`, 4323 selected files.

### madge

agreed: 50508; sample:

- `src/bootstrap-esm.ts` → `src/bootstrap-meta.ts`
- `src/bootstrap-esm.ts` → `src/bootstrap-node.ts`
- `src/bootstrap-esm.ts` → `src/vs/base/common/performance.ts`
- `src/bootstrap-esm.ts` → `src/vs/nls.ts`
- `src/bootstrap-fork.ts` → `src/bootstrap-esm.ts`

gantry_only: 0; sample:


rival_only: 0; sample:



Unexplained edges requiring review: 0.

### dependency-cruiser

agreed: 50479; sample:

- `src/bootstrap-esm.ts` → `src/bootstrap-meta.ts`
- `src/bootstrap-esm.ts` → `src/bootstrap-node.ts`
- `src/bootstrap-esm.ts` → `src/vs/base/common/performance.ts`
- `src/bootstrap-esm.ts` → `src/vs/nls.ts`
- `src/bootstrap-fork.ts` → `src/bootstrap-esm.ts`

gantry_only: 29; sample:

- `src/vs/base/browser/dom.ts` → `src/vs/base/browser/dompurify/dompurify.d.ts`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/browser/dompurify/dompurify.d.ts`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/common/marked/marked.d.ts`
- `src/vs/base/browser/ui/button/button.ts` → `src/vs/base/browser/dompurify/dompurify.d.ts`
- `src/vs/base/test/browser/markdownRenderer.test.ts` → `src/vs/base/common/marked/marked.d.ts`

rival_only: 29; sample:

- `src/vs/base/browser/dom.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/browser/markdownRenderer.ts` → `src/vs/base/common/marked/marked.js`
- `src/vs/base/browser/ui/button/button.ts` → `src/vs/base/browser/dompurify/dompurify.js`
- `src/vs/base/test/browser/markdownRenderer.test.ts` → `src/vs/base/common/marked/marked.js`

- rival policy: dependency-cruiser prefers the runtime .js over TypeScript's .d.ts substitution: 58

Unexplained edges requiring review: 0.

## python

Scope: `django`, 879 selected files.

### pydeps

agreed: 4605; sample:

- `django/__init__.py` → `django/__init__.py`
- `django/__init__.py` → `django/apps/__init__.py`
- `django/__init__.py` → `django/conf/__init__.py`
- `django/__init__.py` → `django/urls/__init__.py`
- `django/__init__.py` → `django/utils/log.py`

gantry_only: 705; sample:

- `django/__init__.py` → `django/utils/__init__.py`
- `django/__main__.py` → `django/core/__init__.py`
- `django/apps/config.py` → `django/core/__init__.py`
- `django/apps/config.py` → `django/utils/__init__.py`
- `django/apps/registry.py` → `django/core/__init__.py`

rival_only: 1; sample:

- `django/db/migrations/__init__.py` → `django/db/migrations/operations/base.py`

- rival policy: pydeps default noise filter removes high-degree packages: 577
- rival limit: pydeps skips migration discovery in its dummy entry module: 128
- rival policy: pydeps star discovery includes submodules absent from literal __all__: 1

Unexplained edges requiring review: 0.

### grimp

agreed: 3002; sample:

- `django/__init__.py` → `django/apps/__init__.py`
- `django/__init__.py` → `django/conf/__init__.py`
- `django/__init__.py` → `django/urls/__init__.py`
- `django/__init__.py` → `django/utils/log.py`
- `django/__init__.py` → `django/utils/version.py`

gantry_only: 0; sample:


rival_only: 0; sample:



Unexplained edges requiring review: 0.

## go

Scope: `pkg`, 8145 selected files.

### go-list

agreed: 7113; sample:

- `pkg/api/endpoints/testing` → `pkg/apis/core`
- `pkg/api/endpoints/testing` → `staging/src/k8s.io/apimachinery/pkg/apis/meta/v1`
- `pkg/api/job` → `pkg/api/pod`
- `pkg/api/job` → `pkg/apis/batch`
- `pkg/api/job` → `pkg/apis/core`

gantry_only: 0; sample:


rival_only: 0; sample:



Unexplained edges requiring review: 0.

## rust

Scope: `crates/ide/src`, 74 selected files.

### cargo-modules

agreed: 115; sample:

- `ide` → `ide::annotations`
- `ide` → `ide::call_hierarchy`
- `ide` → `ide::doc_links`
- `ide` → `ide::expand_macro`
- `ide` → `ide::extend_selection`

gantry_only: 0; sample:


rival_only: 42; sample:

- `ide::annotations` → `ide::navigation_target`
- `ide::call_hierarchy` → `ide`
- `ide::call_hierarchy` → `ide::navigation_target`
- `ide::goto_declaration` → `ide`
- `ide::goto_definition` → `ide`

- scope: semantic definitions, re-exports and type dependencies are outside gantry resolution: 42

Unexplained edges requiring review: 0.

## zig

Scope: `lib/std`, 565 selected files.

Gantry edge sample:

- `lib/std/Build.zig` → `lib/std/Build/Cache.zig`
- `lib/std/Build.zig` → `lib/std/Build/Fuzz.zig`
- `lib/std/Build.zig` → `lib/std/Build/Module.zig`
- `lib/std/Build.zig` → `lib/std/Build/Step.zig`
- `lib/std/Build.zig` → `lib/std/Build/Watch.zig`

Agreement only; no benchmark timings.
