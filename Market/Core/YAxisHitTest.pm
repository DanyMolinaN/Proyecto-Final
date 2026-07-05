package Market::Core::YAxisHitTest;

# =============================================================================
# Market::Core::YAxisHitTest
# Deteccion de zonas del eje Y / paneles (precio, ATR, tiempo).
# =============================================================================

use strict;
use warnings;

sub in_y_axis_strip {
    my ($x, $y, %opts) = @_;
    return 0 unless defined $x && defined $y;
    my $width  = $opts{width}  || 0;
    my $strip  = $opts{strip_w} || 66;
    my $y_top  = $opts{y_top}  || 0;
    my $y_bot  = $opts{y_bottom};
    return 0 unless defined $y_bot && $y_bot > $y_top;

    my $left = $width - $strip;
    $left = 0 if $left < 0;
    return 0 if $x < $left;
    return ($y >= $y_top && $y <= $y_bot) ? 1 : 0;
}

sub in_price_panel {
    my ($y, $price_height) = @_;
    return 0 unless defined $y;
    my $ph = $price_height || 0;
    return ($y >= 0 && $y <= $ph) ? 1 : 0;
}

sub in_atr_panel {
    my ($y, $price_height, $atr_height) = @_;
    return 0 unless defined $y;
    my $ph = $price_height || 0;
    my $ah = $atr_height   || 0;
    return ($y >= $ph && $y <= $ph + $ah) ? 1 : 0;
}

sub in_time_axis {
    my ($y, $top, $height) = @_;
    return 0 unless defined $y && defined $top;
    my $h = $height || 42;
    return ($y >= $top && $y < $top + $h) ? 1 : 0;
}

1;
