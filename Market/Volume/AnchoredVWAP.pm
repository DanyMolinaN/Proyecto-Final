package Market::Volume::AnchoredVWAP;
use strict;
use warnings;
use List::Util qw(max min);

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
        _anchor_kind  => 'regular',

        # Estado para seguimiento de alternancia / ghost
        _max => undef, _min => undef, _max_x1 => 0, _min_x1 => 0,
        _follow_max => undef, _follow_min => undef, _follow_max_x1 => 0, _follow_min_x1 => 0,
        _prev_follow_max => undef, _prev_follow_min => undef,
        _os => 0, _px1 => 0, _py1 => undef,

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
    $self->{_anchor_kind}  = 'regular';

    $self->{_max} = undef; $self->{_min} = undef; 
    $self->{_max_x1} = 0; $self->{_min_x1} = 0;
    $self->{_follow_max} = undef; $self->{_follow_min} = undef; 
    $self->{_follow_max_x1} = 0; $self->{_follow_min_x1} = 0;
    $self->{_prev_follow_max} = undef; $self->{_prev_follow_min} = undef;
    $self->{_os} = 0; $self->{_px1} = 0; $self->{_py1} = undef;

    $self->{_sum_v}   = 0;
    $self->{_sum_pv}  = 0;
    $self->{_sum_pv2} = 0;

    $self->{_series} = {};
}

sub get_values { return []; }   # contrato IndicatorManager (no aplica aqui)

sub calculate {
    my ($self, $md, %args) = @_;
    $self->reset();
    my $size = $md->size();
    for my $i (0 .. $size - 1) {
        $self->update_at_index($md, $i);
    }
    return $self->get_series();
}

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

    my $res = {
        anchor_index => $self->{_anchor_index},
        anchor_price => $self->{_anchor_price},
        anchor_kind  => $self->{_anchor_kind} // 'regular',
        from_index   => $from,
        to_index     => $to,
        points       => \@points,
    };

    my $preview = $self->get_live_ghost_preview();
    $res->{live_preview} = $preview if $preview;

    return $res;
}

sub get_live_ghost_preview {
    my ($self) = @_;
    return undef unless @{ $self->{_pivots} };
    
    my $last_visible_index = $#{ $self->{_c} };
    my $last_pivot = $self->{_pivots}[-1];
    my $px1 = $last_pivot->{index};
    
    return undef if $last_visible_index <= $px1;

    my $os = $last_pivot->{type} eq 'high' ? 1 : 0;
    
    my $x_last = undef;
    my $y_last = undef;

    for my $i ($px1 + 1 .. $last_visible_index) {
        my $c = $self->{_c}[$i];
        next unless defined $c;
        if ($os == 1) {
            if (!defined($y_last) || $c->{low} <= $y_last) {
                $y_last = $c->{low};
                $x_last = $i;
            }
        } else {
            if (!defined($y_last) || $c->{high} >= $y_last) {
                $y_last = $c->{high};
                $x_last = $i;
            }
        }
    }

    return undef unless defined $x_last;

    my $ghost_cumVol = 0;
    my $ghost_cumPriceVol = 0;
    my $ghost_sumSqDiff = 0;
    my @points;

    for my $i ($x_last .. $last_visible_index) {
        my $c = $self->{_c}[$i];
        next unless defined $c;
        
        my $vol = $c->{volume} // 0;
        $vol = 1 if $vol <= 0;
        my $tp = ($c->{high} + $c->{low} + $c->{close}) / 3;

        $ghost_cumVol += $vol;
        $ghost_cumPriceVol += $tp * $vol;
        my $vwap = $ghost_cumVol > 0 ? $ghost_cumPriceVol / $ghost_cumVol : 0;

        $ghost_sumSqDiff += $vol * (($tp - $vwap) ** 2);
        my $var = $ghost_cumVol > 0 ? $ghost_sumSqDiff / $ghost_cumVol : 0;
        $var = 0 if $var < 0;
        my $stdev = sqrt($var);

        my $mults = $self->{band_mult};
        my $point = { index => $i, vwap => $vwap };
        my @keys  = ( 'upper1', 'upper2', 'upper3' );
        my @lkeys = ( 'lower1', 'lower2', 'lower3' );
        for my $m_idx (0 .. $#$mults) {
            last if $m_idx > 2;
            my $m = $mults->[$m_idx];
            $point->{ $keys[$m_idx] }  = $vwap + $stdev * $m;
            $point->{ $lkeys[$m_idx] } = $vwap - $stdev * $m;
        }
        push @points, $point;
    }

    return {
        anchor_index => $x_last,
        anchor_price => $y_last,
        from_index   => $x_last,
        to_index     => $last_visible_index,
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

    my $cand_c = $c->[$cand];
    return 0 unless defined $cand_c;

    # Track alternancia history on evaluated cand
    my $high_len = $cand_c->{high};
    my $low_len  = $cand_c->{low};

    my $prev_max = $self->{_max};
    my $prev_min = $self->{_min};

    $self->{_max} = defined($self->{_max}) ? max($high_len, $self->{_max}) : $high_len;
    $self->{_min} = defined($self->{_min}) ? min($low_len, $self->{_min}) : $low_len;
    $self->{_follow_max} = defined($self->{_follow_max}) ? max($high_len, $self->{_follow_max}) : $high_len;
    $self->{_follow_min} = defined($self->{_follow_min}) ? min($low_len, $self->{_follow_min}) : $low_len;

    if (!defined $prev_max || $self->{_max} > $prev_max) {
        $self->{_max_x1} = $cand;
        $self->{_follow_min} = $low_len;
    }
    if (!defined $prev_min || $self->{_min} < $prev_min) {
        $self->{_min_x1} = $cand;
        $self->{_follow_max} = $high_len;
    }

    my $prev_follow_min = $self->{_prev_follow_min};
    my $prev_follow_max = $self->{_prev_follow_max};

    if (!defined $prev_follow_min || $self->{_follow_min} < $prev_follow_min) {
        $self->{_follow_min_x1} = $cand;
    }
    if (!defined $prev_follow_max || $self->{_follow_max} > $prev_follow_max) {
        $self->{_follow_max_x1} = $cand;
    }

    $self->{_prev_follow_min} = $self->{_follow_min};
    $self->{_prev_follow_max} = $self->{_follow_max};

    my ( $max_h, $min_l );
    for my $i ( ( $idx - 2 * $L ) .. $idx ) {
        my $cc = $c->[$i];
        next unless defined $cc;
        $max_h = $cc->{high} if !defined($max_h) || $cc->{high} > $max_h;
        $min_l = $cc->{low}  if !defined($min_l) || $cc->{low}  < $min_l;
    }
    return 0 unless defined $max_h && defined $min_l;

    my $reanchored = 0;

    if ( $cand_c->{high} == $max_h ) {
        my $ph = $cand_c->{high};
        
        # Ghost Pivot Alternation
        if ($self->{_os} == 1) {
            push @{ $self->{_pivots} }, { index => $self->{_min_x1}, price => $self->{_min}, type => 'low', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_min_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_min_x1}, 'ghost');
                $reanchored = 1;
            }
            $self->{_px1} = $self->{_min_x1}; $self->{_py1} = $self->{_min};
        } elsif (defined $self->{_max} && $ph < $self->{_max}) {
            push @{ $self->{_pivots} }, { index => $self->{_max_x1}, price => $self->{_max}, type => 'high', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_max_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_max_x1}, 'ghost');
                $reanchored = 1;
            }
            push @{ $self->{_pivots} }, { index => $self->{_follow_min_x1}, price => $self->{_follow_min}, type => 'low', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_follow_min_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_follow_min_x1}, 'ghost');
                $reanchored = 1;
            }
            $self->{_px1} = $self->{_follow_min_x1}; $self->{_py1} = $self->{_follow_min};
        }

        # Regular Pivot
        push @{ $self->{_pivots} }, { index => $cand, price => $max_h, type => 'high', kind => 'regular' };
        if ( $self->{mode} eq 'auto' && ( !defined $self->{_anchor_index} || $cand > $self->{_anchor_index} ) ) {
            $self->_set_anchor($cand, 'regular');
            $reanchored = 1;
        }

        $self->{_py1} = $max_h; $self->{_px1} = $cand; $self->{_os} = 1;
        $self->{_max} = $max_h; $self->{_min} = $max_h;
    }
    if ( $cand_c->{low} == $min_l ) {
        my $pl = $cand_c->{low};

        # Ghost Pivot Alternation
        if ($self->{_os} == 0) {
            push @{ $self->{_pivots} }, { index => $self->{_max_x1}, price => $self->{_max}, type => 'high', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_max_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_max_x1}, 'ghost');
                $reanchored = 1;
            }
            $self->{_px1} = $self->{_max_x1}; $self->{_py1} = $self->{_max};
        } elsif (defined $self->{_min} && $pl > $self->{_min}) {
            push @{ $self->{_pivots} }, { index => $self->{_min_x1}, price => $self->{_min}, type => 'low', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_min_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_min_x1}, 'ghost');
                $reanchored = 1;
            }
            push @{ $self->{_pivots} }, { index => $self->{_follow_max_x1}, price => $self->{_follow_max}, type => 'high', kind => 'ghost' };
            if ($self->{mode} eq 'auto' && (!defined $self->{_anchor_index} || $self->{_follow_max_x1} > $self->{_anchor_index})) {
                $self->_set_anchor($self->{_follow_max_x1}, 'ghost');
                $reanchored = 1;
            }
            $self->{_px1} = $self->{_follow_max_x1}; $self->{_py1} = $self->{_follow_max};
        }

        # Regular Pivot
        push @{ $self->{_pivots} }, { index => $cand, price => $min_l, type => 'low', kind => 'regular' };
        if ( $self->{mode} eq 'auto' && ( !defined $self->{_anchor_index} || $cand > $self->{_anchor_index} ) ) {
            $self->_set_anchor($cand, 'regular');
            $reanchored = 1;
        }

        $self->{_py1} = $min_l; $self->{_px1} = $cand; $self->{_os} = 0;
        $self->{_max} = $min_l; $self->{_min} = $min_l;
    }
    return $reanchored;
}

# -----------------------------------------------------------------------------
# _set_anchor: reinicia el VWAP en $idx y re-acumula todas las velas
# disponibles desde $idx hasta la ultima procesada.
# -----------------------------------------------------------------------------
sub _set_anchor {
    my ( $self, $idx, $kind ) = @_;
    my $c = $self->{_c}[$idx];
    return unless defined $c;

    $self->{_anchor_index} = $idx;
    $self->{_anchor_price} = $c->{close};
    $self->{_anchor_kind}  = $kind // 'regular';

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