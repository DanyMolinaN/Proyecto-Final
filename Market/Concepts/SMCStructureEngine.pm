package Market::Concepts::SMCStructureEngine;

# =============================================================================
# Market::Concepts::SMCStructureEngine  — v2.0
# =============================================================================
# Traducción fiel de la lógica de cálculo del indicador
# "Smart Money Concepts [LuxAlgo]" (Pine Script v5) al paradigma iterativo de
# Perl.  Ejecuta DOS máquinas de estado completamente independientes en el
# mismo pase O(N):
#
#   Swing Structure   → size = swing_length (default 50)
#                       Pine: getCurrentStructure(swingsLengthInput, false, false)
#                             displayStructure(false)
#
#   Internal Structure → size = internal_length (default 5)
#                        Pine: getCurrentStructure(5, false, true)
#                              displayStructure(true)
#
#   EQH / EQL          → size = eq_length (default 3)
#                        Pine: getCurrentStructure(equalHighsLowsLengthInput, true)
#
# ── Salida de calculate() ────────────────────────────────────────────────────
#   {
#     events     => \@all,         # BOS + CHoCH + EQH + EQL cronológicos
#     by_index   => \%hash,        # $bar_index → \@events  (lista cruda)
#     features   => \%hash,        # $bar_index → { internal_event => 'BOS_BULL', swing_event => 'CHOCH_BEAR', eqh => 1, eql => 1 }
#
#     # ── Pivotes históricos ────────────────────────────────────────────────
#     swing_highs    => \@pivots,  # { index, level, last_level, label, crossed }
#     swing_lows     => \@pivots,
#     internal_highs => \@pivots,
#     internal_lows  => \@pivots,
#
#     # ── Liquidez (Equal High/Low) ─────────────────────────────────────────
#     eqh => \@events,
#     eql => \@events,
#
#     # ── Estado de tendencia al final del dataset ──────────────────────────
#     swing_trend    => 'bullish'|'bearish'|'neutral',
#     internal_trend => 'bullish'|'bearish'|'neutral',
#
#     # ── Último pivote activo (para OrderBlockEngine) ───────────────────────
#     last_swing_high    => \%pivot_or_undef,
#     last_swing_low     => \%pivot_or_undef,
#     last_internal_high => \%pivot_or_undef,
#     last_internal_low  => \%pivot_or_undef,
#
#     metadata => { bos_count, choch_count, eqh_count, eql_count, ... },
#   }
#
# ── Formato de evento BOS/CHoCH ──────────────────────────────────────────────
#   {
#     kind        => 'BOS'|'CHoCH',
#     scope       => 'swing'|'internal',
#     direction   => 'bullish'|'bearish',
#     index       => $i,           # vela de confirmación (cruce de close)
#     level       => $price,       # precio del pivote cruzado
#     swing_index => $si,          # vela donde se formó el pivote original
#     swing_high  => 0|1,
#     swing_low   => 0|1,
#   }
# =============================================================================

use strict;
use warnings;

# ---------------------------------------------------------------------------
# Constantes (réplica de las del Pine Script)
# ---------------------------------------------------------------------------
use constant {
    _BULLISH     =>  1,
    _BEARISH     => -1,
    _NEUTRAL     =>  0,
    _BULLISH_LEG =>  1,   # leg confirma un swing LOW  (próxima pierna alcista)
    _BEARISH_LEG =>  0,   # leg confirma un swing HIGH (próxima pierna bajista)
};

# Límite máximo de elementos en los arrays de historial para evitar fugas de
# memoria en ejecuciones largas (miles de velas).
use constant MAX_PIVOT_HISTORY => 500;

# Parámetros por defecto (idénticos a los inputs del Pine Script original)
use constant {
    DEFAULT_SWING_LENGTH    => 50,
    DEFAULT_INTERNAL_LENGTH =>  5,
    DEFAULT_EQ_LENGTH       =>  3,
    DEFAULT_EQ_THRESHOLD    =>  0.1,
};

# =============================================================================
# new(%args)
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        # ── Parámetros configurables ─────────────────────────────────────
        swing_length    => $args{swing_length}    // DEFAULT_SWING_LENGTH,
        internal_length => $args{internal_length} // DEFAULT_INTERNAL_LENGTH,
        eq_length       => $args{eq_length}       // DEFAULT_EQ_LENGTH,
        eq_threshold    => $args{eq_threshold}    // DEFAULT_EQ_THRESHOLD,

        # ── Estado de la máquina SWING ───────────────────────────────────
        _sw_high        => undef,   # último Swing High  { level, index, crossed }
        _sw_low         => undef,   # último Swing Low
        _sw_trend       => _NEUTRAL,
        _sw_prev_leg    => undef,

        # ── Estado de la máquina INTERNAL ────────────────────────────────
        _in_high        => undef,
        _in_low         => undef,
        _in_trend       => _NEUTRAL,
        _in_prev_leg    => undef,

        # ── Estado de la máquina EQH/EQL ─────────────────────────────────
        _eq_high        => undef,
        _eq_low         => undef,
        _eq_prev_leg    => undef,

        # ── Resultados (se reconstruyen en cada calculate()) ─────────────
        events          => [],
        by_index        => {},
        features        => {},
        swing_highs     => [],
        swing_lows      => [],
        internal_highs  => [],
        internal_lows   => [],
        eqh             => [],
        eql             => [],
        metadata        => {},
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# reset() — limpia estado completo (se llama automáticamente en calculate())
# =============================================================================
sub reset {
    my ($self) = @_;

    # Máquina SWING
    $self->{_sw_high}     = undef;
    $self->{_sw_low}      = undef;
    $self->{_sw_trend}    = _NEUTRAL;
    $self->{_sw_prev_leg} = undef;

    # Máquina INTERNAL
    $self->{_in_high}     = undef;
    $self->{_in_low}      = undef;
    $self->{_in_trend}    = _NEUTRAL;
    $self->{_in_prev_leg} = undef;

    # EQH/EQL
    $self->{_eq_high}     = undef;
    $self->{_eq_low}      = undef;
    $self->{_eq_prev_leg} = undef;

    # Resultados
    $self->{events}         = [];
    $self->{by_index}       = {};
    $self->{features}       = {};
    $self->{swing_highs}    = [];
    $self->{swing_lows}     = [];
    $self->{internal_highs} = [];
    $self->{internal_lows}  = [];
    $self->{eqh}            = [];
    $self->{eql}            = [];
    $self->{metadata}       = {};

    return $self;
}

# =============================================================================
# calculate($market_data, %args)  →  \%result
#
# Itera barra a barra sobre todo el dataset (respetando replay_controller) y
# reconstruye el estado completo de ambas máquinas en un solo bucle O(N).
# =============================================================================
sub calculate {
    my ($self, $market_data, %args) = @_;
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

    # Precarga todas las velas en un array plano → acceso O(1)
    my @candles;
    $#candles = $last_index;   # pre-extiende el array para evitar reallocations
    for my $i (0 .. $last_index) {
        $candles[$i] = $market_data->get_candle($i);
    }

    my $n         = $last_index + 1;
    my $sw_len    = $self->{swing_length};
    my $in_len    = $self->{internal_length};
    my $eq_len    = $self->{eq_length};
    my $eq_thr    = $self->{eq_threshold};

    # ATR global (200 períodos) para el umbral EQH/EQL
    my $atr = _compute_atr(\@candles, $last_index, 200);

    # =========================================================================
    # Bucle principal: itera barra a barra, igual que Pine Script en cada tick.
    # =========================================================================
    for my $i (0 .. $last_index) {
        next unless $candles[$i];

        # ── 1. Swing Structure: actualización de pivotes ──────────────────
        $self->_update_pivots(\@candles, $i, $sw_len,
            high_ref  => \$self->{_sw_high},
            low_ref   => \$self->{_sw_low},
            prev_ref  => \$self->{_sw_prev_leg},
            store_h   => $self->{swing_highs},
            store_l   => $self->{swing_lows},
        );

        # ── 2. Internal Structure: actualización de pivotes ───────────────
        $self->_update_pivots(\@candles, $i, $in_len,
            high_ref  => \$self->{_in_high},
            low_ref   => \$self->{_in_low},
            prev_ref  => \$self->{_in_prev_leg},
            store_h   => $self->{internal_highs},
            store_l   => $self->{internal_lows},
        );

        # ── 3. EQH / EQL ─────────────────────────────────────────────────
        $self->_update_equal_hl(\@candles, $i, $eq_len,
            high_ref  => \$self->{_eq_high},
            low_ref   => \$self->{_eq_low},
            prev_ref  => \$self->{_eq_prev_leg},
            atr       => $atr,
            threshold => $eq_thr,
        );

        # ── 4. displayStructure() — Swing ─────────────────────────────────
        $self->_check_structure_break(\@candles, $i,
            high_ref  => \$self->{_sw_high},
            low_ref   => \$self->{_sw_low},
            trend_ref => \$self->{_sw_trend},
            scope     => 'swing',
        );

        # ── 5. displayStructure() — Internal ──────────────────────────────
        $self->_check_structure_break(\@candles, $i,
            high_ref  => \$self->{_in_high},
            low_ref   => \$self->{_in_low},
            trend_ref => \$self->{_in_trend},
            scope     => 'internal',
        );
    }

    # ── Construye metadata de salida ─────────────────────────────────────────
    my $sw_trend_str = _bias_str($self->{_sw_trend});
    my $in_trend_str = _bias_str($self->{_in_trend});

    my ($bos_count, $choch_count) = (0, 0);
    for my $e (@{ $self->{events} }) {
        $bos_count++   if $e->{kind} eq 'BOS';
        $choch_count++ if $e->{kind} eq 'CHoCH';
        
        # Construye el hash de features planas para ML (ej. internal_event => 'BOS_BULL')
        my $idx = $e->{index};
        $self->{features}{$idx} //= {};
        
        if ($e->{kind} eq 'BOS' || $e->{kind} eq 'CHoCH') {
            my $key = $e->{scope} eq 'internal' ? 'internal_event' : 'swing_event';
            my $val = uc($e->{kind}) . '_' . (uc($e->{direction}) =~ s/ISH//r); # BOS_BULL / CHOCH_BEAR
            $self->{features}{$idx}{$key} = $val;
        }
        elsif ($e->{kind} eq 'EQH') { $self->{features}{$idx}{eqh} = 1; }
        elsif ($e->{kind} eq 'EQL') { $self->{features}{$idx}{eql} = 1; }
    }

    $self->{metadata} = {
        timeframe       => $args{timeframe}
                        || ($market_data->can('active_tf') ? $market_data->active_tf() : 'unknown'),
        total_candles   => $n,
        last_index      => $last_index,
        visible_limit   => $visible_limit,
        swing_length    => $sw_len,
        internal_length => $in_len,
        eq_length       => $eq_len,
        eq_threshold    => $eq_thr,
        atr             => $atr,
        event_count     => scalar(@{ $self->{events} }),
        bos_count       => $bos_count,
        choch_count     => $choch_count,
        eqh_count       => scalar(@{ $self->{eqh} }),
        eql_count       => scalar(@{ $self->{eql} }),
        swing_trend     => $sw_trend_str,
        internal_trend  => $in_trend_str,
        swing_high_count    => scalar(@{ $self->{swing_highs} }),
        swing_low_count     => scalar(@{ $self->{swing_lows} }),
        internal_high_count => scalar(@{ $self->{internal_highs} }),
        internal_low_count  => scalar(@{ $self->{internal_lows} }),
    };

    return {
        events          => $self->{events},
        by_index        => $self->{by_index},
        features        => $self->{features},
        swing_highs     => $self->{swing_highs},
        swing_lows      => $self->{swing_lows},
        internal_highs  => $self->{internal_highs},
        internal_lows   => $self->{internal_lows},
        eqh             => $self->{eqh},
        eql             => $self->{eql},
        swing_trend     => $sw_trend_str,
        internal_trend  => $in_trend_str,
        # ── Estado final de los pivotes activos (para OrderBlockEngine) ───
        last_swing_high    => $self->{_sw_high},
        last_swing_low     => $self->{_sw_low},
        last_internal_high => $self->{_in_high},
        last_internal_low  => $self->{_in_low},
        metadata        => $self->{metadata},
    };
}

# =============================================================================
# Accesores públicos (compatibles con el patrón de los otros engines)
# =============================================================================
sub events         { $_[0]->{events}         || [] }
sub swing_highs    { $_[0]->{swing_highs}    || [] }
sub swing_lows     { $_[0]->{swing_lows}     || [] }
sub internal_highs { $_[0]->{internal_highs} || [] }
sub internal_lows  { $_[0]->{internal_lows}  || [] }
sub eqh            { $_[0]->{eqh}            || [] }
sub eql            { $_[0]->{eql}            || [] }
sub metadata       { $_[0]->{metadata}       || {} }
sub swing_trend    { _bias_str($_[0]->{_sw_trend}) }
sub internal_trend { _bias_str($_[0]->{_in_trend}) }

# =============================================================================
# PRIVATE — _leg(\@candles, $i, $size)  →  _BEARISH_LEG | _BULLISH_LEG | undef
#
# Réplica exacta de la función leg(int size) del Pine Script.
#
# Modelo mental (Pine Script):
#   • La barra ACTUAL es la barra 0 del script.
#   • high[size]          = high de la barra pivote candidata (size barras atrás)
#   • ta.highest(size)    = máximo de las barras [0..size-1]  (posteriores al pivote)
#   • ta.lowest(size)     = mínimo de las barras [0..size-1]
#
# En nuestro array temporal (índice 0 = más antiguo):
#   • Barra actual        = candles[$i]
#   • Pivote candidato    = candles[$i - size]
#   • Ventana posterior   = candles[$i - size + 1 .. $i]
#
# Condición de Swing HIGH confirmado:
#   high[pivote] > highest(ventana_posterior)
#   → El pivote es el high local más alto de las `size` barras siguientes.
#
# Condición de Swing LOW confirmado:
#   low[pivote] < lowest(ventana_posterior)
# =============================================================================
sub _leg {
    my ($candles, $i, $size) = @_;

    return undef if $i < $size;

    my $pivot_idx = $i - $size;
    my $pivot     = $candles->[$pivot_idx];
    return undef unless $pivot;

    # Busca el máximo y mínimo de la ventana [pivot+1 .. i]
    my ($hi, $lo);
    for my $j ($pivot_idx + 1 .. $i) {
        my $c = $candles->[$j] or next;
        $hi = $c->{high} if !defined $hi || $c->{high} > $hi;
        $lo = $c->{low}  if !defined $lo || $c->{low}  < $lo;
    }
    return undef unless defined $hi && defined $lo;

    if    ($pivot->{high} > $hi) { return _BEARISH_LEG; }  # swing HIGH confirmado
    elsif ($pivot->{low}  < $lo) { return _BULLISH_LEG; }  # swing LOW  confirmado
    return undef;
}

# =============================================================================
# PRIVATE — _update_pivots(\@c, $i, $size, %opts)
#
# Réplica de getCurrentStructure(size, false, $internal) del Pine Script.
# Detecta cambios de leg y actualiza el pivote high/low activo.
#
# Un CAMBIO DE LEG significa:
#   BEARISH_LEG → BULLISH_LEG  (+1)  →  acabamos de confirmar un SWING LOW
#   BULLISH_LEG → BEARISH_LEG  (-1)  →  acabamos de confirmar un SWING HIGH
#
# El pivote confirmado siempre está en $i - $size  (el candidato de esa barra).
# =============================================================================
sub _update_pivots {
    my ($self, $candles, $i, $size, %o) = @_;

    my $current_leg = _leg($candles, $i, $size);
    return unless defined $current_leg;

    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $current_leg;

    # Sin cambio de leg → ningún nuevo pivote en esta barra
    return if defined $prev_leg && $prev_leg == $current_leg;

    my $pivot_idx    = $i - $size;
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;

    # Determina si es LOW o HIGH:
    #   ta.change(leg) == +1  →  BULLISH_LEG recién comenzado  →  pivote LOW
    #   ta.change(leg) == -1  →  BEARISH_LEG recién comenzado  →  pivote HIGH
    my $delta = defined $prev_leg ? ($current_leg - $prev_leg) : $current_leg;

    if ($delta > 0) {
        # ── Pivote LOW confirmado ─────────────────────────────────────────
        my $old  = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};
        my $new_pivot = {
            level      => $nlvl,
            last_level => defined $old ? $old->{level} : undef,
            crossed    => 0,
            index      => $pivot_idx,
        };
        ${ $o{low_ref} } = $new_pivot;

        my $label = _low_label($new_pivot->{last_level}, $nlvl);
        my $entry = {
            index      => $pivot_idx,
            level      => $nlvl,
            last_level => $new_pivot->{last_level},
            label      => $label,
            crossed    => 0,
        };
        push @{ $o{store_l} }, $entry;
        # Poda anti-fuga de memoria
        shift @{ $o{store_l} } while @{ $o{store_l} } > MAX_PIVOT_HISTORY;
    }
    elsif ($delta < 0) {
        # ── Pivote HIGH confirmado ────────────────────────────────────────
        my $old  = ${ $o{high_ref} };
        my $nlvl = $pivot_candle->{high};
        my $new_pivot = {
            level      => $nlvl,
            last_level => defined $old ? $old->{level} : undef,
            crossed    => 0,
            index      => $pivot_idx,
        };
        ${ $o{high_ref} } = $new_pivot;

        my $label = _high_label($new_pivot->{last_level}, $nlvl);
        my $entry = {
            index      => $pivot_idx,
            level      => $nlvl,
            last_level => $new_pivot->{last_level},
            label      => $label,
            crossed    => 0,
        };
        push @{ $o{store_h} }, $entry;
        shift @{ $o{store_h} } while @{ $o{store_h} } > MAX_PIVOT_HISTORY;
    }
}

# =============================================================================
# PRIVATE — _update_equal_hl(\@c, $i, $size, %opts)
#
# Réplica de getCurrentStructure(equalHighsLowsLengthInput, true) del Pine Script.
# Cuando el nuevo pivote es "casi igual" al anterior (dentro de threshold × ATR),
# emite un evento EQH o EQL.
# =============================================================================
sub _update_equal_hl {
    my ($self, $candles, $i, $size, %o) = @_;

    my $current_leg = _leg($candles, $i, $size);
    return unless defined $current_leg;

    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $current_leg;
    return if defined $prev_leg && $prev_leg == $current_leg;

    my $pivot_idx    = $i - $size;
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;

    my $atr = $o{atr} // 0;
    my $thr = $o{threshold} // DEFAULT_EQ_THRESHOLD;
    my $delta = defined $prev_leg ? ($current_leg - $prev_leg) : $current_leg;

    if ($delta > 0) {
        # Pivote LOW
        my $old = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};

        if (defined $old && defined $old->{level} && $atr > 0) {
            if (abs($old->{level} - $nlvl) < $thr * $atr) {
                my $evt = {
                    kind        => 'EQL',
                    index       => $i,
                    swing_index => $pivot_idx,
                    level       => $nlvl,
                    prev_level  => $old->{level},
                    prev_index  => $old->{index},
                };
                push @{ $self->{eql} }, $evt;
                $self->_push_event($i, $evt);
            }
        }
        ${ $o{low_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
    elsif ($delta < 0) {
        # Pivote HIGH
        my $old = ${ $o{high_ref} };
        my $nlvl = $pivot_candle->{high};

        if (defined $old && defined $old->{level} && $atr > 0) {
            if (abs($old->{level} - $nlvl) < $thr * $atr) {
                my $evt = {
                    kind        => 'EQH',
                    index       => $i,
                    swing_index => $pivot_idx,
                    level       => $nlvl,
                    prev_level  => $old->{level},
                    prev_index  => $old->{index},
                };
                push @{ $self->{eqh} }, $evt;
                $self->_push_event($i, $evt);
            }
        }
        ${ $o{high_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
}

# =============================================================================
# PRIVATE — _check_structure_break(\@c, $i, %opts)
#
# Réplica de displayStructure(bool internal) del Pine Script.
#
# ── Lógica BOS vs CHoCH (fórmula exacta) ─────────────────────────────────────
#
#   CRUCE BULLISH  (close > pivot_high.level  AND  NOT crossed):
#     trend anterior == BEARISH  →  CHoCH   (ruptura contra-tendencia)
#     trend anterior != BEARISH  →  BOS     (ruptura a favor de tendencia)
#     → trend := BULLISH
#     → pivot_high.crossed := 1  (el nivel ya fue consumido; no vuelve a disparar)
#
#   CRUCE BEARISH  (close < pivot_low.level  AND  NOT crossed):
#     trend anterior == BULLISH  →  CHoCH
#     trend anterior != BULLISH  →  BOS
#     → trend := BEARISH
#     → pivot_low.crossed := 1
# =============================================================================
sub _check_structure_break {
    my ($self, $candles, $i, %o) = @_;

    my $c = $candles->[$i];
    return unless $c;
    my $close = $c->{close};
    return unless defined $close;

    my $scope     = $o{scope} // 'swing';
    my $trend_ref = $o{trend_ref};

    # ── Cruce BULLISH: close supera el último HIGH ────────────────────────
    my $ph = ${ $o{high_ref} };
    if (defined $ph && defined $ph->{level} && !$ph->{crossed}) {
        if ($close > $ph->{level}) {
            my $kind = ($$trend_ref == _BEARISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BULLISH;
            $ph->{crossed} = 1;

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bullish',
                index       => $i,
                level       => $ph->{level},
                swing_index => $ph->{index},
                swing_high  => 1,
                swing_low   => 0,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);
        }
    }

    # ── Cruce BEARISH: close cae bajo el último LOW ───────────────────────
    my $pl = ${ $o{low_ref} };
    if (defined $pl && defined $pl->{level} && !$pl->{crossed}) {
        if ($close < $pl->{level}) {
            my $kind = ($$trend_ref == _BULLISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BEARISH;
            $pl->{crossed} = 1;

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bearish',
                index       => $i,
                level       => $pl->{level},
                swing_index => $pl->{index},
                swing_high  => 0,
                swing_low   => 1,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);
        }
    }
}

# =============================================================================
# PRIVATE — helpers
# =============================================================================
sub _push_event {
    my ($self, $i, $evt) = @_;
    $self->{by_index}{$i} //= [];
    push @{ $self->{by_index}{$i} }, $evt;
}

# ATR de media simple sobre las últimas $period velas
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
        my $tr = $hl;
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
        $sum += $tr;
        $count++;
    }
    return $count > 0 ? $sum / $count : 1.0;
}

# Etiquetas de pivotes (HH / LH / EQH  y  HL / LL / EQL)
sub _high_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'HH'  if !defined $prev || $curr > $prev;
    return 'LH'  if $curr < $prev;
    return 'EQH';
}
sub _low_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'LL'  if !defined $prev || $curr < $prev;
    return 'HL'  if $curr > $prev;
    return 'EQL';
}

sub _bias_str {
    my ($b) = @_;
    return 'bullish' if defined $b && $b == _BULLISH;
    return 'bearish' if defined $b && $b == _BEARISH;
    return 'neutral';
}

1;

__END__

=pod

=head1 NAME

Market::Concepts::SMCStructureEngine — Doble máquina de estados SMC (LuxAlgo v2)

=head1 SYNOPSIS

    my $engine = Market::Concepts::SMCStructureEngine->new(
        swing_length    => 50,
        internal_length =>  5,
        eq_length       =>  3,
        eq_threshold    =>  0.1,
    );

    my $result = $engine->calculate($market_data,
        replay_controller => $rc,
        timeframe         => '1h',
    );

    # Todos los eventos BOS/CHoCH/EQH/EQL cronológicos
    for my $e (@{ $result->{events} }) { ... }

    # Formato plano de features para Machine Learning (por vela)
    my $features = $result->{features}{$i} // {};
    # $features = { internal_event => 'BOS_BULL', swing_event => 'CHOCH_BEAR', eqh => 1 }

    # Último pivote activo (lo consume OrderBlockEngine)
    my $last_sh = $result->{last_swing_high};   # { level, index, crossed }

=head1 DESCRIPTION

Traduce las funciones C<leg()>, C<getCurrentStructure()> y
C<displayStructure()> del Pine Script v5 de LuxAlgo ejecutando DOS máquinas
de estado paralelas (Swing N=50, Internal N=5) en un único pase O(N) sobre
el dataset.

La clave C<swing_index> de cada evento BOS/CHoCH apunta a la vela exacta
donde se formó el pivote que fue cruzado — esa es la información que
C<OrderBlockEngine> necesita para ubicar la zona institucional (Supply/Demand).

=cut
