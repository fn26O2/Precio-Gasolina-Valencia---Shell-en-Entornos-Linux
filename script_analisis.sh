#!/usr/bin/env bash
set -euo pipefail

# --- Entorno fijo (porque cron no carga el de la terminal) ---
export PATH="/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8

# --- Rutas (siempre relativas a la carpeta del proyecto) ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASETS_DIR="$BASE_DIR/datasets"
INFORMES_DIR="$BASE_DIR/informes"
LOG_FILE="$BASE_DIR/log.txt"
ERR_FILE="$BASE_DIR/errores.log"

# --- Fecha de la ejecución ---
HOY="$(date +%Y%m%d)"

# --- Dataset ---
#URL_CARBURANTES="https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/"
URL_CARBURANTES="${URL_CARBURANTES:-https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/}"
JSON_RAW="$DATASETS_DIR/carburantes_${HOY}.json"
JSON_LIMPIO="$DATASETS_DIR/carburantes_${HOY}_limpio.json"

# --- Informes (misma marca de tiempo que el dataset) ---
INFORME_TXT="$INFORMES_DIR/informe_${HOY}.txt"
INFORME_HTML="$INFORMES_DIR/informe_${HOY}.html"

# --- Parámetros ---
PROVINCIA_ID="46"      # Valencia
DIAS_RETENCION=7       # días que se conservan los datasets
TIMEOUT_DESCARGA="${TIMEOUT_DESCARGA:-120}"   # segundos máximos de descarga

# --- Funciones de log ---
# Formato: [AAAA-MM-DD HH:MM:SS] [NIVEL] mensaje
_log() {
    local nivel="$1"; shift
    local linea
    linea="[$(date '+%Y-%m-%d %H:%M:%S')] [$nivel] $*"
    echo "$linea" >> "$LOG_FILE"
    if [ -t 1 ]; then
        echo "$linea"
    fi
}

log_info()  { _log "INFO"  "$@"; }
log_error() {
    _log "ERROR" "$@"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$ERR_FILE"
}

# ===== PARTE PABLO =====

# ----- DESCARGAR -----

descargar() {
    local tmp="$JSON_RAW.tmp"
    local codigo_curl=0

    log_info "Iniciando descarga"

    mkdir -p "$DATASETS_DIR"

    curl -fsS \
        --connect-timeout 15 \
        --max-time "$TIMEOUT_DESCARGA" \
        -H "Accept: application/json" \
        -o "$tmp" \
        "$URL_CARBURANTES" || codigo_curl=$?

    if [ "$codigo_curl" -ne 0 ]; then
        case "$codigo_curl" in
            6)  log_error "Descarga fallida: no se resuelve el dominio (¿sin internet o URL mal escrita?) (curl 6)" ;;
            7)  log_error "Descarga fallida: no se puede conectar con el servidor (curl 7)" ;;
            22) log_error "Descarga fallida: el servidor respondió con un error HTTP (curl 22)" ;;
            28) log_error "Descarga fallida: tiempo de espera agotado (curl 28)" ;;
            *)  log_error "Descarga fallida: curl terminó con código $codigo_curl" ;;
        esac
        rm -f "$tmp"
        return 1
    fi

    log_info "Descarga completada"
}

# ----- VALIDAR -----
validar() {
    local fichero="$1"

    log_info "Iniciando validación"

    # 1. ¿Está vacío?
    if [ ! -s "$fichero" ]; then
        log_error "Validación fallida: el fichero descargado está vacío"
        rm -f "$fichero"
        return 1
    fi

    # 2. ¿Es un JSON válido? (detecta descargas cortadas y páginas HTML)
    if ! jq empty "$fichero" 2>/dev/null; then
        log_error "Validación fallida: el fichero no es un JSON válido (¿truncado o página de error?)"
        rm -f "$fichero"
        return 1
    fi

    # 3. ¿Tiene la estructura esperada? (ListaEESSPrecio es una lista con estaciones)
    if ! jq -e '.ListaEESSPrecio | type == "array" and length > 0' "$fichero" > /dev/null; then
        log_error "Validación fallida: falta ListaEESSPrecio o está vacía (estructura errónea)"
        rm -f "$fichero"
        return 1
    fi

    # 4. ¿Están los campos que usa la limpieza? (detecta cambios de formato de la API)
    if ! jq -e '.ListaEESSPrecio[0] | has("IDEESS") and has("IDProvincia") and has("Rótulo") and has("Precio Gasolina 95 E5") and has("Precio Gasoleo A")' "$fichero" > /dev/null; then
        log_error "Validación fallida: faltan campos esperados en las estaciones (¿ha cambiado el formato de la API?)"
        rm -f "$fichero"
        return 1
    fi

    # 5. Todo correcto: el fichero pasa a tener su nombre definitivo
    mv "$fichero" "$JSON_RAW"
    log_info "Validación correcta"
}



# ----- LIMPIAR -----
limpiar() {
    local tmp="$JSON_LIMPIO.tmp"
    local resumen

    log_info "Iniciando limpieza"

    if ! jq '
        def num: if . == null or . == "" then null
                 else (sub(","; ".") | tonumber?) // null end;

        def rango: if . == null then null
                   elif . < 0.80 or . > 3 then null
                   else . end;

        (.ListaEESSPrecio | length) as $total

        | ([.ListaEESSPrecio[]
            | ."Precio Gasolina 95 E5", ."Precio Gasoleo A"
            | num
            | select(. != null and (. < 0.80 or . > 3))]
           | length) as $fuera_rango

        | (.ListaEESSPrecio
           | map({
               id:           .IDEESS,
               provincia_id: .IDProvincia,
               marca:        (."Rótulo" | gsub("^\\s+|\\s+$"; "") | ascii_upcase),
               municipio:    .Municipio,
               direccion:    ."Dirección",
               horario:      .Horario,
               lat:          (.Latitud | num),
               lon:          (."Longitud (WGS84)" | num),
               gasolina95:   (."Precio Gasolina 95 E5" | num | rango),
               gasoleo:      (."Precio Gasoleo A" | num | rango)
             })
           | unique_by(.id)) as $estaciones

        | {
            fecha_datos: .Fecha,
            calidad: {
              descargadas:            $total,
              duplicadas:             ($total - ($estaciones | length)),
              precios_fuera_de_rango: $fuera_rango,
              validas:                ($estaciones | length)
            },
            estaciones: $estaciones
          }
    ' "$JSON_RAW" > "$tmp"; then
        log_error "Limpieza fallida: jq no ha podido procesar $JSON_RAW"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$JSON_LIMPIO"

    resumen="$(jq -r '.calidad | "\(.descargadas) descargadas, \(.duplicadas) duplicadas, \(.precios_fuera_de_rango) precios fuera de rango, \(.validas) válidas"' "$JSON_LIMPIO")"
    log_info "Limpieza completada: $resumen"
}

# ----- BORRAR ANTIGUOS -----
borrar_antiguos() {
    local borrados

    log_info "Buscando datasets con más de $DIAS_RETENCION días"

    if ! borrados="$(find "$DATASETS_DIR" -maxdepth 1 -type f -name 'carburantes_*.json' -mtime +"$DIAS_RETENCION" -print -delete)"; then
        log_error "Borrado de antiguos fallido: no se ha podido revisar $DATASETS_DIR"
        return 1
    fi

    if [ -z "$borrados" ]; then
        log_info "No hay datasets antiguos que borrar"
    else
        log_info "Borrados $(echo "$borrados" | wc -l) datasets antiguos: $(echo "$borrados" | xargs -n1 basename | tr '\n' ' ')"
    fi
}




# ===== PARTE ÁLVARO =====
# Entrada común: "$JSON_LIMPIO" (formato acordado: fecha_datos, calidad, estaciones[]).
# Cada función debe registrar su inicio/fin con log_info y sus fallos con log_error + return 1.
 
# ----- ÁLVARO 1: EXTRAER -----
# - Filtrar las estaciones de Valencia: .provincia_id == $PROVINCIA_ID (usar jq --arg)
# - Conteo de estaciones de Valencia
# - Métricas de gasolina95 y gasoleo: mínimo, máximo y media (ignorando los null)
# - Algún filtrado de interés (p. ej. las 5 más baratas, por municipio o por marca)
extraer() {
    log_info "Extracción pendiente (Álvaro)"
}
 
# ----- ÁLVARO 2: INFORME TXT -----
# - Escribir "$INFORME_TXT" con los datos de extraer()
# - mkdir -p "$INFORMES_DIR" antes de escribir
generar_informe_txt() {
    log_info "Informe TXT pendiente (Álvaro)"
}
 
# ----- ÁLVARO 3: INFORME HTML -----
# - Escribir "$INFORME_HTML" con la misma información que el TXT
# - Estructura mínima: título, fecha, resultados
generar_informe_html() {
    log_info "Informe HTML pendiente (Álvaro)"
}




log_info "INICIO ejecución"

descargar
validar "$JSON_RAW.tmp"
limpiar
extraer
generar_informe_txt
generar_informe_html
borrar_antiguos

log_info "FIN correcto"