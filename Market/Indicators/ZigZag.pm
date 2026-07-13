package Market::Indicators::ZigZag;

use strict;
use warnings;

# =============================================================================
# Motor ZigZag incremental (estilo LonesomeTheBlue / TradingView):
#   ph = ta.highestbars(high, period) == 0 ? high : na
#   pl = ta.lowestbars(low, period)  == 0 ? low  : na
#   dir := ph && !pl ? 1 : pl && !ph ? -1 : dir
#   dirchanged -> add pivot | else -> update pivot (reemplazar si mas extremo)
#
# Estado persistente: update_at_index() por vela. compute() es wrapper batch.
# =============================================================================

# Motor base highestbars/lowestbars (tests / utilidades).
# Internal: Market::Indicators::ZigZagMTF (30m, period 2).
# External: Market::Indicators::ZigZagVolumeProfile (deviation_pct).
use constant INTERNAL_PIVOT_LENGTH => 5;

sub pivot_length_for {
    my ($profile) = @_;
    return INTERNAL_PIVOT_LENGTH if ($profile || '') eq 'internal';
    return INTERNAL_PIVOT_LENGTH;
}

sub new {
    my ( $class, %args ) = @_;
    my $period = $args{pivot_length} // $args{period} // INTERNAL_PIVOT_LENGTH;
    $period = 2 if $period < 2;
    my $self = {
        period     => $period,
        _c         => [],
        _pivots    => [],
        _dir       => 0,
        _prev_dir  => 0,
        _last_index => -1,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}          = [];
    $self->{_pivots}     = [];
    $self->{_dir}        = 0;
    $self->{_prev_dir}   = 0;
    $self->{_last_index} = -1;
    return $self;
}

sub period       { return $_[0]->{period}; }
sub last_index   { return $_[0]->{_last_index}; }
sub get_pivots   { return [ map { +{%$_} } @{ $_[0]->{_pivots} || [] } ]; }

sub update_at_index {
    my ( $self, $candle, $idx ) = @_;
    return unless $candle && ref $candle eq 'HASH';
    return unless defined $idx && $idx >= 0;

    $self->{_c}[$idx] = $candle;
    $self->_process_bar($idx);
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

sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless $pivots && @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_idx   = $self->{_last_index};
    return undef unless defined $last_idx && $last_idx > $last_pivot->{index};

    my ( $extreme_price, $extreme_idx );
    if ( $last_pivot->{kind} eq 'L' ) {
        for my $i ( $last_pivot->{index} + 1 .. $last_idx ) {
            my $c = $self->{_c}[$i];
            next unless $c && defined $c->{high};
            if ( !defined $extreme_price || $c->{high} > $extreme_price ) {
                $extreme_price = $c->{high};
                $extreme_idx   = $i;
            }
        }
    }
    else {
        for my $i ( $last_pivot->{index} + 1 .. $last_idx ) {
            my $c = $self->{_c}[$i];
            next unless $c && defined $c->{low};
            if ( !defined $extreme_price || $c->{low} < $extreme_price ) {
                $extreme_price = $c->{low};
                $extreme_idx   = $i;
            }
        }
    }

    return undef unless defined $extreme_price && defined $extreme_idx;
    return {
        from_index => $last_pivot->{index},
        to_index   => $extreme_idx,
        from_price => $last_pivot->{price},
        to_price   => $extreme_price,
        dir        => ( $extreme_price > $last_pivot->{price} ) ? 'up' : 'down',
    };
}

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

# compute($candles) -> \@pivots  (batch, para tests)
sub compute {
    my ( $candles, %args ) = @_;
    my $period = $args{pivot_length} // $args{period} // INTERNAL_PIVOT_LENGTH;
    my $engine = __PACKAGE__->new( pivot_length => $period );
    return [] unless $candles && ref $candles eq 'ARRAY' && @$candles;

    for my $i ( 0 .. $#$candles ) {
        my $c = $candles->[$i];
        next unless $c;
        $engine->update_at_index( $c, $i );
    }
    return $engine->pivots_as_swings();
}

sub _process_bar {
    my ( $self, $i ) = @_;
    my $c      = $self->{_c}[$i];
    my $period = $self->{period};

    my $ph = _is_highest_bar( $self->{_c}, $i, $period );
    my $pl = _is_lowest_bar( $self->{_c}, $i, $period );

    if ( $ph && !$pl ) {
        $self->{_dir} = 1;
    }
    elsif ( $pl && !$ph ) {
        $self->{_dir} = -1;
    }

    return unless $ph || $pl;
    my $dir = $self->{_dir};
    return unless $dir == 1 || $dir == -1;

    my $value = $dir == 1 ? $c->{high} : $c->{low};
    return unless defined $value;

    my $dir_changed = ( $dir != $self->{_prev_dir} );
    my $pivots      = $self->{_pivots};

    if ( !@$pivots || $dir_changed ) {
        _add_pivot( $pivots, $i, $value, $dir );
    }
    else {
        _update_pivot( $pivots, $i, $value, $dir );
    }

    $self->{_prev_dir} = $dir;
    return;
}

sub _is_highest_bar {
    my ( $candles, $i, $period ) = @_;
    return 0 if $i < $period - 1;

    my $hi = $candles->[$i]{high};
    return 0 unless defined $hi;

    for my $j ( $i - $period + 1 .. $i - 1 ) {
        my $other = $candles->[$j]{high};
        return 0 unless defined $other;
        return 0 if $other > $hi;
    }
    return 1;
}

sub _is_lowest_bar {
    my ( $candles, $i, $period ) = @_;
    return 0 if $i < $period - 1;

    my $lo = $candles->[$i]{low};
    return 0 unless defined $lo;

    for my $j ( $i - $period + 1 .. $i - 1 ) {
        my $other = $candles->[$j]{low};
        return 0 unless defined $other;
        return 0 if $other < $lo;
    }
    return 1;
}

sub _add_pivot {
    my ( $pivots, $index, $price, $dir ) = @_;
    push @$pivots, {
        index => $index,
        price => $price,
        kind  => $dir == 1 ? 'H' : 'L',
    };
    return;
}

sub _update_pivot {
    my ( $pivots, $index, $price, $dir ) = @_;
    return unless @$pivots;

    my $last = $pivots->[-1];
    if ( $dir == 1 && $price > $last->{price} ) {
        $last->{price} = $price;
        $last->{index} = $index;
        $last->{kind}  = 'H';
    }
    elsif ( $dir == -1 && $price < $last->{price} ) {
        $last->{price} = $price;
        $last->{index} = $index;
        $last->{kind}  = 'L';
    }
    return;
}

1;
