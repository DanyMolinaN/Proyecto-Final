package Market::Indicators::Liquidity;

# =============================================================================
# Market::Indicators::Liquidity
#
# Deteccion y filtrado de Puntos de Giro (Swings), mas la Linea de Tendencia
# construida a partir de la secuencia combinada de swings (highs y lows
# intercalados, sin distincion de tipo para trazar la polilinea).
#
# NOTA: la clasificacion de estructura HH/HL/LH/LL fue removida de este
# modulo. Esa logica ahora vive, mejorada, en Indicators::SMC_Structures
# (consume los pivotes de ZigZagMTF). Este modulo solo entrega swings
# crudos filtrados por ATR + desplazamiento; no clasifica ni etiqueta.
#
# No incluye Order Blocks, FVG ni logica de dibujo: esto es SOLO calculo.
# El overlay (Overlays/Liquidity.pm) lee get_swings / get_trendline y dibuja.
#
# -----------------------------------------------------------------------------
# PIPELINE (por cada swing base candidato):
#
#   1. FRACTALIDAD (deteccion base)
#        Maximo swing base en t: High[t] > High[t-i] y High[t] > High[t+i]
#        Minimo swing base en t: Low[t]  < Low[t-i]  y Low[t]  < Low[t+i]
#        para todo i en [1, N] (N = fractal_n).
#        La vela t solo puede confirmarse cuando ya se conocen N velas
#        posteriores (t+N) -> confirmacion retrasada, cero look-ahead real
#        en el sentido de que el swing no se usa/expone hasta ese momento.
#
#   2. FILTRO 1: VOLATILIDAD ATR (ruido de mercados laterales)
#        Un swing base solo se CONSOLIDA si la distancia vertical entre el
#        nuevo swing y el ULTIMO SWING CONSOLIDADO DEL TIPO OPUESTO es
#        estrictamente mayor que (m_ATR * ATR[t]).
#        Si no la cumple, se descarta como ruido (no pasa a la fase 2).
#
#   3. FILTRO 2: DESPLAZAMIENTO / MOMENTUM (huella institucional)
#        Tras pasar el filtro ATR, el swing queda "pendiente de
#        confirmacion por desplazamiento": dentro de las V_desp velas
#        siguientes al pivote, el precio debe recorrer al menos
#        (U_desp * ATR[t]) en contra del pivote (hacia abajo si es
#        maximo, hacia arriba si es minimo). Si V_desp velas pasan sin
#        lograrlo, el swing se descarta definitivamente. Mientras el
#        swing esta pendiente, NO se expone ni se usa para clasificar.
#
#   4. ALTERNANCIA ESTRICTA (ZigZag)
#        La secuencia de swings consolidados debe alternar SIEMPRE H-L-H-L...
#        Si el nuevo swing es del MISMO tipo que el ultimo swing consolidado:
#          - Si es MAS EXTREMO (High mayor, o Low menor) que ese ultimo swing,
#            LO REEMPLAZA (el anterior se descarta: era un maximo/minimo
#            intermedio, no el extremo real del tramo).
#          - Si NO es mas extremo, el nuevo candidato se descarta y el
#            anterior se mantiene.
#        Solo cuando el nuevo swing es de tipo OPUESTO al ultimo consolidado
#        se agrega como swing nuevo en la secuencia.
#
#   5. TREND LINE
#        Polilinea construida con TODOS los swings consolidados (highs y
#        lows intercalados por indice/tiempo, sin distinguir tipo), en
#        el orden en que fueron confirmados.
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        atr           => $args{atr},              # Indicators::ATR (get_values)
        source        => $args{source},
        zzmtf         => $args{zzmtf},   # Indicators::ZigZagMTF
        zzvp          => $args{zzvp},
        fractal_n     => $args{fractal_n} // $args{k} // 3,   # N velas a cada lado
        m_atr         => $args{m_atr}     // 1.5,  # multiplicador filtro volatilidad
        atr_period    => $args{atr_period}// 14,   # informativo (el ATR ya trae su periodo)
        v_desp        => $args{v_desp}    // 10,   # ventana max. de velas para el impulso
        u_desp        => $args{u_desp}    // 2.0,  # multiplicador ATR de recorrido minimo

        eq_factor     => $args{eq_factor}    // 0.10,
        grab_window   => $args{grab_window}  // 3,
        acceptance_n  => $args{acceptance_n} // 10,

        level_min_dist_atr => $args{level_min_dist_atr} // 0.5,  # distancia minima (x ATR) entre niveles activos del mismo lado
        level_expiry_n     => $args{level_expiry_n}     // 80,   # velas tras las cuales un nivel DETECTED no tocado expira
        eq_lookback        => $args{eq_lookback}        // 30,

        _c   => [],   # velas conocidas (indice = indice de vela global)
        _atr => [],   # cache local de get_values() del ATR, se refresca cada update

        # Candidatos fractales brutos, a la espera de N velas futuras para
        # confirmar fractalidad. { index, kind => 'H'|'L', price }
        _pending_fractal => [],

        # Candidatos que pasaron fractalidad + filtro ATR, a la espera de
        # desplazamiento dentro de v_desp velas.
        # { index, kind, price, deadline, extreme }
        _pending_displacement => [],

        # Swings totalmente consolidados (pasaron los 2 filtros), en orden
        # cronologico. Cada uno: { id, index, ts, kind => 'H'|'L', price }
        _swings => [],
        _next_id => 1,

        # Ultimo swing consolidado por tipo (para filtro ATR y clasificacion)
        _last_H => undef,   # { index, price }
        _last_L => undef,

        # Linea de tendencia: puntos [{index, price}], un punto por swing
        # consolidado, en orden cronologico (highs y lows intercalados).
        _trendline => [],

        # BSL/SSL, EQH/EQL, eventos (Sweep/Grab/Run): mantenidos para
        # compatibilidad con el overlay existente. Fase de liquidez pura
        # (no SMC) se limita aqui a estructura + swings; estos quedan
        # vacios/placeholder hasta que se aborde esa fase por separado.
        _levels => [],
        _equals => [],
        _events => [],
        _open_level_refs => [],
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_c}   = [];
    $self->{_atr} = [];
    $self->{_pending_fractal}      = [];
    $self->{_pending_displacement} = [];
    $self->{_swings}  = [];
    $self->{_next_id} = 1;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    $self->{_trendline} = [];
    $self->{_levels} = [];
    $self->{_equals} = [];
    $self->{_events} = [];
    $self->{_open_level_refs} = [];
}

sub get_values { return []; }

sub calculate {
    my ($self, $md, %args) = @_;
    $self->reset();
    my $size = $md->size();
    for my $i (0 .. $size - 1) {
        $self->update_at_index($md, $i);
    }
    my $levels = $self->get_levels();
    return {
        swings           => $self->get_swings(),
        trendline        => $self->get_trendline(),
        levels           => $levels,
        liquidity_levels => $levels,       # alias: overlay reads this key
        events           => $self->get_events(),
        eq_levels        => [],
        metadata         => {
            tolerance => _compute_tolerance($self),
        },
    };
}

# _compute_tolerance: aproxima la tolerancia ATR promedio para metadata.
# Usa el ATR del ultimo swing consolidado si esta disponible.
sub _compute_tolerance {
    my ($self) = @_;
    my $arr = $self->{_atr};
    return 1e-6 unless $arr && ref($arr) eq 'ARRAY' && @$arr;
    my $last = $arr->[-1];
    return defined $last && $last > 0 ? $last : 1e-6;
}


# -----------------------------------------------------------------------------
# Accesores de solo lectura para overlays / SMC_Structures.
# -----------------------------------------------------------------------------
sub get_swings       { return $_[0]->{_swings}; }
sub get_trendline    { return $_[0]->{_trendline}; }
sub get_levels       { return $_[0]->{_levels}; }
sub get_equals       { return $_[0]->{_equals}; }
sub get_events       { return $_[0]->{_events}; }

sub side_label {
    my ( $self, $side ) = @_;
    return $side eq 'buy' ? 'BSL' : 'SSL';
}

sub is_internal {
    my ( $self, $level, $current_tf ) = @_;
    return 1 unless defined $level->{origin_tf};
    return $level->{origin_tf} eq $current_tf ? 1 : 0;
}

sub last_swing_high {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'H';
    }
    return undef;
}

sub last_swing_low {
    my ($self) = @_;
    for ( my $i = $#{ $self->{_swings} }; $i >= 0; $i-- ) {
        my $s = $self->{_swings}[$i];
        return { index => $s->{index}, price => $s->{price} } if $s->{kind} eq 'L';
    }
    return undef;
}

# -----------------------------------------------------------------------------
# update_at_index / update_last: contrato del IndicatorManager.
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_ingest($md, $c, $idx);
    $self->_sync_levels_from_internal_zigzag($md);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $md->last_index if $md->can('last_index');
    my $c   = $md->last_candle;
    return unless defined $c;
    $idx = $#{ $self->{_c} } + 1 unless defined $idx;
    $self->_ingest($md, $c, $idx);
}

# Modulos SRP (misma API).
require 'Market/Indicators/Liquidity/Fractals.pm';
require 'Market/Indicators/Liquidity/SwingStore.pm';
require 'Market/Indicators/Liquidity/StateMachine.pm';

1;
