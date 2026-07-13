package Market::Indicators::ZigZagMTF;

# =============================================================================
# Market::Indicators::ZigZagMTF
#
# ZigZag Multi Time Frame (equivalente a "ZigZag Multi Time Frame with
# Fibonacci Retracement [ZZMTF]" de TradingView, sin el bloque de Fibonacci).
# Detecta la DIRECCION INTERNA del precio: remuestrea las velas base (1m) a
# bloques OHLC de una temporalidad superior configurable (15/30/60 min,
# equivalente a request.security() en Pine) y corre un zigzag CLASICO por
# periodo (no ATR, no filtro de desplazamiento) sobre esas velas agregadas.
#
# Deliberadamente NO reutiliza Indicators::Liquidity: el enfoque de esta
# familia de indicadores es distinto (period fijo estilo ta.pivothigh /
# ta.pivotlow de Pine, sin filtros de volatilidad), tal como especifica el
# material de referencia. Ambos criterios pueden coexistir en el sistema.
#
# -----------------------------------------------------------------------------
# REMUESTREO (OHLC agregado real, no ventana de suavizado)
#
#   Las velas base (temporalidad del grafico, tipicamente 1m) se agrupan en
#   bloques de $resolution_minutes usando el timestamp de cada vela para
#   determinar a que bloque pertenece (floor(ts / (resolution*60))). Cada
#   bloque agregado:
#     open  = open  de la PRIMERA vela base del bloque
#     high  = high  MAXIMO entre todas las velas base del bloque
#     low   = low   MINIMO entre todas las velas base del bloque
#     close = close de la ULTIMA vela base del bloque (o la ultima conocida
#             hasta el momento, si el bloque aun esta en curso -- anti-futuro)
#     index_end = indice (en la temporalidad base) de la ULTIMA vela base
#             incorporada a este bloque hasta ahora; es la referencia que se
#             usa para ubicar el pivote en el eje X del grafico base.
#
#   Un bloque se considera "cerrado" (elegible para deteccion de pivote)
#   solo cuando llega la PRIMERA vela base del bloque SIGUIENTE. Esto evita
#   procesar un bloque agregado incompleto (anti-futuro: nunca se usa el
#   supuesto cierre de un bloque que todavia esta en curso).
#
# -----------------------------------------------------------------------------
# ZIGZAG CLASICO POR PERIODO (estilo ta.pivothigh/ta.pivotlow)
#
#   Sobre la serie de velas agregadas (bloques cerrados), un bloque en el
#   indice $t (indice DENTRO de la serie agregada) es:
#     Pivote Alto si High[t] > High[t-i] y High[t] > High[t+i] para todo
#       i en [1, period] (period = leftbars = rightbars).
#     Pivote Bajo si Low[t]  < Low[t-i]  y Low[t]  < Low[t+i]  para todo
#       i en [1, period].
#
#   Sin filtro ATR ni de desplazamiento: la unica regla de limpieza es la
#   ALTERNANCIA ESTRICTA (ver _consolidate): si el nuevo pivote es del mismo
#   tipo que el ultimo pivote confirmado, solo sobrevive el mas extremo
#   (reemplaza al anterior); si es de tipo opuesto, se agrega a la secuencia.
#   Este es el mismo mecanismo de alternancia ya validado en Liquidity.pm.
#
# -----------------------------------------------------------------------------
# SALIDA PARA EL OVERLAY
#
#   get_segments(): lista de segmentos [{from index_base, to index_base,
#   from_price, to_price, dir=>'up'|'down'}] ya mapeados a indices de la
#   temporalidad BASE del grafico (no de la agregada), listos para dibujar
#   como polilinea verde/roja (direccion interna).
# =============================================================================

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        resolution_minutes => $args{resolution_minutes} // 30,   # 15 | 30 | 60
        period             => $args{period}             // 2,    # ZigZag Period

        _c => [],   # velas base procesadas (temporalidad del grafico)

        # Bloque agregado EN CURSO (aun no cerrado).
        # { bucket_id, open, high, low, close, index_start, index_end }
        _current_bucket => undef,

        # Velas agregadas ya CERRADAS, en orden cronologico.
        # { bucket_id, open, high, low, close, index_start, index_end }
        _agg => [],

        # Pivotes confirmados sobre la serie agregada (mismo formato que
        # Liquidity::_swings): { id, index (en _agg), kind=>'H'|'L', price }
        _pivots => [],
        _next_id => 1,

        # Segmentos ya materializados para el overlay (recalculados de forma
        # incremental cada vez que cambia _pivots).
        _segments => [],
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c} = [];
    $self->{_current_bucket} = undef;
    $self->{_agg}     = [];
    $self->{_pivots}  = [];
    $self->{_next_id} = 1;
    $self->{_segments} = [];
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->_ingest($idx, $c);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->_ingest($idx, $c);
}

sub get_pivots   { return $_[0]->{_pivots}; }
sub get_segments { return $_[0]->{_segments}; }

# -----------------------------------------------------------------------------
# get_swings: pivotes confirmados (mismo criterio de alternancia estricta que
# antes vivia en Indicators::Liquidity), pero ya mapeados al indice de la
# temporalidad BASE del grafico (index_base), listos para que cualquier
# overlay (Liquidity, SMC_Structures, etc.) los dibuje sin recalcular nada.
# Formato: { id, index => index_base, kind => 'H'|'L', price }
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# get_trendline: polilinea cronologica de TODOS los pivotes confirmados
# (highs y lows intercalados), ya mapeados a indice base. Reemplaza la
# trendline que antes construia Indicators::Liquidity a partir de sus swings
# crudos (fractal_n + ATR); ahora se basa en la direccion interna del
# ZigZagMTF, consistente con get_swings() de arriba.
# -----------------------------------------------------------------------------
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


# -----------------------------------------------------------------------------
# get_tentative_segment: tramo PROVISIONAL desde el ultimo pivote consolidado
# hasta la vela base mas reciente conocida. No es un pivote confirmado (no
# paso por fractalidad ni alternancia): es solo una guia visual para que la
# linea del zigzag no se quede "cortada" varias velas antes del borde
# derecho del grafico mientras el ultimo bloque agregado sigue en curso o
# el pivote mas reciente aun no se confirma (demora estructural minima de
# (period+1) * resolution_minutes). Se recalcula en cada llamada -- no se
# persiste como parte de _segments ni de _pivots.
#
# Devuelve undef si no hay al menos un pivote confirmado, o si no hay velas
# base conocidas mas alla de ese pivote.
# -----------------------------------------------------------------------------
sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_pivot_base_idx = $self->_base_index_for_pivot($last_pivot);

    my $last_base_idx = $#{ $self->{_c} };
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

# -----------------------------------------------------------------------------
# _ingest: incorpora una vela base, la asigna a su bloque agregado, cierra
# el bloque anterior si corresponde, e intenta confirmar pivotes nuevos.
# -----------------------------------------------------------------------------
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
        $cur->{close} = $c->{close};
        $cur->{index_end} = $idx;
        return;
    }

    # Llego la primera vela de un bloque nuevo: el bloque anterior se cierra.
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
        high_index  => $idx,   # vela base EXACTA donde ocurrio el high del bloque
        low_index   => $idx,   # vela base EXACTA donde ocurrio el low del bloque
    };
}

sub _bucket_id_for {
    my ( $self, $c ) = @_;
    my $secs = $self->{resolution_minutes} * 60;
    return int( $c->{ts} / $secs );
}
# -----------------------------------------------------------------------------
# _try_confirm_pivot: evalua fractalidad estilo ta.pivothigh/pivotlow sobre
# la serie agregada ($self->{_agg}).
# CORRECCIÓN: Manejo de "Outside Bars" para evitar viajes en el tiempo (forma de Z).
# -----------------------------------------------------------------------------
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

    # --- NUEVA LÓGICA DE CONSOLIDACIÓN CRONOLÓGICA ---
    if ($is_high && $is_low) {
        # ¡Vela Envolvente! El bloque gigante rompió por arriba y por abajo.
        # Ordenamos la inserción viendo qué índice base ocurrió primero.
        if ($agg->[$t]{high_index} < $agg->[$t]{low_index}) {
            # El techo se formó antes que el suelo
            $self->_consolidate( $t, 'H', $agg->[$t]{high} );
            $self->_consolidate( $t, 'L', $agg->[$t]{low} );
        } else {
            # El suelo se formó antes que el techo
            $self->_consolidate( $t, 'L', $agg->[$t]{low} );
            $self->_consolidate( $t, 'H', $agg->[$t]{high} );
        }
    } else {
        # Flujo normal: solo uno de los dos, o ninguno, es verdadero
        $self->_consolidate( $t, 'H', $agg->[$t]{high} ) if $is_high;
        $self->_consolidate( $t, 'L', $agg->[$t]{low} )  if $is_low;
    }
}

# -----------------------------------------------------------------------------
# _consolidate: alternancia estricta ZigZag (identico criterio al usado en
# Liquidity.pm) -- si el nuevo pivote es del mismo tipo que el ultimo de la
# secuencia, solo sobrevive el mas extremo; si es opuesto, se agrega.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# _rebuild_segments: reconstruye la lista de segmentos para el overlay,
# mapeando cada pivote (indice en la serie agregada) al indice REAL de la
# temporalidad base donde ocurrio ese extremo especifico -- high_index para
# pivotes 'H', low_index para pivotes 'L' -- NUNCA index_end (esa era la
# causa del desfase visual: index_end es la ULTIMA vela del bloque de 30min,
# que casi nunca coincide con la vela exacta donde se registro el maximo o
# minimo real dentro de ese bloque).
# -----------------------------------------------------------------------------
sub _rebuild_segments {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    my $agg    = $self->{_agg};
    my @segments;

    for my $i ( 1 .. $#$pivots ) {
        my $prev = $pivots->[ $i - 1 ];
        my $cur  = $pivots->[$i];

        my $prev_base_idx = $self->_base_index_for_pivot($prev);
        my $cur_base_idx  = $self->_base_index_for_pivot($cur);

        push @segments, {
            from_index => $prev_base_idx,
            to_index   => $cur_base_idx,
            from_price => $prev->{price},
            to_price   => $cur->{price},
            dir        => ( $cur->{price} > $prev->{price} ) ? 'up' : 'down',
        };
    }
    $self->{_segments} = \@segments;
}

# -----------------------------------------------------------------------------
# _base_index_for_pivot: dado un pivote (indice en la serie agregada + kind),
# devuelve el indice de la temporalidad BASE donde realmente ocurrio ese
# extremo de precio dentro del bloque agregado correspondiente.
# -----------------------------------------------------------------------------
sub _base_index_for_pivot {
    my ( $self, $pivot ) = @_;
    my $bucket = $self->{_agg}[ $pivot->{index} ];
    return $pivot->{kind} eq 'H' ? $bucket->{high_index} : $bucket->{low_index};
}

1;