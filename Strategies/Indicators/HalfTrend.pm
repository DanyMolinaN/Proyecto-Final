package Market::Strategies::Indicators::HalfTrend;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        period         => $args{period} || 10,
        multiplier     => defined $args{multiplier} ? $args{multiplier} : 2,
        values         => [],
        signals        => [],
        metadata       => {},
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
    my $multiplier = $self->{multiplier};

    my @candles;
    for (my $i = 0; $i < $market_data->size(); $i++) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        push @candles, $c if $c;
    }
    return {} unless @candles;

    my @ht;
    my @signals;
    my $prev_trend;
    my $prev_final = undef;

    for my $i (0 .. $#candles) {
        my $candle = $candles[$i];
        my $hl2 = ($candle->{high} + $candle->{low}) / 2;
        my $atr = _compute_atr($market_data, $period, $i, $limit);
        next unless defined $atr;

        my $basic_value = $hl2 + ($multiplier * $atr);
        my $final = defined $prev_final ? ($basic_value + $prev_final) / 2 : $basic_value;
        my $trend;
        my $close = $candle->{close};

        if (defined $prev_final) {
            $trend = $close >= $prev_final ? 'bullish' : 'bearish';
        }
        else {
            $trend = 'bullish';
        }

        if (defined $prev_trend && $trend ne $prev_trend) {
            push @signals, {
                index => $i,
                type  => $trend eq 'bullish' ? 'halftrend_long' : 'halftrend_short',
                trend => $trend,
            };
        }

        push @ht, {
            index => $i,
            value => $final,
            trend => $trend,
            close => $close,
        };

        $prev_trend = $trend;
        $prev_final = $final;
    }

    $self->{values} = \@ht;
    $self->{signals} = \@signals;
    $self->{metadata} = {
        timeframe     => $args{timeframe} || $market_data->active_tf(),
        visible_limit => $limit,
        period        => $period,
        multiplier    => $multiplier,
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

sub _compute_atr {
    my ($market_data, $period, $index, $limit) = @_;
    return undef if $index <= 0;
    my $start = $index - $period + 1;
    $start = 0 if $start < 0;
    return undef if defined $limit && $index > $limit;

    my @trs;
    my $prev_close;
    for my $i ($start .. $index) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        next unless $c;
        if (defined $prev_close) {
            my $high = $c->{high};
            my $low = $c->{low};
            push @trs, _max($high - $low, abs($high - $prev_close), abs($low - $prev_close));
        }
        else {
            push @trs, $c->{high} - $c->{low};
        }
        $prev_close = $c->{close};
    }

    return undef unless @trs >= $period;
    my $sum = 0;
    $sum += $_ for @trs;
    return $sum / @trs;
}

sub _max {
    my ($a, $b, $c) = @_;
    my $max = $a;
    $max = $b if defined $b && $b > $max;
    $max = $c if defined $c && $c > $max;
    return $max;
}

1;
