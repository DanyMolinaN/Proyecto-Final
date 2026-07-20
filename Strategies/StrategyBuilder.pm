package Market::Strategies::StrategyBuilder;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Strategies::RuleEngine;
use Market::Strategies::SignalEngine;
use Market::Strategies::TradeSetup;

sub new {
    my ($class, %args) = @_;
    my $self = {
        signal_engine => $args{signal_engine} || Market::Strategies::SignalEngine->new(),
        rule_engine   => $args{rule_engine}   || Market::Strategies::RuleEngine->new(),
        setups        => $args{setups}        || [],
        strategies    => $args{strategies}    || {},
        verbose       => $args{verbose}       || 0,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub register_strategy {
    my ($self, $name, $config) = @_;
    return unless $name && ref $config eq 'HASH';
    $self->{strategies}{$name} = { config => $config };
    return 1;
}

sub load_strategy {
    my ($self, $name, $definition) = @_;
    return unless $name && $definition;

    my $strategy_def;
    if (!ref $definition) {
        my $module = $definition;
        eval "require $module";
        return unless $module && !$@;
        $strategy_def = $module->new();
    }
    else {
        $strategy_def = $definition;
    }

    return unless $strategy_def && $strategy_def->can('required_signals') && $strategy_def->can('rules');

    my $config = {
        requires => [ @{ $strategy_def->required_signals() || [] } ],
        rules    => $strategy_def->rules() || {},
    };

    $self->{strategies}{$name} = {
        definition => $strategy_def,
        config     => $config,
    };
    return 1;
}

sub execute_strategy {
    my ($self, $name, $market_data, %args) = @_;
    return unless $self->{strategies} && exists $self->{strategies}{$name};
    return unless $market_data;

    my $entry = $self->{strategies}{$name};
    my $config = $entry->{config} || {};
    my $definition = $entry->{definition};

    my $signals = $self->{signal_engine}->generate(
        market_data       => $market_data,
        strategy          => $config,
        visible_limit     => $args{visible_limit},
        timeframe         => $args{timeframe},
        replay_controller => $args{replay_controller},
        engine_context    => $args{engine_context} || {},
    );

    my $result = $self->{rule_engine}->evaluate(
        strategy      => $config,
        signals       => $signals,
        market_data   => $market_data,
        visible_limit => $args{visible_limit},
    );

    my $build_setup_result = {};
    if ($definition && $definition->can('build_setup')) {
        $build_setup_result = $definition->build_setup($signals, $market_data, $args{visible_limit}) || {};
    }

    my $merged_setup = { %{ $result->{setup} || {} }, %{ $build_setup_result || {} } };
    return undef unless ref $merged_setup eq 'HASH';
    return undef unless $merged_setup->{direction};
    return undef unless defined $merged_setup->{entry};
    return undef unless defined $merged_setup->{stop};
    return undef unless ref $merged_setup->{targets} eq 'ARRAY' && @{ $merged_setup->{targets} };

    my $setup_data = {
        name          => $name,
        strategy_name => $name,
        strategy      => $config,
        signals       => $signals,
        result        => $result,
        direction     => $merged_setup->{direction},
        entry         => $merged_setup->{entry},
        stop          => $merged_setup->{stop},
        targets       => $merged_setup->{targets},
        confidence    => $merged_setup->{confidence} // 0,
        visible_limit => $args{visible_limit},
        timeframe     => $args{timeframe},
        timestamp     => time(),
        metadata      => {
            setup      => $merged_setup,
            definition => $definition ? ($definition->{name} || ref $definition) : undef,
        },
    };

    my $setup = Market::Strategies::TradeSetup->new(%$setup_data);
    return $setup;
}

sub execute_all {
    my ($self, $market_data, %args) = @_;
    return [] unless $market_data;

    my @setups;
    for my $name (sort keys %{ $self->{strategies} || {} }) {
        my $setup = $self->execute_strategy($name, $market_data, %args);
        push @setups, $setup if $setup;
    }
    return \@setups;
}

sub build_setups {
    my ($self, $market_data, %args) = @_;
    return [] unless $market_data;

    my @all_setups;
    for my $name (sort keys %{ $self->{strategies} || {} }) {
        my $setup = $self->execute_strategy($name, $market_data, %args);
        push @all_setups, $setup if $setup;
    }

    $self->{setups} = \@all_setups;
    return \@all_setups;
}

sub get_setups {
    my ($self) = @_;
    return $self->{setups} || [];
}

1;
