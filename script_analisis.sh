#!/usr/bin/env bash
# lib.sh - variables y funciones comunes del proyecto
# Se carga desde script_analisis.sh con: source lib.sh

# --- Rutas (siempre relativas a la carpeta del proyecto) ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASETS_DIR="$BASE_DIR/datasets"
INFORMES_DIR="$BASE_DIR/informes"
LOG_FILE="$BASE_DIR/log.txt"
ERR_FILE="$BASE_DIR/errores.log"

# --- Fecha de la ejecución ---
HOY="$(date +%Y%m%d)"

# --- Dataset ---
URL_CARBURANTES="https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/"
JSON_RAW="$DATASETS_DIR/carburantes_${HOY}.json"
JSON_LIMPIO="$DATASETS_DIR/carburantes_${HOY}_limpio.json"

# --- Parámetros ---
PROVINCIA_ID="46"      # Valencia
DIAS_RETENCION=7       # días que se guardan datasets e informes

# --- Funciones de log ---
# Formato: [AAAA-MM-DD HH:MM:SS] [NIVEL] mensaje
_log() {
    local nivel="$1"; shift
    local linea
    linea="[$(date '+%Y-%m-%d %H:%M:%S')] [$nivel] $*"
    echo "$linea" >> "$LOG_FILE"
    echo "$linea"
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() {
    _log "ERROR" "$@"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$ERR_FILE"
}