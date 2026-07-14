#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';

use Market::Concepts::OrderBlockEngine;

{
    package _MockStructure;
    sub new { bless { breaks => [] }, shift }
    sub structure { return { breaks => shift->{breaks} } }
}

{
    package _MockMarketData;
    sub new { bless { candles => [] }, shift }
    sub size { scalar @{ shift->{candles} } }
    sub get_candle { my ($s, $i) = @_; return $s->{candles}[$i]; }
    sub active_tf { '1D' }
}

my $market = _MockMarketData->new;
my $structure = _MockStructure->new;

# We need an order block that gets created and tested against mitigations.
# Let's create a bullish order block at index 1 (so break is at index 2).
# Range of block: low=100, high=200 (range=100)

$market->{candles} = [
    { close => 150, high => 150, low => 150 }, # 0
    { close => 200, high => 200, low => 100 }, # 1: the origin candle
    { close => 250, high => 250, low => 200 }, # 2: the break candle
    { close => 200, high => 200, low => 150 }, # 3: 50% mitigation (low hits 150)
    { close => 200, high => 200, low => 109 }, # 4: 91% mitigation (low hits 109)
    { close => 90,  high => 200, low => 90 },  # 5: 100% invalidated (close below 100)
];

my $engine = Market::Concepts::OrderBlockEngine->new;

# Test 1: 0% mitigation
$structure->{breaks} = [{ direction => 'bullish', break_index => 2, confirmation_index => 2 }];
$market->{candles} = [
    { close => 150, high => 150, low => 150 },
    { close => 200, high => 200, low => 100 },
    { close => 250, high => 250, low => 200 },
];
my $res1 = $engine->calculate($market, $structure);
die "Expected 0% mitigation, got " . $res1->{blocks}[0]{mitigation_pct}
    unless $res1->{blocks}[0]{mitigation_pct} == 0;
die "Expected block to be active" unless @{$res1->{active}} == 1;

# Test 2: 50% mitigation
$market->{candles} = [
    { close => 150, high => 150, low => 150 },
    { close => 200, high => 200, low => 100 },
    { close => 250, high => 250, low => 200 },
    { close => 200, high => 200, low => 150 },
];
my $res2 = $engine->calculate($market, $structure);
die "Expected 50% mitigation, got " . $res2->{blocks}[0]{mitigation_pct}
    unless $res2->{blocks}[0]{mitigation_pct} == 50;
die "Expected block to be active" unless @{$res2->{active}} == 1;

# Test 3: 91% mitigation
$market->{candles} = [
    { close => 150, high => 150, low => 150 },
    { close => 200, high => 200, low => 100 },
    { close => 250, high => 250, low => 200 },
    { close => 200, high => 200, low => 109 },
];
my $res3 = $engine->calculate($market, $structure);
die "Expected 91% mitigation, got " . $res3->{blocks}[0]{mitigation_pct}
    unless $res3->{blocks}[0]{mitigation_pct} == 91;
die "Expected block to be Mitigated, got " . ($res3->{blocks}[0]{state} || '')
    unless ($res3->{blocks}[0]{state} || '') eq 'Mitigated';
die "Expected block to be removed from active" unless @{$res3->{active}} == 0;

# Test 4: 100% invalidated
$market->{candles} = [
    { close => 150, high => 150, low => 150 },
    { close => 200, high => 200, low => 100 },
    { close => 250, high => 250, low => 200 },
    { close => 90,  high => 200, low => 90 },
];
my $res4 = $engine->calculate($market, $structure);
die "Expected 100% mitigation, got " . $res4->{blocks}[0]{mitigation_pct}
    unless $res4->{blocks}[0]{mitigation_pct} == 100;
die "Expected block to be Invalidated, got " . ($res4->{blocks}[0]{state} || '')
    unless ($res4->{blocks}[0]{state} || '') eq 'Invalidated';
die "Expected block to be removed from active" unless @{$res4->{active}} == 0;

print "OK mitigation\n";
exit 0;
