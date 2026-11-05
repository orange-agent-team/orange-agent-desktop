#!/usr/bin/env python3
"""Native Assets compile-time binding, never a model-supplied executable policy."""
from model_bundle import STAGED, digest, verify_bundle
if STAGED.is_symlink():
    raise SystemExit('Linked model bundle refused')
if STAGED.exists():
    verify_bundle(STAGED)
    print(digest(STAGED / 'manifest.json'))
else:
    print('not-packaged')
