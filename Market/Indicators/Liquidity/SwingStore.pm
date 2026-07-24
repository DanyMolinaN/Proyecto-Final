package Market::Indicators::Liquidity;

# =============================================================================
# Liquidity::SwingStore
# =============================================================================
# Consolidacion e insercion ordenada de swings/levels.
# Continuacion de Market::Indicators::Liquidity (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _consolidate {
    my ( $self, $cand, $market_data ) = @_;

    my $swing = {
        id    => $self->{_next_id}++,
        index => $cand->{index},
        ts    => $self->{_c}[ $cand->{index} ]{ts},
        kind  => $cand->{kind},
        price => $cand->{price},
    };

    my $pos = $self->_find_insert_pos( $swing->{index} );
    my $left  = $pos > 0 ? $self->{_swings}[ $pos - 1 ] : undef;
    my $right = $pos <= $#{ $self->{_swings} } ? $self->{_swings}[$pos] : undef;

    my $same_kind_neighbor =
        ( defined $left  && $left->{kind}  eq $swing->{kind} ) ? $left  :
        ( defined $right && $right->{kind} eq $swing->{kind} ) ? $right :
        undef;

    if ( defined $same_kind_neighbor ) {
        my $new_is_more_extreme =
            ( $swing->{kind} eq 'H' )
                ? ( $swing->{price} > $same_kind_neighbor->{price} )
                : ( $swing->{price} < $same_kind_neighbor->{price} );

        return unless $new_is_more_extreme;

        $self->_remove_swing($same_kind_neighbor);
        $pos = $self->_find_insert_pos( $swing->{index} );
    }

    splice( @{ $self->{_swings} }, $pos, 0, $swing );

    $self->_insert_sorted_by_index( $self->{_trendline}, { index => $swing->{index}, price => $swing->{price} } );

    $self->_refresh_last_refs();

    $self->_check_equal_levels( $swing->{kind}, $swing );

    # Crear nivel de liquidez a partir del swing consolidado
    my $level = $self->_register_level( $swing->{kind}, $swing, undef );
    push @{ $self->{_open_level_refs} }, $level
        unless grep { $_ == $level } @{ $self->{_open_level_refs} };
}

# -----------------------------------------------------------------------------
# _find_insert_pos: posicion donde deberia insertarse un swing con este
# index para mantener _swings ordenado ascendente por index.
# -----------------------------------------------------------------------------
sub _find_insert_pos {
    my ( $self, $index ) = @_;
    my $swings = $self->{_swings};
    my $i = $#$swings;
    while ( $i >= 0 && $swings->[$i]{index} > $index ) { $i--; }
    return $i + 1;
}

# -----------------------------------------------------------------------------
# _remove_swing: retira un swing de _swings y _trendline por id.
# Usado cuando un swing del mismo tipo mas extremo lo reemplaza.
# -----------------------------------------------------------------------------
sub _remove_swing {
    my ( $self, $swing ) = @_;

    my $swings = $self->{_swings};
    for my $i ( 0 .. $#$swings ) {
        if ( $swings->[$i]{id} == $swing->{id} ) {
            splice( @$swings, $i, 1 );
            last;
        }
    }

    my $tl = $self->{_trendline};
    for my $i ( 0 .. $#$tl ) {
        if ( $tl->[$i]{index} == $swing->{index} ) {
            splice( @$tl, $i, 1 );
            last;
        }
    }

    for my $i ( reverse 0 .. $#{ $self->{_levels} } ) {
        my $lv = $self->{_levels}[$i];
        if ( $lv->{origin_swing_id} == $swing->{id} && $lv->{state} eq 'DETECTED' ) {
            splice( @{ $self->{_levels} }, $i, 1 );
        }
    }
    $self->{_open_level_refs} =
        [ grep { $_->{origin_swing_id} != $swing->{id} } @{ $self->{_open_level_refs} } ];
}

# -----------------------------------------------------------------------------
# _insert_sorted_by_index: inserta $item en $arr manteniendo orden ascendente
# por {index}. Recorre desde el final porque en la practica la mayoria de las
# confirmaciones SI llegan en orden (insercion casi siempre O(1) amortizado).
# -----------------------------------------------------------------------------
sub _insert_sorted_by_index {
    my ( $self, $arr, $item ) = @_;
    my $i = $#$arr;
    while ( $i >= 0 && $arr->[$i]{index} > $item->{index} ) { $i--; }
    splice( @$arr, $i + 1, 0, $item );
}

# -----------------------------------------------------------------------------
# _refresh_last_refs: recalcula _last_H y _last_L a partir del ULTIMO swing
# de cada tipo en orden cronologico real dentro de _swings (no del ultimo
# confirmado por el motor de eventos). Necesario porque el filtro de
# desplazamiento puede confirmar swings fuera de orden.
# -----------------------------------------------------------------------------
sub _refresh_last_refs {
    my ($self) = @_;
    $self->{_last_H} = undef;
    $self->{_last_L} = undef;
    my $swings = $self->{_swings};
    for ( my $i = $#$swings; $i >= 0; $i-- ) {
        my $s = $swings->[$i];
        if ( $s->{kind} eq 'H' && !defined $self->{_last_H} ) {
            $self->{_last_H} = { index => $s->{index}, price => $s->{price} };
        }
        if ( $s->{kind} eq 'L' && !defined $self->{_last_L} ) {
            $self->{_last_L} = { index => $s->{index}, price => $s->{price} };
        }
        last if defined $self->{_last_H} && defined $self->{_last_L};
    }
}

sub _register_level {
     my ( $self, $kind, $swing, $market_data ) = @_;
    my $side = ( $kind eq 'H' ? 'buy' : 'sell' );

    # --- FILTRO DE NOVEDAD: evita clusters de niveles casi superpuestos ---
    my $atr_now = $self->_atr_at( $swing->{index} );
    if ( defined $atr_now && $atr_now > 0 ) {
        my $min_dist = $self->{level_min_dist_atr} * $atr_now;
        for my $lv ( @{ $self->{_levels} } ) {
            next unless $lv->{side} eq $side;
            next unless $lv->{state} eq 'DETECTED';   # solo compite con niveles aun activos
            if ( abs( $lv->{price} - $swing->{price} ) < $min_dist ) {
                # Ya hay un nivel activo muy cerca: lo actualizamos al swing
                # mas reciente/extremo en vez de crear uno nuevo.
                my $more_extreme = ( $side eq 'buy' )
                    ? ( $swing->{price} > $lv->{price} )
                    : ( $swing->{price} < $lv->{price} );
                if ($more_extreme) {
                    $lv->{price} = $swing->{price};
                    $lv->{index} = $swing->{index};
                    $lv->{origin_swing_id} = $swing->{id};
                }
                return $lv;   # no se crea nivel nuevo
            }
        }
    }

    # type: BSL (Buy Side Liquidity) para highs, SSL (Sell Side Liquidity) para lows
    # scope: 'external' por defecto; se sobreescribe si viene de ZigZag interno
    my $type  = ( $side eq 'buy' ) ? 'BSL' : 'SSL';
    my $level = {
        id              => $self->{_next_id}++,
        side            => $side,
        type            => $type,
        scope           => $swing->{scope} // 'external',
        label           => $type,
        price           => $swing->{price},
        index           => $swing->{index},
        origin_swing_id => $swing->{id},
        state           => 'DETECTED',
        classification  => undef,
        swept_at_index  => undef,
        resolved_at_index => undef,
        origin_tf       => undef,
        volumes         => { '1m' => 0, '5m' => 0, '15m' => 0 },
    };
    $self->_attach_multi_tf_volume( $level, $swing, $market_data ) if $market_data;
    push @{ $self->{_levels} }, $level;
    return $level;
}

sub _attach_multi_tf_volume {
    my ( $self, $level, $swing, $market_data ) = @_;
    my $tf = $market_data->active_tf;
    $level->{origin_tf} = $tf;
}


1;
