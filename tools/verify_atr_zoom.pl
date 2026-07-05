#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Panels::Scales;
use Market::Core::ATRPanelZoom;

sub data_visible {
    my ($lo, $hi, $dmin, $dmax) = @_;
    return $lo <= $dmin && $hi >= $dmax;
}

my $data_min = 2.80;
my $data_max = 3.20;
my $scale = Market::Panels::Scales->new(
    width => 1000, height => 110, y_offset => 590,
    min_value => 2.0, max_value => 6.0,
);
my $opts = { data_min => $data_min, data_max => $data_max, panel_height => 110 };
my $y = 650;

Market::Core::ATRPanelZoom::fit_to_data($scale, $data_min, $data_max);
my ($lo, $hi) = $scale->get_range();
die "fit broken\n" unless data_visible($lo, $hi, $data_min, $data_max);

for (1 .. 40) {
    Market::Core::ATRPanelZoom::apply_wheel_at_y($scale, $y, -1, $opts);
    ($lo, $hi) = $scale->get_range();
    die "zoom in lost data: [$lo,$hi]\n" unless data_visible($lo, $hi, $data_min, $data_max);
}
my $span = $hi - $lo;
my $dspan = $data_max - $data_min;
die "zoom in lost data at floor\n" unless data_visible($lo, $hi, $data_min, $data_max);
die "zoom in past floor: span $span\n" if $span < $dspan * 0.90;

for (1 .. 15) {
    Market::Core::ATRPanelZoom::apply_wheel_at_y($scale, $y, +1, $opts);
    ($lo, $hi) = $scale->get_range();
    die "zoom out lost data\n" unless data_visible($lo, $hi, $data_min, $data_max);
}

# Simular rango corrupto (como el bug del usuario) y recuperar
$scale->set_range(6.06, 6.12);
Market::Core::ATRPanelZoom::ensure_data_visible($scale, $data_min, $data_max);
($lo, $hi) = $scale->get_range();
die "recovery failed: [$lo,$hi]\n" unless data_visible($lo, $hi, $data_min, $data_max);

print "OK ATR zoom: tight span=$span, recovered=[" . ($lo) . "," . ($hi) . "]\n";
exit 0;
