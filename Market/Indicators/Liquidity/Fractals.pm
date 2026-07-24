package Market::Indicators::Liquidity;

# =============================================================================
# Liquidity::Fractals
# =============================================================================
# Ingesta, fractales ATR y displacement.
# Continuacion de Market::Indicators::Liquidity (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _ingest {
    my ( $self, $md, $c, $idx ) = @_;
    $self->{_c}[$idx] = $c;

    my $atr_arr = $self->{atr} && $self->{atr}->can('get_values')
        ? $self->{atr}->get_values
        : undef;
    $self->{_atr} = $atr_arr if $atr_arr;

    $self->_try_confirm_fractals($idx);
    $self->_check_displacement( $idx, $md );
    $self->_update_state_machine( $md, $idx );
}

# -----------------------------------------------------------------------------
# _try_confirm_fractals: intenta confirmar fractalidad en (idx - N), ahora que
# ya se conoce hasta idx (>= (idx-N)+N). Solo evalua UNA vez el candidato
# (idx - N); si idx < N no hay nada que evaluar todavia.
# -----------------------------------------------------------------------------
sub _try_confirm_fractals {
    my ( $self, $idx ) = @_;
    my $n = $self->{fractal_n};
    my $t = $idx - $n;
    return if $t < $n;                      # no hay N velas a la izquierda aun
    return unless defined $self->{_c}[$t];

    my $c = $self->{_c};
    for my $i ( 1 .. $n ) {
        return unless defined $c->[ $t - $i ] && defined $c->[ $t + $i ];
    }

    my $is_high = 1;
    my $is_low  = 1;
    for my $i ( 1 .. $n ) {
        $is_high = 0 if !( $c->[$t]{high} > $c->[ $t - $i ]{high}
                         && $c->[$t]{high} > $c->[ $t + $i ]{high} );
        $is_low  = 0 if !( $c->[$t]{low}  < $c->[ $t - $i ]{low}
                         && $c->[$t]{low}  < $c->[ $t + $i ]{low} );
    }

    return unless $is_high || $is_low;

    my $atr_t = $self->_atr_at($t);
    return unless defined $atr_t && $atr_t > 0;   # sin ATR valido no se puede filtrar

    if ($is_high) {
        $self->_apply_atr_filter( $t, 'H', $c->[$t]{high}, $atr_t );
    }
    if ($is_low) {
        $self->_apply_atr_filter( $t, 'L', $c->[$t]{low}, $atr_t );
    }
}

sub _atr_at {
    my ( $self, $t ) = @_;
    my $arr = $self->{_atr};
    return undef unless $arr && ref($arr) eq 'ARRAY';
    return $arr->[$t];
}

# -----------------------------------------------------------------------------
# FILTRO 1 (ATR): distancia vertical desde el nuevo swing hasta el ULTIMO
# SWING CONSOLIDADO DEL TIPO OPUESTO debe ser > m_ATR * ATR[t].
# Si no hay swing opuesto previo (arranque de la serie), se acepta el primer
# candidato de cada tipo sin filtro (no hay contra que comparar).
# Si pasa, el candidato entra a la cola de validacion por desplazamiento.
# -----------------------------------------------------------------------------
sub _apply_atr_filter {
    my ( $self, $t, $kind, $price, $atr_t ) = @_;

    my $opposite = ( $kind eq 'H' ) ? $self->{_last_L} : $self->{_last_H};

    if ( defined $opposite ) {
        my $dist = abs( $price - $opposite->{price} );
        my $min_req = $self->{m_atr} * $atr_t;
        return if !( $dist > $min_req );   # ruido: se descarta, no se re-evalua
    }

    push @{ $self->{_pending_displacement} }, {
        index    => $t,
        kind     => $kind,
        price    => $price,
        atr      => $atr_t,
        deadline => $t + $self->{v_desp},
        extreme  => $price,   # se actualiza mientras esta pendiente (ver abajo)
    };
}

# -----------------------------------------------------------------------------
# FILTRO 2 (DESPLAZAMIENTO): recorre los candidatos pendientes en cada vela
# nueva (idx). Si dentro de v_desp velas el precio se mueve al menos
# u_desp * ATR[t] en contra del pivote, se consolida. Si se agota la ventana
# sin lograrlo, se descarta.
# -----------------------------------------------------------------------------
sub _check_displacement {
    my ( $self, $idx, $market_data ) = @_;
    return unless @{ $self->{_pending_displacement} };

    my $c   = $self->{_c}[$idx];
    return unless defined $c;

    my @still_pending;
    for my $cand ( @{ $self->{_pending_displacement} } ) {
        if ( $idx <= $cand->{index} ) { push @still_pending, $cand; next; }

        my $required = $self->{u_desp} * $cand->{atr};

        if ( $cand->{kind} eq 'H' ) {
            $cand->{extreme} = $c->{low} if $c->{low} < $cand->{extreme};
            my $travel = $cand->{price} - $cand->{extreme};
            if ( $travel >= $required ) {
                $self->_consolidate($cand, $market_data);
                next;
            }
        }
        else {
            $cand->{extreme} = $c->{high} if $c->{high} > $cand->{extreme};
            my $travel = $cand->{extreme} - $cand->{price};
            if ( $travel >= $required ) {
                $self->_consolidate($cand, $market_data);
                next;
            }
        }

        if ( $idx >= $cand->{deadline} ) {
            next;   # se agoto la ventana sin desplazamiento: descartado
        }
        push @still_pending, $cand;
    }
    $self->{_pending_displacement} = \@still_pending;
}

# -----------------------------------------------------------------------------
# _consolidate: swing validado (paso ATR + desplazamiento). Antes de
# registrarlo se fuerza ALTERNANCIA ESTRICTA (ver punto 4 del pipeline):
#   - Si el ULTIMO swing de la secuencia (por indice, no por confirmacion)
#     es del MISMO tipo que este candidato, no se agrega uno nuevo: se
#     compara contra ese swing y solo sobrevive el mas extremo (el otro se
#     descarta / reemplaza). El swing reemplazado se retira tambien de la
#     trend line y de las etiquetas.
#   - Si es de tipo OPUESTO, se inserta normalmente en la secuencia.
#
# Esta regla es la que garantiza que el patron de estructura sea siempre
# H-L-H-L... (nunca dos maximos ni dos minimos consecutivos en la secuencia
# de swings expuesta al overlay y a SMC_Structures).
#
# La insercion sigue siendo por indice (no por orden de confirmacion) por la
# misma razon documentada en _insert_sorted_by_index: el filtro de
# desplazamiento puede confirmar swings fuera de orden cronologico.
# -----------------------------------------------------------------------------

1;
