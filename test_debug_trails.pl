use strict; use warnings;
use FindBin qw($Bin); use lib $Bin;
use Market::MarketData; use Market::Concepts::DSVWAP::ModularEngine;
use File::Spec; use Time::Piece;

sub parse_ts {
    my ($t) = @_;
    return $t+0 if $t =~ /^\d+$/;
    my $s = $t; $s =~ s/:(?=\d{2}$)//;
    my $e;
    eval { my $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z'); $e = $tp->epoch; };
    return $e // time;
}

my $mkt = Market::MarketData->new();
open my $fh, '<', File::Spec->catfile($Bin, 'data', '2026_07_20.csv') or die;
<$fh>;
while (<$fh>) {
    chomp; next unless /\S/;
    my ($ts,$o,$h,$l,$c,$v) = split /,/;
    $mkt->add_candle({ timestamp=>parse_ts($ts), open=>$o+0, high=>$h+0, low=>$l+0, close=>$c+0, volume=>$v+0 });
}
close $fh;
$mkt->build_timeframes();

my $eng = Market::Concepts::DSVWAP::ModularEngine->new();
my $res = $eng->calculate($mkt);
my $ctr = $res->{_ghost_counter};
my $stats = $ctr->count_trails_batch();

# Top 5 por trails_15m
my @sorted = sort { $b->{trails_15m} <=> $a->{trails_15m} } @$stats;
print "Top 5 apariciones con mas trails:\n";
for my $i (0..4) {
    my $st = $sorted[$i]; last unless $st;
    printf("  idx=%-5d price=%.2f dir=%2d | 3m=%d 5m=%d 10m=%d 15m=%d\n",
        $st->{anchor_index}, $st->{anchor_price}, $st->{anchor_dir},
        $st->{trails_3m}, $st->{trails_5m}, $st->{trails_10m}, $st->{trails_15m});
}

my $con_trails = scalar grep { $_->{trails_15m} > 0 } @$stats;
printf("\nTotal apariciones con trails_15m > 0: %d de %d\n", $con_trails, scalar @$stats);

# Verificar monotonia global
my $roto = 0;
for my $st (@$stats) {
    unless ($st->{trails_3m} <= $st->{trails_5m} &&
            $st->{trails_5m} <= $st->{trails_10m} &&
            $st->{trails_10m} <= $st->{trails_15m}) {
        $roto++;
        printf("  BUG MONOTONIA: idx=%d 3m=%d 5m=%d 10m=%d 15m=%d\n",
               $st->{anchor_index}, $st->{trails_3m}, $st->{trails_5m},
               $st->{trails_10m}, $st->{trails_15m});
    }
}
printf("Casos con monotonia rota: %d\n", $roto);
