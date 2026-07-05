package Market::Strategies::SignalRegistry;

use strict;
use warnings;

use Market::Strategies::Indicators::SuperTrend;
use Market::Strategies::Indicators::RangeFilter;
use Market::Strategies::Indicators::SupplyDemand;

my $_supertrend;
my $_range_filter;
my $_supply_demand;

sub register_all {
    my ($signal_engine) = @_;
    return unless $signal_engine && $signal_engine->can('register_signal_handler');

    $_supertrend    ||= Market::Strategies::Indicators::SuperTrend->new();
    $_range_filter  ||= Market::Strategies::Indicators::RangeFilter->new();
    $_supply_demand ||= Market::Strategies::Indicators::SupplyDemand->new();

    my %handlers = (
        supertrend_long            => \&_h_supertrend_long,
        supertrend_bullish         => \&_h_supertrend_bullish,
        bos_bullish                => \&_h_bos_bullish,
        choch_bearish              => \&_h_choch_bearish,
        fvg_bullish_active         => \&_h_fvg_bullish_active,
        fvg_bearish_active         => \&_h_fvg_bearish_active,
        orderblock_bullish_active  => \&_h_orderblock_bullish_active,
        ssl_sweep                  => \&_h_ssl_sweep,
        liquidity_sweep            => \&_h_liquidity_sweep,
        range_filter_trending      => \&_h_range_filter_trending,
        supply_touched             => \&_h_supply_touched,
    );

    for my $name (keys %handlers) {
        $signal_engine->register_signal_handler($name, $handlers{$name});
    }
    return 1;
}

sub _eval_index {
    my (%args) = @_;
    my $md = $args{market_data};
    return -1 unless $md;
    my $total = $md->size();
    return -1 unless $total > 0;
    my $rc = $args{replay_controller};
    if ($rc && $rc->can('visible_limit')) {
        my $lim = $rc->visible_limit($total);
        return $lim if defined $lim && $lim >= 0 && $lim < $total;
    }
    return $total - 1;
}

sub _cache {
    my (%args) = @_;
    my $ec = $args{engine_context} || {};
    return $ec->{analysis_cache} || {};
}

sub _emit {
    my ($type, $index) = @_;
    return { signals => [ { type => $type, index => $index } ] };
}

sub _empty { return { signals => [] }; }

sub _recent {
    my ($idx, $bars) = @_;
    $bars //= 120;
    return $idx - $bars;
}

sub _h_supertrend_long {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    return _empty() if $idx < 0;

    my $r = $_supertrend->calculate(
        $args{market_data},
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
    );
    my $values = $r->{values} || [];
    my $v = $values->[$idx];
    return _emit('supertrend_long', $idx)
        if $v && ($v->{trend} || '') eq 'bullish';

    for my $sig (@{ $r->{signals} || [] }) {
        next unless ($sig->{type} || '') eq 'supertrend_long';
        return _emit('supertrend_long', $sig->{index}) if $sig->{index} >= _recent($idx);
    }
    return _empty();
}

sub _h_supertrend_bullish {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    return _empty() if $idx < 0;

    my $r = $_supertrend->calculate(
        $args{market_data},
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
    );
    my $values = $r->{values} || [];
    my $v = $values->[$idx];
    return _emit('supertrend_bullish', $idx)
        if $v && ($v->{trend} || '') eq 'bullish';
    return _empty();
}

sub _h_bos_bullish {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $breaks = $cache->{structure}{breaks} || [];
    for my $b (reverse @$breaks) {
        next unless ($b->{direction} || '') eq 'bullish';
        my $ci = $b->{confirmation_index} // $b->{index};
        next unless defined $ci && $ci <= $idx && $ci >= _recent($idx);
        return _emit('bos_bullish', $ci);
    }
    return _empty();
}

sub _h_choch_bearish {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $changes = $cache->{structure}{changes} || [];
    for my $c (reverse @$changes) {
        next unless ($c->{direction} || '') eq 'bearish';
        my $ci = $c->{confirmation_index} // $c->{index};
        next unless defined $ci && $ci <= $idx && $ci >= _recent($idx);
        return _emit('choch_bearish', $ci);
    }
    return _empty();
}

sub _h_fvg_bullish_active {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $active = $cache->{fvg}{active} || [];
    for my $g (@$active) {
        next unless ($g->{type} || '') eq 'bullish';
        next if ($g->{state} || '') eq 'Mitigated';
        my $ci = $g->{created_index} // $g->{index};
        next unless defined $ci && $ci <= $idx;
        return _emit('fvg_bullish_active', $ci);
    }
    return _empty();
}

sub _h_fvg_bearish_active {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $active = $cache->{fvg}{active} || [];
    for my $g (@$active) {
        next unless ($g->{type} || '') eq 'bearish';
        next if ($g->{state} || '') eq 'Mitigated';
        my $ci = $g->{created_index} // $g->{index};
        next unless defined $ci && $ci <= $idx;
        return _emit('fvg_bearish_active', $ci);
    }
    return _empty();
}

sub _h_orderblock_bullish_active {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $active = $cache->{order_block}{active} || [];
    for my $b (@$active) {
        next unless ($b->{type} || '') eq 'bullish';
        my $oi = $b->{origin_index} // $b->{index};
        next unless defined $oi && $oi <= $idx;
        return _emit('orderblock_bullish_active', $oi);
    }
    return _empty();
}

sub _h_ssl_sweep {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $events = $cache->{liquidity}{events} || [];
    for my $e (reverse @$events) {
        next unless ($e->{type} || '') =~ /Sweep/i;
        next unless ($e->{level_type} || '') eq 'SSL';
        my $end = $e->{end} // $e->{index};
        next unless defined $end && $end <= $idx && $end >= _recent($idx);
        return _emit('ssl_sweep', $end);
    }
    return _empty();
}

sub _h_liquidity_sweep {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    my $cache = _cache(%args);
    my $events = $cache->{liquidity}{events} || [];
    for my $e (reverse @$events) {
        next unless ($e->{type} || '') =~ /Sweep/i;
        my $end = $e->{end} // $e->{index};
        next unless defined $end && $end <= $idx && $end >= _recent($idx);
        return _emit('liquidity_sweep', $end);
    }
    return _empty();
}

sub _h_range_filter_trending {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    return _empty() if $idx < 0;

    my $r = $_range_filter->calculate(
        $args{market_data},
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
    );
    my $values = $r->{values} || [];
    my $v = $values->[$idx];
    return _emit('range_filter_trending', $idx)
        if $v && ($v->{state} || '') eq 'trending';
    return _empty();
}

sub _h_supply_touched {
    my (%args) = @_;
    my $idx = _eval_index(%args);
    return _empty() if $idx < 0;

    my $md = $args{market_data};
    my $candle = $md->get_candle($idx);
    return _empty() unless $candle;

    my $r = $_supply_demand->calculate(
        $md,
        replay_controller => $args{replay_controller},
        timeframe         => $args{timeframe},
    );
    for my $zone (@{ $r->{zones} || [] }) {
        next unless ($zone->{type} || '') eq 'supply';
        next unless $candle->{high} >= $zone->{low} && $candle->{low} <= $zone->{high};
        return _emit('supply_touched', $idx);
    }
    return _empty();
}

1;
