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
#   5. Invalidación (el OB es eliminado del caché):
#      • OB BULLISH: close < ob.low
#      • OB BEARISH: close > ob.high
#
# ── Fuente de eventos BOS/CHoCH ──────────────────────────────────────────────
# Este engine consume la salida de Market::Concepts::SMCStructureEngine
# (argumento $smc_result en calculate).  Si se pasa un objeto de la clase
# heredada Market::Structure::StructureEngine se adapta automáticamente.
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
#   • El legacy Market::Structure::StructureEngine (adaptador interno)
# =============================================================================
sub calculate {
    my ($self, $market_data, $smc_src, %args) = @_;
    return {} unless $market_data;

    $self->reset();

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
    my $atr = _compute_atr(\@candles, $last_index, 200);

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
    my @active = grep { ($_->{state} // '') eq 'Detected' } @blocks;

    $self->{blocks}   = \@blocks;
    $self->{active}   = \@active;
    $self->{metadata} = {
        timeframe     => $args{timeframe}
                      || ($market_data->can('active_tf') ? $market_data->active_tf() : 'unknown'),
        block_count   => scalar(@blocks),
        active_count  => scalar(@active),
        visible_limit => $visible_limit,
        atr           => $atr,
        swing_count   => scalar(grep { ($_->{scope}//'') eq 'swing'    } @blocks),
        internal_count=> scalar(grep { ($_->{scope}//'') eq 'internal' } @blocks),
        bos_count     => scalar(grep { ($_->{kind}  //'') eq 'BOS'     } @blocks),
        choch_count   => scalar(grep { ($_->{kind}  //'') eq 'CHoCH'   } @blocks),
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
sub _extract_events {
    my ($self, $src, $vis) = @_;
    return [] unless $src;

    my @raw;

    if (ref $src eq 'HASH') {
        # ── Resultado directo de SMCStructureEngine ───────────────────────
        if (exists $src->{events}) {
            @raw = @{ $src->{events} };
        }
        # ── Legacy StructureEngine resultado ─────────────────────────────
        elsif (exists $src->{breaks}) {
            @raw = map {
                {
                    kind        => $_->{kind}      // 'BOS',
                    direction   => $_->{direction} // 'bullish',
                    scope       => $_->{scope}     // 'swing',
                    index       => $_->{index}     // $_->{confirmation_index},
                    swing_index => $_->{swing_index} // $_->{break_index},
                }
            } @{ $src->{breaks} || [] };
        }
    }
    elsif (ref $src && $src->can('events')) {
        # ── Objeto SMCStructureEngine ─────────────────────────────────────
        @raw = @{ $src->events() };
    }
    elsif (ref $src && $src->can('structure')) {
        # ── Objeto Legacy StructureEngine ─────────────────────────────────
        my $st = $src->structure() || {};
        for my $br (@{ $st->{breaks} || [] }) {
            push @raw, {
                kind        => $br->{kind}        // 'BOS',
                direction   => $br->{direction}   // 'bullish',
                scope       => $br->{scope}       // 'swing',
                index       => $br->{index}       // $br->{confirmation_index},
                swing_index => $br->{swing_index} // $br->{break_index},
            };
        }
    }

    # Filtra por visible_limit y sólo BOS/CHoCH (no EQH/EQL)
    my @filtered;
    for my $e (@raw) {
        next unless ($e->{kind} // '') =~ /^(?:BOS|CHoCH)$/;
        next if defined $vis && ($e->{index} // 0) > $vis;
        push @filtered, $e;
    }

    return \@filtered;
}

# =============================================================================
# PRIVATE — _find_ob_candle(\@candles, \@ph, \@pl, $from, $to, $dir) → $idx
#
# LuxAlgo busca dentro del rango de velas [from..to] la "vela institucional"
# que será el Order Block:
#
#   BOS/CHoCH BULLISH  (ruptura alcista desde un Swing LOW):
#     → Se busca la vela con el parsed_low MÍNIMO dentro del rango.
#       Es la vela que penetró más profundo antes del impulso.
#
#   BOS/CHoCH BEARISH  (ruptura bajista desde un Swing HIGH):
#     → Se busca la vela con el parsed_high MÁXIMO dentro del rango.
#       Es la vela que subió más alto antes del impulso.
#
# El LuxAlgo Pine Script original usa:
#   bearish: a_rray = parsedHighs.slice(p_ivot.barIndex, bar_index)
#            parsedIndex = p_ivot.barIndex + a_rray.indexof(a_rray.max())
#   bullish: a_rray = parsedLows.slice(...)
#            parsedIndex = p_ivot.barIndex + a_rray.indexof(a_rray.min())
# =============================================================================
sub _find_ob_candle {
    my ($self, $candles, $ph, $pl, $from, $to, $dir) = @_;

    return undef if $from > $to;

    my ($best_idx, $best_val);

    if ($dir eq 'bullish') {
        # Busca el mínimo parsed_low en el rango
        for my $i ($from .. $to) {
            my $val = $pl->[$i];
            next unless defined $val;
            if (!defined $best_val || $val < $best_val) {
                $best_val = $val;
                $best_idx = $i;
            }
        }
    }
    else {
        # Busca el máximo parsed_high en el rango
        for my $i ($from .. $to) {
            my $val = $ph->[$i];
            next unless defined $val;
            if (!defined $best_val || $val > $best_val) {
                $best_val = $val;
                $best_idx = $i;
            }
        }
    }

    return $best_idx;
}

# =============================================================================
# PRIVATE — _apply_lifecycle(\@blocks, \@candles, $last_index)
#
# Itera las velas DESPUÉS de la confirmación del OB y aplica:
#
#   OB BULLISH (zona de demanda — el precio debería rebotar desde allí):
#     • Mitigación : alguna vela posterior entra en la zona (low <= ob.high)
#                    y el grado de penetración supera el umbral (50 %)
#     • Invalidación: close < ob.low  (el precio cierra bajo el OB → zona rota)
#
#   OB BEARISH (zona de oferta):
#     • Mitigación : high >= ob.low  y penetración > 50 %
#     • Invalidación: close > ob.high
#
# El porcentaje de mitigación se calcula como la fracción de la zona que ha
# sido "consumida" por el precio:
#   bullish: pct = (ob.high - vela.low)  / (ob.high - ob.low) × 100
#   bearish: pct = (vela.high - ob.low)  / (ob.high - ob.low) × 100
# =============================================================================
sub _apply_lifecycle {
    my ($self, $blocks, $candles, $last_index) = @_;

    for my $ob (@$blocks) {
        my $start  = $ob->{confirmation_index};
        next unless defined $start;

        my $ob_high   = $ob->{high};
        my $ob_low    = $ob->{low};
        my $height    = $ob_high - $ob_low;
        next if $height <= 0;

        my $type      = $ob->{type};
        my $state     = 'Detected';
        my $max_pct   = 0;
        my $mit_idx   = undef;
        my $inv_idx   = undef;

        for (my $i = $start; $i <= $last_index; $i++) {
            my $c = $candles->[$i];
            next unless $c;

            if ($type eq 'bullish') {
                # ── Invalidación: cierre bajo el OB ──────────────────────
                if ($c->{close} < $ob_low) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{low} < $ob_high) {
                    my $pct = ($ob_high - $c->{low}) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                    if ($max_pct >= 50 && $state eq 'Detected') {
                        $state   = 'Mitigated';
                        $mit_idx = $i;
                    }
                }
            }
            else { # bearish
                # ── Invalidación: cierre sobre el OB ─────────────────────
                if ($c->{close} > $ob_high) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{high} > $ob_low) {
                    my $pct = ($c->{high} - $ob_low) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                    if ($max_pct >= 50 && $state eq 'Detected') {
                        $state   = 'Mitigated';
                        $mit_idx = $i;
                    }
                }
            }
        }

        $ob->{state}             = $state;
        $ob->{mitigated_index}   = $mit_idx;
        $ob->{invalidated_index} = $inv_idx;
        $ob->{mitigation_pct}    = int($max_pct + 0.5);
    }
}

# =============================================================================
# PRIVATE — _deduplicate(\@blocks)  →  @unique
#
# Si varios eventos BOS/CHoCH consecutivos apuntan a la misma vela OB (mismo
# $ob_idx), conserva solo el más reciente para ese índice.
# =============================================================================
sub _deduplicate {
    my ($blocks) = @_;
    my %seen;
    my @out;
    # Procesa en orden inverso para quedarse con el más reciente
    for my $b (reverse @$blocks) {
        my $key = join(':', $b->{index}, $b->{type});
        next if $seen{$key}++;
        unshift @out, $b;
    }
    return @out;
}

# =============================================================================
# PRIVATE — _compute_atr(\@candles, $last_idx, $period)
# =============================================================================
sub _compute_atr {
    my ($candles, $last_idx, $period) = @_;
    return 1.0 if $last_idx < 1;
    my $start = $last_idx - $period + 1;
    $start = 1 if $start < 1;
    my ($sum, $count) = (0, 0);
    for my $i ($start .. $last_idx) {
        my $c  = $candles->[$i]     or next;
        my $cp = $candles->[$i - 1] or next;
        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl > $hc ? $hl : $hc;
        $tr = $lc if $lc > $tr;
        $sum += $tr; $count++;
    }
    return $count > 0 ? $sum / $count : 1.0;
}

1;

__END__

=pod

=head1 NAME

Market::Concepts::OrderBlockEngine — Motor de Order Blocks SMC v2

=head1 SYNOPSIS

    # Opción A: pasar el resultado del SMCStructureEngine directamente
    my $smc_result = $smc_engine->calculate($market_data, %args);
    my $ob_result  = $ob_engine->calculate($market_data, $smc_result, %args);

    # Opción B: pasar el objeto engine (se llama a ->events())
    my $ob_result  = $ob_engine->calculate($market_data, $smc_engine, %args);

    # Opción C: compatibilidad con el legacy StructureEngine
    my $ob_result  = $ob_engine->calculate($market_data, $structure_engine, %args);

    for my $ob (@{ $ob_result->{blocks} }) {
        printf "OB %s [%s] idx=%d  %.4f..%.4f  state=%s\n",
            $ob->{type}, $ob->{kind}, $ob->{index},
            $ob->{low}, $ob->{high}, $ob->{state};
    }

=head1 DESCRIPTION

Un Order Block (OB) nace ÚNICAMENTE cuando el SMCStructureEngine detecta un
BOS o CHoCH. La vela institucional que define la zona (High/Low) se localiza
buscando el extremo más pronunciado en el rango de velas entre el Swing
pivote y la vela de confirmación:

    BOS/CHoCH alcista → zona de DEMANDA (OB bullish)
        Vela OB = la de menor parsed_low  en [swing_index .. break_index-1]

    BOS/CHoCH bajista → zona de OFERTA (OB bearish)
        Vela OB = la de mayor parsed_high en [swing_index .. break_index-1]

La mitigación se activa cuando el precio penetra >= 50% de la zona.
La invalidación ocurre cuando el close cierra al otro lado del OB.

=cut
