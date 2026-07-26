package Market::Indicators::AnchoredVolumeProfileDavid;

# Portado desde Proyecto_David/Market/Indicators/AnchoredVolumeProfile.pm.
# Adaptaciones:
#   - Se agrega recompute($md) (contrato IndicatorManager de Kevin).
#   - BUG CORREGIDO del original: David tenia "1;" en medio del archivo
#     (linea 378) seguido de mas subs (set_row_count, set_row_mode_atr,
#     reanchor_to_latest_pivot) despues de ese "1;". En Perl eso puede
#     hacer que el modulo falle con "did not return a true value" segun
#     como se cargue -- aqui el "1;" quedo movido al final real del archivo.
# Resto del algoritmo (bins por precio, POC, Value Area, alto de bin fijo
# por ATR o por conteo de filas) es identico al original de David.

use strict;
use warnings;
use POSIX qw(floor);

use Market::Indicators::ATR;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        mode          => $args{mode}         // 'auto',
        pivot_length  => $args{pivot_length} // 50,
        atr_period    => $args{atr_period}   // 50,
        bin_atr_mult  => $args{bin_atr_mult} // 1.0,

        _c   => [],
        _atr => Market::Indicators::ATR->new( $args{atr_period} // 50 ),

        _pivots => [],

        _anchor_index => undef,
        _anchor_price => undef,
        _bin_height   => undef,

        row_mode  => $args{row_mode}  // 'atr',
        row_count => $args{row_count} // 24,

        _bins         => {},
        _poc_bin      => undef,
        _total_volume => 0,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}   = [];
    $self->{_atr} = Market::Indicators::ATR->new( $self->{atr_period} );

    $self->{_pivots} = [];

    $self->{_anchor_index} = undef;
    $self->{_anchor_price} = undef;
    $self->{_bin_height}   = undef;

    $self->{_bins}         = {};
    $self->{_poc_bin}      = undef;
    $self->{_total_volume} = 0;
}

sub get_values { return []; }

# recompute($md): contrato IndicatorManager de Kevin.
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
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_at_index( $md, $idx );

    my $reanchored = $self->_check_pivot($idx);
    $self->_accumulate_candle($idx) unless $reanchored;
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_last($md);

    my $reanchored = $self->_check_pivot($idx);
    $self->_accumulate_candle($idx) unless $reanchored;
}

sub processed_last { return $#{ $_[0]->{_c} }; }

sub set_mode {
    my ( $self, $mode ) = @_;
    return unless $mode eq 'auto' || $mode eq 'manual';
    my $was_manual = ( $self->{mode} eq 'manual' );
    $self->{mode} = $mode;

    if ( $mode eq 'auto' && $was_manual ) {
        $self->reanchor_to_latest_pivot;
    }
}
sub get_mode { return $_[0]->{mode}; }

sub set_manual_anchor {
    my ( $self, $idx ) = @_;
    return unless defined $idx;
    return if $idx < 0 || $idx > $#{ $self->{_c} };
    $self->_set_anchor($idx);
}

sub get_anchor_index { return $_[0]->{_anchor_index}; }
sub get_pivots       { return $_[0]->{_pivots}; }

sub get_profile {
    my ( $self, $va_pct ) = @_;
    $va_pct //= 0.70;
    return undef unless defined $self->{_anchor_index};
    return undef unless $self->{_bin_height} && $self->{_bin_height} > 0;

    my @bins;
    for my $b ( sort { $a <=> $b } keys %{ $self->{_bins} } ) {
        my $v = $self->{_bins}{$b};
        push @bins, {
            bin      => $b,
            price_lo => $self->{_anchor_price} + $b * $self->{_bin_height},
            price_hi => $self->{_anchor_price} + ( $b + 1 ) * $self->{_bin_height},
            buy      => $v->{buy},
            sell     => $v->{sell},
            total    => $v->{total},
            is_poc   => ( defined $self->{_poc_bin} && $b == $self->{_poc_bin} ) ? 1 : 0,
        };
    }

    my $max_total = 0;
    $max_total = $self->{_bins}{ $self->{_poc_bin} }{total}
        if defined $self->{_poc_bin} && $self->{_bins}{ $self->{_poc_bin} };

    my ( $val_price, $vah_price ) = $self->_compute_value_area($va_pct);

    return {
        anchor_index => $self->{_anchor_index},
        anchor_price => $self->{_anchor_price},
        bin_height   => $self->{_bin_height},
        bins         => \@bins,
        max_total    => $max_total,
        total_volume => $self->{_total_volume},
        val_price    => $val_price,
        vah_price    => $vah_price,
    };
}

sub _compute_value_area {
    my ( $self, $va_pct ) = @_;
    return ( undef, undef ) unless defined $self->{_poc_bin};

    my @all_bins = sort { $a <=> $b } keys %{ $self->{_bins} };
    return ( undef, undef ) unless @all_bins;

    my $total = 0;
    $total += $self->{_bins}{$_}{total} for @all_bins;
    return ( undef, undef ) if $total <= 0;

    my $target = $total * $va_pct;

    my $lo  = $self->{_poc_bin};
    my $hi  = $self->{_poc_bin};
    my $acc = $self->{_bins}{ $self->{_poc_bin} }{total} // 0;

    my %exists = map { $_ => 1 } @all_bins;

    while ( $acc < $target ) {
        my $next_hi = $hi + 1;
        my $next_lo = $lo - 1;
        my $vol_hi  = $exists{$next_hi} ? $self->{_bins}{$next_hi}{total} : undef;
        my $vol_lo  = $exists{$next_lo} ? $self->{_bins}{$next_lo}{total} : undef;

        last unless defined $vol_hi || defined $vol_lo;

        if ( defined $vol_hi && defined $vol_lo ) {
            if ( $vol_hi >= $vol_lo ) { $hi = $next_hi; $acc += $vol_hi; }
            else                       { $lo = $next_lo; $acc += $vol_lo; }
        } elsif ( defined $vol_hi ) {
            $hi = $next_hi; $acc += $vol_hi;
        } else {
            $lo = $next_lo; $acc += $vol_lo;
        }
    }

    my $val_price = $self->{_anchor_price} + $lo * $self->{_bin_height};
    my $vah_price = $self->{_anchor_price} + ( $hi + 1 ) * $self->{_bin_height};

    return ( $val_price, $vah_price );
}

sub _check_pivot {
    my ( $self, $idx ) = @_;
    my $L = $self->{pivot_length};
    return 0 if $idx < 2 * $L;

    my $cand = $idx - $L;
    my $c    = $self->{_c};

    my ( $max_h, $min_l );
    for my $i ( ( $idx - 2 * $L ) .. $idx ) {
        my $cc = $c->[$i];
        next unless defined $cc;
        $max_h = $cc->{high} if !defined($max_h) || $cc->{high} > $max_h;
        $min_l = $cc->{low}  if !defined($min_l) || $cc->{low}  < $min_l;
    }
    return 0 unless defined $max_h && defined $min_l;

    my $reanchored = 0;
    my $cand_c = $c->[$cand];
    return 0 unless defined $cand_c;

    if ( $cand_c->{high} == $max_h ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $max_h, type => 'high' };
        if ( $self->{mode} eq 'auto'
            && ( !defined $self->{_anchor_index} || $cand > $self->{_anchor_index} ) )
        {
            $self->_set_anchor($cand);
            $reanchored = 1;
        }
    }
    if ( $cand_c->{low} == $min_l ) {
        push @{ $self->{_pivots} }, { index => $cand, price => $min_l, type => 'low' };
        if ( $self->{mode} eq 'auto'
            && ( !defined $self->{_anchor_index} || $cand > $self->{_anchor_index} ) )
        {
            $self->_set_anchor($cand);
            $reanchored = 1;
        }
    }
    return $reanchored;
}

sub _set_anchor {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];
    return unless defined $c;

    $self->{_anchor_index} = $idx;
    $self->{_anchor_price} = $c->{close};

    if ( $self->{row_mode} eq 'fixed_count' ) {
        my $last = $#{ $self->{_c} };
        my ( $range_max, $range_min );
        for my $i ( $idx .. $last ) {
            my $cc = $self->{_c}[$i];
            next unless defined $cc;
            $range_max = $cc->{high} if !defined($range_max) || $cc->{high} > $range_max;
            $range_min = $cc->{low}  if !defined($range_min) || $cc->{low}  < $range_min;
        }
        $range_max //= $c->{high};
        $range_min //= $c->{low};
        my $range = $range_max - $range_min;
        $range = 0.01 if $range <= 0;

        $self->{_bin_height} = $range / $self->{row_count};
    } else {
        my $atr_vals = $self->{_atr}{values};
        my $atr = $atr_vals->[$idx];
        if ( !defined $atr ) {
            for ( my $i = $idx; $i >= 0; $i-- ) {
                if ( defined $atr_vals->[$i] ) { $atr = $atr_vals->[$i]; last; }
            }
        }
        $atr //= 0;
        $self->{_bin_height} = $atr * $self->{bin_atr_mult};
    }

    $self->{_bin_height} = 0.01 if !$self->{_bin_height} || $self->{_bin_height} <= 0;

    $self->{_bins}         = {};
    $self->{_poc_bin}      = undef;
    $self->{_total_volume} = 0;

    my $last = $#{ $self->{_c} };
    for my $i ( $idx .. $last ) {
        $self->_accumulate_candle($i);
    }
}

sub _accumulate_candle {
    my ( $self, $idx ) = @_;
    return unless defined $self->{_anchor_index} && $idx >= $self->{_anchor_index};

    my $c = $self->{_c}[$idx];
    return unless defined $c;

    my $bh = $self->{_bin_height};
    return unless $bh && $bh > 0;

    my $vol = $c->{volume} // 0;
    return if $vol <= 0;

    my $is_buy = ( $c->{close} >= $c->{open} ) ? 1 : 0;

    my $lo_bin = floor( ( $c->{low}  - $self->{_anchor_price} ) / $bh );
    my $hi_bin = floor( ( $c->{high} - $self->{_anchor_price} ) / $bh );
    ( $lo_bin, $hi_bin ) = ( $hi_bin, $lo_bin ) if $lo_bin > $hi_bin;

    my $n_bins      = $hi_bin - $lo_bin + 1;
    my $vol_per_bin = $vol / $n_bins;

    for my $b ( $lo_bin .. $hi_bin ) {
        my $slot = ( $self->{_bins}{$b} //= { buy => 0, sell => 0, total => 0 } );
        if ($is_buy) { $slot->{buy}  += $vol_per_bin; }
        else         { $slot->{sell} += $vol_per_bin; }
        $slot->{total} += $vol_per_bin;
    }
    $self->{_total_volume} += $vol;

    my $poc_bin = undef;
    my $poc_tot = -1;
    for my $b ( keys %{ $self->{_bins} } ) {
        my $t = $self->{_bins}{$b}{total};
        if ( $t > $poc_tot ) {
            $poc_tot = $t;
            $poc_bin = $b;
        }
    }
    $self->{_poc_bin} = $poc_bin;
}

sub set_row_count {
    my ( $self, $n ) = @_;
    return unless $n && $n > 0;
    $self->{row_mode}  = 'fixed_count';
    $self->{row_count} = int($n);
    $self->_set_anchor( $self->{_anchor_index} ) if defined $self->{_anchor_index};
}

sub set_row_mode_atr {
    my ( $self, $mult ) = @_;
    $self->{row_mode} = 'atr';
    $self->{bin_atr_mult} = $mult if $mult && $mult > 0;
    $self->_set_anchor( $self->{_anchor_index} ) if defined $self->{_anchor_index};
}

sub reanchor_to_latest_pivot {
    my ($self) = @_;
    return unless @{ $self->{_pivots} };
    my $latest = $self->{_pivots}[-1];
    $self->_set_anchor( $latest->{index} );
}

1;
