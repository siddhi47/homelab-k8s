#!/usr/bin/env bash
# Export or restore the half of Open WebUI's configuration that lives in its
# database rather than in the Kubernetes manifest.
#
# Open WebUI keeps nearly all settings in a `config` key/value table inside
# webui.db: model endpoints, tool servers, image generation, task models, web
# search. Environment variables only SEED these on first boot and are ignored
# afterwards. Applying the manifest alone therefore yields an empty install.
#
#   ./open-webui-config.sh export                 # redacted, safe to commit
#   ./open-webui-config.sh export --with-secrets  # full, DO NOT COMMIT
#   ./open-webui-config.sh restore <file.json>
#
# Redaction blanks any key whose name looks like a credential. A redacted export
# is a faithful record of structure and non-secret values; restoring it will not
# reinstate API keys, which must be set again afterwards.

set -euo pipefail

DEPLOY=${DEPLOY:-open-webui}
NS=${NS:-default}
ACTION=${1:-export}
SECRET_RE='(api_key|apikey|token|secret|password|passwd|credential)'

pod() {
  kubectl -n "$NS" get pods --no-headers \
    | awk -v d="$DEPLOY" '$0 ~ d && $3=="Running" {print $1; exit}'
}

P=$(pod)
[ -n "$P" ] || { echo "error: no running $DEPLOY pod in namespace $NS" >&2; exit 1; }

case "$ACTION" in
  export)
    WITH_SECRETS=0
    [ "${2:-}" = "--with-secrets" ] && WITH_SECRETS=1
    OUT=${OUT:-open-webui-config$([ $WITH_SECRETS = 1 ] && echo '-secrets').json}
    kubectl -n "$NS" exec "$P" -- python3 -c "
import sqlite3, json, re, sys
keep_secrets = ${WITH_SECRETS}
rx = re.compile(r'${SECRET_RE}', re.I)
c = sqlite3.connect('/app/backend/data/webui.db')
out, redacted = {}, 0
for k, v in c.execute('select key, value from config order by key'):
    if not keep_secrets and rx.search(k):
        try:    parsed = json.loads(v) if isinstance(v, str) else v
        except Exception: parsed = v
        if isinstance(parsed, str) and parsed:
            v = json.dumps('__REDACTED__'); redacted += 1
    out[k] = v
json.dump(out, sys.stdout, indent=2)
sys.stderr.write(f'{len(out)} keys, {redacted} redacted\n')
" > "$OUT" 2>/tmp/owcfg.err
    cat /tmp/owcfg.err >&2
    echo "wrote $OUT"
    [ $WITH_SECRETS = 1 ] && echo "WARNING: contains credentials - do not commit" >&2
    ;;

  restore)
    FILE=${2:?usage: $0 restore <file.json>}
    [ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }
    echo "Restoring config into $P ..."
    kubectl -n "$NS" exec -i "$P" -- python3 -c "
import sqlite3, json, sys, time
data = json.load(sys.stdin)
c = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time()); n = skipped = 0
for k, v in data.items():
    try:
        if json.loads(v) == '__REDACTED__':
            skipped += 1; continue
    except Exception:
        pass
    c.execute('insert into config(key,value,updated_at) values(?,?,?) '
              'on conflict(key) do update set value=excluded.value, updated_at=excluded.updated_at',
              (k, v, now))
    n += 1
c.commit()
print(f'restored {n} keys, skipped {skipped} redacted')
" < "$FILE"
    echo "Restart required for PersistentConfig to reload:"
    echo "  kubectl -n $NS rollout restart deploy/$DEPLOY"
    ;;

  *) echo "usage: $0 {export [--with-secrets] | restore <file.json>}" >&2; exit 1 ;;
esac
