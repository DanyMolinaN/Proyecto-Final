package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Breaks
# =============================================================================
# BOS/CHoCH y cierre de proyecciones EQH/EQL.
# Continuacion del paquete Market::Concepts::SMCStructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _check_structure_break {
    my ($self, $candles, $i, %o) = @_;
    my $c = $candles->[$i];
    return unless $c;
    my $close = $c->{close};
    return unless defined $close;
    my $confirm_mode = $self->{confirm_mode} // 'close';
    # En modo 'wick' se confirma con el extremo de la vela (High para cruces
    # alcistas, Low para cruces bajistas); en 'close' (default) solo el cierre.
    my $bull_price = ($confirm_mode eq 'wick' && defined $c->{high}) ? $c->{high} : $close;
    my $bear_price = ($confirm_mode eq 'wick' && defined $c->{low})  ? $c->{low}  : $close;
    my $scope     = $o{scope} // 'swing';
    my $trend_ref = $o{trend_ref};
    my $open_eq   = $o{open_eq} // {};
    my $bar_index = $o{bar_index} // $i;

    # ── Cruce BULLISH ─────────────────────────────────────────────────────────
    my $ph = ${ $o{high_ref} };
    if (defined $ph && defined $ph->{level} && !$ph->{crossed}) {
        if ($bull_price > $ph->{level}) {
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
        if ($bear_price < $pl->{level}) {
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

1;