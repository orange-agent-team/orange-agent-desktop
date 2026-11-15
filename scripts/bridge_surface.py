"""Explicit generated module/DTO/command allowlist; no implicit Host exports."""
import re

def verify_surface(root, app, contract):
    modules={'host':{'classes':contract['public_classes'],'functions':contract['public_functions']},**contract.get('additional_public_modules',{})}
    generated=app/'lib/src/rust'
    allowed={'frb_generated.dart','frb_generated.io.dart','frb_generated.web.dart'}|{'api/'+name+'.dart' for name in modules}
    actual={p.relative_to(generated).as_posix() for p in generated.rglob('*.dart')}
    if actual!=allowed:raise SystemExit('Unreviewed generated module inventory: '+str(sorted(actual^allowed)))
    for name,expected in modules.items():
        source=(generated/'api'/(name+'.dart')).read_text()
        classes=sorted(re.findall(r'^(?:abstract )?class (\w+)',source,re.M))
        functions=sorted(re.findall(r'^Future<[^\n]+> (\w+)\(',source,re.M))
        if classes!=sorted(expected['classes']) or functions!=sorted(expected['functions']):
            raise SystemExit('Unreviewed FRB surface in '+name+': '+str({'classes':classes,'functions':functions}))
    expected_sources={'mod.rs'}|{name+'.rs' for name in modules}
    actual_sources={p.relative_to(root/'crates/desktop-bridge/src/api').as_posix() for p in (root/'crates/desktop-bridge/src/api').rglob('*.rs')}
    if actual_sources!=expected_sources:raise SystemExit('Unreviewed Rust API module inventory')
