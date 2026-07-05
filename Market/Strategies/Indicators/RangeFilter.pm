package Market::Strategies::Indicators::RangeFilter;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        period      => $args{period} || 20,
        threshold   => defined $args{threshold} ? $args{threshold} : 0.005,
        values      => [],
        signals     => [],
        metadata    => {},
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{values} = [];
    $self->{signals} = [];
    $self->{metadata} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    return {} unless $market_data;

    my $limit = _visible_limit($market_data, $args{replay_controller});
    my $period = $self->{period};
    my $threshold = $self->{threshold};

    my @candles;
    for (my $i = 0; $i < $market_data->size(); $i++) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        push @candles, $c if $c;
    }
    return {} unless @candles >= $period;

    my @values;
    my @signals;

    for my $i (0 .. $#candles) {
        my $candle = $candles[$i];
        if ($i >= $period - 1) {
            my $window = [ @candles[$i - $period + 1 .. $i] ];
            my ($high, $low) = _window_high_low($window);
            my $range = $high - $low;
            my $close = $candle->{close};
            my $percent = $range ? $range / $low : 0;
            my $state = $percent <= $threshold ? 'ranging' : 'trending';
            push @values, {
                index   => $i,
                high    => $high,
                low     => $low,
                range   => $range,
                percent => $percent,
                state   => $state,
            };
            push @signals, {
                index => $i,
                type  => $state eq 'ranging' ? 'range_filter_ranging' : 'range_filter_trending',
                state => $state,
            };
        }
        else {
            push @values, undef;
        }
    }

    $self->{values} = \@values;
    $self->{signals} = \@signals;
    $self->{metadata} = {
        timeframe => $args{timeframe} || $market_data->active_tf(),
        visible_limit => $limit,
        period   => $period,
        threshold => $threshold,
    };

    return {
        values   => $self->{values},
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
