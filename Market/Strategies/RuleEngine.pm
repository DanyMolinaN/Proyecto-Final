package Market::Strategies::RuleEngine;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        rules => {
            signal_present => \&_rule_signal_present,
            all_signals    => \&_rule_all_signals,
            any_signals    => \&_rule_any_signals,
            setup          => \&_rule_setup,
            %{ $args{rules} || {} },
        },
        %args,
    };
    bless $self, $class;
    return $self;
}

sub register_rule {
    my ($self, $name, $code_ref) = @_;
    return unless $name && ref $code_ref eq 'CODE';
    $self->{rules}{$name} = $code_ref;
    return 1;
}

sub evaluate {
    my ($self, %args) = @_;
    my $strategy      = $args{strategy}      || {};
    my $signals       = $args{signals}       || {};
    my $market_data   = $args{market_data};
    my $visible_limit = $args{visible_limit};

    my $evaluated = {
        passes => {},
        fails  => {},
        details => {},
    };

    return $evaluated unless ref $strategy eq 'HASH';

    my $rules = $strategy->{rules} || {};
    for my $rule_name (sort keys %$rules) {
        my $rule_def = $rules->{$rule_name};
        next unless ref $rule_def eq 'HASH';
        my $rule_type = $rule_def->{type} || 'custom';

        my $rule_fn = $self->{rules}{$rule_type};
        unless ($rule_fn && ref $rule_fn eq 'CODE') {
            $evaluated->{fails}{$rule_name} = 'missing_rule_definition';
            next;
        }

        my $result = eval {
            $rule_fn->(
                signals       => $signals,
                strategy      => $strategy,
                market_data   => $market_data,
                visible_limit => $visible_limit,
                rule          => $rule_def,
            );
        };

        if ($@) {
            $evaluated->{fails}{$rule_name} = 'rule_error:' . $@;
        }
        elsif ($result) {
            $evaluated->{passes}{$rule_name} = 1;
            $evaluated->{details}{$rule_name} = $result;
            if (ref $result eq 'HASH' && ($result->{direction} || $result->{entry} || $result->{targets})) {
                $evaluated->{setup} = $result;
            }
        }
        else {
            $evaluated->{fails}{$rule_name} = 0;
            $evaluated->{details}{$rule_name} = $result;
        }
    }

    return $evaluated;
}

sub _rule_signal_present {
    my (%args) = @_;
    my $signals = $args{signals} || {};
    my $rule    = $args{rule} || {};
    my $signal_type = $rule->{signal};
    return 0 unless $signal_type;

    for my $entry (@{ $signals->{list} || [] }) {
        return 1 if $entry->{type} && $entry->{type} eq $signal_type;
    }
    return 0;
}

sub _rule_all_signals {
    my (%args) = @_;
    my $signals = $args{signals} || {};
    my $rule    = $args{rule} || {};
    my $required = $rule->{signals} || [];
    return 0 unless ref $required eq 'ARRAY' && @$required;

    my %found;
    for my $entry (@{ $signals->{list} || [] }) {
        next unless $entry->{type};
        $found{$entry->{type}} = 1;
    }

    for my $req (@$required) {
        return 0 unless $found{$req};
    }
    return 1;
}

sub _rule_any_signals {
    my (%args) = @_;
    my $signals = $args{signals} || {};
    my $rule    = $args{rule} || {};
    my $required = $rule->{signals} || [];
    return 0 unless ref $required eq 'ARRAY' && @$required;

    my %found;
    for my $entry (@{ $signals->{list} || [] }) {
        next unless $entry->{type};
        $found{$entry->{type}} = 1;
    }

    for my $req (@$required) {
        return 1 if $found{$req};
    }
    return 0;
}

sub _rule_setup {
    my (%args) = @_;
    my $signals = $args{signals} || {};
    my $rule    = $args{rule} || {};

    if (my $signal = $rule->{signal}) {
        return 0 unless _rule_signal_present(signals => $signals, rule => { signal => $signal });
    }
    if (my $all = $rule->{signals_all}) {
        return 0 unless _rule_all_signals(signals => $signals, rule => { signals => $all });
    }
    if (my $any = $rule->{signals_any}) {
        return 0 unless _rule_any_signals(signals => $signals, rule => { signals => $any });
    }

    return {
        direction  => $rule->{direction},
        entry      => $rule->{entry},
        stop       => $rule->{stop},
        targets    => $rule->{targets},
        confidence => $rule->{confidence} // 0,
    };
}

1;
