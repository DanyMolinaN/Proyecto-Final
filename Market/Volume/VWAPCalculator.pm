package Market::Volume::VWAPCalculator;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        std_dev_multiplier => $args{std_dev_multiplier} // 2,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub calculate {
    my ($self, $market_data, $anchor_index, %args) = @_;
    return {} unless $market_data;
    return {} unless defined $anchor_index;

    my $total = $market_data->size();
    return {} if $anchor_index < 0 || $anchor_index > $total - 1;

    my $sum_pv = 0;
    my $sum_v  = 0;
    my $sum_var = 0;
    my $count = 0;

    for my $index ($anchor_index .. $total - 1) {
        my $candle = $market_data->get_candle($index);
        next unless $candle;
        my $close = $candle->{close};
        my $vol   = $candle->{volume} || 0;
        next if $vol <= 0;

        my $typical = ($candle->{high} + $candle->{low} + $close) / 3;
        $sum_pv += $typical * $vol;
        $sum_v  += $vol;
        $count++;
    }

    return {} unless $sum_v > 0;

    my $vwap = $sum_pv / $sum_v;
    my $variance_sum = 0;

    for my $index ($anchor_index .. $total - 1) {
        my $candle = $market_data->get_candle($index);
        next unless $candle;
        my $close = $candle->{close};
        my $vol   = $candle->{volume} || 0;
        next if $vol <= 0;

        my $typical = ($candle->{high} + $candle->{low} + $close) / 3;
        $variance_sum += $vol * ($typical - $vwap) ** 2;
    }

    my $std_dev = sqrt($variance_sum / $sum_v);
    my $upper = $vwap + ($self->{std_dev_multiplier} * $std_dev);
    my $lower = $vwap - ($self->{std_dev_multiplier} * $std_dev);

    return {
        vwap          => $vwap,
        std_dev       => $std_dev,
        upper_band    => $upper,
        lower_band    => $lower,
        anchor_index  => $anchor_index,
        anchor_time   => $market_data->get_timestamp($anchor_index),
        total_volume  => $sum_v,
    };
}

1;
