package Market::Indicators::ZigZagVolumeProfile;

use strict;
use warnings;

# =============================================================================
# Market::Indicators::ZigZagVolumeProfile (ZZVP)
#
# Motor de direccion EXTERNA macro (logica de Nuevos archivos/).
# Máquina de estados + desviación porcentual; perfiles de volumen al cerrar
# cada segmento institucional.
# =============================================================================

use constant DEFAULT_DEVIATION_PCT => 1;
use constant DEFAULT_BINS          => 10;
use constant DEFAULT_MAX_PROFILES  => 15;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        deviation_pct => $args{deviation_pct} // DEFAULT_DEVIATION_PCT(),
        bins          => $args{bins}          // DEFAULT_BINS(),
        max_profiles  => $args{max_profiles}  // DEFAULT_MAX_PROFILES(),

        _c => [],
        _pivots  => [],
        _next_id => 1,
        _segments => [],
        _profiles => [],

        _state        => 'INIT',
        _last_extreme => undef,
        _extreme_idx  => -1,
        _last_index   => -1,
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}         = [];
    $self->{_pivots}    = [];
    $self->{_next_id}   = 1;
    $self->{_segments}  = [];
    $self->{_profiles}  = [];
    $self->{_state}        = 'INIT';
    $self->{_last_extreme} = undef;
    $self->{_extreme_idx}  = -1;
    $self->{_last_index}   = -1;
    return $self;
}

sub last_index { return $_[0]->{_last_index}; }

sub update_at_index {
    my ( $self, $md_or_candle, $idx ) = @_;
    my $c = _resolve_candle( $md_or_candle, $idx );
    return $self unless $c;
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
    $self->{_last_index} = $idx;
    return $self;
}

sub sync_to_index {
    my ( $self, $market_data, $target_index ) = @_;
    return $self unless $market_data && $market_data->can('get_candle');
    return $self unless defined $target_index && $target_index >= 0;

    if ( $self->{_last_index} > $target_index ) {
        $self->reset();
    }

    my $from = $self->{_last_index} + 1;
    $from = 0 if $from < 0;

    for my $i ( $from .. $target_index ) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        $self->update_at_index( $c, $i );
    }
    return $self;
}

sub get_pivots   { return [ map { +{%$_} } @{ $_[0]->{_pivots} || [] } ]; }
sub get_segments { return [ map { +{%$_} } @{ $_[0]->{_segments} || [] } ]; }
sub get_profiles { return [ map { +{%$_} } @{ $_[0]->{_profiles} || [] } ]; }

sub pivots_as_swings {
    my ($self) = @_;
    return [
        map {
            +{
                index => $_->{index},
                price => $_->{price},
                kind  => $_->{kind},
                type  => $_->{kind} eq 'H' ? 'swing_high' : 'swing_low',
            }
        } @{ $self->{_pivots} || [] }
    ];
}

sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless $pivots && @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_base_idx = $self->{_last_index};
    return undef unless defined $last_base_idx && $last_base_idx >= 0;
    return undef if $last_base_idx <= $last_pivot->{index};

    my $c = $self->{_c};
    my ( $extreme_price, $extreme_idx );

    for my $i ( $last_pivot->{index} + 1 .. $last_base_idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;

        if ( $last_pivot->{kind} eq 'L' ) {
            if ( !defined($extreme_price) || $candle->{high} > $extreme_price ) {
                $extreme_price = $candle->{high};
                $extreme_idx   = $i;
            }
        }
        else {
            if ( !defined($extreme_price) || $candle->{low} < $extreme_price ) {
                $extreme_price = $candle->{low};
                $extreme_idx   = $i;
            }
        }
    }

    return undef unless defined $extreme_price;
    return {
        from_index => $last_pivot->{index},
        to_index   => $extreme_idx,
        from_price => $last_pivot->{price},
        to_price   => $extreme_price,
        dir        => ( $extreme_price > $last_pivot->{price} ) ? 'up' : 'down',
    };
}

sub _resolve_candle {
    my ( $md_or_candle, $idx ) = @_;
    return undef unless defined $idx && $idx >= 0;

    if ( $md_or_candle && ref $md_or_candle eq 'HASH' && defined $md_or_candle->{open} ) {
        return $md_or_candle;
    }
    if ( $md_or_candle && $md_or_candle->can('get_candle') ) {
        return $md_or_candle->get_candle($idx);
    }
    return undef;
}

sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];

    if ( $self->{_state} eq 'INIT' ) {
        $self->{_state} = 'BUSCANDO_MAXIMO';
        $self->{_last_extreme} = $c->{high};
        $self->{_extreme_idx}  = $idx;
        $self->_consolidate( $idx, 'L', $c->{low} );
        return;
    }

    my $dev = $self->{deviation_pct} / 100.0;

    if ( $self->{_state} eq 'BUSCANDO_MAXIMO' ) {
        my $made_new_high = ( $c->{high} > $self->{_last_extreme} );
        my $triggered_reversal = 0;

        my $eval_high = $made_new_high ? $c->{high} : $self->{_last_extreme};

        if ( ( $eval_high - $c->{low} ) / $eval_high >= $dev ) {
            $triggered_reversal = 1;
        }

        if ( $made_new_high && $triggered_reversal ) {
            if ( $c->{open} > $c->{close} ) {
                $self->_consolidate( $idx, 'H', $c->{high} );
                $self->{_state} = 'BUSCANDO_MINIMO';
                $self->{_last_extreme} = $c->{low};
                $self->{_extreme_idx}  = $idx;
            }
            elsif ( $c->{high} >= $self->{_last_extreme} ) {
                $self->{_last_extreme} = $c->{high};
                $self->{_extreme_idx}  = $idx;
            }
        }
        elsif ($made_new_high) {
            $self->{_last_extreme} = $c->{high};
            $self->{_extreme_idx}  = $idx;
        }
        elsif ($triggered_reversal) {
            $self->_consolidate( $self->{_extreme_idx}, 'H', $self->{_last_extreme} );
            $self->{_state} = 'BUSCANDO_MINIMO';
            $self->{_last_extreme} = $c->{low};
            $self->{_extreme_idx}  = $idx;
        }
    }
    elsif ( $self->{_state} eq 'BUSCANDO_MINIMO' ) {
        my $made_new_low = ( $c->{low} < $self->{_last_extreme} );
        my $triggered_reversal = 0;

        my $eval_low = $made_new_low ? $c->{low} : $self->{_last_extreme};

        if ( ( $c->{high} - $eval_low ) / $eval_low >= $dev ) {
            $triggered_reversal = 1;
        }

        if ( $made_new_low && $triggered_reversal ) {
            if ( $c->{open} < $c->{close} ) {
                $self->_consolidate( $idx, 'L', $c->{low} );
                $self->{_state} = 'BUSCANDO_MAXIMO';
                $self->{_last_extreme} = $c->{high};
                $self->{_extreme_idx}  = $idx;
            }
            elsif ( $c->{low} <= $self->{_last_extreme} ) {
                $self->{_last_extreme} = $c->{low};
                $self->{_extreme_idx}  = $idx;
            }
        }
        elsif ($made_new_low) {
            $self->{_last_extreme} = $c->{low};
            $self->{_extreme_idx}  = $idx;
        }
        elsif ($triggered_reversal) {
            $self->_consolidate( $self->{_extreme_idx}, 'L', $self->{_last_extreme} );
            $self->{_state} = 'BUSCANDO_MAXIMO';
            $self->{_last_extreme} = $c->{high};
            $self->{_extreme_idx}  = $idx;
        }
    }
}

sub _consolidate {
    my ( $self, $index, $kind, $price ) = @_;
    my $pivots = $self->{_pivots};
    my $last   = @$pivots ? $pivots->[-1] : undef;

    return if defined $last && $last->{kind} eq $kind;

    my $pivot = { id => $self->{_next_id}++, index => $index, kind => $kind, price => $price };
    push @$pivots, $pivot;

    if ( defined $last ) {
        $self->_add_segment_and_profile( $last, $pivot );
    }
}

sub _add_segment_and_profile {
    my ( $self, $prev, $cur ) = @_;
    push @{ $self->{_segments} }, {
        from_index => $prev->{index},
        to_index   => $cur->{index},
        from_price => $prev->{price},
        to_price   => $cur->{price},
        dir        => ( $cur->{price} > $prev->{price} ) ? 'up' : 'down',
    };

    push @{ $self->{_profiles} }, $self->_build_profile( $prev, $cur );

    my $max = $self->{max_profiles};
    if ( @{ $self->{_profiles} } > $max ) {
        shift @{ $self->{_profiles} };
    }
}

sub _build_profile {
    my ( $self, $prev, $cur ) = @_;
    my $idx_from = $prev->{index} < $cur->{index} ? $prev->{index} : $cur->{index};
    my $idx_to   = $prev->{index} < $cur->{index} ? $cur->{index}  : $prev->{index};

    my $price_lo = $prev->{price} < $cur->{price} ? $prev->{price} : $cur->{price};
    my $price_hi = $prev->{price} < $cur->{price} ? $cur->{price}  : $prev->{price};

    my $n_bins = $self->{bins};
    my $range  = $price_hi - $price_lo;
    $range = 1e-9 if $range <= 0;
    my $bin_size = $range / $n_bins;

    my @bins = map {
        { low => $price_lo + $_ * $bin_size, high => $price_lo + ( $_ + 1 ) * $bin_size, volume => 0 }
    } ( 0 .. $n_bins - 1 );

    my $c = $self->{_c};
    for my $i ( $idx_from .. $idx_to ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        my $vol = $candle->{volume} // 0;
        next if $vol <= 0;

        my $lo = $candle->{low}  < $price_lo ? $price_lo : $candle->{low};
        my $hi = $candle->{high} > $price_hi ? $price_hi : $candle->{high};
        next if $hi <= $lo;

        my $candle_range = $candle->{high} - $candle->{low};
        $candle_range = 1e-9 if $candle_range <= 0;

        for my $b (@bins) {
            my $overlap_lo = $lo > $b->{low}  ? $lo : $b->{low};
            my $overlap_hi = $hi < $b->{high} ? $hi : $b->{high};
            next if $overlap_hi <= $overlap_lo;

            my $fraction = ( $overlap_hi - $overlap_lo ) / $candle_range;
            $b->{volume} += $vol * $fraction;
        }
    }

    my $poc = $bins[0];
    for my $b (@bins) {
        $poc = $b if $b->{volume} > $poc->{volume};
    }

    return {
        idx_from   => $idx_from,
        idx_to     => $idx_to,
        price_from => $prev->{price},
        price_to   => $cur->{price},
        bins       => \@bins,
        poc_price  => ( $poc->{low} + $poc->{high} ) / 2,
        poc_volume => $poc->{volume},
    };
}

1;
