#!/usr/bin/perl
use strict;
no warnings;
use FindBin qw($Bin);
use lib $Bin;
use Market::MarketData;
use Market::Concepts::DSVWAP::ModularEngine;
use Market::Concepts::DSVWAP::LiquiditySnapshot;
use Time::Piece;

open my $out, '>', 'audit_eq.txt' or die $!;

my $csv = 'data/2026_07_24.csv';
my $md = Market::MarketData->new();
open(my $fh, '<', $csv) or die $!;
<$fh>;
while (my $line = <$fh>) {
    chomp $line; next unless $line =~ /\S/;
    my ($ts, $o, $h, $l, $c, $v) = split /,/, $line;
    $ts += 0 if $ts =~ /^\d+$/;
    $md->add_candle({ timestamp=>$ts, open=>$o+0, high=>$h+0, low=>$l+0, close=>$c+0, volume=>$v+0 });
}
close $fh;
$md->build_timeframes();

my $engine = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
my $res = $engine->calculate($md);
my $counter = $res->{_ghost_counter};
my $snaps = $counter->count_trails_batch_with_snapshot($md, pip_factor => 4, window_1m => 500, window_10m => 300);

print $out "=== AUDIT PUNTO 2 ===\n";
my $total_events = 0;
my $eq_events = 0;
my $printed = 0;

# Accedemos directo a la cache de _memo_cache de LiquiditySnapshot si pudieramos, 
# pero mejor llamamos al _run_smc directamente para auditar.
my $ls = Market::Concepts::DSVWAP::LiquiditySnapshot->new(pip_factor => 4);
my $view_1m = $ls->_make_tf_view($md, '1m', $md->size() - 1, 0);
my $smc_res = $ls->_run_smc($view_1m, '1m');

my $evts = $smc_res->{events} || [];
print $out "SMC 1m total eventos: " . scalar(@$evts) . "\n";
for my $e (@$evts) {
    if ($e->{kind} eq 'EQH' || $e->{kind} eq 'EQL') {
        $eq_events++;
    }
}
print $out "SMC 1m EQH/EQL eventos: $eq_events\n";

print $out "\nDetalle 5 primeros eventos:\n";
for my $e (@$evts[0..4]) {
    print $out "  - Kind: $e->{kind}, Index: $e->{index}\n" if $e;
}

close $out;
