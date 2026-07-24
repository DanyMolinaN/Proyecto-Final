package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Pivots
# =============================================================================
# Deteccion de legs, pivotes e equal high/low.
# Continuacion del paquete Market::Concepts::SMCStructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _leg {
    my ($candles, $i, $size) = @_;
    return undef if $i < $size;
    my $pivot_idx = $i - $size;
    my $pivot     = $candles->[$pivot_idx];
    return undef unless $pivot;
    my ($hi, $lo);
    for my $j ($pivot_idx + 1 .. $i) {
        my $c = $candles->[$j] or next;
        $hi = $c->{high} if !defined $hi || $c->{high} > $hi;
        $lo = $c->{low}  if !defined $lo || $c->{low}  < $lo;
    }
    return undef unless defined $hi && defined $lo;
    if    ($pivot->{high} > $hi) { return _BEARISH_LEG; }
    elsif ($pivot->{low}  < $lo) { return _BULLISH_LEG; }
    return undef;
}

# =============================================================================
# PRIVATE — _update_pivots  (sin cambios respecto v2.0)
# =============================================================================
sub _update_pivots {
    my ($self, $candles, $i, $size, %o) = @_;
    my $current_leg = _leg($candles, $i, $size);
    return unless defined $current_leg;
    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $current_leg;
    return if defined $prev_leg && $prev_leg == $current_leg;
    my $pivot_idx    = $i - $size;
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;
    my $delta = defined $prev_leg ? ($current_leg - $prev_leg) : $current_leg;
    if ($delta > 0) {
        my $old  = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};
        my $new_pivot = { level => $nlvl, last_level => defined $old ? $old->{level} : undef, crossed => 0, index => $pivot_idx };
        ${ $o{low_ref} } = $new_pivot;
        my $label = _low_label($new_pivot->{last_level}, $nlvl);
        my $entry = { index => $pivot_idx, level => $nlvl, last_level => $new_pivot->{last_level}, label => $label, crossed => 0 };
        push @{ $o{store_l} }, $entry;
        shift @{ $o{store_l} } while @{ $o{store_l} } > MAX_PIVOT_HISTORY;
    }
    elsif ($delta < 0) {
        my $old  = ${ $o{high_ref} };
        my $nlvl = $pivot_candle->{high};
        my $new_pivot = { level => $nlvl, last_level => defined $old ? $old->{level} : undef, crossed => 0, index => $pivot_idx };
        ${ $o{high_ref} } = $new_pivot;
        my $label = _high_label($new_pivot->{last_level}, $nlvl);
        my $entry = { index => $pivot_idx, level => $nlvl, last_level => $new_pivot->{last_level}, label => $label, crossed => 0 };
        push @{ $o{store_h} }, $entry;
        shift @{ $o{store_h} } while @{ $o{store_h} } > MAX_PIVOT_HISTORY;
    }
}

# =============================================================================
# PRIVATE — _update_equal_hl  (Req-3: registra en %open_eq al crear el evento)
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
    my $open_eq = $o{open_eq} // {};

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
                    # Req-3: campos de proyección (se completan en el pase)
                    start_index => $i,
                    end_index   => undef,   # se rellena cuando se detecta el cierre
                    is_open     => 1,
                };
                push @{ $self->{eql} }, $evt;
                $self->_push_event($i, $evt);
                # Req-3: registrar en HashMap O(1)
                my $key = 'EQL|' . sprintf('%.6f', $nlvl);
                $open_eq->{$key} //= [];
                push @{ $open_eq->{$key} }, $evt;
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
                    start_index => $i,
                    end_index   => undef,
                    is_open     => 1,
                };
                push @{ $self->{eqh} }, $evt;
                $self->_push_event($i, $evt);
                my $key = 'EQH|' . sprintf('%.6f', $nlvl);
                $open_eq->{$key} //= [];
                push @{ $open_eq->{$key} }, $evt;
            }
        }
        ${ $o{high_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
}

# =============================================================================
# PRIVATE — _check_structure_break
# Req-2: `crossed=1` bloquea re-disparo pero NO oculta el nivel (permanente).
# Req-3: al emitir BOS/CHoCH cierra EQL/EQH abiertos cuyo nivel sea cruzado.
# =============================================================================

1;
