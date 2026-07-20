package Market::Indicators::TrendLine;

use strict;
use warnings;
use Carp;
use Market::Indicators::ZigZag;

use constant TRENDLINE_MIN_CANDLE_SEP => 8;

sub new {
    my ($class, %args) = @_;
    my $self = {
        min_sep => $args{min_sep} || TRENDLINE_MIN_CANDLE_SEP,
        zigzag  => Market::Indicators::ZigZag->new(
            pivot_length => $args{pivot_length} // 5,
        ),
        active_lines => [],
        _last_index  => -1,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{active_lines} = [];
    $self->{_last_index}  = -1;
    $self->{zigzag}->reset() if $self->{zigzag};
    return $self;
}

sub sync_to_index {
    my ($self, $market_data, $target_index) = @_;
    return unless $market_data && defined $target_index;
    my $start = $self->{_last_index} + 1;
    $start = 0 if $start < 0;
    for my $i ($start .. $target_index) {
        $self->update_at_index($market_data, $i);
    }
    return $self;
}

sub update_at_index {
    my ($self, $market_data, $idx) = @_;
    return unless $market_data;
    my $candle = $market_data->get_candle($idx) or return;
    $self->{zigzag}->update_at_index($market_data, $idx) if $self->{zigzag};

    # Invalidate active lines if broken
    for my $line (@{ $self->{active_lines} }) {
        next unless $line->{state} eq 'active';
        if ($self->_is_broken($line, $candle, $idx)) {
            $line->{state} = 'invalidated';
            $line->{invalidated_at} = $idx;
        } else {
            $line->{end_index} = $idx; # extend visually
        }
    }
    
    $self->{_last_index} = $idx;
    return $self;
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    
    my $target_index = $args{target_index} // ($market_data->size - 1);
    
    # We only sync internal zigzag if we need to
    my $swings = $args{source_swings} || [];
    if (scalar(@$swings) < 2 && $self->{zigzag}) {
        $self->sync_to_index($market_data, $target_index);
        $swings = $self->{zigzag}->pivots_as_swings();
    }
    
    my @valid_swings = grep { $_->{index} <= $target_index } @$swings;
    
    $self->{active_lines} = [];
    $self->_detect_trendlines(\@valid_swings, $market_data, $target_index);
    
    return {
        active_lines => $self->{active_lines},
    };
}

sub _detect_trendlines {
    my ($self, $swings, $market_data, $target_index) = @_;
    
    my @highs = sort { $a->{index} <=> $b->{index} } grep { $_->{type} eq 'High' || $_->{label} =~ /H/ } @$swings;
    my @lows  = sort { $a->{index} <=> $b->{index} } grep { $_->{type} eq 'Low'  || $_->{label} =~ /L/ } @$swings;
    
    # Bullish (Lows)
    if (@lows >= 2) {
        my $found = 0;
        for (my $i = $#lows; $i >= 1; $i--) {
            my $l2 = $lows[$i];
            for (my $j = $i - 1; $j >= 0; $j--) {
                my $l1 = $lows[$j];
                next if ($l2->{index} - $l1->{index}) < $self->{min_sep};
                next if $l2->{price} <= $l1->{price}; # must be ascending
                
                my $violated = 0;
                for my $idx ($l1->{index} + 1 .. $l2->{index} - 1) {
                    my $c = $market_data->get_candle($idx);
                    if ($self->_is_broken_math($l1, $l2, $c, $idx, 'bullish')) {
                        $violated = 1;
                        last;
                    }
                }
                
                if (!$violated) {
                    my $line = {
                        type   => 'bullish',
                        pivot1 => { index => $l1->{index}, price => $l1->{price} },
                        pivot2 => { index => $l2->{index}, price => $l2->{price} },
                        state  => 'active',
                        end_index => $l2->{index},
                    };
                    for my $idx ($l2->{index} + 1 .. $target_index) {
                        my $c = $market_data->get_candle($idx);
                        if ($self->_is_broken_math($l1, $l2, $c, $idx, 'bullish')) {
                            $line->{state} = 'invalidated';
                            $line->{invalidated_at} = $idx;
                            $line->{end_index} = $idx;
                            last;
                        }
                        $line->{end_index} = $idx;
                    }
                    push @{ $self->{active_lines} }, $line;
                    $found = 1;
                    last;
                }
            }
            last if $found;
        }
    }
    
    # Bearish (Highs)
    if (@highs >= 2) {
        my $found = 0;
        for (my $i = $#highs; $i >= 1; $i--) {
            my $h2 = $highs[$i];
            for (my $j = $i - 1; $j >= 0; $j--) {
                my $h1 = $highs[$j];
                next if ($h2->{index} - $h1->{index}) < $self->{min_sep};
                next if $h2->{price} >= $h1->{price}; # must be descending
                
                my $violated = 0;
                for my $idx ($h1->{index} + 1 .. $h2->{index} - 1) {
                    my $c = $market_data->get_candle($idx);
                    if ($self->_is_broken_math($h1, $h2, $c, $idx, 'bearish')) {
                        $violated = 1;
                        last;
                    }
                }
                
                if (!$violated) {
                    my $line = {
                        type   => 'bearish',
                        pivot1 => { index => $h1->{index}, price => $h1->{price} },
                        pivot2 => { index => $h2->{index}, price => $h2->{price} },
                        state  => 'active',
                        end_index => $h2->{index},
                    };
                    for my $idx ($h2->{index} + 1 .. $target_index) {
                        my $c = $market_data->get_candle($idx);
                        if ($self->_is_broken_math($h1, $h2, $c, $idx, 'bearish')) {
                            $line->{state} = 'invalidated';
                            $line->{invalidated_at} = $idx;
                            $line->{end_index} = $idx;
                            last;
                        }
                        $line->{end_index} = $idx;
                    }
                    push @{ $self->{active_lines} }, $line;
                    $found = 1;
                    last;
                }
            }
            last if $found;
        }
    }
}

sub _is_broken {
    my ($self, $line, $candle, $idx) = @_;
    return $self->_is_broken_math($line->{pivot1}, $line->{pivot2}, $candle, $idx, $line->{type});
}

sub _is_broken_math {
    my ($self, $p1, $p2, $candle, $idx, $type) = @_;
    return 0 if $p2->{index} == $p1->{index};
    
    my $m = ($p2->{price} - $p1->{price}) / ($p2->{index} - $p1->{index});
    my $b = $p1->{price} - ($m * $p1->{index});
    
    my $proj_y = ($m * $idx) + $b;
    
    if ($type eq 'bullish') {
        # Broken if close is below the projected line
        return $candle->{close} < $proj_y ? 1 : 0;
    } else {
        # Broken if close is above the projected line
        return $candle->{close} > $proj_y ? 1 : 0;
    }
}

1;
