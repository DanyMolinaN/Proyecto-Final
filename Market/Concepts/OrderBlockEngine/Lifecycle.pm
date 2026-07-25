package Market::Concepts::OrderBlockEngine;

# =============================================================================
# OrderBlockEngine::Lifecycle
# =============================================================================
# Mitigacion alineada con David SMC_Structures2::_delete_order_blocks:
#   ob_mitig_src = 'highlow' (default): bull → low < ob.low;  bear → high > ob.high
#   ob_mitig_src = 'close':             bull → close < ob.low; bear → close > ob.high
# Al mitigarse, el OB deja de ser 'Detected' (sale de active en el caller).
# =============================================================================

use strict;
use warnings;

sub _apply_lifecycle {
    my ($self, $blocks, $candles, $last_index) = @_;
    my $mitig_src = $self->{ob_mitig_src} // 'highlow';

    for my $ob (@$blocks) {
        my $start = $ob->{confirmation_index};
        next unless defined $start;

        my $ob_high = $ob->{high};
        my $ob_low  = $ob->{low};
        next unless defined $ob_high && defined $ob_low;
        my $height = $ob_high - $ob_low;
        next if $height <= 0;

        my $type    = $ob->{type};
        my $state   = 'Detected';
        my $max_pct = 0;
        my $mit_idx;
        my $inv_idx;

        for (my $i = $start; $i <= $last_index; $i++) {
            my $c = $candles->[$i];
            next unless $c;

            my ($bear_src, $bull_src) = $mitig_src eq 'close'
                ? ($c->{close}, $c->{close})
                : ($c->{high},  $c->{low});

            if ($type eq 'bullish') {
                if (defined $c->{low} && $c->{low} < $ob_high) {
                    my $pct = ($ob_high - $c->{low}) / $height * 100;
                    $pct = 100 if $pct > 100;
                    $max_pct = $pct if $pct > $max_pct;
                }
                # David: bull mitiga si bullMitSrc < barLow
                if (defined $bull_src && $bull_src < $ob_low) {
                    $state   = 'Mitigated';
                    $mit_idx = $i;
                    $inv_idx = $i;
                    last;
                }
            }
            else {
                if (defined $c->{high} && $c->{high} > $ob_low) {
                    my $pct = ($c->{high} - $ob_low) / $height * 100;
                    $pct = 100 if $pct > 100;
                    $max_pct = $pct if $pct > $max_pct;
                }
                # David: bear mitiga si bearMitSrc > barHigh
                if (defined $bear_src && $bear_src > $ob_high) {
                    $state   = 'Mitigated';
                    $mit_idx = $i;
                    $inv_idx = $i;
                    last;
                }
            }
        }

        $ob->{state}             = $state;
        $ob->{mitigated_index}   = $mit_idx;
        $ob->{invalidated_index} = $inv_idx;
        $ob->{mitigation_pct}    = int($max_pct + 0.5);
    }
}

sub _deduplicate {
    my ($blocks) = @_;
    my %seen;
    my @out;
    for my $b (reverse @$blocks) {
        my $key = join(':', $b->{index}, $b->{type});
        next if $seen{$key}++;
        unshift @out, $b;
    }
    return @out;
}

sub _filter_overlaps {
    my ($self, $blocks) = @_;
    my @sorted = sort { $b->{break_index} <=> $a->{break_index} } @$blocks;
    my @kept;
    for my $b (@sorted) {
        my $overlap = 0;
        for my $k (@kept) {
            next if $b->{type} ne $k->{type};
            my $max_low = $b->{low} > $k->{low} ? $b->{low} : $k->{low};
            my $min_high = $b->{high} < $k->{high} ? $b->{high} : $k->{high};
            if ($min_high > $max_low) {
                my $intersection = $min_high - $max_low;
                my $h1 = $b->{high} - $b->{low};
                my $h2 = $k->{high} - $k->{low};
                my $min_h = $h1 < $h2 ? $h1 : $h2;
                if ($min_h > 0 && ($intersection / $min_h) > 0.5) {
                    $overlap = 1;
                    last;
                }
            }
        }
        push @kept, $b unless $overlap;
    }
    return reverse @kept;
}

sub _compute_atr_series {
    my ($candles, $last_idx, $period) = @_;
    my @atr;
    $#atr = $last_idx;
    return \@atr if $last_idx < 1;

    my $sum_tr = 0;
    my $count  = 0;
    my $alpha  = 1.0 / $period;

    for my $i (1 .. $last_idx) {
        my $c  = $candles->[$i];
        my $cp = $candles->[$i - 1];
        next unless $c && $cp;

        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl > $hc ? $hl : $hc;
        $tr = $lc if $lc > $tr;

        if (!defined $atr[$i - 1]) {
            $sum_tr += $tr;
            $count++;
            if ($count == $period) {
                $atr[$i] = $sum_tr / $period;
            }
        } else {
            $atr[$i] = $alpha * $tr + (1 - $alpha) * $atr[$i - 1];
        }
    }

    my $first_valid = 1.0;
    for my $i (0 .. $last_idx) {
        if (defined $atr[$i]) {
            $first_valid = $atr[$i];
            last;
        }
    }
    for my $i (0 .. $last_idx) {
        $atr[$i] //= $first_valid;
    }

    return \@atr;
}

sub _compute_volume_percentile {
    my ($candles, $idx, $period) = @_;
    my $start = $idx - $period + 1;
    $start = 0 if $start < 0;
    my @vols;
    for my $i ($start .. $idx) {
        my $c = $candles->[$i];
        push @vols, $c->{volume} // 0 if $c;
    }
    return 100 unless @vols > 0;
    my $target_vol = $candles->[$idx]->{volume} // 0;
    my $less_count = 0;
    for my $v (@vols) {
        $less_count++ if $v < $target_vol;
    }
    return ($less_count / scalar(@vols)) * 100;
}

1;
