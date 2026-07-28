#!/usr/bin/perl
use strict;
no warnings;
use FindBin qw($Bin);
use lib $Bin;
use Market::MarketData;
use Market::Concepts::DSVWAP::ModularEngine;
use Market::Concepts::DSVWAP::LiquiditySnapshot;
use Time::Piece;

open my $out, '>', 'validate.txt' or die $!;

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

print $out "=== PUNTO 3 ===\n";
my $found = 0;
for my $s (@$snaps) {
    next unless $s->{tf_1m} && $s->{tf_1m}{ob};
    my $obs = $s->{tf_1m}{ob};
    for my $ob (@$obs) {
        printf $out "Anchor: %d | Type: %s | pip_mid: %.2f | pip_high: %.2f | pip_low: %.2f\n",
            $s->{anchor_index}, $ob->{type}, $ob->{pip_mid}, $ob->{pip_high}, $ob->{pip_low};
        $found++;
        last if $found >= 3;
    }
    last if $found >= 3;
}

print $out "\n=== PUNTO 4 ===\n";
# Tomamos los 2 primeros validos
my @valid;
for my $s (@$snaps) {
    next unless $s->{tf_10m} && $s->{tf_1h};
    push @valid, $s;
    last if @valid >= 2;
}

# CSV feature rows correspondientes (el DatasetBuilder descarto 1, asi que deberian ser las filas 0 y 1)
open my $f_csv, '<', 'output/test_features.csv' or die $!;
my $h_str = <$f_csv>; chomp $h_str;
my @h = split /,/, $h_str;
my %h_idx = map { $h[$_] => $_ } 0..$#h;

my @csv_lines;
while (<$f_csv>) { chomp; push @csv_lines, [split /,/, $_]; }
close $f_csv;

for my $i (0..1) {
    my $s = $valid[$i];
    my $ai = $s->{anchor_index};
    my $c_row = $csv_lines[$i];

    print $out "Anchor Index $ai\n";
    printf $out "  Columna                  | Valor CSV | Valor Raw LiquiditySnapshot (pip_mid/size/etc)\n";
    printf $out "  ob_above_pip_1m          | %-9s | %s\n",
        $c_row->[$h_idx{'ob_above_pip_1m'}],
        (grep { $_->{type} =~ /bear/ } @{$s->{tf_1m}{ob}})[0] ? (grep { $_->{type} =~ /bear/ } @{$s->{tf_1m}{ob}})[0]{pip_mid} : 'undef';
        
    printf $out "  fvg_above_pip_1m         | %-9s | %s\n",
        $c_row->[$h_idx{'fvg_above_pip_1m'}],
        (grep { $_->{type} =~ /bear/ } @{$s->{tf_1m}{fvg}})[0] ? (grep { $_->{type} =~ /bear/ } @{$s->{tf_1m}{fvg}})[0]{pip_mid} : 'undef';

    printf $out "  vwap_pip_10m             | %-9s | %s\n",
        $c_row->[$h_idx{'vwap_pip_10m'}],
        $s->{tf_10m}{vwap}{pip_vwap} // 'undef';

    printf $out "  vp_poc_pip_1h            | %-9s | %s\n",
        $c_row->[$h_idx{'vp_poc_pip_1h'}],
        $s->{tf_1h}{vp}{pip_poc} // 'undef';

    printf $out "  structure_above_kind_1m  | %-9s | %s\n",
        $c_row->[$h_idx{'structure_above_kind_1m'}],
        (grep { $_->{pip} > 0 } sort { $a->{pip} <=> $b->{pip} } @{$s->{tf_1m}{structure_events}})[0] ? (grep { $_->{pip} > 0 } sort { $a->{pip} <=> $b->{pip} } @{$s->{tf_1m}{structure_events}})[0]{kind} : 'NONE';
        
    print $out "\n";
}
close $out;
