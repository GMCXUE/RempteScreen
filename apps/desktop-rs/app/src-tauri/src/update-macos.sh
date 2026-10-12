#!/bin/sh
# All paths are positional arguments from the verified native updater.
set -eu
pid="$1"
installed="$2"
stage="$3"
backup="${installed}.before-update"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then exit 1; fi
  sleep 1
done
# Never replace an existing backup blindly.
if [ -e "$backup" ]; then backup="${backup}.$(date +%s)"; fi
mv "$installed" "$backup"
if mv "$stage/RemoteScreen.app" "$installed"; then
  rmdir "$stage" || true
  /usr/bin/open "$installed" || true
else
  mv "$backup" "$installed"
  /usr/bin/open "$installed" || true
  exit 1
fi
