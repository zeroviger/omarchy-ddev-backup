#!/bin/bash

# Test end-to-end di bin/ddev-backup su progetti DDEV veri ma usa-e-getta.
#
# Richiede Docker e DDEV funzionanti. Crea due progetti temporanei
# (ddbt-<pid> e ddbt-<pid>-copia) sotto ~/.cache, usa una cartella di backup
# temporanea e cancella tutto alla fine, anche se un test fallisce.
# Non tocca i tuoi progetti né ~/Backups.
#
# Uso: test/run-tests.sh            (circa 2-3 minuti)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/ddev-backup"

TMP="$(mktemp -d "$HOME/.cache/ddev-backup-test.XXXXXX")"
NAME="ddbt-$$"
COPY="ddbt-$$-copia"
PG="ddbt-$$-pg"
PROJECT="$TMP/projects/$NAME"
BACKUPS="$TMP/backups"

# umask comune: i backup devono risultare privati anche così.
umask 022
export DDEV_BACKUP_CONFIG="$TMP/settings.json"
export DDEV_BACKUP_NOTIFY=0
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$XDG_RUNTIME_DIR"
# keep 0 = nessuna cancellazione automatica: la sezione "Conservazione" la
# attiva da sola, altrimenti lo zip di riferimento dei test verrebbe ruotato via.
echo "{\"backupDir\": \"$BACKUPS\", \"keep\": 0}" >"$DDEV_BACKUP_CONFIG"

PASSED=0
FAILED=0
FAILURES=()

cleanup() {
  ddev delete -Oy "$NAME" >/dev/null 2>&1
  ddev delete -Oy "$COPY" >/dev/null 2>&1
  ddev delete -Oy "$PG" >/dev/null 2>&1
  rm -rf -- "$TMP"
}
trap cleanup EXIT

pass() {
  PASSED=$((PASSED + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  FAILURES+=("$1")
  printf '  \033[31m✗ %s\033[0m\n' "$1"
  [[ -n ${2:-} ]] && printf '      %s\n' "$2"
}

# check <descrizione> <comando...>
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# check_eq <descrizione> <atteso> <ottenuto>
check_eq() {
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "atteso: $2 — ottenuto: $3"; fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# Una istruzione per chiamata: con -c più istruzioni girano in un'unica
# transazione, e CREATE/DROP DATABASE lì dentro non sono ammessi.
psql_in() {
  local dir="$1" db="$2"
  shift 2
  (cd "$dir" && ddev psql -d "$db" -qAt -c "$*" </dev/null 2>/dev/null)
}

pg_user_dbs() {
  psql_in "$1" postgres "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1" | xargs
}

sql() {
  local dir="$1"
  shift
  (cd "$dir" && ddev mysql -N -B -e "$*" 2>/dev/null)
}

last_backup() {
  find "$BACKUPS/$1" -maxdepth 1 -name '*.zip' ! -name '*-pre-restore.zip' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | tail -1 | cut -d' ' -f2-
}

run() {
  OUT="$("$CLI" "$@" 2>&1)"
  RC=$?
}

# ------------------------------------------------------------------ setup

section "Preparazione"
for dep in ddev docker jq bsdtar unzip; do
  command -v "$dep" >/dev/null || { echo "manca $dep"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker non è attivo"; exit 1; }

if command -v shellcheck >/dev/null; then
  check "shellcheck bin/ddev-backup" shellcheck "$CLI"
else
  echo "  - shellcheck non installato, salto il controllo statico"
fi

mkdir -p "$PROJECT/public" "$PROJECT/node_modules/pkg"
echo '<?php echo "originale";' >"$PROJECT/public/index.php"
echo 'APP_SECRET=s3cret' >"$PROJECT/.env"
echo 'module' >"$PROJECT/node_modules/pkg/index.js"
echo 'segreto.txt' >"$PROJECT/.ddev-backup-ignore"
echo 'non nel backup' >"$PROJECT/segreto.txt"
(cd "$PROJECT" && ddev config --project-name="$NAME" --project-type=php --docroot=public --database=mariadb:11.8 >/dev/null 2>&1 &&
  ddev start -y >/dev/null 2>&1) || { echo "ddev start fallito"; exit 1; }
printf 'node_modules/\n' >"$PROJECT/.gitignore"
git -C "$PROJECT" init -q -b main && git -C "$PROJECT" add -A &&
  git -C "$PROJECT" -c user.name=test -c user.email=test@example.com commit -qm iniziale ||
  { echo "git init fallito"; exit 1; }
sql "$PROJECT" "CREATE TABLE items(id INT PRIMARY KEY, name VARCHAR(50));
  INSERT INTO items VALUES (1,'alpha'),(2,'beta');
  CREATE DATABASE extra; CREATE TABLE extra.notes(id INT, txt TEXT);
  INSERT INTO extra.notes VALUES (1,'nota');"
pass "progetto $NAME avviato con i database db ed extra"

# ------------------------------------------------------------------ backup

section "Backup"
run backup "$NAME"
check_eq "backup termina con successo" 0 "$RC"
ZIP="$(last_backup "$NAME")"
check "lo zip esiste in backupDir/<progetto>/" test -f "$ZIP"
check_eq "lo zip è leggibile solo dal proprietario" 600 "$(stat -c %a "$ZIP")"
check_eq "la cartella del progetto è privata" 700 "$(stat -c %a "$BACKUPS/$NAME")"
check_eq "la cartella dei backup creata è privata" 700 "$(stat -c %a "$BACKUPS")"
LIST="$(bsdtar -tf "$ZIP" 2>/dev/null)"
check "contiene manifest.json" grep -qx 'manifest.json' <<<"$LIST"
check "contiene il dump di db" grep -qx 'database/db.sql.gz' <<<"$LIST"
check "contiene il dump di extra" grep -qx 'database/extra.sql.gz' <<<"$LIST"
check "contiene .env" grep -qx 'files/.env' <<<"$LIST"
check "contiene .ddev/config.yaml" grep -qx 'files/.ddev/config.yaml' <<<"$LIST"
check "esclude node_modules" bash -c "! grep -q '^files/node_modules' <<<\"\$1\"" _ "$LIST"
check "esclude i file generati da DDEV" bash -c "! grep -q '\.ddev-docker-compose' <<<\"\$1\"" _ "$LIST"
check "rispetta .ddev-backup-ignore" bash -c "! grep -q 'segreto.txt' <<<\"\$1\"" _ "$LIST"
check "il dump contiene i dati" bash -c "bsdtar -xOf \"\$1\" database/db.sql.gz | gunzip | grep -q alpha" _ "$ZIP"
MANIFEST="$("$CLI" inspect "$ZIP" 2>/dev/null)"
check_eq "manifest: nome progetto" "$NAME" "$(jq -r .project.name <<<"$MANIFEST")"
check_eq "manifest: tipo database" "mariadb" "$(jq -r .database.type <<<"$MANIFEST")"
check_eq "manifest: commit git" "$(git -C "$PROJECT" rev-parse HEAD)" "$(jq -r .git.commit <<<"$MANIFEST")"
check_eq "manifest: branch git" "main" "$(jq -r .git.branch <<<"$MANIFEST")"
check "manifest: sha256 corretti" bash -c '
  zip="$1"; m="$2"
  for db in $(jq -r ".database.databases[].name" <<<"$m"); do
    want=$(jq -r --arg d "$db" ".database.databases[] | select(.name==\$d) | .sha256" <<<"$m")
    got=$(bsdtar -xOf "$zip" "database/$db.sql.gz" | sha256sum | cut -d" " -f1)
    [[ $want == "$got" ]] || exit 1
  done' _ "$ZIP" "$MANIFEST"

section "Backup di un progetto fermo"
ddev stop "$NAME" >/dev/null 2>&1
run backup "$NAME"
check_eq "backup termina con successo" 0 "$RC"
check_eq "il progetto torna fermo" "stopped" "$(ddev describe -j "$NAME" 2>/dev/null | jq -r .raw.status)"
ddev start -y "$NAME" >/dev/null 2>&1

# ------------------------------------------------------------------ lock

section "Blocco delle operazioni concorrenti"
"$CLI" backup "$NAME" >/dev/null 2>&1 &
BG=$!
for _ in $(seq 50); do
  [[ -d $XDG_RUNTIME_DIR/ddev-backup/$NAME.lock ]] && break
  sleep 0.1
done
run backup "$NAME"
check_eq "un secondo backup in parallelo viene rifiutato" 1 "$RC"
check "con un messaggio chiaro" grep -q "già in corso" <<<"$OUT"
wait "$BG"
check_eq "il primo backup va comunque a buon fine" 0 "$?"
check "il lock viene rilasciato alla fine" test ! -e "$XDG_RUNTIME_DIR/ddev-backup/$NAME.lock"

mkdir -p "$XDG_RUNTIME_DIR/ddev-backup/$NAME.lock"
echo 999999 >"$XDG_RUNTIME_DIR/ddev-backup/$NAME.lock/pid"
run backup "$NAME"
check_eq "un lock abbandonato (processo morto) non blocca" 0 "$RC"

# ------------------------------------------------------------------ spazio

section "Spazio su disco"
before="$(find "$BACKUPS/$NAME" -name '*.zip' | wc -l)"
OUT="$(DDEV_BACKUP_TEST_AVAILABLE=1000 "$CLI" backup "$NAME" 2>&1)"
RC=$?
check_eq "backup rifiutato con disco pieno" 1 "$RC"
check "con un messaggio chiaro" grep -q "spazio insufficiente" <<<"$OUT"
check_eq "nessuno zip parziale lasciato" "$before" "$(find "$BACKUPS/$NAME" -name '*.zip*' | wc -l)"
check "nessuna cartella di lavoro lasciata" bash -c "! ls -A \"\$1\" | grep -q '^\.work-'" _ "$BACKUPS/$NAME"
check "il lock viene rilasciato" test ! -e "$XDG_RUNTIME_DIR/ddev-backup/$NAME.lock"

OUT="$(DDEV_BACKUP_TEST_AVAILABLE=1000 "$CLI" restore "$ZIP" --force 2>&1)"
RC=$?
check_eq "restore rifiutato con disco pieno" 1 "$RC"
check "il progetto non è stato toccato" test -f "$PROJECT/segreto.txt"

# ------------------------------------------------------------------ restore

section "Restore sul posto"
sql "$PROJECT" "DELETE FROM items WHERE id=1; UPDATE extra.notes SET txt='modificata'; CREATE DATABASE spuria;"
echo '<?php echo "modificato";' >"$PROJECT/public/index.php"
echo 'nuovo' >"$PROJECT/public/nuovo.txt"

run restore "$ZIP"
check_eq "senza --force viene rifiutato" 1 "$RC"

run restore "$ZIP" --force
check_eq "con --force termina con successo" 0 "$RC"
check_eq "dati di db ripristinati" "1 2" "$(sql "$PROJECT" 'SELECT id FROM items ORDER BY id' | xargs)"
check_eq "dati di extra ripristinati" "nota" "$(sql "$PROJECT" 'SELECT txt FROM extra.notes')"
check "database creato dopo il backup rimosso" bash -c "! (cd \"\$1\" && ddev mysql -N -e 'SHOW DATABASES' 2>/dev/null) | grep -qx spuria" _ "$PROJECT"
check "file ripristinati" grep -q originale "$PROJECT/public/index.php"
check_eq "i file ripristinati mantengono i permessi" 644 "$(stat -c %a "$PROJECT/public/index.php")"
check_eq "il backup di sicurezza è privato" 600 "$(stat -c %a "$(ls "$BACKUPS/$NAME"/*-pre-restore.zip | head -1)")"
check "file creati dopo il backup rimossi" test ! -e "$PROJECT/public/nuovo.txt"
check "creato il backup di sicurezza" bash -c "ls \"\$1\"/*-pre-restore.zip" _ "$BACKUPS/$NAME"
check "nessuna cartella temporanea lasciata" bash -c "! ls -A \"\$1\" | grep -q '^\.ddev-restore-'" _ "$TMP/projects"

section "Restore come copia"
run restore "$ZIP" --to "$TMP/projects/con.punto" --name con.punto
check_eq "un nome con caratteri non validi viene rifiutato" 1 "$RC"
run restore "$ZIP" --to "$TMP/projects/altro"
check_eq "stesso nome in un'altra cartella viene rifiutato" 1 "$RC"
run restore "$ZIP" --to "$TMP/projects/$COPY" --name "$COPY"
check_eq "con --name termina con successo" 0 "$RC"
check_eq "la copia ha i dati" "1 2" "$(sql "$TMP/projects/$COPY" 'SELECT id FROM items ORDER BY id' | xargs)"
check "la copia ha il nuovo nome" grep -q "^name: $COPY" "$TMP/projects/$COPY/.ddev/config.yaml"

section "Rollback se il restore fallisce"
BAD="$TMP/bad"
mkdir -p "$BAD"
bsdtar -xf "$ZIP" -C "$BAD"
echo "QUESTO NON E SQL;" | gzip >"$BAD/database/extra.sql.gz"
sha="$(sha256sum "$BAD/database/extra.sql.gz" | cut -d' ' -f1)"
jq --arg s "$sha" '(.database.databases[] | select(.name == "extra") | .sha256) = $s' "$BAD/manifest.json" >"$BAD/m.json"
mv "$BAD/m.json" "$BAD/manifest.json"
(cd "$BAD" && bsdtar --format zip -cf "$TMP/bad.zip" manifest.json database files)
echo marker >"$TMP/projects/$COPY/MARKER"

run restore "$TMP/bad.zip" --to "$TMP/projects/$COPY" --name "$COPY" --force
check_eq "il restore fallisce" 1 "$RC"
check "la cartella originale viene rimessa" test -f "$TMP/projects/$COPY/MARKER"
check "viene indicato come recuperare il database" grep -q "restore .*pre-restore.zip" <<<"$OUT"
SAFETY="$(ls "$BACKUPS/$COPY"/*-pre-restore.zip 2>/dev/null | tail -1)"
run restore "$SAFETY" --to "$TMP/projects/$COPY" --force --no-safety-backup
check_eq "il recupero dal backup di sicurezza funziona" "1 2" "$(sql "$TMP/projects/$COPY" 'SELECT id FROM items ORDER BY id' | xargs)"

section "Checksum"
cp "$ZIP" "$TMP/tampered.zip"
rm -rf "$BAD" && mkdir -p "$BAD" && bsdtar -xf "$ZIP" -C "$BAD"
echo "SELECT 1;" | gzip >"$BAD/database/db.sql.gz"
(cd "$BAD" && bsdtar --format zip -cf "$TMP/tampered.zip" manifest.json database files)
run restore "$TMP/tampered.zip" --to "$TMP/projects/nuovo" --name ddbt-$$-nuovo
check_eq "un dump alterato viene rifiutato" 1 "$RC"
check "con checksum errato" grep -q "checksum" <<<"$OUT"
check "nessun progetto creato" test ! -e "$TMP/projects/nuovo"

# ------------------------------------------------------------------ solo database

section "Backup del solo database"
run backup "$NAME" --db-only --label "Prima della migrazione: v2!"
check_eq "backup --db-only termina con successo" 0 "$RC"
DBZIP="${OUT##*DONE: }"
check "il nome del file contiene -db e la nota" bash -c '[[ $(basename "$1") == *-db-prima-della-migrazione-v2.zip ]]' _ "$DBZIP"
DBLIST="$(bsdtar -tf "$DBZIP" 2>/dev/null)"
check "contiene i dump" grep -qx 'database/extra.sql.gz' <<<"$DBLIST"
check "non contiene file del progetto" bash -c "! grep -q '^files' <<<\"\$1\"" _ "$DBLIST"
DBMANIFEST="$("$CLI" inspect "$DBZIP" 2>/dev/null)"
check_eq "manifest: kind database" "database" "$(jq -r .kind <<<"$DBMANIFEST")"
check_eq "manifest: nota completa" "Prima della migrazione: v2!" "$(jq -r .label <<<"$DBMANIFEST")"
check "list riporta tipo e nota" jq -e --arg f "$(basename "$DBZIP")" \
  '[.projects[].backups[] | select(.file == $f)][0] | .kind == "database" and .label == "Prima della migrazione: v2!"' \
  <<<"$("$CLI" list 2>/dev/null)"

section "Restore del solo database"
sql "$PROJECT" "DELETE FROM items; UPDATE extra.notes SET txt='cambiata'; CREATE DATABASE spuria2;"
echo '<?php echo "lavoro in corso";' >"$PROJECT/public/index.php"

run restore "$DBZIP"
check_eq "senza --force viene rifiutato" 1 "$RC"
run restore "$DBZIP" --to "$TMP/projects/altrove" --force
check_eq "--to viene rifiutato" 1 "$RC"
run restore "$DBZIP" --name ddbt-$$-inesistente --force
check_eq "su un progetto inesistente viene rifiutato" 1 "$RC"

run restore "$DBZIP" --force
check_eq "con --force termina con successo" 0 "$RC"
check_eq "dati di db ripristinati" "1 2" "$(sql "$PROJECT" 'SELECT id FROM items ORDER BY id' | xargs)"
check_eq "dati di extra ripristinati" "nota" "$(sql "$PROJECT" 'SELECT txt FROM extra.notes')"
check "database creato dopo il backup rimosso" bash -c "! (cd \"\$1\" && ddev mysql -N -e 'SHOW DATABASES' 2>/dev/null) | grep -qx spuria2" _ "$PROJECT"
check "i file non vengono toccati" grep -q "lavoro in corso" "$PROJECT/public/index.php"
DBSAFETY="$(ls -t "$BACKUPS/$NAME"/*-db-pre-restore.zip 2>/dev/null | head -1)"
check "creato un backup di sicurezza del solo database" test -f "$DBSAFETY"
check_eq "il backup di sicurezza è marcato come tale" "database true" \
  "$("$CLI" inspect "$DBSAFETY" 2>/dev/null | jq -r '"\(.kind) \(.safety)"')"
check "il backup di sicurezza contiene lo stato prima del restore" bash -c \
  "bsdtar -xOf \"\$1\" database/extra.sql.gz | gunzip | grep -q cambiata" _ "$DBSAFETY"

# ------------------------------------------------------------------ postgres

section "PostgreSQL"
PGDIR="$TMP/projects/$PG"
mkdir -p "$PGDIR/public"
echo '<?php echo "pg";' >"$PGDIR/public/index.php"
if (cd "$PGDIR" && ddev config --project-name="$PG" --project-type=php --docroot=public --database=postgres:16 >/dev/null 2>&1 &&
  ddev start -y >/dev/null 2>&1); then
  psql_in "$PGDIR" db "CREATE TABLE items(id INT PRIMARY KEY, name TEXT)"
  psql_in "$PGDIR" db "INSERT INTO items VALUES (1,'alpha'),(2,'beta')"
  psql_in "$PGDIR" db "CREATE DATABASE extra"
  psql_in "$PGDIR" extra "CREATE TABLE notes(id INT, txt TEXT)"
  psql_in "$PGDIR" extra "INSERT INTO notes VALUES (1,'nota')"
  check_eq "progetto postgres:16 con i database db ed extra" "db extra" "$(pg_user_dbs "$PGDIR")"

  run backup "$PG"
  check_eq "backup completo" 0 "$RC"
  PGZIP="${OUT##*DONE: }"
  check_eq "manifest: tipo database" "postgres" "$("$CLI" inspect "$PGZIP" 2>/dev/null | jq -r .database.type)"
  check "il dump di db contiene i dati" bash -c "bsdtar -xOf \"\$1\" database/db.sql.gz | gunzip | grep -q alpha" _ "$PGZIP"
  check "il dump di extra contiene i dati" bash -c "bsdtar -xOf \"\$1\" database/extra.sql.gz | gunzip | grep -q nota" _ "$PGZIP"

  psql_in "$PGDIR" db "DELETE FROM items WHERE id = 1"
  psql_in "$PGDIR" extra "UPDATE notes SET txt = 'modificata'"
  psql_in "$PGDIR" db "CREATE DATABASE spuria"
  run restore "$PGZIP" --force
  check_eq "restore completo sul posto" 0 "$RC"
  check_eq "dati di db ripristinati" "1 2" "$(psql_in "$PGDIR" db 'SELECT id FROM items ORDER BY id' | xargs)"
  check_eq "dati di extra ripristinati" "nota" "$(psql_in "$PGDIR" extra 'SELECT txt FROM notes')"
  check_eq "database creato dopo il backup rimosso" "db extra" "$(pg_user_dbs "$PGDIR")"

  run backup "$PG" --db-only --label "pg"
  check_eq "backup del solo database" 0 "$RC"
  PGDBZIP="${OUT##*DONE: }"

  # Connessioni aperte (come un'applicazione o un worker) sia sul database
  # da reimportare sia su uno da eliminare: Postgres le rifiuterebbe.
  psql_in "$PGDIR" db "DELETE FROM items"
  psql_in "$PGDIR" db "CREATE DATABASE spuria2"
  (cd "$PGDIR" && ddev psql -d db -c "SELECT pg_sleep(120)" </dev/null >/dev/null 2>&1) &
  (cd "$PGDIR" && ddev psql -d spuria2 -c "SELECT pg_sleep(120)" </dev/null >/dev/null 2>&1) &
  for _ in $(seq 30); do
    [[ "$(psql_in "$PGDIR" postgres "SELECT count(*) FROM pg_stat_activity WHERE datname IN ('db','spuria2') AND query LIKE '%pg_sleep%'")" -ge 2 ]] && break
    sleep 0.5
  done
  run restore "$PGDBZIP" --force
  check_eq "restore del solo database con connessioni aperte" 0 "$RC"
  check_eq "dati ripristinati" "1 2" "$(psql_in "$PGDIR" db 'SELECT id FROM items ORDER BY id' | xargs)"
  check_eq "database con connessioni aperte eliminato" "db extra" "$(pg_user_dbs "$PGDIR")"
else
  fail "ddev start del progetto postgres fallito"
fi

# ------------------------------------------------------------------ impostazioni

section "Impostazioni da shell.json"
SHELLJSON="$TMP/shell.json"
jq -n --arg dir "$TMP/da-shell-json" '{version: 1, bar: {layout: {right: [
  "omarchy.clock",
  {id: "mcp64.ddev-backup", backupDir: $dir, keep: 0, keepDb: 0, exclude: "node_modules, public", notify: false}
]}}}' >"$SHELLJSON"
OUT="$(env -u DDEV_BACKUP_CONFIG -u DDEV_BACKUP_NOTIFY OMARCHY_SHELL_CONFIG="$SHELLJSON" "$CLI" backup "$NAME" 2>&1)"
check_eq "backup con le impostazioni di shell.json" 0 "$?"
SJZIP="${OUT##*DONE: }"
check "usa la cartella backupDir di shell.json" bash -c '[[ $1 == "$2"/* ]]' _ "$SJZIP" "$TMP/da-shell-json"
SJLIST="$(bsdtar -tf "$SJZIP" 2>/dev/null)"
check "applica le esclusioni separate da virgola" bash -c "! grep -q '^files/public' <<<\"\$1\"" _ "$SJLIST"
check "include ancora il resto" grep -qx 'files/.env' <<<"$SJLIST"
check_eq "list usa la stessa cartella" "$TMP/da-shell-json" \
  "$(env -u DDEV_BACKUP_CONFIG OMARCHY_SHELL_CONFIG="$SHELLJSON" "$CLI" list 2>/dev/null | jq -r .backupDir)"
echo '{"version": 1, "bar": {"layout": {"right": [{"id": "mcp64.ddev-backup", "backupDir": "relativa"}]}}}' >"$SHELLJSON"
OUT="$(env -u DDEV_BACKUP_CONFIG OMARCHY_SHELL_CONFIG="$SHELLJSON" "$CLI" list 2>&1)"
check "rifiuta una backupDir relativa" grep -q "percorso assoluto" <<<"$OUT"

# ------------------------------------------------------------------ altro

section "Conservazione e cancellazione"
echo "{\"backupDir\": \"$BACKUPS\", \"keep\": 3, \"keepDb\": 2}" >"$DDEV_BACKUP_CONFIG"
for _ in 1 2 3 4; do
  sleep 1
  "$CLI" backup "$NAME" >/dev/null 2>&1
done
for _ in 1 2 3; do
  sleep 1
  "$CLI" backup "$NAME" --db-only >/dev/null 2>&1
done
check_eq "restano al massimo 3 backup completi (keep)" 3 \
  "$(find "$BACKUPS/$NAME" -regextype posix-extended -regex ".*/$NAME-[0-9]{8}-[0-9]{6}\.zip" | wc -l)"
check_eq "restano al massimo 2 backup del database (keepDb)" 2 \
  "$(find "$BACKUPS/$NAME" -name '*-db*.zip' ! -name '*-pre-restore*' | wc -l)"
check "i backup pre-restore non vengono cancellati" bash -c "ls \"\$1\"/*-pre-restore.zip" _ "$BACKUPS/$NAME"

cp "$(last_backup "$NAME")" "$TMP/fuori.zip"
run delete "$TMP/fuori.zip"
check_eq "delete rifiuta file fuori da backupDir" 1 "$RC"
VICTIM="$(last_backup "$NAME")"
run delete "$VICTIM"
check_eq "delete di un backup" 0 "$RC"
check "il file è stato cancellato" test ! -e "$VICTIM"

section "Manifest non fidati"
# Uno zip qualsiasi può arrivare da "Ripristina da file": i campi del manifest
# non devono mai essere eseguiti né usati come percorsi.
EVIL="$TMP/evil"
evil_zip() {
  rm -rf "$EVIL" && mkdir -p "$EVIL" && printf '%s' "$2" >"$EVIL/manifest.json" &&
    bsdtar --format zip -cf "$TMP/$1.zip" -C "$EVIL" manifest.json
}
SHA0="$(printf '%064d' 0)"
evil_zip fv '{"format":"ddev-backup","formatVersion":"FORMAT_VERSION[$(touch '"$TMP"'/pwned)]","kind":"full","project":{"name":"x"},"database":{"type":"","databases":[]}}'
run inspect "$TMP/fv.zip"
check_eq "inspect rifiuta formatVersion non numerico" 1 "$RC"
run restore "$TMP/fv.zip" --to "$TMP/projects/evil" --name evil --force
check_eq "restore rifiuta formatVersion non numerico" 1 "$RC"
check "nessun comando eseguito dal manifest" test ! -e "$TMP/pwned"
evil_zip future '{"format":"ddev-backup","formatVersion":2,"kind":"full","project":{"name":"x"},"database":{"type":"","databases":[]}}'
run inspect "$TMP/future.zip"
check_eq "rifiuta un formato più recente" 1 "$RC"
evil_zip path '{"format":"ddev-backup","formatVersion":1,"kind":"full","project":{"name":"x"},"database":{"type":"mariadb","databases":[{"name":"db","file":"../../etc/passwd","sha256":"'"$SHA0"'"}]}}'
run inspect "$TMP/path.zip"
check_eq "rifiuta percorsi dei dump fuori da database/" 1 "$RC"
evil_zip dbname '{"format":"ddev-backup","formatVersion":1,"kind":"full","project":{"name":"x"},"database":{"type":"mariadb","databases":[{"name":"--x;y","file":"database/--x;y.sql.gz","sha256":"'"$SHA0"'"}]}}'
run inspect "$TMP/dbname.zip"
check_eq "rifiuta nomi di database non validi" 1 "$RC"
run inspect "$(last_backup "$NAME")"
check_eq "un backup vero passa i controlli" 0 "$RC"

section "list"
LISTING="$("$CLI" list 2>/dev/null)"
check "produce JSON valido" jq -e . <<<"$LISTING"
check "riporta i dati per l'anteprima del restore" jq -e --arg n "$NAME" --arg root "$PROJECT" '
  [.projects[] | select(.name == $n) | .backups[] | select(.kind == "full")][0] |
  .approot == $root and .dbType == "mariadb" and .dbVersion == "11.8" and (.git.commit | length) == 40
  and .host != "" and .created != "" and .ddevVersion != ""' <<<"$LISTING"
check "include il progetto con i suoi backup" jq -e --arg n "$NAME" \
  '.projects[] | select(.name == $n) | .backups | length > 0' <<<"$LISTING"

# ------------------------------------------------------------------ esito

printf '\n%d superati, %d falliti\n' "$PASSED" "$FAILED"
if ((FAILED > 0)); then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
