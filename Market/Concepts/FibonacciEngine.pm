package Market::Concepts::FibonacciEngine;

# =============================================================================
# Market::Concepts::FibonacciEngine  — v2.0
# =============================================================================
# Calcula niveles de retroceso de Fibonacci anclados en el último swing
# (interno o externo) detectado por SMCStructureEngine.
#
# CAMBIO v2.0 (Fix Fase 0):
#   El segundo argumento de calculate() ahora es el HASH ya calculado por
#   SMCStructureEngine::calculate() (igual que OrderBlockEngine), NO el objeto
#   motor. Esto elimina la llamada `->structure()` que producía el crash.
#
# Fuente de swings: $smc_structure_data->{swing_highs} y
#   $smc_structure_data->{swing_lows}.  Cada entrada tiene:
#     { index => $i, level => $price, label => 'HH'|'HL'|'LH'|'LL', ... }
#   Se usa 'level' como precio (nunca 'price').
#
# Lógica de anclaje:
#   - Se combinan swing_highs y swing_lows en un único array.
#   - El "último swing" es el de mayor índice (el más reciente).
#   - Los niveles de Fibonacci se calculan como retroceso desde ese swing
#     hacia el precio actual del cierre de la última vela visible.
# =============================================================================

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        fibs => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{fibs} = [];
    return $self;
}

# calculate($market_data, $smc_structure_data, %args) -> \%result
#
# $smc_structure_data es el HASH devuelto por SMCStructureEngine::calculate().
# Claves usadas: swing_highs, swing_lows  (cada entrada: {index, level, label}).
sub calculate {
    my ($self, $market_data, $smc_structure_data, %args) = @_;
    return { active => [] } unless $market_data && $smc_structure_data;
    return { active => [] } unless ref $smc_structure_data eq 'HASH';

    $self->reset();

    # ── Determinar índice visible ──────────────────────────────────────────
    my $total = $market_data->size();
    return { active => [] } unless $total > 0;

    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $current_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    # ── Combinar swing_highs y swing_lows del hash SMC ─────────────────────
    my @swing_highs = @{ $smc_structure_data->{swing_highs} || [] };
    my @swing_lows  = @{ $smc_structure_data->{swing_lows}  || [] };

    my @external_swings = sort { $a->{index} <=> $b->{index} } (@swing_highs, @swing_lows);
    @external_swings = grep { $_->{index} <= $current_index } @external_swings;

    return { active => [] } if @external_swings < 2;

    # ── Tomar los dos últimos swings externos ──────────────────────────────
    my $p1 = $external_swings[-2];
    my $p2 = $external_swings[-1];

    my $start_price = $p1->{level};
    my $end_price   = $p2->{level};
    my $start_index = $p1->{index};
    my $end_index   = $p2->{index};

    # ── Niveles de Fibonacci estándar ─────────────────────────────────────
    my @fib_ratios = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);

    # Diferencia entre P2 (fin del impulso) y P1 (inicio del impulso)
    my $diff = $end_price - $start_price;

    my @fib_levels;
    for my $ratio (@fib_ratios) {
        # Retroceso desde P2 hacia P1:
        # nivel = P2 - ratio * diff
        my $level_price = $end_price - $ratio * $diff;
        push @fib_levels, {
            level       => $ratio,
            price       => $level_price,
            start_index => $start_index,
            end_index   => $end_index,
        };
    }

    $self->{fibs} = \@fib_levels;
    return { active => $self->{fibs} };
}

1;
