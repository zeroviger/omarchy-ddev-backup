# DDEV Backup

Plugin per la barra di Omarchy che fa backup e restore completi dei progetti
DDEV: **sorgenti, configurazione (`.env`, `.ddev/`) e tutti i database** in un
singolo file `.zip`.

## Installazione

```sh
omarchy plugin add https://github.com/zeroviger/omarchy-ddev-backup --enable
```

Aggiornamenti: `omarchy plugin update mcp64.ddev-backup`.

Richiede `ddev`, `jq` e `bsdtar` (presente di default su Arch/Omarchy).

## Uso dal pannello

Clicca l'icona  nella barra:

- **💾 Backup** su un progetto crea subito il backup completo. Se il progetto
  è fermo viene avviato per esportare il database e poi rifermato.
- **🛢 Backup DB** salva solo i database, con una nota facoltativa (es. "prima
  della migrazione"): veloce, utile prima di operazioni rischiose. Il restore
  riporta indietro i database senza toccare i file.
- **▸** mostra i backup esistenti; per ognuno ci sono **Ripristina** ed
  **Elimina**, entrambi con richiesta di conferma. Prima di ripristinare
  compare un'anteprima del backup: data, tipo, nota, database, branch e
  commit git (e se c'erano modifiche non committate), cartella originale,
  macchina e versione di DDEV, dimensione.
- **⧉ Ripristina come copia** (solo backup completi) crea un nuovo progetto
  DDEV dal backup, con nome e cartella a scelta: utile per provare qualcosa
  senza toccare l'originale.
- **Ripristina da file…** (in alto) apre un file chooser per un `.zip`
  ovunque si trovi (es. copiato da un altro PC).
- **⚙ Impostazioni** (in alto): cartella dei backup, quanti backup tenere,
  esclusioni, notifiche.
- I backup di progetti non più registrati in DDEV compaiono in fondo e si
  possono ripristinare nella loro cartella originale.

## Uso da terminale

```sh
B=~/.config/omarchy/plugins/mcp64.ddev-backup/bin/ddev-backup
$B backup mioprogetto
$B backup mioprogetto --db-only --label "prima della migrazione"
$B inspect ~/Backups/ddev/mioprogetto/mioprogetto-20261015-102100.zip
$B restore <file.zip> --force                       # sovrascrive il progetto
$B restore <file.zip> --to ~/Projects/copia --name copia   # crea una copia
$B list                                             # JSON per il pannello
```

## Cosa contiene lo zip

```
manifest.json          progetto, versione DDEV, tipo DB, commit git, sha256 dei dump
database/<db>.sql.gz   un dump per ogni database (db, più eventuali database extra)
files/                 l'intera cartella del progetto
```

Esclusi: i file che DDEV rigenera (`.ddev/.ddev-docker-compose-*`,
`.ddev/db_snapshots`, `.ddev/traefik/certs`, …) e `node_modules`.
Pattern aggiuntivi per singolo progetto: un file `.ddev-backup-ignore` nella
root del progetto, un pattern per riga.

## Come funziona il restore

1. Estrae lo zip in una cartella temporanea e verifica gli sha256 dei dump.
2. Se il progetto esiste già: **backup di sicurezza** (`…-pre-restore.zip`),
   poi `ddev delete` (container e database, non i file).
3. Sostituisce la cartella, `ddev start`, `ddev import-db` per ogni database.
4. Se qualcosa fallisce rimette la cartella originale e stampa il comando per
   recuperare il database dal backup di sicurezza.

Il restore è esatto: i file e i database creati dopo il backup spariscono
(restano nel backup di sicurezza). Le cartelle escluse, come `node_modules`,
vanno rigenerate (es. `ddev npm install`).

## Sicurezza delle operazioni

- **Una operazione alla volta per progetto**: backup, restore e delete dello
  stesso progetto non possono sovrapporsi, anche se lanciati da pannello e
  terminale insieme. Il lock sta in `$XDG_RUNTIME_DIR/ddev-backup/`; un lock
  rimasto da un processo terminato male viene ignorato.
- **Spazio su disco**: prima di iniziare controlla che ci sia spazio per il
  backup (file + database non compressi, più 100 MB di margine) o per
  l'estrazione dello zip in caso di restore, e si ferma con un messaggio
  invece di riempire il disco a metà operazione.

## Test

```sh
test/run-tests.sh
```

Test end-to-end (circa 5-6 minuti): crea progetti DDEV usa-e-getta sotto
`~/.cache`, prova backup completi e del solo database, restore, copia, rollback, checksum, lock, spazio
insufficiente, impostazioni, conservazione e cancellazione, poi rimuove tutto. Richiede
Docker e DDEV attivi; usa `shellcheck` se installato.

## Configurazione

Dal pannello (⚙). I valori vengono salvati da Omarchy nella voce del widget in
`~/.config/omarchy/shell.json`, dove li legge anche lo script da terminale:

| Chiave      | Default          | Significato                                          |
|-------------|------------------|------------------------------------------------------|
| `backupDir` | `~/Backups/ddev` | Cartella dei backup (una sottocartella per progetto)|
| `keep`      | `10`             | Backup completi conservati per progetto (0 = tutti)  |
| `keepDb`    | `20`             | Backup del solo database conservati (0 = tutti)      |
| `exclude`   | `node_modules`   | Pattern esclusi dai backup, separati da virgola      |
| `notify`    | `true`           | Notifiche a fine backup e restore                    |

Si possono impostare anche da terminale, es.
`omarchy bar set mcp64.ddev-backup keep 5 --json`.

I backup di sicurezza fatti prima di un restore (`…-pre-restore.zip`) non
contano nei limiti e non vengono mai cancellati automaticamente.
