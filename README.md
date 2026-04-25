# zfs_migrate.sh

ZFS-Migrationsskript für Proxmox zur Defragmentierung und Optimierung von `volblocksize`/`recordsize` durch Umzug auf einen zweiten Pool und zurück.

## Voraussetzungen

- Proxmox mit zwei ZFS-Pools (z.B. `data` und `zdata`)
- Genügend freier Platz auf dem Zielpool (mind. so viel wie belegte Daten auf Quellpool)
- `pv` installiert (optional, für Fortschrittsanzeige): `apt install pv`
- Root-Rechte

## Verwendung

```bash
# Alle Datasets: data -> zdata
bash zfs_migrate_data_to_zdata.sh

# Einzelnes Dataset: data -> zdata
bash zfs_migrate_data_to_zdata.sh vm-103-disk-1

# Rueckmigration: zdata -> data (alle Datasets)
bash zfs_migrate_data_to_zdata.sh --reverse

# Rueckmigration: einzelnes Dataset
bash zfs_migrate_data_to_zdata.sh --reverse vm-103-disk-1

# Snapshots auf data bereinigen
bash zfs_migrate_data_to_zdata.sh --cleanup

# Snapshots auf zdata bereinigen
bash zfs_migrate_data_to_zdata.sh --cleanup-zdata
```

## Ablauf

### Phase 1: data → zdata

```
bash zfs_migrate_data_to_zdata.sh
```

1. Prerequisite-Check (Root, Pools, freier Platz, laufende VMs/LXCs)
2. Dynamische Erkennung aller Datasets auf `data`
3. Tabellarische Übersicht mit aktueller und empfohlener Blockgrösse
4. Interaktive Abfrage der `volblocksize` (zvol) / `recordsize` (subvol) pro Dataset
5. Bestätigung der Migrationsreihenfolge (automatisch nach Grösse sortiert, klein zuerst)
6. Migration Dataset für Dataset mit Snapshot + `zfs send | zfs receive`
7. Verify nach jedem Dataset
8. Bei Fehler: interaktiver Rollback-Prompt

### Phase 2: zdata → data (Rückmigration)

```
bash zfs_migrate_data_to_zdata.sh --reverse
```

Identischer Ablauf, Quell- und Zielpool vertauscht. `data` ist danach defragmentiert und optimiert.

## Interaktive Konfiguration

Vor der Migration wird für jedes Dataset die Blockgrösse abgefragt:

```
DATASET                             TYP      GROESSE    AKTUELL      EMPFEHLUNG
vm-103-disk-1                       zvol     8448GB     8K           128K
vm-121-disk-0                       zvol     3601GB     16K          16K
subvol-106-disk-0                   subvol   1056GB     128K         128K

  zvol vm-103-disk-1 [aktuell: 8K | empfohlen: 128K]: 
  zvol vm-121-disk-0 [aktuell: 16K | empfohlen: 16K]: 
  subvol subvol-106-disk-0 [aktuell: 128K | empfohlen: 128K]: 
```

**Enter** übernimmt die Empfehlung. Alternativ kann ein eigener Wert eingegeben werden (z.B. `64K`).

Gültige Werte: `512`, `1K`, `2K`, `4K`, `8K`, `16K`, `32K`, `64K`, `128K`, `256K`, `512K`, `1M`

## Empfehlungslogik

### volblocksize (zvol)

| Kriterium | Empfehlung |
|---|---|
| Name enthält `samba`, `share`, `nas`, `files` | `128K` |
| Name enthält `docker`, `db`, `sql`, `pg` | `16K` |
| Name enthält `win`, `windows` | `64K` |
| Volsize ≥ 2 TB | `128K` |
| Volsize ≥ 500 GB | `64K` |
| Volsize < 500 GB | `16K` |

### recordsize (subvol / LXC)

| Kriterium | Empfehlung |
|---|---|
| Name enthält `nextcloud`, `cloud`, `files`, `share` | `128K` |
| Name enthält `db`, `sql`, `pg`, `postgres` | `16K` |
| Name enthält `backup`, `media`, `immich`, `photo` | `1M` |
| Sonstiges | `128K` |

## Fallback: Direktes Streaming

Falls auf dem Quellpool kein Platz für einen Snapshot vorhanden ist, fragt das Skript ob direkt gestreamt werden soll:

```
[WARN] Snapshot nicht moeglich (kein Platz) - Fallback: direktes Streaming
[WARN] ACHTUNG: Direkt-Streaming ist nicht crash-konsistent! VM muss gestoppt sein.
Direkt-Streaming fuer vm-103-disk-1 fortfahren? (yes/no):
```

Direktes Streaming ist nur sicher wenn die betroffene VM/der LXC vollständig gestoppt ist.

## Fehlerbehandlung

| Situation | Verhalten |
|---|---|
| Snapshot fehlgeschlagen | Fallback-Prompt für direktes Streaming |
| Migration fehlgeschlagen | Rollback-Prompt |
| Verify fehlgeschlagen | Rollback-Prompt |
| Ziel-Dataset existiert bereits | Überspringen (idempotent) |
| Dataset auf Quellpool nicht gefunden | Warnung, weiter mit nächstem |

## Vollständiger Workflow

```bash
# 1. VMs und LXCs stoppen
qm stop <vmid>
pct stop <ctid>

# 2. Phase 1: data -> zdata
bash zfs_migrate.sh

# 3. Proxmox Storage auf zdata umstellen
# Datacenter -> Storage -> data -> Edit -> pool: zdata
# oder /etc/pve/storage.cfg anpassen

# 4. VMs/LXCs starten und testen
qm start <vmid>
pct start <ctid>

# 5. Phase 2: zdata -> data (Rueckmigration)
bash zfs_migrate.sh --reverse

# 6. Proxmox Storage zurück auf data umstellen

# 7. VMs/LXCs erneut testen

# 8. Aufräumen
bash zfs_migrate_data_to_zdata.sh --cleanup-zdata
zfs list -r zdata                        # verbleibende Datasets prüfen
zfs destroy -r zdata/<dataset>           # manuell löschen falls nötig
```

## Logging

Jeder Lauf schreibt ein Log nach `/var/log/zfs_migrate_<datum>_<uhrzeit>.log`.

```bash
tail -f /var/log/zfs_migrate_*.log
```

## Wichtige Hinweise

- `volblocksize` kann **nur beim Erstellen** eines zvol gesetzt werden – die Migration ist die einzige Möglichkeit zur nachträglichen Änderung
- `recordsize` gilt nur für **neu geschriebene Daten** – bestehende Blöcke behalten die alte Grösse bis sie überschrieben werden
- Der `SNAP_SUFFIX` enthält Datum **und Uhrzeit** des Skriptstarts – ein Datumswechsel während der Migration führt nicht zu Fehlern
- `atime=off` wird nur auf Filesystem-Datasets gesetzt, nicht auf zvols
- Nach der Migration ist `compression=lz4` und `atime=off` auf dem Zielpool gesetzt
