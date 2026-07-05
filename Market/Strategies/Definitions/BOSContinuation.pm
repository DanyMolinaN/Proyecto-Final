package Market::Strategies::Definitions::BOSContinuation;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        name => 'BOSContinuation',
        %args,
    };
    bless $self, $class;
    return $self;
}

sub required_signals {
    return [
        'supertrend_long',
        'bos_bullish',
        'orderblock_bullish_active',
        'ssl_sweep',
    ];
}

sub rules {
    return {
        continuation => {
            type => 'setup',
            direction => 'long',
            entry => 'market',
            stop => 'below_orderblock',
            targets => ['1.0R', '1.5R'],
            confidence => 0.85,
            signals_all => [
                'supertrend_long',
                'bos_bullish',
                'orderblock_bullish_active',
                'ssl_sweep',
            ],
        },
    };
}

sub build_setup {
    my ($self, $signals, $market_data, $visible_limit) = @_;
    return {
        direction => 'long',
        entry => 'market',
        stop => 'below_orderblock',
        targets => ['1.0R', '1.5R'],
        confidence => 0.85,
    };
}

1;
