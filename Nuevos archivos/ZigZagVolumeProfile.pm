package Market::Indicators::ZigZagVolumeProfile;

use strict;
use warnings;

# =============================================================================
# Market::Indicators::ZigZagVolumeProfile (ZZVP) - Refactorizado Fase 2
# 
# Motor de Dirección Externa Macro. Utiliza una Máquina de Estados Finita y 
# una desviación porcentual para filtrar el ruido (micro-tendencias). Los
# perfiles de volumen (POC) solo se calculan cuando se confirma el cierre 
# de un segmento institucional, optimizando el rendimiento computacional.
# =============================================================================

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        # CAMBIO 1: Reemplazamos 'period' por 'deviation_pct'. 
        # Un 0.5% a 1.0% asegura que solo capte movimientos macro.
        deviation_pct => $args{deviation_pct} // 1, 
        bins          => $args{bins}          // 10,
        max_profiles  => $args{max_profiles}  // 15,

        _c => [],
        _pivots  => [],
        _next_id => 1,
        _segments => [],
        _profiles => [],

        # CAMBIO 2: Variables para la Máquina de Estados Finita
        _state         => 'INIT', # Estados: INIT, BUSCANDO_MAXIMO, BUSCANDO_MINIMO
        _last_extreme  => undef,
        _extreme_idx   => -1,
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}         = [];
    $self->{_pivots}    = [];
    $self->{_next_id}   = 1;
    $self->{_segments}  = [];
    $self->{_profiles}  = [];
    
    $self->{_state}        = 'INIT';
    $self->{_last_extreme} = undef;
    $self->{_extreme_idx}  = -1;
}

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    my $c = $md->get_candle($idx);
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

sub update_last {
    my ( $self, $md ) = @_;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->_process_candle($idx);
}

sub get_pivots   { return $_[0]->{_pivots}; }
sub get_segments { return $_[0]->{_segments}; }
sub get_profiles { return $_[0]->{_profiles}; }

# -----------------------------------------------------------------------------
# Tramo provisional para el renderizado (sin cambios, funcional)
# -----------------------------------------------------------------------------
sub get_tentative_segment {
    my ($self) = @_;
    my $pivots = $self->{_pivots};
    return undef unless @$pivots;

    my $last_pivot = $pivots->[-1];
    my $last_base_idx = $#{ $self->{_c} };
    return undef if $last_base_idx <= $last_pivot->{index};
    
    my $c = $self->{_c};
    my $extreme_price = undef;
    my $extreme_idx   = $last_base_idx;

    for my $i ( $last_pivot->{index} + 1 .. $last_base_idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;

        if ( $last_pivot->{kind} eq 'L' ) {
            if ( !defined($extreme_price) || $candle->{high} > $extreme_price ) {
                $extreme_price = $candle->{high};
                $extreme_idx   = $i;
            }
        } else {
            if ( !defined($extreme_price) || $candle->{low} < $extreme_price ) {
                $extreme_price = $candle->{low};
                $extreme_idx   = $i;
            }
        }
    }

    return undef unless defined $extreme_price;
    return {
        from_index => $last_pivot->{index},
        to_index   => $extreme_idx,
        from_price => $last_pivot->{price},
        to_price   => $extreme_price,
        dir        => ( $extreme_price > $last_pivot->{price} ) ? 'up' : 'down',
    };
}
# -----------------------------------------------------------------------------
# _process_candle: Máquina de Estados Finita con Validación "Outside Bar"
# -----------------------------------------------------------------------------
sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c = $self->{_c}[$idx];

    # Inicialización
    if ( $self->{_state} eq 'INIT' ) {
        $self->{_state} = 'BUSCANDO_MAXIMO';
        $self->{_last_extreme} = $c->{high};
        $self->{_extreme_idx}  = $idx;
        $self->_consolidate( $idx, 'L', $c->{low} ); 
        return;
    }

    # EL CAMBIO 2: Uso de Desviación en lugar de Período (Filtro Macro)
    my $dev = $self->{deviation_pct} / 100.0;

    if ( $self->{_state} eq 'BUSCANDO_MAXIMO' ) {
        my $made_new_high = ($c->{high} > $self->{_last_extreme});
        my $triggered_reversal = 0;
        
        my $eval_high = $made_new_high ? $c->{high} : $self->{_last_extreme};
        
        # ¿El retroceso desde el punto más alto superó la desviación macro?
        if ( ( $eval_high - $c->{low} ) / $eval_high >= $dev ) {
            $triggered_reversal = 1;
        }

        # CORRECCION: Parche Cronológico para Outside Bars masivas.
        # ANTES: en el caso "vela verde", se descartaba el pico anterior
        # sobreescribiendo directamente con el high de la vela actual, sin
        # comparar. Eso fusionaba dos piernas del ZigZag en una sola y hacía
        # que se perdieran pivotes intermedios reales. Ahora siempre nos
        # quedamos con el extremo más alto entre el que ya teníamos y el de
        # la vela actual.
        if ($made_new_high && $triggered_reversal) {
            # La vela hizo un nuevo techo Y rompió la desviación a la baja al mismo tiempo.
            if ($c->{open} > $c->{close}) {
                # Vela Roja: Hizo el pico primero, luego se desplomó.
                $self->_consolidate( $idx, 'H', $c->{high} );
                $self->{_state} = 'BUSCANDO_MINIMO';
                $self->{_last_extreme} = $c->{low};
                $self->{_extreme_idx}  = $idx;
            } else {
                # Vela Verde: Cayó primero (falsa reversión), luego hizo el pico real al cerrar.
                # Comparamos contra el extremo previo por si el pico real
                # ya había ocurrido en una vela anterior a esta.
                if ($c->{high} >= $self->{_last_extreme}) {
                    $self->{_last_extreme} = $c->{high};
                    $self->{_extreme_idx}  = $idx;
                }
            }
        } 
        # Flujo Normal: Solo continuación
        elsif ($made_new_high) {
            $self->{_last_extreme} = $c->{high};
            $self->{_extreme_idx}  = $idx;
        } 
        # Flujo Normal: Solo reversión confirmada
        elsif ($triggered_reversal) {
            $self->_consolidate( $self->{_extreme_idx}, 'H', $self->{_last_extreme} );
            $self->{_state} = 'BUSCANDO_MINIMO';
            $self->{_last_extreme} = $c->{low};
            $self->{_extreme_idx}  = $idx;
        }
    }
    elsif ( $self->{_state} eq 'BUSCANDO_MINIMO' ) {
        my $made_new_low = ($c->{low} < $self->{_last_extreme});
        my $triggered_reversal = 0;

        my $eval_low = $made_new_low ? $c->{low} : $self->{_last_extreme};

        # ¿El rebote desde el punto más bajo superó la desviación macro?
        if ( ( $c->{high} - $eval_low ) / $eval_low >= $dev ) {
            $triggered_reversal = 1;
        }

        # CORRECCION: Parche Cronológico para Outside Bars masivas.
        # Mismo criterio que en BUSCANDO_MAXIMO: nunca sobreescribir el
        # extremo sin comparar, o se pierden pivotes intermedios reales.
        if ($made_new_low && $triggered_reversal) {
            if ($c->{open} < $c->{close}) {
                # Vela Verde: Hizo el suelo primero, luego se disparó al alza.
                $self->_consolidate( $idx, 'L', $c->{low} );
                $self->{_state} = 'BUSCANDO_MAXIMO';
                $self->{_last_extreme} = $c->{high};
                $self->{_extreme_idx}  = $idx;
            } else {
                # Vela Roja: Subió primero (falsa reversión), luego se hundió al suelo real.
                # Comparamos contra el extremo previo por si el suelo real
                # ya había ocurrido en una vela anterior a esta.
                if ($c->{low} <= $self->{_last_extreme}) {
                    $self->{_last_extreme} = $c->{low};
                    $self->{_extreme_idx}  = $idx;
                }
            }
        }
        # Flujo Normal: Solo continuación
        elsif ($made_new_low) {
            $self->{_last_extreme} = $c->{low};
            $self->{_extreme_idx}  = $idx;
        }
        # Flujo Normal: Solo reversión confirmada
        elsif ($triggered_reversal) {
            $self->_consolidate( $self->{_extreme_idx}, 'L', $self->{_last_extreme} );
            $self->{_state} = 'BUSCANDO_MAXIMO';
            $self->{_last_extreme} = $c->{high};
            $self->{_extreme_idx}  = $idx;
        }
    }
}

# -----------------------------------------------------------------------------
# _consolidate: Registra el segmento y calcula el Perfil de Volumen
# CAMBIO 3: Eliminamos la destrucción en bucle (pop). Los cálculos pesados
# ocurren una sola vez por cada vector macro cerrado.
# -----------------------------------------------------------------------------
sub _consolidate {
    my ( $self, $index, $kind, $price ) = @_;
    my $pivots = $self->{_pivots};
    my $last   = @$pivots ? $pivots->[-1] : undef;

    # Prevención estructural: No podemos tener dos techos o dos suelos seguidos
    return if defined $last && $last->{kind} eq $kind;

    my $pivot = { id => $self->{_next_id}++, index => $index, kind => $kind, price => $price };
    push @$pivots, $pivot;

    if ( defined $last ) {
        $self->_add_segment_and_profile( $last, $pivot );
    }
}

sub _add_segment_and_profile {
    my ( $self, $prev, $cur ) = @_;
    push @{ $self->{_segments} }, {
        from_index => $prev->{index},
        to_index   => $cur->{index},
        from_price => $prev->{price},
        to_price   => $cur->{price},
        dir        => ( $cur->{price} > $prev->{price} ) ? 'up' : 'down',
    };

    # Disparamos el cálculo del histograma y el POC
    push @{ $self->{_profiles} }, $self->_build_profile( $prev, $cur );
    
    my $max = $self->{max_profiles};
    if ( @{ $self->{_profiles} } > $max ) {
        shift @{ $self->{_profiles} };
    }
}

# -----------------------------------------------------------------------------
# _build_profile: Escaneo de volumen por niveles de precio (Sin cambios en la math)
# -----------------------------------------------------------------------------
sub _build_profile {
    my ( $self, $prev, $cur ) = @_;
    my $idx_from = $prev->{index} < $cur->{index} ? $prev->{index} : $cur->{index};
    my $idx_to   = $prev->{index} < $cur->{index} ? $cur->{index}  : $prev->{index};

    my $price_lo = $prev->{price} < $cur->{price} ? $prev->{price} : $cur->{price};
    my $price_hi = $prev->{price} < $cur->{price} ? $cur->{price}  : $prev->{price};

    my $n_bins = $self->{bins};
    my $range  = $price_hi - $price_lo;
    $range = 1e-9 if $range <= 0;
    my $bin_size = $range / $n_bins;
    
    my @bins = map {
        { low => $price_lo + $_ * $bin_size, high => $price_lo + ( $_ + 1 ) * $bin_size, volume => 0 }
    } ( 0 .. $n_bins - 1 );
    
    my $c = $self->{_c};
    for my $i ( $idx_from .. $idx_to ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        my $vol = $candle->{volume} // 0;
        next if $vol <= 0;
        
        my $lo = $candle->{low}  < $price_lo ? $price_lo : $candle->{low};
        my $hi = $candle->{high} > $price_hi ? $price_hi : $candle->{high};
        next if $hi <= $lo;

        my $candle_range = $candle->{high} - $candle->{low};
        $candle_range = 1e-9 if $candle_range <= 0;

        for my $b (@bins) {
            my $overlap_lo = $lo > $b->{low}  ? $lo : $b->{low};
            my $overlap_hi = $hi < $b->{high} ? $hi : $b->{high};
            next if $overlap_hi <= $overlap_lo;
            
            my $fraction = ( $overlap_hi - $overlap_lo ) / $candle_range;
            $b->{volume} += $vol * $fraction;
        }
    }

    my $poc = $bins[0];
    for my $b (@bins) {
        $poc = $b if $b->{volume} > $poc->{volume};
    }

    return {
        idx_from   => $idx_from,
        idx_to     => $idx_to,
        price_from => $prev->{price},
        price_to   => $cur->{price},
        bins       => \@bins,
        poc_price  => ( $poc->{low} + $poc->{high} ) / 2,
        poc_volume => $poc->{volume},
    };
}

1;