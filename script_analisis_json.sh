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
URL_CARBURANTES="${URL_CARBURANTES:-https://sedeaplicaciones.minetur.gob.es/ServiciosRESTCarburantes/PreciosCarburantes/EstacionesTerrestres/}"
JSON_RAW="$DATASETS_DIR/carburantes_${HOY}.json"
JSON_LIMPIO="$DATASETS_DIR/carburantes_${HOY}_limpio.json"
JSON_RESUMEN="$DATASETS_DIR/carburantes_${HOY}_resumen.json"

# --- Informes (misma marca de tiempo que el dataset) ---
INFORME_TXT="$INFORMES_DIR/informe_${HOY}.txt"
INFORME_HTML="$INFORMES_DIR/informe_${HOY}.html"

# --- Parámetros ---
PROVINCIA_ID="46"      # Valencia
DIAS_RETENCION=7       # días que se conservan los datasets (solo los datasets, no el log)
TIMEOUT_DESCARGA="${TIMEOUT_DESCARGA:-120}"   # segundos máximos de descarga
MIN_ESTACIONES_MARCA=5 # mínimo de gasolineras para calcular la media de una marca
# Provincias que no entran en la media de referencia porque tienen otros impuestos sobre el carburante:
# Las Palmas (35), Santa Cruz de Tenerife (38), Ceuta (51) y Melilla (52). En los informes aparece como "España*".
PROVINCIAS_FUERA_REFERENCIA="35 38 51 52"

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

        # El ministerio pone el artículo al final: "Pobla de Vallbona (la)" -> "La Pobla de Vallbona"
        def articulo: if test("^.+ \\([^)]+\\)$") then
                          capture("^(?<n>.+) \\((?<a>[^)]+)\\)$")
                          | (if (.a | endswith("'"'"'")) then .a + .n else .a + " " + .n end)
                          | (.[0:1] | ascii_upcase) + .[1:]
                      else . end;

        (.ListaEESSPrecio | length) as $total

        | ([.ListaEESSPrecio[]
            | ."Precio Gasolina 95 E5", ."Precio Gasoleo A"
            | num
            | select(. != null and (. < 0.80 or . > 3))]
           | length) as $fuera_rango

        | (.ListaEESSPrecio
           | to_entries
           | map(.key as $orden | .value | {
               orden:        $orden,
               id:           .IDEESS,
               provincia_id: .IDProvincia,
               marca:        (."Rótulo" | gsub("^\\s+|\\s+$"; "") | ascii_upcase),
               municipio:    (.Municipio | articulo),
               direccion:    ."Dirección",
               horario:      .Horario,
               lat:          (.Latitud | num),
               lon:          (."Longitud (WGS84)" | num),
               gasolina95:   (."Precio Gasolina 95 E5" | num | rango),
               gasoleo:      (."Precio Gasoleo A" | num | rango)
             })
           # quita duplicados (se queda con la primera aparición) y recupera el orden original
           | group_by(.id) | map(.[0])
           | sort_by(.orden) | map(del(.orden))) as $estaciones

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
# Conserva los datasets de los últimos DIAS_RETENCION días (hoy incluido) y borra los anteriores.
# La fecha se lee del nombre del fichero (carburantes_AAAAMMDD...), no de la fecha de modificación,
# así el resultado no depende de cuándo se copió o se tocó cada fichero.
borrar_antiguos() {
    local limite fichero nombre fecha
    local borrados="" total=0

    limite="$(date -d "-$((DIAS_RETENCION - 1)) days" +%Y%m%d 2>/dev/null || date -v-"$((DIAS_RETENCION - 1))"d +%Y%m%d)"
    log_info "Buscando datasets anteriores al $limite (se conservan los últimos $DIAS_RETENCION días)"

    for fichero in "$DATASETS_DIR"/carburantes_*.json; do
        [ -e "$fichero" ] || continue
        nombre="$(basename "$fichero")"
        fecha="${nombre:12:8}"
        if [[ ! "$fecha" =~ ^[0-9]{8}$ ]]; then
            continue
        fi
        if [ "$fecha" -lt "$limite" ]; then
            if ! rm -f "$fichero"; then
                log_error "Borrado de antiguos fallido: no se ha podido borrar $nombre"
                return 1
            fi
            borrados="$borrados $nombre"
            total=$((total + 1))
        fi
    done

    if [ "$total" -eq 0 ]; then
        log_info "No hay datasets antiguos que borrar"
    else
        log_info "Borrados $total datasets antiguos:$borrados"
    fi
}

# ===== FIN PARTE PABLO =====


# ===== PARTE ÁLVARO =====

# Funciones jq compartidas por la extracción y los informes:
#   media     -> media de una lista de números (null si está vacía)
#   fmt(d)    -> número con d decimales y coma decimal, redondeado (null -> "N/D")
#   conSigno  -> como fmt pero con "+" delante si es positivo
#   flecha    -> ↑ sube, ↓ baja, = igual (cambios de menos de medio milésimo cuentan como igual)
#   pad(n)    -> rellena con espacios a la derecha hasta n caracteres (para alinear columnas)
#   miles     -> entero con separador de miles: 11495 -> "11.495"
#   esc       -> escapa &, < y > para meter texto en el HTML sin romperlo
JQ_FUNCIONES='
def media: if length > 0 then add / length else null end;
def fmt($d):
    if . == null then "N/D"
    else (. * pow(10; $d) | round | if . == 0 then 0 else . end) as $r
       | (if $r < 0 then -$r else $r end | tostring) as $s
       | (if ($s | length) <= $d then ("0" * ($d + 1 - ($s | length))) + $s else $s end) as $p
       | (if $r < 0 then "-" else "" end) + $p[0:($p | length) - $d] + "," + $p[($p | length) - $d:]
    end;
def conSigno($d): fmt($d) as $t | if . != null and . > 0 and ($t | test("[1-9]")) then "+" + $t else $t end;
def flecha: if . == null then "" elif . >= 0.0005 then "↑" elif . <= -0.0005 then "↓" else "=" end;
def pad($n): tostring as $s | if ($s | length) >= $n then $s else $s + (" " * ($n - ($s | length))) end;
def miles: tostring as $s | if ($s | length) <= 3 then $s else ($s[0:-3] | miles) + "." + $s[-3:] end;
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
'

# ----- EXTRAER -----
# Lee "$JSON_LIMPIO" (y los _limpio.json de días anteriores para la evolución)
# y guarda todos los resultados en "$JSON_RESUMEN", que es lo que leen los dos informes.
extraer() {
    local tmp="$JSON_RESUMEN.tmp"
    local ficheros evolucion

    log_info "Iniciando extracción"

    if [ ! -s "$JSON_LIMPIO" ]; then
        log_error "Extracción fallida: no existe el fichero limpio $JSON_LIMPIO"
        return 1
    fi

    # 1. Evolución: medias de Valencia y de España* (sin Canarias, Ceuta y Melilla) de cada día guardado
    #    (la fecha sale del nombre del fichero)
    ficheros=("$DATASETS_DIR"/carburantes_*_limpio.json)
    if ! evolucion="$(jq -n --arg p "$PROVINCIA_ID" --arg fuera "$PROVINCIAS_FUERA_REFERENCIA" --argjson dias "$DIAS_RETENCION" "$JQ_FUNCIONES"'
        ($fuera | split(" ")) as $fuera
        | [inputs | ([.estaciones[] | select(.provincia_id | IN($fuera[]) | not)]) as $ref | {
            fecha:       (input_filename | capture("carburantes_(?<a>[0-9]{4})(?<m>[0-9]{2})(?<d>[0-9]{2})_limpio") | "\(.d)/\(.m)/\(.a)"),
            val_g95:     ([.estaciones[] | select(.provincia_id == $p) | .gasolina95 | select(. != null)] | media),
            val_gasoleo: ([.estaciones[] | select(.provincia_id == $p) | .gasoleo    | select(. != null)] | media),
            ref_g95:     ([$ref[] | .gasolina95 | select(. != null)] | media),
            ref_gasoleo: ([$ref[] | .gasoleo    | select(. != null)] | media)
        }] | .[-($dias):]
    ' "${ficheros[@]}")"; then
        log_error "Extracción fallida: no se ha podido calcular la evolución semanal"
        return 1
    fi

    # 2. Métricas del día, comparación con la referencia, filtrados y variaciones
    if ! jq --arg p "$PROVINCIA_ID" \
            --arg fuera "$PROVINCIAS_FUERA_REFERENCIA" \
            --argjson min_marca "$MIN_ESTACIONES_MARCA" \
            --argjson evol "$evolucion" \
            "$JQ_FUNCIONES"'
        def variacion($antes; $ahora):
            if $antes == null or $ahora == null then null
            else { eur: ($ahora - $antes),
                   pct: (if $antes > 0 then ($ahora - $antes) / $antes * 100 else null end) }
            end;

        # Ranking de marcas para un combustible: solo gasolineras con precio de ese combustible
        # y marcas con al menos $min gasolineras; las 10 más baratas, de la más barata a la más cara
        def ranking($campo; $min):
            map(select(.[$campo] != null))
            | group_by(.marca)
            | map(select(length >= $min) | {marca: .[0].marca, estaciones: length, media: (map(.[$campo]) | media)})
            | sort_by(.media)
            | .[0:10];

        ($fuera | split(" ")) as $fuera
        | [.estaciones[] | select(.provincia_id == $p)] as $val
        | [.estaciones[] | select(.provincia_id | IN($fuera[]) | not)] as $ref
        | [$val[] | .gasolina95 | select(. != null)] as $val_g95
        | [$val[] | .gasoleo    | select(. != null)] as $val_gasoleo
        | [$ref[] | .gasolina95 | select(. != null)] as $ref_g95
        | [$ref[] | .gasoleo    | select(. != null)] as $ref_gasoleo
        | ($val_g95 | media) as $med_g95
        | ($val_gasoleo | media) as $med_gasoleo
        | ($ref_g95 | media) as $med_ref_g95
        | ($ref_gasoleo | media) as $med_ref_gasoleo

        # Cada día de la evolución, con su variación respecto al día anterior de la lista
        | ($evol | . as $d | [range(0; $d | length) as $i | $d[$i] + {
              var_val_g95:     (if $i == 0 then null else variacion($d[$i - 1].val_g95; $d[$i].val_g95) end),
              var_ref_g95:     (if $i == 0 then null else variacion($d[$i - 1].ref_g95; $d[$i].ref_g95) end),
              var_val_gasoleo: (if $i == 0 then null else variacion($d[$i - 1].val_gasoleo; $d[$i].val_gasoleo) end),
              var_ref_gasoleo: (if $i == 0 then null else variacion($d[$i - 1].ref_gasoleo; $d[$i].ref_gasoleo) end)
          }]) as $dias

        | {
            fecha_datos: .fecha_datos,
            calidad: .calidad,
            valencia: {
                estaciones:         ($val | length),
                con_precio_g95:     ($val_g95 | length),
                con_precio_gasoleo: ($val_gasoleo | length),
                gasolina95: { min: ($val_g95 | min), media: $med_g95, max: ($val_g95 | max) },
                gasoleo:    { min: ($val_gasoleo | min), media: $med_gasoleo, max: ($val_gasoleo | max) }
            },
            referencia: {
                estaciones:         ($ref | length),
                con_precio_g95:     ($ref_g95 | length),
                con_precio_gasoleo: ($ref_gasoleo | length),
                gasolina95_media:   $med_ref_g95,
                gasoleo_media:      $med_ref_gasoleo
            },
            comparacion: {
                gasolina95: variacion($med_ref_g95; $med_g95),
                gasoleo:    variacion($med_ref_gasoleo; $med_gasoleo)
            },
            evolucion: {
                dias: $dias,
                semana: (if ($dias | length) >= 2 then {
                    desde:       $dias[0].fecha,
                    hasta:       $dias[-1].fecha,
                    val_g95:     variacion($dias[0].val_g95; $dias[-1].val_g95),
                    ref_g95:     variacion($dias[0].ref_g95; $dias[-1].ref_g95),
                    val_gasoleo: variacion($dias[0].val_gasoleo; $dias[-1].val_gasoleo),
                    ref_gasoleo: variacion($dias[0].ref_gasoleo; $dias[-1].ref_gasoleo)
                } else null end)
            },
            mas_baratas: {
                gasolina95: ([$val[] | select(.gasolina95 != null)] | sort_by(.gasolina95) | .[0:10]
                             | map({marca, municipio, direccion, precio: .gasolina95})),
                gasoleo:    ([$val[] | select(.gasoleo != null)] | sort_by(.gasoleo) | .[0:10]
                             | map({marca, municipio, direccion, precio: .gasoleo}))
            },
            marcas: {
                gasolina95: ($val | ranking("gasolina95"; $min_marca)),
                gasoleo:    ($val | ranking("gasoleo"; $min_marca))
            }
          }
    ' "$JSON_LIMPIO" > "$tmp"; then
        log_error "Extracción fallida: jq no ha podido generar el resumen"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$JSON_RESUMEN"
    log_info "Extracción completada: $(jq -r '"\(.valencia.estaciones) gasolineras en Valencia, evolución de \(.evolucion.dias | length) día(s)"' "$JSON_RESUMEN")"
}

# ----- INFORME TXT -----
generar_informe_txt() {
    local tmp="$INFORME_TXT.tmp"

    log_info "Iniciando informe TXT"

    if [ ! -s "$JSON_RESUMEN" ]; then
        log_error "Informe TXT fallido: no existe el resumen $JSON_RESUMEN"
        return 1
    fi

    mkdir -p "$INFORMES_DIR"

    if ! jq -r --arg emision "$FECHA_HUMANA" --argjson min_marca "$MIN_ESTACIONES_MARCA" "$JQ_FUNCIONES"'
        def doble: "=" * 84;
        def simple: "-" * 84;
        def subraya($n): "   " + ("-" * $n);
        def dif($v): if $v == null then "N/D" else "\($v.eur | conSigno(3)) €/l (\($v.pct | conSigno(1)) %)" end;
        def variacion($v): if $v == null then "-" else "\($v.eur | flecha) \($v.eur | conSigno(3)) (\($v.pct | conSigno(1)) %)" end;
        def gasolinera: "   \(.marca | .[0:18] | pad(19))\(.municipio | .[0:24] | pad(26))\(.direccion | .[0:28] | pad(30))\(.precio | fmt(3))";
        def fila_marca($m; $i): if $m == null then "" else "\($i + 1 | pad(4))\($m.marca | .[0:19] | pad(20))\($m.estaciones | miles | pad(6))\($m.media | fmt(3))" end;
        # Tabla de evolución de un combustible: una fila por día y la variación semanal al final
        def tabla_evolucion($titulo; $dias; $semana; $cv; $ce):
            "   \($titulo) (€/l)",
            "   \("" | pad(14))\("VALENCIA" | pad(34))| ESPAÑA*",
            "   \("FECHA" | pad(14))\("PRECIO" | pad(10))\("VARIACIÓN" | pad(24))| \("PRECIO" | pad(10))VARIACIÓN",
            "   \("-" * 79)",
            ($dias[] | "   \(.fecha | pad(14))\(.[$cv] | fmt(3) | pad(10))\(variacion(.["var_" + $cv]) | pad(24))| \(.[$ce] | fmt(3) | pad(10))\(variacion(.["var_" + $ce]))"),
            (if $semana != null then
                "   \("-" * 79)",
                "   \("Variación semanal" | pad(24))\(variacion($semana[$cv]) | pad(24))| \("" | pad(10))\(variacion($semana[$ce]))",
                "   \("(\($semana.desde[0:5]) - \($semana.hasta[0:5]))" | pad(48))|"
             else empty end);
        def fila_calidad($nombre; $campo): "   \($nombre | pad(35))\(.calidad[$campo] | miles)";

        .evolucion as $ev
        | .marcas.gasolina95 as $mg
        | .marcas.gasoleo as $md
        | [
          doble,
          "  PRECIOS DE CARBURANTES EN LA PROVINCIA DE VALENCIA",
          doble,
          "  Informe generado: \($emision)",
          "",
          "1. PRECIOS EN VALENCIA HOY",
          simple,
          "   Gasolineras en la provincia: \(.valencia.estaciones | miles)",
          "",
          "   \("COMBUSTIBLE" | pad(15))\("MÍNIMO" | pad(10))\("MEDIA" | pad(10))MÁXIMO",
          subraya(41),
          "   \("Gasolina 95" | pad(15))\(.valencia.gasolina95.min | fmt(3) | pad(10))\(.valencia.gasolina95.media | fmt(3) | pad(10))\(.valencia.gasolina95.max | fmt(3))",
          "   \("Diésel" | pad(15))\(.valencia.gasoleo.min | fmt(3) | pad(10))\(.valencia.gasoleo.media | fmt(3) | pad(10))\(.valencia.gasoleo.max | fmt(3))",
          "   (precios en €/l)",
          "",
          "2. COMPARACIÓN CON LA MEDIA DE ESPAÑA*",
          simple,
          "   * España: sin Canarias, Ceuta y Melilla, que tienen otros impuestos sobre el",
          "     carburante. Se excluyen de todos los cálculos de España del informe.",
          "",
          "   Gasolineras en España*: \(.referencia.estaciones | miles)",
          "",
          "   \("COMBUSTIBLE" | pad(15))\("VALENCIA" | pad(11))\("ESPAÑA*" | pad(11))DIFERENCIA (VALENCIA - ESPAÑA*)",
          subraya(68),
          "   \("Gasolina 95" | pad(15))\(.valencia.gasolina95.media | fmt(3) | pad(11))\(.referencia.gasolina95_media | fmt(3) | pad(11))\(dif(.comparacion.gasolina95))",
          "   \("Diésel" | pad(15))\(.valencia.gasoleo.media | fmt(3) | pad(11))\(.referencia.gasoleo_media | fmt(3) | pad(11))\(dif(.comparacion.gasoleo))",
          "",
          "3. EVOLUCIÓN DE LA SEMANA",
          simple,
          (if ($ev.dias | length) < 2 then
              "   Solo hay 1 día guardado: las variaciones aparecerán a partir del próximo día.",
              ""
           else empty end),
          tabla_evolucion("Gasolina 95"; $ev.dias; $ev.semana; "val_g95"; "ref_g95"),
          "",
          tabla_evolucion("Diésel"; $ev.dias; $ev.semana; "val_gasoleo"; "ref_gasoleo"),
          "",
          "4. PRECIO MEDIO POR MARCA EN VALENCIA (marcas con \($min_marca) o más gasolineras)",
          simple,
          "   \("Gasolina 95 (de más barata a más cara)" | pad(42))Diésel (de más barata a más cara)",
          "   \(("#" | pad(4)) + ("MARCA" | pad(20)) + ("Nº" | pad(6)) + "€/l" | pad(42))\("#" | pad(4))\("MARCA" | pad(20))\("Nº" | pad(6))€/l",
          "   \("-" * 33 | pad(42))\("-" * 33)",
          (if ($mg | length) == 0 and ($md | length) == 0 then "   Ninguna marca llega al mínimo de gasolineras."
           else (range(0; [($mg | length), ($md | length)] | max) as $i
                 | "   \(fila_marca($mg[$i]; $i) | pad(42))\(fila_marca($md[$i]; $i))") end),
          "",
          "5. DÓNDE REPOSTAR MÁS BARATO EN VALENCIA",
          simple,
          "   Las 10 gasolineras más baratas de cada combustible.",
          "",
          "   Gasolina 95",
          "   \("MARCA" | pad(19))\("MUNICIPIO" | pad(26))\("DIRECCIÓN" | pad(30))€/l",
          subraya(78),
          (.mas_baratas.gasolina95[] | gasolinera),
          "",
          "   Diésel",
          "   \("MARCA" | pad(19))\("MUNICIPIO" | pad(26))\("DIRECCIÓN" | pad(30))€/l",
          subraya(78),
          (.mas_baratas.gasoleo[] | gasolinera),
          "",
          "6. NOTA SOBRE LOS DATOS (dataset completo, incluidas Canarias, Ceuta y Melilla)",
          simple,
          "   \("CONCEPTO" | pad(35))TOTAL",
          subraya(41),
          fila_calidad("Gasolineras descargadas"; "descargadas"),
          fila_calidad("Duplicadas eliminadas"; "duplicadas"),
          fila_calidad("Precios anómalos descartados"; "precios_fuera_de_rango"),
          fila_calidad("Gasolineras válidas"; "validas"),
          doble
        ] | .[]
    ' "$JSON_RESUMEN" > "$tmp"; then
        log_error "Informe TXT fallido: jq no ha podido generar $INFORME_TXT"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$INFORME_TXT"
    log_info "Informe TXT completado: $INFORME_TXT"
}

# ----- INFORME HTML -----
generar_informe_html() {
    local tmp="$INFORME_HTML.tmp"
    local cabecera

    log_info "Iniciando informe HTML"

    if [ ! -s "$JSON_RESUMEN" ]; then
        log_error "Informe HTML fallido: no existe el resumen $JSON_RESUMEN"
        return 1
    fi

    mkdir -p "$INFORMES_DIR"

    # Parte fija del HTML: estilos (todo dentro del fichero, no necesita internet)
    cabecera="$(cat <<'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Precios de carburantes - Valencia</title>
<style>
:root { --navy:#1a365d; --navy-light:#2c5282; --bg:#f7fafc; --card:#fff; --text:#2d3748;
        --muted:#718096; --border:#e2e8f0; --head:#edf2f7; --gris:#a0aec0; --green:#2f855a; --red:#c53030;
        --shadow:0 4px 6px -1px rgba(0,0,0,.1),0 2px 4px -1px rgba(0,0,0,.06); }
* { box-sizing:border-box; margin:0; padding:0; }
body { font-family:'Segoe UI',system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--text); line-height:1.6; }
.navbar { background:linear-gradient(135deg,var(--navy) 0%,var(--navy-light) 100%); color:#fff; padding:44px 24px; box-shadow:var(--shadow); }
.navbar-content { max-width:1100px; margin:0 auto; display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:12px; }
.navbar h1 { font-size:34px; line-height:1.2; }
.navbar .fechas { font-size:15px; opacity:.92; text-align:right; }
.container { max-width:1100px; margin:0 auto; padding:24px 16px; }
.kpis { display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-bottom:8px; }
.kpi { background:var(--card); border-radius:12px; box-shadow:var(--shadow); padding:18px 22px; border-top:4px solid var(--navy-light); }
.kpi .etiqueta { font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.5px; }
.kpi .valor { font-size:30px; font-weight:700; color:var(--navy); line-height:1.3; }
.kpi .valor small { font-size:16px; font-weight:600; color:var(--muted); }
.contexto { color:var(--muted); font-size:14px; margin:0 4px 20px; }
.asterisco { font-size:12.5px; }
.card { background:var(--card); border-radius:12px; box-shadow:var(--shadow); padding:24px; border:1px solid var(--border); margin-bottom:20px; overflow-x:auto; }
.card h2 { font-size:17px; color:var(--navy); margin-bottom:14px; padding-bottom:8px; border-bottom:2px solid var(--border); }
.card h3 { font-size:14px; color:var(--navy-light); margin:16px 0 8px; }
.card p { margin:8px 0; }
.nota { color:var(--muted); font-size:13px; }
.dos-columnas { display:grid; grid-template-columns:1fr 1fr; gap:24px; }
.combustible { display:grid; grid-template-columns:7fr 5fr; gap:28px; align-items:center; margin-bottom:20px; }
.combustible + .combustible { padding-top:20px; border-top:1px solid var(--border); }
table { width:100%; border-collapse:collapse; font-size:14px; }
th { background:var(--head); color:var(--navy); text-align:left; padding:9px 12px; white-space:nowrap; }
td { padding:9px 12px; border-bottom:1px solid var(--border); }
th.num, td.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
th.grupo { text-align:center; }
th.sep, td.sep { border-left:2px solid var(--border); }
tr.hoy td { font-weight:700; }
tfoot td { border-top:2px solid var(--navy-light); border-bottom:none; font-weight:600; }
.sube { color:var(--red); font-weight:700; }
.baja { color:var(--green); font-weight:700; }
.igual { color:var(--muted); font-weight:700; }
.pct { color:var(--muted); font-size:12.5px; font-weight:400; }
table.evolucion th.grupo { text-align:center; color:var(--navy); }
table.evolucion th.sep, table.evolucion td.sep { border-left:3px solid var(--navy-light); }
.grafica { margin:4px 0 16px; }
.grafica figcaption { font-size:14px; font-weight:600; color:var(--navy-light); }
.grafica svg { width:100%; height:auto; display:block; }
.grafica .rejilla { stroke:var(--border); stroke-width:1; }
.grafica .eje { font-size:12px; fill:var(--muted); }
.grafica polyline { fill:none; stroke-width:2.5; stroke-linejoin:round; }
.grafica polyline.val { stroke:var(--navy-light); }
.grafica polyline.ref { stroke:var(--gris); stroke-dasharray:6 4; }
.grafica circle.val { fill:var(--navy-light); }
.grafica circle.ref { fill:var(--gris); }
.leyenda { font-size:13px; color:var(--muted); }
.leyenda span { margin-right:16px; }
.leyenda span::before { content:""; display:inline-block; width:20px; height:3px; margin:0 6px 3px 0; vertical-align:middle; }
.leyenda .l-val::before { background:var(--navy-light); }
.leyenda .l-ref::before { background:repeating-linear-gradient(90deg,var(--gris) 0 6px,transparent 6px 10px); }
@media (max-width:760px) { .kpis, .dos-columnas, .combustible { grid-template-columns:1fr; } .navbar-content { flex-direction:column; text-align:center; } .navbar .fechas { text-align:center; } }
</style>
</head>
<body>
EOF
)"

    if ! jq -r --arg emision "$FECHA_HUMANA" --arg cabecera "$cabecera" --argjson min_marca "$MIN_ESTACIONES_MARCA" "$JQ_FUNCIONES"'
        def clase($v): if $v == null then "igual" elif $v >= 0.0005 then "sube" elif $v <= -0.0005 then "baja" else "igual" end;
        def dif($v): if $v == null then "N/D"
                     else "<span class=\"\(clase($v.eur))\">\($v.eur | flecha) \($v.eur | conSigno(3)) €/l</span> <span class=\"pct\">(\($v.pct | conSigno(1)) %)</span>" end;
        def variacion($v): if $v == null then "<span class=\"igual\">-</span>"
                           else "<span class=\"\(clase($v.eur))\">\($v.eur | flecha) \($v.eur | conSigno(3))</span> <span class=\"pct\">(\($v.pct | conSigno(1)) %)</span>" end;
        def kpi($nombre; $media):
            "<div class=\"kpi\"><div class=\"etiqueta\">\($nombre) · media en Valencia</div><div class=\"valor\">\($media | fmt(3)) <small>€/l</small></div></div>";
        def num: "<td class=\"num\">\(.)</td>";
        def tabla($cabeza; $filas): "<table><thead><tr>" + ($cabeza | join("")) + "</tr></thead><tbody>" + ($filas | join("")) + "</tbody></table>";
        def gasolineras: map("<tr><td><strong>\(.marca | esc)</strong></td><td>\(.municipio | esc)</td><td>\(.direccion | esc)</td>\(.precio | fmt(3) | num)</tr>");
        def ranking($titulo; $lista):
            "<div><h3>\($titulo)</h3>"
            + (if ($lista | length) == 0 then "<p class=\"nota\">Ninguna marca llega al mínimo de gasolineras.</p>"
               else tabla(["<th class=\"num\">#</th>", "<th>Marca</th>", "<th class=\"num\">Gasolineras</th>", "<th class=\"num\">Media €/l</th>"];
                          [$lista | to_entries[] | "<tr><td class=\"num\">\(.key + 1)</td><td><strong>\(.value.marca | esc)</strong></td>\(.value.estaciones | miles | num)\(.value.media | fmt(3) | num)</tr>"])
               end)
            + "</div>";
        # Gráfica de líneas en SVG (dibujada aquí mismo, sin librerías): Valencia continua, España* discontinua
        def r1: . * 10 | round / 10;
        def grafica($titulo; $dias; $cv; $ce):
            ($dias | length) as $n
            | [$dias[] | .[$cv], .[$ce] | select(. != null)] as $valores
            | ($valores | min) as $lo
            | ($valores | max) as $hi
            | ([$hi - $lo, 0.004] | max) as $rango
            | ($lo - $rango * 0.2) as $y0
            | ($hi + $rango * 0.2) as $y1
            | def X($i): 64 + (if $n == 1 then 0.5 else $i / ($n - 1) end) * 432;
              def Y($v): 16 + (1 - ($v - $y0) / ($y1 - $y0)) * 216;
              def linea($campo; $clase):
                  [range(0; $n) as $i | $dias[$i][$campo] as $v | select($v != null) | [X($i), Y($v)]] as $puntos
                  | "<polyline class=\"\($clase)\" points=\"\($puntos | map("\(.[0] | r1),\(.[1] | r1)") | join(" "))\"/>"
                    + ($puntos | map("<circle class=\"\($clase)\" cx=\"\(.[0] | r1)\" cy=\"\(.[1] | r1)\" r=\"3.5\"/>") | join(""));
            "<figure class=\"grafica\">"
            + "<svg viewBox=\"0 0 520 262\" role=\"img\" aria-label=\"Evolución del precio medio de \($titulo) en Valencia y en España\">"
            + ([$lo, ($lo + $hi) / 2, $hi] | map("<line class=\"rejilla\" x1=\"64\" x2=\"496\" y1=\"\(Y(.) | r1)\" y2=\"\(Y(.) | r1)\"/><text class=\"eje\" x=\"56\" y=\"\(Y(.) + 4 | r1)\" text-anchor=\"end\">\(fmt(3))</text>") | join(""))
            + ([range(0; $n) as $i | "<text class=\"eje\" x=\"\(X($i) | r1)\" y=\"254\" text-anchor=\"middle\">\($dias[$i].fecha[0:5])</text>"] | join(""))
            + linea($ce; "ref") + linea($cv; "val")
            + "</svg><div class=\"leyenda\"><span class=\"l-val\">Valencia</span><span class=\"l-ref\">España*</span></div></figure>";

        # Tabla de evolución de un combustible: una fila por día (hoy en negrita) y la variación semanal al pie
        def tabla_evolucion($dias; $semana; $cv; $ce):
            ($dias | length) as $n
            | "<table class=\"evolucion\"><thead>"
              + "<tr><th rowspan=\"2\">Fecha</th><th colspan=\"2\" class=\"grupo\">Valencia</th><th colspan=\"2\" class=\"grupo sep\">España*</th></tr>"
              + "<tr><th class=\"num\">Precio</th><th class=\"num\">Variación</th><th class=\"num sep\">Precio</th><th class=\"num\">Variación</th></tr></thead><tbody>"
            + ([$dias | to_entries[] | (.key == $n - 1) as $hoy | .value
                | "<tr\(if $hoy then " class=\"hoy\"" else "" end)><td>\(.fecha[0:5])\(if $hoy then " (hoy)" else "" end)</td>"
                  + "<td class=\"num\">\(.[$cv] | fmt(3))</td><td class=\"num\">\(variacion(.["var_" + $cv]))</td>"
                  + "<td class=\"num sep\">\(.[$ce] | fmt(3))</td><td class=\"num\">\(variacion(.["var_" + $ce]))</td></tr>"] | join(""))
            + "</tbody>"
            + (if $semana != null then
                  "<tfoot><tr><td>Variación semanal<br><span class=\"pct\">(\($semana.desde[0:5]) - \($semana.hasta[0:5]))</span></td><td></td><td class=\"num\">\(variacion($semana[$cv]))</td><td class=\"sep\"></td><td class=\"num\">\(variacion($semana[$ce]))</td></tr></tfoot>"
               else "" end)
            + "</table>";
        def bloque_combustible($titulo; $dias; $semana; $cv; $ce):
            "<div class=\"combustible\"><div><h3>\($titulo) (€/l)</h3>" + tabla_evolucion($dias; $semana; $cv; $ce) + "</div>"
            + (if ($dias | length) >= 2 then grafica($titulo; $dias; $cv; $ce) else "<div></div>" end)
            + "</div>";
        def fila_calidad($nombre; $campo): "<tr><td>\($nombre)</td>\(.calidad[$campo] | miles | num)</tr>";

        .evolucion as $ev
        | [
            $cabecera,
            "<nav class=\"navbar\"><div class=\"navbar-content\">",
            "<h1>Precios de carburantes en la provincia de Valencia</h1>",
            "<div class=\"fechas\">Informe generado: \($emision)</div>",
            "</div></nav>",
            "<div class=\"container\">",

            "<div class=\"kpis\">",
            kpi("Gasolina 95"; .valencia.gasolina95.media),
            kpi("Diésel"; .valencia.gasoleo.media),
            "</div>",
            "<p class=\"contexto\">\(.valencia.estaciones | miles) gasolineras en la provincia de Valencia · \(.referencia.estaciones | miles) en España*<br>"
            + "<span class=\"asterisco\">* España: sin Canarias, Ceuta y Melilla, que tienen otros impuestos sobre el carburante. Se excluyen de todos los cálculos de España del informe.</span></p>",

            "<div class=\"card\"><h2>1. Precios en Valencia hoy</h2>",
            tabla(["<th>Combustible</th>", "<th class=\"num\">Mínimo (€/l)</th>", "<th class=\"num\">Media (€/l)</th>", "<th class=\"num\">Máximo (€/l)</th>"];
                  [ "<tr><td><strong>Gasolina 95</strong></td>\(.valencia.gasolina95.min | fmt(3) | num)\(.valencia.gasolina95.media | fmt(3) | num)\(.valencia.gasolina95.max | fmt(3) | num)</tr>",
                    "<tr><td><strong>Diésel</strong></td>\(.valencia.gasoleo.min | fmt(3) | num)\(.valencia.gasoleo.media | fmt(3) | num)\(.valencia.gasoleo.max | fmt(3) | num)</tr>" ]),
            "</div>",

            "<div class=\"card\"><h2>2. Comparación con la media de España*</h2>",
            tabla(["<th>Combustible</th>", "<th class=\"num\">Media Valencia (€/l)</th>", "<th class=\"num\">Media España* (€/l)</th>", "<th class=\"num\">Diferencia (Valencia − España*)</th>"];
                  [ "<tr><td><strong>Gasolina 95</strong></td>\(.valencia.gasolina95.media | fmt(3) | num)\(.referencia.gasolina95_media | fmt(3) | num)<td class=\"num\">\(dif(.comparacion.gasolina95))</td></tr>",
                    "<tr><td><strong>Diésel</strong></td>\(.valencia.gasoleo.media | fmt(3) | num)\(.referencia.gasoleo_media | fmt(3) | num)<td class=\"num\">\(dif(.comparacion.gasoleo))</td></tr>" ]),
            "</div>",

            "<div class=\"card\"><h2>3. Evolución de la semana</h2>",
            (if ($ev.dias | length) < 2 then
                "<p class=\"nota\">Solo hay 1 día guardado: las variaciones y las gráficas aparecerán a partir del próximo día.</p>"
             else empty end),
            bloque_combustible("Gasolina 95"; $ev.dias; $ev.semana; "val_g95"; "ref_g95"),
            bloque_combustible("Diésel"; $ev.dias; $ev.semana; "val_gasoleo"; "ref_gasoleo"),
            "</div>",

            "<div class=\"card\"><h2>4. Precio medio por marca en Valencia</h2>",
            "<p class=\"nota\">Marcas con \($min_marca) o más gasolineras en la provincia, de la más barata a la más cara.</p>",
            "<div class=\"dos-columnas\">",
            ranking("Gasolina 95"; .marcas.gasolina95),
            ranking("Diésel"; .marcas.gasoleo),
            "</div>",
            "</div>",

            "<div class=\"card\"><h2>5. Dónde repostar más barato en Valencia</h2>",
            "<p class=\"nota\">Las 10 gasolineras más baratas de cada combustible.</p>",
            "<h3>Gasolina 95</h3>",
            tabla(["<th>Marca</th>", "<th>Municipio</th>", "<th>Dirección</th>", "<th class=\"num\">€/l</th>"]; (.mas_baratas.gasolina95 | gasolineras)),
            "<h3>Diésel</h3>",
            tabla(["<th>Marca</th>", "<th>Municipio</th>", "<th>Dirección</th>", "<th class=\"num\">€/l</th>"]; (.mas_baratas.gasoleo | gasolineras)),
            "</div>",

            "<div class=\"card\"><h2>6. Nota sobre los datos</h2>",
            "<p class=\"nota\">Dataset completo descargado: todas las gasolineras, incluidas Canarias, Ceuta y Melilla.</p>",
            tabla(["<th>Concepto</th>", "<th class=\"num\">Total</th>"];
                  [ fila_calidad("Gasolineras descargadas"; "descargadas"),
                    fila_calidad("Duplicadas eliminadas"; "duplicadas"),
                    fila_calidad("Precios anómalos descartados"; "precios_fuera_de_rango"),
                    fila_calidad("Gasolineras válidas"; "validas") ]),
            "</div>",

            "</div>",
            "</body>",
            "</html>"
          ] | .[]
    ' "$JSON_RESUMEN" > "$tmp"; then
        log_error "Informe HTML fallido: jq no ha podido generar $INFORME_HTML"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$INFORME_HTML"
    log_info "Informe HTML completado: $INFORME_HTML"
}

# ===== FIN PARTE ÁLVARO =====


# ===== EJECUCIÓN =====
log_info "INICIO ejecución"

descargar
validar "$JSON_RAW.tmp"
limpiar
borrar_antiguos     # antes de extraer: la evolución usa solo los días que se conservan
extraer
generar_informe_txt
generar_informe_html

log_info "FIN correcto"