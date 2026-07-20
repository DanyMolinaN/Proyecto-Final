package Market::Strategies::Definitions::CHOCHReversal;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        name => 'CHOCHReversal',
        %args,
    };
    bless $self, $class;
    return $self;
}

sub required_signals {
    return [
        'choch_bearish',
        'fvg_bearish_active',
        'supply_touched',
    ];
}

sub rules {
    return {
        reversal => {
            type => 'setup',
            direction => 'short',
            entry => 'market',
            stop => 'above_fvg',
            targets => ['1.0R', '1.5R'],
            confidence => 0.78,
            signals_all => [
                'choch_bearish',
                'fvg_bearish_active',
                'supply_touched',
            ],
        },
    };
}

sub build_setup {
    my ($self, $signals, $market_data, $visible_limit) = @_;
    return {
        direction => 'short',
        entry => 'market',
        stop => 'above_fvg',
        targets => ['1.0R', '1.5R'],
        confidence => 0.78,
    };
}

1;
