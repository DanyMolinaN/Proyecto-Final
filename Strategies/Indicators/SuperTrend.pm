package Market::Strategies::Indicators::SuperTrend;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        period      => $args{period} || 10,
        multiplier  => defined $args{multiplier} ? $args{multiplier} : 3,
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
    $self->{values}  = [];
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

    my @atr_values = _compute_atr($market_data,
        period => $period,
        limit => $limit,
    );
    my @st;
    my @signals;
    my $prev_trend;
    my $prev_st;

    for my $i (0 .. $#candles) {
        my $candle = $candles[$i];
        my $atr = defined $atr_values[$i] ? $atr_values[$i] : undef;
        next unless defined $atr;

        my $hl2 = ($candle->{high} + $candle->{low}) / 2;
        my $basic_upper = $hl2 + ($multiplier * $atr);
        my $basic_lower = $hl2 - ($multiplier * $atr);

        my ($final_upper, $final_lower);
        if (!$prev_st) {
            $final_upper = $basic_upper;
            $final_lower = $basic_lower;
        } else {
            $final_upper = ($basic_upper < $prev_st->{final_upper} || $prev_st->{close} > $prev_st->{final_upper})
                ? $basic_upper
                : $prev_st->{final_upper};
            $final_lower = ($basic_lower > $prev_st->{final_lower} || $prev_st->{close} < $prev_st->{final_lower})
                ? $basic_lower
                : $prev_st->{final_lower};
        }

        my $trend = !$prev_st ? 'bullish' : $prev_trend;
        my $close = $candle->{close};
        if ($close > $final_upper) {
            $trend = 'bullish';
        }
        elsif ($close < $final_lower) {
            $trend = 'bearish';
        }
        else {
            $trend = $prev_trend if defined $prev_trend;
        }

        my $signal;
        if (defined $prev_trend && $trend ne $prev_trend) {
            $signal = {
                index => $i,
                type  => $trend eq 'bullish' ? 'supertrend_long' : 'supertrend_short',
                trend => $trend,
                close => $close,
            };
            push @signals, $signal;
        }

        $st[$i] = {
            index => $i,
            final_upper => $final_upper,
            final_lower => $final_lower,
            trend => $trend,
            close => $close,
        };
        $prev_st = $st[$i];
        $prev_trend = $trend;
    }

    $self->{values} = \@st;
    $self->{signals} = \@signals;
    $self->{metadata} = {
        timeframe    => $args{timeframe} || $market_data->active_tf(),
        visible_limit => $limit,
        period       => $period,
        multiplier   => $multiplier,
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
    my ($market_data, %args) = @_;
    my $period = $args{period};
    my $limit = $args{limit};
    my @tr;
    my @atr;
    my $prev_close;

    for (my $i = 0; $i < $market_data->size(); $i++) {
        last if defined $limit && $i > $limit;
        my $c = $market_data->get_candle($i);
        next unless $c;
        if (defined $prev_close) {
            my $high = $c->{high};
            my $low = $c->{low};
            my $tr_val = _max($high - $low, abs($high - $prev_close), abs($low - $prev_close));
            push @tr, $tr_val;
        }
        else {
            push @tr, $c->{high} - $c->{low};
        }
        $prev_close = $c->{close};
    }

    for my $i (0 .. $#tr) {
        if ($i < $period) {
            if ($i == $period - 1) {
                my $sum = 0;
                $sum += $tr[$_] for 0 .. $i;
                $atr[$i] = $sum / $period;
            }
            else {
                $atr[$i] = undef;
            }
        }
        else {
            $atr[$i] = (($atr[$i-1] * ($period - 1)) + $tr[$i]) / $period;
        }
    }

    return @atr;
}

sub _max {
    my ($a, $b, $c) = @_;
    my $max = $a;
    $max = $b if defined $b && $b > $max;
    $max = $c if defined $c && $c > $max;
    return $max;
}

1;
