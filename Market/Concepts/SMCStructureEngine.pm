package Market::Concepts::SMCStructureEngine;

# =============================================================================
# Market::Concepts::SMCStructureEngine  — v2.1
# =============================================================================
# CAMBIOS v2.1 (Req-2, Req-3):
#
#   Req-2 — Política de No-Mitigación:
#     HH, HL, LH, LL, BOS, CHoCH, EQH, EQL son ESTRUCTURAS PERMANENTES.
#     La flag `crossed=1` sigue existiendo (bloquea re-disparo en la misma barra),
#     pero ya NO se usa para ocultar el nivel visualmente. Los overlays no deben
#     filtrar por `crossed`. Ver DISPATCH TABLE %PERSISTENCE_POLICY.
#
#   Req-3 — Proyección EQL/EQH con Single-Pass O(N):
#     Al detectar un EQL/EQH se guarda en el HashMap %open_eq (clave = kind+level).
#     Cuando una barra posterior cierra al otro lado del nivel (evento finalizador:
#     BOS o CHoCH que cruza ese precio), se calcula end_index = i en O(1) y se
#     cierra el intervalo. Sin bucles anidados O(n^2).
#
# Salida adicional en cada evento EQH/EQL:
#   end_index   => índice donde termina la proyección (o last_index si aún abierto)
#   is_open     => 1 si la línea aún se proyecta, 0 si fue cerrada
# =============================================================================

use strict;
use warnings;

# ---------------------------------------------------------------------------
# Tabla de despacho: persistencia por tipo de estructura (Req-2).
# 'permanent' = nunca se oculta tras ser cruzado.
# 'mitigatable' = se detiene en el punto de ruptura (solo trendlines/canales).
# ---------------------------------------------------------------------------
my %PERSISTENCE_POLICY = (
    HH    => 'permanent',
    HL    => 'permanent',
    LH    => 'permanent',
    LL    => 'permanent',
    BOS   => 'permanent',
    CHoCH => 'permanent',
    EQH   => 'permanent',
    EQL   => 'permanent',
);

use constant {
    _BULLISH     =>  1,
    _BEARISH     => -1,
    _NEUTRAL     =>  0,
    _BULLISH_LEG =>  1,
    _BEARISH_LEG =>  0,
};

use constant MAX_PIVOT_HISTORY => 500;

use constant {
    DEFAULT_SWING_LENGTH    => 50,
    DEFAULT_INTERNAL_LENGTH =>  5,
    DEFAULT_EQ_LENGTH       =>  3,
    DEFAULT_EQ_THRESHOLD    =>  0.1,
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        swing_length    => $args{swing_length}    // DEFAULT_SWING_LENGTH,
        internal_length => $args{internal_length} // DEFAULT_INTERNAL_LENGTH,
        eq_length       => $args{eq_length}       // DEFAULT_EQ_LENGTH,
        eq_threshold    => $args{eq_threshold}    // DEFAULT_EQ_THRESHOLD,

        _sw_high        => undef,
        _sw_low         => undef,
        _sw_trend       => _NEUTRAL,
        _sw_prev_leg    => undef,

        _in_high        => undef,
        _in_low         => undef,
        _in_trend       => _NEUTRAL,
        _in_prev_leg    => undef,

        _eq_high        => undef,
        _eq_low         => undef,
        _eq_prev_leg    => undef,

        events          => [],
        by_index        => {},
        features        => {},
        swing_highs     => [],
        swing_lows      => [],
        internal_highs  => [],
        internal_lows   => [],
        eqh             => [],
        eql             => [],
        metadata        => {},
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_sw_high}     = undef;
    $self->{_sw_low}      = undef;
    $self->{_sw_trend}    = _NEUTRAL;
    $self->{_sw_prev_leg} = undef;
    $self->{_in_high}     = undef;
    $self->{_in_low}      = undef;
    $self->{_in_trend}    = _NEUTRAL;
    $self->{_in_prev_leg} = undef;
    $self->{_eq_high}     = undef;
    $self->{_eq_low}      = undef;
    $self->{_eq_prev_leg} = undef;
    $self->{events}         = [];
    $self->{by_index}       = {};
    $self->{features}       = {};
    $self->{swing_highs}    = [];
    $self->{swing_lows}     = [];
    $self->{internal_highs} = [];
    $self->{internal_lows}  = [];
    $self->{eqh}            = [];
    $self->{eql}            = [];
    $self->{metadata}       = {};
    return $self;
}

# =============================================================================
# calculate($market_data, %args)  →  \%result
# O(N) — único pase sobre el dataset.
# =============================================================================
sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    $self->reset();

    my $total = $market_data->size();
    return {} unless $total > 0;

    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    my @candles;
    $#candles = $last_index;
    for my $i (0 .. $last_index) {
        $candles[$i] = $market_data->get_candle($i);
    }

    my $n      = $last_index + 1;
    my $sw_len = $self->{swing_length};
    my $in_len = $self->{internal_length};
    my $eq_len = $self->{eq_length};
    my $eq_thr = $self->{eq_threshold};

    my $atr = _compute_atr(\@candles, $last_index, 200);

    # ── Req-3: HashMap para rastrear EQL/EQH abiertos en O(1) ────────────────
    # Clave: "EQH|$level" o "EQL|$level" (redondeado a 6 decimales).
    # Valor: referencia al hashref del evento (para actualizar end_index in-place).
    my %open_eq;   # $key => \@list_of_event_refs

    for my $i (0 .. $last_index) {
        next unless $candles[$i];

        # 1. Swing Structure
        $self->_update_pivots(\@candles, $i, $sw_len,
            high_ref  => \$self->{_sw_high},
            low_ref   => \$self->{_sw_low},
            prev_ref  => \$self->{_sw_prev_leg},
            store_h   => $self->{swing_highs},
            store_l   => $self->{swing_lows},
        );

        # 2. Internal Structure
        $self->_update_pivots(\@candles, $i, $in_len,
            high_ref  => \$self->{_in_high},
            low_ref   => \$self->{_in_low},
            prev_ref  => \$self->{_in_prev_leg},
            store_h   => $self->{internal_highs},
            store_l   => $self->{internal_lows},
        );

        # 3. EQH / EQL (detecta nuevos eventos y los registra en %open_eq)
        $self->_update_equal_hl(\@candles, $i, $eq_len,
            high_ref  => \$self->{_eq_high},
            low_ref   => \$self->{_eq_low},
            prev_ref  => \$self->{_eq_prev_leg},
            atr       => $atr,
            threshold => $eq_thr,
            open_eq   => \%open_eq,
        );

        # 4. BOS/CHoCH Swing
        $self->_check_structure_break(\@candles, $i,
            high_ref  => \$self->{_sw_high},
            low_ref   => \$self->{_sw_low},
            trend_ref => \$self->{_sw_trend},
            scope     => 'swing',
            open_eq   => \%open_eq,
            bar_index => $i,
        );

        # 5. BOS/CHoCH Internal
        $self->_check_structure_break(\@candles, $i,
            high_ref  => \$self->{_in_high},
            low_ref   => \$self->{_in_low},
            trend_ref => \$self->{_in_trend},
            scope     => 'internal',
            open_eq   => \%open_eq,
            bar_index => $i,
        );
    }

    # Req-3: Cerrar todos los EQL/EQH que quedaron abiertos → end_index = last_index
    for my $evts (values %open_eq) {
        for my $evt (@{ $evts || [] }) {
            $evt->{end_index} = $last_index if !defined $evt->{end_index} || $evt->{end_index} < $last_index;
            $evt->{is_open}   = 1;
        }
    }

    my $sw_trend_str = _bias_str($self->{_sw_trend});
    my $in_trend_str = _bias_str($self->{_in_trend});

    my ($bos_count, $choch_count) = (0, 0);
    for my $e (@{ $self->{events} }) {
        $bos_count++   if $e->{kind} eq 'BOS';
        $choch_count++ if $e->{kind} eq 'CHoCH';

        my $idx = $e->{index};
        $self->{features}{$idx} //= {};

        if ($e->{kind} eq 'BOS' || $e->{kind} eq 'CHoCH') {
            my $key = $e->{scope} eq 'internal' ? 'internal_event' : 'swing_event';
            my $val = uc($e->{kind}) . '_' . (uc($e->{direction}) =~ s/ISH//r);
            $self->{features}{$idx}{$key} = $val;
        }
        elsif ($e->{kind} eq 'EQH') { $self->{features}{$idx}{eqh} = 1; }
        elsif ($e->{kind} eq 'EQL') { $self->{features}{$idx}{eql} = 1; }
    }

    $self->{metadata} = {
        timeframe       => $args{timeframe}
                        || ($market_data->can('active_tf') ? $market_data->active_tf() : 'unknown'),
        total_candles   => $n,
        last_index      => $last_index,
        visible_limit   => $visible_limit,
        swing_length    => $sw_len,
        internal_length => $in_len,
        eq_length       => $eq_len,
        eq_threshold    => $eq_thr,
        atr             => $atr,
        event_count     => scalar(@{ $self->{events} }),
        bos_count       => $bos_count,
        choch_count     => $choch_count,
        eqh_count       => scalar(@{ $self->{eqh} }),
        eql_count       => scalar(@{ $self->{eql} }),
        swing_trend     => $sw_trend_str,
        internal_trend  => $in_trend_str,
        swing_high_count    => scalar(@{ $self->{swing_highs} }),
        swing_low_count     => scalar(@{ $self->{swing_lows} }),
        internal_high_count => scalar(@{ $self->{internal_highs} }),
        internal_low_count  => scalar(@{ $self->{internal_lows} }),
        persistence_policy  => 'permanent',
    };

    return {
        events          => $self->{events},
        by_index        => $self->{by_index},
        features        => $self->{features},
        swing_highs     => $self->{swing_highs},
        swing_lows      => $self->{swing_lows},
        internal_highs  => $self->{internal_highs},
        internal_lows   => $self->{internal_lows},
        eqh             => $self->{eqh},
        eql             => $self->{eql},
        swing_trend     => $sw_trend_str,
        internal_trend  => $in_trend_str,
        last_swing_high    => $self->{_sw_high},
        last_swing_low     => $self->{_sw_low},
        last_internal_high => $self->{_in_high},
        last_internal_low  => $self->{_in_low},
        metadata        => $self->{metadata},
    };
}

# Accesores públicos
sub events         { $_[0]->{events}         || [] }
sub swing_highs    { $_[0]->{swing_highs}    || [] }
sub swing_lows     { $_[0]->{swing_lows}     || [] }
sub internal_highs { $_[0]->{internal_highs} || [] }
sub internal_lows  { $_[0]->{internal_lows}  || [] }
sub eqh            { $_[0]->{eqh}            || [] }
sub eql            { $_[0]->{eql}            || [] }
sub metadata       { $_[0]->{metadata}       || {} }
sub swing_trend    { _bias_str($_[0]->{_sw_trend}) }
sub internal_trend { _bias_str($_[0]->{_in_trend}) }

# =============================================================================
# PRIVATE — _leg(\@candles, $i, $size)
# =============================================================================
sub _leg {
    my ($candles, $i, $size) = @_;
    return undef if $i < $size;
    my $pivot_idx = $i - $size;
    my $pivot     = $candles->[$pivot_idx];
    return undef unless $pivot;
    my ($hi, $lo);
    for my $j ($pivot_idx + 1 .. $i) {
        my $c = $candles->[$j] or next;
        $hi = $c->{high} if !defined $hi || $c->{high} > $hi;
        $lo = $c->{low}  if !defined $lo || $c->{low}  < $lo;
    }
    return undef unless defined $hi && defined $lo;
    if    ($pivot->{high} > $hi) { return _BEARISH_LEG; }
    elsif ($pivot->{low}  < $lo) { return _BULLISH_LEG; }
    return undef;
}

# =============================================================================
# PRIVATE — _update_pivots  (sin cambios respecto v2.0)
# =============================================================================
sub _update_pivots {
    my ($self, $candles, $i, $size, %o) = @_;
    my $current_leg = _leg($candles, $i, $size);
    return unless defined $current_leg;
    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $current_leg;
    return if defined $prev_leg && $prev_leg == $current_leg;
    my $pivot_idx    = $i - $size;
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;
    my $delta = defined $prev_leg ? ($current_leg - $prev_leg) : $current_leg;
    if ($delta > 0) {
        my $old  = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};
        my $new_pivot = { level => $nlvl, last_level => defined $old ? $old->{level} : undef, crossed => 0, index => $pivot_idx };
        ${ $o{low_ref} } = $new_pivot;
        my $label = _low_label($new_pivot->{last_level}, $nlvl);
        my $entry = { index => $pivot_idx, level => $nlvl, last_level => $new_pivot->{last_level}, label => $label, crossed => 0 };
        push @{ $o{store_l} }, $entry;
        shift @{ $o{store_l} } while @{ $o{store_l} } > MAX_PIVOT_HISTORY;
    }
    elsif ($delta < 0) {
        my $old  = ${ $o{high_ref} };
        my $nlvl = $pivot_candle->{high};
        my $new_pivot = { level => $nlvl, last_level => defined $old ? $old->{level} : undef, crossed => 0, index => $pivot_idx };
        ${ $o{high_ref} } = $new_pivot;
        my $label = _high_label($new_pivot->{last_level}, $nlvl);
        my $entry = { index => $pivot_idx, level => $nlvl, last_level => $new_pivot->{last_level}, label => $label, crossed => 0 };
        push @{ $o{store_h} }, $entry;
        shift @{ $o{store_h} } while @{ $o{store_h} } > MAX_PIVOT_HISTORY;
    }
}

# =============================================================================
# PRIVATE — _update_equal_hl  (Req-3: registra en %open_eq al crear el evento)
# =============================================================================
sub _update_equal_hl {
    my ($self, $candles, $i, $size, %o) = @_;
    my $current_leg = _leg($candles, $i, $size);
    return unless defined $current_leg;
    my $prev_leg = ${ $o{prev_ref} };
    ${ $o{prev_ref} } = $current_leg;
    return if defined $prev_leg && $prev_leg == $current_leg;
    my $pivot_idx    = $i - $size;
    my $pivot_candle = $candles->[$pivot_idx];
    return unless $pivot_candle;
    my $atr = $o{atr} // 0;
    my $thr = $o{threshold} // DEFAULT_EQ_THRESHOLD;
    my $delta = defined $prev_leg ? ($current_leg - $prev_leg) : $current_leg;
    my $open_eq = $o{open_eq} // {};

    if ($delta > 0) {
        my $old  = ${ $o{low_ref} };
        my $nlvl = $pivot_candle->{low};
        if (defined $old && defined $old->{level} && $atr > 0) {
            if (abs($old->{level} - $nlvl) < $thr * $atr) {
                my $evt = {
                    kind        => 'EQL',
                    index       => $i,
                    swing_index => $pivot_idx,
                    level       => $nlvl,
                    prev_level  => $old->{level},
                    prev_index  => $old->{index},
                    # Req-3: campos de proyección (se completan en el pase)
                    start_index => $i,
                    end_index   => undef,   # se rellena cuando se detecta el cierre
                    is_open     => 1,
                };
                push @{ $self->{eql} }, $evt;
                $self->_push_event($i, $evt);
                # Req-3: registrar en HashMap O(1)
                my $key = 'EQL|' . sprintf('%.6f', $nlvl);
                $open_eq->{$key} //= [];
                push @{ $open_eq->{$key} }, $evt;
            }
        }
        ${ $o{low_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
    elsif ($delta < 0) {
        my $old  = ${ $o{high_ref} };
        my $nlvl = $pivot_candle->{high};
        if (defined $old && defined $old->{level} && $atr > 0) {
            if (abs($old->{level} - $nlvl) < $thr * $atr) {
                my $evt = {
                    kind        => 'EQH',
                    index       => $i,
                    swing_index => $pivot_idx,
                    level       => $nlvl,
                    prev_level  => $old->{level},
                    prev_index  => $old->{index},
                    start_index => $i,
                    end_index   => undef,
                    is_open     => 1,
                };
                push @{ $self->{eqh} }, $evt;
                $self->_push_event($i, $evt);
                my $key = 'EQH|' . sprintf('%.6f', $nlvl);
                $open_eq->{$key} //= [];
                push @{ $open_eq->{$key} }, $evt;
            }
        }
        ${ $o{high_ref} } = { level => $nlvl, index => $pivot_idx, crossed => 0 };
    }
}

# =============================================================================
# PRIVATE — _check_structure_break
# Req-2: `crossed=1` bloquea re-disparo pero NO oculta el nivel (permanente).
# Req-3: al emitir BOS/CHoCH cierra EQL/EQH abiertos cuyo nivel sea cruzado.
# =============================================================================
sub _check_structure_break {
    my ($self, $candles, $i, %o) = @_;
    my $c = $candles->[$i];
    return unless $c;
    my $close = $c->{close};
    return unless defined $close;
    my $scope     = $o{scope} // 'swing';
    my $trend_ref = $o{trend_ref};
    my $open_eq   = $o{open_eq} // {};
    my $bar_index = $o{bar_index} // $i;

    # ── Cruce BULLISH ─────────────────────────────────────────────────────────
    my $ph = ${ $o{high_ref} };
    if (defined $ph && defined $ph->{level} && !$ph->{crossed}) {
        if ($close > $ph->{level}) {
            my $kind = ($$trend_ref == _BEARISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BULLISH;
            $ph->{crossed} = 1;   # Req-2: sólo bloquea re-disparo, NO oculta

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bullish',
                index       => $i,
                level       => $ph->{level},
                swing_index => $ph->{index},
                swing_high  => 1,
                swing_low   => 0,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);

            # Req-3: cerrar EQL abiertos cuyo nivel quede por debajo del cierre
            _close_eq_below($open_eq, 'EQL', $close, $bar_index);
        }
    }

    # ── Cruce BEARISH ─────────────────────────────────────────────────────────
    my $pl = ${ $o{low_ref} };
    if (defined $pl && defined $pl->{level} && !$pl->{crossed}) {
        if ($close < $pl->{level}) {
            my $kind = ($$trend_ref == _BULLISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BEARISH;
            $pl->{crossed} = 1;   # Req-2: sólo bloquea re-disparo, NO oculta

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bearish',
                index       => $i,
                level       => $pl->{level},
                swing_index => $pl->{index},
                swing_high  => 0,
                swing_low   => 1,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);

            # Req-3: cerrar EQH abiertos cuyo nivel quede por encima del cierre
            _close_eq_above($open_eq, 'EQH', $close, $bar_index);
        }
    }
}

# =============================================================================
# PRIVATE — _close_eq_below / _close_eq_above
# Req-3: cierre de EQL/EQH en O(1) mediante HashMap.
# Se invoca SOLO cuando se confirma un BOS/CHoCH que cruza el nivel.
# =============================================================================
sub _close_eq_below {
    my ($open_eq, $kind, $close_price, $bar_index) = @_;
    for my $key (keys %$open_eq) {
        next unless $key =~ /^\Q$kind\E\|(.+)$/;
        my $lvl = $1 + 0;
        next unless $close_price > $lvl;   # el cierre superó el EQL → termina
        for my $evt (@{ $open_eq->{$key} || [] }) {
            next unless $evt->{is_open};
            $evt->{end_index} = $bar_index;
            $evt->{is_open}   = 0;
        }
        delete $open_eq->{$key};   # ya no está abierto
    }
}

sub _close_eq_above {
    my ($open_eq, $kind, $close_price, $bar_index) = @_;
    for my $key (keys %$open_eq) {
        next unless $key =~ /^\Q$kind\E\|(.+)$/;
        my $lvl = $1 + 0;
        next unless $close_price < $lvl;   # el cierre cayó bajo el EQH → termina
        for my $evt (@{ $open_eq->{$key} || [] }) {
            next unless $evt->{is_open};
            $evt->{end_index} = $bar_index;
            $evt->{is_open}   = 0;
        }
        delete $open_eq->{$key};
    }
}

# =============================================================================
# PRIVATE — helpers
# =============================================================================
sub _push_event {
    my ($self, $i, $evt) = @_;
    $self->{by_index}{$i} //= [];
    push @{ $self->{by_index}{$i} }, $evt;
}

sub _compute_atr {
    my ($candles, $last_idx, $period) = @_;
    return 1.0 if $last_idx < 1;
    my $start = $last_idx - $period + 1;
    $start = 1 if $start < 1;
    my ($sum, $count) = (0, 0);
    for my $i ($start .. $last_idx) {
        my $c  = $candles->[$i]     or next;
        my $cp = $candles->[$i - 1] or next;
        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl;
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
        $sum += $tr;
        $count++;
    }
    return $count > 0 ? $sum / $count : 1.0;
}

sub _high_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'HH'  if !defined $prev || $curr > $prev;
    return 'LH'  if $curr < $prev;
    return 'EQH';
}
sub _low_label {
    my ($prev, $curr) = @_;
    return '' unless defined $curr;
    return 'LL'  if !defined $prev || $curr < $prev;
    return 'HL'  if $curr > $prev;
    return 'EQL';
}

sub _bias_str {
    my ($b) = @_;
    return 'bullish' if defined $b && $b == _BULLISH;
    return 'bearish' if defined $b && $b == _BEARISH;
    return 'neutral';
}

1;

__END__

=pod

=head1 NAME

Market::Concepts::SMCStructureEngine — v2.1 con No-Mitigation y EQL/EQH Single-Pass

=head1 DESCRIPTION

v2.1 agrega dos comportamientos clave sobre v2.0:

=over 4

=item B<Req-2 — No-Mitigación>: HH/HL/LH/LL/BOS/CHoCH/EQH/EQL son permanentes.
C<crossed=1> solo bloquea el re-disparo del mismo nivel, pero el overlay debe
dibujarlos siempre como registro histórico.

=item B<Req-3 — EQL/EQH Single-Pass O(N)>: Al detectar un EQL/EQH se inserta
la referencia en el HashMap C<%open_eq>. Cuando un BOS/CHoCH posterior cruza
el nivel, el cierre se realiza en O(1). Los eventos llevan C<start_index>,
C<end_index> (undef si aún abierto) e C<is_open>.

=back

=cut
