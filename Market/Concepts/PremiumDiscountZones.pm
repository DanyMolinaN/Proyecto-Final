package Market::Concepts::PremiumDiscountZones;

# =============================================================================
# Market::Concepts::PremiumDiscountZones  — v1.0
# =============================================================================
# Calcula las zonas Premium, Discount y Equilibrium a partir del rango
# definido por los extremos trailing (top/bottom) de TrailingExtremes.
#
# Proporciones exactas del Pine Script de referencia (Smart Money Concepts Pro):
#   Premium zone:     95% - 100% del rango (banda superior)
#   Discount zone:    0%  -   5% del rango (banda inferior)
#   Equilibrium zone: 47.5% - 52.5% del rango (banda central angosta)
#
# Las zonas se extienden horizontalmente desde el índice del extremo
# más antiguo hasta el borde visible actual (last_index).
#
# Salida de calculate():
#   {
#     premium     => { high => $p, low => $p, start_index => $i, end_index => $i },
#     discount    => { high => $p, low => $p, start_index => $i, end_index => $i },
#     equilibrium => { high => $p, low => $p, start_index => $i, end_index => $i },
#     range_top   => $price,
#     range_bottom=> $price,
#   }
# =============================================================================

use strict;
use warnings;

# Proporciones del Pine Script de referencia
use constant PREMIUM_HIGH   => 1.000;
use constant PREMIUM_LOW    => 0.950;
use constant DISCOUNT_HIGH  => 0.050;
use constant DISCOUNT_LOW   => 0.000;
use constant EQ_HIGH        => 0.525;
use constant EQ_LOW         => 0.475;

sub new {
    my ($class, %args) = @_;
    my $self = {};
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    return $self;
}

# calculate($market_data, $trailing_data, %args) -> \%result
#
# $trailing_data: HASH devuelto por TrailingExtremes::calculate().
#   Claves usadas: top => {price, index}, bottom => {price, index}
sub calculate {
    my ($self, $market_data, $trailing_data, %args) = @_;
    my $empty = {
        premium     => undef,
        discount    => undef,
        equilibrium => undef,
        range_top   => undef,
        range_bottom=> undef,
    };

    return $empty unless $market_data && $trailing_data;
    return $empty unless ref $trailing_data eq 'HASH';

    my $top_data = $trailing_data->{top};
    my $bot_data = $trailing_data->{bottom};
    return $empty unless defined $top_data && defined $bot_data;
    return $empty unless defined $top_data->{price} && defined $bot_data->{price};

    my $top    = $top_data->{price};
    my $bottom = $bot_data->{price};
    my $range  = $top - $bottom;
    return $empty if $range <= 0;

    # Determinar índice de inicio (el más antiguo de top/bottom)
    my $start_index = ($top_data->{index} < $bot_data->{index})
        ? $top_data->{index}
        : $bot_data->{index};

    # Determinar last_index visible
    my $total = $market_data->size();
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $end_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    # Función auxiliar: precio en proporción del rango (0=bottom, 1=top)
    # price_at(ratio) = bottom + ratio * range
    my $price_at = sub {
        my ($ratio) = @_;
        return $bottom + $ratio * $range;
    };

    return {
        premium => {
            high        => $price_at->(PREMIUM_HIGH),
            low         => $price_at->(PREMIUM_LOW),
            start_index => $start_index,
            end_index   => $end_index,
        },
        discount => {
            high        => $price_at->(DISCOUNT_HIGH),
            low         => $price_at->(DISCOUNT_LOW),
            start_index => $start_index,
            end_index   => $end_index,
        },
        equilibrium => {
            high        => $price_at->(EQ_HIGH),
            low         => $price_at->(EQ_LOW),
            start_index => $start_index,
            end_index   => $end_index,
        },
        range_top    => $top,
        range_bottom => $bottom,
    };
}

1;
