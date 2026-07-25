package Market::Indicators::TrendLineChannel;

# =============================================================================
# Market::Indicators::TrendLineChannel
#
# Modelo de datos del canal de tendencia (Trend Line Channel), estilo
# TradingView. Soporta dos modos:
#
#   MANUAL: dibujo por el usuario con 3 clics.
#     Clic 1 (origen)     -> punto A (idx, price)
#     Clic 2 (horizontal) -> punto B (idx, price): define la PENDIENTE de la
#                            linea media (A -> B). Se previsualiza con una
#                            linea recta A->cursor mientras se mueve el mouse.
#     Clic 3 (vertical)   -> define el ANCHO del canal (desviacion en precio
#                            respecto a la linea media, medida en el punto C).
#                            Se previsualiza con las dos bandas mientras se
#                            mueve el mouse verticalmente.
#
#   AUTO: se reancla solo, sin clics del usuario, usando order blocks
#     (Market::Indicators::SMC_Structures2) y ATR:
#     - Punto A: el order block NO mitigado mas reciente, considerando
#       tanto order blocks SWING como INTERNAL de SMC_Structures2 (si hay
#       uno vigente en cada lista, gana el de mayor barIndex, es decir el
#       mas reciente en el tiempo -- ver _current_swing_anchor_ob).
#     - Punto B: pivote OPUESTO mas reciente entre A y la vela actual (si el
#       OB es 'bull' -> B es el HIGH maximo del tramo; si es 'bear' -> B es
#       el LOW minimo del tramo). No requiere un zigzag: es simplemente el
#       extremo del rango [A..actual].
#     - Ancho (deviation): ATR(200) del propio indicador ATR ya usado por
#       SMC_Structures2, multiplicado por un factor (por defecto 1.0).
#     - "Fugas": una racha de 1 a 5 velas consecutivas donde el precio queda
#       fuera de cualquiera de las dos bandas (high > banda_sup o
#       low < banda_inf) y luego el precio vuelve a quedar dentro cuenta
#       como UNA fuga (sin importar el lado). Al acumular 4 fugas, el canal
#       se considera invalidado y se REANCLA automaticamente al nuevo OB
#       swing no mitigado mas reciente (recalculando A, B, ancho y
#       reiniciando el contador de fugas a 0).
#
# Este modulo NO dibuja nada (eso es el Overlay). Solo guarda el estado
# geometrico y expone metodos para construir/editar el canal manual, y para
# recalcular el canal automatico velapor vela.
#
# API modo manual:
#   - start_at(idx, price)          -> arranca la construccion (clic 1)
#   - set_point_b(idx, price)       -> fija clic 2 (pendiente)
#   - set_deviation(idx, price)     -> fija clic 3 (ancho) y CIERRA el canal
#   - cancel_pending                -> aborta una construccion a medias
#
# Edicion posterior (drag, solo tiene sentido en modo manual):
#   - move_point_a(idx, price)
#   - move_point_b(idx, price)
#   - set_deviation_at(idx, price)  -> ancho segun drag directo de banda
#   - translate(d_idx, d_price)     -> mover todo el canal (arrastre del centro)
#
# API modo auto:
#   - set_mode('auto' | 'manual')
#   - set_auto_sources(smc_source, atr_source, market, %opts)
#   - update_at_index($md, $idx) / update_last($md)  -> recalculo incremental
#
# Contrato minimo esperado por el Overlay (ambos modos comparten formato):
#   - get_channel() -> undef | { ax, ay, bx, by, deviation, upper_off,
#                                 lower_off, slope, intercept }
#     (ax/ay = punto A; bx/by = punto B; idx en floats permitidos para que
#     el overlay pueda dibujar con precision sub-vela si se desea)
#   - get_pending() -> estado a medias durante la construccion MANUAL (para
#     que el overlay dibuje el preview): { stage => 1|2, ax, ay, bx?, by? }
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        mode => $args{mode} // 'manual',   # 'manual' | 'auto'

        # Estado de construccion en curso (mientras el usuario hace clic 1/2/3)
        _stage => 0,     # 0 = inactivo, 1 = esperando punto B, 2 = esperando desviacion
        _ax    => undef,
        _ay    => undef,
        _bx    => undef,
        _by    => undef,

        # Canal ya confirmado (clic 3 hecho, o calculado por el modo auto)
        _channel => undef,   # { ax, ay, bx, by, deviation }

        # --- Fuentes del modo AUTO (inyectadas via set_auto_sources) ---
        _smc_source => undef,   # Market::Indicators::SMC_Structures2 (order blocks)
        _atr_source => undef,   # Market::Indicators::ATR (ya en uso por SMC_Structures2)
        _market     => undef,   # Market::MarketData (velas)
        _atr_mult   => $args{atr_mult} // 1.0,

        # --- Estado de seguimiento del modo AUTO ---
        _auto_anchor_barindex => undef,   # barIndex del OB usado como ancla actual
        _auto_leak_count      => 0,       # fugas acumuladas contra el canal actual
        _auto_leak_run        => 0,       # velas consecutivas actuales fuera de banda (0 = dentro)
        _auto_leak_side       => undef,   # 'up' | 'down' -- lado de la racha en curso
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# reset: contrato generico de indicadores del proyecto.
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{_stage}   = 0;
    $self->{_ax}      = undef;
    $self->{_ay}      = undef;
    $self->{_bx}       = undef;
    $self->{_by}       = undef;
    $self->{_channel} = undef;

    $self->{_auto_anchor_barindex} = undef;
    $self->{_auto_leak_count}      = 0;
    $self->{_auto_leak_run}        = 0;
    $self->{_auto_leak_side}       = undef;
}

# -----------------------------------------------------------------------------
# Contrato IndicatorManager: en modo manual no hace nada (100% por clics).
# En modo auto, cada vela puede: (a) crear/reanclar el canal si no hay uno
# vigente, (b) detectar fugas y contar, (c) reanclar si se llega a 4 fugas.
# -----------------------------------------------------------------------------
sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    return unless $self->{mode} eq 'auto';
    $self->_auto_step($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    return unless $self->{mode} eq 'auto';
    my $idx = $self->{_market} ? $self->{_market}->last_index : undef;
    $idx = $self->_market_last_index unless defined $idx;
    $self->_auto_step($idx) if defined $idx;
}

sub get_values { return []; }

# -----------------------------------------------------------------------------
# calculate($market_data, %args) — contrato EngineRegistry de Kevin.
# En modo auto reconstruye el canal a partir de order blocks del cache.
# args:
#   orderblocks => resultado de OrderBlockEngine (blocks/active)
#   atr_indicator => ATR opcional (si no, usa ATR interno via velas)
# -----------------------------------------------------------------------------
sub calculate {
    my ( $self, $market_data, %args ) = @_;
    return {} unless $market_data;

    $self->{_market} = $market_data;

    my $ob_data = $args{orderblocks} || $args{orderblock} || {};
    my $adapter = Market::Indicators::TrendLineChannel::_OBAdapter->new($ob_data);
    $self->{_smc_source} = $adapter;
    $self->{_atr_source} = $args{atr_indicator} if $args{atr_indicator};

    if ( ($self->{mode} // 'auto') eq 'auto' ) {
        my $last = $market_data->can('size') ? $market_data->size - 1 : undef;
        if (defined $last && $last >= 0) {
            # Un solo paso en la ultima vela: el canal auto se deriva de los
            # OBs ya calculados (no hace falta simular fuga barra a barra
            # en cada rebuild de TF — eso era O(n^2) con _opposite_extreme).
            $self->{_auto_anchor_barindex} = undef;
            $self->{_channel} = undef;
            $self->{_auto_leak_count} = 0;
            $self->{_auto_leak_run} = 0;
            $self->_auto_step($last);
        }
    }

    my $ch = $self->get_channel;
    return {
        channel  => $ch,
        channels => $ch ? [ _channel_to_legacy($ch) ] : [],
        mode     => $self->{mode},
        metadata => {
            leak_count => $self->{_auto_leak_count},
            anchor     => $self->{_auto_anchor_barindex},
        },
    };
}

# Convierte el canal David (ax/ay/bx/by/deviation) al formato legacy del
# TrendChannelOverlay de Kevin (support/resistance pivots).
sub _channel_to_legacy {
    my ($ch) = @_;
    return undef unless $ch;
    my $dev = $ch->{deviation} // 0;
    my $slope = $ch->{slope} // 0;
    return {
        type  => $slope > 0.0001 ? 'ascending' : ($slope < -0.0001 ? 'descending' : 'horizontal'),
        state => 'active',
        support => {
            pivot1     => { index => $ch->{ax}, price => $ch->{ay} - $dev },
            pivot2     => { index => $ch->{bx}, price => $ch->{by} - $dev },
            end_index  => $ch->{bx},
            state      => 'active',
        },
        resistance => {
            pivot1     => { index => $ch->{ax}, price => $ch->{ay} + $dev },
            pivot2     => { index => $ch->{bx}, price => $ch->{by} + $dev },
            end_index  => $ch->{bx},
            state      => 'active',
        },
        slope_support    => $slope,
        slope_resistance => $slope,
        # Campos David nativos (overlay puede usarlos si estan)
        ax => $ch->{ax}, ay => $ch->{ay},
        bx => $ch->{bx}, by => $ch->{by},
        deviation => $dev,
        mid_a => $ch->{ay}, mid_b => $ch->{by},
    };
}

# Adaptador: expone get_swing/internal_order_blocks desde el cache de Kevin.
package Market::Indicators::TrendLineChannel::_OBAdapter;
sub new {
    my ($class, $ob_data) = @_;
    my @swing;
    my @internal;
    for my $b (@{ $ob_data->{active} || $ob_data->{blocks} || [] }) {
        next unless $b && ref $b eq 'HASH';
        # David mantiene OBs hasta mitigacion TOTAL. PartiallyMitigated sigue activo.
        my $st = $b->{state} // 'Detected';
        next if $st =~ /^(?:Mitigated|Invalidated)$/i;
        my $ob = {
            barIndex => $b->{index} // $b->{origin_index} // $b->{created_index},
            barHigh  => $b->{high},
            barLow   => $b->{low},
            bias     => (($b->{type} // '') eq 'bearish') ? 'bear' : 'bull',
        };
        next unless defined $ob->{barIndex};
        if (($b->{scope} // 'swing') eq 'internal') {
            push @internal, $ob;
        }
        else {
            push @swing, $ob;
        }
    }
    # Mas reciente primero (como unshift de David)
    @swing    = sort { ($b->{barIndex} // 0) <=> ($a->{barIndex} // 0) } @swing;
    @internal = sort { ($b->{barIndex} // 0) <=> ($a->{barIndex} // 0) } @internal;
    return bless { swing => \@swing, internal => \@internal }, $class;
}
sub get_swing_order_blocks    { return $_[0]->{swing}; }
sub get_internal_order_blocks { return $_[0]->{internal}; }

package Market::Indicators::TrendLineChannel;

# -----------------------------------------------------------------------------
# set_mode('auto'|'manual'): cambiar de modo. Al pasar a manual se limpia
# cualquier canal/estado auto (para no mezclar edicion manual sobre un
# canal que el motor auto seguia vigilando). Al pasar a auto se fuerza un
# recalculo inmediato del ancla si hay fuente disponible.
# -----------------------------------------------------------------------------
sub set_mode {
    my ( $self, $mode ) = @_;
    return unless $mode eq 'auto' || $mode eq 'manual';
    return if $self->{mode} eq $mode;
    $self->{mode} = $mode;

    if ( $mode eq 'manual' ) {
        $self->{_auto_anchor_barindex} = undef;
        $self->{_auto_leak_count}      = 0;
        $self->{_auto_leak_run}        = 0;
        $self->{_auto_leak_side}       = undef;
        $self->{_channel}              = undef;
    }
    else {
        $self->cancel_pending;
        $self->{_auto_anchor_barindex} = undef;   # fuerza reanclaje en el proximo _auto_step
        $self->{_auto_leak_count}      = 0;
        $self->{_auto_leak_run}        = 0;
        $self->{_auto_leak_side}       = undef;
        my $idx = $self->_market_last_index;
        $self->_auto_step($idx) if defined $idx;
    }
}

sub get_mode { return $_[0]->{mode}; }

# -----------------------------------------------------------------------------
# set_auto_sources: inyecta las fuentes que necesita el modo auto.
#   $smc_source: Market::Indicators::SMC_Structures2 (order blocks swing +
#                internal)
#   $atr_source: Market::Indicators::ATR ya usado por SMC_Structures2 (misma
#                escala: ATR(200) del propio Pine, reutilizado tal cual)
#   $market:     Market::MarketData (para leer velas por indice)
# -----------------------------------------------------------------------------
sub set_auto_sources {
    my ( $self, $smc_source, $atr_source, $market, %opts ) = @_;
    $self->{_smc_source} = $smc_source;
    $self->{_atr_source} = $atr_source;
    $self->{_market}     = $market;
    $self->{_atr_mult}   = $opts{atr_mult} if defined $opts{atr_mult};
}

# -----------------------------------------------------------------------------
# get_leak_count / get_auto_anchor: accesores informativos (utiles para UI o
# debug: cuantas fugas lleva el canal vigente, y que OB lo ancla).
# -----------------------------------------------------------------------------
sub get_leak_count  { return $_[0]->{_auto_leak_count}; }
sub get_auto_anchor { return $_[0]->{_auto_anchor_barindex}; }

# -----------------------------------------------------------------------------
# Construccion interactiva (clics)
# -----------------------------------------------------------------------------

# Clic 1: origen del canal. Reinicia cualquier construccion/canal previo.
sub start_at {
    my ( $self, $idx, $price ) = @_;
    return unless defined $idx && defined $price;
    $self->{_stage}   = 1;
    $self->{_ax}      = $idx;
    $self->{_ay}      = $price;
    $self->{_bx}      = undef;
    $self->{_by}       = undef;
    $self->{_channel} = undef;
}

# Clic 2: punto que define la pendiente de la linea media (A -> B).
sub set_point_b {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_stage} == 1;
    return unless defined $idx && defined $price;
    $self->{_bx}    = $idx;
    $self->{_by}    = $price;
    $self->{_stage} = 2;
}

# Clic 3: fija el ancho del canal (desviacion vertical) y lo confirma.
# $idx/$price = posicion del cursor en el momento del clic; la desviacion
# se calcula como la distancia vertical (en precio) entre ese punto y la
# linea media evaluada en su mismo indice.
sub set_deviation {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_stage} == 2;
    return unless defined $idx && defined $price;

    my $mid_price_at_idx = $self->_line_price_at( $self->{_ax}, $self->{_ay},
                                                    $self->{_bx}, $self->{_by}, $idx );
    my $deviation = abs( $price - $mid_price_at_idx );
    $deviation = 0.0001 if $deviation <= 0;   # evitar canal de ancho 0

    $self->{_channel} = {
        ax        => $self->{_ax},
        ay        => $self->{_ay},
        bx        => $self->{_bx},
        by        => $self->{_by},
        deviation => $deviation,
    };
    $self->{_stage} = 0;
    $self->{_ax} = $self->{_ay} = $self->{_bx} = $self->{_by} = undef;
}

# Aborta una construccion a medias (ESC). No toca un canal ya confirmado.
sub cancel_pending {
    my ($self) = @_;
    $self->{_stage} = 0;
    $self->{_ax} = $self->{_ay} = $self->{_bx} = $self->{_by} = undef;
}

sub is_building   { return $_[0]->{_stage} > 0; }
sub building_stage { return $_[0]->{_stage}; }

# -----------------------------------------------------------------------------
# Edicion posterior (drag de handles sobre un canal ya confirmado)
# -----------------------------------------------------------------------------

sub move_point_a {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    $self->{_channel}{ax} = $idx;
    $self->{_channel}{ay} = $price;
}

sub move_point_b {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    $self->{_channel}{bx} = $idx;
    $self->{_channel}{by} = $price;
}

# Ajusta el ancho arrastrando directamente una banda: $idx/$price es la
# posicion actual del cursor sobre esa banda.
sub set_deviation_at {
    my ( $self, $idx, $price ) = @_;
    return unless $self->{_channel};
    my $ch = $self->{_channel};
    my $mid_price_at_idx = $self->_line_price_at( $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by}, $idx );
    my $deviation = abs( $price - $mid_price_at_idx );
    $deviation = 0.0001 if $deviation <= 0;
    $ch->{deviation} = $deviation;
}

# Traslada el canal completo (arrastre del centro): desplaza A y B por igual.
sub translate {
    my ( $self, $d_idx, $d_price ) = @_;
    return unless $self->{_channel};
    my $ch = $self->{_channel};
    $ch->{ax} += $d_idx;
    $ch->{ay} += $d_price;
    $ch->{bx} += $d_idx;
    $ch->{by} += $d_price;
}

sub clear_channel {
    my ($self) = @_;
    $self->{_channel} = undef;
}

sub has_channel { return defined $_[0]->{_channel} ? 1 : 0; }

# -----------------------------------------------------------------------------
# Lectura para el Overlay
# -----------------------------------------------------------------------------

sub get_channel {
    my ($self) = @_;
    my $ch = $self->{_channel};
    return undef unless $ch;

    my ( $slope, $intercept ) = $self->_slope_intercept( $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by} );

    return {
        ax        => $ch->{ax},
        ay        => $ch->{ay},
        bx        => $ch->{bx},
        by        => $ch->{by},
        deviation => $ch->{deviation},
        slope     => $slope,
        intercept => $intercept,
        upper_off => $ch->{deviation},
        lower_off => -$ch->{deviation},
    };
}

# Estado a medias, para que el overlay dibuje el preview mientras se
# construye (junto con la posicion actual del cursor, que el overlay ya
# conoce via ChartEngine).
sub get_pending {
    my ($self) = @_;
    return undef unless $self->{_stage} > 0;
    return {
        stage => $self->{_stage},
        ax    => $self->{_ax},
        ay    => $self->{_ay},
        bx    => $self->{_bx},
        by    => $self->{_by},
    };
}

# -----------------------------------------------------------------------------
# Helpers geometricos internos
# -----------------------------------------------------------------------------
sub _slope_intercept {
    my ( $self, $ax, $ay, $bx, $by ) = @_;
    my $dx = $bx - $ax;
    if ( $dx == 0 ) {
        # Segmento vertical degenerado: pendiente 0 para no romper el render.
        return ( 0, $ay );
    }
    my $slope     = ( $by - $ay ) / $dx;
    my $intercept = $ay - $slope * $ax;
    return ( $slope, $intercept );
}

sub _line_price_at {
    my ( $self, $ax, $ay, $bx, $by, $idx ) = @_;
    my ( $slope, $intercept ) = $self->_slope_intercept( $ax, $ay, $bx, $by );
    return $slope * $idx + $intercept;
}

# -----------------------------------------------------------------------------
# _market_last_index: ultimo indice de vela disponible en $self->{_market}.
# MarketData no siempre expone last_index() en todos los puntos del
# codebase; se intenta ese metodo y se cae a get_slice/candle_count si hace
# falta, para no acoplarse a una unica firma.
# -----------------------------------------------------------------------------
sub _market_last_index {
    my ($self) = @_;
    my $md = $self->{_market};
    return undef unless $md;
    return $md->last_index      if $md->can('last_index');
    return $md->candle_count - 1 if $md->can('candle_count');
    return undef;
}

# =============================================================================
# MODO AUTO -- implementacion
# =============================================================================

# -----------------------------------------------------------------------------
# _auto_step: logica principal, se llama una vez por vela procesada.
#   1. Si no hay canal vigente (o el ancla actual ya no es el OB no
#      mitigado mas reciente), reancla desde cero.
#   2. Si hay canal vigente, evalua la vela actual contra las bandas para
#      llevar el conteo de "fugas" (rachas cortas fuera de banda).
#   3. Si se llega a 4 fugas, reancla (recalcula todo, contador a 0).
# -----------------------------------------------------------------------------
sub _auto_step {
    my ( $self, $idx ) = @_;
    return unless defined $idx;
    return unless $self->{_smc_source} && $self->{_market};

    my $anchor_ob = $self->_current_swing_anchor_ob;

    # Sin OB no mitigado disponible todavia: no hay nada que anclar.
    return unless $anchor_ob;

    my $anchor_changed =
        !defined $self->{_auto_anchor_barindex}
        || $self->{_auto_anchor_barindex} != $anchor_ob->{barIndex};

    if ( $anchor_changed || !$self->{_channel} ) {
        $self->_rebuild_auto_channel( $anchor_ob, $idx );
        return;
    }

    # Actualizar B y desviacion con cada vela (replay / live).
    my ( $bx, $by ) = $self->_opposite_extreme( $anchor_ob, $self->{_channel}{ax}, $idx );
    if ( defined $bx ) {
        $self->{_channel}{bx} = $bx;
        $self->{_channel}{by} = $by;
    }

    my $deviation = $self->_current_atr_deviation($idx);
    if ( defined $deviation && $deviation > 0 ) {
        $self->{_channel}{deviation} = $deviation;
    }

    # Refrescar pendiente/intercepto tras mover B (leak y render coherentes).
    my $ch = $self->{_channel};
    if ( defined $ch->{ax} && defined $ch->{bx} ) {
        my ( $slope, $intercept ) = $self->_slope_intercept(
            $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by},
        );
        $ch->{slope}     = $slope;
        $ch->{intercept} = $intercept;
        my $dev = $ch->{deviation} // 0;
        $ch->{upper_off} = $dev;
        $ch->{lower_off} = -$dev;
    }

    # Canal vigente y mismo ancla: evaluar fuga en la vela actual.
    $self->_evaluate_leak($idx);

    if ( $self->{_auto_leak_count} >= 4 ) {
        # 4ta fuga: se considera invalidado -> reanclar al OB no mitigado
        # mas reciente EN ESTE MOMENTO (puede ser el mismo si no hay otro
        # mas nuevo, o uno distinto si ya cambio).
        my $fresh_anchor = $self->_current_swing_anchor_ob;
        return unless $fresh_anchor;
        $self->_rebuild_auto_channel( $fresh_anchor, $idx );
    }
}

# -----------------------------------------------------------------------------
# _current_swing_anchor_ob: el OB NO mitigado mas reciente, considerando
# TANTO swing order blocks COMO internal order blocks (SMC_Structures2 los
# mantiene en listas separadas, cada una ya filtrada -- un OB se elimina de
# su lista en cuanto se mitiga, ver _delete_order_blocks). Ambas listas se
# insertan con unshift (mas nuevo primero), asi que el candidato de cada
# lista es simplemente su primer elemento; entre esos dos candidatos gana
# el de mayor barIndex (el mas reciente en el tiempo).
# -----------------------------------------------------------------------------
sub _current_swing_anchor_ob {
    my ($self) = @_;
    my $src = $self->{_smc_source};
    return undef unless $src;

    my $swing_ob = undef;
    if ( $src->can('get_swing_order_blocks') ) {
        my $obs = $src->get_swing_order_blocks;
        $swing_ob = $obs->[0] if $obs && @$obs;
    }

    my $internal_ob = undef;
    if ( $src->can('get_internal_order_blocks') ) {
        my $obs = $src->get_internal_order_blocks;
        $internal_ob = $obs->[0] if $obs && @$obs;
    }

    return $swing_ob    unless $internal_ob;
    return $internal_ob unless $swing_ob;
    return $internal_ob->{barIndex} >= $swing_ob->{barIndex} ? $internal_ob : $swing_ob;
}

# -----------------------------------------------------------------------------
# _rebuild_auto_channel: recalcula A, B y el ancho a partir de un OB ancla,
# y reinicia el contador de fugas.
#   A = (barIndex del OB, precio del OB: barLow si 'bull', barHigh si 'bear')
#   B = pivote opuesto = extremo (high si 'bull', low si 'bear') entre A y
#       la vela actual, SIN exigir que sea un pivote fractal confirmado.
#   deviation = ATR(200) en la vela actual * atr_mult.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# _rebuild_auto_channel: recalcula A, B y el ancho a partir de un OB ancla,
# y reinicia el contador de fugas.
#   A = (barIndex del OB, precio del OB: barLow si 'bull', barHigh si 'bear')
#   B = pivote opuesto = extremo (high si 'bull', low si 'bear') entre A y
#       la vela actual, SIN exigir que sea un pivote fractal confirmado.
#   deviation = ATR(200) en la vela actual * atr_mult.
# -----------------------------------------------------------------------------
sub _rebuild_auto_channel {
    my ( $self, $ob, $idx ) = @_;

    my $ax = $ob->{barIndex};
    my $ay = $ob->{bias} eq 'bull' ? $ob->{barLow} : $ob->{barHigh};
    return if $ax > $idx;   # ancla mas nueva que la vela actual: nada que hacer aun

    my ( $bx, $by ) = $self->_opposite_extreme( $ob, $ax, $idx );
    return unless defined $bx;   # todavia no hay suficiente rango para un B valido

    my $deviation = $self->_current_atr_deviation($idx);
    return unless defined $deviation && $deviation > 0;

    my ( $slope, $intercept ) = $self->_slope_intercept( $ax, $ay, $bx, $by );

    $self->{_channel} = {
        ax        => $ax,
        ay        => $ay,
        bx        => $bx,
        by        => $by,
        deviation => $deviation,
        slope     => $slope,
        intercept => $intercept,
        upper_off => $deviation,
        lower_off => -$deviation,
    };
    $self->{_auto_anchor_barindex} = $ax;
    $self->{_auto_leak_count}      = 0;
    $self->{_auto_leak_run}        = 0;
    $self->{_auto_leak_side}       = undef;
}

# -----------------------------------------------------------------------------
# _opposite_extreme: dado el OB ancla, busca en [ax..idx] el extremo
# opuesto (high maximo si el OB es 'bull'; low minimo si es 'bear').
# Devuelve (bx, by) o (undef, undef) si no hay velas suficientes.
# -----------------------------------------------------------------------------
sub _opposite_extreme {
    my ( $self, $ob, $ax, $idx ) = @_;
    return ( undef, undef ) if $idx <= $ax;

    my $md = $self->{_market};
    my ( $best_idx, $best_val );

    for my $k ( ( $ax + 1 ) .. $idx ) {
        my $c = $md->get_candle($k);
        next unless defined $c;
        if ( $ob->{bias} eq 'bull' ) {
            if ( !defined $best_val || $c->{high} > $best_val ) {
                $best_val = $c->{high};
                $best_idx = $k;
            }
        }
        else {
            if ( !defined $best_val || $c->{low} < $best_val ) {
                $best_val = $c->{low};
                $best_idx = $k;
            }
        }
    }
    return ( undef, undef ) unless defined $best_idx;
    return ( $best_idx, $best_val );
}

# -----------------------------------------------------------------------------
# _current_atr_deviation: ATR(200) en la vela $idx, multiplicado por
# atr_mult. Usa el mismo Indicators::ATR ya alimentado por SMC_Structures2
# (misma escala/periodo, sin duplicar calculo).
# -----------------------------------------------------------------------------
sub _current_atr_deviation {
    my ( $self, $idx ) = @_;
    my $atr_src = $self->{_atr_source};
    if ( $atr_src && $atr_src->can('get_values') ) {
        my $values = $atr_src->get_values;
        if ( $values && @$values ) {
            my $v = $values->[$idx];
            $v = $values->[-1] unless defined $v;
            return $v * $self->{_atr_mult} if defined $v && $v > 0;
        }
    }
    # Fallback: ATR simple sobre MarketData (cuando no hay ATR inyectado)
    return $self->_fallback_atr_deviation($idx);
}

sub _fallback_atr_deviation {
    my ( $self, $idx ) = @_;
    my $md = $self->{_market};
    return undef unless $md && $idx >= 1;
    my $period = 200;
    my $from = $idx - $period + 1;
    $from = 1 if $from < 1;
    my ( $sum, $n ) = ( 0, 0 );
    for my $k ( $from .. $idx ) {
        my $c  = $md->get_candle($k)     or next;
        my $cp = $md->get_candle($k - 1) or next;
        my $tr = $c->{high} - $c->{low};
        my $hc = abs( $c->{high} - $cp->{close} );
        my $lc = abs( $c->{low}  - $cp->{close} );
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
        $sum += $tr;
        $n++;
    }
    return undef unless $n > 0;
    return ( $sum / $n ) * ( $self->{_atr_mult} // 1.0 );
}

# -----------------------------------------------------------------------------
# _evaluate_leak: revisa la vela $idx contra las bandas del canal vigente
# y lleva el conteo de "fugas" (racha de 1 a 5 velas fuera de banda que
# luego vuelve adentro).
#
# Criterio de "fuera de banda": high > banda_superior en $idx, o
# low < banda_inferior en $idx (no importa el lado, cuentan igual).
#
# Se lleva una racha (_auto_leak_run): mientras la vela siga fuera, la
# racha crece. En cuanto una vela vuelve a estar dentro:
#   - si la racha tenia entre 1 y 5 velas -> se cuenta como 1 fuga
#     (_auto_leak_count++)
#   - si la racha supero 5 velas -> NO se cuenta como fuga (se considera
#     ruptura real, no un pico corto); simplemente se descarta la racha
#     sin sumar al contador.
# -----------------------------------------------------------------------------
sub _evaluate_leak {
    my ( $self, $idx ) = @_;
    my $ch = $self->{_channel};
    return unless $ch;

    my $md = $self->{_market};
    my $c  = $md->get_candle($idx);
    return unless defined $c;

    # Derivar bandas desde ax/ay/bx/by (no confiar en slope cacheado stale).
    my ( $slope, $intercept ) = $self->_slope_intercept(
        $ch->{ax}, $ch->{ay}, $ch->{bx}, $ch->{by},
    );
    my $dev   = $ch->{deviation} // 0;
    my $upper = $slope * $idx + $intercept + $dev;
    my $lower = $slope * $idx + $intercept - $dev;

    my $outside = ( $c->{high} > $upper ) || ( $c->{low} < $lower );

    if ($outside) {
        $self->{_auto_leak_run}++;
    }
    else {
        if ( $self->{_auto_leak_run} >= 1 && $self->{_auto_leak_run} <= 5 ) {
            $self->{_auto_leak_count}++;
        }
        $self->{_auto_leak_run} = 0;
    }
}

1;