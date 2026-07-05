#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::MarketData;
use Market::Concepts::FVGEngine;
use Market::Structure::StructureEngine;
use Market::Indicators::Liquidity;

my $md = Market::MarketData->new();
$md->load_csv('data/2026_03.csv') or die "load fail\n";
$md->set_timeframe('1m');
my $total = $md->size();
print "total=$total\n";

my $liq    = Market::Indicators::Liquidity->new();
my $struct = Market::Structure::StructureEngine->new(liquidity => $liq);
my $fvg    = Market::Concepts::FVGEngine->new();
$liq->calculate($md);

my $view_start = $total - 250;
my $view_end   = $total - 1;

my $res = $fvg->calculate($md, $struct);
my $gaps = $res->{gaps} || [];
print "gaps default engine=" . scalar(@$gaps) . "\n";

my $in_view = 0;
my $visible_strength = 0;
for my $g (@$gaps) {
    my $ci = $g->{created_index} // -1;
    next unless $ci >= $view_start && $ci <= $view_end;
    $in_view++;
    $visible_strength++ if ($g->{strength} // 0) > 0.05;
}
print "gaps in last 250 bars=$in_view (strength>0.05: $visible_strength)\n";

exit 0;
