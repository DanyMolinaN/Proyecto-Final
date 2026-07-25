package Market::Indicators::ZigZagVP2David;

# =============================================================================
# Market::Indicators::ZigZagVP2David
#
# Portado desde Proyecto_David/Market/Indicators/ZigZagVolumeProfile2.pm
# Adaptaciones para Kevin:
#   - Package renombrado a ZigZagVP2David (evita colision de namespace).
#   - Se agrega recompute($md) para compatibilidad con IndicatorManager::rebuild_all().
#   - Todo lo demas es identico al original de David.
# =============================================================================

use strict;
use warnings;

use Market::Indicators::ATR;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        swing_length         => $args{swing_length}         // 150,
        channel_width_factor => $args{channel_width_factor} // 1,
        atr_period           => $args{atr_period}           // 200,
        volume_bin_count     => $args{volume_bin_count}     // 5,
        max_profiles         => $args{max_profiles}         // 15,

        _c   => [],
        _atr => Market::Indicators::ATR->new( $args{atr_period} // 200 ),

        _segments => [],
        _profiles => [],

        _is_bullish       => undef,
        _prev_is_bullish  => undef,
        _bar_index_low    => undef,
        _price_low        => undef,
        _bar_index_high   => undef,
        _price_high       => undef,
        _prev_price_high  => undef,
        _prev_price_low   => undef,

        _open_segment => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}         = [];
    $self->{_atr}       = Market::Indicators::ATR->new( $self->{atr_period} );
    $self->{_segments}  = [];
    $self->{_profiles}  = [];

    $self->{_is_bullish}      = undef;
    $self->{_prev_is_bullish} = undef;
    $self->{_bar_index_low}   = undef;
    $self->{_price_low}       = undef;
    $self->{_bar_index_high}  = undef;
    $self->{_price_high}      = undef;
    $self->{_prev_price_high} = undef;
    $self->{_prev_price_low}  = undef;
    $self->{_open_segment}    = undef;
    $self->{_swing_hi}        = undef;
    $self->{_swing_lo}        = undef;
    delete $self->{_kevin_computed_fp};
}

# recompute($md): contrato de IndicatorManager::rebuild_all() de Kevin.
# Itera update_at_index sobre todas las velas del MarketData.
sub recompute {
    my ( $self, $md ) = @_;
    return unless $md;
    $self->reset();
    my $size = $md->size // 0;
    # Precargar velas + extremos rolling O(n) (antes O(n * swing_length)).
    for my $idx ( 0 .. $size - 1 ) {
        my $c = $md->get_candle($idx);
        next unless defined $c;
        $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
        $self->{_c}[$idx] = $c;
        $self->{_atr}->update_at_index( $md, $idx );
    }
    $self->_precompute_swing_extremes($size);
    for my $idx ( 0 .. $size - 1 ) {
        next unless defined $self->{_c}[$idx];
        $self->_process_candle($idx);
    }
    my $tf = $md->can('active_tf') ? ($md->active_tf() // '') : '';
    $self->{_kevin_computed_fp} = "$tf|$size";
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_at_index( $md, $idx );
    # Invalidar cache rolling si se actualiza fuera de recompute
    $self->{_swing_hi} = undef;
    $self->{_swing_lo} = undef;
    $self->_process_candle($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_last($md);
    $self->{_swing_hi} = undef;
    $self->{_swing_lo} = undef;
    $self->_process_candle($idx);
    if ($md->can('size')) {
        my $tf = $md->can('active_tf') ? ($md->active_tf() // '') : '';
        $self->{_kevin_computed_fp} = "$tf|" . ($md->size // 0);
    }
}

sub get_segments         { return $_[0]->{_segments}; }
sub get_profiles         { return $_[0]->{_profiles}; }
sub get_tentative_segment { return $_[0]->{_open_segment}; }

sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c  = $self->{_c}[$idx];
    my $sl = $self->{swing_length};

    my ( $swing_high, $swing_low ) = $self->_swing_extremes($idx);
    return unless defined $swing_high && defined $swing_low;

    my ( $prev_swing_high, $prev_swing_low ) = $idx > 0
        ? $self->_swing_extremes( $idx - 1 )
        : ( undef, undef );

    $self->{_prev_is_bullish} = $self->{_is_bullish};
    if ( $swing_high == $c->{high} ) {
        $self->{_is_bullish} = 1;
    }
    if ( $swing_low == $c->{low} ) {
        $self->{_is_bullish} = 0;
    }

    if ( $idx > 0 ) {
        my $c_prev = $self->{_c}[ $idx - 1 ];
        if ( defined $prev_swing_high
            && $c_prev->{high} == $prev_swing_high
            && $c->{high} < $swing_high )
        {
            $self->{_bar_index_high} = $idx - 1;
            $self->{_price_high}     = $c_prev->{low};
        }
        if ( defined $prev_swing_low
            && $c_prev->{low} == $prev_swing_low
            && $c->{low} > $swing_low )
        {
            $self->{_bar_index_low} = $idx - 1;
            $self->{_price_low}     = $c_prev->{low};
        }
    }

    return unless defined $self->{_bar_index_high} && defined $self->{_bar_index_low};

    my $ib      = $self->{_is_bullish};
    my $ib_prev = $self->{_prev_is_bullish};
    my $changed = defined($ib) && ( !defined($ib_prev) || $ib != $ib_prev );

    if ( $changed && $ib ) {
        $self->_open_new_segment(
            $self->{_bar_index_low}, $self->{_price_low},
            $self->{_bar_index_high}, $self->{_price_high},
        );
        $self->_draw_profile_segment(
            $self->{_bar_index_high}, $self->{_price_high},
            $self->{_bar_index_low},  $self->{_price_low},
            0,
        );
    }
    if ( $ib && defined( $self->{_prev_price_high} )
        && $self->{_price_high} != $self->{_prev_price_high} )
    {
        $self->_update_open_segment( $self->{_bar_index_high}, $self->{_price_high} );
    }

    if ( $changed && !$ib ) {
        $self->_open_new_segment(
            $self->{_bar_index_high}, $self->{_price_high},
            $self->{_bar_index_low}, $self->{_price_low},
        );
        $self->_draw_profile_segment(
            $self->{_bar_index_low}, $self->{_price_low},
            $self->{_bar_index_high}, $self->{_price_high},
            1,
        );
    }
    if ( defined($ib) && !$ib && defined( $self->{_prev_price_low} )
        && $self->{_price_low} != $self->{_prev_price_low} )
    {
        $self->_update_open_segment( $self->{_bar_index_low}, $self->{_price_low} );
    }

    $self->{_prev_price_high} = $self->{_price_high};
    $self->{_prev_price_low}  = $self->{_price_low};
}

sub _swing_extremes {
    my ( $self, $idx ) = @_;
    if ($self->{_swing_hi} && defined $self->{_swing_hi}[$idx]
        && $self->{_swing_lo} && defined $self->{_swing_lo}[$idx])
    {
        return ( $self->{_swing_hi}[$idx], $self->{_swing_lo}[$idx] );
    }

    my $sl = $self->{swing_length};
    my $from = $idx - $sl + 1;
    $from = 0 if $from < 0;

    my $c = $self->{_c};
    my ( $hi, $lo );
    for my $i ( $from .. $idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $hi = $candle->{high} if !defined($hi) || $candle->{high} > $hi;
        $lo = $candle->{low}  if !defined($lo) || $candle->{low}  < $lo;
    }
    return ( $hi, $lo );
}

# Rolling max/min O(n) con deques monotónicas (ventana = swing_length).
sub _precompute_swing_extremes {
    my ( $self, $size ) = @_;
    my $sl = $self->{swing_length} || 1;
    my $c  = $self->{_c};
    my @hi = (undef) x $size;
    my @lo = (undef) x $size;
    my @dq_hi;  # indices, highs desc
    my @dq_lo;  # indices, lows asc

    for my $i ( 0 .. $size - 1 ) {
        my $candle = $c->[$i];
        unless (defined $candle) {
            $hi[$i] = $i > 0 ? $hi[$i - 1] : undef;
            $lo[$i] = $i > 0 ? $lo[$i - 1] : undef;
            next;
        }
        my $from = $i - $sl + 1;
        $from = 0 if $from < 0;

        while (@dq_hi && $dq_hi[0] < $from) { shift @dq_hi; }
        while (@dq_lo && $dq_lo[0] < $from) { shift @dq_lo; }

        while (@dq_hi && defined $c->[$dq_hi[-1]]
            && $c->[$dq_hi[-1]]{high} <= $candle->{high})
        {
            pop @dq_hi;
        }
        while (@dq_lo && defined $c->[$dq_lo[-1]]
            && $c->[$dq_lo[-1]]{low} >= $candle->{low})
        {
            pop @dq_lo;
        }
        push @dq_hi, $i;
        push @dq_lo, $i;

        $hi[$i] = $c->[$dq_hi[0]]{high};
        $lo[$i] = $c->[$dq_lo[0]]{low};
    }
    $self->{_swing_hi} = \@hi;
    $self->{_swing_lo} = \@lo;
}

sub _open_new_segment {
    my ( $self, $from_idx, $from_price, $to_idx, $to_price ) = @_;
    $self->{_open_segment} = {
        from_index => $from_idx,
        from_price => $from_price,
        to_index   => $to_idx,
        to_price   => $to_price,
        dir        => ( $to_price > $from_price ) ? 'up' : 'down',
    };
    push @{ $self->{_segments} }, $self->{_open_segment};
}

sub _update_open_segment {
    my ( $self, $to_idx, $to_price ) = @_;
    return unless $self->{_open_segment};
    $self->{_open_segment}{to_index} = $to_idx;
    $self->{_open_segment}{to_price} = $to_price;
    $self->{_open_segment}{dir} =
        ( $to_price > $self->{_open_segment}{from_price} ) ? 'up' : 'down';
}

sub _draw_profile_segment {
    my ( $self, $start_idx, $start_price, $end_idx, $end_price, $direction ) = @_;

    my $atr_vals = $self->{_atr}{values};
    my $atr      = $atr_vals->[$end_idx] // $atr_vals->[-1] // 0;
    my $atr_range = $atr * $self->{channel_width_factor};

    my $n       = $self->{volume_bin_count};
    my $c       = $self->{_c};
    my $range_  = $end_idx - $start_idx;
    return if $range_ == 0;

    my @bins;
    my $total_volume = 0;

    for ( my $i = $n; $i >= -$n; $i-- ) {
        my $offset = $atr_range * $i;
        my $y_start = $start_price + $offset;
        my $y_end   = $end_price + $offset;
        my $slope   = ( $y_start - $y_end ) / ( $end_idx - $start_idx );

        my $vol_at_level = 0;
        my ( $lo_idx, $hi_idx ) = $start_idx < $end_idx
            ? ( $start_idx, $end_idx ) : ( $end_idx, $start_idx );

        for my $bar_i ( $lo_idx .. $hi_idx ) {
            my $candle = $c->[$bar_i];
            next unless defined $candle;
            my $k = $end_idx - $bar_i;
            my $level = $end_price + $offset + $slope * $k;
            if ( $candle->{high} > $level && $candle->{low} < $level ) {
                $vol_at_level += ( $candle->{volume} // 0 );
            }
        }

        push @bins, {
            i       => $i,
            offset  => $offset,
            slope   => $slope,
            volume  => $vol_at_level,
        };
        $total_volume += $vol_at_level;
    }

    my $max_vol = 0;
    for my $b (@bins) { $max_vol = $b->{volume} if $b->{volume} > $max_vol; }

    for my $b (@bins) {
        my $vol_pct = $total_volume > 0 ? ( $b->{volume} / $total_volume * 100 ) : 0;
        $b->{volume_pct} = $vol_pct;
        $b->{is_poc}     = ( $max_vol > 0 && $b->{volume} == $max_vol ) ? 1 : 0;
    }

    push @{ $self->{_profiles} }, {
        idx_from    => $start_idx,
        idx_to      => $end_idx,
        price_from  => $start_price,
        price_to    => $end_price,
        direction   => $direction,
        atr_range   => $atr_range,
        bins        => \@bins,
        max_volume  => $max_vol,
        total_volume => $total_volume,
    };

    my $max = $self->{max_profiles};
    if ( @{ $self->{_profiles} } > $max ) {
        shift @{ $self->{_profiles} };
    }
}

1;
