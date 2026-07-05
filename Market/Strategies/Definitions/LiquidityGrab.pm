package Market::Strategies::Definitions::LiquidityGrab;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        name => 'LiquidityGrab',
        %args,
    };
    bless $self, $class;
    return $self;
}

sub required_signals {
    return [
        'range_filter_trending',
        'liquidity_sweep',
        'orderblock_bullish_active',
    ];
}

sub rules {
    return {
        grab => {
            type => 'setup',
            direction => 'long',
            entry => 'market',
            stop => 'below_liquidity',
            targets => ['1.0R', '1.5R'],
            confidence => 0.8,
            signals_all => [
                'range_filter_trending',
                'liquidity_sweep',
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
        stop => 'below_liquidity',
        targets => ['1.0R', '1.5R'],
        confidence => 0.8,
    };
}

1;
