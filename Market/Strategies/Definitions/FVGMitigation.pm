package Market::Strategies::Definitions::FVGMitigation;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        name => 'FVGMitigation',
        %args,
    };
    bless $self, $class;
    return $self;
}

sub required_signals {
    return [
        'supertrend_bullish',
        'fvg_bullish_active',
        'orderblock_bullish_active',
    ];
}

sub rules {
    return {
        mitigation => {
            type => 'setup',
            direction => 'long',
            entry => 'market',
            stop => 'below_fvg',
            targets => ['1.0R', '2.0R'],
            confidence => 0.82,
            signals_all => [
                'supertrend_bullish',
                'fvg_bullish_active',
                'orderblock_bullish_active',
            ],
        },
    };
}

sub build_setup {
    my ($self, $signals, $market_data, $visible_limit) = @_;
    return {
        direction => 'long',
        entry => 'market',
        stop => 'below_fvg',
        targets => ['1.0R', '2.0R'],
        confidence => 0.82,
    };
}

1;
