package Market::Indicators::LiquidityDavid;

# =============================================================================
# Market::Indicators::LiquidityDavid
#
# Portado desde Proyecto_David/Market/Indicators/Liquidity.pm
# Adaptaciones para Kevin:
#   - Package renombrado a LiquidityDavid.
#   - Se agrega recompute($md) para IndicatorManager::rebuild_all().
#   - Los parametros atr/zzmtf/zzvp ya existian en David, se mantienen igual.
#   - NOTA: get_trendline() y get_swings() se delegan al swing_source (zzmtf)
#     si se desea; el overlay LiquidityDavidOverlay acepta swing_source.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        atr       => $args{atr},       # Indicators::ATR de Kevin (get_values)
        zzmtf     => $args{zzmtf},     # ZigZagMTF2David (get_swings)
        zzvp      => $args{zzvp},      # ZigZagVP2David  (get_pivots)
        fractal_n => $args{fractal_n} // $args{k} // 3,
        m_atr     => $args{m_atr}     // 1.5,
        atr_period => $args{atr_period} // 14,
        v_desp    => $args{v_desp}    // 10,
        u_desp    => $args{u_desp}    // 2.0,

        eq_factor    => $args{eq_factor}    // 0.10,
        grab_window  => $args{grab_window}  // 3,
        acceptance_n => $args{acceptance_n} // 10,

        level_min_dist_atr => $args{level_min_dist_atr} // 0.5,
        level_expiry_n     => $args{level_expiry_n}     // 80,
        eq_lookback        => $args{eq_lookback}        // 30,

        _c   => [],
        _atr => [],

        _pending_fractal      => [],
        _pending_displacement => [],

        _swings  => [],
        _next_id => 1,

        _last_H => undef,
        _last_L => undef,

        _trendline => [],

        _levels => [],
        _equals => [],
        _events => [],
        _open_level_refs => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}   = [];
    $self->{_atr} = [];
    $self->{_pending_fractal}      = [];
    $self->{_pending_displacement} = [];
    $self->{_swings}  = [];
    $self->{_next_id} = 1;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    $self->{_trendline} = [];
    $self->{_levels} = [];
    $self->{_equals} = [];
    $self->{_events} = [];
    $self->{_open_level_refs} = [];
    $self->{_seen_swing_ids}  = {};
    $self->{_zz_raw_len}      = undef;
    $self->{_zz_swing_count}  = undef;
}

sub get_values { return []; }

# recompute($md): contrato de IndicatorManager::rebuild_all() de Kevin.
sub recompute {
    my ( $self, $md ) = @_;
    return unless $md;
    $self->reset();
    my $size = $md->size // 0;
    for my $idx ( 0 .. $size - 1 ) {
        $self->update_at_index( $md, $idx );
    }
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_ingest( $md, $c, $idx );
    # Sync zigzag solo cuando cambia el numero de swings (no en cada vela).
    # Antes: get_swings()+loop en CADA barra => ~4s en TF switch.
    $self->_sync_levels_from_internal_zigzag($md);
}

# update_last no duplica state_machine: _ingest ya lo hace.

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $md->can('last_index') ? $md->last_index : undef;
    my $c   = $md->last_candle;
    return unless defined $c;
    $idx = $#{ $self->{_c} } + 1 unless defined $idx;
    $self->_ingest( $md, $c, $idx );
}

# Accesores publicos
sub get_swings    { return $_[0]->{_swings}; }
sub get_trendline { return $_[0]->{_trendline}; }
sub get_levels    { return $_[0]->{_levels}; }
sub get_equals    { return $_[0]->{_equals}; }
sub get_events    { return $_[0]->{_events}; }

sub side_label {
    my ( $self, $side ) = @_;
    return $side eq 'buy' ? 'BSL' : 'SSL';
}

sub last_swing_high {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'H';
    }
    return undef;
}

sub last_swing_low {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'L';
    }
    return undef;
}

sub _ingest {
    my ( $self, $md, $c, $idx ) = @_;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;

    my $atr_arr = $self->{atr} && $self->{atr}->can('get_values')
        ? $self->{atr}->get_values
        : undef;
    $self->{_atr} = $atr_arr if $atr_arr;

    $self->_try_confirm_fractals($idx);
    $self->_check_displacement( $idx, $md );
    $self->_update_state_machine( $md, $idx );
}

sub _try_confirm_fractals {
    my ( $self, $idx ) = @_;
    my $n = $self->{fractal_n};
    my $t = $idx - $n;
    return if $t < $n;
    return unless defined $self->{_c}[$t];

    my $c = $self->{_c};
    for my $i ( 1 .. $n ) {
        return unless defined $c->[ $t - $i ] && defined $c->[ $t + $i ];
    }

    my $is_high = 1;
    my $is_low  = 1;
    for my $i ( 1 .. $n ) {
        $is_high = 0 if !( $c->[$t]{high} > $c->[ $t - $i ]{high}
                         && $c->[$t]{high} > $c->[ $t + $i ]{high} );
        $is_low  = 0 if !( $c->[$t]{low}  < $c->[ $t - $i ]{low}
                         && $c->[$t]{low}  < $c->[ $t + $i ]{low} );
    }

    return unless $is_high || $is_low;

    my $atr_t = $self->_atr_at($t);
    return unless defined $atr_t && $atr_t > 0;

    if ($is_high) { $self->_apply_atr_filter( $t, 'H', $c->[$t]{high}, $atr_t ); }
    if ($is_low)  { $self->_apply_atr_filter( $t, 'L', $c->[$t]{low},  $atr_t ); }
}

sub _atr_at {
    my ( $self, $t ) = @_;
    my $arr = $self->{_atr};
    return undef unless $arr && ref($arr) eq 'ARRAY';
    return $arr->[$t];
}

sub _apply_atr_filter {
    my ( $self, $t, $kind, $price, $atr_t ) = @_;

    my $opposite = ( $kind eq 'H' ) ? $self->{_last_L} : $self->{_last_H};

    if ( defined $opposite ) {
        my $dist = abs( $price - $opposite->{price} );
        my $min_req = $self->{m_atr} * $atr_t;
        return if !( $dist > $min_req );
    }

    push @{ $self->{_pending_displacement} }, {
        index    => $t,
        kind     => $kind,
        price    => $price,
        atr      => $atr_t,
        deadline => $t + $self->{v_desp},
        extreme  => $price,
    };
}

sub _check_displacement {
    my ( $self, $idx, $market_data ) = @_;
    return unless @{ $self->{_pending_displacement} };

    my $c = $self->{_c}[$idx];
    return unless defined $c;

    my @still_pending;
    for my $cand ( @{ $self->{_pending_displacement} } ) {
        if ( $idx <= $cand->{index} ) { push @still_pending, $cand; next; }

        my $required = $self->{u_desp} * $cand->{atr};

        if ( $cand->{kind} eq 'H' ) {
            $cand->{extreme} = $c->{low} if $c->{low} < $cand->{extreme};
            my $travel = $cand->{price} - $cand->{extreme};
            if ( $travel >= $required ) {
                $self->_consolidate( $cand, $market_data );
                next;
            }
        }
        else {
            $cand->{extreme} = $c->{high} if $c->{high} > $cand->{extreme};
            my $travel = $cand->{extreme} - $cand->{price};
            if ( $travel >= $required ) {
                $self->_consolidate( $cand, $market_data );
                next;
            }
        }

        if ( $idx >= $cand->{deadline} ) {
            next;
        }
        push @still_pending, $cand;
    }
    $self->{_pending_displacement} = \@still_pending;
}

sub _consolidate {
    my ( $self, $cand, $market_data ) = @_;

    my $swing = {
        id    => $self->{_next_id}++,
        index => $cand->{index},
        ts    => $self->{_c}[ $cand->{index} ]{ts},
        kind  => $cand->{kind},
        price => $cand->{price},
    };

    my $pos = $self->_find_insert_pos( $swing->{index} );
    my $left  = $pos > 0 ? $self->{_swings}[ $pos - 1 ] : undef;
    my $right = $pos <= $#{ $self->{_swings} } ? $self->{_swings}[$pos] : undef;

    my $same_kind_neighbor =
        ( defined $left  && $left->{kind}  eq $swing->{kind} ) ? $left  :
        ( defined $right && $right->{kind} eq $swing->{kind} ) ? $right :
        undef;

    if ( defined $same_kind_neighbor ) {
        my $new_is_more_extreme =
            ( $swing->{kind} eq 'H' )
                ? ( $swing->{price} > $same_kind_neighbor->{price} )
                : ( $swing->{price} < $same_kind_neighbor->{price} );

        return unless $new_is_more_extreme;

        $self->_remove_swing($same_kind_neighbor);
        $pos = $self->_find_insert_pos( $swing->{index} );
    }

    splice( @{ $self->{_swings} }, $pos, 0, $swing );
    $self->_insert_sorted_by_index( $self->{_trendline}, { index => $swing->{index}, price => $swing->{price} } );
    $self->_refresh_last_refs();
    $self->_check_equal_levels( $swing->{kind}, $swing );
}

sub _find_insert_pos {
    my ( $self, $index ) = @_;
    my $swings = $self->{_swings};
    my $i = $#$swings;
    while ( $i >= 0 && $swings->[$i]{index} > $index ) { $i--; }
    return $i + 1;
}

sub _remove_swing {
    my ( $self, $swing ) = @_;

    my $swings = $self->{_swings};
    for my $i ( 0 .. $#$swings ) {
        if ( $swings->[$i]{id} == $swing->{id} ) {
            splice( @$swings, $i, 1 );
            last;
        }
    }

    my $tl = $self->{_trendline};
    for my $i ( 0 .. $#$tl ) {
        if ( $tl->[$i]{index} == $swing->{index} ) {
            splice( @$tl, $i, 1 );
            last;
        }
    }

    for my $i ( reverse 0 .. $#{ $self->{_levels} } ) {
        my $lv = $self->{_levels}[$i];
        if ( defined $lv->{origin_swing_id} && $lv->{origin_swing_id} == $swing->{id} && $lv->{state} eq 'DETECTED' ) {
            splice( @{ $self->{_levels} }, $i, 1 );
        }
    }
    $self->{_open_level_refs} = [
        grep {
            defined $_->{origin_swing_id} && $_->{origin_swing_id} != $swing->{id}
        } @{ $self->{_open_level_refs} }
    ];
}

sub _insert_sorted_by_index {
    my ( $self, $arr, $item ) = @_;
    my $i = $#$arr;
    while ( $i >= 0 && $arr->[$i]{index} > $item->{index} ) { $i--; }
    splice( @$arr, $i + 1, 0, $item );
}

sub _refresh_last_refs {
    my ($self) = @_;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    my $swings = $self->{_swings};
    for ( my $i = $#$swings; $i >= 0; $i-- ) {
        my $s = $swings->[$i];
        if ( $s->{kind} eq 'H' && !defined $self->{_last_H} ) {
            $self->{_last_H} = { index => $s->{index}, price => $s->{price} };
        }
        if ( $s->{kind} eq 'L' && !defined $self->{_last_L} ) {
            $self->{_last_L} = { index => $s->{index}, price => $s->{price} };
        }
        last if defined $self->{_last_H} && defined $self->{_last_L};
    }
}

sub _register_level {
    my ( $self, $kind, $swing, $market_data ) = @_;
    my $side = ( $kind eq 'H' ? 'buy' : 'sell' );

    my $atr_now = $self->_atr_at( $swing->{index} );
    if ( defined $atr_now && $atr_now > 0 ) {
        my $min_dist = $self->{level_min_dist_atr} * $atr_now;
        for my $lv ( @{ $self->{_levels} } ) {
            next unless $lv->{side} eq $side;
            next unless $lv->{state} eq 'DETECTED';
            if ( abs( $lv->{price} - $swing->{price} ) < $min_dist ) {
                my $more_extreme = ( $side eq 'buy' )
                    ? ( $swing->{price} > $lv->{price} )
                    : ( $swing->{price} < $lv->{price} );
                if ($more_extreme) {
                    $lv->{price} = $swing->{price};
                    $lv->{index} = $swing->{index};
                    $lv->{origin_swing_id} = $swing->{id};
                }
                return $lv;
            }
        }
    }

    my $level = {
        id => $self->{_next_id}++, side => $side,
        price => $swing->{price}, index => $swing->{index},
        origin_swing_id => $swing->{id}, state => 'DETECTED',
        classification => undef, swept_at_index => undef, resolved_at_index => undef,
    };
    push @{ $self->{_levels} }, $level;
    return $level;
}

sub _check_equal_levels {
    my ( $self, $kind, $new_swing ) = @_;
    return unless $self->{atr};
    my $atr_values = $self->{atr}->get_values;
    return unless $atr_values && @$atr_values;
    my $atr_at_new = $atr_values->[ $new_swing->{index} ];
    return unless defined $atr_at_new;
    my $tolerance = $atr_at_new * $self->{eq_factor};

    my $swings = $self->{_swings};
    my $from = @$swings - $self->{eq_lookback};
    $from = 0 if $from < 0;

    for my $idx ( $from .. $#$swings ) {
        my $prev = $swings->[$idx];
        next if $prev->{id} == $new_swing->{id};
        next unless $prev->{kind} eq $kind;
        my $diff = abs( $prev->{price} - $new_swing->{price} );
        next if $diff > $tolerance;
        push @{ $self->{_equals} }, {
            kind => ( $kind eq 'H' ? 'EQH' : 'EQL' ),
            i1 => $prev->{index}, i2 => $new_swing->{index},
            p1 => $prev->{price}, p2 => $new_swing->{price},
        };
    }
}

sub _update_state_machine {
    my ( $self, $market_data, $i ) = @_;
    my $candle = $market_data->get_candle($i);
    return unless $candle;
    my @still_open;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        $self->_check_sweep( $level, $candle, $i )      if $level->{state} eq 'DETECTED';
        if ( $level->{state} eq 'DETECTED'
            && ( $i - $level->{index} ) >= $self->{level_expiry_n} ) {
            $level->{state} = 'EXPIRED';
        }
        $self->_check_resolution( $level, $candle, $i ) if $level->{state} eq 'SWEPT';
        push @still_open, $level unless $level->{state} eq 'RESOLVED';
    }
    $self->{_open_level_refs} = \@still_open;
}

sub _check_sweep {
    my ( $self, $level, $candle, $i ) = @_;
    my $swept = ( $level->{side} eq 'buy' )
        ? ( $candle->{high} > $level->{price} ) : ( $candle->{low} < $level->{price} );
    return unless $swept;
    $level->{state} = 'SWEPT';
    $level->{swept_at_index} = $i;
}

sub _check_resolution {
    my ( $self, $level, $candle, $i ) = @_;
    my $n_since = $i - $level->{swept_at_index} + 1;
    my $closed_inside = ( $level->{side} eq 'buy' )
        ? ( $candle->{close} <= $level->{price} ) : ( $candle->{close} >= $level->{price} );
    if ($closed_inside) {
        $self->_resolve( $level, ( $n_since <= $self->{grab_window} ? 'GRAB' : 'SWEEP' ), $i );
        return;
    }
    $self->_resolve( $level, 'RUN', $i ) if $n_since >= $self->{acceptance_n};
}

sub _resolve {
    my ( $self, $level, $classification, $i ) = @_;
    $level->{state} = 'RESOLVED';
    $level->{classification} = $classification;
    $level->{resolved_at_index} = $i;
    my $dir = ( $level->{side} eq 'buy' ) ? 'up' : 'down';
    push @{ $self->{_events} }, {
        type  => $classification, dir => $dir, index => $i, price => $level->{price},
        label => $self->side_label( $level->{side} ) . ' ' . $classification,
    };
}

sub _sync_levels_from_internal_zigzag {
    my ( $self, $market_data ) = @_;
    my $zzmtf = $self->{zzmtf} or return;

    # Early-out sin reconstruir swings: si el zigzag crudo no crecio, nada que hacer.
    my $raw_len = 0;
    if ( ref($zzmtf) eq 'HASH' || (ref($zzmtf) && exists $zzmtf->{_zigzag}) ) {
        $raw_len = scalar @{ $zzmtf->{_zigzag} || [] };
    }
    return if defined $self->{_zz_raw_len} && $self->{_zz_raw_len} == $raw_len;
    $self->{_zz_raw_len} = $raw_len;
    return unless $raw_len >= 4;   # hace falta al menos 2 pivotes (4 slots)

    my $swings = $zzmtf->can('get_swings') ? $zzmtf->get_swings : undef;
    return unless $swings;

    $self->{_seen_swing_ids} //= {};

    for my $sw (@$swings) {
        my $swing_key = "$sw->{index}_$sw->{kind}";
        next if $self->{_seen_swing_ids}{$swing_key};
        $self->{_seen_swing_ids}{$swing_key} = 1;

        my $level = $self->_register_level( $sw->{kind}, $sw, $market_data );
        $level->{priority} = 'normal';
        push @{ $self->{_open_level_refs} }, $level
            unless grep { $_ == $level } @{ $self->{_open_level_refs} };
    }
}

1;
