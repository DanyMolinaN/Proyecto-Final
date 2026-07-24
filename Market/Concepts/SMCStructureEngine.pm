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
    DEFAULT_CONFIRM_MODE    => 'close',   # 'close' | 'wick' (High/Low)
};

sub new {
    my ($class, %args) = @_;
    my $self = {
        swing_length    => $args{swing_length}    // DEFAULT_SWING_LENGTH,
        internal_length => $args{internal_length} // DEFAULT_INTERNAL_LENGTH,
        eq_length       => $args{eq_length}       // DEFAULT_EQ_LENGTH,
        eq_threshold    => $args{eq_threshold}    // DEFAULT_EQ_THRESHOLD,
        confirm_mode    => ( ( $args{confirm_mode} // DEFAULT_CONFIRM_MODE ) eq 'wick' ) ? 'wick' : 'close',

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

    # Tramo provisional del ZigZag (externo/interno): desde el ultimo pivote
    # confirmado hasta el extremo vivo de la pierna abierta. Sin esto el overlay
    # corta la linea en el ultimo swing confirmado (lag de swing_length).
    my $zigzag_tentative = {
        external => _tentative_segment(\@candles, $last_index, $self->{swing_highs}, $self->{swing_lows}),
        internal => _tentative_segment(\@candles, $last_index, $self->{internal_highs}, $self->{internal_lows}),
    };

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
        zigzag_tentative    => $zigzag_tentative,
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

# Modulos SRP de Market::Concepts::SMCStructureEngine (misma API).
require 'Market/Concepts/SMCStructureEngine/Tentative.pm';
require 'Market/Concepts/SMCStructureEngine/Pivots.pm';
require 'Market/Concepts/SMCStructureEngine/Breaks.pm';
require 'Market/Concepts/SMCStructureEngine/Utils.pm';

1;