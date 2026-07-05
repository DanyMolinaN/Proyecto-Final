#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Panels::Scales;
use Market::Core::VerticalScaleZoom;

my $atr = Market::Panels::Scales->new(
    width => 1000, height => 110, y_offset => 590,
    min_value => 2.0, max_value => 5.0,
    axis_tag => 'atr_y_scale',
);

my $data_min = 2.94;
my $data_max = 3.10;
my $opts = {
    panel_height   => 110,
    data_min       => $data_min,
    data_max       => $data_max,
    min_span_ratio => 0.10,
    max_span_ratio => 4.0,
};

for (1 .. 30) {
    Market::Core::VerticalScaleZoom::apply_wheel($atr, 640, +1, $opts);
}
my ($min, $max) = $atr->get_range();
die "ATR wheel zoom lost data: range $min..$max vs data $data_min..$data_max\n"
    if $max < $data_min || $min > $data_max;

for (1 .. 30) {
    Market::Core::VerticalScaleZoom::apply_wheel($atr, 640, -1, $opts);
}
($min, $max) = $atr->get_range();
die "ATR wheel zoom-in lost data\n" if $max < $data_min || $min > $data_max;

print "OK vertical zoom keeps ATR data visible ($min .. $max)\n";
exit 0;
