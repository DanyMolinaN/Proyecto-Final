package Market::Indicators::ZigZagVolumeProfile2;

use strict;
use warnings;

use Market::Indicators::ATR;

# =============================================================================
# Market::Indicators::ZigZagVolumeProfile2 (ZZVP2)
#
# Replica fiel de "ZigZag Volume Profile [ChartPrime]" (Pine v6).
# Logica del original (NO es una desviacion porcentual como ZZVP1):
#   - swingHigh = highest(high, swingLength) ; swingLow = lowest(low, swingLength)
#   - isBullish pasa a true cuando el high actual == swingHigh (nuevo maximo
#     de la ventana), y pasa a false cuando el low actual == swingLow.
#   - barIndexHigh/priceHigh y barIndexLow/priceLow se registran cuando la
#     vela anterior fue el extremo de la ventana (high[1]==swingHigh[1]) y la
#     vela actual ya no lo supera (high < swingHigh): ahi se "cierra" el pivote.
#   - Cada vez que isBullish cambia de false->true se crea el segmento
#     (barIndexLow,priceLow)->(barIndexHigh,priceHigh) y se dispara el
#     perfil de volumen con direction = not isBullish (false, "bajista" al
#     dibujar ya que el segmento resultante sube). Cambia true->false: segmento
#     (barIndexHigh,priceHigh)->(barIndexLow,priceLow), direction = isBullish.
#   - Mientras el estado no cambia, el pivote abierto se actualiza en vivo
#     (zigzagLine.set_xy2) cada vez que priceHigh/priceLow cambian.
#
# Perfil de volumen (por nivel, no por rango de precio):
#   - atrRange = ATR(200) * channelWidthFactor
#   - Para i en [-volumeBinCount .. +volumeBinCount] se traza un nivel
#     paralelo al segmento, desplazado atrRange*i, y se suma el volumen de
#     cada vela cuyo rango high/low cruza ese nivel (level = endPrice+offset+slope*k).
#   - El bin con mayor volumen es el POC.
#
# -----------------------------------------------------------------------------
# CONTRATO con Market::Structure::StructureEngine (rol EXTERNO, alternativa
# a Market::Indicators::ZigZagVolumeProfile / "ZZVP1"):
#   update_at_index($market_data, $idx)
#   sync_to_index($market_data, $target_index)
#   reset()
#   pivots_as_swings() -> [ { index, price, kind, type }, ... ]
#   get_tentative_segment() -> { from_index, from_price, to_index, to_price, dir } | undef
#   get_segments() / get_profiles()  (para overlay crudo, opcional)
#
# NOTA: a diferencia de ZigZagMTF/ZigZagVolumeProfile, este motor requiere
# SIEMPRE un objeto MarketData (no un candle-hash suelto) porque el ATR
# interno necesita acceso secuencial a velas anteriores por indice.
# =============================================================================

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        swing_length         => $args{swing_length}         // 150,
        channel_width_factor => $args{channel_width_factor} // 1,
        atr_period            => $args{atr_period}            // 200,
        volume_bin_count      => $args{volume_bin_count}      // 5,  # = input Bins/2 (Pine hace int(10/2))
        max_profiles          => $args{max_profiles}          // 15,

        _c   => [],
        _atr => Market::Indicators::ATR->new( $args{atr_period} // 200 ),

        _segments => [],
        _profiles => [],
        _last_index => -1,

        # Estado replicado del Pine (todas 'var' -> persisten entre velas)
        _is_bullish       => undef,
        _prev_is_bullish  => undef,
        _bar_index_low    => undef,
        _price_low        => undef,
        _bar_index_high   => undef,
        _price_high       => undef,
        _prev_price_high  => undef,
        _prev_price_low   => undef,

        # Segmento (pivote) abierto actualmente en construccion
        _open_segment => undef,   # { from_index, from_price, to_index, to_price, dir }
    };
    bless $self, $class;
    return $self;
}

sub get_values { return []; }

sub reset {
    my ($self) = @_;
    $self->{_c}         = [];
    $self->{_atr}       = Market::Indicators::ATR->new( $self->{atr_period} );
    $self->{_segments}  = [];
    $self->{_profiles}  = [];
    $self->{_last_index} = -1;

    $self->{_is_bullish}      = undef;
    $self->{_prev_is_bullish} = undef;
    $self->{_bar_index_low}   = undef;
    $self->{_price_low}       = undef;
    $self->{_bar_index_high}  = undef;
    $self->{_price_high}      = undef;
    $self->{_prev_price_high} = undef;
    $self->{_prev_price_low}  = undef;
    $self->{_open_segment}    = undef;
    return $self;
}

sub last_index { return $_[0]->{_last_index}; }

sub update_at_index {
    my ( $self, $md, $idx ) = @_;
    return $self unless $md && defined $idx && $idx >= 0;
    my $c = $md->get_candle($idx);
    return $self unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_at_index( $md, $idx );
    $self->_process_candle($idx);
    $self->{_last_index} = $idx;
    return $self;
}

sub update_last {
    my ( $self, $md ) = @_;
    return $self unless $md;
    my $idx = $#{ $self->{_c} } + 1;
    my $c   = $md->last_candle;
    return $self unless defined $c;
    $self->{_c}[$idx] = $c;
    $self->{_atr}->update_last($md);
    $self->_process_candle($idx);
    $self->{_last_index} = $idx;
    return $self;
}

# sync_to_index($market_data, $target_index)
# Mismo patron que ZigZagMTF/ZigZagVolumeProfile: si el indice objetivo
# retrocede respecto al ultimo procesado, reinicia el estado; luego procesa
# unicamente las velas nuevas [ultimo+1 .. target_index].
sub sync_to_index {
    my ( $self, $market_data, $target_index ) = @_;
    return $self unless $market_data && $market_data->can('get_candle');
    return $self unless defined $target_index && $target_index >= 0;

    if ( defined $self->{_last_index} && $self->{_last_index} > $target_index ) {
        $self->reset();
    }

    my $from = ( $self->{_last_index} // -1 ) + 1;
    $from = 0 if $from < 0;

    for my $i ( $from .. $target_index ) {
        $self->update_at_index( $market_data, $i );
    }
    return $self;
}

sub get_segments { return $_[0]->{_segments}; }
sub get_profiles { return $_[0]->{_profiles}; }

# Tramo abierto (para render "en vivo", equivalente al ultimo zigzagLine
# antes de que cambie isBullish).
sub get_tentative_segment { return $_[0]->{_open_segment}; }

# pivots_as_swings() -> [ { index, price, kind, type }, ... ]
# CONTRATO requerido por StructureEngine::_build_zigzag_from_engine. Se
# deriva de _segments: el "from" del primer segmento y el "to" de cada
# segmento salvo el ultimo son pivotes ya confirmados (el "to" del ultimo
# segmento sigue vivo -- ver get_tentative_segment/_update_open_segment).
sub pivots_as_swings {
    my ($self) = @_;
    my $segments = $self->{_segments};
    my @out;
    return \@out unless $segments && @$segments;

    push @out, _pivot_from_point( $segments->[0], 'from' );
    for my $i ( 0 .. $#$segments - 1 ) {
        push @out, _pivot_from_point( $segments->[$i], 'to' );
    }
    return \@out;
}

sub _pivot_from_point {
    my ( $seg, $which ) = @_;
    my ( $index, $price ) = $which eq 'from'
        ? ( $seg->{from_index}, $seg->{from_price} )
        : ( $seg->{to_index},   $seg->{to_price} );

    # dir 'up'   => from = L, to = H
    # dir 'down' => from = H, to = L
    my $kind = ( $seg->{dir} eq 'up' )
        ? ( $which eq 'from' ? 'L' : 'H' )
        : ( $which eq 'from' ? 'H' : 'L' );

    return {
        index => $index,
        price => $price,
        kind  => $kind,
        type  => $kind eq 'H' ? 'swing_high' : 'swing_low',
    };
}

# -----------------------------------------------------------------------------
# _process_candle: traduccion literal del bloque de deteccion de swings +
# apertura/actualizacion/cierre de segmentos del Pine.
# -----------------------------------------------------------------------------
sub _process_candle {
    my ( $self, $idx ) = @_;
    my $c  = $self->{_c}[$idx];
    my $sl = $self->{swing_length};

    # --- swingHigh / swingLow: highest/lowest sobre la ventana [idx-sl+1, idx] ---
    my ( $swing_high, $swing_low ) = $self->_swing_extremes($idx);
    return unless defined $swing_high && defined $swing_low;

    # swingHigh/Low de la vela anterior (para las condiciones high[1]==swingHigh[1])
    my ( $prev_swing_high, $prev_swing_low ) = $idx > 0
        ? $self->_swing_extremes( $idx - 1 )
        : ( undef, undef );

    # --- isBullish := true si swingHigh==high ; := false si swingLow==low ---
    $self->{_prev_is_bullish} = $self->{_is_bullish};
    if ( $swing_high == $c->{high} ) {
        $self->{_is_bullish} = 1;
    }
    if ( $swing_low == $c->{low} ) {
        $self->{_is_bullish} = 0;
    }

    # --- deteccion de pivote alto/bajo cerrado ---
    if ( $idx > 0 ) {
        my $c_prev = $self->{_c}[ $idx - 1 ];
        if ( defined $prev_swing_high
            && $c_prev->{high} == $prev_swing_high
            && $c->{high} < $swing_high )
        {
            $self->{_bar_index_high} = $idx - 1;
            # BUGFIX: el pivote alto debe anclarse al HIGH de la vela pivote,
            # no a su low (error presente en la version original pegada:
            # usaba $c_prev->{low} aqui, lo que desalineaba el segmento y,
            # en cascada, el atr_range/niveles del volume profile).
            $self->{_price_high}     = $c_prev->{high};
        }
        if ( defined $prev_swing_low
            && $c_prev->{low} == $prev_swing_low
            && $c->{low} > $swing_low )
        {
            $self->{_bar_index_low} = $idx - 1;
            $self->{_price_low}     = $c_prev->{low};
        }
    }

    # No podemos construir nada hasta tener ambos extremos definidos.
    return unless defined $self->{_bar_index_high} && defined $self->{_bar_index_low};

    my $ib      = $self->{_is_bullish};
    my $ib_prev = $self->{_prev_is_bullish};
    my $changed = defined($ib) && ( !defined($ib_prev) || $ib != $ib_prev );

    if ( $changed && $ib ) {
        # false -> true : nuevo segmento (low -> high), direction = not isBullish = false
        $self->_open_new_segment(
            $self->{_bar_index_low}, $self->{_price_low},
            $self->{_bar_index_high}, $self->{_price_high},
        );
        $self->_draw_profile_segment(
            $self->{_bar_index_high}, $self->{_price_high},
            $self->{_bar_index_low},  $self->{_price_low},
            0,
        );
    }
    if ( $ib && defined( $self->{_prev_price_high} )
        && $self->{_price_high} != $self->{_prev_price_high} )
    {
        # isBullish (linea Pine 139): independiente de si hubo cambio de estado
        # en esta misma barra -- si acaba de abrirse el segmento arriba, esto
        # vuelve a fijar el mismo xy2 (no-op real), igual que el Pine.
        $self->_update_open_segment( $self->{_bar_index_high}, $self->{_price_high} );
    }

    if ( $changed && !$ib ) {
        # true -> false : nuevo segmento (high -> low), direction = isBullish = true
        $self->_open_new_segment(
            $self->{_bar_index_high}, $self->{_price_high},
            $self->{_bar_index_low}, $self->{_price_low},
        );
        $self->_draw_profile_segment(
            $self->{_bar_index_low}, $self->{_price_low},
            $self->{_bar_index_high}, $self->{_price_high},
            1,
        );
    }
    if ( defined($ib) && !$ib && defined( $self->{_prev_price_low} )
        && $self->{_price_low} != $self->{_prev_price_low} )
    {
        # isBullish (linea Pine 148): independiente del cambio de estado
        $self->_update_open_segment( $self->{_bar_index_low}, $self->{_price_low} );
    }

    $self->{_prev_price_high} = $self->{_price_high};
    $self->{_prev_price_low}  = $self->{_price_low};
}

# highest(high, sl) / lowest(low, sl) sobre la ventana que termina en $idx
sub _swing_extremes {
    my ( $self, $idx ) = @_;
    my $sl = $self->{swing_length};
    my $from = $idx - $sl + 1;
    $from = 0 if $from < 0;

    my $c = $self->{_c};
    my ( $hi, $lo );
    for my $i ( $from .. $idx ) {
        my $candle = $c->[$i];
        next unless defined $candle;
        $hi = $candle->{high} if !defined($hi) || $candle->{high} > $hi;
        $lo = $candle->{low}  if !defined($lo) || $candle->{low}  < $lo;
    }
    return ( $hi, $lo );
}

sub _open_new_segment {
    my ( $self, $from_idx, $from_price, $to_idx, $to_price ) = @_;
    $self->{_open_segment} = {
        from_index => $from_idx,
        from_price => $from_price,
        to_index   => $to_idx,
        to_price   => $to_price,
        dir        => ( $to_price > $from_price ) ? 'up' : 'down',
    };
    # Una unica linea por pierna (equivalente a zigzagLine := line.new(...)).
    # Las mutaciones posteriores (set_xy2) NO agregan lineas nuevas, solo
    # editan esta misma entrada -- ver _update_open_segment.
    push @{ $self->{_segments} }, $self->{_open_segment};
}

sub _update_open_segment {
    my ( $self, $to_idx, $to_price ) = @_;
    return unless $self->{_open_segment};
    # Muta en sitio la MISMA linea abierta (equivalente a zigzagLine.set_xy2),
    # nunca crea una entrada nueva en _segments.
    $self->{_open_segment}{to_index} = $to_idx;
    $self->{_open_segment}{to_price} = $to_price;
    $self->{_open_segment}{dir} =
        ( $to_price > $self->{_open_segment}{from_price} ) ? 'up' : 'down';
}

# -----------------------------------------------------------------------------
# _draw_profile_segment: equivalente a drawProfileSegment() del Pine.
# $direction: valor booleano pasado como 'trendDirection' a drawVolumeBin
#             (0/1), solo afecta el lado desde donde arranca cada barra al
#             renderizar; aqui lo guardamos para que el overlay lo use.
# -----------------------------------------------------------------------------
sub _draw_profile_segment {
    my ( $self, $start_idx, $start_price, $end_idx, $end_price, $direction ) = @_;

    my $atr_vals = $self->{_atr}{values};
    my $atr      = $atr_vals->[$end_idx] // $atr_vals->[-1] // 0;
    my $atr_range = $atr * $self->{channel_width_factor};

    my $n       = $self->{volume_bin_count};
    my $c       = $self->{_c};
    my $range_  = $end_idx - $start_idx;   # puede ser negativo, igual que en Pine
    return if $range_ == 0;

    my @bins;   # { offset_i, level_price(at end), slope, volume }
    my $total_volume = 0;

    for ( my $i = $n; $i >= -$n; $i-- ) {
        my $offset = $atr_range * $i;
        my $y_start = $start_price + $offset;
        my $y_end   = $end_price + $offset;
        my $slope   = ( $y_start - $y_end ) / ( $end_idx - $start_idx );

        my $vol_at_level = 0;
        my ( $lo_idx, $hi_idx ) = $start_idx < $end_idx
            ? ( $start_idx, $end_idx ) : ( $end_idx, $start_idx );

        # Pine itera "for k = 0 to endBar-startBar" indexando hacia atras
        # desde la vela actual con high[k]/low[k] (k=0 es la vela mas
        # reciente = endBar en este contexto de llamada). Aqui iteramos
        # directamente sobre el rango de indices [lo_idx, hi_idx].
        for my $bar_i ( $lo_idx .. $hi_idx ) {
            my $candle = $c->[$bar_i];
            next unless defined $candle;
            my $k = $end_idx - $bar_i;   # distancia al extremo final, como high[k]
            my $level = $end_price + $offset + $slope * $k;
            if ( $candle->{high} > $level && $candle->{low} < $level ) {
                $vol_at_level += ( $candle->{volume} // 0 );
            }
        }

        push @bins, {
            i       => $i,
            offset  => $offset,
            slope   => $slope,
            volume  => $vol_at_level,
        };
        $total_volume += $vol_at_level;
    }

    my $max_vol = 0;
    for my $b (@bins) { $max_vol = $b->{volume} if $b->{volume} > $max_vol; }

    for my $b (@bins) {
        my $vol_pct = $total_volume > 0 ? ( $b->{volume} / $total_volume * 100 ) : 0;
        $b->{volume_pct} = $vol_pct;
        $b->{is_poc}     = ( $max_vol > 0 && $b->{volume} == $max_vol ) ? 1 : 0;
    }

    push @{ $self->{_profiles} }, {
        idx_from    => $start_idx,
        idx_to      => $end_idx,
        price_from  => $start_price,
        price_to    => $end_price,
        direction   => $direction,
        atr_range   => $atr_range,
        bins        => \@bins,
        max_volume  => $max_vol,
        total_volume => $total_volume,
    };

    my $max = $self->{max_profiles};
    if ( @{ $self->{_profiles} } > $max ) {
        shift @{ $self->{_profiles} };
    }
}

1;

