package Market::Strategies::Indicators::SupplyDemand;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        lookback       => $args{lookback} || 20,
        strength       => $args{strength} || 3,
        zones          => [],
        signals        => [],
        metadata       => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{zones} = [];
    $self->{signals} = [];
    $self->{metadata} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $limit = _visible_limit($market_data, $args{replay_controller});
    my $lookback = $self->{lookback};

    my @candles;
    for (my $i = 0; $i < $market_data->size(); $i++) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        push @candles, $c if $c;
    }
    return {} unless @candles;

    my @zones;
    my @signals;

    for my $i ($lookback - 1 .. $#candles) {
        my $window = [ @candles[$i - $lookback + 1 .. $i] ];
        my ($high, $low) = _window_high_low($window);
        my $candle = $candles[$i];

        next unless $candle;
        my $body = abs($candle->{close} - $candle->{open});
        my $range = $candle->{high} - $candle->{low};
        next if $range <= 0;

        my $is_supply = $candle->{close} < $candle->{open} && $body >= ($range * 0.5);
        my $is_demand = $candle->{close} > $candle->{open} && $body >= ($range * 0.5);

        if ($is_supply) {
            my $zone = {
                type           => 'supply',
                index          => $i,
                high           => $candle->{high},
                low            => $candle->{low},
                strength       => $self->{strength},
                confirmation_index => $i,
            };
            push @zones, $zone;
            push @signals, {
                index => $i,
                type  => 'supply_zone',
                zone  => $zone,
            };
        }
        elsif ($is_demand) {
            my $zone = {
                type           => 'demand',
                index          => $i,
                high           => $candle->{high},
                low            => $candle->{low},
                strength       => $self->{strength},
                confirmation_index => $i,
            };
            push @zones, $zone;
            push @signals, {
                index => $i,
                type  => 'demand_zone',
                zone  => $zone,
            };
        }
    }

    $self->{zones} = \@zones;
    $self->{signals} = \@signals;

    my $eval_idx = defined $limit && $limit >= 0 ? $limit : ($#candles);
    if ($eval_idx >= 0 && $candles[$eval_idx]) {
        my $c = $candles[$eval_idx];
        for my $zone (@zones) {
            next unless ($zone->{type} || '') eq 'supply';
            if ($c->{high} >= $zone->{low} && $c->{low} <= $zone->{high}) {
                push @signals, {
                    index => $eval_idx,
                    type  => 'supply_touched',
                    zone  => $zone,
                };
                last;
            }
        }
        $self->{signals} = \@signals;
    }

    $self->{metadata} = {
        timeframe      => $args{timeframe} || $market_data->active_tf(),
        visible_limit  => $limit,
        lookback       => $lookback,
        zone_count     => scalar(@zones),
    };

    return {
        zones    => $self->{zones},
        signals  => $self->{signals},
        metadata => $self->{metadata},
    };
}

sub signals {
    my ($self) = @_;
    return $self->{signals} || [];
}

sub _visible_limit {
    my ($market_data, $replay_controller) = @_;
    return undef unless $replay_controller && $replay_controller->can('visible_limit');
    return $replay_controller->visible_limit($market_data->size());
}

sub _window_high_low {
    my ($window) = @_;
    my ($high, $low);
    for my $c (@$window) {
        next unless $c;
        $high = $c->{high} if !defined $high || $c->{high} > $high;
        $low  = $c->{low}  if !defined $low  || $c->{low}  < $low;
    }
    return ($high // 0, $low // 0);
}

1;
