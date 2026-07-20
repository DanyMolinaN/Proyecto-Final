package Market::Strategies::SignalEngine;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        indicator_handlers => $args{indicator_handlers} || {},
        signal_handlers    => $args{signal_handlers} || {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub register_indicator_handler {
    my ($self, $name, $code_ref) = @_;
    return unless $name && ref $code_ref eq 'CODE';
    $self->{indicator_handlers}{$name} = $code_ref;
    return 1;
}

sub register_signal_handler {
    my ($self, $name, $code_ref) = @_;
    return unless $name && ref $code_ref eq 'CODE';
    $self->{signal_handlers}{$name} = $code_ref;
    return 1;
}

sub generate {
    my ($self, %args) = @_;
    my $market_data       = $args{market_data};
    my $strategy          = $args{strategy} || {};
    my $visible_limit     = $args{visible_limit};
    my $timeframe         = $args{timeframe};
    my $replay_controller = $args{replay_controller};
    my $engine_context    = $args{engine_context} || {};

    my $signals = {
        generated   => {},
        list        => [],
        metadata    => {
            visible_limit => $visible_limit,
            timeframe     => $timeframe,
        },
    };

    return $signals unless $market_data && ref $strategy eq 'HASH';

    my $requirements = $strategy->{requires} || [];
    for my $req (@$requirements) {
        next unless $req;
        my $handler = $self->{indicator_handlers}{$req} || $self->{signal_handlers}{$req};
        next unless ref $handler eq 'CODE';
        my $result = eval {
            $handler->(
                market_data       => $market_data,
                strategy          => $strategy,
                visible_limit     => $visible_limit,
                timeframe         => $timeframe,
                replay_controller => $replay_controller,
                engine_context    => $engine_context,
            );
        };
        if ($@) {
            $signals->{generated}{$req} = { error => $@ };
            next;
        }

        $signals->{generated}{$req} = $result;
        if (ref $result eq 'HASH' && ref $result->{signals} eq 'ARRAY') {
            push @{ $signals->{list} }, @{ $result->{signals} };
        }
        elsif (ref $result eq 'ARRAY') {
            push @{ $signals->{list} }, @{ $result };
        }
    }

    return $signals;
}

1;
