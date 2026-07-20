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

    # Agregar también internos para mayor densidad de puntos de anclaje
    my @int_highs   = @{ $smc_structure_data->{internal_highs} || [] };
    my @int_lows    = @{ $smc_structure_data->{internal_lows}  || [] };

    my @all_swings = (@swing_highs, @swing_lows, @int_highs, @int_lows);
    return { active => [] } unless @all_swings;

    # ── Encontrar el swing más reciente (mayor índice ≤ current_index) ─────
    my $last_swing;
    for my $sw (@all_swings) {
        next unless ref $sw eq 'HASH';
        next unless defined $sw->{index} && defined $sw->{level};
        next if $sw->{index} > $current_index;
        if (!defined $last_swing || $sw->{index} > $last_swing->{index}) {
            $last_swing = $sw;
        }
    }
    return { active => [] } unless defined $last_swing;

    # ── Precio actual (cierre de la última vela visible) ───────────────────
    my $current_candle = $market_data->get_candle($current_index);
    return { active => [] } unless $current_candle;
    my $current_price = $current_candle->{close};
    return { active => [] } unless defined $current_price;

    # ── Ancla del retroceso: nivel del swing más reciente ─────────────────
    my $start_price = $last_swing->{level};   # usa 'level', nunca 'price'
    my $start_index = $last_swing->{index};

    # ── Niveles de Fibonacci estándar ─────────────────────────────────────
    my @fib_ratios = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);

    # Diferencia entre el cierre actual y el swing de anclaje:
    #   0%   = precio del swing (origen del movimiento)
    #   100% = precio actual    (extremo del movimiento)
    my $diff = $current_price - $start_price;

    my @fib_levels;
    for my $ratio (@fib_ratios) {
        # Retroceso desde current_price hacia start_price:
        #   nivel = current_price - ratio * diff
        # Cuando ratio=0  → current_price   (extremo actual)
        # Cuando ratio=1  → start_price     (ancla/swing)
        my $level_price = $current_price - $ratio * $diff;
        push @fib_levels, {
            level       => $ratio,
            price       => $level_price,
            start_index => $start_index,
            end_index   => $current_index,
        };
    }

    $self->{fibs} = \@fib_levels;
    return { active => $self->{fibs} };
}

1;
