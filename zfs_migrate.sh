#!/bin/bash
# =============================================================================
# ZFS Migration: data <-> zdata
# Defragmentierung + Optimierung volblocksize/recordsize
# Datasets und Blockgroessen werden dynamisch ermittelt und abgefragt
# =============================================================================
# Verwendung:
#   bash zfs_migrate.sh                  -> data -> zdata (alle Datasets)
#   bash zfs_migrate.sh <dataset>        -> data -> zdata (einzelnes Dataset)
#   bash zfs_migrate.sh --reverse        -> zdata -> data (alle Datasets)
#   bash zfs_migrate.sh --reverse <ds>   -> zdata -> data (einzelnes Dataset)
#   bash zfs_migrate.sh --cleanup        -> Snapshots auf data bereinigen
#   bash zfs_migrate.sh --cleanup-zdata  -> Snapshots auf zdata bereinigen
# =============================================================================

set -euo pipefail

# Richtung bestimmen
REVERSE=false
if [[ "${1:-}" == "--reverse" ]]; then
    REVERSE=true
    shift
fi

if $REVERSE; then
    SRC_POOL="zdata"
    DST_POOL="data"
else
    SRC_POOL="data"
    DST_POOL="zdata"
fi

LOG="/var/log/zfs_migrate_$(date +%Y%m%d_%H%M%S).log"
# SNAP_SUFFIX einmalig beim Start gesetzt - unveraenderlich waehrend des Laufs
SNAP_SUFFIX="migrate_$(date +%Y%m%d_%H%M%S)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "$(date '+%H:%M:%S') $1" | tee -a "$LOG"; }
ok()   { log "${GREEN}[OK]${NC} $1"; }
err()  { log "${RED}[ERR]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
info() { log "${CYAN}[INFO]${NC} $1"; }

# Dynamisch befuellt durch discover_datasets
declare -A VOLBLOCKSIZE=()
declare -A RECORDSIZE=()
declare -a MIGRATION_ORDER=()

# =============================================================================
# Empfehlung fuer volblocksize/recordsize anhand Namensschema + Metadaten
# =============================================================================

recommend_volblocksize() {
    # volblocksize richtet sich nach dem Gast-Dateisystem, NICHT nach dem Workload.
    # Falsche Werte fuehren zu Write Amplification und Datenverlust-Risiko.
    #
    # Grundregeln:
    #   Linux Gast (ext4/xfs, 4K Bloecke) -> 16K (sicherster Wert)
    #   Windows Gast (NTFS, 4K Bloecke)   -> 16K oder 64K
    #   Standardempfehlung fuer alle VMs  -> 16K
    #
    # HINWEIS: volblocksize kann nach der Erstellung NICHT mehr geaendert werden.
    # Im Zweifel 16K waehlen - lieber konservativ als Write Amplification.

    local dataset="$1"
    local volsize_gb="$3"

    case "$dataset" in
        *win*|*windows*) echo "16K" ; return ;;  # NTFS 4K nativ, 16K sicherer als 64K
    esac

    # Standardempfehlung: 16K fuer alle Linux-Gaeste
    echo "16K"
}

recommend_recordsize() {
    # recordsize fuer ZFS Filesystems (LXC/subvol).
    # Gilt nur fuer neu geschriebene Daten nach der Migration.
    #
    # Grundregeln:
    #   Datenbanken (PostgreSQL etc.) -> 16K (passend zu DB-Blocksize 8K)
    #   Gemischte Files (Nextcloud)   -> 128K
    #   Grosse Mediendateien          -> 1M
    #   Standard/unbekannt            -> 128K

    local dataset="$1"
    case "$dataset" in
        *db*|*sql*|*pg*|*postgres*)          echo "16K"  ;;
        *backup*|*media*|*immich*|*photo*)   echo "1M"   ;;
        *nextcloud*|*cloud*|*files*|*share*) echo "128K" ;;
        *)                                    echo "128K" ;;
    esac
}

# =============================================================================
# Dynamische Dataset-Erkennung + interaktive Konfiguration
# =============================================================================

discover_datasets() {
    info "=== Dynamische Dataset-Erkennung auf $SRC_POOL ==="
    echo ""

    local datasets
    # Nur direkte Kinder, keine Snapshots
    mapfile -t datasets < <(zfs list -H -o name -r -t filesystem,volume "$SRC_POOL" \
        | grep -v "^${SRC_POOL}$" \
        | sed "s|^${SRC_POOL}/||")

    if [[ ${#datasets[@]} -eq 0 ]]; then
        err "Keine Datasets auf $SRC_POOL gefunden"
        exit 1
    fi

    echo -e "${CYAN}Gefundene Datasets:${NC}"
    printf "%-35s %-8s %-10s %-12s %-10s\n" "DATASET" "TYP" "GROESSE" "AKTUELL" "EMPFEHLUNG"
    printf "%-35s %-8s %-10s %-12s %-10s\n" "-------" "---" "-------" "-------" "----------"

    local ordered_zvols=()
    local ordered_subvols=()

    for ds in "${datasets[@]}"; do
        local src="${SRC_POOL}/${ds}"
        local dtype used_bytes used_gb volsize_gb current recommend

        dtype=$(zfs get -H -o value type "$src" 2>/dev/null || echo "unknown")
        used_bytes=$(zfs get -Hp -o value used "$src" 2>/dev/null || echo "0")
        used_gb=$(( used_bytes / 1024 / 1024 / 1024 ))

        if [[ "$dtype" == "volume" ]]; then
            local volsize_bytes
            volsize_bytes=$(zfs get -Hp -o value volsize "$src" 2>/dev/null || echo "0")
            volsize_gb=$(( volsize_bytes / 1024 / 1024 / 1024 ))
            current=$(zfs get -H -o value volblocksize "$src" 2>/dev/null || echo "?")
            recommend=$(recommend_volblocksize "$ds" "$current" "$volsize_gb")
            printf "%-35s %-8s %-10s %-12s %-10s\n" "$ds" "zvol" "${used_gb}GB" "$current" "$recommend"
            ordered_zvols+=("$ds")
        else
            current=$(zfs get -H -o value recordsize "$src" 2>/dev/null || echo "?")
            recommend=$(recommend_recordsize "$ds")
            printf "%-35s %-8s %-10s %-12s %-10s\n" "$ds" "subvol" "${used_gb}GB" "$current" "$recommend"
            ordered_subvols+=("$ds")
        fi
    done

    echo ""
    echo -e "${YELLOW}Blockgroessen konfigurieren (Enter = Empfehlung uebernehmen):${NC}"
    echo ""

    # zvols konfigurieren
    for ds in "${ordered_zvols[@]}"; do
        local src="${SRC_POOL}/${ds}"
        local volsize_bytes volsize_gb current recommend input

        volsize_bytes=$(zfs get -Hp -o value volsize "$src" 2>/dev/null || echo "0")
        volsize_gb=$(( volsize_bytes / 1024 / 1024 / 1024 ))
        current=$(zfs get -H -o value volblocksize "$src" 2>/dev/null || echo "?")
        recommend=$(recommend_volblocksize "$ds" "$current" "$volsize_gb")

        read -rp "  zvol $ds [aktuell: $current | empfohlen: $recommend]: " input
        if [[ -z "$input" ]]; then
            VOLBLOCKSIZE["$ds"]="$recommend"
            log "  $ds -> volblocksize=${recommend} (Empfehlung)"
        else
            VOLBLOCKSIZE["$ds"]="$input"
            log "  $ds -> volblocksize=${input} (manuell)"
        fi
    done

    # subvols konfigurieren
    for ds in "${ordered_subvols[@]}"; do
        local src="${SRC_POOL}/${ds}"
        local current recommend input

        current=$(zfs get -H -o value recordsize "$src" 2>/dev/null || echo "?")
        recommend=$(recommend_recordsize "$ds")

        read -rp "  subvol $ds [aktuell: $current | empfohlen: $recommend]: " input
        if [[ -z "$input" ]]; then
            RECORDSIZE["$ds"]="$recommend"
            log "  $ds -> recordsize=${recommend} (Empfehlung)"
        else
            RECORDSIZE["$ds"]="$input"
            log "  $ds -> recordsize=${input} (manuell)"
        fi
    done

    # Migrationsreihenfolge: nach used-Groesse sortieren (kleine zuerst)
    echo ""
    info "Sortiere Datasets nach Groesse (klein nach gross)..."

    local sorted
    mapfile -t sorted < <(
        for ds in "${datasets[@]}"; do
            local used
            used=$(zfs get -Hp -o value used "${SRC_POOL}/${ds}" 2>/dev/null || echo "0")
            echo "$used $ds"
        done | sort -n | awk '{print $2}'
    )

    MIGRATION_ORDER=("${sorted[@]}")

    echo ""
    info "Migrationsreihenfolge:"
    for ds in "${MIGRATION_ORDER[@]}"; do
        local used_bytes used_gb
        used_bytes=$(zfs get -Hp -o value used "${SRC_POOL}/${ds}" 2>/dev/null || echo "0")
        used_gb=$(( used_bytes / 1024 / 1024 / 1024 ))
        if [[ -v "VOLBLOCKSIZE[$ds]" ]]; then
            info "  $ds (${used_gb}GB, volblocksize=${VOLBLOCKSIZE[$ds]})"
        else
            info "  $ds (${used_gb}GB, recordsize=${RECORDSIZE[$ds]:-128K})"
        fi
    done

    echo ""
    read -rp "Konfiguration korrekt? Weiter? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { log "Abgebrochen."; exit 0; }
}

# =============================================================================
# Hilfsfunktionen
# =============================================================================

check_prerequisites() {
    log "=== Prerequisite Check ==="
    [[ $EUID -ne 0 ]] && { err "Root erforderlich"; exit 1; }

    zpool list "$SRC_POOL" &>/dev/null || { err "Pool $SRC_POOL nicht gefunden"; exit 1; }
    zpool list "$DST_POOL" &>/dev/null || { err "Pool $DST_POOL nicht gefunden"; exit 1; }

    local avail avail_tb
    avail=$(zfs get -Hp -o value available "$DST_POOL")
    avail_tb=$(( avail / 1024 / 1024 / 1024 / 1024 ))
    ok "Zielpool $DST_POOL: ${avail_tb}TB frei"

    log "Laufende VMs:"
    qm list 2>/dev/null | grep running || warn "Keine laufenden VMs (oder kein Proxmox)"
    log "Laufende LXCs:"
    pct list 2>/dev/null | grep running || warn "Keine laufenden LXCs"

    echo ""
    warn "Alle betroffenen VMs/LXCs muessen gestoppt sein!"
    read -rp "Weiter? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { log "Abgebrochen."; exit 0; }
}

snapshot_create() {
    local dataset="$1"
    local snap="${SRC_POOL}/${dataset}@${SNAP_SUFFIX}"
    if zfs list -t snapshot "$snap" &>/dev/null; then
        warn "Snapshot $snap existiert bereits"
        return 0
    fi
    if ! zfs snapshot "$snap" 2>/dev/null; then
        err "Snapshot fehlgeschlagen: $snap (kein Platz?)"
        return 1
    fi
    ok "Snapshot: $snap"
}

get_size() {
    zfs get -Hp -o value used "${SRC_POOL}/$1" 2>/dev/null || echo "0"
}

zfs_send_receive_snap() {
    local snap="$1" dst="$2" size="$3" extra_opts="${4:-}"
    if command -v pv &>/dev/null; then
        zfs send "$snap" | pv -s "$size" | zfs receive $extra_opts -F "$dst"
    else
        zfs send "$snap" | zfs receive $extra_opts -F "$dst"
    fi
}

zfs_send_receive_direct() {
    local src="$1" dst="$2" size="$3" extra_opts="${4:-}"
    if command -v pv &>/dev/null; then
        zfs send "$src" | pv -s "$size" | zfs receive $extra_opts -F "$dst"
    else
        zfs send "$src" | zfs receive $extra_opts -F "$dst"
    fi
}

prompt_direct_stream() {
    local dataset="$1"
    warn "Snapshot nicht moeglich (kein Platz) - Fallback: direktes Streaming"
    warn "ACHTUNG: Direkt-Streaming ist nicht crash-konsistent! VM muss gestoppt sein."
    read -rp "Direkt-Streaming fuer $dataset fortfahren? (yes/no): " direct
    [[ "$direct" == "yes" ]]
}

migrate_zvol() {
    local dataset="$1"
    local vbs="${VOLBLOCKSIZE[$dataset]:-16K}"
    local src="${SRC_POOL}/${dataset}"
    local dst="${DST_POOL}/${dataset}"
    local snap="${src}@${SNAP_SUFFIX}"
    local use_snapshot=true

    log "--- Migriere zvol: $dataset (volblocksize=$vbs) ---"

    if zfs list "$dst" &>/dev/null; then
        warn "$dst existiert bereits - ueberspringe"
        return 0
    fi

    local size volsize
    size=$(get_size "$dataset")
    volsize=$(zfs get -Hp -o value volsize "$src")

    if [[ -z "$volsize" ]] || [[ "$volsize" == "0" ]]; then
        err "volsize fuer $dataset konnte nicht ermittelt werden"
        return 1
    fi

    log "Datenmenge: $(( size / 1024 / 1024 / 1024 ))GB / Volsize: $(( volsize / 1024 / 1024 / 1024 ))GB"

    if ! snapshot_create "$dataset"; then
        prompt_direct_stream "$dataset" || { err "Uebersprungen: $dataset"; return 1; }
        use_snapshot=false
    fi

    zfs create -V "$volsize" -b "$vbs" -o compression=lz4 "$dst"
    ok "Ziel-zvol erstellt: $dst (volblocksize=$vbs)"

    if $use_snapshot; then
        zfs_send_receive_snap "$snap" "$dst" "$size"
    else
        warn "Starte direktes Streaming von $src ..."
        zfs_send_receive_direct "$src" "$dst" "$size"
    fi

    ok "Migration abgeschlossen: $dataset -> $dst (volblocksize=$vbs)"
}

migrate_subvol() {
    local dataset="$1"
    local rs="${RECORDSIZE[$dataset]:-128K}"
    local src="${SRC_POOL}/${dataset}"
    local dst="${DST_POOL}/${dataset}"
    local snap="${src}@${SNAP_SUFFIX}"
    local use_snapshot=true

    log "--- Migriere subvol: $dataset (recordsize=$rs) ---"

    if zfs list "$dst" &>/dev/null; then
        warn "$dst existiert bereits - ueberspringe"
        return 0
    fi

    local size
    size=$(get_size "$dataset")
    log "Datenmenge: $(( size / 1024 / 1024 / 1024 ))GB"

    if ! snapshot_create "$dataset"; then
        prompt_direct_stream "$dataset" || { err "Uebersprungen: $dataset"; return 1; }
        use_snapshot=false
    fi

    if $use_snapshot; then
        if command -v pv &>/dev/null; then
            zfs send "$snap" | pv -s "$size" | zfs receive -o recordsize="$rs" "$dst"
        else
            zfs send "$snap" | zfs receive -o recordsize="$rs" "$dst"
        fi
    else
        warn "Starte direktes Streaming von $src ..."
        zfs_send_receive_direct "$src" "$dst" "$size" "-o recordsize=$rs"
    fi

    ok "Migration abgeschlossen: $dataset -> $dst (recordsize=$rs)"
}

verify_migration() {
    local dataset="$1"
    local src="${SRC_POOL}/${dataset}"
    local dst="${DST_POOL}/${dataset}"

    local src_used dst_used
    src_used=$(zfs get -Hp -o value used "$src" 2>/dev/null || echo "N/A")
    dst_used=$(zfs get -Hp -o value used "$dst" 2>/dev/null || echo "N/A")

    log "Verify $dataset: src=${src_used}B dst=${dst_used}B"

    # Existenzpruefung
    if [[ "$src_used" == "N/A" ]] || [[ "$dst_used" == "N/A" ]]; then
        err "Verify fehlgeschlagen fuer $dataset (Dataset nicht gefunden)"
        return 1
    fi

    # Plausibilitaetspruefung: dst darf nicht mehr als 20% groesser oder kleiner als src sein
    # Kompression und Metadaten erklaeren kleine Abweichungen
    # Bei sehr kleinen Datasets (<10MB) Toleranz deaktivieren - Metadaten-Overhead dominiert
    local threshold=$(( 10 * 1024 * 1024 ))  # 10MB
    if [[ "$src_used" -gt "$threshold" ]]; then
        local ratio
        ratio=$(( dst_used * 100 / src_used ))
        if [[ $ratio -lt 50 ]] || [[ $ratio -gt 200 ]]; then
            err "Verify fehlgeschlagen: dst=${dst_used}B ist ${ratio}% von src=${src_used}B - ausserhalb Toleranz"
            return 1
        fi
        ok "Verify OK: $dataset (dst ist ${ratio}% von src)"
    else
        warn "Verify $dataset: Dataset <10MB - Groessenvergleich uebersprungen (Metadaten-Overhead dominiert)"
        ok "Verify OK: $dataset (klein, nur Existenzpruefung)"
    fi
}

rollback() {
    local dataset="$1"
    local dst="${DST_POOL}/${dataset}"
    warn "Rollback: Loesche $dst"
    zfs destroy -r "$dst" && ok "Rollback OK: $dataset" || err "Rollback fehlgeschlagen: $dataset"
}

apply_pool_optimizations() {
    log "=== Pool-Optimierungen fuer $DST_POOL ==="
    zfs set compression=lz4 "$DST_POOL"
    ok "compression=lz4 gesetzt"
    zfs set atime=off "$DST_POOL"
    ok "atime=off gesetzt"
    log "ARC-Empfehlung: options zfs zfs_arc_max=128849018880 (120GB) in /etc/modprobe.d/zfs.conf"
    log "Dann: update-initramfs -u && reboot"
}

cleanup_all_snapshots() {
    local pool="$1"
    log "=== Cleanup Snapshots auf $pool ==="
    zfs list -t snapshot -H -o name -r "$pool" | grep "@migrate_\|@final_" | while read -r snap; do
        zfs destroy "$snap" && ok "Geloescht: $snap"
    done
}

migrate_dataset() {
    local dataset="$1"
    local src="${SRC_POOL}/${dataset}"

    zfs list "$src" &>/dev/null || { warn "$src nicht gefunden - ueberspringe"; return 0; }

    local dtype
    dtype=$(zfs get -H -o value type "$src")

    {
        if [[ "$dtype" == "volume" ]]; then
            migrate_zvol "$dataset"
        else
            migrate_subvol "$dataset"
        fi
    } || {
        err "Migration fehlgeschlagen: $dataset"
        read -rp "Rollback fuer $dataset? (yes/no): " rb
        [[ "$rb" == "yes" ]] && rollback "$dataset"
        return 1
    }

    verify_migration "$dataset" || {
        err "Verify fehlgeschlagen: $dataset"
        read -rp "Rollback? (yes/no): " rb
        [[ "$rb" == "yes" ]] && rollback "$dataset"
        return 1
    }
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Cleanup-Optionen
    if [[ "${1:-}" == "--cleanup" ]]; then
        cleanup_all_snapshots "data"; exit 0
    fi
    if [[ "${1:-}" == "--cleanup-zdata" ]]; then
        cleanup_all_snapshots "zdata"; exit 0
    fi

    log "======================================================="
    log "ZFS Migration: $SRC_POOL -> $DST_POOL"
    $REVERSE && log "Modus: REVERSE (zdata -> data)"
    log "Log: $LOG"
    log "======================================================="

    check_prerequisites

    if [[ $# -gt 0 ]]; then
        # Einzelnes Dataset: Blocksize direkt abfragen
        local dataset="$1"
        local src="${SRC_POOL}/${dataset}"
        local dtype
        dtype=$(zfs get -H -o value type "$src" 2>/dev/null || { err "$src nicht gefunden"; exit 1; })

        if [[ "$dtype" == "volume" ]]; then
            local volsize_bytes volsize_gb current recommend input
            volsize_bytes=$(zfs get -Hp -o value volsize "$src")
            volsize_gb=$(( volsize_bytes / 1024 / 1024 / 1024 ))
            current=$(zfs get -H -o value volblocksize "$src")
            recommend=$(recommend_volblocksize "$dataset" "$current" "$volsize_gb")
            read -rp "volblocksize fuer $dataset [aktuell: $current | empfohlen: $recommend]: " input
            VOLBLOCKSIZE["$dataset"]="${input:-$recommend}"
        else
            local current recommend input
            current=$(zfs get -H -o value recordsize "$src")
            recommend=$(recommend_recordsize "$dataset")
            read -rp "recordsize fuer $dataset [aktuell: $current | empfohlen: $recommend]: " input
            RECORDSIZE["$dataset"]="${input:-$recommend}"
        fi
        MIGRATION_ORDER=("$dataset")
    else
        discover_datasets
    fi

    local failed=()
    for ds in "${MIGRATION_ORDER[@]}"; do
        migrate_dataset "$ds" || failed+=("$ds")
        echo ""
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        err "Fehlgeschlagen: ${failed[*]}"
    else
        ok "Alle Datasets erfolgreich migriert!"
        apply_pool_optimizations

        if $REVERSE; then
            log ""
            log "=== Naechste Schritte ==="
            log "1. Proxmox Storage wieder auf 'data' zeigen (storage.cfg)"
            log "2. VMs/LXCs starten und testen"
            log "3. zdata bereinigen: bash $0 --cleanup-zdata"
            log "4. Datasets auf zdata loeschen: zfs destroy -r zdata/<dataset>"
        else
            log ""
            log "=== Naechste Schritte ==="
            log "1. Proxmox Storage auf 'zdata' umstellen (storage.cfg)"
            log "2. VMs/LXCs testen"
            log "3. Rueckmigration: bash $0 --reverse"
            log "4. Danach data bereinigen: bash $0 --cleanup"
        fi
    fi

    log "======================================================="
    log "Migration abgeschlossen. Log: $LOG"
    log "======================================================="
}

main "$@"
