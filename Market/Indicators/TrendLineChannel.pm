package Market::Indicators::TrendLineChannel;

use strict;
use warnings;

use constant DEFAULT_MIN_BARS  => 5;
use constant DEFAULT_TOLERANCE => 0.1;

sub new {
    my ($class, %args) = @_;
    return bless {
        zzmtf                   => $args{zzmtf},
        min_bars_between_pivots => $args{min_bars_between_pivots} // DEFAULT_MIN_BARS,
        touch_tolerance_atr     => $args{touch_tolerance_atr} // DEFAULT_TOLERANCE,
    }, $class;
}

sub reset {
    my ($self) = @_;
    delete $self->{_state};
    delete $self->{_direction};
    delete $self->{_m};
    delete $self->{_b};
    delete $self->{_p1};
    delete $self->{_p2};
    delete $self->{_confirm_idx};
    delete $self->{_end_idx};
    delete $self->{_events};
}

sub get_state      { $_[0]->{_state} }

sub get_line_points {
    my ($self) = @_;
    return unless $self->{_state} && $self->{_state} ne 'PENDING';
    return unless defined $self->{_p1};
    my $end = defined $self->{_end_idx} ? $self->{_end_idx} : $self->{_p2}{index};
    my $price_end = $self->{_m} * $end + $self->{_b};
    return {
        p1          => $self->{_p1},
        p2          => $self->{_p2},
        m           => $self->{_m},
        b           => $self->{_b},
        end_index   => $end,
        end_price   => $price_end,
        confirm_idx => $self->{_confirm_idx},
    };
}

sub get_events { $_[0]->{_events} || [] }

sub calculate {
    my ($self, $market_data, %args) = @_;
    return { channels => [] } unless $market_data;

    my $smc_data      = $args{smc_structure}    || {};
    my $atr_indicator = $args{atr_indicator};
    my $zzmtf         = $self->{zzmtf};

    my $end_idx = $args{view_end} // $args{end_index};
    $end_idx //= $market_data->can('last_index') ? $market_data->last_index : undef;
    $end_idx //= $market_data->size - 1;
    return { channels => [] } unless defined $end_idx && $end_idx >= 0;

    my $trend = $smc_data->{swing_trend} // '';
    return { channels => [] } unless $trend eq 'bullish' || $trend eq 'bearish';

    my $swings = $self->_get_zzmtf_swings($zzmtf);
    return { channels => [] } unless $swings && @$swings;

    my ($p1, $p2, $line_m, $line_b) = $self->_find_line_pivots($trend, $swings);
    return { channels => [] } unless $p1 && $p2;

    my $dx = $p2->{index} - $p1->{index};
    return { channels => [] } if $dx < $self->{min_bars_between_pivots};

    if (!defined $line_m) {
        $dx = 1 if $dx == 0;
        $line_m = ($p2->{price} - $p1->{price}) / $dx;
        $line_b = $p1->{price} - $line_m * $p1->{index};
    }

    my $confirm_idx = $self->_find_confirmation($market_data, $trend, $line_m, $line_b, $p2->{index} + 1, $end_idx, $atr_indicator);
    return { channels => [] } unless defined $confirm_idx;

    my $break_idx = $self->_find_break($market_data, $trend, $line_m, $line_b, $confirm_idx + 1, $end_idx);

    $self->{_state}       = defined $break_idx ? 'BROKEN' : 'CONFIRMED';
    $self->{_direction}   = $trend;
    $self->{_m}           = $line_m;
    $self->{_b}           = $line_b;
    $self->{_p1}          = $p1;
    $self->{_p2}          = $p2;
    $self->{_confirm_idx} = $confirm_idx;
    $self->{_end_idx}     = $break_idx;

    my $events = $self->{_events} ||= [];
    if ($break_idx) {
        push @$events, { type => 'trendline_break', index => $break_idx, price => $line_m * $break_idx + $line_b };
    }

    my $channel = $self->_build_channel($trend, $line_m, $line_b, $p1, $p2, $confirm_idx, $break_idx, $end_idx);
    return { channels => [$channel] };
}

sub _get_zzmtf_swings {
    my ($self, $zzmtf) = @_;
    return [] unless $zzmtf;
    if ($zzmtf->can('get_swings')) {
        my $sw = $zzmtf->get_swings();
        return $sw if $sw && @$sw;
    }
    return [];
}

sub _find_line_pivots {
    my ($self, $trend, $swings) = @_;

    if ($trend eq 'bullish') {
        my @lows = sort { $a->{index} <=> $b->{index} } grep { $_->{kind} eq 'L' } @$swings;
        return unless @lows >= 2;
        my $p1 = $lows[-2];
        my $p2 = $lows[-1];
        return unless $p2->{price} > $p1->{price};
        return ($p1, $p2);
    }

    my @highs = sort { $a->{index} <=> $b->{index} } grep { $_->{kind} eq 'H' } @$swings;
    return unless @highs >= 2;
    my $p1 = $highs[-2];
    my $p2 = $highs[-1];
    return unless $p2->{price} < $p1->{price};
    return ($p1, $p2);
}

sub _find_confirmation {
    my ($self, $md, $trend, $m, $b, $start, $end, $atr) = @_;
    for my $i ($start .. $end) {
        my $c = $md->get_candle($i);
        next unless $c;
        my $lp = $m * $i + $b;
        my $tol = $self->_atr_tolerance($atr, $i, $md);
        my $touch = 0;
        if ($trend eq 'bullish') {
            $touch = 1 if abs($c->{low} - $lp) <= $tol
                     || ($c->{low} <= $lp && $c->{close} > $lp);
        } else {
            $touch = 1 if abs($c->{high} - $lp) <= $tol
                     || ($c->{high} >= $lp && $c->{close} < $lp);
        }
        return $i if $touch;
    }
    return undef;
}

sub _find_break {
    my ($self, $md, $trend, $m, $b, $start, $end) = @_;
    for my $i ($start .. $end) {
        my $c = $md->get_candle($i);
        next unless $c;
        my $lp = $m * $i + $b;
        if ($trend eq 'bullish' && $c->{close} < $lp) { return $i }
        if ($trend eq 'bearish'  && $c->{close} > $lp) { return $i }
    }
    return undef;
}

sub _atr_tolerance {
    my ($self, $atr, $idx, $md) = @_;
    if ($atr && $atr->can('get_values')) {
        my $v = $atr->get_values;
        if ($v && @$v) {
            my $val = defined $v->[$idx] ? $v->[$idx] : $v->[-1];
            return $val * $self->{touch_tolerance_atr} if defined $val;
        }
    }
    return 0;
}

sub _build_channel {
    my ($self, $trend, $m, $b, $p1, $p2, $confirm_idx, $break_idx, $end_idx) = @_;

    my $type = 'horizontal';
    $type = 'ascending'  if $m > 0.0001;
    $type = 'descending' if $m < -0.0001;

    my $draw_end = defined $break_idx ? $break_idx : $end_idx;
    my $ch_state = defined $break_idx ? 'invalidated' : 'active';

    return {
        type  => $type,
        state => $ch_state,
        project_to_end => 1,
        support => {
            pivot1    => { index => $p1->{index}, price => $p1->{price} },
            pivot2    => { index => $p2->{index}, price => $p2->{price} },
            end_index => $draw_end,
            state     => 'active',
        },
        resistance => {
            pivot1    => { index => $p1->{index}, price => $p1->{price} },
            pivot2    => { index => $p2->{index}, price => $p2->{price} },
            end_index => $draw_end,
            state     => 'active',
        },
        slope_support    => $m,
        slope_resistance => $m,
        $break_idx ? (invalidated_at => $break_idx, break_side => 'support') : (),
    };
}

1;
