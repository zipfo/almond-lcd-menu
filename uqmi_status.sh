#!/bin/sh
# uqmi_status.sh — collect LTE status via uqmi --single
# Outputs full JSON with signal, cell, identity data.
#
# IMPORTANT: We use --single flag which allocates/releases a temporary client ID
# per call. This is safe for concurrent use with netifd — no killall needed.
# The -t 5000 timeout prevents hanging if modem is unresponsive.

QMI_DEV="${1:-/dev/cdc-wdm0}"
OUT="${2:-/tmp/lte_uqmi.json}"
TIMEOUT=5000

RSRP=0; RSRQ=0; RSSI=0; SINR=0; MODE=""; MCC=0; MNC=0; BAND=""; PCI=0
CELL_ID=0; ENB_ID=0; TAC=0; IMEI=""

# Signal info
SIG=$(uqmi -d "$QMI_DEV" -t $TIMEOUT --get-signal-info --single 2>/dev/null)
if [ -n "$SIG" ]; then
    RSRP=$(echo "$SIG" | jsonfilter -e '@.rsrp' 2>/dev/null)
    RSRQ=$(echo "$SIG" | jsonfilter -e '@.rsrq' 2>/dev/null)
    RSSI=$(echo "$SIG" | jsonfilter -e '@.rssi' 2>/dev/null)
    SINR=$(echo "$SIG" | jsonfilter -e '@.snr' 2>/dev/null | awk -F. '{print $1}')
    TYPE=$(echo "$SIG" | jsonfilter -e '@.type' 2>/dev/null)
    case "$TYPE" in lte|LTE) MODE="LTE" ;; wcdma|WCDMA) MODE="3G" ;; gsm|GSM) MODE="2G" ;; nr*|5G*) MODE="5G" ;; esac
fi

# Serving system
SYS=$(uqmi -d "$QMI_DEV" -t $TIMEOUT --get-serving-system --single 2>/dev/null)
if [ -n "$SYS" ]; then
    MCC=$(echo "$SYS" | jsonfilter -e '@.plmn_mcc' 2>/dev/null)
    MNC=$(echo "$SYS" | jsonfilter -e '@.plmn_mnc' 2>/dev/null)
fi

# Cell info (uqmi outputs malformed JSON — use grep instead of jsonfilter)
CELL=$(uqmi -d "$QMI_DEV" -t $TIMEOUT --get-cell-location-info --single 2>/dev/null)
if [ -n "$CELL" ]; then
    B=$(echo "$CELL" | grep -o '"band":[0-9]*' | head -1)
    [ -n "$B" ] && BAND="B${B#*:}"
    P=$(echo "$CELL" | grep -o '"serving_cell_id":[0-9]*' | head -1)
    [ -n "$P" ] && PCI=${P#*:}
    # Cell Identity (short, 8-bit) and eNodeB ID (20-bit)
    CI=$(echo "$CELL" | grep -o '"cell_id":[0-9]*' | head -1)
    [ -n "$CI" ] && CELL_ID=${CI#*:}
    EI=$(echo "$CELL" | grep -o '"enodeb_id":[0-9]*' | head -1)
    [ -n "$EI" ] && ENB_ID=${EI#*:}
    # Tracking Area Code
    TA=$(echo "$CELL" | grep -o '"tracking_area_code":[0-9]*' | head -1)
    [ -n "$TA" ] && TAC=${TA#*:}
fi

# IMEI (device identity)
IMEI_RAW=$(uqmi -d "$QMI_DEV" -t $TIMEOUT --get-imei --single 2>/dev/null)
if [ -n "$IMEI_RAW" ]; then
    # uqmi returns IMEI as JSON string: "867962043962540"
    IMEI=$(echo "$IMEI_RAW" | tr -d '"' | tr -d '[:space:]')
fi

# Write clean JSON atomically
printf '{"rsrp":%s,"rsrq":%s,"rssi":%s,"sinr":%s,"mode":"%s","mcc":%s,"mnc":%s,"band":"%s","pci":%s,"cell_id":%s,"enb_id":%s,"tac":%s,"imei":"%s"}' \
    "${RSRP:-0}" "${RSRQ:-0}" "${RSSI:-0}" "${SINR:-0}" "$MODE" "${MCC:-0}" "${MNC:-0}" "$BAND" "${PCI:-0}" "${CELL_ID:-0}" "${ENB_ID:-0}" "${TAC:-0}" "${IMEI:-}" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"