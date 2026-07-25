package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Pivots
# =============================================================================
# Deteccion de legs, pivotes e equal high/low.
# Alineado con Proyecto_David SMC_Structures2::_leg_raw / _get_current_structure:
#   - leg_state PERSISTE cuando no hay newHigh/newLow (no se pierde el estado)
#   - startOfNewLeg solo cuando cambia la pierna
#   - Nuevo pivote same-side resetea crossed=0 (doble punta mueve el nivel)
#   - EQH/EQL conecta prev_index → swing_index (pivote a pivote, sin proyeccion)
# =============================================================================

use strict;
use warnings;

# -----------------------------------------------------------------------------
# _leg_raw: replica Pine leg(size)
#   newHigh = high[size] > highest(size)   ventana [i-size+1 .. i]
#   newLow  = low[size]  < lowest(size)
# -----------------------------------------------------------------------------
sub _leg_raw {
    my ($candles, $i, $size) = @_;
    return undef if $i < $size;
    my $ref_idx  = $i - $size;
    my $win_from = $i - $size + 1;
    my $win_to   = $i;
    return undef if $win_from < 0;

    my $pivot = $candles->[$ref_idx];
    return undef unless $pivot;

    my ($hi_max, $lo_min);
    for my $k ($win_from .. $win_to) {
        my $c = $candles->[$k] or next;
        $hi_max = $c->{high} if !defined $hi_max || $c->{high} > $hi_max;
        $lo_min = $c->{low}  if !defined $lo_min || $c->{low}  < $lo_min;
    }
    return undef unless defined $hi_max && defined $lo_min;

    return {
        new_high => ($pivot->{high} > $hi_max) ? 1 : 0,
        new_low  => ($pivot->{low}  < $lo_min) ? 1 : 0,
        ref_idx  => $ref_idx,
    };
}

# Compat: _leg() usado por codigo legacy — devuelve BULLISH_LEG/BEARISH_LEG o undef
sub _leg {
    my ($candles, $i, $size) = @_;
    my $raw = _leg_raw($candles, $i, $size);
    return undef unless $raw;
    if    ($raw->{new_high}) { return _BEARISH_LEG; }
    elsif ($raw->{new_low})  { return _BULLISH_LEG; }
    return undef;
}

# =============================================================================
# _update_pivots — con persistencia de leg_state (como David)
# =============================================================================
sub _update_pivots {
    my ($self, $candles, $i, $size, %o) = @_;
    my $raw = _leg_raw($candles, $i, $size);
    return unless $raw;

    # Persistencia del estado de pierna (var int legState en Pine)
    my $leg_state = ${ $o{prev_ref} };   # usamos prev_ref tambien como state
    # Si hay un state_ref dedicado, usarlo; si no, prev_ref guarda el estado vigente
    if (defined $o{state_ref}) {
        $leg_state = ${ $o{state_ref} };
    }

    if ($raw->{new_high}) {
        $leg_state = _BEARISH_LEG;
    }
    elsif ($raw->{new_low}) {
        $leg_state = _BULLISH_LEG;
    }

    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $leg_state;
    ${ $o{state_ref} } = $leg_state if defined $o{state_ref};

    return unless defined $prev_leg;                 # ta.change necesita valor previo
    return if $leg_state == $prev_leg;               # startOfNewLeg

    my $pivot_idx    = $raw->{ref_idx};
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;

    my $delta = $leg_state - $prev_leg;   # +1 bullish leg, -1 bearish leg

    if ($delta > 0) {
        # startOfBullishLeg → nuevo swing LOW
        my $old  = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};
        # Doble punta: resetea crossed=0 y mueve currentLevel al nuevo pivote
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
        shift @{ $o{store_l} } while @{ $o{store_l} } > MAX_PIVOT_HISTORY;
    }
    elsif ($delta < 0) {
        # startOfBearishLeg → nuevo swing HIGH
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
# _update_equal_hl — EQH/EQL pivote a pivote (David: idx_from → idx_to)
# Sin proyeccion hasta BOS: la linea une los dos pivotes iguales.
# =============================================================================
sub _update_equal_hl {
    my ($self, $candles, $i, $size, %o) = @_;
    my $raw = _leg_raw($candles, $i, $size);
    return unless $raw;

    my $leg_state = ${ $o{prev_ref} };
    if ($raw->{new_high}) {
        $leg_state = _BEARISH_LEG;
    }
    elsif ($raw->{new_low}) {
        $leg_state = _BULLISH_LEG;
    }

    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $leg_state;

    return unless defined $prev_leg;
    return if $leg_state == $prev_leg;

    my $pivot_idx    = $raw->{ref_idx};
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;

    my $atr = $o{atr} // 0;
    my $thr = $o{threshold} // DEFAULT_EQ_THRESHOLD;
    my $delta = $leg_state - $prev_leg;

    if ($delta > 0) {
        my $old  = ${ $o{low_ref} };
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
                    # David: linea solo entre los dos pivotes (sin proyeccion)
                    start_index => $old->{index},
                    end_index   => $pivot_idx,
                    is_open     => 0,
                    idx_from    => $old->{index},
                    idx_to      => $pivot_idx,
                };
                push @{ $self->{eql} }, $evt;
                $self->_push_event($i, $evt);
            }
        }
        ${ $o{low_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
    elsif ($delta < 0) {
        my $old  = ${ $o{high_ref} };
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
                    start_index => $old->{index},
                    end_index   => $pivot_idx,
                    is_open     => 0,
                    idx_from    => $old->{index},
                    idx_to      => $pivot_idx,
                };
                push @{ $self->{eqh} }, $evt;
                $self->_push_event($i, $evt);
            }
        }
        ${ $o{high_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
}

1;
