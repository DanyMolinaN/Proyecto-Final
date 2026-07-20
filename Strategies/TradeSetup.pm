package Market::Strategies::TradeSetup;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        name          => $args{name},
        strategy_name => $args{strategy_name} || $args{name},
        strategy      => $args{strategy} || {},
        signals       => $args{signals} || {},
        result        => $args{result} || {},
        direction     => $args{direction},
        entry         => $args{entry},
        stop          => $args{stop},
        targets       => $args{targets},
        confidence    => $args{confidence},
        visible_limit => $args{visible_limit},
        timeframe     => $args{timeframe},
        timestamp     => $args{timestamp} || time(),
        metadata      => $args{metadata} || {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub as_hash {
    my ($self) = @_;
    return {
        name          => $self->{name},
        strategy_name => $self->{strategy_name},
        strategy      => $self->{strategy},
        signals       => $self->{signals},
        result        => $self->{result},
        direction     => $self->{direction},
        entry         => $self->{entry},
        stop          => $self->{stop},
        targets       => $self->{targets},
        confidence    => $self->{confidence},
        visible_limit => $self->{visible_limit},
        timeframe     => $self->{timeframe},
        timestamp     => $self->{timestamp},
        metadata      => $self->{metadata},
    };
}

1;
