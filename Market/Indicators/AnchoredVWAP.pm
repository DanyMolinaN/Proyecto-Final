package Market::Indicators::AnchoredVWAP;
use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        mode         => $args{mode}         // 'auto',   # 'auto' | 'manual'
        pivot_length => $args{pivot_length} // 50,        # ta.pivothigh/low(length,length)
        band_mult    => $args{band_mult}    // [ 1, 2, 3 ],  # hasta 3 desvios

        _c      => [],     # velas procesadas (indice paralelo)
        _pivots => [],     # historial de pivotes confirmados (auto)

        _anchor_index => undef,
        _anchor_price => undef,   # close de la vela ancla (referencia visual)

        # Sumas incrementales desde el ancla
        _sum_v    => 0,
        _sum_pv   => 0,
        _sum_pv2  => 0,   # sum( v * price^2 ), para varianza ponderada

        # Serie de valores por vela (paralela a _c) desde el ancla en adelante:
        # { vwap, upper1, lower1, upper2, lower2, upper3, lower3 }
        _series => {},    # idx => { ... }
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}      = [];
    $self->{_pivots} = [];

    $self->{_anchor_index} = undef;
    $self->{_anchor_price} = undef;

    $self->{_sum_v}   = 0;
    $self->{_sum_pv}  = 0;
    $self->{_sum_pv2} = 0;

    $self->{_series} = {};
}

sub get_values { return []; }   # contrato IndicatorManager (no aplica aqui)

# -----------------------------------------------------------------------------
# update_at_index / update_last: contrato IndicatorManager.
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;

    my $reanchored = $self->_check_pivot($idx);
    $self->_accumulate_candle($idx) unless $reanchored;
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;

    my $reanchored = $self->_check_pivot($idx);
    $self->_accumulate_candle($idx) unless $reanchored;
}

sub processed_last { return $#{ $_[0]->{_c} }; }

# -----------------------------------------------------------------------------
# set_mode('auto'|'manual')
# -----------------------------------------------------------------------------
sub set_mode {
    my ( $self, $mode ) = @_;
    return unless $mode eq 'auto' || $mode eq 'manual';
    $self->{mode} = $mode;
}
sub get_mode { return $_[0]->{mode}; }

# -----------------------------------------------------------------------------
# set_manual_anchor($idx): fija el ancla explicitamente (click del usuario).
# -----------------------------------------------------------------------------
sub set_manual_anchor {
    my ( $self, $idx ) = @_;
    return unless defined $idx;
    return if $idx < 0 || $idx > $#{ $self->{_c} };
    $self->_set_anchor($idx);
}

sub get_anchor_index { return $_[0]->{_anchor_index}; }
sub get_pivots       { return $_[0]->{_pivots}; }

# -----------------------------------------------------------------------------
# get_series: snapshot para el overlay. undef si aun no hay ancla.
# Devuelve { anchor_index, anchor_price, from_index, to_index, points }
# donde points es un arrayref ordenado por indice con
# { index, vwap, upper1, lower1, upper2, lower2, upper3, lower3 }.
# -----------------------------------------------------------------------------
sub get_series {
    my ($self) = @_;
    return undef unless defined $self->{_anchor_index};

    my $from = $self->{_anchor_index};
    my $to   = $#{ $self->{_c} };
    return undef if $to < $from;

    my @points;
    for my $i ( $from .. $to ) {
        my $p = $self->{_series}{$i};
        next unless $p;
        push @points, { index => $i, %$p };
    }
    return undef unless @points;

    return {
        anchor_index => $self->{_anchor_index},
        anchor_price => $self->{_anchor_price},
        from_index   => $from,
        to_index     => $to,
        points       => \@points,
    };
}

# -----------------------------------------------------------------------------
# get_last_point: solo el ultimo valor calculado (vwap + bandas actuales).
# Util para mostrar el precio justo actual en un panel/etiqueta.
# -----------------------------------------------------------------------------
sub get_last_point {
    my ($self) = @_;
    return undef unless defined $self->{_anchor_index};
    my $last = $#{ $self->{_c} };
    return $self->{_series}{$last};
}

# -----------------------------------------------------------------------------
# _check_pivot: identico criterio que AnchoredVolumeProfile::_check_pivot
# (replica ta.pivothigh(length,length)/ta.pivotlow(length,length)).
# Devuelve 1 si esta llamada disparo un re-anclaje.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# _set_anchor: reinicia el VWAP en $idx y re-acumula todas las velas
# disponibles desde $idx hasta la ultima procesada.
# -----------------------------------------------------------------------------
sub _set_anchor {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];
    return unless defined $c;

    $self->{_anchor_index} = $idx;
    $self->{_anchor_price} = $c->{close};

    $self->{_sum_v}   = 0;
    $self->{_sum_pv}  = 0;
    $self->{_sum_pv2} = 0;
    $self->{_series}  = {};

    my $last = $#{ $self->{_c} };
    for my $i ( $idx .. $last ) {
        $self->_accumulate_candle($i);
    }
}

# -----------------------------------------------------------------------------
# _accumulate_candle: acumula la vela $idx en las sumas incrementales y
# guarda el punto (vwap + bandas) resultante en _series{$idx}.
# Precio tipico: hlc3 = (high+low+close)/3. Si no hay volumen (vol<=0) se
# usa 1 como peso minimo para que la linea no quede indefinida (fallback
# igual de conservador que otros indicadores del proyecto ante datos sin
# volumen real).
# -----------------------------------------------------------------------------
sub _accumulate_candle {
    my ( $self, $idx ) = @_;
    return unless defined $self->{_anchor_index} && $idx >= $self->{_anchor_index};

    my $c = $self->{_c}[$idx];
    return unless defined $c;

    my $vol = $c->{volume} // 0;
    $vol = 1 if $vol <= 0;

    my $tp = ( $c->{high} + $c->{low} + $c->{close} ) / 3;   # hlc3

    $self->{_sum_v}   += $vol;
    $self->{_sum_pv}  += $vol * $tp;
    $self->{_sum_pv2} += $vol * $tp * $tp;

    my $sum_v = $self->{_sum_v};
    return if $sum_v <= 0;

    my $vwap = $self->{_sum_pv} / $sum_v;

    # Varianza ponderada por volumen: E[p^2] - E[p]^2 (clamp >=0 por
    # redondeo de punto flotante).
    my $mean_p2 = $self->{_sum_pv2} / $sum_v;
    my $var     = $mean_p2 - ( $vwap * $vwap );
    $var = 0 if $var < 0;
    my $stdev = sqrt($var);

    my $mults = $self->{band_mult};
    my $point = { vwap => $vwap };
    my @keys  = ( 'upper1', 'upper2', 'upper3' );
    my @lkeys = ( 'lower1', 'lower2', 'lower3' );
    for my $i ( 0 .. $#$mults ) {
        last if $i > 2;   # hasta 3 desvios
        my $m = $mults->[$i];
        $point->{ $keys[$i] }  = $vwap + $stdev * $m;
        $point->{ $lkeys[$i] } = $vwap - $stdev * $m;
    }

    $self->{_series}{$idx} = $point;
}

1;