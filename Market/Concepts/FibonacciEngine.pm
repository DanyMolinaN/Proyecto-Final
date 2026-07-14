package Market::Concepts::FibonacciEngine;

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

sub calculate {
    my ($self, $market_data, $structure_engine, %args) = @_;
    return {} unless $market_data && $structure_engine;
    
    $self->reset();
    
    my $structure_data = $structure_engine->structure();
    my $swings = $structure_data->{external_swings} || [];
    
    return {} unless @$swings;
    
    my $last_swing = $swings->[-1];
    return {} unless $last_swing && defined $last_swing->{index} && defined $last_swing->{price};
    
    my $current_index = $market_data->size() - 1;
    my $visible_limit = $args{replay_controller} && $args{replay_controller}->can('visible_limit')
        ? $args{replay_controller}->visible_limit($market_data->size())
        : undef;
    $current_index = $visible_limit if defined $visible_limit && $visible_limit >= 0 && $visible_limit <= $current_index;
    
    my $current_candle = $market_data->get_candle($current_index);
    return {} unless $current_candle;
    
    my $current_price = $current_candle->{close};
    
    my $start_price = $last_swing->{price};
    my $start_index = $last_swing->{index};
    
    my @levels = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1);
    
    my $diff = $current_price - $start_price;
    
    my @fib_levels;
    for my $l (@levels) {
        # 0% es el precio actual (final del movimiento)
        # 100% es el precio del swing (inicio del movimiento)
        my $price = $current_price - $l * $diff;
        push @fib_levels, {
            level => $l,
            price => $price,
            start_index => $start_index,
            end_index => $current_index,
        };
    }
    
    $self->{fibs} = \@fib_levels;
    return { active => $self->{fibs} };
}

1;
