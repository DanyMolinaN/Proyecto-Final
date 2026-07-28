package Market::Indicators::ZigZagMTF2David;

# =============================================================================
# Market::Indicators::ZigZagMTF2David
#
# Portado desde Proyecto_David/Market/Indicators/ZigZagMTF2.pm
# Adaptaciones para Kevin:
#   - Package renombrado a ZigZagMTF2David.
#   - Se agrega recompute($md) para IndicatorManager::rebuild_all().
#   - Se agrega set_resolution($res) para que el ToolsExtra toolbar pueda
#     cambiar la temporalidad en vivo.
#   - Todo lo demas es identico al original de David.
# =============================================================================

use strict;
use warnings;
use Time::Moment;

use constant GMT_OFFSET_MIN => -300;   # GMT-5

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        resolution => $args{resolution} // '5min',
        period     => $args{period}     // 2,

        enable_236 => $args{enable_236} // 1,
        enable_382 => $args{enable_382} // 1,
        enable_500 => $args{enable_500} // 1,
        enable_618 => $args{enable_618} // 1,
        enable_786 => $args{enable_786} // 1,

        _c => [],

        _prev_bucket_ts     => undef,
        _newbar_bar_indices => [],

        _dir      => 0,
        _prev_dir => 0,

        _zigzag => [],

        _fibo_ratios => undef,
    };
    bless $self, $class;
    $self->_build_fibo_ratios;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_prev_bucket_ts} = undef;
    $self->{_newbar_bar_indices} = [];
    $self->{_dir}      = 0;
    $self->{_prev_dir} = 0;
    $self->{_zigzag}   = [];
}

# Permite cambiar la temporalidad desde el ToolsExtra toolbar.
# Tras llamarlo se debe llamar recompute() o request_render() para recalcular.
sub set_resolution {
    my ( $self, $res ) = @_;
    return unless defined $res;
    $self->{resolution} = $res;
    delete $self->{_kevin_computed_fp};
}

sub get_resolution {
    my ($self) = @_;
    return $self->{resolution};
}

# recompute($md): contrato de IndicatorManager::rebuild_all() de Kevin.
sub recompute {
    my ( $self, $md ) = @_;
    return unless $md;
    $self->reset();
    my $size = $md->size // 0;
    for my $idx ( 0 .. $size - 1 ) {
        $self->update_at_index( $md, $idx );
    }
    my $res = $self->{resolution} // '';
    $self->{_kevin_computed_fp} = "$res|$size";
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    # Kevin usa {timestamp}; David usa {ts}. Normalizar al almacenar.
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

sub get_segments {
    my ($self) = @_;
    my $zz = $self->{_zigzag};
    my $n  = @$zz / 2;
    return [] if $n < 2;

    my @segments;
    for my $i ( 0 .. $n - 2 ) {
        my $v_new = $zz->[ 2 * $i ];
        my $b_new = $zz->[ 2 * $i + 1 ];
        my $v_old = $zz->[ 2 * ( $i + 1 ) ];
        my $b_old = $zz->[ 2 * ( $i + 1 ) + 1 ];

        unshift @segments, {
            from_index => $b_old,
            from_price => $v_old,
            to_index   => $b_new,
            to_price   => $v_new,
            dir        => ( $v_new > $v_old ) ? 'up' : 'down',
        };
    }
    return \@segments;
}

sub get_fibo_levels {
    my ($self) = @_;
    my $zz = $self->{_zigzag};
    return undef if @$zz < 6;

    my $y_from  = $zz->[2];
    my $y_to    = $zz->[4];
    my $x_from  = $zz->[5];
    my $diff    = $y_to - $y_from;

    my $last_bar_idx = $#{ $self->{_c} };
    my $dir = $self->{_dir};
    my $ref_extreme = $zz->[0];

    my @out;
    my $stopit = 0;
    my $shown  = $self->_shown_levels_count;

    my $ratios = $self->{_fibo_ratios};
    for my $x ( 0 .. $#$ratios ) {
        last if $stopit && $x > $shown;

        my $ratio = $ratios->[$x];
        my $price = $y_from + $diff * $ratio;

        push @out, {
            ratio      => $ratio,
            price      => $price,
            from_index => $x_from,
            to_index   => $last_bar_idx,
        };

        if ( ( $dir == 1 && $price > $ref_extreme )
            || ( $dir == -1 && $price < $ref_extreme ) )
        {
            $stopit = 1;
        }
    }
    return \@out;
}

sub get_dir { return $_[0]->{_dir}; }

# Expone los swings en formato compatible con Indicators::Liquidity (get_swings)
# para que LiquidityDavid pueda usarlo como zzmtf.
sub get_swings {
    my ($self) = @_;
    my $segs = $self->get_segments;
    return [] unless $segs && @$segs;
    my @swings;
    for my $s (@$segs) {
        push @swings, { index => $s->{from_index}, price => $s->{from_price},
                        kind  => ( $s->{dir} eq 'up' ? 'L' : 'H' ) };
    }
    # Añadir el ultimo punto (to del ultimo segmento)
    my $last = $segs->[-1];
    push @swings, { index => $last->{to_index}, price => $last->{to_price},
                    kind  => ( $last->{dir} eq 'up' ? 'H' : 'L' ) };
    return \@swings;
}

sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];

    my $bucket_ts = $self->_bucket_ts_for( $c->{ts} );
    my $is_newbar = ( !defined $self->{_prev_bucket_ts} )
        || ( $bucket_ts != $self->{_prev_bucket_ts} );
    $self->{_prev_bucket_ts} = $bucket_ts;

    push @{ $self->{_newbar_bar_indices} }, $idx if $is_newbar;

    my $p  = $self->{period};
    my $nb = $self->{_newbar_bar_indices};
    return unless @$nb >= $p;
    my $bi  = $nb->[ -$p ];
    my $len = $idx - $bi + 1;
    return if $len <= 0;

    my ( $ph, $pl ) = $self->_ph_pl( $idx, $len );

    $self->{_prev_dir} = $self->{_dir};
    if ( defined($ph) && !defined($pl) ) {
        $self->{_dir} = 1;
    }
    elsif ( defined($pl) && !defined($ph) ) {
        $self->{_dir} = -1;
    }

    return unless defined($ph) || defined($pl);

    my $dir_changed = ( $self->{_dir} != $self->{_prev_dir} );
    my $value = ( $self->{_dir} == 1 ) ? $ph : $pl;
    return unless defined $value;

    if ($dir_changed) {
        $self->_add_to_zigzag( $value, $idx );
    }
    else {
        $self->_update_zigzag( $value, $idx );
    }
}

sub _ph_pl {
    my ( $self, $idx, $len ) = @_;
    my $from = $idx - $len + 1;
    $from = 0 if $from < 0;

    my $c = $self->{_c};
    my $cur = $c->[$idx];

    my $is_highest = 1;
    my $is_lowest  = 1;
    for my $i ( $from .. $idx - 1 ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $is_highest = 0 if $candle->{high} > $cur->{high};
        $is_lowest  = 0 if $candle->{low}  < $cur->{low};
    }
    my $ph = $is_highest ? $cur->{high} : undef;
    my $pl = $is_lowest  ? $cur->{low}  : undef;
    return ( $ph, $pl );
}

sub _add_to_zigzag {
    my ( $self, $value, $bindex ) = @_;
    unshift @{ $self->{_zigzag} }, $bindex;
    unshift @{ $self->{_zigzag} }, $value;
    if ( @{ $self->{_zigzag} } > 500 ) {
        pop @{ $self->{_zigzag} };
        pop @{ $self->{_zigzag} };
    }
}

sub _update_zigzag {
    my ( $self, $value, $bindex ) = @_;
    my $zz = $self->{_zigzag};
    if ( !@$zz ) {
        $self->_add_to_zigzag( $value, $bindex );
        return;
    }
    my $dir = $self->{_dir};
    if ( ( $dir == 1 && $value > $zz->[0] ) || ( $dir == -1 && $value < $zz->[0] ) ) {
        $zz->[0] = $value;
        $zz->[1] = $bindex;
    }
}

my %RES_MINUTES = (
    '1min'  => 1,  '3min'  => 3,  '5min'  => 5,  '10min' => 10,
    '15min' => 15, '30min' => 30, '45min' => 45,
    '1h'    => 60, '2h'    => 120, '3h'   => 180, '4h'    => 240,
    # Aliases para los botones del toolbar (1m, 2m, etc.)
    '1m'   => 1,  '2m'   => 2,  '3m'   => 3,  '5m'   => 5,
    '10m'  => 10, '15m'  => 15, '30m'  => 30, '45m'  => 45,
    '1H'   => 60, '2H'   => 120, '3H'  => 180, '4H'   => 240,
);

sub _bucket_ts_for {
    my ( $self, $ts ) = @_;
    my $res = $self->{resolution};

    if ( exists $RES_MINUTES{$res} ) {
        my $interval_sec = $RES_MINUTES{$res} * 60;
        return int( $ts / $interval_sec ) * $interval_sec;
    }

    my $tm = Time::Moment->from_epoch($ts)->with_offset_same_instant(GMT_OFFSET_MIN);

    if ( $res eq '1d' || $res eq '1D' ) {
        return $self->_truncate_to_midnight($tm)->epoch;
    }
    if ( $res eq '1w' || $res eq '1W' ) {
        my $dow = $tm->day_of_week;
        return $self->_truncate_to_midnight($tm)->minus_days( $dow - 1 )->epoch;
    }
    if ( $res eq '1mo' ) {
        return $self->_truncate_to_midnight($tm)->with_day_of_month(1)->epoch;
    }

    if ( $res =~ /^(\d+)$/ ) {
        my $interval_sec = $1 * 60;
        return int( $ts / $interval_sec ) * $interval_sec;
    }
    return int($ts);
}

sub _truncate_to_midnight {
    my ( $self, $tm ) = @_;
    return $tm->with_hour(0)->with_minute(0)->with_second(0)->with_nanosecond(0);
}

sub _build_fibo_ratios {
    my ($self) = @_;
    my @ratios = (0.000);
    push @ratios, 0.236 if $self->{enable_236};
    push @ratios, 0.382 if $self->{enable_382};
    push @ratios, 0.500 if $self->{enable_500};
    push @ratios, 0.618 if $self->{enable_618};
    push @ratios, 0.786 if $self->{enable_786};

    for my $x ( 1 .. 5 ) {
        push @ratios, $x, $x + 0.272, $x + 0.414, $x + 0.618;
    }
    $self->{_fibo_ratios} = \@ratios;
}

sub _shown_levels_count {
    my ($self) = @_;
    my $n = 1;
    $n++ for grep { $self->{$_} } qw(enable_236 enable_382 enable_500 enable_618 enable_786);
    return $n;
}

1;
