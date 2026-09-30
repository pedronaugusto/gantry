# Edge agreement (smoke)

Gantry: `a02e572b06d7d45bd61c22d74f79730aec1a3b3b` (dirty: False).

| Language / rival | Agreed | Gantry only | Rival only |
|---|---:|---:|---:|
| python / pydeps | 65 | 28 | 0 |
| python / grimp | 63 | 30 | 0 |

## python

Scope: `django/utils`, 46 selected files.

### pydeps

agreed: 65; sample:

- `django/utils/autoreload.py` → `django/utils/functional.py`
- `django/utils/autoreload.py` → `django/utils/version.py`
- `django/utils/cache.py` → `django/utils/http.py`
- `django/utils/cache.py` → `django/utils/log.py`
- `django/utils/cache.py` → `django/utils/regex_helper.py`

gantry_only: 28; sample:

- `django/utils/autoreload.py` → `django/utils/__init__.py`
- `django/utils/cache.py` → `django/utils/__init__.py`
- `django/utils/choices.py` → `django/utils/__init__.py`
- `django/utils/connection.py` → `django/utils/__init__.py`
- `django/utils/crypto.py` → `django/utils/__init__.py`

rival_only: 0; sample:


- scope: gantry includes selected ancestor/package initializers: 28

Unexplained edges requiring review: 0.

### grimp

agreed: 63; sample:

- `django/utils/autoreload.py` → `django/utils/functional.py`
- `django/utils/autoreload.py` → `django/utils/version.py`
- `django/utils/cache.py` → `django/utils/http.py`
- `django/utils/cache.py` → `django/utils/log.py`
- `django/utils/cache.py` → `django/utils/regex_helper.py`

gantry_only: 30; sample:

- `django/utils/autoreload.py` → `django/utils/__init__.py`
- `django/utils/cache.py` → `django/utils/__init__.py`
- `django/utils/choices.py` → `django/utils/__init__.py`
- `django/utils/connection.py` → `django/utils/__init__.py`
- `django/utils/crypto.py` → `django/utils/__init__.py`

rival_only: 0; sample:


- scope: gantry includes selected ancestor/package initializers: 30

Unexplained edges requiring review: 0.

No benchmark timings. Smoke samples prove instrumentation only.
