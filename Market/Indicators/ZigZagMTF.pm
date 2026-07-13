package Market::Indicators::ZigZagMTF;

use strict;
use warnings;

# =============================================================================
# Market::Indicators::ZigZagMTF
#
# ZigZag Multi Time Frame — direccion INTERNA (logica de Nuevos archivos/).
# Remuestrea velas base a bloques OHLC de resolution_minutes y corre zigzag
# clasico por periodo (ta.pivothigh / ta.pivotlow) sobre bloques cerrados.
# =============================================================================

use constant DEFAULT_RESOLUTION_MINUTES => 30;
use constant DEFAULT_PERIOD               => 2;

sub new {
    my ( $class, %args ) = @_;
    my $period = $args{period} // DEFAULT_PERIOD();
    $period = 2 if $period < 2;
    my $self = {
        resolution_minutes => $args{resolution_minutes} // DEFAULT_RESOLUTION_MINUTES(),
        period             => $period,

        _c => [],

        _current_bucket => undef,
        _agg            => [],
        _pivots         => [],
        _next_id        => 1,
        _segments       => [],
        _last_index     => -1,
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}              = [];
    $self->{_current_bucket} = undef;
    $self->{_agg}            = [];
    $self->{_pivots}         = [];
    $self->{_next_id}        = 1;
    $self->{_segments}       = [];
    $self->{_last_index}     = -1;
    return $self;
}

sub period     { return $_[0]->{period}; }
sub last_index { return $_[0]->{_last_index}; }

sub update_at_index {
    my ( $self, $md_or_candle, $idx ) = @_;
    my $c = _resolve_candle( $md_or_candle, $idx );
    return $self unless $c;
    $self->_ingest( $idx, $c );
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

sub get_swings {
    my ($self) = @_;
    my @out;
    for my $p ( @{ $self->{_pivots} } ) {
        push @out, {
            id    => $p->{id},
            index => $self->_base_index_for_pivot($p),
            kind  => $p->{kind},
            price => $p->{price},
        };
    }
    return \@out;
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
        } @{ $self->get_swings() }
    ];
}

sub get_trendline {
    my ($self) = @_;
    my @out;
    for my $p ( @{ $self->{_pivots} } ) {
        push @out, {
            index => $self->_base_index_for_pivot($p),
            price => $p->{price},
        };
    }
    return \@out;
}

sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless $pivots && @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_pivot_base_idx = $self->_base_index_for_pivot($last_pivot);

    my $last_base_idx = $self->{_last_index};
    return undef unless defined $last_base_idx && $last_base_idx >= 0;
    return undef if $last_base_idx <= $last_pivot_base_idx;

    my $last_candle = $self->{_c}[$last_base_idx];
    return undef unless defined $last_candle;

    return {
        from_index => $last_pivot_base_idx,
        to_index   => $last_base_idx,
        from_price => $last_pivot->{price},
        to_price   => $last_candle->{close},
        dir        => ( $last_candle->{close} > $last_pivot->{price} ) ? 'up' : 'down',
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

sub _ingest {
    my ( $self, $idx, $c ) = @_;
    $self->{_c}[$idx] = $c;

    my $bucket_id = $self->_bucket_id_for($c);
    my $cur = $self->{_current_bucket};

    if ( !defined $cur ) {
        $self->{_current_bucket} = $self->_new_bucket( $bucket_id, $idx, $c );
        return;
    }

    if ( $bucket_id == $cur->{bucket_id} ) {
        if ( $c->{high} > $cur->{high} ) {
            $cur->{high}       = $c->{high};
            $cur->{high_index} = $idx;
        }
        if ( $c->{low} < $cur->{low} ) {
            $cur->{low}       = $c->{low};
            $cur->{low_index} = $idx;
        }
        $cur->{close}     = $c->{close};
        $cur->{index_end} = $idx;
        return;
    }

    push @{ $self->{_agg} }, $cur;
    $self->{_current_bucket} = $self->_new_bucket( $bucket_id, $idx, $c );

    $self->_try_confirm_pivot( $#{ $self->{_agg} } );
}

sub _new_bucket {
    my ( $self, $bucket_id, $idx, $c ) = @_;
    return {
        bucket_id   => $bucket_id,
        open        => $c->{open},
        high        => $c->{high},
        low         => $c->{low},
        close       => $c->{close},
        index_start => $idx,
        index_end   => $idx,
        high_index  => $idx,
        low_index   => $idx,
    };
}

sub _bucket_id_for {
    my ( $self, $c ) = @_;
    my $ts = $c->{timestamp} // $c->{ts};
    return 0 unless defined $ts;
    my $secs = $self->{resolution_minutes} * 60;
    return int( $ts / $secs );
}

sub _try_confirm_pivot {
    my ( $self, $last_agg_idx ) = @_;
    my $p = $self->{period};
    my $t = $last_agg_idx - $p;
    return if $t < $p;

    my $agg = $self->{_agg};
    for my $i ( 1 .. $p ) {
        return unless defined $agg->[ $t - $i ] && defined $agg->[ $t + $i ];
    }

    my $is_high = 1;
    my $is_low  = 1;
    for my $i ( 1 .. $p ) {
        $is_high = 0 if !( $agg->[$t]{high} > $agg->[ $t - $i ]{high}
                         && $agg->[$t]{high} > $agg->[ $t + $i ]{high} );
        $is_low  = 0 if !( $agg->[$t]{low}  < $agg->[ $t - $i ]{low}
                         && $agg->[$t]{low}  < $agg->[ $t + $i ]{low} );
    }

    if ( $is_high && $is_low ) {
        if ( $agg->[$t]{high_index} < $agg->[$t]{low_index} ) {
            $self->_consolidate( $t, 'H', $agg->[$t]{high} );
            $self->_consolidate( $t, 'L', $agg->[$t]{low} );
        }
        else {
            $self->_consolidate( $t, 'L', $agg->[$t]{low} );
            $self->_consolidate( $t, 'H', $agg->[$t]{high} );
        }
    }
    else {
        $self->_consolidate( $t, 'H', $agg->[$t]{high} ) if $is_high;
        $self->_consolidate( $t, 'L', $agg->[$t]{low} )  if $is_low;
    }
}

sub _consolidate {
    my ( $self, $agg_index, $kind, $price ) = @_;

    my $pivot = { id => $self->{_next_id}++, index => $agg_index, kind => $kind, price => $price };

    my $pivots = $self->{_pivots};
    my $last = @$pivots ? $pivots->[-1] : undef;

    if ( defined $last && $last->{kind} eq $kind ) {
        my $more_extreme =
            ( $kind eq 'H' ) ? ( $price > $last->{price} ) : ( $price < $last->{price} );
        return unless $more_extreme;
        pop @$pivots;
    }

    push @$pivots, $pivot;
    $self->_rebuild_segments;
}

sub _rebuild_segments {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    my @segments;

    for my $i ( 1 .. $#$pivots ) {
        my $prev = $pivots->[ $i - 1 ];
        my $cur  = $pivots->[$i];

        push @segments, {
            from_index => $self->_base_index_for_pivot($prev),
            to_index   => $self->_base_index_for_pivot($cur),
            from_price => $prev->{price},
            to_price   => $cur->{price},
            dir        => ( $cur->{price} > $prev->{price} ) ? 'up' : 'down',
        };
    }
    $self->{_segments} = \@segments;
}

sub _base_index_for_pivot {
    my ( $self, $pivot ) = @_;
    my $bucket = $self->{_agg}[ $pivot->{index} ];
    return $pivot->{index} unless $bucket;
    return $pivot->{kind} eq 'H' ? $bucket->{high_index} : $bucket->{low_index};
}

1;
