# DDEV Backup

Plugin per la barra di Omarchy che fa backup e restore completi dei progetti
DDEV: **sorgenti, configurazione (`.env`, `.ddev/`) e tutti i database** in un
singolo file `.zip`.

## Uso dal pannello

Clicca l'icona  nella barra:

- **💾 Backup** su un progetto crea subito il backup. Se il progetto è fermo
  viene avviato per esportare il database e poi rifermato.
- **▸** mostra i backup esistenti; per ognuno ci sono **Ripristina** ed
  **Elimina**, entrambi con richiesta di conferma.
- **Ripristina da file…** (in alto) apre un file chooser per un `.zip`
  ovunque si trovi (es. copiato da un altro PC).
- I backup di progetti non più registrati in DDEV compaiono in fondo e si
  possono ripristinare nella loro cartella originale.

## Uso da terminale

```sh
B=~/.config/omarchy/plugins/solla.ddev-backup/bin/ddev-backup
$B backup mioprogetto
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

## Configurazione

`~/.config/omarchy/ddev-backup/settings.json` (opzionale):

```json
{
  "backupDir": "~/Backups/ddev",
  "keep": 10,
  "exclude": ["node_modules"]
}
```

`keep` è il numero di backup conservati per progetto (0 = tutti). I backup
`pre-restore` non vengono mai cancellati automaticamente.
