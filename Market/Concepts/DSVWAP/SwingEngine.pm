package Market::Concepts::DSVWAP::SwingEngine;

use strict;
use warnings;
use Market::Concepts::DSVWAP::Event;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::SwingEngine
# Responsabilidad: Detectar pivots y swings regulares.
# Complejidad: O(1) amortizado por barra (busca localmente maximos y minimos).
# Emite: SwingConfirmedEvent
# =============================================================================

sub new {
    my ($class, $event_bus, $length) = @_;
    my $self = {
        bus    => $event_bus,
        length => $length || 50,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    # No guarda estado residual
}

sub process_bar {
    my ($self, $market_data, $index) = @_;
    
    my $len = $self->{length};
    # Un pivot se confirma cuando han pasado `length` barras a la derecha.
    # Por lo tanto, el candidato es la barra en $index - $len.
    my $c = $index - $len;
    return if $c - $len < 0; # Necesitamos length barras a la izq tambien

    # 1. Chequear Pivot High
    my $ph = $self->_check_pivot_high($market_data, $c, $len);
    if (defined $ph) {
        $self->{bus}->dispatch(
            Market::Concepts::DSVWAP::Event->swing_confirmed($c, $ph, -1)
        );
    }

    # 2. Chequear Pivot Low
    my $pl = $self->_check_pivot_low($market_data, $c, $len);
    if (defined $pl) {
        $self->{bus}->dispatch(
            Market::Concepts::DSVWAP::Event->swing_confirmed($c, $pl, 1)
        );
    }
}

sub _check_pivot_high {
    my ($self, $market_data, $c, $len) = @_;
    my $candidate = $market_data->get_candle($c);
    return undef unless $candidate;
    my $candidate_high = $candidate->{high};

    for my $k (($c - $len) .. ($c - 1)) {
        my $k_candle = $market_data->get_candle($k);
        return undef if $k_candle && $k_candle->{high} >= $candidate_high;
    }
    for my $k (($c + 1) .. ($c + $len)) {
        my $k_candle = $market_data->get_candle($k);
        return undef if $k_candle && $k_candle->{high} >= $candidate_high;
    }
    return $candidate_high;
}

sub _check_pivot_low {
    my ($self, $market_data, $c, $len) = @_;
    my $candidate = $market_data->get_candle($c);
    return undef unless $candidate;
    my $candidate_low = $candidate->{low};

    for my $k (($c - $len) .. ($c - 1)) {
        my $k_candle = $market_data->get_candle($k);
        return undef if $k_candle && $k_candle->{low} <= $candidate_low;
    }
    for my $k (($c + 1) .. ($c + $len)) {
        my $k_candle = $market_data->get_candle($k);
        return undef if $k_candle && $k_candle->{low} <= $candidate_low;
    }
    return $candidate_low;
}

1;
