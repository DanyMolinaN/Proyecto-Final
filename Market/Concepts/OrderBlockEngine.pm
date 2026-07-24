package Market::Concepts::OrderBlockEngine;

# =============================================================================
# Market::Concepts::OrderBlockEngine  — v2.0  (SMC / LuxAlgo-compatible)
# =============================================================================
# Calcula las zonas institucionales de Supply (OB bajista) y Demand (OB alcista)
# siguiendo la lógica exacta del Pine Script de LuxAlgo:
#
#   1. Un Order Block (OB) SOLO nace cuando el SMCStructureEngine detecta un
#      BOS o CHoCH.
#
#   2. La zona del OB es la vela extrema dentro del tramo impulso:
#      • BOS/CHoCH BULLISH → se originó desde un Swing LOW.
#        Se busca la vela con el MENOR parsed_high (high ajustado por volatilidad)
#        en el rango [swing_index .. break_index].
#        → OB BULLISH (zona de demanda)
#
#      • BOS/CHoCH BEARISH → se originó desde un Swing HIGH.
#        Se busca la vela con el MAYOR parsed_low (low ajustado) en el rango.
#        → OB BEARISH (zona de oferta)
#
#   3. La vela extrema encontrada define:
#        ob.high = high de esa vela
#        ob.low  = low  de esa vela
#
#   4. Mitigación (el OB queda inactivo):
#      • OB BULLISH: price.low  <=  ob.low   → el precio reingresó y lo cubrió
#      • OB BEARISH: price.high >=  ob.high  → ídem en dirección contraria
#      El OB permanece dibujable hasta que el CLOSE lo invalide (cruza fuera).
#
#   5. Invalidación (el OB es excluido de active[] y del render, pero conservado en blocks[] hasta la poda por MAX_BLOCKS):
#      • OB BULLISH: close < ob.low (o swing origin)
#      • OB BEARISH: close > ob.high (o swing origin)
#
# ── Fuente de eventos BOS/CHoCH ──────────────────────────────────────────────
# Este engine consume la salida de Market::Concepts::SMCStructureEngine
# (argumento $smc_result en calculate).  Si se pasa un objeto de la clase
# El flujo principal recibe directamente los eventos del SMCStructureEngine.
#
# ── Salida de calculate() ────────────────────────────────────────────────────
#   {
#     blocks   => \@all_blocks,
#     active   => \@detected_only,
#     metadata => { block_count, active_count, swing_count, internal_count, ... },
#   }
#
# ── Formato de un block ───────────────────────────────────────────────────────
#   {
#     type               => 'bullish'|'bearish',
#     scope              => 'swing'|'internal',
#     kind               => 'BOS'|'CHoCH',
#     high               => $price,
#     low                => $price,
#     price              => $price,       # midpoint (compatible con overlay)
#     value              => $price,       # alias de price
#     index              => $ob_idx,      # índice de la vela OB
#     created_index      => $ob_idx,
#     origin_index       => $ob_idx,
#     break_index        => $break_idx,   # vela donde se confirmó el BOS/CHoCH
#     swing_index        => $swing_idx,   # vela del pivote que fue roto
#     confirmation_index => $break_idx,
#     state              => 'Detected'|'Mitigated'|'Invalidated',
#     mitigated_index    => $i_or_undef,
#     invalidated_index  => $i_or_undef,
#     mitigation_pct     => 0..100,
#   }
# =============================================================================

use strict;
use warnings;

# Número máximo de OBs en el caché (previene fugas de memoria).
# El overlay sólo dibuja los N más recientes de cualquier forma.
use constant MAX_BLOCKS => 200;

# =============================================================================
# new(%args)
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        blocks   => [],
        active   => [],
        metadata => {},

        # Sensibilidad de la búsqueda de la vela institucional.
        # Si es 1 usa el high/low real; si es 0 usa el "parsed" (ajustado por
        # volatilidad, igual que LuxAlgo con parsedHighs/parsedLows).
        use_parsed => $args{use_parsed} // 1,

        # Umbral de volatilidad para parsear highs/lows (múltiplo de ATR).
        # LuxAlgo usa 2 × ATR como frontera de "barra de alta volatilidad".
        vol_atr_mult => $args{vol_atr_mult} // 2.0,

        # Umbral de desplazamiento en múltiplos de ATR (0.5 a 1.0 recomendado).
        displacement_atr_mult => $args{displacement_atr_mult} // 1.0,
        
        # Filtro opcional de volumen relativo (percentil 0..100). undef = desactivado.
        min_rel_volume_pctl   => $args{min_rel_volume_pctl},

        %args,
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# reset()
# =============================================================================
sub reset {
    my ($self) = @_;
    $self->{blocks}   = [];
    $self->{active}   = [];
    $self->{metadata} = {};
    return $self;
}

# =============================================================================
# calculate($market_data, $smc_engine_or_result, %args)  →  \%result
#
# $smc_engine_or_result puede ser:
#   • El resultado (hashref) directo de SMCStructureEngine->calculate()
#   • Un objeto SMCStructureEngine  (se llama a sus métodos)
# =============================================================================
sub calculate {
    my ($self, $market_data, $smc_src, %args) = @_;
    return {} unless $market_data;

    $self->reset();
    $self->{metadata}{displacement_filtered} = 0;
    $self->{metadata}{volume_filtered} = 0;

    my $total = $market_data->size();
    return {} unless $total > 0;

    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    # ── Precarga velas ────────────────────────────────────────────────────
    my @candles;
    $#candles = $last_index;
    for my $i (0 .. $last_index) {
        $candles[$i] = $market_data->get_candle($i);
    }

    # ── ATR global (para detección de velas de alta volatilidad) ─────────
    my $atr_series = _compute_atr_series(\@candles, $last_index, 200);

    # ── Construye parsed_highs / parsed_lows ──────────────────────────────
    # En LuxAlgo: si (high - low) >= 2 × ATR  →  barra de alta volatilidad
    #   parsedHigh = low   (invertido)
    #   parsedLow  = high  (invertido)
    # Esto hace que la búsqueda de la "vela institucional" ignore cuerpos
    # anómalos y se ancle a la parte más informativa de la vela.
    my @ph;  # parsed highs
    my @pl;  # parsed lows
    $#ph = $last_index;
    $#pl = $last_index;
    my $mult = $self->{vol_atr_mult};
    for my $i (0 .. $last_index) {
        my $c = $candles[$i];
        unless ($c) { $ph[$i] = undef; $pl[$i] = undef; next; }
        my $atr = $atr_series->[$i] // 1;
        my $high_vol = ($c->{high} - $c->{low}) >= ($mult * $atr);
        $ph[$i] = $high_vol ? $c->{low}  : $c->{high};
        $pl[$i] = $high_vol ? $c->{high} : $c->{low};
    }

    # ── Extrae eventos BOS/CHoCH del proveedor de estructura ─────────────
    my $events = $self->_extract_events($smc_src, $visible_limit);

    # ── Por cada evento, construye el Order Block correspondiente ─────────
    my @blocks;
    for my $evt (@$events) {
        my $break_idx = $evt->{index}       // next;
        my $swing_idx = $evt->{swing_index} // next;
        my $dir       = $evt->{direction}   // next;
        my $scope     = $evt->{scope}       // 'swing';
        my $kind      = $evt->{kind}        // 'BOS';

        # El pivote debe ser anterior al cruce
        next if $swing_idx >= $break_idx;
        next if $break_idx > $last_index;

        # ── Localiza la vela institucional en [swing_idx .. break_idx-1] ─
        my $ob_idx = $self->_find_ob_candle(
            \@candles, \@ph, \@pl,
            $swing_idx, $break_idx - 1, $dir,
        );
        next unless defined $ob_idx;

        my $ob_candle = $candles[$ob_idx];
        next unless $ob_candle;

        my $ob_high = $ob_candle->{high};
        my $ob_low  = $ob_candle->{low};
        next unless defined $ob_high && defined $ob_low;
        next if $ob_high <= $ob_low;

        # ── Gate 1: Filtro de Displacement ───────────────────────────────────
        my $break_price = $candles[$break_idx]->{close};
        my $displacement = $dir eq 'bullish' ? ($break_price - $ob_low) : ($ob_high - $break_price);
        my $atr_break = $atr_series->[$break_idx] // $atr_series->[$last_index] // 1;
        
        if ($displacement < $self->{displacement_atr_mult} * $atr_break) {
            $self->{metadata}{displacement_filtered}++;
            next;
        }

        # ── Gate 2: Filtro de Volumen Relativo ───────────────────────────────
        if (defined $self->{min_rel_volume_pctl}) {
            my $vol_pctl = _compute_volume_percentile(\@candles, $ob_idx, 200);
            if ($vol_pctl < $self->{min_rel_volume_pctl}) {
                $self->{metadata}{volume_filtered}++;
                next;
            }
        }

        my $mid = ($ob_high + $ob_low) / 2;

        push @blocks, {
            type               => $dir,         # 'bullish' | 'bearish'
            scope              => $scope,
            kind               => $kind,
            high               => $ob_high,
            low                => $ob_low,
            price              => $mid,
            value              => $mid,
            index              => $ob_idx,
            created_index      => $ob_idx,
            origin_index       => $ob_idx,
            break_index        => $break_idx,
            swing_index        => $swing_idx,
            confirmation_index => $break_idx,
            state              => 'Detected',
            mitigated_index    => undef,
            invalidated_index  => undef,
            mitigation_pct     => 0,
        };
    }

    # ── Elimina duplicados: si dos eventos apuntan a la misma vela OB ─────
    @blocks = _deduplicate(\@blocks);

    # ── Filtro anti-solapamiento ──────────────────────────────────────────
    @blocks = $self->_filter_overlaps(\@blocks);

    # ── Aplica mitigación e invalidación ──────────────────────────────────
    $self->_apply_lifecycle(\@blocks, \@candles, $last_index);

    # ── Poda anti-fuga de memoria ─────────────────────────────────────────
    # Conserva solo los MAX_BLOCKS más recientes (por break_index)
    if (@blocks > MAX_BLOCKS) {
        @blocks = sort { $b->{break_index} <=> $a->{break_index} } @blocks;
        @blocks = @blocks[0 .. MAX_BLOCKS - 1];
        @blocks = sort { $a->{break_index} <=> $b->{break_index} } @blocks;
    }

    # ── Resultado ─────────────────────────────────────────────────────────
    my @active = grep { ($_->{state} // '') =~ /^(?:Detected|PartiallyMitigated)$/ } @blocks;

    $self->{blocks}   = \@blocks;
    $self->{active}   = \@active;
    $self->{metadata} = {
        timeframe             => $args{timeframe}
                              || ($market_data->can('active_tf') ? $market_data->active_tf() : 'unknown'),
        block_count           => scalar(@blocks),
        active_count          => scalar(@active),
        visible_limit         => $visible_limit,
        atr                   => $atr_series->[$last_index] // 1,
        swing_count           => scalar(grep { ($_->{scope}//'') eq 'swing'    } @blocks),
        internal_count        => scalar(grep { ($_->{scope}//'') eq 'internal' } @blocks),
        bos_count             => scalar(grep { ($_->{kind}  //'') eq 'BOS'     } @blocks),
        choch_count           => scalar(grep { ($_->{kind}  //'') eq 'CHoCH'   } @blocks),
        displacement_filtered => $self->{metadata}{displacement_filtered} // 0,
        volume_filtered       => $self->{metadata}{volume_filtered} // 0,
        partially_mitigated_count => scalar(grep { ($_->{state}//'') eq 'PartiallyMitigated' } @blocks),
        mitigated_count       => scalar(grep { ($_->{state}//'') eq 'Mitigated' } @blocks),
        invalidated_count     => scalar(grep { ($_->{state}//'') eq 'Invalidated' } @blocks),
    };

    return {
        blocks   => $self->{blocks},
        active   => $self->{active},
        metadata => $self->{metadata},
    };
}

# =============================================================================
# Accesores públicos
# =============================================================================
sub blocks   { $_[0]->{blocks}   || [] }
sub active   { $_[0]->{active}   || [] }
sub metadata { $_[0]->{metadata} || {} }

# =============================================================================
# PRIVATE — _extract_events($src, $visible_limit)  →  \@events
#
# Adapta el proveedor de estructura al formato interno.
# Acepta:
#   • Hashref del SMCStructureEngine->calculate()
#   • Objeto SMCStructureEngine  (con accessor events())
#   • Legacy StructureEngine     (con methods structure() / breaks)
# =============================================================================

# Modulos SRP (misma API).
require 'Market/Concepts/OrderBlockEngine/Detect.pm';
require 'Market/Concepts/OrderBlockEngine/Lifecycle.pm';

1;
