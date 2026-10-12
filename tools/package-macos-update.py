#!/usr/bin/env python3
"""Produce the updater's single .app ZIP, preserving executable modes, without __MACOSX files."""
import argparse, pathlib, subprocess, zipfile, json, hashlib
parser=argparse.ArgumentParser()
parser.add_argument('app',type=pathlib.Path)
parser.add_argument('output',type=pathlib.Path)
args=parser.parse_args()
app=args.app.resolve()
if app.name!='RemoteScreen.app' or not app.is_dir(): raise SystemExit('Expected RemoteScreen.app')
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
version=json.loads((app/'Contents/Resources/update-version.json').read_text())
if args.output.exists(): raise SystemExit('Output exists; choose a new output path')
with zipfile.ZipFile(args.output,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_symlink(): raise SystemExit('Unsupported symlink: '+str(path))
        archive.write(path,path.relative_to(app.parent).as_posix())
sha=hashlib.sha256()
with args.output.open('rb') as source:
    for block in iter(lambda:source.read(1024*1024),b''):sha.update(block)
print(json.dumps({'file':str(args.output.resolve()),**version,'sha256':sha.hexdigest(),'sizeBytes':args.output.stat().st_size},ensure_ascii=False))
