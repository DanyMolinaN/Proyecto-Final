package Market::Concepts::DSVWAP::Engine;

use strict;
use warnings;
use List::Util qw(max min);

sub new {
    my ($class, %args) = @_;
    my $self = {
        length       => $args{length} || 50,
        priceSource  => $args{price_source} || 'HLC3',
        show_reg     => 1,
        show_miss    => defined $args{show_miss} ? $args{show_miss} : 1,
        
        # Estado interno
        DRAW_LOG => [],
        cache    => {},
    };
    
    bless $self, $class;
    $self->reset();
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{vwapData}   = { points => [], poly => undef };
    $self->{bandsData}  = _vwapBands_new();
    $self->{ghostVwapData}  = { points => [], poly => undef };
    $self->{ghostBandsData} = _vwapBands_new();
    
    $self->{live_ghost_label} = undef;
    $self->{zigzag}      = undef;
    $self->{ghost_level} = undef;
    
    $self->{max_v}       = 0.0;
    $self->{min_v}       = 0.0;
    $self->{max_x1}      = 0;
    $self->{min_x1}      = 0;
    $self->{follow_max}    = 0.0;
    $self->{follow_max_x1} = 0;
    $self->{follow_min}    = 0.0;
    $self->{follow_min_x1} = 0;
    $self->{os}  = 0;
    $self->{py1} = 0.0;
    $self->{px1} = 0;
    
    $self->{discovered_pivots} = [];
    $self->{line_refs} = [undef, undef];
    
    $self->{anchor_x} = 0;
    $self->{anchor_y} = 0.0;
    $self->{current_dir} = 0;
    
    $self->{active_cumVol}       = 0.0;
    $self->{active_cumPriceVol}  = 0.0;
    $self->{active_sumSqDiff}    = 0.0;
    
    $self->{hist_max}            = [];
    $self->{hist_min}            = [];
    $self->{hist_max_x1}         = [];
    $self->{hist_min_x1}         = [];
    $self->{hist_follow_max}     = [];
    $self->{hist_follow_min}     = [];
    $self->{hist_follow_max_x1}  = [];
    $self->{hist_follow_min_x1}  = [];
    $self->{hist_os}             = [];
    $self->{hist_px1}            = [];
    $self->{hist_py1}            = [];
    $self->{hist_ghost_level}    = [];
    
    $self->{cache} = {};
    $self->{DRAW_LOG} = [];
}

sub _vwapBands_new {
    return {
        u1_pts => [], l1_pts => [], u2_pts => [], l2_pts => [], u3_pts => [], l3_pts => []
    };
}

# --- Drawing Stubs ---
sub _draw_label {
    my ($self, %a) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'label', %a };
    return { type => 'label', %a, id => scalar(@{$self->{DRAW_LOG}}) };
}
sub _delete_label {
    my ($self, $lbl) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'label_delete', target => $lbl } if defined $lbl;
    return undef;
}
sub _draw_line {
    my ($self, %a) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'line', %a };
    return { type => 'line', %a, id => scalar(@{$self->{DRAW_LOG}}) };
}
sub _delete_line {
    my ($self, $ln) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'line_delete', target => $ln } if defined $ln;
    return undef;
}
sub _line_set_x2 {
    my ($self, $ln, $x2) = @_;
    if (defined $ln) {
        $ln->{x2} = $x2;
        push @{$self->{DRAW_LOG}}, { type => 'line_set_x2', target => $ln, x2 => $x2 };
    }
    return $ln;
}
sub _draw_polyline {
    my ($self, %a) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'polyline', points => [@{$a{points}}], color => $a{color} };
    return { type => 'polyline', points => $a{points}, color => $a{color} };
}
sub _delete_polyline {
    my ($self, $poly) = @_;
    push @{$self->{DRAW_LOG}}, { type => 'polyline_delete', target => $poly } if defined $poly;
    return undef;
}

sub _series_at {
    my ($self, $bars, $b, $field, $back) = @_;
    my $idx = $b - $back;
    return undef if $idx < 0 || $idx >= scalar(@$bars);
    return $bars->[$idx]{$field};
}

sub _pivot_high_at {
    my ($self, $bars, $b, $len) = @_;
    my $c = $b - $len;
    return undef if $c - $len < 0;
    return undef if $c + $len > $b;
    my $candidate = $bars->[$c]{high};
    for my $k (($c - $len) .. ($c - 1)) {
        return undef if $bars->[$k]{high} >= $candidate;
    }
    for my $k (($c + 1) .. ($c + $len)) {
        return undef if $bars->[$k]{high} >= $candidate;
    }
    return $candidate;
}

sub _pivot_low_at {
    my ($self, $bars, $b, $len) = @_;
    my $c = $b - $len;
    return undef if $c - $len < 0;
    return undef if $c + $len > $b;
    my $candidate = $bars->[$c]{low};
    for my $k (($c - $len) .. ($c - 1)) {
        return undef if $bars->[$k]{low} <= $candidate;
    }
    for my $k (($c + 1) .. ($c + $len)) {
        return undef if $bars->[$k]{low} <= $candidate;
    }
    return $candidate;
}

sub _get_swing_pivots {
    my ($self, $b, $ph, $pl, $lines_ref, $_max, $_min, $_max_x1, $_min_x1,
        $_f_max, $_f_min, $_f_max_x1, $_f_min_x1, $_os, $_px1, $_py1) = @_;

    my @local_pivots = ();

    my $l_zigzag      = $lines_ref->[0];
    my $l_ghost_level = $lines_ref->[1];

    my $local_px1 = $_px1;
    my $local_py1 = $_py1;
    my $local_os  = $_os;
    my $local_max = $_max;
    my $local_min = $_min;

    if (defined $ph) {
        if ($self->{show_miss}) {
            if ($_os == 1) {
                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_min_x1, y2=>$_min, dir=>1, is_ghost=>1);
                $local_px1 = $_min_x1; $local_py1 = $_min;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_min_x1, price => $_min, direction => 1, is_ghost => 1 };
            }
            elsif ($ph < $_max) {
                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_max_x1, y2=>$_max, dir=>-1, is_ghost=>1);
                $local_px1 = $_max_x1; $local_py1 = $_max;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_max_x1, price => $_max, direction => -1, is_ghost => 1 };

                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_f_min_x1, y2=>$_f_min, dir=>1, is_ghost=>1);
                $local_px1 = $_f_min_x1; $local_py1 = $_f_min;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_f_min_x1, price => $_f_min, direction => 1, is_ghost => 1 };
            }
        }

        if ($self->{show_reg}) {
            $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$b - $self->{length}, y2=>$ph, dir=>-1, is_ghost=>0);
        }

        push @local_pivots, { found => 1, index => $b - $self->{length}, price => $ph, direction => -1, is_ghost => 0 };
        $local_py1 = $ph; $local_px1 = $b - $self->{length}; $local_os = 1;
        $local_max = $ph; $local_min = $ph;
    }

    if (defined $pl) {
        if ($self->{show_miss}) {
            if ($_os == 0) {
                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_max_x1, y2=>$_max, dir=>-1, is_ghost=>1);
                $local_px1 = $_max_x1; $local_py1 = $_max;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_max_x1, price => $_max, direction => -1, is_ghost => 1 };
            }
            elsif ($pl > $_min) {
                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_min_x1, y2=>$_min, dir=>1, is_ghost=>1);
                $local_px1 = $_min_x1; $local_py1 = $_min;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_min_x1, price => $_min, direction => 1, is_ghost => 1 };

                $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$_f_max_x1, y2=>$_f_max, dir=>-1, is_ghost=>1);
                $local_px1 = $_f_max_x1; $local_py1 = $_f_max;
                $self->_line_set_x2($l_ghost_level, $local_px1);
                $l_ghost_level = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$local_px1, y2=>$local_py1);

                push @local_pivots, { found => 1, index => $_f_max_x1, price => $_f_max, direction => -1, is_ghost => 1 };
            }
        }

        if ($self->{show_reg}) {
            $l_zigzag = $self->_draw_line(x1=>$local_px1, y1=>$local_py1, x2=>$b - $self->{length}, y2=>$pl, dir=>1, is_ghost=>0);
        }

        push @local_pivots, { found => 1, index => $b - $self->{length}, price => $pl, direction => 1, is_ghost => 0 };
        $local_py1 = $pl; $local_px1 = $b - $self->{length}; $local_os = 0;
        $local_max = $pl; $local_min = $pl;
    }

    $lines_ref->[0] = $l_zigzag;
    $lines_ref->[1] = $l_ghost_level;

    return (\@local_pivots, $local_px1, $local_py1, $local_os, $local_max, $local_min);
}

sub _src_price_at {
    my ($self, $bars, $i) = @_;
    my $bar = $bars->[$i];
    my $ps = $self->{priceSource};
    if ($ps eq 'Close') { return $bar->{close}; }
    elsif ($ps eq 'OC2') { return ($bar->{open} + $bar->{close}) / 2; }
    elsif ($ps eq 'OHLC4') { return ($bar->{open} + $bar->{high} + $bar->{low} + $bar->{close}) / 4; }
    else { return ($bar->{high} + $bar->{low} + $bar->{close}) / 3; }
}

# --- Core Loop ---
sub calculate {
    my ($self, $market_data, %args) = @_;
    return $self->{cache} unless $market_data && $market_data->can('size') && $market_data->size() > 0;
    
    my $n = $market_data->size();
    
    $self->reset();
    
    my @bars;
    for my $i (0 .. $n - 1) {
        my $c = $market_data->get_candle($i);
        push @bars, {
            open => $c->{open}, high => $c->{high}, low => $c->{low},
            close => $c->{close}, volume => $c->{volume}
        };
        $bars[-1]{src} = $self->_src_price_at(\@bars, $i);
    }
    
    my $len = $self->{length};
    
    for (my $b = 0; $b < $n; $b++) {
        my $high_len = $self->_series_at(\@bars, $b, 'high', $len);
        my $low_len  = $self->_series_at(\@bars, $b, 'low',  $len);

        $self->{max_v} = defined($high_len) ? max($high_len, $self->{max_v}) : $self->{max_v};
        $self->{min_v} = defined($low_len)  ? min($low_len, $self->{min_v})  : $self->{min_v};
        $self->{follow_max} = defined($high_len) ? max($high_len, $self->{follow_max}) : $self->{follow_max};
        $self->{follow_min} = defined($low_len)  ? min($low_len, $self->{follow_min})  : $self->{follow_min};

        my $max_prev = @{$self->{hist_max}} ? $self->{hist_max}[-1] : 0.0;
        my $min_prev = @{$self->{hist_min}} ? $self->{hist_min}[-1] : 0.0;

        if ($self->{max_v} > $max_prev) {
            $self->{max_x1} = $b - $len;
            $self->{follow_min} = $low_len if defined $low_len;
        }
        if ($self->{min_v} < $min_prev) {
            $self->{min_x1} = $b - $len;
            $self->{follow_max} = $high_len if defined $high_len;
        }

        my $follow_min_prev = @{$self->{hist_follow_min}} ? $self->{hist_follow_min}[-1] : 0.0;
        my $follow_max_prev = @{$self->{hist_follow_max}} ? $self->{hist_follow_max}[-1] : 0.0;

        if ($self->{follow_min} < $follow_min_prev) {
            $self->{follow_min_x1} = $b - $len;
        }
        if ($self->{follow_max} > $follow_max_prev) {
            $self->{follow_max_x1} = $b - $len;
        }

        my $ghost_level_prev = @{$self->{hist_ghost_level}} ? $self->{hist_ghost_level}[-1] : undef;
        $self->_line_set_x2($ghost_level_prev, $b);

        my $_ph = $self->_pivot_high_at(\@bars, $b, $len);
        my $_pl = $self->_pivot_low_at(\@bars, $b, $len);

        $self->{line_refs}[0] = $self->{zigzag};
        $self->{line_refs}[1] = $self->{ghost_level};

        my $max1           = @{$self->{hist_max}}            ? $self->{hist_max}[-1]            : 0.0;
        my $min1           = @{$self->{hist_min}}             ? $self->{hist_min}[-1]             : 0.0;
        my $max_x1_1       = @{$self->{hist_max_x1}}          ? $self->{hist_max_x1}[-1]          : 0;
        my $min_x1_1       = @{$self->{hist_min_x1}}          ? $self->{hist_min_x1}[-1]          : 0;
        my $follow_max_1   = @{$self->{hist_follow_max}}      ? $self->{hist_follow_max}[-1]      : 0.0;
        my $follow_min_1   = @{$self->{hist_follow_min}}      ? $self->{hist_follow_min}[-1]      : 0.0;
        my $follow_max_x1_1= @{$self->{hist_follow_max_x1}}   ? $self->{hist_follow_max_x1}[-1]   : 0;
        my $follow_min_x1_1= @{$self->{hist_follow_min_x1}}   ? $self->{hist_follow_min_x1}[-1]   : 0;
        my $os_1           = @{$self->{hist_os}}              ? $self->{hist_os}[-1]              : 0;
        my $px1_1          = @{$self->{hist_px1}}             ? $self->{hist_px1}[-1]             : 0;
        my $py1_1          = @{$self->{hist_py1}}             ? $self->{hist_py1}[-1]             : 0.0;

        my ($pivots, $new_px1, $new_py1, $new_os, $new_max, $new_min) =
            $self->_get_swing_pivots($b, $_ph, $_pl, $self->{line_refs},
                              $max1, $min1, $max_x1_1, $min_x1_1,
                              $follow_max_1, $follow_min_1,
                              $follow_max_x1_1, $follow_min_x1_1,
                              $os_1, $px1_1, $py1_1);

        $self->{zigzag}      = $self->{line_refs}[0];
        $self->{ghost_level} = $self->{line_refs}[1];

        if (defined($_ph) || defined($_pl)) {
            $self->{px1} = $new_px1; $self->{py1} = $new_py1; $self->{os} = $new_os;
            $self->{max_v} = $new_max; $self->{min_v} = $new_min;
        }

        # --- VWAP Ordinario ---
        if (scalar(@$pivots) > 0) {
            my $active_pivot = $pivots->[-1];

            $self->{anchor_x}    = $active_pivot->{index};
            $self->{anchor_y}    = $active_pivot->{price};
            $self->{current_dir} = $active_pivot->{direction};

            my $barsback = $b - $self->{anchor_x};

            @{$self->{vwapData}{points}} = ();
            $self->{bandsData} = _vwapBands_new();

            my $hist_cumVol = 0.0;
            my $hist_cumPriceVol = 0.0;
            my $hist_sumSqDiff = 0.0;

            for (my $i = $barsback; $i >= 0; $i--) {
                my $v_i = $self->_series_at(\@bars, $b, 'volume', $i);
                my $p_i = $self->_series_at(\@bars, $b, 'src', $i);
                next unless defined $v_i && defined $p_i;

                $hist_cumVol      += $v_i;
                $hist_cumPriceVol += $p_i * $v_i;
                my $curr_vwap = $hist_cumVol > 0 ? $hist_cumPriceVol / $hist_cumVol : undef;

                $hist_sumSqDiff += $v_i * (($p_i - (defined($curr_vwap)?$curr_vwap:0)) ** 2);
                my $curr_stdDev = $hist_cumVol > 0 ? sqrt($hist_sumSqDiff / $hist_cumVol) : 0.0;

                my $current_bar_idx = $b - $i;
                push @{$self->{vwapData}{points}}, { x => $current_bar_idx, y => $curr_vwap, dir => $self->{current_dir} };

                push @{$self->{bandsData}{u1_pts}}, { x => $current_bar_idx, y => $curr_vwap + $curr_stdDev };
                push @{$self->{bandsData}{l1_pts}}, { x => $current_bar_idx, y => $curr_vwap - $curr_stdDev };
                push @{$self->{bandsData}{u2_pts}}, { x => $current_bar_idx, y => $curr_vwap + 2 * $curr_stdDev };
                push @{$self->{bandsData}{l2_pts}}, { x => $current_bar_idx, y => $curr_vwap - 2 * $curr_stdDev };
                push @{$self->{bandsData}{u3_pts}}, { x => $current_bar_idx, y => $curr_vwap + 3 * $curr_stdDev };
                push @{$self->{bandsData}{l3_pts}}, { x => $current_bar_idx, y => $curr_vwap - 3 * $curr_stdDev };
            }

            $self->{active_cumVol}      = $hist_cumVol;
            $self->{active_cumPriceVol} = $hist_cumPriceVol;
            $self->{active_sumSqDiff}   = $hist_sumSqDiff;
        }
        elsif ($self->{current_dir} != 0) {
            my $vol_now = $bars[$b]{volume};
            my $src_now = $bars[$b]{src};

            $self->{active_cumVol}      += $vol_now;
            $self->{active_cumPriceVol} += $src_now * $vol_now;
            my $live_vwap = $self->{active_cumVol} > 0 ? $self->{active_cumPriceVol} / $self->{active_cumVol} : undef;

            $self->{active_sumSqDiff} += $vol_now * (($src_now - (defined($live_vwap)?$live_vwap:0)) ** 2);
            my $live_stdDev = $self->{active_cumVol} > 0 ? sqrt($self->{active_sumSqDiff} / $self->{active_cumVol}) : 0.0;

            push @{$self->{vwapData}{points}}, { x => $b, y => $live_vwap, dir => $self->{current_dir} };
            push @{$self->{bandsData}{u1_pts}}, { x => $b, y => $live_vwap + $live_stdDev };
            push @{$self->{bandsData}{l1_pts}}, { x => $b, y => $live_vwap - $live_stdDev };
            push @{$self->{bandsData}{u2_pts}}, { x => $b, y => $live_vwap + 2 * $live_stdDev };
            push @{$self->{bandsData}{l2_pts}}, { x => $b, y => $live_vwap - 2 * $live_stdDev };
            push @{$self->{bandsData}{u3_pts}}, { x => $b, y => $live_vwap + 3 * $live_stdDev };
            push @{$self->{bandsData}{l3_pts}}, { x => $b, y => $live_vwap - 3 * $live_stdDev };
        }

        # --- Fantasma (Ghost) en la ultima vela ---
        if ($b == $n - 1) {
            my $x_last = 0;
            my $y_last = 0.0;
            my @prices;
            my @prices_x;

            for (my $i = 0; $i <= $b - $self->{px1} - 1; $i++) {
                my $val = $self->{os} == 1 ? $self->_series_at(\@bars, $b, 'low', $i) : $self->_series_at(\@bars, $b, 'high', $i);
                next unless defined $val;
                push @prices, $val;
                push @prices_x, $b - $i;
            }

            if (scalar(@prices) > 0) {
                if ($self->{os} == 1) {
                    $y_last = min(@prices);
                    my ($idx) = grep { $prices[$_] == $y_last } 0 .. $#prices;
                    $x_last = $prices_x[$idx];
                } else {
                    $y_last = max(@prices);
                    my ($idx) = grep { $prices[$_] == $y_last } 0 .. $#prices;
                    $x_last = $prices_x[$idx];
                }

                if ($self->{show_miss}) {
                    my $ghost_dir = $self->{os} == 1 ? 1 : -1;
                    $self->_draw_line(x1=>$self->{px1}, y1=>$self->{py1}, x2=>$x_last, y2=>$y_last, dir=>$ghost_dir, is_ghost=>1, is_ghost_trail=>1);
                    
                    my $ghost_barsback = $b - $x_last;

                    @{$self->{ghostVwapData}{points}} = ();
                    $self->{ghostBandsData} = _vwapBands_new();

                    my $ghost_cumVol = 0.0;
                    my $ghost_cumPriceVol = 0.0;
                    my $ghost_sumSqDiff = 0.0;

                    for (my $i = $ghost_barsback; $i >= 0; $i--) {
                        my $g_vol = $self->_series_at(\@bars, $b, 'volume', $i);
                        my $g_prc = $self->_series_at(\@bars, $b, 'src', $i);
                        next unless defined $g_vol && defined $g_prc;

                        $ghost_cumVol      += $g_vol;
                        $ghost_cumPriceVol += $g_prc * $g_vol;
                        my $g_vwap = $ghost_cumVol > 0 ? $ghost_cumPriceVol / $ghost_cumVol : undef;

                        $ghost_sumSqDiff += $g_vol * (($g_prc - (defined($g_vwap)?$g_vwap:0)) ** 2);
                        my $g_stdDev = $ghost_cumVol > 0 ? sqrt($ghost_sumSqDiff / $ghost_cumVol) : 0.0;

                        my $ghost_bar_idx = $b - $i;
                        push @{$self->{ghostVwapData}{points}}, { x => $ghost_bar_idx, y => $g_vwap, dir => $ghost_dir };

                        push @{$self->{ghostBandsData}{u1_pts}}, { x => $ghost_bar_idx, y => $g_vwap + $g_stdDev };
                        push @{$self->{ghostBandsData}{l1_pts}}, { x => $ghost_bar_idx, y => $g_vwap - $g_stdDev };
                        push @{$self->{ghostBandsData}{u2_pts}}, { x => $ghost_bar_idx, y => $g_vwap + 2 * $g_stdDev };
                        push @{$self->{ghostBandsData}{l2_pts}}, { x => $ghost_bar_idx, y => $g_vwap - 2 * $g_stdDev };
                        push @{$self->{ghostBandsData}{u3_pts}}, { x => $ghost_bar_idx, y => $g_vwap + 3 * $g_stdDev };
                        push @{$self->{ghostBandsData}{l3_pts}}, { x => $ghost_bar_idx, y => $g_vwap - 3 * $g_stdDev };
                    }
                }
            }
        }

        # Snapshot de fin de barra
        push @{$self->{hist_max}}, $self->{max_v};
        push @{$self->{hist_min}}, $self->{min_v};
        push @{$self->{hist_max_x1}}, $self->{max_x1};
        push @{$self->{hist_min_x1}}, $self->{min_x1};
        push @{$self->{hist_follow_max}}, $self->{follow_max};
        push @{$self->{hist_follow_min}}, $self->{follow_min};
        push @{$self->{hist_follow_max_x1}}, $self->{follow_max_x1};
        push @{$self->{hist_follow_min_x1}}, $self->{follow_min_x1};
        push @{$self->{hist_os}}, $self->{os};
        push @{$self->{hist_px1}}, $self->{px1};
        push @{$self->{hist_py1}}, $self->{py1};
        push @{$self->{hist_ghost_level}}, $self->{ghost_level};
    }
    
    # -------------------------------------------------------------
    # Volcar resultados al cache de la manera esperada por Overlay
    # -------------------------------------------------------------
    my $c = {};
    $c->{main_vwap}     = $self->{vwapData}{points};
    $c->{main_bands_u1} = $self->{bandsData}{u1_pts};
    $c->{main_bands_l1} = $self->{bandsData}{l1_pts};
    $c->{main_bands_u2} = $self->{bandsData}{u2_pts};
    $c->{main_bands_l2} = $self->{bandsData}{l2_pts};
    $c->{main_bands_u3} = $self->{bandsData}{u3_pts};
    $c->{main_bands_l3} = $self->{bandsData}{l3_pts};
    
    $c->{ghost_vwap}     = $self->{ghostVwapData}{points};
    $c->{ghost_bands_u1} = $self->{ghostBandsData}{u1_pts};
    $c->{ghost_bands_l1} = $self->{ghostBandsData}{l1_pts};
    $c->{ghost_bands_u2} = $self->{ghostBandsData}{u2_pts};
    $c->{ghost_bands_l2} = $self->{ghostBandsData}{l2_pts};
    $c->{ghost_bands_u3} = $self->{ghostBandsData}{u3_pts};
    $c->{ghost_bands_l3} = $self->{ghostBandsData}{l3_pts};
    
    my @lines;
    for my $l (@{$self->{DRAW_LOG}}) {
        if ($l->{type} eq 'line') {
            next unless defined $l->{dir}; # solo zigzags validos
            if ($l->{is_ghost_trail}) {
                $c->{ghost_line} = $l;
            } else {
                push @lines, $l;
            }
        }
    }
    $c->{zigzag_lines} = \@lines;
    
    $self->{cache} = $c;
    return $c;
}

1;
