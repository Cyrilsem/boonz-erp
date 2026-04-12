"""
This supabase/ directory is a Supabase CLI project folder (migrations, functions, etc.).
This __init__.py proxies to the installed supabase PyPI package so that
``from supabase import create_client, Client`` works when Python is run from
the repo root (where this directory would otherwise shadow the real package).
"""
import sys
import os
import types
import importlib.util

_this_dir = os.path.dirname(os.path.abspath(__file__))
_parent_dir = os.path.dirname(_this_dir)

# Find the real supabase package in site-packages (skip this directory)
_real_pkg_dir: str | None = None
_real_init: str | None = None
for _p in sys.path:
    if os.path.abspath(_p) == _parent_dir:
        continue  # skip the repo root containing this proxy
    _candidate_dir = os.path.join(_p, "supabase")
    _candidate_init = os.path.join(_candidate_dir, "__init__.py")
    if (os.path.isfile(_candidate_init)
            and os.path.abspath(_candidate_dir) != _this_dir):
        _real_pkg_dir = _candidate_dir
        _real_init = _candidate_init
        break

if _real_init is None or _real_pkg_dir is None:
    raise ImportError(
        "supabase/__init__.py proxy: cannot find the real supabase PyPI package. "
        "Install it with: pip install supabase"
    )

# Build a fresh module that will become the real "supabase" package.
# Setting __path__ to the real directory is what makes relative imports
# (e.g. ``from ._async.client import …``) resolve correctly.
_real_mod = types.ModuleType("supabase")
_real_mod.__file__ = _real_init
_real_mod.__package__ = "supabase"
_real_mod.__path__ = [_real_pkg_dir]  # type: ignore[assignment]
_real_mod.__spec__ = importlib.util.spec_from_file_location(
    "supabase",
    _real_init,
    submodule_search_locations=[_real_pkg_dir],
)

# Replace ourselves in sys.modules BEFORE executing the real __init__.py so
# that absolute ``from supabase.X import Y`` imports inside supabase's own
# submodules resolve to this new module (which has the correct __path__).
sys.modules["supabase"] = _real_mod

with open(_real_init) as _fh:
    exec(compile(_fh.read(), _real_init, "exec"), _real_mod.__dict__)
