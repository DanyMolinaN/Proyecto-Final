package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Tentative
# =============================================================================
# Pierna(s) viva(s) del ZigZag SMC (sin confirmar).
# Continuacion del paquete Market::Concepts::SMCStructureEngine (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _tentative_segment {
    my ($candles, $last_index, $highs, $lows) = @_;
    return undef unless $candles && defined $last_index && $last_index >= 0;

    my $last_h = ($highs && @$highs) ? $highs->[-1] : undef;
    my $last_l = ($lows  && @$lows)  ? $lows->[-1]  : undef;
    return undef unless $last_h || $last_l;

    my ($last, $last_is_high);
    if ($last_h && $last_l) {
        if (($last_h->{index} // -1) >= ($last_l->{index} // -1)) {
            $last = $last_h;
            $last_is_high = 1;
        }
        else {
            $last = $last_l;
            $last_is_high = 0;
        }
    }
    elsif ($last_h) {
        $last = $last_h;
        $last_is_high = 1;
    }
    else {
        $last = $last_l;
        $last_is_high = 0;
    }

    my $from_idx   = $last->{index};
    my $from_price = $last->{level};
    return undef unless defined $from_idx && defined $from_price;
    return undef if $from_idx >= $last_index;

    my $seek_high = $last_is_high ? 0 : 1;
    my $start     = $from_idx;
    my @points;
    my $max_legs  = 3;

    for my $leg (1 .. $max_legs) {
        last if $start >= $last_index;
        my ($ext_price, $ext_idx);
        for my $i ($start + 1 .. $last_index) {
            my $c = $candles->[$i] or next;
            if ($seek_high) {
                if (!defined $ext_price || $c->{high} > $ext_price) {
                    $ext_price = $c->{high};
                    $ext_idx   = $i;
                }
            }
            else {
                if (!defined $ext_price || $c->{low} < $ext_price) {
                    $ext_price = $c->{low};
                    $ext_idx   = $i;
                }
            }
        }
        last unless defined $ext_price && defined $ext_idx;
        push @points, { index => $ext_idx, price => $ext_price };
        last if $ext_idx >= $last_index;
        $start     = $ext_idx;
        $seek_high = $seek_high ? 0 : 1;
    }

    return undef unless @points;
    my $tip = $points[-1];
    return {
        from_index => $from_idx,
        to_index   => $tip->{index},
        from_price => $from_price,
        to_price   => $tip->{price},
        dir        => ($tip->{price} > $from_price) ? 'up' : 'down',
        points     => \@points,
    };
}

# =============================================================================
# PRIVATE — _leg(\@candles, $i, $size)
# =============================================================================

1;
