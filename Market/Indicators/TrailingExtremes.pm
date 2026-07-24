package Market::Indicators::TrailingExtremes;

# =============================================================================
# Market::Indicators::TrailingExtremes  — v1.0
# =============================================================================
# Mantiene el máximo (top) y mínimo (bottom) acumulado de toda la historia
# visible, actualizándose vela a vela (running max/min).
#
# Clasificación Strong/Weak:
#   El Pine Script de referencia clasifica los extremos según el sesgo
#   de tendencia del swing structure:
#
#     Tendencia BAJISTA (swing_trend == 'bearish'):
#       top    => Strong High  (fue el origen del último BOS/CHoCH bajista,
#                               no ha sido roto por el precio)
#       bottom => Weak Low     (extremo reciente en dirección de la tendencia,
#                               susceptible de ser barrido)
#
#     Tendencia ALCISTA (swing_trend == 'bullish'):
#       top    => Weak High    (extremo reciente en dirección de la tendencia)
#       bottom => Strong Low   (fue el origen del último BOS/CHoCH alcista)
#
#     Tendencia NEUTRAL:
#       top    => Strong High
#       bottom => Strong Low
#
# Salida de calculate():
#   {
#     top          => { price => $p, index => $i, label => 'Strong High'|'Weak High' },
#     bottom       => { price => $p, index => $i, label => 'Strong Low'|'Weak Low'   },
#     swing_trend  => 'bullish'|'bearish'|'neutral',
#   }
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        top    => undef,
        bottom => undef,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{top}    = undef;
    $self->{bottom} = undef;
    return $self;
}

# calculate($market_data, $smc_structure_data, %args) -> \%result
#
# $smc_structure_data: HASH devuelto por SMCStructureEngine::calculate().
#   Claves usadas: swing_trend (string 'bullish'|'bearish'|'neutral').
sub calculate {
    my ($self, $market_data, $smc_structure_data, %args) = @_;
    $self->reset();
    return { top => undef, bottom => undef, swing_trend => 'neutral' }
        unless $market_data;

    my $total = $market_data->size();
    return { top => undef, bottom => undef, swing_trend => 'neutral' }
        unless $total > 0;

    # Límite visible (respeta modo Replay)
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    # Running max/min sobre todas las velas hasta last_index
    my ($top_price, $top_index, $bot_price, $bot_index);
    for my $i (0 .. $last_index) {
        my $c = $market_data->get_candle($i) or next;
        next unless defined $c->{high} && defined $c->{low};
        if (!defined $top_price || $c->{high} > $top_price) {
            $top_price = $c->{high};
            $top_index = $i;
        }
        if (!defined $bot_price || $c->{low} < $bot_price) {
            $bot_price = $c->{low};
            $bot_index = $i;
        }
    }

    return { top => undef, bottom => undef, swing_trend => 'neutral' }
        unless defined $top_price && defined $bot_price;

    # Tendencia del swing desde SMCStructureEngine
    my $swing_trend = 'neutral';
    if ($smc_structure_data && ref $smc_structure_data eq 'HASH') {
        $swing_trend = $smc_structure_data->{swing_trend} // 'neutral';
    }

    # Clasificación Strong/Weak según tendencia del Pine Script de referencia
    my ($top_label, $bot_label);
    if ($swing_trend eq 'bearish') {
        # Tendencia bajista: el máximo es el origen del movimiento → Strong
        $top_label = 'Strong High';
        $bot_label = 'Weak Low';
    } elsif ($swing_trend eq 'bullish') {
        # Tendencia alcista: el mínimo es el origen del movimiento → Strong
        $top_label = 'Weak High';
        $bot_label = 'Strong Low';
    } else {
        # Neutral: ambos se consideran fuertes
        $top_label = 'Strong High';
        $bot_label = 'Strong Low';
    }

    $self->{top}    = { price => $top_price, index => $top_index, label => $top_label };
    $self->{bottom} = { price => $bot_price, index => $bot_index, label => $bot_label };

    return {
        top         => $self->{top},
        bottom      => $self->{bottom},
        swing_trend => $swing_trend,
    };
}

# Accesores públicos
sub top    { $_[0]->{top}    }
sub bottom { $_[0]->{bottom} }

1;
