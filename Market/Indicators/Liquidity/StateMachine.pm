package Market::Indicators::Liquidity;

# =============================================================================
# Liquidity::StateMachine
# =============================================================================
# FSM de sweep/resolution y sync ZigZag interno.
# Continuacion de Market::Indicators::Liquidity (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _check_equal_levels {
   my ( $self, $kind, $new_swing ) = @_;
    return unless $self->{atr};
    my $atr_values = $self->{atr}->get_values;
    return unless $atr_values && @$atr_values;
    my $atr_at_new = $atr_values->[ $new_swing->{index} ];
    return unless defined $atr_at_new;
    my $tolerance = $atr_at_new * $self->{eq_factor};

    # Solo comparar contra los ultimos N swings (ventana reciente), no todo el historico
    my $swings = $self->{_swings};
    my $from = @$swings - $self->{eq_lookback};
    $from = 0 if $from < 0;

    for my $idx ( $from .. $#$swings ) {
        my $prev = $swings->[$idx];
        next if $prev->{id} == $new_swing->{id};
        next unless $prev->{kind} eq $kind;
        my $diff = abs( $prev->{price} - $new_swing->{price} );
        next if $diff > $tolerance;
        push @{ $self->{_equals} }, {
            kind => ( $kind eq 'H' ? 'EQH' : 'EQL' ),
            i1 => $prev->{index}, i2 => $new_swing->{index},
            p1 => $prev->{price}, p2 => $new_swing->{price},
        };
    }
}

sub _update_state_machine {
    my ( $self, $market_data, $i ) = @_;
    my $candle = $market_data->get_candle($i);
    return unless $candle;
    my @still_open;
    for my $level ( @{ $self->{_open_level_refs} } ) {
        $self->_check_sweep( $level, $candle, $i )      if $level->{state} eq 'DETECTED';
        if ( $level->{state} eq 'DETECTED'
            && ( $i - $level->{index} ) >= $self->{level_expiry_n} ) {
            $level->{state} = 'EXPIRED';
        }
        $self->_check_resolution( $level, $candle, $i ) if $level->{state} eq 'SWEPT';
        push @still_open, $level unless $level->{state} eq 'RESOLVED';
    }
    $self->{_open_level_refs} = \@still_open;
}

sub _check_sweep {
    my ( $self, $level, $candle, $i ) = @_;
    my $swept = ( $level->{side} eq 'buy' )
        ? ( $candle->{high} > $level->{price} ) : ( $candle->{low} < $level->{price} );
    return unless $swept;
    $level->{state} = 'SWEPT';
    $level->{swept_at_index} = $i;
}

sub _check_resolution {
    my ( $self, $level, $candle, $i ) = @_;
    my $n_since = $i - $level->{swept_at_index} + 1;
    my $closed_inside = ( $level->{side} eq 'buy' )
        ? ( $candle->{close} <= $level->{price} ) : ( $candle->{close} >= $level->{price} );
    if ($closed_inside) {
        $self->_resolve( $level, ( $n_since <= $self->{grab_window} ? 'Grab' : 'Sweep' ), $i );
        return;
    }
    $self->_resolve( $level, 'Run', $i ) if $n_since >= $self->{acceptance_n};
}

sub _resolve {
    my ( $self, $level, $classification, $i ) = @_;
    $level->{state} = 'RESOLVED';
    $level->{classification} = $classification;
    $level->{resolved_at_index} = $i;
    my $dir = ( $level->{side} eq 'buy' ) ? 'up' : 'down';
    push @{ $self->{_events} }, {
        type  => $classification,        # 'Sweep' | 'Grab' | 'Run'
        dir   => $dir,
        start => $i,                     # overlay reads {start} for sweep idx
        index => $i,
        price => $level->{price},
        scope => $level->{scope} // 'external',
        label => $self->side_label( $level->{side} ) . ' ' . $classification,
    };
}

sub _external_phase {
    my ($self) = @_;
    my $zzvp = $self->{zzvp} or return undef;
    my $pivots = $zzvp->get_pivots;
    return undef unless $pivots && @$pivots;

    my $last = $pivots->[-1];
    # Un ultimo pivote 'L' confirmado implica que la fase vigente es alcista
    # (se viene buscando el proximo techo); un 'H' implica fase bajista.
    return $last->{kind} eq 'L' ? 'up' : 'down';
}

sub _sync_levels_from_internal_zigzag {
    my ( $self, $market_data ) = @_;
    my $zzmtf = $self->{zzmtf} or return;
    my $swings = $zzmtf->get_swings or return;

    $self->{_seen_swing_ids} //= {};

    for my $sw (@$swings) {
        next if $self->{_seen_swing_ids}{ $sw->{id} };

        my $phase = $self->_external_phase;

        # Si aun no hay fase externa disponible, igual registramos el nivel
        # (sin clasificar prioridad) en vez de descartarlo indefinidamente.
        my $priority = 'normal';
        if ( defined $phase ) {
            my $retracement_end_kind = ( $phase eq 'up' ) ? 'L' : 'H';
            $priority = ( $sw->{kind} eq $retracement_end_kind ) ? 'high' : 'normal';
        }

        $self->{_seen_swing_ids}{ $sw->{id} } = 1;

        my $level = $self->_register_level( $sw->{kind}, $sw, $market_data );
        $level->{priority} = $priority;   # metadato para el overlay (opcional)
        push @{ $self->{_open_level_refs} }, $level
            unless grep { $_ == $level } @{ $self->{_open_level_refs} };
    }
}

1;
