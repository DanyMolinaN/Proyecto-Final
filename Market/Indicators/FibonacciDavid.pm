package Market::Indicators::FibonacciDavid;

# =============================================================================
# Market::Indicators::FibonacciDavid
#
# Portado desde Proyecto_David/Market/Indicators/Fibonacci.pm
# Adaptaciones para Kevin:
#   - Package renombrado a FibonacciDavid.
#   - Se agrega recompute($md) para IndicatorManager::rebuild_all().
#   - Todo lo demas es identico al original de David.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source_zzvp2 => $args{source_zzvp2},   # Indicators::ZigZagVP2David

        enable_236 => $args{enable_236} // 1,
        enable_382 => $args{enable_382} // 1,
        enable_500 => $args{enable_500} // 1,
        enable_618 => $args{enable_618} // 1,
        enable_786 => $args{enable_786} // 1,

        mode => $args{mode} // 'auto',   # 'auto' | 'manual' | 'off'

        _c => [],

        _manual_anchor_index => undef,
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
    $self->{_manual_anchor_index} = undef;
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
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $c = { %$c, ts => ($c->{ts} // $c->{timestamp}) };
    $self->{_c}[$idx] = $c;
}

sub set_mode {
    my ( $self, $mode ) = @_;
    $self->{mode} = $mode;
}

sub get_mode { return $_[0]->{mode}; }

sub set_manual_anchor {
    my ( $self, $index ) = @_;
    $self->{_manual_anchor_index} = $index;
}

sub get_manual_anchor { return $_[0]->{_manual_anchor_index}; }

sub clear_manual_anchor { $_[0]->{_manual_anchor_index} = undef; }

sub get_fibo_levels {
    my ($self) = @_;
    my $mode = $self->{mode};
    return undef if $mode eq 'off';
    return $self->_get_fibo_levels_auto   if $mode eq 'auto';
    return $self->_get_fibo_levels_manual if $mode eq 'manual';
    return undef;
}

sub _get_fibo_levels_auto {
    my ($self) = @_;
    my $src = $self->{source_zzvp2};
    return undef unless $src;

    my ( $from_price, $from_index, $to_price, $to_index );

    my $open = $src->can('get_tentative_segment') ? $src->get_tentative_segment : undef;
    my $segs = $src->can('get_segments') ? $src->get_segments : undef;

    if ($open) {
        $from_price = $open->{from_price};
        $from_index = $open->{from_index};
        $to_price   = $open->{to_price};
        $to_index   = $open->{to_index};
    }
    elsif ( $segs && @$segs >= 1 ) {
        my $last = $segs->[-1];
        $from_price = $last->{from_price};
        $from_index = $last->{from_index};
        $to_price   = $last->{to_price};
        $to_index   = $last->{to_index};
    }
    else {
        return undef;
    }

    ( $from_price, $to_price ) = $self->_wick_prices(
        $from_index, $from_price, $to_index, $to_price
    );

    return $self->_build_levels( $from_price, $from_index, $to_price, $to_index );
}

sub _wick_prices {
    my ( $self, $from_index, $from_price, $to_index, $to_price ) = @_;
    my $c = $self->{_c};

    my $from_is_top = ( $from_price >= $to_price );

    my $from_candle = $c->[$from_index];
    if ($from_candle) {
        $from_price = $from_is_top ? $from_candle->{high} : $from_candle->{low};
    }
    my $to_candle = $c->[$to_index];
    if ($to_candle) {
        $to_price = $from_is_top ? $to_candle->{low} : $to_candle->{high};
    }

    return ( $from_price, $to_price );
}

sub _get_fibo_levels_manual {
    my ($self) = @_;
    my $anchor = $self->{_manual_anchor_index};
    return undef unless defined $anchor;

    my $c = $self->{_c};
    my $last_idx = $#$c;
    return undef if $last_idx < 0 || $anchor > $last_idx;

    my $anchor_candle = $c->[$anchor];
    return undef unless defined $anchor_candle;

    my $hi = $anchor_candle->{high};
    my $lo = $anchor_candle->{low};

    for my $i ( $anchor + 1 .. $last_idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $hi = $candle->{high} if $candle->{high} > $hi;
        $lo = $candle->{low}  if $candle->{low}  < $lo;
    }

    # Extremos por indice cronologico: evita invertir el lado izquierdo
    # durante un retroceso (el from es siempre el extremo que ocurrio primero).
    my $hi_idx = $self->_index_of_extreme( $anchor, $last_idx, 'high', $hi );
    my $lo_idx = $self->_index_of_extreme( $anchor, $last_idx, 'low',  $lo );

    my ( $from_price, $from_index, $to_price, $to_index );
    if ( $lo_idx <= $hi_idx ) {
        # Movimiento alcista (low primero → high despues)
        $from_price = $lo;
        $from_index = $lo_idx;
        $to_price   = $hi;
        $to_index   = $hi_idx;
    }
    else {
        # Movimiento bajista (high primero → low despues)
        $from_price = $hi;
        $from_index = $hi_idx;
        $to_price   = $lo;
        $to_index   = $lo_idx;
    }

    return $self->_build_levels( $from_price, $from_index, $to_price, $to_index );
}

sub _index_of_extreme {
    my ( $self, $from, $to, $field, $target ) = @_;
    my $c = $self->{_c};
    for my $i ( $from .. $to ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        return $i if $candle->{$field} == $target;
    }
    return $to;
}

sub _build_levels {
    my ( $self, $from_price, $from_index, $to_price, $to_index ) = @_;

    my $diff = $to_price - $from_price;
    my $dir  = ( $diff >= 0 ) ? 1 : -1;

    my $last_bar_idx = $#{ $self->{_c} };
    $last_bar_idx = $to_index if $last_bar_idx < $to_index;

    my @out;
    my $stopit = 0;
    my $shown  = $self->_shown_levels_count;

    my $ratios = $self->{_fibo_ratios};
    for my $x ( 0 .. $#$ratios ) {
        last if $stopit && $x > $shown;

        my $ratio = $ratios->[$x];
        last if $ratio > 1.0;
        my $price = $from_price + $diff * $ratio;

        push @out, {
            ratio      => $ratio,
            price      => $price,
            from_index => $from_index,
            to_index   => $last_bar_idx,
        };

        if ( ( $dir == 1 && $price > $to_price )
            || ( $dir == -1 && $price < $to_price ) )
        {
            $stopit = 1;
        }
    }
    return \@out;
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
