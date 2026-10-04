#!/usr/bin/env bash
set -euo pipefail

# --- Entorno fijo (porque cron no carga el de la terminal) ---
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C.UTF-8

# --- Rutas (siempre relativas a la carpeta del proyecto) ---
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASETS_DIR="$BASE_DIR/datasets"
INFORMES_DIR="$BASE_DIR/informes"
LOG_FILE="$BASE_DIR/log.txt"
ERR_FILE="$BASE_DIR/errores.log"

# --- Fecha de la ejecución ---
HOY="$(date +%Y%m%d)"
FECHA_HUMANA="$(date '+%d/%m/%Y %H:%M:%S')"
# --- Dataset ---
#URL_CARBURANTES="https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/"
URL_CARBURANTES="${URL_CARBURANTES:-https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/}"
JSON_RAW="$DATASETS_DIR/carburantes_${HOY}.json"
JSON_LIMPIO="$DATASETS_DIR/carburantes_${HOY}_limpio.json"
JSON_RESUMEN="$DATASETS_DIR/carburantes_${HOY}_resumen.json"

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
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" \
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

# ----- EXTRAER -----
extraer() {
    log_info "INICIO: Extracción de métricas desde $JSON_LIMPIO..."

    # Validación de existencia del archivo de entrada
    if [ ! -f "$JSON_LIMPIO" ]; then
        log_error "Error: El archivo limpio de entrada ($JSON_LIMPIO) no existe."
        return 1
    fi

    # Configuración por defecto de PROVINCIA_ID si no está definida globalmente
    local prov_id="${PROVINCIA_ID:-46}"

    # 1. Obtener la lista cronológica de datasets acumulados para la evolución semanal
    local lista_datasets
    lista_datasets=($(ls -1 "$DATASETS_DIR"/carburantes_*_limpio.json 2>/dev/null | sort))
    local num_dias=${#lista_datasets[@]}

    log_info "Histórico detectado: $num_dias día(s) acumulado(s)."

    # 2. Procesar el histórico para calcular la serie temporal mediante jq
    local evol_json="[]"
    if [ $num_dias -gt 0 ]; then
        evol_json=$(jq -s --arg prov "$prov_id" '
            map({
                fecha: .fecha_datos,
                val_g95: ([.estaciones[] | select(.provincia_id == $prov and .gasolina95 != null) | .gasolina95] | if length > 0 then (add/length) else null end),
                val_gasoleo: ([.estaciones[] | select(.provincia_id == $prov and .gasoleo != null) | .gasoleo] | if length > 0 then (add/length) else null end),
                esp_g95: ([.estaciones[] | .gasolina95 | select(. != null)] | if length > 0 then (add/length) else null end),
                esp_gasoleo: ([.estaciones[] | .gasoleo | select(. != null)] | if length > 0 then (add/length) else null end)
            })
        ' "${lista_datasets[@]}")
    fi

    # 3. Extraer métricas consolidadas y generar $JSON_RESUMEN
    jq --arg prov "$prov_id" --argjson evol "$evol_json" '
        # Filtrado base de estaciones
        (.estaciones | map(select(.provincia_id == $prov))) as $valencia |
        .estaciones as $espana |
        
        # Precios de Valencia
        ([$valencia[] | .gasolina95 | select(. != null)]) as $val_g95_list |
        ([$valencia[] | .gasoleo | select(. != null)]) as $val_gasoleo_list |
        
        # Precios de España
        ([$espana[] | .gasolina95 | select(. != null)]) as $esp_g95_list |
        ([$espana[] | .gasoleo | select(. != null)]) as $esp_gasoleo_list |

        # Cálculo de Medias
        (($val_g95_list | if length > 0 then (add/length) else 0 end)) as $med_val_g95 |
        (($val_gasoleo_list | if length > 0 then (add/length) else 0 end)) as $med_val_gasoleo |
        (($esp_g95_list | if length > 0 then (add/length) else 0 end)) as $med_esp_g95 |
        (($esp_gasoleo_list | if length > 0 then (add/length) else 0 end)) as $med_esp_gasoleo |

        {
            fecha_datos: .fecha_datos,
            calidad: .calidad,
            valencia: {
                total_estaciones: ($valencia | length),
                sin_precio: ($valencia | map(select(.gasolina95 == null and .gasoleo == null)) | length),
                gasolina95: {
                    min: ($val_g95_list | if length > 0 then min else 0 end),
                    media: $med_val_g95,
                    max: ($val_g95_list | if length > 0 then max else 0 end)
                },
                gasoleo: {
                    min: ($val_gasoleo_list | if length > 0 then min else 0 end),
                    media: $med_val_gasoleo,
                    max: ($val_gasoleo_list | if length > 0 then max else 0 end)
                }
            },
            espana: {
                total_estaciones: ($espana | length),
                gasolina95_media: $med_esp_g95,
                gasoleo_medio: $med_esp_gasoleo
            },
            comparacion: {
                gasolina95: {
                    diff_eur: ($med_val_g95 - $med_esp_g95),
                    diff_pct: (if $med_esp_g95 > 0 then (($med_val_g95 - $med_esp_g95) / $med_esp_g95 * 100) else 0 end)
                },
                gasoleo: {
                    diff_eur: ($med_val_gasoleo - $med_esp_gasoleo),
                    diff_pct: (if $med_esp_gasoleo > 0 then (($med_val_gasoleo - $med_esp_gasoleo) / $med_esp_gasoleo * 100) else 0 end)
                }
            },
            evolucion_semanal: $evol,
            top5_baratas: {
                gasolina95: ([$valencia[] | select(.gasolina95 != null)] | sort_by(.gasolina95) | .[0:5] | map({marca, municipio, direccion, precio: .gasolina95})),
                gasoleo: ([$valencia[] | select(.gasoleo != null)] | sort_by(.gasoleo) | .[0:5] | map({marca, municipio, direccion, precio: .gasoleo}))
            },
            marcas_medies_valencia: (
                $valencia 
                | group_by(.marca) 
                | map(select(length >= 5) | {
                    marca: .[0].marca,
                    total_estaciones: length,
                    media_g95: ([.[].gasolina95 | select(. != null)] | if length > 0 then (add/length) else 0 end),
                    media_gasoleo: ([.[].gasoleo | select(. != null)] | if length > 0 then (add/length) else 0 end)
                })
                | sort_by(.marca)
            )
        }
    ' "$JSON_LIMPIO" > "$JSON_RESUMEN"

    if [ $? -ne 0 ] || [ ! -s "$JSON_RESUMEN" ]; then
        log_error "Fallo al generar el archivo JSON de resumen ($JSON_RESUMEN)."
        return 1
    fi

    log_info "FIN: Extracción completada con éxito. Guardado en $JSON_RESUMEN."
    return 0
}

# ----- INFORME TXT -----
generar_informe_txt() {
    log_info "INICIO: Generando informe TXT en $INFORME_TXT..."

    if [ ! -f "$JSON_RESUMEN" ]; then
        log_error "Error: No se encuentra el JSON de resumen ($JSON_RESUMEN)."
        return 1
    fi

    local dir_informes
    dir_informes=$(dirname "$INFORME_TXT")
    mkdir -p "$dir_informes"

    # Extracción de valores con jq para la plantilla de texto
    local fecha_datos=$(jq -r '.fecha_datos' "$JSON_RESUMEN")
    local val_total=$(jq -r '.valencia.total_estaciones' "$JSON_RESUMEN")
    local val_sin_precio=$(jq -r '.valencia.sin_precio' "$JSON_RESUMEN")
    local esp_total=$(jq -r '.espana.total_estaciones' "$JSON_RESUMEN")

    local v_g95_min=$(jq -r '.valencia.gasolina95.min' "$JSON_RESUMEN")
    local v_g95_med=$(jq -r '.valencia.gasolina95.media' "$JSON_RESUMEN")
    local v_g95_max=$(jq -r '.valencia.gasolina95.max' "$JSON_RESUMEN")

    local v_gas_min=$(jq -r '.valencia.gasoleo.min' "$JSON_RESUMEN")
    local v_gas_med=$(jq -r '.valencia.gasoleo.media' "$JSON_RESUMEN")
    local v_gas_max=$(jq -r '.valencia.gasoleo.max' "$JSON_RESUMEN")

    local e_g95_med=$(jq -r '.espana.gasolina95_media' "$JSON_RESUMEN")
    local e_gas_med=$(jq -r '.espana.gasoleo_medio' "$JSON_RESUMEN")

    local diff_g95_eur=$(jq -r '.comparacion.gasolina95.diff_eur' "$JSON_RESUMEN")
    local diff_g95_pct=$(jq -r '.comparacion.gasolina95.diff_pct' "$JSON_RESUMEN")
    local diff_gas_eur=$(jq -r '.comparacion.gasoleo.diff_eur' "$JSON_RESUMEN")
    local diff_gas_pct=$(jq -r '.comparacion.gasoleo.diff_pct' "$JSON_RESUMEN")

    local calidad_nota=$(jq -r '.calidad // "Sin observaciones de calidad"' "$JSON_RESUMEN")

    cat <<EOF > "$INFORME_TXT"
================================================================================
INFORME MONITOREO DE CARBURANTES - PROVINCIA DE VALENCIA
Fecha de Datos: $fecha_datos | Fecha Emisión: $FECHA_HUMANA
================================================================================

1. PRECIOS EN VALENCIA ($val_total estaciones)
--------------------------------------------------------------------------------
   * Gasolina 95:
     - Mínimo: $(printf "%.3f" $v_g95_min) €/L
     - Medio:  $(printf "%.3f" $v_g95_med) €/L
     - Máximo: $(printf "%.3f" $v_g95_max) €/L
   * Diésel (Gasóleo A):
     - Mínimo: $(printf "%.3f" $v_gas_min) €/L
     - Medio:  $(printf "%.3f" $v_gas_med) €/L
     - Máximo: $(printf "%.3f" $v_gas_max) €/L

2. VALENCIA FRENTE A ESPAÑA ($esp_total estaciones nacionales)
--------------------------------------------------------------------------------
   * Gasolina 95:
     - Media Valencia: $(printf "%.3f" $v_g95_med) €/L
     - Media España:   $(printf "%.3f" $e_g95_med) €/L
     - Diferencia:     $(printf "%+.3f" $diff_g95_eur) €/L ($(printf "%+.2f" $diff_g95_pct)%)
   * Diésel:
     - Media Valencia: $(printf "%.3f" $v_gas_med) €/L
     - Media España:   $(printf "%.3f" $e_gas_med) €/L
     - Diferencia:     $(printf "%+.3f" $diff_gas_eur) €/L ($(printf "%+.2f" $diff_gas_pct)%)

3. EVOLUCIÓN DE LA SEMANA
--------------------------------------------------------------------------------
$(jq -r '
    def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end);
    if (.evolucion_semanal | length) <= 1 then
        "   [!] Nota: Solo se dispone de 1 día registrado. Se requieren más datos para mostrar la tendencia semanal."
    else
        .evolucion_semanal[] | "   - Fecha: \(.fecha) | Val G95: \(.val_g95 | if . then (f(3)) else "N/A" end) €/L | Val Diésel: \(.val_gasoleo | if . then (f(3)) else "N/A" end) €/L"
    end
' "$JSON_RESUMEN")

4. DÓNDE REPOSTAR MÁS BARATO EN VALENCIA
--------------------------------------------------------------------------------
   TOP 5 GASOLINA 95:
$(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .top5_baratas.gasolina95[] | "   * \(.marca) (\(.municipio)) - \(.direccion): \(.precio | f(3)) €/L"' "$JSON_RESUMEN")

   TOP 5 DIÉSEL:
$(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .top5_baratas.gasoleo[] | "   * \(.marca) (\(.municipio)) - \(.direccion): \(.precio | f(3)) €/L"' "$JSON_RESUMEN")

5. PRECIO MEDIO POR MARCA EN VALENCIA (mínimo 5 estaciones)
--------------------------------------------------------------------------------
$(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .marcas_medies_valencia[] | "   * \(.marca) (\(.total_estaciones) est.): G95: \(.media_g95 | f(3)) €/L | Diésel: \(.media_gasoleo | f(3)) €/L"' "$JSON_RESUMEN")

6. NOTA SOBRE LOS DATOS Y CALIDAD
--------------------------------------------------------------------------------
   - Calidad indicada por origen: $calidad_nota
   - Estaciones registradas en Valencia sin precio publicado: $val_sin_precio
================================================================================
EOF

    log_info "FIN: Informe TXT generado correctamente en $INFORME_TXT."
    return 0
}

# ----- INFORME HTML -----
generar_informe_html() {
    log_info "INICIO: Generando informe HTML en $INFORME_HTML..."

    if [ ! -f "$JSON_RESUMEN" ]; then
        log_error "Error: No se encuentra el JSON de resumen ($JSON_RESUMEN)."
        return 1
    fi

    local dir_informes
    dir_informes=$(dirname "$INFORME_HTML")
    mkdir -p "$dir_informes"

    # Variables de resumen para HTML
    local fecha_datos=$(jq -r '.fecha_datos' "$JSON_RESUMEN")
    local val_total=$(jq -r '.valencia.total_estaciones' "$JSON_RESUMEN")
    local val_sin_precio=$(jq -r '.valencia.sin_precio' "$JSON_RESUMEN")
    local esp_total=$(jq -r '.espana.total_estaciones' "$JSON_RESUMEN")

    local v_g95_med=$(jq -r '.valencia.gasolina95.media' "$JSON_RESUMEN")
    local v_gas_med=$(jq -r '.valencia.gasoleo.media' "$JSON_RESUMEN")
    local e_g95_med=$(jq -r '.espana.gasolina95_media' "$JSON_RESUMEN")
    local e_gas_med=$(jq -r '.espana.gasoleo_medio' "$JSON_RESUMEN")

    local diff_g95_eur=$(jq -r '.comparacion.gasolina95.diff_eur' "$JSON_RESUMEN")
    local diff_gas_eur=$(jq -r '.comparacion.gasoleo.diff_eur' "$JSON_RESUMEN")

    local calidad_nota=$(jq -r '.calidad // "Sin observaciones de calidad"' "$JSON_RESUMEN")

    # Datos serializados para los graficos Chart.js
    local evolucion_json=$(jq -c '{
        fechas:      [.evolucion_semanal[].fecha],
        val_g95:     [.evolucion_semanal[].val_g95],
        esp_g95:     [.evolucion_semanal[].esp_g95],
        val_gasoleo: [.evolucion_semanal[].val_gasoleo],
        esp_gasoleo: [.evolucion_semanal[].esp_gasoleo]
    }' "$JSON_RESUMEN")
    local marcas_json=$(jq -c '[.marcas_medies_valencia[] | {marca, media_g95, media_gasoleo}]' "$JSON_RESUMEN")

    cat <<EOF > "$INFORME_HTML"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Informe de Mercado de Carburantes - Valencia</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <style>
        :root {
            --navy: #1a365d;
            --navy-light: #2c5282;
            --bg: #f7fafc;
            --card: #ffffff;
            --text: #2d3748;
            --text-muted: #718096;
            --border: #e2e8f0;
            --green: #38a169;
            --red: #e53e3e;
            --shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06);
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }

        .navbar { position: sticky; top: 0; z-index: 100; background: linear-gradient(135deg, var(--navy) 0%, var(--navy-light) 100%); color: white; padding: 16px 24px; box-shadow: var(--shadow); }
        .navbar-content { max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px; }
        .navbar h1 { font-size: 20px; font-weight: 700; }
        .navbar .dates { font-size: 13px; opacity: 0.92; text-align: right; line-height: 1.5; }

        .container { max-width: 1200px; margin: 0 auto; padding: 24px 16px; }

        .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 16px; margin-bottom: 20px; }
        .kpi { background: var(--card); border-radius: 12px; box-shadow: var(--shadow); padding: 20px; text-align: center; border-top: 4px solid var(--navy-light); }
        .kpi .value { font-size: 26px; font-weight: 700; color: var(--navy); }
        .kpi .label { font-size: 11px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-top: 4px; }

        .card { background: var(--card); border-radius: 12px; box-shadow: var(--shadow); padding: 24px; border: 1px solid var(--border); margin-bottom: 20px; }
        .card h2 { font-size: 16px; color: var(--navy); margin-bottom: 16px; padding-bottom: 10px; border-bottom: 2px solid var(--border); }
        .card h3 { font-size: 14px; color: var(--navy-light); margin: 16px 0 8px; }

        table { width: 100%; border-collapse: collapse; font-size: 14px; }
        th { background: #edf2f7; color: var(--navy); font-weight: 600; text-align: left; padding: 10px 12px; }
        td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
        tbody tr { transition: background 0.2s ease; }
        tbody tr:hover { background: #ebf4ff; }

        .arrow-up { color: var(--red); font-weight: 700; }
        .arrow-down { color: var(--green); font-weight: 700; }

        .chart-container { position: relative; height: 320px; margin-top: 16px; }

        .footer { text-align: center; color: var(--text-muted); font-size: 12px; padding: 24px; }

        @media (max-width: 768px) {
            .navbar-content { flex-direction: column; text-align: center; }
            .navbar .dates { text-align: center; }
            .chart-container { height: 260px; }
            .kpi .value { font-size: 22px; }
        }
    </style>
</head>
<body>
    <nav class="navbar">
        <div class="navbar-content">
            <h1>⛽ Monitor de Precios de Carburantes</h1>
            <div class="dates">
                <div>Provincia de Valencia</div>
                <div>Datos: $fecha_datos | Emisión: $FECHA_HUMANA</div>
            </div>
        </div>
    </nav>

    <div class="container">
        <div class="kpi-grid">
            <div class="kpi"><div class="value">$val_total</div><div class="label">Estaciones Valencia</div></div>
            <div class="kpi"><div class="value">$(printf "%.3f" $v_g95_med)</div><div class="label">Media G95 Valencia (€/L)</div></div>
            <div class="kpi"><div class="value">$(printf "%.3f" $v_gas_med)</div><div class="label">Media Diésel Valencia (€/L)</div></div>
            <div class="kpi"><div class="value">$esp_total</div><div class="label">Estaciones España</div></div>
        </div>

        <!-- 1. Precios en Valencia -->
        <div class="card">
            <h2>1. Precios en Valencia</h2>
            <table>
                <thead>
                    <tr><th>Carburante</th><th>Precio Mínimo</th><th>Precio Medio</th><th>Precio Máximo</th></tr>
                </thead>
                <tbody>
                    $(jq -r '
                        def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end);
                        "<tr><td><strong>Gasolina 95</strong></td><td>" + (.valencia.gasolina95.min | f(3)) + " €/L</td><td><strong>" + (.valencia.gasolina95.media | f(3)) + " €/L</strong></td><td>" + (.valencia.gasolina95.max | f(3)) + " €/L</td></tr>" +
                        "<tr><td><strong>Diésel</strong></td><td>" + (.valencia.gasoleo.min | f(3)) + " €/L</td><td><strong>" + (.valencia.gasoleo.media | f(3)) + " €/L</strong></td><td>" + (.valencia.gasoleo.max | f(3)) + " €/L</td></tr>"
                    ' "$JSON_RESUMEN")
                </tbody>
            </table>
        </div>

        <!-- 2. Valencia frente a España -->
        <div class="card">
            <h2>2. Valencia frente a España</h2>
            <table>
                <thead>
                    <tr><th>Carburante</th><th>Media Valencia</th><th>Media España</th><th>Diferencia (€/L)</th><th>Diferencia (%)</th></tr>
                </thead>
                <tbody>
                    <tr>
                        <td><strong>Gasolina 95</strong></td>
                        <td>$(printf "%.3f" $v_g95_med) €/L</td>
                        <td>$(printf "%.3f" $e_g95_med) €/L</td>
                        <td>
                            $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); if .comparacion.gasolina95.diff_eur > 0 then "<span class=\"arrow-up\">↑ +" + (.comparacion.gasolina95.diff_eur | f(3)) + " €/L</span>" else "<span class=\"arrow-down\">↓ " + (.comparacion.gasolina95.diff_eur | f(3)) + " €/L</span>" end' "$JSON_RESUMEN")
                        </td>
                        <td>
                            $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); if .comparacion.gasolina95.diff_pct > 0 then "<span class=\"arrow-up\">↑ +" + (.comparacion.gasolina95.diff_pct | f(2)) + "%</span>" else "<span class=\"arrow-down\">↓ " + (.comparacion.gasolina95.diff_pct | f(2)) + "%</span>" end' "$JSON_RESUMEN")
                        </td>
                    </tr>
                    <tr>
                        <td><strong>Diésel</strong></td>
                        <td>$(printf "%.3f" $v_gas_med) €/L</td>
                        <td>$(printf "%.3f" $e_gas_med) €/L</td>
                        <td>
                            $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); if .comparacion.gasoleo.diff_eur > 0 then "<span class=\"arrow-up\">↑ +" + (.comparacion.gasoleo.diff_eur | f(3)) + " €/L</span>" else "<span class=\"arrow-down\">↓ " + (.comparacion.gasoleo.diff_eur | f(3)) + " €/L</span>" end' "$JSON_RESUMEN")
                        </td>
                        <td>
                            $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); if .comparacion.gasoleo.diff_pct > 0 then "<span class=\"arrow-up\">↑ +" + (.comparacion.gasoleo.diff_pct | f(2)) + "%</span>" else "<span class=\"arrow-down\">↓ " + (.comparacion.gasoleo.diff_pct | f(2)) + "%</span>" end' "$JSON_RESUMEN")
                        </td>
                    </tr>
                </tbody>
            </table>
        </div>

        <!-- 3. Evolución semanal con gráfico interactivo -->
        <div class="card">
            <h2>3. Evolución Semanal: Valencia vs España</h2>
            <div class="chart-container"><canvas id="evolucionChart"></canvas></div>
        </div>

        <!-- 4. Dónde repostar más barato -->
        <div class="card">
            <h2>4. Dónde Repostar más Barato en Valencia</h2>
            <h3>Top 5 Gasolina 95</h3>
            <table>
                <thead><tr><th>Marca</th><th>Municipio</th><th>Dirección</th><th>Precio</th></tr></thead>
                <tbody>
                    $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .top5_baratas.gasolina95[] | "<tr><td><strong>" + .marca + "</strong></td><td>" + .municipio + "</td><td>" + .direccion + "</td><td><span class=\"arrow-down\">" + (.precio | f(3)) + " €/L</span></td></tr>"' "$JSON_RESUMEN")
                </tbody>
            </table>
            <h3>Top 5 Diésel</h3>
            <table>
                <thead><tr><th>Marca</th><th>Municipio</th><th>Dirección</th><th>Precio</th></tr></thead>
                <tbody>
                    $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .top5_baratas.gasoleo[] | "<tr><td><strong>" + .marca + "</strong></td><td>" + .municipio + "</td><td>" + .direccion + "</td><td><span class=\"arrow-down\">" + (.precio | f(3)) + " €/L</span></td></tr>"' "$JSON_RESUMEN")
                </tbody>
            </table>
        </div>

        <!-- 5. Precio medio por marca con gráfico interactivo -->
        <div class="card">
            <h2>5. Precio Medio por Marca en Valencia (&ge; 5 Estaciones)</h2>
            <div class="chart-container"><canvas id="marcasChart"></canvas></div>
            <table>
                <thead><tr><th>Marca</th><th>Estaciones</th><th>Media Gasolina 95</th><th>Media Diésel</th></tr></thead>
                <tbody>
                    $(jq -r 'def f($n): ((. * (pow(10; $n)) | floor) | tostring) as $s | ($s | ltrimstr("-")) as $a | ($a | length) as $l | (if ($s | startswith("-")) then "-" else "" end) + (if $l <= $n then "0." + ("0" * ($n - $l)) + $a else $a[0:($l-$n)] + "." + $a[$l-$n:] end); .marcas_medies_valencia[] | "<tr><td><strong>" + .marca + "</strong></td><td>" + (.total_estaciones | tostring) + "</td><td>" + (.media_g95 | f(3)) + " €/L</td><td>" + (.media_gasoleo | f(3)) + " €/L</td></tr>"' "$JSON_RESUMEN")
                </tbody>
            </table>
        </div>

        <!-- 6. Nota sobre los datos -->
        <div class="card">
            <h2>6. Nota sobre los Datos y Calidad</h2>
            <p><strong>Observaciones de origen:</strong> $calidad_nota</p>
            <p><strong>Estaciones sin precio publicado en Valencia:</strong> $val_sin_precio</p>
        </div>

        <div class="footer">
            Proyecto Shell Script - Máster en IA & Big Data | Módulo de Análisis e Informes (Álvaro)
        </div>
    </div>

    <script>
        var evolucionData = $evolucion_json;
        var marcasData = $marcas_json;

        new Chart(document.getElementById('evolucionChart'), {
            type: 'line',
            data: {
                labels: evolucionData.fechas,
                datasets: [
                    { label: 'Valencia G95', data: evolucionData.val_g95, borderColor: '#2c5282', backgroundColor: 'rgba(44,82,130,0.12)', fill: true, tension: 0.3, pointRadius: 4 },
                    { label: 'España G95', data: evolucionData.esp_g95, borderColor: '#e53e3e', backgroundColor: 'rgba(229,62,62,0.10)', fill: true, tension: 0.3, pointRadius: 4 },
                    { label: 'Valencia Diésel', data: evolucionData.val_gasoleo, borderColor: '#38a169', backgroundColor: 'rgba(56,161,105,0.12)', fill: true, tension: 0.3, pointRadius: 4 },
                    { label: 'España Diésel', data: evolucionData.esp_gasoleo, borderColor: '#d69e2e', backgroundColor: 'rgba(214,158,46,0.10)', fill: true, tension: 0.3, pointRadius: 4 }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: { legend: { position: 'bottom', labels: { usePointStyle: true, padding: 16 } } },
                scales: { y: { title: { display: true, text: '€/L' }, beginAtZero: false } }
            }
        });

        new Chart(document.getElementById('marcasChart'), {
            type: 'bar',
            data: {
                labels: marcasData.map(function(m) { return m.marca; }),
                datasets: [
                    { label: 'Gasolina 95', data: marcasData.map(function(m) { return m.media_g95; }), backgroundColor: '#2c5282', borderRadius: 4 },
                    { label: 'Diésel', data: marcasData.map(function(m) { return m.media_gasoleo; }), backgroundColor: '#38a169', borderRadius: 4 }
                ]
            },
            options: {
                indexAxis: 'y',
                responsive: true,
                maintainAspectRatio: false,
                plugins: { legend: { position: 'bottom', labels: { usePointStyle: true, padding: 16 } } },
                scales: { x: { title: { display: true, text: '€/L' } } }
            }
        });
    </script>
</body>
</html>
EOF

    log_info "FIN: Informe HTML generado correctamente en $INFORME_HTML."
    return 0
}

# ===== FIN PARTE ÁLVARO =====


# ===== EJECUCIÓN =====
log_info "INICIO ejecución"

descargar
validar "$JSON_RAW.tmp"
limpiar
extraer
generar_informe_txt
generar_informe_html
borrar_antiguos

log_info "FIN correcto"